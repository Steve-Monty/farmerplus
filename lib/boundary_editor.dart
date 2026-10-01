import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'domain.dart';
import 'store.dart';
import 'area_units.dart';
import 'ui.dart';
import 'farm.dart' show streetStyle, satelliteStyle, blankStyle;
import 'map_downloads.dart';
import 'location.dart';
import 'wake_lock.dart' if (dart.library.html) 'wake_lock_web.dart';

enum CaptureMethod { draw, walk, corners, coordinates }

class BoundaryPage extends StatefulWidget {
  final FarmStore store;
  final String kind;
  final String? farmId;
  final Map<String, dynamic>? record;
  final bool readOnly;
  const BoundaryPage({
    super.key,
    required this.store,
    required this.kind,
    this.farmId,
    this.record,
    this.readOnly = false,
  });
  @override
  State<BoundaryPage> createState() => _BoundaryState();
}

class _BoundaryState extends State<BoundaryPage> with WidgetsBindingObserver {
  final mapKey = GlobalKey();
  MapLibreMapController? map;
  List<GeoPoint> points = [], parent = [];
  List<Map<String, dynamic>> neighbours = [];
  Map<String, dynamic>? fix;
  List<Offset> handles = [];
  final undoStack = <(List<GeoPoint>, bool)>[],
      redoStack = <(List<GeoPoint>, bool)>[];
  StreamSubscription<Position>? walking;
  StreamSubscription<List<ConnectivityResult>>? connectivity;
  bool loaded = false,
      ready = false,
      closed = false,
      dragging = false,
      busy = false,
      paused = false,
      painting = false,
      paintAgain = false;
  bool lowPower = false;
  AreaUnit areaUnit = AreaUnit.hectare;
  bool crosshair = false;
  int? selected;
  int dragRequest = 0, projectionRequest = 0;
  int walkGeneration = 0;
  Future<void> walkTail = Future.value();
  Position? lastWalkFix;
  Completer<void>? paintCompletion;
  CaptureMethod method = CaptureMethod.draw;
  String style = streetStyle,
      layer = 'Standard · online',
      status = '',
      language = 'en';
  String? error, downloadedStyle;
  late String id;
  CameraPosition camera = const CameraPosition(
    target: LatLng(-28, 25),
    zoom: 4,
  );
  String get draftKey =>
      'boundaryDraft:${widget.record?['id'] ?? widget.farmId ?? 'new'}:${widget.kind}';
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    id = widget.record?['id'] ?? uuid.v4();
    load();
    connectivity = Connectivity().onConnectivityChanged.listen((result) {
      if (result.contains(ConnectivityResult.none) &&
          downloadedStyle != null &&
          style != downloadedStyle &&
          mounted) {
        setState(() {
          style = downloadedStyle!;
          layer = 'Standard · downloaded';
          ready = false;
        });
      }
    });
  }

  Future<void> load() async {
    final draft = widget.readOnly ? null : await widget.store.setting(draftKey);
    final data = draft ?? widget.record?['data'] ?? {};
    points = polygonPoints(data);
    closed = data['closed'] as bool? ?? points.length >= 3;
    final parentId = widget.kind == 'farm' ? id : widget.farmId;
    final farm = parentId == null ? null : await widget.store.get(parentId);
    parent = farm == null ? [] : polygonPoints(farm['data']);
    neighbours = (await widget.store.records(
      'field',
    )).where((r) => r['data']['farmId'] == parentId && r['id'] != id).toList();
    fix = await widget.store.setting('lastGpsFix');
    if (fix != null) {
      status =
          'Saved GPS · ${fix!['updated'] ?? fix!['time'] ?? 'time unavailable'} · ±${fix!['accuracy'] ?? '?'} m';
    }
    lowPower = await widget.store.setting('lowPowerGps') ?? false;
    areaUnit = AreaUnit.parse(await widget.store.setting('areaUnit'));
    language = await widget.store.setting('mappingLanguage') ?? 'en';
    downloadedStyle = await MapPacks(widget.store).activeStyle();
    if (downloadedStyle != null) {
      style = downloadedStyle!;
      layer = 'Standard · downloaded';
    }
    final target = points.isNotEmpty
        ? points.first
        : parent.isNotEmpty
        ? parent.first
        : fix != null
        ? GeoPoint(
            (fix!['lat'] as num).toDouble(),
            (fix!['lon'] as num).toDouble(),
          )
        : const GeoPoint(-28, 25);
    camera = CameraPosition(
      target: LatLng(target.lat, target.lon),
      zoom: points.isNotEmpty || parent.isNotEmpty || fix != null ? 15 : 4,
    );
    if (mounted) setState(() => loaded = true);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    walkGeneration++;
    walking?.cancel();
    connectivity?.cancel();
    releaseBoundaryWakeLock();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed || walking == null) return;
    walkGeneration++;
    final active = walking;
    walking = null;
    active?.cancel();
    releaseBoundaryWakeLock();
    if (mounted) {
      setState(() {
        paused = true;
        status =
            'Walking paused while FarmerPlus was not visible. Resume when ready.';
      });
    }
  }

  Future<void> draft() => widget.store.setSetting(draftKey, {
    'points': points.map((p) => p.toJson()).toList(),
    'closed': closed,
    'name': widget.record?['data']['name'] ?? '',
  });
  void checkpoint() {
    undoStack.add((List.of(points), closed));
    redoStack.clear();
  }

  String? issue(List<GeoPoint> candidate, bool finish) =>
      finish ? validatePolygon(candidate) : validateOpenBoundary(candidate);
  Future<void> change(
    List<GeoPoint> candidate, {
    bool? finish,
    bool history = true,
  }) async {
    final nextClosed = finish ?? closed;
    final problem = candidate.isEmpty ? null : issue(candidate, nextClosed);
    if (problem != null) {
      if (mounted) setState(() => error = problem);
      return;
    }
    if (history) checkpoint();
    dragRequest++;
    setState(() {
      points = candidate;
      closed = nextClosed;
      error = null;
      selected = null;
    });
    await draft();
    await paint();
  }

  Future<void> add(GeoPoint p) async {
    if (closed || widget.readOnly) return;
    await change([...points, p]);
  }

  Future<void> undo(bool redo) async {
    final from = redo ? redoStack : undoStack,
        to = redo ? undoStack : redoStack;
    if (from.isEmpty) return;
    dragRequest++;
    to.add((List.of(points), closed));
    final item = from.removeLast();
    setState(() {
      points = item.$1;
      closed = item.$2;
      selected = null;
      error = null;
    });
    await draft();
    await paint();
  }

  Future<void> project() async {
    if (!ready || map == null || !mounted) return;
    final request = ++projectionRequest;
    final snapshot = List.of(points);
    final scale = kIsWeb ? 1.0 : MediaQuery.devicePixelRatioOf(context);
    final positions = <Offset>[];
    for (final p in snapshot) {
      final xy = await map!.toScreenLocation(LatLng(p.lat, p.lon));
      positions.add(Offset(xy.x / scale, xy.y / scale));
    }
    if (mounted &&
        request == projectionRequest &&
        listEquals(snapshot, points)) {
      setState(() => handles = positions);
    }
  }

  Future<void> paint() async {
    if (!ready || map == null || !mounted) return;
    if (painting) {
      paintAgain = true;
      await paintCompletion!.future;
      return;
    }
    painting = true;
    final completion = paintCompletion = Completer<void>();
    try {
      do {
        paintAgain = false;
        await map!.clearLines();
        await map!.clearFills();
        Future<void> outline(List<GeoPoint> ps, String color, bool fill) async {
          if (ps.length < 2) return;
          final ring = [
            ...ps.map((p) => LatLng(p.lat, p.lon)),
            if (fill) LatLng(ps.first.lat, ps.first.lon),
          ];
          if (fill) {
            await map!.addFill(
              FillOptions(geometry: [ring], fillColor: color, fillOpacity: .13),
            );
          }
          await map!.addLine(
            LineOptions(geometry: ring, lineColor: color, lineWidth: 3),
          );
        }

        if (widget.kind == 'field') await outline(parent, '#2364bd', true);
        for (final row in neighbours) {
          await outline(polygonPoints(row['data']), '#238669', true);
        }
        await outline(List.of(points), '#c34238', closed);
        await project();
      } while (paintAgain && mounted);
    } finally {
      painting = false;
      completion.complete();
    }
  }

  Future<void> fit() async {
    final ps = points.isNotEmpty ? points : parent;
    if (ps.isEmpty) return;
    if (ps.length == 1) {
      await map?.animateCamera(
        CameraUpdate.newLatLngZoom(LatLng(ps.first.lat, ps.first.lon), 17),
      );
      return;
    }
    final minLat = ps.map((p) => p.lat).reduce(math.min),
        maxLat = ps.map((p) => p.lat).reduce(math.max);
    final minLon = ps.map((p) => p.lon).reduce(math.min),
        maxLon = ps.map((p) => p.lon).reduce(math.max);
    await map?.animateCamera(
      CameraUpdate.newLatLngBounds(
        LatLngBounds(
          southwest: LatLng(minLat - .0001, minLon - .0001),
          northeast: LatLng(maxLat + .0001, maxLon + .0001),
        ),
        left: 60,
        right: 60,
        top: 65,
        bottom: 65,
      ),
    );
  }

  Future<void> dragTo(int index, Offset global) async {
    if (index >= points.length) return;
    final request = ++dragRequest;
    final box = mapKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final p = box.globalToLocal(global),
        scale = kIsWeb ? 1.0 : MediaQuery.devicePixelRatioOf(context);
    final latlon = await map!.toLatLng(math.Point(p.dx * scale, p.dy * scale));
    if (!mounted || request != dragRequest || index >= points.length) return;
    final candidate = List<GeoPoint>.of(points)
      ..[index] = GeoPoint(latlon.latitude, latlon.longitude);
    final problem = issue(candidate, closed);
    if (problem != null) {
      setState(() => error = problem);
      return;
    }
    setState(() {
      points = candidate;
      error = null;
    });
    await draft();
    await paint();
  }

  Future<bool> permission() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      throw StateError('Turn on device location to use GPS.');
    }
    var p = await Geolocator.checkPermission();
    if (p == LocationPermission.denied) {
      p = await Geolocator.requestPermission();
    }
    if (p == LocationPermission.denied ||
        p == LocationPermission.deniedForever) {
      throw StateError(
        'Location permission is needed for GPS. Drawing still works.',
      );
    }
    return true;
  }

  bool good(Position p) {
    final age = DateTime.now().difference(p.timestamp);
    return p.latitude.isFinite &&
        p.longitude.isFinite &&
        p.latitude.abs() <= 90 &&
        p.longitude.abs() <= 180 &&
        p.accuracy.isFinite &&
        p.accuracy >= 0 &&
        p.accuracy <= 25 &&
        age >= const Duration(seconds: -5) &&
        age <= const Duration(seconds: 30);
  }

  Future<void> acceptWalkingFix(Position p, int generation) async {
    if (!mounted || generation != walkGeneration || walking == null || closed) {
      return;
    }
    if (!good(p)) {
      setState(
        () => error =
            'Weak or stale GPS point skipped. Wait for accuracy within 25 m.',
      );
      return;
    }
    final previous = lastWalkFix;
    if (previous != null) {
      final elapsed = p.timestamp.difference(previous.timestamp).inMilliseconds;
      if (elapsed <= 0) return;
      final travelled = Geolocator.distanceBetween(
        previous.latitude,
        previous.longitude,
        p.latitude,
        p.longitude,
      );
      final speed = travelled / (elapsed / 1000);
      if (speed > 12 || travelled > 150) {
        if (mounted)
          setState(
            () => error =
                'Implausible GPS jump skipped. Your last valid draft is unchanged.',
          );
        return;
      }
    }
    if (generation != walkGeneration || walking == null || closed) return;
    await remember(p);
    lastWalkFix = p;
    if (points.isEmpty ||
        distance(points.last, GeoPoint(p.latitude, p.longitude)) > 2) {
      await add(GeoPoint(p.latitude, p.longitude, p.accuracy));
    }
  }

  Future<void> remember(Position p) async {
    fix = {
      'lat': p.latitude,
      'lon': p.longitude,
      'accuracy': p.accuracy,
      'time': p.timestamp.toUtc().toIso8601String(),
      'updated': p.timestamp.toUtc().toIso8601String(),
    };
    await widget.store.setSetting('lastGpsFix', fix);
    if (mounted) {
      setState(
        () => status =
            'GPS ±${p.accuracy.toStringAsFixed(0)} m · ${p.timestamp.toLocal().toString().substring(11, 19)}',
      );
    }
  }

  Future<void> gps({bool capture = false}) async {
    setState(() => busy = true);
    try {
      await permission();
      final p = await DeviceLocation.current(
        maxAccuracy: 25,
        accuracy: LocationAccuracy.best,
      );
      await remember(p);
      await map?.animateCamera(
        CameraUpdate.newLatLngZoom(LatLng(p.latitude, p.longitude), 17),
      );
      if (capture) {
        if (!good(p)) {
          throw StateError(
            'GPS is too weak or old. Wait for a fresh fix within 25 m.',
          );
        }
        await add(GeoPoint(p.latitude, p.longitude, p.accuracy));
      }
    } catch (e) {
      if (mounted) {
        setState(() => error = e.toString().replaceFirst('Bad state: ', ''));
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> walk() async {
    if (walking != null) {
      walkGeneration++;
      await walking!.cancel();
      walking = null;
      await walkTail;
      await releaseBoundaryWakeLock();
      setState(() => paused = true);
      return;
    }
    try {
      await permission();
      try {
        final battery = await Battery().batteryLevel;
        if (battery <= 15 && !lowPower && mounted) {
          lowPower =
              await showDialog<bool>(
                context: context,
                builder: (c) => AlertDialog(
                  title: Text('Battery at $battery%'),
                  content: const Text(
                    'Low-power GPS records corners less often. You can pause at any time.',
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(c, false),
                      child: const Text('Keep precision'),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.pop(c, true),
                      child: const Text('Use low power'),
                    ),
                  ],
                ),
              ) ??
              false;
        }
      } catch (_) {}
      setState(() => paused = false);
      final generation = ++walkGeneration;
      lastWalkFix = null;
      final awake = await requestBoundaryWakeLock();
      if (!awake && mounted) {
        setState(
          () => status =
              'Keep FarmerPlus visible while walking; screen wake lock is unavailable.',
        );
      }
      walking =
          Geolocator.getPositionStream(
            locationSettings: LocationSettings(
              accuracy: LocationAccuracy.best,
              distanceFilter: lowPower ? 12 : 5,
            ),
          ).listen(
            (p) {
              walkTail = walkTail
                  .then((_) => acceptWalkingFix(p, generation))
                  .catchError(
                    (Object _, StackTrace _) =>
                        stopWalkingAfterFailure(generation),
                  );
            },
            onError: (Object e) {
              unawaited(stopWalkingAfterFailure(generation));
            },
          );
      setState(() {});
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    }
  }

  Future<void> stopWalkingAfterFailure(int generation) async {
    if (generation != walkGeneration) return;
    walkGeneration++;
    final stream = walking;
    walking = null;
    await stream?.cancel();
    await releaseBoundaryWakeLock();
    if (mounted) {
      setState(() {
        paused = true;
        error =
            'Walking capture stopped because the latest point could not be saved. Your earlier draft is unchanged.';
      });
    }
  }

  Future<void> finish() async {
    final problem = validatePolygon(points);
    if (problem != null) {
      setState(() => error = problem);
      return;
    }
    walkGeneration++;
    await walking?.cancel();
    walking = null;
    await walkTail;
    await releaseBoundaryWakeLock();
    await change(List.of(points), finish: true);
  }

  Future<void> coordinates([int? index]) async {
    final lat = TextEditingController(
          text: index == null ? '' : points[index].lat.toString(),
        ),
        lon = TextEditingController(
          text: index == null ? '' : points[index].lon.toString(),
        );
    final p = await showDialog<GeoPoint>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Boundary point'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: lat,
              decoration: const InputDecoration(labelText: 'Latitude'),
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
                signed: true,
              ),
            ),
            TextField(
              controller: lon,
              decoration: const InputDecoration(labelText: 'Longitude'),
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
                signed: true,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final a = double.tryParse(lat.text),
                  b = double.tryParse(lon.text);
              if (a != null && b != null) Navigator.pop(c, GeoPoint(a, b));
            },
            child: const Text('Use point'),
          ),
        ],
      ),
    );
    if (p != null) {
      if (index == null) {
        await add(p);
      } else {
        await change(List<GeoPoint>.of(points)..[index] = p);
      }
    }
  }

  Future<void> clear() async {
    if (await showDialog<bool>(
          context: context,
          builder: (c) => AlertDialog(
            title: const Text('Redraw boundary?'),
            content: const Text(
              'Only the drawing is cleared. The saved boundary is replaced only when you save. The name and activity history stay unchanged.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(c, false),
                child: const Text('Keep drawing'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(c, true),
                child: const Text('Clear drawing'),
              ),
            ],
          ),
        ) ==
        true) {
      walkGeneration++;
      final stream = walking;
      walking = null;
      await stream?.cancel();
      await walkTail;
      await releaseBoundaryWakeLock();
      await change([], finish: false);
    }
  }

  Future<void> save() async {
    dragRequest++;
    if (points.isNotEmpty && !closed) {
      setState(() => error = 'Finish the boundary before saving.');
      return;
    }
    await guarded(context, () async {
      await widget.store.save(widget.kind, {
        ...?(widget.record?['data'] as Map<String, dynamic>?),
        'name': widget.record?['data']['name'] ?? 'Unnamed area',
        if (widget.farmId != null) 'farmId': widget.farmId,
        'points': points.map((p) => p.toJson()).toList(),
      }, id: id);
      await widget.store.setSetting(draftKey, null);
      if (mounted) Navigator.pop(context, id);
    });
  }

  void chooseLayer() async {
    final selectedLayer = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: const Text('Standard'),
              subtitle: const Text('Online · OpenFreeMap'),
              onTap: () => Navigator.pop(c, 'online'),
            ),
            ListTile(
              title: const Text('Satellite'),
              subtitle: const Text('Online only · Sentinel imagery, 2025'),
              onTap: () => Navigator.pop(c, 'satellite'),
            ),
            ListTile(
              enabled: downloadedStyle != null,
              title: const Text('Downloaded map'),
              subtitle: Text(
                downloadedStyle == null
                    ? 'Download a map in My Farm first'
                    : 'Works without internet · retained until removed',
              ),
              onTap: () => Navigator.pop(c, 'downloaded'),
            ),
            ListTile(
              title: const Text('Boundary only'),
              subtitle: const Text('No background map needed'),
              onTap: () => Navigator.pop(c, 'blank'),
            ),
          ],
        ),
      ),
    );
    if (selectedLayer == null || !mounted) return;
    setState(() {
      ready = false;
      style = switch (selectedLayer) {
        'satellite' => satelliteStyle,
        'downloaded' => downloadedStyle!,
        'blank' => blankStyle,
        _ => streetStyle,
      };
      layer = switch (selectedLayer) {
        'satellite' => 'Satellite · online only',
        'downloaded' => 'Standard · downloaded',
        'blank' => 'Boundary only',
        _ => 'Standard · online',
      };
    });
  }

  String get help {
    if (widget.readOnly) {
      return 'Saved boundary · GPS measurements are estimates';
    }
    if (closed) {
      return 'Select a corner to move it or add a point after it.';
    }
    if (method == CaptureMethod.draw) {
      return language == 'af'
          ? 'Tik om punte by te voeg. Voltooi dan die grens.'
          : language == 'zu'
          ? 'Thepha ukuze ungeze amaphuzu. Bese uqedela umngcele.'
          : 'Tap to add points. Tap the first point or Finish to close.';
    }
    return switch (method) {
      CaptureMethod.walk =>
        'Walk safely along the boundary. Weak GPS points are skipped.',
      CaptureMethod.corners =>
        'Stand at each corner, then capture its GPS position.',
      _ => 'Add each corner using latitude and longitude.',
    };
  }

  @override
  Widget build(BuildContext c) => Scaffold(
    appBar: AppBar(
      title: Text(widget.record?['data']['name'] ?? 'Boundary'),
      actions: [
        IconButton(
          tooltip: 'Map layers',
          onPressed: chooseLayer,
          icon: const Icon(Icons.layers_outlined),
        ),
        IconButton(
          tooltip: 'Map information',
          onPressed: () => showMapCredits(c, style),
          icon: const Icon(Icons.info_outline),
        ),
      ],
    ),
    body: !loaded
        ? const Center(child: CircularProgressIndicator())
        : SafeArea(
            child: Column(
              children: [
                if (!widget.readOnly && !closed)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                    child: DropdownButtonFormField<CaptureMethod>(
                      initialValue: method,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'Mapping method',
                      ),
                      items: const [
                        DropdownMenuItem(
                          value: CaptureMethod.draw,
                          child: Text('Draw on map'),
                        ),
                        DropdownMenuItem(
                          value: CaptureMethod.walk,
                          child: Text('Walk boundary'),
                        ),
                        DropdownMenuItem(
                          value: CaptureMethod.corners,
                          child: Text('Capture GPS corners'),
                        ),
                        DropdownMenuItem(
                          value: CaptureMethod.coordinates,
                          child: Text('Enter coordinates'),
                        ),
                      ],
                      onChanged: (v) async {
                        await walking?.cancel();
                        walking = null;
                        if (mounted) setState(() => method = v!);
                      },
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  child: Text(help, style: Theme.of(c).textTheme.bodySmall),
                ),
                Expanded(
                  child: ClipRect(
                    child: Stack(
                      key: mapKey,
                      children: [
                        MapLibreMap(
                          styleString: style,
                          initialCameraPosition: camera,
                          onMapCreated: (m) => map = m,
                          onStyleLoadedCallback: () async {
                            ready = true;
                            final firstLayout = handles.isEmpty;
                            await paint();
                            if (firstLayout) await fit();
                          },
                          onCameraMove: (position) {
                            camera = position;
                            project();
                          },
                          onCameraIdle: project,
                          onMapClick: (_, p) {
                            if (method == CaptureMethod.draw &&
                                !crosshair &&
                                !closed &&
                                !widget.readOnly) {
                              add(GeoPoint(p.latitude, p.longitude));
                            }
                          },
                          scrollGesturesEnabled: !dragging,
                          rotateGesturesEnabled: false,
                          tiltGesturesEnabled: false,
                          trackCameraPosition: true,
                          compassEnabled: false,
                        ),
                        if (crosshair &&
                            !closed &&
                            method == CaptureMethod.draw)
                          const Center(
                            child: IgnorePointer(
                              child: Icon(
                                Icons.add,
                                size: 32,
                                color: Color(0xffa1352e),
                              ),
                            ),
                          ),
                        if (!widget.readOnly)
                          for (
                            var i = 0;
                            i < handles.length && i < points.length;
                            i++
                          )
                            Positioned(
                              left: handles[i].dx - 24,
                              top: handles[i].dy - 24,
                              child: MouseRegion(
                                cursor: dragging
                                    ? SystemMouseCursors.grabbing
                                    : SystemMouseCursors.grab,
                                child: GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onTap: () {
                                    if (i == 0 &&
                                        !closed &&
                                        points.length >= 3) {
                                      finish();
                                    } else {
                                      setState(() => selected = i);
                                    }
                                  },
                                  onPanStart: (_) {
                                    dragRequest++;
                                    checkpoint();
                                    setState(() {
                                      dragging = true;
                                      selected = i;
                                    });
                                  },
                                  onPanUpdate: (event) =>
                                      dragTo(i, event.globalPosition),
                                  onPanEnd: (_) {
                                    setState(() => dragging = false);
                                    draft();
                                  },
                                  onPanCancel: () {
                                    setState(() => dragging = false);
                                    draft();
                                  },
                                  child: SizedBox(
                                    width: 48,
                                    height: 48,
                                    child: Center(
                                      child: Container(
                                        width: selected == i ? 32 : 22,
                                        height: selected == i ? 32 : 22,
                                        decoration: BoxDecoration(
                                          color: i == 0 && !closed
                                              ? const Color(0xff13765b)
                                              : Colors.white,
                                          shape: BoxShape.circle,
                                          border: Border.all(
                                            color: const Color(0xffa1352e),
                                            width: 3,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                        Positioned(
                          top: 8,
                          left: 8,
                          child: Chip(
                            label: Text(
                              layer,
                              style: const TextStyle(fontSize: 11),
                            ),
                          ),
                        ),
                        Positioned(
                          right: 8,
                          top: 8,
                          child: Material(
                            color: Colors.white,
                            elevation: 2,
                            borderRadius: BorderRadius.circular(14),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  tooltip: 'Zoom in',
                                  onPressed: () =>
                                      map?.animateCamera(CameraUpdate.zoomIn()),
                                  icon: const Icon(Icons.add),
                                ),
                                IconButton(
                                  tooltip: 'Zoom out',
                                  onPressed: () => map?.animateCamera(
                                    CameraUpdate.zoomOut(),
                                  ),
                                  icon: const Icon(Icons.remove),
                                ),
                                IconButton(
                                  tooltip: 'Fit boundary',
                                  onPressed: fit,
                                  icon: const Icon(Icons.fit_screen),
                                ),
                                IconButton(
                                  tooltip: 'My location',
                                  onPressed: busy ? null : () => gps(),
                                  icon: const Icon(Icons.my_location),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 4,
                    ),
                    child: Semantics(
                      liveRegion: true,
                      child: Text(
                        error!,
                        style: TextStyle(color: Theme.of(c).colorScheme.error),
                      ),
                    ),
                  ),
                if (status.isNotEmpty)
                  Text(status, style: Theme.of(c).textTheme.bodySmall),
                Container(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                  decoration: BoxDecoration(
                    color: Theme.of(c).colorScheme.surface,
                    borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(24),
                    ),
                    border: Border.all(
                      color: Theme.of(c).colorScheme.outlineVariant,
                    ),
                  ),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              '${points.length} points · ${closed ? areaUnit.format(area(points)) : '—'}\n${closed ? perimeter(points).toStringAsFixed(0) : '—'} m perimeter',
                              style: Theme.of(c).textTheme.bodyMedium?.copyWith(
                                fontWeight: FontWeight.w600,
                                height: 1.5,
                              ),
                            ),
                          ),
                          if (!widget.readOnly) ...[
                            PopupMenuButton<int>(
                              tooltip: 'Choose corner',
                              icon: const Icon(Icons.pin_drop_outlined),
                              enabled: points.isNotEmpty,
                              itemBuilder: (_) => [
                                for (var i = 0; i < points.length; i++)
                                  PopupMenuItem(
                                    value: i,
                                    child: Text('Corner ${i + 1}'),
                                  ),
                              ],
                              onSelected: (i) {
                                setState(() => selected = i);
                                map?.animateCamera(
                                  CameraUpdate.newLatLngZoom(
                                    LatLng(points[i].lat, points[i].lon),
                                    math.max(camera.zoom, 19.0),
                                  ),
                                );
                              },
                            ),
                            IconButton.filledTonal(
                              tooltip: 'Undo',
                              onPressed: undoStack.isEmpty
                                  ? null
                                  : () => undo(false),
                              icon: const Icon(Icons.undo_rounded),
                            ),
                            IconButton.filledTonal(
                              tooltip: 'Redo',
                              onPressed: redoStack.isEmpty
                                  ? null
                                  : () => undo(true),
                              icon: const Icon(Icons.redo_rounded),
                            ),
                            IconButton.filledTonal(
                              tooltip: 'Clear / redraw boundary',
                              onPressed: points.isEmpty ? null : clear,
                              icon: const Icon(Icons.restart_alt_rounded),
                            ),
                          ],
                        ],
                      ),
                      if (!widget.readOnly) ...[
                        if (selected != null && selected! < points.length)
                          Wrap(
                            spacing: 8,
                            children: [
                              TextButton.icon(
                                icon: const Icon(
                                  Icons.add_location_alt_outlined,
                                ),
                                label: const Text('Add point after'),
                                onPressed: () {
                                  final i = selected!;
                                  final a = points[i],
                                      b = points[(i + 1) % points.length];
                                  change(
                                    List.of(points)..insert(
                                      i + 1,
                                      GeoPoint(
                                        (a.lat + b.lat) / 2,
                                        (a.lon + b.lon) / 2,
                                      ),
                                    ),
                                  );
                                  setState(() => selected = i + 1);
                                },
                              ),
                              TextButton(
                                onPressed: () => coordinates(selected),
                                child: Text('Edit point ${selected! + 1}'),
                              ),
                              TextButton(
                                onPressed: closed && points.length <= 3
                                    ? null
                                    : () => change(
                                        List.of(points)..removeAt(selected!),
                                      ),
                                child: const Text('Delete point'),
                              ),
                            ],
                          ),
                        if (!closed)
                          Wrap(
                            spacing: 8,
                            runSpacing: 4,
                            alignment: WrapAlignment.center,
                            children: [
                              if (method == CaptureMethod.walk) ...[
                                OutlinedButton.icon(
                                  onPressed: walk,
                                  icon: Icon(
                                    walking == null
                                        ? Icons.play_arrow
                                        : Icons.pause,
                                  ),
                                  label: Text(
                                    walking != null
                                        ? 'Pause'
                                        : paused
                                        ? 'Resume'
                                        : 'Start walking',
                                  ),
                                ),
                                FilterChip(
                                  label: const Text('Low-power GPS'),
                                  selected: lowPower,
                                  onSelected: (v) async {
                                    setState(() => lowPower = v);
                                    await widget.store.setSetting(
                                      'lowPowerGps',
                                      v,
                                    );
                                  },
                                ),
                              ],
                              if (method == CaptureMethod.corners)
                                OutlinedButton.icon(
                                  onPressed: busy
                                      ? null
                                      : () => gps(capture: true),
                                  icon: const Icon(Icons.gps_fixed),
                                  label: const Text('Capture corner'),
                                ),
                              if (method == CaptureMethod.draw) ...[
                                FilterChip(
                                  label: const Text('Centre marker'),
                                  selected: crosshair,
                                  onSelected: (v) =>
                                      setState(() => crosshair = v),
                                ),
                                if (crosshair)
                                  OutlinedButton(
                                    onPressed: () => add(
                                      GeoPoint(
                                        camera.target.latitude,
                                        camera.target.longitude,
                                      ),
                                    ),
                                    child: const Text('Add centre point'),
                                  ),
                              ],
                              if (method == CaptureMethod.coordinates)
                                OutlinedButton.icon(
                                  onPressed: () => coordinates(),
                                  icon: const Icon(Icons.pin_drop_outlined),
                                  label: const Text('Add coordinates'),
                                ),
                              FilledButton(
                                onPressed: points.length < 3 ? null : finish,
                                child: const Text('Finish boundary'),
                              ),
                            ],
                          ),
                        if (closed || points.isEmpty)
                          SizedBox(
                            width: double.infinity,
                            child: FilledButton(
                              onPressed: save,
                              child: Text(
                                points.isEmpty
                                    ? 'Save without boundary'
                                    : 'Save boundary',
                              ),
                            ),
                          ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
  );
}

void showMapCredits(BuildContext c, String style) => showDialog<void>(
  context: c,
  builder: (c) => AlertDialog(
    title: const Text('Map information'),
    content: SingleChildScrollView(
      child: Text(
        style == satelliteStyle
            ? 'Satellite imagery: EOxCloudless by EOX IT Services GmbH. Contains modified Copernicus Sentinel data 2025. Online only.'
            : 'Map data from OpenStreetMap (ODbL 1.0). openstreetmap.org/copyright\n\nOnline standard: OpenFreeMap and OpenMapTiles. Downloaded standard: Protomaps and Natural Earth.\n\nOffline map files remain until you remove them. Coverage and detail depend on the source. Farm measurements are estimates, not cadastral surveys.',
      ),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(c), child: const Text('Close')),
    ],
  ),
);
