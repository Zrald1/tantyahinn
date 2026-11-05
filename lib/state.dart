import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:uuid/uuid.dart';

import 'cpm.dart';
import 'design_calc.dart';
import 'formula.dart';
import 'model3d.dart';
import 'models.dart';
import 'price_db.dart';
import 'schedule.dart';
part 'project_tabs.dart';

/// Shared app-wide estimate state — resolves to the ACTIVE project
/// tab's [EstimateState]. Every read (`est.x`) transparently follows
/// tab switches; the UI only ever builds ONE project, so background
/// tabs cost zero frames (see [ProjectTabs] at the file end).
EstimateState get est => projectTabs.active.state;

class EstimateState extends ChangeNotifier {
  ProjectInfo project = ProjectInfo();
  final List<BoqSection> sections = [];

  /// PERT-CPM activity network (letters are positional: A, B, C…).
  final List<CpmActivity> activities = [];

  /// Filed extensions of the contract duration (each stamped with the
  /// date it was created).
  final List<ContractExtension> extensions = [];

  /// Drawings library (paths only) and the user's annotations on them.
  final List<DrawingFile> drawings = [];

  /// SketchUp-lite models built on the 3D MODEL tab — each one can
  /// generate a plan + elevations DXF sheet into [drawings].
  final List<Model3d> models = [];
  DesignParams design = DesignParams();
  final List<DrawingMark> marks = [];

  /// DRAWINGS view state — in-memory only, NOT serialized into
  /// .boqproj. It survives tab switches because `est` outlives the
  /// view widget that gets recreated on every tab change.
  ///
  /// `drawingXfms` maps 'fileId:page' -> the InteractiveViewer's
  /// Matrix4 storage so zoom/pan restores when the user comes back.
  /// `drawingFocus` = full-width focus mode (tabs hidden, BOQ split
  /// beside the canvas). `drawingLibraryOpen` = file rail visible.
  final Map<String, List<double>> drawingXfms = {};
  bool drawingFocus = false;
  bool drawingLibraryOpen = true;

  /// 3D MODEL tab: plan|3D split fraction (plan share). In-memory
  /// only — survives tab switches, resets on app restart/new project.
  double modelSplitFrac = 0.5;

  /// 3D MODEL tab: left model rail visible. In-memory only — same
  /// pattern as `drawingLibraryOpen`.
  bool modelRailOpen = true;

  /// 3D MODEL tab camera memory — plan offset/scale, 3D orbit
  /// yaw/pitch/zoom/pan, and the viewport layout mode — saved by the
  /// view on dispose and restored on the next mount, so navigating
  /// to another tab and back keeps the viewport where it was.
  /// In-memory only — same contract as `drawingXfms`.
  final Map<String, double> modelCam = {};

  /// Index into `models` of the last-selected model — same contract.
  int modelSel = 0;

  /// 3D MODEL tab: the empty-model onboarding card was dismissed.
  /// In-memory session flag — once the user knows the flow it should
  /// not re-appear on every empty model or new project.
  bool modelIntroDismissed = false;

  void setModelRailOpen(bool v) {
    modelRailOpen = v;
    notifyListeners();
  }

  void setModelSplit(double v) {
    modelSplitFrac = v;
    notifyListeners();
  }

  void setDrawingFocus(bool v) {
    drawingFocus = v;
    notifyListeners();
  }

  void setDrawingLibraryOpen(bool v) {
    drawingLibraryOpen = v;
    notifyListeners();
  }

  /// Editable copy of the embedded price database (the DATA sheet).
  final List<MaterialPrice> priceDb = kPriceDb.map((m) => m.copy()).toList();

  /// While a formula field is being edited, taps on "reference" cells
  /// (summary values, section letters) insert their ref into it — like
  /// Excel's click-to-reference while typing `=`.
  void Function(String ref)? formulaRefSink;

  /// Labor cost as a fraction of material cost (0.30 = 30%) for items
  /// whose labor is still auto-derived. Lines the user hand-priced
  /// (`laborOverridden`) keep their own labor when this changes.
  double laborRate = 0.30;

  /// Change the labor rate and recompute every auto-derived labor cost.
  void setLaborRate(double rate) {
    laborRate = rate;
    for (final s in sections) {
      for (final l in s.lines) {
        if (l.kind == BoqLineKind.item && !l.laborOverridden) {
          l.laborCost = l.materialCost * rate;
        }
      }
    }
    notifyListeners();
  }

  /// Start a fresh estimate: blank BOQ, schedule, extensions, drawings
  /// and marks. The office identity (letterhead, logo, signatories,
  /// theme colors), the price database and the labor rate carry over —
  /// they're reusable assets, not project data. Clears `savedPath` so
  /// the next Save asks for a new file.
  void newProject() {
    final p = ProjectInfo();
    p.letterhead = List.of(project.letterhead);
    p.letterheadBold = project.letterheadBold;
    p.logoB64 = project.logoB64;
    p.signatories = project.signatories
        .map(
          (s) => Signatory(label: s.label, name: s.name, position: s.position),
        )
        .toList();
    p.template = project.template;
    p.showLetterhead = project.showLetterhead;
    p.showSignatories = project.showSignatories;
    p.themeColor = project.themeColor;
    p.sectionColor = project.sectionColor;
    p.groupColor = project.groupColor;
    p.subtotalColor = project.subtotalColor;
    p.summaryColor = project.summaryColor;
    p.unworkableDays = project.unworkableDays;
    p.autoSchedule = project.autoSchedule;
    project = p;
    sections.clear();
    activities.clear();
    suppressedAutoIds.clear();
    _scheduleSig = '';
    extensions.clear();
    drawings.clear();
    models.clear();
    design = DesignParams();
    for (final d in List.of(customCadBlocks)) {
      blockMeshes.remove(d.id);
      blockMeshTop.remove(d.id);
      blockMeshBox.remove(d.id);
    }
    customCadBlocks.clear();
    marks.clear();
    _markRedo.clear();
    measureRefs.clear();
    trackItems.clear();
    inspections.clear();
    scheduleSub = 0;
    drawingXfms.clear();
    drawingFocus = false;
    modelSplitFrac = 0.5;
    modelRailOpen = true;
    modelCam.clear();
    modelSel = 0;
    summaryRows
      ..clear()
      ..addAll(defaultSummaryRows());
    savedPath = null;
    update();
  }

