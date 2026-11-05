import 'dart:math' as math;
import 'dart:ui' show Offset;

import 'calculators.dart';
import 'model3d.dart';
import 'models.dart';
import 'structural.dart';

/// Quantities measured straight from a [Model3d] — the same geometry
/// the 2D/3D canvases draw, so the BOQ always matches the model.
class Takeoff {
  /// wall thickness (m, rounded to cm) -> (length m, gross area m2)
  final Map<double, (double, double)> wallsByThk;
  final double wallLen;
  final double wallGross;
  final double aperture;
  final int doors;
  final int windows;
  final double floorArea;
  final double slabVol;
  final double colVol;
  final int colCount;
  final int stairs;
  /// average column footprint side (m) and height (m) — for the
  /// steel-form prefill.
  final double colSec, colHgt;

  /// Structural options measured from the model: isolated footings
  /// (count + concrete volume + schedule side) and wall RC bands —
  /// tieBeam runs at wall base, bondBeam at wall top.
  final int footCount;
  final double footVol, footW;
  final double tieLen, bondLen;
  /// concrete volume of the 0.20-deep wall beams (exact per-wall
  /// thickness, accumulated during the takeoff)
  final double beamVol;
  /// per-slab classification: (area, oneWay?, minThk, actual thk)
  final List<(double, bool, double, double)> slabs;

  /// area (m2) of RC wall-beam bands per wall thickness - the band
  /// is concrete, so it comes OFF the CHB area (but not the paint)
  final Map<double, double> beamBand;

  /// ROOF SYSTEM measured from the placed truss fields + the model's
  /// RoofSpec (same numbers the roof sheet draws + callout prints):
  /// purlin rows/pieces are 6m commercial lengths lapped over
  /// supports; roofLm is the eave->ridge cut length times the sheet
  /// columns (long-span profiles sell by the linear meter); roofSheets
  /// counts standard-length corrugated pieces instead.
  final int trusses;
  final double roofArea; // sq.m incl. overhang
  final double ridgeLm; // ridge cap run
  final double purlinLm;
  final int purlinPcs, purlinRows;
  final double roofLm; // long-span profiles
  final int roofSheets; // corrugated piece count
  final double roofSheetLen; // picked standard length (corrugated)
  final int tekscrews;
  final double trussChordLm, trussWebLm; // angle steel per field sum

  const Takeoff({
    required this.wallsByThk,
    required this.wallLen,
    required this.wallGross,
    required this.aperture,
    required this.doors,
    required this.windows,
    required this.floorArea,
    required this.slabVol,
    required this.colVol,
    required this.colCount,
    required this.stairs,
    this.colSec = 0,
    this.colHgt = 0,
    this.footCount = 0,
    this.footVol = 0,
    this.footW = 0,
    this.tieLen = 0,
    this.bondLen = 0,
    this.beamVol = 0,
    this.slabs = const [],
    this.beamBand = const {},
    this.apByThk = const {},
    this.trusses = 0,
    this.roofArea = 0,
    this.ridgeLm = 0,
    this.purlinLm = 0,
    this.purlinPcs = 0,
    this.purlinRows = 0,
    this.roofLm = 0,
    this.roofSheets = 0,
    this.roofSheetLen = 0,
    this.tekscrews = 0,
    this.trussChordLm = 0,
    this.trussWebLm = 0,
  });

  double get wallNet => math.max(wallGross - aperture, 0.0);

  /// CHB wall area of one thickness group: gross - RC beam bands
  double masonryGross(double thk) =>
      math.max((wallsByThk[thk]?.$2 ?? 0) - (beamBand[thk] ?? 0), 0.0);

  /// total CHB net area (gross - beam bands - openings)
  double get masonryNet => wallsByThk.keys.fold(
    0.0,
    (a, k) => a + math.max(masonryGross(k) - apertureFor(k), 0.0),
  );
  double get concreteVol => slabVol + colVol + footVol + beamVol;
  bool get isEmpty =>
      wallGross <= 0 && floorArea <= 0 && colCount == 0 && stairs == 0;

  /// Thickness of the largest wall group (by gross area) — the group
  /// the editable form prefill represents.
  double? get mainThk {
    if (wallsByThk.isEmpty) return null;
    var best = wallsByThk.keys.first;
    for (final k in wallsByThk.keys) {
      if (wallsByThk[k]!.$2 > wallsByThk[best]!.$2) best = k;
    }
    return best;
  }

