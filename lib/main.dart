import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import 'docx_export.dart';
import 'excel_export.dart';
import 'export_package.dart';
import 'model3d.dart' show preloadBlockMeshes;
import 'open_file.dart';
import 'models.dart';
import 'pdf_export.dart';
import 'state.dart';
import 'ui/carabao_logo.dart';
import 'ui/design_view.dart';
import 'ui/drawing_view.dart';
import 'ui/extension_view.dart';
import 'ui/labor_dialog.dart';
import 'ui/manage_view.dart';
import 'ui/model_view.dart';
import 'ui/pow_view.dart';
import 'ui/pricing_page.dart';
import 'ui/schedule_view.dart';
import 'ui/sheet_view.dart';
import 'ui/template_dialog.dart';
import 'ui/theme_dialog.dart';
import 'ui/work_panel.dart';
part 'ui/project_tab_strip.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Pick up the rolling autosave (every edit on any tab is debounced
  // into it), then enable the writer. Fresh installs fall through to
  // the defaults with the bundled DepEd seal.
  // Restore every open project tab from the manifest + per-tab
  // rolling autosaves (pre-tabs builds fall back to the single
  // autosave.boqproj as tab 0). Fresh installs get the DepEd seal.
  projectTabs.autosave = true;
  final restored = await projectTabs.restore();
  if (!restored) {
    try {
      est.project.logoB64 ??= base64Encode(
        (await rootBundle.load('assets/deped_logo.png')).buffer.asUint8List(),
      );
    } catch (_) {}
  }
  est.autosaveEnabled = true;
  // Bundled Kenney CC0 furniture meshes — loaded once so every placed
  // CAD block renders its real 3D object instead of a plain prism.
  await preloadBlockMeshes(rootBundle.loadString);
  runApp(const BoqApp());
}

class BoqApp extends StatelessWidget {
  const BoqApp({super.key});