  /// Office-identity carry-over into a FRESH session — the same assets
  /// [newProject] keeps (letterhead, logo, signatories, colors,
  /// unworkable days, price db, labor rate, sheet prefs) so a new
  /// project tab starts from the office setup, not factory defaults.
  void copyOfficeFrom(EstimateState src) {
    final s = src.project;
    project = ProjectInfo()
      ..letterhead = List.of(s.letterhead)
      ..letterheadBold = s.letterheadBold
      ..logoB64 = s.logoB64
      ..signatories = [
        for (final g in s.signatories)
          Signatory(label: g.label, name: g.name, position: g.position),
      ]
      ..template = s.template
      ..showLetterhead = s.showLetterhead
      ..showSignatories = s.showSignatories
      ..themeColor = s.themeColor
      ..sectionColor = s.sectionColor
      ..groupColor = s.groupColor
      ..subtotalColor = s.subtotalColor
      ..summaryColor = s.summaryColor
      ..unworkableDays = s.unworkableDays
      ..autoSchedule = s.autoSchedule;
    priceDb
      ..clear()
      ..addAll([for (final m in src.priceDb) m.copy()]);
    laborRate = src.laborRate;
    sheetPaper = src.sheetPaper;
    sheetLandscape = src.sheetLandscape;
  }

  /// The SUMMARY block rows (I DIRECT COST, II TAX…, III GRAND TOTAL).
  /// Formulas reference earlier rows by their `no` and SECTIONS/TOTAL/
  /// DIRECT for the sum of section subtotals.
  final List<SummaryRow> summaryRows = defaultSummaryRows();

  static List<SummaryRow> defaultSummaryRows() => [
    SummaryRow(no: 'I', label: ' DIRECT COST', formula: 'SECTIONS'),
    SummaryRow(no: 'II', label: 'TAX OF 7% OF I', formula: 'I*7%'),
    SummaryRow(no: 'III', label: 'GRAND TOTAL', formula: 'I+II'),
  ];

  /// Auto letters A, B, C ... matching ITEM NO. column of the workbook.
  String letterOf(BoqSection s) {
    final i = sections.indexOf(s);
    if (i < 0) return '?';
    if (i < 26) return String.fromCharCode(65 + i);
    return 'A${i - 25}';
  }

  BoqSection sectionForTitle(String title) {
    final norm = title.trim().toUpperCase();
    return sections.firstWhere(
      (s) => s.title.trim().toUpperCase() == norm,
      orElse: () {
        final s = BoqSection(title: title.trim().toUpperCase());
        sections.add(s);
        return s;
      },
    );
  }

  /// Append a group header + items to a section (created when missing).
  void addWork({
    required String sectionTitle,
    required String groupLabel,
    required List<BoqLine> items,
  }) {
    final s = sectionForTitle(sectionTitle);
    if (groupLabel.trim().isNotEmpty) {
      s.lines.add(BoqLine.header(groupLabel.trim().toUpperCase()));
    }
    s.lines.addAll(items);
    notifyListeners();
  }

  void addSection(String title) {
    sectionForTitle(title);
    notifyListeners();
  }

  void renameSection(BoqSection s, String title) {
    s.title = title.trim().toUpperCase();
    notifyListeners();
  }

  void removeSection(BoqSection s) {
    sections.remove(s);
    notifyListeners();
  }

  void addLine(BoqSection s, BoqLine line) {
    s.lines.add(line);
    notifyListeners();
  }

  /// Insert [line] at [index] within section [s] (clamped) — used by the
  /// right-click "Insert row above/below" menu.
  void insertLineAt(BoqSection s, int index, BoqLine line) {
    s.lines.insert(index.clamp(0, s.lines.length), line);
    notifyListeners();
  }

  /// Insert a new section at [index] (clamped) — right-click "Insert
  /// section above/below".
  BoqSection insertSectionAt(int index, String title) {
    final s = BoqSection(title: title.trim().toUpperCase());
    sections.insert(index.clamp(0, sections.length), s);
    notifyListeners();
    return s;
  }

  void removeLine(BoqSection s, BoqLine line) {
    s.lines.remove(line);
    notifyListeners();
  }

  /// Commit sections parsed by [BoqImport] — append to the live BOQ or
  /// replace it wholesale (the preview dialog collects the choice).
  /// New uuids are reassigned so ids can't collide with existing rows.
  void importBoq(List<BoqSection> imported, {required bool replace}) {
    if (replace) sections.clear();
    for (final s in imported) {
      s.id = const Uuid().v4();
      for (final l in s.lines) {
        l.id = const Uuid().v4();
      }
      sections.add(s);
    }
    notifyListeners();
  }

  void update() => notifyListeners();

  /// Set one of the project theme colors by slot name:
  /// theme | section | group | subtotal | summary.
  void setProjectColor(String slot, int argb) {
    final p = project;
    switch (slot) {
      case 'theme':
        p.themeColor = argb;
      case 'section':
        p.sectionColor = argb;
      case 'group':
        p.groupColor = argb;
      case 'subtotal':
        p.subtotalColor = argb;
      case 'summary':
        p.summaryColor = argb;
    }
    update();
  }

  // ---------- letterhead & logo ----------

  void setLetterheadLine(int i, String text) {
    if (i < 0 || i >= project.letterhead.length) return;
    project.letterhead[i] = text;
    notifyListeners();
  }

  void insertLetterheadLine(int i, [String text = '']) {
    project.letterhead.insert(i.clamp(0, project.letterhead.length), text);
    if (project.letterheadBold >= i) project.letterheadBold++;
    notifyListeners();
  }

  void removeLetterheadLine(int i) {
    if (i < 0 || i >= project.letterhead.length) return;
    project.letterhead.removeAt(i);
    if (project.letterheadBold == i) {
      project.letterheadBold = -1;
    } else if (project.letterheadBold > i) {
      project.letterheadBold--;
    }
    notifyListeners();
  }

  void setLetterheadBold(int i) {
    project.letterheadBold = i.clamp(-1, project.letterhead.length - 1);
    notifyListeners();
  }

  void resetLetterhead() {
    project.letterhead = ProjectInfo.defaultLetterhead.toList();
    project.letterheadBold = ProjectInfo.defaultLetterheadBold;
    notifyListeners();
  }

