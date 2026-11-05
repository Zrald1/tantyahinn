import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../design_calc.dart';
import '../model3d.dart';
import '../open_file.dart';
import '../state.dart';

/// DESIGN CALC tab - ETABS-style automatic design calculation sheet
/// for the selected 3D model (loads, seismic, wind, combinations,
/// member checks per NSCP 2015). Recomputes live on every model or
/// parameter change.
class DesignView extends StatefulWidget {
  const DesignView({super.key});
  @override
  State<DesignView> createState() => _DesignViewState();
}

class _DesignViewState extends State<DesignView> {
  String? _modelId;

  Model3d? get _model {
    if (est.models.isEmpty) return null;
    for (final m in est.models) {
      if (m.id == _modelId) return m;
    }
    return est.models.first;
  }

  void _set(void Function() f) {
    setState(f);
    est.update();
  }

  Widget _num(String label, double v, void Function(double) set, {String? suffix}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: TextFormField(
        key: ValueKey('dp-$label'),
        initialValue: v.toString(),
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        style: const TextStyle(fontSize: 12.5),
        decoration: InputDecoration(labelText: label, suffixText: suffix, isDense: true),
        onChanged: (s) {
          final x = double.tryParse(s);
          if (x != null && x >= 0) _set(() => set(x));
        },
      ),
    );
  }

  Widget _drop<T>(String label, T v, List<T> items, String Function(T) name, void Function(T) set) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: DropdownButtonFormField<T>(
        key: ValueKey('dd-$label'),
        initialValue: v,
        isExpanded: true,
        isDense: true,
        decoration: InputDecoration(labelText: label, isDense: true),
        items: [
          for (final i in items)
            DropdownMenuItem(
              value: i,
              child: Text(name(i), style: const TextStyle(fontSize: 12.5), overflow: TextOverflow.ellipsis),
            ),
        ],
        onChanged: (x) {
          if (x != null) _set(() => set(x));
        },
      ),
    );
  }

  Widget _params() {
    final p = est.design;
    return Container(
      width: 270,
      color: const Color(0xFFF8FAFC),
      child: ListView(
        padding: const EdgeInsets.all(14),
        children: [
          const Text(
            'DESIGN PARAMETERS',
            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 1.1, color: Color(0xFF475569)),
          ),
          const SizedBox(height: 10),
          if (est.models.length > 1)
            _drop<String>(
              'Model',
              _model!.id,
              [for (final m in est.models) m.id],
              (id) => est.models.firstWhere((m) => m.id == id).name,
              (id) => _modelId = id,
            ),
          _drop<int>('Seismic zone', p.zone, const [4, 2], (z) => 'Zone $z (Z = ${z == 4 ? '0.40' : '0.20'})', (z) => p.zone = z),
          _drop<String>('Soil profile', p.soil, kSoils, (s) => s, (s) => p.soil = s),
          _drop<int>('Occupancy', p.occ, List.generate(kOccupancies.length, (i) => i),
              (i) => '${kOccupancies[i].$1} (${kOccupancies[i].$2} kPa)', (i) => p.occ = i),
          _drop<int>('Structural system', p.sys.clamp(0, kSystems.length - 1),
              List.generate(kSystems.length, (i) => i),
              (i) => '${kSystems[i].$1} R=${kSystems[i].$2}',
              (i) => p.sys = i),
          if (p.zone == 4)
            Row(
              children: [
                Expanded(child: _num('Na', p.na, (v) => p.na = v)),
                const SizedBox(width: 8),
                Expanded(child: _num('Nv', p.nv, (v) => p.nv = v)),
              ],
            ),
          _num('Wind speed', p.windKph, (v) => p.windKph = v, suffix: 'kph'),
          Row(
            children: [
              Expanded(child: _num("f'c", p.fc, (v) => p.fc = v, suffix: 'MPa')),
              const SizedBox(width: 8),
              Expanded(child: _num('fy', p.fy, (v) => p.fy = v, suffix: 'MPa')),
            ],
          ),
          _num('Soil bearing qa', p.qa, (v) => p.qa = v, suffix: 'kPa'),
          Row(
            children: [
              Expanded(child: _num('Roof DL', p.roofDl, (v) => p.roofDl = v, suffix: 'kPa')),
              const SizedBox(width: 8),
              Expanded(child: _num('Roof LL', p.roofLl, (v) => p.roofLl = v, suffix: 'kPa')),
            ],
          ),
          Row(
            children: [
              Expanded(child: _num('Finish', p.finishDl, (v) => p.finishDl = v, suffix: 'kPa')),
              const SizedBox(width: 8),
              Expanded(child: _num('Partition', p.partDl, (v) => p.partDl = v, suffix: 'kPa')),
            ],
          ),
          _num('Ceiling', p.ceilDl, (v) => p.ceilDl = v, suffix: 'kPa'),
        ],
      ),
    );
  }

  Color _col(Chk c) => switch (c) {
    Chk.ok => const Color(0xFF15803D),
    Chk.warn => const Color(0xFFB45309),
    Chk.fail => const Color(0xFFB91C1C),
    Chk.info => const Color(0xFF64748B),
  };

  Widget _chip(CalcRow r) {
    if (r.status == Chk.info) return const SizedBox(width: 52);
    final t = switch (r.status) {
      Chk.ok => 'PASS',
      Chk.warn => 'WARN',
      Chk.fail => 'FAIL',
      Chk.info => '',
    };
    return Container(
      width: 46,
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(vertical: 2),
      margin: const EdgeInsets.only(right: 6),
      decoration: BoxDecoration(
        color: _col(r.status).withValues(alpha: .12),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(t, style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: _col(r.status))),
    );
  }

  Widget _kpi(String k, String v, {Chk s = Chk.info}) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
    decoration: BoxDecoration(
      color: Colors.white,
      border: Border.all(color: const Color(0xFFE2E8F0)),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(k, style: const TextStyle(fontSize: 10.5, color: Color(0xFF64748B))),
        const SizedBox(height: 2),
        Text(v, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: _col(s))),
      ],
    ),
  );

  void _applyFix(DesignFix f) {
    final m = _model;
    if (m == null) return;
    if (applyDesignFix(m, f)) {
      est.update();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${f.label} - applied to the 3D model'),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  void _applyAllFixes(CalcReport r) {
    final m = _model;
    if (m == null) return;
    var n = 0;
    for (final s in r.sections) {
      for (final row in s.rows) {
        if (row.fix != null && applyDesignFix(m, row.fix!)) n++;
      }
    }
    if (n > 0) {
      est.update();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Applied $n fix${n == 1 ? '' : 'es'} - sheet recalculated'),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  Widget _report(CalcReport r) {
    final fixCount = r.sections.fold<int>(
        0, (n, s) => n + s.rows.where((x) => x.fix != null).length);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'DESIGN CALCULATION - NSCP 2015 (7th ed.)',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, letterSpacing: .5),
              ),
            ),
            if (fixCount > 0)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: FilledButton.icon(
                  key: const ValueKey('design-fix-all'),
                  onPressed: () => _applyAllFixes(r),
                  icon: const Icon(Icons.build_outlined, size: 16),
                  label: Text('FIX ALL ($fixCount)',
                      style: const TextStyle(fontSize: 12)),
                ),
              ),
            OutlinedButton.icon(
              key: const ValueKey('design-pdf'),
              onPressed: () => _exportPdf(r),
              icon: const Icon(Icons.picture_as_pdf_outlined, size: 16),
              label: const Text('EXPORT PDF', style: TextStyle(fontSize: 12)),
            ),
          ],
        ),
        const SizedBox(height: 10),
        if (r.v > 0)
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              _kpi('Seismic weight W', '${r.w.toStringAsFixed(0)} kN'),
              _kpi('Base shear V', '${r.v.toStringAsFixed(1)} kN'),
              _kpi('Period T', '${r.t.toStringAsFixed(3)} s'),
              _kpi('Wind (max)', '${(r.windX > r.windY ? r.windX : r.windY).toStringAsFixed(1)} kN'),
              _kpi('Passed', '${r.ok}', s: Chk.ok),
              _kpi('Warnings', '${r.warn}', s: r.warn > 0 ? Chk.warn : Chk.info),
              _kpi('Failures', '${r.fail}', s: r.fail > 0 ? Chk.fail : Chk.info),
            ],
          ),
        for (final s in r.sections) ...[
          Padding(
            padding: const EdgeInsets.only(top: 18, bottom: 6),
            child: Text(
              s.title,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800, letterSpacing: .8, color: Color(0xFF1E3A8A)),
            ),
          ),
          Container(
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border.all(color: const Color(0xFFE2E8F0)),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              children: [
                for (var i = 0; i < s.rows.length; i++)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      border: i == 0 ? null : const Border(top: BorderSide(color: Color(0xFFF1F5F9))),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _chip(s.rows[i]),
                        Expanded(
                          flex: 5,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(s.rows[i].label, style: const TextStyle(fontSize: 12)),
                              if (s.rows[i].formula != null)
                                Text(
                                  s.rows[i].formula!,
                                  style: const TextStyle(fontSize: 10.5, color: Color(0xFF94A3B8)),
                                ),
                              if (s.rows[i].ref != null)
                                Text(
                                  'NSCP 2015 ${s.rows[i].ref!}',
                                  style: const TextStyle(
                                    fontSize: 9.5,
                                    fontWeight: FontWeight.w600,
                                    color: Color(0xFF7C8DB5),
                                    letterSpacing: .2,
                                  ),
                                ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          flex: 4,
                          child: Text(
                            s.rows[i].value,
                            textAlign: TextAlign.right,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: s.rows[i].status == Chk.info ? const Color(0xFF0F172A) : _col(s.rows[i].status),
                            ),
                          ),
                        ),
                        SizedBox(
                          width: 52,
                          child: s.rows[i].fix == null
                              ? const SizedBox()
                              : Tooltip(
                                  message: s.rows[i].fix!.label,
                                  child: TextButton(
                                    key: ValueKey('fix-${s.rows[i].fix!.targetId}-${s.rows[i].fix!.kind}'),
                                    style: TextButton.styleFrom(
                                      padding: EdgeInsets.zero,
                                      minimumSize: const Size(44, 26),
                                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                    ),
                                    onPressed: () => _applyFix(s.rows[i].fix!),
                                    child: const Text(
                                      'FIX',
                                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800),
                                    ),
                                  ),
                                ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Future<void> _exportPdf(CalcReport r) async {
    final loc = await getSaveLocation(
      suggestedName: 'design_calculation.pdf',
      acceptedTypeGroups: [const XTypeGroup(label: 'PDF Document', extensions: ['pdf'])],
    );
    if (loc == null) return;
    await File(loc.path).writeAsBytes(await designReportPdf(r, est.project.title));
    unawaited(openExportedFile(loc.path));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Saved ${loc.path}')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: est,
      builder: (context, _) {
        final m = _model;
        return Row(
          children: [
            _params(),
            const VerticalDivider(width: 1),
            Expanded(
              child: m == null
                  ? const Center(child: Text('Create a 3D model first - the design calculation is generated from it.'))
                  : _report(designCalc(m, est.design)),
            ),
          ],
        );
      },
    );
  }
}

String _ascii(String s) => s
    .replaceAll('φ', 'phi')
    .replaceAll('≥', '>=')
    .replaceAll('≤', '<=')
    .replaceAll('×', 'x')
    .replaceAll('·', '.')
    .replaceAll(RegExp(r'[^\x20-\x7E]'), '?');

Future<Uint8List> designReportPdf(CalcReport r, String projectTitle) async {
  final doc = pw.Document();
  final title = projectTitle.isEmpty ? 'Project' : projectTitle;
  doc.addPage(
    pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.all(32),
      build: (_) => [
        pw.Text('DESIGN CALCULATION - NSCP 2015 (7th ed.)', style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold)),
        pw.Text(_ascii(title), style: const pw.TextStyle(fontSize: 10)),
        pw.SizedBox(height: 10),
        for (final s in r.sections) ...[
          pw.SizedBox(height: 8),
          pw.Text(_ascii(s.title), style: pw.TextStyle(fontSize: 10.5, fontWeight: pw.FontWeight.bold)),
          pw.Divider(thickness: .5),
          for (final row in s.rows)
            pw.Padding(
              padding: const pw.EdgeInsets.only(bottom: 2),
              child: pw.Row(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.SizedBox(
                    width: 30,
                    child: pw.Text(
                      switch (row.status) {
                        Chk.ok => 'PASS',
                        Chk.warn => 'WARN',
                        Chk.fail => 'FAIL',
                        Chk.info => '',
                      },
                      style: pw.TextStyle(fontSize: 7, fontWeight: pw.FontWeight.bold),
                    ),
                  ),
                  pw.Expanded(
                    flex: 5,
                    child: pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.start,
                      children: [
                        pw.Text(_ascii(row.label), style: const pw.TextStyle(fontSize: 8.5)),
                        if (row.formula != null)
                          pw.Text(_ascii(row.formula!), style: const pw.TextStyle(fontSize: 7, color: PdfColors.grey700)),
                        if (row.ref != null)
                          pw.Text(_ascii('NSCP 2015 ${row.ref!}'), style: const pw.TextStyle(fontSize: 6.5, color: PdfColors.grey600)),
                      ],
                    ),
                  ),
                  pw.Expanded(
                    flex: 4,
                    child: pw.Text(
                      _ascii(row.value),
                      textAlign: pw.TextAlign.right,
                      style: pw.TextStyle(fontSize: 8.5, fontWeight: pw.FontWeight.bold),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ],
    ),
  );
  return doc.save();
}

