import '../models/models.dart';

/// Small helpers to walk the deeply nested InnerTube JSON trees.
class Json {
  static Map<String, dynamic>? map(dynamic value) =>
      value is Map<String, dynamic> ? value : null;

  static List<dynamic> list(dynamic value) =>
      value is List ? value : const <dynamic>[];

  static dynamic pick(dynamic node, List<String> path) {
    dynamic current = node;
    for (final key in path) {
      final currentMap = map(current);
      if (currentMap == null) return null;
      current = currentMap[key];
    }
    return current;
  }

  /// Recursively find the first value for [key] in a JSON tree.
  static dynamic findKey(dynamic node, String key) {
    if (node is Map) {
      if (node.containsKey(key)) return node[key];
      for (final value in node.values) {
        final found = findKey(value, key);
        if (found != null) return found;
      }
    } else if (node is List) {
      for (final value in node) {
        final found = findKey(value, key);
        if (found != null) return found;
      }
    }
    return null;
  }

  static List<dynamic> findAllKey(dynamic node, String key) {
    final result = <dynamic>[];
    void walk(dynamic current) {
      if (current is Map) {
        if (current.containsKey(key)) result.add(current[key]);
        for (final value in current.values) {
          walk(value);
        }
      } else if (current is List) {
        for (final value in current) {
          walk(value);
        }
      }
    }

    walk(node);
    return result;
  }
}

/// Reads text from the various shapes used by InnerTube (`simpleText`, `runs`).
String textOf(dynamic node) {
  if (node == null) return '';
  if (node is String) return node;
  if (node is num) return node.toString();
  if (node is List) {
    return node.map(textOf).where((e) => e.isNotEmpty).join();
  }
  if (node is Map) {
    final simple = node['simpleText'];
    if (simple is String) return simple;
    final runs = node['runs'];
    if (runs is List) {
      return runs.map(textOf).where((e) => e.isNotEmpty).join();
    }
    for (final key in const ['text', 'title', 'label']) {
      if (node.containsKey(key)) {
        final text = textOf(node[key]);
        if (text.isNotEmpty) return text;
      }
    }
  }
  return '';
}

String textOfRuns(dynamic node, {String separator = ' • '}) {
  final map = Json.map(node);
  if (map == null) return textOf(node);
  final runs = Json.list(map['runs']);
  if (runs.isEmpty) return textOf(node);
  final parts = runs
      .map((run) => textOf(Json.map(run)?['text']))
      .where((part) => part.trim().isNotEmpty)
      .toList();
  return parts.join(separator);
}

String? thumbnailFrom(dynamic node) {
  final thumbnails = Json.findAllKey(node, 'thumbnails');
  Thumbnail? best;
  for (final list in thumbnails) {
    for (final entry in Json.list(list)) {
      final map = Json.map(entry);
      if (map == null) continue;
      final url = map['url'] as String?;
      if (url == null || url.isEmpty) continue;
      final width = (map['width'] as num?)?.toInt() ?? 0;
      final height = (map['height'] as num?)?.toInt() ?? 0;
      final thumb = Thumbnail(url: url, width: width, height: height);
      if (best == null || thumb.width * thumb.height > best.width * best.height) {
        best = thumb;
      }
    }
  }
  return best?.url;
}

Duration? parseDuration(String raw) {
  final text = raw.trim();
  if (text.isEmpty) return null;
  final match = RegExp(r'^(\d+):(\d{1,2})(?::(\d{1,2}))?$').firstMatch(text);
  if (match == null) return null;
  if (match.group(3) != null) {
    return Duration(
      hours: int.parse(match.group(1)!),
      minutes: int.parse(match.group(2)!),
      seconds: int.parse(match.group(3)!),
    );
  }
  return Duration(
    minutes: int.parse(match.group(1)!),
    seconds: int.parse(match.group(2)!),
  );
}

/// Extracts the endpoint data that identifies an item.
class _EndpointInfo {
  const _EndpointInfo({
    this.videoId,
    this.playlistId,
    this.browseId,
    this.params,
    this.pageType,
    this.musicVideoType,
  });

  final String? videoId;
  final String? playlistId;
  final String? browseId;
  final String? params;
  final String? pageType;
  final String? musicVideoType;

  bool get isEmpty => videoId == null && browseId == null;
}

