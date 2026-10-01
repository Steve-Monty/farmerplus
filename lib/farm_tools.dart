import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'store.dart';
import 'area_units.dart';
import 'ui.dart';
import 'farm_context.dart';
import 'farm_places.dart';

const stockUnits = ['kg', 'g', 'litres', 'bags', 'units'];
Map<String, String> namedChoices(
  List<Map<String, dynamic>> rows,
  String empty,
) {
  final choices = <String, String>{empty: ''};
  for (final row in rows) {
    final name = row['data']['name'].toString();
    var label = name;
    var number = 2;
    while (choices.containsKey(label)) {
      label = '$name ($number)';
      number++;
    }
    choices[label] = row['id'];
  }
  return choices;
}

String amount(num value) => value == value.roundToDouble()
    ? value.toInt().toString()
    : value.toStringAsFixed(2);

class ToolField {
  final String key, label, type;
  final List<String>? options;
  final bool required;
  const ToolField(
    this.key,
    this.label, {
    this.type = 'text',
    this.options,
    this.required = true,
  });
}

Future<void> toolForm(
  BuildContext c,
  FarmStore store,
  String kind,
  String title,
  List<ToolField> fields,
  Map<String, dynamic> initial, {
  String? id,
  Map<String, dynamic> Function(Map<String, dynamic>)? transform,
}) async {
  await Navigator.push(
    c,
    MaterialPageRoute(
      builder: (_) => _ToolForm(
        store: store,
        kind: kind,
        title: title,
        fields: fields,
        initial: initial,
        id: id,
        transform: transform,
      ),
    ),
  );
}

class _ToolForm extends StatefulWidget {
  final FarmStore store;
  final String kind, title;
  final List<ToolField> fields;
  final Map<String, dynamic> initial;
  final String? id;
  final Map<String, dynamic> Function(Map<String, dynamic>)? transform;
  const _ToolForm({
    required this.store,
    required this.kind,
    required this.title,
    required this.fields,
    required this.initial,
    this.id,
    this.transform,
  });
  @override
  State<_ToolForm> createState() => _ToolFormState();
}

