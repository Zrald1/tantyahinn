import 'dart:io';
import 'dart:math' as math;

import 'package:tantyahin/design_calc.dart';
import 'package:tantyahin/excel_export.dart';
import 'package:tantyahin/model3d.dart';
import 'package:tantyahin/models.dart';
import 'package:tantyahin/state.dart';
import 'package:tantyahin/structural.dart';
import 'package:tantyahin/takeoff.dart';
import 'package:flutter_test/flutter_test.dart';

// ---------------------------------------------------------------- helpers
List<double> rectPts(double w, double d) => [0, 0, w, 0, w, d, 0, d, 0, 0];
List<double> rectFp(double w, double d) => [0, 0, w, 0, w, d, 0, d];

double numIn(String s, String key) {
  final m = RegExp('$key=([0-9.]+)').firstMatch(s);
  return double.parse(m!.group(1)!);
}

CalcRow row(CalcReport r, String section, String label) => r.sections
    .firstWhere((s) => s.title.contains(section))
    .rows
    .firstWhere((x) => x.label.contains(label));

double kn(CalcRow r) => double.parse(r.value.split(' ')[0]);

/// every number/NaN-prone string in a report must be finite
void expectFinite(CalcReport r, String tag) {
  for (final s in r.sections) {
    for (final x in s.rows) {
      for (final t in [x.label, x.value, x.formula ?? '']) {
        expect(t.contains('NaN') || t.contains('Infinity'), isFalse,
            reason: '$tag: "${x.label}" -> "$t"');
      }
    }
  }
}

// ----------------------------------------------------- scenario B: L house
Model3d lHouse() => Model3d(name: 'L-house')
  ..walls.add(Wall3d(
      points: [0, 0, 8, 0, 8, 3, 4, 3, 4, 6, 0, 6, 0, 0], thickness: 0.15))
  ..walls.add(Wall3d(points: [0, 3, 4, 3], thickness: 0.10))
  ..volumes.add(Volume3d(
      footprint: [0, 0, 8, 0, 8, 3, 4, 3, 4, 6, 0, 6], height: 0.10))
  ..volumes.add(Volume3d(
      footprint: [0, 0, 8, 0, 8, 3, 4, 3, 4, 6, 0, 6],
      base: 2.7,
      height: 0.125))
  ..blocks.addAll([
    Block3d(def: 'door-090', x: 2, y: 0), // 0.9 x 2.1
    Block3d(def: 'window-120', x: 8, y: 1.5, rot: math.pi / 2), // 1.2x1.2
    Block3d(def: 'door-090', x: 2, y: 3), // interior (0.10 wall)
    Block3d(def: 'window-120', x: 0, y: 4.5, rot: math.pi / 2, scale: 1.5),
    Block3d(def: 'door-090', x: 0.2, y: 0), // overhangs wall end
    Block3d(def: 'door-090', x: 6, y: 1.5), // off any wall
  ]);

// ------------------------------------------ scenario C: 2-storey w/ frame
Model3d twoStorey() {
  final m = Model3d(name: 'Two-storey');
  for (final base in [0.0, 3.1]) {
    m.walls.add(Wall3d(
      points: rectPts(8, 6),
      thickness: 0.15,
      base: base,
      height: 3,
      tieBeam: base == 0,
      bondBeam: base == 0,
    ));
  }
  m.volumes
    ..add(Volume3d(footprint: rectFp(8, 6), height: 0.10))
    ..add(Volume3d(footprint: rectFp(8, 6), base: 3.0, height: 0.125))
    ..add(Volume3d(footprint: rectFp(8, 6), base: 6.1, height: 0.125));
  final pos = [(0.0, 0.0), (8.0, 0.0), (8.0, 6.0), (0.0, 6.0), (4.0, 0.0), (4.0, 6.0)];
  for (final bz in [0.0, 3.1]) {
    for (final c in pos) {
      m.blocks.add(Block3d(
          def: 'col-sq', x: c.$1, y: c.$2, bz: bz, footing: bz == 0));
    }
  }
  m.blocks
    ..add(Block3d(def: 'door-090', x: 2, y: 0))
    ..add(Block3d(def: 'door-090', x: 6, y: 6))
    ..add(Block3d(def: 'window-120', x: 0, y: 3, rot: math.pi / 2))
    ..add(Block3d(def: 'window-120', x: 8, y: 3, rot: math.pi / 2))
    ..add(Block3d(def: 'window-120', x: 6, y: 0))
    ..add(Block3d(def: 'window-120', x: 2, y: 6));
  return m;
}

