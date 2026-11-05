import 'dart:math' as math;
import 'dart:typed_data';

/// Minimal Wavefront OBJ importer — enough to pull any public CC0/CC-BY
/// mesh (Kenney, Poly Pizza, Quaternius, Blender exports) into the CAD
/// block library. Parses `v`/`f`/`usemtl`; companion `.mtl` `Kd` colors
/// become per-face paint so a downloaded bed keeps its mattress/wood
/// split instead of rendering as one flat box.
///
/// Axis convention: OBJ is Y-up with Z toward the viewer; our model
/// space is Z-up with Y as plan depth, so (x, y, z)obj -> (x, z, y).
class ObjMesh {
  /// Vertices in model space [x, y(ground), z(up)].
  final List<List<double>> verts;

  /// One polygon per OBJ face: vertex indices + argb face color.
  final List<({List<int> idx, int argb})> faces;

  const ObjMesh(this.verts, this.faces);

  /// Model-space bounds: (minX, minY, minZ, maxX, maxY, maxZ).
  (double, double, double, double, double, double) get bounds {
    var x0 = double.infinity, y0 = double.infinity, z0 = double.infinity;
    var x1 = -double.infinity, y1 = -double.infinity, z1 = -double.infinity;
    for (final v in verts) {
      x0 = math.min(x0, v[0]);
      y0 = math.min(y0, v[1]);
      z0 = math.min(z0, v[2]);
      x1 = math.max(x1, v[0]);
      y1 = math.max(y1, v[1]);
      z1 = math.max(z1, v[2]);
    }
    return (x0, y0, z0, x1, y1, z1);
  }

  /// A copy with all vertices multiplied by [s] — used to tame wildly
  /// off-scale downloads (mm/cm-unit exports) at import time.
  ObjMesh scaled(double s) => ObjMesh(
    [for (final v in verts) [v[0] * s, v[1] * s, v[2] * s]],
    faces,
  );
}

const _kDefaultArgb = 0xFF9E9E9E;

/// Parse an OBJ source; pass the sibling `.mtl` text in [mtlSrc] when
/// present so `usemtl` groups get real colors. Returns null when the
/// file has no geometry (bad pick).
ObjMesh? parseObj(String src, {String? mtlSrc}) {
  final colors = mtlSrc == null ? const <String, int>{} : _parseMtl(mtlSrc);
  final verts = <List<double>>[];
  final faces = <({List<int> idx, int argb})>[];
  var argb = _kDefaultArgb;
  for (final raw in src.split('\n')) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    final sp = line.indexOf(' ');
    final kw = sp < 0 ? line : line.substring(0, sp);
    final rest = sp < 0 ? '' : line.substring(sp + 1).trim();
    switch (kw) {
      case 'v':
        final p = rest.split(RegExp(r'\s+'));
        if (p.length >= 3) {
          final x = double.tryParse(p[0]);
          final y = double.tryParse(p[1]);
          final z = double.tryParse(p[2]);
          if (x != null && y != null && z != null) {
            verts.add([x, z, y]); // Y-up -> Z-up
          }
        }
      case 'usemtl':
        argb = colors[rest] ?? _kDefaultArgb;
      case 'f':
        final idx = <int>[];
        for (final tok in rest.split(RegExp(r'\s+'))) {
          if (tok.isEmpty) continue;
          final head = tok.split('/').first;
          var i = int.tryParse(head);
          if (i == null || i == 0) continue;
          if (i < 0) i = verts.length + i + 1; // relative index
          if (i >= 1 && i <= verts.length) idx.add(i - 1);
        }
        if (idx.length >= 3) faces.add((idx: idx, argb: argb));
    }
  }
  if (verts.isEmpty || faces.isEmpty) return null;
  return ObjMesh(verts, faces);
}

/// STL importer — ASCII and binary. STL carries no colors; every
/// facet gets the neutral CAD gray. Orientation is taken as-is (the
/// CAD world is already Z-up like most STL exports).
ObjMesh? parseStl(List<int> bytes) {
  if (bytes.length < 15) return null;
  final head = String.fromCharCodes(bytes.take(5));
  if (head == 'solid') {
    final src = String.fromCharCodes(bytes);
    // binary files can start with "solid" too — detect by keywords
    if (!src.contains('facet')) return _parseStlBinary(bytes);
    return _parseStlAscii(src);
  }
  return _parseStlBinary(bytes);
}

