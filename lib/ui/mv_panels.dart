part of 'model_view.dart';

// ignore_for_file: invalid_use_of_protected_member

// Split from model_view.dart (1k-line cap): the model rail,
// toolbar, splitter, onboarding card, status strip and HUD.

extension _MvPanels on _ModelViewState {
  /// The draggable plan|3D divider. Drag moves the split (clamped so
  /// both panes stay usable); double-click snaps back to 50/50 — the
  /// SketchUp/Figma splitter convention.
  Widget _splitter(ColorScheme cs, double avail) {
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      onEnter: (_) => setState(() => _splitHover = true),
      onExit: (_) => setState(() => _splitHover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onHorizontalDragUpdate: (d) => est.setModelSplit(
          (est.modelSplitFrac + d.delta.dx / avail).clamp(0.2, 0.8),
        ),
        onDoubleTap: () => est.setModelSplit(0.5),
        child: Container(
          width: 10,
          color: _splitHover
              ? const Color(0xFFCBD5E1)
              : const Color(0xFFE2E8F0),
          child: Center(
            child: Icon(
              Icons.drag_indicator,
              size: 13,
              color: _splitHover
                  ? const Color(0xFF475569)
                  : const Color(0xFF94A3B8),
            ),
          ),
        ),
      ),
    );
  }

  Widget _rail(ColorScheme cs) {
    // collapsed: a thin icon rail so the canvases get the space back —
    // the flag lives in est so it survives tab switches (same pattern
    // as the DRAWINGS library rail)
    if (!est.modelRailOpen) {
      return Container(
        width: 40,
        color: const Color(0xFFF8FAFC),
        child: Column(
          children: [
            const SizedBox(height: 8),
            IconButton(
              icon: const Icon(Icons.chevron_right, size: 18),
              tooltip: 'Show models',
              onPressed: () => est.setModelRailOpen(true),
              visualDensity: VisualDensity.compact,
            ),
            IconButton(
              icon: const Icon(Icons.add, size: 18),
              tooltip: 'New model',
              onPressed: _newModel,
              visualDensity: VisualDensity.compact,
            ),
            if (est.models.isNotEmpty) ...[
              const SizedBox(height: 6),
              Icon(
                Icons.view_in_ar_outlined,
                size: 16,
                color: cs.primary.withValues(alpha: 0.7),
              ),
              Text(
                '${est.models.length}',
                style: TextStyle(fontSize: 10, color: cs.primary),
              ),
            ],
          ],
        ),
      );
    }
    return Container(
      width: 200,
      color: const Color(0xFFF8FAFC),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 8, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '3D MODELS',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.1,
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.chevron_left, size: 18),
                  tooltip: 'Hide models',
                  onPressed: () => est.setModelRailOpen(false),
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints.tightFor(
                    width: 30,
                    height: 30,
                  ),
                  padding: EdgeInsets.zero,
                ),
                IconButton(
                  icon: const Icon(Icons.add, size: 20),
                  tooltip: 'New model',
                  onPressed: _newModel,
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: est.models.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        'No models yet.\nTap + to create one.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 12,
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    ),
                  )
                : Material(
                    type: MaterialType.transparency,
                    child: ListView(
                      children: [
                        for (final m in est.models)
                          ListTile(
                            dense: true,
                            selected: m == _sel,
                            leading: Icon(
                              Icons.view_in_ar_outlined,
                              size: 20,
                              color: m == _sel ? cs.primary : null,
                            ),
                            title: Text(
                              m.name,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 13),
                            ),
                            subtitle: Text(
                              '${m.walls.length} wall'
                              '${m.walls.length == 1 ? '' : 's'} · '
                              '${m.blocks.length} blk · '
                              '${m.volumes.length} vol',
                              style: const TextStyle(fontSize: 11),
                            ),
                            trailing: IconButton(
                              icon: const Icon(Icons.close, size: 16),
                              tooltip: 'Delete model',
                              onPressed: () => _deleteModel(m),
                            ),
                            onTap: () => setState(() {
                              _sel = m;
                              _undo.clear();
                              _vol = null;
                              _wallSel = null;
                              _blkSel = null;
                              _moving = null;
                              _poly.clear();
                              _rect0 = _rectCur = null;
                              _fitPlan();
                            }),
                          ),
                      ],
                    ),
                  ),
          ),
          // discoverable create affordance — the header + was too
          // subtle; a labeled bottom button is the SketchUp "Add
          // Scene"-style pattern
          Padding(
            padding: const EdgeInsets.all(10),
            child: FilledButton.icon(
              key: const Key('newModelBtn'),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('NEW MODEL'),
              style: FilledButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(vertical: 10),
              ),
              onPressed: _newModel,
            ),
          ),
        ],
      ),
    );
  }

  Widget _toolbar(ColorScheme cs) {
    Widget tbtn(_MTool t, IconData ic, String tip) {
      final on = _tool == t;
      return IconButton(
        icon: Icon(
          ic,
          size: 19,
          color: on ? Colors.white : cs.onSurfaceVariant,
        ),
        tooltip: tip,
        style: IconButton.styleFrom(
          backgroundColor: on ? cs.primary : Colors.transparent,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
        onPressed: () => setState(() {
          _tool = t;
          _poly.clear();
          _wall.clear();
          _rect0 = _rectCur = null;
        }),
      );
    }

    return Container(
      height: 46,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(bottom: BorderSide(color: Color(0xFFE2E8F0))),
      ),
      // SketchUp/ArchiCAD convention: secondary controls COLLAPSE to
      // icon mode before anything scrolls off — the scroll view below
      // is the last resort for extreme widths. Pills group the tools
      // and the param controls like the main _BarGroup in the top bar.
      // compact (<720px): text chips -> icon buttons, parts count hides;
      // tight (<430px): GENERATE loses its label too.
      child: LayoutBuilder(
        builder: (_, cc) {
          final compact = cc.maxWidth < 720;
          final tight = cc.maxWidth < 430;
          Widget pill(List<Widget> kids) => Container(
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              color: const Color(0xFFF1F5F9),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFFE2E8F0)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < kids.length; i++) ...[
                  if (i > 0) const SizedBox(width: 2),
                  kids[i],
                ],
              ],
            ),
          );

          return Row(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      pill([
                        tbtn(
                          _MTool.select,
                          Icons.near_me_outlined,
                          'Select / move (A)',
                        ),
                        tbtn(
                          _MTool.wall,
                          Icons.square_outlined,
                          'Draw walls — click points; tap last point or Enter ends (W)',
                        ),
                        tbtn(
                          _MTool.block,
                          Icons.chair_outlined,
                          'Place furniture / openings (B, R rotates)',
                        ),
                        tbtn(
                          _MTool.rect,
                          Icons.crop_square,
                          'Draw box footprint (R)',
                        ),
                        tbtn(
                          _MTool.poly,
                          Icons.timeline,
                          'Draw polygon footprint — tap start or Enter closes (P)',
                        ),
                        tbtn(
                          _MTool.dim,
                          Icons.square_foot_outlined,
                          'Dimension — drag between two points (D)',
                        ),
                        tbtn(
                          _MTool.eraser,
                          Icons.auto_fix_normal,
                          'Erase — click or drag over elements to delete (E)',
                        ),
                        IconButton(
                          icon: Icon(
                            Icons.question_mark,
                            size: 17,
                            color: _hud ? Colors.white : cs.onSurfaceVariant,
                          ),
                          tooltip: 'Shortcuts (?)',
                          visualDensity: VisualDensity.compact,
                          style: IconButton.styleFrom(
                            backgroundColor: _hud ? cs.primary : null,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                          ),
                          onPressed: () => setState(() => _hud = !_hud),
                        ),
                      ]),
                      const SizedBox(width: 8),
                      if (compact)
                        // wall thickness — icon-mode trigger, same menu
                        PopupMenuButton<double>(
                          tooltip:
                              'Wall thickness ${_wallT.toStringAsFixed(2)} m',
                          icon: Icon(
                            Icons.straighten,
                            size: 19,
                            color: (_tool == _MTool.wall || _wallSel != null)
                                ? cs.primary
                                : cs.onSurfaceVariant,
                          ),
                          onSelected: (t) {
                            setState(() {
                              _wallT = t;
                              final w = _wallSel;
                              if (w != null) {
                                _pushUndo();
                                w.thickness = t;
                                est.update();
                              }
                            });
                          },
                          itemBuilder: (_) => [
                            for (final t in const [
                              0.10,
                              0.15,
                              0.20,
                              0.25,
                              0.30,
                            ])
                              PopupMenuItem(
                                value: t,
                                child: Row(
                                  children: [
                                    if (_wallT == t)
                                      const Icon(Icons.check, size: 16)
                                    else
                                      const SizedBox(width: 16),
                                    const SizedBox(width: 6),
                                    Text('${t.toStringAsFixed(2)} m'),
                                  ],
                                ),
                              ),
                          ],
                        )
                      else
                        // wall thickness — drives new walls and the
                        // selected one
                        PopupMenuButton<double>(
                          tooltip: 'Wall thickness',
                          onSelected: (t) {
                            setState(() {
                              _wallT = t;
                              final w = _wallSel;
                              if (w != null) {
                                _pushUndo();
                                w.thickness = t;
                                est.update();
                              }
                            });
                          },
                          itemBuilder: (_) => [
                            for (final t in const [
                              0.10,
                              0.15,
                              0.20,
                              0.25,
                              0.30,
                            ])
                              PopupMenuItem(
                                value: t,
                                child: Row(
                                  children: [
                                    if (_wallT == t)
                                      const Icon(Icons.check, size: 16)
                                    else
                                      const SizedBox(width: 16),
                                    const SizedBox(width: 6),
                                    Text('${t.toStringAsFixed(2)} m'),
                                  ],
                                ),
                              ),
                          ],
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 5,
                            ),
                            decoration: BoxDecoration(
                              border: Border.all(
                                color:
                                    (_tool == _MTool.wall || _wallSel != null)
                                    ? cs.primary
                                    : const Color(0xFFCBD5E1),
                              ),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              't ${_wallT.toStringAsFixed(2)}',
                              style: TextStyle(
                                fontSize: 11.5,
                                fontWeight: FontWeight.w700,
                                color:
                                    (_tool == _MTool.wall || _wallSel != null)
                                    ? cs.primary
                                    : cs.onSurfaceVariant,
                              ),
                            ),
                          ),
                        ),
                      const SizedBox(width: 6),
                      // armed-block chip — opens the Blocks tab (the
                      // library in the right panel IS the palette now)
                      if (compact)
                        IconButton(
                          icon: Icon(
                            Icons.chair_outlined,
                            size: 19,
                            color: _tool == _MTool.block
                                ? cs.primary
                                : cs.onSurfaceVariant,
                          ),
                          tooltip:
                              'Armed block: ${_blkDef.name} — open Blocks tab',
                          onPressed: () => setState(() => _rightTab = 1),
                        )
                      else
                        InkWell(
                          onTap: () => setState(() => _rightTab = 1),
                          borderRadius: BorderRadius.circular(8),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 5,
                            ),
                            decoration: BoxDecoration(
                              border: Border.all(
                                color: _tool == _MTool.block
                                    ? cs.primary
                                    : const Color(0xFFCBD5E1),
                              ),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.chair_outlined,
                                  size: 15,
                                  color: _tool == _MTool.block
                                      ? cs.primary
                                      : cs.onSurfaceVariant,
                                ),
                                const SizedBox(width: 4),
                                ConstrainedBox(
                                  constraints: const BoxConstraints(
                                    maxWidth: 110,
                                  ),
                                  child: Text(
                                    _blkDef.name,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 11.5,
                                      fontWeight: FontWeight.w700,
                                      color: _tool == _MTool.block
                                          ? cs.primary
                                          : cs.onSurfaceVariant,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              // pinned right side — never scrolls away. The view
              // controls (snap/dims/units/fit) live here too: left of
              // the divider they scrolled off under the tools row.
              // At tight widths the secondary pair (unit cycler, fit)
              // drops out so the pinned run never overflows.
              IconButton(
                icon: Icon(
                  Icons.grid_4x4,
                  size: 19,
                  color: _snap ? cs.primary : cs.onSurfaceVariant,
                ),
                tooltip: 'Snap 0.25 m',
                visualDensity: VisualDensity.compact,
                onPressed: () => setState(() => _snap = !_snap),
              ),
              IconButton(
                icon: Icon(
                  Icons.straighten,
                  size: 19,
                  color: _dims ? cs.primary : cs.onSurfaceVariant,
                ),
                tooltip: _dims
                    ? 'Measurements on — wall + block dims'
                    : 'Measurements off',
                visualDensity: VisualDensity.compact,
                onPressed: () => setState(() => _dims = !_dims),
              ),
              // dimension units: m → ft → in, one tap cycles
              if (!tight)
                Tooltip(
                  message: 'Dimension units — tap to cycle m/ft/in',
                  child: TextButton(
                    style: TextButton.styleFrom(
                      minimumSize: const Size(30, 30),
                      padding: EdgeInsets.zero,
                      foregroundColor: _dims ? cs.primary : cs.onSurfaceVariant,
                    ),
                    onPressed: () => setState(() => _unit = (_unit + 1) % 3),
                    child: Text(
                      const ['m', 'ft', 'in'][_unit],
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              if (!tight)
                IconButton(
                  icon: Icon(
                    Icons.fit_screen,
                    size: 19,
                    color: cs.onSurfaceVariant,
                  ),
                  tooltip: 'Fit plan',
                  visualDensity: VisualDensity.compact,
                  onPressed: () => _fitPlan(),
                ),
              const VerticalDivider(),
              if (!compact && _sel != null)
                Text(
                  '${_sel!.volumes.length + _sel!.walls.length + _sel!.blocks.length} parts · '
                  '${_fmtNum(_sel!.volumes.fold(0.0, (s, v) => s + v.area) + _sel!.walls.fold(0.0, (s, w) => s + w.length * w.thickness))} m²',
                  style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                ),
              const SizedBox(width: 12),
              if (tight)
                Tooltip(
                  message: 'Generate drawing',
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 8,
                      ),
                      minimumSize: const Size(36, 32),
                    ),
                    onPressed: _generate,
                    child: const Icon(Icons.article_outlined, size: 17),
                  ),
                )
              else
                FilledButton.icon(
                  icon: const Icon(Icons.article_outlined, size: 17),
                  label: const Text('GENERATE DRAWING'),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 8,
                    ),
                    textStyle: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  onPressed: _generate,
                ),
              const SizedBox(width: 6),
              Tooltip(
                message:
                    'Sheet template: ${est.sheetPaper} '
                    '${est.sheetLandscape ? 'landscape' : 'portrait'}',
                child: IconButton(
                  visualDensity: VisualDensity.compact,
                  iconSize: 18,
                  icon: const Icon(Icons.settings_outlined),
                  onPressed: _sheetSetup,
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _onboardCard(ColorScheme cs) {
    // steps are NON-interactive hints — the card must not eat a
    // single canvas tap: only the x claims hits, every other pixel
    // falls through to the plan so the first wall point works even
    // with the card under the cursor
    Widget step(int n, IconData ic, String title, String sub) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 4),
        child: Row(
          children: [
            Container(
              width: 20,
              height: 20,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: cs.primary,
                shape: BoxShape.circle,
              ),
              child: Text(
                '$n',
                style: const TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w800,
                  color: Colors.white,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Icon(ic, size: 16, color: cs.primary),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      color: cs.onSurface,
                    ),
                  ),
                  Text(
                    sub,
                    style: const TextStyle(
                      fontSize: 11,
                      color: Color(0xFF94A3B8),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    // IgnorePointer wraps the whole card body — a decorated Container
    // claims hits for its full rect, which would eat the first wall
    // tap. The x sits as a separate Stack sibling: the ONLY hit area.
    return SizedBox(
      width: 330,
      child: Stack(
        children: [
          IgnorePointer(
            child: Container(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.96),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: const Color(0xFFE2E8F0)),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.08),
                    blurRadius: 18,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Padding(
                    padding: EdgeInsets.only(right: 26, bottom: 2),
                    child: Text(
                      'Start your model',
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  step(
                    1,
                    Icons.square_outlined,
                    'Draw walls (W)',
                    'click points on the plan — or right in 3D',
                  ),
                  step(
                    2,
                    Icons.chair_outlined,
                    'Place blocks (B)',
                    'doors · windows · furniture from the library',
                  ),
                  step(
                    3,
                    Icons.article_outlined,
                    'Generate drawing',
                    'floor plan · roof · 4 elevations in one click',
                  ),
                ],
              ),
            ),
          ),
          Positioned(
            right: 4,
            top: 4,
            child: IconButton(
              icon: const Icon(Icons.close, size: 15),
              tooltip: 'Hide tips',
              visualDensity: VisualDensity.compact,
              onPressed: () => setState(() => est.modelIntroDismissed = true),
            ),
          ),
        ],
      ),
    );
  }

  void _delVol() => _delSel();

  String _planHint() {
    switch (_tool) {
      case _MTool.select:
        return 'drag a part to move · drag empty space to pan';
      case _MTool.wall:
        return _wall.isEmpty
            ? 'click the first wall point'
            : '${_wall.length} pt · tap last pt or Enter to end';
      case _MTool.block:
        return 'click to place ${_blkDef.name} · R rotates';
      case _MTool.rect:
        return 'drag a box footprint';
      case _MTool.poly:
        return '${_poly.length} pt · tap start or Enter to close';
      case _MTool.dim:
        return _dimA == null
            ? 'drag between two points to dimension them'
            : 'release to commit the dimension';
      case _MTool.eraser:
        return 'click or drag over an element to erase it';
      case _MTool.move:
        return _moving == null
            ? 'click an object to pick it up'
            : 'click to place · Esc releases';
      case _MTool.rotate:
        return _rotating == null
            ? 'click an object to rotate it'
            : 'move cursor to spin · wheel tunes · click to set';
    }
  }

  // ---------- status strip ----------

  /// One SketchUp-style status bar under the viewports: tool + hint
  /// on the left (the hint follows whichever pane the cursor is over),
  /// then selection summary, cursor readout, snap chip and zoom % on
  /// the right. Replaces the old per-pane bottom overlays so the
  /// canvases keep their full area.
  (String, IconData) get _toolInfo => switch (_tool) {
    _MTool.select => ('SELECT', Icons.near_me_outlined),
    _MTool.wall => ('WALL', Icons.square_outlined),
    _MTool.block => ('BLOCK', Icons.chair_outlined),
    _MTool.rect => ('RECT', Icons.crop_square),
    _MTool.poly => ('POLY', Icons.timeline),
    _MTool.eraser => ('ERASE', Icons.auto_fix_normal),
    _MTool.dim => ('DIM', Icons.square_foot_outlined),
    _MTool.move => ('MOVE', Icons.open_with_outlined),
    _MTool.rotate => ('ROTATE', Icons.rotate_right),
  };

  bool get _over3 => _vp == _Vp.model || (_vp == _Vp.split && _hover3 != null);

  String get _hint {
    if (_over3) {
      return _tool == _MTool.select
          ? 'tap a part to select · drag orbits · shift-drag pans · wheel zooms'
          : _tool == _MTool.move
          ? (_moving == null
                ? 'tap an object to pick it up · drag orbits'
                : 'tap to place · Esc releases · drag orbits')
          : _tool == _MTool.rotate
          ? (_rotating == null
                ? 'tap an object to rotate it · drag orbits'
                : 'cursor spins it · wheel tunes · tap sets')
          : _groundEditable
          ? 'click to place · drag orbits · shift pans'
                '${_vp == _Vp.model ? ' · 2/Esc exits focus' : ''}'
          : 'view too flat to place — drag to orbit up first';
    }
    return _planHint();
  }

  /// Cursor readout: plan X,Y or the 3D ground hit X,Y,Z — the
  /// snap-resolved point while a draw tool is armed (same value a
  /// click commits), the plain rounded cursor position otherwise.
  String get _coordText {
    final drawing = _tool != _MTool.select;
    if (_vp == _Vp.model || (_over3 && _hover3 != null)) {
      if (!_groundEditable || _hover3 == null) return '—';
      final g = _s2g(_hover3!, _vp3);
      final p = drawing
          ? _snapPt(g, _z3, _projGround).p
          : Offset(_w(g.dx), _w(g.dy));
      return 'X ${_fmtNum(p.dx)}  Y ${_fmtNum(p.dy)}  Z 0.00';
    }
    if (!_inPlan && _vp != _Vp.plan) return '—';
    final p = drawing
        ? _snapPt(_hover, _pScale).p
        : Offset(_w(_hover.dx), _w(_hover.dy));
    return 'X ${_fmtNum(p.dx)}  Y ${_fmtNum(p.dy)}';
  }

  String get _zoomText {
    final planSide = _vp == _Vp.plan || (_vp != _Vp.model && !_over3);
    return planSide
        ? '${(_pScale / 40 * 100).round()}%'
        : '${(_z3 / 30 * 100).round()}%';
  }

  String? get _selText {
    final w = _wallSel, v = _vol, b = _blkSel;
    if (w != null) return 'WALL · ${_fmtNum(w.length)} m';
    if (v != null) {
      return '${v.name.toUpperCase()} · ${v.area.toStringAsFixed(1)} m²';
    }
    if (b != null) {
      return (cadBlock(b.def)?.name ?? b.def).toUpperCase();
    }
    return null;
  }

  Widget _statusStrip(ColorScheme cs) {
    final (tName, tIcon) = _toolInfo;
    final sel = _selText;
    Widget sep() => Container(
      width: 1,
      height: 14,
      margin: const EdgeInsets.symmetric(horizontal: 10),
      color: const Color(0xFFE2E8F0),
    );
    const numStyle = TextStyle(
      fontSize: 11,
      color: Color(0xFF334155),
      fontFeatures: [FontFeature.tabularFigures()],
    );
    return Container(
      key: const Key('modelStatusStrip'),
      height: 26,
      decoration: const BoxDecoration(
        color: Color(0xFFFBFCFE),
        border: Border(top: BorderSide(color: Color(0xFFE2E8F0))),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: LayoutBuilder(
        builder: (_, cc) {
          // narrow strips drop the numeric cluster — the tool name,
          // hint and snap toggle stay readable
          final narrow = cc.maxWidth < 560;
          return Row(
            children: [
              Icon(tIcon, size: 13, color: cs.primary),
              const SizedBox(width: 5),
              Text(
                tName,
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.9,
                  color: cs.primary,
                ),
              ),
              sep(),
              Expanded(
                child: Text(
                  _hint,
                  style: const TextStyle(
                    fontSize: 11,
                    color: Color(0xFF64748B),
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (sel != null) ...[
                Text(
                  sel,
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    color: cs.primary,
                  ),
                ),
                sep(),
              ],
              if (!narrow) ...[Text(_coordText, style: numStyle), sep()],
              InkWell(
                onTap: () => setState(() => _snap = !_snap),
                borderRadius: BorderRadius.circular(4),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 5,
                    vertical: 2,
                  ),
                  child: Text(
                    _snap ? 'SNAP 0.25' : 'SNAP OFF',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      color: _snap ? cs.primary : cs.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
              sep(),
              if (!narrow) Text(_zoomText, style: numStyle),
            ],
          );
        },
      ),
    );
  }

  // ---------- shortcut HUD ----------

  static const _hudSections = [
    (
      'TOOLS',
      [
        ('A', 'select / move'),
        ('M', 'move - pick object, click to place'),
        ('G', 'rotate - pick, spin to any angle, click'),
        ('long-press', 'carry object - wheel / R rotates'),
        ('W', 'wall chain'),
        ('R', 'rect footprint'),
        ('P', 'poly footprint'),
        ('B', 'place block'),
        ('E', 'eraser - click or drag to delete'),
        ('D', 'dimension - drag between two points'),
        ('R', 'rotate block 15° (block ctx)'),
        ('Enter', 'finish chain / polygon'),
        ('Del', 'delete selected'),
      ],
    ),
    (
      'CANVAS',
      [
        ('drag', 'orbit camera (3D)'),
        ('shift-drag', 'pan camera (3D)'),
        ('mid-drag', 'pan (both panes)'),
        ('space-drag', 'pan (plan)'),
        ('wheel', 'zoom'),
        ('dbl-click sash', 'reset split 50/50'),
      ],
    ),
    (
      'VIEW',
      [
        ('1', 'plan only'),
        ('2', 'split'),
        ('3', '3D only'),
        ('F', '3D focus toggle'),
        ('Esc', 'cancel / back to split'),
      ],
    ),
    (
      'EDIT',
      [
        ('Ctrl+C', 'copy selected'),
        ('Ctrl+X', 'cut selected'),
        ('Ctrl+V', 'paste at pointer'),
        ('Ctrl+Z', 'undo'),
        ('? / F1', 'this card'),
      ],
    ),
  ];

  Widget _hudCard(ColorScheme cs) {
    Widget keyCap(String k) => Container(
      constraints: const BoxConstraints(minWidth: 24),
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      margin: const EdgeInsets.only(right: 7),
      decoration: BoxDecoration(
        color: const Color(0xFFF1F5F9),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: const Color(0xFFCBD5E1)),
      ),
      child: Text(
        k,
        textAlign: TextAlign.center,
        style: const TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          color: Color(0xFF334155),
        ),
      ),
    );
    return Material(
      elevation: 8,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        width: 252,
        padding: const EdgeInsets.fromLTRB(12, 10, 10, 12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: const Color(0xFFE2E8F0)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  'SHORTCUTS',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.1,
                    color: cs.onSurfaceVariant,
                  ),
                ),
                const Spacer(),
                InkWell(
                  onTap: () => setState(() => _hud = false),
                  borderRadius: BorderRadius.circular(4),
                  child: const Padding(
                    padding: EdgeInsets.all(2),
                    child: Icon(
                      Icons.close,
                      size: 14,
                      color: Color(0xFF64748B),
                    ),
                  ),
                ),
              ],
            ),
            for (final (title, rows) in _hudSections) ...[
              const SizedBox(height: 9),
              Text(
                title,
                style: TextStyle(
                  fontSize: 9,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.2,
                  color: cs.primary,
                ),
              ),
              const SizedBox(height: 3),
              for (final (k, d) in rows)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 1.6),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 88,
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: keyCap(k),
                        ),
                      ),
                      Expanded(
                        child: Text(
                          d,
                          style: const TextStyle(
                            fontSize: 10.5,
                            color: Color(0xFF475569),
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  /// Sheet-template setup for GENERATE: paper size + orientation.
  /// Landscape is the drafting default; the choice persists in the
  /// project so every sheet set matches.
  Future<void> _sheetSetup() async {
    var paper = est.sheetPaper;
    var landscape = est.sheetLandscape;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: const Text('Sheet template'),
          content: SizedBox(
            width: 300,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'PAPER SIZE',
                  style: TextStyle(fontSize: 11, letterSpacing: 0.4),
                ),
                const SizedBox(height: 6),
                DropdownButtonFormField<String>(
                  initialValue: paper,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    isDense: true,
                    border: OutlineInputBorder(),
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 8,
                    ),
                  ),
                  items: [
                    for (final e in kPaperSizes.entries)
                      DropdownMenuItem(
                        value: e.key,
                        child: Text(
                          '${e.key}  —  ${e.value.$1.toInt()} x ${e.value.$2.toInt()} mm',
                          style: const TextStyle(fontSize: 13),
                        ),
                      ),
                  ],
                  onChanged: (v) => setD(() => paper = v ?? paper),
                ),
                const SizedBox(height: 14),
                const Text(
                  'ORIENTATION',
                  style: TextStyle(fontSize: 11, letterSpacing: 0.4),
                ),
                const SizedBox(height: 6),
                SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(
                      value: true,
                      icon: Icon(Icons.crop_landscape, size: 16),
                      label: Text('Landscape'),
                    ),
                    ButtonSegment(
                      value: false,
                      icon: Icon(Icons.crop_portrait, size: 16),
                      label: Text('Portrait'),
                    ),
                  ],
                  selected: {landscape},
                  onSelectionChanged: (s) => setD(() => landscape = s.first),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Apply'),
            ),
          ],
        ),
      ),
    );
    if (ok != true) return;
    setState(() {
      est.sheetPaper = paper;
      est.sheetLandscape = landscape;
      est.update();
    });
  }
}