// --------------------------------- scenario D: 3-storey commercial, round+sq
Model3d commercial() {
  final m = Model3d(name: 'Commercial');
  for (var k = 0; k < 3; k++) {
    final base = k * 3.6;
    m.walls.add(Wall3d(
        points: rectPts(12, 9),
        thickness: 0.20,
        base: base,
        height: 3.5,
        tieBeam: k == 0,
        bondBeam: true));
    m.walls.add(Wall3d(
        points: [6, 0, 6, 9], thickness: 0.10, base: base, height: 3.5));
    m.volumes.add(Volume3d(
        footprint: rectFp(12, 9), base: base == 0 ? 0 : base - 0.1, height: base == 0 ? 0.1 : 0.15));
  }
  m.volumes.add(Volume3d(footprint: rectFp(12, 9), base: 10.9, height: 0.15));
  for (var k = 0; k < 3; k++) {
    for (var i = 0; i < 4; i++) {
      for (var j = 0; j < 3; j++) {
        m.blocks.add(Block3d(
          def: (i + j).isEven ? 'col-sq' : 'col-rd',
          x: i * 4.0,
          y: j * 4.5,
          bz: k * 3.6,
          sx: 0.45 / 0.3,
          sy: 0.45 / 0.3,
          footing: k == 0,
        ));
      }
    }
  }
  return m;
}

