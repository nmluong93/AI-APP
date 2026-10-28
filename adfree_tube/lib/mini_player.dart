import 'package:flutter/material.dart';

import 'playback.dart';
import 'player_page.dart';
import 'sleep_timer.dart';

/// Bar shown at the bottom of other screens while something is playing.
class MiniPlayer extends StatelessWidget {
  const MiniPlayer({super.key});

  @override
  Widget build(BuildContext context) {
    final c = PlaybackController.instance;
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final video = c.video;
        if (video == null) return const SizedBox.shrink();
        final theme = Theme.of(context);
        return Material(
          color: theme.colorScheme.surfaceContainerHigh,
          child: SafeArea(
            top: false,
            child: InkWell(
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                    builder: (_) => PlayerPage(videoId: video.id.value)),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  StreamBuilder<Duration>(
                    stream: c.player.stream.position,
                    builder: (context, snap) {
                      final total = c.player.state.duration.inMilliseconds;
                      final pos = (snap.data ?? Duration.zero).inMilliseconds;
                      return LinearProgressIndicator(
                        value: total > 0 ? (pos / total).clamp(0.0, 1.0) : 0,
                        minHeight: 2,
                      );
                    },
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                    child: Row(
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: Image.network(
                            video.thumbnails.mediumResUrl,
                            width: 80,
                            height: 45,
                            fit: BoxFit.cover,
                            errorBuilder: (_, _, _) =>
                                const SizedBox(width: 80, height: 45),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(video.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.titleSmall),
                              Text(video.author,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.bodySmall),
                            ],
                          ),
                        ),
                        const SleepTimerButton(compact: true),
                        StreamBuilder<bool>(
                          stream: c.player.stream.playing,
                          initialData: c.player.state.playing,
                          builder: (context, snap) => IconButton(
                            tooltip: snap.data! ? 'Pause' : 'Play',
                            icon: Icon(snap.data! ? Icons.pause : Icons.play_arrow),
                            onPressed: c.player.playOrPause,
                          ),
                        ),
                        IconButton(
                          tooltip: 'Close',
                          icon: const Icon(Icons.close),
                          onPressed: c.close,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
