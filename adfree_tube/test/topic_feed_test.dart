import 'dart:async';

import 'package:adfree_tube/home_page.dart';
import 'package:adfree_tube/settings.dart';
import 'package:adfree_tube/topic_feed.dart';
import 'package:adfree_tube/topics_page.dart';
import 'package:adfree_tube/youtube_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import 'fake_webview.dart';
import 'search_parsing_test.dart' show resultsPage, video;

/// A fake YouTube whose answer to each search is up to [answer], which gets
/// the searched words and may take its time. Returns the requests made.
List<Uri> fakeTopics(FutureOr<String> Function(String topic) answer) {
  final requests = <Uri>[];
  YoutubeService.useClient(
    YoutubeExplode(
      httpClient: YoutubeHttpClient(
        MockClient((request) async {
          requests.add(request.url);
          final body = await answer(
            request.url.queryParameters['search_query'] ?? '',
          );
          return http.Response(
            body,
            200,
            request: request,
            headers: {'content-type': 'text/html; charset=utf-8'},
          );
        }),
      ),
    ),
  );
  return requests;
}

const broken = '<html>no data here</html>';

Future<void> setTopics(List<String> topics) async {
  for (final t in AppSettings.instance.topics) {
    AppSettings.instance.removeTopic(t);
  }
  for (final t in topics) {
    AppSettings.instance.addTopic(t);
  }
}

List<String> ids(List<FeedVideo> list) => list.map((v) => v.id).toList();

