import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:youtube_explode_dart/youtube_explode_dart.dart' as yte;

import '../state/settings_store.dart';

class ResolvedStream {
  const ResolvedStream({
    required this.url,
    required this.bitrate,
    required this.codec,
    required this.headers,
  });

  final Uri url;
  final int bitrate;
  final String codec;
  final Map<String, String> headers;
}

/// Turns a video id into a direct, playable audio URL.
///
/// Uses the InnerTube `player` endpoint with the `VISIONOS` client. That client
/// returns audio URLs without the `n` throttling parameter or signature
/// ciphers, so no JavaScript player has to run. The request must carry a
/// `visitorData` token, otherwise YouTube caps the stream at the first ~750 KiB
/// and answers 403 for the rest (which is exactly what broke progressive
/// playback before).
///
/// The direct MP4/WebM URL is preferred. When the response only offers HLS, the
/// m3u8 manifest is returned instead: mpv plays it natively and Android bundles
/// `media3-exoplayer-hls`.
class StreamResolver {
  StreamResolver({this.cookies, http.Client? httpClient})
      : _http = httpClient ?? http.Client();

  static const _userAgent =
      'Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) '
      'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15';
  static const _clientName = 'VISIONOS';
  static const _clientVersion = '1.02';
  static const _playerUrl =
      'https://www.youtube.com/youtubei/v1/player?prettyPrint=false';
  static const _visitorUrl =
      'https://www.youtube.com/youtubei/v1/visitor_id?prettyPrint=false';

  /// Raw `Cookie:` header of the signed-in Google account, when available.
  final String? cookies;
  final http.Client _http;
  final yte.YoutubeExplode _fallback = yte.YoutubeExplode();
  final Map<String, _CachedStream> _cache = {};

  String? _visitorData;
  DateTime? _visitorExpiresAt;
  bool _closed = false;

