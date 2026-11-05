part of 'model_view.dart';

// Split from model_view.dart (1k-line cap): real-mesh block previews —
// the library row thumbnail and the rich hover card EVERY library
// block gets, so a piece's actual appearance and size are visible
// before it is placed.

/// Which miniature camera a [_BlockMeshThumb] paints with.
enum _BlockView { front, iso }

/// Local-space aabb (x0,y0,z0,x1,y1,z1) of a face list — same contract
/// as blockMeshBox, for meshes whose box was never registered.
List<double> _meshAabb(List<Face3> faces) {
  var x0 = double.infinity, y0 = double.infinity, z0 = double.infinity;
  var x1 = -double.infinity, y1 = -double.infinity, z1 = -double.infinity;
  for (final f in faces) {
    for (final p in f.v) {
      x0 = math.min(x0, p[0]);
      x1 = math.max(x1, p[0]);
      y0 = math.min(y0, p[1]);
      y1 = math.max(y1, p[1]);
      z0 = math.min(z0, p[2]);
      z1 = math.max(z1, p[2]);
    }
  }
  return [x0, y0, z0, x1, y1, z1];
}

/// A block's registered local mesh painted as a thumbnail: [front] is
/// an orthographic X/Z elevation seen from -Y (the same side
/// projectView's `front` keeps), [iso] is the 3D canvas camera (yaw
/// -0.7, pitch 0.55). Faces paint far->near with the dollhouse light
/// and authored alpha (glass stays translucent). With no registered
/// mesh — e.g. widget tests that skip preload — the plan linework
/// draws as a PLAN-tagged schematic, never an empty gray box.
class _BlockMeshThumb extends CustomPainter {
  final CadBlock def;
  final _BlockView view;

  /// Registry snapshot captured at build time — shouldRepaint compares
  /// it by IDENTITY so a late preload or import repaint fires exactly
  /// once and a parent setState never re-fits the mesh.
  final List<Face3>? mesh;

  _BlockMeshThumb(this.def, this.view)
    : mesh = isTrussDef(def.id)
          // trusses render parametrically when placed — the thumb must
          // show THAT mesh, not the registered wh_truss OBJ (which is a
          // different mono-pitch shape for 'truss' and nothing at all
          // for 'truss-sgl')
          ? trussLocalFaces(
              0,
              def.w,
              def.d,
              def.height,
              single: def.id == 'truss-sgl',
            )
          : blockMeshes[def.id];

  static const _light = [0.35, -0.5, 0.78]; // _SolidPainter's sun