_EndpointInfo _endpointsOf(dynamic node) {
  final map = Json.map(node);
  if (map == null) return const _EndpointInfo();

  final watch = Json.map(map['watchEndpoint']);
  if (watch != null) {
    final configs = Json.map(Json.pick(
      watch,
      ['watchEndpointMusicSupportedConfigs', 'watchEndpointMusicConfig'],
    ));
    return _EndpointInfo(
      videoId: watch['videoId'] as String?,
      playlistId: watch['playlistId'] as String?,
      params: watch['params'] as String?,
      musicVideoType: configs?['musicVideoType'] as String?,
    );
  }

  final browse = Json.map(map['browseEndpoint']);
  if (browse != null) {
    final configs = Json.map(Json.pick(
      browse,
      ['browseEndpointContextSupportedConfigs',
        'browseEndpointContextMusicConfig'],
    ));
    return _EndpointInfo(
      browseId: browse['browseId'] as String?,
      params: browse['params'] as String?,
      pageType: configs?['pageType'] as String?,
    );
  }

  final watchPlaylist = Json.map(map['watchPlaylistEndpoint']);
  if (watchPlaylist != null) {
    return _EndpointInfo(
      playlistId: watchPlaylist['playlistId'] as String?,
      params: watchPlaylist['params'] as String?,
    );
  }

  final queueTarget = Json.map(Json.pick(map, ['queueAddEndpoint', 'queueTarget']));
  if (queueTarget != null) {
    return _EndpointInfo(
      videoId: queueTarget['videoId'] as String?,
      playlistId: queueTarget['playlistId'] as String?,
    );
  }

  return const _EndpointInfo();
}

_EndpointInfo _deepestEndpoint(dynamic node) {
  final direct = _endpointsOf(node);
  if (!direct.isEmpty) return direct;
  for (final key in const [
    'navigationEndpoint',
    'playNavigationEndpoint',
    'onTap',
  ]) {
    final candidate = _endpointsOf(Json.findKey(node, 'navigationEndpoint'));
    if (!candidate.isEmpty) return candidate;
    final candidate2 = _endpointsOf(Json.findKey(node, key));
    if (!candidate2.isEmpty) return candidate2;
  }
  // Search menu entries for a playlist id, useful for albums.
  for (final menu in Json.findAllKey(node, 'menuRenderer')) {
    for (final entry in Json.list(Json.map(menu)?['items'])) {
      final info = _endpointsOf(Json.findKey(entry, 'watchPlaylistEndpoint') == null
          ? Json.findKey(entry, 'navigationEndpoint')
          : Json.findKey(entry, 'watchPlaylistEndpoint'));
      if (info.playlistId != null) return info;
    }
  }
  return const _EndpointInfo();
}

MediaKind _kindFor(_EndpointInfo info, String subtitle) {
  final pageType = info.pageType ?? '';
  if (pageType.contains('ALBUM')) return MediaKind.album;
  if (pageType.contains('PLAYLIST')) return MediaKind.playlist;
  if (pageType.contains('ARTIST')) return MediaKind.artist;
  if (pageType.contains('EPISODE') || pageType.contains('PODCAST')) {
    return MediaKind.episode;
  }
  if (info.videoId != null) {
    if (info.musicVideoType == 'MUSIC_VIDEO_TYPE_ATV') return MediaKind.song;
    if (info.musicVideoType == 'MUSIC_VIDEO_TYPE_PODCAST_EPISODE') {
      return MediaKind.episode;
    }
    return MediaKind.video;
  }
  final lower = subtitle.toLowerCase();
  if (lower.contains('álbum') || lower.contains('album')) return MediaKind.album;
  if (lower.contains('playlist') || lower.contains('lista')) {
    return MediaKind.playlist;
  }
  if (lower.contains('artista') || lower.contains('artist')) {
    return MediaKind.artist;
  }
  return MediaKind.unknown;
}

