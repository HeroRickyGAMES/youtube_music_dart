import 'dart:math';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/youtube_music_api.dart';
import '../models/models.dart';
import '../player/player_controller.dart';
import 'theme.dart';
import 'widgets.dart';

class PlaylistPage extends StatefulWidget {
  const PlaylistPage({
    super.key,
    this.browseId,
    this.playlistId,
    this.fallbackTitle = '',
    this.fallbackThumbnail,
  });

  final String? browseId;
  final String? playlistId;
  final String fallbackTitle;
  final String? fallbackThumbnail;

  @override
  State<PlaylistPage> createState() => _PlaylistPageState();
}

class _PlaylistPageState extends State<PlaylistPage> {
  PlaylistPageData? _data;
  List<HomeSection> _sections = const [];
  Object? _error;
  bool _loading = true;
  bool _loadingMore = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final api = context.read<YouTubeMusicApi>();
    try {
      final data = await api.playlist(
        browseId: widget.browseId,
        playlistId: widget.playlistId,
      );
      if (data == null || (data.tracks.isEmpty && data.title.isEmpty)) {
        final id = widget.browseId;
        if (id != null) {
          final sections = await api.browseSections(id);
          if (!mounted) return;
          setState(() {
            _data = data;
            _sections = sections;
            _loading = false;
          });
          return;
        }
      }
      if (!mounted) return;
      setState(() {
        _data = data;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  Future<void> _loadMore() async {
    final data = _data;
    if (data?.continuation == null || _loadingMore) return;
    setState(() => _loadingMore = true);
    try {
      final more = await context.read<YouTubeMusicApi>().playlistContinuation(
            data!.continuation!,
            data.browseId,
          );
      if (!mounted || more == null) return;
      setState(() {
        _data = data.copyWith(
          tracks: [...data.tracks, ...more.tracks],
          continuation: more.continuation,
        );
        _loadingMore = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  Future<void> _play(int index) async {
    final data = _data;
    if (data == null || data.tracks.isEmpty) return;
    await context.read<PlayerController>().playPlaylist(data, index: index);
  }

  Future<void> _shuffle() async {
    final data = _data;
    if (data == null || data.tracks.isEmpty) return;
    final tracks = [...data.tracks]..shuffle(Random());
    await context.read<PlayerController>().playCollection(
          tracks,
          0,
          queueTitle: data.title,
        );
  }

  void _openItem(MediaItem item) {
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
      context.read<PlayerController>().playRadio(item);
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = _data;
    final title = data?.title.isNotEmpty == true
        ? data!.title
        : widget.fallbackTitle.isNotEmpty
            ? widget.fallbackTitle
            : 'Carregando…';
    final thumbnail = data?.thumbnailUrl ?? widget.fallbackThumbnail;
    final tracks = data?.tracks ?? const <MediaItem>[];

    return Scaffold(
      body: _loading
          ? const LoadingView(label: 'Carregando…')
          : _error != null
              ? ErrorView(message: _error.toString(), onRetry: _load)
              : CustomScrollView(
                  slivers: [
                    SliverAppBar(
                      pinned: true,
                      expandedHeight: 300,
                      backgroundColor: AppColors.background,
                      leading: IconButton(
                        icon: const Icon(Icons.arrow_back),
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                      flexibleSpace: FlexibleSpaceBar(
                        background: Stack(
                          fit: StackFit.expand,
                          children: [
                            if (thumbnail != null)
                              Image.network(
                                thumbnail,
                                fit: BoxFit.cover,
                                errorBuilder: (_, __, ___) =>
                                    Container(color: AppColors.surface),
                              )
                            else
                              Container(color: AppColors.surface),
                            DecoratedBox(
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                  colors: [
                                    Colors.black.withValues(alpha: 0.15),
                                    AppColors.background.withValues(alpha: 0.85),
                                    AppColors.background,
                                  ],
                                  stops: const [0, 0.65, 1],
                                ),
                              ),
                            ),
                            Positioned(
                              left: 20,
                              right: 20,
                              bottom: 16,
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  Artwork(
                                    url: thumbnail,
                                    size: 132,
                                    radius: 10,
                                  ),
                                  const SizedBox(width: 16),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text(
                                          title,
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            fontSize: 26,
                                            fontWeight: FontWeight.w800,
                                            letterSpacing: -0.5,
                                          ),
                                        ),
                                        if (data != null &&
                                            data.subtitle.isNotEmpty) ...[
                                          const SizedBox(height: 6),
                                          Text(
                                            data.subtitle,
                                            maxLines: 2,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(
                                              color: AppColors.textSecondary,
                                              fontSize: 12.5,
                                            ),
                                          ),
                                        ],
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    if (tracks.isNotEmpty)
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                          child: Row(
                            children: [
                              FilledButton.icon(
                                style: FilledButton.styleFrom(
                                  backgroundColor: AppColors.textPrimary,
                                  foregroundColor: Colors.black,
                                ),
                                onPressed: () => _play(0),
                                icon: const Icon(Icons.play_arrow_rounded),
                                label: const Text('Tocar'),
                              ),
                              const SizedBox(width: 10),
                              OutlinedButton.icon(
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: AppColors.textPrimary,
                                  side: const BorderSide(color: Colors.white24),
                                ),
                                onPressed: _shuffle,
                                icon: const Icon(Icons.shuffle, size: 18),
                                label: const Text('Aleatório'),
                              ),
                            ],
                          ),
                        ),
                      ),
                    if (tracks.isNotEmpty)
                      SliverList.builder(
                        itemCount: tracks.length,
                        itemBuilder: (context, index) {
                          final item = tracks[index];
                          return TrackTile(
                            item: item,
                            index: index + 1,
                            onTap: () => _play(index),
                          );
                        },
                      )
                    else
                      ..._sections.map(
                        (section) => SliverToBoxAdapter(
                          child: SectionRow(
                            section: section,
                            onItemTap: _openItem,
                          ),
                        ),
                      ),
                    if (data?.continuation != null)
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.all(20),
                          child: Center(
                            child: _loadingMore
                                ? const CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: AppColors.accent,
                                  )
                                : TextButton(
                                    onPressed: _loadMore,
                                    child: const Text('Carregar mais'),
                                  ),
                          ),
                        ),
                      ),
                    const SliverToBoxAdapter(child: SizedBox(height: 120)),
                  ],
                ),
    );
  }
}
