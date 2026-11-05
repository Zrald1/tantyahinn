import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';

/// Minimal DXF (Drawing Exchange Format) reader + painter for plan
/// viewing. Entities are sampled into world-space polylines at parse
/// time, which makes INSERT/block transforms and bounds math trivial.
/// Supports LINE, LWPOLYLINE (with bulge arcs), POLYLINE/VERTEX, CIRCLE,
/// ARC, ELLIPSE, SPLINE (control-point polyline), POINT, TEXT, MTEXT,
/// SOLID/3DFACE/TRACE outlines, and INSERT (nested, depth-limited).
class DxfScene {
  final List<DxfPrim> prims;
  final List<DxfTextPrim> texts;
  final Rect bounds;

  DxfScene(this.prims, this.texts, this.bounds);

  /// Natural canvas size: scaled so the long edge is about [maxPx].
  Size naturalSize({double maxPx = 1600}) {
    final w = bounds.width <= 0 ? 1.0 : bounds.width;
    final h = bounds.height <= 0 ? 1.0 : bounds.height;
    final s = maxPx / math.max(w, h);
    return Size((w * s).clamp(64.0, 8000.0), (h * s).clamp(64.0, 8000.0));
  }
}

/// A sampled polyline stroke in DXF world coordinates (Y-up).
/// When [fillLoops] is set the prim is a solid region (HATCH fill):
/// all loops are painted even-odd, so nested loops become holes.
class DxfPrim {
  final List<Offset> pts;
  final bool closed;
  final int color;
  final List<List<Offset>>? fillLoops;
  DxfPrim(this.pts, this.closed, this.color, [this.fillLoops]);
}

class DxfTextPrim {
  final Offset pos;
  final double height;
  final String text;
  final int color;
  final double rotation; // degrees
  DxfTextPrim(this.pos, this.height, this.text, this.color, this.rotation);
}

class DxfParseException implements Exception {
  final String message;
  DxfParseException(this.message);
  @override
  String toString() => 'DXF: $message';
}

/// AutoCAD Color Index (ACI) -> Color. Exact for 1-9 and the gray band
/// 250-255; the 10-249 family/shade cube is approximated with HSV (good
/// enough for a viewer). ACI 7 (white-on-black in CAD) maps to dark
/// gray because we draw on white.
Color dxfAciColor(int aci, {Color fallback = const Color(0xFF263238)}) {
  const named = <int, int>{
    1: 0xFFFF0000,
    2: 0xFFFFFF00,
    3: 0xFF00FF00,
    4: 0xFF00FFFF,
    5: 0xFF0000FF,
    6: 0xFFFF00FF,
    7: 0xFF37474F,
    8: 0xFF808080,
    9: 0xFFBFBFBF,
  };
  if (aci >= 1 && aci <= 9) return Color(named[aci]!);
  if (aci >= 250 && aci <= 255) {
    const g = <int>[51, 69, 90, 112, 135, 170];
    final v = g[aci - 250];
    return Color(0xFF000000 | v << 16 | v << 8 | v);
  }
  if (aci >= 10 && aci < 250) {
    final i = aci - 10;
    final family = i ~/ 10; // 0..23
    final shade = i % 10; // 0..9 (0 = saturated)
    final hue = (family % 6) * 60.0 + (family ~/ 6) * 30.0;
    final sat = shade == 0 ? 1.0 : (1.0 - (shade % 5) * 0.12);
    final val = shade == 0 ? 1.0 : (1.0 - (shade ~/ 5) * 0.25);
    return HSVColor.fromAHSV(1, hue % 360, sat, val).toColor();
  }
  return fallback;
}

/// The ACI index whose rendered color is [argb] — the inverse of
/// [dxfAciColor], for re-emitting parsed entities as DXF (the
/// parser stores resolved colors, group 62 wants the index back).
int aciFromArgb(int argb) {
  for (var aci = 1; aci <= 255; aci++) {
    if (dxfAciColor(aci).toARGB32() == argb) return aci;
  }
  return 7;
}

class _Pair {
  final int code;
  final String val;
  _Pair(this.code, this.val);
  double get d => double.tryParse(val.trim()) ?? 0;
  int get i => int.tryParse(val.trim()) ?? 0;
}

