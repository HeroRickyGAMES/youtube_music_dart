import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:tomato_player/tomato_player.dart' show AudioDevice;

import '../player/player_controller.dart';
import 'theme.dart';
import 'widgets.dart';

class PlayerPage extends StatefulWidget {
  const PlayerPage({super.key});

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  bool _dragging = false;
  double _dragValue = 0;
  bool _liked = false;
  double? _volume;

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PlayerController>();
    final track = player.currentTrack;
    if (track == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(
          child: Text('Nada tocando agora.',
              style: TextStyle(color: AppColors.textSecondary)),
        ),
      );
    }

    final duration = player.duration;
    final max = duration.inMilliseconds.toDouble().clamp(1.0, double.infinity);
    final position = _dragging
        ? _dragValue
        : player.position.inMilliseconds.toDouble().clamp(0.0, max);
    final artwork = track.thumbnailUrl;

    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (artwork != null)
            CachedNetworkImage(
              imageUrl: artwork,
              fit: BoxFit.cover,
              errorWidget: (_, __, ___) => Container(color: AppColors.surface),
            )
          else
            Container(color: AppColors.surface),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.black.withValues(alpha: 0.55),
                  AppColors.background.withValues(alpha: 0.92),
                  AppColors.background,
                ],
              ),
            ),
          ),
          SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final wide = constraints.maxWidth >= 760;
                final content = wide
                    ? Row(
                        children: [
                          Expanded(
                            flex: 5,
                            child: Center(
                              child: Artwork(
                                url: artwork,
                                size: constraints.maxWidth * 0.34,
                                radius: 14,
                              ),
                            ),
                          ),
                          Expanded(
                            flex: 6,
                            child: _Controls(
                              player: player,
                              liked: _liked,
                              onLike: () {
                                setState(() => _liked = !_liked);
                                player.setLiked(_liked);
                              },
                              onSeekStart: () {
                                setState(() {
                                  _dragging = true;
                                  _dragValue = position;
                                });
                              },
                              onSeekChanged: (value) =>
                                  setState(() => _dragValue = value),
                              onSeekEnd: (value) {
                                setState(() => _dragging = false);
                                player.seek(Duration(milliseconds: value.round()));
                              },
                              position: position,
                              max: max,
                              duration: duration,
                              volume: _volume ?? player.volume,
                              onVolume: (value) {
                                setState(() => _volume = value);
                                player.setVolume(value);
                              },
                              onQueue: () => _showQueue(context, player),
                              onAudioDevice: () =>
                                  _showAudioDevices(context, player),
                            ),
                          ),
                        ],
                      )
                    : Column(
                        children: [
                          Row(
                            children: [
                              IconButton(
                                onPressed: () => Navigator.of(context).pop(),
                                icon: const Icon(Icons.keyboard_arrow_down,
                                    size: 30),
                              ),
                              const Spacer(),
                              IconButton(
                                tooltip: 'Fila',
                                onPressed: () => _showQueue(context, player),
                                icon: const Icon(Icons.queue_music),
                              ),
                              IconButton(
                                tooltip: 'Saída de áudio',
                                onPressed: () =>
                                    _showAudioDevices(context, player),
                                icon: const Icon(Icons.speaker),
                              ),
                            ],
                          ),
                          const Spacer(),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 32),
                            child: Artwork(
                              url: artwork,
                              size: constraints.maxWidth - 80 > 420
                                  ? 420
                                  : constraints.maxWidth - 80,
                              radius: 12,
                            ),
                          ),
                          const Spacer(),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 26),
                            child: _Controls(
                              player: player,
                              liked: _liked,
                              onLike: () {
                                setState(() => _liked = !_liked);
                                player.setLiked(_liked);
                              },
                              onSeekStart: () {
                                setState(() {
                                  _dragging = true;
                                  _dragValue = position;
                                });
                              },
                              onSeekChanged: (value) =>
                                  setState(() => _dragValue = value),
                              onSeekEnd: (value) {
                                setState(() => _dragging = false);
                                player.seek(Duration(milliseconds: value.round()));
                              },
                              position: position,
                              max: max,
                              duration: duration,
                              volume: _volume ?? player.volume,
                              onVolume: (value) {
                                setState(() => _volume = value);
                                player.setVolume(value);
                              },
                              onQueue: () => _showQueue(context, player),
                              onAudioDevice: () =>
                                  _showAudioDevices(context, player),
                            ),
                          ),
                          const SizedBox(height: 20),
                        ],
                      );
                return Stack(
                  children: [
                    content,
                    if (wide)
                      SafeArea(
                        child: Align(
                          alignment: Alignment.topLeft,
                          child: Padding(
                            padding: const EdgeInsets.all(6),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  tooltip: 'Minimizar player',
                                  onPressed: () =>
                                      Navigator.of(context).pop(),
                                  icon: const Icon(
                                    Icons.keyboard_arrow_down,
                                    size: 30,
                                  ),
                                ),
                                IconButton(
                                  tooltip: 'Fila',
                                  onPressed: () =>
                                      _showQueue(context, player),
                                  icon: const Icon(Icons.queue_music),
                                ),
                                IconButton(
                                  tooltip: 'Saída de áudio',
                                  onPressed: () =>
                                      _showAudioDevices(context, player),
                                  icon: const Icon(Icons.speaker),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  void _showQueue(BuildContext context, PlayerController player) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) {
        final queue = player.queue;
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.7,
          minChildSize: 0.4,
          maxChildSize: 0.92,
          builder: (context, controller) {
            return ListView.builder(
              controller: controller,
              itemCount: queue.length + 1,
              itemBuilder: (context, index) {
                if (index == 0) {
                  return Padding(
                    padding: const EdgeInsets.fromLTRB(20, 4, 20, 10),
                    child: Row(
                      children: [
                        const Text('A seguir',
                            style: TextStyle(
                                fontSize: 19, fontWeight: FontWeight.w700)),
                        const Spacer(),
                        Text('${queue.length} faixas',
                            style: const TextStyle(
                                color: AppColors.textSecondary, fontSize: 12)),
                      ],
                    ),
                  );
                }
                final item = queue[index - 1];
                final current = index - 1 == player.currentIndex;
                return ListTile(
                  leading: Artwork(
                    url: item.artUri?.toString(),
                    size: 40,
                    radius: 4,
                  ),
                  title: Text(
                    item.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: current ? AppColors.accent : AppColors.textPrimary,
                      fontSize: 13.5,
                    ),
                  ),
                  subtitle: Text(
                    item.artist ?? '',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: AppColors.textSecondary, fontSize: 11.5),
                  ),
                  trailing: item.duration == null
                      ? null
                      : Text(formatDuration(item.duration),
                          style: const TextStyle(
                              color: AppColors.textSecondary, fontSize: 11.5)),
                  onTap: () {
                    player.playQueueIndex(index - 1);
                    Navigator.pop(context);
                  },
                );
              },
            );
          },
        );
      },
    );
  }

  Future<void> _showAudioDevices(
      BuildContext context, PlayerController player) async {
    final devices = await player.audioDevices();
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Saída de áudio'),
        content: SizedBox(
          width: 380,
          child: ListView(
            shrinkWrap: true,
            children: [
              ListTile(
                leading: const Icon(Icons.settings_suggest),
                title: const Text('Automático'),
                subtitle: Text(player.currentAudioOutput),
                onTap: () {
                  player.setAudioDevice(AudioDevice.auto);
                  Navigator.pop(context);
                },
              ),
              for (final device in devices)
                ListTile(
                  leading: const Icon(Icons.speaker),
                  title: Text(device.description.isEmpty
                      ? device.name
                      : device.description),
                  subtitle: Text(device.name,
                      style: const TextStyle(fontSize: 11)),
                  onTap: () {
                    player.setAudioDevice(device.name);
                    Navigator.pop(context);
                  },
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Fechar'),
          ),
        ],
      ),
    );
  }
}

