import 'dart:math' as math;
import 'dart:ui' show Offset;

import 'model3d.dart';
import 'structural.dart';
import 'takeoff.dart';

/// Automatic design calculation for a 3D model per NSCP 2015 (7th ed,
/// aligned with ASCE 7-10 / ACI 318-14): gravity load take-down (S204/
/// S205), equivalent lateral force (S208), wind (S207), LRFD load
/// combinations (S203) and member checks. Equivalent-static and
/// member-level only (no stiffness-matrix frame solve) - a PRELIMINARY
/// calculation sheet, not a sealed structural design.

enum Chk { info, ok, warn, fail }

/// A one-click model edit offered on a failing/warned check row:
/// [kind] selects the mutation applied by [applyDesignFix] to the part
/// identified by [targetId] using [value] (meters / section size).
/// [values] (kind 'footing-all') maps block id -> required side so a
/// single click builds every missing footing at its own size.
class DesignFix {
  final String kind; // 'footing' | 'footing-all' | 'footing-depth' | 'column' | 'slab'
  final String targetId;
  final double value;
  final String label; // button tooltip, e.g. 'Add 1.5m sq. footing'
  final Map<String, double>? values;
  const DesignFix(this.kind, this.targetId, this.value, this.label,
      {this.values});
}

/// Apply a check-row fix to the model. Returns true when the part was
/// found and mutated (call est.update() afterwards to rebuild).
bool applyDesignFix(Model3d m, DesignFix fix) {
  switch (fix.kind) {
    case 'footing':
      for (final b in m.blocks) {
        if (b.id == fix.targetId) {
          b.footing = true;
          b.footW = fix.value;
          return true;
        }
      }
      return false;
    case 'footing-all':
      var any = false;
      for (final e in (fix.values ?? const <String, double>{}).entries) {
        for (final b in m.blocks) {
          if (b.id == e.key) {
            b.footing = true;
            b.footW = e.value;
            any = true;
          }
        }
      }
      return any;
    case 'footing-depth':
      for (final b in m.blocks) {
        if (b.id == fix.targetId) {
          b.footD = fix.value;
          return true;
        }
      }
      return false;
    case 'pad':
      // resize a placed ftg-* pad block to [value] side and embed its
      // bottom to the fix's target depth (values['dep'], Table 305-1
      // floor-aware minimum carried by the row; 0.60 fallback)
      for (final b in m.blocks) {
        if (b.id == fix.targetId) {
          final def = cadBlock(b.def);
          if (def == null) return false;
          final cur = def.w * b.sx * b.scale;
          if (cur <= 0) return false;
          final k = fix.value / cur;
          b.sx *= k;
          b.sy *= k;
          final dep = fix.values?['dep'] ?? footingDepth(0);
          b.bz = def.height * b.sz * b.scale - dep;
          return true;
        }
      }
      return false;
    case 'column':
      for (final b in m.blocks) {
        if (b.id == fix.targetId) {
          final def = cadBlock(b.def);
          if (def == null) return false;
          final cur = def.w * b.sx * b.scale;
          if (cur <= 0) return false;
          final k = fix.value / cur;
          b.sx *= k;
          b.sy *= k;
          return true;
        }
      }
      return false;
    case 'slab':
      for (final v in m.volumes) {
        if (v.id == fix.targetId) {
          v.height = fix.value;
          return true;
        }
      }
      return false;
  }
  return false;
}

class CalcRow {
  final String label;
  final String? formula;
  final String value;
  final Chk status;
  final DesignFix? fix;

  /// Code citation for the check (e.g. 'NSCP 2015 S208.5.2.1') —
  /// section/eq/table numbers are verified against the bundled
  /// NSCP 2015 text in docs/nscp/NSCP-2015_djvu.txt.
  final String? ref;
  const CalcRow(this.label, this.value,
      {this.formula, this.status = Chk.info, this.fix, this.ref});
}

class CalcSection {
  final String title;
  final List<CalcRow> rows;
  const CalcSection(this.title, this.rows);
}

class CalcReport {
  final List<CalcSection> sections;
  final double w, v, t, ft, windX, windY;
  final List<double> storeyForces;
  final int ok, warn, fail;
  const CalcReport(
    this.sections, {
    this.w = 0,
    this.v = 0,
    this.t = 0,
    this.ft = 0,
    this.windX = 0,
    this.windY = 0,
    this.storeyForces = const [],
    this.ok = 0,
    this.warn = 0,
    this.fail = 0,
  });
}

/// (name, live kPa, importance I, fraction of LL in seismic weight,
///  live-load factor f1 per NSCP 203.3.1: 1.0 for assembly /
///  LL > 4.8 kPa / garage, else 0.5)
const kOccupancies = <(String, double, double, double, double)>[
  ('Residential', 1.9, 1.0, 0, 0.5),
  ('Office', 2.4, 1.0, 0, 0.5),
  ('Retail / assembly', 4.8, 1.0, 0, 1.0),
  ('Storage (light)', 6.0, 1.0, 0.25, 1.0),
  ('School', 1.9, 1.25, 0, 0.5),
  ('Essential facility', 1.9, 1.5, 0, 1.0),
];

/// (name, R, Ct) - NSCP Table 208-11 / Eq 208-12 coefficients
const kSystems = <(String, double, double)>[
  ('Concrete SMRF', 8.5, 0.0731),
  ('Concrete IMRF (Zone 2 only)', 5.5, 0.0731),
  ('Reinforced masonry bearing wall', 4.5, 0.0488),
];

const kSoils = ['SA', 'SB', 'SC', 'SD', 'SE'];

class DesignParams {
  int zone; // 2 or 4
  String soil;
  int occ; // index into kOccupancies
  int sys; // index into kSystems
  double na, nv; // near-source factors (Z4)
  double windKph;
  double fc, fy; // MPa
  double qa; // allowable soil bearing, kPa
  double roofDl, roofLl; // kPa
  double finishDl, ceilDl, partDl; // kPa

  DesignParams({
    this.zone = 4,
    this.soil = 'SD',
    this.occ = 0,
    this.sys = 0,
    this.na = 1.0,
    this.nv = 1.0,
    this.windKph = 200,
    this.fc = 21,
    this.fy = 276,
    this.qa = 100,
    this.roofDl = 0.6,
    this.roofLl = 1.0,
    this.finishDl = 1.1,
    this.ceilDl = 0.24,
    this.partDl = 0.75,
  });

  Map<String, dynamic> toJson() => {
    'zone': zone,
    'soil': soil,
    'occ': occ,
    'sys': sys,
    'na': na,
    'nv': nv,
    'windKph': windKph,
    'fc': fc,
    'fy': fy,
    'qa': qa,
    'roofDl': roofDl,
    'roofLl': roofLl,
    'finishDl': finishDl,
    'ceilDl': ceilDl,
    'partDl': partDl,
  };

