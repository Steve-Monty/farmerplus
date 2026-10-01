import 'dart:async';
import 'dart:io';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'background.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:image_picker/image_picker.dart';
import 'auth.dart';
import 'store.dart';
import 'sync.dart';
import 'ui.dart';

const sharingPolicy = '20260916-sharing-v1';
const sharingNames = <String, String>{
  'government': 'Government',
  'finance': 'Finance Providers',
  'insurance': 'Insurance Providers',
  'cooperatives': 'Cooperatives',
  'inputs': 'Input Suppliers',
};
const sharingPurposes = <String, String>{
  'government': 'For public agricultural services you choose to apply for.',
  'finance': 'For finance applications you choose to submit.',
  'insurance': 'For insurance applications you choose to submit.',
  'cooperatives': 'For cooperative services you choose to use.',
  'inputs': 'For supplier services you choose to request.',
};
bool validCoopCode(String code) =>
    RegExp(r'^farmerplus:coop:v1:[a-z0-9-]{1,100}$').hasMatch(code);

/// Preferences, cached memberships and pending actions are bound to owner AND API origin.
class CommunityService extends ChangeNotifier with WidgetsBindingObserver {
  static final Map<FarmStore, CommunityService> _instances = {};
  static CommunityService of(FarmStore store, SyncEngine sync) =>
      _instances.putIfAbsent(store, () => CommunityService(store, sync));
  final FarmStore store;
  final SyncEngine sync;
  bool busy = false, started = false;
  Timer? timer;
  String? observedInstallation;
  bool checkingInstallation = false, disposed = false;
  final bool background;
  StreamSubscription? connectivity;
  Future<void> _installationTail = Future.value();
  Future<void> _queueWrite = Future.value();
  Future<void> mutatePending(
    String key,
    void Function(List<Map<String, dynamic>>) change,
  ) {
    final next = _queueWrite.then((_) async {
      final rows = await pending(key);
      change(rows);
      await store.setSetting('communityPending:$key', rows);
    });
    _queueWrite = next.catchError((Object _) {});
    return next;
  }

  CommunityService(this.store, this.sync, {this.background = false});
  Future<Map<String, dynamic>> installationState() async {
    var generation = await store.setting('coopGeneration');
    if (generation == null) {
      await store.appLifecycle(() async {
        if (await store.setting('coopGeneration') == null) {
          await store.setSetting('coopGeneration', uuid.v4());
        }
      });
      generation = await store.setting('coopGeneration');
    }
    return {'generation': generation, 'enabled': await store.ready('coop')};
  }

  String installationSignature(Map state) =>
      '${state['generation']}:${state['enabled']}';

  void storeChanged() async {
    if (checkingInstallation || disposed) return;
    checkingInstallation = true;
    try {
      final state = await installationState();
      final signature = installationSignature(state);
      if (signature != observedInstallation && !disposed) {
        observedInstallation = signature;
        notifyListeners();
        if (!busy) unawaited(refresh());
      }
    } finally {
      checkingInstallation = false;
    }
  }

  Future<String?> scope() async {
    if ((!background && AccountAccess.unlocked.value == null) ||
        (background && sync.token == null) ||
        sync.credentialChangeInProgress) {
      return null;
    }
    final owner = await store.setting('boundOwner'), base = await sync.base();
    if (owner is! String || await store.setting('boundServer') != base) {
      return null;
    }
    return '$base:$owner';
  }

