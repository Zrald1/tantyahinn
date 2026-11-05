import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:tantyahin/model3d.dart';
import 'package:tantyahin/render.dart';
import 'package:tantyahin/ui/model_view.dart';

/// Ray-traced still render, headless: loads the user's REAL project
/// model from the rolling autosave (falls back to a small furnished
/// room), runs the draft-quality ISO render, writes the PNG to
/// test/out/render_iso.png and asserts the frame actually contains
/// shaded geometry (luma variance) - not a flat sky or an empty pass.
void main() {
  setUpAll(() async {
    await preloadBlockMeshes((p) => File(p).readAsString());
  });

  test(
    'ray-traced ISO render of the project model produces a varied PNG',
    () async {
      final m = _projectModel();
      final faces = m.cachedFaces();
      expect(faces, isNotEmpty, reason: 'model has no renderable faces');
      final job = renderJobForModel(
        m,
        yaw: -0.7,
        pitch: 0.55,
        width: 320,
        height: 240,
        quality: RenderQuality.draft,
      );
      expect(job.triIdx.length, greaterThan(0));
      var progressCalls = 0;
      final png = await renderPng(
        job,
        onProgress: (_) => progressCalls++,
      );
      expect(png, isNotEmpty);
      expect(progressCalls, greaterThan(0));
      Directory('test/out').createSync(recursive: true);
      File('test/out/render_iso.png').writeAsBytesSync(png);

      final im = img.decodePng(png);
      expect(im, isNotNull, reason: 'renderPng output did not decode');
      // pixel variance: a flat sky / failed frame has near-zero spread;
      // real geometry produces strong lit-vs-shadow contrast
      var sum = 0.0, sum2 = 0.0, n = 0;
      for (final p in im!) {
        final l = 0.299 * p.r + 0.587 * p.g + 0.114 * p.b;
        sum += l;
        sum2 += l * l;
        n++;
      }
      final mean = sum / n;
      final stdev = math.sqrt(math.max(0.0, sum2 / n - mean * mean));
      // ignore: avoid_print
      print(
        'render_iso.png ${im.width}x${im.height} '
        'mean=${mean.toStringAsFixed(1)} '
        'stdev=${stdev.toStringAsFixed(1)} faces=${faces.length} '
        'tris=${job.triIdx.length ~/ 3}',
      );
      expect(
        stdev,
        greaterThan(6.0),
        reason: 'render looks flat/empty - geometry never reached it',
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

/// First model found in %APPDATA%\ConstructionEstimate\autosave.boqproj
/// (same path EstimateState.autosaveFile uses), else a small furnished
/// room so the renderer check still exercises real mesh geometry.
Model3d _projectModel() {
  try {
    final f = File(
      '${Platform.environment['APPDATA'] ?? Directory.systemTemp.path}'
      '${Platform.pathSeparator}ConstructionEstimate'
      '${Platform.pathSeparator}autosave.boqproj',
    );
    if (f.existsSync()) {
      final j = jsonDecode(f.readAsStringSync());
      final models = (j is Map ? j['models'] : null) as List? ?? const [];
      for (final e in models) {
        final m = Model3d.fromJson(Map<String, dynamic>.from(e as Map));
        if (m.bounds != null) return m;
      }
    }
  } catch (_) {}
  return Model3d(name: 'render-test')
    ..walls.addAll([
      Wall3d(points: [0, 0, 6, 0], thickness: 0.15),
      Wall3d(points: [6, 0, 6, 4], thickness: 0.15),
      Wall3d(points: [6, 4, 0, 4], thickness: 0.15),
      Wall3d(points: [0, 4, 0, 0], thickness: 0.15),
    ])
    ..blocks.addAll([
      Block3d(def: 'door-090', x: 3, y: 0, rot: 0),
      Block3d(def: 'window-120', x: 4.5, y: 4, rot: math.pi),
      Block3d(def: 'dining-6', x: 3, y: 2),
    ]);
}
