import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tantyahin/main.dart';
import 'package:tantyahin/model3d.dart';
import 'package:tantyahin/models.dart';
import 'package:tantyahin/state.dart';

/// The document-template system: 'deped'/'private' builtin templates
/// plus user-saved/uploaded ones. Each template owns its letterhead,
/// logo and signatories; applying one stamps them onto the project.
/// Private signs its documents too — Prepared by the engineer — so the
/// signature block shows under every template that asks for it.
void main() {
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

  DocTemplate privateTpl() =>
      builtinDocTemplates().firstWhere((t) => t.id == 'private');

  test('default: Gerald prepares, other seats keep titles, names blank', () {
    final p = ProjectInfo();
    expect(p.template, 'deped');
    expect(p.signatories, hasLength(4));
    expect(p.signatories.first.name, 'GERALD BUSTILLA');
    expect(p.signatories.first.position, 'Civil Engineer');
    expect(p.signatories[1].label, 'Checked & Reviewed by');
    expect(p.signatories[1].name, isEmpty);
    expect(p.signatories[1].position, 'Division Engineer');
    expect(p.signatories[2].position, 'SGOD Chief');
    expect(p.signatories[3].position, 'Schools Division Superintendent');
  });

  test('fromJson blanks retired names, normalizes Gerald, migrates ids', () {
    final p = ProjectInfo.fromJson({
      'signatories': [
        {'label': 'Prepared by', 'name': 'GERALD P. BUSTILLA', 'position': 'EFS - Staff'},
        {'label': 'Checked & Reviewed by', 'name': 'VIRGILIO B. BANCASO', 'position': 'Division Engineer'},
        {'label': 'Approved by', 'name': 'NORMA B. SAMANTELA, CESO V', 'position': 'SDS'},
      ],
      'template': 'public',
    });
    expect(p.template, 'deped');
    expect(p.signatories[0].name, 'GERALD BUSTILLA');
    expect(p.signatories[0].position, 'Civil Engineer');
    expect(p.signatories[1].name, isEmpty);
    expect(p.signatories[1].position, 'Division Engineer');
    // the missing 'Recommending Approval' seat is restored in order
    expect(p.signatories, hasLength(4));
    expect(p.signatories[2].label, 'Recommending Approval by');
    expect(p.signatories[2].position, 'SGOD Chief');
    expect(p.signatories[3].name, isEmpty);
    expect(p.signatories[3].position, 'SDS');
    // unknown/custom ids are kept — the library resolves or falls back
    expect(ProjectInfo.fromJson({'template': 'tpl-9'}).template, 'tpl-9');
  });

  test('stale one-seat saves get the four DepEd seats back', () {
    // a project saved while the sign-off was one row only
    final stale = ProjectInfo.fromJson({
      'signatories': [
        {
          'label': 'Prepared by',
          'name': 'GERALD BUSTILLA',
          'position': 'Civil Engineer',
        },
      ],
      'template': 'deped',
    });
    expect(
      stale.signatories.map((s) => s.label),
      [
        'Prepared by',
        'Checked & Reviewed by',
        'Recommending Approval by',
        'Approved by',
      ],
    );
    expect(stale.signatories.skip(1).every((s) => s.name.isEmpty), isTrue);
    // same repair on a persisted deped template (a stored template that
    // captured a truncated sign-off heals on load)
    final tpl = DocTemplate.fromJson({
      'id': 'deped',
      'name': 'DepEd Template',
      'signatories': [
        {
          'label': 'Prepared by',
          'name': 'GERALD BUSTILLA',
          'position': 'Civil Engineer',
        },
      ],
    });
    expect(tpl.signatories, hasLength(4));
    expect(tpl.signatories[3].label, 'Approved by');
    // private templates keep their single engineer sign-off
    final priv = DocTemplate.fromJson({
      'id': 'private',
      'name': 'Private Template',
      'signatories': [
        {
          'label': 'Prepared by',
          'name': 'GERALD BUSTILLA',
          'position': 'Civil Engineer',
        },
      ],
    });
    expect(priv.signatories, hasLength(1));
  });

  test('retired names blank under EVERY template — no seat injection',
      () {
    // a custom-template project file still carrying an office name
    // gets it blanked on load (the name can never export) WITHOUT
    // pulling the four deped seats into a non-deped sign-off
    final p = ProjectInfo.fromJson({
      'signatories': [
        {
          'label': 'Approved by',
          'name': '  norma  b. samantela, ceso v ',
          'position': 'SDS',
        },
        {
          'label': 'Prepared by',
          'name': 'JUAN DELA CRUZ',
          'position': 'Engr.',
        },
      ],
      'template': 'tpl-9',
    });
    expect(p.signatories, hasLength(2));
    expect(p.signatories[0].name, isEmpty); // retired name scrubbed
    expect(p.signatories[0].position, 'SDS'); // title stays
    expect(p.signatories[1].name, 'JUAN DELA CRUZ'); // user name kept
    // same for a persisted CUSTOM template: scrub only, no deped seats
    final tpl = DocTemplate.fromJson({
      'id': 'tpl-77',
      'name': 'My office',
      'signatories': [
        {
          'label': 'Checked & Reviewed by',
          'name': 'PEDRO J. PELONIO',
          'position': 'SGOD Chief',
        },
      ],
    });
    expect(tpl.signatories, hasLength(1));
    expect(tpl.signatories[0].name, isEmpty);
    expect(tpl.signatories[0].position, 'SGOD Chief');
  });

  test('private template: no header/logo but signs with the engineer', () {
    final p = ProjectInfo();
    privateTpl().applyTo(p);
    p.logoB64 = 'AAAA';
    expect(p.isPrivate, isTrue);
    expect(p.effLetterhead, isEmpty);
    expect(p.effLogo, isNull);
    // the signature block stays — Gerald Bustilla, Civil Engineer
    expect(p.effSignatories, isNotEmpty);
    expect(p.effSignatories.first.name, 'GERALD BUSTILLA');
    expect(p.effSignatories.first.position, 'Civil Engineer');
    // back to deped restores the office letterhead + signatories
    builtinDocTemplates().first.applyTo(p);
    expect(p.effLetterhead, p.letterhead);
    expect(p.effSignatories.first.name, 'GERALD BUSTILLA');
    expect(p.effSignatories.length, 4);
  });

  test('generated sheet signs private sheets, hides the DepEd cell', () {
    final m = Model3d(name: 'T')
      ..walls.add(Wall3d(points: [0, 0, 4, 0, 4, 3, 0, 3, 0, 0]));
    final pub = buildModelSheet(m, SheetView.plan, project: ProjectInfo());
    expect(pub, contains('BUSTILLA'));
    expect(pub, contains('DepEd'));
    final pp = ProjectInfo();
    privateTpl().applyTo(pp);
    final priv = buildModelSheet(m, SheetView.plan, project: pp);
    expect(priv, isNot(contains('DepEd')));
    expect(priv, contains('BUSTILLA'));
    expect(priv, contains('CIVIL ENGINEER'));
  });

  testWidgets('template gallery applies + private shows sign-off', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    est.addSection('SITEWORKS');
    await tester.pumpWidget(const BoqApp());
    await tester.pumpAndSettle();
    expect(find.text('Department of Education'), findsOneWidget);
    expect(find.text('Add signatory'), findsOneWidget);

    await tester.tap(find.byKey(const Key('template-btn')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('tpl-deped')), findsOneWidget);
    expect(find.byKey(const Key('tpl-private')), findsOneWidget);
    expect(find.byKey(const Key('tpl-new')), findsOneWidget);
    expect(find.byKey(const Key('tpl-upload')), findsOneWidget);

    await tester.tap(find.byKey(const Key('tpl-private')));
    // applyTemplate awaits the real template-file load — let the
    // event loop turn before settling
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 120)));
    await tester.pumpAndSettle();
    expect(est.project.template, 'private');
    expect(find.text('Department of Education'), findsNothing);
    // private still signs — Prepared by the engineer, and the user can
    // add more signatories right on the sheet
    expect(find.text('GERALD BUSTILLA'), findsOneWidget);
    expect(find.text('Civil Engineer'), findsOneWidget);
    expect(find.text('Add signatory'), findsOneWidget);

    await tester.tap(find.byKey(const Key('template-btn')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('tpl-deped')));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 120)));
    await tester.pumpAndSettle();
    expect(est.project.template, 'deped');
    expect(find.text('Department of Education'), findsOneWidget);
  });

  test('saveAsTemplate snapshots + round-trips through json', () {
    est.project.showLetterhead = false;
    est.project.signatories
      ..clear()
      ..add(Signatory(label: 'Prepared by', name: 'ENG', position: 'CE'));
    final t = est.saveAsTemplate('Mine');
    expect(est.activeTemplate.name, 'Mine');
    expect(est.project.template, t.id);
    final t2 = DocTemplate.fromJson(t.toJson());
    expect(t2.name, 'Mine');
    expect(t2.showLetterhead, isFalse);
    expect(t2.signatories.single.name, 'ENG');
    est.deleteTemplate(t);
    expect(est.project.template, 'deped');
    expect(est.docTemplates.any((x) => x.id == t.id), isFalse);
  });
}
