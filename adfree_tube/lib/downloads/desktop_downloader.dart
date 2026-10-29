import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'download_job.dart';
import 'downloader.dart';
import 'yt_dlp_args.dart';

/// Runs the yt-dlp installed on the computer (on macOS: `brew install yt-dlp
/// ffmpeg deno`), one download at a time, and saves to
/// ~/Downloads/AdFree Tube.
///
/// The macOS app isn't sandboxed (see macos/Runner/*.entitlements), because
/// a sandboxed app can't run programs it didn't ship with.
class DesktopDownloader extends Downloader {
  /// Where finished files go.
  final String outputDir;

  /// Folders searched for yt-dlp, ffmpeg and deno, before PATH. Apps opened
  /// from Finder get a short PATH without Homebrew's folders.
  final List<String> toolDirs;

  DesktopDownloader({String? outputDir, List<String>? toolDirs})
    : outputDir = outputDir ?? _defaultOutputDir(),
      toolDirs = toolDirs ?? const ['/opt/homebrew/bin', '/usr/local/bin'];

  static String _defaultOutputDir() {
    final home = Platform.environment['HOME'] ?? Directory.systemTemp.path;
    return '$home/Downloads/AdFree Tube';
  }

  final List<DownloadJob> _jobs = [];
  final Map<int, DownloadRequest> _requests = {};
  final Set<int> _cancelled = {};
  Process? _process;
  int? _runningId;
  int _nextId = 1;
  bool _working = false;

  @override
  List<DownloadJob> get jobs => List.unmodifiable(_jobs);

  @override
  String get saveLocation => outputDir;

  /// PATH with [toolDirs] in front, so yt-dlp finds ffmpeg and deno.
  Map<String, String> get _environment {
    final path = Platform.environment['PATH'] ?? '';
    return {
      'PATH': [...toolDirs, path].where((p) => p.isNotEmpty).join(':'),
    };
  }

  /// The full path of [name], or null if it isn't installed.
  String? findTool(String name) {
    for (final dir in _environment['PATH']!.split(':')) {
      if (dir.isEmpty) continue;
      final file = File('$dir/$name');
      if (file.existsSync()) return file.path;
    }
    return null;
  }

  static const _installHint =
      'yt-dlp isn\'t installed. In Terminal run: brew install yt-dlp ffmpeg deno';

  @override
  Future<String> engineStatus() async {
    final ytDlp = findTool('yt-dlp');
    if (ytDlp == null) return _installHint;
    final missing = [if (findTool('ffmpeg') == null) 'ffmpeg'];
    try {
      final r = await Process.run(ytDlp, [
        '--version',
      ], environment: _environment);
      final version = (r.stdout as String).trim();
      return [
        'yt-dlp $version',
        if (missing.isNotEmpty)
          '${missing.join(', ')} is missing (brew install ${missing.join(' ')}), '
              'so videos above 720p and MP3s won\'t work',
      ].join(' · ');
    } catch (e) {
      return 'yt-dlp could not run: $e';
    }
  }

  @override
  Future<String> updateEngine() async {
    final ytDlp = findTool('yt-dlp');
    if (ytDlp == null) return _installHint;
    // Homebrew's yt-dlp can't update itself; brew does it.
    final brew = findTool('brew');
    final ProcessResult r;
    if (ytDlp.contains('/homebrew/') ||
        ytDlp.contains('/Cellar/') ||
        (brew != null &&
            File(ytDlp).resolveSymbolicLinksSync().contains('/Cellar/'))) {
      if (brew == null) {
        return 'yt-dlp came from Homebrew; run brew upgrade yt-dlp';
      }
      r = await Process.run(brew, [
        'upgrade',
        'yt-dlp',
      ], environment: _environment);
    } else {
      r = await Process.run(ytDlp, ['-U'], environment: _environment);
    }
    final out = '${r.stdout}\n${r.stderr}'.trim();
    if (r.exitCode != 0) return cleanYtDlpError(out, 'Update failed');
    final lines = out.split('\n').where((l) => l.trim().isNotEmpty);
    return lines.isEmpty ? 'yt-dlp is up to date.' : lines.last.trim();
  }

  @override
  Future<int> enqueue(DownloadRequest request) async {
    final id = _nextId++;
    _requests[id] = request;
    _jobs.add(
      DownloadJob(
        id: id,
        url: request.url,
        title: request.title,
        kind: request.kind,
      ),
    );
    notifyListeners();
    _work();
    return id;
  }

  @override
  Future<void> cancel(int id) async {
    final job = _job(id);
    if (job == null || job.isFinished) return;
    _cancelled.add(id);
    if (_runningId == id) {
      // SIGINT lets yt-dlp stop its ffmpeg; kill it if it doesn't stop.
      final process = _process;
      process?.kill(ProcessSignal.sigint);
      Timer(
        const Duration(seconds: 5),
        () => process?.kill(ProcessSignal.sigkill),
      );
    } else {
      _update(
        id,
        (j) => j.copyWith(state: DownloadState.cancelled, detail: ''),
      );
    }
  }

  @override
  Future<void> retry(int id) async {
    final job = _job(id);
    if (job == null ||
        !(job.state == DownloadState.failed ||
            job.state == DownloadState.cancelled)) {
      return;
    }
    _cancelled.remove(id);
    _update(
      id,
      (j) => j.copyWith(state: DownloadState.queued, progress: 0, detail: ''),
    );
    _work();
  }

