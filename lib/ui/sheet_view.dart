import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../formula.dart';
import '../main.dart';
import '../models.dart';
import '../state.dart';

/// Left pane: live preview of the BOQ sheet exactly as it will be exported.
/// Cells (qty, prices, description, group headers) are editable in place.
class SheetView extends StatelessWidget {
  const SheetView({super.key});

  static const _colQty = 70.0;
  static const _colUnit = 64.0;
  static const _colCost = 96.0;
  static const _colAmt = 110.0;
  static const _colNo = 52.0;
  static const _colAct = 34.0;

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
                _SheetToolbar(),
                const Divider(height: 1),
                Expanded(
                  child: est.sections.isEmpty
                      ? const _EmptyState()
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
                                      'DETAILED ESTIMATES',
                                      style: TextStyle(
                                        fontWeight: FontWeight.w800,
                                        fontSize: 16,
                                        letterSpacing: 0.5,
                                      ),
                                    ),
                                    const SizedBox(height: 8),
                                    _TableHeader(),
                                    ..._buildSections(context),
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

  List<Widget> _buildSections(BuildContext context) {
    final out = <Widget>[];
    for (final sec in est.sections) {
      out.add(_SectionHeaderRow(section: sec, letter: est.letterOf(sec)));
      for (final line in sec.lines) {
        if (line.kind == BoqLineKind.groupHeader) {
          out.add(_GroupHeaderRow(section: sec, line: line));
        } else {
          out.add(_ItemRow(section: sec, line: line));
        }
      }
      out.add(_SubtotalRow(section: sec));
    }
    return out;
  }
}

// ---------------------------------------------------------------------------

class _SheetToolbar extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      child: Row(
        children: [
          const Icon(
            Icons.description_outlined,
            size: 18,
            color: Color(0xFF64748B),
          ),
          const SizedBox(width: 8),
          const Text(
            'BOQ SHEET',
            style: TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 12,
              letterSpacing: 1,
              color: Color(0xFF475569),
            ),
          ),
          const Spacer(),
          Flexible(
            child: Text(
              '${est.sections.length} section(s)  ·  ${est.sections.fold<int>(0, (s, x) => s + x.lines.where((l) => l.kind == BoqLineKind.item).length)} items',
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11, color: Color(0xFF94A3B8)),
            ),
          ),
          const SizedBox(width: 12),
          TextButton.icon(
            onPressed: () async {
              final t = await promptSectionTitle(context);
              if (t != null) est.addSection(t);
            },
            icon: const Icon(Icons.add, size: 16),
            label: const Text('Section', style: TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }
}

/// Asks for a section title ("ROOFING WORKS"); returns null on cancel —
/// shared by the toolbar button and the right-click insert menus.
Future<String?> promptSectionTitle(BuildContext context) async {
  final c = TextEditingController();
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('New section'),
      content: TextField(
        controller: c,
        autofocus: true,
        decoration: const InputDecoration(
          labelText: 'Section title',
          hintText: 'e.g. ROOFING WORKS',
        ),
        onSubmitted: (_) => Navigator.pop(ctx, true),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Add'),
        ),
      ],
    ),
  );
  return (ok == true && c.text.trim().isNotEmpty) ? c.text.trim() : null;
}

/// Section row actions — shared by the "…" button and right-click.
List<PopupMenuEntry<String>> _sectionMenuItems() => const [
  PopupMenuItem(value: 'rename', child: Text('Rename section')),
  PopupMenuItem(value: 'secAbove', child: Text('Insert section above…')),
  PopupMenuItem(value: 'secBelow', child: Text('Insert section below…')),
  PopupMenuItem(value: 'header', child: Text('Add group header')),
  PopupMenuItem(value: 'item', child: Text('Add blank item')),
  PopupMenuItem(
    value: 'delete',
    child: Text('Delete section', style: TextStyle(color: Colors.redAccent)),
  ),
];

Future<void> _sectionAction(
  BuildContext context,
  BoqSection section,
  String v,
) async {
  switch (v) {
    case 'rename':
      final c = TextEditingController(text: section.title);
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Rename section'),
          content: TextField(controller: c, autofocus: true),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Save'),
            ),
          ],
        ),
      );
      if (ok == true) est.renameSection(section, c.text);
    case 'secAbove':
      final t = await promptSectionTitle(context);
      if (t != null) {
        est.insertSectionAt(est.sections.indexOf(section), t);
      }
    case 'secBelow':
      final t = await promptSectionTitle(context);
      if (t != null) {
        est.insertSectionAt(est.sections.indexOf(section) + 1, t);
      }
    case 'header':
      est.addLine(section, BoqLine.header('NEW LOCATION'));
    case 'item':
      est.addLine(section, BoqLine(description: 'New item', unit: 'pcs'));
    case 'delete':
      est.removeSection(section);
  }
}

Future<void> _showSectionMenu(
  BuildContext context,
  BoqSection section,
  Offset pos,
) async {
  final v = await showMenu<String>(
    context: context,
    position: RelativeRect.fromLTRB(pos.dx, pos.dy, pos.dx, pos.dy),
    items: _sectionMenuItems(),
  );
  if (v != null && context.mounted) {
    await _sectionAction(context, section, v);
  }
}

