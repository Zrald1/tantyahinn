import 'dart:convert';

import 'package:flutter/material.dart';

import '../models.dart';
import '../state.dart';

/// The top-bar "Template" control: shows the active document template's
/// name and opens the gallery (DepEd / Private built-ins plus the
/// user's saved templates) so switching is one click.
class TemplateButton extends StatelessWidget {
  const TemplateButton({super.key});

  @override
  Widget build(BuildContext context) {
    final t = est.activeTemplate;
    return Tooltip(
      message: 'Document template — letterhead + signatories',
      waitDuration: const Duration(milliseconds: 350),
      child: InkWell(
        key: const Key('template-btn'),
        borderRadius: BorderRadius.circular(10),
        onTap: () => showGeneralDialog(
          context: context,
          barrierDismissible: true,
          barrierLabel: 'Close',
          barrierColor: Colors.black45,
          transitionDuration: const Duration(milliseconds: 260),
          // the dialog itself zooms in — a scale+fade entrance
          transitionBuilder: (ctx, a, _, child) => FadeTransition(
            opacity: CurvedAnimation(parent: a, curve: Curves.easeOut),
            child: ScaleTransition(
              scale: CurvedAnimation(parent: a, curve: Curves.easeOutBack),
              child: child,
            ),
          ),
          pageBuilder: (_, _, _) => const TemplateGalleryDialog(),
        ),
        child: Container(
          height: 34,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: const Color(0xFFF1F5F9),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: const Color(0xFFE2E8F0)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.dashboard_customize_outlined,
                size: 15,
                color: Color(0xFF64748B),
              ),
              const SizedBox(width: 6),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 130),
                child: Text(
                  t.name,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF334155),
                  ),
                ),
              ),
              const Icon(
                Icons.arrow_drop_down,
                size: 18,
                color: Color(0xFF64748B),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The template gallery. Each card shows a live animated preview — the
/// letterhead "types" in line by line, the navy rule draws itself, the
/// table rows wipe across, then the signature block signs the sheet —
/// so the user sees the document being written, not a static picture.
/// Hover lifts + zooms the sheet; the magnifier corner opens a large
/// animated preview. New snapshots the current setup; Upload imports a
/// .tpt/.json template file.
class TemplateGalleryDialog extends StatelessWidget {
  const TemplateGalleryDialog({super.key});

  @override
  Widget build(BuildContext context) {
    return Dialog(
      elevation: 12,
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 700, maxHeight: 580),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(22, 16, 22, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      color: const Color(0xFF1E4976).withValues(alpha: .08),
                      borderRadius: BorderRadius.circular(9),
                    ),
                    child: const Icon(
                      Icons.dashboard_customize_outlined,
                      size: 18,
                      color: Color(0xFF1E4976),
                    ),
                  ),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Document template',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                            color: Color(0xFF0F172A),
                          ),
                        ),
                        SizedBox(height: 2),
                        Text(
                          'Applied to the BOQ, POW and every export',
                          style: TextStyle(
                            fontSize: 11.5,
                            color: Color(0xFF64748B),
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close, size: 18),
                    visualDensity: VisualDensity.compact,
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Flexible(
                child: ListenableBuilder(
                  listenable: est,
                  builder: (context, _) {
                    final ts = est.docTemplates;
                    return GridView.count(
                      crossAxisCount: 3,
                      mainAxisSpacing: 16,
                      crossAxisSpacing: 16,
                      childAspectRatio: 0.74,
                      shrinkWrap: true,
                      children: [for (final t in ts) _TemplateCard(t: t)],
                    );
                  },
                ),
              ),
              const SizedBox(height: 14),
              Container(height: 1, color: const Color(0xFFF1F5F9)),
              const SizedBox(height: 10),
              Row(
                children: [
                  FilledButton.tonalIcon(
                    key: const Key('tpl-new'),
                    onPressed: () => _saveAs(context),
                    icon: const Icon(Icons.add, size: 16),
                    label: const Text('New from current'),
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF1E4976).withValues(
                        alpha: .08,
                      ),
                      foregroundColor: const Color(0xFF1E4976),
                      textStyle: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    key: const Key('tpl-upload'),
                    onPressed: () => _upload(context),
                    icon: const Icon(Icons.upload_file_outlined, size: 15),
                    label: const Text('Upload template'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFF475569),
                      side: const BorderSide(color: Color(0xFFE2E8F0)),
                      textStyle: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _saveAs(BuildContext context) async {
    final name = await _askName(context);
    if (name == null) return;
    final t = est.saveAsTemplate(name);
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Saved "${t.name}"')));
    }
  }

  Future<void> _upload(BuildContext context) async {
    final name = await est.importTemplateFile();
    if (!context.mounted || name == null) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('Template "$name" added')));
  }

  static Future<String?> _askName(BuildContext context, [String? initial]) {
    final c = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Template name', style: TextStyle(fontSize: 15)),
        content: TextField(
          controller: c,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'e.g. Private Estimate',
            isDense: true,
          ),
          onSubmitted: (s) => Navigator.pop(d, s),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(d, c.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }
}

