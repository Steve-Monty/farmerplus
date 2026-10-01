import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:farmerplus_mobile/store.dart';
import 'package:farmerplus_mobile/sync.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late Directory dir;
  late FarmStore store;
  setUp(() async {
    PackageInfo.setMockInitialValues(appName: 'FarmerPlus', packageName: 'farmerplus',
      version: '1.2.3', buildNumber: '45', buildSignature: '');
    FlutterSecureStorage.setMockInitialValues({});
    dir = await Directory.systemTemp.createTemp('sync-resilience-');
    store = await FarmStore.open(
      factory: databaseFactoryFfi,
      filesPath: dir.path,
    );
    await store.setSetting('server', 'http://127.0.0.1:8087');
    await store.setSetting('boundServer', 'http://127.0.0.1:8087');
    await store.setSetting('consent', true);
  });
  tearDown(() async {
    await store.close();
    await dir.delete(recursive: true);
  });

  test('automatic sync is silent when no changes are pending', () async {
    var requests = 0;
    await store.setSetting('lastSync', '2026-09-01T10:00:00Z');
    final engine = SyncEngine(
      store,
      client: MockClient((r) async {
        requests++;
        return http.Response('{"records":[]}', 200);
      }),
    )..token = 'test';
    await engine.automatic();
    await engine.automatic();
    expect(requests, 0);
    expect(engine.busy, false);
    expect(await store.setting('lastSync'), '2026-09-01T10:00:00Z');
    await engine.sync();
    expect(requests, greaterThan(0));
    engine.dispose();
  });

  test(
    'one rejected record does not block others or claim a complete sync',
    () async {
      final bad = await store.save('diary', {'title': 'Needs correction'});
      final good = await store.save('diary', {'title': 'Valid record'});
      await store.setSetting('lastSync', '2026-09-01T10:00:00Z');
      var reject = true;
      final accepted = <String>[];
      final reports = <Map<String, dynamic>>[];
      final engine = SyncEngine(
        store,
        client: MockClient((request) async {
          if (request.url.path == '/sync/complete') {
            reports.add(Map<String, dynamic>.from(jsonDecode(request.body)));
            return http.Response('{"recorded":true}', 200);
          }
          if (request.url.path == '/sync/push') {
            final body = jsonDecode(request.body);
            if (body['id'] == bad && reject) {
              return http.Response(
                '{"detail":"Correct the activity date"}',
                422,
              );
            }
            accepted.add(body['id']);
            return http.Response('{"record":{"version":1}}', 200);
          }
          return http.Response('{"records":[]}', 200);
        }),
      )..token = 'test';
      await engine.sync();
      expect(accepted, [good]);
      expect(reports.single['pendingChanges'], 1);
      expect(reports.single['version'], '1.2.3+45');
      expect(reports.single['settings'], contains('weatherEnabled'));
      expect((await store.db.query('queue')).single['id'], bad);
      expect(engine.itemIssues[bad], 'Correct the activity date');
      expect(
        (await store.setting('syncIssues'))[bad]['message'],
        'Correct the activity date',
      );
      expect(await store.setting('lastSync'), '2026-09-01T10:00:00Z');
      reject = false;
      await engine.sync(recordIds: {bad});
      expect(accepted, [good, bad]);
      expect(engine.itemIssues, isEmpty);
      expect(await store.db.query('queue'), isEmpty);
      expect(engine.status, 'Synced');
      expect(await store.setting('lastSync'), isNot('2026-09-01T10:00:00Z'));
      engine.dispose();
    },
  );

  test(
    'invalid local boundary leaves independent diary upload usable',
    () async {
      final farm = await store.save('farm', {'name': 'Legacy boundary'});
      final record = await store.get(farm);
      final invalid = {
        ...record!['data'] as Map,
        'points': [
          {'lat': 0, 'lon': 0},
          {'lat': 1, 'lon': 1},
        ],
      };
      await store.db.update(
        'queue',
        {'data': jsonEncode(invalid)},
        where: 'id=?',
        whereArgs: [farm],
      );
      final diary = await store.save('diary', {'title': 'Independent diary'});
      final sent = <String>[];
      final engine = SyncEngine(
        store,
        client: MockClient((r) async {
          if (r.url.path == '/sync/push') {
            sent.add(jsonDecode(r.body)['id']);
            return http.Response('{"record":{"version":1}}', 200);
          }
          return http.Response('{"records":[]}', 200);
        }),
      )..token = 'test';
      await engine.sync();
      expect(sent, [diary]);
      expect(engine.itemIssues[farm], isNotEmpty);
      expect((await store.db.query('queue')).single['id'], farm);
      engine.dispose();
    },
  );
}