/// Right-click on an item or group-header row: insert rows around it,
/// grow the structure, or delete it — like Excel's row menu.
Future<void> _rowMenu(
  BuildContext context,
  Offset pos,
  BoqSection sec,
  BoqLine line,
) async {
  final v = await showMenu<String>(
    context: context,
    position: RelativeRect.fromLTRB(pos.dx, pos.dy, pos.dx, pos.dy),
    items: const [
      PopupMenuItem(value: 'itemAbove', child: Text('Insert item above')),
      PopupMenuItem(value: 'itemBelow', child: Text('Insert item below')),
      PopupMenuItem(
        value: 'headerBelow',
        child: Text('Insert group header below'),
      ),
      PopupMenuItem(value: 'secBelow', child: Text('Insert section below…')),
      PopupMenuDivider(),
      PopupMenuItem(
        value: 'delete',
        child: Text('Delete row', style: TextStyle(color: Colors.redAccent)),
      ),
    ],
  );
  if (v == null || !context.mounted) return;
  final i = sec.lines.indexOf(line);
  switch (v) {
    case 'itemAbove':
      est.insertLineAt(sec, i, BoqLine(description: 'New item', unit: 'pcs'));
    case 'itemBelow':
      est.insertLineAt(
        sec,
        i + 1,
        BoqLine(description: 'New item', unit: 'pcs'),
      );
    case 'headerBelow':
      est.insertLineAt(sec, i + 1, BoqLine.header('NEW LABEL'));
    case 'secBelow':
      final t = await promptSectionTitle(context);
      if (t != null) {
        est.insertSectionAt(est.sections.indexOf(sec) + 1, t);
      }
    case 'delete':
      est.removeLine(sec, line);
  }
}

/// Right-click on a SUB TOTAL band: append rows to the section, insert
/// another section after it, or delete the section.
Future<void> _subtotalMenu(
  BuildContext context,
  Offset pos,
  BoqSection sec,
) async {
  final v = await showMenu<String>(
    context: context,
    position: RelativeRect.fromLTRB(pos.dx, pos.dy, pos.dx, pos.dy),
    items: const [
      PopupMenuItem(value: 'item', child: Text('Add item row')),
      PopupMenuItem(value: 'header', child: Text('Add group header')),
      PopupMenuItem(value: 'secBelow', child: Text('Insert section below…')),
      PopupMenuDivider(),
      PopupMenuItem(
        value: 'delete',
        child: Text(
          'Delete section',
          style: TextStyle(color: Colors.redAccent),
        ),
      ),
    ],
  );
  if (v == null || !context.mounted) return;
  switch (v) {
    case 'item':
      est.addLine(sec, BoqLine(description: 'New item', unit: 'pcs'));
    case 'header':
      est.addLine(sec, BoqLine.header('NEW LABEL'));
    case 'secBelow':
      final t = await promptSectionTitle(context);
      if (t != null) {
        est.insertSectionAt(est.sections.indexOf(sec) + 1, t);
      }
    case 'delete':
      est.removeSection(sec);
  }
}

/// The office letterhead shown on BOQ and POW. Every line is
/// click-to-type; right-click a line for insert/emphasize/delete and
/// right-click the header for the logo actions (swap the DepEd seal for
/// any agency or company logo). The logo badge sits at the left, roughly
/// where the export anchors it. Renders nothing under the 'private'
/// (free) template — that's the whole point of it.
class OfficeHeader extends StatelessWidget {
  const OfficeHeader({super.key});

  @override
  Widget build(BuildContext context) {
    final p = est.project;
    if (p.isPrivate) return const SizedBox.shrink();
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onSecondaryTapUp: (d) => _headerMenu(context, d.globalPosition),
      child: SizedBox(
        width: double.infinity,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            const _LogoBadge(),
            for (var i = 0; i < p.letterhead.length; i++) _line(context, i),
          ],
        ),
      ),
    );
  }

  Widget _line(BuildContext context, int i) {
    final p = est.project;
    final bold = i == p.letterheadBold;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onSecondaryTapUp: (d) => _lineMenu(context, d.globalPosition, i),
      child: SizedBox(
        width: double.infinity,
        child: InlineEdit(
          value: p.letterhead[i],
          align: TextAlign.center,
          hint: 'header line — click to type',
          style: TextStyle(
            fontSize: bold ? 14 : 12,
            fontWeight: bold ? FontWeight.w800 : FontWeight.w500,
            color: const Color(0xFF1E293B),
            height: 1.5,
          ),
          onCommit: (s) => est.setLetterheadLine(i, s),
        ),
      ),
    );
  }

  void _lineMenu(BuildContext context, Offset pos, int i) async {
    final p = est.project;
    final isBold = i == p.letterheadBold;
    final v = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(pos.dx, pos.dy, pos.dx, pos.dy),
      items: [
        const PopupMenuItem(value: 'above', child: Text('Insert line above')),
        const PopupMenuItem(value: 'below', child: Text('Insert line below')),
        PopupMenuItem(
          value: 'bold',
          child: Text(isBold ? 'Remove emphasis' : 'Emphasize this line'),
        ),
        if (p.letterhead.length > 1)
          const PopupMenuItem(
            value: 'delete',
            child: Text(
              'Delete line',
              style: TextStyle(color: Colors.redAccent),
            ),
          ),
      ],
    );
    switch (v) {
      case 'above':
        est.insertLetterheadLine(i);
      case 'below':
        est.insertLetterheadLine(i + 1);
      case 'bold':
        est.setLetterheadBold(isBold ? -1 : i);
      case 'delete':
        est.removeLetterheadLine(i);
    }
  }

  void _headerMenu(BuildContext context, Offset pos) async {
    final hasLogo = est.project.logoB64 != null;
    final v = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(pos.dx, pos.dy, pos.dx, pos.dy),
      items: [
        PopupMenuItem(
          value: 'logo',
          child: Text(hasLogo ? 'Replace logo…' : 'Add logo…'),
        ),
        if (hasLogo)
          const PopupMenuItem(
            value: 'nologo',
            child: Text(
              'Remove logo',
              style: TextStyle(color: Colors.redAccent),
            ),
          ),
        const PopupMenuItem(value: 'line', child: Text('Add line at bottom')),
        const PopupMenuDivider(),
        const PopupMenuItem(
          value: 'reset',
          child: Text('Reset to DepEd letterhead'),
        ),
      ],
    );
    switch (v) {
      case 'logo':
        est.pickLogo();
      case 'nologo':
        est.clearLogo();
      case 'line':
        est.insertLetterheadLine(est.project.letterhead.length);
      case 'reset':
        est.resetLetterhead();
    }
  }
}

/// The letterhead logo: shows the chosen image (hover reveals
/// replace/remove chips, right-click a menu) or a faint "logo" button
/// that opens the file picker.
class _LogoBadge extends StatefulWidget {
  const _LogoBadge();

