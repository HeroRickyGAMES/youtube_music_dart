import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:tomato_player/tomato_player.dart';

import '../state/settings_store.dart';
import 'sponsorblock.dart';
import 'stream_resolver.dart';

/// Native playback handler.
///
/// Audio is decoded by [TomatoPlayer] (libmpv on Linux, Media3/ExoPlayer on
/// Android). [audio_service] adds the OS integration on top: foreground
/// service + media session notification on Android, and MPRIS on Linux, which
/// is what makes the hardware media keys (Play/Pause, Next, Previous) work
/// while the app is in background.
class MusicAudioHandler extends BaseAudioHandler with QueueHandler, SeekHandler {
  MusicAudioHandler({
    StreamResolver? resolver,
    SponsorBlockClient? sponsorBlock,
    String? cookies,
  })  : _resolver = resolver ?? StreamResolver(cookies: cookies),
        _sponsorBlock = sponsorBlock ?? SponsorBlockClient();

  final StreamResolver _resolver;
  final SponsorBlockClient _sponsorBlock;
  final TomatoPlayer _player = TomatoPlayer();

  /// Called when the queue is exhausted, to append more tracks (YouTube Music
  /// radio). Returning with a longer queue makes playback continue.
  Future<void> Function()? requestMoreItems;

  List<MediaItem> _items = [];
  int _index = -1;
  Duration _duration = Duration.zero;
  Duration _position = Duration.zero;
  Duration _buffered = Duration.zero;
  bool _playing = false;
  bool _ended = false;
  bool _ready = false;
  bool _advancing = false;
  bool _loading = false;
  String? _error;

  AudioQuality _quality = AudioQuality.high;
  bool _skipIntros = true;
  bool _skipSponsor = true;
  int _fixedIntroSeconds = 0;
  Set<String> _sponsorCategories = {'intro', 'sponsor', 'selfpromo'};

  List<SkipSegment> _segments = [];
  final Set<String> _appliedSegments = {};
  bool _introApplied = false;

  bool _repeatAll = false;
  bool _repeatOne = false;

  int get currentIndex => _index;
  Stream<dynamic> get events => customEvent.stream;

  Future<void> initialize() async {
    _player.addListener(_onPlayerState);
    try {
      await _player.create();
      _ready = true;
    } catch (error) {
      _error = 'Falha ao iniciar o motor de áudio: $error';
      _broadcastState();
    }
  }

  void updateSkipSettings({
    required bool skipAds,
    required bool skipIntros,
    required bool skipSponsor,
    required Set<String> categories,
    required int fixedIntroSeconds,
    required AudioQuality quality,
  }) {
    _skipIntros = skipIntros;
    _skipSponsor = skipSponsor;
    _fixedIntroSeconds = fixedIntroSeconds;
    _quality = quality;
    _sponsorCategories = categories;
    final item = _currentItem;
    if (item != null) _loadSkipSegments(item.id);
    if (_fixedIntroSeconds > 0 && !_introApplied && _position.inSeconds > 0) {
      _introApplied = true;
      if (_position.inSeconds < _fixedIntroSeconds) {
        unawaited(seek(Duration(seconds: _fixedIntroSeconds)));
      }
    }
  }

  MediaItem? get _currentItem {
    if (_index < 0 || _index >= _items.length) return null;
    return _items[_index];
  }

  Future<void> setQueue(
    List<MediaItem> items, {
    int initialIndex = 0,
    String? queueTitle,
  }) async {
    _items = List.of(items);
    queue.add(_items);
    if (queueTitle != null) this.queueTitle.add(queueTitle);
    if (_items.isEmpty) {
      _index = -1;
      mediaItem.add(null);
      return;
    }
    final index = initialIndex.clamp(0, _items.length - 1);
    await _loadIndex(index, autoPlay: false);
  }

  Future<void> addQueueItems(List<MediaItem> items) async {
    if (items.isEmpty) return;
    final known = _items.map((item) => item.id).toSet();
    final fresh = items.where((item) => !known.contains(item.id)).toList();
    if (fresh.isEmpty) return;
    _items = [..._items, ...fresh];
    queue.add(_items);
  }

  Future<void> playIndex(int index, {bool autoPlay = true}) =>
      _loadIndex(index, autoPlay: autoPlay);

