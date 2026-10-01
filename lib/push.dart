import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'auth.dart';
import 'store.dart';
import 'sync.dart';
import 'services.dart';
import 'miniapps.dart';
import 'ui.dart';

// Public client identifiers, supplied by the Firebase project owner at build time.
// No server credential belongs in these values.
const firebaseProject = String.fromEnvironment('FARMER_FIREBASE_PROJECT');
const firebaseAppId = String.fromEnvironment('FARMER_FIREBASE_APP_ID');
const firebaseApiKey = String.fromEnvironment('FARMER_FIREBASE_API_KEY');
const firebaseSender = String.fromEnvironment('FARMER_FIREBASE_SENDER_ID');
bool get firebaseConfigured => [
  firebaseProject,
  firebaseAppId,
  firebaseApiKey,
  firebaseSender,
].every((v) => v.isNotEmpty);
Future<void> initializePushFirebase() async {
  if (Firebase.apps.isEmpty) {
    await Firebase.initializeApp(
      options: const FirebaseOptions(
        apiKey: firebaseApiKey,
        appId: firebaseAppId,
        messagingSenderId: firebaseSender,
        projectId: firebaseProject,
      ),
    );
  }
}

@pragma('vm:entry-point')
Future<void> farmerPushBackground(RemoteMessage message) async {
  if (!firebaseConfigured) return;
  await initializePushFirebase();
  // Android displays notification payloads. No duplicate local alert, UI work,
  // farm-data writes or credentials opened in the background isolate.
}

String? pushNotificationId(Map<String, dynamic> data) {
  final id = data['notificationId'];
  return data['schemaVersion'] == '1' &&
          id is String &&
          RegExp(
            r'^[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12}$',
          ).hasMatch(id)
      ? id
      : null;
}

class PushService extends ChangeNotifier with WidgetsBindingObserver {
  static final Map<FarmStore, PushService> _instances = {};
  static PushService? of(FarmStore store) => _instances[store];
  final FarmStore store;
  final SyncEngine sync;
  final Reminders reminders;
  final GlobalKey<NavigatorState> navigator;
  String status = 'Push is not configured for this build';
  String? pendingRoute, _scope, _registrationSignature;
  bool busy = false, opening = false, ready = false;
  Timer? retry;
  StreamSubscription? connectivity, tokenChanges, foreground, taps;
  final Set<String> seen = {};
  PushService(this.store, this.sync, this.reminders, this.navigator) {
    _instances[store] = this;
  }

  Future<String?> scope() async {
    if (AccountAccess.unlocked.value == null ||
        sync.credentialChangeInProgress) {
      return null;
    }
    final owner = await store.setting('boundOwner');
    final server = await sync.base();
    if (owner is! String || await store.setting('boundServer') != server) {
      return null;
    }
    return '$server:$owner';
  }

