# idTech engine → Metal port: rendering bug classes & methodology (2026-06-02)

Findings from the Q3 Metal port chrome-shell-rendering investigation,
generalised for any idTech (Quake 2, Quake 3, Doom 3) → Metal port. Four
bug classes surfaced, each with a transferable diagnostic + fix pattern.

This document is intended to be ingested into the `projects/quake3-source/port/Quake_IoS`
brain (and cross-referenced from Q2_too_ios and any future Doom3 port).

## Bug class 1 — per-draw uniform binding only hits one shader stage

**Symptom (Q3):** `powerups/quadWeapon` chrome shell rendered with correct
colours, correct tcGen environment reflection, correct tcMod scroll+rotate
animation, but the +0.5-unit `deformVertexes wave` halo expansion was
silently absent. The chrome looked painted flat onto the gun mesh, not
expanded around it.

**Root cause:** in the entity render loop, `setFragmentBytes(&entityUniforms, ...)`
was called per draw inside the loop, but the matching `setVertexBytes` was
only called ONCE outside the loop with the initial uniforms (where
`deformWaveFunc=0`). Per-draw updates from `packEntityDeform`,
`packEntityTcMods`, `packEntityRgbGen` etc. only reached the fragment stage.
Vertex shader kept reading stale outside-loop uniforms. The
`if (uniforms.deformWaveFunc != 0u)` outer guard in `q3_entity_vertex`
silently failed for every chrome shell draw.

**Fix:** mirror every per-draw `setFragmentBytes(&xUniforms, ..., index: i)`
with a matching `setVertexBytes(&xUniforms, ..., index: i)` adjacent. Or
equivalently use a `MTLBuffer` instead of `setBytes` and bind it once with
both `setVertexBuffer` and `setFragmentBuffer`.

**Generality:**
- Affects ANY Metal port of a C engine that uses both vertex+fragment
  uniforms with per-draw state updates.
- Particularly insidious because fragment-side effects (colour, blend
  mode, texture sample) work correctly — the visible signal is the
  ABSENCE of any vertex-side animation (deformVertexes, autosprite
  billboard transforms, vertex skinning).
- Q2: confirmed safe — Q2_too_ios uses per-renderer dedicated MTLBuffer
  ring (`MetalVertexBufferRing`) rather than `setBytes`.
- Doom3 port: when implementing entity uniforms, BIND TO BOTH STAGES PER
  DRAW. Same applies to skinned-mesh joint matrices, deformVertexes
  ports, autosprite billboarding.

**Diagnostic that surfaced it:** 10× the visible scalar in the MSL math
(`worldPos += n * scale * 10.0`). If zero visual change → the block was
never entered → the uniform isn't arriving. If dramatic visual change →
the plumbing works and the canonical value is just sub-pixel-subtle at
the current drawable resolution.

## Bug class 2 — depth-compare strict-less rejects layered overlays

**Symptom (Q3):** `additiveLessDepthDescriptor.depthCompareFunction = .less`
rejected the chrome shell entirely. Sequence: (1) gun renders with depth
write → depth Z at gun surface; (2) chrome shell renders with deformWave
+0.5 unit offset; (3) under `RF_DEPTHHACK` (compresses viewmodel depth
range into a tiny near-z slice via viewport zRange), the 0.5-world-unit
offset projects to *the same NDC depth* as the gun surface; (4) `.less`
requires strictly less → equal-z FAILS → chrome rejected, invisible.

**Root cause:** PC Q3 uses `GL_LEQUAL` (ioq3 `GLS_DEPTHFUNC_LEQUAL` default).
ioq3 only sets `GL_EQUAL` for the explicit `depthFunc equal` shader
directive; everything else, including additive overlays, is `GL_LEQUAL`.
Our port used `.less` for the additive entity pipeline.

**Fix:** `additiveLessDepthDescriptor.depthCompareFunction = .lessEqual`.

**Generality:**
- Universal for any layered/shell rendering: muzzle flashes on guns,
  rocket explosions on world surfaces, decal effects, Q2 underwater
  warp post-process, Doom3 stencil shadow passes that need `LEQUAL`.
