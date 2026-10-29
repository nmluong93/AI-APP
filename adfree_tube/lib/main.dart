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
  await c.player.loadUrl(url);
  // Log where the video is every 3 seconds, whatever the app is doing.
  Timer.periodic(const Duration(seconds: 3), (_) async {
    try {
      final r = await c.player.controller
          .runJavaScriptReturningResult(
            "(function(){const v=document.querySelector('video');"
            "return v?('t='+v.currentTime.toFixed(2)+' paused='+v.paused):'none'})()",
          )
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
