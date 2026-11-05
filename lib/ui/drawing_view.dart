import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pdfx/pdfx.dart';

import '../dxf.dart';
import '../dwg.dart';
import '../model3d.dart';
import '../models.dart';
import '../state.dart';

/// DRAWINGS tab: open image / PDF / DXF files into a library, view them
/// with wheel + button zoom & pan, and annotate them with pen, marker,
/// arrow, rect and text marks. Files live in `est.drawings` (paths) and
/// annotations in `est.marks` — both autosaved with the project.
class DrawingView extends StatefulWidget {
  const DrawingView({super.key});

  @override
  State<DrawingView> createState() => _DrawingViewState();
}

enum _Tool {
  pan,
  select,
  pen,
  hi,
  arrow,
  rect,
  text,
  measure,
  eraser,
  sheet,
}

class _FileCache {
  ui.Image? image; // image kind / rendered pdf page
  PdfDocument? doc; // pdf (kept open while selected)
  final Map<int, ui.Image> pdfPages = {};
  DxfScene? scene;
  Size? size; // natural content size
  String? error;
  bool missing = false;
  bool loading = false;
  bool fitted = false;

  /// The file was removed from the library while a load was still in
  /// flight — its native doc must not be touched again.
  bool retired = false;
}

class _DrawingViewState extends State<DrawingView> {
  final Map<String, _FileCache> _caches = {};
  String? _selId;
  int _page = 0;
  _Tool _tool = _Tool.pan;
  Offset? _midPan;
  DateTime? _midTap;

  /// Currently selected mark (adjust mode): drag handles to reshape,
  /// drag the body to move it, click empty space to release it.
  DrawingMark? _selMark;

  /// -2 = idle, -1 = moving the whole mark; otherwise the handle index
  /// from [_handlesFor].
  int _selHandle = -2;
  Offset? _dragLast;
  MouseCursor _cursor = MouseCursor.defer;
  Offset _lastHover = Offset.zero;

  /// Inline text-note editor: position (normalized), controller and
  /// the mark being edited (null = new note). No popup — typing lands
  /// straight on the canvas.
  Offset? _textAt2;
  TextEditingController? _textCtrl;
  final _textFocus = FocusNode();
  DrawingMark? _textMark;

  /// Keyboard focus for the single-letter tool shortcuts — grabbed by
  /// the canvas on pointer-down so keys only act while the drawing
  /// area was last interacted with.
  final _keyFocus = FocusNode();
  final _colorMenuKey = GlobalKey<PopupMenuButtonState<int>>();
  final _widthMenuKey = GlobalKey<PopupMenuButtonState<double>>();

  /// Pending measurement reference: the drawn line waiting for its
  /// real length. Non-null while the inline ref editor is open.
  List<double>? _refLine;
  TextEditingController? _refCtrl;
  final _refFocus = FocusNode();
  String _refUnit = 'mm';

  /// Inline editor for the generated sheet's project-title cell —
  /// typing lands straight in the cell at sheet scale and live-writes
  /// `project.title`; a corner drag handle resizes `project.titleSize`
  /// (mm). The pre-edit values snapshot lets Esc revert both.
  bool _titleEdit = false;
  String? _titleBefore;
  double? _titleSizeBefore;
  TextEditingController? _titleCtrl;
  final _titleFocus = FocusNode();
  int _markColor = 0xFFD32F2F;
  double _markWidth = 3;
  DrawingMark? _active;
  final _tc = TransformationController();
  Size _viewport = Size.zero;

  DrawingFile? get _sel {
    for (final f in est.drawings) {
      if (f.id == _selId) return f;
    }
    return est.drawings.isEmpty ? null : est.drawings.first;
  }

  /// Generated sheets carry `sheet:{modelId}:{slug}` ids — resolve them
  /// back to the model + SheetView so the "move sheet" drag can pan the
  /// drawing inside its paper frame and rewrite the DXF.
  static const _sheetViews = {
    'floorplan': SheetView.plan,
    'structural': SheetView.structural,
    'roofframe': SheetView.roofFrame,
    'electrical': SheetView.electrical,
    'plumbing': SheetView.plumbing,
    'roofplan': SheetView.roof,
    'front': SheetView.front,
    'rear': SheetView.rear,
    'left': SheetView.left,
    'right': SheetView.right,
  };

  (Model3d, SheetView)? _sheetTarget(DrawingFile f) {
    final p = f.id.split(':');
    if (p.length != 3 || p[0] != 'sheet') return null;
    final v = _sheetViews[p[2]];
    if (v == null) return null;
    for (final m in est.models) {
      if (m.id == p[1]) return (m, v);
    }
    return null;
  }

  Timer? _sheetRegen;
  Model3d? _sheetDragModel;
  SheetView? _sheetDragView;

  /// Regenerate the sheet's DXF with the current stored pan and swap the
  /// parsed scene in place — the camera matrix (est.drawingXfms) is
  /// untouched, so the paper stays put while the drawing slides.
  void _writeSheet(DrawingFile f) {
    final t = _sheetTarget(f);
    if (t == null) return;
    try {
      final src = buildModelSheet(
        t.$1,
        t.$2,
        paper: est.sheetPaper,
        landscape: est.sheetLandscape,
        project: est.project,
      );
      File(f.path).writeAsStringSync(src);
      final c = _cache(f.id);
      c.scene = DxfParser.parse(src);
      c.size = c.scene!.naturalSize();
      if (mounted) setState(() {});
    } catch (_) {}
  }

  /// Drag a generated sheet's drawing inside its paper frame — the
  /// AutoCAD viewport-pan gesture. Screen px -> sheet mm via the scene's
  /// px/mm factor and the current zoom; Y flips (screen-down is paper -Y).
  void _sheetDragUpdate(DrawingFile f, Offset delta) {
    final c = _cache(f.id);
    final sc = c.scene, s = c.size;
    if (sc == null || s == null || sc.bounds.width <= 0) return;
    final upm = s.width / sc.bounds.width;
    final z = _tc.value.getMaxScaleOnAxis();
    final dmm = Offset(
      delta.dx / (z * upm),
      -delta.dy / (z * upm),
    );
    final key = _sheetDragView!.name;
    _sheetDragModel!.sheetPan[key] =
        (_sheetDragModel!.sheetPan[key] ?? Offset.zero) + dmm;
    // regen throttled — the file write + reparse is the live preview
    _sheetRegen?.cancel();
    _sheetRegen = Timer(
      const Duration(milliseconds: 90),
      () => _writeSheet(f),
    );
  }

  /// Drag released: flush the pending regen, persist the new pan into
  /// the project (autosave writes model.sheetPan), clear the drag.
  void _sheetDragEnd() {
    final f = _sel;
    _sheetRegen?.cancel();
    _sheetRegen = null;
    if (f != null && _sheetDragModel != null) _writeSheet(f);
    _sheetDragModel = null;
    _sheetDragView = null;
    est.update();
  }

  _FileCache _cache(String id) => _caches.putIfAbsent(id, _FileCache.new);

  /// Set in dispose(): async loads (pdfium getPage/render run on a
  /// background isolate) may still be in flight — touching their
  /// handles after the widget dies crashes the process natively, so
  /// docs stay open until the last pending op finishes.
  bool _dead = false;
  int _inFlight = 0;

  /// Caches whose file was deleted while ops may still be pending —
  /// their docs close once the view is quiescent.
  final List<_FileCache> _retired = [];

  @override
  void initState() {
    super.initState();
    // keep the zoom/pan matrix in est so it survives the widget being
    // recreated on every tab switch
    _tc.addListener(_saveXfm);
  }

  @override
  void dispose() {
    _dead = true;
    _textCtrl?.dispose();
    _textFocus.dispose();
    _refCtrl?.dispose();
    _refFocus.dispose();
    _titleCtrl?.dispose();
    _titleFocus.dispose();
    _keyFocus.dispose();
    _closeDocsWhenIdle();
    _tc.dispose();
    super.dispose();
  }

  // ---------- keyboard shortcuts ----------

  void _setTool(_Tool t) => setState(() => _tool = t);

  /// Esc — CAD-style cancel, deepest first: open editors ->
  /// selected/in-progress mark -> active tool -> exit focus mode.
  void _esc() {
    if (_titleEdit) {
      _cancelTitle();
      return;
    }
    if (_refLine != null) {
      _cancelRef();
      return;
    }
    if (_textAt2 != null) {
      _textCtrl?.dispose();
      _textCtrl = null;
      setState(() {
        _textAt2 = null;
        _textMark = null;
      });
      return;
    }
    if (_selMark != null || _active != null) {
      setState(() {
        _selMark = null;
        _selHandle = -2;
        _active = null;
      });
      return;
    }
    if (_tool != _Tool.pan) {
      _setTool(_Tool.pan);
      return;
    }
    if (est.drawingFocus) est.setDrawingFocus(false);
  }

  void _undoMark() {
    final f = _sel;
    if (f != null) est.undoMark(f.id, _page);
  }

  void _redoMark() {
    final f = _sel;
    if (f != null) est.redoMark(f.id, _page);
  }

  /// Keys that must stay inert while an inline editor is open — the
  /// field owns character keys anyway, this guards Ctrl+Z and the rest.
  VoidCallback _keyAction(VoidCallback fn) => () {
    if (_textAt2 == null && _refLine == null && !_titleEdit) fn();
  };

  Map<ShortcutActivator, VoidCallback> get _shortcuts => {
    const SingleActivator(LogicalKeyboardKey.escape): _esc,
    const SingleActivator(LogicalKeyboardKey.keyA): _keyAction(
      () => _setTool(_Tool.select),
    ),
    const SingleActivator(LogicalKeyboardKey.keyV): _keyAction(
      () => _setTool(_Tool.pan),
    ),
    const SingleActivator(LogicalKeyboardKey.keyP): _keyAction(
      () => _setTool(_Tool.pen),
    ),
    const SingleActivator(LogicalKeyboardKey.keyH): _keyAction(
      () => _setTool(_Tool.hi),
    ),
    const SingleActivator(LogicalKeyboardKey.keyB): _keyAction(
      () => _setTool(_Tool.arrow),
    ),
    const SingleActivator(LogicalKeyboardKey.keyR): _keyAction(
      () => _setTool(_Tool.rect),
    ),
    const SingleActivator(LogicalKeyboardKey.keyT): _keyAction(
      () => _setTool(_Tool.text),
    ),
    const SingleActivator(LogicalKeyboardKey.keyM): _keyAction(
      () => _setTool(_Tool.measure),
    ),
    const SingleActivator(LogicalKeyboardKey.keyE): _keyAction(
      () => _setTool(_Tool.eraser),
    ),
    const SingleActivator(LogicalKeyboardKey.keyC): _keyAction(
      () => _colorMenuKey.currentState?.showButtonMenu(),
    ),
    const SingleActivator(LogicalKeyboardKey.keyS): _keyAction(
      () => _widthMenuKey.currentState?.showButtonMenu(),
    ),
    const SingleActivator(LogicalKeyboardKey.keyZ, control: true): _keyAction(
      _undoMark,
    ),
    const SingleActivator(LogicalKeyboardKey.keyY, control: true): _keyAction(
      _redoMark,
    ),
    const SingleActivator(LogicalKeyboardKey.keyR, control: true): _keyAction(
      _redoMark,
    ),
  };

