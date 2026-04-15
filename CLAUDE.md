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
- **Entity pipeline diagnostics**: `RE_ClearScene` resets four per-frame counters (`s_entityAcceptedThisFrame`, `s_entityRejectedNullThisFrame`, `s_entityRejectedTypeThisFrame`, `s_entityRejectedModelThisFrame`) and increments `s_clearSceneCalls`. `RE_AddRefEntityToScene` increments `s_rawEntryCount` unconditionally (even for null/invalid). `RE_RenderScene` increments `s_renderSceneCalls` and logs the per-frame accept/reject counts every `s_sceneLogCounter` interval, plus the first accepted entity's origin/axis/renderfx/hModel/reType. Use `s_clearSceneCalls`/`s_renderSceneCalls`/`s_rawEntryCount` to detect if cgame is submitting at all vs. the pipeline rejecting. **Cumulative counters** (`[snapshot-syscall-diag]`, short-lived): `s_acceptedCumulative`, `s_rejectNullCumulative`, `s_rejectTypeCumulative`, `s_rejectModelCumulative` increment alongside the per-frame counters in `RE_AddRefEntityToScene` but are NOT reset by `RE_ClearScene` — they reset only when the 60-frame log fires. Rationale: observed `s_clearSceneCalls` (63) > `s_renderSceneCalls` (60), meaning `ClearScene` fires more than once per rendered frame (one pass per 3D scene + one for HUD/2D). The per-frame counters only capture the LAST scene in the frame, masking true submission volume; the cumulative counters expose accurate per-60-frame totals. Log line includes `cum_accepted cum_rejN cum_rejT cum_rejM`. Remove with all other `[DBG]` instrumentation when root cause is identified. **Multi-scene trace** (`[snapshot-syscall-diag]`, short-lived): `RE_RenderScene` also logs `[DBG] RE_RenderScene #N rdflags=0xX sceneEntities=Y accepted=Z rawSoFar=R` for the first 120 invocations (~2s). Static counter `s_renderSceneTrace` increments unconditionally; `rawSoFar` is `s_rawEntryCount` at the moment of the call (cumulative across all scenes in the session). Purpose: confirm how many `RE_RenderScene` calls occur per cgame frame and what `rdflags` each carries — hypothesis is 3D world scene (rdflags with `RDF_NOWORLDMODEL` clear) followed by HUD/2D scene (`RDF_NOWORLDMODEL` set); also reveals which scene index contains pickup/item entities. HUD-overwrites-world theory already ruled out (user confirmed world + viewmodel render correctly). Remove with all other `[snapshot-syscall-diag]` blocks.
- **Tag-only MD3s**: `LoadMD3ModelData` accepts `numSurfaces == 0` (changed from `< 1` to `< 0`). Models with only tags and no renderable surfaces are valid (e.g., attachment point markers).
- **Optional model path logging**: `TryRegisterModelPath` logs missing pk3 files at `PRINT_DEVELOPER` (not `PRINT_WARNING`). Missing optional paths are expected; only log at warning level for true failures.
- **Synthetic first-person viewmodel**: `SynthesizeViewmodelEntity` (in `metal_renderer_stub.c`) appends its own viewmodel entity to `s_sceneEntities[]` each `RE_RenderScene`, independent of cgame. `GetViewmodelHandle(int weapon)` maps `weapon_t` index (0=WP_NONE … 10=WP_GRAPPLING_HOOK) to an MD3 path; models are lazily registered via `RE_RegisterModel` and cached in `s_viewmodelHandles[16]` (padded past WP_NUM_WEAPONS=11 for safety). Origin = `vieworg + kForward*70 - kRight*18 + kUp*(-24)` plus `cls.realtime`-driven sway; uniform scale faked via `VectorScale(axis, kScale=0.7)`; `renderfx |= RF_DEPTHHACK`. `metalSceneEntity_t.isSynthetic` is `qtrue` for injected viewmodel, `qfalse` for cgame entities. **cgame entities are NOT suppressed** — they render normally alongside the synthetic viewmodel. (Earlier diagnostic instrumentation revealed cgame submits entities correctly; an earlier `!isSynthetic` skip was reverted after it was identified as a false fix.)
- **Entity depth-hack**: `MetalView.swift` keeps two entity depth-stencil states: `depthStencilState` (`.lessEqual`, default) and `depthHackDepthStencilState` (`.always`, depth write on). Per-draw entity loop switches state based on `draw.flags & Q3_METAL_ENTITY_DRAWFLAG_DEPTHHACK`. Used so the first-person viewmodel never gets occluded by world geometry while still self-occluding correctly.
- **Snapshot syscall diagnostics (short-lived)**: `[DBG]` instrumentation blocks spanning `cl_cgame.c` and `MetalView.swift`, same investigation — remove all together when concluded. (1) `CL_GetCurrentSnapshotNumber`: static `lastMsgNum` tracks `cl.snap.messageNum` advances and fires `Com_Printf("[DBG] CL_GetCurrentSnapshotNumber: msgNum=%d serverTime=%d valid=%d\n", ...)`. Static counters `s_cgCallGetSnapshot` and `s_cgLastSnapshot*` family (valid flag, numEntities, first-3-entity num/type/flags/modelindex/origin) recorded by `CL_GetSnapshot` for post-mortem inspection. Purpose: diagnose why cgame never calls `CG_GETSNAPSHOT` (`getSnapshot=0` in all `[cgame syscalls]` logs) despite `cl.snap` populating correctly. (2) `CG_R_ADDREFENTITYTOSCENE` case (~line 648): logs up to the first 30 refEntity submissions per 60-frame window — reType, hModel, renderfx, origin. Purpose: determine whether cgame.qvm submits pickup/item refEntities with real world coords (e.g. `(932, 1348, 16)`) or only the player's sarge/head.md3 at `(-1.8, 0, 0.6)`. (5) `MetalView.swift` entity-draw loop counters (`[snapshot-syscall-diag]`, short-lived): `nonisolated(unsafe) private static var entityDrawLogCounter: UInt32` on `Coordinator` (line 60) drives a 60-frame log gate. Inside `Coordinator.draw(in:)` entity-draw loop (around lines 384–412): `dbgDrawn`, `dbgSkippedNoTexture`, `dbgSkippedZeroIndex` count outcomes per frame; every 60 frames prints `[DBG] entityDraws total=N drawn=D skipZeroIdx=Z skipNoTex=T`. Purpose: identify whether pickup entity draw-commands are silently dropped when `texture(for: draw.textureHandle)` returns nil (the `continue` path) — hypothesis is pickup textures fail to resolve while viewmodel/world textures succeed. Remove with all other `[snapshot-syscall-diag]` blocks.
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
- `[snapshot-syscall-diag]` — Temporary `[DBG]` blocks spanning `cl_cgame.c`, `metal_renderer_stub.c`, and `MetalView.swift`, same investigation. (1) `CL_GetCurrentSnapshotNumber`: instrumentation + `s_cgCallGetSnapshot`/`s_cgLastSnapshot*` counters — diagnosing `getSnapshot=0` in all `[cgame syscalls]` logs despite `cl.snap` being populated. (2) `CG_R_ADDREFENTITYTOSCENE` (~line 648): logs first 30 refEntity submissions per 60-frame window (reType, hModel, renderfx, origin). (3) `metal_renderer_stub.c`: four cumulative accept/reject counters (`s_acceptedCumulative` etc.) expose true per-60-frame entity totals masked by multi-ClearScene-per-frame. (4) `RE_RenderScene` multi-scene trace: `s_renderSceneTrace` counter + `[DBG] RE_RenderScene #N rdflags=0xX sceneEntities=Y accepted=Z rawSoFar=R` log for first 120 calls (~2s) — confirms scene count per cgame frame, rdflags per scene (3D vs. HUD/2D), and which scene index carries pickup/item entities. (5) `MetalView.swift` `Coordinator.draw(in:)` entity-draw loop: `entityDrawLogCounter` (static `UInt32`) gates a 60-frame log; per-loop counters `dbgDrawn`/`dbgSkippedNoTexture`/`dbgSkippedZeroIndex` classify each draw-command outcome; prints `[DBG] entityDraws total=N drawn=D skipZeroIdx=Z skipNoTex=T`. Hypothesis: pickup textures fail `texture(for:)` resolution causing silent `continue` skips while viewmodel/world textures succeed. Remove all blocks once root cause is found.
<!-- END AUTO-MANAGED -->
