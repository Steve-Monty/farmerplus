import 'browser_bridge.dart' if (dart.library.html) 'browser_bridge_web.dart';
import 'course_downloads.dart';
import 'course_download_ui.dart';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:html/parser.dart' as html;
import 'package:html/dom.dart' as dom;
import 'package:crypto/crypto.dart';
import 'learning_viewer.dart';
import 'store.dart';
import 'ui.dart';
import 'auth.dart';
import 'sync.dart';

const learningHost = 'https://learn.agritec.earth';
String lessonText(String source) {
  final doc = html.parse(source);
  for (final node in doc.querySelectorAll('script,style,iframe')) {
    node.remove();
  }
  for (final node in doc.querySelectorAll('p,div,li,h1,h2,h3,h4,br')) {
    node.nodes.add(dom.Text('\n'));
  }
  return (doc.body?.text ?? '')
      .replaceAll(RegExp(r'[ \t]+'), ' ')
      .replaceAll(RegExp(r'\n\s*\n+'), '\n\n')
      .trim();
}

// Only these three entitled Learning resources are available to the app.
// The backend forwards its owner's scoped OIDC access token, never a Moodle
// admin token, password, user ID parameter or unrestricted web-service function.
class StudentLearning {
  final FarmStore store;
  final http.Client client;
  StudentLearning(this.store, {http.Client? client})
    : client = client ?? http.Client();

  Future<String> downloadKey(int id) async {
    final owner = await store.setting('studentId');
    if (owner is! String || !RegExp(r'^[a-f0-9]{32}$').hasMatch(owner)) {
      throw StateError('Verify your FarmerPlus identity before downloading.');
    }
    return 'learningCourse:$owner:farmerplus:farmerplus-learning:$id';
  }

  Future<Map<String, dynamic>?> savedCourse(int id) async {
    final owner = await store.setting('studentId');
    final value =
        await store.setting(await downloadKey(id)) ??
        await store.setting('learningCourse:$id');
    if (value is! Map ||
        value['owner'] != owner ||
        (value['tenant'] != null && value['tenant'] != 'farmerplus') ||
        (value['instance'] != null &&
            value['instance'] != 'farmerplus-learning')) {
      return null;
    }
    return Map<String, dynamic>.from(value);
  }

  Future<dynamic> resource(String kind, [int? id, int offset = 0]) async {
    final route = switch (kind) {
      'courses' =>
        offset == 0 ? '/learning/courses' : '/learning/courses?offset=$offset',
      'activities' => '/learning/activities/$id',
      'text' => '/learning/text/$id',
      'manifest' => '/learning/manifest/$id',
      _ => throw StateError('Unsupported Learning resource'),
    };
    if (kind != 'courses' && (id == null || id < 1)) {
      throw StateError('Invalid activity or course.');
    }
    return SyncEngine(store, client: client).request('GET', route);
  }

  Future<void> clearSession() async {
    // Remove only retired credentials. Current identity belongs to the one app session.
    if (!kIsWeb) {
      await AccountAccess.secure.delete(key: 'learning.student.token');
    }
  }

  Future<void> clearDownloads() async {
    final owner = await store.setting('studentId');
    final rows = await store.db.query(
      'settings',
      where: 'key LIKE ?',
      whereArgs: ['learningCourse:%'],
    );
    await store.db.transaction((tx) async {
      for (final row in rows) {
        final value = jsonDecode(row['value'] as String);
        if (value is Map && value['owner'] == owner) {
          await tx.delete(
            'settings',
            where: 'key = ?',
            whereArgs: [row['key']],
          );
        }
      }
    });
    await store.setSetting('learningCourses', null);
  }

  Future<void> connect(BuildContext context) async {
    try {
      await refresh();
    } on SyncRequestError catch (e) {
      if (e.statusCode != 403) rethrow;
      if (context.mounted) await openStudentWebsite(context, store);
    }
  }

