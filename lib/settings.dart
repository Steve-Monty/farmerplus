import 'dart:convert';
import 'push.dart';
import 'community.dart';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'store.dart';
import 'sync.dart';
import 'background.dart';
import 'services.dart';
import 'ui.dart';
import 'auth.dart';
import 'appearance.dart';
import 'profile.dart';
export 'profile.dart';

import 'backup.dart';
import 'offline_readiness.dart';
import 'map_downloads.dart';
import 'offline_access.dart';
import 'domain.dart';
import 'miniapps.dart';
import 'sign_in_location.dart';
import 'pwa_auth.dart' show KeycloakAccountSecurity;

bool _logoutBusy = false;
Future<void> logOut(BuildContext c, FarmStore store, SyncEngine sync) async {
  if (_logoutBusy) return;
  _logoutBusy = true;
  try {
    final pending = await store.db.query('queue');
    if (!c.mounted) return;
    {
      final confirmed = await showDialog<bool>(
        context: c,
        builder: (d) => AlertDialog(
          title: Text(
            pending.isNotEmpty
                ? 'Log out with unsynced changes?'
                : 'Log out of FarmerPlus?',
          ),
          content: Text(
            pending.isNotEmpty
                ? '${pending.length} changes are saved only on this phone. Your records and downloads will stay here. Sign back into the same account to sync them.'
                : 'Your saved records and downloads will stay on this phone. You will need to sign in again to open them.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(d, false),
              child: const Text('Stay signed in'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(d, true),
              child: const Text('Log out'),
            ),
          ],
        ),
      );
      if (confirmed != true || !c.mounted) return;
    }
    await AccountAccess.signOut(store, sync);
    if (c.mounted) Navigator.of(c).popUntil((r) => r.isFirst);
  } finally {
    _logoutBusy = false;
  }
}

class SettingsPage extends StatelessWidget {
  final FarmStore store;
  final SyncEngine sync;
  final Reminders reminders;
  const SettingsPage({
    super.key,
    required this.store,
    required this.sync,
    required this.reminders,
  });

  Widget row(
    BuildContext c,
    IconData icon,
    String title,
    String description,
    Widget page,
  ) => SurfaceCard(
    child: ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      leading: Container(
        width: 52,
        height: 56,
        decoration: BoxDecoration(
          color: title == 'Notifications'
              ? const Color(0xfffff1cc)
              : title == 'Data sharing'
              ? const Color(0xffece6ff)
              : title == 'Account & security' || title == 'Storage & offline'
              ? const Color(0xffdff0ff)
              : const Color(0xffdef4e9),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Icon(
          icon,
          size: 30,
          color: title == 'Data sharing'
              ? const Color(0xff584091)
              : const Color(0xff155845),
        ),
      ),
      title: Text(
        title,
        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 5),
        child: Text(
          description,
          style: const TextStyle(color: Color(0xff566780), height: 1.35),
        ),
      ),
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: () => openPage(c, page),
    ),
  );

  @override
  Widget build(BuildContext c) => AnimatedBuilder(
    animation: store,
    builder: (c, _) => FutureBuilder<List<dynamic>>(
      future: Future.wait([
        store.ready('coop'),
        store.setting('primaryActivity'),
        store.db.query('queue'),
        store.setting('lastGpsFix'),
        store.setting('signInLocationStatus'),
      ]),
      builder: (c, snapshot) => PageFrame(
        'Settings',
        children: [
          const Padding(
            padding: EdgeInsets.only(bottom: 24),
            child: Text(
              'Manage your account, app preferences and more.',
              style: TextStyle(color: Color(0xff526778), fontSize: 16),
            ),
          ),
          row(
            c,
            Icons.person_outline,
            'Your profile',
            'Personal details, farming activity and units',
            ProfilePage(store: store),
          ),
          row(
            c,
            Icons.shield_outlined,
            'Account & security',
            'Password, sign-in and offline access',
            AccountPage(store: store, sync: sync),
          ),
          row(
            c,
            Icons.location_on_outlined,
            'Location & weather',
            snapshot.data == null
                ? 'GPS, weather and backend location status'
                : snapshot.data![3] == null
                ? 'GPS not captured · Tap to retry'
                : snapshot.data![4] ?? 'GPS captured on this phone',
            LocationWeatherSettingsPage(store: store, sync: sync),
          ),
          row(
            c,
            Icons.notifications_outlined,
            'Notifications',
            'Updates, quiet times and activity reminders',
            NotificationSettingsPage(store: store, reminders: reminders),
          ),
          row(
            c,
            Icons.people_outline,
            'Data sharing',
            snapshot.data == null
                ? 'Your choices and approved organisations'
                : snapshot.data![0] == true
                ? 'Coop installed · Sharing managed automatically'
                : 'Coop not installed · Cooperative sharing off',
            DataSharingPage(service: CommunityService.of(store, sync)),
          ),
          row(
            c,
            Icons.palette_outlined,
            'Appearance',
            'Wallpaper and display preferences',
            PageFrame(
              'Appearance',
              children: [AppearanceSettings(store: store)],
            ),
          ),
          row(
            c,
            Icons.storage_rounded,
            'Storage & offline',
            snapshot.data == null
                ? 'Downloads, backups and sync'
                : '${(snapshot.data![2] as List).length} pending changes · Downloads and backups',
            StorageSettingsPage(store: store, sync: sync, reminders: reminders),
          ),
          const Divider(),
          ListTile(
            leading: Container(
              width: 52,
              height: 56,
              decoration: BoxDecoration(
                color: const Color(0xffffe6e6),
                borderRadius: BorderRadius.circular(16),
              ),
              child: const Icon(Icons.logout, color: Color(0xffb32020)),
            ),
            title: const Text(
              'Log out',
              style: TextStyle(
                color: Color(0xffb32020),
                fontWeight: FontWeight.w700,
              ),
            ),
            subtitle: const Text(
              'Keep saved records and downloads on this phone',
            ),
            onTap: () => guarded(c, () => logOut(c, store, sync)),
          ),
        ],
      ),
    ),
  );
}

