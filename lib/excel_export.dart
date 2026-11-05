import 'dart:convert';
import 'dart:ui' show Color;

import 'package:archive/archive.dart';
import 'package:excel/excel.dart';
import 'package:intl/intl.dart';

import 'cpm.dart';
import 'models.dart';
import 'scurve_chart.dart';
import 'state.dart';

/// Builds an .xlsx workbook that mirrors the SDO template:
/// sheets BOQ (detailed estimates), POW (program of works), DATA (prices).
/// Item unit/unit-cost cells emit real VLOOKUP formulas so the file keeps
/// working when edited in Excel.
class ExcelExport {
  final EstimateState est;

  ExcelExport(this.est);

  static final _thin = Border(borderStyle: BorderStyle.Thin);
  static const _money = '#,##0.00';
  // General avoids the trailing separator "0.##" draws on integers ("344.")
  static const String? _qtyFmt = null;

  CellStyle _style({
    bool bold = false,
    bool italic = false,
    int fontSize = 11,
    Underline underline = Underline.None,
    HorizontalAlign h = HorizontalAlign.Left,
    VerticalAlign v = VerticalAlign.Center,
    bool border = false,
    String? numberFormat,
    bool wrap = false,
    String? bg,
    String? fg,
  }) {
    return CellStyle(
      bold: bold,
      italic: italic,
      fontSize: fontSize,
      underline: underline,
      horizontalAlign: h,
      verticalAlign: v,
      leftBorder: border ? _thin : Border(),
      rightBorder: border ? _thin : Border(),
      topBorder: border ? _thin : Border(),
      bottomBorder: border ? _thin : Border(),
      numberFormat: numberFormat != null
          ? CustomNumericNumFormat(formatCode: numberFormat)
          : NumFormat.standard_0,
      textWrapping: wrap ? TextWrapping.WrapText : null,
      backgroundColorHex: bg != null
          ? ExcelColor.fromHexString(bg)
          : ExcelColor.none,
      fontColorHex: fg != null
          ? ExcelColor.fromHexString(fg)
          : ExcelColor.black,
    );
  }

  /// Paints [st] onto every cell in [row] from column 0 to [lastCol] —
  /// a fill only renders where the cell carries the style, so banded
  /// rows (headers, subtotals, summary, grand total) need the whole row
  /// styled, including cells inside merged ranges.
  void _band(Sheet s, int row, int lastCol, CellStyle st) {
    for (var c = 0; c <= lastCol; c++) {
      s
              .cell(
                CellIndex.indexByColumnRow(columnIndex: c, rowIndex: row - 1),
              )
              .cellStyle =
          st;
    }
  }

  void _c(Sheet s, String ref, CellValue v, [CellStyle? st]) {
    final cell = s.cell(CellIndex.indexByString(ref));
    cell.value = v;
    if (st != null) cell.cellStyle = st;
  }

  void _mergeRow(Sheet s, int row, int c1, int c2) => _mergeCells(
    s,
    CellIndex.indexByColumnRow(columnIndex: c1, rowIndex: row - 1),
    CellIndex.indexByColumnRow(columnIndex: c2, rowIndex: row - 1),
  );

  /// Merges [a]..[b] ("A21", "H22" style indexes) keeping the anchor's
  /// style — `merge()` swaps in a blank cell when nothing in the span holds
  /// a value, which would drop the band/border already painted on it.
  void _mergeCells(Sheet s, CellIndex a, CellIndex b) {
    final st = s.cell(a).cellStyle;
    s.merge(a, b);
    if (st != null) s.cell(a).cellStyle = st;
  }

  void _mergeRange(Sheet s, String range) {
    final p = range.split(':');
    _mergeCells(
      s,
      CellIndex.indexByString(p[0]),
      CellIndex.indexByString(p[1]),
    );
  }

  /// `Sheet.merge()` deletes every covered cell, so no `<c>` element is
  /// written for them and Excel drops the merged region's top/bottom/right
  /// borders and fill (it draws each edge from the cell lying on it).
  /// Re-apply every bordered anchor style over its span — the package's
  /// `setMergedCellStyle` puts the matching edge borders on each cell.
  void _finalizeMerges(Sheet s) {
    for (final span in List<String>.of(s.spannedItems)) {
      final start = CellIndex.indexByString(span.split(':').first);
      final st = s.cell(start).cellStyle;
      if (st != null) s.setMergedCellStyle(start, st);
    }
  }

  // ==========================================================================

  Future<List<int>?> build({List<int>? logoBytes}) async {
    // the exported schedule must reflect the BOQ as it stands NOW —
    // same auto-generation the tabs trigger on build
    est.syncSchedule();
    final excel = Excel.createExcel();
    excel.rename('Sheet1', 'BOQ');
    final boq = excel['BOQ'];
    excel.setDefaultSheet('BOQ');
    _writeBoq(boq);
    _finalizeMerges(boq);
    final pow = excel['POW'];
    _writePow(pow);
    _finalizeMerges(pow);

    // PERT-CPM (formula table) + PERT-NETWORK (diagram) + S-CURVE only
    // exist when there are activities; sheet indexes follow first-touch
    // order below.
    final cpm = computeCpm(est.activities);
    final scurve = cpm.error == null
        ? buildSCurve(
            cpm,
            horizonDays: parseDays(est.project.contractDuration),
            weights: [for (final n in cpm.nodes) est.activityCost(n.a)],
            unworkableDays: est.project.unworkableDays.toDouble(),
            bucket: est.scurveBucket,
          )
        : const <SCurveRow>[];
    final hasPert = est.activities.isNotEmpty;
    final hasCurve = scurve.isNotEmpty;
    var pertFirstData = 0;
    if (hasPert) {
      final pert = excel['PERT-CPM'];
      pertFirstData = _writePertCpm(pert, cpm);
      _finalizeMerges(pert);
      if (cpm.error == null) {
        final net = excel['PERT-NETWORK'];
        _writePertNetwork(net, cpm, pertFirstData);
        _finalizeMerges(net);
      }
    }
    int chartRow = 0;
    if (hasCurve) {
      final sc = excel['S-CURVE'];
      chartRow = _writeSCurve(sc, scurve);
      _finalizeMerges(sc);
    }
    _writeData(excel['DATA']);
    final bytes = excel.save();
    if (bytes == null) return null;

    List<int>? chart;
    if (hasCurve) {
      chart = await renderSCurvePng(
        scurve,
        accent: Color(est.project.themeColor),
        barColor: Color(est.project.sectionColor),
      );
    }
    final anchors = <(int, int)>[
      _centeredAnchor([8, 9, 9, 46, 12, 12, 13, 13, 18]), // BOQ
      _centeredAnchor([10, 11.5, 34.5, 9.6, 8, 8.3, 18, 14]), // POW
      if (hasPert) ...[
        _centeredAnchor(_pertW),
        if (cpm.error == null) _centeredAnchor(_netWidths(cpm)),
      ],
      if (hasCurve) _centeredAnchor(_curveAnchorW),
    ];
    final chartSheet =
        2 + (hasPert ? (cpm.error == null ? 2 : 1) : 0) + (hasCurve ? 1 : 0);
    // page setup per sheet: PERT-CPM / PERT-NETWORK / S-CURVE are wide
    // -> landscape; BOQ and POW print portrait fit-to-width
    final landscape = <int>{
      if (hasPert) 3,
      if (hasPert && cpm.error == null) 4,
      if (hasCurve) chartSheet,
    };
    const portrait = {1, 2};
    if (logoBytes == null &&
        chart == null &&
        landscape.isEmpty &&
        portrait.isEmpty) {
      return bytes;
    }
    return _injectMedia(
      bytes,
      imgBytes: logoBytes,
      logoAnchor: anchors,
      chartPng: chart,
      chartSheet: chartSheet,
      chartAtRow: chartRow,
      landscapeSheets: landscape,
      portraitSheets: portrait,
    );
  }

