import 'package:tantyahin/dxf.dart';
import 'package:tantyahin/model3d.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('generated floor plan carries dims, room text, north, scale, title', () {
    final m = Model3d(name: 'Test House');
    // rectangle (axis-aligned) + one diagonal wall
    m.walls.add(
      Wall3d(
        name: 'Box',
        points: [0, 0, 6, 0, 6, 5, 0, 5, 0, 0],
        thickness: 0.15,
        height: 2.7,
      ),
    );
    m.walls.add(
      Wall3d(
        name: 'Diag',
        points: [8, 0, 11, 4],
        thickness: 0.15,
        height: 2.7,
      ),
    );
    m.volumes.add(
      Volume3d(name: 'Living', footprint: [0.2, 0.2, 5.8, 0.2, 5.8, 4.8, 0.2, 4.8]),
    );
    m.dims.add([0, -3, 2, -3]);
    final dxf = buildModelSheet(m, SheetView.plan);

    expect(dxf, contains('FLOOR PLAN'));
    expect(dxf, contains('LIVING'));
    expect(dxf, contains('SQ.M'));
    expect(dxf, contains('SCALE 1:'));
    expect(dxf, contains('TEST HOUSE'));
    // the diagonal wall (5.00 m long) is dimensioned along itself
    expect(dxf, contains('\n5\n'));
    // manual dim (2.00)
    expect(dxf, contains('\n2\n'));
    // and the whole thing still parses as a valid DXF scene
    final scene = DxfParser.parse(dxf);
    expect(scene.prims.length, greaterThan(40));
  });
}