  /// aperture area attributed to each thickness group (by the wall
  /// the opening sits on) so CHB sizes net out their own openings.
  final Map<double, double> apByThk;
  double apertureFor(double thk) => apByThk[thk] ?? 0;
}

double _cm(double v) => (v * 100).round() / 100;

/// Structural panel (long, short) of a slab volume: beams/columns on
/// a grid cut a big floor into panels, so the span that governs slab
/// type and moment is the largest column-grid gap, not the whole
/// footprint. Falls back to the bounding box when a direction has
/// fewer than two grid lines.
(double, double) slabPanel(Model3d m, Volume3d v) {
  final b = v.bounds;
  List<double> grid(bool xAxis) {
    final lo = xAxis ? b.$1 : b.$2, hi = xAxis ? b.$3 : b.$4;
    final ol = xAxis ? b.$2 : b.$1, oh = xAxis ? b.$4 : b.$3;
    final vals = <double>[];
    for (final c in m.blocks) {
      if (c.def != 'col-sq' && c.def != 'col-rd') continue;
      final a = xAxis ? c.x : c.y, o = xAxis ? c.y : c.x;
      if (a < lo - 0.3 || a > hi + 0.3 || o < ol - 0.3 || o > oh + 0.3) continue;
      vals.add(a);
    }
    vals.sort();
    final out = <double>[];
    for (final x in vals) {
      if (out.isEmpty || x - out.last > 0.3) out.add(x);
    }
    return out.length < 2 ? [lo, hi] : out;
  }

  double gap(List<double> g) {
    var best = 0.0;
    for (var i = 1; i < g.length; i++) {
      best = math.max(best, g[i] - g[i - 1]);
    }
    return best;
  }

  final lx = gap(grid(true)), ly = gap(grid(false));
  return (math.max(lx, ly), math.max(math.min(lx, ly), 1e-6));
}