  /// Data-driven media injector: the project logo on every letterheaded
  /// sheet plus (when present) the rendered S-curve chart below the
  /// SCURVE table. Each sheet that needs media gets its own drawingN
  /// part wired by rels; [imgBytes] may be null (chart-only export).
  List<int> _injectMedia(
    List<int> xlsxBytes, {
    List<int>? imgBytes,
    required List<(int, int)> logoAnchor,
    List<int>? chartPng,
    required int chartSheet,
    required int chartAtRow,
    Set<int> landscapeSheets = const {},
    Set<int> portraitSheets = const {},
  }) {
    final jpeg =
        imgBytes != null &&
        imgBytes.length > 3 &&
        imgBytes[0] == 0xFF &&
        imgBytes[1] == 0xD8;
    final ext = jpeg ? 'jpeg' : 'png';
    final mime = jpeg ? 'image/jpeg' : 'image/png';
    final media = 'xl/media/logo.$ext';
    var sheetCount = imgBytes != null ? logoAnchor.length : 0;
    if (chartPng != null && chartSheet > sheetCount) {
      sheetCount = chartSheet;
    }
    bool hasLogo(int i) => imgBytes != null && i >= 1 && i <= logoAnchor.length;
    bool hasChart(int i) => chartPng != null && i == chartSheet;
    bool needsDrawing(int i) => hasLogo(i) || hasChart(i);

    String pic(
      String name,
      String rId,
      String descr,
      String from,
      String cxCy,
    ) =>
        '<xdr:oneCellAnchor><xdr:from>$from</xdr:from>'
        '<xdr:ext $cxCy/><xdr:pic><xdr:nvPicPr>'
        '<xdr:cNvPr id="0" name="$name" descr="$descr"/>'
        '<xdr:cNvPicPr preferRelativeResize="0"/></xdr:nvPicPr>'
        '<xdr:blipFill><a:blip cstate="print" r:embed="$rId"/>'
        '<a:stretch><a:fillRect/></a:stretch></xdr:blipFill>'
        '<xdr:spPr><a:prstGeom prst="rect"><a:avLst/></a:prstGeom>'
        '<a:noFill/></xdr:spPr></xdr:pic>'
        '<xdr:clientData fLocksWithSheet="0"/></xdr:oneCellAnchor>';

    String logoAt(int i) {
      final at = logoAnchor[i - 1];
      return pic(
        'logo.$ext',
        'rId1',
        'Letterhead logo',
        '<xdr:col>${at.$1}</xdr:col><xdr:colOff>${at.$2}</xdr:colOff>'
            '<xdr:row>0</xdr:row><xdr:rowOff>0</xdr:rowOff>',
        'cx="685800" cy="685800"',
      );
    }

    // chart anchors at column I, top-aligned to the table header —
    // landscape spread with the weekly table on the left
    const chartAnchor =
        '<xdr:col>$_curveChartCol</xdr:col>'
        '<xdr:colOff>$_curveChartColOff</xdr:colOff>';
    String chartXml(int row) => pic(
      'scurve.png',
      'rId2',
      'Planned progress S-curve',
      '$chartAnchor<xdr:row>$row</xdr:row><xdr:rowOff>60000</xdr:rowOff>',
      'cx="$_curveChartCx" cy="$_curveChartCy"',
    );

    String relsFor(int sheet) {
      var rels =
          '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
          '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">';
      if (hasLogo(sheet)) {
        rels +=
            '<Relationship Id="rId1" '
            'Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" '
            'Target="../media/logo.$ext"/>';
      }
      if (hasChart(sheet)) {
        rels +=
            '<Relationship Id="rId2" '
            'Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" '
            'Target="../media/scurve.png"/>';
      }
      return '$rels</Relationships>';
    }

    const wsDrOpen =
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<xdr:wsDr xmlns:xdr="http://schemas.openxmlformats.org/drawingml/2006/spreadsheetDrawing" '
        'xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" '
        'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">';

    String drawingXml(int sheet) {
      var body = hasLogo(sheet) ? logoAt(sheet) : '';
      if (hasChart(sheet)) body += chartXml(chartAtRow);
      return '$wsDrOpen$body</xdr:wsDr>';
    }

    String sheetDrawingRels(int sheet) =>
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" '
        'Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/drawing" '
        'Target="../drawings/drawing$sheet.xml"/></Relationships>';

    final src = ZipDecoder().decodeBytes(xlsxBytes);
    final out = Archive();
    var sawSheet1Rels = false;
    void addText(String name, String content) {
      final b = utf8.encode(content);
      out.addFile(ArchiveFile(name, b.length, b));
    }

    for (final f in src.files) {
      if (f.name == 'xl/worksheets/_rels/sheet1.xml.rels') {
        sawSheet1Rels = true;
      }
      switch (f.name) {
        case 'xl/drawings/drawing1.xml':
          var xml = utf8.decode(f.content as List<int>);
          if (hasLogo(1)) {
            xml = xml.contains('</xdr:wsDr>')
                ? xml.replaceFirst('</xdr:wsDr>', '${logoAt(1)}</xdr:wsDr>')
                : xml.replaceFirst(
                    RegExp(r'/>\s*$'),
                    '>${logoAt(1)}</xdr:wsDr>',
                  );
          }
          addText(f.name, xml);
        case '[Content_Types].xml':
          var xml = utf8.decode(f.content as List<int>);
          if (imgBytes != null && !xml.contains('Extension="$ext"')) {
            xml = xml.replaceFirst(
              '</Types>',
              '<Default Extension="$ext" ContentType="$mime"/></Types>',
            );
          }
          if (chartPng != null && !xml.contains('Extension="png"')) {
            xml = xml.replaceFirst(
              '</Types>',
              '<Default Extension="png" ContentType="image/png"/></Types>',
            );
          }
          for (var i = 1; i <= sheetCount; i++) {
            if (needsDrawing(i) &&
                !xml.contains('/xl/drawings/drawing$i.xml')) {
              xml = xml.replaceFirst(
                '</Types>',
                '<Override PartName="/xl/drawings/drawing$i.xml" '
                    'ContentType="application/vnd.openxmlformats-officedocument.drawing+xml"/></Types>',
              );
            }
          }
          addText(f.name, xml);
        default:
          final m = RegExp(
            r'xl/worksheets/sheet(\d+)\.xml$',
          ).firstMatch(f.name);
          if (m != null) {
            final n = int.parse(m.group(1)!);
            if (needsDrawing(n) ||
                landscapeSheets.contains(n) ||
                portraitSheets.contains(n)) {
              var xml = utf8.decode(f.content as List<int>);
              if (needsDrawing(n) && !xml.contains('<drawing')) {
                xml = xml.replaceFirst(
                  '</worksheet>',
                  '<drawing r:id="rId1"/></worksheet>',
                );
              }
              if (landscapeSheets.contains(n)) {
                xml = _pageSetup(xml, landscape: true);
              } else if (portraitSheets.contains(n)) {
                xml = _pageSetup(xml, landscape: false);
              }
              addText(f.name, xml);
            } else {
              out.addFile(f);
            }
          } else {
            out.addFile(f);
          }
      }
    }
    if (imgBytes != null) {
      out.addFile(ArchiveFile(media, imgBytes.length, imgBytes));
    }
    if (needsDrawing(1) && !sawSheet1Rels) {
      addText('xl/worksheets/_rels/sheet1.xml.rels', sheetDrawingRels(1));
      if (hasLogo(1)) {
        addText('xl/drawings/_rels/drawing1.xml.rels', relsFor(1));
      }
    }
    for (var i = 1; i <= sheetCount; i++) {
      if (!needsDrawing(i)) continue;
      if (i > 1) {
        addText('xl/drawings/drawing$i.xml', drawingXml(i));
        addText('xl/drawings/_rels/drawing$i.xml.rels', relsFor(i));
        addText('xl/worksheets/_rels/sheet$i.xml.rels', sheetDrawingRels(i));
      } else {
        addText('xl/drawings/_rels/drawing1.xml.rels', relsFor(1));
      }
    }
    if (chartPng != null) {
      out.addFile(
        ArchiveFile('xl/media/scurve.png', chartPng.length, chartPng),
      );
    }
    return ZipEncoder().encode(out)!;
  }

  /// Marks a worksheet XML with fit-to-page-width page setup in the
  /// requested orientation so it prints and PDFs as one page wide
  /// (schema order: sheetPr first child, pageSetup after pageMargins /
  /// before drawing).
  static String _pageSetup(String xml, {required bool landscape}) {
    if (!xml.contains('<sheetPr')) {
      xml = xml.replaceFirstMapped(
        RegExp(r'<worksheet[^>]*>'),
        (m) => '${m[0]}<sheetPr><pageSetUpPr fitToPage="1"/></sheetPr>',
      );
    }
    if (!xml.contains('<pageSetup')) {
      final ps =
          '<pageSetup paperSize="1" '
          'orientation="${landscape ? 'landscape' : 'portrait'}" '
          'fitToWidth="1" fitToHeight="0"/>';
      xml = xml.contains('<drawing')
          ? xml.replaceFirst('<drawing', '$ps<drawing')
          : xml.replaceFirst('</worksheet>', '$ps</worksheet>');
    }
    return xml;
  }

