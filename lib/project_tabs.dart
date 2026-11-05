// Project-tab sessions - part of state.dart (keeps the file under
// the ~1000-line cap). See the "project tabs" section in AGENTS.md.
part of 'state.dart';

// ---------- project tabs (multi-session) ----------

/// One open project tab: its own [EstimateState] so sections, marks,
/// drawings, models, view flags and camera memory are independent.
/// Rendering is lazy — `est` resolves to the ACTIVE tab's state only,
/// so the UI builds one project and background tabs are plain state
/// objects holding data (zero widgets, zero frames).
class ProjectSession {
  ProjectSession(this.id, {bool autosave = false}) : state = EstimateState() {
    state.autosaveKey = id == 0 ? '' : '$id';
    state.autosaveEnabled = autosave;
  }

  final int id;
  final EstimateState state;

  /// The view tab (BOQ/POW/DRAWINGS/…) this session was last on —
  /// restored when the user switches back to it.
  int viewTab = 0;

  /// Anything worth keeping — used to confirm before closing the tab.
  bool get hasContent =>
      state.sections.isNotEmpty ||
      state.models.isNotEmpty ||
      state.drawings.isNotEmpty ||
      state.marks.isNotEmpty ||
      state.activities.isNotEmpty;
}

/// The open project tabs, browser-style. `est` reads the active one.
final projectTabs = ProjectTabs();

class ProjectTabs extends ChangeNotifier {
  final List<ProjectSession> tabs = [ProjectSession(0)];
  int _active = 0;
  int _nextId = 1;

  /// Disk persistence gate — main() sets it once so real sessions
  /// autosave + persist the manifest; tests stay off the filesystem.
  bool autosave = false;

  ProjectSession get active => tabs[_active];

  /// A blank tab. [inheritOffice] copies the current tab's office
  /// assets (the "New estimate keeps letterhead/prices" contract);
  /// pass false when the tab is about to be filled by Open/restore.
  ProjectSession newTab({bool activate = true, bool inheritOffice = true}) {
    final s = ProjectSession(_nextId++, autosave: autosave);
    if (inheritOffice) s.state.copyOfficeFrom(active.state);
    tabs.add(s);
    if (activate) _active = tabs.length - 1;
    _persist();
    notifyListeners();
    return s;
  }

  void activate(ProjectSession s) => activateIndex(tabs.indexOf(s));

  void activateIndex(int i) {
    if (i < 0 || i >= tabs.length || i == _active) return;
    _active = i;
    _persist();
    notifyListeners();
  }

  /// Remove the tab — its rolling autosave file goes with it (closing
  /// discards unsaved work; the caller confirms first). The last tab
  /// never disappears: it resets in place, keeping office assets —
  /// the same contract the old "New estimate" button had.
  void close(ProjectSession s) {
    if (tabs.length <= 1) {
      tabs.single.state.newProject();
      notifyListeners();
      return;
    }
    final i = tabs.indexOf(s);
    if (i < 0) return;
    try {
      s.state.autosaveFile.deleteSync();
    } catch (_) {}
    tabs.removeAt(i);
    if (_active > i) _active--;
    if (_active >= tabs.length) _active = tabs.length - 1;
    _persist();
    notifyListeners();
  }

  /// Rebuild the tab list from the persisted manifest + each tab's
  /// own rolling autosave. Falls back to the single legacy
  /// autosave.boqproj (pre-tabs builds) as tab 0. Returns true when
  /// anything was restored.
  Future<bool> restore() async {
    await loadTemplates();
    var any = false;
    try {
      final j = jsonDecode(await _manifest.readAsString());
      final ids = [
        for (final t in j['tabs'] as List? ?? const []) (t as num).toInt(),
      ];
      if (ids.isNotEmpty) {
        tabs.clear();
        for (final id in ids) {
          final s = ProjectSession(id, autosave: autosave);
          tabs.add(s);
          if (id >= _nextId) _nextId = id + 1;
          if (await s.state.restoreAutosave()) any = true;
        }
        final a = (j['active'] as num?)?.toInt() ?? 0;
        _active = a.clamp(0, tabs.length - 1);
      }
    } catch (_) {}
    if (tabs.isEmpty) tabs.add(ProjectSession(0, autosave: autosave));
    if (!any) any = await tabs.first.state.restoreAutosave();
    _persist();
    return any;
  }

