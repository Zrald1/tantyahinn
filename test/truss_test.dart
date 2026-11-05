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
    expect(seat.$3, closeTo(2.7, 1e-6));
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
    expect(seat.$3, closeTo(2.7, 1e-6));
    // span turned perpendicular to the x-running wall
    expect(math.sin(seat.$2).abs(), greaterThan(0.9));
  });

  test('single-wall seat snaps the truss onto the plate line', () {
    final m = boxModel();
    // drop beside the wall centerline — the seat must PIN the truss
    // to the plate, not leave it at the raw click point
    final seat = seatTrussOnWalls(
      m,
      const Offset(2.5, 0.9),
      0,
      4.0,
    )!;
    expect(seat.$1.dy, closeTo(0.0, 1e-6)); // snapped onto y=0 plate
    expect(seat.$3, closeTo(2.7, 1e-6));
    expect(math.sin(seat.$2).abs(), greaterThan(0.9));
  });

  test('no walls -> null (free drop fallback stays)', () {
    final m = Model3d(name: 'empty');
    expect(
      seatTrussOnWalls(m, Offset.zero, 0, 4.0),
      isNull,
    );
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
    // eave purlin drops below wall top by the overhang tail;
    // ridge purlin crests at apex + channel depth
    expect(z0, lessThan(2.7));
    expect(z0, greaterThan(2.0));
    expect(z1, greaterThan(2.7 + 0.85)); // rise + channel depth
    // runs follow the ridge (+X for this rot) spanning u0..u1
    final xspan = runs.first
        .expand((f2) => f2.v)
        .map((p) => p[0])
        .reduce((a, b) => math.max(a, b)) -
        runs.first
            .expand((f2) => f2.v)
            .map((p) => p[0])
            .reduce((a, b) => math.min(a, b));
    expect(xspan, closeTo(f.runLen, 0.01));
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
    // boards. fink: 3 chords + 3 verticals + 3 diagonals = 9 members;
    // king-post: 3 chords + post + 2 struts = 6.
    for (final (def, want) in [('truss', 9), ('truss-sgl', 6)]) {
      final d = cadBlock(def)!;
      final ghost = Block3d(def: def, x: 0, y: 0, rot: 0.3);
      final rd = Offset(-math.sin(0.3), math.cos(0.3));
      final kept = blockFaces(ghost, d)
          .where((f) => f.n[0] * rd.dx + f.n[1] * rd.dy <= -0.9)
          .length;
      expect(kept, want, reason: '$def ghost member count');
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
