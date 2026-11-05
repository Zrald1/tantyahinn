import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:tantyahin/ai_render.dart';
import 'package:tantyahin/model3d.dart';
import 'package:tantyahin/render.dart';
import 'package:tantyahin/ui/model_view.dart';

/// Live: eye-level plate -> best-of-2 vision-judged AI enhance on the
/// user's real model. Skips without a saved key.
void main() {
  setUpAll(() async {
    await preloadBlockMeshes((p) => File(p).readAsString());
  });
  test('pro AI pipeline on the real model', () async {
    final kf = File(
        '${Platform.environment['APPDATA']}/ConstructionEstimate/muse_key.txt');
    if (!kf.existsSync()) return;
    Model3d? m;
    final f = File(
        '${Platform.environment['APPDATA']}/ConstructionEstimate/autosave.boqproj');
    final j = jsonDecode(f.readAsStringSync());
    for (final e in (j['models'] as List)) {
      final t = Model3d.fromJson(Map<String, dynamic>.from(e as Map));
      if (t.bounds != null) { m = t; break; }
    }
    final png = await renderPng(renderJobForModel(m!,
        yaw: -0.6, pitch: 0.1, width: 1280, height: 720,
        quality: RenderQuality.standard));
    Directory('test/out').createSync(recursive: true);
    File('test/out/ai_plate.png').writeAsBytesSync(png);
    final stages = <String>[];
    final out = await museEnhanceBest(png,
        apiKey: kf.readAsStringSync().trim(),
        prompt: 'sunny afternoon, lush landscaping',
        onStage: stages.add);
    File('test/out/ai_best.png').writeAsBytesSync(out);
    // ignore: avoid_print
    print('stages=$stages bytes=${out.length}');
    expect(out.length, greaterThan(10000));
  }, timeout: const Timeout(Duration(minutes: 8)));
}