  Future<List<Map<String, dynamic>>> pending(String key) async =>
      (await store.setting('communityPending:$key') as List? ?? [])
          .map((v) => Map<String, dynamic>.from(v))
          .toList();
  Future<Map<String, dynamic>> snapshot() async {
    final installed = await store.ready('coop');
    final key = await scope();
    if (key == null) {
      return {
        'choices': {
          for (final c in sharingNames.keys)
            c: c == 'cooperatives' && installed,
        },
        'installed': installed,
        'members': [],
        'pending': [],
        'status': 'Sign in to sync your choices',
      };
    }
    final cached = Map<String, dynamic>.from(
      await store.setting('communityCache:$key') ?? {},
    );
    final choices = <String, dynamic>{
      for (final c in sharingNames.keys) c: false,
      ...?cached['choices'],
    };
    final queue = await pending(key);
    for (final action in queue) {
      if (action['type'] == 'choice') {
        choices[action['category']] = action['body']['enabled'];
      }
    }
    choices['cooperatives'] = installed;
    final generation = await store.setting('coopGeneration');
    final installationPending =
        await store.setting('coopAck:$key') != '$generation:$installed';
    return {
      ...cached,
      'choices': choices,
      'members': cached['members'] ?? [],
      'pending': queue,
      'installed': installed,
      'installationPending': installationPending,
      'installationError': await store.setting('coopError:$key'),
      'status': installationPending
          ? 'Sharing change pending sync'
          : queue.isNotEmpty
          ? (queue.any((e) => e['failed'] == true)
                ? 'Failed to sync — saved on this phone. Retry when connected.'
                : 'Pending — saved on this phone')
          : cached['updated'] == null
          ? 'Saved on this phone — not synced yet'
          : 'Synced',
    };
  }

  void start() {
    if (started) return;
    started = true;
    WidgetsBinding.instance.addObserver(this);
    AccountAccess.unlocked.addListener(changed);
    store.addListener(storeChanged);
    connectivity = Connectivity().onConnectivityChanged.listen(
      (_) => changed(),
    );
    changed();
  }

