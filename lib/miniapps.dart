import 'package:flutter/foundation.dart';
import 'learning.dart';
import 'push.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:record/record.dart';
import 'package:audioplayers/audioplayers.dart';
import 'domain.dart';
import 'store.dart';
import 'services.dart';
import 'ui.dart';
import 'taxonomy.dart';
import 'farm_context.dart';
import 'backup.dart';
import 'sync.dart';
import 'home_panels.dart' show PendingSyncPage;
import 'remote_apps.dart';
import 'remote_app_ui.dart';

IconData appIcon(String id) => switch (id) {
  'diary' => Icons.edit_note,
  'calculator' => Icons.calculate_outlined,
  'planner' => Icons.event_note,
  _ => Icons.menu_book_outlined,
};
const sampleCourse = MiniManifest(
  'sample-records',
  'Useful farm records',
  'Original sample lessons.',
  'Learning',
  {'progress'},
  {'progress'},
);

class AppStorePage extends StatefulWidget {
  final FarmStore store;
  final void Function(String) onOpen;
  const AppStorePage({super.key, required this.store, required this.onOpen});
  @override
  State<AppStorePage> createState() => _AppStorePageState();
}

class _AppStorePageState extends State<AppStorePage> {
  String category = 'All';
  bool free = false, offline = false;
  List<String> suggestions = [];
  String? farmName;
  List<MiniManifest> storeApps = catalogue;
  String? catalogueError;
  @override
  void initState() {
    super.initState();
    loadSuggestions();
  }

  Future<void> loadSuggestions() async {
    try {
      final remote = await RemoteApps.of(
        widget.store,
      ).available(refresh: kIsWeb);
      storeApps = {
        ...{for (final a in catalogue) a.id: a},
        ...{for (final a in remote) a.id: a},
      }.values.toList();
    } catch (_) {
      final cached = await RemoteApps.of(widget.store).available();
      storeApps = {
        ...{for (final a in catalogue) a.id: a},
        ...{for (final a in cached) a.id: a},
      }.values.toList();
      catalogueError = 'Showing saved apps. Connect to check new releases.';
    }
    final id = await widget.store.setting('selectedFarm');
    final farms = await widget.store.records('farm');
    final farm =
        farms.where((f) => f['id'] == id).firstOrNull ?? farms.firstOrNull;
    if (mounted) {
      setState(() {
        farmName = farm?['data']['name'];
        suggestions = suggestedApps(farm?['data']['productionCategory']);
      });
    }
  }

  @override
  Widget build(BuildContext c) => PageFrame(
    'App Store',
    children: [
      Text.rich(
        TextSpan(
          children: [
            const TextSpan(text: 'Useful tools.\n'),
            TextSpan(
              text: 'Ready when you are.',
              style: TextStyle(color: Theme.of(c).colorScheme.primary),
            ),
          ],
        ),
        style: Theme.of(
          c,
        ).textTheme.headlineMedium?.copyWith(fontSize: 32, height: 1.12),
      ),
      gap(24),
      if (farmName != null)
        note(
          'Suggested for $farmName: ${catalogue.where((a) => suggestions.contains(a.id)).map((a) => a.title).join(', ')}.',
        ),
      Wrap(
        spacing: 8,
        children: [
          FilterChip(
            avatar: const Icon(Icons.sell_outlined, size: 18),
            label: const Text('Free'),
            selected: free,
            onSelected: (v) => setState(() => free = v),
          ),
          FilterChip(
            avatar: const Icon(Icons.wifi_off_rounded, size: 18),
            label: const Text('Works offline'),
            selected: offline,
            onSelected: (v) => setState(() => offline = v),
          ),
        ],
      ),
      gap(),
      DropdownButtonFormField<String>(
        initialValue: category,
        decoration: const InputDecoration(
          labelText: 'Category',
          prefixIcon: Icon(Icons.grid_view_rounded),
        ),
        items: [
          'All',
          'Records',
          'Tools',
          'Planning',
          'Learning',
        ].map((s) => DropdownMenuItem(value: s, child: Text(s))).toList(),
        onChanged: (v) => setState(() => category = v!),
      ),
      gap(),
      if (catalogueError != null) note(catalogueError!),
      for (final app in storeApps.where(
        (a) =>
            !protectedApps.contains(a.id) &&
            (category == 'All' || a.category == category),
      ))
        SurfaceCard(
          child: InkWell(
            onTap: () => openPage(
              c,
              InstallPage(
                store: widget.store,
                app: app,
                onOpen: () => widget.onOpen(app.id),
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AppArtwork(id: app.id, size: 48),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          app.title,
                          style: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        gap(4),
                        Text(
                          app.description,
                          style: const TextStyle(
                            color: Color(0xff566780),
                            height: 1.4,
                          ),
                        ),
                        gap(12),
                        const Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: [
                            AppBadge('Free', Icons.sell_outlined, accent: true),
                            AppBadge('Works offline', Icons.wifi_off_rounded),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 6),
                  const Padding(
                    padding: EdgeInsets.only(top: 12),
                    child: Icon(Icons.chevron_right_rounded),
                  ),
                ],
              ),
            ),
          ),
        ),
    ],
  );
}

