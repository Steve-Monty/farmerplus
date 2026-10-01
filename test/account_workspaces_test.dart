import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:farmerplus_mobile/account_workspaces.dart';
import 'package:farmerplus_mobile/store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  test('account roots and credential keys stay separate without altering legacy data', () async {
    final root = await Directory.systemTemp.createTemp('farmer-workspaces-');
    final legacy = await FarmStore.open(factory: databaseFactoryFfi, filesPath: root.path);
    final key = AccountWorkspaces.id('https://example.test', 'second');
    final second = await FarmStore.open(factory: databaseFactoryFfi, filesPath: '${root.path}/accounts/$key');
    try {
      await legacy.setSetting('saved-marker', 'first-owner-data');
      await second.setSetting('workspaceId', key);
      expect(await AccountWorkspaces.activeRoot(root.path), root.path);
      expect(await WorkspaceCredentials(legacy).scoped('syncToken'), 'syncToken');
      expect(await WorkspaceCredentials(second).scoped('syncToken'), 'account.$key.syncToken');
      expect(await second.setting('saved-marker'), isNull);
      expect(await legacy.setting('saved-marker'), 'first-owner-data');
      expect(AccountWorkspaces.id('https://other.test', 'second'), isNot(key));
      final pointer = File('${root.path}/active-account');
      await pointer.writeAsString('../outside');
      await expectLater(AccountWorkspaces.activeRoot(root.path), throwsStateError);
      await pointer.writeAsString(key);
      expect(p.normalize(await AccountWorkspaces.activeRoot(root.path)), p.normalize(second.filesPath));
    } finally {
      await second.close();
      await legacy.close();
      await root.delete(recursive: true);
    }
  });
}