  @override
  void paint(Canvas canvas, Size size) {
    final m = mesh;
    if (m == null || m.isEmpty) {
      _planFallback(canvas, size);
      return;
    }
    final yaw = view == _BlockView.front ? 0.0 : -0.7;
    final pitch = view == _BlockView.front ? 0.0 : 0.55;
    final b = isTrussDef(def.id)
        ? _meshAabb(m)
        : (blockMeshBox[def.id] ?? _meshAabb(m));
    // fit: project the aabb's 8 corners at zoom 1, scale the projected
    // bounds into the box, recenter on the viewport midpoint
    var x0 = double.infinity, y0 = double.infinity;
    var x1 = -double.infinity, y1 = -double.infinity;
    for (final cx in [b[0], b[3]]) {
      for (final cy in [b[1], b[4]]) {
        for (final cz in [b[2], b[5]]) {
          final p = cam3Project(
            [cx, cy, cz],
            size,
            yaw: yaw,
            pitch: pitch,
            zoom: 1,
            off: Offset.zero,
          );
          x0 = math.min(x0, p.dx);
          y0 = math.min(y0, p.dy);
          x1 = math.max(x1, p.dx);
          y1 = math.max(y1, p.dy);
        }
      }
    }
    if (x1 - x0 < 1e-9 || y1 - y0 < 1e-9) {
      _planFallback(canvas, size);
      return;
    }
    const pad = 2.0;
    final zoom = math.min(
      (size.width - pad * 2) / (x1 - x0),
      (size.height - pad * 2) / (y1 - y0),
    );
    final off = Offset(
      (size.width / 2 - (x0 + x1) / 2) * zoom,
      (size.height / 2 - (y0 + y1) / 2) * zoom,
    );

    // painter's algorithm: far faces first (cam3Depth descending)
    final order = [
      for (final f in m)
        (
          f.v.fold<double>(
                0,
                (s, p) => s + cam3Depth(p, yaw: yaw, pitch: pitch),
              ) /
              f.v.length,
          f,
        ),
    ]..sort((a, b) => b.$1.compareTo(a.$1));

    canvas.save();
    canvas.clipRect(Offset.zero & size);
    final edge = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.6
      ..color = const Color(0xFF37474F).withValues(alpha: 0.22);
    for (final (_, f) in order) {
      final path = Path();
      var fx0 = double.infinity, fy0 = double.infinity;
      var fx1 = -double.infinity, fy1 = -double.infinity;
      for (var i = 0; i < f.v.length; i++) {
        final p = cam3Project(
          f.v[i],
          size,
          yaw: yaw,
          pitch: pitch,
          zoom: zoom,
          off: off,
        );
        fx0 = math.min(fx0, p.dx);
        fy0 = math.min(fy0, p.dy);
        fx1 = math.max(fx1, p.dx);
        fy1 = math.max(fy1, p.dy);
        i == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
      }
      path.close();
      // sub-pixel cull — dense breps (3.5k faces) stay fluid
      if ((fx1 - fx0) * (fy1 - fy0) < 1.4) continue;
      final dot = (f.n[0] * _light[0] + f.n[1] * _light[1] + f.n[2] * _light[2])
          .abs();
      final shade = 0.52 + 0.48 * dot;
      final c = Color(f.argb);
      canvas.drawPath(
        path,
        Paint()
          ..color = Color.fromARGB(
            (f.argb >> 24) & 0xFF,
            (c.r * 255 * shade).round().clamp(0, 255),
            (c.g * 255 * shade).round().clamp(0, 255),
            (c.b * 255 * shade).round().clamp(0, 255),
          ),
      );
      canvas.drawPath(path, edge);
    }
    canvas.restore();
  }