  Future<void> refresh() async {
    final data = await resource('courses');
    final all = <dynamic>[...data['courses']];
    while (all.length < (data['total'] as int)) {
      if (all.length > 10000) {
        throw StateError(
          'Course list is too large. Existing downloads were kept.',
        );
      }
      final next = await resource('courses', null, all.length);
      if (next['farmerplus_id'] != data['farmerplus_id'] ||
          next['moodle_user_id'] != data['moodle_user_id'] ||
          next['courses'] is! List ||
          (next['courses'] as List).isEmpty) {
        throw StateError(
          'The course list changed. Refresh again; existing downloads were kept.',
        );
      }
      all.addAll(next['courses']);
    }
    final owner = await store.setting('studentId');
    if (data['farmerplus_id'] != owner ||
        !RegExp(r'^[a-f0-9]{32}$').hasMatch(owner ?? '')) {
      throw StateError(
        'Learning returned a different account. Existing downloads were kept.',
      );
    }
    final prior = await store.setting('learningUser');
    if (prior != null &&
        ((prior['farmerplusId'] != null && prior['farmerplusId'] != owner) ||
            (prior['id'] != null && prior['id'] != data['moodle_user_id']))) {
      throw StateError(
        'Existing lessons belong to a different learner. Complete verified account linking before replacing them.',
      );
    }
    await store.setSetting('learningUser', {
      'id': data['moodle_user_id'],
      'farmerplusId': owner,
      'name': await store.setting('accountName') ?? 'Learner',
    });
    await store.setSetting('learningCourses', {
      'owner': owner,
      'updated': DateTime.now().toUtc().toIso8601String(),
      'courses': [
        for (final course in all) {...course, 'fullname': course['name']},
      ],
      'total': data['total'],
    });
  }

  Future<Map<String, dynamic>> course(int id) async {
    final data = await resource('activities', id);
    return {
      'id': id,
      'owner': await store.setting('studentId'),
      'sections': [
        {
          'name': 'Activities',
          'modules': [
            for (final activity in data['activities'])
              {
                'id': activity['id'],
                'name': activity['name'],
                'modname': activity['type'],
                'url': activity['launch_url'],
              },
          ],
        },
      ],
      'updated': DateTime.now().toUtc().toIso8601String(),
    };
  }

  Future<void> downloadText(int id) async {
    final data = await course(id);
    var downloaded = 0;
    for (final section in data['sections']) {
      for (final module in section['modules']) {
        if (!{'page', 'book'}.contains(module['modname'])) continue;
        final content = await resource('text', module['id']);
        if (content['cmid'] != module['id'] ||
            content['text'] is! String ||
            utf8.encode(content['text']).length > 2 * 1024 * 1024) {
          throw StateError(
            'The lesson download could not be verified. Existing text was kept.',
          );
        }
        module['offlineText'] = content['text'];
        downloaded++;
      }
    }
    data['downloadedTexts'] = downloaded;
    await store.setSetting(await downloadKey(id), data);
  }

  Future<Map<String, dynamic>> downloadManifest(int id) async {
    final result = Map<String, dynamic>.from(await resource('manifest', id));
    final owner = await store.setting('studentId');
    if (result['schema'] != 1 ||
        result['courseid'] != id ||
        result['farmerplus_id'] != owner ||
        result['tenant_id'] != 'farmerplus' ||
        result['instance_id'] != 'farmerplus-learning' ||
        result['offline_enabled'] != true ||
        result['activities'] is! List) {
      throw StateError(
        'Offline downloads are not enabled for this account and course. Existing downloads were kept.',
      );
    }
    return result;
  }

