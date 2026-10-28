import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
// The EJS base classes aren't exported by youtube_explode_dart, but they are
// exactly what's needed to plug in a different JavaScript engine.
// ignore: implementation_imports
import 'package:youtube_explode_dart/src/reverse_engineering/challenges/ejs/base_ejs_solver.dart';
// ignore: implementation_imports
import 'package:youtube_explode_dart/src/reverse_engineering/challenges/ejs/ejs.dart';

/// Solves YouTube's JavaScript "challenges" (the `n` and signature
/// parameters in stream URLs) inside an invisible WebView.
///
/// Most YouTube clients only hand out working stream URLs after these are
/// solved with YouTube's own player code. youtube_explode_dart ships the
/// solver scripts (yt-dlp's "EJS") but expects a desktop JavaScript runtime
/// (Deno). A headless WebView gives us a modern JS engine on both Android
/// (Chromium) and macOS (WebKit) instead.
class WebViewEJSSolver extends BaseEJSSolver {
  WebViewEJSSolver._(this._webView, this._controller);

  final HeadlessInAppWebView _webView;
  final InAppWebViewController _controller;

  // Run one script at a time.
  Future<void> _queue = Future.value();

  static Future<WebViewEJSSolver> init() async {
    final ready = Completer<InAppWebViewController>();
    final webView = HeadlessInAppWebView(
      initialData: InAppWebViewInitialData(data: '<html><body></body></html>'),
      onLoadStop: (controller, _) {
        if (!ready.isCompleted) ready.complete(controller);
      },
      onReceivedError: (controller, request, error) {
        if (!ready.isCompleted) ready.completeError(error.description);
      },
    );
    await webView.run();
    final controller =
        await ready.future.timeout(const Duration(seconds: 20));

    // Load yt-dlp's solver library (downloaded and hash-checked by
    // youtube_explode_dart) into the page once.
    final modules = await EJSBuilder.getJSModules();
    await controller.evaluateJavascript(source: '$modules\n;true');
    return WebViewEJSSolver._(webView, controller);
  }

  @override
  Future<String> executeJavaScript(String jsCode) {
    final result = _queue.then((_) async {
      final value = await _controller.evaluateJavascript(source: jsCode);
      if (value is! String) {
        throw Exception('JS solver returned ${value.runtimeType}: $value');
      }
      return value;
    });
    _queue = result.then((_) {}, onError: (_) {});
    return result;
  }

  @override
  void dispose() {
    _webView.dispose();
  }

  /// Creates the solver, or returns null (and logs why) if it can't start.
  static Future<WebViewEJSSolver?> tryInit() async {
    try {
      return await init();
    } catch (e) {
      debugPrint('JS challenge solver unavailable: $e');
      return null;
    }
  }
}
