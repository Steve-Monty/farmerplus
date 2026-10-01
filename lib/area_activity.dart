import 'package:flutter/material.dart';
import 'store.dart';
import 'area_units.dart';
import 'ui.dart';
import 'farm.dart';
import 'farm_details.dart';
import 'farm_tools.dart';
import 'farm_context.dart';
import 'farm_places.dart';
import 'map_downloads.dart';

class AreaActivityPage extends StatefulWidget {
  final FarmStore store;
  final Map<String, dynamic> record;
  const AreaActivityPage({
    super.key,
    required this.store,
    required this.record,
  });
  @override
  State<AreaActivityPage> createState() => _AreaActivityState();
}

class _AreaActivityState extends State<AreaActivityPage> {
  late Map<String, dynamic> record = widget.record;
  Map<String, dynamic>? parentFarm, lastFix;
  List<Map<String, dynamic>> seasons = [], fields = [];
  bool ready = false;
  int revision = 0;
  String get kind => record['kind'] ?? 'field';
  String get farmId => kind == 'farm' ? record['id'] : record['data']['farmId'];
  String? get areaId => kind == 'field' ? record['id'] : null;
  @override
  void initState() {
    super.initState();
    widget.store.addListener(load);
    load();
  }

  @override
  void dispose() {
    widget.store.removeListener(load);
    super.dispose();
  }

  Future<void> load() async {
    final request = ++revision;
    final saved = await widget.store.get(widget.record['id']) ?? widget.record;
    final farm = kind == 'farm' ? saved : await widget.store.get(farmId);
    final fix = await widget.store.setting('lastGpsFix');
    final areas = (await widget.store.records(
      'field',
    )).where((r) => r['data']['farmId'] == farmId).toList();
    final cropSeasons = (await widget.store.records('season'))
        .where(
          (r) =>
              r['data']['farmId'] == farmId &&
              (areaId == null || r['data']['fieldId'] == areaId),
        )
        .toList();
    if (!mounted || request != revision) return;
    setState(() {
      record = saved;
      parentFarm = farm;
      lastFix = fix;
      fields = areas;
      seasons = cropSeasons;
      ready = true;
    });
  }

  Future<void> delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Delete this ${kind == 'farm' ? 'farm' : 'area'}?'),
        content: const Text(
          'Linked records must be reassigned or removed first.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Keep'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await guarded(context, () async {
      await widget.store.save(
        kind,
        Map<String, dynamic>.from(record['data']),
        id: record['id'],
        deleted: true,
      );
      if (mounted) Navigator.pop(context);
    });
  }

  @override
  Widget build(BuildContext c) {
    final snap = areaSnapshot(record);
    final mapped = snap['source'] == 'Mapped';
    final scheme = Theme.of(c).colorScheme;
    return PageFrame(
      record['data']['name'] ?? 'Farm area',
      children: [
        if (kind == 'field' && parentFarm != null)
          TextButton.icon(
            onPressed: () => openPage(
              c,
              AreaActivityPage(store: widget.store, record: parentFarm!),
            ),
            icon: const Icon(Icons.agriculture_outlined),
            label: Text('Within ${parentFarm!['data']['name']}'),
          ),
        Text(
          record['data']['areaType'] ??
              record['data']['productionCategory'] ??
              (kind == 'farm' ? 'Farm' : 'Farm area'),
          style: Theme.of(c).textTheme.titleMedium,
        ),
        gap(12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Chip(
              avatar: Icon(
                mapped ? Icons.check_circle_outline : Icons.polyline_outlined,
                size: 18,
              ),
              label: Text(mapped ? 'Boundary mapped' : 'Boundary not mapped'),
            ),
            if (snap['areaM2'] != null)
              AreaText(
                store: widget.store,
                squareMetres: snap['areaM2'],
                source: snap['source'],
              ),
          ],
        ),
        if (!mapped)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              kind == 'field'
                  ? 'Showing the parent farm. Add a boundary to locate this area precisely.'
                  : 'Add a boundary to measure your farm.',
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
          ),
        gap(16),
        if (!ready)
          const SizedBox(
            height: 300,
            child: Center(child: CircularProgressIndicator()),
          )
        else
          FarmOverviewMap(
            farms: parentFarm == null ? [] : [parentFarm!],
            fields: kind == 'field' ? [record] : fields,
            lastFix: lastFix,
            store: widget.store,
            onArea: (row) {
              if (row['id'] != record['id']) {
                openPage(c, AreaActivityPage(store: widget.store, record: row));
              }
            },
          ),
        Wrap(
          spacing: 8,
          children: [
            TextButton.icon(
              onPressed: () => openPage(
                c,
                FarmDetailsPage(
                  store: widget.store,
                  record: record,
                  kind: kind,
                  farmId: kind == 'field' ? farmId : null,
                ),
              ),
              icon: const Icon(Icons.edit_outlined),
              label: const Text('Edit details'),
            ),
            TextButton.icon(
              onPressed: () => openPage(
                c,
                BoundaryPage(
                  store: widget.store,
                  record: record,
                  kind: kind,
                  farmId: kind == 'field' ? farmId : null,
                ),
              ),
              icon: const Icon(Icons.polyline_outlined),
              label: Text(mapped ? 'Edit boundary' : 'Map boundary'),
            ),
            TextButton.icon(
              onPressed: () => openPage(
                c,
                MapDownloadsPage(store: widget.store, farmId: farmId),
              ),
              icon: const Icon(Icons.download_outlined),
              label: const Text('Download map'),
            ),
          ],
        ),
        if (kind == 'farm') FarmPlaces(store: widget.store, farm: record),
        heading(c, 'Seasons (Crop)'),
        if (seasons.isEmpty)
          const Text(
            'No crop seasons yet. Record what is grown here without changing the area’s name.',
          ),
        for (final s in seasons)
          Card(
            child: ListTile(
              leading: const Icon(Icons.grass_outlined),
              title: Text(s['data']['name'] ?? 'Crop season'),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${s['data']['crop'] ?? ''} · ${s['data']['status']}'),
                  Text(seasonLocation(s, fields)),
                  const SizedBox(height: 6),
                  RecordSyncStatus(store: widget.store, record: s),
                ],
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => openPage(
                c,
                SeasonsPage(
                  store: widget.store,
                  farmId: farmId,
                  initialAreaId: areaId,
                ),
              ),
            ),
          ),
        OutlinedButton.icon(
          onPressed: () => openPage(
            c,
            SeasonsPage(
              store: widget.store,
              farmId: farmId,
              initialAreaId: areaId,
            ),
          ),
          icon: const Icon(Icons.calendar_month_outlined),
          label: const Text('Manage Seasons (Crop)'),
        ),
        gap(32),
        TextButton(
          onPressed: delete,
          child: Text('Delete ${kind == 'farm' ? 'farm' : 'area'}'),
        ),
      ],
    );
  }
}
