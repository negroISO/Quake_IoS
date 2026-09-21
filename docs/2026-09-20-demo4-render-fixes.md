# Demo4 rendering repairs — Catalyst verification, 2026-09-20

The rocket launcher now self-occludes in RT, and q3dm6's column shader retains its authored opaque underlay. The PBR master switch gates cached materials, texture replacements, sprite atlases, normal shading and readability floors; RT material buffers and their texture-slot routing rebuild together when it changes. The previously verified Swift/MSL uniform-layout and entity scene-clock repairs are included. Rocket origin and axes match the Vulkan reference within 0.00013 world units and 0.00000481 respectively at the audited frame; no geometry scaling change was needed.

The weapon repair has two necessary parts: remove the RT-only Always/no-depth-write override, and preserve native world depth across the world→RT→entity encoder boundary on **every RT map**. Previously, persistent depth was requested only for fog. The first candidate removed the override alone; its RT screenshot lost the weapon, so that candidate was rejected. Final opaque weapon draws use the existing LessEqual/write-enabled state and compressed 0–0.3 viewport depth range. HUD depth behavior remains separate.

The column fix removes the C stage-elision rule that discarded opaque ONE/ZERO effect underlays when a structural PBR owner existed. Texture ownership does not change whole-shader coverage. Blended overlays retain their authored blend/depth behavior; no global alpha-discard or forced-opaque ray-intersection hint was added.

**Reproduction and identity**

- Source baseline: `fd646fff23f83f53c4aad53bb30ac7ee3ffdad70`, branch `metal-renderer-fresh`.
- Fixture: pak8 `demos/four.dm_68`, map `q3dm6`, `fixedtime 50`, frames 260/270/280/290/300 (12.95–14.95 seconds after the first tick).
- Frame 300: scene time 1071700 ms, camera (-1325.70789, -451.149292, 610.113525), FOV 90 × 73.7397919, rocket launcher selected, airborne. Output 1280×960; RT 435×326, legacy denoiser, frame interpolation off.
- Reference: local Quake3e Vulkan/MoltenVK build `5d12c8eecf8e0b0607ff3502a50f76b3609fac7b`, same assets/demo and pose. This is not a new Windows/PC hardware run.
- Tested a clean worktree plus this patch. Pre-existing local RT/sidecar edits in the primary checkout were preserved and excluded from this commit. Game/PBR assets were staged from the existing comparison bundle and are not part of the commit.

**Verification**

| Check | Result |
|---|---|
| Final production Catalyst build | Passed; diagnostic instrumentation removed |
| Final raster and PBR RT demo4 smoke runs | Five frames each; no detected API/shader-validation faults |
| Classic RT and PBR raster controls | Five target frames each; no detected validation faults |
| GPU captures | Four completed single-frame documents: raster, RT classic, RT PBR, RT after PBR toggle; command buffer status completed/error nil |
| Column GPU output | Raw pre-denoise RGBA16Float readback: 5×5 samples around output pixel (430,630), RT pixel (146,213), alpha min/max/mean = 1.0 in both RT modes; finite output |
| RT column material assignment | Restored underlay assigned blend 0 and material flags (0,0,0,0) to the audited column primitives |
| Rocket submission at frame 300 | Both 747- and 468-index surfaces encoded in opaque pass, depth-hack enabled, shader time 1071.7 |
| PBR off→on→off during demo | Raster weapon interior identical; whole-image RGB MAE 0.0000011/255. RT buffers rebuilt on transitions; RT output is not pixel-identical |
| Entity draw accounting | No unexplained omitted commands in any of the four frame-300 capture logs; 7 expected third-person exclusions per frame |
| nv15 machinegun/quad control | Frames 419/420 captured; frame 420 has 445 emitted commands = 431 encoded + 14 expected exclusions; no negative entity shader times |
| q3dm4 fog control | Frame 120 captured with validation enabled |
| q3dm1 PBR RT smoke | Captured at setviewpos 216 1328 64 0; no validation faults; limited viewpoint coverage |
| GPU uniform-layout sentinel | Zero failed structs, using actual Swift/MSL fields |
| Scene-clock probe | ASan/UBSan pass: demo effect age 0.0500000007 s; independent HUD scene age 0.25 s |

Xcode window automation returned `cgWindowNotFound`, including after reconnect and a fresh Xcode instance. **This pass did not complete Xcode replay/inspector verification of the saved captures.** The evidence above consists of completed capture documents, instrumented submissions, raw GPU readbacks, source state contracts, and rendered images. It must not be described as a successful Xcode replay or as independently inspected GPU depth-state values.

