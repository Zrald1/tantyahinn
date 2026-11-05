import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

import 'package:tantyahin/model3d.dart';
import 'package:tantyahin/state.dart';
import 'package:tantyahin/takeoff.dart';

void main() {
  Model3d boxModel() {
    final m = Model3d(name: 'H');
    // two parallel bearing walls 4m apart, 2.7m tall, along +X
    m.walls.add(
      Wall3d(points: [0, 0, 5, 0], thickness: .15, height: 2.7),
    );
    m.walls.add(
      Wall3d(points: [0, 4, 5, 4], thickness: .15, height: 2.7),
    );
    return m;
  }

  test('seatTrussOnWalls bears both ends on wall top plates', () {
    final m = boxModel();
    // drop mid-span pointing along +Y (across the two walls)
    final seat = seatTrussOnWalls(
      m,
      const Offset(2.5, 2.0),
      math.pi / 2,
      4.0,
    )!;
    // bz = wall top (base 0 + height 2.7)
    expect(seat.$3, closeTo(2.7 + kTrussSeatLift, 1e-6)); // plate top + chord-half lift
    // span across the walls (rot along +Y/-Y)
    expect(math.cos(seat.$2).abs(), lessThan(0.2));
    // center snaps to the bearing midline
    expect(seat.$1.dy, closeTo(2.0, 0.4));
  });

  test('single wall in reach: span turns perpendicular, seats top',
      () {
    final m = boxModel();
    // near the first wall only, current rot along the wall (+X)
    final seat = seatTrussOnWalls(
      m,
      const Offset(2.5, 0.4),
      0,
      4.0,
      tol: 0.6,
    )!;
    expect(seat.$3, closeTo(2.7 + kTrussSeatLift, 1e-6)); // plate top + chord-half lift
    // span turned perpendicular to the x-running wall
    expect(math.sin(seat.$2).abs(), greaterThan(0.9));
  });

  test('two-axis solve: near-wall hover spans the room, no perch', () {
    final m = boxModel();
    // hover just inside the y=0 wall: only the PERPENDICULAR axis
    // reaches both plates — the multi-axis solve must find it and
    // span the room (2.5,2.0) instead of the old single-rot perch
    // that hung the truss off the nearest plate at (2.5, 0)
    final seat = seatTrussOnWalls(
      m,
      const Offset(2.5, 0.9),
      0,
      4.0,
    )!;
    expect(seat.$1.dx, closeTo(2.5, 1e-6));
    expect(seat.$1.dy, closeTo(2.0, 1e-6)); // room-center span
    expect(seat.$3, closeTo(2.7 + kTrussSeatLift, 1e-6)); // plate top + chord-half lift
    expect(math.sin(seat.$2).abs(), greaterThan(0.9)); // runs N-S
  });

  test('the OTHER axis wins when only it crosses the walls', () {
    final m = boxModel();
    // hover near the east END mid-height: an E-W span can't reach any
    // plate, the N-S axis is the only real option — the ghost must
    // flip to it instead of perching outward past the wall end
    final seat = seatTrussOnWalls(
      m,
      const Offset(4.8, 2.0),
      0, // armed pointing E-W — the wrong axis here
      4.0,
    )!;
    expect(seat.$1.dx, closeTo(4.8, 0.2));
    expect(seat.$1.dy, closeTo(2.0, 1e-6));
    expect(math.sin(seat.$2).abs(), greaterThan(0.9)); // flipped N-S
  });

  Model3d rectModel() {
    final m = Model3d(name: 'R');
    // closed 5m x 4m rectangle drawn as ONE wall polyline — pairing
    // opposite segs of the same Wall3d must work too
    m.walls.add(
      Wall3d(
        points: [0, 0, 5, 0, 5, 4, 0, 4, 0, 0],
        thickness: .15,
        height: 2.7,
      ),
    );
    return m;
  }

  Model3d wideRoom() {
    // the screenshot's room: 6.5 x 5.5 closed wall loop — a 4.0m
    // truss reaches NEITHER wall pair at its design span
    final m = Model3d(name: 'W');
    m.walls.add(
      Wall3d(
        points: [0, 0, 6.5, 0, 6.5, 5.5, 0, 5.5, 0, 0],
        thickness: .15,
        height: 2.7,
      ),
    );
    return m;
  }

  test('out-to-out: a truss shorter than the room still SPANS, fit sx',
      () {
    final m = wideRoom();
    // hover just inside the top wall: the 4m design span can't reach
    // either plate pair (5.5 / 6.5) — the OLD solve perched the truss
    // hanging off the wall. Now the plates dictate the bearing: the
    // seat centers between them and reports the out-to-out distance
    final seat = seatTrussOnWalls(
      m,
      const Offset(2.0, 5.4),
      math.pi / 2,
      4.0,
    )!;
    expect(seat.$4, closeTo(5.5, 1e-6)); // bearing = the 5.5m pair
    expect(seat.$1.dy, closeTo(2.75, 1e-6)); // centered between plates
    expect(math.sin(seat.$2).abs(), greaterThan(0.9)); // runs N-S
    // the caller stretches the truss to cover exactly that bearing
    expect(trussFitSx(1.0, 4.0, seat.$4), closeTo(1.375, 1e-6));
    expect(seat.$3, closeTo(2.7 + kTrussSeatLift, 1e-6)); // chord underside on the wall top
  });

  test('out-to-out: shorter bearing wins; outside hover clamps bay',
      () {
    final m = wideRoom();
    // room-center hover: both axes are real spans — the SHORTER
    // bearing (5.5 N-S) is how trusses actually frame the room
    final seat = seatTrussOnWalls(
      m,
      const Offset(3.25, 2.75),
      0,
      4.0,
    )!;
    expect(seat.$4, closeTo(5.5, 1e-6));
    expect(math.sin(seat.$2).abs(), greaterThan(0.9));
    // hover just EAST of the east wall: the seat slides back to the
    // gable-end bay — ends still in-run on the N-S plates — instead
    // of the old outward-hanging perch
    final edge = seatTrussOnWalls(
      m,
      const Offset(7.5, 2.75),
      math.pi / 2,
      4.0,
    )!;
    expect(edge.$4, closeTo(5.5, 1e-6));
    expect(edge.$1.dx, closeTo(6.5, 1e-6)); // gable-end bay
    expect(edge.$1.dy, closeTo(2.75, 1e-6));
  });

  test('past-end hover slides to the last in-run bay, not a perch', () {
    final m = rectModel();
    // probe 1.5m PAST the east end — the old solve rejected the
    // clamped hits and perched the ghost hanging off the corner; the
    // ridge-slide clamps to the gable-end bay at x=5 instead
    final seat = seatTrussOnWalls(
      m,
      const Offset(6.5, 2.0),
      math.pi / 2,
      4.0,
    )!;
    expect(seat.$1.dx, closeTo(5.0, 1e-6)); // ends sit on the wall ENDS
    expect(seat.$1.dy, closeTo(2.0, 1e-6));
    expect(seat.$3, closeTo(2.7 + kTrussSeatLift, 1e-6)); // plate top + chord-half lift
    expect(math.sin(seat.$2).abs(), greaterThan(0.9)); // runs N-S
  });

  test('armed diagonal cannot skew a span — snaps to a wall axis', () {
    final m = rectModel();
    // a 45° armed rot has no wall family to span across — the solve
    // must land on a real wall-perpendicular axis, not a staggered
    // diagonal between corner projections
    final seat = seatTrussOnWalls(
      m,
      const Offset(2.5, 2.0),
      math.pi / 4,
      4.0,
    )!;
    // both room axes can bear; the 4m N-S span beats the 5m E-W one
    expect(seat.$1.dx, closeTo(2.5, 1e-6));
    expect(seat.$1.dy, closeTo(2.0, 1e-6));
    expect(math.sin(seat.$2).abs(), greaterThan(0.9)); // N-S, not 45°
  });

  test('rect room: the SHORTER bearing axis wins (trusses frame 4m)',
      () {
    final m = rectModel();
    // mid-room hover: E-W spans 5m across x=0/x=5 walls, N-S spans 4m
    // across y=0/y=4 — real trusses run across the short direction
    final seat = seatTrussOnWalls(
      m,
      const Offset(2.5, 2.0),
      0, // armed E-W — but the building frames N-S
      5.2,
    )!;
    expect(math.sin(seat.$2).abs(), greaterThan(0.9)); // flipped N-S
    expect(seat.$1.dx, closeTo(2.5, 1e-6));
    expect(seat.$1.dy, closeTo(2.0, 1e-6));
  });

  test('no walls -> null (free drop fallback stays)', () {
    final m = Model3d(name: 'empty');
    expect(
      seatTrussOnWalls(m, Offset.zero, 0, 4.0),
      isNull,
    );
  });

  test('hover reach: the perpendicular axis finds the room span', () {
    final m = boxModel();
    // probe 1.5m off the y=0 wall: the armed E-W rot can't reach both
    // plates, but the N-S candidate can — the two-axis solve seats the
    // full room span at wall top even at the default reach
    final seat = seatTrussOnWalls(
      m,
      const Offset(2.5, 1.5),
      0,
      3.97,
    );
    expect(seat, isNotNull);
    expect(seat!.$1.dy, closeTo(2.0, 1e-6)); // spanning, not perched
    expect(seat.$3, closeTo(2.7 + kTrussSeatLift, 1e-6)); // plate top + chord-half lift
    expect(math.sin(seat.$2).abs(), greaterThan(0.9));
    // and a wide reach finds the same span — not a junk perch
    final wide = seatTrussOnWalls(
      m,
      const Offset(2.5, 1.5),
      0,
      3.97,
      tol: 2.0,
    );
    expect(wide!.$1.dy, closeTo(2.0, 1e-6));
    expect(wide.$3, closeTo(2.7 + kTrussSeatLift, 1e-6));
  });

  test('corner probe refuses the diagonal seat — perpendicular plates '
      'only', () {
    // L-corner: one end reaches the y=0 wall, the other the x=0 wall.
    // The 45° span passed BOTH >30° tests and widest-pair picked the
    // diagonal — now bearing plates must be parallel, so it falls back
    // to a perpendicular perch on one plate
    final m = Model3d(name: 'L');
    m.walls.addAll([
      Wall3d(points: [0, 0, 5, 0], thickness: .15, height: 2.7),
      Wall3d(points: [0, 0, 0, 4], thickness: .15, height: 2.7),
    ]);
    final seat = seatTrussOnWalls(
      m,
      const Offset(0.7, 0.7),
      -math.pi / 4, // the diagonal span the old pair accepted
      1.4,
      tol: 1.2,
    );
    expect(seat, isNotNull);
    // perched perpendicular on one plate — never the corner diagonal
    final r = seat!.$2;
    final perpX = (math.sin(r - 0)).abs() > 0.9; // ⊥ to the y=0 wall
    final perpY =
        (math.sin(r - math.pi / 2)).abs() > 0.9; // ⊥ to the x=0 wall
    expect(perpX || perpY, isTrue, reason: 'seat rot $r is diagonal');
  });

  test('nearestWallDist measures the plate a probe sits on', () {
    final m = boxModel();
    // a wall-top-plane point mid-room is ~2m from both plates;
    // the probe picks whichever plane lands CLOSEST to a centerline
    expect(
      nearestWallDist(m, const Offset(2.5, 2.0)),
      closeTo(2.0, 1e-6),
    );
    expect(
      nearestWallDist(m, const Offset(2.5, 0.2)),
      closeTo(0.2, 1e-6),
    );
    expect(nearestWallDist(m, const Offset(99, 99)), greaterThan(10));
    expect(nearestWallDist(Model3d(name: 'e'), Offset.zero),
        double.infinity);
  });

  test('trussLocalFaces: parametric web members follow panel count',
      () {
    final f4 = trussLocalFaces(0, 3.97, 0.18, 0.80);
    final f8 = trussLocalFaces(8, 3.97, 0.18, 0.80);
    expect(f8.length, greaterThan(f4.length)); // more bays = more members
    // envelope: span on x, rise on z, depth on y
    var x0 = double.infinity, x1 = -double.infinity, z1 = 0.0;
    for (final f in f4) {
      for (final p in f.v) {
        x0 = math.min(x0, p[0]);
        x1 = math.max(x1, p[0]);
        z1 = math.max(z1, p[2]);
      }
    }
    expect(x1 - x0, closeTo(3.97, 0.15));
    expect(z1, closeTo(0.80, 0.1));
  });

  test('finkNodes: real fink-family layout grows W cells with bays',
      () {
    // researched layout (TRA + span tables): bottom chord split into
    // odd P panels, top into P+1; 4/3=fink, 6/5=double, 8/7=triple —
    // webs zigzag top_i->bot_i and bot_i->top_{i+1} as the letter W.
    // Stretching must therefore multiply W cells, not add verticals.
    final (p4, tops4, bots4) = finkNodes(4, 12.0);
    expect(p4, 3); // '4 over 3' fink
    expect(tops4, hasLength(3)); // quarter-points + apex
    expect(tops4[0], closeTo(-3.0, 1e-9)); // top quarter point -s/2
    expect(tops4[1], closeTo(0.0, 1e-9)); // apex
    expect(bots4, hasLength(2)); // bottom third points
    expect(bots4[0], closeTo(-2.0, 1e-9)); // -s/3
    expect(bots4[1], closeTo(2.0, 1e-9)); // +s/3
    final (p6, tops6, bots6) = finkNodes(6, 12.0);
    expect(p6, 5); // '6 over 5' double fink
    expect(tops6, hasLength(5));
    expect(bots6, hasLength(4));
    final (p8, _, bots8) = finkNodes(8, 12.0);
    expect(p8, 7); // '8 over 7' triple fink
    expect(bots8, hasLength(6));
    // and it keeps stepping odd so a stretched truss still grows
    expect(finkNodes(12, 12.0).$1, 11);
  });

  test('fink webbing: every web is a zigzag member, no verticals',
      () {
    // a real fink has NO vertical webs — stubs run top_i->bot_i and
    // diagonals bot_i->top_{i+1}; each end must sit ON a chord node
    const span = 3.97, rise = 0.80;
    final n = 4;
    final s = span / 2;
    double zt(double x) => rise * (1 - (x / s).abs());
    final (_, tops, bots) = finkNodes(n, span);
    // webs = 2 per bottom node: stub + queen
    // recreate the mesh centerlines and check endpoints land on the
    // node pair (member boxes share the same node math)
    final segs = trussMemberLines(
      Block3d(def: 'truss', x: 0, y: 0, panels: n),
      cadBlock('truss')!,
    );
    // 3 chords + 2 webs per bottom node
    expect(segs.length, 3 + bots.length * 2);
    // every web endpoint touches a node x (top or bottom set incl.
    // supports at +/-s)
    final nodeXs = <double>{
      -s, s,
      ...tops.map((x) => x),
      ...bots.map((x) => x),
    };
    bool onNode(double x) => nodeXs.any((nx) => (x - nx).abs() < 0.02);
    var webs = 0;
    for (final seg in segs.skip(3)) {
      webs++;
      final a = seg[0], b2 = seg[1];
      expect(onNode(a[0]), isTrue, reason: 'web end x=${a[0]}');
      expect(onNode(b2[0]), isTrue, reason: 'web end x=${b2[0]}');
      // one end rides the top chord height, the other sits at z=0
      final hi = math.max(a[2], b2[2]), lo = math.min(a[2], b2[2]);
      final hx = a[2] > b2[2] ? a[0] : b2[0];
      expect(hi, closeTo(zt(hx), 0.12), reason: 'web top on rafter');
      expect(lo, lessThan(0.05), reason: 'web foot on tie beam');
      // and it must be DIAGONAL — a vertical web is not a fink member
      expect((a[0] - b2[0]).abs(), greaterThan(0.05));
    }
    expect(webs, bots.length * 2);
  });

  test('blockFaces routes truss to the parametric mesh', () {
    final def = cadBlock('truss')!;
    final a = Block3d(def: 'truss', x: 0, y: 0, panels: 4);
    final b8 = Block3d(def: 'truss', x: 0, y: 0, panels: 8);
    expect(blockFaces(b8, def).length,
        greaterThan(blockFaces(a, def).length));
  });

  test('roof sheet carries truss symbol + ridge/eave/purlin lines', () {
    final est = EstimateState();
    final m = est.addModel('H');
    m.walls.add(
      Wall3d(points: [0, 0, 5, 0], thickness: .15, height: 2.7),
    );
    m.walls.add(
      Wall3d(points: [0, 4, 5, 4], thickness: .15, height: 2.7),
    );
    m.blocks.add(
      Block3d(
        def: 'truss',
        x: 2.5,
        y: 2.0,
        rot: math.pi / 2,
        bz: 2.7,
      ),
    );
    final roof = projectView(m, SheetView.roof);
    // walls (2 segs) + truss symbol (rect + chord + 3 ticks + 3 diag)
    // + ridge + 2 eaves + >=2 purlins => well above the old walls-only 2
    expect(roof.length, greaterThan(6));
    // ridge line exists along X at y=2.0 (span is +Y => ridge +X)
    final ridge = roof.any(
      (l) =>
          l.length == 2 &&
          (l[0].dy - 2.0).abs() < 0.05 &&
          (l[1].dy - 2.0).abs() < 0.05,
    );
    expect(ridge, isTrue);
  });

  test('gable elevation draws the truss triangle + web verticals', () {
    final est = EstimateState();
    final m = est.addModel('H');
    m.walls.add(
      Wall3d(points: [0, 0, 5, 0], thickness: .15, height: 2.7),
    );
    m.blocks.add(
      Block3d(def: 'truss', x: 2.5, y: 0, rot: 0, bz: 2.7),
    );
    final fr = elevationPrims(m, SheetView.front);
    // triangle rafters + bottom chord + web ticks above the wall top
    final above = fr
        .where((p) => p.$1.every((o) => o.dy > 2.69))
        .toList();
    expect(above.length, greaterThanOrEqualTo(6)); // 3 frame + 3 webs
  });

  test('panels serializes into project JSON', () {
    final b = Block3d(def: 'truss', x: 1, y: 2, panels: 6);
    final back = Block3d.fromJson(b.toJson());
    expect(back.panels, 6);
  });

  test('plan symbol follows panel bays', () {
    final def = cadBlock('truss')!;
    final l4 = blockLines(Block3d(def: 'truss', x: 0, y: 0), def);
    final l8 = blockLines(
      Block3d(def: 'truss', x: 0, y: 0, panels: 8),
      def,
    );
    expect(l8.length, greaterThan(l4.length));
  });

  test('auto bays grow with the stretched span (~1m/bay)', () {
    final def = cadBlock('truss')!;
    final stock = Block3d(def: 'truss', x: 0, y: 0);
    final long = Block3d(def: 'truss', x: 0, y: 0, sx: 2.0);
    // stock 3.97m -> 4 bays; doubled -> 8; clamp caps past 12m
    expect(trussPanelCount(stock, def), 4);
    expect(trussPanelCount(long, def), 8);
    expect(
      trussPanelCount(Block3d(def: 'truss', x: 0, y: 0, sx: 4.0), def),
      12,
    );
    // an explicit count still wins over auto
    expect(
      trussPanelCount(
        Block3d(def: 'truss', x: 0, y: 0, sx: 2.0, panels: 4),
        def,
      ),
      4,
    );
    // the mesh + plan symbol gain members, not just longer ones
    expect(
      blockFaces(long, def).length,
      greaterThan(blockFaces(stock, def).length),
    );
    expect(
      blockLines(long, def).length,
      greaterThan(blockLines(stock, def).length),
    );
  });

  test('ghost/thumb centerlines: one segment per member', () {
    // the wireframe plate ghost drew each member as a doubled pair —
    // trussMemberLines is the single-stick replacement the 3D ghost
    // and the catalog thumb share
    final fink = trussMemberLines(
      Block3d(def: 'truss', x: 0, y: 0),
      cadBlock('truss')!,
    );
    final sgl = trussMemberLines(
      Block3d(def: 'truss-sgl', x: 0, y: 0),
      cadBlock('truss-sgl')!,
    );
    expect(sgl.length, 6); // 3 chords + post + 2 struts
    expect(fink.length, 7); // 3 chords + 4 fink W webs (2 stubs+2 queens)
    // centerlines follow the stretched span's auto bay count too
    final long = trussMemberLines(
      Block3d(def: 'truss', x: 0, y: 0, sx: 2.0),
      cadBlock('truss')!,
    );
    expect(long.length, greaterThan(fink.length));
    // every segment spans a real distance (no degenerate lines)
    for (final seg in sgl) {
      final d = math.sqrt(
        math.pow(seg[1][0] - seg[0][0], 2) +
            math.pow(seg[1][2] - seg[0][2], 2),
      );
      expect(d, greaterThan(0.1));
    }
  });

  group('truss-dbl (user SketchUp model — double mono-pitch)', () {
    test('registered, parametric, and in the truss family', () {
      final def = cadBlock('truss-dbl')!;
      expect(def.name, contains('double'));
      expect(isTrussDef('truss-dbl'), isTrue);
      // same stock envelope as the skp: 3.97 span x 0.18 deep x 0.85
      expect(def.w, closeTo(3.97, 1e-9));
      expect(def.height, closeTo(0.85, 1e-9));
    });

    test('two parallel mono-pitch frames filling the depth', () {
      final fs = trussLocalFaces(4, 3.97, 0.18, 0.85, dbl: true);
      // both plate centers present -> members exist at two y offsets
      var yMin = double.infinity, yMax = -double.infinity;
      for (final f in fs) {
        for (final p in f.v) {
          yMin = math.min(yMin, p[1]);
          yMax = math.max(yMax, p[1]);
        }
      }
      expect(yMax - yMin, greaterThan(0.10)); // frames spread the depth
      // mono-pitch: the top chord's high end sits at +X, its heel at -X
      var zAtPos = 0.0, zAtNeg = 0.0;
      for (final f in fs) {
        for (final p in f.v) {
          if (p[0] > 1.5) zAtPos = math.max(zAtPos, p[2]);
          if (p[0] < -1.5) zAtNeg = math.max(zAtNeg, p[2]);
        }
      }
      expect(zAtPos, closeTo(0.85, 0.08));
      expect(zAtNeg, lessThan(0.35));
      expect(zAtPos, greaterThan(zAtNeg * 2));
    });

    test('memberLines returns BOTH frame centerlines — honest double',
        () {
      final def = cadBlock('truss-dbl')!;
      final dbl = trussMemberLines(
        Block3d(def: 'truss-dbl', x: 0, y: 0),
        def,
      );
      final fink = trussMemberLines(
        Block3d(def: 'truss', x: 0, y: 0),
        cadBlock('truss')!,
      );
      // each member lives on two plates -> roughly 2x the fink count
      expect(dbl.length, greaterThan(fink.length * 1.5));
      // and the two centerlines of a pair sit at different y
      final ys = dbl.map((s) => s[0][1]).toSet();
      expect(ys.length, greaterThan(1));
      // stretch still grows member count (parametric like the rest)
      final long = trussMemberLines(
        Block3d(def: 'truss-dbl', x: 0, y: 0, sx: 2.0),
        def,
      );
      expect(long.length, greaterThan(dbl.length));
    });

    test('takeoff counts the doubled members', () {
      final dbl = trussChordWeb(4, 3.97, 0.85, dbl: true);
      final fink = trussChordWeb(4, 3.97, 0.85);
      expect(dbl.$1, greaterThan(fink.$1 * 1.5)); // chords x2 frames
      expect(dbl.$2, greaterThan(fink.$2));
    });

    test('plan symbol bays + seating stay in the truss family', () {
      final def = cadBlock('truss-dbl')!;
      final l4 = blockLines(Block3d(def: 'truss-dbl', x: 0, y: 0), def);
      final l8 = blockLines(
        Block3d(def: 'truss-dbl', x: 0, y: 0, panels: 8),
        def,
      );
      expect(l8.length, greaterThan(l4.length));
      // seats on parallel walls like every truss
      final m = boxModel();
      final seat = seatTrussOnWalls(
        m,
        const Offset(2.5, 2.0),
        math.pi / 2,
        def.w,
        tol: 2.0,
      );
      expect(seat, isNotNull);
    });
  });

  group('purlin runs connect truss to truss', () {
    Model3d twoWall() {
      final m = Model3d(name: 'H');
      m.walls.add(Wall3d(points: [0, 0, 8, 0], thickness: .15, height: 2.7));
      m.walls.add(Wall3d(points: [0, 4, 8, 4], thickness: .15, height: 2.7));
      return m;
    }

    test('rot jitter + a sparse bay merge into ONE field', () {
      final m = twoWall();
      // hand-placed jitter (adjacent rot buckets) + a wide unplaced bay
      for (final (x, r) in [
        (0.8, math.pi / 2),
        (2.0, math.pi / 2 + 0.08),
        (2.9, math.pi / 2 + 0.14),
        (5.6, math.pi / 2),
      ]) {
        m.blocks.add(Block3d(def: 'truss', x: x, y: 2.0, rot: r, bz: 2.7));
      }
      final fs = roofFields(m);
      expect(fs.length, 1);
      expect(fs.single.count, 4);
      // one continuous purlin set spanning first->last truss
      expect(fs.single.runLen, closeTo(5.8, 0.3));
      for (final run in purlinRuns(m)) {
        var x0 = double.infinity, x1 = -double.infinity;
        for (final f in run) {
          for (final p in f.v) {
            x0 = math.min(x0, p[0]);
            x1 = math.max(x1, p[0]);
          }
        }
        // runs span first truss -> last truss exactly — the old ±0.5
        // extension poked channels past the gable into empty air
        expect(x0, closeTo(0.8, 0.05));
        expect(x1, closeTo(5.6, 0.05));
      }
    });

    test('perpendicular + parallel-wing roofs still split', () {
      final m = twoWall();
      for (final x in [0.8, 2.0]) {
        m.blocks.add(Block3d(def: 'truss', x: x, y: 2.0, rot: math.pi / 2, bz: 2.7));
      }
      // perpendicular truss — a different roof direction
      m.blocks.add(Block3d(def: 'truss', x: 3.4, y: 2.0, rot: 0, bz: 2.7));
      // parallel roof on a different line (its own bearing pair)
      m.blocks.add(Block3d(def: 'truss', x: 0.8, y: 6.5, rot: math.pi / 2, bz: 2.7));
      expect(roofFields(m).length, 3);
    });

    test('elevation split survives the merge', () {
      final m = twoWall();
      m.blocks.add(Block3d(def: 'truss', x: 0.8, y: 2.0, rot: math.pi / 2, bz: 2.7));
      m.blocks.add(Block3d(def: 'truss', x: 2.0, y: 2.0, rot: math.pi / 2, bz: 3.3));
      expect(roofFields(m).length, 2);
    });
  });

  test('RoofSpec auto tables: spacing by sheet, section by span', () {
    final s = RoofSpec();
    expect(s.purlinSpace, closeTo(0.85, 1e-9)); // rib 0.5mm default
    expect(RoofSpec(roofThk: 0.4).purlinSpace, closeTo(0.70, 1e-9));
    expect(RoofSpec(roofProfile: 'corrugated').purlinSpace, closeTo(0.75, 1e-9));
    expect(RoofSpec(roofProfile: 'corrugated', roofThk: 0.4).purlinSpace, closeTo(0.65, 1e-9));
    expect(RoofSpec(roofProfile: 'tile').purlinSpace, closeTo(0.35, 1e-9));
    expect(RoofSpec(purlinSpacing: 1.1).purlinSpace, closeTo(1.1, 1e-9));
    expect(RoofSpec.purlinForSpan(1.5), ('C-75', 1.2));
    expect(RoofSpec.purlinForSpan(4.0), ('C-100', 1.5));
    expect(RoofSpec.purlinForSpan(5.5), ('C-150', 1.5));
    expect(RoofSpec.purlinForSpan(7.0), ('C-200', 2.0));
  });

  Model3d roofModel() {
    final m = boxModel();
    m.blocks.add(
      Block3d(def: 'truss', x: 2.5, y: 2.0, rot: math.pi / 2, bz: 2.7),
    );
    m.blocks.add(
      Block3d(def: 'truss', x: 4.0, y: 2.0, rot: math.pi / 2, bz: 2.7),
    );
    return m;
  }

  test('roofFields groups trusses and measures spacing', () {
    final fields = roofFields(roofModel());
    expect(fields, hasLength(1));
    final f = fields.first;
    expect(f.count, 2);
    expect(f.measuredSpacing, closeTo(1.5, 1e-6));
    // runLen = distance along ridge + 0.5 run-out each side
    expect(f.runLen, closeTo(1.5 + 1.0, 1e-6));
  });

  test('roof plan honors spec purlin spacing + sheet joints', () {
    final m = roofModel();
    final tight = projectView(m, SheetView.roof).length;
    m.roof.purlinSpacing = 3.0; // fewer purlin rows
    final loose = projectView(m, SheetView.roof).length;
    expect(tight, greaterThan(loose));
  });

  test('roofCallouts prints spec + measured quantities', () {
    final m = roofModel();
    final notes = roofCallouts(m);
    expect(notes.length, greaterThanOrEqualTo(4));
    expect(notes[0], contains('Rib-type'));
    expect(notes[1], contains('C-PURLINS'));
    expect(notes[1], contains('0.85'));
    expect(notes[2], contains('TRUSSES: 2'));
    expect(notes[3], contains('SQ.M'));
  });

  test('modelTakeoff + takeoffRoofing measure the roof field', () {
    final m = roofModel();
    final t = modelTakeoff(m);
    expect(t.trusses, 2);
    expect(t.purlinPcs, greaterThan(0));
    expect(t.roofArea, greaterThan(0));
    expect(t.roofLm, greaterThan(0));
    expect(t.tekscrews, greaterThan(0));
    expect(t.trussChordLm, greaterThan(0));
    final w = takeoffRoofing(m, t)!;
    expect(w.results.single.sectionTitle, 'ROOFING WORKS');
    final descs = w.results.single.lines.map((l) => l.description).toList();
    expect(descs.any((d) => d.contains('C-PURLINS')), isTrue);
    expect(descs.any((d) => d.contains('ROOFING')), isTrue);
    expect(descs.any((d) => d.contains('Ridge roll')), isTrue);
    expect(descs.any((d) => d.contains('Tekscrew')), isTrue);
    expect(descs.any((d) => d.contains('Angle bar')), isTrue);
  });

  test('corrugated roofing prices per standard-length sheet', () {
    final m = roofModel();
    m.roof.roofProfile = 'corrugated';
    m.roof.roofThk = 0.4;
    final w = takeoffRoofing(m, modelTakeoff(m))!;
    final sheet = w.results.single.lines
        .firstWhere((l) => l.description.contains('Corrugated'));
    expect(sheet.description, contains('Ga.26'));
    expect(sheet.unit, 'pcs');
    expect(sheet.qty, greaterThan(0));
  });

  test('RoofSpec round-trips through model JSON', () {
    final m = roofModel();
    m.roof.purlinSize = 'C-150';
    m.roof.purlinThk = 2.0;
    m.roof.trussSpacing = 1.8;
    final back = Model3d.fromJson(m.toJson());
    expect(back.roof.purlinSize, 'C-150');
    expect(back.roof.purlinThk, 2.0);
    expect(back.roof.trussSpacing, 1.8);
    expect(back.roof.roofProfile, 'rib');
  });

  test('purlinRuns: one lipped channel per row, seated on top chord',
      () {
    final m = roofModel();
    final runs = purlinRuns(m);
    final f = roofFields(m).single;
    // ridge + 2*bays-2 interior + 2 eave = purlinRows channels
    expect(runs, hasLength(f.purlinRows(m.roof)));
    // every channel = 5 plates x 6 faces (web+flanges+lips)
    expect(runs.every((r) => r.length == 30), isTrue);
    // z envelope: seated on the top chords between bz and bz+rise+t
    var z0 = double.infinity, z1 = -double.infinity;
    for (final r in runs) {
      for (final face in r) {
        for (final p in face.v) {
          z0 = math.min(z0, p[2]);
          z1 = math.max(z1, p[2]);
        }
      }
    }
    // the eave row sits ON the chord edge at heel height — just
    // above the wall plate (the roof sheet, not the steel, is what
    // overhangs); the ridge carries a PAIR flanking the apex half a
    // bay out, so the crest sits just UNDER the apex — a channel
    // straddling o=0 would push z1 over bz+rise
    expect(z0, greaterThan(2.7));
    expect(z0, lessThan(3.0));
    expect(z1, greaterThan(2.7 + f.rise * 0.8));
    expect(z1, lessThan(2.7 + f.rise + 0.15));
    // runs follow the ridge (+X for this rot) spanning u0..u1
    final xspan = runs.first
        .expand((f2) => f2.v)
        .map((p) => p[0])
        .reduce((a, b) => math.max(a, b)) -
        runs.first
            .expand((f2) => f2.v)
            .map((p) => p[0])
            .reduce((a, b) => math.min(a, b));
    // multi-truss runs end AT the gable trusses — the field's ±0.5
    // runLen extension is sheet overhang, not steel
    expect(xspan, closeTo(f.runLen - 1.0, 0.01));
  });

  test('purlinRuns follows spec: tighter spacing = more channels', () {
    final m = roofModel();
    final loose = purlinRuns(m).length;
    m.roof.purlinSpacing = 0.4;
    final tight = purlinRuns(m).length;
    expect(tight, greaterThan(loose));
  });

  test('modelFaces includes purlins + cache invalidates on roof edit',
      () {
    final m = roofModel();
    final withPurlins = modelFaces(m).length;
    final bare = modelFaces(Model3d(name: 'x')).length;
    expect(withPurlins, greaterThan(bare));
    // cachedFaces must rebuild when the spec changes (purlin rows
    // come from the spec, not the hashed block fields)
    m.cachedFaces();
    m.roof.purlinSpacing = 0.4;
    expect(m.cachedFaces().length, greaterThan(withPurlins));
  });

  test('roof plan closes the roof outline with rake edges', () {
    final m = roofModel();
    final roof = projectView(m, SheetView.roof);
    // 3-point gable-edge polyline at each run end: eave->ridge->eave —
    // 2 fields ends x 3 pts; before this the roof outline was open
    final rakes = roof.where(
      (l) => l.length == 3 && (l[0] - l[2]).distance > 3.0,
    );
    expect(rakes, hasLength(2));
  });

  test('gable elevation draws roof band: slopes, ticks, cap, fascia',
      () {
    final m = roofModel(); // span +Y -> left/right are the gable ends
    final fr = elevationPrims(m, SheetView.left);
    // slope-top lines + ridge cap run above the wall top plate
    final high7 = fr.where(
      (p) =>
          p.$2 == 7 &&
          p.$1.length == 2 &&
          p.$1.every((o) => o.dy > 2.6) &&
          p.$1.any((o) => o.dy > 3.5),
    );
    expect(high7.length, greaterThanOrEqualTo(3)); // 2 slopes + cap
    // purlin ticks = band-high aci-8 strokes at row stations
    final ticks = fr.where(
      (p) =>
          p.$2 == 8 &&
          p.$1.length == 2 &&
          p.$1.every((o) => o.dy > 2.5) &&
          (p.$1[0].dy - p.$1[1].dy).abs() > 0.05,
    );
    expect(ticks.length, greaterThanOrEqualTo(6)); // interior+fascia+bottom
  });

  test('eave-side elevation draws the roof silhouette band', () {
    final m = roofModel(); // ridge +X -> front/rear are the eave sides
    final fr = elevationPrims(m, SheetView.front);
    // a 4-pt heavy prim rising from ~tail underside to ridge cap
    final band = fr.where(
      (p) =>
          p.$2 == 7 &&
          p.$1.length == 4 &&
          p.$1.any((o) => o.dy > 3.5) &&
          p.$1.any((o) => o.dy < 2.7),
    );
    expect(band, isNotEmpty);
  });

  test('trussTags numbers members along the ridge; sheet writes them',
      () {
    final est = EstimateState();
    final m = est.addModel('H');
    m.walls.add(
      Wall3d(points: [0, 0, 5, 0], thickness: .15, height: 2.7),
    );
    m.walls.add(
      Wall3d(points: [0, 4, 5, 4], thickness: .15, height: 2.7),
    );
    m.blocks.add(
      Block3d(def: 'truss', x: 2.5, y: 2.0, rot: math.pi / 2, bz: 2.7),
    );
    m.blocks.add(
      Block3d(def: 'truss', x: 4.0, y: 2.0, rot: math.pi / 2, bz: 2.7),
    );
    final tags = trussTags(m);
    expect(tags.values, containsAll(['T1', 'T2']));
    final sheet = buildModelSheet(m, SheetView.roof, project: est.project);
    expect(sheet, contains('T1'));
    expect(sheet, contains('ROOFING:'));
  });

  test('S-102 framing sheet: tags, member notes, spacing dims', () {
    final est = EstimateState();
    final m = est.addModel('H');
    m.walls.add(
      Wall3d(points: [0, 0, 5, 0], thickness: .15, height: 2.7),
    );
    m.walls.add(
      Wall3d(points: [0, 4, 5, 4], thickness: .15, height: 2.7),
    );
    m.blocks.add(
      Block3d(def: 'truss', x: 2.5, y: 2.0, rot: math.pi / 2, bz: 2.7),
    );
    m.blocks.add(
      Block3d(def: 'truss', x: 4.0, y: 2.0, rot: math.pi / 2, bz: 2.7),
    );
    final sheet = buildModelSheet(
      m,
      SheetView.roofFrame,
      project: est.project,
    );
    expect(sheet, contains('ROOF FRAMING PLAN'));
    expect(sheet, contains('S-102'));
    expect(sheet, contains('T1'));
    expect(sheet, contains('L50x50x6'));
    expect(sheet, contains('C-PURLINS'));
    expect(sheet, contains('TEKSCREW'));
    expect(sheet, contains('RA 544'));
    // spacing dim: the 1.5m bay between the two trusses is annotated
    expect(sheet, contains('1.5'));
    // the framing sheet omits the roofing-sheet joint lines the A-102
    // roof plan carries (same fields, joints flag off)
    final frameN = projectView(m, SheetView.roofFrame).length;
    final roofN = projectView(m, SheetView.roof).length;
    expect(frameN, lessThan(roofN));
  });

  test('roofFields splits distant same-rot trusses into two fields',
      () {
    final m = boxModel();
    // two truss clusters 6m apart along the ridge — one roof each,
    // never a merged field whose purlin runs bridge the gap
    for (final x in [1.0, 2.5]) {
      m.blocks.add(
        Block3d(def: 'truss', x: x, y: 2.0, rot: math.pi / 2, bz: 2.7),
      );
    }
    for (final x in [9.0, 10.5]) {
      m.blocks.add(
        Block3d(def: 'truss', x: x, y: 2.0, rot: math.pi / 2, bz: 2.7),
      );
    }
    final fields = roofFields(m);
    expect(fields, hasLength(2));
    // each field's runs stay local — no run crosses the 6m gap
    for (final f in fields) {
      expect(f.runLen, lessThan(4.0));
    }
    final runs = purlinRuns(m);
    // no channel may sit BETWEEN the two fields — a merged field
    // would lay bars across the 6m gap (the user's screenshot bug)
    for (final r in runs) {
      for (final face in r) {
        for (final p in face.v) {
          expect(
            p[0] > 3.5 && p[0] < 8.0,
            isFalse,
            reason: 'purlin point bridged the gap: ${p[0].toStringAsFixed(2)}',
          );
        }
      }
    }
  });

  test('roofFields splits parallel ridge lines (offset wings)', () {
    final m = boxModel();
    // two trusses, same rot, offset 6m along their SPAN dir — they
    // ride different parallel ridge lines -> two fields, and the
    // purlin stations can't land between them
    m.blocks.add(
      Block3d(def: 'truss', x: 2.5, y: 2.0, rot: math.pi / 2, bz: 2.7),
    );
    m.blocks.add(
      Block3d(def: 'truss', x: 8.5, y: 2.0, rot: math.pi / 2, bz: 2.7),
    );
    final fields = roofFields(m);
    expect(fields, hasLength(2));
  });

  test('truss-sgl: single king-post variant routes everywhere', () {
    final m = roofModel();
    m.blocks.add(
      Block3d(def: 'truss-sgl', x: 5.5, y: 2.0, rot: math.pi / 2, bz: 2.7),
    );
    expect(isTrussDef('truss-sgl'), isTrue);
    expect(isTrussDef('truss'), isTrue);
    expect(isTrussDef('col-sq'), isFalse);
    final def = cadBlock('truss-sgl')!;
    final fs = blockFaces(
      Block3d(def: 'truss-sgl', x: 0, y: 0),
      def,
    );
    // 6 members x 6 faces = 36 vs the fink's 54+ — visibly lighter
    expect(fs.length, 36);
    // groups into fields + takeoff counts the single-member web
    final t = modelTakeoff(m);
    expect(t.trusses, 3);
    expect(t.trussWebLm, greaterThan(0));
    final cw = trussChordWeb(0, 3.97, 0.80, single: true);
    final cwD = trussChordWeb(0, 3.97, 0.80);
    expect(cw.$2, lessThan(cwD.$2)); // fewer web members
    // seat + plan symbol also work
    expect(
      seatTrussOnWalls(m, const Offset(2.5, 2.0), math.pi / 2, 3.97),
      isNotNull,
    );
    expect(blockLines(Block3d(def: 'truss-sgl', x: 0, y: 0), def),
        isNotEmpty);
  });

  test('framingNotes derives member sizes + counts from fields', () {
    final notes = framingNotes(roofModel());
    expect(notes, hasLength(4));
    expect(notes[0], contains('TRUSSES: 2 @ 1.5'));
    expect(notes[0], contains('L50x50x6'));
    expect(notes[1], contains('C-PURLINS'));
    expect(notes[1], contains('0.85'));
    expect(notes[3], contains('RA 544'));
    expect(framingNotes(Model3d(name: 'e')), isEmpty);
  });

  test('grid snap: a second truss cannot land inside an existing one',
      () {
    final m = boxModel();
    // an existing truss already seated on the plates
    m.blocks.add(
      Block3d(def: 'truss', x: 2.0, y: 2.0, rot: math.pi / 2, bz: 2.7),
    );
    // click 0.15m along the ridge from it — the doubled-members bug:
    // without the snap this lands nearly on top of the first
    final seat = seatTrussOnWalls(
      m,
      const Offset(2.15, 2.0),
      math.pi / 2,
      3.97,
    );
    expect(seat, isNotNull);
    // snapped one full bay away (default spacing 1.5m)
    expect((seat!.$1.dx - 2.0).abs(), closeTo(1.5, 0.01));
    expect(seat.$1.dy, closeTo(2.0, 0.01));
    // an off-grid click far past half a bay keeps the free seat
    final free = seatTrussOnWalls(
      m,
      const Offset(3.0, 2.0),
      math.pi / 2,
      3.97,
    );
    expect(free, isNotNull);
    expect(free!.$1.dx, closeTo(3.5, 0.01)); // snapped to the 3.5 bay
    // ...or genuinely free when beyond snap reach
    final m2 = boxModel();
    m2.blocks.add(
      Block3d(def: 'truss', x: 2.0, y: 2.0, rot: math.pi / 2, bz: 2.7),
    );
    final far = seatTrussOnWalls(
      m2,
      const Offset(4.6, 2.0),
      math.pi / 2,
      3.97,
    );
    expect(far, isNotNull);
  });

  test('fields split on elevation: stepped roofs get separate runs', () {
    final m = boxModel();
    m.walls.add(
      Wall3d(points: [9, 0, 13, 0], thickness: .15, height: 3.4),
    );
    m.walls.add(
      Wall3d(points: [9, 4, 13, 4], thickness: .15, height: 3.4),
    );
    // two trusses at plate height 2.7, two on the taller 3.4 walls —
    // same ridge direction, continuous u run, DIFFERENT bz
    for (final (x, z) in [(1.0, 2.7), (2.5, 2.7), (4.0, 3.4), (5.5, 3.4)]) {
      m.blocks.add(
        Block3d(def: 'truss', x: x, y: 2.0, rot: math.pi / 2, bz: z),
      );
    }
    final fields = roofFields(m);
    expect(fields, hasLength(2));
    // each run's channels sit on ITS OWN plate elevation — mean bz of
    // a merged field (3.05) would float channels off both roofs
    for (final run in purlinRuns(m)) {
      var zmin = double.infinity, zmax = -double.infinity;
      for (final f in run) {
        for (final p in f.v) {
          zmin = math.min(zmin, p[2]);
          zmax = math.max(zmax, p[2]);
        }
      }
      // eave channel sags to the overhang tail (~0.11 under the plate)
      expect(zmin, greaterThan(2.5));
      expect(zmax - zmin, lessThan(1.2)); // one slope height, not two
    }
  });

  test('ghost filter: one side plate per member = clean layout', () {
    // the 3D ghost keeps only faces whose normal points along -rd —
    // one plate per member box, so a member never reads as doubled
    // boards. fink '4/3': 3 chords + 4 W webs = 7 members;
    // king-post: 3 chords + post + 2 struts = 6.
    for (final (def, want) in [('truss', 7), ('truss-sgl', 6)]) {
      final d = cadBlock(def)!;
      final ghost = Block3d(def: def, x: 0, y: 0, rot: 0.3);
      final rd = Offset(-math.sin(0.3), math.cos(0.3));
      final kept = blockFaces(ghost, d)
          .where((f) => f.n[0] * rd.dx + f.n[1] * rd.dy <= -0.9)
          .length;
      expect(kept, want, reason: '$def ghost member count');
    }
  });

  test('placed mesh reads ONE flat frame — members stay lumber-thin',
      () {
    // regression: member boxes once spanned the whole 0.18 footprint
    // depth, so each member's front AND back plates drew as two
    // parallel flat trusses. Members are lumber on edge: ~0.05 deep.
    for (final single in [true, false]) {
      var y0 = double.infinity, y1 = -double.infinity;
      for (final f in trussLocalFaces(0, 3.97, 0.18, 0.80,
          single: single)) {
        for (final p in f.v) {
          y0 = math.min(y0, p[1]);
          y1 = math.max(y1, p[1]);
        }
      }
      expect(
        y1 - y0,
        lessThanOrEqualTo(0.06),
        reason: 'single=$single member depth',
      );
    }
  });

  test('migrateTrusses heals legacy junk on load', () {
    // the user's real autosave state: wild rotations, a triple-stacked
    // bay near the wall, one stray a bay away, one stored far off-site
    final m = Model3d(name: 'legacy');
    m.walls.addAll([
      Wall3d(points: [0, 0, 5, 0], thickness: .15, height: 2.7),
      Wall3d(points: [0, 4, 5, 4], thickness: .15, height: 2.7),
    ]);
    m.blocks.addAll([
      // stacked trio sharing one spot FAR from walls: cannot reseat,
      // so dedupe keeps the first and drops the impossible copies
      Block3d(def: 'truss', x: -12.0, y: -12.0, rot: -4.732),
      Block3d(def: 'truss-sgl', x: -11.8, y: -11.9, rot: 4.974),
      Block3d(def: 'truss', x: -11.9, y: -12.05, rot: 7.854),
      // a lone stray spanning ACROSS the two x-walls -> reseats
      // (rot must aim the span at the walls; a truss parallel to
      // them has no plates to bear on and correctly stays stored)
      Block3d(def: 'truss', x: 4.0, y: 2.0, rot: 1.5),
      // stored far from any wall, unstacked -> survives as a spare
      Block3d(def: 'truss', x: -16, y: -16, rot: 0.4),
    ]);
    final back = Model3d.fromJson(m.toJson());
    final ts = back.blocks.where((b) => isTrussDef(b.def)).toList();
    // trio collapsed to 1, stray reseated, spare kept: 3 survivors
    expect(ts.length, 3);
    // every survivor's rotation is normalized to [0, pi)
    for (final b in ts) {
      expect(b.rot, inInclusiveRange(0, math.pi));
    }
    // the unstacked far spare survives untouched
    expect(
      ts.any(
        (b) =>
            (Offset(b.x, b.y) - const Offset(-16, -16)).distance < 0.1,
      ),
      isTrue,
      reason: 'stranded spare part stays put',
    );
    // everything near the building now bears on wall tops
    final onRoof = ts.where((b) => b.bz > 0.5).length;
    expect(onRoof, greaterThanOrEqualTo(1));
    // and no two survivors share a spot
    for (var i = 0; i < ts.length; i++) {
      for (var j = i + 1; j < ts.length; j++) {
        final d = (Offset(ts[i].x, ts[i].y) - Offset(ts[j].x, ts[j].y))
            .distance;
        expect(
          d > 0.4 || (ts[i].bz - ts[j].bz).abs() > 0.4,
          isTrue,
          reason: 'no stacked trusses survive migration',
        );
      }
    }
  });
}
