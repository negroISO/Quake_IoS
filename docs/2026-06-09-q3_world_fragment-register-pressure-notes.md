# `q3_world_fragment` register-pressure & redundancy scan — fact-finding

**Date**: 2026-06-09
**Source**: `Quake3-iOS/MetalView.swift` lines 2066-2469 (~400 line MSL fragment)
**Target hardware**: Apple A17 / M4 (TBDR, FP32 register file)
**Context**: Frame ALU is the current bottleneck on iPad M4 q3dm11 (~15,344 world draws/frame).
**Method**: External MSL review by Gemma-4-31b (LM Studio, ~15s, 738 completion tokens), then manually verified against actual source. Line numbers below are real MetalView.swift line numbers.

> **No code changes made.** This is for the follow-up workstream.

---

## CONFIRMED — high-confidence findings

### 1. Five `dfdx/dfdy(in.worldPos)` pairs in one fragment
All five duplicate the same derivative pair (`dfdx(in.worldPos)` + `dfdy(in.worldPos)`):

| Line | Context | Reachable when |
|---|---|---|
| 2106-2107 | tcGen-env normal fallback | tcGenMode==1 AND vertex normal degenerate |
| 2203-2204 | fog-cap orientation fallback | fogOnly>0.5 AND fog cap path AND vertex normal degenerate |
| 2291-2292 | dlight normal fallback | not additiveStage AND vertex normal degenerate |
| 2324-2325 | normal-map fallback | normal-map bound AND vertex normal degenerate |
| **2331-2332** | **TBN basis (unconditional)** | **whenever a normal map is bound** |

- 2324-2325 and 2331-2332 are inside the same `!is_null_texture(worldNormalMap)` block — when the vertex-normal fallback fires here, the derivatives are computed twice for the same fragment, then the TBN computes them a third time at 2331.
- The other three live in mutually-exclusive branches, so they don't redundantly co-fire.
- **Idea (later)**: in the normal-map block, compute `float3 dp1 = dfdx(in.worldPos); float3 dp2 = dfdy(in.worldPos);` once at the top of the `!is_null_texture(worldNormalMap)` block (line 2318), then reuse for both the N-fallback (2324-2326) and the TBN derivation (2331-2342). Saves one redundant `dfdx/dfdy` pair on the degenerate-normal fast path.

### 2. Four `int(drawUniforms.tcModType.X + 0.5)` conversions held live
Lines 2128-2131:
```msl
if (modCount > 0) texCoord = applyTcMod(..., int(drawUniforms.tcModType.x + 0.5), ...);
if (modCount > 1) texCoord = applyTcMod(..., int(drawUniforms.tcModType.y + 0.5), ...);
if (modCount > 2) texCoord = applyTcMod(..., int(drawUniforms.tcModType.z + 0.5), ...);
if (modCount > 3) texCoord = applyTcMod(..., int(drawUniforms.tcModType.w + 0.5), ...);
```
- All four conversions are computed inline. Compiler can't see that `tcModType.x/y/z/w` are dead after each `applyTcMod` call.
- **Idea (later)**: `int4 tcModTypes = int4(drawUniforms.tcModType + 0.5);` once before the chain; access `.x/.y/.z/.w`. Same trick as `rgbGen`/`alphaGen`/`blendMode` at lines 2081-2083.

### 3. `pow(1.0 - NdotV, ...)` called twice with different exponents
Lines 2425 (`pow(1.0 - NdotV, 5.0)` for Fresnel) and 2449 (`pow(1.0 - NdotV, 1.35)` for fresnelGate).
- The input `(1.0 - NdotV)` is shared, the exponent differs.
- **Idea (later)**: `float oneMinusNdotV = 1.0 - NdotV;` hoisted. `pow` itself isn't shareable across different exponents, but the load is.

### 4. PBR IBL block (2393-2457) is a heavy live-state region
Variables alive across this gated block:
- carried in from outside: `lit`, `worldN`, `pbrWorldParams`, `texCoord`, `in.worldPos`, `uniforms.cameraPos`
- created inside: `V`, `NdotV`, `roughness`, `metallic`, `maxMipF`, `diffuseIBL`, `R`, `specMip`, `specularIBL`, `F0`, `F_v`, `kD_v`, `ambBoost`, `specBoost`, `litLuma`, `shadowMask`, `fresnelGate`, `fillScale`, `specMask`

