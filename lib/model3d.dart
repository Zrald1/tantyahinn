import 'dart:math' as math;

import 'package:flutter/painting.dart' show Offset, Rect;
import 'package:uuid/uuid.dart';

import 'dxf.dart';
import 'models.dart';
import 'obj.dart';
import 'structural.dart';

part 'proc_doors.dart';

const _uuid = Uuid();

/// SketchUp-lite primitives: a building model is a list of [Volume3d] —
/// each one a closed footprint polygon in plan (meters) extruded from
/// [base] to [base] + [height]. From these the app derives the 3D view
/// and auto-generates the drawing sheet: floor plan, roof plan and the
/// four elevations (front / right / rear / left).
class Volume3d {
  String id;
  String name;

  /// Flat [x0, y0, x1, y1, ...] footprint in meters (plan XY). Stored
  /// counter-clockwise (positive shoelace area); `_normFp` fixes order.
  final List<double> fp;
  double base; // m — ground/floor elevation
  double height; // m
  int argb; // 0xFFRRGGBB tint used by the 3D preview

  Volume3d({
    String? id,
    this.name = 'Volume',
    required List<double> footprint,
    this.base = 0,
    this.height = 3.0,
    this.argb = 0xFF90A4AE,
  }) : id = id ?? _uuid.v4(),
       fp = List.of(footprint);

  double get top => base + height;
  int get corners => fp.length ~/ 2;

  /// Signed shoelace area (m²) — positive when CCW.
  double get signedArea {
    var a = 0.0;
    for (var i = 0; i < fp.length; i += 2) {
      final j = (i + 2) % fp.length;
      a += fp[i] * fp[j + 1] - fp[j] * fp[i + 1];
    }
    return a / 2;
  }

  double get area => signedArea.abs();

  /// Footprint bounding box: minX, minY, maxX, maxY (meters).
  (double, double, double, double) get bounds {
    var x0 = fp[0], y0 = fp[1], x1 = fp[0], y1 = fp[1];
    for (var i = 2; i < fp.length; i += 2) {
      x0 = math.min(x0, fp[i]);
      x1 = math.max(x1, fp[i]);
      y0 = math.min(y0, fp[i + 1]);
      y1 = math.max(y1, fp[i + 1]);
    }
    return (x0, y0, x1, y1);
  }

  Offset get center {
    final b = bounds;
    return Offset((b.$1 + b.$3) / 2, (b.$2 + b.$4) / 2);
  }

  bool contains(Offset p) {
    var inside = false;
    for (var i = 0; i < fp.length; i += 2) {
      final j = (i + 2) % fp.length;
      final xi = fp[i], yi = fp[i + 1], xj = fp[j], yj = fp[j + 1];
      if (((yi > p.dy) != (yj > p.dy)) &&
          (p.dx < (xj - xi) * (p.dy - yi) / (yj - yi) + xi)) {
        inside = !inside;
      }
    }
    return inside;
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'fp': fp,
    'base': base,
    'height': height,
    'argb': argb,
  };

  factory Volume3d.fromJson(Map<String, dynamic> j) => Volume3d(
    id: j['id'],
    name: j['name'] ?? 'Volume',
    footprint: [
      for (final v in (j['fp'] as List? ?? [])) (v as num).toDouble(),
    ],
    base: (j['base'] ?? 0).toDouble(),
    height: (j['height'] ?? 3).toDouble(),
    argb: (j['argb'] ?? 0xFF90A4AE).toInt(),
  );
}

/// A straight-run wall: a centerline polyline [x0,y0,x1,y1,...]
/// extruded sideways by [thickness]/2 and up to [height]. This is the
/// floor-plan primitive — the user draws the centerline, the wall's
/// solid is derived (Revit-lite: walls auto-build the 3D).
class Wall3d {
  String id;
  String name;
  final List<double> pts; // centerline, >= 2 points
  double thickness; // m
  double base; // m
  double height; // m
  int argb;

  /// NSCP structural options: [tieBeam] = RC strip under the wall
  /// (bottom, at base), [bondBeam] = RC strip capping the wall top.
  /// Both render as 0.20m concrete bands and feed the takeoff.
  bool tieBeam;
  bool bondBeam;

  Wall3d({
    String? id,
    this.name = 'Wall',
    required List<double> points,
    this.thickness = 0.15,
    this.base = 0,
    this.height = 2.7,
    this.argb = 0xFFB0BEC5,
    this.tieBeam = false,
    this.bondBeam = false,
  }) : id = id ?? _uuid.v4(),
       pts = List.of(points);

  double get top => base + height;
  int get segs => math.max(0, pts.length ~/ 2 - 1);

  double get length {
    var l = 0.0;
    for (var i = 0; i < segs; i++) {
      l += math.sqrt(
        math.pow(pts[i * 2 + 2] - pts[i * 2], 2) +
            math.pow(pts[i * 2 + 3] - pts[i * 2 + 1], 2),
      );
    }
    return l;
  }

  /// The thick rectangle (4 corners) covering segment [i].
  List<Offset> segPoly(int i) {
    final ax = pts[i * 2], ay = pts[i * 2 + 1];
    final bx = pts[i * 2 + 2], by = pts[i * 2 + 3];
    final dx = bx - ax, dy = by - ay;
    final l = math.sqrt(dx * dx + dy * dy);
    if (l < 1e-9) return [Offset(ax, ay)];
    final nx = -dy / l * thickness / 2, ny = dx / l * thickness / 2;
    return [
      Offset(ax + nx, ay + ny),
      Offset(bx + nx, by + ny),
      Offset(bx - nx, by - ny),
      Offset(ax - nx, ay - ny),
    ];
  }

  (double, double, double, double) get bounds {
    var x0 = double.infinity, y0 = double.infinity;
    var x1 = -double.infinity, y1 = -double.infinity;
    for (var i = 0; i < segs; i++) {
      for (final p in segPoly(i)) {
        x0 = math.min(x0, p.dx);
        x1 = math.max(x1, p.dx);
        y0 = math.min(y0, p.dy);
        y1 = math.max(y1, p.dy);
      }
    }
    if (x0 == double.infinity) return (0, 0, 0, 0);
    return (x0, y0, x1, y1);
  }

  /// Distance from [p] to the centerline — hit test is
  /// `distance <= thickness/2 + tol`.
  double distTo(Offset p) {
    var best = double.infinity;
    for (var i = 0; i < segs; i++) {
      final a = Offset(pts[i * 2], pts[i * 2 + 1]);
      final b = Offset(pts[i * 2 + 2], pts[i * 2 + 3]);
      final ab = b - a, ap = p - a;
      final t =
          (ab.dx * ap.dx + ab.dy * ap.dy) /
          math.max(1e-12, ab.dx * ab.dx + ab.dy * ab.dy);
      final q = a + ab * t.clamp(0.0, 1.0);
      best = math.min(best, (p - q).distance);
    }
    return best;
  }

  void translate(double dx, double dy) {
    for (var i = 0; i < pts.length; i += 2) {
      pts[i] += dx;
      pts[i + 1] += dy;
    }
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'pts': pts,
    'thickness': thickness,
    'base': base,
    'height': height,
    'argb': argb,
    if (tieBeam) 'tieBeam': true,
    if (bondBeam) 'bondBeam': true,
  };

  factory Wall3d.fromJson(Map<String, dynamic> j) => Wall3d(
    id: j['id'],
    name: j['name'] ?? 'Wall',
    points: [for (final v in (j['pts'] as List? ?? [])) (v as num).toDouble()],
    thickness: (j['thickness'] ?? 0.15).toDouble(),
    base: (j['base'] ?? 0).toDouble(),
    height: (j['height'] ?? 2.7).toDouble(),
    argb: (j['argb'] ?? 0xFFB0BEC5).toInt(),
    tieBeam: j['tieBeam'] == true,
    bondBeam: j['bondBeam'] == true,
  );
}

/// A placed CAD block (door, window, bed, sofa, ...) — a 2D symbol at
/// [(x,y)] rotated by [rot] radians and sized by [scale]. Blocks live
/// in the floor plan; blocks with a positive library height also show
/// as low prisms in the 3D preview.
class Block3d {
  String id;
  String def; // kCadBlocks id
  double x, y; // plan position (meters, symbol center)
  double rot; // radians
  double scale;
  double sx, sy, sz; // per-axis stretch multipliers (bbox handles)
  double bz; // base lift in meters (bottom-face handle / wall-mount)
  int tint; // 0 = mesh colors; else material color blended over faces
  /// Isolated square footing under this block (columns only) —
  /// auto-sized by `footingSched` from the section, rendered as a
  /// concrete pad whose top pedestal shows above the floor line.
  bool footing;

  /// Manual footing side (m); 0 = auto-size from the column section.
  /// Set by the DESIGN CALC fix button or the inspector size field.
  double footW;

  /// Footing embedment: depth from the block base down to the pad
  /// BOTTOM (m). 0 = standard 0.60 m below grade (NSCP 2015 305.1 /
  /// Table 305-1: 0.60 m for 3+ floors supported).
  double footD;

  /// Truss web bays (truss def only): 0 = auto 4. The parametric mesh
  /// rebuilds verticals/diagonals per panel point — the inspector
  /// stepper and the plan symbol both read this.
  int panels;

  Block3d({
    String? id,
    required this.def,
    required this.x,
    required this.y,
    this.rot = 0,
    this.scale = 1,
    this.sx = 1,
    this.sy = 1,
    this.sz = 1,
    this.bz = 0,
    this.tint = 0,
    this.footing = false,
    this.footW = 0,
    this.footD = 0,
    this.panels = 0,
  }) : id = id ?? _uuid.v4();

  Map<String, dynamic> toJson() => {
    'id': id,
    'def': def,
    'x': x,
    'y': y,
    'rot': rot,
    'scale': scale,
    'sx': sx,
    'sy': sy,
    'sz': sz,
    'bz': bz,
    'tint': tint,
    if (footing) 'footing': true,
    if (footW > 0) 'footW': footW,
    if (footD > 0) 'footD': footD,
    if (panels > 0) 'panels': panels,
  };

  factory Block3d.fromJson(Map<String, dynamic> j) => Block3d(
    id: j['id'],
    def: j['def'] ?? '',
    x: (j['x'] ?? 0).toDouble(),
    y: (j['y'] ?? 0).toDouble(),
    rot: (j['rot'] ?? 0).toDouble(),
    scale: (j['scale'] ?? 1).toDouble(),
    sx: (j['sx'] ?? 1).toDouble(),
    sy: (j['sy'] ?? 1).toDouble(),
    sz: (j['sz'] ?? 1).toDouble(),
    bz: (j['bz'] ?? 0).toDouble(),
    tint: (j['tint'] ?? 0).toInt(),
    footing: j['footing'] == true,
    footW: (j['footW'] ?? 0).toDouble(),
    footD: (j['footD'] ?? 0).toDouble(),
    panels: (j['panels'] ?? 0).toInt(),
  );
}

/// The roof SYSTEM spec shared by every truss/purlin/roof sheet in a
/// model — PH light-steel practice per NSCP-aligned supplier data:
/// the purlin SECTION follows its span (= the truss spacing), the
/// purlin SPACING follows the roofing sheet it carries, and sheets
/// run eave->ridge lapping over the trusses.
/// All fields editable on the model; 0/'' = auto from the tables.
class RoofSpec {
  /// 'C-75'|'C-100'|'C-125'|'C-150'|'C-200' (web depth mm); '' = auto
  /// from the governing truss spacing.
  String purlinSize;

  /// base metal thickness mm: 1.2 | 1.5 | 2.0; 0 = auto with size.
  double purlinThk;

  /// spacing along the roof slope (m); 0 = auto from the roofing
  /// sheet table (0.4mm sheet -> 0.65, 0.5 rib -> 0.85, 0.6 -> 1.0).
  double purlinSpacing;

  /// 'corrugated' | 'rib' | 'tile' | 'seam'
  String roofProfile;

  /// sheet thickness mm: corrugated/rib 0.4|0.5|0.6, tile 0.5, seam 0.6.
  double roofThk;

  /// bay spacing between trusses along the ridge (m); 0 = free
  /// placement / measured gaps. Drives the Array action + the
  /// auto purlin-size table.
  double trussSpacing;

  /// eave overhang past the bearing plate (m).
  double overhang;

  RoofSpec({
    this.purlinSize = '',
    this.purlinThk = 0,
    this.purlinSpacing = 0,
    this.roofProfile = 'rib',
    this.roofThk = 0.5,
    this.trussSpacing = 1.5,
    this.overhang = 0.35,
  });

  static const purlinSizes = ['C-75', 'C-100', 'C-125', 'C-150', 'C-200'];
  static const purlinThks = [1.2, 1.5, 2.0];
  static const roofProfiles = {
    'corrugated': 'Corrugated G.I.',
    'rib': 'Rib-type long-span',
    'tile': 'Tile-span',
    'seam': 'Standing seam',
  };
  static const roofThks = [0.4, 0.5, 0.6];

  /// Flange width of a 'C-nnn' section (supplier table: deeper purlins
  /// get wider flanges).
  static int purlinFlange(String size) =>
      const {'C-75': 50, 'C-100': 50, 'C-125': 50, 'C-150': 65, 'C-200': 65}[size] ??
      50;

  /// kg/m by section+thickness — PH mill spec table (GI coil, lipped).
  static double purlinKgM(String size, double thk) {
    final t = {
      'C-75': {1.2: 1.79, 1.5: 2.27, 2.0: 3.27},
      'C-100': {1.2: 2.03, 1.5: 2.57, 2.0: 3.45},
      'C-125': {1.2: 2.43, 1.5: 2.86, 2.0: 3.85},
      'C-150': {1.2: 2.63, 1.5: 3.16, 2.0: 4.24},
      'C-200': {1.5: 3.80, 2.0: 5.10},
    };
    final row = t[size] ?? t['C-100']!;
    var best = row.keys.first;
    for (final k in row.keys) {
      if ((k - thk).abs() < (best - thk).abs()) best = k;
    }
    return row[best]!;
  }

  /// Auto section+thickness from the purlin SPAN (= truss spacing):
  /// PH low-rise practice — 2x3/C-75 to 3.0m, 2x4/C-100 to 4.5m,
  /// 2x6/C-150 to 6.0m, 2x8/C-200 beyond. NOT a safe-span rating.
  static (String, double) purlinForSpan(double span) => span <= 3.0
      ? ('C-75', 1.2)
      : span <= 4.5
      ? ('C-100', 1.5)
      : span <= 6.0
      ? ('C-150', 1.5)
      : ('C-200', 2.0);

  /// Auto purlin spacing (m along slope) for the sheet: thinner
  /// corrugated drums underfoot so it wants the tight end of the
  /// NSCP 600-800mm band; heavier long-span profiles run to ~1.0m.
  double get purlinSpace {
    if (purlinSpacing > 0) return purlinSpacing;
    return switch (roofProfile) {
      'corrugated' => roofThk <= 0.4
          ? 0.65
          : roofThk <= 0.5
          ? 0.75
          : 0.90,
      'tile' => 0.35, // batten module per tile course
      'seam' => 1.20,
      _ => roofThk <= 0.4
          ? 0.70
          : roofThk <= 0.5
          ? 0.85
          : 1.00, // rib long-span
    };
  }

  /// Effective coverage width (m) of one sheet across the ridge run.
  double get roofEffWidth => switch (roofProfile) {
    'corrugated' => 0.90,
    'tile' => 1.00,
    'seam' => 0.50,
    _ => 1.07, // rib long-span (UGC/Metalink eff. coverage)
  };

  /// Resolved section: the user's pick or the auto table keyed on the
  /// actual measured truss spacing (see [roofFields]).
  (String, double) purlinSection(double measuredSpacing) {
    final auto = purlinForSpan(measuredSpacing > 0 ? measuredSpacing : 1.5);
    final size = purlinSize.isEmpty ? auto.$1 : purlinSize;
    final thk = purlinThk <= 0 ? (purlinSize.isEmpty ? auto.$2 : 1.5) : purlinThk;
    return (size, thk);
  }

  String get purlinLabel {
    final s = purlinSize.isEmpty ? 'C-100' : purlinSize;
    final t = purlinThk <= 0 ? 1.5 : purlinThk;
    return 'C-${s.substring(2)}x${purlinFlange(s)}x${t}mm C-PURLINS';
  }

  String get roofLabel {
    final prof = roofProfiles[roofProfile] ?? 'Rib-type long-span';
    final ga = roofThk <= 0.45
        ? 'Ga.26'
        : roofThk <= 0.55
        ? 'Ga.24'
        : 'Ga.22';
    return '$ga $prof ROOFING';
  }

  /// price_db key for the resolved purlin (matches MaterialPrice names).
  String purlinPriceKey(double measuredSpacing) {
    final s = purlinSection(measuredSpacing);
    return 'C-Purlin ${s.$1.substring(2)}x${purlinFlange(s.$1)}x${s.$2} x6m';
  }

  Map<String, dynamic> toJson() => {
    'purlinSize': purlinSize,
    'purlinThk': purlinThk,
    'purlinSpacing': purlinSpacing,
    'roofProfile': roofProfile,
    'roofThk': roofThk,
    'trussSpacing': trussSpacing,
    'overhang': overhang,
  };

  factory RoofSpec.fromJson(Map<String, dynamic> j) =>
      RoofSpec()..loadFrom(j);

  /// In-place load — `Model3d.roof` is a final field populated the
  /// same way `dims`/`sheetPan` are.
  void loadFrom(Map<String, dynamic> j) {
    purlinSize = j['purlinSize'] ?? '';
    purlinThk = (j['purlinThk'] ?? 0).toDouble();
    purlinSpacing = (j['purlinSpacing'] ?? 0).toDouble();
    roofProfile = j['roofProfile'] ?? 'rib';
    roofThk = (j['roofThk'] ?? 0.5).toDouble();
    trussSpacing = (j['trussSpacing'] ?? 1.5).toDouble();
    overhang = (j['overhang'] ?? 0.35).toDouble();
  }
}

/// A named 3D building model — the unit the MODEL tab library lists.
class Model3d {
  String id;
  String name;
  DateTime addedAt;
  final List<Volume3d> volumes;
  final List<Wall3d> walls;
  final List<Block3d> blocks;

  /// Manual aligned dimensions the user drew with the DIM tool —
  /// each entry is [ax, ay, bx, by] in plan meters. Serialized so
  /// production sheets and reloaded projects keep them.
  final List<List<double>> dims;

  /// Per-sheet content pan in paper-space mm, keyed by SheetView.name —
  /// the user drags the drawing inside its paper frame in the DRAWINGS
  /// tab (the AutoCAD viewport-pan gesture); each view keeps its own
  /// placement across regenerates and project reloads.
  final Map<String, Offset> sheetPan;

  /// The shared roof system (purlins + roofing + truss spacing) —
  /// edited on any truss's inspector, consumed by the roof sheet,
  /// the roofing takeoff and the spec callout.
  final RoofSpec roof;

  Model3d({String? id, this.name = 'New model', DateTime? addedAt})
    : id = id ?? _uuid.v4(),
      addedAt = addedAt ?? DateTime.now(),
      volumes = [],
      walls = [],
      blocks = [],
      dims = [],
      sheetPan = {},
      roof = RoofSpec();

  /// Model envelope: minX, minY, maxX, maxY, maxZ (meters). Null when
  /// the model has no geometry.
  (double, double, double, double, double)? get bounds {
    if (volumes.isEmpty && walls.isEmpty && blocks.isEmpty) return null;
    var x0 = double.infinity, y0 = double.infinity;
    var x1 = -double.infinity, y1 = -double.infinity, z1 = 0.0;
    for (final v in volumes) {
      final b = v.bounds;
      x0 = math.min(x0, b.$1);
      y0 = math.min(y0, b.$2);
      x1 = math.max(x1, b.$3);
      y1 = math.max(y1, b.$4);
      z1 = math.max(z1, v.top);
    }
    for (final w in walls) {
      final b = w.bounds;
      x0 = math.min(x0, b.$1);
      y0 = math.min(y0, b.$2);
      x1 = math.max(x1, b.$3);
      y1 = math.max(y1, b.$4);
      z1 = math.max(z1, w.top);
    }
    for (final bl in blocks) {
      final def = cadBlock(bl.def);
      if (def == null) continue;
      final fp = blockFootprint(bl, def);
      for (final p in fp) {
        x0 = math.min(x0, p.dx);
        x1 = math.max(x1, p.dx);
        y0 = math.min(y0, p.dy);
        y1 = math.max(y1, p.dy);
      }
      // a flagged column footing extends past the column footprint —
      // without it fit-to-content crops the pad the user is editing
      if (bl.footing && (bl.def == 'col-sq' || bl.def == 'col-rd')) {
        final hw = footingFor(def.w * bl.sx * bl.scale, bl.footW).w / 2;
        x0 = math.min(x0, bl.x - hw);
        y0 = math.min(y0, bl.y - hw);
        x1 = math.max(x1, bl.x + hw);
        y1 = math.max(y1, bl.y + hw);
      }
      z1 = math.max(z1, blockHeight(bl, def));
    }
    return (x0, y0, x1, y1, z1);
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'addedAt': addedAt.toIso8601String(),
    'volumes': volumes.map((v) => v.toJson()).toList(),
    'walls': walls.map((w) => w.toJson()).toList(),
    'blocks': blocks.map((b) => b.toJson()).toList(),
    'dims': dims,
    'sheetPan': {
      for (final e in sheetPan.entries) e.key: [e.value.dx, e.value.dy],
    },
    'roof': roof.toJson(),
  };

  factory Model3d.fromJson(Map<String, dynamic> j) {
    final m = Model3d(
        id: j['id'],
        name: j['name'] ?? 'New model',
        addedAt: DateTime.tryParse(j['addedAt'] ?? ''),
      )
      ..volumes.addAll(
        (j['volumes'] as List? ?? []).map(
          (v) => Volume3d.fromJson(Map<String, dynamic>.from(v)),
        ),
      )
      ..walls.addAll(
        (j['walls'] as List? ?? []).map(
          (w) => Wall3d.fromJson(Map<String, dynamic>.from(w)),
        ),
      )
      ..blocks.addAll(
        (j['blocks'] as List? ?? []).map(
          (b) => Block3d.fromJson(Map<String, dynamic>.from(b)),
        ),
      )
      ..dims.addAll(
        (j['dims'] as List? ?? []).map(
          (d) => [for (final v in d as List) (v as num).toDouble()],
        ),
      )
      ..sheetPan.addAll({
        for (final e in (j['sheetPan'] as Map? ?? {}).entries)
          e.key.toString(): Offset(
            ((e.value as List)[0] as num).toDouble(),
            (e.value[1] as num).toDouble(),
          ),
      })
      ..roof.loadFrom(
        Map<String, dynamic>.from(j['roof'] as Map? ?? {}),
      );
    migrateTrusses(m);
    return m;
  }

  /// Face-list cache for the live 3D painter: rebuilding every mesh
  /// transform + face list per repaint made orbiting/hover lag badly.
  /// The signature hashes every geometry-affecting field, so ANY
  /// mutation auto-invalidates without call-site bookkeeping.
  List<Face3>? _facesC;
  int _facesSig = -1;

  int _geomSig() {
    var h = 17;
    void m2(num v) => h = 0x1FFFFFFF & (h * 31 + v.hashCode);
    for (final v in volumes) {
      m2(v.base);
      m2(v.height);
      m2(v.argb);
      m2(v.fp.length);
      for (final p in v.fp) {
        m2(p);
      }
    }
    for (final w in walls) {
      m2(w.thickness);
      m2(w.base);
      m2(w.height);
      m2(w.tieBeam ? 1 : 0);
      m2(w.bondBeam ? 1 : 0);
      m2(w.pts.length);
      for (final p in w.pts) {
        m2(p);
      }
    }
    m2(blockMeshes.length);
    for (final b in blocks) {
      m2(b.def.hashCode);
      // mesh-registry state per block: a missing/added/changed mesh
      // changes what blockFaces emits, so it must invalidate the cache
      m2(blockMeshes[b.def]?.length ?? -1);
      m2(b.x);
      m2(b.y);
      m2(b.rot);
      m2(b.scale);
      m2(b.sx);
      m2(b.sy);
      m2(b.sz);
      m2(b.bz);
      m2(b.tint);
      m2(b.footing ? 1 : 0);
      m2(b.footW);
      m2(b.footD);
    }
    // the roof spec drives derived C-purlin channels in modelFaces —
    // without hashing it a spec edit leaves stale faces cached
    m2(roof.purlinSize.hashCode);
    m2(roof.purlinThk);
    m2(roof.purlinSpacing);
    m2(roof.roofProfile.hashCode);
    m2(roof.roofThk);
    m2(roof.trussSpacing);
    m2(roof.overhang);
    return h;
  }

  List<Face3> cachedFaces() {
    final s = _geomSig();
    if (s != _facesSig) {
      _facesC = modelFaces(this);
      _facesSig = s;
    }
    return _facesC!;
  }
}

/// A flat polygon face in model space (meters) for rendering and
/// elevation projection.
class Face3 {
  /// Vertices [x, y, z].
  final List<List<double>> v;
  final List<double> n; // unit normal
  final int argb;

  /// Object group for the two-level painter's sort: faces of one
  /// object (volume / wall seg / block) share a grp so the depth
  /// sort can never interleave two objects — that interleaving is
  /// what made furniture "merge" through walls while orbiting.
  final int grp;
  const Face3(this.v, this.n, this.argb, [this.grp = 0]);
}

List<double> _norm(List<double> a, List<double> b) {
  final n = [
    a[1] * b[2] - a[2] * b[1],
    a[2] * b[0] - a[0] * b[2],
    a[0] * b[1] - a[1] * b[0],
  ];
  final l = math.sqrt(n[0] * n[0] + n[1] * n[1] + n[2] * n[2]);
  return l < 1e-9 ? [0, 0, 1] : [n[0] / l, n[1] / l, n[2] / l];
}

/// Extrude a closed plan polygon into renderable faces — one side
/// quad per edge plus the top cap. Input is normalized CCW so outward
/// normals are right. Shared by volumes, wall segments and blocks.
List<Face3> _polyFaces(List<Offset> fp, double base, double top, int argb) {
  var area = 0.0;
  for (var i = 0; i < fp.length; i++) {
    final j = (i + 1) % fp.length;
    area += fp[i].dx * fp[j].dy - fp[j].dx * fp[i].dy;
  }
  final pts = area >= 0 ? fp : fp.reversed.toList();
  final h = top - base;
  final n = pts.length;
  final out = <Face3>[];
  for (var i = 0; i < n; i++) {
    final a = pts[i], b = pts[(i + 1) % n];
    final quad = [
      [a.dx, a.dy, base],
      [b.dx, b.dy, base],
      [b.dx, b.dy, top],
      [a.dx, a.dy, top],
    ];
    final e1 = [b.dx - a.dx, b.dy - a.dy, 0.0];
    final e2 = [0.0, 0.0, h];
    out.add(Face3(quad, _norm(e1, e2), argb));
  }
  out.add(
    Face3(
      [
        for (final p in pts) [p.dx, p.dy, top],
      ],
      const [0, 0, 1],
      argb,
    ),
  );
  return out;
}

/// The solid's renderable faces: one quad per footprint edge plus the
/// top cap. Footprints are normalized CCW so outward normals are right.
List<Face3> volumeFaces(Volume3d v) {
  final fp = v.signedArea >= 0 ? v.fp : v.fp.reversed.toList();
  return _polyFaces(
    [for (var i = 0; i < fp.length; i += 2) Offset(fp[i], fp[i + 1])],
    v.base,
    v.top,
    v.argb,
  );
}

/// A wall segment split into solid pieces: opening blocks (doors,
/// windows — `CadBlock.opening`) sitting on the centerline cut real
/// gaps; ends touching another segment (corner or T-junction) grow
/// half the thickness so unions cover the outer-corner notch —
/// "automatically combined edges". Shared by the plan painter,
/// `wallFaces` (3D), and elevations, so all views agree.
List<(double, double)> _segSpans(Model3d m, Wall3d w, int i) {
  final a = Offset(w.pts[i * 2], w.pts[i * 2 + 1]);
  final b = Offset(w.pts[i * 2 + 2], w.pts[i * 2 + 3]);
  final len = (b - a).distance;
  if (len < 1e-9) return const [];
  final dir = (b - a) / len;

  // ---- opening cuts: blocks flagged `opening` whose center sits on
  // the centerline carve a gap spanning their projected width
  final cuts = <(double, double)>[];
  for (final blk in m.blocks) {
    final def = cadBlock(blk.def);
    if (def == null || !def.opening) continue;
    final c = Offset(blk.x, blk.y) - a;
    final cross = (c.dx * -dir.dy + c.dy * dir.dx).abs();
    if (cross > w.thickness * 0.75) continue; // not on this wall
    var lo = double.infinity, hi = -double.infinity;
    for (final p in blockFootprint(blk, def)) {
      final d = p - a;
      final t = d.dx * dir.dx + d.dy * dir.dy;
      lo = math.min(lo, t);
      hi = math.max(hi, t);
    }
    cuts.add((math.max(0.0, lo - 0.02), math.min(len, hi + 0.02)));
  }
  cuts.sort((x, y) => x.$1.compareTo(y.$1));
  final merged = <(double, double)>[];
  for (final c in cuts) {
    if (merged.isNotEmpty && c.$1 <= merged.last.$2 + 1e-6) {
      merged[merged.length - 1] = (
        merged.last.$1,
        math.max(merged.last.$2, c.$2),
      );
    } else {
      merged.add(c);
    }
  }

  // ---- join reach: an end that shares another seg's endpoint or
  // lands mid-span extends until its cap crosses that wall's FAR
  // edge — measured ALONG this seg's direction, so non-orthogonal
  // junctions fill the whole wedge instead of leaving the triangular
  // notch a fixed t/2 cap leaves at any angle but 90deg.
  double joinReach(Offset p) {
    var best = 0.0;
    for (final ow in m.walls) {
      for (var j = 0; j < ow.segs; j++) {
        if (identical(ow, w) && j == i) continue;
        final c = Offset(ow.pts[j * 2], ow.pts[j * 2 + 1]);
        final d = Offset(ow.pts[j * 2 + 2], ow.pts[j * 2 + 3]);
        var touching = (p - c).distance < 0.06 || (p - d).distance < 0.06;
        final s = d - c;
        final l2 = s.dx * s.dx + s.dy * s.dy;
        if (!touching && l2 > 1e-9) {
          final t = ((p.dx - c.dx) * s.dx + (p.dy - c.dy) * s.dy) / l2;
          if (t > 0.02 && t < 0.98) {
            final q = Offset(c.dx + s.dx * t, c.dy + s.dy * t);
            if ((p - q).distance < 0.06) touching = true;
          }
        }
        if (!touching || l2 < 1e-9) continue;
        final tl = math.sqrt(l2);
        // unit normal of the joined seg — edge lines sit at ±t/2
        final tn = Offset(-s.dy / tl, s.dx / tl);
        // denom = dir . n_joined = sin(angle between the walls)
        final denom = dir.dx * tn.dx + dir.dy * tn.dy;
        if (denom.abs() < 0.18) {
          // near-parallel junction: no meaningful far edge — keep the
          // legacy half-thickness nudge rather than exploding
          best = math.max(best, w.thickness / 2);
          continue;
        }
        // p's signed offset from the joined centerline; the cap must
        // travel to the farther of the two edge lines: s = edge/denom
        final off = (p.dx - c.dx) * tn.dx + (p.dy - c.dy) * tn.dy;
        for (final e in [ow.thickness / 2, -ow.thickness / 2]) {
          final reach = (e - off) / denom;
          if (reach > best) best = reach;
        }
      }
    }
    // sanity cap: even a 15deg junction only needs ~2 thicknesses
    return math.min(best, (w.thickness * 4).clamp(0.0, 1.5));
  }

  final extA = joinReach(a);
  final extB = joinReach(b);

  // ---- emit pieces between cuts; outer ends carry the join
  // extension, cut edges stay crisp
  final spans = <(double, double)>[];
  var pos = -extA;
  for (final c in merged) {
    if (c.$1 > pos + 1e-4) spans.add((pos, c.$1));
    pos = c.$2;
  }
  if (len + extB > pos + 1e-4) spans.add((pos, len + extB));
  return spans;
}

/// Seg-level pieces as [a + dir*s] parameter intervals along the
/// centerline — shared by the poly emitter and the dimension-string
/// ordinate collector (which needs REAL boundaries: cut edges and
/// original seg ends, NOT join-extension overshoot or thickness
/// faces).
List<(double, double)> wallSegSpans(Model3d m, Wall3d w, int i) =>
    _segSpans(m, w, i);

List<List<Offset>> wallSegPieces(Model3d m, Wall3d w, int i) {
  final a = Offset(w.pts[i * 2], w.pts[i * 2 + 1]);
  final b = Offset(w.pts[i * 2 + 2], w.pts[i * 2 + 3]);
  final len = (b - a).distance;
  if (len < 1e-9) return const [];
  final dir = (b - a) / len;
  final nx = -dir.dy * w.thickness / 2, ny = dir.dx * w.thickness / 2;
  List<Offset> polyOf(double s0, double s1) {
    final p0 = a + dir * s0, p1 = a + dir * s1;
    return [
      Offset(p0.dx + nx, p0.dy + ny),
      Offset(p1.dx + nx, p1.dy + ny),
      Offset(p1.dx - nx, p1.dy - ny),
      Offset(p0.dx - nx, p0.dy - ny),
    ];
  }

  return [for (final s in _segSpans(m, w, i)) polyOf(s.$1, s.$2)];
}

