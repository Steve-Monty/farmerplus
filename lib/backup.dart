import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:sqflite/sqflite.dart';
import 'store.dart';
import 'area_units.dart';
import 'farm_context.dart' show areaSnapshot;
import 'domain.dart';
import 'ui.dart';

Map<String, dynamic> geoJson(List<Map<String, dynamic>> rows) => {
  'type': 'FeatureCollection',
  'features': [
    for (final r in rows.where(
      (r) =>
          {'farm', 'field'}.contains(r['kind']) &&
          polygonPoints(r['data']).length >= 3,
    ))
      {
        'type': 'Feature',
        'properties': {
          'id': r['id'],
          'kind': r['kind'],
          for (final e in (r['data'] as Map).entries)
            if (e.key != 'points') e.key: e.value,
        },
        'geometry': {
          'type': 'Polygon',
          'coordinates': [
            [
              ...polygonPoints(r['data']).map((p) => [p.lon, p.lat]),
              [
                polygonPoints(r['data']).first.lon,
                polygonPoints(r['data']).first.lat,
              ],
            ],
          ],
        },
      },
  ],
};

Future<bool> exportFarmFile({
  required Map<String, dynamic> farm,
  required List<Map<String, dynamic>> fields,
  required String format,
  required bool precise,
  String areaUnit = 'ha',
}) async {
  final unit = AreaUnit.parse(areaUnit);
  final data = Map<String, dynamic>.from(farm['data'] as Map);
  final farmPoints = polygonPoints(data);
  final included = [farm, ...fields];
  final date = DateTime.now().toIso8601String().substring(0, 10);
  final safeName = (data['name'] ?? 'farm')
      .toString()
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-|-$'), '');
  Uint8List bytes;
  String extension;
  if (format == 'geojson') {
    dynamic output;
    if (precise) {
      output = geoJson(included);
    } else {
      final centre = farmPoints.isEmpty
          ? null
          : {
              'lat': double.parse(
                (farmPoints.map((p) => p.lat).reduce((a, b) => a + b) /
                        farmPoints.length)
                    .toStringAsFixed(2),
              ),
              'lon': double.parse(
                (farmPoints.map((p) => p.lon).reduce((a, b) => a + b) /
                        farmPoints.length)
                    .toStringAsFixed(2),
              ),
            };
      output = {
        'type': 'FeatureCollection',
        'privacy': 'summary-only',
        'features': [
          {
            'type': 'Feature',
            'properties': {
              'name': data['name'],
              'productionCategory': data['productionCategory'],
              'areaM2': data['areaM2'] ?? area(farmPoints),
              'fieldCount': fields.length,
              'approximateCentre': centre,
            },
            'geometry': null,
          },
        ],
      };
    }
    bytes = Uint8List.fromList(
      utf8.encode(const JsonEncoder.withIndent('  ').convert(output)),
    );
    extension = 'geojson';
  } else {
    final document = pw.Document();
    document.addPage(
      pw.MultiPage(
        build: (_) => [
          pw.Text(
            data['name']?.toString() ?? 'Farm boundary report',
            style: pw.TextStyle(fontSize: 22, fontWeight: pw.FontWeight.bold),
          ),
          pw.SizedBox(height: 8),
          pw.Text('FarmerPlus farm boundary report · $date'),
          pw.SizedBox(height: 18),
          pw.Text(
            'Privacy: ${precise ? 'Precise coordinates included' : 'Summary only; coordinates omitted'}',
          ),
          pw.SizedBox(height: 12),
          pw.Text(
            'Main production: ${data['productionCategory'] ?? 'Not recorded'}',
          ),
          pw.Text(
            'Farm area: ${unit.format(areaSnapshot(farm)['areaM2'])} · ${areaSnapshot(farm)['source']}',
          ),
          pw.Text(
            'Perimeter: ${((data['perimeterM'] ?? perimeter(farmPoints)) as num).toDouble().toStringAsFixed(0)} m',
          ),
          pw.Text('Fields: ${fields.length}'),
          if (fields.isNotEmpty) ...[
            pw.SizedBox(height: 16),
            pw.Text(
              'Fields',
              style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
            ),
            for (final field in fields)
              pw.Text(
                '• ${field['data']['name'] ?? 'Field'} · ${unit.format(areaSnapshot(field)['areaM2'])} · ${areaSnapshot(field)['source']}',
              ),
          ],
          if (precise && farmPoints.isNotEmpty) ...[
            pw.SizedBox(height: 16),
            pw.Text(
              'Farm boundary coordinates',
              style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
            ),
            pw.TableHelper.fromTextArray(
              headers: const ['Point', 'Latitude', 'Longitude'],
              data: [
                for (var i = 0; i < farmPoints.length; i++)
                  [
                    '${i + 1}',
                    farmPoints[i].lat.toStringAsFixed(7),
                    farmPoints[i].lon.toStringAsFixed(7),
                  ],
              ],
            ),
          ],
          pw.SizedBox(height: 18),
          pw.Text('Measurements are estimates and are not a cadastral survey.'),
        ],
      ),
    );
    bytes = await document.save();
    extension = 'pdf';
  }
  final result = await FilePicker.platform.saveFile(
    dialogTitle: 'Export farm boundary',
    fileName:
        'farmerplus-${safeName.isEmpty ? 'farm' : safeName}-$date.$extension',
    bytes: bytes,
  );
  return result != null || kIsWeb;
}

