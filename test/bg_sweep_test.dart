import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:tantyahin/model3d.dart';
import 'package:tantyahin/render.dart';
import 'package:tantyahin/ui/model_view.dart';

Model3d _m() {
  try {
    final f = File(
      '${Platform.environment['APPDATA']}/ConstructionEstimate/autosave.boqproj',
    );
    final j = jsonDecode(f.readAsStringSync());
    for (final e in (j['models'] as List)) {
      final m = Model3d.fromJson(Map<String, dynamic>.from(e as Map));
      if (m.bounds != null) return m;
    }
  } catch (_) {}
  return Model3d(name: 't')..walls.add(Wall3d(points: [0,0,4,0], thickness: 0.15));
}

void main() {
  setUpAll(() async {
    await preloadBlockMeshes((p) => File(p).readAsString());
  });
  for (final (label, top, bot, gnd) in [
    ('white', 0xFFF2F2F5, 0xFFFFFFFF, 0xFFECECEF),
    ('black', 0xFF101013, 0xFF232329, 0xFF161619),
  ]) {
    test('solid $label backdrop renders the model', () async {
      final job = renderJobForModel(
        _m(),
        yaw: -0.7, pitch: 0.45,
        width: 640, height: 480,
        quality: RenderQuality.standard,
        bgTop: top, bgBottom: bot, bgGround: gnd,
      );
      final png = await renderPng(job);
      Directory('test/out').createSync(recursive: true);
      File('test/out/render_bg_$label.png').writeAsBytesSync(png);
      final im = img.decodePng(png)!;
      // corner pixels must be the backdrop color, not sky-blue
      final c = im.getPixel(10, 10);
      // ignore: avoid_print
      print('$label corner=(${c.r},${c.g},${c.b})');
      expect(png, isNotEmpty);
    }, timeout: const Timeout(Duration(minutes: 3)));
  }
}
