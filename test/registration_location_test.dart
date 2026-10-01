import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:geolocator/geolocator.dart';
import 'package:farmerplus_mobile/location.dart';
import 'package:farmerplus_mobile/store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late Directory dir;
  late FarmStore store;
  Position fix(double lat) => Position(
    latitude: lat,
    longitude: 28,
    timestamp: DateTime.now(),
    accuracy: 9,
    altitude: 0,
    altitudeAccuracy: 0,
    heading: 0,
    headingAccuracy: 0,
    speed: 0,
    speedAccuracy: 0,
  );
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('registration_location_');
    store = await FarmStore.open(
      factory: databaseFactoryFfi,
      filesPath: dir.path,
    );
  });
  tearDown(() async {
    await store.close();
    await dir.delete(recursive: true);
  });
  test(
    'only account-bound GPS is queued, first fix survives weather moves',
    () async {
      await DeviceLocation.saveRegistration(store, fix(-25));
      expect(await store.records('pin'), isEmpty);
      await store.setSetting('accessOwner', 'farmerplus:test-owner');
      await DeviceLocation.saveRegistration(store, fix(-25));
      await DeviceLocation.saveRegistration(store, fix(-26));
      final pins = await store.records('pin');
      expect(pins, hasLength(1));
      expect(pins.single['data']['lat'], -25);
      expect(await store.db.query('queue'), hasLength(1));
      expect((await store.setting('registrationLocation'))['lat'], -25);
    },
  );
  test(
    'concurrent requests cannot create duplicate registration pins',
    () async {
      await store.setSetting('accessOwner', 'farmerplus:test-owner');
      await Future.wait([
        DeviceLocation.saveRegistration(store, fix(-25)),
        DeviceLocation.saveRegistration(store, fix(-26)),
      ]);
      expect(await store.records('pin'), hasLength(1));
    },
  );
  test('online sign-in updates the same registration record', () async {
    await store.setSetting('accessOwner', 'farmerplus:test-owner');
    final id = await DeviceLocation.saveRegistration(store, fix(-25));
    final updated = await DeviceLocation.saveRegistration(
      store,
      fix(-26),
      updateExisting: true,
    );
    expect(updated, id);
    final pins = await store.records('pin');
    expect(pins, hasLength(1));
    expect(pins.single['data']['lat'], -26);
    expect(
      pins.single['data']['source'],
      'Device location — verified online sign-in',
    );
  });
}
