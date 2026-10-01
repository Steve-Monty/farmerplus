import 'dart:io';

import 'package:farmerplus_mobile/account_workspaces.dart';
import 'package:farmerplus_mobile/pwa_auth.dart';
import 'package:farmerplus_mobile/store.dart';
import 'package:farmerplus_mobile/auth.dart' show AccountAccess;
import 'package:farmerplus_mobile/sync.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class DeviceProofFixture extends SyncEngine {
  final Map<String, dynamic> proof;
  DeviceProofFixture(super.store, this.proof);
  @override
  Future<dynamic> request(String method, String route, {Object? body}) async {
    expect(method, 'GET');
    expect(route, '/auth/me');
    expect(body, isNull); // The device passphrase must never enter a request.
    return proof;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  late Directory directory;
  late FarmStore store;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('pwa-offline-auth-');
    store = await FarmStore.open(
      factory: databaseFactoryFfi,
      filesPath: directory.path,
    );
    await store.setSetting('boundServer', 'https://app.example');
    await store.setSetting('boundOwner', 'owner-a');
    await store.setSetting('credentialEpoch', 4);
  });

  tearDown(() async {
    await store.close();
    await directory.delete(recursive: true);
  });

  test('offline verifier accepts only the bound account password', () async {
    await enrollOfflineEmail(store, ' Farmer@Example.org ', 'safe password 42');

    expect(
      await verifyOfflineEmail(store, 'farmer@example.org', 'safe password 42'),
      isTrue,
    );
    expect(
      await verifyOfflineEmail(store, 'farmer@example.org', 'wrong password'),
      isFalse,
    );
    expect(
      await verifyOfflineEmail(store, 'other@example.org', 'safe password 42'),
      isFalse,
    );

    final saved = Map<String, dynamic>.from(
      await store.setting('offlineEmailVerifier'),
    );
    expect(saved['email'], 'farmer@example.org');
    expect(saved['server'], 'https://app.example');
    expect(saved['owner'], 'owner-a');
    expect(saved['credentialEpoch'], 4);
    expect(saved['rounds'], 600000);
    expect(saved.values, isNot(contains('safe password 42')));
  });

  test('offline verifier rejects another epoch and caps bad rounds', () async {
    await enrollOfflineEmail(store, 'farmer@example.org', 'safe password 42');
    await store.setSetting('credentialEpoch', 5);

    expect(
      await verifyOfflineEmail(store, 'farmer@example.org', 'safe password 42'),
      isFalse,
    );
    expect(await store.setting('offlineEmailVerifier'), isNull);

    await store.setSetting('credentialEpoch', 4);
    await enrollOfflineEmail(store, 'farmer@example.org', 'safe password 42');
    final saved = Map<String, dynamic>.from(
      await store.setting('offlineEmailVerifier'),
    );
    await store.setSetting('offlineEmailVerifier', {
      ...saved,
      'rounds': 999999999,
    });
    expect(
      await verifyOfflineEmail(store, 'farmer@example.org', 'safe password 42'),
      isFalse,
    );
    expect(await store.setting('offlineEmailVerifier'), isNull);
  });

  test('workspace identity is stable and isolated by server and owner', () {
    final first = AccountWorkspaces.id('https://app.example', 'owner-a');

    expect(first, hasLength(64));
    expect(AccountWorkspaces.id('https://app.example', 'owner-a'), first);
    expect(
      AccountWorkspaces.id('https://app.example', 'owner-b'),
      isNot(first),
    );
    expect(
      AccountWorkspaces.id('https://other.example', 'owner-a'),
      isNot(first),
    );
  });

  test(
    'device passphrase cannot be used as an account password and survives restart',
    () async {
      await enrollOfflineEmail(
        store,
        'farmer@example.org',
        'Separate local phrase 42',
        deviceUnlock: true,
      );
      expect(
        await verifyOfflineEmail(
          store,
          'farmer@example.org',
          'Separate local phrase 42',
        ),
        isFalse,
      );
      await store.close();
      store = await FarmStore.open(
        factory: databaseFactoryFfi,
        filesPath: directory.path,
      );
      expect(
        await verifyOfflineEmail(
          store,
          'farmer@example.org',
          'Separate local phrase 42',
          deviceUnlock: true,
        ),
        isTrue,
      );
      await store.setSetting('boundOwner', 'owner-b');
      expect(
        await verifyOfflineEmail(
          store,
          'farmer@example.org',
          'Separate local phrase 42',
          deviceUnlock: true,
        ),
        isFalse,
      );
      expect(await store.setting('offlineEmailVerifier'), isNull);
    },
  );

  test(
    'device enrollment requires fresh verified proof for the bound owner',
    () async {
      const student = '0123456789abcdef0123456789abcdef';
      await store.setSetting('server', 'https://app.example');
      await store.setSetting('studentId', student);
      AccountAccess.unlocked.value = 'farmerplus:$student';
      final proof = <String, dynamic>{
        'owner': 'owner-a',
        'studentId': student,
        'verified': true,
        'accountKind': 'keycloak',
        'credentialEpoch': 4,
        'email': 'farmer@example.org',
      };
      final sync = DeviceProofFixture(store, proof);
      try {
        await enrollDeviceUnlock(store, sync, 'Separate local phrase 42');
        expect(
          (await store.setting('offlineEmailVerifier'))['purpose'],
          'device-unlock',
        );
        proof['owner'] = 'owner-b';
        await expectLater(
          enrollDeviceUnlock(store, sync, 'Another local phrase 42'),
          throwsStateError,
        );
        proof['owner'] = 'owner-a';
        proof['verified'] = false;
        await expectLater(
          enrollDeviceUnlock(store, sync, 'Another local phrase 42'),
          throwsStateError,
        );
      } finally {
        AccountAccess.unlocked.value = null;
        sync.dispose();
      }
    },
  );
}
