import 'dart:io';

import 'package:farmerplus_mobile/store.dart';
import 'package:farmerplus_mobile/sync.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class RecoverySync extends SyncEngine {
  int automaticCalls = 0;
  RecoverySync(super.store, {required super.client});

  @override
  Future<void> automatic() async {
    automaticCalls++;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  test(
    'pending browser work probes service recovery and clears backoff',
    () async {
      final directory = await Directory.systemTemp.createTemp('sync-recovery-');
      final store = await FarmStore.open(
        factory: databaseFactoryFfi,
        filesPath: directory.path,
      );
      await store.setSetting('server', 'http://127.0.0.1:8087');
      await store.setSetting('syncMode', 'automatic');
      await store.save('diary', {'title': 'Queued offline'});
      var probes = 0;
      final engine =
          RecoverySync(
              store,
              client: MockClient((request) async {
                probes++;
                return http.Response('{}', 200);
              }),
            )
            ..failures = 3
            ..retryAfter = DateTime.now().add(const Duration(minutes: 10));

      engine.scheduleRecoveryProbe(delay: const Duration(milliseconds: 10));
      await Future<void>.delayed(const Duration(milliseconds: 80));

      expect(probes, 1);
      expect(engine.serverOnline, isTrue);
      expect(engine.retryAfter, isNull);
      expect(engine.failures, 0);
      expect(engine.automaticCalls, 1);

      engine.dispose();
      await store.close();
      await directory.delete(recursive: true);
    },
  );
}
