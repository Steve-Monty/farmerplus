import 'dart:async';
import 'dart:math' as math;
import 'appearance.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'weather_forecast.dart';

const _muted = Color(0xffdeeee9),
    _rain = Color(0xffd0edff),
    _sun = Color(0xffffe19a),
    _night = Color(0xffd6ceff);

class WeatherDisplay extends StatefulWidget {
  final Map<String, dynamic>? cache;
  final String label, status;
  final bool detailed;
  final bool? offline;
  final DateTime? now;
  final VoidCallback? onTap, onRefresh;
  const WeatherDisplay({
    super.key,
    required this.cache,
    required this.label,
    this.status = '',
    this.detailed = false,
    this.onTap,
    this.onRefresh,
    this.offline,
    this.now,
  });
  @override
  State<WeatherDisplay> createState() => _WeatherDisplayState();
}

class _WeatherDisplayState extends State<WeatherDisplay> {
  bool offline = false;
  StreamSubscription<List<ConnectivityResult>>? connection;
  Timer? clock;
  @override
  void initState() {
    super.initState();
    if (widget.offline == null) watchConnection();
    clock = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  Future<void> watchConnection() async {
    try {
      final connectivity = Connectivity();
      connection = connectivity.onConnectivityChanged.listen(
        updateConnection,
        onError: (Object _) {},
      );
      updateConnection(await connectivity.checkConnectivity());
    } catch (_) {
      /* Cached weather remains usable without platform services. */
    }
  }

  void updateConnection(List<ConnectivityResult> values) {
    if (mounted) {
      setState(() => offline = values.contains(ConnectivityResult.none));
    }
  }

  @override
  void dispose() {
    connection?.cancel();
    clock?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final f = WeatherForecast(
      widget.cache?['forecast'] as Map? ?? {},
      now: widget.now,
    );
    final current = f.current;
    final currentTime = f.time(current?['time']);
    final oldDay =
        currentTime != null && !WeatherForecast.sameDay(currentTime, f.now);
    final updated = DateTime.tryParse(
      widget.cache?['updated'] as String? ?? '',
    );
    final stale = updated == null || f.instant.difference(updated).inHours >= 6;
    final isOffline = widget.offline ?? offline;
    final updateLabel = updated == null
        ? 'Update time unavailable'
        : 'Updated ${WeatherForecast.sameDay(f.local(updated), f.now) ? '' : '${f.date(f.local(updated))} · '}${WeatherForecast.clockOf(f.local(updated))}';
    final savedLabel = isOffline
        ? 'Offline · saved forecast'
        : stale || oldDay
        ? 'Saved forecast'
        : '';
    final noData = widget.status.isEmpty
        ? 'Location Unavailable'
        : widget.status;
    final summary = _CompactToday(
      f: f,
      label: widget.label,
      detailed: widget.detailed,
      oldDay: oldDay,
      noData: noData,
      onTap: widget.onTap,
      onRefresh: widget.onRefresh,
      updateLabel: updateLabel,
      savedLabel: savedLabel,
      status: widget.status,
    );
    if (!widget.detailed) return summary;
    final slots = f.slots, days = f.days;
    final scope =
        '${widget.cache?['farmId'] ?? 'current'}:${widget.cache?['latitude']}:${widget.cache?['longitude']}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        summary,
        if (slots.isNotEmpty) ...[
          const SizedBox(height: 12),
          _ForecastStrip(
            key: ValueKey('periods-$scope'),
            storageKey: 'periods-$scope',
            title: 'By time of day',
            subtitle: '3-hourly · 3 days · wind in km/h',
            count: slots.length,
            itemBuilder: (_, i) => _SlotCard(f: f, index: slots[i]),
          ),
        ],
        if (days.isNotEmpty) ...[
          const SizedBox(height: 12),
          _ForecastStrip(
            key: ValueKey('days-$scope'),
            storageKey: 'days-$scope',
            title: 'Daily forecast',
            subtitle: days.length < 14
                ? '${days.length} saved days · dates shown'
                : '14 days · later days are less certain',
            count: days.length,
            itemBuilder: (_, i) => _DayCard(f: f, index: days[i]),
          ),
        ],
        if (current != null && slots.isEmpty && days.isEmpty)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'Forecast details are not saved yet. Connect to update.',
            ),
          ),
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                f.zone.name == 'UTC'
                    ? 'Times shown in UTC'
                    : 'Times at this location',
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              TextButton(
                onPressed: () =>
                    launchUrl(Uri.parse('https://open-meteo.com/')),
                child: const Text(
                  'Open-Meteo · CC BY 4.0',
                  style: TextStyle(fontSize: 11),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class WeatherSymbol extends StatelessWidget {
  final dynamic code;
  final bool isDay;
  final double size;
  const WeatherSymbol({
    super.key,
    required this.code,
    this.isDay = true,
    this.size = 48,
  });
  @override
  Widget build(BuildContext context) {
    final c = code;
    final rain = [
      51,
      53,
      55,
      56,
      57,
      61,
      63,
      65,
      66,
      67,
      80,
      81,
      82,
    ].contains(c);
    final snow = [71, 73, 75, 77, 85, 86].contains(c);
    final storm = [95, 96, 99].contains(c);
    Widget icon(IconData i, double factor, Color color) =>
        Icon(i, size: size * factor, color: color);
    return Semantics(
      label: weatherName(c),
      child: ExcludeSemantics(
        child: SizedBox(
          width: size,
          height: size,
          child: c == 1 || c == 2 || rain || storm
              ? Stack(
                  children: [
                    if (c == 1 || c == 2)
                      Positioned(
                        top: 0,
                        right: 0,
                        child: icon(
                          isDay
                              ? Icons.wb_sunny_rounded
                              : Icons.nightlight_round,
                          .66,
                          isDay ? _sun : _night,
                        ),
                      ),
                    Positioned(
                      top: size * .18,
                      left: 0,
                      child: icon(
                        Icons.cloud_rounded,
                        .88,
                        const Color(0xffeff6f4),
                      ),
                    ),
                    if (rain || storm)
                      Positioned(
                        right: size * .12,
                        bottom: 0,
                        child: icon(
                          storm ? Icons.bolt_rounded : Icons.water_drop_rounded,
                          .46,
                          storm ? _sun : _rain,
                        ),
                      ),
                  ],
                )
              : Center(
                  child: icon(
                    c == 0
                        ? (isDay
                              ? Icons.wb_sunny_rounded
                              : Icons.nightlight_round)
                        : snow
                        ? Icons.ac_unit_rounded
                        : c == 45 || c == 48
                        ? Icons.foggy
                        : c == 3
                        ? Icons.cloud_rounded
                        : Icons.cloud_outlined,
                    .9,
                    c == 0
                        ? (isDay ? _sun : _night)
                        : snow
                        ? _rain
                        : const Color(0xffeff6f4),
                  ),
                ),
        ),
      ),
    );
  }
}

class _ForecastStrip extends StatefulWidget {
  final String title, subtitle, storageKey;
  final int count;
  final IndexedWidgetBuilder itemBuilder;
  const _ForecastStrip({
    super.key,
    required this.title,
    required this.subtitle,
    required this.storageKey,
    required this.count,
    required this.itemBuilder,
  });
  @override
  State<_ForecastStrip> createState() => _ForecastStripState();
}

class _ForecastStripState extends State<_ForecastStrip> {
  PageController? controller;
  double fraction = 0;
  @override
  void dispose() {
    controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LiquidGlass(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                widget.title,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const Icon(Icons.chevron_right_rounded, color: _muted, size: 20),
          ],
        ),
        const SizedBox(height: 5),
        Text(
          widget.subtitle,
          style: const TextStyle(fontSize: 12, color: _muted),
        ),
        const SizedBox(height: 18),
        LayoutBuilder(
          builder: (context, constraints) {
            final scale = math.max(
              1.0,
              MediaQuery.textScalerOf(context).scale(14) / 14,
            );
            final next = (80 * scale / constraints.maxWidth).clamp(.18, .86);
            if (controller == null || (fraction - next).abs() > .001) {
              final page = controller?.hasClients == true
                  ? controller!.page?.round() ?? 0
                  : 0;
              controller?.dispose();
              fraction = next;
              controller = PageController(
                initialPage: page,
                viewportFraction: next,
              );
            }
            return SizedBox(
              height: 218 * scale,
              child: PageView.builder(
                key: PageStorageKey(widget.storageKey),
                controller: controller,
                padEnds: false,
                itemCount: widget.count,
                itemBuilder: (context, i) => Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Padding(
                    padding: const EdgeInsets.only(top: 2, bottom: 2),
                    child: widget.itemBuilder(context, i),
                  ),
                ),
              ),
            );
          },
        ),
      ],
    ),
  );
}

