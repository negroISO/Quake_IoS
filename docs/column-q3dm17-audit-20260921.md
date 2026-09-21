# q3dm6 columns and q3dm17 assets — 21 September 2026

The q3dm6 RT column now retains the stock opaque core, two independently animated masked layers, and stationary outer panel. The incorrect skull replacement was removed. q3dm17's classic launchpad backing is restored, 40 existing PBR DDS files are recoverable through a checked manifest, and a missing animation-atlas albedo no longer leaves atlas UVs or atlas sidecars applied to the classic fallback.

This closes the identified material/UV defects. It does **not** establish RTX Remix lighting parity. q3dm17's pad rim and lamp stems still become too bright, the green ammo icon remains too dim in RT, and high-frequency RT texture filtering needs work. The matching q3dm6 column PBR export is still missing; the user is looking for it.

## Scope and provenance

- Start commit: `1d5e6c78befcf58dc2a8b4bbcaa5aae2f400229e`, branch `metal-renderer-fresh`.
- Clean implementation/validation checkout: `/Volumes/iOS/Quake_Review_20260920/demo4_fix/Source`.
- Evidence directory: `/Volumes/iOS/Quake_Review_20260921/column_fix` (abbreviated `R` below).
- Native reference: local Quake3e Vulkan/MoltenVK executable under `/Volumes/iOS/Quake_Review_20260920/raster_demos/vulkan_reference`. This is the compiled Vulkan front end on Mac, not a fresh Windows/PC GPU capture.
- q3dm6: demo `four`, frames 260–300, 50 ms demo steps; frame 300 scene shader time 1071.700073 s, camera `(-1325.7079, -451.1493, 610.1135)`, FOV 90 × 73.73979. Native reference screenshots: `vulkan_reference/runs/four-13to15-logic/home/baseq3/screenshots/ref-000300.tga`.
- q3dm17: `devmap q3dm17`, `noclip; setviewpos 921.683899 64 25 0; cg_drawGun 0`, capture frame 240. Native reference: `vulkan_reference/runs/q3dm17-columns-launch-native/home/baseq3/screenshots/ref-000240.tga`. Live-map animation/pickup phase is not synchronized across launches.
- RTX appearance references: `/Volumes/iOS/Projects/RTX_Truth/Q3DM6.jpg` and `q3dm17_frames/frame_0021.png`. Different spectator/gameplay viewpoints and lighting make these qualitative material/lighting targets, not pixel-aligned ground truth.

## Changes

1. `metal_renderer_stub.c` no longer gives every `textures/sfx/` and `textures/effects/` JPEG a synthesized radial sprite mask. That operation also zeroed RGB and erased the opaque launchpad backing. Explicit model/sprite/UI policies remain.
2. A narrowly validated stock `blocks18cgeomtrnx` stage stack receives `Q3_METAL_WORLD_DRAWFLAG_RT_CLASSIC_LAYERS`. Raster and RT use its original textures rather than assigning one PBR owner to every layer. The RT material buffer keeps its existing 208-byte record layout and appends shared overlay records after the triangle records. Primary, diffuse-bounce, and reflected hits composite the three masks with each layer's original UV and ordered tcMods.
3. `RayTracingUniforms.sceneAnimationTime` was appended to both Swift/MSL tails. Original Q3 texture transforms now use the engine's scene shader time. Base texture transforms no longer rotate/scroll the static lightmap coordinates. Stochastic sampling, motion vectors, and the existing replacement-atlas clock were left intact.
4. Atlas metadata is enabled only when the replacement albedo actually loads. If it fails, normal/height/emissive/roughness/metallic atlas sidecars and authored material constants are suppressed coherently. Removed the name-only six-frame launchpad assumption.
5. A declared but unloaded emissive texture cannot register as a white authored area-light source. Constant-only records retain their existing route.
6. Removed the `BB9CB6998E4845D0` skull assignment specifically from `textures/gothic_block/blocks18cgeomtrnx` in tracked `Resources/baseq3/pbr/materials.json`. Other uses of that hash remain.
7. `scripts/repair_q3_comparison_assets.py` validates SHA-256 identity for all 40 files in `scripts/q3dm17_asset_manifest.json` before changing anything, restores only missing files, rejects conflicting files, and removes only the known skull assignment. DDS/PK3 files stay local.
8. Opt-in `Q3_GPU_TRACE_FRAME` / `Q3_GPU_TRACE_PATH` support captures one command-queue frame plus the exact RT material buffer and pre-denoising GPU albedo/radiance readbacks. Ordinary launches do not capture or wait for GPU completion. Set `MTL_CAPTURE_ENABLED=1` when using it.

