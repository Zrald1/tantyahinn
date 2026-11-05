import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

import 'package:tantyahin/model3d.dart';
import 'package:tantyahin/state.dart';
import 'package:tantyahin/dxf.dart';

void main() {
  test('render generated roof sheets to PNG for visual inspection', () async {
    final est = EstimateState();
    final m = est.addModel('H');
    m.walls.add(
      Wall3d(points: [0, 0, 6, 0], thickness: .15, height: 2.7),
    );
    m.walls.add(
      Wall3d(points: [0, 4, 6, 4], thickness: .15, height: 2.7),
    );
    m.walls.add(
      Wall3d(points: [0, 0, 0, 4], thickness: .15, height: 2.7),
    );
    m.walls.add(
      Wall3d(points: [6, 0, 6, 4], thickness: .15, height: 2.7),
    );
    for (var i = 0; i < 4; i++) {
      m.blocks.add(
        Block3d(
          def: 'truss',
          x: 1.2 + i * 1.5,
          y: 2.0,
          rot: math.pi / 2,
          bz: 2.7,
        ),
      );
    }
    Directory('test/out').createSync();
    for (final (v, nm) in [
      (SheetView.roof, 'roofplan'),
      (SheetView.roofFrame, 'roofframe'),
      (SheetView.left, 'gable'),
      (SheetView.front, 'eaveside'),
    ]) {
      final src = buildModelSheet(m, v, project: est.project);
      File('test/out/$nm.dxf').writeAsStringSync(src);
      final png = await renderDxfPng(DxfParser.parse(src), maxPx: 1400);
      if (png == null) {
        // ignore: avoid_print
        print('$nm: rasterize returned null');
      } else {
        File('test/out/$nm.png').writeAsBytesSync(png);
      }
    }
  });

  test('single truss variant shows on roof plan + framing + gable',
      () async {
    final est = EstimateState();
    final m = est.addModel('S');
    m.walls.add(Wall3d(points: [0, 0, 6, 0], thickness: .15, height: 2.7));
    m.walls.add(Wall3d(points: [0, 4, 6, 4], thickness: .15, height: 2.7));
    m.walls.add(Wall3d(points: [0, 0, 0, 4], thickness: .15, height: 2.7));
    m.walls.add(Wall3d(points: [6, 0, 6, 4], thickness: .15, height: 2.7));
    // mixed: 2 fink + 1 single king-post — both must reach the sheets
    for (var i = 0; i < 3; i++) {
      m.blocks.add(
        Block3d(
          def: i == 1 ? 'truss-sgl' : 'truss',
          x: 1.2 + i * 1.8,
          y: 2.0,
          rot: math.pi / 2,
          bz: 2.7,
        ),
      );
    }
    for (final (v, nm) in [
      (SheetView.roof, 'roofplan_sgl'),
      (SheetView.roofFrame, 'roofframe_sgl'),
      (SheetView.left, 'gable_sgl'),
    ]) {
      final src = buildModelSheet(m, v, project: est.project);
      File('test/out/$nm.dxf').writeAsStringSync(src);
      final png = await renderDxfPng(DxfParser.parse(src), maxPx: 1400);
      expect(png, isNotNull, reason: '$nm rasterize failed');
      File('test/out/$nm.png').writeAsBytesSync(png!);
    }
    // fields see all 3 trusses regardless of def
    expect(roofFields(m).single.trusses, hasLength(3));
  });
}
