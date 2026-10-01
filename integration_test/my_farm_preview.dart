// Isolated visual QA entry point. The integration_test path gives this build
// the .qa application ID. It uses disposable local data and starts no sync.
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:farmerplus_mobile/store.dart';
import 'package:farmerplus_mobile/area_activity.dart';
import 'package:farmerplus_mobile/ui.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final dir = await Directory.systemTemp.createTemp('my-farm-visual-');
  final store = await FarmStore.open(filesPath: dir.path);
  final farm = await store.save('farm', {
    'name': 'QA Farm · sample',
    'productionCategory': 'Mixed farming',
    'points': [
      {'lat': -26.0560, 'lon': 28.0697},
      {'lat': -26.0570, 'lon': 28.0692},
      {'lat': -26.0574, 'lon': 28.0698},
      {'lat': -26.0570, 'lon': 28.0702},
    ],
  });
  final area = await store.save('field', {
    'name': 'Craal',
    'farmId': farm,
    'areaType': 'Pasture / paddock',
  });
  await store.save('pin', {
    'name': 'North gate',
    'farmId': farm,
    'lat': -26.0561,
    'lon': 28.0697,
    'type': 'Gate',
    'notes': 'Synthetic visual test',
  });
  await store.save('season', {
    'name': 'Spring forage',
    'crop': 'Forage maize',
    'farmId': farm,
    'fieldId': area,
    'start': '2026-09-17',
    'status': 'Planned',
  });
  runApp(
    MaterialApp(
      theme: farmTheme(),
      home: AreaActivityPage(store: store, record: (await store.get(area))!),
    ),
  );
}