void main() {
  // ===================================================== TAKEOFF / BOQ
  group('takeoff accuracy (L-shaped, mixed thickness, scaled/odd openings)', () {
    final t = modelTakeoff(lHouse());

    test('wall length + gross per thickness', () {
      expect(t.wallLen, closeTo(32, 1e-9));
      expect(t.wallsByThk[0.15]!.$1, closeTo(28, 1e-9));
      expect(t.wallsByThk[0.15]!.$2, closeTo(28 * 2.7, 1e-9));
      expect(t.wallsByThk[0.10]!.$2, closeTo(4 * 2.7, 1e-9));
      expect(t.wallGross, closeTo(86.4, 1e-9));
    });

    test('openings: scaled window, wall-end clamp, off-wall ignored', () {
      double apOf(Block3d b) => modelTakeoff(Model3d()
            ..walls.addAll(lHouse().walls)
            ..blocks.add(b))
          .aperture;
      expect(t.doors, 3);
      expect(t.windows, 2);
      expect(apOf(Block3d(def: 'door-090', x: 2, y: 0)), closeTo(1.89, 0.06));
      expect(apOf(Block3d(def: 'window-120', x: 8, y: 1.5, rot: math.pi / 2)),
          closeTo(1.44, 0.01));
      // scale 1.5: width 1.8, sill 1.35, head clipped to wall top 2.7
      expect(
          apOf(Block3d(
              def: 'window-120', x: 0, y: 4.5, rot: math.pi / 2, scale: 1.5)),
          closeTo(1.8 * (2.7 - 1.35), 0.01));
      // a door overhanging the wall end is clipped to the wall
      final end = apOf(Block3d(def: 'door-090', x: 0.2, y: 0));
      expect(end, lessThan(0.8 * 2.1));
      expect(end, greaterThan(0.5 * 2.1));
      expect(apOf(Block3d(def: 'door-090', x: 6, y: 1.5)), 0); // off wall
      expect(t.aperture, closeTo(1.89 + 1.44 + 1.89 + 2.43 + end, 0.2));
    });

    test('roof slab is concrete but NOT floor tile', () {
      expect(t.floorArea, closeTo(36, 1e-9));
      expect(t.slabVol, closeTo(36 * 0.10 + 36 * 0.125, 1e-9));
    });

    test('masonry BOQ lines equal the calculator by hand', () {
      final w = takeoffMasonry(t)!;
      final e = EstimateState();
      insertTakeoffWork(
          w,
          (s, l, items) =>
              e.addWork(sectionTitle: s, groupLabel: l, items: items));
      final lines = e.sections
          .firstWhere((s) => s.title == 'MASONRY WORKS')
          .lines
          .where((l) => l.kind == BoqLineKind.item)
          .toList();
      int chb(String k) => lines
          .firstWhere((l) => l.description.contains(k))
          .qty
          .round();
      final net6 = 75.6 - t.apertureFor(0.15);
      final net4 = 10.8 - t.apertureFor(0.10);
      expect(chb('CHB 6'), (12.5 * net6 * 1.1).ceil());
      expect(chb('CHB 4'), (12.5 * net4 * 1.1).ceil());
    });
  });

  group('wall beams come off the CHB, not off the paint', () {
    test('tie+bond band removed from masonry area only', () {
      final m = Model3d()
        ..walls.add(Wall3d(
            points: [0, 0, 10, 0],
            thickness: 0.15,
            height: 3,
            tieBeam: true,
            bondBeam: true));
      final t = modelTakeoff(m);
      expect(t.wallGross, closeTo(30, 1e-9));
      // 10 m x 0.20 x 2 bands = 4 sq.m of concrete band
      expect(t.masonryGross(0.15), closeTo(26, 1e-9));
      expect(t.masonryNet, closeTo(26, 1e-9));
      expect(t.wallNet, closeTo(30, 1e-9)); // painted face stays whole
      expect(takeoffPainting(t, bothSides: false)!.label, contains('30.00'));
      expect(takeoffMasonry(t)!.label, contains('26.00'));
    });
  });

  group('structural steel + concrete totals (two-storey)', () {
    final m = twoStorey();
    final t = modelTakeoff(m);
    test('concrete = slabs + columns + footings + beams (hand sum)', () {
      final slabs = 48 * (0.10 + 0.125 + 0.125);
      final cols = 12 * 0.3 * 0.3 * 3.0;
      // pads + pedestal stems to the default 0.60 m embedment
      final ftg = 6 * (1.5 * 1.5 * 0.30 + 0.3 * 0.3 * (0.60 - 0.30));
      final beams = 2 * 28 * 0.15 * 0.20;
      expect(t.concreteVol, closeTo(slabs + cols + ftg + beams, 1e-6));
    });
    test('floor tile = ground + 2F slabs only', () {
      expect(t.floorArea, closeTo(96, 1e-9));
    });
    test('steel schedule: kg by dia matches bar-by-bar oracle', () {
      final w = takeoffSteelSched(m)!;
      final byD = {
        for (final l in w.results.first.lines) l.description: l.qty,
      };
      // oracle: 12 columns 4-20mm x 3.0 m  + ties; beams; footings; slabs
      double kg(double d, double len, int n) => n * d * d * len / 162;
      var d20 = 12 * kg(20, 3.0, 4);
      // beams: 28 m wall, span>4.5 -> 4-20mm, tie+bond
      d20 += 2 * kg(20, 28, 4);
      expect(byD['Steel bar 20mm'], closeTo(d20, 0.01));
      // footings 1.5 sq: 12mm both ways, count from schedule
      final f = footingSched(0.3);
      expect(byD['Steel bar 12mm'], closeTo(6 * f.bars.kg, 0.01));
      expect(byD['Steel bar 10mm'], greaterThan(0));
      for (final v in byD.values) {
        expect(v, greaterThan(0));
      }
    });
  });

  // ===================================================== DESIGN CALC
  group('design calc: independent oracle on the two-storey frame', () {
    final m = twoStorey();
    final p = DesignParams(qa: 150);
    final r = designCalc(m, p);
    final t = modelTakeoff(m);

    test('seismic weight W matches a bar-by-bar hand sum', () {
      const gc = 24.0;
      final kpa = 15.3 * 0.15 + 0.48;
      final l1Wall = kpa * (84 - 28 * 0.4 - t.apertureFor(0.15)); // ground
      final l2Wall = kpa * 84;
      final beams = 2 * 28 * 0.15 * 0.20 * gc;
      final cols = 12 * 0.27 * gc;
      final slab = 48 * (0.125 * gc + 1.1 + 0.24 + 0.75);
      final w = l1Wall + l2Wall + beams + cols + 2 * slab;
      expect(r.w, closeTo(w, 0.5));
    });

    test('Fx levels sum to V; overturning = sum(Fx h)', () {
      expect(r.storeyForces.reduce((a, b) => a + b), closeTo(r.v, 1e-6));
      expect(r.storeyForces.length, 2);
    });

    test('LOAD CONSERVATION: ground columns carry the whole structure', () {
      final rows = r.sections
          .firstWhere((s) => s.title.contains('COLUMNS'))
          .rows
          .where((x) => RegExp(r'^C\d+ ').hasMatch(x.label))
          .toList();
      expect(rows.length, 12);
      var sumD = 0.0, sumL = 0.0;
      // first six blocks are the ground-level columns
      for (final x in rows.take(6)) {
        sumD += numIn(x.label, 'D');
        sumL += numIn(x.label, 'L');
      }
      final totD = kn(row(r, 'DEAD', 'TOTAL DEAD LOAD'));
      final totL = kn(row(r, 'LIVE', 'TOTAL LIVE LOAD'));
      expect(sumD, closeTo(totD, 0.8));
      expect(sumL, closeTo(totL, 0.8));
    });

    test('upper columns carry less than the ground columns below', () {
      final rows = r.sections
          .firstWhere((s) => s.title.contains('COLUMNS'))
          .rows
          .where((x) => RegExp(r'^C\d+ ').hasMatch(x.label))
          .toList();
      for (var i = 0; i < 6; i++) {
        expect(numIn(rows[i].label, 'D'),
            greaterThan(numIn(rows[i + 6].label, 'D')));
      }
      // upper column must carry the roof strip + upper walls, not ~0
      expect(numIn(rows[6].label, 'D'), greaterThan(40));
    });

    test('report finite + clean for a normal building', () {
      expectFinite(r, 'twoStorey');
      expect(r.fail, 0, reason: 'a 0.3 sq frame with 125mm slabs is ok');
    });
  });

  group('design calc: commercial 3-storey with round + square columns', () {
    final m = commercial();
    final p = DesignParams(occ: 2, soil: 'SC');
    final r = designCalc(m, p);
    test('conserves loads onto ground columns', () {
      final rows = r.sections
          .firstWhere((s) => s.title.contains('COLUMNS'))
          .rows
          .where((x) => RegExp(r'^C\d+ ').hasMatch(x.label))
          .toList();
      expect(rows.length, 36);
      var sumD = 0.0;
      for (final x in rows.take(12)) {
        sumD += numIn(x.label, 'D');
      }
      expect(sumD, closeTo(kn(row(r, 'DEAD', 'TOTAL DEAD LOAD')), 1.5));
    });
    test('seismic chain is internally consistent', () {
      expect(r.storeyForces.reduce((a, b) => a + b), closeTo(r.v, 1e-6));
      expect(r.v, greaterThan(0.11 * 0.4 * r.w * 0.99));
      expect(r.t, closeTo(0.0731 * math.pow(14.4 - 0.0, 0.75), 0.5));
    });
    test('finite everywhere', () => expectFinite(r, 'commercial'));
    test('round column uses pi d^2/4 for Ag', () {
      // C2 is (i=0,j=1): round, 450 mm -> Ag = 159043 mm2 -> rho check
      final c2 = row(r, 'COLUMNS', 'C2 ');
      expect(c2.label, contains('450mm'));
      expect(c2.formula, contains('rho'));
    });
  });

  // ===================================================== DEGENERATE
  group('degenerate models never crash or emit NaN/Infinity', () {
    final cases = <String, Model3d>{
      'empty': Model3d(),
      'only blocks': Model3d()..blocks.add(Block3d(def: 'col-sq', x: 1, y: 1)),
      'only volume mass': Model3d()
        ..volumes.add(Volume3d(footprint: rectFp(5, 5), height: 3)),
      'only thin slab': Model3d()
        ..volumes.add(Volume3d(footprint: rectFp(5, 5), height: 0.1)),
      'zero-length wall': Model3d()
        ..walls.add(Wall3d(points: [1, 1, 1, 1])),
      'single-point wall': Model3d()..walls.add(Wall3d(points: [1, 1])),
      'zero-thickness wall': Model3d()
        ..walls.add(Wall3d(points: [0, 0, 5, 0], thickness: 0)),
      'wall w/ beams zero length': Model3d()
        ..walls.add(Wall3d(
            points: [2, 2, 2, 2], tieBeam: true, bondBeam: true)),
      'columns without slab or wall': Model3d()
        ..blocks.addAll([
          Block3d(def: 'col-sq', x: 0, y: 0, footing: true),
          Block3d(def: 'col-rd', x: 5, y: 0, footing: true),
        ]),
      'opening with no wall': Model3d()
        ..blocks.add(Block3d(def: 'door-090', x: 0, y: 0)),
      'huge slab, tiny column': Model3d()
        ..volumes.add(Volume3d(footprint: rectFp(40, 40), base: 3, height: 0.2))
        ..blocks.add(Block3d(def: 'col-sq', x: 0, y: 0, sx: 0.5, sy: 0.5)),
    };
    for (final e in cases.entries) {
      test(e.key, () {
        final t = modelTakeoff(e.value);
        expect(t.wallNet.isFinite && t.masonryNet.isFinite, isTrue);
        expect(t.concreteVol.isFinite, isTrue);
        for (final w in [
          takeoffMasonry(t),
          takeoffPainting(t),
          takeoffConcrete(t),
          takeoffTiles(t),
          takeoffSteelSched(e.value),
        ]) {
          if (w == null) continue;
          for (final res in w.results) {
            for (final l in res.lines) {
              expect(l.qty.isFinite && l.qty >= 0, isTrue,
                  reason: '${e.key}: ${l.description} ${l.qty}');
            }
          }
        }
        for (final zone in [2, 4]) {
          for (final soil in kSoils) {
            final r = designCalc(e.value, DesignParams(zone: zone, soil: soil));
            expectFinite(r, '${e.key} z$zone $soil');
          }
        }
      });
    }
  });

  // ===================================================== RANDOM FUZZ
  group('random project fuzz (60 seeds)', () {
    test('invariants hold on random buildings', () {
      final rnd = math.Random(7);
      for (var seed = 0; seed < 60; seed++) {
        final w = 4.0 + rnd.nextInt(10);
        final d = 3.0 + rnd.nextInt(8);
        final storeys = 1 + rnd.nextInt(3);
        final thk = [0.10, 0.15, 0.20][rnd.nextInt(3)];
        final m = Model3d(name: 'R$seed');
        for (var k = 0; k < storeys; k++) {
          final base = k * 3.1;
          m.walls.add(Wall3d(
            points: rectPts(w, d),
            thickness: thk,
            base: base,
            height: 3.0,
            tieBeam: rnd.nextBool(),
            bondBeam: rnd.nextBool(),
          ));
          if (rnd.nextBool()) {
            m.walls.add(Wall3d(
                points: [w / 2, 0, w / 2, d], base: base, height: 3.0, thickness: 0.10));
          }
          m.volumes.add(Volume3d(
              footprint: rectFp(w, d),
              base: k == 0 ? 0 : base - 0.1,
              height: k == 0 ? 0.1 : 0.125));
          for (final c in [(0.0, 0.0), (w, 0.0), (w, d), (0.0, d)]) {
            m.blocks.add(Block3d(
                def: rnd.nextBool() ? 'col-sq' : 'col-rd',
                x: c.$1,
                y: c.$2,
                bz: base,
                footing: k == 0 && rnd.nextBool()));
          }
          for (var o = 0; o < rnd.nextInt(5); o++) {
            m.blocks.add(Block3d(
                def: rnd.nextBool() ? 'door-090' : 'window-120',
                x: 1 + rnd.nextInt(w.toInt() - 1).toDouble(),
                y: 0));
          }
        }
        m.volumes.add(
            Volume3d(footprint: rectFp(w, d), base: storeys * 3.1 - 0.1, height: 0.125));

        final t = modelTakeoff(m);
        // length bookkeeping
        final byLen = t.wallsByThk.values.fold(0.0, (a, b) => a + b.$1);
        expect(byLen, closeTo(t.wallLen, 1e-9), reason: 'seed $seed');
        expect(t.masonryNet, lessThanOrEqualTo(t.wallNet + 1e-9));
        expect(t.masonryNet, greaterThanOrEqualTo(0));
        expect(t.aperture, lessThanOrEqualTo(t.wallGross));
        expect(t.concreteVol,
            closeTo(t.slabVol + t.colVol + t.footVol + t.beamVol, 1e-9));
        // floor tiles never exceed the storeys' slab-on-level area
        expect(t.floorArea, lessThanOrEqualTo(w * d * storeys + 1e-9));
        final r = designCalc(m, DesignParams());
        expectFinite(r, 'seed $seed');
        expect(r.storeyForces.reduce((a, b) => a + b), closeTo(r.v, 1e-6),
            reason: 'seed $seed');
        expect(r.v, greaterThan(0));
        // full conservation: every level has stacked columns
        final cols = r.sections
            .firstWhere((s) => s.title.contains('COLUMNS'))
            .rows
            .where((x) => RegExp(r'^C\d+ ').hasMatch(x.label))
            .toList();
        expect(cols.length, 4 * storeys, reason: 'seed $seed');
        var sumD = 0.0;
        for (final x in cols.take(4)) {
          sumD += numIn(x.label, 'D');
        }
        final tot = kn(row(r, 'DEAD', 'TOTAL DEAD LOAD'));
        expect(sumD, closeTo(tot, 0.6 + tot * 0.0005 * 4),
            reason: 'seed $seed: ground columns must carry everything');
      }
    });
  });

  // ===================================================== E2E BOQ + XLSX
  test('E2E complex project -> Add-all BOQ priced -> xlsx workbook', () async {
    final e = EstimateState();
    final m = commercial();
    final t = modelTakeoff(m);
    for (final w in [
      takeoffConcrete(t),
      takeoffMasonry(t),
      takeoffTiles(t),
      takeoffPainting(t),
      takeoffSteelSched(m),
    ]) {
      insertTakeoffWork(
          w!,
          (s, l, items) =>
              e.addWork(sectionTitle: s, groupLabel: l, items: items));
    }
    final items = [
      for (final s in e.sections)
        for (final l in s.lines)
          if (l.kind == BoqLineKind.item) l,
    ];
    expect(items.length, greaterThan(20));
    for (final l in items) {
      expect(l.qty, greaterThan(0), reason: l.description);
      expect(l.materialCost, greaterThan(0),
          reason: 'unpriced line: ${l.description}');
    }
    final bytes = (await ExcelExport(e).build())!;
    final f = File('${Directory.systemTemp.path}/campaign_boq.xlsx');
    f.writeAsBytesSync(bytes);
    expect(bytes.length, greaterThan(8000));
    // ignore: avoid_print
    print('CAMPAIGN items=${items.length} xlsx=${f.path}');
  });
}