Widget _line(String value, {Color color = Colors.white, double size = 12}) =>
    Text(
      value,
      textAlign: TextAlign.center,
      style: TextStyle(fontSize: size, color: color),
    );

class _CompactToday extends StatelessWidget {
  final WeatherForecast f;
  final String label, noData, updateLabel, savedLabel, status;
  final bool detailed, oldDay;
  final VoidCallback? onTap, onRefresh;
  const _CompactToday({
    required this.f,
    required this.label,
    required this.detailed,
    required this.oldDay,
    required this.noData,
    required this.updateLabel,
    required this.savedLabel,
    required this.status,
    this.onTap,
    this.onRefresh,
  });
  @override
  Widget build(BuildContext context) {
    final current = f.current;
    final large = MediaQuery.textScalerOf(context).scale(14) > 18;
    final location = label
        .replaceFirst('Weather at ', '')
        .replaceFirst('Weather here', 'Your location');
    final description = current == null
        ? noData
        : weatherName(current['weather_code']);
    final temperature = Text(
      '${weatherNumber(current?['temperature_2m'])}°',
      style: TextStyle(
        fontSize: large ? 36 : 48,
        height: 1,
        fontWeight: FontWeight.w400,
        letterSpacing: -1.5,
      ),
    );
    final conditions = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          description,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
        ),
        if (current != null) ...[
          const SizedBox(height: 5),
          Wrap(
            spacing: 9,
            runSpacing: 3,
            children: [
              Text(
                'High ${weatherNumber(f.today('temperature_2m_max'))}°',
                style: const TextStyle(fontSize: 11, color: _sun),
              ),
              Text(
                'Low ${weatherNumber(f.today('temperature_2m_min'))}°',
                style: const TextStyle(fontSize: 11, color: _rain),
              ),
            ],
          ),
          if (detailed) ...[
            const SizedBox(height: 4),
            Text(
              'Feels like ${weatherNumber(current['apparent_temperature'])}°',
              style: const TextStyle(fontSize: 11, color: _muted),
            ),
          ],
        ],
      ],
    );
    return LiquidGlass(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                oldDay ? 'Saved' : 'Today',
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  location,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11, color: _muted),
                ),
              ),
              if (detailed && onRefresh != null)
                IconButton(
                  onPressed: onRefresh,
                  tooltip: 'Refresh weather',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(
                    Icons.refresh_rounded,
                    color: _muted,
                    size: 20,
                  ),
                ),
              if (onTap != null)
                const Icon(
                  Icons.chevron_right_rounded,
                  size: 20,
                  color: _muted,
                ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              WeatherSymbol(
                code: current?['weather_code'],
                isDay: current?['is_day'] != 0,
                size: large ? 36 : 44,
              ),
              const SizedBox(width: 8),
              temperature,
              const SizedBox(width: 12),
              Expanded(child: conditions),
            ],
          ),
          if (current != null) ...[
            const SizedBox(height: 13),
            Wrap(
              spacing: 16,
              runSpacing: 8,
              children: [
                _InlineMetric(
                  icon: Icons.water_drop_outlined,
                  label: 'Rain chance',
                  value:
                      '${weatherNumber(f.today('precipitation_probability_max'))}%',
                ),
                _InlineMetric(
                  icon: Icons.air_rounded,
                  label: 'Wind',
                  value:
                      '${weatherWind(current['wind_direction_10m'])} ${weatherNumber(current['wind_speed_10m'])} km/h',
                ),
              ],
            ),
            if (detailed) ...[
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 11),
                child: Divider(height: 1, color: Color(0x33ffffff)),
              ),
              Wrap(
                spacing: 18,
                runSpacing: 10,
                children: [
                  _InlineMetric(
                    icon: Icons.grain_rounded,
                    label: 'Rain today',
                    value: '${weatherAmount(f.today('precipitation_sum'))} mm',
                    showLabel: true,
                  ),
                  _InlineMetric(
                    icon: Icons.waves_rounded,
                    label: 'Humidity',
                    value: '${weatherNumber(current['relative_humidity_2m'])}%',
                    showLabel: true,
                  ),
                  _InlineMetric(
                    icon: Icons.air_rounded,
                    label: 'Gusts',
                    value: '${weatherNumber(current['wind_gusts_10m'])} km/h',
                    showLabel: true,
                  ),
                ],
              ),
              const SizedBox(height: 11),
              Wrap(
                spacing: 18,
                runSpacing: 6,
                children: [
                  _InlineMetric(
                    icon: Icons.wb_twilight_rounded,
                    label: 'Sunrise',
                    value: f.clock(f.today('sunrise')),
                    showLabel: true,
                  ),
                  _InlineMetric(
                    icon: Icons.nights_stay_outlined,
                    label: 'Sunset',
                    value: f.clock(f.today('sunset')),
                    showLabel: true,
                  ),
                ],
              ),
            ],
            const SizedBox(height: 10),
            Text(
              [if (savedLabel.isNotEmpty) savedLabel, updateLabel].join(' · '),
              style: TextStyle(
                fontSize: 10,
                color: savedLabel.isEmpty ? _muted : _sun,
              ),
            ),
          ],
          if (status.isNotEmpty && current != null)
            Padding(
              padding: const EdgeInsets.only(top: 5),
              child: Text(
                status,
                style: const TextStyle(fontSize: 11, color: _sun),
              ),
            ),
        ],
      ),
    );
  }
}