class LocationWeatherSettingsPage extends StatefulWidget {
  final FarmStore store;
  final SyncEngine sync;
  const LocationWeatherSettingsPage({
    super.key,
    required this.store,
    required this.sync,
  });
  @override
  State<LocationWeatherSettingsPage> createState() =>
      _LocationWeatherSettingsPageState();
}

class _LocationWeatherSettingsPageState
    extends State<LocationWeatherSettingsPage> {
  Map<String, dynamic>? fix, registration, weather;
  String country = 'Unavailable', locationStatus = 'Location not captured';
  String? locationError;
  String backendStatus = 'Not recorded';
  bool busy = false, weatherEnabled = false;

  @override
  void initState() {
    super.initState();
    widget.store.addListener(load);
    load();
  }

  @override
  void dispose() {
    widget.store.removeListener(load);
    super.dispose();
  }

  Future<void> load() async {
    final lastFix = await widget.store.setting('lastGpsFix');
    final savedRegistration = await widget.store.setting(
      'registrationLocation',
    );
    final savedCountry = await widget.store.setting('gpsCountry');
    final savedWeather = await WeatherService(widget.store).cached();
    final status = await widget.store.setting('signInLocationStatus');
    final savedError = await widget.store.setting('signInLocationError');
    final enabled = await widget.store.setting('weatherEnabled') == true;
    final registrations = (await widget.store.records(
      'pin',
    )).where((r) => r['data']['purpose'] == 'registration').toList();
    var syncState = 'Not recorded';
    if (registrations.isNotEmpty) {
      final record = registrations.first;
      final queued = await widget.store.db.query(
        'queue',
        columns: ['id'],
        where: 'id=?',
        whereArgs: [record['id']],
        limit: 1,
      );
      syncState = queued.isNotEmpty
          ? 'Waiting to sync'
          : (record['version'] as num? ?? 0) > 0
          ? 'Synced with backend'
          : 'Saved on this phone';
    }
    if (!mounted) return;
    setState(() {
      fix = lastFix == null ? null : Map<String, dynamic>.from(lastFix);
      registration = savedRegistration == null
          ? null
          : Map<String, dynamic>.from(savedRegistration);
      weather = savedWeather;
      country = savedCountry ?? 'Unavailable';
      locationStatus = status ?? 'Location not captured';
      locationError = savedError;
      backendStatus = syncState;
      weatherEnabled = enabled;
    });
  }

  Future<void> refresh() async {
    if (busy || widget.sync.token == null) return;
    setState(() => busy = true);
    try {
      await OnlineSignInLocation.captureAndSync(widget.store, widget.sync);
      await load();
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PageFrame(
    'Location & weather',
    children: [
      SwitchListTile.adaptive(
        contentPadding: EdgeInsets.zero,
        value: weatherEnabled,
        title: const Text('Show weather'),
        subtitle: Text(
          weatherEnabled
              ? 'Weather requests are enabled.'
              : 'Off · FarmerPlus does not request or display weather.',
        ),
        onChanged: busy
            ? null
            : (value) async {
                await widget.store.setSetting('weatherEnabled', value);
                if (mounted) setState(() => weatherEnabled = value);
                if (value) await refresh();
              },
      ),
      heading(context, 'Sign-in location'),
      if (fix == null)
        note(
          'No GPS location has been captured for this account.',
          icon: Icons.location_off_outlined,
        )
      else
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.gps_fixed),
          title: Text(
            '${(fix!['lat'] as num).toStringAsFixed(5)}, '
            '${(fix!['lon'] as num).toStringAsFixed(5)}',
          ),
          subtitle: Text(
            'Accuracy ${(fix!['accuracy'] as num?)?.toStringAsFixed(0) ?? 'unknown'} m'
            '${fix!['updated'] == null ? '' : ' · ${stamp(fix!['updated'])}'}',
          ),
        ),
      note(locationStatus),
      if (locationError != null && locationError!.isNotEmpty)
        note(locationError!),
      ListTile(
        contentPadding: EdgeInsets.zero,
        leading: const Icon(Icons.public),
        title: Text(country),
        subtitle: const Text('Country from device location'),
      ),
      ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Icon(
          backendStatus == 'Synced with backend'
              ? Icons.cloud_done_outlined
              : Icons.cloud_upload_outlined,
        ),
        title: Text(backendStatus),
        subtitle: Text(
          registration == null
              ? 'Registration location'
              : 'Registration location · ${stamp(registration!['capturedAt'])}',
        ),
      ),
      if (weatherEnabled)
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.cloud_outlined),
          title: Text(
            weather == null ? 'Weather unavailable' : 'Weather ready',
          ),
          subtitle: Text(
            weather == null
                ? 'A GPS fix and connection are required.'
                : 'Using ${weather!['source'] ?? 'your location'} · ${stamp(weather!['updated'])}',
          ),
        ),
      FilledButton.icon(
        onPressed: busy || widget.sync.token == null ? null : refresh,
        icon: const Icon(Icons.my_location),
        label: Text(
          busy
              ? 'Updating location…'
              : weatherEnabled
              ? 'Refresh location, weather & sync'
              : 'Refresh location & sync',
        ),
      ),
      note(
        weatherEnabled
            ? 'Weather uses your chosen location. The registration location is queued until the backend acknowledges it.'
            : 'Weather is off, so no forecast request is made. The registration location is queued until the backend acknowledges it.',
      ),
    ],
  );
}

