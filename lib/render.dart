// Ray-traced still renderer for the 3D MODEL tab (V-Ray-lite).
//
// Pure Dart - no Flutter imports - so the same code can run inside a
// widget, a flutter test, or a background Isolate. The caller hands
// over a flat triangle soup (positions + per-triangle ARGB colors)
// and gets back an encoded PNG.
//
// Pipeline: BVH (median centroid split) -> per-pixel perspective rays
// -> Moller-Trumbore -> sun + hemisphere ambient + AO + soft shadows
// -> glass transmit/reflect -> Reinhard tone map -> PNG.
//
// The PNG encoder is hand-rolled (zlib via dart:io ZLibCodec + CRC32)
// so this file needs no package deps and stays isolate-safe.

import 'dart:io' show ZLibCodec;
import 'dart:math' as math;
import 'dart:typed_data';

/// Quality ladder for [renderPng]. DRAFT trades samples for speed
/// (no AO, one hard shadow ray, 1 spp, 60% resolution); STANDARD adds
/// 6-ray AO, 4-ray soft shadows, 2 spp; FINAL pushes to 8 AO / 6 soft
/// rays / 4 spp plus a single diffuse bounce for color bleeding.
enum RenderQuality { draft, standard, finalQuality }

/// Decoded equirectangular HDR environment map (linear RGB radiance).
/// Bundled Poly Haven CC0 1k maps ship in `assets/env/`; the dialog
/// decodes once via [decodeHdr] and hands the map to [RenderJob].
/// A null env keeps the procedural sky gradient.
class EnvMap {
  EnvMap._(this.width, this.height, this.px);

  /// Image size; [px] is width*height*3 linear radiance, row-major,
  /// v=0 at the TOP of the image (zenith), +Z world = zenith.
  final int width, height;
  final Float32List px;

  /// Bilinear equirect lookup for a normalized direction.
  /// u from atan2(dy,dx), v from acos(dz) so +Z world hits v=0.
  void sample(double dx, double dy, double dz, Float64List out) {
    final u = math.atan2(dy, dx) * 0.15915494309189535 + 0.5;
    final v = math.acos(dz.clamp(-1.0, 1.0)) * 0.3183098861837907;
    final fx = u * width - 0.5, fy = v * height - 0.5;
    var x0 = fx.floor(), y0 = fy.floor();
    final tx = fx - x0, ty = fy - y0;
    x0 = ((x0 % width) + width) % width;
    var x1 = x0 + 1;
    if (x1 >= width) x1 = 0;
    var y1 = y0 + 1;
    if (y0 < 0) y0 = 0;
    if (y0 >= height) y0 = height - 1;
    if (y1 >= height) y1 = height - 1;
    final i00 = (y0 * width + x0) * 3;
    final i10 = (y0 * width + x1) * 3;
    final i01 = (y1 * width + x0) * 3;
    final i11 = (y1 * width + x1) * 3;
    for (var c = 0; c < 3; c++) {
      final a = px[i00 + c] + (px[i10 + c] - px[i00 + c]) * tx;
      final b = px[i01 + c] + (px[i11 + c] - px[i01 + c]) * tx;
      out[c] = a + (b - a) * ty;
    }
  }

  /// Mean radiance over the lower hemisphere (v > 0.5, dz < 0) -
  /// used as the ground-plane tint so the floor matches the env's
  /// real ground (grass, pavement, studio floor...).
  void avgDown(Float64List out) {
    var n = 0;
    for (var y = height ~/ 2; y < height; y += 4) {
      for (var x = 0; x < width; x += 8) {
        final i = (y * width + x) * 3;
        out[0] += px[i];
        out[1] += px[i + 1];
        out[2] += px[i + 2];
        n++;
      }
    }
    if (n > 0) {
      out[0] /= n;
      out[1] /= n;
      out[2] /= n;
    }
  }

  /// Mean luminance over the WHOLE map (strided sample) - the
  /// auto-exposure reference. HDRIs ship unclipped absolute
  /// radiance, so a dim sky (0.2) vs a bright studio (1.0) needs
  /// per-map normalization or everything renders muddy-dark.
  double meanLum() {
    var n = 0, s = 0.0;
    for (var y = 0; y < height; y += 4) {
      for (var x = 0; x < width; x += 8) {
        final i = (y * width + x) * 3;
        s += 0.2126 * px[i] + 0.7152 * px[i + 1] + 0.0722 * px[i + 2];
        n++;
      }
    }
    return n == 0 ? 0.5 : s / n;
  }
}

/// Radiance .hdr (RGBE) decoder - parses the text header, then either
/// flat quads or the new per-scanline RLE (2,2,wHi,wLo + 4 channel
/// planes of count/value runs). Returns null on any format surprise.
EnvMap? decodeHdr(Uint8List bytes) {
  // header = text lines up to a blank line, then the -Y/+X res line
  var pos = 0;
  int endLine(int from) {
    final i = bytes.indexOf(0x0A, from);
    return i < 0 ? bytes.length : i;
  }

  if (bytes.length < 11 ||
      bytes[0] != 0x23 || // '#'
      bytes[1] != 0x3F) {
    // '?'
    return null;
  }
  var w = 0, h = 0, dataStart = -1;
  while (pos < bytes.length) {
    final e = endLine(pos);
    if (e == pos) {
      // blank line ends the header; the res line follows
      final rs = pos + 1;
      final re = endLine(rs);
      final l = String.fromCharCodes(bytes.sublist(rs, re));
      final m = RegExp(r'-Y (\d+) \+X (\d+)').firstMatch(l);
      if (m == null) return null;
      h = int.parse(m.group(1)!);
      w = int.parse(m.group(2)!);
      dataStart = re + 1;
      break;
    }
    pos = e + 1;
  }
  if (w <= 0 || h <= 0 || dataStart < 0) return null;
  final px = Float32List(w * h * 3);
  final scan = Uint8List(w * 4);
  pos = dataStart;
  for (var y = 0; y < h; y++) {
    if (w >= 8 &&
        w < 32768 &&
        pos + 4 <= bytes.length &&
        bytes[pos] == 2 &&
        bytes[pos + 1] == 2 &&
        (bytes[pos + 2] & 0x80) == 0 &&
        bytes[pos + 2] * 256 + bytes[pos + 3] == w) {
      pos += 4;
      for (var c = 0; c < 4; c++) {
        var x = 0;
        while (x < w) {
          if (pos >= bytes.length) return null;
          var n = bytes[pos++];
          if (n > 128) {
            n -= 128;
            if (pos >= bytes.length || x + n > w) return null;
            final v = bytes[pos++];
            for (var k = 0; k < n; k++) {
              scan[x++ * 4 + c] = v;
            }
          } else {
            if (n == 0 || pos + n > bytes.length || x + n > w) {
              return null;
            }
            for (var k = 0; k < n; k++) {
              scan[x++ * 4 + c] = bytes[pos++];
            }
          }
        }
      }
    } else {
      // flat RGBE quads
      if (pos + w * 4 > bytes.length) return null;
      scan.setRange(0, w * 4, bytes, pos);
      pos += w * 4;
    }
    for (var x = 0; x < w; x++) {
      final e = scan[x * 4 + 3];
      final o = (y * w + x) * 3;
      if (e == 0) {
        px[o] = px[o + 1] = px[o + 2] = 0;
      } else {
        // f = 2^(e-136); Radiance adds +0.5 for roundoff
        final f = math.pow(2.0, e - 136).toDouble();
        px[o] = (scan[x * 4] + 0.5) * f;
        px[o + 1] = (scan[x * 4 + 1] + 0.5) * f;
        px[o + 2] = (scan[x * 4 + 2] + 0.5) * f;
      }
    }
  }
  return EnvMap._(w, h, px);
}

