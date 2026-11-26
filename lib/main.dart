import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'src/api/youtube_music_api.dart';
import 'src/auth/session_store.dart';
import 'src/player/audio_handler.dart';
import 'src/player/player_controller.dart';
import 'src/state/settings_store.dart';
import 'src/ui/app_shell.dart';
import 'src/ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Monta tudo com os valores padrão e chama runApp imediatamente.
  // No Linux o runner nativo só exibe a janela quando o Flutter desenha o
  // primeiro frame: qualquer await antes do runApp deixa o app sem janela.
  final settings = SettingsStore();
  final session = SessionStore();
  final api = YouTubeMusicApi();
  final handler = MusicAudioHandler(cookies: session.cookies);
  final player = PlayerController(
    handler: handler,
    api: api,
    settings: settings,
  );

  runApp(MusicApp(api: api, session: session, settings: settings, player: player));

  // Rede e áudio são iniciados em segundo plano, sem bloquear a interface.
  unawaited(_initialize(settings, session, api, handler));
}

Future<void> _initialize(
  SettingsStore settings,
  SessionStore session,
  YouTubeMusicApi api,
  MusicAudioHandler handler,
) async {
  await settings.load();

  // Reaplica as preferências lidas do disco no motor de áudio.
  handler.updateSkipSettings(
    skipAds: settings.skipAds,
    skipIntros: settings.skipIntros,
    skipSponsor: settings.skipSponsor,
    categories: settings.sponsorCategories,
    fixedIntroSeconds: settings.fixedIntroSeconds,
    quality: settings.quality,
  );

  await session.load();

  try {
    await api.initialize(
      cookies: session.cookies,
      brandAccountId: session.brandAccountId,
      authUser: session.authUser,
      language: settings.language,
      region: settings.region,
    );
  } catch (error) {
    debugPrint('Falha ao iniciar a API: $error');
  }

  try {
    await initAudioService(cookies: session.cookies, handler: handler);
  } catch (error) {
    debugPrint('Falha ao iniciar o serviço de áudio: $error');
    await handler.initialize();
  }
}

class MusicApp extends StatelessWidget {
  const MusicApp({
    super.key,
    required this.api,
    required this.session,
    required this.settings,
    required this.player,
  });

  final YouTubeMusicApi api;
  final SessionStore session;
  final SettingsStore settings;
  final PlayerController player;

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        Provider<YouTubeMusicApi>.value(value: api),
        ChangeNotifierProvider<SessionStore>.value(value: session),
        ChangeNotifierProvider<SettingsStore>.value(value: settings),
        ChangeNotifierProvider<PlayerController>.value(value: player),
      ],
      child: MaterialApp(
        title: 'YouTube Music',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(),
        home: const AppShell(),
      ),
    );
  }
}
