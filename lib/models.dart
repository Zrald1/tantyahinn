import 'package:uuid/uuid.dart';

const _uuid = Uuid();

/// One signature block entry ("Prepared by" → name → position).
/// Rendered two per row in sheet order: even index left, odd index right.
class Signatory {
  String label;
  String name;
  String position;

  Signatory({this.label = '', this.name = '', this.position = ''});

  Map<String, dynamic> toJson() => {
    'label': label,
    'name': name,
    'position': position,
  };

  factory Signatory.fromJson(Map<String, dynamic> j) => Signatory(
    label: j['label'] ?? '',
    name: j['name'] ?? '',
    position: j['position'] ?? '',
  );
}

/// A reusable document template — the visual identity stamped on the
/// BOQ, POW, generated drawing sheets and every export: the letterhead
/// lines + logo across the top and the signature block at the bottom.
/// Built-ins ship with the app; user templates are saved locally in the
/// app data dir and can also be uploaded from a `.tpt`/`.json` file.
class DocTemplate {
  String id;
  String name;
  bool builtin;
  bool showLetterhead;
  bool showSignatories;
  List<String> letterhead;
  int letterheadBold;
  String? logoB64;
  List<Signatory> signatories;

  DocTemplate({
    required this.id,
    required this.name,
    this.builtin = false,
    this.showLetterhead = true,
    this.showSignatories = true,
    List<String>? letterhead,
    this.letterheadBold = ProjectInfo.defaultLetterheadBold,
    this.logoB64,
    List<Signatory>? signatories,
  }) : letterhead = letterhead ?? [],
       signatories = signatories ?? [];

  /// Copy this template's identity into [p] (apply) — or the reverse:
  /// capture the project's live fields back into the template so the
  /// user's inline edits stay with the template they were made under.
  void applyTo(ProjectInfo p) {
    p.template = id;
    p.showLetterhead = showLetterhead;
    p.showSignatories = showSignatories;
    p.letterhead = List.of(letterhead);
    p.letterheadBold = letterheadBold;
    p.logoB64 = logoB64;
    p.signatories = [
      for (final s in signatories)
        Signatory(label: s.label, name: s.name, position: s.position),
    ];
  }

  void captureFrom(ProjectInfo p) {
    letterhead = List.of(p.letterhead);
    letterheadBold = p.letterheadBold;
    logoB64 = p.logoB64;
    signatories = [
      for (final s in p.signatories)
        Signatory(label: s.label, name: s.name, position: s.position),
    ];
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'showLetterhead': showLetterhead,
    'showSignatories': showSignatories,
    'letterhead': letterhead,
    'letterheadBold': letterheadBold,
    'logo': logoB64,
    'signatories': signatories.map((s) => s.toJson()).toList(),
  };

  factory DocTemplate.fromJson(Map<String, dynamic> j) {
    final t = DocTemplate(
      id: j['id'] ?? 'tpl-${_uuid.v4()}',
      name: j['name'] ?? 'Template',
      showLetterhead: j['showLetterhead'] ?? true,
      showSignatories: j['showSignatories'] ?? true,
      letterhead:
          (j['letterhead'] as List?)?.map((e) => e.toString()).toList() ??
          [],
      letterheadBold:
          ((j['letterheadBold'] ?? ProjectInfo.defaultLetterheadBold) as num)
              .toInt(),
      logoB64: j['logo'],
      signatories:
          (j['signatories'] as List?)
              ?.map(
                (s) => Signatory.fromJson(Map<String, dynamic>.from(s)),
              )
              .toList() ??
          [],
    );
    // a stored deped template still carrying the retired office names
    // gets them blanked (labels/positions keep the user's structure)
    if (t.id == 'deped') _normalizeSignatories(t.signatories);
    return t;
  }
}

/// The two stock templates. [kPrivateDocTemplate] has no office
/// letterhead but still signs the BOQ/POW — Prepared by the engineer
/// plus any signatories the user adds on the sheet.
List<DocTemplate> builtinDocTemplates() => [
  DocTemplate(
    id: 'deped',
    name: 'DepEd Template',
    builtin: true,
    letterhead: ProjectInfo.defaultLetterhead.toList(),
    signatories: _depedSeats(),
  ),
  DocTemplate(
    id: 'private',
    name: 'Private Template',
    builtin: true,
    showLetterhead: false,
    signatories: [
      Signatory(
        label: 'Prepared by',
        name: 'GERALD BUSTILLA',
        position: 'Civil Engineer',
      ),
    ],
  ),
];

