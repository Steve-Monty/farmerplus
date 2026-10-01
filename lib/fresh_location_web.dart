import 'dart:async';
import 'dart:html' as html;
import 'package:geolocator/geolocator.dart';

bool get desktopBrowser => !RegExp(
  r'Android|iPhone|iPad|iPod',
  caseSensitive: false,
).hasMatch(html.window.navigator.userAgent);

Future<Position>? _pending;

/// Share acquisition, never a cached fix. A browser may first report a coarse
/// network estimate and improve it after the device location provider warms up.
Future<Position> freshBrowserPosition() =>
    _pending ??= _acquire().whenComplete(() => _pending = null);

Future<Position> _acquire() async {
  final result = Completer<Position>();
  Position? best;
  html.PositionError? failure;
  StreamSubscription<html.Geoposition>? subscription;
  Timer? deadline;
  void finish() {
    if (result.isCompleted) return;
    if (best != null) {
      result.complete(best);
    } else {
      result.completeError(
        StateError(switch (failure?.code) {
          1 =>
            'Location permission was denied. Allow location for FarmerPlus in Chrome and enable device location, then retry.',
          2 =>
            'Chrome could not determine your location. Enable device location and Wi-Fi scanning, then retry or enter coordinates.',
          _ =>
            'Chrome did not provide a fresh location within 20 seconds. Enable precise device location and retry outdoors, or enter coordinates.',
        }),
      );
    }
  }

  deadline = Timer(const Duration(seconds: 20), finish);
  try {
    subscription = html.window.navigator.geolocation
        .watchPosition(
          enableHighAccuracy: true,
          maximumAge: Duration.zero,
          timeout: const Duration(seconds: 20),
        )
        .listen(
          (fix) {
            final c = fix.coords;
            if (c == null ||
                c.latitude == null ||
                c.longitude == null ||
                c.accuracy == null ||
                fix.timestamp == null)
              return;
            final p = Position(
              latitude: c.latitude!.toDouble(),
              longitude: c.longitude!.toDouble(),
              timestamp: DateTime.fromMillisecondsSinceEpoch(fix.timestamp!),
              accuracy: c.accuracy!.toDouble(),
              altitude: c.altitude?.toDouble() ?? 0,
              altitudeAccuracy: c.altitudeAccuracy?.toDouble() ?? 0,
              heading: c.heading?.toDouble() ?? 0,
              headingAccuracy: 0,
              speed: c.speed?.toDouble() ?? 0,
              speedAccuracy: 0,
            );
            if (!p.latitude.isFinite ||
                !p.longitude.isFinite ||
                p.latitude.abs() > 90 ||
                p.longitude.abs() > 180 ||
                !p.accuracy.isFinite ||
                p.accuracy < 0 ||
                DateTime.now().difference(p.timestamp).abs() >
                    const Duration(minutes: 2))
              return;
            if (best == null || p.accuracy <= best!.accuracy) best = p;
            if (p.accuracy <= 10) finish();
          },
          onError: (Object error) {
            if (error is html.PositionError) {
              failure = error;
              if (error.code == 1) finish();
            }
          },
          onDone: finish,
        );
    return await result.future;
  } finally {
    deadline.cancel();
    await subscription?.cancel();
  }
}