class DataSharingPage extends StatelessWidget {
  final CommunityService service;
  const DataSharingPage({super.key, required this.service});
  @override
  Widget build(BuildContext c) => PageFrame(
    'Data sharing',
    children: [
      ShareDataSettings(
        service: service,
        onManageCoop: () => openPage(
          c,
          InstallPage(
            store: service.store,
            app: catalogue.firstWhere((a) => a.id == 'coop'),
            onOpen: () => openPage(c, CoopPage(service: service)),
          ),
        ),
      ),
    ],
  );
}

class NotificationSettingsPage extends StatefulWidget {
  final FarmStore store;
  final Reminders reminders;
  const NotificationSettingsPage({
    super.key,
    required this.store,
    required this.reminders,
  });
  @override
  State<NotificationSettingsPage> createState() =>
      _NotificationSettingsPageState();
}

class _NotificationSettingsPageState extends State<NotificationSettingsPage> {
  bool? remind;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    final value = await widget.store.setting('reminders') ?? true;
    if (mounted) setState(() => remind = value);
  }

  @override
  Widget build(BuildContext c) => PageFrame(
    'Notifications',
    children: [
      if (PushService.of(widget.store) case final service?)
        PushSettings(service: service),
      const Divider(),
      if (remind != null)
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Activity reminders'),
          subtitle: const Text('Reminders for your planned farm activities'),
          value: remind!,
          onChanged: (v) => guarded(c, () async {
            await widget.store.setSetting('reminders', v);
            if (!v) {
              for (final task in await widget.store.records('task')) {
                await widget.reminders.cancel(task['id']);
              }
            }
            if (mounted) setState(() => remind = v);
          }),
        ),
    ],
  );
}

Future<int> _browserStorageBytes(FarmStore store) async {
  var bytes = 0;
  for (final table in const [
    'settings',
    'records',
    'queue',
    'conflicts',
    'installs',
  ]) {
    for (final row in await store.db.query(table)) {
      bytes += utf8.encode(jsonEncode(row)).length;
    }
  }
  return bytes;
}

Future<List<Map<String, dynamic>>> _browserMapRegions(FarmStore store) async {
  final raw = await store.setting('downloadedMapPacks');
  final packs = raw is List
      ? raw.map((value) => Map<String, dynamic>.from(value as Map)).toList()
      : <Map<String, dynamic>>[];
  final active = await store.setting('activeMapPack');
  final regions = <Map<String, dynamic>>[];
  for (final pack in packs) {
    final id = pack['id']?.toString();
    if (id == null || id.isEmpty) continue;
    final encoded = await store.setting('browserMap:$id');
    var actualBytes = 0;
    if (encoded is String) {
      try {
        actualBytes = base64Decode(encoded).length;
      } on FormatException {
        actualBytes = 0;
      }
    }
    final bounds = pack['bbox'] ?? pack['bounds'];
    regions.add({
      ...pack,
      'id': id,
      'name': pack['name'] ?? 'Downloaded map area',
      'complete':
          actualBytes > 0 &&
          (pack['bytes'] == null || pack['bytes'] == actualBytes),
      'bytes': actualBytes,
      'coverage': bounds is List ? bounds.join(', ') : 'Saved farm area',
      'zoom': '0–${pack['zoom'] ?? pack['maxZoom'] ?? 15}',
      'authorization': {
        'attribution': pack['attribution'],
        'license': pack['license'] ?? pack['licence'],
      },
      'imported': pack['downloaded'],
      'enabled': active == id,
    });
  }
  return regions;
}