  factory DesignParams.fromJson(Map<String, dynamic>? j) {
    final d = DesignParams();
    if (j == null) return d;
    double n(String k, double def) => (j[k] as num?)?.toDouble() ?? def;
    return DesignParams(
      zone: (j['zone'] as num?)?.toInt() ?? 4,
      soil: j['soil'] as String? ?? 'SD',
      occ: ((j['occ'] as num?)?.toInt() ?? 0).clamp(0, kOccupancies.length - 1),
      sys: ((j['sys'] as num?)?.toInt() ?? 0).clamp(0, kSystems.length - 1),
      na: n('na', d.na),
      nv: n('nv', d.nv),
      windKph: n('windKph', d.windKph),
      fc: n('fc', d.fc),
      fy: n('fy', d.fy),
      qa: n('qa', d.qa),
      roofDl: n('roofDl', d.roofDl),
      roofLl: n('roofLl', d.roofLl),
      finishDl: n('finishDl', d.finishDl),
      ceilDl: n('ceilDl', d.ceilDl),
      partDl: n('partDl', d.partDl),
    );
  }
}

/// NSCP Table 208-7 (Ca) and 208-8 (Cv); Z4 columns carry Na / Nv.
double seismicCa(int zone, String soil, double na) {
  const z2 = {'SA': .16, 'SB': .20, 'SC': .24, 'SD': .28, 'SE': .34};
  const z4 = {'SA': .32, 'SB': .40, 'SC': .40, 'SD': .44, 'SE': .44};
  return zone == 4 ? z4[soil]! * na : z2[soil]!;
}

double seismicCv(int zone, String soil, double nv) {
  const z2 = {'SA': .16, 'SB': .20, 'SC': .32, 'SD': .40, 'SE': .64};
  const z4 = {'SA': .32, 'SB': .40, 'SC': .56, 'SD': .64, 'SE': .96};
  return zone == 4 ? z4[soil]! * nv : z2[soil]!;
}

class SeismicResult {
  final double ca, cv, t, v, vmax, vmin, vz4, ft;
  final List<double> fx;
  const SeismicResult(
    this.ca,
    this.cv,
    this.t,
    this.v,
    this.vmax,
    this.vmin,
    this.vz4,
    this.ft,
    this.fx,
  );
}

/// Equivalent lateral force procedure, NSCP 208.5.2 (Eq 208-8..17).
/// [wx]/[hx]: per-level seismic weight (kN) and elevation (m).
SeismicResult seismicELF(DesignParams p, List<double> wx, List<double> hx) {
  final occ = kOccupancies[p.occ], sys = kSystems[p.sys];
  final ca = seismicCa(p.zone, p.soil, p.na);
  final cv = seismicCv(p.zone, p.soil, p.nv);
  final z = p.zone == 4 ? 0.40 : 0.20;
  final w = wx.fold(0.0, (a, b) => a + b);
  final hn = hx.isEmpty ? 0.0 : hx.reduce(math.max);
  final t = sys.$3 * math.pow(math.max(hn, 0.1), 0.75).toDouble();
  final r = sys.$2, i = occ.$3;
  final vRaw = cv * i * w / (r * t);
  final vmax = 2.5 * ca * i * w / r;
  final vmin = 0.11 * ca * i * w;
  final vz4 = p.zone == 4 ? 0.8 * z * p.nv * i * w / r : 0.0;
  var v = math.min(vRaw, vmax);
  v = math.max(v, math.max(vmin, vz4));
  final ft = t > 0.7 ? math.min(0.07 * t * v, 0.25 * v) : 0.0;
  var sumWh = 0.0;
  for (var k = 0; k < wx.length; k++) {
    sumWh += wx[k] * hx[k];
  }
  final fx = [
    for (var k = 0; k < wx.length; k++)
      (sumWh > 0 ? (v - ft) * wx[k] * hx[k] / sumWh : 0.0) +
          (hx[k] == hx.reduce(math.max) ? ft : 0.0),
  ];
  return SeismicResult(ca, cv, t, v, vmax, vmin, vz4, ft, fx);
}

class _Level {
  double base, top;
  final walls = <Wall3d>[];
  _Level(this.base, this.top);
}

/// Wall dead load kPa of face: ~15.3 kPa per m of CHB thickness
/// (100mm 1.53, 150mm 2.30 - NSCP 204-2 typical) + plaster both faces.
double chbKpa(double thk) => 15.3 * thk + 0.48;

String _f(double v, [int d = 2]) => v.toStringAsFixed(d);

