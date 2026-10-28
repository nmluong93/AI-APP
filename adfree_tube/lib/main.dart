import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import 'home_page.dart';
import 'playback.dart';
import 'settings.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  await AppSettings.load();
  await PlaybackController.instance.initSystemControls();
  runApp(const AdFreeTubeApp());
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
