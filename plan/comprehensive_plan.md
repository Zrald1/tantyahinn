# 3D MODEL Workspace — Comprehensive Improvement Plan

Created from the latest user review (rotated-wall screenshot + right-panel
screenshot). Ordered by user-visible impact. Nothing is implemented yet —
each phase lists concrete files/functions to touch so we can proceed
phase-by-phase on approval.

---

## Phase 0 — Dimension de-cluttering (the "still needs improvement" fix)

The diagonal strings work but the canvas is now crowded: chain labels
duplicate wall-seg labels (8.70 vs 8.70 m), bold overalls collide with seg
labels (9.28 over 9.28 m), and two-ordinate strings print a redundant
overall equal to the only gap.

- [ ] **0.1 Suppress the overall label + outer line when a string has ≤2
      ordinates** — a single-span string gains nothing from a second line.
      (`_extDims` `string()`, `_diagStrings`, painter diagonal pass)
- [ ] **0.2 Kill per-seg wall length labels when a dim string covers that
      seg** — the `9.00 m` / `7.85 m` mid-wall labels are redundant once a
      parallel string exists. Keep them only when `_dims` strings are off
      or the seg has no ordinates. (painter wall-seg label block)
- [ ] **0.3 Collision registry for dim labels** — extend `_placedLabels`
      to dim-string labels too; when two labels would land within ~24px,
      keep the first, drop the second (the 8.70/8.70 double-print).
- [ ] **0.4 Merge overlapping diagonal strings of collinear segs** — a
      chain of diagonal segs in one direction (the V's two legs) should
      share one string, not one per segment.
- [ ] **0.5 Axis strings must skip diagonal-only plans** — a fully
      rotated wing currently gets X/Y strings AND diagonal strings;
      when ≥60% of span-length is diagonal, drop the axis strings on
      the two axes the diagonals already measure.
- [ ] **0.6 Label rotation on diagonal strings** — rotate text to the
      string angle (readable ≤±75°) so labels ride the line instead of
      floating horizontally at odd offsets.
- [ ] **0.7 Verify:** screenshot sim on the user's rotated rect + V
      plan; confirm zero overlapping text, zero duplicate figures.

## Phase 1 — Properties tab gets real detail fields (user-flagged)

The Props list expands a row but shows only a summary block. Every
object needs its full editable field set inline:

- [ ] **1.1 Wall row → full editor inline:** name, thickness, height,
      base offset, color swatches, length (read), segment count,
      Delete — reuse `_wallInspector` widgets but expanded to show
      ALL fields at once (no scroll-collapse of dims).
- [ ] **1.2 Block row →** name, X/Y position fields, rotation (deg),
      per-axis scale (sx/sy/sz) or W/D/H derived, lift (bz), def type
      (read-only), Delete. Editable numerics, not just sliders.
- [ ] **1.3 Volume row →** name, area (read), base, top/height, color
      swatches, Delete.
- [ ] **1.4 Manual dim rows** — list `m.dims` entries with endpoints +
      measured length + delete button (they're erased today, invisible).
- [ ] **1.5 Row polish:** color chip, type icon, unit-aware summaries;
      the expanded editor must not be clipped at 296px — fields use the
      existing `numField`/`label` helpers at proper height.
- [ ] **1.6 Selection sync both ways stays** (list↔canvas) + the row
      flashes/highlights when its object is clicked on canvas.

## Phase 2 — Generated sheet parity

- [ ] **2.1 DXF floor plan gets manual dims + diagonal strings**
      (diagonal strings done; manual `m.dims` done — verify output).
- [ ] **2.2 Title block strip** on generated sheets: project name,
      sheet title, scale note, date, drawn-by — small text block
      bottom-right like production sheets.
- [ ] **2.3 Room names/areas as DXF TEXT** inside volumes (not only
      canvas labels).
- [ ] **2.4 North arrow + graphic scale bar** on the floor plan sheet.
- [ ] **2.5 Verify by opening the generated DXF in the app's DRAWINGS
      viewer** — inspect the artifact, not just the code.

## Phase 3 — Remaining UX gaps seen in screenshots

- [ ] **3.1 "0.82 m" tiny sliver labels** — suppress chain labels under
      0.10 m OR render them hairline-gray instead of same-weight text.
- [ ] **3.2 Wall labels on walls thinner than ~40px on screen** —
      drop to dims-only at low zoom (like the block label cap).
- [ ] **3.3 Eraser cursor on 3D shows over walls too** — currently tap-
      only delete; add hover highlight of what will erase.
- [ ] **3.4 Status strip:** when a diagonal wall is being drawn show
      angle (°) next to length — helps draw exact 30°/45° walls.
- [ ] **3.5 Keyboard cheat sheet (`?`)** — add E, D keys; the TOOLS
      section is missing the two newest tools.

## Phase 4 — Bigger ticket items (parked for later approval)

- **4.1 Wall-level parametric openings** — doors as wall children so
      erasing a wall cleans its doors; moving a wall drags them.
- **4.2 Aligned vs linear dims** — DIM tool modifier: Shift-drag =
      horizontal/vertical projected dim instead of aligned.
- **4.3 Ordinate-mode dimensioning** — production "datum" style: one
      baseline, all points dimensioned from it.
- **4.4 Layer system lite** — walls/furniture/dims on toggleable
      layers for print-clean exports.
- **4.5 Print/PDF of the 2D plan** — direct sheet export without the
      DXF round-trip.
- **4.6 BOQ linkage** — wall lengths × prices feed a BOQ section
      automatically (the original end-goal hook).

---

## Definition of done per phase

- `flutter analyze` clean; `flutter test` all green.
- Release exe rebuilt and relaunched.
- For visible changes: run the real app and eyeball the artifact
  (screenshot or generated DXF in the DRAWINGS viewer).
- `AGENTS.md` updated with any new shared helper or convention.

---

## Execution status

- Phase 0 DONE (single-span rule, sliver drop, covered seg labels, dedupe
  registry, diagonal-heavy overall-only, rotated labels, per-wall outward).
  0.4 (merge collinear strings) was subsumed by per-wall outward + dedupe.
- Phase 1 DONE (accordion Props with full wall/volume/block editors,
  dims list + delete). Verified in the real exe.
- Phase 2 DONE (room text, north arrow, scale bar, title block).
- Phase 3 DONE (sliver + low-zoom label suppression, wall angle readout,
  `?` sheet E/D rows, red eraser hover preview in the plan).
