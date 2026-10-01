import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'domain.dart';
import 'farm.dart';
import 'store.dart';
import 'ui.dart';
import 'place_colors.dart';

const placeTypes = [
  'Gate',
  'Water point',
  'Borehole',
  'Building',
  'Equipment',
  'Livestock handling',
  'Soil sample',
  'Problem',
  'Other',
];

class RecordSyncStatus extends StatefulWidget {
  final FarmStore store;
  final Map<String, dynamic> record;
  const RecordSyncStatus({
    super.key,
    required this.store,
    required this.record,
  });
  @override
  State<RecordSyncStatus> createState() => _RecordSyncStatusState();
}

class _RecordSyncStatusState extends State<RecordSyncStatus> {
  String label = 'Saved on phone';
  @override
  void initState() {
    super.initState();
    widget.store.addListener(load);
    load();
  }

  @override
  void didUpdateWidget(covariant RecordSyncStatus oldWidget) {
    super.didUpdateWidget(oldWidget);
    load();
  }

  @override
  void dispose() {
    widget.store.removeListener(load);
    super.dispose();
  }

  Future<void> load() async {
    final id = widget.record['id'];
    final conflicts = await widget.store.db.query(
      'conflicts',
      where: 'id=?',
      whereArgs: [id],
    );
    final pending = await widget.store.db.query(
      'queue',
      where: 'id=?',
      whereArgs: [id],
    );
    final row = await widget.store.get(id);
    final issues = await widget.store.setting('syncIssues');
    final next =
        conflicts.isNotEmpty || (issues is Map && issues.containsKey(id))
        ? 'Needs attention'
        : pending.isNotEmpty
        ? 'Waiting to sync'
        : (row?['version'] as num? ?? 0) > 0
        ? 'Synced'
        : 'Saved on phone';
    if (mounted && label != next) setState(() => label = next);
  }

  @override
  Widget build(BuildContext context) => Tooltip(
    message: label,
    child: Semantics(
      label: label,
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            label == 'Synced'
                ? Icons.cloud_done_outlined
                : label == 'Needs attention'
                ? Icons.error_outline
                : Icons.cloud_upload_outlined,
            size: 18,
          ),
          const SizedBox(width: 6),
          Text(label, style: Theme.of(context).textTheme.labelSmall),
        ],
      ),
    ),
  );
}

class FarmPlaces extends StatefulWidget {
  final FarmStore store;
  final Map<String, dynamic> farm;
  const FarmPlaces({super.key, required this.store, required this.farm});
  @override
  State<FarmPlaces> createState() => _FarmPlacesState();
}

class _FarmPlacesState extends State<FarmPlaces> {
  List<Map<String, dynamic>> places = [];
  Map<String, String> colors = {};
  @override
  void initState() {
    super.initState();
    widget.store.addListener(load);
    load();
  }

  @override
  void didUpdateWidget(covariant FarmPlaces oldWidget) {
    super.didUpdateWidget(oldWidget);
    load();
  }

  @override
  void dispose() {
    widget.store.removeListener(load);
    super.dispose();
  }

  Future<void> load() async {
    final farmId = widget.farm['id'];
    final allPins = await widget.store.records('pin');
    final rows = allPins.where((r) => r['data']['farmId'] == farmId).toList();
    if (mounted && widget.farm['id'] == farmId) {
      setState(() {
        places = rows;
        colors = resolvePlaceColors(allPins);
      });
    }
  }

  void edit([Map<String, dynamic>? record]) => openPage(
    context,
    PlaceEditor(store: widget.store, farm: widget.farm, record: record),
  );
  @override
  Widget build(BuildContext c) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      heading(c, 'Places'),
      if (places.isEmpty)
        const Padding(
          padding: EdgeInsets.only(bottom: 16),
          child: Text(
            'Mark gates, water points, buildings and other places on your farm.',
          ),
        ),
      for (final p in places)
        Card(
          child: ListTile(
            leading: Icon(
              Icons.place,
              color: Color(
                int.parse('ff${colors[p['id']]!.substring(1)}', radix: 16),
              ),
            ),
            title: Text(p['data']['name'] ?? 'Place'),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(p['data']['type'] ?? 'Place'),
                const SizedBox(height: 6),
                RecordSyncStatus(store: widget.store, record: p),
              ],
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => edit(p),
          ),
        ),
      FilledButton.icon(
        onPressed: () => edit(),
        icon: const Icon(Icons.add_location_alt_outlined),
        label: const Text('Add a place'),
      ),
    ],
  );
}

class PlaceEditor extends StatefulWidget {
  final FarmStore store;
  final Map<String, dynamic> farm;
  final Map<String, dynamic>? record;
  const PlaceEditor({
    super.key,
    required this.store,
    required this.farm,
    this.record,
  });
  @override
  State<PlaceEditor> createState() => _PlaceEditorState();
}

