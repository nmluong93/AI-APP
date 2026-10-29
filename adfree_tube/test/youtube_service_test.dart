import 'package:adfree_tube/youtube_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('finds the video id in links people paste', () {
    const id = 'dQw4w9WgXcQ';
    for (final input in [
      id,
      'https://www.youtube.com/watch?v=$id',
      'https://m.youtube.com/watch?v=$id&t=42s',
      'https://youtu.be/$id',
      '  https://youtu.be/$id?si=abc  ',
      'https://www.youtube.com/embed/$id',
    ]) {
      expect(YoutubeService.parseVideoId(input), id, reason: input);
    }
  });

  test('returns null for search text', () {
    expect(YoutubeService.parseVideoId(''), isNull);
    expect(YoutubeService.parseVideoId('   '), isNull);
    expect(YoutubeService.parseVideoId('relaxing piano music'), isNull);
  });
}
