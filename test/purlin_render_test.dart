import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:tantyahin/model3d.dart';
import 'package:tantyahin/render.dart';
import 'package:tantyahin/ui/model_view.dart';

/// Visual check: render a roof field (2 trusses on walls) and count
/// galvanized-steel pixels — proves the C-purlin channels reached the
/// frame at the right height/shape. PNG saved for eyeball review.
void main() {
  setUpAll(() async {
    await preloadBlockMeshes((p) => File(p).readAsString());
  });

  test('purlin channels render as steel over the truss top chords',
      () async {
    final m = Model3d(name: 'roof');
    m.walls.add(Wall3d(points: [0, 0, 5, 0], thickness: .15, height: 2.7));
    m.walls.add(Wall3d(points: [0, 4, 5, 4], thickness: .15, height: 2.7));
    for (var i = 0; i < 3; i++) {
      m.blocks.add(
        Block3d(def: 'truss', x: 1.0 + i * 1.5, y: 2.0, rot: math.pi / 2, bz: 2.7),
      );
    }
    final job = renderJobForModel(
      m,
      yaw: -0.9,
      pitch: 0.35,
      width: 400,
      height: 300,
      quality: RenderQuality.draft,
    );
    final png = await renderPng(job);
    Directory('test/out').createSync(recursive: true);
    File('test/out/purlin_iso.png').writeAsBytesSync(png);
    // gable-end view: looking down the ridge shows channel sections
    final gable = renderJobForModel(
      m,
      yaw: 0.0,
      pitch: 0.12,
      width: 400,
      height: 300,
      quality: RenderQuality.draft,
    );
    File('test/out/purlin_gable.png')
        .writeAsBytesSync(await renderPng(gable));
    final im = img.decodePng(png)!;
    // galvanized channel color 0xB0BEC5 -> count pixels near it
    var steel = 0;
    for (final p in im) {
      if ((p.r - 0xB0).abs() < 40 &&
          (p.g - 0xBE).abs() < 40 &&
          (p.b - 0xC5).abs() < 40) {
        steel++;
      }
    }
    // ignore: avoid_print
    print('purlin_iso.png steel px=$steel runs=${purlinRuns(m).length}');
    expect(steel, greaterThan(200), reason: 'no C-purlin pixels rendered');
  });

  test('split fields keep purlins on their own roofs (user bug)',
      () async {
    // the screenshot scenario: two truss clusters on different wings
    // at the same rot — merged fields laid purlin bars across the gap
    // and through the walls
    final m = Model3d(name: 'wings');
    m.walls.add(Wall3d(points: [0, 0, 4, 0], thickness: .15, height: 2.7));
    m.walls.add(Wall3d(points: [0, 4, 4, 4], thickness: .15, height: 2.7));
    m.walls.add(Wall3d(points: [9, 0, 13, 0], thickness: .15, height: 2.7));
    m.walls.add(Wall3d(points: [9, 4, 13, 4], thickness: .15, height: 2.7));
    for (var i = 0; i < 3; i++) {
      m.blocks.add(
        Block3d(
            def: 'truss', x: 0.8 + i * 1.5, y: 2.0, rot: math.pi / 2, bz: 2.7),
      );
      m.blocks.add(
        Block3d(
            def: 'truss', x: 9.8 + i * 1.5, y: 2.0, rot: math.pi / 2, bz: 2.7),
      );
    }
    expect(roofFields(m), hasLength(2));
    final job = renderJobForModel(
      m,
      yaw: -0.9,
      pitch: 0.42,
      width: 460,
      height: 320,
      quality: RenderQuality.draft,
    );
    File('test/out/purlin_split.png')
        .writeAsBytesSync(await renderPng(job));
    // no purlin vertex may sit in the 5m air gap between the wings
    for (final run in purlinRuns(m)) {
      for (final f in run) {
        for (final p in f.v) {
          expect(p[0] > 4.4 && p[0] < 8.6, isFalse);
        }
      }
    }
  });

  test('single king-post vs fink truss side by side', () async {
    final m = Model3d(name: 'both');
    m.blocks.add(Block3d(def: 'truss', x: 0, y: 0, bz: 0));
    m.blocks.add(Block3d(def: 'truss-sgl', x: 0, y: 2.0, bz: 0));
    File('test/out/truss_variants.png').writeAsBytesSync(
      await renderPng(
        renderJobForModel(
          m,
          yaw: -1.2,
          pitch: 0.3,
          width: 460,
          height: 300,
          quality: RenderQuality.draft,
        ),
      ),
    );
    // single truss = strictly fewer member faces than the fink
    final sgl = blockFaces(
      Block3d(def: 'truss-sgl', x: 0, y: 0),
      cadBlock('truss-sgl')!,
    ).length;
    final fink = blockFaces(
      Block3d(def: 'truss', x: 0, y: 0),
      cadBlock('truss')!,
    ).length;
    expect(sgl, lessThan(fink));
  });

  test('USER MODEL: load the real autosave, render what they see',
      () async {
    final f = File(
      r'C:\Users\Zrald\AppData\Roaming\ConstructionEstimate\autosave.boqproj',
    );
    if (!f.existsSync()) return;
    final j = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
    final mj = (j['models'] as List).first as Map<String, dynamic>;
    final m = Model3d.fromJson(mj);
    // report the field/purlin state of their actual model
    final fields = roofFields(m);
    final runs = purlinRuns(m);
    // ignore: avoid_print
    print(
      'user model: trusses=${m.blocks.where((b) => isTrussDef(b.def)).length} '
      'fields=${fields.length} purlinRuns=${runs.length}',
    );
    for (final fl in fields) {
      // ignore: avoid_print
      print(
        '  field: n=${fl.count} ridge=(${fl.ridge.dx.toStringAsFixed(2)},'
        '${fl.ridge.dy.toStringAsFixed(2)}) runLen=${fl.runLen.toStringAsFixed(1)}',
      );
    }
    for (final b in m.blocks) {
      if (!isTrussDef(b.def)) continue;
      // ignore: avoid_print
      print(
        '  truss ${b.def} pos=(${b.x.toStringAsFixed(2)},'
        '${b.y.toStringAsFixed(2)}) rot=${b.rot.toStringAsFixed(2)} '
        'bz=${b.bz.toStringAsFixed(2)} inRoof=${trussInRoof(m, b)}',
      );
    }
    // probe: can each truss reach a span at the dominant rot?
    for (final b in m.blocks) {
      if (!isTrussDef(b.def)) continue;
      final def = cadBlock(b.def)!;
      final s = seatTrussOnWalls(
        m,
        Offset(b.x, b.y),
        1.571,
        def.w * b.sx * b.scale,
        tol: 4.0,
        ignore: b,
        requireSpan: true,
      );
      // ignore: avoid_print
      print(
        '  probe (${b.x.toStringAsFixed(1)},${b.y.toStringAsFixed(1)})'
        ' -> ${s == null ? 'null' : '(${s.$1.dx.toStringAsFixed(2)},'
            '${s.$1.dy.toStringAsFixed(2)}) rot=${s.$2.toStringAsFixed(2)} '
            'top=${s.$3.toStringAsFixed(1)}'}',
      );
    }
    File('test/out/user_model_iso.png').writeAsBytesSync(
      await renderPng(
        renderJobForModel(
          m,
          yaw: -0.9,
          pitch: 0.4,
          width: 560,
          height: 420,
          quality: RenderQuality.draft,
        ),
      ),
    );
  });

  test('close-up: each variant alone, matching the user zoom', () async {
    for (final (def, nm) in [('truss', 'zoom_fink'), ('truss-sgl', 'zoom_sgl')]) {
      final m = Model3d(name: nm);
      m.blocks.add(Block3d(def: def, x: 0, y: 0, bz: 0));
      File('test/out/$nm.png').writeAsBytesSync(
        await renderPng(
          renderJobForModel(
            m,
            yaw: 0, // face-on: rot=0 truss lies in the XZ plane
            pitch: 0.12,
            width: 520,
            height: 340,
            quality: RenderQuality.draft,
          ),
        ),
      );
    }
    // the ORIGINAL SketchUp import for comparison — is it single or double?
    final mesh = blockMeshes['truss'];
    // ignore: avoid_print
    print('wh_truss mesh faces=${mesh?.length}');
    if (mesh != null) {
      blockMeshes['wh-raw'] = mesh;
      blockMeshTop['wh-raw'] = 0.8;
      customCadBlocks.add(
        CadBlock('wh-raw', 'raw wh_truss', 'Site', 3.97, 0.18, 0.8, const []),
      );
      final m2 = Model3d(name: 'obj')
        ..blocks.add(Block3d(def: 'wh-raw', x: 0, y: 0));
      File('test/out/zoom_obj.png').writeAsBytesSync(
        await renderPng(
          renderJobForModel(
            m2,
            yaw: 0,
            pitch: 0.12,
            width: 520,
            height: 340,
            quality: RenderQuality.draft,
          ),
        ),
      );
    }
  });
}
