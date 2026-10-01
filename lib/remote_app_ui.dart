import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'auth.dart';
import 'session_activity.dart';
import 'domain.dart';
import 'farm_details.dart';
import 'store.dart';
import 'ui.dart';
import 'remote_apps.dart';
import 'remote_frame.dart';
import 'remote_export.dart';

class RemoteInstallPage extends StatefulWidget {
  final FarmStore store;
  final MiniManifest app;
  final VoidCallback onOpen;
  const RemoteInstallPage({
    super.key,
    required this.store,
    required this.app,
    required this.onOpen,
  });
  @override
  State<RemoteInstallPage> createState() => _RemoteInstallState();
}

class _RemoteInstallState extends State<RemoteInstallPage> {
  late final manager = RemoteApps.of(widget.store);
  bool ready = false, cancel = false;
  int? installedVersion;
  String? error;
  Map<String, dynamic>? listing;
  @override
  void initState() {
    super.initState();
    manager.addListener(changed);
    load();
  }

  void changed() {
    if (mounted) setState(() {});
  }

  Future<void> load() async {
    final isReady = await widget.store.ready(widget.app.id);
    final manifest = await widget.store.setting(
      'miniapp:manifest:${widget.app.id}',
    );
    final row = await manager.listing(widget.app.id);
    if (mounted) {
      setState(() {
        ready = isReady;
        installedVersion = manifest?['version'];
        listing = row;
      });
    }
  }

  @override
  void dispose() {
    cancel = true;
    manager.removeListener(changed);
    super.dispose();
  }

  Future<void> download() async {
    setState(() {
      cancel = false;
      error = null;
    });
    try {
      await manager.install(widget.app, cancelled: () => cancel || !mounted);
    } catch (e) {
      if (mounted) {
        setState(() => error = e.toString().replaceFirst('Bad state: ', ''));
      }
    }
    await load();
  }

  @override
  Widget build(BuildContext c) => PageFrame(
    widget.app.title,
    children: [
      Center(child: AppArtwork(id: widget.app.id, size: 92)),
      gap(20),
      Text(widget.app.description, style: Theme.of(c).textTheme.headlineSmall),
      heading(c, 'Your animals, kept simple'),
      const Text(
        'Record individuals or groups, choose an existing farm location, and keep a history of moves, numbers, care and observations.',
      ),
      heading(c, 'Downloaded from FarmerPlus'),
      Text(
        'Free · Version ${widget.app.version}${listing == null ? '' : ' · ${((listing!['release']['bytes'] as num) / 1024).toStringAsFixed(0)} KB'}',
      ),
      if (listing != null)
        Text(
          'Released ${listing!['release']['releasedAt'].toString().split('T').first}',
        ),
      const Text(
        'The screens and functionality are downloaded when you install. After installation you can record animals offline. Sync and new downloads need a connection.',
      ),
      heading(c, 'Shared with this app'),
      const Text(
        'Your farms and locations; animal records and photos you choose. It can open the shared farm and location editors. Your sign-in details stay with FarmerPlus.',
      ),
      gap(20),
      if (manager.downloading) ...[
        LinearProgressIndicator(
          value: manager.total == 0 ? null : manager.received / manager.total,
        ),
        gap(8),
        Text(
          '${manager.phase}${manager.phase == 'Downloading' && manager.total > 0 ? ' ${(100 * manager.received / manager.total).floor()}% · ${manager.received} of ${manager.total} bytes' : ''}',
          semanticsLabel: manager.phase,
        ),
        TextButton(
          onPressed: () => setState(() => cancel = true),
          child: const Text('Pause download'),
        ),
      ] else ...[
        if (ready)
          FilledButton(onPressed: widget.onOpen, child: const Text('Open app')),
        if (!ready || (installedVersion ?? 0) < widget.app.version)
          FilledButton.icon(
            onPressed: kIsWeb ? download : null,
            icon: const Icon(Icons.download),
            label: Text(ready ? 'Download update' : 'Install My Animals'),
          ),
        if (!kIsWeb)
          const Text(
            'Use FarmerPlus in a browser to install downloadable apps.',
          ),
        if (ready)
          TextButton(
            onPressed: () => guarded(c, () async {
              final confirm = await showDialog<bool>(
                context: c,
                builder: (d) => AlertDialog(
                  title: const Text('Remove app from this device?'),
                  content: const Text(
                    'Its downloaded screens will be removed. Your animal records, photos and pending changes will be kept for reinstalling.',
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(d, false),
                      child: const Text('Keep app'),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.pop(d, true),
                      child: const Text('Remove app'),
                    ),
                  ],
                ),
              );
              if (confirm == true) {
                await manager.remove(widget.app.id);
                await load();
              }
            }),
            child: const Text('Remove app · keep records'),
          ),
      ],
      if (error != null) note(error!, icon: Icons.error_outline),
    ],
  );
}

