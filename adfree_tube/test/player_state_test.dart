import 'package:adfree_tube/playback.dart';
import 'package:adfree_tube/yt_web_player.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parses the state reported by the page', () {
    final s = YtPlayerState.fromJson({
      'playing': true,
      'buffering': false,
      'ended': false,
      'ad': false,
      't': 12.5,
      'd': 3600.25,
      'q': 'hd720',
      'qs': ['hd1080', 'hd720', 'auto'],
      'err': null,
    });
    expect(s.playing, isTrue);
    expect(s.position, const Duration(milliseconds: 12500));
    expect(s.duration, const Duration(milliseconds: 3600250));
    expect(s.qualities, ['hd1080', 'hd720', 'auto']);
    expect(s.error, isNull);
  });

  test('treats missing or non-finite times as zero', () {
    final s = YtPlayerState.fromJson({'t': null, 'd': double.nan});
    expect(s.position, Duration.zero);
    expect(s.duration, Duration.zero);
    expect(s.qualities, isEmpty);
  });

  test('labels YouTube quality names', () {
    expect(qualityLabel('hd1080'), '1080p');
    expect(qualityLabel('large'), '480p');
    expect(qualityLabel('auto'), 'Auto');
    expect(qualityLabel(''), 'Auto');
  });
}