/// The DepEd office sign-off — the four seats are part of the template
/// identity: only the Prepared seat carries a name; the other seats
/// keep their office titles with the name left blank for the sitting
/// officer to sign.
List<Signatory> _depedSeats() => [
  Signatory(
    label: 'Prepared by',
    name: 'GERALD BUSTILLA',
    position: 'Civil Engineer',
  ),
  Signatory(
    label: 'Checked & Reviewed by',
    name: '',
    position: 'Division Engineer',
  ),
  Signatory(
    label: 'Recommending Approval by',
    name: '',
    position: 'SGOD Chief',
  ),
  Signatory(
    label: 'Approved by',
    name: '',
    position: 'Schools Division Superintendent',
  ),
];

/// The retired office signatories — stored projects/templates still
/// carrying these names have them blanked (the labels and office
/// titles stay; the person is whoever sits in the seat now).
const _retiredSignatoryNames = {
  'VIRGILIO B. BANCASO',
  'JONATHAN D. NARVATO',
  'PEDRO J. PELONIO',
  'NORMA B. SAMANTELA, CESO V',
};

/// Normalize [sigs] to the current sign-off: the retired office names
/// are blanked (labels and office titles survive — the person is
/// whoever sits in the seat now) and the old default preparer becomes
/// 'GERALD BUSTILLA / Civil Engineer'. Missing canonical seats are
/// re-inserted in order (stale files saved with fewer rows, hand-edited
/// json); user-reordered seats and extra custom rows are left alone.
/// Returns true when anything changed.
bool _normalizeSignatories(List<Signatory> sigs) {
  var hit = false;
  for (final s in sigs) {
    final n = s.name.toUpperCase();
    if (_retiredSignatoryNames.contains(n)) {
      s.name = '';
      hit = true;
    } else if (n == 'GERALD P. BUSTILLA' ||
        (n == 'GERALD BUSTILLA' && s.position == 'EFS - Staff')) {
      s
        ..name = 'GERALD BUSTILLA'
        ..position = 'Civil Engineer';
      hit = true;
    }
  }
  var insertAt = 0; // the canonical seats lead the block
  for (final seat in _depedSeats()) {
    final i = sigs.indexWhere((s) => s.label == seat.label);
    if (i >= 0) {
      insertAt = i + 1;
    } else {
      sigs.insert(insertAt, seat);
      insertAt++;
      hit = true;
    }
  }
  return hit;
}

class ProjectInfo {
  /// The office letterhead printed at the top of BOQ and POW — one entry
  /// per centered line. [letterheadBold] marks the emphasized line
  /// (the office name; -1 = none) and [logoB64] is an optional PNG/JPEG
  /// drawn at the left of the header on export (null = no logo).
  static const defaultLetterhead = [
    'Republic of the Philippines',
    'Department of Education',
    'Region V',
    'SCHOOLS DIVISION OFFICE OF CAMARINES SUR',
    'Freedom of Sports Complex, San Jose, Pili, Camarines Sur',
  ];
  static const defaultLetterheadBold = 3;

  List<String> letterhead;
  int letterheadBold;
  String? logoB64;

  String title;

  /// Glyph height (mm) of the project title on generated drawing
  /// sheets — resized by dragging the title cell's corner handle in
  /// the DRAWINGS viewer. 3.0 matches the stock strip layout.
  double titleSize;
  String location;
  String division;
  DateTime date;
  String contractDuration;
  int unworkableDays; // pre-determined unworkable days inside the CD
  /// When true (default) the PERT-CPM network is derived from the BOQ
  /// automatically — sections map onto construction-logic phases and
  /// stay in sync. Turn off to hand-manage the activity list.
  bool autoSchedule;
  String sourceOfFund;
  String physicalTarget;
  List<Signatory> signatories;

  /// The active document template's id — 'deped' (government letterhead
  /// + signatories), 'private' (no header, engineer sign-off) or a
  /// custom 'tpl-*' from the local template library. [showLetterhead]
  /// and [showSignatories] are the flags the template stamped; the
  /// letterhead/signatory fields always hold the live working copy.
  String template;
  bool showLetterhead;
  bool showSignatories;

