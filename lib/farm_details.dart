import 'package:flutter/material.dart';
import 'store.dart';
import 'area_units.dart';
import 'farm.dart';
import 'taxonomy.dart';
import 'ui.dart';

class FarmDetailsPage extends StatefulWidget {
  final FarmStore store;
  final String kind;
  final String? farmId;
  final Map<String, dynamic>? record;
  const FarmDetailsPage({
    super.key,
    required this.store,
    this.kind = 'farm',
    this.farmId,
    this.record,
  });
  @override
  State<FarmDetailsPage> createState() => _FarmDetailsState();
}

class _FarmDetailsState extends State<FarmDetailsPage> {
  final name = TextEditingController(),
      other = TextEditingController(),
      manualArea = TextEditingController();
  String? category, subcategory, areaType;
  AreaUnit unit = AreaUnit.hectare;
  String initialAreaText = '';
  late String id;
  Map<String, dynamic> original = {};
  bool loaded = false, busy = false;
  String? error;
  String get draftKey =>
      'farmDetailsDraft:${widget.kind}:${widget.record?['id'] ?? widget.farmId ?? 'new'}';
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    final saved = await widget.store.setting(draftKey);
    original = Map<String, dynamic>.from(
      saved?['data'] ?? widget.record?['data'] ?? {},
    );
    id = widget.record?['id'] ?? saved?['id'] ?? uuid.v4();
    name.text = original['name'] ?? '';
    unit = AreaUnit.parse(await widget.store.setting('areaUnit'));
    final ha = original['manualAreaHa'];
    manualArea.text = ha is num
        ? unit
              .fromM2(ha * 10000)
              .toStringAsFixed(8)
              .replaceFirst(RegExp(r'\.?0+$'), '')
        : '';
    initialAreaText = manualArea.text;
    category = original['productionCategory'];
    subcategory = original['productionSubcategory'];
    areaType = original['areaType'];
    other.text = original['productionOther'] ?? '';
    if (mounted) setState(() => loaded = true);
  }

  Map<String, dynamic> data() => {
    ...original,
    'name': name.text.trim(),
    'manualAreaHa': manualArea.text == initialAreaText
        ? original['manualAreaHa']
        : double.tryParse(manualArea.text) == null
        ? null
        : unit.toM2(double.parse(manualArea.text)) / 10000,
    if (widget.kind == 'farm') ...{
      'productionCategory': category,
      'productionSubcategory': subcategory,
      'productionOther': other.text.trim(),
    } else ...{
      'farmId': widget.farmId,
      'areaType': areaType,
      'productionOther': other.text.trim(),
    },
  };
  Future<void> draft() async {
    await widget.store.setSetting(draftKey, {'id': id, 'data': data()});
  }

  bool validate() {
    final needsOther =
        category == 'Other' || subcategory == 'Other' || areaType == 'Other';
    error = name.text.trim().isEmpty
        ? 'Enter a ${widget.kind} name.'
        : needsOther && other.text.trim().isEmpty
        ? 'Describe the other production type.'
        : null;
    setState(() {});
    return error == null;
  }

  Future<void> saveDetails() async {
    if (!validate()) return;
    final entered = manualArea.text.trim();
    if (entered.isNotEmpty &&
        (double.tryParse(entered) == null ||
            !double.parse(entered).isFinite ||
            double.parse(entered) <= 0)) {
      setState(
        () => error = 'Enter a positive area in ${unit.label.toLowerCase()}.',
      );
      return;
    }
    await guarded(context, () async {
      await widget.store.save(widget.kind, data(), id: id);
      await widget.store.setSetting(draftKey, null);
      await widget.store.setSetting(
        'selectedFarm',
        widget.kind == 'farm' ? id : widget.farmId,
      );
      if (mounted) Navigator.pop(context, id);
    });
  }

  Future<void> mapBoundary() async {
    if (!validate()) return;
    setState(() => busy = true);
    await draft();
    if (!mounted) return;
    final saved = await Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (_) => BoundaryPage(
          store: widget.store,
          kind: widget.kind,
          farmId: widget.farmId,
          record: {'id': id, 'data': data()},
        ),
      ),
    );
    if (!mounted) return;
    setState(() => busy = false);
    if (saved == null) return;
    await widget.store.setSetting(draftKey, null);
    await widget.store.setSetting(
      'selectedFarm',
      widget.kind == 'farm' ? id : widget.farmId,
    );
    final farm = await widget.store.get(
      widget.kind == 'farm' ? id : widget.farmId!,
    );
    if (mounted && farm != null) {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => BoundaryPage(
            store: widget.store,
            kind: 'farm',
            record: farm,
            readOnly: true,
          ),
        ),
      );
    }
  }

  @override
  void dispose() {
    name.dispose();
    other.dispose();
    manualArea.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext c) => PageFrame(
    widget.kind == 'farm' ? 'Farm details' : 'Area details',
    children: [
      if (!loaded)
        const LinearProgressIndicator()
      else ...[
        Text(
          widget.kind == 'farm'
              ? 'Your farm, your way.'
              : 'Give this area a name.',
          style: Theme.of(c).textTheme.headlineMedium,
        ),
        note(
          widget.kind == 'farm'
              ? 'Save the basics now. Add a boundary or production details whenever you are ready.'
              : 'An area can be a paddock, orchard, pond or growing space. Mapping is optional.',
        ),
        TextField(
          controller: name,
          maxLength: 160,
          decoration: InputDecoration(
            labelText: widget.kind == 'farm' ? 'Farm name' : 'Area name',
          ),
          textCapitalization: TextCapitalization.words,
          onChanged: (_) => draft(),
        ),
        gap(),
        if (widget.kind == 'farm') ...[
          DropdownButtonFormField<String>(
            initialValue: category,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'Main production category (optional)',
            ),
            items:
                {...productionCategories.keys, if (category != null) category!}
                    .map(
                      (v) => DropdownMenuItem(
                        value: v,
                        child: Text(v, maxLines: 2),
                      ),
                    )
                    .toList(),
            onChanged: (v) {
              setState(() {
                category = v;
                subcategory = v == 'Other' ? 'Other' : null;
              });
              draft();
            },
          ),
          gap(),
          DropdownButtonFormField<String>(
            key: ValueKey(category),
            initialValue: subcategory,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'Production subcategory (optional)',
            ),
            items:
                {
                      ...?productionCategories[category],
                      'Other',
                      if (subcategory != null) subcategory!,
                    }
                    .map(
                      (v) => DropdownMenuItem(
                        value: v,
                        child: Text(v, maxLines: 2),
                      ),
                    )
                    .toList(),
            onChanged: category == null
                ? null
                : (v) {
                    setState(() => subcategory = v);
                    draft();
                  },
          ),
          if (category == 'Field crops')
            note(
              'Cereals include maize, wheat and rice. Roots and tubers include cassava and potatoes.',
            ),
        ] else
          DropdownButtonFormField<String>(
            initialValue: areaType,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'Area type (optional)',
            ),
            items: {
              ...productionAreaTypes,
              if (areaType != null) areaType!,
            }.map((v) => DropdownMenuItem(value: v, child: Text(v))).toList(),
            onChanged: (v) {
              setState(() => areaType = v);
              draft();
            },
          ),
        if (category == 'Other' ||
            subcategory == 'Other' ||
            areaType == 'Other') ...[
          gap(),
          TextField(
            controller: other,
            maxLength: 160,
            decoration: const InputDecoration(labelText: 'Please specify'),
            onChanged: (_) => draft(),
          ),
        ],
        gap(),
        TextField(
          controller: manualArea,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(
            labelText: 'Known area in ${unit.label.toLowerCase()} (optional)',
            helperText: 'Kept separately from the mapped measurement.',
          ),
          onChanged: (_) => draft(),
        ),
        gap(24),
        if (error != null) note(error!, icon: Icons.error_outline),
        FilledButton.icon(
          onPressed: busy ? null : saveDetails,
          icon: const Icon(Icons.check),
          label: const Text('Save details'),
        ),
        gap(),
        OutlinedButton.icon(
          onPressed: busy ? null : mapBoundary,
          icon: const Icon(Icons.map_outlined),
          label: Text(
            widget.kind == 'farm' ? 'Map your farm' : 'Map this area',
          ),
        ),
        note('Your details and unfinished boundary are saved as a draft.'),
      ],
    ],
  );
}
