import 'dart:io';

import 'package:adfree_tube/downloads/desktop_downloader.dart';
import 'package:adfree_tube/downloads/download_job.dart';
import 'package:adfree_tube/downloads/yt_dlp_args.dart';
import 'package:flutter_test/flutter_test.dart';

/// A stand-in for yt-dlp: prints progress like the real one, then makes a
/// file in the -P folder, fails, or hangs, depending on the URL.
const _fakeYtDlp = r'''#!/bin/sh
if [ "$1" = "--version" ]; then echo 2099.01.01; exit 0; fi
dir=""; url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -P) dir="$2"; shift 2;;
    *) url="$1"; shift;;
  esac
done
case "$url" in
  *fail*) echo "ERROR: [youtube] abc: Video unavailable" >&2; exit 1;;
  *hang*) echo "PROG|downloading| 10.0%|1.0MiB/s|00:10"; trap 'exit 130' INT; while true; do sleep 0.1; done;;
esac
echo "PROG|downloading| 50.0%|1.0MiB/s|00:01"
echo "PROG|finished|100.0%|NA|NA"
echo "PP|started|Merger"
printf 'big file contents' > "$dir/My video.mp4"
printf 'x' > "$dir/My video.jpg"
exit 0
''';

void main() {
  group('ytDlpArguments', () {
    test('video asks for MP4 at the chosen height, URL last', () {
      final args = ytDlpArguments(
        const DownloadRequest(
          url: 'https://youtu.be/x',
          title: 't',
          kind: DownloadKind.video,
          maxHeight: 720,
        ),
        '/out',
      );
      expect(args.last, 'https://youtu.be/x');
      expect(args, containsAllInOrder(['-P', '/out']));
      expect(
        args,
        containsAllInOrder(['-S', 'res:720,vcodec:h264,ext:mp4:m4a']),
      );
      expect(args, containsAllInOrder(['--merge-output-format', 'mp4']));
      expect(args, contains('--no-playlist'));
      expect(args, isNot(contains('-x')));
    });

    test('best video has no height limit', () {
      final args = ytDlpArguments(
        const DownloadRequest(url: 'u', title: 't', kind: DownloadKind.video),
        '/out',
      );
      expect(args, containsAllInOrder(['-S', 'vcodec:h264,ext:mp4:m4a']));
    });

    test('audio extracts MP3 at the chosen bitrate', () {
      final args = ytDlpArguments(
        const DownloadRequest(
          url: 'u',
          title: 't',
          kind: DownloadKind.audio,
          audioKbps: 320,
        ),
        '/out',
      );
      expect(args, containsAllInOrder(['-x', '--audio-format', 'mp3']));
      expect(args, containsAllInOrder(['--audio-quality', '320K']));
      expect(args, contains('--embed-thumbnail'));
    });
  });

  test('cleanYtDlpError keeps the last ERROR line', () {
    expect(
      cleanYtDlpError(
        'WARNING: something\nERROR: [youtube] x: Sign in to confirm\n',
        'f',
      ),
      '[youtube] x: Sign in to confirm',
    );
    expect(cleanYtDlpError('just text\n', 'f'), 'just text');
    expect(cleanYtDlpError('', 'fallback'), 'fallback');
  });

  group('YtDlpProgress', () {
    const job = DownloadJob(
      id: 1,
      url: 'u',
      title: 't',
      kind: DownloadKind.video,
    );

    test('reads percent, speed and ETA, and counts the audio pass', () {
      final p = YtDlpProgress(DownloadKind.video);
      var j = p.handle('PROG|downloading| 42.5%|2.0MiB/s|00:12')!(job);
      expect(j.state, DownloadState.downloading);
      expect(j.progress, closeTo(0.425, 1e-9));
      expect(j.detail, 'Video · 42.5% · 2.0MiB/s · ETA 00:12');
      j = p.handle('PROG|downloading| 99.0%|2.0MiB/s|00:00')!(j);
      j = p.handle('PROG|downloading|  3.0%|NA|Unknown')!(j);
      expect(j.detail, 'Audio · 3.0%');
    });

    test('post-processing shows a step', () {
      final p = YtDlpProgress(DownloadKind.audio);
      final j = p.handle('PP|started|ExtractAudio')!(job);
      expect(j.state, DownloadState.processing);
      expect(j.detail, 'Converting to MP3…');
    });

    test('ignores other lines', () {
      expect(
        YtDlpProgress(DownloadKind.audio).handle('[youtube] x: Downloading'),
        isNull,
      );
    });
  });

  test('DownloadJob.fromJson reads what Android sends', () {
    final j = DownloadJob.fromJson({
      'id': 7,
      'url': 'u',
      'title': 'T',
      'kind': 'audio',
      'state': 'done',
      'progress': 1.0,
      'detail': 'Saved',
      'savedUri': 'content://media/1',
      'savedMime': 'audio/mpeg',
      'savedPath': 'Music/AdFree Tube/T.mp3',
    });
    expect(j.id, 7);
    expect(j.kind, DownloadKind.audio);
    expect(j.state, DownloadState.done);
    expect(j.isFinished, isTrue);
    expect(j.savedUri, 'content://media/1');
    expect(
      DownloadJob.fromJson({'id': 1, 'state': 'processing'}).isActive,
      isTrue,
    );
  });

  group('DesktopDownloader with a fake yt-dlp', () {
    late Directory temp;
    late DesktopDownloader d;

    setUp(() {
      temp = Directory.systemTemp.createTempSync('adfree_dl');
      final bin = Directory('${temp.path}/bin')..createSync();
      final tool = File('${bin.path}/yt-dlp')..writeAsStringSync(_fakeYtDlp);
      Process.runSync('chmod', ['+x', tool.path]);
      d = DesktopDownloader(
        outputDir: '${temp.path}/out',
        toolDirs: [bin.path],
      );
    });

    tearDown(() => temp.deleteSync(recursive: true));

    Future<DownloadJob> finished(int id) async {
      for (var i = 0; i < 200; i++) {
        final j = d.jobs.firstWhere((j) => j.id == id);
        if (j.isFinished) return j;
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      fail('download $id did not finish: ${d.jobs}');
    }

    test('saves the largest file and cleans up', () async {
      final states = <DownloadState>{};
      d.addListener(() => states.addAll(d.jobs.map((j) => j.state)));
      final id = await d.enqueue(
        const DownloadRequest(
          url: 'https://youtu.be/ok',
          title: 'My video',
          kind: DownloadKind.video,
        ),
      );
      final j = await finished(id);
      expect(j.state, DownloadState.done, reason: j.detail);
      expect(j.savedPath, '${temp.path}/out/My video.mp4');
      expect(File(j.savedPath!).readAsStringSync(), 'big file contents');
      expect(
        states,
        containsAll([DownloadState.downloading, DownloadState.processing]),
      );
      expect(
        Directory('${temp.path}/out/.adfree-tube-partial/$id').existsSync(),
        isFalse,
      );

      // A second download of the same video doesn't overwrite the first.
      final again = await finished(
        await d.enqueue(
          const DownloadRequest(
            url: 'https://youtu.be/ok',
            title: 'My video',
            kind: DownloadKind.video,
          ),
        ),
      );
      expect(again.savedPath, '${temp.path}/out/My video (2).mp4');
      expect(await d.engineStatus(), startsWith('yt-dlp 2099.01.01'));
    });

    test('shows yt-dlp\'s error, and retry runs it again', () async {
      final id = await d.enqueue(
        const DownloadRequest(
          url: 'https://youtu.be/fail',
          title: 'x',
          kind: DownloadKind.audio,
        ),
      );
      var j = await finished(id);
      expect(j.state, DownloadState.failed);
      expect(j.detail, '[youtube] abc: Video unavailable');
      await d.retry(id);
      j = await finished(id);
      expect(j.state, DownloadState.failed);
    });

    test('cancel stops a running download and runs the next one', () async {
      final hang = await d.enqueue(
        const DownloadRequest(
          url: 'https://youtu.be/hang',
          title: 'h',
          kind: DownloadKind.video,
        ),
      );
      final next = await d.enqueue(
        const DownloadRequest(
          url: 'https://youtu.be/ok',
          title: 'My video',
          kind: DownloadKind.video,
        ),
      );
      for (var i = 0; i < 100 && d.jobs.first.progress == 0; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(d.jobs.first.state, DownloadState.downloading);
      await d.cancel(hang);
      expect((await finished(hang)).state, DownloadState.cancelled);
      expect((await finished(next)).state, DownloadState.done);
      await d.clearFinished();
      expect(d.jobs, isEmpty);
    });

    test('says how to install yt-dlp when it is missing', () async {
      final none = DesktopDownloader(
        outputDir: '${temp.path}/out',
        toolDirs: const [],
      );
      if (none.findTool('yt-dlp') != null) return; // installed on this machine
      expect(await none.engineStatus(), contains('brew install yt-dlp'));
    });
  });

  // End to end with the real yt-dlp and ffmpeg, downloading a sample video
  // from a local web server. CI installs them; elsewhere it's skipped unless
  // they're installed.
  group('DesktopDownloader with the real yt-dlp', () {
    final probe = DesktopDownloader(
      toolDirs: ['${Platform.environment['HOME']}/.local/bin'],
    );
    final missing =
        probe.findTool('yt-dlp') == null || probe.findTool('ffprobe') == null;
    // CI sets REQUIRE_YTDLP so a missing tool fails instead of skipping.
    final skip = missing && Platform.environment['REQUIRE_YTDLP'] != '1'
        ? 'yt-dlp or ffmpeg is not installed'
        : null;
    late Directory temp;
    late HttpServer server;
    late DesktopDownloader d;

    setUp(() async {
      temp = Directory.systemTemp.createTempSync('adfree_dl_e2e');
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((r) async {
        final file = File('tool/download_test/sample.mp4');
        r.response.headers.contentType = ContentType('video', 'mp4');
        r.response.contentLength = file.lengthSync();
        await r.response.addStream(file.openRead());
        await r.response.close();
      });
      d = DesktopDownloader(
        outputDir: '${temp.path}/out',
        toolDirs: probe.toolDirs,
      );
    });

    tearDown(() async {
      await server.close(force: true);
      temp.deleteSync(recursive: true);
    });

    Future<Map<String, String>> probeStreams(String path) async {
      final r = await Process.run(probe.findTool('ffprobe')!, [
        '-v',
        'error',
        '-show_entries',
        'stream=codec_type,codec_name:format=format_name',
        '-of',
        'default=nw=1',
        path,
      ]);
      expect(r.exitCode, 0, reason: '${r.stderr}');
      final out = r.stdout as String;
      return {
        'codecs': RegExp(r'codec_name=(\w+)')
            .allMatches(out)
            .map((m) => m[1])
            .join(','),
        'format': RegExp(r'format_name=(\S+)').firstMatch(out)?[1] ?? '',
      };
    }

    Future<DownloadJob> download(DownloadRequest request) async {
      final id = await d.enqueue(request);
      for (var i = 0; i < 1200; i++) {
        final j = d.jobs.firstWhere((j) => j.id == id);
        if (j.isFinished) return j;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      fail('download did not finish');
    }

    test(
      'downloads the video as MP4',
      () async {
        final j = await download(
          DownloadRequest(
            url: 'http://127.0.0.1:${server.port}/sample.mp4',
            title: 'sample',
            kind: DownloadKind.video,
            maxHeight: 720,
          ),
        );
        expect(j.state, DownloadState.done, reason: j.detail);
        expect(j.savedPath, endsWith('.mp4'));
        final info = await probeStreams(j.savedPath!);
        expect(info['codecs'], allOf(contains('h264'), contains('aac')));
      },
      skip: skip,
      timeout: const Timeout(Duration(minutes: 3)),
    );

    test(
      'downloads the audio as MP3',
      () async {
        final j = await download(
          DownloadRequest(
            url: 'http://127.0.0.1:${server.port}/sample.mp4',
            title: 'sample',
            kind: DownloadKind.audio,
            audioKbps: 128,
          ),
        );
        expect(j.state, DownloadState.done, reason: j.detail);
        expect(j.savedPath, endsWith('.mp3'));
        final info = await probeStreams(j.savedPath!);
        expect(info['codecs'], 'mp3');
        expect(
          Directory('${temp.path}/out').listSync().whereType<File>(),
          hasLength(1),
        );
      },
      skip: skip,
      timeout: const Timeout(Duration(minutes: 3)),
    );
  });
}