  /// Close pdf documents only once no native op is using them; called
  /// from dispose(), on file deletion, and at the end of every
  /// guarded async op.
  void _closeDocsWhenIdle() {
    if (_inFlight != 0) return;
    if (_dead) {
      for (final c in _caches.values) {
        c.doc?.close();
        c.doc = null;
      }
    }
    for (final c in _retired) {
      c.doc?.close();
      c.doc = null;
    }
    _retired.clear();
  }

  /// Run [op] counted as an in-flight native/async operation. Returns
  /// null when the view was disposed before it finished.
  Future<T?> _guard<T>(Future<T> Function() op) async {
    _inFlight++;
    try {
      return await op();
    } finally {
      _inFlight--;
      _closeDocsWhenIdle();
    }
  }

  /// 'fileId:page' key under which this view's matrix is remembered.
  String get _viewKey {
    final f = _sel;
    return f == null ? '' : '${f.id}:$_page';
  }

  void _saveXfm() {
    final k = _viewKey;
    if (k.isEmpty) return;
    est.drawingXfms[k] = List<double>.of(_tc.value.storage);
  }

  /// Restore the remembered zoom/pan for this file+page, or fit the
  /// sheet to the viewport the first time it is opened.
  void _fitOrRestore() {
    final saved = est.drawingXfms[_viewKey];
    if (saved != null && saved.length == 16) {
      _tc.value = Matrix4.fromList(saved);
      return;
    }
    _fit();
  }

  // ---------- opening files ----------

  static const _imgExt = {'png', 'jpg', 'jpeg', 'gif', 'bmp', 'webp'};

  Future<void> _open() async {
    final files = await openFiles(
      acceptedTypeGroups: [
        const XTypeGroup(
          label: 'Drawings',
          extensions: [
            'png',
            'jpg',
            'jpeg',
            'gif',
            'bmp',
            'webp',
            'pdf',
            'dxf',
            'dwg',
          ],
        ),
        const XTypeGroup(
          label: 'Images',
          extensions: ['png', 'jpg', 'jpeg', 'gif', 'bmp', 'webp'],
        ),
        const XTypeGroup(label: 'PDF', extensions: ['pdf']),
        const XTypeGroup(label: 'CAD drawing', extensions: ['dxf', 'dwg']),
      ],
    );
    if (files.isEmpty) return;
    for (final f in files) {
      final ext = f.path.split('.').last.toLowerCase();
      var kind = 'image';
      if (ext == 'pdf') kind = 'pdf';
      if (ext == 'dxf') kind = 'dxf';
      if (ext == 'dwg') kind = 'dwg';
      if (!_imgExt.contains(ext) &&
          ext != 'pdf' &&
          ext != 'dxf' &&
          ext != 'dwg') {
        continue;
      }
      final df = est.addDrawing(f.path, kind);
      _selId = df.id;
      _page = 0;
      _load(df); // fire & forget; setStates internally
    }
    setState(() {});
  }

  Future<void> _load(DrawingFile f) => _guard(() async {
    final c = _cache(f.id);
    if (c.loading || c.size != null || c.missing || c.error != null) {
      return;
    }
    c.loading = true;
    try {
      final file = File(f.path);
      // sync IO for the path-based loads: DXF plans are small and it
      // keeps the flow deterministic (also testable — real async IO
      // is zone-bound under testWidgets' fake clock)
      if (!file.existsSync()) {
        c.missing = true;
        c.error = 'File not found';
        c.loading = false;
        if (mounted) setState(() {});
        return;
      }
      switch (f.kind) {
        case 'image':
          final codec = await ui.instantiateImageCodec(file.readAsBytesSync());
          if (_dead) return;
          final frame = await codec.getNextFrame();
          if (_dead) return;
          c.image = frame.image;
          c.size = Size(
            frame.image.width.toDouble(),
            frame.image.height.toDouble(),
          );
          break;
        case 'pdf':
          c.doc ??= await PdfDocument.openFile(f.path);
          if (_dead || c.retired) return;
          if (f.pageCount != c.doc!.pagesCount) {
            est.setDrawingPageCount(f, c.doc!.pagesCount);
          }
          await _renderPdfPage(f, _page);
          break;
        case 'dxf':
          String src;
          try {
            src = file.readAsStringSync();
          } catch (_) {
            src = String.fromCharCodes(file.readAsBytesSync());
          }
          c.scene = DxfParser.parse(src);
          c.size = c.scene!.naturalSize();
          break;
        case 'dwg':
          await _loadDwg(f, c);
          break;
      }
    } catch (e) {
      c.error = '$e';
    }
    c.loading = false;
    if (mounted) setState(() => _fitOrRestore());
  });

  Future<void> _renderPdfPage(DrawingFile f, int page) => _guard(() async {
    final c = _cache(f.id);
    if (c.pdfPages.containsKey(page)) {
      c.size = Size(
        c.pdfPages[page]!.width.toDouble(),
        c.pdfPages[page]!.height.toDouble(),
      );
      return;
    }
    if (_dead || c.retired || c.doc == null) return;
    final pg = await c.doc!.getPage(page + 1);
    try {
      if (_dead) return;
      // ~2x source px, capped so big sheets stay under memory limits
      final s = (2400 / pg.width).clamp(0.5, 4.0);
      final img = await pg.render(
        width: pg.width * s,
        height: pg.height * s,
        format: PdfPageImageFormat.png,
        backgroundColor: '#FFFFFF',
      );
      if (_dead) return;
      if (img == null) {
        c.error = 'Could not render page ${page + 1}';
        return;
      }
      final codec = await ui.instantiateImageCodec(img.bytes);
      final frame = await codec.getNextFrame();
      if (_dead) return;
      c.pdfPages[page] = frame.image;
      c.size = Size(img.width!.toDouble(), img.height!.toDouble());
    } finally {
      await pg.close();
    }
  });

  /// .dwg has no open renderer — convert to DXF first. Order: the
  /// DWGs go through the dedicated [DwgReader] (lib/dwg.dart): it
  /// converts to DXF via the bundled LibreDWG `dwgconv\` exe, then
  /// AutoCAD's accoreconsole / ODA File Converter when installed, and
  /// caches the result per file revision.
  Future<void> _loadDwg(DrawingFile f, _FileCache c) =>
      _guard(() => _loadDwgInner(f, c));

  Future<void> _loadDwgInner(DrawingFile f, _FileCache c) async {
    final outDir = Directory(
      '${Directory.systemTemp.path}/ce_dwg/'
      '${f.id}',
    );
    try {
      final r = await DwgReader.open(f.path, outDir);
      c.scene = r.scene;
      c.size = r.scene.naturalSize();
    } on DwgReadException catch (e) {
      c.error = e.message;
    } on DxfParseException {
      c.error = 'The DWG converted but contains no drawable entities.';
    }
  }

  // ---------- zoom ----------

  void _zoomAt(Offset focal, double factor) {
    final cur = _tc.value.getMaxScaleOnAxis();
    final f = (cur * factor).clamp(0.05, 40.0) / cur;
    final d = Matrix4.identity()
      ..translateByDouble(focal.dx, focal.dy, 0, 1)
      ..scaleByDouble(f, f, f, 1)
      ..translateByDouble(-focal.dx, -focal.dy, 0, 1);
    _tc.value = d.multiplied(_tc.value);
  }

  void _fit() {
    final s = _contentSize();
    if (s == null || _viewport.isEmpty) return;
    final k = ((_viewport.width - 24) / s.width).clamp(0.01, 40.0);
    final ky = ((_viewport.height - 24) / s.height).clamp(0.01, 40.0);
    final sc = k < ky ? k : ky;
    _tc.value = Matrix4.identity()
      ..translateByDouble(
        (_viewport.width - s.width * sc) / 2,
        (_viewport.height - s.height * sc) / 2,
        0,
        1,
      )
      ..scaleByDouble(sc, sc, sc, 1);
  }

  void _zoom100() {
    final s = _contentSize();
    if (s == null) return;
    // generated sheets are mm — 1:1 is real size on screen, not 1px/unit
    final info = _sheetScaleInfo;
    final z = info != null ? _pxPerMm / info.$2 : 1.0;
    _tc.value = Matrix4.identity()
      ..translateByDouble(
        (_viewport.width - s.width * z) / 2,
        (_viewport.height - s.height * z) / 2,
        0,
        1,
      )
      ..scaleByDouble(z, z, z, 1);
  }

  /// Absolute zoom (px per content unit) about the viewport centre.
  void _zoomTo(double z) {
    final cur = _tc.value.getMaxScaleOnAxis();
    _zoomAt(_viewport.center(Offset.zero), (z.clamp(0.05, 40.0) / cur));
  }

  /// CSS px per mm at 96dpi — the "print at real size" anchor used to
  /// express the current zoom as a drawing scale on generated sheets.
  static const _pxPerMm = 96 / 25.4;

  /// For a generated sheet: its plotted denominator N (from the
  /// `SCALE 1:N` text) plus the content px per sheet-mm — the two
  /// numbers that turn viewer zoom into a real drawing scale.
  /// Null for images/PDFs and unscaled DXFs.
  (int, double)? get _sheetScaleInfo {
    final f = _sel;
    final c = f == null ? null : _cache(f.id);
    final sc = c?.scene;
    if (sc == null || c!.size == null) return null;
    int? denom;
    for (final t in sc.texts) {
      final m = RegExp(r'^SCALE 1:(\d+)').firstMatch(t.text);
      if (m != null) {
        denom = int.tryParse(m.group(1)!);
        break;
      }
    }
    if (denom == null || sc.bounds.width <= 0) return null;
    return (denom, c.size!.width / sc.bounds.width);
  }

