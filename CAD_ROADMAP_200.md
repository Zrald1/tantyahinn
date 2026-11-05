# CAD/BIM Master Backlog — 200 Tasks

Autonomous execution tracker. Each run: pick the FIRST `[ ]` task,
verify no regressions first, implement end-to-end, verify, mark `[x]`,
append a Changelog line. Stack: Flutter Windows, CustomPainter canvases,
`lib/model3d.dart` (model+DXF) + `lib/ui/model_view.dart` (editor UI).

## Phase 1 — UI Viewport Containment, Canvas Clipping & Layout Polish (1–25)

- [x] 1. Enforce strict canvas clipping on every CustomPaint (plan, 3D, block thumbs) so geometry/labels/ghosts can never bleed over toolbars, rails, or tab chrome; audit remaining bleed paths incl. focus mode.
- [x] 2. Dock the model toolbar into a fixed sub-header strip that painter content can never overpaint; confirm preset/action chips layer above canvas at all zooms.
- [x] 3. Independent 2D pan & zoom matrix: wheel zoom-to-cursor and middle/spacebar-drag pan scoped strictly to the plan viewport (already partially present — polish + document).
- [x] 4. Draggable vertical splitter between plan and 3D panes with double-click reset to 50/50; persist the split fraction in-memory.
- [x] 5. Viewport maximize toggles: Plan-only / Split / 3D-only via buttons and hotkeys 1/2/3 (extends `_focus3`).
- [x] 6. Adaptive multi-scale 2D grid: 1.0m major + 0.25m/0.10m minor lines that fade subdivisions by zoom level.
- [x] 7. Align 3D ground slab/grid origin and scale exactly to the 2D grid so both views share (0,0,0) and objects sit identically.
- [x] 8. Status bar polish: clean bottom strip showing cursor X,Y (+Z ground hit on 3D), active tool, snap state, zoom %, and selection summary.
- [x] 9. Collapsible left model rail (40px icon rail) to reclaim canvas width; same pattern as drawing library rail.
- [x] 10. Right inspector contextual panels: Model Summary when nothing selected vs part properties when selected (done for select — verify empty-state design).
- [x] 11. Keyboard shortcut HUD overlay: toggleable `?` card listing every key (tools, camera, undo, focus).
- [x] 12. Snap indicator glyphs: endpoint/midpoint/grid markers rendered on both canvases while drawing.
- [x] 13. Cursor state map: precise crosshair for draw tools, grab hand over selectable parts, pan cursor for shift-drag on 3D.
- [x] 14. Canvas edge padding: keep a margin so fit-to-content never touches chrome pixels.
- [x] 15. Toolbar overflow handling: compact icon-mode collapse under narrow widths (reuse _BarGroup pattern).
- [x] 16. HiDPI crispness: ensure painter strokes stay sharp at 125%/150% Windows scaling (use hairline widths where appropriate).
- [x] 17. Empty-state onboarding card on the plan canvas (already has overlay text — upgrade to a proper 3-step hint card).
- [x] 18. Selection highlight style: consistent accent outline + handles on both canvases; desaturated for non-active pane.
- [x] 19. Right panel tab badges: show armed block name on Blocks tab, selected part name on Inspect tab.
- [ ] 20. Reduce rail chrome: model list rows compacted to one line + part counts; delete affordance on hover only.
- [ ] 21. Canvas repaint discipline: only repaint on model/camera changes (RepaintBoundary around each canvas).
- [ ] 22. Focus-mode exit affordance: visible "Exit focus (Esc)" pill while `_focus3` is on.
- [ ] 23. Right-panel scrollbars: thin always-on scrollbar for the block library so categories are discoverable.
- [ ] 24. Consistent 8px spacing/6px radius design tokens applied across both canvas overlays.
- [ ] 25. Layout regression sweep: verify at 1280/1600/1936 widths and 100/125/150% DPI — no overflow, no bleed.

## Phase 2 — SketchUp-Style Direct Modeling & Snapping (26–50)

- [ ] 26. Push/pull volume tool: drag a volume face in 3D to extrude it (positive or negative delta updates `height`/`base`).
- [ ] 27. Endpoint snap: magnetize new wall/block points to existing wall vertices (visual marker).
- [ ] 28. Midpoint snap: triangle marker at segment midpoints.
- [ ] 29. Perpendicular snap: project from last point onto adjacent segments.
- [ ] 30. Ortho lock: hold Shift (or toggle) to constrain wall segments to 90°/45° increments.
- [ ] 31. Dynamic dimension input box: typing a number while drawing sets the next segment length exactly (Enter commits).
- [ ] 32. Wall chain live-length tooltip follows cursor while drawing.
- [ ] 33. Wall auto-miter: miter outer corners of closed wall loops (extend segPolys to shared corner points).
- [ ] 34. T-junction cleanup: where a wall endpoint lands on another wall's span, split the host segment and merge hatch geometry.
- [ ] 35. Wall join mode: drawing a chain ending on another wall auto-joins them into one logical wall.
- [ ] 36. Wall chain editing: drag a vertex of an existing wall in plan to reshape it.
- [ ] 37. Wall segment splitting: right-click a wall → "split here" creates two walls.
- [ ] 38. Wall extension: continue a selected wall's chain from either endpoint.
- [ ] 39. Offset tool: drag a wall parallel copy at a typed distance.
- [ ] 40. Rectangle room tool upgrade: R-drag creates a closed 4-segment wall loop (not a volume) with live W×L readout.
- [ ] 41. Grid density follows zoom: snap step subdivides to 0.05m past a zoom threshold, coarsens to 0.5m zoomed out.
- [ ] 42. Numeric entry for thickness/height mid-draw (type t=0.20 while wall tool active).
- [ ] 43. Double-wall auto-trace: pick two points inside a room outline to auto-generate the wall between them.
- [ ] 44. Drag-move with axis constraint: hold X or Y during a move to lock an axis.
- [ ] 45. Rotate tool for selected parts (R cycles 15°; Shift+R opens angle input).
- [ ] 46. Scale handles on selected blocks in plan view.
- [ ] 47. Copy tool: Ctrl+drag a part to duplicate it.
- [ ] 48. Array tool: linear array of a selected block (count × spacing input).
- [ ] 49. Flip/mirror tool for selected walls and blocks.
- [ ] 50. Inference lines: dashed guide lines extending from snapped endpoints (SketchUp-style).