class _InlineMetric extends StatelessWidget {
  final IconData icon;
  final String label, value;
  final bool showLabel;
  const _InlineMetric({
    required this.icon,
    required this.label,
    required this.value,
    this.showLabel = false,
  });
  @override
  Widget build(BuildContext context) => Semantics(
    label: '$label $value',
    child: ExcludeSemantics(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: _rain),
          const SizedBox(width: 5),
          if (showLabel) ...[
            Text(label, style: const TextStyle(fontSize: 10, color: _muted)),
            const SizedBox(width: 4),
          ],
          Text(
            value,
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w500),
          ),
        ],
      ),
    ),
  );
}

class _SlotCard extends StatelessWidget {
  final WeatherForecast f;
  final int index;
  const _SlotCard({required this.f, required this.index});
  @override
  Widget build(BuildContext context) {
    dynamic v(String key) => f.at('hourly', key, index);
    final date = f.time(v('time'))!;
    return Column(
      children: [
        _line(WeatherForecast.clockOf(date), size: 13),
        const SizedBox(height: 3),
        _line('${f.day(date)} ${f.date(date)}', color: _muted, size: 9),
        const SizedBox(height: 10),
        WeatherSymbol(
          code: v('weather_code'),
          isDay: v('is_day') != 0,
          size: 34,
        ),
        const SizedBox(height: 7),
        _line('${weatherNumber(v('temperature_2m'))}°', size: 24),
        const SizedBox(height: 8),
        _forecastMetric(
          Icons.water_drop_outlined,
          '${weatherNumber(v('precipitation_probability'))}%',
          'Rain chance',
          _rain,
        ),
        const SizedBox(height: 4),
        _line(
          '${weatherAmount(v('precipitation'))} mm/h',
          color: _rain,
          size: 10,
        ),
        const SizedBox(height: 8),
        _forecastMetric(
          Icons.air_rounded,
          weatherNumber(v('wind_speed_10m')),
          'Wind km/h',
          _muted,
        ),
        const SizedBox(height: 4),
        _line(
          'Gust ${weatherNumber(v('wind_gusts_10m'))}',
          color: _muted,
          size: 9,
        ),
      ],
    );
  }
}

