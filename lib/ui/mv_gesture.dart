part of 'model_view.dart';

// ignore_for_file: invalid_use_of_protected_member

// Split from model_view.dart (1k-line cap): all hit-testing,
// snapping, drag/gesture handlers, the scale-gizmo math, sheet
// generation and the OBJ/STL import flow.

const _kPlanSafe = EdgeInsets.fromLTRB(20, 48, 20, 34);
const _k3DSafe = EdgeInsets.fromLTRB(20, 46, 20, 36);

// volume color cycle — parts get distinct soft tones as they're added
const _palette = [
  0xFF90A4AE,
  0xFFBCAAA4,
  0xFFA5D6A7,
  0xFF90CAF9,
  0xFFE6EE9C,
  0xFFCE93D8,
  0xFFFFCC80,
  0xFF80CBC4,
];

extension _MvGestures on _ModelViewState {
  double _w(double v) => _snap ? (v * 4).round() / 4 : v; // 0.25 m snap

  /// The point a typed distance commits to: `last + dir(cursor)*v`.
  /// The direction reads the snap-resolved hover target, so axis
  /// inference keeps typed walls orthogonal — AutoCAD direct
  /// distance entry semantics.
  Offset? _dimPoint(Offset last) {
    final v = double.tryParse(_dimIn);
    if (v == null || v <= 0) return null;
    final tgt = _inPlan
        ? (_snap ? _snapPt(_hover, _pScale).p : _hover)
        : _hover3 != null
        ? _snapPt(_s2g(_hover3!, _vp3), _z3, _projGround).p
        : _hover;
    final d = tgt - last;
    return d.distance < 1e-9 ? null : last + d / d.distance * v;
  }

  /// The point a typed offset commits to with an EMPTY wall chain:
  /// [v] meters along the wall/volume segment nearest the cursor,
  /// measured from whichever endpoint the cursor's projection is
  /// closer to — exact T-junction placement ("type 2.0, wall starts
  /// 2 m from the corner") without a second click or a manual dim.
  /// The record carries the anchor corner so the painter can draw
  /// the measurement leader. Only engages when the cursor is within
  /// ~14 screen px of a seg — a stray digit in open space must not
  /// teleport the chain start onto a far wall.
  ({Offset p, Offset anchor})? _edgeOffset(double v) {
    if (v <= 0) return null;
    final pxPerM = _inPlan ? _pScale : _z3;
    final tgt = _inPlan
        ? (_snap ? _snapPt(_hover, _pScale).p : _hover)
        : _hover3 != null
        ? _snapPt(_s2g(_hover3!, _vp3), _z3, _projGround).p
        : _hover;
    (Offset, Offset)? seg;
    Offset? foot;
    var bd = double.infinity;
    for (final (a, b) in _snapSources().$2) {
      final d = b - a;
      final l2 = d.dx * d.dx + d.dy * d.dy;
      if (l2 < 1e-12) continue;
      final t = (((tgt - a).dx * d.dx + (tgt - a).dy * d.dy) / l2).clamp(
        0.0,
        1.0,
      );
      final q = a + d * t;
      final dd = (q - tgt).distance;
      if (dd < bd) {
        bd = dd;
        seg = (a, b);
        foot = q;
      }
    }
    if (seg == null || bd * pxPerM > 14) return null;
    final a = seg.$1, b = seg.$2;
    final d = b - a, len = d.distance;
    final fromA = (foot! - a).distance <= (foot - b).distance;
    final anchor = fromA ? a : b;
    final u = (fromA ? d : -d) / len;
    return (p: anchor + u * math.min(v, len), anchor: anchor);
  }

  /// Digit capture for direct distance entry — only while a wall/
  /// poly chain is open. Returns true when the key was consumed:
  /// digits/'.' accumulate, Backspace edits, Esc clears (chain stays
  /// alive — a second Esc cancels as usual), Enter commits.
  bool _dimKey(KeyDownEvent e) {
    final chain = switch (_tool) {
      _MTool.wall => _wall,
      _MTool.poly => _poly,
      _ => const <Offset>[],
    };
    // the wall tool also takes digits BEFORE the first point — the
    // typed value is an offset along the existing wall nearest the
    // cursor, so an intersection wall can start at an exact distance
    // from the corner without any extra clicks
    final preFirst = _tool == _MTool.wall && chain.isEmpty;
    if (chain.isEmpty && !preFirst) {
      _dimIn = '';
      return false;
    }
    // digits only capture while the pointer is over a canvas — the
    // 1/2/3 viewport shortcuts must keep working when a chain is
    // open but the cursor is on the toolbar/panels
    if (!_inPlan && _hover3 == null) return false;
    final k = e.logicalKey;
    if (k == LogicalKeyboardKey.backspace) {
      if (_dimIn.isNotEmpty) {
        setState(() => _dimIn = _dimIn.substring(0, _dimIn.length - 1));
      }
      return true;
    }
    if (k == LogicalKeyboardKey.escape) {
      if (_dimIn.isNotEmpty) {
        setState(() => _dimIn = '');
        return true;
      }
      return false;
    }
    if (k == LogicalKeyboardKey.enter || k == LogicalKeyboardKey.numpadEnter) {
      final p = preFirst
          ? _edgeOffset(double.tryParse(_dimIn) ?? -1)?.p
          : _dimPoint(chain.last);
      if (p != null) {
        setState(() {
          chain.add(p);
          _dimIn = '';
        });
      }
      return true;
    }
    final ch = e.character;
    if (ch != null &&
        ch.length == 1 &&
        ((ch.codeUnitAt(0) >= 48 && ch.codeUnitAt(0) <= 57) || ch == '.')) {
      if (!(ch == '.' && _dimIn.contains('.'))) {
        setState(() => _dimIn += ch);
      }
      return true;
    }
    return false;
  }

  /// SketchUp-style inference for a world point: nearest wall/volume/
  /// block/chain endpoint within ~9 screen px wins, then a segment
  /// midpoint, else the 0.25m grid. `pxPerM` is the view's px-per-meter
  /// (`_pScale` plan, `_z3` 3D); a [proj] projector can be passed so
  /// the radius is measured in screen px where the view distorts
  /// world distance (3D ground foreshortening). The result is what a
  /// click commits — glyph and snap are one truth.
  /// The inference sources shared by [_snapPt] and [_edgeOffset] —
  /// every wall/volume/block/chain endpoint plus wall/volume/chain
  /// segments, so click snaps and typed offsets read one truth.
  (List<Offset>, List<(Offset, Offset)>) _snapSources() {
    final m = _sel;
    final eps = <Offset>[];
    final segs = <(Offset, Offset)>[];
    void poly(List<double> flat, bool closed) {
      for (var i = 0; i + 3 < flat.length; i += 2) {
        final a = Offset(flat[i], flat[i + 1]);
        final b = Offset(flat[i + 2], flat[i + 3]);
        eps.add(a);
        segs.add((a, b));
      }
      final n = flat.length;
      if (n >= 2) eps.add(Offset(flat[n - 2], flat[n - 1]));
      if (closed && n >= 4) {
        segs.add((Offset(flat[n - 2], flat[n - 1]), Offset(flat[0], flat[1])));
      }
    }

    if (m != null) {
      for (final wl in m.walls) {
        poly(wl.pts, false);
      }
      for (final v in m.volumes) {
        poly(v.fp, true);
      }
      eps.addAll(m.blocks.map((b) => Offset(b.x, b.y)));
    }
    final chain = switch (_tool) {
      _MTool.wall => _wall,
      _MTool.poly => _poly,
      _ => const <Offset>[],
    };
    for (var i = 0; i < chain.length; i++) {
      eps.add(chain[i]);
      if (i > 0) segs.add((chain[i - 1], chain[i]));
    }
    if (_rect0 != null) eps.add(_rect0!);
    return (eps, segs);
  }