/// Accumulates polygons into the flat buffers [RenderJob] consumes.
/// Fan-triangulates each polygon (all model faces are convex planar
/// quads/tris, so a fan is exact).
class TriSoup {
  final _v = <double>[];
  final _t = <int>[];
  final _c = <int>[];

  int get triangleCount => _c.length;

  void addPoly(List<List<double>> verts, int argb) {
    for (var i = 1; i + 1 < verts.length; i++) {
      for (final k in [0, i, i + 1]) {
        _t.add(_v.length ~/ 3);
        final p = verts[k];
        _v.add(p[0]);
        _v.add(p[1]);
        _v.add(p[2]);
      }
      _c.add(argb);
    }
  }

  Float64List get vpos => Float64List.fromList(_v);
  Int32List get tris => Int32List.fromList(_t);
  Int32List get colors => Int32List.fromList(_c);
}

/// Everything [renderPng] needs - plain typed data so a job can be
/// shipped to an Isolate untouched.
class RenderJob {
  RenderJob({
    required this.vpos,
    required this.triIdx,
    required this.colors,
    this.yaw = -0.7,
    this.pitch = 0.55,
    this.groundZ = -0.02,
    this.width = 1280,
    this.height = 720,
    this.quality = RenderQuality.standard,
    this.fovDeg = 40,
    this.distMul = 1.0,
    this.env,
    this.bgTop,
    this.bgBottom,
    this.bgGround,
    this.interiorGlow = false,
  });

  /// Flat vertex positions (x,y,z per vertex).
  final Float64List vpos;

  /// Triangle vertex indices into [vpos] (3 per triangle).
  final Int32List triIdx;

  /// Per-triangle ARGB. alpha < 255 marks glass (translucent).
  final Int32List colors;

  /// Camera orbit angles, same convention as cam3Project/cam3Depth.
  final double yaw;
  final double pitch;

  /// Infinite ground plane height (painter uses minBase - 0.02).
  final double groundZ;

  /// Requested output size in pixels (DRAFT renders at 0.6x).
  final int width;
  final int height;

  final RenderQuality quality;

  /// Vertical field of view and an extra framing margin on top of the
  /// solved fit (the eye distance is computed so every bounds corner
  /// projects inside ~85% of frame, then scaled by [distMul]).
  final double fovDeg;
  final double distMul;

  /// Optional decoded HDRI environment: replaces the procedural sky,
  /// drives image-based ambient light (unoccluded AO rays sample it),
  /// tints the ground plane, and shows up in glass reflections.
  final EnvMap? env;

  /// Solid backdrop used when [env] is null: ARGB zenith/horizon for
  /// a gentle vertical gradient and the ground-plane color. White
  /// gives a seamless studio sweep, black a dark stage; the model's
  /// sun/shadow/AO lighting stays fully active on both.
  final int? bgTop;
  final int? bgBottom;
  final int? bgGround;

  /// Warm point light at the bounds center (~55% height, radius
  /// footprint*0.7, wall-occluded) - makes interiors glow through
  /// glass like the warm-lit V-Ray reference shots.
  final bool interiorGlow;
}

/// Median-split BVH over the triangle soup. Nodes live in parallel
/// typed arrays: count > 0 marks a leaf holding
/// `order[start .. start+count)` triangle indices.
class _Bvh {
  _Bvh(Float64List vpos, Int32List tris) {
    final nt = tris.length ~/ 3;
    _order = List<int>.generate(nt, (i) => i);
    _triBox = Float64List(nt * 6);
    _cent = Float64List(nt * 3);
    for (var t = 0; t < nt; t++) {
      var x0 = 1e30, y0 = 1e30, z0 = 1e30;
      var x1 = -1e30, y1 = -1e30, z1 = -1e30;
      for (var k = 0; k < 3; k++) {
        final vi = tris[t * 3 + k] * 3;
        x0 = math.min(x0, vpos[vi]);
        y0 = math.min(y0, vpos[vi + 1]);
        z0 = math.min(z0, vpos[vi + 2]);
        x1 = math.max(x1, vpos[vi]);
        y1 = math.max(y1, vpos[vi + 1]);
        z1 = math.max(z1, vpos[vi + 2]);
      }
      _triBox[t * 6] = x0;
      _triBox[t * 6 + 1] = y0;
      _triBox[t * 6 + 2] = z0;
      _triBox[t * 6 + 3] = x1;
      _triBox[t * 6 + 4] = y1;
      _triBox[t * 6 + 5] = z1;
      _cent[t * 3] = (x0 + x1) / 2;
      _cent[t * 3 + 1] = (y0 + y1) / 2;
      _cent[t * 3 + 2] = (z0 + z1) / 2;
    }
    _build(0, nt);
    nLeft = Int32List.fromList(_l);
    nRight = Int32List.fromList(_r);
    nStart = Int32List.fromList(_s);
    nCount = Int32List.fromList(_n);
    box = Float64List.fromList(_b);
    order = Int32List.fromList(_order);
  }

  final _l = <int>[], _r = <int>[], _s = <int>[], _n = <int>[];
  final _b = <double>[];
  late List<int> _order;
  late Float64List _triBox, _cent;
  late Float64List box;
  late Int32List nLeft, nRight, nStart, nCount, order;

  int _newNode() {
    _l.add(-1);
    _r.add(-1);
    _s.add(-1);
    _n.add(0);
    for (var i = 0; i < 6; i++) {
      _b.add(0);
    }
    return _n.length - 1;
  }

