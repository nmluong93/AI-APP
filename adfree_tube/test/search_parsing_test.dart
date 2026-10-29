import 'dart:convert';

import 'package:adfree_tube/youtube_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
// ignore: implementation_imports
import 'package:youtube_explode_dart/src/extensions/helpers_extension.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

/// One search result the way YouTube's results page writes it.
Map<String, Object?> video(
  String id, {
  String title = 'A video',
  String? published = '2 days ago',
  String? length = '3:21',
  Object? views = '1,234 views',
  bool owner = true,
}) => {
  'videoRenderer': {
    'videoId': id,
    'title': {
      'runs': [
        {'text': title},
      ],
    },
    if (owner)
      'ownerText': {
        'runs': [
          {
            'text': 'Some channel',
            'navigationEndpoint': {
              'browseEndpoint': {'browseId': 'UCabcdefghijklmnopqrstuv'},
            },
          },
        ],
      },
    'lengthText': ?length == null ? null : {'simpleText': length},
    'publishedTimeText': ?published == null ? null : {'simpleText': published},
    'viewCountText': ?views == null
        ? null
        : views is String
        ? {'simpleText': views}
        : views,
    'thumbnail': {
      'thumbnails': [
        {
          'url': 'https://i.ytimg.com/vi/$id/hq.jpg',
          'width': 480,
          'height': 360,
        },
      ],
    },
  },
};

/// A YouTube results page holding [results].
String resultsPage(List<Map<String, Object?>> results) {
  final data = {
    'estimatedResults': '${results.length}',
    'contents': {
      'twoColumnSearchResultsRenderer': {
        'primaryContents': {
          'sectionListRenderer': {
            'contents': [
              {
                'itemSectionRenderer': {'contents': results},
              },
            ],
          },
        },
      },
    },
  };
  return '<html><body><script>var ytInitialData = ${jsonEncode(data)};'
      '</script></body></html>';
}

/// Points the app's YouTube service at a fake YouTube answering every
/// search with [page].
List<Uri> fakeYouTube(String Function(Uri) page, {int status = 200}) {
  final requests = <Uri>[];
  YoutubeService.useClient(
    YoutubeExplode(
      httpClient: YoutubeHttpClient(
        MockClient((request) async {
          requests.add(request.url);
          return http.Response(
            page(request.url),
            status,
            request: request,
            headers: {'content-type': 'text/html; charset=utf-8'},
          );
        }),
      ),
    ),
  );
  return requests;
}

Future<List<Video>> search(List<Map<String, Object?>> results) async {
  fakeYouTube((_) => resultsPage(results));
  return (await YoutubeService.instance.search('tinhte')).toList();
}

void main() {
  test('reads ordinary results', () async {
    final list = await search([
      video('aaaaaaaaaa1', title: 'First', length: '1:02:03'),
      video('aaaaaaaaaa2', title: 'Second', views: '5 views'),
    ]);
    expect(list.map((v) => v.id.value), ['aaaaaaaaaa1', 'aaaaaaaaaa2']);
    expect(list.first.title, 'First');
    expect(list.first.author, 'Some channel');
    expect(
      list.first.duration,
      const Duration(hours: 1, minutes: 2, seconds: 3),
    );
    expect(list.last.engagement.viewCount, 5);
  });

  test('sends the words as the search query', () async {
    final requests = fakeYouTube((_) => resultsPage([video('aaaaaaaaaa1')]));
    await YoutubeService.instance.search('nhạc trữ tình & C++');
    expect(requests.single.path, '/results');
    expect(
      requests.single.queryParameters['search_query'],
      'nhạc trữ tình & C++',
    );
  });

  // Bug 13: the "tinhte" search failed with
  // "FormatException: Invalid radix-10 number (at character 1) Streamed".
  group('odd results never fail the search', () {
    final odd = <String, Map<String, Object?>>{
      'Streamed with a non-breaking space': video(
        'bbbbbbbbbb1',
        published: 'Streamed 2 weeks ago',
      ),
      'Streamed with no time': video('bbbbbbbbbb2', published: 'Streamed'),
      'Streamed live on a date': video(
        'bbbbbbbbbb3',
        published: 'Streamed live on Oct 2, 2026',
      ),
      'Premiered': video('bbbbbbbbbb4', published: 'Premiered 5 hours ago'),
      'Scheduled': video('bbbbbbbbbb5', published: 'Scheduled for 10/30/26'),
      'no date': video('bbbbbbbbbb6', published: null),
      'unknown time unit': video('bbbbbbbbbb7', published: '3 fortnights ago'),
      'live now': video(
        'bbbbbbbbbb8',
        length: null,
        views: {
          'runs': [
            {'text': '1,234'},
            {'text': ' watching'},
          ],
        },
      ),
      'LIVE length': video('bbbbbbbbbb9', length: 'LIVE'),
      'SHORTS length': video('bbbbbbbbbc0', length: 'SHORTS'),
      'four-part length': video('bbbbbbbbbc1', length: '1:02:03:04'),
      'length with words': video('bbbbbbbbbc2', length: 'Upcoming'),
      'no views': video('bbbbbbbbbc3', views: 'No views'),
      'views missing': video('bbbbbbbbbc4', views: null),
    };
    odd.forEach((name, result) {
      test(name, () async {
        final list = await search([video('aaaaaaaaaa1'), result]);
        expect(list, hasLength(2));
        expect(list.last.id.value, (result['videoRenderer'] as Map)['videoId']);
      });
    });

    test('all of them together', () async {
      final list = await search([video('aaaaaaaaaa1'), ...odd.values]);
      expect(list, hasLength(odd.length + 1));
    });

    test(
      'a result that can\'t be read is left out, the rest still show',
      () async {
        final list = await search([
          video('aaaaaaaaaa1'),
          video('broken00001', owner: false),
          {
            'videoRenderer': {'videoId': 'broken00002'},
          },
          video('aaaaaaaaaa2'),
        ]);
        expect(list.map((v) => v.id.value), ['aaaaaaaaaa1', 'aaaaaaaaaa2']);
      },
    );

    test('other kinds of results are skipped', () async {
      final list = await search([
        {
          'shelfRenderer': {
            'title': {'simpleText': 'People also watched'},
          },
        },
        {'adSlotRenderer': {}},
        {'reelShelfRenderer': {}},
        video('aaaaaaaaaa1'),
      ]);
      expect(list.map((v) => v.id.value), ['aaaaaaaaaa1']);
    });
  });

  test('no results is an empty list, not an error', () async {
    expect(await search([]), isEmpty);
  });

  test('dates that come with search results', () {
    final now = DateTime.now();
    int daysAgo(String text) =>
        (now.difference(text.toDateTime()!).inMinutes / 1440).round();
    expect(daysAgo('Streamed 2 weeks ago'), 14);
    expect(daysAgo('Streamed 3 days ago'), 3);
    expect(daysAgo('1 day ago'), 1);
    expect(daysAgo('5 years ago'), 5 * 365);
    for (final text in [
      'Streamed',
      '',
      'Streamed live on Oct 2, 2026',
      '3 fortnights ago',
    ]) {
      expect(text.toDateTime(), isNull, reason: text);
    }
  });

  test('lengths that come with search results', () {
    expect('3:21'.toDuration(), const Duration(minutes: 3, seconds: 21));
    expect('45'.toDuration(), const Duration(seconds: 45));
    for (final text in [
      'LIVE',
      'SHORTS',
      '',
      '1:02:03:04',
      'Upcoming',
      '1:xx',
    ]) {
      expect(text.toDuration(), isNull, reason: text);
    }
  });
}
