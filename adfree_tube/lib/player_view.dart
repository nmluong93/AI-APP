import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

import 'playback.dart';
import 'widgets.dart';
import 'yt_web_player.dart';

/// The video with the app's own controls on top.
///
/// The YouTube page underneath never receives touches: a full-size gesture
/// layer covers it, so there's nothing on the page (ads, links) to tap.
/// Only one [VideoSurface] can show the player at a time, because the same
/// WebView can't appear in two places.
class VideoSurface extends StatefulWidget {
  final bool fullscreen;

  const VideoSurface({super.key, this.fullscreen = false});

  /// True while the fullscreen page is showing the video, so the normal
  /// player page leaves it alone.
  static final fullscreenActive = ValueNotifier(false);

  @override
  State<VideoSurface> createState() => _VideoSurfaceState();
}

class _VideoSurfaceState extends State<VideoSurface> {
  final _c = PlaybackController.instance;
  bool _controlsVisible = true;
  Timer? _hideTimer;

  @override
  void initState() {
    super.initState();
    _scheduleHide();
  }

  @override
  void dispose() {
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

  Future<void> _openFullscreen() async {
    VideoSurface.fullscreenActive.value = true;
    await Navigator.of(context).push(PageRouteBuilder<void>(
      pageBuilder: (_, _, _) => const _FullscreenPage(),
      transitionsBuilder: (_, animation, _, child) =>
          FadeTransition(opacity: animation, child: child),
    ));
    VideoSurface.fullscreenActive.value = false;
  }

  Widget _webView() {
    final controller = _c.player.controller;
    // Android's default way of embedding the WebView (a texture) can show
    // web video as a black box; hybrid composition draws it reliably.
    if (controller.platform is AndroidWebViewController) {
      return WebViewWidget.fromPlatformCreationParams(
        params: AndroidWebViewWidgetCreationParams(
          controller: controller.platform,
          displayWithHybridComposition: true,
        ),
      );
    }
    return WebViewWidget(controller: controller);
  }

  Future<void> _showDiagnostics() async {
    final text = await _c.player.diagnostics();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Player diagnostics'),
        content: SingleChildScrollView(
          child: SelectableText(text,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 11)),
        ),
        actions: [
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
    return ValueListenableBuilder<bool>(
      valueListenable: VideoSurface.fullscreenActive,
      builder: (context, fullscreenActive, _) {
        final showWebView = widget.fullscreen || !fullscreenActive;
        return Container(
          color: Colors.black,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (showWebView) _webView(),
              // Covers the page so it never gets touches.
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _toggleControls,
                onDoubleTap: () => _c.player.playOrPause(),
                onLongPress: _showDiagnostics,
              ),
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
            child: Center(child: CircularProgressIndicator(color: Colors.white)),
          ),
        if (s.ad)
          const IgnorePointer(
            child: Align(
              alignment: Alignment(0, 0.4),
              child: Text('Skipping ad…',
                  style: TextStyle(color: Colors.white70)),
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
                  s.playing ? Icons.pause_circle_filled : Icons.play_circle_fill,
                  () {
                    _c.player.playOrPause();
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
                  '${formatDuration(Duration(milliseconds: pos))} / ${formatDuration(s.duration)}',
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                ),
                Expanded(
                  child: Slider(
                    value: pos.toDouble(),
                    max: total > 0 ? total.toDouble() : 1,
                    onChanged: total > 0
                        ? (v) {
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

  Widget _iconButton(IconData icon, VoidCallback onPressed, {double size = 28}) {
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
