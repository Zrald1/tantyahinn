import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tantyahin/calculators.dart';
import 'package:tantyahin/export_package.dart';
import 'package:tantyahin/model3d.dart';
import 'package:tantyahin/models.dart';
import 'package:tantyahin/pdf_export.dart';
import 'package:tantyahin/state.dart';

EstimateState _est() {
  final est = EstimateState();
  final r = calcConcrete(volume: 10, concreteClass: 'CLASS A (1:2:4)');
  est.addWork(
    sectionTitle: r.sectionTitle,
    groupLabel: 'GROUND FLOOR',
    items: r.lines.map((e) => e.toBoqLine()).toList(),
  );
  return est;
}

/// A real PNG via the same PictureRecorder path the exports use —
/// stands in for an AI render saved into the drawings library.
Future<Uint8List> _png() async {
  final rec = ui.PictureRecorder();
  final c = Canvas(rec, const Rect.fromLTWH(0, 0, 64, 48));
  c.drawRect(
    const Rect.fromLTWH(0, 0, 64, 48),
    Paint()..color = Colors.blue,
  );
  final img = await rec.endRecording().toImage(64, 48);
  final bd = await img.toByteData(format: ui.ImageByteFormat.png);
  return bd!.buffer.asUint8List();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<File> _sheetFile(EstimateState est, Directory dir) async {
    final m = est.addModel('TESTHOUSE');
    m.walls.add(Wall3d(points: [0, 0, 4, 0, 4, 3, 0, 3, 0, 0]));
    return File('${dir.path}/sheet.dxf')
      ..writeAsStringSync(
        buildModelSheet(m, SheetView.plan, project: est.project),
      );
  }

  test('PDF appendix embeds generated sheets + render, skips missing',
      () async {
    final est = _est();
    final dir = Directory.systemTemp.createTempSync('exp_pdf');

    // baseline: no drawings -> page/image counts to compare against
    // (pdf serializes '/Subtype/Image' with no space)
    est.project.template = 'private';
    final base = await PdfExport(est).build();
    final baseText = latin1.decode(base);
    final basePages =
        RegExp('/Type/Page[^s]').allMatches(baseText).length;
    final baseImages =
        RegExp('/Subtype/Image').allMatches(baseText).length;

    est.drawings
      ..add(
        DrawingFile(
          path: (await _sheetFile(est, dir)).path,
          name: 'Model 1 - FLOOR PLAN.dxf',
          kind: 'dxf',
        ),
      )
      ..add(
        DrawingFile(
          path: (File('${dir.path}/render.png')
                ..writeAsBytesSync(await _png()))
              .path,
          name: 'AI RENDER.png',
          kind: 'image',
        ),
      )
      ..add(
        DrawingFile(
          path: '${dir.path}/gone.dxf',
          name: 'MISSING.dxf',
          kind: 'dxf',
        ),
      );

    final pdf = await PdfExport(est).build();
    final text = latin1.decode(pdf);
    expect(
      RegExp('/Subtype/Image').allMatches(text).length,
      greaterThan(baseImages),
    );
    expect(
      RegExp('/Type/Page[^s]').allMatches(text).length,
      basePages + 2, // two readable drawings, missing skipped
    );
  });

  test('complete package zip carries workbook, pdf, project, drawings',
      () async {
    final est = _est();
    est.project.title = 'PKG TEST';
    final dir = Directory.systemTemp.createTempSync('exp_zip');
    est.drawings
      ..add(
        DrawingFile(
          path: (await _sheetFile(est, dir)).path,
          name: 'plan.dxf',
          kind: 'dxf',
        ),
      )
      ..add(
        DrawingFile(
          path: (File('${dir.path}/r.png')..writeAsBytesSync(await _png()))
              .path,
          name: 'render.png',
          kind: 'image',
        ),
      )
      ..add(
        DrawingFile(
          path: '${dir.path}/nope.png',
          name: 'nope.png',
          kind: 'image',
        ),
      );

    final zip = await ExportPackage.buildZip(est);
    expect(zip[0], 0x50); // PK
    final arc = ZipDecoder().decodeBytes(zip);
    final names = arc.files.map((f) => f.name).toSet();
    expect(names, contains('estimate.xlsx'));
    expect(names, contains('estimate.pdf'));
    expect(names, contains('project.boqproj'));
    expect(names, contains('drawings/plan.dxf'));
    expect(names, contains('drawings/render.png'));
    expect(names, isNot(contains('drawings/nope.png')));

    // editable artifacts intact inside the bundle
    final xlsx = arc.findFile('estimate.xlsx')!;
    expect(xlsx.size, greaterThan(5000));
    expect(xlsx.content[0], 0x50); // inner xlsx is itself a zip
    final pdf = arc.findFile('estimate.pdf')!;
    expect(
      String.fromCharCodes((pdf.content as List<int>).sublist(0, 5)),
      '%PDF-',
    );
    final proj = jsonDecode(
      utf8.decode(arc.findFile('project.boqproj')!.content as List<int>),
    );
    expect(proj['project']['title'], 'PKG TEST');
    final dxf = utf8.decode(
      arc.findFile('drawings/plan.dxf')!.content as List<int>,
    );
    expect(dxf, contains('EOF'));
  });


}
