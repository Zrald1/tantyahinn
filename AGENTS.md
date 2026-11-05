# Tantyahin (Construction Estimate)

Flutter Windows-desktop app — package `tantyahin`, exe `tantyahin.exe`,
window title + top-bar brand "Tantyahin" with the carabao mark — the
USER-SUPPLIED `assets/logo.jpg` (magenta ring, white field, solid
magenta carabao head), used as-is via `lib/ui/carabao_logo.dart`;
`windows/runner/resources/app_icon.ico` is a classic BGRA 3.00 ICO
baked from that jpg by `test/carabao_icon_test.dart` (little-endian
headers + DIB payload — rc.exe rejects PNG-in-ICO) — that reproduces
the SDO estimate workbook:
left = live BOQ sheet preview (editable cells), right = insert-work panel
with quantity calculators; exports .xlsx (BOQ + POW + PERT-CPM + S-CURVE +
DATA sheets, real VLOOKUP/SUM formulas); saves/loads projects as `.boqproj`
JSON; rolling autosave keeps the project safe on every edit.

## Commands (verified Oct 2026)

- 1K-LINE CAP (user rule): every source file max ~1000 lines. Split
  oversized files into `part`/`part of` + `extension` files — extensions
  on a State subclass keep private-field access (`extension _X on
  _FooState`), silence `invalid_use_of_protected_member` per file for
  the setState false-positive, and CANNOT declare instance fields or be
  relied on for statics (move both to top-level or the host class).
  Pattern set by model_view.dart -> mv_gesture/mv_panels/mv_inspect/
  mv_paint.dart. STILL OVER CAP: drawing_view 2242, sheet_view 2019,
  excel_export 1920, model3d ~1860, work_panel 1483, state ~1360,
  pdf_export 1076, main ~1020. Before scripted line-range surgery,
  snapshot the file — IDE local history at
  %APPDATA%\Devin\User\History\<id>\ plus git (see below).
- Git repo: own .git (init Nov 2026), remote origin =
  github.com/Zrald1/tantyahin (private), branch main. The HOME dir has a
  separate outer repo (C:/Users/Zrald) — never commit from there. Windows
  reserved-name files (nul etc.) break `git add -A` — delete strays first.
- Run: `flutter run -d windows` or launch
  `build\windows\x64\runner\Release\tantyahin.exe`
- Build: `flutter build windows --release` (~35s)
- Check: `flutter analyze` | Test: `flutter test`
- Dart scripts that import Flutter can't use `dart run` -> run them inside
  a `flutter test` file (see `test/gen_sample_test.dart`).
- STANDING RULE (user): ALWAYS do web research before implementing any
  feature — look up the proper real-world practice, code provisions, or
  conventions first (NSCP tables for structural sizing, mill sections for
  steel, trade detailing for roof/framing, platform UX norms for UI),
  then encode the researched values as the defaults + tests. The NSCP
  305-1 footing depths / 409.3.1.1 beam depths, C-purlin lipped-channel
  profiles, and fink-family panel growth all came from research — never
  guess dimensions or standards from memory.

## Architecture

- `lib/state.dart` - `est` is a GETTER resolving to the ACTIVE project
  tab's EstimateState (`projectTabs.active.state`): sections, editable
  `priceDb`, project info, save/load, `applyMaterialEdit` propagation.
  PROJECT TABS (browser-style — `ProjectTabs`/`ProjectSession` live in
  `lib/project_tabs.dart`, a `part of 'state.dart'`; the strip widget
  is `_ProjectTabs` in `lib/ui/project_tab_strip.dart`, a part of
  main.dart): `projectTabs.tabs` holds one session per open project;
  `newTab()` (office assets carried via `copyOfficeFrom`), `activate`,
  `close` (last tab resets in place via `newProject()` — the old
  "New estimate" contract), `reset()` (test hook). Each session owns
  its `viewTab` (which view it was left on) + a per-tab rolling
  autosave `autosave-<id>.boqproj` (tab 0 keeps `autosave.boqproj`);
  `sessions.json` in %APPDATA% persists tab ids + active index so
  startup `projectTabs.restore()` rebuilds the strip. Only the ACTIVE
  session renders — background tabs are plain state, zero frames.
  New = new tab (non-destructive); Open loads into a new tab and
  dedupes on `savedPath`. The `_ProjectTabs` strip in main.dart
  auto-hides with <=1 tab. GOTCHA that cost a debug session: the
  strip must NOT be `const` — a canonicalized const instance makes
  `child.widget == newWidget` short-circuit the element update and
  it never rebuilds when tabs change. Same rule for any widget that
  reads `projectTabs`/`est` in build. `_drawingKey`/`_panelKey` are
  per-session GlobalKey maps — GlobalKey is required for focus-mode
  reparent state-keeping, and distinct keys per session stop a
  background project's widget State (PDFs, selections) leaking into
  the active tab.
- `lib/calculators.dart` - faithful ports of the workbook's CONCRETE /
  MASONRY / TILES / PAINTING / CARPENTRY / STEEL / STAIRS formulas.
- `lib/price_db.dart` - `MaterialPrice` + `kPriceDb` (182 items, mutable
  copies live in `est.priceDb`; labor = price * `est.laborRate`, default
  0.30; lines with `laborOverridden` keep their own labor).
- `lib/models.dart` - `BoqSection` > `BoqLine` (item | groupHeader);
  `priceKey` links a line to a DATA name for VLOOKUP export;
  `priceOverridden` freezes a line against db edits. `ProjectInfo`
  also owns the DOCUMENT TEMPLATE: `template` = 'public' (office
  letterhead + signatory blocks everywhere) | 'private' (free
  template — none). Consumers MUST use `effLetterhead` /
  `effSignatories` / `effLogo` — they return empty under private so
  every sheet AND export (xlsx/pdf/docx/extension docx) drops the
  header and signatures while the stored office identity stays
  intact (switching back restores it). The top-bar `_TemplateToggle`
  writes it; newProject/copyOfficeFrom carry it as an office asset.
  The generated-sheet strip shrinks to the title row under private
  via `sheetTitleCells(paper, isPrivate:)` — pass it in BOTH the DXF
  generator and the DRAWINGS overlay or hotspots misalign. Division
  Engineer default is JONATHAN D. NARVATO; fromJson renames the old
  'VIRGILIO B. BANCASO' default on load (covers saved projects +
  autosaves). RETIRED NAMES: _retiredSignatoryNames (Virgilio,
  Jonathan, Pedro, Norma) are BLANKED on every load — every template
  id, via _normalizeSignatories(insertSeats: id=='deped'): only deped
  re-inserts the 4 canonical seats; custom/private sign-offs get the
  name scrub only. Matching goes through _canonName (upper + collapse
  whitespace). Only 'GERALD BUSTILLA / Civil Engineer' survives as the
  Prepared-by default. Exports never substitute names: an empty
  signatory name renders blank — what the user typed is what exports.
  CONST TRAP AGAIN: `OfficeHeader`/`SignatureBlock` read
  est.project in build — they must NOT be instantiated `const` in a
  listenable rebuild (the element update short-circuits and the
  private switch never repaints — cost a test failure). Same rule as
  _ProjectTabs/_TemplateToggle. The 5 theme-color slots default to
  the brand palette (pink accent 0xFFD5008F, violet section band
  0xFF7C3AED, violet/pink-50 tints for the rest) — the same literals
  live in ProjectInfo.fromJson fallbacks AND theme_dialog _Slot
  fallbacks (Reset all); keep all three sites in sync.
- `lib/excel_export.dart` - writes the workbook replica; POW references
  BOQ subtotal cells (`_boqSubtotalRows` must mirror `_writeBoq` layout).
  All row numbers derive from `project.letterhead.length` (default 5)
  via `lhEnd`/`hh`/`i0`/`i1`/`th` - never reintroduce fixed row numbers.
- `lib/ui/` - `sheet_view.dart` (left paper preview, breakpoint: side-by-
  side >= 1000px else panel below), `work_panel.dart` (right inspector),
  `pricing_page.dart` (price DB editor), `pow_view.dart` (POW tab),
  `drawing_view.dart` (DRAWINGS tab), `schedule_view.dart` (PROJECT
  SCHEDULE tab = `ScheduleView` wrapper: header strip + PERT-CPM/S-CURVE
  sub-toggle switching `PertView`/`ScurveView`; `est.scheduleSub`
  remembers the sub-view across tab switches, in-memory only),
  `manage_view.dart` (PROJECT MANAGEMENT tab), `extension_view.dart`
  (extension-letter creator). Tabs 3-5 (SCHEDULE/MANAGEMENT/EXTENSION)
  take the full width; BOQ, POW and DRAWINGS keep the insert-work
  inspector on the right (below the content under 1000px).
- Project management tracking (`est`): `trackItems` (TrackItem: sectionId
  link, name, status pending/ongoing/completed, remarks, `progress`
  0..100) seeded by `syncTrackItems()` from BOQ sections (names follow
  section titles, orphans kept); `inspections` (Inspection: ISO date
  string, inspector, findings - newest first). Both serialize into
  project JSON. `setTrackProgress` keeps status and % consistent
  (0=pending, 100=completed, else ongoing; `setTrackStatus` writes the
  matching % back); `overallProgress` = cost-weighted accomplishment
  (each item's % × its section's subtotal, simple average when
  unpriced); `addTrackItems` batch-adds one item per line from the Add
  dialog (which also lists untracked BOQ sections as checkboxes);
  `addInspection` pre-fills findings with `inspectionFindings()` — an
  editable snapshot listing overall % and every item's status/%.
  ManageView layout (researched vs Procore/PleoStack): KPI strip whose
  tiles (All/Pending/On-going/Completed, keys `kpi-*`) filter the table;
  table with ONE status dropdown pill per row (key `status-<id>`),
  search, single Add button; inspections = date block + inspector +
  findings + ⋮ menu. Keep buttons few - user dislikes button clutter.
  Inline fields are keyless TextFormFields writing to the model +
  `est.update()` per keystroke (keys remount and kill focus); rows/cards
  carry `ValueKey(id)`. Fixed-width pill rows need FittedBox(scaleDown)
  because the test font is wider than real fonts.
