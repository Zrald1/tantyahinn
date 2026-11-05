import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'cpm.dart';
import 'dwg.dart';
import 'dxf.dart';
import 'models.dart';
import 'network_chart.dart';
import 'scurve_chart.dart';
import 'state.dart';

part 'pdf_export_drawings.dart';

/// The whole estimate as a PDF that mirrors the Excel workbook: same
/// Arial typography, theme/section/group/subtotal/summary colors, logo
/// letterhead, boxed project block, two-row table header, signatories —
/// BOQ + POW portrait, PERT-CPM + PERT-NETWORK + S-CURVE landscape.
class _Spec {
  final String t;
  final double w, size;
  final bool bold, italic, right;
  final pw.TextAlign align;
  final PdfColor? bg, fg;
  _Spec(
    this.t,
    this.w,
    this.bold,
    this.italic,
    this.align,
    this.bg,
    this.fg,
    this.size,
    this.right,
  );
}

class PdfExport {
  final EstimateState est;
  PdfExport(this.est);

  static final _moneyFmt = NumberFormat('#,##0.00');
  static final _qtyFmt = NumberFormat('0.##');
  static final _pctFmt = NumberFormat('0.00');

  static const _black = PdfColors.black;
  late pw.Font _reg, _bold, _ital, _boldItal;
  bool _unicode = false;

  /// Base-14 fonts can't draw ₱ and dashes; TTF Arial can.
  String _t(String s) => _unicode
      ? s
      : s
            .replaceAll('₱', 'PHP ')
            .replaceAll('—', '-')
            .replaceAll('–', '-')
            .replaceAll('−', '-')
            .replaceAll('→', '->');

  String _m(double v) => _moneyFmt.format(v);
  String _q(double v) => _qtyFmt.format(v);

  PdfColor _c(int argb) => PdfColor.fromInt(argb | 0xFF000000);
  PdfColor _fg(int argb) {
    final r = (argb >> 16) & 0xFF, g = (argb >> 8) & 0xFF, b = argb & 0xFF;
    return (0.299 * r + 0.587 * g + 0.114 * b) / 255 > 0.55
        ? const PdfColor.fromInt(0xFF1E293B)
        : PdfColors.white;
  }

  void _loadFonts() {
    Uint8List? f(String n) {
      final file = File('C:/Windows/Fonts/$n');
      return file.existsSync() ? file.readAsBytesSync() : null;
    }

    final r = f('arial.ttf'), b = f('arialbd.ttf');
    final i = f('ariali.ttf'), bi = f('arialbi.ttf');
    if (r != null && b != null && i != null && bi != null) {
      pw.Font ttf(Uint8List d) => pw.Font.ttf(ByteData.sublistView(d));
      _reg = ttf(r);
      _bold = ttf(b);
      _ital = ttf(i);
      _boldItal = ttf(bi);
      _unicode = true;
    } else {
      _reg = pw.Font.helvetica();
      _bold = pw.Font.helveticaBold();
      _ital = pw.Font.helveticaOblique();
      _boldItal = pw.Font.helveticaBoldOblique();
    }
  }