  Future<void> downloadSelected(
    int id,
    Map<String, dynamic> manifest,
    Set<int> selected,
  ) async {
    final owner = await store.setting('studentId');
    if (manifest['farmerplus_id'] != owner ||
        manifest['courseid'] != id ||
        manifest['tenant_id'] != 'farmerplus' ||
        manifest['instance_id'] != 'farmerplus-learning' ||
        manifest['offline_enabled'] != true) {
      throw StateError('Download account or policy changed.');
    }
    final items = (manifest['activities'] as List).cast<Map<String, dynamic>>();
    final eligible = items
        .where((m) => m['offline'] == true && m['format'] == 'text/plain')
        .map((m) => m['id'] as int)
        .toSet();
    if (selected.isEmpty || !eligible.containsAll(selected)) {
      throw StateError('Select at least one available offline lesson.');
    }
    final selectedBytes = items
        .where((m) => selected.contains(m['id']))
        .fold<int>(0, (total, m) => total + (m['bytes'] as int));
    if (selectedBytes > 25 * 1024 * 1024) {
      throw StateError(
        'Select fewer lessons: this text download is limited to 25 MB per batch.',
      );
    }
    final prior = await savedCourse(id);
    final old = <int, dynamic>{};
    if (prior != null &&
        prior['owner'] == owner &&
        (prior['tenant'] == null || prior['tenant'] == 'farmerplus') &&
        (prior['instance'] == null ||
            prior['instance'] == 'farmerplus-learning')) {
      for (final section in prior['sections'] ?? []) {
        for (final m in section['modules'] ?? []) {
          old[m['id']] = m;
        }
      }
    }
    final modules = <Map<String, dynamic>>[];
    for (final item in items) {
      final module = <String, dynamic>{
        'id': item['id'],
        'name': item['name'],
        'modname': item['type'],
        'url': item['launch_url'],
        'section': item['section'],
        'offlineReason': item['reason'],
      };
      // Keep unselected downloads, including their original version, until the
      // learner explicitly removes them. Never turn a partial update into deletion.
      if (old[item['id']]?['offlineText'] != null) {
        module['offlineText'] = old[item['id']]['offlineText'];
        module['offlineHash'] = old[item['id']]['offlineHash'];
      }
      if (selected.contains(item['id'])) {
        final content = await resource('text', item['id']);
        if (content['text'] is! String || content['cmid'] != item['id']) {
          throw StateError(
            'The lesson could not be verified. Previous downloads were kept.',
          );
        }
        final bytes = utf8.encode(content['text']);
        if (bytes.length > 2 * 1024 * 1024 ||
            bytes.length != item['bytes'] ||
            sha256.convert(bytes).toString() != item['sha256']) {
          throw StateError(
            'The lesson changed during download. Try again; previous downloads were kept.',
          );
        }
        module['offlineText'] = content['text'];
        module['offlineHash'] = item['sha256'];
      }
      modules.add(module);
    }
    for (final m in old.values) {
      if (m['offlineText'] != null && !modules.any((v) => v['id'] == m['id'])) {
        modules.add({
          ...Map<String, dynamic>.from(m),
          'archivedDownload': true,
        });
      }
    }
    if (await store.setting('studentId') != owner) {
      throw StateError('Account changed during download. Nothing replaced.');
    }
    final saved = modules.where((m) => m['offlineText'] != null).length;
    final data = {
      'id': id,
      'owner': owner,
      'tenant': 'farmerplus',
      'instance': 'farmerplus-learning',
      'manifestVersion': manifest['version'],
      'downloadedTexts': saved,
      'eligibleTexts': eligible.length,
      'onlineActivities': items.length - eligible.length,
      'sections': [
        {'name': 'Lessons', 'modules': modules},
      ],
      'updated': DateTime.now().toUtc().toIso8601String(),
    };
    // SQLite single-row replacement is atomic: failed batches never replace the prior copy.
    await store.setSetting(await downloadKey(id), data);
  }
}

Future<void> openStudentWebsite(
  BuildContext context,
  FarmStore store, [
  String? url,
]) async {
  final sync = SyncEngine(store);
  late Map<String, dynamic> config;
  try {
    config = await sync.oidcConfiguration();
  } finally {
    sync.client.close();
  }
  final origin = Uri.tryParse(config['learningUrl'] ?? '');
  if (origin == null ||
      origin.scheme != 'https' ||
      origin.userInfo.isNotEmpty ||
      origin.hasQuery ||
      origin.hasFragment ||
      origin.hasPort ||
      origin.path.isNotEmpty) {
    throw StateError('Learning is not configured for this account.');
  }
  final target = Uri.parse(
    url ?? '${origin.origin}/auth/farmerplusoidc/login.php',
  );
  if (target.origin != origin.origin ||
      target.path != '/auth/farmerplusoidc/login.php' ||
      target.hasFragment ||
      target.queryParameters.keys.any((k) => k != 'cmid') ||
      (target.queryParameters.containsKey('cmid') &&
          !RegExp(
            r'^[1-9][0-9]*$',
          ).hasMatch(target.queryParameters['cmid']!))) {
    throw StateError('This is not an approved Learning activity link.');
  }
  if (kIsWeb) {
    browserAssign(target.toString());
    return;
  }
  if (!context.mounted) return;
  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => LearningViewer(
        store: store,
        endpoint: Uri.parse('${origin.origin}/auth/farmerplusoidc/native.php'),
        cmid: int.tryParse(target.queryParameters['cmid'] ?? ''),
      ),
    ),
  );
}

class StudentPanel extends StatefulWidget {
  final FarmStore store;
  const StudentPanel({super.key, required this.store});
  @override
  State<StudentPanel> createState() => _StudentPanelState();
}