## Phase 3 — Parametric Walls, Openings & Boolean Cutouts (51–75)

- [ ] 51. Wall `height`/`base`/`thickness` editable per segment (not only per wall).
- [ ] 52. Multi-layer wall assemblies: CHB + plaster both sides as one parametric thickness with per-layer dims on the plan.
- [ ] 53. Door block placed ON a wall: snaps to the wall centerline, aligns rot to wall direction.
- [ ] 54. Door cuts wall: 3D wall faces get a rectangular cutout where a door sits (segment splitting + lintel piece).
- [ ] 55. Window placement on wall with sill height parameter (`base` offset).
- [ ] 56. Window cuts wall with sill + lintel pieces preserved.
- [ ] 57. Plan symbols for openings: door leaf + swing arc drawn through the wall opening; window = double parallel lines in the gap.
- [ ] 58. Associative openings: moving a door along a wall moves its cutout; deleting it heals the wall.
- [ ] 59. Opening can't overlap another opening on the same segment — reject with a hint.
- [ ] 60. Corner openings clamp so they don't eat corner join geometry.
- [ ] 61. Elevation projections show opening cutouts (they come free once faces carry the holes — verify).
- [ ] 62. Door swing direction flip (inside/outside, left/right) via R/F keys while armed or selected.
- [ ] 63. Wall type presets: 100/150/200mm CHB, concrete shear wall, partition stud — chip cycles presets.
- [ ] 64. Gable/sloped wall top (apex height param) for end walls.
- [ ] 65. Beam/column structural line overlay on plan (dashed) — distinct from walls.
- [ ] 66. Slab volumes: horizontal plate volumes as floor slabs with thickness + elevation.
- [ ] 67. Roof volume primitive: simple gable/hip roof generated from the wall envelope bounds.
- [x] 68. Stair block generates a real stepped prism (not flat symbol) with riser count.
- [ ] 69. Opening schedule data: per-opening id, type, size, count feeding the area schedule task.
- [ ] 70. Wall material tagging: paint/finish class per wall feeding elevation callouts.
- [ ] 71. Curved wall segments (arc via 3-point drag).
- [ ] 72. Demolition/dashed-POC wall display mode.
- [ ] 73. Wall end caps: square/mitered/free end toggle for open chains.
- [ ] 74. Multi-storey: level selector — walls/blocks tagged to a level, plan shows active level, 3D stacks them.
- [ ] 75. Level-aware sheet generation (each level gets its own floor plan sheet).

## Phase 4 — Parametric CAD Block Library (76–100)

- [x] 76. Block schema upgrade: parametric defs (width/depth/height/variants) so one def yields size variants.
- [ ] 77. Single door with configurable swing arc (leaf angle, left/right).
- [ ] 78. Double door, sliding door, folding door variants.
- [ ] 79. Casement window with swing arc; awning window; sliding window symbols.
- [ ] 80. Fixed/picture window and glass-block symbols.
- [ ] 81. Straight stair with arrow + riser count label.
- [ ] 82. L-shape and U-shape stair generators.
- [ ] 83. Plumbing fixtures: floor drain, hose bibb, water meter, cleanout.
- [ ] 84. Kitchen variants: island counter, bar counter, pantry unit.
- [ ] 85. Office furniture set: cubicle, conference table, file cabinet (matches ASDS-office use case).
- [ ] 86. School furniture set: classroom desk rows, blackboard, teacher table.
- [ ] 87. Outdoor/site set: fence line symbol, gate, flagpole, parking stall.
- [ ] 88. Structural set: CHB pier, concrete column 0.30/0.40, footing pad symbol.
- [ ] 89. Electrical set: outlet, switch, panel board, light fixture symbols.
- [ ] 90. Block preview pane: large rendered preview + dims when hovering a library row.
- [ ] 91. Recent/favorite blocks section at top of the library (persisted in-memory).
- [ ] 92. User-defined blocks: draw a plan region → "make block" adds it to a CUSTOM category.
- [ ] 93. Block replace: right-click a placed block → swap its def, keep x/y/rot.
- [ ] 94. Block tags: each def carries BOQ-relevant tags (door/window/fixture) feeding quantity extraction.
- [ ] 95. Block outline style toggle: realistic linework vs simple bounding rectangle.
- [ ] 96. DWG/DXF block import: parse a library drawing's entities into a reusable block def.
- [x] 97. Textured 3D faces for furniture blocks (color per def) in the solid preview.
- [ ] 98. Block alignment guides: placing furniture shows centerline guides to nearby walls.
- [ ] 99. Block snap-to-wall edge for counters/beds (auto-offset flush to wall face).
- [ ] 100. Library categories re-sorted to match dwgmodels taxonomy exactly + an "ALL" filter chip.

## Phase 5 — Bidirectional Sync & Selection UX (101–125)

