import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:farmerplus_mobile/community.dart';
import 'package:farmerplus_mobile/auth.dart';
import 'package:farmerplus_mobile/store.dart';
import 'package:farmerplus_mobile/sync.dart';
import 'package:farmerplus_mobile/domain.dart';
import 'package:farmerplus_mobile/push.dart';
import 'package:farmerplus_mobile/services.dart';

class CommunitySync extends SyncEngine {
  CommunitySync(super.store);
  bool offline = false;
  final calls = <String>[];
  final choices = <String, bool>{for (final c in sharingNames.keys) c: false};
  @override
  Future<dynamic> request(String method, String route, {Object? body}) async {
    calls.add('$method $route');
    if (offline) throw const SocketException('offline');
    if (route == '/sharing/preferences') return {'choices': choices};
    if (route == '/coops/memberships') return {'items': []};
    if (route == '/coops/installation') {
      choices['cooperatives'] = (body as Map)['enabled'];
    }
    if (route == '/notifications') return {'items': [], 'fetchedAt': 1};
    if (route.startsWith('/sharing/preferences/')) {
      choices[route.split('/').last] = (body as Map)['enabled'];
    }
    return {'saved': true, 'owner': 'one'};
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late Directory dir;
  late FarmStore store;
  late CommunitySync sync;
  late CommunityService service;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('community-qa-');
    store = await FarmStore.open(
      factory: databaseFactoryFfi,
      filesPath: dir.path,
    );
    sync = CommunitySync(store);
    service = CommunityService(store, sync);
    await store.setSetting('server', 'https://example.test');
    await store.setSetting('boundServer', 'https://example.test');
    await store.setSetting('boundOwner', 'one');
    AccountAccess.unlocked.value = 'farmerplus:one';
  });
  tearDown(() async {
    while (service.busy) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    service.dispose();
    AccountAccess.unlocked.value = null;
    await store.close();
    await dir.delete(recursive: true);
  });
  test(
    'manual sharing waits for explicit sync and background uses bound credentials',
    () async {
      await store.setSetting('syncMode', 'manual');
      await service.choose('insurance', true);
      await service.refresh();
      expect(sync.calls, isEmpty);
      expect((await service.snapshot())['pending'], hasLength(1));
      await service.refresh(explicit: true);
      expect((await service.snapshot())['pending'], isEmpty);
      expect(sync.choices['insurance'], isTrue);
      service.busy = true;
      await service.choose('inputs', true);
      service.busy = false;
      await store.setSetting('syncMode', 'automatic');
      AccountAccess.unlocked.value = null;
      sync.token = 'synthetic-background-session';
      final worker = CommunityService(store, sync, background: true);
      try {
        await worker.refresh();
        expect(sync.choices['inputs'], isTrue);
        expect(await worker.pending((await worker.scope())!), isEmpty);
      } finally {
        worker.dispose();
      }
    },
  );
  test(
    'concurrent choices persist, survive offline, and never cross owners',
    () async {
      service.busy = true;
      await Future.wait([
        service.choose('finance', true),
        service.choose('government', true),
      ]);
      service.busy = false;
      expect((await service.snapshot())['pending'], hasLength(2));
      sync.offline = true;
      await service.refresh();
      expect((await service.snapshot())['installationPending'], isTrue);
      await store.setSetting('boundOwner', 'two');
      expect((await service.snapshot())['pending'], isEmpty);
      expect((await service.snapshot())['choices']['finance'], isFalse);
      await store.setSetting('boundOwner', 'one');
      sync.offline = false;
      await service.refresh();
      expect((await service.snapshot())['pending'], isEmpty);
      expect((await service.snapshot())['status'], 'Synced');
      expect((await service.snapshot())['choices']['finance'], isTrue);
    },
  );
  test(
    'Coop removal preserves membership cache and explicit removal flag',
    () async {
      final app = catalogue.firstWhere((a) => a.id == 'coop');
      await store.install(app);
      expect(await store.ready('coop'), isTrue);
      await service.refresh();
      expect((await service.snapshot())['choices']['cooperatives'], isTrue);
      expect(sync.choices['cooperatives'], isTrue);
      final generation = await store.setting('coopGeneration');
      final key = await service.scope();
      await store.setSetting('communityCache:$key', {
        'members': [
          {'name': 'Demo'},
        ],
      });
      await store.removeApp('coop');
      expect(await store.ready('coop'), isFalse);
      expect(await store.setting('removedApp:coop'), isTrue);
      expect((await service.snapshot())['members'], hasLength(1));
      expect((await service.snapshot())['choices']['cooperatives'], isFalse);
      sync.offline = true;
      await service.refresh();
      expect((await service.snapshot())['installationPending'], isTrue);
      sync.offline = false;
      await service.refresh();
      expect(sync.choices['cooperatives'], isFalse);
      await store.install(app);
      expect(await store.ready('coop'), isTrue);
      expect(await store.setting('coopGeneration'), isNot(generation));
      await service.refresh();
      expect(sync.choices['cooperatives'], isTrue);
      expect(() => service.choose('cooperatives', false), throwsStateError);
    },
  );
  test(
    'notification disable retries server revocation after offline failure',
    () async {
      final push = PushService(
        store,
        sync,
        Reminders(),
        GlobalKey<NavigatorState>(),
      );
      final key = await push.scope();
      await store.setSetting('pushOptIn', true);
      await store.setSetting('pushDevice:$key', 'device-one');
      sync.offline = true;
      await push.disable();
      expect(await store.setting('pushOptIn'), isFalse);
      expect(await store.setting('pushRevoke:$key'), 'device-one');
      sync.offline = false;
      await push.refresh();
      expect(await store.setting('pushRevoke:$key'), isNull);
      expect(
        sync.calls,
        contains('DELETE /notifications/registration/device-one'),
      );
      push.dispose();
    },
  );
}
