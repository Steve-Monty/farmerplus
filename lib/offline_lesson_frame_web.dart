import 'dart:convert';
import 'dart:js_interop';
import 'dart:ui_web' as ui_web;

import 'package:flutter/widgets.dart';
import 'package:web/web.dart' as web;

int _frameSequence = 0;

Widget offlineLessonFrame(List<int> bytes) {
  final viewType = 'farmerplus-offline-lesson-${_frameSequence++}';
  final lesson = utf8.decode(bytes, allowMalformed: false);
  ui_web.platformViewRegistry.registerViewFactory(viewType, (int _) {
    final frame = web.HTMLIFrameElement()
      ..srcdoc = lesson.toJS
      ..setAttribute('sandbox', '')
      ..setAttribute('title', 'Downloaded lesson')
      ..style.width = '100%'
      ..style.height = '100%'
      ..style.border = '0';
    return frame;
  });
  return HtmlElementView(viewType: viewType);
}