  /// Schematic plan-symbol fallback — identical fit to [_BlockThumb],
  /// tagged so nobody reads it as the real 3D piece.
  void _planFallback(Canvas canvas, Size size) {
    _BlockThumb(def).paint(canvas, size);
    final tp = TextPainter(
      text: const TextSpan(
        text: 'PLAN',
        style: TextStyle(
          fontSize: 7,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.8,
          color: Color(0xFF94A3B8),
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(
      canvas,
      Offset(size.width - tp.width - 1, size.height - tp.height - 1),
    );
  }

  @override
  bool shouldRepaint(covariant _BlockMeshThumb old) =>
      old.def != def || old.view != view || !identical(old.mesh, mesh);
}

/// Clipped, repaint-boundary'd mesh thumbnail for [def] at [view].
/// Library rows, the drag feedback and the hover card all use it.
Widget _blockMeshThumb(
  CadBlock def,
  _BlockView view, {
  double w = 52,
  double h = 40,
}) => RepaintBoundary(
  child: ClipRect(
    child: CustomPaint(size: Size(w, h), painter: _BlockMeshThumb(def, view)),
  ),
);

/// Library row subtitle: openings quote the overall frame envelope
/// W x H (frame width x sill-to-head height), furniture W x D x H —
/// the registered mesh's aabb when there is one (an EXTENT, so baked
/// wall-mount lifts don't inflate height), else the def's nominal
/// size. Height visible without hovering.
String _libDims(CadBlock b) {
  String f(double v) => v.toStringAsFixed(2);
  if (b.opening) {
    return '${f(b.w)} × ${f(b.head - b.sill)} m';
  }
  final box = blockMeshBox[b.id];
  final w = box != null ? box[3] - box[0] : b.w;
  final d = box != null ? box[4] - box[1] : b.d;
  final h = box != null ? box[5] - box[2] : b.height;
  return h > 0.005 ? '${f(w)} × ${f(d)} × ${f(h)} m' : '${f(w)} × ${f(d)} m';
}

/// The hover card's honest dims: openings quote the overall frame
/// envelope (def.w x sill-to-head) — the leaf and frame live inside
/// it, this is NOT the passable opening; furniture reads the
/// registered mesh's aabb — an EXTENT, so baked wall-mount lifts
/// never inflate the height — and falls back to the def's nominal
/// size while no mesh is registered.
({double w, double d, double h, double? sill}) _blockDims(CadBlock def) {
  final b = blockMeshBox[def.id];
  if (def.opening) {
    return (
      w: def.w,
      d: b != null ? b[4] - b[1] : def.d,
      h: def.head - def.sill,
      sill: def.sill > 0.001 ? def.sill : null,
    );
  }
  return (
    w: b != null ? b[3] - b[0] : def.w,
    d: b != null ? b[4] - b[1] : def.d,
    h: b != null ? b[5] - b[2] : def.height,
    sill: null,
  );
}

/// The hover card inside every library row's rich tooltip: real FRONT
/// + 3D mesh previews, category/product label and the W/H/D figures —
/// the "what am I actually placing" answer without placing it.
Widget _blockPreviewCard(CadBlock def, ColorScheme cs, double maxW) {
  final d = _blockDims(def);
  final product = kOwnDoorDefs.any((e) => e.id == def.id)
      ? ' · PARAMETRIC'
      : '';
  String m2(double v) => '${v.toStringAsFixed(2)} m';
  Widget dim(String label, String value) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        label,
        style: TextStyle(
          fontSize: 8,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.8,
          color: cs.onSurfaceVariant,
        ),
      ),
      Text(
        value,
        style: const TextStyle(
          fontSize: 11.5,
          fontWeight: FontWeight.w600,
          color: Color(0xFF334155),
        ),
      ),
    ],
  );
  Widget cap(String s) => Padding(
    padding: const EdgeInsets.only(top: 3),
    child: Text(
      s,
      style: TextStyle(
        fontSize: 8,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.9,
        color: cs.onSurfaceVariant,
      ),
    ),
  );
  return Semantics(
    container: true,
    label:
        '${def.name}, ${def.cat}, width ${m2(d.w)}, '
        'height ${m2(d.h)}, depth ${m2(d.d)}',
    child: Container(
      key: ValueKey('block-preview-${def.id}'),
      width: maxW,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFCBD5E1)),
        boxShadow: const [
          BoxShadow(
            blurRadius: 14,
            offset: Offset(0, 4),
            color: Color(0x2A0F172A),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            def.name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
              color: Color(0xFF1E293B),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Text(
              '${def.cat.toUpperCase()}$product',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 8.5,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.9,
                color: cs.primary,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 3,
                child: Column(
                  children: [
                    SizedBox(
                      height: 118,
                      width: double.infinity,
                      child: _blockMeshThumb(def, _BlockView.front),
                    ),
                    cap('FRONT'),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 2,
                child: Column(
                  children: [
                    SizedBox(
                      height: 76,
                      width: double.infinity,
                      child: _blockMeshThumb(def, _BlockView.iso),
                    ),
                    cap('3D'),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 14,
            runSpacing: 4,
            children: [
              dim('WIDTH', m2(d.w)),
              dim('HEIGHT', m2(d.h)),
              dim('DEPTH', m2(d.d)),
              if (d.sill != null) dim('SILL', m2(d.sill!)),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(top: 7),
            child: Text(
              'Click to place · drag into either view',
              style: TextStyle(
                fontSize: 9.5,
                fontStyle: FontStyle.italic,
                color: cs.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

/// Every library row's hover wrapper: a native rich [Tooltip] carrying
/// [_blockPreviewCard]. Hover-only trigger (manual = no long-press/tap
/// trigger, so touch drags and list scrolling are untouched), zero
/// pointer interception on the overlay, and free dismissal — a pointer
/// down anywhere closes it natively, and the Draggable swapping the
/// row for its drag ghost unmounts the tooltip outright. Placement and
/// screen-edge flipping are the platform's positionDependentBox.
Widget _blockTip(CadBlock def, ColorScheme cs, {required Widget child}) {
  return Builder(
    builder: (ctx) {
      final w = math.min(
        340.0,
        math.max(0.0, MediaQuery.sizeOf(ctx).width - 24),
      );
      return Tooltip(
        richMessage: TextSpan(
          children: [WidgetSpan(child: _blockPreviewCard(def, cs, w))],
        ),
        padding: EdgeInsets.zero,
        margin: const EdgeInsets.symmetric(horizontal: 12),
        verticalOffset: 6,
        waitDuration: const Duration(milliseconds: 400),
        exitDuration: const Duration(milliseconds: 120),
        triggerMode: TooltipTriggerMode.manual,
        ignorePointer: true,
        excludeFromSemantics: true,
        decoration: const BoxDecoration(),
        child: child,
      );
    },
  );
}
