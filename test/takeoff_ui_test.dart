import 'dart:io';
import 'package:tantyahin/excel_export.dart';
import 'package:tantyahin/model3d.dart';
import 'package:tantyahin/models.dart';
import 'package:tantyahin/state.dart';
import 'package:tantyahin/takeoff.dart';
import 'package:tantyahin/ui/work_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Model3d _house() => Model3d(name: 'House')
  ..walls
      .add(Wall3d(points: [0, 0, 5, 0, 5, 4, 0, 4, 0, 0], thickness: 0.15))
  ..volumes.add(Volume3d(footprint: [0, 0, 5, 0, 5, 4, 0, 4], height: 0.1))
  ..blocks.add(Block3d(def: 'door-090', x: 2, y: 0))
  ..blocks.add(Block3d(def: 'col-sq', x: 5, y: 4));

TextField _fieldByLabel(WidgetTester t, String label) {
  for (final w in t.widgetList<TextField>(find.byType(TextField))) {
    if (w.decoration?.labelText == label) return w;
  }
  throw StateError('no TextField labelled $label');
}

void main() {
  testWidgets('takeoff button opens the editable form prefilled', (tester) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    est.newProject();
    est.models
      ..clear()
      ..add(_house());
    final t = modelTakeoff(est.models.first);
    await tester
        .pumpWidget(MaterialApp(home: Scaffold(body: WorkPanel(est: est))));
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('takeoff-Masonry')));
    await tester.pump();
    // the masonry form shows the model's own gross + aperture + CHB
    final area = _fieldByLabel(tester, 'Wall total area');
    expect(area.controller!.text, t.wallGross.toStringAsFixed(2));
    final ap = _fieldByLabel(tester, 'Aperture area');
    expect(ap.controller!.text, t.aperture.toStringAsFixed(2));
    final seg = tester.widget<SegmentedButton<String>>(
        find.byType(SegmentedButton<String>));
    expect(seg.selected, {'CHB 6"'});

    await tester.tap(find.text('ADD TO BOQ'));
    await tester.pump();
    final mas = est.sections.firstWhere((s) => s.title == 'MASONRY WORKS');
    expect(
        mas.lines.first.kind == BoqLineKind.groupHeader &&
            mas.lines.first.description.contains('3D MODEL'),
        isTrue);
    expect(
        mas.lines.any((l) =>
            l.kind == BoqLineKind.item && l.description.contains('CHB 6')),
        isTrue);
  });

  testWidgets('takeoff steel button prefills the column members',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    est.newProject();
    est.models
      ..clear()
      ..add(_house());
    await tester
        .pumpWidget(MaterialApp(home: Scaffold(body: WorkPanel(est: est))));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('takeoff-Steel')));
    await tester.pump();
    expect(_fieldByLabel(tester, 'L').controller!.text, '0.30');
    expect(_fieldByLabel(tester, 'H').controller!.text, '3.00');
    expect(_fieldByLabel(tester, 'Qty').controller!.text, '1');
    // NSCP 410: 0.30sq col needs >=900mm² → 4-20mm schedule prefilled
    expect(_fieldByLabel(tester, 'Bar dia').controller!.text, '20');
    expect(_fieldByLabel(tester, 'Bars/member').controller!.text, '4');
  });

  testWidgets('FROM 3D MODEL card: Add all fills the BOQ, exports xlsx',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    est.newProject();
    est.models
      ..clear()
      ..add(_house());
    await tester
        .pumpWidget(MaterialApp(home: Scaffold(body: WorkPanel(est: est))));
    await tester.pump();
    expect(find.text('FROM 3D MODEL'), findsOneWidget);
    expect(find.textContaining('48.60 - '), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('takeoff-all')));
    await tester.pump();
    final titles = est.sections.map((s) => s.title).toSet();
    expect(titles,
        containsAll(['CONCRETING WORKS', 'MASONRY WORKS', 'PAINTING WORKS']));
    final items = [
      for (final s in est.sections)
        for (final l in s.lines)
          if (l.kind == BoqLineKind.item) l
    ];
    expect(items.length, greaterThan(8));
    expect(items.every((l) => l.qty > 0 && l.materialCost > 0), isTrue);
    final bytes = (await tester.runAsync(() => ExcelExport(est).build()))!;
    final f = File('${Directory.systemTemp.path}/takeoff_boq.xlsx');
    f.writeAsBytesSync(bytes);
    // ignore: avoid_print
    print('xlsx ${f.path} ${bytes.length}B items=${items.length}');
    expect(bytes.length, greaterThan(5000));
  });
}