- `lib/dxf.dart` - `DxfParser.parse(src)` -> `DxfScene` (entities sampled
  to world-space polylines so INSERT transforms/bounds are trivial) +
  `DxfPainter` (Y-flip fit transform). Handles LINE, LWPOLYLINE (+bulge
  arcs), POLYLINE/VERTEX, CIRCLE, ARC, ELLIPSE, SPLINE (ctrl-polyline),
  POINT, TEXT/MTEXT, SOLID/3DFACE, INSERT (nested, depth<=6), HATCH
  (polyline + line/arc/ellipse/spline boundaries; SOLID fills -> DxfPrim
  .fillLoops painted even-odd so islands become holes, patterned hatches
  -> boundary outlines), DIMENSION (replays its anonymous *D block - the
  contents are already world-space), MULTILEADER (text from the
  CONTEXT_DATA 304 code + leader line from LEADER_LINE{ 10/20 }), LAYER
  colors, ACI palette (`dxfAciColor`). Skipped: OLE2FRAME, VIEWPORT.
  DWG: `_loadDwg` converts via the BUNDLED LibreDWG `dwg2dxf.exe`
  (shipped as `dwgconv\` beside the exe via windows/CMakeLists.txt
  install rule; dev/tests find it at `tool/dwgconv/`), output goes to a
  per-file dir `%TEMP%\ce_dwg\<fileId>\`. ODA File Converter (if
  installed under C:\Program Files\ODA) is the fallback. PDF-imported
  DWGs store walls as SOLID hatches - without HATCH support the plan
  renders gutted. Regression fixture: `tool/fixtures/floorplan.dxf`
  (real dwg2dxf output, ~21MB; the dxf_test skips when absent).
- `lib/ui/drawing_view.dart` - viewer: left file library (+pdf PAGES
  list), wheel-zoom via outer `Listener`->`TransformationController`
  (zoom-around-focal matrix), InteractiveViewer pan only when the Pan
  tool is active (mark tools overlay a GestureDetector in the content
  stack), marks stored NORMALIZED 0..1 in `est.marks` (autosaved). PDF
  pages render via pdfx `doc.getPage(i).render(width:, height:)` at
  ~2x then cache as ui.Image. `pdfium.dll`+`pdfx_plugin.dll` ship in
  the Release dir (pdfx plugin).
  AUTOCAD NAV: wheel zooms at the cursor (1.25/detent), middle-button
  drag pans under any tool, double-middle-click = zoom extents (_fit).
  CRITICAL: every `_tc.value` write MUST scale all 3 axes
  (`scaleByDouble(s,s,s,1)`) — writing XY-only scale leaves Z at 1.0,
  and `getMaxScaleOnAxis` (max of XYZ) then reports >=1.0 forever:
  zoom under 100% reads "1.0", the % label lies and the 0.05 clamp
  misbehaves. That bug made wheel zoom feel broken on fitted sheets.
  SCALE PICKER: the toolbar % readout is a PopupMenuButton — generated
  sheets (scene text `SCALE 1:N`) list metric scales mapping zoom =
  pxPerMm(96/25.4) * denom / N / unitsPerMm, where unitsPerMm =
  `cache.size.width / scene.bounds.width` (DxfScene.naturalSize
  normalizes content to <=1600px — content units are px, NOT mm).
  The chip label shows the equivalent '1:N'. `_zoom100`/'Actual size'
  = pxPerMm/unitsPerMm for sheets, 1.0 for px files.
- Zoom/pan survives tab switches: a `_tc` listener writes the matrix
  into `est.drawingXfms['fileId:page']` (in-memory, not serialized);
  every auto-fit path calls `_fitOrRestore()` (saved matrix wins,
  else `_fit`). Only the toolbar "Fit" button forces `_fit`. The
  file rail collapses via `est.drawingLibraryOpen` (40px rail with
  expand/open buttons).
- FOCUS MODE (`est.drawingFocus`, toggled from the drawing toolbar or
  Esc): the `_ViewTabs` strip hides and main.dart swaps to
  `_focusLayout` = [DrawingView | drag divider (`_boqFrac`) |
  SheetView | WorkPanel]. `DrawingView` and `WorkPanel` carry
  GlobalKeys (`_drawingKey`/`_panelKey`) so reparenting between the
  normal and focus layouts keeps their State (loaded files, tool,
  selection, open calculator) — same keys in both layouts, one at a
  time. The whole Scaffold body is a ListenableBuilder on est so the
  flag flips the layout.
- Mark editing: DRAW TOOLS ALWAYS DRAW — a drag starting on/inside a
  mark makes a NEW overlapping mark (`_markStart`), it never adjusts
  the old one (user explicitly wanted overlapping rects drawable).
  Adjusting = SELECT tool, or TAP (not drag) a mark with any tool —
  onTapUp adopts it and switches `_tool` to Select. In Select mode
  `_selStart`->`_tryAdjustAt` grabs handle > body > other mark; press
  on empty space releases. A just-drawn mark stays selected. Drag a
  handle dot to reshape (rect corners, arrow endpoints, pen/hi bbox
  corners -> scale), drag the body to move any mark incl. text notes.
  The MouseRegion hand cursor (`grab`) only appears in Select mode
  over a mark — in draw mode a press draws, so no hand.
- Drawing toolbar is compact: ONE PopupMenuButton each for mark color
  and stroke width (icon = current swatch/dot). `< n/m >` file nav
  (navigate_before/next icons) shows when >1 drawing — `_stepFile` /
  `_selectFile`. Everything has a `tooltip:` for hover help.
  `_pickTol` = 14/zoomScale keeps handle hits ~14 screen px at any
  zoom.
  KEYBOARD (a `Focus(_keyFocus)` + `CallbackShortcuts` wraps the whole
  view; the canvas Listener grabs `_keyFocus` on pointer-down, skipped
  while an inline editor (text note OR measure ref card) is open):
  Esc = cancel cascade (discard open
  text editor -> release selected/in-progress mark -> tool back to pan
  -> exit focus mode), A=select V=pan P=pen H=highlighter B=arrow
  R=rect T=text M=measure E=eraser, C=open color menu S=stroke menu (via
  `PopupMenuButtonState.showButtonMenu` on GlobalKeys),
  Ctrl+Z=undoMark, Ctrl+Y & Ctrl+R=redoMark (`est._markRedo` stack,
  cleared by addMark/clearMarks/newProject). Tooltips carry the key.
  ERASER (E, broom icon, `precise` crosshair cursor): tap deletes the
  mark under the point; a drag SWEEPS — `_eraseAlong` samples the path
  between consecutive pointer positions at ~tol/2 steps so a fast
  flick still removes everything crossed (tester.dragFrom only emits
  the endpoints, so per-point erasing misses the middle). Deletes any
  mark kind via `est.removeMark` (clears `_markRedo`, not undoable —
  same contract as page clear).
  Injecting keys headlessly: PostMessage WM_KEYDOWN to the FLUTTERVIEW
  CHILD hwnd, not the top-level frame. Injecting DRAGS headlessly:
  mouse_event needs real dwell — ~100ms down, 10+ move steps at ~50ms,
  pause before up — or the pan gesture loses the arena and _markStart
  never fires (an 8-step/20ms drag silently did nothing).
  MEASURE tool (M, ruler icon): per-page calibration. With no ref on
  the current page the toolbar shows an amber "drag a known-length
  line" hint; the next drag becomes `_refLine` (not a mark) and an
  inline card (Positioned AFTER the gesture overlay in the stack so
  its field/dropdown get taps) asks real length + unit
  (mm/cm/m/in/ft). Commit stores `est.measureRefs['fileId:page']` =
  MeasureRef(px, real, unit) — serialized in project JSON, reset via
  the toolbar chip's reset icon. Calibrated drags add 'measure' marks
  (dimension line + end ticks + label above midpoint, adjustable via
  endpoint handles like arrows). MEASURE OVERLAYS ARE ZOOM-CONSTANT:
  `_MarksPainter`/`_SelPainter` take `zoom = _tc.getMaxScaleOnAxis()`
  and divide measure stroke/ticks/label fs and selection dash/dots by
  it, and the ref card wraps in Transform.scale(1/z, topCenter) — all
  rebuilt via ListenableBuilder(listenable: _tc) so a wheel-zoom
  keeps the overlay the same screen size (pickTol = 14/zoom already
  did this for hit-testing). Refs are per PAGE: switching pages
  shows the hint again. Text notes are typed INLINE on the canvas (Positioned
  TextField in the content stack, commits on submit/tap-outside ->
  `est.addMark` or edits the tapped text mark). The marks
  GestureDetector MUST keep `dragStartBehavior: DragStartBehavior.down`
  - the default `.start` offsets onPanStart's localPosition by the
  pan-slop accumulation (~18-36 px), which breaks handle hit-testing
  and swallows the first update for short drags.
- `lib/model3d.dart` + `lib/ui/model_view.dart` - the 3D MODEL tab
  (Revit-lite): `Model3d` holds THREE part kinds, all serialized into
  `est.models` in project JSON. `Volume3d` = closed footprint extruded
  base->top (massing). `Wall3d` = centerline `pts` polyline +
  `thickness`/`base`/`height`; `segPoly(i)` makes the thick rect per
  segment (BUTT caps - bounds grow perpendicular only, not past
  endpoints), `wallFaces` extrudes each seg via shared `_polyFaces`.
  `Block3d` = placed `kCadBlocks` symbol (x,y,rot,scale + sx/sy/sz
  per-axis stretch + bz base lift — all serialized). `kCadBlocks` is
  the in-code CAD library (~50 defs) and EVERY def resolves a real
  bundled mesh: `kKenneyMeshMap` maps def ids to `assets/kenney/*.obj`
  (~70 CC0 models — Kenney Furniture/Car/Nature/Prototype kits +
  Blocky Characters, plus `kk_*` KayKit Furniture Bits and `kkr_*`
  KayKit Restaurant Bits (doors `door_A`/`door_B`/`wall_doorway`;
  `kkr_door_dbl` = two mirrored door_A leaves composited by script),
  `wh_*` = real 3D Warehouse models (see `assets/kenney/WAREHOUSE.txt`
  for sources). Warehouse pipeline: entity JSON at
  `warehouse/v1.0/entities/<id>` lists binaries — `glb` lives on a
  PUBLIC content url (no login; `s*`/`zip` are restricted-401);
  convert headless with `tool/wh_src/glb2obj.py` (Blender —
  `o.data.copy()` before decimate, glTF shares mesh data). Warehouse
  models ship SketchUp-color materials — recolor MTL Kd for realism
  (white `0010_Snow` leaf -> walnut).
  SKP IMPORT (wh_truss = user's real SketchUp model): `-RubyStartup`
  is DEAD in SketchUp 2026 (probe-verified). Working path: the
  installed `sketchup_mcp_extension` bridge polls 127.0.0.1:8765 —
  launch `SketchUp.exe "file.skp"`, send `tool/skp2obj.rb`'s lambda
  body via the `sketchup_execute_ruby` MCP tool (eval runs inside
  `SketchupMCP::CommandRunner` — `def` fails, use lambdas; emit
  OBJ Y-up = skp `x,z,y`; inches*0.0254). The parser's Y-up->Z-up
  swap bit me once: a Z-up export lays the model on its back.
  `_parseMtl` folds `d`/`Tr` into argb alpha — glass renders genuinely translucent.
  Write asset files ASCII-only — a cp1252 em-dash in a comment once
  made readAsString throw and the mesh silently never registered.
  `tool/bake_kenney.py` samples each face's UV
  centroid in the kit's colormap.png and rewrites the OBJ+MTL with
  real `Kd` colors — that is how texture-mapped kits (car/person/
  stairs/door/window/column) got per-face colors without UV support.
  `kKenneyZLift` bakes mount heights (fan 2.45, tv 0.45 console,
  picture 1.15 eye-level, microwave 0.90 counter, bath-cab 1.35 — a
  bare panel at z=0 renders as a floor sliver; the wall-window mesh
  carries its own sill so it stays 0). Plan dims toggle `_dims`
  (ruler icon next to Snap) gates wall-seg lengths + per-block W×D
  labels (<=40 blocks; selected always shows name+W×D·h).
  `_objLocal` tries BOTH the direct and 90°-swapped xy fit and keeps
  the orientation allowing the LARGER uniform scale — thin panels
  (door/window/wall pieces) often carry their width in the OTHER axis
  and a naive mesh-x↔def-w fit squashes them into floating fragments.
  `preloadBlockMeshes` runs at startup (injectable for tests, which
  load from disk) filling `blockMeshes`/`blockMeshTop`/`blockMeshBox`;
  it ends by calling `registerProceduralSlidingDoors` (lib/
  proc_doors.dart, part of model3d.dart) — five own parametric
  two-track sliding doors, `door-slide-<WxH>` (2.5/2.8/3.0/3.5 m
  widths, 2.0/2.2 heads, 0.16 deep) spread into kCadBlocks after
  `doorway-150`. The meshes are authored in code via `_polyFaces`
  (jambs + head + floor track + two staggered leaf frames with
  translucent glass) exactly like `registerProceduralWindows` — NO
  bundled manufacturer content: the previous GEALAN S9000 IFC assets
  (BIMobject, NOT CC0) were removed for licensing; their old def ids
  still resolve through `kLegacyDefAliases` in `cadBlock()` so saved
  .boqproj files keep working. User-imported .ifc files still load
  via parseIfc + the OBJ/STL import button. `_slidingDoorLines`
  linework (frame + staggered leaves + slide arrow) stays inside
  ±W/2,±D/2 because blockFootprint reads line extents for wall cuts.
  `blockFaces` = mesh verts × (sx,sy,sz) → rotate/scale → +bz, or
  footprint prism fallback when NO mesh is registered (tests without
  preload keep the old flat-symbol behavior — that is why
  model3d_test's "no-mesh openings stay flat" still expects 5 faces).
  `blockLocalBox(def)` = mesh aabb for the scale gizmo; `customCadBlocks`
  + `registerObjBlock`/`loadCustomBlocks`/`customBlocksJson` handle
  user `.obj`/`.stl` imports (obj.dart also parses both STL flavors;
  `_importObj` auto-loads the sibling .mtl). `Model3d.cachedFaces()`
  is the painter path — `_geomSig` hashes all geometry fields AND
  `blockMeshes` registry state (imports/loads invalidate the cache —
  tests proved a registry-blind sig serves stale prisms forever).
  Wall JOIN + PIERCE at model level: `wallSegPieces(m, w, i)` splits
  each centerline seg into solid polys — ends touching another seg
  (endpoint OR T-junction, <=6cm) extend via MITER REACH: the cap
  travels along the seg's own dir until it crosses the joined wall's
  FAR edge (reach = (edge±t_other/2 - off)/sin(theta)); a fixed t/2
  left the triangular wedge notch at every non-90deg junction (the
  "deformed corner" the user screenshotted — verified by a dense
  point-in-strip coverage sweep in join_notch_test). Near-parallel
  joins (|sin|<0.18) fall back to t/2 and reach caps at 4*t.
  `CadBlock.opening` blocks within 0.75*thickness of the
  centerline carve a gap spanning their footprint. Plan painter +
  `modelFaces`/`wallFacesJoined` (3D/elevations) + the generated
  FLOOR PLAN emitters (`_sheetContent`, `_modelSheet`, projectView
  .plan) all consume it — raw `segPoly` in a sheet path leaves open
  corner notches and uncut openings (foundation/roof sheets keep
  `segPoly` on purpose: continuous outlines under doors).
  `wallFaces` stays the per-seg extrusion for tests. `seatOnWall(m,
  def, pos) -> (Offset, rotRad, wallBase)?` is the shared auto-seat:
  `opening` defs ALWAYS snap center to the nearest centerline — no
  distance cap; an unhosted door/window can't cut a wall and floats
  dead (a drop anywhere lands on the nearest wall, so plan taps and
  3D ground-projected taps both glue SketchUp-style). `mountOn` defs
  (tv/picture/bath-cab) hug the near face (t/2 + d/2 offset) within
  a face-distance of 0.55m. Both set rot = wall dir (+pi on the far
  side — rot is RADIANS; a degrees bug once laid a door sideways;
  diagonal walls yield diagonal blocks) and carry the host wall's
  `base` in `$3` -> `_seatOpening` writes it into `b.bz` so
  upper-storey walls lift the block to their floor. `_placeBlock`
  seats on drop, `_planEnd`/`_moveTap` re-seat after drags, and BOTH
  placement ghosts (plan + 3D) preview the seat — green + "snaps to
  wall" label + connector line; the 3D ghost draws the REAL
  registered mesh (blockFaces) when one exists so a door previews
  standing in the wall, falling back to the footprint prism, and an
  unseated ghost stands on `volumeTopAt(m,w)` (highest volume top
  under the point — slab/massing "on face"; `_standOnVolume` applies
  the same lift to real drops/moves, keeping `bz` on bare ground).
  Door plan symbols draw the leaf 35deg open (thin quad) + jamb
  ticks + arc.
  Columns use `seatColumnOnWall(m, pos, colSec)` instead — the center
  snaps to the NEAREST of seg endpoints (junctions), the wall
  centerline, or a face-flush offset (thickness/2 + colSec/2 either
  side) within 0.55m; the nearest candidate wins, rot = wall angle,
  `$3` = host base -> `b.bz` like seatOnWall.
  Trusses use `seatTrussOnWalls(m, pos, rot, span, ignore:)` — a truss
  bears on wall TOP PLATES. TWO-OPTION HOVER: the seat is solved on
  EVERY orthogonal span axis — the armed rot AND the perpendicular of
  each wall-direction family — so a rectilinear building always weighs
  "span across the horizontal walls" vs "span across the vertical
  walls". `_seatTrussRaw` returns (pos, rot, wallTop, reach) where
  reach = the bearing distance of a real two-plate span (0 = perch).
  Pick order across axes: ANY real span beats a perch; among spans
  the SHORTER bearing distance wins (trusses frame the short
  direction of a room — this is what flips a hover near a side wall
  to the axis that actually crosses it); ties + perches break to the
  seat nearest the pointer. Single-axis solving was the bug behind
  "hover always lands wrong": a stored E-W rot perched diagonally on
  whatever wall sat under the cursor while the N-S span went untried.
  Inside one axis, SPANNING is an OUT-TO-OUT parallel-plate solve
  (Medeek/Chief Architect rule: the walls dictate the span — the
  truss STRETCHES to the bearing, never the reverse). The span LINE
  through pos is intersected with each plate's line — the
  intersection params ARE the truss ends, always ON the plates (a
  4m truss in a 5.5m room now spans it; testing fixed ends at
  pos±span/2 could never reach, so every axis fell back to the
  outward-hanging perch). The axis must run ~perpendicular to the
  plates (|sin(rot-plate)| >= 0.85 — an armed diagonal can't
  produce a skewed staggered-bearing span), bearing must sit in
  [0.3, min(max(span*2, span+2), 24)] (auto-fit range — the fink
  auto-count grows the extra panels), the seat CENTERS between
  its plates then RIDGE-SLIDES until both ends land IN-RUN on
  their segs (_lamRange) — a hover past a wall end clamps to the
  nearest real bay (gable-end truss) instead of an outward perch.
  The probe must lie within the corridor the pair frames
  (bearing/2 + tol) so a far pair can't teleport the drop; WIDEST
  valid pair wins per axis (truss spans the whole roof before
  perching on a partition). `reach` ($4) returns the bearing —
  callers auto-fit the stretch via `trussFitSx(scale, defW,
  bearing)` (clamped 0.25..8) so the placed/ghost truss's ends
  land exactly on the plates: _seatOpening, the seat button,
  _arrayTrusses per-bay, all four paint ghosts, and
  migrateTrusses (heals stored trusses that were saved mid-perch
  onto real spans). This made single-Wall3d polygon
  buildings spannable: opposite sides of one polyline used to fail
  the old `identical(wall)` check, degrading every seat to a
  wall-edge perch. Only when no pair qualifies on ANY axis (or
  requireSpan -> null): the closest plate gives a single-wall PERCH —
  span turns PERPENDICULAR to it, centered on the plate projection,
  nearest hemisphere kept — and when the armed rot is ~parallel to
  the plate (hemisphere ambiguous) the perch biases INWARD toward
  more wall support instead of cantilevering outside; no wall ->
  null (volumeTopAt fallback). After the
  raw solve it RIDGE-GRID-SNAPS: the seat slides along the ridge dir
  to the nearest trussSpacing bay measured from the closest same-line
  truss (same span dir v within 0.6, cos(rot diff)>0.96); an occupied
  bay pushes outward in the cursor's direction — two trusses can
  NEVER land inside each other ("doubled members" in the user's
  screenshots were literally two blocks 0.15m apart, not doubled
  geometry). Off-grid >0.55sp keeps the free seat; the snapped point
  re-seats and must land on the same wall family (rot within 0.3,
  top within 0.6) or the free seat wins. Bearing plates must be
  PARALLEL too (|cos(a1-a2)| >= 0.85): at a corner a 45° span passed
  the >30° test on BOTH perpendicular walls and widest-pair seated a
  diagonal truss hanging off the wall ends — now such pairs are
  rejected and the single-wall perpendicular perch takes over.
  `ignore:` = the block being
  moved/pasted/re-seated — it's already in m.blocks and must not
  anchor the grid to itself (_seatOpening passes b always; the
  "Seat on wall top plates" inspector button and move ghosts pass
  the moving block; _arrayTrusses passes nothing — the seed IS the
  anchor). Every caller of seatTrussOnWalls (place, move, paste,
  seat button, array, plan+3D ghosts) shares this contract.
  BEARING PLATES = `bearingSegs(m)`: wall top plates AND every 'beam'
  block's top face (a beam's axis seg, top = bz + h*sz*scale) — the
  pair solve, perch hits and candidate axes all read ONE list, so a
  beam laid on a wall lifts the bearing line by its depth. Widest
  pair wins per axis; on a bearing TIE the HIGHER plate bears (the
  beam top beats the wall it lies on). The public seat returns
  baseZ = plateTop + `kTrussSeatLift` (0.05 = bottom-chord half-depth:
  the member is drawn centered on z=0, so the lift puts the chord
  UNDERSIDE flush on the plate — bearing, not sinking half a member
  in). Raw `_seatTrussRaw` still returns the bare plate top —
  trussInRoof/migrate compares absorb the 5cm.
  'beam' = RC beam block (def 4.0x0.20x0.30, concrete grey): drops
  PARALLEL onto the nearest wall seg via `seatBeamOnWall` (clamped
  inside the run, rests ON the wall top; free drop otherwise);
  sy/sz adjust width/depth, inspector shows the NSCP sched +
  L/16-depth warning (`nscpBeamDepth`/`nscpBeamWidth` —
  Table 409.3.1.1 = span/16 simply supported, /18.5 one end, /21 both,
  /8 cantilever, rounded UP to 50mm). Concrete joins `beamVol`;
  rebar joins takeoffSteelSched via `beamSched(w,d,len)`.
  STACK GUARD: `trussSpotTaken(m,pos,ignore:)` = another truss within
  min(0.45, spacing*0.45) — place refuses with a snackbar, move
  reverts, paste skips; no path can stack two trusses into the
  "double truss" look. `trussInRoof(m,b)` = isTrussDef AND (bz>0.5
  OR a tol-0.9 seat exists within 0.5 of bz) — the membership test
  EVERY roof consumer shares: roofFields/purlinRuns/trussTags/
  takeoff/roof+roofFrame sheets skip ground-stored strays, which
  otherwise each grow a phantom field + 7 crossing purlin runs
  (user model: 6 fields/42 runs from 9 blocks -> 1 field before
  migration). modelFaces still DRAWS stored trusses (they exist,
  they're spare parts — hiding data is dishonest).
  FIELD MERGE PASS: roofFields ends by MERGING same-roof fragments —
  parallel ridge (|cos|>=0.978), same v roof line (<=lineTol), same
  level (<=0.3 bz), truss-run gap <= connectTol=max(4.5,
  trussSpacing*2). Hand-placed rot jitter (~5deg crossing a 10deg
  bucket) and sparse unplaced bays no longer spray per-fragment
  1m purlin stubs — the C-purlins connect truss to truss (user's
  autosave: two sgl trusses 2.75m apart were 2 fields/14 runs).
  REAL splits survive: perpendicular wings (ridge dot), parallel
  roofs on a different v line, stepped levels (bz), distant gaps.
  LOAD-TIME MIGRATION: `migrateTrusses(m)` runs at the tail of
  Model3d.fromJson (heals open/autosave/tab-restore alike):
  rot normalizes to [0,pi) (orientation is modulo-pi — comparisons
  everywhere must use |cos| or cos(2d), never raw diff: -pi/2 and
  +pi/2 are the SAME truss; gotcha sites were the snap's same-line
  check, the re-seat rot check, the dominant accept check, and the
  roofFields bucket needs %18 wrap). domRot = median rot of the
  bearing trusses; EVERY truss then tries a requireSpan seat at
  domRot with tol=span — the widest-pair solve pulls strays onto
  the dominant eave line even when they currently "bear" (a wall-
  edge perch is still migrated to the coherent span). Non-bearing
  trusses that can't join get a tol-2.0 own-rot requireSpan try;
  bearing ones that can't join keep their seat (legit second
  facet). Then same-spot+elevation stacks drop all but the first —
  physically impossible duplicates are placement-bug artifacts.
  Strays with no span in reach survive as honest stored parts.
  GOTCHA: the user live-edits while testing — re-dump the autosave
  before assuming a migration result is stale.
  INTEGRATION SWEEP rule: a new family variant must route EVERY
  dispatch site through isTrussDef — the catalog thumbnail
  (_BlockMeshThumb) was a missed hop: it read blockMeshes['truss']
  = the wh_truss MONO-PITCH OBJ while placement draws the fink;
  truss defs now take trussLocalFaces there too. The 3D ghost +
  catalog thumb both draw `trussMemberLines(b, def)` — member
  CENTERLINES, one stick per member — because even filtered to the
  -Y plates, a box member's outline reads as a doubled pair of lines
  (the user's "preview double" complaint); plates+strips are gone.
  The inspector's "Seat on wall top plates" button re-runs it.
  HOVER PROBE: the 3D cursor unprojects to the GROUND plane, so a
  pointer over a wall FACE used to land beside it and miss seating.
  `_trussProbePt(m, screenPt)` solves the cursor ray on every
  wall-top plane + ground and keeps whichever point is nearest a
  centerline (`nearestWallDist`) — ghost, click AND drop all feed it
  (place=preview parity), then seatTrussOnWalls runs at tol:2.0 so a
  mid-room probe still finds the spanning pair or perches the plate
  under the cursor. `_s2gAt(p,vp,z)` is the generalized unproject.
  `_seatOpening` routes col-sq/col-rd there and everything else to
  `seatOnWall`; `_moveTap` + `_pasteClip` re-seat through the same
  call so a dropped/moved/pasted column always lands on the wall.
  THREE TRUSS DEFS: 'truss' = detailed fink parametric web,
  'truss-sgl' = simple king-post A-frame (the earlier look, kept as
  a second catalog option), 'truss-dbl' = DOUBLE mono-pitch from the
  user's second SketchUp file (truss (1).skp -> assets/kenney/
  dbl_truss.obj via the same -RubyStartup export): trussLocalFaces'
  `dbl:` mode builds ONE flat frame twice at ±y inside the 0.18 m
  depth — bottom chord, top chord rising heel (rise*0.18) to +X
  high end, end posts + the same fink zigzag webs. memberLines returns
  BOTH frames' centerlines (an honest double). MEMBER DEPTH:
  trussLocalFaces clamps member Y-depth to <=0.05 (lumber on edge,
  dbl plates ~0.06) — passing the full def.d footprint (0.18)
  rendered each member's front+back plates as TWO parallel flat
  trusses at iso. Library rows + drag feedback show trusses in
  _BlockView.FRONT (like openings) — the iso wedge collapses all
  variants to identical slivers. EVERY truss check must go through
  `isTrussDef(id)` — literal `== 'truss'` silently drops the other
  variants from fields/seating/drawings/takeoff/ghosts (cost one
  full fix pass: ~10 sites missed it). The two deliberate
  exceptions: `blockLines` picks `_trussPlanLines` for 'truss' +
  'truss-dbl' (sgl uses its static def.lines), and the inspector's
  "Web bays" panels editor hides only for 'truss-sgl'.
  TRUSS IS PARAMETRIC + FINK-FAMILY (researched vs TRA/span tables):
  `blockFaces` intercepts truss defs ->
  `trussLocalFaces(trussPanelCount(b, def), def.w, def.d, def.height)`
  — bottom+top chords + the W zigzag from `finkNodes(n, span)`:
  bottom chord split into odd P panels (3=fink '4/3', 5=double '6/5',
  7=triple '8/7', then keeps stepping odd to 11 so stretch always
  grows webs), top into P+1; webs connect top_i->bot_i (compression
  stub) and bot_i->top_{i+1} (tension diagonal). Once P >= 5 each
  bottom joint ALSO gets a vertical post up to the rafter — the
  Double Howe (KK) / Triple Fan / KKK families all carry posts, so a
  stretched truss gains W cells AND verticals (a 4m fink = 7
  members, an 8m triple = 21). `Block3d.panels` serialized as
  'panels'.
  RESOLVE VIA `trussPanelCount(b, def)` EVERYWHERE — explicit >=2
  wins; 0=auto derives bays from the STRETCHED span
  (def.w*sx*scale, ~1.0 m/bay so the stock 4m truss = 4) — stretching
  length grows members instead of thinning them. Sites: blockFaces,
  blockLines->_trussPlanLines, _elevScene web zigzag, takeoffRoofing
  trussChordWeb, the inspector label, and move-ghost Block3d copies
  MUST carry `panels:` (ghosts re-resolve otherwise).
  the static wh_truss/dbl_truss OBJs are bypassed for placed trusses
  because a fixed mesh can't change member count — they stay
  registered in kKenneyMeshMap for catalog dims/mesh box, but
  blockFaces/thumbs/ghosts all draw trussLocalFaces.
  The plan symbol goes through
  `blockLines` -> `_trussPlanLines(trussPanelCount)` (same finkNodes
  positions: bottom-node ticks + projected W diagonals); the
  gable elevations project the triangle + the W zigzag in `_elevScene`;
  `projectView` SheetView.roof adds truss symbols + `_roofFraming`
  (ridge/eaves/purlin runs + RAKE edges closing the roof outline at
  both run ends + roofing sheet-joint lines grouped by rot bucket at
  the RoofSpec spacing — `sheetJoints: false` drops the joints for the
  framing sheet), T# member tags (`trussTags` numbers trusses along
  each field's ridge — same numbers on both sheets), and
  `roofCallouts(m)` prints a wrapped spec NOTES block
  (roofing/purlin/truss/area + preliminary-design disclaimer) over the
  drawing. SheetView.roofFrame = 'ROOF FRAMING PLAN' S-102 — the
  structural truss sheet: same walls+symbols+framing linework, no
  sheet joints, plus a `_trussSpacingDim` bay-dim string per field
  and `framingNotes` member/fastener callouts (L50x50x6 chords /
  L40x40x4 webs, C-purlin spec, tekscrew/weld/primer, RA 544
  disclaimer). NEW SheetView CHECKLIST (S-102 cost 2 test failures):
  enum + kSheetTitle + kSheetNo + views list in mv_gesture + _sheetViews
  in drawing_view + projectView condition + _sheetContent branch +
  north-arrow list + buildModelDxf tile + sheet-count expectations in
  widget_test (TWO places — the initial expect AND the regen-dedup
  expect) + model3d_test combined-DXF prim counts. TEXT-WIDTH TRAP:
  sheet NOTES blocks run past the right frame edge unwrapped — the
  paper-fit sees loose text bounds; wrap via `_wrap2(s, wrapAt)` with
  wrapAt ~= span/(th*0.31) chars (verified on rendered PNG).
  ELEVATIONS draw the real roof band in `_elevScene`:
  gable views (truss span parallel to view) get sheet-top +
  purlin-underside slope lines, fascia at the overhang edge, ridge
  cap and one tick per purlin row station (same stations as plan/3D);
  eave-side views get the silhouette band + eave sheet edge — all
  from RoofField/RoofSpec math, never re-derived. In 3D,
  `purlinRuns(m)` emits one lipped C-channel per purlin ROW (same
  stations as the plan lines: a ridge PAIR at ±half/(2·bays)
  flanking the apex — never one straddling it, the peak keeps its
  gap — interior rows + the last row ON the chord edge) — real
  section (web x flange x lip x t, mill tables), opening faces
  upslope. Runs end AT the gable trusses (the field's ±0.5 u0/u1
  extension is sheet overhang, not steel — purlins poking past the
  last truss dangled off the roof), and the last ROW sits at
  |o|=half (the truss chord edge) — a row at half+overhang floats
  ~0.5m past the eave on nothing; only the roof SHEET overhangs.
  Each row's z rides the TOP
  SURFACE ENVELOPE — max over member trusses of t.bz + its own
  half/rise profile (mono 'truss-dbl' uses its heel->peak slope)
  + (chordHalf + plateT/2) * slope/half + 0.008 — so mixed-stretch
  fields never bore the channels through the taller chords. The
  lift MUST be projected through the roof normal (×slope/half):
  a flat +0.05 vertical bump only credits ~0.05*half/slope ALONG
  n3 and leaves the channel ~1cm INSIDE the chord on any real
  pitch (the "purlins through rafters" screenshot). Every truss's
  chord is read at ITS OWN span
  coordinate (project the station onto the truss's rot axis — a
  truss offset off the field's ridge line used to be read at the
  field's offset and floated the run ~0.1m over its chords — the
  "purlins don't touch" screenshot), and the field's half/rise are
  the run's
  ENVELOPE (max), not b0's. The field ridge dir follows the
  run's real first->last direction, not b0's stored rot — a
  hand-placed jitter on the first truss used to tilt the whole
  purlin set off the truss line. Plate thickness is floored at
  12mm (`_purlinVisT`) so 1.2mm
  sheet stays visible; each run is its own painter group appended in
  `modelFaces` after blocks.
  CACHE TRAP: `modelFaces` is cached by `_geomSig()` — ANY derived
  geometry driven by non-geometry fields (roof spec -> purlinRuns)
  must be hashed into `_geomSig` or edits paint stale faces forever.
  ROOF SYSTEM (`Model3d.roof` = `RoofSpec`, serialized per model):
  purlinSize 'C-75'..'C-200' + purlinThk 1.2/1.5/2.0 (''/0 = auto —
  `purlinForSpan` keys section+thickness on truss spacing: <=3m C-75,
  <=4.5m C-100, <=6m C-150, else C-200; NOT a safe-span rating),
  purlinSpacing (0 = auto `purlinSpace` keyed on the sheet: corrugated
  0.65-0.90, rib 0.70-1.00, tile 0.35 batten, seam 1.20),
  roofProfile 'corrugated'|'rib'|'tile'|'seam' + roofThk 0.4/0.5/0.6,
  trussSpacing (drives the inspector's "Array along ridge" button —
  `_arrayTrusses` replicates the seed truss perpendicular to its span,
  seating each copy via `seatTrussOnWalls`), overhang. Shared
  `roofFields(m)` groups placed trusses into fields (ridge dir, run
  length, slope+overhang, measured spacing) and `modelTakeoff` +
  `takeoffRoofing(m, t)` read THE SAME fields — FIELD SPLITTING IS
  SPATIAL, not just rotational: same-rot trusses are sorted by
  ridge-perp position v into ridge LINES (tol ~0.4m), then split
  along the run on u-gaps > max(2.5m, 1.8×trussSpacing) OR a bz step
  >0.3m (different plate elevations = different roof levels — a
  merged field's mean-bz purlin plane floats off both roofs). Merging
  separate wings into one field centers purlins BETWEEN the roofs
  and lays bars across the gap/walls (verified: runLen went 10.5 ->
  2.5 after the split; render test purlin_split.png). After
  emitting a run you MUST reset the run accumulator — `run = []`
  after `emit()`, or the split silently re-merges (cost one test
  failure). — purlin rows/pcs at
  6m lapped lengths, roof lm vs corrugated standard-length sheets
  (8/10/12ft), ridge lm, ~15 tekscrews/sheet, truss L50/L40 steel —
  so BOQ, roof sheet and inspector takeoff never disagree.
  PRICE-KEY CONTRACT: every takeoff line's priceKey is COMPUTED
  (size/thk/profile interpolated into the MaterialPrice name) — keep
  kPriceDb covering the WHOLE selectable matrix (15 C-purlin combos,
  all corrugated Ga/ft pairs, every roofing profile+thk), not just
  the combos the auto tables emit; a manual pick otherwise prices 0.
  Face3.grp tags each source object (volume / wall SEG / block);
  `_SolidPainter` sorts with an OVERLAP-SPLIT hybrid: per-group
  depth ranges [gNear..gMax] are computed; when two groups' ranges
  OVERLAP, the LARGER-range member de-atomizes to per-face sorting
  while the smaller stays whole — a project-size slab straddling a
  wall's span, or a wall running past the slab edge, has no valid
  atomic order and the second-painted group overdrows the first as
  a "cut"/swallowed object (user-screenshot bug; regression =
  test/join_notch_test.dart raster + pixel-count assert). Disjoint
  ranges keep the old atomic group-then-face order — the sofa
  masking case still works because compact objects stay atomic.
  Per-face keys = FARTHEST vertex (classic painter's sort). A
  centroid key mis-orders a long wall against objects standing
  along it ("wall slices the wardrobe").
  The floor slab is NOT a sorted face — it paints once as an opaque
  background after grid/axes and before shadows+solids (proved by the
  render-on/off comparison: per-face translucent ground projections
  stacked into dark wall-shaped ghosts outside the slab). Ground
  shadows = ONE union mask via `paintGroundShadow` (mv_render.dart):
  opaque-white projections composited in a layer tinted once by srcIn,
  clipped to `floorPath` — overlap can never darken further.
  RENDER SIM (user-mandated standing check):
  `test/model_render_test.dart` rasterizes the real pipeline
  (`modelFaces` + public `cam3Project`/`cam3Depth` shared with
  `_SolidPainter`) into per-def PNGs under `test/out/` and audits
  groundedness/span/coverage per def — caught the floating-fragment
  and stale-cache bugs; any mesh/transform change MUST keep it green.
  `modelFaces(m)` = every
  face (vols+walls+meshes) -> drives the 3D preview AND the elevation
  `projectView`s, so the 2D plan IS the 3D model with no separate step.
- `lib/render.dart` - PURE-DART CPU ray tracer for the 3D tab's still
  renderer (no Flutter imports -> runs in tests/`dart run`/Isolates;
  only dart:io/math/typed_data). RenderJob = flattened tri soup
  (TriSoup.addPoly fan-triangulates Face3.v) + yaw/pitch + groundZ;
  perspective cam: fwd = cam3Depth gradient (sy*cp,cy*cp,-sp), fov 40;
  eye distance is SOLVED like _fit3 - all 8 bounds corners must project
  inside ~85% of frame (per-view tight fit; distMul is the margin, def
  1.0). BVH = median centroid split,
  one `_nearest(any:)` traversal serves primary AND occlusion rays
  (triangles only - the infinite ground plane never occludes). Glass
  = argb alpha<255: own tint*alpha + 0.15 sky reflect + transmit
  (1-alpha*0.6); shadow rays attenuate through panes (GEALAN glass
  lights interiors). Quality: draft (no AO, 1 hard ray, 1spp, res*0.6)
  / standard (AO6, soft4, 2spp) / finalQuality (AO8, soft6, 4spp + 1
  bounce x0.15). Tone: sRGB->lin (pow 2.2) -> Reinhard -> gamma;
  `_gndAlb`-style 0..1 constants are already display-space (a stray
  *1/255 once made the ground black while a variance check still
  passed - always sanity-check DECODED pixels vs hand-computed
  colors). PNG encoder is hand-rolled (ZLibCodec+CRC32 over type+data
  - NOT the length field; ZLibCodec ctor is non-const on this SDK).
  `renderPng` yields every 16 rows (progress+cancel in same isolate).
  HDRI ENVIRONMENTS (RenderJob.env, dialog ENVIRONMENT chips):
  `EnvMap`+`decodeHdr` parse Radiance RGBE (RLE + flat) from bundled
  Poly Haven CC0 1k maps in `assets/env/` (field/forest/city/sunset/
  studio; null = procedural Sky). Direction->equirect: u=atan2(dy,dx),
  v=acos(dz), bilinear. Effects: background rays show the real photo;
  `_envAmbient` reuses the AO hemisphere rays so UNoccluded rays carry
  env radiance (image-based ambient, colored corners); glass reflect
  picks it up via _sky; the ground plane becomes the env's own lower
  hemisphere along the ray dir (shadow-catcher: darkened by sunVis+AO
  only). interiorGlow = warm wall-occluded point light at bounds
  center (60% height, footprint*0.7 radius, att² falloff) - lit
  windows effect. CRITICAL tuning: exposure is AUTO-normalized per map
  (`_expo = sqrt(0.8/meanLum)` - unclipped absolute radiance means a
  fixed factor renders dim maps muddy); lighting-path samples are
  clamped at meanLum*8 or HDR sun pixels (~40k) become white fireflies
  on walls/grass; env ground gets _gExpo = expo*2 (absolute ground
  radiance is ~4x dimmer than sky). Gotcha: at ISO pitch the camera
  looks DOWN so the ground plane fills the background - flat-tinting
  it is what made early env renders look like a flat green field.
- `lib/ui/mv_render_dlg.dart` - `part of model_view.dart`, extension
  `_MvRenderDlg` + `_RenderDialog`: view FilterChips = 'CURRENT' (live
  _yaw/_pitch, default) + the 6 preset views + All master chip;
  quality/size chips; ENVIRONMENT ChoiceChips (Sky/Field/Forest/City/
  Sunset/Studio - decoded once via rootBundle->decodeHdr, cached,
  falls back to procedural on miss); Choose-folder; progress+cancel;
  'Add renders to the DRAWINGS library' checkbox (default on ->
  `est.addDrawing(path, 'image')` so stills become library entries);
  thumb strip with Save-as
  + Open-folder via openExportedFile; `renderJobForModel` is the shared
  Model3d->job builder (reused by test/render_test.dart); toolbar
  camera icon sits in the 3D pane's icon row, enabled when _sel!=null.
  Default out = %USERPROFILE%\Documents\ConstructionEstimate\renders.
- `lib/ai_render.dart` - AI render pass: `museEnhanceImage(png,
  apiKey:, prompt:)` POSTs the traced PNG + kAiRenderPrompt to Meta's
  /v1/images/edits (api.meta.ai, model muse-image-1.0, ~$0.01/img,
  ~25-40s) via JSON body {model,prompt,images:[{image_url:
  data:image/png;base64,...}]} (Meta-specific JSON - no multipart).
  Response data[0].b64_json is WEBP (RIFF magic) -> decodeWebP ->
  re-encode PNG. Key stored at %APPDATA%\ConstructionEstimate\
  muse_key.txt (OUTSIDE the repo - never commit it). Verified
  end-to-end: 960x720 traced PNG -> 2048x1152 photoreal output with
  geometry preserved. Dialog: AI ENHANCE checkbox (default on) + key
  field + optional Style-hint field; each base PNG writes first, then
  '<view>-AI' enhanced copies save alongside + file into DRAWINGS too.
  Render keeps working offline - a failed enhance only sets _aiErr.
  Env picker (`_EnvDef` in mv_render_dlg): asset = HDRI id, or
  bgTop/bgBot/bgGnd ARGB = solid sweep (White studio, Black stage)
  plumbed through RenderJob.bgTop/bgBottom/bgGround - _sky returns a
  zenith->horizon gradient with NO sun disk, ground/horizon get the
  ARGB, and bright sweeps get a x3 radiance lift because Reinhard
  x/(1+x)+gamma crushes 0.95 white to ~190 (3x -> ~222). The dialog
  is a horizontal 2-pane studio panel: 380px scrollable settings
  column (views/quality+size side-by-side/env/AI/output) + divider +
  results pane (progress strip on top, 2-col thumb GridView, empty
  placeholder card). Thumbs are cell-flexible - no fixed widths.
  `museExpandStyle(hint, apiKey:, envLabel:)` -> /v1/chat/completions
  with muse-spark-1.3 expands a short hint into a detailed style
  sentence (empty hint -> invents one for the env). CRITICAL: spark
  1.3 is a REASONING model - without 'reasoning_effort':'minimal' it
  burns the whole token budget on reasoning_tokens and returns
  content:null (verified: 400 budget -> 398 reasoning, 0 content).
  Supported efforts: minimal/low/medium/high/xhigh/max - 'none' is
  rejected 400. VISION-GROUNDED: _genStyle first renders a 480x360
  DRAFT frame of the live camera (+selected env) and sends it as an
  OpenAI-style image_url part - spark-1.3 accepts it and the style
  lands grounded in the real building colors/layout (verified:
  produced 'sky-blue stucco cottage... wooden double doors' from
  the actual render). Dart gotcha: `x['a']?['b']` (null-aware subscript on
  a subscript result) is a parse error - split into two accesses.
  Dialog wiring: sparkles button calls _genStyle (busy spinner on the
  icon, fills _styleCtrl, editable afterwards); 6 ActionChip presets
  one-tap fill the hint; while a network AI call is in flight the
  progress bar goes INDETERMINATE + right label switches to a live
  elapsed-seconds Timer (_aiBusy/_aiSecs/_aiTimer, reset per view)
  since the API reports no progress - honest feedback beats fake %.
  Selected blocks get the true-mesh AABB scale gizmo: 6 square face
  grips (`paintBoxHandle`), ±x/±y opposite-face-anchored, +z height
  base-pinned, -z = vertical lift; inspector edits Width/Depth/Height/
  Lift meters (same math). `buildModelDxf` emits the sheet: wall
  segments get SOLID hatches + outline + a length label per seg (the
  auto measurement), furniture as open linework, all 6 views
  normalized by their own projection bounds.
- model_view gestures (tested hard - a subtler pair of bugs lived
  here): tools = select / move (M) / wall (W, default) / block (B) /
  box (R) / poly (P). MOVE (M, Ctrl+M in CAD terms = two-click move):
  first click picks the block under the cursor (`_moving`), a ghost
  copy follows the cursor on BOTH panes, second click drops
  (`_pushUndo` first - undo restores position; NOTE undo
  deserializes, so post-undo asserts must re-read `m.blocks`, not a
  held Block3d reference). Pick uses the UNSNAPPED point
  (same as select's hover tolerance), drop uses the snapped point;
  Esc cancels the carry without undoing the pick. LONG-PRESS is the
  second grab path (`_planLp*`/`_modelLp*`): hold ~500ms on a block
  -> `_moving` carry + tool switches to move, drag = ghost follows,
  release drops; hold on EMPTY space pans the plan / orbits the 3D
  (`_lpOrbit` + `_lpLast3` delta source — LongPressMoveUpdateDetails
  has no `delta`). A wheel scroll while ANY carry is active rotates
  the block 15deg/step instead of zooming; R does the same. GOTCHA:
  `onLongPressCancel` fires on EVERY quick tap (the recognizer loses
  the arena) — cancel handlers may only release `_moving` when the
  `_lpCarry` flag says THIS gesture armed it, or every click kills
  an M-command carry (cost a full suite round). ROTATE (G): same
  two-click carry shape as move — `_rotating` holds the picked
  block, cursor angle around its centre spins the ghost FREELY (no
  angle steps — SketchUp-style), click commits via `_rotTap`,
  `_pushUndo` fires at commit. `_rotAnchor` = the cursor->centre
  angle when the spin engaged; null until the FIRST `_rotPreview`
  call so a G-key-armed carry (no click point) anchors on the
  cursor's current spot and never jumps — the painter latches it.
  Wheel adds `_rotBias` 15deg fine-tune while carrying; Esc releases
  without touching rot. Rotation ignores position snap — it follows
  the RAW cursor point. G NEVER auto-arms `_rotating` — it only
  switches the tool; the spin starts exclusively on an object CLICK
  (user rule: rotate must be gated behind picking a specific object).
  ORBIT PIVOT:
  `cam3Project`/`cam3Depth` take an optional `pivot` — the editor's
  `_proj3`/`_depth3`/`_s2g`/`_projGround` all pass `_orbitFocus` =
  the SELECTED model's bounds center, so orbiting spins around the
  project, not the world origin (the pivot point always projects to
  vp/2+_o3 — that's the test invariant). `_orbitFocus` is EPOCH-CACHED
  per `_buildNo` (incremented inside the ListenableBuilder builder —
  the only boundary every paint-producing rebuild crosses) because
  `bounds` walks every wall+block footprint and _proj3 calls it per
  VERTEX; uncached it made frames O(verts x model) — the lag report.
  SCENE-LAYER CACHE (`_scenePic`, docs/PERF_CAMPAIGN_3D.md): the whole
  static layer (sky/slab/grid/axes/shadow/sorted solids) records into
  ONE ui.Picture and replays via drawPicture while
  (identical(cachedFaces) && identical(model) && camera sig) holds —
  ~14-24x on the dominant no-change repaints. `_paintDynamic` (ghosts/
  handles) stays live on top. Measured truth: allocs beat trig —
  fused/materialized and vertex-map arms LOST to the lean 2-pass.
  Rejected arms documented in the campaign file (backface cull =
  interior views blank the model; isolate = paint is sync).
  Callers that keep origin
  rotation pass no pivot (block thumbnails, render job). Wall tool:
  click points on the 0.25 m snap grid; a tap
  near the LAST point (10px) or near the FIRST (18px) or Enter closes
  the chain into a `Wall3d`. Double-tap is DETECTED MANUALLY inside
  `_planTap` (same snapped point twice) - NEVER put `onDoubleTap` on a
  GestureDetector that also uses `onTapUp`: the double-tap recognizer
  defers/suppresses the tap and randomly eats clicks (measured: every
  odd tap vanished). Keyboard needs `CallbackShortcuts` OUTSIDE
  `Focus(focusNode:)` (same as drawing_view) - keys propagate UP from
  the focused node, so bindings nested INSIDE the Focus never fire —
  and BOTH canvas Listeners must `_keyFocus.requestFocus()` on
  pointer-down or keys die after 3D-canvas interactions.
  `t 0.15` chip = thickness for new walls AND the selected wall; the
  inspector edits name/length/thickness/height/base (wall) or
  rotation/scale (block). Segment length labels paint beside each wall
  seg while drawing and after selection. Delete/Backspace removes the
  selected part via `_delSel`. ALL THREE CustomPaints are wrapped in
  `ClipRect` (plan, 3D, `_BlockThumb` rows) — without it fitted
  content overpaints the toolbar/tab strip (CustomPaint does not clip
  by itself). `_fitPlan` pads the fitted bounds by 0.7m — wall dim
  labels sit ~0.22m+text off geometry and block names hang below the
  point, so fitting raw model bounds clips edge labels mid-glyph at
  fit scales above ~180px/m. Fit-to-content is CHROME-AWARE (task
  14): `_kPlanSafe`/`_k3DSafe` EdgeInsets reserve the regions under
  the floating controls (plan: top-right icons ~44px, bottom caption
  ~30px; 3D: top-left preset chips + icons ~44px, bottom ~34px) and
  both `_fitPlan`/`_fit3` center the content bbox on the SAFE rect
  center — never the pane center. Change an overlay's extent ->
  update the matching constant or fit geometry slides under chrome.
- HiDPI hairline contract (task 16): `hairlinePx(dpr)` = exactly 1
  physical px, `pxSnap(v,dpr)` snaps a coord to a device-pixel CENTER
  (x.5 device units). Painters take `dpr` from MediaQuery at the
  CustomPaint site (NOT inside paint — context.dependOn throws there).
  Hairlines are for REFERENCE strokes only (grid, sub-lines, face
  outlines): snapping shifts a line <0.5 device px so model geometry
  (walls, block linework, snap glyphs) must keep honest coords —
  never pxSnap a projected position the user might measure.
- RIGHT PANEL = tabbed inspector (`_rightTab`): 0 Inspect (part/model
  props — auto-selected whenever a part is grabbed on either canvas).
  The Inspect tab is CONTEXTUAL (task 10): `_modelSummary` when no
  part is selected (name field, Walls count·length, Blocks, Volumes,
  Floor area, Envelope + tip), the part's inspector when selected,
  plus a `‹ MODEL SUMMARY` back link that calls `_clearSel` — tests
  must assert part-only markers (e.g. `Delete wall`) since the
  status strip's tool pill shares names like `WALL`/`SELECT`.
  1 Blocks = the CAD-block library (dwgmodels-style categories:
  Openings/Bedroom/Living/Kitchen/Bath/Site; ~31 real-size defs with a
  `cat` field, search field `lib-search`, rows keyed `lib-<id>`,
  `_blockMeshThumb` (mv_block_preview.dart) draws the registered mesh
  — FRONT for openings, ISO otherwise — as the row icon, falling back
  to `_BlockThumb` linework tagged PLAN when no mesh is registered
  (tests that skip preload). Every row is wrapped in `_blockTip`: a
  native rich Tooltip (WidgetSpan card, 400ms hover / 120ms exit,
  triggerMode manual, ignorePointer) showing FRONT+3D previews and
  W/H/D (+SILL) in meters; card keyed `block-preview-<id>` — scope
  hover-card test assertions to it because the canvas already has a
  FRONT preset label. `_blockDims`/`_libDims` quote the OVERALL frame
  envelope for openings (def.w x sill-to-head — NOT the passable
  opening) and mesh-aabb extents for furniture. W/H/D wording: a
  2.5m slider's clear passage is far less than 2.5m — never call the
  envelope 'clear opening'.
  Tapping a row arms the block tool with that def; the armed def also
  shows in the toolbar chip (which jumps back to the Blocks tab).
- Toolbar overflow contract (task 15): `_toolbar` measures its real
  width via `LayoutBuilder` (rail/inspector width changes count too).
  Full = `_BarGroup`-style tool pill + labeled param chips + parts
  count + labeled GENERATE. `<720px` = compact: thickness -> `straighten`
  icon popup (tooltip carries the value), armed-block chip -> chair
  IconButton -> Blocks tab, parts count hidden. `<430px` = tight:
  GENERATE -> icon-only FilledButton (tooltip 'Generate drawing').
  SingleChildScrollView is the LAST-resort overflow path — collapse
  before scroll. Any new toolbar control must pick its tier or the
  narrow-width tests break.
- ONBOARDING CARD (`_onboardCard`, task 17): 3-step hint card at the
  plan's top-left, shown only while `_sel!=null && bounds==null &&
  !est.modelIntroDismissed` (in-memory session flag, NOT serialized).
  Auto-hides on first committed geometry; x ('Hide tips') dismisses
  for the session. HIT-TEST INVARIANT: a decorated Container claims
  hits for its ENTIRE rect (RenderDecoratedBox.hitTestSelf ->
  BoxDecoration.hitTest is true) — a plain overlay card silently eats
  canvas taps. The card body is wrapped in IgnorePointer and the x is
  a separate Stack sibling, so the ONLY hit area is the ~40px button;
  steps are static hints (kbd chips), never InkWells. Any future
  canvas overlay that must not block drawing needs the same
  IgnorePointer + sibling-controls structure.
- THE 3D CANVAS IS A FIRST-CLASS EDITOR (not just a preview): `_s2g`
  inverts `_proj3` (orthographic yaw/pitch, z=0 ground intersection) so
  a tap on the 3D view lands on the exact plan point — `_modelTap`
  mirrors `_planTap`: wall chains, block placement, and part selection
  all work from the 3D side. Drag still orbits (pan wins the arena
  over taps), wheel zooms, and the reset-view IconButton replaced the
  old onDoubleTap (which would have eaten taps). Live feedback: the
  in-progress wall extrudes as a translucent accent prism + vertex
  dots, and the armed block ghosts under the 3D cursor (`_hover3`
  via onPointerHover). Select in 3D uses `_pick3` — REAL ray picking:
  every part's faces are projected to screen and the tap selects the
  part whose face contains it, nearest-camera (smallest avg depth) —
  do NOT ground-project a face tap for selection, it lands meters off
  the footprint. Wall/block placement still uses `_s2g` (ground plane),
  and only when `_groundEditable` (sin(pitch) > .12): at the flat
  FRONT/RIGHT/REAR/LEFT presets the ground unprojection explodes, so
  taps there select only and the hint strip says "view too flat…".
- TAB BADGES (task 19): the right panel's SegmentedButton labels are
  `_tabBadge` columns — Inspect carries `_selText` only while a part is
  selected, Blocks always carries `_blkDef.name` (84px pill, ellipsis).
  `_blkDef` mutates ONLY from `_libRow.onTap` (+ `armBlockDebug`) — a
  badge change means a real library row was tapped. The status strip
  Container is keyed `modelStatusStrip` — scope selection-text finders
  to it or they double-match the Inspect badge.
- SELECTION HIGHLIGHT (task 18): `_paneActivePlan` marks the last-entered
  pane — plan `MouseRegion.onEnter` sets it true, 3D's sets it false.
  Do NOT set it only in `Listener.onPointerHover`: pointer-hover does
  not fire on a click entering the pane, so 3D clicks silently left
  the plan active. `selColorFor(cs, active)` gives full `cs.primary` on
  the active pane, `Color.lerp(primary, 0xFF94A3B8, .62)` desaturated
  on the other — the same selection is visible on both canvases,
  never duplicated in a second accent color (the old hardcoded
  `0xFF7C4DFF` purple is gone). `paintSelHandle` draws the shared
  handle glyph (accent ring + contrasting core); plan semantics =
  volume corners / wall endpoints / block footprint corners+center,
  3D = top verts + footprint via `selFaces` (`volumeFaces`/`wallFaces`
  — top+side faces, not just the cap). NOTE: plan tap has NO select branch — `_planTap`
  covers placement only; parts on the plan are grabbed on drag-start
  (`_planStart`), so live tests must drag-press, not click.
- 3D NAVIGATION (SketchUp-researched): camera preset chips
  ISO/TOP/FRONT/RIGHT/REAR/LEFT (top-left overlay, keys
  `camera-preset-<label>`, active chip tinted) set `_yaw`/`_pitch` then
  call `_fit3` — EVERY preset recentres on the SELECTED model's bounds
  only, so off-origin work can't vanish and other models never widen
  the frame. TOP = yaw 0 + pitch pi/2 exactly (`_topDown` getter):
  caption 'TOP / ORTHOGRAPHIC', and sky/ground-shadow rendering is
  suppressed overhead while `_render` stays stored for ISO. Orbit
  pitch clamp is pi/2 max so leaving TOP doesn't jump. Loose blocks
  stored outside walls (rug/plants) are intentional user content —
  never auto-seat/move them to clean up the view.
  drag orbits, SHIFT-drag pans (`_o3 += delta`), wheel zooms `_z3`,
  fit-screen IconButton = `_fit3` (zoom-extents: projects the bounds'
  8 corners at unit zoom, scales into ~85% of the usable viewport,
  centers the unit-space bbox on the _k3DSafe rect), reset-view icon restores defaults. FOCUS MODE
  (`_vp`, `_Vp {plan, split, model}` — was `_focus3`): either canvas
  can take the whole content area. Keys 1/2/3 = plan/split/3D, F
  toggles 3D focus, each pane's top-right icon row carries a
  fit + maximize/restore button (fullscreen vs fullscreen_exit icon,
  caption flips to 'PLAN FOCUS'/'3D FOCUS'). The
  `CallbackShortcuts`+`Focus` wrapper lives OUTSIDE the split so keys
  still work while either canvas is unmounted; Esc's cascade ends
  with `_vp = _Vp.split`.
- MODEL VIEW PERSISTS ACROSS TABS (same contract as drawingXfms):
  `dispose()` writes {_pScale,_pOff,_yaw,_pitch,_z3,_o3,_vp} into
  `est.modelCam` (Map<String,double>, in-memory only — NOT serialized)
  and the selected model's index into `est.modelSel`; `initState()`
  restores them. main.dart builds `const ModelView()` per build — no
  keep-alive — so without this every tab switch refit the view.
  `est.newProject()` clears both so a new project still refits.
- 2D/3D NAV PATTERN (AutoCAD/SketchUp convention): the plan viewport
  pans three ways — select-tool empty-drag (`_panLast`), SPACEBAR-drag
  in ANY tool (`_planStart` checks
  `HardwareKeyboard.instance.isLogicalKeyPressed(space)` BEFORE the
  tool switch, `_planUpdate` honors `_panLast` ahead of drawing), and
  MIDDLE-BUTTON drag (`_midPan` set in the Listener's onPointerDown,
  `_pOff += delta` in onPointerMove — drag recognizers filter to
  `kPrimaryButton` so the GestureDetector never sees it). The 3D
  canvas uses the same `_midPan` stream to pan `_o3`. `_midBlock`
  swallows the stale tapUp/panEnd a middle-release may still fire —
  set on mid-up, cleared on the NEXT pointer-down (postFrame clearing
  proved flaky — don't reintroduce it). Cursor flips to grabbing while
  mid-panning or space held. Canvas-overlay hint text must be wrapped
  in `IgnorePointer` — a `Center`+Text overlay shadows the canvas'
  hit area under the text (a middle-drag started on the empty-state
  hint silently did nothing until it was wrapped).
- PLAN GRID is multi-scale: `planGridLevels(pScale)` (public, unit-
  tested) -> base `step` (>=26px apart, every 5th major), `sub`
  (step/4 at >=1m => 0.25m subs, step/5 at 0.5m => 0.10m), and
  `subAlpha` fading 0..0.9 as subs gain 5.5-14.5px of room.
- SHARED WORLD LATTICE (task 7): `gridLinePositions(lo,hi,step)`
  (public, unit-tested) yields exact step-multiples inside [lo,hi]
  — BOTH the plan grid and the 3D ground grid draw this lattice, so
  (0,0) is always a line intersection in every view and the grid
  agrees with the world-anchored 0.25m snap. The 3D grid step comes
  from `planGridLevels(_pScale).step` (plan zoom drives the shared
  LOD) and its bounds cover model-envelope ±3m clamped to include
  the origin — never reintroduce a bbox-centered or fixed-spacing
  grid. Sub-line skip uses `(x/sub).round() % div` index math on
  the same lattice — never float-multiple comparisons. Plan tints
  the x=0 column green / y=0 row red (SketchUp axis colors, ~0.28
  alpha) so the origin is legible like the 3D RGB tripod.
- MODEL RAIL collapse (task 9): `est.modelRailOpen` (in-memory, reset
  by `newProject`) — same flag pattern as `drawingLibraryOpen`. The
  200px `_rail` collapses to a 40px icon strip (chevron-right expand,
  + new model, selected-model icon + count); the freed 160px splits
  across plan|3D per `modelSplitFrac` (NOT all to the plan — tests
  asserting pane growth must expect ~half the rail width).
- STATUS STRIP (`_statusStrip`, task 8): ONE 26px bar under the
  viewports replaces per-pane bottom overlays — tool pill, hovered-
  pane hint (`_over3` = model-mode OR split+`_hover3!=null`), selection
  summary, snapped cursor readout (plan X,Y / 3D ground X,Y,Z via
  `_s2g`, `—` when not editable/hovered), SNAP chip (toggles `_snap`),
  hovered-pane zoom % (plan `_pScale`/40, 3D `_z3`/30). `_inPlan`
  tracks plan MouseRegion enter/exit; a 3D `MouseRegion(onExit)`
  clears `_hover3` on leave — do NOT rely on pointer-down alone to
  clear it. Zoom % is relative to each pane's default (40px/m plan,
  30px/m 3D) — `_fitPlan` changes `_pScale` so tests must NOT assert
  a literal `100%`.
- SHORTCUT HUD (`_hudCard`, `_hud`, task 11): `?` (Shift+/) or `F1`
  toggles a floating cheat-sheet card over the viewports — a `Positioned`
  card in the Stack that wraps the plan|3D content (outside the
  `CallbackShortcuts`/`Focus` wrapper so it never eats keys; only the
  card rect blocks pointer hits, canvas stays interactive elsewhere).
  Sections TOOLS/CANVAS/VIEW/EDIT mirror the real `_keys()` bindings —
  keep it in sync when adding hotkeys. Toolbar `?` IconButton (tooltip
  'Shortcuts (?)') sits after the poly tool and shows active state while
  open. `_esc()` closes the card FIRST before the normal cancel cascade
  (chain/points -> selection -> tool -> `_vp`) — the live-verified UX is
  Esc=HUD off with an armed wall chain untouched, second Esc=chain
  cancelled.
- SNAP INFERENCE (`snapTarget`/`_snapPt`/`paintSnapGlyph`, task 12):
  SketchUp vocabulary — endpoint (green square+halo) > midpoint (cyan
  triangle) > EDGE (red open square = foot of perpendicular ON a
  segment — T-wall clicks land exactly on the existing centerline;
  a bare grid snap can sit ~12cm off and silently miss the <=6cm
  join tolerance) > axis > grid (dim `+`), ~9px pick radius.
  `_snapSources()` is the shared eps/segs collector — `_snapPt` AND
  `_edgeOffset` read it so clicks and typed offsets infer identically.
  Candidates = wall
  centerline verts, volume footprint corners, block centers, the
  active tool's chain pts and `_rect0` (endpoints) + wall/volume/chain
  segments (midpoints). ONE target feeds previews, ghosts, the status
  readout and the tap/drag commits — never paint a marker the click
  won't honor. CRITICAL: the 3D call passes `proj:` (a screen
  projector, `_projGround`) so the radius is measured in PIXELS —
  world-unit tolerance shrinks the radius along the depth axis by
  1/sin(pitch) and silently dead-zones vertices near the cursor.
  `_wall`/`_projGround` etc. are private — tests must use the
  `@visibleForTesting` getters (`wallChainDebug`, `debugProjGround`),
  NOT `st._x` on the dynamic state (private names don't resolve
  cross-library even via dynamic).
- CURSOR MAP (task 13, `planMouse`/`m3dMouse` keys): draw tools ->
  `precise` crosshair; select -> `click` hand over a part else `basic`
  arrow; space armed (plan) / shift armed (3D) -> `click`/`move`; ANY
  active drag (`_midPan`, `_panLast`, `_moveLast`, `_drag3`) -> `move`
  SIZEALL. `_overPart` recomputes on EVERY plan hover (cheap
  `_blkAt`/`_wallAt`/`_volAt`); `_overPart3` runs `_pick3` only after
  the cursor travels 8px (face projection per hover is heavy). The
  Focus wrapper's `onKeyEvent` setStates on space/shift transitions —
  modifier cursors need a rebuild, not just the key state. WINDOWS
  CURSOR SUBSET: `SystemMouseCursors.grab`/`grabbing`/`allScroll`/
  `progress`/`contextMenu`/`help`/`zoomIn`/`zoomOut` render as the
  plain ARROW on Windows Flutter — the supported set is basic(ARROW),
  click(HAND), precise(CROSS), move/allScroll->use `move`(SIZEALL),
  text(IBEAM), wait, forbidden(NO), resize*. Never use `grab`/
  `grabbing` for feedback here — they silently show the arrow
  (verified live via GetCursorInfo handle matching).
- PLAN|3D SPLITTER: the fixed `Expanded` pair is a `LayoutBuilder` +
  10px in-flow sash (`_splitter`, key widget `Icons.drag_indicator`).
  `est.modelSplitFrac` (in-memory only, 0.5 default, clamped 0.2–0.8,
  reset by `newProject`) drives `planW = avail*frac` with guards
  plan≥240 / 3D≥280 (upper bound floored at 240 so tiny widths can't
  invert the clamp). Drag updates the fraction via `setModelSplit`;
  `onDoubleTap` resets to 0.5; hover recolors the strip +
  `resizeColumn` cursor. The sash is a Row SIBLING (not an overlay)
  so it can never eat canvas edge interactions.
- UNDO/REDO (`_undo`/`_redo`/`_pushUndo`/`_undoOp`/`_redoOp`, Ctrl+Z /
  Ctrl+R / Ctrl+Y / Ctrl+Shift+Z): a per-MODEL pair of
  `jsonEncode(m.toJson())` snapshot stacks (cap 60) pushed BEFORE
  every structural op — wall close, block place, part move-grab,
  thickness apply, rect/poly commit, delete, array, seat button,
  inspector field commits. `_pushUndo` clears `_redo` (classic
  contract). `_undoOp` pushes live state onto `_redo` then restores;
  `_redoOp` mirrors it. `_restoreSnap` covers EVERYTHING toJson
  carries — name, dims, roof spec, sheetPan — not just the part
  lists (an early version spliced only volumes/walls/blocks and left
  stale roof spec + dims after a revert). CONTINUOUS edits (typing
  in an inspector field) must NOT push per keystroke — call
  `_pushUndoTick(key)` instead: one snapshot per field per ~1.2s
  burst; a discrete `_pushUndo` resets the burst key. The stacks are
  cleared on every `_sel` change — never let them leak across models.
  `pushUndoForTest()` is the widget-test hook.
- GENERATE emits ONE DXF PER VIEW via `buildModelSheet(m, SheetView)`
  — ten `DrawingFile`s `sheet:<modelId>:{floorplan,structural,
  roofframe,electrical,plumbing,roofplan,front,rear,left,right}` in
  `%TEMP%\ce_gen\`, updated idempotently (the old
  combined `sheet:<id>` entry is removed). Each sheet is normalized by
  ITS view's shared min; the floor plan carries wall hatches + seg
  dims + furniture, elevations get a z=0 baseline + view label +
  'MODEL: name' title. `buildModelDxf` (combined 7-view sheet) stays
  for back-compat/tests. Elevation opening detail is projected from
  the block's REAL mesh (`_openingMeshElev`): view-parallel mesh
  faces flatten onto (u,z) deduped — frame/sash rails/staggered
  sliding leaves/sill board draw exactly as the 3D model renders;
  defs with no mesh (or <2 projected faces) keep the generic
  rect+sill-horn+mid-rail symbol.
  SHEET ANNOTATIONS: `_elevScene(m, view)` is the ONE shared
  elevation pass — it returns `(prims, hosted)`; `elevationPrims` and
  `hostedOpenings` are thin wrappers so sheets/tests share the same
  hidden-line + host-wall filtering. `blockTags(m)` assigns schedule
  tags by m.blocks index — D# (door*/doorway*), W# (window*), O#
  (other openings) — so plan and all four elevations agree. The plan
  prefixes opening labels with the tag ('D1 · Door 0.90'); elevations
  callout every drawn opening — floor-level doors tag ABOVE the head,
  raised openings stack tag + 'SILL h' underneath, and `_openingDims`
  adds real DIMENSION STRINGS per opening: a horizontal width string
  below the sill (or above a grade-level head) and a vertical height
  string on the roomier side (sibling-gap pick), 45° ticks + rotated
  text via `_text`'s `rot:` (DXF code 50 — the composer MUST re-emit
  tx.rotation or vertical texts flatten). `_text` insertion for rot:90
  = the string's bottom end, so y = zmid - halflen centers it
  (test/elev_anno_test.dart).
  SHEET LABEL LAYOUT: `_SheetLabels` (model3d.dart) is the AABB
  collision tracker behind plan/structural/MEP annotation — every
  emitted text claims a sheet-space box (`labels.claim`, or the
  `labels:` param on `_dimString`/`_diagStrings`/`_roomLabels`), and
  movable labels negotiate free slots with `labels.hits`. ORDER IS
  THE CONTRACT: fixed ink claims first (dim strings -> dimEdge ->
  manual dims -> room names), then block labels run LAST in
  `_sheetContent`. Opening tags park OUTSIDE their wall (dominant
  axis from the wall-envelope centre, 1 line — the name already
  carries the size and dimEdge draws the width); solids try below ->
  above -> along-run shifts -> flanks, dropping the WxD second line
  before dropping the tag. `dimEdge` keeps its dim LINE anchored and
  negotiates only the VALUE (along-run shifts, further out, then
  drop). Structural F#/FP# callouts negotiate centred under pads ->
  above -> sides, falling back to the bare tag inside the pad. Tests:
  label_layout_test.dart renders a furnished model and asserts zero
  text-box overlaps — the audit box must match _SheetLabels.box.