  /// Theme colors (ARGB ints) — accent drives the app theme, the navy
  /// table header, the grand-total bar and the export's navy rule;
  /// the band colors paint section headers, group/location labels,
  /// subtotal rows and the ordinary summary rows.
  int themeColor;
  int sectionColor;
  int groupColor;
  int subtotalColor;
  int summaryColor;

  ProjectInfo({
    List<String>? letterhead,
    this.letterheadBold = defaultLetterheadBold,
    this.logoB64,
    this.title = 'IMPROVEMENT OF ASDS OFFICE',
    this.titleSize = 3.0,
    this.location = 'SDO NEW BUILDING',
    this.division = 'CAMARINES SUR',
    DateTime? date,
    this.contractDuration = '60 days',
    this.unworkableDays = 0,
    this.autoSchedule = true,
    this.sourceOfFund = '',
    this.physicalTarget = '',
    List<Signatory>? signatories,
    this.template = 'deped',
    this.showLetterhead = true,
    this.showSignatories = true,
    this.themeColor = 0xFF1E4976,
    this.sectionColor = 0xFFDBE4F0,
    this.groupColor = 0xFFF1F5F9,
    this.subtotalColor = 0xFFEAF1F8,
    this.summaryColor = 0xFFF1F5F9,
  }) : letterhead = letterhead ?? defaultLetterhead.toList(),
       date = date ?? DateTime.now(),
       signatories = signatories ?? _depedSeats();

  Map<String, dynamic> toJson() => {
    'letterhead': letterhead,
    'letterheadBold': letterheadBold,
    'logo': logoB64,
    'title': title,
    'titleSize': titleSize,
    'location': location,
    'division': division,
    'date': date.toIso8601String(),
    'contractDuration': contractDuration,
    'unworkableDays': unworkableDays,
    'autoSchedule': autoSchedule,
    'sourceOfFund': sourceOfFund,
    'physicalTarget': physicalTarget,
    'signatories': signatories.map((s) => s.toJson()).toList(),
    'template': template,
    'showLetterhead': showLetterhead,
    'showSignatories': showSignatories,
    'themeColor': themeColor,
    'sectionColor': sectionColor,
    'groupColor': groupColor,
    'subtotalColor': subtotalColor,
    'summaryColor': summaryColor,
  };

  factory ProjectInfo.fromJson(Map<String, dynamic> j) {
    final head =
        (j['letterhead'] as List?)?.map((e) => e.toString()).toList() ??
        defaultLetterhead.toList();
    final p = ProjectInfo(
      letterhead: head,
      letterheadBold: ((j['letterheadBold'] ?? defaultLetterheadBold) as num)
          .clamp(-1, head.length - 1)
          .toInt(),
      logoB64: j['logo'],
      title: j['title'] ?? '',
      titleSize: ((j['titleSize'] as num?) ?? 3.0).clamp(1.2, 9.0).toDouble(),
      location: j['location'] ?? '',
      division: j['division'] ?? '',
      date: DateTime.tryParse(j['date'] ?? '') ?? DateTime.now(),
      contractDuration: j['contractDuration'] ?? '',
      unworkableDays: (j['unworkableDays'] ?? 0).toInt(),
      autoSchedule: j['autoSchedule'] ?? true,
      sourceOfFund: j['sourceOfFund'] ?? '',
      physicalTarget: j['physicalTarget'] ?? '',
      signatories: (j['signatories'] as List?)
          ?.map((s) => Signatory.fromJson(Map<String, dynamic>.from(s)))
          .toList(),
      // template ids: legacy 'public' -> 'deped'; unknown strings are
      // kept (custom templates travel inside the project file too)
      template: _migrateTemplateId(j['template']),
      showLetterhead: j.containsKey('showLetterhead')
          ? j['showLetterhead'] == true
          : j['template'] != 'private',
      showSignatories: j['showSignatories'] ?? true,
      themeColor: j['themeColor'] ?? 0xFF1E4976,
      sectionColor: j['sectionColor'] ?? 0xFFDBE4F0,
      groupColor: j['groupColor'] ?? 0xFFF1F5F9,
      subtotalColor: j['subtotalColor'] ?? 0xFFEAF1F8,
      summaryColor: j['summaryColor'] ?? 0xFFF1F5F9,
    );
    // migrate legacy fixed-field projects — the stock structure:
    // Gerald prepares, the other seats carry titles with blank names
    if (!j.containsKey('signatories')) {
      final seats = _depedSeats();
      seats[0]
        ..name = j['preparedBy'] ?? 'GERALD BUSTILLA'
        ..position = j['preparedByPosition'] ?? 'Civil Engineer';
      seats[1]
        ..name = j['reviewedBy'] ?? ''
        ..position = j['reviewedByPosition'] ?? 'Division Engineer';
      seats[2]
        ..name = j['recommendBy'] ?? ''
        ..position = j['recommendByPosition'] ?? 'SGOD Chief';
      seats[3]
        ..name = j['approvedBy'] ?? ''
        ..position =
            j['approvedByPosition'] ?? 'Schools Division Superintendent';
      p.signatories
        ..clear()
        ..addAll(seats);
    }
    // Legacy 'private' projects predate the flag fields: they stored
    // the office sign-off which never rendered. The private template
    // signs its own block now, so those stored rows are replaced with
    // the engineer's default (the DepEd rows still live in the DepEd
    // template — switching back restores them).
    if (p.template == 'private' && !j.containsKey('showSignatories')) {
      final priv = builtinDocTemplates().firstWhere(
        (t) => t.id == 'private',
      );
      p.signatories
        ..clear()
        ..addAll([
          for (final s in priv.signatories)
            Signatory(label: s.label, name: s.name, position: s.position),
        ]);
    }
    // Retired office names are blanked in deped projects (labels and
    // titles stay — the seats exist, the names are empty); custom
    // signatories the user typed keep their names.
    if (p.template == 'deped') _normalizeSignatories(p.signatories);
    return p;
  }