  Future<ResolvedStream> resolve(
    String videoId, {
    AudioQuality quality = AudioQuality.high,
  }) async {
    if (_closed) throw StateError('StreamResolver foi fechado.');
    final key = '$videoId:${quality.name}';
    final cached = _cache[key];
    if (cached != null && cached.expiresAt.isAfter(DateTime.now())) {
      return cached.stream;
    }

    Object? firstError;
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final stream = await _resolveWithVisionOs(videoId, quality);
        _cache[key] = _CachedStream(
          stream,
          DateTime.now().add(const Duration(minutes: 50)),
        );
        _trimCache();
        return stream;
      } catch (error) {
        firstError = error;
        // A stale visitor token is the most common cause of a refusal.
        _visitorData = null;
        await Future<void>.delayed(Duration(milliseconds: 400 * (attempt + 1)));
      }
    }

    try {
      final stream = await _resolveWithStreamsApi(videoId, quality);
      _cache[key] = _CachedStream(
        stream,
        DateTime.now().add(const Duration(minutes: 50)),
      );
      _trimCache();
      return stream;
    } catch (error) {
      firstError ??= error;
    }

    throw _ResolutionException(
      'Não foi possível preparar o áudio desta faixa. '
      'Tente novamente em alguns segundos.',
      cause: firstError,
    );
  }

  Future<ResolvedStream> _resolveWithVisionOs(
    String videoId,
    AudioQuality quality,
  ) async {
    final visitor = await _ensureVisitorData();
    final payload = <String, dynamic>{
      'context': {
        'client': {
          'clientName': _clientName,
          'clientVersion': _clientVersion,
          'deviceMake': 'Apple',
          'deviceModel': 'RealityDevice17,1',
          'userAgent': _userAgent,
          'osName': 'visionOS',
          'osVersion': '26.5.23O471',
          'hl': 'en',
          'timeZone': 'UTC',
          'utcOffsetMinutes': 0,
          'visitorData': visitor,
        },
      },
      'videoId': videoId,
      'contentCheckOk': true,
      'racyCheckOk': true,
    };

    final response = await _http
        .post(
          Uri.parse(_playerUrl),
          headers: {
            'Content-Type': 'application/json',
            'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
            'Origin': 'https://www.youtube.com',
            'User-Agent': _userAgent,
            'X-YouTube-Client-Name': '101',
            'X-YouTube-Client-Version': _clientVersion,
            'X-Goog-Visitor-Id': visitor,
            if (cookies case final value? when value.isNotEmpty) 'Cookie': value,
          },
          body: jsonEncode(payload),
        )
        .timeout(const Duration(seconds: 25));

    if (response.statusCode != 200) {
      throw _ResolutionException(
        'A API do YouTube recusou a faixa (HTTP ${response.statusCode}).',
      );
    }

    final json = jsonDecode(response.body);
    if (json is! Map<String, dynamic>) {
      throw const _ResolutionException('Resposta inválida do YouTube.');
    }
    final status = json['playabilityStatus'];
    final playability =
        status is Map<String, dynamic> ? status['status'] as String? : null;
    final streaming = json['streamingData'];
    if (streaming is! Map<String, dynamic>) {
      final reason = status is Map<String, dynamic>
          ? (status['reason'] as String? ?? '')
          : '';
      throw _ResolutionException(
        reason.isEmpty
            ? 'Esta faixa não está disponível para reprodução.'
            : reason,
      );
    }

    final allFormats = streaming['adaptiveFormats'];
    final formats = allFormats is List ? allFormats : const [];
    final audio = formats
        .whereType<Map<String, dynamic>>()
        .where((format) =>
            (format['mimeType'] as String? ?? '').startsWith('audio/') &&
            format['url'] is String)
        .toList();
    final chosen = _pick(audio, quality);
    if (chosen != null) {
      final url = Uri.parse(chosen['url'] as String);
      final mime = chosen['mimeType'] as String? ?? '';
      return ResolvedStream(
        url: url,
        bitrate: ((chosen['bitrate'] as num?)?.toInt() ?? 0) ~/ 1000,
        codec: _codecOf(mime),
        headers: _streamHeaders(visitor),
      );
    }

    final hls = streaming['hlsManifestUrl'];
    if (hls is String && hls.isNotEmpty) {
      return ResolvedStream(
        url: Uri.parse(hls),
        bitrate: 0,
        codec: 'hls',
        headers: _streamHeaders(visitor),
      );
    }

    throw _ResolutionException(
      playability == 'OK'
          ? 'Esta faixa não tem uma versão somente-áudio disponível.'
          : 'Esta faixa não está disponível para reprodução.',
    );
  }

  /// Last resort for videos the VISIONOS client cannot serve (for example
  /// "made for kids" content). It may still hit YouTube's byte cap, but trying
  /// is better than failing outright.
  Future<ResolvedStream> _resolveWithStreamsApi(
    String videoId,
    AudioQuality quality,
  ) async {
    final manifest = await _fallback.videos.streams.getManifest(
      videoId,
      ytClients: const [yte.YoutubeApiClient.androidSdkless],
      requireWatchPage: false,
    );
    final playable = manifest.audioOnly.toList()
      ..sort(
        (a, b) => a.bitrate.bitsPerSecond.compareTo(b.bitrate.bitsPerSecond),
      );
    if (playable.isEmpty) {
      throw const _ResolutionException(
        'Esta faixa não tem uma versão somente-áudio disponível.',
      );
    }
    final selected = switch (quality) {
      AudioQuality.low => playable.first,
      AudioQuality.normal => playable.firstWhere(
          (stream) => stream.bitrate.kiloBitsPerSecond <= 160,
          orElse: () => playable.first,
        ),
      AudioQuality.high => playable.last,
    };
    return ResolvedStream(
      url: selected.url,
      bitrate: selected.bitrate.kiloBitsPerSecond.round(),
      codec: selected.audioCodec,
      headers: {'User-Agent': _userAgent},
    );
  }

  Map<String, dynamic>? _pick(
    List<Map<String, dynamic>> formats,
    AudioQuality quality,
  ) {
    if (formats.isEmpty) return null;
    formats.sort(
      (a, b) => ((a['bitrate'] as num?)?.toInt() ?? 0)
          .compareTo((b['bitrate'] as num?)?.toInt() ?? 0),
    );
    return switch (quality) {
      AudioQuality.low => formats.first,
      AudioQuality.normal => formats.firstWhere(
          (format) => ((format['bitrate'] as num?)?.toInt() ?? 0) <= 160000,
          orElse: () => formats.first,
        ),
      AudioQuality.high => formats.last,
    };
  }

  String _codecOf(String mimeType) {
    final match = RegExp(r'codecs="?([^";]+)"?').firstMatch(mimeType);
    if (match != null) return match.group(1)!.trim();
    if (mimeType.contains('opus')) return 'opus';
    if (mimeType.contains('mp4a')) return 'aac';
    return mimeType.split('/').last.split(';').first;
  }

  Map<String, String> _streamHeaders(String visitor) => {
        'User-Agent': _userAgent,
        'X-Goog-Visitor-Id': visitor,
      };

  Future<String> _ensureVisitorData() async {
    final cached = _visitorData;
    final expiresAt = _visitorExpiresAt;
    if (cached != null &&
        expiresAt != null &&
        expiresAt.isAfter(DateTime.now())) {
      return cached;
    }
    try {
      final response = await _http
          .post(
            Uri.parse(_visitorUrl),
            headers: {
              'Content-Type': 'application/json',
              'User-Agent': _userAgent,
              'X-YouTube-Client-Name': '1',
              'X-YouTube-Client-Version': '2.20260101.00.00',
            },
            body: jsonEncode({
              'context': {
                'client': {
                  'clientName': 'WEB',
                  'clientVersion': '2.20260101.00.00',
                },
              },
            }),
          )
          .timeout(const Duration(seconds: 15));
      if (response.statusCode == 200) {
        final json = jsonDecode(response.body);
        final visitor = json is Map<String, dynamic>
            ? _findString(json, 'visitorData')
            : null;
        if (visitor != null && visitor.isNotEmpty) {
          _visitorData = visitor;
          _visitorExpiresAt = DateTime.now().add(const Duration(minutes: 40));
          return visitor;
        }
      }
    } catch (_) {
      // Fall through to the page bootstrap below.
    }

    // Older/blocked visitor endpoint: scrape the token from the home page.
    final response = await _http.get(
      Uri.parse('https://www.youtube.com/'),
      headers: {'User-Agent': _userAgent},
    ).timeout(const Duration(seconds: 20));
    final match = RegExp(r'"VISITOR_DATA":"([^"]+)"').firstMatch(response.body);
    final visitor = match?.group(1) == null
        ? null
        : jsonDecode('"${match!.group(1)}"') as String?;
    if (visitor == null || visitor.isEmpty) {
      throw const _ResolutionException(
        'Não foi possível identificar a sessão anônima do YouTube.',
      );
    }
    _visitorData = visitor;
    _visitorExpiresAt = DateTime.now().add(const Duration(minutes: 40));
    return visitor;
  }

  String? _findString(Object? node, String key) {
    if (node is Map) {
      for (final entry in node.entries) {
        if (entry.key == key && entry.value is String) {
          return entry.value as String;
        }
        final found = _findString(entry.value, key);
        if (found != null) return found;
      }
    } else if (node is List) {
      for (final value in node) {
        final found = _findString(value, key);
        if (found != null) return found;
      }
    }
    return null;
  }

  void _trimCache() {
    if (_cache.length <= 12) return;
    final now = DateTime.now();
    _cache.removeWhere((_, value) => value.expiresAt.isBefore(now));
    while (_cache.length > 12) {
      _cache.remove(_cache.keys.first);
    }
  }

  void dispose() {
    _closed = true;
    _http.close();
    _fallback.close();
  }
}

class _CachedStream {
  const _CachedStream(this.stream, this.expiresAt);

  final ResolvedStream stream;
  final DateTime expiresAt;
}

class _ResolutionException implements Exception {
  const _ResolutionException(this.message, {this.cause});

  final String message;
  final Object? cause;

  @override
  String toString() => message;
}
