import 'package:flutter/material.dart';
import 'domain.dart';
import 'store.dart';

String seasonLocation(
  Map<String, dynamic> season,
  List<Map<String, dynamic>> fields,
) {
  final fieldId = season['data']['fieldId'];
  if (fieldId == null || fieldId == '') return 'Whole farm';
  return fields.where((r) => r['id'] == fieldId).firstOrNull?['data']['name'] ??
      'Farm area';
}

bool pointInside(GeoPoint q, List<GeoPoint> p) {
  if (p.length < 3) return false;
  var inside = false;
  for (var i = 0, j = p.length - 1; i < p.length; j = i++) {
    final a = p[i], b = p[j];
    if ((a.lat > q.lat) != (b.lat > q.lat) &&
        q.lon < (b.lon - a.lon) * (q.lat - a.lat) / (b.lat - a.lat) + a.lon) {
      inside = !inside;
    }
  }
  return inside;
}

Map<String, dynamic> areaSnapshot(Map<String, dynamic>? record) {
  if (record == null) return {'source': 'Not recorded', 'areaM2': null};
  final d = record['data'] as Map<String, dynamic>, p = polygonPoints(d);
  if (record['geometryIssue'] == null && p.length >= 3) {
    return {
      'source': 'Mapped',
      'areaM2': area(p),
      'recordId': record['id'],
      'recordVersion': record['version'] ?? 0,
    };
  }
  final entered = d['manualAreaHa'];
  if (entered is num && entered > 0) {
    return {
      'source': 'Entered manually',
      'areaM2': entered * 10000,
      'recordId': record['id'],
    };
  }
  return {'source': 'Not recorded', 'areaM2': null, 'recordId': record['id']};
}

class FarmContextPicker extends StatefulWidget {
  final FarmStore store;
  final String? farmId, areaId;
  final void Function(String?, String?) onChanged;
  const FarmContextPicker({
    super.key,
    required this.store,
    this.farmId,
    this.areaId,
    required this.onChanged,
  });
  @override
  State<FarmContextPicker> createState() => _ContextState();
}

class _ContextState extends State<FarmContextPicker> {
  List<Map<String, dynamic>> farms = [], areas = [];
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    farms = await widget.store.records('farm');
    areas = await widget.store.records('field');
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext c) {
    final scope = widget.areaId != null
        ? 'area'
        : widget.farmId != null
        ? 'farm'
        : 'general';
    final options = areas
        .where((r) => r['data']['farmId'] == widget.farmId)
        .toList();
    return Column(
      children: [
        DropdownButtonFormField<String>(
          key: ValueKey('scope:$scope'),
          initialValue: scope,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Applies to'),
          items: const [
            DropdownMenuItem(
              value: 'general',
              child: Text('General · not linked'),
            ),
            DropdownMenuItem(value: 'farm', child: Text('Whole farm')),
            DropdownMenuItem(value: 'area', child: Text('Specific farm area')),
          ],
          onChanged: (v) {
            if (v == 'general') {
              widget.onChanged(null, null);
              return;
            }
            final f = widget.farmId ?? farms.firstOrNull?['id'] as String?;
            final a =
                areas.where((r) => r['data']['farmId'] == f).firstOrNull?['id']
                    as String?;
            if (v == 'area' && a == null) {
              ScaffoldMessenger.of(c).showSnackBar(
                const SnackBar(
                  content: Text(
                    'Add an area in My Farm first. Mapping is optional.',
                  ),
                ),
              );
              return;
            }
            widget.onChanged(f, v == 'area' ? a : null);
          },
        ),
        if (widget.farmId != null) ...[
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            key: ValueKey(widget.farmId),
            initialValue: farms.any((r) => r['id'] == widget.farmId)
                ? widget.farmId
                : null,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Farm'),
            items: farms
                .map(
                  (r) => DropdownMenuItem<String>(
                    value: r['id'],
                    child: Text(r['data']['name']),
                  ),
                )
                .toList(),
            onChanged: (v) => widget.onChanged(v, null),
          ),
        ],
        if (widget.areaId != null) ...[
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            key: ValueKey(widget.areaId),
            initialValue: options.any((r) => r['id'] == widget.areaId)
                ? widget.areaId
                : null,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Farm area'),
            items: options
                .map(
                  (r) => DropdownMenuItem<String>(
                    value: r['id'],
                    child: Text(
                      '${r['data']['name']}${polygonPoints(r['data']).isEmpty ? ' · not mapped' : ''}',
                    ),
                  ),
                )
                .toList(),
            onChanged: (v) => widget.onChanged(widget.farmId, v),
          ),
        ],
      ],
    );
  }
}
