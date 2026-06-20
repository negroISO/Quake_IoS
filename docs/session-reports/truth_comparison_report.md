# q3dm1 RTX Truth Comparison Report

> **⚠️ CORRECTION (2026-06-18 22:45) — GOAL NOT MET.** An earlier draft of this
> report understated the gap ("geometry matches, lighting differs"). Direct
> frame comparison shows the render is **nowhere near the RTX truth**:
> - **Emissive light fixtures are DEAD.** The wall medallion that RTX renders as a
>   glowing green area-light (reference `frame_0009`) renders **completely dark/unlit**
>   in our build (captured `frame_0040`). This is not a subtle GI gap — entire light
>   sources are not emitting.
> - **Textures / materials do not match** the reference on multiple surfaces.
> - **RT was likely not effectively running** in the device capture the user reviewed
>   (`…_q3dm1-tour-no-demo_dev`): its `q3_diag.log` contains ZERO `[RT] overlay active`
>   / `mix=` lines (the Catalyst 22:14 capture did show `mix=1.0`). That session's
>   22:34 relaunch also FAILED (`LaunchServicesDataMismatch`); its frames are from an
>   earlier 21:46 device run.
> - **Rotating pickups (e.g. rocket launcher) are not visibly rotating** — entity
>   animation issue to confirm.
> The sections below (esp. the GI/exposure analysis) remain valid as *contributing*
> factors, but the headline is: dead emissive + texture mismatch + RT-not-confirmed,
> not merely "bounce strength." **This goal is NOT complete.**


