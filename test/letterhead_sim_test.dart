import 'dart:convert';
import 'dart:io';

import 'package:tantyahin/calculators.dart';
import 'package:tantyahin/excel_export.dart';
import 'package:tantyahin/state.dart';
import 'package:flutter_test/flutter_test.dart';

// End-to-end simulation of a DIFFERENT government agency: a 3-line custom
// letterhead (with emphasis on a middle line) + a real 64x64 PNG logo,
// exported to a real xlsx in the system temp dir. Verified afterwards with
// tool/verify_xlsx_borders.py and a real-Excel render via tool/render_xlsx.py.
void main() {
  // 64x64 valid PNG (blue roundel) — small enough to embed.
  const pngB64 =
      'iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAIAAAAlC+aJAAABEUlEQVR4nO2ayw1DI'
      'QwEXUnKSXWpM+d0kBQQCfyDXYwljk/sDCD0wMjj+Tq6CZygBdAELZDX1/vz1TciAR'
      'N3uokA0VM0nAImsqUaHoE4QaKDTSB9AcQ7NAis20wiPWsF1u2DwQghoXcHCQ+9L06o'
      '6B2hNoEN9NZcIaQ3pQsnvZ5BJQChV2II7fArSeYCQHoNjDAPv4ZnIgCnnyKVE2BbP1'
      'OqkQCcWwPWAi3QAlUF4MQDhztmoAVaoAXOFzjyb5RzEm460FQ4E7NNwhim6L0QzyRM'
      'MerejcIdlOml6wMVKjTH18g2OziC7qgTV6jUV3grUeG1iobgH8j08SYBq8YK9ASBFI'
      '1ger9aRLcWQDeBEwQFfjbH2+6kW2s3AAAAAElFTkSuQmCC';

  test('custom agency letterhead + custom logo export', () async {
    final e = EstimateState();
    e.project.letterhead = [
      'DEPARTMENT OF PUBLIC WORKS AND HIGHWAYS',
      'CAMARINES SUR 3RD DISTRICT ENGINEERING OFFICE',
      'Legazpi City',
    ];
    e.project.letterheadBold = 1;
    e.project.logoB64 = pngB64;
    e.project.title = 'REHABILITATION OF DISTRICT OFFICE';

    final c = calcConcrete(volume: 10, concreteClass: 'CLASS A (1:2:4)');
    e.addWork(
        sectionTitle: c.sectionTitle,
        groupLabel: 'GROUND FLOOR',
        items: c.lines.map((l) => l.toBoqLine()).toList());
    final m = calcMasonry(wallArea: 50, mortarClass: 'CLASS A (1:2)');
    e.addWork(
        sectionTitle: m.sectionTitle,
        groupLabel: '',
        items: m.lines.map((l) => l.toBoqLine()).toList());

    final bytes = (await ExcelExport(e)
        .build(logoBytes: base64Decode(e.project.logoB64!)))!;
    final out = File(
        '${Directory.systemTemp.path}${Platform.pathSeparator}custom_letterhead.xlsx');
    out.writeAsBytesSync(bytes);
    print('wrote ${out.path} (${bytes.length} bytes)');
    expect(bytes.length, greaterThan(1000));
  });
}
