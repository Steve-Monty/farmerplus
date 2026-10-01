import 'package:path/path.dart' as path;
import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'course_downloads.dart';
import 'learning_webview.dart';
import 'offline_lesson_frame.dart';
import 'store.dart';
import 'ui.dart';

class CourseDownloadPage extends StatefulWidget {
  final FarmStore store;
  final int courseId;
  const CourseDownloadPage({
    super.key,
    required this.store,
    required this.courseId,
  });
  @override
  State<CourseDownloadPage> createState() => _CourseDownloadPageState();
}

class _CourseDownloadPageState extends State<CourseDownloadPage> {
  late final manager = CourseDownloads.of(widget.store);
  Map<String, dynamic>? current, manifest;
  Set<int> selected = {};
  String option = 'all', error = '';
  bool loading = true, refreshing = false, mobile = false;
  @override
  void initState() {
    super.initState();
    manager.addListener(changed);
    load();
  }

  @override
  void dispose() {
    manager.removeListener(changed);
    super.dispose();
  }

  void changed() {
    load(refresh: false);
  }

  Future<void> load({bool refresh = true}) async {
    final saved = await manager.state(widget.courseId);
    if (mounted) {
      setState(() {
        current = saved;
        if (manifest == null && saved?['manifest'] != null) {
          manifest = saved!['manifest'];
          selectAll();
        }
        loading = manifest == null;
      });
    }
    if (refresh) {
      try {
        final m = await manager.manifest(widget.courseId);
        if (mounted) {
          setState(() {
            manifest = m;
            selectAll();
            error = '';
          });
        }
      } catch (e) {
        if (mounted) {
          setState(() => error = e.toString().replaceFirst('Bad state: ', ''));
        }
      }
    }
    if (mounted) setState(() => loading = false);
  }

  void selectAll() {
    selected = (manifest?['activities'] as List? ?? [])
        .where((r) => r['offline'] == true)
        .map((r) => r['id'] as int)
        .toSet();
  }

