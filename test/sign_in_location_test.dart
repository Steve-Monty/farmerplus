import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:farmerplus_mobile/sign_in_location.dart';
import 'package:farmerplus_mobile/store.dart';
import 'package:farmerplus_mobile/sync.dart';

Position fix(double latitude) => Position(
  latitude: latitude,
  longitude: 28.0697,
  timestamp: DateTime.now(),
  accuracy: 12,
  altitude: 0,
  altitudeAccuracy: 0,
  heading: 0,
  headingAccuracy: 0,
  speed: 0,
  speedAccuracy: 0,
);

class AcknowledgingSync extends SyncEngine {
  AcknowledgingSync(super.store) {
    token = 'test-token';
  }
  bool fail = false;
  final synced = <Set<String>>[];
  @override
  Future<void> sync({Set<String>? recordIds, bool pendingOnly = false}) async {
    if (fail) throw StateError('Network unavailable');
    synced.add({...?recordIds});
    final rows = await store.db.query('queue');
    for (final row in rows) {
      if (recordIds == null || recordIds.contains(row['id'])) {
        await store.acknowledge(row, (row['base_version'] as int) + 1);
      }
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late Directory dir;
  late FarmStore store;
  late AcknowledgingSync sync;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('signin-location-');
    store = await FarmStore.open(
      factory: databaseFactoryFfi,
      filesPath: dir.path,
    );
    sync = AcknowledgingSync(store);
    await store.setSetting('accessOwner', 'farmerplus:test-owner');
  });

  tearDown(() async {
    sync.dispose();
    await store.close();
    await dir.delete(recursive: true);
  });

  test('online sign-in captures a location without enabling weather', () async {
    var weatherCalls = 0;
    Future<String?> country(Position position) async {
      await store.setSetting('gpsCountry', 'South Africa');
      return 'South Africa';
    }

    final first = await OnlineSignInLocation.captureAndSync(
      store,
      sync,
      locate: () async => fix(-26.0565),
      resolveCountry: country,
      refreshWeather: (_) async => weatherCalls++,
    );
    expect(first.captured, true);
    expect(first.weatherReady, false);
    expect(first.backendSynced, true);
    expect(await store.setting('weatherHere'), isNull);
    expect((await store.setting('lastGpsFix'))['lat'], -26.0565);
    expect(await store.setting('gpsCountry'), 'South Africa');
    final pins = await store.records('pin');
    expect(pins, hasLength(1));
    expect(pins.single['data']['purpose'], 'registration');
    expect(pins.single['data']['country'], 'South Africa');
    expect(pins.single['version'], 1);
    expect(await store.db.query('queue'), isEmpty);
    expect(sync.synced.single, {pins.single['id']});
    expect(weatherCalls, 0);

    final second = await OnlineSignInLocation.captureAndSync(
      store,
      sync,
      locate: () async => fix(-26.0570),
      resolveCountry: country,
      refreshWeather: (_) async => weatherCalls++,
    );
    final updated = await store.records('pin');
    expect(second.backendSynced, true);
    expect(updated, hasLength(1));
    expect(updated.single['id'], pins.single['id']);
    expect(updated.single['data']['lat'], -26.0570);
    expect(updated.single['version'], 2);
    expect(weatherCalls, 0);
  });

  test('weather refreshes only after the farmer enables it', () async {
    await store.setSetting('weatherEnabled', true);
    var weatherCalls = 0;
    final result = await OnlineSignInLocation.captureAndSync(
      store,
      sync,
      locate: () async => fix(-26.0565),
      resolveCountry: (_) async => null,
      refreshWeather: (_) async {
        weatherCalls++;
      },
    );
    expect(result.captured, true);
    expect(result.weatherReady, true);
    expect(await store.setting('weatherHere'), true);
    expect(weatherCalls, 1);
  });
  test(
    'GPS and country survive backend failure immediately and across reopen',
    () async {
      sync.fail = true;
      final result = await OnlineSignInLocation.captureAndSync(
        store,
        sync,
        locate: () async => fix(-26.0565),
        resolveCountry: (_) async {
          await store.setSetting('gpsCountry', 'South Africa');
          return 'South Africa';
        },
      );
      expect(result.captured, true);
      expect(result.backendSynced, false);
      expect(await store.setting('signInLocationError'), isNull);
      expect(await store.setting('pendingSignInLocation'), false);
      expect(await store.db.query('queue'), isNotEmpty);
      await store.close();
      store = await FarmStore.open(
        factory: databaseFactoryFfi,
        filesPath: dir.path,
      );
      expect((await store.setting('lastGpsFix'))['lat'], -26.0565);
      expect(await store.setting('gpsCountry'), 'South Africa');
      expect(
        (await store.records('pin')).single['data']['country'],
        'South Africa',
      );
    },
  );
}