  @override
  Widget build(BuildContext context) {
    // Rebuild the MaterialApp theme when the accent color changes —
    // or when the active project tab switches to another theme
    return ListenableBuilder(
      listenable: Listenable.merge([est, projectTabs]),
      builder: (context, _) {
        final brand = Color(est.project.themeColor);
        return MaterialApp(
          title: 'Tantyahin',
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            useMaterial3: true,
            colorScheme: ColorScheme.fromSeed(
              seedColor: brand,
              primary: brand,
              surface: Colors.white,
            ),
            scaffoldBackgroundColor: const Color(0xFFEEF1F6),
            cardTheme: CardThemeData(
              color: Colors.white,
              elevation: 0,
              margin: EdgeInsets.zero,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: const BorderSide(color: Color(0xFFE2E8F0)),
              ),
            ),
            inputDecorationTheme: InputDecorationTheme(
              isDense: true,
              filled: true,
              fillColor: const Color(0xFFF8FAFC),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: Color(0xFFCBD5E1)),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 10,
                vertical: 9,
              ),
            ),
            dividerTheme: const DividerThemeData(
              color: Color(0xFFE2E8F0),
              thickness: 1,
            ),
          ),
          home: const HomePage(),
        );
      },
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  /// The view tab lives on the session so each project tab remembers
  /// which view it was on.
  int get _tab => projectTabs.active.viewTab;
  set _tab(int v) => projectTabs.active.viewTab = v;

  /// Per-session keys: the drawing canvas and work inspector keep
  /// their State when REPARENTED between layouts (GlobalKey is the
  /// only key that reparents), and a different project tab gets a
  /// different GlobalKey → fresh State — otherwise a session would
  /// inherit another project's loaded PDFs and selections.
  final _drawingKeys = <int, GlobalKey>{};
  final _panelKeys = <int, GlobalKey>{};
  Key get _drawingKey =>
      _drawingKeys.putIfAbsent(projectTabs.active.id, GlobalKey.new);
  Key get _panelKey =>
      _panelKeys.putIfAbsent(projectTabs.active.id, GlobalKey.new);

  /// BOQ pane width as a fraction of the focus-mode split area —
  /// adjusted by dragging the divider between drawing and sheet.
  double _boqFrac = 0.42;

  Widget get _sheet => switch (_tab) {
    0 => const SheetView(),
    1 => const PowView(),
    2 => DrawingView(key: _drawingKey),
    3 => const ModelView(),
    4 => const DesignView(),
    5 => const ScheduleView(),
    6 => const ManageView(),
    _ => const ExtensionView(),
  };

  Future<void> _export(BuildContext context, String fmt) async {
    if (est.sections.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Nothing to export yet — add work items first.'),
        ),
      );
      return;
    }
    final base = est.project.title.isEmpty ? 'estimate' : est.project.title;
    final loc = await getSaveLocation(
      suggestedName: '$base.$fmt',
      acceptedTypeGroups: [
        XTypeGroup(
          label: switch (fmt) {
            'xlsx' => 'Excel Workbook',
            'pdf' => 'PDF Document',
            'zip' => 'Complete Package',
            _ => 'Word Document',
          },
          extensions: [fmt],
        ),
      ],
    );
    if (loc == null) return;
    List<int>? bytes;
    switch (fmt) {
      case 'xlsx':
        List<int>? logo;
        final b64 = est.project.effLogo;
        if (b64 != null) {
          try {
            logo = base64Decode(b64);
          } catch (_) {}
        }
        bytes = await ExcelExport(est).build(logoBytes: logo);
      case 'pdf':
        bytes = await PdfExport(est).build();
      case 'docx':
        bytes = await DocxExport.buildEstimate();
      case 'zip':
        bytes = await ExportPackage.buildZip(est);
    }
    if (bytes == null) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Export failed.')));
      }
      return;
    }
    await File(loc.path).writeAsBytes(bytes);
    unawaited(openExportedFile(loc.path));
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Saved ${loc.path}')));
    }
  }

  /// DRAWINGS focus mode: the tab strip is hidden and the screen
  /// splits into [drawing canvas | draggable divider | BOQ sheet |
  /// insert-work inspector] so the estimate can be edited while
  /// inspecting the plan. Esc exits.
  Widget _focusLayout() => CallbackShortcuts(
    bindings: {
      const SingleActivator(LogicalKeyboardKey.escape): () =>
          est.setDrawingFocus(false),
    },
    child: Focus(
      autofocus: true,
      child: LayoutBuilder(
        builder: (context, c) {
          const panelW = 380.0, divW = 10.0;
          final avail = (c.maxWidth - panelW - divW).clamp(160.0, 1e9);
          final boqW = (avail * _boqFrac).clamp(240.0, avail - 280.0);
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: avail - boqW,
                child: DrawingView(key: _drawingKey),
              ),
              MouseRegion(
                cursor: SystemMouseCursors.resizeColumn,
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onHorizontalDragUpdate: (d) => setState(
                    () => _boqFrac = (_boqFrac - d.delta.dx / avail).clamp(
                      0.25,
                      0.75,
                    ),
                  ),
                  child: Container(
                    width: divW,
                    color: const Color(0xFFE2E8F0),
                    child: const Center(
                      child: Icon(
                        Icons.drag_indicator,
                        size: 13,
                        color: Color(0xFF94A3B8),
                      ),
                    ),
                  ),
                ),
              ),
              SizedBox(width: boqW, child: const SheetView()),
              SizedBox(
                width: panelW,
                child: WorkPanel(key: _panelKey, est: est),
              ),
            ],
          );
        },
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: ListenableBuilder(
        listenable: Listenable.merge([est, projectTabs]),
        builder: (context, _) {
          return Column(
            children: [
              _TopBar(onExport: (fmt) => _export(context, fmt)),
              // NOT const — a canonicalized const instance short-circuits
              // the element update (child.widget == newWidget) and the
              // strip would never rebuild when tabs change
              _ProjectTabs(),
              if (!est.drawingFocus)
                _ViewTabs(
                  current: _tab,
                  onChanged: (i) => setState(() => _tab = i),
                ),
              Expanded(
                child: est.drawingFocus
                    ? _focusLayout()
                    : LayoutBuilder(
                        builder: (context, c) {
                          // SCHEDULE / MANAGEMENT / EXTENSION take the
                          // full width — the insert-work inspector stays
                          // visible on BOQ, POW and DRAWINGS so the user
                          // can add estimate items while inspecting the
                          // plan.
                          if (_tab >= 3) {
                            return _sheet;
                          }
                          // Wide: sheet left + inspector right.
                          // Narrow: inspector drops BELOW the sheet so
                          // nothing clips.
                          if (c.maxWidth >= 1000) {
                            return Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(flex: 7, child: _sheet),
                                SizedBox(
                                  width: c.maxWidth >= 1280
                                      ? 430
                                      : (c.maxWidth * 0.34).clamp(340.0, 430.0),
                                  child: WorkPanel(key: _panelKey, est: est),
                                ),
                              ],
                            );
                          }
                          return Column(
                            children: [
                              Expanded(child: _sheet),
                              SizedBox(
                                height: (c.maxHeight * 0.52).clamp(
                                  320.0,
                                  560.0,
                                ),
                                child: WorkPanel(key: _panelKey, est: est),
                              ),
                            ],
                          );
                        },
                      ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  final void Function(String fmt) onExport;
  const _TopBar({required this.onExport});

  /// Open a .boqproj in a NEW project tab. If that file is already
  /// open in another tab, just switch to it instead of duplicating.
  Future<void> _openProjectTab(BuildContext context) async {
    final s = projectTabs.newTab(activate: false, inheritOffice: false);
    try {
      final path = await s.state.openProject();
      if (path == null) {
        projectTabs.close(s); // cancelled picker — drop the blank tab
        return;
      }
      final dup = projectTabs.tabs.indexWhere(
        (t) => !identical(t, s) && t.state.savedPath == path,
      );
      if (dup >= 0) {
        projectTabs.close(s);
        projectTabs.activateIndex(dup);
      } else {
        projectTabs.activate(s);
      }
    } catch (e) {
      projectTabs.close(s);
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Open failed: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 64,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(bottom: BorderSide(color: Color(0xFFE2E8F0))),
      ),
      child: LayoutBuilder(
        builder: (context, c) {
          final labels = c.maxWidth >= 1240;
          final subtitle = c.maxWidth >= 1560;
          final chipVisible = c.maxWidth >= 980;
          return Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: kCarabaoPink.withValues(alpha: .28),
                      blurRadius: 8,
                      offset: const Offset(0, 3),
                    ),
                  ],
                ),
                child: const CarabaoLogo(size: 38),
              ),
              const SizedBox(width: 12),
              Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Tantyahin',
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 15,
                      letterSpacing: -.2,
                    ),
                  ),
                  if (subtitle)
                    const Text(
                      'Bill of Quantities & Program of Works',
                      style: TextStyle(fontSize: 11, color: Color(0xFF64748B)),
                    ),
                ],
              ),
              if (chipVisible) ...[
                const SizedBox(width: 18),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 300),
                  child: ListenableBuilder(
                    listenable: est,
                    builder: (_, _) => _ProjectChip(),
                  ),
                ),
              ],
              // Actions are pinned to the FAR RIGHT; if the window is ever
              // too narrow the cluster scales down instead of clipping.
              Expanded(
                child: Align(
                  alignment: Alignment.centerRight,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerRight,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _BarGroup(
                          children: [
                            _BarButton(
                              icon: Icons.note_add_outlined,
                              label: labels ? 'New' : null,
                              tooltip: 'New project tab',
                              onTap: () => projectTabs.newTab(),
                            ),
                            _BarButton(
                              icon: Icons.folder_open_outlined,
                              label: labels ? 'Open' : null,
                              tooltip: 'Open project in a new tab',
                              onTap: () => _openProjectTab(context),
                            ),
                            _BarButton(
                              icon: Icons.save_outlined,
                              label: labels ? 'Save' : null,
                              tooltip: 'Save project',
                              onTap: () async {
                                await est.saveProject();
                              },
                            ),
                          ],
                        ),
                        const SizedBox(width: 10),
                        // NOT const — it reads est.project.template in
                        // build; a canonicalized instance would never
                        // rebuild (the _ProjectTabs trap)
                        ListenableBuilder(
                          listenable: est,
                          builder: (_, _) => const TemplateButton(),
                        ),
                        const SizedBox(width: 10),
                        _BarGroup(
                          children: [
                            _BarButton(
                              icon: Icons.sell_outlined,
                              label: labels ? 'Pricing' : null,
                              tooltip: 'Price database',
                              onTap: () => Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => const PricingPage(),
                                ),
                              ),
                            ),
                            _BarButton(
                              icon: Icons.engineering_outlined,
                              label: labels ? 'Labor' : null,
                              tooltip: 'Labor cost rate',
                              onTap: () => showLaborDialog(context),
                            ),
                            _BarButton(
                              icon: Icons.palette_outlined,
                              label: labels ? 'Colors' : null,
                              tooltip: 'Sheet colors',
                              onTap: () => showThemeDialog(context),
                            ),
                          ],
                        ),
                        const SizedBox(width: 12),
                        _ExportMenu(onExport: onExport),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Segmented pill that groups related toolbar buttons.
