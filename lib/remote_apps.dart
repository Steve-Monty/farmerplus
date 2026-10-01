import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:sqflite/sqflite.dart';
import 'domain.dart';
import 'store.dart';
import 'sync.dart';
import 'remote_frame.dart';
import 'auth.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

/// Backend packages and app-owned data, isolated from the legacy record queue.
class RemoteApps extends ChangeNotifier {
  static final _instances = Expando<RemoteApps>();
  static RemoteApps of(FarmStore store) =>
      _instances[store] ??= RemoteApps(store);
  final FarmStore store;
  final SyncEngine? engine;
  bool downloading = false, syncing = false;
  int received = 0, total = 0;
  String phase = '';
  Timer? timer;
  Timer? recovery;
  final Map<String, int> _epochs = {};
  RemoteApps(this.store, {this.engine});
  void startRecovery() {
    if (recovery != null) return;
    recovery = Timer.periodic(const Duration(seconds: 30), (_) => recover());
    unawaited(recover());
  }

  void stopRecovery() {
    recovery?.cancel();
    recovery = null;
    timer?.cancel();
  }

  Future<void> recover() async {
    final engine = SyncEngine.activeFor(store);
    if (engine == null ||
        engine.disposed ||
        !engine.foreground ||
        AccountAccess.unlocked.value == null) {
      return;
    }
    try {
      final rows = await store.db.query(
        'settings',
        columns: ['key'],
        where: 'key LIKE ?',
        whereArgs: ['miniapp:data:%'],
      );
      for (final row in rows) {
        final id = (row['key'] as String).substring('miniapp:data:'.length);
        if (((await data(id))['queue'] as List).isNotEmpty) {
          await synchronize(id);
        }
      }
    } catch (_) {
      /* A closing workspace will recover on its next open. */
    }
  }

  @override
  void dispose() {
    stopRecovery();
    super.dispose();
  }

  SyncEngine get sync =>
      engine ??
      SyncEngine.activeFor(store) ??
      (throw StateError('Sign in to FarmerPlus first.'));
  String key(String id) => 'miniapp:data:$id';
  Future<Map<String, dynamic>> data(String id) async =>
      Map<String, dynamic>.from(
        await store.setting(key(id)) ??
            {
              'state': {
                'profiles': [],
                'events': [],
                'types': [],
                'breeds': [],
              },
              'revision': 0,
              'serverRevision': 0,
              'queue': [],
              'status': 'Saved on this device',
            },
      );
  Future<void> write(String id, Map<String, dynamic> value) =>
      store.setSetting(key(id), value);
  Future<List<MiniManifest>> available({bool refresh = false}) async {
    if (refresh) {
      final response = await sync.request('GET', '/api/v1/apps');
      await store.setSetting('miniapp:catalogue', response['apps']);
    }
    final rows = await store.setting('miniapp:catalogue') ?? [];
    return [
      for (final row in rows)
        MiniManifest(
          row['id'],
          row['title'],
          row['description'],
          row['category'] ?? 'Records',
          const {'farm', 'field'},
          const {},
          version: row['release']['version'],
          remote: true,
        ),
    ];
  }

  Future<Map<String, dynamic>?> listing(String id) async {
    final rows = await store.setting('miniapp:catalogue') ?? [];
    for (final row in rows) {
      if (row['id'] == id) return Map<String, dynamic>.from(row);
    }
    return null;
  }

  Future<Map<String, dynamic>> verifiedManifest(
    Map<String, dynamic> envelope,
    String id,
    int version,
  ) async {
    final trust =
        jsonDecode(await rootBundle.loadString('assets/miniapps/trust.json'))
            as Map;
    final key = trust[envelope['keyId']];
    if (key is! String) {
      throw StateError(
        'This app publisher is not trusted by this FarmerPlus version.',
      );
    }
    final signed =
        jsonDecode(
              await verifyMiniSignature(
                envelope['signed'],
                envelope['signature'],
                key,
              ),
            )
            as Map;
    if (signed['appId'] != id ||
        signed['version'] != version ||
        signed['sdk'] != 1 ||
        signed['ruleVersion'] != 1 ||
        signed['bytes'] is! int ||
        signed['bytes'] <= 0 ||
        signed['bytes'] > 4 * 1024 * 1024) {
      throw StateError('The package identity, size or SDK is not compatible.');
    }
    return Map<String, dynamic>.from(signed);
  }

