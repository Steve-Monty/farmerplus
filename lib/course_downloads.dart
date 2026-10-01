import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;
import 'package:http/http.dart' as http;
import 'store.dart';
import 'sync.dart';
import 'course_download_storage.dart';

String learningBytes(num size) => size < 1024
    ? '$size B'
    : size < 1048576
    ? '${(size / 1024).toStringAsFixed(1)} KB'
    : '${(size / 1048576).toStringAsFixed(1)} MB';
typedef DownloadRequest = Future<Map<String, dynamic>> Function(String route);

class CourseDownloads extends ChangeNotifier {
  static final _instances = Expando<CourseDownloads>();
  static CourseDownloads of(FarmStore store) =>
      _instances[store] ??= CourseDownloads(store);
  final FarmStore store;
  final DownloadRequest? requester;
  final Future<List<ConnectivityResult>> Function()? connectivity;
  late final CourseDownloadStorage storage = CourseDownloadStorage(
    store.filesPath,
  );
  bool running = false;
  Timer? timer;
  StreamSubscription? connection;
  CourseDownloads(this.store, {this.requester, this.connectivity});
  Future<Map<String, dynamic>> request(String route) async {
    if (requester != null) return requester!(route);
    final engine = SyncEngine(store);
    try {
      return Map<String, dynamic>.from(await engine.request('GET', route));
    } finally {
      engine.client.close();
    }
  }

  Future<String> binding() async {
    final owner = await store.setting('studentId');
    if (owner is! String || !RegExp(r'^[a-f0-9]{32}$').hasMatch(owner)) {
      throw StateError('Sign in before managing course downloads.');
    }
    final server =
        await store.setting('boundServer') ??
        await store.setting('server') ??
        'https://app.agritec.earth';
    return sha256
        .convert(
          utf8.encode(
            '$owner|farmerplus|farmerplus-learning|https://learn.agritec.earth|$server',
          ),
        )
        .toString();
  }

  Future<String> key(int id) async => 'courseDownload:${await binding()}:$id';
  Future<Map<String, dynamic>?> state(int id) async {
    final value = await store.setting(await key(id));
    return value is Map ? Map<String, dynamic>.from(value) : null;
  }

  Future<void> write(int id, Map<String, dynamic> data) async {
    await store.setSetting(await key(id), data);
    notifyListeners();
  }

  Future<Map<String, dynamic>> manifest(int id) async {
    final m = await request('/learning/manifest/$id');
    if (m['schema'] != 1 ||
        m['courseid'] != id ||
        m['farmerplus_id'] != await store.setting('studentId') ||
        m['tenant_id'] != 'farmerplus' ||
        m['instance_id'] != 'farmerplus-learning' ||
        m['learning_origin'] != 'https://learn.agritec.earth' ||
        m['offline_enabled'] != true ||
        m['activities'] is! List ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(m['version'] ?? '')) {
      throw StateError('This download does not match your Learning account.');
    }
    for (final r in m['activities']) {
      if (r['offline'] == true &&
          (r['id'] is! int ||
              r['bytes'] is! int ||
              r['bytes'] <= 0 ||
              r['bytes'] > 9 * 1024 * 1024 ||
              r['format'] != 'text/html' ||
              !RegExp(r'^[a-f0-9]{64}$').hasMatch(r['sha256'] ?? ''))) {
        throw StateError('The download manifest is incomplete.');
      }
    }
    final old = await state(id) ?? {};
    await write(id, {
      ...old,
      'manifest': m,
      'installed': old['installed'] ?? {},
      'state': old['state'] ?? 'idle',
    });
    return m;
  }