- `lib/cpm.dart` - PERT/CPM engine: topological order + forward pass
  (ES/EF) + backward pass (LS/LF) + slack + critical path + cycle
  detection + level/lane layout for the network diagram; also
  `buildSCurve` (weekly planned/cumulative % over the contract days,
  `weights:` = live activity costs, `unworkableDays:` stretches the
  horizon so planned finish lands at CP + unworkable). Each activity's
  weight spreads over its available [ES, LF) window - critical rows
  behave like an early schedule, float-rich work spreads over the
  window the logic allows (keeps a dominant-cost non-critical section
  from cliffing the curve into one week).
- `lib/schedule.dart` - `generateSchedule(sections, costOf, targetDays:)`
  emits EXACTLY ONE activity per BOQ section (name = section title,
  `sectionId` linked, id 'auto:SECTION_ID') - no invented stages or
  virtual mobilization/turnover rows; anything not in the BOQ must not
  appear. `_trades` classifies each title into a `_graph` phase slot
  (mobl -> site -> earth/form/srebar -> pour -> chb -> rough-ins | roof
  -> plaster -> dw/ceil2/tile -> paint); preds resolve absent phases to
  the nearest earlier present one, transitively reduced, so concurrent
  trades still land on parallel lanes. Durations: k-day effort scale
  normalized by total cost weight, bisected so `cpDuration` ~=
  targetDays (CD - unworkable), floored at each trade's minDays.
  `kScheduleVersion` bumps force stored projects to re-sync onto new
  topology even when the BOQ signature is unchanged.