/// Affine 2D transform (x' = a*x + c*y + tx; y' = b*x + d*y + ty).
class _Xf {
  final double a, b, c, d, tx, ty;
  const _Xf([
    this.a = 1,
    this.b = 0,
    this.c = 0,
    this.d = 1,
    this.tx = 0,
    this.ty = 0,
  ]);
  Offset apply(Offset p) =>
      Offset(a * p.dx + c * p.dy + tx, b * p.dx + d * p.dy + ty);
  _Xf mul(_Xf o) => _Xf(
    a * o.a + c * o.b,
    b * o.a + d * o.b,
    a * o.c + c * o.d,
    b * o.c + d * o.d,
    a * o.tx + c * o.ty + tx,
    b * o.tx + d * o.ty + ty,
  );
  double get scale => (math.sqrt(a * a + b * b) + math.sqrt(c * c + d * d)) / 2;
}

class DxfParser {
  static DxfScene parse(String src) {
    final pairs = <_Pair>[];
    final lines = src.split(RegExp(r'\r?\n'));
    for (var i = 0; i + 1 < lines.length; i += 2) {
      pairs.add(_Pair(int.tryParse(lines[i].trim()) ?? -1, lines[i + 1]));
    }
    final layers = <String, int>{}; // name -> aci
    final blocks = <String, List<_Pair>>{}; // name -> body pairs
    final entities = <List<_Pair>>[];
    _scan(pairs, layers, blocks, entities);
    if (entities.isEmpty) {
      throw DxfParseException('no ENTITIES section found');
    }
    final prims = <DxfPrim>[];
    final texts = <DxfTextPrim>[];
    for (final e in entities) {
      _emit(e, const _Xf(), layers, blocks, prims, texts, 0);
    }
    if (prims.isEmpty && texts.isEmpty) {
      throw DxfParseException('no drawable entities');
    }
    var minX = double.infinity,
        minY = double.infinity,
        maxX = -double.infinity,
        maxY = -double.infinity;
    void grow(Offset p) {
      if (p.dx < minX) minX = p.dx;
      if (p.dy < minY) minY = p.dy;
      if (p.dx > maxX) maxX = p.dx;
      if (p.dy > maxY) maxY = p.dy;
    }

    for (final p in prims) {
      for (final q in p.pts) {
        grow(q);
      }
    }
    for (final t in texts) {
      grow(t.pos);
      grow(t.pos + Offset(t.height * t.text.length * 0.6, t.height));
    }
    if (!minX.isFinite) {
      minX = minY = 0;
      maxX = maxY = 100;
    }
    return DxfScene(
      prims,
      texts,
      Rect.fromLTRB(minX, minY, maxX, maxY).inflate(0.01),
    );
  }

  /// Group the raw pairs into ENTITIES bodies, plus LAYER colors and
  /// BLOCK definitions for INSERT expansion.
  static void _scan(
    List<_Pair> pairs,
    Map<String, int> layers,
    Map<String, List<_Pair>> blocks,
    List<List<_Pair>> entities,
  ) {
    String section = '';
    String? table;
    List<_Pair>? ent;
    List<_Pair>? blk;
    var inVertex = false;

    void flushEnt() {
      final e = ent;
      if (e != null) {
        entities.add(e);
        ent = null;
      }
      inVertex = false;
    }

    for (var i = 0; i < pairs.length; i++) {
      final p = pairs[i];
      if (p.code == 0) {
        final v = p.val.trim().toUpperCase();
        if (v == 'SECTION') {
          flushEnt();
          section = '';
        } else if (v == 'ENDSEC' || v == 'EOF') {
          flushEnt();
          section = '';
        } else if (v == 'TABLE' || v == 'ENDTAB') {
          table = null;
        } else if (section == 'TABLES' && v == 'LAYER') {
          // read forward to code 0
          var name = '', aci = 7;
          var j = i + 1;
          while (j < pairs.length && pairs[j].code != 0) {
            if (pairs[j].code == 2) name = pairs[j].val.trim().toUpperCase();
            if (pairs[j].code == 62) aci = pairs[j].i.abs();
            j++;
          }
          if (name.isNotEmpty) layers[name] = aci;
          i = j - 1;
        } else if (section == 'BLOCKS' && v == 'BLOCK') {
          blk = <_Pair>[];
        } else if (section == 'BLOCKS' && v == 'ENDBLK') {
          if (blk != null) {
            final nm = _first(blk, 2).trim().toUpperCase();
            if (nm.isNotEmpty) blocks[nm] = blk;
          }
          blk = null;
        } else if (section == 'ENTITIES' && ent == null && !inVertex) {
          ent = <_Pair>[_Pair(0, v)];
        } else if (inVertex) {
          if (v == 'SEQEND') {
            inVertex = false;
          } else {
            ent?.add(_Pair(0, 'VERTEXMARK'));
          }
        } else if (ent != null) {
          if (v == 'VERTEX') {
            inVertex = true;
            ent?.add(_Pair(0, 'VERTEXMARK'));
          } else {
            flushEnt();
            ent = <_Pair>[_Pair(0, v)];
          }
        }
        if (blk != null && v != 'BLOCK' && v != 'ENDBLK') {
          blk.add(_Pair(0, v));
        }
        continue;
      }
      if (p.code == 2) {
        final v = p.val.trim().toUpperCase();
        const secs = {
          'HEADER',
          'CLASSES',
          'TABLES',
          'BLOCKS',
          'ENTITIES',
          'OBJECTS',
          'ACDSDATA',
          'THUMBNAILIMAGE',
        };
        if (section.isEmpty && secs.contains(v)) {
          section = v;
          continue;
        }
        if (section == 'TABLES' && table == null && blk == null) {
          table = v;
          continue;
        }
      }
      if (blk != null) {
        blk.add(p);
      } else {
        ent?.add(p);
      }
    }
    flushEnt();
  }

