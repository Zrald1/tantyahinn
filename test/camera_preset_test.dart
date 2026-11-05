// Camera preset + composited ground-shadow regressions (UNRUN per
// the user's manual-testing request):
//  - TOP is a true straight-down view: z-invariant, +X right/+Y up.
//  - Every preset re-fits the SELECTED model only (off-origin work
//    can't vanish, other models never widen the frame).
//  - paintGroundShadow unions projections: stacking identical faces
//    cannot darken past the single shadow tint, and the floor clip
//    keeps outside pixels untouched.
//  - TOP->ISO keeps the stored render flag.
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tantyahin/model3d.dart';
import 'package:tantyahin/state.dart';
import 'package:tantyahin/ui/model_view.dart';

void main() {
  const vp = Size(640, 480);

  test('TOP preset is true straight-down: z-invariant, axis aligned', () {
    Offset p(List<double> v) =>
        cam3Project(v, vp, yaw: 0.0, pitch: math.pi / 2, zoom: 20, off: Offset.zero);
    // same x/y at different z lands on the same pixel (cos(pi/2) is a
    // floating residual, so compare distance, not equality)
    expect((p([2, 3, 0]) - p([2, 3, 9])).distance, lessThan(1e-9));
    // +X goes right, +Y goes up (screen y decreases), matching plan
    expect(p([1, 0, 0]).dx, greaterThan(p([-1, 0, 0]).dx));
    expect(p([0, 1, 0]).dy, lessThan(p([0, -1, 0]).dy));
  });

  Future<ui.Image> shadowImage(List<Face3> faces, Path floor) async {
    final rec = ui.PictureRecorder();
    final c = Canvas(rec);
    paintGroundShadow(
      c,
      faces: faces,
      groundZ: 0.0,
      floorPath: floor,
      project: (v) => Offset(v[0] * 20 + 100, v[1] * 20 + 100),
    );
    return rec.endRecording().toImage(200, 200);
  }

  Future<int> px(ui.Image img, int x, int y) async {
    final bd = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
    return bd!.getUint32((y * img.width + x) * 4);
  }

  int alphaOf(int pixel) => pixel & 0xff;

  test('stacked faces cannot darken past the single shadow tint', () async {
    final floor = Path()
      ..addRect(const Rect.fromLTWH(10, 10, 180, 180));
    final quad = Face3(
      [[1, 1, 0], [4, 1, 0], [4, 4, 3], [1, 4, 3]],
      const [0, 0, 1],
      0xFF888888,
      0,
    );
    final one = await shadowImage([quad], floor);
    final many = await shadowImage([quad, quad, quad, quad], floor);
    // (140,150) sits inside this quad's sun-projected polygon
    final single = alphaOf(await px(one, 140, 150));
    expect(single, 0x26); // the single composited tint, nonzero
    expect(alphaOf(await px(many, 140, 150)), single);
    one.dispose();
    many.dispose();
  });

  test('shadow never lands outside the floor clip', () async {
    final floor = Path()
      ..addRect(const Rect.fromLTWH(100, 100, 90, 90));
    final tall = Face3(
      [[-5, -5, 0], [5, -5, 0], [5, 5, 8], [-5, 5, 8]],
      const [0, 0, 1],
      0xFF888888,
      0,
    );
    final img = await shadowImage([tall], floor);
    // (120,120) is inside the projected trapezoid AND the floor rect
    expect(alphaOf(await px(img, 120, 120)), 0x26);
    expect(await px(img, 20, 20), 0); // outside floor: untouched
    img.dispose();
  });

  Widget app() => const MaterialApp(home: Scaffold(body: ModelView()));

  testWidgets(
    'all presets re-fit the SELECTED model only (off-origin + faraway second)',
    (t) async {
      await t.binding.setSurfaceSize(const Size(1600, 900));
      addTearDown(() => t.binding.setSurfaceSize(null));
      est.models.clear();
      final far = Model3d()..name = 'far';
      far.walls.add(Wall3d(points: const [-40, -180, -36, -180]));
      final other = Model3d()..name = 'other';
      other.walls.add(Wall3d(points: const [300, 300, 304, 300]));
      est.models.addAll([far, other]);
      addTearDown(est.models.clear);
      await t.pumpWidget(app());
      await t.pumpAndSettle();
      final st = t.state(find.byType(ModelView)) as dynamic;
      expect(st.selectedModelDebug, same(far));
      final vpBox = t.getRect(find.byKey(const Key('model3d')));
      // scramble the camera first: presets must recenter, not inherit
      await t.tap(find.byIcon(Icons.vrpano_outlined));
      await t.pumpAndSettle();
      final b = far.bounds!;
      const presets = ['ISO', 'TOP', 'FRONT', 'RIGHT', 'REAR', 'LEFT'];
      for (final label in presets) {
        await t.tap(find.byKey(ValueKey('camera-preset-$label')));
        await t.pumpAndSettle();
        for (final x in [b.$1, b.$3]) {
          for (final y in [b.$2, b.$4]) {
            for (final z in [0.0, b.$5]) {
              final u = st.debugProj3(x, y, z) + vpBox.topLeft;
              expect(
                u.dx >= vpBox.left &&
                    u.dx <= vpBox.right &&
                    u.dy >= vpBox.top &&
                    u.dy <= vpBox.bottom,
                isTrue,
                reason: '$label: corner ($x,$y,$z) outside 3D viewport',
              );
            }
          }
        }
      }
    },
  );

  testWidgets('TOP then ISO keeps the stored render flag', (t) async {
    await t.binding.setSurfaceSize(const Size(1600, 900));
    addTearDown(() => t.binding.setSurfaceSize(null));
    est.models.clear();
    final m = Model3d();
    m.walls.add(Wall3d(points: const [0, 0, 4, 0]));
    est.models.add(m);
    addTearDown(est.models.clear);
    await t.pumpWidget(app());
    await t.pumpAndSettle();
    final st = t.state(find.byType(ModelView)) as dynamic;
    await t.tap(find.byIcon(Icons.lightbulb_outline));
    await t.pumpAndSettle();
    expect(st.renderEnabled, isTrue);
    await t.tap(find.byKey(const ValueKey('camera-preset-TOP')));
    await t.pumpAndSettle();
    expect(find.text('TOP / ORTHOGRAPHIC'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('camera-preset-ISO')));
    await t.pumpAndSettle();
    expect(find.text('TOP / ORTHOGRAPHIC'), findsNothing);
    expect(st.renderEnabled, isTrue);
    expect(st.camYaw, -0.7);
    expect(st.camPitch, 0.55);
  });
}
