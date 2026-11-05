import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:tantyahin/ai_render.dart';
import 'package:tantyahin/model3d.dart';
import 'package:tantyahin/render.dart';
import 'package:tantyahin/ui/model_view.dart';

void main() {
  setUpAll(() async {
    await preloadBlockMeshes((p) => File(p).readAsString());
  });
  test('vision style: spark sees a draft preview of the model', () async {
    Model3d? m;
    try {
      final f = File(
        '${Platform.environment['APPDATA']}/ConstructionEstimate/autosave.boqproj',
      );
      final j = jsonDecode(f.readAsStringSync());
      for (final e in (j['models'] as List)) {
        final t = Model3d.fromJson(Map<String, dynamic>.from(e as Map));
        if (t.bounds != null) { m = t; break; }
      }
    } catch (_) {}
    m ??= Model3d(name: 't')
      ..walls.add(Wall3d(points: [0, 0, 4, 0], thickness: 0.15));
    final png = await renderPng(renderJobForModel(
      m, yaw: -0.7, pitch: 0.55,
      width: 480, height: 360, quality: RenderQuality.draft,
    ));
    expect(png, isNotEmpty);
    final kf = File(
      '${Platform.environment['APPDATA']}/ConstructionEstimate/muse_key.txt',
    );
    if (!kf.existsSync()) return;
    final s = await museExpandStyle(
      '', apiKey: kf.readAsStringSync().trim(),
      envLabel: 'Field', imagePng: png,
    );
    // ignore: avoid_print
    print('VISION STYLE -> $s');
    expect(s.length, greaterThan(20));
  }, timeout: const Timeout(Duration(minutes: 3)));
}
