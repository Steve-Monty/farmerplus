import 'course_downloads.dart';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'store.dart';
import 'offline_access.dart';
import 'ui.dart';
import 'map_downloads.dart';
import 'course_download_ui.dart';
import 'miniapps.dart' show LearningPage;
import 'sync.dart';
import 'home_panels.dart' show PendingSyncPage;

class OfflineReadinessPage extends StatefulWidget {
  final FarmStore store;
  const OfflineReadinessPage({super.key, required this.store});
  @override
  State<OfflineReadinessPage> createState() => _OfflineReadinessState();
}

class _OfflineReadinessState extends State<OfflineReadinessPage> {
  late Future<Map<String, dynamic>> report = inspect();

  Future<int?> mapPackBytes(Map<String, dynamic> pack) async {
    final expected = pack['bytes'];
    final expectedHash = pack['sha256'];
    if (expected is! int ||
        expected < 8 ||
        expectedHash is! String ||
        expectedHash.length != 64 ||
        pack['attribution'] is! String ||
        (pack['attribution'] as String).isEmpty ||
        pack['license'] is! String ||
        (pack['license'] as String).isEmpty) {
      return null;
    }
    if (kIsWeb) {
      final encoded = await widget.store.setting('browserMap:${pack['id']}');
      if (encoded is! String || encoded.isEmpty) return null;
      try {
        final bytes = base64Decode(encoded);
        if (bytes.length != expected ||
            sha256.convert(bytes).toString() != expectedHash ||
            utf8.decode(bytes.take(7).toList()) != 'PMTiles' ||
            bytes[7] != 3) {
          return null;
        }
        return bytes.length;
      } catch (_) {
        return null;
      }
    }
    final path = pack['path'];
    if (path is! String || path.isEmpty) return null;
    try {
      final file = File(path);
      if (!await file.exists() || await file.length() != expected) return null;
      final digest = await sha256.bind(file.openRead()).first;
      return digest.toString() == expectedHash ? expected : null;
    } catch (_) {
      return null;
    }
  }

  Future<bool> browserLoginReady() async {
    final saved = await widget.store.setting('offlineEmailVerifier');
    if (saved is! Map ||
        saved['owner'] != await widget.store.setting('boundOwner') ||
        saved['server'] != await widget.store.setting('boundServer') ||
        saved['credentialEpoch'] !=
            await widget.store.setting('credentialEpoch') ||
        saved['rounds'] != 600000 ||
        saved['email'] is! String ||
        (saved['email'] as String).isEmpty) {
      return false;
    }
    try {
      return base64Url.decode(saved['salt'] as String).length == 24 &&
          base64Url.decode(saved['verifier'] as String).length == 32;
    } catch (_) {
      return false;
    }
  }

  Future<void> visit(Widget page) async {
    await openPage(context, page);
    if (mounted) setState(() => report = inspect());
  }