  void changed() {
    if (!disposed) unawaited(refresh());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) changed();
  }

  Future<void> enqueue(Map<String, dynamic> action) async {
    final key = await scope();
    if (key == null) throw StateError('Sign in before saving this choice.');
    await mutatePending(key, (queue) {
      if (action['type'] == 'choice') {
        queue.removeWhere(
          (a) => a['type'] == 'choice' && a['category'] == action['category'],
        );
      }
      if (action['type'] == 'membership' &&
          queue.any(
            (a) => a['type'] == 'membership' && a['coop'] == action['coop'],
          )) {
        throw StateError(
          'A membership request is already pending for this cooperative.',
        );
      }
      queue.add(action);
    });
    notifyListeners();
    await schedulePendingSync(store);
    unawaited(refresh());
  }

  Future<void> choose(String category, bool enabled) {
    if (category == 'cooperatives') {
      throw StateError('Install or remove Coop to change this setting.');
    }
    return enqueue({
      'type': 'choice',
      'category': category,
      'body': {
        'eventId': uuid.v4(),
        'enabled': enabled,
        'policy': sharingPolicy,
      },
    });
  }

  Future<bool> syncInstallation(String key) {
    final next = _installationTail.then((_) => _syncInstallation(key));
    _installationTail = next.then<void>((_) {}, onError: (Object _) {});
    return next;
  }

  Future<bool> _syncInstallation(String key) async {
    if (disposed || await scope() != key) return false;
    final state = await installationState();
    final signature = installationSignature(state);
    observedInstallation = signature;
    if (await store.setting('coopAck:$key') == signature) return true;
    try {
      final result = await sync.request(
        'PUT',
        '/coops/installation',
        body: {
          'eventId': uuid.v5(
            '6ba7b811-9dad-11d1-80b4-00c04fd430c8',
            '$key:$signature',
          ),
          'enabled': state['enabled'],
          'installation': state['generation'],
          'policy': sharingPolicy,
        },
      );
      if (await scope() != key ||
          result['saved'] != true ||
          result['owner'] != await store.setting('boundOwner')) {
        return false;
      }
      await store.setSetting('coopAck:$key', signature);
      await store.setSetting('coopError:$key', null);
      return installationSignature(await installationState()) == signature;
    } catch (_) {
      if (await scope() == key) {
        await store.setSetting(
          'coopError:$key',
          'Sharing change pending sync. Connect and retry to confirm it with the server.',
        );
      }
      return false;
    }
  }

  Future<void> approveRecipient(Map recipient, bool enabled) async {
    final key = await scope();
    if (key == null) throw StateError('Sign in before reviewing sharing.');
    final state = await installationState();
    if (recipient['category'] == 'cooperatives' && enabled) {
      if (!state['enabled']) throw StateError('Install Coop before sharing.');
      if (!await syncInstallation(key)) {
        throw StateError(
          'Connect to confirm Coop installation, then try again.',
        );
      }
      if (installationSignature(await installationState()) !=
          installationSignature(state)) {
        throw StateError('Coop changed. Reopen it and review sharing.');
      }
    }
    if (await scope() != key) {
      throw StateError('Your account changed. Reopen this page.');
    }
    final result = await sync.request(
      'PUT',
      '/sharing/recipients/${recipient['id']}/consent',
      body: {
        'eventId': uuid.v4(),
        'enabled': enabled,
        'policy': recipient['policy'],
        if (recipient['category'] == 'cooperatives')
          'installation': state['generation'],
      },
    );
    if (await scope() != key ||
        result['saved'] != true ||
        result['owner'] != await store.setting('boundOwner')) {
      throw StateError('Sharing was not confirmed. Reopen this page.');
    }
  }

  Future<void> membership(Map coop, String action) => enqueue({
    'type': 'membership',
    'coop': coop['id'] ?? coop['coop'],
    'name': coop['name'],
    'body': {
      'eventId': uuid.v4(),
      'action': action,
      'termsRevision': coop['revision'],
      'confirmed': true,
    },
  });
  Future<void> discard(String event) async {
    if (busy) return;
    final key = await scope();
    if (key == null) return;
    await mutatePending(
      key,
      (queue) => queue.removeWhere((a) => a['body']['eventId'] == event),
    );
    notifyListeners();
    await refresh();
  }

  Future<void> refresh({bool explicit = false}) async {
    if (busy || disposed) return;
    final mode = await store.setting('syncMode') ?? 'automatic';
    if ((!explicit && mode == 'manual') || !await sync.onlineAvailable())
      return;
    if (!explicit &&
        mode == 'wifi' &&
        !kIsWeb &&
        Platform.isAndroid &&
        !(await Connectivity().checkConnectivity()).contains(
          ConnectivityResult.wifi,
        )) {
      return;
    }
    final key = await scope();
    if (key == null) {
      notifyListeners();
      return;
    }
    if (busy || disposed) return;
    busy = true;
    final revision = sync.credentialRevision;
    bool current() => revision == sync.credentialRevision;
    try {
      final installationSynced = await syncInstallation(key);
      for (final action in await pending(key)) {
        if (!current() || await scope() != key) return;
        if (action['type'] == 'choice' &&
            action['category'] == 'cooperatives') {
          await mutatePending(
            key,
            (latest) => latest.removeWhere(
              (a) => a['body']['eventId'] == action['body']['eventId'],
            ),
          );
          continue;
        }
        if (action['type'] == 'membership' &&
            action['body']['action'] == 'join' &&
            (!installationSynced || !await store.ready('coop'))) {
          continue;
        }
        try {
          final body = action['body'];
          final response = await sync.request(
            action['type'] == 'choice' ? 'PUT' : 'POST',
            action['type'] == 'choice'
                ? '/sharing/preferences/${action['category']}'
                : '/coops/${action['coop']}/membership',
            body: body,
          );
          if (!current() || await scope() != key) return;
          if (response['saved'] != true ||
              response['owner'] != await store.setting('boundOwner')) {
            throw StateError('Server did not confirm this change.');
          }
          await mutatePending(
            key,
            (latest) => latest.removeWhere(
              (a) => a['body']['eventId'] == body['eventId'],
            ),
          );
        } catch (error) {
          if (!current() || await scope() != key) return;
          await store.setSetting(
            'communityError:$key',
            error.toString().replaceFirst('Bad state: ', ''),
          );
          await mutatePending(key, (latest) {
            for (final row in latest) {
              if (row['body']['eventId'] == action['body']['eventId']) {
                row['failed'] = true;
              }
            }
          });
          break;
        }
      }
      final prefs = await sync.request('GET', '/sharing/preferences');
      final members = await sync.request('GET', '/coops/memberships');
      if (!current() || await scope() != key) return;
      await store.setSetting('communityCache:$key', {
        'choices': prefs['choices'],
        'members': members['items'],
        'updated': DateTime.now().toUtc().toIso8601String(),
      });
    } catch (_) {
      /* Owner-scoped cache and pending requests remain intact. */
    } finally {
      busy = false;
      if (!disposed) {
        notifyListeners();
        if ((await pending(key)).isNotEmpty ||
            await store.setting('coopError:$key') != null) {
          timer?.cancel();
          timer = Timer(const Duration(seconds: 30), changed);
        }
      }
    }
  }

  @override
  void dispose() {
    disposed = true;
    if (identical(_instances[store], this)) _instances.remove(store);
    store.removeListener(storeChanged);
    timer?.cancel();
    connectivity?.cancel();
    AccountAccess.unlocked.removeListener(changed);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}

