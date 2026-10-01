import 'course_downloads.dart';
import 'community.dart';
import 'push.dart';
import 'home_panels.dart';
import 'dart:io';
import 'package:flutter/services.dart';
import 'appearance.dart';
import 'auth.dart';
import 'package:flutter/material.dart';
import 'store.dart';
import 'sync.dart';
import 'services.dart';
import 'domain.dart';
import 'ui.dart';
import 'farm.dart';
import 'miniapps.dart';
import 'settings.dart';
import 'background.dart';
import 'taxonomy.dart';
import 'farm_tools.dart';
import 'location.dart';
import 'account_workspaces.dart';
import 'offline_access.dart';
import 'sign_in_location.dart';
import 'pwa_auth.dart';
import 'dart:async';
import 'session_activity.dart';
import 'remote_apps.dart';
import 'remote_app_ui.dart';

var navigatorKey = GlobalKey<NavigatorState>();
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await launchWorkspace(await FarmStore.open());
  } catch (e) {
    runApp(
      MaterialApp(
        home: Scaffold(
          body: SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                'FarmerPlus could not open its local storage. Your saved data has not been reset.\n\n$e',
              ),
            ),
          ),
        ),
      ),
    );
  }
}

Future<void> launchWorkspace(
  FarmStore store, {
  Map<String, dynamic>? proof,
  String? password,
}) async {
  if (await store.setting('removedApp:coop') != true &&
      !await store.ready('coop')) {
    await store.install(catalogue.firstWhere((a) => a.id == 'coop'));
  }
  final sync = SyncEngine(store);
  final reminders = Reminders();
  final push = PushService(store, sync, reminders, navigatorKey);
  sync.afterOnlineLogin = () => push.refresh(forceRegistration: true);
  if (proof != null) {
    await sync.acceptOidc(proof);
    await store.setSetting('accessOwner', 'farmerplus:${proof['studentId']}');
    try {
      await OfflineAccess(store, sync).enroll(password!, proof);
    } on PlatformException {
      /* Online access remains available. */
    }
    await OnlineSignInLocation.captureAndSync(store, sync);
    await AccountAccess.unlock(
      store,
      'farmerplus:${proof['studentId']}',
      proof['username'],
      'oidc',
      offline: await OfflineAccess(store, sync).matches(proof),
    );
    await AccountWorkspaces.activate(store);
  }
  runApp(
    FarmerApp(
      key: ValueKey(store.filesPath),
      store: store,
      sync: sync,
      reminders: reminders,
    ),
  );
  try {
    await reminders.start(push.queue);
  } catch (_) {}
  await sync.start();
  final community = CommunityService.of(store, sync);
  community.start();
  await push.start();
  if (proof != null) unawaited(sync.onlineLoginReports());
  final downloads = CourseDownloads.of(store);
  downloads.start();
  AccountWorkspaces.adopt = (nextProof, nextPassword) async {
    if (sync.busy ||
        community.busy ||
        community.checkingInstallation ||
        push.busy ||
        downloads.running ||
        SyncEngine.refreshing != null) {
      throw StateError(
        'Please wait for the current transfer to finish, then sign in again. All saved work is kept.',
      );
    }
    final server = await sync.base();
    final next = await AccountWorkspaces.forIdentity(
      server,
      nextProof['owner'],
    );
    try {
      await AccountAccess.verifyOwner(
        next,
        'farmerplus:${nextProof['studentId']}',
        syncOwner: nextProof['owner'],
        verifiedPermanent: true,
      );
    } catch (_) {
      await next.close();
      rethrow;
    }
    await AccountAccess.signOut(store, sync);
    if (reminders.available) await reminders.plugin.cancelAll();
    community.dispose();
    downloads.dispose();
    push.dispose();
    sync.dispose();
    // Unmount old account widgets before opening the next account's session.
    runApp(
      const MaterialApp(
        home: Scaffold(body: Center(child: CircularProgressIndicator())),
      ),
    );
    await WidgetsBinding.instance.endOfFrame;
    navigatorKey = GlobalKey<NavigatorState>();
    try {
      await launchWorkspace(next, proof: nextProof, password: nextPassword);
    } catch (_) {
      // Return to a sign-in screen instead of stranding the user on a spinner.
      // Both account stores and their queued records remain intact.
      await AccountWorkspaces.activate(store);
      await next.close();
      await launchWorkspace(store);
      return;
    }
    await store.close();
  };
  try {
    await registerBackgroundSync();
    await store.setSetting('backgroundSync', Platform.isAndroid);
    // Sharing has its own queue, so scheduling cannot depend only on core records.
    await schedulePendingSync(store);
  } catch (_) {
    await store.setSetting('backgroundSync', false);
  }
}