  static String _first(List<_Pair> e, int code, [String def = '']) {
    for (final p in e) {
      if (p.code == code) return p.val;
    }
    return def;
  }

  static double _num(List<_Pair> e, int code, [double def = 0]) {
    for (final p in e) {
      if (p.code == code) return p.d;
    }
    return def;
  }

  static List<double> _all(List<_Pair> e, int code) => [
    for (final p in e)
      if (p.code == code) p.d,
  ];

  static int _aci(List<_Pair> e, Map<String, int> layers, _Xf xf) {
    final c = _num(e, 62, 256).round();
    if (c >= 1 && c < 256) return c;
    final lay = _first(e, 8).trim().toUpperCase();
    return layers[lay] ?? 7;
  }

  /// Approximate a polyline arc between p1->p2 given LWPOLYLINE bulge b.
  static List<Offset> _bulgeArc(Offset p1, Offset p2, double b) {
    final chord = p2 - p1;
    final len = chord.distance;
    if (len < 1e-9 || b.abs() < 1e-9) return [p2];
    final theta = 4 * math.atan(b.abs()); // included angle
    final r = len / (2 * math.sin(theta / 2));
    final mid = (p1 + p2) / 2;
    final h = r * math.cos(theta / 2);
    final n = Offset(-chord.dy / len, chord.dx / len) * (b > 0 ? h : -h);
    final c = mid + n;
    final a1 = math.atan2(p1.dy - c.dy, p1.dx - c.dx);
    var a2 = math.atan2(p2.dy - c.dy, p2.dx - c.dx);
    if (b > 0) {
      while (a2 <= a1) {
        a2 += 2 * math.pi;
      }
    } else {
      while (a2 >= a1) {
        a2 -= 2 * math.pi;
      }
    }
    final segs = math.max(4, (theta / (math.pi / 24)).ceil());
    return [
      for (var i = 1; i <= segs; i++)
        c + Offset.fromDirection(a1 + (a2 - a1) * i / segs, r),
    ];
  }

