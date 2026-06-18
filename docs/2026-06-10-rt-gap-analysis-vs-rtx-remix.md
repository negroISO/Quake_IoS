# RT Gap Analysis — Metal build vs RTX Remix reference (2026-06-10)

Source reviewed: `~/Desktop/q3rt_llm_drop` (MetalView.swift 9509 lines, metal_renderer_stub.c 10573 lines, q3_pbr.c, materials.json, q3_diag.log from binaryMtime 12:36/13:02 builds). Screenshots compared: q3dm4 courtyard (ours vs Remix), q3dm17 space platform (ours vs Remix), q3dm12 slime room (ours vs Remix).

## 1. What the RT kernel does today (`rtKernel`, MetalView.swift ~3590)

Primary camera ray into world AS → albedo × lightmap×1.25 (max'd against ambient floor) → optional ONE cosine-hemisphere indirect bounce (hash-jittered, gated on `r_rt_bounces`) → exposure/gamma → rgba8 output, composited over raster via per-pixel alpha mask in `blendRT`.

What it does NOT do — and these are exactly the Remix deltas:

| Missing | Consequence in screenshots |
|---|---|
| No shadow rays / no light sampling | Lighting is still 100% baked lightmap. No contact shadows, no light from emissive surfaces. |
| No emissive light injection (emissive = `albedo × 0.8` self-glow only, `materialParams.x`) | q3dm17: launchpad/lamps glow in Remix and *light the floor*; ours is near-black. q3dm4: crosses/torches light walls in Remix; ours flat dark. |
| No specular reflection rays | Remix floor in q3dm4 has wet/glossy bounce; q3dm12 metal walls reflect slime glow. Ours: matte. |
| No PBR fields in `RTPrimitiveMaterial` (no roughness/metallic/normal/emissive map slots — only albedo + lightmap) | RT path can't shade like the raster PBR path, so even mix=1 looks like "raster re-rendered". |
| rgba8Unorm RT targets (`ensureRTTextures` ~4170), bgra8 backbuffer | Everything clips at 1.0 — no HDR, no bloom, the Remix "glow" look is impossible. Emissive intensity already clamped to 4.0 on raster side for the same reason. |
| Entity AS hit = debug grey gradient (~3633); `r_rt_entities` default 0 | Guns/pickups have no RT representation. |
| `blendRT` has no depth — `effectiveMix = mix × rt.a` (~3801) | **This is the gun bug**: viewmodel exists only in the raster target; RT primary ray hits the wall *behind* the gun with alpha=1, so at `r_rt_mix 1` the gun is overwritten by RT world. |
| No motion vectors; TAA is plain exponential accum | Ghosting; 1-bounce noise can't be integrated aggressively. |

Perf headroom (from CLAUDE.md baseline): RT trace 6.73 ms steady at 1032×774, total frame 14.7 ms @ 68 FPS on q3dm11. Roughly 7–8 ms of GPU budget available at 60 FPS target before cuts are needed.

## 2. Per-screenshot diagnosis

**q3dm4 (ours):** orange sky OK, geometry OK, but (a) flat-black shadowed areas — no fill light, envCube grey too dark for this scene; (b) the white translucent slab at the pillar base = fog boundary sheet drawing `q3ResolvedFogColor` fallback `float3(0.36)` grey (MSL ~1331) because the fog shader's `fogparms` resolved to black through the script path; (c) zero glow on the lit cross textures — emissive bound but LDR-clipped and not lighting neighbors.

**q3dm17 (ours):** map reads as void because the map's light is *all emissive surfaces* (launchpad rings, accent strips) and we have neither emissive-driven direct lighting nor bloom. The Remix shot is essentially "emissive triangles used as area lights + bloom". This map is the best testbed for the emissive-NEE work.

**q3dm12 (ours):** same story plus the solid white quad on the upper platform — fog-only pass surface drawn with `EnsureWhiteTexture()` (stub.c ~4951) where the fog color uniform is effectively white/unset; same root family as the q3dm4 white slab.

## 3. Prioritized roadmap

### P0 — Fix the two correctness bugs (small, do first)
1. **Fog color (task #19, already queued).** Root cause is upstream of the 0.36 fallback: `fogparms` parse (stub.c ~6687) yields (0,0,0) for these shaders, then `q3ResolvedFogColor` hard-codes grey. Fix: verify `ShaderMap_LookupEntry(fogs[fi].shader)` actually finds the fog shader at LUMP_FOGS resolve (~5057) and that the parse path the shader text takes (clean_frontend vs script) carries `fogColor`. Log `s_worldFogs[fi]` color at world load; compare against the `.shader` source. Remove/narrow the 0.36 fallback once real colors flow.
2. **Viewmodel/entity preservation under RT mix (the "guns + depthmaps" item).**
   - `rtKernel` writes hit distance to a second half-res `r32Float` texture (`Q3.RT.depth`).
   - Raster pass already has `sceneDepthTexture` (used by the fog ray-box).
   - `blendRT` gains both textures + invViewProjection: reconstruct raster world distance per pixel; if `rasterDist < rtDist - epsilon` (an entity/viewmodel is in front of the RT world hit), force raster. Viewmodel needs its depth-hack range un-warped — cheaper alternative: render a 1-bit entity mask in the entity pass (MRT or stencil readback) and let `blendRT` keep raster wherever the mask is set. The mask variant avoids depth-precision fights with `RF_DEPTHHACK` and is ~an afternoon of work; do mask first, distance compare later when RT entities land.

### P1 — Emissive-driven direct light + RT shadows (biggest visual payoff)
This is the single feature that makes the build read like Remix; q3dm17 goes from void to lit.
1. **Light list build (CPU, at world load + 30 Hz refresh alongside `buildRTPrimitiveMaterials`):** walk world draws whose material has emissive (PBR emissive path or `materialFlags.y`); collect triangles into an `RTLight { float3 centroid; float3 normal; float area; float3 radiance; }` buffer. Cluster per-surface (merge tris sharing a draw cmd) to keep the list O(100), not O(10k). Radiance from `emissive_intensity × emissive_color` in materials.json.
2. **Kernel NEE:** at each primary hit, pick 1 light (power-proportional CDF sample), sample a point on it, cast ONE shadow ray (`intersector.intersect`, accept-any semantics by just checking `type != triangle` for occlusion — full hit is fine on M4), add `radiance × NdotL × G / pdf`. That's +1 ray/pixel ≈ +2–3 ms at current trace res — fits budget.
3. **Sun/sky NEE for outdoor maps (q3dm4):** one shadow ray toward a sky direction when the sky is visible in the BSP (use `isSky` flag surfaces' average direction or a cvar `r_rt_sun_dir`). Gives the missing directional shadowing.
4. **Temporal accumulation does the denoising.** Bump TAA on by default for RT mode once motion is tolerable; optionally add a 3×3 edge-aware spatial blur on the RT target before blend (cheap, half-res).

### P2 — HDR + bloom (the "Remix glow")
1. Switch `rtTexture/rtAccumTexture/rtHistoryTexture` to `rgba16Float` (same code, format swap — they're private, no bgra constraint).
2. Composite stays in a 16F intermediate; add a tonemap (ACES or Reinhard) + threshold-downsample-blur-upsample bloom chain in `q3_postprocess` before the final drawable write. This also lets you remove the raster-side `intensity = min(raw, 4.0)` emissive clamp (MetalView emissiveParams) and the `saturate()` in `rtKernel`.
3. Raster path can keep bgra8 initially; do RT-mode-only HDR first to limit blast radius.

### P3 — RT specular reflections
1. Extend `RTPrimitiveMaterial` with `roughness, metallic` constants (already parsed into `q3_pbr_material_t`; stage struct already carries `pbrRoughness/pbrMetallic` — stub.c stage fields exist). No texture slots needed initially — constants cover the metalbridge/floor cases.
2. In kernel: when `metallic > 0.5 || roughness < 0.35`, cast one `reflect(rayDir, N)` ray, shade the hit with the same albedo×lightmap path (no recursion), Fresnel-weight into the result. Gate behind `r_rt_reflections` cvar, default on at half-res.
3. Roughness-aware: jitter reflection dir by roughness using the existing hash; TAA integrates it.

### P4 — Real RT entities (guns/pickups in the traced image)
Current entity AS path (`encodeEntityAccelerationStructureBuild` ~4038) builds geometry but shades debug grey — that's why `r_rt_entities` defaults off. Needs an entity-side `RTPrimitiveMaterial` table (mirror of the world one keyed off entity draw cmds) before enabling. Do AFTER P1–P3: the P0 mask fix already makes guns *look* right composited, and entity AS rebuild cost per frame is the perf risk on M4. When it lands, viewmodel shadows from P1 lights come free.

## 4. Suggested cvar additions

- `r_rt_lights` (P1, default 1 in RT mode), `r_rt_light_samples` (default 1)
- `r_rt_sun_dir` / `r_rt_sun_intensity` (P1.3)
- `r_rt_reflections` (P3, default 1), `r_rt_refl_roughness_max` (default 0.35)
- `r_rt_hdr` (P2, default 1 when `r_rt_mix > 0`)

## 5. Order of execution + rough effort

1. P0.2 entity mask in blend — ~0.5 day, unblocks all RT screenshots having guns
2. P0.1 fog color — ~0.5 day (investigation logged already, task #19)
3. P1 emissive NEE + shadows — 2–4 days incl. light-list plumbing + tuning; validate on q3dm17
4. P2 HDR/bloom — 1–2 days; validate on q3dm17 launchpad + q3dm4 crosses
5. P3 reflections — 1–2 days; validate on q3dm12 slime room metal walls
6. P4 RT entities — sized after P1–P3 perf re-baseline

Perf checkpoints after each stage: keep RT GPU ≤ 10 ms at 1032×774 on q3dm11 (currently 6.73 ms; P1 +2–3 ms, P3 +1–2 ms on reflective subset, P2 ~+0.5 ms bandwidth).
