# Tantyahin

**Free construction estimating, CAD drafting and 3D modeling for Windows** —
one desktop app that takes a project from bill of quantities all the way to
printed drawings. Built with Flutter, named after *tantya*, the Filipino word
for "estimate".

No subscriptions, no accounts, no cloud lock-in — projects are plain
`.boqproj` files you own.

## Why Tantyahin

Estimating software is expensive, CAD software is expensive, and they don't
talk to each other. Tantyahin was built for Philippine public-works and DepEd
school estimates, where one engineer prices the job *and* draws the plans.
It's just as useful for private work — flip to the Private template and every
office header disappears.

## What you can do

- **Estimate live** — a spreadsheet-style BOQ with a 180+ item price
  database, labor-rate factoring, and built-in quantity calculators
  (concrete, masonry, tiles, painting, carpentry, steel, stairs) that do the
  volume math for you.
- **Export real office documents** — one click writes a full Excel workbook
  (BOQ, Program of Works, PERT-CPM, S-Curve — live formulas, not pictures),
  plus PDF and DOCX. Public template includes letterhead and signatory
  blocks; Private template is a clean free-form sheet.
- **Draft like CAD** — walls with automatic corner joins and openings,
  dimensions, endpoint/midpoint/edge/axis/grid snapping and typed offsets.
  Import DXF, DWG (bundled LibreDWG), IFC, OBJ — or trace over PDF plans
  page by page.
- **Model in 3D** — parametric walls, columns, volumes and a block library
  (doors, windows, roof trusses). SketchUp-style seating snaps blocks onto
  walls at any angle and onto solid tops.
- **Generate drawings from the model** — floor plans, four elevations, roof
  framing, structural and utility sheets that match the 3D model:
  corner-closed walls, tagged openings (`D1`, `W1`…), dimension callouts and
  a title strip whose logo, title and text size you edit right on the sheet.
- **Check structure early** — preliminary NSCP 2015-aligned sizing checks
  for columns, footings, slabs and wall tie beams (a design aid, not a
  substitute for a sealed design).
- **Mark up and measure** — pen, highlighter, arrows, boxes and text notes
  on any sheet, plus calibrated takeoff measurement on imported PDFs.
- **Work in tabs** — browser-style project tabs with rolling autosave;
  drawings, markups, measurements and camera position all survive switching.

## Run it

```bash
flutter run -d windows            # dev
flutter build windows --release   # → build\windows\x64\runner\Release\tantyahin.exe
flutter test                      # 270+ tests
flutter analyze
```

Requires Flutter stable and the Visual Studio "Desktop development with C++"
workload.

## Repo notes

`AGENTS.md` documents the architecture (state model, DXF importer, generated
sheet pipeline, project tabs). The app icon is baked from `assets/logo.jpg`
by `test/carabao_icon_test.dart`.