- Equal-z is the canonical case for "draw additive over existing
  geometry without z-fighting." `.less` only makes sense for primary
  opaque passes (where you want to reject already-drawn closer geometry).
- Q2: verify all `additive*DepthStencilState` uses `.lessEqual` for
  effect passes, especially `MetalEffectRenderer` sprite/particle pass.
- Doom3: stencil shadow passes use depth-fail (GL_LEQUAL); ambient passes
  use depth-write (GL_LEQUAL); interaction passes use depth-equal (GL_EQUAL).
  Map each to Metal `.lessEqual` / `.lessEqual` / `.equal` respectively.

## Bug class 3 — shader-map → texture-handle metadata propagation gap

**Symptom (Q3, earlier in this session):** quad shell deformVertexes was
0 on the C side of the texture metadata pipeline because `RegisterTexture`
applied stage-0 metadata via 8 `ShaderMap_Get*` accessors (blendMode,
alphaFunc, tcGenEnv, rgbGen, alphaGen, rgbWave, alphaWave, rgbConst,
alphaConst, tcMods) but had **no `ShaderMap_GetDeformWave` accessor**. So
`texture->deformWaveFunc` stayed at 0 even though the parser correctly
stamped deformWave onto every shader-map stage during shader registration.

**Root cause:** the parser populates the shader-map entry correctly, but
some metadata only gets propagated to `metalTexture_t` (the entity render
path's texture handle resolution) via per-field accessors. New shader
fields require new accessors. The chain has multiple silent-failure
points.

**Fix:** new `ShaderMap_GetDeformWave` accessor mirroring the existing
`ShaderMap_GetRgbWave/AlphaWave` pattern, wired into `RegisterTexture`
alongside the other eight accessors.

**Generality:**
- Pattern: any per-stage metadata that's needed at the entity
  customShader render path must have an accessor that pulls it from the
  shader-map's stage-0 to the texture-handle's metadata.
- Q2: `ref_mtl_stub.c` does the equivalent through `bsp_register_texture`
  / `Stub_RegisterPic`. Audit any newly-supported shader fields against
  the equivalent metadata-pull pattern.
- Doom3: idTech 4 has a richer material system with multiple "expressions"
  — same rule applies, more accessors required.

## Bug class 4 — iOS sandboxed stdout is /dev/null; Sys_Print must route to NSLog

**Symptom:** Q3-iOS port's `Sys_Print` wrote to stdout via `fputs`. On iOS
apps, stdout is disconnected by default — `Com_Printf` / `ri.Printf`
output went into the void. Engine prints never reached Console.app, `log
stream`, or `idevicesyslog` (which Apple has also restricted on iOS 18+).
The diagnostic `[METAL-SHADER]` dump was invisible until this was fixed.

**Root cause:** `fputs(msg, stdout)` in a sandboxed app has no consumer.

**Fix:** `Sys_Print` now ALSO calls `NSLog` after `fputs` with the trailing
newline stripped (NSLog adds its own). Negligible per-print cost; only
`Com_Printf` gates flow through `Sys_Print` so renderer/audio inner loops
aren't affected.

**Generality:**
- Applies to ANY C-engine port to iOS (Q2, Q3, Doom 3, Quake 1) where
  printf-class output is expected to be debuggable.
- Q2_too_ios already routes through `Q2IOS_Log` which calls NSLog
  internally — same pattern, just named differently.
- Doom3 port: `Sys_Printf` (idTech 4 convention) must call NSLog too.

**iOS 18+ syslog access regression:** `idevicesyslog` (libimobiledevice)
connects but doesn't stream device syslog on iOS 18. `xcrun devicectl
device console` doesn't have a console subcommand. Reliable alternatives:
- Console.app on Mac with the device selected
- Xcode → Devices and Simulators → View Device Logs
- **File-mirror sandbox dump pattern** (used in this investigation): write
  diagnostic to `Documents/<gamedir>/foo.log` via `fopen(append)`, pull
  via `xcrun devicectl device copy from --domain-type appDataContainer`.
  Deterministic regardless of log streaming status.

## Diagnostic methodology that found all the bugs

### Pattern A — dual-instrumentation log diff

Instrument BOTH the reference engine AND the port with matching-format
logs at the same lifecycle stage. Pull both into text files and diff
line-by-line.

For Q3: `[QE-SHADER]` (Quake3e `renderer/tr_shader.c FinishShader`) vs
`[METAL-SHADER]` (Q3-iOS `metal_renderer_stub.c` at end of shader
registration). Field-by-field identical → parser eliminated as a
divergence candidate within 60 seconds.

For Q2: instrument id-quake2 / yquake2 / vkQuake2 `R_FindImage` with
`[REF-IMAGE]` and Q2_too_ios `RegisterTexture` with `[METAL-IMAGE]` if
investigating image fallback or texture parameter divergence.

For Doom3: instrument `idMaterial::Parse` with `[REF-MATERIAL]` and the
Metal port's material-equivalent with `[METAL-MATERIAL]`.

### Pattern B — file-mirror sandbox dump (iOS 18+ syslog workaround)

```c
static FILE *s_diagFP = NULL;
if (s_diagFP == NULL) {
    const char *home = getenv("HOME");
    if (home != NULL && home[0]) {
        char path[1024];
        Com_sprintf(path, sizeof(path),
                    "%s/Documents/<gamedir>/diag.log", home);
        s_diagFP = fopen(path, "a");
    }
}
if (s_diagFP) {
    fprintf(s_diagFP, "[DIAG] ...\n");
    fflush(s_diagFP);
}
```

Pull via:
```bash
xcrun devicectl device copy from --device "<DeviceName>" \
  --domain-type appDataContainer --domain-identifier <bundle.id> \
  --source "Documents/<gamedir>/diag.log" --destination /tmp/diag.log
```

Clear via push-empty-file pattern:
```bash
: > /tmp/empty.log && xcrun devicectl device copy to \
  --device "<DeviceName>" --domain-type appDataContainer \
  --domain-identifier <bundle.id> --source /tmp/empty.log \
  --destination "Documents/<gamedir>/diag.log"
```

### Pattern C — 10× amplify the visible scalar to distinguish data vs math

When a transform/deform appears not to fire, multiply the visible
scalar by 10 in the shader:

```msl
// Before
worldPos += n * scale;
// Diagnostic
worldPos += n * scale * 10.0;
```

- **Zero visual change** → the surrounding block was never entered →
  the uniform isn't arriving → trace the uniform binding pipeline.
- **Dramatic visual change** → plumbing works → the canonical value is
  just sub-pixel-subtle at current resolution → no real bug.

This single technique exposed bug class 1 above. Logs alone would not
have surfaced it.

### Pattern D — runtime-trace at entity emit site, file-mirrored

When the parser dump matches but rendering is still wrong, add a runtime
trace at the entity-draw-emit site to capture what each draw cmd carries:

```c
// Filter to relevant shader names to bound log volume
if (sceneEntity->entity.customShader != 0) {
    const metalTexture_t *tex = FindTextureByHandle(textureHandle);
    if (tex && (Q_stristr(tex->name, "quad") || ...)) {
        fprintf(fp, "[QUAD-EMIT] tex='%s' blendMode=%d "
                    "tcModCount=%d deformWaveFunc=%d "
                    "finalFlags=0x%x ...\n",
                tex->name, tex->blendMode,
                tex->tcModCount, tex->deformWaveFunc,
                drawFlags);
    }
}
```

If every field is correct but rendering still wrong, the bug is downstream
of emit — in the draw-pass routing, pipeline state, or MSL itself.

## Cross-references

- Q2 port (`Q2_too_ios`): `CLAUDE.md` "Patterns" section, particularly
  `Renderer batch-bind memoization pattern` and `RAG-first lookup rule`.
- Quake3e PC reference instrumentation: branch
  `q2tooios-shader-diag` in `/Users/targus/src/Quake3e/`. The `[QE-SHADER]`
  patch is on its own branch to stay out of upstream master.
- This session's Q3 commit: `2e2273f` on branch `metal-renderer-fresh`
  in `/Users/targus/Documents/Quake_IoS/`.

## Items completed in this session (addendum)

- **`deformVertexes bulge` plumbing** — landed in commit `980b8d8`. Was
  previously a parse-and-discard at `metal_renderer_stub.c:6342` (three
  `(void)COM_ParseExt(...)` calls and a comment that literally said
  "Skip"). Same plumbing shape as deformWave: parser file-scope locals
  → stage stamp at shader close → `Q3MetalWorldStage` field copy →
  `WorldDrawUniforms` field propagation at 4 world stage→uniforms init
  sites → MSL `q3_world_vertex` block right after the existing
  deformWave block. Math: `phase = st.s * bulgeWidth + time * bulgeSpeed;
  scale = sin(phase) * bulgeHeight; pos += normal * scale`. Gated on
  `bulgeWidth != 0 || bulgeHeight != 0` because canonical Q3 shaders
  only specify bulge when actively using it.

  **Pattern lesson for Q2 + Doom3:** any shader-pipeline feature
  currently implemented as "parser parses then throws away" needs the
  full parser → struct → uniforms → shader plumbing. Search any port
  for `parse-and-discard` style stubs to find similar gaps. In our
  Q3 case the comment "// 3 args. Skip." was the smoking gun.

- **Async WAL texture upload Phase 1** — landed in commit `a93aa8a`.
  Port of Q2 commits 868b72f + 2fec194. Architecture:
  - Dedicated background `MTLCommandQueue` ("Q3.tex.asyncUpload")
  - Staging buffer pool: 4 × 4 MiB `.storageModeShared` MTLBuffers,
    NSLock-guarded acquire/release, lazy-init on first upload
  - Destination MTLTexture is `.storageMode = .private` (GPU-only, ~2×
    bandwidth headroom vs `.shared` on Apple Silicon)
  - Backpressure: inflight count capped at 4 via NSLock + Set; at
    capacity falls back to synchronous `.replace` with rate-limited
    warning (5 s gap)
  - **Cache-immediate-insert**: `textureCache[handle]` is populated
    BEFORE the blit completes. Metal's implicit resource tracking
    serialises the GPU draw queue after the upload queue when both
    reference the same `MTLTexture` object, so first-bind draws render
    correctly even if the blit is still in flight.

  **Pattern lesson for Q2 + Doom3:** the `texture(for:device:)`
  resolver pattern (single function called by every renderer pass to
  hand out cached `MTLTexture` for a given engine-side handle) is
  the natural insertion point for any async upload Phase 1. Don't
  scatter texture creation across renderer files; keep one resolver
  and put the async path inside it. Phase 2 (map-load frame-spread
  prewarm) needs an engine-side registration-sequence counter +
  bulk-fetch bridge accessor — defer until Phase 1 perf is measured.

## Items still deferred

- **Async WAL Phase 2 — map-load prewarm**: needs a
  `Q3MetalRenderer_CopyWorldTextureIDs` bridge accessor (analog of
  Q2's `Q2IOS_CopyWorldWALTextureIDs`) and a Q3-side registration-
  sequence counter (`Q2IOS_GetMapRegistrationSequence` analog). Phase 1
  alone delivers most of the gain; Phase 2 smooths remaining hitches
  from first-bind storms when player enters a new map area. Q2
  measured 0 misses / 0 starved across 10,640 presents with both
  phases combined.
- **HUD/menu rendering quality pass** — Q3 HUD uses 640×480 virtual
  coords scaled to drawable. May want explicit aspect-correction at
  widescreen vs the current naive scale.
- **MD3 lat/long normal decode for entities with deformBulge**: bulge
  needs per-vertex normal; entity path already provides it for chrome
  shells, but if any non-MD3 entity (sprite/beam) ends up needing
  bulge, the dfdx/dfdy face-normal fallback would kick in.
