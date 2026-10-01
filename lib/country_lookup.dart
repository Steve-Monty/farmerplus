import 'dart:convert';
import 'package:flutter/services.dart';

/// Country labels from bundled Natural Earth boundaries, available offline.
/// Generalised borders are contextual labels, not legal or survey boundaries.
class CountryLookup {
  static Future<List<dynamic>>? _countries;

  static Future<String?> at(double lat, double lon) async {
    if (!lat.isFinite || !lon.isFinite || lat.abs() > 90 || lon.abs() > 180) {
      return null;
    }
    final countries = await (_countries ??= rootBundle
        .loadString('assets/countries.json')
        .then((text) => jsonDecode(text) as List<dynamic>));
    for (final country in countries) {
      for (final polygon in country['polygons']) {
        final bounds = polygon['bounds'];
        if (lon < bounds[0] ||
            lat < bounds[1] ||
            lon > bounds[2] ||
            lat > bounds[3])
          continue;
        final rings = polygon['rings'] as List;
        if (_inside(lat, lon, rings.first) &&
            !rings.skip(1).any((ring) => _inside(lat, lon, ring))) {
          return country['name'] as String;
        }
      }
    }
    return null;
  }

  static bool _inside(double lat, double lon, List ring) {
    var inside = false;
    for (var i = 0, j = ring.length - 1; i < ring.length; j = i++) {
      final a = ring[i], b = ring[j];
      if ((a[1] > lat) != (b[1] > lat) &&
          lon < (b[0] - a[0]) * (lat - a[1]) / (b[1] - a[1]) + a[0]) {
        inside = !inside;
      }
    }
    return inside;
  }
}
