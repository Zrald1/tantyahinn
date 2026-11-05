import 'package:flutter_test/flutter_test.dart';
import 'package:tantyahin/model3d.dart';
import 'package:tantyahin/takeoff.dart';
import 'package:tantyahin/state.dart';
import 'package:tantyahin/models.dart';

Model3d room() => Model3d(name: 'r')
  ..walls.add(Wall3d(points: [0, 0, 5, 0, 5, 4, 0, 4, 0, 0], thickness: 0.15))
  ..volumes.add(Volume3d(footprint: [0, 0, 5, 0, 5, 4, 0, 4], height: 0.1))
  ..blocks.addAll([
    Block3d(def: 'door-090', x: 2, y: 0),
    Block3d(def: 'window-120', x: 5, y: 2, rot: 1.5707963267948966),
    Block3d(def: 'col-sq', x: 0, y: 0),
  ]);

void main() {
  test('takeoff measures walls, openings, slab, columns exactly', () {
    final t = modelTakeoff(room());
    expect(t.wallLen, closeTo(18, 1e-9));
    expect(t.wallGross, closeTo(18 * 2.7, 1e-9));
    expect(t.doors, 1);
    expect(t.windows, 1);
    expect(t.aperture, closeTo(0.9 * 2.1 + 1.2 * 1.2, 0.05));
    expect(t.wallNet, closeTo(48.6 - t.aperture, 1e-9));
    expect(t.floorArea, closeTo(20, 1e-9));
    expect(t.slabVol, closeTo(2.0, 1e-9));
    expect(t.colCount, 1);
    expect(t.concreteVol, greaterThan(2.0));
  });

  test('opening off any wall is not counted', () {
    final m = room()..blocks.add(Block3d(def: 'door-090', x: 2, y: 2));
    expect(modelTakeoff(m).doors, 1);
  });

  test('work packages produce priced lines and insert into the BOQ', () {
    final t = modelTakeoff(room());
    final e = EstimateState();
    for (final w in [
      takeoffMasonry(t),
      takeoffPainting(t),
      takeoffConcrete(t),
      takeoffTiles(t),
    ]) {
      expect(w, isNotNull);
      insertTakeoffWork(w!, (s, l, items) =>
          e.addWork(sectionTitle: s, groupLabel: l, items: items));
    }
    final titles = e.sections.map((s) => s.title).toList();
    expect(titles, containsAll(['MASONRY WORKS', 'PAINTING WORKS',
        'CONCRETING WORKS']));
    final chb = e.sections
        .firstWhere((s) => s.title == 'MASONRY WORKS')
        .lines
        .firstWhere((l) => l.kind == BoqLineKind.item && l.description.contains('CHB'));
    // 6" wall (t=0.15): 12.5 pcs/sq.m * net * 1.10
    expect(chb.qty, closeTo(12.5 * t.wallNet * 1.1, 1.0));
    expect(chb.materialCost, greaterThan(0));
  });

  test('empty model yields no work', () {
    final t = modelTakeoff(Model3d(name: 'e'));
    expect(t.isEmpty, isTrue);
    expect(takeoffMasonry(t), isNull);
  });
}
