import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

/// Presentation values stay in the forecast location's time zone, including DST.
class WeatherForecast {
  final Map data;
  final DateTime instant;
  static bool _zonesReady = false;
  late final tz.Location zone;
  WeatherForecast(this.data, {DateTime? now})
    : instant = (now ?? DateTime.now()).toUtc() {
    if (!_zonesReady) {
      tzdata.initializeTimeZones();
      _zonesReady = true;
    }
    try {
      zone = tz.getLocation(data['timezone'] as String? ?? 'UTC');
    } catch (_) {
      zone = tz.UTC;
    }
  }
  DateTime get now => tz.TZDateTime.from(instant, zone);
  DateTime? time(dynamic value) {
    if (value is num) {
      return tz.TZDateTime.fromMillisecondsSinceEpoch(
        zone,
        (value * 1000).round(),
      );
    }
    if (value is! String) return null;
    final parsed = DateTime.tryParse(value);
    if (parsed == null) return null;
    if (parsed.isUtc) return tz.TZDateTime.from(parsed, zone);
    // Older caches used UTC ISO strings; timezone is UTC in those responses.
    return tz.TZDateTime(
      zone,
      parsed.year,
      parsed.month,
      parsed.day,
      parsed.hour,
      parsed.minute,
      parsed.second,
    );
  }

  DateTime local(DateTime value) => tz.TZDateTime.from(value, zone);
  static bool sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;
  String date(DateTime value) => '${value.day}/${value.month}';
  String day(DateTime value) {
    if (sameDay(value, now)) return 'Today';
    final tomorrow = tz.TZDateTime(zone, now.year, now.month, now.day + 1);
    if (sameDay(value, tomorrow)) return 'Tomorrow';
    return const [
      'Mon',
      'Tue',
      'Wed',
      'Thu',
      'Fri',
      'Sat',
      'Sun',
    ][value.weekday - 1];
  }

  String clock(dynamic value) {
    final t = time(value);
    return t == null ? '—' : clockOf(t);
  }

