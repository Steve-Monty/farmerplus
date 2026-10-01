import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:geocoding/geocoding.dart';
import 'store.dart';
import 'country_lookup.dart';
import 'fresh_location.dart' if (dart.library.html) 'fresh_location_web.dart';

class DeviceLocation {
  static final _requests = Expando<Future<Position>>();
  // Explicit retries may ask again; automatic Home refreshes never nag.
  static Future<bool> enable(FarmStore store) async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      if (!kIsWeb) await Geolocator.openLocationSettings();
      return false;
    }
    var permission = await Geolocator.checkPermission();
    // The actual browser position request prompts once; requesting permission
    // through the web geolocator first would perform an extra position check.
    if (kIsWeb) return permission != LocationPermission.deniedForever;
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      await store.setSetting('weatherLocationRequested', true);
    }
    if (permission == LocationPermission.deniedForever) {
      if (!kIsWeb) await Geolocator.openAppSettings();
      return false;
    }
    return permission == LocationPermission.always ||
        permission == LocationPermission.whileInUse;
  }

  static Future<Position> weather([FarmStore? store]) async {
    if (store == null) return _weather(null);
    final pending = _requests[store];
    if (pending != null) return pending;
    final request = _weather(store);
    _requests[store] = request;
    try {
      return await request;
    } finally {
      _requests[store] = null;
    }
  }

  static Future<Position> _weather(FarmStore? store) async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      throw StateError('Location Unavailable');
    }
    final permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied && store != null) {
      if (await store.setting('weatherLocationRequested') == true) {
        throw StateError('Location Unavailable');
      }
      await store.setSetting('weatherLocationRequested', true);
    }
    try {
      if ({
            LocationPermission.always,
            LocationPermission.whileInUse,
          }.contains(permission) &&
          !kIsWeb) {
        final saved = await Geolocator.getLastKnownPosition().timeout(
          const Duration(seconds: 3),
        );
        if (saved != null) {
          validate(saved, maxAccuracy: 10000);
          if (store != null) await remember(store, saved);
          return saved;
        }
      }
    } catch (_) {
      // A stale or missing fix must not prevent a fresh request.
    }
    final p = await current(
      maxAccuracy: 10000,
      accuracy: LocationAccuracy.high,
    );
    if (store != null) await remember(store, p);
    return p;
  }

  static Future<void> remember(FarmStore store, Position p) =>
      store.setSetting('lastGpsFix', {
        'lat': p.latitude,
        'lon': p.longitude,
        'accuracy': p.accuracy,
        'updated': p.timestamp.toUtc().toIso8601String(),
      });

  static void validate(Position p, {double maxAccuracy = 1000}) {
    if (!p.latitude.isFinite ||
        !p.longitude.isFinite ||
        p.latitude.abs() > 90 ||
        p.longitude.abs() > 180 ||
        !p.accuracy.isFinite ||
        p.accuracy < 0) {
      throw StateError(
        'The device returned invalid location information. Retry location.',
      );
    }
    if (p.accuracy > maxAccuracy) {
      throw StateError(
        'The browser reported accuracy of ±${p.accuracy.toStringAsFixed(0)} m. '
        'This action needs ±${maxAccuracy.toStringAsFixed(0)} m or better. '
        'Enable precise device location and retry outdoors, or enter coordinates.',
      );
    }
    if (DateTime.now().difference(p.timestamp).abs() >
        const Duration(minutes: 2)) {
      throw StateError(
        'The location is more than two minutes old. Request a fresh location and check the device clock.',
      );
    }
  }

  static Future<Position> current({
    double maxAccuracy = 1000,
    LocationAccuracy accuracy = LocationAccuracy.high,
  }) async {
    if (kIsWeb) {
      final p = await freshBrowserPosition();
      validate(p, maxAccuracy: maxAccuracy);
      return p;
    }
    if (!await Geolocator.isLocationServiceEnabled()) {
      throw StateError('Location is off. Enable device location and retry.');
    }
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      throw StateError(
        'Location permission was not granted. Allow location in device or browser settings, then retry.',
      );
    }
    if (kIsWeb)
      return _bestWebFix(maxAccuracy: maxAccuracy, accuracy: accuracy);
    try {
      Position p;
      try {
        p = await Geolocator.getCurrentPosition(
          locationSettings: LocationSettings(
            accuracy: accuracy,
            timeLimit: const Duration(seconds: 15),
          ),
        ).timeout(const Duration(seconds: 16));
      } catch (_) {
        if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) rethrow;
        // Some devices cannot obtain a fused-provider fix. Try Android's GPS
        // manager directly, still with a deadline and the same validation.
        p = await Geolocator.getCurrentPosition(
          locationSettings: AndroidSettings(
            forceLocationManager: true,
            accuracy: accuracy,
            timeLimit: const Duration(seconds: 15),
          ),
        ).timeout(const Duration(seconds: 16));
      }
      validate(p, maxAccuracy: maxAccuracy);
      return p;
    } on StateError {
      rethrow;
    } catch (_) {
      throw StateError(
        'A fresh location is unavailable. Retry outdoors; GPS itself does not need internet.',
      );
    }
  }

  static Future<Position> _bestWebFix({
    required double maxAccuracy,
    required LocationAccuracy accuracy,
  }) async {
    final result = Completer<Position>();
    StreamSubscription<Position>? subscription;
    Position? best;
    late final Timer deadline;

    void finish() {
      if (result.isCompleted) return;
      final candidate = best;
      if (candidate == null) {
        result.completeError(
          StateError(
            'A fresh location is unavailable. Retry outdoors; GPS itself does not need internet.',
          ),
        );
      } else {
        result.complete(candidate);
      }
      subscription?.cancel();
    }

    deadline = Timer(const Duration(seconds: 15), finish);
    subscription =
        Geolocator.getPositionStream(
          locationSettings: LocationSettings(
            accuracy: accuracy,
            distanceFilter: 0,
          ),
        ).listen(
          (position) {
            try {
              validate(position, maxAccuracy: maxAccuracy);
            } catch (_) {
              return;
            }
            if (best == null || position.accuracy < best!.accuracy)
              best = position;
            if (position.accuracy <= 5) finish();
          },
          onError: (_) => finish(),
          onDone: finish,
          cancelOnError: false,
        );
    try {
      return await result.future;
    } finally {
      deadline.cancel();
      await subscription.cancel();
    }
  }

  static Future<String?> country(FarmStore store, {Position? position}) async {
    final p = position ?? await weather(store);
    validate(p, maxAccuracy: 10000);
    // Resolve locally before queuing the registration pin or any network call.
    final local = await CountryLookup.at(p.latitude, p.longitude);
    if (local != null || kIsWeb) {
      await store.setSetting('gpsCountry', local);
      return local;
    }
    try {
      final places = await Geocoding()
          .placemarkFromCoordinates(p.latitude, p.longitude)
          .timeout(const Duration(seconds: 15));
      final country = places.firstOrNull?.country;
      if (country == null || country.isEmpty) throw StateError('Unavailable');
      await store.setSetting('gpsCountry', country);
      return country;
    } catch (_) {
      throw StateError(
        'GPS found your location, but country lookup is unavailable. Retry when connected or continue with country unavailable.',
      );
    }
  }

  // Weather refreshes never move this pin. A verified online sign-in may update
  // the same registration record, which then uses the durable sync queue.
  static Future<String?> saveRegistration(
    FarmStore store,
    Position p, {
    bool updateExisting = false,
  }) async {
    validate(p, maxAccuracy: 10000);
    if (p.latitude.abs() > 85) return null;
    final owner = await store.setting('accessOwner');
    if (owner is! String || !owner.startsWith('farmerplus:')) return null;
    return store.appLifecycle(() async {
      if (await store.setting('accessOwner') != owner) return null;
      final registrations = (await store.records(
        'pin',
      )).where((r) => r['data']['purpose'] == 'registration').toList();
      if (registrations.isNotEmpty && !updateExisting) {
        return registrations.first['id'] as String;
      }
      final fix = {
        'name': 'Registration location',
        'lat': p.latitude,
        'lon': p.longitude,
        'accuracy': p.accuracy,
        'capturedAt': p.timestamp.toUtc().toIso8601String(),
        if (p.altitudeAccuracy.isFinite &&
            p.altitudeAccuracy > 0 &&
            p.altitude.isFinite)
          'altitude': p.altitude,
        if (p.altitudeAccuracy.isFinite && p.altitudeAccuracy > 0)
          'altitudeAccuracy': p.altitudeAccuracy,
        if (p.speed.isFinite && p.speed > 0) 'speed': p.speed,
        if (p.speed.isFinite && p.speed > 0 && p.heading.isFinite)
          'heading': p.heading,
        'source': updateExisting
            ? 'Device location — verified online sign-in'
            : 'Device location — first account-bound location',
        'purpose': 'registration',
        if (await store.setting('gpsCountry') case final String country)
          'country': country,
      };
      return store.save(
        'pin',
        fix,
        id: registrations.firstOrNull?['id'],
        settings: {'registrationLocation': fix},
      );
    });
  }

  static Future<void> registerWhenAvailable(FarmStore store) async {
    try {
      if ((await store.records(
        'pin',
      )).any((r) => r['data']['purpose'] == 'registration')) {
        return;
      }
      await saveRegistration(store, await weather(store));
    } catch (_) {
      // Permission denied or no fix must never block sign-in. Retry next login
      // or weather/profile location request, respecting the permission guard.
    }
  }
}
