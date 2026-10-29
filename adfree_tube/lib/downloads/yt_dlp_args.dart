import 'download_job.dart';

/// The yt-dlp command-line options for one download, used by the Mac (and
/// other desktop) downloader. The Android side builds the same list in
/// Kotlin (android/.../downloads/YtDlp.kt); keep the two in step. Both are
/// adapted from the YT Downloader apps in this repo.
List<String> ytDlpArguments(DownloadRequest request, String outputDir) {
  final args = <String>[
    '--newline',
    '--no-playlist',
    '--color',
    'never',
    '--no-mtime',
    '--windows-filenames',
    '--progress',
    '--progress-template',
    'download:PROG|%(progress.status)s|%(progress._percent_str)s|%(progress._speed_str)s|%(progress._eta_str)s',
    '--progress-template',
    'postprocess:PP|%(progress.status)s|%(progress.postprocessor)s',
    '-P',
    outputDir,
    '-o',
    '%(title).150B.%(ext)s',
  ];
  switch (request.kind) {
    case DownloadKind.video:
      final sort = [
        if (request.maxHeight != null) 'res:${request.maxHeight}',
        'vcodec:h264',
        'ext:mp4:m4a',
      ];
      args.addAll([
        '-f',
        'bv*+ba/b',
        '-S',
        sort.join(','),
        '--merge-output-format',
        'mp4',
        '--embed-metadata',
      ]);
    case DownloadKind.audio:
      args.addAll([
        '-f',
        'ba/b',
        '-x',
        '--audio-format',
        'mp3',
        '--audio-quality',
        '${request.audioKbps}K',
        '--embed-metadata',
        '--embed-thumbnail',
      ]);
  }
  args.add(request.url);
  return args;
}

/// Turns yt-dlp's error output into one readable line.
String cleanYtDlpError(String raw, String fallback) {
  final lines = raw
      .split('\n')
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty)
      .toList();
  final error = lines.lastWhere(
    (l) => l.startsWith('ERROR:'),
    orElse: () => '',
  );
  final text = error.isNotEmpty
      ? error.substring('ERROR:'.length).trim()
      : (lines.isNotEmpty ? lines.last : fallback);
  return text.length > 400 ? text.substring(0, 400) : text;
}

/// Reads yt-dlp's progress lines (see the templates in [ytDlpArguments])
/// for one download. Ported from the Android app's ProgressParser.
class YtDlpProgress {
  final DownloadKind kind;
  int _pass = 0;
  double _last = 0;

  YtDlpProgress(this.kind);

  /// Returns how to change the job for [line], or null if the line isn't
  /// a progress line.
  DownloadJob Function(DownloadJob)? handle(String line) {
    final text = line.trim();
    if (text.startsWith('PROG|')) {
      final parts = text.split('|').map((p) => p.trim()).toList();
      if (parts.length < 5) return null;
      final status = parts[1],
          percent = parts[2],
          speed = parts[3],
          eta = parts[4];
      if (status == 'finished') {
        _last = 1;
        return (j) => j.copyWith(
          state: DownloadState.downloading,
          progress: 1,
          detail: 'Finishing…',
        );
      }
      final value = double.tryParse(percent.replaceAll('%', ''));
      if (value != null) {
        final v = value / 100;
        // A video download is two passes (video, then audio), so dropping
        // back to 0 is expected.
        if (v < _last - 0.5) _pass++;
        _last = v.clamp(0, 1).toDouble();
      }
      final bits = [
        if (kind == DownloadKind.video) _pass == 0 ? 'Video' : 'Audio',
        percent,
        if (_usable(speed)) speed,
        if (_usable(eta)) 'ETA $eta',
      ];
      final p = _last;
      final detail = bits.join(' · ');
      return (j) => j.copyWith(
        state: DownloadState.downloading,
        progress: p,
        detail: detail,
      );
    }
    if (text.startsWith('PP|')) {
      final parts = text.split('|');
      final name = parts.length > 2 ? parts[2].trim() : '';
      final label = _describe(name);
      return (j) => j.copyWith(state: DownloadState.processing, detail: label);
    }
    return null;
  }

  static bool _usable(String s) =>
      s.isNotEmpty && s != 'NA' && !s.startsWith('Unknown');

  static String _describe(String postprocessor) => switch (postprocessor) {
    'Merger' => 'Merging video and audio…',
    'ExtractAudio' => 'Converting to MP3…',
    'EmbedThumbnail' => 'Adding cover art…',
    'FFmpegMetadata' || 'Metadata' => 'Writing tags…',
    'MoveFiles' => 'Moving file…',
    _ => 'Processing…',
  };
}
