import 'package:flutter/material.dart';
import 'store.dart';

enum AreaUnit {
  hectare('ha', 'Hectares', 'ha', 10000),
  acre('ac', 'Acres', 'ac', 4046.8564224),
  squareMetre('m2', 'Square metres', 'm²', 1),
  squareKilometre('km2', 'Square kilometres', 'km²', 1000000);

  const AreaUnit(this.id, this.label, this.symbol, this.squareMetres);
  final String id, label, symbol;
  final double squareMetres;
  static AreaUnit parse(dynamic id) =>
      values.firstWhere((u) => u.id == id, orElse: () => hectare);
  double fromM2(num value) => value / squareMetres;
  double toM2(num value) => value * squareMetres;
  String format(num? m2) {
    if (m2 == null || !m2.isFinite) return 'Area not recorded';
    final value = fromM2(m2);
    final digits = value == 0 || value >= 100
        ? 0
        : value >= 1
        ? 2
        : 3;
    return '${value > 0 && value < .001 ? '<0.001' : value.toStringAsFixed(digits)} $symbol';
  }
}

/// The preference changes presentation only; stored geometry stays in metres.
class AreaText extends StatefulWidget {
  final FarmStore store;
  final num? squareMetres;
  final String? source;
  final String prefix, suffix;
  final TextStyle? style;
  const AreaText({
    super.key,
    required this.store,
    required this.squareMetres,
    this.source,
    this.prefix = '',
    this.suffix = '',
    this.style,
  });
  @override
  State<AreaText> createState() => _AreaTextState();
}

class _AreaTextState extends State<AreaText> {
  AreaUnit unit = AreaUnit.hectare;
  @override
  void initState() {
    super.initState();
    widget.store.addListener(load);
    load();
  }

  Future<void> load() async {
    final value = AreaUnit.parse(await widget.store.setting('areaUnit'));
    if (mounted && value != unit) setState(() => unit = value);
  }

  @override
  void dispose() {
    widget.store.removeListener(load);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Text(
    '${widget.prefix}${unit.format(widget.squareMetres)}${widget.source == null || widget.source == 'Not recorded' ? '' : ' · ${widget.source}'}${widget.suffix}',
    style: widget.style,
  );
}