  /// Pick a PNG/JPEG image to draw at the left of the letterhead on
  /// export (any government seal or a private company logo).
  Future<void> pickLogo() async {
    final f = await openFile(
      acceptedTypeGroups: [
        const XTypeGroup(
          label: 'Logo image',
          extensions: ['png', 'jpg', 'jpeg'],
        ),
      ],
    );
    if (f == null) return;
    project.logoB64 = base64Encode(await f.readAsBytes());
    notifyListeners();
  }

  void clearLogo() {
    project.logoB64 = null;
    notifyListeners();
  }

  // ---------- signatories ----------

  void addSignatory(Signatory s) {
    project.signatories.add(s);
    notifyListeners();
  }

  void removeSignatory(Signatory s) {
    project.signatories.remove(s);
    notifyListeners();
  }

  // ---------- document templates ----------

  List<DocTemplate> get docTemplates => projectTabs.docTemplates;

  DocTemplate? templateById(String id) =>
      docTemplates.where((t) => t.id == id).firstOrNull;

  /// The library entry behind `project.template` (first builtin when a
  /// project references a template this machine doesn't have).
  DocTemplate get activeTemplate =>
      templateById(project.template) ?? docTemplates.first;

  /// Switch templates: the live working copy (letterhead, logo,
  /// signatories) is written back into the previously active template
  /// first — edits made on the sheet stay with the template they were
  /// made under — then the new template stamps its fields + flags.
  Future<void> applyTemplate(String id) async {
    await projectTabs.loadTemplates();
    final next = templateById(id);
    if (next == null || next.id == project.template) return;
    templateById(project.template)?.captureFrom(project);
    next.applyTo(project);
    projectTabs.persistTemplates();
    notifyListeners();
  }

  /// Snapshot the live header + signature block into a new custom
  /// template and activate it.
  DocTemplate saveAsTemplate(String name) {
    final t = DocTemplate(
      id: 'tpl-${DateTime.now().microsecondsSinceEpoch}',
      name: name.trim().isEmpty ? 'My Template' : name.trim(),
      showLetterhead: project.showLetterhead,
      showSignatories: project.showSignatories,
    )..captureFrom(project);
    docTemplates.add(t);
    t.applyTo(project);
    projectTabs.persistTemplates();
    notifyListeners();
    return t;
  }

  /// Re-snapshot the live fields into an existing custom template.
  void updateTemplateFromCurrent(DocTemplate t) {
    if (t.builtin) return;
    t
      ..showLetterhead = project.showLetterhead
      ..showSignatories = project.showSignatories
      ..captureFrom(project);
    projectTabs.persistTemplates();
    notifyListeners();
  }

  /// Restore a builtin's stock content (clears user customizations).
  void resetTemplate(DocTemplate t) {
    final stock = builtinDocTemplates().firstWhere(
      (b) => b.id == t.id,
      orElse: () => t,
    );
    if (identical(stock, t)) return;
    t
      ..showLetterhead = stock.showLetterhead
      ..showSignatories = stock.showSignatories
      ..letterhead = List.of(stock.letterhead)
      ..letterheadBold = stock.letterheadBold
      ..logoB64 = stock.logoB64
      ..signatories = [
        for (final s in stock.signatories)
          Signatory(label: s.label, name: s.name, position: s.position),
      ];
    if (project.template == t.id) t.applyTo(project);
    projectTabs.persistTemplates();
    notifyListeners();
  }

  void deleteTemplate(DocTemplate t) {
    if (t.builtin) return;
    docTemplates.remove(t);
    if (project.template == t.id) {
      project.template = 'deped';
      docTemplates.first.applyTo(project);
    }
    projectTabs.persistTemplates();
    notifyListeners();
  }

  /// Upload a template file (.tpt/.json — a DocTemplate.toJson map)
  /// into the local library and activate it. Returns its name (null on
  /// cancel or unreadable file).
  Future<String?> importTemplateFile() async {
    final f = await openFile(
      acceptedTypeGroups: [
        const XTypeGroup(
          label: 'Document template',
          extensions: ['tpt', 'json'],
        ),
      ],
    );
    if (f == null) return null;
    try {
      final t = DocTemplate.fromJson(
        Map<String, dynamic>.from(jsonDecode(await f.readAsString())),
      );
      if (docTemplates.any((x) => x.id == t.id)) {
        t.id = 'tpl-${DateTime.now().microsecondsSinceEpoch}';
      }
      docTemplates.add(t);
      project.template = t.id;
      t.applyTo(project);
      projectTabs.persistTemplates();
      notifyListeners();
      return t.name;
    } catch (_) {
      return null;
    }
  }

  /// Save a template to a user-picked file for sharing or backup.
  Future<void> exportTemplate(DocTemplate t) async {
    final loc = await getSaveLocation(
      suggestedName:
          '${t.name.replaceAll(RegExp(r'[^\w]+'), '_')}.tpt',
      acceptedTypeGroups: [
        const XTypeGroup(label: 'Document template', extensions: ['tpt']),
      ],
    );
    if (loc == null) return;
    await File(loc.path).writeAsString(jsonEncode(t.toJson()));
  }

  // ---------- summary rows ----------

  static String _roman(int n) {
    const r = ['', 'I', 'II', 'III', 'IV', 'V', 'VI', 'VII', 'VIII', 'IX', 'X'];
    return n < r.length ? r[n] : n.toString();
  }

  void addSummaryRow({int? after}) {
    final r = SummaryRow(
      no: _roman(summaryRows.length + 1),
      label: 'NEW LINE',
      formula: '0',
    );
    if (after == null) {
      summaryRows.add(r);
    } else {
      summaryRows.insert((after + 1).clamp(0, summaryRows.length), r);
    }
    notifyListeners();
  }

  void removeSummaryRow(SummaryRow r) {
    summaryRows.remove(r);
    notifyListeners();
  }

