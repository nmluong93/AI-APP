import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';

/// Snapshot of what the YouTube player is doing, reported by the page.
@immutable
class YtPlayerState {
  final bool playing;
  final bool buffering;
  final bool ended;
  final bool ad;
  final Duration position;
  final Duration duration;
  final String quality;
  final List<String> qualities;
  final String? error;

  const YtPlayerState({
    this.playing = false,
    this.buffering = false,
    this.ended = false,
    this.ad = false,
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.quality = '',
    this.qualities = const [],
    this.error,
  });

  factory YtPlayerState.fromJson(Map<String, dynamic> j) {
    Duration secs(Object? v) => v is num && v.isFinite
        ? Duration(milliseconds: (v * 1000).round())
        : Duration.zero;
    return YtPlayerState(
      playing: j['playing'] == true,
      buffering: j['buffering'] == true,
      ended: j['ended'] == true,
      ad: j['ad'] == true,
      position: secs(j['t']),
      duration: secs(j['d']),
      quality: (j['q'] as String?) ?? '',
      qualities: ((j['qs'] as List?) ?? const []).cast<String>(),
      error: j['err'] as String?,
    );
  }
}

/// Remembers where the loaded video was, so playback can pick up from there
/// if the page loses it.
///
/// Workaround (bug 17 in the README "Known bugs and workarounds"): after
/// switching away from the app and back, the page sometimes ends up with an
/// empty player (0:00 / 0:00) that won't play.
class ResumePoint {
  Duration? _position;

  /// Where the video was last seen playing, or null if none was loaded yet.
  Duration? get position => _position;

  /// Call with every state the page reports.
  void observe(YtPlayerState s) {
    if (!s.ad && s.duration > Duration.zero) _position = s.position;
  }

  /// A different video is being loaded.
  void reset() => _position = null;

  /// Whether the page has lost a video it had loaded: no length any more,
  /// with no ad or error to explain it.
  bool lost(YtPlayerState s) =>
      _position != null &&
      s.duration == Duration.zero &&
      !s.ad &&
      s.error == null;
}

/// Plays videos with YouTube's own mobile web player inside a WebView.
///
/// Workaround (bug 3 in the README "Known bugs and workarounds"):
/// YouTube only serves video to its own players (they pass an anti-bot check
/// that third-party players can't), so instead of fetching streams ourselves
/// we let the real player do it and strip everything else from the page:
/// - CSS makes the video fill the view and hides the site, its controls and
///   ad overlays; the app draws its own controls on top.
/// - A script skips video ads the moment they start (mute, jump to the end,
///   press "Skip"), and reports the player state back to Dart.
/// - The page is told it's always visible, so YouTube doesn't pause when the
///   app is in the background or the screen is off.
class YtWebPlayer extends ValueNotifier<YtPlayerState> {
  YtWebPlayer() : super(const YtPlayerState()) {
    controller = WebViewController.fromPlatformCreationParams(_params());
    _setUp();
  }

  late final WebViewController controller;

  /// See [AppSettings.pageDrawnVideo]. Apply changes with [applyOptions].
  bool pageDrawnVideo = true;

  /// See [AppSettings.canvasVideo]. Apply changes with [applyOptions].
  bool canvasVideo = true;

  /// Extra lines added to [diagnostics], e.g. the display mode in use.
  String Function()? diagnosticsHeader;
  String? _videoId;
  String? _testHost;
  double _volume = 1;

  // A mobile browser user agent, so YouTube serves its mobile site (whose
  // player we know how to clean up) on macOS too.
  static const _userAgent =
      'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/130.0.0.0 Mobile Safari/537.36';

  static PlatformWebViewControllerCreationParams _params() {
    if (WebViewPlatform.instance is WebKitWebViewPlatform) {
      return WebKitWebViewControllerCreationParams(
        allowsInlineMediaPlayback: true,
        mediaTypesRequiringUserAction: const <PlaybackMediaTypes>{},
      );
    }
    return const PlatformWebViewControllerCreationParams();
  }

