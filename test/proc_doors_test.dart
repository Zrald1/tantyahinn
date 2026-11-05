import 'dart:io';

import 'package:tantyahin/main.dart';
import 'package:tantyahin/model3d.dart';
import 'package:tantyahin/state.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(() => projectTabs.reset());

  const ids = <String>[
    'door-slide-2500x2000',
    'door-slide-2500x2200',
    'door-slide-2800x2000',
    'door-slide-3000x2200',
    'door-slide-3500x2200',
  ];
  const dims = <String, (double, double)>{
    'door-slide-2500x2000': (2.5, 2.0),
    'door-slide-2500x2200': (2.5, 2.2),
    'door-slide-2800x2000': (2.8, 2.0),
    'door-slide-3000x2200': (3.0, 2.2),
    'door-slide-3500x2200': (3.5, 2.2),
  };

  group('own parametric sliding-door defaults', () {
    test('five sliding doors are built-in Openings defs, ordered right', () {
      for (final id in ids) {
        final d = cadBlock(id);
        expect(d, isNotNull, reason: id);
        expect(d!.cat, 'Openings');
        expect(d.opening, isTrue);
        expect(d.sill, 0);
        expect(d.head, dims[id]!.$2);
        expect(d.w, dims[id]!.$1);
        // the plan symbol must stay inside the footprint — blockFootprint
        // reads line extents for the wall cut, so any spill widens the gap
        for (final l in d.lines) {
          for (final p in l) {
            expect(p.dx.abs(), lessThanOrEqualTo(d.w / 2 + 1e-9), reason: id);
            expect(p.dy.abs(), lessThanOrEqualTo(d.d / 2 + 1e-9), reason: id);
          }
        }
      }
      // the original first entry and the spread's slot are untouched
      expect(kCadBlocks.first.id, 'door-090');
      final order = [for (final b in kCadBlocks) b.id];
      final doorway = order.indexOf('doorway-150');
      final stairs = order.indexOf('stairs-100');
      expect(doorway, greaterThan(0));
      for (final id in ids) {
        expect(order.indexOf(id), greaterThan(doorway), reason: id);
        expect(order.indexOf(id), lessThan(stairs), reason: id);
      }
    });

    test(
      'procedural meshes register at preload and normalize to W x D x H',
      () async {
        await preloadBlockMeshes((p) => File(p).readAsString());
        for (final id in ids) {
          final def = cadBlock(id)!;
          expect(blockMeshes[id], isNotEmpty, reason: id);
          final b = blockMeshBox[id]!;
          expect(b[3] - b[0], closeTo(def.w, 0.02), reason: '$id width');
          expect(b[4] - b[1], closeTo(0.16, 0.005), reason: '$id depth');
          expect(
            b[5] - b[2],
            closeTo(def.head - def.sill, 0.02),
            reason: '$id height',
          );
          expect(b[2], closeTo(0, 0.01), reason: '$id base dropped to 0');
          // translucent glass panes must be present — the ray tracer's
          // alpha<255 path renders them see-through
          expect(
            blockMeshes[id]!.any((f) => (f.argb >> 24) & 0xFF < 255),
            isTrue,
            reason: '$id glass',
          );
        }
      },
    );

    test('legacy bundled-BIM def ids still resolve via the alias map', () {
      expect(
        cadBlock('gealan-s9000-plan-a-2500x2200')?.id,
        'door-slide-2500x2200',
      );
      expect(
        cadBlock('gealan-s9000-plan-a-3500x2200')?.id,
        'door-slide-3500x2200',
      );
      expect(cadBlock('gealan-s9000-plan-a-9999x9999'), isNull);
    });

    test(
      'placed sliding-door block survives JSON; defaults outlive clears',
      () {
        final m = Model3d(name: 'T')
          ..blocks.add(Block3d(def: ids.first, x: 1, y: 2));
        final r = Model3d.fromJson(m.toJson());
        expect(r.blocks.single.def, ids.first);
        expect(cadBlock(r.blocks.single.def), isNotNull);
        // File>New / project load clears custom defs — bundled defaults
        // are kCadBlocks entries, never import residue
        loadCustomBlocks(const []);
        expect(customCadBlocks, isEmpty);
        expect(cadBlock(ids.first), isNotNull);
        expect(cadBlock(ids.first)!.opening, isTrue);
      },
    );
  });

  group('library hover previews', () {
    // every card assertion scopes to the card's own key — the canvas
    // ships a FRONT preset, so global find.text('FRONT') is ambiguous
    Finder cardFor(String defId) => find.byKey(Key('block-preview-$defId'));
    Finder inCard(Finder card, String text) =>
        find.descendant(of: card, matching: find.text(text));

    testWidgets(
      'sliding-door hover shows FRONT+3D card with W/H/D, arms+places',
      (t) async {
        t.view.physicalSize = const Size(1600, 900);
        t.view.devicePixelRatio = 1.0;
        addTearDown(t.view.reset);
        addTearDown(() {
          est.models.clear();
          est.modelIntroDismissed = false;
        });
        // real File IO must escape fakeAsync or the read never resolves
        await t.runAsync(
          () => preloadBlockMeshes((p) => File(p).readAsString()),
        );
        est.newProject();
        await t.pumpWidget(const BoqApp());
        await t.pumpAndSettle();
        await t.tap(find.text('3D MODEL'));
        await t.pumpAndSettle();
        await t.tap(find.byTooltip('New model'));
        await t.pumpAndSettle();
        final m = est.models.first;

        await t.enterText(find.byKey(const Key('lib-search')), 'sliding');
        await t.pumpAndSettle();
        final row = find.byKey(const Key('lib-door-slide-2500x2200'));
        expect(row, findsOneWidget);
        // the row's own subtitle quotes the overall frame size already
        expect(find.text('2.50 × 2.20 m'), findsWidgets);
        final card = cardFor('door-slide-2500x2200');
        expect(card, findsNothing);

        // mouse hover -> rich preview card
        final ptr = TestPointer(41, PointerDeviceKind.mouse);
        addTearDown(() => t.sendEventToBinding(ptr.removePointer()));
        await t.sendEventToBinding(
          ptr.hover(t.getCenter(row), timeStamp: Duration.zero),
        );
        await t.pump(const Duration(milliseconds: 500));
        await t.pumpAndSettle();
        expect(card, findsOneWidget);
        expect(inCard(card, 'FRONT'), findsOneWidget);
        expect(inCard(card, '3D'), findsOneWidget);
        expect(inCard(card, 'WIDTH'), findsOneWidget);
        expect(inCard(card, 'HEIGHT'), findsOneWidget);
        expect(inCard(card, 'DEPTH'), findsOneWidget);
        expect(inCard(card, '2.50 m'), findsOneWidget);
        expect(inCard(card, '2.20 m'), findsOneWidget);
        expect(inCard(card, '0.16 m'), findsOneWidget);
        expect(
          find.descendant(
            of: card,
            matching: find.textContaining('PARAMETRIC'),
          ),
          findsOneWidget,
        );

        // pointer leaving the row hides the card — park it over the 3D
        // canvas, which carries no tooltip of its own
        final mc = t.getCenter(find.byKey(const Key('model3d')));
        await t.sendEventToBinding(ptr.hover(mc, timeStamp: Duration.zero));
        await t.pump(const Duration(milliseconds: 300));
        await t.pumpAndSettle();
        expect(card, findsNothing);

        // tap arms the block (and keeps the card away); a plan tap
        // places the real piece
        await t.sendEventToBinding(
          ptr.hover(t.getCenter(row), timeStamp: Duration.zero),
        );
        await t.pump(const Duration(milliseconds: 500));
        await t.pumpAndSettle();
        expect(card, findsOneWidget);
        await t.tap(row);
        await t.pumpAndSettle();
        expect(card, findsNothing);
        final pc = t.getCenter(find.byKey(const Key('modelPlan')));
        await t.tapAt(pc + const Offset(-40, 60));
        await t.pumpAndSettle();
        expect(m.blocks.any((b) => b.def == 'door-slide-2500x2200'), isTrue);
      },
    );

    testWidgets('furniture row hover shows the same card', (t) async {
      t.view.physicalSize = const Size(1600, 900);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);
      addTearDown(() {
        est.models.clear();
        est.modelIntroDismissed = false;
      });
      await t.runAsync(() => preloadBlockMeshes((p) => File(p).readAsString()));
      est.newProject();
      await t.pumpWidget(const BoqApp());
      await t.pumpAndSettle();
      await t.tap(find.text('3D MODEL'));
      await t.pumpAndSettle();
      await t.tap(find.byTooltip('New model'));
      await t.pumpAndSettle();

      await t.enterText(find.byKey(const Key('lib-search')), 'double bed');
      await t.pumpAndSettle();
      final row = find.byKey(const Key('lib-bed-dbl'));
      expect(row, findsOneWidget);
      final card = cardFor('bed-dbl');
      final ptr = TestPointer(42, PointerDeviceKind.mouse);
      addTearDown(() => t.sendEventToBinding(ptr.removePointer()));
      await t.sendEventToBinding(
        ptr.hover(t.getCenter(row), timeStamp: Duration.zero),
      );
      await t.pump(const Duration(milliseconds: 500));
      await t.pumpAndSettle();
      expect(card, findsOneWidget);
      expect(inCard(card, 'FRONT'), findsOneWidget);
      expect(inCard(card, '3D'), findsOneWidget);
      expect(inCard(card, 'WIDTH'), findsOneWidget);
      expect(inCard(card, 'HEIGHT'), findsOneWidget);
      expect(inCard(card, 'DEPTH'), findsOneWidget);
      // kk_bed_double_A normalized to the def footprint: W 1.50
      expect(inCard(card, '1.50 m'), findsOneWidget);
    });
  });
}