class _StudentPanelState extends State<StudentPanel>
    with WidgetsBindingObserver {
  late final api = StudentLearning(widget.store);
  Map<String, dynamic>? user, cache;
  bool busy = false, downloadedOnly = false;
  Map<int, Map<String, dynamic>> downloads = {};
  String? connectionNotice;
  String? provisioningNotice;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    CourseDownloads.of(widget.store).addListener(load);
    load();
    checkProvisioning();
  }

  @override
  void dispose() {
    CourseDownloads.of(widget.store).removeListener(load);
    WidgetsBinding.instance.removeObserver(this);
    api.client.close();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !busy) {
      run(api.refresh).catchError((_) {});
    }
  }

  Future<void> load() async {
    try {
      downloads = {
        for (final d in await CourseDownloads.of(widget.store).all())
          d['manifest']['courseid'] as int: d,
      };
    } catch (_) {}
    connectionNotice = await widget.store.setting('learningNotice');
    final u = await widget.store.setting('learningUser'),
        c = await widget.store.setting('learningCourses');
    if (mounted) {
      setState(() {
        user = u;
        cache = c;
      });
    }
  }

  Future<void> checkProvisioning() async {
    try {
      final state = await SyncEngine(
        widget.store,
        client: api.client,
      ).request('GET', '/learning/provisioning');
      if (!mounted) return;
      setState(
        () => provisioningNotice = switch (state['status']) {
          'pending' =>
            'Your Learning account is being connected. We will retry automatically if Learning is unavailable.',
          'needs_attention' =>
            'Your Learning account is taking longer to connect. Automatic retries are continuing; contact support if this persists.',
          _ => null,
        },
      );
    } catch (_) {
      // Saved lessons remain available during outages or on older deployments.
    }
  }

  Future<void> run(Future<void> Function() action) async {
    setState(() => busy = true);
    try {
      await action();
      await load();
      await checkProvisioning();
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext c) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: const Color(0xffeee2ff),
          borderRadius: BorderRadius.circular(22),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const AppArtwork(id: 'learning', size: 56),
            gap(12),
            Text(
              user == null
                  ? 'Your learning, connected.'
                  : 'Hello, ${user!['name']}',
              style: Theme.of(c).textTheme.titleLarge,
            ),
            gap(8),
            const Text('Your courses and official learning progress'),
          ],
        ),
      ),
      gap(),
      if (provisioningNotice != null) note(provisioningNotice!),
      if (user == null)
        note(
          connectionNotice ??
              'Your FarmerPlus account opens your courses. Connect when online to load them.',
        ),
      if (user == null)
        FilledButton.icon(
          onPressed: busy
              ? null
              : () => guarded(c, () => run(() => api.connect(c))),
          icon: const Icon(Icons.refresh),
          label: const Text('Open my courses'),
        ),
      if (user != null) ...[
        TextButton.icon(
          onPressed: busy
              ? null
              : () => guarded(c, () async {
                  await AccountAccess.lock();
                  if (c.mounted) Navigator.of(c).popUntil((r) => r.isFirst);
                }),
          icon: const Icon(Icons.login),
          label: const Text('Renew FarmerPlus sign-in · keep downloads'),
        ),
        Row(
          children: [
            Expanded(child: Text('Courses saved ${stamp(cache?['updated'])}')),
            IconButton(
              tooltip: 'Refresh courses',
              onPressed: busy ? null : () => guarded(c, () => run(api.refresh)),
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        Wrap(
          spacing: 8,
          children: [
            ChoiceChip(
              label: const Text('All courses'),
              selected: !downloadedOnly,
              onSelected: (_) => setState(() => downloadedOnly = false),
            ),
            ChoiceChip(
              label: const Text('Downloaded'),
              selected: downloadedOnly,
              onSelected: (_) => setState(() => downloadedOnly = true),
            ),
          ],
        ),
        for (final course in cache?['courses'] ?? [])
          if (!downloadedOnly ||
              (downloads[course['id']]?['installed'] as Map? ?? {}).isNotEmpty)
            Semantics(
              container: true,
              child: ListTile(
                contentPadding: const EdgeInsets.symmetric(vertical: 8),
                title: Text(course['fullname'] ?? 'Course'),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      downloads[course['id']] == null
                          ? 'Not downloaded'
                          : CourseDownloads.label(downloads[course['id']]!),
                    ),
                    Text(
                      course['progress'] == null
                          ? 'Official progress unavailable'
                          : 'Learning progress: ${(course['progress'] as num).toStringAsFixed(0)}%',
                    ),
                  ],
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => openPage(
                  c,
                  StudentCoursePage(
                    store: widget.store,
                    course: Map<String, dynamic>.from(course),
                  ),
                ),
              ),
            ),
        TextButton(
          onPressed: () async {
            await Navigator.of(c).push(
              MaterialPageRoute(
                builder: (_) => ManageCourseDownloadsPage(store: widget.store),
              ),
            );
            await load();
          },
          child: const Text('Manage downloads'),
        ),
      ],
      OutlinedButton.icon(
        onPressed: () => guarded(c, () => openStudentWebsite(c, widget.store)),
        icon: const Icon(Icons.open_in_new),
        label: const Text('Open my learning online'),
      ),
      note('Download progress and learning progress are shown separately.'),
    ],
  );
}

