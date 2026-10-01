import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:farmerplus_mobile/offline_access.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:geolocator/geolocator.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:farmerplus_mobile/auth.dart';
import 'package:farmerplus_mobile/appearance.dart';
import 'package:farmerplus_mobile/location.dart';
import 'package:farmerplus_mobile/settings.dart';
import 'package:farmerplus_mobile/services.dart';
import 'package:farmerplus_mobile/store.dart';
import 'package:farmerplus_mobile/sync.dart';

Position position({double accuracy = 10, DateTime? at}) => Position(
  longitude: 28.1,
  latitude: -25.7,
  timestamp: at ?? DateTime.now(),
  accuracy: accuracy,
  altitude: 0,
  altitudeAccuracy: 0,
  heading: 0,
  headingAccuracy: 0,
  speed: 0,
  speedAccuracy: 0,
);

Future<void> settleAccess(WidgetTester tester) async {
  for (var i = 0; i < 60; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump(const Duration(milliseconds: 50));
    if (find.byType(CircularProgressIndicator).evaluate().isEmpty) return;
  }
  fail('Account access did not finish its asynchronous checks.');
}

class OidcFixtureSync extends SyncEngine {
  OidcFixtureSync(super.store);
  int opened = 0;
  int restorations = 0;
  @override
  Future<void> sync({Set<String>? recordIds, bool pendingOnly = false}) async {
    restorations++;
  }

  @override
  Future<bool> onlineAvailable() async => true;
  @override
  Future<dynamic> request(String method, String route, {Object? body}) async {
    if (route == '/sync/pull') return {'records': []};
    throw SyncRequestError(401, 'Sign in');
  }