class _ToolFormState extends State<_ToolForm> {
  final controllers = <String, TextEditingController>{};
  bool ready = false, busy = false;
  String? error;
  String get key =>
      'appDraft:${widget.kind == 'stockmove'
          ? 'stock'
          : widget.kind == 'sale'
          ? 'harvest'
          : widget.kind}:${widget.id ?? 'new'}:${widget.initial['farmId']}${widget.kind == 'season' ? ':${widget.initial['fieldId'] ?? ''}' : ''}';
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    final draft = await widget.store.setting(key);
    for (final f in widget.fields) {
      controllers[f.key] = TextEditingController(
        text:
            (draft?[f.key] ??
                    widget.initial[f.key] ??
                    (f.type == 'date' && f.required
                        ? DateTime.now().toIso8601String().substring(0, 10)
                        : ''))
                .toString(),
      );
    }
    if (mounted) setState(() => ready = true);
  }

  Future<void> saveDraft() async => widget.store.setSetting(key, {
    for (final e in controllers.entries) e.key: e.value.text,
  });
  @override
  void dispose() {
    for (final c in controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> save() async {
    setState(() {
      error = null;
      busy = true;
    });
    try {
      final data = <String, dynamic>{...widget.initial};
      for (final f in widget.fields) {
        final text = controllers[f.key]!.text.trim();
        if (f.required && text.isEmpty) {
          throw StateError('Enter ${f.label.toLowerCase()}.');
        }
        if (f.type == 'number') {
          final value = double.tryParse(text);
          if (value == null || !value.isFinite) {
            throw StateError('Enter a valid ${f.label.toLowerCase()}.');
          }
          data[f.key] = value;
        } else if (f.type == 'date' && text.isNotEmpty) {
          if (DateTime.tryParse(text) == null) {
            throw StateError('Choose a valid date.');
          }
          data[f.key] = text;
        } else {
          data[f.key] = text;
        }
      }
      await widget.store.save(
        widget.kind,
        widget.transform?.call(data) ?? data,
        id: widget.id,
      );
      await widget.store.setSetting(key, null);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        setState(() => error = e.toString().replaceFirst('Bad state: ', ''));
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext c) => PageFrame(
    widget.title,
    children: [
      if (!ready)
        const LinearProgressIndicator()
      else ...[
        for (final f in widget.fields) ...[
          if (f.options != null)
            DropdownButtonFormField<String>(
              initialValue: f.options!.contains(controllers[f.key]!.text)
                  ? controllers[f.key]!.text
                  : null,
              isExpanded: true,
              decoration: InputDecoration(labelText: f.label),
              items: f.options!
                  .map((v) => DropdownMenuItem(value: v, child: Text(v)))
                  .toList(),
              onChanged: (v) {
                controllers[f.key]!.text = v ?? '';
                saveDraft();
              },
            )
          else
            TextField(
              controller: controllers[f.key],
              maxLength: f.type == 'text' ? 160 : null,
              maxLines: f.key == 'notes' ? 3 : 1,
              readOnly: f.type == 'date',
              keyboardType: f.type == 'number'
                  ? const TextInputType.numberWithOptions(
                      decimal: true,
                      signed: true,
                    )
                  : TextInputType.text,
              decoration: InputDecoration(
                labelText: f.label,
                suffixIcon: f.type == 'date'
                    ? const Icon(Icons.calendar_today_outlined)
                    : null,
              ),
              onChanged: (_) => saveDraft(),
              onTap: f.type != 'date'
                  ? null
                  : () async {
                      final date = await showDatePicker(
                        context: c,
                        initialDate:
                            DateTime.tryParse(controllers[f.key]!.text) ??
                            DateTime.now(),
                        firstDate: DateTime(2000),
                        lastDate: DateTime(2100),
                      );
                      if (date != null) {
                        controllers[f.key]!.text = date
                            .toIso8601String()
                            .substring(0, 10);
                        await saveDraft();
                      }
                    },
            ),
          gap(12),
        ],
        if (error != null) note(error!, icon: Icons.error_outline),
        FilledButton(
          onPressed: busy ? null : save,
          child: const Text('Save record'),
        ),
        note(
          'Saved on this device. Synchronise to back it up to your account.',
        ),
      ],
    ],
  );
}

abstract class FarmToolState<T extends StatefulWidget> extends State<T> {
  FarmStore get store;
  List<Map<String, dynamic>> farms = [];
  String? farmId;
  bool loaded = false;
  Future<void> loadTool();
  @override
  void initState() {
    super.initState();
    store.addListener(loadTool);
    loadTool();
  }

  @override
  void dispose() {
    store.removeListener(loadTool);
    super.dispose();
  }

  Future<void> loadFarm() async {
    farms = await store.records('farm');
    final selected = await store.setting('selectedFarm');
    if (!farms.any((f) => f['id'] == farmId)) {
      farmId = farms.any((f) => f['id'] == selected)
          ? selected
          : farms.firstOrNull?['id'];
    }
  }

  Widget farmPicker() => DropdownButtonFormField<String>(
    key: ValueKey(farmId),
    initialValue: farmId,
    isExpanded: true,
    decoration: const InputDecoration(labelText: 'Farm'),
    items: farms
        .map(
          (f) => DropdownMenuItem<String>(
            value: f['id'],
            child: Text(f['data']['name']),
          ),
        )
        .toList(),
    onChanged: (v) async {
      farmId = v;
      await store.setSetting('selectedFarm', v);
      await loadTool();
    },
  );
  List<Widget> get farmHeader => [
    if (farms.isEmpty)
      note('Add a farm in My Farm to start recording.')
    else
      farmPicker(),
    gap(),
  ];
}

class StockPage extends StatefulWidget {
  final FarmStore store;
  final String? initialAreaId;
  const StockPage({super.key, required this.store, this.initialAreaId});
  @override
  State<StockPage> createState() => _StockState();
}

class _StockState extends FarmToolState<StockPage> {
  @override
  FarmStore get store => widget.store;
  List<Map<String, dynamic>> items = [], moves = [];
  @override
  Future<void> loadTool() async {
    await loadFarm();
    items = (await store.records(
      'stock',
    )).where((r) => r['data']['farmId'] == farmId).toList();
    moves = await store.records('stockmove');
    if (mounted) setState(() => loaded = true);
  }

  double balance(String id) => moves
      .where((r) => r['data']['stockId'] == id)
      .fold(0, (a, r) => a + (r['data']['delta'] as num).toDouble());
  Future<void> movement(Map<String, dynamic> item, bool use) async {
    final areas = (await store.records(
      'field',
    )).where((r) => r['data']['farmId'] == farmId).toList();
    final choices = namedChoices(areas, 'Whole farm');
    final chosen =
        choices.entries
            .where((e) => e.value == widget.initialAreaId)
            .firstOrNull
            ?.key ??
        'Whole farm';
    if (!mounted) return;

    await toolForm(
      context,
      store,
      'stockmove',
      use ? 'Record stock use' : 'Add stock',
      [
        if (use)
          ToolField('area', 'Applies to', options: choices.keys.toList()),
        if (use)
          const ToolField(
            'createDiary',
            'Also add to diary?',
            options: ['No', 'Yes'],
          ),
        ToolField('quantity', 'Quantity', type: 'number'),
        ToolField('date', 'Date', type: 'date'),
        ToolField('notes', 'Notes', required: false),
      ],
      {
        'farmId': farmId,
        'stockId': item['id'],
        'area': chosen,
        'createDiary': 'No',
        'itemName': item['data']['name'],
        'unit': item['data']['unit'],
      },
      transform: (d) {
        final q = d.remove('quantity') as num;
        if (q <= 0) throw StateError('Enter a positive quantity.');
        return {
          ...d,
          'delta': use ? -q : q,
          'fieldId': use ? choices[d.remove('area')] : null,
          'createDiary': use && d['createDiary'] == 'Yes',
        };
      },
    );
    await loadTool();
  }

  @override
  Widget build(BuildContext c) => PageFrame(
    'Input Stock',
    children: [
      ...farmHeader,
      if (!loaded) const LinearProgressIndicator(),
      if (loaded && items.isEmpty && farmId != null)
        note(
          'Start with an item, then record stock received or used. Quantities come from your entries.',
        ),
      for (final item in items)
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item['data']['name'],
                  style: Theme.of(c).textTheme.titleLarge,
                ),
                Text(
                  '${amount(balance(item['id']))} ${item['data']['unit']} in stock',
                ),
                if ((item['data']['expiry'] ?? '').isNotEmpty)
                  Text('Expiry: ${item['data']['expiry']}'),
                Row(
                  children: [
                    TextButton.icon(
                      onPressed: () => movement(item, false),
                      icon: const Icon(Icons.add),
                      label: const Text('Received'),
                    ),
                    TextButton.icon(
                      onPressed: () => movement(item, true),
                      icon: const Icon(Icons.remove),
                      label: const Text('Used'),
                    ),
                  ],
                ),
                if (moves.any((r) => r['data']['stockId'] == item['id']))
                  ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    title: const Text('Stock history'),
                    children: [
                      for (final move in moves.where(
                        (r) => r['data']['stockId'] == item['id'],
                      ))
                        ListTile(
                          title: Text(
                            '${(move['data']['delta'] as num) > 0 ? 'Received' : 'Used'} ${amount((move['data']['delta'] as num).abs())} ${item['data']['unit']}',
                          ),
                          subtitle: Text(
                            [move['data']['date'], move['data']['notes']]
                                .where(
                                  (v) => v != null && v.toString().isNotEmpty,
                                )
                                .join(' · '),
                          ),
                        ),
                    ],
                  ),
              ],
            ),
          ),
        ),
      gap(),
      FilledButton.icon(
        onPressed: farmId == null
            ? null
            : () async {
                await toolForm(
                  c,
                  store,
                  'stock',
                  'New stock item',
                  const [
                    ToolField('name', 'Item name'),
                    ToolField('unit', 'Unit', options: stockUnits),
                    ToolField('batch', 'Batch / lot', required: false),
                    ToolField(
                      'expiry',
                      'Expiry date',
                      type: 'date',
                      required: false,
                    ),
                  ],
                  {'farmId': farmId},
                );
                await loadTool();
              },
        icon: const Icon(Icons.add),
        label: const Text('Add item'),
      ),
    ],
  );
}