Correction to the earlier audit: the column top actually uses `textures/gothic_floor/metalbridge06broke`, a static default shader. The similarly named `metalbridge06brokeb` has animated electric layers, but is not this top. Its current PBR top texture has a matching damaged chain/metal pattern. High-frequency shimmer/aliasing remains a filtering issue to investigate, not evidence that this top should rotate.

## Verification

Catalyst Debug built successfully (`R/build-final.log`). GPU sentinel checks of actual Swift/MSL structs passed with zero component mismatches: WorldUniforms 288 bytes, EntityUniforms 464 bytes, RayTracingUniforms 448 bytes; appended scene time at byte 432 (`R/layout-final.log`). `git diff --check` passed. The asset repair rerun verified all 40 files and restored zero, demonstrating idempotence.

Final Catalyst runs (`R/final-verification.json`) cover 15 captured frames: five raster and five classic-RT frames through the column jump, a PBR-RT column frame, and four q3dm17 frames (raster, authored-light RT, direct-light-off, emission-off). All runs reached the requested map/frame, remained alive until intentional termination, had Metal API validation enabled, and reported no bad markers or demo command errors. Output was 1280×960, native upscale, frame interpolation off; RT trace scale was explicitly 1. GPU capture runs disabled Metal shader validation; these are not shader-validation pass claims. Fixed demo timing and diagnostic capture overhead mean these runs are not performance benchmarks.

GPU traces and sidecars live in `/Users/targus/Library/Containers/com.quake3ios.logicaudit20260920/Data/Documents/`:

- `catalyst-four-colfix-final-pbr.gputrace`: frame 300, command status 4/completed, error nil.
- `catalyst-q3dm17-colfix-final-pbr.gputrace`: frame 240, command status 4/completed, error nil.
- `catalyst-four-colfix-gpu-column-raster.gputrace`: preceding equivalent raster capture.

`R/final-gpu-layer-check.json` verifies the actual bound buffer: 46 layered triangles, 24 shared overlay records, exactly three links per column surface, valid record bounds, stationary last layer, and the expected -30/-20 rotations and .2/.1 stretch frequencies. Pre-denoising RT output was finite, and the sampled opaque panel ROI had alpha 1. `R/final-gpu-albedo.png` shows the restored ring/core in the GPU output before denoising. These are real Metal captures and GPU readbacks; interactive Xcode replay inspection was not performed in this pass.

A separate paused-scene test disabled **both** timedemo and timescale. Frames 300/320 retained scene time 1070.700073 s while sampling time advanced from 16.6783 to 19.0091 s (`R/frozen-scene-check.json`). Pixel identity is not claimed: temporal jitter and the separate PBR-atlas clock remained active. Earlier tests using read-only `cl_paused`, or timescale alone with timedemo still enabled, were rejected and recorded in `R/rejected-pause-tests.json`.

The deliberately missing-albedo fixture retains the other five launchpad atlas sidecars. The captured six launchpad triangles have zero atlas parameters, no emissive flag, and invalid roughness/metallic sidecar slots (`R/missing-albedo-check.json`). The pad backing remains complete rather than being sampled as one sixth of the classic image. This verifies the missing-atlas route rather than simply testing with PBR globally off.

