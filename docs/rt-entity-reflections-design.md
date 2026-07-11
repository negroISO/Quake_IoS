# Stage56 RT entity reflections design

## Decision

Implement option **(i) first**: make entities visible to **secondary reflection rays only**.

Do **not** replace the existing `r_rt_preserve_entities` path in this stage. The primary camera view stays: RT world composite first, then raster entities/viewmodel/HUD draw over it. A new default-off cvar may build an entity acceleration structure and let the RT world's reflection ray test it, but primary RT rays must ignore entities unless the old debug `r_rt_entities` cvar is explicitly enabled.

Option (ii), full entity RT shading, is larger because it would have to replace the proven raster entity compositor, reproduce all Q3 entity shader semantics, solve alpha/additive/shell ordering, depth-hack viewmodel behavior, fog, dlights, PBR sidecars, denoise guides, and postprocess ordering. That is not a bounded spike.

## Existing state and failure history

Current RT entities are guarded by `r_rt_entities` (`CVAR_ARCHIVE`, default `0`) and `Q3_RTEntities()`. `encodeEntityAccelerationStructureBuild` early-bails when this is off; `RayTracingUniforms.fovParams.w` also gates primary entity hits so the kernel cannot sample a stale entity AS. CLAUDE.md records why it stays off: the AS path shades entities as debug grey and creates white halos/ghost silhouettes around weapons and pickups when the RT result is composited with the preserved raster entity layer.

The old failure was not the AS build itself. The missing pieces were:

- no entity material table in `rtKernel` (primary hits use a grey distance proxy);
- no classic entity texture/PBR binding for entity triangles;
- no alpha/additive/entity-shader semantics in the RT entity branch;
- primary visibility competed with the separate raster-preserved entity layer, so the RT composite produced halos/silhouettes before the raster entity pass.

The secondary-only design avoids the composite interaction: primary camera rays continue to shade the world only, and preserved raster entities still own the visible weapon/pickup pixels. Reflected rays can hit the entity AS and return a bounded approximation color to reflective world materials.

## Entity AS lifecycle

Animated MD3 vertices are CPU-expanded each frame into the existing entity vertex/index buffers (`Q3MetalRenderer_GetEntityVertices`, `Q3MetalRenderer_GetEntityIndices`) and uploaded by `uploadEntityBuffers`. The current `encodeEntityAccelerationStructureBuild` already builds a primitive AS from those per-frame buffers.

For Stage56, use **per-frame rebuild**, not refit:

- MD3 animation changes vertex positions every frame; refit only helps if topology and bounds are stable enough and if the AS was built with update/refit usage from the start.
- The existing code has no persisted per-entity BLAS instances; it has one flat per-frame entity mesh buffer, so a rebuild is the bounded path.
- Typical Q3 scenes have only a few thousand entity vertices and tens of draw commands. Existing logs show entity frames around ~3.5k-4.4k vertices and ~12k-14k indices in normal scenes; worst fights can be higher but still far below world BSP size.
- Guardrail: cvar default off; on Catalyst medium, if sustained fps cost is >15%, leave off and report. iPhone is smoke only.

Later optimization, if needed: split stable/static inline brush entities vs animated MD3s, build/update BLAS per entity, and instance them into a top-level AS. That is not required for the spike.

## Material binding for the spike

Keep the existing `RTTexTable` size. Do **not** add another texture array in this spike.

Plan:

1. Build a small per-frame `RTEntityPrimitiveMaterial` buffer parallel to entity AS primitive IDs.
2. For each opaque entity draw range, map `firstIndex/indexCount` triangles to:
   - classic entity texture handle;
   - entity vertex color / `entityColor` tint fallback;
   - flags for invalid / alpha-sensitive future use.
3. Reuse spare slots in the existing `RTTexTable.albedo[176]` table:
   - world slots stay fixed by `buildRTPrimitiveMaterials`;
   - entity handles are appended only into unused zero slots;
   - if no spare slot exists, the entity primitive falls back to vertex/tint color instead of evicting world materials.
4. Bind entity vertex/index buffers and the entity primitive-material buffer to `rtKernel` at new buffer indices after the existing world/emissive bindings.
5. Reflection shading samples classic albedo from the slot when present and multiplies by a barycentric entity-vertex color blend. For the spike, lighting is an approximation: a small ambient floor plus normal-facing/camera/specular-reflection bias. Full PBR sidecars, dlights, shell passes, and exact Q3 rgbGen/alphaGen parity are explicitly deferred.

This keeps the world RT material table stable and avoids a table-size change. It also gives a clean bounded fallback when entity textures are not among the spare slots.

## Kernel behavior

Use `RayTracingUniforms.fovParams.w` as an entity-AS mode without changing struct layout:

- `0`: no entity AS use;
- `1`: legacy `r_rt_entities` primary-debug mode only;
- `2`: new secondary-reflection-only mode;
- `3`: both, for diagnostics.

Primary ray branch:

- only uses `entityAS` when mode is `1` or `3`;
- mode `2` ignores entity primary hits, preserving `r_rt_preserve_entities` compositing exactly.

Reflection branch:

- when mode is `2` or `3`, intersect the reflection ray against both world AS and entity AS;
- choose the closer hit;
- world hit uses existing world reflection shading;
- entity hit uses `RTEntityPrimitiveMaterial` + entity buffers for classic albedo/tint shading;
- no alpha/additive entity passes in the initial spike except opaque draws, reducing square/halo risk.

## Performance estimate and guardrails

Expected cost when `r_rt_entity_reflections=1`:

- CPU/GPU AS build every RT frame from current entity buffers: small on quiet maps, variable during combat.
- One additional AS intersection only for reflective world hits, not for every primary ray. Cost scales with `r_rt_reflections`, reflective material coverage, and trace resolution.
- Per-frame entity primitive-material buffer build is linear in entity draw/triangle count and should be much smaller than world RT material refresh.

Guardrails:

- default remains off (`r_rt_entity_reflections 0` = exact no-op; no AS build for this feature);
- no default flips to `r_rt_entities`, `r_rt_reflections`, denoiser, postprocess, or preserve-entities;
- Catalyst medium acceptance target: <=15% fps cost. If above, keep off and document honestly;
- iPhone UUID `1EED792C-F233-511F-8DBD-15A47EC570A3` only for smoke; do not touch iPad;
- Stage54 denoiser behavior must stay unchanged: Catalyst remains on legacy denoise path when `r_rt_denoise 1`, iPhone keeps MetalFX path.

## Tractability verdict

Option (i) is tractable as one bounded increment because the repository already has:

- entity vertex/index upload buffers;
- an entity AS build function;
- per-draw entity texture handles and ranges;
- an RT texture argument table with likely spare albedo slots;
- an existing one-bounce reflection branch where entity-AS testing can be inserted.

Proceed with a cvar-gated spike, default off, secondary rays only.