  /// Test hook: collapse back to one blank tab.
  @visibleForTesting
  void reset() {
    tabs
      ..clear()
      ..add(ProjectSession(0));
    _active = 0;
    _nextId = 1;
    docTemplates
      ..clear()
      ..addAll(builtinDocTemplates());
    _templatesLoaded = false;
  }

  // ---------- document templates (app-wide office assets) ----------

  /// The template library: DepEd/Private built-ins plus the user's
  /// saved templates. Shared across tabs — the document identity is an
  /// office asset, not per-project data. Customs persist in
  /// <datadir>/doc_templates.json and also embed into each .boqproj so
  /// a shared file keeps its look on another machine.
  final List<DocTemplate> docTemplates = builtinDocTemplates();
  bool _templatesLoaded = false;

  static File get _templateFile => File(
    '${_dir.path}${Platform.pathSeparator}doc_templates.json',
  );

  /// Load the persisted library once (called from [restore]; also
  /// lazily before any template mutation so a plain session still
  /// picks up saved templates).
  Future<void> loadTemplates() async {
    if (_templatesLoaded) return;
    _templatesLoaded = true;
    try {
      final j = jsonDecode(await _templateFile.readAsString());
      mergeTemplates(j['templates'] as List? ?? const []);
    } catch (_) {}
  }

  /// Merge serialized templates into the library: builtin ids refresh
  /// that template's content in place (user edits to the stock office
  /// identity carry across restarts); unknown ids append as customs.
  void mergeTemplates(List items) {
    for (final raw in items) {
      final t = DocTemplate.fromJson(
        Map<String, dynamic>.from(raw as Map),
      );
      final i = docTemplates.indexWhere((x) => x.id == t.id);
      if (i < 0) {
        docTemplates.add(t);
      } else {
        final keep = docTemplates[i].builtin;
        t.builtin = keep;
        docTemplates[i] = t;
      }
    }
  }

  void persistTemplates() {
    unawaited(() async {
      try {
        final f = _templateFile;
        await f.parent.create(recursive: true);
        await f.writeAsString(
          jsonEncode({
            'templates': [
              // builtin edits persist too — the user's signatory/letterhead
              // tweaks are office assets like the price db
              for (final t in docTemplates) t.toJson(),
            ],
          }),
        );
      } catch (_) {}
    }());
  }

  /// The app's data dir — %APPDATA%\ConstructionEstimate (temp
  /// fallback). [dataDirOverride] redirects it so tests never read the
  /// developer's real sessions.json / autosave files — without it a
  /// pumped app restores the actual project mid-test.
  @visibleForTesting
  static Directory? dataDirOverride;
  static Directory get _dir =>
      dataDirOverride ??
      Directory(
        '${Platform.environment['APPDATA'] ?? Directory.systemTemp.path}'
        '${Platform.pathSeparator}ConstructionEstimate',
      );

  /// The open-tab manifest — just ids + the active index; each tab's
  /// real data lives in its own `autosave-<id>.boqproj`.
  static File get _manifest =>
      File('${_dir.path}${Platform.pathSeparator}sessions.json');

  void _persist() {
    if (!autosave) return;
    unawaited(() async {
      try {
        final f = _manifest;
        await f.parent.create(recursive: true);
        await f.writeAsString(
          jsonEncode({
            'active': _active,
            'tabs': [for (final t in tabs) t.id],
          }),
        );
      } catch (_) {}
    }());
  }
}
