import 'dart:convert';
import 'dart:math' as math;
import 'farm_tools.dart';
import 'farm_details.dart';
import 'boundary_editor.dart';
export 'boundary_editor.dart' show BoundaryPage;
import 'area_activity.dart';
import 'area_units.dart';
import 'map_downloads.dart';
import 'backup.dart';
import 'farm_context.dart';
import 'farm_places.dart';
import 'place_colors.dart';
import 'location.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'domain.dart';
import 'store.dart';
import 'ui.dart';

const streetStyle = '''
{"version":8,"sources":{"openmaptiles":{"type":"vector","url":"https://tiles.openfreemap.org/planet","attribution":"OpenFreeMap · © OpenMapTiles · OpenStreetMap contributors"}},"layers":[{"id":"background","type":"background","paint":{"background-color":"#eef0e7"}},{"id":"landcover","type":"fill","source":"openmaptiles","source-layer":"landcover","paint":{"fill-color":"#dce8cf","fill-opacity":0.75}},{"id":"landuse","type":"fill","source":"openmaptiles","source-layer":"landuse","paint":{"fill-color":"#e5ead9","fill-opacity":0.6}},{"id":"water","type":"fill","source":"openmaptiles","source-layer":"water","paint":{"fill-color":"#9dcfe4"}},{"id":"buildings","type":"fill","source":"openmaptiles","source-layer":"building","minzoom":13,"paint":{"fill-color":"#c7c3b7","fill-opacity":0.8}},{"id":"roads","type":"line","source":"openmaptiles","source-layer":"transportation","paint":{"line-color":"#ffffff","line-width":["interpolate",["linear"],["zoom"],6,0.4,12,1.4,17,5]}},{"id":"boundaries","type":"line","source":"openmaptiles","source-layer":"boundary","paint":{"line-color":"#8f948d","line-width":1,"line-dasharray":[3,3]}}]}
''';
const satelliteStyle = '''
{"version":8,"sources":{"eox":{"type":"raster","tiles":["https://tiles.maps.eox.at/wmts/1.0.0/s2cloudless-2025_3857/default/g/{z}/{y}/{x}.jpg"],"tileSize":256,"minzoom":0,"maxzoom":14,"attribution":"EOxCloudless by EOX IT Services GmbH (Contains modified Copernicus Sentinel data 2025)"}},"layers":[{"id":"eox-satellite","type":"raster","source":"eox"}]}
''';
const onlineStyle = streetStyle;
const blankStyle =
    '{"version":8,"sources":{},"layers":[{"id":"background","type":"background","paint":{"background-color":"#e8eadf"}}]}';

String mapAttribution(String style, String? offlineAttribution) {
  if (style == satelliteStyle) {
    return 'EOxCloudless · EOX IT Services GmbH · modified Copernicus Sentinel data 2025';
  }
  if (style == streetStyle) {
    return 'OpenFreeMap · © OpenMapTiles · OpenStreetMap';
  }
  return offlineAttribution ?? 'Offline map · see imported source licence';
}

class FarmsPage extends StatefulWidget {
  final FarmStore store;
  const FarmsPage({super.key, required this.store});
  @override
  State<FarmsPage> createState() => _FarmsPageState();
}

class _FarmsPageState extends State<FarmsPage> {
  List<Map<String, dynamic>> farms = [], fields = [];
  String? selected;
  Map<String, dynamic>? draftFarm;
  Map<String, String> syncStates = {};
  String unit = 'ha';
  String mappingLanguage = 'en';
  Map<String, dynamic>? lastFix;
  String locationStatus = 'Finding this device’s location for farm mapping…';
  bool locating = true;
  @override
  void initState() {
    super.initState();
    widget.store.addListener(load);
    initialise();
  }

  Future<void> initialise() async {
    await load();
    if (lastFix != null) {
      if (mounted) {
        setState(() {
          locating = false;
          locationStatus = 'Sign-in GPS location ready for farm mapping.';
        });
      }
      return;
    }
    await captureLocation();
  }