  static void _emit(
    List<_Pair> e,
    _Xf xf,
    Map<String, int> layers,
    Map<String, List<_Pair>> blocks,
    List<DxfPrim> prims,
    List<DxfTextPrim> texts,
    int depth,
  ) {
    final kind = _first(e, 0).toUpperCase();
    final aci = _aci(e, layers, xf);
    final col = dxfAciColor(aci).toARGB32();
    List<Offset> pts = [];
    var closed = false;
    Offset pt(int xc, int yc) => Offset(_num(e, xc), _num(e, yc));

    switch (kind) {
      case 'LINE':
        pts = [pt(10, 20), pt(11, 21)];
        break;
      case 'LWPOLYLINE':
        final xs = _all(e, 10), ys = _all(e, 20);
        final vs = [
          for (var i = 0; i < xs.length && i < ys.length; i++)
            Offset(xs[i], ys[i]),
        ];
        closed = (_num(e, 70).toInt() & 1) == 1;
        final bl = _all(e, 42);
        pts = [if (vs.isNotEmpty) vs.first];
        for (var i = 0; i < vs.length; i++) {
          final nxt = i + 1 < vs.length ? i + 1 : 0;
          if (!closed && nxt == 0) break;
          final b = i < bl.length ? bl[i] : 0.0;
          pts.addAll(b != 0 ? _bulgeArc(vs[i], vs[nxt], b) : [vs[nxt]]);
        }
        break;
      case 'POLYLINE':
        closed = (_num(e, 70).toInt() & 1) == 1;
        final xs = <double>[], ys = <double>[];
        var inVert = false;
        for (final p in e) {
          if (p.code == 0) {
            final v = p.val.trim().toUpperCase();
            inVert = v == 'VERTEXMARK' || v == 'VERTEX';
            continue;
          }
          if (inVert && p.code == 10) xs.add(p.d);
          if (inVert && p.code == 20) ys.add(p.d);
        }
        pts = [
          for (var i = 0; i < xs.length && i < ys.length; i++)
            Offset(xs[i], ys[i]),
        ];
        break;
      case 'CIRCLE':
        final c = pt(10, 20), r = _num(e, 40);
        pts = [
          for (var i = 0; i < 48; i++)
            c + Offset.fromDirection(2 * math.pi * i / 48, r),
        ];
        closed = true;
        break;
      case 'ARC':
        final c = pt(10, 20), r = _num(e, 40);
        var a1 = _num(e, 50) * math.pi / 180, a2 = _num(e, 51) * math.pi / 180;
        while (a2 <= a1) {
          a2 += 2 * math.pi;
        }
        final n = math.max(6, ((a2 - a1) / (math.pi / 24)).ceil());
        pts = [
          for (var i = 0; i <= n; i++)
            c + Offset.fromDirection(a1 + (a2 - a1) * i / n, r),
        ];
        break;
      case 'ELLIPSE':
        final c = pt(10, 20), m = pt(11, 21);
        final r1 = m.distance, ratio = _num(e, 40, 1);
        final ang = m.direction;
        final t1 = _num(e, 41), t2raw = _num(e, 42, 2 * math.pi);
        final t2 = t2raw <= t1 ? t2raw + 2 * math.pi : t2raw;
        final n = math.max(12, ((t2 - t1) / (math.pi / 24)).ceil());
        pts = [
          for (var i = 0; i <= n; i++)
            c +
                Offset(
                  r1 * math.cos(t1 + (t2 - t1) * i / n) * math.cos(ang) -
                      r1 *
                          ratio *
                          math.sin(t1 + (t2 - t1) * i / n) *
                          math.sin(ang),
                  r1 * math.cos(t1 + (t2 - t1) * i / n) * math.sin(ang) +
                      r1 *
                          ratio *
                          math.sin(t1 + (t2 - t1) * i / n) *
                          math.cos(ang),
                ),
        ];
        closed = (t2 - t1) >= 2 * math.pi - 0.01;
        break;
      case 'SPLINE':
      case 'LEADER':
        final xs = _all(e, 10), ys = _all(e, 20);
        pts = [
          for (var i = 0; i < xs.length && i < ys.length; i++)
            Offset(xs[i], ys[i]),
        ];
        break;
      case 'POINT':
        final c = pt(10, 20), s = math.max(_num(e, 40, 1), 0.5);
        prims.add(DxfPrim([c + Offset(-s, 0), c + Offset(s, 0)], false, col));
        prims.add(DxfPrim([c + Offset(0, -s), c + Offset(0, s)], false, col));
        return;
      case 'SOLID':
      case 'TRACE':
      case '3DFACE':
        pts = [pt(10, 20), pt(11, 21), pt(12, 22), pt(13, 23)];
        closed = true;
        break;
      case 'TEXT':
      case 'ATTRIB':
      case 'ATTDEF':
        final s = _first(e, 1).trim();
        if (s.isEmpty) return;
        final p = xf.apply(pt(10, 20));
        texts.add(
          DxfTextPrim(
            p,
            _num(e, 40, 2.5) * xf.scale,
            s,
            col,
            _num(e, 50) + _rotOf(xf),
          ),
        );
        return;
      case 'MTEXT':
        var s = _first(e, 1);
        final cont = e.where((p) => p.code == 3).map((p) => p.val).join();
        s = cont + s;
        s = s
            .replaceAll(RegExp(r'\\P', caseSensitive: false), '\n')
            .replaceAll(RegExp(r'\\[A-Za-z][^;{}]*;'), '')
            .replaceAll(RegExp(r'[{}]'), '')
            .replaceAll('%%d', '°')
            .replaceAll('%%p', '±')
            .replaceAll('%%c', 'Ø')
            .trim();
        if (s.isEmpty) return;
        final p = xf.apply(pt(10, 20));
        texts.add(DxfTextPrim(p, _num(e, 40, 2.5) * xf.scale, s, col, 0));
        return;
      case 'INSERT':
        final name = _first(e, 2).trim().toUpperCase();
        final blk = blocks[name];
        if (blk == null || depth > 6) return;
        final ins = pt(10, 20);
        final rot = _num(e, 50) * math.pi / 180;
        final sx = _num(e, 41, 1), sy = _num(e, 42, 1);
        final base = Offset(_num(blk, 10), _num(blk, 20));
        final local = _Xf(
          sx * math.cos(rot),
          sx * math.sin(rot),
          -sy * math.sin(rot),
          sy * math.cos(rot),
          ins.dx -
              base.dx * (sx * math.cos(rot)) +
              base.dy * (sy * math.sin(rot)),
          ins.dy -
              base.dx * (sx * math.sin(rot)) -
              base.dy * (sy * math.cos(rot)),
        );
        final world = xf.mul(local);
        _emitBlock(blk, world, layers, blocks, prims, texts, depth);
        return;
      case 'HATCH':
        _emitHatch(e, xf, col, prims);
        return;
      case 'DIMENSION':
        // The anonymous *D block already stores the rendered arrows,
        // extension lines and text in world coordinates - replay it.
        final name = _first(e, 2).trim().toUpperCase();
        final blk = blocks[name];
        if (blk != null) {
          _emitBlock(blk, xf, layers, blocks, prims, texts, depth + 1);
          return;
        }
        final t = _first(e, 1).trim();
        if (t.isEmpty) return;
        texts.add(
          DxfTextPrim(
            xf.apply(pt(11, 21)),
            _num(e, 140, 2.5) * xf.scale,
            t,
            col,
            0,
          ),
        );
        return;
      case 'MULTILEADER':
        _emitMLeader(e, xf, col, prims, texts);
        return;
      default:
        return; // VIEWPORT, OLE2FRAME, etc.
    }
    if (pts.length < 2) return;
    prims.add(DxfPrim([for (final p in pts) xf.apply(p)], closed, col));
  }