  /// `(from.col, colOff)` that centers the ~0.72" logo above the
  /// letterhead on a sheet [widths] wide. The offset must stay inside
  /// the chosen column — Excel clamps an oversized colOff instead of
  /// letting it flow into later columns.
  /// A stored `<col width>` already includes Excel's 5px padding, so a
  /// column is exactly `width * 7` px (verified against the real Excel
  /// COM `Range.Left/Width`); an unlisted default column is 64px =
  /// 64/7 stored units. 1px = 9525 EMU.
  static (int, int) _centeredAnchor(List<num> widths) {
    const logoPx = 72.0;
    final edges = <double>[0];
    for (final w in widths) {
      edges.add((edges.last + w * 7).toDouble());
    }
    final x = (edges.last - logoPx) / 2;
    var col = 0;
    while (col + 1 < edges.length - 1 && edges[col + 1] <= x) {
      col++;
    }
    return (col, ((x - edges[col]) * 9525).round());
  }

  /// Rebuilds the xlsx zip with the project logo (PNG or JPEG) centered
  /// above the letterhead on BOQ (sheet1) and POW (sheet2). The excel
  /// package already emits an empty drawing1.xml wired to sheet1; sheet2
  /// gets a fresh drawing part.

  /// ARGB int → 'FFRRGGBB' hex for ExcelColor.
  static String _hex(int argb) =>
      argb.toRadixString(16).padLeft(8, '0').toUpperCase();

  /// Simple luminance for readable text on custom band colors.
  static double _lum(int argb) {
    final r = (argb >> 16) & 0xFF, g = (argb >> 8) & 0xFF, b = argb & 0xFF;
    return (0.299 * r + 0.587 * g + 0.114 * b) / 255;
  }

  /// Text color that stays readable on band color [argb].
  static String _fgOn(int argb) => _lum(argb) > 0.55 ? 'FF1E293B' : 'FFFFFFFF';

  /// Navy underline rule across the table width, matching the template's
  /// divider under the office letterhead (uses the theme accent color).
  void _navyRule(Sheet s, int row, int lastCol) {
    final rule = CellStyle(
      bottomBorder: Border(
        borderStyle: BorderStyle.Medium,
        borderColorHex: ExcelColor.fromInt(est.project.themeColor),
      ),
    );
    for (var c = 0; c <= lastCol; c++) {
      s
              .cell(
                CellIndex.indexByColumnRow(columnIndex: c, rowIndex: row - 1),
              )
              .cellStyle =
          rule;
    }
  }

  // ------------------------------- BOQ -------------------------------------

  /// The office letterhead — one merged centered row per entry of
  /// project.letterhead, the line at letterheadBold emphasized. Returns
  /// the first free row under the block so the caller can lay out the
  /// divider and project block below it (custom agencies/companies may
  /// have fewer or more lines than the DepEd default).
  int _officeHeader(Sheet s, {required int startRow, required int lastCol}) {
    // eff* — the private template exports no letterhead at all, so the
    // derived-row layout still works (the block is just empty)
    final lines = est.project.effLetterhead;
    final bold = est.project.letterheadBold;
    for (var i = 0; i < lines.length; i++) {
      final r = startRow + i;
      _mergeRow(s, r, 0, lastCol);
      _c(
        s,
        'A$r',
        TextCellValue(lines[i]),
        _style(
          bold: i == bold,
          fontSize: i == bold ? 12 : 11,
          h: HorizontalAlign.Center,
        ),
      );
    }
    return startRow + lines.length;
  }

  /// Writes signatories two per 8-row block: even index left, odd index
  /// right; name + position centered in each 3-column span. [rightCol]
  /// is the right block's label column (name merges rightCol+1..+3) —
  /// sheets wider than 9 columns pass a larger one so the right block
  /// doesn't sit on narrow mid-sheet columns.
  void _signatureBlock(
    Sheet s,
    int row, {
    int rightCol = 4,
    int leftSpan = 3,
    int rightSpan = 3,
  }) {
    final sigs = est.project.effSignatories;
    for (var i = 0; i < sigs.length; i++) {
      final sig = sigs[i];
      final left = i.isEven;
      final labelCol = left ? 0 : rightCol;
      final nameCol = left ? 1 : rightCol + 1;
      final span = left ? leftSpan : rightSpan;
      final r = row + (i ~/ 2) * 8;
      _c(
        s,
        '${_colName(labelCol)}$r',
        TextCellValue(left ? '                ${sig.label}:' : '${sig.label}:'),
      );
      _mergeRow(s, r + 3, nameCol, nameCol + span - 1);
      _mergeRow(s, r + 4, nameCol, nameCol + span - 1);
      _c(
        s,
        '${_colName(nameCol)}${r + 3}',
        TextCellValue(sig.name),
        _style(
          bold: true,
          underline: Underline.Single,
          h: HorizontalAlign.Center,
        ),
      );
      _c(
        s,
        '${_colName(nameCol)}${r + 4}',
        TextCellValue(sig.position),
        _style(h: HorizontalAlign.Center),
      );
    }
  }