class InstallPage extends StatefulWidget {
  final FarmStore store;
  final MiniManifest app;
  final VoidCallback onOpen;
  final bool course;
  const InstallPage({
    super.key,
    required this.store,
    required this.app,
    required this.onOpen,
    this.course = false,
  });
  @override
  State<InstallPage> createState() => _InstallPageState();
}

class _InstallPageState extends State<InstallPage> {
  int size = 0, bytes = 0;
  bool ready = false, busy = false, cancel = false;
  String? error;
  @override
  void initState() {
    super.initState();
    widget.store.addListener(load);
    if (!widget.app.remote) load();
  }

  @override
  void dispose() {
    cancel = true;
    widget.store.removeListener(load);
    super.dispose();
  }

  Future<void> load() async {
    if (widget.app.remote) return;
    final asset = await rootBundle.load('assets/packs/${widget.app.id}.json');
    final isReady = await widget.store.ready(widget.app.id);
    final rows = await widget.store.installations();
    final row = rows.where((r) => r['id'] == widget.app.id).firstOrNull;
    if (mounted) {
      setState(() {
        size = asset.lengthInBytes;
        ready = isReady;
        bytes = row?['bytes'] as int? ?? 0;
      });
    }
  }

  Future<void> install() async {
    setState(() {
      busy = true;
      cancel = false;
      error = null;
    });
    try {
      await widget.store.install(widget.app, cancelled: () => cancel);
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
    await load();
  }

  @override
  Widget build(BuildContext c) => widget.app.remote
      ? RemoteInstallPage(
          store: widget.store,
          app: widget.app,
          onOpen: widget.onOpen,
        )
      : PageFrame(
          widget.app.title,
          children: [
            Icon(
              widget.course ? Icons.menu_book_outlined : appIcon(widget.app.id),
              size: 56,
            ),
            gap(20),
            Text(
              widget.app.description,
              style: Theme.of(c).textTheme.headlineSmall,
            ),
            heading(c, 'Included by FarmerPlus'),
            Text(
              'Free • Version ${widget.app.version}\n${size.toString()} bytes of content • CC0 sample material',
            ),
            note(
              widget.course
                  ? 'Sample course. No production connection or official credential. Download this content separately from the Learning client.'
                  : 'This curated app runs inside FarmerPlus. Its content is bundled, so adding it does not need internet.',
            ),
            heading(c, 'Works offline'),
            Text(
              widget.app.id == 'learning'
                  ? 'Browse downloaded courses, read supported lessons and save progress. Download each course separately. New enrolments, grading and server messages need a connection.'
                  : widget.app.id == 'diary'
                  ? 'Create field records, take photos and record voice notes. Voice recordings are not automatically transcribed.'
                  : 'All included text and calculations work offline. New provider content requires a connection.',
            ),
            heading(c, 'Data permissions'),
            Text(
              'Read: ${widget.app.read.isEmpty ? 'none' : widget.app.read.join(', ')}\nWrite: ${widget.app.write.isEmpty ? 'none' : widget.app.write.join(', ')}\nNo access to wallet keys or payment submission.',
            ),
            gap(24),
            if (busy) ...[
              LinearProgressIndicator(value: size == 0 ? null : bytes / size),
              gap(8),
              Text('$bytes / $size bytes saved'),
              TextButton(
                onPressed: () => setState(() => cancel = true),
                child: const Text('Pause'),
              ),
            ] else if (ready) ...[
              note(
                'Ready offline • content integrity verified',
                icon: Icons.offline_pin_outlined,
              ),
              FilledButton(
                onPressed: widget.onOpen,
                child: Text(widget.course ? 'Open course' : 'Open app'),
              ),
              if (!protectedApps.contains(widget.app.id))
                TextButton(
                  onPressed: () => guarded(c, () async {
                    if (await confirmAppRemoval(
                      c,
                      widget.store,
                      widget.app.id,
                      widget.app.title,
                    )) {
                      await load();
                    }
                  }),
                  child: Text(
                    widget.course
                        ? 'Remove download • keep progress'
                        : 'Remove app and local information',
                  ),
                ),
            ] else
              FilledButton.icon(
                onPressed: install,
                icon: const Icon(Icons.download),
                label: Text(
                  bytes > 0
                      ? 'Resume / retry'
                      : widget.course
                      ? 'Download course'
                      : 'Add app',
                ),
              ),
            if (error != null) note(error!, icon: Icons.error_outline),
          ],
        );
}

class RecordsPage extends StatefulWidget {
  final FarmStore store;
  final Reminders reminders;
  final String kind;
  final String? focusId;
  const RecordsPage({
    super.key,
    required this.store,
    required this.reminders,
    required this.kind,
    this.focusId,
  });
  @override
  State<RecordsPage> createState() => _RecordsPageState();
}

class _RecordsPageState extends State<RecordsPage> {
  List<Map<String, dynamic>> rows = [];
  bool focused = false;
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
    final data = await widget.store.records(
      widget.kind,
      scope: catalogue.firstWhere(
        (a) => a.id == (widget.kind == 'task' ? 'planner' : 'diary'),
      ),
    );
    if (mounted) {
      setState(() => rows = data);
      if (!focused && widget.focusId != null) {
        focused = true;
        final r = rows.where((r) => r['id'] == widget.focusId).firstOrNull;
        if (r != null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) edit(r);
          });
        }
      }
    }
  }

  void edit([Map<String, dynamic>? r]) => openPage(
    context,
    RecordEditor(
      store: widget.store,
      reminders: widget.reminders,
      kind: widget.kind,
      record: r,
    ),
  );
  @override
  Widget build(BuildContext c) => PageFrame(
    widget.kind == 'task' ? 'My Planner' : 'Farm Diary',
    children: [
      Text(
        widget.kind == 'task' ? 'What comes next?' : 'Your farm, day by day.',
        style: Theme.of(c).textTheme.headlineMedium,
      ),
      gap(12),
      Text(
        widget.kind == 'task'
            ? 'Make your own plan. Keep each activity linked to its field.'
            : 'Record what happened, where and when. Every entry saves on this phone.',
      ),
      gap(24),
      FilledButton.icon(
        onPressed: () => edit(),
        icon: const Icon(Icons.add),
        label: Text(
          widget.kind == 'task' ? 'Plan an activity' : 'Add a diary entry',
        ),
      ),
      gap(20),
      if (rows.isEmpty)
        note(
          widget.kind == 'task'
              ? 'No activities yet. Add your first plan.'
              : 'No entries yet. Your first record starts here.',
        ),
      for (final r in rows)
        ListTile(
          leading: Icon(
            widget.kind == 'task'
                ? (r['data']['completed'] == true
                      ? Icons.check_circle_outline
                      : Icons.event_outlined)
                : Icons.edit_note,
          ),
          title: Text(r['data']['title'] ?? 'Untitled draft'),
          subtitle: Text(
            '${stamp(r['data']['date'])}${r['data']['fieldName'] == null ? '' : ' • ${r['data']['fieldName']}'}\n${r['data']['notes'] ?? ''}',
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => edit(r),
        ),
    ],
  );
}

