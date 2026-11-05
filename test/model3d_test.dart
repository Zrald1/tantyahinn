import 'dart:math' as math;

import 'package:tantyahin/dxf.dart';
import 'package:tantyahin/model3d.dart';
import 'package:tantyahin/takeoff.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Volume3d geometry', () {
    test('area/bounds/top on a rect footprint', () {
      final v = Volume3d(footprint: [0, 0, 8, 0, 8, 6, 0, 6], height: 3.5);
      expect(v.area, 48);
      expect(v.top, 3.5);
      expect(v.bounds, (0.0, 0.0, 8.0, 6.0));
      expect(v.corners, 4);
      expect(v.contains(const Offset(4, 3)), isTrue);
      expect(v.contains(const Offset(9, 3)), isFalse);
    });

    test('volumeFaces emits side quads + cap, outward normals', () {
      final v = Volume3d(footprint: [0, 0, 8, 0, 8, 6, 0, 6]);
      final faces = volumeFaces(v);
      expect(faces.length, 5); // 4 walls + cap
      // CCW footprint -> south wall (y=0 edge) faces -Y
      expect(faces[0].n[1], lessThan(0));
      expect(faces.last.n, const [0, 0, 1]);
      // CW input is normalized — the same outward normals come out:
      // every wall still faces away from the footprint's interior
      final cw = Volume3d(footprint: [0, 0, 0, 6, 8, 6, 8, 0]);
      final cf = volumeFaces(cw);
      expect(cf.length, 5);
      expect(cf.any((f) => f.n[1] == -1.0), isTrue); // south wall
      expect(cf.any((f) => f.n[0] == -1.0), isTrue); // west wall
      expect(cf.last.n, const [0, 0, 1]);
    });

    test('serialization round-trip', () {
      final v = Volume3d(
          name: 'Wing A',
          footprint: [1, 2, 5, 2, 5, 7, 1, 7],
          base: 1.5,
          height: 4.25,
          argb: 0xFF112233);
      final r = Volume3d.fromJson(v.toJson());
      expect(r.name, 'Wing A');
      expect(r.fp, [1, 2, 5, 2, 5, 7, 1, 7]);
      expect(r.base, 1.5);
      expect(r.height, 4.25);
      expect(r.argb, 0xFF112233);
      expect(r.id, v.id);
    });
  });

  group('projectView', () {
    final m = Model3d(name: 'T')
      ..volumes.add(Volume3d(footprint: [0, 0, 8, 0, 8, 6, 0, 6]));

    test('plan + roof return the footprint outline', () {
      expect(projectView(m, SheetView.plan).single.length, 4);
      expect(projectView(m, SheetView.roof).single.length, 4);
    });

    test('front elevation keeps only -Y faces, rear only +Y', () {
      final front = projectView(m, SheetView.front);
      expect(front.length, 1);
      // projected onto X-Z: x stays, y becomes height z
      expect(front.single[0], const Offset(0, 0));
      expect(front.single[2].dy, 3.0);
      final rear = projectView(m, SheetView.rear);
      expect(rear.length, 1);
      // rear is mirrored on X so it reads correctly
      expect(rear.single.every((p) => p.dx <= 0), isTrue);
    });

    test('left/right elevations project depth onto the horizontal', () {
      expect(projectView(m, SheetView.left).single[2].dy, 3.0);
      expect(projectView(m, SheetView.right).length, 1);
      // cap face (normal +Z) is never in an elevation
      for (final v in [
        SheetView.front, SheetView.rear, SheetView.left, SheetView.right
      ]) {
        for (final p in projectView(m, v)) {
          expect(p.length, 4); // wall quads only
        }
      }
    });
  });

  group('elevationPrims (architectural elevation)', () {
    // 8x6 rect wall ring + window on the front wall, door on the
    // rear, furniture + an interior column that must stay hidden
    Model3d house() => Model3d(name: 'H')
      ..walls.add(
          Wall3d(points: [0, 0, 8, 0, 8, 6, 0, 6, 0, 0], height: 3))
      ..blocks.add(Block3d(def: 'window-120', x: 2, y: 0))
      ..blocks.add(Block3d(def: 'door-090', x: 4, y: 6))
      ..blocks.add(Block3d(def: 'bed-dbl', x: 4, y: 3))
      ..blocks.add(Block3d(def: 'col-sq', x: 4, y: 3));

    List<List<Offset>> fills(List<(List<Offset>, int)> prims) =>
        [for (final p in prims) if (p.$2 == 7) p.$1];
    List<List<Offset>> detail(List<(List<Offset>, int)> prims) =>
        [for (final p in prims) if (p.$2 == 8) p.$1];

    test('front: facade + corner strips only — hidden/interior skipped', () {
      final prims = elevationPrims(house(), SheetView.front);
      final f = fills(prims), d = detail(prims);
      // front wall + 2 side-wall corner strips; the rear wall (same
      // rect behind), the bed and the interior column are covered
      expect(f.length, 3);
      final facade = f.firstWhere((r) => r[0].dx == 0 && r[1].dx == 8);
      expect(facade[2].dy, 3.0);
      // window: rect + sill horn + mid-rail at the real sill..head band
      expect(d.length, 3);
      final wrect = d.firstWhere((p) => p.length == 4);
      expect(wrect[0].dy, closeTo(0.9, 1e-6));
      expect(wrect[2].dy, closeTo(2.1, 1e-6));
      expect(wrect[1].dx - wrect[0].dx, closeTo(1.2, 0.05));
      // door on the REAR wall must not leak onto the front elevation:
      // exactly one detail rect — the front window's
      expect(d.where((p) => p.length == 4).length, 1);
    });

    test('rear mirrors X and picks up its own door, not the window', () {
      final prims = elevationPrims(house(), SheetView.rear);
      final d = detail(prims);
      // rear wall + 2 corner strips; front window stays home
      expect(fills(prims).length, 3);
      final drect = d.firstWhere((p) => p.length == 4);
      // door-090: 0..2.1 band, mirrored to u=-x around x=4 -> [-4.45,-3.55]
      expect(drect[0].dy, closeTo(0, 1e-6));
      expect(drect[2].dy, closeTo(2.1, 1e-6));
      expect(drect[0].dx, closeTo(-4.45, 0.05));
      expect(drect[1].dx, closeTo(-3.55, 0.05));
      expect(d.length, 1); // plain door: no sill/rail/split detail
    });

    test('left/right elevations see the side walls', () {
      final prims = elevationPrims(house(), SheetView.left);
      // left view: x=0 wall is the facade (u=-y -> [-6,0]), front +
      // rear walls collapse to corner strips, x=8 wall hidden
      final f = fills(prims);
      expect(f.length, 3);
      expect(f.any((r) => r[0].dx == -6 && r[1].dx == 0), isTrue);
      // the front-wall window sits on an x-running wall — invisible
      // in a side elevation (edge-on), so no detail linework
      expect(detail(prims), isEmpty);
      expect(elevationPrims(house(), SheetView.right).length, 3);
    });

    test('a porch column in front of the facade draws', () {
      final m = house()..blocks.add(Block3d(def: 'col-sq', x: 4, y: -0.6));
      final f = fills(elevationPrims(m, SheetView.front));
      // facade + 2 strips + porch column
      expect(f.length, 4);
      expect(f.any((r) => r[0].dx > 3.7 && r[1].dx < 4.3), isTrue);
    });

    test('interior partition never reaches an elevation', () {
      final m = house()
        ..walls.add(Wall3d(points: [2, 3, 6, 3], height: 3));
      // same rect inside the facade silhouette -> suppressed both ways
      expect(fills(elevationPrims(m, SheetView.front)).length, 3);
      expect(fills(elevationPrims(m, SheetView.rear)).length, 3);
    });
  });

  group('buildModelDxf', () {
    test('emits a parseable sheet: 6 views, labels, closed polylines',
        () {
      final m = Model3d(name: 'SCHOOL')
        ..volumes.add(Volume3d(
            footprint: [0, 0, 10, 0, 10, 7, 0, 7], height: 4))
        ..volumes.add(Volume3d(
            footprint: [10, 0, 14, 0, 14, 4, 10, 4], height: 6));
      final src = buildModelDxf(m);
      // our own parser must eat it — the real consumer is the DRAWINGS
      // viewer, so this is the honest round-trip
      final scene = DxfParser.parse(src);
      // 2 volumes: plan(2) + roof(2) + framing(2) + 4 elevations x
      // (2 bands + 1 grade line) = 18 prims, all but the 4 grade
      // lines closed
      expect(scene.prims.length, 18);
      expect(scene.prims.where((p) => p.closed).length, 14);
      expect(scene.prims.where((p) => !p.closed).length, 4);
      final labels = scene.texts.map((t) => t.text).toList();
      for (final want in [
        'FLOOR PLAN',
        'ROOF PLAN',
        'ROOF FRAMING PLAN',
        'FRONT ELEVATION',
        'REAR ELEVATION',
        'LEFT ELEVATION',
        'RIGHT ELEVATION',
      ]) {
        expect(labels.any((s) => s.contains(want)), isTrue,
            reason: 'missing $want');
      }
      expect(labels.any((s) => s.contains('SCHOOL')), isTrue);
      expect(scene.bounds.width, greaterThan(0));
      // elevations sit below the plan row — some prim must reach y=0..h
      expect(
          scene.prims.any((p) => p.pts.every((o) => o.dy <= 6.5)), isTrue);
    });

    test('empty model still emits a valid file', () {
      final scene = DxfParser.parse(buildModelDxf(Model3d()));
      expect(scene.texts.single.text, 'EMPTY MODEL');
    });
  });

  group('buildModelSheet (separate sheet per view)', () {
    final m = Model3d(name: 'HUT')
      ..walls.add(
          Wall3d(points: [0, 0, 6, 0, 6, 4], thickness: 0.15, height: 2.7))
      ..blocks.add(Block3d(def: 'bed', x: 2, y: 2));

    test('each SheetView parses and carries only its own label', () {
      for (final v in SheetView.values) {
        final scene = DxfParser.parse(buildModelSheet(m, v));
        final labels = scene.texts.map((t) => t.text).join('|');
        expect(labels, contains(kSheetTitle[v]!));
        for (final other in SheetView.values) {
          if (other != v) {
            expect(labels, isNot(contains(kSheetTitle[other]!)),
                reason: '${v.name} leaks ${other.name} label');
          }
        }
        // every sheet names the model it came from
        expect(labels, contains('HUT'));
      }
    });

    test('floor plan sheet has wall hatches + segment dims', () {
      final scene =
          DxfParser.parse(buildModelSheet(m, SheetView.plan));
      expect(scene.prims.any((p) => p.fillLoops != null), isTrue);
      // a 6m wall segment label must be in there
      expect(scene.texts.any((t) => t.text == '6.00'), isTrue);
    });

    test('elevation sheets have a ground baseline and wall outline',
        () {
      final scene =
          DxfParser.parse(buildModelSheet(m, SheetView.front));
      // an open baseline polyline exists (open == not closed)
      expect(scene.prims.any((p) => !p.closed), isTrue);
      // the wall face(s) show as closed outlines
      expect(scene.prims.any((p) => p.closed), isTrue);
    });

    test('structural sheet draws pads at real size with F/C callouts',
        () {
      final sm = Model3d(name: 'FRAME')
        ..walls.add(
            Wall3d(points: [0, 0, 6, 0, 6, 4, 0, 4, 0, 0], thickness: 0.15))
        ..blocks.add(Block3d(def: 'col-sq', x: 0, y: 0, footing: true))
        ..blocks.add(Block3d(def: 'col-sq', x: 6, y: 4))
        ..blocks.add(Block3d(def: 'ftg-150', x: 3, y: 2));
      final scene =
          DxfParser.parse(buildModelSheet(sm, SheetView.structural));
      final labels = scene.texts.map((t) => t.text).join('|');
      expect(labels, contains('STRUCTURAL PLAN - FOUNDATION'));
      expect(labels, contains('C1'));
      expect(labels, contains('C2'));
      // flagged footing -> F1 with its real schedule size + depth
      expect(labels, contains('F1'));
      expect(labels, contains('1.5x1.5x0.3'));
      // placed pad block -> FP1 callout
      expect(labels, contains('FP1'));
      // the F1 pad square must be drawn at the real 1.5m side, not
      // the 0.3m column footprint — the sheet is mm paper space, so
      // read the emitted SCALE 1:N and expect 1500/N mm
      final scaleTxt = scene.texts
          .firstWhere((t) => t.text.startsWith('SCALE 1:'))
          .text;
      final denom = int.parse(scaleTxt.substring(8).split(' ').first);
      final padSide = 1500.0 / denom;
      final pads = scene.prims.where((p) {
        if (!p.closed || p.pts.length < 4) return false;
        final xs = p.pts.map((q) => q.dx), ys = p.pts.map((q) => q.dy);
        final w = xs.reduce(math.max) - xs.reduce(math.min);
        final h = ys.reduce(math.max) - ys.reduce(math.min);
        return (w - padSide).abs() < 0.5 && (h - padSide).abs() < 0.5;
      });
      expect(pads.length, 2); // F1 flagged pad + FP1 placed pad
    });

    test('discipline sheets only draw their own fixture set', () {
      final dm = Model3d(name: 'MEP')
        ..walls.add(
            Wall3d(points: [0, 0, 6, 0, 6, 4, 0, 4, 0, 0], thickness: 0.15))
        ..blocks.add(Block3d(def: 'tv', x: 1, y: 1))
        ..blocks.add(Block3d(def: 'wc', x: 4, y: 3));
      final el =
          DxfParser.parse(buildModelSheet(dm, SheetView.electrical));
      final elTxt = el.texts.map((t) => t.text).join('|');
      expect(elTxt, contains('ELECTRICAL PLAN'));
      expect(elTxt, contains('TELEVISION'));
      expect(elTxt, isNot(contains('TOILET')));
      final pl = DxfParser.parse(buildModelSheet(dm, SheetView.plumbing));
      final plTxt = pl.texts.map((t) => t.text).join('|');
      expect(plTxt, contains('PLUMBING PLAN'));
      expect(plTxt, contains('TOILET WC'));
      expect(plTxt, isNot(contains('TELEVISION')));
    });

    test('ftg pad block renders buried + counts in takeoff', () {
      final fm = Model3d()
        ..blocks.add(Block3d(def: 'ftg-150', x: 1, y: 1));
      final faces = modelFaces(fm);
      // buried pad: top at base 0, body to -0.30
      final zs = faces.expand((f) => f.v).map((p) => p[2]);
      expect(zs.reduce((a, b) => a < b ? a : b), closeTo(-0.30, 1e-9));
      expect(zs.reduce((a, b) => a > b ? a : b), closeTo(0, 1e-9));
      final t = modelTakeoff(fm);
      expect(t.footCount, 1);
      expect(t.footVol, closeTo(1.5 * 1.5 * 0.30, 1e-9));
    });
  });

  group('Wall3d', () {
    test('centerline -> thick segment polygons, length, dims', () {
      // L-shaped wall: 4m east then 3m north, 0.2 thick
      final w = Wall3d(points: [0, 0, 4, 0, 4, 3], thickness: 0.2);
      expect(w.segs, 2);
      expect(w.length, closeTo(7.0, 1e-9));
      final s0 = w.segPoly(0);
      expect(s0.length, 4);
      // the rect covers thickness around the centerline
      final ys = s0.map((p) => p.dy).toList()..sort();
      expect(ys.first, closeTo(-0.1, 1e-9));
      expect(ys.last, closeTo(0.1, 1e-9));
      // bounds include the perpendicular thickness (butt caps do
      // not extend past segment endpoints)
      final b = w.bounds;
      expect(b.$1, closeTo(0.0, 1e-9)); // seg0's butt cap at x=0
      expect(b.$2, closeTo(-0.1, 1e-9)); // below seg0
      expect(b.$3, closeTo(4.1, 1e-9)); // right of seg1
      expect(b.$4, closeTo(3.0, 1e-9)); // seg1's cap at y=3
    });

    test('wallFaces extrude every segment with outward normals', () {
      final w = Wall3d(points: [0, 0, 4, 0], thickness: 0.2, height: 2.7);
      final f = wallFaces(w);
      expect(f.length, 5); // 4 side quads + cap
      expect(f.last.n, const [0, 0, 1]); // cap faces up
      // the segment is a closed loop in the plan/roof views too
      final m = Model3d()..walls.add(w);
      expect(projectView(m, SheetView.plan).single.length, 4);
      // front elevation shows the wall quad, 4m wide x 2.7m tall
      final front = projectView(m, SheetView.front);
      expect(front.single[2].dy, 2.7);
      expect(front.single[1].dx, 4.0);
    });

    test('distTo hits near the centerline, translates', () {
      final w = Wall3d(points: [0, 0, 4, 0], thickness: 0.2);
      expect(w.distTo(const Offset(2, 0.09)), lessThan(0.1));
      expect(w.distTo(const Offset(2, 0.11)), greaterThan(0.1));
      w.translate(1, 2);
      expect(w.pts, [1, 2, 5, 2]);
    });

    test('serialization round-trip keeps thickness and base', () {
      final w = Wall3d(
          name: 'W7',
          points: [0, 0, 4, 0, 4, 3],
          thickness: 0.25,
          base: 0.4,
          height: 3.1,
          argb: 0xFF445566);
      final r = Wall3d.fromJson(w.toJson());
      expect(r.pts, w.pts);
      expect(r.thickness, 0.25);
      expect(r.base, 0.4);
      expect(r.height, 3.1);
      expect(r.id, w.id);
    });
  });

  group('Block3d + CAD library', () {
    test('library covers the standard plan categories', () {
      final ids = kCadBlocks.map((b) => b.id).toSet();
      for (final want in [
        'door-090', 'window-120', 'stairs-100',
        'bed-dbl', 'sofa-3', 'dining-6',
        'wc', 'basin', 'tub', 'shower',
        'sink-kit', 'stove', 'fridge', 'wardrobe',
      ]) {
        expect(ids, contains(want), reason: 'missing $want');
      }
      // every symbol's linework stays within its reach — symbols can
      // be asymmetric (a door's swing arc runs one full leaf out)
      for (final b in kCadBlocks) {
        final reach = math.max(b.w, b.d) + 0.01;
        for (final l in b.lines) {
          for (final p in l) {
            expect(p.dx.abs(), lessThanOrEqualTo(reach),
                reason: '${b.id} over-wide');
            expect(p.dy.abs(), lessThanOrEqualTo(reach),
                reason: '${b.id} over-deep');
          }
        }
      }
    });

    test('blockLines rotate + translate; footprint hit quad follows',
        () {
      final b = Block3d(def: 'bed-sgl', x: 2, y: 3, rot: math.pi / 2);
      final def = cadBlock('bed-sgl')!;
      final lines = blockLines(b, def);
      expect(lines.isNotEmpty, isTrue);
      // 90° rotation: the 2.0m depth now runs along X
      final q = blockFootprint(b, def);
      final xs = q.map((p) => p.dx).toList()..sort();
      final ys = q.map((p) => p.dy).toList()..sort();
      expect(xs.last - xs.first, closeTo(2.0, 0.01));
      expect(ys.last - ys.first, closeTo(0.9, 0.01));
      // centered on the insertion point
      expect((xs.first + xs.last) / 2, closeTo(2, 0.01));
      expect((ys.first + ys.last) / 2, closeTo(3, 0.01));
    });

    test('furniture adds plan symbols; no-mesh openings stay flat',
        () {
      final m = Model3d()
        ..blocks.add(Block3d(def: 'wc', x: 1, y: 1))
        ..blocks.add(Block3d(def: 'door-090', x: 2, y: 2));
      // plan view carries both symbols
      expect(projectView(m, SheetView.plan).length, greaterThan(3));
      // in-app the bundled door mesh renders in 3D; without a
      // registered mesh the opening stays a flat plan symbol so the
      // faces here are just the WC footprint prism (4 sides + cap)
      final faces = modelFaces(m);
      expect(faces.length, 5);
      // the elevation is semantic, not a mesh dump: a lone toilet and
      // a door not seated on any wall draw nothing
      expect(projectView(m, SheetView.front), isEmpty);
    });

    test('block serialization round-trip', () {
      final b = Block3d(
          def: 'sofa-3', x: 1.5, y: 2.5, rot: 1.2, scale: 1.1);
      final r = Block3d.fromJson(b.toJson());
      expect(r.def, 'sofa-3');
      expect(r.x, 1.5);
      expect(r.rot, 1.2);
      expect(r.id, b.id);
    });
  });

  group('modelFaces (2D drives 3D)', () {
    test('walls + volumes + blocks all contribute faces', () {
      final m = Model3d()
        ..volumes.add(Volume3d(footprint: [0, 0, 8, 0, 8, 6, 0, 6]))
        ..walls.add(Wall3d(points: [9, 0, 9, 4], thickness: 0.2))
        ..blocks.add(Block3d(def: 'bed-sgl', x: 2, y: 3));
      // volume prism(5) + wall prism(5) + bed prism(5)
      expect(modelFaces(m).length, 15);
      // bounds span everything
      final b = m.bounds!;
      expect(b.$3, greaterThanOrEqualTo(9.1));
    });

    test('generated sheet carries wall hatch + segment dimensions', () {
      final m = Model3d(name: 'PLAN')
        ..walls.add(Wall3d(
            points: [0, 0, 6, 0, 6, 4], thickness: 0.2, height: 2.8));
      final scene = DxfParser.parse(buildModelDxf(m));
      // wall fills arrive as hatch loops (the real-plan mass look)
      expect(scene.prims.any((p) => p.fillLoops != null), isTrue);
      // automatic measurement: a "6" and a "4" dim label must exist
      final labels = scene.texts.map((t) => t.text).toList();
      expect(labels.any((s) => s == '6.00 m'), isTrue);
      expect(labels.any((s) => s == '4.00 m'), isTrue);
      // elevations show the wall: front + left at least
      expect(labels.any((s) => s.contains('FRONT ELEVATION')), isTrue);
    });
  });

  test('est JSON round-trip keeps models', () async {
    // est lives in state.dart which pulls Flutter services — this test
    // runs inside flutter_test so the import chain is fine.
    final m = Model3d(name: 'KEEP')..volumes.add(
        Volume3d(footprint: [0, 0, 3, 0, 3, 3, 0, 3], height: 2.8));
    final j = m.toJson();
    final r = Model3d.fromJson(j);
    expect(r.name, 'KEEP');
    expect(r.volumes.single.height, 2.8);
    expect(r.volumes.single.id, m.volumes.single.id);
  });

  group('seatColumnOnWall', () {
  Model3d wallModel() => Model3d(name: 'S')
    ..walls.add(Wall3d(points: [0, 0, 6, 0], thickness: 0.20));

  test('snaps the column center onto the wall centerline', () {
    final seat = seatColumnOnWall(wallModel(), const Offset(3, 0.12), 0.30);
    expect(seat, isNotNull);
    expect(seat!.$1.dx, closeTo(3, 1e-6));
    expect(seat.$1.dy, closeTo(0, 1e-6)); // ON the centerline
    expect(seat.$2, closeTo(0, 1e-6)); // rot follows the wall angle
  });

  test('a drop past the seg end lands at the ENDPOINT (junction)', () {
    // past the end, near the centerline — projected point clamps to
    // the endpoint, so the column lands on the corner
    final seat =
        seatColumnOnWall(wallModel(), const Offset(6.4, 0.05), 0.30);
    expect(seat, isNotNull);
    expect(seat!.$1, const Offset(6, 0));
  });

  test('face-flush: a drop beside the wall lands column edge on the face',
      () {
    // 0.30 column beside a 0.20 wall: flush offset = 0.10 + 0.15 = 0.25
    final seat = seatColumnOnWall(wallModel(), const Offset(3, 0.45), 0.30);
    expect(seat, isNotNull);
    expect(seat!.$1.dy, closeTo(0.25, 1e-6));
    final below =
        seatColumnOnWall(wallModel(), const Offset(3, -0.45), 0.30);
    expect(below!.$1.dy, closeTo(-0.25, 1e-6));
  });

  test('returns null past tolerance — free-standing column stays put', () {
    expect(
      seatColumnOnWall(wallModel(), const Offset(3, 1.5), 0.30),
      isNull,
    );
  });
});
}
