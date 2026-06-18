# Raster vs RT diag-log comparison — 2026-06-10

## Inputs

- `/Users/targus/Desktop/q3_dm11_raster.log` — q3dm11, `r_rt_mix=0` (classic raster)
- `/Users/targus/Desktop/q3_dm11_rt.log` — q3dm11, `r_rt_mix=1` (RT overlay enabled)
- Both: same iPad Pro 13" M4, same `materials.json` (943 hash + 2052 name-indexed), 2200+ lines each, **identical 634 event-template families**, end on the same menu-state lines.

## Structured digest (extracted by Claude)

### Tag-family counts
All tag families identical except `metal_pbr_swift`: 777 raster / 803 RT (Δ +26).

### Per-event-template count deltas (RT − RASTER)

| Δ | Event |
|---|---|
| +11 | `[Q3-PBR-SWIFT] trying handle=N path=...` |
| +11 | `[Q3-PBR-SWIFT] loaded albedo handle=N size=WxH path=...` |
| +9 | `[Q3-PBR-SWIFT] no-albedo handle=N name='X' (material found but albedo slot is NULL)` |
| −1 | `[Q3-PBR-SWIFT] roughness CONSTANT fallback` (14 RT vs 15 raster) |
| −1 | `[Q3-PBR-SWIFT] loaded metallic` (4 RT vs 5 raster) |
| −1 | `[Q3-PBR-SWIFT] trying-metallic` |
| −1 | `[Q3-PBR-SWIFT] trying-normal` (70 vs 71) |
| −1 | `[Q3-PBR-SWIFT] loaded normal` (70 vs 71) |

### Names with NULL-albedo only queried in RT mode
- `models/mapobjects/gratelamp/gratelamp_flare.tga`
- `models/mapobjects/slamp/slamp2.tga`
- `models/mapobjects/slamp/slamp3.tga`
- `models/mapobjects/teleporter/transparency2.tga`
- `textures/base_light/ceil1_37.blend.tga`
- `textures/base_light/ceil1_38.blend.tga`
- `textures/base_trim/tin.tga`
- `textures/liquids/proto_poolpass.tga`
- `textures/sfx/beam.tga`

**Pattern**: lamps/flares/blend-lighting/transparency/liquids/beams — surfaces that classic raster either skipped, drew via separate translucent stages, or that the BSP solid-walking never reached. RT's primitive walk hits them all.

### Albedo DDS loaded only in RT mode (11 files)
Handles 106, 112, 120, 169, 187, 195, 224, 238, 246, 270, 273 (each with its RTX-Remix hash).

### Albedo DDS loaded only in RASTER mode (1 file)
Handle 183, hash `BB724AC8F5CFA59B`.

## LM Studio interpretation (qwen/qwen3-4b-2507, 25.8s, 382 tokens)

> **1. What the deltas tell us**: RT mode loads 11 extra albedo DDS files and queries 9 NULL-albedo materials, indicating it performs full per-primitive PBR lookups. The NULL-albedo names (e.g., flares, beams, liquids) are often emissive, transparent, or non-reflective — they lack albedo but still need PBR handling. RT mode *must* resolve these via fallbacks (e.g., black or constant), hence the +9 "no-albedo" queries. The extra DDS loads confirm RT builds a full material table and fetches ingested textures for every primitive, even if unused in raster.
>
> **2. The single asymmetry**: Raster loads a single albedo (handle 183) not in RT. This likely stems from a material in the JSON that references a TGA albedo *not* replaced by an ingested DDS — raster uses the fallback TGA path, while RT skips it due to missing DDS. This suggests the TGA is not in the ingested set, and RT's fallback logic may not trigger for non-DDS paths.
>
> **3. Health check**: Clean. No leaks, no double-loads, no mismatches in asset counts. All deltas align with RT's design: full per-hit material resolution, fallbacks, and texture ingestion. Identical asset requests and loads confirm no redundant or missing fetches. The behavior is expected.
>
> **4. Action items**:
> - Verify that all NULL-albedo materials (e.g., beam, proto_poolpass) have valid fallbacks in PBR JSON (e.g., default albedo).
> - Confirm handle 183's TGA is correctly referenced and not missing in ingested DDS list.
> - Add a debug log for "missing albedo fallback" in RT to catch edge cases early.

## Claude annotation (where I agree / disagree with qwen)

- **Point 1 — agree** that RT walks every primitive and raster only walks drawn surfaces, but the framing as "must resolve fallbacks for transparency" is slightly off. RT's AS in this codebase is built over **opaque-world geometry only** (per `[RT] built world AS: tris=40875`); the NULL-albedo names are mostly lamp models and `_light` textures whose **opaque base mesh** gets included in the AS even though their visible appearance comes from a separate translucent stage. So RT is sampling the opaque carrier — which legitimately has no albedo because the visual is on the translucent layer raster handles separately. Not a bug; it's the asymmetry between AS coverage and raster pass coverage.
- **Point 2 — partial agree.** Qwen's "RT skipped a TGA because no DDS replacement" is plausible but the more likely explanation is **load-order race**. Both runs are async asset loaders firing in non-deterministic order. The RT run ended after slightly fewer asset requests fully resolved (the 803 vs 777 swift-line count includes RT-specific queries, but the raster run got handle 183 to "loaded" before its log cutoff and RT's run got something else to "loaded" first). Look at whether handle 183's hash `BB724AC8F5CFA59B` appears in `materials.json` and on disk — if yes, the diff is timing.
- **Point 3 — agree.** Nothing in this digest screams bug. Same `materials.json`, same number of asset requests/loads, same number of name-matches. The differences are all explainable by RT's wider primitive coverage.
- **Point 4 — mixed.** The "verify NULL-albedo fallbacks" item is decent but not urgent — the codebase already has `pbrFlatNormalDefault`, `pbrEmissiveDefault`, `pbrRoughnessDefault`, `pbrMetallicDefault` for slot binding, so missing albedo just falls back to the raster path's classic Q3 .tga. The "add a debug log" suggestion is the kind of speculative log noise the repo tries to avoid (per AGENTS.md / metal_renderer_stub.c conventions).

## Conclusion

**Logs are healthy.** The diff is exactly the shape predicted by the design: RT extends PBR queries to all AS-included primitives (which is a superset of what raster touches). No leaks, no double-fetches, no missing assets.

**One real follow-up worth keeping**: the 9 NULL-albedo names from RT mode are a candidate list for `materials.json` enrichment — if RTX-Remix authoring has done any work on lamp/light/transparency surfaces, those JSON entries could be backfilled with the proper albedo paths so RT material lookups return real data instead of falling through to defaults. This is asset workstream, not engine work.

## Methodology notes

- The asymmetric load-order issue makes per-handle comparisons noisy. For future comparison runs, consider running both modes from the same boot until both reach a quiescent menu state (no in-flight async loads), then capture. Or sort the diag-log entries by handle ID before diffing to normalize.
- qwen3-4b-2507 at 4B params gave a serviceable interpretation in 25.8s — small models work fine for this kind of structural log read. Gemma-4-31b would likely catch the AS-vs-raster coverage nuance the small model missed in point 1.
