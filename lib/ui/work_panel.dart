import 'package:flutter/material.dart';

import '../calculators.dart';
import '../main.dart';
import '../price_db.dart';
import '../state.dart';
import 'takeoff_card.dart';

/// Right pane: pick a work type, type in the dimensions, preview the
/// computed material take-off, then write it into the BOQ sheet.
class WorkPanel extends StatefulWidget {
  final EstimateState est;
  const WorkPanel({super.key, required this.est});

  @override
  State<WorkPanel> createState() => _WorkPanelState();
}

class _WorkPanelState extends State<WorkPanel> {
  int _type = 0;
  ModelPrefill? _prefill;

  static const _prefillType = {
    'concrete': 0,
    'masonry': 1,
    'tiles': 2,
    'painting': 3,
    'steel': 5,
  };

  void _openPrefill(ModelPrefill p) {
    final i = _prefillType[p.kind];
    if (i == null) return;
    setState(() {
      _type = i;
      _prefill = p;
    });
  }

  static const _types = [
    ('Concreting', Icons.foundation),
    ('Masonry', Icons.domain),
    ('Tiling', Icons.grid_on),
    ('Painting', Icons.format_paint),
    ('Carpentry', Icons.carpenter),
    ('Steel / Rebar', Icons.construction),
    ('Stairs', Icons.stairs),
    ('Manual Item', Icons.edit_note),
  ];

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 16, 16, 16),
      child: Card(
        child: Column(
          children: [
            _header(),
            const Divider(height: 1),
            TakeoffCard(onPrefill: _openPrefill),
            _typeGrid(),
            const Divider(height: 1),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(14),
                child: _form(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _header() {
    return const Padding(
      padding: EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(
        children: [
          Icon(Icons.playlist_add, size: 18, color: Color(0xFF64748B)),
          SizedBox(width: 8),
          Text(
            'INSERT WORK',
            style: TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 12,
              letterSpacing: 1,
              color: Color(0xFF475569),
            ),
          ),
        ],
      ),
    );
  }

  Widget _typeGrid() {
    return Padding(
      padding: const EdgeInsets.all(10),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (var i = 0; i < _types.length; i++)
            ChoiceChip(
              avatar: Icon(
                _types[i].$2,
                size: 15,
                color: _type == i
                    ? Theme.of(context).colorScheme.primary
                    : const Color(0xFF64748B),
              ),
              label: Text(_types[i].$1, style: const TextStyle(fontSize: 11.5)),
              selected: _type == i,
              onSelected: (_) => setState(() {
                _type = i;
                _prefill = null;
              }),
              selectedColor: const Color(0xFFDCE8F5),
              side: BorderSide(
                color: _type == i
                    ? Theme.of(context).colorScheme.primary
                    : const Color(0xFFE2E8F0),
              ),
            ),
        ],
      ),
    );
  }

  Widget _form() {
    // key on the prefill so each takeoff click remounts the form with
    // fresh model values even when the work type is unchanged.
    final p = _prefill;
    switch (_type) {
      case 0:
        return ConcreteForm(key: ValueKey(p), prefill: p);
      case 1:
        return MasonryForm(key: ValueKey(p), prefill: p);
      case 2:
        return TilesForm(key: ValueKey(p), prefill: p);
      case 3:
        return PaintingForm(key: ValueKey(p), prefill: p);
      case 4:
        return const CarpentryForm();
      case 5:
        return SteelForm(key: ValueKey(p), prefill: p);
      case 6:
        return const StairsForm();
      default:
        return const ManualForm();
    }
  }
}

// ============================================================================
// shared atoms
// ============================================================================

class _Fields extends StatelessWidget {
  final List<Widget> children;
  const _Fields({required this.children});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
  }
}

Widget numField(
  String label,
  TextEditingController c, {
  String? suffix,
  void Function()? onChanged,
}) {
  return Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: TextField(
      controller: c,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      onChanged: (_) => onChanged?.call(),
      decoration: InputDecoration(
        labelText: label,
        suffixText: suffix,
        suffixStyle: _unitStyle,
      ),
      style: const TextStyle(fontSize: 13),
    ),
  );
}

const _unitStyle = TextStyle(fontSize: 11, color: Color(0xFF94A3B8));

