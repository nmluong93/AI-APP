import 'package:flutter/material.dart';

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
  runApp(const AdFreeTubeApp());
}

/// On-device check that video inside the WebView actually shows up. Built
/// only by the render-test CI job (tool/render_test.sh), which takes a
/// screenshot and measures it.
Future<void> _renderTest(String url) async {
  final player = PlaybackController.instance.player;
  runApp(
    const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(backgroundColor: Colors.black, body: VideoSurface()),
    ),
  );
  await player.loadUrl(url);
  await Future.delayed(const Duration(seconds: 20));
  // Whether the page itself sees decoded frames (independent of how the
  // app composites the WebView).
  final result = await player.controller.runJavaScriptReturningResult('''
    (function () {
      const v = document.querySelector('video');
      if (!v) return 'no video';
      const c = document.createElement('canvas');
      c.width = 16; c.height = 9;
      const g = c.getContext('2d');
      try { g.drawImage(v, 0, 0, 16, 9); } catch (e) { return 'draw failed ' + e; }
      const d = g.getImageData(8, 4, 1, 1).data;
      return 'paused=' + v.paused + ' t=' + v.currentTime.toFixed(1) +
        ' size=' + v.videoWidth + 'x' + v.videoHeight +
        ' centre=' + d[0] + ',' + d[1] + ',' + d[2];
    })()''');
  debugPrint('RENDER_TEST page: $result');
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
      home: const HomePage(),
    );
  }
}
