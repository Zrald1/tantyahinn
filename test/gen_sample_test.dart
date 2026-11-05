import 'dart:io';
import 'package:tantyahin/calculators.dart';
import 'package:tantyahin/excel_export.dart';
import 'package:tantyahin/state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('generate sample xlsx', () async {
    final est = EstimateState();
    for (final r in [
      calcConcrete(volume: 20, concreteClass: 'CLASS A (1:2:4)'),
      calcMasonry(wallArea: 88, mortarClass: 'CLASS A (1:2)'),
      calcTiles(area: 35.75, tileSize: '0.60 x 0.60'),
      calcPainting(area: 105, systemIndex: 0),
      calcCarpentry(length: 6, width: 18, system: 'ceiling'),
      calcSteel(length: .2, width: .2, height: 5, members: 4),
      calcStairs(totalRise: 2.5, riser: .175, tread: .28, stairWidth: 1.2),
    ]) {
      est.addWork(sectionTitle: r.sectionTitle, groupLabel: 'GROUND FLOOR',
          items: r.lines.map((e) => e.toBoqLine()).toList());
    }
    // also exercises the PERT-CPM + S-CURVE sheets
    est.syncSchedule(force: true);
    final logo = File('assets/deped_logo.png').readAsBytesSync();
    final bytes = (await ExcelExport(est).build(logoBytes: logo))!;
    File('sample_estimate.xlsx').writeAsBytesSync(bytes);
    print('written ${bytes.length} bytes, sections=${est.sections.length}, total=${est.grandTotal}');
  });
}
