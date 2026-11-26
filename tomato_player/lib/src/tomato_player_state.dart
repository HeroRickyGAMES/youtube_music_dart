import 'package:flutter/foundation.dart';

/// Estados de reprodução expostos pelo [TomatoPlayer].
enum TomatoPlaybackState {
  /// Sem mídia carregada / pronto para abrir.
  idle,

  /// `open()` chamado e o motor ainda está resolvendo a fonte.
  loading,

  /// Tocando porém em buffer (rebuffering).
  buffering,

  /// Reproduzindo.
  playing,

  /// Pausado.
  paused,

  /// Fim do arquivo alcançado.
  ended,

  /// Erro fatal de reprodução.
  error,
}

/// Snapshot imutável do estado do player.
@immutable
class TomatoPlayerState {
  const TomatoPlayerState({
    this.state = TomatoPlaybackState.idle,
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.bufferingPercentage = 0,
    this.completed = false,
    this.videoWidth = 0,
    this.videoHeight = 0,
    this.volume = 100,
    this.muted = false,
    this.hasAudio = false,
    this.currentAo = '',
    this.audioDevice = '',
    this.error,
    this.errorCode,
    this.dbgFrames = 0,
    this.dbgCopies = 0,
    this.dbgUpdates = 0,
    this.dbgLogs = const <String>[],
  });

  final TomatoPlaybackState state;
  final Duration position;
  final Duration duration;
  final double bufferingPercentage;

  /// `true` quando o fim da mídia foi alcançado (fila/auto-próximo).
  final bool completed;

  final int videoWidth;
  final int videoHeight;

  /// Volume real do motor (0-100), como o mpv esta aplicando.
  ///
  /// Antes nao havia isso: o motor abria em 100 e o app nunca mandava volume,
  /// entao um audio mudo ficava sem nenhuma forma de ser visto ou corrigido.
  final double volume;

  /// `true` quando o motor esta com o mute ligado.
  final bool muted;

  /// `true` quando a midia carregada tem faixa de audio.
  ///
  /// E o que habilita o controle de volume na UI: sem faixa de audio o slider
  /// nao teria efeito e so confunde.
  final bool hasAudio;

  /// Backend de audio em uso (ex.: `pipewire`, `pulse`, `alsa`).
  final String currentAo;

  /// Dispositivo de saida selecionado (`auto` quando o mpv escolhe sozinho).
  final String audioDevice;

  /// Mensagem de erro (quando `state == error`).
  final String? error;

  /// Código/categoria do erro (pode ser `null`).
  final String? errorCode;

  /// Telemetria do caminho de render nativo (somente Linux): frames que o mpv
  /// realmente renderizou no buffer (dbgFrames), cópias que o Flutter leu
  /// (dbgCopies) e callbacks de update que o mpv disparou (dbgUpdates).
  final int dbgFrames;
  final int dbgCopies;
  final int dbgUpdates;
  final List<String> dbgLogs;

  bool get hasVideo => videoWidth > 0 && videoHeight > 0;

  double get aspectRatio =>
      hasVideo ? videoWidth / videoHeight : 16 / 9;

  TomatoPlayerState copyWith({
    TomatoPlaybackState? state,
    Duration? position,
    Duration? duration,
    double? bufferingPercentage,
    bool? completed,
    int? videoWidth,
    int? videoHeight,
    double? volume,
    bool? muted,
    bool? hasAudio,
    String? currentAo,
    String? audioDevice,
    String? error,
    String? errorCode,
    int? dbgFrames,
    int? dbgCopies,
    int? dbgUpdates,
    List<String>? dbgLogs,
    bool clearError = false,
  }) {
    return TomatoPlayerState(
      state: state ?? this.state,
      position: position ?? this.position,
      duration: duration ?? this.duration,
      bufferingPercentage: bufferingPercentage ?? this.bufferingPercentage,
      completed: completed ?? this.completed,
      videoWidth: videoWidth ?? this.videoWidth,
      videoHeight: videoHeight ?? this.videoHeight,
      volume: volume ?? this.volume,
      muted: muted ?? this.muted,
      hasAudio: hasAudio ?? this.hasAudio,
      currentAo: currentAo ?? this.currentAo,
      audioDevice: audioDevice ?? this.audioDevice,
      error: clearError ? null : (error ?? this.error),
      errorCode: clearError ? null : (errorCode ?? this.errorCode),
      dbgFrames: dbgFrames ?? this.dbgFrames,
      dbgCopies: dbgCopies ?? this.dbgCopies,
      dbgUpdates: dbgUpdates ?? this.dbgUpdates,
      dbgLogs: dbgLogs ?? this.dbgLogs,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is TomatoPlayerState &&
        other.state == state &&
        other.position == position &&
        other.duration == duration &&
        other.bufferingPercentage == bufferingPercentage &&
        other.completed == completed &&
        other.videoWidth == videoWidth &&
        other.videoHeight == videoHeight &&
        other.volume == volume &&
        other.muted == muted &&
        other.hasAudio == hasAudio &&
        other.currentAo == currentAo &&
        other.audioDevice == audioDevice &&
        other.error == error &&
        other.errorCode == errorCode &&
        other.dbgFrames == dbgFrames &&
        other.dbgCopies == dbgCopies &&
        other.dbgUpdates == dbgUpdates;
  }

  @override
  int get hashCode => Object.hash(
      state,
      position,
      duration,
      bufferingPercentage,
      completed,
      videoWidth,
      videoHeight,
      volume,
      muted,
      hasAudio,
      currentAo,
      audioDevice,
      error,
      errorCode,
      dbgFrames,
      dbgCopies,
      dbgUpdates,
    );
}