  Future<void> _loadIndex(int index, {bool autoPlay = true}) async {
    if (index < 0 || index >= _items.length) return;
    _index = index;
    _loading = true;
    _error = null;
    _ended = false;
    _advancing = false;
    _duration = _items[index].duration ?? Duration.zero;
    _position = Duration.zero;
    _buffered = Duration.zero;
    _segments = [];
    _appliedSegments.clear();
    _introApplied = false;

    final item = _items[index];
    mediaItem.add(item);
    _broadcastState();

    try {
      final stream = await _resolver.resolve(item.id, quality: _quality);
      _broadcastState();
      await _player.open(TomatoMedia(stream.url.toString(),
          httpHeaders: stream.headers));
      _loading = false;
      _ended = false;
      _ready = true;
      if (autoPlay) {
        await _player.play();
      }
      _loadSkipSegments(item.id);
    } catch (error) {
      _loading = false;
      _error = 'Não foi possível tocar "${item.title}".';
      _broadcastState();
      customEvent.add({
        'type': 'error',
        'message': _error,
        'videoId': item.id,
      });
    }
  }

  void _onPlayerState() {
    final state = _player.state;
    _position = state.position;
    if (state.duration > Duration.zero) _duration = state.duration;
    _buffered = state.bufferingPercentage > 0
        ? Duration(
            milliseconds:
                (_duration.inMilliseconds * state.bufferingPercentage / 100)
                    .round(),
          )
        : _buffered;

    _playing = state.state == TomatoPlaybackState.playing;

    // mpv reports EOF as `completed` and may immediately publish `paused`
    // instead of `ended`; accept both so the queue advances.
    final reachedEnd = state.state == TomatoPlaybackState.ended ||
        (state.completed &&
            _duration > Duration.zero &&
            state.position >= _duration - const Duration(seconds: 2));

    if (state.state == TomatoPlaybackState.error) {
      _error = state.error == null
          ? 'Erro de reprodução.'
          : 'Erro de reprodução (${state.errorCode ?? state.error}).';
      _advancing = false;
    } else if (reachedEnd) {
      // A stale "ended" snapshot from the previous track can still arrive
      // while the next one is being resolved; ignore it during a load.
      if (!_loading) _ended = true;
    }

    final item = _currentItem;
    if (item != null &&
        _duration > Duration.zero &&
        (item.duration == null || (item.duration! - _duration).abs() > const Duration(seconds: 1))) {
      final updated = item.copyWith(duration: _duration);
      _items[_index] = updated;
      mediaItem.add(updated);
      queue.add(_items);
    }

    if (_ended && !_advancing && !_loading) {
      _advancing = true;
      unawaited(_onCompleted());
    }

    _broadcastState();
    _maybeSkip();
  }

  void _maybeSkip() {
    if (_segments.isEmpty || _ended) return;
    for (final segment in _segments) {
      if (_position < segment.start || _position >= segment.end) continue;
      final key = segment.uuid.isNotEmpty
          ? segment.uuid
          : '${segment.category}:${segment.start.inMilliseconds}';
      if (!_appliedSegments.add(key)) continue;
      if (_duration > Duration.zero &&
          segment.end >= _duration - const Duration(seconds: 1)) {
        customEvent.add({
          'type': 'skip',
          'label': segment.label,
          'next': true,
        });
        unawaited(skipToNext());
      } else {
        customEvent.add({
          'type': 'skip',
          'label': segment.label,
          'next': false,
        });
        unawaited(seek(segment.end));
      }
      break;
    }
    if (_fixedIntroSeconds > 0 && !_introApplied && _position.inSeconds > 0) {
      _introApplied = true;
      if (_position.inSeconds < _fixedIntroSeconds) {
        unawaited(seek(Duration(seconds: _fixedIntroSeconds)));
      }
    }
  }

  Future<void> _loadSkipSegments(String videoId) async {
    if (!_skipIntros && !_skipSponsor) return;
    final categories = _sponsorCategories.where((category) {
      if (category == 'intro') return _skipIntros;
      if (category == 'sponsor' || category == 'selfpromo') {
        return _skipSponsor;
      }
      return true;
    }).toSet();
    if (categories.isEmpty) return;
    final segments = await _sponsorBlock.segmentsFor(videoId, categories);
    if (_currentItem?.id != videoId) return;
    _segments = segments;
  }

  Future<void> _onCompleted() async {
    if (_repeatOne) {
      _ended = false;
      unawaited(_player.seek(Duration.zero));
      unawaited(_player.play());
      _advancing = false;
      return;
    }
    if (_index + 1 < _items.length) {
      await _loadIndex(_index + 1);
      return;
    }
    if (_repeatAll && _items.isNotEmpty) {
      await _loadIndex(0);
      return;
    }

    // Queue exhausted: ask for more (radio) and keep playing if it grew.
    // Without this the player stopped at the end of an album/playlist.
    final before = _items.length;
    final request = requestMoreItems;
    if (request != null) {
      try {
        await request();
      } catch (_) {
        // Autoplay is best effort.
      }
    }
    if (_items.length > before) {
      await _loadIndex(_index + 1);
      return;
    }

    _playing = false;
    playbackState.add(playbackState.value.copyWith(
      processingState: AudioProcessingState.completed,
      playing: false,
      updatePosition: _duration,
    ));
    customEvent.add({'type': 'queueEnded'});
  }

