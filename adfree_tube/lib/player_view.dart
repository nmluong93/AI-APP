import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

import 'playback.dart';
import 'settings.dart';
import 'widgets.dart';
import 'yt_web_player.dart';

/// Decides which widget shows the player's one WebView: the newest
/// [VideoSurface] (the player or fullscreen screen), or [background] (the
/// 1x1 view of [BackgroundVideoHost]) when no player screen is open.
///
/// Workaround (bug 9 in the README "Known bugs and workarounds"): one
/// WebView can only be on screen in one place at a time.
///
/// Workaround (bug 12): with hybrid composition, showing the WebView in its
/// new place in the same frame it leaves the old one crashes the app (the
/// Android view still has its old parent). So a change of place goes through
/// [owner] = null first, and the new place takes over a moment later.
class VideoHosts {
  VideoHosts._();

  static final _hosts = <Object>[];

  /// Stands for [BackgroundVideoHost].
  static final background = Object();

  /// Where the WebView is shown now; null while it moves.
  static final owner = ValueNotifier<Object?>(background);

  static const handOffDelay = Duration(milliseconds: 150);
  static int _change = 0;

  static Object get _target => _hosts.isEmpty ? background : _hosts.last;

  static void add(Object host) {
    _hosts.add(host);
    _handOff();
  }

  static void remove(Object host) {
    _hosts.remove(host);
    _handOff();
  }

  static void _handOff() {
    final change = ++_change;
    // Called from initState and dispose, so change [owner] after the
    // current frame rather than while widgets are building.
    Timer.run(() {
      if (change != _change) return;
      if (owner.value == _target) return;
      owner.value = null;
      Timer(handOffDelay, () {
        if (change == _change) owner.value = _target;
      });
    });
  }
}

/// The player's WebView, embedded the way Settings says.
class PlayerWebView extends StatelessWidget {
  const PlayerWebView({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: AppSettings.instance,
      builder: (context, _) => _forDisplay(AppSettings.instance.videoDisplay),
    );
  }

  Widget _forDisplay(String display) {
    final controller = PlaybackController.instance.player.controller;
    // Workaround (bug 7 in the README "Known bugs and workarounds"): some
    // phones show web video black in one of Android's two ways of embedding
    // a WebView, so the mode is a setting. 'hybrid' puts the real Android
    // view on screen; 'texture' draws it into a Flutter texture.
    const testHybrid = String.fromEnvironment('PLAYER_HYBRID');
    final hybrid = testHybrid.isNotEmpty
        ? testHybrid == 'true'
        : display == 'hybrid';
    if (controller.platform is AndroidWebViewController) {
      return WebViewWidget.fromPlatformCreationParams(
        key: ValueKey(hybrid),
        params: AndroidWebViewWidgetCreationParams(
          controller: controller.platform,
          displayWithHybridComposition: hybrid,
        ),
      );
    }
    return WebViewWidget(controller: controller);
  }
}

/// Keeps the player's WebView attached to the screen while no [VideoSurface]
/// is open (on the search, history and settings screens, with the mini
/// player), as a 1x1 pixel view in the corner. Wrap the app's navigator in
/// it (`MaterialApp.builder`).
///
/// Workaround (bug 11 in the README "Known bugs and workarounds"): a WebView
/// that isn't attached to the screen counts as hidden, and Chromium pauses
/// a hidden page's video, so leaving the player screen used to stop
/// playback.
class BackgroundVideoHost extends StatelessWidget {
  final Widget child;

  const BackgroundVideoHost({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return Stack(
      alignment: Alignment.topLeft,
      textDirection: TextDirection.ltr,
      children: [
        Positioned.fill(child: child),
        ValueListenableBuilder<Object?>(
          valueListenable: VideoHosts.owner,
          builder: (context, owner, _) =>
              identical(owner, VideoHosts.background)
              ? const Positioned(
                  left: 0,
                  top: 0,
                  width: 1,
                  height: 1,
                  child: IgnorePointer(child: PlayerWebView()),
                )
              : const SizedBox.shrink(),
        ),
      ],
    );
  }
}

/// The video with the app's own controls on top.
///
/// The YouTube page underneath never receives touches: a full-size gesture
/// layer covers it, so there's nothing on the page (ads, links) to tap.
/// Only one [VideoSurface] can show the player at a time, because the same
/// WebView can't appear in two places: the most recently opened one wins
/// (see [VideoHosts]).
class VideoSurface extends StatefulWidget {
  final bool fullscreen;

  const VideoSurface({super.key, this.fullscreen = false});

  @override
  State<VideoSurface> createState() => _VideoSurfaceState();
}

/// Painted over the video on macOS so clicks reach the app (bug 19).
@visibleForTesting
const clickShieldColor = Color(0x01000000);

class _VideoSurfaceState extends State<VideoSurface> {
  final _c = PlaybackController.instance;

  /// On a Mac the mouse, not touch, drives the controls.
  bool get _desktop => defaultTargetPlatform == TargetPlatform.macOS;
  bool _controlsVisible = true;
  Timer? _hideTimer;

  /// Where the seek bar is being dragged to, in milliseconds; null when it
  /// isn't being dragged.
  double? _dragMs;

  @override
  void initState() {
    super.initState();
    VideoHosts.add(this);
    _scheduleHide();
  }