The final signed missing-albedo fixture also passed (`R/missing-albedo-final.log`, `R/final-missing-albedo-check.json`): six launchpad triangles, zero atlas parameters/emission, invalid scalar-map slots, and classic fallback constants roughness 0.85 / metallic 0. The canonical project now has all 40 restored files (`R/production-assets.json`); DDS files were not added to Git.

The fresh iPhone 17 Pro Max build installed over USB (`R/build-phone.log`, `R/install-phone.log`). Raster frame 300 passed and is pixel-identical to Catalyst in both column and weapon crops (MAE 0). RT PBR frame 300 and q3dm17 frame 240 passed with `r_rt_denoise 0`, selecting the legacy route for comparison with Catalyst (`R/phone-legacy-runs.json`). Column/weapon iPhone-versus-Catalyst RT MAE was 2.17 / 0.84 (`R/phone-columns.png`, `R/phone-comparison.json`). API and shader validation were enabled for these ordinary smoke runs, with no reported errors.

**iPhone MetalFX remains a blocker:** `r_rt_denoise 1; r_rt_denoise_metalfx4 0` aborted with shader-validation residency errors in MetalFX `bilateral` / `denoiser_between_processing`, involving the RT depth/albedo textures. This is not accepted as a passing default RT configuration, and this patch does not claim to fix it. The local uncommitted MTL4 residency changes were preserved but are outside the clean tested/published column patch; the failing run selected the classic MetalFX backend. Isolate this backend's residency/validation behavior next. The first phone capture also had a stale post-install container path; that harness-only attempt was rejected and retried using the new `fs_homepath` (`R/rejected-phone-launch.json`).

The iPhone GPU capture also completed at demo frame 300 on the legacy route. Its trace and six raw sidecars are under `/Volumes/iOS/Quake_Review_20260920/raster_logic/runs/phone-four-colfix-gpu-legacy/`. `R/phone-gpu-layer-check.json` confirms the same 46 layered triangles / 24 overlays, finite GPU output and opaque sampled panel. **All 30,715 used material records are byte-identical to the Catalyst capture**, with matching texture slots and scene time; SHA-256 `0cfd0b63e75f4fd8a0361b6de72bbca4684d4f581788f292a40ed6d3434293f8` (`R/cross-platform-gpu-check.json`). Sampling clocks differ as expected. Shader validation was disabled specifically during GPU capture; the preceding legacy smoke had shader validation enabled.

The q3dm17 iPhone/Catalyst launchpad ROI MAE is 1.82 at matching viewpoints (`R/phone-q3dm17.png`), subject to independent live-map animation phase.

## Image comparisons and remaining priorities

`R/columns-final.png`, `R/weapon-final.png`, `R/q3dm17-final.png`, and `R/comparison-metrics.json` provide the review images and metrics. Column-crop RGB MAE against native (0–255 scale): current raster 6.29, current classic RT 16.79, current PBR RT 11.65. Previous captures were 15.86/17.45 for classic/PBR RT, but used a lower RT trace resolution; this is a combined visual comparison, not an isolated performance or image-quality score for this patch. The stationary outer ring and correct center masks are directly visible. The rocket geometry remains intact.

q3dm17's near-black fraction in the fixed launchpad ROI is 5.41% raster and 5.36% RT, close to native's 5.43%. Before RGB/asset repair, corresponding prior captures had 40.09% classic raster and 63.04% RT. Near-black coverage measures the missing backing defect, not lighting parity.

Ranked remaining work (plus the iPhone MetalFX blocker above):

