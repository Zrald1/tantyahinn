import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:tantyahin/network_chart.dart';
import 'package:tantyahin/calculators.dart';
import 'package:tantyahin/docx_export.dart';
import 'package:tantyahin/pdf_export.dart';
import 'package:tantyahin/state.dart';
import 'package:flutter_test/flutter_test.dart';

/// Generates real .pdf + .docx artifacts from the same seeded sample
/// as gen_sample_test so they can be opened in real Word/Acrobat for
/// visual verification (plain test() — the chart rasterizer needs the
/// real event loop).
void main() {
  test('generate sample pdf + docx', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final fl = FontLoader('SampleArial')
      ..addFont(Future.value(ByteData.sublistView(File('C:/Windows/Fonts/arial.ttf').readAsBytesSync())));
    await fl.load();
    kChartFontFamily = 'SampleArial';
    est.project.logoB64 = base64Encode(File('assets/deped_logo.png').readAsBytesSync());
    for (final r in [
      calcConcrete(volume: 20, concreteClass: 'CLASS A (1:2:4)'),
      calcMasonry(wallArea: 88, mortarClass: 'CLASS A (1:2)'),
      calcTiles(area: 35.75, tileSize: '0.60 x 0.60'),
      calcPainting(area: 105, systemIndex: 0),
      calcCarpentry(length: 6, width: 18, system: 'ceiling'),
      calcSteel(length: .2, width: .2, height: 5, members: 4),
      calcStairs(totalRise: 2.5, riser: .175, tread: .28, stairWidth: 1.2),
    ]) {
      est.addWork(sectionTitle: r.sectionTitle, groupLabel: 'GROUND FLOOR',
          items: r.lines.map((e) => e.toBoqLine()).toList());
    }
    est.project.title = 'CONSTRUCTION OF SAMPLE BUILDING';
    est.project.location = 'SAN JOSE, PILI, CAMARINES SUR';
    est.project.division = 'CAMARINES SUR';
    est.project.sourceOfFund = 'BASIC EDUCATION FACILITIES FUND';
    est.syncSchedule(force: true);
    final pdf = await PdfExport(est).build();
    File('sample_estimate.pdf').writeAsBytesSync(pdf);
    final docx = await DocxExport.buildEstimate();
    File('sample_estimate.docx').writeAsBytesSync(docx);
    print('pdf=${pdf.length} docx=${docx.length}');
    est.sections.clear();
    est.activities.clear();
  });
}
