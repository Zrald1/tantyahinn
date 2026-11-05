part of 'model3d.dart';

// Own parametric sliding doors — generated geometry, no bundled
// manufacturer/BIM content (the previous GEALAN S9000 IFC assets were
// removed for licensing). These are built-in defs living in
// [kCadBlocks] with stable ids, so they survive File>New and project
// load (customCadBlocks is cleared on both) and never need a manual
// import step. The meshes are authored in code by
// [registerProceduralSlidingDoors] the same way
// registerProceduralWindows builds the window bodies.

/// Def ids once shipped under the bundled-BIM names — old .boqproj
/// files still resolve to the equivalent own-built def via
/// [cadBlock]'s alias pass.
const kLegacyDefAliases = {
  'gealan-s9000-plan-a-2500x2000': 'door-slide-2500x2000',
  'gealan-s9000-plan-a-2500x2200': 'door-slide-2500x2200',
  'gealan-s9000-plan-a-2800x2000': 'door-slide-2800x2000',
  'gealan-s9000-plan-a-3000x2200': 'door-slide-3000x2200',
  'gealan-s9000-plan-a-3500x2200': 'door-slide-3500x2200',
};

/// Architectural plan symbol for a two-track / two-panel sliding door:
/// the jamb frame reads the full opening ([blockFootprint] uses line
/// extents for the wall cut, so the frame MUST span exactly
/// +/-w/2 x +/-d/2), two staggered leaf rects on the parallel tracks,
/// and a slide arrow inside the moving leaf pointing toward the
/// overlap. No swing arcs — nothing leaves the w x d envelope.
List<List<Offset>> _slidingDoorLines(double w, double d) {
  final hw = w / 2, hd = d / 2;
  const jamb = 0.05; // frame inset from each reveal end
  const lt = 0.035; // leaf thickness
  final tr = hd * 0.62; // track offset from the wall centerline
  final leafW = w / 2 + 0.09; // half the opening + center overlap
  List<Offset> leaf(double x0, double y) => [
    Offset(x0, y - lt / 2),
    Offset(x0 + leafW, y - lt / 2),
    Offset(x0 + leafW, y + lt / 2),
    Offset(x0, y + lt / 2),
    Offset(x0, y - lt / 2),
  ];
  // the moving leaf (near track) travels +x over the fixed leaf
  final ax0 = -hw + jamb + 0.10;
  final ax1 = -hw + jamb + leafW - 0.10;
  return [
    [
      Offset(-hw, -hd),
      Offset(hw, -hd),
      Offset(hw, hd),
      Offset(-hw, hd),
      Offset(-hw, -hd),
    ],
    leaf(-hw + jamb, -tr), // sliding leaf, near track
    leaf(hw - jamb - leafW, tr), // fixed leaf, far track
    [Offset(ax0, -tr), Offset(ax1, -tr)],
    [
      Offset(ax1 - 0.07, -tr - 0.02),
      Offset(ax1, -tr),
      Offset(ax1 - 0.07, -tr + 0.02),
    ],
  ];
}

/// The own-door lineup as default library defs — spread into
/// [kCadBlocks] after the cased-opening entry and before
/// stairs/Bedroom. Depth 0.16 reads as a two-track frame on a 0.15 m
/// wall; heads follow each listed height.
final kOwnDoorDefs = <CadBlock>[
  for (final (w, h) in [
    (2.5, 2.0),
    (2.5, 2.2),
    (2.8, 2.0),
    (3.0, 2.2),
    (3.5, 2.2),
  ])
    CadBlock(
      'door-slide-${(w * 1000).round()}x${(h * 1000).round()}',
      'Sliding door ${w.toStringAsFixed(1)}×${h.toStringAsFixed(1)}',
      'Openings',
      w,
      0.16,
      0,
      _slidingDoorLines(w, 0.16),
      opening: true,
      sill: 0,
      head: h,
    ),
];

/// Builds the sliding-door meshes procedurally: head beam + side
/// jambs + a floor track, then two staggered leaf frames (stiles,
/// rails, translucent glass) riding the two tracks — a generic
/// two-panel slider that is ours, not a product replica. Registered
/// from [preloadBlockMeshes] beside [registerProceduralWindows];
/// no assets are loaded, so nothing can go missing in an install.
void registerProceduralSlidingDoors() {
  const frame = 0xFFF1F3F5, rail = 0xFFE2E6EA, glass = 0xAAA9D6E8;
  const trackC = 0xFFB9BDC2;
  for (final def in kOwnDoorDefs) {
    final w = def.w, d = def.d, z0 = def.sill, z1 = def.head;
    const jt = 0.05; // jamb/head thickness
    const lt = 0.04; // leaf frame thickness
    const st = 0.045; // leaf stile/top-rail width
    const br = 0.12; // leaf bottom rail height
    final hw = w / 2, hd = d / 2;
    final f = <Face3>[];
    void box(
      double x0,
      double y0,
      double x1,
      double y1,
      double a,
      double b,
      int c,
    ) => f.addAll(_polyFaces(_bx(x0, y0, x1, y1), a, b, c));
    // outer frame — jambs carry the full reveal depth, head + floor
    // track span the clear opening between them
    box(-hw, -hd, -hw + jt, hd, z0, z1, frame);
    box(hw - jt, -hd, hw, hd, z0, z1, frame);
    box(-hw + jt, -hd, hw - jt, hd, z1 - jt, z1, frame);
    box(-hw + jt, -hd, hw - jt, hd, z0, z0 + 0.02, trackC);
    // two leaves staggered on parallel tracks; the moving leaf sits
    // on the near track like the plan symbol's arrowed panel
    final tr = hd * 0.62;
    final leafW = w / 2 + 0.10; // half the opening + center overlap
    final lz0 = z0 + 0.02, lz1 = z1 - jt;
    void leaf(double x0, double y) {
      final x1 = x0 + leafW;
      final yl = y - lt / 2, yh = y + lt / 2;
      // stiles + rails
      box(x0, yl, x0 + st, yh, lz0, lz1, rail);
      box(x1 - st, yl, x1, yh, lz0, lz1, rail);
      box(x0 + st, yl, x1 - st, yh, lz1 - st, lz1, rail);
      box(x0 + st, yl, x1 - st, yh, lz0, lz0 + br, rail);
      // glass pane inside the leaf frame
      box(x0 + st, y - 0.004, x1 - st, y + 0.004, lz0 + br, lz1 - st, glass);
    }

    leaf(-hw + jt, -tr);
    leaf(hw - jt - leafW, tr);
    blockMeshes[def.id] = f;
    blockMeshTop[def.id] = z1;
    blockMeshBox[def.id] = _aabbOf(f);
  }
}
