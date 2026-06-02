# Q3 iOS Metal renderer — multi-session progress log

Capture of the 2026-05-30 → 2026-06-02 work on the Metal world renderer for
Quake3-iOS. Covers correctness fixes (lightmap, fog), performance wins
(pass-bucketing, PVS batching, ProMotion), infrastructure (trace + capture
helpers), and the open work queued for next session.

Source-of-truth conventions used here:
- "we" = pair work in this session (Claude / Codex / Negro)
- iPhone reference device: "Yd-Mubarak MajMaj" (iPhone 17 Pro Max, A19 Pro)
- iPad reference device: "Oled" (iPad Pro 13" M4) — both reachable via
  `xcrun devicectl ... --device "<name>"`
- Bundle id: `com.quake3ios.app`

---

## 1. Renderer correctness fixes

### 1a. Implicit lightmap pass for diffuse-only world surfaces (Bug 1)

**Root cause.** `metal_renderer_stub.c` defines `AddWorldDrawLightmapBaseStage`
at line ~1114 but **never calls it**. Stock Q3's `R_StageIteratorGeneric`
implicitly adds a `GL_DST_COLOR / GL_ZERO` lightmap-multiply pass on every
world surface whose `.shader` has only a diffuse stage (i.e. no explicit
`map $lightmap`). Without that pass our floor / wall surfaces render at
full diffuse brightness with zero shadowing — the q3dm4 "flat bright
rubble floor" symptom.

**Fix.** In `metal_renderer_stub.c`:
- Added `shaderHasExplicitLightmapStage(_e)` helper near line 1100.
- Added `shaderShouldInjectImplicitLightmap(_e)` heuristic that returns
  true ONLY when shader has no explicit lightmap stage AND all existing
  stages are opaque (`blendMode == 0`). This last clause prevents the
  implicit pass from over-darkening emissive ceiling fixtures, additive
  glow shaders, alpha-blended decals, etc.
- Inserted the injection at both world-emission sites (one around line
  4248 for patch surfaces, one around line ~4470 for planar/tri-soup)
  just before the post-stage fog-pass emit.
- Pre-allocation in `LoadWorldMap` now reserves one extra slot per
  surface that qualifies (`drawMultiplier += 1`). Without this, the
  malloc'd `s_world.draws[]` overflowed on first map load → SIGKILL
  during boot (this was caught and fixed mid-session).

**Visual verification.** Side-by-side renders against the Quake3e Vulkan
PC reference at iPhone-matched 960×444 confirmed:
- q3dm4 rubble floor now shows lightmap-darkened corners and dappled
  parallel sunlight bars on the corridor floor at t=22s — matches PC.
- Spawn-hall red panels desaturated from the over-saturated pink to PC-
  matching dim earth tones (Bug 2 "red saturation" was a SYMPTOM of
  Bug 1 — once lightmap multiply was active, the diffuse pink panels
  got the same dim modulation PC applies).

Status: shipped and stable across many sessions.

### 1b. Ceiling-light heuristic exclude

**Bug exposed by 1a.** After enabling the implicit lightmap pass, q3dm4
ceiling light fixtures rendered as overly bright halos because their
`.shader` declares additive glow stages on top of the diffuse base; our
naive injection added a `GL_DST_COLOR / GL_ZERO` pass that darkened the
intended fullbright emissive output.

**Fix.** `shaderShouldInjectImplicitLightmap` skips when any stage has
`blendMode != 0` (opaque). Light fixtures, sprites, decals, and
explosion overlays all carry non-opaque blendMode markers, so they
correctly bypass the implicit pass.

Status: shipped.

### 1c. Fog pipeline — FOG_OVERLAY → FOG_ONLY flag mismatch (Bug 3 fragment)

**Bug.** Swift's worldPass==5 (the fog pass) gated on
`(draw.flags & fogOverlayBit) != 0`, but the C-side post-stage fog
emission at line ~4309 (the regular case for surfaces inside a fog
volume) sets only `FOG_ONLY`, never `FOG_OVERLAY`. `FOG_OVERLAY` is set
only on the special "shader self-declares fogparms" path. Result: every
regular fog draw was silently dropped before reaching the GPU.

**Fix.** Swift line 1971 guard changed to `(draw.flags & fogOnlyBit) != 0`.

Status: shipped. Fog draws now reach the fragment shader.

### 1d. Fog math port from DeepSeek (Bug 3 math)

**Background.** The original fog factor was a depth-based
`sqrt(saturate(depth * tcScale))` quad that rendered as a flat white
overlay across whole surfaces. DeepSeek (from an earlier overscope
attempt) had drafted a faithful port of stock ioq3's
`RB_CalcFogTexCoords` + 256×32 fog image bilinear lookup. We rejected
the overscope diff but recovered the fog functions from
`/tmp/q3_deepseek_overscope.patch` and merged just those:
- `q3FogDirectFactor(s, t)` — analytic equivalent of stock R_FogFactor texels
- `q3FogImageFactor(s, t)` — 4-tap bilinear emulating the 256×32 LUT
- `Q3FogTexCoord` struct + `q3FogTexCoords` helper with the eye/surface
  plane logic and the **sign-flip on `fogSurface.w`** (vs the original
  port — ioq3 stores `fog.surface[3] = -plane.dist`, so a camera above
  q3dm4's low fog volume is treated as inside per the source convention)
- `q3FogFactor` glues it together

**Status:** the math works. Fog is visible at the top of the layer in
the user's q3dm4 screenshots from the iPhone 17 Pro Max. Codex's later
commits refined this further.

**Open math gap.** The `eyeT >= 0, t < 0` branch (eye above plane,
surface below — typical case for q3dm4's pit when viewed from above)
snaps `t = 1/32` which makes `q3FogImageFactor` return 0 → no visible
fog when looking DOWN into the pit from outside. From INSIDE the pit
(eyeT < 0), fog renders correctly (the magenta flood the user saw —
that IS q3dm4's authored `fogparms ( 1 0 1 ) 200` color).

### 1e. Build infrastructure — q_platform.h macro guards

`code/qcommon/q_platform.h` lines 110 and 134 unconditionally `#define
DLL_EXT ".so"` and `#define ARCH_STRING "aarch64"`. Xcode's
GCC_PREPROCESSOR_DEFINITIONS already provides both, so every compile
fired ~232 "macro redefined" warnings. Wrapped both in `#ifndef` guards.
Also: msg.c:55 `//<- in bits` looked like a malformed Doxygen tag to
clang — stripped the `<-`. And added `@MainActor` to
`MetalView.swift::preferredDrawableSize()` for Swift 6 strict
concurrency. After all three: build warnings dropped from 244 to 7;
adding `-Wno-comma -Wno-unreachable-code` to `OTHER_CFLAGS` drives it
to 0 errors / 1 informational (`AppIntents SSU skipped`).

Status: shipped.

---

## 2. Performance work

### 2a. Pass-bucketing — commit `9af65ef Bucket world draws by render pass`

**Bug.** The 6-pass world encode loop in `MetalView.swift` iterated all
`worldDraws` six times, filtering each pass with `guard drawPass ==
worldPass else { continue }`. For nv15demo's 74,505 draws that's
**447,030 outer iterations per frame**, with ~85% skipped. Even the
skip cost mounted.

**Fix.** Pre-bucket draws into `worldDrawIndicesByPass[6]: [[Int]]` once
per frame in a single linear pass over `worldDraws`. The 6-pass loop
then iterates only the relevant indices for each pass.

**Measured wins (iPhone 17 Pro Max):**
| | before | after | Δ |
|---|---|---|---|
| q3dm4 p50 | 19.0 ms | 11.1 ms | −41.8% |
| q3dm4 max | ~30 ms | 15.4 ms | hitches gone |
| nv15demo p50 | 315 ms | 169 ms | −46.3% |
| nv15demo fps | 3.0 | 4.92 | +64% |

Status: shipped in commit `9af65ef`.

### 2b. Codex overnight commits

Run-stamped overnight on 2026-05-31 / 2026-06-01, Codex shipped:
- `5515f86` Checkpoint Q3 Metal PVS batching and fog perf
  (+1653 / −434 across MetalView.swift, metal_renderer_shared.h,
  metal_renderer_stub.c)
- `0c30332` Enable ProMotion frame pacing for Q3 Metal
- `ffcbaf4` Fix ProMotion drawable pacing stalls
- `a99a4c6` Fix Q3 fog volume gating and VM call ABI
- `080fbc4` Tune Q3 fog volume and dlight falloff
- `2e1e6fc` Fix Q3 tcMod rotate units
- `56c9ed9` Fix Q3 fog ray-box pipeline validation
- `7a5aa20` Fix Q3 entity fragment uniform bindings
- `8ac1664` Gate Q3 fog ray-box to inside volume
- `dcccc6b` Clear drawable before Q3 render pass
- `49fc8b2` Fog Q3 flare additive pass before UI
- `f0b36ac` Clamp Q3 additive texture samples for trace artifact
- `8a2d161` Visual polish: brightness, postprocess, per-stage wrap,
  quad shell deform

The 5515f86 checkpoint includes PVS batching, which is the same
architectural fix Claude analysis pointed at — visible in the per-commit
diffs.

### 2c. Failed DeepSeek perf rewrite attempt

DeepSeek was dispatched with a brief that excluded the obvious
architectural fix (3-stage merge / 1-draw-per-surface) on the theory that
ring buffers + state coalescing would carry the day on top of our
1-draw-per-stage architecture. The resulting changes:
- Ring buffer for per-draw 512-byte WorldDrawUniforms (3-deep rotation)
- `lastPipelineId` / `lastDepthStateId` ObjectIdentifier coalescing
- One trace-artifact bug fix (duplicate `encoder.setCullMode` at fog
  draws)

**Measured outcome:** q3dm4 REGRESSED 37 fps → 21.5 fps, nv15 unchanged
at 3 fps. The state was already mostly coalesced by surface-emission
ordering and the ring buffer added more overhead than the uniform-copy
elimination saved at our draw volume.

Reverted in-session; patch preserved at
`/tmp/q3_deepseek_perf_attempt.patch` for future reference. Cost burned:
~$8 in DeepSeek calls.

Lesson recorded in `docs/perf-roadmap-pvs-culling.md`: the real
bottleneck on nv15 is **rendering the entire baked BSP every frame**
because `R_inPVS` is stubbed `return qfalse` and `LUMP_VISIBILITY` is
never parsed. Both reference Q3 renderers (ioquake3 `tr_world.c`,
Quake3e renderervk) cull ~90-95% of world surfaces via PVS+frustum BEFORE
encoding. That work is the next-session target.

### 2d. ProMotion 120 Hz / pacing stalls

Codex's `0c30332` + `ffcbaf4` enabled 120 Hz with proper drawable pacing.
Confirmed working on iPhone 17 Pro Max — frame loop now genuinely hits
120 Hz on q3dm4. Required both the Info.plist
`CADisableMinimumFrameDurationOnPhone: true` key and the
`CADisplayLink.preferredFrameRateRange` `(min: 30, preferred: 120,
maximum: 120)` setting from the MetalView side. Without both, iOS
silently caps at 60 Hz.

---

## 3. Trace + capture infrastructure

### 3a. `scripts/q3_iphone_demo_avi.sh` (iOS device captures)

Combined xctrace Metal System Trace + Q3's built-in `video` AVI recorder
into one command:
```
scripts/q3_iphone_demo_avi.sh demo:q3dm4 30      # demo at 30s
DEVICE=ipad scripts/q3_iphone_demo_avi.sh demo:nv15demo 25
```
Outputs to `/tmp/q3_trace/q3iphone_<map>_<HHMMSS>.{trace,avi,log}`. The
script handles the iOS 26.5 + Xcode 26 `xctrace --launch` regression by
first launching via `devicectl process launch` to get a PID, then
attaching via `xctrace record --attach <PID>`. Requires the demo target
to exist at `Documents/baseq3/demos/<name>.dm_68` on the device.

### 3b. `scripts/q3_macos_pc_capture.sh` (Quake3e Vulkan PC reference)

Drives Quake3e on macOS through a pseudo-terminal (via `expect spawn`)
so commands can be injected after the engine reaches the main menu. The
earlier approaches all failed:
- `+exec foo.cfg` from cmdline silently routed errors to in-app tty
- `+set autoaction "..." + +vstr autoaction` lost quotes when Q3 joined
  argv[] back into a single cmdline string
- `baseq3/autoexec.cfg` execs DURING `Com_Init`'s early Cbuf_Execute,
  before `CL_Init` registers the `demo` command — gives "Unknown
  command 'demo'"
- A `<` fifo redirect on stdin failed Quake3e's `isatty(stdin)` check
  with "stdin is not a tty, tty console mode failed"
- The pty allocation via `expect spawn` finally passes the isatty
  check; `send "demo q3dm4\r"` then works exactly like a human typing

Records both AVI (via Q3's `video` command in demo state) and the
Quake3e console log. Pulls the AVI to `/tmp/q3_trace/q3dm4_pc_*.avi`.
Resolution mode selectable via `RES=iphone` (960×444 to match iOS)
or `RES=native` (desktop) or `RES=WxH`.

### 3b'. Comparable Q2 capture helper

`scripts/q2_iphone_demo_avi.sh` was previously added to the Q2 project
(`/Users/targus/Documents/Q2_too_ios/scripts/`) as a parallel — uses
Q2IOS_EXTRA_ARGS env via devicectl, supports `DEVICE=iphone|ipad|sim`.
Q2 has no built-in AVI recorder so the sim path uses
`xcrun simctl io recordVideo` for screen video; device path is
trace-only.

### 3c. Frame-comparison workflow

Process used throughout the session:
1. Capture matched-resolution iOS + PC AVIs of the same demo
2. Extract 6 frames at t=2/6/10/14/18/22s via `ffmpeg -ss ... -frames:v 1`
3. Scale PC frames to iOS dimensions (965×442 — iOS MJPEG encoder rounds
   the 960×444 source slightly)
4. `hstack` filter for side-by-side; read into agent via Read tool
   (multimodal vision)
5. Manual visual diff for lightmap shading, fog, color saturation,
   detail layers

This loop was the key diagnostic tool — let us catch issues like the
ceiling-light over-darkening without GPU traces.

---

## 4. Open infrastructure / future work

### 4a. PVS + frustum culling (documented in `docs/perf-roadmap-pvs-culling.md`)

The single biggest remaining perf lever. ~200 lines of focused C in
`metal_renderer_stub.c`:
1. Parse `LUMP_VISIBILITY` (raw bitsets — Q3 format, NOT Quake2-style
   RLE) — or use existing `ri.CM_ClusterPVS` if available
2. Build `s_world.surfaceDrawRanges[surfIdx] = {firstDraw, drawCount}`
   table at end of world load
3. Allocate `s_world.visibleDraws[]` once, worst-case sized to drawCount
4. `PointInLeaf(viewOrigin)` walking `s_bspWorld.nodes`
5. `R_MarkLeaves` using persistent `visCount` stamp (NOT frame number —
   same-cluster skip breaks if the stamp resets)
6. `R_RecursiveWorldNode` with frustum plane bits + leaf surface
   collection
7. Compaction step writes visible draws contiguously into
   `s_world.visibleDraws[]`
8. `Q3MetalRenderer_GetWorldDrawCommands` returns visibleDraws when
   visibleDrawCount > 0, fallback to s_world.draws; snapshot count
   reflects the active source. **Critical**: do NOT change just the
   count without compacting — that would render the first N static
   draws instead of the visible set.

Expected impact: nv15 worldCommandCount 74,505 → ~5,000-9,000, CPU
encode 169ms → ~20-30ms, **fps 5 → 30+**.

Two DeepSeek attempts at this implementation died at `max_turns=30` and
made only struct-field scaffolding ($8 burned). Approach for next
session: implement manually in 8-10 focused Edit calls with build
verification after each step.

### 4b. Fog math eye-above-plane case

When `eyeT >= 0` and `t < 0` (camera outside pit volume, surface inside
pit), current code snaps `t = 1/32` → `q3FogImageFactor → 0` → no fog
visible from above. Stock Q3 renders a soft haze on those surfaces.
Likely fix: compute proper line-of-sight `t` for this case, mirroring the
inverse-eye branch but with sign flipped. Codex's `8ac1664` commit "Gate
Q3 fog ray-box to inside volume" may already address this — needs visual
verification on q3dm4 from-above viewpoint.

### 4c. Sampler `clampmap` directive routing

Codex shipped `f0b36ac` and `8a2d161` which include "per-stage wrap"
work — the architectural fix for honoring `bundle.wrapClampMode`. Three
known sampler bind sites remain to verify against the new per-stage
routing:
- `MetalView.swift:3261` entity pass (main encoder)
- `MetalView.swift:3494` entity pass (HUD sub-scene)
- `MetalView.swift:4312` flare pass

Pre-Codex these were all `worldSamplerState (repeat)` and produced
concentric ring artifacts on the 64×64 flare disc (`Q3.tex.159`) and on
`Q3.tex.241` scene render target. Should be re-traced post-Codex to
confirm the per-stage wrap routing covers them.

### 4d. nv15 NVIDIA promo shaders

nv15.pk3 ships 31 shaders in `scripts/nvidia.shader`, all using standard
Q3 stage features (3-stage `map $lightmap + map base + map glow.blend`
with `GL_DST_COLOR/ZERO` + `GL_ONE/ONE` blends, plus `tcMod scroll`,
`deformVertexes wave`, `deformVertexes autoSprite`). Nothing exotic.
nv15 fails to load some textures — only 17 unique `Q3.tex.*` IDs
registered in the iOS trace despite the .shader file referencing 40+.
Most missing textures fall back to blue/magenta debug colors. Worth
investigating WHY texture resolution fails for these specific paths
(`textures/base_light/baslt4_1.blend.tga` etc) once draws are
PVS-culled to a tractable count.

---

## 5. Commit log on `metal-renderer-fresh` branch (most recent first)

```
8a2d161 Visual polish: brightness, postprocess, per-stage wrap, quad shell deform
f0b36ac Clamp Q3 additive texture samples for trace artifact
49fc8b2 Fog Q3 flare additive pass before UI
dcccc6b Clear drawable before Q3 render pass
8ac1664 Gate Q3 fog ray-box to inside volume
7a5aa20 Fix Q3 entity fragment uniform bindings
56c9ed9 Fix Q3 fog ray-box pipeline validation
2e1e6fc Fix Q3 tcMod rotate units
080fbc4 Tune Q3 fog volume and dlight falloff
a99a4c6 Fix Q3 fog volume gating and VM call ABI
ffcbaf4 Fix ProMotion drawable pacing stalls
0c30332 Enable ProMotion frame pacing for Q3 Metal
5515f86 Checkpoint Q3 Metal PVS batching and fog perf
046ef8a docs: PVS+frustum culling roadmap for nv15 perf
9af65ef Bucket world draws by render pass
88f06a6 Checkpoint working Metal fog renderer
7a6fea8 renderer: world-vertex CGEN_LIGHTING_DIFFUSE from BSP lightgrid
```

Branch is local-only — never pushed.

---

## 6. Reference projects identified for architectural patterns

External Github / sources consulted (some via brain RAG, some via web):
- `ec-/Quake3e` `code/renderervk/` (`tr_shade.c`, `vk.c`) — Vulkan
  renderer for ioquake3, runs on Apple Silicon via MoltenVK. Same
  1-draw-per-stage architecture as us. Reference for `R_StageIteratorGeneric`.
- `tominated/Quake-3-BSP-Renderer` — Swift+Metal Q3 BSP renderer.
  Outdated and incomplete on shader-side, but useful Swift/Metal API
  patterns. Also 1-draw-per-stage.
- `tomkidd/Quake3-iOS` — full iOS Q3 port, OpenGL ES via SDL. Not Metal,
  but useful for iOS app lifecycle and asset packaging.
- `ioquake/ioq3` PR #710 — incomplete Vulkan renderer port from
  vkQuake3 lineage.
- `ioquake3` `code/renderergl1/tr_world.c` — canonical
  `R_AddWorldSurfaces` / `R_MarkLeaves` / `R_RecursiveWorldNode`
  reference for next session's PVS work.

Key takeaway: both serious Q3 Metal/Vulkan reference renderers preserve
the 1-draw-per-stage shader-iterator architecture. The "merge multi-stage
into one fragment" approach DeepSeek almost talked us into would diverge
from established Q3 renderer convention. Stick with 1-draw-per-stage,
add PVS+frustum culling so most draws never fire.

---

## 7. Two related Q2 cross-project notes

This session's work overlapped with the Q2TooIOS port at
`/Users/targus/Documents/Q2_too_ios`:
- The same lightmap-multiply hue-preserving rescale bug Q2 fixed in
  commit `ffeb197` is the same code shape as the Q3 fix above. Q3 port
  already had the matching atlas-build math correct; the Bug 1 issue was
  the missing implicit pass injection, not the rescale.
- `scripts/q2_iphone_demo_avi.sh` was added as a Q2 parallel to the Q3
  capture helpers documented in §3a.
- Various PENDING Q2 work (Tier 1/2 prewarm, async WAL Phase 2 default
  flip, texture classification constants) remains uncommitted in the Q2
  working tree — covered separately in Q2's own CLAUDE.md "Work in
  flight" section.