class RecordEditor extends StatefulWidget {
  final FarmStore store;
  final Reminders reminders;
  final String kind;
  final String? initialFarmId, initialAreaId;
  final Map<String, dynamic>? record;
  const RecordEditor({
    super.key,
    required this.store,
    required this.reminders,
    required this.kind,
    this.record,
    this.initialFarmId,
    this.initialAreaId,
  });
  @override
  State<RecordEditor> createState() => _RecordEditorState();
}

class _RecordEditorState extends State<RecordEditor> {
  final title = TextEditingController(), notes = TextEditingController();
  final recorder = AudioRecorder(), player = AudioPlayer();
  List<Map<String, dynamic>> media = [], fields = [];
  String? field, farm;
  late String id;
  DateTime date = DateTime.now();
  bool completed = false, remind = false, recording = false, loaded = false;
  String? message;
  String get draftKey =>
      'entryDraft:${widget.kind}:${widget.record?['id'] ?? '${widget.initialFarmId}:${widget.initialAreaId}:new'}';
  @override
  void initState() {
    super.initState();
    id = widget.record?['id'] ?? uuid.v4();
    load();
  }

  Future<void> load() async {
    final data =
        await widget.store.setting(draftKey) ?? widget.record?['data'] ?? {};
    title.text = data['title'] ?? '';
    notes.text = data['notes'] ?? '';
    field = data['fieldId'] ?? widget.initialAreaId;
    farm = data['farmId'] ?? widget.initialFarmId;
    date = DateTime.tryParse(data['date'] ?? '') ?? DateTime.now();
    completed = data['completed'] ?? false;
    remind = data['remind'] ?? false;
    media = List<Map<String, dynamic>>.from(data['media'] ?? []);
    fields = await widget.store.records('field');
    farm ??= fields
        .where((r) => r['id'] == field)
        .firstOrNull?['data']['farmId'];
    if (mounted) setState(() => loaded = true);
  }

  @override
  void dispose() {
    title.dispose();
    notes.dispose();
    recorder.dispose();
    player.dispose();
    super.dispose();
  }