  void _writeBoq(Sheet s) {
    s.setColumnWidth(0, 8); // A item no
    s.setColumnWidth(1, 9); // B qty
    s.setColumnWidth(2, 9); // C unit
    s.setColumnWidth(3, 46); // D description
    s.setColumnWidth(4, 12);
    s.setColumnWidth(5, 12);
    s.setColumnWidth(6, 13);
    s.setColumnWidth(7, 13);
    s.setColumnWidth(8, 18); // I total amount / summary values

    // the whole frame hangs off the letterhead end so a custom
    // letterhead of any length shifts the sheet as one piece
    final lhEnd = _officeHeader(s, startRow: 5, lastCol: 8);
    _navyRule(s, lhEnd, 8);
    final b0 = lhEnd + 5; // project block start (15 w/ default 5-line head)

    // project block rows b0..b0+4 — every cell boxed like the original
    // template (ABC filled after grand total known)
    final p = est.project;
    final dateFmt = DateFormat('MMMM d, yyyy');
    final label = _style(bold: true, border: true);
    final box = _style(border: true);
    // Every row spans the full A:I table width: label A:C, value D:I —
    // or D:E plus a right-hand pair (F label, G:I value) on rows 16-18.
    void infoRow(int r, String lbl, String val, {String? rlbl, String? rval}) {
      _band(s, r, 8, box);
      _mergeRow(s, r, 0, 2);
      _c(s, 'A$r', TextCellValue(lbl), label);
      _mergeRow(s, r, 3, rlbl == null ? 8 : 4);
      _c(s, 'D$r', TextCellValue(val), box);
      if (rlbl == null) return;
      _c(s, 'F$r', TextCellValue(rlbl), label);
      _mergeRow(s, r, 6, 8);
      _c(s, 'G$r', TextCellValue(rval ?? ''), box);
    }

    infoRow(b0, 'PROJECT TITLE:', p.title);
    infoRow(
      b0 + 1,
      'LOCATION:',
      p.location,
      rlbl: 'DATE:',
      rval: dateFmt.format(p.date),
    );
    infoRow(
      b0 + 2,
      'DIVISION:',
      p.division,
      rlbl: 'CD:',
      rval: p.contractDuration,
    );
    infoRow(b0 + 3, 'SOURCE OF FUND:', p.sourceOfFund, rlbl: 'ABC:');
    infoRow(b0 + 4, 'PHYSICAL TARGET:', p.physicalTarget);

    final detRow = b0 + 8;
    _mergeRow(s, detRow, 0, 8);
    _c(
      s,
      'A$detRow',
      TextCellValue('DETAILED ESTIMATES'),
      _style(bold: true, fontSize: 14),
    );

    // two-row table header — accent band like the app
    final hdr = detRow + 2;
    final hStyle = _style(
      bold: true,
      border: true,
      h: HorizontalAlign.Center,
      wrap: true,
      bg: _hex(p.themeColor),
      fg: _fgOn(p.themeColor),
    );
    _band(s, hdr, 8, hStyle);
    _band(s, hdr + 1, 8, hStyle);
    s.merge(
      CellIndex.indexByString('A$hdr'),
      CellIndex.indexByString('A${hdr + 1}'),
    );
    s.merge(
      CellIndex.indexByString('B$hdr'),
      CellIndex.indexByString('B${hdr + 1}'),
    );
    s.merge(
      CellIndex.indexByString('C$hdr'),
      CellIndex.indexByString('C${hdr + 1}'),
    );
    s.merge(
      CellIndex.indexByString('D$hdr'),
      CellIndex.indexByString('D${hdr + 1}'),
    );
    s.merge(CellIndex.indexByString('E$hdr'), CellIndex.indexByString('F$hdr'));
    s.merge(CellIndex.indexByString('G$hdr'), CellIndex.indexByString('H$hdr'));
    s.merge(
      CellIndex.indexByString('I$hdr'),
      CellIndex.indexByString('I${hdr + 1}'),
    );
    _c(s, 'A$hdr', TextCellValue('ITEM NO.'), hStyle);
    _c(s, 'B$hdr', TextCellValue('Qty'), hStyle);
    _c(s, 'C$hdr', TextCellValue('Unit'), hStyle);
    _c(s, 'D$hdr', TextCellValue('ITEM DESCRIPTION'), hStyle);
    _c(s, 'E$hdr', TextCellValue('UNIT  COST'), hStyle);
    _c(s, 'G$hdr', TextCellValue('TOTAL COST'), hStyle);
    _c(s, 'I$hdr', TextCellValue('Total Amount'), hStyle);
    _c(s, 'E${hdr + 1}', TextCellValue('Material Cost'), hStyle);
    _c(s, 'F${hdr + 1}', TextCellValue('Labor Cost'), hStyle);
    _c(s, 'G${hdr + 1}', TextCellValue('Material Cost'), hStyle);
    _c(s, 'H${hdr + 1}', TextCellValue('Labor Cost'), hStyle);

    final center = _style(border: true, h: HorizontalAlign.Center);
    final qty = _style(
      border: true,
      h: HorizontalAlign.Center,
      numberFormat: _qtyFmt,
    );
    final money = _style(
      border: true,
      h: HorizontalAlign.Right,
      numberFormat: _money,
    );
    final desc = _style(border: true, wrap: true);
    // banded-row colors — from the project's theme settings
    final secBg = _hex(p.sectionColor), secFg = _fgOn(p.sectionColor);
    final grpBg = _hex(p.groupColor), grpFg = _fgOn(p.groupColor);
    final subBg = _hex(p.subtotalColor), subFg = _fgOn(p.subtotalColor);
    final secBand = _style(
      bold: true,
      border: true,
      fontSize: 12,
      bg: secBg,
      fg: secFg,
    );
    final secBandC = _style(
      bold: true,
      border: true,
      fontSize: 12,
      bg: secBg,
      fg: secFg,
      h: HorizontalAlign.Center,
    );
    final grpBand = _style(
      bold: true,
      italic: true,
      border: true,
      bg: grpBg,
      fg: grpFg,
    );
    final subBand = _style(
      bold: true,
      border: true,
      bg: subBg,
      fg: subFg,
      h: HorizontalAlign.Right,
    );
    final subBandM = _style(
      bold: true,
      border: true,
      bg: subBg,
      fg: subFg,
      h: HorizontalAlign.Right,
      numberFormat: _money,
    );

    var row = hdr + 2;
    final subtotalRows = <int>[];
    for (final sec in est.sections) {
      final letter = est.letterOf(sec);
      _band(s, row, 8, secBand);
      _c(s, 'A$row', TextCellValue(letter), secBandC);
      _mergeRow(s, row, 3, 8);
      _c(s, 'D$row', TextCellValue(sec.title), secBand);
      row++;
      final firstItemRow = row;
      for (final line in sec.lines) {
        if (line.kind == BoqLineKind.groupHeader) {
          _band(s, row, 8, grpBand);
          _mergeRow(s, row, 0, 8);
          _c(s, 'A$row', TextCellValue(line.description), grpBand);
          row++;
          continue;
        }
        // every cell in the row gets a border — including empty ITEM NO.
        _band(s, row, 8, _style(border: true));
        _c(s, 'B$row', DoubleCellValue(line.qty), qty);
        if (line.priceKey != null) {
          _c(
            s,
            'C$row',
            FormulaCellValue('VLOOKUP(D$row,DATA!\$B\$4:\$E\$600,4,0)'),
            center,
          );
          _c(s, 'D$row', TextCellValue(line.priceKey!), desc);
          _c(
            s,
            'E$row',
            FormulaCellValue('VLOOKUP(D$row,DATA!\$B\$4:\$D\$600,2,0)'),
            money,
          );
          _c(s, 'F$row', FormulaCellValue('E$row*${est.laborRate}'), money);
        } else {
          _c(s, 'C$row', TextCellValue(line.unit), center);
          _c(s, 'D$row', TextCellValue(line.description), desc);
          _c(s, 'E$row', DoubleCellValue(line.materialCost), money);
          _c(s, 'F$row', DoubleCellValue(line.laborCost), money);
        }
        _c(s, 'G$row', FormulaCellValue('E$row*B$row'), money);
        _c(s, 'H$row', FormulaCellValue('F$row*B$row'), money);
        _c(s, 'I$row', FormulaCellValue('H$row+G$row'), money);
        row++;
      }
      _band(s, row, 8, subBand);
      _mergeRow(s, row, 0, 7);
      _c(s, 'A$row', TextCellValue('SUB TOTAL:'), subBand);
      final last = row - 1;
      if (last >= firstItemRow) {
        _c(
          s,
          'I$row',
          FormulaCellValue('SUM(I$firstItemRow:I$last)'),
          subBandM,
        );
      } else {
        _c(s, 'I$row', DoubleCellValue(0), subBandM);
      }
      subtotalRows.add(row);
      row++;
    }

    // summary — one row per est.summaryRows; identifiers become cell refs.
    // Like the template, SUMMARY follows the last SUB TOTAL with no gap so
    // the bordered grid runs unbroken to the GRAND TOTAL.
    final sumLabel = _style(bold: true, border: true);
    _band(s, row, 8, sumLabel);
    _mergeRow(s, row, 0, 8);
    _c(s, 'A$row', TextCellValue('SUMMARY'), sumLabel);
    row++;
    final sumExpr = subtotalRows.isEmpty
        ? '0'
        : subtotalRows.map((r) => 'I$r').join('+');
    final cellOf = <String, int>{};
    // Section letters (A, B, C…) resolve to that section's SUB TOTAL cell.
    final secCells = <String, String>{
      for (
        var i = 0;
        i < est.sections.length && i < subtotalRows.length && i < 26;
        i++
      )
        String.fromCharCode(65 + i): 'I${subtotalRows[i]}',
    };
    for (final sr in est.summaryRows) {
      // last summary row = accent GRAND TOTAL bar like the app
      final isLast = identical(sr, est.summaryRows.last);
      final band = isLast ? p.themeColor : p.summaryColor;
      final bg = _hex(band);
      final fg = _fgOn(band);
      _band(s, row, 8, _style(border: true, bg: bg));
      _c(
        s,
        'A$row',
        TextCellValue(sr.no),
        _style(
          bold: true,
          border: true,
          h: HorizontalAlign.Center,
          bg: bg,
          fg: fg,
        ),
      );
      _c(
        s,
        'B$row',
        TextCellValue(sr.label),
        _style(bold: true, border: true, bg: bg, fg: fg),
      );
      _mergeRow(s, row, 1, 7); // B:H — label spans the full band
      _c(
        s,
        'I$row',
        FormulaCellValue(_xls(sr.formula, cellOf, 'I', sumExpr, secCells)),
        _style(
          bold: true,
          border: true,
          h: HorizontalAlign.Right,
          numberFormat: _money,
          bg: bg,
          fg: fg,
        ),
      );
      cellOf[sr.no.toUpperCase()] = row;
      row++;
    }

    // ABC back-reference → last summary row
    _c(
      s,
      'G${b0 + 3}',
      FormulaCellValue('I${row - 1}'),
      _style(
        bold: true,
        border: true,
        h: HorizontalAlign.Right,
        numberFormat: _money,
      ),
    );

    row += 4;
    _signatureBlock(s, row);
  }

  // ------------------------------- POW -------------------------------------

