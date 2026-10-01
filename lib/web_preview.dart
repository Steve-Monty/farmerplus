// The browser app shares the same farm widgets and owner-bound sync model.
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/semantics.dart';
import 'package:crypto/crypto.dart';
import 'package:sqflite_common_ffi_web/sqflite_ffi_web.dart';
import 'package:sqflite/sqflite.dart';
import 'main.dart' as mobile;
import 'store.dart';
import 'domain.dart';
import 'sync.dart';
import 'services.dart';
import 'package:http/http.dart' as http;

SemanticsHandle? previewSemantics;
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  previewSemantics = SemanticsBinding.instance.ensureSemantics();
  final db = await databaseFactoryFfiWeb.openDatabase(
    'farmer-interactive-preview.db',
    options: OpenDatabaseOptions(
      version: 1,
      onCreate: (db, version) async {
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
  final store = BrowserPreviewStore(db);
  if (await store.setting('farmerId') == null) {
    await store.setSetting('farmerId', uuid.v4());
  }
  final sync = PreviewSync(store);
  runApp(mobile.FarmerApp(store: store, sync: sync, reminders: Reminders()));
  await sync.start();
}

class BrowserPreviewStore extends FarmStore {
  BrowserPreviewStore(Database db) : super(db, 'browser-preview');
  @override
  Future<bool> ready(String id) async {
    final rows = await db.query(
      'installs',
      where: 'id=? AND state=?',
      whereArgs: [id, 'ready'],
    );
    final content = await setting('preview_pack:$id');
    return rows.isNotEmpty &&
        content is String &&
        sha256.convert(utf8.encode(content)).toString() == rows.first['sha'];
  }

  @override
  Future<void> install(MiniManifest app, {bool Function()? cancelled}) =>
      appLifecycle(() => installPreviewPack(app, cancelled: cancelled));
  Future<void> installPreviewPack(
    MiniManifest app, {
    bool Function()? cancelled,
  }) async {
    final wasReady = await ready(app.id);
    final epoch = await setting('appEpoch:${app.id}') ?? 0;
    final content = await rootBundle.loadString('assets/packs/${app.id}.json');
    final decoded = jsonDecode(content);
    if (decoded['id'] != app.id || decoded['version'] != app.version) {
      throw StateError('Package identity does not match.');
    }
    final bytes = utf8.encode(content);
    Future<bool> current(DatabaseExecutor tx) async {
      final values = await tx.query(
        'settings',
        where: 'key=?',
        whereArgs: ['appEpoch:${app.id}'],
      );
      return epoch ==
          (values.isEmpty ? 0 : jsonDecode(values.first['value'] as String));
    }

    final rows = await db.query('installs', where: 'id=?', whereArgs: [app.id]);
    var offset = rows.isEmpty
        ? 0
        : (rows.first['bytes'] as int).clamp(0, bytes.length);
    while (offset < bytes.length) {
      if (cancelled?.call() == true ||
          epoch != (await setting('appEpoch:${app.id}') ?? 0)) {
        return;
      }
      offset = (offset + 128).clamp(0, bytes.length);
      final wrote = await db.transaction((tx) async {
        if (!await current(tx)) return false;
        await tx.insert('installs', {
          'id': app.id,
          'version': app.version,
          'bytes': offset,
          'total': bytes.length,
          'sha': sha256.convert(bytes).toString(),
          'state': 'installing',
        }, conflictAlgorithm: ConflictAlgorithm.replace);
        return true;
      });
      if (!wrote) return;
      notifyListeners();
    }
    await db.transaction((tx) async {
      if (!await current(tx)) return;
      for (final entry in {
        'preview_pack:${app.id}': content,
        'removedApp:${app.id}': false,
        if (app.id == 'coop' && !wasReady) 'coopGeneration': uuid.v4(),
      }.entries) {
        await tx.insert('settings', {
          'key': entry.key,
          'value': jsonEncode(entry.value),
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

  @override
  Future<Map<String, dynamic>> content(String id) async {
    if (!await ready(id)) {
      throw StateError('Install this app before opening it.');
    }
    return Map<String, dynamic>.from(
      jsonDecode(await setting('preview_pack:$id')),
    );
  }

  @override
  Future<String> keepMedia(String source) async {
    final uri = Uri.parse(source);
    if (uri.scheme != 'blob') {
      throw StateError('Choose an image from this browser.');
    }
    final bytes = await http.readBytes(uri);
    if (bytes.length > 25 * 1024 * 1024) {
      throw StateError('Choose an attachment smaller than 25 MB.');
    }
    final hash = sha256.convert(bytes).toString();
    await setSetting('browserMedia:$hash', base64Encode(bytes));
    return hash;
  }
}

class PreviewSync extends SyncEngine {
  PreviewSync(super.store) {
    status = 'Saved in this browser';
  }
  @override
  Future<void> upload(String hash) async {
    final state = await request('GET', '/media/$hash/status');
    if (state['complete'] == true) return;
    final bytes = await store.mediaBytes(hash);
    if (bytes == null) {
      throw StateError('An attachment is not saved in this browser.');
    }
    var offset = state['bytes'] as int;
    if (offset < 0 || offset > bytes.length) {
      throw StateError('Invalid upload offset.');
    }
    while (offset < bytes.length) {
      final end = (offset + 128 * 1024).clamp(0, bytes.length);
      final r = await request(
        'PUT',
        '/media/$hash',
        body: {
          'offset': offset,
          'total': bytes.length,
          'chunk': base64Encode(bytes.sublist(offset, end)),
        },
      );
      if (r['bytes'] <= offset || r['bytes'] > bytes.length) {
        throw StateError('Attachment upload could not finish.');
      }
      offset = r['bytes'];
    }
  }

  @override
  Future<void> download(String hash) async {
    if (await store.mediaBytes(hash) != null) return;
    final bytes = <int>[];
    while (true) {
      final r = await request('GET', '/media/$hash?offset=${bytes.length}');
      if (r['total'] > 25 * 1024 * 1024) {
        throw StateError('Attachment exceeds the browser limit.');
      }
      final chunk = base64Decode(r['chunk']);
      if (chunk.isEmpty && bytes.length < r['total']) {
        throw StateError('Attachment download stopped.');
      }
      bytes.addAll(chunk);
      if (bytes.length >= r['total']) break;
    }
    if (sha256.convert(bytes).toString() != hash) {
      throw StateError('Attachment verification failed.');
    }
    await store.setSetting('browserMedia:$hash', base64Encode(bytes));
  }
}