- Roughly ~18 float/float3 values live across ~65 lines.
- Two `envCube.sample()` calls at 2418 and 2421 issue mip-level fetches — latency overlap matters here.
- Compiler likely keeps `lit` live through this block (needed for F0 mix at 2423 AND for the final accumulation at 2454-2456).

---

## VALIDATED — but lower payoff

### 5. `texCoord` has very long live range (~330 lines)
Computed at line 2080, mutated through line 2155 (sprite atlas remap), used at:
- 2161 `colorTexture.sample`
- 2409 `roughnessMap.sample`
- 2412 `metallicMap.sample`
- 2465 `emissiveTexture.sample`

It's a `float2` (8 bytes / 2 regs), so probably tolerable. But if all four texture samples could be hoisted together via the same UV, the texCoord stays loaded longer for less peak pressure. The current structure already does this — the issue is each sample is gated by separate `is_null_texture` checks, so the compiler may pessimistically keep texCoord live in case any branch fires.

### 6. Debug-mode early returns (lines 2163-2178)
Gemma flagged these as divergence — but `mode` comes from `drawUniforms.debugMode` which is uniform across a draw (and almost always 0). Branch is fully predicted, so no real divergence cost. **Not a concern**.

---

## REJECTED / Gemma was wrong

### 7. Gemma claimed `colorTexture.sample` is "wasted on discarded pixels"
False. Alpha-test discard (lines 2240-2244) reads `texel.a`, so the colorTexture sample **must** precede the discard. Cannot defer.

### 8. Gemma flagged samples inside `if (_pad0 > 0.5)` as wasteful
Lightmap sample at 2281 is correctly gated — `_pad0` is the "combined base+lightmap fast path" enable; samples that aren't needed don't fire. **Not a concern**.

---

## Worth investigating next session (not from Gemma)

### 9. `length(N) > 1e-4` test repeated 5 times for the same `in.worldNormal`
Lines 2102, 2196 (fog), 2290 (dlight), 2323 (normal-map block N init).
Could be replaced with `float nLen = length(in.worldNormal); bool nValid = nLen > 1e-4; float3 N = nValid ? in.worldNormal / nLen : ...` computed once at top of function, then reused. **But**: each branch is mutually exclusive at runtime (only one fog or dlight or normal-map code path will execute for a given draw), so cost is one length per fragment plus a register being live across the function. The win is small and may not be net positive.

### 10. `if (!is_null_texture(roughnessMap))` and `if (!is_null_texture(metallicMap))` inside the IBL gate (lines 2408, 2411)
Roughness and metallic samples both use the SAME `texCoord`. If both maps are bound (the common PBR case), there's no win to combining — they're separate textures. But the texCoord UV being held live across both is fine because `texCoord` is just 8 bytes.

### 11. Two `envCube.sample(envSampler, ..., level(...))` calls back-to-back at 2418 and 2421
Same texture, same sampler, different mip-level argument and different direction. These CANNOT be merged. Apple's TBDR pipeline should pipeline them automatically. **Probably no win available**.

---

## Estimated wins if all "Idea (later)" items applied

Rough order-of-magnitude (no measurement yet):

- **Tier 1 (likely measurable)**: Item 1 (single `dp1/dp2` in normal-map block) + Item 2 (single `int4 tcModTypes` hoist). Saves a handful of ALU + reduces compiler-perceived live ranges for `tcModType.*`. Optimistically 1-3% fragment ALU reduction on q3dm11 average — modest, but cheap to apply and code becomes clearer.
- **Tier 2 (uncertain)**: Item 4 (refactor IBL block to reduce live-state). Probably needs an actual GPU trace + Apple Instruments "Register Pressure" panel before/after to validate. Could be 0% or could be 5-8% if compiler is currently spilling.
- **Tier 3 (not worth pursuing yet)**: Items 5-11. Either small wins or no path to win.

## Verification tools needed before applying

- Xcode → Debug → Capture GPU Frame → select world draw → Shader Profiler → look at the **Register Allocation** field for `q3_world_fragment`. Cap is 32 registers on M4 — if we're at 28+, spills are likely.
- Or: `xcrun metal -frontend -O2 -emit-asm` on the compiled `.metallib` to inspect spill counts directly.

## Source attribution

This document combines:
- Gemma-4-31b structural scan (LM Studio, 738 tokens, ~15s wall-clock) — finding candidates
- Manual line-number verification + REJECTED findings — Claude
- Independent items 9-11 — Claude

External-model time: ~15s. Estimated equivalent token budget if done in main Claude session: ~5-8k tokens of source review.
