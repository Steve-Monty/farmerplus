import 'dart:html' as html;

void browserAssign(String url) => html.window.location.assign(url);
void browserReplacePath(String path) =>
    html.window.history.replaceState(null, '', path);
String? browserActiveWorkspace() =>
    html.window.localStorage['farmerplus.activeWorkspace'];
void setBrowserActiveWorkspace(String id) =>
    html.window.localStorage['farmerplus.activeWorkspace'] = id;
void browserReloadAtRoot() {
  html.window.history.replaceState(null, '', '/');
  html.window.location.reload();
}

Map<String, dynamic> browserCapabilities() => {
  'platform': html.window.navigator.platform ?? '',
  'language': html.window.navigator.language,
  'online': html.window.navigator.onLine,
  'screenWidth': html.window.screen?.width ?? 0,
  'screenHeight': html.window.screen?.height ?? 0,
  'pixelRatio': html.window.devicePixelRatio,
  'timezoneOffsetMinutes': DateTime.now().timeZoneOffset.inMinutes,
  'standalone': html.window.matchMedia('(display-mode: standalone)').matches,
  'userAgent': html.window.navigator.userAgent,
  'cookiesEnabled': html.window.navigator.cookieEnabled,
  if (html.window.navigator.hardwareConcurrency != null)
    'logicalProcessors': html.window.navigator.hardwareConcurrency,
  if (html.window.navigator.maxTouchPoints != null)
    'maxTouchPoints': html.window.navigator.maxTouchPoints,
  if (html.window.navigator.deviceMemory != null)
    'approximateMemoryGb': html.window.navigator.deviceMemory,
};
