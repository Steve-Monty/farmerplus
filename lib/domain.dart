import 'dart:math' as math;

class GeoPoint {
  final double lat, lon;
  final double? accuracy;
  const GeoPoint(this.lat, this.lon, [this.accuracy]);
  Map<String, dynamic> toJson() => {
    'lat': lat,
    'lon': lon,
    if (accuracy != null) 'accuracy': accuracy,
  };
  factory GeoPoint.fromJson(Map<String, dynamic> m) => GeoPoint(
    (m['lat'] as num).toDouble(),
    (m['lon'] as num).toDouble(),
    (m['accuracy'] as num?)?.toDouble(),
  );
}

double radians(double n) => n * math.pi / 180;
double distance(GeoPoint a, GeoPoint b) {
  final x =
      math.pow(math.sin(radians(b.lat - a.lat) / 2), 2) +
      math.cos(radians(a.lat)) *
          math.cos(radians(b.lat)) *
          math.pow(math.sin(radians(b.lon - a.lon) / 2), 2);
  return 6371008.8 * 2 * math.asin(math.sqrt(x.clamp(0, 1)));
}

double perimeter(List<GeoPoint> p) => p.length < 2
    ? 0
    : List.generate(
        p.length,
        (i) => distance(p[i], p[(i + 1) % p.length]),
      ).fold(0, (a, b) => a + b);
double area(List<GeoPoint> p) {
  if (p.length < 3) return 0;
  double sum = 0;
  for (var i = 0; i < p.length; i++) {
    final a = p[i], b = p[(i + 1) % p.length];
    var dl = radians(b.lon - a.lon);
    if (dl > math.pi) dl -= 2 * math.pi;
    if (dl < -math.pi) dl += 2 * math.pi;
    sum += dl * (2 + math.sin(radians(a.lat)) + math.sin(radians(b.lat)));
  }
  return (sum * 6371008.8 * 6371008.8 / 2).abs();
}

/// Validate only drawn segments; the closing edge is checked on Finish.
bool boundaryBacktracks(List<GeoPoint> p, {bool closed = false}) {
  for (var i = 1; i < (closed ? p.length + 1 : p.length - 1); i++) {
    final a = p[(i - 1) % p.length],
        b = p[i % p.length],
        c = p[(i + 1) % p.length];
    final x = b.lon - a.lon,
        y = b.lat - a.lat,
        u = c.lon - b.lon,
        v = c.lat - b.lat;
    if ((x * v - y * u).abs() < 1e-16 && x * u + y * v < 0) return true;
  }
  return false;
}

String? validateOpenBoundary(List<GeoPoint> p) {
  if (p.length > 1000) return 'Use at most 1,000 boundary points.';
  if (p.any(
    (q) =>
        !q.lat.isFinite ||
        !q.lon.isFinite ||
        q.lat.abs() > 85 ||
        q.lon.abs() > 180,
  )) {
    return 'Enter valid map coordinates.';
  }
  if (boundaryBacktracks(p)) return 'An edge overlaps the previous edge.';
  double cross(GeoPoint a, GeoPoint b, GeoPoint c) =>
      (b.lon - a.lon) * (c.lat - a.lat) - (b.lat - a.lat) * (c.lon - a.lon);
  for (var i = 0; i < p.length; i++) {
    for (var j = i + 1; j < p.length; j++) {
      if (distance(p[i], p[j]) < 0.05) return 'Two points overlap.';
    }
  }
  for (var i = 0; i < p.length - 1; i++) {
    for (var j = i + 2; j < p.length - 1; j++) {
      final a = p[i], b = p[i + 1], c = p[j], d = p[j + 1];
      if (math.max(math.min(a.lon, b.lon), math.min(c.lon, d.lon)) <=
              math.min(math.max(a.lon, b.lon), math.max(c.lon, d.lon)) &&
          math.max(math.min(a.lat, b.lat), math.min(c.lat, d.lat)) <=
              math.min(math.max(a.lat, b.lat), math.max(c.lat, d.lat)) &&
          cross(a, b, c) * cross(a, b, d) <= 0 &&
          cross(c, d, a) * cross(c, d, b) <= 0) {
        return 'The boundary cannot cross itself. Move this point.';
      }
    }
  }
  return null;
}

