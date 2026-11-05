import 'dart:convert';
import 'dart:math' as math;

import 'package:tantyahin/design_calc.dart';
import 'package:tantyahin/model3d.dart';
import 'package:tantyahin/state.dart';
import 'package:tantyahin/structural.dart';
import 'package:tantyahin/takeoff.dart';
import 'package:tantyahin/ui/design_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'design_calc_test.dart' show house, rowOf;

/// Overloaded model: 20x20 m roof on four 200mm columns, no footings.
Model3d overloaded() => Model3d()
  ..volumes.add(Volume3d(
      footprint: [0, 0, 20, 0, 20, 20, 0, 20], base: 3, height: 0.2))
  ..walls.add(Wall3d(points: [0, 0, 20, 0], thickness: 0.15))
  ..blocks.addAll([
    for (final c in [(0.0, 0.0), (20.0, 0.0), (20.0, 20.0), (0.0, 20.0)])
      Block3d(def: 'col-sq', x: c.$1, y: c.$2, sx: 0.2 / 0.3, sy: 0.2 / 0.3),
  ]);

void main() {
  test('missing footing offers a fix that adds it to the model', () {
    final m = house();
    for (final b in m.blocks) {
      b.footing = false;
    }
    var r = designCalc(m, DesignParams());
    final row = rowOf(r, 'FOOTINGS', 'F1')!;
    expect(row.status, Chk.warn);
    expect(row.fix, isNotNull);
    expect(row.fix!.kind, 'footing-all');

    for (final s in r.sections) {
      for (final x in s.rows) {
        if (x.fix != null) applyDesignFix(m, x.fix!);
      }
    }
    expect(m.blocks.every((b) => b.footing), isTrue);
    expect(m.blocks.every((b) => b.footW > 0), isTrue);
    r = designCalc(m, DesignParams());
    expect(rowOf(r, 'FOOTINGS', 'F1')!.status, Chk.ok);
  });

  test('one footing FIX builds footings under ALL missing columns', () {
    final m = house();
    for (final b in m.blocks) {
      b.footing = false;
      b.footW = 0;
    }
    final r = designCalc(m, DesignParams());
    // every missing-footing row carries the same all-columns fix
    final rows = r.sections
        .firstWhere((s) => s.title.contains('FOOTINGS'))
        .rows
        .where((x) => x.fix != null)
        .toList();
    expect(rows.length, m.blocks.length);
    expect(rows.first.fix!.values!.length, m.blocks.length);
    // applying only the FIRST row's fix still fixes every column
    applyDesignFix(m, rows.first.fix!);
    expect(m.blocks.every((b) => b.footing && b.footW > 0), isTrue);
    // and the report is clean afterwards
    final r2 = designCalc(m, DesignParams());
    expect(
        r2.sections
            .firstWhere((s) => s.title.contains('FOOTINGS'))
            .rows
            .where((x) => x.status == Chk.warn || x.status == Chk.fail),
        isEmpty);
  });

  test('placed ftg pad block counts as the provided footing', () {
    final m = house();
    // replace flag footings with a placed pad under C1 only
    for (final b in m.blocks) {
      b.footing = false;
    }
    m.blocks.add(Block3d(
        def: 'ftg-150', x: m.blocks.first.x, y: m.blocks.first.y,
        bz: 0.15)); // shallow: 0.30-0.15 = 0.15 m embedment
    var r = designCalc(m, DesignParams());
    final f1 = rowOf(r, 'FOOTINGS', 'F1')!;
    expect(f1.label, contains('(pad block)'));
    expect(f1.status, Chk.ok);
    // the other three columns still count as missing -> footing-all
    // covers them, not the pad column
    final miss = r.sections
        .firstWhere((s) => s.title.contains('FOOTINGS'))
        .rows
        .firstWhere((x) => x.fix?.kind == 'footing-all');
    expect(miss.fix!.values!.length, 3);
    // apply all fixes -> F1 (pad) untouched, F2..F4 get flag footings
    applyDesignFix(m, miss.fix!);
    expect(m.blocks.where((b) => b.footing).length, 3);
    // shallow pad (0.15m embedment < Table 305-1's 0.30 for 1 floor)
    // gets a depth warning + fix
    r = designCalc(m, DesignParams());
    final dep = rowOf(r, 'FOOTINGS', 'embedment')!;
    expect(dep.status, Chk.warn);
    expect(dep.fix!.kind, 'pad');
    applyDesignFix(m, dep.fix!);
    final pad = m.blocks.firstWhere((b) => b.def == 'ftg-150');
    expect(0.30 - pad.bz, closeTo(0.30, 1e-9)); // bottom at -0.30
  });

  test('undersized pad gets a pad fix that resizes + embeds it', () {
    final m = overloaded(); // 20x20 roof -> needs ~2m+ pads
    m.blocks.add(Block3d(
        def: 'ftg-150', x: 0, y: 0)); // under C1, too small
    var r = designCalc(m, DesignParams());
    final f1 = rowOf(r, 'FOOTINGS', 'F1')!;
    expect(f1.status, Chk.fail);
    expect(f1.fix!.kind, 'pad');
    applyDesignFix(m, f1.fix!);
    final pad = m.blocks.firstWhere((b) => b.def == 'ftg-150');
    expect(pad.sx * 1.5, greaterThan(1.5)); // grew past the stock size
    expect(0.30 - pad.bz, closeTo(0.30, 1e-9)); // Table 305-1: 1 floor -> 0.30
    r = designCalc(m, DesignParams());
    expect(rowOf(r, 'FOOTINGS', 'F1')!.status, isNot(Chk.fail));
  });

  test('footing depth: stem volume in takeoff + embedment check', () {
    final m = house();
    final b = m.blocks.first;
    // lone columns in a 1-storey house -> Table 305-1 default 0.30 m;
    // pad top (0.30 thick) reaches the column base so the stem is 0
    final t0 = modelTakeoff(m);
    final sec = 0.3 * b.sx;
    final auto = footingFor(sec, 0);
    expect(blockFootingDepth(m, b), 0.30);
    final stem = sec * sec * math.max(0.30 - auto.t, 0);
    // every footing = pad + pedestal stem up to the column base
    expect(t0.footVol, closeTo(4 * (auto.vol + stem), 1e-6));
    // a deeper manual depth grows the stem
    b.footD = 0.60;
    final stem60 = sec * sec * (0.60 - auto.t);
    expect(modelTakeoff(m).footVol,
        closeTo(3 * (auto.vol + stem) + auto.vol + stem60, 1e-6));
    b.footD = 0;
    // shallow footing (0.20 < Table 305-1's 0.30 for a 1-storey model)
    // -> embedment warning with a depth fix to the floor-aware minimum
    b.footD = 0.20;
    var r = designCalc(m, DesignParams());
    final dep = rowOf(r, 'FOOTINGS', 'embedment')!;
    expect(dep.status, Chk.warn);
    expect(dep.fix!.kind, 'footing-depth');
    applyDesignFix(m, dep.fix!);
    expect(b.footD, 0.30);
    r = designCalc(m, DesignParams());
    expect(rowOf(r, 'FOOTINGS', 'embedment')!.status, Chk.ok);
    // footD round-trips through project JSON
    final j = jsonDecode(jsonEncode(m.toJson()));
    expect(Model3d.fromJson(j).blocks.first.footD, 0.30);
  });

  test('overloaded column fix enlarges the section until it passes', () {
    final m = overloaded();
    var r = designCalc(m, DesignParams());
    final row = rowOf(r, 'COLUMNS', 'C1')!;
    expect(row.status, Chk.fail);
    expect(row.fix!.kind, 'column');
    final target = row.fix!.value;
    expect(target, greaterThan(0.2));

    applyDesignFix(m, row.fix!);
    final b = m.blocks.firstWhere((x) => x.id == row.fix!.targetId);
    expect(b.sx * 0.3, closeTo(target, 1e-9));
    expect(b.sy, closeTo(b.sx, 1e-9)); // stays square

    r = designCalc(m, DesignParams());
    expect(rowOf(r, 'COLUMNS', 'C1')!.status, isNot(Chk.fail));
  });

  test('thin slab fix raises the volume to the code minimum', () {
    final m = house();
    m.volumes.first.height = 0.05;
    var r = designCalc(m, DesignParams());
    final row = r.sections
        .firstWhere((s) => s.title.contains('SLABS'))
        .rows
        .firstWhere((x) => x.label.contains('TWO-WAY'));
    expect(row.status, Chk.fail);
    expect(row.fix!.kind, 'slab');

    applyDesignFix(m, row.fix!);
    expect(m.volumes.first.height, greaterThanOrEqualTo(0.125));
    r = designCalc(m, DesignParams());
    final after = r.sections
        .firstWhere((s) => s.title.contains('SLABS'))
        .rows
        .firstWhere((x) => x.label.contains('TWO-WAY'));
    expect(after.status, Chk.ok);
  });

  test('manual footW flows to takeoff, render and JSON round-trip', () {
    final m = house();
    m.blocks.first.footW = 2.2;
    final t = modelTakeoff(m);
    // 3 auto footings (0.3m col -> 1.5x1.5x0.30 pad; the 1-storey
    // Table 305-1 default 0.30m leaves no stem) + the 2.2m manual one
    // (t=0.44 already deeper than the 0.30 embedment -> no stem)
    const stemAuto = 0.0, stemMan = 0.0;
    expect(
        t.footVol,
        closeTo(
            3 * (1.5 * 1.5 * 0.30 + stemAuto) + 2.2 * 2.2 * 0.44 + stemMan,
            1e-6));
    final faces = m.cachedFaces();
    expect(faces, isNotEmpty);
    final j = jsonDecode(jsonEncode(m.toJson()));
    final m2 = Model3d.fromJson(j);
    expect(m2.blocks.first.footW, 2.2);
    expect(m2.blocks.first.footing, isTrue);
  });

  testWidgets('FIX button and FIX ALL mutate the model and recompute',
      (t) async {
    t.view.physicalSize = const Size(1500, 1000);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    est.newProject();
    est.models
      ..clear()
      ..add(overloaded());
    await t.pumpWidget(const MaterialApp(home: Scaffold(body: DesignView())));
    await t.pump();

    final failsBefore =
        designCalc(est.models.first, est.design).fail;
    expect(failsBefore, greaterThan(0));
    expect(find.byKey(const ValueKey('design-fix-all')), findsOneWidget);

    // per-row FIX button on a footing row (the report ListView lazily
    // builds off-screen rows, so scroll until it exists)
    final blk = est.models.first.blocks.first;
    await t.scrollUntilVisible(
        find.byKey(ValueKey('fix-${blk.id}-footing-all')), 300,
        scrollable: find.byType(Scrollable).last);
    await t.tap(find.byKey(ValueKey('fix-${blk.id}-footing-all')).first);
    await t.pump();
    expect(blk.footing, isTrue);
    expect(blk.footW, greaterThan(0));
    // the single click built footings under ALL missing columns
    expect(est.models.first.blocks.every((b) => b.footing), isTrue);

    // FIX ALL resolves the remaining fixes (scroll back up to the
    // header - the ListView unmounts off-screen children)
    await t.scrollUntilVisible(find.byKey(const ValueKey('design-fix-all')),
        -300,
        scrollable: find.byType(Scrollable).last);
    await t.tap(find.byKey(const ValueKey('design-fix-all')));
    await t.pump();
    final r = designCalc(est.models.first, est.design);
    expect(r.fail, lessThan(failsBefore));
    expect(est.models.first.blocks.every((b) => b.footing), isTrue);
  });
}
