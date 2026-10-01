import 'dart:js_interop';

import 'package:web/web.dart' as web;

@JS()
extension type _NavigatorWakeLock._(JSObject _) implements JSObject {
  external _WakeLockManager? get wakeLock;
}

@JS()
extension type _WakeLockManager._(JSObject _) implements JSObject {
  external JSPromise<_WakeLockSentinel> request(String type);
}

@JS()
extension type _WakeLockSentinel._(JSObject _) implements JSObject {
  external JSPromise<JSAny?> release();
}

_WakeLockSentinel? _sentinel;

Future<bool> requestBoundaryWakeLock() async {
  try {
    final navigator = _NavigatorWakeLock._(web.window.navigator);
    final wakeLock = navigator.wakeLock;
    if (wakeLock == null) return false;
    _sentinel = await wakeLock.request('screen').toDart;
    return true;
  } catch (_) {
    return false;
  }
}

Future<void> releaseBoundaryWakeLock() async {
  final sentinel = _sentinel;
  _sentinel = null;
  if (sentinel == null) return;
  try {
    await sentinel.release().toDart;
  } catch (_) {}
}