class ShareDataSettings extends StatefulWidget {
  final CommunityService service;
  final VoidCallback? onManageCoop;
  const ShareDataSettings({
    super.key,
    required this.service,
    this.onManageCoop,
  });
  @override
  State<ShareDataSettings> createState() => _ShareDataSettingsState();
}

class _ShareDataSettingsState extends State<ShareDataSettings> {
  Map<String, dynamic> data = {};
  bool saving = false;
  @override
  void initState() {
    super.initState();
    widget.service.addListener(load);
    widget.service.store.addListener(load);
    load();
  }

  Future<void> load() async {
    final value = await widget.service.snapshot();
    if (mounted) setState(() => data = value);
  }

  @override
  void dispose() {
    widget.service.removeListener(load);
    widget.service.store.removeListener(load);
    super.dispose();
  }

  Future<void> choose(String category, bool value) async {
    if (saving) return;
    if (value &&
        await showDialog<bool>(
              context: context,
              builder: (c) => AlertDialog(
                title: Text('Allow requests from ${sharingNames[category]}?'),
                content: Text(
                  '${sharingPurposes[category]}\n\nBefore any data is disclosed, you must approve the named organisation, purpose and exact fields. Enabling this category alone shares nothing. Phone identifiers are excluded. You can withdraw future sharing at any time.',
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(c, false),
                    child: const Text('Keep No'),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.pop(c, true),
                    child: const Text('Choose Yes'),
                  ),
                ],
              ),
            ) !=
            true) {
      return;
    }
    if (!mounted) return;
    setState(() => saving = true);
    await guarded(context, () => widget.service.choose(category, value));
    if (mounted) setState(() => saving = false);
  }

  @override
  Widget build(BuildContext c) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const Text(
        'Choose which organisations may request your data. Sharing starts only after you approve the organisation and information.',
      ),
      const SizedBox(height: 12),
      if (data.isEmpty) const LinearProgressIndicator(),
      for (final entry in sharingNames.entries) ...[
        if (entry.key == 'cooperatives') ...[
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.lock_outline),
            title: Text(
              'Cooperatives · ${data['installed'] == true ? 'Yes' : 'No'} · Locked',
            ),
            subtitle: Text(
              data['installed'] == true
                  ? 'Enabled because Coop is installed. Approve sharing with each cooperative before using its services. Remove Coop to turn this off.'
                  : 'Install Coop to enable cooperative services.',
            ),
          ),
          if (data['installationPending'] == true)
            Semantics(
              liveRegion: true,
              child: Text(
                data['installationError'] ??
                    'Sharing change pending sync. The server has not confirmed this change.',
              ),
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: widget.onManageCoop,
              icon: const Icon(Icons.apps),
              label: Text(
                data['installed'] == true
                    ? 'Manage Coop'
                    : 'View Coop in App Store',
              ),
            ),
          ),
        ] else
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(entry.value),
            subtitle: Text(sharingPurposes[entry.key]!),
            value: data['choices']?[entry.key] == true,
            onChanged: saving || data.isEmpty
                ? null
                : (v) => choose(entry.key, v),
          ),
        for (final action in (data['pending'] as List? ?? []).where(
          (a) => a['category'] == entry.key,
        ))
          Semantics(
            liveRegion: true,
            child: Text(
              action['failed'] == true
                  ? 'Could not sync this choice. Saved on this phone.'
                  : 'Choice saved · Waiting to sync',
            ),
          ),
        const Divider(),
      ],
      Text(data['status'] ?? 'Saved on this phone'),
      if ((data['pending'] as List? ?? []).isNotEmpty ||
          data['installationPending'] == true)
        TextButton(
          onPressed: () => guarded(c, widget.service.refresh),
          child: const Text('Retry pending changes'),
        ),
      TextButton(
        onPressed: () => openPage(c, RecipientPage(service: widget.service)),
        child: const Text('Who can access my data?'),
      ),
      const Text('These choices do not change your normal FarmerPlus sync.'),
    ],
  );
}