The diagnostic and final production builds contain identical inline shader literals. The final source differs from the traced renderer only by removal of diagnostic code and two indentation corrections. Final raster frame 300 differs from its diagnostic capture by only 0.0000011/255 RGB MAE. RT production-versus-diagnostic frame differences range from 1.786 to 13.428/255 across the five frames (3.536 at frame 300). RT sampling and material-atlas animation retain their existing monotonic clocks; pixel-identical RT replay is not established. The RT off→on→off control differed by 5.048/255 whole-image RGB MAE; its material-buffer refreshes and draw accounting passed, but this is not proof of pixel-level RT toggle equivalence. No performance improvement is claimed from fixed-time, validation-enabled runs.

In the frame-300 comparison images, classic raster whole-image RGB MAE versus Vulkan fell from 23.848 to 13.342/255; the column rectangle fell from 23.633 to 6.758/255. The RT PBR whole-image error changed from 8.911 to 11.283/255: the repaired, solid weapon is still brighter than the reference. Rectangular metrics include background and differing intended PBR/RT shading; acceptance of the geometry/opacity repair also requires the image and coverage evidence.

**Evidence on the review Mac**

`/Volumes/iOS/Quake_Review_20260920/demo4_fix/` contains the final contact sheet, before/after crops, image metrics, raw RT alpha results, source/shader identity hashes, draw ledgers, build logs, test logs, local-model patch smoke checks and review records. `capture-index.json` records paths and UUIDs for all four traces in the Catalyst app's Documents directory. Run manifests and frames are under `/Volumes/iOS/Quake_Review_20260920/raster_logic/runs/`, using `catalyst-four-fix-reviewed-final-raster`, `catalyst-four-fix-reviewed-final-rt`, and the `fix-reviewed-gpu-*` run names.

Build command:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun xcodebuild \
  -project Quake3-iOS.xcodeproj -scheme Quake3-iOS -configuration Debug \
  -destination 'platform=macOS,variant=Mac Catalyst' \
  -derivedDataPath /Volumes/iOS/Quake_Review_20260920/demo4_fix/build \
  PRODUCT_BUNDLE_IDENTIFIER=com.quake3ios.logicaudit20260920 \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES build
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer python3 scripts/check_metal_uniform_layout.py
```

Runs launch the app executable directly with `-ApplePersistenceIgnoreState YES`. The `capture_demo4.py`, `capture_gpu.py`, `run_reviewed_matrix.py`, `run_reviewed_final.py` and `run_reviewed_gpu.py` scripts in the evidence directory preserve the exact cvars/environment. GPU capture instrumentation is archived separately in `diagnostic-source`; it is not shipped.

**Remaining work, in order**

1. Replay the saved traces in Xcode when its window is accessible; inspect both rocket draws, the opaque column underlay, retained world depth and actual texture bindings. Repeat the corrected frame on iPhone; this repair pass is Catalyst-only.
2. Isolate classic entity lighting and shader-stage differences against Vulkan. Weapon brightness, some animated layer appearance and light effects still differ; visible rectangular effect layers in RT frame 260 also need isolation. Avoid compensating with a global exposure change.
3. Separate material animation time from RT random-sampling time before migrating atlas clocks; bind entity draw time before atlas selection. The extra atlas-clock change was removed during review. RT still selects one representative stage per primitive. With PBR off, the restored opaque animated underlay can dominate the column's appearance; full classic multilayer shader evaluation/baking in RT remains incomplete. Coverage is repaired, full material parity is not.
4. Audit independent Phase5/IBL feature gates and upscale/FI combinations separately. Native output and the legacy Catalyst denoiser were used here; this is not broad Metal4 or device certification.
5. Profile without validation/capture and with real-time playback. PBR enabling can stall for texture loads/material rebuilds (1.31 seconds observed on first enable); warming and scheduling this work is a performance follow-up.

Another engineer would notice the before/after change: **yes**, the RT rocket no longer exposes internal surfaces and the column no longer loses its opaque coverage. The remaining visual mismatches above are explicitly outside the acceptance claim.

Retrieval: ddemby verdict queries for weapon depth, column underlays and PBR gates returned mostly older/irrelevant reports after reformulation; source and existing capture evidence drove the fixes. A source query for `baseq3` staging found `scripts/stage_baseq3.sh` and resolved the clean-worktree launch failure. LM Studio returned a bounded candidate but two exact-source edits failed its patch smoke check; corrected edits were reviewed before application. Claude completed a maximum-effort review with no proven blockers. Follow-up source checks removed the extra atlas/RT clock migration and made PBR shading depend on material presence even when the normal map falls back to a flat texture. `REVIEW_RESOLUTION.md` records each follow-up and the retained review artifacts.