  /// Toolbar label: '1:N' equivalent scale on generated sheets, a plain
  /// percentage for images/PDFs and unscaled DXFs.
  String get _zoomLabel {
    final info = _sheetScaleInfo;
    final z = _tc.value.getMaxScaleOnAxis();
    if (info != null) {
      return '1:${(info.$1 * _pxPerMm / (z * info.$2)).round()}';
    }
    return '${(z * 100).round()}%';
  }

  PopupMenuItem<double> _scaleItem(double v, String s) => PopupMenuItem(
    value: v,
    child: Text(s, style: const TextStyle(fontSize: 12)),
  );

  Size? _contentSize() {
    final f = _sel;
    if (f == null) return null;
    return _cache(f.id).size;
  }

  // ---------- file navigation ----------

  /// Index of the current file in the library (-1 when none).
  int get _selIndex {
    final f = _sel;
    return f == null ? -1 : est.drawings.indexOf(f);
  }

  /// Open a file from the library: select it, reset to page 0 and
  /// either load it or restore its remembered zoom/pan.
  void _selectFile(DrawingFile d) {
    _selId = d.id;
    _page = 0;
    _selMark = null;
    _selHandle = -2;
    if (!_cache(d.id).missing && _cache(d.id).size == null) {
      _load(d);
    } else {
      _fitOrRestore();
    }
    setState(() {});
  }

  /// Prev/next file in the library (the toolbar's < n/m > buttons).
  void _stepFile(int dir) {
    final i = _selIndex, n = est.drawings.length;
    if (n < 2) return;
    final j = (i + dir).clamp(0, n - 1);
    if (j != i) _selectFile(est.drawings[j]);
  }

  // ---------- marking ----------

  Offset _toNorm(Offset local) {
    final s = _contentSize() ?? const Size(1, 1);
    return Offset(
      (local.dx / s.width).clamp(0.0, 1.0),
      (local.dy / s.height).clamp(0.0, 1.0),
    );
  }

  void _markStart(Offset local) {
    final p = _toNorm(local);
    setState(
      () => _active = DrawingMark(
        fileId: _sel!.id,
        page: _page,
        kind: _tool.name,
        pts: [p.dx, p.dy],
        color: _markColor,
        width: _markWidth,
      ),
    );
  }

  void _markUpdate(Offset local) {
    final a = _active;
    if (a == null) return;
    final p = _toNorm(local);
    setState(() {
      if (a.kind == 'pen' || a.kind == 'hi') {
        a.pts.addAll([p.dx, p.dy]);
      } else {
        if (a.pts.length > 2) a.pts.removeRange(2, a.pts.length);
        a.pts.addAll([p.dx, p.dy]);
        // live length readout while a measure drag is in flight
        if (a.kind == 'measure') a.text = _measureText(a.pts);
      }
    });
  }

  void _markEnd() {
    final a = _active;
    if (a != null && a.pts.length >= 4) {
      if (a.kind == 'measure') {
        if (_measureRef == null) {
          // uncalibrated page: this drag is the REFERENCE — hold it
          // and ask for its real length instead of adding a mark
          setState(() {
            _refLine = List.of(a.pts);
            _refCtrl ??= TextEditingController();
            _refCtrl!.clear();
          });
          WidgetsBinding.instance.addPostFrameCallback(
            (_) => _refFocus.requestFocus(),
          );
        } else {
          a.text = _measureText(a.pts);
          est.addMark(a);
          _selMark = a;
        }
        setState(() => _active = null);
        return;
      }
      est.addMark(a);
      // keep the just-drawn mark selected so it can be adjusted right
      // away — click empty space (or another mark) to release it
      _selMark = a;
    }
    setState(() => _active = null);
  }

  // ---------- measuring ----------

  /// This page's calibration, if the user has set one.
  MeasureRef? get _measureRef {
    final f = _sel;
    return f == null ? null : est.measureRefFor(f.id, _page);
  }

  /// Content-px length of a 2-point normalized mark.
  double _pxLen(List<double> pts) {
    final s = _contentSize();
    if (s == null || pts.length < 4) return 0;
    return (Offset(pts[2] * s.width, pts[3] * s.height) -
            Offset(pts[0] * s.width, pts[1] * s.height))
        .distance;
  }

  /// '4,520 mm' — the real length of [pts] under this page's scale.
  String _measureText(List<double> pts) {
    final r = _measureRef;
    if (r == null) return '';
    return '${_fmtLen(_pxLen(pts) * r.realPerPx)} ${r.unit}';
  }

  static String _fmtLen(double v) {
    final s = v >= 1000
        ? v.toStringAsFixed(0)
        : v >= 10
        ? v.toStringAsFixed(1)
        : v.toStringAsFixed(2);
    final dot = s.indexOf('.');
    final ip = dot < 0 ? s : s.substring(0, dot);
    final buf = StringBuffer();
    for (var i = 0; i < ip.length; i++) {
      if (i > 0 && (ip.length - i) % 3 == 0) buf.write(',');
      buf.write(ip[i]);
    }
    return dot < 0 ? buf.toString() : '$buf${s.substring(dot)}';
  }

  /// Commit the reference editor: store the page scale and leave the
  /// drawn reference as a labeled measure mark.
  void _commitRef() {
    final line = _refLine;
    final v = double.tryParse((_refCtrl?.text ?? '').replaceAll(',', ''));
    if (line == null) return;
    if (v != null && v > 0) {
      final px = _pxLen(line);
      if (px > 0) {
        final f = _sel!;
        est.setMeasureRef(f.id, _page, MeasureRef(px, v, _refUnit));
        final ref = DrawingMark(
          fileId: f.id,
          page: _page,
          kind: 'measure',
          pts: line,
          color: _markColor,
          width: _markWidth,
          text: '${_fmtLen(v)} $_refUnit',
        );
        est.addMark(ref);
        _selMark = ref;
      }
    }
    _cancelRef();
  }

  void _cancelRef() {
    setState(() {
      _refLine = null;
    });
  }

  // ---------- generated-sheet title block ----------

  /// mm -> content px for a cell rect on a generated sheet — the same
  /// fit + Y-flip DxfPainter applies to the scene.
  Rect _sheetCellPx(Rect mm, DxfScene sc, Size size) {
    final b = sc.bounds;
    final k = size.width / b.width;
    return Rect.fromLTRB(
      (mm.left - b.left) * k,
      (b.top + b.height - mm.bottom) * k,
      (mm.right - b.left) * k,
      (b.top + b.height - mm.top) * k,
    );
  }

  /// The model a generated sheet belongs to — `f.id` is
  /// `sheet:<modelId>:<slug>`. Fallback for the title cell when the
  /// project title is empty (mirrors `_paperFurniture`).
  String _sheetModelName(DrawingFile f) {
    final parts = f.id.split(':');
    if (parts.length == 3) {
      for (final m in est.models) {
        if (m.id == parts[1]) return m.name.toUpperCase();
      }
    }
    return 'UNTITLED PROJECT';
  }

  void _startTitle() {
    _titleBefore = est.project.title;
    _titleSizeBefore = est.project.titleSize;
    _titleCtrl?.dispose();
    _titleCtrl = TextEditingController(text: est.project.title);
    setState(() => _titleEdit = true);
    _titleFocus.requestFocus();
  }

  void _commitTitle() {
    if (!_titleEdit) return;
    setState(() {
      _titleEdit = false;
      _titleBefore = null;
      _titleSizeBefore = null;
    });
  }

  /// Esc / cancel — restores the text AND the font size captured when
  /// the editor opened.
  void _cancelTitle() {
    if (!_titleEdit) return;
    est.project.title = _titleBefore ?? est.project.title;
    est.project.titleSize = _titleSizeBefore ?? est.project.titleSize;
    est.update();
    setState(() {
      _titleEdit = false;
      _titleBefore = null;
      _titleSizeBefore = null;
    });
  }