/// Auto-seat for wall-going blocks: `opening` defs ALWAYS snap their
/// center onto the nearest wall centerline — an unhosted door/window
/// can't cut a wall and just floats dead, so distance is no object.
/// `mountOn` defs hug the wall's near face within a face-distance
/// tolerance. Both align `rot` (RADIANS) to the wall direction — +pi
/// when the point falls on the far side so the swing/front faces the
/// pick — and carry the host wall's `base` as the third field so a
/// block seats at its floor level on upper-storey walls. Shared by
/// placement, drag-end re-seat, and the ghost preview (what you see
/// is where it lands). Null = no wall to host on.
(Offset, double, double)? seatOnWall(Model3d m, CadBlock def, Offset pos) {
  if (!def.opening && !def.mountOn) return null;
  // openings have no distance cap; mounts compare distance-to-FACE so
  // thicker walls get a proportionally wider magnetic band
  var best = def.opening ? double.infinity : 0.55;
  Offset? bestP;
  var brot = 0.0, bz = 0.0;
  for (final wl in m.walls) {
    for (var i = 0; i < wl.segs; i++) {
      final a = Offset(wl.pts[i * 2], wl.pts[i * 2 + 1]);
      final c = Offset(wl.pts[i * 2 + 2], wl.pts[i * 2 + 3]);
      final s = c - a;
      final l2 = s.dx * s.dx + s.dy * s.dy;
      if (l2 < 1e-9) continue;
      final len = math.sqrt(l2);
      final t = (((pos.dx - a.dx) * s.dx + (pos.dy - a.dy) * s.dy) / l2).clamp(
        0.0,
        1.0,
      );
      final q = Offset(a.dx + s.dx * t, a.dy + s.dy * t);
      final d = (pos - q).distance;
      final cmp = def.opening ? d : d - wl.thickness / 2;
      if (cmp < best) {
        best = cmp;
        final side = s.dx * (pos.dy - q.dy) - s.dy * (pos.dx - q.dx);
        brot = math.atan2(s.dy, s.dx);
        var seat = q;
        if (def.mountOn) {
          // hug the clicked face: offset half the wall + half depth
          final nx = -s.dy / len, ny = s.dx / len;
          final sgn = side >= 0 ? 1.0 : -1.0;
          final off = wl.thickness / 2 + def.d / 2 + 0.01;
          seat = Offset(q.dx + nx * off * sgn, q.dy + ny * off * sgn);
        }
        if (side < 0) brot += math.pi;
        bz = wl.base;
        bestP = seat;
      }
    }
  }
  return bestP == null ? null : (bestP, brot, bz);
}

/// Seat a COLUMN onto a wall: its center snaps to the nearest of the
/// segment ENDPOINTS (columns live at wall junctions), the wall
/// CENTERLINE (column embedded in the wall) or a face-flush offset
/// (column face aligned with either wall face) — the user drops the
/// column anywhere near a wall and it lands correctly. Returns the
/// seated position + the wall angle + the host wall's `base` (a
/// column on an upper storey rises to that floor), or null past
/// [tol].
(Offset, double, double)? seatColumnOnWall(
  Model3d m,
  Offset pos,
  double colSec, {
  double tol = 0.55,
}) {
  Offset? bestP;
  var bestD = tol, brot = 0.0, bz = 0.0;
  for (final wl in m.walls) {
    for (var i = 0; i < wl.segs; i++) {
      final a = Offset(wl.pts[i * 2], wl.pts[i * 2 + 1]);
      final c = Offset(wl.pts[i * 2 + 2], wl.pts[i * 2 + 3]);
      final s = c - a;
      final l2 = s.dx * s.dx + s.dy * s.dy;
      if (l2 < 1e-9) continue;
      final len = math.sqrt(l2);
      final rot = math.atan2(s.dy, s.dx);
      for (final e in [a, c]) {
        final d = (pos - e).distance;
        if (d < bestD) {
          bestD = d;
          bestP = e;
          brot = rot;
          bz = wl.base;
        }
      }
      final t = (((pos.dx - a.dx) * s.dx + (pos.dy - a.dy) * s.dy) / l2).clamp(
        0.0,
        1.0,
      );
      final q = Offset(a.dx + s.dx * t, a.dy + s.dy * t);
      final nx = -s.dy / len, ny = s.dx / len;
      final side = nx * (pos.dx - q.dx) + ny * (pos.dy - q.dy);
      // nearest of centerline / inner-face / outer-face offsets
      final flush = wl.thickness / 2 + colSec / 2;
      var off = 0.0;
      for (final cand in [0.0, flush, -flush]) {
        if ((cand - side).abs() < (off - side).abs()) off = cand;
      }
      final seat = Offset(q.dx + nx * off, q.dy + ny * off);
      final d = (pos - seat).distance;
      if (d < bestD) {
        bestD = d;
        bestP = seat;
        brot = rot;
        bz = wl.base;
      }
    }
  }
  return bestP == null ? null : (bestP, brot, bz);
}

/// Seat a BEAM onto a wall: it aligns PARALLEL to the nearest seg's
/// centerline (a beam runs along its support wall), clamped inside
/// the run so it never hangs past a wall end, and rests ON the wall
/// top — its upper face becomes the plate trusses bear on. Returns
/// (position, rotation, baseZ) or null past [tol].
(Offset, double, double)? seatBeamOnWall(
  Model3d m,
  Offset pos,
  double rot,
  double len, {
  double tol = 1.5,
}) {
  Offset? bestP;
  var bestD = tol, brot = 0.0, bz = 0.0;
  for (final wl in m.walls) {
    for (var i = 0; i < wl.segs; i++) {
      final a = Offset(wl.pts[i * 2], wl.pts[i * 2 + 1]);
      final c = Offset(wl.pts[i * 2 + 2], wl.pts[i * 2 + 3]);
      final s = c - a;
      final l2 = s.dx * s.dx + s.dy * s.dy;
      if (l2 < 1e-9) continue;
      final sl = math.sqrt(l2);
      // clamp inside the run — a beam longer than the wall centers on
      // the seg instead of hanging off an end
      final hf = math.min(len, sl) / 2 / sl;
      final t =
          (((pos.dx - a.dx) * s.dx + (pos.dy - a.dy) * s.dy) / l2).clamp(
            hf,
            1 - hf,
          );
      final q = Offset(a.dx + s.dx * t, a.dy + s.dy * t);
      final d = (pos - q).distance;
      if (d < bestD) {
        bestD = d;
        brot = math.atan2(s.dy, s.dx);
        // keep the armed hemisphere so the beam doesn't flip mid-drag
        if (math.cos(brot - rot) < 0) brot += math.pi;
        bz = wl.top;
        bestP = q;
      }
    }
  }
  return bestP == null ? null : (bestP, brot, bz);
}

/// Min distance from [p] to any wall centerline segment — the
/// hover-probe's "is a wall under the cursor" metric (same projection
/// math _seatTrussRaw uses per seg).
double nearestWallDist(Model3d m, Offset p) {
  var bd = double.infinity;
  for (final wl in m.walls) {
    for (var i = 0; i < wl.segs; i++) {
      final a = Offset(wl.pts[i * 2], wl.pts[i * 2 + 1]);
      final c = Offset(wl.pts[i * 2 + 2], wl.pts[i * 2 + 3]);
      final s = c - a;
      final l2 = s.dx * s.dx + s.dy * s.dy;
      if (l2 < 1e-9) continue;
      final t =
          (((p.dx - a.dx) * s.dx + (p.dy - a.dy) * s.dy) / l2).clamp(
        0.0,
        1.0,
      );
      final d = (p - Offset(a.dx + s.dx * t, a.dy + s.dy * t)).distance;
      if (d < bd) bd = d;
    }
  }
  return bd;
}

/// Every BEARING PLATE a truss can rest on, as (start, unit dir,
/// length, top z, key): each wall seg contributes its top plate, and
/// every 'beam' block contributes a seg along its axis whose top is
/// the beam's upper face — a beam laid on a wall top lifts the
/// bearing line by exactly the beam depth. One collector shared by
/// the seat solve's pair/hit/nearest passes AND the multi-axis
/// candidate scan, so walls and beams always agree on what supports.
List<(Offset, Offset, double, double, int)> bearingSegs(Model3d m) {
  final segs = <(Offset, Offset, double, double, int)>[];
  var k = 0;
  for (final wl in m.walls) {
    for (var i = 0; i < wl.segs; i++, k++) {
      final a = Offset(wl.pts[i * 2], wl.pts[i * 2 + 1]);
      final c = Offset(wl.pts[i * 2 + 2], wl.pts[i * 2 + 3]);
      final s = c - a;
      final len = s.distance;
      if (len < 1e-9) continue;
      segs.add((a, s / len, len, wl.top, k));
    }
  }
  for (final bl in m.blocks) {
    if (!isBeamDef(bl.def)) continue;
    final d = cadBlock(bl.def);
    if (d == null) continue;
    final len = d.w * bl.sx * bl.scale;
    if (len < 1e-9) continue;
    final u = Offset(math.cos(bl.rot), math.sin(bl.rot));
    segs.add((
      Offset(bl.x, bl.y) - u * len / 2,
      u,
      len,
      bl.bz + d.height * bl.sz * bl.scale,
      k++,
    ));
  }
  return segs;
}

/// Seat lift: a truss mesh draws its bottom chord CENTERED on the
/// block's z=0 plane, so the chord underside sits half a chord
/// (~0.05 m) below bz. The public seat returns support-top + this
/// lift — the chord UNDERSIDE rests flush on the plate (bearing on
/// the wall, not sinking half a member into it).
const double kTrussSeatLift = 0.05;

/// Ridge-slide bounds: given the projection parameter [t0] of a truss
/// end on a plate seg and the slide rate [k] (how much t moves per
/// metre of ridge travel), the λ interval keeping t in [0,1] — i.e.
/// where along the wall run the seat may sit before the end slides
/// off the plate's end.
(double, double) _lamRange(double t0, double k) =>
    k > 0 ? (-t0 / k, (1 - t0) / k) : ((1 - t0) / k, -t0 / k);

/// Seat a ROOF TRUSS: it bears on wall TOP PLATES at its two ends —
/// never floats at floor height (the old bug: a truss dropped mid-air
/// at door level). The span's two bearing ends each look for the
/// nearest wall segment within [tol]; both hit -> rot connects the
/// bearing projections and bz = the higher top plate; one hit seats
/// bz at that wall's top and turns the span perpendicular to it
/// (bearing plate runs ALONG the wall); none -> null (free drop,
/// caller falls back to [volumeTopAt]/ground).
/// Raw bearing solve. [pos]/[rot] are the requested drop. The pair
/// solve tries every PARALLEL plate pair: the span LINE through pos
/// intersects each plate line — the plates dictate the bearing
/// (out-to-out, so a truss shorter than the room still seats and the
/// caller stretches it to fit). The seat centers between its plates,
/// then slides along the ridge until both ends land IN-RUN on their
/// segs — a hover past a wall end clamps to the nearest real bay
/// instead of perching off the corner (the Revit rule: both truss
/// endpoints always land on load-bearing elements). The probe must
/// lie within the corridor the pair frames (bearing/2 + tol) so a
/// far-away pair can't teleport the drop. Returns (position,
/// rotation, wallTopZ, reach) or null off-wall — `reach` = the
/// bearing distance of a real two-plate span (0 marks a single-wall
/// perch) so the multi-axis seat can compare the axes and callers
/// can auto-fit the stretch.
(Offset, double, double, double)? _seatTrussRaw(
  Model3d m,
  Offset pos,
  double rot,
  double span, {
  double tol = 1.2,
  // requireSpan: only a real two-plate span counts — used by the load
  // migration, where a 4m reach onto a single interior stub produced
  // perpendicular "seats" at nonsense orientations
  bool requireSpan = false,
}) {
  // every bearing seg once: (start, unit dir, len, top, key) — wall
  // top plates AND beam-block top faces share the list
  final segs = bearingSegs(m);
  // nearest bearing seg to point -> (proj on centerline, seg angle,
  // plate top)
  (Offset, double, double)? nearest(Offset p) {
    var bd = tol;
    (Offset, double, double)? r;
    for (final sg in segs) {
      final t =
          (((p.dx - sg.$1.dx) * sg.$2.dx + (p.dy - sg.$1.dy) * sg.$2.dy) /
                  sg.$3)
              .clamp(0.0, 1.0);
      final q = Offset(sg.$1.dx + sg.$2.dx * sg.$3 * t,
          sg.$1.dy + sg.$2.dy * sg.$3 * t);
      final d = (p - q).distance;
      if (d < bd) {
        bd = d;
        r = (q, math.atan2(sg.$2.dy, sg.$2.dx), sg.$4);
      }
    }
    return r;
  }

  // all bearing segs within tol of [p]: (proj on centerline, seg angle,
  // plate top, distance). An end can sit near an INTERSECTION where a
  // span-parallel seg ties the proper bearing seg — only looking at
  // the single nearest let the wrong seg poison the pair (the
  // perch-on-edge mess), so every candidate pair is tried.
  List<(Offset, double, double, double)> hits(Offset p) {
    final out = <(Offset, double, double, double)>[];
    for (final sg in segs) {
      final t =
          (((p.dx - sg.$1.dx) * sg.$2.dx + (p.dy - sg.$1.dy) * sg.$2.dy) /
                  sg.$3)
              .clamp(0.0, 1.0);
      final q = Offset(sg.$1.dx + sg.$2.dx * sg.$3 * t,
          sg.$1.dy + sg.$2.dy * sg.$3 * t);
      final d = (p - q).distance;
      if (d < tol) {
        out.add((q, math.atan2(sg.$2.dy, sg.$2.dx), sg.$4, d));
      }
    }
    return out;
  }

  final u = Offset(math.cos(rot), math.sin(rot));
  final e1 = pos - u * span / 2, e2 = pos + u * span / 2;
  double tAt(Offset a, Offset s, double len, Offset e) =>
      ((e.dx - a.dx) * s.dx + (e.dy - a.dy) * s.dy) / len;
  // OUT-TO-OUT solve (Medeek/Chief Architect rule): the bearing walls
  // dictate the span — the truss STRETCHES to whatever out-to-out the
  // plate pair holds, the caller fits b.sx to the returned bearing.
  // Testing fixed ends at pos±u·span/2 was the bug: a 4m truss in a
  // 5.5m room could NEVER reach the plates, so every axis failed and
  // the seat fell back to an outward perch. Instead the span LINE
  // through pos at this axis is intersected with each plate's line —
  // the intersection params ARE the truss ends, always ON the plates.
  // t = param along u where the span line crosses the plate line.
  double? lineCross(Offset a, Offset d) {
    final den = d.dx * u.dy - d.dy * u.dx;
    if (den.abs() < 1e-9) return null; // axis ~parallel to the plate
    return (d.dx * (a.dy - pos.dy) - d.dy * (a.dx - pos.dx)) / den;
  }

  // fit range: a truss may stretch to 2x its design span (panels grow
  // via the fink-family auto-count) but never past a 24m single piece
  final cap = math.min(math.max(span * 2.0, span + 2.0), 24.0);
  (Offset, double, double, double)? best;
  var bw = 0.0;
  var bTop = -double.infinity;
  for (final sa in segs) {
    final aA = math.atan2(sa.$2.dy, sa.$2.dx);
    // this axis must run ~PERPENDICULAR to the plate: >58° — armed
    // diagonal rots don't produce skewed staggered-bearing spans;
    // the two wall-family axes always pass on their own family
    if ((math.sin(rot - aA)).abs() < 0.85) continue;
    final tA = lineCross(sa.$1, sa.$2);
    if (tA == null) continue;
    for (final sb in segs) {
      if (sa.$5 == sb.$5) continue; // needs two DIFFERENT plates
      // bearing plates PARALLEL to each other — no corner diagonals
      if ((math.cos(aA - math.atan2(sb.$2.dy, sb.$2.dx))).abs() < 0.85) {
        continue;
      }
      final tB = lineCross(sb.$1, sb.$2);
      if (tB == null) continue;
      final bearing = (tB - tA).abs();
      if (bearing < 0.3 || bearing > cap) continue;
      // center the truss BETWEEN its plates — the seat slides along
      // the span so both ends land on their plate lines
      final mid = pos + u * ((tA + tB) / 2);
      // corridor bound: the probe must sit in/near the band this pair
      // frames — a far-away corridor can't teleport the drop
      if ((mid - pos).distance > bearing / 2 + tol) continue;
      // slide along the RIDGE until both endpoints land IN-RUN on
      // their wall segs — a hover past a wall end clamps to the
      // nearest real bay (gable-end truss), never an outward perch
      final rd = sa.$2; // ridge slide direction = plate direction
      final lA = _lamRange(
        tAt(sa.$1, sa.$2, sa.$3, pos + u * tA),
        (rd.dx * sa.$2.dx + rd.dy * sa.$2.dy) / sa.$3,
      );
      final lB = _lamRange(
        tAt(sb.$1, sb.$2, sb.$3, pos + u * tB),
        (rd.dx * sb.$2.dx + rd.dy * sb.$2.dy) / sb.$3,
      );
      final lo = math.max(lA.$1, lB.$1), hi = math.min(lA.$2, lB.$2);
      if (lo > hi) continue; // no ridge position bears on both
      final lam = lo > 0 ? lo : (hi < 0 ? hi : 0.0);
      if (lam.abs() > math.max(span, tol * 2)) continue;
      // widest pair wins; on a distance TIE the higher plate bears
      // the truss — a beam laid on a wall top lifts the seat to its
      // own top, not the wall's
      final top = math.max(sa.$4, sb.$4);
      if (bearing < math.max(0.3, bw) - 1e-9) continue;
      if (best != null && bearing <= bw + 1e-9 && top <= bTop + 1e-9) {
        continue;
      }
      bw = bearing;
      bTop = top;
      // ends face whichever way u runs from plate A to plate B
      final sgn = tB >= tA ? 1.0 : -1.0;
      best = (
        mid + rd * lam,
        math.atan2(u.dy * sgn, u.dx * sgn),
        top,
        bw,
      );
    }
  }
  if (best != null) return best;
  if (requireSpan) return null;
  // perch: the closest plate the truss reaches (prefer an end's hit
  // over the center probe — the truss hangs off that wall). reach=0:
  // a perch always loses to any real span in the multi-axis solve
  (Offset, double, double, double)? perch;
  {
    var pd = tol;
    for (final h in [...hits(e1), ...hits(e2)]) {
      if (h.$4 < pd) {
        pd = h.$4;
        perch = (h.$1, h.$2, h.$3, 0.0);
      }
    }
    if (perch == null) {
      final near = nearest(pos);
      if (near != null) perch = (near.$1, near.$2, near.$3, 0.0);
    }
  }
  if (perch == null) return null;
  // single wall in reach: the truss spans ACROSS it, centered on the
  // plate projection — pinpointed on the wall, not left at the raw
  // drop point. Span perpendicular; keep the current hemisphere so
  // the seat doesn't flip 180° while dragging
  var r = perch.$2 + math.pi / 2;
  if (math.cos(r - rot) < 0) r += math.pi;
  // INWARD BIAS: when the armed rot is ~parallel to the plate the
  // hemisphere is ambiguous — a perch on an exterior wall should hang
  // INTO the building, not cantilever past the wall face. Prefer the
  // far end with more wall support nearby.
  if ((math.cos(r - rot)).abs() < 0.35) {
    final uu = Offset(math.cos(r), math.sin(r));
    if (nearestWallDist(m, perch.$1 - uu * span / 2) <
        nearestWallDist(m, perch.$1 + uu * span / 2)) {
      r += math.pi;
    }
  }
  return (perch.$1, r, perch.$3, 0.0);
}

/// Public seat: raw bearing solve, then RIDGE-GRID SNAP — the seat
/// slides along the ridge direction to the nearest roof.trussSpacing
/// bay measured from the closest truss already on the same bearing
/// line. A bay that is already taken pushes the snap one bay out in
/// the cursor's direction, so a second truss can never land inside
/// an existing one (the "two trusses read as doubled members" bug).
/// Off-grid candidates (>0.55 sp from a bay) keep the free seat, so
/// deliberate non-bay placements still work. [ignore] = the block
/// being moved/pasted — it's in m.blocks already and must not anchor
/// the grid to itself.
/// Returns (position, rotation, baseZ, bearing): `baseZ` = plate top
/// + [kTrussSeatLift] so the bottom chord's UNDERSIDE rests flush on
/// the plate (a wall top or a beam's upper face). `bearing` is the
/// out-to-out plate distance the seat spans — callers auto-fit the
/// truss stretch to it via [trussFitSx] so both ends actually reach
/// the plates (0 on a perch: leave sx alone).
(Offset, double, double, double)? seatTrussOnWalls(
  Model3d m,
  Offset pos,
  double rot,
  double span, {
  double tol = 1.2,
  Block3d? ignore,
  bool requireSpan = false,
}) {
  // TWO-OPTION hover: solve the drop on EVERY orthogonal span axis —
  // the armed rot AND the perpendicular of each wall-direction family
  // — so a rectilinear building always evaluates "span across the
  // horizontal walls" AND "span across the vertical walls". Only
  // trying the block's stored rot is what used to perch a truss
  // hanging diagonally off whatever wall sat under the cursor. Any
  // real two-plate span beats a perch; among spans the SHORTER bearing
  // distance wins — that's the axis real trusses frame; remaining
  // ties go to the seat nearest the pointer.
  double fold(double a) {
    var r = a % math.pi;
    return r < 0 ? r + math.pi : r;
  }

  final cands = <double>{fold(rot), fold(rot + math.pi / 2)};
  for (final sg in bearingSegs(m)) {
    // the SPAN axis that bears on this plate family runs across it
    cands.add(fold(math.atan2(sg.$2.dy, sg.$2.dx) + math.pi / 2));
  }
  (Offset, double, double, double)? seat;
  for (final cand in cands) {
    final s = _seatTrussRaw(
      m,
      pos,
      cand,
      span,
      tol: tol,
      requireSpan: requireSpan,
    );
    if (s == null) continue;
    // pick order: a real span beats a perch (reach 0); among spans
    // the SHORTER bearing distance wins — trusses frame the short
    // direction of a room (the perpendicular axis the hover was
    // missing). Ties + perches break to the seat nearest the pointer.
    final sSpan = s.$4 > 0, oSpan = seat?.$4 != null && seat!.$4 > 0;
    if (seat == null ||
        (sSpan && !oSpan) ||
        (sSpan &&
            oSpan &&
            (s.$4 < seat.$4 - 1e-9 ||
                ((s.$4 - seat.$4).abs() <= 1e-9 &&
                    (s.$1 - pos).distance <
                        (seat.$1 - pos).distance - 1e-9))) ||
        (!sSpan &&
            !oSpan &&
            (s.$1 - pos).distance < (seat.$1 - pos).distance - 1e-9)) {
      seat = s;
    }
  }
  if (seat == null) return null;
  final (c, r, top) = (seat.$1, seat.$2, seat.$3);
  final rd = Offset(-math.sin(r), math.cos(r)); // along the ridge
  final perp = Offset(math.cos(r), math.sin(r)); // along the span
  final v = c.dx * perp.dx + c.dy * perp.dy;
  var u = c.dx * rd.dx + c.dy * rd.dy;
  // trusses already seated on the same bearing line (same span dir v,
  // same rot bucket — the roofFields clustering contract)
  final us = <double>[
    for (final b in m.blocks)
      if (isTrussDef(b.def) &&
          !identical(b, ignore) &&
          math.cos(b.rot - r).abs() > 0.96 &&
          ((b.x * perp.dx + b.y * perp.dy) - v).abs() < 0.6)
        b.x * rd.dx + b.y * rd.dy,
  ]..sort();
  // the returned bz = plate top + the bottom-chord lift — the chord
  // underside bears flush on the plate instead of sinking into it
  final seat3 = (seat.$1, seat.$2, seat.$3 + kTrussSeatLift, seat.$4);
  if (us.isEmpty) return seat3;
  final sp = m.roof.trussSpacing > 0 ? m.roof.trussSpacing : 1.5;
  var ref = us.first, bd = (u - ref).abs();
  for (final q in us) {
    final d = (u - q).abs();
    if (d < bd) {
      bd = d;
      ref = q;
    }
  }
  var n = ((u - ref) / sp).round();
  if ((u - (ref + n * sp)).abs() > sp * 0.55) return seat3; // free bay
  bool occupied(double uu) =>
      us.any((q) => (q - uu).abs() < math.min(0.35, sp * 0.45));
  // walk outward in the cursor's direction to the first free cell
  final dir = (u - ref) >= 0 ? 1 : -1;
  var k = n, hops = 0;
  while (occupied(ref + k * sp) && hops++ < 8) {
    k += dir;
  }
  if (occupied(ref + k * sp)) return seat3; // crowded line: keep free
  final du = ref + k * sp - u;
  if (du.abs() < 1e-6) return seat3;
  // the snapped point must still bear — re-seat at it and keep the
  // result only when it lands on the same wall family (rot + top)
  final re = _seatTrussRaw(
    m,
    c + rd * du,
    r,
    span,
    tol: tol,
    requireSpan: requireSpan,
  );
  // cos(2d): truss orientation is modulo pi — a re-seat returning
  // -pi/2 where r is +pi/2 is the SAME truss, not a 3.14-rad flip
  if (re == null ||
      math.cos(2 * (re.$2 - r)) < 0.825 ||
      (re.$3 - top).abs() > 0.6) {
    return seat3;
  }
  return (re.$1, re.$2, re.$3 + kTrussSeatLift, re.$4);
}

/// Out-to-out auto-fit (Medeek/Chief Architect rule): the wall pair
/// dictates the truss span — stretch the block so its ends cover the
/// seat's returned bearing exactly. bearing<=0 (a single-wall perch)
/// leaves the stretch alone.
double trussFitSx(double scale, double defW, double bearing) =>
    (bearing / (defW * scale)).clamp(0.25, 8.0);

/// Does [b] count as part of a ROOF (fields, purlins, tags, sheets,
/// takeoff)? Only when it's actually bearing: seated on wall top
/// plates near its stored placement, or elevated >0.5m (on beams /
/// massing — those aren't modeled, trust the height). A truss lying
/// on the ground away from plates is a stored/spare piece — it must
/// never grow a roof field of its own (the user's ground-scattered
/// trusses each sprayed a phantom field + 7 purlin runs).
bool trussInRoof(Model3d m, Block3d b) {
  if (!isTrussDef(b.def)) return false;
  final def = cadBlock(b.def);
  if (def == null) return false;
  if (b.bz > 0.5) return true;
  final seat = _seatTrussRaw(
    m,
    Offset(b.x, b.y),
    b.rot,
    def.w * b.sx * b.scale,
    tol: 0.9,
  );
  return seat != null && (seat.$3 - b.bz).abs() < 0.5;
}

/// True when another truss already sits within ~half a bay of [pos] —
/// placing there stacks them into the doubled/tripled trusses the
/// user reported. Shared by place/move/paste so NO path can stack;
/// [ignore] = the block being moved (it's already in m.blocks).
bool trussSpotTaken(Model3d m, Offset pos, {Block3d? ignore}) {
  final lim = math.min(
    0.45,
    (m.roof.trussSpacing > 0 ? m.roof.trussSpacing : 1.5) * 0.45,
  );
  return m.blocks.any(
    (b) =>
        isTrussDef(b.def) &&
        !identical(b, ignore) &&
        (Offset(b.x, b.y) - pos).distance < lim,
  );
}

/// One-time repair for projects saved before the wall-seat / stack-
/// guard fixes ran on every placement path (the user's autosave held
/// wild rotations, a triple-stacked bay, and ground-scattered trusses
/// that each sprayed a phantom roof field). For every stored truss:
/// 1. rot normalizes into [0, pi) — a truss's orientation is modulo
///    pi, and legacy drops stored -4.73 / 7.85 rad which bucketed as
///    different roof orientations;
/// 2. a truss that is NOT bearing tries a wide reseat (4 m) — strays
///    dragged off their plates snap onto a free ridge bay; genuinely
///    stranded pieces (no wall in reach) stay as stored/spare parts;
///    an elevated truss keeps its height guess if the seat would
///    drop it >1 m (stepped roofs are legit, we only fix the XY);
/// 3. afterwards, trusses still inside another's spot+elevation are
///    dropped — two trusses sharing a bay is physically impossible,
///    those stacks are the "double truss" the user sees. First in
///    file order keeps the bay.
/// Runs inside fromJson so every load path (open, autosave restore,
/// project tabs) heals the same way.
void migrateTrusses(Model3d m) {
  final ts = [for (final b in m.blocks) if (isTrussDef(b.def)) b];
  if (ts.isEmpty) return;
  for (final b in ts) {
    var r = b.rot % math.pi;
    if (r < 0) r += math.pi;
    b.rot = r;
  }
  bool bears(Block3d b, double span) {
    final t = _seatTrussRaw(m, Offset(b.x, b.y), b.rot, span, tol: 0.9);
    return t != null && (t.$3 - b.bz).abs() < 0.5;
  }

  // dominant orientation = median rot of the bearing trusses. Every
  // truss then tries a REAL SPAN solve at that orientation from where
  // it stands — the widest-pair seat pulls it onto the same eave line
  // the coherent trusses use, instead of perching on whichever wall
  // edge was nearest (that perching is what fractured the user's
  // autosave into five single-truss fields at five angles).
  double? domRot;
  {
    final rots = <double>[
      for (final b in ts)
        if (cadBlock(b.def) != null &&
            bears(b, cadBlock(b.def)!.w * b.sx * b.scale))
          b.rot,
    ]..sort();
    if (rots.isNotEmpty) domRot = rots[rots.length ~/ 2];
  }
  for (final b in ts) {
    final def = cadBlock(b.def);
    if (def == null) continue;
    final span = def.w * b.sx * b.scale;
    final p = Offset(b.x, b.y);
    (Offset, double, double, double)? seat;
    // 1) join the dominant roof: a real span at the dominant rot —
    //    |cos| because a span solve returns atan2 raw and truss
    //    orientation is modulo pi. Applies even to "bearing" trusses:
    //    a perch on a wall edge still moves to the coherent span.
    if (domRot != null) {
      final s = seatTrussOnWalls(
        m,
        p,
        domRot,
        span,
        tol: span,
        ignore: b,
        requireSpan: true,
      );
      if (s != null && math.cos(s.$2 - domRot).abs() > 0.86) {
        seat = s;
      }
    }
    // 2) fallback for NON-bearing trusses only: a real two-plate span
    //    in the truss's own direction — single-wall perpendicular
    //    seats on a wide reach are what made the crossing mess.
    //    Bearing trusses that can't join the dominant line keep
    //    their seat (a legit second roof facet).
    if (seat == null && !bears(b, span)) {
      seat = seatTrussOnWalls(
        m,
        p,
        b.rot,
        span,
        tol: 2.0,
        ignore: b,
        requireSpan: true,
      );
    }
    if (seat == null) continue;
    if (b.bz > 0.5 && (seat.$3 - b.bz).abs() > 1.0) continue;
    b.x = seat.$1.dx;
    b.y = seat.$1.dy;
    var r2 = seat.$2 % math.pi;
    if (r2 < 0) r2 += math.pi;
    b.rot = r2;
    b.bz = seat.$3;
    if (seat.$4 > 0) {
      b.sx = trussFitSx(b.scale, def.w, seat.$4); // reach both plates
    }
  }
  final lim = math.min(
    0.45,
    (m.roof.trussSpacing > 0 ? m.roof.trussSpacing : 1.5) * 0.45,
  );
  final kept = <Block3d>[];
  for (final b in ts) {
    final stacked = kept.any(
      (k) =>
          (Offset(k.x, k.y) - Offset(b.x, b.y)).distance < lim &&
          (k.bz - b.bz).abs() < 0.4,
    );
    if (stacked) {
      m.blocks.remove(b);
    } else {
      kept.add(b);
    }
  }
}

/// Highest volume top under [w] — where a free-space drop lands (the
/// slab/massing "on face" contract walls give wall-going defs).
/// -infinity when the point is over bare ground.
double volumeTopAt(Model3d m, Offset w) {
  var top = -double.infinity;
  for (final v in m.volumes) {
    if (v.contains(w) && v.top > top) top = v.top;
  }
  return top;
}

/// A wall's renderable faces: every centerline segment extrudes as
/// its own prism — corners overlap slightly, which reads as a joined
/// wall both in the preview and in the elevations.
List<Face3> wallFaces(Wall3d w) {
  final out = <Face3>[];
  for (var i = 0; i < w.segs; i++) {
    out.addAll(_polyFaces(w.segPoly(i), w.base, w.top, w.argb));
  }
  return out;
}

