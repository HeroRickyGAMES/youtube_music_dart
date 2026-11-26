import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../player/player_controller.dart';
import 'theme.dart';
import 'widgets.dart';

class MiniPlayer extends StatelessWidget {
  const MiniPlayer({super.key, required this.onOpen});

  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PlayerController>();
    final track = player.currentTrack;
    if (track == null) return const SizedBox.shrink();

    final duration = player.duration;
    final progress = duration.inMilliseconds <= 0
        ? 0.0
        : (player.position.inMilliseconds / duration.inMilliseconds)
            .clamp(0.0, 1.0);

    return Material(
      color: AppColors.surface,
      child: InkWell(
        onTap: onOpen,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            LinearProgressIndicator(
              value: progress,
              minHeight: 2,
              backgroundColor: Colors.white12,
              valueColor: const AlwaysStoppedAnimation(AppColors.textPrimary),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
              child: Row(
                children: [
                  Artwork(url: track.thumbnailUrl, size: 46, radius: 5),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          track.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 13.5, fontWeight: FontWeight.w600),
                        ),
                        if (track.subtitle.isNotEmpty)
                          Text(
                            track.subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 11.5,
                                color: AppColors.textSecondary),
                          ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: player.togglePlay,
                    icon: player.buffering
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: AppColors.textPrimary,
                            ),
                          )
                        : Icon(
                            player.playing
                                ? Icons.pause_rounded
                                : Icons.play_arrow_rounded,
                            size: 28,
                          ),
                  ),
                  IconButton(
                    onPressed: player.next,
                    icon: const Icon(Icons.skip_next_rounded, size: 26),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
