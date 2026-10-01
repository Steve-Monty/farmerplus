import 'domain.dart';

/// An area centroid, with a scan-line interior fallback for concave farms.
GeoPoint? farmWeatherPoint(List<GeoPoint> points) {
  if (validatePolygon(points) != null) return null;
  final origin = points.first;
  double crossSum = 0, x = 0, y = 0;
  for (var i = 0; i < points.length; i++) {
    final a = points[i], b = points[(i + 1) % points.length];
    final ax = a.lon - origin.lon, ay = a.lat - origin.lat;
    final bx = b.lon - origin.lon, by = b.lat - origin.lat;
    final cross = ax * by - bx * ay;
    crossSum += cross;
    x += (ax + bx) * cross;
    y += (ay + by) * cross;
  }
  if (crossSum.abs() > 1e-18) {
    final point = GeoPoint(
      origin.lat + y / (3 * crossSum),
      origin.lon + x / (3 * crossSum),
    );
    if (weatherPointInside(point, points)) return point;
  }
  final levels = points.map((p) => p.lat).toSet().toList()..sort();
  GeoPoint? best;
  double width = -1;
  for (var row = 0; row < levels.length - 1; row++) {
    final latitude = (levels[row] + levels[row + 1]) / 2;
    final intersections = <double>[];
    for (var i = 0; i < points.length; i++) {
      final a = points[i], b = points[(i + 1) % points.length];
      if ((a.lat > latitude) != (b.lat > latitude)) {
        intersections.add(
          a.lon + (latitude - a.lat) * (b.lon - a.lon) / (b.lat - a.lat),
        );
      }
    }
    intersections.sort();
    for (var i = 0; i + 1 < intersections.length; i += 2) {
      if (intersections[i + 1] - intersections[i] > width) {
        width = intersections[i + 1] - intersections[i];
        best = GeoPoint(
          latitude,
          (intersections[i + 1] + intersections[i]) / 2,
        );
      }
    }
  }
  return best;
}

bool weatherPointInside(GeoPoint q, List<GeoPoint> points) {
  var inside = false;
  for (var i = 0, j = points.length - 1; i < points.length; j = i++) {
    final a = points[i], b = points[j];
    if ((a.lat > q.lat) != (b.lat > q.lat) &&
        q.lon < (b.lon - a.lon) * (q.lat - a.lat) / (b.lat - a.lat) + a.lon) {
      inside = !inside;
    }
  }
  return inside;
}
