import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;
import 'package:http/http.dart' as http;

import '../models/models.dart';
import 'innertube_parser.dart';

/// Thin client for the private YouTube Music InnerTube API (WEB_REMIX).
///
/// This is the same API used by music.youtube.com itself. It works anonymously;
/// when [cookies] contains a valid Google session the account endpoints and the
/// library become available.
class InnerTubeClient {
  InnerTubeClient({
    http.Client? httpClient,
    this.language = 'pt',
    this.region = 'BR',
  }) : _http = httpClient ?? http.Client();

  static const clientName = 'WEB_REMIX';
  static const clientVersion = '1.20261104.00.00';
  static const origin = 'https://music.youtube.com';
  static const userAgent =
      'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/156.0.0.0 Safari/537.36';

  final http.Client _http;
  String language;
  String region;

  /// Raw `Cookie:` header captured from the login WebView/browser.
  String? cookies;
  String? visitorData;

  /// Brand account (conta de marca) selected for the session. Sent as
  /// `onBehalfOfUser` so library, likes and playlists belong to that channel.
  String? brandAccountId;

  /// Google multi-login index (`X-Goog-AuthUser`) of the captured session.
  int? authUser;

  bool get isAuthenticated {
    final value = cookies;
    if (value == null || value.isEmpty) return false;
    return _cookieValue('SAPISID') != null ||
        _cookieValue('__Secure-3PAPISID') != null ||
        _cookieValue('__Secure-1PAPISID') != null;
  }

  String? _cookieValue(String name) {
    final raw = cookies;
    if (raw == null) return null;
    for (final part in raw.split(';')) {
      final trimmed = part.trim();
      final index = trimmed.indexOf('=');
      if (index <= 0) continue;
      if (trimmed.substring(0, index) == name) {
        return trimmed.substring(index + 1);
      }
    }
    return null;
  }

  Map<String, dynamic> _context() => {
        'client': {
          'clientName': clientName,
          'clientVersion': clientVersion,
          'hl': language,
          'gl': region,
          'userAgent': userAgent,
          'osName': 'X11',
          'osVersion': '',
          'originalUrl': '$origin/',
          'platform': 'DESKTOP',
          'clientFormFactor': 'UNKNOWN_FORM_FACTOR',
          if (visitorData != null) 'visitorData': visitorData,
        },
        'user': {
          'lockedSafetyMode': false,
          if (brandAccountId != null) 'onBehalfOfUser': brandAccountId,
        },
      };

  Map<String, String> _headers() {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final sapisid = _cookieValue('SAPISID') ??
        _cookieValue('__Secure-3PAPISID') ??
        _cookieValue('__Secure-1PAPISID');
    final headers = <String, String>{
      'Content-Type': 'application/json',
      'Accept': '*/*',
      'Origin': origin,
      'Referer': '$origin/',
      'User-Agent': userAgent,
      'X-YouTube-Client-Name': '67',
      'X-YouTube-Client-Version': clientVersion,
      'X-Goog-Api-Format-Version': '1',
      if (visitorData != null) 'X-Goog-Visitor-Id': visitorData!,
      if (brandAccountId != null) 'X-Goog-PageId': brandAccountId!,
      if (authUser != null) 'X-Goog-AuthUser': '$authUser',
      if (cookies != null && cookies!.isNotEmpty) 'Cookie': cookies!,
    };
    if (sapisid != null && sapisid.isNotEmpty) {
      final hashInput = '$now $sapisid $origin';
      final digest = crypto.sha1.convert(utf8.encode(hashInput)).toString();
      headers['Authorization'] = 'SAPISIDHASH ${now}_$digest';
      headers['X-Origin'] = origin;
      headers['X-Goog-AuthUser'] = '0';
    }
    return headers;
  }