class _BarGroup extends StatelessWidget {
  final List<Widget> children;
  const _BarGroup({required this.children});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(3),
    decoration: BoxDecoration(
      color: const Color(0xFFF1F5F9),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: const Color(0xFFE2E8F0)),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0) const SizedBox(width: 2),
          children[i],
        ],
      ],
    ),
  );
}

/// Flat toolbar button: icon + label, white lift on hover.
class _BarButton extends StatefulWidget {
  final IconData icon;
  final String? label;
  final String tooltip;
  final VoidCallback onTap;
  const _BarButton({
    required this.icon,
    this.label,
    required this.tooltip,
    required this.onTap,
  });

  @override
  State<_BarButton> createState() => _BarButtonState();
}

class _BarButtonState extends State<_BarButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Tooltip(
      message: widget.tooltip,
      waitDuration: const Duration(milliseconds: 350),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            height: 34,
            padding: EdgeInsets.symmetric(
              horizontal: widget.label == null ? 10 : 12,
            ),
            decoration: BoxDecoration(
              color: _hover ? Colors.white : Colors.transparent,
              borderRadius: BorderRadius.circular(9),
              boxShadow: _hover
                  ? const [
                      BoxShadow(
                        color: Color(0x1A0F172A),
                        blurRadius: 6,
                        offset: Offset(0, 2),
                      ),
                    ]
                  : null,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  widget.icon,
                  size: 18,
                  color: _hover ? cs.primary : const Color(0xFF475569),
                ),
                if (widget.label != null) ...[
                  const SizedBox(width: 7),
                  Text(
                    widget.label!,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: _hover ? cs.primary : const Color(0xFF334155),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Primary "Export" button with a format menu — always the rightmost
/// control. Excel is the full workbook; PDF/DOCX mirror its layout.
class _ExportMenu extends StatelessWidget {
  final void Function(String fmt) onExport;
  const _ExportMenu({required this.onExport});

  MenuItemButton _item(
    IconData icon,
    Color tint,
    String title,
    String sub,
    String fmt,
  ) {
    return MenuItemButton(
      onPressed: () => onExport(fmt),
      style: ButtonStyle(
        minimumSize: const WidgetStatePropertyAll(Size(270, 52)),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        ),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: tint.withValues(alpha: .12),
              borderRadius: BorderRadius.circular(9),
            ),
            child: Icon(icon, size: 19, color: tint),
          ),
          const SizedBox(width: 12),
          Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                ),
              ),
              Text(
                sub,
                style: const TextStyle(fontSize: 11, color: Color(0xFF64748B)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MenuAnchor(
      alignmentOffset: const Offset(0, 6),
      style: MenuStyle(
        backgroundColor: const WidgetStatePropertyAll(Colors.white),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        elevation: const WidgetStatePropertyAll(10),
        padding: const WidgetStatePropertyAll(EdgeInsets.all(6)),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: const BorderSide(color: Color(0xFFE2E8F0)),
          ),
        ),
      ),
      menuChildren: [
        _item(
          Icons.grid_on,
          const Color(0xFF16A34A),
          'Excel workbook (.xlsx)',
          'Editable sheets with live formulas',
          'xlsx',
        ),
        _item(
          Icons.picture_as_pdf_outlined,
          const Color(0xFFDC2626),
          'PDF document (.pdf)',
          'Print-ready, same layout as Excel',
          'pdf',
        ),
        _item(
          Icons.description_outlined,
          const Color(0xFF2563EB),
          'Word document (.docx)',
          'Editable report, same layout',
          'docx',
        ),
        _item(
          Icons.folder_zip_outlined,
          const Color(0xFF7C3AED),
          'Complete package (.zip)',
          'Workbook + PDF + drawings + project file',
          'zip',
        ),
      ],
      builder: (context, ctl, _) => FilledButton(
        onPressed: () => ctl.isOpen ? ctl.close() : ctl.open(),
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, 40),
          padding: const EdgeInsets.fromLTRB(16, 0, 10, 0),
          elevation: 2,
          shadowColor: Theme.of(context).colorScheme.primary,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(11),
          ),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.ios_share_rounded, size: 18),
            SizedBox(width: 8),
            Text(
              'Export',
              style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
            ),
            SizedBox(width: 4),
            Icon(Icons.keyboard_arrow_down_rounded, size: 20),
          ],
        ),
      ),
    );
  }
}

