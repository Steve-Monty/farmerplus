import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:farmerplus_mobile/weather_forecast.dart';
import 'package:farmerplus_mobile/weather_widgets.dart';

final now = DateTime.utc(2026, 9, 15, 8);
int epoch(DateTime date) => date.millisecondsSinceEpoch ~/ 1000;
Map<String, dynamic> forecastFixture() => {
  'updated': now.toIso8601String(),
  'forecast': {
    'timezone': 'Africa/Johannesburg',
    'current': {
      'time': epoch(now),
      'temperature_2m': 18,
      'apparent_temperature': 17,
      'weather_code': 2,
      'is_day': 1,
      'wind_speed_10m': 12,
      'wind_gusts_10m': 20,
      'wind_direction_10m': 90,
      'relative_humidity_2m': 70,
    },
    'hourly': {
      'time': List.generate(
        168,
        (i) => epoch(DateTime.utc(2026, 9, 14, 22).add(Duration(hours: i))),
      ),
      'temperature_2m': List.generate(168, (i) => 17 + i % 6),
      'weather_code': List.generate(168, (i) => i % 3),
      'precipitation_probability': List.filled(168, 30),
      'precipitation': List.filled(168, .2),
      'wind_speed_10m': List.filled(168, 12),
      'wind_gusts_10m': List.filled(168, 20),
      'is_day': List.generate(168, (i) => i % 24 >= 6 && i % 24 < 18 ? 1 : 0),
    },
    'daily': {
      'time': List.generate(
        7,
        (i) => epoch(DateTime.utc(2026, 9, 14, 22).add(Duration(days: i))),
      ),
      'temperature_2m_max': List.filled(7, 24),
      'temperature_2m_min': List.filled(7, 13),
      'weather_code': List.filled(7, 2),
      'precipitation_probability_max': List.filled(7, 30),
      'precipitation_sum': List.filled(7, 1.2),
      'wind_gusts_10m_max': List.filled(7, 20),
      'sunshine_duration': List.filled(7, 18000),
      'sunrise': List.generate(
        7,
        (i) => epoch(DateTime.utc(2026, 9, 15, 4).add(Duration(days: i))),
      ),
      'sunset': List.generate(
        7,
        (i) => epoch(DateTime.utc(2026, 9, 15, 16).add(Duration(days: i))),
      ),
    },
  },
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final font = FontLoader('Roboto')
      ..addFont(rootBundle.load('assets/fonts/Roboto-Regular.ttf'));
    await font.load();
  });
  test(
    '48 hours aggregate correctly in farm local time, without inflating rain probability',
    () {
      final f = WeatherForecast(forecastFixture()['forecast'], now: now);
      expect(f.now.hour, 10);
      expect(f.clock(f.today('sunrise')), '06:00');
      expect(f.periods.first.name, 'Morning');
      expect(f.periods.first.start.hour, 10);
      expect(f.periods.fold<int>(0, (a, p) => a + p.hours.length), 48);
      expect(f.periods.first.rain, closeTo(.4, .0001));
      expect(f.periods.first.max('precipitation_probability'), 30);
      expect(f.periods.first.code, 2);
      expect(f.days.length, 7);
      expect(f.slots.length, 24);
      expect(f.time(f.at('hourly', 'time', f.slots.first))!.hour, 12);
      expect(f.todayIndex, 0);
      expect(f.day(f.periods.last.start), 'Thu');
    },
  );
  test(
    'future timezone offset follows DST and negative offsets use the right date',
    () {
      final f = WeatherForecast({
        'timezone': 'America/New_York',
      }, now: DateTime.utc(2026, 11, 1, 3));
      expect(f.now.day, 31);
      expect(f.time(epoch(DateTime.utc(2026, 11, 1, 5)))!.hour, 1);
      expect(f.time(epoch(DateTime.utc(2026, 11, 1, 6)))!.hour, 1);
      expect(f.time(epoch(DateTime.utc(2026, 11, 1, 7)))!.hour, 2);
    },
  );
  test(
    'old UTC caches remain readable and missing rain is never shown as zero',
    () {
      final f = WeatherForecast({
        'hourly': {
          'time': ['2026-09-15T08:00'],
          'precipitation': [null],
          'temperature_2m': [18],
        },
      }, now: now);
      expect(f.periods.single.start.hour, 8);
      expect(f.periods.single.rain, isNull);
      expect(weatherAmount(f.periods.single.rain), '—');
      expect(f.days, isEmpty);
      expect(weatherWind(360), 'N');
    },
  );
  test(
    'an expired forecast keeps its original dates and never labels old readings Today',
    () {
      final f = WeatherForecast(
        forecastFixture()['forecast'],
        now: now.add(const Duration(days: 10)),
      );
      expect(f.todayIndex, isNull);
      expect(f.days.length, 7);
      expect(f.periods, isNotEmpty);
      expect(f.day(f.periods.first.start), 'Tue');
    },
  );

  Future<void> show(
    WidgetTester tester, {
    bool detail = true,
    double scale = 1,
    double width = 390,
    bool offline = false,
    VoidCallback? tap,
  }) async {
    tester.view.physicalSize = Size(width, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(
            size: Size(width, 2400),
            textScaler: TextScaler.linear(scale),
          ),
          child: Scaffold(
            body: SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: WeatherDisplay(
                  cache: forecastFixture(),
                  label: 'Test farm',
                  now: now,
                  detailed: detail,
                  offline: offline,
                  onTap: tap,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('Home is one tappable Today card with no forecast carousel', (
    tester,
  ) async {
    var taps = 0;
    await show(tester, detail: false, tap: () => taps++);
    expect(find.byType(PageView), findsNothing);
    expect(find.text('Today'), findsOneWidget);
    expect(tester.getSize(find.byType(WeatherDisplay)).height, lessThan(210));
    await tester.tap(find.text('Today'));
    expect(taps, 1);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'forecast rows retain independent positions through swipes and rebuilds',
    (tester) async {
      await show(tester);
      final rows = find.byType(PageView);
      expect(rows, findsNWidgets(2));
      final first = tester.widget<PageView>(rows.at(0)).controller!;
      final second = tester.widget<PageView>(rows.at(1)).controller!;
      await tester.drag(rows.at(0), const Offset(-220, 0));
      await tester.pumpAndSettle();
      final firstPage = first.page!;
      expect(firstPage, greaterThan(0));
      expect(second.page, 0);
      await tester.drag(rows.at(1), const Offset(-220, 0));
      await tester.pumpAndSettle();
      expect(second.page, greaterThan(0));
      expect(first.page, firstPage);
      final secondPage = second.page;
      await tester.pump(const Duration(minutes: 1));
      expect(first.page, firstPage);
      expect(second.page, secondPage);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    '320px and 150% text remain readable with saved offline forecast',
    (tester) async {
      await show(tester, width: 320, scale: 1.5, offline: true);
      expect(find.textContaining('Offline · saved forecast'), findsOneWidget);
      expect(find.text('Humidity'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.drag(
        find.byType(SingleChildScrollView),
        const Offset(0, -900),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
}