  static String clockOf(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  dynamic at(String section, String key, int i) {
    final values = data[section]?[key];
    return values is List && i >= 0 && i < values.length ? values[i] : null;
  }

  Map? get current => data['current'] as Map?;
  int? get todayIndex {
    final times = data['daily']?['time'];
    if (times is! List) return null;
    for (var i = 0; i < times.length; i++) {
      final t = time(times[i]);
      if (t != null && sameDay(t, now)) return i;
    }
    return null;
  }

  dynamic today(String key) =>
      todayIndex == null ? null : at('daily', key, todayIndex!);

  /// Three-hour samples give 24 forecasts over the next 72 hours.
  List<int> get slots {
    final times = data['hourly']?['time'];
    if (times is! List) return [];
    final start = instant.subtract(
      Duration(
        minutes: instant.minute,
        seconds: instant.second,
        milliseconds: instant.millisecond,
        microseconds: instant.microsecond,
      ),
    );
    final end = start.add(const Duration(hours: 72));
    final all = List.generate(times.length, (i) => i).where((i) {
      final t = time(times[i]);
      return t != null && t.hour % 3 == 0;
    }).toList();
    final upcoming = all.where((i) {
      final t = time(times[i])!;
      return !t.isBefore(start) && t.isBefore(end);
    }).toList();
    return (upcoming.isEmpty ? all : upcoming).take(24).toList();
  }

  List<int> get days {
    final times = data['daily']?['time'];
    if (times is! List) return [];
    final all = List.generate(
      times.length,
      (i) => i,
    ).where((i) => time(times[i]) != null).toList();
    final future = all.where((i) {
      final t = time(times[i])!;
      return sameDay(t, now) || t.isAfter(now);
    }).toList();
    return (future.isEmpty ? all : future).take(14).toList();
  }

  List<WeatherPeriod> get periods {
    final times = data['hourly']?['time'];
    if (times is! List) return [];
    final start = instant.subtract(
      Duration(
        minutes: instant.minute,
        seconds: instant.second,
        milliseconds: instant.millisecond,
        microseconds: instant.microsecond,
      ),
    );
    final end = start.add(const Duration(hours: 48));
    var indices = List.generate(times.length, (i) => i).where((i) {
      final t = time(times[i]);
      return t != null && !t.isBefore(start) && t.isBefore(end);
    }).toList();
    // Expired caches remain inspectable, with explicit dates and saved status.
    if (indices.isEmpty) {
      indices = List.generate(
        times.length,
        (i) => i,
      ).where((i) => time(times[i]) != null).take(48).toList();
    }
    final groups = <String, List<int>>{};
    for (final i in indices) {
      final t = time(times[i])!;
      final key = '${t.year}-${t.month}-${t.day}-${t.hour ~/ 6}';
      groups.putIfAbsent(key, () => []).add(i);
    }
    return groups.values.map((hours) => WeatherPeriod(this, hours)).toList();
  }
}

class WeatherPeriod {
  final WeatherForecast forecast;
  final List<int> hours;
  WeatherPeriod(this.forecast, this.hours);
  DateTime get start =>
      forecast.time(forecast.at('hourly', 'time', hours.first))!;
  String get name =>
      const ['Night', 'Morning', 'Afternoon', 'Evening'][start.hour ~/ 6];
  List<num> values(String key) =>
      hours.map((i) => forecast.at('hourly', key, i)).whereType<num>().toList();
  num? max(String key) =>
      values(key).isEmpty ? null : values(key).reduce((a, b) => a > b ? a : b);
  num? min(String key) =>
      values(key).isEmpty ? null : values(key).reduce((a, b) => a < b ? a : b);
  // Never substitute zero for a missing accumulation.
  num? get rain => values('precipitation').length != hours.length
      ? null
      : values('precipitation').fold<num>(0, (a, b) => a + b);
  num? get code {
    final codes = values('weather_code');
    if (codes.isEmpty) return null;
    return codes.reduce(
      (a, b) => weatherSeverity(a) >= weatherSeverity(b) ? a : b,
    );
  }

  bool get isDay => values('is_day').isEmpty
      ? start.hour >= 6 && start.hour < 18
      : values('is_day').any((v) => v == 1);
}

int weatherSeverity(num code) {
  if (code >= 95) return 9;
  if ([56, 57, 66, 67].contains(code)) return 8;
  if ([71, 73, 75, 77, 85, 86].contains(code)) return 7;
  if (code >= 61) return 6;
  if (code >= 51) return 5;
  if (code >= 45) return 4;
  return code.toInt().clamp(0, 3);
}

String weatherNumber(dynamic n) =>
    n is num && n.isFinite ? n.round().toString() : '—';
String weatherAmount(dynamic n) => n is num && n.isFinite
    ? (n == n.round() ? n.round().toString() : n.toStringAsFixed(1))
    : '—';
String weatherWind(dynamic degrees) => degrees is num && degrees.isFinite
    ? const [
        'N',
        'NE',
        'E',
        'SE',
        'S',
        'SW',
        'W',
        'NW',
      ][(degrees / 45).round() % 8]
    : '—';
String weatherName(dynamic code) {
  if (code == 0) return 'Clear skies';
  if (code == 1 || code == 2) return 'Partly cloudy';
  if (code == 3) return 'Cloudy';
  if (code == 45 || code == 48) return 'Fog';
  if ([71, 73, 75, 77, 85, 86].contains(code)) return 'Snow';
  if ([95, 96, 99].contains(code)) return 'Thunderstorms';
  if ([56, 57, 66, 67].contains(code)) return 'Freezing rain';
  if ([51, 53, 55].contains(code)) return 'Drizzle';
  if ([61, 63, 65, 80, 81, 82].contains(code)) return 'Rain';
  return 'Conditions unavailable';
}