class RecipientPage extends StatefulWidget {
  final CommunityService service;
  const RecipientPage({super.key, required this.service});
  @override
  State<RecipientPage> createState() => _RecipientPageState();
}

class _RecipientPageState extends State<RecipientPage> {
  List<Map<String, dynamic>> rows = [];
  String status = 'Loading…';
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    final key = await widget.service.scope();
    try {
      final data = await widget.service.sync.request(
        'GET',
        '/sharing/recipients',
      );
      if (mounted && key != null && await widget.service.scope() == key) {
        setState(() {
          rows = List<Map<String, dynamic>>.from(data['items']);
          status = rows.isEmpty
              ? 'No external recipients are configured. No data is being sent to providers.'
              : '';
        });
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => status = 'Could not load recipients. Connect and retry.',
        );
      }
    }
  }

  @override
  Widget build(BuildContext c) => PageFrame(
    'Who can access my data?',
    children: [
      Text(status),
      for (final r in rows)
        ListTile(
          title: Text(r['name']),
          subtitle: Text(
            '${r['approved'] == true ? 'Approved' : 'Not approved'}${r['demo'] == true ? ' · Demonstration' : ''}\n${r['purpose']}\nData: ${(r['fields'] as List).map(sharingFieldLabel).join(', ')}',
          ),
          trailing: TextButton(
            child: Text(r['approved'] == true ? 'Withdraw' : 'Review'),
            onPressed: () => guarded(c, () async {
              final scope = await widget.service.scope();
              if (!c.mounted) return;
              final approve = r['approved'] != true;
              final agreed = approve
                  ? await reviewSharing(c, r)
                  : await showDialog<bool>(
                      context: c,
                      builder: (d) => AlertDialog(
                        title: Text(
                          approve
                              ? 'Share with ${r['name']}?'
                              : 'Withdraw sharing?',
                        ),
                        content: Text(
                          approve
                              ? 'Purpose: ${r['purpose']}\nOnly these fields: ${(r['fields'] as List).join(', ')}\nPolicy: ${r['policy']}'
                              : 'This stops future disclosures. It cannot recall information already received.',
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(d, false),
                            child: const Text('Cancel'),
                          ),
                          FilledButton(
                            onPressed: () => Navigator.pop(d, true),
                            child: Text(approve ? 'Approve' : 'Withdraw'),
                          ),
                        ],
                      ),
                    );
              if (agreed == true) {
                if (scope == null || await widget.service.scope() != scope) {
                  throw StateError(
                    'Your signed-in account changed. Reopen this page.',
                  );
                }
                await widget.service.approveRecipient(r, approve);
                await load();
              }
            }),
          ),
        ),
      TextButton(onPressed: load, child: const Text('Refresh')),
    ],
  );
}

String sharingFieldLabel(dynamic field) =>
    const {
      'name': 'Preferred name',
      'country': 'Country',
      'productionCategory': 'Primary farming activity',
    }[field] ??
    field.toString();

Future<bool> reviewSharing(BuildContext context, Map recipient) async =>
    await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (c) => PageFrame(
          'Review data sharing',
          bottom: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 12),
              child: OverflowBar(
                alignment: MainAxisAlignment.end,
                spacing: 12,
                overflowSpacing: 8,
                children: [
                  OutlinedButton(
                    onPressed: () => Navigator.pop(c, false),
                    child: const Text('Cancel'),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.pop(c, true),
                    child: Text(
                      recipient['demo'] == true
                          ? 'Proceed with demo'
                          : 'Proceed and share',
                    ),
                  ),
                ],
              ),
            ),
          ),
          children: [
            Text(recipient['name'], style: Theme.of(c).textTheme.headlineSmall),
            if (recipient['demo'] == true)
              note(
                'Demonstration only. No information is sent to a real cooperative.',
              ),
            heading(c, 'Why this information is needed'),
            Text(recipient['purpose']),
            heading(c, 'Information you approve'),
            for (final field in recipient['fields'])
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.check_circle_outline),
                title: Text(sharingFieldLabel(field)),
              ),
            gap(),
            Text(
              recipient['category'] == 'cooperatives'
                  ? 'Sharing stays enabled while Coop is installed. Removing Coop stops future sharing once the change reaches the server. It does not end your membership or erase information already received.'
                  : 'You can withdraw future sharing from Data sharing. Information already received cannot be recalled.',
            ),
            gap(),
            const Text('Cancel returns you without approving any sharing.'),
          ],
        ),
      ),
    ) ??
    false;

