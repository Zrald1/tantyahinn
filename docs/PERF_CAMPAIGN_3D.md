# 3D Painter Performance Campaign — Frame-Coherence Caching

**Date:** Nov 2026 · **Model under test:** furnished small house —
15,350 faces / 51,676 verts (GEALAN BIM windows, car, wood doors,
furniture) · **Harness:** `test/perf_campaign_test.dart` (Stopwatch on
the real pipeline, `ui.Canvas` + `PictureRecorder`)

## The problem

After the orbit-pivot integration the 3D view lagged. Root cause found
by inspection, then confirmed by measurement:

1. `_orbitFocus` recomputed `Model3d.bounds` (every wall + block
   footprint) **per projected vertex** — ~50k full-model walks/frame.
   Fixed first: per-build epoch cache (`_buildNo` ticks in the
   ListenableBuilder builder — the only boundary every paint-producing
   rebuild passes through).
2. Even with that fixed, `paint()` still spent ~50–100 ms/frame:
   ~410k libm trig calls + ~15k Path + ~30k Paint + ~50k Offset
   allocations on EVERY repaint, including repaints where the camera
   and model had not changed at all.

## Method (mycall campaign.py shape)

20 candidates enumerated from arXiv/graphics research + ZRALD mycall
techniques; the measurable ones were implemented as arms and timed on
the SAME model/camera. Verdicts come from the numbers, not theory.
The "quantum" framing is honest: the cache signature is the OBSERVER —
the world→screen transform only collapses (rebuilds) when the observed
signature changes; between observations the recorded display list IS
the frame (frame-coherence: arXiv 2411.00131, Sander et al.
reprojection cache).

## Results (two runs; suite-run numbers under load)

| Arm | ms/frame | speedup | verdict |
|---|---:|---:|---|
| A0 baseline (2-pass trig) | 47–100 | 1x | — |
| A4 **epoch Picture cache (hit)** | 3.3–4.2 | **14–24x** | **SHIPPED** |
| A9 lean-hoist (trig once, no allocs) | 44–48 | 1.1–2.1x | SHIPPED (rebuild path) |
| A8 batched drawVertices fills | 32–40 | 1.5–2.5x | HELD (fill-only; revisit) |
| A7 backface cull | 28–43 | 1.6–2.3x | REJECTED: orbiting inside a room culls every wall |
| A6 trig LUT 4096 | 48–58 | 1.0–1.7x | REJECTED: parity — trig was never the bottleneck |
| A5 vertex-dedup map | 79–91 | 0.6–1.1x | REJECTED: hash+lookup > math saved |
| A2 fused eval + materialized pts | 180–219 | 0.3–0.5x | REJECTED: 15k list allocs — allocs beat math |

## The 20 candidates

| # | Candidate | Verdict |
|---|---|---|
| 1 | `_orbitFocus` build-epoch cache | SHIPPED (the quadratic fix) |
| 2 | Frame-coherence Picture cache | SHIPPED — champion |
| 3 | Hoisted view constants (view-matrix) | SHIPPED inside rebuild |
| 4 | Fused depth+project, materialized lists | REJECTED (alloc pressure) |
| 5 | Post-transform vertex cache (value map) | REJECTED (measured slower) |
| 6 | Trig LUT / minimax poly | REJECTED (parity — no trig bound) |
| 7 | Backface culling | REJECTED (interior views vanish walls) |
| 8 | drawVertices batched fills | HELD — 2.5x, stroke path still needed in draft mode |
| 9 | Frustum/viewport cull | SHIPPED (free bbox reject) |
| 10 | Sub-pixel cull before Path build | SHIPPED (existed, kept+reordered) |
| 11 | Paint pooling (mutate color) | SHIPPED (~30k allocs → ~3) |
| 12 | Sort-order cache by (geom,cam) | Subsumed by #2 |
| 13 | BSP static depth ordering | REJECTED (overkill; sort ~1–3ms) |
| 14 | ui.Image raster snapshot | REJECTED (async, texture mem, DPR blur) |
| 15 | RepaintBoundary/layer split | n/a (CustomPaint repaints whole) |
| 16 | Isolate/compute() projection | REJECTED (paint is synchronous) |
| 17 | Float64List SoA vertex buffers | DEFERRED (big refactor) |
| 18 | Path pooling across rebuilds | NEUTRAL (paths die with Picture) |
| 19 | Adaptive LOD while camera drags | DEFERRED (fallback arm) |
| 20 | Dirty-rect partial repaint | REJECTED (unsupported by CustomPaint) |

## Shipped architecture

```
paint()
 ├─ sig = hash(yaw,pitch,zoom,pan,viewport,pivot,render,gridStep,dpr)
 ├─ identical(cachedFaces, sceneSrc) && identical(m, sceneModel) && sig match
 │     → canvas.drawPicture(_scenePic)          // ~4ms — the common case
 └─ miss → record _paintStatic into PictureRecorder, store, replay
        ├─ hoisted trig (cy,sy,cp,sp,pivot) once per rebuild
        ├─ depth pass + 2-level group/face sort (unchanged semantics)
        ├─ sub-pixel + frustum culls before any Path work
        └─ pooled fill/stroke Paints
_paintDynamic() — ghosts, snap glyphs, handles: always live on top
```

Invalidation is airtight: `cachedFaces()` returns a NEW List identity
on ANY geometry change (geomSig), the camera signature covers every
projection input, and model switching fails the `identical(m,…)` gate.
Undo/load/est.update flows all regenerate the face list → rebuild.

## Source log

- arXiv:2411.00131 — frame-to-frame coherence caching, layered scenes
- arXiv:1805.08893 — post-transform vertex reuse (arm A5, falsified here)
- Sander et al., "The Real-Time Reprojection Cache" — spatio-temporal reuse
- rxi.github.io/cached_software_rendering — signature-gated redraw
- GPU Gems Ch.28 / OpenGL best practice — hoist per-frame constants
- ZRALD mycall: YOCO (compute once, share everywhere), radix dedup,
  PSU-HQ quantized cache keys, memory-breakthrough alloc discipline

## Deferred arms (if camera-DRAG frames still feel heavy)

- Arm 8 (drawVertices fills, render mode): measured 2.5x — needs a
  stroke strategy for draft mode before shipping
- Arm 17 (SoA vertex buffers): ~2x vertex loop, broad refactor
- Arm 19 (drag-time LOD): drop sub-pixel faces more aggressively while
  a camera gesture is active — cheapest safe lever left
