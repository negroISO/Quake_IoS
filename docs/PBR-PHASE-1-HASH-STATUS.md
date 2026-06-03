# PBR Phase 1 — Hash Algorithm Status (Task A)

**Status:** Algorithmic dead-end after exhaustive permutation testing.
RTX Remix v0.7's `mat_<HEX>` keys cannot be reproduced from any
straight-forward content-hash of the original Q3 textures.

## What we tried

**Target case (locked):**
- pak0 texture: `models/ammo/rocket/rocket.jpg` (64×64 baseline JPEG, 3-byte RGB)
- Decoded to RGBA via PIL → 16384 bytes
- Expected `mat_<HEX>` in `mod.usda`: **`21E72B8334E62360`** (binds to `rocket.a.rtex.dds`)

**Permutations exercised (no match across any combination):**

| Axis | Variants tried |
|---|---|
| Hash function | XXH3_64bits, XXH64, XXH3_128 low/high, custom Q3 hash |
| Channel order | RGBA, BGRA, ARGB, ABGR, GBAR |
| Lightscale (PC Q3 `r_overBrightBits`) | ×1, ×2 (default), ×4 |
| Mip chain | mip-0 only, full chain (top→bottom), bottom-mip only |
| Alpha handling | passthrough, force-opaque, zero, one-minus |
| Row layout | tightly packed, D3D9 4-byte aligned, BGRA aligned |
| Prefix headers | none, W×H ASCII, U16 LE/BE W+H, U32 LE/BE size |
| Flip rows | yes (D3D9 origin TL→BL), no |
| Stride sampling | every 2nd, 3rd, 4th, 8th, 16th pixel |
| Format | A8R8G8B8_BGRA, X8R8G8B8_BGRA, etc. |

Total ~80 permutations across `scripts/pbr_hash_probe.c` +
`/tmp/q3_pbr_test/find_hash.py`. **Zero matches.**

## Source-of-truth dive

NVIDIA dxvk-remix (tip @ `ee936200`):
- `src/d3d9/d3d9_common_texture.cpp::SetupForRtxFrom`:
  `imageHash = XXH3_64bits(buffer->mapPtr(0), buffer->info().size);`
- The buffer in question is the FULL Vulkan-side staging buffer after
  D3D9→VK format conversion. For A8R8G8B8 → VK_FORMAT_B8G8R8A8 the
  memory layout is BGRA in little-endian.
- Buffer SIZE includes alignment + (sometimes) the whole mip chain
  packed sequentially.

The probe replicates exactly this path. Still no match. Possible
explanations:

1. **Version drift** — Mod v0.7 was captured March 2025 with an older
   dxvk-remix build. NVIDIA may have CHANGED the hash function. The
   git log for `d3d9_common_texture.cpp` at the relevant commit
   ranges needs inspection. If a different hash, the v0.7 source is in
   that older commit's tree.

2. **Pre-upload Q3 transformation we don't reproduce** — Q3's
   `tr_image.c` does `R_LightScaleTexture` (multiply ×2 with clamp at
   default) THEN `R_MipMap` (box average). The probe applies these in
   that order but the EXACT box-filter rounding behavior of Q3 differs
   between renderers (the sw renderer uses a different reduction). Q3
   PC's GL renderer uses `R_MipMap` which we replicated, but the chain
   may include `R_BlendOverTexture` or another step we missed.

3. **dxvk-remix specifically does NOT use the simple
   `XXH3_64bits(buffer, size)` path for the v0.7 capture format** —
   there's a separate `m_buffers[subresource=0]` legacy hashing path
   we may have read incompetently. The harness needs to verify by
   compiling and running dxvk-remix against a known capture.

4. **Capture-time D3D9 ALPHA conversion** — JPGs in Q3 are 3-byte RGB.
   `R_LoadJPG` fills alpha=255. But D3D9 may LOAD as X8R8G8B8 (alpha
   undefined) before converting to A8R8G8B8 → the alpha bytes in the
   hash payload could be anything from 0x00 to 0xFF. We tested both
   "alpha = 0xFF" and "alpha = 0x00" — neither matched.

## Recommended next steps

### Path A — Side-step the hash (FASTEST visual progress)

The mod has **80 descriptively-named materials** (FX effects like
`Blackhole`, `LightningMuzzle`, `Thrustersmoke`, `Spark`, etc.) plus
**~770 hex-named materials** (world textures, architecture, weapons).

For Phase 1 we could:
1. Extract the 80 descriptive ones via name match — bind to Q3 shader
   names manually (`Blackhole → models/weapons2/bfg/...`, etc.)
2. Skip the 770 hex-named materials (the bulk visual delta) until the
   hash is solved
3. Wire up the Swift DDS loader + PBR shader so the 80-material subset
   visibly demonstrates PBR is working
4. Re-open hash matching later as a separate research task

### Path B — Capture our own hash table

Run PC Q3 with `dxvk-remix` in `rtx.captureMode = enabled`. The
runtime will log every D3D9 texture's hash + the Q3 file name. Save
that map as our binding table. Then we don't need to reproduce
NVIDIA's hash — we read it.

Prereqs:
- Windows machine (or Wine + Proton + dxvk-remix)
- dxvk-remix capture build
- Same Q3 pak0.pk3 we ship

### Path C — Binary search dxvk-remix git history

The hash function at tip may differ from the function at the v0.7
capture commit (~March 2025). Bisect:
```
cd /tmp/dxvk-remix-latest
git log --oneline --all -- src/d3d9/d3d9_common_texture.cpp | head -50
git log --oneline --since='2024-09-01' --until='2025-04-01' -- 'src/d3d9/d3d9_*' | head -20
```
Walk back through commits that modify the hash path. For each
candidate commit, rebuild the harness with that exact algorithm and
retest rocket.jpg. If any commit produces `21E72B8334E62360`, that's
our reference.

### Path D — Defer entirely; ship Phase 1 as "PBR-by-shader-name"

Most pragmatic for ship value. Ignore the mod's hash table; just
publish a hand-authored `{q3_shader_name → pbr_material}` mapping for
the textures we care about. The DDS files are still usable — we just
match them by content/file inspection rather than by replaying the
RTX Remix capture pipeline.

## Files in current scaffold

```
docs/pbr/q3rtx_v07_materials.json   # 850 materials, hex-keyed
scripts/pbr_hash_probe.c             # ~80 hash permutations, all miss
scripts/pbr_extract_hash_table.py    # mod.usda → JSON extractor
code/ios/q3_pbr.{h,c}                # C-side material table loader
code/ios/vendor/xxhash.h             # vendored xxhash v0.8.2
/tmp/q3_pbr_test/find_hash.py        # Python-side permutation hunt
/tmp/q3_pbr_test/rocket.{jpg,rgba}   # canonical test texture
```

## Recommendation

**Take Path A or D and proceed with Phase 1b (DDS loader) + 1c (PBR
shader).** Solving the hash mystery is interesting but is blocking
shipping value. Even an 80-material partial PBR pipeline visibly
demonstrates the technique and lets us validate the rest of the
plumbing (DDS decode, PBR shader, sampler binding). The hash work can
land as a follow-up task once Phase 1c is green.
