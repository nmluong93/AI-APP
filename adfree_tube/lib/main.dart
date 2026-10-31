import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'downloads/download_job.dart';
import 'downloads/downloader.dart';
import 'downloads/downloads_page.dart';
import 'home_page.dart';
import 'playback.dart';
import 'player_view.dart';
import 'settings.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppSettings.load();
  await PlaybackController.instance.initSystemControls();
  const testUrl = String.fromEnvironment('PLAYER_TEST_URL');
  if (testUrl.isNotEmpty) return _renderTest(testUrl);
  const downloadUrl = String.fromEnvironment('DOWNLOAD_TEST_URL');
  if (downloadUrl.isNotEmpty) return _downloadTest(downloadUrl);
  runApp(const AdFreeTubeApp());
}

/// On-device check that video inside the WebView shows up and keeps
/// playing. Built only by the `render` CI job (tool/render_test/run.sh),
/// which takes a screenshot, sends the app to the background and turns the
/// screen off, then checks the positions this logs.
Future<void> _renderTest(String url) async {
  final c = PlaybackController.instance;
  // The macOS soak test drives the app from outside (see _macSoakTest).
  if (Platform.isMacOS && Platform.environment['SOAK_TEST_LOG'] != null) {
    return _macSoakTest(c, url);
  }
  if (Platform.isAndroid &&
      !const bool.fromEnvironment('PLAYER_BG_FIX', defaultValue: true)) {
    await const MethodChannel('adfree_tube/background')
        .invokeMethod('setKeepPlaying', false);
  }
  final showSurface = ValueNotifier(true);
  runApp(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      builder: (context, child) => BackgroundVideoHost(child: child!),
      home: Scaffold(
        backgroundColor: Colors.black,
        body: ValueListenableBuilder<bool>(
          valueListenable: showSurface,
          builder: (context, show, _) =>
              show ? const VideoSurface() : const SizedBox.expand(),
        ),
      ),
    ),
  );
  c.startRenderTest();
  if (Platform.isMacOS) return _seekTest(c, url);
  await c.player.loadUrl(url);
  // Log where the video is every 3 seconds (every second for the soak test,
  // tool/soak_test), whatever the app is doing, with the duration and frame
  // counts so the soak test can follow loops and count dropped frames.
  const logMs = int.fromEnvironment('PLAYER_TEST_LOG_MS', defaultValue: 3000);
  Timer.periodic(const Duration(milliseconds: logMs), (_) async {
    try {
      final r = await c.player.controller
          .runJavaScriptReturningResult(_positionScript)
          .timeout(const Duration(seconds: 2));
      debugPrint('RENDER_TEST pos $r');
    } catch (e) {
      debugPrint('RENDER_TEST pos no-answer');
    }
  });
  await Future.delayed(const Duration(seconds: 20));
  // Leave the player screen, as when going back to search with the mini
  // player showing, then come back.
  debugPrint('RENDER_TEST PHASE left_player');
  showSurface.value = false;
  await Future.delayed(const Duration(seconds: 20));
  debugPrint('RENDER_TEST PHASE back_on_player');
  showSurface.value = true;
}

