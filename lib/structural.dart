import 'dart:math' as math;

/// NSCP 2015 (7th ed, aligned with ACI 318-14) member schedules for
/// Philippine residential work — the "standard detail" layer behind
/// the 3D model's structural options. All sizes in METERS, bars in
/// MM, output weights in KG (price DB sells rebar by the kilo).
///
/// Sources: NSCP 2015 §407/§408 (slabs), §409 (beams), §410 (columns,
/// ρg 1-8%, ties = min(16db, 48dt, least dim)), NBCP dwelling footing
/// minimums (250mm thick, 600mm below grade), DPWH/typical PH details
/// (CHB stiffener ≤4.0m, tie/bond beam 0.20 deep, 10mm@0.20 stirrups).

/// Philippine commercial bar diameters (mm), stocked 6m lengths.
const kBarDias = [10.0, 12.0, 16.0, 20.0, 25.0];
const kBarLen = 6.0;

/// kg per bar: W = d² × L / 162 (the standard field formula).
double barKg(double diaMm, double lenM) => diaMm * diaMm * lenM / 162;

/// One bar group: [count] bars of [diaMm] × [lenEach].
class BarSched {
  final int count;
  final double diaMm, lenEach;
  const BarSched(this.count, this.diaMm, this.lenEach);
  double get kg => count * barKg(diaMm, lenEach);
  String get label => '$count-${diaMm.round()}mm';
}

/// A member's longitudinal bars plus its transverse steel.
class MemberSched {
  /// main longitudinal bars
  final BarSched main;
  /// ties/stirrups: total pieces of [tie.diaMm]
  final BarSched tie;
  final double tieSpacing; // m
  const MemberSched(this.main, this.tie, this.tieSpacing);
  double get kg => main.kg + tie.kg;
  /// tie wire ~2% of bar weight (the workbook's own convention)
  double get wireKg => kg * 0.02;
}

/// COLUMN — NSCP 410.6: 1% ≤ Ast/Ag ≤ 8%, min 4 bars (tied). Picks the
/// smallest of 16/20/25mm reaching ρ ≥ 1% with 4 bars, else adds bars.
/// Ties (410.7): 10mm @ min(16·db, 48·10, least dim) — then capped at
/// 0.20 for the usual PH detail spacing.
MemberSched columnSched(double sec, double hgt, {bool round = false}) {
  final ag = (round ? math.pi * sec * sec / 4 : sec * sec) * 1e6; // mm²
  var n = 4;
  var dia = 16.0;
  for (;;) {
    final ast = n * math.pi * dia * dia / 4;
    if (ast >= 0.01 * ag || n > 20) break;
    final i = kBarDias.indexOf(dia);
    if (i >= 0 && i < kBarDias.length - 1 && dia >= 16) {
      dia = kBarDias[i + 1];
    } else {
      n += 2; // symmetric layout
      dia = 16;
    }
  }
  final s = math.min(
      math.min(16 * dia, 48 * 10.0), sec * 1000); // mm — NSCP 410.7
  final sp = math.min(s / 1000, 0.20); // m — typical detail spacing
  final ties = math.max(2, (hgt / sp).ceil() + 1);
  // tie length ≈ 4 legs of the stirrup perimeter + hooks (~0.30)
  final tieLen = (round ? math.pi : 4) * math.max(sec - 0.08, 0.05) + 0.30;
  return MemberSched(
    BarSched(n, dia, hgt),
    BarSched(ties, 10, tieLen),
    sp,
  );
}

/// BEAM / TIE BEAM / BOND BEAM — main dia by span (PH residential
/// schedules: ≤3m→12mm, ≤4.5m→16mm, longer→20mm), 4 bars (2T+2B) min.
/// Stirrups 10mm @ min(d/2, 0.20) — the conservative end of NSCP
/// 409's min(d/2, 600) rule, matching standard PH detailing.
MemberSched beamSched(double width, double depth, double len) {
  final dia = len <= 3 ? 12.0 : (len <= 4.5 ? 16.0 : 20.0);
  final d = math.max(depth - 0.065, 0.05); // effective depth, m
  final sp = math.min(d / 2, 0.20);
  final n = math.max(2, (len / sp).ceil() + 1);
  final tieLen = 2 * (width + depth) - 0.16 + 0.30; // legs - cover + hooks
  return MemberSched(
    BarSched(4, dia, len),
    BarSched(n, 10, tieLen),
    sp,
  );
}

