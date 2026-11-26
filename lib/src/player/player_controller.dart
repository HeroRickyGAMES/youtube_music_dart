import 'dart:async';

import 'package:audio_service/audio_service.dart' as audio;
import 'package:flutter/foundation.dart';
import 'package:tomato_player/tomato_player.dart' show AudioDevice;

import '../api/youtube_music_api.dart';
import '../models/models.dart';
import '../state/settings_store.dart';
import 'audio_handler.dart';

/// Bridges the background audio handler, the API and the UI.
class PlayerController extends ChangeNotifier {
  PlayerController({
    required this.handler,
    required this.api,
    required this.settings,
  }) {
    _subscriptions.add(handler.playbackState.listen((state) {
      _playbackState = state;
      _syncPosition();
      notifyListeners();
    }));
    _subscriptions.add(handler.mediaItem.listen((item) {
      _mediaItem = item;
      notifyListeners();
      // Top up the queue before it runs dry, so tracks flow into each other.
      unawaited(_maybeExtend());
    }));
    _subscriptions.add(handler.queue.listen((queue) {
      _queue = queue;
      notifyListeners();
      _maybeExtend();
    }));
    _subscriptions.add(handler.events.listen(_onHandlerEvent));
    handler.requestMoreItems = () => _maybeExtend(force: true);
    handler.updateSkipSettings(
      skipAds: settings.skipAds,
      skipIntros: settings.skipIntros,
      skipSponsor: settings.skipSponsor,
      categories: settings.sponsorCategories,
      fixedIntroSeconds: settings.fixedIntroSeconds,
      quality: settings.quality,
    );
    _positionTimer = Timer.periodic(const Duration(milliseconds: 300), (_) {
      if (playing) {
        _syncPosition();
        notifyListeners();
      }
    });
  }

  final MusicAudioHandler handler;
  final YouTubeMusicApi api;
  final SettingsStore settings;

  final List<StreamSubscription<dynamic>> _subscriptions = [];
  Timer? _positionTimer;

  audio.PlaybackState _playbackState = audio.PlaybackState();
  audio.MediaItem? _mediaItem;
  List<audio.MediaItem> _queue = const [];
  Duration _position = Duration.zero;
  bool _extending = false;
  DateTime _lastExtendAttempt = DateTime.fromMillisecondsSinceEpoch(0);

  final StreamController<String> _messages = StreamController.broadcast();
  Stream<String> get messages => _messages.stream;

  audio.PlaybackState get playbackState => _playbackState;
  audio.MediaItem? get mediaItem => _mediaItem;
  List<audio.MediaItem> get queue => _queue;
  bool get playing => _playbackState.playing;
  bool get buffering =>
      _playbackState.processingState == audio.AudioProcessingState.buffering ||
      _playbackState.processingState == audio.AudioProcessingState.loading;
  Duration get position => _position;
  Duration get duration => _mediaItem?.duration ?? Duration.zero;
  int get currentIndex => _playbackState.queueIndex ?? -1;
  MediaItem? get currentTrack {
    final item = _mediaItem;
    if (item == null) return null;
    return _fromAudioItem(item);
  }

  void _syncPosition() {
    var position = _playbackState.updatePosition;
    if (_playbackState.playing) {
      position += DateTime.now().difference(_playbackState.updateTime);
    }
    final max = _mediaItem?.duration;
    if (max != null && max > Duration.zero && position > max) {
      position = max;
    }
    _position = position;
  }

  void _onHandlerEvent(dynamic event) {
    if (event is! Map) return;
    if (event['type'] == 'skip') {
      final label = event['label'] as String? ?? 'trecho';
      _messages.add('Pulado: $label');
    } else if (event['type'] == 'error') {
      _messages.add(event['message'] as String? ?? 'Erro de reprodução.');
    } else if (event['type'] == 'queueEnded') {
      // Nothing could be fetched at the track transition; retry shortly and
      // resume if the radio came back.
      unawaited(_resumeAfterQueueEnd());
    }
  }

  Future<void> _resumeAfterQueueEnd() async {
    await Future<void>.delayed(const Duration(seconds: 2));
    final before = _queue.length;
    await _maybeExtend(force: true);
    if (_queue.length > before) {
      await handler.skipToNext();
    }
  }

  Future<void> playCollection(
    List<MediaItem> items,
    int index, {
    String? queueTitle,
  }) async {
    final tracks = items.where((item) => item.isPlayable).toList();
    if (tracks.isEmpty) return;
    final start = index.clamp(0, tracks.length - 1);
    final audioItems = tracks.map(_toAudioItem).toList();
    await handler.setQueue(audioItems,
        initialIndex: start, queueTitle: queueTitle ?? 'Fila');
    await handler.play();
  }

