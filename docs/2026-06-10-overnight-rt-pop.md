# Overnight workstream — RT lights/shadows, reflections, parallax, asset parity (2026-06-10/11)

All built and verified compiling (device build SUCCEEDED + both runtime MSL strings compiled offline via `xcrun metal -target air64-apple-ios18.0`). **Nothing visually verified on device yet — iPad away overnight.** First action in the morning: install `build-device-rt/.../Q3_RT.app` to Oled and run the verification list at the bottom.

## 1. P1 — RT direct lighting + shadow rays (authored Remix lights)

- Source of truth: per-map `<map>_lights.usda` from `~/Downloads/Quake III Arena RTX v0.7/rtx-remix/mods/q3rtx_v07/` (DistantLight/SphereLight/DiskLight/RectLight with positions, colors, intensities).
- `scripts/rt_lights_from_usda.py` bakes them to `Resources/baseq3/pbr/lights/<map>.json` (2,638 lights, 31 files; rect → equivalent-area disk; distant light dir from rotateXYZ).
- Swift `ensureRTLightBuffer(device:)` (MetalView.swift): loads JSON for the current map (via new C accessor `Q3MetalRenderer_GetWorldMapName()`), sorts distant lights to slot 0, uploads `RTLightGPU{posRadius, colorIntensity, dirType}` buffer → `Q3.RT.lights.<map>`, bound at kernel buffer(6). One-shot log `[RT] light set map='X' lights=N sun=0|1` (pbrLog + stdout).
- `rtKernel` NEE block (after the indirect bounce, opaque path only): always-sample sun (slot 0, type 0) + 1 stochastic local light per pixel, each with a real shadow ray (`intersector.intersect` occlusion). Local falloff `E = I * 60 * scale / (d² + r² + 1)`, contribution clamped ≤ 3, ×localCount pdf compensation.
- Cvars: `r_rt_lights` (1), `r_rt_light_scale` (1.0, clamp 0..100) — **the tuning knob for matching REF- brightness**.
- `RayTracingUniforms` grew `rtLightParams` (x=lightCount, y=lightScale, z=reflectionsOn, w=reflRoughMax) — appended LAST in both Swift and MSL structs.

## 2. P3 — RT specular reflections

- `RTPrimitiveMaterial.materialParams.z/.w` now carry roughness/metallic (from `roughness_constant`/`metallic_constant` in materials.json; defaults 0.85/0.0 = no reflection).
- Kernel: when `metal > 0.5 || rough < r_rt_refl_roughness_max`, one reflect ray (roughness-jittered via cosine hemisphere, TAA integrates), hit shaded albedo×lightmap(+emissive), miss → envCube. Fresnel-Schlick (F0 = mix(0.04, albedo, metal)) × gloss blend.
- Cvars: `r_rt_reflections` (1), `r_rt_refl_roughness_max` (0.45).

## 3. Height-map parallax (raster world)

- 636 `*_height.h.rtex.dds` now in the bundle (see §4); materials.json already had 1,400 height refs but Swift never loaded them.
- New `pbrHeightTexture(for:)` loader (canonical-path guard like emissive), bound at world fragment `texture(7)` (primary + batched sites; fog overlay binds the 1×1 default).
- `WorldDrawUniforms.parallaxParams` appended LAST in both structs (.x = scale, 0 = off).
- MSL `q3_world_fragment`: derivative-built tangent frame + 8-step layered search + secant refine, mutates texCoord in place (albedo/normal/rough/metal/emissive all get the displaced UV). Gated: scale > 0, tcGen == base, height bound.
- Cvar: `r_pbr_parallax_scale` (0.02, clamp 0..0.08, 0 = off).

## 4. Asset parity with Remix v0.7

- `rsync -a` of upstream `mods/q3rtx_v07/assets/` → `Resources/baseq3/pbr/assets/` (now byte-mirrors upstream: 2,804 DDS incl. all 636 height maps + configs/). Repo pbr tree on top of capture_textures = 14 GB; **bundle is 7.5 GB — dev-only, do not ship**.
- Bundle staging gotcha hit again: new nested dirs don't bump the tracked top-level mtime — after adding `pbr/lights/`, needed `touch Resources/baseq3 Resources/baseq3/pbr` + rebuild. Lights verified staged in the .app afterward.

## 5. Animations status

- World + entity sprite-sheet atlas paths were already wired (78 sprite_sheet materials). Parallax/atlas both mutate the shared texCoord in place, so animated frames get parallax too.
- Known remaining gaps (unchanged): per-material *normal* maps use their own `nmUV` and don't inherit the atlas remap; envmapyel/gold/bfg pickup chrome needs re-ingested multi-frame atlases (asset workstream, documented in CLAUDE.md).

## 6. Morning verification list (device required)

1. Install build, launch, load **q3dm17** with `r_rt_mix 1` — the launchpad/strip lights should now light the floor with real shadows. Tune `r_rt_light_scale` (try 0.5 / 1 / 2 / 4) against `~/Desktop/REF-*.jpg`.
2. `grep "RT] light set" q3_diag.log` → `lights=51 sun=0` on q3dm17, `lights=135 sun=1` on q3dm6.
3. q3dm6 outdoors: sun shadows from architecture; `r_rt_lights 0` for A/B.
4. Reflective check (q3dm10 jump pads / metal floors): `r_rt_reflections 0/1` A/B; widen `r_rt_refl_roughness_max` to 0.6 to see more surfaces.
5. Parallax: q3dm1/q3dm6 brick + tech floors (`r_pbr_parallax_scale 0 / 0.02 / 0.05` sweep, raster mode is enough).
6. Perf: expect +2–4 ms RT GPU (2 shadow rays + reflect subset). If over budget, drop `r_rt_resolution_scale` — perf explicitly deprioritized tonight.
7. Watch for: light leakage (shadow ray bias 0.75 may need bump on thin walls), fireflies near small bright lights (lower clamp from 3.0), reflection ghosting with TAA off.

## 7. Codex handoff (token-minimal)

Codex session `019e93ad…` in `~/Documents/Quake_IoS` (NOTE: repo here is `~/Documents/Quake_IoS_Phase9_Fork`). If picking up: all new code is uncommitted in the working tree; anchors: `ensureRTLightBuffer`, `rtLightParams`, `pbrHeightTexture`, `parallaxParams`, `Q3_RTLights`, `rt_lights_from_usda.py`. Validate MSL changes offline with:
`python3 - <<'EOF' ... extract shaderSource/makeRTLibrary strings ... EOF && xcrun metal -target air64-apple-ios18.0 -std=metal3.0 -c`.
Do NOT reorder uniform struct fields; append-only, both languages.
