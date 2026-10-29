import 'package:adfree_tube/home_page.dart';
import 'package:adfree_tube/settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_webview.dart';
import 'search_parsing_test.dart' show fakeYouTube, resultsPage, video;

void main() {
  setUp(() async {
    FakeWebViewPlatform.install();
    SharedPreferences.setMockInitialValues({});
    await AppSettings.load();
  });

  Future<void> searchFor(WidgetTester tester, String text) async {
    await tester.enterText(find.byType(SearchBar), text);
    await tester.testTextInput.receiveAction(TextInputAction.search);
    // The fake YouTube answers on real async; let it, then draw.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pump();
  }

  testWidgets('shows results, including the kind that used to fail', (
    tester,
  ) async {
    final requests = fakeYouTube(
      (_) => resultsPage([
        video('aaaaaaaaaa1', title: 'Tinhte review'),
        video(
          'bbbbbbbbbb1',
          title: 'Tinhte live',
          published: 'Streamed 2 weeks ago',
        ),
      ]),
    );
    await tester.pumpWidget(const MaterialApp(home: HomePage()));
    await searchFor(tester, 'tinhte');
    expect(requests.single.queryParameters['search_query'], 'tinhte');
    expect(find.text('Tinhte review'), findsOneWidget);
    expect(find.text('Tinhte live'), findsOneWidget);
    expect(find.textContaining('didn\'t work'), findsNothing);
  });

  testWidgets('tidies spaces and searches 11-letter words', (tester) async {
    final requests = fakeYouTube((_) => resultsPage([video('aaaaaaaaaa1')]));
    await tester.pumpWidget(const MaterialApp(home: HomePage()));
    await searchFor(tester, '  programming  ');
    expect(requests.single.queryParameters['search_query'], 'programming');
  });

  testWidgets('blank input does nothing', (tester) async {
    final requests = fakeYouTube((_) => resultsPage([]));
    await tester.pumpWidget(const MaterialApp(home: HomePage()));
    await searchFor(tester, '   ');
    expect(requests, isEmpty);
    expect(find.text('Search for something to watch.'), findsOneWidget);
  });

  testWidgets('a failed search says so and Try again repeats it', (
    tester,
  ) async {
    var fail = true;
    final requests = fakeYouTube(
      (_) => fail
          ? '<html>no data here</html>'
          : resultsPage([video('aaaaaaaaaa1', title: 'Found it')]),
    );
    await tester.pumpWidget(const MaterialApp(home: HomePage()));
    await searchFor(tester, 'tinhte');
    expect(find.textContaining('Search didn\'t work'), findsOneWidget);

    fail = false;
    await tester.tap(find.text('Try again'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pump();
    expect(find.text('Found it'), findsOneWidget);
    expect(requests.last.queryParameters['search_query'], 'tinhte');
  });

  testWidgets('no results shows the empty message', (tester) async {
    fakeYouTube((_) => resultsPage([]));
    await tester.pumpWidget(const MaterialApp(home: HomePage()));
    await searchFor(tester, 'zzzzqqqq nothing');
    expect(find.text('Search for something to watch.'), findsOneWidget);
  });
}
