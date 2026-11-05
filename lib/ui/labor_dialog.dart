import 'package:flutter/material.dart';

import '../state.dart';

/// Labor-cost rate dialog: labor = N% of material cost. Changing the
/// rate recomputes labor on every item still using automatic labor —
/// items whose labor was typed or erased by hand are left untouched.
Future<void> showLaborDialog(BuildContext context) {
  final c = TextEditingController(
    text: (est.laborRate * 100).toStringAsFixed(0),
  );
  const presets = [15, 20, 25, 30, 35, 40];

  void apply(double pct) {
    if (pct < 0 || pct > 200) return;
    est.setLaborRate(pct / 100);
  }

  return showDialog(
    context: context,
    builder: (ctx) => ListenableBuilder(
      listenable: est,
      builder: (ctx, _) {
        final pct = est.laborRate * 100;
        return AlertDialog(
          title: const Text('Labor cost'),
          content: SizedBox(
            width: 360,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Labor = ${pct.toStringAsFixed(pct == pct.roundToDouble() ? 0 : 2)}% of material cost',
                  style: const TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 14),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final p in presets)
                      ChoiceChip(
                        label: Text('$p%'),
                        selected: pct == p,
                        onSelected: (_) {
                          c.text = '$p';
                          apply(p.toDouble());
                        },
                      ),
                  ],
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: c,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    isDense: true,
                    labelText: 'Custom rate',
                    suffixText: '%',
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (s) {
                    final v = double.tryParse(s.trim());
                    if (v != null) apply(v);
                  },
                ),
                const SizedBox(height: 12),
                const Text(
                  'Applies to every item still using automatic labor. '
                  'Items whose labor you typed or erased keep their own '
                  'value — erase a cost field to zero it.',
                  style: TextStyle(fontSize: 11, color: Color(0xFF64748B)),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                c.text = '30';
                apply(30);
              },
              child: const Text('Reset 30%'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Done'),
            ),
          ],
        );
      },
    ),
  );
}