  Future<void> enqueue(
    int id,
    Map<String, dynamic> m,
    Set<int> selected, {
    bool mobileData = false,
    int? availableBytes,
  }) async {
    if (m['farmerplus_id'] != await store.setting('studentId') ||
        m['courseid'] != id ||
        m['tenant_id'] != 'farmerplus' ||
        m['instance_id'] != 'farmerplus-learning' ||
        m['learning_origin'] != 'https://learn.agritec.earth') {
      throw StateError('Account changed. Open the download choices again.');
    }
    final eligible = (m['activities'] as List)
        .where((r) => r['offline'] == true)
        .map((r) => r['id'] as int)
        .toSet();
    if (selected.isEmpty || !eligible.containsAll(selected)) {
      throw StateError('Choose supported lessons.');
    }
    final previous = await state(id) ?? {};
    final installed = Map<String, dynamic>.from(previous['installed'] ?? {});
    final resources = (m['activities'] as List)
        .where((r) => selected.contains(r['id']))
        .toList();
    final missing = resources
        .where((r) => installed['${r['id']}']?['sha256'] != r['sha256'])
        .fold<int>(0, (n, r) => n + (r['bytes'] as int));
    final free =
        availableBytes ??
        (kIsWeb
            ? null
            : await const MethodChannel(
                'farmerplus/storage',
              ).invokeMethod<int>('freeBytes'));
    if (free != null && free < missing + 16 * 1024 * 1024) {
      throw StateError('Not enough free storage. Free some space and retry.');
    }
    // A new job never deletes the old installed version. Resource commits are atomic.
    await write(id, {
      ...previous,
      'manifest': m,
      'jobManifest': m,
      'selected': selected.toList(),
      'installed': installed,
      'state': 'queued',
      'mobileData': mobileData,
      'error': null,
      'bytesReceived': 0,
    });
    unawaited(pump());
  }

  void start() {
    timer ??= Timer.periodic(const Duration(seconds: 15), (_) => pump());
    connection ??= Connectivity().onConnectivityChanged.listen((_) => pump());
    unawaited(pump());
  }

  Future<void> command(int id, String command) async {
    final s = await state(id);
    if (s == null) return;
    if (!{'paused', 'queued', 'cancelled'}.contains(command)) {
      throw StateError('Unknown download action.');
    }
    await write(id, {...s, 'state': command, 'error': null});
    if (command == 'queued') unawaited(pump());
    if (command == 'cancelled') {
      RandomAccessFile? lock;
      try {
        if (!kIsWeb) {
          lock = await File(
            path.join(store.filesPath, 'learning-download.lock'),
          ).open(mode: FileMode.append);
          await lock.lock(FileLock.exclusive);
        }
        await storage.removeCourse(await binding(), id, partialsOnly: true);
      } finally {
        await lock?.close();
      }
    }
  }

  Future<void> allowMobile(int id) async {
    final s = await state(id);
    if (s != null) {
      await write(id, {...s, 'mobileData': true, 'state': 'queued'});
      unawaited(pump());
    }
  }

  Future<List<Map<String, dynamic>>> all() async {
    final prefix = 'courseDownload:${await binding()}:';
    final rows = await store.db.query(
      'settings',
      where: 'key LIKE ?',
      whereArgs: ['$prefix%'],
    );
    return rows
        .map((r) => Map<String, dynamic>.from(jsonDecode(r['value'] as String)))
        .toList();
  }

  Future<void> pump() async {
    if (running) return;
    running = true;
    RandomAccessFile? lock;
    try {
      final account = await binding();
      if (!kIsWeb) {
        lock = await File(
          path.join(store.filesPath, 'learning-download.lock'),
        ).open(mode: FileMode.append);
        await lock.lock(FileLock.exclusive);
      }
      for (final job in await all()) {
        if (![
          'queued',
          'downloading',
          'waitingWifi',
          'waitingConnection',
        ].contains(job['state'])) {
          continue;
        }
        if (account != await binding()) break;
        await runCourse(job['manifest']['courseid'] as int, account);
      }
    } catch (_) {
      /* An account may be locked. Durable jobs resume after sign-in. */
    } finally {
      await lock?.close();
      running = false;
      notifyListeners();
    }
  }

