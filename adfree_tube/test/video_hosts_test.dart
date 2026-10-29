import 'package:adfree_tube/player_view.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Bug 12: the WebView must leave its old place before it appears in the
  // new one, or Android crashes the app in hybrid composition.
  testWidgets('the WebView moves between hosts through a gap', (tester) async {
    await tester.pumpWidget(const SizedBox());
    final seen = <Object?>[];
    VideoHosts.owner.addListener(() => seen.add(VideoHosts.owner.value));
    expect(VideoHosts.owner.value, same(VideoHosts.background));

    final player = Object();
    VideoHosts.add(player);
    // Nothing changes while widgets are building.
    expect(VideoHosts.owner.value, same(VideoHosts.background));
    await tester.pump(Duration.zero);
    expect(VideoHosts.owner.value, isNull);
    await tester.pump(VideoHosts.handOffDelay);
    expect(VideoHosts.owner.value, same(player));

    // Fullscreen opens over the player, then closes.
    final fullscreen = Object();
    VideoHosts.add(fullscreen);
    await tester.pump(Duration.zero);
    await tester.pump(VideoHosts.handOffDelay);
    expect(VideoHosts.owner.value, same(fullscreen));
    VideoHosts.remove(fullscreen);
    await tester.pump(Duration.zero);
    await tester.pump(VideoHosts.handOffDelay);
    expect(VideoHosts.owner.value, same(player));

    // Leaving the player parks the WebView in the background host.
    VideoHosts.remove(player);
    await tester.pump(Duration.zero);
    await tester.pump(VideoHosts.handOffDelay);
    expect(VideoHosts.owner.value, same(VideoHosts.background));

    // Every move went through null; no place was skipped straight to another.
    for (var i = 0; i < seen.length; i++) {
      expect(seen[i] == null, i.isEven, reason: 'change $i: $seen');
    }

    // Quick changes settle on the last one.
    VideoHosts.add(player);
    VideoHosts.remove(player);
    VideoHosts.add(fullscreen);
    await tester.pump(Duration.zero);
    await tester.pump(VideoHosts.handOffDelay);
    expect(VideoHosts.owner.value, same(fullscreen));
    VideoHosts.remove(fullscreen);
    await tester.pump(Duration.zero);
    await tester.pump(VideoHosts.handOffDelay);
  });
}