Future<void> _removeBrowserMap(
  FarmStore store,
  Map<String, dynamic> region,
) async {
  final id = region['id']?.toString();
  if (id == null || id.isEmpty) return;
  await store.setSetting('browserMap:$id', null);
  final raw = await store.setting('downloadedMapPacks');
  final packs = raw is List
      ? raw.map((value) => Map<String, dynamic>.from(value as Map)).toList()
      : <Map<String, dynamic>>[];
  packs.removeWhere((pack) => pack['id']?.toString() == id);
  await store.setSetting('downloadedMapPacks', packs);
  if (await store.setting('activeMapPack') == id) {
    await store.setSetting('activeMapPack', null);
  }
}

class StorageSettingsPage extends StatefulWidget {
  final FarmStore store;
  final SyncEngine sync;
  final Reminders reminders;
  const StorageSettingsPage({
    super.key,
    required this.store,
    required this.sync,
    required this.reminders,
  });
  @override
  State<StorageSettingsPage> createState() => _StorageSettingsPageState();
}

class _StorageSettingsPageState extends State<StorageSettingsPage> {
  final server = TextEditingController(),
      username = TextEditingController(),
      password = TextEditingController();
  String mode = 'automatic', last = 'Never';
  bool consent = false, remind = true, loaded = false, working = false;
  int queued = 0, bytes = 0;
  List<Map<String, Object?>> conflicts = [];
  List<Map<String, dynamic>> regions = [];
  @override
  void initState() {
    super.initState();
    widget.sync.addListener(changed);
    load();
  }

