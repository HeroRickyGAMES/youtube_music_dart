import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/models.dart';
import 'innertube_client.dart';
import 'innertube_parser.dart';

enum SearchFilter {
  all('Tudo', null),
  songs('Músicas', 'EgWKAQIIAWoKEAkQBRAKEAMQBA%3D%3D'),
  videos('Vídeos', 'EgWKAQIQAWoKEAkQChAFEAMQBA%3D%3D'),
  albums('Álbuns', 'EgWKAQIYAWoKEAkQChAFEAMQBA%3D%3D'),
  playlists('Playlists', 'EgWKAQIoAWoKEAkQChAFEAMQBA%3D%3D'),
  artists('Artistas', 'EgWKAQIgAWoKEAkQChAFEAMQBA%3D%3D');

  const SearchFilter(this.label, this.params);

  final String label;
  final String? params;
}

/// High level, typed facade over [InnerTubeClient].
class YouTubeMusicApi {
  YouTubeMusicApi({http.Client? httpClient})
      : client = InnerTubeClient(httpClient: httpClient);

  final InnerTubeClient client;
  final Map<String, List<HomeSection>> _homeCache = {};

  Future<void> initialize({
    String? cookies,
    String? brandAccountId,
    int? authUser,
    String language = 'pt',
    String region = 'BR',
  }) async {
    client.language = language;
    client.region = region;
    client.cookies = cookies;
    client.brandAccountId = brandAccountId;
    client.authUser = authUser;
    await client.bootstrap();
  }

  void updateSession({
    String? cookies,
    String? language,
    String? region,
    String? brandAccountId,
    int? authUser,
  }) {
    if (cookies != null) client.cookies = cookies;
    if (language != null) client.language = language;
    if (region != null) client.region = region;
    client.brandAccountId = brandAccountId;
    client.authUser = authUser;
    _homeCache.clear();
  }

  /// Re-reads the visitor id, brand account and login index from the site.
  Future<void> refreshSession() => client.bootstrap();

  String? get brandAccountId => client.brandAccountId;

  int? get authUser => client.authUser;

  bool get isAuthenticated => client.isAuthenticated;

  Future<List<HomeSection>> home({bool refresh = false}) async {
    final key = '${client.language}_${client.region}_${client.isAuthenticated}';
    final cached = _homeCache[key];
    if (!refresh && cached != null && cached.isNotEmpty) return cached;

    final response = await client.browse(browseId: 'FEmusic_home');
    var sections = sectionsFrom(response);
    sections = _dedupe(sections);
    if (sections.isNotEmpty) _homeCache[key] = sections;
    return sections;
  }

  Future<List<HomeSection>> homeContinuation(String token) async {
    final response = await client.browse(continuation: token);
    return _dedupe(sectionsFrom(response));
  }

  Future<List<HomeSection>> search(String query,
      {SearchFilter filter = SearchFilter.all, String? continuation}) async {
    final response = await client.search(
      query,
      params: filter.params,
      continuation: continuation,
    );
    final sections = _dedupe(sectionsFrom(response));
    final hasTopResult = Json.findAllKey(response, 'musicCardShelfRenderer')
        .isNotEmpty;
    if (!hasTopResult) return sections;

    final top = <MediaItem>[];
    for (final card in Json.findAllKey(response, 'musicCardShelfRenderer')) {
      final item = mediaItemFrom({'musicCardShelfRenderer': card});
      if (item != null) top.add(item);
    }
    if (top.isEmpty) return sections;
    return [
      HomeSection(title: 'Melhor resultado', items: top),
      ...sections,
    ];
  }

  Future<List<SearchSuggestion>> suggestions(String query) =>
      client.suggestions(query);