  @override
  void dispose() {
    widget.store.removeListener(load);
    super.dispose();
  }

  Future<void> load() async {
    final f = await widget.store.records('farm'),
        p = await widget.store.records('field'),
        s = await widget.store.setting('selectedFarm'),
        u = await widget.store.setting('areaUnit'),
        fix = await widget.store.setting('lastGpsFix'),
        draft = await widget.store.setting('farmDetailsDraft:farm:new'),
        language = await widget.store.setting('mappingLanguage') ?? 'en';
    final queued = await widget.store.db.query('queue');
    final conflicts = await widget.store.db.query('conflicts');
    final states = <String, String>{};
    for (final farm in f) {
      final ids = <String>{farm['id'].toString()};
      ids.addAll(
        p
            .where((field) => field['data']['farmId'] == farm['id'])
            .map((field) => field['id'].toString()),
      );
      final hasConflict = conflicts.any((row) => ids.contains(row['id']));
      final hasQueue = queued.any((row) {
        if (ids.contains(row['id'])) return true;
        try {
          return jsonDecode(row['data'] as String)['farmId'] == farm['id'];
        } catch (_) {
          return false;
        }
      });
      states[farm['id'].toString()] = hasConflict
          ? 'Needs attention'
          : hasQueue
          ? 'Waiting to sync'
          : (farm['version'] as num? ?? 0) > 0
          ? 'Synced'
          : 'Saved locally';
    }
    if (mounted) {
      setState(() {
        farms = f;
        fields = p;
        selected = f.any((farm) => farm['id'] == s) ? s : f.firstOrNull?['id'];
        unit = u ?? 'ha';
        lastFix = fix;
        draftFarm = draft;
        mappingLanguage = language;
        syncStates = states;
      });
    }
  }

  Future<void> captureLocation() async {
    if (mounted) {
      setState(() {
        locating = true;
        locationStatus = 'Finding this device’s location for farm mapping…';
      });
    }
    try {
      if (!await DeviceLocation.enable(widget.store)) {
        throw StateError('Location permission was not granted.');
      }
      final position = await DeviceLocation.current(
        maxAccuracy: 10000,
        accuracy: LocationAccuracy.best,
      );
      await DeviceLocation.remember(widget.store, position);
      final fix = await widget.store.setting('lastGpsFix');
      if (mounted) {
        setState(() {
          lastFix = fix;
          locating = false;
          locationStatus = 'GPS location ready for farm mapping.';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          locating = false;
          locationStatus =
              '${e.toString().replaceFirst('Bad state: ', '')} You can still enter coordinates.';
        });
      }
    }
  }