  int _build(int lo, int hi) {
    final ni = _newNode();
    // tight node box over this range
    var x0 = 1e30, y0 = 1e30, z0 = 1e30;
    var x1 = -1e30, y1 = -1e30, z1 = -1e30;
    var cx0 = 1e30, cy0 = 1e30, cz0 = 1e30;
    var cx1 = -1e30, cy1 = -1e30, cz1 = -1e30;
    for (var i = lo; i < hi; i++) {
      final t = _order[i] * 6;
      x0 = math.min(x0, _triBox[t]);
      y0 = math.min(y0, _triBox[t + 1]);
      z0 = math.min(z0, _triBox[t + 2]);
      x1 = math.max(x1, _triBox[t + 3]);
      y1 = math.max(y1, _triBox[t + 4]);
      z1 = math.max(z1, _triBox[t + 5]);
      final c = _order[i] * 3;
      cx0 = math.min(cx0, _cent[c]);
      cy0 = math.min(cy0, _cent[c + 1]);
      cz0 = math.min(cz0, _cent[c + 2]);
      cx1 = math.max(cx1, _cent[c]);
      cy1 = math.max(cy1, _cent[c + 1]);
      cz1 = math.max(cz1, _cent[c + 2]);
    }
    final b = ni * 6;
    _b[b] = x0;
    _b[b + 1] = y0;
    _b[b + 2] = z0;
    _b[b + 3] = x1;
    _b[b + 4] = y1;
    _b[b + 5] = z1;
    if (hi - lo <= 4) {
      _s[ni] = lo;
      _n[ni] = hi - lo;
      return ni;
    }
    // median split on the widest centroid axis
    final dx = cx1 - cx0, dy = cy1 - cy0, dz = cz1 - cz0;
    final axis = dx >= dy && dx >= dz ? 0 : (dy >= dz ? 1 : 2);
    _order.setRange(
      lo,
      hi,
      _order.sublist(lo, hi)
        ..sort((a, b2) => _cent[a * 3 + axis].compareTo(_cent[b2 * 3 + axis])),
    );
    final mid = (lo + hi) >> 1;
    _l[ni] = _build(lo, mid);
    _r[ni] = _build(mid, hi);
    return ni;
  }
}

/// Deterministic per-pixel xorshift32 - stable renders and no
/// Random() allocation in the hot loop.
class _Rng {
  _Rng(int seed) : s = (seed & 0xFFFFFFFF) | 1;
  int s;
  double next() {
    s = (s ^ (s << 13)) & 0xFFFFFFFF;
    s = s ^ (s >> 17);
    s = (s ^ (s << 5)) & 0xFFFFFFFF;
    return s / 4294967296.0;
  }
}

/// Scene constants (linear-light space, before tone mapping).
const _sunDir = [0.3534, -0.5049, 0.7875]; // _SolidPainter._light, unit
const _sunI = [1.55, 1.45, 1.28]; // warm white sun
const _skyZen = [0.42, 0.62, 0.83];
const _skyHor = [0.93, 0.91, 0.86];
const _ambSky = [0.62, 0.72, 0.85];
const _ambGnd = [0.78, 0.70, 0.58];
const _ambSide = [0.70, 0.70, 0.72];
const _gndAlb = [0.85, 0.76, 0.62];

class _Tracer {
  _Tracer(RenderJob j)
    : vpos = j.vpos,
      tris = j.triIdx,
      colors = j.colors,
      groundZ = j.groundZ,
      quality = j.quality,
      env = j.env,
      bgTop = j.bgTop,
      bgBottom = j.bgBottom,
      bgGround = j.bgGround,
      interiorGlow = j.interiorGlow,
      bvh = _Bvh(j.vpos, j.triIdx) {
    // scene bounds -> target + eye
    var x0 = 1e30, y0 = 1e30, z0 = 1e30;
    var x1 = -1e30, y1 = -1e30, z1 = -1e30;
    for (var i = 0; i + 2 < vpos.length; i += 3) {
      x0 = math.min(x0, vpos[i]);
      y0 = math.min(y0, vpos[i + 1]);
      z0 = math.min(z0, vpos[i + 2]);
      x1 = math.max(x1, vpos[i]);
      y1 = math.max(y1, vpos[i + 1]);
      z1 = math.max(z1, vpos[i + 2]);
    }
    if (x0 > x1) {
      x0 = 0;
      y0 = 0;
      z0 = 0;
      x1 = 10;
      y1 = 8;
      z1 = 3;
    }
    final cx = (x0 + x1) / 2, cy = (y0 + y1) / 2, cz = (z0 + z1) / 2;
    _gx = cx;
    _gy = cy;
    _gz = z0 + (z1 - z0) * 0.6;
    _gRad = math.sqrt(
          (x1 - x0) * (x1 - x0) + (y1 - y0) * (y1 - y0),
        ) *
            0.7 +
        1.0;
    final sy = math.sin(j.yaw), cyw = math.cos(j.yaw);
    final sp = math.sin(j.pitch), cp = math.cos(j.pitch);
    // forward = depth gradient of cam3Depth: (sy*cp, cy*cp, -sp)
    fx = sy * cp;
    fy = cyw * cp;
    fz = -sp;
    rx = cyw;
    ry = -sy;
    ux = sy * sp;
    uy = cyw * sp;
    uz = cp;
    tanF = math.tan(j.fovDeg * math.pi / 360.0);
    // Fit like the editor's _fit3: eye distance so all 8 bounds
    // corners project inside ~85% of the frame at this yaw/pitch.
    // For a corner p: ndc_u = u / ((dist + w) * tanF * aspect),
    // so dist >= |u| / (tanF * aspect * fill) - w; take the max.
    final aspect0 = j.width / j.height;
    var dist = 0.6;
    for (final px in [x0, x1]) {
      for (final py in [y0, y1]) {
        for (final pz in [z0, z1]) {
          final ox = px - cx, oy = py - cy, oz = pz - cz;
          final u = ox * rx + oy * ry;
          final v = ox * ux + oy * uy + oz * uz;
          final w = ox * fx + oy * fy + oz * fz;
          final tU = u.abs() / (tanF * aspect0 * 0.85) - w;
          final tV = v.abs() / (tanF * 0.85) - w;
          if (tU > dist) dist = tU;
          if (tV > dist) dist = tV;
        }
      }
    }
    dist *= j.distMul;
    ex = cx - fx * dist;
    ey = cy - fy * dist;
    ez = cz - fz * dist;
    // perp basis of the sun for soft-shadow jitter
    su0 = -_sunDir[1];
    sv0 = _sunDir[0];
    sw0 = 0.0;
    final l0 = math.sqrt(su0 * su0 + sv0 * sv0);
    su0 /= l0;
    sv0 /= l0;
    su1 = _sunDir[1] * sw0 - _sunDir[2] * sv0;
    sv1 = _sunDir[2] * su0 - _sunDir[0] * sw0;
    sw1 = _sunDir[0] * sv0 - _sunDir[1] * su0;
    // ground albedo: procedural constant, or the env's real lower
    // hemisphere so the floor reads as grass/pavement/studio floor
    if (env != null) {
      final meanL = math.max(env!.meanLum(), 0.05);
      // sqrt normalization: half-way between raw and flat-normalized,
      // so a sunset still reads darker than noon - just watchable
      _expo = math.sqrt(0.8 / meanL).clamp(0.4, 4.5);
      _amb = _expo * 0.7;
      // firefly clamp: HDR sun pixels (~40k radiance) must not leak
      // into lighting paths or they render as white speckles; direct
      // sky views keep the raw range. 8x mean keeps one clamped ray
      // near the ambient average instead of a random bright dot
      _clamp = meanL * 8;
      // the env's own ground floor gets extra lift (absolute ground
      // radiance is naturally ~4x dimmer than the sky)
      _gExpo = _expo * 2.0;
      env!.avgDown(_lt);
      final gs = 0.55 / meanL;
      _gR = (_lt[0] * gs).clamp(0.02, 0.9);
      _gG = (_lt[1] * gs).clamp(0.02, 0.9);
      _gB = (_lt[2] * gs).clamp(0.02, 0.9);
      // horizon fade color = the env seen at eye level
      env!.sample(0, 1, 0, _lt);
      _hR = _lt[0] * _expo;
      _hG = _lt[1] * _expo;
      _hB = _lt[2] * _expo;
    } else {
      _expo = _amb = _gExpo = 0;
      _clamp = 1e30;
      // solid backdrop overrides the procedural ground + horizon;
      // channel helper turns ARGB into sRGB 0..1 triples
      double ch(int argb, int s) => ((argb >> s) & 0xFF) / 255.0;
      if (bgGround != null) {
        _gR = math.pow(ch(bgGround!, 16), 2.2).toDouble();
        _gG = math.pow(ch(bgGround!, 8), 2.2).toDouble();
        _gB = math.pow(ch(bgGround!, 0), 2.2).toDouble();
      } else {
        _gR = math.pow(_gndAlb[0], 2.2).toDouble();
        _gG = math.pow(_gndAlb[1], 2.2).toDouble();
        _gB = math.pow(_gndAlb[2], 2.2).toDouble();
      }
      if (bgBottom != null) {
        _hR = ch(bgBottom!, 16);
        _hG = ch(bgBottom!, 8);
        _hB = ch(bgBottom!, 0);
      } else {
        _hR = _skyHor[0];
        _hG = _skyHor[1];
        _hB = _skyHor[2];
      }
      if (bgTop != null) {
        _bgT0 = ch(bgTop!, 16);
        _bgT1 = ch(bgTop!, 8);
        _bgT2 = ch(bgTop!, 0);
      }
    }
  }

