import 'package:flutter/widgets.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

/// Stands in for the real WebView so screens that create the player can be
/// tested. Every call does nothing.
class FakeWebViewPlatform extends WebViewPlatform {
  static void install() => WebViewPlatform.instance = FakeWebViewPlatform();

  /// Every script the app ran on a page, oldest first.
  static final scripts = <String>[];

  @override
  PlatformWebViewController createPlatformWebViewController(
    PlatformWebViewControllerCreationParams params,
  ) => _FakeController(params);

  @override
  PlatformNavigationDelegate createPlatformNavigationDelegate(
    PlatformNavigationDelegateCreationParams params,
  ) => _FakeNavigationDelegate(params);

  @override
  PlatformWebViewWidget createPlatformWebViewWidget(
    PlatformWebViewWidgetCreationParams params,
  ) => _FakeWidget(params);
}

class _FakeWidget extends PlatformWebViewWidget {
  _FakeWidget(super.params) : super.implementation();

  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}

class _FakeController extends PlatformWebViewController {
  _FakeController(super.params) : super.implementation();

  @override
  Future<void> setJavaScriptMode(JavaScriptMode javaScriptMode) async {}
  @override
  Future<void> setBackgroundColor(Color color) async {}
  @override
  Future<void> setUserAgent(String? userAgent) async {}
  @override
  Future<void> addJavaScriptChannel(
    JavaScriptChannelParams javaScriptChannelParams,
  ) async {}
  @override
  Future<void> setPlatformNavigationDelegate(
    PlatformNavigationDelegate handler,
  ) async {}
  @override
  Future<void> loadRequest(LoadRequestParams params) async {}
  @override
  Future<void> loadHtmlString(String html, {String? baseUrl}) async {}
  @override
  Future<void> runJavaScript(String javaScript) async =>
      FakeWebViewPlatform.scripts.add(javaScript);
  @override
  Future<Object> runJavaScriptReturningResult(String javaScript) async => '';
}

class _FakeNavigationDelegate extends PlatformNavigationDelegate {
  _FakeNavigationDelegate(super.params) : super.implementation();

  @override
  Future<void> setOnNavigationRequest(NavigationRequestCallback c) async {}
  @override
  Future<void> setOnPageStarted(PageEventCallback c) async {}
  @override
  Future<void> setOnPageFinished(PageEventCallback c) async {}
  @override
  Future<void> setOnHttpError(HttpResponseErrorCallback c) async {}
  @override
  Future<void> setOnProgress(ProgressCallback c) async {}
  @override
  Future<void> setOnWebResourceError(WebResourceErrorCallback c) async {}
  @override
  Future<void> setOnUrlChange(UrlChangeCallback c) async {}
  @override
  Future<void> setOnHttpAuthRequest(HttpAuthRequestCallback c) async {}
  @override
  Future<void> setOnSSlAuthError(SslAuthErrorCallback c) async {}
}