  /// Evaluates [target]'s formula. Identifiers resolve to the `no` column
  /// of the rows listed ABOVE it, to section letters (A, B, C… = that
  /// section's subtotal), and SECTIONS/TOTAL/DIRECT = [directCost].
  /// Returns NaN when the formula can't be evaluated.
  double summaryValue(SummaryRow target) {
    final env = <String, double>{
      'SECTIONS': directCost,
      'TOTAL': directCost,
      'DIRECT': directCost,
    };
    for (var i = 0; i < sections.length && i < 26; i++) {
      env[String.fromCharCode(65 + i)] = sections[i].subtotal;
    }
    for (final row in summaryRows) {
      if (identical(row, target)) {
        return evalFormula(row.formula, env) ?? double.nan;
      }
      env[row.no.toUpperCase()] = evalFormula(row.formula, env) ?? 0;
    }
    return evalFormula(target.formula, env) ?? double.nan;
  }

  // ---------- drag / reorder ----------

  /// Move a summary row to just before [before] (end when null-ish).
  void moveSummaryRow(SummaryRow row, SummaryRow before) {
    if (identical(row, before)) return;
    summaryRows.remove(row);
    var i = summaryRows.indexOf(before);
    if (i < 0) i = summaryRows.length;
    summaryRows.insert(i, row);
    notifyListeners();
  }

  /// Move a section to just before [before].
  void moveSection(BoqSection s, BoqSection before) {
    if (identical(s, before)) return;
    sections.remove(s);
    var i = sections.indexOf(before);
    if (i < 0) i = sections.length;
    sections.insert(i, s);
    notifyListeners();
  }

  /// Move a line (item or group header) into section [to], placed just
  /// before [before] (or appended when null). Works across sections.
  void moveLine(BoqLine line, BoqSection to, {BoqLine? before}) {
    for (final s in sections) {
      s.lines.remove(line);
    }
    if (before != null) {
      final i = to.lines.indexOf(before);
      to.lines.insert(i < 0 ? to.lines.length : i, line);
    } else {
      to.lines.add(line);
    }
    notifyListeners();
  }

  double get directCost => sections.fold(0.0, (s, x) => s + x.subtotal);
  double get overhead => directCost * 0.07;

  /// Grand total = the last summary row's computed value (the template's
  /// bottom line), falling back to direct + 7% when the list is empty or
  /// its formula is broken.
  double get grandTotal {
    if (summaryRows.isEmpty) return directCost + overhead;
    final v = summaryValue(summaryRows.last);
    return v.isFinite ? v : directCost + overhead;
  }

  /// Resolve a material name in a price list (exact, then contains).
  static MaterialPrice? findIn(List<MaterialPrice> db, String name) {
    final norm = name.trim().toUpperCase();
    for (final m in db) {
      if (m.name.toUpperCase() == norm) return m;
    }
    for (final m in db) {
      if (m.name.toUpperCase().contains(norm) && norm.length > 3) return m;
    }
    for (final m in db) {
      if (norm.contains(m.name.toUpperCase()) && m.name.length > 3) return m;
    }
    return null;
  }

  MaterialPrice? findPrice(String name) => findIn(priceDb, name);

  // ---------- PERT-CPM activities ----------

  String activityLetter(CpmActivity a) => cpmLetter(activities.indexOf(a));

  void addActivity({int? after}) {
    final a = CpmActivity(name: 'NEW ACTIVITY');
    if (after == null) {
      activities.add(a);
    } else {
      activities.insert((after + 1).clamp(0, activities.length), a);
    }
    reletterPreds();
    notifyListeners();
  }

  void removeActivity(CpmActivity a) {
    // Auto rows stay suppressed across syncs; Rebuild restores them.
    if (a.auto) suppressedAutoIds.add(a.id);
    activities.remove(a);
    reletterPreds();
    notifyListeners();
  }

  void moveActivity(CpmActivity a, CpmActivity before) {
    if (identical(a, before)) return;
    activities.remove(a);
    var i = activities.indexOf(before);
    if (i < 0) i = activities.length;
    activities.insert(i, a);
    reletterPreds();
    notifyListeners();
  }

  void setActivityName(CpmActivity a, String name) {
    a.name = name.toUpperCase();
    if (a.auto) a.nameFixed = true;
    update();
  }

  void setActivityDays(CpmActivity a, double days) {
    a.days = days;
    if (a.auto) a.daysFixed = true;
    update();
  }

  /// Parse a preds letter string ('A,C') into ids, flag it as a manual
  /// override on auto rows, then re-letter every row's `preds`.
  void setActivityPreds(CpmActivity a, String letters) {
    final index = {
      for (var i = 0; i < activities.length; i++)
        cpmLetter(i): activities[i].id,
    };
    a.predIds = letters
        .split(RegExp(r'[,;\s]+'))
        .where((s) => s.isNotEmpty)
        .map((l) => index[l.toUpperCase()])
        .whereType<String>()
        .toList();
    if (a.auto) a.predsFixed = true;
    reletterPreds();
    update();
  }

  /// Network-diagram drag drop: landing [a] in column [level] re-points
  /// its predecessors at every activity one column left, so dropping
  /// beside existing nodes runs it parallel with them and dropping one
  /// column further makes it follow that stage sequentially. Landing in
  /// its own column only pins the lane (row order inside the column).
  /// Returns an error string when the drop would cycle the network and
  /// leaves state untouched; null on success. Rows are re-sorted into
  /// the new topological order so the ACT. letters re-align.
  String? moveActivityToCell(CpmActivity a, int level, int lane) {
    final res = computeCpm(activities);
    if (res.error != null) return res.error;
    CpmNode? node;
    for (final n in res.nodes) {
      if (n.a == a) {
        node = n;
        break;
      }
    }
    if (node == null) return 'Activity not found';
    level = level.clamp(0, res.maxLevel + 1);
    lane = lane < 0 ? 0 : lane;
    if (level == node.level) {
      a.lane = lane;
      notifyListeners();
      return null;
    }
    // A descendant can sit in the target's left column — wiring it as
    // a predecessor would cycle, so those candidates drop out.
    final desc = <String>{};
    final stack = List.of(node.succIdx);
    while (stack.isNotEmpty) {
      final j = stack.removeLast();
      if (desc.add(res.nodes[j].a.id)) {
        stack.addAll(res.nodes[j].succIdx);
      }
    }
    final newPreds = level <= 0
        ? <String>[]
        : [
            for (final n in res.nodes)
              if (n.level == level - 1 &&
                  n.a.id != a.id &&
                  !desc.contains(n.a.id))
                n.a.id,
          ];
    final oldPreds = List.of(a.predIds), oldLane = a.lane;
    a.predIds = newPreds;
    a.predsFixed = true;
    a.lane = lane;
    // computeCpm edges come from the `preds` letters — re-letter first
    // or the cycle check runs on the stale graph
    reletterPreds();
    final check = computeCpm(activities);
    if (check.error != null) {
      a.predIds = oldPreds;
      a.lane = oldLane;
      reletterPreds();
      return check.error;
    }
    final order = {
      for (final n in check.nodes) n.a.id: n.level * 1000 + n.lane,
    };
    activities.sort((x, y) => (order[x.id] ?? 0).compareTo(order[y.id] ?? 0));
    reletterPreds();
    notifyListeners();
    return null;
  }