  /// Legacy id migration: 'public' -> 'deped', 'private' stays; anything
  /// else is kept as-is so custom template ids survive a round-trip.
  static String _migrateTemplateId(Object? v) {
    final s = v?.toString() ?? '';
    if (s == 'public' || s.isEmpty) return 'deped';
    return s;
  }

  /// true when the active template drops the office header — sheets and
  /// exports show no letterhead/logo (the signature block is governed
  /// by [showSignatories], so a private estimate still gets signed).
  bool get isPrivate => !showLetterhead;

  /// What consumers should render/export, gated by the active
  /// template's flags; the stored lists are never mutated.
  List<String> get effLetterhead => showLetterhead ? letterhead : const [];
  List<Signatory> get effSignatories =>
      showSignatories ? signatories : const [];

  /// The letterhead logo — suppressed on headerless exports (the
  /// drawing-sheet title cell still shows it).
  String? get effLogo => showLetterhead ? logoB64 : null;
}

/// One row of the sheet's SUMMARY block: a label plus an Excel-style
/// formula string (e.g. "SECTIONS", "I*7%", "I+II"). References resolve
/// against the `no` column of the rows above it; SECTIONS/TOTAL/DIRECT
/// mean the sum of all section subtotals.
class SummaryRow {
  String no;
  String label;
  String formula;

  SummaryRow({this.no = '', this.label = '', this.formula = '0'});

  Map<String, dynamic> toJson() => {
    'no': no,
    'label': label,
    'formula': formula,
  };

  factory SummaryRow.fromJson(Map<String, dynamic> j) => SummaryRow(
    no: j['no'] ?? '',
    label: j['label'] ?? '',
    formula: j['formula'] ?? '0',
  );
}

enum BoqLineKind { item, groupHeader }

/// A single row inside a BOQ section: either a priced item or a bold
/// location/group header (e.g. "3RD FLOOR CR").
class BoqLine {
  String id;
  BoqLineKind kind;
  String description;
  double qty;
  String unit;
  double materialCost; // unit material cost
  double laborCost; // unit labor cost
  /// Material name in the DATA sheet used to emit VLOOKUPs on export.
  String? priceKey;

  /// True once the user hand-edits the unit costs — the price-database
  /// editor will then leave this line alone.
  bool priceOverridden;

  /// True once the user hand-edits (or erases) the labor cost directly —
  /// global labor-rate changes then leave this line alone.
  bool laborOverridden;

  BoqLine({
    String? id,
    this.kind = BoqLineKind.item,
    this.description = '',
    this.qty = 0,
    this.unit = '',
    this.materialCost = 0,
    this.laborCost = 0,
    this.priceKey,
    this.priceOverridden = false,
    this.laborOverridden = false,
  }) : id = id ?? _uuid.v4();

  factory BoqLine.header(String text) =>
      BoqLine(kind: BoqLineKind.groupHeader, description: text);