/// BOQ | POW tab strip between the top bar and the sheet area.
class _ViewTabs extends StatelessWidget {
  final int current;
  final ValueChanged<int> onChanged;
  const _ViewTabs({required this.current, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    Widget tab(int i, IconData icon, String label) {
      final sel = current == i;
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 7),
        child: InkWell(
          onTap: () => onChanged(i),
          borderRadius: BorderRadius.circular(7),
          child: ListenableBuilder(
            listenable: est,
            builder: (_, _) => AnimatedContainer(
              duration: const Duration(milliseconds: 140),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              decoration: BoxDecoration(
                color: sel ? Color(est.project.themeColor) : Colors.transparent,
                borderRadius: BorderRadius.circular(7),
              ),
              child: Row(
                children: [
                  Icon(
                    icon,
                    size: 15,
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
        ),
      );
    }

    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(bottom: BorderSide(color: Color(0xFFE2E8F0))),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            tab(0, Icons.table_rows_outlined, 'BOQ'),
            tab(1, Icons.fact_check_outlined, 'POW'),
            tab(2, Icons.design_services_outlined, 'DRAWINGS'),
            tab(3, Icons.view_in_ar_outlined, '3D MODEL'),
            tab(4, Icons.calculate_outlined, 'DESIGN CALC'),
            tab(5, Icons.event_note_outlined, 'PROJECT SCHEDULE'),
            tab(6, Icons.assignment_ind_outlined, 'PROJECT MANAGEMENT'),
            tab(7, Icons.description_outlined, 'EXTENSION'),
          ],
        ),
      ),
    );
  }
}

