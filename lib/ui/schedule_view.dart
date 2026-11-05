import 'package:flutter/material.dart';

import '../state.dart';
import 'pert_view.dart';
import 'scurve_view.dart';
import 'sheet_view.dart' show bandFg;

/// PROJECT SCHEDULE tab: one button on the strip, two views inside —
/// a slim sub-toggle switches between the PERT-CPM network and the
/// S-CURVE. `est.scheduleSub` remembers the choice across tab switches
/// (in-memory, like `drawingXfms`). Each child keeps its own Card +
/// toolbar; this only adds the toggle strip on top.
class ScheduleView extends StatelessWidget {
  const ScheduleView({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: est,
      builder: (context, _) {
        final sub = est.scheduleSub;
        return Column(
          children: [
            Container(
              height: 46,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              decoration: const BoxDecoration(
                color: Colors.white,
                border: Border(bottom: BorderSide(color: Color(0xFFE2E8F0))),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.calendar_month_outlined,
                    size: 16,
                    color: Color(0xFF64748B),
                  ),
                  const SizedBox(width: 8),
                  const Text(
                    'PROJECT SCHEDULE',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.5,
                      color: Color(0xFF334155),
                    ),
                  ),
                  const Spacer(),
                  _subToggle(sub),
                ],
              ),
            ),
            Expanded(child: sub == 0 ? const PertView() : const ScurveView()),
          ],
        );
      },
    );
  }

  Widget _subToggle(int sub) {
    Widget chip(int i, IconData icon, String label) {
      final sel = sub == i;
      return Tooltip(
        message: i == 0
            ? 'Activity network & critical path'
            : 'Planned progress curve',
        child: InkWell(
          onTap: () {
            est.scheduleSub = i;
            est.update();
          },
          borderRadius: BorderRadius.circular(7),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            decoration: BoxDecoration(
              color: sel
                  ? Color(est.project.themeColor)
                  : const Color(0xFFF1F5F9),
              borderRadius: BorderRadius.circular(7),
            ),
            child: Row(
              children: [
                Icon(
                  icon,
                  size: 14,
                  color: sel
                      ? bandFg(est.project.themeColor)
                      : const Color(0xFF64748B),
                ),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: sel
                        ? bandFg(est.project.themeColor)
                        : const Color(0xFF64748B),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: const Color(0xFFF1F5F9),
        borderRadius: BorderRadius.circular(9),
      ),
      child: Row(
        children: [
          chip(0, Icons.hub_outlined, 'PERT-CPM'),
          const SizedBox(width: 4),
          chip(1, Icons.show_chart, 'S-CURVE'),
        ],
      ),
    );
  }
}
