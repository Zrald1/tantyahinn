import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show ClipOp, Picture, PictureRecorder;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../ai_render.dart';
import '../model3d.dart';
import '../models.dart';
import '../ifc.dart';
import '../obj.dart';
import '../open_file.dart';
import '../render.dart';
import '../state.dart';
import '../structural.dart';
import '../takeoff.dart';

/// 3D MODEL tab — a SketchUp-lite workspace. Draw footprints on the
/// plan grid (left), orbit the extruded solid (right), then one click
/// generates the floor plan + four elevations + roof plan as a real
/// DXF in the DRAWINGS library.
part 'mv_gesture.dart';
part 'mv_panels.dart';
part 'mv_inspect.dart';
part 'mv_paint.dart';
part 'mv_render.dart';
part 'mv_render_dlg.dart';
part 'mv_block_preview.dart';

class ModelView extends StatefulWidget {
  const ModelView({super.key});

  @override
  State<ModelView> createState() => _ModelViewState();
}

enum _MTool { select, rect, poly, wall, block, eraser, dim, move, rotate }

/// Viewport layout mode: plan-only / side-by-side split / 3D-only.
/// Keys 1/2/3 and the per-pane maximize buttons drive it (F toggles
/// 3D focus as before).
enum _Vp { plan, split, model }

class _ModelViewState extends State<ModelView> {
  Model3d? _sel;
  Volume3d? _vol;
  Wall3d? _wallSel;
  Block3d? _blkSel;
  _MTool _tool = _MTool.wall;
  _MTool _seenTool = _MTool.wall, _lastTool = _MTool.wall;

  /// CAD MOVE command (M): the block being carried between a pick
  /// click and a place click. Position is only mutated on drop, so
  /// releasing it (Esc/tool switch) never needs an undo.
  Block3d? _moving;
  bool _snap = true;
  bool _dims = true; // plan measurements: wall segs + block W×D labels
  int _unit = 0; // dimension unit: 0=m 1=ft 2=in (toolbar cycles)

  /// AutoCAD-style direct distance entry: digits typed while a wall/
  /// poly chain is open constrain the next point to exactly that
  /// length along the cursor direction (Enter or click commits)
  String _dimIn = '';

  /// Eraser tool state: a drag-sweep deletes on contact; one undo
  /// snapshot covers the whole stroke
  bool _erasing = false;
  bool _erasePushed = false;

  /// DIM tool drag state: snapped world endpoints of the in-progress
  /// aligned dimension (A = drag start, B = cursor)
  Offset? _dimA, _dimB;

  // plan editor transform: screen = off + world*scale (y flipped)
  double _pScale = 40;
  Offset _pOff = const Offset(60, 60);
  Offset? _rect0, _rectCur;
  final List<Offset> _poly = [];
  final List<Offset> _wall = []; // in-progress wall chain (world)
  Offset _hover = Offset.zero;
  Offset? _moveLast; // last screen pos while moving a selection
  Offset? _panLast; // last screen pos while panning the plan
  Offset? _midPan; // middle-button pan anchor (screen space)
  Offset? _lpPan; // long-press on empty plan space -> pan anchor
  Offset? _lpLast3; // last long-press pos on 3D (orbit delta source)
  bool _lpOrbit = false; // long-press on empty 3D space -> orbit
  // true while _moving was armed by a LONG-PRESS grab — cancel/end
  // only release a carry the gesture itself started (a quick tap's
  // long-press LOSS must not cancel an M-command carry)
  bool _lpCarry = false;
  bool _overPart = false; // select tool: a part sits under the plan cursor
  bool _overPart3 = false; // select tool: a part sits under the 3D cursor
  bool _drag3 = false; // a left-drag (orbit or pan) is in progress on 3D
  Offset _pickAt3 = Offset.infinite; // last _pick3-eval spot (8px throttle)
  // bounding-box scale gizmo on the selected block: 0..5 = +x,-x,+y,-y,
  // +z,-z face handles. _stretchAxis != -1 while a handle drag runs;
  // _overHandle caches the hovered handle index for the cursor map.
  int _stretchAxis = -1;
  int _overHandle = -1;
  List<Offset> _handles3 = const []; // screen pts, same order as axes
  List<List<double>> _box3Pts = const []; // 8 world corners of sel bbox
  bool _midBlock =
      false; // suppress the tap/pan-end a middle-drag leaves behind
  final _keyFocus = FocusNode();

  // wall settings — apply to new walls and the selected wall
  double _wallT = 0.15;
  final double _wallH = 2.7;

  // block placement state
  CadBlock _blkDef = kCadBlocks.first;
  double _blkRot = 0;

  // ROTATE command (G): _rotating carries the picked block — its real
  // rot is untouched until the commit click; the ghost previews
  // rot + (cursorAngle - _rotAnchor) + _rotBias (free rotation)
  Block3d? _rotating;
  double? _rotAnchor; // cursor->centre angle when the spin started
  double _rotBias = 0; // wheel fine-tune while carrying

  // right panel: 0 = PROPERTIES, 1 = LIBRARY (default — the CAD
  // blocks live here per the dwgmodels-style palette request)
  int _rightTab = 1;
  final _libSearch = TextEditingController();

