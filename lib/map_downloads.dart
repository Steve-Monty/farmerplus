import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:maplibre_gl/maplibre_gl.dart';
import 'store.dart';
import 'domain.dart';
import 'farm.dart' show streetStyle;
import 'settings.dart' show OfflineMapStoragePage;
import 'miniapps.dart' show sampleCourse;
import 'learning.dart';
import 'ui.dart';
import 'sync.dart';
import 'map_preparation.dart';
import 'offline_map_blob.dart'
    if (dart.library.html) 'offline_map_blob_web.dart';

String mapBytes(num bytes) => bytes >= 1048576
    ? '${(bytes / 1048576).toStringAsFixed(1)} MB'
    : '${(bytes / 1024).toStringAsFixed(0)} KB';
List<double> mapBounds(double lat, double lon, int radius) {
  final dy = radius / 111.195, dx = dy / math.cos(lat * math.pi / 180);
  return [lon - dx, lat - dy, lon + dx, lat + dy];
}

/// Self-contained geometry style: no online sprite, glyph or font dependencies.
String localMapStyle(String file) {
  final sourceUrl = file.startsWith('blob:') ? file : Uri.file(file).toString();
  return jsonEncode({
  'version': 8,
  'sources': {
    'local': {
      'type': 'vector',
      'url': 'pmtiles://$sourceUrl',
      'attribution': 'Map data from OpenStreetMap · Protomaps · Natural Earth',
    },
  },
  'layers': [
    {
      'id': 'background',
      'type': 'background',
      'paint': {'background-color': '#eaf0e2'},
    },
    for (final entry in {
      'earth': '#f4f3e8',
      'landcover': '#dae8c8',
      'landuse': '#d9e4cb',
      'water': '#99cde3',
      'buildings': '#c1beb1',
    }.entries)
      {
        'id': entry.key,
        'type': 'fill',
        'source': 'local',
        'source-layer': entry.key,
        'filter': [
          '==',
          ['geometry-type'],
          'Polygon',
        ],
        'paint': {
          'fill-color': entry.value,
          'fill-opacity': entry.key == 'landuse' ? 0.65 : 1,
        },
      },
    {
      'id': 'roads',
      'type': 'line',
      'source': 'local',
      'source-layer': 'roads',
      'paint': {
        'line-color': '#ffffff',
        'line-width': [
          'interpolate',
          ['linear'],
          ['zoom'],
          8,
          1,
          14,
          3,
          18,
          7,
        ],
      },
    },
    {
      'id': 'boundaries',
      'type': 'line',
      'source': 'local',
      'source-layer': 'boundaries',
      'paint': {
        'line-color': '#898e88',
        'line-width': 1,
        'line-dasharray': [3, 3],
      },
    },
  ],
  });
}

class MapPacks {
  final FarmStore store;
  MapPacks(this.store);
  Future<List<Map<String, dynamic>>> list() async =>
      List<Map<String, dynamic>>.from(
        await store.setting('downloadedMapPacks') ?? [],
      );
  Future<String?> activeStyle() async {
    final selected = await store.setting('activeMapPack');
    final rows = await list();
    final pack = rows.where((r) => r['id'] == selected).firstOrNull;
    if (kIsWeb && pack != null) {
      final encoded = await store.setting('browserMap:${pack['id']}');
      if (encoded is String &&
          pack['license'] is String &&
          pack['attribution'] is String) {
        final url = await browserMapBlobUrl(encoded);
        if (url != null) return localMapStyle(url);
      }
      return null;
    }
    if (pack != null &&
        await File(pack['path']).exists() &&
        await File(pack['path']).length() == pack['bytes']) {
      return localMapStyle(pack['path']);
    }
    final imported = await store.setting('mapEnabled');
    if (imported != null &&
        await store.setting('mapAuthorization:$imported') != null) {
      try {
        if ((await getOfflineRegionStatus(imported)).isComplete) {
          return await store.setting('mapStyle') as String?;
        }
      } catch (_) {}
    }
    return null;
  }