List<Map<String, dynamic>> parseGeoJson(dynamic value) {
  if (value is! Map ||
      value['type'] != 'FeatureCollection' ||
      value['features'] is! List ||
      value['features'].isEmpty ||
      value['features'].length > 100) {
    throw StateError(
      'Choose a GeoJSON FeatureCollection with 1–100 farm or field polygons.',
    );
  }
  final rows = <Map<String, dynamic>>[];
  final ids = <String, String>{};
  for (final f in value['features']) {
    if (f is! Map ||
        f['geometry'] is! Map ||
        f['geometry']['type'] != 'Polygon' ||
        f['geometry']['coordinates'] is! List ||
        f['geometry']['coordinates'].length != 1) {
      throw StateError('Only single polygons without holes can be imported.');
    }
    if (f['properties'] != null &&
        (f['properties'] is! Map ||
            (f['properties'] as Map).keys.any((key) => key is! String))) {
      throw StateError('Polygon properties must be named values.');
    }
    final props = Map<String, dynamic>.from(f['properties'] ?? {});
    for (final key in [
      'id',
      'name',
      'farmId',
      'productionCategory',
      'productionSubcategory',
      'productionOther',
      'areaType',
      'areaTypeOther',
    ]) {
      if (props[key] != null &&
          (props[key] is! String || (props[key] as String).length > 200)) {
        throw StateError(
          'Polygon property $key must be text of at most 200 characters.',
        );
      }
    }
    props.removeWhere(
      (key, value) => !{
        'id',
        'kind',
        'name',
        'farmId',
        'productionCategory',
        'productionSubcategory',
        'productionOther',
        'areaType',
        'areaTypeOther',
      }.contains(key),
    );
    final kind = props['kind'] ?? 'farm';
    if (!{'farm', 'field'}.contains(kind)) {
      throw StateError('Each polygon must be a farm or field.');
    }
    final ring = f['geometry']['coordinates'][0];
    if (ring is! List || ring.length < 4 || ring.length > 1001) {
      throw StateError(
        'A polygon needs 3–1000 vertices and a closing coordinate.',
      );
    }
    if (ring.any(
      (p) =>
          p is! List || p.length != 2 || p.any((v) => v is! num || !v.isFinite),
    )) {
      throw StateError('Use finite longitude, latitude pairs.');
    }
    if (ring.first[0] != ring.last[0] || ring.first[1] != ring.last[1]) {
      throw StateError('Close each polygon by repeating its first coordinate.');
    }
    final points = [
      for (final p in ring.take(ring.length - 1))
        GeoPoint((p[1] as num).toDouble(), (p[0] as num).toDouble()),
    ];
    final issue = validatePolygon(points);
    if (issue != null) throw StateError(issue);
    final sourceId = (props.remove('id') ?? 'feature-${rows.length}')
        .toString();
    if (ids.containsKey(sourceId)) {
      throw StateError('Polygon identifiers must be unique in the file.');
    }
    final id = uuid.v4();
    ids[sourceId] = id;
    props.remove('kind');
    rows.add({
      'id': id,
      'kind': kind,
      'data': {
        'name': 'Imported ${kind == 'farm' ? 'farm' : 'field'}',
        if (kind == 'farm') ...{
          'productionCategory': 'Other',
          'productionSubcategory': 'Other',
          'productionOther': 'Imported polygon',
        },
        if (kind == 'field') 'areaType': 'Other',
        ...props,
        'points': points.map((p) => p.toJson()).toList(),
        'areaM2': area(points),
        'perimeterM': perimeter(points),
      },
    });
  }
  for (final r in rows.where((r) => r['kind'] == 'field')) {
    final mapped = ids[r['data']['farmId']];
    if (mapped == null ||
        !rows.any((f) => f['id'] == mapped && f['kind'] == 'farm')) {
      throw StateError(
        'Include each field’s parent farm in the same file, linked by properties.farmId and properties.id.',
      );
    }
    r['data']['farmId'] = mapped;
    final parent = rows.firstWhere((f) => f['id'] == mapped);
    final issue = validateContainment(
      polygonPoints(parent['data']),
      polygonPoints(r['data']),
    );
    if (issue != null) throw StateError(issue);
  }
  rows.sort(
    (a, b) =>
        (a['kind'] == 'farm' ? 0 : 1).compareTo(b['kind'] == 'farm' ? 0 : 1),
  );
  return rows;
}

