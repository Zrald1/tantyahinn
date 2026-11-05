import 'dart:math' as math;
import 'package:flutter_test/flutter_test.dart';
import 'package:tantyahin/model3d.dart';
import 'package:tantyahin/structural.dart';
import 'package:tantyahin/takeoff.dart';

void main() {
  Model3d boxModel() {
    final m = Model3d(name: 'H');
    // two parallel bearing walls 4m apart, 2.7m tall, along +X
    m.walls.add(Wall3d(points: [0, 0, 5, 0], thickness: .15, height: 2.7));
    m.walls.add(Wall3d(points: [0, 4, 5, 4], thickness: .15, height: 2.7));
    return m;
  }

  test('NSCP 409.3.1.1: min beam depth = span/16 rounded UP to 50mm',
      () {
    expect(nscpBeamDepth(4.5), closeTo(0.30, 1e-9)); // 0.281 -> 0.30
    expect(nscpBeamDepth(6.0), closeTo(0.40, 1e-9)); // 0.375 -> 0.40
    expect(nscpBeamDepth(3.0), closeTo(0.20, 1e-9)); // floor 0.20
    // continuity divisors: 18.5 / 21 / 8
    expect(nscpBeamDepth(3.7, cont: 18.5), closeTo(0.20, 1e-9));
    expect(nscpBeamDepth(8.4, cont: 21), closeTo(0.40, 1e-9));
    expect(nscpBeamDepth(1.6, cont: 8), closeTo(0.20, 1e-9));
    // width: >= 0.20 floor, ~half the depth
    expect(nscpBeamWidth(0.30), closeTo(0.20, 1e-9));
    expect(nscpBeamWidth(0.60), closeTo(0.30, 1e-9));
  });

  test('seatBeamOnWall: beam parallels the wall and rests on its top',
      () {
    final m = boxModel();
    // drop near the y=0 wall, armed with an arbitrary rotation —
    // the beam should align ALONG the wall and sit on its top
    final seat = seatBeamOnWall(m, const Offset(2.5, 0.5), 1.2, 4.0)!;
    expect(seat.$1.dx, closeTo(2.5, 1e-6));
    expect(seat.$1.dy, closeTo(0.0, 1e-6)); // on the wall centerline
    expect(math.cos(seat.$2).abs(), greaterThan(0.99)); // runs +X
    expect(seat.$3, closeTo(2.7, 1e-6)); // rests ON the wall top
  });

  test('a beam is a bearing plate: the truss seats on the beam top',
      () {
    final m = boxModel();
    // a 0.20x0.30 beam running along the y=4 wall ON TOP of it —
    // the truss span must bear at the BEAM's upper face, not the
    // wall plate underneath
    m.blocks.add(
      Block3d(def: 'beam', x: 2.5, y: 4.0, rot: 0, bz: 2.7),
    );
    final seat = seatTrussOnWalls(
      m,
      const Offset(2.5, 2.0),
      math.pi / 2,
      4.0,
    )!;
    // beam top 2.7+0.30 = 3.00 beats the wall top 2.70 at the same
    // bearing distance; bz = plate + the chord-half lift
    expect(seat.$3, closeTo(3.0 + kTrussSeatLift, 1e-6));
    // the truss resting there counts as a roof member
    final t = Block3d(
      def: 'truss',
      x: seat.$1.dx,
      y: seat.$1.dy,
      rot: seat.$2,
      bz: seat.$3,
    );
    m.blocks.add(t);
    expect(trussInRoof(m, t), isTrue);
  });

  test('beam blocks join the concrete + steel takeoff', () {
    final m = boxModel();
    m.blocks.add(
      Block3d(def: 'beam', x: 2.5, y: 4.0, rot: 0, bz: 2.7),
    );
    final t = modelTakeoff(m);
    // 4.0 x 0.20 x 0.30 = 0.24 cu.m of beam concrete
    expect(t.beamVol, greaterThanOrEqualTo(0.24 - 1e-9));
    final s = takeoffSteelSched(m)!;
    expect(s.results.single.notes.any((n) => n.contains('BEAM')), isTrue);
  });

  test('purlins ride each truss at its OWN chord station', () {
    final m = boxModel();
    // two trusses on the same run, one 0.6m off the field's ridge
    // line (inside the cluster tolerance) — the straight channel
    // must seat on whichever chord is TALLEST at each station:
    // reading every truss at the field's own offset floated the run
    // off the off-line truss's chord
    m.blocks.add(
      Block3d(def: 'truss', x: 1.0, y: 2.0, rot: math.pi / 2, bz: 2.7),
    );
    m.blocks.add(
      Block3d(def: 'truss', x: 2.5, y: 1.4, rot: math.pi / 2, bz: 2.7),
    );
    final f = roofFields(m).single;
    final runs = purlinRuns(m);
    expect(runs.length, f.purlinRows(m.roof));
    const th = 3.97 / 2, tr = 0.80;
    // expected contact surface at field station o: the max over member
    // trusses of their own-station chord TOP SURFACE — the member's
    // half-thickness lands along the roof normal, so the vertical lift
    // is chordHalf * slope/half (a bare vertical +0.05 credits only
    // 0.05*half/slope along the normal and EMBEDS the channel in the
    // chord on any real pitch)
    double env(double o) {
      var z = -double.infinity;
      for (final t in f.trusses) {
        final tp = Offset(math.cos(t.rot), math.sin(t.rot));
        final oT =
            (f.center.dx + f.perp.dx * o - t.x) * tp.dx +
            (f.center.dy + f.perp.dy * o - t.y) * tp.dy;
        final zt = t.bz + tr * (1 - oT.abs() / th);
        if (zt > z) z = zt;
      }
      return z + 0.05 * f.slope / f.half;
    }

    for (final r in runs) {
      // the run's station = its centroid projected on the field perp
      var cx = 0.0, cy = 0.0, n = 0;
      var mz = double.infinity;
      for (final face in r) {
        for (final p in face.v) {
          cx += p[0];
          cy += p[1];
          n++;
          mz = math.min(mz, p[2]);
        }
      }
      cx /= n;
      cy /= n;
      final o =
          (cx - f.center.dx) * f.perp.dx + (cy - f.center.dy) * f.perp.dy;
      // the channel's lowest vertex kisses the surface: flange/plate
      // centering dips it a few mm below the contact plane, never
      // more — embed (>2cm under) or float (>4cm over) both fail
      expect(
        mz,
        inInclusiveRange(env(o) - 0.02, env(o) + 0.04),
        reason: 'channel at o=${o.toStringAsFixed(2)} must touch the '
            'chord top surface, not bore through or float',
      );
    }
  });
}
