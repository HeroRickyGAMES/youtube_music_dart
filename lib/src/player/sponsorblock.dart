import 'dart:convert';

import 'package:http/http.dart' as http;

class SkipSegment {
  const SkipSegment({
    required this.category,
    required this.start,
    required this.end,
    this.uuid = '',
  });

  final String category;
  final Duration start;
  final Duration end;
  final String uuid;

  String get label {
    switch (category) {
      case 'intro':
        return 'Introdução';
      case 'sponsor':
        return 'Patrocínio';
      case 'selfpromo':
        return 'Autopromoção';
      case 'interaction':
        return 'Pedido de inscrição';
      case 'music_offtopic':
        return 'Fora do tópico';
      case 'preview':
        return 'Prévia';
      default:
        return category;
    }
  }
}

/// Fetches community skip segments from SponsorBlock (the same data source
/// used by most "intro skip" browser extensions).
class SponsorBlockClient {
  SponsorBlockClient({http.Client? httpClient})
      : _http = httpClient ?? http.Client();

  final http.Client _http;
  final Map<String, List<SkipSegment>> _cache = {};

  Future<List<SkipSegment>> segmentsFor(
    String videoId,
    Set<String> categories,
  ) async {
    if (categories.isEmpty) return const [];
    final key = '$videoId:${(categories.toList()..sort()).join(',')}';
    final cached = _cache[key];
    if (cached != null) return cached;

    try {
      final encoded = Uri.encodeComponent(jsonEncode(categories.toList()));
      final response = await _http.get(
        Uri.parse(
          'https://sponsor.ajay.app/api/skipSegments/'
          '${Uri.encodeComponent(videoId)}?categories=$encoded',
        ),
        headers: const {
          'User-Agent': 'YouTubeMusicPlayer/1.0 (Flutter; Linux/Android)',
          'Accept': 'application/json',
        },
      ).timeout(const Duration(seconds: 8));

      if (response.statusCode == 404) {
        _cache[key] = const [];
        return const [];
      }
      if (response.statusCode != 200) return const [];

      final decoded = jsonDecode(response.body);
      if (decoded is! List) return const [];
      final segments = <SkipSegment>[];
      for (final entry in decoded) {
        if (entry is! Map) continue;
        final segment = entry['segment'];
        if (segment is! List || segment.length < 2) continue;
        if ((entry['actionType'] as String? ?? 'skip') != 'skip') continue;
        final start = (segment[0] as num).toDouble();
        final end = (segment[1] as num).toDouble();
        if (end <= start) continue;
        segments.add(SkipSegment(
          category: entry['category'] as String? ?? 'unknown',
          start: Duration(milliseconds: (start * 1000).round()),
          end: Duration(milliseconds: (end * 1000).round()),
          uuid: entry['UUID'] as String? ?? '',
        ));
      }
      segments.sort((a, b) => a.start.compareTo(b.start));
      _cache[key] = segments;
      if (_cache.length > 200) _cache.remove(_cache.keys.first);
      return segments;
    } catch (_) {
      return const [];
    }
  }

  void dispose() => _http.close();
}
