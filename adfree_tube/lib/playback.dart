import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/widgets.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart' as yt;

import 'settings.dart';
import 'youtube_service.dart';
import 'yt_web_player.dart';

/// YouTube's quality names and the resolution each one stands for.
const youtubeQualities = <String, int>{
  'highres': 4320,
  'hd2160': 2160,
  'hd1440': 1440,
  'hd1080': 1080,
  'hd720': 720,
  'large': 480,
  'medium': 360,
  'small': 240,
  'tiny': 144,
};

String qualityLabel(String quality) {
  final h = youtubeQualities[quality];
  if (h != null) return '${h}p';
  return quality == 'auto' || quality.isEmpty ? 'Auto' : quality;
}

/// Owns the one app-wide player, so playback keeps going when you leave the
/// player screen, switch apps, or lock the phone. Also runs the sleep timer.
class PlaybackController extends ChangeNotifier {
  PlaybackController._() {
    player.addListener(_onPlayerState);
    final settings = AppSettings.instance;
    const testCanvas = String.fromEnvironment('PLAYER_CANVAS');
    void syncOptions() {
      player.pageDrawnVideo = settings.pageDrawnVideo;
      player.canvasVideo =
          testCanvas.isNotEmpty ? testCanvas == 'true' : settings.canvasVideo;
    }

    syncOptions();
    player.diagnosticsHeader = () =>
        'Display: ${settings.videoDisplay}, page-drawn video: '
        '${player.pageDrawnVideo}, canvas: ${player.canvasVideo}\n';
    settings.addListener(() {
      syncOptions();
      player.applyOptions();
    });
  }

  static final instance = PlaybackController._();

  final player = YtWebPlayer();
  final _service = YoutubeService.instance;

  String? videoId;
  yt.Video? video;
  List<yt.Video> related = const [];
  String? error;
  int _loadToken = 0;
  bool _qualityApplied = false;

  bool get hasMedia => videoId != null;
  YtPlayerState get state => player.value;

  /// Loads [id] unless it is already the video being played.
  Future<void> load(String id) async {
    if (id == videoId && error == null) return;
    final token = ++_loadToken;
    videoId = id;
    video = null;
    related = const [];
    error = null;
    _qualityApplied = false;
    notifyListeners();
    await player.load(id);
    try {
      final v = await _service.getVideo(id);
      if (token != _loadToken) return;
      video = v;
      notifyListeners();
      _handler?.setMedia(v);
      AppSettings.instance
          .addToHistory(HistoryEntry(v.id.value, v.title, v.author));
      final rel = await _service.related(v);
      if (token != _loadToken) return;
      related = rel;
      notifyListeners();
    } catch (e) {
      // Details are optional; the player itself may still work.
      debugPrint('Could not load video details: $e');
    }
  }

  YtPlayerState _last = const YtPlayerState();

  void _onPlayerState() {
    final s = player.value;
    // Apply the preferred quality once the player reports what it has.
    if (!_qualityApplied && s.qualities.isNotEmpty && !s.ad) {
      _qualityApplied = true;
      final preferred = AppSettings.instance.preferredHeight;
      final pick = s.qualities.firstWhere(
        (q) => (youtubeQualities[q] ?? 99999) <= preferred,
        orElse: () => s.qualities.first,
      );
      player.setQuality(pick);
    }
    final newError = s.error;
    if (newError != error && hasMedia) error = newError;
    // Only rebuild listeners for changes they show; position updates are
    // read straight from [player] by the widgets that need them.
    if (s.playing != _last.playing ||
        s.buffering != _last.buffering ||
        s.ended != _last.ended ||
        s.ad != _last.ad ||
        s.quality != _last.quality ||
        s.qualities.length != _last.qualities.length ||
        s.error != _last.error) {
      notifyListeners();
    }
    _last = s;
    _handler?.publish();
  }

  Future<void> changeQuality(String quality) => player.setQuality(quality);

  /// Used by the on-device render test (see main.dart) in place of [load]:
  /// marks something as playing so the system media controls and the
  /// background service start, as they do for a real video.
  void startRenderTest() {
    videoId = 'render-test';
    _handler?.mediaItem.add(
      const MediaItem(id: 'render-test', title: 'Render test'),
    );
    notifyListeners();
  }

  /// Stops playback completely and clears the mini player.
  Future<void> close() async {
    _loadToken++;
    cancelSleepTimer();
    await player.stop();
    videoId = null;
    video = null;
    related = const [];
    error = null;
    notifyListeners();
    await _handler?.clear();
  }

