import 'dart:convert';
import 'dart:io';

import 'package:tantyahin/design_calc.dart';
import 'package:tantyahin/model3d.dart';
import 'package:tantyahin/state.dart';
import 'package:tantyahin/ui/design_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Model3d house({double side = 6, double colSec = 0.3}) {
  final m = Model3d(name: 'House')
    ..walls.add(Wall3d(
      points: [0, 0, side, 0, side, 4, 0, 4, 0, 0],
      thickness: 0.15,
      tieBeam: true,
      bondBeam: true,
    ))
    ..volumes.add(Volume3d(
        footprint: [0, 0, side, 0, side, 4, 0, 4], base: 2.7, height: 0.125));
  for (final c in [(0.0, 0.0), (side, 0.0), (side, 4.0), (0.0, 4.0)]) {
    m.blocks.add(Block3d(
      def: 'col-sq',
      x: c.$1,
      y: c.$2,
      footing: true,
      sx: colSec / 0.3,
      sy: colSec / 0.3,
    ));
  }
  return m;
}

CalcRow? rowOf(CalcReport r, String section, String label) {
  for (final s in r.sections) {
    if (!s.title.contains(section)) continue;
    for (final row in s.rows) {
      if (row.label.contains(label)) return row;
    }
  }
  return null;
}