  final Float64List vpos;
  final Int32List tris, colors;
  final double groundZ;
  final RenderQuality quality;
  final EnvMap? env;
  final int? bgTop;
  final int? bgBottom;
  final int? bgGround;
  final bool interiorGlow;
  final _Bvh bvh;

  // interior point light (bounds center, 60% height): warm glow that
  // makes windows light up like evening architectural shots
  late double _gx, _gy, _gz, _gRad;
  static const _gI = [1.9, 1.15, 0.55]; // warm lamp color

  // env exposure is AUTO-normalized per map in the ctor (HDRIs are
  // unclipped absolute radiance - a fixed factor renders dim maps
  // muddy); _expo scales direct env views, _amb the ambient term,
  // _gExpo the env ground floor, _clamp firefly-limits lighting rays
  late double _expo, _amb, _gExpo, _clamp;
  // ground-plane tint (linear), from _gndAlb or the env lower hemi;
  // _h* = horizon color the ground fades into at distance
  late double _gR, _gG, _gB;
  late double _hR, _hG, _hB;
  // solid backdrop zenith (sRGB); null = procedural sky gradient
  double? _bgT0, _bgT1, _bgT2;

  // camera
  late double ex, ey, ez;
  late double fx, fy, fz;
  late double rx, ry;
  late double ux, uy, uz;
  late double tanF;
  // sun-perpendicular disk basis
  late double su0, sv0, sw0, su1, sv1, sw1;

  // last-hit scratch (kept on the object - no per-call allocs)
  double ht = 0, hu = 0, hv = 0;
  int htri = -1;
  final _stack = Int32List(96);
  final _lt = Float64List(3);
  final _lt2 = Float64List(3);

  int get _aoRays => quality == RenderQuality.draft
      ? 0
      : quality == RenderQuality.standard
      ? 6
      : 8;
  int get _shadowRays => quality == RenderQuality.draft
      ? 1
      : quality == RenderQuality.standard
      ? 4
      : 6;
  int get _spp => quality == RenderQuality.draft
      ? 1
      : quality == RenderQuality.standard
      ? 2
      : 4;
  bool get _bounce => quality == RenderQuality.finalQuality;

  static const _softRad = 0.03; // soft-shadow cone half-angle (rad)
  static const _aoRadius = 1.0; // AO reach in meters

  /// BVH traversal shared by primary and occlusion rays. With
  /// [any]=false it tracks the NEAREST hit and fills ht/htri/hu/hv;
  /// with any=true it early-outs on the first contact (shadow/AO rays).
  /// Triangles only - the infinite ground plane never occludes.
  bool _nearest(
    double ox,
    double oy,
    double oz,
    double dx,
    double dy,
    double dz,
    double maxT, {
    bool any = false,
  }) {
    final ix = 1.0 / dx, iy = 1.0 / dy, iz = 1.0 / dz;
    var best = maxT;
    var tri = -1;
    var bu = 0.0, bv = 0.0;
    var sp = 0;
    _stack[sp++] = 0;
    final box = bvh.box, left = bvh.nLeft, right = bvh.nRight;
    final start = bvh.nStart, count = bvh.nCount, order = bvh.order;
    final vp = vpos, ti = tris;
    while (sp > 0) {
      final ni = _stack[--sp];
      final b = ni * 6;
      // slab test
      var t0 = (box[b] - ox) * ix, t1 = (box[b + 3] - ox) * ix;
      var tmin = math.min(t0, t1), tmax = math.max(t0, t1);
      t0 = (box[b + 1] - oy) * iy;
      t1 = (box[b + 4] - oy) * iy;
      tmin = math.max(tmin, math.min(t0, t1));
      tmax = math.min(tmax, math.max(t0, t1));
      t0 = (box[b + 2] - oz) * iz;
      t1 = (box[b + 5] - oz) * iz;
      tmin = math.max(tmin, math.min(t0, t1));
      tmax = math.min(tmax, math.max(t0, t1));
      if (tmax < math.max(tmin, 0.0) || tmin > best) continue;
      final cnt = count[ni];
      if (cnt > 0) {
        final s0 = start[ni];
        for (var i = s0; i < s0 + cnt; i++) {
          final t = order[i] * 3;
          final a = ti[t] * 3, bb = ti[t + 1] * 3, c = ti[t + 2] * 3;
          final ax = vp[a], ay = vp[a + 1], az = vp[a + 2];
          final e1x = vp[bb] - ax, e1y = vp[bb + 1] - ay, e1z = vp[bb + 2] - az;
          final e2x = vp[c] - ax, e2y = vp[c + 1] - ay, e2z = vp[c + 2] - az;
          // Moller-Trumbore, two-sided (meshes are single-sided polys)
          final px = dy * e2z - dz * e2y;
          final py = dz * e2x - dx * e2z;
          final pz = dx * e2y - dy * e2x;
          final det = e1x * px + e1y * py + e1z * pz;
          if (det > -1e-12 && det < 1e-12) continue;
          final inv = 1.0 / det;
          final tx = ox - ax, ty = oy - ay, tz = oz - az;
          final u = (tx * px + ty * py + tz * pz) * inv;
          if (u < 0 || u > 1) continue;
          final qx = ty * e1z - tz * e1y;
          final qy = tz * e1x - tx * e1z;
          final qz = tx * e1y - ty * e1x;
          final v = (dx * qx + dy * qy + dz * qz) * inv;
          if (v < 0 || u + v > 1) continue;
          final tt = (e2x * qx + e2y * qy + e2z * qz) * inv;
          if (tt > 1e-6 && tt < best) {
            if (any) return true;
            best = tt;
            tri = order[i];
            bu = u;
            bv = v;
          }
        }
      } else {
        _stack[sp++] = left[ni];
        _stack[sp++] = right[ni];
      }
    }
    if (tri < 0) return false;
    ht = best;
    htri = tri;
    hu = bu;
    hv = bv;
    return true;
  }

