part of 'pdf_export.dart';

/// DRAWINGS appendix for the PDF export — one page per library file.
/// Extracted from pdf_export.dart to keep it under the 1K-line cap;
/// extension members see the class's privates through the part-of
/// library (same pattern as the model_view split).
extension _DrawingPages on PdfExport {
  /// One page per drawing in the library: generated sheets rasterize
  /// from DXF, render PNGs and imported images embed as-is. A file
  /// that can't be read/converted is skipped, never fatal.
  Future<void> _appendDrawingPages(
    pw.Document doc,
    PdfPageFormat landscape,
    pw.EdgeInsets mg,
    pw.MemoryImage? logo,
  ) async {
    // NOTE: bare `est` resolves to the GLOBAL `est` getter in
    // state.dart — must qualify `this.est` (the export's own state).
    for (final d in this.est.drawings) {
      final img = await _drawingImage(d);
      if (img == null) continue;
      doc.addPage(
        pw.Page(
          pageFormat: landscape,
          margin: mg,
          build: (c) => pw.Column(
            children: [
              _letterhead(logo, 720),
              _title('DRAWING — ${_t(d.name.toUpperCase())}', size: 11),
              pw.SizedBox(height: 6),
              pw.Expanded(
                child: pw.Center(
                  child: pw.FittedBox(
                    fit: pw.BoxFit.scaleDown,
                    child: pw.Image(pw.MemoryImage(img)),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }
  }

  /// One library file -> PNG bytes for the appendix: images read raw
  /// (the AI renders and user imports land here), DXF sheets rasterize
  /// through [renderDxfPng], DWGs convert via the bundled LibreDWG
  /// chain when present. Returns null on any failure.
  Future<Uint8List?> _drawingImage(DrawingFile d) async {
    try {
      final f = File(d.path);
      if (!f.existsSync()) return null;
      switch (d.kind) {
        case 'image':
          return f.readAsBytesSync();
        case 'dxf':
          String src;
          try {
            src = f.readAsStringSync();
          } catch (_) {
            src = String.fromCharCodes(f.readAsBytesSync());
          }
          return await renderDxfPng(DxfParser.parse(src));
        case 'dwg':
          final dir = Directory(
            '${Directory.systemTemp.path}/ce_export_dwg/${d.id}',
          );
          final r = await DwgReader.open(d.path, dir, fileId: d.id);
          return await renderDxfPng(r.scene);
      }
    } catch (_) {}
    return null;
  }
}