ObjMesh? _parseStlAscii(String src) {
  final verts = <List<double>>[];
  final faces = <({List<int> idx, int argb})>[];
  final idx = <int>[];
  for (final raw in src.split('\n')) {
    final p = raw.trim().split(RegExp(r'\s+'));
    if (p.isEmpty) continue;
    if (p[0] == 'vertex' && p.length >= 4) {
      final x = double.tryParse(p[1]);
      final y = double.tryParse(p[2]);
      final z = double.tryParse(p[3]);
      if (x != null && y != null && z != null) {
        idx.add(verts.length);
        verts.add([x, y, z]);
      }
    } else if (p[0] == 'endfacet') {
      if (idx.length >= 3) {
        faces.add((idx: List<int>.of(idx), argb: _kDefaultArgb));
      }
      idx.clear();
    }
  }
  if (verts.isEmpty || faces.isEmpty) return null;
  return ObjMesh(verts, faces);
}

ObjMesh? _parseStlBinary(List<int> bytes) {
  if (bytes.length < 84) return null;
  final n = ByteData.sublistView(
    Uint8List.fromList(bytes),
  ).getUint32(80, Endian.little);
  if (84 + n * 50 > bytes.length || n > 500000) return null;
  final bd = ByteData.sublistView(Uint8List.fromList(bytes));
  final verts = <List<double>>[];
  final faces = <({List<int> idx, int argb})>[];
  var o = 84;
  for (var t = 0; t < n; t++) {
    o += 12; // skip facet normal
    final idx = <int>[];
    for (var v = 0; v < 3; v++) {
      idx.add(verts.length);
      verts.add([
        bd.getFloat32(o, Endian.little),
        bd.getFloat32(o + 4, Endian.little),
        bd.getFloat32(o + 8, Endian.little),
      ]);
      o += 12;
    }
    o += 2; // attribute byte count
    faces.add((idx: idx, argb: _kDefaultArgb));
  }
  if (verts.isEmpty || faces.isEmpty) return null;
  return ObjMesh(verts, faces);
}

/// `newmtl`/`Kd` diffuse colors -> argb.
Map<String, int> _parseMtl(String src) {
  final out = <String, int>{};
  var name = '';
  for (final raw in src.split('\n')) {
    final line = raw.trim();
    if (line.startsWith('newmtl ')) {
      name = line.substring(7).trim();
    } else if (line.startsWith('Kd ') && name.isNotEmpty) {
      final p = line.substring(3).trim().split(RegExp(r'\s+'));
      if (p.length >= 3) {
        final r = ((double.tryParse(p[0]) ?? 0) * 255).round().clamp(0, 255);
        final g = ((double.tryParse(p[1]) ?? 0) * 255).round().clamp(0, 255);
        final b = ((double.tryParse(p[2]) ?? 0) * 255).round().clamp(0, 255);
        out[name] = 0xFF000000 | (r << 16) | (g << 8) | b;
      }
    } else if (line.startsWith('d ') && name.isNotEmpty) {
      // dissolve — fold real transparency into argb so glass doors /
      // window panes render see-through instead of opaque walls
      final a = ((double.tryParse(line.substring(2).trim()) ?? 1) * 255)
          .round()
          .clamp(0, 255);
      if (out.containsKey(name) && a < 255) {
        out[name] = (out[name]! & 0x00FFFFFF) | (a << 24);
      }
    } else if (line.startsWith('Tr ') && name.isNotEmpty) {
      // Tr = 1 - d (3ds convention)
      final t = double.tryParse(line.substring(3).trim());
      if (t != null && out.containsKey(name)) {
        final a = ((1 - t) * 255).round().clamp(0, 255);
        if (a < 255) out[name] = (out[name]! & 0x00FFFFFF) | (a << 24);
      }
    }
  }
  return out;
}