  // 3D orbit state
  double _yaw = -0.7, _pitch = 0.55, _z3 = 30;
  Offset _o3 = Offset.zero;
  // per-build epoch: `_orbitFocus` caches against it so a paint pass
  // never recomputes model bounds per projected vertex (frame-lag fix)
  int _buildNo = 0;
  List<double>? _orbitCache;
  int _orbitBuild = -1;

  // 3D SCENE LAYER CACHE (frame-coherence — see docs/PERF_CAMPAIGN_3D):
  // the whole static layer (sky, slab, grid, axes, ground shadow,
  // depth-sorted solids) is recorded into ONE Picture and replayed via
  // drawPicture while the camera + geometry signature is unchanged —
  // ~14x faster than re-projecting ~50k verts on every hover repaint.
  Picture? _scenePic;
  Object? _sceneModel; // the Model3d the layer was built from
  Object? _sceneSrc; // the identical() cachedFaces list it used
  int _sceneSig = 0; // camera+viewport+render signature at build time

  @visibleForTesting
  Offset get planOffset => _pOff;
  @visibleForTesting
  double get planScale => _pScale;
  @visibleForTesting
  Offset get camOffset => _o3;
  @visibleForTesting
  double get camYaw => _yaw;
  @visibleForTesting
  double get camPitch => _pitch;
  @visibleForTesting
  bool get renderEnabled => _render;
  @visibleForTesting
  Model3d? get selectedModelDebug => _sel;
  @visibleForTesting
  bool get midBlockDebug => _midBlock;
  @visibleForTesting
  Offset? get planPanLast => _panLast;
  @visibleForTesting
  Offset? get midPanDebug => _midPan;
  @visibleForTesting
  Object? get movingDebug => _moving;
  @visibleForTesting
  Object? get toolDebug => _tool;
  @visibleForTesting
  List<Offset> get wallChainDebug => _wall;
  bool get paneActivePlanDebug => _paneActivePlan;
  @visibleForTesting
  void armBlockDebug(CadBlock b) => setState(() => _blkDef = b);
  @visibleForTesting
  Offset debugProjGround(Offset w) => _projGround(w);
  @visibleForTesting
  Offset debugProj3(double x, double y, double z) => _proj3([x, y, z], _vp3);
  Size _vp3 = Size.zero; // last 3D viewport (for unprojection)
  Size? _lastVp; // last plan viewport (refit on resize)
  Offset? _hover3; // cursor pos on the 3D canvas (screen space)
  bool _inPlan = false; // pointer currently over the plan canvas
  bool _activePlan = true; // last pane the pointer entered — drives selection
  // saturation: the ACTIVE pane draws the accent outline+handles at
  // full strength, the other pane shows a desaturated ghost of it
  bool get _paneActivePlan =>
      _vp == _Vp.plan || (_vp == _Vp.split && _activePlan);
  _Vp _vp = _Vp.split; // viewport layout mode (keys 1/2/3, pane buttons)
  bool _hud = false; // shortcut cheat-sheet overlay (? / F1)
  // draft mode is the lightweight working view: cached faces +
  // wire strokes. _render flips on the simple "V-Ray-lite" pass —
  // sky backdrop, sun-projected ground shadows, wider shading range,
  // no wireframe — meant for look-checking once modeling is done.
  bool _render = false;

  /// Clipboard: (kind, serialized part) — 'block' | 'wall' | 'volume'.
  /// Parts copy through their JSON form so every field (footing
  /// settings, stretch, tint...) carries over without a hand list.
  (String, Map<String, dynamic>)? _clip;

  // undo — snapshots of the selected model's json before every
  // structural op (create/close/delete/move/commit)
  final List<String> _undo = [];
  void _pushUndo() {
    final m = _sel;
    if (m == null) return;
    _undo.add(jsonEncode(m.toJson()));
    if (_undo.length > 60) _undo.removeAt(0);
  }

  void _undoOp() {
    final m = _sel;
    if (m == null || _undo.isEmpty) return;
    final snap = Model3d.fromJson(
      jsonDecode(_undo.removeLast()) as Map<String, dynamic>,
    );
    setState(() {
      m.volumes
        ..clear()
        ..addAll(snap.volumes);
      m.walls
        ..clear()
        ..addAll(snap.walls);
      m.blocks
        ..clear()
        ..addAll(snap.blocks);
      _clearSel();
      _wall.clear();
      _poly.clear();
      _rect0 = _rectCur = null;
    });
    est.update();
  }