class HarvestPage extends StatefulWidget {
  final FarmStore store;
  final String? initialAreaId;
  const HarvestPage({super.key, required this.store, this.initialAreaId});
  @override
  State<HarvestPage> createState() => _HarvestState();
}

class _HarvestState extends FarmToolState<HarvestPage> {
  @override
  FarmStore get store => widget.store;
  List<Map<String, dynamic>> harvests = [],
      sales = [],
      fields = [],
      seasons = [];
  @override
  Future<void> loadTool() async {
    await loadFarm();
    harvests = (await store.records(
      'harvest',
    )).where((r) => r['data']['farmId'] == farmId).toList();
    sales = await store.records('sale');
    fields = (await store.records(
      'field',
    )).where((r) => r['data']['farmId'] == farmId).toList();
    seasons = (await store.records(
      'season',
    )).where((r) => r['data']['farmId'] == farmId).toList();
    if (mounted) setState(() => loaded = true);
  }

  double sold(String id) => sales
      .where((r) => r['data']['harvestId'] == id)
      .fold(0, (a, r) => a + (r['data']['quantity'] as num).toDouble());
  Future<void> addHarvest() async {
    final fieldChoices = namedChoices(fields, 'Whole farm');
    final seasonChoices = namedChoices(seasons, 'No season selected');
    await toolForm(
      context,
      store,
      'harvest',
      'Record harvest',
      [
        const ToolField('name', 'Crop / product'),
        ToolField('field', 'Farm area', options: fieldChoices.keys.toList()),
        ToolField('season', 'Season', options: seasonChoices.keys.toList()),
        const ToolField('date', 'Harvest date', type: 'date'),
        const ToolField('quantity', 'Quantity', type: 'number'),
        const ToolField('unit', 'Unit', options: stockUnits),
        const ToolField('grade', 'Grade / quality', required: false),
      ],
      {
        'farmId': farmId,
        'field':
            fieldChoices.entries
                .where((e) => e.value == widget.initialAreaId)
                .firstOrNull
                ?.key ??
            'Whole farm',
        'season': 'No season selected',
      },
      transform: (d) {
        final fieldId = fieldChoices[d.remove('field')];
        final record =
            fields.where((r) => r['id'] == fieldId).firstOrNull ??
            farms.where((r) => r['id'] == farmId).firstOrNull;
        final snapshot = areaSnapshot(record);
        return {
          ...d,
          'fieldId': fieldId,
          'seasonId': seasonChoices[d.remove('season')],
          'areaSnapshot': snapshot,
          if (snapshot['areaM2'] is num && snapshot['areaM2'] > 0)
            'yieldPerHa': (d['quantity'] as num) / (snapshot['areaM2'] / 10000),
        };
      },
    );
    await loadTool();
  }