/// Wall faces WITH join-extension and opening cuts — the live model
/// path (plan, 3D, elevations). [wallFaces] stays the raw per-seg
/// extrusion used by tests and the sheet generator's per-wall calls.
List<Face3> wallFacesJoined(Model3d m, Wall3d w) {
  final out = <Face3>[];
  for (var i = 0; i < w.segs; i++) {
    for (final p in wallSegPieces(m, w, i)) {
      out.addAll(_polyFaces(p, w.base, w.top, w.argb));
    }
    out.addAll(_openingBands(m, w, i));
  }
  return out;
}

/// Solid wall left ABOVE each opening's head (lintel) and BELOW its
/// sill (window apron) — the plan gap is full-length, but in 3D a
/// window only removes the 0.90..2.10 m band and a door everything
/// under 2.10 m.
List<Face3> _openingBands(Model3d m, Wall3d w, int i) {
  final a = Offset(w.pts[i * 2], w.pts[i * 2 + 1]);
  final b = Offset(w.pts[i * 2 + 2], w.pts[i * 2 + 3]);
  final len = (b - a).distance;
  if (len < 1e-9) return const [];
  final dir = (b - a) / len;
  final nx = -dir.dy * w.thickness / 2, ny = dir.dx * w.thickness / 2;
  final out = <Face3>[];
  for (final blk in m.blocks) {
    final def = cadBlock(blk.def);
    if (def == null || !def.opening) continue;
    final c = Offset(blk.x, blk.y) - a;
    if ((c.dx * -dir.dy + c.dy * dir.dx).abs() > w.thickness * 0.75) continue;
    var lo = double.infinity, hi = -double.infinity;
    for (final p in blockFootprint(blk, def)) {
      final d = p - a;
      final t = d.dx * dir.dx + d.dy * dir.dy;
      lo = math.min(lo, t);
      hi = math.max(hi, t);
    }
    lo = math.max(0.0, lo - 0.02);
    hi = math.min(len, hi + 0.02);
    if (hi - lo < 1e-4) continue;
    final k = blk.sz * blk.scale;
    final zl = def.sill * k + blk.bz, zh = def.head * k + blk.bz;
    final p0 = a + dir * lo, p1 = a + dir * hi;
    List<Offset> poly() => [
      Offset(p0.dx + nx, p0.dy + ny),
      Offset(p1.dx + nx, p1.dy + ny),
      Offset(p1.dx - nx, p1.dy - ny),
      Offset(p0.dx - nx, p0.dy - ny),
    ];
    if (zl > w.base + 1e-3) {
      out.addAll(_polyFaces(poly(), w.base, math.min(zl, w.top), w.argb));
    }
    if (zh < w.top - 1e-3) {
      out.addAll(_polyFaces(poly(), math.max(zh, w.base), w.top, w.argb));
    }
  }
  return out;
}

/// The standard architectural block library (researched against the
/// First In Architecture / Cadtorial / CADdillo sets): plan symbols at
/// real size in meters, centered on the insertion point, facing +Y.
/// [height] is the block's extrusion height for the 3D dollhouse —
/// 0 means a flat on-wall symbol (doors, windows).
class CadBlock {
  final String id, name;
  final String cat; // library group for the palette panel
  final double w, d; // overall plan size, meters
  final double height; // 3D extrusion height (m)
  final List<List<Offset>> lines; // local polylines
  /// true for doors/windows/doorways that pierce a wall — the wall
  /// renderer cuts a gap where one is placed (plan AND 3D)
  final bool opening;

  /// true for wall-hung blocks (TV, picture, vanity) — dropped near a
  /// wall they hug the near face and align their width to it
  final bool mountOn;

  /// opening z-range above the floor (m): doors 0..2.10, windows
  /// 0.90..2.10 (standard domestic sill/head — head lines up with the
  /// door heads). The wall keeps solid below the sill and above the
  /// head in 3D.
  final double sill, head;
  const CadBlock(
    this.id,
    this.name,
    this.cat,
    this.w,
    this.d,
    this.height,
    this.lines, {
    this.opening = false,
    this.mountOn = false,
    this.sill = 0,
    this.head = 2.1,
  });
}

List<Offset> _arc(
  double cx,
  double cy,
  double r,
  double a0,
  double a1, [
  int n = 8,
]) {
  final out = <Offset>[];
  for (var i = 0; i <= n; i++) {
    final a = (a0 + (a1 - a0) * i / n) * math.pi / 180;
    out.add(Offset(cx + r * math.cos(a), cy + r * math.sin(a)));
  }
  return out;
}

/// Closed rect polyline — terse plan symbol for simple footprints.
List<Offset> _rect(double w, double d) => [
  Offset(-w / 2, -d / 2),
  Offset(w / 2, -d / 2),
  Offset(w / 2, d / 2),
  Offset(-w / 2, d / 2),
  Offset(-w / 2, -d / 2),
];

final kCadBlocks = <CadBlock>[
  // ---- Openings (flat symbols, drawn on walls) ----
  CadBlock('door-090', 'Door 0.90', 'Openings', 0.9, 0.9, 0, [
    // architectural symbol: jamb line + ticks, leaf shown 35° open
    // as a thin leaf (hinge right), arc sweeping to the closed line
    [const Offset(-0.45, 0), const Offset(0.45, 0)],
    [const Offset(-0.45, -0.1), const Offset(-0.45, 0.1)],
    [const Offset(0.45, -0.1), const Offset(0.45, 0.1)],
    [
      const Offset(0.47, 0.029),
      const Offset(-0.267, 0.545),
      const Offset(-0.307, 0.487),
      const Offset(0.43, -0.029),
      const Offset(0.47, 0.029),
    ],
    _arc(0.45, 0, 0.9, 145, 180),
  ], opening: true),
  CadBlock('door-dbl', 'Double door 1.50', 'Openings', 1.5, 0.75, 0, [
    [const Offset(-0.75, 0), const Offset(0.75, 0)],
    [const Offset(-0.75, -0.1), const Offset(-0.75, 0.1)],
    [const Offset(0.75, -0.1), const Offset(0.75, 0.1)],
    [
      const Offset(0.77, 0.029),
      const Offset(0.156, 0.459),
      const Offset(0.116, 0.402),
      const Offset(0.73, -0.029),
      const Offset(0.77, 0.029),
    ],
    [
      const Offset(-0.77, 0.029),
      const Offset(-0.116, 0.402),
      const Offset(-0.156, 0.459),
      const Offset(-0.73, -0.029),
      const Offset(-0.77, 0.029),
    ],
    _arc(0.75, 0, 0.75, 145, 180),
    _arc(-0.75, 0, 0.75, 0, 35),
  ], opening: true),
  CadBlock(
    'window-120',
    'Window 1.20',
    'Openings',
    1.2,
    0.2,
    0,
    [
      [
        const Offset(-0.6, -0.1),
        const Offset(0.6, -0.1),
        const Offset(0.6, 0.1),
        const Offset(-0.6, 0.1),
        const Offset(-0.6, -0.1),
      ],
      [const Offset(-0.6, -0.033), const Offset(0.6, -0.033)],
      [const Offset(-0.6, 0.033), const Offset(0.6, 0.033)],
    ],
    opening: true,
    sill: 0.9,
  ),
  CadBlock(
    'window-slide',
    'Sliding window 1.80',
    'Openings',
    1.8,
    0.2,
    0,
    [
      [
        const Offset(-0.9, -0.1),
        const Offset(0.9, -0.1),
        const Offset(0.9, 0.1),
        const Offset(-0.9, 0.1),
        const Offset(-0.9, -0.1),
      ],
      [const Offset(-0.9, -0.033), const Offset(0.9, -0.033)],
      [const Offset(-0.9, 0.033), const Offset(0.9, 0.033)],
    ],
    opening: true,
    sill: 0.9,
  ),
  CadBlock(
    'window-fixed',
    'Fixed window 1.20',
    'Openings',
    1.2,
    0.2,
    0,
    [
      [
        const Offset(-0.6, -0.1),
        const Offset(0.6, -0.1),
        const Offset(0.6, 0.1),
        const Offset(-0.6, 0.1),
        const Offset(-0.6, -0.1),
      ],
      [const Offset(-0.6, -0.033), const Offset(0.6, -0.033)],
      [const Offset(-0.6, 0.033), const Offset(0.6, 0.033)],
    ],
    opening: true,
    sill: 0.9,
  ),
  CadBlock(
    'window-bath',
    'Bath window 0.60',
    'Openings',
    0.6,
    0.2,
    0,
    [
      [
        const Offset(-0.3, -0.1),
        const Offset(0.3, -0.1),
        const Offset(0.3, 0.1),
        const Offset(-0.3, 0.1),
        const Offset(-0.3, -0.1),
      ],
      [const Offset(-0.3, -0.033), const Offset(0.3, -0.033)],
      [const Offset(-0.3, 0.033), const Offset(0.3, 0.033)],
    ],
    opening: true,
    sill: 1.4,
  ),
  // 3D Warehouse doors (wh_*): real downloaded models — glass =
  // double sliding leaves on the plan symbol; wood = swing leaf
  CadBlock('door-glass', 'Glass door 1.50', 'Openings', 1.5, 0.2, 0, [
    [
      const Offset(-0.75, -0.05),
      const Offset(0.05, -0.05),
      const Offset(0.05, 0.05),
      const Offset(-0.75, 0.05),
      const Offset(-0.75, -0.05),
    ],
    [
      const Offset(-0.05, -0.05),
      const Offset(0.75, -0.05),
      const Offset(0.75, 0.05),
      const Offset(-0.05, 0.05),
      const Offset(-0.05, -0.05),
    ],
  ], opening: true),
  CadBlock('door-wood', 'Wood door 0.90', 'Openings', 0.9, 0.9, 0, [
    [const Offset(-0.45, 0), const Offset(0.45, 0)],
    [const Offset(-0.45, -0.1), const Offset(-0.45, 0.1)],
    [const Offset(0.45, -0.1), const Offset(0.45, 0.1)],
    [
      const Offset(0.47, 0.029),
      const Offset(-0.267, 0.545),
      const Offset(-0.307, 0.487),
      const Offset(0.43, -0.029),
      const Offset(0.47, 0.029),
    ],
    _arc(0.45, 0, 0.9, 145, 180),
  ], opening: true),
  // cased opening — a pass-through frame with no leaf
  CadBlock('doorway-150', 'Cased opening 1.50', 'Openings', 1.5, 0.3, 0, [
    [const Offset(-0.75, 0), const Offset(0.75, 0)],
    [const Offset(-0.75, -0.15), const Offset(-0.75, 0.15)],
    [const Offset(0.75, -0.15), const Offset(0.75, 0.15)],
  ], opening: true),
  // own parametric sliding doors (proc_doors.dart) — procedural
  // meshes registered at startup; still ordinary default defs, so
  // no import step and nothing to clear
  ...kOwnDoorDefs,
  CadBlock('stairs-100', 'Staircase 1.0×3.0', 'Openings', 1.0, 3.0, 0, [
    [
      Offset(-0.5, -1.5),
      Offset(0.5, -1.5),
      Offset(0.5, 1.5),
      Offset(-0.5, 1.5),
      Offset(-0.5, -1.5),
    ],
    [Offset(-0.5, -0.9), Offset(0.5, -0.9)],
    [Offset(-0.5, -0.3), Offset(0.5, -0.3)],
    [Offset(-0.5, 0.3), Offset(0.5, 0.3)],
    [Offset(-0.5, 0.9), Offset(0.5, 0.9)],
    [Offset(0, -1.3), Offset(0, 1.1)], // up arrow
    [Offset(-0.1, 0.95), Offset(0, 1.1), Offset(0.1, 0.95)],
  ]),
  // ---- Bedroom ----
  CadBlock('bed-sgl', 'Single bed 0.9×2.0', 'Bedroom', 0.9, 2.0, 0.5, [
    [
      Offset(-0.45, -1.0),
      Offset(0.45, -1.0),
      Offset(0.45, 1.0),
      Offset(-0.45, 1.0),
      Offset(-0.45, -1.0),
    ],
    [
      Offset(-0.35, 0.55),
      Offset(0.35, 0.55),
      Offset(0.35, 0.95),
      Offset(-0.35, 0.95),
      Offset(-0.35, 0.55),
    ], // pillow
  ]),
  CadBlock('bed-dbl', 'Double bed 1.5×2.0', 'Bedroom', 1.5, 2.0, 0.5, [
    [
      Offset(-0.75, -1.0),
      Offset(0.75, -1.0),
      Offset(0.75, 1.0),
      Offset(-0.75, 1.0),
      Offset(-0.75, -1.0),
    ],
    [
      Offset(-0.65, 0.55),
      Offset(-0.05, 0.55),
      Offset(-0.05, 0.95),
      Offset(-0.65, 0.95),
      Offset(-0.65, 0.55),
    ],
    [
      Offset(0.05, 0.55),
      Offset(0.65, 0.55),
      Offset(0.65, 0.95),
      Offset(0.05, 0.95),
      Offset(0.05, 0.55),
    ],
  ]),
  CadBlock('wardrobe', 'Wardrobe 1.5×0.6', 'Bedroom', 1.5, 0.6, 2.1, [
    [
      Offset(-0.75, -0.3),
      Offset(0.75, -0.3),
      Offset(0.75, 0.3),
      Offset(-0.75, 0.3),
      Offset(-0.75, -0.3),
    ],
    [Offset(-0.75, -0.3), Offset(0.75, 0.3)], // X
    [Offset(-0.75, 0.3), Offset(0.75, -0.3)],
  ]),
  CadBlock('bunk', 'Bunk bed 0.9×2.0', 'Bedroom', 0.9, 2.0, 1.7, [
    _rect(0.9, 2.0),
    [const Offset(-0.35, -0.8), const Offset(0.35, -0.8)], // pillow
    [const Offset(-0.35, -0.8), const Offset(-0.35, -0.5)],
    [const Offset(0.35, -0.8), const Offset(0.35, -0.5)],
    [const Offset(-0.35, -0.5), const Offset(0.35, -0.5)],
    [const Offset(-0.45, 0.6), const Offset(0.45, 0.6)], // ladder
    [const Offset(-0.45, 0.85), const Offset(0.45, 0.85)],
  ]),
  // ---- Living ----
  CadBlock('sofa-3', 'Sofa 3-seat 1.9×0.85', 'Living', 1.9, 0.85, 0.75, [
    [
      Offset(-0.95, -0.425),
      Offset(0.95, -0.425),
      Offset(0.95, 0.425),
      Offset(-0.95, 0.425),
      Offset(-0.95, -0.425),
    ],
    [Offset(-0.95, -0.2), Offset(0.95, -0.2)], // seat/back split
    [Offset(-0.63, -0.2), Offset(-0.63, -0.425)], // seat seams
    [Offset(0, -0.2), Offset(0, -0.425)],
    [Offset(0.63, -0.2), Offset(0.63, -0.425)],
  ]),
  CadBlock('armchair', 'Armchair 0.85', 'Living', 0.85, 0.85, 0.75, [
    [
      Offset(-0.425, -0.425),
      Offset(0.425, -0.425),
      Offset(0.425, 0.425),
      Offset(-0.425, 0.425),
      Offset(-0.425, -0.425),
    ],
    [Offset(-0.425, -0.15), Offset(0.425, -0.15)], // back line
    [Offset(-0.425, -0.15), Offset(-0.425, 0.25)], // arms
    [Offset(0.425, -0.15), Offset(0.425, 0.25)],
  ]),
  CadBlock('coffee', 'Coffee table 1.1×0.55', 'Living', 1.1, 0.55, 0.4, [
    [
      Offset(-0.55, -0.275),
      Offset(0.55, -0.275),
      Offset(0.55, 0.275),
      Offset(-0.55, 0.275),
      Offset(-0.55, -0.275),
    ],
  ]),
  CadBlock('tv-unit', 'TV console 1.6×0.4', 'Living', 1.6, 0.4, 0.5, [
    [
      Offset(-0.8, -0.2),
      Offset(0.8, -0.2),
      Offset(0.8, 0.2),
      Offset(-0.8, 0.2),
      Offset(-0.8, -0.2),
    ],
    [Offset(-0.7, -0.2), Offset(-0.7, 0.2)], // door splits
    [Offset(0.7, -0.2), Offset(0.7, 0.2)],
  ]),
  CadBlock('bookshelf', 'Bookshelf 0.9×0.3', 'Living', 0.9, 0.3, 2.0, [
    [
      Offset(-0.45, -0.15),
      Offset(0.45, -0.15),
      Offset(0.45, 0.15),
      Offset(-0.45, 0.15),
      Offset(-0.45, -0.15),
    ],
    [Offset(-0.45, -0.05), Offset(0.45, -0.05)], // shelf line
  ]),
  CadBlock('desk', 'Desk 1.4×0.7', 'Living', 1.4, 0.7, 0.75, [
    [
      Offset(-0.7, -0.35),
      Offset(0.7, -0.35),
      Offset(0.7, 0.35),
      Offset(-0.7, 0.35),
      Offset(-0.7, -0.35),
    ],
    [Offset(-0.7, -0.05), Offset(0.7, -0.05)], // modesty panel
  ]),
  CadBlock('dining-6', 'Dining table 6', 'Living', 1.8, 0.9, 0.75, [
    [
      Offset(-0.9, -0.45),
      Offset(0.9, -0.45),
      Offset(0.9, 0.45),
      Offset(-0.9, 0.45),
      Offset(-0.9, -0.45),
    ],
    [
      Offset(-0.75, 0.55),
      Offset(-0.25, 0.55),
      Offset(-0.25, 0.85),
      Offset(-0.75, 0.85),
      Offset(-0.75, 0.55),
    ], // chair top L
    [
      Offset(0.25, 0.55),
      Offset(0.75, 0.55),
      Offset(0.75, 0.85),
      Offset(0.25, 0.85),
      Offset(0.25, 0.55),
    ],
    [
      Offset(-0.75, -0.55),
      Offset(-0.25, -0.55),
      Offset(-0.25, -0.85),
      Offset(-0.75, -0.85),
      Offset(-0.75, -0.55),
    ],
    [
      Offset(0.25, -0.55),
      Offset(0.75, -0.55),
      Offset(0.75, -0.85),
      Offset(0.25, -0.85),
      Offset(0.25, -0.55),
    ],
    [
      Offset(-1.15, -0.2),
      Offset(-1.15, 0.2),
      Offset(-0.95, 0.2),
      Offset(-0.95, -0.2),
      Offset(-1.15, -0.2),
    ], // end chairs
    [
      Offset(1.15, -0.2),
      Offset(1.15, 0.2),
      Offset(0.95, 0.2),
      Offset(0.95, -0.2),
      Offset(1.15, -0.2),
    ],
  ]),
  CadBlock('table-r', 'Round table 0.9', 'Living', 0.9, 0.9, 0.75, [
    [
      Offset(0.45, 0),
      Offset(0.318, 0.318),
      Offset(0, 0.45),
      Offset(-0.318, 0.318),
      Offset(-0.45, 0),
      Offset(-0.318, -0.318),
      Offset(0, -0.45),
      Offset(0.318, -0.318),
      Offset(0.45, 0),
    ],
  ]),
  CadBlock('chair', 'Chair 0.45', 'Living', 0.45, 0.45, 0.95, [
    _rect(0.45, 0.45),
    [const Offset(-0.22, -0.22), const Offset(0.22, -0.22)], // back
  ]),
  CadBlock('office-chair', 'Office chair 0.6', 'Living', 0.6, 0.6, 1.05, [
    _rect(0.55, 0.55),
    _arc(0, 0.05, 0.14, 0, 360, 10), // seat
    [const Offset(-0.27, -0.2), const Offset(0.27, -0.2)], // backrest
  ]),
  CadBlock('sofa-l', 'Corner sofa 1.9×1.9', 'Living', 1.9, 1.9, 0.75, [
    [
      const Offset(-0.95, -0.95),
      const Offset(0.95, -0.95),
      const Offset(0.95, -0.35),
      const Offset(0.35, -0.35),
      const Offset(0.35, 0.95),
      const Offset(-0.35, 0.95),
      const Offset(-0.35, -0.35),
      const Offset(-0.95, -0.35),
      const Offset(-0.95, -0.95),
    ],
    [const Offset(-0.95, -0.7), const Offset(0.7, -0.7)], // back L
    [const Offset(0.7, -0.7), const Offset(0.7, -0.95)],
    [const Offset(-0.7, -0.35), const Offset(-0.7, 0.7)],
    [const Offset(-0.7, 0.7), const Offset(-0.35, 0.7)],
  ]),
  CadBlock('bench', 'Bench 1.5×0.4', 'Living', 1.5, 0.4, 0.45, [
    _rect(1.5, 0.4),
    [const Offset(-0.6, -0.1), const Offset(-0.6, 0.1)], // legs
    [const Offset(0.6, -0.1), const Offset(0.6, 0.1)],
  ]),
  CadBlock('side-table', 'Side table 0.5', 'Living', 0.5, 0.5, 0.55, [
    _rect(0.5, 0.5),
    _arc(0, 0, 0.1, 0, 360, 8),
  ]),
  CadBlock('lamp-floor', 'Floor lamp Ø0.35', 'Living', 0.35, 0.35, 1.5, [
    _arc(0, 0, 0.17, 0, 360, 12),
    _arc(0, 0, 0.05, 0, 360, 8),
  ]),
  CadBlock('rug', 'Rug 2.0×1.4', 'Living', 2.0, 1.4, 0, [
    _rect(2.0, 1.4),
    _rect(1.8, 1.2),
  ]),
  CadBlock('plant', 'Potted plant 0.4', 'Living', 0.4, 0.4, 0.7, [
    _arc(0, 0, 0.2, 0, 360, 12),
    _arc(0, 0, 0.09, 0, 360, 8),
  ]),
  CadBlock('stool', 'Stool 0.35', 'Living', 0.35, 0.35, 0.5, [
    _arc(0, 0, 0.17, 0, 360, 10),
    _rect(0.22, 0.22),
  ]),
  CadBlock('lamp-table', 'Table lamp 0.25', 'Living', 0.25, 0.25, 0.4, [
    _arc(0, 0, 0.12, 0, 360, 10),
    _arc(0, 0, 0.04, 0, 360, 8),
  ]),
  CadBlock('books', 'Book stack 0.3', 'Living', 0.3, 0.22, 0.2, [
    _rect(0.3, 0.22),
    [const Offset(-0.1, -0.11), const Offset(-0.1, 0.11)],
  ]),
  CadBlock('picture', 'Picture frame 0.5', 'Living', 0.5, 0.06, 0.55, [
    _rect(0.5, 0.06),
    _rect(0.4, 0.02),
  ], mountOn: true),
  CadBlock('tv', 'Television 1.1', 'Living', 1.1, 0.1, 0.65, [
    _rect(1.1, 0.1),
    [const Offset(-0.15, 0.05), const Offset(0.15, 0.05)], // stand
    [const Offset(0, 0.05), const Offset(0, 0.2)],
  ], mountOn: true),
  CadBlock('coat-rack', 'Coat rack 0.4', 'Living', 0.4, 0.4, 1.75, [
    _arc(0, 0, 0.2, 0, 360, 10),
    [const Offset(-0.14, 0), const Offset(0.14, 0)],
    [const Offset(0, -0.14), const Offset(0, 0.14)],
  ]),
  CadBlock('ceiling-fan', 'Ceiling fan 1.1', 'Living', 1.1, 1.1, 0.25, [
    _arc(0, 0, 0.55, 0, 360, 16),
    _arc(0, 0, 0.08, 0, 360, 8),
    [const Offset(-0.5, 0), const Offset(0.5, 0)],
    [const Offset(0, -0.5), const Offset(0, 0.5)],
  ]),
  CadBlock('case-closed', 'Cabinet 0.9×0.3', 'Living', 0.9, 0.3, 2.0, [
    _rect(0.9, 0.3),
    [const Offset(0, -0.15), const Offset(0, 0.15)], // door split
  ]),
  // ---- Kitchen ----
  CadBlock('sink-kit', 'Kitchen sink 0.8', 'Kitchen', 0.8, 0.55, 0, [
    [
      Offset(-0.4, -0.275),
      Offset(0.4, -0.275),
      Offset(0.4, 0.275),
      Offset(-0.4, 0.275),
      Offset(-0.4, -0.275),
    ],
    [
      Offset(-0.3, -0.175),
      Offset(-0.02, -0.175),
      Offset(-0.02, 0.175),
      Offset(-0.3, 0.175),
      Offset(-0.3, -0.175),
    ],
    [
      Offset(0.02, -0.175),
      Offset(0.3, -0.175),
      Offset(0.3, 0.175),
      Offset(0.02, 0.175),
      Offset(0.02, -0.175),
    ],
  ]),
  CadBlock('stove', 'Stove 0.6×0.6', 'Kitchen', 0.6, 0.6, 0.9, [
    [
      Offset(-0.3, -0.3),
      Offset(0.3, -0.3),
      Offset(0.3, 0.3),
      Offset(-0.3, 0.3),
      Offset(-0.3, -0.3),
    ],
    [Offset(-0.15, -0.15), Offset(-0.15, -0.02)], // burners
    [Offset(0.15, -0.15), Offset(0.15, -0.02)],
    [Offset(-0.15, 0.15), Offset(-0.15, 0.02)],
    [Offset(0.15, 0.15), Offset(0.15, 0.02)],
  ]),
  CadBlock('fridge', 'Refrigerator 0.7', 'Kitchen', 0.7, 0.7, 1.8, [
    [
      Offset(-0.35, -0.35),
      Offset(0.35, -0.35),
      Offset(0.35, 0.35),
      Offset(-0.35, 0.35),
      Offset(-0.35, -0.35),
    ],
    [Offset(-0.35, -0.35), Offset(0.35, 0.35)], // X = appliance
    [Offset(-0.35, 0.35), Offset(0.35, -0.35)],
  ]),
  CadBlock('counter-kit', 'Kitchen counter 1.8×0.6', 'Kitchen', 1.8, 0.6, 0.9, [
    [
      Offset(-0.9, -0.3),
      Offset(0.9, -0.3),
      Offset(0.9, 0.3),
      Offset(-0.9, 0.3),
      Offset(-0.9, -0.3),
    ],
    [Offset(-0.9, -0.3), Offset(0.9, 0.3)], // base-cabinet X
    [Offset(-0.9, 0.3), Offset(0.9, -0.3)],
  ]),
  CadBlock('microwave', 'Microwave 0.5×0.35', 'Kitchen', 0.5, 0.35, 0.3, [
    _rect(0.5, 0.35),
    [const Offset(-0.25, -0.17), const Offset(-0.25, 0.17)], // door edge
  ]),
  // ---- Bath ----
  CadBlock('wc', 'Toilet WC', 'Bath', 0.45, 0.7, 0.45, [
    [
      Offset(-0.2, 0.15),
      Offset(0.2, 0.15),
      Offset(0.2, 0.35),
      Offset(-0.2, 0.35),
      Offset(-0.2, 0.15),
    ], // tank
    [
      Offset(-0.19, -0.35),
      Offset(0.19, -0.35),
      Offset(0.19, 0.1),
      Offset(-0.19, 0.1),
      Offset(-0.19, -0.35),
    ], // bowl
  ]),
  CadBlock('basin', 'Wash basin 0.5', 'Bath', 0.5, 0.45, 0.85, [
    [
      Offset(-0.25, -0.225),
      Offset(0.25, -0.225),
      Offset(0.25, 0.225),
      Offset(-0.25, 0.225),
      Offset(-0.25, -0.225),
    ],
    [
      Offset(0.14, 0),
      Offset(0.1, 0.1),
      Offset(0, 0.14),
      Offset(-0.1, 0.1),
      Offset(-0.14, 0),
      Offset(-0.1, -0.1),
      Offset(0, -0.14),
      Offset(0.1, -0.1),
      Offset(0.14, 0),
    ], // drain
  ]),
  CadBlock('tub', 'Bathtub 1.7×0.75', 'Bath', 1.7, 0.75, 0.55, [
    [
      Offset(-0.85, -0.375),
      Offset(0.85, -0.375),
      Offset(0.85, 0.375),
      Offset(-0.85, 0.375),
      Offset(-0.85, -0.375),
    ],
    [
      Offset(-0.75, -0.28),
      Offset(0.75, -0.28),
      Offset(0.75, 0.28),
      Offset(-0.75, 0.28),
      Offset(-0.75, -0.28),
    ], // inner rim
  ]),
  CadBlock('shower', 'Shower 0.9×0.9', 'Bath', 0.9, 0.9, 0, [
    [
      Offset(-0.45, -0.45),
      Offset(0.45, -0.45),
      Offset(0.45, 0.45),
      Offset(-0.45, 0.45),
      Offset(-0.45, -0.45),
    ],
    [Offset(-0.45, -0.45), Offset(0.45, 0.45)], // diagonal
    [
      Offset(0.08, 0.23),
      Offset(-0.08, 0.23),
      Offset(-0.08, 0.38),
      Offset(0.08, 0.38),
      Offset(0.08, 0.23),
    ], // drain
  ]),
  CadBlock('urinal', 'Urinal 0.4×0.6', 'Bath', 0.4, 0.6, 0.7, [
    [
      Offset(-0.2, -0.1),
      Offset(0.2, -0.1),
      Offset(0.2, 0.3),
      Offset(-0.2, 0.3),
      Offset(-0.2, -0.1),
    ],
    _arc(0, -0.1, 0.2, 180, 360, 6), // rounded front
  ]),
  CadBlock('washer', 'Washer 0.6×0.6', 'Bath', 0.6, 0.6, 0.85, [
    [
      Offset(-0.3, -0.3),
      Offset(0.3, -0.3),
      Offset(0.3, 0.3),
      Offset(-0.3, 0.3),
      Offset(-0.3, -0.3),
    ],
    _arc(0, 0, 0.2, 0, 360, 12), // drum
  ]),
  CadBlock('dryer', 'Dryer 0.6×0.6', 'Bath', 0.6, 0.6, 0.85, [
    _rect(0.6, 0.6),
    _arc(0, 0, 0.19, 0, 360, 12),
    [const Offset(-0.25, -0.25), const Offset(0.25, -0.25)], // controls
  ]),
  CadBlock('bath-cab', 'Bath cabinet 0.6×0.25', 'Bath', 0.6, 0.25, 0.7, [
    _rect(0.6, 0.25),
    [const Offset(0, -0.12), const Offset(0, 0.12)], // doors
  ], mountOn: true),
  CadBlock('trash', 'Trash bin 0.3', 'Bath', 0.3, 0.3, 0.45, [
    _arc(0, 0, 0.15, 0, 360, 12),
    _arc(0, 0, 0.08, 0, 360, 8),
  ]),
  // ---- Site / structure / outdoors ----
  CadBlock('col-sq', 'Column 0.3□', 'Site', 0.3, 0.3, 3.0, [
    [
      Offset(-0.15, -0.15),
      Offset(0.15, -0.15),
      Offset(0.15, 0.15),
      Offset(-0.15, 0.15),
      Offset(-0.15, -0.15),
    ],
    [Offset(-0.15, -0.15), Offset(0.15, 0.15)],
    [Offset(-0.15, 0.15), Offset(0.15, -0.15)],
  ]),
  CadBlock('col-rd', 'Column Ø0.3', 'Site', 0.3, 0.3, 3.0, [
    _arc(0, 0, 0.15, 0, 360, 12),
    [Offset(-0.15, 0), Offset(0.15, 0)],
    [Offset(0, -0.15), Offset(0, 0.15)],
  ]),
  // RC beam — runs horizontally along X; drop it ON a wall top (or
  // free-lift it) and trusses seat on its top like a wall plate.
  // 0.20×0.30 is the PH "200×300" floor beam; the inspector's NSCP
  // panel sizes it to the span (Table 409.3.1.1 L/16).
  CadBlock('beam', 'Beam 0.20×0.30', 'Site', 4.0, 0.20, 0.30, [
    _rect(4.0, 0.20),
    [const Offset(-2.0, 0), const Offset(2.0, 0)],
  ]),
  // standalone footing pads — plan symbol = square + X cross; the 3D
  // pad renders BURIED (top at the block base, body below) so placing
  // at base 0 puts concrete under the floor. Design calc treats a pad
  // within 0.4 m of a column as that column's provided footing.
  CadBlock('ftg-150', 'Footing 1.5×1.5', 'Site', 1.5, 1.5, 0.30, [
    _rect(1.5, 1.5),
    [const Offset(-0.75, -0.75), const Offset(0.75, 0.75)],
    [const Offset(-0.75, 0.75), const Offset(0.75, -0.75)],
  ]),
  CadBlock('ftg-200', 'Footing 2.0×2.0', 'Site', 2.0, 2.0, 0.40, [
    _rect(2.0, 2.0),
    [const Offset(-1.0, -1.0), const Offset(1.0, 1.0)],
    [const Offset(-1.0, 1.0), const Offset(1.0, -1.0)],
  ]),
  // the user's SketchUp truss (truss.skp -> wh_truss.obj): ~4m span,
  // 0.8m rise. Plan symbol = bottom chord + web zigzag.
  CadBlock('truss', 'Roof truss 4.0m', 'Site', 3.97, 0.18, 0.80, [
    _rect(3.97, 0.18),
    [const Offset(-1.985, 0), const Offset(1.985, 0)],
    // web members: verticals at the panel points + diagonal braces
    [const Offset(-0.99, -0.09), const Offset(-0.99, 0.09)],
    [const Offset(-0.33, -0.09), const Offset(-0.33, 0.09)],
    [const Offset(0.33, -0.09), const Offset(0.33, 0.09)],
    [const Offset(0.99, -0.09), const Offset(0.99, 0.09)],
    [const Offset(-1.985, -0.09), const Offset(-0.99, 0.09)],
    [const Offset(-0.99, -0.09), const Offset(0.0, 0.09)],
    [const Offset(0.0, -0.09), const Offset(0.99, 0.09)],
    [const Offset(0.99, -0.09), const Offset(1.985, 0.09)],
  ]),
  // SINGLE-member king-post variant — the simple truss from before
  // the parametric web upgrade: A-frame + center post + two struts,
  // thin single members instead of the doubled fink web. Plan symbol
  // = bottom chord + center post mark + two strut ticks.
  CadBlock('truss-sgl', 'Roof truss 4.0m (single)', 'Site', 3.97, 0.18, 0.80, [
    _rect(3.97, 0.18),
    [const Offset(-1.985, 0), const Offset(1.985, 0)],
    [const Offset(-0.05, -0.09), const Offset(-0.05, 0.09)],
    [const Offset(0.05, -0.09), const Offset(0.05, 0.09)],
    [const Offset(-1.0, -0.09), const Offset(-0.25, 0.09)],
    [const Offset(1.0, -0.09), const Offset(0.25, 0.09)],
  ]),
  // the user's second SketchUp model (truss (1).skp -> dbl_truss.obj):
  // a DOUBLE mono-pitch truss — two flat frames side by side filling
  // the 0.18 m depth, top chord rising heel->high end. Parametric
  // like the other trusses (plan symbol = same chord+web ticks).
  CadBlock('truss-dbl', 'Roof truss 4.0m (double)', 'Site', 3.97, 0.18, 0.85, [
    _rect(3.97, 0.18),
    [const Offset(-1.985, 0), const Offset(1.985, 0)],
    [const Offset(-0.99, -0.09), const Offset(-0.99, 0.09)],
    [const Offset(-0.33, -0.09), const Offset(-0.33, 0.09)],
    [const Offset(0.33, -0.09), const Offset(0.33, 0.09)],
    [const Offset(0.99, -0.09), const Offset(0.99, 0.09)],
  ]),
  CadBlock('tree', 'Tree canopy 3.0', 'Site', 1.5, 1.5, 0, [
    _arc(0, 0, 0.75, 0, 360, 16),
    _arc(0.1, 0.05, 0.4, 0, 360, 12), // inner canopy
    [Offset(0, -0.12), Offset(0, 0.12)], // trunk cross
    [Offset(-0.12, 0), Offset(0.12, 0)],
  ]),
  CadBlock('shrub', 'Shrub 0.6', 'Site', 0.6, 0.6, 0, [
    _arc(0, 0, 0.3, 0, 360, 12),
    _arc(0, 0, 0.15, 0, 360, 8),
  ]),
  CadBlock('car', 'Car 4.6×1.8', 'Site', 4.6, 1.8, 0, [
    [
      Offset(-2.3, -0.75),
      Offset(1.7, -0.75),
      Offset(2.1, -0.6),
      Offset(2.3, -0.3),
      Offset(2.3, 0.3),
      Offset(2.1, 0.6),
      Offset(1.7, 0.75),
      Offset(-2.3, 0.75),
      Offset(-2.3, -0.75),
    ],
    [
      Offset(-1.1, -0.65),
      Offset(0.5, -0.65),
      Offset(0.5, 0.65),
      Offset(-1.1, 0.65),
      Offset(-1.1, -0.65),
    ], // cabin
    [
      Offset(0.6, -0.6),
      Offset(1.5, -0.6),
      Offset(1.5, 0.6),
      Offset(0.6, 0.6),
      Offset(0.6, -0.6),
    ], // windshield
  ]),
  CadBlock('person', 'Person', 'Site', 0.5, 0.6, 0, [
    _arc(0, 0.15, 0.12, 0, 360, 10), // head
    _arc(0, -0.1, 0.22, 200, 340, 8), // shoulders
  ]),
];

