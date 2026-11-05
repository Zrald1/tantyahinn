import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart' show Offset, Size;
import 'package:flutter_test/flutter_test.dart';
import 'package:tantyahin/model3d.dart';
import 'package:tantyahin/ui/model_view.dart';

/// Repro for the user's screenshot: a wall ending ON another wall at a
/// non-90deg angle used to leave a triangular wedge notch — the join
/// extension was a FIXED t/2 perpendicular cap, which only reaches
/// t/2*sin(theta) into the joined wall. Fix = miter reach: extend the
/// cap along the seg's own direction until it crosses the joined wall's
/// FAR edge (s = t_other/(2*sin)). At 90deg this equals the old t/2.
void main() {
  setUpAll(() async {
    await preloadBlockMeshes((p) => File(p).readAsString());
  });

  test('angled T-junction: cap reaches the through-wall far edge', () {
    final m = Model3d(name: 'junction')
      ..walls.addAll([
        Wall3d(points: [0, 0, 8, 0], thickness: 0.2), // through wall
        // 45deg joiner ending on the centerline at (4,0)
        Wall3d(points: [1, 3, 4, 0], thickness: 0.2),
      ]);
    final spans = wallSegSpans(m, m.walls[1], 0);
    final len = math.sqrt(9.0 + 9.0); // |(3,-3)|
    // needed reach: t/(2 sin45) = 0.1414 past the end
    expect(spans, hasLength(1));
    expect(spans.single.$2, greaterThan(len + 0.12),
        reason: '45deg join must extend ~0.141 past the end, not 0.1');
    expect(spans.single.$2, lessThan(len + 0.20));
  });

  test('90deg junction unchanged (still t_other/2)', () {
    final m = Model3d(name: 'corner90')
      ..walls.addAll([
        Wall3d(points: [0, 0, 6, 0], thickness: 0.15),
        Wall3d(points: [6, 0, 6, 4], thickness: 0.15),
      ]);
    final spans = wallSegSpans(m, m.walls[0], 0);
    expect(spans.single.$2, closeTo(6.075, 1e-9));
  });

  test('dense wedge coverage: no uncovered point inside the strips', () {
    final m = Model3d(name: 'wedge')
      ..walls.addAll([
        Wall3d(points: [0, 0, 8, 0], thickness: 0.2),
        Wall3d(points: [1, 3, 4, 0], thickness: 0.2), // 45deg
        Wall3d(points: [6.4, 2.2, 6.05, 0], thickness: 0.2), // ~80deg-ish
      ]);

    bool covered(Offset q) {
      for (final w in m.walls) {
        for (var i = 0; i < w.segs; i++) {
          for (final poly in wallSegPieces(m, w, i)) {
            var pos = 0, neg = 0;
            for (var e = 0; e < poly.length; e++) {
              final a = poly[e], b = poly[(e + 1) % poly.length];
              final cr = (b.dx - a.dx) * (q.dy - a.dy) -
                  (b.dy - a.dy) * (q.dx - a.dx);
              if (cr > 1e-9) pos++;
              if (cr < -1e-9) neg++;
            }
            if (pos == 0 || neg == 0) return true;
          }
        }
      }
      return false;
    }

    // insideStrip: q within t/2 of a wall centerline AND within that
    // seg's span (plus the join reach) — these MUST all be covered,
    // else the top cap shows the slab through a wedge (the screenshot)
    bool inStrip(Offset q, Wall3d w, int i) {
      final a = Offset(w.pts[i * 2], w.pts[i * 2 + 1]);
      final b = Offset(w.pts[i * 2 + 2], w.pts[i * 2 + 3]);
      final s = b - a;
      final l2 = s.dx * s.dx + s.dy * s.dy;
      if (l2 < 1e-9) return false;
      final t = ((q.dx - a.dx) * s.dx + (q.dy - a.dy) * s.dy) / l2;
      if (t < 0 || t > 1) return false; // free-end caps: [0,len] only
      final c = a + s * t;
      return (q - c).distance <= w.thickness / 2;
    }

    final missed = <Offset>[];
    for (var x = 0.5; x < 7.5; x += 0.04) {
      for (var y = -0.3; y < 3.1; y += 0.04) {
        final q = Offset(x, y);
        var inside = false;
        for (final w in m.walls) {
          for (var i = 0; i < w.segs; i++) {
            if (inStrip(q, w, i)) inside = true;
          }
        }
        if (inside && !covered(q)) missed.add(q);
      }
    }
    expect(missed, isEmpty,
        reason: 'wedge notch: ${missed.length} uncovered points, '
            'e.g. ${missed.take(4).toList()}');
  });

  test('opening near a junction still cuts and ends cleanly', () {
    final m = Model3d(name: 'open-join')
      ..walls.addAll([
        Wall3d(points: [0, 0, 8, 0], thickness: 0.2),
        Wall3d(points: [1, 3, 4, 0], thickness: 0.2),
      ])
      ..blocks.add(Block3d(def: 'door-090', x: 2.0, y: 0.0));
    final spans = wallSegSpans(m, m.walls[0], 0);
    // door cuts the through wall; joined END (x=8 side? no — (0,0)
    // and (8,0) are free ends; the join is on wall1's end) — through
    // wall has no joined ends, expect [0..cutLo],[cutHi..8]
    expect(spans, hasLength(2));
    expect(spans[0].$1, 0.0);
    expect(spans[1].$2, 8.0);
    // pieces must be simple convex rects (no self-intersection)
    for (final p in wallSegPieces(m, m.walls[0], 0)) {
      expect(p, hasLength(4));
    }
  });

  test('raster: angled junction renders solid — PNG check', () async {
    final m = Model3d(name: 'junction-render')
      ..volumes.add(
        // modest slab; the through wall runs PAST its far edge — the
        // wall's far vertex then outranks the slab's group key, the
        // wall paints first, and the slab's top face overdrows its
        // cap mid-span = the beige "cut" in the user's screenshot
        Volume3d(
            footprint: [-2, -3, 9, -3, 9, 5, -2, 5],
            base: -0.15,
            height: 0.15),
      )
      ..walls.addAll([
        Wall3d(points: [0, 0, 8, 0], thickness: 0.2),
        Wall3d(points: [1, 3, 4, 0], thickness: 0.2), // the 45deg case
        Wall3d(points: [6.5, 2.0, 6.1, 0], thickness: 0.2),
        // long wall running well past the slab's far edge
        Wall3d(points: [2, 0.8, 14, 10], thickness: 0.2),
      ]);
    final faces = m.cachedFaces();
    const vp = Size(900, 640);
    const yaw = -0.7, pitch = 0.62;
    final bb = m.bounds!;
    final c = [(bb.$1 + bb.$3) / 2, (bb.$2 + bb.$4) / 2, bb.$5 / 2];
    final zoom = vp.shortestSide * 0.7 /
        math.max(bb.$3 - bb.$1, math.max(bb.$4 - bb.$2, bb.$5));
    final pc =
        cam3Project(c, vp, yaw: yaw, pitch: pitch, zoom: zoom, off: Offset.zero);
    final off = Offset(vp.width / 2, vp.height / 2) - pc;
    Offset prj(List<double> v) =>
        cam3Project(v, vp, yaw: yaw, pitch: pitch, zoom: zoom, off: off);
    double dep(List<double> v) => cam3Depth(v, yaw: yaw, pitch: pitch);
    final gNear = <int, double>{};
    final gMax = <int, double>{};
    final keyed = <(double, Face3)>[];
    for (final f in faces) {
      var d = -double.infinity, dn = double.infinity;
      for (final p in f.v) {
        final q = dep(p);
        if (q > d) d = q;
        if (q < dn) dn = q;
      }
      keyed.add((d, f));
      if (d > (gMax[f.grp] ?? -double.infinity)) gMax[f.grp] = d;
      if (dn < (gNear[f.grp] ?? double.infinity)) gNear[f.grp] = dn;
    }
    // mirrors _SolidPainter's overlap-split rule (keep in sync):
    // the larger member of each overlapping depth-range pair is
    // de-atomized to per-face sorting; the smallest stays atomic
    double span(int g) => gMax[g]! - gNear[g]!;
    bool overlap(int a, int b) =>
        gNear[a]! < gMax[b]! + 1e-6 && gNear[b]! < gMax[a]! + 1e-6;
    final splitG = <int>{};
    for (final gx in gMax.keys) {
      for (final gy in gMax.keys) {
        if (gy == gx || !overlap(gx, gy)) continue;
        if (span(gy) <= span(gx) * 1.25) {
          splitG.add(gx);
          break;
        }
      }
    }
    keyed.sort((a, b) {
      final ka = splitG.contains(a.$2.grp) ? a.$1 : gMax[a.$2.grp]!;
      final kb = splitG.contains(b.$2.grp) ? b.$1 : gMax[b.$2.grp]!;
      if (ka != kb) return kb.compareTo(ka);
      return b.$1.compareTo(a.$1);
    });
    final rec = ui.PictureRecorder();
    final canvas = ui.Canvas(rec);
    canvas.drawRect(Offset.zero & vp, ui.Paint()..color = const ui.Color(0xFFF2EDE4));
    for (final (_, f) in keyed) {
      final path = ui.Path();
      for (var i = 0; i < f.v.length; i++) {
        final p = prj(f.v[i]);
        i == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
      }
      path.close();
      canvas.drawPath(path, ui.Paint()..color = ui.Color(f.argb));
    }
    final img = await rec.endRecording().toImage(900, 640);
    final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
    Directory('test/out').createSync(recursive: true);
    File('test/out/junction.png').writeAsBytesSync(bytes!.buffer.asUint8List());

    // pixel assert: the long wall's cap must be VISIBLE — count
    // pixels close to the wall argb (0xFF90A4AE) vs the slab argb
    // (0xFFB0BEC5) along the wall's mid-span projection. Under the
    // old atomic-group sort the slab top face overdraws the wall and
    // the wall-pixel count collapses toward zero.
    final raw = await img.toByteData();
    int near(ui.Color c, int r, int g, int b) {
      return ((r - (c.r * 255).round()).abs() +
                  (g - (c.g * 255).round()).abs() +
                  (b - (c.b * 255).round()).abs() <
              60)
          ? 1
          : 0;
    }

    var wallPx = 0, slabPx = 0;
    const wallC = ui.Color(0xFF90A4AE), slabC = ui.Color(0xFFB0BEC5);
    for (var y = 0; y < 640; y++) {
      for (var x = 0; x < 900; x++) {
        final i = (y * 900 + x) * 4;
        wallPx += near(
            wallC, raw!.getUint8(i), raw.getUint8(i + 1), raw.getUint8(i + 2));
        slabPx += near(
            slabC, raw.getUint8(i), raw.getUint8(i + 1), raw.getUint8(i + 2));
      }
    }
    // four 2.7m walls over the slab must out-cover it in wall color;
    // a swallowed wall would show as slab pixels instead
    expect(wallPx, greaterThan(4000),
        reason: 'walls swallowed by the slab overdraw bug — '
            'wall px $wallPx vs slab px $slabPx');
  });
}