  double get materialTotal => materialCost * qty;
  double get laborTotal => laborCost * qty;
  double get amount => materialTotal + laborTotal;

  Map<String, dynamic> toJson() => {
    'id': id,
    'kind': kind.index,
    'description': description,
    'qty': qty,
    'unit': unit,
    'materialCost': materialCost,
    'laborCost': laborCost,
    'priceKey': priceKey,
    'priceOverridden': priceOverridden,
    'laborOverridden': laborOverridden,
  };

  factory BoqLine.fromJson(Map<String, dynamic> j) => BoqLine(
    id: j['id'],
    kind: BoqLineKind.values[j['kind'] ?? 0],
    description: j['description'] ?? '',
    qty: (j['qty'] ?? 0).toDouble(),
    unit: j['unit'] ?? '',
    materialCost: (j['materialCost'] ?? 0).toDouble(),
    laborCost: (j['laborCost'] ?? 0).toDouble(),
    priceKey: j['priceKey'],
    priceOverridden: j['priceOverridden'] ?? false,
    laborOverridden: j['laborOverridden'] ?? false,
  );
}

/// One node of the PERT-CPM network. Its letter is positional (A, B, C…
/// like ITEM NO. on the sheets); [preds] is the user-typed list of
/// predecessor letters ("A,C" — blank = start activity); [cost] weights
/// the activity for the S-curve (0 = equal share).
class CpmActivity {
  /// Stable identity. Auto-generated rows use 'auto:SECTION_ID:KEY'
  /// (or 'auto:v:KEY' for virtual rows) so regeneration can match
  /// them; user-added rows get a uuid.
  String id;
  String name;
  double days;

  /// Display/engine form: predecessor LETTERS ('A,C'). Regenerated
  /// from [predIds] whenever the row order changes — never store it
  /// as the source of truth.
  String preds;

  /// Canonical predecessors: activity ids, immune to row reordering.
  List<String> predIds;

  /// Stored cost for manual rows; for BOQ-linked rows the live cost
  /// comes from the section subtotal × [costShare] (this field keeps a
  /// snapshot for when the section is gone).
  double cost;

  /// Auto-generated rows ([auto] = true) are rebuilt by the schedule
  /// sync; `…Fixed` flags mark fields the user overrode so the sync
  /// leaves them alone.
  bool auto;
  bool nameFixed;
  bool daysFixed;
  bool predsFixed;

  /// BOQ section this activity reports progress against (live cost).
  String? sectionId;
  double costShare; // portion of the section subtotal (stage split)

  /// Network-diagram lane pinned by dragging a node up/down inside its
  /// column; -1 lets the layout choose (barycenter).
  int lane;

  CpmActivity({
    String? id,
    this.name = '',
    this.days = 1,
    this.preds = '',
    List<String>? predIds,
    this.cost = 0,
    this.auto = false,
    this.nameFixed = false,
    this.daysFixed = false,
    this.predsFixed = false,
    this.sectionId,
    this.costShare = 1,
    this.lane = -1,
  }) : id = id ?? _uuid.v4(),
       predIds = predIds ?? [];

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'days': days,
    'preds': preds,
    'predIds': predIds,
    'cost': cost,
    'auto': auto,
    'nameFixed': nameFixed,
    'daysFixed': daysFixed,
    'predsFixed': predsFixed,
    'sectionId': sectionId,
    'costShare': costShare,
    'lane': lane,
  };

  factory CpmActivity.fromJson(Map<String, dynamic> j) => CpmActivity(
    id: j['id'],
    name: j['name'] ?? '',
    days: (j['days'] ?? 1).toDouble(),
    preds: j['preds'] ?? '',
    predIds: (j['predIds'] as List?)?.map((e) => e.toString()).toList(),
    cost: (j['cost'] ?? 0).toDouble(),
    auto: j['auto'] ?? false,
    nameFixed: j['nameFixed'] ?? false,
    daysFixed: j['daysFixed'] ?? false,
    predsFixed: j['predsFixed'] ?? false,
    sectionId: j['sectionId'],
    costShare: (j['costShare'] ?? 1).toDouble(),
    lane: (j['lane'] ?? -1).toInt(),
  );
}

