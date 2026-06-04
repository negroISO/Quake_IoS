# Codex Task — PBR Phase 9: per-shader material classifier

**Branch:** `metal-renderer-fresh` (working tree clean at HEAD after Phase 8 brightness tuning landed mid-session)
**Estimated:** 45-90 min of focused work, single commit at the end
**Owner:** codex (delegated from main session 2026-06-04)

## Goal

Make Q3 world surfaces read by material type instead of one global roughness/metallic. Bricks should look matte and dielectric, polished metal trim/plaques should look chrome, wood should look matte and neutral. The signal is sitting in the Q3 shader path names — extract it and route the appropriate constants through to the existing PBR Phase 8 MSL block.

A/B gate must be a new cvar `r_pbr_world_class_match` (CVAR_ARCHIVE, default `1`) so the current uniform-material behaviour is one console set away.

## What's already shipped (do NOT re-implement)

- **Phase 6 IBL** — procedural sky-gradient cube + per-map skybox cube via env/*.jpg loader (Phase 6 v2) + auto-detect via skyparms publish to `r_pbr_ibl_skybox` (Phase 6 v3). Working.
- **Phase 8 world Cook-Torrance + IBL** in `q3_world_fragment`. The MSL block is gated on `r_pbr_world_textures` (default 1) and uses these globals:
  - `pbrWorldParams.x` = enable
  - `pbrWorldParams.y` = ambient boost (default 0.30)
  - `pbrWorldParams.z` = spec boost (default 0.60)
  - `pbrWorldParams.w` = reserved
- Current uniform defaults in MSL: `roughness = 0.45`, `metallic = 0.30`. These are what Phase 9 must REPLACE per-shader.
- The MSL has a Fresnel-edge gate on the spec contribution and strict inverse-luma on the diffuse fill. Do NOT change the lighting math; only change *which* roughness/metallic values feed it.

## Where to wire the classifier (file-level map)

| File | Why |
|---|---|
| `code/ios/q3_pbr.c` / `q3_pbr.h` | New `q3_pbr_classify_shader` C function + enum + class→(rough, metal) lookup table |
| `code/ios/metal_renderer_stub.c` | Call classifier when a shader gets parsed; store class on `metalShaderMap_t`; expose via accessor at draw time. Add three cvar accessors. |
| `code/ios/metal_renderer_shared.h` | Extend `Q3MetalWorldDrawCmd` / `Q3MetalWorldStage` (whichever fires per-draw) with a `float pbrRoughness; float pbrMetallic;` pair so Swift can read them per draw without another lookup. |
| `Quake3-iOS/Quake3-iOS-Bridging-Header.h` | `Q3_PBRWorldClassMatchEnabled()` declaration |
| `Quake3-iOS/MetalView.swift` | Read the per-draw rough/metal from the world draw cmd; pack into the existing `pbrWorldParams.w` slot OR extend pbrWorldParams to a `float8`/two `float4`s. Use the per-draw values inside the existing Phase 8 MSL block instead of the hardcoded `0.45 / 0.30`. |

## Classifier table — q3dm1 prefixes

```c
typedef enum {
    Q3_PBR_MAT_DEFAULT = 0,    /* 0.55 / 0.30 — matches current uniform */
    Q3_PBR_MAT_STONE_ROUGH,    /* 0.85 / 0.02 */
    Q3_PBR_MAT_WOOD,           /* 0.75 / 0.00 */
    Q3_PBR_MAT_METAL_TRIM,     /* 0.30 / 0.85 */
    Q3_PBR_MAT_METAL_PLAQUE,   /* 0.25 / 0.90 */
    Q3_PBR_MAT_METAL_BRIDGE,   /* 0.40 / 0.70 */
    Q3_PBR_MAT_LIGHT_FIXTURE,  /* 0.50 / 0.30 — emissive boost reserved */
    Q3_PBR_MAT_MAX
} q3_pbr_world_mat_t;