  @override
  void dispose() {
    VideoHosts.remove(this);
    _hideTimer?.cancel();
    super.dispose();
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && _c.state.playing) setState(() => _controlsVisible = false);
    });
  }

  void _toggleControls() {
    setState(() => _controlsVisible = !_controlsVisible);
    if (_controlsVisible) _scheduleHide();
  }

  void _showControls() {
    if (!_controlsVisible) setState(() => _controlsVisible = true);
    _scheduleHide();
  }

  Future<void> _openFullscreen() async {
    await Navigator.of(context).push(
      PageRouteBuilder<void>(
        pageBuilder: (_, _, _) => const _FullscreenPage(),
        transitionsBuilder: (_, animation, _, child) =>
            FadeTransition(opacity: animation, child: child),
      ),
    );
  }

  Future<void> _showDiagnostics() async {
    final text = await _c.player.diagnostics();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Player diagnostics'),
        content: SingleChildScrollView(
          child: SelectableText(
            text,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              _c.player.showTestSquare();
            },
            child: const Text('Test square'),
          ),
          TextButton.icon(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: text));
              if (context.mounted) Navigator.of(context).pop();
            },
            icon: const Icon(Icons.copy, size: 18),
            label: const Text('Copy'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Object?>(
      valueListenable: VideoHosts.owner,
      builder: (context, owner, _) {
        final showWebView = identical(owner, this);
        return Container(
          color: Colors.black,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (showWebView) const PlayerWebView(),
              // Covers the page so it never gets touches.
              MouseRegion(
                onHover: _desktop ? (_) => _showControls() : null,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _toggleControls,
                  onDoubleTap: () => _c.playOrPause(),
                  onLongPress: _showDiagnostics,
                  // Workaround (bug 19 in the README "Known bugs and
                  // workarounds"): on macOS a click over the WebView goes
                  // to the page, not to Flutter, unless Flutter painted
                  // something at that spot. The gesture layer paints
                  // nothing, so once the controls faded out every click
                  // went to the page and they could never be brought
                  // back. A practically invisible tint makes the whole
                  // video count as Flutter's.
                  child: _desktop
                      ? const ColoredBox(color: clickShieldColor)
                      : null,
                ),
              ),
              if (!const bool.fromEnvironment('PLAYER_TEST'))
                ValueListenableBuilder<YtPlayerState>(
                  valueListenable: _c.player,
                  builder: (context, s, _) => _overlay(context, s),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _overlay(BuildContext context, YtPlayerState s) {
    final showSpinner = s.buffering || s.ad;
    return Stack(
      fit: StackFit.expand,
      children: [
        if (showSpinner)
          const IgnorePointer(
            child: Center(
              child: CircularProgressIndicator(color: Colors.white),
            ),
          ),
        if (s.ad)
          const IgnorePointer(
            child: Align(
              alignment: Alignment(0, 0.4),
              child: Text(
                'Skipping ad…',
                style: TextStyle(color: Colors.white70),
              ),
            ),
          ),
        IgnorePointer(
          ignoring: !_controlsVisible,
          child: AnimatedOpacity(
            opacity: _controlsVisible ? 1 : 0,
            duration: const Duration(milliseconds: 200),
            child: _controls(context, s),
          ),
        ),
      ],
    );
  }

  Widget _controls(BuildContext context, YtPlayerState s) {
    final total = s.duration.inMilliseconds;
    final pos = s.position.inMilliseconds.clamp(0, total > 0 ? total : 0);
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.black38, Colors.transparent, Colors.black54],
        ),
      ),
      child: Stack(
        children: [
          Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _iconButton(Icons.replay_10, () {
                  _c.player.seek(s.position - const Duration(seconds: 10));
                  _scheduleHide();
                }),
                const SizedBox(width: 24),
                _iconButton(
                  s.playing
                      ? Icons.pause_circle_filled
                      : Icons.play_circle_fill,
                  () {
                    _c.playOrPause();
                    _scheduleHide();
                  },
                  size: 56,
                ),
                const SizedBox(width: 24),
                _iconButton(Icons.forward_10, () {
                  _c.player.seek(s.position + const Duration(seconds: 10));
                  _scheduleHide();
                }),
              ],
            ),
          ),
          Positioned(
            left: 12,
            right: 4,
            bottom: 0,
            child: Row(
              children: [
                Text(
                  '${formatDuration(Duration(milliseconds: _dragMs?.round() ?? pos))} / ${formatDuration(s.duration)}',
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                ),
                Expanded(
                  // Workaround (bug 20): seeks only once, where the drag
                  // ends. Seeking on every step of a drag sent the page
                  // dozens of seeks a second, and on macOS the video could
                  // be left loading forever.
                  child: Slider(
                    value: _dragMs ?? pos.toDouble(),
                    max: total > 0 ? total.toDouble() : 1,
                    onChanged: total > 0
                        ? (v) {
                            setState(() => _dragMs = v);
                            _scheduleHide();
                          }
                        : null,
                    onChangeEnd: total > 0
                        ? (v) {
                            setState(() => _dragMs = null);
                            _c.player.seek(Duration(milliseconds: v.round()));
                            _scheduleHide();
                          }
                        : null,
                  ),
                ),
                _iconButton(
                  widget.fullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
                  () => widget.fullscreen
                      ? Navigator.of(context).maybePop()
                      : _openFullscreen(),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _iconButton(
    IconData icon,
    VoidCallback onPressed, {
    double size = 28,
  }) {
    return IconButton(
      iconSize: size,
      color: Colors.white,
      icon: Icon(icon),
      onPressed: onPressed,
    );
  }
}

class _FullscreenPage extends StatefulWidget {
  const _FullscreenPage();

  @override
  State<_FullscreenPage> createState() => _FullscreenPageState();
}

class _FullscreenPageState extends State<_FullscreenPage> {
  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
  }

  @override
  void dispose() {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: Colors.black,
      body: VideoSurface(fullscreen: true),
    );
  }
}