- `lib/state.dart` schedule sync: `est.syncSchedule()` merges the
  generated specs with existing rows by activity id - `nameFixed`/
  `daysFixed`/`predsFixed` survive, deleted auto rows stay suppressed
  in `suppressedAutoIds`, hand-added rows (auto=false) keep their spot.
  No-op while `project.autoSchedule` is off or `_sig()` unchanged.
  `rebuildScheduleFromBoq()` clears overrides+suppression and forces a
  regen (also clears `lane` pins); `reletterPreds()` keeps `preds`
  letter strings truthful after insert/remove/move; `activityCost(a)`
  = section.subtotal * costShare for BOQ-linked rows so the S-curve
  follows live BOQ edits. `moveActivityToCell(a, level, lane)` is the
  drag-drop op from the network diagram: same-level drop just sets
  `a.lane` (presentation only); a cross-level drop rewires `predIds`
  to every activity one level left (excluding `a` itself), sets
  `predsFixed`, validates with `computeCpm()` and rolls back
  predIds+preds+lane on a cycle, then sorts rows by level/lane and
  re-letters. `CpmActivity.lane` (serialized, -1 = auto) pins a lane;
  the barycenter layout in `computeCpm()` honors pinned lanes first.
  Contract duration = critical path + `project.unworkableDays`
  (pre-determined unworkable days, per NIA "calendar days inclusive of
  unworkable days"); `est.applyCpmDuration(days)` writes it as
  'N calendar days' - the PERT-CPM tab's duration strip drives it.
- `lib/scurve_chart.dart` - `SCurvePainter` shared by the tab preview
  and the PNG the exporter embeds; `renderSCurvePng` rasterizes it.
- `lib/docx_export.dart` - extension letter .docx; `buildEstimate()`
  delegates to `lib/docx_estimate.dart` (async: renders chart PNGs).
- `lib/docx_estimate.dart` + `lib/pdf_export.dart` - PDF/DOCX that MIRROR
  the workbook: Letter, Arial (PDF loads C:/Windows/Fonts/arial*.ttf,
  falls back to Helvetica + ASCII-sanitised text), logo letterhead +
  theme-color rule, boxed 5-row project block (same label/value split
  as the sheet), 2-row header in themeColor with `fgOn` text, section/
  group/subtotal/summary bands from the project's colors, GRAND TOTAL in
  themeColor, signatories (2 per band portrait, <=5 spread landscape).
  BOQ + POW portrait; PERT-CPM table, PERT-NETWORK image, S-CURVE
  table+chart landscape (docx: per-section `sectPr`; header rows
  `tblHeader` repeat; numeric columns widen to the longest figure).
  PDF rows are built from `_Spec`s so each row's cells share the tallest
  cell's height (pdf pkg has no IntrinsicHeight, no col spans).
- `lib/network_chart.dart` - `renderNetworkPng` draws the PERT diagram
  like the PERT-NETWORK sheet (3x4 node blocks, critical = subtotalColor
  fill + theme border, orthogonal channel-routed connectors) for PDF and
  DOCX; `kChartFontFamily` is a TEST hook (gen_exports_test loads Arial
  so sample images have real text; null in the app).
- Toolbar (`_TopBar` in main.dart): brand on the left; actions in
  `_BarGroup` pills (New/Open/Save | Pricing/Labor/Colors) + primary
  `_ExportMenu` pinned to the far right via `Expanded(Align(
  centerRight, FittedBox(scaleDown)))` — `ImportButton` (lib/ui/
  import_menu.dart) sits just left of it: file picker accepting
  xlsx/csv/tsv/txt/pdf/docx → `BoqImport.fromFile` parses to draft
  sections → preview dialog (sections, item counts, warnings) →
  `est.importBoq(sections, replace:)` commits append-or-replace with
  fresh uuids. Labels show >=1240px, icons-only
  (tooltips) below; the cluster scales instead of clipping. Never reuse
  Icons.edit_outlined here - widget tests find the pen tool by it.
  The project chip + ProjectDialog were REMOVED (redundant): project
  fields edit inline on the BOQ sheet header + title on generated
  sheets, unworkableDays lives in PROJECT SCHEDULE; the project tab
  strip already shows the title.
- `lib/boq_import.dart` - BOQ table importer. Every extractor emits
  `List<List<String>>` rows and shares `rowsToSections`: detects a
  column-header row (desc|qty|unit + a cost column — the POW sheet's
  WORK ITEM/QTY/TOTAL/REMARKS layout fails the cost gate and is
  skipped), merges a following 'Material Cost|Labor Cost' sub-header
  into the unit-cost pair + shifts trailing columns by the span diff,
  falls back to positional columns (warns). Text-only rows → section
  when they carry a roman/letter/number prefix ('I.', 'PART 2'), else
  groupHeader when a section exists and the text is mostly-caps; item
  rows map desc/qty/unit/material/labor (+amount→unit-cost derive when
  only a total column exists). `_stopRow` kills first-cell junk;
  `_killAnywhere` kills summary tails ('I | DIRECT COST | 62,920') in
  ANY cell. Extractors: xlsx via `excel` (only sheets whose first 60
  rows contain a header — skips PERT/S-CURVE/DATA/POW), csv/tsv/txt
  (RFC-4180 quoting + delimiter auto-detect), docx via archive+xml
  (`w:tbl`→`w:tr`→`w:tc`, `w:gridSpan` expands to padding cells —
  NOTE: xml pkg's findElements/getElement need qualified names;
  `e.name.local == 'x'` matching and `getAttribute('val',
  namespace: '*')` are what actually work), pdf via pdf_import.dart.
- `lib/pdf_import.dart` - pdfium FFI (dart:ffi, no new deps): the
  pdfium.dll bundled by pdfx (Release dir / pdfium-src/x64/bin).
  MUST call `FPDF_InitLibraryWithConfig` (config v2, all-null) BEFORE
  FPDF_LoadDocument — without it the dll hard-crashes the process.
  Per page: FPDFText_LoadPage → per-char FPDFText_GetUnicode +
  FPDFText_GetCharBox → cluster chars into lines by baseline (±40%
  height), split lines into cells on gaps > ~2.2× median char width →
  rows for rowsToSections. Scanned PDFs (zero chars) fail honestly.
- Export orientation contract: BOQ/POW portrait, PERT-CPM/PERT-NETWORK/
  S-CURVE landscape in xlsx (`pageSetup`), pdf (page formats) and docx
  (`sectPr`). `test/gen_exports_test.dart` regenerates sample_estimate.
  pdf/.docx; verify pdf with PyMuPDF and docx with `tool/render_docx.py`
  (one PNG per page).
- Excel column/anchor geometry (verified against real Excel COM
  `Range.Left/Width` + `Shapes`): a stored `<col width="w">` is exactly
  `w*7` px (the stored value already includes Excel's 5px padding -
  `w*7+5` was wrong and put every logo 7-20px off-center); an unlisted
  column is the 64px default (= 64/7 units). `_centeredAnchor` uses
  this. The logo is 54pt tall and sits at rowOff 0: rows 1-4 above the
  first letterhead line are only 57pt, so any rowOff > ~3pt makes it
  overlap "Republic of the Philippines".
- S-CURVE sheet = A..H weekly table + chart PNG anchored at col I
  (`_curveChartCol/ColOff/Cx/Cy` shared by `_injectMedia` and the span
  math). `_curveLastCol` (= 22, the column holding the chart's right
  edge) is DERIVED from those constants, and letterhead/rule/title/
  signatories all merge 0.._curveLastCol so they center over table +
  chart. Signatories use `_signatureRowWide` (equal column shares,
  <=5 per 8-row band, parked below the chart bottom); PERT-NETWORK
  uses it too (the old 2-column block clipped a long name).
  `test/export_test.dart` "landscape spread" asserts all of this from
  the raw XML using the same px model.
- `tool/render_xlsx.py` no longer forces portrait: it used to set
  `Orientation = 1` on every sheet, hiding the injected landscape
  `<pageSetup>` (renders looked portrait even though the file was
  landscape). It now renders the workbook's own orientation.
- `lib/open_file.dart` - `openExportedFile(path)` launches the saved
  artifact in its associated app via `Process.start('explorer',[path],
  detached)`; explorer exits 1 even on success so it is fire-and-forget
  (never awaited). Called after every export write (main `_export` +
  extension DOCX).
- `est.newProject()` (New button in the top bar): resets BOQ,
  activities, extensions, drawings, marks, summary rows and
  `savedPath` to a blank estimate. Letterhead, logo, signatories,
  theme colors, `priceDb` and `laborRate` carry over (reusable
  assets). Confirmed by a dialog before wiping.
- Top-bar buttons sit in an `Expanded`+`SingleChildScrollView`
  (reverse: true) so the row can never overflow on narrow windows;
  the two-line title collapses to one line under 1480 px. NOTE:
  flutter_test renders ~2x wider glyphs than real fonts, so the bar
  overflows in tests sooner than on screen - the scroll view covers
  both; use `tester.ensureVisible` before tapping off-screen buttons.
- `lib/state.dart` autosave: `notifyListeners()` is OVERRIDDEN to arm a
  700 ms debounce -> `autosaveNow()` writes
  `%APPDATA%\ConstructionEstimate\autosave(-<id>).boqproj` (+ the
  savedPath file if the project was explicitly saved). Every mutation
  on every tab funnels through it. `main()` calls
  `projectTabs.restore()` before runApp (manifest + per-tab autosaves),
  then enables autosave (stays false during load to avoid save loops).
  Never call `autosaveNow()` in tests - it writes the real %APPDATA%
  file; `projectTabs.autosave` also gates manifest writes in tests.

## Domain facts

- DepEd SDO Camarines Sur template: sections lettered A-Z, group headers
  are location labels, SUB TOTAL per section, summary = Direct + 7% + GT.
- 69 materials in the template have price 0 - fill them in via Pricing page.
- Letterhead is fully editable: `project.letterhead` (list of lines, first
  3 get the top rule, `letterheadBold` = index of the bold line,
  `letterheadSmall` = indices of small-font lines) + `project.logoB64`
  (PNG/JPEG, persisted in `.boqproj`). Edit in place on the sheet preview
  or right-click a line (add/insert/emphasize/delete); the logo badge
  above the lines opens a file picker.
- Row context menus: right-click any section header, group-label row, or
  item row in DETAILED ESTIMATES -> add item/group label above or below,
  rename/add/delete section, delete row (`_rowMenu` in sheet_view.dart).
- Exported xlsx gets images via `archive`-level zip injection in
  `ExcelExport._injectMedia` (logo on every letterheaded sheet through
  drawingN.xml; the S-CURVE sheet also gets the chart PNG as a second
  pic; logo may be null - chart-only inject works too). Default asset:
  `assets/deped_logo.png`, loaded into `project.logoB64` at startup in
  `main.dart`; custom logo = `est.pickLogo()` (file_selector).
- PERT export = TWO sheets: `PERT-CPM` = the live formula table
  (ES=MAX(pred EF), EF=ES+DAYS, LS=LF-DAYS, LF=MIN(succ LS)|$K$durRow,
  SLACK=LS-ES - DAYS/PREDECESSORS are editable values, the whole
  network recomputes in Excel) and `PERT-NETWORK` = the diagram as
  bordered cell blocks whose values are cross-sheet formulas into the
  table; connectors are real cell borders routed through gap cols +
  each band's empty channel row (`_writePertNetwork`). When the CPM
  has a cycle, PERT-NETWORK is skipped and the timing cells go blank.
- Project-block labels are merged A:C on BOQ (rows 15-19) and A:B on POW
  (rows 13-17, wide work-item column is C) - do NOT unmerge or labels
  clip again.
- Layout mirrors the user's template `Desktop\pay julan\phase1.xlsx`: BOQ
  runs SUB TOTAL straight into SUMMARY (merged A:I); POW has a 2-row
  merged header (21-22), a B:C-merged spare row, then SUMMARY: (A:H).

## Excel export gotchas (excel pkg 4.0.6)

- `Sheet.merge()` DELETES every covered cell, so no `<c>` is written for
  them and Excel drops the merged range's borders/fill. Never rely on
  styling cells before a merge: `build()` runs `_finalizeMerges` on BOQ
  and POW after all writes (calls `setMergedCellStyle` per span). Keep it.
- Writes into a merged coordinate silently redirect to the anchor cell.
- `_mergeRow/_mergeCells/_mergeRange` keep the anchor's style across merge.
- openpyxl FABRICATES merged-cell borders from the anchor - it reported
  `YYYY` for a sheet Excel drew with holes. Never trust it for borders.
- The pkg emits `sheet1.xml.rels` + an EMPTY `drawing1.xml` for BOQ but
  never writes the `<drawing r:id="rId1"/>` element into `sheet1.xml` -
  without it Excel ignores the drawing part entirely (logo was invisible
  on BOQ while POW worked). `_injectLogo` appends the element + a
  drawing-rels entry if absent. For sheet2 we write drawing2.xml, the
  `<drawing>` element, rels, and the Content_Types override ourselves.
- `oneCellAnchor` colOff is CLAMPED to `from.col`'s width: to center the
  logo you must compute which column the target x lands in and pass the
  remainder as colOff (`_centeredAnchor`). Extent 685800 EMU (~0.72")
  keeps it above the letterhead text.
- `ExcelExport.build()` is async and returns `List<int>?` (null on
  failure) because `renderSCurvePng` awaits `picture.toImage`.
- Chart PNG text: under `flutter test` the picture renderer uses the
  placeholder test font, so axis labels come out as dashes in a test-
  generated sample - in the real app fonts load and labels render fine.
- `CellIndex.toString()` is NOT an 'A1' string - use the `_colName`
  helper (0->A) when composing cell references like `'F$row'` from ints.
- `testWidgets` + real file IO: futures created inside the fake-async
  zone never complete (File.exists() hangs forever) - either keep the
  load path synchronous (sync existsSync/readAsStringSync as in
  `_load` for dxf) or wrap the wait in `tester.runAsync`. A spinning
  CircularProgressIndicator makes every `pumpAndSettle` time out.

## Verifying the xlsx export (simulation)

1. `flutter test` (regenerates `sample_estimate.xlsx`; the test
   "every BOQ/POW grid cell is written with its edge borders" parses raw
   XML and fails if any merged/grid cell is missing or lacks edges;
   "custom agency letterhead" covers the dynamic row layout;
   `test/letterhead_sim_test.dart` writes a real xlsx with a custom
   letterhead + real PNG into the system temp dir).
2. `python tool/verify_xlsx_borders.py sample_estimate.xlsx` - same check
   on raw XML (non-vacuous: aborts if the table extent collapses).
3. `python tool/render_xlsx.py sample_estimate.xlsx <outdir>` - renders
   every sheet (skips DATA) through a PRIVATE hidden Excel (DispatchEx,
   aborts if it would attach to the user's running Excel, kills only its
   own PID) to PDF -> PNG; view the PNGs. Needs `pip install pywin32
   pymupdf`. PDF export has no gridlines, so every visible line is a real
   border.
3b. `python tool/probe_xlsx_logo.py sample_estimate.xlsx` - asks the same
   private Excel for the logo picture's real position: header-center vs
   logo-center delta per sheet (expect |delta| < 1px; POW's letterhead
   line 1 is unmerged so its row is not meaningful) and logo-vs-row5
   overlap (expect negative). Use it whenever anchors/column widths move.
4. `python tool/render_docx.py <file.docx> <out.png>` - same private-
   instance pattern for Word (PID found by diffing WINWORD before/after
   DispatchEx; Word.Application has no Hwnd).

- Model tool keys: A=select R=rect(rotate when block) P=poly W=wall
  B=block E=eraser(sweep-delete blk>dim>wall>vol, one undo/stroke,
  custom painted eraser cursor + SystemMouseCursors.none) D=dim
  (drag A->B aligned dim -> `Model3d.dims` [ax,ay,bx,by], serialized).
  TYPED ENTRY (`_dimIn`/`_dimKey`, AutoCAD direct distance): with a
  wall/poly chain open, digits set the next point's length along the
  cursor direction (`_dimPoint`); with the wall tool and NO first
  point yet, digits are an OFFSET ALONG the existing wall nearest
  the cursor (`_edgeOffset` — measured from the nearer endpoint,
  dashed anchor-leader + bold label preview, <=14px proximity gate)
  so an intersection wall starts at an exact distance from a corner.
  Enter or a click commits; Esc clears input first, chain second.
- Dimension strings: `wallOrds(m, xAxis)` in model3d.dart is the
  SHARED ordinate source for the plan painter's `_extDims` AND the
  DXF `buildModelSheet` `_dimString` emitter — keep them on it.
  Per-side strings filter ordinates to the near half of the bound
  and extension lines start AT the bound edge (never inside the
  plan). Manual dims render in painter via `_manualDims` and export
  in the floorplan DXF.
- The plan toolbar's right-side controls (snap/dims/unit/fit) are
  PINNED outside the tools scroll view — a wider tool pill once
  pushed the snap chip off-viewport and broke widget taps.

- Props tab (`_objectList` in mv_inspect.dart) is a custom accordion,
  NOT ExpansionTile: header tap toggles selection, the editor body
  (`_wallBody/_volBody/_blkBody`, 2-column `_pf` fields) is built only
  for the selected row, so canvas picks and list taps share one source
  of truth. While `_rightTab == 2` canvas picks do NOT jump to Inspect.
  Regression: test/props_test.dart.
- Dimension de-clutter rules (painter AND DXF): single-span strings
  print ONE bold figure (no outer duplicate line); gaps < 0.10 m lose
  their number; perimeter/diagonal wall segs lose their mid-wall label
  (a string already covers them); mostly-diagonal plans (>=60% of wall
  length) keep only the overall axis extent; diagonal strings use the
  wall's OWN centroid for "outward", rotated upright labels
  (`_lblAngle`), and `_dedupe` drops labels within 22px of another.
- Generated floor-plan DXF: room name+area TEXT, north arrow, graphic
  scale bar. The sheet template (`_paperFurniture`) is the DepEd
  signature strip spanning the full frame bottom: top row = DepEd logo
  cell | LOCATION | wrapped project title | DATE (long form), bottom
  row = up to 4 `project.signatories` columns (label/name/position);
  big drawing title + `SHEET A-1xx`/`SCALE 1:N` meta line sit above it.
  `buildModelSheet(project:)` takes `ProjectInfo` (defaults when null).
  test/sheet_test.dart.
  TITLE-BLOCK HOTSPOTS: in the DRAWINGS viewer the strip's logo and
  title cells are live overlays, not just painted DXF — cell rects come
  from `sheetTitleCells(scene.bounds)` in model3d.dart (ONE source of
  truth — `_paperFurniture` derives its strip layout from it; the
  paper border is the outermost entity so bounds == paper rect). Logo
  cell tap -> `est.pickLogo()` + right-click remove menu (covers the
  painted 'DepEd' with the real `project.logoB64` image). Title cell
  tap -> WYSIWYG in-cell TextField at sheet scale (live-writes
  `project.title` per keystroke, `project.titleSize` mm glyph height
  serialized, Esc reverts the _titleBefore/_titleSizeBefore snapshot);
  a corner handle drags `titleSize` 1.2..9mm. TWO GOTCHAS: the field's
  `onTapOutside` fires on pointer-DOWN — the handle must sit in the
  same `TapRegion(groupId:'sheet-title')` (TextField.groupId) or the
  down commits the editor and disposes the handle mid-gesture; and the
  handle uses a raw `Listener.onPointerMove`, NOT a pan recognizer —
  the TextField's selection-drag/Tooltip recognizers win the arena at
  the cell edge (verified: pan got PAN CANCEL with zero updates).
  Cells sit ABOVE the marks gesture layer; panning locks while
  _titleEdit. Keys `sheet-cell-logo/title`, `sheet-title-field`,
  `sheet-title-size`. test/sheet_cells_test.dart.
  TEST DATA DIR: `ProjectTabs.dataDirOverride` redirects
  %APPDATA%\ConstructionEstimate (sessions.json + all autosave files —
  `EstimateState.autosaveFile` shares it). ALWAYS set it in tests that
  pump the app, else `projectTabs.restore()` loads the developer's
  REAL project mid-test and mutations hit real autosaves.
- Real-exe smoke: ce_win.ps1 click coords are NOT screenshot pixels
  (DPI offset) - calibrate with a known button before trusting them.

- BIM object import (`lib/ifc.dart`, 3D MODEL > Blocks > Import .obj/.stl/.ifc):
  parses IFC2X3/IFC4 FACETEDBREP solids (manufacturer exports) with
  colors+transparency; BIM exports are Y-up -> mapped (x,y,z)->(x,z,y).
  Caveat: that mapping is verified on the GEALAN S9000 sample whose
  IFCMAPPEDITEM swaps Y/Z itself — it is NOT a universal IFC
  convention, so other exporters' IFC may need axis review.
  IFCDOOR/IFCWINDOW -> registered as an `opening` block (cuts walls,
  persisted via customBlocksJson with cat/opening/sill/head). BIMobject
  zips contain .rfa/.adsklib/IFC/PDF - NO dwg/skp; IFC is the usable
  geometry. Sample: GEALAN S9000 sliding door (5584 faces). Revit .rfa
  is not parseable. Test: test/ifc_test.dart (reads %TEMP%/gealan.ifc).
- Openings carry sill/head (CadBlock): windows 0.90..2.10 (bath 1.40),
  3D walls keep apron+lintel via `_openingBands`; procedural windows in
  `registerProceduralWindows`.

## Mesh ordering + pro AI render (latest)
- `_SolidPainter` MESH groups (>24 faces): vertical faces (|n.z|<0.5)
  sort by depth-range MIDPOINT, horizontal faces by FARTHEST vertex;
  no hairline strokes on mesh groups; sub-pixel cull 0.35px2.
  Tried + rejected: pure nearest-vertex (big door face's near corner
  hides handles), pure centroid (clips bed pillows under mattress),
  backface cull (kit meshes have inconsistent winding -> holes).
  Regression: test/mesh_order_test.dart (mirrors the key; eyeball PNGs
  in test/out/mesh_*_near.png).
- AI render = `museEnhanceBest` (ai_render.dart): N=2 parallel Muse
  Image edits -> `museJudgeRender` (spark vision JSON score+fix) ->
  best kept; <8 score triggers one critique-folded regeneration.
  Prompt `kAiRenderPrompt` uses photography vocabulary + avoid-list.
  AI on => plate never Draft. `EYE-LEVEL` preset view (pitch 0.1).
  Live check: test/ai_pro_test.dart (skips without muse_key.txt).

## Model -> BOQ takeoff
- `lib/takeoff.dart`: `modelTakeoff(Model3d)` measures wall length /
  gross area (grouped by thickness), openings (each attributed to the
  ONE nearest wall seg, same 0.75*t test as wall piercing; area =
  footprint width along wall x (min(head,top)-max(sill,base))),
  floor area (all volumes), slab vol (volumes <=0.5m tall) + column
  vol, stairs. `takeoffMasonry/Painting/Concrete/Tiles` call the
  existing `calc*` so results equal the manual forms; CHB 4" for
  t<=0.125 else 6" (price DB has no 8"). `insertTakeoffWork` ->
  `est.addWork` with group header "3D MODEL - X unit".
- UI: `lib/ui/takeoff_card.dart` ("FROM 3D MODEL", top of WorkPanel,
  collapsible, model dropdown if >1). Per-work buttons send a
  `ModelPrefill` (kind/volume/area/aperture/side/height/count/chb/
  label) via `onPrefill` -> `_WorkPanelState._openPrefill` which
  switches `_type` and passes it into the REAL form widget keyed by
  `ValueKey(prefill)` (remount = fresh values). Forms apply prefill in
  initState — user edits CHB/mortar/class/system/etc before ADD TO
  BOQ. Masonry prefills the DOMINANT thickness group (`mainThk`).
  "Add all" still instant-inserts every package with defaults.
- Tests: takeoff_test (exact geometry), takeoff_ui_test (prefill ->
  edit -> BOQ, Add all -> BOQ -> xlsx; export MUST run in
  `tester.runAsync` or it hangs).
- Not done (phase 2): per-line traceability + "Refresh from model".

## Structural options (NSCP 2015)
- `lib/structural.dart` — pure schedule layer, all SI (bars mm):
  `columnSched` (410: 1%<=Ast/Ag<=8%, min 4 bars, ties 10mm @
  min(16db, 48dt, least dim) cap 0.20), `beamSched` (dia by span
  <=3m=12/<=4.5=16/>4.5=20, 4 bars, stirrups 10mm @ min(d/2,0.20)),
  `footingSched` (square, side ~5x col min 1.0, t=max(0.25,W/5)
  NBCP, 12mm@0.20 / 16mm@0.15 >1.5m), `wallFootingSched` (strip
  3x wall thk, 0.25), `slabType` (ONE-WAY iff long/short >= 2),
  `slabMinThk` (one-way max(L/28,0.075), two-way 0.125),
  `slabSched` (two-way 10mm@0.20 B/W; one-way main @0.20 short +
  temp @0.25 long), `barKg` = d^2 L/162.
- Model flags (serialized): `Wall3d.tieBeam`/`bondBeam` -> 0.20m RC
  bands (thickness+0.06, grey 0xFF9E9E9E) emitted in modelFaces via
  wallSegSpans; `Block3d.footing` (col defs only) -> square pad,
  body below floor + 0.10m pedestal above. `_geomSig` hashes all
  three flags.
- Inspectors: wall SIZE section has the two beam switches + schedule
  readout; column blocks show "Isolated square footing" + F dims and
  rebar; thin volumes (<=0.5m) show SLAB type + min-thk OK/under.
- Takeoff: `footCount/footVol/footW`, `tieLen/bondLen/beamVol`,
  `slabs` (area,oneWay,minThk,thk); `concreteVol` now includes
  footVol+beamVol; `takeoffSteelSched(m)` -> STEEL WORKS lines
  aggregated kg by diameter + tie wire (2%/25kg rolls) + schedule
  notes, added to Add-all. Steel button prefill uses columnSched
  (dia + barsPerMember). Price DB gained Steel bar 10/16/20/25mm kg.

## DESIGN CALC tab (NSCP 2015)
- Tab index 4 (between 3D MODEL and PROJECT SCHEDULE; later tabs
  shifted to 5/6/7 - tests tap tabs by TEXT so shifts are safe).
- `lib/design_calc.dart`: pure `designCalc(Model3d, DesignParams) ->
  CalcReport` (sections of CalcRow label/formula/value/Chk status).
  Levels = distinct wall bases (0.5m); suspended slab = thin volume
  (<=0.5m) whose base is within 0.4m of a level top, else on-grade;
  top level with no slab gets a roof allowance on the wall bbox.
  Wall DL kPa = 15.3*t + 0.48 plaster. W = DL (+25% LL storage only).
  `seismicELF` = NSCP 208 Eq 208-8..17 (Ca/Cv Tables 208-7/8 with
  Na/Nv in Z4) - test reproduces the published Z4/SD/SMRF example
  (T 0.471, V=Vmax 1035 kN). Columns: nearest-column tributary by
  0.25m sampling of slabs/roof/walls, load cascades down stacked
  columns; phiPn,max = 0.80*0.65[0.85f'c(Ag-Ast)+fyAst]. Footing: q
  vs qa + punching 0.75*0.33*sqrt(f'c)*bo*d. Tie beam load = wall at
  height min(H, L/2) (arching); bond beam = 0.5m roof edge strip;
  shear = phi(Vc+Vs). Slab strip: one-way wL^2/10, two-way direct
  design 0.57*wu*Ls^2/8 (Marcus x0.8 was too conservative - false
  FAIL on a normal 4x6 slab). Equivalent-static, PRELIMINARY only.
- `DesignParams` lives on `est.design` (serialized as 'design').
- UI `lib/ui/design_view.dart`: params left, live report right,
  `designReportPdf` (ASCII-sanitized) behind EXPORT PDF.
- FIX buttons: `CalcRow.fix` = `DesignFix(kind, targetId, value, label,
  {values})` ('footing' | 'footing-all' | 'footing-depth' | 'column' |
  'slab'); `applyDesignFix(m, fix)` mutates the part. Fix targets are
  SOLVED inside designCalc so the recalc passes: footing side clears
  BOTH bearing and punching (t follows footingFor max(0.25,w/5));
  column section steps +0.05m until Pu/phiPn <= 0.95; slab = minT
  rounded up to 5mm. A MISSING footing's fix is kind 'footing-all' —
  `values` maps EVERY missing lowest-column id to its own required
  side, so one click builds all missing footings (a per-row fix left
  the model with a pad on one side only). Rows show a FIX TextButton
  (key `fix-<id>-<kind>`); the header shows FIX ALL (n)
  (`design-fix-all`). Off-screen rows are lazy — tests must
  `scrollUntilVisible` on the LAST Scrollable (params panel is first).
- `Block3d.footW` = manual footing side, `Block3d.footD` = embedment
  to pad BOTTOM below the block base (0 = auto). NSCP 2015 §305.1 /
  Table 305-1: `nscpFootingDepth(floors)` = 0.30/0.45/0.60 m for
  1/2/3+ floors supported (roofs-only counts 1F); `footingDepth(footD,
  [floors])` resolves manual-or-table; `columnStackFloors(m, b)` counts
  the column's stacked levels (0.4 plan/0.3 bz tests); EVERY consumer
  resolves depth through `blockFootingDepth(m, b)` — a lone column
  defaults to 0.30, a 3-high stack 0.60. Both serialized + in _geomSig
  (stack changes invalidate via the blocks' own x/y/bz hashes).
  `footingFor(sec, b.footW)` sizes pad+t; render = pad at
  [bz-d, bz-d+t] + a column-section pedestal stem padTop->bz
  (`footingStemVol` takes the RESOLVED dep, adds it to takeoff
  concrete). `blockFaces`/`blockFootingFaces` take `floors:` — scene
  build, 3D pick and ghosts pass `columnStackFloors`. Design emits a
  per-footing embedment row (warn below the Table 305-1 floor-aware
  minDep, 'footing-depth' fix). Inspector exposes Side + Depth
  (0=auto) fields + NSCP 305-1 preset chips AUTO/1F·0.30/2F·0.45/
  3F·0.60 writing footD.
- Placeable footing blocks: `ftg-150`/`ftg-200` in the Site library
  (square + X-cross plan symbol — standard structural notation).
  `blockFaces` renders them as a buried closed box, TOP face at `b.bz`
  (bz = top elevation; bottom = bz − t; embedment = t − bz). Design
  calc treats a placed `ftg-*` pad within 0.4 m of a column as that
  column's provided footing (`padOf`) — its own side/thickness/bz drive
  bearing, punching and embedment rows ('(pad block)' suffix); a
  'pad'-kind fix resizes it (`sx`) and lifts `bz` so the bottom lands
  at −0.60. 'footing-all' skips pad-covered columns. Takeoff counts
  pad concrete at the real scaled side + an `FTG-BLK` steel line.
  The column inspector carries an 'Apply footing to all columns'
  TextButton (inside `if (b.footing)`) that copies footing=true +
  footW/footD to every stack-LOWEST column — the same lowest-column
  rule as 'footing-all' (upper stacked columns never get pads).
- Model clipboard (Ctrl+C/X/V): `_clip` = (kind, toJson map) on the
  State — extensions can't hold fields. `_copySel` serializes the
  selected block/wall/volume; `_pasteClip` strips 'id' (fresh uuid),
  JSON round-trips, drops at the snap-resolved pointer in whichever
  pane is hovered (`_pastePoint`: plan `_hover` else `_s2g(_hover3)`
  else null → +0.5/+0.5 nudge), re-seats blocks via `_seatOpening`,
  and selects the copy. Walls/volumes translate so their bbox center
  lands on the pointer (`_shiftFp`). Ctrl+X = copy + `_delSel`.
- SheetView gained `structural`, `electrical`, `plumbing` — GENERATE
  emits NINE sheets (floor, structural, electrical, plumbing, roof, 4
  elevations), one DXF per view, ids `sheet:<modelId>:<slug>`. The
  structural sheet (`_structuralSheet`) is the foundation layout: wall
  outlines + C# column marks + flagged footings as F# squares at the
  REAL `footingFor` size with `WxWxT @D M` labels + placed ftg-* pads
  as FP# — never a generic symbol. Electrical/plumbing
  (`_fixtureSheet`) draw wall outlines + only that trade's blocks
  (`kElectricalDefs`/`kPlumbingDefs`) with their CAD linework + name.
  Buried pads render below z=0 by design — the no-floaters render
  test anchors ftg-* at `zmax`, and raster tests need the bottom cap
  (closed box = 6 faces). Selection contract: plan `_blkAt` hits the
  pad square (footprint for ftg-*, footingFor square for flagged
  cols) and the plan painter now DRAWS flagged footings (dashed
  square + X) — without that they were invisible where selectable;
  `Model3d.bounds` includes the pad so fit doesn't crop it. A pad
  under a slab is NOT 3D-clickable — `_pick3` takes the nearest face
  (the slab top wins) which is correct occlusion; buried parts are
  selected in plan (or via the Props object-list accordion). ftg-*
  inspector shows a FOOTING section: Side/Thickness write sx/sz,
  Embedment writes bz = t - depth (top anchors at bz), shallow
  warns <0.60.

## Accuracy campaign (test/accuracy_campaign_test.dart)
Hand-oracle + conservation + 60-seed fuzz over L-house, 2-storey frame,
3-storey commercial, 11 degenerate models. Bugs it found and the
contracts that came out of them:
- Openings are clipped to their wall seg and use scale/bz like the
  renderer (`k = sz*scale`, `def.sill*k + bz`).
- Floor-tile area = thin slabs at a storey BASE (wall base +-0.4m); a
  roof slab (at wall top) is concrete only. Massing volumes count only
  when no thin slab exists.
- RC wall beam bands (0.20m per tie/bond) come OFF the CHB area
  (`masonryGross/masonryNet`) but not off the paint (`wallNet`).
- Design calc: stacked columns at equal plan distance -> the HIGHEST
  takes the load and the cascade carries it down (tie-break bug left
  upper columns ~unloaded); column self weight rides the same cascade;
  beam weight is part of the wall line load. INVARIANT tested: sum of
  ground-column D (and L) == TOTAL DEAD (LIVE) LOAD.
- Footing checks only for the lowest column of a stack; slab type/
  span come from the COLUMN GRID panel (`slabPanel`), not the whole
  footprint; slab mesh reports the 10mm spacing needed (200/150/125/
  100) and WARNs when BOQ's 10mm@200 is not enough.
- Masonry BOQ headers are per CHB thickness (TakeoffWork.labels).

## Code editions - NSCP 2015 ONLY
- RESEARCH FACT: there is NO published "NSCP 2018". The code in force
  is NSCP 2015 Vol.1 (7th ed., UBC-97 seismic, ACI 318-14); documents
  that say "NSCP 2018" mean it. The 8th edition is PROPOSED, not
  released - and per user decision this app implements NSCP 2015 ONLY:
  no edition selector, no ASCE-7 spectral path, no code field on
  DesignParams (old projects that saved `code`/`ss`/`s1`/`tl` keys are
  ignored and load as 2015).
- SOURCE TEXT: the real NSCP 2015 djvu OCR is bundled at
  `docs/nscp/NSCP-2015_djvu.txt` (~3MB, archive.org NSCP2015). Every
  `CalcRow.ref` citation is verified against it by a test that extracts
  `NNN-N`/`NNN.x.y`/`207A.x` tokens and asserts each appears verbatim -
  when adding a check, grep the source for the token FIRST (OCR garbles
  a few like `2 07`; pick a rendering that resolves, e.g. 'S207A.5.1'
  not 'Fig. 207-1').
- Citations: `CalcRow.ref` renders as 'NSCP 2015 <ref>' under the
  formula in both the UI row and `designReportPdf`. EVERY non-SUMMARY
  row must carry one (enforced by test). Verified mappings: dead loads
  Table 204-1/204-2/S204, live Table 205-1, seismic S208.x + Tables
  208-1..11, wind S207A.5.1/S207B.6, combos Eq.203-1..7, columns
  S422.4.2/S421.2/S410.6.1, footings S304.2/S422.6/S305.1 Table 305-1,
  wall beams S409.5/S422.3/S422.5, slabs Table 407.3.1.1/S408.3.1.1/
  S408.10, CHB Ch.7 S706, concrete f'c S401.2 (17 MPa floor), rebar
  S420.2.
- Real corrections found in the source (keep!): seismic combos carry
  the vertical term Ev = 0.5 Ca I D (Eq.208-18, `evFac` adds to 1.2D
  and subtracts from 0.9D); the 203.3.1 f1 live-load factor is per-
  occupancy (kOccupancies element $5: 1.0 assembly/storage/essential,
  else 0.5); footing embedment is Table 305-1 FLOOR-AWARE -
  `minDep = [0.30, 0.45, 0.60][levels.clamp(1,3)-1]`, NOT a flat 0.60.
  'pad'-kind DesignFix carries `values['dep']` = minDep so pad embed
  fixes hit the floor-aware depth (footingDepth(0)=0.60 fallback).
- Tests: test/nscp_editions_test.dart (Ca/Cv tables, ELF hand oracle,
  persistence, 3-model simulation, Ev combos + f1, IMRF Zone-4 ban,
  Table 305-1 floors, citation coverage + source sweep, 300-combo fuzz,
  UI 2015-only, PDF).