class _Controls extends StatelessWidget {
  const _Controls({
    required this.player,
    required this.liked,
    required this.onLike,
    required this.onSeekStart,
    required this.onSeekChanged,
    required this.onSeekEnd,
    required this.position,
    required this.max,
    required this.duration,
    required this.volume,
    required this.onVolume,
    required this.onQueue,
    required this.onAudioDevice,
  });

  final PlayerController player;
  final bool liked;
  final VoidCallback onLike;
  final VoidCallback onSeekStart;
  final ValueChanged<double> onSeekChanged;
  final ValueChanged<double> onSeekEnd;
  final double position;
  final double max;
  final Duration duration;
  final double volume;
  final ValueChanged<double> onVolume;
  final VoidCallback onQueue;
  final VoidCallback onAudioDevice;

  @override
  Widget build(BuildContext context) {
    final track = player.currentTrack!;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    track.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.4,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    track.subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: AppColors.textSecondary, fontSize: 14),
                  ),
                ],
              ),
            ),
            IconButton(
              onPressed: onLike,
              icon: Icon(
                liked ? Icons.favorite : Icons.favorite_border,
                color: liked ? AppColors.accent : AppColors.textSecondary,
              ),
            ),
          ],
        ),
        const SizedBox(height: 18),
        Slider(
          value: position.clamp(0.0, max),
          max: max,
          onChangeStart: (_) => onSeekStart(),
          onChanged: onSeekChanged,
          onChangeEnd: onSeekEnd,
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Row(
            children: [
              Text(formatDuration(Duration(milliseconds: position.round())),
                  style: const TextStyle(
                      color: AppColors.textSecondary, fontSize: 11)),
              const Spacer(),
              Text(formatDuration(duration),
                  style: const TextStyle(
                      color: AppColors.textSecondary, fontSize: 11)),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconButton(
              onPressed: onQueue,
              tooltip: 'Fila',
              icon: const Icon(Icons.queue_music,
                  color: AppColors.textSecondary),
            ),
            const SizedBox(width: 4),
            IconButton(
              onPressed: player.previous,
              iconSize: 38,
              icon: const Icon(Icons.skip_previous_rounded),
            ),
            const SizedBox(width: 10),
            Container(
              decoration: const BoxDecoration(
                color: AppColors.textPrimary,
                shape: BoxShape.circle,
              ),
              child: IconButton(
                onPressed: player.togglePlay,
                iconSize: 40,
                color: Colors.black,
                icon: player.buffering
                    ? const SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.4,
                          color: Colors.black,
                        ),
                      )
                    : Icon(player.playing
                        ? Icons.pause_rounded
                        : Icons.play_arrow_rounded),
              ),
            ),
            const SizedBox(width: 10),
            IconButton(
              onPressed: player.next,
              iconSize: 38,
              icon: const Icon(Icons.skip_next_rounded),
            ),
            const SizedBox(width: 4),
            IconButton(
              onPressed: onAudioDevice,
              tooltip: 'Saída de áudio',
              icon: const Icon(Icons.speaker,
                  color: AppColors.textSecondary),
            ),
          ],
        ),
        const SizedBox(height: 14),
        Row(
          children: [
            Icon(
              volume == 0 ? Icons.volume_off : Icons.volume_down,
              size: 20,
              color: AppColors.textSecondary,
            ),
            Expanded(
              child: Slider(
                value: volume.clamp(0, 100),
                max: 100,
                onChanged: onVolume,
              ),
            ),
            Icon(Icons.volume_up, size: 20, color: AppColors.textSecondary),
          ],
        ),
        const SizedBox(height: 6),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.auto_awesome, size: 13, color: AppColors.accent),
            const SizedBox(width: 6),
            Text(
              'Anúncios pulados · intro/patrocínio automáticos',
              style: TextStyle(
                fontSize: 11,
                color: AppColors.textSecondary.withValues(alpha: 0.9),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
