import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:youtube_music_player_dart/src/api/youtube_music_api.dart';
import 'package:youtube_music_player_dart/src/player/stream_resolver.dart';
import 'package:youtube_music_player_dart/src/state/settings_store.dart';

void main() {
  final enabled = Platform.environment['RUN_NETWORK_TESTS'] == '1';

  test('home, search and stream resolve (network)', () async {
    final api = YouTubeMusicApi();
    await api.initialize();
    final home = await api.home();
    expect(home, isNotEmpty);
    final search = await api.search('daft punk', filter: SearchFilter.songs);
    expect(search, isNotEmpty);
    final track = search
        .expand((section) => section.items)
        .firstWhere((item) => item.videoId != null);
    final resolver = StreamResolver();
    final stream = await resolver.resolve(track.videoId!,
        quality: AudioQuality.high);
    final response = await http.get(
      stream.url,
      headers: {...stream.headers, 'Range': 'bytes=0-1023'},
    );
    expect(response.statusCode, anyOf(200, 206));
    resolver.dispose();
  }, timeout: const Timeout(Duration(minutes: 2)),
      skip: enabled ? false : 'set RUN_NETWORK_TESTS=1 to run');
}
