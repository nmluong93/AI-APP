import 'package:adfree_tube/home_page.dart';
import 'package:adfree_tube/settings.dart';
import 'package:adfree_tube/topic_feed.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_webview.dart';
import 'search_parsing_test.dart' show resultsPage, video;
import 'topic_feed_test.dart' show fakeTopics;

FeedVideo v(String id, {int views = 0, int? seconds, bool live = false}) =>
    FeedVideo(
      id: id,
      title: id,
      author: 'x',
      views: views,
      duration: seconds == null ? null : Duration(seconds: seconds),
      isLive: live,
    );

List<String> ids(List<FeedVideo> list) => list.map((v) => v.id).toList();

void main() {
  // Newest first, as the feed has them.
  final feed = [
    v('a', views: 10, seconds: 600),
    v('b', views: 5000, seconds: 60),
    v('live', views: 300, live: true),
    v('c', views: 5000, seconds: 3600),
    v('d', views: 0, seconds: 60),
  ];

  test('newest keeps the feed order', () {
    expect(ids(FeedSort.newest.apply(feed)), ['a', 'b', 'live', 'c', 'd']);
  });

  test('most viewed first, ties stay newest first', () {
    expect(ids(FeedSort.mostViewed.apply(feed)), ['b', 'c', 'live', 'a', 'd']);
  });

  test('by length, live streams last', () {
    expect(ids(FeedSort.shortest.apply(feed)), ['b', 'd', 'a', 'c', 'live']);
    expect(ids(FeedSort.longest.apply(feed)), ['c', 'a', 'b', 'd', 'live']);
  });

  test('sorting leaves the feed itself alone', () {
    final copy = List.of(feed);
    FeedSort.longest.apply(feed);
    expect(feed, copy);
  });

  test('unknown or missing names fall back to newest', () {
    expect(FeedSort.byName('mostViewed'), FeedSort.mostViewed);
    expect(FeedSort.byName('bogus'), FeedSort.newest);
    expect(FeedSort.byName(null), FeedSort.newest);
  });

  group('Home screen', () {
    setUp(() async {
      FakeWebViewPlatform.install();
      SharedPreferences.setMockInitialValues({});
      await AppSettings.load();
    });

    testWidgets('sort menu reorders the feed and is remembered', (
      tester,
    ) async {
      AppSettings.instance.addTopic('Music');
      fakeTopics(
        (_) => resultsPage([
          video('new00000001', title: 'Fresh', views: '12 views', published: '1 hour ago'),
          video('pop00000001', title: 'Popular', views: '9,000 views', published: '2 days ago'),
        ]),
      );
      await tester.pumpWidget(const MaterialApp(home: HomePage()));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await tester.pump();
      double top(String text) => tester.getTopLeft(find.text(text)).dy;
      expect(top('Fresh'), lessThan(top('Popular')));
      expect(find.text('Newest'), findsOneWidget);

      await tester.tap(find.byTooltip('Sort'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Most viewed').last);
      await tester.pumpAndSettle();
      expect(top('Popular'), lessThan(top('Fresh')));
      expect(AppSettings.instance.feedSort, 'mostViewed');

      // Opening the app again keeps the choice.
      await AppSettings.load();
      expect(FeedSort.byName(AppSettings.instance.feedSort), FeedSort.mostViewed);
    });
  });
}
