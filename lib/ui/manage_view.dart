import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../models.dart';
import '../state.dart';
import 'sheet_view.dart' show bandFg;

/// PROJECT MANAGEMENT tab. Layout (top -> bottom):
///  * KPI strip: Total / Pending / On-going / Completed tiles (tap a
///    tile to filter the table) + overall progress bar.
///  * Work items table (left) — one status dropdown per row, remarks,
///    a ⋮ menu for row actions; toolbar has search + one Add button.
///  * Site inspections (right) — date column, inspector, findings,
///    ⋮ menu; one Add button.
class ManageView extends StatefulWidget {
  const ManageView({super.key});

  @override
  State<ManageView> createState() => _ManageViewState();
}

class _ManageViewState extends State<ManageView> {
  String? _filter; // null = all
  String _query = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) est.syncTrackItems();
    });
  }

  static const _stColors = {
    'pending': Color(0xFF64748B),
    'ongoing': Color(0xFFD97706),
    'completed': Color(0xFF059669),
  };
  static const _stLabels = {
    'pending': 'Pending',
    'ongoing': 'On-going',
    'completed': 'Completed',
  };
  static const _ink = Color(0xFF334155);
  static const _muted = Color(0xFF94A3B8);
  static const _line = Color(0xFFE2E8F0);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      child: ListenableBuilder(
        listenable: est,
        builder: (context, _) => Column(
          children: [
            _kpiStrip(),
            const SizedBox(height: 12),
            Expanded(
              child: LayoutBuilder(
                builder: (context, c) {
                  if (c.maxWidth >= 900) {
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(flex: 3, child: _board()),
                        const SizedBox(width: 12),
                        Expanded(flex: 2, child: _inspections()),
                      ],
                    );
                  }
                  return SingleChildScrollView(
                    child: Column(
                      children: [
                        SizedBox(height: 440, child: _board()),
                        const SizedBox(height: 12),
                        SizedBox(height: 420, child: _inspections()),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------- KPI strip ----------------

  Widget _kpiStrip() {
    final items = est.trackItems;
    int count(String s) => items.where((t) => t.status == s).length;
    final frac = est.overallProgress; // cost-weighted accomplishment
    final theme = Color(est.project.themeColor);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: theme,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(
                Icons.assignment_turned_in_outlined,
                size: 21,
                color: bandFg(est.project.themeColor),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              flex: 3,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Project Management',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800),
                  ),
                  Text(
                    est.project.title.isEmpty
                        ? 'Work progress & site inspections'
                        : est.project.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11, color: _muted),
                  ),
                ],
              ),
            ),
            _kpiTile('All', items.length, _ink, null),
            for (final s in TrackItem.statuses)
              _kpiTile(_stLabels[s]!, count(s), _stColors[s]!, s),
            const SizedBox(width: 14),
            SizedBox(
              width: 170,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'Progress',
                        style: TextStyle(fontSize: 11, color: _muted),
                      ),
                      Text(
                        '${(frac * 100).toStringAsFixed(1)}%',
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 5),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: frac,
                      minHeight: 7,
                      backgroundColor: _line,
                      valueColor: const AlwaysStoppedAnimation(
                        Color(0xFF059669),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _kpiTile(String label, int n, Color color, String? filter) {
    final sel = _filter == filter;
    return Padding(
      padding: const EdgeInsets.only(left: 6),
      child: Tooltip(
        message: filter == null
            ? 'Show all work items'
            : 'Show ${label.toLowerCase()} only',
        child: InkWell(
          key: ValueKey('kpi-${filter ?? 'all'}'),
          borderRadius: BorderRadius.circular(9),
          onTap: () => setState(() => _filter = filter),
          child: Container(
            width: 84,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: sel ? color.withValues(alpha: 0.12) : Colors.transparent,
              borderRadius: BorderRadius.circular(9),
              border: Border.all(
                color: sel ? color.withValues(alpha: 0.5) : _line,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '$n',
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                    color: color,
                  ),
                ),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 10.5, color: _muted),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ---------------- work items ----------------

  List<TrackItem> get _visible => [
    for (final t in est.trackItems)
      if ((_filter == null || t.status == _filter) &&
          (_query.isEmpty ||
              t.name.toLowerCase().contains(_query.toLowerCase()) ||
              t.remarks.toLowerCase().contains(_query.toLowerCase())))
        t,
  ];

  Widget _cardHeader(IconData icon, String title, List<Widget> actions) =>
      Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
        child: Row(
          children: [
            Icon(icon, size: 17, color: const Color(0xFF64748B)),
            const SizedBox(width: 8),
            Text(
              title,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.5,
                color: _ink,
              ),
            ),
            const Spacer(),
            ...actions,
          ],
        ),
      );

  Widget _board() {
    final rows = _visible;
    return Card(
      margin: EdgeInsets.zero,
      child: Column(
        children: [
          _cardHeader(Icons.playlist_add_check, 'WORK ITEMS', [
            SizedBox(
              width: 190,
              height: 32,
              child: TextField(
                onChanged: (v) => setState(() => _query = v),
                style: const TextStyle(fontSize: 12),
                decoration: InputDecoration(
                  hintText: 'Search',
                  hintStyle: const TextStyle(fontSize: 12, color: _muted),
                  prefixIcon: const Icon(Icons.search, size: 16),
                  isDense: true,
                  contentPadding: EdgeInsets.zero,
                  filled: true,
                  fillColor: const Color(0xFFF8FAFC),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(color: _line),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(color: _line),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton.icon(
              onPressed: _addItem,
              icon: const Icon(Icons.add, size: 16),
              label: const Text('Add item', style: TextStyle(fontSize: 12)),
              style: FilledButton.styleFrom(
                visualDensity: VisualDensity.compact,
                backgroundColor: Color(est.project.themeColor),
                foregroundColor: bandFg(est.project.themeColor),
              ),
            ),
          ]),
          const Divider(height: 1, color: _line),
          Container(
            color: const Color(0xFFF8FAFC),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
            child: const Row(
              children: [
                SizedBox(width: 40, child: _Th('NO.')),
                Expanded(flex: 3, child: _Th('WORK ITEM')),
                SizedBox(width: 130, child: _Th('STATUS')),
                SizedBox(width: 10),
                SizedBox(width: 104, child: _Th('%')),
                SizedBox(width: 10),
                Expanded(flex: 2, child: _Th('REMARKS')),
                SizedBox(width: 32),
              ],
            ),
          ),
          const Divider(height: 1, color: _line),
          Expanded(
            child: rows.isEmpty
                ? Center(
                    child: Text(
                      est.trackItems.isEmpty
                          ? 'No work items yet — add BOQ sections or '
                                'press "Add item".'
                          : 'No work items match this filter.',
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 12, color: _muted),
                    ),
                  )
                : ListView.builder(
                    itemCount: rows.length,
                    itemBuilder: (_, i) => _itemRow(rows[i]),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _itemRow(TrackItem t) {
    final sec = t.sectionId == null
        ? null
        : est.sections.where((s) => s.id == t.sectionId).firstOrNull;
    return Container(
      key: ValueKey(t.id),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Color(0xFFF1F5F9))),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      child: Row(
        children: [
          SizedBox(
            width: 40,
            child: Align(
              alignment: Alignment.centerLeft,
              child: sec != null
                  ? Container(
                      width: 24,
                      height: 24,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: Color(est.project.sectionColor),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        est.letterOf(sec),
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                          color: bandFg(est.project.sectionColor),
                        ),
                      ),
                    )
                  : const Icon(Icons.edit_note, size: 18, color: _muted),
            ),
          ),
          Expanded(
            flex: 3,
            child: sec != null
                ? Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Text(
                      t.name.isEmpty ? '(untitled)' : t.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  )
                : _inlineField(
                    t.name,
                    hint: 'Work item name',
                    onChanged: (v) => t.name = v,
                  ),
          ),
          SizedBox(width: 130, child: _statusMenu(t)),
          const SizedBox(width: 10),
          SizedBox(width: 104, child: _pctCell(t)),
          const SizedBox(width: 10),
          Expanded(
            flex: 2,
            child: _inlineField(
              t.remarks,
              hint: 'Add remarks',
              onChanged: (v) => t.remarks = v,
            ),
          ),
          SizedBox(
            width: 32,
            child: sec == null
                ? PopupMenuButton<String>(
                    tooltip: 'Row actions',
                    icon: const Icon(Icons.more_vert, size: 18, color: _muted),
                    padding: EdgeInsets.zero,
                    onSelected: (_) => est.removeTrackItem(t),
                    itemBuilder: (_) => const [
                      PopupMenuItem(
                        value: 'del',
                        child: Text(
                          'Remove item',
                          style: TextStyle(fontSize: 12),
                        ),
                      ),
                    ],
                  )
                : null,
          ),
        ],
      ),
    );
  }

  /// Editable accomplishment % + a mini progress bar. Typing a % keeps
  /// the status consistent (0 = pending, 100 = completed, else on-going).
  Widget _pctCell(TrackItem t) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 66,
          child: TextFormField(
            key: ValueKey('pct-${t.id}'),
            initialValue: t.progress == t.progress.roundToDouble()
                ? '${t.progress.toInt()}'
                : t.progress.toStringAsFixed(1),
            textAlign: TextAlign.right,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[\d.]')),
            ],
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
            decoration: const InputDecoration(
              hintText: '0',
              hintStyle: TextStyle(fontSize: 11.5, color: Color(0xFFCBD5E1)),
              isDense: true,
              contentPadding: EdgeInsets.symmetric(horizontal: 4, vertical: 6),
              border: InputBorder.none,
              suffixText: '%',
              suffixStyle: TextStyle(fontSize: 10, color: _muted),
            ),
            onChanged: (v) {
              final p = double.tryParse(v);
              if (p != null) est.setTrackProgress(t, p);
            },
          ),
        ),
        const SizedBox(height: 3),
        ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: LinearProgressIndicator(
            value: (t.progress / 100).clamp(0.0, 1.0),
            minHeight: 4,
            backgroundColor: _line,
            valueColor: AlwaysStoppedAnimation(_stColors[t.status]!),
          ),
        ),
      ],
    );
  }

  /// One compact pill per row — click opens the 3-option menu.
  Widget _statusMenu(TrackItem t) {
    final c = _stColors[t.status]!;
    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerLeft,
      child: PopupMenuButton<String>(
        key: ValueKey('status-${t.id}'),
        tooltip: 'Change status',
        padding: EdgeInsets.zero,
        onSelected: (s) => est.setTrackStatus(t, s),
        itemBuilder: (_) => [
          for (final s in TrackItem.statuses)
            PopupMenuItem(
              value: s,
              height: 36,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.circle, size: 9, color: _stColors[s]),
                  const SizedBox(width: 9),
                  Text(_stLabels[s]!, style: const TextStyle(fontSize: 12)),
                  if (s == t.status) ...[
                    const SizedBox(width: 14),
                    const Icon(Icons.check, size: 14),
                  ],
                ],
              ),
            ),
        ],
        child: Container(
          padding: const EdgeInsets.fromLTRB(9, 4, 5, 4),
          decoration: BoxDecoration(
            color: c.withValues(alpha: 0.11),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.circle, size: 8, color: c),
              const SizedBox(width: 6),
              Text(
                _stLabels[t.status]!,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: c,
                ),
              ),
              Icon(Icons.arrow_drop_down, size: 16, color: c),
            ],
          ),
        ),
      ),
    );
  }

  // ---------------- inspections ----------------

  Widget _inspections() {
    return Card(
      margin: EdgeInsets.zero,
      child: Column(
        children: [
          _cardHeader(Icons.fact_check_outlined, 'SITE INSPECTIONS', [
            FilledButton.icon(
              onPressed: () => est.addInspection(),
              icon: const Icon(Icons.add, size: 16),
              label: const Text(
                'Add inspection',
                style: TextStyle(fontSize: 12),
              ),
              style: FilledButton.styleFrom(
                visualDensity: VisualDensity.compact,
                backgroundColor: Color(est.project.themeColor),
                foregroundColor: bandFg(est.project.themeColor),
              ),
            ),
          ]),
          const Divider(height: 1, color: _line),
          Expanded(
            child: est.inspections.isEmpty
                ? const Center(
                    child: Text(
                      'No inspections yet — press "Add inspection"\n'
                      'to log a site visit and its findings.',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 12, color: _muted),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    itemCount: est.inspections.length,
                    itemBuilder: (_, i) => _inspectionRow(est.inspections[i]),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _inspectionRow(Inspection ins) {
    final date = _parseDate(ins.date);
    final theme = Color(est.project.themeColor);
    return Container(
      key: ValueKey(ins.id),
      padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Color(0xFFF1F5F9))),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // date block — click to repick
          InkWell(
            key: ValueKey('date-${ins.id}'),
            borderRadius: BorderRadius.circular(8),
            onTap: () => _pickDate(ins),
            child: Tooltip(
              message: 'Change date',
              child: Container(
                width: 52,
                padding: const EdgeInsets.symmetric(vertical: 6),
                decoration: BoxDecoration(
                  color: theme.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: date == null
                    ? Icon(Icons.event, size: 20, color: theme)
                    : Column(
                        children: [
                          Text(
                            DateFormat('MMM').format(date).toUpperCase(),
                            style: TextStyle(
                              fontSize: 9.5,
                              fontWeight: FontWeight.w800,
                              color: theme,
                            ),
                          ),
                          Text(
                            '${date.day}',
                            style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          Text(
                            '${date.year}',
                            style: const TextStyle(fontSize: 9, color: _muted),
                          ),
                        ],
                      ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _inlineField(
                  ins.inspector,
                  hint: 'Inspector',
                  bold: true,
                  onChanged: (v) => ins.inspector = v,
                ),
                _inlineField(
                  ins.findings,
                  hint: 'Findings / observations',
                  maxLines: 4,
                  onChanged: (v) => ins.findings = v,
                ),
              ],
            ),
          ),
          PopupMenuButton<String>(
            tooltip: 'Inspection actions',
            icon: const Icon(Icons.more_vert, size: 18, color: _muted),
            padding: EdgeInsets.zero,
            onSelected: (v) =>
                v == 'date' ? _pickDate(ins) : est.removeInspection(ins),
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: 'date',
                child: Text('Change date', style: TextStyle(fontSize: 12)),
              ),
              PopupMenuItem(
                value: 'del',
                child: Text(
                  'Delete inspection',
                  style: TextStyle(fontSize: 12),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ---------------- helpers ----------------

  /// Keyless on purpose: the element must survive rebuilds so the
  /// internal controller keeps focus while typing.
  Widget _inlineField(
    String value, {
    required String hint,
    int maxLines = 1,
    bool bold = false,
    required ValueChanged<String> onChanged,
  }) {
    return TextFormField(
      initialValue: value,
      maxLines: maxLines,
      minLines: 1,
      style: TextStyle(
        fontSize: 12,
        fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
      ),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(fontSize: 11.5, color: Color(0xFFCBD5E1)),
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
        border: InputBorder.none,
      ),
      onChanged: (v) {
        onChanged(v);
        est.update();
      },
    );
  }

  DateTime? _parseDate(String iso) {
    if (iso.isEmpty) return null;
    try {
      return DateTime.parse(iso);
    } catch (_) {
      return null;
    }
  }

  Future<void> _pickDate(Inspection ins) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _parseDate(ins.date) ?? DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked == null) return;
    ins.date = DateFormat('yyyy-MM-dd').format(picked);
    est.update();
  }

  /// Add work items — BOQ sections not yet tracked can be ticked, and
  /// extra items can be typed or pasted several at once (one per line).
  Future<void> _addItem() async {
    final ctrl = TextEditingController();
    final untracked = [
      for (final s in est.sections)
        if (!est.trackItems.any((t) => t.sectionId == s.id)) s,
    ];
    final picked = {...untracked};
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setD) => AlertDialog(
          title: const Text('Add work items', style: TextStyle(fontSize: 15)),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (untracked.isNotEmpty) ...[
                  const Text(
                    'BOQ SECTIONS',
                    style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.5,
                      color: _muted,
                    ),
                  ),
                  const SizedBox(height: 4),
                  for (final s in untracked)
                    CheckboxListTile(
                      value: picked.contains(s),
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        '${est.letterOf(s)} — ${s.title}',
                        style: const TextStyle(fontSize: 12.5),
                      ),
                      onChanged: (v) => setD(
                        () => v == true ? picked.add(s) : picked.remove(s),
                      ),
                    ),
                  const SizedBox(height: 8),
                ],
                const Text(
                  'OTHER ITEMS — ONE PER LINE',
                  style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.5,
                    color: _muted,
                  ),
                ),
                const SizedBox(height: 4),
                TextField(
                  controller: ctrl,
                  autofocus: untracked.isEmpty,
                  maxLines: 4,
                  minLines: 1,
                  decoration: const InputDecoration(
                    hintText:
                        'TEMPORARY FACILITIES\nSAFETY & HEALTH\nMOBILIZATION',
                    hintStyle: TextStyle(fontSize: 12, color: _muted),
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Add'),
            ),
          ],
        ),
      ),
    );
    if (ok != true) return;
    var added = false;
    for (final s in picked) {
      if (!est.trackItems.any((t) => t.sectionId == s.id)) {
        est.trackItems.add(TrackItem(sectionId: s.id, name: s.title));
        added = true;
      }
    }
    final names = ctrl.text
        .split('\n')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty);
    if (est.addTrackItems(names.map((e) => e.toUpperCase())).isNotEmpty) {
      added = true;
    }
    if (added) est.update();
  }
}

class _Th extends StatelessWidget {
  final String text;
  const _Th(this.text);
  @override
  Widget build(BuildContext context) => Text(
    text,
    style: const TextStyle(
      fontSize: 10,
      fontWeight: FontWeight.w800,
      letterSpacing: 0.5,
      color: Color(0xFF94A3B8),
    ),
  );
}