  Future<void> remove([int? id]) async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(
          id == null ? 'Remove this download?' : 'Remove saved lesson?',
        ),
        content: const Text(
          'Enrolment, confirmed progress and purchase history are kept. Any pending work remains protected on this phone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Keep'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Remove download'),
          ),
        ],
      ),
    );
    if (accepted == true) {
      await manager.remove(
        widget.courseId,
        resources: id == null ? null : {id},
      );
      await load(refresh: false);
    }
  }

  @override
  Widget build(BuildContext c) {
    final items = manifest?['activities'] as List? ?? [];
    final installed = current?['installed'] as Map? ?? {};
    final eligible = items.where((r) => r['offline'] == true).toList();
    final chosen = items.where((r) => selected.contains(r['id'])).toList();
    final total = chosen.fold<int>(0, (n, r) => n + (r['bytes'] as int));
    final missing = chosen
        .where((r) => installed['${r['id']}']?['sha256'] != r['sha256'])
        .fold<int>(0, (n, r) => n + (r['bytes'] as int));
    final jobItems = (current?['jobManifest']?['activities'] as List? ?? [])
        .where((r) => (current?['selected'] as List? ?? []).contains(r['id']))
        .toList();
    final jobTotal = jobItems.fold<int>(0, (n, r) => n + (r['bytes'] as int));
    final done =
        jobItems
            .where((r) => installed['${r['id']}']?['sha256'] == r['sha256'])
            .fold<int>(0, (n, r) => n + (r['bytes'] as int)) +
        (current?['bytesReceived'] as int? ?? 0);
    final state = current?['state'];
    final active = [
      'queued',
      'downloading',
      'waitingConnection',
      'waitingWifi',
    ].contains(state);
    return PageFrame(
      'Download',
      showArtwork: false,
      children: [
        Text(
          manifest?['name'] ?? 'Course downloads',
          style: Theme.of(c).textTheme.headlineMedium,
        ),
        if (loading) const LinearProgressIndicator(),
        if (error.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(error),
          ),
        if (current != null) ...[
          ListTile(
            leading: Icon(
              installed.isEmpty
                  ? Icons.download_rounded
                  : Icons.offline_pin_rounded,
            ),
            title: Text(CourseDownloads.label(current!)),
            subtitle: Text(
              '${installed.length} resources saved · download status is separate from learning progress',
            ),
          ),
          if (jobTotal > 0 && state != 'idle') ...[
            LinearProgressIndicator(value: (done / jobTotal).clamp(0.0, 1.0)),
            gap(8),
            Text(
              '${learningBytes(done.clamp(0, jobTotal))} of ${learningBytes(jobTotal)} · ${learningBytes((jobTotal - done).clamp(0, jobTotal))} remaining',
            ),
            if (active || state == 'paused')
              Wrap(
                spacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: () => manager.command(
                      widget.courseId,
                      active ? 'paused' : 'queued',
                    ),
                    icon: Icon(
                      active ? Icons.pause_rounded : Icons.play_arrow_rounded,
                    ),
                    label: Text(active ? 'Pause' : 'Resume'),
                  ),
                  TextButton(
                    onPressed: () =>
                        manager.command(widget.courseId, 'cancelled'),
                    child: const Text('Cancel download'),
                  ),
                ],
              ),
            if (state == 'waitingWifi')
              TextButton.icon(
                onPressed: () => manager.allowMobile(widget.courseId),
                icon: const Icon(Icons.network_cell),
                label: const Text('Allow mobile data for this download'),
              ),
            if (current?['error'] != null) Text(current!['error']),
          ],
        ],
        if (manifest != null) ...[
          gap(),
          Text(
            '${eligible.length} supported lessons · ${items.length - eligible.length} require internet',
            style: Theme.of(c).textTheme.titleMedium,
          ),
          RadioGroup<String>(
            groupValue: option,
            onChanged: (value) {
              if (!active && value != null) {
                setState(() {
                  option = value;
                  if (value == 'choose') {
                    selected.clear();
                  } else {
                    selectAll();
                  }
                });
              }
            },
            child: Column(
              children: [
                RadioListTile<String>(
                  value: 'all',
                  enabled: !active,
                  title: const Text('Complete offline package'),
                  subtitle: const Text(
                    'All supported content; internet-only activities stay online',
                  ),
                ),
                RadioListTile<String>(
                  value: 'choose',
                  enabled: !active,
                  title: const Text('Choose lessons'),
                  subtitle: const Text(
                    'Select sections or individual resources',
                  ),
                ),
                RadioListTile<String>(
                  value: 'noVideo',
                  enabled: !active,
                  title: const Text('Download without videos'),
                  subtitle: const Text(
                    'Reading packages only. Video-dependent lessons require internet.',
                  ),
                ),
              ],
            ),
          ),
          for (final section
              in items.map((r) => r['section'] ?? 'Lessons').toSet()) ...[
            Row(
              children: [
                Expanded(
                  child: Text(
                    section.toString(),
                    style: Theme.of(c).textTheme.titleMedium,
                  ),
                ),
                if (option == 'choose')
                  TextButton(
                    onPressed: active
                        ? null
                        : () => setState(() {
                            selected.addAll(
                              items
                                  .where(
                                    (r) =>
                                        r['section'] == section &&
                                        r['offline'] == true,
                                  )
                                  .map((r) => r['id'] as int),
                            );
                          }),
                    child: const Text('Select section'),
                  ),
              ],
            ),
            for (final r in items.where(
              (r) => (r['section'] ?? 'Lessons') == section,
            ))
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: selected.contains(r['id']),
                onChanged: !active && option == 'choose' && r['offline'] == true
                    ? (v) => setState(() {
                        v == true
                            ? selected.add(r['id'])
                            : selected.remove(r['id']);
                      })
                    : null,
                title: Text(r['name']),
                subtitle: Text(
                  r['offline'] == true
                      ? '${learningBytes(r['bytes'])} · ${installed['${r['id']}']?['sha256'] == r['sha256'] ? 'Already downloaded' : 'Reading with included images'}'
                      : r['reason'] ?? 'Internet required',
                ),
              ),
          ],
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Allow mobile data'),
            subtitle: const Text('Wi-Fi only by default'),
            value: mobile,
            onChanged: active ? null : (v) => setState(() => mobile = v),
          ),
          FilledButton.icon(
            onPressed: active || selected.isEmpty
                ? null
                : () => guarded(c, () async {
                    await manager.enqueue(
                      widget.courseId,
                      manifest!,
                      selected,
                      mobileData: mobile,
                    );
                    await load(refresh: false);
                  }),
            icon: const Icon(Icons.download_rounded),
            label: Text(
              'Download ${selected.length} · ${learningBytes(missing)}',
            ),
          ),
          if (selected.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                '${learningBytes(total)} selected. Only missing or changed resources are transferred.',
              ),
            ),
          TextButton.icon(
            onPressed: refreshing
                ? null
                : () => guarded(c, () async {
                    setState(() => refreshing = true);
                    try {
                      await load();
                    } finally {
                      if (mounted) setState(() => refreshing = false);
                    }
                  }),
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('Check for updates'),
          ),
        ],
        if (installed.isNotEmpty) ...[
          heading(c, 'Manage saved resources'),
          FutureBuilder<int>(
            future: directoryBytes(widget.store, manager, widget.courseId),
            builder: (c, s) => Text(
              'Storage used: ${s.hasData ? learningBytes(s.data!) : 'Checking…'}',
            ),
          ),
          for (final r in installed.values)
            ListTile(
              title: Text(r['name']),
              subtitle: Text(learningBytes(r['bytes'])),
              trailing: IconButton(
                tooltip: 'Remove ${r['name']}',
                onPressed: () => guarded(c, () => remove(r['id'] as int)),
                icon: const Icon(Icons.delete_outline_rounded),
              ),
            ),
          OutlinedButton.icon(
            onPressed: () => guarded(c, () => remove()),
            icon: const Icon(Icons.delete_outline_rounded),
            label: const Text('Remove entire download'),
          ),
        ],
      ],
    );
  }
}