  Future<void> sell(
    Map<String, dynamic> harvest, [
    Map<String, dynamic>? sale,
  ]) async {
    await toolForm(
      context,
      store,
      'sale',
      sale == null ? 'Record sale' : 'Edit sale',
      const [
        ToolField('buyer', 'Buyer'),
        ToolField('quantity', 'Quantity sold', type: 'number'),
        ToolField('unitPrice', 'Price per unit', type: 'number'),
        ToolField(
          'currency',
          'Currency',
          options: [
            'ZAR',
            'USD',
            'EUR',
            'GBP',
            'KES',
            'UGX',
            'TZS',
            'NGN',
            'GHS',
            'ZMW',
            'BWP',
            'NAD',
          ],
        ),
        ToolField('payment', 'Payment status', options: ['Unpaid', 'Paid']),
        ToolField('date', 'Sale date', type: 'date'),
      ],
      {
        'farmId': farmId,
        'harvestId': harvest['id'],
        'unit': harvest['data']['unit'],
        'payment': 'Unpaid',
        ...?sale?['data'],
      },
      id: sale?['id'],
    );
    await loadTool();
  }

  @override
  Widget build(BuildContext c) => PageFrame(
    'Harvest & Sales',
    children: [
      ...farmHeader,
      if (loaded && harvests.isEmpty && farmId != null)
        note(
          'Record what you harvested, then link each sale. Prices and payments are your records; this does not move money.',
        ),
      for (final h in harvests)
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  h['data']['name'],
                  style: Theme.of(c).textTheme.titleLarge,
                ),
                Text(
                  '${amount(h['data']['quantity'])} ${h['data']['unit']} harvested · ${h['data']['date']}',
                ),
                if (h['data']['yieldPerHa'] is num)
                  FutureBuilder<dynamic>(
                    future: widget.store.setting('areaUnit'),
                    builder: (c, pref) {
                      final unit = AreaUnit.parse(pref.data);
                      return Text(
                        '${amount((h['data']['yieldPerHa'] as num) * unit.squareMetres / 10000)} ${h['data']['unit']}/${unit.symbol} · ${h['data']['areaSnapshot']?['source'] ?? 'recorded'} area at harvest',
                      );
                    },
                  ),
                Text(
                  '${amount((h['data']['quantity'] as num) - sold(h['id']))} ${h['data']['unit']} unsold',
                ),
                TextButton.icon(
                  onPressed: () => sell(h),
                  icon: const Icon(Icons.receipt_long_outlined),
                  label: const Text('Record sale'),
                ),
                for (final sale in sales.where(
                  (r) => r['data']['harvestId'] == h['id'],
                ))
                  ListTile(
                    title: Text(sale['data']['buyer']),
                    subtitle: Text(
                      '${sale['data']['currency']} ${amount((sale['data']['quantity'] as num) * (sale['data']['unitPrice'] as num))} · ${sale['data']['payment']}',
                    ),
                    trailing: const Icon(Icons.edit_outlined),
                    onTap: () => sell(h, sale),
                  ),
              ],
            ),
          ),
        ),
      FilledButton.icon(
        onPressed: farmId == null ? null : addHarvest,
        icon: const Icon(Icons.add),
        label: const Text('Add harvest'),
      ),
    ],
  );
}