  /// Emit every entity stored inside a block body under [xf].
  static void _emitBlock(
    List<_Pair> blk,
    _Xf xf,
    Map<String, int> layers,
    Map<String, List<_Pair>> blocks,
    List<DxfPrim> prims,
    List<DxfTextPrim> texts,
    int depth,
  ) {
    var cur = <_Pair>[];
    for (final p in blk) {
      if (p.code == 0) {
        if (cur.isNotEmpty) {
          _emit(cur, xf, layers, blocks, prims, texts, depth + 1);
        }
        cur = [_Pair(0, p.val)];
      } else {
        cur.add(p);
      }
    }
    if (cur.isNotEmpty) {
      _emit(cur, xf, layers, blocks, prims, texts, depth + 1);
    }
  }

  /// Sample a HATCH's boundary loops. Solid fills become [DxfPrim]s
  /// with fillLoops (even-odd, islands become holes); patterned
  /// hatches render as closed outlines. Handles polyline boundaries
  /// (92 bit 2) plus line/arc/ellipse/spline edge boundaries.
  static void _emitHatch(List<_Pair> e, _Xf xf, int col, List<DxfPrim> prims) {
    final solid =
        _num(e, 70).toInt() == 1 ||
        _first(e, 2).trim().toUpperCase() == 'SOLID';
    var i = 0;
    while (i < e.length && e[i].code != 91) {
      i++; // loop count
    }
    if (i >= e.length) return;
    var loops = e[i].i;
    i++;
    final out = <List<Offset>>[];
    while (loops-- > 0 && i < e.length) {
      while (i < e.length && e[i].code != 92) {
        i++; // path flags
      }
      if (i >= e.length) return;
      final poly = (e[i].i & 2) != 0;
      i++;
      final loop = <Offset>[];
      if (poly) {
        var hasBulge = false, closedLoop = true, n = 0;
        while (i < e.length && e[i].code != 93) {
          if (e[i].code == 72) hasBulge = e[i].i != 0;
          if (e[i].code == 73) closedLoop = e[i].i != 0;
          i++;
        }
        if (i >= e.length) return;
        n = e[i].i;
        i++;
        final vs = <Offset>[], bl = <double>[];
        for (var v = 0; v < n && i < e.length; v++) {
          double x = 0, y = 0, b = 0;
          if (i < e.length && e[i].code == 10) x = e[i++].d;
          if (i < e.length && e[i].code == 20) y = e[i++].d;
          if (hasBulge && i < e.length && e[i].code == 42) b = e[i++].d;
          vs.add(Offset(x, y));
          bl.add(b);
        }
        if (vs.isNotEmpty) loop.add(vs.first);
        for (var v = 0; v < vs.length; v++) {
          final nxt = v + 1 < vs.length ? v + 1 : 0;
          if (!closedLoop && nxt == 0) break;
          loop.addAll(
            bl[v] != 0 ? _bulgeArc(vs[v], vs[nxt], bl[v]) : [vs[nxt]],
          );
        }
      } else {
        while (i < e.length && e[i].code != 93) {
          i++; // edge count
        }
        if (i >= e.length) return;
        var edges = e[i].i;
        i++;
        while (edges-- > 0 && i < e.length) {
          while (i < e.length && e[i].code != 72) {
            i++;
          }
          if (i >= e.length) return;
          final type = e[i].i;
          i++;
          double nx() => i < e.length ? e[i++].d : 0;
          List<Offset> seg;
          switch (type) {
            case 1: // line: 10/20 start, 11/21 end
              final a = Offset(nx(), nx()), b = Offset(nx(), nx());
              seg = [a, b];
              break;
            case 2: // circular arc: c10/20, r40, a50/51, ccw73
              final c = Offset(nx(), nx()), r = nx();
              var a1 = nx() * math.pi / 180, a2 = nx() * math.pi / 180;
              final ccw = i < e.length && e[i].code == 73
                  ? e[i++].i != 0
                  : true;
              if (ccw) {
                while (a2 <= a1) {
                  a2 += 2 * math.pi;
                }
              } else {
                while (a2 >= a1) {
                  a2 -= 2 * math.pi;
                }
              }
              final nseg = math.max(
                4,
                ((a2 - a1).abs() / (math.pi / 24)).ceil(),
              );
              seg = [
                for (var k = 0; k <= nseg; k++)
                  c + Offset.fromDirection(a1 + (a2 - a1) * k / nseg, r),
              ];
              break;
            case 3: // elliptic arc: c10/20, major11/21, ratio40, t50/51
              final c = Offset(nx(), nx()), mj = Offset(nx(), nx());
              final ratio = nx();
              var t1 = nx(), t2 = nx();
              final ccw = i < e.length && e[i].code == 73
                  ? e[i++].i != 0
                  : true;
              if (ccw) {
                while (t2 <= t1) {
                  t2 += 2 * math.pi;
                }
              } else {
                while (t2 >= t1) {
                  t2 -= 2 * math.pi;
                }
              }
              final r1 = mj.distance, ang = mj.direction;
              final nseg = math.max(
                8,
                ((t2 - t1).abs() / (math.pi / 24)).ceil(),
              );
              seg = [
                for (var k = 0; k <= nseg; k++)
                  c +
                      Offset(
                        r1 *
                                math.cos(t1 + (t2 - t1) * k / nseg) *
                                math.cos(ang) -
                            r1 *
                                ratio *
                                math.sin(t1 + (t2 - t1) * k / nseg) *
                                math.sin(ang),
                        r1 *
                                math.cos(t1 + (t2 - t1) * k / nseg) *
                                math.sin(ang) +
                            r1 *
                                ratio *
                                math.sin(t1 + (t2 - t1) * k / nseg) *
                                math.cos(ang),
                      ),
              ];
              break;
            case 4: // spline -> control-polyline approximation
              nx();
              nx(); // 94 degree, 73 rational
              nx(); // 74 periodic
              var nk = nx().toInt(), nc = nx().toInt(); // 95, 96
              for (var k = 0; k < nk && i < e.length; k++) {
                nx(); // knots
              }
              seg = [
                for (var k = 0; k < nc && i < e.length; k++) Offset(nx(), nx()),
              ];
              break;
            default:
              seg = const [];
          }
          for (final q in seg) {
            if (loop.isEmpty || (q - loop.last).distance > 1e-9) {
              loop.add(q);
            }
          }
        }
      }
      // skip source-object handles (97) up to next loop or style
      while (i < e.length && e[i].code != 92 && e[i].code != 75) {
        i++;
      }
      if (loop.length > 1) out.add(loop);
    }
    if (out.isEmpty) return;
    if (solid) {
      prims.add(
        DxfPrim(
          [
            for (final l in out)
              for (final p in l) xf.apply(p),
          ],
          true,
          col,
          [
            for (final l in out) [for (final p in l) xf.apply(p)],
          ],
        ),
      );
    } else {
      for (final l in out) {
        prims.add(DxfPrim([for (final p in l) xf.apply(p)], true, col));
      }
    }
  }