MediaItem? mediaItemFrom(dynamic renderer) {
  final map = Json.map(renderer);
  if (map == null) return null;

  String title = '';
  String subtitle = '';
  String durationText = '';
  dynamic endpointNode;

  if (map.containsKey('musicTwoRowItemRenderer')) {
    final item = Json.map(map['musicTwoRowItemRenderer'])!;
    title = textOfRuns(item['title'], separator: '');
    subtitle = textOfRuns(item['subtitle']);
    endpointNode = item['navigationEndpoint'] ?? item['thumbnailOverlay'];
  } else if (map.containsKey('musicResponsiveListItemRenderer')) {
    final item = Json.map(map['musicResponsiveListItemRenderer'])!;
    final columns = Json.list(item['flexColumns']);
    final texts = columns
        .map((column) => textOfRuns(
              Json.pick(column, ['musicResponsiveListItemFlexColumnRenderer', 'text']),
            ))
        .where((text) => text.trim().isNotEmpty)
        .toList();
    if (texts.isNotEmpty) title = texts.first;
    if (texts.length > 1) subtitle = texts.skip(1).join(' • ');
    final fixed = Json.list(item['fixedColumns']);
    for (final column in fixed) {
      final text = textOfRuns(Json.pick(
        column,
        ['musicResponsiveListItemFixedColumnRenderer', 'text'],
      ));
      if (parseDuration(text) != null) durationText = text;
    }
    endpointNode = item['navigationEndpoint'] ??
        Json.pick(item, ['overlay', 'musicItemThumbnailOverlayRenderer', 'content']);
    if (_endpointsOf(endpointNode).isEmpty) {
      for (final column in columns) {
        final candidate = Json.findKey(column, 'navigationEndpoint');
        if (_endpointsOf(candidate).videoId != null) {
          endpointNode = candidate;
          break;
        }
      }
    }
  } else if (map.containsKey('musicCardShelfRenderer')) {
    final item = Json.map(map['musicCardShelfRenderer'])!;
    title = textOfRuns(item['title'], separator: '');
    subtitle = textOfRuns(item['subtitle']);
    endpointNode = item['onTap'] ?? item['title'];
  } else if (map.containsKey('playlistPanelVideoRenderer')) {
    final item = Json.map(map['playlistPanelVideoRenderer'])!;
    title = textOfRuns(item['title'], separator: '');
    subtitle = textOfRuns(item['shortBylineText']);
    durationText = textOf(item['lengthText']);
    endpointNode = item['navigationEndpoint'] ?? item['videoId'];
  } else if (map.containsKey('gridVideoRenderer') ||
      map.containsKey('videoRenderer')) {
    final item = Json.map(map['gridVideoRenderer'] ?? map['videoRenderer'])!;
    title = textOfRuns(item['title'], separator: '');
    subtitle = textOfRuns(item['shortBylineText'] ?? item['subtitle']);
    durationText = textOf(item['lengthText']);
    endpointNode = item['navigationEndpoint'];
  } else {
    return null;
  }

  final info = _deepestEndpoint(endpointNode);

  String? videoId = info.videoId;
  if (videoId == null) {
    final watch = Json.findKey(endpointNode, 'watchEndpoint');
    videoId = Json.map(watch)?['videoId'] as String?;
  }

  String? browseId = info.browseId;
  if (browseId == null) {
    browseId = textOf(Json.map(Json.findKey(endpointNode, 'browseEndpoint'))?['browseId']);
  }

  // Playlists/albums expose their id inside the browse id (VL...) or menu.
  String? playlistId = info.playlistId;
  if (playlistId == null) {
    for (final menu in Json.findAllKey(renderer, 'menuRenderer')) {
      for (final entry in Json.list(Json.map(menu)?['items'])) {
        final info2 = _endpointsOf(Json.findKey(entry, 'navigationEndpoint'));
        if (info2.playlistId != null) {
          playlistId = info2.playlistId;
          break;
        }
        final queue = _endpointsOf(Json.findKey(entry, 'queueAddEndpoint'));
        if (queue.playlistId != null) {
          playlistId = queue.playlistId;
          break;
        }
      }
      if (playlistId != null) break;
    }
  }
  if (playlistId == null && browseId.startsWith('VL')) {
    playlistId = browseId.substring(2);
  }

  final kind = _kindFor(info, subtitle);
  final id = videoId ?? browseId ?? playlistId ?? '';
  if (id.isEmpty || title.trim().isEmpty) return null;

  final thumbnail = thumbnailFrom(
    Json.findKey(renderer, 'musicThumbnailRenderer') ??
        Json.findKey(renderer, 'thumbnail'),
  );
  final duration = parseDuration(durationText);
  final explicit = Json.findKey(renderer, 'badges') != null &&
      textOf(Json.findKey(renderer, 'badges')).toUpperCase().contains('EXPLICIT');

  return MediaItem(
    id: id,
    title: title.trim(),
    subtitle: subtitle.trim(),
    kind: kind,
    duration: duration,
    thumbnailUrl: thumbnail,
    videoId: videoId,
    playlistId: playlistId,
    browseId: browseId,
    params: info.params,
    explicit: explicit,
  );
}