  @override
  State<_LogoBadge> createState() => _LogoBadgeState();
}

class _LogoBadgeState extends State<_LogoBadge> {
  bool _hover = false;

  Uint8List? _bytes() {
    final b64 = est.project.logoB64;
    if (b64 == null) return null;
    try {
      return base64Decode(b64);
    } catch (_) {
      return null;
    }
  }

  void _menu(BuildContext context, Offset pos) async {
    final v = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(pos.dx, pos.dy, pos.dx, pos.dy),
      items: const [
        PopupMenuItem(value: 'pick', child: Text('Replace logo…')),
        PopupMenuItem(
          value: 'clear',
          child: Text('Remove logo', style: TextStyle(color: Colors.redAccent)),
        ),
      ],
    );
    switch (v) {
      case 'pick':
        est.pickLogo();
      case 'clear':
        est.clearLogo();
    }
  }

  Widget _chip(IconData icon, String tip, VoidCallback onTap) {
    return Tooltip(
      message: tip,
      child: InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(3),
          decoration: const BoxDecoration(
            color: Colors.white,
            shape: BoxShape.circle,
          ),
          child: Icon(icon, size: 12, color: const Color(0xFF64748B)),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes();
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onSecondaryTapUp: (d) => _menu(context, d.globalPosition),
        child: bytes == null
            ? Opacity(
                opacity: _hover ? 1 : 0.45,
                child: OutlinedButton.icon(
                  onPressed: () => est.pickLogo(),
                  icon: const Icon(
                    Icons.add_photo_alternate_outlined,
                    size: 14,
                  ),
                  label: const Text('logo', style: TextStyle(fontSize: 11)),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFF94A3B8),
                    side: const BorderSide(color: Color(0xFFCBD5E1)),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    visualDensity: VisualDensity.compact,
                  ),
                ),
              )
            : Stack(
                clipBehavior: Clip.none,
                children: [
                  Image.memory(bytes, height: 64, fit: BoxFit.contain),
                  if (_hover)
                    Positioned(
                      top: -8,
                      right: -10,
                      child: Row(
                        children: [
                          _chip(
                            Icons.refresh,
                            'Replace logo',
                            () => est.pickLogo(),
                          ),
                          const SizedBox(width: 2),
                          _chip(
                            Icons.close,
                            'Remove logo',
                            () => est.clearLogo(),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
      ),
    );
  }
}

class ProjectBlock extends StatelessWidget {
  const ProjectBlock({super.key});

  @override
  Widget build(BuildContext context) {
    final p = est.project;
    final date = DateFormat('MMMM d, yyyy').format(p.date);
    Widget edit(
      String v,
      void Function(String) set, {
      TextAlign align = TextAlign.left,
    }) => InlineEdit(
      value: v,
      align: align,
      style: const TextStyle(fontSize: 12),
      onCommit: (s) {
        set(s);
        est.update();
      },
    );
    Widget row(String l, Widget v, [String? l2, Widget? v2]) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 1.5),
      child: Row(
        children: [
          SizedBox(
            width: 140,
            child: Text(
              '$l:',
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12),
            ),
          ),
          Expanded(child: v),
          if (l2 != null)
            SizedBox(
              width: 70,
              child: Text(
                '$l2:',
                textAlign: TextAlign.right,
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 12,
                ),
              ),
            ),
          if (v2 != null)
            SizedBox(
              width: 170,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: v2,
              ),
            ),
        ],
      ),
    );
    return SizedBox(
      width: double.infinity,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          row('PROJECT TITLE', edit(p.title, (s) => p.title = s)),
          row(
            'LOCATION',
            edit(p.location, (s) => p.location = s),
            'DATE',
            edit(date, _setDate, align: TextAlign.right),
          ),
          row(
            'DIVISION',
            edit(p.division, (s) => p.division = s),
            'CD',
            edit(p.contractDuration, (s) {
              p.contractDuration = s;
              est.syncSchedule();
            }, align: TextAlign.right),
          ),
          row(
            'SOURCE OF FUND',
            edit(p.sourceOfFund, (s) => p.sourceOfFund = s),
            'ABC',
            Text(
              moneyFmt.format(est.grandTotal),
              textAlign: TextAlign.right,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
          ),
          row(
            'PHYSICAL TARGET',
            edit(p.physicalTarget, (s) => p.physicalTarget = s),
          ),
        ],
      ),
    );
  }

  /// Accepts common date spellings; keeps the old date when unparseable.
  static void _setDate(String s) {
    for (final f in const [
      'MMMM d, yyyy',
      'MMMM d yyyy',
      'M/d/yyyy',
      'M-d-yyyy',
      'yyyy-MM-dd',
    ]) {
      try {
        est.project.date = DateFormat(f).parse(s.trim());
        return;
      } catch (_) {}
    }
  }
}

// ------------------------------- table --------------------------------------

class _TableHeader extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final th = Theme.of(context);
    Widget cell(
      String t,
      double w, [
      TextAlign a = TextAlign.center,
      int flex = 0,
    ]) => flex == 1
        ? Expanded(
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Text(t, textAlign: TextAlign.left, style: _hs(th)),
            ),
          )
        : SizedBox(
            width: w,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Text(t, textAlign: a, style: _hs(th)),
            ),
          );

    return Container(
      decoration: BoxDecoration(
        color: Color(est.project.themeColor),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
      ),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            cell('ITEM\nNO.', SheetView._colNo),
            cell('Qty', SheetView._colQty),
            cell('Unit', SheetView._colUnit),
            cell('ITEM DESCRIPTION', 0, TextAlign.left, 1),
            cell('UNIT COST\nMaterial', SheetView._colCost),
            cell('UNIT COST\nLabor', SheetView._colCost),
            cell('TOTAL\nMaterial', SheetView._colCost),
            cell('TOTAL\nLabor', SheetView._colCost),
            cell('Total Amount', SheetView._colAmt, TextAlign.right),
            cell('', SheetView._colAct),
          ],
        ),
      ),
    );
  }

  static TextStyle _hs(ThemeData th) => TextStyle(
    color: bandFg(est.project.themeColor),
    fontSize: 10.5,
    fontWeight: FontWeight.w700,
    letterSpacing: 0.4,
    height: 1.3,
  );
}

