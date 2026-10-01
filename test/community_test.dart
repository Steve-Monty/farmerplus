import 'package:flutter_test/flutter_test.dart';
import 'package:farmerplus_mobile/community.dart';
import 'package:farmerplus_mobile/domain.dart';
import 'package:farmerplus_mobile/taxonomy.dart';
import 'package:farmerplus_mobile/weather_forecast.dart';

void main() {
  test('only a bounded FarmerPlus QR invitation is accepted', () {
    expect(validCoopCode('farmerplus:coop:v1:demo-avocado-tarlton'), isTrue);
    for(final value in ['Best Scanner', 'https://evil.test', 'farmerplus:coop:v1:../x', 'farmerplus:coop:v1:']) {
      expect(validCoopCode(value), isFalse);
    }
  });
  test('Coop is removable without owning or deleting farm records', () {
    expect(catalogue.where((a)=>a.id=='coop').length, 1);
    expect(protectedApps.contains('coop'), isFalse);
    expect(appOwnedKinds['coop'], isEmpty);
    expect(catalogue.last.id, 'learning');
    expect(sharingNames.length, 5);
  });
  test('daily forecast caps real provider data at 14 without inventing days', () {
    final now=DateTime.utc(2026,9,16);
    for(final length in [7,14,16]) {
      final forecast=WeatherForecast({'daily':{'time':List.generate(length,(i)=>now.add(Duration(days:i)).toIso8601String())}},now:now);
      expect(forecast.days.length, length>14?14:length);
    }
  });
}
