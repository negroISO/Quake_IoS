# Q3DM4 transparency, fog and quad-light repair — 2026-09-21

The bounded repair is implemented, built for Mac Catalyst and the USB iPhone 17 Pro Max, and verified with demo captures, Metal traces and GPU buffer readbacks. Complete native lighting parity remains open.

Start commit: `4fbb9cc8efee676952ebb6334994b40316e38368`, branch `metal-renderer-fresh`. The published code commit is the commit containing the repository copy of this report. Final source/binary fingerprints are in `tested-source-sha256.json` and `tested-binaries.json` in the artifact directory.

Canonical checkout: `/Volumes/iOS/Projects/Quake_IoS_Phase9_Fork`.
Artifact directory: `/Volumes/iOS/Quake_Review_20260921/q3dm4_fix`.
Capture runs: `/Volumes/iOS/Quake_Review_20260920/raster_logic/runs`.

## Changes and evidence

- **Explosion stages and smoke/plasma masks:** animated shaders retain their logical identity. Sprites and animated MD3 effects emit authored stages at each entity's shader age through immutable texture aliases. Rocket explosions now include both authored animated stages. Sprite normals are initialized; custom-skin draw measurement and emission stay consistent. Stock alpha is preserved; replacement-only alpha reconstruction and explicit shader alpha tests remain separate.
- **Grey PBR effect polygons:** classic effects bypass PBR readability floors, emissive replacement modulation and extra entity dynamic-light RGB. The old floor raised black additive pixels into visible grey carriers. An old-build floor=0 control removed the defect; subsequent captures verify zero effect floors while pickup/viewmodel floors are deliberately configured to 0.4/0.2. The actual draw records confirm the stock effect textures and stage state.
- **Blend coverage:** entity alpha uses source-over coverage; filter/subtract decals preserve destination alpha. Translucent world/fog layers also use source-over alpha without changing RGB factors. Final RT fog frames 40/420 have alpha minimum 255 on both platforms, versus 191/200 before the world-alpha correction. Raster frame-40 RGB MAE for that correction is exactly 0 on both platforms. Raw raster world alpha has a separate remaining limitation below.
- **Fog geometry and animation:** eight fog-only carrier triangles are excluded from the RT AS without renumbering primitive/material IDs. All 1,600 q3dm4 bulge vertices update from the raster formula and scene clock; the AS refits before RT in the same command buffer. Previous deformed vertices supply deformation motion. Repeated scene timestamps reuse current positions as previous positions: the frozen control had 1,600 falsely moving vertices before, and zero after on both platforms; regular playback still has 1,600 moving vertices.
- **Fog coordinates:** cameraUp × cameraRight recovers Q3's forward axis because cameraRight is minus Q3 axis[1]. Across 28 sampled camera bases, its dot product with native forward is 0.99999942–0.99999999; the previous cross product pointed backwards. Fog S/T is evaluated at vertices and interpolated, matching native Q3. Artificial fog-boundary opacity floors were removed.
- **Quad/gameplay lights:** gameplay lights survive `r_rt_lights=0`, independently of authored RT lights. Their radius is an influence volume, not a physical emitter radius. They bypass authored top-K/chroma suppression, use finite-radius falloff and correctly bounded occlusion rays, and use immutable per-frame light data. A controlled iPhone quad on/off comparison with GI/reflections disabled adds average floor RGB of approximately (1.22, 1.52, 6.88)/255: the environmental blue contribution is restored.
- **Metal4FX lifetime:** preserved the pre-existing local residency-set/resource retention and lazy sidecar changes, and added bounded command-allocator lifetime. Fresh effect allocators remain retained through GPU completion; no in-flight allocator is reset. The repaired full iPhone run completed all 30 captures. Sampled allocator storage stayed at 664,712 bytes, while total Metal allocations ranged from 862,453,760 to 1,165,295,616 bytes. The earlier run was killed by signal 9; its precise OS kill reason was not established.

Changed implementation files: `Quake3-iOS/MetalView.swift` and `code/ios/metal_renderer_stub.c`. Capture instrumentation is opt-in. Other pre-existing local files were preserved.

## Validation

Reference: locally compiled Quake3e Vulkan/MoltenVK on the Mac with the same demo and stock assets. This is not a new Windows GPU capture. Effects have some cgame randomness, so exact transient counts/rotations are not claimed to match across every run.

Fixed demo clock: 50 ms, 1280×960 output. Checkpoints: frame 40 initial fog; 420 outside-fog spines; 840 rocket/smoke; 1320 plasma; 1680 quad. Align by scene timestamp rather than the diagnostic engine counter.