class _SectionHeaderRow extends StatelessWidget {
  final BoqSection section;
  final String letter;
  const _SectionHeaderRow({required this.section, required this.letter});

  @override
  Widget build(BuildContext context) {
    return DragTarget<BoqSection>(
      onWillAcceptWithDetails: (d) => !identical(d.data, section),
      onAcceptWithDetails: (d) => est.moveSection(d.data, section),
      builder: (ctx, secCands, _) => DragTarget<BoqLine>(
        onAcceptWithDetails: (d) => est.moveLine(d.data, section),
        builder: (ctx, lineCands, _) => GestureDetector(
          behavior: HitTestBehavior.opaque,
          onSecondaryTapUp: (d) =>
              _showSectionMenu(context, section, d.globalPosition),
          child: Container(
            decoration: BoxDecoration(
              color: (secCands.isNotEmpty || lineCands.isNotEmpty)
                  ? const Color(0xFFBBD0F5)
                  : Color(est.project.sectionColor),
              border: const Border(
                bottom: BorderSide(color: Color(0xFFB6C4D8)),
              ),
            ),
            child: Row(
              children: [
                SizedBox(
                  width: SheetView._colNo,
                  child: Center(
                    child: Draggable<BoqSection>(
                      data: section,
                      feedback: _DragChip('$letter — ${section.title}'),
                      childWhenDragging: const Icon(
                        Icons.drag_indicator,
                        size: 14,
                        color: Color(0xFF94A3B8),
                      ),
                      child: GestureDetector(
                        onTap: () {
                          // Click-to-reference: insert the section letter
                          // (its subtotal) into the active formula field.
                          if (est.formulaRefSink != null) {
                            est.formulaRefSink!(letter);
                          }
                        },
                        child: Tooltip(
                          message:
                              'Drag to reorder · click inserts “$letter” '
                              'into a formula',
                          child: Text(
                            letter,
                            style: TextStyle(
                              fontWeight: FontWeight.w800,
                              fontSize: 12,
                              color: bandFg(est.project.sectionColor),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 2,
                      vertical: 4,
                    ),
                    child: InlineEdit(
                      value: section.title,
                      pickRef: letter,
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 12,
                        letterSpacing: 0.5,
                        color: bandFg(est.project.sectionColor),
                      ),
                      onCommit: (s) => est.renameSection(section, s),
                    ),
                  ),
                ),
                _SectionMenu(section: section),
                const SizedBox(width: 6),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SectionMenu extends StatelessWidget {
  final BoqSection section;
  const _SectionMenu({required this.section});

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      icon: const Icon(Icons.more_horiz, size: 16, color: Color(0xFF64748B)),
      tooltip: 'Section actions (right-click also works)',
      itemBuilder: (_) => _sectionMenuItems(),
      onSelected: (v) => _sectionAction(context, section, v),
    );
  }
}

class _GroupHeaderRow extends StatelessWidget {
  final BoqSection section;
  final BoqLine line;
  const _GroupHeaderRow({required this.section, required this.line});

  @override
  Widget build(BuildContext context) {
    return DragTarget<BoqLine>(
      onWillAcceptWithDetails: (d) => !identical(d.data, line),
      onAcceptWithDetails: (d) => est.moveLine(d.data, section, before: line),
      builder: (ctx, cands, _) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onSecondaryTapUp: (d) =>
            _rowMenu(context, d.globalPosition, section, line),
        child: _HoverRow(
          color: cands.isNotEmpty
              ? const Color(0xFFBBD0F5)
              : Color(est.project.groupColor),
          child: Row(
            children: [
              SizedBox(
                width: SheetView._colNo,
                child: Center(child: _LineGrip(line: line)),
              ),
              Expanded(
                child: InlineEdit(
                  value: line.description,
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontStyle: FontStyle.italic,
                    fontSize: 11.5,
                    color: bandFg(est.project.groupColor),
                  ),
                  onCommit: (s) {
                    line.description = s.toUpperCase();
                    est.update();
                  },
                ),
              ),
              _DeleteBtn(onTap: () => est.removeLine(section, line)),
            ],
          ),
        ),
      ),
    );
  }
}

class _ItemRow extends StatelessWidget {
  final BoqSection section;
  final BoqLine line;
  const _ItemRow({required this.section, required this.line});

  @override
  Widget build(BuildContext context) {
    return DragTarget<BoqLine>(
      onWillAcceptWithDetails: (d) => !identical(d.data, line),
      onAcceptWithDetails: (d) => est.moveLine(d.data, section, before: line),
      builder: (ctx, cands, _) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onSecondaryTapUp: (d) =>
            _rowMenu(context, d.globalPosition, section, line),
        child: _HoverRow(
          color: cands.isNotEmpty ? const Color(0xFFE8F0FE) : Colors.white,
          child: Row(
            children: [
              SizedBox(
                width: SheetView._colNo,
                child: Center(child: _LineGrip(line: line)),
              ),
              SizedBox(
                width: SheetView._colQty,
                child: InlineEdit(
                  value: qtyFmt.format(line.qty),
                  align: TextAlign.center,
                  onCommit: (s) {
                    final v = _numInput(s);
                    if (v != null) {
                      line.qty = v;
                      est.update();
                    }
                  },
                ),
              ),
              SizedBox(
                width: SheetView._colUnit,
                child: InlineEdit(
                  value: line.unit,
                  align: TextAlign.center,
                  onCommit: (s) {
                    line.unit = s;
                    est.update();
                  },
                ),
              ),
              Expanded(
                child: InlineEdit(
                  value: line.description,
                  onCommit: (v) {
                    line.description = v;
                    // VLOOKUP keys on the description cell — freeze the price
                    // when the text no longer matches the DATA sheet name.
                    if (v != line.priceKey) line.priceKey = null;
                    est.update();
                  },
                ),
              ),
              SizedBox(
                width: SheetView._colCost,
                child: InlineEdit(
                  value: moneyFmt.format(line.materialCost),
                  align: TextAlign.right,
                  onCommit: (s) {
                    final v = _numInput(s);
                    if (v != null) {
                      line.materialCost = v;
                      // editing material re-derives labor at the global
                      // rate — it is no longer a manual labor value
                      line.laborCost = v * est.laborRate;
                      line.laborOverridden = false;
                      line.priceOverridden = true;
                      line.priceKey = null;
                      est.update();
                    }
                  },
                ),
              ),
              SizedBox(
                width: SheetView._colCost,
                child: InlineEdit(
                  value: moneyFmt.format(line.laborCost),
                  align: TextAlign.right,
                  onCommit: (s) {
                    final v = _numInput(s);
                    if (v != null) {
                      line.laborCost = v;
                      // manual labor (incl. erasing to 0) survives labor-
                      // rate changes and price-db propagation
                      line.laborOverridden = true;
                      line.priceOverridden = true;
                      est.update();
                    }
                  },
                ),
              ),
              _NumCell(w: SheetView._colCost, v: line.materialTotal),
              _NumCell(w: SheetView._colCost, v: line.laborTotal),
              _NumCell(w: SheetView._colAmt, v: line.amount, bold: true),
              _DeleteBtn(onTap: () => est.removeLine(section, line)),
            ],
          ),
        ),
      ),
    );
  }
}

class _SubtotalRow extends StatelessWidget {
  final BoqSection section;
  const _SubtotalRow({required this.section});

  @override
  Widget build(BuildContext context) {
    final fg = bandFg(est.project.subtotalColor);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onSecondaryTapUp: (d) =>
          _subtotalMenu(context, d.globalPosition, section),
      child: Container(
        decoration: BoxDecoration(
          color: Color(est.project.subtotalColor),
          border: const Border(bottom: BorderSide(color: Color(0xFFB6C4D8))),
        ),
        child: Row(
          children: [
            const Spacer(),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 7),
              child: Text(
                'SUB TOTAL:',
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 11,
                  color: fg,
                ),
              ),
            ),
            const SizedBox(width: 16),
            SizedBox(
              width: SheetView._colAmt,
              child: Text(
                moneyFmt.format(section.subtotal),
                textAlign: TextAlign.right,
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 11.5,
                  color: fg,
                ),
              ),
            ),
            const SizedBox(width: SheetView._colAct),
          ],
        ),
      ),
    );
  }
}

/// The SUMMARY block: a live formula table. Left-click edits the label or
/// the formula (Excel `=` syntax); right-click inserts/deletes rows or
/// opens the formula builder.
class SummaryBlock extends StatelessWidget {
  const SummaryBlock({super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 14),
        Row(
          children: [
            const Text(
              'SUMMARY',
              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13),
            ),
            const Spacer(),
            TextButton.icon(
              onPressed: () => est.addSummaryRow(),
              icon: const Icon(Icons.add, size: 14),
              label: const Text('Row', style: TextStyle(fontSize: 11)),
              style: TextButton.styleFrom(
                foregroundColor: const Color(0xFF64748B),
                visualDensity: VisualDensity.compact,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        for (var i = 0; i < est.summaryRows.length; i++)
          _SummaryLine(
            row: est.summaryRows[i],
            index: i,
            big: i == est.summaryRows.length - 1,
          ),
      ],
    );
  }
}

class _SummaryLine extends StatelessWidget {
  final SummaryRow row;
  final int index;
  final bool big;
  const _SummaryLine({
    required this.row,
    required this.index,
    this.big = false,
  });

