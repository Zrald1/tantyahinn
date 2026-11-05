import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../main.dart';
import '../models.dart';
import '../state.dart';
import 'sheet_view.dart';

/// POW tab: Program of Works rendered from the live BOQ data — every work
/// item row pulls its section's subtotal, the summary adds the 7% tax, and
/// signatories are shared with the BOQ sheet.
class PowView extends StatelessWidget {
  const PowView({super.key});

  static const _colNo = 52.0;
  static const _colPct = 90.0;
  static const _colUnit = 70.0;
  static const _colQty = 60.0;
  static const _colTotal = 130.0;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 8, 16),
      child: Card(
        child: ListenableBuilder(
          listenable: est,
          builder: (context, _) {
            return Column(
              children: [
                _toolbar(),
                const Divider(height: 1),
                Expanded(
                  child: est.sections.isEmpty
                      ? _empty()
                      : LayoutBuilder(
                          builder: (context, c) => SingleChildScrollView(
                            padding: const EdgeInsets.all(20),
                            child: SingleChildScrollView(
                              scrollDirection: Axis.horizontal,
                              child: SizedBox(
                                width: (c.maxWidth - 40).clamp(
                                  880.0,
                                  double.infinity,
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    OfficeHeader(),
                                    const SizedBox(height: 12),
                                    ProjectBlock(),
                                    const SizedBox(height: 18),
                                    const Text(
                                      'PROGRAM OF WORKS',
                                      style: TextStyle(
                                        fontWeight: FontWeight.w800,
                                        fontSize: 16,
                                        letterSpacing: 0.5,
                                      ),
                                    ),
                                    const SizedBox(height: 8),
                                    _tableHeader(),
                                    ..._sectionRows(),
                                    SummaryBlock(),
                                    const SizedBox(height: 24),
                                    SignatureBlock(),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _toolbar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      child: Row(
        children: [
          const Icon(
            Icons.fact_check_outlined,
            size: 18,
            color: Color(0xFF64748B),
          ),
          const SizedBox(width: 8),
          const Text(
            'POW SHEET',
            style: TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 12,
              letterSpacing: 1,
              color: Color(0xFF475569),
            ),
          ),
          const SizedBox(width: 10),
          const Flexible(
            child: Text(
              'auto-built from the BOQ',
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: Color(0xFF94A3B8)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _tableHeader() {
    final fg = bandFg(est.project.themeColor);
    Widget cell(String t, double w, [TextAlign a = TextAlign.center]) =>
        SizedBox(
          width: w,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Text(
              t,
              textAlign: a,
              style: TextStyle(
                color: fg,
                fontSize: 10.5,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.4,
              ),
            ),
          ),
        );
    return Container(
      decoration: BoxDecoration(
        color: Color(est.project.themeColor),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
      ),
      child: Row(
        children: [
          cell('ITEM\nNO.', _colNo),
          Expanded(
            flex: 3,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Text(
                'WORK ITEM',
                style: TextStyle(
                  color: fg,
                  fontSize: 10.5,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.4,
                ),
              ),
            ),
          ),
          cell('% TOTAL', _colPct),
          cell('UNIT', _colUnit),
          cell('QTY', _colQty),
          cell('TOTAL', _colTotal, TextAlign.right),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Text(
                'REMARKS',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: fg,
                  fontSize: 10.5,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.4,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _sectionRows() {
    final direct = est.directCost;
    return [
      for (var i = 0; i < est.sections.length; i++)
        _PowRow(
          letter: String.fromCharCode(65 + i),
          section: est.sections[i],
          pct: direct > 0 ? est.sections[i].subtotal / direct : 0,
        ),
    ];
  }

  Widget _empty() {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.fact_check_outlined, size: 56, color: Color(0xFFCBD5E1)),
          SizedBox(height: 14),
          Text(
            'No work items yet',
            style: TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 16,
              color: Color(0xFF475569),
            ),
          ),
          SizedBox(height: 6),
          Text(
            'Add work on the BOQ tab — this Program of Works\nbuilds itself from the section totals.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12.5, color: Color(0xFF94A3B8)),
          ),
        ],
      ),
    );
  }
}

class _PowRow extends StatelessWidget {
  final String letter;
  final BoqSection section;
  final double pct;
  const _PowRow({
    required this.letter,
    required this.section,
    required this.pct,
  });

  @override
  Widget build(BuildContext context) {
    final pctFmt = NumberFormat('0.00%');
    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(bottom: BorderSide(color: Color(0xFFEEF2F7))),
      ),
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: DefaultTextStyle(
        style: const TextStyle(fontSize: 11.5, color: Color(0xFF1E293B)),
        child: Row(
          children: [
            SizedBox(
              width: PowView._colNo,
              child: Text(
                letter,
                textAlign: TextAlign.center,
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
            ),
            Expanded(
              flex: 3,
              child: InlineEdit(
                value: section.title,
                style: const TextStyle(fontWeight: FontWeight.w600),
                onCommit: (s) => est.renameSection(section, s),
              ),
            ),
            SizedBox(
              width: PowView._colPct,
              child: Text(pctFmt.format(pct), textAlign: TextAlign.center),
            ),
            const SizedBox(
              width: PowView._colUnit,
              child: Text('lot', textAlign: TextAlign.center),
            ),
            const SizedBox(
              width: PowView._colQty,
              child: Text('1', textAlign: TextAlign.center),
            ),
            SizedBox(
              width: PowView._colTotal,
              child: Text(
                moneyFmt.format(section.subtotal),
                textAlign: TextAlign.right,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
            Expanded(
              child: InlineEdit(
                value: section.remark,
                hint: 'remark',
                align: TextAlign.center,
                onCommit: (s) {
                  section.remark = s;
                  est.update();
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
