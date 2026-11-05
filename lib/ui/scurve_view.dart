import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../cpm.dart';
import '../scurve_chart.dart';
import '../state.dart';
import 'sheet_view.dart';

/// S-CURVE tab: planned cumulative progress across the contract
/// duration, cost-weighted from the PERT-CPM schedule (each section's
/// amount spread evenly across its ES→EF window, bucketed per week).
class ScurveView extends StatefulWidget {
  const ScurveView({super.key});

  static const _colW = 70.0;
  static const _colAmt = 130.0;
  static const _colPct = 110.0;

  @override
  State<ScurveView> createState() => _ScurveViewState();
}

class _ScurveViewState extends State<ScurveView> {
  @override
  void initState() {
    super.initState();
    // The curve derives from the auto-seeded PERT-CPM network — make
    // sure it exists even if the user comes here before PERT-CPM.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) est.syncSchedule();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 8, 16),
      child: Card(
        child: ListenableBuilder(
          listenable: est,
          builder: (context, _) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) est.syncSchedule();
            });
            final cpm = computeCpm(est.activities);
            final rows = buildSCurve(
              cpm,
              horizonDays: parseDays(est.project.contractDuration),
              weights: [for (final n in cpm.nodes) est.activityCost(n.a)],
              unworkableDays: est.project.unworkableDays.toDouble(),
              bucket: est.scurveBucket,
            );
            return Column(
              children: [
                _toolbar(),
                const Divider(height: 1),
                Expanded(
                  child: rows.isEmpty
                      ? _empty(context)
                      : SingleChildScrollView(
                          padding: const EdgeInsets.all(20),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              OfficeHeader(),
                              const SizedBox(height: 12),
                              const Text(
                                'S-CURVE',
                                style: TextStyle(
                                  fontWeight: FontWeight.w800,
                                  fontSize: 16,
                                  letterSpacing: 0.5,
                                ),
                              ),
                              Text(
                                'I. ${est.project.title}    '
                                'CONTRACT DURATION: '
                                '${_cdText()}    '
                                'ABC: ${moneyFmt.format(est.grandTotal)}',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                  fontSize: 11.5,
                                  color: Color(0xFF475569),
                                ),
                              ),
                              const SizedBox(height: 14),
                              _chart(rows),
                              const SizedBox(height: 18),
                              _table(rows),
                              const SizedBox(height: 24),
                              SignatureBlock(),
                            ],
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

  String _cdText() {
    final raw = est.project.contractDuration.trim();
    final d = parseDays(raw);
    if (d == null) return raw;
    final n = d == d.roundToDouble() ? d.toInt() : d;
    return '$n calendar days';
  }

  Widget _toolbar() {
    Widget chip(CurveBucket b, String label) {
      final sel = est.scurveBucket == b;
      return Tooltip(
        message: 'Bucket the curve by ${label.toLowerCase()}',
        child: InkWell(
          onTap: () {
            est.scurveBucket = b;
            est.update();
          },
          borderRadius: BorderRadius.circular(7),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
            decoration: BoxDecoration(
              color: sel
                  ? Color(est.project.themeColor)
                  : const Color(0xFFF1F5F9),
              borderRadius: BorderRadius.circular(7),
            ),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
                color: sel
                    ? bandFg(est.project.themeColor)
                    : const Color(0xFF64748B),
              ),
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      child: Row(
        children: [
          const Icon(Icons.show_chart, size: 18, color: Color(0xFF64748B)),
          const SizedBox(width: 8),
          const Text(
            'S-CURVE',
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
              'planned cumulative %, weighted by each activity\'s share of the contract — live from the BOQ',
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: Color(0xFF94A3B8)),
            ),
          ),
          Container(
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              color: const Color(0xFFF1F5F9),
              borderRadius: BorderRadius.circular(9),
            ),
            child: Row(
              children: [
                chip(CurveBucket.day, 'Day'),
                const SizedBox(width: 4),
                chip(CurveBucket.week, 'Week'),
                const SizedBox(width: 4),
                chip(CurveBucket.month, 'Month'),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _chart(List<SCurveRow> rows) {
    return Container(
      height: 340,
      decoration: BoxDecoration(
        color: const Color(0xFFFCFDFE),
        border: Border.all(color: const Color(0xFFE2E8F0)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: CustomPaint(
        size: const Size(double.infinity, 340),
        painter: _LiveCurvePainter(rows),
      ),
    );
  }

  Widget _table(List<SCurveRow> rows) {
    final fg = bandFg(est.project.themeColor);
    Widget hcell(String t, double w, [TextAlign a = TextAlign.center]) =>
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
    final pctFmt = NumberFormat('0.00%');
    return Column(
      children: [
        Container(
          decoration: BoxDecoration(
            color: Color(est.project.themeColor),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
          ),
          child: Row(
            children: [
              hcell(est.scurveBucket.label, ScurveView._colW),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Text(
                    'PERIOD (CALENDAR DAYS)',
                    style: TextStyle(
                      color: fg,
                      fontSize: 10.5,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.4,
                    ),
                  ),
                ),
              ),
              hcell('PLANNED', ScurveView._colAmt, TextAlign.right),
              hcell(
                'THIS ${est.scurveBucket.label}',
                ScurveView._colPct,
                TextAlign.right,
              ),
              hcell('CUMULATIVE', ScurveView._colPct, TextAlign.right),
            ],
          ),
        ),
        for (final r in rows)
          Container(
            decoration: BoxDecoration(
              color: r.week.isOdd ? const Color(0xFFFAFBFD) : Colors.white,
              border: const Border(
                bottom: BorderSide(color: Color(0xFFEEF2F7)),
              ),
            ),
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: DefaultTextStyle(
              style: const TextStyle(fontSize: 11.5, color: Color(0xFF1E293B)),
              child: Row(
                children: [
                  SizedBox(
                    width: ScurveView._colW,
                    child: Text(
                      '${r.tag}${r.week}',
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      r.fromDay == r.toDay
                          ? 'Day ${r.fromDay}'
                          : 'Days ${r.fromDay} – ${r.toDay}',
                    ),
                  ),
                  SizedBox(
                    width: ScurveView._colAmt,
                    child: Text(
                      est.grandTotal > 0
                          ? moneyFmt.format(r.pct * est.grandTotal)
                          : '—',
                      textAlign: TextAlign.right,
                    ),
                  ),
                  SizedBox(
                    width: ScurveView._colPct,
                    child: Text(
                      pctFmt.format(r.pct),
                      textAlign: TextAlign.right,
                    ),
                  ),
                  SizedBox(
                    width: ScurveView._colPct,
                    child: Text(
                      pctFmt.format(r.cumPct),
                      textAlign: TextAlign.right,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _empty(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.show_chart, size: 56, color: Color(0xFFCBD5E1)),
          const SizedBox(height: 14),
          const Text(
            'No schedule yet',
            style: TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 16,
              color: Color(0xFF475569),
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'The S-curve is built from the PERT-CPM schedule.\nCreate activities on the PERT-CPM tab first.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12.5, color: Color(0xFF94A3B8)),
          ),
          const SizedBox(height: 12),
          FilledButton.tonal(
            onPressed: () {
              if (est.sections.isNotEmpty) {
                est.rebuildScheduleFromBoq();
              }
            },
            child: const Text('Build from BOQ sections'),
          ),
        ],
      ),
    );
  }
}

class _LiveCurvePainter extends CustomPainter {
  final List<SCurveRow> rows;
  _LiveCurvePainter(this.rows);

  @override
  void paint(Canvas canvas, Size size) {
    paintSCurve(
      canvas,
      size,
      rows,
      accent: Color(est.project.themeColor),
      barColor: Color(est.project.sectionColor),
    );
  }

  @override
  bool shouldRepaint(_LiveCurvePainter old) => true;
}

/// Keep the money formatter local so the view doesn't import main.dart.
final moneyFmt = NumberFormat('#,##0.00');