  /// Any-hit occlusion test for AO rays - wrapper over [_nearest].
  bool _occluded(
    double ox,
    double oy,
    double oz,
    double dx,
    double dy,
    double dz,
    double maxT,
  ) =>
      _nearest(ox, oy, oz, dx, dy, dz, maxT, any: true);

  /// Sun visibility 0..1 from a surface point - opaque blockers zero
  /// it, glass attenuates by its alpha (walks through up to 8 panes).
  double _sunVis(double px, double py, double pz, _Rng rng) {
    final rays = _shadowRays;
    if (rays <= 1) {
      // hard shadow: ONE jitter-free ray along the sun
      return _sunTrans(px, py, pz, _sunDir[0], _sunDir[1], _sunDir[2]);
    }
    var vis = 0.0;
    for (var i = 0; i < rays; i++) {
      final a = rng.next() * math.pi * 2;
      final r = math.sqrt(rng.next()) * _softRad;
      final jx = math.cos(a) * r, jy = math.sin(a) * r;
      var dx = _sunDir[0] + jx * su0 + jy * su1;
      var dy = _sunDir[1] + jx * sv0 + jy * sv1;
      var dz = _sunDir[2] + jx * sw0 + jy * sw1;
      final l = math.sqrt(dx * dx + dy * dy + dz * dz);
      dx /= l;
      dy /= l;
      dz /= l;
      vis += _sunTrans(px, py, pz, dx, dy, dz);
    }
    return vis / rays;
  }

  /// Transmittance along ONE sun ray - 0 on opaque contact, alpha
  /// product through glass panes.
  double _sunTrans(
    double px,
    double py,
    double pz,
    double dx,
    double dy,
    double dz,
  ) {
    var ox = px + dx * 2e-4, oy = py + dy * 2e-4, oz = pz + dz * 2e-4;
    var vis = 1.0;
    for (var k = 0; k < 8; k++) {
      if (!_nearest(ox, oy, oz, dx, dy, dz, 1e9)) return vis;
      final a = (colors[htri] >> 24) & 0xFF;
      if (a >= 255) return 0.0;
      vis *= a / 255.0;
      ox += dx * (ht + 2e-4);
      oy += dy * (ht + 2e-4);
      oz += dz * (ht + 2e-4);
    }
    return vis;
  }

  /// Cosine-weighted hemisphere occlusion around [nx,ny,nz]:
  /// fraction of K short rays (radius 1m) that strike geometry.
  double _ao(
    double px,
    double py,
    double pz,
    double nx,
    double ny,
    double nz,
    _Rng rng,
  ) {
    final k = _aoRays;
    if (k <= 0) return 0.0;
    // tangent basis
    double tx, ty, tz;
    if (nz.abs() < 0.9) {
      tx = ny;
      ty = -nx;
      tz = 0.0;
    } else {
      tx = 0.0;
      ty = nz;
      tz = -ny;
    }
    var tl = math.sqrt(tx * tx + ty * ty + tz * tz);
    if (tl < 1e-9) {
      tx = 1;
      ty = 0;
      tz = 0;
      tl = 1;
    }
    tx /= tl;
    ty /= tl;
    tz /= tl;
    final bx = ny * tz - nz * ty;
    final by = nz * tx - nx * tz;
    final bz = nx * ty - ny * tx;
    var occ = 0;
    for (var i = 0; i < k; i++) {
      final r = math.sqrt(rng.next());
      final a = rng.next() * math.pi * 2;
      final lx = r * math.cos(a), ly = r * math.sin(a);
      final lz = math.sqrt(math.max(0.0, 1.0 - r * r));
      final dx = lx * tx + ly * bx + lz * nx;
      final dy = lx * ty + ly * by + lz * ny;
      final dz = lx * tz + ly * bz + lz * nz;
      if (_occluded(
        px + dx * 2e-4,
        py + dy * 2e-4,
        pz + dz * 2e-4,
        dx,
        dy,
        dz,
        _aoRadius,
      )) {
        occ++;
      }
    }
    return occ / k;
  }

  /// Image-based ambient for an env-lit scene: cosine hemisphere rays
  /// around the normal; each UNoccluded ray contributes the HDRI
  /// radiance it sees (occluded dirs add 0), so corners darken and
  /// surfaces pick up sky/forest/sunset colors for free. Requires
  /// _aoRays > 0; result written to out[0..2].
  void _envAmbient(
    double px,
    double py,
    double pz,
    double nx,
    double ny,
    double nz,
    _Rng rng,
    Float64List out,
  ) {
    final k = _aoRays;
    double tx, ty, tz;
    if (nz.abs() < 0.9) {
      tx = ny;
      ty = -nx;
      tz = 0.0;
    } else {
      tx = 0.0;
      ty = nz;
      tz = -ny;
    }
    var tl = math.sqrt(tx * tx + ty * ty + tz * tz);
    if (tl < 1e-9) {
      tx = 1;
      ty = 0;
      tz = 0;
      tl = 1;
    }
    tx /= tl;
    ty /= tl;
    tz /= tl;
    final bx = ny * tz - nz * ty;
    final by = nz * tx - nx * tz;
    final bz = nx * ty - ny * tx;
    var r = 0.0, g = 0.0, b = 0.0;
    for (var i = 0; i < k; i++) {
      final rr = math.sqrt(rng.next());
      final a = rng.next() * math.pi * 2;
      final lx = rr * math.cos(a), ly = rr * math.sin(a);
      final lz = math.sqrt(math.max(0.0, 1.0 - rr * rr));
      final dx = lx * tx + ly * bx + lz * nx;
      final dy = lx * ty + ly * by + lz * ny;
      final dz = lx * tz + ly * bz + lz * nz;
      if (_occluded(
        px + dx * 2e-4,
        py + dy * 2e-4,
        pz + dz * 2e-4,
        dx,
        dy,
        dz,
        _aoRadius,
      )) {
        continue;
      }
      env!.sample(dx, dy, dz, _lt2);
      // firefly clamp - the sun pixel must not blast ambient rays
      r += math.min(_lt2[0], _clamp);
      g += math.min(_lt2[1], _clamp);
      b += math.min(_lt2[2], _clamp);
    }
    out[0] = r * _amb / k;
    out[1] = g * _amb / k;
    out[2] = b * _amb / k;
  }

  /// Ambient hemisphere light at a normal - sky for up-facing, warm
  /// bounce for down-facing, neutral side band for walls.
  void _ambient(double nz, Float64List out) {
    final up = math.max(0.0, nz), dn = math.max(0.0, -nz);
    final side = 1.0 - up - dn;
    out[0] = _ambSky[0] * 0.45 * up +
        _ambGnd[0] * 0.30 * dn +
        _ambSide[0] * 0.35 * side;
    out[1] = _ambSky[1] * 0.45 * up +
        _ambGnd[1] * 0.30 * dn +
        _ambSide[1] * 0.35 * side;
    out[2] = _ambSky[2] * 0.45 * up +
        _ambGnd[2] * 0.30 * dn +
        _ambSide[2] * 0.35 * side;
  }