  SnapTarget _snapPt(Offset w, double pxPerM, [Offset Function(Offset)? proj]) {
    if (!_snap) return SnapTarget(w, SnapKind.grid);
    final (eps, segs) = _snapSources();
    return snapTarget(
      w,
      step: 0.25,
      tol: proj == null ? 9 / pxPerM : 9.0,
      endpoints: eps,
      segments: segs,
      proj: proj,
    );
  }

  // ---------- plan transforms ----------

  Offset _w2s(Offset w, Size s) =>
      Offset(_pOff.dx + w.dx * _pScale, _pOff.dy - w.dy * _pScale);
  Offset _s2w(Offset p, Size s) =>
      Offset((p.dx - _pOff.dx) / _pScale, (_pOff.dy - p.dy) / _pScale);

  /// Chrome-aware safe area for fit-to-content: the pane's floating
  /// controls must never be underlapped by fitted geometry. Plan:
  /// top-right fit/maximize icon row (~44px) and the bottom-right
  /// view caption (~30px). 3D: top-left camera-preset chip row +
  /// top-right icons (~44px) and the bottom captions/hints (~34px).

  void _fitPlan([Size? vp]) {
    final m = _sel;
    final bb = m?.bounds;
    final size = vp ?? _lastVp ?? const Size(600, 400);
    final (x0, y0, x1, y1, _) = bb ?? (0.0, 0.0, 12.0, 8.0, 3.0);
    // pad the fitted bounds for ANNOTATION overshoot — wall dim
    // labels sit ~0.22m+text off the geometry and block names hang
    // below their point, so fitting raw bounds clips edge labels
    // mid-glyph at anything above ~180 px/m zoom
    const labelPad = 0.7;
    final w = math.max(x1 - x0 + labelPad * 2, 1),
        d = math.max(y1 - y0 + labelPad * 2, 1);
    const safe = _kPlanSafe;
    final sw = math.max(size.width - safe.horizontal, 40.0),
        sh = math.max(size.height - safe.vertical, 40.0);
    setState(() {
      _pScale = math.min(sw / w, sh / d).clamp(4.0, 400.0);
      // center inside the SAFE rect — not the raw pane rect — so the
      // margin stays clear of the floating controls on every side
      final cx = safe.left + sw / 2, cy = safe.top + sh / 2;
      _pOff = Offset(
        cx - (x0 + x1) / 2 * _pScale,
        cy + (y0 + y1) / 2 * _pScale,
      );
    });
  }

  void _zoomPlan(Offset focal, double f) {
    setState(() {
      final ns = (_pScale * f).clamp(4.0, 400.0);
      final t = ns / _pScale;
      _pOff = focal - (focal - _pOff) * t;
      _pScale = ns;
    });
  }

  // ---------- footprint editing ----------

  Volume3d? _volAt(Offset w) {
    final m = _sel;
    if (m == null) return null;
    for (var i = m.volumes.length - 1; i >= 0; i--) {
      if (m.volumes[i].contains(w)) return m.volumes[i];
    }
    return null;
  }

  Wall3d? _wallAt(Offset w) {
    final m = _sel;
    if (m == null) return null;
    final tol = 6 / _pScale + 0.02;
    Wall3d? best;
    var bd = double.infinity;
    for (final wl in m.walls) {
      final d = wl.distTo(w) - wl.thickness / 2;
      if (d < bd && d <= tol) {
        bd = d;
        best = wl;
      }
    }
    return best;
  }

  Block3d? _blkAt(Offset w) {
    final m = _sel;
    if (m == null) return null;
    for (var i = m.blocks.length - 1; i >= 0; i--) {
      final b = m.blocks[i];
      final def = cadBlock(b.def);
      if (def == null) continue;
      final fp = blockFootprint(b, def);
      // point-in-polygon over the rotated bbox
      var inside = false;
      for (var j = 0; j < fp.length; j++) {
        final k = (j + 1) % fp.length;
        final pi = fp[j], pj = fp[k];
        if (((pi.dy > w.dy) != (pj.dy > w.dy)) &&
            (w.dx <
                (pj.dx - pi.dx) * (w.dy - pi.dy) / (pj.dy - pi.dy) + pi.dx)) {
          inside = !inside;
        }
      }
      // the footing pad is drawn axis-aligned beyond the footprint —
      // clicking it must select its column too
      if (!inside && b.footing && (b.def == 'col-sq' || b.def == 'col-rd')) {
        final hw = footingFor(def.w * b.sx * b.scale, b.footW).w / 2;
        inside = (w.dx - b.x).abs() <= hw && (w.dy - b.y).abs() <= hw;
      }
      if (inside) return b;
    }
    return null;
  }

  void _clearSel() {
    _vol = null;
    _wallSel = null;
    _blkSel = null;
  }

  /// A draw/drop gesture implies a model — SketchUp never leaves the
  /// canvas dead: with none selected (fresh project, all deleted) the
  /// first interaction creates one instead of swallowing the input.
  Model3d _ensureModel() {
    var m = _sel;
    if (m == null) {
      m = est.addModel('Model ${est.models.length + 1}');
      _sel = m;
      WidgetsBinding.instance.addPostFrameCallback((_) => _fitPlan());
    }
    return m;
  }

  /// Shared by plan tap, 3D tap and library drag-drop: place [def] at
  /// world point [w], select the new part.
  /// Auto-seat a wall-going block onto the nearest wall —
  /// `seatOnWall` handles openings (centerline cut) and wall-hung
  /// mounts (face offset); `seatColumnOnWall` drops columns onto a
  /// wall endpoint / centerline / face-flush edge. The seat carries
  /// the host wall's `base` into `b.bz` so upper-storey walls lift
  /// the block to their floor. Returns true when re-seated.
  bool _seatOpening(Model3d m, Block3d b) {
    final def = cadBlock(b.def);
    if (def == null) return false;
    if (isTrussDef(b.def)) {
      // trusses bear on wall TOP PLATES — the seat carries the wall
      // top into bz and turns the span across the bearing walls
      final seat = seatTrussOnWalls(
        m,
        Offset(b.x, b.y),
        b.rot,
        def.w * b.sx * b.scale,
        ignore: b,
      );
      if (seat == null) return false;
      b.x = seat.$1.dx;
      b.y = seat.$1.dy;
      b.rot = seat.$2;
      b.bz = seat.$3;
      return true;
    }
    if (b.def == 'col-sq' || b.def == 'col-rd') {
      final seat = seatColumnOnWall(
        m,
        Offset(b.x, b.y),
        def.w * b.sx * b.scale,
      );
      if (seat == null) return false;
      b.x = seat.$1.dx;
      b.y = seat.$1.dy;
      b.rot = seat.$2;
      b.bz = seat.$3;
      return true;
    }
    final seat = seatOnWall(m, def, Offset(b.x, b.y));
    if (seat == null) return false;
    b.x = seat.$1.dx;
    b.y = seat.$1.dy;
    b.rot = seat.$2;
    b.bz = seat.$3;
    return true;
  }