  void changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.sync.removeListener(changed);
    for (final c in [server, username, password]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> load() async {
    server.text = await widget.sync.base();
    mode = await widget.store.setting('syncMode') ?? 'automatic';
    consent = await widget.store.setting('consent') ?? false;
    remind = await widget.store.setting('reminders') ?? true;
    last = stamp(await widget.store.setting('lastSync'));
    queued = (await widget.store.db.query('queue')).length;
    conflicts = await widget.store.db.query('conflicts');
    bytes = 0;
    if (kIsWeb) {
      bytes = await _browserStorageBytes(widget.store);
      regions = await _browserMapRegions(widget.store);
      if (mounted) setState(() => loaded = true);
      return;
    }
    await for (final f in Directory(
      widget.store.filesPath,
    ).list(recursive: true)) {
      if (f is File) bytes += await f.length();
    }
    try {
      regions = [];
      for (final r in await getListOfRegions()) {
        final state = await getOfflineRegionStatus(r.id);
        regions.add({
          'id': r.id,
          'name': r.metadata['name'] ?? 'Imported map region',
          'complete': state.isComplete,
          'bytes': state.completedResourceSize,
          'style': r.definition.mapStyleUrl,
          'coverage':
              '${r.definition.bounds.southwest.latitude.toStringAsFixed(3)}, ${r.definition.bounds.southwest.longitude.toStringAsFixed(3)} to ${r.definition.bounds.northeast.latitude.toStringAsFixed(3)}, ${r.definition.bounds.northeast.longitude.toStringAsFixed(3)}',
          'zoom': '${r.definition.minZoom}–${r.definition.maxZoom}',
          'metadata': r.metadata,
          'authorization': await widget.store.setting(
            'mapAuthorization:${r.id}',
          ),
          'enabled': await widget.store.setting('mapEnabled') == r.id,
        });
      }
    } catch (_) {}
    if (mounted) setState(() => loaded = true);
  }

  Future<void> config() async {
    await widget.store.setSetting('consent', true);
    await widget.store.setSetting('syncMode', mode);
  }

  Future<dynamic> phoneReportStatus() async {
    final owner = await widget.store.setting('boundOwner');
    final bound = await widget.store.setting('boundServer');
    return widget.store.setting('phoneReport:$owner:$bound');
  }

  Future<void> importMap() async {
    if (kIsWeb) {
      throw StateError(
        'MapLibre database imports require the Android app. Download a prepared browser map area instead.',
      );
    }
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['db'],
    );
    final source = picked?.files.single.path;
    if (source == null) return;
    final input = File(source);
    if (await input.length() > 500 * 1024 * 1024) {
      throw StateError('Map pack exceeds 500 MB.');
    }
    final handle = await input.open();
    final header = await handle.read(16);
    await handle.close();
    if (utf8.decode(header, allowMalformed: true) != 'SQLite format 3\u0000') {
      throw StateError('Choose a valid MapLibre SQLite region database.');
    }
    final copy = await File(
      source,
    ).copy('${widget.store.filesPath}/import-map.db');
    final imported = await mergeOfflineRegions(copy.path);
    if (imported.isEmpty) {
      throw StateError(
        'This file contains no supported MapLibre offline regions.',
      );
    }
    await load();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Map imported but not enabled. Review its source, licence and coverage below.',
          ),
        ),
      );
    }
  }

  Future<void> authorizeMap(Map<String, dynamic> region) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            MapAuthorizationPage(store: widget.store, region: region),
      ),
    );
    await load();
  }

  @override
  Widget build(BuildContext c) => PageFrame(
    'Storage & offline',
    children: [
      ListTile(
        leading: const Icon(Icons.offline_pin_outlined),
        title: const Text('Ready for offline'),
        subtitle: const Text('Check what will work without a connection'),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => openPage(c, OfflineReadinessPage(store: widget.store)),
      ),
      heading(c, 'Storage & sync'),
      ListTile(
        leading: const Icon(Icons.backup_outlined),
        title: const Text('Backup & boundary files'),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => openPage(c, BackupPage(store: widget.store)),
      ),
      Text(
        '${(bytes / 1024).toStringAsFixed(1)} KB saved on this phone\n$queued pending changes • Last sync: $last',
      ),
      note(widget.sync.status),
      if (loaded)
        DropdownButtonFormField(
          initialValue: mode,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'When to synchronise'),
          items: const [
            DropdownMenuItem(value: 'automatic', child: Text('Automatic')),
            DropdownMenuItem(value: 'wifi', child: Text('Wi-Fi only')),
            DropdownMenuItem(value: 'manual', child: Text('Manual')),
          ],
          onChanged: (v) => guarded(c, () async {
            await widget.store.setSetting('syncMode', v);
            if (mounted) setState(() => mode = v!);
            await widget.store.setSetting('consent', true);
            await schedulePendingSync(widget.store);
            await widget.sync.automatic();
            await CommunityService.of(widget.store, widget.sync).refresh();
          }),
        ),
      OutlinedButton.icon(
        onPressed: widget.sync.token == null || widget.sync.busy
            ? null
            : () => guarded(c, () async {
                await config();
                await widget.sync.sync();
                await CommunityService.of(
                  widget.store,
                  widget.sync,
                ).refresh(explicit: true);
                await load();
              }),
        icon: const Icon(Icons.sync),
        label: const Text('Sync now'),
      ),
      ExpansionTile(
        tilePadding: EdgeInsets.zero,
        title: const Text('Phone information report'),
        children: [
          note(
            'Technical phone details, the raw Android ID and app version are shared with authorised farmer-profile administrators. Personal content is not included.',
          ),
          AnimatedBuilder(
            animation: widget.store,
            builder: (context, child) => FutureBuilder<dynamic>(
              future: phoneReportStatus(),
              builder: (context, snapshot) {
                final report = snapshot.data;
                if (report is! Map) {
                  return const Text(
                    'Pending — waiting to send phone information',
                  );
                }
                final facts = report['body']?['technical'] as Map? ?? {};
                return SelectableText(
                  '${report['ack'] == 'y' ? 'Phone information received' : 'Pending — waiting to send phone information'}\nPhone ID: ${facts['androidId'] ?? facts['phoneIdentifier'] ?? 'Unavailable'}\nFarmerPlus ${facts['versionName'] ?? 'Unknown'} · Build ${facts['versionCode'] ?? 'Unknown'}',
                );
              },
            ),
          ),
          TextButton.icon(
            onPressed: () =>
                guarded(c, () => widget.sync.reportPhone(explicit: true)),
            icon: const Icon(Icons.refresh),
            label: const Text('Retry phone report'),
          ),
        ],
      ),
      if (conflicts.isNotEmpty) ...[
        heading(c, 'Choose between conflicting edits'),
        for (final conflict in conflicts)
          ListTile(
            title: const Text('Two versions need your choice'),
            subtitle: Text(conflict['id'] as String),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => openPage(
              c,
              ConflictPage(
                store: widget.store,
                id: conflict['id'] as String,
                onResolved: load,
              ),
            ),
          ),
      ],
      heading(c, 'Offline maps'),
      ListTile(
        leading: const Icon(Icons.download_for_offline_outlined),
        title: const Text('Download an area'),
        subtitle: const Text('Choose a radius and manage saved maps'),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => openPage(c, MapDownloadsPage(store: widget.store)),
      ),
      for (final r in regions)
        ListTile(
          title: Text(r['name']),
          subtitle: Text(
            '${r['complete'] == true ? (r['enabled'] == true ? 'Enabled · Ready offline' : 'Complete · awaiting enable') : 'Incomplete · not ready'} • ${r['bytes']} bytes\nCoverage ${r['coverage']} · Zoom ${r['zoom']}\n${r['authorization']?['attribution'] ?? 'Source and licence review required'}',
          ),
          onTap: kIsWeb ? null : () => guarded(c, () => authorizeMap(r)),
          trailing: IconButton(
            tooltip: 'Remove map pack',
            icon: const Icon(Icons.delete_outline),
            onPressed: () => guarded(c, () async {
              if (kIsWeb) {
                await _removeBrowserMap(widget.store, r);
              } else {
                await deleteOfflineRegion(r['id']);
                await widget.store.setSetting(
                  'mapAuthorization:${r['id']}',
                  null,
                );
                if (r['enabled'] == true) {
                  await widget.store.setSetting('mapEnabled', null);
                  await widget.store.setSetting('mapStyle', null);
                }
              }
              await load();
              if (regions.isEmpty) {
                await widget.store.setSetting('mapStyle', null);
              }
            }),
          ),
        ),
      FilledButton(
        onPressed: () => guarded(c, () async {
          await config();
          if (c.mounted) {
            ScaffoldMessenger.of(c).showSnackBar(
              const SnackBar(content: Text('Settings saved on this phone.')),
            );
          }
        }),
        child: const Text('Save settings'),
      ),
    ],
  );
}