List<MediaItem> itemsFromContents(dynamic contents) {
  final items = <MediaItem>[];
  for (final entry in Json.list(contents)) {
    final map = Json.map(entry);
    if (map == null) continue;
    for (final key in map.keys) {
      if (key.endsWith('Renderer')) {
        final item = mediaItemFrom({key: map[key]});
        if (item != null) {
          items.add(item);
          break;
        }
      }
    }
  }
  return items;
}

String? continuationOf(dynamic node) {
  final map = Json.map(node);
  if (map == null) return null;
  for (final key in const [
    'continuationItemRenderer',
    'nextContinuationData',
    'musicPlaylistShelfContinuation',
  ]) {
    final value = Json.findKey(map, key);
    if (value != null) {
      final found = Json.findKey(value, 'continuation');
      if (found is String) return found;
      final token = Json.findKey(value, 'token');
      if (token is String) return token;
    }
  }
  return null;
}

/// Parses carousels/shelves from browse responses.
List<HomeSection> sectionsFrom(dynamic root) {
  final sections = <HomeSection>[];

  void addSection(String title, dynamic contents, {String? moreBrowseId}) {
    final items = itemsFromContents(contents);
    if (items.isEmpty) return;
    if (title.trim().isEmpty) return;
    sections.add(HomeSection(
      title: title.trim(),
      items: items,
      moreBrowseId: moreBrowseId,
    ));
  }

  for (final carousel in Json.findAllKey(root, 'musicCarouselShelfRenderer')) {
    final map = Json.map(carousel)!;
    final header = Json.findKey(map['header'], 'title') ??
        Json.findKey(map['header'], 'accessibilityData');
    final title = textOf(header);
    final more = textOf(
      Json.pick(map, ['header', 'musicCarouselShelfBasicHeaderRenderer',
        'moreContentButton', 'buttonRenderer', 'navigationEndpoint',
        'browseEndpoint', 'browseId']),
    );
    addSection(
      title,
      map['contents'],
      moreBrowseId: more.isEmpty ? null : more,
    );
  }

  for (final shelf in Json.findAllKey(root, 'musicShelfRenderer')) {
    final map = Json.map(shelf)!;
    addSection(
      textOf(map['title']),
      map['contents'],
      moreBrowseId: textOf(Json.pick(map, ['moreContentButton', 'buttonRenderer',
        'navigationEndpoint', 'browseEndpoint', 'browseId'])),
    );
  }

  for (final grid in Json.findAllKey(root, 'gridRenderer')) {
    final map = Json.map(grid)!;
    addSection(textOf(Json.findKey(map['header'], 'title')), map['items']);
  }

  // De-duplicate sections that carry the same title, keeping the richest one.
  final unique = <String, HomeSection>{};
  for (final section in sections) {
    final existing = unique[section.title];
    if (existing == null || existing.items.length < section.items.length) {
      unique[section.title] = section;
    }
  }
  return unique.values.toList();
}