  Future<void> start() async {
    WidgetsBinding.instance.addObserver(this);
    AccountAccess.unlocked.addListener(changed);
    sync.beforeLogout = revoke;
    if (!kIsWeb && Platform.isAndroid && firebaseConfigured) {
      try {
        await initializePushFirebase();
        FirebaseMessaging.onBackgroundMessage(farmerPushBackground);
        final android = reminders.plugin
            .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin
            >();
        await android?.createNotificationChannel(
          const AndroidNotificationChannel(
            'farmerplus_updates',
            'FarmerPlus updates',
            description: 'Learning, Planner and account updates',
            importance: Importance.defaultImportance,
          ),
        );
        tokenChanges = FirebaseMessaging.instance.onTokenRefresh.listen((_) {
          _registrationSignature = null;
          changed();
        });
        foreground = FirebaseMessaging.onMessage.listen((m) async {
          if (await store.setting('pushOptIn') != true) return;
          final id = pushNotificationId(m.data);
          if (id == null || await scope() == null || !seen.add(id)) return;
          if (seen.length > 200) seen.remove(seen.first);
          await refresh();
          final c = navigator.currentContext;
          if (c != null && c.mounted && AccountAccess.unlocked.value != null) {
            ScaffoldMessenger.of(c).showSnackBar(
              SnackBar(
                content: const Text('You have a FarmerPlus update.'),
                action: SnackBarAction(
                  label: 'Open',
                  onPressed: () => queue('push:$id'),
                ),
              ),
            );
          }
        });
        taps = FirebaseMessaging.onMessageOpenedApp.listen((m) {
          final id = pushNotificationId(m.data);
          if (id != null) queue('push:$id');
        });
        final initial = await FirebaseMessaging.instance.getInitialMessage();
        if (initial != null) {
          final id = pushNotificationId(initial.data);
          if (id != null) pendingRoute = 'push:$id';
        }
        ready = true;
        status = 'Enable notifications in Settings';
      } catch (_) {
        status = 'Push unavailable. Your Inbox and saved work still work.';
      }
    }
    connectivity = Connectivity().onConnectivityChanged.listen(
      (_) => changed(),
    );
    retry = Timer.periodic(const Duration(minutes: 5), (_) => changed());
    changed();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) changed();
  }

  void changed() {
    unawaited(refresh());
    unawaited(drain());
  }

  void queue(String route) {
    if (!route.startsWith('task:') && !route.startsWith('push:')) return;
    pendingRoute = route;
    unawaited(drain());
  }

  Future<Map<String, dynamic>> preferences() async {
    final key = await scope();
    return Map<String, dynamic>.from(
      await store.setting('pushPreferences:$key') ??
          {
            'learning': true,
            'planner': true,
            'account': true,
            'general': true,
            'quietStart': null,
            'quietEnd': null,
          },
    );
  }

  Future<void> savePreferences(Map<String, dynamic> value) async {
    final key = await scope();
    if (key == null) return;
    await store.setSetting('pushPreferences:$key', value);
    _registrationSignature = null;
    await refresh();
  }

  Future<void> enable() async {
    if (!ready) return;
    final permission = await FirebaseMessaging.instance.requestPermission();
    final allowed =
        permission.authorizationStatus == AuthorizationStatus.authorized ||
        permission.authorizationStatus == AuthorizationStatus.provisional;
    await store.setSetting('pushOptIn', allowed);
    if (!allowed) {
      status = 'Notifications disabled in Android Settings';
      notifyListeners();
      return;
    }
    final prefs = await preferences();
    for (final category in ['learning', 'planner', 'account', 'general']) {
      prefs[category] = true;
    }
    final key = await scope();
    if (key != null) await store.setSetting('pushPreferences:$key', prefs);
    await FirebaseMessaging.instance.setAutoInitEnabled(true);
    _registrationSignature = null;
    await refresh();
  }

  Future<bool> enabled() async {
    if (!ready || await store.setting('pushOptIn') != true) return false;
    final p = await FirebaseMessaging.instance.getNotificationSettings();
    return p.authorizationStatus == AuthorizationStatus.authorized ||
        p.authorizationStatus == AuthorizationStatus.provisional;
  }

  Future<void> disable() async {
    await store.setSetting('pushOptIn', false);
    final key = await scope();
    if (key != null) {
      await store.setSetting(
        'pushRevoke:$key',
        await store.setting('pushDevice:$key'),
      );
    }
    _registrationSignature = null;
    status = 'Off — pending server confirmation';
    if (ready) {
      try {
        await FirebaseMessaging.instance.setAutoInitEnabled(false);
        await FirebaseMessaging.instance.deleteToken();
      } catch (_) {}
    }
    notifyListeners();
    await refresh();
  }

  Future<void> refresh({bool forceRegistration = false}) async {
    if (busy) return;
    if (forceRegistration) _registrationSignature = null;
    final key = await scope();
    if (key == null) return;
    busy = true;
    final revision = sync.credentialRevision;
    try {
      if (_scope != key) {
        _scope = key;
        _registrationSignature = null;
      }
      try {
        final revokeDevice = await store.setting('pushRevoke:$key');
        if (revokeDevice != null) {
          await sync.request(
            'DELETE',
            '/notifications/registration/$revokeDevice',
          );
          await store.setSetting('pushRevoke:$key', null);
          status = 'Notifications off';
        }
        if (ready && await store.setting('pushOptIn') == true) {
          final permission = await FirebaseMessaging.instance
              .getNotificationSettings();
          var device = await store.setting('pushDevice:$key');
          if (device is! String) {
            device = uuid.v4();
            await store.setSetting('pushDevice:$key', device);
          }
          final token = await FirebaseMessaging.instance.getToken();
          if (token != null) {
            final info = await PackageInfo.fromPlatform();
            final prefs = await preferences();
            for (final category in [
              'learning',
              'planner',
              'account',
              'general',
            ]) {
              prefs[category] = true;
            }
            final body = {
              'deviceId': device,
              'token': token,
              'permission': permission.authorizationStatus.name,
              'version': '${info.version}+${info.buildNumber}',
              'preferences': {
                ...prefs,
                'utcOffsetMinutes': DateTime.now().timeZoneOffset.inMinutes,
              },
            };
            final signature = jsonEncode(body);
            if (_registrationSignature != signature) {
              final ack = await sync.request(
                'PUT',
                '/notifications/registration',
                body: body,
              );
              if (ack['ack'] == 'y' &&
                  ack['owner'] == await store.setting('boundOwner') &&
                  revision == sync.credentialRevision) {
                _registrationSignature = signature;
                status =
                    permission.authorizationStatus == AuthorizationStatus.denied
                    ? 'Notifications disabled in Android Settings'
                    : 'Notifications enabled — synced';
              }
            }
          }
        }
      } catch (_) {
        status = await store.setting('pushOptIn') == true
            ? 'Pending — notification settings saved on this phone'
            : 'Off on this phone — pending server confirmation';
      }
      final result = await sync.request('GET', '/notifications');
      if (await scope() != key || revision != sync.credentialRevision) return;
      final page = List<Map<String, dynamic>>.from(
        result['items'].map((e) => Map<String, dynamic>.from(e)),
      );
      await store.setSetting(
        'pushCursor:$key',
        page.length == 100
            ? {'created': page.last['created'], 'id': page.last['id']}
            : null,
      );
      final old = await cached();
      final merged = {
        for (final row in old) row['id']: row,
        for (final row in result['items']) row['id']: row,
      };
      final readIds = List<String>.from(
        await store.setting('pushRead:$key') ?? [],
      );
      for (final id in readIds) {
        if (merged[id] != null) {
          merged[id]['read'] ??= DateTime.now().millisecondsSinceEpoch;
        }
      }
      await store.setSetting('pushInbox:$key', merged.values.toList());
      await store.setSetting('pushInboxFetched:$key', result['fetchedAt']);
      for (final id in readIds.toList()) {
        if (await scope() != key || revision != sync.credentialRevision) break;
        await sync.request('POST', '/notifications/$id/read');
        readIds.remove(id);
        await store.setSetting('pushRead:$key', readIds);
      }
    } catch (_) {
      status = ready ? 'Waiting to connect • saved Inbox is available' : status;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<List<Map<String, dynamic>>> cached() async {
    final key = await scope();
    if (key == null) return [];
    return (await store.setting('pushInbox:$key') as List? ?? [])
        .map((e) => Map<String, dynamic>.from(e))
        .toList()
      ..sort((a, b) => (b['created'] as int).compareTo(a['created'] as int));
  }

  Future<void> older() async {
    final key = await scope(), rows = await cached();
    if (key == null || rows.isEmpty) return;
    final tail = await store.setting('pushCursor:$key');
    if (tail == null) return;
    final result = await sync.request(
      'GET',
      '/notifications?before=${tail['created']}&beforeId=${tail['id']}',
    );
    if (key != await scope()) return;
    final page = List<Map<String, dynamic>>.from(
      result['items'].map((e) => Map<String, dynamic>.from(e)),
    );
    await store.setSetting(
      'pushCursor:$key',
      page.length == 100
          ? {'created': page.last['created'], 'id': page.last['id']}
          : null,
    );
    final merged = {
      for (final r in rows) r['id']: r,
      for (final r in result['items']) r['id']: r,
    };
    await store.setSetting('pushInbox:$key', merged.values.toList());
    notifyListeners();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    AccountAccess.unlocked.removeListener(changed);
    retry?.cancel();
    connectivity?.cancel();
    tokenChanges?.cancel();
    foreground?.cancel();
    taps?.cancel();
    sync.beforeLogout = null;
    _instances.remove(store);
    super.dispose();
  }

  Future<void> markRead(String id) async {
    final key = await scope();
    if (key == null) return;
    final pending = List<String>.from(
      await store.setting('pushRead:$key') ?? [],
    );
    if (!pending.contains(id)) pending.add(id);
    await store.setSetting('pushRead:$key', pending);
    final rows = await cached();
    for (final row in rows) {
      if (row['id'] == id) row['read'] = DateTime.now().millisecondsSinceEpoch;
    }
    await store.setSetting('pushInbox:$key', rows);
    notifyListeners();
    unawaited(refresh());
  }

  Future<void> drain() async {
    if (opening || pendingRoute == null || await scope() == null) return;
    final c = navigator.currentContext;
    if (c == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(drain()));
      return;
    }
    final route = pendingRoute!;
    pendingRoute = null;
    opening = true;
    try {
      if (route.startsWith('task:')) {
        if (c.mounted) {
          openPage(
            c,
            RecordsPage(
              store: store,
              reminders: reminders,
              kind: 'task',
              focusId: route.substring(5),
            ),
          );
        }
      } else {
        final id = route.substring(5);
        if (pushNotificationId({'schemaVersion': '1', 'notificationId': id}) ==
            null) {
          return;
        }
        if (c.mounted) openPage(c, PushMessagePage(service: this, id: id));
      }
    } finally {
      opening = false;
    }
  }

  Future<void> revoke() async {
    final key = await scope();
    if (key != null) {
      final device = await store.setting('pushDevice:$key');
      if (device != null) {
        try {
          await sync.request('DELETE', '/notifications/registration/$device');
        } catch (_) {}
      }
      await store.setSetting('pushDevice:$key', null);
    }
    pendingRoute = null;
    _registrationSignature = null;
    if (ready) {
      try {
        await FirebaseMessaging.instance.setAutoInitEnabled(false);
        await FirebaseMessaging.instance.deleteToken();
      } catch (_) {}
    }
    await store.setSetting('pushOptIn', false);
    // Generic OS previews contain no account data, even if offline revoke fails.
  }
}