  Future<void> add() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => FarmDetailsPage(store: widget.store)),
    );
    await load();
  }

  @override
  Widget build(BuildContext c) {
    final visibleFarms = farms.length > 1
        ? farms.where((farm) => farm['id'] == selected).toList()
        : farms;
    return PageFrame(
      'My Farm',
      children: [
        if (farms.isEmpty) ...[
          heading(c, 'Your farm starts here'),
          note('Name your farm now. Map it when you are ready.'),
        ] else
          heading(c, visibleFarms.first['data']['name']),
        FarmOverviewMap(
          farms: visibleFarms,
          fields: fields
              .where(
                (r) => visibleFarms.any((f) => f['id'] == r['data']['farmId']),
              )
              .toList(),
          lastFix: lastFix,
          store: widget.store,
          onArea: (row) =>
              openPage(c, AreaActivityPage(store: widget.store, record: row)),
        ),

        note(
          locationStatus,
          icon: locating ? Icons.location_searching : Icons.my_location,
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: locating ? null : captureLocation,
            icon: const Icon(Icons.gps_fixed),
            label: const Text('Refresh GPS location'),
          ),
        ),
        if (farms.length > 1)
          DropdownButtonFormField<String>(
            initialValue: selected,
            decoration: const InputDecoration(
              labelText: 'Farm',
              prefixIcon: Icon(Icons.agriculture_outlined),
            ),
            items: [
              for (final farm in farms)
                DropdownMenuItem(
                  value: farm['id'].toString(),
                  child: Text(farm['data']['name'] ?? 'Unnamed farm'),
                ),
            ],
            onChanged: (value) async {
              if (value == null) return;
              await widget.store.setSetting('selectedFarm', value);
              setState(() => selected = value);
            },
          ),
        if (farms.isEmpty)
          note(
            'Add a farm to start. You can name it now and map it later.',
            icon: Icons.landscape_outlined,
          ),
        for (final farm in visibleFarms) ...[
          Row(
            children: [
              Expanded(child: heading(c, farm['data']['name'])),
              Chip(
                avatar: Icon(
                  syncStates[farm['id']] == 'Needs attention'
                      ? Icons.error_outline
                      : syncStates[farm['id']] == 'Waiting to sync'
                      ? Icons.schedule
                      : syncStates[farm['id']] == 'Synced'
                      ? Icons.cloud_done_outlined
                      : Icons.phone_android,
                  size: 17,
                ),
                label: Text(syncStates[farm['id']] ?? 'Saved locally'),
              ),
            ],
          ),
          if (farm['geometryIssue'] != null)
            note(
              'Boundary needs repair: ${farm['geometryIssue']}',
              icon: Icons.error_outline,
            ),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              TextButton.icon(
                onPressed: () => openPage(
                  c,
                  FarmDetailsPage(store: widget.store, record: farm),
                ),
                icon: const Icon(Icons.edit_outlined),
                label: const Text('Edit details'),
              ),
              TextButton.icon(
                onPressed: () => openPage(
                  c,
                  BoundaryPage(store: widget.store, kind: 'farm', record: farm),
                ),
                icon: const Icon(Icons.polyline_outlined),
                label: const Text('Edit boundary'),
              ),
            ],
          ),
          ListTile(
            leading: const Icon(Icons.polyline_outlined),
            title: const Text('Whole farm boundary'),
            subtitle: Text(
              '${farm['data']['productionCategory'] ?? 'Choose production category'} · ${farmMeasurement(farm, unit)}',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => openPage(
              c,
              AreaActivityPage(store: widget.store, record: farm),
            ),
          ),
          for (final field in fields.where(
            (f) => f['data']['farmId'] == farm['id'],
          ))
            ListTile(
              leading: const Icon(Icons.crop_square),
              title: Text(field['data']['name']),
              subtitle: Text(
                field['geometryIssue'] == null
                    ? farmMeasurement(field, unit)
                    : 'Boundary needs repair: ${field['geometryIssue']}',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => openPage(
                c,
                AreaActivityPage(store: widget.store, record: field),
              ),
            ),
          OutlinedButton.icon(
            onPressed: () => openPage(
              c,
              FarmDetailsPage(
                store: widget.store,
                kind: 'field',
                farmId: farm['id'],
              ),
            ),
            icon: const Icon(Icons.add),
            label: const Text('Add area'),
          ),
          TextButton.icon(
            onPressed: () => openPage(
              c,
              SeasonsPage(store: widget.store, farmId: farm['id']),
            ),
            icon: const Icon(Icons.calendar_month_outlined),
            label: const Text('Seasons (Crop)'),
          ),
          FarmPlaces(store: widget.store, farm: farm),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: () => exportFarm(c, farm),
                icon: const Icon(Icons.ios_share_outlined),
                label: const Text('Export / share'),
              ),
            ],
          ),
          gap(16),
          const Divider(),
        ],
        gap(),
        FilledButton.icon(
          onPressed: () => guarded(c, add),
          icon: Icon(draftFarm == null ? Icons.add : Icons.play_arrow),
          label: Text(draftFarm == null ? 'Add a farm' : 'Resume farm setup'),
        ),
        if (draftFarm != null)
          note(
            'Draft saved${draftFarm?['data']?['name']?.toString().trim().isNotEmpty == true ? ': ${draftFarm!['data']['name']}' : ''}. Continue where you stopped.',
            icon: Icons.edit_note,
          ),
        gap(),
        OutlinedButton.icon(
          onPressed: () => openPage(c, MapDownloadsPage(store: widget.store)),
          icon: const Icon(Icons.storage_outlined),
          label: const Text('Offline maps & storage'),
        ),
        note(
          'Farm area includes uncultivated land and is not necessarily the sum of your areas. GPS measurements are estimates, not a cadastral survey.',
        ),
      ],
    );
  }

  Future<void> exportFarm(
    BuildContext context,
    Map<String, dynamic> farm,
  ) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const ListTile(
              title: Text('Export farm'),
              subtitle: Text('Choose what the recipient is allowed to see.'),
            ),
            ListTile(
              leading: const Icon(Icons.map_outlined),
              title: const Text('Precise GeoJSON'),
              subtitle: const Text('Exact farm and area coordinates'),
              onTap: () => Navigator.pop(c, 'geojson-precise'),
            ),
            ListTile(
              leading: const Icon(Icons.privacy_tip_outlined),
              title: const Text('Private GeoJSON summary'),
              subtitle: const Text(
                'Area and approximate location; no boundary',
              ),
              onTap: () => Navigator.pop(c, 'geojson-private'),
            ),
            ListTile(
              leading: const Icon(Icons.picture_as_pdf_outlined),
              title: const Text('PDF report'),
              subtitle: const Text(
                'Choose precise or private on the next step',
              ),
              onTap: () => Navigator.pop(c, 'pdf'),
            ),
          ],
        ),
      ),
    );
    if (choice == null || !context.mounted) return;
    var precise = choice.endsWith('precise');
    if (choice == 'pdf') {
      precise =
          await showDialog<bool>(
            context: context,
            builder: (c) => AlertDialog(
              title: const Text('PDF privacy'),
              content: const Text(
                'Exact coordinates can reveal the location and shape of the farm.',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(c, false),
                  child: const Text('Private summary'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(c, true),
                  child: const Text('Include coordinates'),
                ),
              ],
            ),
          ) ??
          false;
    }
    final saved = await exportFarmFile(
      farm: farm,
      fields: fields
          .where((field) => field['data']['farmId'] == farm['id'])
          .toList(),
      format: choice.startsWith('geojson') ? 'geojson' : 'pdf',
      precise: precise,
      areaUnit: await widget.store.setting('areaUnit') ?? 'ha',
    );
    if (saved && context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Farm export saved.')));
    }
  }
}

