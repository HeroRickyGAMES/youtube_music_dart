enum MediaKind { song, video, album, playlist, artist, episode, unknown }

class Thumbnail {
  const Thumbnail({required this.url, this.width = 0, this.height = 0});

  final String url;
  final int width;
  final int height;
}

/// A generic item returned by the YouTube Music InnerTube API.
///
/// The same class represents songs, videos, albums, playlists and artists.
/// [id] is the video id for songs/videos, or the browse id for the other kinds.
class MediaItem {
  MediaItem({
    required this.id,
    required this.title,
    this.subtitle = '',
    this.kind = MediaKind.unknown,
    this.duration,
    this.thumbnailUrl,
    this.videoId,
    this.playlistId,
    this.browseId,
    this.params,
    this.explicit = false,
  });

  final String id;
  final String title;
  final String subtitle;
  final MediaKind kind;
  final Duration? duration;
  final String? thumbnailUrl;
  final String? videoId;

  /// Playlist id usable with the `next` endpoint (radio, album audio playlist).
  final String? playlistId;
  final String? browseId;
  final String? params;
  final bool explicit;

  bool get isPlayable => (videoId != null && videoId!.isNotEmpty);
  bool get isCollection =>
      kind == MediaKind.album ||
      kind == MediaKind.playlist ||
      kind == MediaKind.artist;

  MediaItem copyWith({
    String? title,
    String? subtitle,
    Duration? duration,
    String? thumbnailUrl,
    String? playlistId,
  }) {
    return MediaItem(
      id: id,
      title: title ?? this.title,
      subtitle: subtitle ?? this.subtitle,
      kind: kind,
      duration: duration ?? this.duration,
      thumbnailUrl: thumbnailUrl ?? this.thumbnailUrl,
      videoId: videoId,
      playlistId: playlistId ?? this.playlistId,
      browseId: browseId,
      params: params,
      explicit: explicit,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'subtitle': subtitle,
        'kind': kind.name,
        'duration': duration?.inMilliseconds,
        'thumbnailUrl': thumbnailUrl,
        'videoId': videoId,
        'playlistId': playlistId,
        'browseId': browseId,
        'params': params,
        'explicit': explicit,
      };

  static MediaItem fromJson(Map<String, dynamic> json) => MediaItem(
        id: json['id'] as String,
        title: json['title'] as String? ?? '',
        subtitle: json['subtitle'] as String? ?? '',
        kind: MediaKind.values.firstWhere(
          (k) => k.name == json['kind'],
          orElse: () => MediaKind.unknown,
        ),
        duration: json['duration'] == null
            ? null
            : Duration(milliseconds: json['duration'] as int),
        thumbnailUrl: json['thumbnailUrl'] as String?,
        videoId: json['videoId'] as String?,
        playlistId: json['playlistId'] as String?,
        browseId: json['browseId'] as String?,
        params: json['params'] as String?,
        explicit: json['explicit'] as bool? ?? false,
      );

  @override
  String toString() => 'MediaItem($kind, $id, $title)';
}

class HomeSection {
  HomeSection({required this.title, required this.items, this.moreBrowseId});

  final String title;
  final List<MediaItem> items;
  final String? moreBrowseId;
}

class PlaylistPageData {
  PlaylistPageData({
    required this.title,
    required this.subtitle,
    required this.tracks,
    this.thumbnailUrl,
    this.description = '',
    this.playlistId,
    this.browseId,
    this.continuation,
    this.year = '',
  });

  final String title;
  final String subtitle;
  final String description;
  final String? thumbnailUrl;
  final List<MediaItem> tracks;
  final String? playlistId;
  final String? browseId;
  final String? continuation;
  final String year;

  PlaylistPageData copyWith({
    List<MediaItem>? tracks,
    String? continuation,
  }) {
    return PlaylistPageData(
      title: title,
      subtitle: subtitle,
      description: description,
      thumbnailUrl: thumbnailUrl,
      tracks: tracks ?? this.tracks,
      playlistId: playlistId,
      browseId: browseId,
      continuation: continuation,
      year: year,
    );
  }
}

class AccountInfo {
  const AccountInfo({
    required this.name,
    this.handle = '',
    this.avatarUrl,
    this.brandAccountId,
    this.loggedIn = true,
  });

  final String name;
  final String handle;
  final String? avatarUrl;

  /// Numeric id of the YouTube brand account (conta de marca) in use, when the
  /// session was captured while that channel was selected.
  final String? brandAccountId;
  final bool loggedIn;
}

class SearchSuggestion {
  const SearchSuggestion(this.text, {this.fromHistory = false});

  final String text;
  final bool fromHistory;
}
