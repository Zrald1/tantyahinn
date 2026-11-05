import 'package:flutter/material.dart';

import '../state.dart';

/// A theme-color slot the user can customize.
class _Slot {
  final String key;
  final String label;
  final String hint;
  final int Function() get;
  final int fallback;
  const _Slot(this.key, this.label, this.hint, this.get, this.fallback);
}

List<_Slot> _slots() => [
  _Slot(
    'theme',
    'Theme accent',
    'App accent, table headers, grand total bar, dividers',
    () => est.project.themeColor,
    0xFFD5008F,
  ),
  _Slot(
    'section',
    'Section header',
    'Band behind "A — CONCRETING WORKS" rows',
    () => est.project.sectionColor,
    0xFF7C3AED,
  ),
  _Slot(
    'group',
    'Location / label',
    'Band behind location labels like "GROUND FLOOR"',
    () => est.project.groupColor,
    0xFFF5F3FF,
  ),
  _Slot(
    'subtotal',
    'Sub total',
    'SUB TOTAL rows under each section',
    () => est.project.subtotalColor,
    0xFFF3E8FF,
  ),
  _Slot(
    'summary',
    'Summary rows',
    'I / II / … rows above the grand total',
    () => est.project.summaryColor,
    0xFFFCE7F3,
  ),
];

/// Opens the theme dialog: per-slot swatches + a full color picker
/// (presets, HSV field, hue slider, hex input).
Future<void> showThemeDialog(BuildContext context) {
  return showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Sheet colors'),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final s in _slots()) _SlotRow(slot: s),
            const SizedBox(height: 6),
            const Text(
              'Tap a color to change it — pick a swatch, drag the '
              'color field, or type a hex code.',
              style: TextStyle(fontSize: 11, color: Color(0xFF64748B)),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            for (final s in _slots()) {
              est.setProjectColor(s.key, s.fallback);
            }
          },
          child: const Text('Reset all'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Done'),
        ),
      ],
    ),
  );
}