String? validatePolygon(List<GeoPoint> p) {
  if (p.length > 1000) return 'Use at most 1,000 boundary points.';
  if (p.length < 3) return 'Add at least three boundary points.';
  if (boundaryBacktracks(p, closed: true)) return 'Boundary edges overlap.';
  if (p.any(
    (q) =>
        !q.lat.isFinite ||
        !q.lon.isFinite ||
        q.lat.abs() > 85 ||
        q.lon.abs() > 180,
  )) {
    return 'Use valid coordinates between 85° south and 85° north.';
  }
  for (var i = 0; i < p.length; i++) {
    for (var j = i + 1; j < p.length; j++) {
      if (distance(p[i], p[j]) < 0.05) {
        return 'Two points overlap. Remove or correct a point.';
      }
    }
  }
  double cross(GeoPoint a, GeoPoint b, GeoPoint c) =>
      (b.lon - a.lon) * (c.lat - a.lat) - (b.lat - a.lat) * (c.lon - a.lon);
  bool boundsOverlap(GeoPoint a, GeoPoint b, GeoPoint c, GeoPoint d) =>
      math.max(math.min(a.lon, b.lon), math.min(c.lon, d.lon)) <=
          math.min(math.max(a.lon, b.lon), math.max(c.lon, d.lon)) &&
      math.max(math.min(a.lat, b.lat), math.min(c.lat, d.lat)) <=
          math.min(math.max(a.lat, b.lat), math.max(c.lat, d.lat));
  if (p.any((q) => (q.lon - p.first.lon).abs() > 180)) {
    return 'Boundaries crossing the international date line are not supported yet.';
  }
  for (var i = 0; i < p.length; i++) {
    for (var j = i + 1; j < p.length; j++) {
      if (j == i + 1 || (i == 0 && j == p.length - 1)) continue;
      final a = p[i],
          b = p[(i + 1) % p.length],
          c = p[j],
          d = p[(j + 1) % p.length];
      if (boundsOverlap(a, b, c, d) &&
          cross(a, b, c) * cross(a, b, d) <= 0 &&
          cross(c, d, a) * cross(c, d, b) <= 0) {
        return 'The boundary crosses itself. Correct the points.';
      }
    }
  }
  if (area(p) < 1) {
    return 'The boundary must enclose at least one square metre.';
  }
  return null;
}

/// Non-blocking checks for shapes that are technically valid but deserve a
/// second look before they become the farmer's saved boundary.
List<String> boundaryReviewWarnings(
  List<GeoPoint> points, {
  required bool isFarm,
}) {
  if (points.length < 3) return const [];
  final warnings = <String>[];
  final squareMetres = area(points);
  final shortestEdge = List.generate(
    points.length,
    (i) => distance(points[i], points[(i + 1) % points.length]),
  ).reduce(math.min);
  if (shortestEdge < 2) {
    warnings.add(
      'Two neighbouring points are less than 2 metres apart. This may be an accidental duplicate.',
    );
  }
  if (squareMetres < 10) {
    warnings.add(
      'The boundary is smaller than 10 m². Check the scale and units.',
    );
  }
  if (isFarm && squareMetres > 100000 * 10000) {
    warnings.add(
      'The farm is larger than 100,000 hectares. Check for a misplaced point.',
    );
  }
  return warnings;
}

List<GeoPoint> polygonPoints(dynamic data) => (data['points'] as List? ?? [])
    .map((p) => GeoPoint.fromJson(Map<String, dynamic>.from(p)))
    .toList();

// Split every child edge at all parent intersections. Testing each interval
// catches excursions through concavities, including tangencies and shared edges.
String? validateContainment(List<GeoPoint> parent, List<GeoPoint> child) {
  final parentIssue = validatePolygon(parent);
  if (parentIssue != null) return 'Map a valid whole farm boundary first.';
  final issue = validatePolygon(child);
  if (issue != null) return issue;
  const eps = 1e-10;
  double cross(double ax, double ay, double bx, double by) => ax * by - ay * bx;
  bool inside(GeoPoint q) {
    var result = false;
    for (var i = 0; i < parent.length; i++) {
      final a = parent[i], b = parent[(i + 1) % parent.length];
      final dx = b.lon - a.lon, dy = b.lat - a.lat;
      final len = math.sqrt(dx * dx + dy * dy);
      if (cross(dx, dy, q.lon - a.lon, q.lat - a.lat).abs() <= eps * len &&
          q.lon >= math.min(a.lon, b.lon) - eps &&
          q.lon <= math.max(a.lon, b.lon) + eps &&
          q.lat >= math.min(a.lat, b.lat) - eps &&
          q.lat <= math.max(a.lat, b.lat) + eps) {
        return true;
      }
      if ((a.lat > q.lat) != (b.lat > q.lat) &&
          q.lon < (b.lon - a.lon) * (q.lat - a.lat) / (b.lat - a.lat) + a.lon) {
        result = !result;
      }
    }
    return result;
  }

  for (var i = 0; i < child.length; i++) {
    final a = child[i], b = child[(i + 1) % child.length];
    if (!inside(a)) {
      return 'Every field point must be inside or on the farm boundary.';
    }
    final dx = b.lon - a.lon, dy = b.lat - a.lat;
    final ts = <double>[0, 1];
    for (var j = 0; j < parent.length; j++) {
      final c = parent[j], d = parent[(j + 1) % parent.length];
      final ex = d.lon - c.lon, ey = d.lat - c.lat;
      final den = cross(dx, dy, ex, ey);
      if (den.abs() > 1e-20) {
        final t = cross(c.lon - a.lon, c.lat - a.lat, ex, ey) / den;
        final u = cross(c.lon - a.lon, c.lat - a.lat, dx, dy) / den;
        if (t >= 0 && t <= 1 && u >= -eps && u <= 1 + eps) ts.add(t);
      } else {
        for (final p in [c, d]) {
          final t =
              ((p.lon - a.lon) * dx + (p.lat - a.lat) * dy) /
              (dx * dx + dy * dy);
          if (t > 0 && t < 1) ts.add(t);
        }
      }
    }
    ts.sort();
    for (var j = 1; j < ts.length; j++) {
      final t = (ts[j - 1] + ts[j]) / 2;
      if (!inside(GeoPoint(a.lat + dy * t, a.lon + dx * t))) {
        return 'A field edge crosses outside the farm. Correct the points or farm boundary.';
      }
    }
  }
  return null;
}

