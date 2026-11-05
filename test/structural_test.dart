import 'package:flutter_test/flutter_test.dart';
import 'package:tantyahin/model3d.dart';
import 'package:tantyahin/structural.dart';
import 'package:tantyahin/takeoff.dart';

void main() {
  test('column sched: NSCP 410 1% min steel, 4+ bars, code ties', () {
    // 0.20 sq col: Ag=40000 → 1%=400mm²; 4-16mm=804 ≥ 400
    final s20 = columnSched(0.20, 3.0);
    expect(s20.main.count, 4);
    expect(s20.main.diaMm, 16);
    // ties: min(16×16, 48×10, 200mm) = 200mm → 0.20m spacing
    expect(s20.tieSpacing, closeTo(0.20, 1e-9));

    // 0.30 sq col: 1%=900 > 4-16=804 → bumps to 4-20mm=1257
    final s30 = columnSched(0.30, 3.0);
    expect(s30.main.count, 4);
    expect(s30.main.diaMm, 20);
    final ast = 4 * 3.14159 * 20 * 20 / 4;
    expect(ast / (300 * 300), greaterThanOrEqualTo(0.01));

    // 0.50 sq col: needs more than 4 bars or bigger dia — any
    // valid schedule must satisfy rho >= 1% and n >= 4
    final s50 = columnSched(0.50, 3.0);
    final a50 =
        s50.main.count * 3.14159 * s50.main.diaMm * s50.main.diaMm / 4;
    expect(a50 / (500 * 500), greaterThanOrEqualTo(0.01));
    expect(s50.main.count, greaterThanOrEqualTo(4));
  });

  test('beam sched: span picks bar dia, stirrups min(d/2,0.20)', () {
    final short = beamSched(0.20, 0.20, 2.5);
    expect(short.main.diaMm, 12);
    expect(short.main.count, 4);
    final long = beamSched(0.20, 0.40, 5.0);
    expect(long.main.diaMm, 20);
    // d = 0.40-0.065 = 0.335 → min(0.1675, 0.20) = 0.1675
    expect(long.tieSpacing, closeTo(0.335 / 2, 1e-3));
  });

  test('footing sched: 5× column side, NBCP 0.25 min thickness', () {
    final f20 = footingSched(0.20);
    expect(f20.w, 1.0); // 5×0.20 = 1.0
    expect(f20.t, 0.25); // max(0.25, 1.0/5)
    expect(f20.bars.diaMm, 12);
    final f30 = footingSched(0.30);
    expect(f30.w, 1.5); // 5×0.30
    expect(f30.t, 0.30); // 1.5/5
    // mat bars both ways at ~0.20 spacing, ≥6 each direction
    expect(f30.bars.count, greaterThanOrEqualTo(12));
  });

  test('slab classification + NSCP min thickness', () {
    expect(slabType(7, 3), SlabType.oneWay); // 2.33:1
    expect(slabType(6, 5), SlabType.twoWay); // 1.2:1
    expect(slabType(6, 3), SlabType.oneWay); // exactly 2.0
    // one-way: L/28 both-continuous, 75mm floor
    expect(slabMinThk(SlabType.oneWay, 3), closeTo(3 / 28, 1e-9));
    expect(slabMinThk(SlabType.oneWay, 1), 0.075);
    // two-way: 125mm without drop panels
    expect(slabMinThk(SlabType.twoWay, 4), 0.125);
    // two-way mesh = 10mm @ 0.20 BOTH ways
    final s = slabSched(SlabType.twoWay, 5, 4);
    expect(s.every((b) => b.diaMm == 10), isTrue);
    expect(s[0].count, (4 / 0.20).ceil() + 1);
    expect(s[1].count, (5 / 0.20).ceil() + 1);
  });

  test('takeoff measures footings, wall beams, slab types', () {
    final m = Model3d()
      ..walls.add(Wall3d(
        points: [0, 0, 6, 0],
        thickness: 0.15,
        tieBeam: true,
        bondBeam: true,
      ))
      ..blocks.add(Block3d(def: 'col-sq', x: 0, y: 0, footing: true))
      ..blocks.add(Block3d(def: 'col-sq', x: 6, y: 0))
      ..volumes
          .add(Volume3d(footprint: [0, 0, 8, 0, 8, 3, 0, 3], height: 0.10));
    final t = modelTakeoff(m);
    expect(t.footCount, 1);
    // col-sq 0.3 → footing 1.5×1.5×0.30 = 0.675 cu.m + 0.30×0.30
    // pedestal stem to the default 0.60 m embedment depth
    expect(t.footVol,
        closeTo(1.5 * 1.5 * 0.30 + 0.3 * 0.3 * (0.60 - 0.30), 1e-9));
    expect(t.footW, 1.5);
    expect(t.tieLen, closeTo(6, 1e-9));
    expect(t.bondLen, closeTo(6, 1e-9));
    // 6m × 0.15 thk × 0.20 deep × 2 beams
    expect(t.beamVol, closeTo(6 * 0.15 * 0.20 * 2, 1e-9));
    // concreteVol = slab + columns + footing + beams
    expect(
      t.concreteVol,
      closeTo(t.slabVol + t.colVol + t.footVol + t.beamVol, 1e-9),
    );
    // 8×3 slab: 2.67:1 → ONE-WAY, min 3/28 ≈ 0.107 > 0.10 actual
    expect(t.slabs.length, 1);
    expect(t.slabs[0].$2, isTrue);
    expect(t.slabs[0].$3, closeTo(3 / 28, 1e-9));
    expect(t.slabs[0].$3 > t.slabs[0].$4, isTrue); // under-thick flag
  });

  test('takeoffSteelSched aggregates kg by diameter + wire', () {
    final m = Model3d()
      ..walls.add(Wall3d(
        points: [0, 0, 6, 0],
        thickness: 0.15,
        tieBeam: true,
      ))
      ..blocks.add(Block3d(def: 'col-sq', x: 0, y: 0, footing: true))
      ..volumes
          .add(Volume3d(footprint: [0, 0, 6, 0, 6, 4, 0, 4], height: 0.10));
    final w = takeoffSteelSched(m)!;
    final lines = w.results.first.lines;
    // col 0.3×3.0 → 4-20mm; beam 6m → 4-20mm... wait span>4.5 → 20mm
    // footing 1.5 → 12mm; slab 6×4 two-way → 10mm
    final byDesc = {for (final l in lines) l.description: l.qty};
    expect(byDesc.keys, containsAll(
        ['Steel bar 10mm', 'Steel bar 12mm', 'Steel bar 20mm']));
    expect(byDesc['Steel bar 20mm'],
        closeTo(4 * 20 * 20 * 3.0 / 162 + 4 * 20 * 20 * 6.0 / 162, 0.5));
    expect(byDesc['Tie Wire #16 25kg/roll'], greaterThan(0));
    expect(w.results.first.notes.any((n) => n.contains('FTG 1.5')), isTrue);
    // schedule notes mention the NSCP members
    expect(w.results.first.notes.any((n) => n.contains('TWO-WAY')), isTrue);
  });
}
