import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:webview_flutter/webview_flutter.dart';
// The EJS base classes aren't exported by youtube_explode_dart, but they are
// exactly what's needed to plug in a different JavaScript engine.
// ignore: implementation_imports
import 'package:youtube_explode_dart/src/reverse_engineering/challenges/ejs/base_ejs_solver.dart';
// ignore: implementation_imports
import 'package:youtube_explode_dart/src/reverse_engineering/challenges/ejs/ejs.dart';

/// Solves YouTube's JavaScript "challenges" (the `n` and signature
/// parameters in stream URLs) inside an off-screen WebView.
///
/// Most YouTube clients only hand out working stream URLs after these are
/// solved with YouTube's own player code. youtube_explode_dart ships the
/// solver scripts (yt-dlp's "EJS") but expects a desktop JavaScript runtime
/// (Deno). A WebView gives us a modern JS engine on both Android (Chromium)
/// and macOS (WebKit) instead. The WebView is never shown.
class WebViewEJSSolver extends BaseEJSSolver {
  WebViewEJSSolver._(this._controller);

  final WebViewController _controller;

  // Run one script at a time.
  Future<void> _queue = Future.value();

  static Future<WebViewEJSSolver> init() async {
    final loaded = Completer<void>();
    final controller = WebViewController();
    await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
    await controller.setNavigationDelegate(NavigationDelegate(
      onPageFinished: (_) {
        if (!loaded.isCompleted) loaded.complete();
      },
    ));
    await controller.loadHtmlString('<html><body></body></html>');
    await loaded.future.timeout(const Duration(seconds: 20));

    // Load yt-dlp's solver library (downloaded and hash-checked by
    // youtube_explode_dart) into the page once.
    final modules = await EJSBuilder.getJSModules();
    await controller.runJavaScript(modules);
    return WebViewEJSSolver._(controller);
  }

  @override
  Future<String> executeJavaScript(String jsCode) {
    final result = _queue.then((_) async {
      final value = await _controller.runJavaScriptReturningResult(jsCode);
      if (value is! String) {
        throw Exception('JS solver returned ${value.runtimeType}');
      }
      // Android hands back the string JSON-encoded (with quotes); WebKit
      // returns it as is.
      if (value.startsWith('"')) return jsonDecode(value) as String;
      return value;
    });
    _queue = result.then((_) {}, onError: (_) {});
    return result;
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
