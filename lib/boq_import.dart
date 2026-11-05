import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:excel/excel.dart';
import 'package:xml/xml.dart';

import 'models.dart';
import 'pdf_import.dart';

/// Result of parsing an external BOQ file into draft sections.
/// Nothing is committed to [est.sections] until the user confirms in
/// the preview dialog (append vs replace).
class BoqImportResult {
  final List<BoqSection> sections;
  final String source; // e.g. 'sheet BOQ' / 'pages 1-3' / 'table 2'
  final List<String> warnings;

  BoqImportResult(this.sections, {this.source = '', this.warnings = const []});

  int get lineCount => sections.fold(
    0,
    (n, s) => n + s.lines.where((l) => l.kind == BoqLineKind.item).length,
  );
}

/// Imports BOQ tables from xlsx/csv/tsv/docx/pdf into draft
/// [BoqSection]s. The heavy lifting lives in [rowsToSections] — every
/// extractor (Excel cells, CSV fields, docx w:tbl, pdfium text runs)
/// produces `List<List<String>>` rows and shares the same mapping so
/// column detection stays identical across formats.
class BoqImport {
  /// File extensions the picker offers / the dispatcher accepts.
  static const supportedExtensions = [
    'xlsx',
    'xls',
    'csv',
    'tsv',
    'txt',
    'pdf',
    'docx',
  ];

  /// Entry point — route by extension, extract rows, map to sections.
  static Future<BoqImportResult> fromFile(String path) async {
    final ext = path.split('.').last.toLowerCase();
    final bytes = await File(path).readAsBytes();
    switch (ext) {
      case 'xlsx':
      case 'xls':
        return fromExcelBytes(bytes);
      case 'csv':
      case 'tsv':
      case 'txt':
        return fromDelimitedText(
          String.fromCharCodes(bytes),
          delimiter: ext == 'tsv' ? '\t' : null,
        );
      case 'docx':
        return fromDocxBytes(bytes);
      case 'pdf':
        final rows = await PdfText.extractRows(path);
        return _finish(rows, source: 'PDF');
      default:
        throw BoqImportException('Unsupported file type: .$ext');
    }
  }

  // ------------------------------------------------------------------
  // Extractors — produce uniform rows of trimmed strings
  // ------------------------------------------------------------------

  /// .xlsx workbook → rows. Prefers the sheet named like BOQ/ESTIMATE;
  /// otherwise merges every sheet that contains a usable header.
  static BoqImportResult fromExcelBytes(List<int> bytes) {
    Excel xl;
    try {
      xl = Excel.decodeBytes(bytes);
    } catch (e) {
      throw BoqImportException(
        'Could not read workbook ($e). Legacy .xls is not supported — '
        're-save the file as .xlsx and try again.',
      );
    }
    final warnings = <String>[];
    final sections = <BoqSection>[];

    final entries = xl.tables.entries.toList()
      ..sort((a, b) {
        int score(String n) {
          final u = n.toUpperCase();
          if (u.contains('BOQ') || u.contains('ESTIMATE')) return 0;
          if (u == 'DATA' || u.contains('PRICE')) return 2;
          return 1;
        }

        return score(a.key).compareTo(score(b.key));
      });

    for (final t in entries) {
      final rows = [
        for (final row in t.value.rows) [for (final d in row) _cellText(d)],
      ];
      if (t.key.toUpperCase() == 'DATA' || t.key.toUpperCase() == 'POW') {
        continue; // price DB + program sheet are not BOQ lines
      }
      // a sheet only counts as BOQ content when a real column header
      // shows up in its first rows (PERT-CPM/S-CURVE etc. never match)
      final hasHeader = rows
          .take(60)
          .any((r) => _detectHeader(r).desc >= 0);
      if (!hasHeader) continue;
      final r = rowsToSections(rows, source: 'sheet "${t.key}"');
      _merge(sections, r.sections);
      warnings.addAll(r.warnings);
    }
    return BoqImportResult(sections, source: 'Excel workbook', warnings: warnings);
  }

  static String _cellText(Data? d) {
    final v = d?.value;
    if (v == null) return '';
    final s = v.toString().trim();
    // formula cells stringify as '=…' — the cached literal isn't exposed
    return s.startsWith('=') ? '' : s;
  }