  /// References offered in the `=` dropdown while editing this row's
  /// formula: SECTIONS, earlier summary lines, and section letters.
  List<({String label, String ref})> get _refs => [
    (label: 'SECTIONS — all work sections', ref: 'SECTIONS'),
    for (var i = 0; i < index; i++)
      (
        label:
            'Line ${est.summaryRows[i].no} — ${est.summaryRows[i].label.trim()}',
        ref: est.summaryRows[i].no,
      ),
    for (var i = 0; i < est.sections.length && i < 26; i++)
      (
        label:
            'Section ${String.fromCharCode(65 + i)} — ${est.sections[i].title}',
        ref: String.fromCharCode(65 + i),
      ),
  ];

  @override
  Widget build(BuildContext context) {
    final v = est.summaryValue(row);
    final band = big ? est.project.themeColor : est.project.summaryColor;
    final fg = bandFg(band);
    return DragTarget<SummaryRow>(
      onWillAcceptWithDetails: (d) => !identical(d.data, row),
      onAcceptWithDetails: (d) => est.moveSummaryRow(d.data, row),
      builder: (ctx, cands, _) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onSecondaryTapUp: (d) => _menu(context, d.globalPosition),
        child: Container(
          decoration: BoxDecoration(
            color: cands.isNotEmpty ? const Color(0xFFBBD0F5) : Color(band),
            border: const Border(bottom: BorderSide(color: Color(0xFFCBD5E1))),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(
            children: [
              SizedBox(
                width: 18,
                child: Draggable<SummaryRow>(
                  data: row,
                  feedback: _DragChip('${row.no} — ${row.label.trim()}'),
                  childWhenDragging: const Icon(
                    Icons.drag_indicator,
                    size: 13,
                    color: Color(0xFFE2E8F0),
                  ),
                  child: Icon(
                    Icons.drag_indicator,
                    size: 13,
                    color: big ? fg.withAlpha(140) : const Color(0xFFCBD5E1),
                  ),
                ),
              ),
              const SizedBox(width: 2),
              SizedBox(
                width: 40,
                child: InlineEdit(
                  value: row.no,
                  align: TextAlign.center,
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 11,
                    color: fg,
                  ),
                  onCommit: (s) {
                    row.no = s.toUpperCase();
                    est.update();
                  },
                ),
              ),
              Expanded(
                child: InlineEdit(
                  value: row.label,
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 11.5,
                    color: fg,
                  ),
                  onCommit: (s) {
                    row.label = s;
                    est.update();
                  },
                ),
              ),
              SizedBox(
                width: 110,
                child: Text(
                  '=${row.formula}',
                  textAlign: TextAlign.right,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 9,
                    color: big ? fg.withAlpha(160) : const Color(0xFF94A3B8),
                  ),
                ),
              ),
              SizedBox(
                width: 140,
                child: InlineEdit(
                  value: v.isNaN ? '#ERR' : moneyFmt.format(v),
                  editText: '=${row.formula}',
                  align: TextAlign.right,
                  isFormula: true,
                  pickRef: row.no,
                  formulaRefs: _refs,
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: big ? 13 : 11.5,
                    color: v.isNaN ? Colors.redAccent : fg,
                  ),
                  onCommit: (s) {
                    final t = s.trim();
                    // typing a plain number stores a constant formula
                    row.formula = t.startsWith('=') ? t.substring(1) : t;
                    est.update();
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _menu(BuildContext context, Offset pos) async {
    final v = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(pos.dx, pos.dy, pos.dx, pos.dy),
      items: const [
        PopupMenuItem(value: 'fx', child: Text('Edit formula…')),
        PopupMenuItem(value: 'insert', child: Text('Insert row below')),
        PopupMenuItem(
          value: 'delete',
          child: Text('Delete row', style: TextStyle(color: Colors.redAccent)),
        ),
      ],
    );
    if (!context.mounted) return;
    switch (v) {
      case 'fx':
        _formulaDialog(context);
      case 'insert':
        est.addSummaryRow(after: index);
      case 'delete':
        est.removeSummaryRow(row);
    }
  }

  /// Quick formula builder: presets + custom expression, like Excel's fx.
  void _formulaDialog(BuildContext context) {
    final idx = est.summaryRows.indexOf(row);
    final prior = est.summaryRows.sublist(0, idx < 0 ? 0 : idx);
    final custom = TextEditingController(text: row.formula);
    final pct = TextEditingController(text: '7');
    final amt = TextEditingController();
    String? sel = prior.isNotEmpty ? prior.last.no : null;
    String? selA = prior.isNotEmpty ? prior.first.no : null;
    String? selB = prior.length > 1 ? prior[1].no : selA;
    String op = '+';

    void apply(String f) {
      row.formula = f;
      est.update();
      Navigator.pop(context);
    }

    Widget optBtn(String label, String Function() f) => Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Expanded(child: Text(label, style: const TextStyle(fontSize: 12))),
          FilledButton.tonal(
            onPressed: () => apply(f()),
            child: const Text('Use', style: TextStyle(fontSize: 11)),
          ),
        ],
      ),
    );

    final ddStyle = const TextStyle(fontSize: 12);
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: const Text('Set formula', style: TextStyle(fontSize: 15)),
          content: SizedBox(
            width: 360,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                optBtn('Sum of all work sections', () => 'SECTIONS'),
                if (prior.isNotEmpty) ...[
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '${sel ?? ''}  ×  %',
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                      DropdownButton<String>(
                        value: sel,
                        items: [
                          for (final r in prior)
                            DropdownMenuItem(
                              value: r.no,
                              child: Text(r.no, style: ddStyle),
                            ),
                        ],
                        onChanged: (v) => setD(() => sel = v),
                      ),
                      const SizedBox(width: 8),
                      SizedBox(
                        width: 56,
                        child: TextField(
                          controller: pct,
                          style: ddStyle,
                          decoration: const InputDecoration(
                            isDense: true,
                            suffixText: '%',
                          ),
                        ),
                      ),
                      FilledButton.tonal(
                        onPressed: () => apply('$sel*${pct.text}%'),
                        child: const Text(
                          'Use',
                          style: TextStyle(fontSize: 11),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      DropdownButton<String>(
                        value: selA,
                        items: [
                          for (final r in prior)
                            DropdownMenuItem(
                              value: r.no,
                              child: Text(r.no, style: ddStyle),
                            ),
                        ],
                        onChanged: (v) => setD(() => selA = v),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        child: DropdownButton<String>(
                          value: op,
                          items: const [
                            DropdownMenuItem(value: '+', child: Text('＋')),
                            DropdownMenuItem(value: '-', child: Text('－')),
                            DropdownMenuItem(value: '*', child: Text('×')),
                            DropdownMenuItem(value: '/', child: Text('÷')),
                          ],
                          onChanged: (v) => setD(() => op = v ?? '+'),
                        ),
                      ),
                      DropdownButton<String>(
                        value: selB,
                        items: [
                          for (final r in prior)
                            DropdownMenuItem(
                              value: r.no,
                              child: Text(r.no, style: ddStyle),
                            ),
                        ],
                        onChanged: (v) => setD(() => selB = v),
                      ),
                      const Spacer(),
                      FilledButton.tonal(
                        onPressed: () => apply('$selA$op$selB'),
                        child: const Text(
                          'Use',
                          style: TextStyle(fontSize: 11),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                ],
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'Fixed amount',
                        style: TextStyle(fontSize: 12),
                      ),
                    ),
                    SizedBox(
                      width: 90,
                      child: TextField(
                        controller: amt,
                        style: ddStyle,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          isDense: true,
                          hintText: '0.00',
                        ),
                      ),
                    ),
                    FilledButton.tonal(
                      onPressed: () => apply(amt.text.isEmpty ? '0' : amt.text),
                      child: const Text('Use', style: TextStyle(fontSize: 11)),
                    ),
                  ],
                ),
                const Divider(height: 20),
                TextField(
                  controller: custom,
                  style: ddStyle,
                  decoration: const InputDecoration(
                    labelText: 'Custom formula',
                    hintText: 'e.g. I*7% or I+II or SECTIONS',
                    prefixText: '=',
                    isDense: true,
                  ),
                  onSubmitted: (_) => apply(custom.text),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => apply(custom.text),
              child: const Text('Apply'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Signature area: two signatories per row (even index left, odd right).
/// Every field is editable in place (click → type); hover shows a delete
/// button and right-click also offers delete. "Add signatory" appends a
/// blank entry you type into directly.
class SignatureBlock extends StatelessWidget {
  const SignatureBlock({super.key});

  @override
  Widget build(BuildContext context) {
    final sigs = est.project.effSignatories;
    if (sigs.isEmpty) return const SizedBox.shrink();
    final rows = <Widget>[];
    for (var i = 0; i < sigs.length; i += 2) {
      rows.add(
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _SignatoryCell(sig: sigs[i]),
            i + 1 < sigs.length
                ? _SignatoryCell(sig: sigs[i + 1])
                : const Spacer(),
          ],
        ),
      );
      rows.add(const SizedBox(height: 16));
    }
    return SizedBox(
      width: double.infinity,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ...rows,
          TextButton.icon(
            onPressed: () => est.addSignatory(
              Signatory(label: 'Noted by', name: '', position: ''),
            ),
            icon: const Icon(Icons.add, size: 15),
            label: const Text(
              'Add signatory',
              style: TextStyle(fontSize: 11.5),
            ),
            style: TextButton.styleFrom(
              foregroundColor: const Color(0xFF64748B),
              visualDensity: VisualDensity.compact,
            ),
          ),
        ],
      ),
    );
  }
}

class _SignatoryCell extends StatefulWidget {
  final Signatory sig;
  const _SignatoryCell({required this.sig});

