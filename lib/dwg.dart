import 'dart:convert';
import 'dart:io';

import 'dxf.dart';

/// Dedicated DWG reader.
///
/// No open-source library renders DWG directly, so the reader converts
/// the file to DXF and feeds the app's DxfParser — the conversion is
/// the whole job. Converters are tried in order:
///   1. the bundled LibreDWG `dwg2dxf.exe` (shipped as `dwgconv\` next
///      to the release exe, `tool/dwgconv/` in dev) — fast, offline;
///   2. Autodesk's `accoreconsole.exe` when AutoCAD is installed —
///      highest fidelity but slow (cached so it only runs once per
///      file revision);
///   3. ODA File Converter under `C:\Program Files\ODA` or on PATH.
/// Output goes to a per-file dir under `%TEMP%\ce_dwg\<fileId>` and is
/// reused while the source file is unchanged (mtime+size key).
class DwgResult {
  final DxfScene scene;
  final String engine; // 'libredwg' | 'autocad' | 'oda'
  final String dxfPath;
  const DwgResult(this.scene, this.engine, this.dxfPath);
}

class DwgReadException implements Exception {
  final String message;
  DwgReadException(this.message);
  @override
  String toString() => message;
}

class DwgReader {
  /// Locate the bundled LibreDWG converter: `dwgconv\` beside the exe
  /// in release builds, `tool/dwgconv` from the project root in dev.
  static String? findBundledDwg2Dxf() {
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    for (final d in [
      '$exeDir/dwgconv',
      '${Directory.current.path}/tool/dwgconv',
    ]) {
      final f = File('$d/dwg2dxf.exe');
      if (f.existsSync()) return f.path;
    }
    return null;
  }

  /// Locate `accoreconsole.exe` under C:\Program Files\Autodesk when a
  /// full AutoCAD install is present.
  static String? findAccoreConsole() {
    const roots = [
      r'C:\Program Files\Autodesk',
      r'C:\Program Files (x86)\Autodesk',
    ];
    for (final root in roots) {
      final dir = Directory(root);
      if (!dir.existsSync()) continue;
      for (final sub in dir.listSync(recursive: true)) {
        if (sub is File &&
            sub.path.toLowerCase().endsWith('accoreconsole.exe')) {
          return sub.path;
        }
      }
    }
    return null;
  }

  /// Locate ODA File Converter (installs under C:\Program Files\ODA).
  static String? findOdaConverter() {
    const root = r'C:\Program Files\ODA';
    final dir = Directory(root);
    if (dir.existsSync()) {
      for (final sub in dir.listSync(recursive: true)) {
        if (sub is File &&
            sub.path.toLowerCase().endsWith('odafileconverter.exe')) {
          return sub.path;
        }
      }
    }
    for (final p in (Platform.environment['PATH'] ?? '').split(';')) {
      final f = File('$p/ODAFileConverter.exe');
      if (f.existsSync()) return f.path;
    }
    return null;
  }

  /// Convert [dwgPath] to DXF in [outDir], trying each converter in
  /// order. Returns the produced file and which engine made it.
  /// Throws [DwgReadException] when every converter fails/absent.
  static Future<(File, String)> convert(
    String dwgPath,
    Directory outDir,
  ) async {
    final name = dwgPath.split(RegExp(r'[\\/]')).last;
    final base = name.toLowerCase().endsWith('.dwg')
        ? name.substring(0, name.length - 4)
        : name;
    final dxfPath = '${outDir.path}/$base.dxf';
    final out = File(dxfPath);
    final failures = <String>[];

    final bundled = findBundledDwg2Dxf();
    if (bundled != null) {
      if (out.existsSync()) out.deleteSync();
      try {
        final r = await Process.run(
          bundled,
          ['-y', '-o', dxfPath, dwgPath],
          workingDirectory: File(bundled).parent.path,
        ).timeout(const Duration(seconds: 90));
        if (r.exitCode == 0 && out.existsSync() && out.lengthSync() > 0) {
          return (out, 'libredwg');
        }
        failures.add('LibreDWG: ${r.stderr ?? r.stdout}');
      } catch (err) {
        failures.add('LibreDWG: $err');
      }
    } else {
      failures.add('LibreDWG: converter not bundled');
    }

    final acad = findAccoreConsole();
    if (acad != null) {
      if (out.existsSync()) out.deleteSync();
      final scr = File('${outDir.path}/cvt.scr')
        ..writeAsStringSync('FILEDIA\n0\nDXFOUT\n$dxfPath\n16\n');
      try {
        final r = await Process.run(acad, [
          '/i',
          dwgPath,
          '/s',
          scr.path,
          '/l',
          'en-US',
        ], workingDirectory: outDir.path).timeout(const Duration(seconds: 120));
        if (out.existsSync() && out.lengthSync() > 0) {
          return (out, 'autocad');
        }
        failures.add('AutoCAD: ${r.stdout ?? r.stderr}');
      } catch (err) {
        failures.add('AutoCAD: $err');
      }
    }

    final oda = findOdaConverter();
    if (oda != null) {
      if (out.existsSync()) out.deleteSync();
      // ODA converts a whole input folder; point it at the file's dir
      // and pick our file back up from outDir.
      final srcDir = File(dwgPath).parent.path;
      try {
        final r = await Process.run(
          oda,
          [srcDir, outDir.path, 'ACAD2018', 'DXF', '0', '1', name],
          workingDirectory: File(oda).parent.path,
        ).timeout(const Duration(seconds: 120));
        if (r.exitCode == 0 && out.existsSync() && out.lengthSync() > 0) {
          return (out, 'oda');
        }
        failures.add('ODA: ${r.stderr ?? r.stdout}');
      } catch (err) {
        failures.add('ODA: $err');
      }
    } else {
      failures.add('ODA: not installed');
    }

    throw DwgReadException(
      'Could not convert the DWG — tried bundled LibreDWG'
      '${acad != null ? ", AutoCAD" : ""}'
      '${oda != null ? ", ODA" : ""}.\n'
      '${failures.join('\n')}',
    );
  }

  /// Convert + parse. [outDir] is the per-file cache dir; a file whose
  /// mtime+size matches a previous conversion reuses the cached DXF.
  static Future<DwgResult> open(
    String dwgPath,
    Directory outDir, {
    String fileId = '',
  }) async {
    await outDir.create(recursive: true);
    final src = File(dwgPath);
    if (!src.existsSync()) {
      throw DwgReadException('DWG file not found:\n$dwgPath');
    }
    final name = dwgPath.split(RegExp(r'[\\/]')).last;
    final base = name.toLowerCase().endsWith('.dwg')
        ? name.substring(0, name.length - 4)
        : name;
    var dxfPath = '${outDir.path}/$base.dxf';
    final stamp = File('${outDir.path}/$base.stamp');
    final key =
        '${src.lengthSync()}:${src.lastModifiedSync().millisecondsSinceEpoch}';

    String engine;
    if (File(dxfPath).existsSync() &&
        stamp.existsSync() &&
        stamp.readAsStringSync() == key) {
      engine = 'cached';
    } else {
      final (dxf, e) = await convert(dwgPath, outDir);
      engine = e;
      stamp.writeAsStringSync(key);
      if (dxf.path != dxfPath) dxfPath = dxf.path;
    }

    final bytes = File(dxfPath).readAsBytesSync();
    final scene = DxfParser.parse(utf8.decode(bytes, allowMalformed: true));
    return DwgResult(scene, engine, dxfPath);
  }
}
