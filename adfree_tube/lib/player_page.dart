import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'playback.dart';
import 'sleep_timer.dart';
import 'widgets.dart';
import 'youtube_service.dart';

class PlayerPage extends StatefulWidget {
  final String videoId;

  const PlayerPage({super.key, required this.videoId});

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  final _c = PlaybackController.instance;

  @override
  void initState() {
    super.initState();
    _c.load(widget.videoId);
  }

  Future<void> _chooseQuality() async {
    final chosen = await showModalBottomSheet<PlaybackSource>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final s in _c.sources)
              ListTile(
                leading: Icon(
                  s.audioOnly ? Icons.headphones : Icons.high_quality,
                ),
                title: Text(s.label),
                trailing: s == _c.current ? const Icon(Icons.check) : null,
                onTap: () => Navigator.pop(context, s),
              ),
          ],
        ),
      ),
    );
    if (chosen != null && chosen != _c.current) {
      await _c.changeQuality(chosen);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _c,
      builder: (context, _) => _build(context),
    );
  }

  Widget _build(BuildContext context) {
    final theme = Theme.of(context);
    final video = _c.video;
    final wide = MediaQuery.sizeOf(context).width > 1000;

    final player = AspectRatio(
      aspectRatio: 16 / 9,
      child: Container(
        color: Colors.black,
        child: _c.error != null && _c.current == null
            ? SingleChildScrollView(
                padding: const EdgeInsets.all(12),
                child: ErrorBox(text: _c.error!),
              )
            : Stack(
                fit: StackFit.expand,
                children: [
                  Video(
                    controller: _c.videoController,
                    // Keep playing when the app is hidden or the screen locks.
                    pauseUponEnteringBackgroundMode: false,
                    resumeUponEnteringForegroundMode: false,
                  ),
                  if (_c.current?.audioOnly == true && video != null)
                    IgnorePointer(
                      child: Image.network(video.thumbnails.highResUrl,
                          fit: BoxFit.contain),
                    ),
                  if (_c.current == null || _c.switching)
                    const IgnorePointer(
                      child: Center(child: CircularProgressIndicator()),
                    ),
                ],
              ),
      ),
    );

    final details = video == null
        ? const SizedBox.shrink()
        : Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(video.title, style: theme.textTheme.titleLarge),
              const SizedBox(height: 8),
              Text(
                [
                  video.author,
                  if (video.engagement.viewCount > 0)
                    '${formatCount(video.engagement.viewCount)} views',
                  if (video.uploadDate != null)
                    MaterialLocalizations.of(context)
                        .formatMediumDate(video.uploadDate!),
                ].join(' • '),
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (_c.sources.isNotEmpty)
                    FilledButton.tonalIcon(
                      onPressed: _chooseQuality,
                      icon: const Icon(Icons.tune),
                      label: Text(_c.current?.label ?? 'Quality'),
                    ),
                  const SleepTimerButton(),
                ],
              ),
              if (_c.error != null && _c.current != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: ErrorBox(text: _c.error!),
                ),
              const SizedBox(height: 12),
              _Description(text: video.description),
            ],
          );

    final relatedList = [
      if (_c.related.isNotEmpty)
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 16, 12, 4),
          child: Text('Up next', style: theme.textTheme.titleMedium),
        ),
      for (final r in _c.related)
        VideoTile(
          thumbnail: r.thumbnails.mediumResUrl,
          title: r.title,
          subtitle: r.author,
          badge: formatDuration(r.duration),
          onTap: () => Navigator.of(context).pushReplacement(
            MaterialPageRoute(builder: (_) => PlayerPage(videoId: r.id.value)),
          ),
        ),
    ];

    return Scaffold(
      appBar: AppBar(title: Text(video?.title ?? '', maxLines: 1)),
      body: wide
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  flex: 3,
                  child: ListView(
                    padding: const EdgeInsets.all(16),
                    children: [player, const SizedBox(height: 16), details],
                  ),
                ),
                SizedBox(width: 420, child: ListView(children: relatedList)),
              ],
            )
          : ListView(
              children: [
                player,
                Padding(padding: const EdgeInsets.all(12), child: details),
                ...relatedList,
              ],
            ),
    );
  }
}

class _Description extends StatefulWidget {
  final String text;

  const _Description({required this.text});

  @override
  State<_Description> createState() => _DescriptionState();
}

class _DescriptionState extends State<_Description> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    if (widget.text.trim().isEmpty) return const SizedBox.shrink();
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => setState(() => _expanded = !_expanded),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
        ),
        child: SelectableText(
          widget.text,
          maxLines: _expanded ? null : 3,
          onTap: () => setState(() => _expanded = !_expanded),
        ),
      ),
    );
  }
}

/// Error message that can be selected, with a button to copy all of it.
class ErrorBox extends StatelessWidget {
  final String text;

  const ErrorBox({super.key, required this.text});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 4, 4, 12),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.error_outline, color: scheme.onErrorContainer),
              const SizedBox(width: 8),
              Expanded(
                child: Text('Playback error',
                    style: TextStyle(
                        color: scheme.onErrorContainer,
                        fontWeight: FontWeight.bold)),
              ),
              TextButton.icon(
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: text));
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Error copied')),
                    );
                  }
                },
                icon: const Icon(Icons.copy, size: 18),
                label: const Text('Copy'),
              ),
            ],
          ),
          SelectableText(text, style: TextStyle(color: scheme.onErrorContainer)),
        ],
      ),
    );
  }
}
