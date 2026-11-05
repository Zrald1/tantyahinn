part of 'model_view.dart';

/// The 3D camera transform, shared by the painter AND the headless
/// render simulation (test/model_render_test.dart) so the test paints
/// the exact same projection the app does. Public on purpose.
Offset cam3Project(
  List<double> p,
  Size vp, {
  required double yaw,
  required double pitch,
  required double zoom,
  required Offset off,
  List<double>? pivot,
}) {
  final px = pivot == null ? 0.0 : pivot[0];
  final py = pivot == null ? 0.0 : pivot[1];
  final pz = pivot == null ? 0.0 : pivot[2];
  final cy = math.cos(yaw), sy = math.sin(yaw);
  final cp = math.cos(pitch), sp = math.sin(pitch);
  final rx = (p[0] - px) * cy - (p[1] - py) * sy;
  final ry = (p[0] - px) * sy + (p[1] - py) * cy;
  final pzz = ry * sp + (p[2] - pz) * cp;
  return Offset(
    vp.width / 2 + off.dx + rx * zoom,
    vp.height / 2 + off.dy - pzz * zoom,
  );
}

/// Camera-space depth for the painter's-algorithm face sort (same
/// math as [cam3Project]'s depth axis).
double cam3Depth(
  List<double> p, {
  required double yaw,
  required double pitch,
  List<double>? pivot,
}) {
  final px = pivot == null ? 0.0 : pivot[0];
  final py = pivot == null ? 0.0 : pivot[1];
  final pz = pivot == null ? 0.0 : pivot[2];
  final sy = math.sin(yaw), cy = math.cos(yaw);
  final cp = math.cos(pitch), sp = math.sin(pitch);
  return ((p[0] - px) * sy + (p[1] - py) * cy) * cp - (p[2] - pz) * sp;
}

/// Multi-scale plan grid levels for a given screen px-per-meter
/// scale: the base `step` (>=26px between lines, every 5th major),
/// the finer `sub` division (step/4 at >=1m -> 0.25m, step/5 at
/// 0.5m -> 0.10m), and `subAlpha` — the subdivision's fade alpha,
/// ramping 0..0.9 as it gains ~6..15px of room (SketchUp-style
/// smooth fade instead of a pop-in).
@visibleForTesting
({double step, double sub, double subAlpha}) planGridLevels(double pScale) {
  const steps = [0.5, 1.0, 2.0, 5.0, 10.0, 25.0, 50.0];
  var step = steps.last;
  for (final s in steps) {
    if (s * pScale >= 26) {
      step = s;
      break;
    }
  }
  final div = step >= 1.0 ? 4.0 : 5.0;
  final sub = step / div;
  final subPx = sub * pScale;
  final alpha = ((subPx - 5.5) / 9.0).clamp(0.0, 1.0) * 0.9;
  return (step: step, sub: sub, subAlpha: alpha);
}

/// World-anchored grid line positions over [lo, hi]: yields exact
/// multiples of `step` — the shared lattice the 2D and 3D grids
/// both draw, so (0,0) is a line intersection in every view.
@visibleForTesting
Iterable<double> gridLinePositions(double lo, double hi, double step) sync* {
  for (var i = (lo / step).ceil(); i * step <= hi + 1e-9; i++) {
    yield i * step;
  }
}

/// SketchUp-style snap inference kinds — painted as distinct glyphs
/// (endpoint square, midpoint triangle, axis-align diamond, grid plus).
enum SnapKind { endpoint, midpoint, edge, axis, grid }

class SnapTarget {
  const SnapTarget(this.p, this.kind, [this.guides = const [], this.seg]);
  final Offset p;
  final SnapKind kind;

  /// Source vertices the result aligned with (axis inference) — the
  /// painter draws dashed guide lines from each to [p]
  final List<Offset> guides;

  /// The segment an [SnapKind.edge] point was projected onto — lets
  /// the painter show temporary dims to BOTH ends (left/right or
  /// top/bottom) so a T-wall start can be placed at an exact offset.
  final (Offset, Offset)? seg;
}

/// Inference order: the nearest [endpoints] candidate inside `tol`
/// wins; failing that the nearest [segments] midpoint; otherwise the
/// grid-rounded point. Distances are measured in world units unless
/// [proj] maps points into another space first — the 3D view passes a
/// screen projector so the ~9px pick radius stays uniform even where
/// the ground plane is foreshortened by the camera pitch. The
/// returned point IS where a click commits — the glyph is honest.
@visibleForTesting
SnapTarget snapTarget(
  Offset p, {
  required double step,
  double tol = 0,
  List<Offset> endpoints = const [],
  List<(Offset, Offset)> segments = const [],
  Offset Function(Offset p)? proj,
}) {
  var bd = tol;
  Offset? best;
  final sp = proj == null ? p : proj(p);
  double dist(Offset q) => ((proj == null ? q : proj(q)) - sp).distance;
  for (final e in endpoints) {
    final d = dist(e);
    if (d < bd) {
      bd = d;
      best = e;
    }
  }
  if (best != null) return SnapTarget(best, SnapKind.endpoint);
  for (final (a, b) in segments) {
    final mid = (a + b) / 2;
    final d = dist(mid);
    if (d < bd) {
      bd = d;
      best = mid;
    }
  }
  if (best != null) return SnapTarget(best, SnapKind.midpoint);
  // edge inference — the point ON a segment nearest the cursor wins
  // over axis/grid: a T-wall click lands exactly on the existing
  // wall's centerline, where a bare 0.25m grid snap can sit ~12cm
  // off and silently miss the join tolerance
  (Offset, Offset)? bseg;
  for (final (a, b) in segments) {
    final d = b - a;
    final l2 = d.dx * d.dx + d.dy * d.dy;
    if (l2 < 1e-12) continue;
    final t = (((p - a).dx * d.dx + (p - a).dy * d.dy) / l2).clamp(0.0, 1.0);
    final q = a + d * t;
    final dd = dist(q);
    if (dd < bd) {
      bd = dd;
      best = q;
      bseg = (a, b);
    }
  }
  if (best != null) return SnapTarget(best, SnapKind.edge, const [], bseg);
  // axis inference (plan space only — a projected tol would make
  // x/y equality meaningless under 3D foreshortening): a cursor x or
  // y within tol of any vertex's x/y snaps that axis and reports the
  // source so the painter can draw the alignment guide
  if (proj == null && tol > 0) {
    Offset? gx, gy;
    var dx = tol, dy = tol;
    for (final e in endpoints) {
      final ex = (p.dx - e.dx).abs();
      if (ex < dx) {
        dx = ex;
        gx = e;
      }
      final ey = (p.dy - e.dy).abs();
      if (ey < dy) {
        dy = ey;
        gy = e;
      }
    }
    if (gx != null || gy != null) {
      return SnapTarget(Offset(gx?.dx ?? p.dx, gy?.dy ?? p.dy), SnapKind.axis, [
        ?gx,
        ?gy,
      ]);
    }
  }
  return SnapTarget(
    Offset((p.dx / step).round() * step, (p.dy / step).round() * step),
    SnapKind.grid,
  );
}