Future<void> importPolygons(
  FarmStore store,
  List<Map<String, dynamic>> rows,
) async {
  await store.db.transaction((tx) async {
    for (final r in rows) {
      if ((await tx.query(
        'records',
        where: 'id=?',
        whereArgs: [r['id']],
      )).isNotEmpty) {
        throw StateError('This import has already been saved.');
      }
      await store.validateGeometry(tx, r['id'], r['kind'], r['data'], false);
      await tx.insert('records', {
        'id': r['id'],
        'kind': r['kind'],
        'data': jsonEncode(r['data']),
        'version': 0,
        'deleted': 0,
        'updated': DateTime.now().toUtc().toIso8601String(),
      }, conflictAlgorithm: ConflictAlgorithm.abort);
      await tx.insert('queue', {
        'id': r['id'],
        'op_id': uuid.v4(),
        'kind': r['kind'],
        'data': jsonEncode(r['data']),
        'base_version': 0,
        'deleted': 0,
      });
    }
  });
  await store.setSetting(
    'lastImport',
    DateTime.now().toUtc().toIso8601String(),
  );
}

class BackupPage extends StatefulWidget {
  final FarmStore store;
  const BackupPage({super.key, required this.store});
  @override
  State<BackupPage> createState() => _BackupState();
}

class _BackupState extends State<BackupPage> {
  String last = 'Never', message = '';
  bool busy = false;
  List<Map<String, dynamic>>? preview;
  @override
  void initState() {
    super.initState();
    widget.store.setting('lastBackup').then((v) {
      if (mounted) setState(() => last = stamp(v));
    });
  }