class CoopPage extends StatefulWidget {
  final CommunityService service;
  const CoopPage({super.key, required this.service});
  @override
  State<CoopPage> createState() => _CoopPageState();
}

class _CoopPageState extends State<CoopPage> {
  Map<String, dynamic> data = {};
  Map<String, dynamic>? candidate;
  String? message, code;
  bool working = false;
  Future<void> chooseImage() async {
    final image = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (image == null || !mounted) return;
    final scanner = MobileScannerController(
      autoStart: false,
      formats: [BarcodeFormat.qrCode],
    );
    try {
      final capture = await scanner.analyzeImage(image.path);
      final values =
          capture?.barcodes
              .map((b) => b.rawValue)
              .whereType<String>()
              .toSet() ??
          <String>{};
      if (values.length != 1) {
        throw StateError(
          values.isEmpty
              ? 'No QR code found. Choose a clear, uncropped QR image.'
              : 'More than one QR code found. Choose an image with one invitation.',
        );
      }
      if (mounted) await resolve(values.single);
    } finally {
      await scanner.dispose();
    }
  }

  @override
  void initState() {
    super.initState();
    widget.service.addListener(load);
    load();
    unawaited(widget.service.refresh());
    restore();
  }

  @override
  void dispose() {
    widget.service.removeListener(load);
    super.dispose();
  }

  Future<void> load() async {
    final v = await widget.service.snapshot();
    if (mounted) setState(() => data = v);
  }

  Future<void> restore() async {
    final key = await widget.service.scope();
    if (key == null) return;
    final saved = await widget.service.store.setting('coopScan:$key');
    if (saved is String && mounted) await resolve(saved);
  }