  /// Pull the annotation text + leader segment out of a MULTILEADER's
  /// context data (300 CONTEXT_DATA{ ... 304 text ... } and
  /// LEADER_LINE{ 10/20 anchor }).
  static void _emitMLeader(
    List<_Pair> e,
    _Xf xf,
    int col,
    List<DxfPrim> prims,
    List<DxfTextPrim> texts,
  ) {
    Offset? textPos, leaderEnd, connPt;
    var text = '', height = 0.0;
    var inCtx = false, inLine = false, inLeader = false, ctxClosed = false;
    for (var i = 0; i < e.length; i++) {
      final p = e[i];
      if (p.code == 300) inCtx = true;
      if (p.code == 301) {
        inCtx = false;
        ctxClosed = true;
      }
      if (p.code == 302) inLeader = true;
      if (p.code == 303) inLeader = false;
      if (p.code == 304 && p.val.trim() == 'LEADER_LINE{') inLine = true;
      if (p.code == 305) inLine = false;
      if (inCtx) {
        if (p.code == 10 && textPos == null) {
          var y = 0.0;
          if (i + 2 < e.length && e[i + 1].code == 20) y = e[i + 1].d;
          textPos = Offset(p.d, y);
        }
        // Context 41 is scaled-space text height; the entity-level 41
        // (after 301) holds the real height - prefer it.
        if (p.code == 41 && height == 0) height = p.d;
        if (p.code == 304 &&
            p.val.trim() != 'LEADER_LINE{' &&
            !p.val.trim().endsWith('{') &&
            text.isEmpty) {
          text = p.val;
        }
        // LEADER{ 10/20 } is the connection point on the object side.
        if (inLeader && p.code == 10 && connPt == null && !inLine) {
          var y = 0.0;
          if (i + 1 < e.length && e[i + 1].code == 20) y = e[i + 1].d;
          connPt = Offset(p.d, y);
        }
      }
      if (inLine && p.code == 10 && leaderEnd == null) {
        var y = 0.0;
        if (i + 1 < e.length && e[i + 1].code == 20) y = e[i + 1].d;
        leaderEnd = Offset(p.d, y);
      }
      if (ctxClosed && !inCtx && p.code == 41 && height <= 0.12) {
        height = p.d; // entity-level text height beats the context's
      }
    }
    text = text
        .replaceAll(RegExp(r'\\P', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'\\[A-Za-z][^;{}]*;'), '')
        .replaceAll(RegExp(r'[{}]'), '')
        .replaceAll('%%d', '°')
        .replaceAll('%%p', '±')
        .replaceAll('%%c', 'Ø')
        .trim();
    if (textPos != null) {
      // Leader polyline: connection -> line -> text base, deduped.
      final pts = <Offset>[];
      for (final pt in [connPt, leaderEnd, textPos]) {
        if (pt == null) continue;
        if (pts.isEmpty || (pts.last - pt).distance > 0.001) {
          pts.add(pt);
        }
      }
      if (pts.length >= 2) {
        prims.add(DxfPrim(pts.map((p) => xf.apply(p)).toList(), false, col));
      }
    }
    if (text.isNotEmpty && textPos != null) {
      texts.add(
        DxfTextPrim(
          xf.apply(textPos),
          (height > 0 ? height : 0.17) * xf.scale,
          text,
          col,
          0,
        ),
      );
    }
  }

