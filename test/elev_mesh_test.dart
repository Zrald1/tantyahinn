import 'dart:io';

import 'package:tantyahin/model3d.dart';
import 'package:flutter_test/flutter_test.dart';

/// Elevation opening linework now comes from the block's REAL mesh
/// (_openingMeshElev): a registered procedural mesh draws its own
/// frame / sash / sill-board quads; a def with no mesh keeps the old
/// generic rect + sill horn + mid-rail symbol.
void main() {
  setUpAll(() async {
    await preloadBlockMeshes((p) => File(p).readAsString());
  });

  Model3d house() => Model3d(name: 'H')
    ..walls.add(Wall3d(points: [0, 0, 8, 0, 8, 6, 0, 6, 0, 0], height: 3))
    ..blocks.add(Block3d(def: 'window-slide', x: 4, y: 0));

  List<List<Offset>> detail(Model3d m, SheetView v) => [
    for (final p in elevationPrims(m, v))
      if (p.$2 == 8) p.$1,
  ];

  test('registered mesh: frame, sashes and sill board draw', () {
    final d = detail(house(), SheetView.front);
    // opening rect + ~15 mesh quads — the old generic symbol was
    // rect + sill horn + mid-rail (3 prims)
    expect(d.length, greaterThan(10));
    // staggered sliding leaves => doubled meeting stiles near the
    // window's center u (=4): at least two close vertical edges
    final centerVerts = d
        .expand((p) => p)
        .where((o) => (o.dx - 4.0).abs() < 0.15 && o.dy > 1.0)
        .length;
    expect(centerVerts, greaterThan(2));
    // the sill board is real geometry: it must draw BELOW the sill
    // band (sill = 0.9) and past the opening width
    final below = d.expand((p) => p).where((o) => o.dy < 0.9 - 1e-6);
    expect(below, isNotEmpty);
  });

  test('no registered mesh: generic symbol kept', () {
    final saved = blockMeshes.remove('window-slide');
    addTearDown(() {
      if (saved != null) blockMeshes['window-slide'] = saved;
    });
    final d = detail(house(), SheetView.front);
    // rect + sill horn + mid-rail — unchanged contract
    expect(d.length, 3);
  });
}