  // ---------------------------------------------------------------------------
  // Sleep timer

  DateTime? sleepAt;
  Timer? _sleepTimer;
  Timer? _ticker;

  Duration? get sleepRemaining {
    final at = sleepAt;
    if (at == null) return null;
    final left = at.difference(DateTime.now());
    return left.isNegative ? Duration.zero : left;
  }

  void setSleepTimer(Duration duration) {
    cancelSleepTimer();
    sleepAt = DateTime.now().add(duration);
    _sleepTimer = Timer(duration, _fadeOutAndPause);
    // Refresh countdowns in the UI once a second.
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => notifyListeners());
    notifyListeners();
  }

  void cancelSleepTimer() {
    _sleepTimer?.cancel();
    _ticker?.cancel();
    _sleepTimer = null;
    _ticker = null;
    sleepAt = null;
    notifyListeners();
  }

  Future<void> _fadeOutAndPause() async {
    _ticker?.cancel();
    final volume = player.volume;
    // Lower the volume over ~5 seconds so it doesn't stop abruptly.
    for (var i = 9; i >= 0 && sleepAt != null; i--) {
      await player.setVolume(volume * i / 10);
      await Future.delayed(const Duration(milliseconds: 500));
    }
    if (sleepAt != null) await player.pause();
    await player.setVolume(volume);
    sleepAt = null;
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // System media controls (notification, lock screen, headset, macOS media
  // keys). On Android this also runs the foreground service that keeps the
  // app alive while it plays in the background.

  _MediaHandler? _handler;

  Future<void> initSystemControls() async {
    try {
      _handler = await AudioService.init(
        builder: () => _MediaHandler(this),
        config: const AudioServiceConfig(
          androidNotificationChannelId: 'com.luong.adfree_tube.playback',
          androidNotificationChannelName: 'Playback',
          androidNotificationIcon: 'mipmap/ic_launcher',
          // Workaround (bug 8): stay a foreground service while paused so Android never kills
          // playback or blocks resuming from the notification.
          androidStopForegroundOnPause: false,
          fastForwardInterval: Duration(seconds: 10),
          rewindInterval: Duration(seconds: 10),
        ),
      );
    } catch (e) {
      debugPrint('System media controls unavailable: $e');
    }
  }
}

class _MediaHandler extends BaseAudioHandler with SeekHandler {
  final PlaybackController c;

  _MediaHandler(this.c);

  void setMedia(yt.Video v) {
    mediaItem.add(MediaItem(
      id: v.id.value,
      title: v.title,
      artist: v.author,
      duration: v.duration,
      artUri: Uri.parse(v.thumbnails.highResUrl),
    ));
  }

  Future<void> clear() async {
    mediaItem.add(null);
    playbackState.add(PlaybackState());
  }

  PlaybackState? _lastPublished;

  /// Pushes the player state to the OS. Skips position-only changes, since
  /// the OS extrapolates the position from the last update.
  void publish() {
    final st = c.state;
    final prev = _lastPublished;
    final processing = !c.hasMedia
        ? AudioProcessingState.idle
        : st.ended
            ? AudioProcessingState.completed
            : st.buffering
                ? AudioProcessingState.buffering
                : AudioProcessingState.ready;
    final expected = prev == null
        ? null
        : prev.updatePosition +
            (prev.playing
                ? DateTime.now().difference(prev.updateTime)
                : Duration.zero);
    final drifted = expected == null ||
        (st.position - expected).inMilliseconds.abs() > 1500;
    if (prev != null &&
        prev.playing == st.playing &&
        prev.processingState == processing &&
        !drifted) {
      return;
    }
    final item = mediaItem.value;
    if (item != null && st.duration > Duration.zero && item.duration != st.duration) {
      mediaItem.add(item.copyWith(duration: st.duration));
    }
    _lastPublished = PlaybackState(
      controls: [
        MediaControl.rewind,
        st.playing ? MediaControl.pause : MediaControl.play,
        MediaControl.fastForward,
        MediaControl.stop,
      ],
      systemActions: const {
        MediaAction.seek,
        MediaAction.seekForward,
        MediaAction.seekBackward,
      },
      androidCompactActionIndices: const [0, 1, 2],
      processingState: processing,
      playing: st.playing,
      updatePosition: st.position,
    );
    playbackState.add(_lastPublished!);
  }

  @override
  Future<void> play() => c.player.play();

  @override
  Future<void> pause() => c.player.pause();

  @override
  Future<void> seek(Duration position) => c.player.seek(position);

  @override
  Future<void> stop() async {
    await c.close();
    await super.stop();
  }
}
