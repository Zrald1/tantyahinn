import 'package:tantyahin/main.dart';
import 'package:tantyahin/model3d.dart';
import 'package:tantyahin/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(() => projectTabs.reset());

  testWidgets('Props tab: accordion editors edit walls, blocks, dims', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const BoqApp());
    await tester.pumpAndSettle();
    await tester.tap(find.text('3D MODEL'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('New model'));
    await tester.pumpAndSettle();
    final m = est.models.first;
    final pc = tester.getCenter(find.byKey(const Key('modelPlan')));
    await tester.tapAt(pc + const Offset(-160, -80));
    await tester.tapAt(pc + const Offset(120, -80));
    await tester.tapAt(pc + const Offset(120, -80));
    await tester.pumpAndSettle();
    m.blocks.add(Block3d(def: 'sofa-3', x: 1, y: 1));
    m.dims.add([0, 0, 3, 0]);
    est.update();
    await tester.tap(find.text('Props'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    // open the wall row -> full detail set
    if (find.text('Thickness (m)').evaluate().isEmpty) {
      await tester.tap(find.textContaining('seg').first);
      await tester.pumpAndSettle();
    }
    for (final l in [
      'Thickness (m)',
      'Height (m)',
      'Base (m)',
      'Length (m)',
      'Start X',
      'End Y',
    ]) {
      expect(find.text(l), findsOneWidget, reason: l);
    }
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Height (m)'),
      '3.40',
    );
    await tester.pumpAndSettle();
    expect(m.walls.first.height, 3.4);

    // open the block row -> W/D/H + lift; typing resizes
    await tester.tap(find.textContaining('deg').first);
    await tester.pumpAndSettle();
    for (final l in ['Width (m)', 'Depth (m)', 'Height (m)', 'Lift (m)']) {
      expect(find.text(l), findsOneWidget, reason: l);
    }
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Lift (m)'),
      '0.30',
    );
    await tester.pumpAndSettle();
    expect(m.blocks.first.bz, 0.3);

    // dims are listed and deletable
    expect(find.text('DIMENSIONS - 1'), findsOneWidget);
    await tester.tap(find.byTooltip('Delete dimension'));
    await tester.pumpAndSettle();
    expect(m.dims, isEmpty);
    expect(tester.takeException(), isNull);
    est.models.clear();
  });
}
