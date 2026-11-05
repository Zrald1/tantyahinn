import 'dart:ui';

import 'package:tantyahin/model3d.dart';
import 'package:tantyahin/structural.dart';
import 'package:tantyahin/ui/model_view.dart';
import 'package:flutter_test/flutter_test.dart';

/// Replicates _pick3's exact math: project each face's verts with
/// cam3Project, point-in-polygon at the tap, keep the face with the
/// smallest average cam3Depth.
Object? pick3(
  Model3d m,
  Offset sp,
  Size vp, {
  required double yaw,
  required double pitch,
  required double zoom,
  required Offset off,
}) {
  Object? best;
  var bestD = double.infinity;
  void faceHit(List<List<double>> v, double d, Object part) {
    var inside = false;
    for (var i = 0; i < v.length; i++) {
      final a = cam3Project(v[i], vp,
          yaw: yaw, pitch: pitch, zoom: zoom, off: off);
      final b = cam3Project(v[(i + 1) % v.length], vp,
          yaw: yaw, pitch: pitch, zoom: zoom, off: off);
      if (((a.dy > sp.dy) != (b.dy > sp.dy)) &&
          (sp.dx <
              (b.dx - a.dx) * (sp.dy - a.dy) / (b.dy - a.dy) + a.dx)) {
        inside = !inside;
      }
    }
    if (inside && d < bestD) {
      bestD = d;
      best = part;
    }
  }

  void partFaces(List<Face3> faces, Object part) {
    for (final f in faces) {
      var d = 0.0;
      for (final p in f.v) {
        d += cam3Depth(p, yaw: yaw, pitch: pitch);
      }
      faceHit(f.v, d / f.v.length, part);
    }
  }

  for (final v in m.volumes) {
    partFaces(volumeFaces(v), v);
  }
  for (final w in m.walls) {
    partFaces(wallFaces(w), w);
  }
  for (final b in m.blocks) {
    final def = cadBlock(b.def);
    if (def == null) continue;
    final real = blockFaces(b, def);
    if (real.isNotEmpty) {
      partFaces(real, b);
      continue;
    }
    final fp = blockFootprint(b, def);
    partFaces([
      Face3(
        [for (final p in fp) [p.dx, p.dy, 0.0]],
        const [0, 0, 1],
        0,
      ),
    ], b);
  }
  return best;
}

Offset proj(
  List<double> p,
  Size vp,
  double yaw,
  double pitch,
  double zoom,
  Offset off,
) =>
    cam3Project(p, vp, yaw: yaw, pitch: pitch, zoom: zoom, off: off);

/// Plan-view _blkAt replica: footprint PIP, then the footing pad
/// square for flagged columns.
Block3d? blkAt(Model3d m, Offset w) {
  for (var i = m.blocks.length - 1; i >= 0; i--) {
    final b = m.blocks[i];
    final def = cadBlock(b.def);
    if (def == null) continue;
    final fp = blockFootprint(b, def);
    var inside = false;
    for (var j = 0; j < fp.length; j++) {
      final k = (j + 1) % fp.length;
      final pi = fp[j], pj = fp[k];
      if (((pi.dy > w.dy) != (pj.dy > w.dy)) &&
          (w.dx <
              (pj.dx - pi.dx) * (w.dy - pi.dy) / (pj.dy - pi.dy) +
                  pi.dx)) {
        inside = !inside;
      }
    }
    if (!inside &&
        b.footing &&
        (b.def == 'col-sq' || b.def == 'col-rd')) {
      final hw = footingFor(def.w * b.sx * b.scale, b.footW).w / 2;
      inside = (w.dx - b.x).abs() <= hw && (w.dy - b.y).abs() <= hw;
    }
    if (inside) return b;
  }
  return null;
}

void main() {
  const vp = Size(800, 600);
  const yaw = -0.7, pitch = 0.55, zoom = 70.0;
  const off = Offset.zero;

  test('3D pick: placed ftg pad selects itself', () {
    final pad = Block3d(def: 'ftg-150', x: 3, y: 2);
    final m = Model3d()..blocks.add(pad);
    // tap where the pad's top-face center projects
    final tap = proj([3, 2, 0], vp, yaw, pitch, zoom, off);
    final hit = pick3(m, tap, vp,
        yaw: yaw, pitch: pitch, zoom: zoom, off: off);
    expect(hit, same(pad));
  });

  test('3D pick: column footing pad selects its column', () {
    final col = Block3d(def: 'col-sq', x: 0, y: 0, footing: true);
    final m = Model3d()..blocks.add(col);
    // lone column -> Table 305-1 1F default: pad spans bz-0.30..bz;
    // tap its projected side, clear of the column body
    final tap = proj([0.6, 0.6, -0.15], vp, yaw, pitch, zoom, off);
    final hit = pick3(m, tap, vp,
        yaw: yaw, pitch: pitch, zoom: zoom, off: off);
    expect(hit, same(col));
  });

  test('plan pick: placed ftg pad selects itself', () {
    final pad = Block3d(def: 'ftg-150', x: 3, y: 2);
    final m = Model3d()..blocks.add(pad);
    expect(blkAt(m, const Offset(3, 2)), same(pad));
    expect(blkAt(m, const Offset(3.6, 2.6)), same(pad)); // pad corner
  });

  test('plan pick: column footing pad square selects its column', () {
    final col = Block3d(def: 'col-sq', x: 0, y: 0, footing: true);
    final m = Model3d()..blocks.add(col);
    // 0.6,0.6 is inside the 1.5 pad but outside the 0.3 column
    expect(blkAt(m, const Offset(0.6, 0.6)), same(col));
  });
}