class PushInboxSection extends StatefulWidget {
  final PushService service;
  const PushInboxSection({super.key, required this.service});
  @override
  State<PushInboxSection> createState() => _PushInboxSectionState();
}

class _PushInboxSectionState extends State<PushInboxSection> {
  List<Map<String, dynamic>> rows = [];
  @override
  void initState() {
    super.initState();
    widget.service.addListener(load);
    load();
    unawaited(widget.service.refresh());
  }

  Future<void> load() async {
    final result = await widget.service.cached();
    if (mounted) setState(() => rows = result);
  }

  @override
  void dispose() {
    widget.service.removeListener(load);
    super.dispose();
  }

  @override
  Widget build(BuildContext c) => Column(
    children: [
      ListTile(
        title: const Text('Updates from FarmerPlus'),
        subtitle: Text(widget.service.status),
        trailing: IconButton(
          tooltip: 'Refresh updates',
          onPressed: widget.service.refresh,
          icon: const Icon(Icons.refresh),
        ),
      ),
      for (final row in rows)
        ListTile(
          leading: Icon(
            row['read'] == null
                ? Icons.mark_email_unread_outlined
                : Icons.drafts_outlined,
          ),
          title: Text(row['title']),
          subtitle: Text(row['category']),
          onTap: () => openPage(
            c,
            PushMessagePage(service: widget.service, id: row['id']),
          ),
        ),
      if (rows.length >= 100)
        TextButton(
          onPressed: () => guarded(c, widget.service.older),
          child: const Text('Load older updates'),
        ),
    ],
  );
}