  Future<void> resolve(String value) async {
    if (working) return;
    if (!validCoopCode(value)) {
      setState(() {
        code = null;
        candidate = null;
        message = 'This QR code is not a FarmerPlus cooperative invitation.';
      });
      return;
    }
    final key = await widget.service.scope();
    if (key == null) return;
    await widget.service.store.setSetting('coopScan:$key', value);
    if (!mounted) return;
    setState(() {
      working = true;
      code = value;
      candidate = null;
      message = 'Checking invitation…';
    });
    try {
      if (!await widget.service.store.ready('coop')) {
        throw StateError('Install Coop first.');
      }
      if (!await widget.service.syncInstallation(key)) {
        throw StateError('Connect to confirm Coop installation.');
      }
      final r = await widget.service.sync.request(
        'GET',
        '/coops/resolve?code=${Uri.encodeQueryComponent(value)}',
      );
      if (mounted && await widget.service.scope() == key) {
        if (!await approveCooperative(r)) {
          await cancel();
          return;
        }
        if (!mounted || await widget.service.scope() != key) return;
        setState(() {
          candidate = Map<String, dynamic>.from(r);
          message = null;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => message =
              'Saved on this phone — invitation not verified. Connect and retry. Invalid or expired invitations cannot be joined.',
        );
      }
    } finally {
      if (mounted) setState(() => working = false);
    }
  }

  Future<bool> approveCooperative(Map coop) async {
    final sharing = coop['sharing'];
    if (sharing is! Map) {
      throw StateError('Sharing details are unavailable. Connect and retry.');
    }
    if (sharing['approved'] == true) return true;
    if (!mounted || !await reviewSharing(context, sharing)) return false;
    await widget.service.approveRecipient(sharing, true);
    return mounted;
  }

  Future<void> openMember(Map member) async {
    if (working) return;
    setState(() => working = true);
    await guarded(context, () async {
      final key = await widget.service.scope();
      if (key == null ||
          !await widget.service.store.ready('coop') ||
          !await widget.service.syncInstallation(key)) {
        throw StateError(
          'Connect with Coop installed to review this cooperative.',
        );
      }
      final coop = await widget.service.sync.request(
        'GET',
        '/coops/${member['coop']}/details',
      );
      if (!mounted ||
          await widget.service.scope() != key ||
          !await approveCooperative(coop)) {
        return;
      }
      if (!mounted) return;
      await openPage(
        context,
        PageFrame(
          coop['name'],
          children: [
            if (coop['demo'] == true)
              note(
                'Demonstration only · No payment collected. No information is sent to a real cooperative.',
              ),
            heading(context, 'Membership'),
            Text(
              member['status'] == 'left'
                  ? 'You have left this cooperative.'
                  : 'Demo membership',
            ),
            heading(context, 'Data sharing'),
            Text(coop['sharing']['purpose']),
            for (final field in coop['sharing']['fields'])
              ListTile(title: Text(sharingFieldLabel(field))),
            heading(context, 'Membership terms'),
            Text(coop['terms']),
          ],
        ),
      );
    });
    if (mounted) setState(() => working = false);
  }

  Future<void> cancel() async {
    final key = await widget.service.scope();
    if (key != null) {
      await widget.service.store.setSetting('coopScan:$key', null);
    }
    if (mounted) {
      setState(() {
        candidate = null;
        code = null;
        message = null;
      });
    }
  }

  Future<void> act(Map coop, String action) async {
    final sharing = coop['sharing'];
    if (action == 'join' && sharing is! Map) {
      throw StateError('Sharing details are unavailable. Connect and retry.');
    }
    final yes = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(
          action == 'leave'
              ? 'Leave ${coop['name']}?'
              : 'Join ${coop['name']}?',
        ),
        content: Text(
          action == 'leave'
              ? 'Your membership will show as left only after the backend confirms. History is kept. This demonstration has no payment to cancel.'
              : 'Demo — no payment collected.\n\n${coop['terms']}\n\nBy joining, you approve sharing with ${sharing['name']}: ${sharing['purpose']}\n\nInformation shared: ${(sharing['fields'] as List).map(sharingFieldLabel).join(', ')}. You can withdraw future sharing in Data sharing.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: Text(action == 'leave' ? 'Leave cooperative' : 'Join demo'),
          ),
        ],
      ),
    );
    if (yes == true && mounted) {
      await guarded(context, () async {
        if (action == 'join') {
          await widget.service.approveRecipient(sharing as Map, true);
        }
        await widget.service.membership(coop, action);
      });
      if (action == 'join') await cancel();
    }
  }

  @override
  Widget build(BuildContext c) {
    final members = List<Map<String, dynamic>>.from(data['members'] ?? []);
    final pending = List<Map<String, dynamic>>.from(
      data['pending'] ?? [],
    ).where((a) => a['type'] == 'membership').toList();
    return PageFrame(
      'Coop',
      children: [
        heading(c, 'Your Cooperatives'),
        FilledButton.icon(
          onPressed: working
              ? null
              : () async {
                  final result = await Navigator.of(c).push<String>(
                    MaterialPageRoute(builder: (_) => const CoopScannerPage()),
                  );
                  if (result != null && mounted) await resolve(result);
                },
          icon: const Icon(Icons.qr_code_scanner),
          label: const Text('Scan invitation'),
        ),
        OutlinedButton.icon(
          onPressed: working ? null : () => guarded(c, chooseImage),
          icon: const Icon(Icons.photo_library_outlined),
          label: const Text('Choose QR image'),
        ),
        const Text(
          'The image is decoded on this phone. Only the invitation code is sent for verification.',
        ),
        if (message != null) note(message!),
        if (code != null && candidate == null) ...[
          TextButton(
            onPressed: working ? null : () => resolve(code!),
            child: const Text('Retry invitation'),
          ),
          TextButton(onPressed: cancel, child: const Text('Cancel')),
        ],
        if (candidate case final coop?) ...[
          heading(c, coop['name']),
          const Text('Demo — no payment collected'),
          Text(
            'Annual membership fee: ${coop['currency']} ${(coop['annual_minor'] / 100).toStringAsFixed(2)}',
          ),
          note(coop['terms']),
          Row(
            children: [
              Expanded(
                child: FilledButton(
                  onPressed: () => act(coop, 'join'),
                  child: const Text('Join'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton(
                  onPressed: cancel,
                  child: const Text('Cancel'),
                ),
              ),
            ],
          ),
        ],
        if (members.isEmpty && pending.isEmpty && candidate == null)
          note(
            'You haven’t added a cooperative yet. Scan an invitation to review it before joining.',
          ),
        for (final action in pending)
          ListTile(
            title: Text(action['name']),
            subtitle: Text(
              '${action['failed'] == true ? 'Failed to sync' : 'Pending'} — ${action['body']['action']} request saved on this phone',
            ),
            trailing: TextButton(
              onPressed: widget.service.busy
                  ? null
                  : () async {
                      final yes = await showDialog<bool>(
                        context: c,
                        builder: (d) => AlertDialog(
                          title: const Text('Stop retrying this request?'),
                          content: const Text(
                            'This removes the pending retry from this phone. It cannot undo a change already accepted by the server. Refresh status to check your membership.',
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(d, false),
                              child: const Text('Keep request'),
                            ),
                            FilledButton(
                              onPressed: () => Navigator.pop(d, true),
                              child: const Text('Stop retrying'),
                            ),
                          ],
                        ),
                      );
                      if (yes == true && c.mounted) {
                        await guarded(
                          c,
                          () =>
                              widget.service.discard(action['body']['eventId']),
                        );
                      }
                    },
              child: const Text('Stop retrying'),
            ),
          ),
        for (final member in members) ...[
          const Divider(),
          ListTile(
            title: Text(member['name']),
            onTap: working ? null : () => openMember(member),
            subtitle: Text(
              '${member['status'] == 'left' ? 'Left cooperative' : 'Demo member'} · Synced\nDemo — no payment collected\nAnnual membership fee: ${member['currency']} ${(member['annual_minor'] / 100).toStringAsFixed(2)}',
            ),
            trailing: member['status'] == 'left'
                ? null
                : TextButton(
                    onPressed: pending.any((a) => a['coop'] == member['coop'])
                        ? null
                        : () => act(member, 'leave'),
                    child: const Text('Leave'),
                  ),
          ),
        ],
        Text(data['status'] ?? 'Loading…'),
        TextButton(
          onPressed: () => guarded(c, widget.service.refresh),
          child: const Text('Refresh status'),
        ),
      ],
    );
  }
}