PlaylistPageData? playlistFrom(dynamic root, {String? fallbackBrowseId}) {
  String title = '';
  String subtitle = '';
  String description = '';
  String year = '';
  String? thumbnail;
  String? playlistId;

  final headerCandidates = [
    ...Json.findAllKey(root, 'musicResponsiveHeaderRenderer'),
    ...Json.findAllKey(root, 'musicDetailHeaderRenderer'),
    ...Json.findAllKey(root, 'musicEditablePlaylistDetailHeaderRenderer'),
    ...Json.findAllKey(root, 'musicVisualHeaderRenderer'),
  ];
  for (final candidate in headerCandidates) {
    final map = Json.map(candidate);
    if (map == null) continue;
    title = textOfRuns(map['title'] ?? map['headingText'], separator: '');
    if (title.isEmpty) continue;
    subtitle = [
      textOfRuns(map['subtitle']),
      textOfRuns(map['secondSubtitle']),
    ].where((e) => e.isNotEmpty).join(' • ');
    description = textOfRuns(map['description'], separator: ' ');
    final yearMatch = RegExp(r'\b(19|20)\d{2}\b').firstMatch(subtitle);
    year = yearMatch?.group(0) ?? '';
    thumbnail = thumbnailFrom(map['thumbnail'] ?? map);
    playlistId = textOf(Json.pick(map, ['menu', 'menuRenderer', 'items']));
    break;
  }

  if (title.isEmpty) {
    title = textOf(Json.findKey(root, 'title'));
  }

  final tracks = <MediaItem>[];
  for (final entry in Json.list(
    Json.pick(root, [
      'continuationContents',
      'musicPlaylistShelfContinuation',
      'contents',
    ]),
  )) {
    final map = Json.map(entry);
    if (map == null) continue;
    final key = map.keys.firstWhere(
      (k) => k.endsWith('Renderer'),
      orElse: () => '',
    );
    if (key.isEmpty) continue;
    final item = mediaItemFrom({key: map[key]});
    if (item != null && item.isPlayable) tracks.add(item);
  }

  if (tracks.isEmpty) {
    for (final shelf in Json.findAllKey(root, 'musicPlaylistShelfRenderer')) {
      tracks.addAll(itemsFromContents(Json.map(shelf)?['contents']));
    }
  }
  if (tracks.isEmpty) {
    for (final shelf in Json.findAllKey(root, 'musicShelfRenderer')) {
      tracks.addAll(itemsFromContents(Json.map(shelf)?['contents'])
          .where((item) => item.isPlayable));
    }
  }
  if (tracks.isEmpty && !Json.findAllKey(root, 'musicPlaylistShelfRenderer').isEmpty) {
    return null;
  }
  if (title.isEmpty && tracks.isEmpty) return null;

  final continuation = continuationOf(root) ??
      continuationOf(Json.findKey(root, 'musicPlaylistShelfRenderer'));

  return PlaylistPageData(
    title: title,
    subtitle: subtitle,
    description: description,
    year: year,
    thumbnailUrl: thumbnail,
    tracks: tracks,
    playlistId: playlistId ?? (fallbackBrowseId?.startsWith('VL') == true
        ? fallbackBrowseId!.substring(2)
        : null),
    browseId: fallbackBrowseId,
    continuation: continuation,
  );
}

List<MediaItem> queueFromNext(dynamic root) {
  final items = <MediaItem>[];
  for (final panel in Json.findAllKey(root, 'playlistPanelRenderer')) {
    items.addAll(itemsFromContents(Json.map(panel)?['contents']));
  }
  if (items.isEmpty) {
    for (final panel in Json.findAllKey(root, 'playlistPanelContinuation')) {
      items.addAll(itemsFromContents(Json.map(panel)?['contents']));
    }
  }
  return items.where((item) => item.isPlayable).toList();
}

String? queueContinuationFrom(dynamic root) {
  for (final key in const [
    'playlistPanelContinuation',
    'playlistPanelRenderer',
  ]) {
    for (final panel in Json.findAllKey(root, key)) {
      final continuation = continuationOf(panel);
      if (continuation != null) return continuation;
    }
  }
  return null;
}

AccountInfo? accountFrom(dynamic root) {
  final renderer = Json.findKey(root, 'activeAccountHeaderRenderer') ??
      Json.findKey(root, 'accountItemRenderer');
  if (renderer == null) return null;
  final map = Json.map(renderer)!;
  final name = textOfRuns(map['accountName'], separator: '');
  if (name.isEmpty) return null;
  // The "manage account" link points to
  // https://myaccount.google.com/u/<index>/b/<brandId>/..., which is how the
  // active brand account (conta de marca) can be identified.
  final manageUrl = Json.findKey(map['manageAccountTitle'], 'url');
  final brandAccountId = manageUrl is String
      ? RegExp(r'/b/(\d+)').firstMatch(manageUrl)?.group(1)
      : null;
  return AccountInfo(
    name: name,
    handle: textOfRuns(map['channelHandle'], separator: ''),
    avatarUrl: thumbnailFrom(map['accountPhoto']),
    brandAccountId: brandAccountId,
  );
}
