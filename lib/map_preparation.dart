import 'dart:async';

Future<Map<String, dynamic>> waitForMap(
  Map<String, dynamic> job, {
  required Future<Map<String, dynamic>> Function(String) poll,
  required bool Function() cancelled,
  required void Function(String) status,
  Duration limit = const Duration(minutes: 18),
  Future<void> Function(Duration)? delay,
}) async {
  final clock = Stopwatch()..start();
  delay ??= Future<void>.delayed;
  while (true) {
    if (cancelled()) throw StateError('Map download cancelled.');
    final id = job['id'];
    if (id is! String || !RegExp(r'^[a-f0-9]{32}$').hasMatch(id)) {
      throw StateError('The map server returned an invalid preparation.');
    }
    if (job['state'] == 'ready') return job;
    if (!{'queued', 'preparing'}.contains(job['state'])) {
      throw StateError(
        job['error']?.toString() ?? 'Map preparation failed. Please retry.',
      );
    }
    if (clock.elapsed >= limit) {
      throw StateError(
        'Map preparation is taking too long. Retry to check the same map, or choose a smaller area.',
      );
    }
    status(
      '${job['state'] == 'queued' ? 'Waiting for the map server' : 'Preparing your map'} · ${clock.elapsed.inSeconds}s',
    );
    await delay(const Duration(seconds: 3));
    if (cancelled()) throw StateError('Map download cancelled.');
    job = await poll(id).timeout(
      limit - clock.elapsed > Duration.zero
          ? limit - clock.elapsed
          : const Duration(milliseconds: 1),
    );
  }
}