- [ ] 101. Selection sync polish: tapping a part on one canvas flashes its outline on the other.
- [ ] 102. Multi-select via drag box on plan canvas (all parts inside).
- [ ] 103. Multi-select via drag box on 3D canvas (screen-space face hit).
- [ ] 104. Shift-click additive selection on both canvases.
- [ ] 105. Group move/delete for the multi-selection.
- [ ] 106. Redo stack (Ctrl+Y) complementing `_undo` snapshots.
- [ ] 107. Undo coalescing: drags and typed edits fold into one snapshot.
- [ ] 108. Gizmo-lite: on-screen rotate/scale arrows for the selected block in 3D.
- [ ] 109. Move gizmo on plan canvas: arrow handles for axis-constrained moves.
- [ ] 110. Hover pre-highlight on both canvases before click-to-select.
- [ ] 111. Camera preset animation: lerp yaw/pitch/zoom over ~200ms to the preset.
- [ ] 112. Walk-through camera mode (eye-height WASD + mouse look) — read-only inspection.
- [ ] 113. Section-plane slider: drag a horizontal cut plane that clips the 3D view.
- [ ] 114. X-ray/wireframe 3D toggle.
- [ ] 115. Plan transparency overlay: draw the plan linework faintly onto the 3D ground for alignment.
- [ ] 116. Isolated edit mode: double-click a part to dim everything else while editing.
- [ ] 117. Selection info strip: "Wall — 6.25m · t0.15 · h2.70" pinned under the toolbar when something's selected.
- [ ] 118. Drag-duplicate ghost preview before commit.
- [ ] 119. Measure tool on model canvases (click two points → distance + angle label).
- [ ] 120. Protractor/angle readout while rotating blocks.
- [ ] 121. Paste in place (Ctrl+Shift+V) and paste at cursor (Ctrl+V).
- [ ] 122. Tab cycling between overlapping parts under the cursor.
- [ ] 123. Lock flag per part: locked parts can't be selected/moved until unlocked.
- [ ] 124. Layer/visibility toggles: walls / volumes / furniture / dims independent eye icons.
- [ ] 125. Scene bookmarks: save named camera+selection states.

## Phase 6 — Automated Production Sheets (126–150)