  @override
  State<_SignatoryCell> createState() => _SignatoryCellState();
}

class _SignatoryCellState extends State<_SignatoryCell> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final sig = widget.sig;
    return Expanded(
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onSecondaryTapUp: (d) => _menu(context, d.globalPosition),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Flexible(
                    child: InlineEdit(
                      value: sig.label,
                      hint: 'e.g. Prepared by',
                      style: const TextStyle(fontSize: 11),
                      onCommit: (s) {
                        sig.label = s.replaceAll(':', '').trim();
                        est.update();
                      },
                    ),
                  ),
                  const Text(':', style: TextStyle(fontSize: 11)),
                  if (_hover)
                    InkWell(
                      onTap: () => est.removeSignatory(sig),
                      child: const Padding(
                        padding: EdgeInsets.all(2),
                        child: Icon(
                          Icons.close,
                          size: 13,
                          color: Color(0xFF94A3B8),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 14),
              InlineEdit(
                value: sig.name,
                hint: 'NAME',
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 11.5,
                  decoration: TextDecoration.underline,
                ),
                onCommit: (s) {
                  sig.name = s;
                  est.update();
                },
              ),
              InlineEdit(
                value: sig.position,
                hint: 'Position',
                style: const TextStyle(fontSize: 10.5),
                onCommit: (s) {
                  sig.position = s;
                  est.update();
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _menu(BuildContext context, Offset pos) async {
    final v = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(pos.dx, pos.dy, pos.dx, pos.dy),
      items: const [
        PopupMenuItem(
          value: 'delete',
          child: Text(
            'Delete signatory',
            style: TextStyle(color: Colors.redAccent),
          ),
        ),
      ],
    );
    if (v == 'delete') est.removeSignatory(widget.sig);
  }
}

// ------------------------------- atoms --------------------------------------

class _HoverRow extends StatefulWidget {
  final Widget child;
  final Color color;
  const _HoverRow({required this.child, this.color = Colors.white});

  @override
  State<_HoverRow> createState() => _HoverRowState();
}

class _HoverRowState extends State<_HoverRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 0, vertical: 0),
        decoration: BoxDecoration(
          color: _hover
              ? Color.alphaBlend(const Color(0x0A1E4976), widget.color)
              : widget.color,
          border: const Border(bottom: BorderSide(color: Color(0xFFEEF2F7))),
        ),
        child: DefaultTextStyle(
          style: const TextStyle(fontSize: 11.5, color: Color(0xFF1E293B)),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 0),
            child: widget.child,
          ),
        ),
      ),
    );
  }
}