/// Measures [m]. Openings are attributed to the ONE nearest wall
/// segment they sit on (same 0.75*thickness test the wall piercing
/// uses), so a door is never subtracted twice.
Takeoff modelTakeoff(Model3d m) {
  final byThk = <double, (double, double)>{};
  var len = 0.0, gross = 0.0, tie = 0.0, bond = 0.0, beamVol = 0.0;
  final band = <double, double>{};
  for (final w in m.walls) {
    final t = _cm(w.thickness);
    final l = w.length;
    final g = l * w.height;
    len += l;
    gross += g;
    final p = byThk[t] ?? (0.0, 0.0);
    byThk[t] = (p.$1 + l, p.$2 + g);
    final nb = (w.tieBeam ? 1 : 0) + (w.bondBeam ? 1 : 0);
    if (w.tieBeam) {
      tie += l;
      beamVol += l * w.thickness * 0.20;
    }
    if (w.bondBeam) {
      bond += l;
      beamVol += l * w.thickness * 0.20;
    }
    if (nb > 0) band[t] = (band[t] ?? 0) + l * 0.20 * nb;
  }

  var ap = 0.0, doors = 0, windows = 0;
  final apBy = <double, double>{};
  var cols = 0, stairs = 0;
  var colVol = 0.0, colW = 0.0, colH = 0.0;
  var foots = 0;
  var footVol = 0.0, footW = 0.0;
  for (final b in m.blocks) {
    final def = cadBlock(b.def);
    if (def == null) continue;
    if (b.def == 'col-sq' || b.def == 'col-rd') {
      cols++;
      var a = def.w * b.sx * def.d * b.sy * b.scale * b.scale;
      if (b.def == 'col-rd') a *= math.pi / 4;
      colVol += a * def.height * b.sz * b.scale;
      colW += def.w * b.sx * b.scale;
      colH += def.height * b.sz * b.scale;
      if (b.footing) {
        foots++;
        final sec = def.w * b.sx * b.scale;
        final f = footingFor(sec, b.footW);
        footVol += f.vol + footingStemVol(sec, b.footD, f.t);
        footW += f.w;
      }
    } else if (b.def.startsWith('stairs')) {
      stairs++;
    } else if (b.def.startsWith('ftg-')) {
      // standalone footing pad: buried prism, real placed size
      foots++;
      final w = def.w * b.sx * b.scale;
      footVol += w * (def.d * b.sy * b.scale) * (def.height * b.sz * b.scale);
      footW += w;
    }
    if (!def.opening) continue;
    // nearest wall segment under this opening
    Wall3d? bw;
    var bestCross = double.infinity;
    var bestLo = 0.0, bestHi = 0.0;
    for (final w in m.walls) {
      for (var i = 0; i < w.segs; i++) {
        final a = Offset(w.pts[i * 2], w.pts[i * 2 + 1]);
        final c = Offset(w.pts[i * 2 + 2], w.pts[i * 2 + 3]);
        final sl = (c - a).distance;
        if (sl < 1e-9) continue;
        final dir = (c - a) / sl;
        final d0 = Offset(b.x, b.y) - a;
        final cross = (d0.dx * -dir.dy + d0.dy * dir.dx).abs();
        if (cross > w.thickness * 0.75 || cross >= bestCross) continue;
        final along = d0.dx * dir.dx + d0.dy * dir.dy;
        if (along < -0.05 || along > sl + 0.05) continue;
        var lo = double.infinity, hi = -double.infinity;
        for (final p in blockFootprint(b, def)) {
          final t = (p - a).dx * dir.dx + (p - a).dy * dir.dy;
          lo = math.min(lo, t);
          hi = math.max(hi, t);
        }
        bestCross = cross;
        bw = w;
        bestLo = math.max(lo, 0.0);
        bestHi = math.min(hi, sl);
      }
    }
    if (bw == null) continue;
    final width = math.max(bestHi - bestLo, 0.0);
    final k = b.sz * b.scale;
    final zlo = math.max(def.sill * k + b.bz, bw.base);
    final zhi = math.min(def.head * k + b.bz, bw.top);
    final a = width * math.max(zhi - zlo, 0.0);
    ap += a;
    final t = _cm(bw.thickness);
    apBy[t] = (apBy[t] ?? 0) + a;
    if (def.sill > 0.05) {
      windows++;
    } else {
      doors++;
    }
  }

  var floor = 0.0, slab = 0.0, massing = 0.0;
  var anyThin = false;
  final slabs = <(double, bool, double, double)>[];
  bool atLevel(Volume3d v) =>
      m.walls.isEmpty || m.walls.any((w) => (v.base - w.base).abs() <= 0.4);
  for (final v in m.volumes) {
    massing += v.area;
    if (v.height <= 0.5) {
      anyThin = true;
      // only slabs at a storey base are walked on / tiled - a roof
      // slab sits at wall TOP and gets no floor tiles
      if (atLevel(v)) floor += v.area;
      slab += v.area * v.height;
      final pn = slabPanel(m, v);
      final t = slabType(pn.$1, pn.$2);
      slabs.add((v.area, t == SlabType.oneWay, slabMinThk(t, pn.$2), v.height));
    }
  }

  if (!anyThin) floor = massing;

  // ROOF: every quantity derives from the same roofFields the roof
  // plan draws — purlin rows at spec spacing, eave->ridge sheet
  // lengths incl. overhang, and truss member steel per the parametric
  // mesh. Corrugated picks the shortest standard sheet length that
  // covers the slope (8/10/12 ft), two rows when it can't.
  final rs = m.roof;
  var trusses = 0, pPcs = 0, pRows = 0, sheets = 0;
  var pLm = 0.0, rArea = 0.0, ridge = 0.0, rLm = 0.0;
  var chord = 0.0, webLm = 0.0, sheetLen = 0.0;
  const sheetLens = [2.44, 3.05, 3.66]; // 8/10/12 ft corrugated GI
  for (final f in roofFields(m)) {
    trusses += f.count;
    pRows += f.purlinRows(rs);
    pPcs += f.purlinPcs(rs);
    pLm += f.purlinLm(rs);
    rArea += f.roofArea(rs);
    ridge += f.runLen;
    final slopeLen = f.slopeRoof(rs);
    final cols = (f.runLen / rs.roofEffWidth).ceil();
    if (rs.roofProfile == 'corrugated') {
      var len = sheetLens.last;
      var rows = 1;
      for (final l in sheetLens) {
        if (l >= slopeLen) {
          len = l;
          break;
        }
      }
      if (len < slopeLen) rows = (slopeLen / len).ceil();
      sheetLen = math.max(sheetLen, len);
      sheets += cols * rows;
    } else {
      rLm += 2 * cols * slopeLen; // one sheet column per slope
    }
    for (final t in f.trusses) {
      final def = cadBlock(t.def)!;
      final cw = trussChordWeb(
        t.panels,
        def.w * t.sx * t.scale,
        def.height * t.sz * t.scale,
        single: t.def == 'truss-sgl',
      );
      chord += cw.$1;
      webLm += cw.$2;
    }
  }
  return Takeoff(
    wallsByThk: byThk,
    wallLen: len,
    wallGross: gross,
    aperture: ap,
    doors: doors,
    windows: windows,
    floorArea: floor,
    slabVol: slab,
    colVol: colVol,
    colCount: cols,
    stairs: stairs,
    colSec: cols > 0 ? colW / cols : 0,
    colHgt: cols > 0 ? colH / cols : 0,
    footCount: foots,
    footVol: footVol,
    footW: foots > 0 ? footW / foots : 0,
    tieLen: tie,
    bondLen: bond,
    beamVol: beamVol,
    slabs: slabs,
    beamBand: band,
    apByThk: apBy,
    trusses: trusses,
    roofArea: rArea,
    ridgeLm: ridge,
    purlinLm: pLm,
    purlinPcs: pPcs,
    purlinRows: pRows,
    roofLm: rLm,
    roofSheets: sheets,
    roofSheetLen: sheetLen,
    tekscrews: (rArea * 7.5).ceil(), // ~15 screws per 2 sq.m sheet
    trussChordLm: chord,
    trussWebLm: webLm,
  );
}