/// Editable combo: dropdown presets AND free input — the presets appear
/// in the menu while the field itself accepts typed values.
Widget comboField(
  String label,
  TextEditingController c,
  List<({String value, String label})> presets, {
  void Function()? onChanged,
}) {
  return Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: DropdownMenu<String>(
      controller: c,
      requestFocusOnTap: true,
      enableFilter: false,
      expandedInsets: EdgeInsets.zero,
      label: Text(label, style: const TextStyle(fontSize: 12.5)),
      trailingIcon: const Icon(Icons.arrow_drop_down, size: 20),
      menuStyle: MenuStyle(
        backgroundColor: const WidgetStatePropertyAll(Colors.white),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      ),
      dropdownMenuEntries: [
        for (final p in presets)
          DropdownMenuEntry(
            value: p.value,
            label: p.label,
            style: MenuItemButton.styleFrom(
              textStyle: const TextStyle(fontSize: 12.5),
            ),
          ),
      ],
      onSelected: (v) {
        if (v != null) c.text = v;
        onChanged?.call();
      },
    ),
  );
}

Widget dropField<T>(
  String label,
  T value,
  List<T> items,
  String Function(T) labelOf,
  void Function(T) onChanged,
) {
  return Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: DropdownButtonFormField<T>(
      initialValue: value,
      isExpanded: true,
      decoration: InputDecoration(labelText: label),
      items: items
          .map(
            (e) => DropdownMenuItem(
              value: e,
              child: Text(
                labelOf(e),
                style: const TextStyle(fontSize: 12.5),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          )
          .toList(),
      onChanged: (v) => v != null ? onChanged(v) : null,
    ),
  );
}

Widget switchRow(String label, bool value, void Function(bool) onChanged) {
  return Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: const TextStyle(fontSize: 12.5, color: Color(0xFF334155)),
          ),
        ),
        Switch(value: value, onChanged: onChanged),
      ],
    ),
  );
}

Widget segField<T>(
  String label,
  List<T> options,
  T value,
  String Function(T) labelOf,
  void Function(T) onChanged,
) {
  return Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(fontSize: 11, color: Color(0xFF64748B)),
        ),
        const SizedBox(height: 6),
        SizedBox(
          width: double.infinity,
          child: SegmentedButton<T>(
            segments: options
                .map(
                  (o) => ButtonSegment(
                    value: o,
                    label: Text(
                      labelOf(o),
                      style: const TextStyle(fontSize: 11),
                    ),
                  ),
                )
                .toList(),
            selected: {value},
            onSelectionChanged: (s) => onChanged(s.first),
            style: ButtonStyle(
              visualDensity: VisualDensity.compact,
              textStyle: WidgetStateProperty.all(const TextStyle(fontSize: 11)),
            ),
          ),
        ),
      ],
    ),
  );
}

/// Area-or-dimensions input used by several forms.
class AreaInput extends StatelessWidget {
  final bool byDims;
  final TextEditingController length;
  final TextEditingController width;
  final TextEditingController area;
  final String areaLabel;
  final String dimsLabel;
  final void Function(bool) onMode;
  final void Function() onChanged;

  const AreaInput({
    super.key,
    required this.byDims,
    required this.length,
    required this.width,
    required this.area,
    this.areaLabel = 'Total area',
    this.dimsLabel = 'sq.m',
    required this.onMode,
    required this.onChanged,
  });

  double get value {
    if (byDims) {
      return (_d(length.text)) * (_d(width.text));
    }
    return _d(area.text);
  }

  static double _d(String s) => double.tryParse(s) ?? 0;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        segField(
          'Input as',
          const [true, false],
          byDims,
          (v) => v ? 'L × W' : areaLabel,
          onMode,
        ),
        if (byDims)
          Row(
            children: [
              Expanded(
                child: numField(
                  'Length',
                  length,
                  suffix: 'm',
                  onChanged: onChanged,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: numField(
                  'Width',
                  width,
                  suffix: 'm',
                  onChanged: onChanged,
                ),
              ),
            ],
          )
        else
          numField(areaLabel, area, suffix: dimsLabel, onChanged: onChanged),
      ],
    );
  }
}

/// Live take-off preview + target-section picker + add button.
class ResultCard extends StatelessWidget {
  final CalcResult? result;
  final TextEditingController label;
  final String? overrideSection;
  final void Function(String section) onAdd;
  final List<String> extraSections;

  const ResultCard({
    super.key,
    required this.result,
    required this.label,
    required this.onAdd,
    this.overrideSection,
    this.extraSections = const [],
  });

