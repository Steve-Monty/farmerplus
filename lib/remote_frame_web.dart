import 'dart:js_interop';
import 'dart:ui_web' as ui;
import 'package:web/web.dart' as web;
import 'package:flutter/widgets.dart';

@JS('FarmerMiniRuntime.verify')
external JSPromise<JSString> _verify(
  JSString signed,
  JSString signature,
  JSString key,
);
@JS('FarmerMiniRuntime.mount')
external JSPromise<_FrameHandle> _mount(
  web.HTMLIFrameElement frame,
  JSString source,
  JSFunction callback,
);
extension type _FrameHandle._(JSObject _) implements JSObject {
  external void update();
  external void close();
}

Future<String> verifyMiniSignature(
  String signed,
  String signature,
  String key,
) async {
  return (await _verify(signed.toJS, signature.toJS, key.toJS).toDart).toDart;
}

class RemoteFrame extends StatefulWidget {
  final String html;
  final Future<String> Function(String) onRequest;
  final Listenable changes;
  const RemoteFrame({
    super.key,
    required this.html,
    required this.onRequest,
    required this.changes,
  });
  @override
  State<RemoteFrame> createState() => _RemoteFrameState();
}

int _sequence = 0;

class _RemoteFrameState extends State<RemoteFrame> {
  late final String view = 'farmerplus-miniapp-${_sequence++}';
  _FrameHandle? handle;
  late final web.HTMLIFrameElement frame;
  @override
  void initState() {
    super.initState();
    widget.changes.addListener(update);
    frame = web.HTMLIFrameElement()
      ..title = 'My Animals'
      ..style.width = '100%'
      ..style.height = '100%'
      ..style.border = '0';
    ui.platformViewRegistry.registerViewFactory(view, (int _) => frame);
    final callback =
        ((JSString request) => widget
                .onRequest(request.toDart)
                .then((value) => value.toJS)
                .toJS)
            .toJS;
    _mount(frame, widget.html.toJS, callback).toDart.then((value) {
      if (!mounted) {
        value.close();
        return;
      }
      handle = value;
    });
  }

  void update() {
    handle?.update();
  }

  @override
  void dispose() {
    widget.changes.removeListener(update);
    handle?.close();
    frame.remove();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => HtmlElementView(viewType: view);
}