  /// Rewrite every activity's `preds` letter string from [predIds]
  /// against the current row order — call after any insert/remove/
  /// move so letters stay truthful. Dead ids are dropped.
  void reletterPreds() {
    final index = {
      for (var i = 0; i < activities.length; i++) activities[i].id: i,
    };
    for (final a in activities) {
      a.predIds
        ..retainWhere(index.containsKey)
        ..sort((x, y) => index[x]! - index[y]!);
      a.preds = a.predIds.map((id) => cpmLetter(index[id]!)).join(',');
    }
  }

  /// Ids of generated rows the user deleted — kept suppressed across
  /// syncs until "Rebuild from BOQ" clears the set.
  final Set<String> suppressedAutoIds = {};

  /// Fingerprint of the BOQ/settings the schedule was generated from;
  /// the auto rows regenerate whenever it changes.
  String _scheduleSig = '';

  /// Live cost of an activity: BOQ-linked rows read their section's
  /// subtotal × stage share so the S-curve follows BOQ edits; manual
  /// rows use their stored cost.
  double activityCost(CpmActivity a) {
    if (a.sectionId != null) {
      for (final s in sections) {
        if (s.id == a.sectionId) return s.subtotal * a.costShare;
      }
    }
    return a.cost;
  }

  String _sig() {
    final b = StringBuffer()
      ..write('v$kScheduleVersion|')
      ..write(project.contractDuration)
      ..write('|')
      ..write(project.unworkableDays)
      ..write('|');
    for (final s in sections) {
      b.write('${s.id}:${s.title}:${s.subtotal.round()};');
    }
    return b.toString();
  }

  /// Regenerate the auto rows when the BOQ changed (Philippine
  /// convention: the network derives from the quantities). Merges by
  /// stable activity id so user overrides — `…Fixed` fields, deleted
  /// (suppressed) rows and hand-added activities — survive. No-op while
  /// `project.autoSchedule` is off or when nothing changed; a fully
  /// hand-built list is left untouched.
  void syncSchedule({bool force = false}) {
    if (!project.autoSchedule) return;
    final sig = _sig();
    if (!force && sig == _scheduleSig) return;
    _scheduleSig = sig;
    final cd = parseDays(project.contractDuration) ?? 60;
    final target = (cd - project.unworkableDays).clamp(1.0, 3650.0);
    final specs = sections.isEmpty
        ? <CpmActivity>[]
        : generateSchedule(
            sections,
            (s) => s.subtotal,
            targetDays: target.toDouble(),
          );
    final old = {for (final a in activities) a.id: a};
    final next = <CpmActivity>[];
    for (final spec in specs) {
      if (suppressedAutoIds.contains(spec.id)) continue;
      final a = old.remove(spec.id);
      if (a == null) {
        next.add(spec);
      } else {
        if (!a.nameFixed) a.name = spec.name;
        if (!a.daysFixed) a.days = spec.days;
        if (!a.predsFixed) a.predIds = List.of(spec.predIds);
        a
          ..sectionId = spec.sectionId
          ..costShare = spec.costShare
          ..cost = spec.cost
          ..auto = true;
        next.add(a);
      }
    }
    // Hand-built rows keep their place at the end; auto rows whose
    // section vanished don't make it back in.
    next.addAll(old.values.where((a) => !a.auto));
    activities
      ..clear()
      ..addAll(next);
    reletterPreds();
    notifyListeners();
  }

  /// Discard every schedule override and regenerate from the BOQ.
  void rebuildScheduleFromBoq() {
    suppressedAutoIds.clear();
    for (final a in activities) {
      a.nameFixed = a.daysFixed = a.predsFixed = false;
      a.lane = -1;
    }
    _scheduleSig = '';
    syncSchedule(force: true);
  }

  /// Philippine contract-duration derivation: CD = critical-path
  /// duration + pre-determined unworkable days, stated in calendar
  /// days (inclusive of unworkable days) per the NIA/DPWH format.
  void applyCpmDuration(double cpmDays) {
    final total = (cpmDays + project.unworkableDays).ceilToDouble().clamp(
      1,
      3650,
    );
    project.contractDuration = '${total.toInt()} calendar days';
    notifyListeners();
  }

  // ---------- contract extensions ----------

  /// File a new extension: `createdAt` is stamped NOW and the letter
  /// fields default to the current project (title, grand total, and the
  /// Prepared/Recommending/Approved signatories).
  ContractExtension addExtension() {
    final sigs = project.signatories;
    String sigName(int i) => i < sigs.length ? sigs[i].name : '';
    String sigPos(int i) => i < sigs.length ? sigs[i].position : '';
    final x = ContractExtension(
      projectRef: project.title,
      days: 30,
      contractAmount: grandTotal,
      validatedBy: sigName(0),
      validatedPos: sigPos(0),
      recommendBy: sigName(2),
      recommendPos: sigPos(2),
      approvedBy: sigName(3),
      approvedPos: sigPos(3),
    );
    extensions.add(x);
    notifyListeners();
    return x;
  }

  void removeExtension(ContractExtension x) {
    extensions.remove(x);
    notifyListeners();
  }

  // ---------- drawings library & marks ----------

  DrawingFile addDrawing(String path, String kind, {int pageCount = 1}) {
    final f = DrawingFile(
      path: path,
      name: path.split(RegExp(r'[\\/]')).last,
      kind: kind,
      pageCount: pageCount,
    );
    drawings.add(f);
    notifyListeners();
    return f;
  }

  void removeDrawing(DrawingFile f) {
    drawings.remove(f);
    marks.removeWhere((m) => m.fileId == f.id);
    notifyListeners();
  }

  void setDrawingPageCount(DrawingFile f, int n) {
    f.pageCount = n.clamp(1, 9999);
    notifyListeners();
  }

