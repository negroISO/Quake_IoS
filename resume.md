# Resume: Quake_IoS Metal Renderer Validation

Stop point: 2026-04-25, branch `metal-renderer-fresh`.

## Current State

- User corrected the active parity targets: use `q3dm4` and `nv15demo2` references first. `four` is only valid once the new `/Users/targus/Documents/four_ref.avi` source-of-truth recording is processed.
- Target physical device is the iPad Pro M4 13" named `Oled`, UDID `937CF279-EC34-51CC-8FB6-A0B8C719B6E2`. The earlier iPhone selection came from `q3dev_run.sh` matching only `connected.*iPhone`.
- Latest successful iPad q3dm4 Metal capture:
  `/Users/targus/Desktop/q3sim_sessions/2026-04-25_19-41-29__581d0e2_q3dm4-ipad-parity_dev`
- Existing q3dm4 Quake3e/Vulkan reference:
  `/Users/targus/Desktop/q3sim_sessions/2026-04-25_17-13-24__581d0e2_q3dm4-ipad-dev/reference_quake3e/frames`
- Existing q3dm4 compare artifact:
  `/Users/targus/Desktop/q3sim_sessions/2026-04-25_17-13-24__581d0e2_q3dm4-ipad-dev/compare/q3dm4_metal_vs_quake3e_sheet.jpg`

## Changes In This Stop Commit

- `scripts/q3dev_run.sh`
  - Supports `DEMO`, `VIDEO_NAME`, and `LAUNCH_COMMAND`.
  - Auto-detects connected iPad or iPhone.
  - Passes `Q3_LAUNCH_COMMAND` into the app and pulls `Documents/baseq3/videos/${VIDEO_NAME}.avi`.
- `Quake3-iOS/Quake3_iOSApp.swift`
  - Reads `Q3_LAUNCH_COMMAND` from the process environment instead of requiring hardcoded demo launch edits.
- Entity animated shader parity work:
  - Animated frame textures inherit parent shader metadata: blend, alphaFunc, tcGen env, rgbGen, alphaGen, rgb/alpha waves, const colors, and tcMod chain.
  - Entity draw commands now carry `shaderTime`; Swift feeds it into entity uniforms so wave/tcMod effects use per-entity shader time.
- Existing nv15 BSP allocation diagnostic/fix remains in the tree:
  - Blob budget counts patch surfaces instead of all BSP surfaces.
  - `Z_TagMalloc` logs an Apple backtrace on over-INT_MAX allocation.
- `scripts/q3push_baseq3.sh`
  - Adds `--bundle <bundle.id>` support for pushing assets to other installed Q3 iOS apps.
- `Resources/baseq3/demos/q3dm4.dm_68`
  - Added user-recorded iPad q3dm4 demo.

## Validation Already Done

- Xcode build succeeded on iPad after fixing `e->shaderTime.f`.
- q3dm4 iPad capture succeeded and produced `q3dm4.avi`.
- q3dm4 log showed:
  - `Demo file: demos/q3dm4.dm_68`
  - `Metal world: 1 fog volumes (1 with resolved fogparms)`
  - `[world-env-audit]` lines present
  - `[decal-audit]` lines present
  - no fresh `[asset-miss]` or white fallback found in the quick grep

## Required Next Step

1. Compare the new q3dm4 iPad frames against the q3dm4 Quake3e reference, not `four`.
2. Run `nv15demo2` on the iPad with:
   `DEVICE=937CF279-EC34-51CC-8FB6-A0B8C719B6E2 DEMO=nv15demo2 VIDEO_NAME=nv15demo2 RUN_SECS=100 ./scripts/q3dev_run.sh nv15demo2-ipad-parity`
3. Process `/Users/targus/Documents/four_ref.avi` only when resuming the `four` comparison.
4. Pick one visible mismatch and run the 3-source check:
   - ioq3 original behavior
   - Quake3e/Vulkan Kenny Edition behavior
   - Quake_IoS Metal behavior
   - verdict / next fix

## Current Suspicions

- q3dm4 white floor/sky-like blanking was likely fog or pass-state related, but the latest screenshots appear improved; confirm from q3dm4 frame comparison before patching.
- q3dm4 remaining obvious issues may include dark/black curved ceiling geometry or missing shader/fog behavior.
- Do not treat `four` debug-pair artifacts as authoritative until the newly added `four_ref.avi` is extracted and aligned.