  Future<void> _setUp() async {
    final platform = controller.platform;
    if (platform is AndroidWebViewController) {
      await platform.setMediaPlaybackRequiresUserGesture(false);
      // Lets chrome://inspect attach to the page in debug builds.
      if (kDebugMode) await AndroidWebViewController.enableDebugging(true);
    } else if (platform is WebKitWebViewController && kDebugMode) {
      await platform.setInspectable(true);
    }
    await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
    if (!Platform.isMacOS) {
      await controller.setBackgroundColor(const Color(0xFF000000));
    }
    await controller.setUserAgent(_userAgent);
    await controller.addJavaScriptChannel(
      'AdFreeBridge',
      onMessageReceived: (message) {
        try {
          value = YtPlayerState.fromJson(
            jsonDecode(message.message) as Map<String, dynamic>,
          );
        } catch (e) {
          debugPrint('YtWebPlayer: bad state message: $e');
        }
      },
    );
    await controller.setNavigationDelegate(
      NavigationDelegate(
        onPageStarted: (_) => controller.runJavaScript(_withOptions()),
        onPageFinished: (_) => controller.runJavaScript(_withOptions()),
        onNavigationRequest: (request) {
          // Stay on the watch page: block app-store links, ad clicks, etc.
          final uri = Uri.tryParse(request.url);
          final host = uri?.host ?? '';
          final allowed =
              host.endsWith('youtube.com') ||
              host.endsWith('google.com') ||
              host.endsWith('gstatic.com') ||
              host.endsWith('googlevideo.com') ||
              // The page the render test opened (see [loadUrl]). WebKit asks
              // about pages the app loads itself too, so without this the
              // macOS test page was blocked.
              host == _testHost;
          return allowed && request.isMainFrame || !request.isMainFrame
              ? NavigationDecision.navigate
              : NavigationDecision.prevent;
        },
      ),
    );
  }

  String? get videoId => _videoId;

  String get _optionsJs =>
      'window.__adfreeOptions = ${jsonEncode({'pageDrawnVideo': pageDrawnVideo, 'canvasVideo': canvasVideo})};';

  String _withOptions() => '$_optionsJs\n$_script';

  /// Sends changed options to the page; the script reads them live.
  Future<void> applyOptions() async {
    try {
      await controller.runJavaScript(_optionsJs);
    } catch (e) {
      debugPrint('YtWebPlayer: $e');
    }
  }

  /// Shows an orange square on the page for a few seconds. If it shows up,
  /// the WebView itself is on screen, whatever happens to the video.
  Future<void> showTestSquare() => _cmd('testSquare()');

  /// Opens [id] in the player and starts playing from [start].
  Future<void> load(String id, {Duration start = Duration.zero}) async {
    _videoId = id;
    value = const YtPlayerState(buffering: true);
    final t = start.inSeconds > 0 ? '&t=${start.inSeconds}s' : '';
    await controller.loadRequest(
      Uri.parse('https://m.youtube.com/watch?v=$id$t'),
    );
  }

  /// Opens any page. Only used by the on-device rendering test.
  Future<void> loadUrl(String url) async {
    _videoId = 'test';
    _testHost = Uri.parse(url).host;
    await controller.loadRequest(Uri.parse(url));
  }

  Future<void> _cmd(String js) async {
    try {
      await controller.runJavaScript('window.__adfree && window.__adfree.$js;');
    } catch (e) {
      debugPrint('YtWebPlayer: $e');
    }
  }

  Future<void> play() => _cmd('play()');
  Future<void> pause() => _cmd('pause()');
  Future<void> playOrPause() => value.playing ? pause() : play();

  /// Resets the page's video pipeline in place; see `api.refresh` in the
  /// page script. Called when the app comes back to the front.
  Future<void> refresh() => _cmd('refresh()');
  Future<void> seek(Duration to) => _cmd('seek(${to.inMilliseconds / 1000})');
  Future<void> setQuality(String quality) =>
      _cmd('setQuality(${jsonEncode(quality)})');

  /// A readable report of what the page's player is doing, for bug reports.
  Future<String> diagnostics() async {
    try {
      final result = await controller.runJavaScriptReturningResult(
        'window.__adfree ? window.__adfree.debug() : "Player script not loaded"',
      );
      var text = result is String ? result : result.toString();
      // Android returns the string JSON-encoded a second time.
      if (text.startsWith('"')) {
        try {
          text = jsonDecode(text) as String;
        } catch (_) {}
      }
      final header = diagnosticsHeader?.call() ?? '';
      return 'Video: $_videoId\n${header}State: ${jsonEncode(_stateJson())}\n$text';
    } catch (e) {
      return 'Could not read the player: $e';
    }
  }

  Map<String, Object?> _stateJson() => {
    'playing': value.playing,
    'buffering': value.buffering,
    'ad': value.ad,
    'position': value.position.inSeconds,
    'duration': value.duration.inSeconds,
    'error': value.error,
  };

