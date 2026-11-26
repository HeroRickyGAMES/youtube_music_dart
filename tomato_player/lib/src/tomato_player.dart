import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'audio_device.dart';
import 'tomato_media.dart';
import 'tomato_player_state.dart';

/// Controlador do player nativo.
///
/// Uma única instância nativa é compartilhada por todos os [TomatoPlayer]
/// (o app usa apenas um por vez). Chame [create] uma vez para obter o id da
/// textura e [disposePlayer] ao sair da tela de player.
class TomatoPlayer extends ChangeNotifier {
  TomatoPlayer({MethodChannel? channel})
      : _channel =
            channel ?? const MethodChannel('br.com.tomatos/tomato_player') {
    _channel.setMethodCallHandler(_onMethodCall);
  }

  final MethodChannel _channel;

  TomatoPlayerState _state = const TomatoPlayerState();
  TomatoPlayerState get state => _state;

  int? _textureId;
  int? get textureId => _textureId;

  /// Prepara o motor nativo e a textura.
  ///
  /// Deve ser chamado uma vez antes do [open]. Retorna o id a usar no widget
  /// [Texture] (null se o motor ainda não criou textura).
  Future<int?> create() async {
    final result = await _channel.invokeMapMethod<String, dynamic>('create');
    final textureId = result?['textureId'] as int?;
    _textureId = textureId;
    _setState(state.copyWith(state: TomatoPlaybackState.idle));
    return textureId;
  }

  /// Carrega (abre) a mídia.
  Future<void> open(TomatoMedia media) async {
    _setState(state.copyWith(
      state: TomatoPlaybackState.loading,
      position: Duration.zero,
      duration: Duration.zero,
      completed: false,
      error: null,
      errorCode: null,
    ));
    await _channel.invokeMethod('open', <String, dynamic>{
      'uri': media.uri,
      'httpHeaders': media.httpHeaders,
      'options': media.options,
    });
  }

  Future<void> play() => _channel.invokeMethod('play');

  Future<void> pause() => _channel.invokeMethod('pause');

  Future<void> seek(Duration position) => _channel.invokeMethod(
        'seek',
        <String, dynamic>{'positionMs': position.inMilliseconds},
      );

  /// Ajusta uma propriedade do motor (ex.: `volume`, `speed`).
  Future<void> setProperty(String name, Object value) =>
      _channel.invokeMethod('setProperty', <String, dynamic>{
        'name': name,
        'value': value,
      });

  /// Define o volume do motor (0-100).
  Future<void> setVolume(double value) =>
      setProperty('volume', value.clamp(0, 100).toDouble());

  /// Liga/desliga o mute do motor.
  Future<void> setMuted(bool value) => setProperty('mute', value);

  /// Escolhe o dispositivo de saida de audio.
  ///
  /// [name] e o identificador exato devolvido por [listAudioDevices]; `auto`
  /// devolve a escolha ao mpv.
  Future<void> setAudioDevice(String name) =>
      setProperty('audio-device', name);

  /// Lista os dispositivos de saida de audio disponiveis.
  ///
  /// Tolerante a plataformas sem o metodo: devolve lista vazia em vez de estourar,
  /// e a UI simplesmente esconde o seletor.
  Future<List<AudioDevice>> listAudioDevices() async {
    try {
      final result = await _channel.invokeListMethod<Object?>('listAudioDevices');
      if (result == null) return const <AudioDevice>[];
      return result
          .whereType<Map<Object?, Object?>>()
          .map((m) => AudioDevice(
                name: m['name']?.toString() ?? '',
                description: m['description']?.toString() ?? '',
              ))
          .where((d) => d.name.isNotEmpty)
          .toList();
    } on MissingPluginException {
      return const <AudioDevice>[];
    } on PlatformException {
      return const <AudioDevice>[];
    }
  }

