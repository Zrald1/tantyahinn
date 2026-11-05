import 'dart:ffi';

import 'package:ffi/ffi.dart';

/// Positioned character pulled out of a PDF page.
class _Ch {
  final int code;
  final double left, right, bottom, top;
  const _Ch(this.code, this.left, this.right, this.bottom, this.top);
}

// pdfium C API — stable ABI, types are opaque pointers.
final class FpdfLibraryConfig extends Struct {
  @Int32()
  external int version;
  external Pointer<Pointer<Utf8>> userFontPaths;
  external Pointer isolate;
  @Uint32()
  external int v8EmbedderSlot;
  external Pointer platform;
}

typedef _InitLibC = Void Function(Pointer<FpdfLibraryConfig> config);
typedef _InitLibD = void Function(Pointer<FpdfLibraryConfig> config);
typedef _LoadDocC = Pointer Function(Pointer<Utf8> path, Pointer<Utf8> pw);
typedef _LoadDocD = Pointer Function(Pointer<Utf8> path, Pointer<Utf8> pw);
typedef _CloseDocC = Void Function(Pointer doc);
typedef _CloseDocD = void Function(Pointer doc);
typedef _PageCountC = Int32 Function(Pointer doc);
typedef _PageCountD = int Function(Pointer doc);
typedef _LoadPageC = Pointer Function(Pointer doc, Int32 index);
typedef _LoadPageD = Pointer Function(Pointer doc, int index);
typedef _ClosePageC = Void Function(Pointer page);
typedef _ClosePageD = void Function(Pointer page);
typedef _TextLoadPageC = Pointer Function(Pointer page);
typedef _TextLoadPageD = Pointer Function(Pointer page);
typedef _TextClosePageC = Void Function(Pointer tp);
typedef _TextClosePageD = void Function(Pointer tp);
typedef _CountCharsC = Int32 Function(Pointer tp);
typedef _CountCharsD = int Function(Pointer tp);
typedef _GetUnicodeC = Uint32 Function(Pointer tp, Int32 index);
typedef _GetUnicodeD = int Function(Pointer tp, int index);
typedef _CharBoxC =
    Int32 Function(
      Pointer tp,
      Int32 index,
      Pointer<Double> left,
      Pointer<Double> right,
      Pointer<Double> bottom,
      Pointer<Double> top,
    );
typedef _CharBoxD =
    int Function(
      Pointer tp,
      int index,
      Pointer<Double> left,
      Pointer<Double> right,
      Pointer<Double> bottom,
      Pointer<Double> top,
    );

/// Text extraction via the pdfium.dll already shipped next to the app
/// (bundled by the pdfx viewer plugin). pdfx only renders — this thin
/// wrapper pulls positioned characters so BOQ tables can be rebuilt
/// into rows for [BoqImport.rowsToSections].
class PdfText {
  static DynamicLibrary? _lib;

  static DynamicLibrary _open() {
    if (_lib != null) return _lib!;
    final candidates = <String>[
      'pdfium.dll', // beside the exe (Release) / loader search path
      'build/windows/x64/pdfium-src/x64/bin/pdfium.dll',
      'build/windows/x64/runner/Debug/pdfium.dll',
      'build/windows/x64/runner/Release/pdfium.dll',
      'tool/pdfium/pdfium.dll',
    ];
    for (final c in candidates) {
      try {
        _lib = DynamicLibrary.open(c);
        return _lib!;
      } catch (_) {}
    }
    throw StateError('pdfium.dll not found — PDF import unavailable.');
  }

  static _InitLibD? _initLib;
  static _LoadDocD? _loadDoc;
  static _CloseDocD? _closeDoc;
  static _PageCountD? _pageCount;
  static _LoadPageD? _loadPage;
  static _ClosePageD? _closePage;
  static _TextLoadPageD? _textLoadPage;
  static _TextClosePageD? _textClosePage;
  static _CountCharsD? _countChars;
  static _GetUnicodeD? _getUnicode;
  static _CharBoxD? _charBox;

  static bool _inited = false;

