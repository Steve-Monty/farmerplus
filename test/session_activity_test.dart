import 'package:flutter_test/flutter_test.dart';
import 'package:farmerplus_mobile/session_activity.dart';

void main() {
  test('activity extends the idle deadline, not total signed-in duration', () {
    final start = DateTime(2026, 9, 29);
    final clock = InactivityClock(start);
    for (var hour = 0; hour < 48; hour++) {
      for (var minute = 0; minute < 60; minute += 10) {
        expect(
          clock.touch(start.add(Duration(hours: hour, minutes: minute))),
          true,
        );
      }
    }
    expect(
      clock.expired(clock.last.add(const Duration(minutes: 29, seconds: 59))),
      false,
    );
    expect(clock.expired(clock.last.add(const Duration(minutes: 30))), true);
  });
  test('a suspended page cannot revive an already expired local session', () {
    final start = DateTime(2026, 9, 29);
    final clock = InactivityClock(start);
    expect(clock.touch(start.add(const Duration(minutes: 31))), false);
    expect(clock.last, start);
  });
}