void main() {
  test('ELF reproduces the published NSCP worked example', () {
    // 4-storey SMRF, Zone 4, SD, Na=Nv=1, I=1, hn=12 m, W=8000 kN
    final p = DesignParams(); // Z4 / SD / SMRF R=8.5 / residential I=1
    final r = seismicELF(p, [8000], [12]);
    expect(r.ca, closeTo(0.44, 1e-9));
    expect(r.cv, closeTo(0.64, 1e-9));
    expect(r.t, closeTo(0.0731 * 6.447, 0.005)); // ~0.471 s
    expect(r.vmax, closeTo(1035.3, 0.5));
    expect(r.vmin, closeTo(387.2, 0.5));
    expect(r.vz4, closeTo(301.2, 0.5));
    expect(r.v, closeTo(1035.3, 0.5)); // Vmax governs
    expect(r.ft, 0); // T < 0.7
  });

  test('Fx distribution sums to V and weights by height', () {
    final r = seismicELF(DesignParams(), [1000, 1000, 800], [3, 6, 9]);
    expect(r.fx.reduce((a, b) => a + b), closeTo(r.v, 1e-6));
    expect(r.fx[2], greaterThan(r.fx[1]));
    expect(r.fx[1], greaterThan(r.fx[0]));
  });

  test('zone 2 uses table values without near-source factors', () {
    expect(seismicCa(2, 'SD', 9.9), 0.28);
    expect(seismicCv(2, 'SD', 9.9), 0.40);
    expect(seismicCa(4, 'SB', 1.2), closeTo(0.48, 1e-9));
  });

  test('house report has every section and sane results', () {
    final r = designCalc(house(), DesignParams());
    final titles = r.sections.map((s) => s.title).join('|');
    for (final k in [
      'DESIGN CRITERIA',
      'DEAD LOADS',
      'LIVE LOADS',
      'SEISMIC',
      'WIND',
      'LOAD COMBINATIONS',
      'COLUMNS',
      'FOOTINGS',
      'WALL BEAMS',
      'SLABS',
      'CHB WALLS',
    ]) {
      expect(titles, contains(k));
    }
    expect(r.v, greaterThan(0));
    expect(r.w, greaterThan(100));
    // hand check: roof slab (0.125x24 + 1.1+0.24+0.75) x 24 m2
    final slab = rowOf(r, 'DEAD', 'Roof slab')!;
    expect(slab.value, '${((0.125 * 24 + 1.1 + 0.24 + 0.75) * 24).toStringAsFixed(2)} kN');
    // roof LL 1.0 kPa x 24 m2
    expect(rowOf(r, 'LIVE', 'Roof live')!.value, '24.00 kN');
    // modest house with 300mm columns passes the column check
    expect(rowOf(r, 'COLUMNS', 'C1')!.status, Chk.ok);
    expect(r.fail, 0);
  });

  test('overloaded column FAILS, undersized footing FAILS', () {
    // 20x20 m roof slab on four 200mm columns
    final m = Model3d()
      ..volumes.add(Volume3d(
          footprint: [0, 0, 20, 0, 20, 20, 0, 20], base: 3, height: 0.2))
      ..walls.add(Wall3d(points: [0, 0, 20, 0], thickness: 0.15))
      ..blocks.addAll([
        for (final c in [(0.0, 0.0), (20.0, 0.0), (20.0, 20.0), (0.0, 20.0)])
          Block3d(
              def: 'col-sq',
              x: c.$1,
              y: c.$2,
              sx: 0.2 / 0.3,
              sy: 0.2 / 0.3,
              footing: true),
      ]);
    final r = designCalc(m, DesignParams());
    expect(rowOf(r, 'COLUMNS', 'C1')!.status, Chk.fail);
    expect(rowOf(r, 'FOOTINGS', 'F1')!.status, Chk.fail);
    expect(r.fail, greaterThan(0));
  });

  test('slab below NSCP minimum thickness is flagged', () {
    final m = house();
    m.volumes.first.height = 0.05; // 6x4 two-way needs 125 mm
    final r = designCalc(m, DesignParams());
    final row = r.sections
        .firstWhere((s) => s.title.contains('SLABS'))
        .rows
        .firstWhere((x) => x.label.contains('TWO-WAY'));
    expect(row.status, Chk.fail);
  });

  test('IMRF in zone 4 is rejected; params survive JSON', () {
    final p = DesignParams(sys: 1);
    final r = designCalc(house(), p);
    expect(rowOf(r, 'SEISMIC', 'System check')!.status, Chk.fail);
    final q = DesignParams.fromJson(
        jsonDecode(jsonEncode(DesignParams(zone: 2, soil: 'SC', fc: 28, qa: 150).toJson())));
    expect(q.zone, 2);
    expect(q.soil, 'SC');
    expect(q.fc, 28);
    expect(q.qa, 150);
  });

  test('multi-storey: columns cascade load down the stack', () {
    final m = Model3d()
      ..walls.add(Wall3d(points: [0, 0, 5, 0, 5, 4, 0, 4, 0, 0], height: 3))
      ..walls.add(Wall3d(
          points: [0, 0, 5, 0, 5, 4, 0, 4, 0, 0], base: 3.1, height: 3))
      ..volumes.add(Volume3d(
          footprint: [0, 0, 5, 0, 5, 4, 0, 4], base: 3.0, height: 0.125))
      ..volumes.add(Volume3d(
          footprint: [0, 0, 5, 0, 5, 4, 0, 4], base: 6.1, height: 0.125))
      ..blocks.add(Block3d(def: 'col-sq', x: 0, y: 0))
      ..blocks.add(Block3d(def: 'col-sq', x: 0, y: 0, bz: 3.1));
    final r = designCalc(m, DesignParams());
    expect(r.storeyForces.length, 2);
    expect(r.storeyForces[1], greaterThan(r.storeyForces[0]));
    // ground-floor column carries more than the upper one
    double pu(String id) => double.parse(
        rowOf(r, 'COLUMNS', id)!.value.split(' ')[1]);
    expect(pu('C1'), greaterThan(pu('C2')));
  });

  test('PDF export writes a real multi-section document', () async {
    final r = designCalc(house(), DesignParams());
    final bytes = await designReportPdf(r, 'Test House');
    expect(String.fromCharCodes(bytes.sublist(0, 5)), '%PDF-');
    expect(bytes.length, greaterThan(3000));
    final f = File('${Directory.systemTemp.path}/design_calc.pdf');
    f.writeAsBytesSync(bytes);
  });

  testWidgets('DESIGN CALC tab sits between 3D MODEL and SCHEDULE', (t) async {
    t.view.physicalSize = const Size(1500, 1000);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    est.newProject();
    est.models
      ..clear()
      ..add(house());
    await t.pumpWidget(const MaterialApp(home: Scaffold(body: DesignView())));
    await t.pump();
    expect(find.text('DESIGN CALCULATION - NSCP 2015 (7th ed.)'), findsOneWidget);
    await t.scrollUntilVisible(find.textContaining('DESIGN BASE SHEAR'), 300,
        scrollable: find.byType(Scrollable).last);
    expect(find.textContaining('DESIGN BASE SHEAR'), findsOneWidget);
    // changing a parameter recomputes the sheet
    final before = designCalc(est.models.first, est.design).v;
    est.design.zone = 2;
    est.update();
    await t.pump();
    expect(designCalc(est.models.first, est.design).v, lessThan(before));
  });
}