  void _writePow(Sheet s) {
    // Column split mirrors the original template: wide WORK ITEM lives
    // in C while A+B is wide enough to box the project labels
    // ("PHYSICAL TARGET:" needs ~20 units).
    s.setColumnWidth(0, 10);
    s.setColumnWidth(1, 11.5);
    s.setColumnWidth(2, 34.5);
    s.setColumnWidth(3, 9.6);
    s.setColumnWidth(4, 8);
    s.setColumnWidth(5, 8.3);
    s.setColumnWidth(6, 18); // G amounts + summary values
    s.setColumnWidth(7, 14);

    // same letterhead-driven layout as the BOQ: everything hangs off the
    // letterhead end (default 5 lines → block at 13, header at 21)
    final lhEnd = _officeHeader(s, startRow: 6, lastCol: 7);
    _navyRule(s, lhEnd, 7);
    final b0 = lhEnd + 2; // project block start (13 w/ default letterhead)

    final p = est.project;
    // Project block rows b0..b0+4 — every cell boxed like the original
    // template (label A:B, value C:D, right pair E:F + G:H).
    final box = _style(border: true);
    final boxB = _style(border: true, bold: true);
    void infoRow(
      int r,
      String lbl,
      String val, {
      String? rlbl,
      String? rval,
      bool wide = false,
    }) {
      _band(s, r, 7, box);
      _mergeRow(s, r, 0, 1);
      _c(s, 'A$r', TextCellValue(lbl), boxB);
      _mergeRow(s, r, 2, wide ? 7 : 3);
      _c(s, 'C$r', TextCellValue(val), box);
      if (rlbl != null) {
        _mergeRow(s, r, 4, 5);
        _c(s, 'E$r', TextCellValue(rlbl), boxB);
        _mergeRow(s, r, 6, 7);
        _c(s, 'G$r', TextCellValue(rval ?? ''), box);
      }
    }

    infoRow(b0, 'PROJECT TITLE:', p.title, wide: true);
    infoRow(
      b0 + 1,
      'LOCATION:',
      p.location,
      rlbl: 'DATE:',
      rval: DateFormat('MMMM d, yyyy').format(p.date),
    );
    infoRow(
      b0 + 2,
      'DIVISION:',
      p.division,
      rlbl: 'CD:',
      rval: p.contractDuration,
    );
    infoRow(b0 + 3, 'SOURCE OF FUND:', p.sourceOfFund, rlbl: 'ABC:');
    infoRow(b0 + 4, 'PHYSICAL TARGET:', p.physicalTarget, wide: true);

    _mergeRow(s, b0 + 6, 0, 6);
    _c(
      s,
      'A${b0 + 6}',
      TextCellValue('PROGRAM OF WORKS'),
      _style(bold: true, fontSize: 14),
    );

    // accent header band, matching the BOQ table header
    final hStyle = _style(
      bold: true,
      border: true,
      wrap: true,
      h: HorizontalAlign.Center,
      bg: _hex(p.themeColor),
      fg: _fgOn(p.themeColor),
    );
    // two-row header (rows b0+8..b0+9), each title merged down like the template
    final hdr = b0 + 8;
    _band(s, hdr, 7, hStyle);
    _band(s, hdr + 1, 7, hStyle);
    for (final c in 'ADEFGH'.split('')) {
      _mergeRange(s, '$c$hdr:$c${hdr + 1}');
    }
    _mergeRange(s, 'B$hdr:C${hdr + 1}');
    _c(s, 'A$hdr', TextCellValue('ITEM NO.'), hStyle);
    _c(s, 'B$hdr', TextCellValue('WORK ITEM'), hStyle);
    _c(s, 'D$hdr', TextCellValue('% TOTAL'), hStyle);
    _c(s, 'E$hdr', TextCellValue('UNIT'), hStyle);
    _c(s, 'F$hdr', TextCellValue('QTY'), hStyle);
    _c(s, 'G$hdr', TextCellValue('TOTAL'), hStyle);
    _c(s, 'H$hdr', TextCellValue('REMARKS'), hStyle);

    // find BOQ section/subtotal rows: recompute layout the same way _writeBoq did
    final boqSubtotal = _boqSubtotalRows();

    var row = hdr + 2;
    final firstRow = row;
    final directCostRow = firstRow + est.sections.length + 2;
    final center = _style(border: true, h: HorizontalAlign.Center);
    final money = _style(
      border: true,
      h: HorizontalAlign.Right,
      numberFormat: _money,
    );
    final pct = _style(
      border: true,
      h: HorizontalAlign.Center,
      numberFormat: '0.00%',
    );
    for (var i = 0; i < est.sections.length; i++) {
      final sec = est.sections[i];
      _c(s, 'A$row', TextCellValue(String.fromCharCode(65 + i)), center);
      _c(s, 'B$row', TextCellValue(sec.title), _style(border: true));
      _mergeRow(s, row, 1, 2);
      _c(s, 'D$row', FormulaCellValue('G$row/G$directCostRow'), pct);
      _c(s, 'E$row', TextCellValue('lot'), center);
      _c(s, 'F$row', DoubleCellValue(1), center);
      _c(s, 'G$row', FormulaCellValue('BOQ!I${boqSubtotal[i]}'), money);
      _c(s, 'H$row', TextCellValue(sec.remark), _style(border: true));
      row++;
    }
    final lastSec = row - 1;
    final spare = _style(border: true);
    _band(s, row, 7, spare); // spare row keeps the grid running
    _mergeRow(s, row, 1, 2);
    row++;
    final sumLabel = _style(bold: true, border: true);
    _band(s, row, 7, sumLabel);
    _mergeRow(s, row, 0, 7);
    _c(s, 'A$row', TextCellValue('SUMMARY:'), sumLabel);
    row++;
    final cellOf = <String, int>{};
    final powSum = 'SUM(G$firstRow:G$lastSec)';
    // Section letters → the section's work-item row in POW column G.
    final secCells = <String, String>{
      for (var i = 0; i < est.sections.length && i < 26; i++)
        String.fromCharCode(65 + i): 'G${firstRow + i}',
    };
    for (final sr in est.summaryRows) {
      // last summary row = accent GRAND TOTAL bar like the app
      final isLast = identical(sr, est.summaryRows.last);
      final band = isLast ? p.themeColor : p.summaryColor;
      final bg = _hex(band);
      final fg = _fgOn(band);
      _band(s, row, 7, _style(border: true, bg: bg));
      _c(
        s,
        'A$row',
        TextCellValue(sr.no),
        _style(
          bold: true,
          border: true,
          h: HorizontalAlign.Center,
          bg: bg,
          fg: fg,
        ),
      );
      _c(
        s,
        'B$row',
        TextCellValue(sr.label),
        _style(bold: true, border: true, bg: bg, fg: fg),
      );
      _mergeRow(s, row, 1, 5); // B:F label span so long labels fit
      _c(
        s,
        'G$row',
        FormulaCellValue(_xls(sr.formula, cellOf, 'G', powSum, secCells)),
        _style(
          bold: true,
          border: true,
          h: HorizontalAlign.Right,
          numberFormat: _money,
          bg: bg,
          fg: fg,
        ),
      );
      cellOf[sr.no.toUpperCase()] = row;
      row++;
    }
    _c(
      s,
      'G${b0 + 3}',
      FormulaCellValue('G${row - 1}'),
      _style(
        bold: true,
        border: true,
        h: HorizontalAlign.Right,
        numberFormat: _money,
      ),
    );

    row += 3;
    _signatureBlock(s, row);
  }

  /// Translates an app formula ("I*7%", "SECTIONS") into an Excel formula:
  /// identifiers matching summary rows become `[col][excelRow]` refs;
  /// SECTIONS/TOTAL/DIRECT expand to [sumExpr]; section letters resolve
  /// through [secCells] (e.g. A → the subtotal cell of section A).
  static String _xls(
    String src,
    Map<String, int> cellOf,
    String col,
    String sumExpr,
    Map<String, String> secCells,
  ) {
    var f = src.trim();
    if (f.startsWith('=')) f = f.substring(1);
    final out = f.replaceAllMapped(RegExp(r'[A-Za-z_]+'), (m) {
      final id = m[0]!.toUpperCase();
      if (id == 'SECTIONS' || id == 'TOTAL' || id == 'DIRECT') {
        return '($sumExpr)';
      }
      final r = cellOf[id];
      if (r != null) return '$col$r';
      return secCells[id] ?? '0';
    });
    return out;
  }

  /// Row numbers of each section's SUB TOTAL cell in BOQ, mirroring
  /// _writeBoq's letterhead-driven layout (first data row is hdr+2 =
  /// letterhead length + 22).
  List<int> _boqSubtotalRows() {
    final rows = <int>[];
    var row = est.project.effLetterhead.length + 22;
    for (final sec in est.sections) {
      row += 1 + sec.lines.length;
      rows.add(row);
      row++;
    }
    return rows;
  }

  // ----------------------------- PERT-CPM ---------------------------------

