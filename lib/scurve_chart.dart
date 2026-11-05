import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'cpm.dart';
import 'network_chart.dart' show kChartFontFamily;

/// Paints the planned-progress S-curve: per-bucket % as light bars,
/// the cumulative % as the accent line. Buckets are days, weeks or
/// months (the row's `tag` labels the axis). Shared by the in-app
/// chart and the PNG rendered into the exported workbook.
void paintSCurve(
  Canvas canvas,
  Size size,
  List<SCurveRow> rows, {
  required Color accent,
  required Color barColor,
}) {
  if (rows.isEmpty) return;
  const padL = 46.0, padR = 16.0, padT = 18.0, padB = 30.0;
  final plot = Rect.fromLTWH(
    padL,
    padT,
    size.width - padL - padR,
    size.height - padT - padB,
  );
  final text = TextPainter(textDirection: TextDirection.ltr);
  void label(
    String s,
    Offset o, {
    double w = 40,
    TextAlign a = TextAlign.right,
    bool bold = false,
  }) {
    text
      ..text = TextSpan(
        text: s,
        style: TextStyle(
          fontSize: 8.5,
          fontFamily: kChartFontFamily,
          fontWeight: bold ? FontWeight.w700 : FontWeight.w500,
          color: const Color(0xFF64748B),
        ),
      )
      ..textAlign = a
      ..layout(maxWidth: w)
      ..paint(canvas, o);
  }

  double xOf(double week) =>
      plot.left + (week - 0.5) / rows.length * plot.width;
  double yOf(double pct) => plot.bottom - pct.clamp(0, 1) * plot.height;

  // Y gridlines + % labels at every 10%.
  final grid = Paint()
    ..color = const Color(0xFFE6EBF2)
    ..strokeWidth = 1;
  for (var p = 0; p <= 10; p++) {
    final y = yOf(p / 10);
    canvas.drawLine(Offset(plot.left, y), Offset(plot.right, y), grid);
    label('${p * 10}%', Offset(plot.left - 44, y - 5));
  }
  // Axes.
  final axis = Paint()
    ..color = const Color(0xFF94A3B8)
    ..strokeWidth = 1.1;
  canvas.drawLine(plot.bottomLeft, plot.bottomRight, axis);
  canvas.drawLine(plot.topLeft, plot.bottomLeft, axis);

  // Weekly bars.
  final barW = math.max(2.0, plot.width / rows.length * 0.55);
  final barPaint = Paint()..color = barColor;
  for (final r in rows) {
    final x = xOf(r.week.toDouble());
    canvas.drawRect(
      Rect.fromLTRB(x - barW / 2, yOf(r.pct), x + barW / 2, plot.bottom),
      barPaint,
    );
  }

  // Cumulative curve + points + every-few week labels.
  final line = Paint()
    ..color = accent
    ..strokeWidth = 2.4
    ..style = PaintingStyle.stroke
    ..strokeJoin = StrokeJoin.round;
  final path = Path();
  for (var i = 0; i < rows.length; i++) {
    final p = Offset(xOf(rows[i].week.toDouble()), yOf(rows[i].cumPct));
    if (i == 0) {
      path.moveTo(plot.left, yOf(0));
    }
    path.lineTo(p.dx, p.dy);
    canvas.drawCircle(p, 3, Paint()..color = accent);
    // ~10 axis labels whatever the granularity (a 90-day daily curve
    // can't afford a tag per bucket).
    final every = math.max(2, (rows.length / 10).ceil());
    if (i % every == 0 || i == rows.length - 1) {
      label(
        '${rows[i].tag}${rows[i].week}',
        Offset(p.dx - 20, plot.bottom + 6),
        w: 40,
        a: TextAlign.center,
      );
    }
    if (i % math.max(1, rows.length ~/ 6) == 0 || i == rows.length - 1) {
      label(
        '${(rows[i].cumPct * 100).toStringAsFixed(0)}%',
        Offset(p.dx - 20, p.dy - 18),
        w: 40,
        a: TextAlign.center,
        bold: true,
      );
    }
  }
  canvas.drawPath(path, line);
}

/// Renders the curve to PNG bytes for the exported workbook
/// (dart:ui picture — no widget needed).
Future<Uint8List?> renderSCurvePng(
  List<SCurveRow> rows, {
  required Color accent,
  required Color barColor,
  double w = 1100,
  double h = 620,
}) async {
  if (rows.isEmpty) return null;
  try {
    final rec = ui.PictureRecorder();
    final canvas = Canvas(rec, Rect.fromLTWH(0, 0, w, h));
    canvas.drawRect(Rect.fromLTWH(0, 0, w, h), Paint()..color = Colors.white);
    paintSCurve(canvas, Size(w, h), rows, accent: accent, barColor: barColor);
    final img = await rec.endRecording().toImage(w.round(), h.round());
    final bd = await img.toByteData(format: ui.ImageByteFormat.png);
    return bd?.buffer.asUint8List();
  } catch (_) {
    return null;
  }
}