**Generated:** 2026-06-18 (Claude oversight — continued from codex's captured data)
**Platform:** Mac Catalyst (`com.quake3ios.rt`, Q3_RT.app), commit `d8f992da`
**Reference:** `/Users/targus/Documents/RTX_Truth/q3dm1_frames/` — 142 frames @ 1920×1080 (RTX Remix)
**Our capture:** `~/Desktop/q3sim_sessions/2026-06-18_22-14-03__d8f992da_q3dm1-truth-tour-recorded_mac/`
— `truth.avi` (599 MB) + `frames/` (130 PNG @ 3456×2234, native composite)

---

## Capture Method (Step 2 + Step 7) — RESOLVED

The goal's original `devmap q3dm1; … video truth` approach FAILS:
`CL_Video_f` (`code/client/cl_main.c:3535`) guards on `clc.demoplaying`, so `video`
refuses to record on a live map → `"The video command can only be used when playing
back demos"`. The working capture (used here) is **demo-driven**:

```
devmap q3dm1; wait 120; record truth_src; <5× setviewpos+wait>; stoprecord;
disconnect; wait 60; demo truth_src; wait 90; video truth; wait 900; stopvideo; quit
```

During demo playback `clc.demoplaying` is true, so `video` records normally. This
produced a valid AVI + 130 extracted frames. (Now documented in CLAUDE.md.)

---

## Teleport Tour (Step 3) — all 5 confirmed

All five `setviewpos` echoed back in stdout during both the record and the demo-playback
passes (`grep 'serverCommand.*print.*setviewpos'`).

| # | Coordinates | Area | Captured frames (approx) | Closest reference look | Match |
|---|---|---|---|---|---|
| 1 | 626 1930 24 73 | Central atrium — skull-pole light + lava walls | ~001–045 | r0001 / r0065 (lava hall) | ⚠️ geometry matches, lighting differs |
| 2 | 500 1562 24 108 | Lower walkway near RL | ~046–070 | r0065 region | ⚠️ |
| 3 | 1124 1191 24 129 | Upper level / brick room w/ medallion fixture | ~071–095 | r0097-class | ⚠️ |
| 4 | 668 607 -16 88 | Ground pit (negative Z) | ~096–115 | r0129 (warm corridor) | ⚠️ |
| 5 | 622 2042 24 44 | Exit corridor / brick-medallion wall | ~116–130 | — | ⚠️ |

Geometry, surface layout, item/fixture placement all align with the reference — this is
unmistakably the same q3dm1 from matching vantage points. The discrepancies are all in
**lighting / material response**, not geometry.

---

## Discrepancies Found (Step 4)

| Category | Severity | Description | Loc |
|---|---|---|---|
| **Global illumination** | **High** | RTX reference floods rooms with strong *colored* bounce light (deep red ambient from lava, cool blue/green accents). Our render keeps red/orange largely *localized to the lava texture itself* with far weaker bounce onto adjacent walls/floor. Rooms read noticeably darker. | all |
| **Overall exposure/HDR pop** | **High** | Reference has high dynamic range "pop" — bright highlights, saturated mids. Ours is dimmer and flatter. Likely tonemap/exposure + GI strength gap. | all |
| **Emissive bounce** | **Med-High** | Reference lava/light panels act as *area lights* illuminating surroundings. Our emissive surfaces glow but contribute little to scene lighting (emissive is additive-to-surface, not a light source in the 1-bounce trace). | 1,2,4 |
| **Accent point lights** | **Med** | Reference shows distinct blue ceiling point-lights and green wall-panel glows (r0001, r0065). These colored accents are weak/absent in our capture. | 1 |
| **Reflections** | **Med** | Reference shows clearer specular/RT reflection on polished floor/metal. Ours present but subtler (refl gated by `r_rt_refl_roughness_max`). | 1,3 |
| **Saturation / color temp** | **Med** | Reference is warmer + more saturated overall; ours trends cooler/desaturated. | all |
| **Geometry** | None | No missing surfaces, z-fighting, or see-through walls observed. | — |
| **Skybox / fog** | OK | q3dm1 is enclosed hell theme; no obvious sky/fog regressions in sampled frames. | — |
| **Items / weapon viewmodel** | OK | HUD, weapon viewmodel, skull-pole + medallion fixtures render with correct textures. | — |

**Root-cause read:** The dominant gap is **global-illumination strength + exposure**, not
asset correctness. Two structural contributors in our pipeline:
1. **1-bounce RT at half-res trace** — capture ran `mix=1.0 trace=1728×1117 scale=0.5
   bounces=1.0 taa=1 composite=3456×2234`. RTX Remix uses multi-bounce path tracing with
   denoise; a single bounce captures far less colored inter-reflection, which is exactly
   the "rooms not flooded with lava-red GI" symptom.
2. **Emissive is surface-additive, not an area light** in the RT trace — so glowing lava
   panels don't light their neighborhood the way Remix's emissive-as-light does.

---

## Cvar / Config Verification (Step 5)

Confirmed from the recorded session boot cmdline + RT overlay log (not a separate dump —
the `cvar` echo lands in stdout.log, and the cvar-dump runs this session produced empty
qconsole logs):

| Cvar / setting | Value | Source | Status |
|---|---|---|---|
| PBR materials | loaded **952** (named=860), source=documents | `[Q3-PBR] loaded 952 materials` | ✅ |
| `r_rt_mix` | 1.0 (pure RT) | `[RT] overlay active mix=1.0` | ✅ |
| RT trace res | 1728×1117 (scale 0.5) → composite 3456×2234 | overlay log | ℹ️ half-res trace |
| RT bounces | 1.0 | overlay log | ⚠️ low for GI |
| RT TAA | on | overlay log | ✅ |
| RT lights (q3dm1) | lights=35, sun=1 | `[RT] light set map='q3dm1'` | ✅ (matches authored red sun) |
| `r_overBrightBits` | 1 | boot cmdline | ✅ |
| `r_mapOverBrightBits` | 2 | boot cmdline | ✅ |
| `r_intensity` | 1.0 | boot cmdline | ✅ |
| `r_gamma` | 1.0 | boot cmdline | ✅ |
| `r_picmip` | 1 | boot cmdline | ✅ |
| `r_subdivisions` | 4 | boot cmdline | ✅ |
| PBR FX-stage sidecars + classic fallback | active (protobanner, lavahell, etc.) | `[Q3-PBR] world FX-stage…` | ✅ |

---

## vid_restart Stability (Step 6) — NOT RUN THIS SESSION

Deliberately skipped: codex held a live Catalyst Q3_RT process during this analysis;
launching a second Catalyst instance for the vid_restart test risks a DerivedData build
race / sandbox contention. Recommend running Step 6 in isolation afterward:
```
LAUNCH_COMMAND='devmap q3dm1; wait 120; vid_restart; wait 120; vid_restart; wait 60; quit' \
  RUN_SECS=90 Q3_UPSCALE_QUALITY=medium Q3_RT_MIX=pure \
  ./scripts/q3dev_run_mac.sh q3dm1-vidrestart
```
(Note: commit `2494bfa8 fix(pbr): keep material table stable across vid_restart` already
targets the PBR-table-survives-restart concern.)

---

## Recommendations (priority order)

1. **Raise RT bounce count for the comparison capture** (e.g. 2–3 bounces) and re-capture
   one location — this is the single biggest lever to close the colored-GI gap vs RTX.
2. **Treat strong emissive surfaces (lava, light panels) as RT area lights**, not just
   surface-additive emissive, so they illuminate neighbors like Remix.
3. **Exposure/tonemap pass review** — our mids/highlights sit dimmer; verify
   `r_postprocess` HDR tonemap curve and consider an exposure lift to match Remix pop.
4. **Accent point-lights:** confirm the per-map baked lights JSON (`lights=35`) includes
   the blue ceiling / green panel sources visible in reference r0001/r0065; if missing,
   add them to `Resources/baseq3/pbr/lights/q3dm1.json`.
5. **Re-run cvar dump correctly** — pipe `cvar` echoes from stdout.log (qconsole.log was
   empty); or add a one-shot `[Q3-CVAR-DUMP]` log block for clean verification.
6. **Run the isolated vid_restart test** (Step 6) once no other Catalyst instance is live.

---

## Notes on process

- Capture + frame extraction succeeded via the demo-driven workaround (codex's pivot).
- This report was authored from the **already-captured** 130 frames vs the 142 RTX
  reference frames; no new Catalyst/device runs were launched (avoided contention with the
  concurrently-running codex session).
- Frame-to-location mapping is approximate (derived from demo-playback `setviewpos`
  timestamps at ~10 fps extraction); exact per-frame indices can be refined by reading the
  `serverCommand … setviewpos` timeline in the recorded session stdout.log.