  /// CSV / TSV / fixed-text → rows. Auto-detects the delimiter per line
  /// when none is supplied (`,` `;` `\t` or 2+ spaces).
  static BoqImportResult fromDelimitedText(String text, {String? delimiter}) {
    final rows = <List<String>>[];
    for (final raw in const LineSplitter().convert(text)) {
      if (raw.trim().isEmpty) continue;
      final d =
          delimiter ??
          (raw.contains('\t')
              ? '\t'
              : raw.contains(';')
              ? ';'
              : raw.contains(RegExp(r'\s{2,}'))
              ? null
              : ',');
      rows.add(d == null ? _splitWideSpace(raw) : _splitDelimited(raw, d));
    }
    return _finish(rows, source: 'delimited text');
  }

  static List<String> _splitWideSpace(String line) =>
      line.split(RegExp(r'\s{2,}')).map((c) => c.trim()).toList();

  /// Minimal RFC-4180 field splitter — quoted segments may embed the
  /// delimiter and `""` escapes a quote.
  static List<String> _splitDelimited(String line, String d) {
    final cells = <String>[];
    final buf = StringBuffer();
    var inQ = false;
    for (var i = 0; i < line.length; i++) {
      final ch = line[i];
      if (inQ) {
        if (ch == '"') {
          if (i + 1 < line.length && line[i + 1] == '"') {
            buf.write('"');
            i++;
          } else {
            inQ = false;
          }
        } else {
          buf.write(ch);
        }
      } else if (ch == '"') {
        inQ = true;
      } else if (line.startsWith(d, i)) {
        cells.add(buf.toString().trim());
        buf.clear();
        i += d.length - 1;
      } else {
        buf.write(ch);
      }
    }
    cells.add(buf.toString().trim());
    return cells;
  }

  /// .docx → rows. Reads `word/document.xml`, walks every `w:tbl`, and
  /// concatenates `w:t` text inside each `w:tc`. Documents without
  /// tables fall back to one paragraph per row.
  static BoqImportResult fromDocxBytes(List<int> bytes) {
    String xml;
    try {
      final zip = ZipDecoder().decodeBytes(bytes);
      final f = zip.files.firstWhere(
        (f) => f.name == 'word/document.xml',
        orElse: () => throw StateError('no document.xml'),
      );
      xml = String.fromCharCodes(f.content as List<int>);
    } catch (e) {
      throw BoqImportException('Could not read Word document ($e).');
    }
    final doc = XmlDocument.parse(xml);
    final warnings = <String>[];
    final sections = <BoqSection>[];

    Iterable<XmlElement> named(XmlNode n, String local) => n.descendants
        .whereType<XmlElement>()
        .where((e) => e.name.local == local);
    Iterable<XmlElement> kids(XmlElement n, String local) => n.children
        .whereType<XmlElement>()
        .where((e) => e.name.local == local);

    final tables = named(doc, 'tbl').toList();
    var tableNo = 0;
    for (final tbl in tables) {
      tableNo++;
      final rows = <List<String>>[
        for (final tr in kids(tbl, 'tr'))
          [
            for (final tc in kids(tr, 'tc'))
              ..._cellExpand(tc, kids, named),
          ],
      ];
      if (rows.isEmpty) continue;
      // only tables with a real BOQ column header count — the project
      // block, POW, signature and schedule tables never produce one
      final hasHeader = rows
          .take(60)
          .any((r) => _detectHeader(r).desc >= 0);
      if (!hasHeader) continue;
      final r = rowsToSections(rows, source: 'table $tableNo');
      _merge(sections, r.sections);
      warnings.addAll(r.warnings);
    }
    if (sections.isEmpty) {
      warnings.add('No usable BOQ table found in the document.');
    }
    return BoqImportResult(sections, source: 'Word document', warnings: warnings);
  }

  /// One `w:tc` → 1..N cell strings: the concatenated `w:t` text plus
  /// N-1 padding cells when a `w:gridSpan` makes it occupy extra
  /// columns — keeps header rows aligned with data rows.
  static List<String> _cellExpand(
    XmlElement tc,
    Iterable<XmlElement> Function(XmlElement, String) kids,
    Iterable<XmlElement> Function(XmlNode, String) named,
  ) {
    final text = named(tc, 't').map((t) => t.innerText).join().trim();
    var span = 1;
    final tcPr = kids(tc, 'tcPr').firstOrNull;
    if (tcPr != null) {
      final gs = kids(tcPr, 'gridSpan').firstOrNull;
      // attribute names are namespace-qualified — match 'val' in any ns
      span = int.tryParse(
            gs?.getAttribute('val', namespace: '*') ??
                gs?.getAttribute('w:val') ??
                '1',
          ) ??
          1;
    }
    return [text, for (var k = 1; k < span; k++) ''];
  }