  /// Free-space drop: stand the block on the highest volume top under
  /// the point — the slab/massing "on face" contract walls give
  /// wall-going defs. Leaves `bz` alone when the point is over bare
  /// ground (SketchUp keeps the carried height off-face).
  void _standOnVolume(Model3d m, Block3d b) {
    final top = volumeTopAt(m, Offset(b.x, b.y));
    if (top.isFinite) b.bz = top;
  }

  void _placeBlock(CadBlock def, Offset w) {
    final m = _ensureModel();
    final b = Block3d(def: def.id, x: w.dx, y: w.dy, rot: _blkRot);
    // wall-going defs glue to the nearest wall (position, direction
    // AND floor level come with the seat); free-standing pieces stand
    // on the volume face under the drop point when there is one
    if (!_seatOpening(m, b)) _standOnVolume(m, b);
    // a truss can't land inside another — the seat's ridge-grid snap
    // redirects same-line drops to a free bay; this catches stacks
    // the snap can't (no walls nearby, cross-rotation overlaps)
    if (isTrussDef(b.def) &&
        trussSpotTaken(m, Offset(b.x, b.y), ignore: b)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('A truss already occupies this spot')),
      );
      return;
    }
    _pushUndo();
    m.blocks.add(b);
    setState(() {
      _clearSel();
      _blkSel = b;
    });
    est.update();
  }

  /// MOVE command: pick up the block under [w] (or take [b]
  /// directly, e.g. the current selection), or - when one is already
  /// carried - drop it at the snap-resolved [w]. The carried block's
  /// position is untouched until the drop, so Esc never needs undo.
  /// A wall-going block re-seats exactly like a fresh placement.
  void _moveTap(Offset w, {Block3d? b}) {
    final m = _sel;
    final grab = b ?? (m == null ? null : _blkAt(w));
    if (_moving == null) {
      if (grab != null) {
        setState(() {
          _clearSel();
          _blkSel = grab;
          _moving = grab;
        });
      }
      return;
    }
    final mv = _moving!;
    _pushUndo();
    final ox = mv.x, oy = mv.y;
    mv.x = w.dx;
    mv.y = w.dy;
    // re-seat onto walls like a fresh drop (openings + columns);
    // off-wall drops stand on the volume face under the point
    if (m != null && !_seatOpening(m, mv)) _standOnVolume(m, mv);
    // refused: the drop would stack this truss inside another
    if (m != null &&
        isTrussDef(mv.def) &&
        trussSpotTaken(m, Offset(mv.x, mv.y), ignore: mv)) {
      mv.x = ox;
      mv.y = oy;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('A truss already occupies that spot'),
        ),
      );
    }
    setState(() => _moving = null);
    est.update();
  }

  // ---------- long-press carry ----------

  /// Long-press = pick up the block under the press and carry it live
  /// (same ghost as the M command — drag moves, wheel/R rotates).
  /// A press on empty space falls back to canvas navigation instead.
  void _planLpStart(Offset p, Size vp) {
    if (_midPan != null || _midBlock) return;
    final w = _s2w(p, vp);
    final b = _blkAt(Offset(_w(w.dx), _w(w.dy)));
    if (b != null) {
      setState(() {
        _clearSel();
        _blkSel = b;
        _moving = b;
        _lpCarry = true;
        _tool = _MTool.move;
        _hover = w;
      });
    } else {
      _lpPan = p;
    }
  }

  void _planLpUpdate(Offset p, Size vp) {
    final l = _lpPan;
    if (_moving != null) {
      setState(() => _hover = _s2w(p, vp));
    } else if (l != null) {
      setState(() {
        _pOff += p - l;
        _lpPan = p;
      });
    }
  }

  void _planLpEnd(Offset p, Size vp) {
    _lpPan = null;
    _lpCarry = false;
    if (_moving == null) return;
    _moveTap(_snapPt(_s2w(p, vp), _pScale).p);
  }

  void _planLpCancel() {
    _lpPan = null;
    // a quick tap LOSES the long-press recognizer — only release a
    // carry this gesture itself armed (never an M-command carry)
    if (_lpCarry && _moving != null) setState(() => _moving = null);
    _lpCarry = false;
  }

  /// 3D long-press: over a block = carry it on the ground plane; over
  /// empty space = orbit the camera exactly like a plain drag.
  void _modelLpStart(Offset p, Size vp) {
    if (_midBlock) return;
    final hit = _pick3(p, vp);
    if (hit is Block3d) {
      setState(() {
        _clearSel();
        _blkSel = hit;
        _moving = hit;
        _lpCarry = true;
        _tool = _MTool.move;
        _hover3 = p;
      });
    } else {
      _lpOrbit = true;
      _lpLast3 = p;
    }
  }

  void _modelLpUpdate(LongPressMoveUpdateDetails d, Size vp) {
    if (_moving != null) {
      setState(() => _hover3 = d.localPosition);
    } else if (_lpOrbit) {
      final last = _lpLast3;
      _lpLast3 = d.localPosition;
      if (last == null) return;
      final delta = d.localPosition - last;
      setState(() {
        _drag3 = true;
        if (HardwareKeyboard.instance.isShiftPressed) {
          _o3 += delta;
        } else {
          _yaw += delta.dx * 0.012;
          _pitch = (_pitch + delta.dy * 0.012).clamp(0.05, math.pi / 2);
        }
      });
    }
  }

  void _modelLpEnd(Offset p, Size vp) {
    _lpOrbit = false;
    _lpLast3 = null;
    _lpCarry = false;
    if (_moving == null) return;
    if (_groundEditable) {
      _moveTap(_snapPt(_s2g(p, vp), _z3, _projGround).p);
    } else {
      setState(() => _moving = null);
    }
  }

  void _modelLpCancel() {
    _lpOrbit = false;
    _lpLast3 = null;
    _drag3 = false;
    if (_lpCarry && _moving != null) setState(() => _moving = null);
    _lpCarry = false;
  }

  // ---------- rotate command (G) ----------

  /// Free-rotation preview at world point [w] (SketchUp-style): the
  /// block turns so the cursor direction from its centre follows the
  /// spin — the FIRST cursor position anchors it so the carry never
  /// jumps; `_rotBias` is the wheel fine-tune on top.
  double _rotPreview(Offset w) {
    final r = _rotating!;
    final a = math.atan2(w.dy - r.y, w.dx - r.x);
    final anchor = _rotAnchor ??= a;
    return r.rot + (a - anchor) + _rotBias;
  }

  /// ROTATE command (G): pick the block under [w] (or take [b]
  /// directly), spin it with the cursor, click again to commit the
  /// previewed angle. The real `rot` is untouched until commit, so
  /// Esc cancels with no undo needed.
  void _rotTap(Offset w, {Block3d? b}) {
    final m = _sel;
    final grab = b ?? (m == null ? null : _blkAt(w));
    if (_rotating == null) {
      if (grab != null) {
        setState(() {
          _clearSel();
          _blkSel = grab;
          _rotating = grab;
          _rotAnchor = math.atan2(w.dy - grab.y, w.dx - grab.x);
          _rotBias = 0;
        });
      }
      return;
    }
    final r = _rotating!;
    _pushUndo();
    r.rot = _rotPreview(w);
    setState(() {
      _rotating = null;
      _rotAnchor = null;
      _rotBias = 0;
    });
    est.update();
  }

  /// [loop]: the click landed back on the FIRST point — append it so
  /// the polyline gains the closing segment; without it the wall is
  /// an open chain with a gap between last and first ("the last
  /// click of the first wall does not close")
  void _closeWall([bool loop = false]) {
    final m = _sel;
    if (m == null || _wall.length < 2) {
      setState(() => _wall.clear());
      return;
    }
    _pushUndo();
    final pts = <double>[
      for (final p in _wall) ...[p.dx, p.dy],
      if (loop && (_wall.last - _wall.first).distance > 1e-6) ...[
        _wall.first.dx,
        _wall.first.dy,
      ],
    ];
    final w = Wall3d(
      name: 'Wall ${m.walls.length + 1}',
      points: pts,
      thickness: _wallT,
      height: _wallH,
      argb: _palette[m.walls.length % _palette.length],
    );
    m.walls.add(w);
    setState(() {
      _wall.clear();
      _clearSel();
      _wallSel = w;
    });
    est.update();
  }

  void _delSel() {
    final m = _sel;
    if (m == null) return;
    final v = _vol, w = _wallSel, b = _blkSel;
    if (v != null || w != null || b != null) _pushUndo();
    if (v != null) m.volumes.remove(v);
    if (w != null) m.walls.remove(w);
    if (b != null) m.blocks.remove(b);
    if (b != null && _moving == b) _moving = null;
    if (b != null && _rotating == b) _rotating = null;
    setState(_clearSel);
    est.update();
  }

  // ---------- copy / paste ----------

  void _copySel() {
    final b = _blkSel, w = _wallSel, v = _vol;
    if (b != null) {
      _clip = ('block', b.toJson());
    } else if (w != null) {
      _clip = ('wall', w.toJson());
    } else if (v != null) {
      _clip = ('volume', v.toJson());
    }
  }

  void _cutSel() {
    _copySel();
    _delSel();
  }

  /// World point under the pointer (snap-resolved) in whichever pane
  /// is hovered, or null — the paste drops the copy there like a
  /// fresh placement, instead of an invisible exact-duplicate.
  Offset? _pastePoint() {
    if (_inPlan) return _snapPt(_hover, _pScale).p;
    if (_hover3 != null) {
      return _snapPt(_s2g(_hover3!, _vp3), _z3, _projGround).p;
    }
    return null;
  }

  void _pasteClip() {
    final c = _clip, m = _sel;
    if (c == null || m == null) return;
    // fresh copy each paste: JSON round-trip, new uuid, so repeated
    // Ctrl+V drops independent parts
    final j = Map<String, dynamic>.from(c.$2)..remove('id');
    final at = _pastePoint();
    _pushUndo();
    switch (c.$1) {
      case 'block':
        final b = Block3d.fromJson(j);
        if (at != null) {
          b.x = at.dx;
          b.y = at.dy;
        } else {
          b.x += 0.5;
          b.y += 0.5;
        }
        _seatOpening(m, b); // columns/openings re-seat onto walls
        // pasted onto an occupied truss bay? refuse the stack like a
        // fresh placement would (the move command reverts instead)
        if (isTrussDef(b.def) &&
            trussSpotTaken(m, Offset(b.x, b.y), ignore: b)) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('A truss already occupies this spot'),
            ),
          );
          break;
        }
        m.blocks.add(b);
        setState(() {
          _clearSel();
          _blkSel = b;
        });
      case 'wall':
        final wl = Wall3d.fromJson(j);
        _shiftFp(wl.pts, at);
        m.walls.add(wl);
        setState(() {
          _clearSel();
          _wallSel = wl;
        });
      default:
        final v = Volume3d.fromJson(j);
        _shiftFp(v.fp, at);
        m.volumes.add(v);
        setState(() {
          _clearSel();
          _vol = v;
        });
    }
    est.update();
  }

  /// Translate a flat x,y footprint: bbox center lands on [at], or a
  /// fixed +0.5/+0.5 nudge when the pointer is off-canvas.
  void _shiftFp(List<double> fp, Offset? at) {
    var x0 = double.infinity, y0 = double.infinity;
    var x1 = -double.infinity, y1 = -double.infinity;
    for (var i = 0; i + 1 < fp.length; i += 2) {
      x0 = math.min(x0, fp[i]);
      x1 = math.max(x1, fp[i]);
      y0 = math.min(y0, fp[i + 1]);
      y1 = math.max(y1, fp[i + 1]);
    }
    if (!x0.isFinite) return;
    final off = at != null
        ? at - Offset((x0 + x1) / 2, (y0 + y1) / 2)
        : const Offset(0.5, 0.5);
    for (var i = 0; i + 1 < fp.length; i += 2) {
      fp[i] += off.dx;
      fp[i + 1] += off.dy;
    }
  }

  void _addRect(Offset a, Offset b) {
    final m = _ensureModel();
    final x0 = math.min(a.dx, b.dx), x1 = math.max(a.dx, b.dx);
    final y0 = math.min(a.dy, b.dy), y1 = math.max(a.dy, b.dy);
    if (x1 - x0 < 0.3 || y1 - y0 < 0.3) return;
    _pushUndo();
    final v = Volume3d(
      name: 'Volume ${m.volumes.length + 1}',
      footprint: [x0, y0, x1, y0, x1, y1, x0, y1],
      argb: _palette[m.volumes.length % _palette.length],
    );
    m.volumes.add(v);
    setState(() {
      _clearSel();
      _vol = v;
      _tool = _MTool.select;
    });
    est.update();
  }

  void _closePoly() {
    if (_poly.length < 3) return;
    final m = _ensureModel();
    _pushUndo();
    final fp = <double>[
      for (final p in _poly) ...[p.dx, p.dy],
    ];
    var v = Volume3d(
      name: 'Volume ${m.volumes.length + 1}',
      footprint: fp,
      argb: _palette[m.volumes.length % _palette.length],
    );
    if (v.signedArea < 0) {
      v = Volume3d(
        name: v.name,
        footprint: [
          for (var i = fp.length - 2; i >= 0; i -= 2) ...[fp[i], fp[i + 1]],
        ],
        argb: v.argb,
      );
    }
    m.volumes.add(v);
    setState(() {
      _poly.clear();
      _clearSel();
      _vol = v;
      _tool = _MTool.select;
    });
    est.update();
  }

  void _esc() {
    if (!_hud && _wall.length >= 2) {
      _closeWall();
      return;
    }
    setState(() {
      if (_hud) {
        _hud = false;
      } else if (_moving != null) {
        _moving = null; // release the carried block - nothing moved
      } else if (_rotating != null) {
        // release the spin carry - the real rot was never touched
        _rotating = null;
        _rotAnchor = null;
        _rotBias = 0;
      } else if (_wall.isNotEmpty) {
        _wall.clear();
      } else if (_poly.isNotEmpty) {
        _poly.clear();
      } else if (_rect0 != null) {
        _rect0 = _rectCur = null;
      } else if (_dimA != null) {
        _dimA = _dimB = null;
      } else if (_vol != null || _wallSel != null || _blkSel != null) {
        _clearSel();
      } else if (_tool != _MTool.select) {
        _tool = _MTool.select;
      } else if (_vp != _Vp.split) {
        _vp = _Vp.split;
      }
    });
  }

  // ---------- 3D ----------

  /// Orbit pivot = the SELECTED model's own center — the camera never
  /// swings around the world origin when the project sits off-origin.
  /// CACHED PER BUILD: `_proj3`/`_depth3` call this per VERTEX while
  /// `bounds` walks every wall + block footprint — uncached, each frame
  /// cost O(verts x model) and orbiting a furnished model visibly lagged.
  List<double> get _orbitFocus {
    if (_orbitBuild != _buildNo) {
      _orbitBuild = _buildNo;
      final b = _sel?.bounds;
      _orbitCache =
          (b == null ||
              !b.$1.isFinite ||
              !b.$2.isFinite ||
              !b.$3.isFinite ||
              !b.$4.isFinite ||
              !b.$5.isFinite)
          ? const [0.0, 0.0, 0.0]
          : [(b.$1 + b.$3) / 2, (b.$2 + b.$4) / 2, b.$5 / 2];
    }
    return _orbitCache!;
  }

  Offset _proj3(List<double> p, Size vp) => cam3Project(
    p,
    vp,
    yaw: _yaw,
    pitch: _pitch,
    zoom: _z3,
    off: _o3,
    pivot: _orbitFocus,
  );

  double _depth3(List<double> p) =>
      cam3Depth(p, yaw: _yaw, pitch: _pitch, pivot: _orbitFocus);

  /// True straight-down camera (pitch == pi/2): render-mode sky and
  /// ground shadows are suppressed there — they read as artifacts
  /// from directly overhead. `_render` itself is left stored.
  bool get _topDown => (_pitch - math.pi / 2).abs() < 1e-6;

  /// Zoom-extents (SketchUp "Fit"): project the model bounds' 8
  /// corners at unit zoom, then solve _z3/_o3 so the projected bbox
  /// fills ~80% of the viewport, centered.
  void _fit3() {
    final m = _sel;
    if (m == null || _vp3 == Size.zero) return;
    var b = m.bounds ?? (0.0, 0.0, 10.0, 8.0, 3.0);
    // blocks whose defs no longer resolve leave bounds as inf/-inf —
    // a NaN camera offset would silently blank the view on preset fit
    if (!b.$1.isFinite ||
        !b.$2.isFinite ||
        !b.$3.isFinite ||
        !b.$4.isFinite ||
        !b.$5.isFinite) {
      b = (0.0, 0.0, 10.0, 8.0, 3.0);
    }
    final corners = [
      for (final x in [b.$1, b.$3])
        for (final y in [b.$2, b.$4])
          for (final z in [0.0, b.$5]) [x, y, z],
    ];
    // project at unit zoom with zero offset -> unit-space bbox
    final saveZ = _z3, saveO = _o3;
    _z3 = 1;
    _o3 = Offset.zero;
    final vc = Offset(_vp3.width / 2, _vp3.height / 2);
    var x0 = double.infinity, y0 = double.infinity;
    var x1 = -double.infinity, y1 = -double.infinity;
    for (final c in corners) {
      final u = _proj3(c, _vp3) - vc;
      x0 = math.min(x0, u.dx);
      y0 = math.min(y0, u.dy);
      x1 = math.max(x1, u.dx);
      y1 = math.max(y1, u.dy);
    }
    _z3 = saveZ;
    _o3 = saveO;
    final sx = math.max(x1 - x0, 1e-3), sy = math.max(y1 - y0, 1e-3);
    const safe = _k3DSafe;
    final sw = math.max(_vp3.width - safe.horizontal, 40.0),
        sh = math.max(_vp3.height - safe.vertical, 40.0);
    final z = 0.85 * math.min(sw / sx, sh / sy).clamp(3.0, 600.0);
    setState(() {
      _z3 = z;
      // land the unit-space bbox center on the SAFE rect center —
      // the preset chips row + captions stay clear of the model
      final vcSafe = Offset(safe.left + sw / 2, safe.top + sh / 2);
      _o3 = (vcSafe - vc) - Offset((x0 + x1) / 2, (y0 + y1) / 2) * z;
    });
  }

  /// True 3D picking: project each part's faces to screen and return
  /// the part whose face contains the tap — the NEAREST face wins, so
  /// tapping a wall's side or a block's top selects it even though
  /// the click's ground projection lands beside its footprint.
  Object? _pick3(Offset sp, Size vp) {
    final m = _sel;
    if (m == null) return null;
    Object? best;
    var bestD = double.infinity; // depth sort draws big->small, so the
    // camera-near face is the SMALLEST average depth
    void faceHit(List<List<double>> v, double d, Object part) {
      var inside = false;
      for (var i = 0; i < v.length; i++) {
        final a = _proj3(v[i], vp), b = _proj3(v[(i + 1) % v.length], vp);
        if (((a.dy > sp.dy) != (b.dy > sp.dy)) &&
            (sp.dx < (b.dx - a.dx) * (sp.dy - a.dy) / (b.dy - a.dy) + a.dx)) {
          inside = !inside;
        }
      }
      if (inside && d < bestD) {
        bestD = d;
        best = part;
      }
    }

    void partFaces(List<Face3> faces, Object part) {
      for (final f in faces) {
        var d = 0.0;
        for (final p in f.v) {
          d += _depth3(p);
        }
        faceHit(f.v, d / f.v.length, part);
      }
    }

    for (final v in m.volumes) {
      partFaces(volumeFaces(v), v);
    }
    for (final w in m.walls) {
      partFaces(wallFaces(w), w);
    }
    for (final b in m.blocks) {
      final def = cadBlock(b.def);
      if (def == null) continue;
      final real = blockFaces(b, def);
      if (real.isNotEmpty) {
        partFaces(real, b);
        continue;
      }
      // flat plan symbol — a thin footprint slab stays clickable
      final fp = blockFootprint(b, def);
      partFaces([
        Face3(
          [
            for (final p in fp) [p.dx, p.dy, 0.0],
          ],
          const [0, 0, 1],
          0,
        ),
      ], b);
    }
    return best;
  }

  /// World-space point of the selected block's bounding-box corner or
  /// face center. [i] 0..7 = the 8 local-aabb corners, 8..13 = the six
  /// face centers (+x,-x,+y,-y,+z,-z). Returns null when no block sel.
  List<double>? _blkBoxPt(int i) {
    final b = _blkSel, m = _sel;
    if (b == null || m == null) return null;
    final def = cadBlock(b.def);
    if (def == null) return null;
    final bb = blockLocalBox(def);
    final cx = (bb[0] + bb[3]) / 2, cy = (bb[1] + bb[4]) / 2;
    final cz = (bb[2] + bb[5]) / 2;
    final (lx, ly, lz) = switch (i) {
      0 => (bb[0], bb[1], bb[2]),
      1 => (bb[3], bb[1], bb[2]),
      2 => (bb[3], bb[4], bb[2]),
      3 => (bb[0], bb[4], bb[2]),
      4 => (bb[0], bb[1], bb[5]),
      5 => (bb[3], bb[1], bb[5]),
      6 => (bb[3], bb[4], bb[5]),
      7 => (bb[0], bb[4], bb[5]),
      8 => (bb[3], cy, cz), // +x face
      9 => (bb[0], cy, cz),
      10 => (cx, bb[4], cz), // +y face
      11 => (cx, bb[1], cz),
      12 => (cx, cy, bb[5]), // top
      _ => (cx, cy, bb[2]), // bottom
    };
    final c = math.cos(b.rot), s = math.sin(b.rot);
    return [
      b.x + (lx * b.sx * c - ly * b.sy * s) * b.scale,
      b.y + (lx * b.sx * s + ly * b.sy * c) * b.scale,
      lz * b.sz * b.scale + b.bz,
    ];
  }

  /// Unit world direction of stretch axis [a] (0:+x 1:-x 2:+y 3:-y
  /// 4:+z 5:-z) — follows the block's rotation on plan axes.
  List<double> _axisDir(int a) {
    final b = _blkSel;
    if (b == null) return const [0, 0, 0];
    final c = math.cos(b.rot), s = math.sin(b.rot);
    return switch (a) {
      0 => [c, s, 0.0],
      1 => [-c, -s, 0.0],
      2 => [-s, c, 0.0],
      3 => [s, -c, 0.0],
      4 => [0.0, 0.0, 1.0],
      _ => [0.0, 0.0, -1.0],
    };
  }

  /// Project the bbox corners + 6 face centers; the painter and the
  /// handle hit-test share this cache so what you see is what you grab.
  void _layoutSelBox(Size vp) {
    final b = _blkSel;
    if (b == null) {
      _box3Pts = const [];
      _handles3 = const [];
      return;
    }
    _box3Pts = [for (var i = 0; i < 8; i++) _blkBoxPt(i)!];
    _handles3 = [for (var i = 8; i < 14; i++) _proj3(_blkBoxPt(i)!, vp)];
  }

  /// Index of the face handle under screen point [sp] (8..13 in
  /// _blkBoxPt numbering -> 0..5 axis), or -1.
  int _handleAt(Offset sp) {
    for (var i = 0; i < _handles3.length; i++) {
      if ((_handles3[i] - sp).distance <= 11) return i;
    }
    return -1;
  }

  /// Drag one face handle: ±x/±y scale that axis with the OPPOSITE
  /// face anchored (the dragged face tracks the cursor, SketchUp
  /// scale-grip style); +z resizes height pinned at the base plane;
  /// -z lifts/drops the whole object (wall-mount height).
  void _stretchDrag(int axis, Offset delta) {
    final b = _blkSel;
    final def = b == null ? null : cadBlock(b.def);
    if (b == null || def == null || _vp3 == Size.zero) return;
    final faceW = _blkBoxPt(8 + axis)!;
    final dir = _axisDir(axis);
    final p0 = _proj3(faceW, _vp3);
    final p1 = _proj3([
      faceW[0] + dir[0],
      faceW[1] + dir[1],
      faceW[2] + dir[2],
    ], _vp3);
    final seg = p1 - p0;
    final pxPerM = seg.distance;
    if (pxPerM < 1e-6) return;
    final dm = (delta.dx * seg.dx + delta.dy * seg.dy) / (pxPerM * pxPerM);
    if (dm == 0) return;
    final bb = blockLocalBox(def);
    switch (axis) {
      case 0 || 1:
        final half = (bb[3] - bb[0]) / 2;
        final eff = half * b.sx * b.scale;
        final neu = (eff + dm).clamp(0.05, 500.0);
        final d = neu - eff;
        if (d == 0) return;
        b.sx = (b.sx * neu / eff).clamp(0.02, 200.0);
        b.x += dir[0] * d;
        b.y += dir[1] * d;
      case 2 || 3:
        final half = (bb[4] - bb[1]) / 2;
        final eff = half * b.sy * b.scale;
        final neu = (eff + dm).clamp(0.05, 500.0);
        final d = neu - eff;
        if (d == 0) return;
        b.sy = (b.sy * neu / eff).clamp(0.02, 200.0);
        b.x += dir[0] * d;
        b.y += dir[1] * d;
      case 4: // top face — grow/shrink height, base plane pinned
        final z1 = bb[5];
        if (z1.abs() < 1e-9) return;
        final bot = bb[2] * b.sz * b.scale + b.bz;
        final neu =
            ((bb[5] * b.sz * b.scale + b.bz + dm - b.bz) / (z1 * b.scale))
                .clamp(0.02, 200.0);
        b.sz = neu;
        b.bz = bot - bb[2] * neu * b.scale; // re-pin the base plane
      case 5: // bottom face — lift/drop the whole object (wall-mount)
        b.bz = (b.bz - dm).clamp(-50.0, 50.0);
    }
    _layoutSelBox(_vp3);
  }

  /// Screen point -> world point on the ground plane (z=0). Inverse
  /// of [_proj3]: un-rotate the screen offset, then undo the yaw so a
  /// tap on the 3D canvas lands exactly where the cursor is. This is
  /// what lets users draw/select on the 3D side too.
  Offset _s2g(Offset p, Size vp) {
    final f = _orbitFocus;
    final rx = (p.dx - vp.width / 2 - _o3.dx) / _z3;
    final pz = (vp.height / 2 + _o3.dy - p.dy) / _z3;
    // pz = ry*sin(pitch) + (z - f.z)*cos(pitch); on the ground z = 0
    final ry = (pz + f[2] * math.cos(_pitch)) / math.sin(_pitch);
    final cy = math.cos(_yaw), sy = math.sin(_yaw);
    return Offset(rx * cy + ry * sy + f[0], -rx * sy + ry * cy + f[1]);
  }

  /// Ground world point -> 3D screen px. Snap candidates are compared
  /// in THIS space so the pick radius is a uniform ~9px even where the
  /// camera foreshortens the ground plane (depth axis ÷ sin(pitch)).
  Offset _projGround(Offset w) => _proj3([w.dx, w.dy, 0.0], _vp3);

  // ---------- generate drawing ----------

  void _generate() {
    final m = _sel;
    if (m == null) return;
    if (m.bounds == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Draw some walls or volumes first.')),
      );
      return;
    }
    final dir = Directory('${Directory.systemTemp.path}\\ce_gen')
      ..createSync(recursive: true);
    // one sheet PER VIEW — the user asked for separate sheets per
    // elevation (floor plan, roof, and all four sides)
    const views = [
      (SheetView.plan, 'floorplan'),
      (SheetView.structural, 'structural'),
      (SheetView.roofFrame, 'roofframe'),
      (SheetView.electrical, 'electrical'),
      (SheetView.plumbing, 'plumbing'),
      (SheetView.roof, 'roofplan'),
      (SheetView.front, 'front'),
      (SheetView.rear, 'rear'),
      (SheetView.left, 'left'),
      (SheetView.right, 'right'),
    ];
    var added = 0;
    for (final (v, slug) in views) {
      final path = '${dir.path}\\model_${m.id}_$slug.dxf';
      File(path).writeAsStringSync(
        buildModelSheet(
          m,
          v,
          paper: est.sheetPaper,
          landscape: est.sheetLandscape,
          project: est.project,
        ),
      );
      final did = 'sheet:${m.id}:$slug';
      final nm = '${m.name} — ${kSheetTitle[v]}.dxf';
      DrawingFile? f;
      for (final d in est.drawings) {
        if (d.id == did) f = d;
      }
      if (f == null) {
        est.drawings.add(
          DrawingFile(id: did, path: path, name: nm, kind: 'dxf'),
        );
        added++;
      } else {
        f.path = path;
        f.name = nm;
      }
    }
    // retire the old combined sheet entry if it exists
    est.drawings.removeWhere((d) => d.id == 'sheet:${m.id}');
    est.update();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '${views.length} sheets ${added == views.length ? "added" : "updated"} — floor, structural, electrical, plumbing, roof and 4 elevations are in the DRAWINGS tab.',
        ),
      ),
    );
  }

  /// Import any public `.obj` model (Kenney, Poly Pizza, Blender
  /// exports) as a reusable CAD block. The sibling `.mtl` is picked up
  /// automatically for per-face colors; wildly off-scale downloads are
  /// tamed to furniture size before registering.
  Future<void> _importObj() async {
    final f = await openFile(
      acceptedTypeGroups: [
        const XTypeGroup(label: '3D model', extensions: ['obj', 'stl', 'ifc']),
      ],
    );
    if (f == null) return;
    ObjMesh? om;
    IfcModel? ifc;
    if (f.name.toLowerCase().endsWith('.ifc')) {
      ifc = parseIfc(await f.readAsString());
      om = ifc?.mesh;
    } else if (f.name.toLowerCase().endsWith('.stl')) {
      om = parseStl(await f.readAsBytes());
    } else {
      String? mtl;
      try {
        final mp = f.path.replaceAll(
          RegExp(r'\.obj$', caseSensitive: false),
          '.mtl',
        );
        final mf = File(mp);
        if (await mf.exists()) mtl = await mf.readAsString();
      } catch (_) {}
      om = parseObj(await f.readAsString(), mtlSrc: mtl);
    }
    if (!mounted) return;
    if (om == null || om.faces.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No geometry found in that model.')),
      );
      return;
    }
    final bb = om.bounds;
    final maxD = math.max(
      bb.$4 - bb.$1,
      math.max(bb.$5 - bb.$2, bb.$6 - bb.$3),
    );
    if (maxD > 12) {
      om = om.scaled(4.5 / maxD);
    } else if (maxD < 0.15) {
      om = om.scaled(1.0 / maxD);
    }
    final name = ifc != null && ifc.name != 'IFC object'
        ? ifc.name
        : f.name.replaceAll(
            RegExp(r'\.(obj|stl|ifc)$', caseSensitive: false),
            '',
          );
    final def = registerObjBlock(
      name,
      om,
      opening: ifc?.kind != null,
      sill: ifc?.kind == 'window' ? 0.9 : 0,
    );
    setState(() {
      _blkDef = def;
      _tool = _MTool.block;
      _rightTab = 1;
    });
    est.update();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Imported "$name" — click a canvas to place it.')),
    );
  }

  // ---------- build ----------

  /// Eraser (E): delete whatever the point hits — smallest target
  /// first (block > wall > volume) so a block ON a wall erases the
  /// block. One undo snapshot per stroke (`_erasePushed`), so a
  /// drag-sweep is a single undo step.
  bool _eraseAt(Offset w2) {
    final m = _sel;
    if (m == null) return false;
    final b = _blkAt(w2);
    // a drawn dimension near the stroke erases before the wall under
    // it — point-to-segment within ~8cm picks it up
    int? dimHit;
    if (b == null) {
      for (var i = 0; i < m.dims.length; i++) {
        final d = m.dims[i], a = Offset(d[0], d[1]), e = Offset(d[2], d[3]);
        final ab = e - a;
        final l2 = ab.dx * ab.dx + ab.dy * ab.dy;
        final ap = w2 - a;
        final t = l2 < 1e-9
            ? 0.0
            : ((ap.dx * ab.dx + ap.dy * ab.dy) / l2).clamp(0.0, 1.0);
        if ((w2 - (a + ab * t)).distance < 0.08) {
          dimHit = i;
          break;
        }
      }
    }
    final wl = (b == null && dimHit == null) ? _wallAt(w2) : null;
    final v = (b == null && dimHit == null && wl == null) ? _volAt(w2) : null;
    if (b == null && dimHit == null && wl == null && v == null) {
      return false;
    }
    if (!_erasePushed) {
      _pushUndo();
      _erasePushed = true;
    }
    setState(() {
      if (b != null) {
        m.blocks.remove(b);
        if (_blkSel == b) _blkSel = null;
        if (_moving == b) _moving = null;
        if (_rotating == b) _rotating = null;
      } else if (dimHit != null) {
        m.dims.removeAt(dimHit);
      } else if (wl != null) {
        m.walls.remove(wl);
        if (_wallSel == wl) _wallSel = null;
      } else if (v != null) {
        m.volumes.remove(v);
        if (_vol == v) _vol = null;
      }
    });
    est.update();
    return true;
  }

  void _planStart(Offset p, Size vp) {
    // a middle-button drag pans in the Listener — never starts geometry
    if (_midPan != null || _midBlock) return;
    // CAD convention: SPACEBAR-drag pans regardless of the active
    // tool (middle-button drag is handled in the Listener directly)
    if (HardwareKeyboard.instance.isLogicalKeyPressed(
      LogicalKeyboardKey.space,
    )) {
      _panLast = p;
      return;
    }
    final w = _s2w(p, vp);
    switch (_tool) {
      case _MTool.rect:
        _rect0 = _rectCur = _snapPt(w, _pScale).p;
      case _MTool.select:
        final w2 = Offset(_w(w.dx), _w(w.dy));
        final b = _blkAt(w2);
        final wl = _wallAt(w2);
        final v = _volAt(w2);
        setState(() {
          _clearSel();
          if (b != null) {
            _blkSel = b;
            _moveLast = w;
          } else if (wl != null) {
            _wallSel = wl;
            _moveLast = w;
          } else if (v != null) {
            _vol = v;
            _moveLast = w;
          } else {
            _panLast = p;
          }
          // grabbed a part — snapshot before any move mutates it
          if (b != null || wl != null || v != null) {
            if (_rightTab != 2) _rightTab = 0;
            _pushUndo();
          }
        });
      case _MTool.dim:
        final s = _snapPt(w, _pScale).p;
        _dimA = _dimB = s;
      case _MTool.eraser:
        _erasing = true;
        _eraseAt(Offset(_w(w.dx), _w(w.dy)));
      case _MTool.poly:
      case _MTool.wall:
      case _MTool.block:
      case _MTool.move:
      case _MTool.rotate:
        break; // taps add points / place blocks / pick-drop / spin
    }
  }

  void _planUpdate(Offset p, Size vp) {
    // middle-drag pans via the Listener's own pointer stream
    if (_midPan != null) return;
    // spacebar pan wins over every tool — pan, don't draw
    if (_panLast != null) {
      final d = p - _panLast!;
      setState(() {
        _pOff += d;
        _panLast = p;
      });
      return;
    }
    final w = _s2w(p, vp);
    switch (_tool) {
      case _MTool.rect:
        setState(() => _rectCur = _snapPt(w, _pScale).p);
      case _MTool.select:
        final v = _vol, wl = _wallSel, b = _blkSel, last = _moveLast;
        if ((v != null || wl != null || b != null) && last != null) {
          final dx = _w(w.dx - last.dx), dy = _w(w.dy - last.dy);
          if (dx != 0 || dy != 0) {
            if (v != null) {
              for (var i = 0; i < v.fp.length; i += 2) {
                v.fp[i] += dx;
                v.fp[i + 1] += dy;
              }
            } else if (wl != null) {
              wl.translate(dx, dy);
            } else if (b != null) {
              b.x += dx;
              b.y += dy;
            }
            setState(() => _moveLast = Offset(last.dx + dx, last.dy + dy));
          }
        }
      case _MTool.dim:
        setState(() {
          _hover = w;
          _dimB = _snapPt(w, _pScale).p;
        });
      case _MTool.eraser:
        _hover = w;
        if (_erasing) {
          _eraseAt(Offset(_w(w.dx), _w(w.dy)));
        }
      case _MTool.poly:
      case _MTool.wall:
      case _MTool.block:
      case _MTool.move:
      case _MTool.rotate:
        setState(() => _hover = w);
    }
  }

  void _planEnd() {
    if (_midPan != null || _midBlock) {
      // a middle-drag pan ends here too — commit nothing
      _rect0 = _rectCur = null;
      _moveLast = _panLast = null;
      return;
    }
    if (_tool == _MTool.rect && _rect0 != null && _rectCur != null) {
      _addRect(_rect0!, _rectCur!); // corners already snap-resolved
    }
    // DIM drag-up commits an aligned dimension (A,B already snapped)
    final m0 = _sel, da = _dimA, db = _dimB;
    if (_tool == _MTool.dim &&
        m0 != null &&
        da != null &&
        db != null &&
        (db - da).distance > 0.05) {
      _pushUndo();
      m0.dims.add([da.dx, da.dy, db.dx, db.dy]);
      est.update();
    }
    _dimA = _dimB = null;
    // a moved door/window re-seats onto the nearest wall on drop
    final m = _sel, b = _blkSel;
    if (m != null && b != null && _moveLast != null && _seatOpening(m, b)) {
      est.update();
    }
    _rect0 = _rectCur = null;
    _moveLast = null;
    _panLast = null;
    _erasing = _erasePushed = false;
  }

  void _planTap(Offset p, Size vp) {
    // a middle-release or space-tap is navigation, never geometry
    if (_midBlock ||
        HardwareKeyboard.instance.isLogicalKeyPressed(
          LogicalKeyboardKey.space,
        )) {
      return;
    }
    var w = _snapPt(_s2w(p, vp), _pScale).p;
    _ensureModel(); // any canvas intent means a model exists
    // a pending typed distance overrides the click point — the click
    // only picks the direction, like AutoCAD's direct distance entry
    if (_dimIn.isNotEmpty) {
      final chain = switch (_tool) {
        _MTool.wall => _wall,
        _MTool.poly => _poly,
        _ => const <Offset>[],
      };
      if (chain.isNotEmpty) {
        w = _dimPoint(chain.last) ?? w;
      } else if (_tool == _MTool.wall) {
        w = _edgeOffset(double.tryParse(_dimIn) ?? -1)?.p ?? w;
      }
    }
    // close thresholds carry a WORLD cap beside the px check — at fit
    // zoom (low px/m) a bare px radius swallowed legit chain points
    // and ended the wall early: the "i can't draw" bug
    switch (_tool) {
      case _MTool.poly:
        final dFirst = _poly.isEmpty ? 9e9 : (_poly.first - w).distance;
        final dLast = _poly.isEmpty ? 9e9 : (_poly.last - w).distance;
        if (_poly.length >= 3 && dFirst * _pScale < 18 && dFirst < 0.35) {
          _closePoly();
          return;
        }
        // double-tap on the last point ends the polygon
        if (_poly.length >= 3 && dLast * _pScale < 10 && dLast < 0.13) {
          _closePoly();
          return;
        }
        setState(() {
          _poly.add(w);
          _dimIn = '';
        });
      case _MTool.wall:
        final dFirst = _wall.isEmpty ? 9e9 : (_wall.first - w).distance;
        final dLast = _wall.isEmpty ? 9e9 : (_wall.last - w).distance;
        // tap near the start -> close the wall as a loop
        if (_wall.length >= 3 && dFirst * _pScale < 18 && dFirst < 0.35) {
          _closeWall(true);
          return;
        }
        // tap on the last point (a double-tap lands the same snapped
        // spot twice) -> end the chain there
        if (dLast * _pScale < 10 && dLast < 0.13) {
          _closeWall();
          return;
        }
        setState(() {
          _wall.add(w);
          _dimIn = '';
        });
      case _MTool.block:
        _placeBlock(_blkDef, w);
      case _MTool.move:
        // pick on the raw point like select; drop on the snapped one
        _moveTap(w, b: _blkAt(Offset(_w(_s2w(p, vp).dx), _w(_s2w(p, vp).dy))));
      case _MTool.rotate:
        // pick on the raw point; the spin anchor/commit use it too —
        // rotation never snaps, ANY angle is reachable
        _rotTap(
          Offset(_w(_s2w(p, vp).dx), _w(_s2w(p, vp).dy)),
          b: _blkAt(Offset(_w(_s2w(p, vp).dx), _w(_s2w(p, vp).dy))),
        );
      default:
        break;
    }
  }

  /// Tap on the 3D canvas — same editing contract as the plan side:
  /// the ground projection of the click IS a plan point, so wall
  /// chains, block placement and selection all work from the 3D view.
  /// Ground-plane editing needs a real pitch — near an elevation
  /// view sin(_pitch) ~ 0 and the unprojection explodes, so taps
  /// there only select (screen-space picking stays exact).
  bool get _groundEditable => math.sin(_pitch) > 0.12;

  void _modelTap(Offset p, Size vp) {
    // a middle-release is camera pan, never a place/select tap
    if (_midBlock) return;
    _ensureModel(); // canvas intent implies a model
    final g = _s2g(p, vp);
    final w = _snapPt(g, _z3, _projGround).p;
    switch (_tool) {
      case _MTool.wall:
        if (!_groundEditable) return;
        if (_wall.length >= 3 && (_wall.first - w).distance < 0.35) {
          _closeWall(true);
          return;
        }
        if (_wall.isNotEmpty && (_wall.last - w).distance < 0.13) {
          _closeWall();
          return;
        }
        setState(() => _wall.add(w));
      case _MTool.block:
        if (!_groundEditable) return;
        _placeBlock(_blkDef, w);
      case _MTool.move:
        if (_moving == null) {
          final hit = _pick3(p, vp);
          if (hit is Block3d) _moveTap(w, b: hit);
        } else if (_groundEditable) {
          _moveTap(w); // drop on the snap-resolved ground point
        }
      case _MTool.rotate:
        if (_rotating == null) {
          final hit = _pick3(p, vp);
          if (hit is Block3d && _groundEditable) _rotTap(g, b: hit);
        } else if (_groundEditable) {
          _rotTap(g); // commit the previewed spin
        }
      case _MTool.select:
        final hit = _pick3(p, vp);
        setState(() {
          _clearSel();
          if (hit is Block3d) {
            _blkSel = hit;
          } else if (hit is Wall3d) {
            _wallSel = hit;
          } else if (hit is Volume3d) {
            _vol = hit;
          }
          if (hit != null && _rightTab != 2) _rightTab = 0;
        });
      case _MTool.eraser:
        // 3D drag is camera orbit, so erasing here is per-tap; the
        // screen-space pick already resolves the topmost object
        final hit = _pick3(p, vp);
        final m = _sel;
        if (m != null && hit != null) {
          _pushUndo();
          setState(() {
            if (hit is Block3d) {
              m.blocks.remove(hit);
              if (_blkSel == hit) _blkSel = null;
              if (_moving == hit) _moving = null;
            } else if (hit is Wall3d) {
              m.walls.remove(hit);
              if (_wallSel == hit) _wallSel = null;
            } else if (hit is Volume3d) {
              m.volumes.remove(hit);
              if (_vol == hit) _vol = null;
            }
          });
          est.update();
        }
      case _MTool.dim:
      case _MTool.rect:
      case _MTool.poly:
        // plan-only tools — hint the user via the status strip
        break;
    }
  }

  // ---------- 3D canvas ----------
}