  Future<Map<String, dynamic>> inspect() async {
    final db = widget.store.db;
    final records = await db.query('records', where: 'deleted=0');
    final queue = await db.query('queue');
    final conflicts = await db.query('conflicts');
    final lessons = await db.query(
      'settings',
      where: 'key LIKE ?',
      whereArgs: ['learningCourse:%'],
    );
    var texts = 0, lessonBytes = 0, mapBytes = 0, readyMaps = 0;
    final readingIds = <String>{};
    final owner = await widget.store.setting('studentId');
    final ownedCourses = <String, Map>{};
    final coursePlans = <Map<String, dynamic>>[];
    final mapFarmIds = <String>{};
    int? freeBytes;
    if (!kIsWeb) {
      try {
        freeBytes = await const MethodChannel(
          'farmerplus/storage',
        ).invokeMethod<int>('freeBytes');
      } catch (_) {}
    }
    String? mapError;
    for (final row in lessons) {
      final saved = jsonDecode(row['value'] as String);
      if (saved is! Map || saved['owner'] != owner) continue;
      lessonBytes += utf8.encode(row['value'] as String).length;
      final id =
          '${saved['tenant'] ?? 'farmerplus'}:${saved['instance'] ?? 'farmerplus-learning'}:${saved['id']}';
      if (!ownedCourses.containsKey(id) ||
          (row['key'] as String).contains(':$owner:')) {
        ownedCourses[id] = saved;
      }
    }
    for (final saved in ownedCourses.values) {
      for (final section in saved['sections'] ?? []) {
        for (final resource in section['modules'] ?? []) {
          if (resource['offlineText'] != null) {
            readingIds.add('${saved['id']}:${resource['id']}');
          }
        }
      }
    }
    if (owner is String && RegExp(r'^[a-f0-9]{32}$').hasMatch(owner)) {
      final manager = CourseDownloads.of(widget.store);
      for (final course in await manager.all()) {
        final manifest = course['manifest'] as Map;
        final installed = course['installed'] as Map? ?? {};
        final validInstalled = <String, int>{};
        for (final entry in installed.entries) {
          if (entry.value is! Map) continue;
          final resource = Map<String, dynamic>.from(entry.value as Map);
          try {
            final bytes = await manager.readResource(resource);
            validInstalled['${entry.key}'] = bytes.length;
            lessonBytes += bytes.length;
            readingIds.add('${manifest['courseid']}:${resource['id']}');
          } catch (_) {
            // An incomplete or changed resource is reported as missing below.
          }
        }
        var missingBytes = 0, missingLessons = 0, onlineOnly = 0;
        for (final resource in manifest['activities'] ?? []) {
          if (resource['offline'] != true) {
            onlineOnly++;
            continue;
          }
          final file = installed['${resource['id']}'];
          final exists =
              file is Map &&
              file['sha256'] == resource['sha256'] &&
              validInstalled['${resource['id']}'] == resource['bytes'];
          if (!exists) {
            missingLessons++;
            missingBytes += (resource['bytes'] as num).toInt();
          }
        }
        coursePlans.add({
          'id': manifest['courseid'],
          'name': manifest['name'],
          'missingBytes': missingBytes,
          'missingLessons': missingLessons,
          'onlineOnly': onlineOnly,
          'state': CourseDownloads.label(course),
        });
      }
    }
    texts = readingIds.length;
    if (!kIsWeb) {
      try {
        for (final region in await getListOfRegions()) {
          final state = await getOfflineRegionStatus(region.id);
          mapBytes += state.completedResourceSize;
          final allowed = await widget.store.setting(
            'mapAuthorization:${region.id}',
          );
          if (state.isComplete && allowed != null) readyMaps++;
        }
      } catch (_) {
        mapError = 'Map availability could not be checked';
      }
    }
    for (final pack in await MapPacks(widget.store).list()) {
      final bytes = await mapPackBytes(pack);
      if (bytes != null) {
        readyMaps++;
        mapBytes += bytes;
        if (pack['farmId'] is String) mapFarmIds.add(pack['farmId']);
      }
    }
    var localBytes = 0;
    final localBytesKnown =
        !kIsWeb && widget.store.filesPath != 'browser-preview';
    if (localBytesKnown) {
      await for (final f in Directory(
        widget.store.filesPath,
      ).list(recursive: true, followLinks: false)) {
        if (f is File) localBytes += await f.length();
      }
    }
    final login = kIsWeb
        ? await browserLoginReady()
        : await OfflineAccess.info() != null;
    return {
      'records': records.length,
      'queue': queue.length,
      'conflicts': conflicts.length,
      'texts': texts,
      'lessonBytes': lessonBytes,
      'maps': readyMaps,
      'mapBytes': mapBytes,
      'mapError': mapError,
      'localBytes': localBytes,
      'localBytesKnown': localBytesKnown,
      'login': login,
      'loginMessage': kIsWeb
          ? login
                ? 'Ready in this browser'
                : 'Sign in online with your password first'
          : null,
      'device': kIsWeb ? 'browser' : 'phone',
      'freeBytes': freeBytes,
      'courses': coursePlans,
      'farmMaps': [
        for (final farm in await widget.store.records('farm'))
          {
            'id': farm['id'],
            'name': farm['data']['name'],
            'downloaded': mapFarmIds.contains(farm['id']),
          },
      ],
    };
  }

