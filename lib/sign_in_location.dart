import 'package:geolocator/geolocator.dart';
import 'location.dart';
import 'services.dart';
import 'store.dart';
import 'sync.dart';

class SignInLocationResult {
  final bool captured;
  final bool weatherReady;
  final bool backendSynced;
  final String? country;
  final String? error;
  const SignInLocationResult({
    required this.captured,
    required this.weatherReady,
    required this.backendSynced,
    this.country,
    this.error,
  });
}

/// Captures one fresh, account-bound fix during a verified online sign-in.
/// The ordered flow prevents weather, registration and background sync from
/// competing for the same account database.
class OnlineSignInLocation {
  static final _running = Expando<Future<SignInLocationResult>>();

  static Future<SignInLocationResult> captureAndSync(
    FarmStore store,
    SyncEngine sync, {
    Future<Position> Function()? locate,
    Future<String?> Function(Position)? resolveCountry,
    Future<void> Function(Position)? refreshWeather,
  }) {
    final current = _running[store];
    if (current != null) return current;
    final job = _captureAndSync(
      store,
      sync,
      locate: locate,
      resolveCountry: resolveCountry,
      refreshWeather: refreshWeather,
    );
    _running[store] = job;
    return job.whenComplete(() => _running[store] = null);
  }

  static Future<SignInLocationResult> _captureAndSync(
    FarmStore store,
    SyncEngine sync, {
    Future<Position> Function()? locate,
    Future<String?> Function(Position)? resolveCountry,
    Future<void> Function(Position)? refreshWeather,
  }) async {
    await store.setSetting('signInLocationStatus', 'Finding GPS location…');
    try {
      if (locate == null && !await DeviceLocation.enable(store)) {
        throw StateError('Allow location access to save your farm location.');
      }
      final position =
          await (locate ??
              () => DeviceLocation.current(
                maxAccuracy: 10000,
                accuracy: LocationAccuracy.high,
              ))();
      DeviceLocation.validate(position, maxAccuracy: 10000);
      await DeviceLocation.remember(store, position);
      await store.setSetting(
        'signInLocationCapturedAt',
        DateTime.now().toUtc().toIso8601String(),
      );
      final weatherEnabled = await store.setting('weatherEnabled') == true;
      if (weatherEnabled && await store.setting('weatherHere') == null) {
        await store.setSetting('weatherHere', true);
      }

      String? country;
      try {
        country =
            await (resolveCountry ??
                (p) => DeviceLocation.country(store, position: p))(position);
      } catch (_) {
        // A missing country label never discards the persisted GPS fix.
      }

      final registrationId = await DeviceLocation.saveRegistration(
        store,
        position,
        updateExisting: true,
      );
      await store.setSetting(
        'signInLocationStatus',
        'Location saved on this device. Sync pending.',
      );
      await store.setSetting('signInLocationError', null);
      await store.setSetting('pendingSignInLocation', false);
      var backendSynced = false;
      if (registrationId != null && sync.token != null) {
        await store.setSetting('consent', true);
        try {
          await sync.sync(
            recordIds: {
              registrationId,
              ...(await store.db.query(
                'queue',
                columns: ['id'],
                where: 'kind=?',
                whereArgs: ['preference'],
              )).map((r) => r['id'] as String),
            },
          );
        } catch (_) {
          /* Durable queue retries when the backend is reachable. */
        }
        final pending = await store.db.query(
          'queue',
          columns: ['id'],
          where: 'id=?',
          whereArgs: [registrationId],
          limit: 1,
        );
        final saved = await store.get(registrationId);
        backendSynced = pending.isEmpty && (saved?['version'] as num? ?? 0) > 0;
      }

      var weatherReady = false;
      if (weatherEnabled) {
        try {
          await (refreshWeather ??
              (p) => WeatherService(store, locate: () async => p).refresh())(
            position,
          );
          weatherReady = true;
        } catch (_) {
          weatherReady = await WeatherService(store).cached() != null;
        }
      }

      final status = backendSynced
          ? 'Location captured and synced during online sign-in.'
          : 'Location captured. Location is waiting to sync.';
      await store.setSetting('signInLocationStatus', status);
      await store.setSetting('signInLocationError', null);
      return SignInLocationResult(
        captured: true,
        weatherReady: weatherReady,
        backendSynced: backendSynced,
        country: country,
      );
    } catch (error) {
      final message = error.toString().replaceFirst('Bad state: ', '');
      final savedFix = await store.setting('lastGpsFix');
      await store.setSetting('signInLocationStatus', savedFix == null
          ? 'Location unavailable'
          : 'Could not refresh location. Your previously saved location is unchanged.');
      await store.setSetting('signInLocationError', message);
      return SignInLocationResult(
        captured: false,
        weatherReady: false,
        backendSynced: false,
        error: message,
      );
    }
  }
}