class _ProjectChip extends StatefulWidget {
  @override
  State<_ProjectChip> createState() => _ProjectChipState();
}

class _ProjectChipState extends State<_ProjectChip> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final p = est.project;
    final cs = Theme.of(context).colorScheme;
    // tap = project details dialog
    return Tooltip(
      message: 'Project details',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: () => showDialog(
            context: context,
            builder: (_) => ProjectDialog(project: p),
          ),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            height: 38,
            padding: const EdgeInsets.fromLTRB(6, 0, 12, 0),
            decoration: BoxDecoration(
              color: _hover ? Colors.white : const Color(0xFFF8FAFC),
              borderRadius: BorderRadius.circular(19),
              border: Border.all(
                color: _hover
                    ? cs.primary.withValues(alpha: .5)
                    : const Color(0xFFE2E8F0),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 26,
                  height: 26,
                  decoration: BoxDecoration(
                    color: cs.primary.withValues(alpha: .12),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(Icons.apartment, size: 15, color: cs.primary),
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    p.title.isEmpty ? 'Untitled project' : p.title,
                    style: const TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 6),
                const Icon(
                  Icons.more_horiz,
                  size: 14,
                  color: Color(0xFF94A3B8),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Project details dialog. Signatories are edited on the sheet itself
/// (click to edit, right-click to delete, "Add signatory" to append).
class ProjectDialog extends StatefulWidget {
  final ProjectInfo project;
  const ProjectDialog({super.key, required this.project});

  @override
  State<ProjectDialog> createState() => _ProjectDialogState();
}

class _ProjectDialogState extends State<ProjectDialog> {
  late final Map<String, TextEditingController> c;

  @override
  void initState() {
    super.initState();
    final p = widget.project;
    c = {
      'title': TextEditingController(text: p.title),
      'location': TextEditingController(text: p.location),
      'division': TextEditingController(text: p.division),
      'cd': TextEditingController(text: p.contractDuration),
      'unwork': TextEditingController(text: '${p.unworkableDays}'),
      'fund': TextEditingController(text: p.sourceOfFund),
      'target': TextEditingController(text: p.physicalTarget),
    };
  }

  @override
  void dispose() {
    for (final x in c.values) {
      x.dispose();
    }
    super.dispose();
  }

  Widget _f(String label, String key) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: TextField(
      controller: c[key],
      decoration: InputDecoration(labelText: label),
    ),
  );

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Project Details'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            children: [
              _f('Project title', 'title'),
              _f('Location', 'location'),
              _f('Division', 'division'),
              Row(
                children: [
                  Expanded(child: _f('Contract duration', 'cd')),
                  const SizedBox(width: 10),
                  Expanded(child: _f('Unworkable days (weather)', 'unwork')),
                ],
              ),
              Row(
                children: [
                  Expanded(child: _f('Source of fund', 'fund')),
                  const SizedBox(width: 10),
                  Expanded(child: _f('Physical target', 'target')),
                ],
              ),
              const Divider(height: 24),
              const Text(
                'Signatories are edited on the sheet — click one to edit, '
                'right-click to delete, or use "Add signatory".',
                style: TextStyle(fontSize: 11, color: Color(0xFF64748B)),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            final p = widget.project;
            p.title = c['title']!.text;
            p.location = c['location']!.text;
            p.division = c['division']!.text;
            p.contractDuration = c['cd']!.text;
            final u = int.tryParse(c['unwork']!.text);
            if (u != null && u >= 0 && u <= 3650) {
              p.unworkableDays = u;
            }
            p.sourceOfFund = c['fund']!.text;
            p.physicalTarget = c['target']!.text;
            est.update();
            est.syncSchedule();
            Navigator.pop(context);
          },
          child: const Text('Apply'),
        ),
      ],
    );
  }
}

final moneyFmt = NumberFormat('#,##0.00');
final qtyFmt = NumberFormat('#,##0.##');