  Map<String, dynamic> data() => {
    'title': title.text.trim(),
    'notes': notes.text,
    'date': date.toUtc().toIso8601String(),
    'fieldId': field,
    'farmId': farm,
    'contextScope': field != null
        ? 'area'
        : farm != null
        ? 'farm'
        : 'general',
    'fieldName': fields
        .where((f) => f['id'] == field)
        .firstOrNull?['data']['name'],
    'completed': completed,
    'remind': remind,
    'media': media,
  };
  Future<void> draft() => widget.store.setSetting(draftKey, data());
  Future<void> photo() async {
    final image = await ImagePicker().pickImage(
      source: kIsWeb ? ImageSource.gallery : ImageSource.camera,
      imageQuality: 85,
    );
    if (image == null) return;
    final hash = await widget.store.keepMedia(image.path);
    setState(
      () => media.add({'hash': hash, 'type': 'image/jpeg', 'name': 'Photo'}),
    );
    await draft();
  }

  Future<void> voice() async {
    if (kIsWeb) {
      throw StateError(
        'Voice recording requires the Android app; text diary entries work in the browser.',
      );
    }
    if (recording) {
      final file = await recorder.stop();
      setState(() => recording = false);
      if (file != null) {
        final hash = await widget.store.keepMedia(file);
        setState(
          () => media.add({
            'hash': hash,
            'type': 'audio/mp4',
            'name': 'Voice note',
          }),
        );
        await draft();
      }
      return;
    }
    if (!await recorder.hasPermission()) {
      throw StateError('Allow microphone access to record a voice note.');
    }
    await recorder.start(
      const RecordConfig(),
      path: '${widget.store.filesPath}/voice-draft.m4a',
    );
    setState(() => recording = true);
  }

  Future<void> pickDate() async {
    final day = await showDatePicker(
      context: context,
      initialDate: date,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (day == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(date),
    );
    if (time == null) return;
    setState(
      () =>
          date = DateTime(day.year, day.month, day.day, time.hour, time.minute),
    );
    await draft();
  }

  Future<void> save() async {
    if (recording) throw StateError('Stop the recording before saving.');
    if (title.text.trim().isEmpty) {
      throw StateError('Add an activity title first.');
    }
    final scope = catalogue.firstWhere(
      (a) => a.id == (widget.kind == 'task' ? 'planner' : 'diary'),
    );
    await widget.store.save(widget.kind, data(), id: id, scope: scope);
    await widget.store.setSetting(draftKey, null);
    if (widget.kind == 'task') {
      await widget.reminders.cancel(id);
      bool scheduled = false;
      if (remind &&
          !completed &&
          await widget.store.setting('reminders') != false) {
        scheduled = await widget.reminders.schedule(id, title.text, date);
      }
      final inboxId = uuid.v5(
        '6ba7b811-9dad-11d1-80b4-00c04fd430c8',
        'planner:$id',
      );
      await widget.store.save('inbox', {
        'source': 'My Planner',
        'title': title.text,
        'action': 'Open activity',
        'priority': 'normal',
        'route': 'task:$id',
        'read': false,
        'completed': completed,
        'due': date.toUtc().toIso8601String(),
      }, id: inboxId);
      if (remind && !completed && !scheduled) {
        if (mounted) {
          setState(
            () => message =
                'Activity saved. Device reminder was not scheduled; check notification permission, reminder settings and the activity time.',
          );
        }
        return;
      }
    }
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext c) => PageFrame(
    widget.kind == 'task' ? 'Plan activity' : 'Diary entry',
    children: [
      if (!loaded)
        const LinearProgressIndicator()
      else ...[
        TextField(
          controller: title,
          onChanged: (_) => draft(),
          decoration: const InputDecoration(labelText: 'Activity title'),
        ),
        gap(),
        FarmContextPicker(
          store: widget.store,
          farmId: farm,
          areaId: field,
          onChanged: (f, a) {
            setState(() {
              farm = f;
              field = a;
            });
            draft();
          },
        ),
        gap(),
        OutlinedButton.icon(
          onPressed: pickDate,
          icon: const Icon(Icons.calendar_today_outlined),
          label: Text(stamp(date.toIso8601String())),
        ),
        gap(),
        TextField(
          controller: notes,
          minLines: 4,
          maxLines: 10,
          onChanged: (_) => draft(),
          decoration: const InputDecoration(
            labelText: 'Notes, quantities and observations',
          ),
        ),
        if (widget.kind == 'task') ...[
          SwitchListTile(
            title: const Text('Remind me on this phone'),
            subtitle: const Text(
              'Android may deliver reminders later to save battery.',
            ),
            value: remind,
            onChanged: (v) {
              setState(() => remind = v);
              draft();
            },
          ),
          CheckboxListTile(
            title: const Text('Activity completed'),
            value: completed,
            onChanged: (v) {
              setState(() => completed = v!);
              draft();
            },
          ),
        ] else ...[
          gap(),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: () => guarded(c, photo),
                icon: const Icon(Icons.camera_alt_outlined),
                label: Text(kIsWeb ? 'Add photo' : 'Take photo'),
              ),
              OutlinedButton.icon(
                onPressed: () => guarded(c, voice),
                icon: Icon(recording ? Icons.stop : Icons.mic_none),
                label: Text(recording ? 'Stop recording' : 'Voice note'),
              ),
            ],
          ),
          if (recording)
            note('Recording on this phone… No automatic transcription.'),
          for (final m in media)
            ListTile(
              leading: Icon(
                m['type'].startsWith('image')
                    ? Icons.image_outlined
                    : Icons.play_circle_outline,
              ),
              title: Text(m['name']),
              onTap: () => guarded(c, () async {
                final bytes = await widget.store.mediaBytes(m['hash']);
                if (bytes == null) {
                  throw StateError(
                    'Attachment has not downloaded yet. Try sync.',
                  );
                }
                if (m['type'].startsWith('image')) {
                  if (c.mounted) {
                    openPage(
                      c,
                      PageFrame('Photo', children: [Image.memory(bytes)]),
                    );
                  }
                } else {
                  await player.play(BytesSource(bytes, mimeType: m['type']));
                }
              }),
              trailing: IconButton(
                tooltip: 'Remove attachment from entry',
                onPressed: () {
                  setState(() => media.remove(m));
                  draft();
                },
                icon: const Icon(Icons.close),
              ),
            ),
        ],
        if (message != null) note(message!),
        gap(),
        FilledButton(
          onPressed: () => guarded(c, save),
          child: const Text('Save on this phone'),
        ),
        note('Unfinished entries are kept as local drafts.'),
        if (widget.record != null)
          TextButton(
            onPressed: () => guarded(c, () async {
              final ok = await showDialog<bool>(
                context: c,
                builder: (d) => AlertDialog(
                  title: const Text('Delete this record?'),
                  content: const Text(
                    'The deletion will sync when you reconnect. Other records are kept.',
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(d, false),
                      child: const Text('Keep'),
                    ),
                    TextButton(
                      onPressed: () => Navigator.pop(d, true),
                      child: const Text('Delete'),
                    ),
                  ],
                ),
              );
              if (ok != true) return;
              await widget.store.save(
                widget.kind,
                data(),
                id: id,
                deleted: true,
              );
              await widget.reminders.cancel(id);
              await widget.store.setSetting(draftKey, null);
              if (c.mounted) Navigator.pop(c);
            }),
            child: const Text('Delete record'),
          ),
      ],
    ],
  );
}

