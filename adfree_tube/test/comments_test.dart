import 'dart:async';
import 'dart:convert';

import 'package:adfree_tube/comments.dart';
import 'package:adfree_tube/youtube_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
// ignore: implementation_imports
import 'package:youtube_explode_dart/src/reverse_engineering/clients/comments_client.dart'
    show parseCommentCount;
// ignore: implementation_imports
import 'package:youtube_explode_dart/src/reverse_engineering/pages/watch_page.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

const channel = 'UCaaaaaaaaaaaaaaaaaaaaaa';

/// A video whose watch page points at the comments with [token], or has no
/// comments section at all when [token] is null.
Video videoWithComments(String? token) {
  final initialData = {
    'contents': {
      'twoColumnWatchNextResults': {
        'results': {
          'results': {
            'contents': [
              {'videoPrimaryInfoRenderer': {}},
              if (token != null)
                {
                  'itemSectionRenderer': {
                    'contents': [
                      {
                        'continuationItemRenderer': {
                          'continuationEndpoint': {
                            'continuationCommand': {'token': token},
                          },
                        },
                      },
                    ],
                  },
                },
            ],
          },
        },
      },
    },
  };
  final page = WatchPage.parse(
    '<html><body><script>var ytInitialData = '
    '${jsonEncode(initialData)};</script></body></html>',
    VideoId('aaaaaaaaaaa'),
    const {},
  );
  return Video(
    VideoId('aaaaaaaaaaa'),
    'A video',
    'Someone',
    ChannelId(channel),
    null,
    null,
    null,
    '',
    null,
    const ThumbnailSet('aaaaaaaaaaa'),
    null,
    const Engagement(0, null, null),
    false,
    const [],
    page,
  );
}

/// A comment the way YouTube writes it now: a view model with keys, and
/// the comment itself in frameworkUpdates.
({Map<String, Object?> item, List<Map<String, Object?>> entities}) comment(
  String id, {
  String text = 'Nice video',
  String author = '@someone',
  String likes = '1.2K',
  String replies = '3',
  bool hearted = false,
  String channelId = channel,
}) => (
  item: {
    'commentThreadRenderer': {
      'commentViewModel': {
        'commentViewModel': {
          'commentKey': 'key-$id',
          'toolbarStateKey': 'toolbar-$id',
          'commentId': id,
        },
      },
      'replies': {
        'commentRepliesRenderer': {
          'contents': [
            {
              'continuationItemRenderer': {
                'continuationEndpoint': {
                  'continuationCommand': {'token': 'replies-$id'},
                },
              },
            },
          ],
        },
      },
    },
  },
  entities: [
    {
      'entityKey': 'key-$id',
      'payload': {
        'commentEntityPayload': {
          'key': 'key-$id',
          'properties': {
            'commentId': id,
            'content': {'content': text},
            'publishedTime': '2 days ago',
          },
          'author': {'channelId': channelId, 'displayName': author},
          'toolbar': {'likeCountNotliked': likes, 'replyCount': replies},
        },
      },
    },
    {
      'entityKey': 'toolbar-$id',
      'payload': {
        'engagementToolbarStateEntityPayload': {
          'key': 'toolbar-$id',
          'heartState': hearted
              ? 'TOOLBAR_HEART_STATE_HEARTED'
              : 'TOOLBAR_HEART_STATE_UNHEARTED',
        },
      },
    },
  ],
);

Map<String, Object?> continuation(String token) => {
  'continuationItemRenderer': {
    'continuationEndpoint': {
      'continuationCommand': {'token': token},
    },
  },
};