/* Classification rule: walk the shader name and match the first prefix that
 * hits. Order matters (most-specific first). Strings to recognise (q3dm1
 * inventory cross-referenced — see audit in /tmp/ralph_q3/q3dm1-textures.txt
 * if the file still exists; otherwise unzip pak0.pk3 maps/q3dm1.bsp |
 * strings | grep ^textures/). */

static const struct {
    const char *prefix;
    q3_pbr_world_mat_t mat;
} kQ3PBRClassRules[] = {
    /* Most specific first */
    { "textures/gothic_floor/metalbridge",        Q3_PBR_MAT_METAL_BRIDGE },
    { "textures/gothic_floor/blocks",             Q3_PBR_MAT_STONE_ROUGH },
    { "textures/gothic_floor/largerblock",        Q3_PBR_MAT_STONE_ROUGH },
    { "textures/gothic_floor/xstair",             Q3_PBR_MAT_STONE_ROUGH },
    { "textures/gothic_floor/xstepborder",        Q3_PBR_MAT_STONE_ROUGH },
    { "textures/gothic_floor/center2trn",         Q3_PBR_MAT_STONE_ROUGH },

    { "textures/gothic_ceiling/woodceiling",      Q3_PBR_MAT_WOOD },

    { "textures/gothic_door/skullarch",           Q3_PBR_MAT_METAL_PLAQUE },
    { "textures/gothic_door/skull_door",          Q3_PBR_MAT_METAL_PLAQUE },
    { "textures/gothic_door/skull",               Q3_PBR_MAT_METAL_PLAQUE },
    { "textures/gothic_door/km_arena1arch",       Q3_PBR_MAT_METAL_TRIM },
    { "textures/gothic_door/km_arena1column",     Q3_PBR_MAT_METAL_PLAQUE },
    { "textures/gothic_door/xian_tourneyarch",    Q3_PBR_MAT_METAL_TRIM },

    { "textures/gothic_trim/baseboard",           Q3_PBR_MAT_METAL_TRIM },
    { "textures/gothic_trim/km_arena1tower",      Q3_PBR_MAT_METAL_TRIM },

    { "textures/gothic_block/killblock",          Q3_PBR_MAT_METAL_PLAQUE },
    { "textures/gothic_block/demon_block",        Q3_PBR_MAT_STONE_ROUGH },
    { "textures/gothic_block/blocks",             Q3_PBR_MAT_STONE_ROUGH },

    { "textures/gothic_light/pentagram_light",    Q3_PBR_MAT_LIGHT_FIXTURE },

    /* sentinel */
    { NULL, Q3_PBR_MAT_DEFAULT },
};

static const struct {
    float roughness;
    float metallic;
} kQ3PBRClassParams[Q3_PBR_MAT_MAX] = {
    /* DEFAULT       */ { 0.55f, 0.30f },
    /* STONE_ROUGH   */ { 0.85f, 0.02f },
    /* WOOD          */ { 0.75f, 0.00f },
    /* METAL_TRIM    */ { 0.30f, 0.85f },
    /* METAL_PLAQUE  */ { 0.25f, 0.90f },
    /* METAL_BRIDGE  */ { 0.40f, 0.70f },
    /* LIGHT_FIXTURE */ { 0.50f, 0.30f },
};

q3_pbr_world_mat_t q3_pbr_classify_shader(const char *name);
void q3_pbr_class_params(q3_pbr_world_mat_t mat, float *out_rough, float *out_metal);
```

Add a logging line on first classification of each new shader name:
`[Q3-PBR-CLASS] '<name>' → class=<N> rough=<R> metal=<M>` (telemetry channel `metal_pbr_ibl` or a new `metal_pbr_class` — same pattern as existing `[Q3-PBR-IBL] auto-detect` line in `GetSkyFaceTextureForSurface`).

## Cvars to add (mirror the Phase 8 pattern in metal_renderer_stub.c around the existing Q3_PBRWorldEnabled fn)

```c
/* CVAR_ARCHIVE, default 1. When 0, MSL falls back to the previous uniform
 * defaults (0.45 / 0.30) so the existing tuning behaviour stays available. */
