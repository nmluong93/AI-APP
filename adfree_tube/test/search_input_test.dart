import 'package:adfree_tube/search_input.dart';
import 'package:adfree_tube/youtube_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const id = 'dQw4w9WgXcQ';

  group('links and ids open the video', () {
    for (final input in [
      id,
      '  $id  ',
      'https://www.youtube.com/watch?v=$id',
      'http://www.youtube.com/watch?v=$id',
      'https://youtube.com/watch?v=$id',
      'www.youtube.com/watch?v=$id',
      'youtube.com/watch?v=$id',
      'https://m.youtube.com/watch?v=$id&t=42s',
      'https://www.youtube.com/watch?feature=share&v=$id',
      'https://www.youtube.com/watch?v=$id&list=PL123&index=4',
      'https://music.youtube.com/watch?v=$id&si=xyz',
      'https://WWW.YOUTUBE.COM/watch?v=$id',
      'https://youtu.be/$id',
      'youtu.be/$id',
      '  https://youtu.be/$id?si=abc  ',
      'https://youtu.be/$id?t=10',
      'https://www.youtube.com/embed/$id',
      'https://www.youtube-nocookie.com/embed/$id?rel=0',
      'https://www.youtube.com/shorts/$id',
      'https://youtube.com/shorts/$id?feature=share',
      'https://www.youtube.com/live/$id',
      'https://www.youtube.com/live/$id?si=abc',
      'https://www.youtube.com/v/$id',
      'https://youtu.be/$id\n',
    ]) {
      test(input.replaceAll('\n', r'\n'), () {
        expect(parseSearchInput(input), const VideoInput(id));
        expect(YoutubeService.parseVideoId(input), id);
      });
    }

    test('ids with - and _ in them', () {
      expect(parseSearchInput('a-b_c-d_e-f'), const VideoInput('a-b_c-d_e-f'));
      expect(
        parseSearchInput('https://youtu.be/_-_-_-_-_-_'),
        const VideoInput('_-_-_-_-_-_'),
      );
    });
  });

  group('everything else is searched for', () {
    final cases = {
      'tinhte': 'tinhte',
      'relaxing piano music': 'relaxing piano music',
      '  lofi   hip hop  ': 'lofi hip hop',
      'nhạc trữ tình': 'nhạc trữ tình',
      'Sơn Tùng M-TP': 'Sơn Tùng M-TP',
      'tin hte review': 'tin hte review',
      'line\nbreak': 'line break',
      'tab\there': 'tab here',
      // 11 letters, but plain words, not ids.
      'programming': 'programming',
      'HELLOWORLDS': 'HELLOWORLDS',
      'documentary': 'documentary',
      'TaylorSwift': 'TaylorSwift',
      'BlackPinkMV': 'BlackPinkMV',
      // Not 11 characters.
      'dQw4w9WgXc': 'dQw4w9WgXc',
      'dQw4w9WgXcQQ': 'dQw4w9WgXcQQ',
      // An id with other words is a search.
      '$id lyrics': '$id lyrics',
      // Links that aren't to one video.
      'https://www.youtube.com/@tinhte': 'https://www.youtube.com/@tinhte',
      'https://www.youtube.com/channel/UC123':
          'https://www.youtube.com/channel/UC123',
      'https://www.youtube.com/playlist?list=PL123':
          'https://www.youtube.com/playlist?list=PL123',
      'https://www.youtube.com/results?search_query=x':
          'https://www.youtube.com/results?search_query=x',
      'https://www.youtube.com/watch?v=short':
          'https://www.youtube.com/watch?v=short',
      'https://vimeo.com/watch?v=$id': 'https://vimeo.com/watch?v=$id',
      'https://example.com/$id': 'https://example.com/$id',
      'https://tinhte.vn': 'https://tinhte.vn',
      'AC/DC': 'AC/DC',
      '1/2 hour timer': '1/2 hour timer',
      'what?': 'what?',
      '?': '?',
      '#shorts': '#shorts',
      'C++ tutorial': 'C++ tutorial',
      '100%': '100%',
      'https://': 'https://',
      'http://[::1': 'http://[::1',
      'emoji 🎵🎶': 'emoji 🎵🎶',
      '"exact phrase"': '"exact phrase"',
      '-minus': '-minus',
    };
    cases.forEach((input, query) {
      test(input, () {
        expect(parseSearchInput(input), QueryInput(query));
        expect(YoutubeService.parseVideoId(input), isNull);
      });
    });

    test('a very long query is kept whole', () {
      final long = List.filled(200, 'word').join(' ');
      expect(parseSearchInput(long), QueryInput(long));
    });
  });

  group('blank input does nothing', () {
    for (final input in ['', ' ', '   ', '\n', '\t', ' ', ' \n\t ']) {
      test(input.codeUnits.toString(), () {
        expect(parseSearchInput(input), isA<EmptyInput>());
        expect(YoutubeService.parseVideoId(input), isNull);
      });
    }
  });

  test('videoIdFromLink ignores text that is not a link', () {
    expect(videoIdFromLink(id), isNull);
    expect(videoIdFromLink('tinhte'), isNull);
    expect(videoIdFromLink('https://youtu.be/'), isNull);
    expect(videoIdFromLink('https://youtu.be/abc'), isNull);
    expect(videoIdFromLink('https://www.youtube.com/watch'), isNull);
    expect(videoIdFromLink('https://www.youtube.com/shorts/'), isNull);
  });
}
