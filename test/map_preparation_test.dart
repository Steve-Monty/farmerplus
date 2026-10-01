import 'package:flutter_test/flutter_test.dart';
import 'package:farmerplus_mobile/map_preparation.dart';

void main() {
  final id = 'a' * 32;
  test('queued preparation finishes and reports elapsed state', () async {
    var polls = 0;
    final states = <String>[];
    final ready = await waitForMap(
      {'id': id, 'state': 'queued'},
      poll: (_) async => {
        'id': id,
        'state': ++polls == 1 ? 'preparing' : 'ready',
      },
      cancelled: () => false,
      status: states.add,
      delay: (_) async {},
    );
    expect(ready['state'], 'ready');
    expect(states.first, contains('Waiting'));
    expect(states.last, contains('Preparing'));
  });
  test('stuck, failed and cancelled jobs cannot poll indefinitely', () async {
    Future<void> check(Map<String, dynamic> job, {bool cancel = false}) async {
      await expectLater(
        waitForMap(
          job,
          poll: (_) async => throw StateError('Must not poll'),
          cancelled: () => cancel,
          status: (_) {},
          limit: Duration.zero,
        ),
        throwsStateError,
      );
    }

    await check({'id': id, 'state': 'preparing'});
    await check({'id': id, 'state': 'failed', 'error': 'Source unavailable'});
    await check({'id': id, 'state': 'queued'}, cancel: true);
    await check({'id': '../bad', 'state': 'ready'});
  });
}