class FarmerApp extends StatelessWidget {
  final FarmStore store;
  final SyncEngine sync;
  final Reminders reminders;
  const FarmerApp({
    super.key,
    required this.store,
    required this.sync,
    required this.reminders,
  });
  @override
  Widget build(BuildContext c) => MaterialApp(
    navigatorKey: navigatorKey,
    title: 'FarmerPlus',
    debugShowCheckedModeBanner: false,
    theme: farmTheme(),
    darkTheme: farmTheme(Brightness.dark),
    themeMode: ThemeMode.light,
    builder: (context, child) => SessionActivity(
      sync: sync,
      onLock: () =>
          navigatorKey.currentState?.popUntil((route) => route.isFirst),
      child: child ?? const SizedBox.shrink(),
    ),
    home: PwaAuthGate(
      store: store,
      sync: sync,
      child: HomePage(store: store, sync: sync, reminders: reminders),
    ),
  );
}

class HomePage extends StatefulWidget {
  final FarmStore store;
  final SyncEngine sync;
  final Reminders reminders;
  const HomePage({
    super.key,
    required this.store,
    required this.sync,
    required this.reminders,
  });
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  List<MiniManifest> apps = [];
  Map<String, dynamic>? farm, forecast;
  String name = '';
  String? wallpaper;
  String wallpaperPreset = 'fields';
  bool homeHighContrast = false;
  bool animateIcons = true;
  String? lastSync;
  final homeScroll = ScrollController();
  String? hoverTarget;
  DateTime hoverAfter = DateTime.fromMillisecondsSinceEpoch(0);
  String weatherStatus = 'Loading weather…';
  String weatherLabel = 'Weather here';
  String? requestedWeatherTarget;
  bool weatherBusy = false, weatherEnabled = false;
  int queue = 0, unread = 0;
  bool loaded = false;
  List<String> launcherOrder = [];
  String? dragging;
  bool editingApps = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.store.addListener(refresh);
    widget.sync.addListener(changed);
    start();
  }

  Future<void> start() async {
    weatherEnabled = await widget.store.setting('weatherEnabled') == true;
    await refresh();
    if (weatherEnabled) await updateWeather();
  }

  Future<void> updateWeather() async {
    final enabled = await widget.store.setting('weatherEnabled') == true;
    if (!enabled) {
      if (mounted) {
        setState(() {
          weatherEnabled = false;
          forecast = null;
          weatherStatus = '';
          requestedWeatherTarget = null;
        });
      }
      return;
    }
    if (weatherBusy) return;
    weatherEnabled = true;
    weatherBusy = true;
    try {
      final service = WeatherService(widget.store);
      requestedWeatherTarget = await service.targetKey();
      final saved = await service.cached();
      if (saved == null ||
          saved['weatherSchema'] != 3 ||
          DateTime.now().difference(DateTime.parse(saved['updated'])) >=
              const Duration(minutes: 15)) {
        await service.refresh();
      }
      if (await widget.store.setting('weatherEnabled') == true) {
        weatherStatus = '';
      }
    } catch (e) {
      if (await widget.store.setting('weatherEnabled') == true) {
        weatherStatus = e.toString().replaceFirst('Bad state: ', '');
      }
    } finally {
      weatherBusy = false;
      if (mounted) {
        setState(() {});
        await refresh();
      }
    }
  }

  void changed() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted) updateWeather();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    RemoteApps.of(widget.store).stopRecovery();
    widget.store.removeListener(refresh);
    widget.sync.removeListener(changed);
    homeScroll.dispose();
    super.dispose();
  }

  Future<void> refresh() async {
    final s = widget.store;
    RemoteApps.of(s).startRecovery();
    final remoteCatalogue = await RemoteApps.of(s).available();
    final allApps = {
      ...{for (final a in catalogue) a.id: a},
      ...{for (final a in remoteCatalogue) a.id: a},
    }.values.toList();
    final enabled = await s.setting('weatherEnabled') == true;
    final order = List<String>.from(
      {...?await s.setting('appOrder'), ...allApps.map((a) => a.id)}.toList(),
    );
    final installed = <MiniManifest>[];
    for (final id in order) {
      final found = allApps.where((a) => a.id == id);
      if (found.isNotEmpty && await s.ready(id)) installed.add(found.first);
    }
    final farms = await s.records('farm'),
        selected = await s.setting('selectedFarm');
    final matches = farms.where((f) => f['id'] == selected);
    final chosen = matches.isNotEmpty ? matches.first : farms.firstOrNull;
    Map<String, dynamic>? weatherFarm;
    Map<String, dynamic>? cached;
    String? target;
    if (enabled) {
      final service = WeatherService(s);
      weatherFarm = await service.selectedFarm();
      target = await service.targetKey();
      cached = await service.cached();
    }
    final p = await s.records('profile');
    final q = (await s.db.query('queue')).length;
    final messages = await s.records('inbox');
    final updates =
        await PushService.of(s)?.cached() ?? <Map<String, dynamic>>[];
    final covered = updates
        .map((p) => (p['event_key'] ?? '').toString().split(':').last)
        .toSet();
    final photo = await s.setting('wallpaperPhoto');
    final preset =
        await s.setting('wallpaperPreset') ??
        (photo == null ? 'fields' : 'photo');
    final motion = await s.setting('animateIcons') != false;
    final contrast = await s.setting('homeHighContrast') == true;
    final successfulSync = await s.setting('lastSync');
    final iconOrder = List<String>.from(await s.setting('launcherOrder') ?? []);
    if (mounted) {
      setState(() {
        apps = installed;
        if (dragging == null) launcherOrder = iconOrder;
        farm = chosen;
        weatherEnabled = enabled;
        forecast = enabled ? cached : null;
        if (!enabled) {
          weatherStatus = '';
          requestedWeatherTarget = null;
        }
        weatherLabel = weatherFarm == null
            ? 'Weather here'
            : 'Weather at ${weatherFarm['data']['name']}';
        name = p.firstOrNull?['data']['name'] ?? '';
        queue = q;
        unread =
            messages
                .where(
                  (m) =>
                      m['data']['read'] != true && !covered.contains(m['id']),
                )
                .length +
            updates.where((m) => m['read'] == null).length;
        wallpaper = photo;
        wallpaperPreset = preset;
        animateIcons = motion;
        homeHighContrast = contrast;
        lastSync = successfulSync;
        loaded = true;
      });
      if (enabled && !weatherBusy && requestedWeatherTarget != target) {
        updateWeather();
      }
    }
  }

  void mainNavigation(int index) {
    switch (index) {
      case 0:
        return;
      case 1:
        launch('farm');
      case 2:
        launch('inbox');
      case 3:
        launch('wallet');
      case 4:
        openPage(
          context,
          SettingsPage(
            store: widget.store,
            sync: widget.sync,
            reminders: widget.reminders,
          ),
        );
    }
  }

  void launch(String id) {
    final remote =
        apps.where((a) => a.id == id && a.remote).firstOrNull ??
        catalogue.where((a) => a.id == id && a.remote).firstOrNull;
    if (remote != null) {
      openPage(
        context,
        RemoteAppPage(store: widget.store, appId: id, title: remote.title),
      );
      return;
    }
    switch (id) {
      case 'coop':
        openPage(
          context,
          CoopPage(service: CommunityService.of(widget.store, widget.sync)),
        );
      case 'store':
        openPage(context, AppStorePage(store: widget.store, onOpen: launch));
      case 'farm':
        openPage(context, FarmsPage(store: widget.store));
      case 'wallet':
        openPage(context, const WalletPage());
      case 'inbox':
        openPage(
          context,
          InboxPage(store: widget.store, reminders: widget.reminders),
        );
      case 'calculator':
        openPage(context, const CalculatorPage());
      case 'learning':
        openPage(context, LearningPage(store: widget.store));
      case 'guides':
        openPage(context, GuidesPage(store: widget.store));
      case 'stock':
        openPage(context, StockPage(store: widget.store));
      case 'harvest':
        openPage(context, HarvestPage(store: widget.store));
      default:
        openPage(
          context,
          RecordsPage(
            store: widget.store,
            reminders: widget.reminders,
            kind: id == 'diary' ? 'diary' : 'task',
          ),
        );
    }
  }

  List<(String, String)> get launcherApps {
    final all = <(String, String)>[
      ('store', 'App Store'),
      ('learning', 'Learning'),
      ...apps
          .where((a) => !protectedApps.contains(a.id))
          .map((a) => (a.id, a.title)),
    ];
    final keys = [
      ...launcherOrder,
      ...all.map((a) => a.$1).where((id) => !launcherOrder.contains(id)),
    ];
    all.sort((a, b) => keys.indexOf(a.$1).compareTo(keys.indexOf(b.$1)));
    return all;
  }

  Future<void> moveIcon(
    String source,
    String target, {
    bool persist = true,
  }) async {
    if (source == target) return;
    final order = launcherApps.map((a) => a.$1).toList();
    final to = order.indexOf(target);
    order.remove(source);
    order.insert(to, source);
    setState(() => launcherOrder = order);
    if (persist) await widget.store.setSetting('launcherOrder', order);
  }

  Future<void> appActions(String id, String label) async {
    final items = launcherApps;
    final index = items.indexWhere((item) => item.$1 == id);
    await showModalBottomSheet<void>(
      context: context,
      builder: (c) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(label, style: Theme.of(c).textTheme.titleLarge),
              gap(),
              if (index > 0)
                OutlinedButton.icon(
                  onPressed: () async {
                    await moveIcon(id, items[index - 1].$1);
                    if (c.mounted) Navigator.pop(c);
                  },
                  icon: const Icon(Icons.arrow_back),
                  label: const Text('Move earlier'),
                ),
              if (index < items.length - 1)
                OutlinedButton.icon(
                  onPressed: () async {
                    await moveIcon(id, items[index + 1].$1);
                    if (c.mounted) Navigator.pop(c);
                  },
                  icon: const Icon(Icons.arrow_forward),
                  label: const Text('Move later'),
                ),
              if (protectedApps.contains(id))
                const Text('This essential app stays on your Home screen.')
              else
                TextButton.icon(
                  onPressed: () async {
                    Navigator.pop(c);
                    if (await confirmAppRemoval(
                      context,
                      widget.store,
                      id,
                      label,
                    )) {
                      await refresh();
                    }
                  },
                  icon: const Icon(Icons.remove_circle_outline),
                  label: const Text('Remove app and its offline data'),
                ),
            ],
          ),
        ),
      ),
    );
  }

  void editHome() {
    if (!editingApps) {
      HapticFeedback.selectionClick();
      setState(() => editingApps = true);
    }
  }

  Future<void> resetHome() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Reset home layout?'),
        content: const Text(
          'Restore the default icon order. Your apps, records and downloads stay on this phone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Reset layout'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await widget.store.setSetting('launcherOrder', <String>[]);
      await widget.store.setSetting('appOrder', <String>[]);
      await refresh();
    }
  }

  void hoverIcon(String source, String target) {
    if (source == target ||
        hoverTarget == target ||
        DateTime.now().isBefore(hoverAfter)) {
      return;
    }
    hoverTarget = target;
    hoverAfter = DateTime.now().add(const Duration(milliseconds: 220));
    moveIcon(source, target, persist: false);
  }

  Widget launcherTile(String id, String label, double width) {
    final tile = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        AppArtwork(id: id, size: width < 85 ? 56 : 64),
        gap(10),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
          decoration: BoxDecoration(
            color: homeHighContrast
                ? const Color(0xdd17302e)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(9),
          ),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: const TextStyle(
              shadows: [
                Shadow(
                  color: Color(0xff163b28),
                  blurRadius: 5,
                  offset: Offset(0, 1),
                ),
              ],
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: Colors.white,
            ),
          ),
        ),
      ],
    );
    return EditWiggle(
      enabled:
          editingApps &&
          animateIcons &&
          !MediaQuery.disableAnimationsOf(context) &&
          dragging != id,
      seed: id.hashCode % 10,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          GestureDetector(
            onSecondaryTap: editHome,
            child: DragTarget<String>(
              onWillAcceptWithDetails: (d) => d.data != id,
              onMove: (d) => hoverIcon(d.data, id),
              onLeave: (_) {
                if (hoverTarget == id) hoverTarget = null;
              },
              onAcceptWithDetails: (_) {},
              builder: (c, candidates, rejected) => EditableDraggable<String>(
                data: id,
                editing: editingApps,
                onDragStarted: () => setState(() {
                  dragging = id;
                  editingApps = true;
                }),
                onDragUpdate: (details) {
                  if (!homeScroll.hasClients) return;
                  final height = MediaQuery.sizeOf(context).height;
                  final y = details.globalPosition.dy;
                  final change = y > height - 100
                      ? 14.0
                      : y < 150
                      ? -14.0
                      : 0.0;
                  if (change != 0) {
                    homeScroll.jumpTo(
                      (homeScroll.offset + change).clamp(
                        0.0,
                        homeScroll.position.maxScrollExtent,
                      ),
                    );
                  }
                },
                onDragEnd: (_) async {
                  final order = List<String>.from(launcherOrder);
                  setState(() {
                    dragging = null;
                    hoverTarget = null;
                  });
                  await widget.store.setSetting('launcherOrder', order);
                },
                feedback: Material(
                  color: Colors.transparent,
                  child: SizedBox(
                    width: width,
                    child: Transform.scale(scale: 1.12, child: tile),
                  ),
                ),
                childWhenDragging: SizedBox(
                  width: width,
                  child: Opacity(opacity: .22, child: tile),
                ),
                child: Semantics(
                  button: true,
                  label: label,
                  hint: editingApps
                      ? 'Choose how to move this app.'
                      : 'Tap to open. Hold and drag to move.',
                  excludeSemantics: true,
                  onTap: () {
                    if (editingApps) {
                      appActions(id, label);
                    } else {
                      launch(id);
                    }
                  },
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 140),
                    width: width,
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    decoration: BoxDecoration(
                      color: candidates.isNotEmpty
                          ? const Color(0xffd8e3ff)
                          : Colors.transparent,
                      border: Border.all(
                        color: candidates.isNotEmpty
                            ? const Color(0xff3157ed)
                            : Colors.transparent,
                        width: 2,
                      ),
                      borderRadius: BorderRadius.circular(22),
                    ),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(22),
                      onTap: () {
                        if (editingApps) {
                          appActions(id, label);
                        } else {
                          launch(id);
                        }
                      },
                      child: tile,
                    ),
                  ),
                ),
              ),
            ),
          ),
          if (editingApps && !protectedApps.contains(id))
            Positioned(
              top: -4,
              left: -4,
              child: IconButton.filled(
                tooltip: 'Remove $label',
                style: IconButton.styleFrom(
                  backgroundColor: Colors.white,
                  foregroundColor: Colors.red.shade800,
                  minimumSize: const Size(48, 48),
                ),
                onPressed: () => guarded(context, () async {
                  if (await confirmAppRemoval(
                    context,
                    widget.store,
                    id,
                    label,
                  )) {
                    await refresh();
                  }
                }),
                icon: const Icon(Icons.remove_circle, size: 22),
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext c) {
    return FarmBackdrop(
      glassOpacity: homeHighContrast ? .92 : .60,
      photo: wallpaper,
      preset: wallpaperPreset,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Colors.white.withValues(alpha: .75),
          scrolledUnderElevation: 0,
          title: editingApps
              ? const Text('Edit home')
              : Image.asset(
                  'assets/branding/wordmark.png',
                  width: 210,
                  height: 42,
                  fit: BoxFit.contain,
                  semanticLabel: 'FarmerPlus',
                ),
          actions: [
            if (editingApps)
              TextButton(
                onPressed: () => setState(() => editingApps = false),
                child: const Text('Done'),
              ),
            ConnectionLight(online: widget.sync.serverOnline),
            if (!editingApps)
              IconButton(
                tooltip: 'Profile',
                onPressed: () => openPage(c, ProfilePage(store: widget.store)),
                icon: const Icon(Icons.person_outline),
              ),
            if (!editingApps)
              IconButton(
                tooltip: 'Log out',
                onPressed: () =>
                    guarded(c, () => logOut(c, widget.store, widget.sync)),
                icon: const Icon(Icons.logout),
              ),
          ],
        ),
        extendBody: true,
        bottomNavigationBar: SafeArea(
          minimum: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          child: LiquidGlass(
            opacity: homeHighContrast ? .9 : .28,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
            child: Row(
              children: [
                for (final item in [
                  (1, 'farm', 'My Farm'),
                  (2, 'inbox', 'Inbox'),
                  (3, 'wallet', 'Wallet'),
                  (4, 'settings', 'Settings'),
                ])
                  Expanded(
                    child: Semantics(
                      button: true,
                      label: item.$3,
                      child: Tooltip(
                        message: item.$3,
                        excludeFromSemantics: true,
                        child: InkWell(
                          borderRadius: BorderRadius.circular(18),
                          onTap: () => mainNavigation(item.$1),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            child: Center(
                              heightFactor: 1,
                              child: Badge(
                                isLabelVisible:
                                    item.$2 == 'inbox' && unread > 0,
                                label: Text('$unread'),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    AppArtwork(id: item.$2, size: 50),
                                    const SizedBox(height: 7),
                                    Text(
                                      item.$3,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                        shadows: [
                                          Shadow(
                                            color: Color(0xff173b28),
                                            blurRadius: 5,
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 680),
              child: !loaded
                  ? const Center(child: CircularProgressIndicator())
                  : GestureDetector(
                      onLongPress: editHome,
                      behavior: HitTestBehavior.translucent,
                      child: ListView(
                        controller: homeScroll,
                        padding: const EdgeInsets.fromLTRB(20, 18, 20, 132),
                        children: [
                          if (weatherEnabled)
                            WeatherDisplay(
                              cache: forecast,
                              label: weatherLabel,
                              status: weatherStatus,
                              onTap: () => openPage(
                                c,
                                WeatherPage(store: widget.store, farm: farm),
                              ),
                            ),
                          SyncGlass(
                            count: queue,
                            busy: widget.sync.busy,
                            lastSync: lastSync,
                            issue: widget.sync.itemIssues.isEmpty
                                ? null
                                : widget.sync.itemIssues.values.first,
                            onTap: () => openPage(
                              c,
                              PendingSyncPage(
                                store: widget.store,
                                sync: widget.sync,
                              ),
                            ),
                          ),
                          gap(10),
                          LayoutBuilder(
                            builder: (c, box) {
                              const columns = 4;
                              final items = launcherApps;
                              final width =
                                  (box.maxWidth - 8 * (columns - 1)) / columns;
                              final rowHeight =
                                  108 + MediaQuery.textScalerOf(c).scale(26);
                              return SizedBox(
                                height: ((items.length + 3) ~/ 4) * rowHeight,
                                child: Stack(
                                  clipBehavior: Clip.none,
                                  children: [
                                    for (var i = 0; i < items.length; i++)
                                      AnimatedPositioned(
                                        key: ValueKey(items[i].$1),
                                        duration:
                                            MediaQuery.disableAnimationsOf(c) ||
                                                !animateIcons
                                            ? Duration.zero
                                            : const Duration(milliseconds: 180),
                                        curve: Curves.easeOutCubic,
                                        left: (i % 4) * (width + 8),
                                        top: (i ~/ 4) * rowHeight,
                                        width: width,
                                        child: launcherTile(
                                          items[i].$1,
                                          items[i].$2,
                                          width,
                                        ),
                                      ),
                                  ],
                                ),
                              );
                            },
                          ),
                        ],
                      ),
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

class WeatherPage extends StatefulWidget {
  final FarmStore store;
  final Map<String, dynamic>? farm;
  const WeatherPage({super.key, required this.store, this.farm});
  @override
  State<WeatherPage> createState() => _WeatherPageState();
}

class _WeatherPageState extends State<WeatherPage> {
  Map<String, dynamic>? cache;
  List<Map<String, dynamic>> farms = [];
  String choice = 'current';
  String status = '';
  bool busy = false;
  @override
  void initState() {
    super.initState();
    openForecast();
  }

  Future<void> openForecast() async {
    await load();
    final updated = DateTime.tryParse(cache?['updated'] ?? '');
    if (mounted &&
        (cache?['weatherSchema'] != 3 ||
            updated == null ||
            DateTime.now().difference(updated) >=
                const Duration(minutes: 15))) {
      await updateForecast(requestLocation: false);
    }
  }

  Future<void> load() async {
    final service = WeatherService(widget.store);
    final value = await service.cached();
    final selected = await service.selectedFarm();
    final available = await widget.store.records('farm');
    if (mounted) {
      setState(() {
        cache = value;
        farms = available;
        choice = selected?['id'] ?? 'current';
      });
    }
  }

  Future<void> updateForecast({bool requestLocation = true}) async {
    if (busy) return;
    setState(() {
      busy = true;
      status = '';
    });
    try {
      if (requestLocation &&
          choice == 'current' &&
          !await DeviceLocation.enable(widget.store)) {
        throw StateError('Location Unavailable');
      }
      await WeatherService(widget.store).refresh();
    } catch (e) {
      if (mounted) {
        setState(() => status = e.toString().replaceFirst('Bad state: ', ''));
      }
    } finally {
      await load();
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext c) {
    return PageFrame(
      'Farm weather',
      actions: [
        PopupMenuButton<String>(
          tooltip: 'Change weather location',
          icon: const Icon(Icons.location_on_outlined),
          enabled: !busy,
          initialValue: choice,
          itemBuilder: (_) => [
            const PopupMenuItem(value: 'current', child: Text('Weather here')),
            for (final f in farms)
              PopupMenuItem(
                value: f['id'] as String,
                child: Text(f['data']['name'] ?? 'Unnamed farm'),
              ),
          ],
          onSelected: (value) async {
            await widget.store.setSetting('weatherHere', value == 'current');
            if (value != 'current') {
              await widget.store.setSetting('selectedFarm', value);
            }
            await load();
            await updateForecast();
          },
        ),
      ],
      children: [
        WeatherDisplay(
          cache: cache,
          label: choice == 'current'
              ? 'Weather here'
              : '${farms.where((f) => f['id'] == choice).firstOrNull?['data']['name'] ?? 'Your farm'}',
          onRefresh: busy ? null : updateForecast,
          status: status,
          detailed: true,
        ),
        if (busy)
          const Padding(
            padding: EdgeInsets.all(12),
            child: LinearProgressIndicator(),
          ),
      ],
    );
  }
}

class WalletPage extends StatelessWidget {
  const WalletPage({super.key});
  @override
  Widget build(BuildContext c) => PageFrame(
    'Wallet',
    children: [
      Text(
        'Your two assets.\nKept separate.',
        style: Theme.of(c).textTheme.headlineMedium,
      ),
      note(
        'Connect an approved wallet service to activate your wallet. No provider or assets have been configured.',
      ),
      for (final name in ['Local-currency token', 'Agri token'])
        ListTile(
          leading: const Icon(Icons.account_balance_wallet_outlined),
          title: Text(name),
          subtitle: const Text('Not connected • balance unavailable'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => openPage(
            c,
            PageFrame(
              name,
              children: [
                Text(
                  'Not activated',
                  style: Theme.of(c).textTheme.headlineMedium,
                ),
                note(
                  'There is no verified balance or transaction history on this phone.',
                ),
                heading(c, 'Before activation'),
                const Text(
                  'Your service must identify the network, token contract, custody provider, supported actions and recovery method. Country naming will follow the actual configured asset.',
                ),
                heading(c, 'Your approval, every time'),
                const Text(
                  'A supported payment will show recipient, asset, amount and fees before you approve. Offline payment drafts will never be submitted by farm synchronisation.',
                ),
                heading(c, 'Activity'),
                const Text('No verified activity available.'),
              ],
            ),
          ),
        ),
      gap(),
      note('Never share your private key or recovery phrase with a mini-app.'),
    ],
  );
}

String weatherSummary(Map<String, dynamic> cache) {
  final current = cache['forecast']['current'];
  if (current == null) return 'Saved weather is unavailable.';
  final units = cache['forecast']['current_units'];
  return '${current['temperature_2m']} ${units['temperature_2m']}  ·  ${weatherCondition(current['weather_code'])}\nWind ${current['wind_speed_10m']} ${units['wind_speed_10m']} · Rain ${current['precipitation']} ${units['precipitation']}';
}

String weatherCondition(dynamic code) {
  if (code == 0) return 'Clear';
  if ([1, 2, 3].contains(code)) return 'Cloudy';
  if ([45, 48].contains(code)) return 'Fog';
  if ([51, 53, 55, 56, 57].contains(code)) return 'Drizzle';
  if ([61, 63, 65, 66, 67, 80, 81, 82].contains(code)) return 'Rain';
  if ([71, 73, 75, 77, 85, 86].contains(code)) return 'Snow';
  if ([95, 96, 99].contains(code)) return 'Thunderstorms';
  return 'Conditions unavailable';
}