/// Draws the inference glyph for a [SnapTarget] at screen point [s].
/// SketchUp palette: green endpoint square, cyan midpoint triangle,
/// dim plus for a bare grid intersection.
void paintSnapGlyph(Canvas canvas, Offset s, SnapKind kind, ColorScheme cs) {
  switch (kind) {
    case SnapKind.endpoint:
      const c = Color(0xFF2E9E4F);
      final r = Rect.fromCenter(center: s, width: 9, height: 9);
      canvas.drawRect(
        r.inflate(1.6),
        Paint()
          ..color = Colors.white
          ..strokeWidth = 1,
      );
      canvas.drawRect(r, Paint()..color = c);
    case SnapKind.midpoint:
      const c = Color(0xFF00A5C8);
      final path = Path()
        ..moveTo(s.dx, s.dy - 5.4)
        ..lineTo(s.dx + 4.8, s.dy + 3.6)
        ..lineTo(s.dx - 4.8, s.dy + 3.6)
        ..close();
      canvas.drawPath(
        path,
        Paint()
          ..color = Colors.white
          ..strokeWidth = 4.4
          ..style = PaintingStyle.stroke,
      );
      canvas.drawPath(path, Paint()..color = c);
    case SnapKind.edge:
      // orange square — "on edge" inference (SketchUp color)
      const c = Color(0xFFE11D48);
      final r = Rect.fromCenter(center: s, width: 8, height: 8);
      canvas.drawRect(
        r.inflate(1.6),
        Paint()
          ..color = Colors.white
          ..strokeWidth = 1,
      );
      canvas.drawRect(
        r,
        Paint()
          ..color = c
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
    case SnapKind.axis:
      // magenta diamond — axis-alignment inference (SketchUp color)
      const c = Color(0xFFD946EF);
      final path = Path()
        ..moveTo(s.dx, s.dy - 6)
        ..lineTo(s.dx + 6, s.dy)
        ..lineTo(s.dx, s.dy + 6)
        ..lineTo(s.dx - 6, s.dy)
        ..close();
      canvas.drawPath(
        path,
        Paint()
          ..color = Colors.white
          ..strokeWidth = 4.4
          ..style = PaintingStyle.stroke,
      );
      canvas.drawPath(path, Paint()..color = c);
    case SnapKind.grid:
      final pen = Paint()
        ..color = cs.onSurfaceVariant.withValues(alpha: 0.75)
        ..strokeWidth = 1.2;
      canvas.drawLine(s - const Offset(4.5, 0), s + const Offset(4.5, 0), pen);
      canvas.drawLine(s - const Offset(0, 4.5), s + const Offset(0, 4.5), pen);
  }
}

/// Device-pixel hairline contract (HiDPI): a hairline is exactly ONE
/// physical pixel wide at any Windows scaling, and an axis-aligned
/// hairline must sit on a pixel CENTER so the stroke covers one
/// raster row/column exactly — otherwise 125%/150% scaling smears a
/// 1-logical-px line across ~1.3-1.5 physical px (the classic CAD
/// "draw reference lines at half-integer device coords" rule).
double hairlinePx(double dpr) => 1.0 / dpr;
double pxSnap(double v, double dpr) => ((v * dpr - 0.5).round() + 0.5) / dpr;

/// Darken a wall's user color for its plan outline — the edge reads
/// as the fill's heavier line, matching colored-CAD-plan convention.
Color darken(Color c, double f) {
  final h = HSLColor.fromColor(c);
  return h.withLightness((h.lightness * f).clamp(0.0, 0.5)).toColor();
}

/// Selection accent for a pane: full-strength `cs.primary` on the
/// active canvas, desaturated toward slate on the passive one — the
/// SketchUp/Revit cue for "this is where your next edit lands".
Color selColorFor(ColorScheme cs, bool active) => active
    ? cs.primary
    : Color.lerp(cs.primary, const Color(0xFF94A3B8), 0.62)!;

/// One selection handle: white core + accent ring reads on any fill
/// (accent tints, colored volumes, photo-white). `dim` shrinks it for
/// the passive pane.
void paintSelHandle(Canvas canvas, Offset p, Color c, {bool dim = false}) {
  final r = dim ? 2.8 : 3.4;
  canvas.drawCircle(p, r, Paint()..color = Colors.white);
  canvas.drawCircle(
    p,
    r,
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = c,
  );
}

/// One bbox scale grip: a SQUARE accent handle (SketchUp scale-box
/// vocabulary — distinct from vertex rings so the user reads "draggable
/// face" at a glance). [hot] fills it while hovered/stretched.
void paintBoxHandle(
  Canvas canvas,
  Offset p,
  Color c, {
  bool dim = false,
  bool hot = false,
}) {
  final s = dim ? 4.6 : 5.6;
  final r = Rect.fromCenter(center: p, width: s * 2, height: s * 2);
  canvas.drawRect(r, Paint()..color = hot ? c : Colors.white);
  canvas.drawRect(
    r,
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..color = c,
  );
}

class _PlanPainter extends CustomPainter {
  final _ModelViewState st;
  final ColorScheme cs;
  final double dpr;
  _PlanPainter(this.st, this.cs, [this.dpr = 1.0]);

  @override
  void paint(Canvas canvas, Size size) {
    final bg = Paint()..color = Colors.white;
    canvas.drawRect(Offset.zero & size, bg);

    // grid — adaptive multi-scale (SketchUp convention): a base
    // step that keeps >=26 px between lines, every 5th line major,
    // plus a finer subdivision that fades in as it gains pixel
    // room — 1m splits to 0.25m, 0.5m to 0.10m, 2m to 0.5m...
    final (:step, :sub, :subAlpha) = planGridLevels(st._pScale);
    // HiDPI hairlines: grid is a REFERENCE lattice — it renders at
    // exactly 1 device px on pixel centers at any Windows scaling
    // (model geometry keeps its honest projected coords instead)
    final lw = hairlinePx(dpr);
    final minor = Paint()
      ..color = const Color(0xFFEFF3F8)
      ..strokeWidth = lw;
    final major = Paint()
      ..color = const Color(0xFFDDE5EE)
      ..strokeWidth = lw;
    final w0 = st._s2w(Offset.zero, size);
    final w1 = st._s2w(Offset(size.width, size.height), size);
    final xa = w0.dx.floorToDouble(), xb = w1.dx.ceilToDouble();
    final ya = w1.dy.floorToDouble(), yb = w0.dy.ceilToDouble();
    // lines sit at world-multiples of the step — the same lattice
    // the 3D ground grid draws, so both views share (0,0,0) and the
    // grid agrees with the 0.25m snap
    final axisX = Paint()
      ..color = const Color(0xFFEF5350).withValues(alpha: 0.28)
      ..strokeWidth = lw * 1.4;
    final axisY = Paint()
      ..color = const Color(0xFF66BB6A).withValues(alpha: 0.28)
      ..strokeWidth = lw * 1.4;
    // keep the sheet clean: the grid is clipped OUT of the model's
    // bound region (plus margin covering the dim strings), so no
    // construction line ever runs through the drawn floor plan
    final gbb = st._sel?.bounds;
    if (gbb != null) {
      const mg = 1.3;
      final a = st._w2s(Offset(gbb.$1 - mg, gbb.$2 - mg), size);
      final b = st._w2s(Offset(gbb.$3 + mg, gbb.$4 + mg), size);
      canvas.save();
      canvas.clipRect(
        Rect.fromPoints(a, b).inflate(0),
        clipOp: ClipOp.difference,
      );
    }
    for (final x in gridLinePositions(xa, xb, step)) {
      final sx = pxSnap(st._w2s(Offset(x, 0), size).dx, dpr);
      final i = (x / step).round();
      canvas.drawLine(
        Offset(sx, 0),
        Offset(sx, size.height),
        i == 0 ? axisY : (i % 5 == 0 ? major : minor),
      );
    }
    for (final y in gridLinePositions(ya, yb, step)) {
      final sy = pxSnap(st._w2s(Offset(0, y), size).dy, dpr);
      final i = (y / step).round();
      canvas.drawLine(
        Offset(0, sy),
        Offset(size.width, sy),
        i == 0 ? axisX : (i % 5 == 0 ? major : minor),
      );
    }
    if (subAlpha > 0) {
      final subPaint = Paint()
        ..color = const Color(0xFFE7EDF4).withValues(alpha: subAlpha)
        ..strokeWidth = lw;
      // subdivisions on the same world-multiple lattice: every
      // `div`-th index lands exactly on a base line — the skip is
      // exact, no float-tolerance misses
      final div = (step / sub).round();
      for (final x in gridLinePositions(xa, xb, sub)) {
        if ((x / sub).round() % div == 0) continue;
        final sx = pxSnap(st._w2s(Offset(x, 0), size).dx, dpr);
        canvas.drawLine(Offset(sx, 0), Offset(sx, size.height), subPaint);
      }
      for (final y in gridLinePositions(ya, yb, sub)) {
        if ((y / sub).round() % div == 0) continue;
        final sy = pxSnap(st._w2s(Offset(0, y), size).dy, dpr);
        canvas.drawLine(Offset(0, sy), Offset(size.width, sy), subPaint);
      }
    }
    if (gbb != null) canvas.restore();

    final m = st._sel;
    final tp = TextPainter(textDirection: TextDirection.ltr);

    void label(String s, Offset at, {Color? c, bool bold = false}) {
      // dimension labels register here; a later one landing within
      // ~22px of an earlier one is dropped (duplicate-figure noise)
      if (_dedupe) {
        for (final q in _dimPlaced) {
          if ((q - at).distance < 22) return;
        }
        _dimPlaced.add(at);
      }
      // white halo underlay first so the title never blends into the
      // linework it overlaps (professional-sheet convention)
      final w = bold ? FontWeight.w800 : FontWeight.w600;
      final fs = bold ? 12.0 : 11.0;
      tp.text = TextSpan(
        text: s,
        style: TextStyle(
          fontSize: fs,
          fontWeight: w,
          foreground: Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 3.2
            ..color = Colors.white,
        ),
      );
      tp.layout();
      final off = at - Offset(tp.width / 2, tp.height / 2);
      // rotated labels (diagonal dim strings) ride their line
      final rot = _lblAngle != 0;
      if (rot) {
        canvas.save();
        canvas.translate(at.dx, at.dy);
        canvas.rotate(_lblAngle);
        canvas.translate(-at.dx, -at.dy);
      }
      tp.paint(canvas, off);
      tp.text = TextSpan(
        text: s,
        style: TextStyle(
          fontSize: fs,
          color: c ?? const Color(0xFF475569),
          fontWeight: w,
        ),
      );
      tp.layout();
      tp.paint(canvas, off);
      if (rot) canvas.restore();
    }

    /// Room-style title: BOLD name over a normal sub-line (area/dims)
    /// — the "LIVING ROOM / 206 SF" convention from the reference.
    void titleLabel(String name, String sub, Offset at, {Color? c}) {
      label(
        name,
        at - const Offset(0, 10.5),
        c: c ?? const Color(0xFF334155),
        bold: true,
      );
      label(sub, at + const Offset(0, 10.5), c: c);
    }

    // selection vocabulary (task 18): accent at full strength on the
    // active pane, desaturated on the passive one; identical ring
    // handles on both canvases
    final selActive = st._paneActivePlan;
    final selC = selColorFor(cs, selActive);

    if (m != null) {
      for (final v in m.volumes) {
        final sel = v == st._vol;
        final path = Path();
        for (var i = 0; i < v.fp.length; i += 2) {
          final p = st._w2s(Offset(v.fp[i], v.fp[i + 1]), size);
          i == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
        }
        path.close();
        canvas.drawPath(
          path,
          Paint()
            ..color = Color(
              v.argb,
            ).withValues(alpha: sel ? (selActive ? 0.28 : 0.14) : 0.14),
        );
        canvas.drawPath(
          path,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = sel ? 2.2 : 1.4
            ..color = sel ? selC : const Color(0xFF475569),
        );
        if (sel) {
          for (var i = 0; i < v.fp.length; i += 2) {
            paintSelHandle(
              canvas,
              st._w2s(Offset(v.fp[i], v.fp[i + 1]), size),
              selC,
              dim: !selActive,
            );
          }
        }
        // room title: BOLD name over its area — "BEDROOM / 144 SF"
        // (labels only when the set is small, or for the selected
        // volume — a busy plan would turn into soup)
        if ((st._dims && m.volumes.length <= 40) || sel) {
          titleLabel(
            v.name,
            _fmtArea(_polyArea(v.fp)),
            st._w2s(v.center, size),
            c: sel ? selC : const Color(0xFF334155),
          );
        }
      }

      // ---- walls: thick mass + outline + automatic segment dims ----
      var wallSegs = 0;
      for (final w in m.walls) {
        wallSegs += w.segs;
      }
      final showWallDims = wallSegs <= 60;
      for (final w in m.walls) {
        final sel = w == st._wallSel;
        final fill = Paint()
          ..color = sel
              ? selC.withValues(alpha: selActive ? 0.30 : 0.16)
              : Color(w.argb).withValues(alpha: 0.30);
        final edge = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = sel ? 1.8 : 1.0
          ..color = sel ? selC : darken(Color(w.argb), 0.42);
        for (var i = 0; i < w.segs; i++) {
          // solid pieces: openings carve gaps, joined ends are
          // extended so corners combine cleanly (model-level op)
          for (final piece in wallSegPieces(m, w, i)) {
            final path = Path();
            for (final (j, p) in piece.indexed) {
              final s = st._w2s(p, size);
              j == 0 ? path.moveTo(s.dx, s.dy) : path.lineTo(s.dx, s.dy);
            }
            path.close();
            canvas.drawPath(path, fill);
            canvas.drawPath(path, edge);
          }
          // automatic measurement — segment length beside its midpoint
          if ((st._dims && showWallDims) || sel) {
            final a = Offset(w.pts[i * 2], w.pts[i * 2 + 1]);
            final b = Offset(w.pts[i * 2 + 2], w.pts[i * 2 + 3]);
            final len = (b - a).distance;
            // a perimeter / diagonal seg is already dimensioned by an
            // exterior string — its mid-wall label is a duplicate
            // figure (9.28 over 9.28 m), so only selected or interior
            // walls keep one
            var covered = false;
            final we = wallEnv(m);
            final bbx = we == null
                ? m.bounds
                : (we.$1, we.$2, we.$3, we.$4, m.bounds!.$5);
            if (!sel && bbx != null && len > 1e-9) {
              final d = (b - a) / len;
              const e = 0.3;
              if (d.dx.abs() < 0.2 || d.dy.abs() < 0.2) {
                final horiz = d.dx.abs() >= d.dy.abs();
                final c = horiz ? a.dy : a.dx;
                covered = horiz
                    ? (c - bbx.$2).abs() < e || (c - bbx.$4).abs() < e
                    : (c - bbx.$1).abs() < e || (c - bbx.$3).abs() < e;
              } else {
                covered = true;
              }
            }
            if (len > 0.05 && !covered && (sel || len * st._pScale > 40)) {
              final mid = (a + b) / 2;
              final dir = (b - a) / len;
              final off = Offset(-dir.dy, dir.dx) * (w.thickness / 2 + 0.22);
              label(
                _fmtM(len),
                st._w2s(mid + off, size),
                c: sel ? selC : const Color(0xFF64748B),
              );
            }
          }
        }
        if (sel) {
          // centerline nodes + thickness tag on the first segment
          for (var i = 0; i < w.pts.length; i += 2) {
            paintSelHandle(
              canvas,
              st._w2s(Offset(w.pts[i], w.pts[i + 1]), size),
              selC,
              dim: !selActive,
            );
          }
          final a = Offset(w.pts[0], w.pts[1]);
          final b = Offset(w.pts[2], w.pts[3]);
          label('t ${_fmtM(w.thickness)}', st._w2s((a + b) / 2, size), c: selC);
        }
      }

      // ---- blocks: CAD symbols ----
      _placedLabels.clear();
      for (final b in m.blocks) {
        final def = cadBlock(b.def);
        if (def == null) continue;
        final sel = b == st._blkSel;
        final pen = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = sel ? 1.8 : 1.1
          ..color = sel ? selC : const Color(0xFF475569);
        for (final l in blockLines(b, def)) {
          final path = Path();
          for (final (i, p) in l.indexed) {
            final s = st._w2s(p, size);
            i == 0 ? path.moveTo(s.dx, s.dy) : path.lineTo(s.dx, s.dy);
          }
          canvas.drawPath(path, pen);
        }
        // column footings are buried concrete — the plan must draw
        // them (dashed square + X, structural notation) or they are
        // invisible where they are actually selectable
        if (b.footing && (b.def == 'col-sq' || b.def == 'col-rd')) {
          final hw = footingFor(def.w * b.sx * b.scale, b.footW).w / 2;
          final sq = [
            Offset(b.x - hw, b.y - hw),
            Offset(b.x + hw, b.y - hw),
            Offset(b.x + hw, b.y + hw),
            Offset(b.x - hw, b.y + hw),
          ];
          final fpen = Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = sel ? 1.6 : 1.0
            ..color = sel ? selC : const Color(0xFF78909C);
          for (var i = 0; i < 4; i++) {
            _dashLine(
              canvas,
              st._w2s(sq[i], size),
              st._w2s(sq[(i + 1) % 4], size),
              fpen,
            );
          }
          _dashLine(canvas, st._w2s(sq[0], size), st._w2s(sq[2], size), fpen);
          _dashLine(canvas, st._w2s(sq[1], size), st._w2s(sq[3], size), fpen);
        }
        if (sel) {
          final quad = Path();
          var bot = -double.infinity, cx = 0.0;
          for (final (i, p) in blockFootprint(b, def).indexed) {
            final s = st._w2s(p, size);
            bot = math.max(bot, s.dy);
            cx += s.dx;
            i == 0 ? quad.moveTo(s.dx, s.dy) : quad.lineTo(s.dx, s.dy);
          }
          quad.close();
          canvas.drawPath(
            quad,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1.4
              ..color = selC.withValues(alpha: 0.8),
          );
          paintSelHandle(
            canvas,
            st._w2s(Offset(b.x, b.y), size),
            selC,
            dim: !selActive,
          );
          // anchored below the footprint so it never covers the symbol
          titleLabel(
            def.name,
            '${_fmt(def.w * b.scale * b.sx)} × '
            '${_fmt(def.d * b.scale * b.sy)} · '
            'h ${_fmt(def.height * b.scale * b.sz)}',
            Offset(cx / 4, bot + 28),
            c: selC,
          );
        } else if (st._dims && m.blocks.length <= 80) {
          // name + footprint dims under EVERY block (toggleable; the
          // cap keeps a dense furnished plan readable). Anchor on the
          // projected quad's bottom edge — screen space, so the label
          // always lands just below the symbol regardless of axis
          // convention or rotation. Labels that would collide with an
          // already-drawn one are skipped — a readable subset beats
          // stacked half-hidden text (adjacent furniture overlapped).
          final bw = def.w * b.scale * b.sx;
          final bd = def.d * b.scale * b.sy;
          var bot = -double.infinity, cx = 0.0;
          for (final p in blockFootprint(b, def)) {
            final s = st._w2s(p, size);
            bot = math.max(bot, s.dy);
            cx += s.dx;
          }
          final at = Offset(cx / 4, bot + 44);
          var clash = false;
          for (final q in _placedLabels) {
            if ((q - at).distance < 30) {
              clash = true;
              break;
            }
          }
          if (!clash) {
            _placedLabels.add(at);
            label(
              '${def.name}\n${_fmt(bw)} × ${_fmt(bd)}',
              at,
              c: const Color(0xFF64748B),
            );
          }
        }
      }
    }

    // INTERIOR dimensions: only furniture/doors/windows, short lines
    // hugging each footprint on its room-facing side. Outside strings
    // below are walls only.
    if (st._dims && m != null && m.blocks.length <= 80) {
      var cx = 0.0, cy = 0.0;
      final bb0 = m.bounds;
      if (bb0 != null) {
        cx = (bb0.$1 + bb0.$3) / 2;
        cy = (bb0.$2 + bb0.$4) / 2;
      }
      final pen = Paint()
        ..color = const Color(0xFF94A3B8)
        ..strokeWidth = 0.9;
      void dimEdge(Offset a, Offset b, Offset c0, double off) {
        final d = b - a;
        final len = d.distance;
        if (len < 0.1) return;
        var n = Offset(-d.dy, d.dx) / len;
        if (n.dx * ((a + b).dx / 2 - c0.dx) + n.dy * ((a + b).dy / 2 - c0.dy) <
            0) {
          n = -n;
        }
        final a2 = st._w2s(a + n * off, size), b2 = st._w2s(b + n * off, size);
        canvas.drawLine(a2, b2, pen);
        final sd = b2 - a2;
        final sl = sd.distance;
        if (sl < 24) return;
        final u = sd / sl, nn = Offset(-u.dy, u.dx);
        for (final e in [a2, b2]) {
          canvas.drawLine(e - (u + nn) * 3, e + (u + nn) * 3, pen);
        }
        final out = st._w2s(a + n * off, size) - st._w2s(a, size);
        final dirOut = out / (out.distance == 0 ? 1 : out.distance);
        label(
          _fmt(len),
          (a2 + b2) / 2 + dirOut * 9,
          c: const Color(0xFF64748B),
        );
      }

      for (final b in m.blocks) {
        final def = kCadBlocks.where((x) => x.id == b.def).firstOrNull;
        if (def == null) continue;
        final fp = blockFootprint(b, def);
        if (fp.length < 4) continue;
        final c0 = Offset(b.x, b.y);
        if (def.opening) {
          dimEdge(fp[0], fp[1], Offset(cx, cy), 0.28);
        } else {
          dimEdge(fp[0], fp[1], c0, 0.14);
          dimEdge(fp[1], fp[2], c0, 0.14);
        }
      }
    }

    // exterior dimension strings — architectural convention: an inner
    // chain of ordinate-to-ordinate gaps plus an outer overall dim on
    // every side. Ordinates come from the JOINED wall pieces, so door
    // jambs (cut edges) appear in the chain like a real production
    // drawing. Gated by the same `_dims` toggle as everything else.
    if (st._dims && m != null && m.walls.isNotEmpty) {
      _dimPlaced.clear();
      _dedupe = true;
      _extDims(canvas, size, m, label);
      _dedupe = false;
      _lblAngle = 0;
    }
    // manual aligned dims — user-authored geometry, always visible
    _manualDims(canvas, size, m, label, cs);

    // snap inference — one target feeds the previews, the glyph and
    // the tap handlers so what you see is exactly where a click lands
    final snap = (st._snap && st._tool != _MTool.select)
        ? st._snapPt(st._hover, st._pScale)
        : null;
    var snapW = snap?.p ?? st._hover;
    // typed distance entry: the ghost already lands on the exact
    // point Enter/click will commit — what you see is what you get
    if (st._dimIn.isNotEmpty) {
      final chain = st._tool == _MTool.wall ? st._wall : st._poly;
      if (chain.isNotEmpty) {
        snapW = st._dimPoint(chain.last) ?? snapW;
      }
    }

    // typed offset BEFORE the first wall point — dashed leader from
    // the anchor corner to where Enter/click will start the chain,
    // labeled with the raw input like AutoCAD's DYN field
    if (st._tool == _MTool.wall && st._wall.isEmpty && st._dimIn.isNotEmpty) {
      final off = st._edgeOffset(double.tryParse(st._dimIn) ?? -1);
      if (off != null) {
        final sp = st._w2s(off.p, size);
        final sa = st._w2s(off.anchor, size);
        _dashLine(
          canvas,
          sa,
          sp,
          Paint()
            ..color = cs.primary
            ..strokeWidth = 1.2,
        );
        canvas.drawCircle(sp, 3.5, Paint()..color = cs.primary);
        label(
          st._dimIn,
          (sa + sp) / 2 + const Offset(0, -14),
          c: cs.primary,
          bold: true,
        );
      }
    }

    // in-progress wall chain — live thickness + running measurements
    if (st._wall.isNotEmpty) {
      final pts = [...st._wall];
      if (st._tool == _MTool.wall) pts.add(snapW);
      final thick = Paint()
        ..color = cs.primary.withValues(alpha: 0.25)
        ..strokeWidth = math.max(2.0, st._wallT * st._pScale)
        ..strokeCap = StrokeCap.round;
      final core = Paint()
        ..color = cs.primary
        ..strokeWidth = 1.4;
      for (var i = 0; i < pts.length - 1; i++) {
        final a = st._w2s(pts[i], size), b = st._w2s(pts[i + 1], size);
        canvas.drawLine(a, b, thick);
        canvas.drawLine(a, b, core);
        // only the ACTIVE (last) segment shows its running length —
        // labeling every committed chain leg cluttered the plan
        if (i != pts.length - 2) continue;
        final len = (pts[i + 1] - pts[i]).distance;
        if (len > 0.05) {
          final mid = (a + b) / 2;
          final dir = (b - a) / (a - b).distance;
          // while typing, the label shows the raw input — bold like
          // AutoCAD's DYN field
          label(
            st._dimIn.isNotEmpty
                ? st._dimIn
                : '${_fmtM(len)}  ${_wallAngle(pts[i], pts[i + 1])}',
            mid + Offset(-dir.dy, dir.dx) * (st._wallT * st._pScale / 2 + 12),
            c: cs.primary,
            bold: st._dimIn.isNotEmpty,
          );
        }
      }
      for (final p in st._wall) {
        canvas.drawCircle(st._w2s(p, size), 3, Paint()..color = cs.primary);
      }
    }

    // block placement ghost follows the cursor (snap-resolved);
    // wall-going defs preview their auto-seat — green when the click
    // will snap them onto a wall, theme color when free-standing
    if (st._tool == _MTool.block) {
      final m = st._sel;
      final seat = m == null
          ? null
          : (isTrussDef(st._blkDef.id)
                ? seatTrussOnWalls(m, snapW, st._blkRot, st._blkDef.w)
                : seatOnWall(m, st._blkDef, snapW));
      final seatC = const Color(0xFF16A34A);
      final ghost = Block3d(
        def: st._blkDef.id,
        x: seat?.$1.dx ?? snapW.dx,
        y: seat?.$1.dy ?? snapW.dy,
        rot: seat?.$2 ?? st._blkRot,
      );
      final pen = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.1
        ..color = (seat != null ? seatC : cs.primary).withValues(alpha: 0.6);
      for (final l in blockLines(ghost, st._blkDef)) {
        final path = Path();
        for (final (i, p) in l.indexed) {
          final s = st._w2s(p, size);
          i == 0 ? path.moveTo(s.dx, s.dy) : path.lineTo(s.dx, s.dy);
        }
        canvas.drawPath(path, pen);
      }
      // a thin connector shows the wall snap target
      if (seat != null && (seat.$1 - snapW).distance > 0.02) {
        canvas.drawLine(
          st._w2s(snapW, size),
          st._w2s(seat.$1, size),
          Paint()
            ..color = seatC.withValues(alpha: 0.45)
            ..strokeWidth = 1,
        );
      }
      label(
        seat != null ? '${st._blkDef.name} — snaps to wall' : st._blkDef.name,
        st._w2s(Offset(ghost.x, ghost.y), size) + const Offset(0, -12),
        c: seat != null ? seatC : cs.primary,
      );
    }

    // MOVE command ghost (M): the carried block at the snap-resolved
    // cursor + a vector line back to its original spot — doors/
    // windows preview their wall seat like the place tool does
    if (st._tool == _MTool.move && st._moving != null) {
      final mv = st._moving!;
      final mdef = cadBlock(mv.def);
      if (mdef != null) {
        final m = st._sel;
        final seat = m == null
            ? null
            : (isTrussDef(mdef.id)
                  ? seatTrussOnWalls(
                      m,
                      snapW,
                      mv.rot,
                      mdef.w * mv.sx * mv.scale,
                      ignore: mv,
                    )
                  : seatOnWall(m, mdef, snapW));
        final seatC = const Color(0xFF16A34A);
        final ghost = Block3d(
          def: mv.def,
          x: seat?.$1.dx ?? snapW.dx,
          y: seat?.$1.dy ?? snapW.dy,
          rot: seat?.$2 ?? mv.rot,
          scale: mv.scale,
          sx: mv.sx,
          sy: mv.sy,
          sz: mv.sz,
          bz: mv.bz,
        );
        final pen = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.1
          ..color = (seat != null ? seatC : cs.primary).withValues(alpha: 0.6);
        for (final l in blockLines(ghost, mdef)) {
          final path = Path();
          for (final (i, p) in l.indexed) {
            final s = st._w2s(p, size);
            i == 0 ? path.moveTo(s.dx, s.dy) : path.lineTo(s.dx, s.dy);
          }
          canvas.drawPath(path, pen);
        }
        // vector from the original position to the ghost
        canvas.drawLine(
          st._w2s(Offset(mv.x, mv.y), size),
          st._w2s(Offset(ghost.x, ghost.y), size),
          Paint()
            ..color = cs.primary.withValues(alpha: 0.4)
            ..strokeWidth = 1
            ..style = PaintingStyle.stroke,
        );
        label(
          seat != null
              ? '${mdef.name} — snaps to wall'
              : '${mdef.name} — click to place',
          st._w2s(Offset(ghost.x, ghost.y), size) + const Offset(0, -12),
          c: seat != null ? seatC : cs.primary,
        );
      }
    }

    // ROTATE ghost (G): the carried block spins around its own centre
    // to the cursor's angle — a protractor circle + radius line give
    // the SketchUp-style live angle readout; the real rot is untouched
    if (st._tool == _MTool.rotate && st._rotating != null) {
      final r = st._rotating!;
      final rdef = cadBlock(r.def);
      if (rdef != null) {
        final rot = st._rotPreview(st._hover);
        final ghost = Block3d(
          def: r.def,
          x: r.x,
          y: r.y,
          rot: rot,
          scale: r.scale,
          sx: r.sx,
          sy: r.sy,
          sz: r.sz,
          bz: r.bz,
        );
        final pen = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.1
          ..color = cs.primary.withValues(alpha: 0.6);
        for (final l in blockLines(ghost, rdef)) {
          final path = Path();
          for (final (i, p) in l.indexed) {
            final s = st._w2s(p, size);
            i == 0 ? path.moveTo(s.dx, s.dy) : path.lineTo(s.dx, s.dy);
          }
          canvas.drawPath(path, pen);
        }
        // protractor: circle at the centre + radius line to the cursor
        final c = st._w2s(Offset(r.x, r.y), size);
        final d = st._w2s(st._hover, size) - c;
        final thin = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.8
          ..color = cs.primary.withValues(alpha: 0.3);
        canvas.drawCircle(c, d.distance, thin);
        canvas.drawLine(
          c,
          c + d,
          Paint()
            ..color = cs.primary.withValues(alpha: 0.4)
            ..strokeWidth = 1,
        );
        final deg = ((rot * 180 / math.pi) % 360 + 360) % 360;
        label(
          '${deg.toStringAsFixed(0)}\u00b0 — click to set',
          c + const Offset(10, -14),
          c: cs.primary,
        );
      }
    }

    // rect drag preview — corners arrive snap-resolved
    final r0 = st._rect0, r1 = st._rectCur;
    if (r0 != null && r1 != null) {
      final a = st._w2s(r0, size);
      final b = st._w2s(r1, size);
      final r = Rect.fromPoints(a, b);
      canvas.drawRect(
        r,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6
          ..color = cs.primary,
      );
      label(
        '${_fmt((r1.dx - r0.dx).abs())} × ${_fmt((r1.dy - r0.dy).abs())} m',
        r.center,
      );
    }

    // in-progress polyline
    if (st._poly.isNotEmpty) {
      final pp = Paint()
        ..color = cs.primary
        ..strokeWidth = 1.6;
      for (var i = 0; i < st._poly.length - 1; i++) {
        canvas.drawLine(
          st._w2s(st._poly[i], size),
          st._w2s(st._poly[i + 1], size),
          pp,
        );
      }
      if (st._tool == _MTool.poly) {
        canvas.drawLine(
          st._w2s(st._poly.last, size),
          st._w2s(snapW, size),
          pp..strokeWidth = 1,
        );
      }
      for (final p in st._poly) {
        canvas.drawCircle(st._w2s(p, size), 3, Paint()..color = cs.primary);
      }
      canvas.drawCircle(
        st._w2s(st._poly.first, size),
        5,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = cs.primary,
      );
    }

    // inference glyph + axis-alignment guides — only while the
    // pointer is actually over the plan; a stale `_hover` must not
    // leave a frozen marker behind
    if (snap != null && st._inPlan) {
      // dashed magenta guide from each aligned vertex to the snap —
      // vertical guides share x, horizontal share y
      if (snap.guides.isNotEmpty) {
        const c = Color(0xFFD946EF);
        final pen = Paint()
          ..color = c.withValues(alpha: 0.85)
          ..strokeWidth = 1.2;
        final tgt = st._w2s(snap.p, size);
        for (final g in snap.guides) {
          final gs = st._w2s(g, size);
          // guide runs axis-aligned through the shared coordinate
          final end = (g.dx - snap.p.dx).abs() < 1e-9
              ? Offset(gs.dx, tgt.dy)
              : Offset(tgt.dx, gs.dy);
          _dashLine(canvas, gs, end, pen);
          canvas.drawCircle(gs, 2.5, Paint()..color = c);
        }
      }
      // temporary dims along the snapped segment — distance to BOTH
      // ends so a T-wall start reads "X this side | Y that side" in
      // whichever direction the user draws (horizontal or vertical);
      // the typed-offset anchor side (nearer endpoint) draws bold
      if (snap.kind == SnapKind.edge &&
          snap.seg != null &&
          st._dimIn.isEmpty &&
          (st._tool == _MTool.wall || st._tool == _MTool.poly)) {
        final (a, b) = snap.seg!;
        final da = snap.p - a, db = b - snap.p;
        final segDir = b - a;
        if (segDir.distance >= 1e-9) {
          final n = Offset(-segDir.dy, segDir.dx) / segDir.distance * 14;
          final pen = Paint()
            ..color = cs.primary.withValues(alpha: 0.55)
            ..strokeWidth = 1.0;
          final tick = Offset(-segDir.dy, segDir.dx) / segDir.distance * 5;
          void side(Offset from, Offset to, double len, bool anchor) {
            if (len < 0.02) return;
            final fs = st._w2s(from, size), ts = st._w2s(to, size);
            canvas.drawLine(fs, ts, pen);
            canvas.drawLine(fs - tick, fs + tick, pen);
            canvas.drawLine(ts - tick, ts + tick, pen);
            label(_fmtM(len), (fs + ts) / 2 + n, c: cs.primary, bold: anchor);
          }

          // typing an offset measures from the NEARER endpoint — the
          // bold label is the side typing will adjust
          final nearA = da.distance <= db.distance;
          side(a, snap.p, da.distance, nearA);
          side(snap.p, b, db.distance, !nearA);
        }
      }
      paintSnapGlyph(canvas, st._w2s(snap.p, size), snap.kind, cs);
    }
    // eraser tool — the system cursor is hidden; paint a tilted
    // eraser icon at the pointer instead (pink/white rubber look)
    if (st._tool == _MTool.eraser && st._inPlan && m != null) {
      // red preview of exactly what a click would erase (same
      // priority as `_eraseAt`: block > wall > volume)
      final h = Offset(st._w(st._hover.dx), st._w(st._hover.dy));
      final hb = st._blkAt(h);
      final red = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.4
        ..color = const Color(0xFFDC2626);
      final redFill = Paint()
        ..color = const Color(0xFFDC2626).withValues(alpha: 0.18);
      void poly(List<Offset> pts) {
        final path = Path();
        for (final (j, p) in pts.indexed) {
          final q = st._w2s(p, size);
          j == 0 ? path.moveTo(q.dx, q.dy) : path.lineTo(q.dx, q.dy);
        }
        path.close();
        canvas.drawPath(path, redFill);
        canvas.drawPath(path, red);
      }

      if (hb != null) {
        final d = cadBlock(hb.def);
        if (d != null) poly(blockFootprint(hb, d));
      } else {
        final hw = st._wallAt(h);
        final hv = hw == null ? st._volAt(h) : null;
        if (hw != null) {
          for (var i = 0; i < hw.segs; i++) {
            for (final pc in wallSegPieces(m, hw, i)) {
              poly(pc);
            }
          }
        } else if (hv != null) {
          poly([
            for (var i = 0; i < hv.fp.length; i += 2)
              Offset(hv.fp[i], hv.fp[i + 1]),
          ]);
        }
      }
    }
    if (st._tool == _MTool.eraser && st._inPlan) {
      final s = st._w2s(st._hover, size);
      canvas.save();
      canvas.translate(s.dx, s.dy);
      canvas.rotate(-0.7);
      final rr = RRect.fromRectAndRadius(
        const Rect.fromLTWH(-7, -4, 14, 9),
        const Radius.circular(2),
      );
      canvas.drawRRect(rr, Paint()..color = const Color(0xFFF472B6));
      canvas.drawRect(
        const Rect.fromLTWH(-7, -4, 14, 5),
        Paint()..color = Colors.white,
      );
      canvas.drawRRect(
        rr,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2
          ..color = const Color(0xFF9D174D),
      );
      canvas.restore();
    }
  }

  /// Dashed line helper for inference guides.
  void _dashLine(Canvas c, Offset a, Offset b, Paint p) {
    final d = b - a;
    final len = d.distance;
    if (len < 1e-6) return;
    final dir = d / len;
    var t = 0.0;
    while (t < len) {
      final t1 = math.min(t + 6, len);
      c.drawLine(a + dir * t, a + dir * t1, p);
      t = t1 + 4;
    }
  }

  /// Manual DIM-tool annotations: an aligned segment with 45° ticks
  /// at both ends and the unit-aware length above its midpoint —
  /// same drafting vocabulary as the exterior strings. Also paints
  /// the in-progress drag ghost (`_dimA`/`_dimB`) in primary.
  void _manualDims(
    Canvas canvas,
    Size size,
    Model3d? m,
    void Function(String, Offset, {Color? c, bool bold}) label,
    ColorScheme cs,
  ) {
    void one(Offset a, Offset b, Color col, bool bold) {
      final sa = st._w2s(a, size), sb = st._w2s(b, size);
      final pen = Paint()
        ..color = col
        ..strokeWidth = 1.1;
      canvas.drawLine(sa, sb, pen);
      // perpendicular end ticks (10px), 45°-slashed like real dims
      final d = sb - sa;
      if (d.distance < 2) return;
      final n = Offset(-d.dy, d.dx) / d.distance * 5;
      for (final s in [sa, sb]) {
        canvas.drawLine(s - n, s + n, pen);
      }
      label(
        _fmt((b - a).distance),
        (sa + sb) / 2 + const Offset(0, -12),
        c: col,
        bold: bold,
      );
    }

    if (m != null) {
      for (final d in m.dims) {
        one(
          Offset(d[0], d[1]),
          Offset(d[2], d[3]),
          const Color(0xFF475569),
          false,
        );
      }
    }
    final a = st._dimA, b = st._dimB;
    if (a != null && b != null) one(a, b, cs.primary, true);
  }

  /// Screen-space anchors of emitted block labels for the current
  /// paint pass — used to skip names that would overlap.
  final List<Offset> _placedLabels = [];

  /// Dimension-label dedupe registry + rotation applied by `label`
  /// (set around the exterior/diagonal string pass only).
  final List<Offset> _dimPlaced = [];
  bool _dedupe = false;
  double _lblAngle = 0;

  /// Per-side dimension strings (bottom/top/left/right of the plan).
  /// Horizontal strings take x-ordinates; vertical take y-ordinates.
  /// Each ordinate records the geometry coordinate that generated it
  /// so extension lines start ON the element, not the bound edge.
  void _extDims(
    Canvas canvas,
    Size size,
    Model3d m,
    void Function(String, Offset, {Color? c, bool bold}) label,
  ) {
    // ordinate(cm) -> [minCoord, maxCoord] of contributing geometry.
    // Shared with the DXF sheet generator (`wallOrds`) so generated
    // drawings dimension the exact same boundaries as this view.
    final bb = m.bounds;
    if (bb == null) return;
    // the chain measures the wall envelope — furniture/pads pushing
    // m.bounds past the walls must not drag the strings off the
    // building face (same rule the DXF sheet applies)
    final we = wallEnv(m);
    const slate = Color(0xFF64748B);
    final dimPen = Paint()
      ..color = slate.withValues(alpha: 0.8)
      ..strokeWidth = 0.9;
    final tickPen = Paint()
      ..color = slate
      ..strokeWidth = 1.2;

    // share of wall length that is diagonal decides whether the axis
    // chains are meaningful or just projections
    var diagLen = 0.0, allLen = 0.0;
    for (final w in m.walls) {
      for (var i = 0; i < w.segs; i++) {
        final d = Offset(
          w.pts[i * 2 + 2] - w.pts[i * 2],
          w.pts[i * 2 + 3] - w.pts[i * 2 + 1],
        );
        final l = d.distance;
        allLen += l;
        if (l > 1e-9 && (d.dx.abs() / l < 0.2 || d.dy.abs() / l < 0.2)) {
          continue;
        }
        diagLen += l;
      }
    }
    final diagHeavy = allLen > 0 && diagLen / allLen >= 0.6;

    /// One string: [ords] sorted cm along the run axis; [side] 0=bottom
    /// 1=top 2=left 3=right picks the perpendicular side + direction.
    void string(int side) {
      final vert = side >= 2;
      final sign = side == 0 || side == 2 ? -1.0 : 1.0;
      final edge = switch (side) {
        0 => we?.$2 ?? bb.$2,
        1 => we?.$4 ?? bb.$4,
        2 => we?.$1 ?? bb.$1,
        _ => we?.$3 ?? bb.$3,
      };
      var ords = [for (final v in wallOrds(m, side)) (v * 100).round()];
      if (ords.length < 2) return;
      // mostly-diagonal plans: the chain would measure projections of
      // rotated walls — keep ONLY the overall extent (diagonal strings
      // carry the real lengths)
      if (diagHeavy && ords.length > 2) ords = [ords.first, ords.last];
      // a single span needs one line + one bold figure, not a chain
      // line AND an identical outer overall (the duplicate-figure noise)
      final single = ords.length == 2;
      const gap = 0.15, line1 = 0.62, line2 = 1.06;
      Offset pt(double run, double perp) =>
          st._w2s(vert ? Offset(perp, run) : Offset(run, perp), size);
      final o0 = ords.first / 100, o1 = ords.last / 100;
      final dLine = edge + sign * (gap + line1);
      final dLine2 = edge + sign * (gap + line2);

      // dim lines: inner segment chain + outer overall
      canvas.drawLine(pt(o0, dLine), pt(o1, dLine), dimPen);
      if (!single) canvas.drawLine(pt(o0, dLine2), pt(o1, dLine2), dimPen);

      for (final cm in ords) {
        final r = cm / 100;
        // extension starts just OUTSIDE the bound edge — never draws
        // into the plan interior (user: no lines inside the drawing)
        canvas.drawLine(pt(r, edge + sign * 0.05), pt(r, dLine), dimPen);
        // 45° tick at the ordinate on the chain line + outer line ends
        for (final dl
            in (cm == ords.first || cm == ords.last) && !single
                ? [dLine, dLine2]
                : [dLine]) {
          final s = pt(r, dl);
          canvas.drawLine(
            s + const Offset(-3.4, -3.4),
            s + const Offset(3.4, 3.4),
            tickPen,
          );
        }
      }

      // gap labels between consecutive ordinates — pushed OUTWARD
      // past the chain line (screen space, sign-aware per side)
      for (var i = 0; i + 1 < ords.length; i++) {
        final a = ords[i] / 100, b = ords[i + 1] / 100;
        final gapLen = b - a;
        // slivers (<0.10 m) can't be read at plan scale — their
        // ticks stay, the figure is dropped
        if (gapLen < 0.10) continue;
        final mid = pt((a + b) / 2, dLine + sign * 0.07);
        label(
          _fmt(gapLen),
          vert ? mid + Offset(sign * 10, 0) : mid + Offset(0, -sign * 10),
          c: single ? const Color(0xFF334155) : slate,
          bold: single,
        );
      }
      // overall at the outer line — bold, the figure you read first
      if (!single) {
        final midAll = pt((o0 + o1) / 2, dLine2 + sign * 0.07);
        label(
          _fmt(o1 - o0),
          vert ? midAll + Offset(sign * 10, 0) : midAll + Offset(0, -sign * 10),
          c: const Color(0xFF334155),
          bold: true,
        );
      }
    }

    string(0);
    string(1);
    string(2);
    string(3);

    // DIAGONAL walls: a rotated wing can't be dimensioned honestly
    // on world axes — each non-axis-aligned seg gets its own dim
    // string PARALLEL to the seg, parked outside the band on the side
    // away from ITS OWN wall's centroid (not the whole model's — a
    // wing far from the model center used to flip inward). Labels
    // are rotated onto the string; single-span strings print one
    // bold figure.
    for (final w in m.walls) {
      var cx = 0.0, cy = 0.0;
      final np = w.pts.length ~/ 2;
      for (var i = 0; i < np; i++) {
        cx += w.pts[i * 2];
        cy += w.pts[i * 2 + 1];
      }
      cx /= np;
      cy /= np;
      for (var i = 0; i < w.segs; i++) {
        final a = Offset(w.pts[i * 2], w.pts[i * 2 + 1]);
        final b = Offset(w.pts[i * 2 + 2], w.pts[i * 2 + 3]);
        final len = (b - a).distance;
        if (len < 1e-9) continue;
        final dir = (b - a) / len;
        // axis-aligned segs are already covered by the four strings
        if (dir.dx.abs() < 0.20 || dir.dy.abs() < 0.20) continue;
        final ords = <double>{
          for (final s in wallSegSpans(m, w, i))
            for (final e in [s.$1, s.$2]) e.clamp(0.0, len),
        }.toList()..sort();
        if (ords.length < 2) continue;
        final single = ords.length == 2;
        var n = Offset(-dir.dy, dir.dx);
        final mid = (a + b) / 2;
        if (n.dx * (mid.dx - cx) + n.dy * (mid.dy - cy) < 0) n = -n;
        const gap = 0.15, line1 = 0.62, line2 = 1.06;
        final fOff = w.thickness / 2;
        Offset at(double t, double perp) =>
            st._w2s(a + dir * t + n * perp, size);
        final d1 = fOff + gap + line1, d2 = fOff + gap + line2;
        canvas.drawLine(at(ords.first, d1), at(ords.last, d1), dimPen);
        if (!single) {
          canvas.drawLine(at(ords.first, d2), at(ords.last, d2), dimPen);
        }
        for (final t in ords) {
          canvas.drawLine(at(t, fOff + 0.05), at(t, d1), dimPen);
          for (final dl
              in (t == ords.first || t == ords.last) && !single
                  ? [d1, d2]
                  : [d1]) {
            final s = at(t, dl);
            canvas.drawLine(
              s + const Offset(-3.4, -3.4),
              s + const Offset(3.4, 3.4),
              tickPen,
            );
          }
        }
        // text angle = string angle, flipped to stay upright
        var ang = math.atan2(dir.dy, dir.dx);
        // screen y is flipped vs world y
        ang = -ang;
        if (ang > math.pi / 2) ang -= math.pi;
        if (ang < -math.pi / 2) ang += math.pi;
        _lblAngle = ang;
        for (var k = 0; k + 1 < ords.length; k++) {
          final gapLen = ords[k + 1] - ords[k];
          if (gapLen < 0.10) continue;
          label(
            _fmt(gapLen),
            at((ords[k] + ords[k + 1]) / 2, d1 + 0.16),
            c: single ? const Color(0xFF334155) : slate,
            bold: single,
          );
        }
        if (!single) {
          label(
            _fmt(ords.last - ords.first),
            at((ords.first + ords.last) / 2, d2 + 0.16),
            c: const Color(0xFF334155),
            bold: true,
          );
        }
        _lblAngle = 0;
      }
    }
  }

  /// Drawing-angle readout (0-359 deg, CCW from +X) for the live wall
  /// label - helps hit exact 30/45/60 deg walls.
  String _wallAngle(Offset a, Offset b) {
    var d = math.atan2(b.dy - a.dy, b.dx - a.dx) * 180 / math.pi;
    if (d < 0) d += 360;
    return '${d.toStringAsFixed(d == d.roundToDouble() ? 0 : 1)}°';
  }

  /// Dimension formatting honors the toolbar unit cycle: m prints
  /// bare metric (the classic look), ft gets a ′, in gets a ″ —
  /// matches the reference plans' conventions.
  String _fmt(double v) => switch (st._unit) {
    1 => '${(v / 0.3048).toStringAsFixed(2)}′',
    2 => '${(v / 0.0254).toStringAsFixed(1)}″',
    _ => v.toStringAsFixed(2),
  };

  /// Standalone length labels (wall segs, chains) keep an explicit
  /// unit word in metric mode; ′/″ already carry it.
  String _fmtM(double v) => st._unit == 0 ? '${_fmt(v)} m' : _fmt(v);

  /// Area readout for room titles — m² in metric, SF (sq ft) in both
  /// imperial modes like the reference sheet.
  String _fmtArea(double a) => st._unit == 0
      ? '${a.toStringAsFixed(1)} m²'
      : '${(a * 10.7639).round()} SF';

  /// Shoelace area of a flat x,y polygon (volume footprints).
  double _polyArea(List<double> fp) {
    var a = 0.0;
    for (var i = 0; i + 1 < fp.length; i += 2) {
      final j = (i + 2) % fp.length;
      a += fp[i] * fp[j + 1] - fp[j] * fp[i + 1];
    }
    return a.abs() / 2;
  }

  @override
  bool shouldRepaint(covariant _PlanPainter old) => true;
}

class _SolidPainter extends CustomPainter {
  final _ModelViewState st;
  final ColorScheme cs;
  final double dpr;
  _SolidPainter(this.st, this.cs, [this.dpr = 1.0]);

  static const _light = [0.35, -0.5, 0.78];

  @override
  void paint(Canvas canvas, Size size) {
    final m = st._sel;
    final faces = m?.cachedFaces();
    final pivot = st._orbitFocus;
    // frame-coherence signature: everything the static layer's output
    // depends on — camera, viewport, orbit pivot, render mode, plan
    // grid step, device pixel ratio. While this + the face list are
    // unchanged the recorded Picture replays verbatim (~14x faster —
    // measured in test/perf_campaign_test.dart, docs/PERF_CAMPAIGN_3D)
    final sig = Object.hash(
      st._yaw,
      st._pitch,
      st._z3,
      st._o3.dx,
      st._o3.dy,
      size.width,
      size.height,
      pivot[0],
      pivot[1],
      pivot[2],
      st._render,
      planGridLevels(st._pScale).step,
      dpr,
    );
    if (st._scenePic != null &&
        identical(m, st._sceneModel) &&
        identical(faces, st._sceneSrc) &&
        sig == st._sceneSig) {
      canvas.drawPicture(st._scenePic!);
    } else {
      final rec = PictureRecorder();
      _paintStatic(Canvas(rec), size);
      st._scenePic?.dispose();
      st._scenePic = rec.endRecording();
      st._sceneModel = m;
      st._sceneSrc = faces;
      st._sceneSig = sig;
      canvas.drawPicture(st._scenePic!);
    }
    _paintDynamic(canvas, size);
  }

  /// The static layer — sky, floor slab, ground lattice, RGB axes,
  /// composited ground shadow and the depth-sorted solids. Fully
  /// determined by the camera+geometry signature, so it records into
  /// `_scenePic` and replays until that signature changes.
  void _paintStatic(Canvas canvas, Size size) {
    final m = st._sel;
    final render = st._render;
    // per-frame view constants — the "view matrix" hoisted upstream:
    // trig evaluated ONCE, then each vertex costs ~12 flops and ZERO
    // libm calls (arm A9 of the perf campaign)
    final pivot = st._orbitFocus;
    final px = pivot[0], py = pivot[1], pz = pivot[2];
    final cy = math.cos(st._yaw), sy = math.sin(st._yaw);
    final cp = math.cos(st._pitch), sp = math.sin(st._pitch);
    final cx = size.width / 2 + st._o3.dx;
    final cyy = size.height / 2 + st._o3.dy;
    Offset prj(List<double> p) {
      final dx = p[0] - px, dy = p[1] - py, dz = p[2] - pz;
      final rx = dx * cy - dy * sy;
      final ry = dx * sy + dy * cy;
      return Offset(cx + rx * st._z3, cyy - (ry * sp + dz * cp) * st._z3);
    }

    double dep(List<double> p) =>
        ((p[0] - px) * sy + (p[1] - py) * cy) * cp - (p[2] - pz) * sp;
    if (render && !st._topDown) {
      // simple sky: pale blue up top fading to warm ground haze —
      // instantly reads as "rendered" vs the flat draft canvas
      canvas.drawRect(
        Offset.zero & size,
        Paint()
          ..shader = const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFFBCD6F0), Color(0xFFEAF1F7), Color(0xFFF5F0E8)],
            stops: [0.0, 0.62, 1.0],
          ).createShader(Offset.zero & size),
      );
    }
    // dollhouse floor slab under the model envelope (wood tone) —
    // a true background: painted ONCE after the lattice and before
    // the composited ground shadow + all depth-sorted solids, so it
    // can no longer depth-fight or blanket the shadow pass
    final ext = m?.bounds ?? (0.0, 0.0, 10.0, 8.0, 3.0);
    final faces = <(double, Face3)>[];
    Path? floorPath;
    var groundZ = 0.0;
    if (m != null && m.bounds != null) {
      const pad = 0.35;
      var base = double.infinity;
      for (final v in m.volumes) {
        base = math.min(base, v.base);
      }
      for (final w in m.walls) {
        base = math.min(base, w.base);
      }
      if (base == double.infinity) base = 0;
      groundZ = base - 0.02;
      final slab = [
        [ext.$1 - pad, ext.$2 - pad, groundZ],
        [ext.$3 + pad, ext.$2 - pad, groundZ],
        [ext.$3 + pad, ext.$4 + pad, groundZ],
        [ext.$1 - pad, ext.$4 + pad, groundZ],
      ];
      floorPath = Path();
      for (var i = 0; i < slab.length; i++) {
        final p = prj(slab[i]);
        i == 0 ? floorPath.moveTo(p.dx, p.dy) : floorPath.lineTo(p.dx, p.dy);
      }
      floorPath.close();
    }
    // ground grid — the SAME world lattice as the 2D plan: lines
    // at multiples of the plan's current grid step around the
    // model envelope, so both views share (0,0,0) and the RGB axes
    // sit exactly on grid intersections
    final grid = Paint()
      ..color = Colors.black.withValues(alpha: 0.05)
      ..strokeWidth = hairlinePx(dpr);
    final gStep = planGridLevels(st._pScale).step;
    const gm = 3.0; // context margin past the model envelope
    // coverage always includes (0,0) so the RGB axes can never
    // float off the lattice even when the model sits far out
    final gx0 = (math.min(ext.$1 - gm, 0.0) / gStep).floor() * gStep;
    final gx1 = (math.max(ext.$3 + gm, 0.0) / gStep).ceil() * gStep;
    final gy0 = (math.min(ext.$2 - gm, 0.0) / gStep).floor() * gStep;
    final gy1 = (math.max(ext.$4 + gm, 0.0) / gStep).ceil() * gStep;
    for (var x = gx0; x <= gx1 + 1e-9; x += gStep) {
      canvas.drawLine(prj([x, gy0, 0]), prj([x, gy1, 0]), grid);
    }
    for (var y = gy0; y <= gy1 + 1e-9; y += gStep) {
      canvas.drawLine(prj([gx0, y, 0]), prj([gx1, y, 0]), grid);
    }
    // axes at origin: X red, Y green, Z blue
    void axis(List<double> to, Color c) {
      canvas.drawLine(
        prj(const [0, 0, 0]),
        prj(to),
        Paint()
          ..color = c
          ..strokeWidth = 2,
      );
    }

    axis(const [3, 0, 0], const Color(0xFFEF5350));
    axis(const [0, 3, 0], const Color(0xFF66BB6A));
    axis(const [0, 0, 3], const Color(0xFF42A5F5));

    if (m == null) return;

    // floor slab background — one opaque paint over the lattice,
    // always under the shadow union and every real solid
    if (floorPath != null) {
      canvas.drawPath(floorPath, Paint()..color = const Color(0xFFD9C29E));
    }

    // render mode: ONE composited silhouette, clipped to the slab —
    // overlapping projections can no longer stack into dark ghosts
    if (render && !st._topDown && floorPath != null) {
      paintGroundShadow(
        canvas,
        faces: m.cachedFaces(),
        groundZ: groundZ,
        floorPath: floorPath,
        project: prj,
      );
    }

    // painter's algorithm, TWO levels: objects first (Face3.grp),
    // then faces within each object — each keyed by its FARTHEST
    // vertex (classic painter's sort). A CENTROID key mis-orders a
    // long wall against objects standing along it (the mid-span
    // centroid reads nearer than an object at the far end, so the
    // wall painted over furniture in front of it — "wall slices the
    // wardrobe"); farthest-vertex keys track depth across the whole
    // span without splitting faces. cachedFaces keeps orbit/hover
    // repaints cheap (transforms run only after real mutations).
    //
    // OVERLAP-SPLIT fix: when two groups' depth ranges OVERLAP, no
    // atomic group order can satisfy both — a project-size floor
    // slab straddling every wall's span, or a long wall running past
    // the slab edge. Whichever paints second overdrows the first
    // wherever their projections intersect: the beige "cut" notch
    // the user saw on a wall cap. The LARGER-range member of every
    // overlapping pair is de-atomized (its faces sort by their own
    // farthest vertex — correct for flat spanning pieces) while the
    // smallest member stays atomic, so compact objects like a sofa
    // against a wall still draw whole instead of face-sliced.
    final gNear = <int, double>{};
    final gMax = <int, double>{};
    final gCnt = <int, int>{};
    final nearOf = Map<Face3, double>.identity();
    for (final f in m.cachedFaces()) {
      var d = -double.infinity, dn = double.infinity;
      for (final p in f.v) {
        final q = dep(p);
        if (q > d) d = q;
        if (q < dn) dn = q;
      }
      faces.add((d, f));
      nearOf[f] = dn;
      final g = f.grp;
      gCnt[g] = (gCnt[g] ?? 0) + 1;
      if (d > (gMax[g] ?? -double.infinity)) gMax[g] = d;
      if (dn < (gNear[g] ?? double.infinity)) gNear[g] = dn;
    }
    double span(int g) => gMax[g]! - gNear[g]!;
    bool overlap(int a, int b) =>
        gNear[a]! < gMax[b]! + 1e-6 && gNear[b]! < gMax[a]! + 1e-6;
    final splitG = <int>{};
    for (final gx in gMax.keys) {
      for (final gy in gMax.keys) {
        if (gy == gx || !overlap(gx, gy)) continue;
        // gx splits unless it is clearly the SMALLEST of the pair
        if (span(gy) <= span(gx) * 1.25) {
          splitG.add(gx);
          break;
        }
      }
    }
    // MESH groups (dense furniture, >24 faces): VERTICAL faces (doors,
    // sides, panels) order by the midpoint of their depth range — a
    // thin panel's far vertex sits inside the body, so a farthest key
    // let interior shelves/handles paint over closed doors (the
    // "half-baked wireframe" look). Horizontal faces keep the farthest
    // key (a midpoint clipped bed pillows under the mattress).
    // Backface culling was tried and rejected: kit meshes ship with
    // inconsistent winding, so culling opens holes.
    bool mesh(int g) => (gCnt[g] ?? 0) > 24;
    double fk((double, Face3) e) => mesh(e.$2.grp) && e.$2.n[2].abs() < 0.5
        ? (e.$1 + nearOf[e.$2]!) / 2
        : e.$1;
    faces.sort((a, b) {
      final ka = splitG.contains(a.$2.grp) ? fk(a) : gMax[a.$2.grp]!;
      final kb = splitG.contains(b.$2.grp) ? fk(b) : gMax[b.$2.grp]!;
      if (ka != kb) return kb.compareTo(ka); // far first
      return fk(b).compareTo(fk(a)); // far face first within a tie
    });

    // pooled paints — mutate color per face instead of ~30k Paint
    // allocations per rebuild (the campaign showed allocs, not trig,
    // dominate the miss path)
    final fillP = Paint();
    final strokeP = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = hairlinePx(dpr)
      ..color = const Color(0xFF37474F).withValues(alpha: 0.3);
    for (final (_, f) in faces) {
      final path = Path();
      var x0 = double.infinity, y0 = double.infinity;
      var x1 = -double.infinity, y1 = -double.infinity;
      for (var i = 0; i < f.v.length; i++) {
        final p = prj(f.v[i]);
        x0 = math.min(x0, p.dx);
        y0 = math.min(y0, p.dy);
        x1 = math.max(x1, p.dx);
        y1 = math.max(y1, p.dy);
        i == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
      }
      path.close();
      // draft cull: sub-pixel faces cost a fill+stroke but paint
      // nothing — skip them (dense meshes stay fluid zoomed out)
      if ((x1 - x0) * (y1 - y0) < 0.35) continue;
      // frustum cull: fully off-viewport — a fill+stroke paints zero
      // pixels but still costs two draw calls
      if (x1 < 0 || y1 < 0 || x0 > size.width || y0 > size.height) {
        continue;
      }
      final dot = (f.n[0] * _light[0] + f.n[1] * _light[1] + f.n[2] * _light[2])
          .abs();
      final shade = render ? 0.42 + 0.68 * dot : 0.5 + 0.5 * dot;
      final c = Color(f.argb);
      final lc = Color.lerp(c, Colors.white, render ? 0.06 : 0.2)!;
      fillP.color = Color.fromARGB(
        255,
        (lc.r * 255 * shade).round().clamp(0, 255),
        (lc.g * 255 * shade).round().clamp(0, 255),
        (lc.b * 255 * shade).round().clamp(0, 255),
      );
      canvas.drawPath(path, fillP);
      if (!render && !mesh(f.grp)) {
        canvas.drawPath(path, strokeP);
      }
    }
  }

  /// The DYNAMIC layer — edit previews, ghosts, snap glyphs, selection
  /// handles. Depends on cursor/tool state, NOT the camera signature,
  /// so it always repaints live on top of the cached static layer.
  void _paintDynamic(Canvas canvas, Size size) {
    if (st._sel == null) return;

    // live edit previews — the in-progress wall extrudes in 3D as
    // you click (on EITHER canvas), and the armed block ghosts under
    // the 3D cursor so placement reads spatially
    const accent = Color(0xFF7C4DFF);
    void ghostFace(List<List<double>> v) {
      final path = Path();
      for (var i = 0; i < v.length; i++) {
        final p = st._proj3(v[i], size);
        i == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
      }
      path.close();
      canvas.drawPath(path, Paint()..color = accent.withValues(alpha: 0.16));
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.1
          ..color = accent.withValues(alpha: 0.75),
      );
    }

    // snap inference on the ground plane — one target feeds the
    // wall/block ghosts, the glyph and `_modelTap`, matching the plan
    SnapTarget? snap3;
    if (st._hover3 != null &&
        st._groundEditable &&
        (st._tool == _MTool.wall ||
            st._tool == _MTool.block ||
            (st._tool == _MTool.move && st._moving != null))) {
      snap3 = st._snapPt(st._s2g(st._hover3!, st._vp3), st._z3, st._projGround);
    }

    if (st._tool == _MTool.wall && st._wall.isNotEmpty) {
      final pts = [...st._wall];
      if (snap3 != null) {
        pts.add(snap3.p);
      } else if (st._hover3 != null) {
        final g = st._s2g(st._hover3!, st._vp3);
        pts.add(Offset(st._w(g.dx), st._w(g.dy)));
      }
      if (pts.length >= 2) {
        final ghost = Wall3d(
          points: [
            for (final p in pts) ...[p.dx, p.dy],
          ],
          thickness: st._wallT,
          height: st._wallH,
          argb: 0xFF7C4DFF,
        );
        for (final f in wallFaces(ghost)) {
          ghostFace(f.v);
        }
      }
      for (final p in st._wall) {
        canvas.drawCircle(
          st._proj3([p.dx, p.dy, st._wallH], size),
          3,
          Paint()..color = accent,
        );
      }
    }
    if (st._tool == _MTool.block && st._hover3 != null) {
      final g = st._s2g(st._hover3!, st._vp3);
      var w = snap3?.p ?? Offset(st._w(g.dx), st._w(g.dy));
      var rot3 = st._blkRot;
      var gz = 0.0;
      final m3 = st._sel;
      final seat3 = m3 == null
          ? null
          : (isTrussDef(st._blkDef.id)
                ? seatTrussOnWalls(m3, w, rot3, st._blkDef.w)
                : seatOnWall(m3, st._blkDef, w));
      if (seat3 != null) {
        w = seat3.$1;
        rot3 = seat3.$2;
        gz = seat3.$3;
      } else if (m3 != null) {
        final top = volumeTopAt(m3, w);
        if (top.isFinite) gz = top;
      }
      final ghost = Block3d(
        def: st._blkDef.id,
        x: w.dx,
        y: w.dy,
        rot: rot3,
        bz: gz,
      );
      // a registered mesh previews the real piece — doors/windows
      // stand vertically IN the wall instead of a flat floor sliver;
      // trusses preview via the parametric mesh (no OBJ registered)
      final fs =
          (isTrussDef(st._blkDef.id) ||
              blockMeshes.containsKey(st._blkDef.id))
          ? blockFaces(ghost, st._blkDef)
          : null;
      if (fs != null) {
        // truss members are boxes: painting every face makes ONE
        // member read as doubled boards — keep only the -Y side plates
        // so the ghost shows the true member layout (fink vs kingpost)
        final rgd = isTrussDef(st._blkDef.id)
            ? Offset(-math.sin(rot3), math.cos(rot3))
            : null;
        for (final f in fs) {
          if (rgd != null &&
              f.n[0] * rgd.dx + f.n[1] * rgd.dy > -0.9) {
            continue;
          }
          ghostFace(f.v);
        }
      } else {
        final fp = blockFootprint(ghost, st._blkDef);
        final h = st._blkDef.height;
        if (h > 0) {
          ghostFace([
            for (final p in fp) [p.dx, p.dy, gz + h],
          ]);
          for (var i = 0; i < fp.length; i++) {
            final a = fp[i], b = fp[(i + 1) % fp.length];
            ghostFace([
              [a.dx, a.dy, gz],
              [b.dx, b.dy, gz],
              [b.dx, b.dy, gz + h],
              [a.dx, a.dy, gz + h],
            ]);
          }
        } else {
          ghostFace([
            for (final p in fp) [p.dx, p.dy, gz + 0.02],
          ]);
        }
      }
    }

    // MOVE ghost on the 3D pane — footprint prism of the carried
    // block at the hovered ground point (seat-snapped when its def
    // mounts a wall)
    if (st._tool == _MTool.move && st._moving != null && st._hover3 != null) {
      final mv = st._moving!;
      final mdef = cadBlock(mv.def);
      if (mdef != null) {
        final g = st._s2g(st._hover3!, st._vp3);
        var w = snap3?.p ?? Offset(st._w(g.dx), st._w(g.dy));
        var rot3 = mv.rot;
        var gz = mv.bz;
        final m3 = st._sel;
        final seat3 = m3 == null
            ? null
            : (isTrussDef(mdef.id)
                  ? seatTrussOnWalls(
                      m3,
                      w,
                      rot3,
                      mdef.w * mv.sx * mv.scale,
                      ignore: mv,
                    )
                  : seatOnWall(m3, mdef, w));
        if (seat3 != null) {
          w = seat3.$1;
          rot3 = seat3.$2;
          gz = seat3.$3;
        } else if (m3 != null) {
          final top = volumeTopAt(m3, w);
          if (top.isFinite) gz = top;
        }
        final ghost = Block3d(
          def: mv.def,
          x: w.dx,
          y: w.dy,
          rot: rot3,
          scale: mv.scale,
          sx: mv.sx,
          sy: mv.sy,
          sz: mv.sz,
          bz: gz,
        );
        final fs =
            (isTrussDef(mdef.id) || blockMeshes.containsKey(mdef.id))
            ? blockFaces(ghost, mdef)
            : null;
        if (fs != null) {
          final rgd = isTrussDef(mdef.id)
              ? Offset(-math.sin(rot3), math.cos(rot3))
              : null;
          for (final f in fs) {
            if (rgd != null &&
                f.n[0] * rgd.dx + f.n[1] * rgd.dy > -0.9) {
              continue;
            }
            ghostFace(f.v);
          }
        } else {
          final fp = blockFootprint(ghost, mdef);
          final h = mdef.height;
          if (h > 0) {
            ghostFace([
              for (final p in fp) [p.dx, p.dy, gz + h],
            ]);
            for (var i = 0; i < fp.length; i++) {
              final a = fp[i], b = fp[(i + 1) % fp.length];
              ghostFace([
                [a.dx, a.dy, gz],
                [b.dx, b.dy, gz],
                [b.dx, b.dy, gz + h],
                [a.dx, a.dy, gz + h],
              ]);
            }
          } else {
            ghostFace([
              for (final p in fp) [p.dx, p.dy, gz + 0.02],
            ]);
          }
        }
      }
    }

    // ROTATE ghost on the 3D pane — footprint prism of the carried
    // block spins around its own centre to the cursor's ground angle
    if (st._tool == _MTool.rotate &&
        st._rotating != null &&
        st._hover3 != null &&
        st._groundEditable) {
      final r = st._rotating!;
      final rdef = cadBlock(r.def);
      if (rdef != null) {
        final g = st._s2g(st._hover3!, st._vp3);
        final ghost = Block3d(
          def: r.def,
          x: r.x,
          y: r.y,
          rot: st._rotPreview(g),
          scale: r.scale,
          sx: r.sx,
          sy: r.sy,
          sz: r.sz,
          bz: r.bz,
        );
        final fp = blockFootprint(ghost, rdef);
        final h = rdef.height;
        if (h > 0) {
          ghostFace([
            for (final p in fp) [p.dx, p.dy, h],
          ]);
          for (var i = 0; i < fp.length; i++) {
            final a = fp[i], b = fp[(i + 1) % fp.length];
            ghostFace([
              [a.dx, a.dy, 0.0],
              [b.dx, b.dy, 0.0],
              [b.dx, b.dy, h],
              [a.dx, a.dy, h],
            ]);
          }
        } else {
          ghostFace([
            for (final p in fp) [p.dx, p.dy, 0.02],
          ]);
        }
      }
    }

    // inference glyph on the ground plane — same vocabulary as 2D
    if (snap3 != null && st._snap) {
      paintSnapGlyph(
        canvas,
        st._proj3([snap3.p.dx, snap3.p.dy, 0.02], size),
        snap3.kind,
        cs,
      );
    }

    // eraser cursor on the 3D pane — `_hover3` is already screen space
    if (st._tool == _MTool.eraser && st._hover3 != null) {
      final s = st._hover3!;
      canvas.save();
      canvas.translate(s.dx, s.dy);
      canvas.rotate(-0.7);
      final rr = RRect.fromRectAndRadius(
        const Rect.fromLTWH(-7, -4, 14, 9),
        const Radius.circular(2),
      );
      canvas.drawRRect(rr, Paint()..color = const Color(0xFFF472B6));
      canvas.drawRect(
        const Rect.fromLTWH(-7, -4, 14, 5),
        Paint()..color = Colors.white,
      );
      canvas.drawRRect(
        rr,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2
          ..color = const Color(0xFF9D174D),
      );
      canvas.restore();
    }

    // selection cage (task 18): same accent vocabulary as the plan —
    // every face edge outlined (SketchUp's blue cage), ring handles at
    // the semantic vertices at TOP height; desaturated when the plan
    // is the active pane
    final selActive = !st._paneActivePlan;
    final selC = selColorFor(cs, selActive);
    List<Face3> selFaces = [];
    final selHandles = <List<double>>[];
    final v = st._vol, wl = st._wallSel, bl = st._blkSel;
    if (v != null) {
      selFaces = volumeFaces(v);
      for (var i = 0; i < v.fp.length; i += 2) {
        selHandles.add([v.fp[i], v.fp[i + 1], v.top]);
      }
    } else if (wl != null) {
      selFaces = wallFaces(wl);
      for (var i = 0; i < wl.pts.length; i += 2) {
        selHandles.add([wl.pts[i], wl.pts[i + 1], wl.top]);
      }
    } else if (bl != null) {
      // scale-gizmo: the true mesh bounding box (12 edges) + six
      // draggable square face grips — SketchUp's scale box. Handles
      // stay live while stretched because _layoutSelBox runs per frame.
      st._layoutSelBox(size);
      if (st._box3Pts.length == 8) {
        const edges = [
          (0, 1), (1, 2), (2, 3), (3, 0), // bottom quad
          (4, 5), (5, 6), (6, 7), (7, 4), // top quad
          (0, 4), (1, 5), (2, 6), (3, 7), // verticals
        ];
        final box = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.3
          ..color = selC;
        for (final (a, c) in edges) {
          canvas.drawLine(
            st._proj3(st._box3Pts[a], size),
            st._proj3(st._box3Pts[c], size),
            box,
          );
        }
        for (var i = 0; i < st._handles3.length; i++) {
          paintBoxHandle(
            canvas,
            st._handles3[i],
            selC,
            dim: !selActive,
            hot: i == st._overHandle || i == st._stretchAxis,
          );
        }
        // live dimension readout next to the dragged grip
        final ax = st._stretchAxis;
        if (ax >= 0 && ax < st._handles3.length) {
          final def = cadBlock(bl.def);
          if (def != null) {
            final bb = blockLocalBox(def);
            final label = switch (ax) {
              0 || 1 =>
                'W ${((bb[3] - bb[0]) * bl.sx * bl.scale).toStringAsFixed(2)} m',
              2 || 3 =>
                'D ${((bb[4] - bb[1]) * bl.sy * bl.scale).toStringAsFixed(2)} m',
              4 =>
                'H ${((bb[5] - bb[2]) * bl.sz * bl.scale).toStringAsFixed(2)} m',
              _ => 'LIFT ${bl.bz.toStringAsFixed(2)} m',
            };
            _dimTag(
              canvas,
              st._handles3[ax] + const Offset(14, -10),
              label,
              cs,
            );
          }
        }
      }
    }
    final selEdge = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..color = selC;
    for (final f in selFaces) {
      final path = Path();
      for (var i = 0; i < f.v.length; i++) {
        final p = st._proj3(f.v[i], size);
        i == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
      }
      path.close();
      canvas.drawPath(path, selEdge);
    }
    for (final h in selHandles) {
      paintSelHandle(canvas, st._proj3(h, size), selC, dim: !selActive);
    }
  }

  /// Small floating dimension pill used by the stretch gizmo.
  void _dimTag(Canvas canvas, Offset p, String text, ColorScheme cs) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w800,
          color: cs.primary,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final r = Rect.fromLTWH(p.dx, p.dy, tp.width + 8, tp.height + 6);
    canvas.drawRRect(
      RRect.fromRectAndRadius(r, const Radius.circular(4)),
      Paint()..color = Colors.white.withValues(alpha: 0.92),
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(r, const Radius.circular(4)),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = cs.primary,
    );
    tp.paint(canvas, Offset(p.dx + 4, p.dy + 3));
  }

  @override
  bool shouldRepaint(covariant _SolidPainter old) => true;
}