  /// Shared tail for extractors that already produced rows.
  static BoqImportResult _finish(
    List<List<String>> rows, {
    required String source,
  }) => rowsToSections(rows, source: source);

  // ------------------------------------------------------------------
  // Row mapper — header detection + section/item classification
  // ------------------------------------------------------------------

  static final _sectionPrefix = RegExp(
    r'^(part|division|section|phase|item)?\s*'
    r'([IVXLCDM]+|[A-Z]|[0-9]+)[\.\)\-:\s]',
    caseSensitive: false,
  );
  static final _stopRow = RegExp(
    r'^(sub[\s\-]?total|total\b|grand\s*total|summary|amount carried|'
    r'direct\s+cost|indirect\s+cost|overhead|contingency|tax\b|vat\b|'
    r'ocm\b|mobiliz|demobiliz|'
    r'prepared by|checked|reviewed|approved|recommending|signature|'
    r'item\s*no\.?|work\s*item|'
    r'page\s+\d|date\s*:|note\s*:|republic of|department of|region\b)',
    caseSensitive: false,
  );

  /// Summary/signature phrases that kill a row no matter which cell
  /// they land in (BOQ summary tail: "I | DIRECT COST | 62,920").
  static final _killAnywhere = RegExp(
    r'^(grand\s*total|sub[\s\-]?total|summary|amount carried|'
    r'direct\s+cost|indirect\s+cost|overhead|contingency|'
    r'total\s+cost|tax\b|vat\b)',
    caseSensitive: false,
  );
  static final _numRe = RegExp(r'^[\$₱]?\s*\(?-?[\d,]*\.?\d+\)?%?$');

  /// Column indices detected from a header row (-1 = absent).
  static ({int desc, int qty, int unit, int mat, int lab, int amount})
  _detectHeader(List<String> cells) {
    var desc = -1, qty = -1, unit = -1, mat = -1, lab = -1, amount = -1;
    var hits = 0;
    var hasCost = false;
    for (var i = 0; i < cells.length; i++) {
      final c = cells[i].toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
      if (c.contains('cost') ||
          c.contains('price') ||
          c.contains('rate') ||
          c.contains('amount') ||
          c.contains('material') ||
          c.contains('labor') ||
          c.contains('labour')) {
        hasCost = true;
      }
      if (c.contains('desc') ||
          c.contains('particular') ||
          c.contains('work item') ||
          c.contains('article')) {
        desc = i;
        hits++;
      } else if (c.contains('qty') ||
          c.contains('quantity') ||
          c == 'no. of' ||
          c.contains('volume') ||
          c == 'area') {
        qty = i;
        hits++;
      } else if ((c.contains('unit') &&
              !c.contains('cost') &&
              !c.contains('price')) ||
          c == 'uom') {
        unit = i;
        hits++;
      } else if (c.contains('material')) {
        if (mat < 0) mat = i;
      } else if (c.contains('labor') || c.contains('labour')) {
        if (lab < 0) lab = i;
      } else if (c.contains('unit cost') ||
          c.contains('unit price') ||
          c.contains('rate')) {
        mat = i; // single unit-cost column maps to material
        hits++;
      }
    }
    // amount column: the LAST 'amount'/'total' cell (the grand-total
    // column trails material/labor totals in the two-pair layout)
    for (var i = cells.length - 1; i >= 0; i--) {
      final c = cells[i].toLowerCase();
      if (c.contains('amount') || c.contains('total')) {
        amount = i;
        break;
      }
    }
    // a BOQ table needs description + qty/unit + a money column — the
    // POW sheet (work item / qty / total / remarks) has no cost column
    // and is rejected here so only real BOQ tables map
    return hits >= 2 && desc >= 0 && hasCost
        ? (desc: desc, qty: qty, unit: unit, mat: mat, lab: lab, amount: amount)
        : (desc: -1, qty: -1, unit: -1, mat: -1, lab: -1, amount: -1);
  }

  /// Second header row carrying 'Material Cost'/'Labor Cost' under a
  /// spanning 'UNIT COST' label — returns the first material/labor pair
  /// (later pairs are totals), or null when the row isn't a sub-header.
  static ({int mat, int lab})? _subHeader(List<String> cells) {
    var mat = -1, lab = -1;
    for (var i = 0; i < cells.length; i++) {
      final c = cells[i].toLowerCase();
      if (c.contains('material')) {
        if (mat < 0) mat = i;
      } else if (c.contains('labor') || c.contains('labour')) {
        if (lab < 0) lab = i;
      }
    }
    return (mat >= 0 || lab >= 0) ? (mat: mat, lab: lab) : null;
  }