  @override
  void initState() {
    super.initState();
    if (_sel == null && est.models.isNotEmpty) {
      _sel = est.models[est.modelSel.clamp(0, est.models.length - 1).toInt()];
    }
    // restore the camera from the last visit — tab switches dispose
    // this State, so pan/zoom/orbit live in `est` between mounts
    // (same contract as drawingXfms on the DRAWINGS tab)
    final cam = est.modelCam;
    if (cam.isNotEmpty) {
      _pScale = cam['pScale'] ?? _pScale;
      _pOff = Offset(cam['pOffX'] ?? _pOff.dx, cam['pOffY'] ?? _pOff.dy);
      _yaw = cam['yaw'] ?? _yaw;
      _pitch = cam['pitch'] ?? _pitch;
      _z3 = cam['z3'] ?? _z3;
      _o3 = Offset(cam['o3x'] ?? _o3.dx, cam['o3y'] ?? _o3.dy);
      _vp =
          _Vp.values[(cam['vp'] ?? _vp.index.toDouble())
              .round()
              .clamp(0, _Vp.values.length - 1)
              .toInt()];
    }
    // an empty project stays honest — `_ensureModel` lazily creates
    // Model 1 on the FIRST canvas interaction instead of polluting a
    // project the user only opened to look at
  }

  // library drag-drop: the canvas drop contexts (captured inside each
  // DragTarget's builder) turn a global drop offset into local px
  BuildContext? _planDropCtx;
  BuildContext? _modelDropCtx;

  /// A library row dropped onto a canvas places the block at the drop
  /// point — the sketchup component-palette drag gesture the user
  /// asked for ("easily insert the furnitures").
  void _dropBlock(CadBlock def, Offset global, bool plan) {
    final ctx = plan ? _planDropCtx : _modelDropCtx;
    final rb = ctx?.findRenderObject() as RenderBox?;
    if (rb == null) return;
    final local = rb.globalToLocal(global);
    if (plan) {
      _placeBlock(def, _snapPt(_s2w(local, rb.size), _pScale).p);
    } else {
      if (!_groundEditable) return; // flat pitch can't unproject
      _placeBlock(def, _snapPt(_s2g(local, _vp3), _z3, _projGround).p);
    }
    _blkDef = def; // keep armed for the next drop
  }

  /// Wraps a viewport: accepts `CadBlock` drags from the library and
  /// drops them as placed parts at the drop point.
  Widget _blockDrop(bool plan, Widget child) => DragTarget<CadBlock>(
    onAcceptWithDetails: (d) => _dropBlock(d.data, d.offset, plan),
    builder: (ctx, cand, _) {
      if (plan) {
        _planDropCtx = ctx;
      } else {
        _modelDropCtx = ctx;
      }
      return Container(
        decoration: cand.isEmpty
            ? const BoxDecoration()
            : BoxDecoration(
                border: Border.all(color: const Color(0xFF2563EB), width: 2.5),
              ),
        child: child,
      );
    },
  );

  /// Drops a stale model selection (e.g. after File > New cleared
  /// `est.models`); otherwise the canvases keep drawing the deleted
  /// model — the "New doesn't clear the 3D view" bug.
  void _fixSel() {
    if (_sel != null && !est.models.contains(_sel)) {
      _sel = est.models.isEmpty ? null : est.models.first;
      _undo.clear();
      _vol = null;
      _wallSel = null;
      _blkSel = null;
      _moving = null;
      _poly.clear();
      _wall.clear();
      _rect0 = _rectCur = null;
    }
  }

  @override
  void dispose() {
    // remember the viewport for the next mount — est outlives the
    // State across tab switches
    est.modelCam
      ..['pScale'] = _pScale
      ..['pOffX'] = _pOff.dx
      ..['pOffY'] = _pOff.dy
      ..['yaw'] = _yaw
      ..['pitch'] = _pitch
      ..['z3'] = _z3
      ..['o3x'] = _o3.dx
      ..['o3y'] = _o3.dy
      ..['vp'] = _vp.index.toDouble();
    final sel = _sel;
    if (sel != null) {
      final i = est.models.indexOf(sel);
      if (i >= 0) est.modelSel = i;
    }
    _scenePic?.dispose();
    _keyFocus.dispose();
    _libSearch.dispose();
    super.dispose();
  }

  // ---------- model / selection ----------