Future<int> directoryBytes(
  FarmStore store,
  CourseDownloads manager,
  int id,
) async {
  final dir = Directory(
    '${store.filesPath}/learning/${await manager.binding()}/$id',
  );
  var total = 0;
  if (await dir.exists()) {
    await for (final f in dir.list(recursive: true, followLinks: false)) {
      if (f is File) {
        total += await f.length();
      }
    }
  }
  return total;
}

class ManageCourseDownloadsPage extends StatefulWidget {
  final FarmStore store;
  const ManageCourseDownloadsPage({super.key, required this.store});
  @override
  State<ManageCourseDownloadsPage> createState() =>
      _ManageCourseDownloadsPageState();
}

class _ManageCourseDownloadsPageState extends State<ManageCourseDownloadsPage> {
  late final manager = CourseDownloads.of(widget.store);
  List<Map<String, dynamic>> courses = [];
  @override
  void initState() {
    super.initState();
    manager.addListener(load);
    load();
  }

  @override
  void dispose() {
    manager.removeListener(load);
    super.dispose();
  }

  Future<void> load() async {
    final values = await manager.all();
    if (mounted) setState(() => courses = values);
  }

  @override
  Widget build(BuildContext c) => PageFrame(
    'Manage downloads',
    children: [
      if (courses.isEmpty) const Text('No course downloads yet.'),
      for (final course in courses)
        ListTile(
          leading: const Icon(Icons.download_done_rounded),
          title: Text(course['manifest']['name']),
          subtitle: Text(CourseDownloads.label(course)),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => openPage(
            c,
            CourseDownloadPage(
              store: widget.store,
              courseId: course['manifest']['courseid'],
            ),
          ),
        ),
    ],
  );
}

class OfflineReadingPage extends StatefulWidget {
  final FarmStore store;
  final Map<String, dynamic> resource;
  final int courseId;
  const OfflineReadingPage({
    super.key,
    required this.store,
    required this.resource,
    required this.courseId,
  });
  @override
  State<OfflineReadingPage> createState() => _OfflineReadingPageState();
}

class _OfflineReadingPageState extends State<OfflineReadingPage> {
  WebViewController? web;
  Widget? browserLesson;
  String? error, key;
  Timer? timer;
  int lastY = -1;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final manager = CourseDownloads.of(widget.store);
      key =
          'readingPosition:${await manager.binding()}:${widget.courseId}:${widget.resource['id']}:${widget.resource['sha256']}';
      final bytes = await manager.readResource(widget.resource);
      await widget.store.setSetting(
        'lastLesson:${await manager.binding()}:${widget.courseId}',
        widget.resource['id'],
      );
      if (kIsWeb) {
        browserLesson = offlineLessonFrame(bytes);
        if (mounted) setState(() {});
        return;
      }
      final file = File(widget.resource['path']);
      final root = Directory(
        '${widget.store.filesPath}/learning/${await manager.binding()}/${widget.courseId}',
      ).absolute.path;
      if (!path.isWithin(
        path.normalize(root),
        path.normalize(file.absolute.path),
      )) {
        throw StateError('This resource belongs to another account.');
      }
      final y = await widget.store.setting(key!) ?? 0;
      final controller = WebViewController();
      await controller.setJavaScriptMode(JavaScriptMode.disabled);
      await controller.setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (_) async {
            await controller.scrollTo(0, y as int);
          },
          onNavigationRequest: (r) =>
              r.url == Uri.file(file.path).toString() || r.url == 'about:blank'
              ? NavigationDecision.navigate
              : NavigationDecision.prevent,
        ),
      );
      await controller.loadFile(file.path);
      if (mounted) setState(() => web = controller);
      timer = Timer.periodic(const Duration(seconds: 3), (_) => savePosition());
    } catch (e) {
      if (mounted) {
        setState(() => error = e.toString().replaceFirst('Bad state: ', ''));
      }
    }
  }

  Future<void> savePosition() async {
    if (web == null || key == null) return;
    try {
      final y = (await web!.getScrollPosition()).dy.round();
      if (y != lastY) {
        lastY = y;
        await widget.store.setSetting(key!, y);
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    timer?.cancel();
    savePosition();
    super.dispose();
  }

  @override
  Widget build(BuildContext c) => Scaffold(
    appBar: AppBar(
      title: Text(widget.resource['name']),
      actions: const [
        Tooltip(
          message: 'Downloaded reading',
          child: Padding(
            padding: EdgeInsets.all(16),
            child: Icon(Icons.offline_pin_rounded),
          ),
        ),
      ],
    ),
    body: SafeArea(
      child: error != null
          ? Padding(padding: const EdgeInsets.all(24), child: Text(error!))
          : browserLesson != null
          ? browserLesson!
          : web == null
          ? const Center(child: CircularProgressIndicator())
          : learningWebView(web!),
    ),
  );
}