  /// Full lighting at a surface point: ambient x AO + sun x shadow.
  /// Returns into _lt: [ar,ag,ab] ambient and [sr,sg,sb] sun terms
  /// packed as ar,ag,ab,sr,sg,sb in a scratch passed by the caller.
  void _light(
    double px,
    double py,
    double pz,
    double nx,
    double ny,
    double nz,
    _Rng rng,
    Float64List out,
  ) {
    if (env != null && _aoRays > 0) {
      // HDRI lighting: unoccluded hemisphere rays carry env radiance
      _envAmbient(px, py, pz, nx, ny, nz, rng, out);
    } else {
      _ambient(nz, out);
      if (_aoRays > 0) {
        final f = 1.0 - _ao(px, py, pz, nx, ny, nz, rng);
        out[0] *= f;
        out[1] *= f;
        out[2] *= f;
      }
      if (env != null) {
        // draft: no AO rays - still tint ambient by the env so the
        // scene picks up the sky/ground colors cheaply
        env!.sample(nx, ny, nz, _lt2);
        out[0] = math.min(_lt2[0], _clamp) * _amb;
        out[1] = math.min(_lt2[1], _clamp) * _amb;
        out[2] = math.min(_lt2[2], _clamp) * _amb;
      }
    }
    final ndl = math.max(
      0.0,
      nx * _sunDir[0] + ny * _sunDir[1] + nz * _sunDir[2],
    );
    var vis = 0.0;
    if (ndl > 0) {
      vis = _sunVis(px, py, pz, rng) * ndl;
    }
    out[3] = _sunI[0] * vis;
    out[4] = _sunI[1] * vis;
    out[5] = _sunI[2] * vis;
    if (interiorGlow) {
      // warm point light inside the model; occluded by walls (an
      // any-hit ray to the lamp) so only openings/glass leak it
      final lx = _gx - px, ly = _gy - py, lz = _gz - pz;
      final r = math.sqrt(lx * lx + ly * ly + lz * lz);
      if (r < _gRad && r > 1e-6) {
        final dot = (nx * lx + ny * ly + nz * lz) / r;
        if (dot > 0 &&
            !_occluded(
              px + lx * 2e-4 / r,
              py + ly * 2e-4 / r,
              pz + lz * 2e-4 / r,
              lx / r,
              ly / r,
              lz / r,
              r - 2e-4,
            )) {
          final att = 1.0 - r / _gRad;
          final e = att * att * dot;
          out[3] += _gI[0] * e;
          out[4] += _gI[1] * e;
          out[5] += _gI[2] * e;
        }
      }
    }
  }

  /// Sky for a miss ray: the HDRI env when present (real photo sky +
  /// horizon), else the procedural zenith -> horizon gradient with a
  /// sun disk glow.
  void _sky(double dx, double dy, double dz, Float64List out) {
    if (env != null) {
      env!.sample(dx, dy, dz, out);
      out[0] *= _expo;
      out[1] *= _expo;
      out[2] *= _expo;
      return;
    }
    double r, g, b;
    if (_bgT0 != null) {
      // solid studio backdrop: zenith -> horizon gradient, no sun
      // disk (a visible glow blob ruins a clean white/black sweep)
      final k = math
          .pow((1.0 - (dz * 0.5 + 0.5)).clamp(0.0, 1.0), 1.3)
          .toDouble();
      out[0] = _bgT0! * (1 - k) + _hR * k;
      out[1] = _bgT1! * (1 - k) + _hG * k;
      out[2] = _bgT2! * (1 - k) + _hB * k;
      // Reinhard+gamma crushes a white sweep to ~190 gray - push
      // bright backdrops into the shoulder so white reads ~220
      if (0.299 * out[0] + 0.587 * out[1] + 0.114 * out[2] > 0.5) {
        out[0] *= 3.0;
        out[1] *= 3.0;
        out[2] *= 3.0;
      }
      return;
    }
    if (dz >= 0) {
      final k = math.pow(1.0 - dz, 1.6).toDouble();
      r = _skyZen[0] * (1 - k) + _skyHor[0] * k;
      g = _skyZen[1] * (1 - k) + _skyHor[1] * k;
      b = _skyZen[2] * (1 - k) + _skyHor[2] * k;
    } else {
      final k = math.min(1.0, -dz * 5.0);
      r = _skyHor[0] * (1 - k) + 0.72 * k;
      g = _skyHor[1] * (1 - k) + 0.66 * k;
      b = _skyHor[2] * (1 - k) + 0.55 * k;
    }
    final sd = math.max(0.0, dx * _sunDir[0] + dy * _sunDir[1] + dz * _sunDir[2]);
    final halo = math.pow(sd, 24).toDouble() * 0.18;
    final disk = math.pow(sd, 700).toDouble() * 4.0;
    out[0] = r + halo * 0.35 + disk;
    out[1] = g + halo * 0.30 + disk * 0.9;
    out[2] = b + halo * 0.22 + disk * 0.7;
  }

  /// Cheap secondary shading for the FINAL diffuse bounce: albedo
  /// under ambient + one hard sun ray - no AO, no recursion.
  void _bounceColor(
    double ox,
    double oy,
    double oz,
    double dx,
    double dy,
    double dz,
    Float64List out,
  ) {
    // ground plane counts here - it is a real radiance source
    final gt = dz < -1e-9 ? (groundZ - oz) / dz : -1.0;
    final hit = _nearest(ox, oy, oz, dx, dy, dz, 1e9);
    if (!hit || (gt > 1e-6 && gt < ht)) {
      if (gt > 1e-6) {
        // ground bounce: warm, dimmed like the hemisphere term
        out[0] = _gndAlb[0] * 0.4;
        out[1] = _gndAlb[1] * 0.4;
        out[2] = _gndAlb[2] * 0.4;
        return;
      }
      _sky(dx, dy, dz, out);
      return;
    }
    final tri = htri;
    final t = tri * 3;
    final a = tris[t] * 3, bb = tris[t + 1] * 3, c = tris[t + 2] * 3;
    final e1x = vpos[bb] - vpos[a], e1y = vpos[bb + 1] - vpos[a + 1],
        e1z = vpos[bb + 2] - vpos[a + 2];
    final e2x = vpos[c] - vpos[a], e2y = vpos[c + 1] - vpos[a + 1],
        e2z = vpos[c + 2] - vpos[a + 2];
    var nx = e1y * e2z - e1z * e2y;
    var ny = e1z * e2x - e1x * e2z;
    var nz = e1x * e2y - e1y * e2x;
    final nl = math.sqrt(nx * nx + ny * ny + nz * nz);
    if (nl < 1e-12) {
      out[0] = out[1] = out[2] = 0;
      return;
    }
    nx /= nl;
    ny /= nl;
    nz /= nl;
    if (nx * dx + ny * dy + nz * dz > 0) {
      nx = -nx;
      ny = -ny;
      nz = -nz;
    }
    final argb = colors[tri];
    _ambient(nz, _lt);
    final ndl = math.max(
      0.0,
      nx * _sunDir[0] + ny * _sunDir[1] + nz * _sunDir[2],
    );
    var vis = 0.0;
    if (ndl > 0) {
      final px2 = ox + dx * ht, py2 = oy + dy * ht, pz2 = oz + dz * ht;
      vis = _sunTrans(px2, py2, pz2, _sunDir[0], _sunDir[1], _sunDir[2]) * ndl;
    }
    const srgb = 1.0 / 255.0;
    final lr = math.pow(((argb >> 16) & 0xFF) * srgb, 2.2).toDouble();
    final lg = math.pow(((argb >> 8) & 0xFF) * srgb, 2.2).toDouble();
    final lb = math.pow((argb & 0xFF) * srgb, 2.2).toDouble();
    out[0] = lr * (_lt[0] + _sunI[0] * vis);
    out[1] = lg * (_lt[1] + _sunI[1] * vis);
    out[2] = lb * (_lt[2] + _sunI[2] * vis);
  }