/// A template card: hover lifts it and zooms the sheet preview ~7%;
/// every entrance replays the "writing" animation (letterhead types in,
/// rule draws, rows wipe, signature signs). Tap applies the template.
class _TemplateCard extends StatefulWidget {
  final DocTemplate t;
  const _TemplateCard({required this.t});

  @override
  State<_TemplateCard> createState() => _TemplateCardState();
}

class _TemplateCardState extends State<_TemplateCard>
    with SingleTickerProviderStateMixin {
  bool _hover = false;
  bool _pressed = false;
  late final AnimationController _write = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2200),
  )..forward();

  @override
  void dispose() {
    _write.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.t;
    final active = est.project.template == t.id;
    return MouseRegion(
      onEnter: (_) {
        setState(() => _hover = true);
        _write.forward(from: 0); // replay the writing on hover
      },
      onExit: (_) => setState(() {
        _hover = false;
        _pressed = false;
      }),
      child: GestureDetector(
        onTapDown: (_) => setState(() => _pressed = true),
        onTapCancel: () => setState(() => _pressed = false),
        onTapUp: (_) => setState(() => _pressed = false),
        child: InkWell(
          key: Key('tpl-${t.id}'),
          borderRadius: BorderRadius.circular(12),
          onTap: () async {
            await est.applyTemplate(t.id);
            if (context.mounted) Navigator.pop(context);
          },
          child: AnimatedScale(
            scale: _pressed ? 0.97 : (_hover ? 1.03 : 1.0),
            duration: const Duration(milliseconds: 140),
            curve: Curves.easeOut,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                color: Colors.white,
                border: Border.all(
                  color: active
                      ? const Color(0xFF1E4976)
                      : _hover
                      ? const Color(0xFF93C5FD)
                      : const Color(0xFFE2E8F0),
                  width: active ? 2 : 1,
                ),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF1E4976).withValues(
                      alpha: _hover || active ? .14 : .06,
                    ),
                    blurRadius: _hover ? 16 : 8,
                    offset: Offset(0, _hover ? 6 : 2),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: Stack(
                      children: [
                        Positioned.fill(
                          child: _TemplatePreview(t: t, anim: _write),
                        ),
                        if (_hover)
                          Positioned(
                            top: 4,
                            right: 4,
                            child: _ZoomBadge(
                              onTap: () => _zoom(context, t),
                            ),
                          ),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 5,
                    ),
                    decoration: const BoxDecoration(
                      color: Color(0xFFF8FAFC),
                      borderRadius: BorderRadius.vertical(
                        bottom: Radius.circular(11),
                      ),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            t.name,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: active
                                  ? const Color(0xFF1E4976)
                                  : const Color(0xFF334155),
                            ),
                          ),
                        ),
                        if (active)
                          const Icon(
                            Icons.check_circle,
                            size: 13,
                            color: Color(0xFF1E4976),
                          ),
                        _cardMenu(context),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _cardMenu(BuildContext context) {
    final t = widget.t;
    return PopupMenuButton<String>(
      icon: const Icon(Icons.more_vert, size: 14, color: Color(0xFF94A3B8)),
      tooltip: 'Template actions',
      padding: EdgeInsets.zero,
      itemBuilder: (_) => [
        if (!t.builtin) ...[
          const PopupMenuItem(
            value: 'update',
            child: Text('Update from current'),
          ),
          const PopupMenuItem(value: 'rename', child: Text('Rename')),
        ],
        const PopupMenuItem(value: 'export', child: Text('Export file')),
        if (t.builtin)
          const PopupMenuItem(
            value: 'reset',
            child: Text('Reset to defaults'),
          )
        else
          const PopupMenuItem(
            value: 'delete',
            child: Text('Delete', style: TextStyle(color: Colors.redAccent)),
          ),
      ],
      onSelected: (v) async {
        switch (v) {
          case 'update':
            est.updateTemplateFromCurrent(t);
          case 'rename':
            final n = await TemplateGalleryDialog._askName(context, t.name);
            if (n != null && n.trim().isNotEmpty) {
              t.name = n.trim();
              est.update();
            }
          case 'export':
            await est.exportTemplate(t);
          case 'reset':
            est.resetTemplate(t);
          case 'delete':
            est.deleteTemplate(t);
        }
      },
    );
  }

  /// The magnifier opens a full-size animated preview — the same
  /// writing animation at readable size inside a zoom-in dialog.
  void _zoom(BuildContext context, DocTemplate t) {
    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Close preview',
      barrierColor: Colors.black54,
      transitionDuration: const Duration(milliseconds: 220),
      transitionBuilder: (ctx, a, _, child) => FadeTransition(
        opacity: a,
        child: ScaleTransition(
          scale: CurvedAnimation(parent: a, curve: Curves.easeOutBack),
          child: child,
        ),
      ),
      pageBuilder: (_, _, _) => _ZoomPreview(t: t),
    );
  }
}

class _ZoomBadge extends StatelessWidget {
  final VoidCallback onTap;
  const _ZoomBadge({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Preview',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Container(
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: .92),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: const Color(0xFFE2E8F0)),
          ),
          child: const Icon(
            Icons.zoom_in,
            size: 13,
            color: Color(0xFF1E4976),
          ),
        ),
      ),
    );
  }
}

