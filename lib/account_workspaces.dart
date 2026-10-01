import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'store.dart';

/// Only a verified server identity may choose a workspace. Existing legacy
/// storage stays at its original path; no records or downloads are moved.
class AccountWorkspaces {
  static Future<void> Function(Map<String, dynamic>, String)? adopt;
  static String id(String server, String owner) =>
      sha256.convert(utf8.encode('$server\n$owner')).toString();

  static Future<String> activeRoot(String root) async {
    final pointer = File(p.join(root, 'active-account'));
    if (!await pointer.exists()) return root;
    final value = (await pointer.readAsString()).trim();
    if (value == 'legacy') return root;
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(value)) {
      throw StateError(
        'Account selection could not be read. Saved work is unchanged.',
      );
    }
    return p.join(root, 'accounts', value);
  }

  static Future<FarmStore> forIdentity(String server, String owner) async {
    final root = (await getApplicationDocumentsDirectory()).path;
    final legacy = await FarmStore.open(filesPath: root, singleInstance: false);
    final isLegacy =
        await legacy.setting('boundServer') == server &&
        await legacy.setting('boundOwner') == owner;
    await legacy.close();
    if (isLegacy) return FarmStore.open(filesPath: root);
    final key = id(server, owner);
    final store = await FarmStore.open(
      filesPath: p.join(root, 'accounts', key),
    );
    await store.setSetting('workspaceId', key);
    await store.setSetting('server', server);
    return store;
  }

  static Future<void> activate(FarmStore store) async {
    final root = (await getApplicationDocumentsDirectory()).path;
    final key = await store.setting('workspaceId') ?? 'legacy';
    final temp = File(p.join(root, 'active-account.pending'));
    await temp.writeAsString(key, flush: true);
    await temp.rename(p.join(root, 'active-account'));
  }
}

/// Legacy credentials retain their existing names. New workspaces cannot read
/// or refresh another account's credentials, including from background jobs.
class WorkspaceCredentials {
  final FarmStore store;
  final FlutterSecureStorage storage = const FlutterSecureStorage();
  WorkspaceCredentials(this.store);
  Future<String> scoped(String key) async {
    final workspace = await store.setting('workspaceId');
    return workspace == null ? key : 'account.$workspace.$key';
  }

  Future<String?> read({required String key}) async =>
      storage.read(key: await scoped(key));
  Future<void> write({required String key, required String? value}) async =>
      storage.write(key: await scoped(key), value: value);
  Future<void> delete({required String key}) async =>
      storage.delete(key: await scoped(key));
}
