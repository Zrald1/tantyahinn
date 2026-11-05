part of 'model_view.dart';

// ignore_for_file: invalid_use_of_protected_member

// Split from model_view.dart (1k-line cap): right-panel
// inspector, tab badges, block library and per-part editors.

extension _MvInspect on _ModelViewState {
  Widget _inspector(ColorScheme cs) {
    return Container(
      width: 296,
      color: const Color(0xFFF8FAFC),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 10, 10, 0),
            child: SegmentedButton<int>(
              segments: [
                ButtonSegment(
                  value: 0,
                  icon: const Icon(Icons.tune, size: 15),
                  label: _tabBadge(cs, 'Inspect', _selText),
                ),
                ButtonSegment(
                  value: 2,
                  icon: const Icon(Icons.list_alt, size: 15),
                  label: _tabBadge(cs, 'Props', null),
                ),
                ButtonSegment(
                  value: 1,
                  icon: const Icon(Icons.category_outlined, size: 15),
                  label: _tabBadge(cs, 'Blocks', _blkDef.name),
                ),
              ],
              selected: {_rightTab},
              onSelectionChanged: (s) => setState(() => _rightTab = s.first),
              showSelectedIcon: false,
              style: ButtonStyle(
                visualDensity: VisualDensity.compact,
                padding: const WidgetStatePropertyAll(
                  EdgeInsets.symmetric(horizontal: 6),
                ),
                textStyle: const WidgetStatePropertyAll(
                  TextStyle(fontSize: 11.5),
                ),
              ),
            ),
          ),
          Expanded(
            child: _rightTab == 0
                ? _properties(cs)
                : _rightTab == 2
                ? _objectList(cs)
                : _library(cs),
          ),
        ],
      ),
    );
  }

  /// Tab label + state badge (task 19): the Inspect tab carries the
  /// selected part's name, Blocks always carries the armed piece —
  /// SketchUp-tray-style state visible without switching tabs.
  Widget _tabBadge(ColorScheme cs, String title, String? badge) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(title),
        if (badge != null)
          Container(
            margin: const EdgeInsets.only(top: 1),
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
            constraints: const BoxConstraints(maxWidth: 84),
            decoration: BoxDecoration(
              color: cs.primary.withValues(alpha: .12),
              borderRadius: BorderRadius.circular(5),
            ),
            child: Text(
              badge,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 8.5,
                fontWeight: FontWeight.w600,
                color: cs.primary,
              ),
            ),
          ),
      ],
    );
  }

  /// The CAD-block library — grouped like a dwgmodels palette, with
  /// drawn thumbnails. Tapping arms the block tool with that piece;
  /// the armed piece stays highlighted so the user always sees what
  /// the next click will place.
  Widget _library(ColorScheme cs) {
    final q = _libSearch.text.trim().toLowerCase();
    final groups = <String, List<CadBlock>>{};
    for (final b in [...kCadBlocks, ...customCadBlocks]) {
      if (q.isNotEmpty && !b.name.toLowerCase().contains(q)) continue;
      groups.putIfAbsent(b.cat, () => []).add(b);
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 10, 10, 0),
          child: TextField(
            key: const Key('lib-search'),
            controller: _libSearch,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              isDense: true,
              hintText: 'Search blocks…',
              prefixIcon: Icon(Icons.search, size: 18),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 6, 10, 0),
          child: OutlinedButton.icon(
            key: const Key('import-obj'),
            onPressed: _importObj,
            icon: const Icon(Icons.download_outlined, size: 16),
            label: const Text(
              'Import 3D model (.obj/.stl/.ifc)',
              style: TextStyle(fontSize: 11.5),
            ),
            style: OutlinedButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 8),
            ),
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 16),
            children: [
              for (final g in groups.entries) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(6, 8, 6, 4),
                  child: Text(
                    g.key.toUpperCase(),
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.1,
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                ),
                for (final b in g.value) _libRow(b, cs),
              ],
              if (groups.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    'No blocks match.',
                    style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _libRow(CadBlock b, ColorScheme cs) {
    final on = _tool == _MTool.block && _blkDef == b;
    // tap arms the block tool; a LEFTWARD drag carries the block onto
    // a canvas and drops it placed (horizontal affinity keeps the
    // vertical list scroll free)
    return Draggable<CadBlock>(
      data: b,
      affinity: Axis.horizontal,
      dragAnchorStrategy: pointerDragAnchorStrategy,
      onDragStarted: Tooltip.dismissAllToolTips,
      feedback: Material(
        color: Colors.transparent,
        child: Container(
          width: 64,
          height: 48,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.92),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: cs.primary, width: 1.4),
            boxShadow: const [
              BoxShadow(blurRadius: 10, color: Color(0x33000000)),
            ],
          ),
          child: _blockMeshThumb(
            b,
            // openings AND trusses are profile objects — the /\ web
            // layout is unreadable squashed into an iso wedge
            b.opening || isTrussDef(b.id)
                ? _BlockView.front
                : _BlockView.iso,
            w: 64,
            h: 48,
          ),
        ),
      ),
      childWhenDragging: Opacity(opacity: 0.4, child: _libRowBody(b, on, cs)),
      child: _blockTip(
        b,
        cs,
        child: InkWell(
          key: ValueKey('lib-${b.id}'),
          onTap: () => setState(() {
            _blkDef = b;
            _tool = _MTool.block;
          }),
          child: _libRowBody(b, on, cs),
        ),
      ),
    );
  }

  Widget _libRowBody(CadBlock b, bool on, ColorScheme cs) => Container(
    margin: const EdgeInsets.symmetric(vertical: 1),
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
    decoration: BoxDecoration(
      color: on ? cs.primary.withValues(alpha: 0.1) : null,
      borderRadius: BorderRadius.circular(8),
      border: on ? Border.all(color: cs.primary, width: 1.4) : null,
    ),
    child: Row(
      children: [
        // openings + trusses read clearest head-on (FRONT); furniture
        // isos. _blockMeshThumb clips + repaint-boundaries itself
        _blockMeshThumb(
          b,
          b.opening || isTrussDef(b.id)
              ? _BlockView.front
              : _BlockView.iso,
          w: 52,
          h: 40,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                b.name,
                style: const TextStyle(fontSize: 12),
                overflow: TextOverflow.ellipsis,
              ),
              Text(
                _libDims(b),
                style: TextStyle(fontSize: 10, color: cs.onSurfaceVariant),
              ),
            ],
          ),
        ),
        if (on) Icon(Icons.check_circle, size: 16, color: cs.primary),
      ],
    ),
  );

  Widget _properties(ColorScheme cs) {
    final m = _sel, v = _vol, wl = _wallSel, bl = _blkSel;
    if (m == null) {
      return Center(
        child: Text(
          'Select or create a model.',
          style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
        ),
      );
    }
    // SketchUp Entity-Info convention: the inspector shows WHAT is
    // selected — a part's properties, or the model summary when the
    // selection is empty
    final partSel = wl != null || bl != null || v != null;
    return ListView(
      padding: const EdgeInsets.all(14),
      children: [
        if (partSel) ...[
          InkWell(
            onTap: () => setState(_clearSel),
            borderRadius: BorderRadius.circular(6),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  Icon(
                    Icons.chevron_left,
                    size: 18,
                    color: cs.onSurfaceVariant,
                  ),
                  const SizedBox(width: 2),
                  Text(
                    'MODEL SUMMARY',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.1,
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
        ] else
          ..._modelSummary(cs, m),
        if (wl != null)
          ..._wallInspector(cs, wl)
        else if (bl != null)
          ..._blkInspector(cs, bl)
        else if (v != null)
          ..._volInspector(cs, v),
        const Divider(height: 28),
        FilledButton.icon(
          icon: const Icon(Icons.article_outlined, size: 17),
          label: const Text('GENERATE DRAWING'),
          onPressed: _generate,
        ),
        const SizedBox(height: 6),
        Text(
          'Adds a floor plan + roof + 4 elevations sheet to the '
          'DRAWINGS tab (regenerates on every click).',
          style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
        ),
      ],
    );
  }

  /// PROPERTIES tab — every object in the drawing as an expandable
  /// row: walls, volumes, blocks. Tapping a tile selects the object
  /// on BOTH canvases and drops it open to reveal the same property
  /// editors the Inspect tab uses — a Revit-style object browser.
  /// Compact numeric field for the Props accordion - two fit side by
  /// side in the 296px panel. Keyed per object+label so the field
  /// keeps focus while typing (rebuilds never remount it).
  Widget _pf(
    String id,
    String label,
    double cur,
    void Function(double) set, {
    bool Function(double)? ok,
  }) {
    return Expanded(
      child: TextFormField(
        key: ValueKey('$id-$label'),
        initialValue: cur.toStringAsFixed(2),
        keyboardType: const TextInputType.numberWithOptions(
          decimal: true,
          signed: true,
        ),
        style: const TextStyle(fontSize: 12.5),
        decoration: InputDecoration(labelText: label, isDense: true),
        onChanged: (s) {
          final x = double.tryParse(s);
          if (x != null && (ok == null || ok(x))) {
            _pushUndoTick('$id-$label');
            setState(() => set(x));
            est.update();
          }
        },
      ),
    );
  }

  Widget _pair(Widget a, Widget b) => Padding(
    padding: const EdgeInsets.only(top: 8),
    child: Row(children: [a, const SizedBox(width: 8), b]),
  );

  Widget _pRead(String label, String value) => Expanded(
    child: InputDecorator(
      decoration: InputDecoration(
        labelText: label,
        isDense: true,
        enabled: false,
      ),
      child: Text(value, style: const TextStyle(fontSize: 12.5)),
    ),
  );

  /// Compact dropdown for the props panel — same density as [_pf].
  Widget _pdd<T>(
    String id,
    String label,
    T cur,
    List<(T, String)> items,
    void Function(T) set,
  ) {
    return Expanded(
      child: DropdownButtonFormField<T>(
        key: ValueKey('$id-$label'),
        initialValue: cur,
        isDense: true,
        isExpanded: true,
        decoration: InputDecoration(labelText: label, isDense: true),
        style: const TextStyle(fontSize: 12.5),
        items: [
          for (final it in items)
            DropdownMenuItem<T>(
              value: it.$1,
              child: Text(it.$2, overflow: TextOverflow.ellipsis),
            ),
        ],
        onChanged: (v) {
          if (v != null) {
            _pushUndo();
            setState(() => set(v));
            est.update();
          }
        },
      ),
    );
  }

  /// Replicates the truss along the ridge (perpendicular to its span)
  /// at the RoofSpec truss spacing, stopping when the next position no
  /// longer seats on two distinct walls — the natural end of the plates.
  void _arrayTrusses(Model3d m, Block3d seed, CadBlock def) {
    final sp = m.roof.trussSpacing > 0 ? m.roof.trussSpacing : 1.5;
    final span = def.w * seed.sx * seed.scale;
    final rd = Offset(-math.sin(seed.rot), math.cos(seed.rot));
    var placed = 0;
    _pushUndo(); // the whole array is ONE undo step
    setState(() {
      for (final sgn in [1.0, -1.0]) {
        for (var k = 1; k <= 24; k++) {
          final c = Offset(seed.x, seed.y) + rd * (sgn * k * sp);
          if (m.blocks.any(
            (q) => isTrussDef(q.def) && (Offset(q.x, q.y) - c).distance < sp * 0.6,
          )) {
            continue;
          }
          final seat = seatTrussOnWalls(m, c, seed.rot, span);
          // cos-compare: truss orientation is modulo pi — a seat
          // returned at seed.rot+pi is the SAME truss, not a flip
          if (seat == null || math.cos(seat.$2 - seed.rot).abs() < 0.94) {
            break;
          }
          m.blocks.add(
            Block3d(
              def: seed.def,
              x: seat.$1.dx,
              y: seat.$1.dy,
              rot: seat.$2,
              scale: seed.scale,
              // out-to-out: fit each bay's span to its bearing pair
              sx: seat.$4 > 0
                  ? trussFitSx(seed.scale, def.w, seat.$4)
                  : seed.sx,
              sy: seed.sy,
              sz: seed.sz,
              bz: seat.$3,
              tint: seed.tint,
              panels: seed.panels,
            ),
          );
          placed++;
        }
      }
    });
    est.update();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          placed > 0
              ? '$placed truss(es) added along the ridge'
              : 'No free wall seats found along the ridge',
        ),
      ),
    );
  }

  Widget _pHead(ColorScheme cs, String s) => Padding(
    padding: const EdgeInsets.only(top: 12, bottom: 2),
    child: Align(
      alignment: Alignment.centerLeft,
      child: Text(
        s,
        style: TextStyle(
          fontSize: 9.5,
          fontWeight: FontWeight.w700,
          letterSpacing: 1,
          color: cs.onSurfaceVariant,
        ),
      ),
    ),
  );

  Widget _swatches(
    ColorScheme cs,
    int cur,
    List<int> colors,
    void Function(int) pick,
  ) => Wrap(
    spacing: 6,
    runSpacing: 6,
    children: [
      for (final c in colors)
        InkWell(
          onTap: () => setState(() {
            if (cur != c) _pushUndo();
            pick(c);
            est.update();
          }),
          child: Container(
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              color: c == 0 ? Colors.white : Color(c),
              shape: BoxShape.circle,
              border: Border.all(
                width: cur == c ? 2.4 : 1,
                color: cur == c ? cs.primary : Colors.black26,
              ),
            ),
          ),
        ),
    ],
  );

  /// Compact toggle row for structural options (tie/bond beam,
  /// column footing) in the part inspectors.
  Widget _pSwitch(String label, bool value, void Function(bool) set) {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: const TextStyle(fontSize: 12, color: Color(0xFF334155)),
            ),
          ),
          SizedBox(
            height: 26,
            child: Switch(
              value: value,
              onChanged: (v) {
                _pushUndo();
                setState(() => set(v));
                est.update();
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _delBtn(ColorScheme cs, String label) => Padding(
    padding: const EdgeInsets.only(top: 12),
    child: SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        icon: const Icon(Icons.delete_outline, size: 16),
        label: Text(label),
        style: OutlinedButton.styleFrom(
          foregroundColor: cs.error,
          padding: const EdgeInsets.symmetric(vertical: 6),
        ),
        onPressed: _delSel,
      ),
    ),
  );

  List<Widget> _wallBody(ColorScheme cs, Wall3d w) {
    final n = w.pts.length;
    final id = w.id;
    return [
      TextFormField(
        key: ValueKey('$id-pn'),
        initialValue: w.name,
        style: const TextStyle(fontSize: 12.5),
        decoration: const InputDecoration(labelText: 'Name', isDense: true),
        onChanged: (s) {
          _pushUndoTick('$id-pn');
          w.name = s;
          est.update();
        },
      ),
      _pHead(cs, 'SIZE'),
      _pair(
        _pf(
          id,
          'Thickness (m)',
          w.thickness,
          (x) => w.thickness = x,
          ok: (x) => x > 0,
        ),
        _pf(id, 'Height (m)', w.height, (x) => w.height = x, ok: (x) => x > 0),
      ),
      _pair(
        _pf(id, 'Base (m)', w.base, (x) => w.base = x),
        _pRead('Length (m)', _fmtNum(w.length)),
      ),
      _pHead(cs, 'ENDPOINTS - ${w.segs} SEGMENT${w.segs == 1 ? '' : 'S'}'),
      _pair(
        _pf(id, 'Start X', w.pts[0], (x) => w.pts[0] = x),
        _pf(id, 'Start Y', w.pts[1], (x) => w.pts[1] = x),
      ),
      _pair(
        _pf(id, 'End X', w.pts[n - 2], (x) => w.pts[n - 2] = x),
        _pf(id, 'End Y', w.pts[n - 1], (x) => w.pts[n - 1] = x),
      ),
      _pHead(cs, 'STRUCTURE (NSCP 2015)'),
      _pSwitch('Tie beam below (0.20m RC)', w.tieBeam, (v) => w.tieBeam = v),
      _pSwitch('Bond beam above (0.20m RC)', w.bondBeam, (v) => w.bondBeam = v),
      if (w.tieBeam || w.bondBeam)
        _pRead(
          'Beam sched',
          '4-12mm + 10mm st @${(beamSched(w.thickness, 0.20, w.length).tieSpacing * 100).round()}cm',
        ),
      _pHead(cs, 'COLOR'),
      _swatches(cs, w.argb, _palette, (c) => w.argb = c),
      _delBtn(cs, 'Delete wall'),
    ];
  }

  List<Widget> _volBody(ColorScheme cs, Volume3d v) {
    final id = v.id;
    return [
      TextFormField(
        key: ValueKey('$id-pn'),
        initialValue: v.name,
        style: const TextStyle(fontSize: 12.5),
        decoration: const InputDecoration(labelText: 'Name', isDense: true),
        onChanged: (s) {
          _pushUndoTick('$id-pn');
          v.name = s;
          est.update();
        },
      ),
      _pHead(cs, 'SIZE'),
      _pair(
        _pf(id, 'Height (m)', v.height, (x) => v.height = x, ok: (x) => x > 0),
        _pf(id, 'Base (m)', v.base, (x) => v.base = x),
      ),
      _pair(
        _pRead('Area (m2)', _fmtNum(v.area)),
        _pRead('Corners', '${v.corners}'),
      ),
      if (v.height <= 0.5) ...[
        _pHead(cs, 'SLAB (NSCP 2015)'),
        Builder(
          builder: (_) {
            final b = v.bounds;
            final long = math.max(b.$3 - b.$1, b.$4 - b.$2);
            final short = math.max(math.min(b.$3 - b.$1, b.$4 - b.$2), 1e-6);
            final t = slabType(long, short);
            final minT = slabMinThk(t, short);
            final ok = v.height + 1e-3 >= minT;
            return _pair(
              _pRead(
                'Type',
                t == SlabType.oneWay
                    ? 'ONE-WAY (${(long / short).toStringAsFixed(1)}:1)'
                    : 'TWO-WAY (${(long / short).toStringAsFixed(1)}:1)',
              ),
              _pRead(
                'Min thk',
                ok
                    ? '${minT.toStringAsFixed(2)}m ✓'
                    : '${minT.toStringAsFixed(2)}m ⚠ under',
              ),
            );
          },
        ),
      ],
      _pHead(cs, 'COLOR'),
      _swatches(cs, v.argb, _palette, (c) => v.argb = c),
      _delBtn(cs, 'Delete volume'),
    ];
  }

  List<Widget> _blkBody(ColorScheme cs, Block3d b) {
    final def = cadBlock(b.def);
    final id = b.id;
    final box = def == null ? null : blockLocalBox(def);
    return [
      _stat('Symbol', def?.name ?? b.def),
      if (def != null) _stat('Category', def.cat),
      _pHead(cs, 'POSITION'),
      _pair(
        _pf(id, 'X (m)', b.x, (x) => b.x = x),
        _pf(id, 'Y (m)', b.y, (x) => b.y = x),
      ),
      _pair(
        _pf(id, 'Rotation (deg)', b.rot * 180 / math.pi, (x) {
          b.rot = x * math.pi / 180;
          _blkRot = b.rot;
        }),
        _pf(id, 'Lift (m)', b.bz, (x) => b.bz = x),
      ),
      if (box != null) ...[
        _pHead(cs, 'SIZE'),
        _pair(
          _pf(
            id,
            'Width (m)',
            (box[3] - box[0]) * b.sx * b.scale,
            (x) => b.sx = x / ((box[3] - box[0]) * b.scale),
            ok: (x) => x > 0,
          ),
          _pf(
            id,
            'Depth (m)',
            (box[4] - box[1]) * b.sy * b.scale,
            (x) => b.sy = x / ((box[4] - box[1]) * b.scale),
            ok: (x) => x > 0,
          ),
        ),
        _pair(
          _pf(
            id,
            'Height (m)',
            (box[5] - box[2]) * b.sz * b.scale,
            (x) => b.sz = x / ((box[5] - box[2]) * b.scale),
            ok: (x) => x > 0,
          ),
          _pf(id, 'Scale', b.scale, (x) => b.scale = x, ok: (x) => x > 0),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            icon: const Icon(Icons.restart_alt, size: 15),
            label: const Text('Reset size', style: TextStyle(fontSize: 11)),
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 6),
            ),
            onPressed: () {
              _pushUndo();
              setState(() {
                b.sx = b.sy = b.sz = 1;
                b.bz = 0;
              });
              est.update();
            },
          ),
        ),
        _pHead(cs, 'MATERIAL'),
        _swatches(cs, b.tint, const [
          0x00000000,
          0xFFFFFFFF,
          0xFFECEFF1,
          0xFF8D6E63,
          0xFF5D4037,
          0xFF78909C,
          0xFF37474F,
          0xFFEF5350,
          0xFFFFA726,
          0xFF66BB6A,
          0xFF2E7D32,
          0xFF42A5F5,
          0xFF1E3A8A,
          0xFFAB47BC,
          0xFFF9A825,
          0xFF212121,
        ], (t) => b.tint = t),
      ],
      if (b.def == 'col-sq' || b.def == 'col-rd') ...[
        _pHead(cs, 'STRUCTURE (NSCP 2015)'),
        _pSwitch('Isolated square footing', b.footing, (v) => b.footing = v),
        if (b.footing) ...[
          _pair(
            _pf(
              b.id,
              'Side (m, 0=auto)',
              b.footW,
              (x) => b.footW = x,
              ok: (x) => x == 0 || x >= 0.5,
            ),
            _pf(
              b.id,
              'Depth (m, 0=auto)',
              b.footD,
              (x) => b.footD = x,
              ok: (x) => x >= 0,
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 4, 14, 0),
            child: Wrap(
              spacing: 4,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                const Text(
                  'NSCP 305-1',
                  style: TextStyle(fontSize: 10, color: Color(0xFF64748B)),
                ),
                for (final e in [
                  ('AUTO', 0.0),
                  ('1F·0.30', 0.30),
                  ('2F·0.45', 0.45),
                  ('3F·0.60', 0.60),
                ])
                  InkWell(
                    onTap: () {
                      if (b.footD == e.$2) return;
                      _pushUndo();
                      setState(() => b.footD = e.$2);
                      est.update();
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 7, vertical: 3),
                      decoration: BoxDecoration(
                        color: (e.$2 == 0 ? b.footD == 0 : b.footD == e.$2)
                            ? cs.primaryContainer
                            : cs.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(9),
                        border: Border.all(
                          color: (e.$2 == 0 ? b.footD == 0 : b.footD == e.$2)
                              ? cs.primary
                              : Colors.black26,
                        ),
                      ),
                      child: Text(
                        e.$1,
                        style: const TextStyle(fontSize: 10),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Builder(
            builder: (_) {
              final m = _sel!;
              final f = footingFor(def!.w * b.sx * b.scale, b.footW);
              return _pair(
                _pRead(
                  'Footing',
                  '${f.w.toStringAsFixed(1)}×${f.w.toStringAsFixed(1)}×${f.t.toStringAsFixed(2)} @${blockFootingDepth(m, b).toStringAsFixed(2)}m',
                ),
                _pRead(
                  'Rebar',
                  '${f.bars.count}-${f.bars.diaMm.round()}mm B/W',
                ),
              );
            },
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 2, 14, 4),
            child: SizedBox(
              width: double.infinity,
              child: TextButton.icon(
                icon: const Icon(Icons.copy_all, size: 15),
                label: const Text(
                  'Apply footing to all columns',
                  style: TextStyle(fontSize: 11.5),
                ),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                ),
                onPressed: () {
                  // balance: every stack-LOWEST column gets a footing —
                  // same rule as the design calc's footing-all fix
                  // (upper columns of a stack never carry pads)
                  final m = _sel;
                  if (m == null) return;
                  _pushUndo(); // mass footing pass = one undo step
                  setState(() {
                    for (final q in m.blocks) {
                      if (q.def != 'col-sq' && q.def != 'col-rd') {
                        continue;
                      }
                      var stacked = false;
                      for (final r in m.blocks) {
                        if (r != q &&
                            (r.def == 'col-sq' || r.def == 'col-rd') &&
                            r.bz < q.bz - 0.3 &&
                            (Offset(r.x, r.y) - Offset(q.x, q.y)).distance <
                                0.4) {
                          stacked = true;
                        }
                      }
                      if (!stacked) {
                        q.footing = true;
                        q.footW = b.footW;
                        q.footD = b.footD;
                      }
                    }
                  });
                  est.update();
                },
              ),
            ),
          ),
        ],
      ],
      if (isTrussDef(b.def)) ...[
        _pHead(cs, 'TRUSS'),
        if (b.def == 'truss' || b.def == 'truss-dbl')
          _pair(
            _pf(
              b.id,
              'Web bays (0=auto→${trussPanelCount(b, cadBlock(b.def)!)})',
              b.panels.toDouble(),
              (x) => b.panels = x.round(),
              ok: (x) => x == 0 || (x >= 2 && x <= 12),
            ),
            _pRead('Bearing', 'z ${b.bz.toStringAsFixed(2)}m'),
          )
        else
          _pair(
            _pRead('Type', 'king-post (single)'),
            _pRead('Bearing', 'z ${b.bz.toStringAsFixed(2)}m'),
          ),
        // ROOF SYSTEM — shared by every truss in the model: purlin
        // section+spacing and the roofing sheet. Auto entries resolve
        // from the PH tables (span->section, sheet->spacing); the
        // roof sheet + roofing takeoff read the same values.
        Builder(
          builder: (_) {
            final m = _sel;
            if (m == null) return const SizedBox.shrink();
            final rs = m.roof;
            final t = modelTakeoff(m);
            final sec = rs.purlinSection(
              rs.trussSpacing > 0 ? rs.trussSpacing : 1.5,
            );
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _pHead(cs, 'C-PURLINS / ROOFING (shared)'),
                _pair(
                  _pdd<String>(
                    '${m.id}-ps',
                    'Purlin section',
                    rs.purlinSize,
                    [
                      ('', 'Auto (${sec.$1}x${sec.$2})'),
                      for (final s in RoofSpec.purlinSizes) (s, s),
                    ],
                    (v) => rs.purlinSize = v,
                  ),
                  _pdd<double>(
                    '${m.id}-pt',
                    'Thk mm',
                    rs.purlinThk,
                    [
                      (0.0, 'Auto (${sec.$2})'),
                      for (final t2 in RoofSpec.purlinThks) (t2, '$t2'),
                    ],
                    (v) => rs.purlinThk = v,
                  ),
                ),
                _pair(
                  _pf(
                    '${m.id}-psp',
                    'Purlin o.c. m (0=auto ${rs.purlinSpace})',
                    rs.purlinSpacing,
                    (x) => rs.purlinSpacing = x,
                    ok: (x) => x >= 0 && x <= 3,
                  ),
                  _pf(
                    '${m.id}-oh',
                    'Eave overhang m',
                    rs.overhang,
                    (x) => rs.overhang = x,
                    ok: (x) => x >= 0 && x <= 1.5,
                  ),
                ),
                _pair(
                  _pdd<String>(
                    '${m.id}-rp',
                    'Roofing',
                    rs.roofProfile,
                    [
                      for (final e in RoofSpec.roofProfiles.entries)
                        (e.key, e.value),
                    ],
                    (v) => rs.roofProfile = v,
                  ),
                  _pdd<double>(
                    '${m.id}-rt',
                    'Sheet mm',
                    rs.roofThk,
                    [
                      for (final t2 in RoofSpec.roofThks)
                        (t2, '$t2 (${t2 <= 0.45 ? 'Ga.26' : t2 <= 0.55 ? 'Ga.24' : 'Ga.22'})'),
                    ],
                    (v) => rs.roofThk = v,
                  ),
                ),
                _pair(
                  _pf(
                    '${m.id}-tsp',
                    'Truss o.c. m (0=free)',
                    rs.trussSpacing,
                    (x) => rs.trussSpacing = x,
                    ok: (x) => x >= 0 && x <= 6,
                  ),
                  _pRead(
                    'Takeoff',
                    t.trusses > 0
                        ? '${t.purlinPcs} purlin · ${rs.roofProfile == 'corrugated' ? '${t.roofSheets} sht' : '${t.roofLm.toStringAsFixed(1)} lm'}'
                        : '—',
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.fromLTRB(14, 0, 14, 4),
                  child: Text(
                    'Preliminary PH/NSCP sizing — verify purlin span + wind '
                    'uplift with a licensed civil/structural engineer (RA 544).',
                    style: TextStyle(fontSize: 9.5, color: Color(0xFF94A3B8)),
                  ),
                ),
              ],
            );
          },
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 2, 14, 4),
          child: SizedBox(
            width: double.infinity,
            child: TextButton.icon(
              icon: const Icon(Icons.view_week_outlined, size: 15),
              label: Text(
                'Array along ridge @ ${(((_sel?.roof.trussSpacing) ?? 0) > 0 ? _sel!.roof.trussSpacing : 1.5).toStringAsFixed(2)}m',
                style: const TextStyle(fontSize: 11.5),
              ),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 6),
              ),
              onPressed: () {
                final m = _sel;
                if (m != null) _arrayTrusses(m, b, def!);
              },
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 2, 14, 4),
          child: SizedBox(
            width: double.infinity,
            child: TextButton.icon(
              icon: const Icon(Icons.vertical_align_top, size: 15),
              label: const Text(
                'Seat on wall top plates',
                style: TextStyle(fontSize: 11.5),
              ),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 6),
              ),
              onPressed: () {
                final m = _sel;
                if (m == null) return;
                final seat = seatTrussOnWalls(
                  m,
                  Offset(b.x, b.y),
                  b.rot,
                  def!.w * b.sx * b.scale,
                  ignore: b,
                );
                if (seat == null) return;
                _pushUndo();
                setState(() {
                  b.x = seat.$1.dx;
                  b.y = seat.$1.dy;
                  b.rot = seat.$2;
                  b.bz = seat.$3;
                  if (seat.$4 > 0) {
                    b.sx = trussFitSx(b.scale, def.w, seat.$4);
                  }
                });
                est.update();
              },
            ),
          ),
        ),
      ],
      if (b.def.startsWith('ftg-')) ...[
        _pHead(cs, 'FOOTING (NSCP 2015)'),
        Builder(
          builder: (_) {
            final t = def!.height * b.sz * b.scale;
            final side = def.w * b.sx * b.scale;
            // embedment = how far the pad BOTTOM sits below grade;
            // the pad top anchors at bz so bz = t - embedment
            final emb = t - b.bz;
            return Column(
              children: [
                _pair(
                  _pf(
                    b.id,
                    'Side (m)',
                    side,
                    (x) => b.sx = x / (def.w * b.scale),
                    ok: (x) => x >= 0.5,
                  ),
                  _pf(
                    b.id,
                    'Thickness (m)',
                    t,
                    (x) => b.sz = x / (def.height * b.scale),
                    ok: (x) => x >= 0.15,
                  ),
                ),
                _pair(
                  _pf(
                    b.id,
                    'Embedment (m)',
                    emb,
                    (x) => b.bz = t - x,
                    ok: (x) => x >= 0.2,
                  ),
                  _pRead(
                    'Rebar',
                    '${footingFor(0, side).bars.count}-${footingFor(0, side).bars.diaMm.round()}mm B/W',
                  ),
                ),
                if (emb < 0.6)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(14, 2, 14, 4),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.warning_amber,
                          size: 14,
                          color: Colors.orange,
                        ),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            'Below the 0.60 m standard embedment',
                            style: TextStyle(
                              fontSize: 10.5,
                              color: cs.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            );
          },
        ),
      ],
      if (isBeamDef(b.def)) ...[
        _pHead(cs, 'BEAM (NSCP 2015 §409.3.1.1)'),
        Builder(
          builder: (_) {
            final len = def!.w * b.sx * b.scale;
            final wd = def.d * b.sy * b.scale;
            final dp = def.height * b.sz * b.scale;
            // simply-supported L/16 — the no-calc deflection floor
            final hMin = nscpBeamDepth(len);
            final s = beamSched(wd, dp, len);
            return Column(
              children: [
                _pair(
                  _pf(
                    b.id,
                    'Width b (m)',
                    wd,
                    (x) => b.sy = x / (def.d * b.scale),
                    ok: (x) => x >= 0.15,
                  ),
                  _pf(
                    b.id,
                    'Depth h (m)',
                    dp,
                    (x) => b.sz = x / (def.height * b.scale),
                    ok: (x) => x >= 0.15,
                  ),
                ),
                _pair(
                  _pRead(
                    'Min depth L/16',
                    '${hMin.toStringAsFixed(2)} m (span ${len.toStringAsFixed(1)} m)',
                  ),
                  _pRead(
                    'Rebar',
                    '${s.main.label} + 10mm st @${(s.tieSpacing * 100).round()}cm',
                  ),
                ),
                if (dp < hMin - 1e-3)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(14, 2, 14, 4),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.warning_amber,
                          size: 14,
                          color: Colors.orange,
                        ),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            'Below the NSCP L/16 deflection minimum',
                            style: TextStyle(
                              fontSize: 10.5,
                              color: cs.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            );
          },
        ),
      ],
      _delBtn(cs, 'Delete block'),
    ];
  }

  Widget _objectList(ColorScheme cs) {
    final m = _sel;
    if (m == null) {
      return Center(
        child: Text(
          'Select or create a model.',
          style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
        ),
      );
    }
    Widget head(String s, int n) => Padding(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 4),
      child: Text(
        '$s - $n',
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.1,
          color: cs.onSurfaceVariant,
        ),
      ),
    );

    // Accordion row: header toggles selection (canvas follows), the
    // editor body is built ONLY for the open row - selection is the
    // single source of truth, so canvas picks and list taps agree.
    Widget tile(
      Object obj,
      IconData icon,
      Color tint,
      String title,
      String sub,
      bool sel,
      VoidCallback select,
      List<Widget> Function() body,
    ) {
      return Container(
        key: ObjectKey(obj),
        decoration: BoxDecoration(
          color: sel ? cs.primary.withValues(alpha: 0.07) : null,
          border: Border(
            left: BorderSide(
              width: 3,
              color: sel ? cs.primary : Colors.transparent,
            ),
          ),
        ),
        child: Column(
          children: [
            InkWell(
              onTap: () => sel ? setState(_clearSel) : select(),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                child: Row(
                  children: [
                    Icon(icon, size: 18, color: tint),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            style: const TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                          Text(
                            sub,
                            style: TextStyle(
                              fontSize: 10.5,
                              color: cs.onSurfaceVariant,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    Icon(
                      sel ? Icons.expand_less : Icons.expand_more,
                      size: 20,
                      color: cs.onSurfaceVariant,
                    ),
                  ],
                ),
              ),
            ),
            if (sel)
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
                child: Column(children: body()),
              ),
          ],
        ),
      );
    }

    return Material(
      type: MaterialType.transparency,
      child: ListView(
        children: [
          if (m.walls.isNotEmpty) head('WALLS', m.walls.length),
          for (final w in m.walls)
            tile(
              w,
              Icons.square_outlined,
              darken(Color(w.argb), 0.55),
              w.name,
              '${_fmtNum(w.length)} m - t ${_fmtNum(w.thickness)} - '
              'h ${_fmtNum(w.height)} - ${w.segs} seg',
              w == _wallSel,
              () => setState(() {
                _clearSel();
                _wallSel = w;
                _rightTab = 2;
              }),
              () => _wallBody(cs, w),
            ),
          if (m.volumes.isNotEmpty) head('ROOMS / VOLUMES', m.volumes.length),
          for (final v in m.volumes)
            tile(
              v,
              Icons.crop_free,
              Color(v.argb),
              v.name,
              '${_fmtNum(v.area)} m2 - h ${_fmtNum(v.height)}',
              v == _vol,
              () => setState(() {
                _clearSel();
                _vol = v;
                _rightTab = 2;
              }),
              () => _volBody(cs, v),
            ),
          if (m.blocks.isNotEmpty) head('BLOCKS', m.blocks.length),
          for (final b in m.blocks)
            Builder(
              key: ObjectKey(b),
              builder: (_) {
                final def = cadBlock(b.def);
                return tile(
                  b,
                  Icons.category_outlined,
                  cs.primary,
                  def?.name ?? b.def,
                  '${_fmtNum(b.x)}, ${_fmtNum(b.y)}'
                  ' - ${(b.rot * 180 / math.pi).round()} deg',
                  b == _blkSel,
                  () => setState(() {
                    _clearSel();
                    _blkSel = b;
                    _rightTab = 2;
                  }),
                  () => _blkBody(cs, b),
                );
              },
            ),
          if (m.dims.isNotEmpty) head('DIMENSIONS', m.dims.length),
          for (var i = 0; i < m.dims.length; i++)
            ListTile(
              dense: true,
              leading: Icon(
                Icons.square_foot_outlined,
                size: 18,
                color: cs.onSurfaceVariant,
              ),
              title: Text(
                '${_fmtNum(Offset(m.dims[i][2] - m.dims[i][0], m.dims[i][3] - m.dims[i][1]).distance)} m',
                style: const TextStyle(fontSize: 12.5),
              ),
              subtitle: Text(
                '(${_fmtNum(m.dims[i][0])}, ${_fmtNum(m.dims[i][1])}) to '
                '(${_fmtNum(m.dims[i][2])}, ${_fmtNum(m.dims[i][3])})',
                style: TextStyle(fontSize: 10.5, color: cs.onSurfaceVariant),
              ),
              trailing: IconButton(
                icon: const Icon(Icons.delete_outline, size: 18),
                tooltip: 'Delete dimension',
                onPressed: () {
                  _pushUndo();
                  setState(() => m.dims.removeAt(i));
                  est.update();
                },
              ),
            ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  List<Widget> _modelSummary(ColorScheme cs, Model3d m) {
    final wallLen = m.walls.fold(0.0, (s, w) => s + w.length);
    final area =
        m.volumes.fold(0.0, (s, v) => s + v.area) +
        m.walls.fold(0.0, (s, w) => s + w.length * w.thickness);
    return [
      Text(
        'MODEL',
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.2,
          color: cs.onSurfaceVariant,
        ),
      ),
      const SizedBox(height: 6),
      TextFormField(
        key: ValueKey('mn-${m.id}'),
        initialValue: m.name,
        decoration: const InputDecoration(labelText: 'Name', isDense: true),
        onChanged: (s) {
          _pushUndoTick('mn-${m.id}');
          m.name = s;
          est.update();
        },
      ),
      const SizedBox(height: 14),
      _stat(
        'Walls',
        m.walls.isEmpty ? '0' : '${m.walls.length} · ${_fmtNum(wallLen)} m',
      ),
      _stat('Blocks', '${m.blocks.length}'),
      _stat('Volumes', '${m.volumes.length}'),
      _stat('Floor area', '${_fmtNum(area)} m²'),
      _stat('Envelope', _envelope(m)),
      const SizedBox(height: 14),
      Text(
        'Select a wall, volume or block to edit it — or draw walls '
        '(W), place blocks (B).',
        style: TextStyle(
          fontSize: 11,
          fontStyle: FontStyle.italic,
          color: cs.onSurfaceVariant,
        ),
      ),
    ];
  }

  List<Widget> _volInspector(ColorScheme cs, Volume3d v) {
    return [
      Text(
        'VOLUME',
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.2,
          color: cs.onSurfaceVariant,
        ),
      ),
      const SizedBox(height: 6),
      TextFormField(
        key: ValueKey('vn-${v.id}'),
        initialValue: v.name,
        decoration: const InputDecoration(labelText: 'Name', isDense: true),
        onChanged: (s) {
          _pushUndoTick('vn-${v.id}');
          v.name = s;
          est.update();
        },
      ),
      const SizedBox(height: 10),
      _numField(v, 'Base (m)', v.base, (x) => v.base = x),
      const SizedBox(height: 10),
      _numField(v, 'Height (m)', v.height, (x) => v.height = math.max(0.1, x)),
      const SizedBox(height: 12),
      Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (final c in _palette)
            InkWell(
              onTap: () {
                if (v.argb != c) _pushUndo();
                v.argb = c;
                est.update();
                setState(() {});
              },
              child: Container(
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  color: Color(c),
                  shape: BoxShape.circle,
                  border: Border.all(
                    width: v.argb == c ? 2.4 : 1,
                    color: v.argb == c ? cs.primary : Colors.black26,
                  ),
                ),
              ),
            ),
        ],
      ),
      const SizedBox(height: 14),
      OutlinedButton.icon(
        icon: const Icon(Icons.delete_outline, size: 17),
        label: const Text('Delete volume'),
        style: OutlinedButton.styleFrom(
          foregroundColor: cs.error,
          padding: const EdgeInsets.symmetric(vertical: 8),
        ),
        onPressed: _delVol,
      ),
    ];
  }

  String _envelope(Model3d m) {
    final b = m.bounds;
    if (b == null) return '—';
    return '${_fmtNum(b.$3 - b.$1)} × ${_fmtNum(b.$4 - b.$2)} × '
        '${_fmtNum(b.$5)} m';
  }

  Widget _stat(String k, String v) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      children: [
        Text(k, style: const TextStyle(fontSize: 12, color: Color(0xFF64748B))),
        Expanded(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerRight,
            child: Text(
              v,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
          ),
        ),
      ],
    ),
  );

  Widget _numField(
    Volume3d v,
    String label,
    double cur,
    void Function(double) set,
  ) {
    return TextFormField(
      key: ValueKey('${v.id}-$label'),
      initialValue: cur.toStringAsFixed(2),
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      decoration: InputDecoration(labelText: label, isDense: true),
      onChanged: (s) {
        final x = double.tryParse(s);
        if (x != null) {
          _pushUndoTick('${v.id}-$label');
          set(x);
          est.update();
        }
      },
    );
  }

  List<Widget> _wallInspector(ColorScheme cs, Wall3d w) {
    return [
      Text(
        'WALL',
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.2,
          color: cs.onSurfaceVariant,
        ),
      ),
      const SizedBox(height: 6),
      TextFormField(
        key: ValueKey('wn-${w.id}'),
        initialValue: w.name,
        decoration: const InputDecoration(labelText: 'Name', isDense: true),
        onChanged: (s) {
          _pushUndoTick('wn-${w.id}');
          w.name = s;
          est.update();
        },
      ),
      const SizedBox(height: 10),
      _stat('Length', '${_fmtNum(w.length)} m'),
      _stat('Segments', '${w.segs}'),
      const SizedBox(height: 8),
      TextFormField(
        key: ValueKey('${w.id}-t'),
        initialValue: w.thickness.toStringAsFixed(2),
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: const InputDecoration(
          labelText: 'Thickness (m)',
          isDense: true,
        ),
        onChanged: (s) {
          final x = double.tryParse(s);
          if (x != null && x > 0) {
            _pushUndoTick('${w.id}-t');
            setState(() => w.thickness = x);
            est.update();
          }
        },
      ),
      const SizedBox(height: 10),
      TextFormField(
        key: ValueKey('${w.id}-h'),
        initialValue: w.height.toStringAsFixed(2),
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: const InputDecoration(
          labelText: 'Height (m)',
          isDense: true,
        ),
        onChanged: (s) {
          final x = double.tryParse(s);
          if (x != null && x > 0) {
            _pushUndoTick('${w.id}-h');
            setState(() => w.height = x);
            est.update();
          }
        },
      ),
      const SizedBox(height: 10),
      TextFormField(
        key: ValueKey('${w.id}-b'),
        initialValue: w.base.toStringAsFixed(2),
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: const InputDecoration(labelText: 'Base (m)', isDense: true),
        onChanged: (s) {
          final x = double.tryParse(s);
          if (x != null) {
            _pushUndoTick('${w.id}-b');
            setState(() => w.base = x);
            est.update();
          }
        },
      ),
      const SizedBox(height: 12),
      // wall color — fill follows argb, the outline auto-darkens
      Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (final c in _palette)
            InkWell(
              onTap: () {
                if (w.argb != c) _pushUndo();
                w.argb = c;
                est.update();
                setState(() {});
              },
              child: Container(
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  color: Color(c),
                  shape: BoxShape.circle,
                  border: Border.all(
                    width: w.argb == c ? 2.4 : 1,
                    color: w.argb == c ? cs.primary : Colors.black26,
                  ),
                ),
              ),
            ),
        ],
      ),
      const SizedBox(height: 14),
      OutlinedButton.icon(
        icon: const Icon(Icons.delete_outline, size: 17),
        label: const Text('Delete wall'),
        style: OutlinedButton.styleFrom(
          foregroundColor: cs.error,
          padding: const EdgeInsets.symmetric(vertical: 8),
        ),
        onPressed: _delVol,
      ),
    ];
  }

  /// Editable dimension for the block inspector — value is the live
  /// effective size; [set] converts typed meters back to the axis
  /// multiplier. Same math the 3D bbox grips apply.
  Widget _dimField(
    Block3d b,
    String label,
    double cur,
    void Function(double) set,
  ) {
    return TextFormField(
      key: ValueKey('${b.id}-$label'),
      initialValue: cur.toStringAsFixed(2),
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      decoration: InputDecoration(labelText: label, isDense: true),
      onChanged: (s) {
        final x = double.tryParse(s);
        if (x != null) {
          _pushUndoTick('${b.id}-$label');
          setState(() => set(x));
          est.update();
        }
      },
    );
  }

  List<Widget> _blkInspector(ColorScheme cs, Block3d b) {
    final def = cadBlock(b.def);
    return [
      Text(
        'BLOCK',
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.2,
          color: cs.onSurfaceVariant,
        ),
      ),
      const SizedBox(height: 6),
      _stat('Symbol', def?.name ?? b.def),
      if (def != null) _stat('Size', '${def.w} × ${def.d} m'),
      const SizedBox(height: 8),
      TextFormField(
        key: ValueKey('${b.id}-rot'),
        initialValue: (b.rot * 180 / math.pi).toStringAsFixed(0),
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: const InputDecoration(
          labelText: 'Rotation (°)',
          isDense: true,
        ),
        onChanged: (s) {
          final x = double.tryParse(s);
          if (x != null) {
            _pushUndoTick('${b.id}-rot');
            setState(() {
              b.rot = x * math.pi / 180;
              _blkRot = b.rot;
            });
            est.update();
          }
        },
      ),
      const SizedBox(height: 10),
      TextFormField(
        key: ValueKey('${b.id}-sc'),
        initialValue: b.scale.toStringAsFixed(2),
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: const InputDecoration(labelText: 'Scale', isDense: true),
        onChanged: (s) {
          final x = double.tryParse(s);
          if (x != null && x > 0) {
            _pushUndoTick('${b.id}-sc');
            setState(() => b.scale = x);
            est.update();
          }
        },
      ),
      const SizedBox(height: 10),
      // real dimensions — the 6-face scale box writes these same axes
      if (def != null) ...[
        _dimField(
          b,
          'Width (m)',
          (blockLocalBox(def)[3] - blockLocalBox(def)[0]) * b.sx * b.scale,
          (x) => b.sx =
              x / ((blockLocalBox(def)[3] - blockLocalBox(def)[0]) * b.scale),
        ),
        const SizedBox(height: 10),
        _dimField(
          b,
          'Depth (m)',
          (blockLocalBox(def)[4] - blockLocalBox(def)[1]) * b.sy * b.scale,
          (x) => b.sy =
              x / ((blockLocalBox(def)[4] - blockLocalBox(def)[1]) * b.scale),
        ),
        const SizedBox(height: 10),
        _dimField(
          b,
          'Height (m)',
          (blockLocalBox(def)[5] - blockLocalBox(def)[2]) * b.sz * b.scale,
          (x) => b.sz =
              x / ((blockLocalBox(def)[5] - blockLocalBox(def)[2]) * b.scale),
        ),
        const SizedBox(height: 10),
        _dimField(b, 'Lift (m)', b.bz, (x) => b.bz = x),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            icon: const Icon(Icons.restart_alt, size: 15),
            label: const Text('Reset size', style: TextStyle(fontSize: 11)),
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 6),
            ),
            onPressed: () {
              _pushUndo();
              setState(() {
                b.sx = b.sy = b.sz = 1;
                b.bz = 0;
              });
              est.update();
            },
          ),
        ),
        const SizedBox(height: 8),
        // material color — a tint blended over the mesh's baked face
        // colors so shading/detail stay readable; first swatch = the
        // model's original colors (tint 0)
        Text(
          'MATERIAL',
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w700,
            letterSpacing: 1,
            color: cs.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final t in const [
              0x00000000, // original mesh colors
              0xFFFFFFFF,
              0xFFECEFF1,
              0xFF8D6E63,
              0xFF5D4037,
              0xFF78909C,
              0xFF37474F,
              0xFFEF5350,
              0xFFFFA726,
              0xFF66BB6A,
              0xFF2E7D32,
              0xFF42A5F5,
              0xFF1E3A8A,
              0xFFAB47BC,
              0xFFF9A825,
              0xFF212121,
            ])
              InkWell(
                onTap: () {
                  _pushUndo();
                  setState(() => b.tint = t);
                  est.update();
                },
                borderRadius: BorderRadius.circular(5),
                child: Container(
                  width: 26,
                  height: 26,
                  decoration: BoxDecoration(
                    color: t == 0 ? Colors.white : Color(t),
                    borderRadius: BorderRadius.circular(5),
                    border: Border.all(
                      color: b.tint == t ? cs.primary : Colors.black26,
                      width: b.tint == t ? 2.4 : 1,
                    ),
                  ),
                  child: t == 0
                      ? Icon(
                          Icons.format_paint_outlined,
                          size: 14,
                          color: cs.onSurfaceVariant,
                        )
                      : null,
                ),
              ),
          ],
        ),
      ],
      const SizedBox(height: 14),
      OutlinedButton.icon(
        icon: const Icon(Icons.delete_outline, size: 17),
        label: const Text('Delete block'),
        style: OutlinedButton.styleFrom(
          foregroundColor: cs.error,
          padding: const EdgeInsets.symmetric(vertical: 8),
        ),
        onPressed: _delVol,
      ),
    ];
  }
}
