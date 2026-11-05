import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart' show Offset, Size;
import 'package:flutter_test/flutter_test.dart';
import 'package:tantyahin/model3d.dart';
import 'package:tantyahin/ui/model_view.dart';

/// 3D PAINTER PERFORMANCE CAMPAIGN — measures the real projection/sort/
/// paint pipeline on a heavy user-scale project and compares candidate
/// acceleration arms before/after integration. Mirrors the mycall
/// campaign methodology: arms are falsifiable, numbers are real
/// Stopwatch measurements on the same model, same camera.
///
/// The scene approximates a furnished small house: structural shell +
/// GEALAN BIM windows (~3.5k faces each) + car + furniture — on the
/// order of 20k faces, the workload that made the 3D view lag.
void main() {
  setUpAll(() async {
    await preloadBlockMeshes((p) => File(p).readAsString());
  });

  Model3d heavyModel() {
    return Model3d(name: 'perf-house')
      ..volumes.add(
        Volume3d(
          footprint: [0, 0, 10, 0, 10, 7, 0, 7],
          base: -0.15,
          height: 0.15,
        ),
      )
      ..walls.addAll([
        Wall3d(points: [0, 0, 10, 0], thickness: 0.2),
        Wall3d(points: [10, 0, 10, 7], thickness: 0.2),
        Wall3d(points: [10, 7, 0, 7], thickness: 0.2),
        Wall3d(points: [0, 7, 0, 0], thickness: 0.2),
        Wall3d(points: [5, 0, 5, 4.2], thickness: 0.15),
        Wall3d(points: [5, 5.4, 5, 7], thickness: 0.15),
        Wall3d(points: [5, 4.2, 8, 4.2], thickness: 0.15),
      ])
      ..blocks.addAll([
        Block3d(def: 'door-slide-2500x2200', x: 2.5, y: 0.0),
        Block3d(def: 'door-slide-2800x2000', x: 7.5, y: 7.0, rot: math.pi),
        // procedural doors are ~84 faces vs the old multi-thousand
        // IFC meshes — the heavy warehouse blocks keep the fixture
        // in its intended ~15-20k face range
        Block3d(def: 'door-glass', x: 10.0, y: 5.0, rot: -math.pi / 2),
        Block3d(def: 'car', x: -2.5, y: 1.5, rot: 0.9),
        Block3d(def: 'tub', x: 6.6, y: 6.4),
        Block3d(def: 'door-wood', x: 5.0, y: 4.7, rot: math.pi / 2),
        Block3d(def: 'door-090', x: 0.0, y: 3.5, rot: -math.pi / 2),
        Block3d(def: 'window-slide', x: 10.0, y: 3.0, rot: math.pi / 2),
        Block3d(def: 'car', x: 12.5, y: 3.5, rot: 0.3),
        Block3d(def: 'tree', x: 11.5, y: 6.2),
        Block3d(def: 'tree', x: -1.2, y: 5.8),
        Block3d(def: 'dining-6', x: 2.5, y: 2.4),
        Block3d(def: 'chair', x: 1.9, y: 1.8),
        Block3d(def: 'chair', x: 3.1, y: 3.0, rot: math.pi),
        Block3d(def: 'sofa-3', x: 8.0, y: 5.8, rot: math.pi),
        Block3d(def: 'tv', x: 9.6, y: 5.0, rot: math.pi / 2),
        Block3d(def: 'bed-dbl', x: 2.0, y: 5.6),
        Block3d(def: 'wardrobe', x: 4.2, y: 6.6),
        Block3d(def: 'wc', x: 6.4, y: 5.2),
        Block3d(def: 'basin', x: 7.4, y: 5.2),
        Block3d(def: 'stove', x: 8.8, y: 0.8),
        Block3d(def: 'fridge', x: 9.5, y: 1.6),
        Block3d(def: 'stairs-100', x: 0.8, y: 0.8),
      ]);
  }

  const vp = Size(900, 640);
  const yaw = -0.7, pitch = 0.55;

  /// The CURRENT production pipeline, verbatim: per-vertex trig inside
  /// cam3Project/cam3Depth, a full depth pass for sorting, then a full
  /// projection pass for paths, with per-face Path/Paint/Color allocs.
  /// This is arm A0 — the baseline every candidate must beat.
  int paintBaseline(List<Face3> faces, ui.Canvas canvas) {
    const zoom = 42.0;
    const off = Offset(60, 40);
    final pivot = [5.0, 3.5, 1.35];
    final gMax = <int, double>{};
    final keyed = <(double, Face3)>[];
    for (final f in faces) {
      var d = -double.infinity;
      for (final p in f.v) {
        final q = cam3Depth(p, yaw: yaw, pitch: pitch, pivot: pivot);
        if (q > d) d = q;
      }
      keyed.add((d, f));
      if (d > (gMax[f.grp] ?? -double.infinity)) gMax[f.grp] = d;
    }
    double gD(int g) => gMax[g]!;
    keyed.sort((a, b) {
      final ga = gD(a.$2.grp), gb = gD(b.$2.grp);
      if (ga != gb) return gb.compareTo(ga);
      return b.$1.compareTo(a.$1);
    });
    var painted = 0;
    for (final (_, f) in keyed) {
      final path = ui.Path();
      var x0 = double.infinity, y0 = double.infinity;
      var x1 = -double.infinity, y1 = -double.infinity;
      for (var i = 0; i < f.v.length; i++) {
        final p = cam3Project(
          f.v[i],
          vp,
          yaw: yaw,
          pitch: pitch,
          zoom: zoom,
          off: off,
          pivot: pivot,
        );
        x0 = math.min(x0, p.dx);
        y0 = math.min(y0, p.dy);
        x1 = math.max(x1, p.dx);
        y1 = math.max(y1, p.dy);
        i == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
      }
      path.close();
      if ((x1 - x0) * (y1 - y0) < 1.2) continue;
      canvas.drawPath(path, ui.Paint()..color = ui.Color(f.argb));
      painted++;
    }
    return painted;
  }

  /// Arm A2 MATERIALIZED-FUSED (falsified): one pass computes depth +
  /// screen into a per-face List<Offset> — the 15k list allocations
  /// cost ~4x more than the double-projection it saves. Kept as the
  /// campaign's documented reject.
  int paintFusedMaterialize(List<Face3> faces, ui.Canvas canvas) {
    const zoom = 42.0;
    const off = Offset(60, 40);
    const px = 5.0, py = 3.5, pz = 1.35;
    final cy = math.cos(yaw), sy = math.sin(yaw);
    final cp = math.cos(pitch), sp = math.sin(pitch);
    final cx = vp.width / 2 + off.dx, cyy = vp.height / 2 + off.dy;
    final keyed = <(double, Face3, List<Offset>)>[];
    final gMax = <int, double>{};
    for (final f in faces) {
      var d = -double.infinity;
      final pts = List<Offset>.filled(f.v.length, Offset.zero);
      for (var i = 0; i < f.v.length; i++) {
        final p = f.v[i];
        final dx = p[0] - px, dy = p[1] - py, dz = p[2] - pz;
        final rx = dx * cy - dy * sy;
        final ry = dx * sy + dy * cy;
        final dep = ry * cp - dz * sp;
        if (dep > d) d = dep;
        pts[i] = Offset(cx + rx * zoom, cyy - (ry * sp + dz * cp) * zoom);
      }
      keyed.add((d, f, pts));
      if (d > (gMax[f.grp] ?? -double.infinity)) gMax[f.grp] = d;
    }
    double gD(int g) => gMax[g]!;
    keyed.sort((a, b) {
      final ga = gD(a.$2.grp), gb = gD(b.$2.grp);
      if (ga != gb) return gb.compareTo(ga);
      return b.$1.compareTo(a.$1);
    });
    var painted = 0;
    final paint = ui.Paint();
    for (final (_, f, pts) in keyed) {
      var x0 = double.infinity, y0 = double.infinity;
      var x1 = -double.infinity, y1 = -double.infinity;
      for (final p in pts) {
        x0 = math.min(x0, p.dx);
        y0 = math.min(y0, p.dy);
        x1 = math.max(x1, p.dx);
        y1 = math.max(y1, p.dy);
      }
      if ((x1 - x0) * (y1 - y0) < 1.2) continue;
      if (x1 < 0 || y1 < 0 || x0 > vp.width || y0 > vp.height) continue;
      final path = ui.Path()..addPolygon(pts, true);
      canvas.drawPath(path, paint..color = ui.Color(f.argb));
      painted++;
    }
    return painted;
  }

  /// Arm A9 LEAN-HOIST: identical structure to baseline — separate
  /// depth pass then Path-building project pass, ZERO extra allocs —
  /// but with trig hoisted to per-frame constants. The safe miss-path
  /// win: strictly less work than A0 with no structural risk.
  int paintLeanHoist(List<Face3> faces, ui.Canvas canvas) {
    const zoom = 42.0;
    const off = Offset(60, 40);
    const px = 5.0, py = 3.5, pz = 1.35;
    final cy = math.cos(yaw), sy = math.sin(yaw);
    final cp = math.cos(pitch), sp = math.sin(pitch);
    final cx = vp.width / 2 + off.dx, cyy = vp.height / 2 + off.dy;
    double dep(List<double> p) =>
        ((p[0] - px) * sy + (p[1] - py) * cy) * cp - (p[2] - pz) * sp;
    final gMax = <int, double>{};
    final keyed = <(double, Face3)>[];
    for (final f in faces) {
      var d = -double.infinity;
      for (final p in f.v) {
        final q = dep(p);
        if (q > d) d = q;
      }
      keyed.add((d, f));
      if (d > (gMax[f.grp] ?? -double.infinity)) gMax[f.grp] = d;
    }
    double gD(int g) => gMax[g]!;
    keyed.sort((a, b) {
      final ga = gD(a.$2.grp), gb = gD(b.$2.grp);
      if (ga != gb) return gb.compareTo(ga);
      return b.$1.compareTo(a.$1);
    });
    var painted = 0;
    final paint = ui.Paint();
    for (final (_, f) in keyed) {
      final path = ui.Path();
      var x0 = double.infinity, y0 = double.infinity;
      var x1 = -double.infinity, y1 = -double.infinity;
      for (var i = 0; i < f.v.length; i++) {
        final p = f.v[i];
        final dx = p[0] - px, dy = p[1] - py, dz = p[2] - pz;
        final rx = dx * cy - dy * sy;
        final ry = dx * sy + dy * cy;
        final ox = cx + rx * zoom;
        final oy = cyy - (ry * sp + dz * cp) * zoom;
        x0 = math.min(x0, ox);
        y0 = math.min(y0, oy);
        x1 = math.max(x1, ox);
        y1 = math.max(y1, oy);
        i == 0 ? path.moveTo(ox, oy) : path.lineTo(ox, oy);
      }
      path.close();
      if ((x1 - x0) * (y1 - y0) < 1.2) continue;
      if (x1 < 0 || y1 < 0 || x0 > vp.width || y0 > vp.height) continue;
      canvas.drawPath(path, paint..color = ui.Color(f.argb));
      painted++;
    }
    return painted;
  }

  /// Arm A8 BATCHED VERTICES: every solid face fans into ONE
  /// canvas.drawVertices call — ~15k drawPath ops collapse to a
  /// single draw call with flat per-vertex colors (fill path only;
  /// draft-mode strokes still need per-face paths).
  int paintBatched(List<Face3> faces, ui.Canvas canvas) {
    const zoom = 42.0;
    const off = Offset(60, 40);
    const px = 5.0, py = 3.5, pz = 1.35;
    final cy = math.cos(yaw), sy = math.sin(yaw);
    final cp = math.cos(pitch), sp = math.sin(pitch);
    final cx = vp.width / 2 + off.dx, cyy = vp.height / 2 + off.dy;
    double dep(List<double> p) =>
        ((p[0] - px) * sy + (p[1] - py) * cy) * cp - (p[2] - pz) * sp;
    final gMax = <int, double>{};
    final keyed = <(double, Face3)>[];
    for (final f in faces) {
      var d = -double.infinity;
      for (final p in f.v) {
        final q = dep(p);
        if (q > d) d = q;
      }
      keyed.add((d, f));
      if (d > (gMax[f.grp] ?? -double.infinity)) gMax[f.grp] = d;
    }
    double gD(int g) => gMax[g]!;
    keyed.sort((a, b) {
      final ga = gD(a.$2.grp), gb = gD(b.$2.grp);
      if (ga != gb) return gb.compareTo(ga);
      return b.$1.compareTo(a.$1);
    });
    // fan-triangulate every convex face into flat positions+colors —
    // ONE drawVertices replaces all per-face drawPath fills
    var tris = 0;
    for (final (_, f) in keyed) {
      tris += f.v.length - 2;
    }
    final pos = Float32List(tris * 6);
    final col = Int32List(tris * 3);
    var ti = 0, ci = 0, painted = 0;
    final pts = List<Offset>.filled(8, Offset.zero);
    for (final (_, f) in keyed) {
      final nv = f.v.length;
      while (pts.length < nv) {
        pts.add(Offset.zero);
      }
      var x0 = double.infinity, y0 = double.infinity;
      var x1 = -double.infinity, y1 = -double.infinity;
      for (var i = 0; i < nv; i++) {
        final p = f.v[i];
        final dx = p[0] - px, dy = p[1] - py, dz = p[2] - pz;
        final rx = dx * cy - dy * sy;
        final ry = dx * sy + dy * cy;
        final ox = cx + rx * zoom;
        final oy = cyy - (ry * sp + dz * cp) * zoom;
        x0 = math.min(x0, ox);
        y0 = math.min(y0, oy);
        x1 = math.max(x1, ox);
        y1 = math.max(y1, oy);
        pts[i] = Offset(ox, oy);
      }
      if ((x1 - x0) * (y1 - y0) < 1.2) continue;
      if (x1 < 0 || y1 < 0 || x0 > vp.width || y0 > vp.height) continue;
      for (var t = 2; t < nv; t++) {
        pos[ti++] = pts[0].dx;
        pos[ti++] = pts[0].dy;
        pos[ti++] = pts[t - 1].dx;
        pos[ti++] = pts[t - 1].dy;
        pos[ti++] = pts[t].dx;
        pos[ti++] = pts[t].dy;
        col[ci++] = f.argb;
        col[ci++] = f.argb;
        col[ci++] = f.argb;
      }
      painted++;
    }
    if (ti > 0) {
      canvas.drawVertices(
        ui.Vertices(
          ui.VertexMode.triangles,
          List.generate(ti ~/ 2, (i) => Offset(pos[i * 2], pos[i * 2 + 1])),
          colors: List.generate(ci, (i) => ui.Color(col[i])),
        ),
        ui.BlendMode.srcOver,
        ui.Paint(),
      );
    }
    return painted;
  }

  /// Arm A5: post-transform vertex cache — hash-keyed screen point
  /// reuse for shared verts (arXiv 1805.08893 idea, measured honestly).
  int paintVertexCache(List<Face3> faces, ui.Canvas canvas) {
    const zoom = 42.0;
    const off = Offset(60, 40);
    const px = 5.0, py = 3.5, pz = 1.35;
    final cy = math.cos(yaw), sy = math.sin(yaw);
    final cp = math.cos(pitch), sp = math.sin(pitch);
    final cx = vp.width / 2 + off.dx, cyy = vp.height / 2 + off.dy;
    final vcache = <List<double>, Offset>{};
    Offset prj(List<double> p) {
      return vcache.putIfAbsent(p, () {
        final dx = p[0] - px, dy = p[1] - py, dz = p[2] - pz;
        final rx = dx * cy - dy * sy;
        final ry = dx * sy + dy * cy;
        return Offset(cx + rx * zoom, cyy - (ry * sp + dz * cp) * zoom);
      });
    }

    final gMax = <int, double>{};
    final keyed = <(double, Face3)>[];
    for (final f in faces) {
      var d = -double.infinity;
      for (final p in f.v) {
        final q = cam3Depth(p, yaw: yaw, pitch: pitch, pivot: [px, py, pz]);
        if (q > d) d = q;
      }
      keyed.add((d, f));
      if (d > (gMax[f.grp] ?? -double.infinity)) gMax[f.grp] = d;
    }
    double gD(int g) => gMax[g]!;
    keyed.sort((a, b) {
      final ga = gD(a.$2.grp), gb = gD(b.$2.grp);
      if (ga != gb) return gb.compareTo(ga);
      return b.$1.compareTo(a.$1);
    });
    var painted = 0;
    for (final (_, f) in keyed) {
      final path = ui.Path();
      for (var i = 0; i < f.v.length; i++) {
        final p = prj(f.v[i]);
        i == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
      }
      path.close();
      canvas.drawPath(path, ui.Paint()..color = ui.Color(f.argb));
      painted++;
    }
    return painted;
  }

  /// Arm A6: quantized trig LUT (mycall PSU-HQ analog) — sin/cos via
  /// table lookup instead of libm, still per-vertex.
  int paintTrigLut(List<Face3> faces, ui.Canvas canvas) {
    const zoom = 42.0;
    const off = Offset(60, 40);
    const px = 5.0, py = 3.5, pz = 1.35;
    const n = 4096;
    final lut = List<double>.generate(n, (i) => math.sin(i * 2 * math.pi / n));
    double fsin(double a) => lut[((a * n / (2 * math.pi)).round()) & (n - 1)];
    double fcos(double a) =>
        lut[(((a * n / (2 * math.pi)).round()) + n ~/ 4) & (n - 1)];
    final cy = fcos(yaw), sy = fsin(yaw);
    final cp = fcos(pitch), sp = fsin(pitch);
    final cx = vp.width / 2 + off.dx, cyy = vp.height / 2 + off.dy;
    final gMax = <int, double>{};
    final keyed = <(double, Face3)>[];
    for (final f in faces) {
      var d = -double.infinity;
      for (final p in f.v) {
        final dx = p[0] - px, dy = p[1] - py, dz = p[2] - pz;
        final ry = dx * sy + dy * cy;
        final q = ry * cp - dz * sp;
        if (q > d) d = q;
      }
      keyed.add((d, f));
      if (d > (gMax[f.grp] ?? -double.infinity)) gMax[f.grp] = d;
    }
    double gD(int g) => gMax[g]!;
    keyed.sort((a, b) {
      final ga = gD(a.$2.grp), gb = gD(b.$2.grp);
      if (ga != gb) return gb.compareTo(ga);
      return b.$1.compareTo(a.$1);
    });
    var painted = 0;
    for (final (_, f) in keyed) {
      final path = ui.Path();
      for (var i = 0; i < f.v.length; i++) {
        final p = f.v[i];
        final dx = p[0] - px, dy = p[1] - py, dz = p[2] - pz;
        final rx = dx * cy - dy * sy;
        final ry = dx * sy + dy * cy;
        final o = Offset(cx + rx * zoom, cyy - (ry * sp + dz * cp) * zoom);
        i == 0 ? path.moveTo(o.dx, o.dy) : path.lineTo(o.dx, o.dy);
      }
      path.close();
      canvas.drawPath(path, ui.Paint()..color = ui.Color(f.argb));
      painted++;
    }
    return painted;
  }

  /// Arm A7: backface culling — drop faces whose camera-space normal
  /// points away. Measured for the savings; flagged for the winding
  /// correctness risk on open geometry.
  int paintBackface(List<Face3> faces, ui.Canvas canvas) {
    const zoom = 42.0;
    const off = Offset(60, 40);
    const px = 5.0, py = 3.5, pz = 1.35;
    final cy = math.cos(yaw), sy = math.sin(yaw);
    final cp = math.cos(pitch), sp = math.sin(pitch);
    final cx = vp.width / 2 + off.dx, cyy = vp.height / 2 + off.dy;
    final gMax = <int, double>{};
    final keyed = <(double, Face3)>[];
    for (final f in faces) {
      // camera-space normal depth — negative = facing away
      final nx = f.n[0], ny = f.n[1], nz = f.n[2];
      final nry = nx * sy + ny * cy;
      if (nry * cp - nz * sp < 0) continue;
      var d = -double.infinity;
      final pts = List<Offset>.filled(f.v.length, Offset.zero);
      for (var i = 0; i < f.v.length; i++) {
        final p = f.v[i];
        final dx = p[0] - px, dy = p[1] - py, dz = p[2] - pz;
        final rx = dx * cy - dy * sy;
        final ry = dx * sy + dy * cy;
        final dep = ry * cp - dz * sp;
        if (dep > d) d = dep;
        pts[i] = Offset(cx + rx * zoom, cyy - (ry * sp + dz * cp) * zoom);
      }
      keyed.add((d, f));
      if (d > (gMax[f.grp] ?? -double.infinity)) gMax[f.grp] = d;
    }
    double gD(int g) => gMax[g]!;
    keyed.sort((a, b) {
      final ga = gD(a.$2.grp), gb = gD(b.$2.grp);
      if (ga != gb) return gb.compareTo(ga);
      return b.$1.compareTo(a.$1);
    });
    var painted = 0;
    for (final (_, f) in keyed) {
      canvas.drawPath(
        ui.Path()..addPolygon(
          f.v.map((p) {
            final dx = p[0] - px, dy = p[1] - py, dz = p[2] - pz;
            final rx = dx * cy - dy * sy;
            final ry = dx * sy + dy * cy;
            return Offset(cx + rx * zoom, cyy - (ry * sp + dz * cp) * zoom);
          }).toList(),
          true,
        ),
        ui.Paint()..color = ui.Color(f.argb),
      );
      painted++;
    }
    return painted;
  }

  double bench(String label, int Function(ui.Canvas) run, {int iters = 30}) {
    final rec = ui.PictureRecorder();
    final canvas = ui.Canvas(rec);
    // warmup
    run(canvas);
    final sw = Stopwatch()..start();
    for (var i = 0; i < iters; i++) {
      run(canvas);
    }
    sw.stop();
    final us = sw.elapsedMicroseconds / iters;
    // ignore: avoid_print
    print('${label.padRight(34)} ${(us / 1000).toStringAsFixed(2)} ms/frame');
    return us;
  }

  test('PERF CAMPAIGN: candidate arms on a 20k-face project', () {
    final m = heavyModel();
    final faces = m.cachedFaces();
    var verts = 0;
    for (final f in faces) {
      verts += f.v.length;
    }
    // ignore: avoid_print
    print('model: ${faces.length} faces, $verts verts');

    final a0 = bench(
      'A0 baseline (current 2-pass)',
      (c) => paintBaseline(faces, c),
    );
    final a2 = bench(
      'A2 fused+materialize pts',
      (c) => paintFusedMaterialize(faces, c),
    );
    final a9 = bench(
      'A9 lean-hoist (no allocs)',
      (c) => paintLeanHoist(faces, c),
    );
    final a8 = bench('A8 batched drawVertices', (c) => paintBatched(faces, c));
    final a5 = bench('A5 vertex-dedup map', (c) => paintVertexCache(faces, c));
    final a6 = bench('A6 trig LUT 4096', (c) => paintTrigLut(faces, c));
    final a7 = bench('A7 backface cull', (c) => paintBackface(faces, c));

    // Arm A4: epoch Picture cache — the recorded frame replayed as ONE
    // drawPicture; the honest number for every camera-UNCHANGED repaint
    // (hover, cursor blink, selection chrome, status ticks)
    final rec = ui.PictureRecorder();
    final cRec = ui.Canvas(rec);
    paintLeanHoist(faces, cRec);
    final pic = rec.endRecording();
    final rec2 = ui.PictureRecorder();
    final c2 = ui.Canvas(rec2);
    var n = 0;
    final sw = Stopwatch()..start();
    for (var i = 0; i < 300; i++) {
      c2.drawPicture(pic);
      n++;
    }
    sw.stop();
    final a4 = sw.elapsedMicroseconds / n;
    // ignore: avoid_print
    print(
      '${'A4 epoch Picture cache (hit)'.padRight(34)} ${(a4 / 1000).toStringAsFixed(2)} ms/frame',
    );
    pic.dispose();

    // ignore: avoid_print
    print(
      'speedups: fused=${(a0 / a2).toStringAsFixed(1)}x  '
      'lean=${(a0 / a9).toStringAsFixed(1)}x  '
      'batched=${(a0 / a8).toStringAsFixed(1)}x  '
      'vtxcache=${(a0 / a5).toStringAsFixed(1)}x  '
      'lut=${(a0 / a6).toStringAsFixed(1)}x  '
      'backface=${(a0 / a7).toStringAsFixed(1)}x  '
      'epochHit=${(a0 / a4).toStringAsFixed(1)}x',
    );
    // the winners must actually win — the campaign is falsifiable:
    // lean-hoist and the epoch cache are the shipped arms
    expect(a9, lessThan(a0), reason: 'lean-hoist must beat baseline');
    expect(a4, lessThan(a0), reason: 'epoch cache hit must beat baseline');
  });
}