  Future<void> _logoMenu(Offset pos) async {
    final v = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(pos.dx, pos.dy, pos.dx, pos.dy),
      items: const [
        PopupMenuItem(value: 'replace', child: Text('Replace logo…')),
        PopupMenuItem(
          value: 'remove',
          child: Text(
            'Remove logo',
            style: TextStyle(color: Colors.redAccent),
          ),
        ),
      ],
    );
    switch (v) {
      case 'replace':
        unawaited(est.pickLogo().catchError((_) {}));
      case 'remove':
        est.clearLogo();
    }
  }

  /// The title-block hotspots for a generated sheet (`sheet:` files):
  /// the logo cell opens the image picker (right-click for a
  /// replace/remove menu), the title cell opens an inline editor for
  /// `project.title`. Both cover the painted cells with live values so
  /// edits show instantly without regenerating the sheet.
  Widget _sheetCells(DrawingFile f, _FileCache c, Size s) {
    final sc = c.scene!;
    final cells = sheetTitleCells(
      sc.bounds,
      isPrivate: est.project.effSignatories.isEmpty,
    );
    final z = _tc.value.getMaxScaleOnAxis().abs() + .0001;
    final logo = _sheetCellPx(cells.logo, sc, s);
    final title = _sheetCellPx(cells.title, sc, s);
    final hasLogo = est.project.logoB64 != null;
    final display = est.project.title.isEmpty
        ? _sheetModelName(f)
        : est.project.title.toUpperCase();
    // cell is the strip's 12mm top row — px-per-mm lets the overlay's
    // font match the painted sheet mm size exactly
    final kmm = title.height / 12;
    final ts = est.project.titleSize.clamp(1.2, 9.0);
    final style = TextStyle(
      fontSize: ts * kmm,
      fontWeight: FontWeight.w700,
      letterSpacing: .3,
      height: 1.15,
      color: const Color(0xFF334155),
    );
    // resize handle ~11 screen px, in sheet space so it tracks the cell
    final hs = 11 / z;
    return Stack(
      children: [
        Positioned.fromRect(
          rect: logo,
          child: Tooltip(
            message: hasLogo
                ? 'Click to replace the project logo · right-click for options'
                : 'Click to add the project logo',
            child: _CellHover(
              key: const Key('sheet-cell-logo'),
              onTap: () => unawaited(est.pickLogo().catchError((_) {})),
              onSecondary: hasLogo ? (p) => _logoMenu(p) : null,
              child: hasLogo
                  ? Container(
                      color: Colors.white,
                      padding: const EdgeInsets.all(1),
                      child: Image.memory(
                        base64Decode(est.project.logoB64!),
                        fit: BoxFit.contain,
                      ),
                    )
                  : const SizedBox.expand(),
            ),
          ),
        ),
        Positioned.fromRect(
          rect: title,
          child: _titleEdit
              ? Container(
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    border: Border.all(
                      color: const Color(0xFF1E4976),
                      width: .6,
                    ),
                  ),
                  child: TextField(
                    key: const Key('sheet-title-field'),
                    controller: _titleCtrl,
                    focusNode: _titleFocus,
                    autofocus: true,
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    style: style,
                    decoration: const InputDecoration(
                      isDense: true,
                      border: InputBorder.none,
                      contentPadding: EdgeInsets.symmetric(horizontal: 2),
                    ),
                    onChanged: (v) {
                      // WYSIWYG: every keystroke lands on the cell at
                      // its real sheet size — the controller + focus
                      // survive the rebuild
                      est.project.title = v;
                      est.update();
                    },
                    onSubmitted: (_) => _commitTitle(),
                    // the resize handle shares this group — dragging it
                    // must NOT count as an outside tap or the editor
                    // (and the handle itself) dies mid-gesture
                    groupId: 'sheet-title',
                    onTapOutside: (_) => _commitTitle(),
                  ),
                )
              : Tooltip(
                  message: 'Click to edit the project title',
                  child: _CellHover(
                    key: const Key('sheet-cell-title'),
                    onTap: _startTitle,
                    child: Container(
                      color: Colors.white,
                      alignment: Alignment.center,
                      padding: const EdgeInsets.symmetric(horizontal: 2),
                      child: Text(
                        display,
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: style,
                      ),
                    ),
                  ),
                ),
        ),
        // corner handle — drag diagonally to resize the title text:
        // down-right grows, up-left shrinks (mm per content px = 12/H)
        if (_titleEdit)
          Positioned(
            // 3/4 of the handle hangs below the cell — its center stays
            // outside the TextField's hit region, which would otherwise
            // win the gesture arena with a text-selection drag
            left: title.right - hs * .2,
            top: title.bottom - hs * .25,
            width: hs,
            height: hs,
            child: MouseRegion(
              cursor: SystemMouseCursors.resizeUpLeftDownRight,
              child: TapRegion(
                // inside the editor's tap group — a down here must not
                // commit the title via onTapOutside
                groupId: 'sheet-title',
                // raw pointer moves, not a pan recognizer — the
                // TextField's selection-drag/Tooltip recognizers win
                // the gesture arena at the cell edge and the handle
                // silently never drags
                child: Listener(
                  key: const Key('sheet-title-size'),
                  behavior: HitTestBehavior.opaque,
                  onPointerMove: (e) {
                    if (e.buttons & kPrimaryButton == 0) return;
                    final k = title.height / 12;
                    est.project.titleSize =
                        (est.project.titleSize +
                                (e.delta.dx + e.delta.dy) / 2 / k)
                            .clamp(1.2, 9.0);
                    est.update();
                  },
                  child: Tooltip(
                    message: 'Drag to resize the title',
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.white,
                        border: Border.all(
                          color: const Color(0xFF1E4976),
                          width: .5 / z,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  // ---------- eraser ----------

  Offset? _eraseLast;

  /// Erase every mark the eraser tip touches (content px).
  void _eraseAt(Offset local) => _eraseAlong(local, local);

  /// Sweep from [a] to [b] — sampled so a fast flick still removes
  /// every mark the path crosses, any kind (pen, hi, arrow, rect,
  /// text, measure). Clears the selection when it is erased.
  void _eraseAlong(Offset a, Offset b) {
    final f = _sel;
    if (f == null || _contentSize() == null) return;
    final s = _contentSize()!;
    final step = (_pickTol / 2).clamp(2.0, 20.0);
    final n = max(1, ((b - a).distance / step).ceil());
    final doomed = <DrawingMark>{};
    for (final m in est.marksFor(f.id, _page)) {
      for (var i = 0; i <= n; i++) {
        if (_markHit(m, Offset.lerp(a, b, i / n)!, s)) {
          doomed.add(m);
          break;
        }
      }
    }
    if (doomed.isEmpty) return;
    for (final m in doomed) {
      est.removeMark(m);
    }
    if (_selMark != null && doomed.contains(_selMark)) {
      setState(() {
        _selMark = null;
        _selHandle = -2;
      });
    }
  }

  // ---------- select / adjust ----------

  /// Topmost mark hit by [local] (content px), or null.
  DrawingMark? _hitMark(Offset local) {
    final s = _contentSize() ?? const Size(1, 1);
    final marks = est.marksFor(_sel!.id, _page);
    for (var i = marks.length - 1; i >= 0; i--) {
      final m = marks[i];
      if (_markHit(m, local, s)) return m;
    }
    return null;
  }

  /// Pick tolerance in content px — keeps ~14 px on screen at any zoom.
  double get _pickTol {
    final k = _tc.value.getMaxScaleOnAxis();
    return k <= 0 ? 14.0 : 14.0 / k;
  }

  bool _markHit(DrawingMark m, Offset p, Size s) {
    final tol = _pickTol;
    Offset px(double x, double y) => Offset(x * s.width, y * s.height);
    switch (m.kind) {
      case 'pen':
      case 'hi':
        for (var i = 0; i + 3 < m.pts.length; i += 2) {
          if (_distSeg(
                p,
                px(m.pts[i], m.pts[i + 1]),
                px(m.pts[i + 2], m.pts[i + 3]),
              ) <
              tol + m.width) {
            return true;
          }
        }
        return m.pts.length >= 2 && (p - px(m.pts[0], m.pts[1])).distance < tol;
      case 'arrow':
      case 'measure':
        if (m.pts.length < 4) return false;
        return _distSeg(p, px(m.pts[0], m.pts[1]), px(m.pts[2], m.pts[3])) <
            tol + m.width;
      case 'rect':
        if (m.pts.length < 4) return false;
        // on an edge or inside selects it
        return _markRect(m, s).inflate(tol).contains(p);
      case 'text':
        if (m.pts.length < 2) return false;
        final r = _textBounds(m, s);
        return r.inflate(tol).contains(p);
      default:
        return false;
    }
  }

  double _distSeg(Offset p, Offset a, Offset b) {
    final ab = b - a;
    final t = ab.distance == 0
        ? 0.0
        : (((p - a).dx * ab.dx + (p - a).dy * ab.dy) /
                  (ab.dx * ab.dx + ab.dy * ab.dy))
              .clamp(0.0, 1.0);
    return (p - (a + ab * t)).distance;
  }

  Rect _markRect(DrawingMark m, Size s) {
    final r = Rect.fromPoints(
      Offset(m.pts[0] * s.width, m.pts[1] * s.height),
      Offset(m.pts[2] * s.width, m.pts[3] * s.height),
    );
    return r;
  }

  Rect _textBounds(DrawingMark m, Size s) {
    final tp = TextPainter(
      text: TextSpan(
        text: m.text,
        style: TextStyle(
          fontSize: m.width.clamp(10.0, 60.0),
          fontWeight: FontWeight.w600,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 8,
    )..layout(maxWidth: s.width * .5);
    return Rect.fromLTWH(
      m.pts[0] * s.width,
      m.pts[1] * s.height,
      tp.width,
      tp.height,
    );
  }

  /// Handle points (content px) for a selected mark: rect/freeform ->
  /// bbox corners, arrow -> endpoints, text -> none (drag body to move).
  List<Offset> _handlesFor(DrawingMark m, Size s) {
    switch (m.kind) {
      case 'rect':
        final r = _markRect(m, s);
        return [r.topLeft, r.topRight, r.bottomRight, r.bottomLeft];
      case 'arrow':
      case 'measure':
        return [
          Offset(m.pts[0] * s.width, m.pts[1] * s.height),
          Offset(m.pts[2] * s.width, m.pts[3] * s.height),
        ];
      case 'pen':
      case 'hi':
        if (m.pts.length < 4) return const [];
        var l = m.pts[0], t = m.pts[1], r = m.pts[0], b = m.pts[1];
        for (var i = 0; i + 1 < m.pts.length; i += 2) {
          l = min(l, m.pts[i]);
          r = max(r, m.pts[i]);
          t = min(t, m.pts[i + 1]);
          b = max(b, m.pts[i + 1]);
        }
        final rr = Rect.fromLTRB(
          l * s.width,
          t * s.height,
          r * s.width,
          b * s.height,
        );
        return [rr.topLeft, rr.topRight, rr.bottomRight, rr.bottomLeft];
      default:
        return const [];
    }
  }

  void _selStart(Offset local) {
    if (!_tryAdjustAt(local)) {
      // press on empty space in select mode releases the selection
      setState(() {
        _selMark = null;
        _selHandle = -2;
        _dragLast = null;
      });
    }
  }

  /// If the press lands on the current selection's handles, the
  /// selection's body, or any other mark, adopt it as the selection
  /// and start the adjust drag. Returns true when a mark was grabbed —
  /// callers then skip starting a new mark.
  bool _tryAdjustAt(Offset local) {
    final f = _sel;
    if (f == null) return false;
    final s = _contentSize() ?? const Size(1, 1);
    final m = _selMark;
    if (m != null && est.marksFor(f.id, _page).contains(m)) {
      // a handle grab wins over a body move
      final hs = _handlesFor(m, s);
      for (var i = 0; i < hs.length; i++) {
        if ((local - hs[i]).distance < _pickTol + 2) {
          setState(() {
            _selHandle = i;
            _dragLast = local;
            _tool = _Tool.select;
          });
          return true;
        }
      }
      if (_markHit(m, local, s)) {
        setState(() {
          _selHandle = -1;
          _dragLast = local;
          _tool = _Tool.select;
        });
        return true;
      }
    }
    final hit = _hitMark(local);
    if (hit == null) return false;
    setState(() {
      _selMark = hit;
      _selHandle = -1;
      _dragLast = local;
      // switch to Select so the handles stay up after this drag
      _tool = _Tool.select;
    });
    return true;
  }

  void _selUpdate(Offset local) {
    final m = _selMark;
    final last = _dragLast;
    if (m == null || last == null || _selHandle == -2) return;
    final s = _contentSize() ?? const Size(1, 1);
    setState(() {
      _dragLast = local;
      if (_selHandle == -1) {
        // move: translate every point by the drag delta
        final d = _toNorm(local) - _toNorm(last);
        for (var i = 0; i < m.pts.length; i += 2) {
          m.pts[i] = (m.pts[i] + d.dx).clamp(-0.5, 1.5);
          m.pts[i + 1] = (m.pts[i + 1] + d.dy).clamp(-0.5, 1.5);
        }
      } else {
        _resize(m, _selHandle, local, s);
      }
    });
  }

  void _resize(DrawingMark m, int h, Offset local, Size s) {
    final p = _toNorm(local);
    switch (m.kind) {
      case 'rect':
        // corner handles: rewrite both stored corners normalized
        final hs = _handlesFor(m, s);
        final opp = hs[(h + 2) % 4];
        final a = _toNorm(opp), b = p;
        m.pts
          ..[0] = min(a.dx, b.dx)
          ..[1] = min(a.dy, b.dy)
          ..[2] = max(a.dx, b.dx)
          ..[3] = max(a.dy, b.dy);
        break;
      case 'arrow':
      case 'measure':
        m.pts[h * 2] = p.dx;
        m.pts[h * 2 + 1] = p.dy;
        // keep the readout honest while a measure line is resized
        if (m.kind == 'measure' && _measureRef != null) {
          m.text = _measureText(m.pts);
        }
        break;
      case 'pen':
      case 'hi':
        // scale the whole stroke about the opposite bbox corner
        final hs = _handlesFor(m, s);
        final o = _toNorm(hs[(h + 2) % 4]);
        final tgt = _toNorm(hs[h]);
        final sx = (tgt.dx - o.dx).abs() < 1e-6
            ? 1.0
            : (p.dx - o.dx) / (tgt.dx - o.dx);
        final sy = (tgt.dy - o.dy).abs() < 1e-6
            ? 1.0
            : (p.dy - o.dy) / (tgt.dy - o.dy);
        for (var i = 0; i < m.pts.length; i += 2) {
          m.pts[i] = o.dx + (m.pts[i] - o.dx) * sx;
          m.pts[i + 1] = o.dy + (m.pts[i + 1] - o.dy) * sy;
        }
        break;
    }
  }

  void _selEnd() {
    if (_selMark != null && _selHandle != -2) est.update();
    _selHandle = -2;
    _dragLast = null;
    _updateHover(_lastHover);
  }

  /// Hand cursor feedback: grab over a movable mark, grabbing while a
  /// drag is in flight, default elsewhere.
  void _setCursor(MouseCursor c) {
    if (c != _cursor && mounted) setState(() => _cursor = c);
  }

  void _updateHover(Offset local) {
    _lastHover = local;
    if (_selHandle != -2) {
      // grab/grabbing render as the plain arrow on Windows — SIZEALL
      // is the drag affordance that actually shows
      _setCursor(SystemMouseCursors.move);
      return;
    }
    // eraser reads as a crosshair wherever it hovers — a press erases
    if (_tool == _Tool.eraser) {
      _setCursor(SystemMouseCursors.precise);
      return;
    }
    // the sheet-move drag reads as the 4-way move cursor everywhere —
    // anywhere on the paper grabs the drawing
    if (_tool == _Tool.sheet) {
      _setCursor(SystemMouseCursors.move);
      return;
    }
    // the hand only shows where a press will actually grab: Select
    // mode over a mark. With a draw tool the same spot draws a new
    // mark, so the cursor stays default.
    if (_tool == _Tool.select &&
        _sel != null &&
        _contentSize() != null &&
        _hitMark(local) != null) {
      _setCursor(SystemMouseCursors.click);
    } else {
      _setCursor(MouseCursor.defer);
    }
  }

  // ---------- inline text note ----------

  void _startText(Offset local, {DrawingMark? mark}) {
    _textCtrl?.dispose();
    _textCtrl = TextEditingController(text: mark?.text ?? '');
    setState(() {
      _textAt2 = _toNorm(local);
      _textMark = mark;
    });
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _textFocus.requestFocus(),
    );
  }

  void _commitText() {
    final at = _textAt2;
    final ctrl = _textCtrl;
    if (at == null || ctrl == null) return;
    final t = ctrl.text.trim();
    final m = _textMark;
    setState(() {
      _textAt2 = null;
      _textMark = null;
    });
    if (m != null) {
      if (t.isNotEmpty) {
        m.text = t;
        est.update();
      }
      return;
    }
    if (t.isEmpty) return;
    final mark = DrawingMark(
      fileId: _sel!.id,
      page: _page,
      kind: 'text',
      pts: [at.dx, at.dy],
      color: _markColor,
      width: _markWidth * 5,
      text: t,
    );
    est.addMark(mark);
    _selMark = mark;
  }

  // ---------- build ----------

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: _shortcuts,
      child: Focus(
        focusNode: _keyFocus,
        child: ListenableBuilder(
          listenable: est,
          builder: (context, _) {
            final f = _sel;
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _library(f),
                Expanded(
                  child: Column(
                    children: [
                      Expanded(child: f == null ? _emptyState() : _viewer(f)),
                      _toolbar(f),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _emptyState() => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(
          Icons.design_services_outlined,
          size: 56,
          color: Color(0xFF94A3B8),
        ),
        const SizedBox(height: 12),
        const Text(
          'No drawings yet',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 6),
        const Text(
          'Open plans as images, PDFs, or AutoCAD DXF files.\n'
          'DWG files open through the built-in converter.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12, color: Color(0xFF64748B)),
        ),
        const SizedBox(height: 14),
        FilledButton.icon(
          onPressed: _open,
          icon: const Icon(Icons.folder_open_outlined, size: 18),
          label: const Text('Open drawing'),
        ),
      ],
    ),
  );

  Widget _library(DrawingFile? sel) {
    // collapsed: a thin rail so the canvas gets the space back —
    // the flag lives in est so it survives tab switches
    if (!est.drawingLibraryOpen) {
      return Container(
        width: 40,
        margin: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: const Color(0xFFE2E8F0)),
        ),
        child: Column(
          children: [
            IconButton(
              icon: const Icon(Icons.chevron_right, size: 18),
              tooltip: 'Show drawing files',
              onPressed: () => est.setDrawingLibraryOpen(true),
            ),
            IconButton(
              icon: const Icon(Icons.add, size: 18),
              tooltip: 'Open drawing file',
              onPressed: _open,
            ),
          ],
        ),
      );
    }
    return Container(
      width: 236,
      margin: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 6, 6),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    'DRAWING FILES',
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF475569),
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.chevron_left, size: 18),
                  tooltip: 'Hide drawing files',
                  onPressed: () => est.setDrawingLibraryOpen(false),
                  constraints: const BoxConstraints.tightFor(
                    width: 30,
                    height: 30,
                  ),
                  padding: EdgeInsets.zero,
                ),
                IconButton(
                  icon: const Icon(Icons.add, size: 18),
                  tooltip: 'Open drawing file',
                  onPressed: _open,
                  constraints: const BoxConstraints.tightFor(
                    width: 30,
                    height: 30,
                  ),
                  padding: EdgeInsets.zero,
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: est.drawings.isEmpty
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(12),
                      child: Text(
                        'Open files appear here — pick one to view.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 11,
                          color: Color(0xFF94A3B8),
                        ),
                      ),
                    ),
                  )
                : Material(
                    type: MaterialType.transparency,
                    child: ListView(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      children: [
                        for (final d in est.drawings) _fileTile(d, sel),
                      ],
                    ),
                  ),
          ),
          if (sel != null && sel.kind == 'pdf' && sel.pageCount > 1) ...[
            const Divider(height: 1),
            const Padding(
              padding: EdgeInsets.fromLTRB(12, 8, 12, 2),
              child: Text(
                'PAGES',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF475569),
                ),
              ),
            ),
            SizedBox(
              height: (sel.pageCount * 34.0).clamp(60.0, 220.0),
              child: Material(
                type: MaterialType.transparency,
                child: ListView(
                  children: [
                    for (var i = 0; i < sel.pageCount; i++)
                      ListTile(
                        dense: true,
                        selected: i == _page,
                        selectedTileColor: const Color(
                          0xFF1E4976,
                        ).withValues(alpha: .08),
                        leading: Icon(
                          Icons.article_outlined,
                          size: 15,
                          color: i == _page
                              ? const Color(0xFF1E4976)
                              : const Color(0xFF94A3B8),
                        ),
                        title: Text(
                          'Page ${i + 1}',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: i == _page
                                ? FontWeight.w700
                                : FontWeight.w400,
                          ),
                        ),
                        onTap: () async {
                          setState(() => _page = i);
                          await _renderPdfPage(sel, i);
                          setState(() => _fitOrRestore());
                        },
                      ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _fileTile(DrawingFile d, DrawingFile? sel) {
    final active = d.id == sel?.id;
    final icon = switch (d.kind) {
      'pdf' => Icons.picture_as_pdf_outlined,
      'dxf' || 'dwg' => Icons.architecture_outlined,
      _ => Icons.image_outlined,
    };
    return ListTile(
      dense: true,
      selected: active,
      selectedTileColor: const Color(0xFF1E4976).withValues(alpha: .08),
      leading: Icon(
        icon,
        size: 18,
        color: active ? const Color(0xFF1E4976) : const Color(0xFF64748B),
      ),
      title: Text(
        d.name,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 11.5,
          fontWeight: active ? FontWeight.w700 : FontWeight.w500,
        ),
      ),
      subtitle: Text(
        '${d.kind.toUpperCase()}'
        '${d.kind == 'pdf' ? ' · ${d.pageCount}p' : ''}',
        style: const TextStyle(fontSize: 9.5),
      ),
      trailing: InkWell(
        onTap: () {
          final c = _caches.remove(d.id);
          if (c != null) {
            // a getPage/render may still be in flight on its native
            // doc — defer the close until the view is quiescent
            c.retired = true;
            _retired.add(c);
            _closeDocsWhenIdle();
          }
          est.removeDrawing(d);
          if (_selId == d.id) {
            _selId = est.drawings.isEmpty ? null : est.drawings.first.id;
            _page = 0;
          }
        },
        child: const Padding(
          padding: EdgeInsets.all(4),
          child: Icon(Icons.close, size: 14, color: Color(0xFF94A3B8)),
        ),
      ),
      onTap: () => _selectFile(d),
    );
  }

  Widget _viewer(DrawingFile f) {
    final c = _cache(f.id);
    if (c.size == null && !c.missing && c.error == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _load(f));
      return const Center(child: CircularProgressIndicator());
    }
    if (c.missing || c.error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.broken_image_outlined,
              size: 48,
              color: Color(0xFF94A3B8),
            ),
            const SizedBox(height: 10),
            Text(
              c.missing ? 'File not found' : 'Cannot open file',
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 40),
              child: Text(
                c.missing ? f.path : (c.error ?? ''),
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 11, color: Color(0xFF64748B)),
              ),
            ),
          ],
        ),
      );
    }
    final s = c.size!;
    return LayoutBuilder(
      builder: (context, box) {
        _viewport = Size(box.maxWidth, box.maxHeight);
        if (!c.fitted) {
          c.fitted = true;
          WidgetsBinding.instance.addPostFrameCallback((_) => _fitOrRestore());
        }
        return Container(
          color: const Color(0xFFCBD5E1),
          child: Listener(
            onPointerDown: (e) {
              // middle-button drag pans like AutoCAD — any tool,
              // double-middle-click is zoom extents
              if (e.buttons == kMiddleMouseButton) {
                final now = DateTime.now();
                if (_midTap != null &&
                    now.difference(_midTap!) <
                        const Duration(milliseconds: 400)) {
                  _midTap = null;
                  _midPan = null;
                  _fit();
                  return;
                }
                _midTap = now;
                _midPan = e.localPosition;
                return;
              }
              // grab key focus for the tool shortcuts — but not while
              // an inline editor (text note / measure ref) owns the keys
              if (_textAt2 == null && _refLine == null) {
                _keyFocus.requestFocus();
              }
            },
            onPointerMove: (e) {
              if (_midPan != null) {
                final d = e.localPosition - _midPan!;
                _midPan = e.localPosition;
                _tc.value = Matrix4.translationValues(
                  d.dx,
                  d.dy,
                  0,
                ).multiplied(_tc.value);
              }
            },
            onPointerUp: (_) => _midPan = null,
            onPointerCancel: (_) => _midPan = null,
            onPointerSignal: (e) {
              if (e is PointerScrollEvent) {
                _zoomAt(
                  e.localPosition,
                  e.scrollDelta.dy < 0 ? 1.25 : 1 / 1.25,
                );
              }
            },
            child: ClipRect(
              child: InteractiveViewer(
                transformationController: _tc,
                constrained: false,
                // an open title-cell editor locks panning: the corner
                // drag handle would otherwise lose the gesture arena
                // to the viewer pan
                panEnabled: _tool == _Tool.pan && !_titleEdit,
                scaleEnabled: false,
                minScale: 0.05,
                maxScale: 40,
                boundaryMargin: const EdgeInsets.all(4000),
                child: SizedBox(
                  width: s.width,
                  height: s.height,
                  child: Stack(
                    children: [
                      Positioned.fill(child: Container(color: Colors.white)),
                      Positioned.fill(child: _content(f, c)),
                      Positioned.fill(
                        child: ListenableBuilder(
                          // marks + zoom: measure overlays counter-
                          // scale, so repaint on either changing
                          listenable: Listenable.merge([est, _tc]),
                          builder: (_, _) => CustomPaint(
                            painter: _MarksPainter(
                              est.marksFor(f.id, _page),
                              s,
                              zoom: _tc.value.getMaxScaleOnAxis(),
                            ),
                          ),
                        ),
                      ),
                      if (_active != null)
                        Positioned.fill(
                          child: ListenableBuilder(
                            listenable: _tc,
                            builder: (_, _) => CustomPaint(
                              painter: _MarksPainter(
                                [_active!],
                                s,
                                zoom: _tc.value.getMaxScaleOnAxis(),
                              ),
                            ),
                          ),
                        ),
                      // selection chrome for the mark being adjusted
                      if (_selMark != null &&
                          _tool != _Tool.pan &&
                          est.marksFor(f.id, _page).contains(_selMark))
                        Positioned.fill(
                          child: ListenableBuilder(
                            listenable: _tc,
                            builder: (_, _) => CustomPaint(
                              painter: _SelPainter(
                                _selMark!,
                                s,
                                _handlesFor,
                                zoom: _tc.value.getMaxScaleOnAxis(),
                              ),
                            ),
                          ),
                        ),
                      // inline text-note editor — type straight on the
                      // canvas where you clicked, no popup
                      if (_textAt2 != null)
                        Positioned(
                          left: _textAt2!.dx * s.width - 6,
                          top: _textAt2!.dy * s.height - 10,
                          child: Container(
                            width: 260,
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: .92),
                              border: Border.all(
                                color: const Color(0xFF1E4976),
                                width: 1.4,
                              ),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            child: TextField(
                              controller: _textCtrl,
                              focusNode: _textFocus,
                              autofocus: true,
                              maxLines: null,
                              style: TextStyle(
                                color: Color(_markColor),
                                fontSize: _markWidth * 5,
                                fontWeight: FontWeight.w600,
                              ),
                              decoration: const InputDecoration(
                                isDense: true,
                                border: InputBorder.none,
                                hintText: 'Type note…',
                              ),
                              onSubmitted: (_) => _commitText(),
                              onTapOutside: (_) => _commitText(),
                            ),
                          ),
                        ),
                      if (_tool != _Tool.pan)
                        Positioned.fill(
                          child: MouseRegion(
                            cursor: _cursor,
                            onHover: (e) => _updateHover(e.localPosition),
                            child: GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              // report the real touch point and emit the
                              // pending delta as the first update — needed
                              // so handle/body hit-tests see the true tap
                              // position (start behavior would offset it by
                              // the ~18-36px pan slop)
                              dragStartBehavior: DragStartBehavior.down,
                              onPanStart: (d) {
                                _commitText();
                                _commitRef();
                                _commitTitle();
                                final local = d.localPosition;
                                if (_tool == _Tool.select) {
                                  _selStart(local);
                                  return;
                                }
                                if (_tool == _Tool.eraser) {
                                  _selMark = null;
                                  _eraseLast = local;
                                  _eraseAt(local);
                                  return;
                                }
                                if (_tool == _Tool.sheet) {
                                  _selMark = null;
                                  final f = _sel;
                                  if (f != null) {
                                    final t = _sheetTarget(f);
                                    _sheetDragModel = t?.$1;
                                    _sheetDragView = t?.$2;
                                  }
                                  return;
                                }
                                // draw tools ALWAYS draw — a drag that
                                // starts on/inside a mark creates a new
                                // overlapping mark. To adjust a mark tap
                                // it once (adopts Select) or use the
                                // Select tool, then drag it.
                                switch (_tool) {
                                  case _Tool.text:
                                    break; // taps place the editor
                                  default:
                                    _selMark = null;
                                    _markStart(local);
                                }
                              },
                              onPanUpdate: (d) {
                                switch (_tool) {
                                  case _Tool.select:
                                    _selUpdate(d.localPosition);
                                  case _Tool.eraser:
                                    _eraseAlong(
                                      _eraseLast ?? d.localPosition,
                                      d.localPosition,
                                    );
                                    _eraseLast = d.localPosition;
                                  case _Tool.text:
                                    break;
                                  case _Tool.sheet:
                                    final f = _sel;
                                    if (f != null &&
                                        _sheetDragModel != null &&
                                        _sheetDragView != null) {
                                      _sheetDragUpdate(f, d.delta);
                                    }
                                  default:
                                    _markUpdate(d.localPosition);
                                }
                              },
                              onPanEnd: (_) {
                                switch (_tool) {
                                  case _Tool.select:
                                    _selEnd();
                                  case _Tool.eraser:
                                    _eraseLast = null;
                                  case _Tool.text:
                                    break;
                                  case _Tool.sheet:
                                    _sheetDragEnd();
                                  default:
                                    _markEnd();
                                }
                              },
                              onPanCancel: () {
                                switch (_tool) {
                                  case _Tool.select:
                                    _selEnd();
                                  case _Tool.eraser:
                                    _eraseLast = null;
                                  case _Tool.text:
                                    break;
                                  case _Tool.sheet:
                                    _sheetDragEnd();
                                  default:
                                    _markEnd();
                                }
                              },
                              onTapUp: (d) {
                                switch (_tool) {
                                  case _Tool.text:
                                    _commitText();
                                    _commitRef();
                                    _commitTitle();
                                    final hit = _hitMark(d.localPosition);
                                    _startText(
                                      d.localPosition,
                                      mark: hit?.kind == 'text' ? hit : null,
                                    );
                                  case _Tool.select:
                                    _commitText();
                                    _commitRef();
                                    _commitTitle();
                                    _selStart(d.localPosition);
                                    if (_selMark == null) _selEnd();
                                  case _Tool.eraser:
                                    _commitText();
                                    _commitRef();
                                    _commitTitle();
                                    _eraseAt(d.localPosition);
                                  case _Tool.sheet:
                                    _commitText();
                                    _commitRef();
                                    _commitTitle();
                                  default:
                                    // click a drawn line/shape to select
                                    // and adjust it; click empty space to
                                    // release the current selection
                                    _commitText();
                                    _commitRef();
                                    _commitTitle();
                                    final hit = _hitMark(d.localPosition);
                                    setState(() {
                                      if (hit != null) {
                                        _selMark = hit;
                                        _tool = _Tool.select;
                                      } else {
                                        _selMark = null;
                                      }
                                    });
                                }
                              },
                            ),
                          ),
                        ),
                      // generated-sheet title block: the logo + title
                      // cells are tap targets (logo picker, title
                      // editor) — above the gesture layer so they win
                      // in every tool, in sheet space so they zoom
                      // with the drawing
                      if (f.id.startsWith('sheet:') && c.scene != null)
                        Positioned.fill(
                          child: ListenableBuilder(
                            listenable: Listenable.merge([est, _tc]),
                            builder: (_, _) => _sheetCells(f, c, s),
                          ),
                        ),
                      // pending measurement reference: a card at the
                      // line's midpoint asking for its real length —
                      // above the gesture layer so its field and unit
                      // picker are clickable. The card lives inside the
                      // zoom transform, so counter-scale it back to a
                      // constant screen size at any magnification.
                      if (_refLine != null)
                        ListenableBuilder(
                          listenable: _tc,
                          builder: (_, _) {
                            final line = _refLine!;
                            final z =
                                _tc.value.getMaxScaleOnAxis().abs() + 0.0001;
                            final mid = Offset(
                              (line[0] + line[2]) / 2 * s.width,
                              (line[1] + line[3]) / 2 * s.height,
                            );
                            // topCenter scaling keeps the child's own
                            // top-center fixed: put that point 64
                            // screen px above the line's midpoint so
                            // the card hovers over the line at any zoom
                            final ch = 64 / z;
                            return Positioned(
                              left: (mid.dx - 144).clamp(-140.0, s.width - 140),
                              top: (mid.dy - ch).clamp(4.0, s.height - ch),
                              child: Transform.scale(
                                scale: 1 / z,
                                alignment: Alignment.topCenter,
                                child: _refEditor(),
                              ),
                            );
                          },
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  /// Inline card for entering the drawn reference line's real length —
  /// number + unit, Enter commits, Esc discards.
  Widget _refEditor() {
    return Container(
      width: 288,
      padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: const Color(0xFF1E4976), width: 1.4),
        borderRadius: BorderRadius.circular(8),
        boxShadow: const [
          BoxShadow(
            color: Color(0x33000000),
            blurRadius: 8,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          const Icon(Icons.straighten, size: 16, color: Color(0xFF1E4976)),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: _refCtrl,
              focusNode: _refFocus,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              decoration: const InputDecoration(
                isDense: true,
                border: InputBorder.none,
                hintText: 'Real length of this line',
              ),
              onSubmitted: (_) => _commitRef(),
            ),
          ),
          DropdownButton<String>(
            value: _refUnit,
            isDense: true,
            underline: const SizedBox.shrink(),
            style: const TextStyle(fontSize: 12, color: Color(0xFF334155)),
            items: const [
              DropdownMenuItem(value: 'mm', child: Text('mm')),
              DropdownMenuItem(value: 'm', child: Text('m')),
            ],
            onChanged: (v) => setState(() => _refUnit = v ?? 'mm'),
          ),
        ],
      ),
    );
  }

  Widget _content(DrawingFile f, _FileCache c) {
    switch (f.kind) {
      case 'image':
        return c.image == null
            ? const SizedBox.shrink()
            : CustomPaint(painter: _ImagePainter(c.image!));
      case 'pdf':
        final img = c.pdfPages[_page];
        return img == null
            ? const Center(child: CircularProgressIndicator())
            : CustomPaint(painter: _ImagePainter(img));
      case 'dxf':
      case 'dwg':
        final sc = c.scene!;
        return CustomPaint(
          painter: DxfPainter(sc, c.size!.width / sc.bounds.width),
        );
      default:
        return const SizedBox.shrink();
    }
  }

  Widget _toolbar(DrawingFile? f) {
    Widget sep() => const Padding(
      padding: EdgeInsets.symmetric(horizontal: 6),
      child: SizedBox(
        height: 20,
        child: VerticalDivider(width: 1, color: Color(0xFFE2E8F0)),
      ),
    );
    Widget toolBtn(_Tool t, IconData icon, String tip) {
      final on = _tool == t;
      return IconButton(
        icon: Icon(icon, size: 18),
        tooltip: tip,
        color: on ? Colors.white : const Color(0xFF475569),
        style: IconButton.styleFrom(
          backgroundColor: on ? const Color(0xFF1E4976) : Colors.transparent,
        ),
        onPressed: () => setState(() => _tool = t),
      );
    }

    // one compact popup button for mark color: the icon IS the
    // current swatch, the menu lists swatch + name + a check
    Widget colorBtn() {
      const names = {
        0xFFD32F2F: 'Red',
        0xFF1976D2: 'Blue',
        0xFF388E3C: 'Green',
        0xFF212121: 'Black',
        0xFFF9A825: 'Amber',
      };
      return PopupMenuButton<int>(
        key: _colorMenuKey,
        tooltip: 'Mark color (C)',
        icon: Container(
          width: 20,
          height: 20,
          decoration: BoxDecoration(
            color: Color(_markColor),
            shape: BoxShape.circle,
            border: Border.all(color: const Color(0xFF94A3B8), width: 1.2),
          ),
        ),
        onSelected: (v) => setState(() => _markColor = v),
        itemBuilder: (_) => [
          for (final e in names.entries)
            PopupMenuItem<int>(
              value: e.key,
              height: 38,
              child: Row(
                children: [
                  Container(
                    width: 16,
                    height: 16,
                    decoration: BoxDecoration(
                      color: Color(e.key),
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(e.value, style: const TextStyle(fontSize: 12)),
                  ),
                  if (e.key == _markColor) const Icon(Icons.check, size: 16),
                ],
              ),
            ),
        ],
      );
    }

    // same for stroke thickness: one button, dot preview scales with
    // the current width
    Widget widthBtn() {
      const opts = [(2.0, 'Fine'), (4.0, 'Medium'), (7.0, 'Thick')];
      return PopupMenuButton<double>(
        key: _widthMenuKey,
        tooltip: 'Stroke thickness (S)',
        icon: Center(
          child: Container(
            width: 10 + _markWidth,
            height: 10 + _markWidth,
            decoration: const BoxDecoration(
              color: Color(0xFF475569),
              shape: BoxShape.circle,
            ),
          ),
        ),
        onSelected: (w) => setState(() => _markWidth = w),
        itemBuilder: (_) => [
          for (final e in opts)
            PopupMenuItem<double>(
              value: e.$1,
              height: 38,
              child: Row(
                children: [
                  SizedBox(
                    width: 20,
                    child: Center(
                      child: Container(
                        width: e.$1 + 4,
                        height: e.$1 + 4,
                        decoration: const BoxDecoration(
                          color: Color(0xFF475569),
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(e.$2, style: const TextStyle(fontSize: 12)),
                  ),
                  if (e.$1 == _markWidth) const Icon(Icons.check, size: 16),
                ],
              ),
            ),
        ],
      );
    }

    final canMark =
        f != null && !(_cache(f.id).missing) && _cache(f.id).size != null;
    return Container(
      height: 44,
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: Color(0xFFE2E8F0))),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          children: [
            // step through the loaded files — always visible when the
            // library holds more than one drawing
            if (est.drawings.length > 1) ...[
              IconButton(
                icon: const Icon(Icons.navigate_before, size: 20),
                tooltip: 'Previous file',
                onPressed: _selIndex > 0 ? () => _stepFile(-1) : null,
              ),
              Text(
                '${_selIndex + 1}/${est.drawings.length}',
                style: const TextStyle(fontSize: 11),
              ),
              IconButton(
                icon: const Icon(Icons.navigate_next, size: 20),
                tooltip: 'Next file',
                onPressed: _selIndex < est.drawings.length - 1
                    ? () => _stepFile(1)
                    : null,
              ),
              sep(),
            ],
            toolBtn(_Tool.pan, Icons.open_with, 'Pan / zoom view (V)'),
            // generated sheets only: pan the drawing inside its paper
            // frame — the AutoCAD viewport-pan gesture
            if (f != null && f.id.startsWith('sheet:'))
              toolBtn(
                _Tool.sheet,
                Icons.crop_free,
                'Move drawing on sheet — drag it inside the frame',
              ),
            toolBtn(
              _Tool.select,
              Icons.near_me_outlined,
              'Select / adjust a mark (A)',
            ),
            toolBtn(_Tool.pen, Icons.edit_outlined, 'Pen (P)'),
            toolBtn(_Tool.hi, Icons.brush_outlined, 'Highlighter (H)'),
            toolBtn(_Tool.arrow, Icons.arrow_outward, 'Arrow (B)'),
            toolBtn(_Tool.rect, Icons.crop_square, 'Rectangle (R)'),
            toolBtn(_Tool.text, Icons.text_fields, 'Text note (T)'),
            toolBtn(_Tool.measure, Icons.straighten, 'Measure (M)'),
            toolBtn(
              _Tool.eraser,
              Icons.cleaning_services_outlined,
              'Eraser — click or drag over marks to erase (E)',
            ),
            sep(),
            colorBtn(),
            widthBtn(),
            sep(),
            // per-page measurement state: a hint while the page has no
            // reference, and a reset chip once one is set
            if (_tool == _Tool.measure && _measureRef == null)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 6),
                child: Text(
                  'Drag a known-length line to set the '
                  'reference for this page',
                  style: TextStyle(fontSize: 10.5, color: Color(0xFFB45309)),
                ),
              ),
            if (f != null && _measureRef != null)
              Tooltip(
                message:
                    'Reference for this page: the line you drew '
                    '= ${_fmtLen(_measureRef!.realLen)} '
                    '${_measureRef!.unit} — tap to reset it',
                child: TextButton.icon(
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    foregroundColor: const Color(0xFF1E4976),
                  ),
                  icon: const Icon(Icons.restart_alt, size: 15),
                  label: Text(
                    'Ref ${_fmtLen(_measureRef!.realLen)}'
                    '${_measureRef!.unit}',
                    style: const TextStyle(fontSize: 11),
                  ),
                  onPressed: () => est.clearMeasureRef(f.id, _page),
                ),
              ),
            IconButton(
              icon: const Icon(Icons.undo, size: 18),
              tooltip: 'Undo last mark (Ctrl+Z)',
              onPressed: canMark ? _undoMark : null,
            ),
            IconButton(
              icon: const Icon(Icons.redo, size: 18),
              tooltip: 'Redo mark (Ctrl+Y / Ctrl+R)',
              onPressed: canMark ? _redoMark : null,
            ),
            IconButton(
              icon: const Icon(Icons.delete_sweep_outlined, size: 18),
              tooltip: 'Clear marks on this page',
              onPressed: canMark ? () => est.clearMarks(f.id, _page) : null,
            ),
            sep(),
            IconButton(
              icon: const Icon(Icons.zoom_out, size: 18),
              tooltip: 'Zoom out',
              onPressed: () => _zoomAt(_viewport.center(Offset.zero), 1 / 1.25),
            ),
            ListenableBuilder(
              listenable: _tc,
              builder: (_, _) {
                final info = _sheetScaleInfo;
                return PopupMenuButton<double>(
                  tooltip: info != null
                      ? 'View scale — the sheet plots at 1:${info.$1}'
                      : 'Zoom presets',
                  itemBuilder: (_) => [
                    _scaleItem(-1, 'Fit to window'),
                    _scaleItem(0, 'Actual size (1 sheet-mm = 1 screen-mm)'),
                    const PopupMenuDivider(),
                    if (info != null)
                      for (final n in const [
                        25,
                        50,
                        75,
                        100,
                        150,
                        200,
                        500,
                        1000,
                      ])
                        _scaleItem(_pxPerMm * info.$1 / n / info.$2, '1:$n')
                    else
                      for (final n in const [
                        25,
                        50,
                        75,
                        100,
                        150,
                        200,
                        400,
                        800,
                      ])
                        _scaleItem(n / 100, '$n%'),
                  ],
                  onSelected: (z) {
                    if (z < 0) {
                      _fit();
                    } else if (z == 0) {
                      final i = _sheetScaleInfo;
                      _zoomTo(i != null ? _pxPerMm / i.$2 : 1.0);
                    } else {
                      _zoomTo(z);
                    }
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(_zoomLabel, style: const TextStyle(fontSize: 11)),
                        const Icon(Icons.arrow_drop_down, size: 16),
                      ],
                    ),
                  ),
                );
              },
            ),
            IconButton(
              icon: const Icon(Icons.zoom_in, size: 18),
              tooltip: 'Zoom in',
              onPressed: () => _zoomAt(_viewport.center(Offset.zero), 1.25),
            ),
            IconButton(
              icon: const Icon(Icons.fit_screen, size: 18),
              tooltip: 'Fit to window',
              onPressed: _fit,
            ),
            TextButton(
              onPressed: _zoom100,
              child: const Text('1:1', style: TextStyle(fontSize: 11)),
            ),
            sep(),
            IconButton(
              icon: Icon(
                est.drawingFocus ? Icons.fullscreen_exit : Icons.fullscreen,
                size: 18,
              ),
              tooltip: est.drawingFocus
                  ? 'Exit focus mode'
                  : 'Focus mode — split drawing + BOQ',
              onPressed: () => est.setDrawingFocus(!est.drawingFocus),
            ),
            if (f != null && f.kind == 'pdf' && f.pageCount > 1) ...[
              sep(),
              IconButton(
                icon: const Icon(Icons.chevron_left, size: 18),
                onPressed: _page > 0
                    ? () async {
                        setState(() => _page--);
                        await _renderPdfPage(f, _page);
                        setState(() => _fitOrRestore());
                      }
                    : null,
              ),
              Text(
                '${_page + 1}/${f.pageCount}',
                style: const TextStyle(fontSize: 11),
              ),
              IconButton(
                icon: const Icon(Icons.chevron_right, size: 18),
                onPressed: _page < f.pageCount - 1
                    ? () async {
                        setState(() => _page++);
                        await _renderPdfPage(f, _page);
                        setState(() => _fitOrRestore());
                      }
                    : null,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Draws a ui.Image filling the canvas (already sized to its px size).
class _ImagePainter extends CustomPainter {
  final ui.Image img;
  const _ImagePainter(this.img);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawImageRect(
      img,
      Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
      Rect.fromLTWH(0, 0, size.width, size.height),
      Paint()..filterQuality = FilterQuality.high,
    );
  }

  @override
  bool shouldRepaint(_ImagePainter old) => old.img != img;
}

/// Renders stored marks (normalized coords) scaled to the content size.
/// Annotation strokes scale with the drawing, but a MEASURE overlay —
/// its dimension line, end ticks and label — counter-scales by [zoom]
/// so the readout stays the same size on screen at any magnification.
class _MarksPainter extends CustomPainter {
  final List<DrawingMark> marks;
  final Size size;
  final double zoom;
  const _MarksPainter(this.marks, this.size, {this.zoom = 1});

  Offset _p(double x, double y) => Offset(x * size.width, y * size.height);

  @override
  void paint(Canvas canvas, Size s) {
    for (final m in marks) {
      final col = Color(m.color);
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
      switch (m.kind) {
        case 'pen':
          paint
            ..color = col
            ..strokeWidth = m.width;
          final path = Path()
            ..moveTo(m.pts[0] * size.width, m.pts[1] * size.height);
          for (var i = 2; i + 1 < m.pts.length; i += 2) {
            path.lineTo(m.pts[i] * size.width, m.pts[i + 1] * size.height);
          }
          canvas.drawPath(path, paint);
          break;
        case 'hi':
          paint
            ..color = col.withValues(alpha: .35)
            ..strokeWidth = m.width * 4;
          final path = Path()
            ..moveTo(m.pts[0] * size.width, m.pts[1] * size.height);
          for (var i = 2; i + 1 < m.pts.length; i += 2) {
            path.lineTo(m.pts[i] * size.width, m.pts[i + 1] * size.height);
          }
          canvas.drawPath(path, paint);
          break;
        case 'arrow':
          if (m.pts.length < 4) break;
          paint
            ..color = col
            ..strokeWidth = m.width;
          final a = _p(m.pts[0], m.pts[1]);
          final b = _p(m.pts[2], m.pts[3]);
          canvas.drawLine(a, b, paint);
          final dir = (b - a).direction;
          const head = 14.0;
          for (final off in const [0.45, -0.45]) {
            canvas.drawLine(
              b,
              b + Offset.fromDirection(dir + (3.14159 - 0) + off, head),
              paint,
            );
          }
          break;
        case 'rect':
          if (m.pts.length < 4) break;
          paint
            ..color = col
            ..strokeWidth = m.width;
          canvas.drawRect(
            Rect.fromPoints(_p(m.pts[0], m.pts[1]), _p(m.pts[2], m.pts[3])),
            paint,
          );
          break;
        case 'measure':
          if (m.pts.length < 4) break;
          // zoom is the canvas->screen scale: divide so line, ticks and
          // label stay constant screen sizes at every magnification
          final z = zoom <= 0 ? 1.0 : zoom;
          final a = _p(m.pts[0], m.pts[1]);
          final b = _p(m.pts[2], m.pts[3]);
          final dir = (b - a).direction;
          paint
            ..color = col
            ..strokeWidth = max(m.width * .8, 1.4) / z;
          canvas.drawLine(a, b, paint);
          // perpendicular end ticks — the dimension-line look
          final tick = 9.0 / z;
          for (final p in [a, b]) {
            canvas.drawLine(
              p + Offset.fromDirection(dir + pi / 2, tick),
              p + Offset.fromDirection(dir - pi / 2, tick),
              paint,
            );
          }
          if (m.text.isNotEmpty) {
            final fs = (m.width * 3.4).clamp(11.0, 46.0) / z;
            final tp = TextPainter(
              text: TextSpan(
                text: m.text,
                style: TextStyle(
                  color: col,
                  fontSize: fs,
                  fontWeight: FontWeight.w700,
                  backgroundColor: Colors.white.withValues(alpha: .8),
                ),
              ),
              textDirection: TextDirection.ltr,
            )..layout();
            // above the midpoint — the perpendicular that points up
            var n = Offset(-(b - a).dy, (b - a).dx);
            if (n.distance > 0 && n.dy > 0) n = -n;
            final up = n.distance == 0
                ? const Offset(0, -1)
                : n / n.distance * (fs * .9 + 4);
            final mid = (a + b) / 2;
            tp.paint(canvas, mid + up - Offset(tp.width / 2, tp.height / 2));
          }
          break;
        case 'text':
          if (m.pts.length < 2 || m.text.isEmpty) break;
          final tp = TextPainter(
            text: TextSpan(
              text: m.text,
              style: TextStyle(
                color: col,
                fontSize: m.width.clamp(10.0, 60.0),
                fontWeight: FontWeight.w600,
              ),
            ),
            textDirection: TextDirection.ltr,
            maxLines: 8,
          )..layout(maxWidth: size.width * .5);
          tp.paint(canvas, _p(m.pts[0], m.pts[1]));
          break;
      }
    }
  }

  @override
  bool shouldRepaint(_MarksPainter old) => true;
}

/// Paints the selection chrome for the mark being adjusted: a dashed
/// bounding outline plus draggable handle dots. Dashes, ring width and
/// handle radius counter-scale by [zoom] — the chrome stays ~14 screen
/// px (matching `_pickTol`) instead of blowing up when zoomed in.
class _SelPainter extends CustomPainter {
  _SelPainter(this.mark, this.s, this.handlesFor, {this.zoom = 1});

  final DrawingMark mark;
  final Size s;
  final double zoom;
  final List<Offset> Function(DrawingMark, Size) handlesFor;

  @override
  void paint(Canvas canvas, Size size) {
    final z = zoom <= 0 ? 1.0 : zoom;
    final outline = Paint()
      ..style = PaintingStyle.stroke
      ..color = const Color(0xFF1E4976)
      ..strokeWidth = 1.2 / z;
    // bounding box of the mark's points, expanded a little for text
    var l = mark.pts[0], t = mark.pts[1], r = mark.pts[0], b = mark.pts[1];
    for (var i = 0; i + 1 < mark.pts.length; i += 2) {
      l = min(l, mark.pts[i]);
      r = max(r, mark.pts[i]);
      t = min(t, mark.pts[i + 1]);
      b = max(b, mark.pts[i + 1]);
    }
    var rect = Rect.fromLTRB(
      l * s.width,
      t * s.height,
      r * s.width,
      b * s.height,
    );
    if (mark.kind == 'text') {
      final tp = TextPainter(
        text: TextSpan(
          text: mark.text,
          style: TextStyle(
            fontSize: mark.width.clamp(10.0, 60.0),
            fontWeight: FontWeight.w600,
          ),
        ),
        textDirection: TextDirection.ltr,
        maxLines: 8,
      )..layout(maxWidth: s.width * .5);
      rect = Rect.fromLTWH(rect.left, rect.top, tp.width, tp.height);
    }
    rect = rect.inflate(4 / z);
    // dashed outline
    final dash = 6.0 / z, gap = 4.0 / z;
    void dashedLine(Offset a, Offset c) {
      final d = c - a, len = d.distance;
      if (len == 0) return;
      final dir = d / len;
      var x = 0.0;
      while (x < len) {
        final e = min(x + dash, len);
        canvas.drawLine(a + dir * x, a + dir * e, outline);
        x = e + gap;
      }
    }

    dashedLine(rect.topLeft, rect.topRight);
    dashedLine(rect.topRight, rect.bottomRight);
    dashedLine(rect.bottomRight, rect.bottomLeft);
    dashedLine(rect.bottomLeft, rect.topLeft);
    // handle dots
    final fill = Paint()..color = Colors.white;
    final ring = Paint()
      ..color = const Color(0xFF1E4976)
      ..strokeWidth = 1.4 / z
      ..style = PaintingStyle.stroke;
    for (final h in handlesFor(mark, s)) {
      canvas.drawCircle(h, 5 / z, fill);
      canvas.drawCircle(h, 5 / z, ring);
    }
  }

  @override
  bool shouldRepaint(_SelPainter old) => true;
}

/// Tap/hover chrome for the generated-sheet title-block cells — a
/// click cursor plus a faint highlight ring so the hotspots are
/// discoverable. Lives in sheet space, so the ring scales with zoom.
class _CellHover extends StatefulWidget {
  const _CellHover({
    super.key,
    required this.child,
    required this.onTap,
    this.onSecondary,
  });
  final Widget child;
  final VoidCallback onTap;
  final void Function(Offset globalPos)? onSecondary;

  @override
  State<_CellHover> createState() => _CellHoverState();
}

class _CellHoverState extends State<_CellHover> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) => MouseRegion(
    cursor: SystemMouseCursors.click,
    onEnter: (_) => setState(() => _hover = true),
    onExit: (_) => setState(() => _hover = false),
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onTap,
      onSecondaryTapUp: widget.onSecondary == null
          ? null
          : (d) => widget.onSecondary!(d.globalPosition),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: _hover
              ? const Color(0xFF1E4976).withValues(alpha: .08)
              : null,
          border: _hover
              ? Border.all(color: const Color(0xFF1E4976), width: .6)
              : null,
        ),
        child: widget.child,
      ),
    ),
  );
}
