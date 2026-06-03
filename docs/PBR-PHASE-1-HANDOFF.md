# PBR Phase 1 — Handoff for Codex

**Status:** Scaffolding compiles + sim builds. Runtime verification of
hash-function compatibility with NVIDIA RTX Remix is incomplete.

## What's done

| File | Status |
|---|---|
| `scripts/pbr_extract_hash_table.py` | Extracts 850 materials from `mod.usda` → JSON |
| `docs/pbr/q3rtx_v07_materials.json` | 850 materials, 148 with full PBR set (albedo+normal+roughness+metallic), 756 with at least albedo+normal |
| `code/ios/vendor/xxhash.h` | Vendored from xxHash v0.8.2 (BSD-2) |
| `code/ios/q3_pbr.h` + `q3_pbr.c` | Table loader, XXH3_64bits over BGRA mip-0, O(1) lookup, stats |
| `metalTexture_t` extended | Two new fields: `pbrContentHash` (uint64_t), `pbrMaterial` (const void *) |
| Hash hook in `load_pic_texture_with_mipmap` | Hashes RGBA after load, looks up table, attaches `q3_pbr_material_t *` |
| Boot table-load in `GetRefAPI` | Reads `Q3_PBR_JSON` + `Q3_PBR_ASSETS` env vars |
| `r_pbrMaterials` cvar | CVAR_ARCHIVE, default "0", gates the hash hook |

Both sim + device targets compile clean.

## What's NOT verified

1. **Hash function compatibility** — RTX Remix is documented as using xxHash
   but we haven't proven that `XXH3_64bits(BGRA_mip0)` matches their actual
   `mat_<HEX>` keys. The dxvk-remix source at
   `https://github.com/NVIDIAGameWorks/dxvk-remix/blob/main/src/dxvk/rtx_render/rtx_hashing.h`
   has the authoritative algorithm — needs reading.

2. **Logging pipeline** — `MetalTelemetryPrintf("metal_pbr_boot", ...)` calls
   don't show up in `q3_diag.log` during current sim runs. Could be that the
   GetRefAPI insertion point runs BEFORE `Q3_FileLogf` has working HOME, or
   the diag log file got locked. The strings ARE in the dylib
   (`Quake3-iOS.debug.dylib`) so compile + link are confirmed; just no
   observable runtime output yet.

3. **Sim env-var pass-through** — when launching with
   `-SIMCTL_CHILD_Q3_LAUNCH_COMMAND ...`, recent runs showed the engine never
   booting (q3_diag.log mtime stuck before launch time). May be related to
   issue #2 or to simctl arg quoting.

## Next steps for codex

### A. Verify the hash function

1. Read `dxvk-remix/src/dxvk/rtx_render/rtx_hashing.h` (search for
   `getNextValidHashRule`, `RtxTextureExtractionLatest`, `dwTextureHashRule`
   constants).

2. Find one Q3 texture that has a known PBR match in our table. The mod's
   `gfx/damage/burn_med_mrk.jpg` (pak0) is replaced by the remaster's TGA —
   look for its hash in `mod.usda`.

3. Decode that pak0 texture, run our `q3_pbr_hash_rgba()` on its bytes, and
   compare to the table entry's hash. If they don't match, try permutations:
   - RGBA layout instead of BGRA
   - Including mip chain
   - Format conversion via DXT compress first
   - Width/height included in hash header

### B. Fix the boot diag pipeline

The simplest fix: defer the table load to the FIRST `RE_RegisterShader`
call instead of inside `GetRefAPI`. By then `ri.Printf` definitely works
and `Q3_FileLogf` has HOME. Pattern:

```c
qhandle_t RE_RegisterShader(const char *name) {
    static int s_pbr_init_attempted = 0;
    if (!s_pbr_init_attempted) {
        s_pbr_init_attempted = 1;
        const char *json = getenv("Q3_PBR_JSON");
        const char *root = getenv("Q3_PBR_ASSETS");
        if (json && root && json[0] && root[0]) {
            q3_pbr_table_load(json, root);
        }
    }
    return RegisterTexture(name);
}
```

### C. Bundle a default JSON path

The asset root being a Downloads path is fine for sim debugging but ships
nowhere. Plan: stage `docs/pbr/q3rtx_v07_materials.json` into the app
Resources/baseq3/ and fall back to that path when the env var is unset.

### D. DDS loader (Swift side)

`MTKTextureLoader` handles BC formats natively on Apple Silicon. Sample:

```swift
let url = URL(fileURLWithPath: pbrMaterial.albedoPath)
let opts: [MTKTextureLoader.Option: Any] = [
    .SRGB: false,
    .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
    .textureStorageMode: NSNumber(value: MTLStorageMode.`private`.rawValue)
]
let albedoTexture = try loader.newTexture(URL: url, options: opts)
```

### E. PBR fragment shader

Cook-Torrance GGX with Disney's diffuse + roughness-aware Smith G2. ~80 lines
of MSL. Reference: `vkQuake2/code/shaders/world_warp.frag` for an existing
fragment shader in this codebase to pattern-match against.

## Open questions

- Is the q3_diag.log not being updated due to the boot-time write coming
  before the file-mirror's HOME is queryable? (Most likely.)
- Are we even running the engine when `Q3_LAUNCH_COMMAND` is set via
  `-SIMCTL_CHILD_*`? Earlier sessions worked; recent sessions don't seem
  to. May be a simctl version drift or container state.

## Hand-off-friendly file list

```
scripts/pbr_extract_hash_table.py                            # standalone Python tool
docs/pbr/q3rtx_v07_materials.json                            # 850 materials extracted
docs/PBR-PHASE-1-HANDOFF.md                                  # this doc
code/ios/vendor/xxhash.h                                     # vendored xxhash
code/ios/q3_pbr.h                                            # public C API
code/ios/q3_pbr.c                                            # impl (table loader, hash, lookup)
code/ios/metal_renderer_stub.c                               # cvar + boot env + hash hook + metalTexture_t fields
```

Total ~700 LOC across new files; ~30 LOC inserted into metal_renderer_stub.c.