  /// Full trace for one ray: opaque shading, glass transmit/reflect
  /// walk, sky or ground on miss. Result written to [out] (linear).
  void _trace(
    double ox,
    double oy,
    double oz,
    double dx,
    double dy,
    double dz,
    _Rng rng,
    Float64List out,
  ) {
    var w = 1.0;
    var ar = 0.0, ag = 0.0, ab = 0.0;
    var cx = ox, cy = oy, cz = oz;
    var dxv = dx, dyv = dy, dzv = dz;
    final lt = Float64List(6);
    final sb = Float64List(3);
    for (var pass = 0; pass < 6 && w > 0.02; pass++) {
      final gt = dzv < -1e-9 ? (groundZ - cz) / dzv : -1.0;
      final hit = _nearest(cx, cy, cz, dxv, dyv, dzv, 1e9);
      final ground = !hit || (gt > 1e-6 && gt < ht);
      if (ground) {
        if (gt <= 1e-6) {
          _sky(dxv, dyv, dzv, sb);
          ar += w * sb[0];
          ag += w * sb[1];
          ab += w * sb[2];
          break;
        }
        // infinite ground plane - shade it like an opaque +z face,
        // then fade to horizon haze with distance
        final px = cx + dxv * gt, py = cy + dyv * gt, pz = groundZ;
        double rr, gg, bb;
        if (env != null) {
          // HDRI floor: the env's own lower hemisphere along the ray
          // direction (nadir = ground under the model, near-horizon =
          // distant field), darkened by the model's sun shadow + a
          // little AO so the building still grounds itself. Clamped:
          // the sun pixel would speckle the grass with fireflies
          env!.sample(dxv, dyv, dzv, sb);
          final vis = _sunVis(px, py, pz, rng);
          final occ = _aoRays > 0
              ? _ao(px, py, pz, 0, 0, 1, rng)
              : 0.0;
          final shade = (0.5 + 0.5 * vis) * (1.0 - 0.45 * occ);
          rr = math.min(sb[0], _clamp) * _gExpo * shade;
          gg = math.min(sb[1], _clamp) * _gExpo * shade;
          bb = math.min(sb[2], _clamp) * _gExpo * shade;
        } else {
          _light(px, py, pz, 0, 0, 1, rng, lt);
          // _gR/_gG/_gB are already linear (_gndAlb^2.2)
          rr = _gR * (lt[0] + lt[3]);
          gg = _gG * (lt[1] + lt[4]);
          bb = _gB * (lt[2] + lt[5]);
        }
        // env mode fades slower - the HDRI already has a real horizon
        final fade =
            1.0 - math.exp(-gt * (env != null ? 0.006 : 0.015));
        rr = rr * (1 - fade) + _hR * fade;
        gg = gg * (1 - fade) + _hG * fade;
        bb = bb * (1 - fade) + _hB * fade;
        ar += w * rr;
        ag += w * gg;
        ab += w * bb;
        break;
      }
      final tri = htri;
      final argb = colors[tri];
      final alpha = ((argb >> 24) & 0xFF) / 255.0;
      final px = cx + dxv * ht, py = cy + dyv * ht, pz = cz + dzv * ht;
      // geometric normal, flipped to face the incoming ray
      final t = tri * 3;
      final a = tris[t] * 3, bb = tris[t + 1] * 3, c = tris[t + 2] * 3;
      final e1x = vpos[bb] - vpos[a], e1y = vpos[bb + 1] - vpos[a + 1],
          e1z = vpos[bb + 2] - vpos[a + 2];
      final e2x = vpos[c] - vpos[a], e2y = vpos[c + 1] - vpos[a + 1],
          e2z = vpos[c + 2] - vpos[a + 2];
      var nx = e1y * e2z - e1z * e2y;
      var ny = e1z * e2x - e1x * e2z;
      var nz = e1x * e2y - e1y * e2x;
      final nl = math.sqrt(nx * nx + ny * ny + nz * nz);
      if (nl < 1e-12) {
        break;
      }
      nx /= nl;
      ny /= nl;
      nz /= nl;
      if (nx * dxv + ny * dyv + nz * dzv > 0) {
        nx = -nx;
        ny = -ny;
        nz = -nz;
      }
      const srgb = 1.0 / 255.0;
      final lr = math.pow(((argb >> 16) & 0xFF) * srgb, 2.2).toDouble();
      final lg = math.pow(((argb >> 8) & 0xFF) * srgb, 2.2).toDouble();
      final lb = math.pow((argb & 0xFF) * srgb, 2.2).toDouble();
      _light(px, py, pz, nx, ny, nz, rng, lt);
      if (alpha < 0.999) {
        // glass: own tint at alpha weight, a Fresnel-ish sky reflect,
        // then continue the ray through at reduced weight
        ar += w * lr * alpha * (lt[0] + lt[3]);
        ag += w * lg * alpha * (lt[1] + lt[4]);
        ab += w * lb * alpha * (lt[2] + lt[5]);
        final dot = dxv * nx + dyv * ny + dzv * nz;
        final rxv = dxv - 2 * dot * nx;
        final ryv = dyv - 2 * dot * ny;
        final rzv = dzv - 2 * dot * nz;
        _sky(rxv, ryv, rzv, sb);
        ar += w * 0.15 * sb[0];
        ag += w * 0.15 * sb[1];
        ab += w * 0.15 * sb[2];
        w *= 1.0 - alpha * 0.6;
        cx = px + dxv * 2e-4;
        cy = py + dyv * 2e-4;
        cz = pz + dzv * 2e-4;
        continue;
      }
      // opaque: albedo * light + Blinn specular
      final diff = 1.0;
      ar += w * lr * (lt[0] + lt[3] * diff);
      ag += w * lg * (lt[1] + lt[4] * diff);
      ab += w * lb * (lt[2] + lt[5] * diff);
      // Blinn halfway vector between sun and view
      var hx = _sunDir[0] - dxv, hy = _sunDir[1] - dyv, hz = _sunDir[2] - dzv;
      final hl = math.sqrt(hx * hx + hy * hy + hz * hz);
      if (hl > 1e-9) {
        hx /= hl;
        hy /= hl;
        hz /= hl;
        final ndh = math.max(0.0, nx * hx + ny * hy + nz * hz);
        final vis = lt[3] + lt[4] + lt[5];
        final spec = math.pow(ndh, 32).toDouble() * 0.08 * vis / 3;
        ar += w * spec;
        ag += w * spec;
        ab += w * spec;
      }
      // FINAL: one diffuse bounce at 0.15 weight (color bleed)
      if (_bounce) {
        final t2 = rng.next() * math.pi * 2;
        final r2 = math.sqrt(rng.next());
        // hemisphere basis around n
        double tx, ty, tz;
        if (nz.abs() < 0.9) {
          tx = ny;
          ty = -nx;
          tz = 0.0;
        } else {
          tx = 0.0;
          ty = nz;
          tz = -ny;
        }
        var tl = math.sqrt(tx * tx + ty * ty + tz * tz);
        if (tl < 1e-9) {
          tx = 1;
          ty = 0;
          tz = 0;
          tl = 1;
        }
        tx /= tl;
        ty /= tl;
        tz /= tl;
        final bxx = ny * tz - nz * ty;
        final byy = nz * tx - nx * tz;
        final bzz = nx * ty - ny * tx;
        final lx = r2 * math.cos(t2), ly = r2 * math.sin(t2);
        final lz = math.sqrt(math.max(0.0, 1.0 - r2 * r2));
        final bdx = lx * tx + ly * bxx + lz * nx;
        final bdy = lx * ty + ly * byy + lz * ny;
        final bdz = lx * tz + ly * bzz + lz * nz;
        _bounceColor(
          px + nx * 2e-4,
          py + ny * 2e-4,
          pz + nz * 2e-4,
          bdx,
          bdy,
          bdz,
          sb,
        );
        ar += w * 0.15 * lr * sb[0];
        ag += w * 0.15 * lg * sb[1];
        ab += w * 0.15 * lb * sb[2];
      }
      break;
    }
    out[0] = ar;
    out[1] = ag;
    out[2] = ab;
  }
}