/// Excel-style inline edit: shows plain text; a tap swaps in a focused,
/// border-only text field (no dialog, no grid lines). Commits on Enter or
/// when the field loses focus; unchanged text does nothing.
class InlineEdit extends StatefulWidget {
  final String value;

  /// Text shown in the field while editing (defaults to [value]) — lets
  /// the display show a computed value while the field edits a formula.
  final String? editText;
  final TextStyle? style;
  final TextAlign align;
  final String? hint;
  final void Function(String text) onCommit;

  /// When true the field edits a formula: blur commits after a short
  /// delay so a tap on a [pickRef] cell can insert its ref + refocus
  /// (Excel's click-to-reference), and a `=` dropdown menu is shown.
  final bool isFormula;

  /// When a formula field is being edited elsewhere, tapping this cell
  /// inserts [pickRef] into that formula instead of starting an edit.
  final String? pickRef;

  /// `(label, ref)` entries for the `=` dropdown shown while editing.
  final List<({String label, String ref})>? formulaRefs;

  const InlineEdit({
    super.key,
    required this.value,
    required this.onCommit,
    this.editText,
    this.style,
    this.align = TextAlign.left,
    this.hint,
    this.isFormula = false,
    this.pickRef,
    this.formulaRefs,
  });

  @override
  State<InlineEdit> createState() => _InlineEditState();
}