  Future<dynamic> _post(String endpoint, Map<String, dynamic> body) async {
    final uri = _apiUri(endpoint);
    final payload = {
      ...body,
      'context': body['context'] ?? _context(),
    };
    Object? lastError;
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        final response = await _http
            .post(
              uri,
              headers: _headers(),
              body: jsonEncode(payload),
            )
            .timeout(const Duration(seconds: 25));
        if (response.statusCode == 200) {
          return jsonDecode(response.body);
        }
        if (response.statusCode == 401 || response.statusCode == 403) {
          throw InnerTubeException(
            'A sessão do Google expirou ou foi recusada.',
            statusCode: response.statusCode,
          );
        }
        lastError = InnerTubeException(
          'Falha na API do YouTube Music (HTTP ${response.statusCode}).',
          statusCode: response.statusCode,
        );
      } on InnerTubeException {
        rethrow;
      } catch (error) {
        lastError = error;
      }
      await Future<void>.delayed(Duration(milliseconds: 400 * (attempt + 1)));
    }
    throw InnerTubeException(
      'Não foi possível falar com o YouTube Music. '
      'Verifique a conexão e tente novamente.',
      cause: lastError,
    );
  }

  /// Fetches the visitor id, brand account and anonymous configuration from
  /// the site. Runs with the current cookies, so the brand account
  /// (`DELEGATED_SESSION_ID`) and the multi-login index (`SESSION_INDEX`) match
  /// the captured session.
  Future<void> bootstrap() async {
    final cookieHeader = cookies;
    try {
      final response = await _http
          .get(
            Uri.parse('$origin/'),
            headers: {
              'User-Agent': userAgent,
              if (cookieHeader != null && cookieHeader.isNotEmpty)
                'Cookie': cookieHeader,
            },
          )
          .timeout(const Duration(seconds: 20));
      if (response.statusCode != 200) return;
      final body = response.body;
      final match = RegExp(r'"VISITOR_DATA":"([^"]+)"').firstMatch(body);
      visitorData ??= match?.group(1);
      final apiKey = RegExp(r'"INNERTUBE_API_KEY":"([^"]+)"')
          .firstMatch(body)
          ?.group(1);
      if (apiKey != null) {
        // The WEB_REMIX endpoint currently accepts keyless POSTs, but sending
        // the key when present is harmless and more future-proof.
        _apiKey = apiKey;
      }

      if (cookieHeader == null || cookieHeader.isEmpty) {
        brandAccountId = null;
        authUser = null;
        return;
      }
      final brand = RegExp(r'"DELEGATED_SESSION_ID":"(\d+)"').firstMatch(body);
      if (brand != null) brandAccountId = brand.group(1);
      final index = RegExp(r'"SESSION_INDEX":"(\d+)"').firstMatch(body);
      if (index != null) authUser = int.tryParse(index.group(1)!);
    } catch (_) {
      // Anonymous calls still work without visitor data.
    }
  }

  String? _apiKey;

  Uri _apiUri(String endpoint, [Map<String, String>? query]) {
    return Uri.parse('$origin/youtubei/v1/$endpoint').replace(
      queryParameters: {
        'prettyPrint': 'false',
        if (_apiKey != null) 'key': _apiKey!,
        ...?query,
      },
    );
  }

  Future<Map<String, dynamic>> browse({
    String? browseId,
    String? continuation,
    String? params,
  }) async {
    final json = await _post('browse', {
      if (browseId != null) 'browseId': browseId,
      if (continuation != null) 'continuation': continuation,
      if (params != null) 'params': params,
    });
    return Json.map(json) ?? const {};
  }

  Future<Map<String, dynamic>> search(String query,
      {String? params, String? continuation}) async {
    final json = await _post('search', {
      'query': query,
      if (params != null) 'params': params,
      if (continuation != null) 'continuation': continuation,
    });
    return Json.map(json) ?? const {};
  }

  Future<Map<String, dynamic>> next({
    required String videoId,
    String? playlistId,
    String? params,
    String? continuation,
  }) async {
    final json = await _post('next', {
      'videoId': videoId,
      if (playlistId != null) 'playlistId': playlistId,
      if (params != null) 'params': params,
      'isAudioOnly': true,
      'enablePersistentPlaylistPanel': true,
      'tunerSettingValue': 'AUTOMIX_SETTING_NORMAL',
      if (continuation != null) 'continuation': continuation,
    });
    return Json.map(json) ?? const {};
  }

  Future<List<SearchSuggestion>> suggestions(String input) async {
    if (input.trim().isEmpty) return const [];
    try {
      final json = await _post('music/get_search_suggestions', {'input': input});
      final root = Json.map(json);
      if (root == null) return const [];
      final suggestions = <SearchSuggestion>[];
      for (final entry in Json.findAllKey(root, 'searchSuggestionRenderer')) {
        final map = Json.map(entry);
        if (map == null) continue;
        final text = textOfRuns(map['suggestion'], separator: '');
        if (text.isNotEmpty) suggestions.add(SearchSuggestion(text));
      }
      for (final entry in Json.findAllKey(root, 'musicSearchSuggestionRenderer')) {
        final map = Json.map(entry);
        if (map == null) continue;
        final text = textOfRuns(map['suggestion'] ?? map['text'], separator: '');
        if (text.isNotEmpty) suggestions.add(SearchSuggestion(text));
      }
      return suggestions.take(8).toList();
    } catch (_) {
      return const [];
    }
  }

  Future<String?> visitorId() async {
    visitorData ??= await _fetchVisitorData();
    return visitorData;
  }

  Future<String?> _fetchVisitorData() async {
    try {
      final json = await _post('visitor_id', {});
      return Json.findKey(json, 'visitorData') as String?;
    } catch (_) {
      return null;
    }
  }

  Future<AccountInfo?> accountInfo() async {
    if (!isAuthenticated) return null;
    try {
      final json = await _post('account/account_menu', {});
      return accountFrom(json);
    } catch (_) {
      return null;
    }
  }

  Future<void> rateSong(String videoId, {required bool like}) async {
    if (!isAuthenticated) {
      throw const InnerTubeException(
        'Entre com uma conta Google para curtir músicas.',
      );
    }
    await _post(like ? 'like/like' : 'like/removelike', {
      'target': {'videoId': videoId},
    });
  }

  Future<void> close() {
    _http.close();
    return Future.value();
  }
}

class InnerTubeException implements Exception {
  const InnerTubeException(this.message, {this.statusCode, this.cause});

  final String message;
  final int? statusCode;
  final Object? cause;

  @override
  String toString() => message;
}
