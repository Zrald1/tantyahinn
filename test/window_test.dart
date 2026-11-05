import 'dart:ui';
import 'package:flutter_test/flutter_test.dart';
import 'package:tantyahin/model3d.dart';

void main() {
  test('window cuts only sill..head band in 3D and has a real mesh', () {
    registerProceduralWindows();
    final m = Model3d(name: 't');
    final w = Wall3d(name: 'w', points: [0, 0, 6, 0], thickness: 0.15, height: 2.7);
    m.walls.add(w);
    m.blocks.add(Block3d(def: 'window-120', x: 3, y: 0));
    final fs = wallFacesJoined(m, w);
    double zmin(Iterable<Face3> f) =>
        f.expand((e) => e.v).map((p) => p[2]).reduce((a, b) => a < b ? a : b);
    // apron under the sill + lintel above head exist inside the gap span
    final mid = fs.where((f) => f.v.every((p) => p[0] > 2.3 && p[0] < 3.7));
    expect(mid.isNotEmpty, true);
    final zs = mid.expand((f) => f.v).map((p) => p[2]).toSet();
    expect(zs.any((z) => (z - 0.9).abs() < 1e-6), true);
    expect(zs.any((z) => (z - 2.1).abs() < 1e-6), true);
    expect(zmin(mid), 0.0);
    final mesh = blockMeshes['window-120']!;
    expect(mesh.length > 20, true);
    final box = blockMeshBox['window-120']!;
    expect(box[2] < 0.9 + 1e-6 && box[5] > 2.09, true);
  });
}
