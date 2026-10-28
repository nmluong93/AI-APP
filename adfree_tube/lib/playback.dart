import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/widgets.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart' as yt;

import 'settings.dart';
import 'youtube_service.dart';

/// Owns the one app-wide player, so playback keeps going when you leave the
/// player screen, switch apps, or lock the phone. Also runs the sleep timer.
class PlaybackController extends ChangeNotifier with WidgetsBindingObserver {
  PlaybackController._() {
    WidgetsBinding.instance.addObserver(this);
    player.stream.completed.listen((done) {
      if (done) notifyListeners();
    });
  }

  static final instance = PlaybackController._();

  final player = Player();
  late final videoController = VideoController(player);
  final _service = YoutubeService.instance;

  String? videoId;
  yt.Video? video;
  List<PlaybackSource> sources = const [];
  PlaybackSource? current;
  List<yt.Video> related = const [];
  String? error;
  bool switching = false;
  int _loadToken = 0;

  bool get hasMedia => current != null;

  /// Loads [id] unless it is already the video being played.
  Future<void> load(String id) async {
    if (id == videoId && error == null) return;
    final token = ++_loadToken;
    videoId = id;
    video = null;
    sources = const [];
    current = null;
    related = const [];
    error = null;
    await player.stop();
    notifyListeners();
    try {
      final results = await Future.wait([
        _service.getVideo(id),
        _service.sources(id),
      ]);
      if (token != _loadToken) return;
      video = results[0] as yt.Video;
      sources = results[1] as List<PlaybackSource>;
      notifyListeners();
      _handler?.setMedia(video!);
      AppSettings.instance.addToHistory(
          HistoryEntry(video!.id.value, video!.title, video!.author));
      await play(YoutubeService.pick(sources, AppSettings.instance.preferredHeight));
      final rel = await _service.related(video!);
      if (token != _loadToken) return;
      related = rel;
      notifyListeners();
    } catch (e) {
      if (token != _loadToken) return;
      error = '$e';
      notifyListeners();
    }
  }

  /// Opens [source], keeping the current position when switching quality.
  /// If it doesn't start playing, falls back to simpler streams (360p muxed,
  /// then HLS) before giving up with an error message.
  Future<void> play(PlaybackSource source, {Duration? from}) async {
    final token = _loadToken;
    current = source;
    switching = true;
    error = null;
    notifyListeners();
    final candidates = [source, ..._fallbacks(source)];
    String? lastError;
    for (final candidate in candidates) {
      if (token != _loadToken) return;
      if (candidate != source) {
        debugPrint('Playback of ${current?.label} failed ($lastError); trying ${candidate.label}');
      }
      current = candidate;
      notifyListeners();
      lastError = await _tryOpen(candidate, from);
      if (lastError == null) break;
    }
    if (token != _loadToken) return;
    if (lastError != null) {
      error = 'Could not play this video: $lastError';
    }
    switching = false;
    notifyListeners();
  }

  /// Simpler streams to try when [failed] doesn't play, most likely first.
  List<PlaybackSource> _fallbacks(PlaybackSource failed) {
    final muxed = sources.where((s) => s.audioUrl == null && s.height > 0);
    final hls = sources.where((s) => s.height == 0);
    final split = sources.where((s) => s.audioUrl != null && s.height <= 720);
    return {...muxed, ...hls, ...split}
        .where((s) => s != failed)
        .take(3)
        .toList();
  }

