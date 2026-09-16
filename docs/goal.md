# GOAL — 2026-09-16 · Raster parity before RT (PAUSED for machine transfer 2026-09-16 ~15:10)

## Objective (user ralph-loop spec, 2026-09-16)

Restore 1:1 parity of the native Metal non-RT Mac Catalyst renderer with pinned
ioquake3 raster behavior and original game assets — shader for shader, scene
for scene — BEFORE any RT versioning work. Match framebuffer resolution,
aspect, viewport, FOV, camera and demo time; verify capture pixel dimensions
without rescaling. Apply one minimal upstream-backed renderer correction at a
time; C stays authoritative for shader-stage decisions, Metal is executor.
No gameplay/timing/simulation/asset/hook changes. Output completion promise
`RASTER_PARITY_VERIFIED` only when fully verified — never from one demo or a
green build.

## Definition of done

- Deterministic capture harness (1280x960 both legs, fixed vantages, unified
  tone config) — DONE, see resume.md for the recipe.
- Per-vantage scene diffs at ≤1.10x luma ratio AND no structural region
  outliers, across q3dm4 + q3dm1 + nv15 vantage sets.
- Weapon viewmodel placement verified by silhouette A/B (area/centroid within
  ~15% of ioq3).
- Clean Metal validation on the acceptance build.
- Each renderer correction in its own reviewed, pushed commit.

## Open from prior batches

- v2-hall bright-region residual (0.54-0.87x, ceiling-shaped): UNSOLVED.
  First Codex verdict REJECTED (direction contradiction, absent diff).
  Next instrument: lightmap texel forensics (see resume.md §6).
- Stage-72 iPad confirm + full MTL4FX device validation: BLOCKED—device.
- Comparator five genuine mismatches: HOLD (user decision).
- Raster wall "corruption" in AVI captures: NOT REPRODUCED in lossless; cause
  UNCONFIRMED (capture-path amplification hypothesis only) — parked.

## Workspace + Branch + HEAD

Repo /Volumes/iOS/Projects/Quake_IoS_Phase9_Fork, branch metal-renderer-fresh,
HEAD dddf7bcf (FOV fix, pushed). All evidence in
/Volumes/iOS/Quake_iOS27_Review_20260914/ (deletable review folder — PRESERVED
per standing no-deletion decision).