  /// Limita o tamanho do alvo do render por software.
  ///
  /// O render do motor é por software: a cada frame o mpv converte YUV->RGB no
  /// buffer informado, e no tamanho nativo do stream isso custa caro — num 4K
  /// são 8 megapixels convertidos para exibir um widget de 640x360.
  ///
  /// Passar o tamanho que o widget realmente ocupa mantém a imagem igual na
  /// tela e corta esse trabalho. O aspecto é preservado: o motor escala pelo
  /// menor lado. [width] ou [height] <= 0 volta ao tamanho nativo.
  /// Tolerante a plataformas sem o metodo: onde ele nao existe, o motor simplesmente
  /// continua renderizando no tamanho nativo, que e o comportamento antigo.
  Future<void> setOutputSize(int width, int height) async {
    try {
      await _channel.invokeMethod('setOutputSize', <String, dynamic>{
        'width': width <= 0 ? 0 : width,
        'height': height <= 0 ? 0 : height,
      });
    } on MissingPluginException {
      // Plataforma sem suporte: segue no tamanho nativo.
    }
  }

  /// Libera o motor nativo e a textura.
  Future<void> disposePlayer() async {
    try {
      await _channel.invokeMethod('disposePlayer');
    } on PlatformException {
      // o plugin pode já ter sido destruído junto com a engine; ignora.
    }
    _textureId = null;
    _setState(const TomatoPlayerState());
  }

  /// Diagnóstico: inspeciona o buffer nativo mais recente (somente Linux).
  ///
  /// Distingue "mpv não produziu frame" de "mpv produziu mas o Flutter não
  /// mostra": se `framesRendered > 0` e `nonBlack` ~ `sampled` (ou seja, o
  /// buffer tem pixels de vídeo), o problema está no upload/composição; se
  /// `framesRendered == 0` ou o buffer está preto, é o motor de render SW.
  Future<Map<String, dynamic>?> debugFrame() async {
    try {
      final result =
          await _channel.invokeMapMethod<String, dynamic>('debugFrame');
      return result;
    } on PlatformException {
      return null;
    }
  }

  Future<dynamic> _onMethodCall(MethodCall call) async {
    if (call.method == 'state') {
      final args = call.arguments;
      if (args is Map) {
        _onNativeState(args.cast<Object?, Object?>());
      }
    }
    return null;
  }

  void _onNativeState(Map<Object?, Object?> m) {
    final state = _parseState(m);
    _setState(state);
  }

  TomatoPlayerState _parseState(Map<Object?, Object?> m) {
    String? str(Object? key) => m[key]?.toString();

    final state = switch (str('state')) {
      'loading' => TomatoPlaybackState.loading,
      'buffering' => TomatoPlaybackState.buffering,
      'playing' => TomatoPlaybackState.playing,
      'paused' => TomatoPlaybackState.paused,
      'ended' => TomatoPlaybackState.ended,
      'error' => TomatoPlaybackState.error,
      _ => TomatoPlaybackState.idle,
    };

    return TomatoPlayerState(
      state: state,
      position: Duration(milliseconds: _asInt(m['positionMs']) ?? 0),
      duration: Duration(milliseconds: _asInt(m['durationMs']) ?? 0),
      bufferingPercentage: _asDouble(m['bufferingPercentage']) ?? 0,
      completed: (m['completed'] as bool?) ?? false,
      videoWidth: _asInt(m['videoWidth']) ?? 0,
      videoHeight: _asInt(m['videoHeight']) ?? 0,
      volume: _asDouble(m['volume']) ?? 100,
      muted: (m['muted'] as bool?) ?? false,
      hasAudio: (m['hasAudio'] as bool?) ?? false,
      currentAo: str('currentAo') ?? '',
      audioDevice: str('audioDevice') ?? '',
      error: str('error'),
      errorCode: str('errorCode'),
      dbgFrames: _asInt(m['dbgFrames']) ?? 0,
      dbgCopies: _asInt(m['dbgCopies']) ?? 0,
      dbgUpdates: _asInt(m['dbgUpdates']) ?? 0,
      dbgLogs: m['dbgLogs'] is List
          ? (m['dbgLogs'] as List).whereType<String>().toList()
          : const <String>[],
    );
  }

  void _setState(TomatoPlayerState next) {
    if (next == _state) return;
    _state = next;
    notifyListeners();
  }

  static int? _asInt(Object? v) => v is int ? v : (v is num ? v.toInt() : null);

  static double? _asDouble(Object? v) =>
      v is double ? v : (v is num ? v.toDouble() : null);

  @override
  void dispose() {
    _channel.setMethodCallHandler(null);
    super.dispose();
  }
}