  double get volume => _volume;
  Future<void> setVolume(double v) {
    _volume = v.clamp(0, 1);
    return _cmd('setVolume($_volume)');
  }

  /// Stops playback and unloads the page.
  Future<void> stop() async {
    _videoId = null;
    value = const YtPlayerState();
    // Workaround (bug 18): a WebView that stopped answering (as in bug 17)
    // must not keep Stop from finishing, so give up on it after a moment.
    try {
      await controller
          .loadHtmlString('<html><body style="background:#000"></body></html>')
          .timeout(const Duration(seconds: 3));
    } catch (e) {
      debugPrint('YtWebPlayer: could not clear the page: $e');
    }
  }

  static const _css = r'''
html, body { background: #000 !important; overflow: hidden !important; }
#player-container-id, .player-container, #player, ytm-player,
.player-size, .html5-video-player, #movie_player {
  position: fixed !important; inset: 0 !important; top: 0 !important;
  left: 0 !important; width: 100vw !important; height: 100vh !important;
  max-width: none !important; max-height: none !important;
  margin: 0 !important; padding: 0 !important;
  z-index: 2147483640 !important; background: #000 !important;
  transform: none !important;
}
.html5-video-container, video.html5-main-video, video {
  position: fixed !important; inset: 0 !important; top: 0 !important;
  left: 0 !important; width: 100vw !important; height: 100vh !important;
  object-fit: contain !important; z-index: 2147483641 !important;
}
/* The app draws its own controls; hide YouTube's UI and ad overlays. */
.ytp-chrome-bottom, .ytp-chrome-top, .ytp-gradient-top, .ytp-gradient-bottom,
#player-control-container, .player-controls-content, ytm-custom-control,
.player-controls-background, .ytp-ad-overlay-container, .ytp-ad-module,
.ytp-ad-player-overlay, .ytp-ad-text, .ytp-paid-content-overlay,
ytm-promoted-sparkles-web-renderer, ytm-companion-ad-renderer,
ad-slot-renderer, ytm-promoted-video-renderer, .ytp-ce-element,
.ytp-pause-overlay, .ytp-spinner, ytm-mobile-topbar-renderer, header,
ytm-pivot-bar-renderer, .mobile-topbar-header, ytm-app-promo-renderer,
.ytm-autonav-bar, ytm-engagement-panel, .watch-below-the-player {
  display: none !important;
}
''';