/// One recorded extension of the contract duration. [createdAt] is
/// stamped automatically when the user files the extension and never
/// changes afterwards — it is the "date the extension was created"
/// printed on the letter and kept in the record list.
class ContractExtension {
  String id;
  DateTime createdAt;
  String projectRef; // e.g. "Lot 7 – Construction of TLS ..."
  String contractor;
  int days;
  String reason; // e.g. "adverse weather conditions"
  String reasonBasis; // e.g. "weather-related interruptions"
  double contractAmount;
  String validatedBy;
  String validatedPos;
  String recommendBy;
  String recommendPos;
  String approvedBy;
  String approvedPos;

  ContractExtension({
    String? id,
    DateTime? createdAt,
    this.projectRef = '',
    this.contractor = '',
    this.days = 30,
    this.reason = 'adverse weather conditions',
    this.reasonBasis = 'weather-related interruptions',
    this.contractAmount = 0,
    this.validatedBy = '',
    this.validatedPos = '',
    this.recommendBy = '',
    this.recommendPos = '',
    this.approvedBy = '',
    this.approvedPos = '',
  }) : id = id ?? _uuid.v4(),
       createdAt = createdAt ?? DateTime.now();

  Map<String, dynamic> toJson() => {
    'id': id,
    'createdAt': createdAt.toIso8601String(),
    'projectRef': projectRef,
    'contractor': contractor,
    'days': days,
    'reason': reason,
    'reasonBasis': reasonBasis,
    'contractAmount': contractAmount,
    'validatedBy': validatedBy,
    'validatedPos': validatedPos,
    'recommendBy': recommendBy,
    'recommendPos': recommendPos,
    'approvedBy': approvedBy,
    'approvedPos': approvedPos,
  };

  factory ContractExtension.fromJson(Map<String, dynamic> j) =>
      ContractExtension(
        id: j['id'],
        createdAt: DateTime.tryParse(j['createdAt'] ?? ''),
        projectRef: j['projectRef'] ?? '',
        contractor: j['contractor'] ?? '',
        days: (j['days'] ?? 30).toInt(),
        reason: j['reason'] ?? '',
        reasonBasis: j['reasonBasis'] ?? '',
        contractAmount: (j['contractAmount'] ?? 0).toDouble(),
        validatedBy: j['validatedBy'] ?? '',
        validatedPos: j['validatedPos'] ?? '',
        recommendBy: j['recommendBy'] ?? '',
        recommendPos: j['recommendPos'] ?? '',
        approvedBy: j['approvedBy'] ?? '',
        approvedPos: j['approvedPos'] ?? '',
      );
}

/// A file added to the Drawings library. `kind` is 'image' | 'pdf' |
/// 'dxf'; [pageCount] is filled in when a pdf is opened so the library
/// can show its page list. Only the path is stored - missing files are
/// flagged at view time, not at load time.
class DrawingFile {
  String id;
  String path;
  String name;
  String kind;
  int pageCount;
  DateTime addedAt;

  DrawingFile({
    String? id,
    required this.path,
    required this.name,
    required this.kind,
    this.pageCount = 1,
    DateTime? addedAt,
  }) : id = id ?? _uuid.v4(),
       addedAt = addedAt ?? DateTime.now();

  Map<String, dynamic> toJson() => {
    'id': id,
    'path': path,
    'name': name,
    'kind': kind,
    'pageCount': pageCount,
    'addedAt': addedAt.toIso8601String(),
  };

  factory DrawingFile.fromJson(Map<String, dynamic> j) => DrawingFile(
    id: j['id'],
    path: j['path'] ?? '',
    name: j['name'] ?? '',
    kind: j['kind'] ?? 'image',
    pageCount: (j['pageCount'] ?? 1).toInt(),
    addedAt: DateTime.tryParse(j['addedAt'] ?? ''),
  );
}

/// One annotation drawn on a document page. Coordinates are normalized
/// (0..1) against the page's natural size so marks survive zooming and
/// re-rendering at different resolutions.
/// kind: 'pen' | 'hi' (highlighter) | 'arrow' | 'rect' | 'text'.
/// For pen/hi, [pts] is the stroke; for arrow/rect two points (start,
/// end); for text a single anchor point + [text].
class DrawingMark {
  String fileId;
  int page;
  String kind;
  List<double> pts; // flattened [x1,y1,x2,y2,...], normalized
  int color;
  double width; // stroke width in content-space px
  String text;

  DrawingMark({
    required this.fileId,
    this.page = 0,
    required this.kind,
    List<double>? pts,
    this.color = 0xFFD32F2F,
    this.width = 3,
    this.text = '',
  }) : pts = pts ?? [];

