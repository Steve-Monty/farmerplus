import 'dart:io';
import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:farmerplus_mobile/offline_access.dart';
import 'package:farmerplus_mobile/store.dart';
import 'package:farmerplus_mobile/sync.dart';
import 'package:farmerplus_mobile/auth.dart';

const proof = {
  'verified': true,
  'owner': 'qa-owner',
  'studentId': '0123456789abcdef0123456789abcdef',
  'username': 'qa_farmer',
  'credentialEpoch': 2,
};

class AccessSync extends SyncEngine {
  AccessSync(super.store);
  bool online = true, cleared = false;
  Object? failure;
  Completer<dynamic>? pending;
  int calls = 0;
  Map<String, dynamic> result = Map.of(proof);
  @override
  Future<bool> onlineAvailable() async => online;
  @override
  Future<dynamic> request(String method, String route, {Object? body}) async {
    calls++;
    if (pending != null) return pending!.future;
    if (failure != null) throw failure!;
    return result;
  }

  @override
  Future<void> clearLocalSession() async {
    cleared = true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late Directory dir;
  late FarmStore store;
  late AccessSync sync;
  late OfflineAccess access;
  Map<String, dynamic>? vault;
  String? savedPassword;
  int checks = 0;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('offline-login-test-');
    store = await FarmStore.open(
      factory: databaseFactoryFfi,
      filesPath: dir.path,
    );
    for (final item in {
      'server': 'http://127.0.0.1:8089',
      'boundOwner': proof['owner'],
      'studentId': proof['studentId'],
      'accessOwner': 'farmerplus:${proof['studentId']}',
    }.entries) {
      await store.setSetting(item.key, item.value);
    }
    sync = AccessSync(store);
    SyncEngine.accessRejected.value = false;
    access = OfflineAccess(store, sync);
    vault = null;
    savedPassword = null;
    checks = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(OfflineAccess.channel, (call) async {
          final args = Map<String, dynamic>.from(call.arguments ?? {});
          switch (call.method) {
            case 'info':
              return vault;
            case 'clear':
              if (!args.containsKey('credentialEpoch') ||
                  vault?['credentialEpoch'] == args['credentialEpoch']) {
                vault = null;
                savedPassword = null;
              }
              return null;
            case 'enroll':
              savedPassword = args.remove('password');
              vault = args;
              return null;
            case 'verify':
              checks++;
              if (args['password'] != savedPassword ||
                  args['username'] != vault?['username']) {
                throw PlatformException(
                  code: 'denied',
                  message: 'Password was not accepted',
                );
              }
              return vault;
          }
          return null;
        });
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(OfflineAccess.channel, null);
    sync.dispose();
    AccountAccess.offlineSession = false;
    AccountAccess.unlocked.value = null;
    await store.close();
    await dir.delete(recursive: true);
  });
  test(
    'online proof provisions a bound verifier without credentials in SQLite',
    () async {
      await access.prepare('Synthetic-Password');
      expect(vault?['owner'], proof['owner']);
      expect(
        (await store.db.query('settings')).toString(),
        isNot(contains('Synthetic-Password')),
      );
      sync.online = false;
      expect(
        (await access.verify('qa_farmer', 'Synthetic-Password'))['owner'],
        proof['owner'],
      );
      expect(sync.calls, 1);
      await expectLater(
        access.verify('qa_farmer', 'Wrong'),
        throwsA(isA<PlatformException>()),
      );
    },
  );
  test(
    'online rejection never falls back to a valid offline password',
    () async {
      await access.prepare('Synthetic-Password');
      sync.failure = SyncRequestError(401, 'Revoked');
      await expectLater(
        access.verify('qa_farmer', 'Synthetic-Password'),
        throwsA(isA<SyncRequestError>()),
      );
      expect(vault, isNull);
      expect(checks, 0);
    },
  );
  test(
    'a changed remote credential version invalidates the old verifier',
    () async {
      await access.prepare('Synthetic-Password');
      sync.result = {...proof, 'credentialEpoch': 3};
      await expectLater(
        access.verify('qa_farmer', 'Synthetic-Password'),
        throwsStateError,
      );
      expect(vault, isNull);
      expect(checks, 0);
    },
  );
  test(
    'password replacement follows server acceptance and clears old tokens locally',
    () async {
      await access.prepare('Synthetic-Password');
      sync.result = {...proof, 'credentialEpoch': 3};
      await access.changePassword(
        'Synthetic-Password',
        'New-Synthetic-Password',
      );
      expect(savedPassword, 'New-Synthetic-Password');
      expect(vault?['credentialEpoch'], 3);
      expect(sync.cleared, true);
      expect(sync.credentialChangeInProgress, false);
      sync.online = false;
      await expectLater(
        access.verify('qa_farmer', 'Synthetic-Password'),
        throwsA(isA<PlatformException>()),
      );
      expect(
        (await access.verify(
          'qa_farmer',
          'New-Synthetic-Password',
        ))['credentialEpoch'],
        3,
      );
    },
  );
  test(
    'offline password changes are blocked and never queued or erase existing verifier',
    () async {
      await access.prepare('Synthetic-Password');
      sync.online = false;
      await expectLater(
        access.changePassword('Synthetic-Password', 'New-Password'),
        throwsStateError,
      );
      expect(savedPassword, 'Synthetic-Password');
      expect(sync.calls, 1);
      expect(await store.db.query('queue'), isEmpty);
    },
  );
  test(
    'unconfirmed password change fails closed while farm data stays intact',
    () async {
      final record = await store.save('diary', {'title': 'Saved work'});
      await access.prepare('Synthetic-Password');
      sync.failure = const SocketException('Unreachable');
      await expectLater(
        access.changePassword('Synthetic-Password', 'New-Password'),
        throwsStateError,
      );
      expect(vault, isNull);
      expect(await store.get(record), isNotNull);
    },
  );
  test('a different account cannot adopt the saved verifier', () async {
    await access.prepare('Synthetic-Password');
    sync.online = false;
    await store.setSetting('server', 'https://other.invalid');
    await expectLater(
      access.verify('qa_farmer', 'Synthetic-Password'),
      throwsStateError,
    );
    await store.setSetting('server', 'http://127.0.0.1:8089');
    await store.setSetting('boundOwner', 'another-owner');
    await expectLater(
      access.verify('qa_farmer', 'Synthetic-Password'),
      throwsStateError,
    );
    expect(checks, 0);
  });
  test(
    'a stale rejection cannot erase a newer credential or lock its session',
    () async {
      await access.prepare('Synthetic-Password');
      sync.token = 'fixture-only-token';
      AccountAccess.offlineSession = true;
      AccountAccess.unlocked.value = 'farmerplus:${proof['studentId']}';
      sync.pending = Completer<dynamic>();
      final restoring = AccountAccess.restore(store, sync);
      for (var i = 0; i < 20 && sync.calls < 2; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(sync.calls, 2);
      sync.credentialRevision++;
      vault = {...vault!, 'credentialEpoch': 3};
      sync.pending!.completeError(SyncRequestError(401, 'Stale request'));
      await restoring;
      expect(vault?['credentialEpoch'], 3);
      expect(AccountAccess.unlocked.value, 'farmerplus:${proof['studentId']}');
      await OfflineAccess.clear(epoch: 2);
      expect(vault?['credentialEpoch'], 3);
    },
  );
}