  String size(int value) => '${(value / 1048576).toStringAsFixed(1)} MB';
  @override
  Widget build(BuildContext c) => PageFrame(
    'Ready for offline',
    children: [
      note(
        'Check this before leaving connectivity. Downloads stay until you choose to remove them.',
      ),
      FutureBuilder<Map<String, dynamic>>(
        future: report,
        builder: (c, snapshot) {
          if (snapshot.hasError) {
            return const Text(
              'The check could not finish. Your saved work is unchanged.',
            );
          }
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final r = snapshot.data!;
          final plans = r['courses'] as List;
          final missingMaps = (r['farmMaps'] as List)
              .where((f) => f['downloaded'] != true)
              .toList();
          final missingCourses = plans
              .where((p) => p['missingLessons'] > 0)
              .toList();
          final knownMissingBytes = missingCourses.fold<int>(
            0,
            (n, p) => n + (p['missingBytes'] as int),
          );
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (missingMaps.isNotEmpty ||
                  missingCourses.isNotEmpty ||
                  r['texts'] == 0) ...[
                FilledButton.icon(
                  onPressed: () => visit(
                    missingMaps.isNotEmpty
                        ? MapDownloadsPage(
                            store: widget.store,
                            farmId: missingMaps.first['id'],
                          )
                        : missingCourses.isNotEmpty
                        ? CourseDownloadPage(
                            store: widget.store,
                            courseId: missingCourses.first['id'],
                          )
                        : LearningPage(store: widget.store),
                  ),
                  icon: const Icon(Icons.download_for_offline_outlined),
                  label: Text(
                    missingMaps.isNotEmpty
                        ? 'Prepare a farm map'
                        : 'Prepare lesson downloads',
                  ),
                ),
                const SizedBox(height: 8),
              ],
              Text(
                r['freeBytes'] == null
                    ? 'Free storage unavailable'
                    : '${size(r['freeBytes'])} free on this ${r['device']}',
              ),
              if (knownMissingBytes > 0)
                Text(
                  '${learningBytes(knownMissingBytes)} of missing or updated supported lessons',
                ),
              if (r['freeBytes'] != null && knownMissingBytes > r['freeBytes'])
                const Text(
                  'Free some space before downloading these lessons.',
                  style: TextStyle(color: Colors.red),
                ),
              const SizedBox(height: 12),
              ListTile(
                leading: const Icon(Icons.lock_outline),
                title: const Text('Offline sign in'),
                subtitle: Text(
                  r['loginMessage'] ??
                      (r['login']
                          ? 'Ready on this phone'
                          : 'Sign in online with your password first'),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.agriculture_outlined),
                title: Text('${r['records']} saved farm records'),
                subtitle: const Text(
                  'Available offline, including boundary drawing',
                ),
              ),
              ListTile(
                leading: const Icon(Icons.sync),
                title: Text(
                  r['queue'] == 0
                      ? 'No changes waiting to sync'
                      : '${r['queue']} changes waiting to sync',
                ),
                subtitle: Text('${r['conflicts']} conflicts need review'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () {
                  final engine = SyncEngine.activeFor(widget.store);
                  if (engine != null) {
                    visit(PendingSyncPage(store: widget.store, sync: engine));
                  }
                },
              ),
              for (final farm in r['farmMaps'])
                ListTile(
                  leading: Icon(
                    farm['downloaded'] == true
                        ? Icons.offline_pin_outlined
                        : Icons.download_outlined,
                  ),
                  title: Text(farm['name']),
                  subtitle: Text(
                    farm['downloaded'] == true
                        ? 'Farm map downloaded · check coverage'
                        : 'No download linked to this farm · choose coverage to check size',
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => visit(
                    MapDownloadsPage(store: widget.store, farmId: farm['id']),
                  ),
                ),
              ListTile(
                leading: const Icon(Icons.map_outlined),
                title: Text(
                  r['mapError'] ??
                      '${r['maps']} complete, authorised map regions',
                ),
                subtitle: Text(
                  '${size(r['mapBytes'])} downloaded map resources · coverage is limited to those regions',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => visit(MapDownloadsPage(store: widget.store)),
              ),
              for (final course in plans)
                ListTile(
                  leading: Icon(
                    course['missingLessons'] == 0
                        ? Icons.offline_pin_outlined
                        : Icons.downloading_outlined,
                  ),
                  title: Text(course['name']),
                  subtitle: Text(
                    '${course['state']}\n${course['missingLessons']} supported lessons missing or changed · ${learningBytes(course['missingBytes'])}\n${course['onlineOnly']} activities require internet',
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => visit(
                    CourseDownloadPage(
                      store: widget.store,
                      courseId: course['id'],
                    ),
                  ),
                ),
              ListTile(
                leading: const Icon(Icons.school_outlined),
                title: Text('${r['texts']} saved reading lessons'),
                subtitle: Text(
                  '${size(r['lessonBytes'])} lesson data · interactive Moodle activities require a connection',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => visit(LearningPage(store: widget.store)),
              ),
              ListTile(
                leading: const Icon(Icons.storage),
                title: const Text('Local app documents'),
                subtitle: Text(
                  r['localBytesKnown'] == true
                      ? '${size(r['localBytes'])} · maps and Android system storage are reported separately'
                      : 'Browser storage is reported in the saved maps and lessons above',
                ),
              ),
            ],
          );
        },
      ),
    ],
  );
}
