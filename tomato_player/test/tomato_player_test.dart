import 'package:flutter_test/flutter_test.dart';
import 'package:tomato_player/tomato_player.dart';

void main() {
  test('estado inicial é idle', () {
    final player = TomatoPlayer();
    expect(player.state.state, TomatoPlaybackState.idle);
    expect(player.textureId, isNull);
    player.dispose();
  });
}