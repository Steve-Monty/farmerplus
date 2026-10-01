import 'package:flutter_test/flutter_test.dart';
import 'package:farmerplus_mobile/area_units.dart';

void main() {
  test('acres convert accurately and unit changes preserve area', () {
    expect(AreaUnit.acre.toM2(1), 4046.8564224);
    expect(AreaUnit.acre.fromM2(10000), closeTo(2.47105381467, 1e-10));
    for (final unit in AreaUnit.values) {
      expect(unit.toM2(unit.fromM2(17348.19283)), closeTo(17348.19283, 1e-8));
      expect(unit.format(0), startsWith('0 '));
    }
    expect(AreaUnit.parse('old-unknown'), AreaUnit.hectare);
    expect(AreaUnit.acre.format(4046.8564224), '1.00 ac');
    expect(AreaUnit.squareKilometre.format(1000000), '1.00 km²');
    expect(AreaUnit.hectare.format(.1), '<0.001 ha');
    expect(AreaUnit.hectare.format(null), 'Area not recorded');
  });
}