void main() {
  setUp(() async {
    FakeWebViewPlatform.install();
    SharedPreferences.setMockInitialValues({});
    await AppSettings.load();
  });

  group('saved topics', () {
    test(
      'tidies, skips blanks and repeats in any case, and persists',
      () async {
        final s = AppSettings.instance;
        expect(s.topics, isEmpty);
        var notified = 0;
        s.addListener(() => notified++);

        expect(s.addTopic('  lo-fi   music '), isTrue);
        expect(s.addTopic('Lo-Fi Music'), isFalse);
        expect(s.addTopic('   '), isFalse);
        expect(s.addTopic('Football'), isTrue);
        expect(s.topics, ['lo-fi music', 'Football']);
        expect(notified, 2);

        // Opening the app again reads them back.
        await AppSettings.load();
        expect(AppSettings.instance.topics, ['lo-fi music', 'Football']);

        AppSettings.instance.removeTopic('lo-fi music');
        expect(AppSettings.instance.topics, ['Football']);
      },
    );

    test('stops at ${AppSettings.maxTopics} topics', () {
      final s = AppSettings.instance;
      for (var i = 0; i < AppSettings.maxTopics; i++) {
        expect(s.addTopic('t$i'), isTrue);
      }
      expect(s.addTopic('one more'), isFalse);
      expect(s.topics.length, AppSettings.maxTopics);
    });
  });

  group('TopicFeed', () {
    test('searches each topic for its newest videos only', () async {
      await setTopics(['Music', 'nhạc trữ tình']);
      final requests = fakeTopics((_) => resultsPage([video('aaaaaaaaaa1')]));
      await TopicFeed(AppSettings.instance).load();
      expect(requests.map((r) => r.queryParameters['search_query']).toSet(), {
        'Music',
        'nhạc trữ tình',
      });
      for (final r in requests) {
        expect(r.path, '/results');
        // Sorted by upload date, videos only.
        expect(r.query, contains('sp=${YoutubeService.newestVideos.value}'));
      }
    });

    test(
      'mixes the topics newest first and lists a shared video once',
      () async {
        await setTopics(['Music', 'News']);
        fakeTopics(
          (topic) => topic == 'Music'
              ? resultsPage([
                  video('music00001a', title: 'M1', published: '1 hour ago'),
                  video('shared0001a', title: 'Both', published: '3 days ago'),
                  video('music00002a', title: 'M2', published: '2 weeks ago'),
                ])
              : resultsPage([
                  video('news000001a', title: 'N1', published: '5 hours ago'),
                  video('shared0001a', title: 'Both', published: '3 days ago'),
                  video('news000002a', title: 'N2', published: '1 month ago'),
                ]),
        );
        final feed = TopicFeed(AppSettings.instance);
        await feed.load();

        expect(feed.loading, isFalse);
        expect(feed.error, isNull);
        expect(feed.failedTopics, isEmpty);
        expect(ids(feed.videos), [
          'music00001a',
          'news000001a',
          'shared0001a',
          'music00002a',
          'news000002a',
        ]);
        final shared = feed.videos.firstWhere((v) => v.id == 'shared0001a');
        expect(shared.topics, ['Music', 'News']);
        expect(ids(feed.videosFor('News')), [
          'news000001a',
          'shared0001a',
          'news000002a',
        ]);
        expect(feed.videosFor(null), feed.videos);
      },
    );

    test('keeps YouTube\'s order for videos of the same age', () async {
      await setTopics(['A', 'B']);
      fakeTopics(
        (topic) => resultsPage([
          video('${topic}0000000001', published: '1 day ago'),
          video('${topic}0000000002', published: '1 day ago'),
        ]),
      );
      final feed = TopicFeed(AppSettings.instance);
      await feed.load();
      // Taking the topics in turn.
      expect(ids(feed.videos), [
        'A0000000001',
        'B0000000001',
        'A0000000002',
        'B0000000002',
      ]);
      expect(feed.videos.map((v) => v.rank), [0, 0, 1, 1]);
      expect(feed.videos.map((v) => v.topics.single), ['A', 'B', 'A', 'B']);
    });

    test('live streams go after dated videos', () async {
      await setTopics(['Music']);
      fakeTopics(
        (_) => resultsPage([
          video('live0000001', title: 'Live', published: null, length: null),
          video('dated000001', title: 'Dated', published: '2 hours ago'),
        ]),
      );
      final feed = TopicFeed(AppSettings.instance);
      await feed.load();
      expect(ids(feed.videos), ['dated000001', 'live0000001']);
    });

    test('the next start shows the saved feed before anything loads', () async {
      await setTopics(['Music']);
      fakeTopics(
        (_) => resultsPage([
          video('saved000001', title: 'Saved', published: '2 days ago'),
        ]),
      );
      await TopicFeed(AppSettings.instance).load();

      // Open the app again, with YouTube unreachable this time.
      await AppSettings.load();
      fakeTopics((_) => broken);
      final feed = TopicFeed(AppSettings.instance);
      expect(ids(feed.videos), ['saved000001']);
      expect(feed.videos.single.title, 'Saved');
      expect(feed.videos.single.published, '2 days ago');
      expect(
        feed.videos.single.duration,
        const Duration(minutes: 3, seconds: 21),
      );
      expect(feed.videos.single.views, 1234);

      // A failed refresh keeps what was there.
      await feed.load();
      expect(ids(feed.videos), ['saved000001']);
      expect(feed.failedTopics, ['Music']);
    });

    test('a cache that doesn\'t parse is ignored', () async {
      SharedPreferences.setMockInitialValues({
        'feedCache': ['not json'],
      });
      await AppSettings.load();
      expect(TopicFeed(AppSettings.instance).videos, isEmpty);
    });

    test('one failing topic doesn\'t hide the others', () async {
      await setTopics(['Music', 'News']);
      fakeTopics(
        (topic) => topic == 'News'
            ? broken
            : resultsPage([video('music00001a', published: '1 hour ago')]),
      );
      final feed = TopicFeed(AppSettings.instance);
      await feed.load();
      expect(ids(feed.videos), ['music00001a']);
      expect(feed.failedTopics, ['News']);
      expect(feed.error, isNull);
    });

    test('says so when every topic fails and nothing is saved', () async {
      await setTopics(['Music', 'News']);
      fakeTopics((_) => broken);
      final feed = TopicFeed(AppSettings.instance);
      await feed.load();
      expect(feed.videos, isEmpty);
      expect(feed.error, isNotNull);
      expect(feed.failedTopics, ['Music', 'News']);
      expect(feed.loading, isFalse);
    });

    test('no topics empties the feed and its saved copy', () async {
      await setTopics(['Music']);
      fakeTopics((_) => resultsPage([video('music00001a')]));
      final feed = TopicFeed(AppSettings.instance);
      await feed.load();
      expect(feed.videos, isNotEmpty);

      await setTopics([]);
      final requests = fakeTopics((_) => resultsPage([video('music00001a')]));
      await feed.load();
      expect(requests, isEmpty);
      expect(feed.videos, isEmpty);
      expect(AppSettings.instance.feedCache, isEmpty);
    });

    test(
      'a removed topic\'s videos go at once, before the reload ends',
      () async {
        await setTopics(['Music', 'News']);
        fakeTopics(
          (topic) => resultsPage([
            video(topic == 'Music' ? 'music00001a' : 'news000001a'),
          ]),
        );
        final feed = TopicFeed(AppSettings.instance);
        await feed.load();
        expect(ids(feed.videos).toSet(), {'music00001a', 'news000001a'});

        AppSettings.instance.removeTopic('News');
        final answer = Completer<String>();
        fakeTopics((_) => answer.future);
        final loading = feed.load();
        expect(feed.loading, isTrue);
        expect(ids(feed.videos), ['music00001a']);
        answer.complete(resultsPage([video('music00002a')]));
        await loading;
        expect(ids(feed.videos), ['music00002a']);
      },
    );

    test('shows each topic as soon as it answers', () async {
      await setTopics(['Fast', 'Slow']);
      final slow = Completer<String>();
      fakeTopics(
        (topic) =>
            topic == 'Fast' ? resultsPage([video('fast0000001')]) : slow.future,
      );
      final feed = TopicFeed(AppSettings.instance);
      final seen = <List<String>>[];
      feed.addListener(() => seen.add(ids(feed.videos)));
      final loading = feed.load();

      // Wait until the fast topic is in, while the slow one still runs.
      while (!feed.videos.any((v) => v.id == 'fast0000001')) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(feed.loading, isTrue);

      slow.complete(
        resultsPage([video('slow0000001', published: '1 year ago')]),
      );
      await loading;
      expect(feed.loading, isFalse);
      expect(ids(feed.videos), ['fast0000001', 'slow0000001']);
      expect(seen, contains(equals(['fast0000001'])));
    });

    test(
      'runs at most ${TopicFeed.parallelSearches} searches at once',
      () async {
        await setTopics(['a', 'b', 'c', 'd', 'e', 'f', 'g']);
        var running = 0, most = 0;
        final requests = fakeTopics((topic) async {
          running++;
          most = running > most ? running : most;
          await Future<void>.delayed(const Duration(milliseconds: 20));
          running--;
          return resultsPage([video('${topic}0000000000')]);
        });
        final feed = TopicFeed(AppSettings.instance);
        await feed.load();
        expect(requests.length, 7);
        expect(most, TopicFeed.parallelSearches);
        expect(feed.videos.length, 7);
      },
    );

    test('a newer load wins over an older one still running', () async {
      await setTopics(['Old']);
      final old = Completer<String>();
      fakeTopics(
        (topic) =>
            topic == 'Old' ? old.future : resultsPage([video('new00000001')]),
      );
      final feed = TopicFeed(AppSettings.instance);
      final first = feed.load();

      await setTopics(['New']);
      await feed.load();
      old.complete(resultsPage([video('old00000001')]));
      await first;
      expect(ids(feed.videos), ['new00000001']);
      expect(feed.loading, isFalse);
    });

    test('a load finishing after dispose does nothing', () async {
      await setTopics(['Music']);
      final answer = Completer<String>();
      fakeTopics((_) => answer.future);
      final feed = TopicFeed(AppSettings.instance);
      final loading = feed.load();
      feed.dispose();
      answer.complete(resultsPage([video('music00001a')]));
      await loading; // Would throw if it notified after dispose.
    });
  });

  group('Home screen', () {
    /// Lets the fake YouTube answer on real async, then draws.
    Future<void> settle(WidgetTester tester) async {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await tester.pump();
    }

    testWidgets('with no topics, asks for some and loads them', (tester) async {
      final requests = fakeTopics(
        (topic) => resultsPage([video('music00001a', title: 'Fresh $topic')]),
      );
      await tester.pumpWidget(const MaterialApp(home: HomePage()));
      await tester.pump();
      expect(requests, isEmpty);
      expect(find.textContaining('Pick topics you like'), findsOneWidget);

      await tester.tap(find.text('Choose topics'));
      await tester.pumpAndSettle();
      expect(find.byType(TopicsPage), findsOneWidget);
      await tester.tap(find.widgetWithText(ActionChip, 'Music'));
      await tester.pump();
      expect(AppSettings.instance.topics, ['Music']);

      await tester.pageBack();
      await tester.pumpAndSettle();
      await settle(tester);
      expect(requests.single.queryParameters['search_query'], 'Music');
      expect(find.text('Fresh Music'), findsOneWidget);
    });

    testWidgets('on start, draws first and loads the topics afterwards', (
      tester,
    ) async {
      await setTopics(['Music']);
      final answer = Completer<String>();
      final requests = fakeTopics((_) => answer.future);
      await tester.pumpWidget(const MaterialApp(home: HomePage()));
      // The first frame is up without waiting on YouTube, with the topic
      // chips and a spinner while the feed loads.
      expect(find.widgetWithText(ChoiceChip, 'All'), findsOneWidget);
      expect(find.widgetWithText(ChoiceChip, 'Music'), findsOneWidget);
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      // The search bar still works while it loads.
      await tester.enterText(find.byType(SearchBar), 'typing');
      expect(find.text('typing'), findsOneWidget);

      await settle(tester);
      expect(requests, hasLength(1));
      answer.complete(resultsPage([video('music00001a', title: 'Newest one')]));
      await settle(tester);
      expect(find.text('Newest one'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('on start, the saved feed shows while the fresh one loads', (
      tester,
    ) async {
      await setTopics(['Music']);
      fakeTopics(
        (_) => resultsPage([video('saved000001', title: 'Saved one')]),
      );
      await tester.runAsync(() => TopicFeed(AppSettings.instance).load());

      final answer = Completer<String>();
      fakeTopics((_) => answer.future);
      await tester.pumpWidget(const MaterialApp(home: HomePage()));
      expect(find.text('Saved one'), findsOneWidget);
      await tester.pump();
      // A thin bar says it's refreshing.
      expect(find.byType(LinearProgressIndicator), findsOneWidget);

      answer.complete(resultsPage([video('fresh000001', title: 'Fresh one')]));
      await settle(tester);
      expect(find.text('Fresh one'), findsOneWidget);
      expect(find.text('Saved one'), findsNothing);
      expect(find.byType(LinearProgressIndicator), findsNothing);
    });

    testWidgets('topic chips filter the feed', (tester) async {
      await setTopics(['Music', 'News']);
      fakeTopics(
        (topic) => resultsPage([
          video('${topic}xxxxxxx'.substring(0, 11), title: '$topic video'),
        ]),
      );
      await tester.pumpWidget(const MaterialApp(home: HomePage()));
      await settle(tester);
      expect(find.text('Music video'), findsOneWidget);
      expect(find.text('News video'), findsOneWidget);

      await tester.tap(find.widgetWithText(ChoiceChip, 'News'));
      await tester.pump();
      expect(find.text('Music video'), findsNothing);
      expect(find.text('News video'), findsOneWidget);

      await tester.tap(find.widgetWithText(ChoiceChip, 'All'));
      await tester.pump();
      expect(find.text('Music video'), findsOneWidget);
    });

    testWidgets('a failed load says so and Try again reloads', (tester) async {
      await setTopics(['Music']);
      var fail = true;
      fakeTopics(
        (_) =>
            fail ? broken : resultsPage([video('music00001a', title: 'Back')]),
      );
      await tester.pumpWidget(const MaterialApp(home: HomePage()));
      await settle(tester);
      expect(
        find.textContaining('Couldn\'t load the latest videos'),
        findsOneWidget,
      );

      fail = false;
      await tester.tap(find.text('Try again'));
      await settle(tester);
      expect(find.text('Back'), findsOneWidget);
    });

    testWidgets('names a topic that failed while others loaded', (
      tester,
    ) async {
      await setTopics(['Music', 'News']);
      fakeTopics(
        (topic) => topic == 'News'
            ? broken
            : resultsPage([video('music00001a', title: 'Fine')]),
      );
      await tester.pumpWidget(const MaterialApp(home: HomePage()));
      await settle(tester);
      expect(find.text('Fine'), findsOneWidget);
      expect(find.textContaining('Couldn\'t refresh News'), findsOneWidget);
    });

    testWidgets('clearing a search goes back to the feed', (tester) async {
      await setTopics(['Music']);
      fakeTopics(
        (q) => q == 'Music'
            ? resultsPage([video('music00001a', title: 'Feed video')])
            : resultsPage([video('search00001', title: 'Search hit')]),
      );
      await tester.pumpWidget(const MaterialApp(home: HomePage()));
      await settle(tester);
      expect(find.text('Feed video'), findsOneWidget);

      await tester.enterText(find.byType(SearchBar), 'something');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await settle(tester);
      expect(find.text('Search hit'), findsOneWidget);
      expect(find.text('Feed video'), findsNothing);

      await tester.tap(find.byTooltip('Clear'));
      await tester.pump();
      expect(find.text('Feed video'), findsOneWidget);
      expect(find.text('Search hit'), findsNothing);
    });

    testWidgets('editing topics reloads, and an unchanged list doesn\'t', (
      tester,
    ) async {
      await setTopics(['Music']);
      final requests = fakeTopics(
        (topic) => resultsPage([
          video('${topic}xxxxxxxxxx'.substring(0, 11), title: '$topic video'),
        ]),
      );
      await tester.pumpWidget(const MaterialApp(home: HomePage()));
      await settle(tester);
      expect(requests, hasLength(1));

      await tester.tap(find.byTooltip('Your topics'));
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();
      await settle(tester);
      expect(requests, hasLength(1));

      await tester.tap(find.widgetWithText(ActionChip, 'Edit'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Remove Music'));
      await tester.enterText(find.byType(TextField), 'Gaming');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(AppSettings.instance.topics, ['Gaming']);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await settle(tester);
      expect(requests.last.queryParameters['search_query'], 'Gaming');
      expect(find.text('Gaming video'), findsOneWidget);
      expect(find.text('Music video'), findsNothing);
    });
  });

  group('Topics screen', () {
    testWidgets('adds typed and suggested topics and removes them', (
      tester,
    ) async {
      await tester.pumpWidget(const MaterialApp(home: TopicsPage()));
      expect(find.text('No topics yet.'), findsOneWidget);

      await tester.enterText(find.byType(TextField), '  Vinfast review ');
      await tester.tap(find.byTooltip('Add'));
      await tester.pump();
      expect(AppSettings.instance.topics, ['Vinfast review']);
      expect(find.widgetWithText(InputChip, 'Vinfast review'), findsOneWidget);
      // The box empties for the next one.
      expect(find.text('  Vinfast review '), findsNothing);

      await tester.tap(find.widgetWithText(ActionChip, 'Cooking'));
      await tester.pump();
      expect(AppSettings.instance.topics, ['Vinfast review', 'Cooking']);
      // A picked suggestion isn't offered again.
      expect(find.widgetWithText(ActionChip, 'Cooking'), findsNothing);
      expect(find.widgetWithText(InputChip, 'Cooking'), findsOneWidget);

      await tester.tap(find.byTooltip('Remove Cooking'));
      await tester.pump();
      expect(AppSettings.instance.topics, ['Vinfast review']);
      expect(find.widgetWithText(ActionChip, 'Cooking'), findsOneWidget);
    });

    testWidgets('says when the list is full', (tester) async {
      for (var i = 0; i < AppSettings.maxTopics; i++) {
        AppSettings.instance.addTopic('t$i');
      }
      await tester.pumpWidget(const MaterialApp(home: TopicsPage()));
      await tester.enterText(find.byType(TextField), 'one more');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(find.textContaining('the most topics'), findsOneWidget);
      expect(AppSettings.instance.topics.length, AppSettings.maxTopics);
    });
  });
}
