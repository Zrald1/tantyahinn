import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:archive/archive.dart';

import 'package:tantyahin/cpm.dart';
import 'package:tantyahin/docx_export.dart';
import 'package:tantyahin/dxf.dart';
import 'package:tantyahin/main.dart';
import 'package:tantyahin/model3d.dart';
import 'package:tantyahin/models.dart';
import 'package:tantyahin/obj.dart';
import 'package:tantyahin/pdf_export.dart';
import 'package:tantyahin/state.dart';
import 'package:tantyahin/ui/model_view.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';

void main() {
  // each test gets one fresh project session — the per-session view
  // tab and models must not leak between pumps
  setUp(() => projectTabs.reset());

  testWidgets('app boots with insert-work panel', (tester) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const BoqApp());
    expect(find.text('INSERT WORK'), findsOneWidget);
    expect(find.text('BOQ SHEET'), findsOneWidget);

    // POW tab switches the left paper to the program of works
    await tester.tap(find.text('POW'));
    await tester.pumpAndSettle();
    expect(find.text('POW SHEET'), findsOneWidget);
    expect(find.text('No work items yet'), findsOneWidget);
    await tester.tap(find.text('BOQ'));
    await tester.pumpAndSettle();
    expect(find.text('BOQ SHEET'), findsOneWidget);
  });

  testWidgets('add signatory inserts an editable entry', (tester) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const BoqApp());
    est.addSection('TEST SECTION');
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Add signatory'));
    await tester.pumpAndSettle();
    final before = est.project.signatories.length;
    await tester.tap(find.text('Add signatory'));
    await tester.pumpAndSettle();
    expect(est.project.signatories.length, before + 1);
    expect(find.text('Noted by'), findsWidgets);
    est.project.signatories.removeLast();
    est.sections.clear();
  });

  testWidgets('right-click a BOQ row inserts and deletes rows', (tester) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const BoqApp());
    final sec = est.sectionForTitle('MASONRY WORKS');
    est.addLine(sec, BoqLine(description: 'WIDGET ITEM', unit: 'pcs'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('WIDGET ITEM'));
    await tester.pumpAndSettle();

    // right-click → Insert item below
    await tester.tap(find.text('WIDGET ITEM'), buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    expect(find.text('Insert item below'), findsOneWidget);
    await tester.tap(find.text('Insert item below'));
    await tester.pumpAndSettle();
    expect(sec.lines.length, 2);
    expect(sec.lines[1].description, 'New item');

    // right-click → Delete row removes exactly that row
    await tester.tap(find.text('WIDGET ITEM'), buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete row'));
    await tester.pumpAndSettle();
    expect(sec.lines.length, 1);
    expect(sec.lines.single.description, 'New item');

    est.sections.clear();
  });

  testWidgets('right-click a letterhead line inserts/emphasizes lines', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const BoqApp());
    final sec = est.sectionForTitle('X');
    est.addLine(sec, BoqLine(description: 'I', unit: 'pcs'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Region V'));
    await tester.pumpAndSettle();

    // right-click 'Region V' → Insert line below pushes the bold line down
    await tester.tap(find.text('Region V'), buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    expect(find.text('Insert line below'), findsOneWidget);
    await tester.tap(find.text('Insert line below'));
    await tester.pumpAndSettle();
    expect(est.project.letterhead.length, 6);
    expect(est.project.letterhead[3], '');
    expect(est.project.letterheadBold, 4); // emphasis followed its line

    est.project.letterhead = ProjectInfo.defaultLetterhead.toList();
    est.project.letterheadBold = ProjectInfo.defaultLetterheadBold;
    est.sections.clear();
  });

  testWidgets('PERT-CPM tab builds the activity network', (tester) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const BoqApp());
    final sec = est.sectionForTitle('MASONRY WORKS');
    est.addLine(sec, BoqLine(description: 'CHB 4"', unit: 'pcs'));
    await tester.pumpAndSettle();

    // ceiling runs parallel to masonry; painting joins both lanes —
    // real fork + junction from the user's own sections
    est.addLine(
      est.sectionForTitle('CEILING WORKS'),
      BoqLine(description: 'Boards', unit: 'lot', qty: 1),
    );
    est.addLine(
      est.sectionForTitle('PAINTING WORKS'),
      BoqLine(description: 'Paint', unit: 'lot', qty: 1),
    );

    await tester.tap(find.text('PROJECT SCHEDULE'));
    await tester.pumpAndSettle();
    expect(find.text('PERT-CPM'), findsWidgets);
    // exactly one activity per BOQ section — nothing invented
    expect(est.activities.map((a) => a.name).toSet(), {
      'MASONRY WORKS',
      'CEILING WORKS',
      'PAINTING WORKS',
    });
    expect(est.activities.first.predIds, isEmpty);
    expect(find.textContaining('CRITICAL PATH'), findsWidgets);
    final cpm = computeCpm(est.activities);
    expect(cpm.error, isNull);
    expect(cpm.laneCount, greaterThan(1)); // parallel branches
    expect(
      cpm.nodes.where((n) => n.predIdx.length > 1).length,
      greaterThan(0),
    ); // a merge/junction exists

    // Philippine duration strip: critical path + unworkable -> Apply
    est.project.unworkableDays = 10;
    await tester.pumpAndSettle();
    final cpmDays = computeCpm(est.activities).duration;
    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();
    expect(
      est.project.contractDuration,
      '${(cpmDays + 10).toInt()} calendar days',
    );

    // right-click a row → Delete activity (auto row stays suppressed)
    await tester.tap(
      find.text('CEILING WORKS'),
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();
    expect(find.text('Delete activity'), findsOneWidget);
    await tester.tap(find.text('Delete activity'));
    await tester.pumpAndSettle();
    expect(est.activities.any((a) => a.name == 'CEILING WORKS'), isFalse);
    est.activities.clear();
    est.suppressedAutoIds.clear();
    est.sections.clear();
  });

  testWidgets('PERT-CPM rows track BOQ sections and show their letter', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const BoqApp());
    final sec = est.sectionForTitle('CEILING WORKS');
    est.addLine(
      sec,
      BoqLine(
        description: 'Ficem board',
        unit: 'pcs',
        qty: 38,
        materialCost: 683,
        laborCost: 273,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('PROJECT SCHEDULE'));
    await tester.pumpAndSettle();

    // generated rows name the section and carry its letter badge
    expect(est.activities.any((a) => a.name == 'CEILING WORKS'), isTrue);
    final linked = est.activities.where((a) => a.sectionId == sec.id);
    expect(linked.length, 1);
    // the BOQ column badge carries the section letter + tooltip
    expect(find.byTooltip('From BOQ section A — CEILING WORKS'), findsWidgets);

    // rename the section -> generated names follow the BOQ title
    sec.title = 'ACOUSTIC CEILING WORKS';
    est.update();
    est.syncSchedule(force: true);
    await tester.pumpAndSettle();
    expect(
      est.activities.any((a) => a.name == 'ACOUSTIC CEILING WORKS'),
      isTrue,
    );
    expect(est.activities.any((a) => a.name == 'CEILING WORKS'), isFalse);

    // add a second section -> its trade stages appear
    final sec2 = est.sectionForTitle('PAINTING WORKS');
    est.addLine(sec2, BoqLine(description: 'Latex', unit: 'liters', qty: 10));
    est.syncSchedule(force: true);
    await tester.pumpAndSettle();
    expect(
      est.activities.any((a) => a.name.startsWith('PAINTING WORKS')),
      isTrue,
    );

    // delete the section -> its auto rows leave the network
    est.sections.remove(sec);
    est.update();
    est.syncSchedule(force: true);
    await tester.pumpAndSettle();
    expect(est.activities.any((a) => a.sectionId == sec.id), isFalse);
    expect(
      est.activities.any((a) => a.name.contains('ACOUSTIC CEILING')),
      isFalse,
    );

    est.activities.clear();
    est.suppressedAutoIds.clear();
    est.sections.clear();
    est.trackItems.clear();
    est.inspections.clear();
  });

  testWidgets('S-CURVE and EXTENSION tabs render', (tester) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const BoqApp());
    est.activities.add(CpmActivity(name: 'WORKS', days: 14, cost: 100));
    await tester.pumpAndSettle();

    await tester.tap(find.text('PROJECT SCHEDULE'));
    await tester.pumpAndSettle();
    // switch the inner toggle to the S-CURVE view
    await tester.tap(find.text('S-CURVE'));
    await tester.pumpAndSettle();
    expect(find.text('S-CURVE'), findsWidgets);
    expect(find.text('W1'), findsOneWidget);

    await tester.tap(find.text('EXTENSION'));
    await tester.pumpAndSettle();
    expect(find.text('No extension recorded yet'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'New extension'));
    await tester.pumpAndSettle();
    expect(find.text('EXTENSION OF CONTRACT DURATION'), findsWidgets);
    expect(est.extensions.length, 1); // stamped with today's date
    est.extensions.clear();
    est.activities.clear();
  });

  testWidgets('PROJECT MANAGEMENT tracks item status and inspections', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const BoqApp());
    final sec = est.sectionForTitle('MASONRY WORKS');
    est.addLine(sec, BoqLine(description: 'CHB 4"', unit: 'pcs'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('PROJECT MANAGEMENT'));
    await tester.pumpAndSettle();
    expect(find.text('WORK ITEMS'), findsOneWidget);
    expect(find.text('SITE INSPECTIONS'), findsOneWidget);
    // section synced into a linked tracking row
    expect(est.trackItems.length, 1);
    expect(est.trackItems[0].name, 'MASONRY WORKS');
    expect(est.trackItems[0].status, 'pending');
    // status dropdown: pending -> on-going -> completed
    final st = find.byKey(ValueKey('status-${est.trackItems[0].id}'));
    await tester.tap(st);
    await tester.pumpAndSettle();
    await tester.tap(find.text('On-going').last);
    await tester.pumpAndSettle();
    expect(est.trackItems[0].status, 'ongoing');
    await tester.tap(st);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Completed').last);
    await tester.pumpAndSettle();
    expect(est.trackItems[0].status, 'completed');

    // KPI tile filters the table; All restores it
    await tester.tap(find.byKey(const ValueKey('kpi-pending')));
    await tester.pumpAndSettle();
    expect(find.text('No work items match this filter.'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('kpi-all')));
    await tester.pumpAndSettle();
    expect(find.text('MASONRY WORKS'), findsOneWidget);

    // custom work items via the Add dialog — several lines at once
    await tester.tap(find.text('Add item'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextField).last,
      'SITE TEMP WORKS\nSAFETY & HEALTH',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Add'));
    await tester.pumpAndSettle();
    expect(est.trackItems.length, 3);
    expect(est.trackItems[1].name, 'SITE TEMP WORKS');
    expect(est.trackItems[1].sectionId, isNull);
    expect(est.trackItems[2].name, 'SAFETY & HEALTH');

    // per-item % drives status; overall % is cost-weighted
    est.setTrackProgress(est.trackItems[1], 45);
    expect(est.trackItems[1].status, 'ongoing');
    est.setTrackProgress(est.trackItems[1], 100);
    expect(est.trackItems[1].status, 'completed');
    expect(est.overallProgress, greaterThan(0));

    // inspection log: add stamps today and auto-fills the
    // accomplishment snapshot; fields stay editable
    await tester.tap(find.text('Add inspection'));
    await tester.pumpAndSettle();
    expect(est.inspections.length, 1);
    expect(
      est.inspections[0].date,
      DateFormat('yyyy-MM-dd').format(DateTime.now()),
    );
    expect(est.inspections[0].findings, contains('Overall accomplishment'));
    Finder byHint(String hint) => find.byWidgetPredicate(
      (w) => w is TextField && w.decoration?.hintText == hint,
    );
    await tester.enterText(byHint('Inspector'), 'ENGR. DELA CRUZ');
    await tester.enterText(
      byHint('Findings / observations'),
      'All works on schedule',
    );
    await tester.pumpAndSettle();
    expect(est.inspections[0].inspector, 'ENGR. DELA CRUZ');
    expect(est.inspections[0].findings, 'All works on schedule');

    // persists through the project JSON round-trip
    final j = est.toJson();
    est.newProject();
    est.loadJson(Map<String, dynamic>.from(j));
    await tester.pumpAndSettle();
    expect(est.trackItems.length, 3);
    expect(est.trackItems[0].status, 'completed');
    expect(est.inspections.length, 1);

    est.trackItems.clear();
    est.inspections.clear();
    est.sections.clear();
  });

  testWidgets('DRAWINGS tab shows library, loads files, marks save', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const BoqApp());

    // empty state — and the insert-work inspector stays on the right
    await tester.tap(find.text('DRAWINGS'));
    await tester.pumpAndSettle();
    expect(find.text('No drawings yet'), findsOneWidget);
    expect(find.text('DRAWING FILES'), findsOneWidget);
    expect(find.text('INSERT WORK'), findsOneWidget);

    // seed the library with the DXF fixture -> it parses + renders
    final f = est.addDrawing(
      '${Directory.current.path}\\tool\\fixtures\\plan.dxf',
      'dxf',
    );
    await tester.pump();
    expect(find.text('plan.dxf'), findsOneWidget);
    // select it in the library -> triggers the async load. Real file
    // IO doesn't progress under the fake test clock, so give it a real
    // event loop with runAsync, then pump the frames.
    await tester.tap(find.text('plan.dxf'));
    await tester.pump();
    await tester.runAsync(
      () => Future.delayed(const Duration(milliseconds: 800)),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('Cannot open file'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);

    // mark tools: pick pen, drag a stroke on the canvas
    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.pumpAndSettle();
    final center = tester.getCenter(find.byType(InteractiveViewer));
    await tester.dragFrom(center, const Offset(80, 50));
    await tester.pumpAndSettle();
    expect(est.marksFor(f.id, 0).length, 1);
    // undo removes it
    await tester.tap(find.byIcon(Icons.undo));
    await tester.pumpAndSettle();
    expect(est.marksFor(f.id, 0), isEmpty);
    est.drawings.clear();
  });

  testWidgets('DRAWINGS zoom survives tab switch; focus mode splits '
      'with BOQ; file rail collapses', (tester) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const BoqApp());
    await tester.pumpAndSettle();
    await tester.tap(find.text('DRAWINGS'));
    await tester.pumpAndSettle();
    est.addDrawing(
      '${Directory.current.path}\\tool\\fixtures\\plan.dxf',
      'dxf',
    );
    await tester.pump();
    await tester.tap(find.text('plan.dxf'));
    await tester.pump();
    await tester.runAsync(
      () => Future.delayed(const Duration(milliseconds: 800)),
    );
    await tester.pump();
    await tester.pump();
    final iv = find.byType(InteractiveViewer);
    expect(iv, findsOneWidget);

    // pan the canvas (pan is the default tool) -> matrix changes and
    // is remembered in est under a 'file:page' key
    final c = tester.getCenter(iv);
    await tester.dragFrom(c, const Offset(-90, -60));
    await tester.pumpAndSettle();
    final before = List<double>.of(
      tester
          .widget<InteractiveViewer>(iv)
          .transformationController!
          .value
          .storage,
    );
    expect(
      est.drawingXfms.values.any((m) => orderedEquals(m).matches(before, {})),
      true,
    );

    // leave and come back -> the view widget is recreated but the
    // zoom/pan must be restored, not re-fitted
    await tester.tap(find.text('BOQ'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('DRAWINGS'));
    await tester.pumpAndSettle();
    final after = List<double>.of(
      tester
          .widget<InteractiveViewer>(iv)
          .transformationController!
          .value
          .storage,
    );
    expect(after, orderedEquals(before));

    // focus mode: tab strip hides, BOQ + inspector sit beside the
    // canvas — the matrix survives the reparent too
    await tester.ensureVisible(find.byIcon(Icons.fullscreen));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.fullscreen));
    await tester.pumpAndSettle();
    expect(est.drawingFocus, true);
    expect(find.text('PERT-CPM'), findsNothing);
    expect(find.text('BOQ SHEET'), findsOneWidget);
    expect(find.text('INSERT WORK'), findsOneWidget);
    final focused = List<double>.of(
      tester
          .widget<InteractiveViewer>(iv)
          .transformationController!
          .value
          .storage,
    );
    expect(focused, orderedEquals(before));

    // collapse the file rail -> 'DRAWING FILES' leaves the screen,
    // the rail's expand button brings it back
    await tester.tap(find.byIcon(Icons.chevron_left));
    await tester.pumpAndSettle();
    expect(find.text('DRAWING FILES'), findsNothing);
    await tester.tap(find.byIcon(Icons.chevron_right));
    await tester.pumpAndSettle();
    expect(find.text('DRAWING FILES'), findsOneWidget);

    // exit focus -> the tab strip comes back
    await tester.ensureVisible(find.byIcon(Icons.fullscreen_exit));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.fullscreen_exit));
    await tester.pumpAndSettle();
    expect(est.drawingFocus, false);
    expect(find.text('PROJECT SCHEDULE'), findsOneWidget);

    est.drawings.clear();
    est.drawingXfms.clear();
  });

  testWidgets('DRAWINGS marks can be selected and reshaped, notes type '
      'inline on the canvas', (tester) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const BoqApp());
    await tester.tap(find.text('DRAWINGS'));
    await tester.pumpAndSettle();
    final f = est.addDrawing(
      '${Directory.current.path}\\tool\\fixtures\\plan.dxf',
      'dxf',
    );
    await tester.pump();
    await tester.tap(find.text('plan.dxf'));
    await tester.pump();
    await tester.runAsync(
      () => Future.delayed(const Duration(milliseconds: 800)),
    );
    await tester.pump();
    await tester.pump();

    // draw a rectangle on the canvas
    await tester.tap(find.byIcon(Icons.crop_square));
    await tester.pumpAndSettle();
    final c = tester.getCenter(find.byType(InteractiveViewer));
    await tester.dragFrom(c, const Offset(160, 100));
    await tester.pumpAndSettle();
    expect(est.marksFor(f.id, 0).length, 1);
    final rect = est.marksFor(f.id, 0).first;
    expect(rect.kind, 'rect');

    // click ON the drawn rect with a draw tool still active -> it
    // becomes selected instead of starting a new mark
    await tester.tapAt(c + const Offset(80, 50));
    await tester.pumpAndSettle();

    // dragging inside it now moves the same mark (no new mark drawn)
    final before = List<double>.of(rect.pts);
    await tester.dragFrom(c + const Offset(80, 50), const Offset(40, 30));
    await tester.pumpAndSettle();
    expect(est.marksFor(f.id, 0).length, 1);
    expect(rect.pts[0], isNot(before[0]));
    expect(rect.pts[1], isNot(before[1]));

    // drag the bottom-right corner handle -> rect resizes
    final before2 = List<double>.of(rect.pts);
    await tester.dragFrom(c + const Offset(200, 130), const Offset(30, 25));
    await tester.pumpAndSettle();
    expect(est.marksFor(f.id, 0).length, 1);
    expect(rect.pts[2], greaterThan(before2[2]));
    expect(rect.pts[3], greaterThan(before2[3]));

    // click empty space -> deselect; back on the rect tool a drag
    // draws a NEW mark instead of moving the old one
    await tester.tapAt(c + const Offset(-300, -250));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.crop_square));
    await tester.pumpAndSettle();
    await tester.dragFrom(c + const Offset(-300, -250), const Offset(120, 60));
    await tester.pumpAndSettle();
    expect(est.marksFor(f.id, 0).length, 2);

    // text tool: tap the canvas -> an inline TextField appears right
    // on the sheet (no AlertDialog), typing + tapping away commits it
    est.drawings.clear();
    est.marks.clear();
    await tester.pump();
    final f2 = est.addDrawing(
      '${Directory.current.path}\\tool\\fixtures\\plan.dxf',
      'dxf',
    );
    await tester.pump();
    await tester.tap(find.text('plan.dxf'));
    await tester.pump();
    await tester.runAsync(
      () => Future.delayed(const Duration(milliseconds: 800)),
    );
    await tester.pump();
    await tester.pump();
    await tester.tap(find.byIcon(Icons.text_fields));
    await tester.pumpAndSettle();
    await tester.tapAt(c);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    final noteField = find.byWidgetPredicate(
      (w) => w is TextField && w.decoration?.hintText == 'Type note…',
    );
    expect(noteField, findsOneWidget);
    await tester.enterText(noteField, 'COL A GRID 1');
    await tester.tapAt(c + const Offset(-250, -200));
    await tester.pumpAndSettle();
    final notes = est
        .marksFor(f2.id, 0)
        .where((m) => m.kind == 'text')
        .toList();
    expect(notes.length, 1);
    expect(notes.first.text, 'COL A GRID 1');

    // and it survives the JSON autosave round-trip
    final j = est.toJson();
    final e2 = EstimateState()..loadJson(j);
    expect(
      e2
          .marksFor(f2.id, 0)
          .any((m) => m.kind == 'text' && m.text == 'COL A GRID 1'),
      isTrue,
    );

    // SEMANTICS: a draw tool ALWAYS draws — a drag that starts inside
    // a mark creates a new overlapping mark; adjusting is done by
    // tapping the mark first (adopts Select) or with the Select tool.
    final note = notes.first;
    final notePts = List<double>.of(note.pts);

    // Select tool: a drag on the note's body moves it — no new mark
    await tester.tap(find.byIcon(Icons.near_me_outlined));
    await tester.pumpAndSettle();
    await tester.dragFrom(c, const Offset(60, 40));
    await tester.pumpAndSettle();
    expect(note.pts[0], isNot(notePts[0]));
    expect(est.marksFor(f2.id, 0).length, 1);

    // with the rect tool active, a drag starting ON the note draws a
    // NEW mark instead of moving or resizing the note
    await tester.tap(find.byIcon(Icons.crop_square));
    await tester.pumpAndSettle();
    final beforeNote = List<double>.of(note.pts);
    await tester.dragFrom(c, const Offset(60, 40));
    await tester.pumpAndSettle();
    expect(est.marksFor(f2.id, 0).length, 2);
    expect(note.pts[0], beforeNote[0]);
    expect(note.pts[1], beforeNote[1]);

    // same for rects: draw one, then drag INSIDE it with the rect
    // tool still on -> a second overlapping rect is created
    await tester.tap(find.byIcon(Icons.crop_square));
    await tester.pumpAndSettle();
    await tester.dragFrom(c + const Offset(-200, -150), const Offset(140, 90));
    await tester.pumpAndSettle();
    expect(est.marksFor(f2.id, 0).length, 3);
    await tester.dragFrom(c + const Offset(-130, -105), const Offset(35, 25));
    await tester.pumpAndSettle();
    expect(est.marksFor(f2.id, 0).length, 4); // drew, not moved

    // tapping that rect selects it -> the same drag now MOVES it
    final r3 = est.marksFor(f2.id, 0).last;
    expect(r3.kind, 'rect');
    final r3pts = List<double>.of(r3.pts);
    await tester.tapAt(c + const Offset(-115, -92));
    await tester.pumpAndSettle();
    await tester.dragFrom(c + const Offset(-115, -92), const Offset(35, 25));
    await tester.pumpAndSettle();
    expect(est.marksFor(f2.id, 0).length, 4); // moved, not drawn
    expect(r3.pts[0], isNot(r3pts[0]));
    est.drawings.clear();
    est.marks.clear();
  });

  testWidgets('DRAWINGS keys: letters pick tools, Esc cancels, '
      'Ctrl+Z/Y/R undo+redo marks', (tester) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const BoqApp());

    await tester.tap(find.text('DRAWINGS'));
    await tester.pumpAndSettle();
    final f = est.addDrawing(
      '${Directory.current.path}\\tool\\fixtures\\plan.dxf',
      'dxf',
    );
    await tester.pump();
    await tester.tap(find.text('plan.dxf'));
    await tester.pump();
    await tester.runAsync(
      () => Future.delayed(const Duration(milliseconds: 800)),
    );
    await tester.pump();
    await tester.pump();
    final c = tester.getCenter(find.byType(InteractiveViewer));

    // canvas tap grabs key focus; 'R' picks the rect tool -> rect mark
    await tester.tapAt(c);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyR);
    await tester.pump();
    await tester.dragFrom(c + const Offset(-120, -90), const Offset(140, 90));
    await tester.pumpAndSettle();
    expect(est.marksFor(f.id, 0).single.kind, 'rect');

    // Esc steps outward like CAD: first press releases the just-drawn
    // mark's selection, second resets the tool to pan — then a drag
    // pans, draws nothing
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await tester.dragFrom(c + const Offset(-40, -40), const Offset(60, 50));
    await tester.pumpAndSettle();
    expect(est.marksFor(f.id, 0).length, 1);

    // Ctrl+Z removes the mark; Ctrl+Y restores it; Ctrl+Z again and
    // Ctrl+R restores too
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(est.marksFor(f.id, 0), isEmpty);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyY);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(est.marksFor(f.id, 0).length, 1);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(est.marksFor(f.id, 0), isEmpty);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyR);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(est.marksFor(f.id, 0).length, 1);

    // 'T' picks the text tool; a tap opens the inline editor and Esc
    // DISCARDS it — no mark, no field
    await tester.sendKeyEvent(LogicalKeyboardKey.keyT);
    await tester.pump();
    await tester.tapAt(c + const Offset(200, -120));
    await tester.pumpAndSettle();
    final noteField = find.byWidgetPredicate(
      (w) => w is TextField && w.decoration?.hintText == 'Type note…',
    );
    expect(noteField, findsOneWidget);
    await tester.enterText(noteField, 'discard me');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(noteField, findsNothing);
    expect(est.marksFor(f.id, 0).where((m) => m.kind == 'text'), isEmpty);

    est.drawings.clear();
    est.marks.clear();
  });

  testWidgets('DRAWINGS measure tool: per-page reference, labeled '
      'measurements, resettable', (tester) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const BoqApp());

    await tester.tap(find.text('DRAWINGS'));
    await tester.pumpAndSettle();
    final f = est.addDrawing(
      '${Directory.current.path}\\tool\\fixtures\\plan.dxf',
      'dxf',
    );
    await tester.pump();
    await tester.tap(find.text('plan.dxf'));
    await tester.pump();
    await tester.runAsync(
      () => Future.delayed(const Duration(milliseconds: 800)),
    );
    await tester.pump();
    await tester.pump();
    final c = tester.getCenter(find.byType(InteractiveViewer));

    // pick the measure tool with the 'M' shortcut
    await tester.tapAt(c);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
    await tester.pump();

    // first drag on an uncalibrated page is the REFERENCE — an inline
    // editor asks for its real length instead of adding a mark
    await tester.dragFrom(c + const Offset(-120, -80), const Offset(150, 90));
    await tester.pumpAndSettle();
    expect(est.marksFor(f.id, 0), isEmpty);
    final refField = find.byWidgetPredicate(
      (w) =>
          w is TextField &&
          w.decoration?.hintText == 'Real length of this line',
    );
    expect(refField, findsOneWidget);

    // Esc discards the pending reference — still uncalibrated
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(refField, findsNothing);
    expect(est.measureRefFor(f.id, 0), isNull);

    // draw it again, type 5000, Enter -> the page is calibrated and
    // the reference itself stays as a labeled measure mark
    await tester.dragFrom(c + const Offset(-120, -80), const Offset(150, 90));
    await tester.pumpAndSettle();
    await tester.enterText(refField, '5000');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(est.measureRefFor(f.id, 0), isNotNull);
    expect(est.marksFor(f.id, 0).single.text, '5,000 mm');

    // the reference is per page — other pages stay uncalibrated
    expect(est.measureRefFor(f.id, 1), isNull);

    // an equal-length drag elsewhere measures the same real length
    await tester.dragFrom(c + const Offset(-60, 130), const Offset(150, 90));
    await tester.pumpAndSettle();
    expect(est.marksFor(f.id, 0).last.text, '5,000 mm');

    // the Ref chip resets this page's calibration — the next drag is
    // a reference again
    await tester.tap(find.text('Ref 5,000mm'));
    await tester.pumpAndSettle();
    expect(est.measureRefFor(f.id, 0), isNull);
    await tester.dragFrom(c + const Offset(-120, -80), const Offset(150, 90));
    await tester.pumpAndSettle();
    expect(refField, findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    est.drawings.clear();
    est.marks.clear();
    est.measureRefs.clear();
  });

  testWidgets('DRAWINGS eraser: E tool removes marks on tap and drag', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const BoqApp());

    await tester.tap(find.text('DRAWINGS'));
    await tester.pumpAndSettle();
    final f = est.addDrawing(
      '${Directory.current.path}\\tool\\fixtures\\plan.dxf',
      'dxf',
    );
    await tester.pump();
    await tester.tap(find.text('plan.dxf'));
    await tester.pump();
    await tester.runAsync(
      () => Future.delayed(const Duration(milliseconds: 800)),
    );
    await tester.pump();
    await tester.pump();
    final c = tester.getCenter(find.byType(InteractiveViewer));

    // two rects + a pen stroke
    await tester.tap(find.byIcon(Icons.crop_square));
    await tester.pumpAndSettle();
    await tester.dragFrom(c + const Offset(-300, -250), const Offset(160, 100));
    await tester.pumpAndSettle();
    await tester.dragFrom(c + const Offset(120, 60), const Offset(160, 100));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.pumpAndSettle();
    await tester.dragFrom(c + const Offset(-150, 180), const Offset(80, 30));
    await tester.pumpAndSettle();
    expect(est.marksFor(f.id, 0).length, 3);

    // 'E' picks the eraser; a tap on empty space removes nothing
    await tester.tapAt(c);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyE);
    await tester.pump();
    await tester.tapAt(c + const Offset(0, -330));
    await tester.pumpAndSettle();
    expect(est.marksFor(f.id, 0).length, 3);

    // a tap on a mark erases it — rect 1 is gone, rect 2 + pen remain
    await tester.tapAt(c + const Offset(-220, -200)); // inside rect 1
    await tester.pumpAndSettle();
    expect(est.marksFor(f.id, 0).length, 2);
    expect(est.marksFor(f.id, 0).where((m) => m.kind == 'rect').length, 1);

    // a drag sweeps every mark the path crosses — pen stroke first
    await tester.dragFrom(c + const Offset(-260, 195), const Offset(220, 0));
    await tester.pumpAndSettle();
    expect(est.marksFor(f.id, 0).where((m) => m.kind == 'pen'), isEmpty);
    expect(est.marksFor(f.id, 0).length, 1);

    // then the remaining rect — erased marks are NOT undoable via
    // Ctrl+Z's mark pop (same contract as page clear)
    await tester.dragFrom(c + const Offset(100, 110), const Offset(200, 0));
    await tester.pumpAndSettle();
    expect(est.marksFor(f.id, 0), isEmpty);
    est.drawings.clear();
    est.marks.clear();
  });

  testWidgets('3D MODEL tab: create, draw footprint, generate sheet', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const BoqApp());
    await tester.pumpAndSettle();
    await tester.tap(find.text('3D MODEL'));
    await tester.pumpAndSettle();
    expect(find.text('3D MODELS'), findsOneWidget);

    // + New model -> the rail lists it; wall tool is the default
    await tester.tap(find.byTooltip('New model'));
    await tester.pumpAndSettle();
    expect(est.models.length, 1);
    final m = est.models.first;

    // WALL TOOL: tap three points -> re-tap the last ends the chain
    final pc = tester.getCenter(find.byKey(const Key('modelPlan')));
    await tester.tapAt(pc + const Offset(-160, -80));
    await tester.tapAt(pc + const Offset(120, -80));
    await tester.tapAt(pc + const Offset(120, 120));
    await tester.tapAt(pc + const Offset(120, 120));
    await tester.pumpAndSettle();
    expect(m.walls.length, 1);
    expect(m.walls.first.segs, 2);
    expect(m.walls.first.thickness, 0.15);
    expect(m.walls.first.length, greaterThan(3));

    // the wall extrudes into the shared 3D face list automatically
    expect(modelFaces(m).length, 10); // 2 prisms x (4 sides + cap)

    // BLOCK LIBRARY: filter to the WC and pick it, tap the plan
    await tester.enterText(find.byKey(const Key('lib-search')), 'toilet');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('lib-wc')));
    await tester.pumpAndSettle();
    await tester.tapAt(pc + const Offset(-40, 60));
    await tester.pumpAndSettle();
    expect(m.blocks.length, 1);
    expect(m.blocks.first.def, 'wc');

    // 3D CANVAS IS LIVE TOO: with the block tool still armed, a tap
    // on the 3D view unprojects onto the ground plane and places
    // another piece (wc -> 2 total)
    final mc = tester.getCenter(find.byKey(const Key('model3d')));
    await tester.tapAt(mc + const Offset(-60, -30));
    await tester.pumpAndSettle();
    expect(m.blocks.length, 2);

    // wall drawing on the 3D side: W tool, two taps -> third tap on
    // the same spot ends the chain -> a second wall appears
    await tester.sendKeyEvent(LogicalKeyboardKey.keyW);
    await tester.pumpAndSettle();
    await tester.tapAt(mc + const Offset(60, -60));
    await tester.pumpAndSettle();
    await tester.tapAt(mc + const Offset(140, 30));
    await tester.pumpAndSettle();
    await tester.tapAt(mc + const Offset(140, 30));
    await tester.pumpAndSettle();
    expect(m.walls.length, 2);
    expect(m.walls.last.segs, 1);

    // 3D PICKING + KEYS: select tool, tap the placed block's prism
    // in the 3D view -> it selects, then Delete removes it. Tap the
    // block's projected 3D centre — its screen spot shifts with the
    // orbit pivot, so a hardcoded offset can land on a wall face
    final st = tester.state(find.byType(ModelView)) as dynamic;
    final b3 = m.blocks.last;
    final b3c =
        tester.getTopLeft(find.byKey(const Key('model3d'))) +
        (st.debugProj3(b3.x, b3.y, 0.4) as Offset);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.pumpAndSettle();
    await tester.tapAt(b3c);
    await tester.pumpAndSettle();
    expect(m.blocks.length, 2);
    await tester.sendKeyEvent(LogicalKeyboardKey.delete);
    await tester.pumpAndSettle();
    expect(m.blocks.length, 1);

    // CTRL+Z UNDO: the delete rolls back (block returns), then the
    // second wall's creation undoes too
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(m.blocks.length, 2);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(m.walls.length, 1);
    // undo the extra block placement as well -> back to 1 wall 1 blk
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(m.blocks.length, 1);

    // FOCUS MODE: F hides the plan canvas so the 3D gets the width —
    // keys must still work (the shortcuts wrapper outlives the split)
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('modelPlan')), findsNothing);
    expect(find.byKey(const Key('model3d')), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('modelPlan')), findsOneWidget);

    // GENERATE DRAWING -> TEN DXF sheets (one per view) land in the
    // drawings library, each parseable by the real viewer stack
    await tester.tap(find.text('GENERATE DRAWING').first);
    await tester.pumpAndSettle();
    final sheets = est.drawings
        .where((d) => d.id.startsWith('sheet:${m.id}:'))
        .toList();
    expect(sheets.length, 10);
    final byId = {for (final d in sheets) d.id: d};
    expect(byId.keys.toSet(), {
      'sheet:${m.id}:floorplan',
      'sheet:${m.id}:structural',
      'sheet:${m.id}:roofframe',
      'sheet:${m.id}:electrical',
      'sheet:${m.id}:plumbing',
      'sheet:${m.id}:roofplan',
      'sheet:${m.id}:front',
      'sheet:${m.id}:rear',
      'sheet:${m.id}:left',
      'sheet:${m.id}:right',
    });
    for (final d in sheets) {
      expect(File(d.path).existsSync(), isTrue, reason: d.name);
    }
    // the floor plan sheet carries wall hatches + dim labels
    final planScene = DxfParser.parse(
      File(byId['sheet:${m.id}:floorplan']!.path).readAsStringSync(),
    );
    expect(planScene.prims.any((p) => p.fillLoops != null), isTrue);
    expect(
      planScene.texts.map((t) => t.text).join('|'),
      contains('FLOOR PLAN'),
    );
    // the front elevation is its OWN sheet with its own label
    final frontScene = DxfParser.parse(
      File(byId['sheet:${m.id}:front']!.path).readAsStringSync(),
    );
    expect(
      frontScene.texts.map((t) => t.text).join('|'),
      contains('FRONT ELEVATION'),
    );
    expect(
      frontScene.texts.map((t) => t.text).join('|'),
      isNot(contains('REAR ELEVATION')),
    );
    // and the two sheets live in different files
    expect(
      byId['sheet:${m.id}:front']!.path,
      isNot(byId['sheet:${m.id}:rear']!.path),
    );
    // discipline sheets: plumbing lists the placed WC, structural is
    // its own foundation drawing
    final plScene = DxfParser.parse(
      File(byId['sheet:${m.id}:plumbing']!.path).readAsStringSync(),
    );
    final plTxt = plScene.texts.map((t) => t.text).join('|');
    expect(plTxt, contains('PLUMBING PLAN'));
    expect(plTxt, contains('TOILET WC'));
    final strScene = DxfParser.parse(
      File(byId['sheet:${m.id}:structural']!.path).readAsStringSync(),
    );
    expect(
      strScene.texts.map((t) => t.text).join('|'),
      contains('STRUCTURAL PLAN - FOUNDATION'),
    );

    // regenerate -> same ten entries are reused, not duplicated
    await tester.tap(find.text('GENERATE DRAWING').first);
    await tester.pumpAndSettle();
    expect(
      est.drawings.where((d) => d.id.startsWith('sheet:${m.id}:')).length,
      10,
    );

    est.models.clear();
    est.drawings.clear();
  });

  testWidgets('3D MODEL dead canvas: first tap creates the model', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    est.newProject(); // zero models — the "i cant draw" dead state
    await tester.pumpWidget(const BoqApp());
    await tester.pumpAndSettle();
    await tester.tap(find.text('3D MODEL'));
    await tester.pumpAndSettle();
    expect(est.models, isEmpty);
    final st = tester.state(find.byType(ModelView)) as dynamic;

    // wall tool (default): a tap with NO model lazily creates Model 1
    // and lands the point — the canvas is never dead
    final pc = tester.getCenter(find.byKey(const Key('modelPlan')));
    await tester.tapAt(pc + const Offset(-100, -60));
    await tester.pumpAndSettle();
    expect(est.models.length, 1);
    expect(st.wallChainDebug.length, 1);

    // two more points + a same-spot re-tap ends the chain into Model 1
    await tester.tapAt(pc + const Offset(120, -60));
    await tester.tapAt(pc + const Offset(120, 90));
    await tester.tapAt(pc + const Offset(120, 90));
    await tester.pumpAndSettle();
    expect(est.models.first.walls.length, 1);
    expect(est.models.first.walls.first.segs, 2);

    // BLOCK TOOL on a second empty canvas: arm a block, tap the 3D
    // side — placement works there too and selects the piece
    est.models.clear();
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyB);
    await tester.pumpAndSettle();
    final mc = tester.getCenter(find.byKey(const Key('model3d')));
    await tester.tapAt(mc + const Offset(30, -20));
    await tester.pumpAndSettle();
    expect(est.models.length, 1);
    expect(est.models.first.blocks.length, 1);

    est.models.clear();
  });

  testWidgets('3D MODEL M command: pick a block, click to place it', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    est.modelIntroDismissed = true; // the tips card would eat the taps
    await tester.pumpWidget(const BoqApp());
    await tester.pumpAndSettle();
    await tester.tap(find.text('3D MODEL'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('New model'));
    await tester.pumpAndSettle();
    final m = est.models.first;
    final st = tester.state(find.byType(ModelView)) as dynamic;
    final planTL = tester.getTopLeft(find.byKey(const Key('modelPlan')));
    Offset w2s(double x, double y) =>
        planTL +
        Offset(
          (st.planOffset as Offset).dx + x * (st.planScale as double),
          (st.planOffset as Offset).dy - y * (st.planScale as double),
        );

    // place a block: a middle press grabs canvas key focus (it pans,
    // adds no wall point), then B + tap places the block
    final g0 = await tester.startGesture(
      w2s(6.0, -2.0),
      kind: PointerDeviceKind.mouse,
      buttons: kMiddleMouseButton,
    );
    await g0.up();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyB);
    await tester.pumpAndSettle();
    await tester.tapAt(w2s(6.0, -2.0));
    await tester.pumpAndSettle();
    expect(m.blocks.length, 1);
    final b = m.blocks.first;
    final x0 = b.x, y0 = b.y;

    // M with the block still selected picks it up straight away —
    // the next click places it somewhere else
    await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
    await tester.pumpAndSettle();
    await tester.tapAt(w2s(9.0, -3.0));
    await tester.pumpAndSettle();
    expect(b.x, isNot(x0));
    expect(b.y, isNot(y0));

    // deselect, then M + click ON the block picks it up again
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
    await tester.pumpAndSettle();
    await tester.tapAt(w2s(b.x, b.y));
    await tester.pumpAndSettle();
    await tester.tapAt(w2s(10.0, -5.0));
    await tester.pumpAndSettle();
    final x2 = b.x, y2 = b.y;
    expect(x2, isNot(9.0));
    expect(y2, isNot(-3.0));

    // Ctrl+Z undoes the move — undo deserializes a fresh block list,
    // so read it back from the model (the old reference is stale)
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(m.blocks.single.x, isNot(x2));

    est.models.clear();
  });

  testWidgets('3D MODEL undo/redo: Ctrl+Z reverts, Ctrl+R + Ctrl+Y redo', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    est.modelIntroDismissed = true;
    await tester.pumpWidget(const BoqApp());
    await tester.pumpAndSettle();
    await tester.tap(find.text('3D MODEL'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('New model'));
    await tester.pumpAndSettle();
    final m = est.models.first;
    final st = tester.state(find.byType(ModelView)) as dynamic;
    final planTL = tester.getTopLeft(find.byKey(const Key('modelPlan')));
    Offset w2s(double x, double y) =>
        planTL +
        Offset(
          (st.planOffset as Offset).dx + x * (st.planScale as double),
          (st.planOffset as Offset).dy - y * (st.planScale as double),
        );

    // grab canvas focus with a middle press, then B + tap places a block
    final g0 = await tester.startGesture(
      w2s(6.0, -2.0),
      kind: PointerDeviceKind.mouse,
      buttons: kMiddleMouseButton,
    );
    await g0.up();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyB);
    await tester.pumpAndSettle();
    await tester.tapAt(w2s(6.0, -2.0));
    await tester.pumpAndSettle();
    expect(m.blocks.length, 1);

    Future<void> ctrl(LogicalKeyboardKey k) async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(k);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
    }

    // Ctrl+Z removes the placement…
    await ctrl(LogicalKeyboardKey.keyZ);
    expect(m.blocks, isEmpty);
    // …Ctrl+R brings it back (redo stack caught the live state)…
    await ctrl(LogicalKeyboardKey.keyR);
    expect(m.blocks.length, 1);
    // …Ctrl+Z + Ctrl+Y round-trips the same way…
    await ctrl(LogicalKeyboardKey.keyZ);
    expect(m.blocks, isEmpty);
    await ctrl(LogicalKeyboardKey.keyY);
    expect(m.blocks.length, 1);
    // …and Ctrl+Shift+Z is bound too
    await ctrl(LogicalKeyboardKey.keyZ);
    expect(m.blocks, isEmpty);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(m.blocks.length, 1);

    // a NEW op after undo clears the redo stack: undo the placement,
    // place a second block — the first must stay gone
    await ctrl(LogicalKeyboardKey.keyZ);
    expect(m.blocks, isEmpty);
    await tester.tapAt(w2s(8.0, -3.0));
    await tester.pumpAndSettle();
    expect(m.blocks.length, 1);
    await ctrl(LogicalKeyboardKey.keyR);
    expect(m.blocks.length, 1); // redo had nothing to bring back

    est.models.clear();
  });

  testWidgets('3D MODEL undo restores roof spec + dims, not just parts', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    est.modelIntroDismissed = true;
    await tester.pumpWidget(const BoqApp());
    await tester.pumpAndSettle();
    await tester.tap(find.text('3D MODEL'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('New model'));
    await tester.pumpAndSettle();
    final m = est.models.first;
    final st = tester.state(find.byType(ModelView)) as dynamic;
    final planTL = tester.getTopLeft(find.byKey(const Key('modelPlan')));
    Offset w2s(double x, double y) =>
        planTL +
        Offset(
          (st.planOffset as Offset).dx + x * (st.planScale as double),
          (st.planOffset as Offset).dy - y * (st.planScale as double),
        );
    // grab canvas key focus so the shortcut bindings see the key event
    final g0 = await tester.startGesture(
      w2s(6.0, -2.0),
      kind: PointerDeviceKind.mouse,
      buttons: kMiddleMouseButton,
    );
    await g0.up();
    await tester.pump();

    // mutate roof spec + name directly (what the inspector fields do),
    // with an undo push between — then undo must restore BOTH, not just
    // the part lists
    final oldSpacing = m.roof.trussSpacing;
    st.pushUndoForTest();
    m.roof.trussSpacing = 0.9;
    m.name = 'renamed';
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(m.roof.trussSpacing, closeTo(oldSpacing, 1e-9));
    expect(m.name, isNot('renamed'));

    est.models.clear();
  });

  testWidgets('3D MODEL long-press: carry a block, wheel rotates, drop lands', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    est.modelIntroDismissed = true; // the tips card would eat the taps
    await tester.pumpWidget(const BoqApp());
    await tester.pumpAndSettle();
    await tester.tap(find.text('3D MODEL'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('New model'));
    await tester.pumpAndSettle();
    final m = est.models.first;
    final st = tester.state(find.byType(ModelView)) as dynamic;
    final planTL = tester.getTopLeft(find.byKey(const Key('modelPlan')));
    Offset w2s(double x, double y) =>
        planTL +
        Offset(
          (st.planOffset as Offset).dx + x * (st.planScale as double),
          (st.planOffset as Offset).dy - y * (st.planScale as double),
        );

    // place a block off the world origin — the orbit pivot test
    // below only needs the project to sit AWAY from (0,0)
    final g0 = await tester.startGesture(
      w2s(6.0, -2.0),
      kind: PointerDeviceKind.mouse,
      buttons: kMiddleMouseButton,
    );
    await g0.up();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyB);
    await tester.pumpAndSettle();
    await tester.tapAt(w2s(6.0, -2.0));
    await tester.pumpAndSettle();
    expect(m.blocks.length, 1);
    final b = m.blocks.first;

    // ORBIT PIVOT: the model's own bounds centre always projects to
    // the viewport centre + pan offset, however far off-origin it is —
    // orbiting swings around the project, never the world origin
    final vp3 = tester.getSize(find.byKey(const Key('model3d')));
    final o = st.camOffset as Offset;
    final bnd = m.bounds!;
    final pr = st.debugProj3(
      (bnd.$1 + bnd.$3) / 2,
      (bnd.$2 + bnd.$4) / 2,
      bnd.$5 / 2,
    );
    expect(pr.dx, closeTo(vp3.width / 2 + o.dx, 0.01));
    expect(pr.dy, closeTo(vp3.height / 2 + o.dy, 0.01));

    // LONG-PRESS on the block picks it up; holding still 600ms wins
    // the gesture arena against pan/select
    final g = await tester.startGesture(
      w2s(b.x, b.y),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump(const Duration(milliseconds: 600));
    // wheel while carried rotates it 15deg/step, before any drop
    final r0 = b.rot;
    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: w2s(b.x, b.y),
        scrollDelta: const Offset(0, -100),
      ),
    );
    await tester.pump();
    expect(b.rot, isNot(r0));

    // drag carries the ghost; release drops at the snapped point
    await g.moveTo(w2s(8.0, -4.0));
    await tester.pump();
    await g.up();
    await tester.pumpAndSettle();
    expect(b.x, closeTo(8.0, 0.3));
    expect(b.y, closeTo(-4.0, 0.3));

    // long-press on EMPTY space pans the plan instead of grabbing
    final off0 = st.planOffset as Offset;
    final g2 = await tester.startGesture(
      planTL + const Offset(20, 20),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump(const Duration(milliseconds: 600));
    await g2.moveTo(planTL + const Offset(80, 60));
    await tester.pump();
    await g2.up();
    await tester.pumpAndSettle();
    expect((st.planOffset as Offset) != off0, isTrue);

    est.models.clear();
  });

  testWidgets('3D MODEL camera + selection survive a tab switch', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    addTearDown(() {
      est.models.clear();
      est.modelCam.clear();
      est.modelSel = 0;
      est.modelIntroDismissed = false;
    });
    est.modelIntroDismissed = true;
    await tester.pumpWidget(const BoqApp());
    await tester.pumpAndSettle();
    await tester.tap(find.text('3D MODEL'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('New model'));
    await tester.pumpAndSettle();

    // drag the plan camera away from the fitted default — a
    // long-press on empty space pans (proved by the LP test above)
    var st = tester.state(find.byType(ModelView)) as dynamic;
    final off0 = st.planOffset as Offset;
    final planTL = tester.getTopLeft(find.byKey(const Key('modelPlan')));
    final g = await tester.startGesture(
      planTL + const Offset(20, 20),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump(const Duration(milliseconds: 600));
    await g.moveTo(planTL + const Offset(80, 60));
    await tester.pump();
    await g.up();
    await tester.pumpAndSettle();
    final off1 = st.planOffset as Offset;
    final sc1 = st.planScale as double;
    expect(off1 != off0, isTrue, reason: 'the pan must move the camera');

    // DESIGN CALC -> back: the view used to refit/reset; it must now
    // restore the exact plan camera and the selected model
    await tester.tap(find.text('DESIGN CALC'));
    await tester.pumpAndSettle();
    expect(find.byType(ModelView), findsNothing);
    await tester.tap(find.text('3D MODEL'));
    await tester.pumpAndSettle();

    st = tester.state(find.byType(ModelView)) as dynamic;
    expect(st.planOffset, off1);
    expect(st.planScale, sc1);
    expect(st.selectedModelDebug, est.models.first);
  });

  testWidgets('3D MODEL G command: free-angle rotate via cursor spin', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    est.modelIntroDismissed = true;
    await tester.pumpWidget(const BoqApp());
    await tester.pumpAndSettle();
    await tester.tap(find.text('3D MODEL'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('New model'));
    await tester.pumpAndSettle();
    final m = est.models.first;
    final st = tester.state(find.byType(ModelView)) as dynamic;
    final planTL = tester.getTopLeft(find.byKey(const Key('modelPlan')));
    Offset w2s(double x, double y) =>
        planTL +
        Offset(
          (st.planOffset as Offset).dx + x * (st.planScale as double),
          (st.planOffset as Offset).dy - y * (st.planScale as double),
        );

    // place a block — mid-press grabs key focus, B + tap places it
    final g0 = await tester.startGesture(
      w2s(6.0, -2.0),
      kind: PointerDeviceKind.mouse,
      buttons: kMiddleMouseButton,
    );
    await g0.up();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyB);
    await tester.pumpAndSettle();
    await tester.tapAt(w2s(6.0, -2.0));
    await tester.pumpAndSettle();
    expect(m.blocks.length, 1);
    final b = m.blocks.first;

    // GATE: a bare G press only ARMS the rotate tool — clicking empty
    // canvas while armed must NOT spin the (still-selected) block
    await tester.sendKeyEvent(LogicalKeyboardKey.keyG);
    await tester.pumpAndSettle();
    await tester.tapAt(w2s(9.0, -4.0)); // empty canvas, far from the block
    await tester.pumpAndSettle();
    expect(b.rot, 0.0); // nothing picked, nothing rotated

    // click ON the block picks it: the pick point anchors the spin
    // (click dead-centre -> atan2(0,0) = 0), the NEXT click commits
    // the cursor-direction delta — here atan2(-2,3) ~ -33.7deg, a
    // FREE angle unreachable via the 15deg R-step
    await tester.tapAt(w2s(b.x, b.y));
    await tester.pumpAndSettle();
    await tester.tapAt(w2s(b.x + 3.0, b.y - 2.0));
    await tester.pumpAndSettle();
    expect(b.rot, closeTo(math.atan2(-2.0, 3.0), 0.01));

    // second spin from the new angle: pick at centre, commit due
    // "north" -> atan2(-2,0) = -pi/2 on top of the committed rot
    final prev = b.rot;
    await tester.sendKeyEvent(LogicalKeyboardKey.keyG);
    await tester.pumpAndSettle();
    await tester.tapAt(w2s(b.x, b.y));
    await tester.pumpAndSettle();
    await tester.tapAt(w2s(b.x, b.y - 2.0));
    await tester.pumpAndSettle();
    expect(b.rot, closeTo(prev - math.pi / 2, 0.01));

    // Esc mid-carry releases WITHOUT changing the committed angle —
    // the real rot is only ever written on the commit click
    final locked = b.rot;
    await tester.sendKeyEvent(LogicalKeyboardKey.keyG);
    await tester.pumpAndSettle();
    await tester.tapAt(w2s(b.x, b.y)); // pick it up...
    await tester.pumpAndSettle();
    await tester.sendEventToBinding(
      PointerHoverEvent(position: w2s(b.x + 4.0, b.y)),
    );
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(b.rot, locked); // ...and let go — rot untouched

    est.models.clear();
  });

  testWidgets('3D MODEL plan viewport: mid/space pan + wheel zoom', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const BoqApp());
    await tester.pumpAndSettle();
    await tester.tap(find.text('3D MODEL'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('New model'));
    await tester.pumpAndSettle();
    final m = est.models.first;
    // private viewport state via dynamic — the transforms ARE the
    // feature under test
    final st = tester.state(find.byType(ModelView)) as dynamic;
    final pc = tester.getCenter(find.byKey(const Key('modelPlan')));

    // MIDDLE-DRAG pans the plan even with the wall tool armed —
    // and creates no geometry
    final off0 = st.planOffset as Offset;
    final g = await tester.startGesture(
      pc,
      kind: PointerDeviceKind.mouse,
      buttons: kMiddleMouseButton,
    );
    await g.moveBy(const Offset(80, 40));
    await tester.pump();
    expect(st.planOffset as Offset, off0 + const Offset(80, 40));
    await g.up();
    await tester.pumpAndSettle();
    expect(m.walls, isEmpty);
    expect(m.volumes, isEmpty);
    expect(m.blocks, isEmpty);

    // SPACEBAR-DRAG pans too — and the space-tap adds no wall point.
    // (inject into HardwareKeyboard directly so the pressed state is
    // synchronous — the simulated channel update lags a frame)
    HardwareKeyboard.instance.handleKeyEvent(
      const KeyDownEvent(
        physicalKey: PhysicalKeyboardKey.space,
        logicalKey: LogicalKeyboardKey.space,
        timeStamp: Duration.zero,
      ),
    );
    expect(
      HardwareKeyboard.instance.isLogicalKeyPressed(LogicalKeyboardKey.space),
      isTrue,
    );
    final g2 = await tester.startGesture(pc);
    await g2.moveBy(const Offset(-50, -20));
    await tester.pump();
    expect(st.planPanLast, isNotNull); // space-drag armed the pan
    expect(st.planOffset as Offset, off0 + const Offset(30, 20));
    await g2.up();
    HardwareKeyboard.instance.handleKeyEvent(
      const KeyUpEvent(
        physicalKey: PhysicalKeyboardKey.space,
        logicalKey: LogicalKeyboardKey.space,
        timeStamp: Duration.zero,
      ),
    );
    await tester.pumpAndSettle();
    expect(m.walls, isEmpty);

    // WHEEL ZOOM keeps the cursor world point fixed (zoom-to-cursor)
    final s0 = st.planScale as double;
    final scroll = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(scroll.hover(pc, timeStamp: Duration.zero));
    await tester.sendEventToBinding(
      scroll.scroll(const Offset(0, -120), timeStamp: Duration.zero),
    );
    await tester.pump();
    expect(st.planScale as double, greaterThan(s0));

    // MIDDLE-DRAG on the 3D canvas pans the camera (_o3), not orbit
    final mc = tester.getCenter(find.byKey(const Key('model3d')));
    final yaw0 = st.camYaw as double;
    final o0 = st.camOffset as Offset;
    final g3 = await tester.startGesture(
      mc,
      kind: PointerDeviceKind.mouse,
      buttons: kMiddleMouseButton,
    );
    expect(st.midPanDebug, isNotNull); // middle-down armed the pan
    await g3.moveBy(const Offset(25, 15));
    await tester.pump();
    expect(st.camOffset as Offset, o0 + const Offset(25, 15));
    expect(st.camYaw as double, yaw0); // unchanged — it panned, didn't orbit
    await g3.up();
    await tester.pumpAndSettle();

    est.models.clear();
  });

  testWidgets('3D MODEL split divider drags + double-tap resets', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const BoqApp());
    await tester.pumpAndSettle();
    await tester.tap(find.text('3D MODEL'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('New model'));
    await tester.pumpAndSettle();

    final plan = find.byKey(const Key('modelPlan'));
    final w0 = tester.getSize(plan).width;
    final split = find.byIcon(Icons.drag_indicator);
    expect(split, findsOneWidget);

    // drag right +160 -> plan pane widens, fraction follows
    await tester.drag(split, const Offset(160, 0));
    await tester.pumpAndSettle();
    expect(est.modelSplitFrac, greaterThan(0.5));
    expect(tester.getSize(plan).width, greaterThan(w0 + 100));

    // double-tap resets to 50/50
    await tester.tap(split);
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tap(split);
    await tester.pumpAndSettle();
    expect(est.modelSplitFrac, 0.5);
    expect(tester.getSize(plan).width, closeTo(w0, 1.0));

    est.models.clear();
  });

  testWidgets('3D MODEL viewport modes: 1/2/3 keys + pane buttons', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const BoqApp());
    await tester.pumpAndSettle();
    await tester.tap(find.text('3D MODEL'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('New model'));
    await tester.pumpAndSettle();

    final plan = find.byKey(const Key('modelPlan'));
    final model = find.byKey(const Key('model3d'));
    expect(plan, findsOneWidget);
    expect(model, findsOneWidget);

    // canvas key-focus: tap a safe empty corner of the plan first
    await tester.tapAt(tester.getTopLeft(plan) + const Offset(30, 30));
    await tester.pumpAndSettle();

    // '1' -> plan only: 3D canvas unmounts, the plan pane's button
    // flips to a split-restore affordance
    await tester.sendKeyEvent(LogicalKeyboardKey.digit1);
    await tester.pumpAndSettle();
    expect(model, findsNothing);
    expect(plan, findsOneWidget);
    expect(find.byTooltip('Back to split view (2)'), findsOneWidget);

    // '3' -> 3D only: plan canvas unmounts
    await tester.sendKeyEvent(LogicalKeyboardKey.digit3);
    await tester.pumpAndSettle();
    expect(plan, findsNothing);
    expect(model, findsOneWidget);
    expect(find.byTooltip('Back to split view (2)'), findsOneWidget);

    // the 3D pane's restore button returns to split
    await tester.tap(find.byTooltip('Back to split view (2)'));
    await tester.pumpAndSettle();
    expect(plan, findsOneWidget);
    expect(model, findsOneWidget);

    // '3' again then Esc -> the cascade restores the split (Esc may
    // first clear an armed chain/selection, so two presses settle it)
    await tester.sendKeyEvent(LogicalKeyboardKey.digit3);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(plan, findsOneWidget);
    expect(model, findsOneWidget);

    // '1' then the plan pane's own restore button
    await tester.sendKeyEvent(LogicalKeyboardKey.digit1);
    await tester.pumpAndSettle();
    expect(model, findsNothing);
    await tester.tap(find.byTooltip('Back to split view (2)'));
    await tester.pumpAndSettle();
    expect(plan, findsOneWidget);
    expect(model, findsOneWidget);

    est.models.clear();
  });

  test('planGridLevels: multi-scale steps, subdivisions, fade', () {
    // pScale 30 -> 1m base (0.5m would be only 15px), 0.25m sub
    var g = planGridLevels(30);
    expect(g.step, 1.0);
    expect(g.sub, closeTo(0.25, 1e-9));
    expect(g.subAlpha, greaterThan(0));
    expect(g.subAlpha, lessThan(0.9));
    // pScale 60 -> 0.5m base, 0.10m subdivision just past the
    // 5.5px visibility threshold -> barely faded in
    g = planGridLevels(60);
    expect(g.step, 0.5);
    expect(g.sub, closeTo(0.10, 1e-9));
    expect(g.subAlpha, greaterThan(0));
    expect(g.subAlpha, lessThan(0.2));
    // deep zoom -> same subdivisions at full 0.9 alpha
    g = planGridLevels(300);
    expect(g.subAlpha, closeTo(0.9, 1e-9));
    // zoomed out -> 5m base, 1.25m subs
    g = planGridLevels(8);
    expect(g.step, 5.0);
    expect(g.sub, closeTo(1.25, 1e-9));
    // at the 52px boundary the 0.1m subs are only 5.2px apart:
    // below the fade threshold -> hidden
    g = planGridLevels(52);
    expect(g.sub, closeTo(0.10, 1e-9));
    expect(g.subAlpha, 0);
    // huge pScale still bottoms out at the smallest base step
    g = planGridLevels(2000);
    expect(g.step, 0.5);
  });

  test('gridLinePositions: world-multiple lattice shared 2D/3D', () {
    // lines land on exact multiples of step, not on the floored
    // view bound — both views share (0,0) as an intersection
    final p = gridLinePositions(-2.3, 7.7, 2.0).toList();
    expect(p, [-2.0, 0.0, 2.0, 4.0, 6.0]);
    expect(p.contains(0.0), isTrue); // origin is always a grid line
    for (final x in p) {
      expect(x % 2.0, closeTo(0.0, 1e-9));
    }
    // fractional steps stay exact through the negative range too
    final q = gridLinePositions(-1.1, 0.9, 0.25).toList();
    expect(q.contains(-1.0), isTrue);
    expect(q.contains(0.0), isTrue);
    expect(q.length, 8); // -1.0 .. 0.75 at 0.25 step
    // empty when the span is tighter than one step gap
    expect(gridLinePositions(0.1, 0.2, 1.0).toList(), isEmpty);
  });

  test('snapTarget: endpoint > midpoint > grid precedence', () {
    final eps = [const Offset(1.37, 0.83)];
    final segs = [(const Offset(1.37, 0.83), const Offset(3.61, 0.83))];
    // near an endpoint -> exact endpoint, off the grid lattice
    var t = snapTarget(
      const Offset(1.42, 0.86),
      step: 0.25,
      tol: 0.2,
      endpoints: eps,
      segments: segs,
    );
    expect(t.kind, SnapKind.endpoint);
    expect(t.p, const Offset(1.37, 0.83));
    // near the segment midpoint (2.49, .83) -> midpoint
    t = snapTarget(
      const Offset(2.44, 0.80),
      step: 0.25,
      tol: 0.2,
      endpoints: eps,
      segments: segs,
    );
    expect(t.kind, SnapKind.midpoint);
    expect(t.p, const Offset(2.49, 0.83));
    // off-midpoint hover over the segment -> the point ON the edge
    // (T-wall clicks land exactly on the existing wall's centerline)
    t = snapTarget(
      const Offset(2.0, 0.9),
      step: 0.25,
      tol: 0.2,
      endpoints: eps,
      segments: segs,
    );
    expect(t.kind, SnapKind.edge);
    expect(t.p, const Offset(2.0, 0.83));
    expect(t.seg, (const Offset(1.37, 0.83), const Offset(3.61, 0.83)));
    // midpoint closer but endpoint still wins (SketchUp precedence)
    t = snapTarget(
      const Offset(1.45, 0.83),
      step: 0.25,
      tol: 0.2,
      endpoints: eps,
      segments: [(const Offset(1.37, 0.83), const Offset(1.60, 0.83))],
    );
    expect(t.kind, SnapKind.endpoint);
    // far from everything -> bare grid rounding
    t = snapTarget(
      const Offset(5.04, 5.07),
      step: 0.25,
      tol: 0.2,
      endpoints: eps,
      segments: segs,
    );
    expect(t.kind, SnapKind.grid);
    expect(t.p, const Offset(5.0, 5.0));
  });

  testWidgets('3D MODEL snap inference commits honest points', (tester) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const BoqApp());
    await tester.pumpAndSettle();
    await tester.tap(find.text('3D MODEL'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('New model'));
    await tester.pumpAndSettle();
    final m = est.models.first;
    final st = tester.state(find.byType(ModelView)) as dynamic;

    // a wall with OFF-GRID vertices — endpoint/midpoint snaps must
    // land off the 0.25 lattice to prove real inference
    m.walls.add(Wall3d(points: [1.37, 0.83, 3.61, 0.83]));
    est.update();
    await tester.pumpAndSettle();

    // _w2s/_s2w work in canvas-LOCAL coords — tapAt needs globals
    final planTL = tester.getTopLeft(find.byKey(const Key('modelPlan')));
    Offset toScreen(Offset w) {
      final off = st.planOffset as Offset;
      final sc = st.planScale as double;
      return planTL + Offset(off.dx + w.dx * sc, off.dy - w.dy * sc);
    }

    // ENDPOINT: tap ~0.06m off the wall end -> lands exactly on it
    await tester.tapAt(toScreen(const Offset(3.66, 0.80)));
    await tester.pumpAndSettle();
    expect(st.wallChainDebug.length, 1);
    expect(st.wallChainDebug.last, const Offset(3.61, 0.83));

    // MIDPOINT: tap ~0.05m off (2.49,.83) -> exact midpoint
    await tester.tapAt(toScreen(const Offset(2.44, 0.80)));
    await tester.pumpAndSettle();
    expect(st.wallChainDebug.last, const Offset(2.49, 0.83));

    // GRID: open space still lands on the 0.25 lattice
    await tester.tapAt(toScreen(const Offset(5.04, 5.07)));
    await tester.pumpAndSettle();
    expect(st.wallChainDebug.last, const Offset(5.0, 5.0));

    // 3D CANVAS: the endpoint pick radius is measured in screen px —
    // a tap a few px off a chain vertex's ground projection must land
    // exactly on it (foreshortening can't shrink the radius). Aim at
    // the middle chain vertex (2.49,.83) — not the first, which would
    // legitimately close the loop.
    final m3dTL = tester.getTopLeft(find.byKey(const Key('model3d')));
    final s3 = st.debugProjGround(const Offset(2.49, 0.83)) as Offset;
    await tester.tapAt(m3dTL + s3 + const Offset(6, 0));
    await tester.pumpAndSettle();
    expect(st.wallChainDebug.last, const Offset(2.49, 0.83));

    // SNAP OFF: a tap near the endpoint commits the raw point
    await tester.tap(find.byTooltip('Snap 0.25 m'));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle(); // clear the chain
    await tester.tapAt(toScreen(const Offset(3.66, 0.80)));
    await tester.pumpAndSettle();
    final raw = st.wallChainDebug.last as Offset;
    expect((raw - const Offset(3.61, 0.83)).distance, greaterThan(0.03));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(m.walls.length, 2); // Esc now finishes (cuts) the open chain

    est.models.clear();
  });

  testWidgets('3D MODEL status strip: coords, snap, zoom, selection', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const BoqApp());
    await tester.pumpAndSettle();
    await tester.tap(find.text('3D MODEL'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('New model'));
    await tester.pumpAndSettle();
    final m = est.models.first;

    // the strip: active tool pill + hint + snap chip + zoom %
    expect(find.text('WALL'), findsOneWidget);
    expect(find.text('SNAP 0.25'), findsOneWidget);
    expect(find.textContaining(RegExp(r'^\d+%$')), findsOneWidget);
    expect(find.text('click the first wall point'), findsOneWidget);

    // hovering the plan shows the snapped X,Y readout (no Z)
    final pc = tester.getCenter(find.byKey(const Key('modelPlan')));
    final ptr = TestPointer(9, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(ptr.hover(pc, timeStamp: Duration.zero));
    await tester.pump();
    expect(
      find.textContaining(RegExp(r'^X -?\d+\.\d+  Y -?\d+\.\d+$')),
      findsOneWidget,
    );
    expect(find.textContaining('Z 0.00'), findsNothing);

    // hovering the 3D canvas shows the X,Y,Z ground hit + 3D hint
    final mc = tester.getCenter(find.byKey(const Key('model3d')));
    await tester.sendEventToBinding(ptr.hover(mc, timeStamp: Duration.zero));
    await tester.pump();
    expect(find.textContaining('Z 0.00'), findsOneWidget);
    expect(find.textContaining('drag orbits'), findsOneWidget);

    // the snap chip toggles the toolbar's own _snap flag
    await tester.tap(find.text('SNAP 0.25'));
    await tester.pump();
    expect(find.text('SNAP OFF'), findsOneWidget);
    await tester.tap(find.text('SNAP OFF'));
    await tester.pump();

    // draw + select a wall -> the strip shows its selection summary
    await tester.tapAt(pc + const Offset(-160, -80));
    await tester.tapAt(pc + const Offset(120, -80));
    await tester.tapAt(pc + const Offset(120, -80));
    await tester.pumpAndSettle();
    expect(m.walls.length, 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.pumpAndSettle();
    expect(find.text('SELECT'), findsOneWidget);
    await tester.tapAt(pc + const Offset(-20, -80));
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byKey(const Key('modelStatusStrip')),
        matching: find.textContaining(RegExp(r'^WALL · \d+\.\d+ m$')),
      ),
      findsOneWidget,
    );

    est.models.clear();
  });

  testWidgets('3D MODEL model rail collapses to a 40px icon rail', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const BoqApp());
    await tester.pumpAndSettle();
    await tester.tap(find.text('3D MODEL'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('New model'));
    await tester.pumpAndSettle();

    final plan = find.byKey(const Key('modelPlan'));
    final w0 = tester.getSize(plan).width;

    // header chevron collapses the rail -> icons only, canvas widens
    await tester.tap(find.byTooltip('Hide models'));
    await tester.pumpAndSettle();
    expect(est.modelRailOpen, isFalse);
    expect(find.text('3D MODELS'), findsNothing);
    expect(find.byTooltip('Show models'), findsOneWidget);
    expect(find.byTooltip('New model'), findsOneWidget);
    // the 160px reclaim splits between the panes (split fraction)
    expect(tester.getSize(plan).width, greaterThan(w0 + 50));

    // + on the collapsed rail still creates a model
    final n = est.models.length;
    await tester.tap(find.byTooltip('New model'));
    await tester.pumpAndSettle();
    expect(est.models.length, n + 1);

    // chevron expands back to the full rail
    await tester.tap(find.byTooltip('Show models'));
    await tester.pumpAndSettle();
    expect(est.modelRailOpen, isTrue);
    expect(find.text('3D MODELS'), findsOneWidget);
    expect(tester.getSize(plan).width, closeTo(w0, 2));

    est.models.clear();
  });

  testWidgets('3D MODEL inspector: model summary vs part properties', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const BoqApp());
    await tester.pumpAndSettle();
    await tester.tap(find.text('3D MODEL'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('New model'));
    await tester.pumpAndSettle();
    final m = est.models.first;

    // switch the inspector to Inspect — nothing selected -> summary
    await tester.tap(find.text('Inspect'));
    await tester.pumpAndSettle();
    expect(find.text('MODEL'), findsOneWidget);
    expect(find.text('Floor area'), findsOneWidget);
    expect(find.text('Envelope'), findsOneWidget);
    expect(find.text('Delete wall'), findsNothing); // no part panel

    // draw a wall, select it -> inspector becomes the wall's panel
    final pc = tester.getCenter(find.byKey(const Key('modelPlan')));
    await tester.tapAt(pc + const Offset(-160, -80));
    await tester.tapAt(pc + const Offset(120, -80));
    await tester.tapAt(pc + const Offset(120, -80));
    await tester.pumpAndSettle();
    expect(m.walls.length, 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.pumpAndSettle();
    await tester.tapAt(pc + const Offset(-20, -80));
    await tester.pumpAndSettle();
    expect(find.text('Delete wall'), findsOneWidget); // part panel
    expect(find.text('MODEL SUMMARY'), findsOneWidget); // back link
    expect(find.text('Envelope'), findsNothing); // summary hidden

    // back link returns to the model summary (deselects)
    await tester.tap(find.text('MODEL SUMMARY'));
    await tester.pumpAndSettle();
    expect(find.text('Envelope'), findsOneWidget);
    expect(find.text('Delete wall'), findsNothing);

    est.models.clear();
  });

  testWidgets('3D MODEL footing: placed pad + column footing select in plan', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const BoqApp());
    await tester.pumpAndSettle();
    await tester.tap(find.text('3D MODEL'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('New model'));
    await tester.pumpAndSettle();
    final m = est.models.first;

    // a placed footing pad at the origin — select it through the
    // object list (same _blkSel the canvas pick sets)
    m.blocks.add(Block3d(def: 'ftg-150', x: 0, y: 0));
    est.update();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Props'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Footing 1.5×1.5'));
    await tester.pumpAndSettle();
    expect(find.text('FOOTING (NSCP 2015)'), findsOneWidget);
    expect(find.text('Embedment (m)'), findsOneWidget);
    expect(find.text('Thickness (m)'), findsOneWidget);

    // the column footing: its structure panel carries the depth field
    m.blocks.clear();
    m.blocks.add(Block3d(def: 'col-sq', x: 0, y: 0, footing: true));
    est.update();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Column 0.3□'));
    await tester.pumpAndSettle();
    expect(find.text('STRUCTURE (NSCP 2015)'), findsOneWidget);
    expect(find.text('Depth (m, 0=auto)'), findsOneWidget);
    // NSCP 305-1 preset chips sit beside the depth field
    expect(find.text('1F·0.30'), findsOneWidget);
    expect(find.text('2F·0.45'), findsOneWidget);
    expect(find.text('3F·0.60'), findsOneWidget);

    est.models.clear();
  });

  testWidgets('3D MODEL clipboard: Ctrl+C / Ctrl+V duplicates a part', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const BoqApp());
    await tester.pumpAndSettle();
    await tester.tap(find.text('3D MODEL'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('New model'));
    await tester.pumpAndSettle();
    final m = est.models.first;

    // a column with manual footing settings — the copy must carry them
    m.blocks.add(
      Block3d(def: 'col-sq', x: 1, y: 1, footing: true, footW: 1.8, footD: 0.8),
    );
    est.update();
    await tester.pumpAndSettle();

    // select it through the object list (sets _blkSel — same as a pick)
    await tester.tap(find.text('Props'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Column 0.3□'));
    await tester.pumpAndSettle();

    // grab canvas key focus, then Ctrl+C + Ctrl+V
    await tester.tapAt(
      tester.getTopLeft(find.byKey(const Key('modelPlan'))) +
          const Offset(30, 30),
    );
    await tester.pumpAndSettle();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(m.blocks.length, 1); // copy alone adds nothing

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(m.blocks.length, 2);
    final paste = m.blocks[1];
    expect(paste.id, isNot(m.blocks[0].id)); // independent copy
    expect(paste.footing, isTrue);
    expect(paste.footW, 1.8); // manual footing size carried over
    expect(paste.footD, 0.8);
    // pointer off-canvas -> +0.5 offset fallback, copy is selected
    expect(paste.x, closeTo(1.5, 1e-6));
    expect(paste.y, closeTo(1.5, 1e-6));
    expect(find.text('STRUCTURE (NSCP 2015)'), findsOneWidget);

    // Ctrl+X removes the original after copying
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyX);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(m.blocks.length, 1);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(m.blocks.length, 2);

    est.models.clear();
  });

  testWidgets('3D MODEL footing: apply-to-all balances every column', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const BoqApp());
    await tester.pumpAndSettle();
    await tester.tap(find.text('3D MODEL'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('New model'));
    await tester.pumpAndSettle();
    final m = est.models.first;

    // two columns: one already carries a manual footing, one has none
    m.blocks.addAll([
      Block3d(def: 'col-sq', x: 0, y: 0, footing: true, footW: 1.8),
      Block3d(def: 'col-sq', x: 5, y: 0),
    ]);
    est.update();
    await tester.pumpAndSettle();

    // select the footing column via the object list, tap the button
    await tester.tap(find.text('Props'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Column 0.3□').first);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Apply footing to all columns'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Apply footing to all columns'));
    await tester.pumpAndSettle();

    expect(m.blocks[1].footing, isTrue);
    expect(m.blocks[1].footW, 1.8); // balanced to the same manual size

    est.models.clear();
  });

  testWidgets('3D MODEL shortcut HUD: ? card toggles and Esc closes', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const BoqApp());
    await tester.pumpAndSettle();
    await tester.tap(find.text('3D MODEL'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('New model'));
    await tester.pumpAndSettle();

    // grab canvas key focus (empty corner tap)
    final plan = find.byKey(const Key('modelPlan'));
    await tester.tapAt(tester.getTopLeft(plan) + const Offset(30, 30));
    await tester.pumpAndSettle();
    expect(find.text('SHORTCUTS'), findsNothing);

    // ? (shift+/) opens the card — sections + rows present
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.slash);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();
    expect(find.text('SHORTCUTS'), findsOneWidget);
    for (final s in const ['TOOLS', 'CANVAS', 'VIEW', 'EDIT']) {
      expect(find.text(s), findsOneWidget);
    }
    expect(find.text('select / move'), findsOneWidget);
    expect(find.text('reset split 50/50'), findsOneWidget);
    expect(find.text('undo'), findsOneWidget);

    // toolbar ? button toggles it off
    await tester.tap(find.byTooltip('Shortcuts (?)'));
    await tester.pumpAndSettle();
    expect(find.text('SHORTCUTS'), findsNothing);

    // reopen via F1, then Esc is consumed by the HUD first
    await tester.sendKeyEvent(LogicalKeyboardKey.f1);
    await tester.pumpAndSettle();
    expect(find.text('SHORTCUTS'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('SHORTCUTS'), findsNothing);
    // ...and the split view is still intact (Esc didn't cascade on)
    expect(plan, findsOneWidget);
    expect(find.byKey(const Key('model3d')), findsOneWidget);

    est.models.clear();
  });

  testWidgets('3D MODEL toolbar pins GENERATE at narrow widths', (
    tester,
  ) async {
    // 1100px: tools overflow into the scroll strip but the primary
    // action + parts count stay pinned at the right edge on-screen
    tester.view.physicalSize = const Size(1100, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const BoqApp());
    await tester.pumpAndSettle();
    await tester.tap(find.text('3D MODEL'));
    await tester.pumpAndSettle();
    final gen = find.text('GENERATE DRAWING');
    expect(gen, findsOneWidget);
    // its top-left must be inside the visible window, not scrolled off
    expect(tester.getTopLeft(gen).dx, lessThan(1100));
    expect(tester.getTopLeft(gen).dx, greaterThan(0));
  });

  testWidgets('DRAWINGS toolbar steps through multiple files', (tester) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const BoqApp());
    await tester.pumpAndSettle();
    await tester.tap(find.text('DRAWINGS'));
    await tester.pumpAndSettle();
    // two files -> the < 1/2 > nav appears on the bottom toolbar
    final d1 = est.addDrawing(
      '${Directory.current.path}\\tool\\fixtures\\plan.dxf',
      'dxf',
    );
    est.addDrawing(
      '${Directory.current.path}\\some\\other.pdf',
      'pdf',
      pageCount: 3,
    );
    await tester.pump();
    expect(find.text('1/2'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.navigate_next));
    await tester.pump();
    await tester.runAsync(
      () => Future.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('2/2'), findsOneWidget);
    // next is disabled at the last file; prev goes back
    await tester.tap(find.byIcon(Icons.navigate_before));
    await tester.pump();
    await tester.runAsync(
      () => Future.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('1/2'), findsOneWidget);
    expect(find.text('plan.dxf'), findsWidgets);
    expect(d1.id, isNotEmpty);
    est.drawings.clear();
  });

  testWidgets('colors button opens theme dialog and recolors sheet', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const BoqApp());
    est.addSection('TEST SECTION');
    await tester.pumpAndSettle();
    // open the theme dialog via the Colors button
    await tester.tap(find.text('Colors'));
    await tester.pumpAndSettle();
    expect(find.text('Section header'), findsWidgets);
    expect(find.text('Location / label'), findsWidgets);
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    // change the section band color and verify the sheet repaints
    est.setProjectColor('section', 0xFF123456);
    await tester.pumpAndSettle();
    final box = tester.widgetList<Container>(find.byType(Container));
    expect(
      box.any(
        (c) =>
            c.decoration is BoxDecoration &&
            (c.decoration as BoxDecoration).color == const Color(0xFF123456),
      ),
      isTrue,
    );
    est.setProjectColor('section', 0xFFDBE4F0);
    est.sections.clear();
  });

  testWidgets('New button opens a fresh project tab that keeps office '
      'assets', (tester) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const BoqApp());

    // dirty the project: a section, an activity, a custom letterhead,
    // a mark and a non-default saved path
    est.addSection('KEEP ME NOT');
    est.activities.add(CpmActivity(name: 'OLD TASK', days: 3));
    est.project.letterhead[0] = 'CUSTOM REPUBLIC';
    // a real 1x1 PNG so the logo renderer has valid data
    const png =
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';
    est.project.logoB64 = png;
    est.savedPath = 'C:\\tmp\\old.boqproj';
    await tester.pumpAndSettle();
    expect(est.sections, isNotEmpty);

    // New -> a second project tab: non-destructive, the old estimate
    // stays open in its own tab and the new one starts blank
    await tester.ensureVisible(find.text('New'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('New'));
    await tester.pumpAndSettle();

    expect(projectTabs.tabs.length, 2);
    expect(est.sections, isEmpty);
    expect(est.activities, isEmpty);
    expect(est.savedPath, isNull);
    expect(est.extensions, isEmpty);
    expect(est.drawings, isEmpty);
    expect(est.marks, isEmpty);
    // office assets carry over into the new tab
    expect(est.project.letterhead[0], 'CUSTOM REPUBLIC');
    expect(est.project.logoB64, png); // logo kept across reset
    expect(est.project.signatories, isNotEmpty);
    // blank sheet now shows the empty-state prompt, and the project
    // tab strip appeared with both projects on it
    expect(find.text('BOQ SHEET'), findsOneWidget);
    expect(find.byTooltip('New project tab'), findsNWidgets(2));
    expect(projectTabs.tabs.first.state.sections.single.title, 'KEEP ME NOT');

    // closing the new (blank) tab drops back to the original project
    await tester.tap(find.byTooltip('Close tab').last);
    await tester.pumpAndSettle();
    expect(projectTabs.tabs.length, 1);
    expect(est.sections.single.title, 'KEEP ME NOT');
  });

  testWidgets('export menu offers xlsx/pdf/docx; pdf+docx builders '
      'produce real files', (tester) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const BoqApp());
    await tester.pumpAndSettle();

    // Export is a menu at the far right with the three formats
    final exportBtn = find.textContaining('Export');
    await tester.ensureVisible(exportBtn);
    await tester.pumpAndSettle();
    await tester.tap(exportBtn);
    await tester.pumpAndSettle();
    expect(find.text('Excel workbook (.xlsx)'), findsOneWidget);
    expect(find.text('PDF document (.pdf)'), findsOneWidget);
    expect(find.text('Word document (.docx)'), findsOneWidget);
    await tester.tapAt(const Offset(10, 450)); // dismiss menu
    await tester.pumpAndSettle();
  });

  // Plain test() — renderSCurvePng awaits picture.toImage which needs
  // the real event loop (testWidgets' fake-async zone starves it).
  test('pdf and docx builders produce real files', () async {
    est.addSection('SITE WORKS');
    est.addLine(
      est.sections.last,
      BoqLine(
        description: 'EXCAVATION',
        unit: 'cu.m',
        qty: 10,
        materialCost: 500,
        laborCost: 150,
      ),
    );
    final docx = await DocxExport.buildEstimate();
    expect(docx.length, greaterThan(400));
    expect(docx[0], 0x50); // 'P' — zip magic PK\x03\x04
    expect(docx[1], 0x4B); // 'K'
    final pdf = await PdfExport(est).build();
    expect(pdf.length, greaterThan(2000));
    // %PDF-1.x header
    expect(String.fromCharCodes(pdf.sublist(0, 5)), '%PDF-');
    est.project.logoB64 = base64Encode(
      File('assets/deped_logo.png').readAsBytesSync(),
    );
    final withLogo = await DocxExport.buildEstimate();
    final arc = ZipDecoder().decodeBytes(withLogo);
    String part(String n) => utf8.decode(
      arc.files.firstWhere((f) => f.name == n).content as List<int>,
    );
    final doc = part('word/document.xml');
    // workbook colors + structure carried into Word
    expect(
      doc,
      contains(
        'w:fill="${(est.project.themeColor & 0xFFFFFF).toRadixString(16).toUpperCase()}"',
      ),
    );
    expect(
      doc,
      contains(
        'w:fill="${(est.project.sectionColor & 0xFFFFFF).toRadixString(16).toUpperCase()}"',
      ),
    );
    expect(doc, contains('ITEM DESCRIPTION'));
    expect(doc, contains('<w:tblHeader/>')); // header repeats per page
    expect(doc, contains('GRAND TOTAL'));
    expect(arc.files.map((f) => f.name), contains('word/media/logo.png'));
    expect(arc.files.map((f) => f.name), contains('word/styles.xml'));
    expect(part('word/styles.xml'), contains('Arial'));
    est.project.logoB64 = null;
    est.sections.clear();
  });

  testWidgets('3D MODEL cursor map: tool/hover/modifier states', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const BoqApp());
    await tester.pumpAndSettle();
    await tester.tap(find.text('3D MODEL'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('New model'));
    await tester.pumpAndSettle();

    final st = tester.state(find.byType(ModelView)) as dynamic;
    final m = est.models.first;
    // one wall + one volume as hover targets
    m.walls.add(Wall3d(points: [1, -1, 5, -1]));
    m.volumes.add(
      Volume3d(footprint: [-2, 2, -0.5, 2, -0.5, 3.5, -2, 3.5], height: 2),
    );
    est.update();
    await tester.pumpAndSettle();

    MouseCursor planCur() =>
        tester.widget<MouseRegion>(find.byKey(const Key('planMouse'))).cursor;
    MouseCursor m3Cur() =>
        tester.widget<MouseRegion>(find.byKey(const Key('m3dMouse'))).cursor;

    final plan = find.byKey(const Key('modelPlan'));
    final model = find.byKey(const Key('model3d'));
    final pTl = tester.getTopLeft(plan);
    final m3Tl = tester.getTopLeft(model);
    Offset toScreen(Offset w) =>
        pTl +
        (st.planOffset as Offset) +
        Offset(
          w.dx * (st.planScale as double),
          -w.dy * (st.planScale as double),
        );

    // draw tool armed -> precise crosshair on both canvases
    expect(planCur(), SystemMouseCursors.precise);
    expect(m3Cur(), SystemMouseCursors.precise);

    // grab canvas key-focus so letter keys switch tools
    await tester.tapAt(pTl + const Offset(30, 30));
    await tester.pumpAndSettle();

    // select tool -> plain arrow over empty space
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.pumpAndSettle();
    expect(planCur(), SystemMouseCursors.basic);
    expect(m3Cur(), SystemMouseCursors.basic);

    // hover over the wall's centerline -> hand (part affordance)
    final ptr = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(ptr.hover(toScreen(const Offset(3, -1))));
    await tester.pump();
    expect(planCur(), SystemMouseCursors.click);

    // drift off the part (still on-canvas) -> back to the plain arrow
    await tester.sendEventToBinding(ptr.hover(toScreen(const Offset(3, -4))));
    await tester.pump();
    expect(planCur(), SystemMouseCursors.basic);

    // space held -> hand even with the select tool
    await tester.sendKeyDownEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(planCur(), SystemMouseCursors.click);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(planCur(), SystemMouseCursors.basic);

    // 3D: hover over the volume's top face -> grab hand
    final top = st.debugProj3(-1.25, 2.75, 2.0) as Offset;
    await tester.sendEventToBinding(ptr.hover(m3Tl + top));
    await tester.pump();
    expect(m3Cur(), SystemMouseCursors.click);
    // empty sky -> arrow
    await tester.sendEventToBinding(ptr.hover(m3Tl + const Offset(40, 40)));
    await tester.pump();
    expect(m3Cur(), SystemMouseCursors.basic);

    // mid-drag pan -> move cursor on whichever canvas is dragged
    final midP = await tester.startGesture(
      m3Tl + const Offset(300, 300),
      kind: PointerDeviceKind.mouse,
      buttons: kMiddleMouseButton,
    );
    await midP.moveBy(const Offset(20, 10));
    await tester.pump();
    expect(m3Cur(), SystemMouseCursors.move);
    await midP.up();
    await tester.pump();

    // W -> precise crosshair returns on both panes
    await tester.sendKeyEvent(LogicalKeyboardKey.keyW);
    await tester.pumpAndSettle();
    expect(planCur(), SystemMouseCursors.precise);
    expect(m3Cur(), SystemMouseCursors.precise);

    est.models.clear();
  });

  testWidgets('3D MODEL fit-to-content respects edge padding', (tester) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    est.newProject();
    await tester.pumpWidget(const BoqApp());
    await tester.pumpAndSettle();
    await tester.tap(find.text('3D MODEL'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('New model'));
    await tester.pumpAndSettle();

    final st = tester.state(find.byType(ModelView)) as dynamic;
    final m = est.models.first;
    m.walls.add(Wall3d(points: [1, -1, 5, -1, 5, 3]));
    m.volumes.add(
      Volume3d(footprint: [-2, 2, -0.5, 2, -0.5, 3.5, -2, 3.5], height: 2),
    );
    est.update();
    await tester.pumpAndSettle();

    final plan = find.byKey(const Key('modelPlan'));
    final model = find.byKey(const Key('model3d'));
    final pTl = tester.getTopLeft(plan);
    final pSz = tester.getSize(plan);
    Offset toScreen(Offset w) =>
        pTl +
        (st.planOffset as Offset) +
        Offset(
          w.dx * (st.planScale as double),
          -w.dy * (st.planScale as double),
        );

    // tap the canvas fit buttons — the real user path
    await tester.tap(find.byTooltip('Fit plan (zoom extents)'));
    await tester.pumpAndSettle();

    // every model-bounds corner (plus labelPad) inside the plan safe
    // rect: left/right 20, top 48, bottom 34
    final bb = m.bounds!;
    for (final c in [
      const Offset(-0.7, -0.7),
      const Offset(0.7, 0.7),
      Offset(bb.$1 - 0.7, bb.$2 - 0.7),
      Offset(bb.$3 + 0.7, bb.$4 + 0.7),
      Offset(bb.$3 + 0.7, bb.$2 - 0.7),
      Offset(bb.$1 - 0.7, bb.$4 + 0.7),
    ]) {
      final s = toScreen(c);
      expect(
        s.dx,
        inInclusiveRange(pTl.dx + 19.5, pTl.dx + pSz.width - 19.5),
        reason: 'plan safe-x $c -> $s',
      );
      expect(
        s.dy,
        inInclusiveRange(pTl.dy + 47.5, pTl.dy + pSz.height - 33.5),
        reason: 'plan safe-y $c -> $s',
      );
    }

    // 3D fit: project the bounds' 8 corners — all inside the safe
    // rect (left/right 20, top 46, bottom 36)
    await tester.tap(find.byTooltip('Fit model (zoom extents)'));
    await tester.pumpAndSettle();
    final m3Tl = tester.getTopLeft(model);
    final m3Sz = tester.getSize(model);
    for (final x in [bb.$1, bb.$3]) {
      for (final y in [bb.$2, bb.$4]) {
        for (final z in [0.0, bb.$5]) {
          final s = m3Tl + (st.debugProj3(x, y, z) as Offset);
          expect(
            s.dx,
            inInclusiveRange(m3Tl.dx + 19.5, m3Tl.dx + m3Sz.width - 19.5),
            reason: '3D safe-x ($x,$y,$z) -> $s',
          );
          expect(
            s.dy,
            inInclusiveRange(m3Tl.dy + 45.5, m3Tl.dy + m3Sz.height - 35.5),
            reason: '3D safe-y ($x,$y,$z) -> $s',
          );
        }
      }
    }

    est.models.clear();
  });

  testWidgets('3D MODEL toolbar collapses to icon mode at narrow widths', (
    t,
  ) async {
    t.view.physicalSize = const Size(1600, 900);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
    est.newProject();
    await t.pumpWidget(const BoqApp());
    await t.pumpAndSettle();
    await t.tap(find.text('3D MODEL'));
    await t.pumpAndSettle();
    await t.tap(find.byTooltip('New model'));
    await t.pumpAndSettle();

    // full width: labeled chips + parts count + labeled action
    expect(find.text('t 0.15'), findsOneWidget);
    expect(find.byTooltip('Wall thickness'), findsOneWidget);
    expect(find.textContaining('parts'), findsOneWidget);
    expect(find.text('GENERATE DRAWING'), findsOneWidget);

    // compact (~684px toolbar): chips -> icons, parts count hides,
    // GENERATE keeps its label, every tool stays visible
    t.view.physicalSize = const Size(1100, 900);
    await t.pumpAndSettle();
    expect(find.text('t 0.15'), findsNothing);
    expect(
      find.byWidgetPredicate(
        (w) => w is PopupMenuButton && w.tooltip == 'Wall thickness 0.15 m',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('parts'), findsNothing);
    expect(find.text('GENERATE DRAWING'), findsOneWidget);
    for (final ic in [
      Icons.near_me_outlined,
      Icons.square_outlined,
      Icons.crop_square,
      Icons.timeline,
      Icons.grid_4x4,
      Icons.fit_screen,
    ]) {
      expect(find.byIcon(ic), findsWidgets, reason: '$ic must stay visible');
    }
    // block chip collapsed to an icon that still opens the Blocks tab
    await t.tap(
      find.byWidgetPredicate(
        (w) => w is IconButton && (w.tooltip ?? '').startsWith('Armed block:'),
      ),
      warnIfMissed: false,
    );
    await t.pumpAndSettle();
    expect(find.text('OPENINGS'), findsOneWidget);

    // tight (~344px toolbar): GENERATE drops its label too
    t.view.physicalSize = const Size(760, 900);
    await t.pumpAndSettle();
    expect(find.text('GENERATE DRAWING'), findsNothing);
    expect(find.byTooltip('Generate drawing'), findsOneWidget);
    // and the action still fires from the icon (empty model ->
    // the "draw first" snackbar proves _generate ran)
    await t.tap(find.byTooltip('Generate drawing'), warnIfMissed: false);
    await t.pumpAndSettle();
    expect(find.text('Draw some walls or volumes first.'), findsOneWidget);

    est.models.clear();
  });

  test('hairlinePx/pxSnap: strokes land on one device pixel', () {
    // a hairline is exactly one physical px at any scaling
    expect(hairlinePx(1.0), 1.0);
    expect(hairlinePx(1.25), closeTo(0.8, 1e-9));
    expect(hairlinePx(1.5), closeTo(2 / 3, 1e-9));
    expect(hairlinePx(2.0), 0.5);
    // pxSnap lands on device-pixel CENTERS (x.5) within half a device px
    for (final dpr in [1.0, 1.25, 1.5, 2.0]) {
      for (var v = 3.0; v < 400.0; v += 7.37) {
        final s = pxSnap(v, dpr);
        expect(
          (s * dpr) % 1.0,
          closeTo(0.5, 1e-9),
          reason: 'v=$v dpr=$dpr -> ${s * dpr}',
        );
        expect((s - v).abs(), lessThanOrEqualTo(0.5 / dpr + 1e-9));
      }
    }
  });

  testWidgets('3D MODEL painters receive the real devicePixelRatio', (t) async {
    t.view.physicalSize = const Size(1600, 900);
    t.view.devicePixelRatio = 1.5;
    addTearDown(t.view.reset);
    est.newProject();
    await t.pumpWidget(const BoqApp());
    await t.pumpAndSettle();
    await t.tap(find.text('3D MODEL'));
    await t.pumpAndSettle();
    // both canvas painters carry the window's 1.5 DPR into the hairline math
    final ours = find
        .byWidgetPredicate(
          (w) =>
              w is CustomPaint &&
              w.painter != null &&
              (w.painter.runtimeType.toString().contains('PlanPainter') ||
                  w.painter.runtimeType.toString().contains('SolidPainter')),
        )
        .evaluate()
        .map(
          (e) => (
            (e.widget as CustomPaint).painter.runtimeType.toString(),
            ((e.widget as CustomPaint).painter as dynamic).dpr as double,
          ),
        )
        .toList();
    expect(ours.length, 2);
    expect(ours.map((r) => r.$2).toSet(), {1.5});
  });

  testWidgets('3D MODEL empty model shows 3-step onboarding card', (t) async {
    t.view.physicalSize = const Size(1600, 900);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
    est.newProject();
    est.modelIntroDismissed = false;
    await t.pumpWidget(const BoqApp());
    await t.pumpAndSettle();
    await t.tap(find.text('3D MODEL'));
    await t.pumpAndSettle();
    await t.tap(find.byTooltip('New model'));
    await t.pumpAndSettle();

    // card up with all three steps
    expect(find.text('Start your model'), findsOneWidget);
    expect(find.text('Draw walls (W)'), findsOneWidget);
    expect(find.text('Place blocks (B)'), findsOneWidget);
    expect(find.text('Generate drawing'), findsOneWidget);

    // the card must NEVER eat a canvas tap: tap a point INSIDE the
    // card's dead area (avoiding the x button) and the wall chain
    // still starts — the tap falls through to the plan
    final card = t.getTopLeft(find.text('Start your model'));
    final inside = card + const Offset(60, 80); // body, off the x
    await t.tapAt(inside);
    await t.pumpAndSettle();
    final m = est.models.last;
    expect(m.walls, isEmpty); // nothing committed yet, but...
    final st = t.state(find.byType(ModelView)) as dynamic;
    expect(
      (st.wallChainDebug as List).length,
      1,
    ); // ...the chain DID start under the card

    // finish the chain -> bounds appear -> card auto-hides
    await t.tapAt(inside + const Offset(120, 60));
    await t.tapAt(inside + const Offset(120, 60)); // re-tap = commit
    await t.pumpAndSettle();
    expect(m.walls, isNotEmpty);
    expect(find.text('Start your model'), findsNothing);

    // deleting parts keeps it hidden only while geometry exists — a
    // fresh empty model shows it again until the user dismisses it
    await t.tap(find.byTooltip('New model'));
    await t.pumpAndSettle();
    expect(find.text('Start your model'), findsOneWidget);
    await t.tap(find.byTooltip('Hide tips'));
    await t.pumpAndSettle();
    expect(find.text('Start your model'), findsNothing);
    await t.tap(find.byTooltip('New model'));
    await t.pumpAndSettle();
    expect(find.text('Start your model'), findsNothing);

    est.models.clear();
    est.modelIntroDismissed = false;
  });

  testWidgets('3D MODEL selection accent: active pane vs desaturated', (
    t,
  ) async {
    t.view.physicalSize = const Size(1600, 900);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
    est.newProject();
    est.modelIntroDismissed = true; // keep the hint card off the canvas
    await t.pumpWidget(const BoqApp());
    await t.pumpAndSettle();
    await t.tap(find.text('3D MODEL'));
    await t.pumpAndSettle();
    await t.tap(find.byTooltip('New model'));
    await t.pumpAndSettle();
    final m = est.models.first;
    await t.tap(find.text('Inspect'));
    await t.pumpAndSettle();

    // draw + select a wall on the plan (tap = plan pane active)
    final pc = t.getCenter(find.byKey(const Key('modelPlan')));
    await t.tapAt(pc + const Offset(-160, -80));
    await t.tapAt(pc + const Offset(120, -80));
    await t.tapAt(pc + const Offset(120, -80)); // re-tap = commit
    await t.pumpAndSettle();
    expect(m.walls.length, 1);
    await t.sendKeyEvent(LogicalKeyboardKey.keyA);
    await t.pumpAndSettle();
    await t.tapAt(pc + const Offset(-20, -80));
    await t.pumpAndSettle();
    final st = t.state(find.byType(ModelView)) as dynamic;
    expect(find.text('Delete wall'), findsOneWidget); // wall selected
    expect(st.paneActivePlanDebug, isTrue); // plan = active pane

    // shared vocabulary: accent on active, desaturated on passive
    final cs = Theme.of(t.element(find.byType(ModelView))).colorScheme;
    expect(selColorFor(cs, true), cs.primary);
    expect(
      selColorFor(cs, false),
      Color.lerp(cs.primary, const Color(0xFF94A3B8), 0.62),
    );

    // hovering the 3D canvas makes IT the active pane -> plan desats
    final mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(t.getCenter(find.byKey(const Key('model3d'))));
    await t.pump();
    expect(st.paneActivePlanDebug, isFalse);

    // back over the plan -> active again (sticky last-pane rule)
    await mouse.moveTo(pc);
    await t.pump();
    expect(st.paneActivePlanDebug, isTrue);
    await mouse.removePointer();

    est.models.clear();
    est.modelIntroDismissed = false;
  });

  testWidgets('3D MODEL tab badges: armed block + selected part names', (
    t,
  ) async {
    t.view.physicalSize = const Size(1600, 900);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
    est.newProject();
    est.modelIntroDismissed = true;
    await t.pumpWidget(const BoqApp());
    await t.pumpAndSettle();
    await t.tap(find.text('3D MODEL'));
    await t.pumpAndSettle();
    await t.tap(find.byTooltip('New model'));
    await t.pumpAndSettle();
    final m = est.models.first;

    // Blocks badge always carries the armed piece
    final segs = find.byType(SegmentedButton<int>);
    expect(
      find.descendant(of: segs, matching: find.text(kCadBlocks.first.name)),
      findsOneWidget,
    );
    // nothing selected yet -> no Inspect badge
    expect(
      find.descendant(of: segs, matching: find.textContaining('WALL ·')),
      findsNothing,
    );

    // commit a wall -> auto-selected -> Inspect badge names it
    final pc = t.getCenter(find.byKey(const Key('modelPlan')));
    await t.tapAt(pc + const Offset(-160, -80));
    await t.tapAt(pc + const Offset(120, -80));
    await t.tapAt(pc + const Offset(120, -80));
    await t.pumpAndSettle();
    expect(m.walls.length, 1);
    expect(
      find.descendant(of: segs, matching: find.textContaining('WALL ·')),
      findsOneWidget,
    );

    // Esc releases the selection -> Inspect badge empties again
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await t.pumpAndSettle();
    expect(
      find.descendant(of: segs, matching: find.textContaining('WALL ·')),
      findsNothing,
    );

    // arming a different block renames the Blocks badge
    final other = kCadBlocks.firstWhere((b) => b.name != kCadBlocks.first.name);
    final st = t.state(find.byType(ModelView)) as dynamic;
    st.armBlockDebug(other);
    await t.pumpAndSettle();
    expect(
      find.descendant(of: segs, matching: find.text(other.name)),
      findsOneWidget,
    );

    est.models.clear();
    est.modelIntroDismissed = false;
  });

  testWidgets('3D MODEL imported OBJ blocks list in library + render mesh', (
    t,
  ) async {
    t.view.physicalSize = const Size(1600, 900);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
    est.newProject();
    est.modelIntroDismissed = true;
    await t.pumpWidget(const BoqApp());
    await t.pumpAndSettle();
    await t.tap(find.text('3D MODEL'));
    await t.pumpAndSettle();
    await t.tap(find.byTooltip('New model'));
    await t.pumpAndSettle();
    final m = est.models.first;

    // the import affordance lives at the top of the Blocks library
    expect(find.byKey(const Key('import-obj')), findsOneWidget);

    // registering an OBJ creates an 'Imported' library row that arms
    // the block tool on tap
    final om = parseObj('''
v 0 0 0
v 0.5 0 0
v 0.5 0.4 0
v 0 0.4 0
v 0 0.8 0
v 0.5 0.8 0
v 0.5 1.2 0
v 0 1.2 0
f 1 2 6 5
f 2 3 7 6
f 3 4 8 7
f 4 1 5 8
f 5 6 7 8
''')!;
    final def = registerObjBlock('Test chair', om);
    await t.pumpAndSettle();
    // filter the library to bring the Imported row to the top
    await t.enterText(find.byKey(const Key('lib-search')), 'test');
    await t.pumpAndSettle();
    expect(find.text('IMPORTED'), findsOneWidget);
    expect(find.text('Test chair'), findsOneWidget);
    await t.tap(find.text('Test chair'));
    await t.pumpAndSettle();

    // placing it emits real mesh faces — never the box prism
    m.blocks.add(Block3d(def: def.id, x: 0, y: 0));
    await t.pumpAndSettle();
    expect(modelFaces(m).where((f) => f.argb == 0xFF9E9E9E).length, 5);

    customCadBlocks.clear();
    blockMeshes.remove(def.id);
    blockMeshTop.remove(def.id);
    est.models.clear();
    est.modelIntroDismissed = false;
  });

  testWidgets('DRAWINGS scale picker + AutoCAD nav on a generated sheet', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const BoqApp());
    await tester.pumpAndSettle();
    est.drawings.clear();
    est.drawingXfms.clear();

    // write a real generated sheet (paper-space mm, carries a
    // 'SCALE 1:N' text — N becomes the anchor for the scale picker)
    final m = Model3d(name: 'SCALE_TEST')
      ..walls.add(
        Wall3d(points: [0, 0, 6, 0, 6, 4, 0, 4, 0, 0], thickness: 0.15),
      );
    final src = buildModelSheet(m, SheetView.plan);
    final denom = int.parse(
      RegExp(r'SCALE 1:(\d+)').firstMatch(src)!.group(1)!,
    );
    final tmp = File('${Directory.systemTemp.path}\\ce_scale_test.dxf')
      ..writeAsStringSync(src);
    await tester.tap(find.text('DRAWINGS'));
    await tester.pumpAndSettle();
    est.addDrawing(tmp.path, 'dxf');
    await tester.pump();
    await tester.tap(find.textContaining('ce_scale_test'));
    await tester.pump();
    await tester.runAsync(
      () => Future.delayed(const Duration(milliseconds: 800)),
    );
    await tester.pump();
    await tester.pump();
    final iv = find.byType(InteractiveViewer);
    expect(iv, findsOneWidget);
    double zoom() => tester
        .widget<InteractiveViewer>(iv)
        .transformationController!
        .value
        .getMaxScaleOnAxis();
    // settle onto a deterministic view: the async load's own fit may
    // still be in flight, so drive the Fit button explicitly
    await tester.tap(find.byIcon(Icons.fit_screen));
    await tester.pumpAndSettle();

    // the label reads the equivalent paper scale, not a raw percent
    expect(find.textContaining('1:'), findsWidgets);

    // scale dropdown -> pick 1:100. The viewer content is the scene
    // scaled to naturalSize (1600px across the 297mm sheet), so
    // zoom = 96/25.4 * denom/100 / (1600/297)
    const unitsPerMm = 1600 / 297;
    final chip = find.ancestor(
      of: find.byIcon(Icons.arrow_drop_down),
      matching: find.byType(PopupMenuButton<double>),
    );
    await tester.tap(chip.last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('1:100').last);
    await tester.pumpAndSettle();
    expect(zoom(), closeTo(96 / 25.4 * denom / 100 / unitsPerMm, 0.01));
    expect(find.text('1:100'), findsOneWidget);

    // wheel scroll zooms AT THE CURSOR like AutoCAD
    final c = tester.getCenter(iv);
    final z0 = zoom();
    final ptr = TestPointer(7, PointerDeviceKind.mouse);
    await ptr.addPointer(location: c);
    await tester.sendEventToBinding(ptr.scroll(const Offset(0, -120)));
    await tester.pump();
    expect(zoom(), greaterThan(z0));
    // and scroll-down zooms back out — past the start, not just to it
    // (each wheel detent applies one 1/1.25 factor)
    await tester.sendEventToBinding(ptr.scroll(const Offset(0, 120)));
    await tester.sendEventToBinding(ptr.scroll(const Offset(0, 120)));
    await tester.pump();
    expect(zoom(), lessThan(z0));

    // middle-button drag pans the sheet without switching tools
    final m0 = tester
        .widget<InteractiveViewer>(iv)
        .transformationController!
        .value
        .getTranslation();
    await tester.sendEventToBinding(ptr.down(c, buttons: kMiddleMouseButton));
    await tester.sendEventToBinding(ptr.move(c + const Offset(40, 25)));
    await tester.sendEventToBinding(ptr.up());
    await tester.pump();
    final m1 = tester
        .widget<InteractiveViewer>(iv)
        .transformationController!
        .value
        .getTranslation();
    expect((m1.x - m0.x), closeTo(40, 1));
    expect((m1.y - m0.y), closeTo(25, 1));

    // double-middle-click = zoom extents (fit) — the whole sheet
    // returns to view
    await tester.sendEventToBinding(ptr.down(c, buttons: kMiddleMouseButton));
    await tester.sendEventToBinding(ptr.up());
    await tester.sendEventToBinding(ptr.down(c, buttons: kMiddleMouseButton));
    await tester.sendEventToBinding(ptr.up());
    await tester.pumpAndSettle();
    expect(zoom(), isNot(closeTo(96 / 25.4 * denom / 100 / unitsPerMm, 0.01)));
    est.drawings.clear();
  });

  testWidgets('DRAWINGS move-sheet tool pans the drawing in its frame', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const BoqApp());
    await tester.pumpAndSettle();
    est.drawings.clear();
    est.drawingXfms.clear();

    // a real generated sheet registered like _generate does —
    // 'sheet:{modelId}:{slug}' is what links it back to the model
    final m = Model3d(name: 'MOVE_TEST')
      ..walls.add(
        Wall3d(points: [0, 0, 6, 0, 6, 4, 0, 4, 0, 0], thickness: 0.15),
      );
    est.models.add(m);
    final path = '${Directory.systemTemp.path}\\ce_move_test.dxf';
    File(path).writeAsStringSync(buildModelSheet(m, SheetView.plan));
    est.drawings.add(
      DrawingFile(
        id: 'sheet:${m.id}:floorplan',
        path: path,
        name: 'MOVE_TEST — FLOOR PLAN.dxf',
        kind: 'dxf',
      ),
    );
    await tester.tap(find.text('DRAWINGS'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('MOVE_TEST'));
    await tester.pump();
    await tester.runAsync(
      () => Future.delayed(const Duration(milliseconds: 800)),
    );
    await tester.pump();
    await tester.pump();
    expect(find.byType(InteractiveViewer), findsOneWidget);
    await tester.tap(find.byIcon(Icons.fit_screen));
    await tester.pumpAndSettle();

    // the move-sheet tool shows only on generated sheets
    await tester.tap(
      find.byTooltip('Move drawing on sheet — drag it inside the frame'),
    );
    await tester.pumpAndSettle();

    // drag the drawing down-right inside the frame: screen +x/+y maps
    // to paper +x/-y mm (the painter y-flips)
    final iv = find.byType(InteractiveViewer);
    final c = tester.getCenter(iv);
    await tester.dragFrom(c, const Offset(60, 40));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();

    final pan = m.sheetPan[SheetView.plan.name];
    expect(pan, isNotNull);
    expect(pan!.dx, greaterThan(0));
    expect(pan.dy, lessThan(0));

    // the DXF on disk was regenerated with the offset baked in: it
    // matches a same-model build WITH the pan and differs from one
    // without it — the stored offset reached paper space
    final regen = File(path).readAsStringSync();
    final panNow = m.sheetPan.remove(SheetView.plan.name)!;
    final zero = buildModelSheet(m, SheetView.plan);
    m.sheetPan[SheetView.plan.name] = panNow;
    final again = buildModelSheet(m, SheetView.plan);
    expect(regen == zero, isFalse);
    expect(regen, again);
    est.drawings.clear();
    est.models.remove(m);
  });
}
