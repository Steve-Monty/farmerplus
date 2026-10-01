import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:farmerplus_mobile/store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  test(
    'preferences survive restart, pull and conflict resolution; secrets stay local',
    () async {
      final dir = await Directory.systemTemp.createTemp('preference_sync_');
      var store = await FarmStore.open(
        factory: databaseFactoryFfi,
        filesPath: dir.path,
      );
      try {
        await store.setSetting('areaUnit', 'ha');
        await store.setSetting('consent', true);
        await store.setSetting('offlineVerifier', 'local-only');
        final ops = await store.db.query('queue');
        expect(ops.length, 1);
        await store.acknowledge(ops.single, 1);
        await store.close();
        store = await FarmStore.open(
          factory: databaseFactoryFfi,
          filesPath: dir.path,
        );
        expect(await store.setting('areaUnit'), 'ha');
        final incoming = {
          'id': store.preferenceId('areaUnit'),
          'kind': 'preference',
          'data': {'key': 'areaUnit', 'value': 'acres'},
          'version': 2,
          'deleted': false,
          'updated': DateTime.now().toUtc().toIso8601String(),
        };
        await store.incoming(incoming);
        expect(await store.setting('areaUnit'), 'acres');
        await store.setSetting('areaUnit', 'ha');
        await store.incoming({...incoming, 'version': 3});
        expect(await store.setting('areaUnit'), 'ha');
        expect(await store.db.query('conflicts'), hasLength(1));
        await store.resolve(store.preferenceId('areaUnit'), keepLocal: false);
        expect(await store.setting('areaUnit'), 'acres');
        expect(await store.setting('offlineVerifier'), 'local-only');
        expect(await store.db.query('queue'), isEmpty);
      } finally {
        await store.close();
        await dir.delete(recursive: true);
      }
    },
  );
}