  Future<void> export(bool polygons) async {
    final rows = (await widget.store.db.query(
      'records',
      where: 'deleted=0',
    )).map(widget.store.decode).toList();
    dynamic data;
    if (polygons) {
      data = geoJson(rows);
    } else {
      final hashes = <String>{};
      final drafts = {
        for (final r in await widget.store.db.query('settings'))
          if (RegExp(
            r'^(entryDraft:|farmDetailsDraft:|boundaryDraft:|appDraft:)',
          ).hasMatch(r['key'] as String))
            r['key'] as String: jsonDecode(r['value'] as String),
      };
      for (final m in RegExp(
        r'[a-f0-9]{64}',
      ).allMatches(jsonEncode([rows, drafts]))) {
        hashes.add(m.group(0)!);
      }
      final attachments = <String, String>{};
      final unavailable = <String>[];
      var bytes = 0;
      for (final h in hashes) {
        final content = await widget.store.mediaBytes(h);
        if (content == null) {
          unavailable.add(h);
          continue;
        }
        bytes += content.length;
        if (bytes > 50 * 1024 * 1024) {
          throw StateError(
            'Attachments exceed 50 MB. Export polygons now; copy the device data folder for a full backup.',
          );
        }
        attachments[h] = base64Encode(content);
      }
      data = {
        'format': 'farmerplus-backup',
        'version': 1,
        'created': DateTime.now().toUtc().toIso8601String(),
        'owner': await widget.store.setting('boundOwner'),
        'records': rows,
        'drafts': drafts,
        'attachments': attachments,
        'unavailableAttachments': unavailable,
        'excludes': [
          'passwords',
          'sessions',
          'recovery codes',
          'wallet keys',
          'official Moodle records',
          'downloaded course packages',
        ],
      };
    }
    final saved = await FilePicker.platform.saveFile(
      dialogTitle: polygons ? 'Export boundaries' : 'Save backup',
      fileName:
          'farmerplus-${DateTime.now().toIso8601String().substring(0, 10)}.${polygons ? 'geojson' : 'json'}',
      bytes: Uint8List.fromList(
        utf8.encode(const JsonEncoder.withIndent('  ').convert(data)),
      ),
    );
    if (saved != null || kIsWeb) {
      if (!polygons) {
        await widget.store.setSetting(
          'lastBackup',
          DateTime.now().toUtc().toIso8601String(),
        );
      }
      if (mounted) {
        setState(() {
          last = polygons ? last : stamp(DateTime.now().toIso8601String());
          message = kIsWeb
              ? 'Download requested. Check your browser downloads and keep the file private.'
              : polygons
              ? 'Boundaries exported.'
              : 'Backup saved. Keep this private file in a safe place.';
        });
      }
    }
  }

  Future<void> pick() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['geojson', 'json'],
      withData: true,
    );
    if (result == null) return;
    final file = result.files.single;
    if (file.size > 2 * 1024 * 1024) {
      throw StateError('Choose a boundary file below 2 MB.');
    }
    final parsed = parseGeoJson(jsonDecode(utf8.decode(file.bytes!)));
    if (mounted) setState(() => preview = parsed);
  }

  @override
  Widget build(BuildContext c) => PageFrame(
    'Backup & boundaries',
    children: [
      Text(
        'Keep a copy of your records.',
        style: Theme.of(c).textTheme.headlineMedium,
      ),
      note(
        'Last backup: $last. Backups contain private farm records and available attachments. Learning results remain in Moodle.',
      ),
      FilledButton.icon(
        onPressed: () => guarded(c, () => export(false)),
        icon: const Icon(Icons.download_outlined),
        label: const Text('Export record backup'),
      ),
      note(
        'This version exports a readable backup for recovery support. It does not automatically restore a whole account.',
      ),
      OutlinedButton.icon(
        onPressed: () => guarded(c, () => export(true)),
        icon: const Icon(Icons.map_outlined),
        label: const Text('Export farm and field GeoJSON'),
      ),
      OutlinedButton.icon(
        onPressed: () => guarded(c, pick),
        icon: const Icon(Icons.upload_file_outlined),
        label: const Text('Import GeoJSON boundaries'),
      ),
      if (message.isNotEmpty) note(message),
      if (preview != null) ...[
        heading(c, 'Review ${preview!.length} new boundaries'),
        note(
          'Import creates new farms and fields. Existing boundaries stay as they are. Check names and production details in My Farm after import.',
        ),
        for (final r in preview!)
          ListTile(
            title: Text(r['data']['name']),
            subtitle: AreaText(
              store: widget.store,
              squareMetres: r['data']['areaM2'],
              prefix: '${r['kind']} · ',
              source: 'Mapped',
            ),
          ),
        FilledButton(
          onPressed: busy
              ? null
              : () => guarded(c, () async {
                  setState(() => busy = true);
                  try {
                    await importPolygons(widget.store, preview!);
                    if (mounted) {
                      setState(() {
                        preview = null;
                        message =
                            'Boundaries imported and saved on this device.';
                      });
                    }
                  } finally {
                    if (mounted) setState(() => busy = false);
                  }
                }),
          child: const Text('Save these boundaries'),
        ),
        TextButton(
          onPressed: () => setState(() => preview = null),
          child: const Text('Cancel import'),
        ),
      ],
    ],
  );
}
