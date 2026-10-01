import 'settings.dart' show ConflictPage;
import 'dart:convert';
import 'appearance.dart';
import 'area_activity.dart';
import 'package:flutter/material.dart';
import 'store.dart';
import 'sync.dart';
import 'ui.dart';

export 'weather_widgets.dart' show WeatherDisplay;

class ConnectionLight extends StatelessWidget {
  final bool online;
  const ConnectionLight({super.key, required this.online});
  @override
  Widget build(BuildContext context) => Tooltip(
    message: online
        ? 'Online · connected to FarmerPlus'
        : 'Offline · saved work stays on this phone',
    child: Semantics(
      label: online ? 'Online' : 'Offline',
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 12),
        width: 12,
        height: 12,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: online ? const Color(0xff11ed72) : const Color(0xffff363e),
          border: Border.all(color: Colors.white, width: 1.5),
          boxShadow: [
            BoxShadow(
              color: (online ? Colors.greenAccent : Colors.redAccent)
                  .withValues(alpha: .65),
              blurRadius: 8,
              spreadRadius: 1,
            ),
          ],
        ),
      ),
    ),
  );
}

String lastSyncLabel(String? value) {
  final time = DateTime.tryParse(value ?? '')?.toLocal();
  if (time == null) return 'No successful sync yet';
  final now = DateTime.now();
  final date =
      time.year == now.year && time.month == now.month && time.day == now.day
      ? 'Today'
      : '${time.day}/${time.month}';
  return '$date ${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
}

class SyncGlass extends StatelessWidget {
  final int count;
  final bool busy;
  final String? lastSync, issue;
  final VoidCallback onTap;
  const SyncGlass({
    super.key,
    required this.count,
    required this.busy,
    required this.onTap,
    this.lastSync,
    this.issue,
  });
  @override
  Widget build(BuildContext context) {
    final attention = count > 0 && issue != null;
    final compact = count == 0;
    return Padding(
      padding: const EdgeInsets.only(top: 10, bottom: 4),
      child: LiquidGlass(
        onTap: onTap,
        padding: EdgeInsets.symmetric(
          horizontal: 16,
          vertical: compact ? 10 : 14,
        ),
        child: Row(
          children: [
            Icon(
              busy
                  ? Icons.sync_rounded
                  : attention
                  ? Icons.error_outline
                  : count > 0
                  ? Icons.cloud_upload_outlined
                  : Icons.cloud_done_outlined,
              size: compact ? 22 : 26,
              color: attention
                  ? const Color(0xffffe19a)
                  : const Color(0xffd8f8e8),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    busy && !compact
                        ? 'Syncing changes…'
                        : attention
                        ? 'Failed to sync · $count ${count == 1 ? 'change' : 'changes'}'
                        : count > 0
                        ? 'Pending · $count ${count == 1 ? 'change' : 'changes'}'
                        : lastSync == null
                        ? 'No pending changes'
                        : 'All changes synced',
                    style: TextStyle(
                      fontSize: compact ? 13 : 15,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    compact
                        ? lastSyncLabel(lastSync)
                        : attention
                        ? 'Saved on this phone · tap to retry'
                        : 'Saved on this phone · last synced: ${lastSyncLabel(lastSync)}',
                    style: const TextStyle(
                      fontSize: 11,
                      color: Color(0xffe3eee9),
                    ),
                  ),
                ],
              ),
            ),
            const Icon(
              Icons.chevron_right_rounded,
              color: Colors.white,
              size: 20,
            ),
          ],
        ),
      ),
    );
  }
}

class PendingSyncPage extends StatefulWidget {
  final FarmStore store;
  final SyncEngine sync;
  const PendingSyncPage({super.key, required this.store, required this.sync});
  @override
  State<PendingSyncPage> createState() => _PendingSyncPageState();
}

class _PendingSyncPageState extends State<PendingSyncPage> {
  List<Map<String, Object?>> rows = [];
  Set<String> conflicts = {};
  bool loading = true;
  String? lastSync;
  Map<String, dynamic> savedIssues = {};
  @override
  void initState() {
    super.initState();
    widget.store.addListener(load);
    widget.sync.addListener(changed);
    load();
  }

