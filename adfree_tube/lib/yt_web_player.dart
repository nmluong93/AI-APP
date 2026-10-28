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

/// Plays videos with YouTube's own mobile web player inside a WebView.
///
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
  String? _videoId;
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
    await controller.addJavaScriptChannel('AdFreeBridge',
        onMessageReceived: (message) {
      try {
        value = YtPlayerState.fromJson(
            jsonDecode(message.message) as Map<String, dynamic>);
      } catch (e) {
        debugPrint('YtWebPlayer: bad state message: $e');
      }
    });
    await controller.setNavigationDelegate(NavigationDelegate(
      onPageStarted: (_) => controller.runJavaScript(_script),
      onPageFinished: (_) => controller.runJavaScript(_script),
      onNavigationRequest: (request) {
        // Stay on the watch page: block app-store links, ad clicks, etc.
        final uri = Uri.tryParse(request.url);
        final host = uri?.host ?? '';
        final allowed = host.endsWith('youtube.com') ||
            host.endsWith('google.com') ||
            host.endsWith('gstatic.com') ||
            host.endsWith('googlevideo.com');
        return allowed && request.isMainFrame || !request.isMainFrame
            ? NavigationDecision.navigate
            : NavigationDecision.prevent;
      },
    ));
  }

  String? get videoId => _videoId;

  /// Opens [id] in the player and starts playing from [start].
  Future<void> load(String id, {Duration start = Duration.zero}) async {
    _videoId = id;
    value = const YtPlayerState(buffering: true);
    final t = start.inSeconds > 0 ? '&t=${start.inSeconds}s' : '';
    await controller
        .loadRequest(Uri.parse('https://m.youtube.com/watch?v=$id$t'));
  }

  Future<void> _cmd(String js) async {
    try {
      await controller.runJavaScript(
          'window.__adfree && window.__adfree.$js;');
    } catch (e) {
      debugPrint('YtWebPlayer: $e');
    }
  }

  Future<void> play() => _cmd('play()');
  Future<void> pause() => _cmd('pause()');
  Future<void> playOrPause() => value.playing ? pause() : play();
  Future<void> seek(Duration to) =>
      _cmd('seek(${to.inMilliseconds / 1000})');
  Future<void> setQuality(String quality) =>
      _cmd('setQuality(${jsonEncode(quality)})');

  double get volume => _volume;
  Future<void> setVolume(double v) {
    _volume = v.clamp(0, 1);
    return _cmd('setVolume($_volume)');
  }

  /// Stops playback and unloads the page.
  Future<void> stop() async {
    _videoId = null;
    value = const YtPlayerState();
    await controller.loadHtmlString(
        '<html><body style="background:#000"></body></html>');
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

  static final _script = '''
(function () {
  if (window.__adfree) return;
  const api = {};
  window.__adfree = api;

  // Pretend the page is always visible so YouTube keeps playing in the
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

  const video = () => document.querySelector('video');
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
