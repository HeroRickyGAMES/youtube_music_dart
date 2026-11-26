/// Player de vídeo nativo do Tomato.
///
/// Substitui o media_kit por um motor próprio:
///  - Linux/Windows: libmpv renderizado em software direto para uma
///    [FlPixelBufferTexture] (sem OpenGL/FBO).
///  - Android: Media3 (ExoPlayer) com FlutterTexture.
///
/// Uso básico:
///
/// ```dart
/// final player = TomatoPlayer();
/// await player.create();          // prepara a textura nativa
/// await player.open(TomatoMedia(uri: url, httpHeaders: {'Authorization': '...'}));
/// await player.play();
/// ```
library;

export 'src/audio_device.dart';
export 'src/tomato_media.dart';
export 'src/tomato_player.dart';
export 'src/tomato_player_state.dart';