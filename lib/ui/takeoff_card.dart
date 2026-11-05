import 'package:flutter/material.dart';

import '../model3d.dart';
import '../state.dart';
import '../structural.dart';
import '../takeoff.dart';

/// A request from the takeoff card to open a work form pre-filled
/// with model-measured quantities — the user reviews/edits every
/// property (CHB, mortar, class, system…) before ADD TO BOQ.
class ModelPrefill {
  /// 'concrete' | 'masonry' | 'tiles' | 'painting' | 'steel'
  final String kind;
  final double? volume, area, aperture, side, height, count;
  final double? barDia, barsPerMember;
  final String? chb, label;
  const ModelPrefill(
    this.kind, {
    this.volume,
    this.area,
    this.aperture,
    this.side,
    this.height,
    this.count,
    this.barDia,
    this.barsPerMember,
    this.chb,
    this.label,
  });
}

/// MODEL TAKEOFF: measured quantities of a 3D model. Work buttons
/// open the matching form pre-filled from the model; ADD ALL inserts
/// all packages with default parameters.
class TakeoffCard extends StatefulWidget {
  final void Function(ModelPrefill) onPrefill;
  const TakeoffCard({super.key, required this.onPrefill});
  @override
  State<TakeoffCard> createState() => _TakeoffCardState();
}

class _TakeoffCardState extends State<TakeoffCard> {
  bool _open = true;
  bool _bothSides = true;
  String? _modelId;

  Model3d? get _model {
    if (est.models.isEmpty) return null;
    for (final m in est.models) {
      if (m.id == _modelId) return m;
    }
    return est.models.first;
  }