  static final _script =
      '''
(function () {
  if (window.__adfree) return;
  const api = {};
  window.__adfree = api;

  // Workaround (bug 8): pretend the page is always visible so YouTube keeps playing in the
  // background and with the screen off.
  try {
    Object.defineProperty(document, 'hidden', { get: () => false });
    Object.defineProperty(document, 'visibilityState', { get: () => 'visible' });
    Object.defineProperty(document, 'webkitHidden', { get: () => false });
  } catch (e) {}
  for (const type of ['visibilitychange', 'webkitvisibilitychange', 'pagehide', 'blur']) {
    window.addEventListener(type, (e) => e.stopImmediatePropagation(), true);
    document.addEventListener(type, (e) => e.stopImmediatePropagation(), true);
  }

  function addStyle() {
    if (document.getElementById('__adfree_css')) return;
    const style = document.createElement('style');
    style.id = '__adfree_css';
    style.textContent = ${jsonEncode(_css)};
    (document.head || document.documentElement).appendChild(style);
  }

  // Workaround (bug 6): the main player's <video>, not a muted preview elsewhere on the page.
  const video = () =>
    document.querySelector('#movie_player video') ||
    document.querySelector('video.html5-main-video') ||
    document.querySelector('video');
  const player = () => document.getElementById('movie_player');

  let wantPlaying = true;
  let volume = 1;
  let mutedForAd = false;

  api.play = () => { wantPlaying = true; const p = player(); if (p && p.playVideo) p.playVideo(); else if (video()) video().play(); };
  api.pause = () => { wantPlaying = false; const p = player(); if (p && p.pauseVideo) p.pauseVideo(); else if (video()) video().pause(); };
  api.seek = (t) => { const p = player(); if (p && p.seekTo) p.seekTo(t, true); else if (video()) video().currentTime = t; };
  api.setVolume = (v) => { volume = v; const el = video(); if (el && !mutedForAd) el.volume = v; };
  api.setQuality = (q) => {
    const p = player();
    if (!p) return;
    if (p.setPlaybackQualityRange) p.setPlaybackQualityRange(q, q);
    if (p.setPlaybackQuality) p.setPlaybackQuality(q);
  };

  // Workaround (bug 5): YouTube's mobile site starts videos muted ("Tap to unmute"), and the
  // app never lets taps reach the page, so turn the sound on ourselves.
  function unmute(p, el) {
    try {
      if (p && p.isMuted && p.isMuted()) p.unMute();
      if (p && p.getVolume && p.getVolume() === 0) p.setVolume(100);
    } catch (e) {}
    if (el) {
      if (el.muted) el.muted = false;
      if (Math.abs(el.volume - volume) > 0.01) el.volume = volume;
    }
  }

  // Everything useful for working out why the video doesn't show or play.
  // Workaround (bug 7 in the README "Known bugs and workarounds"): on some
  // phones (a Galaxy S23) the <video> plays and is on the page, but its
  // picture never reaches the screen inside the app, while it does on an
  // emulator. Whatever the phone does with the video layer, a <canvas> is
  // drawn like any other page content, so copy each video frame into a
  // canvas laid over the video. Costs a little battery; Settings can turn
  // it off.
  let canvasFrames = 0;
  let lastFrameTime = -1;
  // Frame timing, so a bug report can tell a slow page (low fps, slow
  // canvas copies) from a struggling decoder (dropped frames) or network
  // (waiting events, little buffered).
  const frameTimes = [];
  const drawTimes = [];
  let waitingEvents = 0;
  let refreshes = 0;
  function canvas() {
    let c = document.getElementById('__adfree_canvas');
    if (!c) {
      c = document.createElement('canvas');
      c.id = '__adfree_canvas';
      c.style.cssText = 'position:fixed!important;left:0!important;top:0!important;' +
        'width:100vw!important;height:100vh!important;z-index:2147483646!important;' +
        'background:#000!important;pointer-events:none!important;display:block!important';
      document.documentElement.appendChild(c);
    }
    return c;
  }
  function drawFrame() {
    const opts = window.__adfreeOptions || {};
    const el = video();
    const existing = document.getElementById('__adfree_canvas');
    if (opts.canvasVideo === false || !el || !el.videoWidth) {
      if (existing) existing.style.setProperty('display', 'none', 'important');
      return;
    }
    const c = canvas();
    c.style.setProperty('display', 'block', 'important');
    const dpr = Math.min(window.devicePixelRatio || 1, 2);
    const W = Math.round(innerWidth * dpr), H = Math.round(innerHeight * dpr);
    const resized = c.width !== W || c.height !== H;
    if (resized) { c.width = W; c.height = H; }
    // Skip redrawing a paused frame.
    if (!resized && el.currentTime === lastFrameTime) return;
    lastFrameTime = el.currentTime;
    const g = c.getContext('2d');
    const s = Math.min(W / el.videoWidth, H / el.videoHeight);
    const w = el.videoWidth * s, h = el.videoHeight * s;
    g.fillStyle = '#000';
    g.fillRect(0, 0, W, H);
    try {
      const t0 = performance.now();
      g.drawImage(el, (W - w) / 2, (H - h) / 2, w, h);
      drawTimes.push(performance.now() - t0);
      if (drawTimes.length > 60) drawTimes.shift();
      canvasFrames++;
    } catch (e) {}
  }
  (function loop(now) {
    if (now) {
      frameTimes.push(now);
      if (frameTimes.length > 240) frameTimes.shift();
    }
    drawFrame();
    requestAnimationFrame(loop);
  })();

  // Workaround (bug 16): back in front after the app was in the background: Android hid the
  // WebView for a moment before the app's keep-awake workaround (bug 10)
  // answered, and Chromium's video pipeline can stay out of step after
  // that, so playback stutters until the next seek. Seeking to where it
  // already is resets it, with buffered data, so it's near instant.
  // Only on the <video> itself, and only when what's around the current
  // spot is already buffered: going through YouTube's own seekTo here could
  // make it reset the video (bug 17).
  api.refresh = () => {
    const el = video();
    if (!el || el.paused || el.ended || el.readyState < 3 || !isFinite(el.duration)) return;
    const p = player();
    if (p && (p.classList.contains('ad-showing') || p.classList.contains('ad-interrupting'))) return;
    const t = el.currentTime;
    let buffered = false;
    for (let i = 0; i < el.buffered.length; i++) {
      if (el.buffered.start(i) <= t && t + 1 <= el.buffered.end(i)) buffered = true;
    }
    if (!buffered) return;
    refreshes++;
    lastFrameTime = -1;
    el.currentTime = t;
  };

  api.testSquare = () => {
    const d = document.createElement('div');
    d.style.cssText = 'position:fixed!important;left:0!important;top:0!important;' +
      'width:30vw!important;height:30vh!important;background:rgb(255,140,0)!important;' +
      'z-index:2147483647!important;pointer-events:none!important';
    document.documentElement.appendChild(d);
    setTimeout(() => d.remove(), 5000);
  };

  api.debug = () => {
    const p = player();
    const info = {
      options: window.__adfreeOptions || null,
      canvasFrames: canvasFrames,
      perf: (() => {
        const now = performance.now();
        const recent = frameTimes.filter((t) => now - t <= 2000);
        const el = video();
        const q = el && el.getVideoPlaybackQuality ? el.getVideoPlaybackQuality() : null;
        let ahead = null;
        if (el) {
          for (let i = 0; i < el.buffered.length; i++) {
            if (el.buffered.start(i) <= el.currentTime && el.currentTime <= el.buffered.end(i)) {
              ahead = +(el.buffered.end(i) - el.currentTime).toFixed(1);
            }
          }
        }
        const avg = drawTimes.length ? drawTimes.reduce((a, b) => a + b, 0) / drawTimes.length : null;
        return {
          fps: recent.length > 1 ? +((recent.length - 1) / ((recent[recent.length - 1] - recent[0]) / 1000)).toFixed(1) : 0,
          canvasDrawMs: avg === null ? null : +avg.toFixed(2),
          canvasDrawMaxMs: drawTimes.length ? +Math.max(...drawTimes).toFixed(2) : null,
          videoFrames: q ? q.totalVideoFrames : null,
          droppedFrames: q ? q.droppedVideoFrames : null,
          bufferedAhead: ahead,
          waitingEvents: waitingEvents,
          refreshes: refreshes,
          playbackRate: el ? el.playbackRate : null,
        };
      })(),
      canvasCentre: (() => {
        const c = document.getElementById('__adfree_canvas');
        if (!c || !c.width) return null;
        try {
          const d = c.getContext('2d').getImageData(c.width >> 1, c.height >> 1, 1, 1).data;
          return d[0] + ',' + d[1] + ',' + d[2] + ' (' + c.style.display + ')';
        } catch (e) { return 'unreadable: ' + e; }
      })(),
      url: location.href,
      title: document.title,
      hidden: document.hidden,
      playerClasses: p ? p.className : null,
      playerMuted: p && p.isMuted ? p.isMuted() : null,
      playerVolume: p && p.getVolume ? p.getVolume() : null,
      playerState: p && p.getPlayerState ? p.getPlayerState() : null,
      quality: p && p.getPlaybackQuality ? p.getPlaybackQuality() : null,
      error: (document.querySelector('.ytp-error') || {}).innerText || null,
      videos: Array.from(document.querySelectorAll('video')).map((v) => {
        const r = v.getBoundingClientRect();
        const cs = getComputedStyle(v);
        return {
          main: v === video(),
          src: (v.currentSrc || v.src || '').slice(0, 40),
          paused: v.paused, muted: v.muted, volume: v.volume,
          readyState: v.readyState, networkState: v.networkState,
          time: v.currentTime, duration: v.duration,
          size: v.videoWidth + 'x' + v.videoHeight,
          rect: [r.x, r.y, r.width, r.height].map(Math.round).join(','),
          display: cs.display, visibility: cs.visibility, opacity: cs.opacity,
          error: v.error ? v.error.code + ' ' + v.error.message : null,
        };
      }),
      parents: (() => {
        const out = [];
        for (let n = video(); n && n !== document.documentElement; n = n.parentElement) {
          const cs = getComputedStyle(n);
          const r = n.getBoundingClientRect();
          out.push(n.tagName.toLowerCase() + (n.id ? '#' + n.id : '') +
            (n.className && typeof n.className === 'string' ? '.' + n.className.trim().split(/\\s+/).slice(0, 3).join('.') : '') +
            ' ' + cs.display + '/' + cs.visibility + '/' + cs.opacity + '/' + cs.position +
            ' ' + [r.x, r.y, r.width, r.height].map(Math.round).join(','));
        }
        return out;
      })(),
      viewport: innerWidth + 'x' + innerHeight,
      userAgent: navigator.userAgent,
    };
    return JSON.stringify(info, null, 1);
  };

  // Workaround (bug 7): our CSS hides parts of the site by class name, and YouTube moves its
  // player around between releases. If anything above the video ends up
  // hidden, the sound plays but the picture doesn't, so force the video's
  // whole chain of parents back into view. (Inline !important styles win
  // over stylesheet !important ones.)
  function keepVisible(el) {
    for (let n = el; n && n !== document.documentElement; n = n.parentElement) {
      const cs = getComputedStyle(n);
      if (cs.display === 'none') n.style.setProperty('display', 'block', 'important');
      if (cs.visibility !== 'visible') n.style.setProperty('visibility', 'visible', 'important');
      if (n !== el && cs.opacity !== '1') n.style.setProperty('opacity', '1', 'important');
      if (n !== el && cs.overflow !== 'visible') n.style.setProperty('overflow', 'visible', 'important');
      if (n !== el && cs.transform !== 'none') n.style.setProperty('transform', 'none', 'important');
      if (cs.filter !== 'none') n.style.setProperty('filter', 'none', 'important');
      if (cs.contain !== 'none') n.style.setProperty('contain', 'none', 'important');
    }
    el.style.setProperty('position', 'fixed', 'important');
    el.style.setProperty('inset', '0', 'important');
    el.style.setProperty('width', '100vw', 'important');
    el.style.setProperty('height', '100vh', 'important');
    el.style.setProperty('object-fit', 'contain', 'important');
    el.style.setProperty('z-index', '2147483647', 'important');
    // Workaround (bug 7): on real phones Android's WebView can hand video to
    // a separate hardware layer that sits behind the page and shows through
    // a transparent hole. Flutter doesn't composite that layer, so the hole
    // could show up black while the sound plays. Only fully opaque,
    // unrotated video is handed off, so 0.99 opacity and a tiny rotation
    // (both invisible) keep it drawn into the page. Settings can turn this
    // off to compare.
    const opts = window.__adfreeOptions || {};
    if (opts.pageDrawnVideo !== false) {
      el.style.setProperty('opacity', '0.99', 'important');
      el.style.setProperty('transform', 'rotate(0.001deg)', 'important');
    } else {
      el.style.setProperty('opacity', '1', 'important');
      el.style.setProperty('transform', 'none', 'important');
    }
  }

  function skipAds() {
    const p = player();
    const el = video();
    const ad = !!(p && (p.classList.contains('ad-showing') || p.classList.contains('ad-interrupting')));
    if (ad && el) {
      if (!mutedForAd) { mutedForAd = true; el.muted = true; }
      if (isFinite(el.duration) && el.duration > 0 && el.currentTime < el.duration - 0.1) {
        el.currentTime = el.duration;
      }
    } else if (mutedForAd && el) {
      mutedForAd = false;
      el.muted = false;
      el.volume = volume;
    }
    if (!ad) unmute(p, el);
    document.querySelectorAll(
      '.ytp-ad-skip-button, .ytp-ad-skip-button-modern, .ytp-skip-ad-button, ' +
      '.ytp-ad-skip-button-container button, button.ytp-ad-skip-button-slot'
    ).forEach((b) => { try { b.click(); } catch (e) {} });
    return ad;
  }

  let last = '';
  function tick() {
    addStyle();
    const ad = skipAds();
    const el = video();
    if (el) keepVisible(el);
    if (el && !el.__adfreeWaiting) {
      el.__adfreeWaiting = true;
      el.addEventListener('waiting', () => waitingEvents++);
    }
    const p = player();
    let err = null;
    const errBox = document.querySelector('.ytp-error-content-wrap-reason, .ytp-error .ytp-error-content');
    if (errBox && errBox.offsetParent !== null) err = errBox.innerText.trim() || 'Playback error';
    // Resume if YouTube paused on its own (e.g. "are you still watching?").
    if (el && el.paused && wantPlaying && !el.ended && !ad && el.readyState >= 2) {
      el.play().catch(() => {});
    }
    const state = {
      playing: !!(el && !el.paused && !el.ended),
      buffering: !el || el.readyState < 3,
      ended: !!(el && el.ended),
      ad: ad,
      t: el && !ad ? el.currentTime : 0,
      d: el && !ad && isFinite(el.duration) ? el.duration : 0,
      q: p && p.getPlaybackQuality ? p.getPlaybackQuality() : '',
      qs: p && p.getAvailableQualityLevels ? p.getAvailableQualityLevels() : [],
      err: err,
    };
    const json = JSON.stringify(state);
    if (json !== last) {
      last = json;
      try { AdFreeBridge.postMessage(json); } catch (e) {}
    }
  }
  setInterval(tick, 250);
  tick();
})();
''';
}