  // ---------- 3D models ----------

  Model3d addModel(String name) {
    final m = Model3d(name: name);
    models.add(m);
    notifyListeners();
    return m;
  }

  void removeModel(Model3d m) {
    models.remove(m);
    notifyListeners();
  }

  /// Marks for one file/page in draw order.
  List<DrawingMark> marksFor(String fileId, int page) => [
    for (final m in marks)
      if (m.fileId == fileId && m.page == page) m,
  ];

  /// Measurement calibration per drawing page — key 'fileId:page'.
  /// Pages of one file can use different scales, so the reference is
  /// never shared across pages.
  final Map<String, MeasureRef> measureRefs = {};

  MeasureRef? measureRefFor(String fileId, int page) =>
      measureRefs['$fileId:$page'];

  void setMeasureRef(String fileId, int page, MeasureRef ref) {
    measureRefs['$fileId:$page'] = ref;
    notifyListeners();
  }

  void clearMeasureRef(String fileId, int page) {
    measureRefs.remove('$fileId:$page');
    notifyListeners();
  }

  /// Marks popped by [undoMark], re-addable by [redoMark]. Cleared by
  /// any new mark or a page clear — the classic undo/redo contract.
  final List<DrawingMark> _markRedo = [];

  void addMark(DrawingMark m) {
    marks.add(m);
    _markRedo.clear();
    notifyListeners();
  }

  /// Pop the newest mark on a page (returns false when nothing to undo).
  bool undoMark(String fileId, int page) {
    for (var i = marks.length - 1; i >= 0; i--) {
      if (marks[i].fileId == fileId && marks[i].page == page) {
        _markRedo.add(marks.removeAt(i));
        notifyListeners();
        return true;
      }
    }
    return false;
  }

  /// Re-add the newest undone mark on a page (false when empty).
  bool redoMark(String fileId, int page) {
    for (var i = _markRedo.length - 1; i >= 0; i--) {
      if (_markRedo[i].fileId == fileId && _markRedo[i].page == page) {
        marks.add(_markRedo.removeAt(i));
        notifyListeners();
        return true;
      }
    }
    return false;
  }

  void clearMarks(String fileId, int page) {
    marks.removeWhere((m) => m.fileId == fileId && m.page == page);
    _markRedo.removeWhere((m) => m.fileId == fileId && m.page == page);
    notifyListeners();
  }

  /// Remove one mark (the eraser tool). Any mark-list mutation clears
  /// the redo stack, same contract as [addMark] / [clearMarks].
  void removeMark(DrawingMark m) {
    if (marks.remove(m)) {
      _markRedo.clear();
      notifyListeners();
    }
  }

  // ---------- project management (work status + inspections) ----------

  /// PROJECT SCHEDULE tab's inner page: 0 = PERT-CPM, 1 = S-CURVE.
  /// Kept here (in-memory only) so the sub-view survives tab switches
  /// like `drawingXfms`.
  int scheduleSub = 0;

  /// S-CURVE time granularity (day / 7-day week / 30-day month).
  /// In-memory only; also drives the exported S-CURVE sheet so the
  /// workbook matches what the user is looking at.
  CurveBucket scurveBucket = CurveBucket.week;

  /// Generated drawing-sheet template: paper name from
  /// `model3d.kPaperSizes` ('A3','A4','Folio 8.5x13',…) and
  /// orientation — landscape is the drafting default. Persisted in
  /// project JSON so every GENERATE run reuses the same sheet.
  String sheetPaper = 'A4';
  bool sheetLandscape = true;

  /// Work-progress board on the PROJECT MANAGEMENT tab. Rows linked to
  /// a BOQ section are seeded by [syncTrackItems]; hand-added rows have
  /// no `sectionId` and can be deleted.
  final List<TrackItem> trackItems = [];

  /// Site inspection log on the PROJECT MANAGEMENT tab.
  final List<Inspection> inspections = [];

  /// Mirror the BOQ: every section gets a linked tracking row (names
  /// follow the section title). Orphaned rows whose section was deleted
  /// are kept — the user may already have marked progress on them.
  void syncTrackItems() {
    var changed = false;
    final linked = {
      for (final t in trackItems)
        if (t.sectionId != null) t.sectionId!: t,
    };
    for (final s in sections) {
      final t = linked[s.id];
      if (t == null) {
        trackItems.add(TrackItem(sectionId: s.id, name: s.title));
        changed = true;
      } else if (t.name != s.title) {
        t.name = s.title;
        changed = true;
      }
    }
    if (changed) notifyListeners();
  }

  void setTrackStatus(TrackItem t, String status) {
    t.status = status;
    // Keep % and status consistent: completed is always 100%, pending
    // 0%, and reopening a completed item backs off to 99%.
    if (status == 'completed') {
      t.progress = 100;
    } else if (status == 'pending') {
      t.progress = 0;
    } else if (t.progress >= 100) {
      t.progress = 99;
    }
    notifyListeners();
  }

  /// Set an item's accomplishment %; the status follows it so the two
  /// can never disagree (0 = pending, 100 = completed, else on-going).
  void setTrackProgress(TrackItem t, double pct) {
    t.progress = pct.clamp(0, 100);
    t.status = t.progress >= 100
        ? 'completed'
        : t.progress <= 0
        ? 'pending'
        : 'ongoing';
    notifyListeners();
  }

  /// Overall project accomplishment 0..1: each item's % weighted by
  /// its BOQ section's subtotal (a ₱3M section counts more than a
  /// ₱4K one). Falls back to a simple average when nothing is priced.
  double get overallProgress {
    if (trackItems.isEmpty) return 0;
    double wsum = 0, acc = 0;
    for (final t in trackItems) {
      var w = 0.0;
      final sid = t.sectionId;
      if (sid != null) {
        for (final s in sections) {
          if (s.id == sid) {
            w = s.subtotal;
            break;
          }
        }
      }
      acc += t.progress * w;
      wsum += w;
    }
    if (wsum <= 0) {
      return trackItems.fold<double>(0, (a, t) => a + t.progress) /
          trackItems.length /
          100;
    }
    return acc / wsum / 100;
  }