/// One ready-to-insert BOQ work package from a takeoff.
class TakeoffWork {
  final String label; // group header text in the BOQ
  final List<CalcResult> results;
  /// optional per-result group headers (e.g. one per CHB thickness)
  final List<String>? labels;
  const TakeoffWork(this.label, this.results, {this.labels});
  int get lineCount => results.fold(0, (s, r) => s + r.lines.length);
}

String chbForThk(double thk) => thk <= 0.125 ? 'CHB 4"' : 'CHB 6"';
String _f(double v) => v.toStringAsFixed(2);

/// Masonry per wall-thickness group (CHB size from thickness, each
/// group nets out its own openings).
TakeoffWork? takeoffMasonry(Takeoff t, {String mortar = 'CLASS A (1:2)'}) {
  if (t.wallGross <= 0) return null;
  final out = <CalcResult>[];
  final labels = <String>[];
  final keys = t.wallsByThk.keys.toList()..sort();
  for (final k in keys) {
    final g = t.masonryGross(k);
    labels.add(
      '3D MODEL - ${_f(math.max(g - t.apertureFor(k), 0))} sq.m net wall - ${chbForThk(k)} (${(k * 100).round()}cm)',
    );
    out.add(
      calcMasonry(
        wallArea: g,
        apertureArea: t.apertureFor(k),
        chb: chbForThk(k),
        mortarClass: mortar,
      ),
    );
  }
  return TakeoffWork(
    '3D MODEL - ${_f(t.masonryNet)} sq.m net wall',
    out,
    labels: labels,
  );
}

TakeoffWork? takeoffPainting(Takeoff t, {int system = 0, bool bothSides = true}) {
  if (t.wallNet <= 0) return null;
  final a = t.wallNet * (bothSides ? 2 : 1);
  return TakeoffWork('3D MODEL - ${_f(a)} sq.m wall paint', [
    calcPainting(area: a, systemIndex: system),
  ]);
}

TakeoffWork? takeoffConcrete(Takeoff t, {String cls = 'CLASS A (1:2:4)'}) {
  if (t.concreteVol <= 0) return null;
  return TakeoffWork('3D MODEL - ${_f(t.concreteVol)} cu.m concrete', [
    calcConcrete(volume: t.concreteVol, concreteClass: cls),
  ]);
}

TakeoffWork? takeoffTiles(Takeoff t, {String size = '0.60 x 0.60'}) {
  if (t.floorArea <= 0) return null;
  return TakeoffWork('3D MODEL - ${_f(t.floorArea)} sq.m floor tiles', [
    calcTiles(area: t.floorArea, tileSize: size),
  ]);
}

