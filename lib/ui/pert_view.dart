import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../cpm.dart';
import '../models.dart';
import '../state.dart';
import 'sheet_view.dart';

/// PERT-CPM tab: the editable activity network. The table takes
/// name/days/predecessors per lettered activity; the diagram below it is
/// drawn from the same data (ES/EF/LS/LF boxes, arrows, slack) with the
/// zero-slack critical path highlighted in the theme color.
class PertView extends StatefulWidget {
  const PertView({super.key});

  static const _colAct = 58.0;
  static const _colBoq = 44.0;
  static const _colNum = 62.0;
  static const _colPred = 120.0;

  @override
  State<PertView> createState() => _PertViewState();
}

class _PertViewState extends State<PertView> {
  @override
  void initState() {
    super.initState();
    // Philippine standard: the network auto-derives from the BOQ —
    // seed (or append new sections) once the first frame is up.
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
            // Re-check on every rebuild too: sections added while on
            // another tab get appended here (no-op when nothing's new).
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) est.syncSchedule();
            });
            final result = computeCpm(est.activities);
            _lastCpm = result;
            return Column(
              children: [
                _toolbar(context),
                const Divider(height: 1),
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(20),
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: SizedBox(
                        width: 940,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            OfficeHeader(),
                            const SizedBox(height: 12),
                            const Text(
                              'Program Evaluation and Review Technique '
                              '(PERT) & Critical Path Method (CPM)',
                              style: TextStyle(
                                fontWeight: FontWeight.w800,
                                fontSize: 14,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              'I. ${est.project.title}    '
                              'CONTRACT DURATION: '
                              '${_cdText()}',
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: 12,
                              ),
                            ),
                            const SizedBox(height: 8),
                            _durationStrip(context, result),
                            const SizedBox(height: 14),
                            _tableHeader(),
                            ..._rows(result),
                            if (est.activities.isNotEmpty &&
                                result.error == null) ...[
                              const SizedBox(height: 18),
                              _diagram(result),
                              const SizedBox(height: 14),
                              _notes(result),
                            ] else if (result.error != null)
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 14,
                                ),
                                child: Text(
                                  result.error!,
                                  style: const TextStyle(
                                    color: Colors.redAccent,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            const SizedBox(height: 24),
                            SignatureBlock(),
                          ],
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

  Widget _toolbar(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      child: Row(
        children: [
          const Icon(Icons.hub_outlined, size: 18, color: Color(0xFF64748B)),
          const SizedBox(width: 8),
          const Text(
            'PERT-CPM',
            style: TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 12,
              letterSpacing: 1,
              color: Color(0xFF475569),
            ),
          ),
          const SizedBox(width: 10),
          Flexible(
            child: Text(
              'auto-built from your BOQ '
              '(${est.sections.length} section${est.sections.length == 1 ? '' : 's'}) — '
              'edits are kept; right-click a row to insert or delete',
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11, color: Color(0xFF94A3B8)),
            ),
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 18,
                height: 18,
                child: Checkbox(
                  value: est.project.autoSchedule,
                  visualDensity: VisualDensity.compact,
                  onChanged: (v) {
                    est.project.autoSchedule = v ?? true;
                    if (v == true) est.syncSchedule(force: true);
                    est.update();
                  },
                ),
              ),
              const SizedBox(width: 4),
              const Text(
                'AUTO',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF64748B),
                ),
              ),
              const SizedBox(width: 8),
            ],
          ),
          TextButton.icon(
            onPressed: est.sections.isEmpty
                ? null
                : () async {
                    final go = await showDialog<bool>(
                      context: context,
                      builder: (c) => AlertDialog(
                        title: const Text('Rebuild from BOQ?'),
                        content: const Text(
                          'This regenerates the construction network '
                          'from the BOQ — one activity per section, '
                          'ordered by construction logic with parallel '
                          'work fronts where the trades allow. Manual '
                          'edits to names, days and predecessors are '
                          'lost.',
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(c, false),
                            child: const Text('Cancel'),
                          ),
                          FilledButton(
                            onPressed: () => Navigator.pop(c, true),
                            child: const Text('Rebuild'),
                          ),
                        ],
                      ),
                    );
                    if (go == true) {
                      est.rebuildScheduleFromBoq();
                    }
                  },
            icon: const Icon(Icons.auto_fix_high, size: 16),
            label: const Text(
              'Rebuild from BOQ',
              style: TextStyle(fontSize: 12),
            ),
          ),
          TextButton.icon(
            onPressed: () => est.addActivity(),
            icon: const Icon(Icons.add, size: 16),
            label: const Text('Add activity', style: TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }

  /// '116 calendar days' — avoids doubling the unit when the stored
  /// string already carries one ("116 calendar days CALENDAR DAYS").
  String _cdText() {
    final raw = est.project.contractDuration.trim();
    final d = parseDays(raw);
    if (d == null) return raw;
    final n = d == d.roundToDouble() ? d.toInt() : d;
    return '$n calendar days';
  }

  /// Philippine duration derivation (NIA/DPWH): the critical path
  /// gives the project duration in working calendar days; the stated
  /// contract duration adds the pre-determined unworkable-days
  /// allowance. "Apply" writes it back to the project header.
  Widget _durationStrip(BuildContext context, CpmResult result) {
    final cpmDays = result.duration;
    final unwork = est.project.unworkableDays;
    final estCd = (cpmDays + unwork).ceilToDouble().clamp(1, 3650).toInt();
    return Wrap(
      spacing: 14,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(
          'CRITICAL PATH: ${cpmDays.toStringAsFixed(0)} CD  ·  '
          'UNWORKABLE DAYS:',
          style: const TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w700,
            color: Color(0xFF475569),
          ),
        ),
        SizedBox(
          width: 46,
          child: InlineEdit(
            value: unwork.toString(),
            hint: '0',
            align: TextAlign.center,
            onCommit: (s) {
              final v = int.tryParse(s);
              if (v != null && v >= 0 && v <= 3650) {
                est.project.unworkableDays = v;
                est.update();
              }
            },
          ),
        ),
        Text(
          '→  ESTIMATED CONTRACT DURATION: $estCd calendar days',
          style: const TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w800,
            color: Color(0xFF1E4976),
          ),
        ),
        TextButton(
          onPressed: result.error == null && cpmDays > 0
              ? () => est.applyCpmDuration(cpmDays)
              : null,
          style: TextButton.styleFrom(
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.symmetric(horizontal: 8),
          ),
          child: const Text('Apply', style: TextStyle(fontSize: 11.5)),
        ),
      ],
    );
  }

  Widget _tableHeader() {
    final fg = bandFg(est.project.themeColor);
    Widget cell(String t, double w) => SizedBox(
      width: w,
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Text(
          t,
          textAlign: TextAlign.center,
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
          cell('ACT.', PertView._colAct),
          cell('BOQ', PertView._colBoq),
          Expanded(
            flex: 3,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Text(
                'ACTIVITY',
                style: TextStyle(
                  color: fg,
                  fontSize: 10.5,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.4,
                ),
              ),
            ),
          ),
          cell('DAYS', PertView._colNum),
          cell('PREDECESSORS', PertView._colPred),
          cell('ES', PertView._colNum),
          cell('EF', PertView._colNum),
          cell('LS', PertView._colNum),
          cell('LF', PertView._colNum),
          cell('SLACK', PertView._colNum),
        ],
      ),
    );
  }

  List<Widget> _rows(CpmResult result) {
    return [
      for (var i = 0; i < est.activities.length; i++)
        _ActivityRow(
          index: i,
          activity: est.activities[i],
          node: i < result.nodes.length ? result.nodes[i] : null,
        ),
    ];
  }

  Widget _diagram(CpmResult r) {
    final size = _CpmPainter.sizeFor(r);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text(
              'NETWORK DIAGRAM',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 1,
                color: Color(0xFF64748B),
              ),
            ),
            const SizedBox(width: 10),
            Flexible(
              child: Text(
                'drag a box to another column to re-wire its '
                'predecessors, or up/down inside a column to reorder',
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 10.5,
                  color: Color(0xFF94A3B8),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        LayoutBuilder(
          builder: (context, bc) {
            // The canvas sizes itself to the network. Fit it to the
            // available width (scale-down only) and give it natural
            // height — no internal scroll/zoom, so the mouse wheel
            // always scrolls the page and nothing is ever clipped.
            final w = bc.maxWidth.isFinite ? bc.maxWidth : size.width;
            final s = math.min(1.0, w / size.width);
            return Container(
              width: double.infinity,
              height: size.height * s,
              decoration: BoxDecoration(
                color: const Color(0xFFFCFDFE),
                border: Border.all(color: const Color(0xFFE2E8F0)),
                borderRadius: BorderRadius.circular(8),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: SizedBox(
                    width: size.width,
                    height: size.height,
                    child: Stack(
                      children: [
                        CustomPaint(
                          size: size,
                          painter: _CpmPainter(
                            r,
                            accent: Color(est.project.themeColor),
                            drag: _dragNode,
                            dragPos: _dragPos,
                            drop: _dropCell,
                          ),
                        ),
                        // one opaque hit target per node so drags claim the
                        // gesture away from the page scroll / viewer pan
                        for (final n in r.nodes)
                          Positioned(
                            left: _CpmPainter.topLeftOf(n.level, n.lane).dx,
                            top: _CpmPainter.topLeftOf(n.level, n.lane).dy,
                            width: _CpmPainter.boxW,
                            height: _CpmPainter.boxH,
                            child: GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onPanStart: (d) => _netDragStart(n, d),
                              onPanUpdate: _netDragUpdate,
                              onPanEnd: (_) => _netDragEnd(),
                              onPanCancel: _netDragEnd,
                              child: const MouseRegion(
                                cursor: SystemMouseCursors.click,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ],
    );
  }

  CpmNode? _dragNode;
  Offset _dragPos = Offset.zero;
  (int, int)? _dropCell;
  CpmResult? _lastCpm;

  void _netDragStart(CpmNode n, DragStartDetails d) {
    final r = _lastCpm;
    if (r == null) return;
    // localPosition is inside the node box — add its origin back to
    // land in diagram coordinates
    final o = _CpmPainter.topLeftOf(n.level, n.lane);
    setState(() {
      _dragNode = n;
      _dragPos = o + d.localPosition;
      _dropCell = _CpmPainter.cellAt(_dragPos, r);
    });
  }

  void _netDragUpdate(DragUpdateDetails d) {
    final n = _dragNode;
    final r = _lastCpm;
    if (n == null || r == null) return;
    final o = _CpmPainter.topLeftOf(n.level, n.lane);
    setState(() {
      _dragPos = o + d.localPosition;
      _dropCell = _CpmPainter.cellAt(_dragPos, r);
    });
  }

  void _netDragEnd() {
    final n = _dragNode;
    final cell = _dropCell;
    setState(() {
      _dragNode = null;
      _dropCell = null;
    });
    if (n == null || cell == null) return;
    final err = est.moveActivityToCell(n.a, cell.$1, cell.$2);
    if (err != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Cannot drop here: $err'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Widget _notes(CpmResult r) {
    final crit = r.criticalPath;
    final nonCrit = r.nodes
        .where((n) => !n.critical)
        .map((n) => n.letter)
        .toList();
    final slacks = nonCrit.isEmpty
        ? 0.0
        : r.nodes
              .where((n) => !n.critical)
              .map((n) => n.slack)
              .reduce(math.min);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: Color(est.project.subtotalColor),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            'CRITICAL PATH ${crit.isEmpty ? '—' : crit}   •   '
            'PROJECT DURATION: ${r.duration.toStringAsFixed(0)} '
            'CALENDAR DAYS',
            style: TextStyle(
              fontWeight: FontWeight.w800,
              fontSize: 12,
              color: bandFg(est.project.subtotalColor),
            ),
          ),
        ),
        const SizedBox(height: 8),
        if (crit.isNotEmpty)
          Text(
            '1.) Any delay in the $crit path will cause a delay in the '
            'entire project\'s completion, as it is the critical path '
            'with zero slack.',
            style: const TextStyle(fontSize: 11.5, color: Color(0xFF475569)),
          ),
        if (nonCrit.isNotEmpty)
          Text(
            '2.) Activities ${nonCrit.join(', ')} carry '
            '${slacks.toStringAsFixed(0)}+ days of slack — they can be '
            'delayed by up to that much without affecting the overall '
            'timeline.',
            style: const TextStyle(fontSize: 11.5, color: Color(0xFF475569)),
          ),
      ],
    );
  }
}

class _ActivityRow extends StatelessWidget {
  final int index;
  final CpmActivity activity;
  final CpmNode? node;
  const _ActivityRow({required this.index, required this.activity, this.node});

  @override
  Widget build(BuildContext context) {
    final critical = node?.critical ?? false;
    final fmt = NumberFormat('0.#');
    Widget num(String v, {bool bold = false}) => SizedBox(
      width: PertView._colNum,
      child: Text(
        v,
        textAlign: TextAlign.center,
        style: TextStyle(
          fontSize: 11.5,
          fontWeight: bold ? FontWeight.w800 : FontWeight.w500,
          color: const Color(0xFF1E293B),
        ),
      ),
    );
    return GestureDetector(
      onSecondaryTapUp: (d) => _menu(context, d.globalPosition),
      child: Container(
        decoration: BoxDecoration(
          color: critical
              ? Color(est.project.subtotalColor)
              : (index.isOdd ? const Color(0xFFFAFBFD) : Colors.white),
          border: const Border(bottom: BorderSide(color: Color(0xFFEEF2F7))),
        ),
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            SizedBox(
              width: PertView._colAct,
              child: Text(
                cpmLetter(index),
                textAlign: TextAlign.center,
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
            ),
            SizedBox(width: PertView._colBoq, child: _boqBadge(activity)),
            Expanded(
              flex: 3,
              child: InlineEdit(
                value: activity.name,
                hint: 'activity name',
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 11.5,
                ),
                onCommit: (s) => est.setActivityName(activity, s),
              ),
            ),
            SizedBox(
              width: PertView._colNum,
              child: InlineEdit(
                value: fmt.format(activity.days),
                hint: 'days',
                align: TextAlign.center,
                onCommit: (s) {
                  final v = double.tryParse(s);
                  if (v != null && v > 0) {
                    est.setActivityDays(activity, v);
                  }
                },
              ),
            ),
            SizedBox(
              width: PertView._colPred,
              child: InlineEdit(
                value: activity.preds,
                hint: 'e.g. A,C',
                align: TextAlign.center,
                onCommit: (s) => est.setActivityPreds(activity, s),
              ),
            ),
            num(node == null ? '—' : fmt.format(node!.es)),
            num(node == null ? '—' : fmt.format(node!.ef)),
            num(node == null ? '—' : fmt.format(node!.ls)),
            num(node == null ? '—' : fmt.format(node!.lf)),
            num(node == null ? '—' : fmt.format(node!.slack), bold: critical),
          ],
        ),
      ),
    );
  }

  /// The BOQ section this activity was generated from — the letter and
  /// a tooltip with the section title; a muted dot for hand-added rows
  /// that aren't linked to a BOQ section.
  Widget _boqBadge(CpmActivity a) {
    final sid = a.sectionId;
    if (sid == null) {
      return const Text(
        '·',
        textAlign: TextAlign.center,
        style: TextStyle(color: Color(0xFFCBD5E1), fontSize: 13),
      );
    }
    BoqSection? sec;
    for (final s in est.sections) {
      if (s.id == sid) sec = s;
    }
    if (sec == null) {
      return const Text(
        '—',
        textAlign: TextAlign.center,
        style: TextStyle(color: Color(0xFFCBD5E1), fontSize: 11),
      );
    }
    return Tooltip(
      message: 'From BOQ section ${est.letterOf(sec)} — ${sec.title}',
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        padding: const EdgeInsets.symmetric(vertical: 2),
        decoration: BoxDecoration(
          color: Color(est.project.sectionColor).withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          est.letterOf(sec),
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w800,
            color: Color(0xFF334155),
          ),
        ),
      ),
    );
  }

  void _menu(BuildContext context, Offset pos) async {
    final i = est.activities.indexOf(activity);
    final v = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(pos.dx, pos.dy, pos.dx, pos.dy),
      items: const [
        PopupMenuItem(value: 'above', child: Text('Insert activity above')),
        PopupMenuItem(value: 'below', child: Text('Insert activity below')),
        PopupMenuItem(
          value: 'delete',
          child: Text(
            'Delete activity',
            style: TextStyle(color: Colors.redAccent),
          ),
        ),
      ],
    );
    switch (v) {
      case 'above':
        est.addActivity(after: i - 1);
      case 'below':
        est.addActivity(after: i);
      case 'delete':
        est.removeActivity(activity);
    }
  }
}