class CoopScannerPage extends StatefulWidget {
  const CoopScannerPage({super.key});
  @override
  State<CoopScannerPage> createState() => _CoopScannerPageState();
}

class _CoopScannerPageState extends State<CoopScannerPage>
    with WidgetsBindingObserver {
  final controller = MobileScannerController(
    formats: [BarcodeFormat.qrCode],
    detectionSpeed: DetectionSpeed.noDuplicates,
  );
  bool captured = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!controller.value.hasCameraPermission) return;
    if (state == AppLifecycleState.resumed && !captured) {
      unawaited(controller.start());
    } else if (state != AppLifecycleState.resumed) {
      unawaited(controller.stop());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(controller.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext c) => Scaffold(
    appBar: AppBar(
      title: const Text('Scan cooperative QR'),
      actions: [
        IconButton(
          tooltip: 'Torch',
          onPressed: () => guarded(c, controller.toggleTorch),
          icon: const Icon(Icons.flashlight_on),
        ),
      ],
    ),
    body: Stack(
      children: [
        MobileScanner(
          controller: controller,
          onDetect: (capture) {
            if (captured) return;
            final value = capture.barcodes
                .map((b) => b.rawValue)
                .whereType<String>()
                .firstOrNull;
            if (value != null) {
              captured = true;
              unawaited(controller.stop());
              Navigator.pop(c, value);
            }
          },
          errorBuilder: (context, error) => Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'Camera unavailable. Allow camera access in Android Settings, then retry. No photo is uploaded.',
                  ),
                  TextButton(
                    onPressed: () => guarded(c, controller.start),
                    child: const Text('Retry camera'),
                  ),
                  TextButton(
                    onPressed: () => Navigator.pop(c),
                    child: const Text('Cancel'),
                  ),
                ],
              ),
            ),
          ),
        ),
        const Positioned(
          left: 20,
          right: 20,
          bottom: 32,
          child: IgnorePointer(
            child: Card(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  'Point the camera at a FarmerPlus cooperative QR code. Scanning does not join or pay.',
                ),
              ),
            ),
          ),
        ),
      ],
    ),
  );
}
