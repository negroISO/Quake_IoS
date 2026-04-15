# Quake3-iOS

<!-- AUTO-MANAGED: project-description -->
Native iOS port of Quake 3 Arena using Metal rendering. SwiftUI app shell wrapping an MTKView-based renderer that bridges to C/C++ engine code via a bridging header.
<!-- END AUTO-MANAGED -->

<!-- AUTO-MANAGED: architecture -->
## Architecture

```
Quake3-iOS/
├── Quake3_iOSApp.swift              # @main SwiftUI entry point
├── MetalView.swift                  # MTKView wrapper + inline MSL shaders
├── Quake3-iOS-Bridging-Header.h     # C/C++ bridge
├── Info.plist
code/                                # C/C++ Quake 3 engine source
baseq3/                              # Game assets
Resources/
```

**MetalView.swift** is the core renderer. It contains:
- `MetalView`: `UIViewRepresentable` wrapping `MTKView`
- `Coordinator`: `MTKViewDelegate` holding GPU structs and inline MSL shader source
- Three render pipelines: UI (`q3_ui_*`), World (`q3_world_*`), Entity (`q3_entity_*`)
<!-- END AUTO-MANAGED -->

<!-- AUTO-MANAGED: conventions -->
## Conventions

- Inline MSL shaders compiled at runtime from `shaderSource` string in `Coordinator`
- GPU vertex structs mirror MSL counterparts: `GPUVertex`, `GPUWorldVertex`, `GPUEntityVertex`
- Uniform structs: `Uniforms`, `WorldUniforms`, `WorldDrawUniforms`, `EntityUniforms`
- MTKView configured: `bgra8Unorm` color, `depth32Float` depth, display-rate FPS, continuous rendering (`isPaused = false`)
<!-- END AUTO-MANAGED -->

<!-- AUTO-MANAGED: patterns -->
## Patterns

- **World debug modes**: `worldDebugMode` static `Float` on `Coordinator` (default `0`). Values: `0`=normal, `1`=base texture only, `2`=lightmap only, `3`=UV1 visualization, `4`=vertex color only. Change at compile time to diagnose rendering issues.
- **Alpha-test**: NOT applied globally in the world fragment shader. Q3 `alphaFunc` is per-shader-stage opt-in. Alpha-tested stages must be driven by the Q3 shader parser, not a global `discard_fragment()` call. Unconditional discard causes transparent geometry on surfaces whose stage0 texture falls back to white.
- **Entity pipeline diagnostics**: `RE_ClearScene` resets four per-frame counters (`s_entityAcceptedThisFrame`, `s_entityRejectedNullThisFrame`, `s_entityRejectedTypeThisFrame`, `s_entityRejectedModelThisFrame`) and increments `s_clearSceneCalls`. `RE_AddRefEntityToScene` increments `s_rawEntryCount` unconditionally (even for null/invalid). `RE_RenderScene` increments `s_renderSceneCalls` and logs the per-frame accept/reject counts every `s_sceneLogCounter` interval, plus the first accepted entity's origin/axis/renderfx/hModel/reType. Use `s_clearSceneCalls`/`s_renderSceneCalls`/`s_rawEntryCount` to detect if cgame is submitting at all vs. the pipeline rejecting.
- **Tag-only MD3s**: `LoadMD3ModelData` accepts `numSurfaces == 0` (changed from `< 1` to `< 0`). Models with only tags and no renderable surfaces are valid (e.g., attachment point markers).
- **Optional model path logging**: `TryRegisterModelPath` logs missing pk3 files at `PRINT_DEVELOPER` (not `PRINT_WARNING`). Missing optional paths are expected; only log at warning level for true failures.
- **Synthetic first-person viewmodel**: `SynthesizeViewmodelEntity` (in `metal_renderer_stub.c`) appends its own viewmodel entity to `s_sceneEntities[]` each `RE_RenderScene`, independent of cgame. `GetViewmodelHandle(int weapon)` maps `weapon_t` index (0=WP_NONE … 10=WP_GRAPPLING_HOOK) to an MD3 path; models are lazily registered via `RE_RegisterModel` and cached in `s_viewmodelHandles[16]` (padded past WP_NUM_WEAPONS=11 for safety). Origin = `vieworg + kForward*70 - kRight*18 + kUp*(-24)` plus `cls.realtime`-driven sway; uniform scale faked via `VectorScale(axis, kScale=0.7)`; `renderfx |= RF_DEPTHHACK`. `metalSceneEntity_t.isSynthetic` is `qtrue` for injected viewmodel, `qfalse` for cgame entities. **cgame entities are NOT suppressed** — they render normally alongside the synthetic viewmodel. (Earlier diagnostic instrumentation revealed cgame submits entities correctly; an earlier `!isSynthetic` skip was reverted after it was identified as a false fix.)
- **Entity depth-hack**: `MetalView.swift` keeps two entity depth-stencil states: `depthStencilState` (`.lessEqual`, default) and `depthHackDepthStencilState` (`.always`, depth write on). Per-draw entity loop switches state based on `draw.flags & Q3_METAL_ENTITY_DRAWFLAG_DEPTHHACK`. Used so the first-person viewmodel never gets occluded by world geometry while still self-occluding correctly.
- **World-scene state preservation** (THREE-PART, permanent architectural pattern): cgame calls `RE_ClearScene` before every scene in a frame — world scene, then each HUD/2D scene. This means ClearScene fires N times per rendered frame, not once. All three parts below must stay coherent; reverting any one causes render breakage.
  1. **`RE_ClearScene` does NOT reset `s_entityVertexCount`/`s_entityIndexCount`/`s_entityDrawCount`**. It still resets `s_sceneEntityCount` and the per-scene accept/reject counters. Rationale: resetting draw buffer counts in ClearScene wiped the world scene's built geometry before the subsequent HUD scenes' `RE_RenderScene` ran, producing nothing to draw.
  2. **In `RE_RenderScene`, the `s_entity{Vertex,Index,Draw}Count = 0` resets and the `if (s_sceneEntityCount > 0) { ... build loop ... }` block are both gated on `fd->rdflags == 0`**. Only world scenes (rdflags 0) rebuild the entity buffers; HUD scenes retain the previous world buffer intact.
  3. **In `RE_RenderScene`, the `s_sceneView` write-out (fovX/fovY/viewOrigin/viewAxis) is also gated on `fd->rdflags == 0`**. Required because preserving world entity draws is useless if sceneView is still overwritten by a HUD camera — world-space coordinates would project off-screen. Regression history: parts 2+3 alone caused all-invisible because ClearScene's buffer-count resets still ran between scenes.

