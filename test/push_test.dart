import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:farmerplus_mobile/push.dart';
import 'package:farmerplus_mobile/appearance.dart';
import 'package:farmerplus_mobile/auth.dart';
import 'package:farmerplus_mobile/store.dart';
import 'package:farmerplus_mobile/sync.dart';
import 'package:farmerplus_mobile/services.dart';

class TestSync extends SyncEngine {
  bool offline = false;
  final calls = <String>[];
  TestSync(super.store);
  @override
  Future<dynamic> request(String method, String route, {Object? body}) async {
    calls.add('$method $route');
    if (offline) throw const SocketException('offline');
    if (route == '/notifications') {
      return {
        'items': [
          {
            'id': '00000000-0000-4000-8000-000000000001',
            'created': 1,
            'read': null,
            'title': 'Saved update',
          },
        ],
        'fetchedAt': 2,
      };
    }
    return {'ack': 'y'};
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  test('push payload accepts only versioned notification UUIDs', () {
    expect(
      pushNotificationId({
        'schemaVersion': '1',
        'notificationId': '00000000-0000-4000-8000-000000000001',
      }),
      isNotNull,
    );
    for (final value in ['https://evil.test', 'task:abc', '../auth', null]) {
      expect(
        pushNotificationId({'schemaVersion': '1', 'notificationId': value}),
        isNull,
      );
    }
    expect(
      pushNotificationId({
        'schemaVersion': '2',
        'notificationId': '00000000-0000-4000-8000-000000000001',
      }),
      isNull,
    );
  });
  test(
    'inbox survives offline, retains pending reads and isolates accounts',
    () async {
      final dir = await Directory.systemTemp.createTemp('push-test-');
      final store = await FarmStore.open(
        factory: databaseFactoryFfi,
        filesPath: dir.path,
      );
      final sync = TestSync(store);
      final push = PushService(
        store,
        sync,
        Reminders(),
        GlobalKey<NavigatorState>(),
      );
      try {
        await store.setSetting('server', 'https://example.test');
        await store.setSetting('boundServer', 'https://example.test');
        await store.setSetting('boundOwner', 'one');
        AccountAccess.unlocked.value = 'farmerplus:one';
        await push.refresh();
        expect((await push.cached()).length, 1);
        sync.offline = true;
        await push.refresh();
        expect((await push.cached()).length, 1);
        await push.markRead('00000000-0000-4000-8000-000000000001');
        expect((await push.cached()).single['read'], isNotNull);
        // Wait for the non-blocking retry to settle before changing account scope.
        while (push.busy) {
          await Future<void>.delayed(const Duration(milliseconds: 1));
        }
        await store.setSetting('boundOwner', 'two');
        AccountAccess.unlocked.value = 'farmerplus:two';
        expect(await push.cached(), isEmpty);
        await store.setSetting('boundOwner', 'one');
        AccountAccess.unlocked.value = 'farmerplus:one';
        sync.offline = false;
        await push.refresh();
        expect(
          sync.calls,
          contains(
            'POST /notifications/00000000-0000-4000-8000-000000000001/read',
          ),
        );
        expect((await push.cached()).single['read'], isNotNull);
        AccountAccess.unlocked.value = null;
        expect(await push.cached(), isEmpty);
      } finally {
        push.dispose();
        await store.close();
        await dir.delete(recursive: true);
        AccountAccess.unlocked.value = null;
      }
    },
  );
  testWidgets(
    'Home glass uses precisely 60 percent opacity without changing other panels',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                HomeGlassOpacity(
                  opacity: .60,
                  child: LiquidGlass(child: Text('Home')),
                ),
                LiquidGlass(child: Text('Other')),
              ],
            ),
          ),
        ),
      );
      final ink = tester.widgetList<Ink>(find.byType(Ink)).toList();
      final home =
          (ink[0].decoration as BoxDecoration).gradient as LinearGradient;
      final other =
          (ink[1].decoration as BoxDecoration).gradient as LinearGradient;
      expect(home.colors.first.a, .60);
      expect(other.colors.first.a, closeTo(173 / 255, .0001));
    },
  );
  testWidgets('four photo wallpapers are bundled and selectable', (
    tester,
  ) async {
    for (final preset in ['orchard', 'mountains', 'sunrise', 'botanical']) {
      await tester.pumpWidget(
        MaterialApp(
          home: FarmBackdrop(
            preset: preset,
            glassOpacity: .60,
            child: const Scaffold(
              backgroundColor: Colors.transparent,
              body: LiquidGlass(child: Text('FarmerPlus')),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
        tester.widget<Image>(find.byType(Image)).image,
        isA<ResizeImage>(),
      );
    }
  });
}