/// The enlarged animated preview: the sheet writes itself in front of
/// the user — letterhead types line by line, the rule draws, the table
/// fills, the signature block signs off. Loops with a pause.
class _ZoomPreview extends StatefulWidget {
  final DocTemplate t;
  const _ZoomPreview({required this.t});

  @override
  State<_ZoomPreview> createState() => _ZoomPreviewState();
}

class _ZoomPreviewState extends State<_ZoomPreview>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 4200),
  )..forward();

  @override
  void initState() {
    super.initState();
    // writing segment ~55% of the cycle, hold, then loop
    _c.addStatusListener((s) {
      if (s == AnimationStatus.completed) _c.forward(from: 0);
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Material(
        color: Colors.transparent,
        child: Container(
          width: 380,
          height: 480,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: const Color(0xFFF1F5F9),
            borderRadius: BorderRadius.circular(16),
            boxShadow: const [
              BoxShadow(
                color: Colors.black38,
                blurRadius: 30,
                offset: Offset(0, 10),
              ),
            ],
          ),
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.t.name,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF334155),
                      ),
                    ),
                  ),
                  InkWell(
                    onTap: () => Navigator.pop(context),
                    child: const Icon(
                      Icons.close,
                      size: 16,
                      color: Color(0xFF64748B),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Expanded(child: _TemplatePreview(t: widget.t, anim: _c, big: true)),
            ],
          ),
        ),
      ),
    );
  }
}

/// A shrunken sheet that draws itself: letterhead lines stagger-fade
/// in, the navy rule wipes left→right, table rows wipe in, then the
/// signature block fades up and the name lines draw — driven by [anim]
/// so the same animation serves card + zoomed previews.
class _TemplatePreview extends StatelessWidget {
  final DocTemplate t;
  final Animation<double> anim;
  final bool big;
  const _TemplatePreview({required this.t, required this.anim, this.big = false});

  double _v(double a, double b) => CurvedAnimation(
    parent: anim,
    curve: Interval(a, b, curve: Curves.easeOutCubic),
  ).value;

