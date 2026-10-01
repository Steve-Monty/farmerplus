import 'dart:convert';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;
import 'store.dart';
import 'location.dart';
import 'domain.dart';
import 'weather_location.dart';
import 'package:crypto/crypto.dart';
import 'package:geolocator/geolocator.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

class Reminders {
  final plugin = FlutterLocalNotificationsPlugin();
  bool available = false;
  Future<void> start(void Function(String) open) async {
    tzdata.initializeTimeZones();
    await plugin.initialize(
      const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        iOS: DarwinInitializationSettings(
          requestAlertPermission: false,
          requestBadgePermission: false,
          requestSoundPermission: false,
        ),
      ),
      onDidReceiveNotificationResponse: (r) {
        if (r.payload != null) open(r.payload!);
      },
    );
    available = true;
    final launch = await plugin.getNotificationAppLaunchDetails();
    if (launch?.didNotificationLaunchApp == true &&
        launch?.notificationResponse?.payload != null) {
      open(launch!.notificationResponse!.payload!);
    }
  }

  int notificationId(String id) =>
      id.codeUnits.fold(0, (a, b) => (a * 31 + b) & 0x7fffffff);
  Future<void> cancel(String id) async {
    if (available) await plugin.cancel(notificationId(id));
  }

  Future<bool> schedule(String id, String title, DateTime at) async {
    if (!available || !at.isAfter(DateTime.now())) return false;
    final android = plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    final allowed = await android?.requestNotificationsPermission();
    if (allowed == false) return false;
    await plugin
        .resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin
        >()
        ?.requestPermissions(alert: true, badge: true, sound: true);
    await plugin.zonedSchedule(
      notificationId(id),
      title,
      'My Planner • Open your activity',
      tz.TZDateTime.from(at, tz.UTC),
      const NotificationDetails(
        android: AndroidNotificationDetails(
          'planner',
          'My Planner reminders',
          channelDescription: 'Activities you choose to be reminded about',
          importance: Importance.defaultImportance,
        ),
        iOS: DarwinNotificationDetails(),
      ),
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      payload: 'task:$id',
    );
    return true;
  }
}

class WeatherService {
  static final Map<String, Future<void>> _inFlight = {};
  final FarmStore store;
  final http.Client client;
  final Future<Position> Function() locate;
  final Future<List<ConnectivityResult>> Function() connections;
  WeatherService(
    this.store, {
    http.Client? client,
    Future<Position> Function()? locate,
    Future<List<ConnectivityResult>> Function()? connections,
  }) : client = client ?? http.Client(),
       locate = locate ?? (() => DeviceLocation.weather(store)),
       connections = connections ?? Connectivity().checkConnectivity;
  Future<Map<String, dynamic>?> selectedFarm() async {
    if (await store.setting('weatherHere') == true) return null;
    final farms = await store.records('farm');
    final selected = await store.setting('selectedFarm');
    final chosen =
        farms.where((f) => f['id'] == selected).firstOrNull ??
        farms.firstOrNull;
    return chosen != null && polygonPoints(chosen['data']).length >= 3
        ? chosen
        : null;
  }

  static String boundaryKey(Map<String, dynamic>? farm) => farm == null
      ? 'current'
      : sha256
            .convert(utf8.encode(jsonEncode(farm['data']['points'] ?? [])))
            .toString();

  static String cacheKey(Map<String, dynamic>? farm) =>
      farm == null ? 'weather:current' : 'weather:farm:${farm['id']}';

  Future<String> targetKey() async {
    final farm = await selectedFarm();
    return '${cacheKey(farm)}:${boundaryKey(farm)}';
  }

  Future<Map<String, dynamic>?> cached([String? farmId]) async {
    final farm = farmId == null
        ? await selectedFarm()
        : (await store.records(
            'farm',
          )).where((f) => f['id'] == farmId).firstOrNull;
    final value = await store.setting(cacheKey(farm));
    if (value == null ||
        (farm != null && value['boundaryKey'] != boundaryKey(farm))) {
      return null;
    }
    return Map<String, dynamic>.from(value);
  }

  Future<void> refresh([Map<String, dynamic>? farm]) async {
    if (await store.setting('weatherEnabled') != true) return;
    farm ??= await selectedFarm();
    if (await store.setting('weatherEnabled') != true) return;
    final jobKey = '${store.filesPath}:${cacheKey(farm)}:${boundaryKey(farm)}';
    final existing = _inFlight[jobKey];
    if (existing != null) return existing;
    final job = _refresh(farm);
    _inFlight[jobKey] = job;
    try {
      await job;
    } finally {
      _inFlight.remove(jobKey);
    }
  }