class PushMessagePage extends StatefulWidget {
  final PushService service;
  final String id;
  const PushMessagePage({super.key, required this.service, required this.id});
  @override
  State<PushMessagePage> createState() => _PushMessagePageState();
}

class _PushMessagePageState extends State<PushMessagePage> {
  Map<String, dynamic>? row;
  bool loading = true, fresh = false;
  String? message;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    if (mounted) setState(() => loading = true);
    final s = widget.service, key = await widget.service.scope();
    final revision = s.sync.credentialRevision;
    try {
      final data = await s.sync.request('GET', '/notifications/${widget.id}');
      if (key == null ||
          key != await s.scope() ||
          revision != s.sync.credentialRevision) {
        return;
      }
      row = Map<String, dynamic>.from(data);
      fresh = true;
      message = null;
      await s.markRead(widget.id);
    } catch (e) {
      if (key != await s.scope()) return;
      if (e is SyncRequestError && [401, 403, 404].contains(e.statusCode)) {
        row = null;
        message = 'This update is not available for the signed-in account.';
      } else {
        row = (await s.cached()).where((r) => r['id'] == widget.id).firstOrNull;
        message = row == null
            ? 'Connect to load this update.'
            : 'Saved copy • reconnect for the latest information.';
      }
      fresh = false;
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext c) => PageFrame(
    'Update',
    children: [
      if (loading) const LinearProgressIndicator(),
      if (message != null) Text(message!),
      if (row != null) ...[
        Text(row!['title'], style: Theme.of(c).textTheme.headlineSmall),
        Text(row!['body']),
        if (fresh &&
            row!['destination'] == 'task' &&
            row!['latestRecord'] != null) ...[
          const Divider(),
          const Text('Latest task from the backend'),
          Text(
            (row!['latestRecord']['data']['title'] ?? 'Planner task')
                .toString(),
          ),
          Text('Your local edits have not been overwritten.'),
          Text((row!['latestRecord']['data']['notes'] ?? '').toString()),
          Text(
            row!['latestRecord']['data']['completed'] == true
                ? 'Completed'
                : 'Not completed',
          ),
          FilledButton(
            onPressed: () => openPage(
              c,
              RecordsPage(
                store: widget.service.store,
                reminders: widget.service.reminders,
                kind: 'task',
                focusId: row!['resource'],
              ),
            ),
            child: const Text('Open Planner'),
          ),
        ],
        if (fresh && row!['destination'] == 'learning')
          FilledButton(
            onPressed: () =>
                openPage(c, LearningPage(store: widget.service.store)),
            child: const Text('Open Learning'),
          ),
      ],
      TextButton.icon(
        onPressed: load,
        icon: const Icon(Icons.refresh),
        label: const Text('Fetch latest'),
      ),
    ],
  );
}