- [x] 126. GENERATE emits one DXF per view — A-1 Floor Plan, A-2 Roof Plan, A-3..A-6 four elevations as separate DRAWINGS entries (done: `buildModelSheet` + six `sheet:<id>:` entries).
- [ ] 127. Section views: pick a cutting line on plan → auto-generate section sheet.
- [ ] 128. Sheet numbering A-1..A-8 with a consistent title scheme on each file/entry name.
- [ ] 129. Sheet order grouping in the DRAWINGS rail (model sheets cluster under the model name).
- [ ] 130. Regenerate-in-place: content updates when the model changes; stale sheets flagged visually.
- [ ] 131. Cover sheet generator: project info + sheet index + 3D snapshot.
- [ ] 132. Per-level floor plans when multi-storey lands (Phase 3 #74).
- [ ] 133. Detail callout: zoomed wall-assembly detail sheet.
- [ ] 134. Reflected ceiling plan (RCP) view generation.
- [ ] 135. Site plan view: model + north arrow + site blocks on a wider canvas.
- [ ] 136. Elevation depth shading: far faces drawn lighter/thinner for depth cue.
- [ ] 137. Plan hatch per wall type: CHB vs concrete vs partition distinct poché.
- [ ] 138. Door/window symbols through openings on the floor plan sheet (uses Phase 3 data).
- [ ] 139. Grid-line propagation onto elevation sheets.
- [ ] 140. Sheet border + margin frame on every generated sheet.
- [ ] 141. View title bubble under each drawing ("FRONT ELEVATION · SCALE 1:100").
- [ ] 142. Auto-layout engine for multi-drawing sheets (spacing solver, not fixed slots).
- [ ] 143. Sheet regeneration uses stable layout so regenerated files don't jitter vs. prior revision.
- [ ] 144. Empty-view suppression: skip (or mark) sheets whose projection has no content.
- [ ] 145. Model-units metadata in DXF header (INSUNITS=meters) for correct scaling in real CAD.
- [ ] 146. Layer discipline in generated DXF: WALLS/OUTLINES/DIMS/LABELS/TEXT/TITLE layers with proper ACI colors.
- [ ] 147. Dimension layer separation so dims can be toggled off in real CAD viewers.
- [ ] 148. Revision table on each sheet (rev no., date, description).
- [ ] 149. Sheet rename support: user-set sheet titles persist through regenerate.
- [ ] 150. 3D isometric view sheet (render the ortho projection into a view panel).

## Phase 7 — Annotation, Dimensioning & Title Blocks (151–175)

- [ ] 151. Exterior chain dims tier 1: opening widths + pier segments on floor plan.
- [ ] 152. Exterior chain dims tier 2: structural grid centerlines.
- [ ] 153. Exterior chain dims tier 3: overall building length/width.
- [ ] 154. Interior room dims: clear span W×L inside enclosed rooms.
- [ ] 155. Column grid bubbles (A,B,C / 1,2,3) along perimeter on plan + elevations.
- [ ] 156. Architectural tick marks: 45° slashes, extension gaps, centered text.
- [ ] 157. Production title block: border + Project Title, Owner/Agency, Sheet Title, Sheet No., Scale, Date, Drawn/Checked/Approved boxes, PRC block.
- [ ] 158. Title block editor modal: fields stored on the model/project, propagate to all sheets.
- [ ] 159. Graphic scale bar + north arrow under plan/roof callouts.
- [ ] 160. Automated room tag stamps: name, finish code, ceiling height, area.
- [ ] 161. Wall-type callout leaders (150mm THK CHB W/ PLASTER BOTH SIDES etc.).
- [ ] 162. Elevation material callout leaders (roofing/paint/window frame).
- [ ] 163. General notes + symbol legend block on Sheet A-1 (optional).
- [ ] 164. Area tabulation schedule on floor plan sheet (rooms → m² → gross total).
- [ ] 165. Anti-collision dim layout: stagger text when segments are tight.
- [ ] 166. Custom text + leader annotation tool on generated sheets.
- [ ] 167. Spot elevation markers (+0.00 / -0.15) at entries and wet areas.
- [ ] 168. Wet-area waterproofing hatch region on plan.
- [ ] 169. Ceiling height datum markers on elevations.
- [ ] 170. Door/window schedule table on a sheet (type, size, count, remarks).
- [ ] 171. Centerlines for doors/windows on plan (axis lines through openings).
- [ ] 172. Fire-exit / egress arrows optional layer.
- [ ] 173. Plumbing fixture count schedule.
- [ ] 174. Elevation grade-line symbol with finished-floor datum tag.
- [ ] 175. Key plan inset on sheets for multi-building models.

## Phase 8 — Print Production, Export & BOQ Live Link (176–200)

- [ ] 176. True-to-scale PDF print: 1:50 / 1:100 selectable, exact mm on A3/A4.
- [ ] 177. Batch sheet print preview modal with include-checkboxes per sheet.
- [ ] 178. AIA lineweight hierarchy: cut > outline > dim > hatch > text.
- [ ] 179. Hidden-line removal quality pass on elevation projections (drop fully occluded faces).
- [ ] 180. DXF export polish: verify in real AutoCAD/LibreCAD (units, layers, text styles).
- [ ] 181. SVG export of generated sheets.
- [ ] 182. PNG snapshot of 3D view embedded on cover sheet.
- [ ] 183. Model → quantity extraction: wall lengths, gross/net wall area, volume concrete.
- [ ] 184. Masonry area = gross wall minus opening areas (uses Phase 3 data).
- [ ] 185. Plaster/paint area = 2 × net wall area.
- [ ] 186. Floor slab volume + tile area; ceiling + roof sheet area.
- [ ] 187. Door/window itemized counts feeding BOQ lines.
- [ ] 188. BOQ item → 3D highlight traceability (click a line, flash its parts).
- [ ] 189. Live pricing hook: model quantities × est.priceDb → live cost card.
- [ ] 190. Schedule auto-generation from model quantities × labor rates into PROJECT SCHEDULE.
- [ ] 191. Starter template gallery: ASDS office, 2-bedroom house, classroom, commercial — 1-click models.
- [ ] 192. Guided onboarding tour: 4-step walkthrough (draw walls → drop openings → adjust 3D → generate).
- [ ] 193. Print scale calibration check: ruler overlay validating plotted mm.
- [ ] 194. Room finish schedule generator.
- [ ] 195. Layer presets: Architectural / Structural / Furniture / Renovation sheet variants.
- [ ] 196. Existing-vs-proposed wall styling mode.
- [ ] 197. Drawing pack export: all sheets into one multi-page PDF.
- [ ] 198. Model JSON version stamp + migration guard for saved projects.
- [ ] 199. Performance pass: 500+ wall model stays interactive (face caching, painter repaints).
- [ ] 200. Final polish: app icon, installer docs, README feature list + shortcut card.

## Changelog

- Run 0: rewrote malformed roadmap blob into the numbered 200-task tracker above; task 126 pre-marked done (six per-view sheets shipped + verified earlier this session).
- Run 1 (task 1): `_BlockThumb` wrapped in ClipRect (swing-arc strokes overshot the 44×34 box); `_fitPlan` now pads fitted bounds by 0.7m of annotation overshoot so edge labels/dims never clip mid-glyph; audited all bleed paths — plan/3D canvases already ClipRect'd, overlay chips are Stack siblings after the canvas, `_panLast`/`_zoomPlan` transforms stay inside the left split. Verified: 42/42 tests, analyze clean, live Fit shows all volume+dim labels inside bounds. Files: `lib/ui/model_view.dart`.
- Run 2 (task 2): toolbar restructured — tools scroll inside an Expanded+SingleChildScrollView while the parts count + GENERATE DRAWING pin at the right edge (primary action never scrolls off at narrow widths); overlay chips verified Stack-after-canvas (always above at any zoom); `dart format` applied to model_view. New widget test asserts GENERATE stays on-screen at 1100px. Verified: 87/87 tests, analyze clean, live rebuild shows pinned layout. Files: `lib/ui/model_view.dart`, `test/widget_test.dart`.
- Run 3 (task 3): middle-button drag pans both viewports in any tool (plan `_midPan`→`_pOff` in the Listener stream, 3D → `_o3` camera pan); spacebar-drag pans the plan across all tools via `_panLast` checked ahead of the tool switch; `_midBlock` swallows the stale tap/pan-end a middle-release leaves behind until the next pointer down; grabbing cursor while mid-panning or space held. REAL DEFECT fixed: the empty-canvas `Center` hint shadowed canvas input under its text — now `IgnorePointer`-wrapped. Verified: 88/88 tests (new test drives mid/space drags + wheel zoom + 3D mid-pan via the real gesture pipeline), analyze clean, live-verified on debug+release (plan +3D pans visible, zero phantom geometry). Files: `lib/ui/model_view.dart`, `test/widget_test.dart`.
- Run 4 (task 4): fixed `Expanded` plan/3D pair replaced by a `LayoutBuilder` + 10px draggable sash (`_splitter`): `est.modelSplitFrac` (in-memory, clamped 0.2–0.8, reset by `newProject`) drives `planW` with plan≥240/3D≥280 guards; horizontal drag updates the fraction live, double-click resets to 50/50, hover highlight + `resizeColumn` cursor afford the grab. Verified: 89/89 tests (drag asserts frac grows + pane widens, double-tap asserts reset), analyze clean, release build OK, live-verified on the debug build with pointer instrumentation — strip tracked the drag stepwise and `onDoubleTap` fired `setModelSplit(0.5)` restoring 722.0. Files: `lib/ui/model_view.dart`, `lib/state.dart`, `test/widget_test.dart`.
- Run 5 (task 5): `_focus3` bool upgraded to `_Vp {plan, split, model}` — keys 1/2/3 pick plan-only/split/3D-only, F still toggles 3D focus, Esc cascade now restores the split from either maximize; the plan pane gained its own top-right icon row (fit + maximize) mirroring the 3D pane's, and pane captions flip to PLAN FOCUS / 3D FOCUS. Verified: 90/90 tests (new test drives digits 1/3, both restore buttons, and the Esc cascade), analyze clean, release build OK, live-verified — real key presses 1→PLAN FOCUS, 3→3D FOCUS, 2→split, and the plan-pane maximize button all observed on the debug build. Files: `lib/ui/model_view.dart`, `test/widget_test.dart`.
- Run 6 (task 6): plan grid upgraded to a true multi-scale hierarchy — `planGridLevels(pScale)` (public, testable) returns the base `step` (>=26px apart, every 5th major), a `sub` division (step/4 at >=1m -> 0.25m, step/5 at 0.5m -> 0.10m, 2m->0.5m, 5m->1.25m...), and `subAlpha` fading 0..0.9 across ~5.5-14.5px of subdivision room (SketchUp-style smooth fade-in). Sub-lines iterate indices from the same `xa`/`ya` anchor so every `div`-th lands exactly on a base line (no double-draw). Verified: 91/91 tests (new unit test pins the step ladder, sub ratios, and the fade thresholds), analyze clean, release build OK, live-verified — subdivision texture visible at multiple zooms and two distinct line densities confirmed by pixel scan. Files: `lib/ui/model_view.dart`, `test/widget_test.dart`.
- Run 7 (task 7): both grids now draw the SAME world lattice — `gridLinePositions(lo,hi,step)` (public, tested) yields exact step-multiples inside the view, so the 2D plan grid is world-anchored (previously floored-view-bound) and the 3D ground grid uses the plan's own `planGridLevels(_pScale).step` around the model envelope ±3m (previously a bbox-centered fixed 2m grid); coverage is clamped to always include (0,0) so the RGB axes can never float off the lattice. 2D origin now legible SketchUp-style: x=0 column tinted green, y=0 row tinted red. Verified: 92/92 tests (new unit test pins world-multiple positions incl. origin through negative ranges), analyze clean, release build OK, live-verified — pixel scan found the tinted axes and a synthetic wall (0,0)->(4,0) lay exactly on the red axis in plan while its prism rose from the 3D origin. Files: `lib/ui/model_view.dart`, `test/widget_test.dart`.
- Run 8 (task 8): unified SketchUp-style `_statusStrip` under the viewports (26px, replaces both per-pane bottom overlays) — tool pill (icon+name) | context hint that follows the hovered pane (`_over3` picks plan vs 3D hint) | selection summary (WALL · len / name · area / block name) | snapped cursor readout (plan `X,Y`; 3D ground hit `X,Y,Z 0.00` via `_s2g`, `—` when the view is too flat or no pane is hovered) | tappable `SNAP 0.25`/`SNAP OFF` chip (mirrors the toolbar `_snap`) | hovered-pane zoom % (plan `_pScale`/40, 3D `_z3`/30). Added `_inPlan` MouseRegion enter/exit on the plan and a 3D `MouseRegion(onExit)` so `_hover3` now clears when the pointer leaves (previously it only cleared on pointer-down). Verified: 93/93 tests (new test drives hovers on both canvases, the snap chip, and a wall selection summary), analyze clean, release build OK, live-verified — plan hover read `X 6.00 Y -6.50`, 3D hover read `X -6.75 Y -2.25 Z 0.00` with the hint switching panes. Files: `lib/ui/model_view.dart`, `test/widget_test.dart`.
- Run 9 (task 9): left model rail collapses to a 40px icon rail via `est.modelRailOpen` (in-memory, reset by `newProject`, survives tab switches) — mirrors the DRAWINGS `drawingLibraryOpen` pattern: header gains a chevron-left `Hide models` beside `+`, collapsed rail shows chevron-right `Show models` + `New model` + a selected-model icon with the model count; the 160px reclaim divides across the plan|3D split per `modelSplitFrac`. Verified: 94/94 tests (new test asserts hide -> width growth, collapsed + still creates a model, expand restores), analyze clean, release build OK, live-verified — collapse showed the icon rail and both canvases widened, expand restored the list. Files: `lib/ui/model_view.dart`, `lib/state.dart`, `test/widget_test.dart`.
- Run 10 (task 10): right inspector is now contextual per SketchUp Entity-Info convention — nothing selected shows `_modelSummary` (name field, Walls count·length, Blocks, Volumes, Floor area m², Envelope, italic hint), a selected part replaces it with the focused inspector (`_wallInspector`/`_blkInspector`/extracted `_volInspector`) plus a `‹ MODEL SUMMARY` back link that deselects; GENERATE stays under both. Verified: 95/95 tests (new test asserts summary↔part switching + back-link deselect), analyze clean, release build OK, live-verified — 3D canvas pick showed the full WALL panel with back link, which restored the summary on tap. Files: `lib/ui/model_view.dart`, `test/widget_test.dart`.
- Run 11 (task 11): keyboard shortcut HUD — `?` (Shift+/) or `F1` toggles a floating `_hudCard` over the viewports (Stack overlay, IgnorePointer-free card only blocks its own rect; canvas stays interactive outside it). Card lists every real binding in `_keys()` grouped TOOLS (A select / W wall / R rect / P poly / B block / R rotate-armed-block / Enter finish / Del delete) · CANVAS (drag orbit 3D / shift-drag pan 3D / mid-drag pan both / space-drag pan plan / wheel zoom / dbl-click sash reset) · VIEW (1/2/3 modes, F focus, Esc) · EDIT (Ctrl+Z, ?/F1 self). Toolbar gains an always-visible `?` IconButton (tooltip "Shortcuts (?)", active state mirrors `_hud`); Esc in `_esc()` closes the card FIRST before the normal cancel cascade. Verified: 96/96 tests (new test taps for canvas focus, toggles via shift+/ + F1 + toolbar, asserts all 4 sections and Esc-first ordering), analyze clean, release build OK, live-verified — F1 open, toolbar open, Esc closed while a wall chain stayed armed then a second Esc cancelled it, card × closed, Shift+/ reopened. Files: `lib/ui/model_view.dart`, `test/widget_test.dart`.
- Run 12 (task 12): SketchUp-style snap inference with real snapping + glyphs on BOTH canvases — `snapTarget()` (public, unit-tested) orders endpoint > midpoint > grid; `_snapPt(w, pxPerM, [proj])` collects wall verts, volume corners, block centers, chain pts and `_rect0` as endpoints and wall/volume/chain segments for midpoints; `proj:` lets the 3D view measure the ~9px pick radius in SCREEN px (foreshortening shrinks it along the depth axis if measured in world units — verified live: world-tol missed a vertex ~2px off). `paintSnapGlyph` draws the SketchUp vocabulary: green endpoint square + white halo, cyan midpoint triangle, dim `+` for bare grid. One target drives previews, ghost, status readout AND the tap commit (`_planTap`/`_modelTap`/`_rectCur`/`_rect0`) — the marker is honest, never decorative; glyph gated to draw tools + `_snap` on + `_inPlan`/editable-3D. Verified: 98/98 tests (unit test pins precedence; widget test taps ~0.06m off off-grid vertices and asserts exact endpoint/midpoint commits on plan AND on the 3D canvas via `debugProjGround`+6px, plus snap-off raw commit), analyze clean, release build OK, live-verified — green square on a chain vertex, cyan triangle at a segment midpoint (live dim read 2.00m to it), `+` on open ground, all on both canvases. Files: `lib/ui/model_view.dart`, `test/widget_test.dart`.
- Run 13 (task 13): full cursor state map on both canvases — plan `planMouse`: any active drag (`_midPan`/`_panLast`/`_moveLast`) -> `move` (SIZEALL); space armed -> `click` (hand); select -> `click` over a part (`_overPart` recomputed every plan hover via `_blkAt`/`_wallAt`/`_volAt`) else `basic` arrow; draw tools -> `precise` crosshair. 3D `m3dMouse`: `_midPan`/`_drag3`/shift -> `move`; select -> `click` over a part (`_overPart3` via throttled `_pick3`, re-eval only after the cursor travels 8px) else `basic`; draw -> `precise`. `_drag3` set in 3D `onPanUpdate`, cleared on pointer-up/cancel; `Focus.onKeyEvent` rebuilds on space/shift transitions so modifier cursors appear without a mouse move. WINDOWS CURSOR SUBSET GOTCHA: `SystemMouseCursors.grab`/`grabbing`/`allScroll` render as the plain ARROW on Windows Flutter — the hand is `click` (IDC_HAND) and drags are `move` (IDC_SIZEALL); same broken glyphs fixed in `drawing_view` (mark drag/hover) and `pert_view` (node drag). Live-verified by reading OS cursor handles via GetCursorInfo+LoadCursor: CROSS on draw, ARROW on empty, HAND over Vol-2 plan footprint and over 3D block/volume faces, HAND on space-hold, SIZEALL on mid-drag, shift-hold and orbit-drag. Verified: 99/99 tests (cursor-map test asserts all tool/hover/modifier states on both canvases incl. volume-top face via `debugProj3`), analyze clean, release build OK. Files: `lib/ui/model_view.dart`, `lib/ui/drawing_view.dart`, `lib/ui/pert_view.dart`, `test/widget_test.dart`.
- Run 14 (task 14): fit-to-content now respects a chrome-aware safe rect on BOTH canvases — `_kPlanSafe` (20/48/20/34 for the top-right fit/maximize icons + bottom-right caption) and `_k3DSafe` (20/46/20/36 for the camera-preset chip row + top-right icons + bottom captions) shrink the usable fit area and `_fitPlan`/`_fit3` center the content bbox on the SAFE center instead of the pane center; plan keeps `labelPad 0.7` so wall dims/block names aren't clipped mid-glyph, 3D keeps an 0.85 fill of the safe rect. Verified: 100/100 tests (new test taps both canvas fit buttons and asserts every bounds/label corner lands inside each pane's safe rect via `debugProj3`), analyze clean, release build OK, live-verified — plan fit leaves ~29px right clearance + full top/bottom margins, 3D model sits clear of the preset chips and captions. Files: `lib/ui/model_view.dart`, `test/widget_test.dart`.
- Run 15 (task 15): toolbar collapses to icon mode before anything scrolls — LayoutBuilder measures the real toolbar width (rail/inspector changes count too): full -> tools in a `_BarGroup`-style segmented pill [select/wall/block/rect/poly/?] + labeled param chips + parts count + labeled GENERATE; compact (<720px) -> wall thickness becomes a `straighten` icon popup trigger (tooltip carries the live value), armed-block chip becomes a chair IconButton that still opens the Blocks tab, parts count hides; tight (<430px) -> GENERATE drops to an icon-only FilledButton with tooltip. The SingleChildScrollView stays as the last-resort overflow path. Verified: 101/101 tests (new test at 1600/1100/760px asserts chip->icon swaps, parts-text hiding, tool visibility, Blocks-tab tap, and that the icon-mode GENERATE still fires `_generate`), analyze clean, release build OK, live-verified by resizing the real window — 1120px shows every tool as icons + labeled action, 780px shows icon-only GENERATE with the tools pill intact. Files: `lib/ui/model_view.dart`, `test/widget_test.dart`.
- Run 16 (task 16): HiDPI hairlines — `hairlinePx(dpr)` (= 1 physical px at any scaling) + `pxSnap(v,dpr)` (lands axis-aligned strokes on device-pixel CENTERS: `(v*dpr-0.5).round()+0.5)/dpr`). Both canvas painters take `dpr` via `MediaQuery.devicePixelRatioOf(context)`; plan grid minor/major/subdivision lines and axis tints draw at hairline width on snapped coords (reference lattice may drift <0.5 device px — model geometry keeps honest projected coords); 3D ground grid + all face-edge outlines (0.7 -> hairline, was sub-px and always smeared) draw at `hairlinePx(dpr)` weight. Verified: 103/103 tests (unit pins pxSnap on .5-centers across dpr 1.0/1.25/1.5/2.0 + bounds to half a device px; widget test asserts both painters carry the real 1.5 DPR), analyze clean, release build OK, live-verified by pixel-profile scan on the real ~125% display — every plan grid line renders exactly 1 physical px wide at uniform depth (before: irregular widths + multi-px smears). Files: `lib/ui/model_view.dart`, `test/widget_test.dart`.
- Run 17 (task 17): 3-step onboarding card on an empty plan canvas — `Start your model` (top-left) lists Draw walls (W) / Place blocks (B) / Generate drawing with numbered accents; shows only when `_sel!=null && _sel!.bounds==null && !est.modelIntroDismissed`, auto-hides once any geometry commits, and the x (`Hide tips`) sets `est.modelIntroDismissed` (in-memory session flag in state.dart) so later empty models stay clean. HIT-TEST LESSON: a decorated Container claims hits for its whole rect (RenderDecoratedBox.hitTestSelf -> BoxDecoration.hitTest returns true) — the first centered version ate canvas taps and broke 7 tests. Fix: IgnorePointer wraps the entire card body; the x is a separate Stack sibling so it is the ONLY hit area — taps on every other card pixel fall through to the plan (steps teach the KEYS, SketchUp/Rayon-style, not fake buttons). Verified: 104/104 tests (new test taps INSIDE the card body and asserts the wall chain still starts, plus auto-hide/x/persistence), analyze clean, release build OK, live-verified — click inside the card started the chain (status showed `1 pt`), commit drew a 5.48m wall and hid the card, Model 3 re-showed it, x dismissed it, Model 4 stayed clean. Files: `lib/ui/model_view.dart`, `lib/state.dart`, `test/widget_test.dart`.
- Run 18 (task 18): selection highlight unified across both canvases - `_activePlan` state tracks the last-entered pane (plan `MouseRegion.onEnter` -> true, 3D `onEnter` -> false; critical fix: 3D activity was set only in `onPointerHover`, so a click entering 3D never claimed the pane - now `onEnter` carries it; no `_hover3` fallback, which would have painted a phantom snap glyph at the origin). Shared helpers `_selCol(cs, active)` (full `cs.primary` accent / `lerp` toward onSurface 0.55 for the inactive pane) + `_paintSelHandle` (accent ring + contrasting core). Plan: selected volumes/walls/blocks get accent outline+fill and semantic handles (volume corners, wall endpoints, block footprint corners+center); 3D: hardcoded purple `0xFF7C4DFF` replaced by the theme accent, `_polyFacesSel` now returns top+side faces so the cage wraps the whole part, same handle vocabulary on top verts/footprint. Same selection renders desaturated on whichever pane isn't active. Verified: 105/105 tests (new test flips active pane and asserts accent vs desat colors reach both painters), analyze clean, release build OK, live-verified - plan drag-select on Volume 5 showed vivid outline+ring handles while the 3D slab went muted, then a 3D click picked the TV console and flipped it: 3D vivid footprint cage, plan side drew the part at desat (151,101,211) vs vivid (124,77,255) pixel-verified. PLAN TAP-SELECT GAP FOUND: `_planTap` has no select branch - plan parts are grabbed only on drag-start (`_planStart`); recorded for a future sync task. Files: `lib/ui/model_view.dart`, `test/widget_test.dart`.
- Run 19 (task 19): right-panel tab badges - the inspector SegmentedButton labels are `_tabBadge` columns (title + 84px accent pill, ellipsis): Inspect carries `_selText` while a part is selected (empty otherwise), Blocks always carries the armed `_blkDef.name` - SketchUp-tray-style state readable without switching tabs. Added `armBlockDebug` test setter; keyed the status strip Container `modelStatusStrip` and scoped the old selection-text finder to it (the badge legitimately duplicated `WALL · N.NN m` and broke the findsOneWidget assertion). Verified: 106/106 tests (new test asserts armed name, no badge pre-selection, `WALL ·` badge after wall commit, badge cleared by Esc, re-arm renames the Blocks badge), analyze clean, release build OK, live-verified - `Door 0.90` under Blocks from boot, placing a door put `DOOR 0.90` under Inspect, Esc emptied it, and `Double door ...` showed real ellipsis truncation after a library row tap. Files: `lib/ui/model_view.dart`, `test/widget_test.dart`.
- Run 20 (tasks 68+76+97, user-directed): every CAD block now renders a REAL downloaded 3D model — 48 CC0 Kenney meshes bundled in `assets/kenney/` (Furniture Kit, Car Kit, 3D Nature Pack, Prototype Kit, Blocky Characters). `tool/bake_kenney.py` bakes texture-mapped OBJs into flat-Kd OBJ+MTL so per-face colors reach our parser (car = 148 colors, person = 11). 16 new block defs (chair, office chair, bunk, corner sofa, bench, side table, floor lamp, rug, plant, TV, coat rack, ceiling fan, closed cabinet, microwave, dryer, bath cabinet, trash). Openings now show real leaf/frame meshes (door-rotate, door-sliding-double, wall-window); `kKenneyZLift` bakes mount heights (window sill 0.95, ceiling fan 2.45, bath cab 1.35, TV 0.45, microwave 0.95). Procedural body code deleted per user directive (no stand-in shapes). Scale gizmo: `Block3d` gains `sx/sy/sz` + `bz` (serialized, undo-safe); selected block draws the true mesh AABB (`blockMeshBox`/`blockLocalBox`) with 6 square face grips — ±x/±y scale with opposite face anchored, +z resizes height base-pinned, -z drags vertical lift (wall-mount). Hover shows resize cursors, drag shows a live `W/D/H/LIFT` dim pill; inspector gains Width/Depth/Height/Lift fields + Reset size. `parseStl` (ASCII+binary) joins `parseObj`; import button accepts `.obj/.stl` and auto-loads sibling `.mtl`. Verified: 113/113 tests (new: all-mesh coverage, stretch/serialization, STL ascii+binary), analyze clean, release build OK. Files: `lib/model3d.dart`, `lib/ui/model_view.dart`, `lib/obj.dart`, `tool/bake_kenney.py`, `assets/kenney/`, `test/obj_test.dart`, `test/model3d_test.dart`.
- Run 21 (user-directed batch): (1) `New` now really clears the 3D tab — `_fixSel()` in the ListenableBuilder drops a `_sel` pointing at a deleted model (the stale-selection leak that made New look uncleared); rail gains a labeled NEW MODEL button (`newModelBtn` key) since the header `+` was too subtle. (2) LAG FIX: `_SolidPainter` rebuilt `modelFaces` per repaint — thousands of mesh vertex transforms on every hover/orbit frame. `Model3d.cachedFaces()` caches by `_geomSig()` hash of all geometry fields so any mutation auto-invalidates; draft mode also culls sub-pixel faces. (3) RENDER toggle (lightbulb, 3D top-right): sky gradient backdrop, sun-projected ground shadows, wider Lambert range, no wireframe — the "simple V-Ray for now". (4) `Block3d.tint` (serialized) — MATERIAL swatch row in the block inspector blends color over baked mesh colors. (5) 1K-LINE CAP: model_view.dart 4404 -> 839 + 4 `part`/`extension` files `mv_gesture.dart` (898, hit-test/snap/drag/gizmo/generate/import), `mv_panels.dart` (992, rail/toolbar/status/HUD/onboard), `mv_inspect.dart` (711, inspector+library), `mv_paint.dart` (1000, painters+helpers). RECOVERY NOTE: mid-split I dropped the build() body — recovered verbatim from `%APPDATA%\Devin\User\History\<id>\` local-history snapshots; ALWAYS snapshot a file before scripted surgery (no git here). Remaining >1k files to split in later runs: drawing_view 2242, sheet_view 2019, excel_export 1920, model3d ~1860, work_panel 1483, state 1288, pdf_export 1076, main 1002. Verified: 113/113 tests (zero-behavior-change split), analyze clean, release build OK. Files: `lib/model3d.dart`, `lib/state.dart`, `lib/ui/model_view.dart`, `lib/ui/mv_{gesture,panels,inspect,paint}.dart`.
- Run 22 (user-reported defect): blocks rendered as floating fragments / un-pickable. Root cause found by the new HEADLESS RENDER SIM (`test/model_render_test.dart` — rasterizes the real modelFaces+cam3Project pipeline to PNGs in test/out/): `_objLocal` assumed mesh-x↔def-width / mesh-y↔def-depth, but thin panels ship their width in the OTHER axis — `min()` then picked the tiny thickness ratio and squashed doors/windows/TV/car to floating chips. Fix: try the 90°-swapped fit and keep the orientation allowing the LARGER uniform scale (window 0.06→0.67m, car 1.06→3.06m, door-dbl 0.29→1.50m real). Secondary fixes: `_geomSig` now hashes `blockMeshes.length` + per-block mesh presence (registry changes — imports/customs — invalidate the face cache; sim-proven stale before); `kKenneyZLift` trimmed to ceiling-fan only (the wall-window mesh carries its own sill; tv/microwave/bath-cab standalone lifts read as "floating" bugs); six baked prototype MTLs recolored from black to material tones (window glass-blue, door wood, stairs/columns concrete). `cam3Project`/`cam3Depth` extracted as public shared projection (painter+sim one truth); `_proj3`/`_depth3` delegate. Sim = 4 tests: per-def grounded-geometry audit table, cache invalidation, per-def PNG raster + coverage, 2D linework — runs inside `flutter test` every suite pass. Verified: 117/117, analyze clean, release build OK; PNGs eyeballed — table legs, sedan wheels, window opening all real. Files: `lib/model3d.dart`, `lib/ui/mv_paint.dart`, `lib/ui/mv_gesture.dart`, `test/model_render_test.dart`, `assets/kenney/*.mtl`.
- Run 23 (user-reported "i cant draw"): dead-canvas + insertion friction fixes. (1) `_ensureModel()` — any canvas tap/drop/commit with `_sel == null` lazily creates 'Model N' instead of no-op'ing (New-project/empty-project canvases are never dead); `_closeWall`/`_closePoly`/`_addRect`/`_planTap`/`_modelTap` route through it. (2) Zoom-fragile close thresholds fixed: `dist*scale < 10/18 px` alone let a LEGIT chain point close the wall early at fit-zoom (low px/m) — now ALSO capped at 0.35m (loop-close on start) / 0.13m (double-tap-end), so thresholds are honest at any zoom. (3) DRAG & DROP furniture: library rows are `Draggable<CadBlock>` (horizontal affinity — vertical list scroll untouched); both canvases are `DragTarget`s that place the block at the drop point via shared `_placeBlock` (plan `_s2w` / 3D `_s2g`, snap-resolved, selected after drop, def stays armed for repeat drops). (4) New widget test: tap on a zero-model canvas creates Model 1 + draws/commits; 3D-side placement works the same. Verified 118/118, analyze clean, release build OK. Files: `lib/ui/mv_gesture.dart`, `lib/ui/model_view.dart`, `lib/ui/mv_inspect.dart`, `test/widget_test.dart`.