  static void _bind() {
    final l = _open();
    _initLib ??= l.lookupFunction<_InitLibC, _InitLibD>(
      'FPDF_InitLibraryWithConfig',
    );
    if (!_inited) {
      final cfg = calloc<FpdfLibraryConfig>();
      cfg.ref
        ..version = 2
        ..userFontPaths = nullptr
        ..isolate = nullptr
        ..v8EmbedderSlot = 0
        ..platform = nullptr;
      try {
        _initLib!(cfg);
        _inited = true;
      } finally {
        calloc.free(cfg);
      }
    }
    _loadDoc ??= l.lookupFunction<_LoadDocC, _LoadDocD>('FPDF_LoadDocument');
    _closeDoc ??= l.lookupFunction<_CloseDocC, _CloseDocD>(
      'FPDF_CloseDocument',
    );
    _pageCount ??= l.lookupFunction<_PageCountC, _PageCountD>(
      'FPDF_GetPageCount',
    );
    _loadPage ??= l.lookupFunction<_LoadPageC, _LoadPageD>('FPDF_LoadPage');
    _closePage ??= l.lookupFunction<_ClosePageC, _ClosePageD>(
      'FPDF_ClosePage',
    );
    _textLoadPage ??= l.lookupFunction<_TextLoadPageC, _TextLoadPageD>(
      'FPDFText_LoadPage',
    );
    _textClosePage ??= l.lookupFunction<_TextClosePageC, _TextClosePageD>(
      'FPDFText_ClosePage',
    );
    _countChars ??= l.lookupFunction<_CountCharsC, _CountCharsD>(
      'FPDFText_CountChars',
    );
    _getUnicode ??= l.lookupFunction<_GetUnicodeC, _GetUnicodeD>(
      'FPDFText_GetUnicode',
    );
    _charBox ??= l.lookupFunction<_CharBoxC, _CharBoxD>('FPDFText_GetCharBox');
  }

  /// True when pdfium is resolvable on this machine — lets callers hide
  /// PDF from the import menu instead of failing on pick.
  static bool get available {
    try {
      _bind();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Every positioned character on [pageIndex] (0-based).
  static List<_Ch> _pageChars(Pointer page) {
    final tp = _textLoadPage!(page);
    try {
      final n = _countChars!(tp);
      final out = <_Ch>[];
      final l = calloc<Double>(), r = calloc<Double>();
      final b = calloc<Double>(), t = calloc<Double>();
      try {
        for (var i = 0; i < n; i++) {
          final ok = _charBox!(tp, i, l, r, b, t);
          final code = _getUnicode!(tp, i);
          if (ok == 0) continue;
          out.add(_Ch(code, l.value, r.value, b.value, t.value));
        }
      } finally {
        calloc.free(l);
        calloc.free(r);
        calloc.free(b);
        calloc.free(t);
      }
      return out;
    } finally {
      _textClosePage!(tp);
    }
  }

  /// Cluster chars into text lines (same baseline), then split each
  /// line into cells at horizontal gaps — emits the same
  /// `List<List<String>>` shape the Excel/CSV extractors produce.
  static List<List<String>> _charsToRows(List<_Ch> chars) {
    if (chars.isEmpty) return [];
    // median char width → cell-gap threshold
    final widths = chars.map((c) => c.right - c.left).where((w) => w > 0).toList()
      ..sort();
    final median = widths.isEmpty ? 4.0 : widths[widths.length ~/ 2];
    final gap = median * 2.2 < 3.0 ? 3.0 : median * 2.2;

    // group by baseline (bottom), tolerance = 40% of height
    final sorted = [...chars]..sort((a, b) => b.bottom.compareTo(a.bottom));
    final lines = <List<_Ch>>[];
    for (final c in sorted) {
      final h = (c.top - c.bottom).abs();
      final tol = (h * 0.4).clamp(1.0, 6.0);
      final line = lines.lastOrNull;
      if (line != null &&
          (line.first.bottom - c.bottom).abs() <=
              tol + (line.first.top - line.first.bottom).abs() * 0.4) {
        line.add(c);
      } else {
        lines.add([c]);
      }
    }

    final rows = <List<String>>[];
    for (final line in lines) {
      line.sort((a, b) => a.left.compareTo(b.left));
      final cells = <String>[];
      final buf = StringBuffer();
      double? prevRight;
      for (final c in line) {
        if (prevRight != null && c.left - prevRight > gap) {
          cells.add(buf.toString().trim());
          buf.clear();
        }
        final ch = String.fromCharCode(c.code);
        buf.write(ch);
        prevRight = c.right > (prevRight ?? -1e9) ? c.right : prevRight;
      }
      cells.add(buf.toString().trim());
      if (cells.any((c) => c.isNotEmpty)) rows.add(cells);
    }
    return rows;
  }

  /// Extract every page's text as table rows, in reading order.
  static Future<List<List<String>>> extractRows(String path) async {
    _bind();
    final cPath = path.toNativeUtf8();
    Pointer doc = nullptr;
    try {
      doc = _loadDoc!(cPath, nullptr);
      if (doc == nullptr) {
        throw StateError(
          'PDF could not be opened (may be password-protected or corrupt).',
        );
      }
      final rows = <List<String>>[];
      final pages = _pageCount!(doc);
      var textChars = 0;
      for (var i = 0; i < pages; i++) {
        final page = _loadPage!(doc, i);
        if (page == nullptr) continue;
        try {
          final chars = _pageChars(page);
          textChars += chars.length;
          rows.addAll(_charsToRows(chars));
        } finally {
          _closePage!(page);
        }
      }
      if (textChars == 0) {
        throw StateError(
          'No text layer found — the PDF looks like a scan. '
          'Only text-based PDFs can be imported.',
        );
      }
      return rows;
    } finally {
      calloc.free(cPath);
      if (doc != nullptr) _closeDoc!(doc);
    }
  }
}