class FarmSetupProgress extends StatelessWidget {
  final int current;
  const FarmSetupProgress({super.key, required this.current});
  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Farm setup step $current of 4',
    child: Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (var i = 1; i <= 4; i++)
          Chip(
            avatar: Icon(
              i < current
                  ? Icons.check
                  : i == current
                  ? Icons.circle
                  : Icons.circle_outlined,
              size: 15,
            ),
            label: Text(
              const ['Details', 'Boundary', 'Areas', 'Offline'][i - 1],
            ),
            visualDensity: VisualDensity.compact,
          ),
      ],
    ),
  );
}

class FarmOverviewMap extends StatefulWidget {
  final FarmStore? store;
  final void Function(Map<String, dynamic>)? onArea;
  final List<Map<String, dynamic>> farms;
  final List<Map<String, dynamic>> fields;
  final Map<String, dynamic>? lastFix;
  final void Function(GeoPoint)? onPick;
  final GeoPoint? selectedPlace;
  final String selectedPlaceColor;
  const FarmOverviewMap({
    super.key,
    this.store,
    this.onArea,
    required this.farms,
    required this.fields,
    required this.lastFix,
    this.onPick,
    this.selectedPlace,
    this.selectedPlaceColor = '#d75418',
  });

  @override
  State<FarmOverviewMap> createState() => _FarmOverviewMapState();
}