  Future<Uint8List> build() async {
    est.syncSchedule();
    _loadFonts();
    final p = est.project;
    final cpm = computeCpm(est.activities);
    final scurveRows = cpm.error == null
        ? buildSCurve(
            cpm,
            horizonDays: parseDays(p.contractDuration),
            weights: [for (final n in cpm.nodes) est.activityCost(n.a)],
            unworkableDays: p.unworkableDays.toDouble(),
            bucket: est.scurveBucket,
          )
        : const <SCurveRow>[];
    final curve = await renderSCurvePng(
      scurveRows,
      accent: ui.Color(p.themeColor | 0xFF000000),
      barColor: ui.Color(p.sectionColor | 0xFF000000),
    );
    final net = await renderNetworkPng(cpm, p);
    pw.MemoryImage? logo;
    if (p.effLogo != null) {
      try {
        logo = pw.MemoryImage(base64Decode(p.effLogo!));
      } catch (_) {}
    }

    final doc = pw.Document(
      theme: pw.ThemeData.withFont(
        base: _reg,
        bold: _bold,
        italic: _ital,
        boldItalic: _boldItal,
      ),
    );
    const portrait = PdfPageFormat.letter;
    final landscape = PdfPageFormat.letter.landscape;
    const mg = pw.EdgeInsets.fromLTRB(36, 30, 36, 36);

    final boq = _boqRows(540);
    doc.addPage(
      pw.MultiPage(
        pageFormat: portrait,
        margin: mg,
        header: (c) => c.pageNumber > 1 ? boq.header() : pw.SizedBox(),
        build: (c) => [
          _letterhead(logo, 540),
          _projectBlock(540, boq: true),
          pw.SizedBox(height: 14),
          pw.Text(
            'DETAILED ESTIMATES',
            style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold),
          ),
          pw.SizedBox(height: 8),
          boq.header(),
          ...boq.rows,
          _signatoryPairs(540),
        ],
      ),
    );
    doc.addPage(
      pw.MultiPage(
        pageFormat: portrait,
        margin: mg,
        build: (c) => [
          _letterhead(logo, 540),
          _projectBlock(540, boq: false),
          pw.SizedBox(height: 12),
          pw.Text(
            'PROGRAM OF WORKS',
            style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold),
          ),
          pw.SizedBox(height: 8),
          ..._powRows(540),
          _signatoryPairs(540),
        ],
      ),
    );
    if (est.activities.isNotEmpty && cpm.error == null) {
      doc.addPage(
        pw.MultiPage(
          pageFormat: landscape,
          margin: mg,
          build: (c) => [
            _letterhead(logo, 720),
            _title(
              'Program Evaluation and Review Technique (PERT) & Critical Path Method (CPM)',
              size: 10,
            ),
            _infoRow(
              720,
              'CALENDAR DAYS${p.unworkableDays > 0 ? ' (incl. ${p.unworkableDays} unworkable)' : ''}',
            ),
            pw.SizedBox(height: 8),
            ..._pertRows(cpm, 720),
            pw.SizedBox(height: 18),
            _signatoryRow(720),
          ],
        ),
      );
      if (net != null) {
        doc.addPage(
          pw.Page(
            pageFormat: landscape,
            margin: mg,
            build: (c) => pw.Column(
              children: [
                _letterhead(logo, 720),
                _title('NETWORK DIAGRAM — PERT/CPM', size: 11),
                _infoRow(
                  720,
                  'CALENDAR DAYS${p.unworkableDays > 0 ? ' (incl. ${p.unworkableDays} unworkable)' : ''}',
                ),
                pw.SizedBox(height: 6),
                pw.Expanded(
                  child: pw.Center(
                    child: pw.FittedBox(
                      fit: pw.BoxFit.scaleDown,
                      child: pw.Image(
                        pw.MemoryImage(net.bytes),
                        width: net.w / 2.5,
                        height: net.h / 2.5,
                      ),
                    ),
                  ),
                ),
                pw.Align(
                  alignment: pw.Alignment.centerLeft,
                  child: pw.Text(
                    _t(
                      'CRITICAL PATH ${cpm.criticalPath}   PROJECT DURATION: ${cpm.duration.toStringAsFixed(0)} CALENDAR DAYS'
                      '${p.unworkableDays > 0 ? ' (+${p.unworkableDays} unworkable = ${(cpm.duration + p.unworkableDays).toStringAsFixed(0)} CD)' : ''}',
                    ),
                    style: pw.TextStyle(
                      fontSize: 8.5,
                      fontWeight: pw.FontWeight.bold,
                    ),
                  ),
                ),
                pw.SizedBox(height: 14),
                _signatoryRow(720),
              ],
            ),
          ),
        );
      }
    }
    if (scurveRows.isNotEmpty) {
      doc.addPage(
        pw.MultiPage(
          pageFormat: landscape,
          margin: mg,
          build: (c) => [
            _letterhead(logo, 720),
            _title('S-CURVE', size: 13),
            _infoRow(720, 'ABC: ${_m(est.grandTotal)}'),
            pw.SizedBox(height: 8),
            _scurveBlock(scurveRows, curve),
            pw.SizedBox(height: 16),
            _signatoryRow(720),
          ],
        ),
      );
    }
    // DRAWINGS appendix lives in pdf_export_drawings.dart.
    await _appendDrawingPages(doc, landscape, mg, logo);
    return doc.save();
  }

  // ---------- low-level cell helpers ----------

  static const _thin = pw.BorderSide(width: 0.5, color: _black);

  _Spec _s(
    String text,
    double w, {
    bool bold = false,
    bool italic = false,
    pw.TextAlign align = pw.TextAlign.left,
    PdfColor? bg,
    PdfColor? fg,
    double size = 7.6,
    bool right = true,
  }) => _Spec(text, w, bold, italic, align, bg, fg, size, right);

  pw.Widget _cell(
    String text,
    double w, {
    bool bold = false,
    bool italic = false,
    pw.TextAlign align = pw.TextAlign.left,
    PdfColor? bg,
    PdfColor? fg,
    double size = 7.6,
    double? h,
    bool right = true,
  }) {
    return pw.Container(
      width: w,
      height: h,
      alignment: switch (align) {
        pw.TextAlign.center => pw.Alignment.center,
        pw.TextAlign.right => pw.Alignment.centerRight,
        _ => pw.Alignment.centerLeft,
      },
      padding: const pw.EdgeInsets.symmetric(horizontal: 3, vertical: 1.8),
      decoration: pw.BoxDecoration(
        color: bg,
        border: pw.Border(right: right ? _thin : pw.BorderSide.none),
      ),
      child: pw.Text(
        _t(text),
        textAlign: align,
        style: pw.TextStyle(
          fontSize: size,
          color: fg ?? _black,
          fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal,
          fontStyle: italic ? pw.FontStyle.italic : pw.FontStyle.normal,
        ),
      ),
    );
  }

  /// One bordered table row; every cell gets the tallest cell's height so
  /// the vertical rules run unbroken. [bg] paints the whole row.
  pw.Widget _row(List<_Spec> specs, {PdfColor? bg, bool top = false}) {
    var lines = 1;
    for (final sp in specs) {
      final avail = sp.w - 6;
      final tw = _textW(_t(sp.t), sp.size, bold: sp.bold) - 8;
      final n = avail <= 0 ? 1 : (tw * 1.08 / avail).ceil();
      if (n > lines) lines = n;
    }
    final maxSize = specs.fold<double>(0, (a, b) => b.size > a ? b.size : a);
    final h = lines * maxSize * 1.2 + 3.6;
    return pw.Container(
      decoration: pw.BoxDecoration(
        color: bg,
        border: pw.Border(
          left: _thin,
          right: _thin,
          bottom: _thin,
          top: top ? _thin : pw.BorderSide.none,
        ),
      ),
      child: pw.Row(
        children: [
          for (final sp in specs)
            _cell(
              sp.t,
              sp.w,
              bold: sp.bold,
              italic: sp.italic,
              align: sp.align,
              bg: sp.bg,
              fg: sp.fg,
              size: sp.size,
              right: sp.right,
              h: h,
            ),
        ],
      ),
    );
  }

  double _textW(String s, double size, {bool bold = false}) {
    var w = 0.0;
    for (final ch in s.runes) {
      final c = String.fromCharCode(ch);
      if (RegExp(r'[0-9]').hasMatch(c)) {
        w += 0.556;
      } else if (RegExp(r'[A-Z]').hasMatch(c)) {
        w += 0.68;
      } else if (RegExp(r'[a-z]').hasMatch(c)) {
        w += 0.5;
      } else if (c == 'm' || c == 'w') {
        w += 0.78;
      } else {
        w += 0.3;
      }
    }
    return w * size * (bold ? 1.07 : 1) + 8;
  }

  // ---------- shared blocks ----------

  pw.Widget _letterhead(pw.MemoryImage? logo, double width) {
    final p = est.project;
    final accent = _c(p.themeColor);
    return pw.Column(
      children: [
        if (logo != null)
          pw.Container(
            height: 54,
            alignment: pw.Alignment.center,
            child: pw.Image(logo, height: 54),
          ),
        if (logo != null) pw.SizedBox(height: 3),
        for (var i = 0; i < p.effLetterhead.length; i++)
          pw.Padding(
            padding: const pw.EdgeInsets.symmetric(vertical: 1.2),
            child: pw.Text(
              _t(p.effLetterhead[i]),
              style: pw.TextStyle(
                fontSize: i == p.letterheadBold ? 9.5 : 8.4,
                fontWeight: i == p.letterheadBold
                    ? pw.FontWeight.bold
                    : pw.FontWeight.normal,
              ),
            ),
          ),
        pw.SizedBox(height: 7),
        pw.Container(width: width, height: 1.6, color: accent),
        pw.SizedBox(height: 10),
      ],
    );
  }

  pw.Widget _title(String s, {double size = 12}) => pw.Padding(
    padding: const pw.EdgeInsets.only(top: 2, bottom: 3),
    child: pw.Center(
      child: pw.Text(
        _t(s),
        style: pw.TextStyle(fontSize: size, fontWeight: pw.FontWeight.bold),
      ),
    ),
  );

  /// "I. TITLE   CD: ..." on the left, [right] on the right.
  pw.Widget _infoRow(double width, String right) {
    final p = est.project;
    return pw.SizedBox(
      width: width,
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Text(
            _t('I. ${p.title}   CD: ${p.contractDuration}'),
            style: pw.TextStyle(fontSize: 8.4, fontWeight: pw.FontWeight.bold),
          ),
          pw.Text(
            _t(right),
            style: pw.TextStyle(fontSize: 8.4, fontWeight: pw.FontWeight.bold),
          ),
        ],
      ),
    );
  }

  /// Boxed 5-row project block, same label/value geometry as the sheet.
  pw.Widget _projectBlock(double width, {required bool boq}) {
    final p = est.project;
    final fmt = DateFormat('MMMM d, yyyy');
    // [label, value, right label, right value] widths from the sheet's
    // column units (BOQ A:C|D:E|F|G:I, POW A:B|C:D|E:F|G:H)
    final u = boq ? [26, 58, 12, 44, 0] : [21.5, 44.1, 16.3, 32, 0];
    final tot = u[0] + u[1] + u[2] + u[3];
    final w = [for (var i = 0; i < 4; i++) width * u[i] / tot];
    pw.Widget r(
      String l,
      String v, {
      String? rl,
      String? rv,
      bool last = false,
    }) {
      const sz = 8.0;
      final cells = rl == null
          ? [
              _s(l, w[0], bold: true, size: sz),
              _s(v, w[1] + w[2] + w[3], size: sz, right: false),
            ]
          : [
              _s(l, w[0], bold: true, size: sz),
              _s(v, w[1], size: sz),
              _s(rl, w[2], bold: true, size: sz),
              _s(
                rv ?? '',
                w[3],
                size: sz,
                right: false,
                bold: rl == 'ABC:',
                align: rl == 'ABC:' ? pw.TextAlign.right : pw.TextAlign.left,
              ),
            ];
      return _row(cells, top: l == 'PROJECT TITLE:');
    }

    return pw.Column(
      children: [
        r('PROJECT TITLE:', p.title),
        r('LOCATION:', p.location, rl: 'DATE:', rv: fmt.format(p.date)),
        r('DIVISION:', p.division, rl: 'CD:', rv: p.contractDuration),
        r(
          'SOURCE OF FUND:',
          p.sourceOfFund,
          rl: 'ABC:',
          rv: _m(est.grandTotal),
        ),
        r('PHYSICAL TARGET:', p.physicalTarget),
      ],
    );
  }

  // ---------- signatories ----------

  pw.Widget _sigCell(Signatory s, {bool labelLeft = false}) => pw.Column(
    children: [
      pw.Align(
        alignment: labelLeft ? pw.Alignment.centerLeft : pw.Alignment.center,
        child: pw.Padding(
          padding: pw.EdgeInsets.only(left: labelLeft ? 28 : 0),
          child: pw.Text(
            _t('${s.label}:'),
            style: const pw.TextStyle(fontSize: 8.4),
          ),
        ),
      ),
      pw.SizedBox(height: 26),
      pw.Text(
        _t(s.name),
        textAlign: pw.TextAlign.center,
        style: pw.TextStyle(
          fontSize: 8.6,
          fontWeight: pw.FontWeight.bold,
          decoration: pw.TextDecoration.underline,
        ),
      ),
      pw.Text(
        _t(s.position),
        textAlign: pw.TextAlign.center,
        style: const pw.TextStyle(fontSize: 8.4),
      ),
    ],
  );

  /// Portrait sheets: two signatories per band like the workbook.
  pw.Widget _signatoryPairs(double width) {
    final sigs = est.project.effSignatories;
    final bands = <pw.Widget>[];
    for (var i = 0; i < sigs.length; i += 2) {
      bands.add(
        pw.Padding(
          padding: const pw.EdgeInsets.only(top: 22),
          child: pw.Row(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Expanded(child: _sigCell(sigs[i], labelLeft: true)),
              pw.Expanded(
                child: i + 1 < sigs.length
                    ? _sigCell(sigs[i + 1], labelLeft: true)
                    : pw.SizedBox(),
              ),
            ],
          ),
        ),
      );
    }
    return pw.Padding(
      padding: const pw.EdgeInsets.only(top: 16),
      child: pw.Column(children: bands),
    );
  }

  /// Landscape sheets: signatories spread evenly (<=5 per band).
  pw.Widget _signatoryRow(double width) {
    final sigs = est.project.effSignatories;
    final bands = <pw.Widget>[];
    for (var i = 0; i < sigs.length; i += 5) {
      final chunk = sigs.sublist(i, i + 5 < sigs.length ? i + 5 : sigs.length);
      bands.add(
        pw.Padding(
          padding: const pw.EdgeInsets.only(top: 6),
          child: pw.Row(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [for (final s in chunk) pw.Expanded(child: _sigCell(s))],
          ),
        ),
      );
    }
    return pw.Column(children: bands);
  }

  // ---------- BOQ ----------

  ({pw.Widget Function() header, List<pw.Widget> rows}) _boqRows(double width) {
    final p = est.project;
    // widths from the sheet's column units (8,9,9,46,12,12,13,13,18),
    // numeric columns widened to fit the longest figure
    final items = [
      for (final s in est.sections)
        ...s.lines.where((l) => l.kind == BoqLineKind.item),
    ];
    double numW(double base, Iterable<String> vals) {
      var m = base;
      for (final v in vals) {
        final w = _textW(v, 7.6);
        if (w > m) m = w;
      }
      return m;
    }

    final wE = numW(46, items.map((l) => _m(l.materialCost)));
    final wF = numW(46, items.map((l) => _m(l.laborCost)));
    final wG = numW(54, items.map((l) => _m(l.materialTotal)));
    final wH = numW(54, items.map((l) => _m(l.laborTotal)));
    final wI = numW(66, [
      ...items.map((l) => _m(l.amount)),
      ...est.sections.map((s) => _m(s.subtotal)),
      _m(est.grandTotal),
    ]);
    const wA = 30.0, wB = 32.0, wC = 34.0;
    final wD = width - (wA + wB + wC + wE + wF + wG + wH + wI);
    final all = width;

    final hBg = _c(p.themeColor), hFg = _fg(p.themeColor);
    pw.Widget hc(String t, double w, double h) => _cell(
      t,
      w,
      bold: true,
      align: pw.TextAlign.center,
      bg: hBg,
      fg: hFg,
      h: h,
      size: 7.8,
    );
    const h1 = 15.0, h2 = 24.0;
    pw.Widget header() => pw.Container(
      decoration: pw.BoxDecoration(
        color: hBg,
        border: pw.Border.all(width: 0.5, color: _black),
      ),
      child: pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          hc('ITEM NO.', wA, h1 + h2),
          hc('Qty', wB, h1 + h2),
          hc('Unit', wC, h1 + h2),
          hc('ITEM DESCRIPTION', wD, h1 + h2),
          pw.Column(
            children: [
              pw.Row(
                children: [
                  hc('UNIT  COST', wE + wF, h1),
                  hc('TOTAL COST', wG + wH, h1),
                ],
              ),
              pw.Row(
                children: [
                  hc('Material Cost', wE, h2),
                  hc('Labor Cost', wF, h2),
                  hc('Material Cost', wG, h2),
                  hc('Labor Cost', wH, h2),
                ],
              ),
            ],
          ),
          _cell(
            'Total Amount',
            wI,
            bold: true,
            align: pw.TextAlign.center,
            bg: hBg,
            fg: hFg,
            h: h1 + h2,
            size: 7.8,
            right: false,
          ),
        ],
      ),
    );

    final secBg = _c(p.sectionColor), secFg = _fg(p.sectionColor);
    final grpBg = _c(p.groupColor), grpFg = _fg(p.groupColor);
    final subBg = _c(p.subtotalColor), subFg = _fg(p.subtotalColor);
    final rows = <pw.Widget>[];
    for (final sec in est.sections) {
      rows.add(
        _row([
          _s(
            est.letterOf(sec),
            wA,
            bold: true,
            align: pw.TextAlign.center,
            bg: secBg,
            fg: secFg,
            size: 8.4,
          ),
          _s('', wB, bg: secBg),
          _s('', wC, bg: secBg),
          _s(
            sec.title,
            all - wA - wB - wC,
            bold: true,
            bg: secBg,
            fg: secFg,
            size: 8.4,
            right: false,
          ),
        ], bg: secBg),
      );
      for (final l in sec.lines) {
        if (l.kind == BoqLineKind.groupHeader) {
          rows.add(
            _row([
              _s(
                l.description,
                all,
                bold: true,
                italic: true,
                bg: grpBg,
                fg: grpFg,
                right: false,
              ),
            ], bg: grpBg),
          );
          continue;
        }
        rows.add(
          _row([
            _s('', wA),
            _s(_q(l.qty), wB, align: pw.TextAlign.center),
            _s(l.unit, wC, align: pw.TextAlign.center),
            _s(l.description, wD),
            _s(_m(l.materialCost), wE, align: pw.TextAlign.right),
            _s(_m(l.laborCost), wF, align: pw.TextAlign.right),
            _s(_m(l.materialTotal), wG, align: pw.TextAlign.right),
            _s(_m(l.laborTotal), wH, align: pw.TextAlign.right),
            _s(_m(l.amount), wI, align: pw.TextAlign.right, right: false),
          ]),
        );
      }
      rows.add(
        _row([
          _s(
            'SUB TOTAL:',
            all - wI,
            bold: true,
            align: pw.TextAlign.right,
            bg: subBg,
            fg: subFg,
          ),
          _s(
            _m(sec.subtotal),
            wI,
            bold: true,
            align: pw.TextAlign.right,
            bg: subBg,
            fg: subFg,
            right: false,
          ),
        ], bg: subBg),
      );
    }
    rows.add(_row([_s('SUMMARY', all, bold: true, right: false)]));
    for (final sr in est.summaryRows) {
      final last = identical(sr, est.summaryRows.last);
      final band = last ? p.themeColor : p.summaryColor;
      final v = est.summaryValue(sr);
      rows.add(
        _row([
          _s(
            sr.no,
            wA,
            bold: true,
            align: pw.TextAlign.center,
            bg: _c(band),
            fg: _fg(band),
          ),
          _s(sr.label, all - wA - wI, bold: true, bg: _c(band), fg: _fg(band)),
          _s(
            v.isFinite ? _m(v) : '-',
            wI,
            bold: true,
            align: pw.TextAlign.right,
            bg: _c(band),
            fg: _fg(band),
            right: false,
          ),
        ], bg: _c(band)),
      );
    }
    return (header: header, rows: rows);
  }

  // ---------- POW ----------

  List<pw.Widget> _powRows(double width) {
    final p = est.project;
    const u = [10.0, 46.0, 9.6, 8.0, 8.3, 18.0, 14.0];
    final tot = u.fold<double>(0, (a, b) => a + b);
    final w = [for (final x in u) width * x / tot];
    final hBg = _c(p.themeColor), hFg = _fg(p.themeColor);
    pw.Widget hc(String t, double cw) => _cell(
      t,
      cw,
      bold: true,
      align: pw.TextAlign.center,
      bg: hBg,
      fg: hFg,
      h: 24,
      size: 7.8,
    );
    final out = <pw.Widget>[
      pw.Container(
        decoration: pw.BoxDecoration(
          color: hBg,
          border: pw.Border.all(width: 0.5),
        ),
        child: pw.Row(
          children: [
            hc('ITEM NO.', w[0]),
            hc('WORK ITEM', w[1]),
            hc('% TOTAL', w[2]),
            hc('UNIT', w[3]),
            hc('QTY', w[4]),
            hc('TOTAL', w[5]),
            _cell(
              'REMARKS',
              w[6],
              bold: true,
              align: pw.TextAlign.center,
              bg: hBg,
              fg: hFg,
              h: 24,
              size: 7.8,
              right: false,
            ),
          ],
        ),
      ),
    ];
    final direct = est.sections.fold<double>(0, (a, s) => a + s.subtotal);
    for (var i = 0; i < est.sections.length; i++) {
      final s = est.sections[i];
      out.add(
        _row([
          _s(String.fromCharCode(65 + i), w[0], align: pw.TextAlign.center),
          _s(s.title, w[1]),
          _s(
            direct > 0
                ? '${_pctFmt.format(s.subtotal / direct * 100)}%'
                : '0.00%',
            w[2],
            align: pw.TextAlign.center,
          ),
          _s('lot', w[3], align: pw.TextAlign.center),
          _s('1', w[4], align: pw.TextAlign.center),
          _s(_m(s.subtotal), w[5], align: pw.TextAlign.right),
          _s(s.remark, w[6], right: false),
        ]),
      );
    }
    out.add(_row([_s('', width, right: false)]));
    out.add(_row([_s('SUMMARY:', width, bold: true, right: false)]));
    for (final sr in est.summaryRows) {
      final last = identical(sr, est.summaryRows.last);
      final band = last ? p.themeColor : p.summaryColor;
      final v = est.summaryValue(sr);
      out.add(
        _row([
          _s(
            sr.no,
            w[0],
            bold: true,
            align: pw.TextAlign.center,
            bg: _c(band),
            fg: _fg(band),
          ),
          _s(
            sr.label,
            width - w[0] - w[5] - w[6],
            bold: true,
            bg: _c(band),
            fg: _fg(band),
          ),
          _s(
            v.isFinite ? _m(v) : '-',
            w[5],
            bold: true,
            align: pw.TextAlign.right,
            bg: _c(band),
            fg: _fg(band),
          ),
          _s('', w[6], bg: _c(band), right: false),
        ], bg: _c(band)),
      );
    }
    return out;
  }

  // ---------- PERT-CPM (landscape) ----------

  List<pw.Widget> _pertRows(CpmResult r, double width) {
    final p = est.project;
    const u = [5.0, 49.5, 8.0, 16.0, 7.0, 7.0, 7.0, 7.0, 8.0];
    final tot = u.fold<double>(0, (a, b) => a + b);
    final w = [for (final x in u) width * u[u.indexOf(x)] / tot];
    final hBg = _c(p.themeColor), hFg = _fg(p.themeColor);
    final crit = _c(p.subtotalColor);
    String d(double v) => _qtyFmt.format(v);
    pw.Widget line(
      List<String> t, {
      PdfColor? bg,
      PdfColor? fg,
      bool head = false,
      bool crit = false,
    }) {
      return _row([
        for (var i = 0; i < t.length; i++)
          _s(
            t[i],
            w[i],
            bold: head || (crit && i < 2) || i == 0,
            align: i == 1 ? pw.TextAlign.left : pw.TextAlign.center,
            bg: bg,
            fg: fg,
            size: 8.4,
            right: i < t.length - 1,
          ),
      ], bg: bg);
    }

    return [
      line(
        [
          'ACT',
          'ACTIVITY',
          'DAYS',
          'PREDECESSORS',
          'ES',
          'EF',
          'LS',
          'LF',
          'SLACK',
        ],
        bg: hBg,
        fg: hFg,
        head: true,
      ),
      for (final n in r.nodes)
        line(
          [
            n.letter,
            n.a.name,
            d(n.a.days),
            n.a.preds,
            d(n.es),
            d(n.ef),
            d(n.ls),
            d(n.lf),
            d(n.slack),
          ],
          bg: n.critical ? crit : null,
          crit: n.critical,
        ),
      pw.Align(
        alignment: pw.Alignment.centerRight,
        child: pw.Padding(
          padding: const pw.EdgeInsets.only(top: 3),
          child: pw.Row(
            mainAxisSize: pw.MainAxisSize.min,
            children: [
              pw.Text(
                _t('PROJECT DURATION (CRITICAL PATH ${r.criticalPath}):  '),
                style: pw.TextStyle(
                  fontSize: 8.4,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
              pw.Container(
                width: 36,
                alignment: pw.Alignment.center,
                padding: const pw.EdgeInsets.symmetric(vertical: 1.5),
                decoration: pw.BoxDecoration(
                  color: crit,
                  border: pw.Border.all(width: 0.5),
                ),
                child: pw.Text(
                  d(r.duration),
                  style: pw.TextStyle(
                    fontSize: 8.4,
                    fontWeight: pw.FontWeight.bold,
                  ),
                ),
              ),
              pw.Text(
                '  CD',
                style: pw.TextStyle(
                  fontSize: 8.4,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
            ],
          ),
        ),
      ),
      pw.SizedBox(height: 6),
      pw.Center(
        child: pw.Text(
          _t(
            'A activity   T time   ES Earliest Start   EF Earliest Finish   LS Latest Start   LF Latest Finish   → Network diagram on the next page',
          ),
          style: pw.TextStyle(fontSize: 7.6, fontStyle: pw.FontStyle.italic),
        ),
      ),
      pw.SizedBox(height: 10),
      if (r.criticalPath.isNotEmpty)
        pw.Text(
          _t(
            '1.) Any delay in the ${r.criticalPath} path will cause a delay in the entire project\'s completion, as it is the critical path with zero slack.',
          ),
          style: const pw.TextStyle(fontSize: 8.4),
        ),
      if (r.nodes.any((n) => !n.critical))
        pw.Text(
          _t(
            '2.) Activities ${r.nodes.where((n) => !n.critical).map((n) => n.letter).join(', ')} have slack — they may be delayed without affecting the overall timeline.',
          ),
          style: const pw.TextStyle(fontSize: 8.4),
        ),
    ];
  }

  // ---------- S-CURVE (landscape) ----------

  pw.Widget _scurveBlock(List<SCurveRow> rows, Uint8List? png) {
    final p = est.project;
    final hBg = _c(p.themeColor), hFg = _fg(p.themeColor);
    const w = [34.0, 122.0, 84.0, 56.0, 66.0];
    final total = est.grandTotal;
    pw.Widget line(List<String> t, {bool head = false}) => _row(
      [
        for (var i = 0; i < t.length; i++)
          _s(
            t[i],
            w[i],
            bold: head || i == 0 || i == 4,
            align: i == 2 || i == 3 || i == 4
                ? pw.TextAlign.right
                : pw.TextAlign.center,
            bg: head ? hBg : null,
            fg: head ? hFg : null,
            size: 7.8,
            right: i < 4,
          ),
      ],
      bg: head ? hBg : null,
      top: true,
    );
    String pct(double v) => '${_pctFmt.format(v * 100)}%';
    final table = pw.Column(
      children: [
        line([
          est.scurveBucket.label,
          'PERIOD (CALENDAR DAYS)',
          'PLANNED',
          'THIS ${est.scurveBucket.label}',
          'CUMULATIVE',
        ], head: true),
        for (final r in rows)
          line([
            '${r.tag}${r.week}',
            r.fromDay == r.toDay
                ? 'Day ${r.fromDay}'
                : 'Days ${r.fromDay} – ${r.toDay}',
            _m(r.pct * total),
            pct(r.pct),
            pct(r.cumPct),
          ]),
      ],
    );
    return pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        table,
        pw.SizedBox(width: 14),
        if (png != null)
          pw.Expanded(
            child: pw.Image(pw.MemoryImage(png), fit: pw.BoxFit.contain),
          ),
      ],
    );
  }
}