  static double _rotOf(_Xf xf) => math.atan2(xf.b, xf.a) * 180 / math.pi;
}

/// Paints a [DxfScene] into the (already-sized) canvas. Caller sizes the
/// widget to `scene.naturalSize()` and this painter fits the bounds in,
/// flipping Y (DXF is Y-up).
class DxfPainter extends CustomPainter {
  final DxfScene scene;
  final double scale; // content px per world unit (precomputed by caller)
  const DxfPainter(this.scene, this.scale);

  @override
  void paint(Canvas canvas, Size size) {
    final b = scene.bounds;
    // screen_x = (x - left)*s ; screen_y = (top + height - y)*s  (Y flip)
    final xform = Matrix4.identity()
      ..scaleByDouble(scale, -scale, 1, 1)
      ..translateByDouble(-b.left, -(b.top + b.height), 0, 1);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      // paths are pre-transformed to screen px (path.transform below),
      // so the stroke width is in screen px - dividing by scale here
      // would draw a 1.2/scale px ghost line.
      ..strokeWidth = 1.2
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round;
    final byColor = <int, Path>{};
    final fills = <int, Path>{};
    for (final p in scene.prims) {
      final loops = p.fillLoops;
      if (loops != null) {
        final path = fills.putIfAbsent(p.color, Path.new)
          ..fillType = PathFillType.evenOdd;
        for (final loop in loops) {
          path.addPolygon([for (final q in loop) Offset(q.dx, q.dy)], true);
        }
        continue;
      }
      final path = byColor.putIfAbsent(p.color, Path.new);
      for (var i = 0; i < p.pts.length; i++) {
        final q = p.pts[i];
        if (i == 0) {
          path.moveTo(q.dx, q.dy);
        } else {
          path.lineTo(q.dx, q.dy);
        }
      }
      if (p.closed) path.close();
    }
    final fillPaint = Paint()..style = PaintingStyle.fill;
    fills.forEach((col, path) {
      fillPaint.color = Color(col);
      canvas.drawPath(path.transform(xform.storage), fillPaint);
    });
    byColor.forEach((col, path) {
      paint.color = Color(col);
      canvas.drawPath(path.transform(xform.storage), paint);
    });
    for (final t in scene.texts) {
      final p = MatrixUtils.transformPoint(xform, t.pos);
      final tp = TextPainter(
        text: TextSpan(
          text: t.text,
          style: TextStyle(
            color: Color(t.color),
            fontSize: (t.height * scale).clamp(1.5, 600.0),
          ),
        ),
        textDirection: TextDirection.ltr,
        maxLines: 6,
      )..layout(maxWidth: size.width * 0.9);
      canvas.save();
      canvas.translate(p.dx, p.dy - t.height * scale);
      if (t.rotation != 0) canvas.rotate(-t.rotation * math.pi / 180);
      tp.paint(canvas, Offset.zero);
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(DxfPainter old) => old.scene != scene;
}

/// Rasterize [scene] to PNG bytes — the PDF export's drawing pages and
/// any headless sheet preview go through this (dart:ui picture, no
/// widget needed; same pattern as renderSCurvePng). White paper, the
/// painter's own Y-flip/fit.
Future<Uint8List?> renderDxfPng(DxfScene scene, {double maxPx = 2400}) async {
  try {
    final size = scene.naturalSize(maxPx: maxPx);
    final w = size.width.round(), h = size.height.round();
    final rec = ui.PictureRecorder();
    final canvas = Canvas(rec, Rect.fromLTWH(0, 0, size.width, size.height));
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, size.height),
      Paint()..color = Colors.white,
    );
    DxfPainter(scene, size.width / scene.bounds.width).paint(canvas, size);
    final img = await rec.endRecording().toImage(w, h);
    final bd = await img.toByteData(format: ui.ImageByteFormat.png);
    return bd?.buffer.asUint8List();
  } catch (_) {
    return null;
  }
}