  void _broadcastState() {
    final processing = switch (_player.state.state) {
      TomatoPlaybackState.idle => AudioProcessingState.idle,
      TomatoPlaybackState.loading => AudioProcessingState.loading,
      TomatoPlaybackState.buffering => AudioProcessingState.buffering,
      TomatoPlaybackState.playing => AudioProcessingState.ready,
      TomatoPlaybackState.paused => AudioProcessingState.ready,
      TomatoPlaybackState.ended => AudioProcessingState.completed,
      TomatoPlaybackState.error => AudioProcessingState.error,
    };
    playbackState.add(PlaybackState(
      controls: [
        MediaControl.skipToPrevious,
        if (_playing) MediaControl.pause else MediaControl.play,
        MediaControl.skipToNext,
      ],
      systemActions: const {
        MediaAction.seek,
        MediaAction.seekForward,
        MediaAction.seekBackward,
      },
      androidCompactActionIndices: const [0, 1, 2],
      processingState: processing,
      playing: _playing,
      updatePosition: _position,
      bufferedPosition: _buffered,
      speed: 1.0,
      queueIndex: _index < 0 ? null : _index,
      errorMessage: _error,
    ));
  }

  @override
  Future<void> play() async {
    if (_items.isEmpty) return;
    if (_index < 0) {
      await _loadIndex(0);
      return;
    }
    if (!_ready) await initialize();
    if (_ended) {
      _ended = false;
      _advancing = false;
      await _player.seek(Duration.zero);
    }
    await _player.play();
    _playing = true;
    _broadcastState();
  }

  @override
  Future<void> pause() async {
    await _player.pause();
    _playing = false;
    _broadcastState();
  }

  @override
  Future<void> stop() async {
    await _player.pause();
    await _player.seek(Duration.zero);
    _playing = false;
    await super.stop();
  }

  @override
  Future<void> seek(Duration position) async {
    await _player.seek(position);
    _position = position;
    _ended = false;
    _advancing = false;
    _broadcastState();
  }

  @override
  Future<void> skipToNext() async {
    if (_items.isEmpty) return;
    _advancing = false;
    if (_index + 1 >= _items.length) {
      if (_repeatAll) {
        await _loadIndex(0);
        return;
      }
      // Pressing "next" on the last track also tops up the radio.
      final before = _items.length;
      final request = requestMoreItems;
      if (request != null) {
        try {
          await request();
        } catch (_) {}
      }
      if (_items.length > before) {
        await _loadIndex(_index + 1);
      }
      return;
    }
    await _loadIndex(_index + 1);
  }

  @override
  Future<void> skipToPrevious() async {
    if (_items.isEmpty) return;
    if (_position > const Duration(seconds: 4)) {
      await seek(Duration.zero);
      return;
    }
    if (_index > 0) {
      await _loadIndex(_index - 1);
    } else {
      await seek(Duration.zero);
    }
  }

  @override
  Future<void> skipToQueueItem(int index) async {
    await _loadIndex(index);
  }

  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode) async {
    _repeatAll = repeatMode == AudioServiceRepeatMode.all;
    _repeatOne = repeatMode == AudioServiceRepeatMode.one;
  }

  Future<void> setVolume(double value) => _player.setVolume(value);

  Future<void> setMuted(bool muted) => _player.setMuted(muted);

  Future<List<AudioDevice>> audioDevices() => _player.listAudioDevices();

  Future<void> setAudioDevice(String name) => _player.setAudioDevice(name);

  double get volume => _player.state.volume;

  bool get muted => _player.state.muted;

  String get currentAudioOutput => _player.state.currentAo;

  @override
  Future<void> onTaskRemoved() async {
    await _player.pause();
    _resolver.dispose();
  }
}

/// Boots audio_service and returns the initialized handler.
///
/// [handler] can be supplied when it was created early (before the first
/// Flutter frame) so the UI does not have to wait for the audio service.
Future<MusicAudioHandler> initAudioService({
  String? cookies,
  MusicAudioHandler? handler,
}) async {
  final audioHandler = handler ?? MusicAudioHandler(cookies: cookies);
  final initialized = await AudioService.init(
    builder: () => audioHandler,
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'app.ytmusic.player.audio',
      androidNotificationChannelName: 'Reprodução',
      androidNotificationChannelDescription:
          'Controles de reprodução do YouTube Music',
      androidNotificationOngoing: true,
      androidStopForegroundOnPause: true,
      androidResumeOnClick: true,
      preloadArtwork: true,
    ),
  );
  await initialized.initialize();
  return initialized;
}
