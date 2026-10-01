import 'package:flutter_test/flutter_test.dart';
import 'package:farmerplus_mobile/country_lookup.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'offline country lookup includes enclaves and rejects ocean/invalid fixes',
    () async {
      expect(await CountryLookup.at(-26.05631, 28.06936), 'South Africa');
      expect(await CountryLookup.at(-29.31, 27.48), 'Lesotho');
      expect(await CountryLookup.at(51.51, -0.12), 'United Kingdom');
      expect(await CountryLookup.at(0, -140), isNull);
      expect(await CountryLookup.at(double.nan, 28), isNull);
    },
  );
}
