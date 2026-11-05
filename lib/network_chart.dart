import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import 'cpm.dart';
import 'models.dart';

/// PNG bytes plus pixel size.
class PngImage {
  final Uint8List bytes;
  final int w, h;
  const PngImage(this.bytes, this.w, this.h);
}

/// Text style font hook: null in the app (engine default). Tests load a
/// real TTF and set this so rendered chart/diagram text is legible.
String? kChartFontFamily;

Color _argb(int v) => Color(v | 0xFF000000);

/// Readable text color on [bg] — same rule as the Excel export.
Color fgOn(int argb) {
  final r = (argb >> 16) & 0xFF, g = (argb >> 8) & 0xFF, b = argb & 0xFF;
  return (0.299 * r + 0.587 * g + 0.114 * b) / 255 > 0.55
      ? const Color(0xFF1E293B)
      : const Color(0xFFFFFFFF);
}

/// The precedence diagram drawn like the workbook's PERT-NETWORK sheet:
/// 3x4 bordered node blocks (SLACK / letter ES EF / days LS LF / name),
/// critical nodes filled with the subtotal color and outlined in the
/// theme color, orthogonal connectors routed through lane channels.
_Pending? _paintNetwork(CpmResult r, ProjectInfo p, double scale) {
  if (r.error != null || r.nodes.isEmpty) return null;
  const rowH = 18.0, colW = 46.0, gap = 30.0, startW = 54.0, pad = 14.0;
  const boxW = colW * 3, boxH = rowH * 4, bandH = rowH * 5;
  const pitch = boxW + gap;
  final w = startW + (r.maxLevel + 1) * pitch - gap + pad * 2;
  final h = pad + rowH + r.laneCount * bandH;
  double x0(int level) => startW + level * pitch;
  double y0(int lane) => pad + rowH * 0.5 + lane * bandH;
  final theme = _argb(p.themeColor);
  final critFill = _argb(p.subtotalColor);

  final rec = ui.PictureRecorder();
  final canvas = Canvas(rec, Rect.fromLTWH(0, 0, w * scale, h * scale));
  canvas.scale(scale);
  canvas.drawRect(
    Rect.fromLTWH(0, 0, w, h),
    Paint()..color = const Color(0xFFFFFFFF),
  );

  void edgePath(CpmNode pN, CpmNode n, Paint paint) {
    final yS = y0(pN.lane) + 2 * rowH, yT = y0(n.lane) + 2 * rowH;
    final xs = x0(pN.level) + boxW, xt = x0(n.level);
    final path = Path()..moveTo(xs, yS);
    if (n.level == pN.level + 1 && n.lane == pN.lane) {
      path.lineTo(xt, yT);
    } else {
      final busS = xs + gap / 2, busT = xt - gap / 2;
      final chan = pN.lane <= n.lane
          ? y0(pN.lane) + 4.5 * rowH
          : y0(pN.lane) - 0.5 * rowH;
      path
        ..lineTo(busS, yS)
        ..lineTo(busS, chan)
        ..lineTo(busT, chan)
        ..lineTo(busT, yT)
        ..lineTo(xt, yT);
    }
    canvas.drawPath(path, paint);
    final head = Path()
      ..moveTo(xt, yT)
      ..lineTo(xt - 5, yT - 3)
      ..lineTo(xt - 5, yT + 3)
      ..close();
    canvas.drawPath(head, Paint()..color = paint.color);
  }

  Paint line(Color c, double w2) => Paint()
    ..color = c
    ..strokeWidth = w2
    ..style = PaintingStyle.stroke
    ..strokeJoin = StrokeJoin.round;
  for (final crit in [false, true]) {
    final pt = crit ? line(theme, 2.2) : line(const Color(0xFF94A3B8), 1.1);
    for (final n in r.nodes.where((n) => n.critical == crit)) {
      for (final pi in n.predIdx) {
        edgePath(r.nodes[pi], n, pt);
      }
    }
  }

  final tp = TextPainter(textDirection: ui.TextDirection.ltr);
  void text(
    String s,
    Rect cell, {
    double fs = 9,
    bool bold = false,
    bool italic = false,
    TextAlign a = TextAlign.center,
    Color color = const Color(0xFF000000),
  }) {
    tp
      ..text = TextSpan(
        text: s,
        style: TextStyle(
          fontSize: fs,
          fontFamily: kChartFontFamily,
          fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
          fontStyle: italic ? FontStyle.italic : FontStyle.normal,
          color: color,
        ),
      )
      ..textAlign = a
      ..maxLines = 1
      ..ellipsis = '…'
      ..layout(minWidth: 0, maxWidth: cell.width - 4);
    final dx = switch (a) {
      TextAlign.right => cell.right - 2 - tp.width,
      TextAlign.left => cell.left + 2,
      _ => cell.left + (cell.width - tp.width) / 2,
    };
    tp.paint(canvas, Offset(dx, cell.top + (cell.height - tp.height) / 2));
  }

  String n0(double v) =>
      v == v.roundToDouble() ? '${v.toInt()}' : v.toStringAsFixed(1);
  for (final n in r.nodes) {
    final x = x0(n.level), y = y0(n.lane);
    final box = Rect.fromLTWH(x, y, boxW, boxH);
    canvas.drawRect(
      box,
      Paint()..color = n.critical ? critFill : const Color(0xFFFFFFFF),
    );
    final grid = line(const Color(0xFF64748B), 0.7);
    for (var i = 1; i < 4; i++) {
      canvas.drawLine(
        Offset(x, y + i * rowH),
        Offset(x + boxW, y + i * rowH),
        grid,
      );
    }
    for (var i = 1; i < 3; i++) {
      canvas.drawLine(
        Offset(x + i * colW, y),
        Offset(x + i * colW, y + 3 * rowH),
        grid,
      );
    }
    canvas.drawRect(
      box,
      line(
        n.critical ? theme : const Color(0xFF334155),
        n.critical ? 1.6 : 0.9,
      ),
    );
    Rect c(int col, int row) =>
        Rect.fromLTWH(x + col * colW, y + row * rowH, colW, rowH);
    text('SLACK', c(0, 0), fs: 7, italic: true);
    text(n0(n.slack), c(2, 0), fs: 8, a: TextAlign.right);
    text(n.letter, c(0, 1), fs: 11, bold: true);
    text(n0(n.es), c(1, 1), fs: 8);
    text(n0(n.ef), c(2, 1), fs: 8);
    text(n0(n.a.days), c(0, 2), fs: 8);
    text(n0(n.ls), c(1, 2), fs: 8);
    text(n0(n.lf), c(2, 2), fs: 8);
    text(
      n.a.name,
      Rect.fromLTWH(x, y + 3 * rowH, boxW, rowH),
      fs: 7,
      italic: true,
    );
    if (n.level == 0) {
      text(
        'START',
        Rect.fromLTWH(2, y + rowH, startW - 6, rowH),
        fs: 8,
        bold: true,
        a: TextAlign.left,
      );
    }
  }
  final pic = rec.endRecording();
  return _Pending(pic, (w * scale).round(), (h * scale).round());
}

class _Pending {
  final ui.Picture pic;
  final int w, h;
  _Pending(this.pic, this.w, this.h);
}

/// Async PNG render of the network diagram (null on cycle/empty).
Future<PngImage?> renderNetworkPng(
  CpmResult r,
  ProjectInfo p, {
  double scale = 2.5,
}) async {
  final pending = _paintNetwork(r, p, scale);
  if (pending == null) return null;
  try {
    final img = await pending.pic.toImage(pending.w, pending.h);
    final bd = await img.toByteData(format: ui.ImageByteFormat.png);
    if (bd == null) return null;
    return PngImage(bd.buffer.asUint8List(), pending.w, pending.h);
  } catch (_) {
    return null;
  }
}