  Future<void> install(
    MiniManifest app, {
    required bool Function() cancelled,
  }) async {
    if (downloading) {
      throw StateError('Another app download is already running.');
    }
    downloading = true;
    final epoch = _epochs[app.id] ?? 0;
    phase = 'Checking release';
    notifyListeners();
    try {
      final envelope = Map<String, dynamic>.from(
        await sync.request(
          'GET',
          '/api/v1/apps/${app.id}/releases/${app.version}/manifest',
        ),
      );
      final manifest = await verifiedManifest(envelope, app.id, app.version);
      final existing = await store.setting('miniapp:manifest:${app.id}');
      if (existing != null && existing['version'] > app.version) {
        throw StateError(
          'Keep the installed newer version. Downgrading data is not supported.',
        );
      }
      final staged = await store.setting('miniapp:download:${app.id}');
      var bytes = <int>[];
      if (staged is Map && staged['sha'] == manifest['sha256']) {
        bytes = base64Decode(staged['bytes']).toList();
      }
      total = manifest['bytes'];
      received = bytes.length;
      if (received > total) {
        bytes = [];
        received = 0;
      }
      phase = 'Downloading';
      notifyListeners();
      while (bytes.length < total) {
        if (cancelled() || (_epochs[app.id] ?? 0) != epoch) {
          phase = 'Download paused';
          return;
        }
        final chunk = await sync.request(
          'GET',
          '/api/v1/apps/${app.id}/releases/${app.version}/package?offset=${bytes.length}',
        );
        final part = base64Decode(chunk['chunk']);
        if (chunk['offset'] != bytes.length ||
            chunk['total'] != total ||
            chunk['sha256'] != manifest['sha256'] ||
            part.isEmpty ||
            bytes.length + part.length > total) {
          throw StateError(
            'Download changed or was incomplete. Retry this release.',
          );
        }
        bytes.addAll(part);
        received = bytes.length;
        await store.setSetting('miniapp:download:${app.id}', {
          'sha': manifest['sha256'],
          'bytes': base64Encode(bytes),
        });
        notifyListeners();
      }
      phase = 'Checking download';
      notifyListeners();
      if (sha256.convert(bytes).toString() != manifest['sha256']) {
        await store.setSetting('miniapp:download:${app.id}', null);
        throw StateError('Download integrity failed. Please download again.');
      }
      final raw = utf8.decode(bytes), package = jsonDecode(raw);
      if (package['id'] != app.id ||
          package['version'] != app.version ||
          package['format'] != 1 ||
          package['sdk'] != 1 ||
          package['html'] is! String) {
        throw StateError('Invalid app package.');
      }
      if (cancelled() || (_epochs[app.id] ?? 0) != epoch) {
        phase = 'Download paused';
        return;
      }
      phase = 'Installing';
      notifyListeners();
      await store.appLifecycle(
        () => store.db.transaction((tx) async {
          if ((_epochs[app.id] ?? 0) != epoch) {
            throw StateError('App installation was cancelled.');
          }
          for (final entry in {
            'miniapp:package:${app.id}': raw,
            'miniapp:manifest:${app.id}': envelope,
            'miniapp:download:${app.id}': null,
            'removedApp:${app.id}': false,
          }.entries) {
            await tx.insert('settings', {
              'key': entry.key,
              'value': jsonEncode(entry.value),
            }, conflictAlgorithm: ConflictAlgorithm.replace);
          }
          await tx.insert('installs', {
            'id': app.id,
            'version': app.version,
            'bytes': total,
            'total': total,
            'sha': manifest['sha256'],
            'state': 'ready',
          }, conflictAlgorithm: ConflictAlgorithm.replace);
        }),
      );
      phase = 'Ready offline';
      store.notifyListeners();
      await report(app.id, app.version, 'Installed');
    } finally {
      downloading = false;
      notifyListeners();
    }
  }

  Future<String> document(String id) async {
    final raw = await store.setting('miniapp:package:$id'),
        envelope = await store.setting('miniapp:manifest:$id');
    if (raw is! String || envelope is! Map) {
      throw StateError('Install this app before opening it.');
    }
    final signed = await verifiedManifest(
      Map<String, dynamic>.from(envelope),
      id,
      envelope['version'],
    );
    if (sha256.convert(utf8.encode(raw)).toString() != signed['sha256']) {
      throw StateError(
        'The saved app is incomplete. Reinstall it to keep your records and repair the app.',
      );
    }
    return jsonDecode(raw)['html'];
  }

  Future<void> report(String id, int version, String state) async {
    try {
      final installation =
          await store.setting('miniapp:installation:$id') ?? uuid.v4();
      await store.setSetting('miniapp:installation:$id', installation);
      await sync.request(
        'PUT',
        '/api/v1/apps/$id/installations/$installation',
        body: {
          'version': version,
          'state': state,
          'deviceId': await deviceId(),
        },
      );
    } catch (_) {
      /* Device inventory is best effort; local install is already committed. */
    }
  }

  Future<String> deviceId() async {
    final old = await store.setting('miniapp:device');
    if (old is String) return old;
    final id = uuid.v4();
    await store.setSetting('miniapp:device', id);
    return id;
  }

