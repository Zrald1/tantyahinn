import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'excel_export.dart';
import 'pdf_export.dart';
import 'state.dart';

/// The COMPLETE PROJECT PACKAGE — one .zip holding every deliverable:
///   estimate.xlsx  (BOQ + POW + PERT-CPM + S-CURVE + DATA, editable)
///   estimate.pdf   (print report incl. the drawings appendix)
///   project.boqproj (re-openable project file)
///   drawings/*     (generated DXF sheets, AI render PNGs, imports —
///                   the editable CAD sources the PDF rasterizes)
/// A missing/unreadable drawing file is skipped, never fatal.
class ExportPackage {
  static Future<Uint8List> buildZip(EstimateState est) async {
    final arc = Archive();

    Future<void> put(String name, Future<List<int>?> bytes) async {
      try {
        final b = await bytes;
        if (b != null) arc.addFile(ArchiveFile(name, b.length, b));
      } catch (_) {}
    }

    await put('estimate.xlsx', ExcelExport(est).build());
    await put('estimate.pdf', PdfExport(est).build());
    await put(
      'project.boqproj',
      Future.value(utf8.encode(jsonEncode(est.toJson()))),
    );

    final used = <String>{};
    for (final d in est.drawings) {
      final f = File(d.path);
      if (!f.existsSync()) continue;
      var name = 'drawings/${d.name}';
      var i = 2;
      while (used.contains(name)) {
        final dot = d.name.lastIndexOf('.');
        name = dot > 0
            ? 'drawings/${d.name.substring(0, dot)} ($i)${d.name.substring(dot)}'
            : 'drawings/${d.name} ($i)';
        i++;
      }
      used.add(name);
      try {
        final b = f.readAsBytesSync();
        arc.addFile(ArchiveFile(name, b.length, b));
      } catch (_) {}
    }
    return Uint8List.fromList(ZipEncoder().encode(arc)!);
  }
}
