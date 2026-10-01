import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:farmerplus_mobile/domain.dart';
import 'package:farmerplus_mobile/store.dart';
import 'package:farmerplus_mobile/sync.dart';
import 'package:farmerplus_mobile/provider_kit.dart';

class TestWallet implements WalletProvider {
  int calls = 0;
  @override
  Future<Map<String, dynamic>> verifiedBalance(AssetConfiguration a) async => {
    'testOnly': true,
  };
  @override
  Future<Map<String, dynamic>> quote(
    AssetConfiguration a,
    String r,
    String n,
  ) async => {'testOnly': true};
  @override
  Future<String> submit(
    Map<String, dynamic> q, {
    required bool explicitlyApproved,
  }) async {
    calls++;
    return 'TEST-ONLY';
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));
  test(
    'payment gate requires current explicit approval and forbids duplicate submission',
    () async {
      final provider = TestWallet();
      final gate = PaymentApprovalGate(provider);
      const asset = AssetConfiguration(
        'TEST-NET',
        'TEST-CONTRACT',
        'TEST',
        'TEST-CUSTODY',
      );
      PaymentReview review(DateTime expiry) => PaymentReview(
        asset: asset,
        id: 'TEST-QUOTE',
        recipient: 'TEST-RECIPIENT',
        amount: '2.50',
        fee: '0.01',
        expiresAt: expiry,
      );
      final live = review(DateTime.now().add(const Duration(minutes: 1)));
      await expectLater(
        gate.approve(
          live,
          approvedQuoteId: live.id,
          connected: false,
          userApproved: true,
        ),
        throwsStateError,
      );
      await expectLater(
        gate.approve(
          live,
          approvedQuoteId: live.id,
          connected: true,
          userApproved: false,
        ),
        throwsStateError,
      );
      await expectLater(
        gate.approve(
          review(DateTime(2000)),
          approvedQuoteId: live.id,
          connected: true,
          userApproved: true,
        ),
        throwsStateError,
      );
      expect(provider.calls, 0);
      expect(
        await gate.approve(
          live,
          approvedQuoteId: live.id,
          connected: true,
          userApproved: true,
        ),
        'TEST-ONLY',
      );
      await expectLater(
        gate.approve(
          live,
          approvedQuoteId: live.id,
          connected: true,
          userApproved: true,
        ),
        throwsStateError,
      );
      expect(provider.calls, 1);
    },
  );
  test(
    'offline queue survives failed push; retry keeps op id and applies server version',
    () async {
      final dir = await Directory.systemTemp.createTemp('sync_test_');
      final store = await FarmStore.open(
        factory: databaseFactoryFfi,
        filesPath: dir.path,
      );
      final id = await store.save('diary', {'title': 'Offline entry'});
      await store.setSetting('server', 'http://127.0.0.1:8087');
      await store.setSetting('boundServer', 'http://127.0.0.1:8087');
      await store.setSetting('consent', true);
      var fail = true;
      final ops = <String>[];
      final remote = {
        'id': id,
        'kind': 'diary',
        'data': {'title': 'Offline entry'},
        'version': 1,
        'deleted': false,
        'updated': DateTime.now().toUtc().toIso8601String(),
      };
      final client = MockClient((r) async {
        if (r.url.path == '/sync/push') {
          final body = jsonDecode(r.body);
          ops.add(body['op_id']);
          if (fail) return http.Response('{"detail":"Test offline"}', 503);
          return http.Response(jsonEncode({'record': remote}), 200);
        }
        return http.Response(
          jsonEncode({
            'records': [remote],
          }),
          200,
        );
      });
      final engine = SyncEngine(store, client: client)..token = 'TEST-TOKEN';
      await engine.sync();
      expect(await store.db.query('queue'), hasLength(1));
      fail = false;
      await engine.sync();
      expect(ops[0], ops[1]);
      expect(await store.db.query('queue'), isEmpty);
      expect((await store.get(id))!['version'], 1);
      engine.dispose();
      await store.close();
      await dir.delete(recursive: true);
    },
  );
  test('changing server cannot leak a linked phone queue', () async {
    final dir = await Directory.systemTemp.createTemp('scope_test_');
    final store = await FarmStore.open(
      factory: databaseFactoryFfi,
      filesPath: dir.path,
    );
    await store.save('diary', {'title': 'Private'});
    await store.setSetting('server', 'http://127.0.0.1:8088');
    await store.setSetting('boundServer', 'http://127.0.0.1:8087');
    await store.setSetting('consent', true);
    int requests = 0;
    final engine = SyncEngine(
      store,
      client: MockClient((r) async {
        requests++;
        return http.Response('{}', 200);
      }),
    )..token = 'TEST-TOKEN';
    await engine.sync();
    expect(requests, 0);
    expect(await store.db.query('queue'), hasLength(1));
    engine.dispose();
    await store.close();
    await dir.delete(recursive: true);
  });
}