class SeasonsPage extends StatefulWidget {
  final FarmStore store;
  final String farmId;
  final String? initialAreaId;
  const SeasonsPage({
    super.key,
    required this.store,
    required this.farmId,
    this.initialAreaId,
  });
  @override
  State<SeasonsPage> createState() => _SeasonsState();
}

class _SeasonsState extends State<SeasonsPage> {
  List<Map<String, dynamic>> rows = [], fields = [];
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
    rows = (await widget.store.records('season'))
        .where(
          (r) =>
              r['data']['farmId'] == widget.farmId &&
              (widget.initialAreaId == null ||
                  r['data']['fieldId'] == widget.initialAreaId),
        )
        .toList();
    fields = (await widget.store.records(
      'field',
    )).where((r) => r['data']['farmId'] == widget.farmId).toList();
    if (mounted) setState(() {});
  }

  Future<void> edit([Map<String, dynamic>? row]) async {
    final choices = namedChoices(fields, 'Whole farm');
    await toolForm(
      context,
      widget.store,
      'season',
      row == null ? 'New crop season' : 'Edit crop season',
      [
        const ToolField('name', 'Season name'),
        const ToolField('crop', 'Crop / production'),
        ToolField('field', 'Farm area', options: choices.keys.toList()),
        const ToolField('start', 'Start date', type: 'date'),
        const ToolField(
          'status',
          'Status',
          options: ['Planned', 'Active', 'Closed'],
        ),
      ],
      {
        'farmId': widget.farmId,
        'fieldId': widget.initialAreaId,
        'status': 'Planned',
        ...?row?['data'],
        'field': choices.keys.firstWhere(
          (k) =>
              choices[k] ==
              (row == null ? widget.initialAreaId : row['data']['fieldId']),
          orElse: () => choices.keys.first,
        ),
      },
      id: row?['id'],
      transform: (d) {
        final fieldId = choices[d.remove('field')];
        return {...d, 'fieldId': fieldId};
      },
    );
    await load();
  }

  @override
  Widget build(BuildContext c) => PageFrame(
    'Seasons (Crop)',
    children: [
      note(
        widget.initialAreaId == null
            ? 'Crop seasons across this farm. Each season keeps its own crop, area and dates.'
            : 'Crop seasons for this area. New seasons are linked here automatically.',
      ),
      if (rows.isEmpty)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 24),
          child: Text(
            'No crop seasons yet. Add your first planned or active crop.',
          ),
        ),
      for (final row in rows)
        ListTile(
          title: Text(row['data']['name']),
          leading: const Icon(Icons.grass_outlined),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('${row['data']['crop']} · ${row['data']['status']}'),
              Text(
                '${seasonLocation(row, fields)} · ${row['data']['start'] ?? ''}',
              ),
              const SizedBox(height: 6),
              RecordSyncStatus(store: widget.store, record: row),
            ],
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => edit(row),
        ),
      FilledButton.icon(
        onPressed: () => edit(),
        icon: const Icon(Icons.add),
        label: const Text('Add crop season'),
      ),
    ],
  );
}