class AccountPage extends StatelessWidget {
  final FarmStore store;
  final SyncEngine sync;
  const AccountPage({super.key, required this.store, required this.sync});
  @override
  Widget build(BuildContext c) => kIsWeb
      ? FutureBuilder<dynamic>(
          future: store.setting('accountKind'),
          builder: (context, snapshot) =>
              snapshot.connectionState != ConnectionState.done
              ? const Center(child: CircularProgressIndicator())
              : snapshot.data == 'keycloak'
              ? KeycloakAccountSecurity(store: store, sync: sync)
              : legacyAccount(c),
        )
      : legacyAccount(c);

  Widget legacyAccount(BuildContext c) => PageFrame(
    'Account & security',
    children: [
      Text(
        'One FarmerPlus account',
        style: Theme.of(c).textTheme.headlineMedium,
      ),
      gap(),
      OutlinedButton(
        onPressed: () => guarded(c, () async {
          await logOut(c, store, sync);
        }),
        child: const Text('Log out'),
      ),
      OutlinedButton.icon(
        onPressed: () => guarded(c, () async {
          await OfflineAccess(store, sync).enableBiometric();
          if (c.mounted) {
            ScaffoldMessenger.of(c).showSnackBar(
              const SnackBar(
                content: Text(
                  'Fingerprint unlock enabled. Your password still works.',
                ),
              ),
            );
          }
        }),
        icon: const Icon(Icons.fingerprint),
        label: const Text('Enable fingerprint unlock'),
      ),
      TextButton(
        onPressed: () => guarded(c, () async {
          await OfflineAccess.channel.invokeMethod('biometricClear');
          if (c.mounted) {
            ScaffoldMessenger.of(c).showSnackBar(
              const SnackBar(content: Text('Fingerprint unlock turned off.')),
            );
          }
        }),
        child: const Text('Turn off fingerprint unlock'),
      ),
      OutlinedButton.icon(
        onPressed: () =>
            openPage(c, ChangePasswordPage(store: store, sync: sync)),
        icon: const Icon(Icons.password),
        label: const Text('Change password · online'),
      ),
      OutlinedButton.icon(
        onPressed: () => configureOfflineLogin(c, store, sync),
        icon: const Icon(Icons.lock_outline),
        label: const Text('Enable or update offline login'),
      ),
    ],
  );
}

String? mapAuthorizationIssue({
  required bool complete,
  required String source,
  required String license,
  required String attribution,
  required bool permitted,
}) {
  final url = Uri.tryParse(source);
  if (!complete) {
    return 'This pack is incomplete. Import a complete pack before enabling it.';
  }
  if (url == null ||
      url.scheme != 'https' ||
      url.host.isEmpty ||
      url.userInfo.isNotEmpty) {
    return 'Enter an HTTPS source or publisher page.';
  }
  if (license.trim().length < 3 || attribution.trim().length < 3) {
    return 'Provide the licence and required attribution from the publisher.';
  }
  if (!permitted) return 'Confirm that the licence permits your offline use.';
  return null;
}

class MapAuthorizationPage extends StatefulWidget {
  final FarmStore store;
  final Map<String, dynamic> region;
  const MapAuthorizationPage({
    super.key,
    required this.store,
    required this.region,
  });
  @override
  State<MapAuthorizationPage> createState() => _MapAuthorizationPageState();
}

class OfflineMapStoragePage extends StatefulWidget {
  final FarmStore store;
  const OfflineMapStoragePage({super.key, required this.store});
  @override
  State<OfflineMapStoragePage> createState() => _OfflineMapStoragePageState();
}

class _OfflineMapStoragePageState extends State<OfflineMapStoragePage> {
  List<Map<String, dynamic>> regions = [];
  bool loaded = false;

  @override
  void initState() {
    super.initState();
    load();
  }

