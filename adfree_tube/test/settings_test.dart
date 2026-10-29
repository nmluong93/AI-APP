import 'package:adfree_tube/home_page.dart';
import 'package:adfree_tube/settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.load();
  });

  test('defaults keep the black-video workarounds on', () {
    final s = AppSettings.instance;
    expect(s.preferredHeight, 1080);
    expect(s.videoDisplay, 'hybrid');
    expect(s.canvasVideo, isTrue);
    expect(s.pageDrawnVideo, isTrue);
  });

  test('settings persist and notify listeners', () async {
    final s = AppSettings.instance;
    var notified = 0;
    s.addListener(() => notified++);
    s.videoDisplay = 'texture';
    s.canvasVideo = false;
    s.pageDrawnVideo = false;
    s.preferredHeight = 720;
    expect(notified, 4);

    // A fresh load reads the stored values back.
    await AppSettings.load();
    final again = AppSettings.instance;
    expect(again.videoDisplay, 'texture');
    expect(again.canvasVideo, isFalse);
    expect(again.pageDrawnVideo, isFalse);
    expect(again.preferredHeight, 720);
  });

  test('history keeps the newest entry once and caps at 200', () {
    final s = AppSettings.instance;
    s.addToHistory(const HistoryEntry('a', 'A', 'x'));
    s.addToHistory(const HistoryEntry('b', 'B', 'x'));
    s.addToHistory(const HistoryEntry('a', 'A again', 'x'));
    expect(s.history.map((e) => e.id), ['a', 'b']);
    expect(s.history.first.title, 'A again');

    for (var i = 0; i < 250; i++) {
      s.addToHistory(HistoryEntry('v$i', 'V$i', 'x'));
    }
    expect(s.history.length, 200);
    expect(s.history.first.id, 'v249');

    s.clearHistory();
    expect(s.history, isEmpty);
  });

  testWidgets('settings page switches the video display options', (
    tester,
  ) async {
    // Tall enough that every option is on screen without scrolling.
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const MaterialApp(home: SettingsPage()));
    final s = AppSettings.instance;

    await tester.tap(find.text('Texture'));
    await tester.pump();
    expect(s.videoDisplay, 'texture');

    await tester.tap(find.text('Draw video through a canvas'));
    await tester.pump();
    expect(s.canvasVideo, isFalse);

    await tester.tap(find.text('Keep video drawn in the page'));
    await tester.pump();
    expect(s.pageDrawnVideo, isFalse);

    await tester.tap(find.text('720p'));
    await tester.pump();
    expect(s.preferredHeight, 720);
  });
}