/// Draws the activity-on-node boxes:
///   ┌───────────┬────┬────┐
///   │ SLACK     │    │  v │
///   │  A        │ ES │ EF │───▶
///   │  days     │ LS │ LF │
///   │  activity name           │
///   └───────────┴────┴────┘
/// Critical boxes/edges use the theme accent; others stay neutral.
/// Cross-lane connectors route orthogonally through the empty channel
/// between lanes so parallel flows stay readable.
class _CpmPainter extends CustomPainter {
  final CpmResult r;
  final Color accent;

  /// Node being dragged (ghost follows [dragPos]) and the cell it
  /// would drop into, highlighted as a target.
  final CpmNode? drag;
  final Offset dragPos;
  final (int, int)? drop;
  _CpmPainter(
    this.r, {
    required this.accent,
    this.drag,
    this.dragPos = Offset.zero,
    this.drop,
  });

  static const boxW = 150.0, boxH = 92.0, gapX = 58.0, gapY = 46.0;

  static Offset topLeftOf(int level, int lane) =>
      Offset(30 + level * (boxW + gapX), 20 + lane * (boxH + gapY));

  static Size sizeFor(CpmResult r) => Size(
    (r.maxLevel + 2) * (boxW + gapX) + 60,
    (r.laneCount + 1) * (boxH + gapY) + 40,
  );

