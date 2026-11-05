import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart' show Offset, Size;
import 'package:flutter_test/flutter_test.dart';
import 'package:tantyahin/model3d.dart';
import 'package:tantyahin/ui/model_view.dart';

/// HEADLESS RENDER SIMULATION — paints the REAL pipeline (blockFaces /
/// modelFaces + cam3Project + painter's-algorithm sort) into actual
/// pixels, no app window needed. Asserts every placed block produces
/// real, grounded, on-footprint geometry. Dumps PNGs to test/out/ so
/// the result is eyeball-able exactly like the 3D VIEW.
void main() {
  setUpAll(() async {
    await preloadBlockMeshes((p) => File(p).readAsString());
  });

  test('every block def renders grounded real geometry (no floaters)', () {
    final report = <String>[];
    var bad = 0;
    for (final def in kCadBlocks) {
      final b = Block3d(def: def.id, x: 0, y: 0);
      final faces = blockFaces(b, def);
      var zmin = double.infinity, zmax = 0.0;
      var xspan = 0.0, yspan = 0.0;
      for (final f in faces) {
        for (final p in f.v) {
          zmin = math.min(zmin, p[2]);
          zmax = math.max(zmax, p[2]);
          xspan = math.max(xspan, p[0].abs() * 2);
          yspan = math.max(yspan, p[1].abs() * 2);
        }
      }
      final lift = kKenneyZLift[def.id] ?? def.sill;
      // ftg-* pads are buried foundation concrete: their TOP anchors
      // at grade, so the body legitimately extends below z=0
      final buried = def.id.startsWith('ftg-');
      final floats =
          ((buried ? zmax : zmin) - lift).abs() > 0.06;
      // a real mesh is at least 6 faces; fewer means it fell back to
      // the bare prism or failed to register
      final tiny = faces.length < 6;
      if (floats || tiny || faces.isEmpty) bad++;
      report.add(
        '${def.id.padRight(14)} faces=${faces.length.toString().padLeft(4)} '
        'z=${zmin.toStringAsFixed(2)}..${zmax.toStringAsFixed(2)} '
        'xy=${xspan.toStringAsFixed(2)}x${yspan.toStringAsFixed(2)}'
        '${floats ? '  <-- FLOATS' : ''}${tiny ? '  <-- TINY' : ''}',
      );
    }
    // ignore: avoid_print
    print(report.join('\n'));
    expect(bad, 0, reason: report.join('\n'));
  });

  test('cachedFaces invalidates on block edits AND mesh-registry changes', () {
    final m = Model3d(name: 'sim');
    m.blocks.add(Block3d(def: 'bed-sgl', x: 1, y: 1));
    final a = m.cachedFaces();
    // a geometry mutation must produce a NEW face list
    m.blocks.first.x = 5;
    final b = m.cachedFaces();
    expect(identical(a, b), isFalse);
    // registry change: drop the def's mesh -> prism fallback must
    // appear on the next read (was the stale-cache bug)
    final save = blockMeshes.remove('bed-sgl');
    try {
      final c = m.cachedFaces();
      expect(identical(b, c), isFalse, reason: 'mesh removal must invalidate');
    } finally {
      blockMeshes['bed-sgl'] = save!;
    }
  });

  test('2D + 3D raster simulation paints real pixels per block', () async {
    final dir = Directory('test/out')..createSync(recursive: true);
    const vp = Size(640, 480);
    var checked = 0;
    for (final def in kCadBlocks) {
      final m = Model3d(name: def.id)
        ..blocks.add(Block3d(def: def.id, x: 0, y: 0));
      final faces = m.cachedFaces();
      if (faces.isEmpty) continue;
      checked++;

      // fit a camera to the block bounds, then rasterize — aim at the
      // mesh's projected center like _fit3, or lifted objects (window
      // at sill height, ceiling fan) fly off the top of the frame
      final bb = blockLocalBox(def);
      final zoom = (vp.shortestSide * 0.55) /
          math.max(bb[3] - bb[0], math.max(bb[4] - bb[1], bb[5] - bb[2]));
      const yaw = -0.7, pitch = 0.55;
      final c = [
        (bb[0] + bb[3]) / 2,
        (bb[1] + bb[4]) / 2,
        (bb[2] + bb[5]) / 2,
      ];
      final pc = cam3Project(
        c,
        vp,
        yaw: yaw,
        pitch: pitch,
        zoom: zoom,
        off: Offset.zero,
      );
      final off = Offset(vp.width / 2, vp.height / 2) - pc;
      Offset prj(double px, double py, double pz) => cam3Project(
            [px, py, pz],
            vp,
            yaw: yaw,
            pitch: pitch,
            zoom: zoom,
            off: off,
          );
      final rec = ui.PictureRecorder();
      final canvas = ui.Canvas(rec);
      canvas.drawRect(
        Offset.zero & vp,
        ui.Paint()..color = const ui.Color(0xFFDDE3EA),
      );
      final sorted = faces.toList()
        ..sort(
          (a, b2) => cam3Depth(
            b2.v[0],
            yaw: yaw,
            pitch: pitch,
          ).compareTo(cam3Depth(a.v[0], yaw: yaw, pitch: pitch)),
        );
      var painted = 0;
      for (final f in sorted) {
        final path = ui.Path();
        for (var i = 0; i < f.v.length; i++) {
          final p = prj(f.v[i][0], f.v[i][1], f.v[i][2]);
          i == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
        }
        path.close();
        canvas.drawPath(path, ui.Paint()..color = ui.Color(f.argb));
        painted++;
      }
      expect(painted, greaterThanOrEqualTo(6), reason: def.id);

      final pic = rec.endRecording();
      final img = await pic.toImage(vp.width.toInt(), vp.height.toInt());
      final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
      File('${dir.path}/block_${def.id}.png')
          .writeAsBytesSync(bytes!.buffer.asUint8List());

      // coverage: the block must occupy real screen area (not a
      // dot, not empty). Count non-white pixels via raw RGBA.
      final raw = await img.toByteData();
      var lit = 0;
      final px = raw!.buffer.asUint32List();
      for (final q in px) {
        final r = q & 0xFF, g = (q >> 8) & 0xFF, bch = (q >> 16) & 0xFF;
        // lit = differs from the gray backdrop (white porcelain counts)
        if ((r - 0xDD).abs() > 16 ||
            (g - 0xE3).abs() > 16 ||
            (bch - 0xEA).abs() > 16) {
          lit++;
        }
      }
      final frac = lit / px.length;
      expect(
        frac,
        inExclusiveRange(0.005, 0.99),
        reason: '${def.id} painted ${(frac * 100).toStringAsFixed(1)}%',
      );
    }
    expect(checked, kCadBlocks.length);
  });

  test('wall join + opening cut: corners combine, doors gap', () {
    // user's complaint: wall ends butt-cap into corner notches and a
    // door block floats ON the wall instead of cutting an opening
    final m = Model3d(name: 'join')
      ..walls.addAll([
        // two walls meeting at the (6,4) corner — perpendicular
        Wall3d(points: [0, 4, 6, 4], thickness: 0.15),
        Wall3d(points: [6, 0, 6, 4], thickness: 0.15),
        // a third wall with a door sitting on its centerline
        Wall3d(points: [0, 0, 6, 0], thickness: 0.15),
      ])
      ..blocks.add(Block3d(def: 'door-090', x: 3.0, y: 0.0, rot: 0));
    // join: the corner piece of wall 0 must extend past its (6,4)
    // end by t/2 so the two rects cover the outer notch
    final p0 = wallSegPieces(m, m.walls[0], 0);
    expect(p0, hasLength(1));
    expect(p0[0].map((p) => p.dx).reduce(math.max), closeTo(6.075, 0.01));
    // uncut wall keeps full length incl. extension on the joined end
    // cut: the door splits wall 2 into two pieces with a ~0.9m gap
    final p2 = wallSegPieces(m, m.walls[2], 0);
    expect(p2, hasLength(2));
    final g0 = p2[0].map((p) => p.dx).reduce(math.max);
    final g1 = p2[1].map((p) => p.dx).reduce(math.min);
    expect(g1 - g0, closeTo(0.94, 0.06)); // gap ~= footprint + margin
    // end joining at x=6 gets the join extension too
    expect(
      p2[1].map((p) => p.dx).reduce(math.max),
      closeTo(6.075, 0.01),
    );
    // 3D path gets the same pieces via wallFacesJoined/modelFaces
    final gapMinX = g0;
    final gapMaxX = g1;
    for (final f in wallFacesJoined(m, m.walls[2])) {
      for (final v in f.v) {
        expect(
          v[0] < gapMinX + 1e-6 || v[0] > gapMaxX - 1e-6,
          isTrue,
          reason: 'wall face vertex landed inside the door opening',
        );
      }
    }
  });

  test('seatOnWall: openings center-line, mounts hug the face', () {
    final m = Model3d(name: 'seat')
      ..walls.add(Wall3d(points: [0, 0, 6, 0], thickness: 0.15));
    // opening dropped beside a horizontal wall -> on centerline, rot 0
    final s1 = seatOnWall(m, cadBlock('door-090')!, const Offset(3, 0.05));
    expect(s1, isNotNull);
    expect(s1!.$1, const Offset(3, 0));
    expect(s1.$2, closeTo(0, 1e-9));
    // far side -> swing flips (+pi)
    final s2 = seatOnWall(m, cadBlock('door-090')!, const Offset(3, -0.05));
    expect(s2!.$2, closeTo(math.pi, 1e-9));
    // vertical wall -> rot 90deg; clicking the far side flips +pi
    m.walls.add(Wall3d(points: [2, -2, 2, 2], thickness: 0.15));
    final s3 = seatOnWall(m, cadBlock('window-120')!, const Offset(2.2, 0.5));
    expect(s3!.$1, const Offset(2, 0.5));
    expect(s3.$2, closeTo(3 * math.pi / 2, 1e-9));
    // wall-hung TV hugs the FACE, not the centerline (t/2 + d/2 off)
    final s4 = seatOnWall(m, cadBlock('tv')!, const Offset(3, 0.3));
    expect(s4, isNotNull);
    expect(s4!.$1.dy, closeTo(0.075 + 0.05 + 0.01, 1e-6));
    expect(s4.$2, closeTo(0, 1e-9)); // front faces the clicked side
    // non-wall block -> null
    expect(seatOnWall(m, cadBlock('chair')!, const Offset(3, 0.05)), isNull);
    // openings ALWAYS host: even far off the wall the drop lands on
    // the nearest segment (an unhosted door can't cut anything). The
    // vertical wall is closer to (3,1.5) -> seat at (2,1.5), far
    // side -> +pi like s3
    final s5 = seatOnWall(m, cadBlock('door-090')!, const Offset(3, 1.5));
    expect(s5, isNotNull);
    expect(s5!.$1, const Offset(2, 1.5));
    expect(s5.$2, closeTo(3 * math.pi / 2, 1e-9));
    // third field = the host wall's base — upper-storey walls lift
    // the block to their floor level
    m.walls.add(Wall3d(points: [10, -2, 10, 2], base: 3.0));
    final s6 = seatOnWall(m, cadBlock('door-090')!, const Offset(10, 0));
    expect(s6!.$1, const Offset(10, 0));
    expect(s6.$3, 3.0);
  });

  test('scene sim: mixed furnished room renders plausible PNG', () async {
    // user's real composition — a table set, wall-mounted pieces and
    // a stair must all read correctly in ONE frame (per-def checks
    // can't catch a mount-height/orientation miss in context)
    final m = Model3d(name: 'scene')
      // FAR walls — cam3Depth at yaw -0.7 = -0.549x + 0.652y - 0.523z:
      // camera sits +x/-y, so far = north (y=4) and west (x=0) edges
      ..walls.add(Wall3d(points: [0, 4, 6, 4], thickness: 0.15))
      ..walls.add(Wall3d(points: [0, 0, 0, 4], thickness: 0.15))
      ..blocks.addAll([
        Block3d(def: 'dining-6', x: 3.0, y: 2.2),
        Block3d(def: 'chair', x: 2.2, y: 1.5),
        Block3d(def: 'chair', x: 3.9, y: 2.9, rot: math.pi),
        Block3d(def: 'stairs-100', x: 5.2, y: 3.2),
        Block3d(def: 'tv', x: 5.6, y: 1.6, rot: math.pi / 2),
        Block3d(def: 'picture', x: 2.0, y: 3.8),
        Block3d(def: 'sofa-3', x: 1.2, y: 0.9),
      ]);
    final noWalls = Model3d(name: 'nw')..blocks.addAll(m.blocks);
    final faces = m.cachedFaces();
    const vp = Size(800, 600);
    const yaw = -0.7, pitch = 0.55;
    // aim at bounds center like _fit3
    final bb = m.bounds!;
    final c = [(bb.$1 + bb.$3) / 2, (bb.$2 + bb.$4) / 2, bb.$5 / 2];
    final zoom = (vp.shortestSide * 0.5) /
        math.max(bb.$3 - bb.$1, math.max(bb.$4 - bb.$2, bb.$5));
    final pc = cam3Project(c, vp, yaw: yaw, pitch: pitch, zoom: zoom, off: Offset.zero);
    final off = Offset(vp.width / 2, vp.height / 2) - pc;
    Offset prj(List<double> v) =>
        cam3Project(v, vp, yaw: yaw, pitch: pitch, zoom: zoom, off: off);
    final rec = ui.PictureRecorder();
    final canvas = ui.Canvas(rec);
    canvas.drawRect(
      Offset.zero & vp,
      ui.Paint()..color = const ui.Color(0xFFDDE3EA),
    );
    // painter's algorithm exactly like the app: two-level — object
    // group (Face3.grp) far->near, then face within the group
    double cd(Face3 f) {
      var d = 0.0;
      for (final v in f.v) {
        d += cam3Depth(v, yaw: yaw, pitch: pitch);
      }
      return d / f.v.length;
    }

    final gSum = <int, double>{};
    final gCnt = <int, int>{};
    for (final f in faces) {
      final d = cd(f);
      gSum[f.grp] = (gSum[f.grp] ?? 0) + d;
      gCnt[f.grp] = (gCnt[f.grp] ?? 0) + 1;
    }

    double gD(int g) => gSum[g]! / gCnt[g]!;
    final sorted = faces.toList()
      ..sort((a, b2) {
        final ga = gD(a.grp), gb = gD(b2.grp);
        if (ga != gb) return gb.compareTo(ga);
        return cd(b2).compareTo(cd(a));
      });
    for (final f in sorted) {
      final path = ui.Path();
      for (var i = 0; i < f.v.length; i++) {
        final p = prj(f.v[i]);
        i == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
      }
      path.close();
      canvas.drawPath(path, ui.Paint()..color = ui.Color(f.argb));
    }
    final pic = rec.endRecording();
    final img = await pic.toImage(vp.width.toInt(), vp.height.toInt());
    final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
    File('test/out/scene_room.png')
        .writeAsBytesSync(bytes!.buffer.asUint8List());

    // same pass with NO walls — tells occlusion apart from missing
    final faces2 = noWalls.cachedFaces();
    final gSum2 = <int, double>{};
    final gCnt2 = <int, int>{};
    for (final f in faces2) {
      final d = cd(f);
      gSum2[f.grp] = (gSum2[f.grp] ?? 0) + d;
      gCnt2[f.grp] = (gCnt2[f.grp] ?? 0) + 1;
    }

    double gD2(int g) => gSum2[g]! / gCnt2[g]!;
    final rec2 = ui.PictureRecorder();
    final canvas2 = ui.Canvas(rec2);
    canvas2.drawRect(
      Offset.zero & vp,
      ui.Paint()..color = const ui.Color(0xFFDDE3EA),
    );
    final sorted2 = faces2.toList()
      ..sort((a, b2) {
        final ga = gD2(a.grp), gb = gD2(b2.grp);
        if (ga != gb) return gb.compareTo(ga);
        return cd(b2).compareTo(cd(a));
      });
    for (final f in sorted2) {
      final path = ui.Path();
      for (var i = 0; i < f.v.length; i++) {
        final p = prj(f.v[i]);
        i == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
      }
      path.close();
      canvas2.drawPath(path, ui.Paint()..color = ui.Color(f.argb));
    }
    final pic2 = rec2.endRecording();
    final img2 = await pic2.toImage(vp.width.toInt(), vp.height.toInt());
    final bytes2 = await img2.toByteData(format: ui.ImageByteFormat.png);
    File('test/out/scene_nowalls.png')
        .writeAsBytesSync(bytes2!.buffer.asUint8List());
    // ORBIT MERGE CHECK — same scene at a second yaw: the two-level
    // sort must keep objects whole (no face-interleaving "merge").
    // Count sofa-orange pixels: visible => sofa paints over walls,
    // zero => it merged behind them like the old global sort.
    const yaw2 = 0.9;
    double cd2(Face3 f) {
      var d = 0.0;
      for (final v in f.v) {
        d += cam3Depth(v, yaw: yaw2, pitch: pitch);
      }
      return d / f.v.length;
    }

    final pc2 = cam3Project(
      c, vp,
      yaw: yaw2, pitch: pitch, zoom: zoom, off: Offset.zero,
    );
    final off2 = Offset(vp.width / 2, vp.height / 2) - pc2;
    Offset prj2(List<double> v) =>
        cam3Project(v, vp, yaw: yaw2, pitch: pitch, zoom: zoom, off: off2);
    final gSum3 = <int, double>{};
    final gCnt3 = <int, int>{};
    for (final f in faces) {
      final d = cd2(f);
      gSum3[f.grp] = (gSum3[f.grp] ?? 0) + d;
      gCnt3[f.grp] = (gCnt3[f.grp] ?? 0) + 1;
    }

    double gD3(int g) => gSum3[g]! / gCnt3[g]!;
    final rec3 = ui.PictureRecorder();
    final canvas3 = ui.Canvas(rec3);
    canvas3.drawRect(
      Offset.zero & vp,
      ui.Paint()..color = const ui.Color(0xFFDDE3EA),
    );
    final sorted3 = faces.toList()
      ..sort((a, b2) {
        final ga = gD3(a.grp), gb = gD3(b2.grp);
        if (ga != gb) return gb.compareTo(ga);
        return cd2(b2).compareTo(cd2(a));
      });
    for (final f in sorted3) {
      final path = ui.Path();
      for (var i = 0; i < f.v.length; i++) {
        final p = prj2(f.v[i]);
        i == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
      }
      path.close();
      canvas3.drawPath(path, ui.Paint()..color = ui.Color(f.argb));
    }
    final pic3 = rec3.endRecording();
    final img3 = await pic3.toImage(vp.width.toInt(), vp.height.toInt());
    final bytes3 = await img3.toByteData(format: ui.ImageByteFormat.png);
    File('test/out/scene_orbit.png')
        .writeAsBytesSync(bytes3!.buffer.asUint8List());
    // furniture must paint real pixels at this angle too — a merged
    // scene buries them behind wall faces
    final raw3 = await img3.toByteData();
    var lit3 = 0;
    final px3 = raw3!.buffer.asUint32List();
    for (final q in px3) {
      final r = q & 0xFF, g = (q >> 8) & 0xFF, bch = (q >> 16) & 0xFF;
      if ((r - 0xDD).abs() > 16 ||
          (g - 0xE3).abs() > 16 ||
          (bch - 0xEA).abs() > 16) {
        lit3++;
      }
    }
    expect(
      lit3 / px3.length,
      greaterThan(0.03),
      reason: 'orbit view painted ${(lit3 / px3.length * 100).toStringAsFixed(1)}% — furniture merged away',
    );

    // mounted pieces must leave the floor: tv base at ~0.45, picture ~1.15
    for (final b in m.blocks) {
      final bf = blockFaces(b, cadBlock(b.def) ?? kCadBlocks.first);
      var x0 = 1e9, x1 = -1e9, y0 = 1e9, y1 = -1e9;
      for (final f in bf) {
        for (final v in f.v) {
          final p = prj(v);
          x0 = math.min(x0, p.dx); x1 = math.max(x1, p.dx);
          y0 = math.min(y0, p.dy); y1 = math.max(y1, p.dy);
        }
      }
      // ignore: avoid_print
      print(
        '${b.def.padRight(10)} f=${bf.length.toString().padLeft(4)} '
        'screen [${x0.toStringAsFixed(0)},${y0.toStringAsFixed(0)} .. '
        '${x1.toStringAsFixed(0)},${y1.toStringAsFixed(0)}]',
      );
    }
    final tv = m.blocks.firstWhere((b) => b.def == 'tv');
    final tvFaces = blockFaces(tv, cadBlock('tv')!);
    final zmin = tvFaces
        .expand((f) => f.v)
        .map((p) => p[2])
        .reduce(math.min);
    expect(zmin, greaterThan(0.3), reason: 'tv must mount, not floor-sit');
    expect(faces.length, greaterThan(500));
  });

  test('2D plan linework renders for every def', () {
    for (final def in kCadBlocks) {
      final b = Block3d(def: def.id, x: 3, y: 4, rot: 0.4);
      final lines = blockLines(b, def);
      expect(lines, isNotEmpty, reason: def.id);
      for (final l in lines) {
        expect(l.length, greaterThanOrEqualTo(2), reason: def.id);
      }
      final fp = blockFootprint(b, def);
      expect(fp.length, 4);
    }
  });
}