class StudentCoursePage extends StatefulWidget {
  final FarmStore store;
  final Map<String, dynamic> course;
  const StudentCoursePage({
    super.key,
    required this.store,
    required this.course,
  });
  @override
  State<StudentCoursePage> createState() => _StudentCoursePageState();
}

class _StudentCoursePageState extends State<StudentCoursePage> {
  late final api = StudentLearning(widget.store);
  Map<String, dynamic>? data;
  bool busy = true;
  String? error;
  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void dispose() {
    api.client.close();
    super.dispose();
  }

  Future<void> load() async {
    data =
        await CourseDownloads.of(
          widget.store,
        ).savedCourse(widget.course['id']) ??
        await api.savedCourse(widget.course['id']);
    if (data != null &&
        (data!['owner'] != await widget.store.setting('studentId') ||
            (data!['tenant'] != null && data!['tenant'] != 'farmerplus') ||
            (data!['instance'] != null &&
                data!['instance'] != 'farmerplus-learning'))) {
      data = null;
    }
    if (data == null) {
      try {
        data = await api.course(widget.course['id']);
      } catch (_) {
        error =
            'Connect to load this course. No downloaded lessons are available yet.';
      }
    }
    if (mounted) setState(() => busy = false);
  }

  Future<void> download() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => CourseDownloadPage(
          store: widget.store,
          courseId: widget.course['id'],
        ),
      ),
    );
    await load();
  }

  @override
  Widget build(BuildContext c) => PageFrame(
    'My course',
    children: [
      Text(
        widget.course['fullname'],
        style: Theme.of(c).textTheme.headlineMedium,
      ),
      gap(),
      FilledButton.icon(
        onPressed: busy ? null : () => guarded(c, download),
        icon: const Icon(Icons.download),
        label: Text(busy ? 'Loading…' : 'Download'),
      ),
      if (data?['downloadedTexts'] != null)
        note(
          '${data!['downloadedTexts']} text resource(s) saved ${stamp(data!['updated'])}. Images, audio, video and interactive content require the online activity.',
        ),
      if (error != null) note(error!),
      for (final section in data?['sections'] ?? []) ...[
        heading(c, lessonText(section['name'] ?? '')),
        for (final module in section['modules'] ?? [])
          ListTile(
            title: Text(lessonText(module['name'] ?? 'Activity')),
            subtitle: Text(
              module['offlineHtml'] != null
                  ? 'Downloaded · open now'
                  : module['offlineText'] != null
                  ? 'Text downloaded · read offline'
                  : 'Internet required',
            ),
            trailing: Icon(
              module['offlineHtml'] != null || module['offlineText'] != null
                  ? Icons.offline_pin
                  : Icons.open_in_new,
            ),
            onTap: () => module['offlineHtml'] != null
                ? openPage(
                    c,
                    OfflineReadingPage(
                      store: widget.store,
                      courseId: widget.course['id'],
                      resource: Map<String, dynamic>.from(
                        module['offlineHtml'],
                      ),
                    ),
                  )
                : module['offlineText'] != null
                ? openPage(
                    c,
                    PageFrame(
                      lessonText(module['name']),
                      showArtwork: false,
                      children: [
                        note(
                          'Offline text reading does not record official completion.',
                        ),
                        Semantics(
                          label: module['offlineText'],
                          child: ExcludeSemantics(
                            child: SelectableText(module['offlineText']),
                          ),
                        ),
                      ],
                    ),
                  )
                : guarded(
                    c,
                    () => openStudentWebsite(c, widget.store, module['url']),
                  ),
          ),
      ],
    ],
  );
}