  /// Auto-generated inspection findings: a snapshot of today's
  /// accomplishment per item, so the report always reflects the real
  /// percentages at inspection time. Fully editable afterwards.
  String inspectionFindings() {
    final pct = overallProgress * 100;
    String tag(TrackItem t) {
      final sec = t.sectionId == null
          ? null
          : sections.where((s) => s.id == t.sectionId).firstOrNull;
      return sec == null ? t.name : '${t.name} (${letterOf(sec)})';
    }

    String listOf(String st, {bool withPct = false}) {
      final names = [
        for (final t in trackItems)
          if (t.status == st)
            withPct ? '${tag(t)} ${t.progress.toStringAsFixed(0)}%' : tag(t),
      ];
      return names.isEmpty ? '—' : names.join(', ');
    }

    return 'Overall accomplishment: '
        '${pct.toStringAsFixed(2)}% of contract.\n'
        'Completed: ${listOf('completed')}.\n'
        'On-going: ${listOf('ongoing', withPct: true)}.\n'
        'Pending: ${listOf('pending')}.\n'
        'Findings: ';
  }

  /// Add several work items at once (e.g. pasted from a list).
  List<TrackItem> addTrackItems(Iterable<String> names) {
    final added = [
      for (final n in names)
        if (n.trim().isNotEmpty) TrackItem(name: n.trim()),
    ];
    trackItems.addAll(added);
    if (added.isNotEmpty) notifyListeners();
    return added;
  }

  TrackItem addTrackItem(String name) {
    final t = TrackItem(name: name);
    trackItems.add(t);
    notifyListeners();
    return t;
  }

  void removeTrackItem(TrackItem t) {
    trackItems.remove(t);
    notifyListeners();
  }

  /// Insert a new inspection at the top of the log, stamped today and
  /// pre-filled with the auto-generated accomplishment snapshot.
  Inspection addInspection() {
    final now = DateTime.now();
    final i = Inspection(
      date:
          '${now.year.toString().padLeft(4, '0')}-'
          '${now.month.toString().padLeft(2, '0')}-'
          '${now.day.toString().padLeft(2, '0')}',
      findings: inspectionFindings(),
    );
    inspections.insert(0, i);
    notifyListeners();
    return i;
  }

  void removeInspection(Inspection i) {
    inspections.remove(i);
    notifyListeners();
  }

  // ---------- price database editing ----------

  /// Apply an edited material back into the db and refresh every BOQ line
  /// that still tracks it (lines the user hand-priced are left alone).
  void applyMaterialEdit(MaterialPrice m, String oldName) {
    for (final s in sections) {
      for (final l in s.lines) {
        if (l.kind == BoqLineKind.item &&
            !l.priceOverridden &&
            l.priceKey == oldName) {
          l.priceKey = m.name;
          if (l.description == oldName) l.description = m.name;
          l.unit = m.unit;
          l.materialCost = m.price;
          if (!l.laborOverridden) l.laborCost = m.price * laborRate;
        }
      }
    }
    notifyListeners();
  }

  void addMaterial(MaterialPrice m) {
    priceDb.add(m);
    notifyListeners();
  }

  void removeMaterial(MaterialPrice m) {
    priceDb.remove(m);
    notifyListeners();
  }

  void resetPriceDb() {
    priceDb
      ..clear()
      ..addAll(kPriceDb.map((m) => m.copy()));
    notifyListeners();
  }

  // ---------- persistence (.boqproj JSON) ----------

  Map<String, dynamic> toJson() => {
    'project': project.toJson(),
    'priceDb': priceDb.map((m) => m.toJson()).toList(),
    'sections': sections.map((s) => s.toJson()).toList(),
    'summaryRows': summaryRows.map((r) => r.toJson()).toList(),
    'activities': activities.map((a) => a.toJson()).toList(),
    'suppressedAuto': suppressedAutoIds.toList(),
    'scheduleSig': _scheduleSig,
    'extensions': extensions.map((x) => x.toJson()).toList(),
    'drawings': drawings.map((d) => d.toJson()).toList(),
    'models': models.map((m) => m.toJson()).toList(),
    'design': design.toJson(),
    'marks': marks.map((m) => m.toJson()).toList(),
    'measureRefs': measureRefs.map((k, v) => MapEntry(k, v.toJson())),
    'trackItems': trackItems.map((t) => t.toJson()).toList(),
    'inspections': inspections.map((i) => i.toJson()).toList(),
    'customBlocks': customBlocksJson(),
    // the user's own templates ride inside the file — a .boqproj opened
    // on another machine still resolves project.template
    'docTemplates': [
      for (final t in projectTabs.docTemplates)
        if (!t.builtin) t.toJson(),
    ],
    'laborRate': laborRate,
    'sheetPaper': sheetPaper,
    'sheetLandscape': sheetLandscape,
    'savedPath': savedPath,
  };

