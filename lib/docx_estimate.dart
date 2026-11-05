import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:archive/archive.dart';
import 'package:intl/intl.dart';

import 'cpm.dart';
import 'models.dart';
import 'network_chart.dart';
import 'scurve_chart.dart';
import 'state.dart';

/// The whole estimate as an editable .docx that mirrors the workbook:
/// Arial, theme/section/group/subtotal/summary colors, logo letterhead,
/// boxed project block, two-row header (repeats per page), signatories;
/// BOQ + POW portrait, PERT-CPM + PERT-NETWORK + S-CURVE landscape.
class DocxEstimate {
  static String _esc(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;');

  static String _hexc(int argb) =>
      (argb & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase();
  static String _fgHex(int argb) {
    final r = (argb >> 16) & 0xFF, g = (argb >> 8) & 0xFF, b = argb & 0xFF;
    return (0.299 * r + 0.587 * g + 0.114 * b) / 255 > 0.55
        ? '1E293B'
        : 'FFFFFF';
  }

  static String _trim(double v) => NumberFormat('0.##').format(v);

  static String _para(
    String text, {
    bool bold = false,
    bool italic = false,
    bool underline = false,
    String align = 'left',
    int size = 16,
    String color = '000000',
    int after = 0,
    int before = 0,
  }) {
    final lines = text.split('\n');
    final runs = StringBuffer();
    for (var i = 0; i < lines.length; i++) {
      if (i > 0) runs.write('<w:r><w:br/></w:r>');
      runs.write(
        '<w:r><w:rPr>'
        '${bold ? '<w:b/>' : ''}${italic ? '<w:i/>' : ''}'
        '${underline ? '<w:u w:val="single"/>' : ''}'
        '<w:color w:val="$color"/><w:sz w:val="$size"/></w:rPr>'
        '<w:t xml:space="preserve">${_esc(lines[i])}</w:t></w:r>',
      );
    }
    return '<w:p><w:pPr><w:spacing w:before="$before" w:after="$after"/>'
        '<w:jc w:val="$align"/></w:pPr>$runs</w:p>';
  }

  static const _noBorders =
      '<w:tcBorders><w:top w:val="nil"/><w:left w:val="nil"/>'
      '<w:bottom w:val="nil"/><w:right w:val="nil"/></w:tcBorders>';

  static String _cellx(
    String text,
    int w, {
    int span = 1,
    String? vm,
    bool bold = false,
    bool italic = false,
    String align = 'left',
    int size = 16,
    String? bg,
    String fg = '000000',
    bool borders = true,
  }) {
    return '<w:tc><w:tcPr><w:tcW w:w="$w" w:type="dxa"/>'
        '${span > 1 ? '<w:gridSpan w:val="$span"/>' : ''}'
        '${vm != null ? (vm == 'restart' ? '<w:vMerge w:val="restart"/>' : '<w:vMerge/>') : ''}'
        '${borders ? '' : _noBorders}'
        '${bg != null ? '<w:shd w:val="clear" w:color="auto" w:fill="$bg"/>' : ''}'
        '<w:tcMar><w:top w:w="20" w:type="dxa"/><w:left w:w="60" w:type="dxa"/>'
        '<w:bottom w:w="20" w:type="dxa"/><w:right w:w="60" w:type="dxa"/></w:tcMar>'
        '<w:vAlign w:val="center"/></w:tcPr>'
        '${_para(text, bold: bold, italic: italic, align: align, size: size, color: fg)}</w:tc>';
  }

  static String _tr(List<String> cells, {bool header = false}) =>
      '<w:tr><w:trPr><w:cantSplit/>${header ? '<w:tblHeader/>' : ''}</w:trPr>${cells.join()}</w:tr>';

  static String _tbl(List<int> grid, List<String> rows, {bool borders = true}) {
    const line = 'w:val="single" w:sz="4" w:space="0" w:color="000000"';
    final b = borders
        ? '<w:tblBorders><w:top $line/><w:left $line/><w:bottom $line/>'
              '<w:right $line/><w:insideH $line/><w:insideV $line/></w:tblBorders>'
        : '';
    return '<w:tbl><w:tblPr><w:tblW w:w="${grid.fold<int>(0, (a, x) => a + x)}" w:type="dxa"/>'
        '$b<w:tblLayout w:type="fixed"/><w:tblCellMar><w:left w:w="60" w:type="dxa"/>'
        '<w:right w:w="60" w:type="dxa"/></w:tblCellMar></w:tblPr>'
        '<w:tblGrid>${grid.map((g) => '<w:gridCol w:w="$g"/>').join()}</w:tblGrid>'
        '${rows.join()}</w:tbl>';
  }

  static List<int> _split(int total, List<double> units) {
    final sum = units.fold<double>(0, (a, b) => a + b);
    final out = [for (final u in units) (total * u / sum).floor()];
    out[out.length - 1] += total - out.fold<int>(0, (a, b) => a + b);
    return out;
  }

  static String _imgPara(
    String rid,
    int id,
    int cx,
    int cy,
    String name, {
    String align = 'center',
  }) =>
      '<w:p><w:pPr><w:spacing w:before="0" w:after="60"/><w:jc w:val="$align"/></w:pPr>'
      '<w:r><w:drawing><wp:inline distT="0" distB="0" distL="0" distR="0">'
      '<wp:extent cx="$cx" cy="$cy"/><wp:docPr id="$id" name="$name"/>'
      '<a:graphic xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">'
      '<a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">'
      '<pic:pic xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">'
      '<pic:nvPicPr><pic:cNvPr id="$id" name="$name"/><pic:cNvPicPr/></pic:nvPicPr>'
      '<pic:blipFill><a:blip r:embed="$rid"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>'
      '<pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="$cx" cy="$cy"/></a:xfrm>'
      '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr></pic:pic>'
      '</a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>';

  static double _aspect(List<int> b) {
    if (b.length > 24 && b[1] == 0x50 && b[2] == 0x4E) {
      int u(int o) =>
          (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3];
      return u(16) / u(20);
    }
    return 1;
  }

  static String _sect({required bool landscape, bool inPara = true}) {
    final s = landscape
        ? '<w:pgSz w:w="15840" w:h="12240" w:orient="landscape"/>'
        : '<w:pgSz w:w="12240" w:h="15840"/>';
    final x =
        '<w:sectPr>$s<w:pgMar w:top="720" w:right="720" w:bottom="720" '
        'w:left="720" w:header="360" w:footer="360" w:gutter="0"/></w:sectPr>';
    return inPara ? '<w:p><w:pPr>$x</w:pPr></w:p>' : x;
  }

  static Future<List<int>> build() async {
    est.syncSchedule();
    final p = est.project;
    final money = NumberFormat('#,##0.00');
    String m(double v) => money.format(v);
    final cpm = computeCpm(est.activities);
    final scRows = cpm.error == null
        ? buildSCurve(
            cpm,
            horizonDays: parseDays(p.contractDuration),
            weights: [for (final n in cpm.nodes) est.activityCost(n.a)],
            unworkableDays: p.unworkableDays.toDouble(),
            bucket: est.scurveBucket,
          )
        : const <SCurveRow>[];
    final curve = await renderSCurvePng(
      scRows,
      accent: ui.Color(p.themeColor | 0xFF000000),
      barColor: ui.Color(p.sectionColor | 0xFF000000),
    );
    final net = await renderNetworkPng(cpm, p);

    final media = <String, List<int>>{};
    Uint8List? logo;
    var logoExt = 'png';
    if (p.effLogo != null) {
      try {
        logo = base64Decode(p.effLogo!);
        if (logo.length > 3 && logo[0] == 0xFF && logo[1] == 0xD8)
          logoExt = 'jpeg';
        media['logo.$logoExt'] = logo;
      } catch (_) {
        logo = null;
      }
    }
    if (curve != null) media['scurve.png'] = curve;
    if (net != null) media['network.png'] = net.bytes;

    const imgId = 10;
    String letterhead() {
      final b = StringBuffer();
      if (logo != null) {
        const hEmu = 54 * 12700;
        b.write(
          _imgPara(
            'rIdLogo',
            imgId,
            (hEmu * _aspect(logo)).round(),
            hEmu,
            'logo',
          ),
        );
      }
      for (var i = 0; i < p.effLetterhead.length; i++) {
        b.write(
          _para(
            p.effLetterhead[i],
            align: 'center',
            bold: i == p.letterheadBold,
            size: i == p.letterheadBold ? 19 : 17,
            after: 20,
          ),
        );
      }
      b.write(
        '<w:p><w:pPr><w:pBdr><w:bottom w:val="single" w:sz="12" w:space="1" '
        'w:color="${_hexc(p.themeColor)}"/></w:pBdr>'
        '<w:spacing w:before="0" w:after="200"/></w:pPr></w:p>',
      );
      return b.toString();
    }

    String projectBlock(int total, bool boq) {
      final u = boq ? [26.0, 24.0, 12.0, 44.0] : [21.5, 19.6, 16.3, 32.0];
      final g = _split(total, u);
      final fmt = DateFormat('MMMM d, yyyy');
      String row(String l, String v, {String? rl, String? rv}) {
        if (rl == null) {
          return _tr([
            _cellx(l, g[0], bold: true),
            _cellx(v, g[1] + g[2] + g[3], span: 3),
          ]);
        }
        return _tr([
          _cellx(l, g[0], bold: true),
          _cellx(v, g[1]),
          _cellx(rl, g[2], bold: true),
          _cellx(
            rv ?? '',
            g[3],
            bold: rl == 'ABC:',
            align: rl == 'ABC:' ? 'right' : 'left',
          ),
        ]);
      }

      return _tbl(g, [
        row('PROJECT TITLE:', p.title),
        row('LOCATION:', p.location, rl: 'DATE:', rv: fmt.format(p.date)),
        row('DIVISION:', p.division, rl: 'CD:', rv: p.contractDuration),
        row(
          'SOURCE OF FUND:',
          p.sourceOfFund,
          rl: 'ABC:',
          rv: m(est.grandTotal),
        ),
        row('PHYSICAL TARGET:', p.physicalTarget),
      ]);
    }

    String sigGrid(int total, {required int perBand}) {
      final sigs = p.effSignatories;
      final b = StringBuffer();
      for (var i = 0; i < sigs.length; i += perBand) {
        b.write(_para('', after: 200));
        final chunk = sigs.sublist(
          i,
          i + perBand < sigs.length ? i + perBand : sigs.length,
        );
        final g = _split(total, [for (var k = 0; k < perBand; k++) 1.0]);
        final cells = <String>[];
        for (var k = 0; k < perBand; k++) {
          if (k >= chunk.length) {
            cells.add(_cellx('', g[k], borders: false));
            continue;
          }
          final s = chunk[k];
          cells.add(
            '<w:tc><w:tcPr><w:tcW w:w="${g[k]}" w:type="dxa"/>$_noBorders</w:tcPr>'
            '${_para('${s.label}:', align: perBand == 2 ? 'left' : 'center', size: 17, after: 520)}'
            '${_para(s.name, bold: true, underline: true, align: 'center', size: 17)}'
            '${_para(s.position, align: 'center', size: 17, after: 120)}</w:tc>',
          );
        }
        b.write(_tbl(g, [_tr(cells)], borders: false));
      }
      return b.toString();
    }

    String title(String t, {int size = 22}) => _para(
      t,
      bold: true,
      align: 'center',
      size: size,
      before: 40,
      after: 60,
    );
    String info(String right, int total) {
      final g = _split(total, [60, 40]);
      return _tbl(g, [
        _tr([
          _cellx(
            'I. ${p.title}   CD: ${p.contractDuration}',
            g[0],
            bold: true,
            size: 17,
            borders: false,
          ),
          _cellx(
            right,
            g[1],
            bold: true,
            size: 17,
            align: 'right',
            borders: false,
          ),
        ]),
      ], borders: false);
    }

    final hBg = _hexc(p.themeColor), hFg = _fgHex(p.themeColor);
    final secBg = _hexc(p.sectionColor), secFg = _fgHex(p.sectionColor);
    final grpBg = _hexc(p.groupColor), grpFg = _fgHex(p.groupColor);
    final subBg = _hexc(p.subtotalColor), subFg = _fgHex(p.subtotalColor);

    final body = StringBuffer()
      ..write(
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" '
        'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" '
        'xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing">'
        '<w:body>',
      );

    // ---- BOQ (portrait) ----
    const pw1 = 10800;
    // numeric columns widen to fit the longest figure (8pt Arial digits
    // ~ 92 dxa each + cell margins)
    final items = [
      for (final sec in est.sections)
        ...sec.lines.where((l) => l.kind == BoqLineKind.item),
    ];
    int need(int base, Iterable<double> vals) {
      var n = base;
      for (final v in vals) {
        final w = m(v).length * 92 + 150;
        if (w > n) n = w;
      }
      return n;
    }

    final nE = need(925, items.map((l) => l.materialCost));
    final nF = need(925, items.map((l) => l.laborCost));
    final nG = need(1000, items.map((l) => l.materialTotal));
    final nH = need(1000, items.map((l) => l.laborTotal));
    final nI = need(1390, [
      ...items.map((l) => l.amount),
      ...est.sections.map((s) => s.subtotal),
      est.grandTotal,
    ]);
    const fixedL = 620 + 700 + 700;
    final bg = [
      620,
      700,
      700,
      pw1 - fixedL - nE - nF - nG - nH - nI,
      nE,
      nF,
      nG,
      nH,
      nI,
    ];
    String hc(String t, int w, {int span = 1, String? vm}) => _cellx(
      t,
      w,
      span: span,
      vm: vm,
      bold: true,
      align: 'center',
      bg: hBg,
      fg: hFg,
    );
    final boqRows = <String>[
      _tr([
        hc('ITEM NO.', bg[0], vm: 'restart'),
        hc('Qty', bg[1], vm: 'restart'),
        hc('Unit', bg[2], vm: 'restart'),
        hc('ITEM DESCRIPTION', bg[3], vm: 'restart'),
        hc('UNIT  COST', bg[4] + bg[5], span: 2),
        hc('TOTAL COST', bg[6] + bg[7], span: 2),
        hc('Total Amount', bg[8], vm: 'restart'),
      ], header: true),
      _tr([
        hc('', bg[0], vm: 'continue'),
        hc('', bg[1], vm: 'continue'),
        hc('', bg[2], vm: 'continue'),
        hc('', bg[3], vm: 'continue'),
        hc('Material Cost', bg[4]),
        hc('Labor Cost', bg[5]),
        hc('Material Cost', bg[6]),
        hc('Labor Cost', bg[7]),
        hc('', bg[8], vm: 'continue'),
      ], header: true),
    ];
    for (final sec in est.sections) {
      boqRows.add(
        _tr([
          _cellx(
            est.letterOf(sec),
            bg[0],
            bold: true,
            align: 'center',
            size: 18,
            bg: secBg,
            fg: secFg,
          ),
          _cellx('', bg[1] + bg[2], span: 2, bg: secBg),
          _cellx(
            sec.title,
            pw1 - bg[0] - bg[1] - bg[2],
            span: 6,
            bold: true,
            size: 18,
            bg: secBg,
            fg: secFg,
          ),
        ]),
      );
      for (final l in sec.lines) {
        if (l.kind == BoqLineKind.groupHeader) {
          boqRows.add(
            _tr([
              _cellx(
                l.description,
                pw1,
                span: 9,
                bold: true,
                italic: true,
                bg: grpBg,
                fg: grpFg,
              ),
            ]),
          );
          continue;
        }
        boqRows.add(
          _tr([
            _cellx('', bg[0]),
            _cellx(_trim(l.qty), bg[1], align: 'center'),
            _cellx(l.unit, bg[2], align: 'center'),
            _cellx(l.description, bg[3]),
            _cellx(m(l.materialCost), bg[4], align: 'right'),
            _cellx(m(l.laborCost), bg[5], align: 'right'),
            _cellx(m(l.materialTotal), bg[6], align: 'right'),
            _cellx(m(l.laborTotal), bg[7], align: 'right'),
            _cellx(m(l.amount), bg[8], align: 'right'),
          ]),
        );
      }
      boqRows.add(
        _tr([
          _cellx(
            'SUB TOTAL:',
            pw1 - bg[8],
            span: 8,
            bold: true,
            align: 'right',
            bg: subBg,
            fg: subFg,
          ),
          _cellx(
            m(sec.subtotal),
            bg[8],
            bold: true,
            align: 'right',
            bg: subBg,
            fg: subFg,
          ),
        ]),
      );
    }
    boqRows.add(_tr([_cellx('SUMMARY', pw1, span: 9, bold: true)]));
    for (final sr in est.summaryRows) {
      final last = identical(sr, est.summaryRows.last);
      final band = last ? p.themeColor : p.summaryColor;
      final v = est.summaryValue(sr);
      boqRows.add(
        _tr([
          _cellx(
            sr.no,
            bg[0],
            bold: true,
            align: 'center',
            bg: _hexc(band),
            fg: _fgHex(band),
          ),
          _cellx(
            sr.label,
            pw1 - bg[0] - bg[8],
            span: 7,
            bold: true,
            bg: _hexc(band),
            fg: _fgHex(band),
          ),
          _cellx(
            v.isFinite ? m(v) : '-',
            bg[8],
            bold: true,
            align: 'right',
            bg: _hexc(band),
            fg: _fgHex(band),
          ),
        ]),
      );
    }
    body
      ..write(letterhead())
      ..write(projectBlock(pw1, true))
      ..write(
        _para(
          'DETAILED ESTIMATES',
          bold: true,
          size: 26,
          before: 240,
          after: 120,
        ),
      )
      ..write(_tbl(bg, boqRows))
      ..write(sigGrid(pw1, perBand: 2))
      ..write(_sect(landscape: false));

    // ---- POW (portrait) ----
    final pg = _split(pw1, [10, 46, 9.6, 8, 8.3, 18, 14]);
    String ph(String t, int w) =>
        _cellx(t, w, bold: true, align: 'center', bg: hBg, fg: hFg);
    final direct = est.sections.fold<double>(0, (a, s) => a + s.subtotal);
    final powRows = <String>[
      _tr([
        ph('ITEM NO.', pg[0]),
        ph('WORK ITEM', pg[1]),
        ph('% TOTAL', pg[2]),
        ph('UNIT', pg[3]),
        ph('QTY', pg[4]),
        ph('TOTAL', pg[5]),
        ph('REMARKS', pg[6]),
      ], header: true),
      for (var i = 0; i < est.sections.length; i++)
        _tr([
          _cellx(String.fromCharCode(65 + i), pg[0], align: 'center'),
          _cellx(est.sections[i].title, pg[1]),
          _cellx(
            '${direct > 0 ? (est.sections[i].subtotal / direct * 100).toStringAsFixed(2) : '0.00'}%',
            pg[2],
            align: 'center',
          ),
          _cellx('lot', pg[3], align: 'center'),
          _cellx('1', pg[4], align: 'center'),
          _cellx(m(est.sections[i].subtotal), pg[5], align: 'right'),
          _cellx(est.sections[i].remark, pg[6]),
        ]),
      _tr([_cellx('', pw1, span: 7)]),
      _tr([_cellx('SUMMARY:', pw1, span: 7, bold: true)]),
      for (final sr in est.summaryRows)
        () {
          final last = identical(sr, est.summaryRows.last);
          final band = last ? p.themeColor : p.summaryColor;
          final v = est.summaryValue(sr);
          return _tr([
            _cellx(
              sr.no,
              pg[0],
              bold: true,
              align: 'center',
              bg: _hexc(band),
              fg: _fgHex(band),
            ),
            _cellx(
              sr.label,
              pg[1] + pg[2] + pg[3] + pg[4],
              span: 4,
              bold: true,
              bg: _hexc(band),
              fg: _fgHex(band),
            ),
            _cellx(
              v.isFinite ? m(v) : '-',
              pg[5],
              bold: true,
              align: 'right',
              bg: _hexc(band),
              fg: _fgHex(band),
            ),
            _cellx('', pg[6], bg: _hexc(band)),
          ]);
        }(),
    ];
    body
      ..write(letterhead())
      ..write(projectBlock(pw1, false))
      ..write(
        _para(
          'PROGRAM OF WORKS',
          bold: true,
          size: 26,
          before: 240,
          after: 120,
        ),
      )
      ..write(_tbl(pg, powRows))
      ..write(sigGrid(pw1, perBand: 2))
      ..write(_sect(landscape: false));

    // ---- landscape sheets ----
    const lw = 14400;
    final unw = p.unworkableDays > 0
        ? ' (incl. ${p.unworkableDays} unworkable)'
        : '';
    if (est.activities.isNotEmpty && cpm.error == null) {
      final cg = _split(lw, [5, 49.5, 8, 16, 7, 7, 7, 7, 8]);
      String ch(String t, int w) =>
          _cellx(t, w, bold: true, align: 'center', size: 17, bg: hBg, fg: hFg);
      String d(double v) => _trim(v);
      final pertRows = <String>[
        _tr([
          ch('ACT', cg[0]),
          ch('ACTIVITY', cg[1]),
          ch('DAYS', cg[2]),
          ch('PREDECESSORS', cg[3]),
          ch('ES', cg[4]),
          ch('EF', cg[5]),
          ch('LS', cg[6]),
          ch('LF', cg[7]),
          ch('SLACK', cg[8]),
        ], header: true),
        for (final n in cpm.nodes)
          () {
            final bgc = n.critical ? subBg : null;
            String c(
              String t,
              int i, {
              bool bold = false,
              String a = 'center',
            }) => _cellx(
              t,
              cg[i],
              bold: bold,
              align: a,
              size: 17,
              bg: bgc,
              fg: n.critical ? subFg : '000000',
            );
            return _tr([
              c(n.letter, 0, bold: true),
              c(n.a.name, 1, bold: n.critical, a: 'left'),
              c(d(n.a.days), 2),
              c(n.a.preds, 3),
              c(d(n.es), 4),
              c(d(n.ef), 5),
              c(d(n.ls), 6),
              c(d(n.lf), 7),
              c(d(n.slack), 8),
            ]);
          }(),
      ];
      body
        ..write(letterhead())
        ..write(
          title(
            'Program Evaluation and Review Technique (PERT) & Critical Path Method (CPM)',
            size: 20,
          ),
        )
        ..write(info('CALENDAR DAYS$unw', lw))
        ..write(_para('', after: 80))
        ..write(_tbl(cg, pertRows))
        ..write(
          _para(
            'PROJECT DURATION (CRITICAL PATH ${cpm.criticalPath}):  ${d(cpm.duration)}  CD',
            bold: true,
            align: 'right',
            size: 17,
            before: 60,
          ),
        )
        ..write(
          _para(
            'A activity   T time   ES Earliest Start   EF Earliest Finish   LS Latest Start   LF Latest Finish   → Network diagram on the next page',
            italic: true,
            align: 'center',
            size: 15,
            after: 120,
          ),
        )
        ..write(
          cpm.criticalPath.isEmpty
              ? ''
              : _para(
                  '1.) Any delay in the ${cpm.criticalPath} path will cause a delay in the entire project\'s completion, as it is the critical path with zero slack.',
                  size: 17,
                ),
        )
        ..write(
          cpm.nodes.any((n) => !n.critical)
              ? _para(
                  '2.) Activities ${cpm.nodes.where((n) => !n.critical).map((n) => n.letter).join(', ')} have slack — they may be delayed without affecting the overall timeline.',
                  size: 17,
                )
              : '',
        )
        ..write(sigGrid(lw, perBand: 4))
        ..write(_sect(landscape: true));

      if (net != null) {
        var cx = lw * 635, cy = (cx * net.h / net.w).round();
        const maxCy = 4600 * 635;
        if (cy > maxCy) {
          cx = (cx * maxCy / cy).round();
          cy = maxCy;
        }
        body
          ..write(letterhead())
          ..write(title('NETWORK DIAGRAM — PERT/CPM'))
          ..write(info('CALENDAR DAYS$unw', lw))
          ..write(_imgPara('rIdNet', imgId + 1, cx, cy, 'network'))
          ..write(
            _para(
              'CRITICAL PATH ${cpm.criticalPath}   PROJECT DURATION: ${cpm.duration.toStringAsFixed(0)} CALENDAR DAYS'
              '${p.unworkableDays > 0 ? ' (+${p.unworkableDays} unworkable = ${(cpm.duration + p.unworkableDays).toStringAsFixed(0)} CD)' : ''}',
              bold: true,
              size: 17,
              before: 60,
            ),
          )
          ..write(sigGrid(lw, perBand: 4))
          ..write(_sect(landscape: true));
      }
    }
    if (scRows.isNotEmpty) {
      final sg = _split(7500, [34, 122, 84, 56, 66]);
      String sh(String t, int i) =>
          _cellx(t, sg[i], bold: true, align: 'center', bg: hBg, fg: hFg);
      String pct(double v) => '${(v * 100).toStringAsFixed(2)}%';
      final rows = <String>[
        _tr([
          sh(est.scurveBucket.label, 0),
          sh('PERIOD (CALENDAR DAYS)', 1),
          sh('PLANNED', 2),
          sh('THIS ${est.scurveBucket.label}', 3),
          sh('CUMULATIVE', 4),
        ], header: true),
        for (final r in scRows)
          _tr([
            _cellx('${r.tag}${r.week}', sg[0], bold: true, align: 'center'),
            _cellx(
              r.fromDay == r.toDay
                  ? 'Day ${r.fromDay}'
                  : 'Days ${r.fromDay} – ${r.toDay}',
              sg[1],
              align: 'center',
            ),
            _cellx(m(r.pct * est.grandTotal), sg[2], align: 'right'),
            _cellx(pct(r.pct), sg[3], align: 'right'),
            _cellx(pct(r.cumPct), sg[4], align: 'right', bold: true),
          ]),
      ];
      final chartCx = 6700 * 635, chartCy = (chartCx * 620 / 1100).round();
      final layout = _tbl(
        [7700, 6700],
        [
          _tr([
            '<w:tc><w:tcPr><w:tcW w:w="7700" w:type="dxa"/>$_noBorders</w:tcPr>${_tbl(sg, rows)}${_para('')}</w:tc>',
            '<w:tc><w:tcPr><w:tcW w:w="6700" w:type="dxa"/>$_noBorders</w:tcPr>${_imgPara('rIdCurve', imgId + 2, chartCx, chartCy, 'scurve', align: 'left')}</w:tc>',
          ]),
        ],
        borders: false,
      );
      body
        ..write(letterhead())
        ..write(title('S-CURVE', size: 26))
        ..write(info('ABC: ${m(est.grandTotal)}', lw))
        ..write(_para('', after: 80))
        ..write(layout)
        ..write(sigGrid(lw, perBand: 4));
    }
    body.write(_sect(landscape: scRows.isNotEmpty, inPara: false));
    body.write('</w:body></w:document>');

    final a = Archive();
    void add(String name, String content) {
      final b = utf8.encode(content);
      a.addFile(ArchiveFile(name, b.length, b));
    }

    add(
      '[Content_Types].xml',
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
          '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
          '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
          '<Default Extension="xml" ContentType="application/xml"/>'
          '<Default Extension="png" ContentType="image/png"/>'
          '<Default Extension="jpeg" ContentType="image/jpeg"/>'
          '<Override PartName="/word/document.xml" '
          'ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>'
          '<Override PartName="/word/styles.xml" '
          'ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>'
          '</Types>',
    );
    add(
      '_rels/.rels',
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
          '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
          '<Relationship Id="rId1" '
          'Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" '
          'Target="word/document.xml"/></Relationships>',
    );
    final rels = StringBuffer(
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
      '<Relationship Id="rIdStyles" '
      'Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" '
      'Target="styles.xml"/>',
    );
    const imgType =
        'http://schemas.openxmlformats.org/officeDocument/2006/relationships/image';
    for (final e in {
      'rIdLogo': 'logo.$logoExt',
      'rIdCurve': 'scurve.png',
      'rIdNet': 'network.png',
    }.entries) {
      if (media.containsKey(e.value)) {
        rels.write(
          '<Relationship Id="${e.key}" Type="$imgType" Target="media/${e.value}"/>',
        );
      }
    }
    rels.write('</Relationships>');
    add('word/_rels/document.xml.rels', rels.toString());
    add(
      'word/styles.xml',
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
          '<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
          '<w:docDefaults><w:rPrDefault><w:rPr>'
          '<w:rFonts w:ascii="Arial" w:hAnsi="Arial" w:cs="Arial" w:eastAsia="Arial"/>'
          '<w:sz w:val="16"/><w:szCs w:val="16"/><w:lang w:val="en-PH"/></w:rPr></w:rPrDefault>'
          '<w:pPrDefault><w:pPr><w:spacing w:after="0" w:line="240" w:lineRule="auto"/></w:pPr></w:pPrDefault>'
          '</w:docDefaults>'
          '<w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/></w:style>'
          '</w:styles>',
    );
    add('word/document.xml', body.toString());
    for (final e in media.entries) {
      a.addFile(ArchiveFile('word/media/${e.key}', e.value.length, e.value));
    }
    return ZipEncoder().encode(a)!;
  }
}