/// Renders [job] into PNG bytes. Yields to the event loop every ~16
/// rows so progress, cancellation and the UI stay live in the SAME
/// isolate. Returns empty bytes when [isCancelled] fires.
Future<Uint8List> renderPng(
  RenderJob job, {
  void Function(double progress)? onProgress,
  bool Function()? isCancelled,
}) async {
  final scale = job.quality == RenderQuality.draft ? 0.6 : 1.0;
  final w = math.max(8, (job.width * scale).round());
  final h = math.max(8, (job.height * scale).round());
  final tr = _Tracer(job);
  final aspect = w / h;
  final px = Uint8List(w * h * 3);
  final rgb = Float64List(3);
  final acc = Float64List(3);
  final spp = tr._spp;
  const offs = [
    [0.5, 0.5],
    [0.25, 0.75],
    [0.75, 0.25],
    [0.25, 0.25],
    [0.75, 0.75],
  ];
  const gamma = 1.0 / 2.2;
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      acc[0] = acc[1] = acc[2] = 0;
      for (var s = 0; s < spp; s++) {
        final o = offs[s];
        final rng = _Rng(
          (x * 1973 + y * 9277 + s * 26699 + 7919) & 0x7FFFFFFF,
        );
        final ndcX = ((x + o[0]) / w * 2 - 1) * tr.tanF * aspect;
        final ndcY = (1 - (y + o[1]) / h * 2) * tr.tanF;
        var dx = tr.fx + ndcX * tr.rx + ndcY * tr.ux;
        var dy = tr.fy + ndcX * tr.ry + ndcY * tr.uy;
        var dz = tr.fz + ndcY * tr.uz;
        final l = math.sqrt(dx * dx + dy * dy + dz * dz);
        dx /= l;
        dy /= l;
        dz /= l;
        tr._trace(tr.ex, tr.ey, tr.ez, dx, dy, dz, rng, rgb);
        acc[0] += rgb[0];
        acc[1] += rgb[1];
        acc[2] += rgb[2];
      }
      final i = (y * w + x) * 3;
      // Reinhard + gamma
      var r = acc[0] / spp, g = acc[1] / spp, b = acc[2] / spp;
      px[i] = (math.pow(r / (1 + r), gamma) * 255).clamp(0, 255).round();
      px[i + 1] = (math.pow(g / (1 + g), gamma) * 255)
          .clamp(0, 255)
          .round();
      px[i + 2] = (math.pow(b / (1 + b), gamma) * 255)
          .clamp(0, 255)
          .round();
    }
    if (y % 16 == 15 || y == h - 1) {
      onProgress?.call((y + 1) / h);
      // yield so the UI/dialog stays responsive in the same isolate
      await Future<void>(() {});
      if (isCancelled != null && isCancelled()) return Uint8List(0);
    }
  }
  return _pngEncode(w, h, px);
}

// ---------- minimal PNG encoder (RGB8, filter 0) ----------

final _crcTable = _buildCrc();

List<int> _buildCrc() {
  final t = List<int>.filled(256, 0);
  for (var n = 0; n < 256; n++) {
    var c = n;
    for (var k = 0; k < 8; k++) {
      c = c & 1 != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
    }
    t[n] = c;
  }
  return t;
}

int _crc32(List<int> data, int start, int end) {
  var c = 0xFFFFFFFF;
  for (var i = start; i < end; i++) {
    c = _crcTable[(c ^ data[i]) & 0xFF] ^ (c >> 8);
  }
  return c ^ 0xFFFFFFFF;
}

List<int> _chunk(String type, List<int> data) {
  final out = ByteData(12 + data.length);
  out.setUint32(0, data.length);
  final bytes = out.buffer.asUint8List();
  for (var i = 0; i < 4; i++) {
    bytes[4 + i] = type.codeUnitAt(i);
  }
  bytes.setRange(8, 8 + data.length, data);
  // PNG CRC covers the 4 type bytes + data, not the length field
  out.setUint32(8 + data.length, _crc32(bytes, 4, 8 + data.length));
  return bytes;
}

Uint8List _pngEncode(int w, int h, Uint8List rgb) {
  // scanlines each prefixed by filter byte 0
  final raw = Uint8List(h * (1 + w * 3));
  for (var y = 0; y < h; y++) {
    raw.setRange(y * (1 + w * 3) + 1, (y + 1) * (1 + w * 3), rgb, y * w * 3);
  }
  final comp = ZLibCodec(level: 5).encode(raw);
  final ihdr = ByteData(13);
  ihdr.setUint32(0, w);
  ihdr.setUint32(4, h);
  ihdr.setUint8(8, 8); // bit depth
  ihdr.setUint8(9, 2); // color type RGB
  final bytes = BytesBuilder();
  bytes.add(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
  bytes.add(_chunk('IHDR', ihdr.buffer.asUint8List()));
  bytes.add(_chunk('IDAT', comp));
  bytes.add(_chunk('IEND', const []));
  return bytes.toBytes();
}
