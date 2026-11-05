import 'obj.dart';

/// Result of an IFC import: the tessellated mesh in model space
/// (meters, mapped to our Z-up model space, base NOT yet dropped) plus what the file says it is.
class IfcModel {
  final ObjMesh mesh;
  final String name;

  /// 'door' | 'window' | null (furniture / other)
  final String? kind;
  const IfcModel(this.mesh, this.name, this.kind);
}

/// Minimal IFC (STEP) reader for manufacturer BIM objects (BIMobject,
/// GEALAN, Velux ... export IFC2X3/IFC4 with IFCFACETEDBREP solids):
/// follows IFCFACETEDBREP -> CLOSEDSHELL -> FACE -> POLYLOOP -> POINT,
/// colors via IFCSTYLEDITEM -> style assignment -> surface style ->
/// rendering -> COLOURRGB (+ transparency -> alpha), unit scale from the
/// project's LENGTHUNIT. Returns null when no brep geometry exists.
IfcModel? parseIfc(String src) {
  final a = src.indexOf('DATA;');
  if (a < 0) return null;
  final ents = <int, (String, String)>{};
  final re = RegExp(r'^#(\d+)\s*=\s*([A-Z0-9_]+)\s*\((.*)\)\s*$', dotAll: true);
  for (final raw in src.substring(a + 5).split(';')) {
    final m = re.firstMatch(raw.trim());
    if (m != null) ents[int.parse(m[1]!)] = (m[2]!, m[3]!);
  }
  List<int> refs(String s) =>
      [for (final m in RegExp(r'#(\d+)').allMatches(s)) int.parse(m[1]!)];

  var unit = 1.0;
  for (final e in ents.values) {
    if (e.$1 == 'IFCSIUNIT' && e.$2.contains('.LENGTHUNIT.')) {
      unit = e.$2.contains('.MILLI.')
          ? 0.001
          : e.$2.contains('.CENTI.')
              ? 0.01
              : 1.0;
    }
  }

  int? colorOfStyle(int assignId) {
    final asg = ents[assignId];
    if (asg == null) return null;
    for (final sId in refs(asg.$2)) {
      final st = ents[sId];
      if (st == null || st.$1 != 'IFCSURFACESTYLE') continue;
      for (final rId in refs(st.$2)) {
        final r = ents[rId];
        if (r == null || r.$1 != 'IFCSURFACESTYLERENDERING') continue;
        final cid = refs(r.$2).first;
        final c = ents[cid];
        if (c == null || c.$1 != 'IFCCOLOURRGB') continue;
        final nums = [
          for (final m in RegExp(r'-?\d+\.?\d*(?:E-?\d+)?').allMatches(
            c.$2.substring(c.$2.indexOf(',') + 1),
          ))
            double.parse(m[0]!),
        ];
        final tr = double.tryParse(
              r.$2.split(',').skip(1).first.trim(),
            ) ??
            0.0;
        int ch(double v) => (v.clamp(0.0, 1.0) * 255).round();
        final al = ((1 - tr).clamp(0.05, 1.0) * 255).round();
        return (al << 24) | (ch(nums[0]) << 16) | (ch(nums[1]) << 8) | ch(nums[2]);
      }
    }
    return null;
  }

  final colorOf = <int, int>{};
  for (final e in ents.values) {
    if (e.$1 != 'IFCSTYLEDITEM') continue;
    final r = refs(e.$2);
    if (r.length < 2 || e.$2.trimLeft().startsWith(r'$')) continue;
    final col = colorOfStyle(r[1]);
    if (col != null) colorOf[r[0]] = col;
  }

  final pts = <int, List<double>>{};
  final verts = <List<double>>[];
  final vIdx = <int, int>{};
  int vert(int pid) => vIdx.putIfAbsent(pid, () {
        var p = pts[pid];
        if (p == null) {
          final e = ents[pid];
          final n = [
            for (final m in RegExp(r'-?\d+\.?\d*(?:E-?\d+)?').allMatches(e!.$2))
              double.parse(m[0]!) * unit,
          ];
          p = pts[pid] = n;
        }
        // BIM-configurator exports are Y-up like OBJ: (x,y,z) -> (x,z,y)
        verts.add([p[0], p.length > 2 ? p[2] : 0.0, p[1]]);
        return verts.length - 1;
      });

  final faces = <({List<int> idx, int argb})>[];
  for (final b in ents.entries) {
    if (b.value.$1 != 'IFCFACETEDBREP') continue;
    final argb = colorOf[b.key] ?? 0xFFB0B0B0;
    final shell = ents[refs(b.value.$2).first];
    if (shell == null) continue;
    for (final fId in refs(shell.$2)) {
      final face = ents[fId];
      if (face == null) continue;
      for (final bId in refs(face.$2)) {
        final bound = ents[bId];
        if (bound == null || bound.$1 != 'IFCFACEOUTERBOUND') continue;
        final loop = ents[refs(bound.$2).first];
        if (loop == null) continue;
        final idx = [for (final p in refs(loop.$2)) vert(p)];
        if (idx.length >= 3) faces.add((idx: idx, argb: argb));
      }
    }
  }
  if (faces.isEmpty) return null;

  String name = 'IFC object';
  String? kind;
  for (final e in ents.values) {
    final t = e.$1;
    if (t == 'IFCDOOR' || t == 'IFCWINDOW') {
      kind = t == 'IFCDOOR' ? 'door' : 'window';
      final m = RegExp(r"'([^']*)'").allMatches(e.$2).toList();
      if (m.length > 2 && m[2][1]!.isNotEmpty) name = m[2][1]!;
      break;
    }
  }
  return IfcModel(ObjMesh(verts, faces), name, kind);
}