  Future<void> runCourse(int id, String account) async {
    try {
      while (true) {
        if (account != await binding()) return;
        var s = await state(id);
        if (s == null ||
            ![
              'queued',
              'downloading',
              'waitingWifi',
              'waitingConnection',
            ].contains(s['state'])) {
          return;
        }
        final networks =
            await (connectivity?.call() ?? Connectivity().checkConnectivity());
        if (networks.contains(ConnectivityResult.none)) {
          await write(id, {...s, 'state': 'waitingConnection'});
          return;
        }
        if (s['mobileData'] != true &&
            !networks.contains(ConnectivityResult.wifi)) {
          await write(id, {...s, 'state': 'waitingWifi'});
          return;
        }
        final m = s['jobManifest'] as Map;
        final installed = Map<String, dynamic>.from(s['installed'] ?? {});
        final selected = List<int>.from(s['selected']);
        final resources = (m['activities'] as List)
            .where((r) => selected.contains(r['id']))
            .toList();
        Map<String, dynamic>? next;
        for (final raw in resources) {
          final r = Map<String, dynamic>.from(raw);
          final old = installed['${r['id']}'];
          final reference = old?['storageKey'] ?? old?['path'];
          if (old == null ||
              old['sha256'] != r['sha256'] ||
              reference is! String ||
              !await storage.exists(reference)) {
            next = r;
            break;
          }
        }
        if (next == null) {
          await write(id, {
            ...s,
            'state': 'complete',
            'error': null,
            'bytesReceived': 0,
          });
          return;
        }
        final r = next;
        final storageKey =
            '$account/$id/${m['version']}/${r['id']}-${r['sha256']}.html';
        var offset = await storage.partialLength(storageKey);
        if (offset > r['bytes']) {
          await storage.resetPartial(storageKey);
          offset = 0;
        }
        await write(id, {
          ...s,
          'state': 'downloading',
          'current': r['name'],
          'currentId': r['id'],
          'bytesReceived': offset,
        });
        if (offset < r['bytes']) {
          final chunk = await request(
            '/learning/download/${r['id']}?offset=$offset&version=${r['sha256']}',
          );
          if (chunk['cmid'] != r['id'] ||
              chunk['sha256'] != r['sha256'] ||
              chunk['offset'] != offset ||
              chunk['total'] != r['bytes'] ||
              chunk['data'] is! String) {
            throw StateError(
              'The lesson changed. Refresh downloads to get its new version.',
            );
          }
          final bytes = base64Decode(chunk['data']);
          if (bytes.isEmpty ||
              bytes.length > 65536 ||
              offset + bytes.length > r['bytes']) {
            throw StateError('The downloaded file is incomplete.');
          }
          if (account != await binding()) return;
          // Honour a pause/cancel before writing, and preserve it if it arrives during the write.
          s = await state(id);
          if (s == null || !['downloading', 'queued'].contains(s['state'])) {
            return;
          }
          if (s['jobManifest']['version'] != m['version']) return;
          await storage.appendPartial(storageKey, bytes);
          offset += bytes.length;
        }
        if (account != await binding()) return;
        s = await state(id);
        if (s == null ||
            !['downloading', 'queued'].contains(s['state']) ||
            s['jobManifest']['version'] != m['version']) {
          return;
        }
        if (offset == r['bytes']) {
          if (sha256
                  .convert(await storage.readPartial(storageKey))
                  .toString() !=
              r['sha256']) {
            await storage.resetPartial(storageKey);
            throw StateError(
              'Verification failed. Your previous download is still available.',
            );
          }
          final reference = await storage.commitPartial(storageKey);
          installed['${r['id']}'] = {
            ...r,
            'path': reference,
            'storageKey': storageKey,
            'courseVersion': m['version'],
          };
          await write(id, {...s, 'installed': installed, 'bytesReceived': 0});
        } else {
          await write(id, {...s, 'bytesReceived': offset});
        }
      }
    } catch (e) {
      if (account != await binding()) return;
      final s = await state(id);
      if (s == null || ['paused', 'cancelled'].contains(s['state'])) return;
      final transient =
          e is SocketException ||
          e is http.ClientException ||
          e is TimeoutException ||
          e is SyncTransportError ||
          (e is SyncRequestError && e.statusCode >= 500);
      await write(id, {
        ...s,
        'state': transient ? 'waitingConnection' : 'paused',
        'error': e.toString().replaceFirst('Bad state: ', ''),
      });
    }
  }

