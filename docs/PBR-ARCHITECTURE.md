# PBR Architecture — Quake3-iOS

**Status:** Phase 4b shipped as of commit `d26a768` on `metal-renderer-fresh`.

This document explains how PBR materials are wired through the Q3-iOS port —
from C-side texture registration, through Swift's MTKTextureLoader cache,
to the Metal entity/world fragment shaders. It exists so a future contributor
(or future me) can extend coverage without re-tracing the full pipeline.

## Phase summary

| Phase | What it does | Code touch | Commit |
|---|---|---|---|
| 1 | Per-weapon **albedo** texture substitution. Names like `models/weapons2/rocketl/rocketl.TGA` resolve via the alias table in `q3_pbr.c` and the C texture register hook looks up the material; Swift `MetalView.pbrAlbedoTexture(for:)` MTKTextureLoader-decodes the DDS and binds it at fragment texture(0). | `q3_pbr.c`, `metal_renderer_stub.c`, `MetalView.swift` | `c145a64` |
| 2 | Per-weapon **tangent-space normal mapping** via Mikkelsen's screen-space TBN trick (no per-vertex tangents needed — derived from `dfdx`/`dfdy` of worldPos + uv). Adds visible 3D relief on rocket and shotgun. | `MetalView.swift` `q3_entity_fragment` | `efb32b0` |
| 3 | **Universal world normal mapping**. Single bundled `metal_plate_normal_2k_OTH_Normal.n.rtex.dds` applied to every world surface. Q3 color variety preserved (no albedo swap); just adds rim-light modulation via the same Mikkelsen TBN. | `MetalView.swift` `q3_world_fragment` | `bc284f0` |
| 4 | **Cook-Torrance**-style specular. Initially attempted real GGX (commits `fdf5f56`, `ec4b9e3`, `4e0d07e`) but on Q3 viewmodel geometry the GGX peak was too narrow to read (`pow(NdotH, 43)` ≈ 5e-5 at typical viewing angles). After magenta/green diagnostic proved the branch fires, settled on **Fresnel-rim mix-blend** as the production formulation. | `MetalView.swift` `q3_entity_fragment` | `b2b6f0c` |
| 4b | Generic **shotgun.n.rtex.dds** normal-map fallback when material has albedo but no normal. Lets railgun/grenade/BFG enter the Phase 4 lighting block too. | `MetalView.swift` `pbrNormalTexture(for:)` | `d26a768` |

## Per-weapon coverage matrix

| Weapon | Albedo | Normal | Roughness | Metallic | Phase 4 rim |
|---|:---:|:---:|:---:|:---:|:---:|
| **Rocket** | rocket.a.rtex.dds | rocket_body_normal.n | rocket_body_roughness.r | rocket_body_metal.m | ✓ texture-driven |
| **Shotgun** | (vanilla pak0) | shotgun.n | — | — | ✓ defaults (r=0.55, m=0.50) |
| **Lightning** | lighting.a.rtex.dds | LightningGun_BurnNormal.n | — | — | ✓ defaults |
| **Railgun** | rail.a.rtex.dds | (Phase 4b generic shotgun.n) | — | — | ✓ defaults |
| **Grenade** | grenade.a.rtex.dds | (Phase 4b generic shotgun.n) | — | — | ✓ defaults |
| **BFG** | bfg.a.rtex.dds | (Phase 4b generic shotgun.n) | — | — | ✓ defaults |
| Machinegun | *(vanilla, user reverted)* | — | — | — | ✗ |
| Plasma | *(vanilla, user reverted)* | — | — | — | ✗ |
| Gauntlet | *(no entry in materials.json)* | — | — | — | ✗ |

## Why Cook-Torrance was replaced by Fresnel-rim mix-blend

**Math diagnostic** (see commit `4e0d07e` for the v3 attempt and `b2b6f0c`
for the v6 production):

For roughness=0.30 and a typical NdotH ≈ 0.7:
- GGX D = `alpha² / (π · (NdotH²·(alpha²-1)+1)²)` ≈ 0.00977
- `spec = D·F·G / (4·NdotV·NdotL + ε)` ≈ 0.001 per channel
- Even at 20× multiplier, additive `base.rgb += spec * NdotL * 20` ≈ 0.01 → invisible

