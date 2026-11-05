import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:tantyahin/ifc.dart';
import 'package:tantyahin/model3d.dart';

void main() {
  const dir = 'C:/Users/Zrald/AppData/Local/Temp';
  test('GEALAN S9000 sliding door IFC imports as a real opening block', () async {
    final f = File('/tmp/bimo/planA/GEALAN_S9000_Sliding_Door_Plan-A_2500x2200-IFC2X3.ifc');
    final f2 = File('C:/Users/Zrald/AppData/Local/Temp/gealan.ifc');
    final file = f.existsSync() ? f : f2;
    if (!file.existsSync()) return;
    final r = parseIfc(await file.readAsString())!;
    final b = r.mesh.bounds;
    print('kind=${r.kind} name=${r.name} faces=${r.mesh.faces.length}');
    print('bounds x ${b.$1}..${b.$4}  y ${b.$2}..${b.$5}  z ${b.$3}..${b.$6}');
    print('colors ${r.mesh.faces.map((e) => e.argb.toRadixString(16)).toSet()}');
    expect(r.kind, 'door');
    expect(b.$4 - b.$1, closeTo(2.5, 0.05));
    expect(b.$6 - b.$3, closeTo(2.25, 0.02));
    final def = registerObjBlock(r.name, r.mesh, opening: true);
    expect(def.opening, true);
    expect(def.head, closeTo(2.25, 0.02));
    expect(blockMeshes[def.id]!.length, r.mesh.faces.length);
    // survives project save/load
    final js = customBlocksJson();
    loadCustomBlocks(js);
    expect(customCadBlocks.single.opening, true);
    expect(dir.isNotEmpty, true);
  });
}