  /// The activity table — a live, Excel-editable CPM: DAYS and
  /// PREDECESSORS are plain values the user can change, and ES/EF/LS/LF/
  /// SLACK are real formulas (ES=MAX of pred EF, EF=ES+DAYS, LS=LF-DAYS,
  /// LF=MIN of succ LS or the project-duration cell, SLACK=LS-ES) — the
  /// same convention the division's template uses. Returns the 1-based
  /// row number of the first activity row so PERT-NETWORK can reference
  /// it with cross-sheet formulas.
  int _writePertCpm(Sheet s, CpmResult r) {
    for (var c = 0; c < _pertW.length; c++) {
      s.setColumnWidth(c, _pertW[c]);
    }
    final p = est.project;
    final lhEnd = _officeHeader(s, startRow: 5, lastCol: 11);
    _navyRule(s, lhEnd, 11);
    final title = lhEnd + 2;
    _mergeRow(s, title, 0, 11);
    _c(
      s,
      'A$title',
      TextCellValue(
        'Program Evaluation and Review Technique (PERT) '
        '& Critical Path Method (CPM)',
      ),
      _style(bold: true, fontSize: 11, h: HorizontalAlign.Center),
    );
    final info = title + 1;
    _mergeRow(s, info, 0, 7);
    _c(
      s,
      'A$info',
      TextCellValue('I. ${p.title}   CD: ${p.contractDuration}'),
      _style(bold: true, fontSize: 10),
    );
    _mergeRow(s, info, 8, 11);
    _c(
      s,
      'I$info',
      TextCellValue(
        p.unworkableDays > 0
            ? 'CALENDAR DAYS (incl. ${p.unworkableDays} unworkable)'
            : 'CALENDAR DAYS',
      ),
      _style(bold: true, fontSize: 10, h: HorizontalAlign.Right),
    );

    final th = info + 2;
    final head = _style(
      bold: true,
      border: true,
      bg: _hex(p.themeColor),
      fg: _fgOn(p.themeColor),
      h: HorizontalAlign.Center,
      fontSize: 10,
    );
    _band(s, th, 11, head);
    _c(s, 'A$th', TextCellValue('ACT'), head);
    _mergeRow(s, th, 1, 3);
    _c(s, 'B$th', TextCellValue('ACTIVITY'), head);
    _c(s, 'E$th', TextCellValue('DAYS'), head);
    _mergeRow(s, th, 5, 6);
    _c(s, 'F$th', TextCellValue('PREDECESSORS'), head);
    _c(s, 'H$th', TextCellValue('ES'), head);
    _c(s, 'I$th', TextCellValue('EF'), head);
    _c(s, 'J$th', TextCellValue('LS'), head);
    _c(s, 'K$th', TextCellValue('LF'), head);
    _c(s, 'L$th', TextCellValue('SLACK'), head);

    final firstData = th + 1;
    var row = firstData;
    final bad = r.error != null;
    // successors per activity index, for LF = MIN(successor LS)
    final succs = <int, List<int>>{};
    for (var i = 0; i < r.nodes.length; i++) {
      for (final pi in r.nodes[i].predIdx) {
        (succs[pi] ??= []).add(i);
      }
    }
    final durRow = firstData + est.activities.length;
    for (var i = 0; i < est.activities.length; i++) {
      final a = est.activities[i];
      final n = i < r.nodes.length ? r.nodes[i] : null;
      final crit = n?.critical ?? false;
      final band = crit ? _hex(p.subtotalColor) : null;
      CellStyle cellSt(HorizontalAlign h) =>
          _style(border: true, bg: band, h: h, fontSize: 10);
      _band(s, row, 11, _style(border: true, bg: band));
      _c(
        s,
        'A$row',
        TextCellValue(cpmLetter(i)),
        _style(
          border: true,
          bold: true,
          bg: band,
          h: HorizontalAlign.Center,
          fontSize: 10,
        ),
      );
      _mergeRow(s, row, 1, 3);
      _c(
        s,
        'B$row',
        TextCellValue(a.name),
        _style(border: true, bold: true, bg: band, fontSize: 10),
      );
      _c(s, 'E$row', DoubleCellValue(a.days), cellSt(HorizontalAlign.Center));
      _mergeRow(s, row, 5, 6);
      _c(s, 'F$row', TextCellValue(a.preds), cellSt(HorizontalAlign.Center));
      if (bad || n == null) {
        for (final col in ['H', 'I', 'J', 'K', 'L']) {
          _c(s, '$col$row', TextCellValue(''), cellSt(HorizontalAlign.Center));
        }
      } else {
        // live formulas so edits in Excel recompute the whole network
        final predRows = n.predIdx.map((pi) => firstData + pi).toList();
        _c(
          s,
          'H$row',
          predRows.isEmpty
              ? DoubleCellValue(0)
              : FormulaCellValue(
                  'MAX(${predRows.map((x) => 'I$x').join(',')})',
                ),
          cellSt(HorizontalAlign.Center),
        );
        _c(
          s,
          'I$row',
          FormulaCellValue('H$row+E$row'),
          cellSt(HorizontalAlign.Center),
        );
        _c(
          s,
          'J$row',
          FormulaCellValue('K$row-E$row'),
          cellSt(HorizontalAlign.Center),
        );
        final su = succs[i] ?? const <int>[];
        _c(
          s,
          'K$row',
          su.isEmpty
              ? FormulaCellValue('\$K\$$durRow')
              : FormulaCellValue(
                  'MIN(${su.map((x) => 'J${firstData + x}').join(',')})',
                ),
          cellSt(HorizontalAlign.Center),
        );
        _c(
          s,
          'L$row',
          FormulaCellValue('J$row-H$row'),
          cellSt(HorizontalAlign.Center),
        );
      }
      row++;
    }
    // project-duration cell every terminal node's LF points at
    _mergeRow(s, durRow, 0, 9);
    _c(
      s,
      'A$durRow',
      TextCellValue('PROJECT DURATION (CRITICAL PATH ${r.criticalPath}):'),
      _style(bold: true, fontSize: 10, h: HorizontalAlign.Right),
    );
    _c(
      s,
      'K$durRow',
      bad
          ? TextCellValue('')
          : FormulaCellValue('MAX(I$firstData:I${durRow - 1})'),
      _style(
        bold: true,
        border: true,
        h: HorizontalAlign.Center,
        bg: _hex(p.subtotalColor),
      ),
    );
    _mergeRow(s, durRow, 11, 11);
    _c(s, 'L$durRow', TextCellValue('CD'), _style(bold: true, fontSize: 10));
    row = durRow + 1;
    if (bad) {
      _mergeRow(s, row, 0, 11);
      _c(
        s,
        'A$row',
        TextCellValue(r.error!),
        _style(italic: true, fg: 'FFCC0000'),
      );
      return firstData;
    }

    _mergeRow(s, row, 0, 11);
    _c(
      s,
      'A$row',
      TextCellValue(
        'A activity   T time   ES Earliest Start   '
        'EF Earliest Finish   LS Latest Start   LF Latest Finish   '
        '→ Network diagram on the PERT-NETWORK sheet',
      ),
      _style(italic: true, fontSize: 9, h: HorizontalAlign.Center),
    );
    row += 2;
    if (r.criticalPath.isNotEmpty) {
      _mergeRow(s, row, 0, 11);
      _c(
        s,
        'A$row',
        TextCellValue(
          '1.) Any delay in the ${r.criticalPath} path will cause a '
          'delay in the entire project\'s completion, as it is the '
          'critical path with zero slack.',
        ),
        _style(fontSize: 10),
      );
      row++;
    }
    final nonCrit = r.nodes.where((n) => !n.critical).toList();
    if (nonCrit.isNotEmpty) {
      _mergeRow(s, row, 0, 11);
      _c(
        s,
        'A$row',
        TextCellValue(
          '2.) Activities ${nonCrit.map((n) => n.letter).join(', ')} '
          'have slack — they may be delayed without affecting the '
          'overall timeline.',
        ),
        _style(fontSize: 10),
      );
      row++;
    }
    row += 2;
    _signatureBlock(s, row, rightCol: 6, rightSpan: 4);
    return firstData;
  }

  static const _pertW = <double>[5, 16.5, 16.5, 16.5, 8, 8, 8, 7, 7, 7, 7, 8];

  // ---------------------------- PERT-NETWORK -------------------------------

  /// Column widths for the diagram sheet: col 0 carries START labels,
  /// each level gets 3 box columns + 2 gap columns for the connectors.
  List<double> _netWidths(CpmResult r) {
    final w = <double>[9];
    for (var l = 0; l <= r.maxLevel; l++) {
      w.addAll(const [8, 8, 8]);
      if (l < r.maxLevel) w.addAll(const [2.4, 2.4]);
    }
    w.add(6);
    // a 1-2 level network leaves the signatory band nothing to merge
    // across — pad so the footer keeps its tiling
    while (w.length < 10) {
      w.add(8);
    }
    return w;
  }