  @override
  Widget build(BuildContext context) {
    const ink = Color(0xFF334155);
    const faint = Color(0xFF94A3B8);
    final fs = big ? 1.9 : 1.0;
    return AnimatedBuilder(
      animation: anim,
      builder: (context, _) {
        // staggered timeline inside the first ~70% of the cycle
        final head = t.showLetterhead ? t.letterhead.take(4).toList() : [];
        Widget typedLine(String s, int i, bool bold) => Opacity(
          opacity: _v(0.03 + i * .05, 0.13 + i * .05),
          child: Transform.translate(
            offset: Offset(0, (1 - _v(0.03 + i * .05, 0.13 + i * .05)) * 4),
            child: Text(
              s,
              maxLines: 1,
              overflow: TextOverflow.clip,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 4.5 * fs,
                height: 1.3,
                fontWeight: bold ? FontWeight.w800 : FontWeight.w400,
                color: ink,
              ),
            ),
          ),
        );
        Widget wipe(double h, Color c, double a, double b) =>
            FractionallySizedBox(
              widthFactor: _v(a, b).clamp(0.001, 1.0),
              alignment: Alignment.centerLeft,
              child: Container(
                height: h,
                margin: const EdgeInsets.symmetric(vertical: 2),
                decoration: BoxDecoration(
                  color: c,
                  borderRadius: BorderRadius.circular(1.5),
                ),
              ),
            );
        return Container(
          margin: const EdgeInsets.all(8),
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: Colors.white,
            border: Border.all(color: const Color(0xFFCBD5E1)),
            borderRadius: BorderRadius.circular(4),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: .05),
                blurRadius: 6,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (t.showLetterhead) ...[
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (t.logoB64 != null)
                      Padding(
                        padding: const EdgeInsets.only(right: 4),
                        child: Image.memory(
                          base64Decode(t.logoB64!),
                          width: 14 * fs,
                          height: 14 * fs,
                          fit: BoxFit.cover,
                        ),
                      )
                    else
                      Container(
                        width: 14 * fs,
                        height: 14 * fs,
                        margin: const EdgeInsets.only(right: 4),
                        decoration: BoxDecoration(
                          color: const Color(0xFFE2E8F0),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    Expanded(
                      child: Column(
                        children: [
                          for (var i = 0; i < head.length; i++)
                            typedLine(head[i], i, i == t.letterheadBold),
                        ],
                      ),
                    ),
                  ],
                ),
                FractionallySizedBox(
                  widthFactor: _v(0.24, 0.32).clamp(0.001, 1.0),
                  alignment: Alignment.centerLeft,
                  child: Container(
                    height: 1.5 * fs,
                    margin: const EdgeInsets.symmetric(vertical: 3),
                    color: const Color(0xFF1E4976),
                  ),
                ),
              ] else
                const SizedBox(height: 4),
              for (
                var i = 0;
                i < (t.showSignatories ? 4 : 6);
                i++
              )
                wipe(
                  5 * fs,
                  i == 0 ? const Color(0xFFDBE4F0) : const Color(0xFFF1F5F9),
                  0.34 + i * .05,
                  0.44 + i * .05,
                ),
              const Spacer(),
              if (t.showSignatories)
                Opacity(
                  opacity: _v(0.58, 0.68),
                  child: Transform.translate(
                    offset: Offset(0, (1 - _v(0.58, 0.68)) * 6),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        for (var i = 0; i < 2; i++)
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  i < t.signatories.length
                                      ? '${t.signatories[i].label}:'
                                      : '',
                                  maxLines: 1,
                                  style: TextStyle(
                                    fontSize: 4 * fs,
                                    color: faint,
                                  ),
                                ),
                                SizedBox(height: 5 * fs),
                                // the pen stroke — the signature line
                                // draws itself across
                                FractionallySizedBox(
                                  widthFactor: _v(
                                    0.66 + i * .06,
                                    0.78 + i * .06,
                                  ).clamp(0.001, 1.0),
                                  alignment: Alignment.centerLeft,
                                  child: Container(
                                    height: 1,
                                    margin: const EdgeInsets.only(right: 6),
                                    color: ink,
                                  ),
                                ),
                                Text(
                                  i < t.signatories.length
                                      ? t.signatories[i].name
                                      : '',
                                  maxLines: 1,
                                  overflow: TextOverflow.clip,
                                  style: TextStyle(
                                    fontSize: 4.5 * fs,
                                    fontWeight: FontWeight.w800,
                                    color: ink,
                                  ),
                                ),
                                Text(
                                  i < t.signatories.length
                                      ? t.signatories[i].position
                                      : '',
                                  maxLines: 1,
                                  overflow: TextOverflow.clip,
                                  style: TextStyle(
                                    fontSize: 4 * fs,
                                    color: faint,
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}