1. **Pad/lamp lighting and material response:** native pad ROI mean RGB is about (72.84,61.05,48.83), current raster (104.18,88.81,71.44), RT (111.45,89.76,70.42). Disabling direct RT lighting only changes RT to (110.18,88.73,69.63); the bright rim persists. Disabling emission removes the orange core but leaves the bright rim/stems. Therefore direct-light scale alone is not the main explanation. Next isolate lightmap energy, material/normal/specular response, and raster/RT composition using raw HDR and per-pass captures at a fixed atlas phase. Do not globally retune exposure from a differently lit YouTube frame.
2. **Verified column PBR:** obtain `textures/gothic_block/blocks18cgeomtrnx` with its transparent-center mask, emissive map, normal/roughness/metallic maps, and Remix material/animation metadata. Until then the stock Q3 layered fallback is intentional. Do not reuse the skull plaque or invent a white emissive core to resemble the screenshot.
3. **RT texture filtering:** current compute texture sampling lacks a ray-footprint LOD policy. High-frequency top and wall textures alias; full trace resolution improves sharpness but costs GPU time. Measure filtering and denoiser separately.
4. **RT pickup emissive overlays and sky/environment:** green ammo symbols still lose brightness in RT. Both current phone and Catalyst captures have a black sky compared with the foggy RTX video; match exported sky/fog configuration before attributing this difference to the platform. Neither appearance gap was fixed here.
5. **Other missing assets outside the repaired pad set:** `models/mapobjects/teleporter/energy3` (`FEACD498CB74F58C` albedo/emissive/normal/height), `models/mapobjects/bitch/hologirl` (`FF05DC1E2FA903D1`), and unresolved environment-capture routing merit a separate asset sweep. No additional q3dm17 launchpad atlas files are needed from the user for this patch.

Would another engineer notice before/after? **Yes**: the column's outer panel stays intact, the skull is gone, and the launchpad floor backing is restored. The lighting mismatch remains visible and is explicitly not accepted as RTX parity.

## Reproduction and implementation review

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun xcodebuild \
  -project Quake3-iOS.xcodeproj -scheme Quake3-iOS -configuration Debug \
  -destination 'platform=macOS,variant=Mac Catalyst' \
  -derivedDataPath /Volumes/iOS/Quake_Review_20260920/demo4_fix/build \
  PRODUCT_BUNDLE_IDENTIFIER=com.quake3ios.logicaudit20260920 \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES build
python3 scripts/check_metal_uniform_layout.py
python3 scripts/repair_q3_comparison_assets.py \
  --pbr Resources/baseq3/pbr --export /Volumes/iOS/Projects/export_for_mac/textures_dds
```

Exact launch environments, executable hashes, capture commands and timestamps are in `R/final-binary.json`, `R/final_runs.py`, `R/capture_gpu_scene.py` and each run's `launch.json` / `manifest.json` under `/Volumes/iOS/Quake_Review_20260920/raster_logic/runs`. GPU captures are large and stay outside Git.

The requested LM Studio/Qwen coder was smoke-tested on a small Swift patch, applied only after exact-match checks, and compiled/run. Its proposed renderer edits were reviewed before use; an incorrect record/texture-slot bound and a float bitwise expression were corrected. Prompts and accepted/rejected output remain in `R/lm`. Claude Opus `--effort max` was also invoked for independent review.

Claude did not return a review after two attempts (about 20 minutes initially, then over 11 minutes with strict MCP configuration); both stalled invocations were terminated. No Claude approval is claimed. Local-model output was manually reviewed, compiled, and checked against GPU evidence; independent Claude review remains unavailable. Logs: `R/claude-review*.json` / `.stderr`.

Relevant ddemby searches used `projects/quake3-metal-port/work/verdicts`: column layer/atlas fallback and q3dm17 missing DDS; reformulated lookup for `sprite_sheet_cols`/bad material matches; and `TextureNeedsLuminanceAlpha`/radial JPG masking. Historical atlas and incorrect-material results were useful context; the alpha search was irrelevant, so implementation and asset-source evidence determined that fix. Phone follow-up retrieval found useful earlier Catalyst-versus-iPhone MetalFX backend policy; container-path retrieval was only indirectly relevant, so the fresh device log supplied the actual UUID. Earlier rigid q3dm1-only acceptance instructions were superseded by the user's explicit q3dm6/q3dm17 demo scope.

The primary project’s pre-existing Swift edits for MTL4 residency and lazy sidecars remain uncommitted, including both normal-map gates at the overlapping hunk. `R/main-user-before.patch` and `R/main-user-preserved.patch` record that preservation. Published changes come from the clean audit checkout.
