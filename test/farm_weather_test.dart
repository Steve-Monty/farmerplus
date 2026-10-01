import 'dart:convert';
import 'dart:io';
import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:farmerplus_mobile/store.dart';
import 'package:farmerplus_mobile/domain.dart';
import 'package:farmerplus_mobile/services.dart';
import 'package:farmerplus_mobile/weather_location.dart';
import 'package:farmerplus_mobile/location.dart';
import 'package:geolocator/geolocator.dart';

class DeniedLocation extends GeolocatorPlatform {
  int prompts = 0;
  @override
  Future<LocationPermission> checkPermission() async =>
      LocationPermission.denied;
  @override
  Future<bool> isLocationServiceEnabled() async => true;
  @override
  Future<LocationPermission> requestPermission() async {
    prompts++;
    return LocationPermission.denied;
  }
}

class StalledCacheLocation extends GeolocatorPlatform {
  int fixes = 0;
  @override
  Future<LocationPermission> checkPermission() async =>
      LocationPermission.whileInUse;
  @override
  Future<bool> isLocationServiceEnabled() async => true;
  @override
  Future<Position?> getLastKnownPosition({bool forceLocationManager = false}) =>
      Completer<Position?>().future;
  @override
  Future<Position> getCurrentPosition({
    LocationSettings? locationSettings,
  }) async {
    fixes++;
    return Position(
      latitude: -29.79,
      longitude: 30.901,
      timestamp: DateTime.now(),
      accuracy: 20,
      altitude: 0,
      altitudeAccuracy: 0,
      heading: 0,
      headingAccuracy: 0,
      speed: 0,
      speedAccuracy: 0,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late Directory dir;
  late FarmStore store;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('farm-weather-');
    store = await FarmStore.open(
      factory: databaseFactoryFfi,
      filesPath: dir.path,
    );
    await store.setSetting('weatherEnabled', true);
  });
  tearDown(() async {
    await store.close();
    await dir.delete(recursive: true);
  });
  test('a stalled location cache falls back to one shared fresh fix', () async {
    final previous = GeolocatorPlatform.instance;
    final location = StalledCacheLocation();
    GeolocatorPlatform.instance = location;
    try {
      final results = await Future.wait([
        DeviceLocation.weather(store),
        DeviceLocation.weather(store),
      ]);
      expect(results[0].latitude, -29.79);
      expect(location.fixes, 1);
      expect((await store.setting('lastGpsFix'))['lat'], -29.79);
    } finally {
      GeolocatorPlatform.instance = previous;
    }
  });
  test(
    'weather asks for permission once and keeps later starts uninterrupted',
    () async {
      final previous = GeolocatorPlatform.instance;
      final denied = DeniedLocation();
      GeolocatorPlatform.instance = denied;
      try {
        await expectLater(DeviceLocation.weather(store), throwsStateError);
        await expectLater(
          DeviceLocation.weather(store),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              'Location Unavailable',
            ),
          ),
        );
        expect(denied.prompts, 1);
        expect(await DeviceLocation.enable(store), false);
        expect(
          denied.prompts,
          2,
          reason: 'An explicit retry may request permission again',
        );
      } finally {
        GeolocatorPlatform.instance = previous;
      }
    },
  );
  List<Map<String, dynamic>> square(double lon) => [
    GeoPoint(0, lon),
    GeoPoint(0, lon + .01),
    GeoPoint(.01, lon + .01),
    GeoPoint(.01, lon),
  ].map((p) => p.toJson()).toList();
  http.Response forecast() => http.Response(
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

  test(
    'weather defaults off without location, connectivity or HTTP work',
    () async {
      await store.setSetting('weatherEnabled', false);
      var locations = 0, networks = 0, requests = 0;
      final client = MockClient((_) async {
        requests++;
        return forecast();
      });
      final weather = WeatherService(
        store,
        client: client,
        locate: () async {
          locations++;
          throw StateError('must not locate');
        },
        connections: () async {
          networks++;
          return [ConnectivityResult.wifi];
        },
      );
      await weather.refresh();
      expect(locations, 0);
      expect(networks, 0);
      expect(requests, 0);
      client.close();
    },
  );

  test(
    'concave farm uses an interior weather point rather than the outside centroid',
    () {
      const p = [
        GeoPoint(0, 0),
        GeoPoint(0, .03),
        GeoPoint(.03, .03),
        GeoPoint(.03, .02),
        GeoPoint(.01, .02),
        GeoPoint(.01, .01),
        GeoPoint(.03, .01),
        GeoPoint(.03, 0),
      ];
      final point = farmWeatherPoint(p);
      expect(point, isNotNull);
      expect(weatherPointInside(point!, p), isTrue);
      expect(farmWeatherPoint([]), isNull);
    },
  );
  test(
    'farm forecasts never need GPS, have isolated caches, and invalidate edited boundaries',
    () async {
      final a = await store.save('farm', {'name': 'A', 'points': square(0)});
      final b = await store.save('farm', {'name': 'B', 'points': square(1)});
      final requested = <double>[];
      final client = MockClient((r) async {
        requested.add(double.parse(r.url.queryParameters['longitude']!));
        return forecast();
      });
      final weather = WeatherService(
        store,
        client: client,
        locate: () => throw StateError('GPS must not run'),
        connections: () async => [ConnectivityResult.wifi],
      );
      await store.setSetting('selectedFarm', a);
      await weather.refresh();
      expect((await weather.cached())!['farmId'], a);
      expect(await store.setting('weatherPoint:$a'), isNotNull);
      await store.setSetting('selectedFarm', b);
      expect(await weather.cached(), isNull);
      await weather.refresh();
      expect((await weather.cached())!['farmId'], b);
      expect(requested, [.005, 1.005]);
      await store.save('farm', {'name': 'B', 'points': square(2)}, id: b);
      expect(await weather.cached(), isNull);
      await weather.refresh();
      expect(requested.last, 2.005);
      await store.setSetting('selectedFarm', a);
      expect((await weather.cached())!['farmId'], a);
      client.close();
    },
  );
  test(
    'turning weather off during a request prevents a cache update',
    () async {
      final id = await store.save('farm', {
        'name': 'Switch farm',
        'points': square(0),
      });
      await store.setSetting('selectedFarm', id);
      final requested = Completer<void>();
      final response = Completer<http.Response>();
      final client = MockClient((_) {
        requested.complete();
        return response.future;
      });
      final service = WeatherService(
        store,
        client: client,
        connections: () async => [ConnectivityResult.wifi],
      );

      final refresh = service.refresh();
      await requested.future;
      await store.setSetting('weatherEnabled', false);
      response.complete(forecast());
      await refresh;

      expect(await store.setting('weather:farm:$id'), isNull);
      client.close();
    },
  );
  test(
    'missing location has the exact message and does not affect saved farm work',
    () async {
      await store.save('farm', {'name': 'Not mapped yet'});
      final weather = WeatherService(
        store,
        locate: () => throw StateError('permission denied'),
      );
      await expectLater(
        weather.refresh(),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            'Location Unavailable',
          ),
        ),
      );
      expect(
        (await store.records('farm')).single['data']['name'],
        'Not mapped yet',
      );
    },
  );
  test(
    'a failed weather request can retry after one minute, not fifteen',
    () async {
      final id = await store.save('farm', {
        'name': 'Retry farm',
        'points': square(0),
      });
      var requests = 0;
      final client = MockClient((_) async {
        requests++;
        if (requests == 1) throw TimeoutException('A slow test response');
        return forecast();
      });
      final service = WeatherService(
        store,
        client: client,
        connections: () async => [ConnectivityResult.wifi],
      );
      await expectLater(service.refresh(), throwsStateError);
      await expectLater(service.refresh(), throwsStateError);
      expect(requests, 1);
      final farm = (await store.records(
        'farm',
      )).firstWhere((f) => f['id'] == id);
      await store.setSetting(
        'weatherLastAttempt:v2:weather:farm:$id:${WeatherService.boundaryKey(farm)}',
        DateTime.now()
            .subtract(const Duration(minutes: 2))
            .toUtc()
            .toIso8601String(),
      );
      await service.refresh();
      expect(requests, 2);
      expect((await service.cached())!['weatherSchema'], 3);
      client.close();
    },
  );
}