| Check | Result |
|---|---|
| Final Xcode Catalyst and iOS builds | Passed; canonical and build-worktree source hashes match |
| RT checkpoints on both platforms | Captured with Metal API validation; no reported runtime/Metal errors |
| Raster rocket/plasma checkpoints on both | Captured; stock masks/effects visually checked |
| Full q3dm4 runs | 30 captures per platform; iPhone uses Metal4FX, Catalyst uses its RT fallback path |
| Final frozen/moving checks | Both platforms: 0/1,600 moving deformation vertices; finite GPU motion |
| Final fog checks | Both platforms: raster and RT captures at frames 40/420; RT coverage fully opaque |
| q3dm6 `four` / q3dm17 controls | Column layers and launch-area assets retained in raster/RT captures |
| iPhone installation/settings | Final build installed; original config restored and verified byte-for-byte before normal launch |

The full runs and broad controls used the main repair before two final follow-ups: repeated-timestamp motion handling and the world-alpha factor. `late-final.delta.patch` proves these are the only differences. Both final builds then passed the targeted frozen, moving and fog checks. No full performance or frame-interpolation certification is claimed.

The original harness marked the completed iPhone full run and two q3dm17 controls FAIL because their standalone startup echo was absent. Raw manifests are preserved. Independent verification checks the actual demo/map/pose, fresh frame hashes, completed GPU traces where applicable, validation logs and an app alive until intentional termination. See `full-phone-independent-verification.json` and `release-verification.json`; these are explicit handshake exceptions, not rewritten PASS manifests.

GPU evidence includes actual encoded entity draw states and bound textures, deformed vertex/index inputs and GPU-written RT/motion outputs. World submission lists alone are not treated as draw-call proof. Xcode UI replay became unavailable (`cgWindowNotFound`), so no successful final UI replay is claimed. API validation was confirmed in logs; ordinary full runs also requested shader validation. Debug/capture overhead makes their FPS unsuitable as a performance benchmark.

Useful artifacts:

- `final-effects-comparison.png`, `pbr-floor-control.png`, `final-phone-full-contact.png`, `final-catalyst-full-contact.png`, `final-controls.png`.
- `quad-isolate-final.png`, `quad-isolate-deterministic.json`, `fog-basis-check.json`.
- `final-gpu-comparison.json`: byte-identical Catalyst/iPhone world vertices at all five checkpoints; effect floor/state evidence.
- `release-verification.json`: final paused/moving and fog measurements, including remaining raw-alpha/motion caveats.
- `build-final-tested-{catalyst,phone}.log`, `tested-source-sha256.json`, `tested-binaries.json`.

Reproduction drivers in the artifact directory: `final_validation.py`, `final_raster_fx.py`, `verify_pause_fix.py`, `verify_fog_coverage.py`; verifiers: `analyze_final.py`, `verify_full_run.py`, `verify_release.py`. They call the existing demo/GPU capture harnesses with explicit cvars. Builds use Xcode.app's Developer directory, the `Quake3-iOS` scheme, Debug, and the Catalyst or generic iOS destination. `git diff --check` passed.

## Local coder and retrieval

The local LM Studio coder supplied bounded sprite-stage, light-weight, fog-varying and allocator drafts after a unified-diff apply/compile/assert smoke test. Drafts were reviewed and corrected before integration; `lm-review.md` and the saved prompts/responses record rejected or repaired details. No Claude fallback was needed.

ddemby was queried before subsystem/failure work. Relevant results covered fog overlay replay, the old cap-floor workaround and earlier motion reset work. Most FX, allocator and harness queries were weak/unrelated; reformulated searches were followed by native/current source and SDK-header inspection.

## Ranked remaining work

1. **Lighting parity:** RT GI, PBR brightness/exposure, emissive energy and fog color/overbright calibration still differ from native. The restored quad contribution does not establish full lighting equivalence. Compare fixed camera/material regions before changing global scalars.
2. **Decal geometry:** native versus Metal plasma-mark clipping/submission counts previously differed (630 versus 693 indices). Correct masks/blending do not establish exact clipping parity; compare the clipping inputs and resulting polygons next.
3. **Temporal and alpha cleanup:** paused deformation inputs now match, but raw motion still contains the existing ray-jitter contribution (about 0.000382 UV in the frozen sample). Raw raster world passes also retain asset alpha: final frame-40/420 alpha minima are 63/0 despite corrected fog blending. Do not claim zero total paused motion or universally opaque exported raster alpha. Audit these separately with explicit output contracts.
4. **Broader RT geometry:** this refit supports q3dm4 bulge. General wave/move/autosprite deformation and alpha-tested AS occlusion remain separate work.
5. **Performance/backends:** profile a release build with capture/validation disabled. The exercised iPhone path is Metal4FX; the earlier legacy MetalFX residency problem and frame interpolation are not certified by these runs.

No additional PBR assets are required for the fixes in this batch. The separate q3dm6 animated column-face Remix material/export request remains open.

Would another engineer notice the before/after? **Yes:** corrected explosion stages, removed grey effect carriers, restored fog and continuing RT spine animation are visible; the quad contribution and frozen deformation behavior are measured.
