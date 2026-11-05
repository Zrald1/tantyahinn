import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart' show Offset, Size;
import 'package:flutter_test/flutter_test.dart';
import 'package:tantyahin/model3d.dart';
import 'package:tantyahin/ui/model_view.dart';

/// Dense mesh furniture must order faces by NEAREST vertex so closed
/// doors/panels cover the interior (mirrors _SolidPainter).
Future<List<int>> _render(String def, bool near, String out) async {
  final m = Model3d(name: 'w')..blocks.add(Block3d(def: def, x: 0, y: 0));
  final faces = m.cachedFaces();
  const vp = Size(500, 500);
  const yaw = -0.7, pitch = 0.5;
  final bb = m.bounds!;
  final c = [(bb.$1 + bb.$3) / 2, (bb.$2 + bb.$4) / 2, bb.$5 / 2];
  final zoom = vp.shortestSide * 0.7 /
      math.max(bb.$3 - bb.$1, math.max(bb.$4 - bb.$2, bb.$5));
  final pc = cam3Project(c, vp, yaw: yaw, pitch: pitch, zoom: zoom, off: Offset.zero);
  final off = Offset(vp.width / 2, vp.height / 2) - pc;
  Offset prj(List<double> v) =>
      cam3Project(v, vp, yaw: yaw, pitch: pitch, zoom: zoom, off: off);
  final keyed = <(double, Face3)>[];
  for (final f in faces) {
    var d = -1e18, dn = 1e18, sum = 0.0;
    for (final p in f.v) {
      final q = cam3Depth(p, yaw: yaw, pitch: pitch);
      if (q > d) d = q;
      if (q < dn) dn = q;
      sum += q;
    }
    keyed.add((near && f.n[2].abs() < 0.5 ? (d + dn) / 2 : d, f));
  }
  keyed.sort((a, b) => b.$1.compareTo(a.$1));
  final rec = ui.PictureRecorder();
  final canvas = ui.Canvas(rec);
  canvas.drawRect(Offset.zero & vp, ui.Paint()..color = const ui.Color(0xFFFFFFFF));
  for (final (_, f) in keyed) {
    final path = ui.Path();
    for (var i = 0; i < f.v.length; i++) {
      final p = prj(f.v[i]);
      i == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
    }
    path.close();
    final dot = (f.n[0] * .3 + f.n[1] * .5 + f.n[2] * .8).abs().clamp(0.0, 1.0);
    final c0 = ui.Color(f.argb);
    canvas.drawPath(path, ui.Paint()..color = ui.Color.fromARGB(255,
        (c0.r * 255 * (0.5 + 0.5 * dot)).round(),
        (c0.g * 255 * (0.5 + 0.5 * dot)).round(),
        (c0.b * 255 * (0.5 + 0.5 * dot)).round()));
  }
  final img = await rec.endRecording().toImage(500, 500);
  final png = await img.toByteData(format: ui.ImageByteFormat.png);
  Directory('test/out').createSync(recursive: true);
  File(out).writeAsBytesSync(png!.buffer.asUint8List());
  final raw = (await img.toByteData())!;
  // front-door band: count distinct quantized colors (interior mess = many)
  final colors = <int>{};
  for (var y = 0; y < 500; y++) {
    for (var x = 0; x < 500; x++) {
      final i = (y * 500 + x) * 4;
      colors.add((raw.getUint8(i) >> 4) << 8 | (raw.getUint8(i + 1) >> 4) << 4 | raw.getUint8(i + 2) >> 4);
    }
  }
  return [colors.length];
}

void main() {
  setUpAll(() async {
    await preloadBlockMeshes((p) => File(p).readAsString());
  });
  test('nearest-vertex order renders closed furniture solid', () async {
    for (final d in ['wardrobe', 'bed-dbl', 'bookshelf', 'tv-unit']) {
      final far = await _render(d, false, 'test/out/mesh_${d}_far.png');
      final nr = await _render(d, true, 'test/out/mesh_${d}_near.png');
      // ignore: avoid_print
      print('$d colors far=${far[0]} near=${nr[0]}');
    }
  });
}