class _SlotRow extends StatelessWidget {
  final _Slot slot;
  const _SlotRow({required this.slot});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: est,
      builder: (context, _) {
        final c = Color(slot.get());
        return InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () async {
            final picked = await showColorPicker(context, c);
            if (picked != null)
              est.setProjectColor(slot.key, picked.toARGB32());
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
            child: Row(
              children: [
                Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                    color: c,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: const Color(0xFFCBD5E1)),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        slot.label,
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 12.5,
                        ),
                      ),
                      Text(
                        slot.hint,
                        style: const TextStyle(
                          fontSize: 10.5,
                          color: Color(0xFF64748B),
                        ),
                      ),
                    ],
                  ),
                ),
                Text(
                  '#${c.toARGB32().toRadixString(16).padLeft(8, '0').substring(2).toUpperCase()}',
                  style: const TextStyle(
                    fontSize: 11,
                    fontFamily: 'monospace',
                    color: Color(0xFF475569),
                  ),
                ),
                const SizedBox(width: 4),
                const Icon(
                  Icons.edit_outlined,
                  size: 14,
                  color: Color(0xFF94A3B8),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Full color picker dialog → preset swatches + HSV field + hue slider
/// + hex input. Returns the picked [Color] or null when cancelled.
Future<Color?> showColorPicker(BuildContext context, Color initial) {
  return showDialog<Color>(
    context: context,
    builder: (_) => _PickerDialog(initial: initial),
  );
}

class _PickerDialog extends StatefulWidget {
  final Color initial;
  const _PickerDialog({required this.initial});

  @override
  State<_PickerDialog> createState() => _PickerDialogState();
}

class _PickerDialogState extends State<_PickerDialog> {
  late HSVColor _hsv = HSVColor.fromColor(widget.initial);
  late final TextEditingController _hex = TextEditingController(
    text: _hexOf(_hsv.toColor()),
  );

  static const _presets = [
    0xFF1E4976,
    0xFFD5008F,
    0xFF7C3AED,
    0xFFB91C1C,
    0xFFB45309,
    0xFF166534,
    0xFF0F766E,
    0xFF0E7490,
    0xFFDBE4F0,
    0xFFCCFBF1,
    0xFFEDE9FE,
    0xFFFEE2E2,
    0xFFFEF3C7,
    0xFFDCFCE7,
    0xFFF1F5F9,
    0xFFCFFAFE,
    0xFFEAF1F8,
    0xFFFDF2F8,
    0xFFFFF7ED,
    0xFFFEF9C3,
    0xFFFFFFFF,
    0xFF1E293B,
    0xFF64748B,
    0xFF000000,
  ];

  String _hexOf(Color c) =>
      c.toARGB32().toRadixString(16).padLeft(8, '0').substring(2).toUpperCase();

  void _set(HSVColor h) => setState(() {
    _hsv = h;
    _hex.text = _hexOf(h.toColor());
  });

  void _onHex(String t) {
    var v = t.trim().replaceAll('#', '');
    if (v.length == 6) v = 'FF$v';
    final n = int.tryParse(v, radix: 16);
    if (n != null) setState(() => _hsv = HSVColor.fromColor(Color(n)));
  }

  @override
  void dispose() {
    _hex.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = _hsv.toColor();
    return AlertDialog(
      title: const Text('Pick a color'),
      content: SizedBox(
        width: 320,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // preset swatches
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final p in _presets)
                  InkWell(
                    onTap: () => _set(HSVColor.fromColor(Color(p))),
                    child: Container(
                      width: 24,
                      height: 24,
                      decoration: BoxDecoration(
                        color: Color(p),
                        borderRadius: BorderRadius.circular(5),
                        border: Border.all(
                          color: color.toARGB32() == p
                              ? const Color(0xFF1E4976)
                              : const Color(0xFFCBD5E1),
                          width: color.toARGB32() == p ? 2 : 1,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 14),
            // saturation/value field
            _SvField(hsv: _hsv, onChanged: _set),
            const SizedBox(height: 10),
            // hue slider
            _HueBar(hsv: _hsv, onChanged: _set),
            const SizedBox(height: 12),
            Row(
              children: [
                Container(
                  width: 42,
                  height: 34,
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: const Color(0xFFCBD5E1)),
                  ),
                ),
                const SizedBox(width: 10),
                SizedBox(
                  width: 100,
                  child: TextField(
                    controller: _hex,
                    onChanged: _onHex,
                    style: const TextStyle(
                      fontSize: 12,
                      fontFamily: 'monospace',
                    ),
                    decoration: const InputDecoration(
                      isDense: true,
                      prefixText: '#',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, color),
          child: const Text('Select'),
        ),
      ],
    );
  }
}

/// Saturation/value square: white → hue horizontally,
/// transparent → black vertically. Drag to set S & V.
class _SvField extends StatelessWidget {
  final HSVColor hsv;
  final ValueChanged<HSVColor> onChanged;
  const _SvField({required this.hsv, required this.onChanged});

  void _pick(Offset p, Size size) {
    final s = (p.dx / size.width).clamp(0.0, 1.0);
    final v = 1 - (p.dy / size.height).clamp(0.0, 1.0);
    onChanged(hsv.withSaturation(s).withValue(v));
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (ctx, box) {
        final size = Size(box.maxWidth, 150);
        return GestureDetector(
          onPanDown: (d) => _pick(d.localPosition, size),
          onPanUpdate: (d) => _pick(d.localPosition, size),
          child: SizedBox(
            width: size.width,
            height: size.height,
            child: Stack(
              children: [
                Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(6),
                      gradient: LinearGradient(
                        colors: [
                          Colors.white,
                          HSVColor.fromAHSV(1, hsv.hue, 1, 1).toColor(),
                        ],
                      ),
                    ),
                  ),
                ),
                Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(6),
                      gradient: const LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Colors.transparent, Colors.black],
                      ),
                    ),
                  ),
                ),
                Positioned(
                  left: hsv.saturation * size.width - 7,
                  top: (1 - hsv.value) * size.height - 7,
                  child: IgnorePointer(
                    child: Container(
                      width: 14,
                      height: 14,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 2),
                        boxShadow: const [
                          BoxShadow(color: Colors.black45, blurRadius: 3),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Rainbow hue bar; drag sets the hue component.
class _HueBar extends StatelessWidget {
  final HSVColor hsv;
  final ValueChanged<HSVColor> onChanged;
  const _HueBar({required this.hsv, required this.onChanged});

  void _pick(Offset p, Size size) {
    final h = (p.dx / size.width).clamp(0.0, 1.0) * 360;
    onChanged(hsv.withHue(h.clamp(0.0, 359.99)));
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (ctx, box) {
        final size = Size(box.maxWidth, 14);
        return GestureDetector(
          onPanDown: (d) => _pick(d.localPosition, size),
          onPanUpdate: (d) => _pick(d.localPosition, size),
          child: SizedBox(
            width: size.width,
            height: size.height,
            child: Stack(
              children: [
                Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(7),
                      gradient: LinearGradient(
                        colors: [
                          for (var h = 0; h <= 360; h += 60)
                            HSVColor.fromAHSV(1, h.toDouble(), 1, 1).toColor(),
                        ],
                      ),
                    ),
                  ),
                ),
                Positioned(
                  left: (hsv.hue / 360) * size.width - 6,
                  top: -1,
                  child: IgnorePointer(
                    child: Container(
                      width: 12,
                      height: 16,
                      decoration: BoxDecoration(
                        color: hsv.toColor(),
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: Colors.white, width: 2),
                        boxShadow: const [
                          BoxShadow(color: Colors.black45, blurRadius: 3),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