/// NSCP 2015 structural steel for the WHOLE model — column bars
/// (410.6 min 1% Ag, min 4), wall tie/bond beams, footing mats and
/// slab mesh, aggregated into kg by bar diameter (the DB sells rebar
/// by kg). Notes carry the schedule so the BOQ stays traceable.
TakeoffWork? takeoffSteelSched(Model3d m) {
  final kgByDia = <double, double>{};
  var wire = 0.0;
  final notes = <String>[];
  void acc(BarSched b) {
    if (b.count <= 0) return;
    kgByDia[b.diaMm] = (kgByDia[b.diaMm] ?? 0) + b.kg;
    wire += b.kg * 0.02;
  }

  for (final b in m.blocks) {
    final def = cadBlock(b.def);
    if (def == null) continue;
    if (b.def == 'col-sq' || b.def == 'col-rd') {
      final sec = def.w * b.sx * b.scale;
      final h = def.height * b.sz * b.scale;
      final s = columnSched(sec, h, round: b.def == 'col-rd');
      acc(s.main);
      acc(s.tie);
      notes.add(
          'COL ${sec.toStringAsFixed(2)}×${sec.toStringAsFixed(2)}×${h.toStringAsFixed(1)}: ${s.main.label} + 10mm ties @${(s.tieSpacing * 100).round()}cm');
      if (b.footing) {
        final f = footingFor(sec, b.footW);
        acc(f.bars);
        notes.add(
            'FTG ${f.w.toStringAsFixed(1)}×${f.w.toStringAsFixed(1)}×${f.t.toStringAsFixed(2)}: ${f.bars.label} B/W');
      }
    } else if (b.def.startsWith('ftg-')) {
      final side = def.w * b.sx * b.scale;
      final f = footingFor(0, side);
      acc(f.bars);
      notes.add(
          'FTG-BLK ${side.toStringAsFixed(1)}×${side.toStringAsFixed(1)}: ${f.bars.label} B/W');
    }
  }
  for (final w in m.walls) {
    if (!w.tieBeam && !w.bondBeam) continue;
    final s = beamSched(w.thickness, 0.20, w.length);
    for (var i = 0; i < (w.tieBeam ? 1 : 0) + (w.bondBeam ? 1 : 0); i++) {
      acc(s.main);
      acc(s.tie);
    }
    notes.add(
        '${w.tieBeam && w.bondBeam ? 'TIE+BOND' : w.tieBeam ? 'TIE' : 'BOND'} BEAM ${w.length.toStringAsFixed(2)}m: ${s.main.label} + 10mm st @${(s.tieSpacing * 100).round()}cm');
  }
  for (final v in m.volumes) {
    if (v.height > 0.5) continue;
    final b = v.bounds;
    final bl = math.max(b.$3 - b.$1, b.$4 - b.$2);
    final bs = math.max(math.min(b.$3 - b.$1, b.$4 - b.$2), 1e-6);
    final pn = slabPanel(m, v);
    final t = slabType(pn.$1, pn.$2);
    for (final s in slabSched(t, bl, bs)) {
      acc(s);
    }
    final lbl = t == SlabType.oneWay ? 'ONE-WAY' : 'TWO-WAY';
    if (slabMinThk(t, pn.$2) > v.height + 1e-3) {
      notes.add(
          'SLAB panel ${pn.$1.toStringAsFixed(1)}×${pn.$2.toStringAsFixed(1)} $lbl: ${v.height.toStringAsFixed(2)}m < ${slabMinThk(t, pn.$2).toStringAsFixed(2)}m NSCP min');
    } else {
      notes.add(
          'SLAB panel ${pn.$1.toStringAsFixed(1)}×${pn.$2.toStringAsFixed(1)} $lbl: 10mm mesh @0.20');
    }
  }
  if (kgByDia.isEmpty) return null;
  final lines = <ComputedLine>[
    for (final d in (kgByDia.keys.toList()..sort()))
      ComputedLine(
        'Steel bar ${d.round()}mm',
        (kgByDia[d]! * 100).roundToDouble() / 100,
        'kg',
        'Steel bar ${d.round()}mm',
      ),
    ComputedLine(
        'Tie Wire #16 25kg/roll', (wire / 25).ceilToDouble(), 'roll', 'Tie Wire #16 25kg/roll'),
  ];
  return TakeoffWork(
      '3D MODEL - NSCP STEEL', [CalcResult('STEEL WORKS', lines, notes)]);
}