  String size(num bytes) {
    if (bytes >= 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '$bytes bytes';
  }

  Future<void> load() async {
    final found = <Map<String, dynamic>>[];
    if (kIsWeb) {
      found.addAll(await _browserMapRegions(widget.store));
    } else {
      try {
        for (final r in await getListOfRegions()) {
          final state = await getOfflineRegionStatus(r.id);
          found.add({
            'id': r.id,
            'name': r.metadata['name'] ?? 'Imported map region',
            'complete': state.isComplete,
            'bytes': state.completedResourceSize,
            'style': r.definition.mapStyleUrl,
            'coverage':
                '${r.definition.bounds.southwest.latitude.toStringAsFixed(3)}, ${r.definition.bounds.southwest.longitude.toStringAsFixed(3)} to ${r.definition.bounds.northeast.latitude.toStringAsFixed(3)}, ${r.definition.bounds.northeast.longitude.toStringAsFixed(3)}',
            'zoom': '${r.definition.minZoom}–${r.definition.maxZoom}',
            'metadata': r.metadata,
            'authorization': await widget.store.setting(
              'mapAuthorization:${r.id}',
            ),
            'imported': await widget.store.setting('mapImportedAt:${r.id}'),
            'enabled': await widget.store.setting('mapEnabled') == r.id,
          });
        }
      } catch (_) {}
    }
    if (mounted) {
      setState(() {
        regions = found;
        loaded = true;
      });
    }
  }

  Future<void> importMap() async {
    if (kIsWeb) {
      throw StateError(
        'MapLibre database imports require the Android app. Download a prepared browser map area instead.',
      );
    }
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['db'],
    );
    final source = picked?.files.single.path;
    if (source == null) return;
    final input = File(source);
    if (await input.length() > 500 * 1024 * 1024) {
      throw StateError('Map pack exceeds 500 MB.');
    }
    final handle = await input.open();
    final header = await handle.read(16);
    await handle.close();
    if (utf8.decode(header, allowMalformed: true) != 'SQLite format 3\u0000') {
      throw StateError('Choose a valid MapLibre SQLite region database.');
    }
    final copy = await input.copy('${widget.store.filesPath}/import-map.db');
    final ids = await mergeOfflineRegions(copy.path);
    if (ids.isEmpty) {
      throw StateError(
        'This file contains no supported MapLibre offline regions.',
      );
    }
    final now = DateTime.now().toUtc().toIso8601String();
    for (final id in ids) {
      await widget.store.setSetting('mapImportedAt:$id', now);
    }
    await load();
  }

  Future<void> remove(Map<String, dynamic> region) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Remove offline map?'),
        content: Text(
          '${region['name']} and its ${size(region['bytes'])} of map data will be removed. Farm and field boundaries stay saved.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Keep map'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (kIsWeb) {
      await _removeBrowserMap(widget.store, region);
    } else {
      await deleteOfflineRegion(region['id']);
      await widget.store.setSetting('mapAuthorization:${region['id']}', null);
      await widget.store.setSetting('mapImportedAt:${region['id']}', null);
      if (region['enabled'] == true) {
        await widget.store.setSetting('mapEnabled', null);
        await widget.store.setSetting('mapStyle', null);
        await widget.store.setSetting('preferredMapLayer', 'offline');
      }
    }
    await load();
  }

