import 'course_downloads.dart';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:workmanager/workmanager.dart';
import 'store.dart';
import 'sync.dart';
import 'community.dart';

@pragma('vm:entry-point')
void syncDispatcher() {
  Workmanager().executeTask((task, input) async {
    WidgetsFlutterBinding.ensureInitialized();
    // Workmanager may run while the foreground Flutter engine is alive. Keep
    // its database handle independent so closing this task cannot close the
    // foreground store returned by sqflite's single-instance cache.
    final store = await FarmStore.open(singleInstance: false);
    final engine = SyncEngine(store);
    try {
      if (input?['workspace'] != null &&
          input!['workspace'] !=
              (await store.setting('workspaceId') ?? 'legacy'))
        return true;
      final session = await engine.oidcStored();
      engine.token =
          session?['access_token'] ??
          await engine.secure.read(key: 'syncToken');
      await engine.automatic();
      final community = CommunityService(store, engine, background: true);
      bool communityDone = true;
      try {
        await community.refresh();
        final key = await community.scope();
        if (key != null)
          communityDone =
              (await community.pending(key)).isEmpty &&
              await store.setting('coopError:$key') == null;
      } finally {
        community.dispose();
      }
      await CourseDownloads(store).pump();
      if (await store.setting('syncMode') == 'manual' || engine.token == null)
        return true;
      return communityDone && (await store.db.query('queue', limit: 1)).isEmpty;
    } finally {
      engine.dispose();
      await store.close();
    }
  });
}

Future<void> registerBackgroundSync() async {
  if (kIsWeb || !Platform.isAndroid) return;
  await Workmanager().initialize(syncDispatcher);
  await Workmanager().cancelByUniqueName('farmer-sync');
}

/// Durable, event-driven work. Android runs it when the requested network is
/// available; this is not a periodic polling schedule.
Future<void> schedulePendingSync(FarmStore store) async {
  if (kIsWeb || !Platform.isAndroid) return;
  final mode = await store.setting('syncMode') ?? 'automatic';
  if (mode == 'manual') return;
  final corePending = (await store.db.query('queue', limit: 1)).isNotEmpty;
  final auxiliary = await store.db.query(
    'settings',
    where: 'key LIKE ? OR key LIKE ?',
    whereArgs: ['communityPending:%', 'courseDownload:%'],
  );
  final auxiliaryPending = auxiliary.any((row) {
    final value = jsonDecode(row['value'] as String);
    if (value is List) return value.isNotEmpty;
    return value is Map &&
        {
          'queued',
          'downloading',
          'waitingWifi',
          'waitingConnection',
        }.contains(value['state']);
  });
  if (!corePending && !auxiliaryPending) return;
  final workspace = await store.setting('workspaceId') ?? 'legacy';
  try {
    await Workmanager().registerOneOffTask(
      'farmer-pending-$workspace-$mode',
      'farmer-sync',
      existingWorkPolicy: ExistingWorkPolicy.keep,
      inputData: {'workspace': workspace},
      constraints: Constraints(networkType: NetworkType.connected),
    );
  } catch (_) {
    /* Foreground sync remains available if scheduling fails. */
  }
}