  Future<void> remove(String id) async {
    _epochs[id] = (_epochs[id] ?? 0) + 1;
    final envelope = await store.setting('miniapp:manifest:$id');
    await store.appLifecycle(
      () => store.db.transaction((tx) async {
        await tx.delete('installs', where: 'id=?', whereArgs: [id]);
        for (final suffix in ['package', 'manifest', 'download']) {
          await tx.delete(
            'settings',
            where: 'key=?',
            whereArgs: ['miniapp:$suffix:$id'],
          );
        }
        await tx.insert('settings', {
          'key': 'removedApp:$id',
          'value': 'true',
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }),
    );
    store.notifyListeners();
    notifyListeners();
    if (envelope != null) await report(id, envelope['version'], 'Removed');
  }

  Future<void> enqueue(
    String id,
    Map<String, dynamic> command,
    Map<String, dynamic> state,
  ) async {
    await store.appLifecycle(() async {
      final saved = await data(id);
      if (saved['conflict'] != null) {
        throw StateError('Review pending changes in Animal options first.');
      }
      if (command['expectedRevision'] != saved['revision']) {
        throw StateError(
          'Records changed. Return to the animal and review again; your draft is kept.',
        );
      }
      if (jsonEncode(command).length > 64000 ||
          jsonEncode(state).length > 8 * 1024 * 1024) {
        throw StateError('This app record is too large.');
      }
      await write(id, {
        ...saved,
        'state': state,
        'revision': saved['revision'] + 1,
        'queue': [...saved['queue'], command],
        'status': 'Saved on this device · waiting to sync',
      });
    });
    notifyListeners();
    timer?.cancel();
    timer = Timer(const Duration(seconds: 2), () => synchronize(id));
  }

  Future<void> synchronize(String id, {bool explicit = false}) async {
    final engine = this.engine ?? SyncEngine.activeFor(store);
    if (syncing ||
        engine == null ||
        engine.disposed ||
        engine.busy ||
        engine.credentialChangeInProgress) {
      return;
    }
    final owner = AccountAccess.unlocked.value,
        revision = engine.credentialRevision;
    if (owner == null || owner != await store.setting('accessOwner')) return;
    bool current() =>
        !engine.disposed &&
        !engine.credentialChangeInProgress &&
        engine.credentialRevision == revision &&
        AccountAccess.unlocked.value == owner;
    final mode = await store.setting('syncMode');
    if (!explicit && mode == 'manual') return;
    if (!explicit && mode == 'wifi') {
      final networks = await Connectivity().checkConnectivity();
      if (!networks.contains(ConnectivityResult.wifi)) return;
    }
    if (!current()) return;
    syncing = true;
    try {
      // Existing shared records (new farms/areas) must reach the server first.
      if ((await store.db.query('queue')).isNotEmpty) {
        await sync.sync();
      }
      if ((await store.db.query('queue')).isNotEmpty) return;
      if (!current()) return;
      var saved = await data(id);
      if (saved['conflict'] != null) return;
      while ((saved['queue'] as List).isNotEmpty) {
        if (!current()) return;
        final command = saved['queue'].first as Map;
        for (final value in [
          command['payload']?['photo'],
          command['payload']?['replacement']?['photo'],
        ]) {
          if (value is String && value.isNotEmpty) await sync.upload(value);
        }
        final result = await sync.request(
          'POST',
          '/api/v1/apps/$id/commands',
          body: command,
        );
        await store.appLifecycle(() async {
          if (!current()) return;
          final latest = await data(id);
          final queue = List<dynamic>.from(latest['queue']);
          if (queue.isEmpty ||
              queue.first['operationId'] != command['operationId']) {
            return;
          }
          queue.removeAt(0);
          await write(id, {
            ...latest,
            'queue': queue,
            'serverRevision': result['revision'],
            if (queue.isEmpty) 'state': result['state'],
            if (queue.isEmpty) 'revision': result['revision'],
            'status': queue.isEmpty
                ? 'Synced'
                : 'Saved on this device · waiting to sync',
          });
        });
        saved = await data(id);
      }
      if (!current()) return;
      final snapshot = await sync.request('GET', '/api/v1/apps/$id/records');
      await store.appLifecycle(() async {
        if (!current()) return;
        final latest = await data(id);
        if ((latest['queue'] as List).isEmpty) {
          await write(id, {
            ...latest,
            'state': snapshot['state'],
            'revision': snapshot['revision'],
            'serverRevision': snapshot['revision'],
            'status': 'Synced',
          });
        }
      });
    } on SyncRequestError catch (e) {
      if (!current()) return;
      await store.appLifecycle(() async {
        final saved = await data(id);
        await write(id, {
          ...saved,
          'status': {409, 422}.contains(e.statusCode)
              ? 'Needs review'
              : 'Saved on this device · waiting to sync',
          if ({409, 422}.contains(e.statusCode)) 'conflict': e.message,
        });
      });
    } catch (_) {
      if (!current()) return;
      await store.appLifecycle(() async {
        final saved = await data(id);
        await write(id, {
          ...saved,
          'status': 'Saved on this device · waiting to sync',
        });
      });
    } finally {
      syncing = false;
      notifyListeners();
    }
  }
}
