import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:farmerplus_mobile/domain.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:farmerplus_mobile/auth.dart';
import 'package:farmerplus_mobile/store.dart';
import 'package:farmerplus_mobile/sync.dart';
import 'package:farmerplus_mobile/remote_apps.dart';

class FakeSync extends SyncEngine {
  FakeSync(super.store);
  Completer<dynamic>? reply;
  int calls = 0;
  Future<dynamic> Function(String,String,Object?)? handler;
  @override
  Future<dynamic> request(String method, String route, {Object? body}) async {
    calls++;
    if (handler != null) return handler!(method, route, body);
    if (method == 'POST') return reply!.future;
    return {
      'revision': 1,
      'state': {'profiles': [], 'events': [], 'types': [], 'breeds': []},
    };
  }
}

class FixtureInstaller extends RemoteApps {
  FixtureInstaller(super.store, {required super.engine});
  // Cryptographic verification is exercised by browser_miniapps.test.cjs.
  @override
  Future<Map<String,dynamic>> verifiedManifest(Map<String,dynamic> envelope,String id,int version) async => envelope;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late Directory dir;
  late FarmStore store;
  late RemoteApps manager;
  late FakeSync sync;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('animal-queue-');
    store = await FarmStore.open(
      factory: databaseFactoryFfi,
      filesPath: dir.path,
    );
    sync = FakeSync(store);
    manager = RemoteApps(store, engine: sync);
    await store.setSetting('accessOwner', 'test-owner');
    AccountAccess.unlocked.value = 'test-owner';
  });
  tearDown(() async {
    manager.dispose();
    sync.dispose();
    AccountAccess.unlocked.value = null;
    await store.close();
    await dir.delete(recursive: true);
  });
  Future<void> enqueue() async {
    final saved = await manager.data('my-animals');
    await manager.enqueue('my-animals', {
      'expectedRevision': 0,
      'operationId': 'operation-1',
      'payload': {},
    }, Map<String, dynamic>.from(saved['state']));
    manager.timer?.cancel();
  }

  test(
    'queued commands persist across reopening and reject stale writes',
    () async {
      await enqueue();
      await expectLater(enqueue(), throwsStateError);
      await store.close();
      store = await FarmStore.open(
        factory: databaseFactoryFfi,
        filesPath: dir.path,
      );
      expect(
        (await RemoteApps.of(store).data('my-animals'))['queue'],
        hasLength(1),
      );
    },
  );
  test('locked account cannot send a queued command', () async {
    await enqueue();
    AccountAccess.unlocked.value = null;
    await manager.synchronize('my-animals', explicit: true);
    expect(sync.calls, 0);
    expect((await manager.data('my-animals'))['queue'], hasLength(1));
  });
  test(
    'late response after sign-out does not overwrite local records',
    () async {
      await enqueue();
      sync.reply = Completer<dynamic>();
      final running = manager.synchronize('my-animals', explicit: true);
      while (sync.calls == 0) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      AccountAccess.unlocked.value = null;
      sync.credentialRevision++;
      sync.reply!.complete({
        'revision': 1,
        'state': {
          'profiles': [
            {'name': 'must not apply'},
          ],
        },
      });
      await running;
      final saved = await manager.data('my-animals');
      expect(saved['queue'], hasLength(1));
      expect(saved['state']['profiles'], isEmpty);
    },
  );
  test('removing package preserves records and pending commands', () async {
    await enqueue();
    await store.setSetting('miniapp:package:my-animals', 'download');
    await manager.remove('my-animals');
    expect(await store.setting('miniapp:package:my-animals'), isNull);
    expect((await manager.data('my-animals'))['queue'], hasLength(1));
  });
  test('location deletion is blocked locally while animals remain', () async {
    final farm = await store.save('farm', {'name': 'Farm', 'points': []});
    await manager.write('my-animals', {
      'state': {
        'profiles': [
          {'active': true, 'farmId': farm},
        ],
      },
    });
    await expectLater(
      store.save(
        'farm',
        {'name': 'Farm', 'points': []},
        id: farm,
        deleted: true,
      ),
      throwsStateError,
    );
    expect((await store.get(farm))!['deleted'], 0);
  });
  test('paused download resumes from durable bytes and commits only a verified package', () async {
    final installer=FixtureInstaller(store,engine:sync);
    final raw=jsonEncode({'format':1,'id':'my-animals','version':1,'sdk':1,'html':'<html>${'x'*90000}</html>'});
    final bytes=utf8.encode(raw), offsets=<int>[];
    final manifest={'bytes':bytes.length,'sha256':sha256.convert(bytes).toString(),'version':1};
    sync.handler=(method,route,body)async {
      if(route.endsWith('/manifest')) return manifest;
      if(route.contains('/package?')) {
        final offset=int.parse(Uri.parse(route).queryParameters['offset']!);offsets.add(offset);
        final end=(offset+32768).clamp(0,bytes.length);
        return {'chunk':base64Encode(bytes.sublist(offset,end)),'offset':offset,'total':bytes.length,'sha256':manifest['sha256']};
      }
      return {'saved':true};
    };
    final app=catalogue.firstWhere((a)=>a.id=='my-animals');
    await installer.install(app,cancelled:()=>installer.received>0);
    expect(await store.setting('miniapp:package:my-animals'),isNull);
    expect(installer.received,32768);
    final resumed=FixtureInstaller(store,engine:sync);
    await resumed.install(app,cancelled:()=>false);
    expect(offsets,[0,32768,65536]);
    expect(await store.setting('miniapp:package:my-animals'),raw);
    expect((await store.db.query('installs')).single['state'],'ready');
    installer.dispose();resumed.dispose();
  });
}
