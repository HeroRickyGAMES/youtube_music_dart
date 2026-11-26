import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/youtube_music_api.dart';
import '../auth/session_store.dart';
import '../models/models.dart';
import '../player/player_controller.dart';
import 'login_page.dart';
import 'playlist_page.dart';
import 'theme.dart';
import 'widgets.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  Future<List<HomeSection>>? _future;

  @override
  void initState() {
    super.initState();
    _future = context.read<YouTubeMusicApi>().home();
  }

  void _reload({bool refresh = false}) {
    setState(() {
      _future = context.read<YouTubeMusicApi>().home(refresh: refresh);
    });
  }

  void _openItem(MediaItem item) {
    final player = context.read<PlayerController>();
    if (item.isCollection) {
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => PlaylistPage(
          browseId: item.browseId,
          playlistId: item.playlistId,
          fallbackTitle: item.title,
          fallbackThumbnail: item.thumbnailUrl,
        ),
      ));
    } else if (item.isPlayable) {
      player.playRadio(item);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<SessionStore>();
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 18,
        title: Row(
          children: [
            Container(
              width: 30,
              height: 30,
              decoration: const BoxDecoration(
                color: AppColors.accent,
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.play_arrow_rounded,
                  color: Colors.white, size: 22),
            ),
            const SizedBox(width: 10),
            const Text(
              'Music',
              style: TextStyle(fontWeight: FontWeight.w700, fontSize: 20),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Atualizar',
            onPressed: () => _reload(refresh: true),
            icon: const Icon(Icons.refresh),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: InkWell(
              borderRadius: BorderRadius.circular(24),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => const LoginPage(),
              )),
              child: CircleAvatar(
                radius: 17,
                backgroundColor: AppColors.surfaceHigh,
                backgroundImage: session.account?.avatarUrl == null
                    ? null
                    : NetworkImage(session.account!.avatarUrl!),
                child: session.account?.avatarUrl == null
                    ? Icon(
                        session.isLoggedIn ? Icons.person : Icons.person_outline,
                        size: 20,
                        color: AppColors.textSecondary,
                      )
                    : null,
              ),
            ),
          ),
        ],
      ),
      body: FutureBuilder<List<HomeSection>>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const LoadingView(label: 'Carregando seu YouTube Music…');
          }
          if (snapshot.hasError) {
            return ErrorView(
              message: snapshot.error.toString(),
              onRetry: () => _reload(refresh: true),
            );
          }
          final sections = snapshot.data ?? const <HomeSection>[];
          if (sections.isEmpty) {
            return ErrorView(
              message: 'Nada apareceu aqui. Tente atualizar.',
              onRetry: () => _reload(refresh: true),
            );
          }
          return RefreshIndicator(
            color: AppColors.accent,
            onRefresh: () async => _reload(refresh: true),
            child: ListView.builder(
              padding: const EdgeInsets.only(bottom: 24),
              itemCount: sections.length,
              itemBuilder: (context, index) {
                final section = sections[index];
                return SectionRow(
                  section: section,
                  onItemTap: _openItem,
                  onMore: section.moreBrowseId == null
                      ? null
                      : () => Navigator.of(context).push(MaterialPageRoute(
                            builder: (_) => PlaylistPage(
                              browseId: section.moreBrowseId,
                              fallbackTitle: section.title,
                            ),
                          )),
                );
              },
            ),
          );
        },
      ),
    );
  }
}
