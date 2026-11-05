import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

import 'package:tantyahin/dxf.dart';
import 'package:tantyahin/model3d.dart';
import 'package:tantyahin/state.dart';

/// Sheet-annotation regression: generated drawing sheets used to
/// stack every block label at the quad's bottom edge, so opening
/// tags, truss callouts and footing labels all collided with each
/// other and with the dimension ink. The label allocator must never
/// emit a text whose box intersects an already-emitted one.
void main() {
  Model3d furnished() {
    final m = EstimateState().addModel('M');
    // 6.5 x 5.5 room, walls as separate segments
    m.walls.add(Wall3d(points: [0, 0, 6.5, 0], thickness: .18, height: 2.7));
    m.walls.add(Wall3d(points: [0, 5.5, 6.5, 5.5], thickness: .18, height: 2.7));
    m.walls.add(Wall3d(points: [0, 0, 0, 5.5], thickness: .18, height: 2.7));
    m.walls.add(Wall3d(points: [6.5, 0, 6.5, 5.5], thickness: .18, height: 2.7));
    // openings on every wall — the tag-collision scenario
    m.blocks.add(Block3d(def: 'window-120', x: 2.0, y: 5.5));
    m.blocks.add(Block3d(def: 'window-120', x: 4.5, y: 5.5));
    m.blocks.add(Block3d(def: 'window-slide', x: 6.5, y: 1.8, rot: math.pi / 2));
    m.blocks.add(Block3d(def: 'window-slide', x: 6.5, y: 4.0, rot: math.pi / 2));
    m.blocks.add(Block3d(def: 'door-dbl', x: 0, y: 2.6, rot: math.pi / 2));
    m.blocks.add(Block3d(def: 'door-glass', x: 3.2, y: 0));
    // interior trusses + corner columns w/ footings + trees
    for (var i = 0; i < 3; i++) {
      m.blocks.add(Block3d(
          def: 'truss-sgl',
          x: 1.4 + i * 1.9,
          y: 2.75,
          rot: math.pi / 2,
          bz: 2.7));
    }
    for (final c in [
      (0.0, 0.0), (6.5, 0.0), (0.0, 5.5), (6.5, 5.5),
    ]) {
      m.blocks.add(
          Block3d(def: 'col-sq', x: c.$1, y: c.$2, footing: true, footW: 1.5));
    }
    m.blocks.add(Block3d(def: 'tree', x: -1.2, y: 6.6));
    m.blocks.add(Block3d(def: 'tree', x: 7.4, y: 6.6));
    return m;
  }

  /// AABB overlap count among all text entities of a generated sheet
  /// (same conservative box the allocator negotiates with).
  int textOverlaps(String dxf) {
    final sc = DxfParser.parse(dxf);
    final boxes = <(double, double, double, double, String)>[];
    for (final t in sc.texts) {
      boxes.add((
        t.pos.dx - t.height * 0.08,
        t.pos.dy - t.height * 0.30,
        t.pos.dx + t.text.length * t.height * 0.62 + t.height * 0.08,
        t.pos.dy + t.height * 1.1,
        t.text,
      ));
    }
    var n = 0;
    for (var i = 0; i < boxes.length; i++) {
      for (var j = i + 1; j < boxes.length; j++) {
        final a = boxes[i], b = boxes[j];
        if (a.$1 < b.$3 && a.$3 > b.$1 && a.$2 < b.$4 && a.$4 > b.$2) {
          n++;
          // ignore: avoid_print
          print(
            '  OVERLAP "${a.$5}"(${a.$1.toStringAsFixed(0)},${a.$2.toStringAsFixed(0)})'
            ' x "${b.$5}"(${b.$1.toStringAsFixed(0)},${b.$2.toStringAsFixed(0)})',
          );
        }
      }
    }
    return n;
  }

  test('plan sheet labels never collide', () {
    final m = furnished();
    expect(textOverlaps(buildModelSheet(m, SheetView.plan)), 0);
    // the D#/W# tags still make it onto the sheet
    final sc = DxfParser.parse(buildModelSheet(m, SheetView.plan));
    final texts = sc.texts.map((t) => t.text).toList();
    expect(texts.where((t) => t.contains('W1')), isNotEmpty);
    expect(texts.where((t) => t.contains('D1')), isNotEmpty);
    // opening tags carry their schedule prefix (tag · name)
    expect(texts.where((t) => t.startsWith('W') && t.contains('window')),
        isNotEmpty);
  });

  test('structural sheet callouts never collide or clip', () {
    final m = furnished();
    expect(textOverlaps(buildModelSheet(m, SheetView.structural)), 0);
    final sc = DxfParser.parse(buildModelSheet(m, SheetView.structural));
    // four column footings -> four F# callouts, all kept (no drops)
    final fs = sc.texts.where((t) => t.text.startsWith('F')).toList();
    expect(fs.length, greaterThanOrEqualTo(4));
    expect(
      fs.where((t) => t.text.contains('x') && t.text.contains('@')).length,
      greaterThanOrEqualTo(4),
    );
  });
}
