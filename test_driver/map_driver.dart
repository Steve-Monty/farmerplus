import 'dart:io';
import 'package:integration_test/integration_test_driver_extended.dart';

Future<void> main() async {
  await integrationDriver(
    onScreenshot: (name, bytes, [args]) async {
      final folder = await Directory(
        '../artifacts/farm-areas-20260913',
      ).create(recursive: true);
      await File('${folder.path}/$name.png').writeAsBytes(bytes);
      return true;
    },
  );
}
