import 'package:flutter_test/flutter_test.dart';
import 'package:tantyahin/model3d.dart';

/// The structural options must add renderable faces: tie/bond beams
/// widen the wall band, footings add a square pad under columns.
void main() {
  test('footing + tie/bond beams emit faces and invalidate cache', () {
    final m = Model3d()
      ..walls.add(Wall3d(points: [0, 0, 6, 0, 6, 5, 0, 5, 0, 0],
          thickness: 0.15))
      ..blocks.add(Block3d(def: 'col-sq', x: 3, y: 2.5));
    final base = modelFaces(m).length;

    m.blocks.first.footing = true;
    final withFoot = modelFaces(m);
    // buried pad (4 sides + top) + pedestal stem (4 sides + top) = 10
    expect(withFoot.length - base, 10);
    // the pad bottom sits at the 0.60m default embedment below base
    final fZ = withFoot
        .skip(base)
        .expand((f) => f.v)
        .map((p) => p[2]);
    expect(fZ.reduce((a, b) => a < b ? a : b), closeTo(-0.60, 1e-9));
    expect(fZ.reduce((a, b) => a > b ? a : b), closeTo(0, 1e-9));
    // the pad+stem are inside blockFaces -> the 3D ray pick and the
    // render both see the footing as part of the column (selectable)
    final bf = blockFaces(m.blocks.first, cadBlock('col-sq')!);
    expect(bf.where((f) => f.v.every((p) => p[2] < 0)).length,
        greaterThanOrEqualTo(5));
    final top = withFoot
        .expand((f) => f.v)
        .map((p) => p[2])
        .reduce((a, b) => a > b ? a : b);
    expect(top, greaterThanOrEqualTo(3.0)); // column mesh top

    m.walls.first.tieBeam = true;
    m.walls.first.bondBeam = true;
    final withBeams = modelFaces(m);
    // 4 segs × 2 beams × (4 sides + top) = 40 new faces
    expect(withBeams.length - withFoot.length, 40);
    // beams rendered in concrete grey
    expect(withBeams.where((f) => f.argb == 0xFF9E9E9E).length,
        greaterThanOrEqualTo(40));
    // cache signature sees the flag flips
    m.cachedFaces();
    m.walls.first.bondBeam = false;
    expect(m.cachedFaces().length, lessThan(withBeams.length));
  });
}
