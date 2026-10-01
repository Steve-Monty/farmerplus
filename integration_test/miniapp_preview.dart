// Disposable local UI fixture; never included in the production entry point.
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:http/http.dart' as http;
import 'package:sqflite_common_ffi_web/sqflite_ffi_web.dart';
import 'package:sqflite/sqflite.dart';
import 'package:farmerplus_mobile/pwa_main.dart'
    show BrowserPwaStore, BrowserPwaSync;
import 'package:farmerplus_mobile/auth.dart';
import 'package:farmerplus_mobile/remote_apps.dart';
import 'package:farmerplus_mobile/remote_app_ui.dart';
import 'package:farmerplus_mobile/ui.dart';

SemanticsHandle? semantics;
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  semantics = SemanticsBinding.instance.ensureSemantics();
  final fixture = jsonDecode(
    (await http.get(Uri.base.resolve('/qa/fixture'))).body,
  );
  final db = await databaseFactoryFfiWeb.openDatabase(
    'animals-qa-${fixture['owner']}.db',
    options: OpenDatabaseOptions(
      version: 1,
      onCreate: (db, v) async {
        for (final sql in [
          'CREATE TABLE settings (key TEXT PRIMARY KEY,value TEXT NOT NULL)',
          'CREATE TABLE records (id TEXT PRIMARY KEY,kind TEXT NOT NULL,data TEXT NOT NULL,version INTEGER NOT NULL DEFAULT 0,deleted INTEGER NOT NULL DEFAULT 0,updated TEXT NOT NULL)',
          'CREATE TABLE queue (id TEXT PRIMARY KEY,op_id TEXT NOT NULL,base_version INTEGER NOT NULL,data TEXT NOT NULL,kind TEXT NOT NULL,deleted INTEGER NOT NULL)',
          'CREATE TABLE conflicts (id TEXT PRIMARY KEY,remote TEXT NOT NULL)',
          'CREATE TABLE installs (id TEXT PRIMARY KEY,version INTEGER NOT NULL,bytes INTEGER NOT NULL,total INTEGER NOT NULL,sha TEXT NOT NULL,state TEXT NOT NULL)',
        ]) {
          await db.execute(sql);
        }
      },
    ),
  );
  final store = BrowserPwaStore(db);
  final engine = BrowserPwaSync(store);
  await store.setSetting('server', Uri.base.origin);
  await engine.request('POST', '/auth/login', body: fixture['credentials']);
  await store.setSetting('accessOwner', 'qa:${fixture['owner']}');
  AccountAccess.unlocked.value = 'qa:${fixture['owner']}';
  await db.insert('settings', {
    'key': 'syncMode',
    'value': '"manual"',
  }, conflictAlgorithm: ConflictAlgorithm.replace);
  await engine.start();
  for (final r in fixture['records']) {
    await db.insert('records', {
      'id': r['id'],
      'kind': r['kind'],
      'data': jsonEncode(r['data']),
      'version': r['version'],
      'deleted': 0,
      'updated': r['updated'],
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }
  final apps = await RemoteApps.of(store).available(refresh: true);
  runApp(
    MaterialApp(
      theme: farmTheme(),
      home: Builder(
        builder: (context) => RemoteInstallPage(
          store: store,
          app: apps.first,
          onOpen: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => RemoteAppPage(store: store, appId: 'my-animals'),
            ),
          ),
        ),
      ),
    ),
  );
}
