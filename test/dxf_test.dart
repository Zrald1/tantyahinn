import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:tantyahin/dxf.dart';
import 'package:tantyahin/dwg.dart';
import 'package:tantyahin/models.dart';
import 'package:tantyahin/state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('dxf parser reads entities, layers, colors and expands INSERT',
      () async {
    final src =
        await File('tool/fixtures/plan.dxf').readAsString();
    final sc = DxfParser.parse(src);
    // 4 walls + lwpolyline(2 segs + bulge pts) + circle + arc +
    // polyline + INSERT(block: line + arc)
    expect(sc.prims.length, greaterThanOrEqualTo(10));
    expect(sc.texts.single.text, 'ASDS OFFICE PLAN');
    // bounds cover the 6000x4000 room plus margins
    expect(sc.bounds.width, greaterThan(5900));
    expect(sc.bounds.height, greaterThan(3900));
    // WALLS layer is ACI 5 (blue), DIMS is 1 (red)
    final blues =
        sc.prims.where((p) => p.color == 0xFF0000FF).length;
    final reds =
        sc.prims.where((p) => p.color == 0xFFFF0000).length;
    expect(blues, greaterThanOrEqualTo(5)); // walls + closed polyline
    expect(reds, greaterThanOrEqualTo(3)); // lwpolyline+circle+arc
    // bulge arc adds interior points between the lwpolyline's 3 vertices
    final bulge = sc.prims.firstWhere(
        (p) => p.pts.length > 6 && !p.closed && p.color == 0xFFFF0000);
    expect(bulge.pts.length, greaterThan(5));
  });

  test('dxf parser throws on empty / junk input', () {
    expect(() => DxfParser.parse('not a dxf'),
        throwsA(isA<DxfParseException>()));
  });

  test('dxf painter renders non-blank pixels', () async {
    final src =
        await File('tool/fixtures/plan.dxf').readAsString();
    final sc = DxfParser.parse(src);
    final size = sc.naturalSize();
    final scale = size.width / sc.bounds.width;
    final rec = PictureRecorder();
    final canvas = Canvas(rec);
    canvas.drawRect(
        Offset.zero & size, Paint()..color = const Color(0xFFFFFFFF));
    DxfPainter(sc, scale).paint(canvas, size);
    final img =
        await rec.endRecording().toImage(size.width.round(), size.height.round());
    final bd = await img.toByteData(format: ImageByteFormat.rawRgba);
    var dark = 0;
    final px = bd!.buffer.asUint32List();
    for (final p in px) {
      if ((p & 0xFFFFFF) != 0xFFFFFF && (p & 0xFFFFFF) != 0x00FFFFFF) {
        dark++;
      }
    }
    expect(dark, greaterThan(500)); // the plan drew actual lines
  });

  test('drawings & marks round-trip through project json', () {
    est.drawings.clear();
    est.marks.clear();
    final f = est.addDrawing(r'C:\plans\floor1.dxf', 'dxf');
    est.addMark(DrawingMark(
        fileId: f.id,
        page: 0,
        kind: 'pen',
        pts: [0.1, 0.2, 0.5, 0.8],
        color: 0xFF1976D2,
        width: 4));
    est.addMark(DrawingMark(
        fileId: f.id,
        kind: 'text',
        pts: [0.3, 0.4],
        text: 'check this wall'));
    final j = est.toJson();
    est.loadJson(j);
    expect(est.drawings.single.name, 'floor1.dxf');
    expect(est.drawings.single.kind, 'dxf');
    expect(est.marks.length, 2);
    expect(est.marksFor(est.drawings.single.id, 0).first.kind, 'pen');
    expect(est.marks.last.text, 'check this wall');
    // undo pops the newest mark on that page
    expect(est.undoMark(est.drawings.single.id, 0), isTrue);
    expect(est.marks.length, 1);
    // removing the file drops its marks too
    est.removeDrawing(est.drawings.single);
    expect(est.marks, isEmpty);
    est.drawings.clear();
  });

  test('DwgReader converts real AutoCAD DWGs the parser can draw',
      () async {
    final root = Directory.current.absolute.path;
    for (final v in ['2000', '2018']) {
      final outDir = Directory(
          '${Directory.systemTemp.path}/ce_test_dwgreader_$v');
      final r = await DwgReader.open(
          '$root/tool/fixtures/sample_$v.dwg', outDir);
      expect(r.scene.prims.length, greaterThanOrEqualTo(5), reason: v);
      expect(r.scene.texts.length, 1, reason: v);
      expect(r.scene.bounds.width, greaterThan(0), reason: v);
      // Second open on an unchanged file must hit the cache, not
      // re-run the converter.
      final r2 = await DwgReader.open(
          '$root/tool/fixtures/sample_$v.dwg', outDir);
      expect(r2.engine, 'cached');
    }
  });

  test('mleaders use entity-level text height and 3-point leaders',
      () {
    // Real MULTILEADER shape from the floorplan fixture: context 41 is
    // scaled-space (0.085) while the entity 41 after 301 is the true
    // height; LEADER{ 10/20 } carries the object-side connection point.
    final src = '0\nSECTION\n2\nENTITIES\n0\nMULTILEADER\n'
        '8\n0\n270\n2\n300\nCONTEXT_DATA{\n40\n1.0\n'
        '10\n100.0\n20\n50.0\n30\n0.0\n41\n0.085\n'
        '304\nCallout text\n302\nLEADER{\n10\n95.0\n20\n48.0\n30\n0.0\n'
        '304\nLEADER_LINE{\n10\n96.0\n20\n49.0\n30\n0.0\n305\n}\n'
        '303\n}\n301\n}\n41\n0.36\n'
        '0\nENDSEC\n0\nEOF\n';
    final scene = DxfParser.parse(src);
    final t = scene.texts.singleWhere((x) => x.text == 'Callout text');
    expect(t.height, closeTo(0.36, 0.01));
    // leader polyline conn -> line -> text
    expect(
        scene.prims.any((p) => p.pts.length == 3 &&
            (p.pts.first - const Offset(95, 48)).distance < 0.01 &&
            (p.pts.last - const Offset(100, 50)).distance < 0.01),
        isTrue);
  });

  test('parser draws hatches, dimensions and mleaders from a real plan',
      () {
    // floorplan.dxf = dwg2dxf output for a PDF-imported architectural
    // plan: SOLID wall hatches, *D dimension blocks, MULTILEADER notes.
    final f = File('${Directory.current.absolute.path}/tool/fixtures/floorplan.dxf');
    if (!f.existsSync()) return; // fixture only exists where generated
    final scene = DxfParser.parse(
        utf8.decode(f.readAsBytesSync(), allowMalformed: true));
    final fills = scene.prims.where((p) => p.fillLoops != null).length;
    expect(fills, greaterThan(300)); // ~426 solid wall hatches
    expect(scene.texts.length, greaterThan(20)); // dim text + mleaders
    expect(scene.prims.length, greaterThan(2000));
  });

  test('hatch fill loops become even-odd holes', () {
    final src = '0\nSECTION\n2\nENTITIES\n0\nHATCH\n'
        '8\n0\n100\nAcDbHatch\n10\n0.0\n20\n0.0\n30\n0.0\n'
        '210\n0.0\n220\n0.0\n230\n1.0\n2\nSOLID\n70\n1\n71\n0\n'
        '91\n1\n92\n3\n72\n0\n73\n1\n93\n4\n'
        '10\n0.0\n20\n0.0\n10\n10.0\n20\n0.0\n'
        '10\n10.0\n20\n10.0\n10\n0.0\n20\n10.0\n'
        '97\n0\n75\n0\n76\n1\n98\n0\n0\nENDSEC\n0\nEOF\n';
    final scene = DxfParser.parse(src);
    final fill = scene.prims.singleWhere((p) => p.fillLoops != null);
    expect(fill.fillLoops!.single.length, greaterThanOrEqualTo(4));
  });
}