class CalculatorPage extends StatefulWidget {
  final FarmStore? store;
  final String? initialFarmId, initialAreaId;
  const CalculatorPage({
    super.key,
    this.store,
    this.initialFarmId,
    this.initialAreaId,
  });
  @override
  State<CalculatorPage> createState() => _CalculatorPageState();
}

class _CalculatorPageState extends State<CalculatorPage> {
  String tool = 'Plant count';
  final a = TextEditingController(),
      b = TextEditingController(),
      d = TextEditingController();
  String result = '';
  String? farm, areaId;
  Map<String, dynamic> snapshot = {
    'source': 'Entered manually',
    'areaM2': null,
  };
  Map<String, dynamic>? calculated;
  @override
  void initState() {
    super.initState();
    farm = widget.initialFarmId;
    areaId = widget.initialAreaId;
  }

  Future<void> useArea() async {
    final record = (areaId ?? farm) == null
        ? null
        : await widget.store?.get((areaId ?? farm)!);
    final value = areaSnapshot(record);
    if (value['areaM2'] == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No area recorded. Enter an area manually.'),
          ),
        );
      }
      return;
    }
    setState(() {
      snapshot = value;
      a.text = (value['areaM2'] as num).toStringAsFixed(2);
      result = '';
      calculated = null;
    });
  }

  Future<void> saveCalculation() async {
    if (widget.store == null || calculated == null) return;
    await guarded(context, () async {
      await widget.store!.save('calculation', calculated!);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Calculation snapshot saved.')),
        );
      }
    });
  }

  @override
  void dispose() {
    a.dispose();
    b.dispose();
    d.dispose();
    super.dispose();
  }

  void calculate() {
    calculated = null;
    try {
      final x = double.parse(a.text),
          y = double.tryParse(b.text) ?? 0,
          z = double.tryParse(d.text) ?? 0;
      if (!x.isFinite || x < 0 || !y.isFinite || !z.isFinite) {
        throw ArgumentError();
      }
      setState(
        () => result = switch (tool) {
          'Plant count' => '${plantCount(x, y, z)} plants (rounded down)',
          'Hectares to m²' => '${(x * 10000).toStringAsFixed(2)} m²',
          'm² to hectares' => '${(x / 10000).toStringAsFixed(4)} ha',
          'Kilograms to tonnes' => '${(x / 1000).toStringAsFixed(3)} tonnes',
          'Tonnes to kilograms' => '${(x * 1000).toStringAsFixed(2)} kg',
          _ =>
            y < 0
                ? throw ArgumentError()
                : '${(x * y).toStringAsFixed(2)} in your entered price currency',
        },
      );
      calculated = {
        'title': tool,
        'result': result,
        'farmId': farm,
        'fieldId': areaId,
        'date': DateTime.now().toUtc().toIso8601String(),
        'inputs': {'a': x, 'b': y, 'd': z},
        'areaSnapshot': {
          ...snapshot,
          'areaM2': tool == 'Plant count' ? x : null,
        },
      };
    } catch (_) {
      setState(
        () => result =
            'Enter valid non-negative quantities. Plant spacing must be greater than zero.',
      );
    }
  }

  @override
  Widget build(BuildContext c) => PageFrame(
    'Farm Calculator',
    children: [
      Text(
        'Start with your numbers.',
        style: Theme.of(c).textTheme.headlineMedium,
      ),
      note(
        'These are arithmetic estimates. Plant counts do not account for paths, edges or unsuitable ground.',
      ),
      DropdownButtonFormField(
        initialValue: tool,
        decoration: const InputDecoration(labelText: 'Calculation'),
        items: [
          'Plant count',
          'Hectares to m²',
          'm² to hectares',
          'Kilograms to tonnes',
          'Tonnes to kilograms',
          'Quantity × unit price',
        ].map((v) => DropdownMenuItem(value: v, child: Text(v))).toList(),
        onChanged: (v) => setState(() {
          tool = v!;
          result = '';
        }),
      ),
      gap(),
      if (widget.store != null) ...[
        FarmContextPicker(
          store: widget.store!,
          farmId: farm,
          areaId: areaId,
          onChanged: (f, r) => setState(() {
            farm = f;
            areaId = r;
            result = '';
            calculated = null;
            snapshot = {'source': 'Entered manually', 'areaM2': null};
          }),
        ),
        if (tool == 'Plant count')
          TextButton.icon(
            onPressed: useArea,
            icon: const Icon(Icons.area_chart_outlined),
            label: const Text('Use recorded area'),
          ),
        Text('Area source: ${snapshot['source']}'),
        gap(),
      ],
      TextField(
        onChanged: (_) => setState(() {
          snapshot = {'source': 'Entered manually', 'areaM2': null};
          result = '';
          calculated = null;
        }),
        controller: a,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(
          labelText: tool == 'Plant count'
              ? 'Usable planting area (m²)'
              : tool == 'Quantity × unit price'
              ? 'Quantity'
              : 'Value in ${tool.split(' to ').first.toLowerCase()}',
        ),
      ),
      if (tool == 'Plant count' || tool == 'Quantity × unit price') ...[
        gap(),
        TextField(
          controller: b,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(
            labelText: tool == 'Plant count'
                ? 'Row spacing (metres)'
                : 'Price per unit',
          ),
        ),
      ],
      if (tool == 'Plant count') ...[
        gap(),
        TextField(
          controller: d,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(
            labelText: 'Plant spacing within row (metres)',
          ),
        ),
      ],
      gap(24),
      FilledButton(onPressed: calculate, child: const Text('Calculate')),
      if (calculated != null && widget.store != null)
        OutlinedButton(
          onPressed: saveCalculation,
          child: const Text('Save calculation'),
        ),
      gap(24),
      Semantics(
        liveRegion: true,
        child: Text(result, style: Theme.of(c).textTheme.headlineSmall),
      ),
    ],
  );
}

