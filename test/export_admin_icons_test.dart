// One-off asset export: the admin uses the phone's actual painter, not lookalikes.
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import '../lib/ui.dart';

void main() {
  testWidgets('export shared mini-app artwork', (tester) async {
    final folder = Directory('docs/evidence/app-design-20260929/icons')..createSync(recursive: true);
    for (final id in ['diary','planner','calculator','guides','stock','harvest','coop']) {
      final key = GlobalKey();
      await tester.pumpWidget(Directionality(textDirection: TextDirection.ltr,
        child: Center(child: RepaintBoundary(key: key, child: AppArtwork(id: id, size: 80)))));
      await tester.pump();
      await tester.runAsync(() async {
        final image = await (key.currentContext!.findRenderObject() as RenderRepaintBoundary).toImage(pixelRatio: 3);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('${folder.path}/$id.png').writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }
  });
}