  Map<String, dynamic> toJson() => {
    'fileId': fileId,
    'page': page,
    'kind': kind,
    'pts': pts,
    'color': color,
    'width': width,
    'text': text,
  };

  factory DrawingMark.fromJson(Map<String, dynamic> j) => DrawingMark(
    fileId: j['fileId'] ?? '',
    page: (j['page'] ?? 0).toInt(),
    kind: j['kind'] ?? 'pen',
    pts: (j['pts'] as List? ?? []).map((e) => (e as num).toDouble()).toList(),
    color: (j['color'] ?? 0xFFD32F2F).toInt(),
    width: (j['width'] ?? 3).toDouble(),
    text: j['text'] ?? '',
  );
}

/// Per-page calibration for the measure tool: a drawn reference line
/// [pxLen] content-px long is known to be [realLen] [unit] in the real
/// world. Stored per file+page because every sheet on a plan can use
/// a different scale.
class MeasureRef {
  final double pxLen;
  final double realLen;
  final String unit;
  const MeasureRef(this.pxLen, this.realLen, this.unit);

  double get realPerPx => pxLen == 0 ? 0 : realLen / pxLen;

  Map<String, dynamic> toJson() => {'px': pxLen, 'real': realLen, 'unit': unit};

  factory MeasureRef.fromJson(Map<String, dynamic> j) => MeasureRef(
    (j['px'] ?? 0).toDouble(),
    (j['real'] ?? 0).toDouble(),
    j['unit'] ?? 'mm',
  );
}

/// Project-management tracking row — one per BOQ section (linked via
/// [sectionId]) plus any hand-added work items. Status cycles
/// pending -> ongoing -> completed.
class TrackItem {
  String id;
  String? sectionId; // null = hand-added item not in the BOQ
  String name;
  String status; // 'pending' | 'ongoing' | 'completed'
  String remarks;
  double progress; // 0..100 accomplishment %

  TrackItem({
    String? id,
    this.sectionId,
    this.name = '',
    this.status = 'pending',
    this.remarks = '',
    this.progress = 0,
  }) : id = id ?? _uuid.v4();

  static const statuses = ['pending', 'ongoing', 'completed'];

  Map<String, dynamic> toJson() => {
    'id': id,
    'sectionId': sectionId,
    'name': name,
    'status': status,
    'remarks': remarks,
    'progress': progress,
  };

  factory TrackItem.fromJson(Map<String, dynamic> j) => TrackItem(
    id: j['id'],
    sectionId: j['sectionId'],
    name: j['name'] ?? '',
    status: statuses.contains(j['status']) ? j['status'] : 'pending',
    remarks: j['remarks'] ?? '',
    progress: (j['progress'] as num?)?.toDouble().clamp(0, 100) ?? 0,
  );
}

/// A site inspection entry on the Project Management tab — a visit
/// date, who inspected, and what was found.
class Inspection {
  String id;
  String date; // ISO yyyy-MM-dd, '' = not set yet
  String inspector;
  String findings;

  Inspection({
    String? id,
    this.date = '',
    this.inspector = '',
    this.findings = '',
  }) : id = id ?? _uuid.v4();

  Map<String, dynamic> toJson() => {
    'id': id,
    'date': date,
    'inspector': inspector,
    'findings': findings,
  };

  factory Inspection.fromJson(Map<String, dynamic> j) => Inspection(
    id: j['id'],
    date: j['date'] ?? '',
    inspector: j['inspector'] ?? '',
    findings: j['findings'] ?? '',
  );
}

class BoqSection {
  String id;
  String title;
  String remark; // shown in the POW REMARKS column
  List<BoqLine> lines;

  BoqSection({
    String? id,
    this.title = '',
    this.remark = '',
    List<BoqLine>? lines,
  }) : id = id ?? _uuid.v4(),
       lines = lines ?? [];

  double get subtotal => lines
      .where((l) => l.kind == BoqLineKind.item)
      .fold(0.0, (s, l) => s + l.amount);

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'remark': remark,
    'lines': lines.map((l) => l.toJson()).toList(),
  };

  factory BoqSection.fromJson(Map<String, dynamic> j) => BoqSection(
    id: j['id'],
    title: j['title'] ?? '',
    remark: j['remark'] ?? '',
    lines: (j['lines'] as List? ?? [])
        .map((l) => BoqLine.fromJson(Map<String, dynamic>.from(l)))
        .toList(),
  );
}