  @override
  Future<Map<String, dynamic>> nativeLogin(
    String username,
    String password,
  ) async {
    opened++;
    return {
      'owner': 'fixture-owner',
      'studentId': '0123456789abcdef0123456789abcdef',
      'username': 'fixture_farmer',
      'accountKind': 'native',
      'verified': true,
      'admin': false,
      'credentialEpoch': 0,
      'oidcSession': {
        'kind': 'native',
        'access_token': 'opaque-fixture-only',
        'refresh_token': 'refresh-fixture-only',
        'expires': DateTime.now().millisecondsSinceEpoch + 300000,
        'server': await base(),
        'farmerplusId': '0123456789abcdef0123456789abcdef',
      },
    };
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late Directory dir;
  late FarmStore store;
  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    Map<String, dynamic>? vault;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(OfflineAccess.channel, (call) async {
          if (call.method == 'biometricInfo') return false;
          if (call.method == 'info') return vault;
          if (call.method == 'enroll') {
            vault = Map<String, dynamic>.from(call.arguments)
              ..remove('password');
            return vault;
          }
          if (call.method == 'clear') {
            vault = null;
            return null;
          }
          throw PlatformException(code: 'unsupported');
        });
    AccountAccess.unlocked.value = null;
    AccountAccess.offlineSession = false;
    AccountAccess.authenticating = false;
    dir = await Directory.systemTemp.createTemp('farmer_features_');
    store = await FarmStore.open(
      factory: databaseFactoryFfiNoIsolate,
      filesPath: dir.path,
    );
  });
  tearDown(() async {
    await store.close();
    await dir.delete(recursive: true);
    AccountAccess.unlocked.value = null;
  });
  test(
    'Password baseline accepts eight mixed-case characters and rejects weak forms',
    () {
      expect(passwordIssue('GoodPass'), isNull);
      for (final value in [
        'short',
        'alllowercase',
        'ALLUPPERCASE',
        '12345678',
      ]) {
        expect(passwordIssue(value), isNotNull);
      }
    },
  );
  test(
    'First verified owner retains legacy drafts and records and blocks other owners',
    () async {
      final id = await store.save('diary', {'title': 'Existing activity'});
      await store.setSetting('profileDraft', {'name': 'Draft'});
      await AccountAccess.verifyOwner(store, 'local:first', syncOwner: 'first');
      await AccountAccess.unlock(
        store,
        'local:first',
        'Original farmer',
        'local',
      );
      await expectLater(
        AccountAccess.verifyOwner(store, 'local:second', syncOwner: 'second'),
        throwsStateError,
      );
      expect((await store.get(id))!['data']['title'], 'Existing activity');
      expect((await store.setting('profileDraft'))['name'], 'Draft');
      expect((await store.db.query('queue')).length, 1);
      await AccountAccess.signOut(store, SyncEngine(store));
      expect(AccountAccess.unlocked.value, isNull);
      expect(await store.get(id), isNotNull);
      await AccountAccess.restore(store);
      expect(AccountAccess.unlocked.value, isNull);
    },
  );
  test(
    'Legacy Learning downloads may only bind to their matching verified identity',
    () async {
      await store.setSetting('learningUser', {'id': 31});
      await store.setSetting('learningCourse:1', {'offlineText': 'Kept'});
      await expectLater(
        AccountAccess.verifyOwner(store, 'moodle:32'),
        throwsStateError,
      );
      await AccountAccess.verifyOwner(store, 'moodle:31');
      expect((await store.setting('learningCourse:1'))['offlineText'], 'Kept');
    },
  );
  test(
    'Original sync owner can recover a legacy device without cross-account transfer',
    () async {
      await store.setSetting('boundOwner', 'original');
      await store.setSetting('learningUser', {'id': 31});
      await expectLater(
        AccountAccess.verifyOwner(store, 'local:other', syncOwner: 'other'),
        throwsStateError,
      );
      await AccountAccess.verifyOwner(
        store,
        'local:original',
        syncOwner: 'original',
      );
    },
  );
  test(
    'A saved session flag alone cannot unlock a cold offline start',
    () async {
      await AccountAccess.unlock(store, 'local:first', 'First', 'local');
      AccountAccess.unlocked.value = null;
      await AccountAccess.restore(store);
      expect(AccountAccess.unlocked.value, isNull);
      AccountAccess.unlocked.value = null;
      await store.setSetting('accessOwner', 'local:other');
      await AccountAccess.restore(store);
      expect(AccountAccess.unlocked.value, isNull);
    },
  );
  test('Location rejects stale and inaccurate fixes', () {
    DeviceLocation.validate(position());
    expect(
      () => DeviceLocation.validate(position(accuracy: 5000)),
      throwsStateError,
    );
    expect(
      () => DeviceLocation.validate(
        position(at: DateTime.now().subtract(const Duration(minutes: 5))),
      ),
      throwsStateError,
    );
  });
  test(
    'Weather uses fresh supplied GPS, caches timestamp, throttles and keeps cache offline',
    () async {
      await store.setSetting('weatherEnabled', true);
      var calls = 0;
      final client = MockClient((r) async {
        calls++;
        expect(r.url.host, 'api.open-meteo.com');
        expect(r.url.queryParameters['latitude'], '-25.7000');
        expect(r.url.queryParameters['forecast_days'], '14');
        expect(r.url.queryParameters['timezone'], 'auto');
        expect(r.url.queryParameters['timeformat'], 'unixtime');
        return http.Response(
          jsonEncode({
            'current': {'temperature_2m': 20},
            'current_units': {'temperature_2m': '°C'},
            'hourly': {
              'time': [],
              'temperature_2m': [],
              'precipitation_probability': [],
              'precipitation': [],
              'wind_speed_10m': [],
            },
            'hourly_units': {},
          }),
          200,
        );
      });
      final service = WeatherService(
        store,
        client: client,
        locate: () async => position(),
        connections: () async => [ConnectivityResult.wifi],
      );
      await service.refresh();
      final cache = await service.cached();
      expect(cache!['latitude'], -25.7);
      expect(cache['updated'], isNotNull);
      expect(calls, 1);
      await expectLater(service.refresh(), throwsStateError);
      expect(calls, 1);
      await store.setSetting('weatherLastAttempt', null);
      final offline = WeatherService(
        store,
        client: client,
        locate: () async => position(),
        connections: () async => [ConnectivityResult.none],
      );
      await expectLater(offline.refresh(), throwsStateError);
      expect(calls, 1);
      expect((await offline.cached())!['updated'], cache['updated']);
      client.close();
    },
  );
  test(
    'Wallpaper persists locally, never queues, and reset restores bundled default',
    () async {
      final bytes = await File('assets/branding/fp-original.png').readAsBytes();
      await Wallpaper.save(store, bytes);
      expect(await store.setting('wallpaperPhoto'), base64Encode(bytes));
      expect(await store.db.query('queue'), isEmpty);
      await Wallpaper.reset(store);
      expect(await store.setting('wallpaperPhoto'), isNull);
      await expectLater(
        Wallpaper.save(store, utf8.encode('not an image')),
        throwsStateError,
      );
    },
  );
  test(
    'Map cannot be enabled without complete resources, source, attribution and permission',
    () {
      String? check({
        bool complete = true,
        String source = 'https://publisher.example/maps',
        String license = 'CC BY 4.0',
        String attribution = 'Publisher',
        bool permitted = true,
      }) => mapAuthorizationIssue(
        complete: complete,
        source: source,
        license: license,
        attribution: attribution,
        permitted: permitted,
      );
      expect(check(), isNull);
      expect(check(complete: false), isNotNull);
      expect(check(source: 'file://unknown'), isNotNull);
      expect(check(license: ''), isNotNull);
      expect(check(attribution: ''), isNotNull);
      expect(check(permitted: false), isNotNull);
    },
  );
  testWidgets(
    'Fresh root is sign-in and never exposes the farm before authentication',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: AuthGate(
            store: store,
            sync: OidcFixtureSync(store),
            child: const Text('Private farm records'),
          ),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await settleAccess(tester);
      expect(find.text('Your farm, together.'), findsNothing);
      expect(find.text('Private farm records'), findsNothing);
      expect(find.text('Sign in to FarmerPlus'), findsNothing);
      expect(find.text('Connection settings'), findsNothing);
      expect(find.text('Farmer sign in'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'Native sign-in stays in the app and keeps credentials out of records',
    (tester) async {
      final sync = OidcFixtureSync(store);
      await tester.binding.setSurfaceSize(const Size(390, 844));
      await tester.pumpWidget(
        MaterialApp(
          home: SignInPage(store: store, sync: sync),
        ),
      );
      expect(find.byType(TextField), findsNWidgets(2));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 250)),
      );
      await settleAccess(tester);
      expect(sync.opened, 0);
      expect(find.text('Create account'), findsOneWidget);
      await tester.tap(find.text('Create account'));
      await tester.pumpAndSettle();
      expect(find.text('Create farmer account'), findsOneWidget);
      expect(find.text('Confirm password'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('Connection settings'), findsNothing);
      await tester.enterText(find.byType(TextField).first, 'fixture_farmer');
      await tester.enterText(find.byType(TextField).last, 'FixturePassword');
      await tester.tap(find.text('Sign in'));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await tester.pumpAndSettle();
      expect(
        AccountAccess.unlocked.value,
        'farmerplus:0123456789abcdef0123456789abcdef',
      );
      expect(sync.opened, 1);
      await tester.runAsync(() async {
        for (var i = 0; i < 30 && sync.busy; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      });
      expect(sync.busy, false);
      expect(sync.restorations, 1);
      final settings = await tester.runAsync(() => store.db.query('settings'));
      expect(jsonEncode(settings), isNot(contains('FixturePassword')));
      expect(jsonEncode(settings), isNot(contains('opaque-fixture-only')));
      expect(jsonEncode(settings), isNot(contains('refresh-fixture-only')));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.binding.setSurfaceSize(null);
      sync.dispose();
    },
  );
  test(
    'Expired offline verification locks access but retains unsent records',
    () async {
      final id = await store.save('diary', {'title': 'Unsent work'});
      await AccountAccess.unlock(
        store,
        'farmerplus:0123456789abcdef0123456789abcdef',
        'Farmer',
        'oidc',
      );
      await AccountAccess.secure.write(key: 'farmer.access.until', value: '1');
      await AccountAccess.restore(store);
      expect(AccountAccess.unlocked.value, isNull);
      expect(await store.get(id), isNotNull);
      expect(await store.db.query('queue'), isNotEmpty);
    },
  );
}