class _PlaceEditorState extends State<PlaceEditor> {
  final name = TextEditingController(),
      notes = TextEditingController(),
      lat = TextEditingController(),
      lon = TextEditingController();
  String type = 'Gate';
  late final String placeId = widget.record?['id'] ?? uuid.v4();
  String color = placePalette.first;
  GeoPoint? point;
  Map<String, dynamic>? fix;
  bool ready = false, saving = false;
  String? error;
  String get draftKey =>
      'placeDraft:${widget.farm['id']}:${widget.record?['id'] ?? 'new'}';
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    final draft = await widget.store.setting(draftKey);
    final data = draft ?? widget.record?['data'] ?? <String, dynamic>{};
    final savedFix = await widget.store.setting('lastGpsFix');
    final others = (await widget.store.records(
      'pin',
    )).where((r) => r['id'] != placeId).toList();
    color = validPlaceColor(data['color'])
        ? data['color']
        : unusedPlaceColor(placeId, resolvePlaceColors(others).values.toSet());
    name.text = data['name'] ?? '';
    notes.text = data['notes'] ?? '';
    type = data['type'] ?? 'Gate';
    if (data['lat'] is num && data['lon'] is num) {
      point = GeoPoint(
        (data['lat'] as num).toDouble(),
        (data['lon'] as num).toDouble(),
      );
      lat.text = point!.lat.toString();
      lon.text = point!.lon.toString();
    }
    if (mounted) {
      setState(() {
        fix = savedFix;
        ready = true;
      });
    }
  }

  Map<String, dynamic> data() => {
    ...?widget.record?['data'],
    'farmId': widget.farm['id'],
    'fieldId': null,
    'color': color,
    'name': name.text.trim(),
    'type': type,
    'notes': notes.text.trim(),
    'lat': point?.lat,
    'lon': point?.lon,
  };
  Future<void> draft() => widget.store.setSetting(draftKey, data());
  void pick(GeoPoint p) {
    setState(() {
      point = p;
      lat.text = p.lat.toStringAsFixed(7);
      lon.text = p.lon.toStringAsFixed(7);
    });
    draft();
  }

  Future<void> locate() async {
    await guarded(context, () async {
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        throw StateError(
          'Allow location access or tap the map to place your pin.',
        );
      }
      final p = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.best,
          timeLimit: Duration(seconds: 20),
        ),
      );
      if (!mounted) return;
      setState(() => fix = {'lat': p.latitude, 'lon': p.longitude});
      pick(GeoPoint(p.latitude, p.longitude));
    });
  }

  Future<void> save() async {
    if (name.text.trim().isEmpty || point == null) {
      setState(() => error = 'Enter a place name and choose its location.');
      return;
    }
    setState(() {
      saving = true;
      error = null;
    });
    try {
      await widget.store.save('pin', data(), id: placeId);
      await widget.store.setSetting(draftKey, null);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        setState(() => error = e.toString().replaceFirst('Bad state: ', ''));
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  void dispose() {
    name.dispose();
    notes.dispose();
    lat.dispose();
    lon.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext c) => PageFrame(
    widget.record == null ? 'Add a place' : 'Edit place',
    children: [
      Text(
        'On ${widget.farm['data']['name']}',
        style: Theme.of(c).textTheme.titleMedium,
      ),
      gap(16),
      if (!ready)
        const LinearProgressIndicator()
      else ...[
        TextField(
          controller: name,
          maxLength: 160,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(labelText: 'Place name'),
          onChanged: (_) => draft(),
        ),
        gap(),
        DropdownButtonFormField<String>(
          initialValue: type,
          decoration: const InputDecoration(labelText: 'Place type'),
          items: {
            ...placeTypes,
            type,
          }.map((t) => DropdownMenuItem(value: t, child: Text(t))).toList(),
          onChanged: (v) {
            if (v != null) {
              setState(() => type = v);
              draft();
            }
          },
        ),
        gap(16),
        FarmOverviewMap(
          farms: [widget.farm],
          fields: const [],
          lastFix: point == null ? fix : {'lat': point!.lat, 'lon': point!.lon},
          store: widget.store,
          onPick: pick,
          selectedPlace: point,
          selectedPlaceColor: color,
        ),
        TextButton.icon(
          onPressed: locate,
          icon: const Icon(Icons.my_location),
          label: const Text('Use my location'),
        ),
        Text(
          point == null
              ? 'Tap the map to position the pin.'
              : 'Pin selected. Tap the map to move it.',
        ),
        ExpansionTile(
          title: const Text('Coordinates'),
          children: [
            TextField(
              controller: lat,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
                signed: true,
              ),
              decoration: const InputDecoration(labelText: 'Latitude'),
            ),
            gap(),
            TextField(
              controller: lon,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
                signed: true,
              ),
              decoration: const InputDecoration(labelText: 'Longitude'),
            ),
            TextButton(
              onPressed: () {
                final a = double.tryParse(lat.text),
                    b = double.tryParse(lon.text);
                if (a == null ||
                    b == null ||
                    !a.isFinite ||
                    !b.isFinite ||
                    a.abs() > 85 ||
                    b.abs() > 180) {
                  setState(() => error = 'Enter valid latitude and longitude.');
                  return;
                }
                pick(GeoPoint(a, b));
              },
              child: const Text('Use coordinates'),
            ),
          ],
        ),
        gap(),
        TextField(
          controller: notes,
          maxLines: 3,
          decoration: const InputDecoration(labelText: 'Notes (optional)'),
          onChanged: (_) => draft(),
        ),
        gap(20),
        if (error != null)
          Text(error!, style: TextStyle(color: Theme.of(c).colorScheme.error)),
        FilledButton.icon(
          onPressed: saving ? null : save,
          icon: const Icon(Icons.check),
          label: const Text('Save place'),
        ),
        note(
          'Saved on this phone first. Sync follows your connection and sync settings.',
        ),
      ],
    ],
  );
}
