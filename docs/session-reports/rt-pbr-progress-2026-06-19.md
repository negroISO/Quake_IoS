# RT PBR Progress — 2026-06-19 (q3dm1, OLED iPad Pro M4)

Branch `metal-renderer-fresh`. Baseline reset to `2e53826a` (codex's overnight
work reverted — it bundled a Catalyst-corrupting HDR change + over-aggressive
emissive gating; tagged `codex-overnight-backup`). All work below verified on the
**OLED device** (Catalyst AVI capture is a separate broken path — do not trust it
for visual truth).

## What works (committed + OLED-verified)
- **`1ef96071` entity-floor (`r_pbr_entity_floor`, default 0.40):** world item
  pickups (RL/ammo/plasma — authored metallic=1.0) were rendering as near-black
  silhouettes because metal has zero diffuse and only reflects the near-black IBL
  cube; world entities had no readability floor (viewmodels did). Fix lifts
  non-viewmodel entities by unlit albedo × floor. Ammo box now visible.
- **`1ef96071` Step 1:** `RTPrimitiveMaterial` gained `pbrSlots`(uint4) +
  `rtPBRParams`(float4) as 16-byte-aligned tail (192-byte stride, Swift==MSL).
- **`3632da10` Step 2a:** RT kernel texture table moved to a Metal **argument
  buffer** (`RTTexTable` @buffer(8)), lifting the 128 direct-binding cap. Renders
  identical. `texArgEncoder len=1008` (126×8).
- **`72d1ef81` Step 2b:** added normal+height sidecar tables to RTTexTable
  (parallel to albedo). `len=2768` (346×8). Renders identical.
- **`01f725ee` Step 2c — RT normal mapping (`r_rt_normal_scale`, default 0):**
  rtKernel builds analytic TBN (RTWorldVertex has no tangent) + perturbs N before
  the NEE `dot(N,L)` terms. A/B (0/1/4) shows correct progressive bump on
  strongly-normal-mapped surfaces; **subtle on flat lightmapped surfaces**.

## Key diagnosis
- **RT shading was albedo×lightmap dominated** → normal mapping (and future
  parallax/roughness) gets washed out by the baked Q3 lightmap. RTX Remix uses NO
  Q3 lightmaps. This is THE blocker to the RTX look.
- The RT kernel is otherwise albedo+lightmap+emissive + NEE sun/2-local-lights
  (shadow-rayed) + optional 1-bounce indirect + optional reflections.

## In progress (UNCOMMITTED, tuning on device)
- **RT lighting rebalance** (`r_rt_lightmap_scale` [0..1] default 1.0,
  `r_rt_direct_scale` [0..8] default 1.0; carried in rtPBRGlobal.z/.w). Dims the
  baked lightmap + boosts RT direct so PBR detail reads. Default = current look.
  Tuning toward RTX: e.g. `r_rt_lightmap_scale 0.35 ; r_rt_direct_scale 3 ;
  r_rt_normal_scale 1`. Awaiting final values to bake + commit.

## Known issues / next
- **Parallax (Step 5):** reserved `rtPBRGlobal.y`; reuses Step 2c TBN. Will read
  on the stone floor only after the lighting rebalance lands.
- **Emissive clamped to 4.5** (persisted `r_pbr_emissive_intensity_max`); RTX
  authors up to 982. Needs HDR backbuffer + tonemap to lift without white-clip.
- **Viewmodel weapon renders dark** — separate from RT (viewmodel is rasterized,
  not RT-shaded). Investigate after rebalance.
- **Console arrow keys** emit `UIInputUpArrow`/`UIInputDownArrow` instead of
  history nav — `Q3InputView.keyDown` mapping fix pending.
- **Catalyst AVI capture broken** (channel-swap/blocky) — Catalyst is compile +
  fast-iteration only; OLED device is visual truth.

## Capture artifacts note
`~/Desktop/q3sim_sessions/` (33 GB: 113 AVIs + 105 frame dirs) are reproducible
captures — safe to delete. Durable knowledge lives in CLAUDE.md, git commits, and
the curated reports in this directory.
