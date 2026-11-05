import 'dart:io';
import 'package:tantyahin/dxf.dart';
void main() {
  for (final slug in ['floorplan','structural','front']) {
    final f = File(r'C:\Users\Zrald\AppData\Local\Temp\ce_gen\model_97f1293d-1e12-411b-9ec9-df76b887d15d_$slug.dxf');
    if (!f.existsSync()) { print('$slug MISSING'); continue; }
    final sc = DxfParser.parse(f.readAsStringSync());
    print('$slug bounds=${sc.bounds} prims=${sc.prims.length} texts=${sc.texts.length}');
    // where does content actually sit
    var x0=1e9,y0=1e9,x1=-1e9,y1=-1e9;
    for (final p in sc.prims) for (final o in p.pts) {
      if(o.dx<x0)x0=o.dx; if(o.dy<y0)y0=o.dy; if(o.dx>x1)x1=o.dx; if(o.dy>y1)y1=o.dy;
    }
    for (final t in sc.texts) { if(t.pos.dx<x0)x0=t.pos.dx; if(t.pos.dy<y0)y0=t.pos.dy; if(t.pos.dx>x1)x1=t.pos.dx; if(t.pos.dy>y1)y1=t.pos.dy; }
    print('  content x=$x0..$x1 y=$y0..$y1');
  }
}