  static bool _isNumeric(String s) =>
      _numRe.hasMatch(s.trim()) && s.trim().isNotEmpty;

  static double _num(String s) {
    var t = s.trim().replaceAll(RegExp(r'[\$₱,\s]'), '');
    var neg = false;
    if (t.startsWith('(') && t.endsWith(')')) {
      neg = true;
      t = t.substring(1, t.length - 1);
    }
    if (t.endsWith('%')) t = t.substring(0, t.length - 1);
    final v = double.tryParse(t) ?? 0;
    return neg ? -v : v;
  }

  /// Mostly-uppercase text heuristic (digits/punctuation ignored).
  static bool _shouty(String s) {
    final letters = s.replaceAll(RegExp(r'[^a-zA-Z]'), '');
    if (letters.length < 3) return false;
    final up = letters.replaceAll(RegExp(r'[^A-Z]'), '').length;
    return up / letters.length > 0.75;
  }

  static String _firstText(List<String> cells) =>
      cells.firstWhere((c) => c.isNotEmpty, orElse: () => '');

  static void _merge(List<BoqSection> into, List<BoqSection> add) {
    for (final s in add) {
      final existing = into.indexWhere(
        (x) => x.title.trim().toUpperCase() == s.title.trim().toUpperCase(),
      );
      if (existing >= 0) {
        into[existing].lines.addAll(s.lines);
      } else {
        into.add(s);
      }
    }
  }

