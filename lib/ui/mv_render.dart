part of 'model_view.dart';

// Ground-plane drop shadows for the 3D render mode.
//
// The old pass drew every face projected to the floor with its own
// translucent fill — overlapping projections stacked alpha into dark
// wall-shaped ghosts, and faces off the slab left silhouettes on bare
// canvas. Instead every projection draws OPAQUE white into one layer,
// so overlaps union into a single mask; the layer is then tinted once
// by `srcIn` (fixed shadow opacity, never darker) and clipped to the
// floor slab so nothing lands outside it.
void paintGroundShadow(
  Canvas canvas, {
  required Iterable<Face3> faces,
  required double groundZ,
  required Path floorPath,
  required Offset Function(List<double> p) project,
  Color color = const Color(0x260F172A),
}) {
  final sun = _SolidPainter._light;
  final white = Paint()..color = const Color(0xFFFFFFFF);
  canvas.save();
  canvas.clipPath(floorPath);
  canvas.saveLayer(
    floorPath.getBounds(),
    Paint()..colorFilter = ColorFilter.mode(color, BlendMode.srcIn),
  );
  for (final f in faces) {
    var allBelow = true;
    for (final v in f.v) {
      if (v[2] > groundZ + 1e-6) {
        allBelow = false;
        break;
      }
    }
    if (allBelow) continue;
    final path = Path();
    var x0 = double.infinity, y0 = double.infinity;
    var x1 = -double.infinity, y1 = -double.infinity;
    for (var i = 0; i < f.v.length; i++) {
      final v = f.v[i];
      final p = project([
        v[0] - (v[2] - groundZ) * sun[0] / sun[2],
        v[1] - (v[2] - groundZ) * sun[1] / sun[2],
        groundZ,
      ]);
      x0 = math.min(x0, p.dx);
      y0 = math.min(y0, p.dy);
      x1 = math.max(x1, p.dx);
      y1 = math.max(y1, p.dy);
      i == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
    }
    path.close();
    if ((x1 - x0) * (y1 - y0) < 0.5) continue;
    canvas.drawPath(path, white);
  }
  canvas.restore();
  canvas.restore();
}
