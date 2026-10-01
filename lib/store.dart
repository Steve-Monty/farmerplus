import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import 'package:crypto/crypto.dart';
import 'domain.dart';
import 'taxonomy.dart';
import 'business_rules.dart';
import 'place_colors.dart';
import 'account_workspaces.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

const uuid = Uuid();

class FarmStore extends ChangeNotifier {
  final Database db;
  final String filesPath;
  FarmStore(this.db, this.filesPath);
  Future<Uint8List?> mediaBytes(String hash) async {
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(hash)) {
      throw StateError('Invalid attachment reference.');
    }
    if (kIsWeb) {
      final value = await setting('browserMedia:$hash');
      return value is String ? base64Decode(value) : null;
    }
    final file = File(path.join(filesPath, 'media', hash));
    return await file.exists() ? file.readAsBytes() : null;
  }

  static final Map<String, Future<void>> _lifecycleTails = {};
  Future<T> appLifecycle<T>(Future<T> Function() action) async {
    final prior = _lifecycleTails[filesPath] ?? Future.value();
    final done = Completer<void>();
    _lifecycleTails[filesPath] = done.future;
    await prior;
    RandomAccessFile? lifecycleLock;
    try {
      if (!kIsWeb) {
        lifecycleLock = await File(
          path.join(filesPath, 'app-lifecycle.lock'),
        ).open(mode: FileMode.append);
        await lifecycleLock.lock(FileLock.exclusive);
      }
      return await action();
    } finally {
      await lifecycleLock?.close();
      if (_lifecycleTails[filesPath] == done.future) {
        _lifecycleTails.remove(filesPath);
      }
      done.complete();
    }
  }

  static Future<FarmStore> open({
    DatabaseFactory? factory,
    String? dbPath,
    String? filesPath,
    bool singleInstance = true,
  }) async {
    final f = factory ?? databaseFactory;
    final root =
        filesPath ??
        await AccountWorkspaces.activeRoot(
          (await getApplicationDocumentsDirectory()).path,
        );
    await Directory(root).create(recursive: true);
    final db = await f.openDatabase(
      dbPath ?? path.join(root, 'farm.sqlite'),
      options: OpenDatabaseOptions(
        version: 1,
        singleInstance: singleInstance,
        onCreate: (db, v) async {
          await db.execute(
            'CREATE TABLE settings (key TEXT PRIMARY KEY,value TEXT NOT NULL)',
          );
          await db.execute(
            'CREATE TABLE records (id TEXT PRIMARY KEY,kind TEXT NOT NULL,data TEXT NOT NULL,version INTEGER NOT NULL DEFAULT 0,deleted INTEGER NOT NULL DEFAULT 0,updated TEXT NOT NULL)',
          );
          await db.execute(
            'CREATE TABLE queue (id TEXT PRIMARY KEY,op_id TEXT NOT NULL,base_version INTEGER NOT NULL,data TEXT NOT NULL,kind TEXT NOT NULL,deleted INTEGER NOT NULL)',
          );
          await db.execute(
            'CREATE TABLE conflicts (id TEXT PRIMARY KEY,remote TEXT NOT NULL)',
          );
          await db.execute(
            'CREATE TABLE installs (id TEXT PRIMARY KEY,version INTEGER NOT NULL,bytes INTEGER NOT NULL,total INTEGER NOT NULL,sha TEXT NOT NULL,state TEXT NOT NULL)',
          );
        },
      ),
    );
    final s = FarmStore(db, root);
    if (await s.setting('farmerId') == null) {
      await s.setSetting('farmerId', uuid.v4());
    }
    return s;
  }

  Future<dynamic> setting(String key) async {
    if (key == 'primaryActivity' || key == 'optionalEmail') {
      final profiles = await records('profile');
      if (profiles.isNotEmpty) {
        return profiles.first['data'][key == 'optionalEmail' ? 'email' : key];
      }
    }
    if (syncedPreferences.contains(key)) {
      final record = await get(preferenceId(key));
      if (record != null && record['deleted'] != 1)
        return record['data']['value'];
    }

    final rows = await db.query('settings', where: 'key=?', whereArgs: [key]);
    return rows.isEmpty ? null : jsonDecode(rows.first['value'] as String);
  }

  static const syncedPreferences = {
    'weatherEnabled',
    'weatherHere',
    'selectedFarm',
    'areaUnit',
    'mappingLanguage',
    'reminders',
    'syncMode',
    'wallpaperPreset',
    'homeHighContrast',
    'animateIcons',
    'launcherOrder',
    'appOrder',
    'glassOpacity',
    'themeMode',
  };
  String preferenceId(String key) =>
      uuid.v5(Uuid.NAMESPACE_URL, 'https://farmerplus.earth/preferences/$key');

  Future<void> setSetting(String key, dynamic value) async {
    if (syncedPreferences.contains(key)) {
      if (jsonEncode(await setting(key)) == jsonEncode(value)) return;
      await save(
        'preference',
        {'key': key, 'value': value},
        id: preferenceId(key),
        settings: {key: value},
      );
      return;
    }

    await db.insert('settings', {
      'key': key,
      'value': jsonEncode(value),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    notifyListeners();
  }

  Map<String, dynamic> decode(Map<String, Object?> r) => {
    ...r,
    'data': jsonDecode(r['data'] as String),
  };
  Future<List<Map<String, dynamic>>> records(
    String kind, {
    MiniManifest? scope,
  }) async {
    if (scope != null && !scope.permits(kind)) {
      throw StateError('Permission denied: $kind');
    }
    final result = (await db.query(
      'records',
      where: 'kind=? AND deleted=0',
      whereArgs: [kind],
      orderBy: 'updated DESC',
    )).map(decode).toList();
    if (kind == 'farm' || kind == 'field') {
      for (final record in result) {
        final issue = await geometryIssue(record);
        if (issue != null) record['geometryIssue'] = issue;
      }
    }
    return result;
  }

  Future<Map<String, dynamic>?> get(String id) async {
    final rows = await db.query('records', where: 'id=?', whereArgs: [id]);
    return rows.isEmpty ? null : decode(rows.first);
  }

  Future<String> save(
    String kind,
    Map<String, dynamic> data, {
    String? id,
    MiniManifest? scope,
    bool deleted = false,
    Map<String, dynamic> settings = const {},
  }) async {
    if (scope != null && !scope.permits(kind, writing: true)) {
      throw StateError('Permission denied: $kind');
    }
    if (!{
      'profile',
      'preference',
      'farm',
      'field',
      'diary',
      'task',
      'progress',
      'inbox',
      'season',
      'stock',
      'stockmove',
      'harvest',
      'sale',
      'guideprogress',
      'pin',
      'calculation',
    }.contains(kind)) {
      throw StateError('Record kind is not syncable');
    }
    final appId = owningApp(kind);
    if (appId != null && await setting('removedApp:$appId') == true) {
      throw StateError('This app was removed. Reinstall it before saving.');
    }
    final key = id ?? uuid.v4();
    if (!deleted && (kind == 'farm' || kind == 'field')) {
      final p = polygonPoints(data);
      data = {...data, 'areaM2': area(p), 'perimeterM': perimeter(p)};
    }
    await db.transaction((tx) async {
      if (appId != null) {
        final flags = await tx.query(
          'settings',
          where: 'key=?',
          whereArgs: ['removedApp:$appId'],
        );
        if (flags.isNotEmpty &&
            jsonDecode(flags.first['value'] as String) == true) {
          throw StateError('This app was removed. Reinstall it before saving.');
        }
      }
      await validateGeometry(tx, key, kind, data, deleted);
      if (kind == 'farm' || kind == 'field') {
        final apps = await tx.query(
          'settings',
          where: 'key LIKE ?',
          whereArgs: ['miniapp:data:%'],
        );
        for (final app in apps) {
          final saved = jsonDecode(app['value'] as String);
          for (final animal in saved['state']['profiles']) {
            if (animal['active'] != true) continue;
            final referenced =
                animal[kind == 'farm' ? 'farmId' : 'locationId'] == key;
            if (referenced &&
                (deleted ||
                    (kind == 'field' && animal['farmId'] != data['farmId']))) {
              throw StateError(
                'Move the animals at this location before removing it or changing its farm.',
              );
            }
          }
        }
      }
      await validateBusiness(tx, key, kind, data, deleted);
      if (!deleted &&
          kind == 'pin' &&
          data['farmId'] != null &&
          data['farmId'] != '') {
        data = Map<String, dynamic>.from(data);
        final pins = (await tx.query(
          'records',
          where: 'kind=? AND deleted=0 AND id<>?',
          whereArgs: ['pin', key],
        )).map(decode).toList();
        final prior = await tx.query(
          'records',
          where: 'id=?',
          whereArgs: [key],
        );
        final priorColor = prior.isEmpty
            ? null
            : decode(prior.first)['data']['color'];
        final used = resolvePlaceColors(pins).values.toSet();
        data['color'] = validPlaceColor(priorColor)
            ? priorColor
            : validPlaceColor(data['color']) &&
                  !used.contains((data['color'] as String).toLowerCase())
            ? (data['color'] as String).toLowerCase()
            : unusedPlaceColor(key, used);
      }
      final old = await tx.query('records', where: 'id=?', whereArgs: [key]);
      if (old.isNotEmpty && old.first['kind'] != kind) {
        throw StateError('Record type cannot change');
      }
      final version = old.isEmpty ? 0 : old.first['version'];
      await tx.insert('records', {
        'id': key,
        'kind': kind,
        'data': jsonEncode(data),
        'version': version,
        'deleted': deleted ? 1 : 0,
        'updated': DateTime.now().toUtc().toIso8601String(),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      await tx.insert('queue', {
        'id': key,
        'op_id': uuid.v4(),
        'base_version': version,
        'data': jsonEncode(data),
        'kind': kind,
        'deleted': deleted ? 1 : 0,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      for (final entry in settings.entries) {
        if (kind != 'preference' && syncedPreferences.contains(entry.key)) {
          final prefId = preferenceId(entry.key);
          final prior = await tx.query(
            'records',
            where: 'id=?',
            whereArgs: [prefId],
          );
          final prefVersion = prior.isEmpty ? 0 : prior.first['version'];
          final payload = jsonEncode({'key': entry.key, 'value': entry.value});
          await tx.insert('records', {
            'id': prefId,
            'kind': 'preference',
            'data': payload,
            'version': prefVersion,
            'deleted': 0,
            'updated': DateTime.now().toUtc().toIso8601String(),
          }, conflictAlgorithm: ConflictAlgorithm.replace);
          await tx.insert('queue', {
            'id': prefId,
            'op_id': uuid.v4(),
            'base_version': prefVersion,
            'data': payload,
            'kind': 'preference',
            'deleted': 0,
          }, conflictAlgorithm: ConflictAlgorithm.replace);
        }
        await tx.insert('settings', {
          'key': entry.key,
          'value': jsonEncode(entry.value),
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      if (kind == 'stockmove') {
        if (!deleted && data['createDiary'] == true) {
          final removed = await tx.query(
            'settings',
            where: 'key=?',
            whereArgs: ['removedApp:diary'],
          );
          if (removed.isNotEmpty &&
              jsonDecode(removed.first['value'] as String) == true) {
            throw StateError(
              'Reinstall Diary before adding this input use to your diary.',
            );
          }
        }
        final diaryId = uuid.v5(
          '6ba7b811-9dad-11d1-80b4-00c04fd430c8',
          'stock-diary:$key',
        );
        final existing = await tx.query(
          'records',
          where: 'id=?',
          whereArgs: [diaryId],
        );
        if (data['createDiary'] == true || existing.isNotEmpty) {
          final shouldDelete = deleted || data['createDiary'] != true;
          final entry = {
            'title': 'Input used: ${data['itemName'] ?? 'Stock'}',
            'notes':
                '${(data['delta'] as num).abs()} ${data['unit'] ?? ''}. ${data['notes'] ?? ''}',
            'date': data['date'],
            'farmId': data['farmId'],
            'fieldId': data['fieldId'],
            'stockmoveId': key,
            'media': <dynamic>[],
          };
          await validateBusiness(tx, diaryId, 'diary', entry, shouldDelete);
          final version = existing.isEmpty ? 0 : existing.first['version'];
          await tx.insert('records', {
            'id': diaryId,
            'kind': 'diary',
            'data': jsonEncode(entry),
            'version': version,
            'deleted': shouldDelete ? 1 : 0,
            'updated': DateTime.now().toUtc().toIso8601String(),
          }, conflictAlgorithm: ConflictAlgorithm.replace);
          await tx.insert('queue', {
            'id': diaryId,
            'op_id': uuid.v4(),
            'base_version': version,
            'data': jsonEncode(entry),
            'kind': 'diary',
            'deleted': shouldDelete ? 1 : 0,
          }, conflictAlgorithm: ConflictAlgorithm.replace);
        }
      }
    });
    notifyListeners();
    return key;
  }

  Future<void> incoming(Map<String, dynamic> remote) async {
    await db.transaction((tx) async {
      final appId = owningApp(remote['kind']);
      if (appId != null) {
        final blocked = await tx.query(
          'settings',
          where: 'key=?',
          whereArgs: ['removedApp:$appId'],
        );
        if (blocked.isNotEmpty &&
            jsonDecode(blocked.first['value'] as String) == true) {
          return;
        }
      }
      final queued = await tx.query(
        'queue',
        where: 'id=?',
        whereArgs: [remote['id']],
      );
      String? geometryIssue;
      try {
        await validateBusiness(
          tx,
          remote['id'],
          remote['kind'],
          Map<String, dynamic>.from(remote['data']),
          remote['deleted'] == true,
        );
        await validateGeometry(
          tx,
          remote['id'],
          remote['kind'],
          Map<String, dynamic>.from(remote['data']),
          remote['deleted'] == true,
        );
      } catch (e) {
        geometryIssue = e.toString();
      }
      if (queued.isNotEmpty || geometryIssue != null) {
        await tx.insert('conflicts', {
          'id': remote['id'],
          'remote': jsonEncode({
            ...remote,
            if (geometryIssue != null) 'geometryIssue': geometryIssue,
          }),
        }, conflictAlgorithm: ConflictAlgorithm.replace);
        return;
      }
      await tx.insert('records', {
        'id': remote['id'],
        'kind': remote['kind'],
        'data': jsonEncode(remote['data']),
        'version': remote['version'],
        'deleted': remote['deleted'] == true ? 1 : 0,
        'updated': remote['updated'],
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    });
    notifyListeners();
  }

  Future<void> acknowledge(Map<String, Object?> op, int version) async {
    await db.transaction((tx) async {
      await tx.update(
        'records',
        {'version': version},
        where: 'id=?',
        whereArgs: [op['id']],
      );
      await tx.delete(
        'queue',
        where: 'id=? AND op_id=?',
        whereArgs: [op['id'], op['op_id']],
      );
      await tx.update(
        'queue',
        {'base_version': version},
        where: 'id=?',
        whereArgs: [op['id']],
      );
    });
  }

  Future<void> resolve(String id, {required bool keepLocal}) async {
    final rows = await db.query('conflicts', where: 'id=?', whereArgs: [id]);
    if (rows.isEmpty) return;
    final remote =
        jsonDecode(rows.first['remote'] as String) as Map<String, dynamic>;
    await db.transaction((tx) async {
      final localRows = await tx.query(
        'records',
        where: 'id=?',
        whereArgs: [id],
      );
      final candidate = keepLocal
          ? (localRows.isEmpty ? null : decode(localRows.first))
          : remote;
      if (candidate == null) {
        throw StateError(
          'No local record exists. Correct the farm geometry before accepting this record.',
        );
      }
      final deleted = candidate['deleted'] == true || candidate['deleted'] == 1;
      final ownerApp = owningApp(candidate['kind']);
      if (ownerApp != null) {
        final removed = await tx.query(
          'settings',
          where: 'key=?',
          whereArgs: ['removedApp:$ownerApp'],
        );
        if (removed.isNotEmpty &&
            jsonDecode(removed.first['value'] as String) == true) {
          throw StateError('This app was removed. Reinstall it first.');
        }
      }
      await validateBusiness(
        tx,
        id,
        candidate['kind'],
        Map<String, dynamic>.from(candidate['data']),
        deleted,
      );
      await validateGeometry(
        tx,
        id,
        candidate['kind'],
        Map<String, dynamic>.from(candidate['data']),
        deleted,
      );
      await tx.insert('records', {
        'id': id,
        'kind': candidate['kind'],
        'data': jsonEncode(candidate['data']),
        'version': remote['version'],
        'deleted': deleted ? 1 : 0,
        'updated': DateTime.now().toUtc().toIso8601String(),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      if (keepLocal) {
        await tx.insert('queue', {
          'id': id,
          'op_id': uuid.v4(),
          'base_version': remote['version'],
          'data': jsonEncode(candidate['data']),
          'kind': candidate['kind'],
          'deleted': deleted ? 1 : 0,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      } else {
        await tx.delete('queue', where: 'id=?', whereArgs: [id]);
      }
      await tx.delete('conflicts', where: 'id=?', whereArgs: [id]);
    });
    notifyListeners();
  }

  Future<List<Map<String, Object?>>> installations() => db.query('installs');

  Future<void> validateGeometry(
    DatabaseExecutor tx,
    String id,
    String kind,
    Map<String, dynamic> data,
    bool deleted,
  ) async {
    if (kind != 'farm' && kind != 'field') return;
    final p = polygonPoints(data);
    if (!deleted && p.isNotEmpty) {
      final issue = validatePolygon(p);
      if (issue != null) throw StateError(issue);
    }
    if (kind == 'field' && !deleted) {
      final parent = await tx.query(
        'records',
        where: 'id=? AND kind=? AND deleted=0',
        whereArgs: [data['farmId'], 'farm'],
      );
      if (parent.isEmpty) {
        throw StateError('Choose a parent farm first.');
      }
      final issue = p.isEmpty
          ? null
          : validateContainment(polygonPoints(decode(parent.first)['data']), p);
      if (issue != null) throw StateError(issue);
    }
    if (kind == 'farm') {
      final fields = await tx.query(
        'records',
        where: 'kind=? AND deleted=0',
        whereArgs: ['field'],
      );
      for (final row in fields) {
        final child = decode(row)['data'];
        if (child['farmId'] != id) continue;
        if (deleted) {
          throw StateError(
            'This farm still has farm areas. Move or delete them explicitly first.',
          );
        }
        final childPoints = polygonPoints(child);
        final issue = childPoints.isEmpty
            ? null
            : validateContainment(p, childPoints);
        if (issue != null) {
          throw StateError(
            'Farm change would exclude area "${child['name']}". $issue',
          );
        }
      }
    }
  }

  // Legacy records remain recoverable and visible, but cannot be treated as
  // valid mapped geometry or re-saved until the user repairs them.
  Future<String?> geometryIssue(Map<String, dynamic> record) async {
    try {
      await validateGeometry(
        db,
        record['id'],
        record['kind'],
        Map<String, dynamic>.from(record['data']),
        record['deleted'] == 1,
      );
      return null;
    } catch (e) {
      return e.toString().replaceFirst('Bad state: ', '');
    }
  }

  Future<bool> ready(String id) async {
    final rows = await db.query(
      'installs',
      where: 'id=? AND state=?',
      whereArgs: [id, 'ready'],
    );
    final file = File(path.join(filesPath, 'packs', '$id.json'));
    return rows.isNotEmpty &&
        await file.exists() &&
        sha256.convert(await file.readAsBytes()).toString() ==
            rows.first['sha'];
  }

  Future<void> install(MiniManifest app, {bool Function()? cancelled}) =>
      appLifecycle(() => installPack(app, cancelled: cancelled));
  Future<void> installPack(
    MiniManifest app, {
    bool Function()? cancelled,
  }) async {
    final wasReady = await ready(app.id);
    final epoch = await setting('appEpoch:${app.id}') ?? 0;
    final asset = await rootBundle.load('assets/packs/${app.id}.json');
    final data = asset.buffer.asUint8List(
      asset.offsetInBytes,
      asset.lengthInBytes,
    );
    final manifest = jsonDecode(utf8.decode(data));
    if (manifest['id'] != app.id || manifest['version'] != app.version) {
      throw StateError('Package identity or version does not match this app.');
    }
    final hash = sha256.convert(data).toString();
    final dir = Directory(path.join(filesPath, 'packs'));
    await dir.create(recursive: true);
    final partial = File(path.join(dir.path, '${app.id}.partial'));
    var offset = await partial.exists() ? await partial.length() : 0;
    if (offset > data.length ||
        (offset > 0 &&
            !listEquals(
              await partial.readAsBytes(),
              data.sublist(0, offset),
            ))) {
      await partial.writeAsBytes([]);
      offset = 0;
    }
    while (offset < data.length) {
      if (cancelled?.call() == true ||
          epoch != (await setting('appEpoch:${app.id}') ?? 0)) {
        return;
      }
      final end = (offset + 128).clamp(0, data.length);
      await partial.writeAsBytes(
        data.sublist(offset, end),
        mode: FileMode.append,
        flush: true,
      );
      offset = end;
      await db.insert('installs', {
        'id': app.id,
        'version': app.version,
        'bytes': offset,
        'total': data.length,
        'sha': hash,
        'state': 'installing',
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      notifyListeners();
    }
    if (sha256.convert(await partial.readAsBytes()).toString() != hash) {
      throw StateError('Content integrity check failed. Try installing again.');
    }
    if (epoch != (await setting('appEpoch:${app.id}') ?? 0)) return;
    await partial.rename(path.join(dir.path, '${app.id}.json'));
    await db.transaction((tx) async {
      await tx.insert('settings', {
        'key': 'removedApp:${app.id}',
        'value': 'false',
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      if (app.id == 'coop' && !wasReady) {
        await tx.insert('settings', {
          'key': 'coopGeneration',
          'value': jsonEncode(uuid.v4()),
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await tx.update(
        'installs',
        {'state': 'ready'},
        where: 'id=?',
        whereArgs: [app.id],
      );
    });
    notifyListeners();
  }

  Future<Map<String, dynamic>> content(String id) async {
    if (!await ready(id)) {
      throw StateError('Install this app before opening it.');
    }
    return jsonDecode(
      await File(path.join(filesPath, 'packs', '$id.json')).readAsString(),
    );
  }

  Future<Map<String, int>> removalSummary(String id) async {
    final kinds = appOwnedKinds[id] ?? {};
    var count = 0, pending = 0;
    for (final kind in kinds) {
      count += (await records(kind)).length;
      pending += (await db.query(
        'queue',
        where: 'kind=?',
        whereArgs: [kind],
      )).length;
    }
    final installed = await db.query(
      'installs',
      where: 'id=?',
      whereArgs: [id],
    );
    return {
      'records': count,
      'unsynced': pending,
      'bytes': installed.isEmpty ? 0 : installed.first['bytes'] as int,
    };
  }

  Future<void> removeApp(String id) => appLifecycle(() => removeAppData(id));
  Future<void> removeAppData(String id) async {
    if (protectedApps.contains(id)) {
      throw StateError('This core app cannot be removed.');
    }
    if (!appOwnedKinds.containsKey(id) && id != 'sample-records') {
      throw StateError('Unknown app.');
    }
    final kinds = appOwnedKinds[id] ?? {};
    final removedMedia = <String>{};
    final reminders = <String>[];
    RandomAccessFile? lock;
    try {
      if (!kIsWeb) {
        lock = await File(
          path.join(filesPath, 'sync.lock'),
        ).open(mode: FileMode.append);
        await lock.lock(FileLock.exclusive);
      }
      await db.transaction((tx) async {
        final epochRows = await tx.query(
          'settings',
          where: 'key=?',
          whereArgs: ['appEpoch:$id'],
        );
        final epoch = epochRows.isEmpty
            ? 0
            : jsonDecode(epochRows.first['value'] as String) as int;
        for (final entry in {
          'appEpoch:$id': epoch + 1,
          'removedApp:$id': true,
          'preview_pack:$id': null,
          if (id == 'coop') 'coopGeneration': uuid.v4(),
        }.entries) {
          await tx.insert('settings', {
            'key': entry.key,
            'value': jsonEncode(entry.value),
          }, conflictAlgorithm: ConflictAlgorithm.replace);
        }
        for (final kind in kinds) {
          final ownedDrafts = await tx.query(
            'settings',
            where: 'key LIKE ?',
            whereArgs: ['entryDraft:$kind:%'],
          );
          final ownedQueue = await tx.query(
            'queue',
            where: 'kind=?',
            whereArgs: [kind],
          );
          for (final source in [...ownedDrafts, ...ownedQueue]) {
            removedMedia.addAll(
              RegExp(
                r'[a-f0-9]{64}',
              ).allMatches(jsonEncode(source)).map((m) => m.group(0)!),
            );
          }
          final rows = await tx.query(
            'records',
            where: 'kind=?',
            whereArgs: [kind],
          );
          for (final row in rows) {
            final data = jsonDecode(row['data'] as String);
            for (final media in data['media'] ?? []) {
              if (media['hash'] is String) removedMedia.add(media['hash']);
            }
            if (kind == 'task') reminders.add(row['id'] as String);
          }
          await tx.delete('records', where: 'kind=?', whereArgs: [kind]);
          await tx.delete('queue', where: 'kind=?', whereArgs: [kind]);
          await tx.delete(
            'settings',
            where: 'key LIKE ?',
            whereArgs: ['entryDraft:$kind:%'],
          );
        }
        final conflicts = await tx.query('conflicts');
        for (final conflict in conflicts) {
          if (kinds.contains(
            jsonDecode(conflict['remote'] as String)['kind'],
          )) {
            removedMedia.addAll(
              RegExp(r'[a-f0-9]{64}')
                  .allMatches(conflict['remote'] as String)
                  .map((m) => m.group(0)!),
            );
            await tx.delete(
              'conflicts',
              where: 'id=?',
              whereArgs: [conflict['id']],
            );
          }
        }
        await tx.delete('installs', where: 'id=?', whereArgs: [id]);
        await tx.delete(
          'settings',
          where: 'key LIKE ?',
          whereArgs: ['appDraft:$id:%'],
        );
        if (id == 'guides') {
          await tx.delete(
            'settings',
            where: 'key LIKE ?',
            whereArgs: ['guideRead:%'],
          );
        }
        if (id == 'planner') {
          final messages = await tx.query(
            'records',
            where: 'kind=?',
            whereArgs: ['inbox'],
          );
          for (final message in messages) {
            final data = jsonDecode(message['data'] as String);
            if (data['source'] == 'My Planner' &&
                (data['route'] as String? ?? '').startsWith('task:')) {
              for (final table in ['records', 'queue', 'conflicts']) {
                await tx.delete(
                  table,
                  where: 'id=?',
                  whereArgs: [message['id']],
                );
              }
            }
          }
        }
      });
      if (kIsWeb) {
        final remaining = [
          ...await db.query('records'),
          ...await db.query('queue'),
          ...await db.query('conflicts'),
          ...await db.query(
            'settings',
            where: 'key NOT LIKE ?',
            whereArgs: ['browserMedia:%'],
          ),
        ].map(jsonEncode).join();
        for (final hash in removedMedia) {
          if (!remaining.contains(hash)) {
            await db.delete(
              'settings',
              where: 'key=?',
              whereArgs: ['browserMedia:$hash'],
            );
          }
        }
      }
      if (!kIsWeb) {
        for (final reminder in reminders) {
          await FlutterLocalNotificationsPlugin().cancel(
            reminder.codeUnits.fold(0, (a, b) => (a * 31 + b) & 0x7fffffff),
          );
        }
        for (final extension in ['json', 'partial']) {
          final f = File(path.join(filesPath, 'packs', '$id.$extension'));
          if (await f.exists()) await f.delete();
        }
        final remaining = [
          ...await db.query('records'),
          ...await db.query('queue'),
          ...await db.query('settings'),
          ...await db.query('conflicts'),
        ].map((r) => jsonEncode(r)).join();
        for (final hash in removedMedia) {
          if (RegExp(r'^[a-f0-9]{64}$').hasMatch(hash) &&
              !remaining.contains(hash)) {
            final f = File(path.join(filesPath, 'media', hash));
            if (await f.exists()) await f.delete();
          }
        }
      }
    } finally {
      if (lock != null) {
        await lock.unlock();
        await lock.close();
      }
    }
    notifyListeners();
  }

  Future<String> keepMedia(String source) async {
    if (await File(source).length() > 25 * 1024 * 1024) {
      throw StateError('Choose an attachment below 25 MB.');
    }
    final bytes = await File(source).readAsBytes();
    final hash = sha256.convert(bytes).toString();
    final dir = Directory(path.join(filesPath, 'media'));
    await dir.create(recursive: true);
    final dest = File(path.join(dir.path, hash));
    await dest.writeAsBytes(bytes, flush: true);
    return hash;
  }

  Future<void> close() => db.close();
}
