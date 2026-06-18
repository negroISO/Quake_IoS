# CODEX BRIEF — remaining work after atlas/rgbConst round (2026-06-11)

Repo: ~/Documents/Quake_IoS_Phase9_Fork (NOT ~/Documents/Quake_IoS). Working
tree is shared with Claude — `git diff` before editing; do not revert
uncommitted changes. Build check: `xcodebuild -project Quake3-iOS.xcodeproj
-scheme Quake3-iOS -destination 'generic/platform=iOS' -configuration Debug
-derivedDataPath build-device-rt build`. MSL is runtime-compiled — validate by
extracting `shaderSource` and the `makeRTLibrary` string from MetalView.swift
and compiling with `xcrun metal -target air64-apple-ios18.0 -std=metal3.0 -c`
(prepend `#include <metal_stdlib>` to the RT string).

## ALREADY DONE — do not redo
- FX atlas override (worldTextureSelectionForPBRDebug) — Codex, landed.
- RT kernel atlas remap (RTPrimitiveMaterial.spriteAtlasParams) — Codex, landed.
- rgbConstColor/alphaConst passthrough, both world sites — Claude, landed.
- pbrSpriteAtlasParams(logEnabled:) log-poison fix — Claude, landed.
- envCube grey/stem invalidation — exists for months of log-proof; DROPPED from diagnosis.
- RT lights/shadows (top-2 deterministic), reflections, parallax, dlight injection — landed, pending device verify.

## TASK 1 — materials.json emissive hygiene (data, ~30 min)
12 entries point `emissive` at albedo/normal DDS (e.g. `machinegun.a.rtex.dds`,
`plasma.a.rtex.dds`, `rocket.a.rtex.dds`, `shotgun.n.rtex.dds`). Runtime guard
already skips them; clean the data: for each `[Q3-PBR-SWIFT] suspicious
emissive path` name in the latest q3_diag.log, edit
Resources/baseq3/pbr/materials.json — if a real `*_emissive*.e.rtex.dds`
exists in assets/ingested for that hash, point to it; else set the field null.
Do NOT touch any other field. Verify: rebuild, run, zero `suspicious emissive`
lines.

## TASK 2 — two corrupt capture DDS (code or data, ~30 min)
`baseq3/pbr/capture_textures_dds/02C12E76E6B809A7.dds` and
`A3E896158424164C.dds` fail both MTKTextureLoader and the tolerant reader.
Inspect headers (first 148 bytes). If dxgi format ≠ 28, extend
`loadCaptureFormatDDS` for that format ONLY if trivial (e.g. BGRA 87);
otherwise add the two hashes to a skip-set so the load-FAILED log noise stops.

## TASK 3 — normal map atlas remap (MSL, small)
In `q3_world_fragment` the generic `worldNormalMap` sample uses `nmUV =
in.texCoord * 0.5` and material normal maps sample pre-remap UV — animated
atlas materials get wrong normals. Fix: sample material normal maps with the
SAME `texCoord` after the atlas/parallax mutation (it already is for
roughness/metallic — verify the normal sample site reads the mutated
`texCoord`, not `in.texCoord`/`nmUV`, when the material normal is bound).
Generic fallback nmUV path stays as-is. Validate MSL offline before building.

## TASK 4 — reflection-ray atlas/tcMod parity (MSL, small)
In `rtKernel`'s reflection-hit shading (the `rh` block), the hit albedo is
sampled without tcMod/atlas. `rmat.spriteAtlasParams` and `rmat.tcMod*` are
available — apply the same sub-rect remap (and tcMod loop, reuse
`rtApplyTcMod`) before sampling `ralb`. Keeps mirrors of animated surfaces
animated.

## DO NOT
- Re-derive RT lights or change the top-2 selection without device perf data.
- Force envmapyel/envmapgold/envmapbfg pickup chrome animation (single-frame
  capture DDS; needs asset re-ingestion, not code).
- Reorder ANY uniform/material struct fields — append-only, Swift+MSL lockstep.
- Start HDR/bloom or RT entity materials (P2/P4) — owner decision pending
  device verification of the current build.
- Install to device while another `devicectl device install` is running
  (`pgrep -f "devicectl device install"` first; bundle is 7.5 GB, ~50 min).

## Verification greps (after owner runs the new build)
grep -E "world-atlas params|RT] light set|suspicious emissive|DDS load FAILED" /private/tmp/q3rt_logs/q3_diag.log
Expected: nonzero atlasTime, lights=N per map, zero suspicious-emissive, zero
(or skip-listed) DDS failures.