/// macOS part of the render test: checks that the video plays, and that it
/// carries on playing after seeking, including a burst of seeks like the
/// ones dragging the seek bar used to send (bug 20). Built only by the
/// `macos-render` CI job (tool/render_test/run_macos.sh), which runs the app
/// once per scenario and checks the readings this writes with seek_check.py.
///
/// The job builds the app once and picks each scenario with environment
/// variables: PLAYER_TEST_URL (the page to play), PLAYER_CANVAS (draw the
/// video through a canvas or not) and RENDER_TEST_LOG (where to write).
///
/// With PLAYER_TEST_USER=1 the app doesn't seek by itself: it logs where the
/// seek bar and Play/Pause button are, and tool/render_test/user_drive.py
/// moves and clicks the real mouse, as a user would, and logs the phases in
/// the same file. Times are then seconds since 1970, so both line up.
Future<void> _seekTest(PlaybackController c, String url) async {
  final env = Platform.environment;
  final logFile = File(env['RENDER_TEST_LOG'] ?? 'render_test.log');
  final user = env['PLAYER_TEST_USER'] == '1';
  final started = user
      ? DateTime.fromMillisecondsSinceEpoch(0)
      : DateTime.now();
  void log(String line) {
    final t = DateTime.now().difference(started).inMilliseconds / 1000;
    final text = '${t.toStringAsFixed(2)} RENDER_TEST $line';
    debugPrint(text);
    logFile.writeAsStringSync('$text\n', mode: FileMode.append, flush: true);
  }

  final canvas = env['PLAYER_CANVAS'];
  if (canvas != null) c.player.canvasVideo = canvas == 'true';
  log(
    'config url=${env['PLAYER_TEST_URL'] ?? url} canvas=${c.player.canvasVideo} '
    'pageDrawn=${c.player.pageDrawnVideo}',
  );
  await c.player.loadUrl(env['PLAYER_TEST_URL'] ?? url);

  // Where the video is every second, as the page and the app see it.
  Timer.periodic(const Duration(seconds: 1), (_) async {
    final s = c.state;
    try {
      final r = await c.player.controller
          .runJavaScriptReturningResult(
            "(function(){const v=document.querySelector('#movie_player video')||"
            "document.querySelector('video');"
            "return v?('t='+v.currentTime.toFixed(2)+' paused='+v.paused+"
            "' ready='+v.readyState+' seeking='+v.seeking):'none'})()",
          )
          .timeout(const Duration(seconds: 2));
      log(
        'pos $r buffering=${s.buffering} ad=${s.ad} '
        'd=${s.duration.inSeconds} err=${s.error}',
      );
    } catch (e) {
      log('pos no-answer');
    }
    if (user) log('ui ${_uiLayout()}');
  });

  // Wait for the video to start (YouTube can take a while, and show an ad).
  for (var i = 0; i < 60; i++) {
    final s = c.state;
    if (s.playing && !s.ad && s.position > const Duration(seconds: 1)) break;
    await Future.delayed(const Duration(seconds: 1));
  }
  log('PHASE play');
  if (user) {
    // user_drive.py does the rest, and stops the app when it is done.
    await Future.delayed(const Duration(minutes: 4));
    log('debug ${await c.player.diagnostics()}'.replaceAll('\n', ' '));
    exit(0);
  }
  await Future.delayed(const Duration(seconds: 10));

  log('PHASE seek target=60');
  await c.player.seek(const Duration(seconds: 60));
  await Future.delayed(const Duration(seconds: 12));

  // What dragging the seek bar used to do: a seek every 50 ms.
  log('PHASE seek_burst target=120');
  for (var t = 90.0; t <= 120; t += 1) {
    await c.player.seek(Duration(milliseconds: (t * 1000).round()));
    await Future.delayed(const Duration(milliseconds: 50));
  }
  await Future.delayed(const Duration(seconds: 12));

  log('PHASE seek_back target=30');
  await c.player.seek(const Duration(seconds: 30));
  await Future.delayed(const Duration(seconds: 12));

  log('debug ${await c.player.diagnostics()}'.replaceAll('\n', ' '));
  log('PHASE end');
  exit(0);
}

/// Where the seek bar and Play/Pause button are, in points from the top left
/// of the window's content, and the content's size: `seek=x,y,w,h
/// play=x,y,w,h view=w,h` (`none` for a control not on screen).
String _uiLayout() {
  String rect(GlobalKey key) {
    final box = key.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize || !box.attached) return 'none';
    final o = box.localToGlobal(Offset.zero);
    return [
      o.dx,
      o.dy,
      box.size.width,
      box.size.height,
    ].map((v) => v.toStringAsFixed(1)).join(',');
  }

  final view = WidgetsBinding.instance.platformDispatcher.views.first;
  final size = view.physicalSize / view.devicePixelRatio;
  return 'seek=${rect(seekBarKey)} play=${rect(playButtonKey)} '
      'view=${size.width.toStringAsFixed(1)},${size.height.toStringAsFixed(1)}';
}

/// Where the page's video is, as the render and soak tests log it.
const _positionScript =
    "(function(){const v=document.querySelector('video');if(!v)return 'none';"
    "const q=v.getVideoPlaybackQuality?v.getVideoPlaybackQuality():null;"
    "return 't='+v.currentTime.toFixed(2)+' paused='+v.paused+"
    "' d='+(v.duration||0).toFixed(2)+' rs='+v.readyState+"
    "(q?' frames='+q.totalVideoFrames+' dropped='+q.droppedVideoFrames:'')})()";

