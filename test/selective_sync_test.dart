import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:farmerplus_mobile/sync.dart';
import 'package:farmerplus_mobile/store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));
  test(
    'individual sync includes related queued parent and leaves unrelated changes pending',
    () async {
      final dir = await Directory.systemTemp.createTemp('selective-sync-');
      final store = await FarmStore.open(
        factory: databaseFactoryFfi,
        filesPath: dir.path,
      );
      final parent = await store.save('diary', {'title': 'parent'});
      final child = await store.save('diary', {
        'title': 'child',
        'relatedId': parent,
      });
      final other = await store.save('diary', {'title': 'unrelated'});
      await store.setSetting('server', 'http://127.0.0.1:8087');
      await store.setSetting('boundServer', 'http://127.0.0.1:8087');
      await store.setSetting('consent', true);
      final sent = <String>[];
      final engine = SyncEngine(
        store,
        client: MockClient((r) async {
          if (r.url.path == '/sync/push') {
            final data = jsonDecode(r.body);
            sent.add(data['id']);
            return http.Response(
              jsonEncode({
                'record': {'version': 1},
              }),
              200,
            );
          }
          return http.Response('{"records":[]}', 200);
        }),
      )..token = 'test';
      await engine.sync(recordIds: {child});
      expect(engine.status, isNot(contains('Saved on this phone')));
      expect(sent.toSet(), {parent, child});
      expect((await store.db.query('queue')).map((r) => r['id']), [other]);
      expect(engine.status, 'Pending — 1 changes saved on this phone');
      engine.dispose();
      await store.close();
      await dir.delete(recursive: true);
    },
  );
}