  /// The precedence diagram as bordered cell blocks — every value is a
  /// cross-sheet formula into the PERT-CPM table so editing the table in
  /// Excel updates the diagram. Edges are drawn as cell borders routed
  /// through the gap columns and the empty channel row under each band,
  /// so parallel branches read as real parallel lanes.
  void _writePertNetwork(Sheet s, CpmResult r, int firstData) {
    final widths = _netWidths(r);
    for (var c = 0; c < widths.length; c++) {
      s.setColumnWidth(c, widths[c]);
    }
    final lastCol = widths.length - 1;
    final p = est.project;
    final lhEnd = _officeHeader(s, startRow: 5, lastCol: lastCol);
    _navyRule(s, lhEnd, lastCol);
    final title = lhEnd + 2;
    _mergeRow(s, title, 0, lastCol);
    _c(
      s,
      'A$title',
      TextCellValue('NETWORK DIAGRAM — PERT/CPM'),
      _style(bold: true, fontSize: 12, h: HorizontalAlign.Center),
    );
    final info = title + 1;
    final split = lastCol > 6 ? lastCol - 3 : 3;
    _mergeRow(s, info, 0, split - 1);
    _c(
      s,
      'A$info',
      TextCellValue('I. ${p.title}   CD: ${p.contractDuration}'),
      _style(bold: true, fontSize: 10),
    );
    _mergeRow(s, info, split, lastCol);
    _c(
      s,
      '${_colName(split)}$info',
      TextCellValue(
        p.unworkableDays > 0
            ? 'CALENDAR DAYS (incl. ${p.unworkableDays} unworkable)'
            : 'CALENDAR DAYS',
      ),
      _style(bold: true, fontSize: 10, h: HorizontalAlign.Right),
    );

    final d0 = info + 2; // row above the first band doubles as a channel
    const bandH = 5; // 4 box rows + 1 channel row
    int boxTop(int lane) => d0 + lane * bandH;
    int boxCol(int level) => 1 + level * 5;

    final critBorder = Border(
      borderStyle: BorderStyle.Thin,
      borderColorHex: ExcelColor.fromInt(p.themeColor),
    );
    final edgeBorder = Border(
      borderStyle: BorderStyle.Thin,
      borderColorHex: ExcelColor.fromHexString('FF94A3B8'),
    );
    final edgeCritBorder = Border(
      borderStyle: BorderStyle.Medium,
      borderColorHex: ExcelColor.fromInt(p.themeColor),
    );

    CellStyle box({
      bool crit = false,
      bool bold = false,
      bool italic = false,
      int fs = 9,
      HorizontalAlign h = HorizontalAlign.Center,
      VerticalAlign v = VerticalAlign.Center,
    }) {
      final st = _style(
        border: true,
        bold: bold,
        italic: italic,
        fontSize: fs,
        h: h,
        v: v,
        bg: crit ? _hex(p.subtotalColor) : null,
      );
      if (crit) {
        return st.copyWith(
          topBorderVal: critBorder,
          bottomBorderVal: critBorder,
          leftBorderVal: critBorder,
          rightBorderVal: critBorder,
        );
      }
      return st;
    }

    /// Adds a border segment to a cell, preserving whatever is already
    /// drawn on it — edges can cross, so each write must merge.
    void edge(
      int col,
      int row, {
      bool bottom = false,
      bool right = false,
      bool crit = false,
    }) {
      final idx = CellIndex.indexByColumnRow(
        columnIndex: col,
        rowIndex: row - 1,
      );
      final cell = s.cell(idx);
      var st = cell.cellStyle ?? CellStyle();
      final b = crit ? edgeCritBorder : edgeBorder;
      if (bottom) st = st.copyWith(bottomBorderVal: b);
      if (right) st = st.copyWith(rightBorderVal: b);
      cell.cellStyle = st;
    }

    String ref(int tr, String col) => "'PERT-CPM'!$col$tr";

    for (var i = 0; i < r.nodes.length; i++) {
      final n = r.nodes[i];
      final tr = firstData + i;
      final c0 = boxCol(n.level);
      final r0 = boxTop(n.lane);
      for (var dr = 0; dr < 4; dr++) {
        for (var dc = 0; dc < 3; dc++) {
          _c(
            s,
            '${_colName(c0 + dc)}${r0 + dr}',
            TextCellValue(''),
            box(crit: n.critical),
          );
        }
      }
      _c(
        s,
        '${_colName(c0)}$r0',
        TextCellValue('SLACK'),
        box(crit: n.critical, italic: true, fs: 7),
      );
      _c(
        s,
        '${_colName(c0 + 2)}$r0',
        FormulaCellValue(ref(tr, 'L')),
        box(crit: n.critical, fs: 8, h: HorizontalAlign.Right),
      );
      _c(
        s,
        '${_colName(c0)}${r0 + 1}',
        FormulaCellValue(ref(tr, 'A')),
        box(crit: n.critical, bold: true, fs: 11),
      );
      _c(
        s,
        '${_colName(c0 + 1)}${r0 + 1}',
        FormulaCellValue(ref(tr, 'H')),
        box(crit: n.critical, fs: 8),
      );
      _c(
        s,
        '${_colName(c0 + 2)}${r0 + 1}',
        FormulaCellValue(ref(tr, 'I')),
        box(crit: n.critical, fs: 8),
      );
      _c(
        s,
        '${_colName(c0)}${r0 + 2}',
        FormulaCellValue(ref(tr, 'E')),
        box(crit: n.critical, fs: 8),
      );
      _c(
        s,
        '${_colName(c0 + 1)}${r0 + 2}',
        FormulaCellValue(ref(tr, 'J')),
        box(crit: n.critical, fs: 8),
      );
      _c(
        s,
        '${_colName(c0 + 2)}${r0 + 2}',
        FormulaCellValue(ref(tr, 'K')),
        box(crit: n.critical, fs: 8),
      );
      _mergeRow(s, r0 + 3, c0, c0 + 2);
      _c(
        s,
        '${_colName(c0)}${r0 + 3}',
        FormulaCellValue(ref(tr, 'B')),
        box(crit: n.critical, italic: true, fs: 7),
      );
      if (n.level == 0) {
        _c(
          s,
          'A${r0 + 1}',
          TextCellValue('START'),
          _style(bold: true, fontSize: 8),
        );
      }
    }

    // connectors — straight across for adjacent same-lane edges, elbow
    // through the source band's channel row otherwise. Arrowheads are
    // written FIRST so the border pass can merge into the cell's style
    // instead of being overwritten by it.
    for (var i = 0; i < r.nodes.length; i++) {
      final n = r.nodes[i];
      final crit = n.critical;
      final bN = boxTop(n.lane) + 1; // boundary = bottom of this row
      final cN = boxCol(n.level);
      if (n.predIdx.isNotEmpty) {
        _c(
          s,
          '${_colName(cN - 1)}$bN',
          TextCellValue('▸'),
          _style(
            bold: true,
            fontSize: 7,
            v: VerticalAlign.Bottom,
            h: HorizontalAlign.Right,
            fg: crit ? _hex(p.themeColor) : 'FF94A3B8',
          ),
        );
      }
      for (final pi in n.predIdx) {
        final pN = r.nodes[pi];
        final bP = boxTop(pN.lane) + 1;
        final cP = boxCol(pN.level);
        if (n.level == pN.level + 1 && n.lane == pN.lane) {
          for (var c = cP + 3; c <= cN - 1; c++) {
            edge(c, bP, bottom: true, crit: crit);
          }
        } else {
          // out of the source at its mid boundary to the gap bus
          edge(cP + 3, bP, bottom: true, crit: crit);
          // bus down/up to the source channel row
          final chan = bP + 3; // channel row = band bottom row +4
          final chanUp = bP - 2; // channel row above the source band
          if (pN.lane <= n.lane) {
            for (var rr = bP + 1; rr <= chan; rr++) {
              edge(cP + 3, rr, right: true, crit: crit);
            }
          } else {
            for (var rr = chanUp + 1; rr <= bP; rr++) {
              edge(cP + 3, rr, right: true, crit: crit);
            }
          }
          final chanRow = pN.lane <= n.lane ? chan : chanUp;
          // horizontal run along the channel boundary
          for (var c = cP + 4; c <= cN - 2; c++) {
            edge(c, chanRow, bottom: true, crit: crit);
          }
          // drop/rise into the target's gap bus then in
          if (n.lane > pN.lane) {
            for (var rr = chanRow + 1; rr <= bN; rr++) {
              edge(cN - 2, rr, right: true, crit: crit);
            }
          } else if (n.lane < pN.lane) {
            for (var rr = bN + 1; rr <= chanRow; rr++) {
              edge(cN - 2, rr, right: true, crit: crit);
            }
          }
          edge(cN - 1, bN, bottom: true, crit: crit);
        }
      }
    }

    var row = d0 + r.laneCount * bandH + 1;
    _mergeRow(s, row, 0, lastCol);
    _c(
      s,
      'A$row',
      TextCellValue(
        'CRITICAL PATH ${r.criticalPath}   PROJECT DURATION: '
        '${r.duration.toStringAsFixed(0)} CALENDAR DAYS'
        '${p.unworkableDays > 0 ? ' (+${p.unworkableDays} unworkable = ${(r.duration + p.unworkableDays).toStringAsFixed(0)} CD)' : ''}',
      ),
      _style(bold: true),
    );
    row += 2;
    _mergeRow(s, row, 0, lastCol);
    _c(
      s,
      'A$row',
      TextCellValue(
        'A letter   ES/EF earliest start/finish   '
        'LS/LF latest start/finish   SLACK = LS − ES   '
        'values link to the PERT-CPM table',
      ),
      _style(italic: true, fontSize: 9, h: HorizontalAlign.Center),
    );
    row += 2;
    _signatureRowWide(s, row, lastCol);
  }