<!-- END AUTO-MANAGED -->

<!-- AUTO-MANAGED: git-insights -->
## Key Decisions (from git history)

- `37bea83` — Removed unconditional `discard_fragment()` from world fragment shader. Per-stage alpha-test will be reintroduced via Q3 shader parser.
- `ff20ac2` — Added 5-mode world render debug system (`worldDebugMode`).
- `ef21f24` — Depth compare set to `LEQUAL`; alpha-test discard added (later reverted in 37bea83).
- `ec2c16f` — Single drawable present path per frame to avoid double-present artifacts.
- `fa745fe` — Fallback depth-stencil state added to prevent nil bind crashes.
- `c348982` — LoadMD3ModelData gains null/size guards and verbose per-rejection diagnostic logs (file size, offsets, surface indices).
- `760e106` — `RegisterTexture` dedup ring (256-entry static ring, zero-overhead on repeat calls): each unique shader/texture name printed once to console. Reveals which Q3 shaders a map actually loads; feeds scope decision for shader parser.
- `8715dc7` — Extension-agnostic asset lookup in Metal stub (strips extension before searching pk3).
- `cd13e18` — Tag-only MD3s accepted (`numSurfaces >= 0`); optional model misses downgraded to PRINT_DEVELOPER.
- `43fd957` — Entity pipeline diagnostics added: per-frame accept/reject counters (`s_entityAcceptedThisFrame`, `s_entityRejectedNullThisFrame`, etc.) logged in RE_RenderScene; `s_clearSceneCalls`/`s_renderSceneCalls` track call frequency.
- `d8a4666` — First queued entity transform (origin, axis, renderfx, hModel) logged each diagnostics interval; `s_clearSceneCalls`, `s_renderSceneCalls`, `s_rawEntryCount` counters added for call-frequency and raw submission tracking. `metalSceneEntity_t.isSynthetic` field added to distinguish injected viewmodel from cgame-submitted entities. `s_viewmodelHandles[16]` caches lazily-registered weapon MD3s by `weapon_t` index.
- **World-scene state preservation (three-part fix)** — `RE_ClearScene` no longer resets `s_entityVertexCount`/`s_entityIndexCount`/`s_entityDrawCount` (part 1). In `RE_RenderScene`, both the buffer-count resets + entity build loop (part 2) and the `s_sceneView` camera write-out (part 3) are gated on `fd->rdflags == 0`. Rationale: cgame fires ClearScene once per 3D scene and once per HUD scene each frame; the old code wiped the world's built geometry and camera before HUD's RenderScene ran. Parts 2+3 alone (without part 1) still regressed to all-invisible because ClearScene's resets erased the buffer counts between scenes. All three parts are load-bearing.
<!-- END AUTO-MANAGED -->
