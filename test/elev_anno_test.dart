import 'dart:io';

import 'package:tantyahin/model3d.dart';
import 'package:tantyahin/models.dart';
import 'package:flutter_test/flutter_test.dart';

/// Drawing annotations: every door/window gets a schedule tag
/// (D#/W#/O#) shared between the plan and the elevations, and every
/// elevation callouts its drawn openings (tag + W×H + sill). Also the
/// SketchUp truss block (wh_truss.obj via tool/skp2obj.rb).
void main() {
  setUpAll(() async {
    await preloadBlockMeshes((p) => File(p).readAsString());
  });

  Model3d house() => Model3d(name: 'H')
    ..walls.add(Wall3d(points: [0, 0, 8, 0, 8, 6, 0, 6, 0, 0], height: 3))
    ..blocks.addAll([
      Block3d(def: 'door-090', x: 2, y: 0),
      Block3d(def: 'window-slide', x: 5, y: 0),
      Block3d(def: 'door-dbl', x: 4, y: 6),
    ]);

  test('blockTags numbers doors and windows in model order', () {
    final t = blockTags(house());
    expect(t[0], 'D1');
    expect(t[1], 'W1');
    expect(t[2], 'D2');
  });

  test('hostedOpenings: front wall openings face front, not left', () {
    final m = house();
    final front = hostedOpenings(m, SheetView.front);
    // the y=0 wall's door + window draw on the front elevation
    expect(front.map((o) => o.bi).toSet(), {0, 1});
    // left view sees the x=0 wall — nothing on it
    expect(hostedOpenings(m, SheetView.left), isEmpty);
    // the rear wall's double door hosts on rear
    expect(hostedOpenings(m, SheetView.rear).map((o) => o.bi), [2]);
  });

  test('elevation sheet carries tag + size + sill callouts', () {
    final m = house();
    final dxf = buildModelSheet(m, SheetView.front, project: ProjectInfo());
    expect(dxf, contains('D1'));
    expect(dxf, contains('W1'));
    expect(dxf, contains('SILL')); // window sill height callout
    expect(dxf, contains('×'));
    final plan = buildModelSheet(m, SheetView.plan, project: ProjectInfo());
    expect(plan, contains('D1 · Door 0.90'));
    expect(plan, contains('W1 · Sliding window'));
  });

  test('truss block: real SketchUp mesh registered + fitted', () {
    final def = cadBlock('truss');
    expect(def, isNotNull);
    expect(def!.cat, 'Site');
    final mesh = blockMeshes['truss'];
    expect(mesh, isNotNull);
    expect(mesh!.length, greaterThan(100));
    // fitted to the def envelope: ~4m span x, thin y, ~0.8m rise
    final box = blockMeshBox['truss']!;
    expect(box[3] - box[0], closeTo(3.97, 0.05));
    expect(box[4] - box[1], closeTo(0.18, 0.05));
    expect(blockMeshTop['truss'], closeTo(0.80, 0.05));
  });
}
