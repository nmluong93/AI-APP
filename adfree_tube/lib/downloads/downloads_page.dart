import 'package:flutter/material.dart';

import 'download_job.dart';
import 'downloader.dart';

/// Asks what to download (video quality or MP3 bitrate) and adds it to the
/// queue.
Future<void> showDownloadSheet(
  BuildContext context, {
  required String url,
  required String title,
}) async {
  final request = await showModalBottomSheet<DownloadRequest>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => _DownloadSheet(url: url, title: title),
  );
  if (request == null || !context.mounted) return;
  await Downloader.instance.enqueue(request);
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(
        request.kind == DownloadKind.audio
            ? 'Downloading MP3…'
            : 'Downloading video…',
      ),
      action: SnackBarAction(
        label: 'View',
        onPressed: () =>
            Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => const DownloadsPage())),
      ),
    ),
  );
}

class _DownloadSheet extends StatefulWidget {
  final String url;
  final String title;

  const _DownloadSheet({required this.url, required this.title});

  @override
  State<_DownloadSheet> createState() => _DownloadSheetState();
}

class _DownloadSheetState extends State<_DownloadSheet> {
  DownloadKind _kind = DownloadKind.video;
  int? _height = 1080;
  int _kbps = 192;

  static const _heights = <int?>[null, 1080, 720, 480, 360];
  static const _bitrates = [320, 192, 128];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Download', style: theme.textTheme.titleLarge),
            const SizedBox(height: 4),
            Text(widget.title, maxLines: 2, overflow: TextOverflow.ellipsis),
            const SizedBox(height: 16),
            SegmentedButton<DownloadKind>(
              segments: const [
                ButtonSegment(
                  value: DownloadKind.video,
                  icon: Icon(Icons.movie),
                  label: Text('Video (MP4)'),
                ),
                ButtonSegment(
                  value: DownloadKind.audio,
                  icon: Icon(Icons.music_note),
                  label: Text('Audio (MP3)'),
                ),
              ],
              selected: {_kind},
              onSelectionChanged: (s) => setState(() => _kind = s.first),
            ),
            const SizedBox(height: 16),
            Text(
              _kind == DownloadKind.video ? 'Quality' : 'Bitrate',
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _kind == DownloadKind.video
                  ? [
                      for (final h in _heights)
                        ChoiceChip(
                          label: Text(h == null ? 'Best' : '${h}p'),
                          selected: _height == h,
                          onSelected: (_) => setState(() => _height = h),
                        ),
                    ]
                  : [
                      for (final k in _bitrates)
                        ChoiceChip(
                          label: Text('$k kbps'),
                          selected: _kbps == k,
                          onSelected: (_) => setState(() => _kbps = k),
                        ),
                    ],
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              icon: const Icon(Icons.download),
              label: const Text('Download'),
              onPressed: () => Navigator.of(context).pop(
                DownloadRequest(
                  url: widget.url,
                  title: widget.title,
                  kind: _kind,
                  maxHeight: _height,
                  audioKbps: _kbps,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The download queue: progress, cancel, retry, open.
class DownloadsPage extends StatefulWidget {
  const DownloadsPage({super.key});

  @override
  State<DownloadsPage> createState() => _DownloadsPageState();
}

class _DownloadsPageState extends State<DownloadsPage> {
  final _d = Downloader.instance;
  String _engine = '';
  bool _updating = false;

  @override
  void initState() {
    super.initState();
    _loadEngine();
  }

  Future<void> _loadEngine() async {
    final status = await _d.engineStatus();
    if (mounted) setState(() => _engine = status);
  }

  Future<void> _update() async {
    setState(() => _updating = true);
    final message = await _d.updateEngine();
    if (!mounted) return;
    setState(() => _updating = false);
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
    _loadEngine();
  }

  Future<void> _open(DownloadJob job) async {
    final ok = await _d.open(job);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Couldn\'t open it. It\'s in ${job.savedPath ?? _d.saveLocation}',
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Downloads'),
        actions: [
          IconButton(
            tooltip: 'Update yt-dlp',
            icon: _updating
                ? const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.system_update_alt),
            onPressed: _updating ? null : _update,
          ),
          IconButton(
            tooltip: 'Clear finished',
            icon: const Icon(Icons.clear_all),
            onPressed: _d.clearFinished,
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: _d,
        builder: (context, _) {
          final jobs = _d.jobs.reversed.toList();
          return ListView(
            children: [
              ListTile(
                dense: true,
                leading: const Icon(Icons.info_outline),
                title: Text(_engine.isEmpty ? 'Checking yt-dlp…' : _engine),
                subtitle: Text('Saved to ${_d.saveLocation}'),
              ),
              const Divider(height: 1),
              if (jobs.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(32),
                  child: Center(
                    child: Text(
                      'No downloads yet. Open a video and tap Download.',
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
              for (final job in jobs) _tile(job),
            ],
          );
        },
      ),
    );
  }

  Widget _tile(DownloadJob job) {
    final theme = Theme.of(context);
    final (icon, color) = switch (job.state) {
      DownloadState.done => (Icons.check_circle, Colors.green),
      DownloadState.failed => (Icons.error, theme.colorScheme.error),
      DownloadState.cancelled => (Icons.cancel, theme.disabledColor),
      _ => (
        job.kind == DownloadKind.audio ? Icons.music_note : Icons.movie,
        theme.colorScheme.primary,
      ),
    };
    final status = switch (job.state) {
      DownloadState.queued => 'Waiting…',
      DownloadState.cancelled => 'Cancelled',
      _ => job.detail,
    };
    return ListTile(
      key: ValueKey(job.id),
      leading: Icon(icon, color: color),
      title: Text(job.title, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (job.isActive)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: LinearProgressIndicator(
                value: job.state == DownloadState.processing
                    ? null
                    : job.progress,
              ),
            ),
          Text(
            '${job.kind == DownloadKind.audio ? 'MP3' : 'MP4'} · $status',
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
      onTap: job.state == DownloadState.done ? () => _open(job) : null,
      trailing: switch (job.state) {
        DownloadState.queued ||
        DownloadState.downloading ||
        DownloadState.processing => IconButton(
          tooltip: 'Cancel',
          icon: const Icon(Icons.close),
          onPressed: () => _d.cancel(job.id),
        ),
        DownloadState.failed || DownloadState.cancelled => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: 'Retry',
              icon: const Icon(Icons.refresh),
              onPressed: () => _d.retry(job.id),
            ),
            IconButton(
              tooltip: 'Remove',
              icon: const Icon(Icons.delete_outline),
              onPressed: () => _d.remove(job.id),
            ),
          ],
        ),
        DownloadState.done => IconButton(
          tooltip: 'Remove from list',
          icon: const Icon(Icons.delete_outline),
          onPressed: () => _d.remove(job.id),
        ),
      },
    );
  }
}