int Q3_PBRWorldClassMatchEnabled(void);
```

Plumb via the existing `pbrWorldParams` struct — re-using `pbrWorldParams.w` (currently 0) as the class-match toggle, OR add a new struct slot. Easier: route per-draw `roughness` + `metallic` floats through extended `WorldDrawUniforms`, then the MSL just reads them.

## Per-draw plumbing

The cleanest path:

1. Add to `WorldDrawUniforms` struct (`metal_renderer_shared.h`):
   ```c
   float pbrRoughness;  /* per-shader class lookup */
   float pbrMetallic;
   ```
   …or pack both into one `float2` field. Either way, push them per-draw alongside the existing `tcGen`, `blendMode`, etc.

2. In Swift's world-encode site (look for `var drawUniforms = WorldDrawUniforms(`), populate them from the per-draw Q3MetalWorldStage / Q3MetalWorldDrawCmd. The C side already has access to the shader's classified material on the `metalShaderMap_t` — when emitting a draw cmd, copy the class's (rough, metal) into the per-draw struct.

3. In the MSL `q3_world_fragment` Phase 8 block — REPLACE the hardcoded
   ```msl
   float roughness = 0.45;
   float metallic = 0.30;
   ```
   with
   ```msl
   float roughness = (pbrClassMatchEnabled > 0.5) ? drawUniforms.pbrRoughness : 0.45;
   float metallic  = (pbrClassMatchEnabled > 0.5) ? drawUniforms.pbrMetallic  : 0.30;
   ```
   …where `pbrClassMatchEnabled` is plumbed via either an extra `pbrWorldParams.w` flag (the slot is reserved/unused right now) OR a separate uniform.

## Acceptance criteria

1. Build clean on `-sdk iphonesimulator -arch arm64 ONLY_ACTIVE_ARCH=YES` AND `-sdk iphoneos -allowProvisioningUpdates DEVELOPMENT_TEAM=72MB2RMPTC`.
2. Sim launch on UDID `99CE0933-41D5-41F2-A10D-D6E63B947B96`: `devmap q3dm1 ; wait 80 ; give all`.
3. Log should show 5-15 distinct `[Q3-PBR-CLASS]` events on map load (one per unique shader classified into a non-DEFAULT class). Including at minimum a hit for `textures/gothic_block/*` (STONE_ROUGH) and `textures/gothic_door/skull*` (METAL_PLAQUE).
4. A/B via `set r_pbr_world_class_match 0; vid_restart` falls back to the uniform `0.45 / 0.30` behaviour. Screenshots from sim should differ.
5. Visual expectation:
   - Stone bricks render very matte; no specular highlight even at grazing angles
   - Skull plaques / arch trim render distinctly chrome (Fresnel-edge IBL reflection)
   - Wood ceiling stays neutral matte
6. No regression on already-shipped Phase 6 IBL, Phase 5 GGX, Phase 4 v6 Fresnel rim, or Phase 8 world IBL on default cvar settings.

## DO NOT touch

- `materials.json` or any entity (weapon viewmodel / pickup) PBR plumbing. Phase 9 is world-only.
- `MetalAliasRenderer.swift`, `MetalEffectRenderer.swift`, `MetalOverlayRenderer.swift`. World renderer only.
- The IBL composition math (Fresnel-edge gate, inverse-luma fill, sun direction, kD energy split). Only the inputs (roughness, metallic) change per-draw.
- Tier 1/2 asset prewarming. Out of scope.
- The hash crack for the mod's 2,804 hex-keyed DDS pool. Separate Phase deferred.

## Commit message template

```
feat(pbr): Phase 9 — per-shader material classifier for world surfaces

Routes per-draw roughness/metallic from a name-pattern classifier instead
of the global 0.45/0.30 defaults. Stone bricks read as matte dielectric,
skull plaques + metal trim read as polished chrome, wood ceiling stays
neutral matte. Signal is the Q3 shader path prefix — no authored PBR
data required.

Classifier covers q3dm1's gothic_* family (stone, wood, metal trim,
metal plaques, metal bridge, light fixtures). Other maps' shader names
will fall through to DEFAULT until added.

A/B via r_pbr_world_class_match (CVAR_ARCHIVE, default 1). Set to 0 +
vid_restart to revert to the global uniform behaviour shipped in
Phase 8.

Phase 8 IBL composition math unchanged — only the per-draw rough/metal
inputs differ. Fresnel-edge spec gate + inverse-luma diffuse fill
preserved. No entity renderer changes.

Co-Authored-By: codex (delegated)
```

## Reference paths

- Phase 8 MSL block (where rough/metal are currently hardcoded): `Quake3-iOS/MetalView.swift` ~line 2050+ inside `q3_world_fragment`, immediately after the Phase 3 `worldNormalMap` branch's halfLambert.
- World-draw binding site: `MetalView.swift` ~line 4438 (main world pass) and ~line 4794 (fog pass). Both already populate `WorldDrawUniforms` and bind `pbrWorldParams` at fragment buffer slot 3.
- Existing Phase 8 cvar accessor pattern: `code/ios/metal_renderer_stub.c` immediately after `Q3_PBRPhase5Enabled()` — `Q3_PBRWorldEnabled`, `Q3_PBRWorldAmbientBoost`, `Q3_PBRWorldSpecBoost`.
- Shader-map / `metalShaderMap_t` is at `metal_renderer_stub.c` around line 560; `skyBoxBase`, `isSky` etc. live there — add `pbrMatClass` next to them.
- Shader-parse hook fires inside the big shader parser around line 6336 (where `skyparms` is recognised). Classify the shader's name at the SAME exit point that fills `last->skyBoxBase` (line ~7279 / line ~7067).

## How to test

```bash
cd /Users/targus/Documents/Quake_IoS
xcodebuild -project Quake3-iOS.xcodeproj -scheme Quake3-iOS \
    -sdk iphonesimulator -configuration Debug \
    -arch arm64 ONLY_ACTIVE_ARCH=YES \
    -derivedDataPath build-sim build

SIM_UDID=99CE0933-41D5-41F2-A10D-D6E63B947B96
xcrun simctl boot "$SIM_UDID" 2>/dev/null
xcrun simctl install "$SIM_UDID" build-sim/Build/Products/Debug-iphonesimulator/Quake3-iOS.app

# A/B: class-match ON
SIMCTL_CHILD_Q3_LAUNCH_COMMAND="set r_pbr_world_class_match 1;devmap q3dm1;wait 80;give all" \
    xcrun simctl launch "$SIM_UDID" com.quake3ios.app
sleep 14
xcrun simctl io "$SIM_UDID" screenshot /tmp/phase9-on.png

# A/B: class-match OFF (back to Phase 8 uniform)
xcrun simctl terminate "$SIM_UDID" com.quake3ios.app
SIMCTL_CHILD_Q3_LAUNCH_COMMAND="set r_pbr_world_class_match 0;devmap q3dm1;wait 80;give all" \
    xcrun simctl launch "$SIM_UDID" com.quake3ios.app
sleep 14
xcrun simctl io "$SIM_UDID" screenshot /tmp/phase9-off.png

# log
SIM_DATA=$(xcrun simctl get_app_container "$SIM_UDID" com.quake3ios.app data)
grep '\[Q3-PBR-CLASS\]' "$SIM_DATA/Documents/q3_diag.log" | sort -u | head -20
```

Done. Commit + push to a topic branch (`feat/pbr-phase-9-classifier` if you want), or land on `metal-renderer-fresh` directly — whatever the parent session prefers. Parent will integrate and push to iPhone via `xcrun devicectl device install app --device "Yd-Mubarak MajMaj"`.
