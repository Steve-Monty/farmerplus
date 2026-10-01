import 'package:flutter/widgets.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

/// Uses Android's native hybrid-composition view for Learning content.
///
/// It costs a little more to compose than the default SurfaceTexture path,
/// but avoids blank or detached WebView surfaces on affected Android devices.
Widget learningWebView(WebViewController controller) {
  PlatformWebViewWidgetCreationParams params =
      PlatformWebViewWidgetCreationParams(controller: controller.platform);
  if (WebViewPlatform.instance is AndroidWebViewPlatform) {
    params =
        AndroidWebViewWidgetCreationParams.fromPlatformWebViewWidgetCreationParams(
          params,
          displayWithHybridComposition: true,
        );
  }
  return WebViewWidget.fromPlatformCreationParams(params: params);
}