  void _newModel() {
    final m = est.addModel('Model ${est.models.length + 1}');
    setState(() {
      _sel = m;
      _undo.clear(); // undo stack is scoped to the selected model
      _vol = null;
      _wallSel = null;
      _blkSel = null;
      _moving = null;
      _poly.clear();
      _wall.clear();
      _rect0 = _rectCur = null;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _fitPlan());
  }

  void _deleteModel(Model3d m) {
    est.removeModel(m);
    if (_sel == m) {
      setState(() {
        _sel = null;
        _undo.clear();
        _vol = null;
        _wallSel = null;
        _blkSel = null;
        _moving = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_tool != _seenTool) {
      if (_seenTool != _MTool.select) _lastTool = _seenTool;
      _seenTool = _tool;
    }
    final cs = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: est,
      builder: (context, _) {
        // tick HERE (not in build): est.update() rebuilds painters via
        // this callback alone, so this is the only boundary every
        // paint-producing rebuild passes through
        ++_buildNo;
        _fixSel();
        return Row(
          children: [
            _rail(cs),
            const VerticalDivider(width: 1),
            Expanded(
              child: Column(
                children: [
                  _toolbar(cs),
                  Expanded(
                    child: Stack(
                      children: [
                        // FOCUS MODE (F): the 3D canvas takes the whole
                        // content area so the user models undistracted —
                        // rail + right panel stay reachable. The shortcuts
                        // wrapper lives OUTSIDE the split so keys survive
                        // the plan canvas unmounting.
                        Positioned.fill(
                          child: CallbackShortcuts(
                            bindings: _keys(),
                            child: Focus(
                              focusNode: _keyFocus,
                              // space/shift transitions change the canvas
                              // cursor map — rebuild so the MouseRegions
                              // re-evaluate `cursor:` (read at build time).
                              // Ignored so the key keeps reaching the
                              // shortcuts/pan modifiers.
                              onKeyEvent: (node, e) {
                                if (e is KeyDownEvent && _dimKey(e)) {
                                  return KeyEventResult.handled;
                                }
                                if (e is KeyDownEvent &&
                                    e.logicalKey == LogicalKeyboardKey.space &&
                                    _tool == _MTool.select &&
                                    _wall.isEmpty &&
                                    _poly.isEmpty) {
                                  setState(() => _tool = _lastTool);
                                  return KeyEventResult.handled;
                                }
                                if (e.logicalKey == LogicalKeyboardKey.space ||
                                    e.logicalKey ==
                                        LogicalKeyboardKey.shiftLeft ||
                                    e.logicalKey ==
                                        LogicalKeyboardKey.shiftRight) {
                                  setState(() {});
                                }
                                return KeyEventResult.ignored;
                              },
                              child: _vp == _Vp.model
                                  ? _modelCanvas(cs)
                                  : _vp == _Vp.plan
                                  ? _planCanvas(cs)
                                  : LayoutBuilder(
                                      builder: (context, c) {
                                        const divW = 10.0;
                                        final avail = (c.maxWidth - divW).clamp(
                                          160.0,
                                          1e9,
                                        );
                                        // plan keeps >=240px, 3D keeps >=280px
                                        // (upper floored so tiny widths can't
                                        // invert the clamp)
                                        final planW =
                                            (avail * est.modelSplitFrac)
                                                .clamp(
                                                  240.0,
                                                  math.max(
                                                    240.0,
                                                    avail - 280.0,
                                                  ),
                                                )
                                                .toDouble();
                                        return Row(
                                          children: [
                                            SizedBox(
                                              width: planW,
                                              child: _planCanvas(cs),
                                            ),
                                            _splitter(cs, avail),
                                            SizedBox(
                                              width: avail - planW,
                                              child: _modelCanvas(cs),
                                            ),
                                          ],
                                        );
                                      },
                                    ),
                            ),
                          ),
                        ),
                        // shortcut cheat sheet (? / F1 / toolbar ?) —
                        // floats over the viewports, Esc closes it first
                        if (_hud)
                          Positioned(top: 10, right: 10, child: _hudCard(cs)),
                      ],
                    ),
                  ),
                  _statusStrip(cs),
                ],
              ),
            ),
            const VerticalDivider(width: 1),
            _inspector(cs),
          ],
        );
      },
    );
  }

  bool _splitHover = false;

  String _fmtNum(double v) => v.toStringAsFixed(v < 10 ? 2 : 1);

  // ---------- plan canvas ----------

  /// Keyboard contract — hoisted above the plan/3D split so keys keep
  /// working in 3D focus mode (the plan canvas unmounts there).
  Map<ShortcutActivator, VoidCallback> _keys() => {
    const SingleActivator(LogicalKeyboardKey.escape): _esc,
    const SingleActivator(LogicalKeyboardKey.enter): () {
      if (_tool == _MTool.poly) {
        _closePoly();
      } else if (_tool == _MTool.wall) {
        _closeWall();
      }
    },
    const SingleActivator(LogicalKeyboardKey.delete): _delVol,
    const SingleActivator(LogicalKeyboardKey.backspace): _delVol,
    const SingleActivator(LogicalKeyboardKey.keyA): () =>
        setState(() => _tool = _MTool.select),
    const SingleActivator(LogicalKeyboardKey.keyR): () => setState(() {
      if (_moving != null) {
        _moving!.rot += math.pi / 12; // carried block spins in the ghost
      } else if (_tool == _MTool.block || _blkSel != null) {
        _blkRot += math.pi / 12;
        final b = _blkSel;
        if (b != null) {
          b.rot = _blkRot;
          est.update();
        }
      } else {
        _tool = _MTool.rect;
      }
    }),
    const SingleActivator(LogicalKeyboardKey.keyP): () =>
        setState(() => _tool = _MTool.poly),
    const SingleActivator(LogicalKeyboardKey.keyW): () =>
        setState(() => _tool = _MTool.wall),
    const SingleActivator(LogicalKeyboardKey.keyB): () =>
        setState(() => _tool = _MTool.block),
    const SingleActivator(LogicalKeyboardKey.keyE): () =>
        setState(() => _tool = _MTool.eraser),
    const SingleActivator(LogicalKeyboardKey.keyM): () => setState(() {
      _tool = _MTool.move;
      // a selected block is picked up straight away - CAD MOVE
      // reads the current selection, no re-click needed
      _moving = _blkSel;
    }),
    const SingleActivator(LogicalKeyboardKey.keyG): () => setState(() {
      _tool = _MTool.rotate;
      // never auto-spin: rotation only engages after the user CLICKS
      // a specific object — a bare G press just arms the picker
      _rotating = null;
      _rotAnchor = null;
      _rotBias = 0;
    }),
    const SingleActivator(LogicalKeyboardKey.keyD): () =>
        setState(() => _tool = _MTool.dim),
    const SingleActivator(LogicalKeyboardKey.keyF): () =>
        setState(() => _vp = _vp == _Vp.model ? _Vp.split : _Vp.model),
    // viewport modes — SketchUp/Rayon-style pane maximization
    const SingleActivator(LogicalKeyboardKey.digit1): () =>
        setState(() => _vp = _Vp.plan),
    const SingleActivator(LogicalKeyboardKey.digit2): () =>
        setState(() => _vp = _Vp.split),
    const SingleActivator(LogicalKeyboardKey.digit3): () =>
        setState(() => _vp = _Vp.model),
    const SingleActivator(LogicalKeyboardKey.keyZ, control: true): _undoOp,
    // clipboard — copy/cut the selected part, paste at the pointer
    const SingleActivator(LogicalKeyboardKey.keyC, control: true): _copySel,
    const SingleActivator(LogicalKeyboardKey.keyX, control: true): _cutSel,
    const SingleActivator(LogicalKeyboardKey.keyV, control: true): _pasteClip,
    // ? = shift+/, F1 — the shortcut cheat sheet
    const SingleActivator(LogicalKeyboardKey.slash, shift: true): () =>
        setState(() => _hud = !_hud),
    const SingleActivator(LogicalKeyboardKey.f1): () =>
        setState(() => _hud = !_hud),
  };

  Widget _planCanvas(ColorScheme cs) {
    return _blockDrop(
      true,
      LayoutBuilder(
        builder: (context, box) {
          final vp = Size(box.maxWidth, box.maxHeight);
          _lastVp = vp;
          return Container(
            color: const Color(0xFFCBD5E1),
            child: Stack(
              children: [
                Positioned.fill(
                  child: Listener(
                    onPointerDown: (e) {
                      // a fresh press ends the stale-tap swallow window
                      _midBlock = false;
                      _keyFocus.requestFocus();
                      // CAD convention: middle-button drag pans any time
                      if (e.buttons & kMiddleMouseButton != 0) {
                        _midPan = e.localPosition;
                      }
                    },
                    onPointerMove: (e) {
                      final l = _midPan;
                      if (l != null && e.buttons & kMiddleMouseButton != 0) {
                        setState(() {
                          _pOff += e.localPosition - l;
                          _midPan = e.localPosition;
                        });
                      }
                    },
                    onPointerUp: (_) {
                      if (_midPan != null) {
                        _midPan = null;
                        // swallow the stale tap/pan-end this release may
                        // still fire — cleared on the next pointer down
                        _midBlock = true;
                      }
                    },
                    onPointerCancel: (_) => _midPan = null,
                    onPointerSignal: (e) {
                      if (e is PointerScrollEvent) {
                        // a carried block (M / long-press) rotates on the
                        // wheel instead of zooming — drop then resumes it;
                        // a rotate-carry (G) gets 15deg fine-tune bias
                        if (_moving != null) {
                          setState(
                            () => _moving!.rot +=
                                (e.scrollDelta.dy < 0 ? 1 : -1) * math.pi / 12,
                          );
                          return;
                        }
                        if (_rotating != null) {
                          setState(
                            () => _rotBias +=
                                (e.scrollDelta.dy < 0 ? 1 : -1) * math.pi / 12,
                          );
                          return;
                        }
                        _zoomPlan(
                          e.localPosition,
                          e.scrollDelta.dy < 0 ? 1.15 : 1 / 1.15,
                        );
                      }
                    },
                    onPointerHover: (e) {
                      final w = _s2w(e.localPosition, vp);
                      setState(() {
                        _hover = w;
                        _overPart = _tool == _MTool.select
                            ? (_blkAt(w) != null ||
                                  _wallAt(w) != null ||
                                  _volAt(w) != null)
                            : (_tool == _MTool.move && _moving == null) ||
                                  (_tool == _MTool.rotate && _rotating == null)
                            ? _blkAt(w) != null
                            : false;
                      });
                    },
                    child: MouseRegion(
                      key: const Key('planMouse'),
                      onEnter: (_) => setState(() {
                        _inPlan = true;
                        _activePlan = true;
                      }),
                      onExit: (_) => setState(() => _inPlan = false),
                      // cursor map (SketchUp/Revit): any active drag ->
                      // SIZEALL move; space armed -> hand; select -> hand
                      // over a part, plain arrow elsewhere; draw tools ->
                      // precise crosshair. Windows supports only a subset
                      // of SystemMouseCursors (grab/grabbing fall back to
                      // the arrow), so the hand is `click` and drags are
                      // `move`/`allScroll`.
                      cursor:
                          _midPan != null ||
                              _panLast != null ||
                              _moveLast != null
                          ? SystemMouseCursors.move
                          : HardwareKeyboard.instance.isLogicalKeyPressed(
                              LogicalKeyboardKey.space,
                            )
                          ? SystemMouseCursors.click
                          : _tool == _MTool.eraser
                          ? SystemMouseCursors.none
                          : _tool == _MTool.move
                          ? SystemMouseCursors.move
                          : _tool == _MTool.rotate
                          ? (_rotating != null
                                ? SystemMouseCursors.allScroll
                                : _overPart
                                ? SystemMouseCursors.click
                                : SystemMouseCursors.basic)
                          : _tool == _MTool.select
                          ? (_overPart
                                ? SystemMouseCursors.click
                                : SystemMouseCursors.basic)
                          : SystemMouseCursors.precise,
                      child: GestureDetector(
                        key: const Key('modelPlan'),
                        behavior: HitTestBehavior.opaque,
                        dragStartBehavior: DragStartBehavior.down,
                        onPanStart: (d) => _planStart(d.localPosition, vp),
                        onPanUpdate: (d) => _planUpdate(d.localPosition, vp),
                        onPanEnd: (_) => _planEnd(),
                        onTapUp: (d) => _planTap(d.localPosition, vp),
                        onLongPressStart: (d) =>
                            _planLpStart(d.localPosition, vp),
                        onLongPressMoveUpdate: (d) =>
                            _planLpUpdate(d.localPosition, vp),
                        onLongPressEnd: (d) => _planLpEnd(d.localPosition, vp),
                        onLongPressCancel: _planLpCancel,
                        child: ClipRect(
                          child: CustomPaint(
                            painter: _PlanPainter(
                              this,
                              cs,
                              MediaQuery.devicePixelRatioOf(context),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                // fit + viewport maximize — mirrors the 3D pane's
                // top-right icon row (Rayon/ArchiCAD pane control)
                Positioned(
                  right: 8,
                  top: 8,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.fit_screen, size: 18),
                        tooltip: 'Fit plan (zoom extents)',
                        visualDensity: VisualDensity.compact,
                        onPressed: () => _fitPlan(vp),
                      ),
                      IconButton(
                        icon: Icon(
                          _vp == _Vp.plan
                              ? Icons.fullscreen_exit
                              : Icons.fullscreen,
                          size: 18,
                        ),
                        tooltip: _vp == _Vp.plan
                            ? 'Back to split view (2)'
                            : 'Maximize plan (1)',
                        visualDensity: VisualDensity.compact,
                        onPressed: () => setState(
                          () => _vp = _vp == _Vp.plan ? _Vp.split : _Vp.plan,
                        ),
                      ),
                    ],
                  ),
                ),
                Positioned(
                  right: 10,
                  bottom: 8,
                  child: Text(
                    _vp == _Vp.plan ? 'PLAN FOCUS' : 'PLAN VIEW',
                    style: const TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.2,
                      color: Color(0xFF64748B),
                    ),
                  ),
                ),
                // SketchUp-instructor onboarding for an empty model:
                // docked TOP-LEFT so the canvas center stays free for
                // the first wall points — a centered card would eat
                // the very taps it teaches. Its own rect eats input;
                // the rest of the canvas stays live
                if (_sel != null &&
                    _sel!.bounds == null &&
                    !est.modelIntroDismissed)
                  Positioned(left: 10, top: 10, child: _onboardCard(cs)),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _modelCanvas(ColorScheme cs) {
    return _blockDrop(
      false,
      LayoutBuilder(
        builder: (context, box) {
          _vp3 = Size(box.maxWidth, box.maxHeight);
          return Container(
            color: const Color(0xFFE9EDF0),
            child: Stack(
              children: [
                Positioned.fill(
                  child: MouseRegion(
                    key: const Key('m3dMouse'),
                    opaque: false,
                    // cursor map: any drag (mid-pan, shift-pan or plain
                    // orbit) -> SIZEALL move; shift armed -> move; select
                    // -> hand over a part else arrow; draw tools ->
                    // precise crosshair
                    cursor:
                        _midPan != null ||
                            _drag3 ||
                            HardwareKeyboard.instance.isShiftPressed
                        ? SystemMouseCursors.move
                        : _stretchAxis >= 0 || _overHandle >= 0
                        ? (_overHandle >= 4 || _stretchAxis >= 4
                              ? SystemMouseCursors.resizeUpDown
                              : SystemMouseCursors.resizeLeftRight)
                        : _tool == _MTool.eraser
                        ? SystemMouseCursors.none
                        : _tool == _MTool.move
                        ? SystemMouseCursors.move
                        : _tool == _MTool.rotate
                        ? (_rotating != null
                              ? SystemMouseCursors.allScroll
                              : _overPart3
                              ? SystemMouseCursors.click
                              : SystemMouseCursors.basic)
                        : _tool == _MTool.select
                        ? (_overPart3
                              ? SystemMouseCursors.click
                              : SystemMouseCursors.basic)
                        : SystemMouseCursors.precise,
                    // onEnter (not just onPointerHover): the MouseTracker
                    // fires enter on the FIRST event at a spot — including
                    // pointer-down — so clicking/selecting in 3D claims
                    // the active pane even when no hover precedes it
                    onEnter: (_) => setState(() => _activePlan = false),
                    onExit: (_) => setState(() => _hover3 = null),
                    child: Listener(
                      onPointerSignal: (e) {
                        if (e is PointerScrollEvent) {
                          // carried block (M / long-press): wheel rotates
                          // it 15deg/step instead of zooming the camera;
                          // rotate-carry (G) gets the same fine-tune bias
                          if (_moving != null) {
                            setState(
                              () => _moving!.rot +=
                                  (e.scrollDelta.dy < 0 ? 1 : -1) *
                                  math.pi /
                                  12,
                            );
                            return;
                          }
                          if (_rotating != null) {
                            setState(
                              () => _rotBias +=
                                  (e.scrollDelta.dy < 0 ? 1 : -1) *
                                  math.pi /
                                  12,
                            );
                            return;
                          }
                          // zoom-to-cursor: keep the world point under
                          // the pointer fixed (same scheme as _zoomPlan;
                          // _o3 is relative to the viewport center, so
                          // shift the focal point by vc first)
                          final nz =
                              (_z3 * (e.scrollDelta.dy < 0 ? 1.15 : 1 / 1.15))
                                  .clamp(3.0, 600.0);
                          final t = nz / _z3;
                          final c =
                              e.localPosition -
                              Offset(_vp3.width / 2, _vp3.height / 2);
                          setState(() {
                            _o3 = c - (c - _o3) * t;
                            _z3 = nz;
                          });
                        }
                      },
                      onPointerHover: (e) => setState(() {
                        _hover3 = e.localPosition;
                        _activePlan = false;
                        // rotate's pick phase needs the same hover-pick
                        // as select so the cursor shows the hand
                        final picking =
                            _tool == _MTool.select ||
                            (_tool == _MTool.rotate && _rotating == null);
                        if (!picking) {
                          _overPart3 = false;
                          _overHandle = -1;
                        } else {
                          _overHandle = _tool == _MTool.select
                              ? _handleAt(e.localPosition)
                              : -1;
                          if (_overHandle < 0 &&
                              (e.localPosition - _pickAt3).distance >= 8) {
                            // face-pick per hover event is heavy — re-eval
                            // only after the cursor traveled ~8 px
                            _pickAt3 = e.localPosition;
                            _overPart3 = _pick3(e.localPosition, _vp3) != null;
                          }
                        }
                      }),
                      onPointerDown: (e) {
                        // a fresh press ends the stale-tap swallow window
                        _midBlock = false;
                        // grab key focus so W/B/Delete/Esc work right
                        // after a 3D-canvas interaction
                        _keyFocus.requestFocus();
                        setState(() => _hover3 = null);
                        // CAD convention: middle-button drag pans
                        if (e.buttons & kMiddleMouseButton != 0) {
                          _midPan = e.localPosition;
                        }
                      },
                      onPointerMove: (e) {
                        final l = _midPan;
                        if (l != null && e.buttons & kMiddleMouseButton != 0) {
                          setState(() {
                            _o3 += e.localPosition - l;
                            _midPan = e.localPosition;
                          });
                        }
                      },
                      onPointerUp: (_) {
                        if (_midPan != null) {
                          _midPan = null;
                          _midBlock = true; // swallow this release's stale tap
                        }
                        if (_drag3) setState(() => _drag3 = false);
                      },
                      onPointerCancel: (_) => setState(() {
                        _midPan = null;
                        _drag3 = false;
                      }),
                      child: GestureDetector(
                        key: const Key('model3d'),
                        behavior: HitTestBehavior.opaque,
                        onPanStart: (d) {
                          // a press on a bbox face handle starts a stretch
                          // instead of the camera orbit
                          if (_tool == _MTool.select && _blkSel != null) {
                            final h = _handleAt(d.localPosition);
                            if (h >= 0) {
                              setState(() => _stretchAxis = h);
                            }
                          }
                        },
                        onPanEnd: (_) {
                          if (_stretchAxis >= 0) {
                            _stretchAxis = -1;
                            est.update(); // commit stretched size once
                          }
                        },
                        onPanUpdate: (d) => setState(() {
                          if (_stretchAxis >= 0) {
                            _drag3 = true;
                            _stretchDrag(_stretchAxis, d.delta);
                            return;
                          }
                          // SketchUp-style: plain drag orbits, shift-drag
                          // pans the camera
                          _drag3 = true;
                          if (HardwareKeyboard.instance.isShiftPressed) {
                            _o3 += d.delta;
                          } else {
                            _yaw += d.delta.dx * 0.012;
                            _pitch = (_pitch + d.delta.dy * 0.012).clamp(
                              0.05,
                              math.pi / 2,
                            );
                          }
                        }),
                        onTapUp: (d) => _modelTap(
                          d.localPosition,
                          Size(box.maxWidth, box.maxHeight),
                        ),
                        onLongPressStart: (d) => _modelLpStart(
                          d.localPosition,
                          Size(box.maxWidth, box.maxHeight),
                        ),
                        onLongPressMoveUpdate: (d) => _modelLpUpdate(
                          d,
                          Size(box.maxWidth, box.maxHeight),
                        ),
                        onLongPressEnd: (d) => _modelLpEnd(
                          d.localPosition,
                          Size(box.maxWidth, box.maxHeight),
                        ),
                        onLongPressCancel: _modelLpCancel,
                        child: ClipRect(
                          child: CustomPaint(
                            painter: _SolidPainter(
                              this,
                              cs,
                              MediaQuery.devicePixelRatioOf(context),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                // camera presets (SketchUp-style standard views) + fit
                Positioned(
                  left: 8,
                  top: 8,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final (label, yaw, pitch) in const [
                        ('ISO', -0.7, 0.55),
                        ('TOP', 0.0, math.pi / 2),
                        ('FRONT', 0.0, 0.05),
                        ('RIGHT', -math.pi / 2, 0.05),
                        ('REAR', math.pi, 0.05),
                        ('LEFT', math.pi / 2, 0.05),
                      ])
                        Padding(
                          key: ValueKey('camera-preset-$label'),
                          padding: const EdgeInsets.only(right: 4),
                          child: InkWell(
                            onTap: () {
                              setState(() {
                                _yaw = yaw;
                                _pitch = pitch;
                              });
                              // recentre on the SELECTED model so an
                              // off-origin project can't vanish when the
                              // axes flip — never fits world/other models
                              _fit3();
                            },
                            borderRadius: BorderRadius.circular(6),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 7,
                                vertical: 3,
                              ),
                              decoration: BoxDecoration(
                                color:
                                    (_yaw - yaw).abs() < 1e-6 &&
                                        (_pitch - pitch).abs() < 1e-6
                                    ? cs.primary.withValues(alpha: 0.14)
                                    : Colors.white.withValues(alpha: 0.85),
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(
                                  color:
                                      (_yaw - yaw).abs() < 1e-6 &&
                                          (_pitch - pitch).abs() < 1e-6
                                      ? cs.primary
                                      : const Color(0xFFCBD5E1),
                                ),
                              ),
                              child: Text(
                                label,
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w700,
                                  color:
                                      (_yaw - yaw).abs() < 1e-6 &&
                                          (_pitch - pitch).abs() < 1e-6
                                      ? cs.primary
                                      : const Color(0xFF475569),
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                Positioned(
                  right: 8,
                  top: 8,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.fit_screen, size: 18),
                        tooltip: 'Fit model (zoom extents)',
                        visualDensity: VisualDensity.compact,
                        onPressed: _fit3,
                      ),
                      IconButton(
                        icon: const Icon(Icons.vrpano_outlined, size: 18),
                        tooltip: 'Reset 3D view',
                        visualDensity: VisualDensity.compact,
                        onPressed: () => setState(() {
                          _yaw = -0.7;
                          _pitch = 0.55;
                          _o3 = Offset.zero;
                          _z3 = 30;
                        }),
                      ),
                      IconButton(
                        icon: Icon(
                          _render ? Icons.lightbulb : Icons.lightbulb_outline,
                          size: 18,
                          color: _render ? const Color(0xFFF59E0B) : null,
                        ),
                        tooltip: _render
                            ? 'Back to draft view (fast editing)'
                            : 'Render view (sky + shadows + lighting)',
                        visualDensity: VisualDensity.compact,
                        style: IconButton.styleFrom(
                          backgroundColor: _render
                              ? const Color(0xFFFEF3C7)
                              : null,
                        ),
                        onPressed: () => setState(() => _render = !_render),
                      ),
                      // ray-traced still render (lib/render.dart) - exports
                      // real PNGs of the standard views for reports
                      IconButton(
                        icon: const Icon(Icons.camera_alt_outlined, size: 18),
                        tooltip: 'Render (ray-traced still)',
                        visualDensity: VisualDensity.compact,
                        onPressed: _sel == null ? null : _showRenderDialog,
                      ),
                      IconButton(
                        icon: Icon(
                          _vp == _Vp.model
                              ? Icons.fullscreen_exit
                              : Icons.fullscreen,
                          size: 18,
                        ),
                        tooltip: _vp == _Vp.model
                            ? 'Back to split view (2)'
                            : 'Maximize 3D (3 / F)',
                        visualDensity: VisualDensity.compact,
                        onPressed: () => setState(
                          () => _vp = _vp == _Vp.model ? _Vp.split : _Vp.model,
                        ),
                      ),
                    ],
                  ),
                ),
                Positioned(
                  right: 10,
                  bottom: 8,
                  child: Text(
                    _topDown
                        ? 'TOP / ORTHOGRAPHIC'
                        : (_vp == _Vp.model ? '3D FOCUS' : '3D VIEW'),
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.2,
                      color: Color(0xFF64748B),
                    ),
                  ),
                ),
                if (_sel != null && _sel!.bounds == null)
                  // hint must not eat canvas input under its text
                  IgnorePointer(
                    child: Center(
                      child: Text(
                        'Draw walls (W) on the plan OR right here — both\n'
                        'sides stay in sync. Place furniture from Blocks (B).',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.black.withValues(alpha: 0.45),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  // ---------- inspector ----------
}