/// The answer to the first comments request.
String firstPage(
  List<({Map<String, Object?> item, List<Map<String, Object?>> entities})>
  comments, {
  String count = '1,234',
  String? next,
}) => jsonEncode({
  'onResponseReceivedEndpoints': [
    {
      'reloadContinuationItemsCommand': {
        'continuationItems': [
          {
            'commentsHeaderRenderer': {
              'countText': {
                'runs': [
                  {'text': count},
                  {'text': ' Comments'},
                ],
              },
            },
          },
        ],
      },
    },
    {
      'reloadContinuationItemsCommand': {
        'continuationItems': [
          for (final c in comments) c.item,
          if (next != null) continuation(next),
        ],
      },
    },
  ],
  'frameworkUpdates': {
    'entityBatchUpdate': {
      'mutations': [for (final c in comments) ...c.entities],
    },
  },
});

/// The answer to a "more comments" request.
String nextPage(
  List<({Map<String, Object?> item, List<Map<String, Object?>> entities})>
  comments, {
  String? next,
}) => jsonEncode({
  'onResponseReceivedEndpoints': [
    {
      'appendContinuationItemsAction': {
        'continuationItems': [
          for (final c in comments) c.item,
          if (next != null) continuation(next),
        ],
      },
    },
  ],
  'frameworkUpdates': {
    'entityBatchUpdate': {
      'mutations': [for (final c in comments) ...c.entities],
    },
  },
});