/// Miniature plan-symbol preview for a library row — renders the
/// block's own local linework fitted into the row's thumb box.
class _BlockThumb extends CustomPainter {
  final CadBlock def;
  _BlockThumb(this.def);

  @override
  void paint(Canvas canvas, Size size) {
    var x0 = double.infinity, y0 = double.infinity;
    var x1 = -double.infinity, y1 = -double.infinity;
    for (final l in def.lines) {
      for (final p in l) {
        x0 = math.min(x0, p.dx);
        y0 = math.min(y0, p.dy);
        x1 = math.max(x1, p.dx);
        y1 = math.max(y1, p.dy);
      }
    }
    if (!x0.isFinite || x1 - x0 < 1e-6 || y1 - y0 < 1e-6) return;
    const pad = 3.0;
    final s = math.min(
      (size.width - pad * 2) / (x1 - x0),
      (size.height - pad * 2) / (y1 - y0),
    );
    final ox = pad + (size.width - pad * 2 - (x1 - x0) * s) / 2;
    final oy = pad + (size.height - pad * 2 - (y1 - y0) * s) / 2;
    final pen = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.1
      ..color = const Color(0xFF455A64);
    for (final l in def.lines) {
      if (l.length < 2) continue;
      final path = Path()
        ..moveTo(ox + (l.first.dx - x0) * s, oy + (l.first.dy - y0) * s);
      for (var i = 1; i < l.length; i++) {
        path.lineTo(ox + (l[i].dx - x0) * s, oy + (l[i].dy - y0) * s);
      }
      canvas.drawPath(path, pen);
    }
  }

  @override
  bool shouldRepaint(covariant _BlockThumb old) => old.def != def;
}