  Future<void> _refresh(Map<String, dynamic>? farm) async {
    if (await store.setting('weatherEnabled') != true) return;
    final key = cacheKey(farm), geometry = boundaryKey(farm);
    final throttleKey = 'weatherLastAttempt:v2:$key:$geometry';
    final last = DateTime.tryParse(await store.setting(throttleKey) ?? '');
    final saved = await store.setting(key);
    final successful = DateTime.tryParse(saved?['updated'] ?? '');
    final lastFailed =
        last != null && (successful == null || successful.isBefore(last));
    final retryDelay = lastFailed
        ? const Duration(minutes: 1)
        : const Duration(minutes: 15);
    if (last != null && DateTime.now().difference(last) < retryDelay) {
      throw StateError(
        lastFailed
            ? 'Please wait a minute before trying weather again.'
            : 'Weather refreshes at most every 15 minutes. Your saved forecast is still available.',
      );
    }
    GeoPoint? point;
    Position? position;
    String source;
    if (farm != null) {
      if (farm['geometryIssue'] != null) {
        throw StateError('Location Unavailable');
      }
      final saved = await store.setting('weatherPoint:${farm['id']}');
      if (saved != null && saved['boundaryKey'] == geometry) {
        point = GeoPoint.fromJson(Map<String, dynamic>.from(saved));
      } else if (farm['geometryIssue'] == null) {
        point = farmWeatherPoint(polygonPoints(farm['data']));
        if (point != null) {
          await store.setSetting('weatherPoint:${farm['id']}', {
            ...point.toJson(),
            'boundaryKey': geometry,
          });
        }
      }
      if (point == null) throw StateError('Location Unavailable');
      source = 'Farm boundary';
    } else {
      try {
        position = await locate();
        if (await store.setting('weatherEnabled') != true) return;
        point = GeoPoint(position.latitude, position.longitude);
        // Reverse geocoding cannot delay the forecast or make it fail.
        unawaited(
          DeviceLocation.country(
            store,
            position: position,
          ).then<void>((_) {}, onError: (Object _, StackTrace __) {}),
        );
      } catch (_) {
        throw StateError('Location Unavailable');
      }
      source = 'Device location';
    }
    final networks = await connections();
    if (await store.setting('weatherEnabled') != true) return;
    if (networks.contains(ConnectivityResult.none)) {
      throw StateError(
        'Offline • Showing saved weather, if available. Connect to update.',
      );
    }
    await store.setSetting(
      throttleKey,
      DateTime.now().toUtc().toIso8601String(),
    );
    final uri = Uri.https('api.open-meteo.com', '/v1/forecast', {
      'latitude': point.lat.toStringAsFixed(4),
      'longitude': point.lon.toStringAsFixed(4),
      'current':
          'temperature_2m,apparent_temperature,relative_humidity_2m,precipitation,weather_code,wind_speed_10m,wind_direction_10m,wind_gusts_10m,is_day',
      'hourly':
          'temperature_2m,weather_code,precipitation_probability,precipitation,wind_speed_10m,wind_direction_10m,wind_gusts_10m,is_day',
      'daily':
          'weather_code,temperature_2m_max,temperature_2m_min,sunrise,sunset,precipitation_sum,precipitation_probability_max,wind_gusts_10m_max,sunshine_duration',
      'forecast_days': '14',
      'timezone': 'auto',
      'timeformat': 'unixtime',
    });
    try {
      final r = await client.get(uri).timeout(const Duration(seconds: 30));
      if (await store.setting('weatherEnabled') != true) return;
      if (r.statusCode != 200) {
        throw StateError(
          'Weather service is unavailable. Saved weather has not changed.',
        );
      }
      final data = jsonDecode(r.body) as Map<String, dynamic>;
      if (data['current']?['temperature_2m'] is! num ||
          data['current_units'] is! Map ||
          data['hourly']?['time'] is! List ||
          data['hourly_units'] is! Map ||
          [
            'temperature_2m',
            'precipitation_probability',
            'precipitation',
            'wind_speed_10m',
          ].any(
            (key) =>
                data['hourly'][key] is! List ||
                (data['hourly'][key] as List).length !=
                    (data['hourly']['time'] as List).length,
          )) {
        throw StateError(
          'Weather response is incomplete. Saved weather has not changed.',
        );
      }
      if (await store.setting('weatherEnabled') != true) return;
      await store.setSetting(key, {
        'updated': DateTime.now().toUtc().toIso8601String(),
        'weatherSchema': 3,
        'latitude': point.lat,
        'longitude': point.lon,
        'accuracy': position?.accuracy,
        'source': source,
        'farmId': farm?['id'],
        'farmName': farm?['data']['name'],
        'boundaryKey': geometry,
        'locationTime': position?.timestamp.toUtc().toIso8601String(),
        'forecast': data,
      });
    } on StateError {
      rethrow;
    } catch (error) {
      debugPrint('Weather update failed (${error.runtimeType})');
      throw StateError(
        error is TimeoutException
            ? 'Weather is taking longer than usual. Your saved forecast is available; try again in a minute.'
            : 'Weather could not update. Check your connection; saved weather remains available.',
      );
    }
  }
}