  /// Plays a single song and builds a YouTube Music style radio around it.
  Future<void> playRadio(MediaItem seed) async {
    final videoId = seed.videoId;
    if (videoId == null) return;
    var tracks = <MediaItem>[seed];
    try {
      final radio = await api.radio(videoId, playlistId: seed.playlistId);
      if (radio.isNotEmpty) {
        tracks = [
          seed,
          ...radio.where((item) => item.videoId != videoId),
        ];
      }
    } catch (_) {
      // A single track is still playable; the radio is a bonus.
    }
    final index = tracks.indexWhere((item) => item.videoId == videoId);
    await playCollection(tracks, index < 0 ? 0 : index,
        queueTitle: 'Rádio');
  }

  Future<void> playPlaylist(PlaylistPageData playlist, {int index = 0}) async {
    if (playlist.tracks.isEmpty) return;
    await playCollection(playlist.tracks, index, queueTitle: playlist.title);
  }

  Future<void> togglePlay() async {
    if (playing) {
      await handler.pause();
    } else {
      if (_mediaItem == null && _queue.isEmpty) return;
      await handler.play();
    }
  }

  Future<void> next() => handler.skipToNext();

  Future<void> previous() => handler.skipToPrevious();

  Future<void> seek(Duration position) => handler.seek(position);

  Future<void> playQueueIndex(int index) async {
    await handler.skipToQueueItem(index);
    await handler.play();
  }

  Future<void> setVolume(double value) => handler.setVolume(value);

  Future<void> setMuted(bool value) => handler.setMuted(value);

  double get volume => handler.volume;

  bool get muted => handler.muted;

  String get currentAudioOutput => handler.currentAudioOutput;

  Future<List<AudioDevice>> audioDevices() => handler.audioDevices();

  Future<void> setAudioDevice(String name) => handler.setAudioDevice(name);

  Future<void> setRepeatAll(bool value) => handler.setRepeatMode(
        value
            ? audio.AudioServiceRepeatMode.all
            : audio.AudioServiceRepeatMode.none,
      );

  Future<void> setLiked(bool liked) async {
    final track = currentTrack;
    if (track?.videoId == null) return;
    try {
      await api.rateSong(track!.videoId!, like: liked);
      _messages.add(liked ? 'Adicionado às curtidas' : 'Removido das curtidas');
    } catch (error) {
      _messages.add(error.toString());
    }
  }

  Future<void> _maybeExtend({bool force = false}) async {
    if (!settings.autoplay || _extending) return;
    if (_queue.isEmpty) return;
    final index = currentIndex;
    if (index < 0) return;
    final remaining = _queue.length - 1 - index;
    if (!force && remaining > 3) return;
    final now = DateTime.now();
    if (!force && now.difference(_lastExtendAttempt) < const Duration(seconds: 12)) {
      return;
    }
    _lastExtendAttempt = now;
    _extending = true;
    try {
      final last = _queue.last;
      final videoId = last.id;
      final radio = await api.radio(videoId);
      if (radio.isEmpty) return;
      await handler.addQueueItems(radio.map(_toAudioItem).toList());
    } catch (_) {
      // Autoplay is best effort. A 404 or a bot check must not break playback.
    } finally {
      _extending = false;
    }
  }

  audio.MediaItem _toAudioItem(MediaItem item) {
    return audio.MediaItem(
      id: item.videoId ?? item.id,
      title: item.title,
      artist: item.subtitle,
      album: '',
      duration: item.duration,
      artUri: item.thumbnailUrl == null
          ? null
          : Uri.tryParse(item.thumbnailUrl!),
      extras: {
        'subtitle': item.subtitle,
        'kind': item.kind.name,
        'playlistId': item.playlistId ?? '',
        'browseId': item.browseId ?? '',
        'thumbnail': item.thumbnailUrl ?? '',
        'videoId': item.videoId ?? '',
      },
    );
  }

  MediaItem _fromAudioItem(audio.MediaItem item) {
    final extras = item.extras ?? const <String, dynamic>{};
    return MediaItem(
      id: item.id,
      title: item.title,
      subtitle: extras['subtitle'] as String? ?? item.artist ?? '',
      kind: MediaKind.values.firstWhere(
        (kind) => kind.name == extras['kind'],
        orElse: () => MediaKind.song,
      ),
      duration: item.duration,
      thumbnailUrl: (extras['thumbnail'] as String?)?.isNotEmpty == true
          ? extras['thumbnail'] as String
          : item.artUri?.toString(),
      videoId: item.id,
      playlistId: (extras['playlistId'] as String?)?.isNotEmpty == true
          ? extras['playlistId'] as String
          : null,
      browseId: (extras['browseId'] as String?)?.isNotEmpty == true
          ? extras['browseId'] as String
          : null,
    );
  }

  void applySettings() {
    handler.updateSkipSettings(
      skipAds: settings.skipAds,
      skipIntros: settings.skipIntros,
      skipSponsor: settings.skipSponsor,
      categories: settings.sponsorCategories,
      fixedIntroSeconds: settings.fixedIntroSeconds,
      quality: settings.quality,
    );
  }

  @override
  void dispose() {
    _positionTimer?.cancel();
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    _messages.close();
    super.dispose();
  }
}