class RemoteAppPage extends StatefulWidget {
  final FarmStore store;
  final String appId;
  final String title;
  const RemoteAppPage({
    super.key,
    required this.store,
    required this.appId,
    this.title = 'My Animals',
  });
  @override
  State<RemoteAppPage> createState() => _RemoteAppPageState();
}

class _RemoteAppPageState extends State<RemoteAppPage> {
  late final manager = RemoteApps.of(widget.store);
  final changes = ValueNotifier<int>(0);
  String? document, error, owner;
  Timer? poll;
  @override
  void initState() {
    super.initState();
    AccountAccess.unlocked.addListener(accessChanged);
    manager.addListener(changed);
    load();
  }

  Future<void> load() async {
    try {
      owner = await widget.store.setting('accessOwner');
      final html = await manager.document(widget.appId);
      if (mounted) setState(() => document = html);
      await manager.synchronize(widget.appId);
      if (!mounted) return;
      poll = Timer.periodic(
        const Duration(seconds: 30),
        (_) => manager.synchronize(widget.appId),
      );
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    }
  }

  void accessChanged() {
    if (AccountAccess.unlocked.value != owner && mounted) {
      setState(() => document = null);
      Navigator.of(context).popUntil((r) => r.isFirst);
    }
  }

  void changed() {
    if (mounted) changes.value++;
  }

  @override
  void dispose() {
    poll?.cancel();
    AccountAccess.unlocked.removeListener(accessChanged);
    manager.removeListener(changed);
    changes.dispose();
    super.dispose();
  }

  Map<String, dynamic> theme() {
    final s = Theme.of(context).colorScheme;
    String hex(Color c) => '#${c.toARGB32().toRadixString(16).substring(2)}';
    return {
      'dark': s.brightness == Brightness.dark,
      'textScale': MediaQuery.textScalerOf(context).scale(16) / 16,
      'colors': {
        'primary': hex(s.primary),
        'on-primary': hex(s.onPrimary),
        'surface': hex(s.surface),
        'card': hex(s.surfaceContainerLowest),
        'ink': hex(s.onSurface),
        'muted': hex(s.onSurfaceVariant),
        'line': hex(s.outlineVariant),
        'soft': hex(s.primaryContainer),
        'danger': hex(s.error),
      },
    };
  }

  Future<Map<String, dynamic>> bootstrap() async {
    final saved = await manager.data(widget.appId),
        farms = await widget.store.records('farm');
    final chosen =
        await widget.store.setting('miniapp:farm:${widget.appId}') ??
        await widget.store.setting('selectedFarm');
    return {
      ...saved,
      'farms': farms,
      'locations': await widget.store.records('field'),
      'farmId': farms.any((f) => f['id'] == chosen)
          ? chosen
          : farms.firstOrNull?['id'],
      'deviceId': await manager.deviceId(),
      'theme': theme(),
      'draft': await widget.store.setting('miniapp:draft:${widget.appId}:form'),
    };
  }