class _FarmOverviewMapState extends State<FarmOverviewMap>
    with AutomaticKeepAliveClientMixin {
  MapLibreMapController? controller;
  List<Map<String, dynamic>> places = [];
  Map<String, String> placeColors = {};
  bool styleReady = false;
  String overviewStyle = streetStyle;
  bool loadingStyle = true, painting = false, pendingPaint = false;
  String? paintedSignature, fittedScope;
  @override
  bool get wantKeepAlive => true;
  @override
  void initState() {
    super.initState();
    widget.store?.addListener(refreshPlaces);
    loadStyle();
  }

  @override
  void dispose() {
    widget.store?.removeListener(refreshPlaces);
    super.dispose();
  }

  Future<void> refreshPlaces() async {
    final ids = widget.farms.map((r) => r['id']).toSet();
    final allPins = widget.store == null
        ? <Map<String, dynamic>>[]
        : await widget.store!.records('pin');
    final rows = allPins
        .where((r) => ids.contains(r['data']['farmId']))
        .toList();
    final colors = resolvePlaceColors(allPins);
    if (!mounted) return;
    if (jsonEncode(places) != jsonEncode(rows) ||
        jsonEncode(placeColors) != jsonEncode(colors)) {
      setState(() {
        places = rows;
        placeColors = colors;
      });
    }
    if (styleReady) await paintAndFit();
  }

  Future<void> loadStyle() async {
    try {
      final s = widget.store == null
          ? null
          : await MapPacks(widget.store!).activeStyle();
      await refreshPlaces();
      if (mounted) {
        setState(() {
          overviewStyle = s ?? streetStyle;
          loadingStyle = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => loadingStyle = false);
    }
  }

  List<GeoPoint> get farmPoints => widget.farms
      .expand((farm) => polygonPoints(farm['data']))
      .toList(growable: false);

  @override
  void didUpdateWidget(covariant FarmOverviewMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.store != widget.store) {
      oldWidget.store?.removeListener(refreshPlaces);
      widget.store?.addListener(refreshPlaces);
    }
    refreshPlaces();
  }

  Future<void> outline(
    List<GeoPoint> polygon,
    String color,
    double opacity,
  ) async {
    if (controller == null || polygon.length < 3) return;
    final ring = [
      ...polygon.map((point) => LatLng(point.lat, point.lon)),
      LatLng(polygon.first.lat, polygon.first.lon),
    ];
    await controller!.addFill(
      FillOptions(geometry: [ring], fillColor: color, fillOpacity: opacity),
    );
    await controller!.addLine(
      LineOptions(geometry: ring, lineColor: color, lineWidth: 3),
    );
  }

  Future<void> paintAndFit() async {
    final map = controller;
    if (!styleReady || map == null) return;
    if (painting) {
      pendingPaint = true;
      return;
    }
    final signature = jsonEncode([
      for (final r in [...widget.farms, ...widget.fields])
        [r['id'], r['data']['points']],
      for (final r in places) [r['id'], r['data'], placeColors[r['id']]],
      widget.lastFix?['lat'],
      widget.lastFix?['lon'],
      widget.selectedPlace?.toJson(),
    ]);
    if (signature == paintedSignature) return;
    painting = true;
    try {
      await map.clearLines();
      await map.clearFills();
      await map.clearCircles();
      for (final pin in places) {
        await map.addCircle(
          CircleOptions(
            geometry: LatLng(
              (pin['data']['lat'] as num).toDouble(),
              (pin['data']['lon'] as num).toDouble(),
            ),
            circleColor: placeColors[pin['id']],
            circleRadius: 7,
            circleStrokeColor: '#ffffff',
            circleStrokeWidth: 2,
          ),
        );
      }
      if (widget.selectedPlace case final point?) {
        await map.addCircle(
          CircleOptions(
            geometry: LatLng(point.lat, point.lon),
            circleColor: widget.selectedPlaceColor,
            circleRadius: 10,
            circleStrokeColor: '#ffffff',
            circleStrokeWidth: 3,
          ),
        );
      }
      for (final farm in widget.farms) {
        await outline(polygonPoints(farm['data']), '#1b57e7', .18);
      }
      for (final field in widget.fields) {
        await outline(polygonPoints(field['data']), '#05a981', .22);
      }
      final fix = widget.lastFix ?? places.firstOrNull?['data'];
      if (widget.lastFix != null && fix != null && widget.onPick == null) {
        await map.addCircle(
          CircleOptions(
            geometry: LatLng(
              (fix['lat'] as num).toDouble(),
              (fix['lon'] as num).toDouble(),
            ),
            circleRadius: 7,
            circleColor: '#ffffff',
            circleStrokeColor: '#1267ed',
            circleStrokeWidth: 3,
          ),
        );
      }
      final all = [
        ...farmPoints,
        ...widget.fields.expand((f) => polygonPoints(f['data'])),
      ];
      paintedSignature = signature;
      final scope = jsonEncode([
        widget.farms.map((r) => r['id']).toList(),
        widget.fields.map((r) => r['id']).toList(),
        all.isNotEmpty,
        if (all.isEmpty) [fix?['lat'], fix?['lon']],
      ]);
      if (fittedScope == scope) return;
      fittedScope = scope;
      if (all.isEmpty) {
        if (fix != null) {
          await map.animateCamera(
            CameraUpdate.newLatLngZoom(
              LatLng(
                (fix['lat'] as num).toDouble(),
                (fix['lon'] as num).toDouble(),
              ),
              16,
            ),
          );
        }
        return;
      }
      final minLat = all.map((p) => p.lat).reduce(math.min);
      final maxLat = all.map((p) => p.lat).reduce(math.max);
      final minLon = all.map((p) => p.lon).reduce(math.min);
      final maxLon = all.map((p) => p.lon).reduce(math.max);
      await map.animateCamera(
        CameraUpdate.newLatLngBounds(
          LatLngBounds(
            southwest: LatLng(minLat, minLon),
            northeast: LatLng(maxLat, maxLon),
          ),
          left: 28,
          right: 28,
          top: 28,
          bottom: 28,
        ),
      );
    } finally {
      painting = false;
      if (pendingPaint && mounted) {
        pendingPaint = false;
        paintAndFit();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final all = [
      ...farmPoints,
      ...widget.fields.expand((f) => polygonPoints(f['data'])),
    ];
    final fix = widget.lastFix ?? places.firstOrNull?['data'];
    final target = all.isNotEmpty
        ? LatLng(all.first.lat, all.first.lon)
        : fix != null
        ? LatLng((fix['lat'] as num).toDouble(), (fix['lon'] as num).toDouble())
        : const LatLng(0, 0);
    if (loadingStyle) {
      return const SizedBox(
        height: 300,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (all.isEmpty && fix == null && widget.selectedPlace == null) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              const Icon(Icons.map_outlined, size: 40),
              gap(12),
              const Text(
                'Farm location not recorded',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              gap(8),
              const Text(
                'Map your farm boundary or use your location to show this farm.',
              ),
            ],
          ),
        ),
      );
    }
    return Card(
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        height: 300,
        child: Stack(
          children: [
            Positioned.fill(
              child: MapLibreMap(
                styleString: overviewStyle,
                featureTapsTriggersMapClick: true,
                annotationOrder: const [
                  AnnotationType.fill,
                  AnnotationType.line,
                  AnnotationType.circle,
                  AnnotationType.symbol,
                ],
                onMapClick: (_, p) {
                  if (widget.onPick != null) {
                    widget.onPick!(GeoPoint(p.latitude, p.longitude));
                    return;
                  }
                  for (final pin in places) {
                    if (distance(
                          GeoPoint(p.latitude, p.longitude),
                          GeoPoint(
                            (pin['data']['lat'] as num).toDouble(),
                            (pin['data']['lon'] as num).toDouble(),
                          ),
                        ) <
                        50) {
                      showDialog<void>(
                        context: context,
                        builder: (c) => AlertDialog(
                          title: Text(pin['data']['name']),
                          content: Text(
                            '${pin['data']['type']}\n${pin['data']['notes'] ?? ''}',
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(c),
                              child: const Text('Close'),
                            ),
                          ],
                        ),
                      );
                      return;
                    }
                  }
                  for (final row in [...widget.fields, ...widget.farms]) {
                    if (pointInside(
                      GeoPoint(p.latitude, p.longitude),
                      polygonPoints(row['data']),
                    )) {
                      widget.onArea?.call(row);
                      break;
                    }
                  }
                },
                initialCameraPosition: CameraPosition(
                  target: target,
                  zoom: all.isEmpty && fix == null ? 1 : 14,
                ),
                onMapCreated: (map) => controller = map,
                onStyleLoadedCallback: () async {
                  styleReady = true;
                  paintedSignature = null;
                  await paintAndFit();
                },
                compassEnabled: false,
                rotateGesturesEnabled: false,
                attributionButtonPosition: AttributionButtonPosition.bottomLeft,
              ),
            ),
            Positioned(
              top: 8,
              right: 8,
              child: IconButton.filledTonal(
                tooltip: 'Show whole farm',
                onPressed: () {
                  fittedScope = null;
                  paintedSignature = null;
                  paintAndFit();
                },
                icon: const Icon(Icons.center_focus_strong),
              ),
            ),
            Positioned(
              top: 10,
              left: 10,
              right: 62,
              child: Align(
                alignment: Alignment.centerLeft,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: .9),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    child: Text(
                      widget.onPick != null
                          ? 'Tap to position your place'
                          : 'Farm map',
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              left: 8,
              right: 8,
              bottom: 6,
              child: Text(
                'Map data from OpenStreetMap',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 9,
                  shadows: [Shadow(color: Colors.black, blurRadius: 3)],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String measure(dynamic value, String unit) {
  final points = (value as List? ?? [])
      .map((p) => GeoPoint.fromJson(Map<String, dynamic>.from(p)))
      .toList();
  if (points.length < 3) return 'Not mapped yet';
  return '${AreaUnit.parse(unit).format(area(points))} · Mapped • ${perimeter(points).toStringAsFixed(0)} m perimeter';
}

GeoPoint polygonLabelPoint(List<GeoPoint> polygon) {
  final minY = polygon.map((p) => p.lat).reduce(math.min),
      maxY = polygon.map((p) => p.lat).reduce(math.max);
  double best = -1;
  GeoPoint result = polygon.first;
  for (var row = 1; row < 32; row++) {
    final y = minY + (maxY - minY) * row / 32;
    final xs = <double>[];
    for (var i = 0; i < polygon.length; i++) {
      final a = polygon[i], b = polygon[(i + 1) % polygon.length];
      if ((a.lat > y) != (b.lat > y)) {
        xs.add(a.lon + (y - a.lat) * (b.lon - a.lon) / (b.lat - a.lat));
      }
    }
    xs.sort();
    for (var i = 0; i + 1 < xs.length; i += 2) {
      final width = xs[i + 1] - xs[i];
      if (width > best) {
        best = width;
        result = GeoPoint(y, (xs[i] + xs[i + 1]) / 2);
      }
    }
  }
  return result;
}

String farmMeasurement(Map<String, dynamic> record, String unit) {
  final snapshot = areaSnapshot(record);
  if (snapshot['areaM2'] == null) return 'Boundary not mapped';
  return '${AreaUnit.parse(unit).format(snapshot['areaM2'])} · ${snapshot['source']}';
}