CadBlock? cadBlock(String id) {
  id = kLegacyDefAliases[id] ?? id;
  for (final b in kCadBlocks) {
    if (b.id == id) return b;
  }
  for (final b in customCadBlocks) {
    if (b.id == id) return b;
  }
  return null;
}

// ---------- Real 3D block geometry ----------

/// User-imported block defs (`.obj` files registered at runtime) —
/// searched by [cadBlock] after the built-in library. Category is
/// always 'Imported'.
final List<CadBlock> customCadBlocks = [];

/// Renderable local-space faces per def id: bundled Kenney meshes,
/// imported OBJ meshes, and lazily-cached procedural bodies all live
/// here. Coordinates are def-local — centered on the insertion point,
/// z base at 0, already fitted to the def's w/d/height.
final Map<String, List<Face3>> blockMeshes = {};

/// Local-space z extent of [blockMeshes] entries — lets
/// [blockHeight]/bounds/picking stay honest when the real mesh is
/// taller than the plan symbol's nominal height.
final Map<String, double> blockMeshTop = {};

/// Kenney CC0 furniture bundled in `assets/kenney/` — maps built-in
/// defs to their real downloaded counterparts so every placed block
/// renders as an actual object, not a box.
const kKenneyMeshMap = {
  // Openings — real leaf/frame meshes (Kenney Prototype Kit, texture
  // baked to flat colors by tool/bake_kenney.py)
  // doors/windows — KayKit Restaurant Bits (kkr_*): real frame+leaf
  // doors with handles; the prototype window keeps its own sill so
  // it stays the opening-mesh (kk windows are 4m wall segments —
  // normalizing one to a 1.2m def would shrink it to a chip)
  'door-090': 'kkr_door_A',
  'door-dbl': 'kkr_door_dbl', // two mirrored door_A leaves
  'door-glass': 'wh_door_glass', // 3D Warehouse real door models
  'door-wood': 'wh_door_wood',
  'doorway-150': 'kkr_wall_doorway',
  'stairs-100': 'stairs',
  // Bedroom — KayKit Furniture Bits pieces where they beat the
  // furniture kit (kk_* = GitHub CC0 pack; bed frames + bedding win,
  // soft sofas/chairs bake near-white so Kenney's colored ones stay)
  'bed-sgl': 'kk_bed_single_A',
  'bed-dbl': 'kk_bed_double_A',
  'bunk': 'bedBunk',
  'wardrobe': 'bookcaseClosedDoors', // tallest closed cabinet = wardrobe
  // Living
  'sofa-3': 'loungeSofa',
  'sofa-l': 'loungeSofaCorner',
  'armchair': 'loungeChair',
  'chair': 'kk_chair_A_wood',
  'stool': 'kk_chair_stool',
  'office-chair': 'chairDesk',
  'bench': 'bench',
  'coffee': 'kk_table_low',
  'side-table': 'kk_table_small',
  'tv-unit': 'cabinetTelevision',
  'tv': 'televisionModern',
  'bookshelf': 'bookcaseOpen', // kk shelves are media consoles — too low
  'case-closed': 'kk_cabinet_medium',
  'desk': 'desk',
  'dining-6': 'kk_table_medium_long',
  'table-r': 'tableRound',
  'lamp-floor': 'kk_lamp_standing',
  'lamp-table': 'kk_lamp_table',
  'books': 'kk_book_set',
  'picture': 'kk_pictureframe_large_A',
  'rug': 'rugRectangle', // kk rug bakes near-white; Kenney's carries dye
  'plant': 'kk_cactus_medium_A',
  'ceiling-fan': 'ceilingFan',
  'coat-rack': 'coatRackStanding',
  // Kitchen
  'sink-kit': 'kitchenSink',
  'stove': 'kitchenStove',
  'fridge': 'kitchenFridge',
  'counter-kit': 'kitchenCabinet',
  'microwave': 'kitchenMicrowave',
  // Bath
  'wc': 'toilet',
  'basin': 'bathroomSink',
  'tub': 'bathtub',
  'shower': 'shower',
  'urinal': 'bathroomSink', // nearest wall-hung fixture in the pack
  'washer': 'washer',
  'dryer': 'dryer',
  'bath-cab': 'bathroomCabinet',
  'trash': 'trashcan',
  // Site
  'col-sq': 'columnSq',
  'col-rd': 'columnRd',
  'truss': 'wh_truss', // user's SketchUp model (tool/skp2obj.rb)
  'truss-dbl': 'dbl_truss', // user's 2nd SketchUp model (double mono-pitch)
  'tree': 'treeOak',
  'shrub': 'shrubBush',
  'car': 'carSedan',
  'person': 'person',
};

/// Baked z-offset per def — wall-mounted and ceiling pieces get a
/// lift baked into their local mesh so the object hangs correctly.
const kKenneyZLift = {
  // objects that genuinely mount or sit at working height: the
  // wall-window mesh already carries its opening at sill height
  // inside the panel, but a bare TV/picture panel at z=0 is a thin
  // sliver on the floor — mount heights read as intended. Lifted
  // pieces land on the counters/walls the user places them with.
  'ceiling-fan': 2.45,
  'tv': 0.45, // console-top height
  'picture': 1.15, // eye-level hang
  'microwave': 0.90, // countertop
  'bath-cab': 1.35, // wall-hung vanity cabinet
};

/// Newell face normal — robust for the slightly non-planar quads OBJ
/// files ship with.
List<double> _newell(List<List<double>> vs) {
  var nx = 0.0, ny = 0.0, nz = 0.0;
  for (var i = 0; i < vs.length; i++) {
    final a = vs[i], b = vs[(i + 1) % vs.length];
    nx += (a[1] - b[1]) * (a[2] + b[2]);
    ny += (a[2] - b[2]) * (a[0] + b[0]);
    nz += (a[0] - b[0]) * (a[1] + b[1]);
  }
  final l = math.sqrt(nx * nx + ny * ny + nz * nz);
  return l < 1e-9 ? [0, 0, 1] : [nx / l, ny / l, nz / l];
}

/// Fits a parsed OBJ mesh into a def's local space: recenters on the
/// xy centroid, drops the base to z=0, scales xy uniformly to the def
/// footprint and z to [fitH] (or the xy scale when flat — keeps the
/// object's proportions). [zLift] raises the normalized body — baked
/// wall-mount heights (ceiling fan, bath cabinet). Returns faces.
List<Face3> _objLocal(
  ObjMesh om,
  double fitW,
  double fitD,
  double fitH, [
  double zLift = 0,
]) {
  final b = om.bounds;
  final dx = b.$4 - b.$1, dy = b.$5 - b.$2, dz = b.$6 - b.$3;
  final cx = (b.$1 + b.$4) / 2, cy = (b.$2 + b.$5) / 2;
  // orientation pick: meshes ship in either xy order (a window's
  // thickness may sit in X with its width in Y, or vice-versa).
  // Trying the 90°-swapped fit and keeping whichever allows the
  // LARGER uniform scale stops thin panels (door/window/tv/car)
  // collapsing to floating fragments — the "swapped axis" bug the
  // sim caught.
  var s = 1.0, sSwap = -1.0;
  if (dx > 1e-9 && dy > 1e-9) {
    s = math.min(fitW / dx, fitD / dy);
    sSwap = math.min(fitW / dy, fitD / dx);
  }
  final swap = sSwap > s;
  if (swap) s = sSwap;
  final sz = fitH > 0 && dz > 1e-9 ? fitH / dz : s;
  var top = 0.0;
  final out = <Face3>[
    for (final f in om.faces)
      Face3(
        [
          for (final i in f.idx)
            [
              // swapped = rotate -90° about local z: (x,y) -> (y,-x)
              ((swap ? om.verts[i][1] - cy : om.verts[i][0] - cx)) * s,
              ((swap ? cx - om.verts[i][0] : om.verts[i][1] - cy)) * s,
              (om.verts[i][2] - b.$3) * sz + zLift,
            ],
        ],
        const [0, 0, 1],
        f.argb,
      ),
  ];
  // compute normals AFTER the axis map + fit so winding stays honest
  for (var i = 0; i < out.length; i++) {
    final n = _newell(out[i].v);
    out[i] = Face3(out[i].v, n, out[i].argb);
    for (final p in out[i].v) {
      if (p[2] > top) top = p[2];
    }
  }
  blockMeshTop[''] = top; // sentinel slot — caller overwrites with id
  return out;
}

/// Local-space aabb of each registered mesh — (x0,y0,z0,x1,y1,z1).
/// The 3D scale-gizmo's bounding box and handle positions come from
/// this, not the plan symbol, so the cage hugs the real object.
final Map<String, List<double>> blockMeshBox = {};

