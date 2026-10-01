import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:farmerplus_mobile/store.dart';
import 'package:farmerplus_mobile/sync.dart';

// Explicit opt-in: this test creates synthetic records on a local test API only.
void main() {
  const server = String.fromEnvironment('SYNC_TEST_URL');
  const phase = String.fromEnvironment('SYNC_TEST_PHASE', defaultValue: 'seed');
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  test(
    'real local API: offline SQLite, web edit, pull and conflict',
    () async {
      if (server.isEmpty) return;
      expect(Uri.parse(server).host, '127.0.0.1');
      HttpOverrides.global = null;
      final stateFile = File('../evidence/private/e2e-state.json');
      if (phase == 'media') {
        final state = jsonDecode(await stateFile.readAsString());
        final sender = await FarmStore.open(
          factory: databaseFactoryFfi,
          filesPath: state['root'],
        );
        final upload = SyncEngine(sender);
        final identity = await upload.request(
          'POST',
          '/auth/login',
          body: {'username': state['username'], 'password': state['password']},
        );
        upload.token = identity['token'];
        final bytes = base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aJ9sAAAAASUVORK5CYII=',
        );
        final fixture = File('${sender.filesPath}/test-only-pixel.png');
        await fixture.writeAsBytes(bytes);
        final hash = await sender.keepMedia(fixture.path);
        final id = await sender.save('diary', {
          'title': 'Synthetic attachment transfer',
          'media': [
            {'hash': hash, 'type': 'image/png'},
          ],
        });
        await upload.sync();
        expect(upload.failures, 0, reason: upload.status);
        expect(await sender.db.query('queue'), isEmpty);
        final receiverRoot = await Directory(
          '../evidence/private/receiver-${DateTime.now().millisecondsSinceEpoch}',
        ).create(recursive: true);
        final receiver = await FarmStore.open(
          factory: databaseFactoryFfi,
          filesPath: receiverRoot.absolute.path,
        );
        for (final key in ['server', 'boundServer', 'boundOwner', 'consent']) {
          await receiver.setSetting(key, await sender.setting(key));
        }
        final download = SyncEngine(receiver)..token = identity['token'];
        await download.sync();
        expect(download.failures, 0, reason: download.status);
        expect((await receiver.get(id))!['data']['media'][0]['hash'], hash);
        expect(
          await File('${receiver.filesPath}/media/$hash').readAsBytes(),
          bytes,
        );
        upload.dispose();
        download.dispose();
        await sender.close();
        await receiver.close();
        return;
      }
      late FarmStore store;
      late SyncEngine sync;
      if (phase == 'seed') {
        final directory = await Directory(
          '../evidence/private/mobile-e2e-${DateTime.now().millisecondsSinceEpoch}',
        ).create(recursive: true);
        store = await FarmStore.open(
          factory: databaseFactoryFfi,
          filesPath: directory.absolute.path,
        );
        final farm = await store.save('farm', {
          'name': 'Test farm · synthetic QA',
          'points': [
            {'lat': -25.0, 'lon': 28.0},
            {'lat': -25.0, 'lon': 28.001},
            {'lat': -25.001, 'lon': 28.001},
          ],
        });
        final field = await store.save('field', {
          'name': 'Test north field',
          'farmId': farm,
          'points': [
            {'lat': -25.0001, 'lon': 28.0002},
            {'lat': -25.0001, 'lon': 28.0008},
            {'lat': -25.0008, 'lon': 28.0008},
          ],
        });
        final diary = await store.save('diary', {
          'title': 'Offline irrigation check',
          'notes': 'Synthetic test record created offline on SQLite.',
          'fieldId': field,
          'fieldName': 'Test north field',
          'date': DateTime.now().toUtc().toIso8601String(),
        });
        await store.save('task', {
          'title': 'Test plan: inspect irrigation',
          'date': DateTime.now().toUtc().toIso8601String(),
          'completed': false,
        });
        expect(await store.db.query('queue'), hasLength(4));
        final root = store.filesPath;
        await store.db.close();
        store = await FarmStore.open(
          factory: databaseFactoryFfi,
          filesPath: root,
        );
        expect(
          (await store.get(diary))!['data']['title'],
          'Offline irrigation check',
        );
        await store.setSetting('server', server);
        sync = SyncEngine(store);
        final credentials = {
          'username': 'qa_${DateTime.now().millisecondsSinceEpoch}',
          'password': 'Synthetic-Local-Test-Only!',
        };
        await sync.request('POST', '/auth/register', body: credentials);
        final identity = await sync.request(
          'POST',
          '/auth/login',
          body: credentials,
        );
        sync.token = identity['token'];
        await store.setSetting('boundOwner', identity['owner']);
        await store.setSetting('boundServer', server);
        await store.setSetting('consent', true);
        await sync.sync();
        expect(sync.failures, 0, reason: sync.status);
        expect(await store.db.query('queue'), isEmpty);
        expect((await store.get(diary))!['version'], 1);
        await stateFile.parent.create(recursive: true);
        await stateFile.writeAsString(
          jsonEncode({
            ...credentials,
            'owner': identity['owner'],
            'root': root,
            'diary': diary,
            'server': server,
          }),
        );
      } else {
        final state = jsonDecode(await stateFile.readAsString());
        store = await FarmStore.open(
          factory: databaseFactoryFfi,
          filesPath: state['root'],
        );
        sync = SyncEngine(store);
        final identity = await sync.request(
          'POST',
          '/auth/login',
          body: {'username': state['username'], 'password': state['password']},
        );
        sync.token = identity['token'];
        final id = state['diary'] as String;
        expect(
          (await store.get(id))!['data']['title'],
          'Offline irrigation check',
        );
        await sync.sync();
        expect(sync.failures, 0, reason: sync.status);
        expect(
          (await store.get(id))!['data']['title'],
          'Irrigation checked on the web',
        );
        final prior = (await store.get(id))!;
        await store.save('diary', {
          ...prior['data'],
          'title': 'New offline edit',
        }, id: id);
        await sync.request(
          'POST',
          '/sync/push',
          body: {
            'id': id,
            'op_id': uuid.v4(),
            'kind': 'diary',
            'base_version': prior['version'],
            'data': {...prior['data'], 'title': 'Concurrent server edit'},
            'deleted': false,
          },
        );
        await sync.sync();
        expect(await store.db.query('conflicts'), hasLength(1));
        expect((await store.get(id))!['data']['title'], 'New offline edit');
        await store.resolve(id, keepLocal: true);
        await sync.sync();
        expect(sync.failures, 0, reason: sync.status);
        expect(await store.db.query('conflicts'), isEmpty);
        expect(await store.db.query('queue'), isEmpty);
        final remote = await sync.request('GET', '/sync/pull');
        expect(
          (remote['records'] as List).firstWhere(
            (r) => r['id'] == id,
          )['data']['title'],
          'New offline edit',
        );
      }
      sync.dispose();
      await store.db.close();
    },
    skip: server.isEmpty
        ? 'Requires an explicitly started local test API'
        : false,
  );
}