  /// The shared table→BOQ mapper. [rows] is any extracted table —
  /// already column-aligned. Detects a header row for column mapping;
  /// falls back to positional heuristics (first long text = desc, next
  /// numeric = qty, short text = unit, trailing numerics = costs).
  static BoqImportResult rowsToSections(
    List<List<String>> rows, {
    String source = '',
  }) {
    final sections = <BoqSection>[];
    final warnings = <String>[];
    var cols = (
      desc: -1,
      qty: -1,
      unit: -1,
      mat: -1,
      lab: -1,
      amount: -1,
    );
    var foundHeader = false;
    var warnedFallback = false;

    BoqSection? current;
    BoqLine? lastItem;

    void ensureSection() {
      current ??= () {
        final s = BoqSection(title: 'IMPORTED ITEMS');
        sections.add(s);
        return s;
      }();
    }

    for (var ri = 0; ri < rows.length; ri++) {
      final cells = [for (final c in rows[ri]) c.trim()];
      if (cells.every((c) => c.isEmpty)) continue;
      final joined = cells.where((c) => c.isNotEmpty).join(' ');

      // Column header row → switch mapping mode on; a following
      // 'Material Cost | Labor Cost' sub-header pins the unit-cost
      // pair (later material/labor columns are line totals).
      if (!foundHeader) {
        final h = _detectHeader(cells);
        if (h.desc >= 0) {
          cols = h;
          foundHeader = true;
          if (ri + 1 < rows.length) {
            final sub = _subHeader(rows[ri + 1]);
            if (sub != null) {
              // the sub-header row is full-width while the main header
              // collapses spanning labels — shift trailing columns by
              // the difference so they line up with data rows
              final shift = rows[ri + 1].length - cells.length;
              if (sub.mat >= 0) {
                cols = (
                  desc: cols.desc,
                  qty: cols.qty,
                  unit: cols.unit,
                  mat: sub.mat,
                  lab: cols.lab,
                  amount: cols.amount,
                );
              }
              if (sub.lab >= 0) {
                cols = (
                  desc: cols.desc,
                  qty: cols.qty,
                  unit: cols.unit,
                  mat: cols.mat,
                  lab: sub.lab,
                  amount: cols.amount,
                );
              }
              if (shift > 0 &&
                  cols.amount > 0 &&
                  cols.amount >= cols.mat) {
                cols = (
                  desc: cols.desc,
                  qty: cols.qty,
                  unit: cols.unit,
                  mat: cols.mat,
                  lab: cols.lab,
                  amount: cols.amount + shift,
                );
              }
              ri++; // consume the sub-header
            }
          }
          continue;
        }
      } else {
        // repeated page-break headers mid-file → skip
        final h = _detectHeader(cells);
        if (h.desc >= 0 &&
            joined.toLowerCase().contains('item') &&
            cells.where((c) => _isNumeric(c)).isEmpty) {
          continue;
        }
      }

      if (_stopRow.hasMatch(_firstText(cells).trim())) continue;
      if (cells.any((c) => _killAnywhere.hasMatch(c.trim()))) continue;

      final numericIdx = <int>[
        for (var i = 0; i < cells.length; i++)
          if (_isNumeric(cells[i])) i,
      ];

      // ---- text-only row → section band or group header ----
      if (numericIdx.isEmpty) {
        // prefer the description column's text (item-no letters live in
        // col A of our own exports); fall back to the first cell
        final text =
            (foundHeader &&
                    cols.desc >= 0 &&
                    cols.desc < cells.length &&
                    cells[cols.desc].isNotEmpty)
            ? cells[cols.desc]
            : _firstText(cells);
        if (text.length < 3) continue;
        if (_sectionPrefix.hasMatch(text)) {
          final s = BoqSection(
            title: text.replaceAll(RegExp(r'\s+'), ' ').toUpperCase(),
          );
          current = s;
          sections.add(s);
          lastItem = null;
        } else if (_shouty(text) && current != null) {
          ensureSection();
          current!.lines.add(BoqLine.header(text));
          lastItem = null;
        } else if (lastItem != null) {
          // wrapped description continuation from the row above
          final li = lastItem;
          li.description = '${li.description} $text'.trim();
        }
        continue;
      }

      // ---- item row ----
      ensureSection();
      String desc;
      double qty = 0, mat = 0, lab = 0;
      String unit = '';

      if (foundHeader) {
        desc = cols.desc < cells.length ? cells[cols.desc] : '';
        if (desc.isEmpty) {
          // our own export writes group headers in col A while the
          // desc column (D) stays empty — treat as a group header
          final t = _firstText(cells);
          if (numericIdx.isEmpty || _shouty(t)) {
            current!.lines.add(BoqLine.header(t));
            lastItem = null;
            continue;
          }
        }
        if (cols.qty >= 0 && cols.qty < cells.length) {
          qty = _num(cells[cols.qty]);
        }
        if (cols.unit >= 0 && cols.unit < cells.length) {
          unit = cells[cols.unit];
        }
        if (cols.mat >= 0 && cols.mat < cells.length) {
          mat = _num(cells[cols.mat]);
        }
        if (cols.lab >= 0 && cols.lab < cells.length) {
          lab = _num(cells[cols.lab]);
        }
        // single unit-cost absent but amount present → derive per-unit
        if (mat == 0 &&
            cols.amount >= 0 &&
            cols.amount < cells.length &&
            qty > 0) {
          final amt = _num(cells[cols.amount]);
          if (amt > 0) mat = amt / qty;
        }
      } else {
        if (!warnedFallback) {
          warnings.add(
            'No header row detected — guessed columns positionally '
            '(desc | qty | unit | costs). Review before confirming.',
          );
          warnedFallback = true;
        }
        // desc = first non-numeric cell; then walk right: qty is the
        // first numeric; unit is the first short text after qty; the
        // remaining numerics are unit cost then amount.
        var di = cells.indexWhere((c) => c.isNotEmpty && !_isNumeric(c));
        if (di < 0) continue;
        desc = cells[di];
        var cursor = di + 1;
        if (cursor < cells.length &&
            cells[cursor].isNotEmpty &&
            !_isNumeric(cells[cursor]) &&
            cells[cursor].length <= 12) {
          unit = cells[cursor];
          cursor++;
        }
        if (cursor < cells.length && _isNumeric(cells[cursor])) {
          qty = _num(cells[cursor]);
          cursor++;
        }
        if (unit.isEmpty &&
            cursor < cells.length &&
            cells[cursor].isNotEmpty &&
            !_isNumeric(cells[cursor])) {
          unit = cells[cursor];
          cursor++;
        }
        final rest = [
          for (var i = cursor; i < cells.length; i++)
            if (_isNumeric(cells[i])) _num(cells[i]),
        ];
        if (rest.isNotEmpty) mat = rest.first;
        if (rest.length >= 2 && qty > 0 && rest.last > rest.first * qty * 1.5) {
          // last looks like a line total — keep first as unit cost
        }
      }

      if (desc.isEmpty) continue;
      if (_stopRow.hasMatch(desc)) continue;

      final line = BoqLine(
        description: desc,
        qty: qty,
        unit: unit,
        materialCost: mat,
        laborCost: lab,
      );
      current!.lines.add(line);
      lastItem = line;
    }

    if (sections.isEmpty) {
      warnings.add('No BOQ rows found${source.isEmpty ? '' : ' in $source'}.');
    }
    return BoqImportResult(
      sections,
      source: source,
      warnings: warnings,
    );
  }
}

class BoqImportException implements Exception {
  final String message;
  BoqImportException(this.message);
  @override
  String toString() => message;
}
