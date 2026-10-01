import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:farmerplus_mobile/main.dart';
import 'package:farmerplus_mobile/store.dart';
import 'package:farmerplus_mobile/sync.dart';
import 'package:farmerplus_mobile/services.dart';
import 'package:farmerplus_mobile/domain.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('native SQLite restart and installed Learning launcher', (
    tester,
  ) async {
    final dir = await Directory.systemTemp.createTemp('farmer-native-');
    var store = await FarmStore.open(filesPath: dir.path);
    final field = await store.save('field', {
      'name': 'TEST FIELD',
      'points': [
        {'lat': 0.0, 'lon': 0.0},
        {'lat': 0.0, 'lon': 0.001},
        {'lat': 0.001, 'lon': 0.0},
      ],
    });
    await store.save('diary', {
      'title': 'TEST OFFLINE ENTRY',
      'fieldId': field,
      'media': [],
    });
    await store.install(catalogue.last);
    await store.close();
    store = await FarmStore.open(filesPath: dir.path);
    expect(
      (await store.records('diary')).single['data']['title'],
      'TEST OFFLINE ENTRY',
    );
    expect(await store.ready('learning'), true);
    final sync = SyncEngine(store);
    await tester.pumpWidget(
      FarmerApp(store: store, sync: sync, reminders: Reminders()),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Learning'), 150);
    expect(find.text('Learning'), findsOneWidget);
    if (Platform.isAndroid) {
      await binding.convertFlutterSurfaceToImage();
      await tester.pumpAndSettle();
      await binding.takeScreenshot('android-home');
    }
    await tester.tap(find.text('Learning'));
    await tester.pumpAndSettle();
    expect(find.text('My courses'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    sync.dispose();
    await store.close();
    await dir.delete(recursive: true);
  });
}