  void loadJson(Map<String, dynamic> j) {
    project = ProjectInfo.fromJson(
      Map<String, dynamic>.from(j['project'] ?? {}),
    );
    // custom templates embedded in the file join the local library so
    // the referenced template id resolves here too
    if (j['docTemplates'] is List &&
        (j['docTemplates'] as List).isNotEmpty) {
      projectTabs.mergeTemplates(j['docTemplates'] as List);
    }
    sections
      ..clear()
      ..addAll(
        (j['sections'] as List? ?? []).map(
          (s) => BoqSection.fromJson(Map<String, dynamic>.from(s)),
        ),
      );
    activities
      ..clear()
      ..addAll(
        (j['activities'] as List? ?? []).map(
          (a) => CpmActivity.fromJson(Map<String, dynamic>.from(a)),
        ),
      );
    suppressedAutoIds
      ..clear()
      ..addAll((j['suppressedAuto'] as List? ?? []).map((e) => e.toString()));
    _scheduleSig = j['scheduleSig'] ?? '';
    // Legacy project (pre-auto-schedule): rows saved without the auto
    // flag by the old sequential seeder get one upgrade — drop the
    // seeded list so the next sync regenerates the proper construction
    // network; anything with predIds already migrated is kept.
    if (activities.isNotEmpty &&
        activities.every((a) => !a.auto) &&
        (j['seededSectionCount'] ?? 0).toInt() > 0) {
      activities.clear();
      _scheduleSig = '';
    }
    // Legacy rows: derive predIds from letter preds so relettering
    // doesn't strip their links.
    if (activities.isNotEmpty) {
      final index = {
        for (var i = 0; i < activities.length; i++)
          cpmLetter(i): activities[i].id,
      };
      for (final a in activities) {
        if (a.predIds.isEmpty && a.preds.trim().isNotEmpty) {
          a.predIds = a.preds
              .split(RegExp(r'[,;\s]+'))
              .where((s) => s.isNotEmpty)
              .map((l) => index[l.toUpperCase()])
              .whereType<String>()
              .toList();
        }
      }
      reletterPreds();
    }
    extensions
      ..clear()
      ..addAll(
        (j['extensions'] as List? ?? []).map(
          (x) => ContractExtension.fromJson(Map<String, dynamic>.from(x)),
        ),
      );
    drawings
      ..clear()
      ..addAll(
        (j['drawings'] as List? ?? []).map(
          (d) => DrawingFile.fromJson(Map<String, dynamic>.from(d)),
        ),
      );
    loadCustomBlocks(j['customBlocks'] as List?);
    design = DesignParams.fromJson(j['design'] as Map<String, dynamic>?);
    models
      ..clear()
      ..addAll(
        (j['models'] as List? ?? []).map(
          (m) => Model3d.fromJson(Map<String, dynamic>.from(m)),
        ),
      );
    marks
      ..clear()
      ..addAll(
        (j['marks'] as List? ?? []).map(
          (m) => DrawingMark.fromJson(Map<String, dynamic>.from(m)),
        ),
      );
    measureRefs
      ..clear()
      ..addEntries(
        (j['measureRefs'] as Map? ?? {}).entries.map(
          (e) => MapEntry(
            e.key as String,
            MeasureRef.fromJson(Map<String, dynamic>.from(e.value)),
          ),
        ),
      );
    trackItems
      ..clear()
      ..addAll(
        (j['trackItems'] as List? ?? []).map(
          (t) => TrackItem.fromJson(Map<String, dynamic>.from(t)),
        ),
      );
    inspections
      ..clear()
      ..addAll(
        (j['inspections'] as List? ?? []).map(
          (i) => Inspection.fromJson(Map<String, dynamic>.from(i)),
        ),
      );
    savedPath = j['savedPath'];
    priceDb
      ..clear()
      ..addAll(
        (j['priceDb'] as List? ?? kPriceDb.map((m) => m.toJson()).toList()).map(
          (m) => MaterialPrice.fromJson(Map<String, dynamic>.from(m)),
        ),
      );
    summaryRows
      ..clear()
      ..addAll(
        (j['summaryRows'] as List? ??
                defaultSummaryRows().map((r) => r.toJson()).toList())
            .map((r) => SummaryRow.fromJson(Map<String, dynamic>.from(r))),
      );
    laborRate = (j['laborRate'] ?? 0.30).toDouble();
    sheetPaper = (j['sheetPaper'] ?? 'A4').toString();
    sheetLandscape = (j['sheetLandscape'] ?? true) == true;
    notifyListeners();
  }

  // ---------- autosave ----------

  /// Last explicit .boqproj path from Save/Open — once known, autosave
  /// mirrors every edit into it so the user's file is never stale.
  String? savedPath;

  /// Enabled from main() only — tests never write to disk.
  bool autosaveEnabled = false;
  Timer? _autosaveTimer;

  /// Per-tab autosave suffix: '' keeps the legacy `autosave.boqproj`
  /// name (tab 0); other project tabs write `autosave-<id>.boqproj`
  /// so concurrent sessions never clobber one rolling file.
  String autosaveKey = '';

  /// Rolling project file: %APPDATA%\ConstructionEstimate\autosave*.boqproj
  /// (system temp as a fallback so tests/web builds never crash).
  /// Shares [ProjectTabs._dir] so the test `dataDirOverride` redirects
  /// restores AND rolling saves together.
  File get autosaveFile => File(
    '${ProjectTabs._dir.path}'
    '${Platform.pathSeparator}'
    'autosave${autosaveKey.isEmpty ? '' : '-$autosaveKey'}.boqproj',
  );

  @override
  void notifyListeners() {
    super.notifyListeners();
    if (autosaveEnabled) {
      _autosaveTimer?.cancel();
      _autosaveTimer = Timer(const Duration(milliseconds: 700), autosaveNow);
    }
  }

  /// Debounced write: every mutation on any tab funnels through
  /// notifyListeners, so one 700 ms trailing save covers the whole app.
  Future<void> autosaveNow() async {
    try {
      final json = jsonEncode(toJson());
      final f = autosaveFile;
      await f.parent.create(recursive: true);
      await f.writeAsString(json);
      final p = savedPath;
      if (p != null && p != f.path) {
        await File(p).writeAsString(json);
      }
    } catch (_) {}
  }

  /// Load the rolling autosave back into state (called once at startup).
  /// Returns true when a saved project was found.
  Future<bool> restoreAutosave() async {
    try {
      final f = autosaveFile;
      if (!f.existsSync()) return false;
      final j = jsonDecode(await f.readAsString());
      loadJson(j is Map<String, dynamic> ? j : Map<String, dynamic>.from(j));
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<String?> saveProject() async {
    final loc = await getSaveLocation(
      suggestedName: 'estimate.boqproj',
      acceptedTypeGroups: [
        const XTypeGroup(label: 'BOQ Project', extensions: ['boqproj']),
      ],
    );
    if (loc == null) return null;
    savedPath = loc.path;
    await File(loc.path).writeAsString(jsonEncode(toJson()));
    return loc.path;
  }

  Future<String?> openProject() async {
    final file = await openFile(
      acceptedTypeGroups: [
        const XTypeGroup(label: 'BOQ Project', extensions: ['boqproj', 'json']),
      ],
    );
    if (file == null) return null;
    final j = jsonDecode(await file.readAsString());
    savedPath = file.path;
    // projects saved before the logo field existed get the default seal
    // back (an explicit 'logo': null in newer files is respected)
    final pj = j['project'];
    final hadLogoKey = pj is Map && pj.containsKey('logo');
    loadJson(j is Map<String, dynamic> ? j : Map<String, dynamic>.from(j));
    if (!hadLogoKey) {
      try {
        project.logoB64 = base64Encode(
          (await rootBundle.load('assets/deped_logo.png')).buffer.asUint8List(),
        );
      } catch (_) {}
    }
    return file.path;
  }
}