  /// Opens one source and waits until it is actually playing. Returns null on
  /// success, or a short reason on failure.
  Future<String?> _tryOpen(PlaybackSource source, Duration? from) async {
    String? playerError;
    final sub = player.stream.error.listen((e) => playerError = e);
    try {
      final headers = source.headers;
      final native = player.platform;
      if (native is NativePlayer) {
        await native.setProperty('user-agent', headers['User-Agent']!);
      }
      await player.open(Media(source.videoUrl, httpHeaders: headers), play: false);

      // Wait until the file is loaded before adding audio or seeking.
      final loaded = await _waitFor(
        () => player.state.duration > Duration.zero || playerError != null,
        const Duration(seconds: 20),
      );
      if (!loaded || player.state.duration == Duration.zero) {
        return playerError ?? 'timed out loading the stream';
      }
      if (source.audioUrl != null) {
        await player.setAudioTrack(AudioTrack.uri(source.audioUrl!));
      }
      if (from != null && from > Duration.zero) await player.seek(from);
      if (_inBackground && !source.audioOnly) {
        await player.setVideoTrack(VideoTrack.no());
      }
      final startAt = player.state.position;
      await player.play();

      // Make sure it really plays rather than buffering forever. If the user
      // pauses meanwhile, count that as success.
      final started = await _waitFor(
        () =>
            !player.state.playing ||
            player.state.position > startAt + const Duration(milliseconds: 500),
        const Duration(seconds: 20),
      );
      if (!started) return playerError ?? 'stream stalled while buffering';
      return null;
    } catch (e) {
      return '$e';
    } finally {
      await sub.cancel();
    }
  }

  static Future<bool> _waitFor(bool Function() test, Duration timeout) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (test()) return true;
      await Future.delayed(const Duration(milliseconds: 250));
    }
    return test();
  }

  Future<void> changeQuality(PlaybackSource source) =>
      play(source, from: player.state.position);

  /// Stops playback completely and clears the mini player.
  Future<void> close() async {
    _loadToken++;
    cancelSleepTimer();
    await player.stop();
    videoId = null;
    video = null;
    sources = const [];
    current = null;
    related = const [];
    error = null;
    notifyListeners();
    await _handler?.clear();
  }

  // ---------------------------------------------------------------------------
  // Background: on Android the video surface goes away when the app is hidden,
  // so we turn off video decoding (audio keeps going) and turn it back on when
  // the app returns. macOS keeps rendering normally.

  bool _inBackground = false;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!Platform.isAndroid || !hasMedia || current!.audioOnly) return;
    if (state == AppLifecycleState.paused && !_inBackground) {
      _inBackground = true;
      player.setVideoTrack(VideoTrack.no());
    } else if (state == AppLifecycleState.resumed && _inBackground) {
      _inBackground = false;
      player.setVideoTrack(VideoTrack.auto());
    }
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
    final volume = player.state.volume;
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
  // System media controls (notification, lock screen, headset, macOS media keys)

  _MediaHandler? _handler;

  Future<void> initSystemControls() async {
    try {
      _handler = await AudioService.init(
        builder: () => _MediaHandler(this),
        config: const AudioServiceConfig(
          androidNotificationChannelId: 'com.luong.adfree_tube.playback',
          androidNotificationChannelName: 'Playback',
          androidNotificationIcon: 'mipmap/ic_launcher',
          // Stay a foreground service while paused so Android never kills
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

  _MediaHandler(this.c) {
    final s = c.player.stream;
    s.playing.listen((_) => _publish());
    s.buffering.listen((_) => _publish());
    s.completed.listen((_) => _publish());
    s.duration.listen((d) {
      final item = mediaItem.value;
      if (item != null && d > Duration.zero) {
        mediaItem.add(item.copyWith(duration: d));
      }
    });
  }

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

  void _publish() {
    final st = c.player.state;
    playbackState.add(PlaybackState(
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
      processingState: !c.hasMedia
          ? AudioProcessingState.idle
          : st.completed
              ? AudioProcessingState.completed
              : st.buffering
                  ? AudioProcessingState.buffering
                  : AudioProcessingState.ready,
      playing: st.playing,
      updatePosition: st.position,
      bufferedPosition: st.buffer,
      speed: st.rate,
    ));
  }

  @override
  Future<void> play() => c.player.play();

  @override
  Future<void> pause() => c.player.pause();

  @override
  Future<void> seek(Duration position) async {
    await c.player.seek(position);
    _publish();
  }

  @override
  Future<void> stop() async {
    await c.close();
    await super.stop();
  }
}