/// ISOLATED SQUARE FOOTING — NBCP minimums for dwellings (≥0.25m
/// thick) + typical PH residential schedule: side ≈ 5× column width,
/// min 1.0m; thickness = max(0.25, W/5); mat bars 12mm @ 0.20 both
/// ways (16mm @ 0.15 above 1.5m).
class FootingSched {
  final double w, t; // square side, thickness (m)
  final BarSched bars;
  const FootingSched(this.w, this.t, this.bars);
  double get vol => w * w * t;
}

FootingSched footingSched(double colSec) =>
    footingFor(colSec, (math.max(1.0, colSec * 5) * 10).ceilToDouble() / 10);

/// Footing schedule for a column section with an optional manual side
/// override (`side` <= 0 = auto from the column section). A manual side
/// re-derives thickness and the bar mat so takeoff/render/design all
/// agree.
FootingSched footingFor(double colSec, double side) {
  final w = side > 0 ? side : (math.max(1.0, colSec * 5) * 10).ceilToDouble() / 10;
  final t = math.max(0.25, w / 5);
  final dia = w <= 1.5 ? 12.0 : 16.0;
  final sp = w <= 1.5 ? 0.20 : 0.15;
  final n = ((w - 0.15) / sp).floor() + 1; // 75mm cover each side
  // each bar ≈ W - covers + 2 × 90° hook (~15db)
  final barLen = w - 0.15 + 2 * 15 * dia / 1000;
  return FootingSched(w, t, BarSched(n * 2, dia, barLen));
}

/// Effective footing embedment depth (m): the pad bottom sits this
/// far below the column base. `footD` <= 0 means the standard default
/// 0.60 m below grade (NSCP 2015 305.1 / Table 305-1: footing base
/// below undisturbed grade, 0.60 m where 3+ floors are supported).
double footingDepth(double footD) => footD > 0 ? footD : 0.60;

/// Concrete volume of the pedestal stem between the pad top and the
/// column base (0 when the pad top reaches the base). The stem is a
/// square prism of the column section (>= 0.20 m) — poured with the
/// footing, so it counts as footing concrete.
double footingStemVol(double colSec, double footD, double padT) {
  final h = footingDepth(footD) - padT;
  if (h <= 0) return 0;
  final s = math.max(colSec, 0.20);
  return s * s * h;
}

/// CONTINUOUS WALL FOOTING (strip) — NBCP: ≥3× wall width, ≥0.25m
/// thick; typical 10mm longitudinal + 10mm @ 0.30 transverse.
class StripFootingSched {
  final double w, t;
  final BarSched longBars, transBars;
  const StripFootingSched(this.w, this.t, this.longBars, this.transBars);
  double vol(double len) => w * t * len;
}

StripFootingSched wallFootingSched(double wallThk, double len) {
  final w = math.max(0.40, wallThk * 3);
  const t = 0.25;
  final longN = math.max(3, (w / 0.15).round());
  final transN = (len / 0.30).ceil() + 1;
  return StripFootingSched(
    w,
    t,
    BarSched(longN, 10, len),
    BarSched(transN, 10, w - 0.15 + 0.30),
  );
}

/// SLAB classification — NSCP 406/408: a four-side-supported panel is
/// ONE-WAY when long/short ≥ 2, otherwise TWO-WAY.
enum SlabType { oneWay, twoWay }

SlabType slabType(double long, double short) =>
    long >= 2 * short ? SlabType.oneWay : SlabType.twoWay;

/// NSCP minimum slab thickness: one-way (§407.3, both ends
/// continuous) = L/28 with a 75mm floor; two-way (§408.3.1.1, no drop
/// panels) = 125mm minimum.
double slabMinThk(SlabType t, double shortSpan) =>
    t == SlabType.oneWay ? math.max(shortSpan / 28, 0.075) : 0.125;

/// Slab reinforcement — PH residential detail: 10mm @ 0.20 both ways
/// for two-way; one-way main 10mm @ 0.20 across the short span plus
/// shrinkage bars 10mm @ 0.25 the long way. Returns [main, temp].
List<BarSched> slabSched(SlabType t, double long, double short) {
  if (t == SlabType.twoWay) {
    final nx = (short / 0.20).ceil() + 1;
    final ny = (long / 0.20).ceil() + 1;
    return [
      BarSched(nx, 10, long),
      BarSched(ny, 10, short),
    ];
  }
  final main = (long / 0.20).ceil() + 1;
  final temp = (short / 0.25).ceil() + 1;
  return [
    BarSched(main, 10, short),
    BarSched(temp, 10, long),
  ];
}
