import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/youtube_music_api.dart';
import '../models/models.dart';
import '../player/player_controller.dart';
import 'playlist_page.dart';
import 'theme.dart';
import 'widgets.dart';

class SearchPage extends StatefulWidget {
  const SearchPage({super.key});

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  Timer? _debounce;
  List<SearchSuggestion> _suggestions = const [];
  SearchFilter _filter = SearchFilter.all;
  Future<List<HomeSection>>? _future;

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus) {
        setState(() => _suggestions = const []);
      }
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    if (value.trim().isEmpty) {
      setState(() => _suggestions = const []);
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 350), () async {
      final suggestions =
          await context.read<YouTubeMusicApi>().suggestions(value);
      if (mounted && _focus.hasFocus) {
        setState(() => _suggestions = suggestions);
      }
    });
  }

  void _search([String? query]) {
    final text = (query ?? _controller.text).trim();
    if (text.isEmpty) return;
    _controller.text = text;
    _focus.unfocus();
    setState(() {
      _suggestions = const [];
      _future = context.read<YouTubeMusicApi>().search(text, filter: _filter);
    });
  }

  void _changeFilter(SearchFilter filter) {
    setState(() {
      _filter = filter;
      if (_controller.text.trim().isNotEmpty) {
        _future =
            context.read<YouTubeMusicApi>().search(_controller.text, filter: filter);
      }
    });
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
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 12,
        title: TextField(
          controller: _controller,
          focusNode: _focus,
          textInputAction: TextInputAction.search,
          onChanged: _onChanged,
          onSubmitted: (_) => _search(),
          decoration: InputDecoration(
            hintText: 'Músicas, artistas, álbuns…',
            prefixIcon: const Icon(Icons.search, size: 20),
            suffixIcon: _controller.text.isEmpty
                ? null
                : IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: () {
                      _controller.clear();
                      setState(() {
                        _future = null;
                        _suggestions = const [];
                      });
                    },
                  ),
          ),
        ),
      ),
      body: Column(
        children: [
          SizedBox(
            height: 46,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: [
                for (final filter in SearchFilter.values)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(filter.label),
                      selected: _filter == filter,
                      onSelected: (_) => _changeFilter(filter),
                      labelStyle: TextStyle(
                        fontSize: 12.5,
                        color: _filter == filter
                            ? Colors.black
                            : AppColors.textPrimary,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (_suggestions.isNotEmpty)
            Expanded(
              child: ListView.builder(
                itemCount: _suggestions.length,
                itemBuilder: (context, index) {
                  final suggestion = _suggestions[index];
                  return ListTile(
                    dense: true,
                    leading: const Icon(Icons.search, size: 20),
                    title: Text(suggestion.text),
                    onTap: () => _search(suggestion.text),
                  );
                },
              ),
            )
          else
            Expanded(
              child: _future == null
                  ? const _SearchEmpty()
                  : FutureBuilder<List<HomeSection>>(
                      future: _future,
                      builder: (context, snapshot) {
                        if (snapshot.connectionState == ConnectionState.waiting) {
                          return const LoadingView(label: 'Buscando…');
                        }
                        if (snapshot.hasError) {
                          return ErrorView(
                            message: snapshot.error.toString(),
                            onRetry: () => _search(),
                          );
                        }
                        final sections = snapshot.data ?? const <HomeSection>[];
                        if (sections.isEmpty) {
                          return const ErrorView(
                              message: 'Nenhum resultado encontrado.');
                        }
                        return ListView.builder(
                          padding: const EdgeInsets.only(bottom: 130),
                          itemCount: sections.length,
                          itemBuilder: (context, index) {
                            final section = sections[index];
                            final isTracks = section.items.every(
                              (item) =>
                                  item.kind == MediaKind.song ||
                                  item.kind == MediaKind.video ||
                                  item.kind == MediaKind.episode,
                            );
                            if (!isTracks) {
                              return SectionRow(
                                section: section,
                                onItemTap: _openItem,
                              );
                            }
                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Padding(
                                  padding:
                                      const EdgeInsets.fromLTRB(18, 18, 18, 4),
                                  child: Text(
                                    section.title,
                                    style: const TextStyle(
                                      fontSize: 19,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                                ...section.items.asMap().entries.map(
                                      (entry) => TrackTile(
                                        item: entry.value,
                                        onTap: () => context
                                            .read<PlayerController>()
                                            .playCollection(
                                              section.items,
                                              entry.key,
                                              queueTitle: section.title,
                                            ),
                                      ),
                                    ),
                              ],
                            );
                          },
                        );
                      },
                    ),
            ),
        ],
      ),
    );
  }
}

class _SearchEmpty extends StatelessWidget {
  const _SearchEmpty();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(36),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.music_note, size: 54, color: AppColors.textSecondary),
            SizedBox(height: 16),
            Text(
              'Busque por uma música, álbum ou artista',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.textSecondary),
            ),
          ],
        ),
      ),
    );
  }
}