/// macOS part of the soak test (tool/soak_test/run_macos.sh). Plays
/// PLAYER_TEST_URL and appends where the video is, every second, to the file
/// SOAK_TEST_LOG, in the format tool/soak_test/check.py reads. The script
/// adds its phase marks to the same file while it pauses and resumes from
/// the system media controls, hides the app, switches apps and turns the
/// display off.
///
/// If a system media command doesn't reach the app, the script writes
/// "play" or "pause" as a new line of SOAK_TEST_CMD instead, and this calls
/// what the media handler would have (PlaybackController.play, or pause on
/// the player).
Future<void> _macSoakTest(PlaybackController c, String url) async {
  final env = Platform.environment;
  final logFile = File(env['SOAK_TEST_LOG']!);
  void log(String line) {
    final t = DateTime.now().millisecondsSinceEpoch / 1000;
    logFile.writeAsStringSync(
      '${t.toStringAsFixed(3)} RENDER_TEST $line\n',
      mode: FileMode.append,
      flush: true,
    );
  }

  runApp(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      builder: (context, child) => BackgroundVideoHost(child: child!),
      home: const Scaffold(
        backgroundColor: Colors.black,
        body: VideoSurface(),
      ),
    ),
  );
  c.startRenderTest();
  await c.player.loadUrl(env['PLAYER_TEST_URL'] ?? url);
  Timer.periodic(const Duration(seconds: 1), (_) async {
    try {
      final r = await c.player.controller
          .runJavaScriptReturningResult(_positionScript)
          .timeout(const Duration(seconds: 2));
      log('pos $r');
    } catch (e) {
      log('pos no-answer');
    }
  });

  final commands = env['SOAK_TEST_CMD'];
  if (commands == null) return;
  var done = 0;
  Timer.periodic(const Duration(milliseconds: 500), (_) {
    final f = File(commands);
    if (!f.existsSync()) return;
    final lines = f.readAsLinesSync();
    for (final cmd in lines.skip(done)) {
      debugPrint('SOAK_TEST command $cmd');
      if (cmd == 'play') c.play();
      if (cmd == 'pause') c.player.pause();
    }
    done = lines.length;
  });
}

/// On-device check that downloads work: downloads [url] as a video and as
/// an MP3 through the app's own queue, showing the Downloads screen. Built
/// only by the `downloads-android` CI job (tool/download_test/run_android.sh),
/// which waits for the DOWNLOAD_TEST lines this logs and checks the saved
/// files.
Future<void> _downloadTest(String url) async {
  final d = Downloader.instance;
  runApp(
    const MaterialApp(debugShowCheckedModeBanner: false, home: DownloadsPage()),
  );
  final reported = <int>{};
  final last = <int, String>{};
  d.addListener(() {
    for (final j in d.jobs) {
      final line = '${j.state.name} ${(j.progress * 100).round()}% ${j.detail}';
      if (last[j.id] != line) {
        last[j.id] = line;
        debugPrint('DOWNLOAD_TEST job ${j.id} $line');
      }
      if (j.isFinished && reported.add(j.id)) {
        debugPrint(
          'DOWNLOAD_TEST finished kind=${j.kind.name} state=${j.state.name} '
          'path=${j.savedPath} detail=${j.detail}',
        );
      }
    }
  });
  debugPrint('DOWNLOAD_TEST engine ${await d.engineStatus()}');
  await d.enqueue(
    DownloadRequest(
      url: url,
      title: 'sample',
      kind: DownloadKind.video,
      maxHeight: 720,
    ),
  );
  await d.enqueue(
    DownloadRequest(
      url: url,
      title: 'sample',
      kind: DownloadKind.audio,
      audioKbps: 128,
    ),
  );
}

class AdFreeTubeApp extends StatelessWidget {
  const AdFreeTubeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AdFree Tube',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.system,
      theme: ThemeData(
        colorSchemeSeed: Colors.red,
        brightness: Brightness.light,
      ),
      darkTheme: ThemeData(
        colorSchemeSeed: Colors.red,
        brightness: Brightness.dark,
      ),
      builder: (context, child) => BackgroundVideoHost(child: child!),
      home: const HomePage(),
    );
  }
}