  Future<PlaylistPageData?> playlist({
    String? browseId,
    String? playlistId,
    String? continuation,
  }) async {
    if (continuation != null) {
      final response = await client.browse(continuation: continuation);
      return playlistFrom(response);
    }
    final id = browseId ?? (playlistId != null ? 'VL$playlistId' : null);
    if (id == null) return null;
    final response = await client.browse(browseId: id);
    final data = playlistFrom(response, fallbackBrowseId: id);
    if (data == null) return null;

    var tracks = data.tracks;
    var nextToken = data.continuation;
    // Load a couple of pages up front so "play all" and autoplay have a
    // healthy queue even for huge playlists.
    var pages = 0;
    while (nextToken != null && tracks.length < 100 && pages < 2) {
      try {
        final more = await playlistContinuation(nextToken, data.browseId ?? id);
        if (more == null || more.tracks.isEmpty) break;
        tracks = [...tracks, ...more.tracks];
        nextToken = more.continuation;
        pages++;
      } catch (_) {
        break;
      }
    }
    return PlaylistPageData(
      title: data.title,
      subtitle: data.subtitle,
      description: data.description,
      year: data.year,
      thumbnailUrl: data.thumbnailUrl,
      tracks: _dedupeTracks(tracks),
      playlistId: data.playlistId ?? playlistId,
      browseId: data.browseId ?? id,
      continuation: nextToken,
    );
  }

  Future<PlaylistPageData?> playlistContinuation(String token, String? id) async {
    final response = await client.browse(continuation: token);
    final data = playlistFrom(response, fallbackBrowseId: id);
    if (data == null) return null;
    return data.copyWith(tracks: _dedupeTracks(data.tracks));
  }

  /// Builds the "auto radio" queue YouTube Music uses after a song ends.
  Future<List<MediaItem>> radio(String videoId,
      {String? playlistId, String? params}) async {
    final response = await client.next(
      videoId: videoId,
      playlistId: playlistId ?? 'RDAMVM$videoId',
      params: params ?? 'wAEB',
    );
    final items = queueFromNext(response);
    return _dedupeTracks(items);
  }

  Future<AccountInfo?> accountInfo() => client.accountInfo();

  Future<List<HomeSection>> browseSections(String browseId) async {
    final response = await client.browse(browseId: browseId);
    return _dedupe(sectionsFrom(response));
  }

  Future<void> rateSong(String videoId, {required bool like}) =>
      client.rateSong(videoId, like: like);

  Future<String?> visitorData() => client.visitorId();

  Future<PlaylistPageData?> likedSongs() async {
    if (!isAuthenticated) return null;
    final response = await client.browse(browseId: 'VLLM');
    final data = playlistFrom(response, fallbackBrowseId: 'VLLM');
    if (data == null) {
      return PlaylistPageData(
        title: 'Músicas curtidas',
        subtitle: 'Sua biblioteca',
        tracks: const [],
        browseId: 'VLLM',
      );
    }
    return data;
  }

  /// Sections for the Library tab. Login is required.
  Future<List<HomeSection>> library() async {
    if (!isAuthenticated) return const [];
    final results = <HomeSection>[];
    try {
      final liked = await likedSongs();
      if (liked != null && liked.tracks.isNotEmpty) {
        results.add(HomeSection(
          title: 'Músicas curtidas',
          items: liked.tracks.take(20).toList(),
        ));
      }
    } catch (_) {}
    try {
      final response = await client.browse(browseId: 'FEmusic_liked_playlists');
      results.addAll(_dedupe(sectionsFrom(response)));
    } catch (_) {}
    try {
      final response = await client.browse(browseId: 'FEmusic_library_landing');
      final extra = _dedupe(sectionsFrom(response));
      for (final section in extra) {
        final exists = results.any((e) => e.title == section.title);
        if (!exists) results.add(section);
      }
    } catch (_) {}
    return results;
  }

  Future<String> exportSession() async {
    return jsonEncode({
      'cookies': client.cookies,
      'visitorData': client.visitorData,
      'brandAccountId': client.brandAccountId,
      'authUser': client.authUser,
    });
  }

  List<HomeSection> _dedupe(List<HomeSection> sections) {
    final byTitle = <String, HomeSection>{};
    for (final section in sections) {
      final seenItems = <String>{};
      final items = <MediaItem>[];
      for (final item in section.items) {
        if (seenItems.add('${item.kind}:${item.id}')) items.add(item);
      }
      if (items.isEmpty) continue;
      final existing = byTitle[section.title];
      if (existing == null || existing.items.length < items.length) {
        byTitle[section.title] = HomeSection(
          title: section.title,
          items: items,
          moreBrowseId: section.moreBrowseId,
        );
      }
    }
    return byTitle.values.toList();
  }

  List<MediaItem> _dedupeTracks(List<MediaItem> items) {
    final seen = <String>{};
    return items
        .where((item) => item.isPlayable && seen.add(item.videoId!))
        .toList();
  }
}
