import 'package:adfree_tube/yt_web_player.dart';
import 'package:flutter_test/flutter_test.dart';

YtPlayerState state({
  int t = 0,
  int d = 0,
  bool ad = false,
  String? err,
  bool playing = false,
}) => YtPlayerState(
  position: Duration(seconds: t),
  duration: Duration(seconds: d),
  ad: ad,
  error: err,
  playing: playing,
);

void main() {
  test('nothing is lost before a video has loaded', () {
    final r = ResumePoint();
    expect(r.position, isNull);
    expect(r.lost(state()), isFalse);
  });

  test('remembers the last position of the loaded video', () {
    final r = ResumePoint()
      ..observe(state(t: 10, d: 1519, playing: true))
      ..observe(state(t: 32, d: 1519, playing: true));
    expect(r.position, const Duration(seconds: 32));
    expect(r.lost(state(t: 33, d: 1519)), isFalse);
  });

  test('an empty player after a loaded video counts as lost', () {
    final r = ResumePoint()..observe(state(t: 32, d: 1519));
    // What the page reported in the bug: 0:00 / 0:00, not playing.
    r.observe(state());
    expect(r.lost(state()), isTrue);
    // The empty state doesn't overwrite where it was.
    expect(r.position, const Duration(seconds: 32));
  });

  test('ads and errors are not a lost video', () {
    final r = ResumePoint()..observe(state(t: 32, d: 1519));
    r.observe(state(ad: true, d: 15, t: 3));
    expect(r.position, const Duration(seconds: 32));
    expect(r.lost(state(ad: true)), isFalse);
    expect(r.lost(state(err: 'Video unavailable')), isFalse);
  });

  test('loading another video forgets the old position', () {
    final r = ResumePoint()..observe(state(t: 32, d: 1519));
    r.reset();
    expect(r.position, isNull);
    expect(r.lost(state()), isFalse);
  });
}
