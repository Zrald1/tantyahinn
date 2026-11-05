import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tantyahin/main.dart';
import 'package:tantyahin/model3d.dart';
import 'package:tantyahin/models.dart';
import 'package:tantyahin/state.dart';

/// Generated-sheet title block in the DRAWINGS viewer: the logo cell
/// and project-title cell are tap targets — logo opens the picker /
/// a remove menu, title opens an inline editor for `project.title`.
void main() {
  // redirect the app data dir — otherwise the pumped app restores the
  // developer's real sessions.json + autosave mid-test
  setUp(() {
    ProjectTabs.dataDirOverride = Directory.systemTemp.createTempSync(
      'ce_tabs',
    );
    projectTabs.reset();
  });
  tearDown(() {
    projectTabs.reset();
    ProjectTabs.dataDirOverride = null;
  });

  Future<void> addSheet(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final m = est.addModel('TESTHOUSE');
    m.walls.add(Wall3d(points: [0, 0, 4, 0, 4, 3, 0, 3, 0, 0]));
    final dir = Directory.systemTemp.createTempSync('sheet_cells');
    final f = File('${dir.path}\\sheet.dxf')
      ..writeAsStringSync(
        buildModelSheet(m, SheetView.plan, project: est.project),
      );
    est.drawings.add(
      DrawingFile(
        id: 'sheet:${m.id}:floorplan',
        path: f.path,
        name: 'S.dxf',
        kind: 'dxf',
      ),
    );
    await tester.pumpWidget(const BoqApp());
    await tester.pumpAndSettle();
    await tester.tap(find.text('DRAWINGS'));
    await tester.pumpAndSettle();
  }

  testWidgets('title cell edits inline + corner handle resizes', (
    tester,
  ) async {
    await addSheet(tester);
    final cell = find.byKey(const Key('sheet-cell-title'));
    expect(cell, findsOneWidget);
    await tester.tap(cell);
    await tester.pumpAndSettle();
    // typing lands straight on the canvas at sheet scale — no popup
    final field = find.byKey(const Key('sheet-title-field'));
    expect(field, findsOneWidget);
    await tester.enterText(field, 'RENOVATED TITLE');
    await tester.pump();
    expect(est.project.title, 'RENOVATED TITLE');

    // the corner handle resizes the title's mm glyph height live
    final before = est.project.titleSize;
    await tester.drag(
      find.byKey(const Key('sheet-title-size')),
      const Offset(20, 20),
    );
    await tester.pump();
    expect(est.project.titleSize, greaterThan(before));
  });

  testWidgets('logo cell renders logoB64 + right-click removes it', (
    tester,
  ) async {
    est.project.logoB64 = base64Encode(
      File('assets/deped_logo.png').readAsBytesSync(),
    );
    await addSheet(tester);
    final cell = find.byKey(const Key('sheet-cell-logo'));
    expect(cell, findsOneWidget);
    await tester.tapAt(tester.getCenter(cell), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove logo'));
    await tester.pumpAndSettle();
    expect(est.project.logoB64, isNull);
  });
}
