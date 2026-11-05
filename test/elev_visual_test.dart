import 'dart:io';
import 'dart:ui';

import 'package:tantyahin/dxf.dart';
import 'package:tantyahin/model3d.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// Scratch verification: generate the real elevation sheets for a
// furnished house and rasterize them to PNG so the linework can be
// eyeballed against the old mesh-dump wireframe.
void main() {
  test('elevation sheets rasterize', () async {
    await preloadBlockMeshes((p) => File(p).readAsString());
    final m = Model3d(name: 'ELEV-CHECK')
      ..volumes.add(Volume3d(footprint: [0, 0, 8, 0, 8, 6, 0, 6], height: 0.15, base: -0.15))
      ..volumes.add(Volume3d(footprint: [0, 0, 8, 0, 8, 6, 0, 6], base: 3.0, height: 0.125))
      ..walls.add(Wall3d(points: [0, 0, 8, 0, 8, 6, 0, 6, 0, 0], height: 3))
      ..walls.add(Wall3d(points: [3, 1.5, 3, 6])) // interior partition
      ..blocks.add(Block3d(def: 'window-120', x: 2, y: 0))
      ..blocks.add(Block3d(def: 'window-slide', x: 5.5, y: 0))
      ..blocks.add(Block3d(def: 'door-090', x: 6.5, y: 6))
      ..blocks.add(Block3d(def: 'door-dbl', x: 8, y: 3, rot: 1.5708))
      ..blocks.add(Block3d(def: 'col-sq', x: 4, y: -0.6)) // porch col
      ..blocks.add(Block3d(def: 'col-sq', x: 4, y: 3))   // interior
      ..blocks.add(Block3d(def: 'bed-dbl', x: 5, y: 4))
      ..blocks.add(Block3d(def: 'sofa-3', x: 2, y: 4.5))
      ..blocks.add(Block3d(def: 'wc', x: 6.5, y: 4.8))
      ..blocks.add(Block3d(def: 'car', x: 4, y: -3))
      // stale manual dim 50m away from the model — must NOT inflate
      // the sheet bounds (the original "tiny plan on a giant page" bug)
      ..dims.add([-23.5, 50.25, -30.0, 50.25]);

    for (final v in [SheetView.plan, SheetView.front, SheetView.right]) {
      final src = buildModelSheet(m, v);
      final sc = DxfParser.parse(src);
      stdout.writeln(
          '${v.name}: prims=${sc.prims.length} texts=${sc.texts.length} '
          'bounds=${sc.bounds.width.toStringAsFixed(0)}x'
          '${sc.bounds.height.toStringAsFixed(0)}');
      // the sheet IS the paper: scene bounds = chosen paper size,
      // landscape by default (w > h) regardless of content shape
      expect(sc.bounds.width, greaterThan(sc.bounds.height));
      expect(sc.bounds.width, closeTo(297, 1));
      expect(sc.bounds.height, closeTo(210, 1));
      final size = sc.naturalSize();
      final scale = size.width / sc.bounds.width;
      final rec = PictureRecorder();
      final canvas = Canvas(rec);
      canvas.drawRect(
          Offset.zero & size, Paint()..color = const Color(0xFFFFFFFF));
      DxfPainter(sc, scale).paint(canvas, size);
      final img = await rec
          .endRecording()
          .toImage(size.width.round(), size.height.round());
      final bd = await img.toByteData(format: ImageByteFormat.png);
      final f = File('${Directory.systemTemp.path}/elev_${v.name}.png');
      await f.writeAsBytes(bd!.buffer.asUint8List());
      stdout.writeln('wrote ${f.path} ${sc.prims.length} prims');
      expect(sc.prims.length, greaterThan(3));
      // the old mesh-dump emitted one prim per mesh triangle — a
      // furnished model was hundreds; the semantic elevation is a
      // handful of architectural outlines + the paper furniture
      // (border, frame, title block, scale bar, north arrow). The
      // plan legitimately carries more: dim ticks, footing dashes
      // and per-block labels.
      if (v != SheetView.plan) {
        expect(sc.prims.length, lessThan(80));
      }
    }
  });
}