  Future<Map<String, dynamic>?> savedCourse(int id) async {
    final s = await state(id);
    if (s == null) return null;
    final m = s['manifest'];
    final installed = s['installed'] ?? {};
    final sections = <int, Map<String, dynamic>>{};
    for (final r in m['activities']) {
      final sid = (r['section_id'] ?? 0) as int;
      sections.putIfAbsent(
        sid,
        () => {'name': r['section'] ?? 'Lessons', 'modules': <dynamic>[]},
      );
      final saved = installed['${r['id']}'];
      final reference = saved?['storageKey'] ?? saved?['path'];
      final exists =
          saved != null &&
          reference is String &&
          await storage.exists(reference);
      (sections[sid]!['modules'] as List).add({
        ...r,
        'modname': r['type'],
        'url': r['launch_url'],
        if (exists) 'offlineHtml': saved,
      });
    }
    // Removed/restructured resources remain discoverable until explicitly removed.
    final archived = <dynamic>[];
    for (final r in installed.values) {
      final reference = r['storageKey'] ?? r['path'];
      if (!(m['activities'] as List).any((a) => a['id'] == r['id']) &&
          reference is String &&
          await storage.exists(reference)) {
        archived.add({
          ...r,
          'modname': r['type'],
          'url': r['launch_url'],
          'offlineHtml': r,
        });
      }
    }
    if (archived.isNotEmpty) {
      sections[-1] = {
        'name': 'Earlier downloaded lessons',
        'modules': archived,
      };
    }
    return {
      'id': id,
      'owner': await store.setting('studentId'),
      'sections': sections.values.toList(),
      'downloadState': s,
    };
  }

  static String label(Map<String, dynamic> s) {
    if (s['state'] == 'waitingWifi') return 'Waiting for Wi-Fi';
    if (s['state'] == 'waitingConnection') return 'Waiting for connection';
    if (s['state'] == 'downloading' || s['state'] == 'queued') {
      return 'Downloading';
    }
    final m = s['manifest'] as Map;
    if (s['state'] == 'paused') return 'Download paused';
    final items = m['activities'] as List;
    final installed = s['installed'] as Map? ?? {};
    final count = items
        .where((r) => installed.containsKey('${r['id']}'))
        .length;
    if (items.any(
      (r) =>
          installed['${r['id']}'] != null &&
          r['sha256'] != installed['${r['id']}']['sha256'],
    )) {
      return 'Update available';
    }
    if (count == items.length && count > 0) return 'Fully available offline';
    return count == 0
        ? 'Not downloaded'
        : 'Partly downloaded — $count of ${items.length} lessons';
  }

  Future<void> remove(int id, {Set<int>? resources}) async {
    await command(id, 'cancelled');
    // Worker checks command between bounded chunks. Its lock protects removal from an in-flight commit.
    RandomAccessFile? lock;
    try {
      if (!kIsWeb) {
        lock = await File(
          path.join(store.filesPath, 'learning-download.lock'),
        ).open(mode: FileMode.append);
        await lock.lock(FileLock.exclusive);
      }
      final s = await state(id);
      if (s == null) return;
      final installed = Map<String, dynamic>.from(s['installed'] ?? {});
      final ids = resources ?? installed.keys.map(int.parse).toSet();
      for (final key in installed.keys.toList()) {
        if (!ids.contains(int.parse(key))) continue;
        installed.remove(key);
      }
      // Delete every stored version and partial for explicitly selected resources.
      // Enrolment and reading-progress rows remain in the workspace database.
      await storage.removeCourse(await binding(), id, resources: resources);
      await write(id, {
        ...s,
        'installed': installed,
        'state': 'idle',
        'selected': [],
        'bytesReceived': 0,
      });
    } finally {
      await lock?.close();
    }
  }

  Future<List<int>> readResource(Map<String, dynamic> resource) async {
    final reference = resource['storageKey'] ?? resource['path'];
    if (reference is! String || !await storage.exists(reference)) {
      throw StateError('This saved lesson needs downloading again.');
    }
    final bytes = await storage.read(reference);
    if (bytes.length != resource['bytes'] ||
        sha256.convert(bytes).toString() != resource['sha256']) {
      throw StateError('This saved lesson needs downloading again.');
    }
    return bytes;
  }

  @override
  void dispose() {
    timer?.cancel();
    connection?.cancel();
    super.dispose();
  }
}