Widget _forecastMetric(
  IconData icon,
  String value,
  String label,
  Color colour,
) => Semantics(
  label: '$label $value',
  child: ExcludeSemantics(
    child: Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(icon, size: 12, color: colour),
        const SizedBox(width: 4),
        Text(value, style: TextStyle(fontSize: 12, color: colour)),
      ],
    ),
  ),
);

class _DayCard extends StatelessWidget {
  final WeatherForecast f;
  final int index;
  const _DayCard({required this.f, required this.index});
  @override
  Widget build(BuildContext context) {
    dynamic v(String key) => f.at('daily', key, index);
    final date = f.time(v('time'))!;
    final sunshine = v('sunshine_duration');
    return Column(
      children: [
        _line(f.day(date), size: 12),
        const SizedBox(height: 3),
        _line(f.date(date), color: _muted, size: 9),
        const SizedBox(height: 10),
        WeatherSymbol(code: v('weather_code'), size: 34),
        const SizedBox(height: 7),
        _line(
          '${weatherNumber(v('temperature_2m_max'))}°',
          color: _sun,
          size: 24,
        ),
        const SizedBox(height: 2),
        _line(
          'Low ${weatherNumber(v('temperature_2m_min'))}°',
          color: _rain,
          size: 12,
        ),
        const SizedBox(height: 8),
        _forecastMetric(
          Icons.water_drop_outlined,
          '${weatherNumber(v('precipitation_probability_max'))}%',
          'Rain chance',
          _rain,
        ),
        const SizedBox(height: 4),
        _line(
          '${weatherAmount(v('precipitation_sum'))} mm',
          color: _rain,
          size: 10,
        ),
        const SizedBox(height: 8),
        _forecastMetric(
          Icons.wb_sunny_outlined,
          '${weatherAmount(sunshine is num ? sunshine / 3600 : null)} h',
          'Sunshine',
          _muted,
        ),
        const SizedBox(height: 4),
        _line(
          'Gust ${weatherNumber(v('wind_gusts_10m_max'))}',
          color: _muted,
          size: 9,
        ),
      ],
    );
  }
}