class _InlineEditState extends State<InlineEdit> {
  bool _editing = false;
  bool _menuOpen = false;
  late TextEditingController _c;
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus && _editing) {
        if (widget.isFormula) {
          _commitLater();
        } else {
          _commit();
        }
      }
    });
  }

  @override
  void dispose() {
    _focus.dispose();
    if (_editing) _c.dispose();
    super.dispose();
  }

  void _start() {
    _c = TextEditingController(text: widget.editText ?? widget.value);
    setState(() => _editing = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focus.requestFocus();
      _c.selection = TextSelection(baseOffset: 0, extentOffset: _c.text.length);
    });
    if (widget.isFormula) {
      est.formulaRefSink = (ref) {
        if (!mounted) return;
        _insertRef(ref);
        _focus.requestFocus();
      };
    }
  }

  /// Delayed commit for formula fields — gives a click-to-reference tap
  /// or the `=` dropdown a chance to refocus us before we close.
  void _commitLater() {
    Future.delayed(const Duration(milliseconds: 150), () {
      if (mounted && _editing && !_focus.hasFocus && !_menuOpen) {
        _commit();
      }
    });
  }

  void _insertRef(String ref) {
    final sel = _c.selection;
    if (sel.isValid) {
      _c.text = _c.text.replaceRange(sel.start, sel.end, ref);
      _c.selection = TextSelection.collapsed(offset: sel.start + ref.length);
    } else {
      _c.text += ref;
      _c.selection = TextSelection.collapsed(offset: _c.text.length);
    }
  }

  void _commit() {
    if (!_editing) return;
    final t = _c.text;
    setState(() => _editing = false);
    _c.dispose();
    if (widget.isFormula) est.formulaRefSink = null;
    if (t != (widget.editText ?? widget.value)) widget.onCommit(t);
  }

  @override
  Widget build(BuildContext context) {
    if (_editing) {
      return SizedBox(
        height: 26,
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _c,
                focusNode: _focus,
                style: widget.style ?? const TextStyle(fontSize: 11.5),
                textAlign: widget.align,
                decoration: InputDecoration(
                  isDense: true,
                  isCollapsed: true,
                  hintText: widget.hint,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 5,
                  ),
                  filled: true,
                  fillColor: const Color(0xFFF8FAFC),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(4),
                    borderSide: const BorderSide(color: Color(0xFF93C5FD)),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(4),
                    borderSide: BorderSide(
                      color: Color(est.project.themeColor),
                      width: 1.4,
                    ),
                  ),
                ),
                onSubmitted: (_) => _commit(),
              ),
            ),
            if (widget.formulaRefs != null && widget.formulaRefs!.isNotEmpty)
              PopupMenuButton<String>(
                icon: const Icon(
                  Icons.arrow_drop_down,
                  size: 16,
                  color: Color(0xFF64748B),
                ),
                tooltip: 'Insert reference',
                padding: EdgeInsets.zero,
                onOpened: () => _menuOpen = true,
                onCanceled: () {
                  _menuOpen = false;
                  _commitLater();
                },
                onSelected: (ref) {
                  _menuOpen = false;
                  _insertRef(ref);
                  _focus.requestFocus();
                },
                itemBuilder: (_) => [
                  for (final r in widget.formulaRefs!)
                    PopupMenuItem(
                      height: 30,
                      value: r.ref,
                      child: Text(
                        r.label,
                        style: const TextStyle(fontSize: 11.5),
                      ),
                    ),
                ],
              ),
          ],
        ),
      );
    }
    return InkWell(
      onTap: () {
        // While a formula is being edited elsewhere, tapping this cell
        // inserts our reference into it — like Excel click-to-reference.
        if (est.formulaRefSink != null && widget.pickRef != null) {
          est.formulaRefSink!(widget.pickRef!);
          return;
        }
        _start();
      },
      child: MouseRegion(
        cursor: SystemMouseCursors.text,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: Text(
            widget.value.isEmpty ? (widget.hint ?? '—') : widget.value,
            textAlign: widget.align,
            overflow: TextOverflow.ellipsis,
            style: widget.value.isEmpty
                ? (widget.style ?? const TextStyle()).copyWith(
                    color: const Color(0xFF94A3B8),
                  )
                : widget.style,
          ),
        ),
      ),
    );
  }
}

/// Foreground that stays readable on a band of color [argb] —
/// dark text on light bands, white on dark ones.
Color bandFg(int argb) => Color(argb).computeLuminance() > 0.45
    ? const Color(0xFF1E293B)
    : Colors.white;

/// Parses a numeric cell entry: plain number, or `=expression`
/// (e.g. =20*5.5) evaluated arithmetically — like Excel.
double? _numInput(String s) {
  final t = s.replaceAll(',', '').trim();
  if (t.isEmpty) return 0; // erasing a numeric cell zeroes it
  if (t.startsWith('=')) return evalFormula(t, const {});
  return double.tryParse(t);
}

/// Drag handle shown in the first column of item/group rows.
class _LineGrip extends StatelessWidget {
  final BoqLine line;
  const _LineGrip({required this.line});

  @override
  Widget build(BuildContext context) {
    return Draggable<BoqLine>(
      data: line,
      feedback: _DragChip(line.description),
      childWhenDragging: const Icon(
        Icons.drag_indicator,
        size: 14,
        color: Color(0xFFE2E8F0),
      ),
      child: const Tooltip(
        message: 'Drag to move this row',
        child: Icon(Icons.drag_indicator, size: 14, color: Color(0xFFCBD5E1)),
      ),
    );
  }
}

/// Floating label shown under the cursor while dragging a row.
class _DragChip extends StatelessWidget {
  final String text;
  const _DragChip(this.text);

  @override
  Widget build(BuildContext context) {
    return Material(
      elevation: 4,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: Color(est.project.themeColor),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          text,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: bandFg(est.project.themeColor),
            fontSize: 11,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

class _NumCell extends StatelessWidget {
  final double w;
  final double v;
  final bool bold;
  const _NumCell({required this.w, required this.v, this.bold = false});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: w,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Text(
          moneyFmt.format(v),
          textAlign: TextAlign.right,
          style: TextStyle(
            fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
            fontFeatures: const [],
          ),
        ),
      ),
    );
  }
}

class _DeleteBtn extends StatelessWidget {
  final VoidCallback onTap;
  const _DeleteBtn({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: SheetView._colAct,
      child: IconButton(
        icon: const Icon(Icons.close, size: 14, color: Color(0xFF94A3B8)),
        onPressed: onTap,
        tooltip: 'Remove',
        splashRadius: 14,
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.post_add, size: 56, color: Colors.grey.shade300),
          const SizedBox(height: 14),
          const Text(
            'Your BOQ sheet is empty',
            style: TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 16,
              color: Color(0xFF475569),
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'Pick a work type on the right panel, enter the area / volume,\nand the computed materials will be written here.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12.5, color: Color(0xFF94A3B8)),
          ),
        ],
      ),
    );
  }
}