  void changed() {
    if (mounted) setState(() {});
    load();
  }

  Future<void> load() async {
    final pending = await widget.store.db.query('queue');
    final unresolved = await widget.store.db.query('conflicts');
    final last = await widget.store.setting('lastSync');
    final issues = await widget.store.setting('syncIssues') ?? {};
    if (mounted) {
      setState(() {
        rows = pending;
        lastSync = last;
        savedIssues = Map<String, dynamic>.from(issues);
        conflicts = unresolved.map((r) => r['id'] as String).toSet();
        loading = false;
      });
    }
  }

  @override
  void dispose() {
    widget.store.removeListener(load);
    widget.sync.removeListener(changed);
    super.dispose();
  }

  Future<void> send([String? id]) async {
    await widget.store.setSetting('consent', true);
    await widget.sync.sync(recordIds: id == null ? null : {id});
    await load();
  }

  @override
  Widget build(BuildContext c) => PageFrame(
    'Changes to sync',
    children: [
      Text('Last successful sync: ${lastSyncLabel(lastSync)}'),
      const SizedBox(height: 12),
      Row(
        children: [
          Expanded(
            child: Text(
              '${rows.length} pending',
              style: Theme.of(c).textTheme.headlineMedium,
            ),
          ),
          FilledButton.icon(
            onPressed: widget.sync.busy ? null : () => guarded(c, () => send()),
            icon: const Icon(Icons.sync_rounded),
            label: Text(rows.isEmpty ? 'Sync now' : 'Sync all'),
          ),
        ],
      ),
      if (widget.sync.busy) const LinearProgressIndicator(),
      if (!loading && rows.isEmpty)
        const ListTile(
          leading: Icon(Icons.cloud_done_rounded, color: Colors.green),
          title: Text('You’re up to date'),
        ),
      for (final row in rows)
        Builder(
          builder: (c) {
            final data = jsonDecode(row['data'] as String) as Map;
            final media = data['media'] as List?;
            final savedIssue = savedIssues[row['id']] as Map?;
            final issue =
                widget.sync.itemIssues[row['id']] ??
                (savedIssue?['op_id'] == row['op_id']
                    ? (savedIssue?['message'] as String?)
                    : null);
            final label =
                (data['name'] ?? data['title'] ?? data['date'] ?? row['kind'])
                    .toString();
            return Card(
              child: ListTile(
                leading: Icon(
                  row['kind'] == 'farm'
                      ? Icons.agriculture_outlined
                      : Icons.edit_note_rounded,
                ),
                title: Text(label),
                subtitle: Text(
                  '${row['kind']} · ${row['deleted'] == 1
                      ? 'Removal'
                      : conflicts.contains(row['id'])
                      ? 'Needs conflict review'
                      : issue != null
                      ? 'Failed to sync — saved on this phone'
                      : 'Pending — saved on this phone'}${issue == null ? '' : '\n$issue'}${media?.isNotEmpty == true ? ' · ${media!.length} attachments' : ''}',
                ),
                onTap: conflicts.contains(row['id'])
                    ? () => openPage(
                        c,
                        ConflictPage(
                          store: widget.store,
                          id: row['id'] as String,
                          onResolved: load,
                        ),
                      )
                    : issue != null && {'farm', 'field'}.contains(row['kind'])
                    ? () async {
                        final record = await widget.store.get(
                          row['id'] as String,
                        );
                        if (record != null && c.mounted) {
                          await openPage(
                            c,
                            AreaActivityPage(
                              store: widget.store,
                              record: record,
                            ),
                          );
                          await load();
                        }
                      }
                    : null,
                trailing: IconButton(
                  tooltip: 'Sync $label',
                  onPressed: widget.sync.busy || conflicts.contains(row['id'])
                      ? null
                      : () => guarded(c, () => send(row['id'] as String)),
                  icon: const Icon(Icons.cloud_upload_outlined),
                ),
              ),
            );
          },
        ),
      if (rows.isNotEmpty)
        const Padding(
          padding: EdgeInsets.only(top: 12),
          child: Text(
            'Related farm records and attachments are included when needed.',
          ),
        ),
      if (widget.sync.status != 'Synced')
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Text(widget.sync.status),
        ),
    ],
  );
}