  @override
  Widget build(BuildContext c) => PageFrame(
    'Offline maps & storage',
    children: [
      Semantics(
        label: 'Farm setup step 4 of 4. Prepare offline maps.',
        child: const Chip(
          avatar: Icon(Icons.check_circle_outline, size: 18),
          label: Text('Step 4 of 4 · Offline readiness'),
        ),
      ),
      gap(),
      Text(
        'Maps that work without signal',
        style: Theme.of(c).textTheme.headlineMedium,
      ),
      ListTile(
        leading: const Icon(Icons.download_for_offline_outlined),
        title: const Text('Download an area'),
        subtitle: const Text('Choose coverage and manage saved maps'),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => openPage(c, MapDownloadsPage(store: widget.store)),
      ),
      if (!loaded) const LinearProgressIndicator(),
      for (final region in regions)
        Card(
          child: Column(
            children: [
              ListTile(
                leading: Icon(
                  region['complete'] == true
                      ? Icons.offline_pin
                      : Icons.warning_amber,
                ),
                title: Text(region['name']),
                subtitle: Text(
                  '${region['enabled'] == true
                      ? 'In use'
                      : region['complete'] == true
                      ? 'Ready to enable'
                      : 'Incomplete'} · ${size(region['bytes'])}\nCoverage ${region['coverage']} · Zoom ${region['zoom']}\nImported ${stamp(region['imported'])}',
                ),
                isThreeLine: true,
                onTap: () async {
                  await Navigator.push(
                    c,
                    MaterialPageRoute(
                      builder: (_) => MapAuthorizationPage(
                        store: widget.store,
                        region: region,
                      ),
                    ),
                  );
                  await load();
                },
              ),
              OverflowBar(
                alignment: MainAxisAlignment.end,
                spacing: 8,
                children: [
                  TextButton.icon(
                    onPressed: () => guarded(c, () => remove(region)),
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('Remove'),
                  ),
                  FilledButton.tonalIcon(
                    onPressed: () async {
                      await Navigator.push(
                        c,
                        MaterialPageRoute(
                          builder: (_) => MapAuthorizationPage(
                            store: widget.store,
                            region: region,
                          ),
                        ),
                      );
                      await load();
                    },
                    icon: const Icon(Icons.verified_user_outlined),
                    label: Text(
                      region['enabled'] == true ? 'Review' : 'Review & enable',
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
    ],
  );
}

class _MapAuthorizationPageState extends State<MapAuthorizationPage> {
  final source = TextEditingController(),
      license = TextEditingController(),
      attribution = TextEditingController();
  bool permitted = false;
  @override
  void initState() {
    super.initState();
    final values =
        widget.region['authorization'] ?? widget.region['metadata'] ?? {};
    source.text = values['source']?.toString() ?? '';
    license.text = values['license']?.toString() ?? '';
    attribution.text = values['attribution']?.toString() ?? '';
    permitted = widget.region['authorization'] != null;
  }

  @override
  void dispose() {
    source.dispose();
    license.dispose();
    attribution.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext c) => PageFrame(
    'Review offline map',
    children: [
      Text(widget.region['name'], style: Theme.of(c).textTheme.titleLarge),
      note(
        'Coverage: ${widget.region['coverage']}\nZoom: ${widget.region['zoom']}\n${widget.region['complete'] == true ? 'Complete resources' : 'Incomplete resources'} · ${widget.region['bytes']} bytes',
      ),
      note(
        'Check the publisher’s terms and coverage. Importing a file does not grant a licence. FarmerPlus does not bulk-download public tiles or purchase maps.',
      ),
      TextField(
        controller: source,
        decoration: const InputDecoration(labelText: 'Source or publisher URL'),
      ),
      gap(),
      TextField(
        controller: license,
        decoration: const InputDecoration(
          labelText: 'Licence / permission reference',
        ),
      ),
      gap(),
      TextField(
        controller: attribution,
        minLines: 2,
        maxLines: 4,
        decoration: const InputDecoration(labelText: 'Required attribution'),
      ),
      gap(),
      CheckboxListTile(
        contentPadding: EdgeInsets.zero,
        value: permitted,
        onChanged: (v) => setState(() => permitted = v!),
        title: const Text('I have permission to use this map offline'),
      ),
      FilledButton(
        onPressed: () => guarded(c, () async {
          final issue = mapAuthorizationIssue(
            complete: widget.region['complete'] == true,
            source: source.text.trim(),
            license: license.text,
            attribution: attribution.text,
            permitted: permitted,
          );
          if (issue != null) throw StateError(issue);
          final status = await getOfflineRegionStatus(widget.region['id']);
          if (!status.isComplete) {
            throw StateError(
              'Resources are no longer complete. Import the full pack again.',
            );
          }
          await widget.store
              .setSetting('mapAuthorization:${widget.region['id']}', {
                'source': source.text.trim(),
                'license': license.text.trim(),
                'attribution': attribution.text.trim(),
                'authorized': DateTime.now().toUtc().toIso8601String(),
              });
          await widget.store.setSetting('mapEnabled', widget.region['id']);
          await widget.store.setSetting('mapStyle', widget.region['style']);
          if (c.mounted) Navigator.pop(c);
        }),
        child: const Text('Authorize & enable offline map'),
      ),
      if (widget.region['enabled'] == true)
        TextButton(
          onPressed: () => guarded(c, () async {
            await widget.store.setSetting('mapEnabled', null);
            await widget.store.setSetting('mapStyle', null);
            if (c.mounted) Navigator.pop(c);
          }),
          child: const Text('Disable map · keep pack'),
        ),
    ],
  );
}

class ConflictPage extends StatefulWidget {
  final FarmStore store;
  final String id;
  final VoidCallback onResolved;
  const ConflictPage({
    super.key,
    required this.store,
    required this.id,
    required this.onResolved,
  });
  @override
  State<ConflictPage> createState() => _ConflictPageState();
}

class _ConflictPageState extends State<ConflictPage> {
  Map<String, dynamic>? local, remote;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    final l = await widget.store.get(widget.id);
    final rows = await widget.store.db.query(
      'conflicts',
      where: 'id=?',
      whereArgs: [widget.id],
    );
    if (mounted) {
      setState(() {
        local = l;
        remote = rows.isEmpty
            ? null
            : jsonDecode(rows.first['remote'] as String);
      });
    }
  }

  Future<void> resolve(bool keep) async {
    await widget.store.resolve(widget.id, keepLocal: keep);
    widget.onResolved();
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext c) => PageFrame(
    'Resolve edit',
    children: [
      note(
        'Your offline edit has been kept. Review both versions before choosing. Keeping your edit queues it against the latest server version.',
      ),
      heading(c, 'On this phone'),
      SelectableText(
        const JsonEncoder.withIndent(
          '  ',
        ).convert({'deleted': local?['deleted'], 'data': local?['data']}),
      ),
      heading(c, 'On the server'),
      SelectableText(
        const JsonEncoder.withIndent(
          '  ',
        ).convert({'deleted': remote?['deleted'], 'data': remote?['data']}),
      ),
      gap(),
      FilledButton(
        onPressed: remote == null
            ? null
            : () => guarded(c, () => resolve(true)),
        child: const Text('Keep my edit & retry sync'),
      ),
      gap(),
      OutlinedButton(
        onPressed: remote == null
            ? null
            : () => guarded(c, () => resolve(false)),
        child: const Text('Use server version'),
      ),
    ],
  );
}