  /// Diagram cell under [p]: column index clamped to one past the last
  /// level (a drop there appends a finish stage), lane index allowed
  /// one past the last lane (drops add a row).
  static (int, int) cellAt(Offset p, CpmResult r) {
    final level = ((p.dx - 30) / (boxW + gapX)).round().clamp(
      0,
      r.maxLevel + 1,
    );
    final lane = ((p.dy - 20) / (boxH + gapY)).round().clamp(0, r.laneCount);
    return (level, lane);
  }

  Offset _topLeft(CpmNode n) => topLeftOf(n.level, n.lane);

  @override
  void paint(Canvas canvas, Size size) {
    final text = TextPainter(textDirection: ui.TextDirection.ltr);
    void drawText(
      String s,
      Offset o,
      double w, {
      bool bold = false,
      double fs = 10,
      Color color = const Color(0xFF334155),
      TextAlign align = TextAlign.left,
    }) {
      text
        ..text = TextSpan(
          text: s,
          style: TextStyle(
            fontSize: fs,
            fontWeight: bold ? FontWeight.w800 : FontWeight.w500,
            color: color,
          ),
        )
        ..textAlign = align
        // force full layout width so right/center alignment lands
        // on the box edge instead of next to the label
        ..layout(minWidth: w, maxWidth: w)
        ..paint(canvas, o);
    }

    // Edges first so boxes paint over their tails.
    for (final n in r.nodes) {
      final to = _topLeft(n);
      for (final j in n.predIdx) {
        final p = r.nodes[j];
        final from = _topLeft(p);
        final start = Offset(from.dx + boxW, from.dy + boxH / 2);
        final end = Offset(to.dx, to.dy + boxH / 2);
        final crit = n.critical && p.critical;
        final paint = Paint()
          ..color = crit ? accent : const Color(0xFF94A3B8)
          ..strokeWidth = crit ? 2.2 : 1.2
          ..style = PaintingStyle.stroke;
        if (p.lane == n.lane) {
          canvas.drawLine(start, end, paint);
        } else {
          // orthogonal route through the lane channel
          final outX = from.dx + boxW + gapX * 0.5;
          final inX = to.dx - gapX * 0.5;
          final channelY = n.lane > p.lane
              ? from.dy + boxH + gapY * 0.5
              : from.dy - gapY * 0.5;
          final path = Path()
            ..moveTo(start.dx, start.dy)
            ..lineTo(outX, start.dy)
            ..lineTo(outX, channelY)
            ..lineTo(inX, channelY)
            ..lineTo(inX, end.dy)
            ..lineTo(end.dx - 9, end.dy);
          canvas.drawPath(path, paint);
        }
        // arrowhead at the target edge
        final ah = Path()
          ..moveTo(end.dx, end.dy)
          ..lineTo(end.dx - 9, end.dy - 4.5)
          ..lineTo(end.dx - 9, end.dy + 4.5)
          ..close();
        canvas.drawPath(
          ah,
          Paint()..color = crit ? accent : const Color(0xFF94A3B8),
        );
      }
    }

    // drop-target cell under the pointer
    final dc = drop;
    if (dc != null) {
      final o = topLeftOf(dc.$1, dc.$2);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(o.dx - 4, o.dy - 4, boxW + 8, boxH + 8),
          const Radius.circular(9),
        ),
        Paint()..color = accent.withValues(alpha: 0.13),
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(o.dx - 4, o.dy - 4, boxW + 8, boxH + 8),
          const Radius.circular(9),
        ),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.4
          ..color = accent.withValues(alpha: 0.55),
      );
    }

    final fmt = NumberFormat('0.#');
    for (final n in r.nodes) {
      // the dragged node ghosts at the pointer; edges stay anchored to
      // its real slot until the drop lands
      final o = identical(n, drag)
          ? dragPos - const Offset(boxW / 2, boxH / 2)
          : _topLeft(n);
      final rect = Rect.fromLTWH(o.dx, o.dy, boxW, boxH);
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(6)),
        Paint()
          ..color = n.critical ? accent.withValues(alpha: 0.10) : Colors.white,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(6)),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = n.critical ? 2.2 : 1.1
          ..color = n.critical ? accent : const Color(0xFFCBD5E1),
      );
      final ink = n.critical ? accent : const Color(0xFF475569);
      final row1 = o.dy + 5,
          row2 = o.dy + 25,
          row3 = o.dy + 45,
          row4 = o.dy + 68;
      drawText('SLACK', Offset(o.dx + 8, row1), 60, fs: 8.5, color: ink);
      drawText(
        fmt.format(n.slack),
        Offset(o.dx + 8, row1),
        boxW - 16,
        bold: n.critical,
        color: ink,
        align: TextAlign.right,
      );
      drawText(
        n.letter,
        Offset(o.dx + 8, row2),
        44,
        bold: true,
        fs: 12,
        color: ink,
      );
      drawText(
        fmt.format(n.es),
        Offset(o.dx + 52, row2),
        40,
        color: ink,
        align: TextAlign.center,
      );
      drawText(
        fmt.format(n.ef),
        Offset(o.dx + 96, row2),
        44,
        color: ink,
        align: TextAlign.center,
      );
      drawText(
        fmt.format(n.a.days),
        Offset(o.dx + 8, row3),
        44,
        fs: 9.5,
        color: const Color(0xFF64748B),
      );
      drawText(
        fmt.format(n.ls),
        Offset(o.dx + 52, row3),
        40,
        fs: 9.5,
        color: const Color(0xFF64748B),
        align: TextAlign.center,
      );
      drawText(
        fmt.format(n.lf),
        Offset(o.dx + 96, row3),
        44,
        fs: 9.5,
        color: const Color(0xFF64748B),
        align: TextAlign.center,
      );
      // legend inside the box: ES | EF headers
      drawText(
        'ES',
        Offset(o.dx + 52, o.dy + 3),
        40,
        fs: 7,
        color: const Color(0xFF94A3B8),
        align: TextAlign.center,
      );
      drawText(
        'EF',
        Offset(o.dx + 96, o.dy + 3),
        44,
        fs: 7,
        color: const Color(0xFF94A3B8),
        align: TextAlign.center,
      );
      // name line across the bottom of the box (ellipsized)
      text
        ..text = TextSpan(
          text: n.a.name,
          style: const TextStyle(
            fontSize: 8,
            fontWeight: FontWeight.w500,
            color: Color(0xFF64748B),
          ),
        )
        ..textAlign = TextAlign.center
        ..maxLines = 1
        ..ellipsis = '…'
        ..layout(minWidth: boxW - 16, maxWidth: boxW - 16)
        ..paint(canvas, Offset(o.dx + 8, row4))
        ..maxLines = null
        ..ellipsis = null;
      if (n.level == 0) {
        drawText(
          'START',
          Offset(o.dx - 52, o.dy + boxH / 2 - 6),
          46,
          fs: 8,
          bold: true,
          color: const Color(0xFF94A3B8),
          align: TextAlign.right,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_CpmPainter old) => true;
}
