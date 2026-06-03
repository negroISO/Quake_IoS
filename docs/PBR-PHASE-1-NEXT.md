# PBR Phase 1 — Next Steps (post Path A scaffolding)

**Status:** C-side name-based PBR binding lands clean. Swift DDS loader
and PBR fragment shader are queued; runtime visual verification is
blocked on a sim env-var pipeline issue (see open issues below).

## What landed this turn

| Component | Status |
|---|---|
| `scripts/pbr_extract_hash_table.py` extended → `materials_by_name` map (21 entries: rocket, shotgun, rail, grenade, plasma, machinegun, bfg, LightningGun*, Blackhole, Thruster*, Spark, …) | ✅ |
| `code/ios/q3_pbr.h`: `q3_pbr_lookup_by_name`, `q3_pbr_named_count` | ✅ |
| `code/ios/q3_pbr.c`: JSON parse of `materials_by_name`, linear-scan lookup, shader-name normalization (basename, lowercase, ext-strip) | ✅ |
| `metal_renderer_stub.c::load_pic_texture_with_mipmap`: hash-miss → name-match fallback wired | ✅ |
| Sim + device builds: clean | ✅ |

## What's still needed

### 1. Swift DDS loader (~30 LOC)

`MTKTextureLoader` on Apple Silicon natively handles BC1/BC3/BC5/BC7
DDS. Add to `MetalView.swift`:

```swift
private let pbrTextureLoader = MTKTextureLoader(device: device)
private var pbrCache: [String: MTLTexture] = [:]   // path → texture

func loadPBRTexture(_ path: String) -> MTLTexture? {
    if let cached = pbrCache[path] { return cached }
    let url = URL(fileURLWithPath: path)
    let opts: [MTKTextureLoader.Option: Any] = [
        .SRGB: false,
        .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
        .textureStorageMode: NSNumber(value: MTLStorageMode.private.rawValue),
        .generateMipmaps: false,
    ]
    do {
        let t = try pbrTextureLoader.newTexture(URL: url, options: opts)
        pbrCache[path] = t
        return t
    } catch {
        NSLog("[Q3-PBR] DDS load failed: %@ — %@", path, error.localizedDescription)
        return nil
    }
}
```

Bridge accessor in C (`Q3MetalRenderer_GetPBRMaterial(handle)`)
returning the same `q3_pbr_material_t *` we already store in
`metalTexture_t.pbrMaterial`. Then Swift inspects `.albedo` / `.normal`
paths and lazy-loads them via `loadPBRTexture`.

### 2. PBR fragment shader for the world pass (~80 LOC MSL)

Minimum-viable PBR: albedo + normal map + Lambert × lightmap. No
specular/GGX in v1 — Q3 has no light direction vectors per-fragment so
specular needs a synthetic sun. Save that for v2.

```msl
fragment float4 q3_world_pbr_fragment(
    WorldVOut in [[stage_in]],
    texture2d<float> albedoMap   [[texture(0)]],
    texture2d<float> normalMap   [[texture(1)]],
    texture2d<float> lightmap    [[texture(2)]],
    sampler s [[sampler(0)]]
) {
    float3 albedo  = albedoMap.sample(s, in.uv).rgb;
    float3 normalT = normalMap.sample(s, in.uv).rgb * 2.0 - 1.0;
    float3 light   = lightmap.sample(s, in.lmuv).rgb;

    // Cheap normal modulation: dot with up-ish (0, 0, 1) tangent-space
    float ndotl = saturate(normalT.z);
    float3 color = albedo * light * (0.5 + 0.5 * ndotl);

    return float4(color, 1.0);
}
```

Pipeline state: add a `worldPBRPipelineState` analogous to
`worldPipelineState`. Choose between them per-draw based on whether
`pbrMaterial != nil` for the texture handle bound to this draw.

### 3. Bridge the C `q3_pbr_material_t` to Swift

Two options:

**Option A — opaque pointer + accessor functions:**
```c
// In q3_pbr.h
const char *q3_pbr_material_albedo_path(const void *material);
const char *q3_pbr_material_normal_path(const void *material);
// … one per slot
```

**Option B — mirror struct in bridging header:**
```c
// Bridging header
typedef struct {
    uint64_t hash;
    const char *albedo, *normal, *roughness, *metallic, *emissive, *height;
    float emissive_intensity;
    float emissive_color_r, emissive_color_g, emissive_color_b;
    int has_emissive_color;
} Q3PBRMaterial;

const Q3PBRMaterial *Q3MetalRenderer_GetPBRMaterial(uint32_t textureHandle);
```

B is simpler — Swift reads the struct directly and walks the paths.

### 4. Bundle the JSON + asset root

Currently `q3_pbr_table_load` only fires when `Q3_PBR_JSON` +
`Q3_PBR_ASSETS` env vars are set. For ship:

- Stage `docs/pbr/q3rtx_v07_materials.json` into the app bundle's
  `Resources/baseq3/pbr/materials.json`.
- Curate a subset of DDS assets (just the ~80 named ones, ~50–100 MB
  vs the full 14 GB) into `Resources/baseq3/pbr/assets/ingested/`.
- Default-load these paths via `[NSBundle mainBundle resourcePath]` in
  `GetRefAPI` when env vars aren't set.

### 5. Default-on `r_pbrMaterials 1` (ship-flip)

Once 1–4 are stable, flip the default in `q3_pbr_cvar_enabled`.

## Open issues

### Env-var passthrough on sim

`xcrun simctl launch -SIMCTL_CHILD_Q3_LAUNCH_COMMAND "..."` is not
reaching the launched process reliably in the current session. The app
boots to the SwiftUI launcher menu and waits for a tap. The engine
never invokes `Quake3_Init`, so `GetRefAPI` doesn't run and the PBR
table doesn't load.

This is the same issue noted in `docs/PBR-PHASE-1-HANDOFF.md` under
"Sim env-var pass-through" (Open issue #3). Workarounds:

- **On device:** `xcrun devicectl device process launch
  --environment-variables` works reliably (we used this earlier in
  the session for MetalFX testing).
- **For sim only:** add a debug cvar `r_pbrAutoBoot 1` that lets us
  set everything via Cbuf after the launcher tap.
- **Manual sim test:** launch via Simulator GUI, tap a demo, then
  console-set `r_pbrMaterials 1`. C-side hooks will fire as long as
  `Q3_PBR_JSON` env var was set at process spawn (which is the
  unresolved part).

### Hash function still undetermined

`docs/PBR-PHASE-1-HASH-STATUS.md` has the full ~80-permutation
dead-end record. Name fallback covers ~20 of 850 materials. Remaining
830 are hex-keyed and need either:
- Path B: capture our own table via dxvk-remix instrumentation
- Path C: bisect dxvk-remix git history for the v0.7 capture-time hash
- Defer indefinitely; bind by name only

## Files touched this turn

```
scripts/pbr_extract_hash_table.py    # +materials_by_name extraction
docs/pbr/q3rtx_v07_materials.json    # regenerated, version 2
code/ios/q3_pbr.h                    # +q3_pbr_lookup_by_name, +q3_pbr_named_count
code/ios/q3_pbr.c                    # +named-array parser + linear lookup + normalize
code/ios/metal_renderer_stub.c       # name-match fallback after hash-miss in load_pic_texture_with_mipmap
docs/PBR-PHASE-1-NEXT.md             # this doc
```