/// ROOFING WORKS for the placed truss fields: C-purlins by 6m piece
/// (section auto-keyed on the measured/spec truss spacing), roofing
/// by the profile's own unit (lm for long-span, standard-length pcs
/// for corrugated), ridge roll, tekscrews and the truss angle steel —
/// every quantity measured by [modelTakeoff] off the same geometry
/// the roof sheet draws, so the BOQ and the drawing never disagree.
TakeoffWork? takeoffRoofing(Model3d m, Takeoff t) {
  if (t.trusses <= 0) return null;
  final rs = m.roof;
  var spacing = rs.trussSpacing;
  for (final f in roofFields(m)) {
    spacing = math.max(spacing, f.measuredSpacing);
  }
  final sec = rs.purlinSection(spacing);

  final lines = <ComputedLine>[
    ComputedLine(
      '${rs.purlinLabel} x6.0m',
      t.purlinPcs.toDouble(),
      'pcs',
      rs.purlinPriceKey(spacing),
    ),
  ];
  // roofing sheet line: corrugated sells per standard-length piece,
  // long-span profiles per linear meter of eave->ridge cut
  if (rs.roofProfile == 'corrugated') {
    final ga = rs.roofThk <= 0.45 ? 'Ga.26' : 'Ga.24';
    final ft = (t.roofSheetLen / 0.3048).round();
    lines.add(
      ComputedLine(
        'Corrugated G.I. sheet $ga x ${ft}ft',
        t.roofSheets.toDouble(),
        'pcs',
        'Corrugated GI $ga x${ft}ft',
      ),
    );
  } else {
    final key = rs.roofProfile == 'tile'
        ? 'Tile-span roofing 0.5mm'
        : rs.roofProfile == 'seam'
        ? 'Standing seam roofing 0.6mm'
        : 'Rib-type long-span ${rs.roofThk}mm';
    lines.add(ComputedLine(rs.roofLabel, t.roofLm, 'lm', key));
  }
  lines.addAll([
    ComputedLine('Ridge roll 0.4mm', t.ridgeLm, 'lm', 'Ridge roll 0.4mm'),
    ComputedLine(
      'Tekscrew #12 x 2-1/2"',
      t.tekscrews.toDouble(),
      'pcs',
      'Tekscrew #12x2-1/2',
    ),
  ]);
  // truss steel: chords weld from L50x50x6, web members L40x40x4 —
  // 6m sticks + 5% cutting/lap waste; rod+primer scale with weight
  final chordPcs = (t.trussChordLm * 1.05 / 6.0).ceil();
  final webPcs = (t.trussWebLm * 1.05 / 6.0).ceil();
  if (chordPcs > 0) {
    lines.addAll([
      ComputedLine(
        'Angle bar L50x50x6 x6m',
        chordPcs.toDouble(),
        'pcs',
        'Angle bar L50x50x6 x6m',
      ),
      ComputedLine(
        'Angle bar L40x40x4 x6m',
        webPcs.toDouble(),
        'pcs',
        'Angle bar L40x40x4 x6m',
      ),
      ComputedLine(
        'Welding rod E6013',
        ((t.trussChordLm * 4.47 + t.trussWebLm * 2.42) * 0.02).ceilToDouble(),
        'kg',
        'Welding rod E6013',
      ),
      ComputedLine(
        'Red oxide metal primer',
        ((t.trussChordLm * 4.47 + t.trussWebLm * 2.42) / 50).ceilToDouble(),
        'gal',
        'Red oxide metal primer',
      ),
    ]);
  }

  final notes = <String>[
    '${t.trusses} truss(es) @ ${_f(spacing > 0 ? spacing : 0)}m o.c. '
        '- purlin section ${sec.$1}x${sec.$2}mm by span table',
    '${t.purlinRows} purlin rows @ ${_f(rs.purlinSpace)}m o.c. = '
        '${_f(t.purlinLm)} lm -> ${t.purlinPcs} pcs x 6.0m (lapped)',
    'Roof area ${_f(t.roofArea)} sq.m incl. ${_f(rs.overhang)}m eave '
        'overhang${rs.roofProfile == 'corrugated' ? '; ${_num2(t.roofSheetLen)}m sheets' : ''}',
    'Truss steel assumes L50x50x6 chords + L40x40x4 web angles, '
        '6m sticks + 5% lap/cut waste',
  ];
  return TakeoffWork(
    '3D MODEL - ${_f(t.roofArea)} sq.m ROOFING',
    [CalcResult('ROOFING WORKS', lines, notes)],
  );
}

String _num2(double v) => v.toStringAsFixed(2);

/// Inserts [w] into [est]-style storage via [add]. Returns lines added.
int insertTakeoffWork(
  TakeoffWork w,
  void Function(String section, String label, List<BoqLine> items) add,
) {
  var n = 0;
  for (var i = 0; i < w.results.length; i++) {
    final r = w.results[i];
    final items = [for (final l in r.lines) l.toBoqLine()];
    add(r.sectionTitle, w.labels?[i] ?? w.label, items);
    n += items.length;
  }
  return n;
}