class LearningPage extends StatelessWidget {
  final FarmStore store;
  const LearningPage({super.key, required this.store});
  @override
  Widget build(BuildContext c) => PageFrame(
    'Learning',
    children: [
      StudentPanel(store: store),
      heading(c, 'Offline practice'),
      ListTile(
        leading: const Icon(Icons.menu_book_outlined),
        title: const Text('Useful farm records'),
        subtitle: const Text(
          'Sample course • 2 lessons and a quick check\nFree • text and quiz work offline',
        ),
        isThreeLine: true,
        trailing: const Icon(Icons.chevron_right),
        onTap: () => openPage(
          c,
          InstallPage(
            store: store,
            app: sampleCourse,
            course: true,
            onOpen: () => openPage(c, CoursePage(store: store)),
          ),
        ),
      ),
      heading(c, 'Your progress'),
      const Text(
        'Downloaded lessons save progress on this phone. A sample quiz does not award a qualification or official course completion.',
      ),
    ],
  );
}

class CoursePage extends StatefulWidget {
  final FarmStore store;
  final int? initialLesson;
  const CoursePage({super.key, required this.store, this.initialLesson});
  @override
  State<CoursePage> createState() => _CoursePageState();
}

class _CoursePageState extends State<CoursePage> {
  Map<String, dynamic>? content;
  String? loadError;
  bool loading = true;
  bool linkedLessonOpened = false;
  Map<String, dynamic> progress = {};
  late String id;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    if (mounted) {
      setState(() {
        loading = true;
        loadError = null;
        content = null;
      });
    }
    try {
      id = uuid.v5(
        '6ba7b811-9dad-11d1-80b4-00c04fd430c8',
        '${await widget.store.setting('farmerId')}:sample-records:1',
      );
      final data = await widget.store.content(sampleCourse.id);
      final saved = await widget.store.get(id);
      if (mounted) {
        setState(() {
          content = data;
          loading = false;
          progress = saved?['data'] ?? {};
        });
        final index = widget.initialLesson;
        if (!linkedLessonOpened &&
            index != null &&
            index >= 0 &&
            index < (data['lessons'] as List).length) {
          linkedLessonOpened = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) openLesson(index);
          });
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          loading = false;
          loadError = e.toString().replaceFirst('Bad state: ', '');
        });
      }
    }
  }

  Future<void> save(Map<String, dynamic> change) async {
    progress = {
      ...progress,
      ...change,
      'courseId': 'sample-records',
      'contentVersion': 1,
      'sample': true,
      'authority': 'local-practice',
    };
    await widget.store.save(
      'progress',
      progress,
      id: id,
      scope: catalogue.last,
    );
    if (mounted) setState(() {});
  }

  void openLesson(int index) {
    final lesson = content!['lessons'][index];
    openPage(
      context,
      PageFrame(
        lesson['title'],
        children: [
          Text(lesson['body'], style: Theme.of(context).textTheme.bodyLarge),
          gap(32),
          FilledButton(
            onPressed: () => guarded(context, () async {
              await save({
                'lessons': {
                  ...List<int>.from(progress['lessons'] ?? []),
                  index,
                }.toList(),
              });
              if (mounted) Navigator.pop(context);
            }),
            child: const Text('Mark as read'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext c) {
    final lessons = content?['lessons'] as List? ?? [];
    final completed = List<int>.from(progress['lessons'] ?? []);
    return PageFrame(
      'Useful farm records',
      children: [
        if (loading) ...[
          const LinearProgressIndicator(),
          note('Checking downloaded course content…'),
        ] else if (loadError != null) ...[
          note(loadError!, icon: Icons.error_outline),
          FilledButton(
            onPressed: load,
            child: const Text('Retry opening course'),
          ),
          gap(),
          OutlinedButton(
            onPressed: () => openPage(
              c,
              InstallPage(
                store: widget.store,
                app: sampleCourse,
                course: true,
                onOpen: () {
                  Navigator.pop(c);
                  load();
                },
              ),
            ),
            child: const Text('Check / download course'),
          ),
        ] else
          note(
            'Sample course • Ready offline\n${completed.length} of ${lessons.length} lessons read. Progress is saved locally.',
          ),
        for (var i = 0; i < lessons.length; i++)
          ListTile(
            leading: Icon(
              completed.contains(i)
                  ? Icons.check_circle_outline
                  : Icons.menu_book_outlined,
            ),
            title: Text(lessons[i]['title']),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => openPage(
              c,
              PageFrame(
                lessons[i]['title'],
                children: [
                  Text(
                    lessons[i]['body'],
                    style: Theme.of(c).textTheme.bodyLarge,
                  ),
                  gap(32),
                  FilledButton(
                    onPressed: () => guarded(c, () async {
                      await save({
                        'lessons': {...completed, i}.toList(),
                      });
                      if (c.mounted) Navigator.pop(c);
                    }),
                    child: const Text('Mark as read'),
                  ),
                ],
              ),
            ),
          ),
        if (content != null) ...[
          heading(c, 'Quick check'),
          Text(content!['quiz']['question']),
          gap(),
          for (var i = 0; i < (content!['quiz']['answers'] as List).length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: OutlinedButton(
                onPressed: () => guarded(
                  c,
                  () => save({
                    'quizAnswer': i,
                    'quizCorrect': i == content!['quiz']['correct'],
                  }),
                ),
                child: Text(content!['quiz']['answers'][i]),
              ),
            ),
          if (progress['quizAnswer'] != null)
            note(
              progress['quizCorrect'] == true
                  ? 'That record includes the field, date, quantity and unit. Practice result saved.'
                  : 'Try again. Look for a field, date, quantity and unit.',
            ),
          note('This is practice, not an official grade or credential.'),
        ],
      ],
    );
  }
}

class InboxPage extends StatefulWidget {
  final FarmStore store;
  final Reminders reminders;
  const InboxPage({super.key, required this.store, required this.reminders});
  @override
  State<InboxPage> createState() => _InboxPageState();
}

class _InboxPageState extends State<InboxPage> {
  List<Map<String, dynamic>> rows = [];
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
    final r = await widget.store.records('inbox');
    final push =
        await PushService.of(widget.store)?.cached() ??
        <Map<String, dynamic>>[];
    final covered = push
        .map((p) => (p['event_key'] ?? '').toString().split(':').last)
        .toSet();
    if (mounted) {
      setState(
        () => rows = r.where((row) => !covered.contains(row['id'])).toList(),
      );
    }
  }

  @override
  Widget build(BuildContext c) => PageFrame(
    'Inbox',
    children: [
      if (PushService.of(widget.store) case final service?)
        PushInboxSection(service: service),
      Text(
        'One place to keep up.',
        style: Theme.of(c).textTheme.headlineMedium,
      ),
      note(
        'Your activity reminders appear here. New provider messages arrive after you connect.',
      ),
      if (rows.isEmpty)
        note(
          'You are all caught up. Plan an activity to add your first reminder.',
          icon: Icons.mark_email_read_outlined,
        ),
      for (final r in rows)
        ListTile(
          leading: Icon(
            r['data']['completed'] == true
                ? Icons.check_circle_outline
                : r['data']['read'] == true
                ? Icons.drafts_outlined
                : Icons.mail_outline,
          ),
          title: Text(r['data']['title'] ?? 'Message'),
          subtitle: Text(
            '${r['data']['source']} • ${r['data']['priority'] ?? 'normal'}\n${r['data']['action'] ?? 'Open'}',
          ),
          trailing: IconButton(
            tooltip: 'Mark message completed',
            icon: const Icon(Icons.done),
            onPressed: () => widget.store.save('inbox', {
              ...r['data'],
              'completed': true,
              'read': true,
            }, id: r['id']),
          ),
          onTap: () => guarded(c, () async {
            await widget.store.save('inbox', {
              ...r['data'],
              'read': true,
            }, id: r['id']);
            final route = (r['data']['route'] ?? '').toString();
            if (!c.mounted) return;
            if (route.startsWith('task:')) {
              openPage(
                c,
                RecordsPage(
                  store: widget.store,
                  reminders: widget.reminders,
                  kind: 'task',
                  focusId: route.substring(5),
                ),
              );
            } else if (route.startsWith('learning:')) {
              final parts = route.split(':');
              if (parts.length >= 3 &&
                  parts[1] == 'sample-records' &&
                  await widget.store.ready('learning') &&
                  await widget.store.ready('sample-records')) {
                if (c.mounted) {
                  openPage(
                    c,
                    CoursePage(
                      store: widget.store,
                      initialLesson: int.tryParse(parts[2]),
                    ),
                  );
                }
              } else if (c.mounted) {
                openPage(c, LearningPage(store: widget.store));
              }
            } else {
              throw StateError(
                'This message has no supported destination yet.',
              );
            }
          }),
        ),
    ],
  );
}

Future<bool> confirmAppRemoval(
  BuildContext context,
  FarmStore store,
  String id,
  String title,
) async {
  if (await store.setting('miniapp:manifest:$id') != null) {
    if (!context.mounted) return false;
    final agreed = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Remove $title?'),
        content: const Text(
          'Remove the downloaded app from this device. Your records, photos and pending changes will be kept for reinstalling.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Keep app'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Remove app'),
          ),
        ],
      ),
    );
    if (agreed != true) return false;
    await RemoteApps.of(store).remove(id);
    return true;
  }
  if (protectedApps.contains(id)) return false;
  final info = await store.removalSummary(id);
  final unsynced = info['unsynced'] ?? 0;
  if (!context.mounted) return false;
  final agreed = await showDialog<String>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text('Remove $title?'),
      content: Text(
        id == 'coop'
            ? 'Cooperative sharing will be set to No. Future sharing stops on the server once this change syncs; offline changes remain pending until you reconnect. Removing Coop does not end memberships or erase previously shared information. Reinstalling requires you to approve sharing with each cooperative again.'
            : 'This removes $title and its offline downloads from this phone.\n\n${info['records']} local records · $unsynced unsynced changes\n\n${unsynced > 0 ? 'Sync or export your pending work before removing it. Removing now will lose those unsynced changes.\n\n' : ''}Shared farm boundaries and existing server copies remain.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(c, 'keep'),
          child: const Text('Keep app'),
        ),
        if (unsynced > 0) ...[
          TextButton(
            onPressed: () => Navigator.pop(c, 'sync'),
            child: const Text('Sync first'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, 'export'),
            child: const Text('Export backup'),
          ),
        ],
        FilledButton(
          onPressed: () => Navigator.pop(c, 'remove'),
          child: Text(
            unsynced > 0 ? 'Remove and discard changes' : 'Remove app',
          ),
        ),
      ],
    ),
  );
  if (!context.mounted) return false;
  if (agreed == 'export') {
    await openPage(context, BackupPage(store: store));
    return false;
  }
  if (agreed == 'sync') {
    final engine = SyncEngine.activeFor(store);
    if (engine != null) {
      await openPage(context, PendingSyncPage(store: store, sync: engine));
    }
    return false;
  }
  if (agreed != 'remove') return false;
  await store.removeApp(id);
  return true;
}