List<double> _aabbOf(List<Face3> faces) {
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

/// A def's local bounding box — the registered mesh's real extents,
/// falling back to the plan-symbol footprint + nominal height.
List<double> blockLocalBox(CadBlock def) {
  final b = blockMeshBox[def.id];
  if (b != null) return b;
  var x0 = double.infinity, y0 = double.infinity;
  var x1 = -double.infinity, y1 = -double.infinity;
  for (final l in def.lines) {
    for (final p in l) {
      x0 = math.min(x0, p.dx);
      x1 = math.max(x1, p.dx);
      y0 = math.min(y0, p.dy);
      y1 = math.max(y1, p.dy);
    }
  }
  if (!x0.isFinite) {
    x0 = -def.w / 2;
    x1 = def.w / 2;
    y0 = -def.d / 2;
    y1 = def.d / 2;
  }
  return [x0, y0, 0, x1, y1, def.height];
}

/// Register a bundled or imported mesh under [defId]. [w]/[d]/[h] are
/// the def's plan footprint and nominal height — the mesh is fitted
/// inside that envelope. [zLift] bakes a wall-mount height into the
/// local geometry (window sill, ceiling fan, bath cabinet).
void registerBlockMesh(
  String defId,
  ObjMesh om,
  double w,
  double d,
  double h, {
  double zLift = 0,
}) {
  blockMeshTop.remove('');
  final faces = _objLocal(om, w, d, h, zLift);
  blockMeshes[defId] = faces;
  blockMeshTop[defId] = blockMeshTop[''] ?? 0;
  blockMeshTop.remove('');
  blockMeshBox[defId] = _aabbOf(faces);
}

/// Register an imported OBJ as a new CAD block def in the 'Imported'
/// category. The def's footprint/height come straight from the mesh
/// bounds so picking, fit and envelopes stay honest. Returns the new
/// def.
CadBlock registerObjBlock(
  String name,
  ObjMesh om, {
  bool opening = false,
  double sill = 0,
}) {
  final b = om.bounds;
  final w = (b.$4 - b.$1).clamp(0.1, 999.0);
  final d = (b.$5 - b.$2).clamp(0.1, 999.0);
  final h = (b.$6 - b.$3).clamp(0.05, 999.0);
  final id = 'imp-${_uuid.v4().substring(0, 8)}';
  final def = CadBlock(
    id,
    name,
    opening ? 'Openings' : 'Imported',
    w,
    d,
    h,
    [
      [
        Offset(-w / 2, -d / 2),
        Offset(w / 2, -d / 2),
        Offset(w / 2, d / 2),
        Offset(-w / 2, d / 2),
        Offset(-w / 2, -d / 2),
      ],
      if (opening) [Offset(-w / 2, 0), Offset(w / 2, 0)],
    ],
    opening: opening,
    sill: sill,
    head: sill + h,
  );
  customCadBlocks.add(def);
  blockMeshTop.remove('');
  blockMeshes[id] = _objLocal(om, w, d, h, sill);
  blockMeshTop[id] = blockMeshTop[''] ?? h;
  blockMeshTop.remove('');
  blockMeshBox[id] = _aabbOf(blockMeshes[id]!);
  return def;
}

List<Offset> _bx(double x0, double y0, double x1, double y1) => [
  Offset(x0, y0),
  Offset(x1, y0),
  Offset(x1, y1),
  Offset(x0, y1),
];

/// Parametric windows (frame + sash rails + glass + projecting sill
/// board), built at their real standard height: the mesh spans
/// sill..sill+h in local z so a placed window sits at 0.90 m (1.40 m
/// bath) with a 1.20 m glazed height — matching the wall's cut band.
void registerProceduralWindows() {
  const frame = 0xFFF1F3F5, rail = 0xFFE2E6EA, glass = 0xAAA9D6E8;
  const sillC = 0xFFD9D4CC;
  void reg(String id, int panes, {bool slide = false}) {
    final def = cadBlock(id);
    if (def == null) return;
    final w = def.w, z0 = def.sill, z1 = def.head;
    const ft = 0.05, t = 0.12;
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
    final hw = w / 2;
    // outer frame (full reveal depth)
    box(-hw, -t / 2, -hw + ft, t / 2, z0, z1, frame);
    box(hw - ft, -t / 2, hw, t / 2, z0, z1, frame);
    box(-hw + ft, -t / 2, hw - ft, t / 2, z1 - ft, z1, frame);
    box(-hw + ft, -t / 2, hw - ft, t / 2, z0, z0 + ft, frame);
    // projecting sill board
    box(-hw - 0.04, -0.10, hw + 0.04, 0.10, z0 - 0.03, z0, sillC);
    final iw = w - 2 * ft, ix0 = -hw + ft;
    final pw = iw / panes;
    for (var k = 0; k < panes; k++) {
      final x0 = ix0 + k * pw, x1 = x0 + pw;
      final off = slide ? (k.isEven ? -0.02 : 0.02) : 0.0;
      const r = 0.035;
      final yl = off - 0.015, yh = off + 0.015;
      // sash rails
      box(x0, yl, x0 + r, yh, z0 + ft, z1 - ft, rail);
      box(x1 - r, yl, x1, yh, z0 + ft, z1 - ft, rail);
      box(x0 + r, yl, x1 - r, yh, z1 - ft - r, z1 - ft, rail);
      box(x0 + r, yl, x1 - r, yh, z0 + ft, z0 + ft + r, rail);
      // glass pane
      box(
        x0 + r,
        off - 0.004,
        x1 - r,
        off + 0.004,
        z0 + ft + r,
        z1 - ft - r,
        glass,
      );
    }
    blockMeshes[id] = f;
    blockMeshTop[id] = z1;
    blockMeshBox[id] = _aabbOf(f);
  }

  reg('window-120', 2);
  reg('window-slide', 2, slide: true);
  reg('window-fixed', 1);
  reg('window-bath', 1);
}

/// Loads every bundled Kenney mesh into [blockMeshes] at startup —
/// pass `rootBundle.loadString` (kept injectable so tests can preload
/// from disk instead of the asset bundle).
Future<void> preloadBlockMeshes(
  Future<String> Function(String path) load,
) async {
  registerProceduralWindows();
  for (final e in kKenneyMeshMap.entries) {
    final def = cadBlock(e.key);
    if (def == null) continue;
    try {
      final obj = await load('assets/kenney/${e.value}.obj');
      String? mtl;
      try {
        mtl = await load('assets/kenney/${e.value}.mtl');
      } catch (_) {}
      final om = parseObj(obj, mtlSrc: mtl);
      if (om != null) {
        // natural z (uniform scale) — a bed's headboard keeps its
        // proportions; blockMeshTop records the real top so bounds,
        // picking and the selection cage stay honest
        registerBlockMesh(
          def.id,
          om,
          def.w,
          def.d,
          def.opening ? def.head - def.sill : 0,
          zLift: kKenneyZLift[def.id] ?? 0,
        );
      }
    } catch (_) {}
  }
  registerProceduralSlidingDoors();
}

/// A block's effective rendered height: the real mesh's z extent when
/// it has one, else the plan symbol's nominal height. Scaled by the
/// instance.
double blockHeight(Block3d b, CadBlock def) {
  final t = blockMeshTop[def.id];
  return (t != null && t > 0 ? t : def.height) * b.sz * b.scale + b.bz;
}

/// All renderable faces of one placed block: the registered mesh
/// (bundled Kenney / imported OBJ) transformed by the instance's
/// per-axis stretch, uniform scale, rotation and base lift, or the
/// legacy footprint prism for flat plan symbols.
/// Blend a face color toward a material [tint] (0xAARRGGBB); ~55% mix
/// keeps the mesh's baked shading readable under the new color.
int _tinted(int argb, int tint) {
  if (tint == 0) return argb;
  const t = 0.55;
  int ch(int a, int b) => (a + (b - a) * t).round();
  return (0xFF << 24) |
      (ch((argb >> 16) & 0xFF, (tint >> 16) & 0xFF) << 16) |
      (ch((argb >> 8) & 0xFF, (tint >> 8) & 0xFF) << 8) |
      ch(argb & 0xFF, tint & 0xFF);
}

/// Floors this column's footing supports = its own level plus each
/// column directly above it in the same stack (within 0.4 m plan
/// distance at a higher base — the same 0.4/0.3 test the design
/// checks and the footing apply-all use). A lone/roof-only column
/// counts as 1 floor per NSCP 2015 Table 305-1 note 3.
int columnStackFloors(Model3d m, Block3d b) {
  var n = 1, lvl = b.bz;
  for (;;) {
    var nz = double.infinity;
    for (final q in m.blocks) {
      if ((q.def == 'col-sq' || q.def == 'col-rd') &&
          q.bz > lvl + 0.3 &&
          q.bz < nz &&
          (Offset(q.x, q.y) - Offset(b.x, b.y)).distance < 0.4) {
        nz = q.bz;
      }
    }
    if (!nz.isFinite) return n;
    n++;
    lvl = nz;
  }
}

/// The footing embedment this column actually uses: manual `footD`
/// wins; otherwise NSCP Table 305-1 for the floors its stack carries.
/// Every consumer (render, takeoff, checks, sheets) resolves through
/// this so they always agree on the same depth.
double blockFootingDepth(Model3d m, Block3d b) =>
    footingDepth(b.footD, columnStackFloors(m, b));

/// The column footing pad (buried at footD) + pedestal stem — part of
/// the block's own faces so 3D picking, render groups and the cache all
/// treat it as one selectable object. Concrete colors stay untinted.
/// [floors] is the stack's supported-floor count (Table 305-1) —
/// callers with the model pass `columnStackFloors`, else 1.
List<Face3> blockFootingFaces(Block3d b, CadBlock def, {int floors = 1}) {
  if (!b.footing || (b.def != 'col-sq' && b.def != 'col-rd')) {
    return const [];
  }
  final sec = def.w * b.sx * b.scale;
  final f = footingFor(sec, b.footW);
  final d = footingDepth(b.footD, floors);
  final hw = f.w / 2;
  final out = <Face3>[
    ..._polyFaces(
      [
        Offset(b.x - hw, b.y - hw),
        Offset(b.x + hw, b.y - hw),
        Offset(b.x + hw, b.y + hw),
        Offset(b.x - hw, b.y + hw),
      ],
      b.bz - d,
      b.bz - d + f.t,
      0xFF9E9E9E,
    ),
  ];
  // pedestal stem: pad top up to the column base
  final hs = math.max(sec / 2, 0.10);
  final stemTop = b.bz, stemBot = b.bz - d + f.t;
  if (stemTop - stemBot > 0.01) {
    out.addAll(
      _polyFaces(
        [
          Offset(b.x - hs, b.y - hs),
          Offset(b.x + hs, b.y - hs),
          Offset(b.x + hs, b.y + hs),
          Offset(b.x - hs, b.y + hs),
        ],
        stemBot,
        stemTop,
        0xFFBDBDBD,
      ),
    );
  }
  return out;
}

/// A truss member as a solid box: the xz-plane segment (x1,z1)->(x2,z2)
/// given in-plane thickness [t], extruded [depth] along Y centered on
/// y=0. Local coords — the truss spans +X centered, rises +Z.
List<Face3> _memberBox(
  double x1,
  double z1,
  double x2,
  double z2,
  double t,
  double depth,
  int argb,
) {
  final dx = x2 - x1, dz = z2 - z1;
  final l = math.sqrt(dx * dx + dz * dz);
  if (l < 1e-9) return const [];
  final px = -dz / l * t / 2, pz = dx / l * t / 2;
  final y0 = -depth / 2, y1 = depth / 2;
  final q = [
    [x1 + px, z1 + pz],
    [x2 + px, z2 + pz],
    [x2 - px, z2 - pz],
    [x1 - px, z1 - pz],
  ];
  final out = <Face3>[
    Face3(
      [for (final c in q.reversed) [c[0], y0, c[1]]],
      const [0, -1, 0],
      argb,
    ),
    Face3(
      [for (final c in q) [c[0], y1, c[1]]],
      const [0, 1, 0],
      argb,
    ),
  ];
  for (var i = 0; i < 4; i++) {
    final a = q[i], c = q[(i + 1) % 4];
    out.add(
      Face3(
        [
          [a[0], y0, a[1]],
          [c[0], y0, c[1]],
          [c[0], y1, c[1]],
          [a[0], y1, a[1]],
        ],
        _norm([c[0] - a[0], 0.0, c[1] - a[1]], const [0, 1, 0]),
        argb,
      ),
    );
  }
  return out;
}

/// A def id belongs to the roof-truss family ('truss' parametric
/// fink, 'truss-sgl' single king-post, 'truss-dbl' double mono-pitch
/// from the user's second SketchUp model) — seating, roof fields,
/// sheet symbols and takeoff treat them the same.
bool isTrussDef(String id) => id.startsWith('truss');

/// A 'beam' block — an RC member running horizontally that TRUSSES
/// CAN BEAR ON (its top acts as a plate in the seat solve, same as a
/// wall top). Sized per NSCP 2015 Table 409.3.1.1 by default.
bool isBeamDef(String id) => id == 'beam';

/// The bay count a placed truss actually builds: an explicit `panels`
/// (inspector stepper) wins; 0 = AUTO follows the STRETCHED span —
/// lengthening a truss adds web members at ~1.0 m/bay (the stock
/// 4.0 m/4-bay pitch) instead of thinning out a fixed fink. Same
/// 2..12 clamp as the manual count.
int trussPanelCount(Block3d b, CadBlock def) {
  if (b.panels >= 2) return b.panels.clamp(2, 12);
  return (def.w * b.sx * b.scale / 1.0).round().clamp(2, 12);
}

/// Fink-family node layout (TRA quarter/third rule): for [n] bays on
/// a span [-s..s] pick the odd bottom-panel count P — 3=fink "4/3",
/// 5=double fink "6/5", 7=triple fink "8/7", then keep odd-stepping
/// (9,11) so a stretched truss keeps gaining W cells — real practice
/// subdivides the triangle rather than adding arbitrary verticals.
/// Returns (top node xs at i/(P+1) fractions, bottom node xs at i/P).
/// The zigzag webs then connect top_i->bot_i (compression stub) and
/// bot_i->top_{i+1} (tension diagonal) — the letter W eave to eave.
(int, List<double>, List<double>) finkNodes(int n, double span) {
  final p = n <= 4 ? 3 : (n <= 6 ? 5 : ((n + 1) ~/ 2) * 2 - 1);
  final s = span / 2;
  return (
    p,
    [for (var i = 1; i <= p; i++) -s + span * i / (p + 1)],
    [for (var i = 1; i < p; i++) -s + span * i / p],
  );
}

/// The parametric roof-truss mesh in def-local space: bottom chord +
/// two top chords + fink-family W webbing (stubs top_i->bot_i,
/// diagonals bot_i->top_{i+1} — see [finkNodes]). [panels] = web bays
/// (0 -> auto 4); larger bay counts step the pattern single->double->
/// triple fink the way real trusses subdivide with span.
/// [single] switches to the king-post layout: thin single members,
/// center post + two struts — the 'truss-sgl' variant. [dbl] builds
/// the user-supplied 'truss (1).skp' design ('truss-dbl'): a DOUBLE
/// mono-pitch truss — two identical flat frames filling the depth —
/// whose top chord rises heel->high end toward +X.
/// Replaces the static wh_truss OBJ for placed trusses so the member
/// layout follows the block's panel count — the inspector stepper
/// and the plan symbol both read it.
List<Face3> trussLocalFaces(
  int panels,
  double span,
  double depth,
  double rise, {
  bool single = false,
  bool dbl = false,
}) {
  final n = (panels < 2 ? 4 : panels).clamp(2, 12);
  if (dbl) return _dblTrussFaces(n, span, depth, rise);
  final chord = single ? 0.08 : 0.10, web = single ? 0.06 : 0.075;
  const wood = 0xFF8D6E63, woodDark = 0xFF6D4C41;
  // members are lumber on edge — ~0.05 m into the roof plane, NOT the
  // truss footprint depth (def.d 0.18): full-depth member boxes drew
  // their front AND back plates as two parallel flat trusses
  final dep = math.min(depth, 0.05);
  final s = span / 2;
  double zt(double x) => rise * (1 - (x / s).abs());
  final out = <Face3>[
    ..._memberBox(-s, 0, s, 0, chord, dep, wood),
    ..._memberBox(-s, 0, 0, rise, chord, dep, wood),
    ..._memberBox(0, rise, s, 0, chord, dep, wood),
  ];
  if (single) {
    // king-post: center post + struts from the quarter-points of the
    // bottom chord up to the rafter at the eighth-point
    out.addAll(_memberBox(0, 0, 0, rise, web, dep * 0.7, woodDark));
    out.addAll(
      _memberBox(-s * 0.5, 0, -s * 0.25, zt(s * 0.25), web, dep * 0.7, wood),
    );
    out.addAll(
      _memberBox(s * 0.5, 0, s * 0.25, zt(s * 0.25), web, dep * 0.7, wood),
    );
    return out;
  }
  // fink-family W webbing: compression stubs (top_i -> bot_i) and
  // tension diagonals (bot_i -> top_{i+1}) zigzag eave to eave — the
  // real '4 over 3' / '6 over 5' / '8 over 7' pattern
  final (p, tops, bots) = finkNodes(n, span);
  for (var i = 0; i < bots.length; i++) {
    final bx = bots[i], t1 = tops[i], t2 = tops[i + 1];
    out.addAll(_memberBox(t1, zt(t1), bx, 0, web, dep * 0.7, woodDark));
    out.addAll(_memberBox(bx, 0, t2, zt(t2), web, dep * 0.7, wood));
    // double-fink and up (p >= 5): a vertical web at each bottom
    // panel joint rises to the rafter — the Double Howe (KK) /
    // Triple Fan / KKK families all carry these posts, so a
    // stretched truss gains BOTH the extra W cells and the posts
    if (p >= 5) {
      out.addAll(_memberBox(bx, 0, bx, zt(bx), web, dep * 0.7, woodDark));
    }
  }
  return out;
}

/// The 'truss-dbl' frame: ONE mono-pitch plate (bottom chord, top
/// chord rising heel->high end, end posts, fink-family zigzag
/// webbing) — called twice at ±y to build the supplied skp's two
/// parallel frames.
List<Face3> _dblTrussFaces(int n, double span, double depth, double rise) {
  const wood = 0xFF8D6E63, woodDark = 0xFF6D4C41;
  const chord = 0.10, web = 0.06, plate = 0.06;
  final s = span / 2;
  final zlo = rise * 0.18; // heel height measured off the skp export
  double zt(double x) => zlo + (rise - zlo) * (x + s) / span;
  List<Face3> frame() {
    final out = <Face3>[
      ..._memberBox(-s, 0, s, 0, chord, plate, wood),
      ..._memberBox(-s, zlo, s, rise, chord, plate, wood),
      ..._memberBox(-s, 0, -s, zlo, web, plate * 0.8, woodDark),
      ..._memberBox(s, 0, s, rise, web, plate * 0.8, woodDark),
    ];
    // mono-pitch webbing: the fink-family zigzag — stubs top_i->bot_i,
    // diagonals bot_i->top_{i+1} — a proper fan layout on one slope;
    // p >= 5 adds the same vertical posts as the gabled variant
    final (p, tops, bots) = finkNodes(n, span);
    for (var i = 0; i < bots.length; i++) {
      final bx = bots[i], t1 = tops[i], t2 = tops[i + 1];
      out.addAll(
        _memberBox(t1, zt(t1), bx, 0, web, plate * 0.8, woodDark),
      );
      out.addAll(_memberBox(bx, 0, t2, zt(t2), web, plate * 0.8, wood));
      if (p >= 5) {
        out.addAll(
          _memberBox(bx, 0, bx, zt(bx), web, plate * 0.8, woodDark),
        );
      }
    }
    return out;
  }

  // the skp's two ~0.09 m frames side by side in the 0.18 depth —
  // a visible gap keeps the "double" reading distinct from 'single'
  final off = depth / 2 - plate / 2 - 0.01;
  List<Face3> at(double dy) => [
    for (final f in frame())
      Face3([for (final p in f.v) [p[0], p[1] + dy, p[2]]], f.n, f.argb),
  ];
  return [...at(-off), ...at(off)];
}

/// Chord vs web member lengths (m) of the parametric truss — mirrors
/// the mesh in [trussLocalFaces] so the steel takeoff counts exactly
/// the members the model draws: bottom+top chords vs the
/// vertical/diagonal web steel. Returns (chordLm, webLm).
(double, double) trussChordWeb(
  int panels,
  double span,
  double rise, {
  bool single = false,
  bool dbl = false,
}) {
  final n = (panels < 2 ? 4 : panels).clamp(2, 12);
  if (dbl) {
    // mono-pitch frame x2 plates — same fink zigzag webs + the
    // vertical posts (p >= 5) the mesh draws
    final s = span / 2, zlo = rise * 0.18;
    double zt(double x) => zlo + (rise - zlo) * (x + s) / span;
    var web = zlo + rise; // the two end posts
    final (p, tops, bots) = finkNodes(n, span);
    for (var i = 0; i < bots.length; i++) {
      web += math.sqrt(
        (tops[i] - bots[i]) * (tops[i] - bots[i]) +
            zt(tops[i]) * zt(tops[i]),
      );
      web += math.sqrt(
        (tops[i + 1] - bots[i]) * (tops[i + 1] - bots[i]) +
            zt(tops[i + 1]) * zt(tops[i + 1]),
      );
      if (p >= 5) web += zt(bots[i]); // vertical post to the rafter
    }
    final chord =
        span + math.sqrt(span * span + (rise - zlo) * (rise - zlo));
    return (chord * 2, web * 2);
  }
  final s = span / 2;
  double zt(double x) => rise * (1 - (x / s).abs());
  if (single) {
    // king-post: center post + the two struts
    double strut() => math.sqrt(
      (s * 0.25) * (s * 0.25) + zt(s * 0.25) * zt(s * 0.25),
    );
    return (span + 2 * math.sqrt(s * s + rise * rise), rise + 2 * strut());
  }
  // fink-family W: stub (top_i -> bot_i) + diagonal (bot_i -> top_{i+1})
  // + the vertical post at each bottom joint once p >= 5
  var web = 0.0;
  final (p, tops, bots) = finkNodes(n, span);
  for (var i = 0; i < bots.length; i++) {
    web += math.sqrt(
      (tops[i] - bots[i]) * (tops[i] - bots[i]) +
          zt(tops[i]) * zt(tops[i]),
    );
    web += math.sqrt(
      (tops[i + 1] - bots[i]) * (tops[i + 1] - bots[i]) +
          zt(tops[i + 1]) * zt(tops[i + 1]),
    );
    if (p >= 5) web += zt(bots[i]); // vertical post to the rafter
  }
  return (span + 2 * math.sqrt(s * s + rise * rise), web);
}

/// Member CENTERLINES of a placed truss in world space — one segment
/// per member (chords + webs), end-to-end. The 3D ghost and the
/// catalog thumb draw THESE instead of each box member's plate
/// outline, which reads as a doubled pair of lines. Same members the
/// solid mesh, plan symbol and takeoff use.
List<List<List<double>>> trussMemberLines(Block3d b, CadBlock def) {
  final local = trussLocalFaces(
    trussPanelCount(b, def),
    def.w,
    def.d,
    def.height,
    single: def.id == 'truss-sgl',
    dbl: def.id == 'truss-dbl',
  );
  final c = math.cos(b.rot), s = math.sin(b.rot);
  List<double> toWorld(List<double> p) => [
    b.x + (p[0] * b.sx * c - p[1] * b.sy * s) * b.scale,
    b.y + (p[0] * b.sx * s + p[1] * b.sy * c) * b.scale,
    p[2] * b.sz * b.scale + b.bz,
  ];
  return [
    for (final f in local)
      // -Y side plate = one face per member; its midpoints at the two
      // member ends give the member's centerline
      if (f.n[1] < -0.9)
        [
          toWorld([
            (f.v[0][0] + f.v[3][0]) / 2,
            (f.v[0][1] + f.v[3][1]) / 2,
            (f.v[0][2] + f.v[3][2]) / 2,
          ]),
          toWorld([
            (f.v[1][0] + f.v[2][0]) / 2,
            (f.v[1][1] + f.v[2][1]) / 2,
            (f.v[1][2] + f.v[2][2]) / 2,
          ]),
        ],
  ];
}

List<Face3> blockFaces(Block3d b, CadBlock def, {int floors = 1}) {
  final out = <Face3>[];
  if (def.id.startsWith('ftg-')) {
    // standalone footing pad: buried, TOP face at the block base so
    // bz = the pad's top elevation (bz 0 -> concrete under the floor)
    final w = def.w * b.sx * b.scale / 2, d = def.d * b.sy * b.scale / 2;
    final t = def.height * b.sz * b.scale;
    final fp = [
      Offset(b.x - w, b.y - d),
      Offset(b.x + w, b.y - d),
      Offset(b.x + w, b.y + d),
      Offset(b.x - w, b.y + d),
    ];
    return [
      ..._polyFaces(fp, b.bz - t, b.bz, 0xFF9E9E9E),
      // bottom cap — the pad is a closed box even though it sits buried
      Face3(
        [
          for (final p in fp.reversed) [p.dx, p.dy, b.bz - t],
        ],
        const [0, 0, -1],
        0xFF9E9E9E,
      ),
    ];
  }
  // trusses build parametrically — `panels` changes the member
  // layout, which the fixed wh_truss OBJ could never do; 'truss-sgl'
  // gets the single-member king-post mesh
  final local = isTrussDef(def.id)
      ? trussLocalFaces(
          trussPanelCount(b, def),
          def.w,
          def.d,
          def.height,
          single: def.id == 'truss-sgl',
          dbl: def.id == 'truss-dbl',
        )
      : blockMeshes[def.id];
  if (local != null && local.isNotEmpty) {
    final c = math.cos(b.rot), s = math.sin(b.rot);
    out.addAll([
      for (final f in local)
        Face3(
          [
            for (final p in f.v)
              [
                b.x + (p[0] * b.sx * c - p[1] * b.sy * s) * b.scale,
                b.y + (p[0] * b.sx * s + p[1] * b.sy * c) * b.scale,
                p[2] * b.sz * b.scale + b.bz,
              ],
          ],
          [f.n[0] * c - f.n[1] * s, f.n[0] * s + f.n[1] * c, f.n[2]],
          _tinted(f.argb, b.tint),
        ),
    ]);
  } else if (def.height > 0) {
    // sz scales the extrusion like the mesh path does — the
    // inspector's Height field writes b.sz and generic boxes used to
    // ignore it (a beam couldn't change depth); base honors b.bz so
    // lifted boxes stop rendering at ground
    final fp = blockFootprint(b, def);
    final col = _tinted(isBeamDef(def.id) ? 0xFF9E9E9E : 0xFFBCAAA4, b.tint);
    out.addAll(_polyFaces(fp, b.bz, b.bz + def.height * b.sz * b.scale, col));
    if (isBeamDef(def.id)) {
      // closed solid — a lifted beam's underside must render
      out.add(
        Face3(
          [for (final p in fp) [p.dx, p.dy, b.bz]],
          const [0, 0, -1],
          col,
        ),
      );
    }
  }
  out.addAll(blockFootingFaces(b, def, floors: floors));
  return out;
}

/// Serialize a registered imported mesh (verts re-emitted per face +
/// colors) for project JSON round-trips.
Map<String, dynamic> _meshJson(List<Face3> faces) => {
  'v': [for (final f in faces) f.v],
  'c': [for (final f in faces) f.argb],
};

/// Rebuild [blockMeshes]/[customCadBlocks] entries from project JSON.
void loadCustomBlocks(List? js) {
  customCadBlocks.clear();
  for (final e in js ?? const []) {
    final m = Map<String, dynamic>.from(e as Map);
    final def = CadBlock(
      m['id'] ?? 'imp-x',
      m['name'] ?? 'Imported',
      m['cat'] ?? 'Imported',
      (m['w'] ?? 1).toDouble(),
      (m['d'] ?? 1).toDouble(),
      (m['h'] ?? 1).toDouble(),
      [
        for (final l in (m['lines'] as List? ?? []))
          [
            for (final p in (l as List))
              Offset((p[0] as num).toDouble(), (p[1] as num).toDouble()),
          ],
      ],
      opening: m['opening'] == true,
      sill: (m['sill'] ?? 0).toDouble(),
      head: (m['head'] ?? 2.1).toDouble(),
    );
    customCadBlocks.add(def);
    final mesh = Map<String, dynamic>.from(m['mesh'] ?? {});
    final vs = mesh['v'] as List? ?? [];
    final cs = mesh['c'] as List? ?? [];
    var top = 0.0;
    final faces = <Face3>[
      for (var i = 0; i < vs.length; i++)
        Face3(
          [
            for (final p in (vs[i] as List))
              [
                (p[0] as num).toDouble(),
                (p[1] as num).toDouble(),
                (p[2] as num).toDouble(),
              ],
          ],
          const [0, 0, 1],
          (i < cs.length ? cs[i] : 0xFF9E9E9E) as int,
        ),
    ];
    for (var i = 0; i < faces.length; i++) {
      faces[i] = Face3(faces[i].v, _newell(faces[i].v), faces[i].argb);
      for (final p in faces[i].v) {
        if (p[2] > top) top = p[2];
      }
    }
    blockMeshes[def.id] = faces;
    blockMeshTop[def.id] = top;
    blockMeshBox[def.id] = _aabbOf(faces);
  }
}

/// Project-JSON view of every imported block def + its mesh.
List<Map<String, dynamic>> customBlocksJson() => [
  for (final d in customCadBlocks)
    {
      'id': d.id,
      'name': d.name,
      'w': d.w,
      'd': d.d,
      'h': d.height,
      'cat': d.cat,
      'opening': d.opening,
      'sill': d.sill,
      'head': d.head,
      'lines': [
        for (final l in d.lines)
          [
            for (final p in l) [p.dx, p.dy],
          ],
      ],
      'mesh': _meshJson(blockMeshes[d.id] ?? const []),
    },
];

Offset _rotP(Offset p, double a) {
  final c = math.cos(a), s = math.sin(a);
  return Offset(p.dx * c - p.dy * s, p.dx * s + p.dy * c);
}

/// A block's polylines transformed into plan coordinates
/// (per-axis stretch → scale → rotate → translate).
List<List<Offset>> blockLines(Block3d b, CadBlock def) => [
  for (final l in def.id == 'truss' || def.id == 'truss-dbl'
      ? _trussPlanLines(trussPanelCount(b, def), def)
      : def.lines)
    [
      for (final p in l)
        _rotP(Offset(p.dx * b.sx, p.dy * b.sy) * b.scale, b.rot) +
            Offset(b.x, b.y),
    ],
];

/// The truss PLAN symbol follows the same fink-family node layout as
/// the 3D mesh — outline + bottom chord + a tick at every bottom-
/// chord web node + the W zigzag diagonals, so the sheet reads the
/// real member layout.
List<List<Offset>> _trussPlanLines(int panels, CadBlock def) {
  final n = (panels < 2 ? 4 : panels).clamp(2, 12);
  final s = def.w / 2, hd = def.d / 2;
  final out = <List<Offset>>[
    _rect(def.w, def.d),
    [Offset(-s, 0), Offset(s, 0)],
  ];
  final (_, tops, bots) = finkNodes(n, def.w);
  for (var i = 0; i < bots.length; i++) {
    final bx = bots[i];
    out.add([Offset(bx, -hd), Offset(bx, hd)]);
    // the two webs meeting at this bottom node, projected as plan
    // diagonals — reads as the W pattern on the sheet
    out.add([Offset(tops[i], -hd), Offset(bx, hd)]);
    out.add([Offset(bx, -hd), Offset(tops[i + 1], hd)]);
  }
  return out;
}

/// The block's rotated bounding quad — used for hit-testing and the
/// 3D furniture prism.
List<Offset> blockFootprint(Block3d b, CadBlock def) {
  var x0 = double.infinity, y0 = double.infinity;
  var x1 = -double.infinity, y1 = -double.infinity;
  for (final l in def.lines) {
    for (final p in l) {
      x0 = math.min(x0, p.dx);
      x1 = math.max(x1, p.dx);
      y0 = math.min(y0, p.dy);
      y1 = math.max(y1, p.dy);
    }
  }
  return [
    for (final c in [
      Offset(x0, y0),
      Offset(x1, y0),
      Offset(x1, y1),
      Offset(x0, y1),
    ])
      _rotP(Offset(c.dx * b.sx, c.dy * b.sy) * b.scale, b.rot) +
          Offset(b.x, b.y),
  ];
}

/// Every renderable face in the model — volumes, wall prisms and
/// extruded furniture prisms. The 3D preview and the elevation
/// projections both consume this.
List<Face3> modelFaces(Model3d m) {
  final out = <Face3>[];
  var g = 0;
  // each source object gets its own grp so the painter's depth
  // sort treats it as a unit (never face-interleaved with others)
  void addGroup(List<Face3> fs) {
    g++;
    for (final f in fs) {
      out.add(Face3(f.v, f.n, f.argb, g));
    }
  }

  for (final v in m.volumes) {
    addGroup(volumeFaces(v));
  }
  for (final w in m.walls) {
    // each solid piece (cut by openings, extended at joins) is a
    // separate prism = separate group
    for (var i = 0; i < w.segs; i++) {
      for (final p in wallSegPieces(m, w, i)) {
        addGroup(_polyFaces(p, w.base, w.top, w.argb));
      }
      final bands = _openingBands(m, w, i);
      if (bands.isNotEmpty) addGroup(bands);
      // structural RC bands: the same joined/cut spans re-emitted
      // 0.06 wider in concrete grey — tie beam at the wall base,
      // bond beam at the top (NSCP 2015 detail options).
      if (w.tieBeam || w.bondBeam) {
        const beamArgb = 0xFF9E9E9E;
        for (final s in wallSegSpans(m, w, i)) {
          final a = Offset(w.pts[i * 2], w.pts[i * 2 + 1]);
          final bb = Offset(w.pts[i * 2 + 2], w.pts[i * 2 + 3]);
          final len = (bb - a).distance;
          if (len < 1e-9) continue;
          final dir = (bb - a) / len;
          final nx = -dir.dy * (w.thickness / 2 + 0.03);
          final ny = dir.dx * (w.thickness / 2 + 0.03);
          final p0 = a + dir * s.$1, p1 = a + dir * s.$2;
          final poly = [
            Offset(p0.dx + nx, p0.dy + ny),
            Offset(p1.dx + nx, p1.dy + ny),
            Offset(p1.dx - nx, p1.dy - ny),
            Offset(p0.dx - nx, p0.dy - ny),
          ];
          if (w.tieBeam) {
            addGroup(_polyFaces(poly, w.base, w.base + 0.20, beamArgb));
          }
          if (w.bondBeam) {
            addGroup(_polyFaces(poly, w.top - 0.20, w.top, beamArgb));
          }
        }
      }
    }
  }
  for (final b in m.blocks) {
    final def = cadBlock(b.def);
    if (def == null) continue;
    // blockFaces includes the footing pad + pedestal stem, so the
    // footing is part of the block's group: render AND pick it as one
    addGroup(blockFaces(b, def, floors: columnStackFloors(m, b)));
  }
  // C-purlin channels ride on the truss top chords — derived geometry
  // like the RC bands, not pickable parts; one run per group
  for (final run in purlinRuns(m)) {
    addGroup(run);
  }
  return out;
}

/// The orthographic views a generated sheet shows. plan/roof + the
/// four elevations are architectural; structural/electrical/plumbing
/// are discipline plans — separate drawings so each trade sees only
/// what it builds.
enum SheetView {
  plan,
  roof,
  front,
  rear,
  left,
  right,
  structural,
  roofFrame,
  electrical,
  plumbing,
}

/// Fixture sets for the discipline plans: an electrical plan marks
/// powered/lighting blocks, a plumbing plan marks wet fixtures.
const kElectricalDefs = {
  'ceiling-fan',
  'tv',
  'lamp-floor',
  'lamp-table',
  'microwave',
  'stove',
  'fridge',
  'washer',
  'dryer',
  'picture',
};
const kPlumbingDefs = {
  'wc',
  'basin',
  'tub',
  'shower',
  'urinal',
  'sink-kit',
  'washer',
};

/// Project one model into 2D outlines for a view, keeping only faces
/// that face the viewer (normal · lookDir < 0) so rear edges don't
/// clutter the elevation. Returned in view-local meters.
List<List<Offset>> projectView(Model3d m, SheetView view) {
  final out = <List<Offset>>[];
  if (view == SheetView.structural) {
    // foundation layout: wall outlines + column squares + every pad
    // (flagged column footings and placed ftg-* pad blocks)
    for (final w in m.walls) {
      for (var i = 0; i < w.segs; i++) {
        out.add(w.segPoly(i));
      }
    }
    for (final b in m.blocks) {
      final def = cadBlock(b.def);
      if (def == null) continue;
      if (b.def == 'col-sq' || b.def == 'col-rd' || b.def.startsWith('ftg-')) {
        out.add(blockFootprint(b, def));
      }
      if (b.footing) {
        final hw = footingFor(def.w * b.sx * b.scale, b.footW).w / 2;
        out.add([
          Offset(b.x - hw, b.y - hw),
          Offset(b.x + hw, b.y - hw),
          Offset(b.x + hw, b.y + hw),
          Offset(b.x - hw, b.y + hw),
        ]);
      }
    }
    return out;
  }
  if (view == SheetView.electrical || view == SheetView.plumbing) {
    for (final w in m.walls) {
      for (var i = 0; i < w.segs; i++) {
        out.add(w.segPoly(i));
      }
    }
    final want = view == SheetView.electrical ? kElectricalDefs : kPlumbingDefs;
    for (final b in m.blocks) {
      final def = cadBlock(b.def);
      if (def != null && want.contains(b.def)) {
        out.addAll(blockLines(b, def));
      }
    }
    return out;
  }
  if (view == SheetView.plan ||
      view == SheetView.roof ||
      view == SheetView.roofFrame) {
    // top view = footprints + wall outlines (roof ignores furniture)
    for (final vol in m.volumes) {
      out.add([
        for (var i = 0; i < vol.fp.length; i += 2)
          Offset(vol.fp[i], vol.fp[i + 1]),
      ]);
    }
    for (final w in m.walls) {
      for (var i = 0; i < w.segs; i++) {
        // plan = the joined/opening-carved pieces the canvas + 3D
        // draw (closed corners, real gaps at doors/windows); the
        // roof keeps continuous outlines — a door must not notch
        // the roof footprint
        if (view == SheetView.plan) {
          out.addAll(wallSegPieces(m, w, i));
        } else {
          out.add(w.segPoly(i));
        }
      }
    }
    if (view == SheetView.plan) {
      for (final b in m.blocks) {
        final def = cadBlock(b.def);
        if (def != null) out.addAll(blockLines(b, def));
      }
    }
    if (view == SheetView.roof || view == SheetView.roofFrame) {
      // the ROOFING/FRAMING LAYOUT: truss plan symbols + the ridge/
      // eaves/purlin/roofing field the placed truss array + spec imply
      // — the framing sheet drops the roofing-sheet joint lines and
      // adds member tags + spacing dims in _roofFrameSheet instead
      for (final b in m.blocks) {
        final def = cadBlock(b.def);
        // roof sheets draw the ROOF — stored/ground trusses stay out
        // (same trussInRoof rule as the fields/tags/purlins)
        if (def == null || !trussInRoof(m, b)) continue;
        out.addAll(blockLines(b, def));
      }
      out.addAll(
        _roofFraming(m, const [], sheetJoints: view == SheetView.roof),
      );
    }
    return out;
  }
  // elevations: semantic outline, not the raw mesh — see
  // [elevationPrims] for the per-category version (fills vs detail)
  return [for (final p in elevationPrims(m, view)) p.$1];
}

/// One roof FIELD: the set of same-direction trusses that share a
/// ridge run, reduced to the geometry every consumer needs — the
/// roof plan's framing lines, the spec callout, and the roofing
/// takeoff all read this one source so they can never disagree.
class RoofField {
  final Offset ridge; // unit dir along the ridge run
  final Offset perp; // unit dir across the span (bearing->bearing)
  final Offset center;
  final double u0, u1; // ridge-run extents past the outermost trusses
  final double half; // horizontal half-span (bearing -> ridge)
  final double rise;
  final int count; // trusses in the field
  final List<Block3d> trusses;

  const RoofField({
    required this.ridge,
    required this.perp,
    required this.center,
    required this.u0,
    required this.u1,
    required this.half,
    required this.rise,
    required this.count,
    required this.trusses,
  });

  double get runLen => u1 - u0;
  double get span => half * 2;
  double get slope => math.sqrt(half * half + rise * rise);

  /// slope eave->ridge INCLUDING the overhang tail (the sheet length).
  double slopeRoof(RoofSpec s) => slope * (half + s.overhang) / half;

  /// measured spacing between adjacent trusses in the field (m) —
  /// the purlin SPAN that sizes the auto section table.
  double get measuredSpacing {
    if (trusses.length < 2) return 0;
    final us = [
      for (final b in trusses)
        (b.x - center.dx) * ridge.dx + (b.y - center.dy) * ridge.dy,
    ]..sort();
    var sum = 0.0;
    for (var i = 1; i < us.length; i++) {
      sum += us[i] - us[i - 1];
    }
    return sum / (us.length - 1);
  }

  List<Offset> lineAt(double off, {double a = 0, double? b}) => [
    center + ridge * (a + u0) + perp * off,
    center + ridge * (b ?? u1) + perp * off,
  ];

  /// Purlin rows at spec spacing: eave->ridge on both slopes. Bays
  /// divide the slope so spacing never exceeds the spec; the apex
  /// carries a flanking PAIR (half a bay out each side), so each
  /// slope holds bays+1 rows.
  int purlinBays(RoofSpec s) => math.max(1, (slope / s.purlinSpace).ceil());
  int purlinRows(RoofSpec s) => 2 * purlinBays(s) + 2;
  double purlinLm(RoofSpec s) => purlinRows(s) * runLen;
  /// 6m commercial lengths, lapped over supports — per row.
  int purlinPcs(RoofSpec s) => purlinRows(s) * (runLen / 6.0).ceil();
  double roofArea(RoofSpec s) => 2 * slopeRoof(s) * runLen;
}

/// Group the model's trusses into roof fields by span direction
/// (10° buckets) so perpendicular wings get a field each, THEN by
/// ridge line + contiguous run — two same-rot roofs on different
/// ridge lines (parallel wings, an L) or split by a wide gap are
/// separate fields, so purlin runs can never bridge across a wing
/// or dangle through walls between distant trusses.
List<RoofField> roofFields(Model3d m) {
  final byRot = <int, List<Block3d>>{};
  for (final b in m.blocks) {
    // only trusses that actually bear — a stored/ground piece must not
    // seed a roof field (ground scatter sprays phantom purlin runs)
    if (!trussInRoof(m, b) || cadBlock(b.def) == null) continue;
    var a = b.rot % math.pi;
    if (a < 0) a += math.pi;
    // % 18: rot ~0 and rot ~pi are the same truss orientation —
    // without the wrap a 0.02-rad and a 3.12-rad truss split fields
    byRot.putIfAbsent((a * 18 / math.pi).round() % 18, () => []).add(b);
  }
  final out = <RoofField>[];
  for (final g in byRot.values) {
    final b0 = g.first;
    final def = cadBlock(b0.def)!;
    final half = def.w * b0.sx * b0.scale / 2;
    final rise = def.height * b0.sz * b0.scale;
    final rd = Offset(-math.sin(b0.rot), math.cos(b0.rot));
    final perp = Offset(math.cos(b0.rot), math.sin(b0.rot));
    // (u along ridge, v along span dir) in world coords — trusses on
    // the same ridge LINE share v; parallel roofs differ in v by the
    // spacing between their bearing plates
    final uv = [
      for (final b in g)
        (
          b,
          u: b.x * rd.dx + b.y * rd.dy,
          v: b.x * perp.dx + b.y * perp.dy,
        ),
    ]..sort((a, b) => a.v.compareTo(b.v));
    // cluster by ridge line first (v within the field's half-span —
    // a real roof's own slopes can't split it), then by run gaps
    final lineTol = math.max(0.6, half * 0.6);
    final gapTol = math.max(2.5, m.roof.trussSpacing * 1.8);
    var line = <(Block3d, {double u, double v})>[];
    void flush() {
      if (line.isEmpty) return;
      line.sort((a, b) => a.u.compareTo(b.u));
      var run = <(Block3d, {double u, double v})>[];
      void emit() {
        if (run.isEmpty) return;
        var cx = 0.0, cy = 0.0;
        // ENVELOPE half/rise over the run's own trusses — after
        // out-to-out auto-fit different bays can carry different
        // stretches, and a field plane solved from b0 alone bores the
        // shared purlin runs THROUGH the taller trusses' chords
        var hlf = 0.0, rs = 0.0;
        for (final t in run) {
          cx += t.$1.x;
          cy += t.$1.y;
          final d = cadBlock(t.$1.def);
          if (d == null) continue;
          hlf = math.max(hlf, d.w * t.$1.sx * t.$1.scale / 2);
          rs = math.max(rs, d.height * t.$1.sz * t.$1.scale);
        }
        if (hlf <= 0) hlf = half;
        if (rs <= 0) rs = rise;
        final cent = Offset(cx / run.length, cy / run.length);
        // ridge follows the RUN's real first->last direction, not
        // b0's stored rot — a hand-placed jitter on the first truss
        // used to tilt the whole purlin set off the truss line
        var rdf = rd;
        if (run.length > 1) {
          final dd = Offset(
            run.last.$1.x - run.first.$1.x,
            run.last.$1.y - run.first.$1.y,
          );
          if (dd.distance > 1e-6) {
            rdf = dd / dd.distance;
            if (rdf.dx * rd.dx + rdf.dy * rd.dy < 0) rdf = -rdf;
          }
        }
        final perpf = Offset(rdf.dy, -rdf.dx);
        double uOf(Block3d b) => b.x * rdf.dx + b.y * rdf.dy;
        final cu = cent.dx * rdf.dx + cent.dy * rdf.dy;
        final u0 =
            run.map((t) => uOf(t.$1)).reduce(math.min) - cu - 0.5;
        final u1 =
            run.map((t) => uOf(t.$1)).reduce(math.max) - cu + 0.5;
        out.add(
          RoofField(
            ridge: rdf,
            perp: perpf,
            center: cent,
            u0: u0,
            u1: u1,
            half: hlf,
            rise: rs,
            count: run.length,
            trusses: [for (final t in run) t.$1],
          ),
        );
      }

      for (final t in line) {
        // split on a run gap OR a base-elevation step — trusses at
        // different bz are different roof levels; merging them puts
        // the shared purlin plane mid-air between them
        if (run.isNotEmpty &&
            (t.u - run.last.u > gapTol ||
                (t.$1.bz - run.last.$1.bz).abs() > 0.3)) {
          emit();
          run = [];
        }
        run.add(t);
      }
      emit();
      line = [];
    }

    for (final t in uv) {
      if (line.isNotEmpty && (t.v - line.last.v).abs() > lineTol) {
        flush();
      }
      line.add(t);
    }
    flush();
  }
  // MERGE pass — one roof fragmented by the rot buckets (hand-placed
  // jitter) or a sparse unplaced bay must still read as ONE run so the
  // C-purlins connect truss to truss: same roof line (parallel ridge +
  // same v offset + same bearing level) whose truss-run gap fits inside
  // a purlin span merges into one field. A real wing stays split —
  // different ridge direction, different roof line, different level,
  // or a gap wider than a purlin can plausibly reach.
  final connectTol = math.max(4.5, m.roof.trussSpacing * 2.0);
  for (var go = true; go;) {
    go = false;
    outer:
    for (var i = 0; i < out.length; i++) {
      for (var j = i + 1; j < out.length; j++) {
        final a = out[i], b = out[j];
        final dot = a.ridge.dx * b.ridge.dx + a.ridge.dy * b.ridge.dy;
        if (dot.abs() < 0.978) continue; // ridges not parallel (~12 deg)
        final lineTol = math.max(0.6, math.max(a.half, b.half) * 0.6);
        final dc = b.center - a.center;
        if ((dc.dx * a.perp.dx + dc.dy * a.perp.dy).abs() > lineTol) {
          continue; // different roof line (parallel wing)
        }
        var bzA = 0.0, bzB = 0.0;
        for (final t in a.trusses) {
          bzA += t.bz;
        }
        for (final t in b.trusses) {
          bzB += t.bz;
        }
        if ((bzA / a.count - bzB / b.count).abs() > 0.3) continue;
        // truss-run extents on a's ridge axis — the gap between the
        // two fragments' nearest trusses decides the join
        double uOf(Block3d t) => t.x * a.ridge.dx + t.y * a.ridge.dy;
        var aLo = double.infinity, aHi = -double.infinity;
        var bLo = double.infinity, bHi = -double.infinity;
        for (final t in a.trusses) {
          final u = uOf(t);
          aLo = math.min(aLo, u);
          aHi = math.max(aHi, u);
        }
        for (final t in b.trusses) {
          final u = uOf(t);
          bLo = math.min(bLo, u);
          bHi = math.max(bHi, u);
        }
        final gap = math.max(0.0, math.max(aLo - bHi, bLo - aHi));
        if (gap > connectTol) continue;
        final ts = [...a.trusses, ...b.trusses]
          ..sort((p, q) => uOf(p).compareTo(uOf(q)));
        var cx = 0.0, cy = 0.0;
        for (final t in ts) {
          cx += t.x;
          cy += t.y;
        }
        final cent = Offset(cx / ts.length, cy / ts.length);
        final cu = cent.dx * a.ridge.dx + cent.dy * a.ridge.dy;
        out[i] = RoofField(
          ridge: a.ridge,
          perp: a.perp,
          center: cent,
          u0: uOf(ts.first) - cu - 0.5,
          u1: uOf(ts.last) - cu + 0.5,
          half: math.max(a.half, b.half),
          rise: math.max(a.rise, b.rise),
          count: ts.length,
          trusses: ts,
        );
        out.removeAt(j);
        go = true;
        break outer;
      }
    }
  }
  return out;
}

List<double> _u3(List<double> v) {
  final l = math.sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
  return l < 1e-9 ? const [0, 0, 1] : [v[0] / l, v[1] / l, v[2] / l];
}

/// A plate as a 3D prism: segment [a] -> [b] (the plate's long axis)
/// with thickness [t] along unit [tDir], extruded along unit [e] from
/// scalar extents [e0] to [e1]. Six quad faces — the general version
/// of [_memberBox] for members that don't live in a local xz-plane.
List<Face3> _platePrism(
  List<double> a,
  List<double> b,
  List<double> tDir,
  double t,
  List<double> e,
  double e0,
  double e1,
  int argb,
) {
  final hw = t / 2;
  final seg = _u3([b[0] - a[0], b[1] - a[1], b[2] - a[2]]);
  final tn = tDir;
  List<double> at(List<double> p, double s, double u) => [
        p[0] + tn[0] * s + e[0] * u,
        p[1] + tn[1] * s + e[1] * u,
        p[2] + tn[2] * s + e[2] * u,
      ];
  final a0 = at(a, -hw, e0), a1 = at(a, hw, e0);
  final b0 = at(b, -hw, e0), b1 = at(b, hw, e0);
  final ae0 = at(a, -hw, e1), ae1 = at(a, hw, e1);
  final be0 = at(b, -hw, e1), be1 = at(b, hw, e1);
  final ne = [-e[0], -e[1], -e[2]];
  final nt = [-tn[0], -tn[1], -tn[2]];
  final ns = [-seg[0], -seg[1], -seg[2]];
  return [
    Face3([a0, a1, b1, b0], ne, argb), // e0 end cap
    Face3([ae0, be0, be1, ae1], e, argb), // e1 end cap
    Face3([a0, b0, be0, ae0], nt, argb), // plate underside
    Face3([a1, ae1, be1, b1], tn, argb), // plate topside
    Face3([a0, ae0, ae1, a1], ns, argb), // a end cap
    Face3([b0, b1, be1, be0], seg, argb), // b end cap
  ];
}

/// A lipped C-channel extruded along unit [e] from [e0] to [e1]:
/// web + two flanges + two downturned lips — the real C-purlin
/// profile per mill tables (web x flange x lip x t). Section coords:
/// [u] = upslope dir (the channel OPENING faces upslope toward the
/// ridge), [n] = outward roof normal. [origin] is the bottom-flange
/// underside at the web. Faces point both ways on each plate so the
/// channel reads solid through the open side.
List<Face3> _purlinChannel(
  List<double> origin,
  List<double> u,
  List<double> n,
  List<double> e,
  double e0,
  double e1,
  double depth,
  double flange,
  double lip,
  double t,
  int argb,
) {
  List<double> pt(double du, double dn) => [
        origin[0] + u[0] * du + n[0] * dn,
        origin[1] + u[1] * du + n[1] * dn,
        origin[2] + u[2] * du + n[2] * dn,
      ];
  return [
    // web stands off the roof at the channel's DOWNSLOPE edge (u=0)
    ..._platePrism(pt(0, 0), pt(0, depth), u, t, e, e0, e1, argb),
    // bottom flange lies on the roof plane running upslope
    ..._platePrism(pt(0, 0), pt(flange, 0), n, t, e, e0, e1, argb),
    // top flange carries the sheeting
    ..._platePrism(pt(0, depth), pt(flange, depth), n, t, e, e0, e1, argb),
    // downturned lips at the free edge, turned toward each other
    ..._platePrism(pt(flange, depth), pt(flange, depth - lip), u, t, e, e0, e1, argb),
    ..._platePrism(pt(flange, 0), pt(flange, lip), u, t, e, e0, e1, argb),
  ];
}

/// Visual wall thickness for the channel plates: real 1.2-2.0mm is
/// sub-pixel at building scale, so floor it at 12mm — reads as formed
/// sheet metal next to the (already exaggerated) truss members.
const double _purlinVisT = 0.012;

/// The C-purlin channels in 3D: one continuous run along the ridge at
/// every row station the roof plan draws — ridge, interior rows at
/// `purlinBays` divisions, and the last row ON the truss chord edge
/// (the eave line — steel ends where the trusses end; only the roof
/// SHEET overhangs). Opening faces upslope (PH detailing convention),
/// section keyed on the field's measured/spec truss spacing.
/// Each run is returned as its own face GROUP for the painter's sort.
List<List<Face3>> purlinRuns(Model3d m) {
  final s = m.roof;
  const argb = 0xFFB0BEC5; // galvanized blue-grey
  final out = <List<Face3>>[];
  for (final f in roofFields(m)) {
    var bz = 0.0;
    for (final t in f.trusses) {
      bz += t.bz;
    }
    bz /= f.trusses.length;
    final spacing = s.trussSpacing > 0 ? s.trussSpacing : f.measuredSpacing;
    final sec = s.purlinSection(spacing);
    final depth = int.parse(sec.$1.substring(2)) / 1000;
    final flange = RoofSpec.purlinFlange(sec.$1) / 1000;
    final lip = (depth * 1200).clamp(12.0, 20.0) / 1000; // ~12-20mm
    final t = math.max(sec.$2 / 1000, _purlinVisT);
    final r3 = [f.ridge.dx, f.ridge.dy, 0.0];
    final sl = f.slope;
    final bays = f.purlinBays(s);
    // runs end AT the gable trusses — the field's ±0.5 extension is
    // roof-SHEET overhang, not steel: purlins poking past the last
    // truss were the "hanging" channels in the screenshots. A lone
    // truss keeps its ±0.5 stub so the channels don't collapse to a
    // zero-length dot
    final pu0 = f.count > 1 ? f.u0 + 0.5 : f.u0;
    final pu1 = f.count > 1 ? f.u1 - 0.5 : f.u1;
    // each row rides the TOP SURFACE of every chord it crosses — the
    // tallest member chord sets the straight channel's height (purlins
    // can't dip between differing trusses). The underside runs along
    // the roof normal n3, so the required LIFT is the member's
    // half-thickness projected through n3 — (chordHalf + plateT/2) *
    // sl/half vertically. A flat +0.05 vertical bump only credits
    // 0.05*half/sl ALONG n3 and leaves the channel ~1cm INSIDE the
    // chord on any real slope — the "purlins bore through the
    // rafters" screenshot.
    double topAt(double o) {
      var z = -double.infinity;
      for (final tb in f.trusses) {
        final d = cadBlock(tb.def);
        if (d == null) continue;
        final th = d.w * tb.sx * tb.scale / 2;
        final tr = d.height * tb.sz * tb.scale;
        // the truss's OWN span coordinate for this field station — a
        // truss offset off the field's ridge line reads its chord at
        // the wrong o otherwise, floating the whole run above the
        // chords (the screenshot gap)
        final tp = Offset(math.cos(tb.rot), math.sin(tb.rot));
        final oT =
            (f.center.dx + f.perp.dx * o - tb.x) * tp.dx +
            (f.center.dy + f.perp.dy * o - tb.y) * tp.dy;
        // mono-pitch frames rise heel->peak on ONE slope (zlo at the
        // low heel); fink/king-posts peak at the center
        final zc = tb.def == 'truss-dbl'
            ? tb.bz + tr * 0.18 + tr * 0.82 * (oT + th) / (2 * th)
            : tb.bz + tr * (1 - oT.abs() / th);
        // centerline -> top surface: half the chord member thickness
        // (fink/dbl 0.10 -> 0.05, single 0.08 -> 0.04) plus half the
        // channel's own plate gauge, projected through n3
        final zt =
            zc + ((tb.def == 'truss-sgl' ? 0.04 : 0.05) + t / 2) * sl / f.half;
        if (zt > z) z = zt;
      }
      return z.isFinite
          ? z
          : bz + f.rise * (1 - o.abs() / f.half) + (0.05 + t / 2) * sl / f.half;
    }

    for (final sgn in [1.0, -1.0]) {
      // upslope (toward ridge) and outward-normal unit vectors in the
      // perp-z plane for this slope
      final u3 = [
        -sgn * f.perp.dx * f.half / sl,
        -sgn * f.perp.dy * f.half / sl,
        f.rise / sl,
      ];
      final n3 = [
        sgn * f.perp.dx * f.rise / sl,
        sgn * f.perp.dy * f.rise / sl,
        f.half / sl,
      ];
      // stations: the ridge carries a PAIR flanking the apex — half
      // a bay below it each side, leaving room for the ridge cap (a
      // channel dead ON o=0 reads as one purlin straddling the peak).
      // Interior rows divide the half-span; the LAST row sits ON the
      // truss chord edge (the eave line) — a purlin at half+overhang
      // hangs past the chord end on nothing. The sheet edge still
      // overhangs (roof plan/elev draw it); steel doesn't.
      final offs = <double>[
        sgn * f.half / (2 * bays),
        for (var j = 1; j < bays; j++) sgn * f.half * j / bays,
        sgn * f.half,
      ];
      for (final o in offs) {
        // +8mm so the channel underside kisses the chord's top surface
        // without z-fighting it — surfaces that share a plane flicker
        final zTop = topAt(o) + 0.008;
        // station point on the roof surface; the channel's bottom
        // flange underside starts there, centered on the row line
        final base = [
          f.center.dx + f.perp.dx * o,
          f.center.dy + f.perp.dy * o,
          zTop,
        ];
        final origin = [
          base[0] - u3[0] * flange / 2 - n3[0] * t / 2,
          base[1] - u3[1] * flange / 2 - n3[1] * t / 2,
          base[2] - u3[2] * flange / 2 - n3[2] * t / 2,
        ];
        out.add(
          _purlinChannel(
            origin,
            u3,
            n3,
            r3,
            pu0,
            pu1,
            depth,
            flange,
            lip,
            t,
            argb,
          ),
        );
      }
    }
  }
  return out;
}

/// The roof FRAMING plan the placed truss array implies: ridge line,
/// eave lines at the spec overhang, C-purlin rows at the spec spacing
/// (auto table when unset), rake edges closing the roof outline at
/// both run ends, and (unless [sheetJoints] is off) light roofing-
/// sheet joints across the ridge run at the sheet's effective
/// coverage width — the "roofing layout" a real roof plan carries.
List<List<Offset>> _roofFraming(
  Model3d m,
  List<Block3d> trusses, {
  bool sheetJoints = true,
}) {
  final s = m.roof;
  final out = <List<Offset>>[];
  for (final f in roofFields(m)) {
    final oh = s.overhang;
    final bays = f.purlinBays(s);
    out.add(f.lineAt(0)); // ridge
    for (final sgn in [1.0, -1.0]) {
      out.add(f.lineAt(sgn * (f.half + oh))); // eave
      // ridge-pair row — same half-bay offset the 3D purlins use
      out.add(f.lineAt(sgn * f.half / (2 * bays)));
      for (var j = 1; j < bays; j++) {
        out.add(f.lineAt(sgn * f.half * j / bays)); // C-purlin row
      }
    }
    // gable-end roof boundary: eave corner -> ridge end -> eave corner
    for (final u in [f.u0, f.u1]) {
      out.add([
        f.center + f.ridge * u + f.perp * (f.half + oh),
        f.center + f.ridge * u,
        f.center + f.ridge * u - f.perp * (f.half + oh),
      ]);
    }
    // roofing sheet joints — light lines across the slope at each
    // effective-coverage bay (what the corrugated/rib sheets snap to)
    if (!sheetJoints) continue;
    final cols = (f.runLen / s.roofEffWidth).floor();
    for (var c = 1; c <= cols; c++) {
      final u = f.u0 + s.roofEffWidth * c;
      out.add([
        f.center + f.ridge * u - f.perp * (f.half + oh),
        f.center + f.ridge * u + f.perp * (f.half + oh),
      ]);
    }
  }
  return out;
}

/// Spec callout rows for the roof sheet: one NOTES block naming the
/// roofing, purlin spec+spacing and truss array — the values every
/// checker looks for on a real roof framing plan.
List<String> roofCallouts(Model3d m) {
  final s = m.roof;
  final fields = roofFields(m);
  if (fields.isEmpty) return const [];
  var trusses = 0, pcs = 0;
  var area = 0.0, lm = 0.0;
  var spacing = 0.0;
  for (final f in fields) {
    trusses += f.count;
    pcs += f.purlinPcs(s);
    area += f.roofArea(s);
    lm += f.purlinLm(s);
    spacing = math.max(
      spacing,
      s.trussSpacing > 0 ? s.trussSpacing : f.measuredSpacing,
    );
  }
  final sec = s.purlinSection(spacing);
  return [
    'ROOFING: ${s.roofLabel}  (eff. ${_num(s.roofEffWidth)}m cover)',
    'PURLINS: C-${sec.$1.substring(2)}x${RoofSpec.purlinFlange(sec.$1)}x${sec.$2}mm C-PURLINS '
        '@ ${_num(s.purlinSpace)}m O.C. - $pcs PCS x 6m (${_num(lm)} lm)',
    'TRUSSES: $trusses @ ${_num(spacing > 0 ? spacing : 0)}m O.C. '
        '- ${fields.map((f) => _num(f.span)).join('/')}m SPAN',
    'ROOF AREA: ${_num(area)} SQ.M  (OH ${s.overhang}M)',
    'PRELIMINARY SIZING ONLY - VERIFY PURLIN/SPAN + WIND UPLIFT W/ '
        'LICENSED CIVIL/STRUCTURAL ENGINEER (RA 544 / NSCP)',
  ];
}

/// Architectural elevation for one view — the projected OUTLINES of
/// the building's own parts instead of every viewer-facing mesh
/// triangle (the old wireframe). Draws volume bands, wall faces and
/// columns as fill rects, then doors/windows seated on a wall that
/// actually faces this view as detail linework; furniture, fixtures
/// and footings never appear (an elevation shows massing + skin, not
/// the interior). A painter's hidden-line pass drops any fill fully
/// covered by a nearer fill in BOTH width and height, so rear walls,
/// interior partitions and interior columns don't ghost through the
/// facade. Returns `(polyline, aci)` pairs — aci 7 outlines, aci 8
/// opening detail; 2-point entries are open lines (sill/rail), the
/// rest closed rects.
/// Door/window schedule tags shared by every sheet — D1..Dn for
/// door*/doorway* blocks, W1..Wn for window*, O# for other openings,
/// numbered in model order so the floor plan and the four elevations
/// always agree (the convention real drawing sets use).
Map<int, String> blockTags(Model3d m) {
  final tags = <int, String>{};
  var d = 0, w = 0, o = 0;
  for (var i = 0; i < m.blocks.length; i++) {
    final def = cadBlock(m.blocks[i].def);
    if (def == null || !def.opening) continue;
    final id = m.blocks[i].def;
    tags[i] = id.startsWith('window')
        ? 'W${++w}'
        : id.startsWith('door')
        ? 'D${++d}'
        : 'O${++o}';
  }
  return tags;
}

/// 'T1'..'Tn' tags for every placed truss — numbered along each
/// field's ridge (u order) so the ROOF PLAN and ROOF FRAMING sheets
/// tag the SAME member with the same number; keyed by block index.
Map<int, String> trussTags(Model3d m) {
  final tags = <int, String>{};
  final fields = roofFields(m);
  final seen = <Block3d>{};
  var n = 0;
  for (final f in fields) {
    final ts = [...f.trusses]..sort((a, b) {
      final ua =
          (a.x - f.center.dx) * f.ridge.dx +
          (a.y - f.center.dy) * f.ridge.dy;
      final ub =
          (b.x - f.center.dx) * f.ridge.dx +
          (b.y - f.center.dy) * f.ridge.dy;
      return ua.compareTo(ub);
    });
    for (final t in ts) {
      final bi = m.blocks.indexOf(t);
      if (bi < 0 || !seen.add(t)) continue;
      tags[bi] = 'T${++n}';
    }
  }
  // trusses that matched no field (unseated storage pieces are
  // excluded — a ground truss isn't a roof member and gets no tag)
  for (var i = 0; i < m.blocks.length; i++) {
    if (trussInRoof(m, m.blocks[i]) && !tags.containsKey(i)) {
      tags[i] = 'T${++n}';
    }
  }
  return tags;
}

/// An opening whose host wall faces the view and survived the hidden-
/// line pass — the rect the elevation actually drew (u = horizontal
/// sheet axis, z = vertical), plus the block and def for tagging.
typedef HostedOpening = ({
  int bi,
  Block3d b,
  CadBlock def,
  double u0,
  double u1,
  double zl,
  double zh,
});

List<(List<Offset>, int)> elevationPrims(Model3d m, SheetView view) =>
    _elevScene(m, view).prims;

/// The openings an elevation really drew — used by [elevationPrims]
/// for linework and by the sheet generator for the D#/W# callouts.
List<HostedOpening> hostedOpenings(Model3d m, SheetView view) =>
    _elevScene(m, view).hosted;

/// One shared pass: the painted wall/volume/column fills, the hosted
/// opening rectangles and their detail lines — everything a sheet
/// view needs to draw and annotate an elevation.
({
  List<(List<Offset>, int)> prims,
  List<HostedOpening> hosted,
})
_elevScene(Model3d m, SheetView view) {
  final out = <(List<Offset>, int)>[];
  final yView = view == SheetView.front || view == SheetView.rear;
  // horizontal drawing axis for this view (rear/left mirror so the
  // sheet reads from the outside)
  double uOf(double x, double y) => switch (view) {
    SheetView.front => x,
    SheetView.rear => -x,
    SheetView.left => -y,
    _ => y,
  };
  // distance toward the viewer — nearer parts occlude farther ones
  double dOf(double x, double y) => switch (view) {
    SheetView.front => y,
    SheetView.rear => -y,
    SheetView.left => x,
    _ => -x,
  };
  List<Offset> rect(double u0, double u1, double z0, double z1) => [
    Offset(u0, z0),
    Offset(u1, z0),
    Offset(u1, z1),
    Offset(u0, z1),
  ];
  final cands =
      <({double u0, double u1, double z0, double z1, double d, String key})>[];
  for (final v in m.volumes) {
    var u0 = double.infinity, u1 = -double.infinity, d = double.infinity;
    for (var i = 0; i < v.fp.length; i += 2) {
      u0 = math.min(u0, uOf(v.fp[i], v.fp[i + 1]));
      u1 = math.max(u1, uOf(v.fp[i], v.fp[i + 1]));
      d = math.min(d, dOf(v.fp[i], v.fp[i + 1]));
    }
    if (u1 - u0 > 1e-6) {
      cands.add((
        u0: u0,
        u1: u1,
        z0: v.base,
        z1: v.base + v.height,
        d: d,
        key: '',
      ));
    }
  }
  for (var wi = 0; wi < m.walls.length; wi++) {
    final w = m.walls[wi];
    for (var i = 0; i < w.segs; i++) {
      final a = Offset(w.pts[i * 2], w.pts[i * 2 + 1]);
      final b = Offset(w.pts[i * 2 + 2], w.pts[i * 2 + 3]);
      var u0 = math.min(uOf(a.dx, a.dy), uOf(b.dx, b.dy));
      var u1 = math.max(uOf(a.dx, a.dy), uOf(b.dx, b.dy));
      // edge-on seg (runs away from the viewer): its projected face
      // collapses to a strip the width of the wall — the corner line
      if (u1 - u0 < w.thickness / 2) {
        final uc = (u0 + u1) / 2;
        u0 = uc - w.thickness / 2;
        u1 = uc + w.thickness / 2;
      }
      cands.add((
        u0: u0,
        u1: u1,
        z0: w.base,
        z1: w.base + w.height,
        d: dOf((a.dx + b.dx) / 2, (a.dy + b.dy) / 2),
        key: '$wi:$i',
      ));
    }
  }
  final opens = <(int, Block3d, CadBlock)>[];
  for (var bi = 0; bi < m.blocks.length; bi++) {
    final b = m.blocks[bi];
    final def = cadBlock(b.def);
    if (def == null) continue;
    if (b.def.startsWith('col-')) {
      var u0 = double.infinity, u1 = -double.infinity;
      for (final p in blockFootprint(b, def)) {
        final t = uOf(p.dx, p.dy);
        u0 = math.min(u0, t);
        u1 = math.max(u1, t);
      }
      if (u1 - u0 < 1e-6) continue;
      // drawn at the block's real local z-extent (mesh box when one
      // is registered, def height otherwise) so the elevation shows
      // exactly the height the 3D view renders
      final lb = blockLocalBox(def);
      cands.add((
        u0: u0,
        u1: u1,
        z0: b.bz + lb[2] * b.sz * b.scale,
        z1: b.bz + lb[5] * b.sz * b.scale,
        d: dOf(b.x, b.y),
        key: '',
      ));
    } else if (def.opening) {
      opens.add((bi, b, def));
    }
  }
  // painter's pass: a fill whose rect is fully covered (width AND
  // height) by an already-drawn nearer fill never reaches the sheet
  cands.sort((a, b) => a.d.compareTo(b.d));
  final drawn = <({double u0, double u1, double z0, double z1})>[];
  final drawnSegs = <String>{};
  for (final c in cands) {
    final covered = drawn.any(
      (r) =>
          r.u0 <= c.u0 + 1e-9 &&
          r.u1 >= c.u1 - 1e-9 &&
          r.z0 <= c.z0 + 1e-9 &&
          r.z1 >= c.z1 - 1e-9,
    );
    if (covered) continue;
    drawn.add((u0: c.u0, u1: c.u1, z0: c.z0, z1: c.z1));
    drawnSegs.add(c.key);
    out.add((rect(c.u0, c.u1, c.z0, c.z1), 7));
  }
  // openings only draw when their host wall seg faces this view AND
  // survived the hidden-line pass (a rear-wall door stays off the
  // front elevation)
  final hosted = <HostedOpening>[];
  for (final (bi, b, def) in opens) {
    var best = 0.5;
    var onWall = false;
    for (var wi = 0; wi < m.walls.length; wi++) {
      final w = m.walls[wi];
      for (var i = 0; i < w.segs; i++) {
        if (!drawnSegs.contains('$wi:$i')) continue;
        final a = Offset(w.pts[i * 2], w.pts[i * 2 + 1]);
        final c = Offset(w.pts[i * 2 + 2], w.pts[i * 2 + 3]);
        final dir = c - a;
        final l2 = dir.dx * dir.dx + dir.dy * dir.dy;
        if (l2 < 1e-9) continue;
        // front/rear see x-running wall faces, left/right y-running
        final facesView = yView
            ? dir.dx.abs() >= dir.dy.abs()
            : dir.dy.abs() > dir.dx.abs();
        if (!facesView) continue;
        final t = (((b.x - a.dx) * dir.dx + (b.y - a.dy) * dir.dy) / l2).clamp(
          0.0,
          1.0,
        );
        final d = (Offset(b.x, b.y) - (a + dir * t)).distance;
        if (d < best) {
          best = d;
          onWall = true;
        }
      }
    }
    if (!onWall) continue;
    var u0 = double.infinity, u1 = -double.infinity;
    for (final p in blockFootprint(b, def)) {
      final t = uOf(p.dx, p.dy);
      u0 = math.min(u0, t);
      u1 = math.max(u1, t);
    }
    // same sill..head band the 3D wall-cut uses, so the drawn opening
    // lands exactly where the hole is
    final k = b.sz * b.scale;
    final zl = def.sill * k + b.bz, zh = def.head * k + b.bz;
    if (u1 - u0 < 1e-6 || zh - zl < 1e-6) continue;
    hosted.add((bi: bi, b: b, def: def, u0: u0, u1: u1, zl: zl, zh: zh));
    out.add((rect(u0, u1, zl, zh), 8));
    final meshLines = _openingMeshElev(b, def, u0, u1, zl, zh);
    if (meshLines != null) {
      out.addAll(meshLines);
    } else if (zl > b.bz + 0.3) {
      // window: sill horn + mid-rail read as glazing in elevation
      out.add(([Offset(u0 - 0.06, zl), Offset(u1 + 0.06, zl)], 8));
      out.add(([Offset(u0, (zl + zh) / 2), Offset(u1, (zl + zh) / 2)], 8));
    } else if (u1 - u0 > 1.3) {
      // wide door/pass: center split is the leaf meeting line
      final uc = (u0 + u1) / 2;
      out.add(([Offset(uc, zl), Offset(uc, zh)], 8));
    }
  }
  // trusses read on gable-end elevations: the frame triangle + web
  // verticals projected to (u,z) — same bays as the 3D mesh and the
  // plan symbol. Edge-on trusses skip (the other elevation pair
  // shows their face).
  for (final b in m.blocks) {
    if (!isTrussDef(b.def)) continue;
    final def = cadBlock(b.def);
    if (def == null) continue;
    final span = def.w * b.sx * b.scale;
    final rise = def.height * b.sz * b.scale;
    final u = Offset(math.cos(b.rot), math.sin(b.rot));
    final e1 = Offset(b.x, b.y) - u * span / 2;
    final e2 = Offset(b.x, b.y) + u * span / 2;
    final u0 = math.min(uOf(e1.dx, e1.dy), uOf(e2.dx, e2.dy));
    final u1 = math.max(uOf(e1.dx, e1.dy), uOf(e2.dx, e2.dy));
    if (u1 - u0 < 0.3) continue;
    final z0 = b.bz, zr = b.bz + rise;
    final uc = (u0 + u1) / 2;
    // 'truss-dbl' is mono-pitch: the chord rises heel->high end along
    // the block's +X axis — uLo/uHi keep the slope direction honest
    // whichever way the block is rotated
    final mono = def.id == 'truss-dbl';
    final uLo = uOf(e1.dx, e1.dy), uHi = uOf(e2.dx, e2.dy);
    final zLo = z0 + rise * 0.18;
    if (mono) {
      out.add(([Offset(uLo, zLo), Offset(uHi, zr)], 8));
      out.add(([Offset(uLo, z0), Offset(uLo, zLo)], 8));
      out.add(([Offset(uHi, z0), Offset(uHi, zr)], 8));
    } else {
      out.add(([Offset(u0, z0), Offset(uc, zr)], 8));
      out.add(([Offset(uc, zr), Offset(u1, z0)], 8));
    }
    out.add(([Offset(u0, z0), Offset(u1, z0)], 8));
    // the same fink-family W zigzag the mesh builds: stub top_i->bot_i
    // + diagonal bot_i->top_{i+1} — fractions along the span map to
    // the u axis; zTop follows the mono slope or the gable triangle
    final n = trussPanelCount(b, def);
    final (_, tops, bots) = finkNodes(n, span);
    double zTopOf(double x) => mono
        ? zLo + (zr - zLo) * ((x + span / 2) / span)
        : zr - (x / (span / 2)).abs() * rise;
    double uOfX(double x) =>
        uLo + (uHi - uLo) * ((x + span / 2) / span);
    for (var i = 0; i < bots.length; i++) {
      final ub = uOfX(bots[i]);
      out.add(([Offset(uOfX(tops[i]), zTopOf(tops[i])), Offset(ub, z0)], 8));
      out.add(([Offset(ub, z0), Offset(uOfX(tops[i + 1]), zTopOf(tops[i + 1]))], 8));
    }
  }
  // THE ROOF ITSELF — each field projects its real roof band onto
  // (u,z). Gable-end views (truss span parallel to the view) get the
  // two slope surfaces: sheet-top and purlin/tail underside lines,
  // fascia at the overhang edge, a ridge cap and one tick per purlin
  // row station — the SAME stations plan + 3D purlinRuns use. Eave-
  // side views (ridge parallel to the view) get the roof silhouette:
  // tail underside at the overhang up to the ridge cap, plus the
  // sheet's eave edge. All geometry comes from RoofField + RoofSpec
  // so the elevations can't disagree with the plan or the 3D.
  final spec = m.roof;
  for (final f in roofFields(m)) {
    var bz = 0.0;
    for (final t in f.trusses) {
      bz += t.bz;
    }
    bz /= f.trusses.length;
    final sp = spec.trussSpacing > 0 ? spec.trussSpacing : f.measuredSpacing;
    final sec = spec.purlinSection(sp);
    final depth = int.parse(sec.$1.substring(2)) / 1000;
    final band = depth + 0.02; // channel + sheet above the chord top
    final oh = spec.overhang, hf = f.half, sl = f.slope, rs = f.rise;
    final uC = uOf(f.center.dx, f.center.dy);
    final pU = uOf(f.center.dx + f.perp.dx, f.center.dy + f.perp.dy) - uC;
    final rU = uOf(f.center.dx + f.ridge.dx, f.center.dy + f.ridge.dy) - uC;
    if (pU.abs() >= 0.7) {
      // gable-end view — both slope surfaces + buildup band + ticks
      Offset pt(double sgn, double o, double l) => Offset(
        uC + pU * sgn * (o + l * rs / sl),
        bz + rs * (1 - o.abs() / hf) + 0.05 + l * hf / sl,
      );
      final bays = f.purlinBays(spec);
      for (final sgn in [1.0, -1.0]) {
        out.add(([pt(sgn, hf + oh, band), pt(sgn, 0, band)], 7));
        out.add(([pt(sgn, hf + oh, 0), pt(sgn, 0, 0)], 8));
        out.add(([pt(sgn, hf + oh, 0), pt(sgn, hf + oh, band)], 8));
        for (var j = 0; j < bays; j++) {
          // j=0 is the ridge-pair row flanking the apex (half a bay
          // out); the rest divide the half-span to the eave line
          final o = j == 0 ? hf / (2 * bays) : hf * j / bays;
          out.add(([pt(sgn, o, 0), pt(sgn, o, band)], 8));
        }
      }
      out.add(([pt(-1, 0, band), pt(1, 0, band)], 7)); // ridge cap
    } else if (rU.abs() >= 0.7) {
      // eave-side view — silhouette band + the sheet's eave edge
      final ue0 = uOf(
        f.center.dx + f.ridge.dx * f.u0,
        f.center.dy + f.ridge.dy * f.u0,
      );
      final ue1 = uOf(
        f.center.dx + f.ridge.dx * f.u1,
        f.center.dy + f.ridge.dy * f.u1,
      );
      final lo = math.min(ue0, ue1), hi = math.max(ue0, ue1);
      final zBot = bz + rs * (1 - (hf + oh) / hf) + 0.05;
      final zTop = bz + rs + 0.05 + band * hf / sl;
      out.add((
        [Offset(lo, zBot), Offset(hi, zBot), Offset(hi, zTop), Offset(lo, zTop)],
        7,
      ));
      out.add((
        [Offset(lo, zBot + band * hf / sl), Offset(hi, zBot + band * hf / sl)],
        8,
      ));
    }
  }
  return (prims: out, hosted: hosted);
}

/// Elevation linework projected from the block's REAL registered mesh:
/// every face parallel to the view plane is flattened onto (u, z) and
/// deduped, so the sheet shows the same frame / sash rails / mullions /
/// projecting sill board the 3D model renders — sliding sashes keep
/// their staggered meeting stiles, leaf frames their rails. Faces
/// perpendicular to the view collapse onto the parallel faces' edges,
/// so they add nothing. Null when no mesh is registered or too few
/// faces project — the caller falls back to the generic symbol.
List<(List<Offset>, int)>? _openingMeshElev(
  Block3d b,
  CadBlock def,
  double u0,
  double u1,
  double zl,
  double zh,
) {
  final mesh = blockMeshes[def.id];
  final box = blockMeshBox[def.id];
  if (mesh == null || box == null || mesh.isEmpty) return null;
  // the u axis is the mesh's wider local extent (a fitted OBJ can sit
  // 90deg-swapped); faces normal to the other axis are view-parallel
  final uAx = (box[3] - box[0]) >= (box[4] - box[1]) ? 0 : 1;
  final dAx = 1 - uAx;
  final uc = (u0 + u1) / 2;
  final cu = (box[uAx] + box[uAx + 3]) / 2;
  // local units are def units (procedural + _objLocal-fitted alike):
  // u anchored on the drawn opening, z on def.sill so sill boards and
  // floor tracks land where they really are — even outside the band
  final su = (u1 - u0) / math.max(1e-9, def.w * b.sx * b.scale);
  final sz = (zh - zl) / math.max(1e-9, def.head - def.sill);
  Offset map(List<double> p) =>
      Offset(uc + (p[uAx] - cu) * su, zl + (p[2] - def.sill) * sz);
  final seen = <String>{};
  final out = <(List<Offset>, int)>[];
  for (final f in mesh) {
    if (f.v.length < 4 || f.n[dAx].abs() < 0.9) continue;
    final poly = [for (final p in f.v) map(p)];
    var drawn = false;
    for (var i = 0; i < poly.length; i++) {
      if ((poly[i] - poly[(i + 1) % poly.length]).distance > 1e-4) {
        drawn = true;
        break;
      }
    }
    if (!drawn) continue;
    final key = [
      for (final p in poly)
        '${p.dx.toStringAsFixed(3)},${p.dy.toStringAsFixed(3)}',
    ]..sort();
    if (!seen.add(key.join('|'))) continue;
    out.add((poly, 8));
    if (out.length > 48) break; // pathological meshes stay readable
  }
  return out.length < 2 ? null : out;
}

String _num(double v) {
  var s = v.toStringAsFixed(4);
  while (s.contains('.') && s.endsWith('0')) {
    s = s.substring(0, s.length - 1);
  }
  return s.endsWith('.') ? s.substring(0, s.length - 1) : s;
}

/// Dimension figures on generated sheets — 2 decimals like the 2D
/// plan's `_fmt` ("5.04", "0.30", "1.50"), not the coordinate _num.
String _dim2(double v) => v.toStringAsFixed(2);

void _poly(StringBuffer b, List<Offset> pts, {int aci = 7, bool open = false}) {
  b.write(
    '0\nLWPOLYLINE\n8\nOUTLINES\n62\n$aci\n90\n${pts.length}\n70\n${open ? 0 : 1}\n',
  );
  for (final p in pts) {
    b.write('10\n${_num(p.dx)}\n20\n${_num(p.dy)}\n');
  }
}

/// A SOLID-fill HATCH with one polyline boundary — how real CAD plans
/// show wall mass. Matches the loop layout our own parser reads.
void _hatch(StringBuffer b, List<Offset> pts, {int aci = 9}) {
  b.write(
    '0\nHATCH\n8\nWALLS\n62\n$aci\n'
    '10\n0\n20\n0\n30\n0\n210\n0\n220\n0\n230\n1\n'
    '2\nSOLID\n70\n1\n71\n0\n91\n1\n92\n2\n93\n${pts.length}\n',
  );
  for (final p in pts) {
    b.write('10\n${_num(p.dx)}\n20\n${_num(p.dy)}\n');
  }
  b.write('97\n1\n');
}

void _text(
  StringBuffer b,
  double x,
  double y,
  double h,
  String s, {
  int aci = 8,
  double rot = 0,
}) {
  b.write(
    '0\nTEXT\n8\nLABELS\n62\n$aci\n10\n${_num(x)}\n20\n${_num(y)}\n40\n${_num(h)}\n1\n$s\n'
    '${rot != 0 ? '50\n${_num(rot)}\n' : ''}',
  );
}

/// AABB collision tracker for sheet annotation. Every emitted text
/// claims its sheet-space box; movable labels (block tags, footing
/// callouts) must clear all claimed boxes before drawing, so text
/// never lands on text. Fixed ink (dimensions, room labels) claims
/// first, movable labels negotiate around it.
class _SheetLabels {
  final boxes = <(double, double, double, double)>[];

  /// Approximate rendered box of a left-anchored text: the simplex
  /// advance is ~0.6·h per char; a touch of side bearing + descender
  /// keeps neighbours honest.
  static (double, double, double, double) box(
    double x,
    double y,
    double h,
    String s,
  ) => (x - h * 0.08, y - h * 0.30, x + s.length * h * 0.62 + h * 0.08, y + h * 1.1);

  bool hits((double, double, double, double) b) => boxes.any(
    (q) => b.$1 < q.$3 && b.$3 > q.$1 && b.$2 < q.$4 && b.$4 > q.$2,
  );

  /// Emit a text through [buf] AND claim its box.
  void text(
    StringBuffer buf,
    double x,
    double y,
    double h,
    String s, {
    int aci = 8,
    double rot = 0,
  }) {
    _text(buf, x, y, h, s, aci: aci, rot: rot);
    boxes.add(box(x, y, h, s));
  }

  /// Claim a box without emitting (e.g. the caller draws via _text
  /// itself — register the same footprint).
  void claim(double x, double y, double h, String s) =>
      boxes.add(box(x, y, h, s));
}

List<Offset> _shift(List<Offset> poly, double dx, double dy) => [
  for (final p in poly) p + Offset(dx, dy),
];

// Shared min across a view's polys (not per-poly) keeps multi-volume
// spacing inside the view truthful.
double _minX(List<List<Offset>> polys) => polys.fold(
  double.infinity,
  (a, ps) => math.min(a, ps.fold(double.infinity, (b, p) => math.min(b, p.dx))),
);
double _minY(List<List<Offset>> polys) => polys.fold(
  double.infinity,
  (a, ps) => math.min(a, ps.fold(double.infinity, (b, p) => math.min(b, p.dy))),
);

/// Sheet titles per generated view — each view becomes its OWN
/// drawing entry (the user asked for a separate sheet per elevation).
const kSheetTitle = {
  SheetView.plan: 'FLOOR PLAN',
  SheetView.roof: 'ROOF PLAN',
  SheetView.front: 'FRONT ELEVATION',
  SheetView.rear: 'REAR ELEVATION',
  SheetView.left: 'LEFT ELEVATION',
  SheetView.right: 'RIGHT ELEVATION',
  SheetView.structural: 'STRUCTURAL PLAN - FOUNDATION',
  SheetView.roofFrame: 'ROOF FRAMING PLAN',
  SheetView.electrical: 'ELECTRICAL PLAN',
  SheetView.plumbing: 'PLUMBING PLAN',
};

/// Emit ONE model view as a standalone DXF sheet. The floor plan gets
/// the real-plan treatment (wall mass fills + outline + per-segment
/// dimension labels + furniture linework); the roof keeps massing
/// only; each elevation is normalized onto a z=0 baseline.
/// Exterior-dimension ordinates for one plan axis: cm-rounded
/// coordinate -> (min,max) perpendicular extent of contributing
/// geometry. Horizontal segs feed the X maps, vertical the Y maps.
/// Shared by the plan painter's dim strings and the DXF sheet so
/// generated drawings dimension the SAME boundaries as the 2D view.
///
/// The envelope the chains measure is the WALLS' bound — furniture,
/// door swings and footing pads inflate [Model3d.bounds] past the
/// building face and would push the ordinate edge off the walls they
/// are supposed to dimension.
(double, double, double, double)? wallEnv(Model3d m) {
  double? x0, y0, x1, y1;
  for (final w in m.walls) {
    final b = w.bounds;
    x0 = x0 == null ? b.$1 : math.min(x0, b.$1);
    y0 = y0 == null ? b.$2 : math.min(y0, b.$2);
    x1 = x1 == null ? b.$3 : math.max(x1, b.$3);
    y1 = y1 == null ? b.$4 : math.max(y1, b.$4);
  }
  if (x0 == null) return null;
  return (x0, y0!, x1!, y1!);
}

List<double> wallOrds(Model3d m, int side) {
  final bb = m.bounds;
  if (bb == null) return const [];
  final we = wallEnv(m);
  final xAxis = side < 2;
  final edge = switch (side) {
    0 => we?.$2 ?? bb.$2,
    1 => we?.$4 ?? bb.$4,
    2 => we?.$1 ?? bb.$1,
    _ => we?.$3 ?? bb.$3,
  };
  final set = <int>{};
  for (final w in m.walls) {
    for (var i = 0; i < w.segs; i++) {
      final a = Offset(w.pts[i * 2], w.pts[i * 2 + 1]);
      final b = Offset(w.pts[i * 2 + 2], w.pts[i * 2 + 3]);
      final d = b - a;
      if (d.distance < 1e-9) continue;
      if ((d.dx.abs() >= d.dy.abs()) != xAxis) continue;
      final perp = xAxis ? (a.dy + b.dy) / 2 : (a.dx + b.dx) / 2;
      if ((perp - edge).abs() > w.thickness / 2 + 0.35) continue;
      for (final p in [a, b]) {
        set.add(((xAxis ? p.dx : p.dy) * 100).round());
      }
    }
  }
  return [for (final k in set.toList()..sort()) k / 100];
}

/// Emit one DXF dimension string: extension lines from the bound
/// edge, an inner ordinate-to-ordinate chain with 45° ticks, an
/// outer overall line, and gap + overall text. [side] 0=bottom
/// 1=top 2=left 3=right; coords are already sheet-space ([ox]/[oy]
/// applied by the caller).
void _dimString(
  StringBuffer buf,
  Model3d m,
  int side,
  (double, double, double, double, double) bb,
  double ox,
  double oy,
  double th, {
  _SheetLabels? labels,
}) {
  final xAxis = side < 2;
  final ords = wallOrds(m, side);
  final vert = !xAxis;
  final sign = side == 0 || side == 2 ? -1.0 : 1.0;
  final edge = switch (side) {
    0 => bb.$2,
    1 => bb.$4,
    2 => bb.$1,
    _ => bb.$3,
  };
  if (ords.length < 2) return;
  final single = ords.length == 2;
  Offset pt(double run, double perp) =>
      vert ? Offset(perp + ox, run + oy) : Offset(run + ox, perp + oy);
  const gap = 0.15, line1 = 0.62, line2 = 1.06;
  final o0 = ords.first, o1 = ords.last;
  final d1 = edge + sign * (gap + line1), d2 = edge + sign * (gap + line2);
  _poly(buf, [pt(o0, d1), pt(o1, d1)], aci: 9, open: true);
  if (!single) _poly(buf, [pt(o0, d2), pt(o1, d2)], aci: 9, open: true);
  final tk = th * 0.28;
  for (final r in ords) {
    _poly(buf, [pt(r, edge + sign * 0.05), pt(r, d1)], aci: 9, open: true);
    for (final dl in (r == o0 || r == o1) && !single ? [d1, d2] : [d1]) {
      final s = pt(r, dl);
      _poly(
        buf,
        [s + Offset(-tk, -tk), s + Offset(tk, tk)],
        aci: 8,
        open: true,
      );
    }
  }
  for (var i = 0; i + 1 < ords.length; i++) {
    final a = ords[i], b = ords[i + 1];
    if (b - a < 0.10) continue;
    final mid = pt((a + b) / 2, d1 + sign * th * 0.4);
    final fs = th * (single ? 0.6 : 0.5), s = _dim2(b - a);
    _text(buf, mid.dx, mid.dy, fs, s, aci: single ? 7 : 8);
    labels?.claim(mid.dx, mid.dy, fs, s);
  }
  if (!single) {
    final midAll = pt((o0 + o1) / 2, d2 + sign * th * 0.4);
    final s = _dim2(o1 - o0);
    _text(buf, midAll.dx, midAll.dy, th * 0.6, s, aci: 7);
    labels?.claim(midAll.dx, midAll.dy, th * 0.6, s);
  }
}

/// Diagonal-seg dimension strings for the DXF: same rule as the
/// plan painter — non-axis-aligned segs get a string PARALLEL to
/// the seg, parked outside the band away from the model center.
void _diagStrings(
  StringBuffer buf,
  Model3d m,
  (double, double, double, double, double) bb,
  double ox,
  double oy,
  double th, {
  _SheetLabels? labels,
}) {
  for (final w in m.walls) {
    var cx = 0.0, cy = 0.0;
    final np = w.pts.length ~/ 2;
    for (var i = 0; i < np; i++) {
      cx += w.pts[i * 2];
      cy += w.pts[i * 2 + 1];
    }
    cx /= np;
    cy /= np;
    for (var i = 0; i < w.segs; i++) {
      final a = Offset(w.pts[i * 2], w.pts[i * 2 + 1]);
      final b = Offset(w.pts[i * 2 + 2], w.pts[i * 2 + 3]);
      final len = (b - a).distance;
      if (len < 1e-9) continue;
      final dir = (b - a) / len;
      if (dir.dx.abs() < 0.20 || dir.dy.abs() < 0.20) continue;
      final ords = <double>{
        for (final s in wallSegSpans(m, w, i))
          for (final e in [s.$1, s.$2]) e.clamp(0.0, len),
      }.toList()..sort();
      if (ords.length < 2) continue;
      final single = ords.length == 2;
      var n = Offset(-dir.dy, dir.dx);
      final mid = (a + b) / 2;
      if (n.dx * (mid.dx - cx) + n.dy * (mid.dy - cy) < 0) n = -n;
      const gap = 0.15, line1 = 0.62, line2 = 1.06;
      final fOff = w.thickness / 2;
      Offset at(double t, double perp) =>
          a + dir * t + n * perp + Offset(ox, oy);
      final d1 = fOff + gap + line1, d2 = fOff + gap + line2;
      _poly(buf, [at(ords.first, d1), at(ords.last, d1)], aci: 9, open: true);
      if (!single) {
        _poly(buf, [at(ords.first, d2), at(ords.last, d2)], aci: 9, open: true);
      }
      final tk = th * 0.28;
      for (final t in ords) {
        _poly(buf, [at(t, fOff + 0.05), at(t, d1)], aci: 9, open: true);
        for (final dl
            in (t == ords.first || t == ords.last) && !single
                ? [d1, d2]
                : [d1]) {
          final s = at(t, dl);
          _poly(
            buf,
            [s + Offset(-tk, -tk), s + Offset(tk, tk)],
            aci: 8,
            open: true,
          );
        }
      }
      for (var k = 0; k + 1 < ords.length; k++) {
        final g = ords[k + 1] - ords[k];
        if (g < 0.10) continue;
        final p = at((ords[k] + ords[k + 1]) / 2, d1 + th * 0.4);
        final fs = th * (single ? 0.6 : 0.5), s = _dim2(g);
        _text(buf, p.dx, p.dy, fs, s, aci: single ? 7 : 8);
        labels?.claim(p.dx, p.dy, fs, s);
      }
      if (!single) {
        final p = at((ords.first + ords.last) / 2, d2 + th * 0.4);
        final s = _dim2(ords.last - ords.first);
        _text(buf, p.dx, p.dy, th * 0.6, s, aci: 7);
        labels?.claim(p.dx, p.dy, th * 0.6, s);
      }
    }
  }
}

/// WIDTH + HEIGHT dimension strings on one hosted elevation opening —
/// the same grammar as [_dimString] (extension lines off the jamb
/// edges, a dim line with 45° ticks, the metric value on the line).
/// Width parks BELOW a raised sill or ABOVE a grade-level head; the
/// height string rides whichever side of the opening has more room.
/// [ox]/[oy] are the sheet-space shift, [all] the sibling openings
/// used for the side pick.
void _openingDims(
  StringBuffer buf,
  HostedOpening o,
  double ox,
  double oy,
  double th,
  List<HostedOpening> all,
) {
  final tk = th * 0.28;
  final raised = o.zl - o.b.bz >= 0.05;
  // --- horizontal WIDTH string
  final zDim = raised ? o.zl - th * 2.9 : o.zh + th * 1.7;
  final zObj = raised ? o.zl : o.zh;
  final out = raised ? -1.0 : 1.0; // ext-line direction, away from body
  for (final ux in [o.u0, o.u1]) {
    _poly(
      buf,
      [
        Offset(ux + ox, zObj + out * 0.05 + oy),
        Offset(ux + ox, zDim + out * th * 0.15 + oy),
      ],
      aci: 9,
      open: true,
    );
    final p = Offset(ux + ox, zDim + oy);
    _poly(buf, [p + Offset(-tk, -tk), p + Offset(tk, tk)],
        aci: 8, open: true);
  }
  _poly(
    buf,
    [Offset(o.u0 + ox, zDim + oy), Offset(o.u1 + ox, zDim + oy)],
    aci: 9,
    open: true,
  );
  final ws = _dim2(o.u1 - o.u0);
  _text(
    buf,
    (o.u0 + o.u1) / 2 + ox - ws.length * th * 0.45 * 0.3,
    zDim + out * th * 0.15 + oy,
    th * 0.45,
    ws,
  );

  // --- vertical HEIGHT string on the roomier side
  var rightGap = double.infinity, leftGap = double.infinity;
  for (final q in all) {
    if (q.bi == o.bi) continue;
    if (q.u0 >= o.u1 - 1e-6) rightGap = math.min(rightGap, q.u0 - o.u1);
    if (q.u1 <= o.u0 + 1e-6) leftGap = math.min(leftGap, o.u0 - q.u1);
  }
  final left = rightGap < th * 2.4 && leftGap > rightGap;
  final s = left ? -1.0 : 1.0;
  final uEdge = left ? o.u0 : o.u1;
  final uDim = uEdge + s * th * 1.5;
  for (final z in [o.zl, o.zh]) {
    _poly(
      buf,
      [
        Offset(uEdge + s * 0.05 + ox, z + oy),
        Offset(uDim + s * th * 0.15 + ox, z + oy),
      ],
      aci: 9,
      open: true,
    );
    final p = Offset(uDim + ox, z + oy);
    _poly(buf, [p + Offset(-tk, -tk), p + Offset(tk, tk)],
        aci: 8, open: true);
  }
  _poly(
    buf,
    [Offset(uDim + ox, o.zl + oy), Offset(uDim + ox, o.zh + oy)],
    aci: 9,
    open: true,
  );
  final hs = _dim2(o.zh - o.zl);
  _text(
    buf,
    uDim + s * th * 0.5 + ox,
    (o.zl + o.zh) / 2 + oy - hs.length * th * 0.45 * 0.3,
    th * 0.45,
    hs,
    rot: 90,
  );
}

/// FOUNDATION plan: thin wall outlines, every footing pad at REAL
/// size with an F# callout matching the DESIGN CALC row numbering,
/// C# column marks and placed ftg-* pads as FP#. Exterior dimension
/// strings included so workers can lay out the pads on site.
void _structuralSheet(
  StringBuffer buf,
  Model3d m,
  (double, double, double, double, double) bb,
  double ox,
  double oy,
  double th,
) {
  for (final w in m.walls) {
    for (var i = 0; i < w.segs; i++) {
      _poly(buf, _shift(w.segPoly(i), ox, oy), aci: 9);
    }
  }
  // the dim strings claim their text boxes BEFORE the F#/FP# labels
  // negotiate — pads at the bound edge used to have their callouts
  // clipped under the exterior dim ink
  final labels = _SheetLabels();
  final we = wallEnv(m);
  final dbb = (
    we?.$1 ?? bb.$1,
    we?.$2 ?? bb.$2,
    we?.$3 ?? bb.$3,
    we?.$4 ?? bb.$4,
    bb.$5,
  );
  for (var s = 0; s < 4; s++) {
    _dimString(buf, m, s, dbb, ox, oy, th, labels: labels);
  }
  _diagStrings(buf, m, bb, ox, oy, th, labels: labels);
  final cols = [
    for (final b in m.blocks)
      if (b.def == 'col-sq' || b.def == 'col-rd') b,
  ];
  // (text, quad half-extents, centre) — callouts negotiate here
  final pending = <(String, double, double, Offset)>[];
  for (var i = 0; i < cols.length; i++) {
    final b = cols[i];
    final def = cadBlock(b.def)!;
    final c = Offset(b.x + ox, b.y + oy);
    _poly(buf, _shift(blockFootprint(b, def), ox, oy), aci: 8);
    _text(
      buf,
      c.dx - th * 0.5,
      c.dy + th * 0.3,
      th * 0.55,
      'C${i + 1}',
      aci: 8,
    );
    // footings draw only at the stack-lowest column (design-calc rule)
    var stacked = false;
    for (final q in cols) {
      if (q != b &&
          q.bz < b.bz - 0.3 &&
          (Offset(q.x, q.y) - Offset(b.x, b.y)).distance < 0.4) {
        stacked = true;
      }
    }
    if (!stacked && b.footing) {
      final f = footingFor(def.w * b.sx * b.scale, b.footW);
      final hw = f.w / 2;
      final sq = [
        Offset(c.dx - hw, c.dy - hw),
        Offset(c.dx + hw, c.dy - hw),
        Offset(c.dx + hw, c.dy + hw),
        Offset(c.dx - hw, c.dy + hw),
      ];
      _poly(buf, sq, aci: 7);
      _poly(buf, [sq[0], sq[2]], aci: 9, open: true);
      _poly(buf, [sq[1], sq[3]], aci: 9, open: true);
      pending.add((
        'F${i + 1}  ${_num(f.w)}x${_num(f.w)}x${_num(f.t)} @${_num(blockFootingDepth(m, b))}M',
        hw,
        hw,
        c,
      ));
    }
  }
  var np = 0;
  for (final b in m.blocks) {
    if (!b.def.startsWith('ftg-')) continue;
    final def = cadBlock(b.def)!;
    final w = def.w * b.sx * b.scale / 2, d = def.d * b.sy * b.scale / 2;
    final c = Offset(b.x + ox, b.y + oy);
    final sq = [
      Offset(c.dx - w, c.dy - d),
      Offset(c.dx + w, c.dy - d),
      Offset(c.dx + w, c.dy + d),
      Offset(c.dx - w, c.dy + d),
    ];
    _poly(buf, sq, aci: 7);
    _poly(buf, [sq[0], sq[2]], aci: 9, open: true);
    _poly(buf, [sq[1], sq[3]], aci: 9, open: true);
    pending.add((
      'FP${++np}  ${_num(w * 2)}x${_num(d * 2)}x${_num(def.height * b.sz * b.scale)}',
      w,
      d,
      c,
    ));
  }
  // callout placement: centred under the pad (the old corner anchor
  // ran into the east dim strings), then above / right / left /
  // shifted; nothing overlaps claimed ink
  final fs = th * 0.5;
  for (final (s, hw, hd, c) in pending) {
    final w = s.length * fs * 0.62;
    final cs = <(double, double)>[];
    final step = w * 0.6 + th * 0.4;
    for (final sh in [0.0, step, -step]) {
      cs.add((c.dx + sh, c.dy - hd - th * 0.4 - fs * 1.05));
    }
    for (final sh in [0.0, step, -step]) {
      cs.add((c.dx + sh, c.dy + hd + th * 0.4 + fs * 0.3));
    }
    cs.add((c.dx + hw + th * 0.4 + w / 2, c.dy - fs * 0.4));
    cs.add((c.dx - hw - th * 0.4 - w / 2, c.dy - fs * 0.4));
    var drawn = false;
    for (final p in cs) {
      final b = (
        p.$1 - w / 2 - fs * 0.1,
        p.$2 - fs * 0.32,
        p.$1 + w / 2 + fs * 0.1,
        p.$2 + fs * 1.12,
      );
      if (labels.hits(b)) continue;
      _text(buf, p.$1 - s.length * fs * 0.31, p.$2, fs, s, aci: 8);
      labels.boxes.add(b);
      drawn = true;
      break;
    }
    if (!drawn) {
      // hopeless — drop to the bare tag centred inside the pad so
      // the pad still carries its F#/FP# mark
      final tag = s.split(' ').first;
      _text(buf, c.dx - tag.length * fs * 0.31, c.dy - fs * 0.4, fs, tag,
          aci: 8);
    }
  }
}

/// Framing NOTES for the roof-framing sheet — member sizes, spacing
/// and fastening, all derived from the same fields/spec the takeoff
/// and the A-102 roof plan read.
List<String> framingNotes(Model3d m) {
  final s = m.roof;
  final fields = roofFields(m);
  if (fields.isEmpty) return const [];
  var trusses = 0, pcs = 0;
  var span = 0.0, spacing = 0.0;
  for (final f in fields) {
    trusses += f.count;
    pcs += f.purlinPcs(s);
    span = math.max(span, f.span);
    spacing = math.max(
      spacing,
      s.trussSpacing > 0 ? s.trussSpacing : f.measuredSpacing,
    );
  }
  final sec = s.purlinSection(spacing);
  return [
    'TRUSSES: $trusses @ ${_num(spacing)}m O.C. - ANGLE-BAR TRUSS, '
        'L50x50x6 CHORDS / L40x40x4 WEB MEMBERS, ${_num(span)}m SPAN',
    'PURLINS: C-${sec.$1.substring(2)}x${RoofSpec.purlinFlange(sec.$1)}x${sec.$2}mm C-PURLINS '
        '@ ${_num(s.purlinSpace)}m O.C. - $pcs PCS x 6.0m (LAPPED OVER SUPPORTS)',
    'CONNECTIONS: E6013 WELDED JOINTS + ANGLE CLEATS AT TRUSS PANEL PTS; '
        'TEKSCREW #12x2-1/2 PURLIN-TO-TRUSS; RED OXIDE PRIMER ALL STEEL',
    'PRELIMINARY SIZING ONLY - VERIFY W/ LICENSED CIVIL/STRUCTURAL '
        'ENGINEER (RA 544 / NSCP)',
  ];
}

/// Truss-spacing dimension string on the ROOF FRAMING sheet — a dim
/// line outside the roof edge on the field's -perp side, one tick per
/// truss bay center, the bay values, and the bearing-to-bearing span.
void _trussSpacingDim(
  StringBuffer buf,
  Model3d m,
  RoofField f,
  double ox,
  double oy,
  double th,
) {
  final us = [
    for (final t in f.trusses)
      (t.x - f.center.dx) * f.ridge.dx + (t.y - f.center.dy) * f.ridge.dy,
  ]..sort();
  if (us.isEmpty) return;
  final dOff = -(f.half + m.roof.overhang + 0.9);
  Offset pt(double u, double o) => Offset(
    f.center.dx + f.ridge.dx * u + f.perp.dx * o + ox,
    f.center.dy + f.ridge.dy * u + f.perp.dy * o + oy,
  );
  _poly(buf, [pt(us.first, dOff), pt(us.last, dOff)], aci: 9, open: true);
  final tOff = -(f.half + m.roof.overhang + 0.15);
  for (final u in us) {
    // extension line from the truss's bearing side down to the dim
    _poly(buf, [pt(u, tOff), pt(u, dOff - 0.05)], aci: 9, open: true);
    _poly(
      buf,
      [
        pt(u, dOff) + Offset(-1, -1) * th * 0.28,
        pt(u, dOff) + Offset(1, 1) * th * 0.28,
      ],
      aci: 8,
      open: true,
    );
  }
  for (var i = 0; i + 1 < us.length; i++) {
    final gap = us[i + 1] - us[i];
    if (gap < 0.1) continue;
    final mid = pt((us[i] + us[i + 1]) / 2, dOff - th * 0.55);
    _text(buf, mid.dx - th * 0.3, mid.dy, th * 0.5, _dim2(gap), aci: 8);
  }
  if (us.length > 1) {
    final mid = pt((us.first + us.last) / 2, dOff - th * 1.4);
    _text(
      buf,
      mid.dx - th * 0.4,
      mid.dy,
      th * 0.6,
      _dim2(us.last - us.first),
      aci: 7,
    );
  }
}

/// ROOF FRAMING plan (S-102): the structural sheet for the truss
/// design — thin wall outlines (the bearing lines the trusses sit
/// on), truss plan symbols tagged T1..Tn (same numbering as the roof
/// plan), ridge/eave/purlin/rake linework WITHOUT the roofing-sheet
/// joints (those stay on A-102), a truss-spacing dimension string
/// per field, and the member/fastener notes.
void _roofFrameSheet(
  StringBuffer buf,
  Model3d m,
  (double, double, double, double, double) bb,
  double ox,
  double oy,
  double th,
) {
  for (final w in m.walls) {
    for (var i = 0; i < w.segs; i++) {
      _poly(buf, _shift(w.segPoly(i), ox, oy), aci: 9);
    }
  }
  for (final l in _roofFraming(m, const [], sheetJoints: false)) {
    _poly(buf, _shift(l, ox, oy), aci: 8, open: true);
  }
  final tags = trussTags(m);
  var topY = -double.infinity;
  for (var i = 0; i < m.blocks.length; i++) {
    final b = m.blocks[i];
    if (!trussInRoof(m, b)) continue;
    final def = cadBlock(b.def);
    if (def == null) continue;
    for (final l in blockLines(b, def)) {
      topY = math.max(
        topY,
        l.fold(0.0, (a, p) => math.max(a, p.dy + oy)),
      );
      _poly(buf, _shift(l, ox, oy), aci: 7, open: true);
    }
    final tag = tags[i];
    if (tag != null) {
      final u = Offset(math.cos(b.rot), math.sin(b.rot));
      final span = def.w * b.sx * b.scale;
      final tp = Offset(b.x + ox, b.y + oy) - u * (span / 2 + th * 0.6);
      _text(buf, tp.dx - th * 0.3, tp.dy, th * 0.6, tag, aci: 7);
    }
  }
  for (final f in roofFields(m)) {
    _trussSpacingDim(buf, m, f, ox, oy, th);
  }
  final notes = framingNotes(m);
  if (notes.isNotEmpty) {
    if (topY == -double.infinity) topY = oy + bb.$4 - bb.$2;
    final span = math.max(bb.$3 - bb.$1, bb.$4 - bb.$2);
    final wrapAt = math.max(30, (span / (th * 0.31)).round());
    var ny = topY + th * 1.4;
    for (final s in notes.reversed) {
      var first = true;
      for (final ln in _wrap2(s, wrapAt)) {
        _text(buf, ox + (first ? 0 : th * 0.8), ny, th * 0.5, ln, aci: 8);
        ny += th * 0.9;
        first = false;
      }
    }
  }
}

/// MEP discipline plan (electrical / plumbing): thin wall outlines +
/// only that trade's fixture symbols, labeled at real positions.
void _fixtureSheet(
  StringBuffer buf,
  Model3d m,
  SheetView view,
  (double, double, double, double, double) bb,
  double ox,
  double oy,
  double th,
) {
  for (final w in m.walls) {
    for (var i = 0; i < w.segs; i++) {
      _poly(buf, _shift(w.segPoly(i), ox, oy), aci: 9);
    }
  }
  final want = view == SheetView.electrical ? kElectricalDefs : kPlumbingDefs;
  // fixture labels negotiate against each other — a run of
  // receptacles along one wall stacked to unreadable before
  final labels = _SheetLabels();
  for (final b in m.blocks) {
    final def = cadBlock(b.def);
    if (def == null || !want.contains(b.def)) continue;
    for (final l in blockLines(b, def)) {
      _poly(buf, _shift(l, ox, oy), aci: 8, open: true);
    }
    final s = def.name.toUpperCase();
    final fs = th * 0.45, w = s.length * fs * 0.62;
    final hd = def.d * b.sy * b.scale / 2;
    final cs = <(double, double)>[
      (b.x, b.y - hd - th * 0.4 - fs * 1.05), // below
      (b.x, b.y + hd + th * 0.4 + fs * 0.3), // above
      (b.x + w * 0.6, b.y - hd - th * 0.4 - fs * 1.05), // shifted
      (b.x - w * 0.6, b.y - hd - th * 0.4 - fs * 1.05),
    ];
    for (final p in cs) {
      final bx = (
        ox + p.$1 - w / 2 - fs * 0.1,
        oy + p.$2 - fs * 0.32,
        ox + p.$1 + w / 2 + fs * 0.1,
        oy + p.$2 + fs * 1.12,
      );
      if (labels.hits(bx)) continue;
      _text(buf, ox + p.$1 - s.length * fs * 0.31, oy + p.$2, fs, s, aci: 8);
      labels.boxes.add(bx);
      break;
    }
  }
}

/// The drawing CONTENT of one sheet (no paper frame): walls,
/// fixtures, dimensions and labels in model meters. buildModelSheet
/// parses this back and lays it onto the chosen paper template.
String _sheetContent(Model3d m, SheetView view) {
  final buf = StringBuffer('0\nSECTION\n2\nENTITIES\n');
  final polys = projectView(m, view);
  if (m.bounds == null || polys.isEmpty) {
    buf.write('0\nENDSEC\n0\nEOF\n');
    return buf.toString();
  }
  final bb = m.bounds!;
  // the wall envelope drives dim coverage + chain placement — the
  // full bound (furniture/pads) parks them meters off the building
  final wbb = wallEnv(m);
  final h = math.max(bb.$5, 0.5);
  final span = math.max(bb.$3 - bb.$1, math.max(bb.$4 - bb.$2, h));
  final th = math.max(0.35, span * 0.045);
  final mx = _minX(polys), my = _minY(polys);
  // content sits at origin; label row hangs below it
  const pad = 1.0;
  final ox = -mx + pad, oy = -my + pad;
  // dims measure the wall envelope; padded 5-tuple for _dimString
  final dbb = (
    wbb?.$1 ?? bb.$1,
    wbb?.$2 ?? bb.$2,
    wbb?.$3 ?? bb.$3,
    wbb?.$4 ?? bb.$4,
    bb.$5,
  );

  if (view == SheetView.plan) {
    // every emitted text claims a sheet-space box so the movable
    // block labels can negotiate free spots — no text-on-text ink
    final labels = _SheetLabels();
    for (final wl in m.walls) {
      for (var i = 0; i < wl.segs; i++) {
        // the same joined/opening-carved pieces the plan canvas
        // paints — raw segPoly left open corner notches and no
        // door/window gaps on generated sheets
        for (final piece in wallSegPieces(m, wl, i)) {
          _hatch(buf, _shift(piece, ox, oy), aci: 9);
          _poly(buf, _shift(piece, ox, oy));
        }
        final a = Offset(wl.pts[i * 2], wl.pts[i * 2 + 1]);
        final bpt = Offset(wl.pts[i * 2 + 2], wl.pts[i * 2 + 3]);
        final len = (bpt - a).distance;
        // perimeter + diagonal segs are dimensioned by the exterior /
        // diagonal strings — a mid-wall number would duplicate them
        var covered = false;
        if (len > 1e-9) {
          final d = (bpt - a) / len;
          const e = 0.3;
          if (d.dx.abs() < 0.2 || d.dy.abs() < 0.2) {
            final horiz = d.dx.abs() >= d.dy.abs();
            final c = horiz ? a.dy : a.dx;
            covered = horiz
                ? (c - dbb.$2).abs() < e || (c - dbb.$4).abs() < e
                : (c - dbb.$1).abs() < e || (c - dbb.$3).abs() < e;
          } else {
            covered = true;
          }
        }
        if (len > 0.4 && !covered) {
          final mid = (a + bpt) / 2;
          final dir = (bpt - a) / len;
          final off = Offset(-dir.dy, dir.dx) * (wl.thickness / 2 + th * 0.4);
          final s = '${_dim2(len)} m';
          _text(
            buf,
            mid.dx + ox + off.dx - th * 0.3,
            mid.dy + oy + off.dy,
            th * 0.55,
            s,
          );
          labels.claim(
            mid.dx + ox + off.dx - th * 0.3,
            mid.dy + oy + off.dy,
            th * 0.55,
            s,
          );
        }
      }
    }
    for (final vol in m.volumes) {
      _poly(
        buf,
        _shift(
          [
            for (var i = 0; i < vol.fp.length; i += 2)
              Offset(vol.fp[i], vol.fp[i + 1]),
          ],
          ox,
          oy,
        ),
      );
    }
    for (final bl in m.blocks) {
      final def = cadBlock(bl.def);
      if (def == null) continue;
      for (final l in blockLines(bl, def)) {
        _poly(buf, _shift(l, ox, oy), aci: 8, open: true);
      }
    }
    // exterior dimension strings + diagonal strings FIRST — they are
    // the outermost fixed ink; opening/block dims negotiate around
    // them, so their text boxes must be claimed before anything else
    // that could sit in the same corridor
    for (var s = 0; s < 4; s++) {
      _dimString(buf, m, s, dbb, ox, oy, th, labels: labels);
    }
    _diagStrings(buf, m, bb, ox, oy, th, labels: labels);
    // interior dimension ticks hugging each footprint — the dim
    // LINES stay anchored, only their VALUES negotiate clear slots
    if (m.blocks.length <= 80) {
      final ccx = (bb.$1 + bb.$3) / 2, ccy = (bb.$2 + bb.$4) / 2;
      void dimEdge(Offset a, Offset b, Offset c0, double off) {
        final d = b - a;
        final len = d.distance;
        if (len < 0.1) return;
        var n = Offset(-d.dy, d.dx) / len;
        final mid = (a + b) / 2;
        if (n.dx * (mid.dx - c0.dx) + n.dy * (mid.dy - c0.dy) < 0) {
          n = -n;
        }
        final a2 = a + n * off, b2 = b + n * off;
        _poly(buf, _shift([a2, b2], ox, oy), aci: 8, open: true);
        final u = (b2 - a2) / len;
        final nn = Offset(-u.dy, u.dx);
        for (final e in [a2, b2]) {
          _poly(
            buf,
            _shift(
              [e - (u + nn) * th * 0.22, e + (u + nn) * th * 0.22],
              ox,
              oy,
            ),
            aci: 8,
            open: true,
          );
        }
        final lm = (a2 + b2) / 2 + n * th * 0.55;
        final s = _dim2(len);
        final fs = th * 0.45;
        // the dim LINE hugs the footprint; the VALUE negotiates a
        // clear slot — opening width dims used to land on the
        // exterior strings and neighbouring blocks' dims
        for (final p in [
          lm,
          lm + u * (s.length * fs * 0.62 + th * 0.3),
          lm - u * (s.length * fs * 0.62 + th * 0.3),
          lm + n * th * 0.9,
        ]) {
          final lx = p.dx + ox - s.length * fs * 0.3;
          final ly = p.dy + oy;
          if (labels.hits(_SheetLabels.box(lx, ly, fs, s))) continue;
          _text(buf, lx, ly, fs, s, aci: 8);
          labels.claim(lx, ly, fs, s);
          break;
        }
      }

      for (var bi = 0; bi < m.blocks.length; bi++) {
        final bl = m.blocks[bi];
        final def = cadBlock(bl.def);
        if (def == null) continue;
        final fp = blockFootprint(bl, def);
        if (fp.length < 4) continue;
        if (def.opening) {
          dimEdge(fp[0], fp[1], Offset(ccx, ccy), 0.28);
        } else {
          dimEdge(fp[0], fp[1], Offset(bl.x, bl.y), 0.14);
          dimEdge(fp[1], fp[2], Offset(bl.x, bl.y), 0.14);
        }
      }
    }
    // manual DIM-tool annotations — only ones anchored near the
    // model: a stray mark left far off-plan (stale edit) would
    // stretch the sheet bounds and shrink the drawing to a speck
    final dimLim = math.max(bb.$3 - bb.$1, bb.$4 - bb.$2) * 1.5;
    for (final d in m.dims) {
      final midx = (d[0] + d[2]) / 2, midy = (d[1] + d[3]) / 2;
      if (midx < bb.$1 - dimLim ||
          midx > bb.$3 + dimLim ||
          midy < bb.$2 - dimLim ||
          midy > bb.$4 + dimLim) {
        continue;
      }
      final a = Offset(d[0] + ox, d[1] + oy), b = Offset(d[2] + ox, d[3] + oy);
      _poly(buf, [a, b], aci: 8, open: true);
      final dir = b - a;
      if (dir.distance > 1e-6) {
        final n = Offset(-dir.dy, dir.dx) / dir.distance * th * 0.4;
        _poly(buf, [a - n, a + n], aci: 8, open: true);
        _poly(buf, [b - n, b + n], aci: 8, open: true);
        final mid = (a + b) / 2 + n * 0.6;
        final s = _dim2(dir.distance);
        _text(buf, mid.dx, mid.dy, th * 0.5, s, aci: 8);
        labels.claim(mid.dx, mid.dy, th * 0.5, s);
      }
    }
    _roomLabels(buf, m, ox, oy, th, labels: labels);
    // movable block labels — LAST, so every fixed text (dim strings,
    // opening width dims, room names) is already claimed. Openings
    // park OUTSIDE their wall (away from the wall-envelope centre)
    // where a plan reader expects the D#/W# tag; solids try below
    // → above → shifted → flanks. A candidate whose box hits claimed
    // ink is skipped; a block that can't place its full tag drops
    // the W×D line first, then the label entirely (never overlaps).
    if (m.blocks.length <= 80) {
      // envelope centre decides which side of a wall opening is
      // "out" — the model bound can be skewed by furniture/trees
      final ecx = (dbb.$1 + dbb.$3) / 2, ecy = (dbb.$2 + dbb.$4) / 2;
      final tags = blockTags(m);
      const gap = 0.35;
      for (var bi = 0; bi < m.blocks.length; bi++) {
        final bl = m.blocks[bi];
        final def = cadBlock(bl.def);
        if (def == null) continue;
        final fp = blockFootprint(bl, def);
        if (fp.length < 4) continue;
        var qx0 = double.infinity, qy0 = double.infinity;
        var qx1 = -double.infinity, qy1 = -double.infinity;
        for (final p in fp) {
          qx0 = math.min(qx0, p.dx);
          qy0 = math.min(qy0, p.dy);
          qx1 = math.max(qx1, p.dx);
          qy1 = math.max(qy1, p.dy);
        }
        final qcx = (qx0 + qx1) / 2, qcy = (qy0 + qy1) / 2;
        final qw = qx1 - qx0, qh = qy1 - qy0;
        // openings carry the D#/W# schedule tag the elevations
        // match — the name already carries the size and dimEdge
        // draws the width on the wall, so no W×D line (one line
        // of ink where three collided before)
        final l1 = tags[bi] != null ? '${tags[bi]} · ${def.name}' : def.name;
        final s2 =
            '${_dim2(def.w * bl.scale * bl.sx)} × ${_dim2(def.d * bl.scale * bl.sy)}';
        final fs1 = th * 0.5, fs2 = th * 0.45, pitch = th * 0.75;
        final w1 = l1.length * fs1 * 0.62;
        final w2 = s2.length * fs2 * 0.62;

        // (cx, yBot) candidates in MODEL coords: yBot = baseline of
        // the lowest line; the 2-line block stacks up by pitch.
        // The claimed boxes are SHEET coords — shift before testing.
        bool tryCands(List<(double, double)> cs, bool two) {
          final w = two ? math.max(w1, w2) : w1;
          for (final c in cs) {
            final b = (
              ox + c.$1 - w / 2 - fs1 * 0.1,
              oy + c.$2 - fs2 * 0.32,
              ox + c.$1 + w / 2 + fs1 * 0.1,
              oy + c.$2 + (two ? pitch : 0) + fs1 * 1.12,
            );
            if (labels.hits(b)) continue;
            // draw lowest line first, both centred on cx
            var y = c.$2;
            if (two) {
              final x = ox + c.$1 - s2.length * fs2 * 0.31;
              _text(buf, x, oy + y, fs2, s2, aci: 8);
              y += pitch;
            }
            final x = ox + c.$1 - l1.length * fs1 * 0.31;
            _text(buf, x, oy + y, fs1, l1, aci: 8);
            labels.boxes.add(b);
            return true;
          }
          return false;
        }

        List<(double, double)> cands(bool two) {
          final w = two ? math.max(w1, w2) : w1;
          final bh = (two ? pitch : 0.0) + fs1; // block height est
          final step = w * 0.6 + th * 0.4; // along-run shift step
          final cs = <(double, double)>[];
          if (def.opening) {
            // dominant outward axis from the envelope centre
            final dx = qcx - ecx, dy = qcy - ecy;
            if (dx.abs() >= dy.abs()) {
              final sgn = dx < 0 ? -1.0 : 1.0;
              for (final cl in [th * 0.4, th * 1.0, th * 1.6]) {
                for (final dcy in [0.0, qh / 2 + fs1, -(qh / 2 + fs1)]) {
                  cs.add(
                      (qcx + sgn * (qw / 2 + cl + w / 2), qcy + dcy - bh / 2));
                }
              }
              // inner side last resort
              cs.add((qcx - sgn * (qw / 2 + th + w / 2), qcy - bh / 2));
            } else {
              final sgn = dy < 0 ? -1.0 : 1.0;
              for (final cl in [th * 0.4, th * 1.0, th * 1.6]) {
                for (final sh in [0.0, step, -step]) {
                  if (sgn > 0) {
                    cs.add((qcx + sh, qy1 + cl + fs1 * 0.32));
                  } else {
                    cs.add((qcx + sh, qy0 - cl - bh));
                  }
                }
              }
              // inner side last resort
              cs.add(
                sgn > 0
                    ? (qcx, qy0 - th - bh)
                    : (qcx, qy1 + th + fs1 * 0.32),
              );
            }
          } else {
            for (final sh in [0.0, step, -step]) {
              cs.add((qcx + sh, qy0 - gap * th - bh)); // below
            }
            for (final sh in [0.0, step, -step]) {
              cs.add((qcx + sh, qy1 + gap * th + fs2 * 0.3)); // above
            }
            cs.add((qx1 + gap * th + w / 2, qcy - bh / 2)); // right
            cs.add((qx0 - gap * th - w / 2, qcy - bh / 2)); // left
          }
          return cs;
        }

        // solids keep their W×D second line when it fits anywhere;
        // drop the size line before dropping the tag entirely
        if (!def.opening && tryCands(cands(true), true)) continue;
        tryCands(cands(false), false);
      }
    }
  } else if (view == SheetView.structural) {
    _structuralSheet(buf, m, bb, ox, oy, th);
  } else if (view == SheetView.roofFrame) {
    _roofFrameSheet(buf, m, bb, ox, oy, th);
  } else if (view == SheetView.roof) {
    for (final p in polys) {
      _poly(buf, _shift(p, ox, oy));
    }
    // T# member tags — same numbering the S-102 framing sheet uses,
    // parked at each truss symbol's first bearing end
    final ttags = trussTags(m);
    for (var i = 0; i < m.blocks.length; i++) {
      final b = m.blocks[i];
      final tag = ttags[i];
      if (tag == null) continue;
      final def = cadBlock(b.def);
      if (def == null) continue;
      final u = Offset(math.cos(b.rot), math.sin(b.rot));
      final tp =
          Offset(b.x + ox, b.y + oy) - u * (def.w * b.sx * b.scale / 2 + th * 0.6);
      _text(buf, tp.dx - th * 0.3, tp.dy, th * 0.6, tag, aci: 7);
    }
    // spec NOTES block over the drawing: roofing / purlin / truss /
    // area callouts — the values a checker reads a roof plan for.
    // Wrapped to ~drawing width so long spec lines can't run off the
    // sheet frame (the paper-fit sees text bounds loosely)
    final notes = roofCallouts(m);
    if (notes.isNotEmpty) {
      final topY = polys.fold(
        0.0,
        (a, ps) => math.max(a, ps.fold(0.0, (b, p) => math.max(b, p.dy))),
      );
      final wrapAt = math.max(30, (span / (th * 0.31)).round());
      var ny = oy + topY + th * 1.2;
      for (final s in notes.reversed) {
        var first = true;
        for (final ln in _wrap2(s, wrapAt)) {
          _text(buf, ox + (first ? 0 : th * 0.8), ny, th * 0.5, ln, aci: 8);
          ny += th * 0.9;
          first = false;
        }
      }
    }
  } else if (view == SheetView.electrical || view == SheetView.plumbing) {
    _fixtureSheet(buf, m, view, bb, ox, oy, th);
  } else if (view == SheetView.front ||
      view == SheetView.rear ||
      view == SheetView.left ||
      view == SheetView.right) {
    // elevations carry per-category linework: heavy fill outlines
    // (aci 7) + light opening detail (aci 8), sills/rails open lines
    final es = _elevScene(m, view);
    for (final pr in es.prims) {
      _poly(buf, _shift(pr.$1, ox, oy), aci: pr.$2, open: pr.$1.length == 2);
    }
    // door/window callouts on every drawn opening — the same D#/W#
    // tags the floor plan uses: doors sit on grade so they tag ABOVE
    // the head; raised openings stack tag + sill underneath. The W/H
    // numbers moved onto real dimension strings (_openingDims).
    final tags = blockTags(m);
    for (final o in es.hosted) {
      final tag = tags[o.bi];
      if (tag == null) continue;
      final uc = (o.u0 + o.u1) / 2 + ox;
      final lines = o.zl - o.b.bz < 0.05
          ? [(o.zh + th * 0.45, tag)]
          : [
              (o.zl - th * 0.7, tag),
              (o.zl - th * 1.5, 'SILL ${_dim2(o.zl - o.b.bz)}'),
            ];
      for (final (tz, s) in lines) {
        _text(
          buf,
          uc - s.length * th * 0.45 * 0.3,
          tz + oy,
          th * 0.45,
          s,
          aci: 8,
        );
      }
      _openingDims(buf, o, ox, oy, th, es.hosted);
    }
  } else {
    for (final p in polys) {
      _poly(buf, _shift(p, ox, oy));
    }
  }
  // elevations get a ground baseline + view label + model title
  if (view == SheetView.front ||
      view == SheetView.rear ||
      view == SheetView.left ||
      view == SheetView.right) {
    final maxX = polys.fold(
      0.0,
      (a, ps) => math.max(a, ps.fold(0.0, (b, p) => math.max(b, p.dx))),
    );
    _poly(
      buf,
      [Offset(ox - pad / 2, oy), Offset(ox + (maxX - mx) + pad / 2, oy)],
      aci: 9,
      open: true,
    );
  }
  buf.write('0\nENDSEC\n0\nEOF\n');
  return buf.toString();
}

/// Paper sizes (mm, portrait W×H) offered for generated sheets —
/// ISO A-series plus the PH government bond-paper set (Letter =
/// short bond, Folio/Legal = long bond).
const kPaperSizes = <String, (double, double)>{
  'A4': (210, 297),
  'A3': (297, 420),
  'A2': (420, 594),
  'Letter': (216, 279),
  'Folio 8.5x13': (216, 330),
  'Legal': (216, 356),
};

/// Sheet numbers per view — the A/S/E/P series a real set uses.
const kSheetNo = <SheetView, String>{
  SheetView.plan: 'A-101',
  SheetView.roof: 'A-102',
  SheetView.front: 'A-201',
  SheetView.rear: 'A-202',
  SheetView.left: 'A-203',
  SheetView.right: 'A-204',
  SheetView.structural: 'S-101',
  SheetView.roofFrame: 'S-102',
  SheetView.electrical: 'E-101',
  SheetView.plumbing: 'P-101',
};

/// Metric drawing scales (ISO 5455) the sheet fit snaps to — a real
/// drawing never carries an arbitrary scale like 1:87.
const _metricScales = [
  5,
  10,
  20,
  25,
  50,
  75,
  100,
  125,
  150,
  200,
  250,
  500,
  750,
  1000,
  1500,
  2000,
];

/// Emit one view as a proper drawing sheet on the chosen paper:
/// border + frame, content scaled to a snapped metric scale, title
/// block (project / model / sheet / scale / date), north arrow on
/// plan views and a graphic scale bar. The DXF is in mm — real CAD
/// paper space.
String buildModelSheet(
  Model3d m,
  SheetView view, {
  String paper = 'A4',
  bool landscape = true,
  ProjectInfo? project,
}) {
  var pw = kPaperSizes[paper]?.$1 ?? 210.0;
  var ph = kPaperSizes[paper]?.$2 ?? 297.0;
  if (landscape) {
    final t = pw;
    pw = ph;
    ph = t;
  }
  final buf = StringBuffer('0\nSECTION\n2\nENTITIES\n');
  // sheet edge + drawing frame: 10mm margins + 10mm binding edge
  const mg = 10.0, bind = 10.0;
  final fx0 = mg + bind, fy0 = mg, fx1 = pw - mg, fy1 = ph - mg;
  _poly(buf, [Offset(0, 0), Offset(pw, 0), Offset(pw, ph), Offset(0, ph)]);
  _poly(buf, [
    Offset(fx0, fy0),
    Offset(fx1, fy0),
    Offset(fx1, fy1),
    Offset(fx0, fy1),
  ]);

  final sc = DxfParser.parse(_sheetContent(m, view));
  // content bounds in model coords
  var cx0 = double.infinity, cy0 = double.infinity;
  var cx1 = -double.infinity, cy1 = -double.infinity;
  for (final p in sc.prims) {
    final loops = p.fillLoops ?? [p.pts];
    for (final l in loops) {
      for (final o in l) {
        cx0 = math.min(cx0, o.dx);
        cy0 = math.min(cy0, o.dy);
        cx1 = math.max(cx1, o.dx);
        cy1 = math.max(cy1, o.dy);
      }
    }
  }
  for (final t in sc.texts) {
    cx0 = math.min(cx0, t.pos.dx);
    cy0 = math.min(cy0, t.pos.dy);
    cx1 = math.max(cx1, t.pos.dx);
    cy1 = math.max(cy1, t.pos.dy + t.height);
  }
  var scaleDenom = 100;
  if (cx0.isFinite) {
    final cw = math.max(cx1 - cx0, 0.1), ch = math.max(cy1 - cy0, 0.1);
    final dw = fx1 - fx0, dh = fy1 - fy0;
    // reserve the title-block lane inside the frame
    const tbH = 48.0;
    final nominal = 1000 / math.min((dw - 8) / cw, (dh - tbH - 6) / ch);
    scaleDenom = _metricScales.firstWhere(
      (s) => s >= nominal,
      orElse: () => 2000,
    );
    final k = 1000.0 / scaleDenom;
    // center content in the frame (a touch above center leaves room
    // for the scale bar + title block below), then the user's stored
    // viewport pan shifts it (mm — the DRAWINGS "move sheet" gesture)
    final pan = m.sheetPan[view.name] ?? Offset.zero;
    final ox2 = fx0 + (dw - cw * k) / 2 + pan.dx;
    final oy2 = fy0 + tbH + 4 + (dh - tbH - 4 - ch * k) / 2 + pan.dy;
    Offset t(Offset p) =>
        Offset(ox2 + (p.dx - cx0) * k, oy2 + (p.dy - cy0) * k);
    for (final pr in sc.prims) {
      // parsed colors are resolved ARGB — map back to ACI indices
      // before writing group 62 or real CAD sees garbage values
      final aci = aciFromArgb(pr.color);
      if (pr.fillLoops != null) {
        for (final l in pr.fillLoops!) {
          final lp = [for (final p in l) t(p)];
          _hatch(buf, lp, aci: aci);
          _poly(buf, lp, aci: aci);
        }
      } else if (pr.pts.length >= 2) {
        _poly(buf, [for (final p in pr.pts) t(p)], aci: aci, open: !pr.closed);
      }
    }
    for (final tx in sc.texts) {
      final q = t(tx.pos);
      // annotation scales with the drawing but never below ~1.5mm —
      // smaller stops being readable on the print
      _text(
        buf,
        q.dx,
        q.dy,
        math.max(tx.height * k, 1.5),
        tx.text,
        aci: aciFromArgb(tx.color),
        rot: tx.rotation,
      );
    }
    _paperFurniture(buf, view, fx0, fy0, fx1, fy1, scaleDenom, m, project);
  } else {
    _text(buf, fx0 + 10, (fy0 + fy1) / 2, 8, 'EMPTY MODEL', aci: 7);
    _paperFurniture(buf, view, fx0, fy0, fx1, fy1, scaleDenom, m, project);
  }
  buf.write('0\nENDSEC\n0\nEOF\n');
  return buf.toString();
}

/// The signature strip's clickable cells on a generated sheet, in
/// sheet mm relative to the PAPER rect (which is also the DXF scene's
/// bounds — the paper border is the outermost entity). `_paperFurniture`
/// lays the strip out with these same constants; the DRAWINGS tab
/// overlays the logo + project title on the returned rects so both are
/// tap-to-edit on screen. Y points up, so the strip's larger y sits
/// near the sheet's screen bottom. `isPrivate` (the free template)
/// shrinks the strip to the title row only — no signatory band.
({Rect logo, Rect title}) sheetTitleCells(
  Rect paper, {
  bool isPrivate = false,
}) {
  const mg = 10.0, bind = 10.0, topH = 12.0;
  final tbH = isPrivate ? topH : 34.0;
  const logoW = 18.0, dateW = 32.0;
  final fx0 = paper.left + mg + bind;
  final fx1 = paper.right - mg;
  final by1 = paper.top + mg + tbH, bym = by1 - topH;
  final dw = fx1 - fx0;
  return (
    logo: Rect.fromLTRB(fx0, bym, fx0 + logoW, by1),
    title: Rect.fromLTRB(fx0 + logoW + dw * .24, bym, fx1 - dateW, by1),
  );
}

/// The paper furniture: the DepEd signature strip across the full frame
/// bottom (logo | LOCATION | project title | DATE over PREPARED /
/// CHECKED / RECOMMENDING / APPROVED columns), the drawing title
/// centered above it, a graphic scale bar and the north arrow on plan
/// views — everything in mm on the sheet.
void _paperFurniture(
  StringBuffer buf,
  SheetView view,
  double fx0,
  double fy0,
  double fx1,
  double fy1,
  int scaleDenom,
  Model3d m,
  ProjectInfo? project,
) {
  final p = project ?? ProjectInfo();
  final dw = fx1 - fx0;
  const topH = 12.0;
  // shared with the DRAWINGS overlay — its logo/title hotspots must
  // land on these exact cells (paper = frame + the margins)
  // the strip's signature band exists iff the template signs its
  // documents — private/custom templates sign too, so gate on the
  // resolved signatory list, not the letterhead flag
  final sigs = p.effSignatories;
  final cells = sheetTitleCells(
    Rect.fromLTRB(fx0 - 20, fy0 - 10, fx1 + 10, fy1 + 10),
    isPrivate: sigs.isEmpty,
  );
  final by0 = fy0, by1 = cells.logo.bottom, bym = cells.logo.top;
  void box(double x0, double y0, double x1, double y1) => _poly(buf, [
    Offset(x0, y0),
    Offset(x1, y0),
    Offset(x1, y1),
    Offset(x0, y1),
  ]);
  void hline(double y, [double x0 = 0, double? x1]) =>
      _poly(buf, [Offset(fx0 + x0, y), Offset(x1 ?? fx1, y)], open: true);
  void vline(double x, double y0, double y1) =>
      _poly(buf, [Offset(x, y0), Offset(x, y1)], open: true);
  void ctext(double cx, double y, double h, String s, {int aci = 7}) =>
      _text(buf, cx - s.length * h * 0.28, y, h, s, aci: aci);

  // ---- signature strip: outer box + horizontal split ----
  box(fx0, by0, fx1, by1);
  // no signatories: bym == by0 (title row only, no signatory band)
  if (sigs.isNotEmpty) hline(bym);
  // top row cells: logo(18) | LOCATION(~24%) | title(rest) | DATE(30)
  final lx1 = cells.logo.right,
      lo1 = cells.title.left,
      tx1 = cells.title.right;
  vline(lx1, bym, by1);
  vline(lo1, bym, by1);
  vline(tx1, bym, by1);
  if (!p.isPrivate) {
    _text(buf, fx0 + 3, bym + (topH - 4) / 2, 4, 'DepEd', aci: 7);
  }
  _text(buf, lx1 + 2, by1 - 3.4, 1.8, 'LOCATION:', aci: 8);
  _text(buf, lx1 + 2, by1 - 8.4, 2.6, p.location.toUpperCase(), aci: 7);
  _text(buf, tx1 + 2, by1 - 3.4, 1.8, 'DATE:', aci: 8);
  _text(buf, tx1 + 2, by1 - 8.4, 2.6, _longDate(p.date), aci: 7);
  // project title cell, wrapped to <=2 lines and centered — the size
  // is user-resizable in the DRAWINGS viewer (title-cell drag handle)
  final title = p.title.isEmpty ? m.name.toUpperCase() : p.title.toUpperCase();
  final ts = p.titleSize.clamp(1.2, 9.0);
  final wrapAt = ((tx1 - lo1 - 6) / (ts * 0.62)).floor().clamp(8, 60);
  final tl = _wrap2(title, wrapAt);
  for (var i = 0; i < tl.length; i++) {
    ctext((lo1 + tx1) / 2, by1 - 1.8 - ts - i * ts * 1.45, ts, tl[i]);
  }
  // signature row: up to 4 equal columns — `sigs` resolved above; an
  // empty list means the band was never drawn and this no-ops
  final n = math.min(math.max(sigs.length, 1), 4);
  final cw2 = dw / n;
  for (var i = 0; i < n; i++) {
    final cx0 = fx0 + i * cw2;
    if (i > 0) vline(cx0, by0, bym);
    if (i >= sigs.length) continue;
    final s = sigs[i];
    _text(buf, cx0 + 2, bym - 3.2, 1.8, '${s.label.toUpperCase()}:', aci: 8);
    _text(buf, cx0 + 2, by0 + 6.6, 2.8, s.name.toUpperCase(), aci: 7);
    _text(buf, cx0 + 2, by0 + 2.8, 1.9, s.position.toUpperCase(), aci: 8);
  }
  // ---- drawing title centered above the strip + sheet meta ----
  ctext(fx0 + dw / 2, by1 + 9.4, 7.5, kSheetTitle[view]!);
  final tw = kSheetTitle[view]!.length * 7.5 * 0.56;
  _poly(buf, [
    Offset(fx0 + dw / 2 - tw / 2, by1 + 8.5),
    Offset(fx0 + dw / 2 + tw / 2, by1 + 8.5),
  ], open: true);
  ctext(fx0 + dw / 2, by1 + 4.2, 2.2, 'MODEL: ${m.name.toUpperCase()}', aci: 8);
  _text(
    buf,
    fx1 - 2 - 'SCALE 1:$scaleDenom'.length * 2.6 * 0.62,
    by1 + 4.2,
    2.6,
    'SCALE 1:$scaleDenom',
    aci: 8,
  );
  _text(buf, fx0 + 2, by1 + 4.2, 2.6, 'SHEET ${kSheetNo[view]!}', aci: 8);
  // ---- graphic scale bar above the strip, bottom-left ----
  final k = 1000.0 / scaleDenom; // mm per model meter
  var step = 0.5;
  for (final s in [0.5, 1.0, 2.0, 5.0, 10.0, 20.0, 50.0, 100.0]) {
    if (4 * s * k >= 35 && 4 * s * k <= 80) {
      step = s;
      break;
    }
    step = s;
  }
  final sx = fx0 + 8, sy = by1 + 16;
  _poly(
    buf,
    [Offset(sx, sy), Offset(sx + 4 * step * k, sy)],
    aci: 7,
    open: true,
  );
  for (var i = 0; i <= 4; i++) {
    final tx = sx + i * step * k;
    _poly(buf, [Offset(tx, sy), Offset(tx, sy + 2)], aci: 7, open: true);
    _text(buf, tx - 1.5, sy + 3, 2.2, _num(i * step), aci: 8);
  }
  _text(buf, sx + 4 * step * k + 2, sy + 1, 2.2, 'M', aci: 8);
  // ---- north arrow, top-right of the frame — plan views only ----
  if (view == SheetView.plan ||
      view == SheetView.roof ||
      view == SheetView.structural ||
      view == SheetView.roofFrame ||
      view == SheetView.electrical ||
      view == SheetView.plumbing) {
    final nx = fx1 - 10, ny = fy1 - 16;
    _poly(buf, [
      Offset(nx, ny + 10),
      Offset(nx - 2.4, ny),
      Offset(nx, ny + 2.4),
      Offset(nx + 2.4, ny),
    ]);
    _text(buf, nx - 1.6, ny + 11.5, 4, 'N', aci: 7);
  }
}

/// "October 19, 2026" for the DATE cell.
String _longDate(DateTime? d) {
  const mo = [
    'January',
    'February',
    'March',
    'April',
    'May',
    'June',
    'July',
    'August',
    'September',
    'October',
    'November',
    'December',
  ];
  final t = d ?? DateTime.now();
  return '${mo[t.month - 1]} ${t.day}, ${t.year}';
}

/// Greedy word-wrap to at most two lines for the project-title cell.
List<String> _wrap2(String s, int at) {
  if (s.length <= at) return [s];
  var cut = s.lastIndexOf(' ', at.clamp(0, s.length - 1));
  if (cut < 8) cut = at;
  final a = s.substring(0, cut).trimRight();
  var b = s.substring(cut).trimLeft();
  if (b.length > at) b = '${b.substring(0, at - 1)}.';
  return [a, b];
}

/// plan CONTENT (sheet furniture lives in the paper template).
void _roomLabels(
  StringBuffer buf,
  Model3d m,
  double ox,
  double oy,
  double th, {
  _SheetLabels? labels,
}) {
  for (final v in m.volumes) {
    final c = v.center;
    final nm = v.name.toUpperCase();
    _text(
      buf,
      c.dx + ox - nm.length * th * 0.17,
      c.dy + oy + th * 0.2,
      th * 0.6,
      nm,
      aci: 7,
    );
    labels?.claim(c.dx + ox - nm.length * th * 0.17, c.dy + oy + th * 0.2,
        th * 0.6, nm);
    final ar = '${_num(v.area)} SQ.M';
    _text(
      buf,
      c.dx + ox - ar.length * th * 0.13,
      c.dy + oy - th * 0.6,
      th * 0.45,
      ar,
      aci: 8,
    );
    labels?.claim(c.dx + ox - ar.length * th * 0.13, c.dy + oy - th * 0.6,
        th * 0.45, ar);
  }
}

/// Emit the model as a real DXF drawing sheet: FLOOR PLAN + ROOF PLAN
/// on top, FRONT / RIGHT / REAR / LEFT elevations in a row underneath
/// (third-angle-ish), each labeled — ready for the DRAWINGS library,
/// measurement calibration and xlsx/pdf export flows.
String buildModelDxf(Model3d m) {
  final bb = m.bounds;
  final buf = StringBuffer('0\nSECTION\n2\nENTITIES\n');
  if (bb == null) {
    _text(buf, 0, 0, 0.4, 'EMPTY MODEL', aci: 7);
    buf.write('0\nENDSEC\n0\nEOF\n');
    return buf.toString();
  }
  final (x0, y0, x1, y1, z1) = bb;
  final w = x1 - x0, d = y1 - y0, h = math.max(z1, 0.5);
  final gap = math.max(w, d) * 0.3 + 2.0;
  final th = math.max(0.35, math.max(w, math.max(d, h)) * 0.045);

  final minX = _minX;
  final minY = _minY;

  // -- elevations row (baseline z=0 at sheet y=0)
  // front | right | rear | left, widths w,d,w,d
  final fronts = [
    SheetView.front,
    SheetView.right,
    SheetView.rear,
    SheetView.left,
  ];
  final widths = {
    SheetView.front: w,
    SheetView.right: d,
    SheetView.rear: w,
    SheetView.left: d,
  };
  var ex = 0.0;
  final labelY = -th * 1.6;
  for (final v in fronts) {
    final prims = elevationPrims(m, v);
    final polys = [for (final p in prims) p.$1];
    final mx = polys.isEmpty ? 0.0 : minX(polys);
    final my = polys.isEmpty ? 0.0 : minY(polys);
    for (final p in prims) {
      _poly(buf, _shift(p.$1, ex - mx, -my), aci: p.$2, open: p.$1.length == 2);
    }
    // grade line anchors the elevation — z=0 across its width
    if (polys.isNotEmpty) {
      final ux = polys.fold(
        0.0,
        (a, ps) => math.max(a, ps.fold(0.0, (b, p) => math.max(b, p.dx))),
      );
      _poly(
        buf,
        [Offset(ex - 0.5, -my), Offset(ex + ux - mx + 0.5, -my)],
        aci: 9,
        open: true,
      );
    }
    _text(
      buf,
      ex + widths[v]! / 2 - widths[v]! * 0.25,
      labelY,
      th * 0.8,
      '${v.name.toUpperCase()} ELEVATION',
    );
    ex += widths[v]! + gap;
  }

  // -- plan + roof row above the elevations
  final topY = h + gap;
  final planPolys = projectView(m, SheetView.plan);
  final pmx = planPolys.isEmpty ? 0.0 : minX(planPolys);
  final pmy = planPolys.isEmpty ? 0.0 : minY(planPolys);
  // walls get the real-plan treatment: gray mass fill + dark outline
  // + a dimension label on every segment (the automatic measurement)
  for (final wl in m.walls) {
    for (var i = 0; i < wl.segs; i++) {
      // joined/opening-carved pieces — closes corner notches
      for (final piece in wallSegPieces(m, wl, i)) {
        final sp = _shift(piece, -pmx, topY - pmy);
        _hatch(buf, sp, aci: 9);
        _poly(buf, sp);
      }
      final a = Offset(wl.pts[i * 2], wl.pts[i * 2 + 1]);
      final bpt = Offset(wl.pts[i * 2 + 2], wl.pts[i * 2 + 3]);
      final len = (bpt - a).distance;
      if (len > 0.4) {
        final mid = (a + bpt) / 2;
        final dir = (bpt - a) / len;
        final off = Offset(-dir.dy, dir.dx) * (wl.thickness / 2 + th * 0.4);
        _text(
          buf,
          mid.dx - pmx + off.dx - th * 0.3,
          mid.dy + topY - pmy + off.dy,
          th * 0.55,
          '${_dim2(len)} m',
        );
      }
    }
  }
  // massing volumes + furniture symbols as plain outlines
  for (final vol in m.volumes) {
    _poly(
      buf,
      _shift(
        [
          for (var i = 0; i < vol.fp.length; i += 2)
            Offset(vol.fp[i], vol.fp[i + 1]),
        ],
        -pmx,
        topY - pmy,
      ),
    );
  }
  for (final bl in m.blocks) {
    final def = cadBlock(bl.def);
    if (def == null) continue;
    for (final l in blockLines(bl, def)) {
      _poly(buf, _shift(l, -pmx, topY - pmy), aci: 8, open: true);
    }
  }
  _text(buf, w / 2 - w * 0.18, topY + labelY - 0.5, th * 0.8, 'FLOOR PLAN');
  final roofX = w + gap;
  final roofPolys = projectView(m, SheetView.roof);
  final rmx = roofPolys.isEmpty ? 0.0 : minX(roofPolys);
  final rmy = roofPolys.isEmpty ? 0.0 : minY(roofPolys);
  for (final p in roofPolys) {
    _poly(buf, _shift(p, roofX - rmx, topY - rmy));
  }
  _text(
    buf,
    roofX + w / 2 - w * 0.2,
    topY + labelY - 0.5,
    th * 0.8,
    'ROOF PLAN',
  );
  final frameX = roofX + w + gap;
  final framePolys = projectView(m, SheetView.roofFrame);
  final fmx = framePolys.isEmpty ? 0.0 : minX(framePolys);
  final fmy = framePolys.isEmpty ? 0.0 : minY(framePolys);
  for (final p in framePolys) {
    _poly(buf, _shift(p, frameX - fmx, topY - fmy));
  }
  _text(
    buf,
    frameX + w / 2 - w * 0.3,
    topY + labelY - 0.5,
    th * 0.8,
    'ROOF FRAMING PLAN',
  );

  // -- sheet title
  _text(
    buf,
    0,
    topY + d + th * 2.2,
    th,
    'MODEL: ${m.name} — GENERATED PLAN & ELEVATIONS',
    aci: 7,
  );
  buf.write('0\nENDSEC\n0\nEOF\n');
  return buf.toString();
}