  static String _colName(int c) {
    var name = '';
    var x = c;
    while (true) {
      name = String.fromCharCode(65 + x % 26) + name;
      x = x ~/ 26 - 1;
      if (x < 0) break;
    }
    return name;
  }

  // ------------------------------ S-CURVE ---------------------------------

  /// Weekly planned-progress table (cost-weighted from the CPM
  /// schedule); the curve itself is rendered to PNG and anchored under
  /// the table — this returns the 0-based row the image attaches to.
  int _writeSCurve(Sheet s, List<SCurveRow> rows) {
    // Landscape spread: the weekly table sits in A..H and the chart PNG
    // overlays I.._curveLastCol. Every header merge spans the full
    // range so the letterhead, rule and title center over the whole
    // page, not just the table.
    final lastCol = _curveLastCol;
    for (var c = 0; c < _curveW.length; c++) {
      s.setColumnWidth(c, _curveW[c]);
    }
    final p = est.project;
    final lhEnd = _officeHeader(s, startRow: 5, lastCol: lastCol);
    _navyRule(s, lhEnd, lastCol);
    final title = lhEnd + 2;
    _mergeRow(s, title, 0, lastCol);
    _c(
      s,
      'A$title',
      TextCellValue('S-CURVE'),
      _style(bold: true, fontSize: 14, h: HorizontalAlign.Center),
    );
    final info = title + 1;
    _mergeRow(s, info, 0, 12);
    _c(
      s,
      'A$info',
      TextCellValue('I. ${p.title}   CD: ${p.contractDuration}'),
      _style(bold: true, fontSize: 10),
    );
    _mergeRow(s, info, 13, lastCol);
    _c(
      s,
      'N$info',
      TextCellValue('ABC: ${NumberFormat('#,##0.00').format(est.grandTotal)}'),
      _style(bold: true, fontSize: 10, h: HorizontalAlign.Right),
    );

    final th = info + 2;
    final head = _style(
      bold: true,
      border: true,
      bg: _hex(p.themeColor),
      fg: _fgOn(p.themeColor),
      h: HorizontalAlign.Center,
      fontSize: 10,
    );
    _band(s, th, 7, head);
    _c(s, 'A$th', TextCellValue(est.scurveBucket.label), head);
    _mergeRow(s, th, 1, 3);
    _c(s, 'B$th', TextCellValue('PERIOD (CALENDAR DAYS)'), head);
    _mergeRow(s, th, 4, 5);
    _c(s, 'E$th', TextCellValue('PLANNED'), head);
    _c(s, 'G$th', TextCellValue('THIS ${est.scurveBucket.label}'), head);
    _c(s, 'H$th', TextCellValue('CUMULATIVE'), head);

    var row = th + 1;
    const pct = '0.00%';
    for (final r in rows) {
      _band(s, row, 7, _style(border: true));
      _c(
        s,
        'A$row',
        TextCellValue('${r.tag}${r.week}'),
        _style(border: true, bold: true, h: HorizontalAlign.Center),
      );
      _mergeRow(s, row, 1, 3);
      _c(
        s,
        'B$row',
        TextCellValue(
          r.fromDay == r.toDay
              ? 'Day ${r.fromDay}'
              : 'Days ${r.fromDay} – ${r.toDay}',
        ),
        _style(border: true, h: HorizontalAlign.Center),
      );
      _mergeRow(s, row, 4, 5);
      _c(
        s,
        'E$row',
        DoubleCellValue(r.pct * est.grandTotal),
        _style(border: true, h: HorizontalAlign.Right, numberFormat: _money),
      );
      _c(
        s,
        'G$row',
        DoubleCellValue(r.pct),
        _style(border: true, h: HorizontalAlign.Right, numberFormat: pct),
      );
      _c(
        s,
        'H$row',
        DoubleCellValue(r.cumPct),
        _style(
          border: true,
          bold: true,
          h: HorizontalAlign.Right,
          numberFormat: pct,
        ),
      );
      row++;
    }
    // Signatories spread across the whole spread, parked below BOTH
    // the table and the chart's bottom edge. Chart: 5.55" ≈ 27 default
    // rows below its anchor at row th -> clear it at th + 30.
    final sigTop = row + 2 > th + 30 ? row + 2 : th + 30;
    _signatureRowWide(s, sigTop, lastCol);
    // the chart anchors beside the table (column I, aligned to the
    // header row) so the sheet reads landscape: table left, chart
    // right — 0-based row index
    return th - 1;
  }

  /// Signatories spread over the full sheet width: up to [perRow] per
  /// 8-row band, each taking an equal share of columns 0..[lastCol] —
  /// label, underlined name and position centered inside its span, so
  /// the block reads centered under the whole landscape spread and a
  /// long name never clips against a neighbor.
  void _signatureRowWide(Sheet s, int row, int lastCol, {int perRow = 5}) {
    final sigs = est.project.effSignatories;
    final w = lastCol + 1;
    for (var start = 0; start < sigs.length; start += perRow) {
      final end = start + perRow < sigs.length ? start + perRow : sigs.length;
      final band = sigs.sublist(start, end);
      final r = row + (start ~/ perRow) * 8;
      for (var i = 0; i < band.length; i++) {
        final c0 = (i * w) ~/ band.length;
        final c1 = ((i + 1) * w) ~/ band.length - 1;
        final sig = band[i];
        _mergeRow(s, r, c0, c1);
        _c(
          s,
          '${_colName(c0)}$r',
          TextCellValue('${sig.label}:'),
          _style(h: HorizontalAlign.Center),
        );
        _mergeRow(s, r + 3, c0, c1);
        _c(
          s,
          '${_colName(c0)}${r + 3}',
          TextCellValue(sig.name),
          _style(
            bold: true,
            underline: Underline.Single,
            h: HorizontalAlign.Center,
          ),
        );
        _mergeRow(s, r + 4, c0, c1);
        _c(
          s,
          '${_colName(c0)}${r + 4}',
          TextCellValue(sig.position),
          _style(h: HorizontalAlign.Center),
        );
      }
    }
  }

  static const _curveW = <double>[8, 9, 9, 11, 12, 12, 12, 14];

  /// Chart PNG placement on the S-CURVE sheet (shared by `_injectMedia`
  /// and the header-span math so they can never drift apart): anchored
  /// at column [_curveChartCol] (right of the weekly table), 9.84" x
  /// 5.55" (EMU).
  static const _curveChartCol = 8;
  static const _curveChartColOff = 60000;
  static const _curveChartCx = 9000000;
  static const _curveChartCy = 5072727;

  /// Rightmost column of the S-curve spread = the column holding the
  /// chart's right edge (table columns use `_curveW`; every later
  /// column is the Excel default ≈ 64 px; 1 px = 9525 EMU). Letterhead,
  /// rule, title and signatories merge across 0.._curveLastCol so they
  /// center over table + chart, not just the table.
  static final int _curveLastCol = () {
    final chartEndPx = (_curveChartColOff + _curveChartCx) / 9525;
    return _curveChartCol - 1 + (chartEndPx / 64).ceil();
  }();

  /// Column widths used to center the logo over the whole S-curve
  /// spread (cols 8+ keep the Excel default = 64px = 64/7 units).
  static final _curveAnchorW = <num>[
    ..._curveW,
    for (var i = _curveW.length; i <= _curveLastCol; i++) 64 / 7,
  ];

  // ------------------------------- DATA ------------------------------------

  void _writeData(Sheet s) {
    s.setColumnWidth(0, 28);
    s.setColumnWidth(1, 60);
    s.setColumnWidth(2, 12);
    s.setColumnWidth(3, 12);
    s.setColumnWidth(4, 8);
    _c(s, 'B2', TextCellValue('DETAILED WORK/ITEM'), _style(bold: true));
    _c(s, 'C2', TextCellValue('PRICE'), _style(bold: true));
    _c(s, 'C3', TextCellValue('MATERIAL'), _style(bold: true));
    _c(s, 'D3', TextCellValue('LABOR'), _style(bold: true));
    var row = 4;
    var lastCat = '';
    for (final m in est.priceDb) {
      if (m.category != lastCat) {
        _c(s, 'A$row', TextCellValue(m.category), _style(bold: true));
        lastCat = m.category;
      }
      _c(s, 'B$row', TextCellValue(m.name));
      _c(s, 'C$row', DoubleCellValue(m.price), _style(numberFormat: _money));
      _c(
        s,
        'D$row',
        FormulaCellValue('C$row*${est.laborRate}'),
        _style(numberFormat: _money),
      );
      _c(s, 'E$row', TextCellValue(m.unit));
      row++;
    }
  }
}