/// Answers comment requests with [answer], given the continuation token
/// sent. Returns the tokens asked for.
/// With [gate], answers only once it completes.
List<String> fakeComments(
  String Function(String token) answer, {
  Future<void>? gate,
}) {
  final tokens = <String>[];
  YoutubeService.useClient(
    YoutubeExplode(
      httpClient: YoutubeHttpClient(
        MockClient((request) async {
          final token =
              (jsonDecode(request.body) as Map)['continuation'] as String;
          tokens.add(token);
          await gate;
          return http.Response(
            answer(token),
            200,
            request: request,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      ),
    ),
  );
  return tokens;
}

void main() {
  test('reads YouTube\'s current comment format, page by page', () async {
    final tokens = fakeComments(
      (token) => switch (token) {
        'first' => firstPage([
          comment('c1', text: 'First!', hearted: true),
          comment('c2', text: 'Second', likes: '', replies: ''),
        ], next: 'page2'),
        _ => nextPage([comment('c3', text: 'Third', likes: '17')]),
      },
    );
    final comments = VideoComments(videoWithComments('first'));
    await comments.load();

    expect(tokens, ['first']);
    expect(comments.total, 1234);
    expect(comments.items.map((c) => c.text), ['First!', 'Second']);
    final first = comments.items.first;
    expect(first.author, '@someone');
    expect(first.channelId.value, channel);
    expect(first.publishedTime, '2 days ago');
    expect(first.likeCount, 1200);
    expect(first.replyCount, 3);
    expect(first.isHearted, isTrue);
    expect(comments.items[1].likeCount, 0);
    expect(comments.items[1].isHearted, isFalse);
    expect(comments.hasMore, isTrue);

    await comments.loadMore();
    expect(tokens, ['first', 'page2']);
    expect(comments.items.map((c) => c.text), ['First!', 'Second', 'Third']);
    expect(comments.items.last.likeCount, 17);
    expect(comments.total, 1234);
    expect(comments.hasMore, isFalse);
  });

  test('still reads the older commentRenderer format', () async {
    fakeComments(
      (_) => jsonEncode({
        'onResponseReceivedEndpoints': [
          {
            'reloadContinuationItemsCommand': {'continuationItems': []},
          },
          {
            'reloadContinuationItemsCommand': {
              'continuationItems': [
                {
                  'commentThreadRenderer': {
                    'comment': {
                      'commentRenderer': {
                        'authorText': {'simpleText': 'Old style'},
                        'authorEndpoint': {
                          'browseEndpoint': {'browseId': channel},
                        },
                        'contentText': {
                          'runs': [
                            {'text': 'Hello '},
                            {'text': 'there'},
                          ],
                        },
                        'publishedTimeText': {
                          'runs': [
                            {'text': '1 year ago'},
                          ],
                        },
                        'voteCount': {'simpleText': '5'},
                        'replyCount': 2,
                      },
                    },
                  },
                },
              ],
            },
          },
        ],
      }),
    );
    final comments = VideoComments(videoWithComments('first'));
    await comments.load();
    final c = comments.items.single;
    expect(c.author, 'Old style');
    expect(c.text, 'Hello there');
    expect(c.likeCount, 5);
    expect(c.replyCount, 2);
  });

  test('skips a comment it can\'t read instead of failing', () async {
    fakeComments(
      (_) => firstPage([
        comment('c1', channelId: 'not a channel'),
        comment('c2', text: 'Readable'),
      ]),
    );
    final comments = VideoComments(videoWithComments('first'));
    await comments.load();
    expect(comments.items.map((c) => c.text), ['Readable']);
    expect(comments.error, isNull);
  });

  test('a video with comments turned off asks nothing', () async {
    final tokens = fakeComments((_) => fail('should not ask'));
    final comments = VideoComments(videoWithComments(null));
    await comments.load();
    expect(tokens, isEmpty);
    expect(comments.none, isTrue);
    expect(comments.items, isEmpty);
    expect(comments.hasMore, isFalse);
  });

  test('a failed load says so and Try again repeats it', () async {
    var broken = true;
    fakeComments(
      (_) => broken ? '<html>not json</html>' : firstPage([comment('c1')]),
    );
    final comments = VideoComments(videoWithComments('first'));
    await comments.load();
    expect(comments.error, isNotNull);
    expect(comments.items, isEmpty);

    broken = false;
    await comments.loadMore();
    expect(comments.error, isNull);
    expect(comments.items, hasLength(1));
  });

  test('reads counts the way YouTube writes them', () {
    expect(parseCommentCount('1,234'), 1234);
    expect(parseCommentCount('1,234 Comments'), 1234);
    expect(parseCommentCount('2.5K'), 2500);
    expect(parseCommentCount('3M'), 3000000);
    expect(parseCommentCount('17'), 17);
    expect(parseCommentCount(''), 0);
    expect(parseCommentCount(' '), 0);
    expect(parseCommentCount(null), 0);
  });

  group('on screen', () {
    Future<VideoComments> loaded(WidgetTester tester) async {
      fakeComments(
        (_) => firstPage([
          comment('c1', text: 'First comment'),
          comment('c2', text: 'Second comment'),
        ], next: 'page2'),
      );
      final comments = VideoComments(videoWithComments('first'));
      await tester.runAsync(comments.load);
      return comments;
    }

    testWidgets('wide windows list the comments', (tester) async {
      final comments = await loaded(tester);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: CommentsSection(comments: comments),
            ),
          ),
        ),
      );
      expect(find.text('Comments · 1.2K'), findsOneWidget);
      expect(find.text('First comment'), findsOneWidget);
      expect(find.text('Second comment'), findsOneWidget);
      expect(find.text('Show more comments'), findsOneWidget);
    });

    testWidgets('phones preview one and open the rest', (tester) async {
      final comments = await loaded(tester);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CommentsSection(comments: comments, preview: true),
          ),
        ),
      );
      expect(find.text('First comment'), findsOneWidget);
      expect(find.text('Second comment'), findsNothing);

      await tester.tap(find.text('First comment'));
      await tester.pumpAndSettle();
      expect(find.text('Second comment'), findsOneWidget);
    });

    testWidgets('shows a spinner while the first page loads', (tester) async {
      final gate = Completer<void>();
      fakeComments((_) => firstPage([comment('c1')]), gate: gate.future);
      final comments = VideoComments(videoWithComments('first'));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CommentsSection(comments: comments, preview: true),
          ),
        ),
      );
      final load = comments.load();
      await tester.pump();
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      gate.complete();
      await tester.runAsync(() => load);
      await tester.pump();
      expect(find.text('Nice video'), findsOneWidget);
    });
  });
}
