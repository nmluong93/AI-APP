import 'package:adfree_tube/player_view.dart';
import 'package:adfree_tube/playback.dart';
import 'package:adfree_tube/settings.dart';
import 'package:adfree_tube/yt_web_player.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_webview.dart';

void main() {
  setUp(() async {
    FakeWebViewPlatform.install();
    SharedPreferences.setMockInitialValues({});
    await AppSettings.load();
  });

  final shield = find.byWidgetPredicate(
    (w) => w is ColoredBox && w.color == clickShieldColor,
  );

  double controlsOpacity(WidgetTester tester) =>
      tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity;

  /// Opens the player on a playing video and waits for the controls to fade.
  Future<void> openPlaying(WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: VideoSurface())),
    );
    PlaybackController.instance.player.value = const YtPlayerState(
      playing: true,
      duration: Duration(minutes: 3),
    );
    await tester.pump(VideoHosts.handOffDelay);
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    expect(controlsOpacity(tester), 0);
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(VideoHosts.handOffDelay);
  }

  // Bug 19: on macOS, clicks over the WebView only reach the app where the
  // app painted something.
  testWidgets(
    'on macOS the video is painted over, and clicks and the mouse bring the controls back',
    (tester) async {
      await openPlaying(tester);
      expect(shield, findsOneWidget);
      expect(tester.getSize(shield), tester.getSize(find.byType(VideoSurface)));

      await tester.tapAt(tester.getCenter(find.byType(VideoSurface)));
      await tester.pump(kDoubleTapTimeout);
      await tester.pumpAndSettle();
      expect(controlsOpacity(tester), 1);

      // They fade again, and moving the mouse shows them.
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
      expect(controlsOpacity(tester), 0);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(10, 10));
      await mouse.moveTo(tester.getCenter(find.byType(VideoSurface)));
      await tester.pumpAndSettle();
      expect(controlsOpacity(tester), 1);
      await mouse.removePointer();

      await tester.pump(const Duration(seconds: 4));
      await close(tester);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  testWidgets(
    'on Android nothing is painted over the video, and a tap still shows the controls',
    (tester) async {
      await openPlaying(tester);
      expect(shield, findsNothing);

      await tester.tapAt(tester.getCenter(find.byType(VideoSurface)));
      await tester.pump(kDoubleTapTimeout);
      await tester.pumpAndSettle();
      expect(controlsOpacity(tester), 1);

      await tester.pump(const Duration(seconds: 4));
      await close(tester);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  // Bug 20: dragging the seek bar used to seek on every step of the drag.
  testWidgets('dragging the seek bar seeks once, where the drag ends', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: VideoSurface())),
    );
    PlaybackController.instance.player.value = const YtPlayerState(
      playing: true,
      duration: Duration(minutes: 3),
    );
    await tester.pump(VideoHosts.handOffDelay);
    FakeWebViewPlatform.scripts.clear();

    final bar = find.byType(Slider);
    final drag = await tester.startGesture(tester.getCenter(bar));
    for (var i = 0; i < 20; i++) {
      await drag.moveBy(const Offset(4, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    final seeks = FakeWebViewPlatform.scripts.where((s) => s.contains('seek('));
    expect(seeks, isEmpty);
    expect(tester.widget<Slider>(bar).value, greaterThan(90 * 1000));
    await drag.up();
    await tester.pump();
    expect(seeks, hasLength(1));
    // Where the drag ended: just past the middle of a 3 minute video.
    final to = double.parse(
      RegExp(r'seek\(([\d.]+)\)').firstMatch(seeks.single)!.group(1)!,
    );
    expect(to, inInclusiveRange(91, 150));

    await tester.pump(const Duration(seconds: 4));
    await close(tester);
  });
}