  void _insert(TakeoffWork? w) {
    if (w == null) return;
    final n = insertTakeoffWork(
      w,
      (s, l, items) => est.addWork(sectionTitle: s, groupLabel: l, items: items),
    );
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('$n item(s) added from model'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  String _f(double v) => v.toStringAsFixed(2);

  /// Prefill for the dominant wall-thickness group (largest gross
  /// area) — its CHB size and its own opening deduction.
  ModelPrefill? _masonryPrefill(Takeoff t) {
    final k = t.mainThk;
    if (k == null) return null;
    final g = t.masonryGross(k);
    return ModelPrefill(
      'masonry',
      area: g,
      aperture: t.apertureFor(k),
      chb: chbForThk(k),
      label: '3D MODEL - ${_f(g - t.apertureFor(k))} SQ.M NET WALL',
    );
  }

  ModelPrefill? _paintPrefill(Takeoff t) {
    if (t.wallNet <= 0) return null;
    final a = t.wallNet * (_bothSides ? 2 : 1);
    return ModelPrefill(
      'painting',
      area: a,
      label: '3D MODEL - ${_f(a)} SQ.M WALL PAINT',
    );
  }

  ModelPrefill? _concretePrefill(Takeoff t) => t.concreteVol <= 0
      ? null
      : ModelPrefill(
          'concrete',
          volume: t.concreteVol,
          label: '3D MODEL - ${_f(t.concreteVol)} CU.M CONCRETE',
        );

  ModelPrefill? _tilesPrefill(Takeoff t) => t.floorArea <= 0
      ? null
      : ModelPrefill(
          'tiles',
          area: t.floorArea,
          label: '3D MODEL - ${_f(t.floorArea)} SQ.M FLOOR TILES',
        );

  ModelPrefill? _steelPrefill(Takeoff t) {
    if (t.colCount <= 0) return null;
    final s = columnSched(t.colSec, t.colHgt);
    return ModelPrefill(
      'steel',
      side: t.colSec,
      height: t.colHgt,
      count: t.colCount.toDouble(),
      barDia: s.main.diaMm,
      barsPerMember: s.main.count.toDouble(),
      label: '3D MODEL - ${t.colCount} COLUMN(S) ${s.main.label}',
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: est,
      builder: (context, _) {
        final m = _model;
        if (m == null) return const SizedBox.shrink();
        final t = modelTakeoff(m);
        final cs = Theme.of(context).colorScheme;
        const lab = TextStyle(fontSize: 11.5, color: Color(0xFF475569));
        const val = TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700);
        Widget row(String k, String v) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 1.5),
          child: Row(
            children: [
              Expanded(child: Text(k, style: lab)),
              Text(v, style: val),
            ],
          ),
        );
        Widget btn(String label, IconData icon, ModelPrefill? p) =>
            OutlinedButton.icon(
              key: ValueKey('takeoff-$label'),
              onPressed: p == null ? null : () => widget.onPrefill(p),
              icon: Icon(icon, size: 15),
              label: Text(label, style: const TextStyle(fontSize: 11.5)),
            );
        return Container(
          margin: const EdgeInsets.fromLTRB(10, 10, 10, 0),
          decoration: BoxDecoration(
            color: const Color(0xFFF1F5F9),
            border: Border.all(color: const Color(0xFFCBD5E1)),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              InkWell(
                key: const ValueKey('takeoff-head'),
                onTap: () => setState(() => _open = !_open),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
                  child: Row(
                    children: [
                      Icon(Icons.view_in_ar, size: 16, color: cs.primary),
                      const SizedBox(width: 6),
                      const Expanded(
                        child: Text(
                          'FROM 3D MODEL',
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 11.5,
                            letterSpacing: 1,
                            color: Color(0xFF475569),
                          ),
                        ),
                      ),
                      Icon(_open ? Icons.expand_less : Icons.expand_more, size: 18),
                    ],
                  ),
                ),
              ),
              if (_open)
                Padding(
                  padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (est.models.length > 1)
                        DropdownButton<String>(
                          isExpanded: true,
                          isDense: true,
                          value: m.id,
                          items: [
                            for (final x in est.models)
                              DropdownMenuItem(
                                value: x.id,
                                child: Text(x.name, style: const TextStyle(fontSize: 12)),
                              ),
                          ],
                          onChanged: (v) => setState(() => _modelId = v),
                        ),
                      if (t.isEmpty)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 6),
                          child: Text(
                            'Draw walls, slabs or columns in the 3D MODEL tab to measure them here.',
                            style: lab,
                          ),
                        )
                      else ...[
                        row('Walls', '${t.wallLen.toStringAsFixed(2)} m'),
                        row(
                          'Wall area',
                          '${t.wallGross.toStringAsFixed(2)} - ${t.aperture.toStringAsFixed(2)} = ${t.wallNet.toStringAsFixed(2)} sq.m',
                        ),
                        row('Doors / windows', '${t.doors} / ${t.windows}'),
                        row('Floor area', '${t.floorArea.toStringAsFixed(2)} sq.m'),
                        row(
                          'Concrete (slab+col+ftg+beam)',
                          '${t.concreteVol.toStringAsFixed(2)} cu.m',
                        ),
                        if (t.colCount > 0) row('Columns', '${t.colCount}'),
                        if (t.footCount > 0)
                          row(
                            'Footings',
                            '${t.footCount} × ${t.footW.toStringAsFixed(1)}×${t.footW.toStringAsFixed(1)}',
                          ),
                        if (t.tieLen + t.bondLen > 0)
                          row(
                            'Wall beams',
                            'tie ${t.tieLen.toStringAsFixed(1)}m + bond ${t.bondLen.toStringAsFixed(1)}m',
                          ),
                        if (t.slabs.isNotEmpty)
                          row(
                            'Slab type',
                            t.slabs
                                .map((s) =>
                                    '${s.$2 ? 'ONE-WAY' : 'TWO-WAY'}${s.$4 + 1e-3 < s.$3 ? ' ⚠<${s.$3.toStringAsFixed(2)}m' : ''}')
                                .join(', '),
                          ),
                        if (t.trusses > 0) ...[
                          row('Trusses', '${t.trusses}'),
                          row(
                            'Purlins (${m.roof.purlinSpace}m o.c.)',
                            '${t.purlinRows} runs → ${t.purlinPcs} pcs 6m',
                          ),
                          row('Roof area', '${t.roofArea.toStringAsFixed(2)} sq.m'),
                        ],
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            SizedBox(
                              height: 24,
                              width: 24,
                              child: Checkbox(
                                value: _bothSides,
                                onChanged: (v) => setState(() => _bothSides = v ?? true),
                              ),
                            ),
                            const SizedBox(width: 6),
                            const Text('Paint both wall faces', style: lab),
                          ],
                        ),
                        const SizedBox(height: 2),
                        const Text(
                          'Tap a work to review quantities & properties, or:',
                          style: TextStyle(fontSize: 10.5, color: Color(0xFF94A3B8)),
                        ),
                        const SizedBox(height: 6),
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: [
                            btn('Masonry', Icons.domain, _masonryPrefill(t)),
                            btn('Painting', Icons.format_paint, _paintPrefill(t)),
                            btn('Concreting', Icons.foundation, _concretePrefill(t)),
                            btn('Tiling', Icons.grid_on, _tilesPrefill(t)),
                            btn('Steel', Icons.construction, _steelPrefill(t)),
                            if (t.trusses > 0)
                              OutlinedButton.icon(
                                key: const ValueKey('takeoff-Roofing'),
                                onPressed: () => _insert(takeoffRoofing(m, t)),
                                icon: const Icon(Icons.roofing, size: 15),
                                label: const Text('Roofing', style: TextStyle(fontSize: 11.5)),
                              ),
                            FilledButton.icon(
                              key: const ValueKey('takeoff-all'),
                              onPressed: () {
                                for (final w in [
                                  takeoffConcrete(t),
                                  takeoffMasonry(t),
                                  takeoffTiles(t),
                                  takeoffPainting(t, bothSides: _bothSides),
                                  takeoffSteelSched(m),
                                  takeoffRoofing(m, t),
                                ]) {
                                  _insert(w);
                                }
                              },
                              icon: const Icon(Icons.auto_awesome, size: 15),
                              label: const Text('Add all', style: TextStyle(fontSize: 11.5)),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}