  @override
  Future<void> remove(int id) async {
    await cancel(id);
    _jobs.removeWhere((j) => j.id == id);
    _requests.remove(id);
    notifyListeners();
  }

  @override
  Future<void> clearFinished() async {
    final finished = _jobs.where((j) => j.isFinished).map((j) => j.id).toSet();
    _jobs.removeWhere((j) => finished.contains(j.id));
    finished.forEach(_requests.remove);
    notifyListeners();
  }

  @override
  Future<bool> open(DownloadJob job) async {
    final path = job.savedPath;
    if (path == null || !File(path).existsSync()) return false;
    final ProcessResult r;
    if (Platform.isMacOS) {
      r = await Process.run('open', ['-R', path]);
    } else {
      r = await Process.run('xdg-open', [File(path).parent.path]);
    }
    return r.exitCode == 0;
  }

  DownloadJob? _job(int id) {
    for (final j in _jobs) {
      if (j.id == id) return j;
    }
    return null;
  }

  void _update(int id, DownloadJob Function(DownloadJob) change) {
    final i = _jobs.indexWhere((j) => j.id == id);
    if (i < 0) return;
    _jobs[i] = change(_jobs[i]);
    notifyListeners();
  }

  Future<void> _work() async {
    if (_working) return;
    _working = true;
    try {
      while (true) {
        final next = _jobs
            .where((j) => j.state == DownloadState.queued)
            .firstOrNull;
        if (next == null) break;
        await _run(next.id);
      }
    } finally {
      _working = false;
    }
  }

  static const _finalExtensions = {
    'mp4',
    'mkv',
    'webm',
    'mov',
    'mp3',
    'm4a',
    'opus',
    'ogg',
  };

  Future<void> _run(int id) async {
    final request = _requests[id];
    if (request == null) return;
    final ytDlp = findTool('yt-dlp');
    if (ytDlp == null) {
      _update(
        id,
        (j) => j.copyWith(state: DownloadState.failed, detail: _installHint),
      );
      return;
    }
    // Each download works in its own folder, so a cancelled or failed one
    // leaves no partial files next to the finished ones.
    final workDir = Directory('$outputDir/.adfree-tube-partial/$id');
    if (workDir.existsSync()) workDir.deleteSync(recursive: true);
    workDir.createSync(recursive: true);

    _update(
      id,
      (j) => j.copyWith(
        state: DownloadState.downloading,
        progress: 0,
        detail: 'Starting…',
      ),
    );
    final progress = YtDlpProgress(request.kind);
    final errors = StringBuffer();
    try {
      final process = await Process.start(
        ytDlp,
        ytDlpArguments(request, workDir.path),
        environment: _environment,
      );
      _process = process;
      _runningId = id;
      final out = process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .forEach((line) {
            final change = progress.handle(line);
            if (change != null) _update(id, change);
          });
      final err = process.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .forEach(errors.writeln);
      final code = await process.exitCode;
      await Future.wait([out, err]);

      if (_cancelled.contains(id)) {
        _update(
          id,
          (j) => j.copyWith(state: DownloadState.cancelled, detail: ''),
        );
        return;
      }
      if (code != 0) {
        _update(
          id,
          (j) => j.copyWith(
            state: DownloadState.failed,
            detail: cleanYtDlpError(
              errors.toString(),
              'yt-dlp stopped with code $code',
            ),
          ),
        );
        return;
      }
      // The finished file is the largest one; anything else is a leftover
      // such as a cover image.
      final files =
          workDir
              .listSync()
              .whereType<File>()
              .where(
                (f) => _finalExtensions.contains(
                  f.path.split('.').last.toLowerCase(),
                ),
              )
              .toList()
            ..sort((a, b) => b.lengthSync().compareTo(a.lengthSync()));
      if (files.isEmpty) {
        _update(
          id,
          (j) => j.copyWith(
            state: DownloadState.failed,
            detail: 'yt-dlp finished but no file was made',
          ),
        );
        return;
      }
      final saved = _moveToOutput(files.first);
      _update(
        id,
        (j) => j.copyWith(
          state: DownloadState.done,
          progress: 1,
          detail: 'Saved to $saved',
          savedPath: saved,
        ),
      );
    } catch (e) {
      _update(id, (j) => j.copyWith(state: DownloadState.failed, detail: '$e'));
    } finally {
      _process = null;
      _runningId = null;
      if (workDir.existsSync()) workDir.deleteSync(recursive: true);
    }
  }

  /// Moves [file] into [outputDir], adding " (2)" and so on if the name is
  /// taken.
  String _moveToOutput(File file) {
    final name = file.uri.pathSegments.last;
    final dot = name.lastIndexOf('.');
    final base = dot > 0 ? name.substring(0, dot) : name;
    final ext = dot > 0 ? name.substring(dot) : '';
    var target = '$outputDir/$name';
    for (var n = 2; File(target).existsSync(); n++) {
      target = '$outputDir/$base ($n)$ext';
    }
    try {
      file.renameSync(target);
    } on FileSystemException {
      file.copySync(target);
      file.deleteSync();
    }
    return target;
  }
}