class PushSettings extends StatefulWidget {
  final PushService service;
  const PushSettings({super.key, required this.service});
  @override
  State<PushSettings> createState() => _PushSettingsState();
}

class _PushSettingsState extends State<PushSettings> {
  Map<String, dynamic> prefs = {};
  bool enabled = false, saving = false;
  @override
  void initState() {
    super.initState();
    widget.service.addListener(changed);
    load();
  }

  void changed() {
    load();
  }

  Future<void> load() async {
    final p = await widget.service.preferences();
    final e = await widget.service.enabled();
    if (mounted) {
      setState(() {
        prefs = p;
        enabled = e;
      });
    }
  }

  @override
  void dispose() {
    widget.service.removeListener(changed);
    super.dispose();
  }

  Future<void> save(String key, dynamic value) async {
    setState(() => prefs[key] = value);
    await widget.service.savePreferences(prefs);
  }

  @override
  Widget build(BuildContext c) => Column(
    children: [
      SwitchListTile(
        title: const Text('Enable notifications'),
        subtitle: Text(widget.service.status),
        value: enabled,
        onChanged: saving || !widget.service.ready
            ? null
            : (v) async {
                setState(() => saving = true);
                await guarded(
                  c,
                  v ? widget.service.enable : widget.service.disable,
                );
                await load();
                if (mounted) setState(() => saving = false);
              },
      ),
      if (enabled)
        SwitchListTile(
          title: const Text('Quiet times: 22:00–07:00'),
          subtitle: const Text(
            'Push waits until morning. Inbox updates remain available.',
          ),
          value: prefs['quietStart'] != null,
          onChanged: (v) async {
            prefs['quietEnd'] = v ? 7 : null;
            await save('quietStart', v ? 22 : null);
          },
        ),
    ],
  );
}
