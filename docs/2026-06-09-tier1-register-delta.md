# Tier-1 register-pressure patches — measurement results

**Date**: 2026-06-09 evening session
**Patches measured**: 4 edits to `q3_world_fragment` in `MetalView.swift`
1. Hoist `dp1`/`dp2` (`dfdx/dfdy` of `worldPos`) above the N-validity check inside the `worldNormalMap` block
2. Pre-compute `int4 tcModTypes = int4(drawUniforms.tcModType + 0.5)` once before the 4-branch `applyTcMod` chain
3. Hoist `oneMinusNdotV = 1.0 - NdotV` for the Fresnel `pow(_, 5.0)`
4. Hoist `oneMinusNdotV` reuse for the `fresnelGate = pow(_, 1.35)`

## Measurement methodology

Native GPU register count is not exposed via any CLI tool — Apple keeps the GPU ISA undocumented and only Xcode's runtime Shader Profiler shows it. Instead, used AIR (LLVM IR) as a proxy:

- Extract the inlined MSL string from `MetalView.swift` lines 1245-3183 → `world.metal`
- Compile: `xcrun metal -target air64-apple-ios18.0 -O2 -ffast-math world.metal -o world.metallib`
- Disassemble: `xcrun metal-objdump --disassemble world.metallib > world.air.ll`
- Per-function AIR stats: total lines, max SSA vreg ID, instruction count, function calls, branches, phis, loads, stores, fmuls, fadds

Harness: `scripts/shader_register_audit.sh`. Run with env `LABEL=<name>` to persist `scripts/shader_dump/world_stats_<name>.json`.

## Result

`q3_world_fragment` AIR stats:

| Metric | Baseline (pre-patch) | Patched | Δ |
|---|---|---|---|
| Lines | 948 | 948 | **0** |
| Max SSA vreg | 741 | 741 | **0** |
| Instructions | 724 | 724 | **0** |
| Function calls | 105 | 105 | **0** |
| Branches | 89 | 89 | **0** |
| Phis | 30 | 30 | **0** |
| Loads | 43 | 43 | **0** |
| FMul | 97 | 97 | **0** |
| FAdd | 30 | 30 | **0** |

JSON snapshots: `scripts/shader_dump/world_stats_baseline.json` and `world_stats_patched.json` are **byte-identical**.

## Conclusion

**The Tier-1 patches do not change the optimized AIR.** LLVM at `-O2` already performs:

1. **CSE on `dfdx`/`dfdy` of the same input** — multiple `dfdx(in.worldPos)` calls collapse to one; the manual hoist gives the optimizer no new information.
2. **SLP/vectorization of the 4 `int(... + 0.5)` chain** — the compiler fuses the four scalar conversions into a single vector form, equivalent to our manual `int4 tcModTypes` hoist.
3. **CSE on `1.0 - NdotV`** — both `pow()` calls share the input expression after CSE.

This is a **negative result on the perf hypothesis**, but a **positive result on the toolchain**: the harness works, can be re-used for any future shader change, takes ~3 seconds to run, and provides a reproducible before/after.

## What the patches still buy us

- **Readability** — intent is explicit ("we have one Fresnel input, two consumers"; "tcMod chain takes 4 indices, here's the vector").
- **Insurance against future changes** — if someone modifies the function and accidentally introduces something that breaks LLVM's CSE (e.g., adds a `volatile` qualifier, adds a side-effect call between two CSE candidates), the manual hoist still pays off.
- **No cost** — the patched AIR is byte-identical to baseline, so we are not paying anything to keep them.

**Recommendation: keep the patches in.** They are documentation as code.

## What this means for Tier 2

The Tier-2 candidate was the IBL block live-state refactor — ~18 float/float3 values live across ~65 lines. If LLVM's optimizer is this good at register pressure on the Tier-1 stuff, the Tier-2 win is likely also smaller than the original Gemma analysis suggested. The right next step is **not** another speculative refactor; it's **a real GPU trace** (Xcode Shader Profiler → Register Allocation field on `q3_world_fragment` for an actual world draw) to learn whether we're at the register cap (32 on M4) or comfortably below it.

If the profiler shows we're at 28+ registers (spill territory), Tier-2 is worth attempting. If we are at 18-22, leave it alone — the function is fine.

## What worked vs. what didn't this session

- ✅ `tmc/gputrace` CLI exists at `~/go/bin/gputrace` but **does not parse Xcode 16+ flat-store traces** (looks for legacy `unsorted-capture/` directory). No `stats`/`kernels`/`insights` output from `/Users/targus/Documents/Q3_RT.gputrace`.
- ✅ `xcrun metal-objdump --disassemble` produces AIR (LLVM IR), not GPU ASM — Apple's GPU ISA is not exposed via CLI.
- ✅ AIR vreg/instruction count is a usable proxy for register pressure when measuring optimization effectiveness.
- ✅ `scripts/shader_register_audit.sh` is the reusable harness.
- ❌ Manual hoists are not a measurable win on this compiler — LLVM is doing the work already.

## Files

- `scripts/shader_register_audit.sh` — the audit harness
- `scripts/shader_dump/world.metal` — extracted MSL source
- `scripts/shader_dump/world.metallib` — compiled metallib
- `scripts/shader_dump/world.air.ll` — disassembled AIR (5,115 lines)
- `scripts/shader_dump/world_stats_baseline.json` — baseline numbers
- `scripts/shader_dump/world_stats_patched.json` — patched numbers (byte-identical to baseline)
