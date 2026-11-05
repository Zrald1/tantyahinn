import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:tantyahin/cpm.dart';
import 'package:tantyahin/docx_export.dart';
import 'package:tantyahin/models.dart';
import 'package:tantyahin/state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  //   A(3) ──► C(2) ──► E(6) ──► F(3)
  //   B(4) ──────────►          ▲
  //         D(5) ───────────────┘
  //   critical path A-C-E-F = 14 days
  List<CpmActivity> net() => [
        CpmActivity(name: 'A', days: 3),
        CpmActivity(name: 'B', days: 4),
        CpmActivity(name: 'C', days: 2, preds: 'A'),
        CpmActivity(name: 'D', days: 5, preds: 'A'),
        CpmActivity(name: 'E', days: 6, preds: 'B,C'),
        CpmActivity(name: 'F', days: 3, preds: 'D,E'),
      ];

  test('forward/backward pass produces ES/EF/LS/LF and slack', () {
    final r = computeCpm(net());
    expect(r.error, isNull);
    expect(r.duration, 14);
    final byLetter = {for (final n in r.nodes) n.letter: n};
    expect(byLetter['A']!.es, 0);
    expect(byLetter['A']!.ef, 3);
    expect(byLetter['E']!.es, 5); // waits for B (EF 4) and C (EF 5)
    expect(byLetter['E']!.ef, 11);
    expect(byLetter['D']!.slack, 3); // D can slip 3d before hitting F
    expect(byLetter['B']!.slack, 1);
    expect(byLetter['C']!.slack, 0);
    expect(r.criticalPath, 'A-C-E-F');
  });

  test('cycle reports an error instead of hanging', () {
    final r = computeCpm([
      CpmActivity(name: 'A', days: 1, preds: 'B'),
      CpmActivity(name: 'B', days: 1, preds: 'A'),
    ]);
    expect(r.error, isNotNull);
  });

  test('layout levels and lanes track the network depth', () {
    final r = computeCpm(net());
    final byLetter = {for (final n in r.nodes) n.letter: n};
    expect(byLetter['A']!.level, 0);
    expect(byLetter['B']!.level, 0);
    expect(byLetter['C']!.level, 1);
    expect(byLetter['E']!.level, 2);
    expect(byLetter['F']!.level, 3);
    // A and B share level 0 on different lanes
    expect(byLetter['A']!.lane, isNot(byLetter['B']!.lane));
  });

  test('s-curve is monotonic and ends at 100%', () {
    final r = computeCpm([
      CpmActivity(name: 'A', days: 7, cost: 70),
      CpmActivity(name: 'B', days: 14, cost: 140, preds: 'A'),
    ]);
    final rows = buildSCurve(r, horizonDays: 21);
    expect(rows.length, 3);
    var last = 0.0;
    for (final row in rows) {
      expect(row.cumPct, greaterThanOrEqualTo(last));
      last = row.cumPct;
    }
    expect(rows.last.cumPct, closeTo(1.0, 1e-9));
    // A's 70 across days 0-7 lands fully inside week 1
    expect(rows.first.planned, closeTo(70 + 0.0, 1e-9));
  });

  test('s-curve buckets: day/week/month cover the same horizon', () {
    final r = computeCpm([
      CpmActivity(name: 'A', days: 7, cost: 70),
      CpmActivity(name: 'B', days: 14, cost: 140, preds: 'A'),
    ]);
    // 21-day horizon: 21 daily rows, 3 weekly rows, 1 monthly row.
    final days =
        buildSCurve(r, horizonDays: 21, bucket: CurveBucket.day);
    expect(days.length, 21);
    expect(days.first.tag, 'D');
    expect(days.first.fromDay, 1);
    expect(days.first.toDay, 1);
    expect(days.last.toDay, 21);
    expect(days.last.cumPct, closeTo(1.0, 1e-9));

    final weeks =
        buildSCurve(r, horizonDays: 21, bucket: CurveBucket.week);
    expect(weeks.length, 3);
    expect(weeks[1].fromDay, 8);
    expect(weeks[1].toDay, 14);
    expect(weeks.last.cumPct, closeTo(1.0, 1e-9));

    final months =
        buildSCurve(r, horizonDays: 60, bucket: CurveBucket.month);
    expect(months.length, 2);
    expect(months.first.tag, 'M');
    expect(months.first.fromDay, 1);
    expect(months.first.toDay, 30);
    expect(months.last.toDay, 60);
    expect(months.last.cumPct, closeTo(1.0, 1e-9));
    // bucketing never loses planned value
    for (final rows in [days, weeks, months]) {
      expect(rows.fold<double>(0, (a, b) => a + b.planned),
          closeTo(210.0, 1e-9));
    }
  });

  test('extensions stamp the creation date and snapshot the project',
      () {
    final e = EstimateState();
    e.project.title = 'TEST PROJECT';
    final before = DateTime.now();
    final x = e.addExtension();
    expect(x.createdAt.isBefore(before), isFalse);
    expect(x.projectRef, 'TEST PROJECT');
    expect(x.validatedBy, e.project.signatories[0].name);
    expect(x.approvedBy, e.project.signatories[3].name);
    expect(e.extensions, contains(x));
  });

  test('extension letter docx contains the letterhead and fields', () {
    final e = EstimateState();
    final x = e.addExtension()
      ..projectRef = 'Lot 7 – TEST WORKS'
      ..contractor = 'ACME BUILDERS'
      ..days = 45;
    final bytes = DocxExport.build(x);
    final doc = utf8.decode(ZipDecoder()
        .decodeBytes(bytes)
        .files
        .firstWhere((f) => f.name == 'word/document.xml')
        .content as List<int>);
    expect(doc, contains('EXTENSION OF CONTRACT DURATION'));
    expect(doc, contains('ACME BUILDERS'));
    expect(doc, contains('45-days extension'));
    expect(doc, contains('Lot 7'));
    expect(doc, contains(e.project.letterhead.first));
  });

  test('activities + extensions survive a save/load round-trip', () {
    final e = EstimateState()
      ..activities.addAll(net())
      ..addExtension();
    final j = e.toJson();
    final e2 = EstimateState()..loadJson(j);
    expect(e2.activities.length, net().length);
    expect(e2.activities[4].preds, 'B,C');
    expect(e2.extensions.length, 1);
    expect(e2.extensions.first.days, 30);
  });

  test('syncSchedule generates the network and stays in sync', () {
    final e = EstimateState();
    final s1 = e.sectionForTitle('SITE WORKS');
    e.addLine(s1, BoqLine(
        description: 'Excavation',
        unit: 'cu.m',
        qty: 10,
        materialCost: 500));
    e.syncSchedule(force: true);
    // exactly one activity per BOQ section — nothing extra invented
    expect(e.activities.map((a) => a.name).toList(),
        ['SITE WORKS']);

    // a section added later regenerates with the new trade
    final s2 = e.sectionForTitle('MASONRY WORKS');
    e.addLine(s2, BoqLine(
        description: 'CHB 4"', unit: 'pcs', qty: 100, materialCost: 90));
    e.syncSchedule();
    expect(e.activities.map((a) => a.name).toList(),
        ['SITE WORKS', 'MASONRY WORKS']);
    // masonry hangs off site preparation, not on a phantom trade
    expect(
        e.activities
            .firstWhere((a) => a.name == 'MASONRY WORKS')
            .predIds
            .length,
        1);

    // nothing new -> no-op; sync state survives a round-trip
    e.syncSchedule();
    final e2 = EstimateState()..loadJson(e.toJson());
    expect(e2.activities.length, e.activities.length);
  });

  test('applyCpmDuration writes CD = critical path + unworkable days',
      () {
    final e = EstimateState()
      ..activities.addAll(net());
    e.project.unworkableDays = 10;
    e.applyCpmDuration(computeCpm(e.activities).duration);
    // critical path is 14 -> 14 + 10 unworkable = 24 calendar days
    expect(e.project.contractDuration, '24 calendar days');
    expect(parseDays(e.project.contractDuration), 24);
  });

  // ---------- construction-logic schedule generation ----------

  EstimateState boq() {
  final e = EstimateState();
  BoqLine line(String d, {double mat = 1000}) =>
      BoqLine(description: d, unit: 'lot', qty: 1, materialCost: mat);
  for (final t in [
    'SITE WORKS',
    'CONCRETING WORKS',
    'MASONRY WORKS',
    'ELECTRICAL WORKS',
    'ROOFING WORKS',
    'PAINTING WORKS',
  ]) {
    e.addLine(e.sectionForTitle(t), line('item'));
  }
  e.project.contractDuration = '90 days';
  return e;
  }

  test('generated network has parallel branches and real junctions',
      () {
    final e = boq()..syncSchedule(force: true);
    final r = computeCpm(e.activities);
    expect(r.error, isNull);
    // concurrent work fronts: several lanes and multi-pred junctions
    expect(r.laneCount, greaterThan(1));
    expect(e.activities.where((a) => a.predIds.length > 1).length,
        greaterThan(0));
    // site works is the unique start; painting closes the finishing
    // trades as the deepest phase
    expect(
        e.activities.where((a) => a.predIds.isEmpty).single.name,
        'SITE WORKS');
    expect(e.activities.last.name, 'PAINTING WORKS');
    // painting waits on both the wall lane (masonry) and the roof
    // lane — a real junction in the network
    expect(
        e.activities
            .firstWhere((a) => a.name == 'PAINTING WORKS')
            .predIds
            .length,
        2);
    // parallel: electrical hangs off masonry, roofing off concrete —
    // two independent lanes with no order between them
    final elec = e.activities
        .firstWhere((a) => a.name == 'ELECTRICAL WORKS');
    final roof = e.activities
        .firstWhere((a) => a.name == 'ROOFING WORKS');
    final mas = e.activities
        .firstWhere((a) => a.name == 'MASONRY WORKS');
    final con = e.activities
        .firstWhere((a) => a.name == 'CONCRETING WORKS');
    expect(elec.predIds, [mas.id]);
    expect(roof.predIds, [con.id]);
    // fitted to the contract duration (working days, not 10k days)
    expect(r.duration, lessThanOrEqualTo(91));
    expect(r.duration, greaterThan(30));
  });

  test('sync preserves manual edits and suppressed deletions', () {
    final e = boq()..syncSchedule(force: true);
    final chb =
        e.activities.firstWhere((a) => a.name.contains('MASONRY'));
    e.setActivityDays(chb, 40);
    e.setActivityName(chb, 'CHB WORKS (REVISED)');
    final site =
        e.activities.firstWhere((a) => a.name == 'SITE WORKS');
    e.removeActivity(site);
    e.activities.add(CpmActivity(name: 'MY CUSTOM', days: 5));

    e.syncSchedule(force: true); // BOQ unchanged shape -> merge
    expect(chb.days, 40); // daysFixed survives regeneration
    expect(chb.name, 'CHB WORKS (REVISED)'); // nameFixed survives
    expect(e.activities.any((a) => a.name == 'SITE WORKS'),
        isFalse); // suppressed row stays deleted
    expect(e.activities.any((a) => a.name == 'MY CUSTOM'), isTrue);

    // Rebuild discards overrides and restores the deleted row
    e.rebuildScheduleFromBoq();
    expect(e.activities.any((a) => a.name == 'SITE WORKS'), isTrue);
  });

  test('a new BOQ section gains auto activities on the next sync', () {
    final e = boq()..syncSchedule(force: true);
    final before = e.activities.length;
    e.addLine(e.sectionForTitle('PLUMBING WORKS'),
        BoqLine(description: 'pipes', unit: 'lot', materialCost: 500));
    e.syncSchedule();
    expect(e.activities.length, greaterThan(before));
    expect(e.activities.any((a) => a.name.contains('PLUMBING')),
        isTrue);
    // and the graph is still a valid DAG
    expect(computeCpm(e.activities).error, isNull);
  });

  test('activities are exactly the user\'s BOQ sections', () {
    // The user's real case: one MASONRY section -> ONE activity named
    // "MASONRY WORKS", no stages, no process rows, nothing invented.
    final e = EstimateState();
    BoqLine line(String d) =>
        BoqLine(description: d, unit: 'lot', qty: 1, materialCost: 1000);
    final s = e.sectionForTitle('MASONRY WORKS');
    for (final d in [
      'CHB 4"', 'CEMENT 40kg', 'SAND',
      'Steel bar 12mm', 'Tie Wire #16 25kg/roll'
    ]) {
      e.addLine(s, line(d));
    }
    e.project.contractDuration = '60 days';
    e.syncSchedule(force: true);
    expect(e.activities.map((a) => a.name).toList(),
        ['MASONRY WORKS']);
    expect(e.activities.single.predIds, isEmpty);
    expect(computeCpm(e.activities).error, isNull);

    // Adding a second section gives exactly two activities — parallel
    // only where construction logic honestly allows it.
    final e2 = EstimateState();
    e2.addLine(e2.sectionForTitle('MASONRY WORKS'), line('blocks'));
    e2.addLine(e2.sectionForTitle('CEILING WORKS'), line('boards'));
    e2.project.contractDuration = '60 days';
    e2.syncSchedule(force: true);
    final names2 = e2.activities.map((a) => a.name).toSet();
    expect(names2, {'MASONRY WORKS', 'CEILING WORKS'});
    // ceiling doesn't wait on walls in a fit-out — independent lanes
    expect(
        e2.activities
            .firstWhere((a) => a.name == 'CEILING WORKS')
            .predIds,
        isEmpty);
    expect(computeCpm(e2.activities).error, isNull);
  });

  test('editing contract duration re-fits the generated schedule', () {
    final e = boq()..syncSchedule(force: true);
    // 90-day contract, 0 unworkable -> critical path fits 90
    expect(computeCpm(e.activities).duration, closeTo(90.0, 0.5));

    // the BOQ 'CD' field setter now calls syncSchedule() - simulate
    // exactly that edit path
    e.project.contractDuration = '45 calendar days';
    e.syncSchedule();
    expect(computeCpm(e.activities).duration, closeTo(45.0, 0.5));

    // unworkable days are on top of the critical path
    e.project.unworkableDays = 10;
    e.project.contractDuration = '60 calendar days';
    e.syncSchedule();
    expect(computeCpm(e.activities).duration, closeTo(50.0, 0.5));
  });

  test('dragging a node rewires predecessors and re-letters rows', () {
    final e = boq()..syncSchedule(force: true);
    var r = computeCpm(e.activities);
    expect(r.error, isNull);

    // drag MASONRY into the first column -> becomes a start activity,
    // running parallel with the other level-0 works
    final mas = e.activities.firstWhere(
        (a) => a.name == 'MASONRY WORKS');
    expect(e.moveActivityToCell(mas, 0, 0), isNull);
    expect(mas.predIds, isEmpty);
    expect(mas.predsFixed, isTrue);
    r = computeCpm(e.activities);
    expect(r.error, isNull);
    expect(
        r.nodes.firstWhere((n) => n.a == mas).level, 0);

    // letters follow the new topological order (sorted by level+lane)
    for (var i = 0; i < e.activities.length; i++) {
      expect(e.activities[i].preds,
          e.activities[i].predIds.map(
              (id) => cpmLetter(
                  e.activities.indexWhere((x) => x.id == id))).join(','));
    }

    // drag it back one column past concreting -> sequential again:
    // preds = every node in the column to its left, minus its own
    // descendants (wiring them would cycle — e.g. ELECTRICAL which
    // already follows MASONRY)
    r = computeCpm(e.activities);
    final lvl = r.nodes
        .firstWhere((n) =>
            n.a.name == 'CONCRETING WORKS')
        .level;
    final expected = {
      for (final n in r.nodes)
        if (n.level == lvl && n.a.name != 'ELECTRICAL WORKS') n.a.id
    };
    expect(e.moveActivityToCell(mas, lvl + 1, 1), isNull);
    expect(mas.predIds.toSet(), expected);
    expect(
        computeCpm(e.activities)
            .nodes
            .firstWhere((n) => n.a == mas)
            .level,
        lvl + 1);

    // a drop that would cycle the network is refused and rolls back
    final steel = e.activities
        .firstWhere((a) => a.name == 'SITE WORKS');
    final predsBefore = List.of(steel.predIds);
    r = computeCpm(e.activities);
    final masLvl =
        r.nodes.firstWhere((n) => n.a == mas).level;
    // SITE WORKS is a predecessor-chain root; dropping it behind a
    // descendant column keeps the graph acyclic OR is rejected — the
    // state stays valid either way
    final err = e.moveActivityToCell(steel, masLvl + 1, 0);
    if (err != null) {
      expect(steel.predIds, predsBefore);
    }
    expect(computeCpm(e.activities).error, isNull);
  });
}