  Future<void> remove(Map<String, dynamic> pack) async {
    if (kIsWeb) {
      await store.setSetting('browserMap:${pack['id']}', null);
      await store.setSetting(
        'downloadedMapPacks',
        (await list())..removeWhere((p) => p['id'] == pack['id']),
      );
      if (await store.setting('activeMapPack') == pack['id']) {
        await store.setSetting('activeMapPack', null);
      }
      return;
    }
    final expected = File(
      '${store.filesPath}/maps/${pack['id']}.pmtiles',
    ).absolute.path;
    if (File(pack['path']).absolute.path != expected) {
      throw StateError('Unexpected map path; nothing removed.');
    }
    final file = File(expected);
    if (await file.exists()) await file.delete();
    await store.setSetting(
      'downloadedMapPacks',
      (await list())..removeWhere((p) => p['id'] == pack['id']),
    );
    if (await store.setting('activeMapPack') == pack['id']) {
      await store.setSetting('activeMapPack', null);
    }
  }
}

class MapDownloadsPage extends StatefulWidget {
  final FarmStore store;
  final String? farmId;
  const MapDownloadsPage({super.key, required this.store, this.farmId});
  @override
  State<MapDownloadsPage> createState() => _MapDownloadsState();
}

class _MapDownloadsState extends State<MapDownloadsPage> {
  List<Map<String, dynamic>> farms = [], packs = [];
  String? farmId, error;
  int radius = 5, zoom = 14;
  double? lat, lon;
  num? estimate, free;
  bool busy = false, guide = false, lessons = false;
  bool cancelled = false;
  late final SyncEngine mapSync = SyncEngine(widget.store);
  String managedService = '';
  List<Map<String, dynamic>> courses = [];
  final selectedCourses = <int>{};
  final contentStatus = <String, String>{};
  double? progress;
  String status = 'Choose an area, then check the download size.',
      service = const String.fromEnvironment('FARMER_MAP_SERVICE');
  MapLibreMapController? map;
  bool mapReady = false;
  Map<String, dynamic>? job;
  http.Client? transfer;
  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void dispose() {
    cancelled = true;
    transfer?.close();
    mapSync.dispose();
    super.dispose();
  }

  Future<void> load() async {
    farms = await widget.store.records('farm');
    farmId =
        widget.farmId ??
        await widget.store.setting('selectedFarm') ??
        farms.firstOrNull?['id'];
    packs = await MapPacks(widget.store).list();
    final cached = await widget.store.setting('learningCourses');
    if (cached?['owner'] == await widget.store.setting('studentId')) {
      courses = List<Map<String, dynamic>>.from(cached?['courses'] ?? []);
    }
    for (final id in ['guides', 'sample-records']) {
      final asset = await rootBundle.load('assets/packs/$id.json');
      contentStatus[id] =
          '${mapBytes(asset.lengthInBytes)} · ${await widget.store.ready(id) ? 'Ready offline' : 'Not downloaded'}';
    }
    service = await widget.store.setting('mapPackService') ?? service;
    managedService = '${await mapSync.base()}/maps';
    if (service.isEmpty) service = managedService;
    try {
      free = await const MethodChannel(
        'farmerplus/storage',
      ).invokeMethod<num>('freeBytes');
    } catch (_) {}
    await center();
    if (mounted) setState(() {});
  }

  Future<void> center() async {
    final farm = farms.where((r) => r['id'] == farmId).firstOrNull;
    final ps = farm == null ? <GeoPoint>[] : polygonPoints(farm['data']);
    final fix = await widget.store.setting('lastGpsFix');
    lat = ps.isEmpty
        ? (fix?['lat'] as num?)?.toDouble()
        : ps.map((p) => p.lat).reduce((a, b) => a + b) / ps.length;
    lon = ps.isEmpty
        ? (fix?['lon'] as num?)?.toDouble()
        : ps.map((p) => p.lon).reduce((a, b) => a + b) / ps.length;
    estimate = null;
    await preview();
  }

  Future<void> preview() async {
    if (!mapReady || map == null || lat == null || lon == null) return;
    final b = mapBounds(lat!, lon!, radius);
    await map!.clearLines();
    await map!.clearFills();
    final ring = [
      LatLng(b[1], b[0]),
      LatLng(b[1], b[2]),
      LatLng(b[3], b[2]),
      LatLng(b[3], b[0]),
      LatLng(b[1], b[0]),
    ];
    await map!.addFill(
      FillOptions(geometry: [ring], fillColor: '#13765b', fillOpacity: .16),
    );
    await map!.addLine(
      LineOptions(geometry: ring, lineColor: '#13765b', lineWidth: 3),
    );
    await map!.animateCamera(
      CameraUpdate.newLatLngBounds(
        LatLngBounds(southwest: ring[0], northeast: ring[2]),
        left: 24,
        right: 24,
        top: 24,
        bottom: 24,
      ),
    );
  }

