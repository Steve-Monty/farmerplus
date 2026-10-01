import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:farmerplus_mobile/store.dart';
import 'package:farmerplus_mobile/sync.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  test(
    'Inbox receipt names only records accepted into local storage',
    () async {
      FlutterSecureStorage.setMockInitialValues({});
      PackageInfo.setMockInitialValues(
        appName: 'Fixture',
        packageName: 'test.fixture',
        version: '1.0',
        buildNumber: '1',
        buildSignature: '',
      );
      final directory = await Directory.systemTemp.createTemp(
        'admin-receipt-test-',
      );
      final store = await FarmStore.open(
        factory: databaseFactoryFfi,
        filesPath: directory.path,
      );
      await store.setSetting('server', 'http://127.0.0.1:8087');
      await store.setSetting('boundServer', 'http://127.0.0.1:8087');
      await store.setSetting('consent', true);
      const id = '00000000-0000-4000-8000-000000000001';
      final reports = <Map<String, dynamic>>[];
      final engine = SyncEngine(
        store,
        client: MockClient((request) async {
          if (request.url.path == '/sync/complete') {
            expect(await store.get(id), isNotNull);
            reports.add(Map<String, dynamic>.from(jsonDecode(request.body)));
            return http.Response('{"recorded":true}', 200);
          }
          return http.Response(
            jsonEncode({
              'records': [
                {
                  'id': id,
                  'kind': 'inbox',
                  'version': 1,
                  'deleted': false,
                  'updated': '2026-09-15T10:00:00Z',
                  'data': {
                    'title': 'Fixture message',
                    'read': false,
                    'completed': false,
                    'source': 'FarmerPlus',
                    'action': 'Open',
                    'route': 'task:00000000-0000-4000-8000-000000000002',
                    'priority': 'normal',
                  },
                },
              ],
            }),
            200,
          );
        }),
      )..token = 'fixture';
      try {
        await engine.sync();
        expect(reports, hasLength(1));
        expect(reports.single['receivedInboxIds'], [id]);
        expect(engine.status, 'Synced');
      } finally {
        engine.dispose();
        await store.close();
        await directory.delete(recursive: true);
      }
    },
  );
}