  Future<String> request(String raw) async {
    try {
      if (!mounted ||
          owner == null ||
          AccountAccess.unlocked.value != owner ||
          await widget.store.setting('accessOwner') != owner ||
          !await widget.store.ready(widget.appId)) {
        throw StateError('This account or app is no longer open.');
      }
      final message = jsonDecode(raw),
          a = Map<String, dynamic>.from(message['args']);
      dynamic value;
      switch (message['method']) {
        case 'activity':
          SessionActivity.recordInteraction?.call();
          value = true;
        case 'context.get':
          value = await bootstrap();
        case 'context.selectFarm':
          if (!(await widget.store.records(
            'farm',
          )).any((f) => f['id'] == a['farmId'])) {
            throw StateError('Choose one of your farms.');
          }
          await widget.store.setSetting(
            'miniapp:farm:${widget.appId}',
            a['farmId'],
          );
          value = true;
        case 'commands.enqueue':
          await manager.enqueue(
            widget.appId,
            Map<String, dynamic>.from(a['command']),
            Map<String, dynamic>.from(a['state']),
          );
          value = await bootstrap();
        case 'drafts.put':
          if (a['key'] != 'form' || jsonEncode(a['data']).length > 64000) {
            throw StateError('Invalid draft.');
          }
          await widget.store.setSetting(
            'miniapp:draft:${widget.appId}:form',
            a['data'],
          );
          value = true;
        case 'drafts.remove':
          await widget.store.setSetting(
            'miniapp:draft:${widget.appId}:form',
            null,
          );
          value = true;
        case 'farms.create':
        case 'locations.create':
          final isArea = message['method'] == 'locations.create';
          if (isArea &&
              !(await widget.store.records(
                'farm',
              )).any((f) => f['id'] == a['farmId'])) {
            throw StateError('Choose one of your farms.');
          }
          if (!mounted) throw StateError('App closed.');
          await Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => FarmDetailsPage(
                store: widget.store,
                kind: isArea ? 'field' : 'farm',
                farmId: a['farmId'],
              ),
            ),
          );
          value = true;
        case 'media.choosePhoto':
          final picked = await ImagePicker().pickImage(
            source: ImageSource.gallery,
            maxWidth: 1600,
            imageQuality: 85,
          );
          if (picked != null) {
            final hash = await widget.store.keepMedia(picked.path);
            await widget.store.setSetting(
              'miniapp:photo:${widget.appId}:$hash',
              true,
            );
            value = {'hash': hash};
          }
        case 'media.getPreview':
          final sha = a['hash'];
          final saved = await manager.data(widget.appId);
          final linked =
              (saved['state']['profiles'] as List).any(
                (p) => p['photo'] == sha,
              ) ||
              (saved['state']['events'] as List).any(
                (p) => p['photo'] == sha,
              ) ||
              await widget.store.setting(
                    'miniapp:photo:${widget.appId}:$sha',
                  ) ==
                  true;
          if (!linked) {
            throw StateError('This photo does not belong to this app.');
          }
          var bytes = await widget.store.mediaBytes(sha);
          if (bytes == null) {
            await manager.sync.download(sha);
            bytes = await widget.store.mediaBytes(sha);
          }
          if (bytes == null) {
            throw StateError('Photo is not available offline yet.');
          }
          value = 'data:image/jpeg;base64,${base64Encode(bytes)}';
        case 'sync.request':
          await manager.synchronize(widget.appId, explicit: true);
          value = true;
        case 'exports.create':
          await exportMiniRecords(
            '${widget.appId}-${DateTime.now().toIso8601String().split('T').first}.json',
            jsonEncode(await bootstrap()),
          );
          value = true;
        case 'conflicts.remote':
          value = await manager.sync.request(
            'GET',
            '/api/v1/apps/${widget.appId}/records',
          );
        case 'conflicts.discard':
          final remote = await manager.sync.request(
            'GET',
            '/api/v1/apps/${widget.appId}/records',
          );
          await widget.store.appLifecycle(() async {
            final old = await manager.data(widget.appId);
            await widget.store.setSetting(
              'miniapp:recovery:${widget.appId}',
              old,
            );
            await manager.write(widget.appId, {
              ...remote,
              'serverRevision': remote['revision'],
              'queue': [],
              'status': 'Synced',
            });
          });
          value = await bootstrap();
        case 'conflicts.rebase':
          final remote = await manager.sync.request(
            'GET',
            '/api/v1/apps/${widget.appId}/records',
          );
          if (remote['revision'] != a['serverRevision']) {
            throw StateError(
              'Server records changed again. Please review again.',
            );
          }
          final queue = List<dynamic>.from(a['queue']);
          for (var i = 0; i < queue.length; i++) {
            if (queue[i]['expectedRevision'] != a['serverRevision'] + i) {
              throw StateError('Invalid revised queue.');
            }
          }
          await widget.store.appLifecycle(() async {
            await widget.store.setSetting(
              'miniapp:recovery:${widget.appId}',
              await manager.data(widget.appId),
            );
            await manager.write(widget.appId, {
              'state': a['state'],
              'revision': a['serverRevision'] + queue.length,
              'serverRevision': a['serverRevision'],
              'queue': queue,
              'status': 'Saved on this device · waiting to sync',
            });
          });
          value = await bootstrap();
        default:
          throw StateError('This app capability is not available.');
      }
      return jsonEncode({'value': value});
    } catch (e) {
      return jsonEncode({
        'error': e.toString().replaceFirst('Bad state: ', ''),
      });
    }
  }

  @override
  Widget build(BuildContext c) => Scaffold(
    appBar: AppBar(
      title: Row(
        children: [
          AppArtwork(id: widget.appId, size: 32),
          const SizedBox(width: 12),
          Text(widget.title),
        ],
      ),
      actions: [
        IconButton(
          tooltip: 'Back to FarmerPlus',
          icon: const Icon(Icons.home_outlined),
          onPressed: () => Navigator.of(c).popUntil((r) => r.isFirst),
        ),
      ],
    ),
    body: SafeArea(
      child: error != null
          ? Padding(padding: const EdgeInsets.all(24), child: Text(error!))
          : document == null
          ? const Center(child: CircularProgressIndicator())
          : RemoteFrame(html: document!, onRequest: request, changes: changes),
    ),
  );
}
