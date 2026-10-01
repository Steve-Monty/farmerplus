import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:farmerplus_mobile/home_panels.dart';

void main() {
  testWidgets('idle background sync does not resize the home card', (tester) async {
    Future<void> show(bool busy) => tester.pumpWidget(MaterialApp(
      home: Scaffold(body: SyncGlass(count: 0, busy: busy,
        lastSync: '2026-09-28T09:00:00Z', onTap: () {})),
    ));
    await show(false);
    final size = tester.getSize(find.byType(SyncGlass));
    await show(true);
    expect(tester.getSize(find.byType(SyncGlass)), size);
    expect(find.text('All changes synced'), findsOneWidget);
  });
  testWidgets(
    'weather and glass status remain readable at narrow width with large text',
    (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(1.5)),
            child: Scaffold(
              body: SingleChildScrollView(
                child: Column(
                  children: [
                    WeatherDisplay(
                      cache: {
                        'forecast': {
                          'current': {
                            'temperature_2m': 18,
                            'weather_code': 95,
                            'wind_speed_10m': 10,
                            'relative_humidity_2m': 80,
                          },
                          'hourly': {
                            'time': [
                              DateTime.now()
                                  .toUtc()
                                  .add(const Duration(hours: 1))
                                  .toIso8601String()
                                  .replaceAll('Z', ''),
                            ],
                            'temperature_2m': [18],
                            'weather_code': [95],
                            'precipitation_probability': [100],
                            'wind_direction_10m': [90],
                            'wind_speed_10m': [20],
                          },
                        },
                      },
                      label: 'A long farm name in South Africa',
                      detailed: true,
                      offline: false,
                    ),
                    SyncGlass(count: 22, busy: false, onTap: () {}),
                    const ConnectionLight(online: true),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.text('Thunderstorms'), findsOneWidget);
    },
  );
}
