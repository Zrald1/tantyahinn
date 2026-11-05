import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:tantyahin/calculators.dart';
import 'package:tantyahin/excel_export.dart';
import 'package:tantyahin/formula.dart';
import 'package:tantyahin/models.dart';
import 'package:tantyahin/state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('concrete math matches CONCRETE sheet', () {
    // Sheet example: 20 cu.m class A (1:2:4) -> per cu.m 9 bags? verify formulas
    final r = calcConcrete(volume: 20, concreteClass: 'CLASS A (1:2:4)');
    final cement = r.lines[0].qty;
    final sand = r.lines[1].qty;
    final agg = r.lines[2].qty;
    // cementPer = ceil(1*1.7*1440/7/40) = ceil(8.74) = 9 -> 180 bags
    expect(cement, 180);
    // sandPer = ceil(2*1.7/7*10)/10 = 0.5 -> 20*0.5+0.1 -> 11 (ceil)
    expect(sand, 11);
    // aggRatio = 4*1.7/7 = 0.97 -> >0.5 ceil->1 min(1,1)=1 -> 20
    expect(agg, 20);
  });

  test('masonry math matches MASONRY sheet', () {
    // 88 m2 wall, class A, 40kg, 19mm plaster, 10% allowance
    final r = calcMasonry(wallArea: 88, mortarClass: 'CLASS A (1:2)');
    final chb = r.lines[0].qty;
    expect(chb, (12.5 * 88 * 1.1).ceil());
  });

  test('dry pack math matches TILES sheet D15/D16', () {
    // Sheet: CEMENT = ROUNDUP(9.82*A*T/1000); SAND = ROUNDUP(A*T*0.834/1000)
    // at A=35.75 m2, T=50mm -> cement ceil(17.55)=18, sand ceil(1.49)=2
    final r = calcTiles(
        area: 35.75, tileSize: '0.60 x 0.60', dryPack: true);
    final cement =
        r.lines.firstWhere((l) => l.description.contains('CEMENT')).qty;
    final sand =
        r.lines.firstWhere((l) => l.description == 'SAND').qty;
    expect(cement, 18);
    expect(sand, 2);
    // thinner bed -> less material
    final r25 = calcTiles(
        area: 35.75,
        tileSize: '0.60 x 0.60',
        dryPack: true,
        dryPackMm: 25);
    expect(
        r25.lines.firstWhere((l) => l.description.contains('CEMENT')).qty,
        9);
  });

  test('export produces a workbook with formulas', () async {
    final est = EstimateState();
    final r = calcConcrete(volume: 10, concreteClass: 'CLASS A (1:2:4)');
    est.addWork(
      sectionTitle: r.sectionTitle,
      groupLabel: 'GROUND FLOOR',
      items: r.lines.map((e) => e.toBoqLine()).toList(),
    );
    final bytes = await ExcelExport(est).build();
    expect(bytes, isNotNull);
    expect(bytes!.length, greaterThan(5000));
    expect(est.directCost, greaterThan(0));
  });

  test('export embeds logo, merges formulas', () async {
    final est = EstimateState();
    final r = calcConcrete(volume: 10, concreteClass: 'CLASS A (1:2:4)');
    est.addWork(
      sectionTitle: r.sectionTitle,
      groupLabel: 'GROUND FLOOR',
      items: r.lines.map((e) => e.toBoqLine()).toList(),
    );
    final logo = File('assets/deped_logo.png').readAsBytesSync();
    final bytes = await ExcelExport(est).build(logoBytes: logo);

    final arc = ZipDecoder().decodeBytes(bytes!);
    String part(String n) => utf8.decode(
        arc.files.firstWhere((f) => f.name == n).content as List<int>);
    final names = arc.files.map((f) => f.name).toSet();

    // logo media + drawing parts on both BOQ and POW
    expect(names, contains('xl/media/logo.png'));
    expect(names, contains('xl/drawings/_rels/drawing1.xml.rels'));
    expect(names, contains('xl/drawings/drawing2.xml'));
    expect(names, contains('xl/drawings/_rels/drawing2.xml.rels'));
    expect(names, contains('xl/worksheets/_rels/sheet2.xml.rels'));
    expect(part('xl/drawings/drawing1.xml'), contains('logo.png'));
    expect(part('xl/drawings/drawing1.xml'), contains('r:embed="rId1"'));
    expect(part('xl/drawings/drawing2.xml'), contains('logo.png'));
    // <drawing> must be wired into BOTH sheets — the package emits
    // drawing1.xml + sheet1 rels but never the element, and without it
    // Excel silently drops the BOQ logo (regressed, caught by render)
    expect(part('xl/worksheets/sheet1.xml'),
        contains('<drawing r:id="rId1"/>'));
    expect(part('xl/worksheets/sheet2.xml'), contains('<drawing r:id="rId1"/>'));
    expect(part('[Content_Types].xml'), contains('Extension="png"'));

    // project labels merged wide enough to not clip
    final boq = part('xl/worksheets/sheet1.xml');
    expect(boq, contains('A15:C15'));
    expect(boq, contains('A19:C19'));
    // VLOOKUP formulas still emitted
    expect(boq, contains('VLOOKUP'));
  });

  test(
      'S-CURVE / PERT-NETWORK header, logo and signatories span the whole '
      'landscape spread', () async {
    final e = EstimateState();
    final r = calcConcrete(volume: 10, concreteClass: 'CLASS A (1:2:4)');
    e.addWork(
      sectionTitle: r.sectionTitle,
      groupLabel: 'GROUND FLOOR',
      items: r.lines.map((x) => x.toBoqLine()).toList(),
    );
    // a second section so the network isn't a single-node degenerate
    final m = calcMasonry(wallArea: 40);
    e.addWork(
      sectionTitle: m.sectionTitle,
      groupLabel: 'GROUND FLOOR',
      items: m.lines.map((x) => x.toBoqLine()).toList(),
    );
    // a 5th and 6th signatory force a second band
    e.addSignatory(Signatory(label: 'Noted by', name: 'ANA REYES', position: 'Chief'));
    e.addSignatory(Signatory(label: 'Witness', name: 'JOSE CRUZ', position: 'Auditor'));
    final logo = File('assets/deped_logo.png').readAsBytesSync();
    final arc =
        ZipDecoder().decodeBytes((await ExcelExport(e).build(logoBytes: logo))!);
    String part(String n) => utf8.decode(
        arc.files.firstWhere((f) => f.name == n).content as List<int>);

    int colNum(String s) =>
        s.codeUnits.fold(0, (a, ch) => a * 26 + ch - 64) - 1; // 0-based
    // column pixel edges - ground truth from real Excel COM
    // Range.Left/Width: a stored <col width> is width*7 px, unlisted
    // columns are the 64px default
    List<double> edges(String xml, int count) {
      final w = <int, double>{};
      for (final m in RegExp(r'<col min="(\d+)" max="(\d+)" width="([\d.]+)"')
          .allMatches(xml)) {
        for (var c = int.parse(m[1]!); c <= int.parse(m[2]!); c++) {
          w[c - 1] = double.parse(m[3]!) * 7;
        }
      }
      final out = <double>[0];
      for (var c = 0; c < count; c++) {
        out.add(out.last + (w[c] ?? 64));
      }
      return out;
    }

    final ss = [
      for (final m in RegExp(r'<si>(.*?)</si>', dotAll: true)
          .allMatches(part('xl/sharedStrings.xml')))
        RegExp(r'<t[^>]*>(.*?)</t>', dotAll: true)
            .allMatches(m[1]!)
            .map((t) => t[1])
            .join()
    ];

    for (final (n, name) in [(4, 'PERT-NETWORK'), (5, 'S-CURVE')]) {
      final xml = part('xl/worksheets/sheet$n.xml');
      expect(xml, contains('orientation="landscape"'), reason: name);
      final merges = [
        for (final m in RegExp(r'<mergeCell ref="([A-Z]+)(\d+):([A-Z]+)(\d+)"')
            .allMatches(xml))
          (colNum(m[1]!), int.parse(m[2]!), colNum(m[3]!), int.parse(m[4]!))
      ];

      // the five letterhead rows merge A..last - one shared last column
      final head = merges.where((m) => m.$1 == 0 && m.$2 >= 5 && m.$2 <= 9);
      expect(head, hasLength(5), reason: '$name letterhead rows');
      final last = head.first.$3;
      expect(head.every((m) => m.$3 == last), isTrue, reason: name);
      final ed = edges(xml, last + 2);
      final center = ed[last + 1] / 2;

      // logo centered over that same span (real-Excel probe: <= 1px)
      final logoFrom = RegExp(
              r'<xdr:from><xdr:col>(\d+)</xdr:col><xdr:colOff>(\d+)</xdr:colOff>')
          .firstMatch(part('xl/drawings/drawing$n.xml'))!;
      final logoLeft =
          ed[int.parse(logoFrom[1]!)] + int.parse(logoFrom[2]!) / 9525;
      expect(logoLeft + 36, closeTo(center, 1.5), reason: '$name logo');
      // ...and fits inside the 4 blank rows above the letterhead (real
      // Excel: 4 x 14.25pt = 57pt = 723900 EMU) instead of overlapping
      // the first text line
      final logoRow = RegExp(
              r'</xdr:colOff><xdr:row>(\d+)</xdr:row><xdr:rowOff>(\d+)</xdr:rowOff>')
          .firstMatch(part('xl/drawings/drawing$n.xml'))!;
      expect(int.parse(logoRow[1]!), 0);
      expect(int.parse(logoRow[2]!) + 685800, lessThanOrEqualTo(723900),
          reason: '$name logo bottom must clear the letterhead');

      if (n == 5) {
        // the chart's right edge sits inside the last header column
        final pics = RegExp(
                r'<xdr:from><xdr:col>(\d+)</xdr:col><xdr:colOff>(\d+)</xdr:colOff>.*?<xdr:ext cx="(\d+)"',
                dotAll: true)
            .allMatches(part('xl/drawings/drawing5.xml'))
            .toList();
        final c = pics.last;
        final chartRight = ed[int.parse(c[1]!)] +
            int.parse(c[2]!) / 9525 +
            int.parse(c[3]!) / 9525;
        expect(chartRight, greaterThan(ed[last]), reason: 'chart reaches last col');
        expect(chartRight, lessThanOrEqualTo(ed[last + 1] + 0.5),
            reason: 'header does not overshoot the chart');
      }

      // signatory bands tile 0..last with no gap or overlap
      final idx = ss.indexOf('${e.project.signatories.first.label}:');
      expect(idx, isNonNegative);
      final lblCell = RegExp('<c r="([A-Z]+)(\\d+)"[^>]*t="s"><v>$idx</v>')
          .firstMatch(xml)!;
      final bandRow = int.parse(lblCell[2]!);
      for (final (rowOff, count) in [(0, 5), (8, 1)]) {
        final row = merges
            .where((m) => m.$2 == bandRow + rowOff && m.$4 == m.$2)
            .toList()
          ..sort((a, b) => a.$1.compareTo(b.$1));
        expect(row, hasLength(count), reason: '$name band +$rowOff');
        expect(row.first.$1, 0);
        expect(row.last.$3, last, reason: '$name band +$rowOff spans to last');
        for (var i = 1; i < row.length; i++) {
          expect(row[i].$1, row[i - 1].$3 + 1, reason: '$name contiguous');
        }
      }
    }
  });

  test('formula evaluator handles excel-style expressions', () {
    expect(evalFormula('I*7%', {'I': 100}), closeTo(7, 1e-9));
    expect(evalFormula('=I+II', {'I': 100, 'II': 7}), 107);
    expect(evalFormula('SECTIONS', {'SECTIONS': 42}), 42);
    expect(evalFormula('(I+II)*2', {'I': 3, 'II': 4}), 14);
    expect(evalFormula('20*5.5', const {}), 110);
    expect(evalFormula('BAD', const {}), isNull);
  });

  test('summary rows drive grandTotal and export formulas', () async {
    final est = EstimateState();
    final r = calcConcrete(volume: 10, concreteClass: 'CLASS A (1:2:4)');
    est.addWork(
      sectionTitle: r.sectionTitle,
      groupLabel: 'GF',
      items: r.lines.map((e) => e.toBoqLine()).toList(),
    );
    // default III = I+II = direct + 7%
    expect(est.grandTotal, closeTo(est.directCost * 1.07, 0.01));
    // editable: change II to 5% -> grand total drops
    est.summaryRows[1].formula = 'I*5%';
    expect(est.grandTotal, closeTo(est.directCost * 1.05, 0.01));
    // add a row referencing the others
    est.addSummaryRow();
    est.summaryRows.last.label = ' PLUS 1K';
    est.summaryRows.last.formula = 'III+1000';
    expect(est.grandTotal, closeTo(est.directCost * 1.05 + 1000, 0.01));
    // export emits translated cell formulas
    final bytes = await ExcelExport(est).build();
    final arc = ZipDecoder().decodeBytes(bytes!);
    String part(String n) => utf8.decode(
        arc.files.firstWhere((f) => f.name == n).content as List<int>);
    final boq = part('xl/worksheets/sheet1.xml');
    // I+II translated to real cell refs like <f>I35+I36</f>
    expect(boq, contains(RegExp(r'<f>I\d+\+I\d+')));
    expect(boq, contains('*5%')); // II formula set to I*5% above
    // formulas must NOT carry a stray '=' inside <f> (broke in Excel)
    expect(boq, isNot(contains('<f>=')));
  });

  test('section letters work as formula references', () async {
    final est = EstimateState();
    final r = calcConcrete(volume: 10, concreteClass: 'CLASS A (1:2:4)');
    est.addWork(
      sectionTitle: r.sectionTitle,
      groupLabel: 'GF',
      items: r.lines.map((e) => e.toBoqLine()).toList(),
    );
    // 'A' = first section's subtotal
    est.summaryRows.first.formula = 'A';
    expect(est.summaryValue(est.summaryRows.first),
        closeTo(est.sections.first.subtotal, 0.01));
    // export: A -> the subtotal's I-cell
    final bytes = await ExcelExport(est).build();
    final arc = ZipDecoder().decodeBytes(bytes!);
    final boq = utf8.decode(arc.files
        .firstWhere((f) => f.name == 'xl/worksheets/sheet1.xml')
        .content as List<int>);
    expect(boq, contains(RegExp(r'<f>I\d+')));
  });

  test('reorder helpers move rows, lines and sections', () {
    final est = EstimateState();
    final r = calcConcrete(volume: 10, concreteClass: 'CLASS A (1:2:4)');
    est.addWork(
      sectionTitle: 'FIRST',
      groupLabel: 'GF',
      items: r.lines.map((e) => e.toBoqLine()).toList(),
    );
    est.addWork(
      sectionTitle: 'SECOND',
      groupLabel: 'GF',
      items: r.lines.map((e) => e.toBoqLine()).toList(),
    );
    // summary reorder
    est.addSummaryRow(); // IV
    final iv = est.summaryRows.last;
    est.moveSummaryRow(iv, est.summaryRows.first);
    expect(est.summaryRows.first, same(iv));
    // section reorder
    est.moveSection(est.sections[1], est.sections[0]);
    expect(est.sections.first.title, 'SECOND');
    // line move across sections
    final moved = est.sections[1].lines.first;
    est.moveLine(moved, est.sections[0]);
    expect(est.sections[0].lines, contains(moved));
    expect(est.sections[1].lines, isNot(contains(moved)));
  });

  test('labor rate recomputes auto labor but keeps manual labor', () {
    final e = EstimateState();
    final auto = BoqLine(
        description: 'A', qty: 1, unit: 'pc', materialCost: 100, laborCost: 30);
    final manual = BoqLine(
        description: 'B',
        qty: 1,
        unit: 'pc',
        materialCost: 100,
        laborCost: 55,
        laborOverridden: true);
    final erased = BoqLine(
        description: 'C',
        qty: 1,
        unit: 'pc',
        materialCost: 100,
        laborCost: 0,
        laborOverridden: true);
    e.addWork(
        sectionTitle: 'T', groupLabel: 'G', items: [auto, manual, erased]);
    e.setLaborRate(0.25);
    expect(auto.laborCost, closeTo(25, 1e-9)); // followed the rate
    expect(manual.laborCost, 55); // hand-priced: untouched
    expect(erased.laborCost, 0); // erased labor stays erased
    e.setLaborRate(0.30);
    expect(auto.laborCost, closeTo(30, 1e-9));
  });

  test('every BOQ/POW grid cell is written with its edge borders', () async {
    final e = EstimateState();
    final c = calcConcrete(volume: 10, concreteClass: 'CLASS A (1:2:4)');
    for (final t in ['CONCRETING WORKS', 'MASONRY WORKS', 'TILING WORKS']) {
      e.addWork(
        sectionTitle: t,
        groupLabel: 'GROUND FLOOR',
        items: c.lines.map((l) => l.toBoqLine()).toList(),
      );
    }
    e.addSummaryRow(); // extra summary row must be bordered like the defaults
    e.addSignatory(Signatory(label: 'Noted by', name: 'A', position: 'B'));

    final zip = ZipDecoder().decodeBytes((await ExcelExport(e).build())!);
    String part(String n) => utf8.decode(
        zip.firstWhere((f) => f.name == n).content as List<int>);

    // border sides per cellXfs index, straight from styles.xml
    final styles = part('xl/styles.xml');
    final borderXml = RegExp(r'<border(?:/>|>(.*?)</border>)', dotAll: true)
        .allMatches(RegExp(r'<borders.*?</borders>', dotAll: true)
            .firstMatch(styles)!
            .group(0)!)
        .map((m) => m.group(1) ?? '')
        .toList();
    bool side(String xml, String s) => RegExp('<$s style="').hasMatch(xml);
    final xfBorder = RegExp(r'<xf\s[^>]*?borderId="(\d+)"')
        .allMatches(RegExp(r'<cellXfs.*?</cellXfs>', dotAll: true)
            .firstMatch(styles)!
            .group(0)!)
        .map((m) => borderXml[int.parse(m.group(1)!)])
        .toList();

    int colNum(String s) =>
        s.codeUnits.fold(0, (a, ch) => a * 26 + ch - 64);
    (int, int) ref(String r) {
      final m = RegExp(r'([A-Z]+)(\d+)').firstMatch(r)!;
      return (colNum(m.group(1)!), int.parse(m.group(2)!));
    }

    void checkSheet(String name, String path, int lastCol, int tableFirst,
        List<(int, int)> blocks) {
      final xml = part(path);
      final cells = <(int, int), String>{};
      for (final m in RegExp(r'<c r="([A-Z]+\d+)"(?: s="(\d+)")?')
          .allMatches(xml)) {
        cells[ref(m.group(1)!)] = xfBorder[int.parse(m.group(2) ?? '0')];
      }
      final merges = RegExp(r'<mergeCell ref="([A-Z]+\d+):([A-Z]+\d+)"')
          .allMatches(xml)
          .map((m) => (ref(m.group(1)!), ref(m.group(2)!)))
          .toList();

      // table extent: contiguous rows whose column-A cell has a left border
      var tableLast = tableFirst;
      while (cells[(1, tableLast + 1)] != null &&
          side(cells[(1, tableLast + 1)]!, 'left')) {
        tableLast++;
      }
      expect(tableLast, greaterThan(tableFirst + 5),
          reason: '$name table extent collapsed — check is vacuous');
      final rows = [...blocks, (tableFirst, tableLast)];

      // covering merge for each cell (c1, r1, c2, r2)
      (int, int, int, int)? coverOf(int c, int r) {
        for (final ((c1, r1), (c2, r2)) in merges) {
          if (c >= c1 && c <= c2 && r >= r1 && r <= r2) {
            return (c1, r1, c2, r2);
          }
        }
        return null;
      }

      for (final (lo, hi) in rows) {
        for (var r = lo; r <= hi; r++) {
          for (var c = 1; c <= lastCol; c++) {
            final b = cells[(c, r)];
            expect(b, isNotNull, reason: '$name $c,$r has no <c> element');
            final m = coverOf(c, r);
            final (c1, r1, c2, r2) = m ?? (c, r, c, r);
            if (r == r1) expect(side(b!, 'top'), isTrue, reason: '$name $c,$r top');
            if (r == r2) expect(side(b!, 'bottom'), isTrue, reason: '$name $c,$r bottom');
            if (c == c1) expect(side(b!, 'left'), isTrue, reason: '$name $c,$r left');
            if (c == c2) expect(side(b!, 'right'), isTrue, reason: '$name $c,$r right');
          }
        }
      }
    }

    checkSheet('BOQ', 'xl/worksheets/sheet1.xml', 9, 25, [(15, 19)]);
    checkSheet('POW', 'xl/worksheets/sheet2.xml', 8, 21, [(13, 17)]);
  });

  test('custom letterhead shifts the whole layout and is written', () async {
    final e = EstimateState();
    e.project.letterhead = ['ACME BUILDERS CO.', 'General Contractors'];
    e.project.letterheadBold = 0;
    final c = calcConcrete(volume: 10, concreteClass: 'CLASS A (1:2:4)');
    e.addWork(
      sectionTitle: 'CONCRETING WORKS',
      groupLabel: 'GF',
      items: c.lines.map((l) => l.toBoqLine()).toList(),
    );

    final zip = ZipDecoder().decodeBytes((await ExcelExport(e).build())!);
    String part(String n) => utf8.decode(
        zip.firstWhere((f) => f.name == n).content as List<int>);
    final boq = part('xl/worksheets/sheet1.xml');
    final pow = part('xl/worksheets/sheet2.xml');
    final shared = part('xl/sharedStrings.xml');

    // 2-line head: BOQ block lands at b0 = 5+2+5 = 12, POW at 6+2+2 = 10
    expect(boq, contains('A12:C12')); // PROJECT TITLE label merge
    expect(boq, contains('A16:C16')); // PHYSICAL TARGET label merge
    expect(shared, contains('PROJECT TITLE:'));
    expect(shared, contains('ACME BUILDERS CO.'));
    expect(shared, contains('General Contractors'));
    expect(boq, contains('A20:I20')); // DETAILED ESTIMATES banner merge
    expect(pow, contains('A10:B10')); // POW label merge
    expect(pow, contains('A14:B14')); // PHYSICAL TARGET label merge
    expect(pow, contains('A16:G16')); // PROGRAM OF WORKS banner merge
    // table headers moved: BOQ hdr = 12+10 = 22, POW hdr = 10+8 = 18
    expect(boq, contains('A22:A23'));
    expect(pow, contains('B18:C19'));
    // ABC back-refs point at the shifted summary (G15 BOQ / G13 POW)
    expect(boq, contains('r="G15"'));
    expect(pow, contains('r="G13"'));
    // POW still references the real BOQ subtotal row (hdr+2+1+lines = 29)
    expect(pow, contains('BOQ!I29'));
    expect(shared, contains('SUB TOTAL:'));
  });

  test('jpeg logo is embedded as image/jpeg', () async {
    final e = EstimateState();
    e.addWork(
        sectionTitle: 'T', groupLabel: 'G', items: [BoqLine(description: 'X')]);
    // minimal JPEG header bytes — only the signature matters for the check
    final jpeg = [0xFF, 0xD8, 0xFF, 0xE0, 0, 0, 0, 0];
    final bytes = await ExcelExport(e).build(logoBytes: jpeg);
    final zip = ZipDecoder().decodeBytes(bytes!);
    final names = zip.files.map((f) => f.name).toSet();
    expect(names, contains('xl/media/logo.jpeg'));
    final ct = utf8.decode(zip.files
        .firstWhere((f) => f.name == '[Content_Types].xml')
        .content as List<int>);
    expect(ct, contains('Extension="jpeg"'));
    expect(ct, contains('image/jpeg'));
  });

  test('project letterhead survives save/load round-trip', () {
    final e = EstimateState();
    e.project.letterhead = ['MY OFFICE', 'Line two'];
    e.project.letterheadBold = 0;
    e.project.logoB64 = 'aGk='; // "hi" — any bytes
    final j = e.toJson();
    final e2 = EstimateState();
    e2.loadJson(Map<String, dynamic>.from(j));
    expect(e2.project.letterhead, ['MY OFFICE', 'Line two']);
    expect(e2.project.letterheadBold, 0);
    expect(e2.project.logoB64, 'aGk=');
    // clearing the logo serializes an explicit null — respected on load
    e.project.logoB64 = null;
    e2.loadJson(Map<String, dynamic>.from(e.toJson()));
    expect(e2.project.logoB64, isNull);
    // legacy files without the keys still get the DepEd letterhead
    final legacy = e.toJson();
    (legacy['project'] as Map).remove('letterhead');
    (legacy['project'] as Map).remove('letterheadBold');
    final e3 = EstimateState();
    e3.loadJson(Map<String, dynamic>.from(legacy));
    expect(e3.project.letterhead, ProjectInfo.defaultLetterhead);
    expect(e3.project.letterheadBold, ProjectInfo.defaultLetterheadBold);
  });

  test('export emits the current labor rate in formulas', () async {
    final e = EstimateState();
    e.laborRate = 0.25;
    e.addWork(
      sectionTitle: 'T',
      groupLabel: 'G',
      items: [
        BoqLine(
            description: 'CEMENT 40kg',
            qty: 2,
            unit: 'bags',
            materialCost: 300,
            laborCost: 75,
            priceKey: 'CEMENT 40kg'),
      ],
    );
    final bytes = await ExcelExport(e).build();
    final xml = utf8.decode(ZipDecoder()
        .decodeBytes(bytes!)
        .firstWhere((f) => f.name == 'xl/worksheets/sheet1.xml')
        .content as List<int>);
    expect(xml, contains('E29*0.25'));
  });
}