  @override
  Widget build(BuildContext context) {
    final r = result;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: TextField(
            controller: label,
            decoration: const InputDecoration(
              labelText: 'Location / label',
              hintText: 'e.g. 3RD FLOOR CR, GROUND FLOOR…',
            ),
            style: const TextStyle(fontSize: 13),
            textCapitalization: TextCapitalization.characters,
          ),
        ),
        Container(
          decoration: BoxDecoration(
            color: const Color(0xFFF8FAFC),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: const Color(0xFFE2E8F0)),
          ),
          child: r == null || r.lines.isEmpty
              ? const Padding(
                  padding: EdgeInsets.all(18),
                  child: Text(
                    'Fill in the inputs to preview materials.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 12, color: Color(0xFF94A3B8)),
                  ),
                )
              : Column(
                  children: [
                    for (final l in r.lines.map((e) => e.toBoqLine()))
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 6,
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                l.description,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 12),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Flexible(
                              flex: 0,
                              child: Text(
                                '${qtyFmt.format(l.qty)} ${l.unit}',
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: Color(0xFF475569),
                                ),
                              ),
                            ),
                            SizedBox(
                              width: 98,
                              child: Text(
                                l.amount > 0
                                    ? '₱${moneyFmt.format(l.amount)}'
                                    : '—',
                                textAlign: TextAlign.right,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    if (r.notes.isNotEmpty) ...[
                      const Divider(height: 1),
                      for (final n in r.notes)
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 4,
                          ),
                          child: Row(
                            children: [
                              const Icon(
                                Icons.info_outline,
                                size: 13,
                                color: Color(0xFF94A3B8),
                              ),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  n,
                                  style: const TextStyle(
                                    fontSize: 11,
                                    color: Color(0xFF64748B),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                    const Divider(height: 1),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      child: Row(
                        children: [
                          const Expanded(
                            child: Text(
                              'TOTAL',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w800,
                                color: Color(0xFF475569),
                              ),
                            ),
                          ),
                          Flexible(
                            child: Text(
                              '₱${moneyFmt.format(r.lines.map((e) => e.toBoqLine()).fold(0.0, (s, l) => s + l.amount))}',
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
        ),
        const SizedBox(height: 12),
        _SectionPicker(
          result: r,
          sectionTitleOverride: overrideSection,
          extra: extraSections,
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: r == null || r.lines.isEmpty
              ? null
              : () => onAdd(r.sectionTitle),
          icon: const Icon(Icons.add, size: 18),
          label: const Text('ADD TO BOQ'),
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 14),
            textStyle: const TextStyle(
              fontWeight: FontWeight.w700,
              letterSpacing: 0.8,
            ),
          ),
        ),
      ],
    );
  }
}

/// Global override for target section (null = auto-suggested).
String? gSectionOverride;

class _SectionPicker extends StatelessWidget {
  final CalcResult? result;
  final String? sectionTitleOverride;
  final List<String> extra;
  const _SectionPicker({
    required this.result,
    this.sectionTitleOverride,
    this.extra = const [],
  });

  @override
  Widget build(BuildContext context) {
    final suggested = sectionTitleOverride ?? result?.sectionTitle ?? '';
    final options = <String>{
      suggested,
      ...est.sections.map((s) => s.title),
      ...extra,
    }.toList();
    return DropdownButtonFormField<String>(
      initialValue: gSectionOverride ?? suggested,
      isExpanded: true,
      decoration: const InputDecoration(
        labelText: 'Add to section',
        prefixIcon: Icon(Icons.list, size: 18),
      ),
      items: options
          .map(
            (o) => DropdownMenuItem(
              value: o,
              child: Text(o, style: const TextStyle(fontSize: 12)),
            ),
          )
          .toList(),
      onChanged: (v) => gSectionOverride = (v == suggested ? null : v),
    );
  }
}

mixin _AddMixin<T extends StatefulWidget> on State<T> {
  void add(CalcResult r, TextEditingController label) {
    final sec = gSectionOverride ?? r.sectionTitle;
    widgetEst.addWork(
      sectionTitle: sec,
      groupLabel: label.text.trim(),
      items: r.lines.map((l) => l.toBoqLine()).toList(),
    );
    gSectionOverride = null;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('${r.lines.length} item(s) added to $sec'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  EstimateState get widgetEst => est;
}

// ============================================================================
// CONCRETING
// ============================================================================

class ConcreteForm extends StatefulWidget {
  final ModelPrefill? prefill;
  const ConcreteForm({super.key, this.prefill});
  @override
  State<ConcreteForm> createState() => _ConcreteFormState();
}

class _ConcreteFormState extends State<ConcreteForm> with _AddMixin {
  bool _byDims = false;
  final _l = TextEditingController();
  final _w = TextEditingController();
  final _t = TextEditingController();
  final _vol = TextEditingController();
  final _label = TextEditingController();
  String _cls = 'CLASS A (1:2:4)';
  String _gravel = '3/4';

  @override
  void initState() {
    super.initState();
    final p = widget.prefill;
    if (p != null) {
      if (p.volume != null) _vol.text = p.volume!.toStringAsFixed(2);
      if (p.label != null) _label.text = p.label!;
    }
  }

  CalcResult? get _result {
    final v = _byDims
        ? AreaInput._d(_l.text) * AreaInput._d(_w.text) * AreaInput._d(_t.text)
        : AreaInput._d(_vol.text);
    if (v <= 0) return null;
    return calcConcrete(volume: v, concreteClass: _cls, gravel: _gravel);
  }

  @override
  Widget build(BuildContext context) {
    return _Fields(
      children: [
        AreaInput(
          byDims: _byDims,
          length: _l,
          width: _w,
          area: _vol,
          areaLabel: 'Total volume',
          dimsLabel: 'cu.m',
          onMode: (v) => setState(() => _byDims = v),
          onChanged: () => setState(() {}),
        ),
        if (_byDims)
          numField(
            'Depth / thickness',
            _t,
            suffix: 'm',
            onChanged: () => setState(() {}),
          ),
        dropField(
          'Concrete class',
          _cls,
          kConcreteClasses.keys.toList(),
          (v) => v,
          (v) => setState(() => _cls = v),
        ),
        segField(
          'Gravel size',
          const ['3/4', '1'],
          _gravel,
          (v) => '$v"',
          (v) => setState(() => _gravel = v),
        ),
        const SizedBox(height: 4),
        ResultCard(
          result: _result,
          label: _label,
          onAdd: (_) => add(_result!, _label),
        ),
      ],
    );
  }
}

// ============================================================================
// MASONRY
// ============================================================================

class MasonryForm extends StatefulWidget {
  final ModelPrefill? prefill;
  const MasonryForm({super.key, this.prefill});
  @override
  State<MasonryForm> createState() => _MasonryFormState();
}

class _MasonryFormState extends State<MasonryForm> with _AddMixin {
  final _area = TextEditingController();
  final _aperture = TextEditingController(text: '0');
  final _allow = TextEditingController(text: '10');
  final _plaster = TextEditingController(text: '19');
  final _label = TextEditingController();
  String _chb = 'CHB 4"';
  String _mortar = 'CLASS A (1:2)';
  String _bag = '40kg';
  bool _rebar = true;

  @override
  void initState() {
    super.initState();
    final p = widget.prefill;
    if (p != null) {
      if (p.area != null) _area.text = p.area!.toStringAsFixed(2);
      if (p.aperture != null) _aperture.text = p.aperture!.toStringAsFixed(2);
      if (p.chb != null) _chb = p.chb!;
      if (p.label != null) _label.text = p.label!;
    }
  }

  CalcResult? get _result {
    final a = AreaInput._d(_area.text);
    if (a <= 0) return null;
    return calcMasonry(
      wallArea: a,
      apertureArea: AreaInput._d(_aperture.text),
      allowance: AreaInput._d(_allow.text) / 100,
      chb: _chb,
      mortarClass: _mortar,
      cementBag: _bag,
      plasterMm: AreaInput._d(_plaster.text),
      includeRebar: _rebar,
    );
  }

  @override
  Widget build(BuildContext context) {
    return _Fields(
      children: [
        numField(
          'Wall total area',
          _area,
          suffix: 'sq.m',
          onChanged: () => setState(() {}),
        ),
        Row(
          children: [
            Expanded(
              child: numField(
                'Aperture area',
                _aperture,
                suffix: 'sq.m',
                onChanged: () => setState(() {}),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: numField(
                'Allowance',
                _allow,
                suffix: '%',
                onChanged: () => setState(() {}),
              ),
            ),
          ],
        ),
        segField(
          'CHB size',
          const ['CHB 4"', 'CHB 6"'],
          _chb,
          (v) => v,
          (v) => setState(() => _chb = v),
        ),
        dropField(
          'Mortar class',
          _mortar,
          kMortarClasses.keys.toList(),
          (v) => v,
          (v) => setState(() => _mortar = v),
        ),
        Row(
          children: [
            Expanded(
              child: dropField(
                'Cement bag',
                _bag,
                const ['40kg', '50kg'],
                (v) => v,
                (v) => setState(() => _bag = v),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: numField(
                'Plastering',
                _plaster,
                suffix: 'mm',
                onChanged: () => setState(() {}),
              ),
            ),
          ],
        ),
        switchRow(
          'Include steel bars + tie wire',
          _rebar,
          (v) => setState(() => _rebar = v),
        ),
        ResultCard(
          result: _result,
          label: _label,
          onAdd: (_) => add(_result!, _label),
        ),
      ],
    );
  }
}

// ============================================================================
// TILING
// ============================================================================

class TilesForm extends StatefulWidget {
  final ModelPrefill? prefill;
  const TilesForm({super.key, this.prefill});
  @override
  State<TilesForm> createState() => _TilesFormState();
}

class _TilesFormState extends State<TilesForm> with _AddMixin {
  bool _byDims = true;
  final _l = TextEditingController(text: '6.5');
  final _w = TextEditingController(text: '5.5');
  final _area = TextEditingController();
  final _waste = TextEditingController(text: '5');
  final _thick = TextEditingController(text: '50');
  final _label = TextEditingController();
  String _size = '0.60 x 0.60';
  bool _isWall = false;
  bool _dryPack = false;

  /// Standard mud-bed / dry-pack thicknesses (mm) offered in the
  /// dropdown — 50mm matches the workbook default and the common
  /// Philippine/TCNA thick-bed practice (38–50mm bonded mud bed).
  static const _thickPresets = [
    (value: '25', label: '25 mm'),
    (value: '38', label: '38 mm (1½″)'),
    (value: '50', label: '50 mm — standard'),
    (value: '75', label: '75 mm'),
    (value: '100', label: '100 mm'),
  ];

  @override
  void initState() {
    super.initState();
    // live preview while the user types a custom thickness
    _thick.addListener(() => setState(() {}));
    final p = widget.prefill;
    if (p != null) {
      if (p.area != null) {
        _byDims = false;
        _area.text = p.area!.toStringAsFixed(2);
      }
      if (p.label != null) _label.text = p.label!;
    }
  }

  CalcResult? get _result {
    final a = AreaInput(
      byDims: _byDims,
      length: _l,
      width: _w,
      area: _area,
      onMode: (_) {},
      onChanged: () {},
    ).value;
    if (a <= 0) return null;
    return calcTiles(
      area: a,
      tileSize: _size,
      isWall: _isWall,
      wastePct: AreaInput._d(_waste.text),
      dryPack: _dryPack,
      dryPackMm: AreaInput._d(_thick.text),
    );
  }

  @override
  Widget build(BuildContext context) {
    return _Fields(
      children: [
        AreaInput(
          byDims: _byDims,
          length: _l,
          width: _w,
          area: _area,
          onMode: (v) => setState(() => _byDims = v),
          onChanged: () => setState(() {}),
        ),
        segField(
          'Application',
          const [false, true],
          _isWall,
          (v) => v ? 'WALL' : 'FLOOR',
          (v) => setState(() => _isWall = v),
        ),
        dropField(
          'Tile size',
          _size,
          kTileSizes.keys.toList(),
          (v) => v,
          (v) => setState(() => _size = v),
        ),
        numField(
          'Waste allowance',
          _waste,
          suffix: '%',
          onChanged: () => setState(() {}),
        ),
        switchRow(
          'Dry pack / mud pack mortar',
          _dryPack,
          (v) => setState(() => _dryPack = v),
        ),
        if (_dryPack)
          comboField(
            'Dry pack thickness (mm)',
            _thick,
            _thickPresets,
            onChanged: () => setState(() {}),
          ),
        ResultCard(
          result: _result,
          label: _label,
          onAdd: (_) => add(_result!, _label),
        ),
      ],
    );
  }
}

// ============================================================================
// PAINTING
// ============================================================================

class PaintingForm extends StatefulWidget {
  final ModelPrefill? prefill;
  const PaintingForm({super.key, this.prefill});
  @override
  State<PaintingForm> createState() => _PaintingFormState();
}

class _PaintingFormState extends State<PaintingForm> with _AddMixin {
  bool _byDims = true;
  final _l = TextEditingController(text: '6.5');
  final _w = TextEditingController(text: '5.5');
  final _area = TextEditingController();
  final _label = TextEditingController();
  int _sys = 0;

  @override
  void initState() {
    super.initState();
    final p = widget.prefill;
    if (p != null) {
      if (p.area != null) {
        _byDims = false;
        _area.text = p.area!.toStringAsFixed(2);
      }
      if (p.label != null) _label.text = p.label!;
    }
  }

  CalcResult? get _result {
    final a = AreaInput(
      byDims: _byDims,
      length: _l,
      width: _w,
      area: _area,
      onMode: (_) {},
      onChanged: () {},
    ).value;
    if (a <= 0) return null;
    return calcPainting(area: a, systemIndex: _sys);
  }

  @override
  Widget build(BuildContext context) {
    return _Fields(
      children: [
        AreaInput(
          byDims: _byDims,
          length: _l,
          width: _w,
          area: _area,
          onMode: (v) => setState(() => _byDims = v),
          onChanged: () => setState(() {}),
        ),
        dropField(
          'Paint system',
          _sys,
          List.generate(kPaintSystems.length, (i) => i),
          (i) => kPaintSystems[i].label,
          (v) => setState(() => _sys = v),
        ),
        ResultCard(
          result: _result,
          label: _label,
          onAdd: (_) => add(_result!, _label),
        ),
      ],
    );
  }
}

// ============================================================================
// CARPENTRY
// ============================================================================

class CarpentryForm extends StatefulWidget {
  const CarpentryForm({super.key});
  @override
  State<CarpentryForm> createState() => _CarpentryFormState();
}

class _CarpentryFormState extends State<CarpentryForm> with _AddMixin {
  final _l = TextEditingController(text: '6');
  final _w = TextEditingController(text: '18');
  final _label = TextEditingController();
  String _sys = 'ceiling';

  static const _systems = {
    'ceiling': 'Metal furring ceiling',
    'plywood partition': 'Plywood lumber partition',
    'metal stud': 'Metal stud wall partition',
  };

  CalcResult? get _result {
    final l = AreaInput._d(_l.text), w = AreaInput._d(_w.text);
    if (l <= 0 || w <= 0) return null;
    return calcCarpentry(length: l, width: w, system: _sys);
  }

  @override
  Widget build(BuildContext context) {
    return _Fields(
      children: [
        Row(
          children: [
            Expanded(
              child: numField(
                'Length',
                _l,
                suffix: 'm',
                onChanged: () => setState(() {}),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: numField(
                'Width',
                _w,
                suffix: 'm',
                onChanged: () => setState(() {}),
              ),
            ),
          ],
        ),
        dropField(
          'System',
          _sys,
          _systems.keys.toList(),
          (v) => _systems[v]!,
          (v) => setState(() => _sys = v),
        ),
        ResultCard(
          result: _result,
          label: _label,
          onAdd: (_) => add(_result!, _label),
        ),
      ],
    );
  }
}

// ============================================================================
// STEEL / REBAR
// ============================================================================

class SteelForm extends StatefulWidget {
  final ModelPrefill? prefill;
  const SteelForm({super.key, this.prefill});
  @override
  State<SteelForm> createState() => _SteelFormState();
}

class _SteelFormState extends State<SteelForm> with _AddMixin {
  final _member = TextEditingController(text: 'COLUMN');
  final _l = TextEditingController(text: '0.2');
  final _w = TextEditingController(text: '0.2');
  final _h = TextEditingController(text: '5');
  final _count = TextEditingController(text: '1');
  final _dia = TextEditingController(text: '12');
  final _bars = TextEditingController(text: '4');
  final _barLen = TextEditingController(text: '6');
  final _label = TextEditingController();
  String _cls = 'CLASS A (1:2:4)';
  bool _concrete = true;

  @override
  void initState() {
    super.initState();
    final p = widget.prefill;
    if (p != null) {
      if (p.side != null) {
        _l.text = p.side!.toStringAsFixed(2);
        _w.text = p.side!.toStringAsFixed(2);
      }
      if (p.height != null) _h.text = p.height!.toStringAsFixed(2);
      if (p.count != null) _count.text = '${p.count!.round()}';
      if (p.barDia != null) _dia.text = '${p.barDia!.round()}';
      if (p.barsPerMember != null) {
        _bars.text = '${p.barsPerMember!.round()}';
      }
      if (p.label != null) _label.text = p.label!;
    }
  }

  CalcResult? get _result {
    final l = AreaInput._d(_l.text),
        w = AreaInput._d(_w.text),
        h = AreaInput._d(_h.text);
    if (l <= 0 && AreaInput._d(_bars.text) <= 0) return null;
    return calcSteel(
      length: l,
      width: w,
      height: h,
      members: AreaInput._d(_count.text).round().clamp(1, 9999),
      barDiaMm: AreaInput._d(_dia.text),
      barsPerMember: AreaInput._d(_bars.text),
      barLengthM: AreaInput._d(_barLen.text),
      concreteClass: _cls,
      includeConcrete: _concrete,
      memberName: _member.text.isEmpty ? 'MEMBER' : _member.text,
    );
  }

  @override
  Widget build(BuildContext context) {
    return _Fields(
      children: [
        numField('Member name', _member, onChanged: () => setState(() {})),
        Row(
          children: [
            Expanded(
              child: numField(
                'L',
                _l,
                suffix: 'm',
                onChanged: () => setState(() {}),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: numField(
                'W',
                _w,
                suffix: 'm',
                onChanged: () => setState(() {}),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: numField(
                'H',
                _h,
                suffix: 'm',
                onChanged: () => setState(() {}),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: numField(
                'Qty',
                _count,
                suffix: 'pcs',
                onChanged: () => setState(() {}),
              ),
            ),
          ],
        ),
        Row(
          children: [
            Expanded(
              child: numField(
                'Bar dia',
                _dia,
                suffix: 'mm',
                onChanged: () => setState(() {}),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: numField(
                'Bars/member',
                _bars,
                suffix: 'pcs',
                onChanged: () => setState(() {}),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: numField(
                'Bar length',
                _barLen,
                suffix: 'm',
                onChanged: () => setState(() {}),
              ),
            ),
          ],
        ),
        switchRow(
          'Include concrete for members',
          _concrete,
          (v) => setState(() => _concrete = v),
        ),
        if (_concrete)
          dropField(
            'Concrete class',
            _cls,
            kConcreteClasses.keys.toList(),
            (v) => v,
            (v) => setState(() => _cls = v),
          ),
        ResultCard(
          result: _result,
          label: _label,
          onAdd: (_) => add(_result!, _label),
        ),
      ],
    );
  }
}

// ============================================================================
// STAIRS
// ============================================================================

class StairsForm extends StatefulWidget {
  const StairsForm({super.key});
  @override
  State<StairsForm> createState() => _StairsFormState();
}

class _StairsFormState extends State<StairsForm> with _AddMixin {
  final _rise = TextEditingController(text: '2.5');
  final _riser = TextEditingController(text: '0.175');
  final _tread = TextEditingController(text: '0.28');
  final _width = TextEditingController(text: '1.2');
  final _waist = TextEditingController(text: '100');
  final _label = TextEditingController();
  String _cls = 'CLASS A (1:2:4)';
  bool _tiles = false;
  String _tileSize = '0.60 x 0.60';

  CalcResult? get _result {
    final r = AreaInput._d(_rise.text);
    if (r <= 0) return null;
    return calcStairs(
      totalRise: r,
      riser: AreaInput._d(_riser.text),
      tread: AreaInput._d(_tread.text),
      stairWidth: AreaInput._d(_width.text),
      waistMm: AreaInput._d(_waist.text),
      concreteClass: _cls,
      tileTreads: _tiles,
      tileSize: _tileSize,
    );
  }

  @override
  Widget build(BuildContext context) {
    return _Fields(
      children: [
        Row(
          children: [
            Expanded(
              child: numField(
                'Total rise',
                _rise,
                suffix: 'm',
                onChanged: () => setState(() {}),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: numField(
                'Riser',
                _riser,
                suffix: 'm',
                onChanged: () => setState(() {}),
              ),
            ),
          ],
        ),
        Row(
          children: [
            Expanded(
              child: numField(
                'Tread',
                _tread,
                suffix: 'm',
                onChanged: () => setState(() {}),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: numField(
                'Stair width',
                _width,
                suffix: 'm',
                onChanged: () => setState(() {}),
              ),
            ),
          ],
        ),
        Row(
          children: [
            Expanded(
              child: numField(
                'Waist slab',
                _waist,
                suffix: 'mm',
                onChanged: () => setState(() {}),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: dropField(
                'Class',
                _cls,
                kConcreteClasses.keys.toList(),
                (v) => v.split(' ').take(2).join(' '),
                (v) => setState(() => _cls = v),
              ),
            ),
          ],
        ),
        switchRow('Tile the treads', _tiles, (v) => setState(() => _tiles = v)),
        if (_tiles)
          dropField(
            'Tile size',
            _tileSize,
            kTileSizes.keys.toList(),
            (v) => v,
            (v) => setState(() => _tileSize = v),
          ),
        ResultCard(
          result: _result,
          label: _label,
          onAdd: (_) => add(_result!, _label),
        ),
      ],
    );
  }
}

// ============================================================================
// MANUAL ITEM
// ============================================================================

class ManualForm extends StatefulWidget {
  const ManualForm({super.key});
  @override
  State<ManualForm> createState() => _ManualFormState();
}

class _ManualFormState extends State<ManualForm> with _AddMixin {
  final _qty = TextEditingController(text: '1');
  final _label = TextEditingController();
  final _section = TextEditingController();
  MaterialPrice? _picked;
  final _price = TextEditingController();

  @override
  Widget build(BuildContext context) {
    final qty = AreaInput._d(_qty.text);
    final p = AreaInput._d(_price.text);
    final line = _picked == null
        ? null
        : ComputedLine(
            _picked!.name,
            qty <= 0 ? 1 : qty,
            _picked!.unit,
            _picked!.name,
            p > 0 ? p : null,
          );
    final result = line == null
        ? null
        : CalcResult(
            _section.text.trim().isEmpty
                ? 'GENERAL REQUIREMENTS'
                : _section.text.trim().toUpperCase(),
            [line],
          );

    return _Fields(
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Autocomplete<MaterialPrice>(
            optionsBuilder: (v) {
              final q = v.text.toUpperCase();
              if (q.isEmpty) return kPriceDb.take(20);
              return kPriceDb.where((m) => m.name.toUpperCase().contains(q));
            },
            displayStringForOption: (m) => m.name,
            onSelected: (m) => setState(() => _picked = m),
            fieldViewBuilder: (ctx, ctrl, focus, onSubmit) => TextField(
              controller: ctrl,
              focusNode: focus,
              decoration: const InputDecoration(
                labelText: 'Search material',
                hintText: 'type to search the price list',
                prefixIcon: Icon(Icons.search, size: 18),
              ),
              style: const TextStyle(fontSize: 12.5),
            ),
            optionsViewBuilder: (ctx, onSel, opts) => Align(
              alignment: Alignment.topLeft,
              child: Material(
                elevation: 4,
                borderRadius: BorderRadius.circular(8),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    maxHeight: 240,
                    maxWidth: 360,
                  ),
                  child: ListView.builder(
                    padding: EdgeInsets.zero,
                    shrinkWrap: true,
                    itemCount: opts.length,
                    itemBuilder: (_, i) {
                      final m = opts.elementAt(i);
                      return ListTile(
                        dense: true,
                        title: Text(
                          m.name,
                          style: const TextStyle(fontSize: 12),
                        ),
                        subtitle: Text(
                          '${m.category} · ₱${m.price} / ${m.unit}',
                          style: const TextStyle(fontSize: 10.5),
                        ),
                        onTap: () => onSel(m),
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        ),
        if (_picked != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0xFFDCE8F5),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _picked!.name,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Text(
                    '₱${_picked!.price}/${_picked!.unit}',
                    style: const TextStyle(fontSize: 12),
                  ),
                ],
              ),
            ),
          ),
        Row(
          children: [
            Expanded(
              child: numField(
                'Quantity',
                _qty,
                onChanged: () => setState(() {}),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: numField(
                'Unit price (optional)',
                _price,
                suffix: '₱',
                onChanged: () => setState(() {}),
              ),
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: TextField(
            controller: _section,
            decoration: const InputDecoration(
              labelText: 'Section (optional)',
              hintText: 'default: GENERAL REQUIREMENTS',
            ),
            style: const TextStyle(fontSize: 13),
            textCapitalization: TextCapitalization.characters,
          ),
        ),
        ResultCard(
          result: result,
          label: _label,
          onAdd: (_) => add(result!, _label),
        ),
      ],
    );
  }
}
