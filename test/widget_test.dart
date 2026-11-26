import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:youtube_music_player_dart/src/models/models.dart';
import 'package:youtube_music_player_dart/src/ui/theme.dart';
import 'package:youtube_music_player_dart/src/ui/widgets.dart';

void main() {
  test('formatDuration renders minutes and seconds', () {
    expect(formatDuration(const Duration(seconds: 65)), '1:05');
    expect(formatDuration(const Duration(hours: 1, minutes: 2, seconds: 3)),
        '1:02:03');
    expect(formatDuration(null), '');
    expect(formatDuration(Duration.zero), '');
  });

  testWidgets('media cards fit inside a section row', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final item = MediaItem(
      id: 'album-1',
      title: 'Um titulo bem comprido que quebra em duas linhas para testar',
      subtitle: 'Artista • Album • 2024 • Mais texto no subtitulo',
      kind: MediaKind.album,
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(1.5)),
          child: Scaffold(
            body: SectionRow(
              section: HomeSection(title: 'Teste', items: [item]),
              onItemTap: (_) {},
            ),
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
  });
}
