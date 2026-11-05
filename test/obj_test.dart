import 'dart:io';
import 'dart:typed_data';

import 'package:tantyahin/model3d.dart';
import 'package:tantyahin/obj.dart';
import 'package:tantyahin/state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parseObj: axis map, mtl colors, negative + slash indices', () {
    final om = parseObj(
      '''
v 0 0 0
v 1 0 0
v 1 0 1
v 0 0 1
usemtl wood
f 1// 2// 3// 4//
usemtl carpet
f -4/1/1 -3 -2 -1
''',
      mtlSrc: '''
newmtl wood
Kd 0.8 0.6 0.4
newmtl carpet
Kd 1 0 0
''',
    );
    expect(om, isNotNull);
    expect(om!.verts.length, 4);
    // obj (x, y-up, z) -> model (x, z-ground, y-up): z=1 becomes model y=1
    expect(om.verts[2], [1.0, 1.0, 0.0]);
    expect(om.faces.length, 2);
    expect(om.faces[0].idx, [0, 1, 2, 3]);
    // negative indices resolve relative to the vertex list
    expect(om.faces[1].idx, [0, 1, 2, 3]);
    // Kd colors map per usemtl group
    expect(om.faces[0].argb >> 16 & 0xFF, greaterThan(180));
    expect(om.faces[1].argb, 0xFFFF0000);
    expect(parseObj('junk\nno geometry'), isNull);
  });

  test('bundled Kenney meshes fit their def envelope', () async {
    var loaded = 0;
    await preloadBlockMeshes((p) async {
      loaded++;
      return File(p).readAsString();
    });
    expect(loaded, greaterThan(15));
    // the single bed is a real mesh now, not a box
    final def = cadBlock('bed-sgl')!;
    final b = Block3d(def: 'bed-sgl', x: 2, y: 3);
    final faces = blockFaces(b, def);
    expect(faces.length, greaterThan(20));
    // multiple materials (wood frame + white mattress) survive
    expect(faces.map((f) => f.argb).toSet().length, greaterThan(1));
    // fitted inside the def footprint, centered on the instance
    var maxAbsX = 0.0, top = 0.0;
    for (final f in faces) {
      for (final p in f.v) {
        if ((p[0] - 2).abs() > maxAbsX) maxAbsX = (p[0] - 2).abs();
        if (p[2] > top) top = p[2];
      }
    }
    expect(maxAbsX, lessThanOrEqualTo(def.w / 2 + 0.01));
    expect(top, greaterThan(0));
    expect(blockHeight(b, def), closeTo(top, 1e-9));
  });

  test('every def resolves a real bundled mesh — no box stand-ins', () async {
    // same preload the app boot does (assets/kenney on disk in tests)
    await preloadBlockMeshes((p) => File(p).readAsString());
    for (final id in kKenneyMeshMap.keys) {
      final def = cadBlock(id)!;
      final faces = blockFaces(Block3d(def: id, x: 0, y: 0), def);
      expect(
        faces.length,
        greaterThan(4),
        reason: '$id renders a real mesh, not a flat prism',
      );
    }
    // the sedan is the baked 148-color mesh — body/tires/trim differ
    final car = blockFaces(
      Block3d(def: 'car', x: 0, y: 0),
      cadBlock('car')!,
    );
    expect(car.length, greaterThan(1000));
    expect(car.map((f) => f.argb).toSet().length, greaterThan(10));
    // stairs ascend: upward-facing tread tops at >=3 heights
    final steps = blockFaces(
      Block3d(def: 'stairs-100', x: 0, y: 0),
      cadBlock('stairs-100')!,
    );
    final tops = steps
        .where((f) => f.n[2] > 0.9)
        .map((f) => (f.v[0][2] * 100).round())
        .toSet();
    expect(tops.length, greaterThanOrEqualTo(3));
    // the door is a real leaf+frame now, not nothing
    final door = blockFaces(
      Block3d(def: 'door-090', x: 0, y: 0),
      cadBlock('door-090')!,
    );
    expect(door.length, greaterThan(10));
  });

  test('bbox stretch: sx/sy/sz scale the mesh, bz lifts it', () async {
    await preloadBlockMeshes((p) => File(p).readAsString());
    final def = cadBlock('bed-sgl')!;
    final b = Block3d(def: 'bed-sgl', x: 5, y: 5);
    double maxDx(List<Face3> fs) {
      var x0 = double.infinity, x1 = -double.infinity;
      for (final f in fs) {
        for (final p in f.v) {
          if (p[0] < x0) x0 = p[0];
          if (p[0] > x1) x1 = p[0];
        }
      }
      return x1 - x0;
    }

    final w0 = maxDx(blockFaces(b, def));
    b.sx = 2;
    expect(maxDx(blockFaces(b, def)), closeTo(w0 * 2, 0.01));
    // plan symbol + footprint follow the stretch
    final fp = blockFootprint(b, def);
    final xs = fp.map((p) => p.dx).toList()..sort();
    expect(xs.last - xs.first, closeTo(def.w * 2, 0.01));
    // height + lift
    final h0 = blockHeight(b, def);
    b.sz = 1.5;
    b.bz = 0.9;
    expect(blockHeight(b, def), closeTo(h0 * 1.5 + 0.9, 0.01));
    // blockLocalBox feeds the gizmo: extents are the mesh's real aabb
    final bb = blockLocalBox(def);
    expect(bb[3] - bb[0], closeTo(def.w, 0.05));
    // json round-trip keeps the stretch
    final r = Block3d.fromJson(b.toJson());
    expect(r.sx, 2);
    expect(r.sz, 1.5);
    expect(r.bz, 0.9);
  });

  test('parseStl reads ascii and binary bodies', () {
    final ascii = parseStl(
      '''solid t
facet normal 0 0 1
outer loop
vertex 0 0 0
vertex 1 0 0
vertex 0 1 0
endloop
endfacet
endsolid t'''
          .codeUnits,
    );
    expect(ascii, isNotNull);
    expect(ascii!.faces.single.idx, [0, 1, 2]);

    // binary: 80-byte header + 1 triangle record
    final bin = ByteData(84 + 50)
      ..setUint32(80, 1, Endian.little)
      ..setFloat32(84 + 12, 0, Endian.little)
      ..setFloat32(84 + 24, 1, Endian.little)
      ..setFloat32(84 + 40, 1, Endian.little);
    final b2 = parseStl(bin.buffer.asUint8List());
    expect(b2, isNotNull);
    expect(b2!.faces.single.idx, [0, 1, 2]);
    expect(b2.verts[2], [0.0, 1.0, 0.0]);
  });

  test('registerObjBlock + project json round-trip restores the mesh', () {
    final om = parseObj('''
v 0 0 0
v 0.5 0 0
v 0.5 0.4 0
v 0 0.4 0
v 0 0.8 0
v 0.5 0.8 0
v 0.5 1.2 0
v 0 1.2 0
f 1 2 6 5
f 2 3 7 6
f 3 4 8 7
f 4 1 5 8
f 5 6 7 8
''')!;
    final def = registerObjBlock('Test chair', om);
    expect(cadBlock(def.id), same(def));
    expect(def.cat, 'Imported');
    final b = Block3d(def: def.id, x: 1, y: 1, rot: 0.5);
    final faces = blockFaces(b, def);
    expect(faces.length, 5);
    expect(blockHeight(b, def), closeTo(1.2, 1e-9));

    final js = est.toJson();
    customCadBlocks.clear();
    blockMeshes.remove(def.id);
    expect(cadBlock(def.id), isNull);
    est.loadJson(js);
    expect(cadBlock(def.id), isNotNull);
    expect(blockFaces(b, cadBlock(def.id)!).length, 5);
    expect(blockHeight(b, cadBlock(def.id)!), closeTo(1.2, 1e-9));

    // clean up module state for other tests
    customCadBlocks.clear();
    blockMeshes.remove(def.id);
    blockMeshTop.remove(def.id);
  });
}
