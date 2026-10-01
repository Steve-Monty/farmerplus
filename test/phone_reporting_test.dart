import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:farmerplus_mobile/store.dart';
import 'package:farmerplus_mobile/phone_reporting.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late Directory dir;
  late FarmStore store;
  const owner = 'owner-one', server = 'https://example.test';
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('phone-ack-');
    store = await FarmStore.open(
      factory: databaseFactoryFfi,
      filesPath: dir.path,
    );
    await store.setSetting('boundOwner', owner);
    await store.setSetting('boundServer', server);
  });
  tearDown(() async {
    await store.close();
    await dir.delete(recursive: true);
  });
  Future<Map<String, dynamic>> collect() async => {
    'technical': {
      'androidId': '0123456789abcdef',
      'phoneIdentifier': '0123456789abcdef',
      'versionCode': 4016,
    },
    'permissions': {'camera': 'denied'},
  };
  Map<String, dynamic> ack(Map<String, dynamic> b) => {
    'ack': 'y',
    'reportId': b['reportId'],
    'deviceId': b['deviceId'],
    'owner': owner,
    'receivedAt': 12345,
  };
  test(
    'lost acknowledgement retains exact pending report across restart',
    () async {
      Map<String, dynamic>? first;
      final reporter = PhoneReporter(store, collector: collect);
      await reporter.report(
        owner: owner,
        server: server,
        captureCurrent: true,
        send: (b) async {
          first = b;
          throw StateError('Lost ACK');
        },
      );
      expect((await store.setting('phoneReport:$owner:$server'))['ack'], 'n');
      final restarted = PhoneReporter(
        store,
        collector: () async => throw StateError('Must retry stored data'),
      );
      await restarted.report(
        owner: owner,
        server: server,
        send: (b) async {
          expect(b, first);
          return ack(b);
        },
      );
      expect((await store.setting('phoneReport:$owner:$server'))['ack'], 'y');
      expect(first!.containsKey('local'), false);
    },
  );
  test('mismatched acknowledgements never set Ack y', () async {
    final reporter = PhoneReporter(store, collector: collect);
    for (final field in ['owner', 'deviceId', 'reportId', 'ack']) {
      await reporter.report(
        owner: owner,
        server: server,
        forceRetry: true,
        captureCurrent: true,
        send: (b) async => {...ack(b), field: 'wrong'},
      );
      expect((await store.setting('phoneReport:$owner:$server'))['ack'], 'n');
    }
  });
  test(
    'fresh snapshots require online login while retries retain installation ID',
    () async {
      final ids = <String>[], devices = <String>[];
      Future<dynamic> send(Map<String, dynamic> b) async {
        ids.add(b['reportId']);
        devices.add(b['deviceId']);
        return ack(b);
      }

      final reporter = PhoneReporter(store, collector: collect);
      await reporter.report(owner: owner, server: server, send: send);
      expect(ids, isEmpty);
      await reporter.report(
        owner: owner,
        server: server,
        send: send,
        captureCurrent: true,
      );
      await reporter.report(owner: owner, server: server, send: send);
      expect(ids.length, 1);
      await PhoneReporter(
        store,
        collector: collect,
      ).report(owner: owner, server: server, send: send, captureCurrent: true);
      expect(ids.toSet().length, 2);
      expect(devices.toSet().length, 1);
    },
  );
  test(
    'owner change while request is pending does not acknowledge old account',
    () async {
      await PhoneReporter(store, collector: collect).report(
        owner: owner,
        server: server,
        captureCurrent: true,
        send: (b) async {
          await store.setSetting('boundOwner', 'someone-else');
          return ack(b);
        },
      );
      expect((await store.setting('phoneReport:$owner:$server'))['ack'], 'n');
    },
  );
  test(
    'online login retries pending report then captures current state',
    () async {
      final sent = <String>[];
      final reporter = PhoneReporter(store, collector: collect);
      await reporter.report(
        owner: owner,
        server: server,
        captureCurrent: true,
        send: (body) async {
          throw StateError('Offline before acknowledgement');
        },
      );
      await PhoneReporter(store, collector: collect).report(
        owner: owner,
        server: server,
        captureCurrent: true,
        send: (body) async {
          sent.add(body['reportId']);
          return ack(body);
        },
      );
      expect(sent.length, 2);
      expect(sent.toSet().length, 2);
    },
  );
}