CalcReport designCalc(Model3d m, DesignParams p) {
  final out = <CalcSection>[];
  final occ = kOccupancies[p.occ];
  final sys = kSystems[p.sys.clamp(0, kSystems.length - 1)];
  final sysName = sys.$1, sysR = sys.$2;
  const gc = 24.0; // kN/m3 reinforced concrete (NSCP Table 204-1)
  var nOk = 0, nWarn = 0, nFail = 0;
  CalcRow row(String l, String v,
      {String? f, Chk s = Chk.info, DesignFix? fix, String? ref}) {
    if (s == Chk.ok) nOk++;
    if (s == Chk.warn) nWarn++;
    if (s == Chk.fail) nFail++;
    return CalcRow(l, v, formula: f, status: s, fix: fix, ref: ref);
  }

  // ---- 1. criteria
  out.add(
    CalcSection('1. DESIGN CRITERIA', [
      row(
        'Code basis',
        'NSCP 2015 (7th ed.) / ACI 318-14M / ASCE 7-10',
        f: 'equivalent lateral force procedure, UBC-97 formulation',
        ref: 'NSCP 2015 Preface',
      ),
      row('Concrete f\'c', '${_f(p.fc, 1)} MPa', ref: 'S401.2'),
      row('Rebar fy', '${_f(p.fy, 0)} MPa', ref: 'S420.2'),
      row('Concrete unit weight', '${_f(gc, 1)} kN/m3', ref: 'Table 204-1'),
      row('Occupancy', '${occ.$1}  (I = ${_f(occ.$3)})',
          ref: 'Table 208-1 / 205-1'),
      row('Structural system', '$sysName  (R = ${_f(sysR, 1)})',
          ref: 'Table 208-11'),
      row('Seismic zone / soil',
          'Zone ${p.zone}  (Z = ${p.zone == 4 ? '0.40' : '0.20'}) / ${p.soil}',
          ref: 'Table 208-3 / 208-2'),
      row('Allowable soil bearing', '${_f(p.qa, 0)} kPa',
          ref: 'Table 304-1'),
    ]),
  );
  if (m.walls.isEmpty && m.volumes.isEmpty && m.blocks.isEmpty) {
    return CalcReport(out);
  }

  // ---- levels from wall bases
  final levels = <_Level>[];
  for (final w in m.walls) {
    final b = (w.base * 2).round() / 2;
    var lv = levels.where((l) => (l.base - b).abs() < 0.25).firstOrNull;
    if (lv == null) {
      lv = _Level(b, b + w.height);
      levels.add(lv);
    }
    lv.top = math.max(lv.top, w.base + w.height);
    lv.walls.add(w);
  }
  levels.sort((a, b) => a.base.compareTo(b.base));
  if (levels.isEmpty) {
    final top = m.volumes.fold(0.0, (a, v) => math.max(a, v.top));
    levels.add(_Level(0, math.max(top, 3.0)));
  }

  // ---- floors: suspended slabs (floor above a level) / on-grade
  // each floor: level index it closes, area, dead/live kPa
  final floors = <(int, List<Volume3d>, double, double, double)>[];
  final onGrade = <Volume3d>[];
  final used = <Volume3d>{};
  for (var k = 0; k < levels.length; k++) {
    final vs = m.volumes
        .where((v) => v.height <= 0.5 && (v.base - levels[k].top).abs() <= 0.4)
        .toList();
    if (vs.isEmpty) continue;
    used.addAll(vs);
    final a = vs.fold(0.0, (s, v) => s + v.area);
    final thk = vs.fold(0.0, (s, v) => s + v.area * v.height) / a;
    final dl = thk * gc + p.finishDl + p.ceilDl + p.partDl;
    final top = k == levels.length - 1;
    floors.add((k, vs, a, dl, top ? p.roofLl : occ.$2));
  }
  for (final v in m.volumes) {
    if (v.height <= 0.5 && !used.contains(v)) onGrade.add(v);
  }
  // roof allowance when the top level has no slab above it
  final topK = levels.length - 1;
  final hasTopSlab = floors.any((f) => f.$1 == topK);
  double roofArea = 0;
  if (!hasTopSlab) {
    var x0 = double.infinity, y0 = double.infinity;
    var x1 = -double.infinity, y1 = -double.infinity;
    for (final w in levels[topK].walls) {
      final b = w.bounds;
      x0 = math.min(x0, b.$1);
      y0 = math.min(y0, b.$2);
      x1 = math.max(x1, b.$3);
      y1 = math.max(y1, b.$4);
    }
    if (x0.isFinite) roofArea = (x1 - x0) * (y1 - y0);
  }

  // ---- per-level wall DL (net of openings)
  final lvWallKn = List.filled(levels.length, 0.0);
  final wallKnPerM = <Wall3d, double>{};
  for (var k = 0; k < levels.length; k++) {
    for (final w in levels[k].walls) {
      final sub = Model3d()
        ..walls.add(w)
        ..blocks.addAll(m.blocks);
      final t = modelTakeoff(sub);
      final kpa = chbKpa(w.thickness);
      // CHB only: RC beam bands are weighed as concrete, not masonry
      lvWallKn[k] += kpa * t.masonryNet;
      final fnet = t.wallGross > 1e-9 ? t.masonryNet / t.wallGross : 1.0;
      wallKnPerM[w] = kpa * w.height * fnet +
          w.thickness * 0.20 * gc * ((w.tieBeam ? 1 : 0) + (w.bondBeam ? 1 : 0));
    }
  }
  final colBlocks = [
    for (final b in m.blocks)
      if (b.def == 'col-sq' || b.def == 'col-rd') b,
  ];
  double colSecOf(Block3d b) {
    final d = cadBlock(b.def)!;
    return d.w * b.sx * b.scale;
  }

  double colHOf(Block3d b) => cadBlock(b.def)!.height * b.sz * b.scale;
  double colVolOf(Block3d b) {
    final s = colSecOf(b);
    final a = b.def == 'col-rd' ? math.pi * s * s / 4 : s * s;
    return a * colHOf(b);
  }

  // ---- 2. dead loads
  final dl = <CalcRow>[];
  var totalDl = 0.0;
  for (var k = 0; k < levels.length; k++) {
    dl.add(
      row(
        'Level ${k + 1} CHB walls (net, plastered)',
        '${_f(lvWallKn[k])} kN',
        f: 'sum(kPa(t) x net area), kPa = 15.3t + 0.48',
        ref: 'Table 204-2',
      ),
    );
    totalDl += lvWallKn[k];
  }
  for (final f in floors) {
    final kn = f.$4 * f.$3;
    dl.add(
      row(
        f.$1 == topK ? 'Roof slab (above level ${f.$1 + 1})' : 'Floor slab above level ${f.$1 + 1}',
        '${_f(kn)} kN',
        f: '${_f(f.$3)} m2 x ${_f(f.$4)} kPa (sw + finish ${_f(p.finishDl)} + ceiling ${_f(p.ceilDl)} + partitions ${_f(p.partDl)})',
        ref: 'S204',
      ),
    );
    totalDl += kn;
  }
  if (roofArea > 0) {
    final kn = p.roofDl * roofArea;
    dl.add(
      row(
        'Roof (GI on purlins)',
        '${_f(kn)} kN',
        f: '${_f(roofArea)} m2 x ${_f(p.roofDl)} kPa',
        ref: 'Table 204-2',
      ),
    );
    totalDl += kn;
  }
  var colKn = 0.0;
  for (final b in colBlocks) {
    colKn += colVolOf(b) * gc;
  }
  if (colBlocks.isNotEmpty) {
    dl.add(
      row('Columns (${colBlocks.length})', '${_f(colKn)} kN',
          f: 'sum(Ag x H) x 24', ref: 'Table 204-1'),
    );
    totalDl += colKn;
  }
  var beamKn = 0.0;
  final tk = modelTakeoff(m);
  beamKn = tk.beamVol * gc;
  if (beamKn > 0) {
    dl.add(row('Wall tie/bond beams', '${_f(beamKn)} kN',
        f: '${_f(tk.beamVol, 3)} m3 x 24', ref: 'Table 204-1'));
    totalDl += beamKn;
  }
  var gradeKn = 0.0;
  for (final v in onGrade) {
    gradeKn += v.area * v.height * gc;
  }
  if (gradeKn > 0) {
    dl.add(row('Slab on grade (not in seismic mass)', '${_f(gradeKn)} kN',
        f: 'area x thk x 24', ref: 'Table 204-1'));
  }
  dl.add(row('TOTAL DEAD LOAD (superstructure)', '${_f(totalDl)} kN',
      s: Chk.info, ref: 'S204'));
  out.add(CalcSection('2. DEAD LOADS (NSCP S204)', dl));

  // ---- 3. live loads
  var totalLl = 0.0;
  final ll = <CalcRow>[];
  for (final f in floors) {
    final kn = f.$5 * f.$3;
    totalLl += kn;
    ll.add(
      row(
        f.$1 == topK ? 'Roof live load' : 'Floor live load (${occ.$1})',
        '${_f(kn)} kN',
        f: '${_f(f.$3)} m2 x ${_f(f.$5)} kPa',
        ref: 'Table 205-1',
      ),
    );
  }
  if (roofArea > 0) {
    final kn = p.roofLl * roofArea;
    totalLl += kn;
    ll.add(row('Roof live load', '${_f(kn)} kN',
        f: '${_f(roofArea)} m2 x ${_f(p.roofLl)} kPa',
        ref: 'Table 205-1'));
  }
  ll.add(row('TOTAL LIVE LOAD', '${_f(totalLl)} kN', ref: 'S205'));
  out.add(CalcSection('3. LIVE LOADS (NSCP S205)', ll));

  // ---- 4. seismic
  final wx = <double>[], hx = <double>[];
  for (var k = 0; k < levels.length; k++) {
    var wk = lvWallKn[k];
    for (final w in levels[k].walls) {
      wk += w.length * w.thickness * 0.20 * ((w.tieBeam ? 1 : 0) + (w.bondBeam ? 1 : 0)) * gc;
    }
    for (final b in colBlocks) {
      final kk = _levelOf(levels, b.bz);
      if (kk == k) wk += colVolOf(b) * gc;
    }
    for (final f in floors) {
      if (f.$1 == k) wk += f.$4 * f.$3 + occ.$4 * f.$5 * f.$3;
    }
    if (k == topK && roofArea > 0) wk += p.roofDl * roofArea;
    wx.add(wk);
    hx.add(levels[k].top);
  }
  final wTot = wx.fold(0.0, (a, b) => a + b);
  final hn = hx.reduce(math.max);
  final sr = seismicELF(p, wx, hx);
  final vBase = sr.v, tPer = sr.t, ftTop = sr.ft;
  final fxL = sr.fx;
  // vertical seismic effect - NSCP 208.6.1 Eq 208-18: for strength
  // design Ev = 0.5 Ca I D adds to D in the E combos (rho = 1.0 -
  // the element-storey shear ratio rmax needs a full frame model;
  // rho is also 1.0 in Zone 2 and for drift)
  final evFac = 0.5 * sr.ca * occ.$3;
  final vPct = wTot > 0 ? sr.v / wTot * 100 : 0.0;
  out.add(
    CalcSection('4. SEISMIC - EQUIVALENT LATERAL FORCE (NSCP S208)', [
      row('Seismic weight W', '${_f(wTot)} kN',
          f: 'total dead + ${_f(occ.$4 * 100, 0)}% of floor live (storage) + partitions >= 0.5 kPa',
          ref: 'S208.6.1'),
      row('Ca / Cv', '${_f(sr.ca)} / ${_f(sr.cv)}',
          f: 'Na=${_f(p.na)}, Nv=${_f(p.nv)} (Z4 near-source)',
          ref: 'Table 208-7/8, Na/Nv Tables 208-5/6'),
      row('Height hn', '${_f(hn)} m', ref: 'S208.5.2.2'),
      row('Period T', '${_f(sr.t, 3)} s',
          f: 'T = Ct hn^0.75 = ${sys.$3} x ${_f(hn)}^0.75 (Method A)',
          ref: 'S208.5.2.2 Eq.208-12'),
      row('V', '${_f(sr.cv * occ.$3 * wTot / (sys.$2 * sr.t))} kN',
          f: 'Cv I W / (R T)', ref: 'S208.5.2.1 Eq.208-8'),
      row('V max', '${_f(sr.vmax)} kN', f: '2.5 Ca I W / R',
          ref: 'Eq.208-9'),
      row('V min', '${_f(sr.vmin)} kN', f: '0.11 Ca I W',
          ref: 'Eq.208-10'),
      if (p.zone == 4)
        row('V min Z4', '${_f(sr.vz4)} kN', f: '0.8 Z Nv I W / R',
            ref: 'Eq.208-11'),
      row('DESIGN BASE SHEAR V', '${_f(sr.v)} kN  (${_f(vPct, 1)}% W)',
          s: Chk.info, ref: 'S208.5.2'),
      row('Top force Ft', '${_f(sr.ft)} kN',
          f: 'T>0.7s: min(0.07TV, 0.25V)', ref: 'S208.5.2.3 Eq.208-16'),
      for (var k = 0; k < levels.length; k++)
        row(
          'Fx level ${k + 1}  (w=${_f(wx[k], 1)} kN, h=${_f(hx[k])} m)',
          '${_f(sr.fx[k])} kN',
          f: '(V-Ft) w h / sum(w h)',
          ref: 'Eq.208-17',
        ),
      row('Vertical effect Ev', '0.5 Ca I D = ${_f(evFac)} x D',
          f: 'E = rho Eh + Ev; strength design adds 0.5 Ca I D to D',
          ref: 'S208.6.1 Eq.208-18'),
      row('Redundancy rho', '1.0',
          f: 'rho = 2 - 6.1/(rmax sqrt(Ab)), capped [1.0, 1.5]; 1.25 max for SMRF; rmax needs a frame model - conservative 1.0 used',
          ref: 'S208.6.1 Eq.208-20'),
      if (p.zone == 4 && sys.$1.contains('IMRF'))
        row('System check', 'IMRF/OMRF not permitted in Zone 4',
            s: Chk.fail, ref: 'S208.4.6.3 / Table 208-11'),
    ]),
  );

  // ---- 5. wind
  var x0 = double.infinity, y0 = double.infinity;
  var x1 = -double.infinity, y1 = -double.infinity;
  for (final w in m.walls) {
    final b = w.bounds;
    x0 = math.min(x0, b.$1);
    y0 = math.min(y0, b.$2);
    x1 = math.max(x1, b.$3);
    y1 = math.max(y1, b.$4);
  }
  final bx = x0.isFinite ? x1 - x0 : 0.0, by = y0.isFinite ? y1 - y0 : 0.0;
  final vms = p.windKph / 3.6;
  const kz = 0.85, kzt = 1.0, kd = 0.85, g = 0.85, cp = 1.3;
  final qz = 0.613 * kz * kzt * kd * vms * vms / 1000; // kPa
  final pw = qz * g * cp;
  final windX = pw * by * hn; // wind in X acts on the Y-width face
  final windY = pw * bx * hn;
  out.add(
    CalcSection('5. WIND (NSCP S207, simplified enclosed building)', [
      row('Basic wind speed', '${_f(p.windKph, 0)} kph = ${_f(vms, 1)} m/s',
          ref: 'S207A.5.1'),
      row('Velocity pressure q', '${_f(qz, 3)} kPa',
          f: 'q = 0.613 Kz Kzt Kd V^2 (Kz 0.85, Kzt 1.0, Kd 0.85)',
          ref: 'S207B.6'),
      row('Design pressure p', '${_f(pw, 3)} kPa',
          f: 'q G (Cpw - Cpl) = q x 0.85 x 1.3', ref: 'S207B.6'),
      row('Wind base shear, X dir', '${_f(windX)} kN',
          f: '${_f(pw, 3)} x ${_f(by)} m x ${_f(hn)} m', ref: 'S207B.6'),
      row('Wind base shear, Y dir', '${_f(windY)} kN',
          f: '${_f(pw, 3)} x ${_f(bx)} m x ${_f(hn)} m', ref: 'S207B.6'),
      row(
        'Governing lateral',
        vBase >= math.max(windX, windY) ? 'SEISMIC  ${_f(vBase)} kN' : 'WIND  ${_f(math.max(windX, windY))} kN',
        ref: 'S208.5.2 / S207',
      ),
    ]),
  );

  // ---- 6. combinations - NSCP 203.3.1 (f1 per occupancy:
  // 1.0 assembly / LL>4.8 kPa / garage, else 0.5); seismic E per
  // 208.6.1: E = rho Eh + Ev where Ev = 0.5 Ca I D for strength design
  final d = totalDl, l = totalLl;
  final lrLike = roofArea > 0 || hasTopSlab ? 0.5 * p.roofLl : 0.0;
  final f1 = occ.$5;
  out.add(
    CalcSection('6. LOAD COMBINATIONS (NSCP S203 LRFD)', [
      row('1.4(D+F)', '${_f(1.4 * d)} kN', ref: 'Eq.203-1'),
      row('1.2D + 1.6L + 0.5Lr', '${_f(1.2 * d + 1.6 * l + lrLike)} kN',
          f: 'Lr ~ roof LL', ref: 'Eq.203-2'),
      row('(1.2 + 0.5CaI)D + E + ${_f(f1, 1)}L',
          '${_f((1.2 + evFac) * d + f1 * l)} kN  + E = ${_f(vBase)} kN lateral',
          f: 'E = Eh + Ev, Ev = 0.5 Ca I D adds ${_f(evFac)} x D to dead',
          ref: 'Eq.203-5 + S208.6.1'),
      row('(0.9 - 0.5CaI)D + E',
          '${_f((0.9 - evFac) * d)} kN  + E = ${_f(vBase)} kN lateral',
          f: 'uplift: Ev reduces D', ref: 'Eq.203-7 + S208.6.1'),
      row('1.2D + 1.0W + ${_f(f1, 1)}L',
          '${_f(1.2 * d + f1 * l)} kN  + W = ${_f(math.max(windX, windY))} kN lateral',
          ref: 'Eq.203-4'),
      row('0.9D + 1.0W',
          '${_f(0.9 * d)} kN  + W = ${_f(math.max(windX, windY))} kN lateral',
          ref: 'Eq.203-6'),
      row('Governing gravity Pu',
          '${_f(math.max(1.4 * d, 1.2 * d + 1.6 * l + lrLike))} kN',
          ref: 'S203.3.1'),
      row('Overturning (E)', 'M = ${_f(_overturn(fxL, hx))} kN-m',
          f: 'sum(Fx h)', ref: 'S208.5.1.5'),
    ]),
  );

  // ---- 7. columns: tributary by nearest-column sampling
  final nc = colBlocks.length;
  final cD = List.filled(nc, 0.0), cL = List.filled(nc, 0.0);
  final cLv = [for (final b in colBlocks) _levelOf(levels, b.bz)];
  void give(int level, Offset at, double dKn, double lKn) {
    // nearest column in plan among those at or below [level]; cascade
    // the same load down the stack of columns beneath it
    var cur = -1;
    var best = double.infinity;
    for (var i = 0; i < nc; i++) {
      if (cLv[i] > level) continue;
      final dd = (Offset(colBlocks[i].x, colBlocks[i].y) - at).distance;
      // equal distance (stacked columns): the HIGHEST one takes the
      // load and the cascade carries it down - picking the lower one
      // would leave the upper column unloaded
      if (dd < best - 1e-6 || (dd < best + 1e-6 && cur >= 0 && cLv[i] > cLv[cur])) {
        best = dd;
        cur = i;
      }
    }
    if (cur < 0) return;
    cD[cur] += dKn;
    cL[cur] += lKn;
    final p0 = Offset(colBlocks[cur].x, colBlocks[cur].y);
    for (var lv = cLv[cur] - 1; lv >= 0; lv--) {
      for (var i = 0; i < nc; i++) {
        if (cLv[i] == lv && (Offset(colBlocks[i].x, colBlocks[i].y) - p0).distance < 0.4) {
          cD[i] += dKn;
          cL[i] += lKn;
          break;
        }
      }
    }
  }

  const ds = 0.25;
  if (nc > 0) {
    for (final f in floors) {
      for (final v in f.$2) {
        final b = v.bounds;
        for (var x = b.$1 + ds / 2; x < b.$3; x += ds) {
          for (var y = b.$2 + ds / 2; y < b.$4; y += ds) {
            final pt = Offset(x, y);
            if (v.contains(pt)) {
              give(f.$1, pt, f.$4 * ds * ds, f.$5 * ds * ds);
            }
          }
        }
      }
    }
    if (roofArea > 0) {
      var rx0 = double.infinity, ry0 = double.infinity;
      var rx1 = -double.infinity, ry1 = -double.infinity;
      for (final w in levels[topK].walls) {
        final b = w.bounds;
        rx0 = math.min(rx0, b.$1);
        ry0 = math.min(ry0, b.$2);
        rx1 = math.max(rx1, b.$3);
        ry1 = math.max(ry1, b.$4);
      }
      for (var x = rx0 + ds / 2; x < rx1; x += ds) {
        for (var y = ry0 + ds / 2; y < ry1; y += ds) {
          give(topK, Offset(x, y), p.roofDl * ds * ds, p.roofLl * ds * ds);
        }
      }
    }
    for (var k = 0; k < levels.length; k++) {
      for (final w in levels[k].walls) {
        final lm = wallKnPerM[w] ?? 0;
        for (var i = 0; i < w.segs; i++) {
          final a = Offset(w.pts[i * 2], w.pts[i * 2 + 1]);
          final c = Offset(w.pts[i * 2 + 2], w.pts[i * 2 + 3]);
          final len = (c - a).distance;
          final n = math.max(1, (len / ds).ceil());
          for (var s = 0; s < n; s++) {
            final pt = a + (c - a) * ((s + 0.5) / n);
            give(k, pt, lm * len / n, 0);
          }
        }
      }
    }
  }

  // column self weight rides the same cascade (an upper column is
  // also carried by the one below it)
  for (var i = 0; i < nc; i++) {
    give(cLv[i], Offset(colBlocks[i].x, colBlocks[i].y), colVolOf(colBlocks[i]) * gc, 0);
  }
  final colRows = <CalcRow>[];
  final ftgRows = <CalcRow>[];
  for (var i = 0; i < nc; i++) {
    final b = colBlocks[i];
    final sec = colSecOf(b);
    final ag = (b.def == 'col-rd' ? math.pi * sec * sec / 4 : sec * sec) * 1e6;
    final cs = columnSched(sec, colHOf(b), round: b.def == 'col-rd');
    final ast = cs.main.count * math.pi * cs.main.diaMm * cs.main.diaMm / 4;
    final dd = cD[i], ll2 = cL[i];
    final pu = math.max(1.4 * dd, 1.2 * dd + 1.6 * ll2);
    final phiPn = 0.80 * 0.65 * (0.85 * p.fc * (ag - ast) + p.fy * ast) / 1000;
    final ratio = phiPn > 0 ? pu / phiPn : 9.9;
    final rho = ast / ag;
    final s = ratio <= 1.0 ? (ratio > 0.9 ? Chk.warn : Chk.ok) : Chk.fail;
    DesignFix? colFix;
    if (s == Chk.fail) {
      // smallest standard step section whose phiPn clears Pu with
      // ~5% margin; the FIX button rescales the block to it
      for (var s2 = sec + 0.05; s2 <= sec + 0.80; s2 += 0.05) {
        final ag2 = (b.def == 'col-rd' ? math.pi * s2 * s2 / 4 : s2 * s2) * 1e6;
        final cs2 = columnSched(s2, colHOf(b), round: b.def == 'col-rd');
        final ast2 = cs2.main.count * math.pi * cs2.main.diaMm * cs2.main.diaMm / 4;
        final phiPn2 =
            0.80 * 0.65 * (0.85 * p.fc * (ag2 - ast2) + p.fy * ast2) / 1000;
        if (pu / phiPn2 <= 0.95) {
          colFix = DesignFix('column', b.id, s2,
              'Enlarge column to ${_f(s2 * 1000, 0)}mm');
          break;
        }
      }
    }
    colRows.add(
      row(
        'C${i + 1}  ${_f(sec * 1000, 0)}mm  ${cs.main.label}  (D=${_f(dd, 1)} L=${_f(ll2, 1)} kN)',
        'Pu ${_f(pu, 1)} / phiPn ${_f(phiPn, 1)} = ${_f(ratio)}',
        f: 'phiPn,max = 0.80x0.65[0.85f\'c(Ag-Ast)+fy Ast], rho = ${_f(rho * 100, 2)}% (1-8%)',
        s: s,
        fix: colFix,
        ref: 'S422.4.2 / S421.2',
      ),
    );
    if (rho < 0.01 || rho > 0.08) {
      colRows.add(row('C${i + 1} steel ratio',
          '${_f(rho * 100, 2)}% outside 1-8%',
          s: Chk.fail, ref: 'S410.6.1'));
    }
  }

  // ---- footings (only the lowest column of a stack bears on soil)
  // a placed ftg-* pad block within 0.4 m counts as the provided
  // footing - its own side/thickness/elevation drive the checks
  Block3d? padOf(Block3d col) {
    Block3d? best;
    var bd = 0.4;
    for (final q in m.blocks) {
      if (!q.def.startsWith('ftg-')) continue;
      final d = (Offset(q.x, q.y) - Offset(col.x, col.y)).distance;
      if (d < bd) {
        bd = d;
        best = q;
      }
    }
    return best;
  }

  double padW(Block3d p) =>
      cadBlock(p.def)!.w * p.sx * p.scale;
  double padT(Block3d p) =>
      cadBlock(p.def)!.height * p.sz * p.scale;

  // pre-pass: which columns are stack-lowest, their service load and
  // the required side - needed so one FIX can build ALL missing
  // footings at each column's own size
  final lowest = <int>[];
  final serOf = <double>[], puOf = <double>[];
  final reqOf = <String, double>{};
  for (var i = 0; i < nc; i++) {
    final b = colBlocks[i];
    final sec = colSecOf(b);
    final dd = cD[i], ll2 = cL[i];
    serOf.add(dd + ll2);
    puOf.add(math.max(1.4 * dd, 1.2 * dd + 1.6 * ll2));
    var stacked = false;
    for (var j = 0; j < nc; j++) {
      if (cLv[j] < cLv[i] &&
          (Offset(colBlocks[j].x, colBlocks[j].y) - Offset(b.x, b.y)).distance <
              0.4) {
        stacked = true;
      }
    }
    if (stacked) continue;
    lowest.add(i);
    final ser = serOf[i], pu = puOf[i];
    double qAt(double s2, double t2) =>
        (ser + s2 * s2 * t2 * gc) / (s2 * s2);
    bool punchOk(double s2, double t2) {
      final dE = (t2 - 0.075 - 0.012) * 1000;
      final bo = 4 * (sec * 1000 + dE);
      final qu = pu / (s2 * s2);
      final vu = pu - qu * math.pow((sec * 1000 + dE) / 1000, 2);
      return vu <= 0.75 * 0.33 * math.sqrt(p.fc) * bo * dE / 1000;
    }

    var s2 = math.max(
        0.6,
        (math.max(
                    math.max(footingFor(sec, b.footW).w,
                        padOf(b) == null ? 0 : padW(padOf(b)!)),
                    math.sqrt(ser * 1.1 / p.qa)) *
                10)
            .ceil() /
            10);
    while ((qAt(s2, math.max(0.25, s2 / 5)) > p.qa ||
            !punchOk(s2, math.max(0.25, s2 / 5))) &&
        s2 < 6.0) {
      s2 += 0.1;
    }
    reqOf[b.id] = s2;
  }
  final missing = {
    for (final i in lowest)
      if (!colBlocks[i].footing && padOf(colBlocks[i]) == null)
        colBlocks[i].id: reqOf[colBlocks[i].id]!,
  };
  // NSCP Table 305-1: min depth below undisturbed grade scales with
  // floors supported - 0.30 m (1 fl), 0.45 m (2 fl), 0.60 m (3+ fl)
  final minDep = [0.30, 0.45, 0.60][levels.length.clamp(1, 3) - 1];
  for (final i in lowest) {
    final b = colBlocks[i];
    final sec = colSecOf(b);
    final ser = serOf[i], pu = puOf[i];
    final wf = footingFor(sec, b.footW);
    final pad = b.footing ? null : padOf(b);
    final aReq = (ser * 1.1) / p.qa; // +10% self-weight allowance
    final sideReq = math.sqrt(aReq);
    final provided = b.footing ? wf.w : (pad == null ? 0.0 : padW(pad));
    final provT = b.footing ? wf.t : (pad == null ? 0.0 : padT(pad));
    final side = provided > 0 ? provided : (sideReq * 10).ceil() / 10;
    final qNet =
        (ser + side * side * provT * gc) / (side * side);
    final fok = provided == 0
        ? Chk.warn
        : (qNet <= p.qa ? Chk.ok : Chk.fail);
    // punching at the PROVIDED thickness (schedule or pad slab)
    bool punchNow() {
      final dE = (provT - 0.075 - 0.012) * 1000;
      final bo = 4 * (sec * 1000 + dE);
      final qu = pu / (provided * provided);
      final vu = pu - qu * math.pow((sec * 1000 + dE) / 1000, 2);
      return vu <= 0.75 * 0.33 * math.sqrt(p.fc) * bo * dE / 1000;
    }

    DesignFix? ftgFix;
    if (provided == 0) {
      // one click builds EVERY missing footing, each at its own
      // computed size - fixes the "footing only on one side" issue
      final rs = reqOf[b.id]!;
      ftgFix = DesignFix('footing-all', b.id, rs,
          'Add footings under all ${missing.length} column${missing.length == 1 ? '' : 's'} (this one ${_f(rs, 1)}x${_f(rs, 1)} m)',
          values: missing);
    } else if (fok == Chk.fail || !punchNow()) {
      final rs = reqOf[b.id]!;
      ftgFix = pad == null
          ? DesignFix('footing', b.id, rs,
              'Enlarge footing to ${_f(rs, 1)}x${_f(rs, 1)} m')
          : DesignFix('pad', pad.id, rs,
              'Resize pad to ${_f(rs, 1)}x${_f(rs, 1)} m + embed ${_f(minDep)} m',
              values: {'dep': minDep});
    }
    ftgRows.add(
      row(
        provided > 0
            ? 'F${i + 1}  ${_f(provided, 1)}x${_f(provided, 1)}x${_f(provT)} @${_f(b.footing ? footingDepth(b.footD) : provT - pad!.bz)}m deep${pad != null ? ' (pad block)' : ''}  (provided${fok == Chk.fail ? ', need >= ${_f((sideReq * 10).ceil() / 10, 1)} m sq.' : ''})'
            : 'F${i + 1}  no footing set - required min ${_f(math.max(side, footingSched(sec).w), 1)}m sq.',
        'q = ${_f(qNet, 1)} kPa vs qa ${_f(p.qa, 0)}',
        f: 'q = (P + Wf)/A, P = ${_f(ser, 1)} kN service',
        s: fok,
        fix: ftgFix,
        ref: 'S304.2',
      ),
    );
    if (provided > 0) {
      final dEff = (provT - 0.075 - 0.012) * 1000; // mm
      final c = sec * 1000;
      final bo = 4 * (c + dEff);
      final qu = pu / (provided * provided);
      final vu = pu - qu * math.pow((c + dEff) / 1000, 2);
      final phiVc = 0.75 * 0.33 * math.sqrt(p.fc) * bo * dEff / 1000;
      ftgRows.add(
        row(
          'F${i + 1} punching shear',
          'Vu ${_f(vu, 1)} / phiVc ${_f(phiVc, 1)} kN',
          f: 'phiVc = 0.75 x 0.33 sqrt(f\'c) bo d, d=${_f(dEff, 0)} mm',
          s: vu <= phiVc ? Chk.ok : Chk.fail,
          fix: vu > phiVc
              ? (pad == null
                  ? DesignFix('footing', b.id, reqOf[b.id]!,
                      'Enlarge footing to clear punching')
                  : DesignFix('pad', pad.id, reqOf[b.id]!,
                      'Resize pad to clear punching',
                      values: {'dep': minDep}))
              : null,
          ref: 'S422.6 / S421.2',
        ),
      );
      // embedment depth - NSCP 305.1 / Table 305-1: footing base
      // below undisturbed grade, scaled by floors supported
      final dep = b.footing ? footingDepth(b.footD) : provT - pad!.bz;
      ftgRows.add(
        row(
          'F${i + 1} embedment depth',
          '${_f(dep)} m vs min ${_f(minDep)} m',
          f: 'Table 305-1: ${_f(minDep)} m for ${levels.length.clamp(1, 3)} floor(s); bearing + scour',
          s: dep >= minDep - 1e-9 ? Chk.ok : Chk.warn,
          fix: dep < minDep - 1e-9
              ? (pad == null
                  ? DesignFix('footing-depth', b.id, minDep,
                      'Set embedment to ${_f(minDep)} m')
                  : DesignFix('pad', pad.id, provided,
                      'Embed pad to ${_f(minDep)} m',
                      values: {'dep': minDep}))
              : null,
          ref: 'S305.1 Table 305-1',
        ),
      );
    }
  }
  if (nc == 0) {
    colRows.add(row('No columns placed', 'Add column blocks (Site > Column) to check supports', s: Chk.info));
  }
  out.add(CalcSection('7. COLUMNS (NSCP S410) - tributary Pu', colRows));
  if (ftgRows.isNotEmpty) {
    out.add(CalcSection('8. FOOTINGS (NSCP S413 / NBCP)', ftgRows));
  }

  // ---- 9. beams
  final bmRows = <CalcRow>[];
  final topDl = hasTopSlab
      ? floors.firstWhere((f) => f.$1 == topK).$4
      : p.roofDl;
  for (final w in m.walls) {
    if (!w.tieBeam && !w.bondBeam) continue;
    final bs = beamSched(w.thickness, 0.20, w.length);
    final dEff = (0.20 - 0.065) * 1000;
    final bw = w.thickness * 1000;
    final as = 2 * math.pi * bs.main.diaMm * bs.main.diaMm / 4;
    final a = as * p.fy / (0.85 * p.fc * bw);
    final phiMn = 0.9 * as * p.fy * (dEff - a / 2) / 1e6;
    final selfW = w.thickness * 0.20 * gc;
    final span = math.min(w.length, 4.0);
    final av = 2 * math.pi * 10 * 10 / 4;
    final vs = av * p.fy * dEff / (bs.tieSpacing * 1000) / 1000;
    final phiVn = 0.75 * (0.17 * math.sqrt(p.fc) * bw * dEff / 1000 + vs);
    for (final tie in [true, false]) {
      if (tie ? !w.tieBeam : !w.bondBeam) continue;
      // tie beam: wall above, masonry arching limits the load height
      // to span/2; bond beam: 0.5 m edge strip of roof/top slab
      final loadH = math.min(w.height, span / 2);
      final wallW = tie ? chbKpa(w.thickness) * loadH : 0.0;
      final stripD = tie ? 0.0 : topDl * 0.5;
      final stripL = tie ? 0.0 : p.roofLl * 0.5;
      final wu = 1.2 * (selfW + wallW + stripD) + 1.6 * stripL;
      final mu = wu * span * span / 8;
      final vu = wu * span / 2;
      final nm = '${w.name} ${tie ? 'tie' : 'bond'} beam  ${_f(w.thickness * 1000, 0)}x200  ${bs.main.label}';
      bmRows.add(
        row(
          nm,
          'Mu ${_f(mu, 2)} / phiMn ${_f(phiMn, 2)} kN-m',
          f: 'wu = ${_f(wu, 2)} kN/m over ${_f(span)} m (${tie ? 'wall load height min(H, L/2) = ${_f(loadH)} m' : '0.5 m edge strip of roof'})',
          s: mu <= phiMn ? Chk.ok : Chk.fail,
          ref: 'S409.5 / S422.3',
        ),
      );
      bmRows.add(
        row(
          '$nm - shear',
          'Vu ${_f(vu, 2)} / phiVn ${_f(phiVn, 2)} kN',
          f: 'phiVn = 0.75(Vc + Vs), 10mm stirrups @ ${_f(bs.tieSpacing * 100, 0)} cm',
          s: vu <= phiVn ? Chk.ok : Chk.fail,
          ref: 'S422.5',
        ),
      );
    }
  }
  if (bmRows.isNotEmpty) out.add(CalcSection('9. WALL BEAMS (NSCP S409)', bmRows));

  // ---- 10. slabs
  final slRows = <CalcRow>[];
  for (final v in m.volumes) {
    if (v.height > 0.5) continue;
    final bb = v.bounds;
    final bboxL = math.max(bb.$3 - bb.$1, bb.$4 - bb.$2);
    final bboxS = math.max(math.min(bb.$3 - bb.$1, bb.$4 - bb.$2), 1e-6);
    final pn = slabPanel(m, v);
    final long = pn.$1, short = pn.$2;
    final t = slabType(long, short);
    final minT = slabMinThk(t, short);
    final grade = onGrade.contains(v);
    if (v.area < 0.95 * bboxL * bboxS) {
      slRows.add(
        row(
          '${v.name} is not rectangular (${_f(v.area / (bboxL * bboxS) * 100, 0)}% of its bounding box)',
          'spans taken from the ${_f(long, 1)}x${_f(short, 1)} m column grid / box',
          f: 'split L/T/U slabs into rectangular panels for an exact span check',
          s: Chk.warn,
        ),
      );
    }
    final sup = grade
        ? 'on grade'
        : t == SlabType.oneWay
            ? 'ONE-WAY'
            : 'TWO-WAY';
    final thin = !grade && v.height + 1e-3 < minT;
    final tFix =
        (minT * 1000 / 5).ceil() * 5 / 1000; // next 5mm step >= minT
    slRows.add(
      row(
        '${v.name} panel ${_f(long, 1)}x${_f(short, 1)} m  $sup (${_f(long / short, 1)}:1)',
        't = ${_f(v.height * 1000, 0)} mm vs min ${_f(minT * 1000, 0)} mm',
        f: t == SlabType.oneWay ? 'L/28 (both ends continuous), >=75mm' : '>=125mm without drop panels',
        s: grade ? Chk.info : (thin ? Chk.fail : Chk.ok),
        ref: t == SlabType.oneWay ? 'Table 407.3.1.1' : 'S408.3.1.1',
        fix: thin
            ? DesignFix('slab', v.id, tFix,
                'Set slab thickness to ${(tFix * 1000).round()}mm')
            : null,
      ),
    );
    if (grade) continue;
    final fl = floors.firstWhere((f) => f.$2.contains(v));
    final wu = 1.2 * fl.$4 + 1.6 * fl.$5; // kPa
    final dEff = (v.height - 0.02 - 0.005) * 1000;
    final mu = t == SlabType.oneWay
        ? wu * short * short / 10
        : 0.57 * wu * short * short / 8;
    double phiMn(double spacingMm) {
      final asBar = 1000 / spacingMm * math.pi * 10 * 10 / 4;
      final aa = asBar * p.fy / (0.85 * p.fc * 1000);
      return 0.9 * asBar * p.fy * (dEff - aa / 2) / 1e6;
    }

    double? need;
    for (final sp in [200.0, 150.0, 125.0, 100.0]) {
      if (mu <= phiMn(sp)) {
        need = sp;
        break;
      }
    }
    final st = need == null
        ? Chk.fail
        : (need == 200 ? Chk.ok : Chk.warn);
    slRows.add(
      row(
        '${v.name} strip moment (1 m width)',
        need == null
            ? 'Mu ${_f(mu, 2)} > phiMn ${_f(phiMn(100), 2)} even at 10mm@100 - thicken slab'
            : 'Mu ${_f(mu, 2)} / phiMn ${_f(phiMn(need), 2)} kN-m  (10mm@${need.round()})',
        f: 'wu = 1.2D+1.6L = ${_f(wu)} kPa; ${t == SlabType.oneWay ? 'Mu = wu L^2/10' : 'direct design: Mu+ = 0.57 wu Ls^2/8 (end span)'}'
            '${need != null && need != 200 ? '; BOQ steel assumes 10mm@200 - increase mesh' : ''}',
        s: st,
        ref: t == SlabType.oneWay ? 'S407' : 'S408.10',
      ),
    );
  }
  if (slRows.isNotEmpty) out.add(CalcSection('10. SLABS (NSCP S407 / S408)', slRows));

  // ---- 11. CHB walls (practice checks)
  final wlRows = <CalcRow>[];
  for (final w in m.walls) {
    if (w.thickness < 0.01) continue;
    final ht = w.height / w.thickness;
    final needs = w.length > 4.0 && !w.bondBeam && colBlocks.isEmpty;
    wlRows.add(
      row(
        '${w.name}  ${_f(w.thickness * 1000, 0)}mm x ${_f(w.height)} m  L=${_f(w.length)} m',
        'h/t = ${_f(ht, 1)}${ht > 25 ? '  > 25' : ''}',
        f: 'practice limit h/t <= 25; stiffener column every <= 4.0 m',
        s: ht > 25 || needs ? Chk.warn : Chk.ok,
        ref: 'Ch.7 S706',
      ),
    );
  }
  if (wlRows.isNotEmpty) out.add(CalcSection('11. CHB WALLS (practice checks)', wlRows));

  out.add(
    CalcSection('SUMMARY', [
      row('Checks passed', '$nOk'),
      row('Warnings', '$nWarn', s: Chk.info),
      row('Failures', '$nFail', s: Chk.info),
      row(
        'Disclaimer',
        'PRELIMINARY equivalent-static calculation. Not a substitute for a '
            'sealed design by a licensed civil/structural engineer (RA 544).',
      ),
    ]),
  );
  return CalcReport(
    out,
    w: wTot,
    v: vBase,
    t: tPer,
    ft: ftTop,
    windX: windX,
    windY: windY,
    storeyForces: fxL,
    ok: nOk,
    warn: nWarn,
    fail: nFail,
  );
}

double _overturn(List<double> fx, List<double> hx) {
  var s = 0.0;
  for (var i = 0; i < fx.length; i++) {
    s += fx[i] * hx[i];
  }
  return s;
}

int _levelOf(List<_Level> levels, double z) {
  var best = 0;
  var d = double.infinity;
  for (var i = 0; i < levels.length; i++) {
    final x = (levels[i].base - z).abs();
    if (x < d) {
      d = x;
      best = i;
    }
  }
  return best;
}