class GuidesPage extends StatefulWidget {
  final FarmStore store;
  const GuidesPage({super.key, required this.store});
  @override
  State<GuidesPage> createState() => _GuidesState();
}

class _GuidesState extends State<GuidesPage> {
  List<dynamic> guides = [];
  String query = '';
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    final content = await widget.store.content('guides');
    if (mounted) setState(() => guides = content['guides'] ?? []);
  }

  @override
  Widget build(BuildContext c) => PageFrame(
    'Farm Guides',
    children: [
      note(
        'Short reference guides saved on this device. Local conditions and expert advice still matter.',
      ),
      TextField(
        decoration: const InputDecoration(
          labelText: 'Search guides',
          prefixIcon: Icon(Icons.search),
        ),
        onChanged: (v) => setState(() => query = v.toLowerCase()),
      ),
      gap(),
      for (final guide in guides.where(
        (g) => jsonEncode(g).toLowerCase().contains(query),
      ))
        ListTile(
          title: Text(guide['title']),
          subtitle: Text(guide['summary']),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => openPage(
            c,
            PageFrame(
              guide['title'],
              showArtwork: false,
              children: [
                Text(guide['body'], style: Theme.of(c).textTheme.bodyLarge),
                gap(24),
                Text('Original FarmerPlus reference · ${guide['reviewed']}'),
                for (final source in guide['sources'] ?? [])
                  TextButton.icon(
                    onPressed: () => launchUrl(
                      Uri.parse(source['url']),
                      mode: LaunchMode.externalApplication,
                    ),
                    icon: const Icon(Icons.open_in_new),
                    label: Text(source['title']),
                  ),
              ],
            ),
          ),
        ),
    ],
  );
}