  Map<String, dynamic> get region => {
    'lat': lat,
    'lon': lon,
    'radius': radius,
    'zoom': zoom,
  };
  Future<Map<String, dynamic>> request(
    String route, {
    Map<String, dynamic>? body,
  }) async {
    if (service == managedService) {
      return Map<String, dynamic>.from(
        await mapSync.request(
          body == null ? 'GET' : 'POST',
          '/maps$route',
          body: body,
        ),
      );
    }
    if (service.isEmpty) {
      throw StateError(
        'Map download service is not configured. Use Advanced to connect your map server.',
      );
    }
    final uri = Uri.parse('${service.replaceAll(RegExp(r'/+$'), '')}$route');
    final result = body == null
        ? await http.get(uri).timeout(const Duration(seconds: 40))
        : await http
              .post(
                uri,
                headers: {'Content-Type': 'application/json'},
                body: jsonEncode(body),
              )
              .timeout(const Duration(seconds: 40));
    final data = jsonDecode(result.body);
    if (result.statusCode >= 400) {
      throw StateError(data['detail']?.toString() ?? 'Map server unavailable');
    }
    return Map<String, dynamic>.from(data);
  }

  Future<void> check() async {
    setState(() {
      busy = true;
      error = null;
      status = 'Checking the latest map build…';
    });
    try {
      final info = await request('/estimate', body: region);
      if (mounted) {
        setState(() {
          estimate = info['estimatedBytes'];
          status =
              'Build ${info['build']} · ${estimate == null ? 'size available after preparation' : 'estimated size; actual download may differ'}';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          status = 'Map size could not be checked.';
          error = e.toString().replaceFirst('Bad state: ', '');
        });
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> download() async {
    cancelled = false;
    var savedMap = false;
    File? partial;
    setState(() {
      busy = true;
      error = null;
      progress = null;
      status = 'Preparing your map…';
    });
    try {
      job = await request('/prepare', body: region);
      job = await waitForMap(
        job!,
        poll: (id) => request('/jobs/$id'),
        cancelled: () => cancelled || !mounted,
        status: (value) {
          if (mounted) setState(() => status = value);
        },
      );
      if (job!['state'] != 'ready') {
        throw StateError(job!['error'] ?? 'Preparation failed');
      }
      final bytes = job!['bytes'] as int;
      if (bytes < 127 ||
          bytes > 500 * 1048576 ||
          !RegExp(
            r'^[a-f0-9]{64}$',
          ).hasMatch(job!['sha256']?.toString() ?? '')) {
        throw StateError('Pack exceeds the 500 MB limit.');
      }
      if (free != null && free! < bytes * 1.2) {
        throw StateError('Not enough free storage for this map.');
      }
      if (!mounted) return;
      final proceed = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('Download map?'),
          content: Text(
            '${mapBytes(bytes)} · $radius km radius\nStandard map, zoom 0–$zoom. Retained until you remove it. Mobile data may be used.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Download'),
            ),
          ],
        ),
      );
      if (proceed != true) return;
      if (cancelled || !mounted) return;
      if (kIsWeb) {
        final row = await downloadBrowserPack(bytes);
        final all = await MapPacks(widget.store).list();
        all.removeWhere((r) => r['id'] == row['id']);
        all.add(row);
        await widget.store.setSetting('downloadedMapPacks', all);
        await widget.store.setSetting('activeMapPack', row['id']);
        savedMap = true;
        packs = all;
        if (mounted) {
          setState(() => status = 'Map downloaded, verified and saved in this browser.');
        }
        return;
      }
      final dir = Directory('${widget.store.filesPath}/maps');
      await dir.create(recursive: true);
      final target = File('${dir.path}/${job!['id']}.pmtiles'),
          temp = File('${dir.path}/${job!['id']}.partial');
      partial = temp;
      transfer = http.Client();
      // Refresh through the normal session path before a potentially large file.
      if (service == managedService) await request('/jobs/${job!['id']}');
      final fileRequest = http.Request(
        'GET',
        Uri.parse('$service/files/${job!['id']}'),
      )..followRedirects = false;
      if (service == managedService && mapSync.token != null) {
        fileRequest.headers['Authorization'] = 'Bearer ${mapSync.token}';
      }
      final response = await transfer!
          .send(fileRequest)
          .timeout(const Duration(seconds: 40));
      if (response.statusCode != 200) {
        throw StateError('Map download failed. Please retry.');
      }
      final sink = temp.openWrite();
      var received = 0;
      try {
        await for (final chunk in response.stream.timeout(
          const Duration(seconds: 40),
        )) {
          if (cancelled || !mounted) {
            throw StateError('Map download cancelled.');
          }
          received += chunk.length;
          if (received > bytes) {
            throw StateError('Map file size did not match.');
          }
          sink.add(chunk);
          if (mounted) {
            setState(() {
              progress = received / bytes;
              status =
                  'Downloading ${mapBytes(received)} of ${mapBytes(bytes)}';
            });
          }
        }
      } finally {
        await sink.close();
        transfer?.close();
        transfer = null;
      }
      if (received != bytes ||
          (await sha256.bind(temp.openRead()).first).toString() !=
              job!['sha256']) {
        throw StateError('Map integrity check failed. Please retry.');
      }
      final read = await temp.open();
      final header = await read.read(8);
      await read.close();
      if (utf8.decode(header.take(7).toList()) != 'PMTiles' || header[7] != 3) {
        throw StateError('Unsupported map archive.');
      }
      await temp.rename(target.path);
      final row = {
        ...job!,
        'path': target.path,
        'farmId': farmId,
        'name':
            farms
                .where((r) => r['id'] == farmId)
                .firstOrNull?['data']['name'] ??
            'Map area',
        'downloaded': DateTime.now().toUtc().toIso8601String(),
      };
      final all = await MapPacks(widget.store).list();
      all.removeWhere((r) => r['id'] == row['id']);
      all.add(row);
      await widget.store.setSetting('downloadedMapPacks', all);
      await widget.store.setSetting('activeMapPack', row['id']);
      savedMap = true;
      packs = all;
      if (guide) {
        try {
          await widget.store.install(
            catalogue.firstWhere((a) => a.id == 'guides'),
          );
          contentStatus['guides'] = 'Ready offline';
        } catch (_) {
          contentStatus['guides'] = 'Download failed · retry from App Store';
        }
      }
      if (lessons) {
        try {
          await widget.store.install(sampleCourse);
          contentStatus['sample-records'] = 'Ready offline';
        } catch (_) {
          contentStatus['sample-records'] =
              'Download failed · retry from Learning';
        }
      }
      final learner = StudentLearning(widget.store);
      try {
        for (final courseId in selectedCourses) {
          try {
            await learner.downloadText(courseId);
            final cached = await widget.store.setting(
              'learningCourse:$courseId',
            );
            contentStatus['course:$courseId'] =
                '${cached['downloadedTexts']} text lessons · ${mapBytes(utf8.encode(jsonEncode(cached)).length)} saved';
          } catch (_) {
            contentStatus['course:$courseId'] =
                'Not downloaded · open Learning to check access or retry';
          }
        }
      } finally {
        learner.client.close();
      }
      packs = all;
      if (mounted) {
        setState(
          () => status = 'Map downloaded and verified. Ready without internet.',
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          status = cancelled
              ? 'Map download cancelled.'
              : 'Map download did not finish.';
          error = cancelled
              ? null
              : e.toString().replaceFirst('Bad state: ', '');
        });
      }
    } finally {
      transfer?.close();
      transfer = null;
      if (partial != null && await partial.exists()) await partial.delete();
      if (mounted && !savedMap && error == null) {
        status = 'Map download cancelled.';
      }
      if (mounted) setState(() => busy = false);
    }
  }

  Future<Map<String, dynamic>> downloadBrowserPack(int expectedBytes) async {
    final attribution = job!['attribution']?.toString() ?? '';
    final license = (job!['license'] ?? job!['licence'])?.toString() ?? '';
    if (attribution.isEmpty || license.isEmpty) {
      throw StateError('The map service did not provide required attribution and licence details.');
    }
    if (expectedBytes > 100 * 1048576) {
      throw StateError('Browser map packs are limited to 100 MB. Choose a smaller area or less detail.');
    }
    final uri = Uri.parse('$service/files/${job!['id']}');
    final response = await mapSync.client.get(uri).timeout(const Duration(seconds: 90));
    if (response.statusCode != 200 || response.bodyBytes.length != expectedBytes) {
      throw StateError('Map file size did not match.');
    }
    final bytes = response.bodyBytes;
    if (sha256.convert(bytes).toString() != job!['sha256'] ||
        bytes.length < 8 ||
        utf8.decode(bytes.take(7).toList()) != 'PMTiles' ||
        bytes[7] != 3) {
      throw StateError('Map integrity check failed. Please retry.');
    }
    await widget.store.setSetting('browserMap:${job!['id']}', base64Encode(bytes));
    return {
      ...job!,
      'path': 'browser:${job!['id']}',
      'farmId': farmId,
      'name': farms.where((r) => r['id'] == farmId).firstOrNull?['data']['name'] ?? 'Map area',
      'downloaded': DateTime.now().toUtc().toIso8601String(),
      'attribution': attribution,
      'license': license,
    };
  }

  Future<void> advanced() async {
    final input = TextEditingController(text: service);
    await showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Map service'),
        content: TextField(
          controller: input,
          decoration: const InputDecoration(
            labelText: 'Map preparation URL',
            helperText: 'Self-hosted service; no paid provider key.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              final uri = Uri.tryParse(input.text.trim());
              if (uri == null ||
                  uri.host.isEmpty ||
                  !{'https', 'http'}.contains(uri.scheme)) {
                return;
              }
              if (uri.scheme == 'http' &&
                  !{'10.0.2.2', 'localhost', '127.0.0.1'}.contains(uri.host)) {
                return;
              }
              service = input.text.trim();
              await widget.store.setSetting('mapPackService', service);
              if (c.mounted) Navigator.pop(c);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext c) => PageFrame(
    'Offline maps',
    children: [
      heading(c, 'Take your map with you'),
      const Text(
        'Downloaded maps stay on this device until you remove them. No “recently used” requirement.',
      ),
      gap(),
      if (farms.isNotEmpty)
        DropdownButtonFormField<String>(
          initialValue: farmId,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Around this farm'),
          items: farms
              .map(
                (r) => DropdownMenuItem<String>(
                  value: r['id'],
                  child: Text(r['data']['name']),
                ),
              )
              .toList(),
          onChanged: busy
              ? null
              : (v) async {
                  farmId = v;
                  await center();
                  if (mounted) setState(() {});
                },
        ),
      gap(),
      SizedBox(
        height: 200,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: MapLibreMap(
            styleString: streetStyle,
            initialCameraPosition: CameraPosition(
              target: LatLng(lat ?? -28, lon ?? 25),
              zoom: 8,
            ),
            onMapCreated: (m) => map = m,
            onStyleLoadedCallback: () async {
              mapReady = true;
              await preview();
            },
            onMapClick: busy
                ? null
                : (_, p) {
                    setState(() {
                      lat = p.latitude;
                      lon = p.longitude;
                      estimate = null;
                    });
                    preview();
                  },
          ),
        ),
      ),
      Text(
        lat == null
            ? 'Tap the map to choose a centre.'
            : 'Tap to move centre · ${lat!.toStringAsFixed(4)}, ${lon!.toStringAsFixed(4)}',
        style: Theme.of(c).textTheme.bodySmall,
      ),
      gap(),
      Text(
        '$radius km radius · ${radius * 2} km across',
        style: Theme.of(c).textTheme.titleMedium,
      ),
      Slider(
        value: radius.toDouble(),
        min: 1,
        max: 10,
        divisions: 9,
        label: '$radius km',
        onChanged: busy
            ? null
            : (v) {
                setState(() {
                  radius = v.round();
                  estimate = null;
                });
              },
        onChangeEnd: (_) => preview(),
      ),
      const Text('The outlined square is downloaded to cover the full radius.'),
      gap(),
      DropdownButtonFormField<int>(
        initialValue: zoom,
        decoration: const InputDecoration(labelText: 'Map detail'),
        items: const [
          DropdownMenuItem(
            value: 12,
            child: Text('Overview · smaller download'),
          ),
          DropdownMenuItem(
            value: 14,
            child: Text('Standard · roads and buildings'),
          ),
          DropdownMenuItem(
            value: 15,
            child: Text('Detailed · larger download'),
          ),
        ],
        onChanged: busy
            ? null
            : (v) => setState(() {
                zoom = v!;
                estimate = null;
              }),
      ),
      gap(),
      Text(
        'Estimated: ${estimate == null ? 'not checked' : mapBytes(estimate!)} · Free: ${free == null ? 'unavailable' : mapBytes(free!)}',
      ),
      Text(status, style: Theme.of(c).textTheme.bodySmall),
      if (busy) LinearProgressIndicator(value: progress),
      if (busy)
        TextButton(
          onPressed: cancelled
              ? null
              : () {
                  setState(() {
                    cancelled = true;
                    status = 'Cancelling…';
                  });
                  transfer?.close();
                },
          child: const Text('Cancel'),
        ),
      if (error != null) note(error!, icon: Icons.error_outline),
      Wrap(
        spacing: 8,
        children: [
          OutlinedButton(
            onPressed: busy || lat == null ? null : check,
            child: const Text('Check size'),
          ),
          FilledButton.icon(
            onPressed: busy || lat == null ? null : download,
            icon: const Icon(Icons.download),
            label: const Text('Prepare download'),
          ),
        ],
      ),
      ExpansionTile(
        title: const Text('Include free offline content'),
        subtitle: const Text('Choose what is stored with the map'),
        children: [
          CheckboxListTile(
            value: guide,
            onChanged: busy ? null : (v) => setState(() => guide = v!),
            title: const Text('Farm Guides'),
            subtitle: Text(contentStatus['guides'] ?? 'Checking guide pack…'),
          ),
          CheckboxListTile(
            value: lessons,
            onChanged: busy ? null : (v) => setState(() => lessons = v!),
            title: const Text('Useful farm records · sample lessons'),
            subtitle: Text(
              contentStatus['sample-records'] ?? 'Checking lesson pack…',
            ),
          ),
          for (final course in courses)
            CheckboxListTile(
              value: selectedCourses.contains(course['id']),
              onChanged: busy
                  ? null
                  : (v) => setState(() {
                      if (v == true) {
                        selectedCourses.add(course['id']);
                      } else {
                        selectedCourses.remove(course['id']);
                      }
                    }),
              title: Text(
                course['fullname'] ?? course['name'] ?? 'Enrolled course',
              ),
              subtitle: Text(
                contentStatus['course:${course['id']}'] ??
                    'Available lesson text only · size known after download · access checked online',
              ),
            ),
          if (courses.isEmpty)
            const ListTile(
              title: Text('Enrolled courses'),
              subtitle: Text(
                'Open Learning to refresh your enrolled courses. They can then be selected here.',
              ),
            ),
        ],
      ),
      heading(c, 'Downloaded maps'),
      if (packs.isEmpty)
        const Text(
          'No maps downloaded yet. Your boundaries and records still work offline.',
        ),
      for (final p in packs)
        ListTile(
          leading: const Icon(Icons.offline_pin_outlined),
          title: Text('${p['name']} · ${p['radius']} km'),
          subtitle: Text(
            '${mapBytes(p['bytes'])} · Build ${p['build']}\nStandard map geometry; online place labels are not included.',
          ),
          isThreeLine: true,
          onTap: () async {
            await widget.store.setSetting('activeMapPack', p['id']);
            if (c.mounted) {
              ScaffoldMessenger.of(c).showSnackBar(
                const SnackBar(content: Text('Downloaded map selected.')),
              );
            }
          },
          trailing: IconButton(
            tooltip: 'Remove downloaded map',
            icon: const Icon(Icons.delete_outline),
            onPressed: busy
                ? null
                : () async {
                    if (await showDialog<bool>(
                          context: c,
                          builder: (d) => AlertDialog(
                            title: const Text('Remove downloaded map?'),
                            content: const Text(
                              'Farm boundaries and records are kept. You can download this map again.',
                            ),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(d, false),
                                child: const Text('Keep'),
                              ),
                              FilledButton(
                                onPressed: () => Navigator.pop(d, true),
                                child: const Text('Remove'),
                              ),
                            ],
                          ),
                        ) ==
                        true) {
                      await MapPacks(widget.store).remove(p);
                      await load();
                    }
                  },
          ),
        ),
      ExpansionTile(
        title: const Text('Advanced'),
        children: [
          ListTile(
            title: const Text('Map service connection'),
            onTap: advanced,
          ),
          ListTile(
            title: const Text('Import an authorised map database'),
            onTap: () =>
                openPage(c, OfflineMapStoragePage(store: widget.store)),
          ),
        ],
      ),
      note(
        'Map data from OpenStreetMap · ODbL 1.0. Protomaps and Natural Earth. Satellite imagery is online only.',
      ),
    ],
  );
}