int plantCount(double sqm, double rowMetres, double plantMetres) {
  if (!sqm.isFinite ||
      !rowMetres.isFinite ||
      !plantMetres.isFinite ||
      sqm < 0 ||
      rowMetres <= 0 ||
      plantMetres <= 0) {
    throw ArgumentError('Enter positive spacing and a non-negative area.');
  }
  return (sqm / rowMetres / plantMetres).floor();
}

class MiniManifest {
  final String id, title, description, category;
  final Set<String> read, write;
  final int version;
  final bool remote;
  const MiniManifest(
    this.id,
    this.title,
    this.description,
    this.category,
    this.read,
    this.write, {
    this.version = 1,
    this.remote = false,
  });
  bool permits(String kind, {bool writing = false}) =>
      (writing ? write : read).contains(kind);
}

const catalogue = [
  MiniManifest('my-animals', 'My Animals', 'Your animals, their locations and a clear record of what happened.', 'Records', {'farm', 'field'}, {}, remote: true),
  MiniManifest(
    'coop',
    'Coop',
    'Scan invitations and manage your cooperatives.',
    'Tools',
    {},
    {},
  ),
  MiniManifest(
    'stock',
    'Input Stock',
    'Know what is received, used and remaining.',
    'Records',
    {'farm', 'stock', 'stockmove'},
    {'stock', 'stockmove'},
  ),
  MiniManifest(
    'harvest',
    'Harvest & Sales',
    'Record harvests, buyers and actual sales.',
    'Records',
    {'farm', 'field', 'season', 'harvest', 'sale'},
    {'harvest', 'sale'},
  ),
  MiniManifest(
    'guides',
    'Farm Guides',
    'Small, searchable reference guides saved offline.',
    'Learning',
    {},
    {},
  ),
  MiniManifest(
    'diary',
    'Farm Diary',
    'Your activities, photos and voice notes.',
    'Records',
    {'field', 'diary'},
    {'diary'},
  ),
  MiniManifest(
    'calculator',
    'Farm Calculator',
    'Plant spacing, area and everyday costs.',
    'Tools',
    {'field'},
    {},
  ),
  MiniManifest(
    'planner',
    'My Planner',
    'Plan activities. Set your own reminders.',
    'Planning',
    {'field', 'task'},
    {'task'},
  ),
  MiniManifest(
    'learning',
    'Learning',
    'Your courses, downloaded lessons and progress.',
    'Learning',
    {'progress'},
    {'progress'},
  ),
];

enum PaymentState { draft, submitted, confirmed, failed }

class AssetConfiguration {
  final String network, contract, symbol, custodyProvider;
  const AssetConfiguration(
    this.network,
    this.contract,
    this.symbol,
    this.custodyProvider,
  );
  bool get valid => [
    network,
    contract,
    symbol,
    custodyProvider,
  ].every((s) => s.trim().isNotEmpty);
}

abstract class WalletProvider {
  Future<Map<String, dynamic>> verifiedBalance(AssetConfiguration asset);
  Future<Map<String, dynamic>> quote(
    AssetConfiguration asset,
    String recipient,
    String amount,
  );
  Future<String> submit(
    Map<String, dynamic> quote, {
    required bool explicitlyApproved,
  });
}

class DisconnectedWallet implements WalletProvider {
  Never unavailable() => throw StateError(
    'Wallet provider is not configured. No transaction has been submitted.',
  );
  @override
  Future<Map<String, dynamic>> verifiedBalance(
    AssetConfiguration asset,
  ) async => unavailable();
  @override
  Future<Map<String, dynamic>> quote(
    AssetConfiguration asset,
    String recipient,
    String amount,
  ) async => unavailable();
  @override
  Future<String> submit(
    Map<String, dynamic> quote, {
    required bool explicitlyApproved,
  }) async => unavailable();
}
