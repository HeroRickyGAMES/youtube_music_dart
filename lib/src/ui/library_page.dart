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

class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key});

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  Future<List<HomeSection>>? _future;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    final session = context.read<SessionStore>();
    if (!session.isLoggedIn) {
      _future = null;
      return;
    }
    _future = context.read<YouTubeMusicApi>().library();
  }

  void _openItem(HomeSection section, int index) {
    final item = section.items[index];
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
      final allTracks =
          section.items.where((entry) => entry.isPlayable).toList();
      final trackIndex =
          allTracks.indexWhere((entry) => entry.videoId == item.videoId);
      context.read<PlayerController>().playCollection(
            allTracks,
            trackIndex < 0 ? 0 : trackIndex,
            queueTitle: section.title,
          );
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<SessionStore>();
    if (!session.isLoggedIn) {
      return Scaffold(
        appBar: AppBar(title: const Text('Biblioteca')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.library_music_outlined,
                    size: 54, color: AppColors.textSecondary),
                const SizedBox(height: 16),
                const Text(
                  'Sua biblioteca do YouTube Music',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Entre com uma conta Google para ver músicas curtidas, '
                  'playlists e artistas.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: AppColors.textSecondary, height: 1.4),
                ),
                const SizedBox(height: 22),
                FilledButton.icon(
                  onPressed: () async {
                    await Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => const LoginPage(),
                    ));
                    if (mounted) {
                      setState(_load);
                    }
                  },
                  icon: const Icon(Icons.login),
                  label: const Text('Entrar com Google'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    _future ??= context.read<YouTubeMusicApi>().library();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Biblioteca'),
        actions: [
          IconButton(
            tooltip: 'Atualizar',
            onPressed: () => setState(_load),
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: 'Conta',
            onPressed: () async {
              await Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => const LoginPage(),
              ));
              if (mounted) setState(_load);
            },
            icon: const Icon(Icons.person_outline),
          ),
        ],
      ),
      body: FutureBuilder<List<HomeSection>>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const LoadingView(label: 'Carregando sua biblioteca…');
          }
          final sections = snapshot.data ?? const <HomeSection>[];
          return ListView(
            padding: const EdgeInsets.only(bottom: 130),
            children: [
              _AccountHeader(
                name: session.account?.name ?? 'Sua conta',
                handle: session.account?.handle ?? '',
                avatar: session.account?.avatarUrl,
              ),
              if (snapshot.hasError)
                Padding(
                  padding: const EdgeInsets.all(20),
                  child: ErrorView(
                    message: snapshot.error.toString(),
                    onRetry: () => setState(_load),
                  ),
                ),
              if (sections.isEmpty && snapshot.connectionState == ConnectionState.done)
                const Padding(
                  padding: EdgeInsets.all(36),
                  child: Center(
                    child: Text(
                      'Ainda não há itens na biblioteca.\n'
                      'Curta músicas no YouTube Music para vê-las aqui.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: AppColors.textSecondary),
                    ),
                  ),
                ),
              ...sections.map(
                (section) => SectionRow(
                  section: section,
                  onItemTap: (item) {
                    final index = section.items.indexOf(item);
                    _openItem(section, index < 0 ? 0 : index);
                  },
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _AccountHeader extends StatelessWidget {
  const _AccountHeader({
    required this.name,
    required this.handle,
    this.avatar,
  });

  final String name;
  final String handle;
  final String? avatar;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Row(
        children: [
          CircleAvatar(
            radius: 30,
            backgroundColor: AppColors.surfaceHigh,
            backgroundImage: avatar == null ? null : NetworkImage(avatar!),
            child: avatar == null ? const Icon(Icons.person, size: 30) : null,
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name,
                    style: const TextStyle(
                        fontSize: 20, fontWeight: FontWeight.w700)),
                if (handle.isNotEmpty)
                  Text(handle,
                      style: const TextStyle(
                          color: AppColors.textSecondary, fontSize: 12)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
