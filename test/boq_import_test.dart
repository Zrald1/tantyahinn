import 'dart:io';

import 'package:tantyahin/boq_import.dart';
import 'package:tantyahin/calculators.dart';
import 'package:tantyahin/docx_export.dart';
import 'package:tantyahin/excel_export.dart';
import 'package:tantyahin/models.dart';
import 'package:tantyahin/pdf_export.dart';
import 'package:tantyahin/pdf_import.dart';
import 'package:tantyahin/state.dart';
import 'package:flutter_test/flutter_test.dart';

EstimateState _seed() {
  final e = EstimateState();
  final r = calcConcrete(volume: 10, concreteClass: 'CLASS A (1:2:4)');
  e.addWork(
    sectionTitle: 'I. CONCRETE WORKS',
    groupLabel: 'GROUND FLOOR',
    items: r.lines.map((x) => x.toBoqLine()).toList(),
  );
  e.addWork(
    sectionTitle: 'II. MASONRY WORKS',
    groupLabel: '',
    items: [
      BoqLine(
        description: 'CHB 6" load bearing',
        qty: 88,
        unit: 'sq.m',
        materialCost: 250,
        laborCost: 75,
      ),
    ],
  );
  return e;
}

void main() {
  test('CSV: header row maps columns, roman sections, totals skipped', () {
    const csv = 'PROJECT X\n'
        'ITEM NO.,Qty,Unit,ITEM DESCRIPTION,UNIT COST,TOTAL COST\n'
        ',,,,Material Cost,Labor Cost,\n'
        'I. SITE WORKS\n'
        'a,10,sq.m,Clearing and grubbing,50,25,750\n'
        'b,5,cu.m,Excavation,120,30,750\n'
        'SUB TOTAL:,,,,,1500\n'
        'II. CONCRETE\n'
        'c,20,bags,Cement 40kg,350,0,7000\n'
        'GRAND TOTAL:,,,,,8500\n';
    final r = BoqImport.fromDelimitedText(csv);
    expect(r.sections.length, 2);
    expect(r.sections[0].title, contains('SITE WORKS'));
    expect(r.sections[0].lines.length, 2);
    final l = r.sections[0].lines.first;
    expect(l.description, 'Clearing and grubbing');
    expect(l.qty, 10);
    expect(l.unit, 'sq.m');
    expect(l.materialCost, 50);
    expect(l.laborCost, 25);
    expect(r.sections[1].lines.single.qty, 20);
    expect(r.lineCount, 3);
  });

  test('CSV: no header falls back to positional columns with warning', () {
    const csv = 'Clearing,10,sq.m,50\nCement,20,bags,350\n';
    final r = BoqImport.fromDelimitedText(csv);
    expect(r.warnings, isNotEmpty);
    expect(r.sections.length, 1);
    expect(r.sections[0].lines[0].qty, 10);
    expect(r.sections[0].lines[0].unit, 'sq.m');
    expect(r.sections[0].lines[0].materialCost, 50);
  });

  test('CSV: quoted fields with commas survive', () {
    const csv = 'ITEM NO.,QTY,UNIT,DESCRIPTION,UNIT COST\n'
        '1,5,pcs,"Bolt, anchor, 12mm",42.50\n';
    final r = BoqImport.fromDelimitedText(csv);
    expect(r.sections.single.lines.single.description, 'Bolt, anchor, 12mm');
    expect(r.sections.single.lines.single.materialCost, 42.5);
  });

  test('xlsx round-trip: our own export re-imports sections + items',
      () async {
    final e = _seed();
    final bytes = (await ExcelExport(e).build())!;
    final r = BoqImport.fromExcelBytes(bytes);
    expect(r.sections.length, greaterThanOrEqualTo(2));
    final titles = r.sections.map((s) => s.title).join('|');
    expect(titles, contains('CONCRETE WORKS'));
    expect(titles, contains('MASONRY WORKS'));
    final chb = r.sections
        .expand((s) => s.lines)
        .firstWhere((l) => l.description.contains('CHB 6'));
    expect(chb.qty, 88);
    expect(chb.unit, 'sq.m');
    expect(chb.materialCost, 250);
    expect(chb.laborCost, 75);
    // group header from 'GROUND FLOOR' survives as a header line
    expect(
      r.sections
          .expand((s) => s.lines)
          .any((l) => l.kind == BoqLineKind.groupHeader),
      isTrue,
    );
  });

  test('docx round-trip: DocxEstimate BOQ table re-imports', () async {
    // DocxEstimate reads the global est — seed the active tab's state
    projectTabs.reset();
    est.newProject();
    final c = calcConcrete(volume: 10, concreteClass: 'CLASS A (1:2:4)');
    est.addWork(
      sectionTitle: 'I. CONCRETE WORKS',
      groupLabel: 'GROUND FLOOR',
      items: c.lines.map((x) => x.toBoqLine()).toList(),
    );
    final bytes = await DocxExport.buildEstimate();
    final r = BoqImport.fromDocxBytes(bytes);
    expect(r.sections, isNotEmpty);
    final titles = r.sections.map((s) => s.title).join('|');
    expect(titles, contains('CONCRETE WORKS'));
    expect(r.lineCount, greaterThanOrEqualTo(2));
  });

  test('importBoq: append keeps existing, replace swaps wholesale', () {
    final e = _seed();
    final before = e.sections.length;
    final imported = [
      BoqSection(
        title: 'III. IMPORTED',
        lines: [BoqLine(description: 'X', qty: 1, unit: 'lot')],
      ),
    ];
    e.importBoq(imported, replace: false);
    expect(e.sections.length, before + 1);
    final oldId = imported[0].id;
    e.importBoq(imported, replace: true);
    expect(e.sections.length, 1);
    expect(e.sections.single.title, 'III. IMPORTED');
    // ids were regenerated — no collision with the source list
    expect(e.sections.single.id, isNot(oldId));
  });

  test('pdfium: pdf text extraction produces mappable rows', () async {
    if (!PdfText.available) {
      // dev box without the plugin dll — nothing to verify against
      return;
    }
    final e = _seed();
    final bytes = await PdfExport(e).build();
    expect(bytes, isNotNull);
    final tmp = File(
      '${Directory.systemTemp.path}/boq_imp_${DateTime.now().microsecondsSinceEpoch}.pdf',
    );
    await tmp.writeAsBytes(bytes!);
    try {
      final rows = await PdfText.extractRows(tmp.path);
      expect(rows, isNotEmpty);
      final r = BoqImport.rowsToSections(rows, source: 'test pdf');
      expect(
        r.sections.expand((s) => s.lines).map((l) => l.description).join('|'),
        contains('CHB'),
      );
    } finally {
      await tmp.delete();
    }
  });
}