The GGX peak is by design narrow (mirror angle), which is fine for IBL-driven
PBR but useless for "shiny" on Q3 viewmodel geometry under a fixed-direction
fake sun.

**Production v6 (`b2b6f0c`)**: Fresnel rim with mix-blend toward a metallic-
tinted highlight color:
```msl
float fresnel = pow(1.0 - NdotV, 2.5);     // narrow but VISIBLE
float3 rimColor = mix(white, base*1.25+0.15, metallic);
float rimStrength = fresnel * mix(0.20, 0.55, 1.0 - roughness);
base.rgb = mix(base.rgb, rimColor, saturate(rimStrength));
```

This **mix-blend** (not additive) means the rim can never be washed out by
a dark base — at silhouette where fresnel=1, the color goes fully to rimColor.

## Per-pixel cost

| Path | Texture samples | ALU |
|---|---|---|
| Phase 1 only (albedo swap) | 1 (existing slot 0) | ~0 |
| Phase 2 + normal map | +1 (slot 1) | ~25 (TBN + Lambert) |
| Phase 3 (world surfaces) | +1 (slot 2) | ~25 (per fragment, but world is large screen area) |
| Phase 4 (Fresnel rim, no rough/metal) | 0 (uses Phase 2's normal sample) | ~10 |
| Phase 4 (Fresnel + texture-driven rough/metal) | +2 (slots 3,4) | ~10 |

Apple Silicon absorbs all of this — measured perf:
- Device (iPhone 17 Pro Max): 120 FPS (capped) with all phases active
- Simulator (iPhone 17 Pro Max sim): 60 FPS

## Files of interest

- `code/ios/q3_pbr.c` — material table, alias table, name normalization
- `code/ios/metal_renderer_stub.c` — texture register hook (`load_pic_texture_with_mipmap`)
- `Quake3-iOS/MetalView.swift` lines ~2960-3100 — Swift PBR cache + loaders
- `Quake3-iOS/MetalView.swift` lines ~1900-2100 — `q3_entity_fragment` MSL
- `Quake3-iOS/MetalView.swift` lines ~1700-1830 — `q3_world_fragment` MSL
- `baseq3/pbr/materials.json` — `materials_by_name` table (gitignored under baseq3/)

## How to extend coverage

### Add a weapon to the PBR-rim list

1. Check `baseq3/pbr/materials.json` for a `materials_by_name` entry with the weapon's stem
2. If missing, add the stem + asset paths (albedo required; normal optional — Phase 4b will fall back)
3. If the weapon's Q3 shader path doesn't normalize to the stem directly (e.g. railgun uses `railgun1.tga` not `railgun.tga`), add an alias in `q3_pbr.c::kPbrAliases[]`

### Tune the visual rim look

Three numbers in `q3_entity_fragment`:
- `pow(1.0 - NdotV, 2.5)` — exponent. 1.5 = wider rim, 3.5 = sharper
- `mix(0.20, 0.55, 1.0 - roughness)` — strength range. Matte floor 0.20, smooth peak 0.55
- `base.rgb * 1.25 + 0.15` in `rimColor` — highlight brightness boost

### Add per-shader-name world PBR alias

`q3_pbr.c::q3_pbr_lookup_by_name` linear-scans `kPbrAliases[]`. Add an
entry like `{"base_wall", "metal_plate_diff_2k"}` to route Q3 base-wall
shaders to the mod's metal plate albedo.

## Known limitations

- **No path tracing** — Apple doesn't expose the RTX Remix path-tracing API. Phase 4 is a *stylized rim accent* that mimics PBR's wet-metal cue, not real IBL-driven PBR.
- **Single fake sun direction** `(0.3, 0.5, 0.7)` — hardcoded in MSL. A real PBR rig would derive from BSP lightgrid.
- **No environment cubemap reflections** — chrome surfaces don't reflect the room. Would need a render-to-cube pass.
- **No emissive bloom** — lightning gun coils etc. don't tint surrounding world. Would need HDR + 2-pass blur.
- **830 hex-keyed mod materials unreachable** — RTX Remix uses XXH3 hash of D3D9 buffer bytes; algorithm not reverse-engineered. Only the ~21 descriptive-stem materials in `materials_by_name` are used.
