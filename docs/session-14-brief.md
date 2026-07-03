# Session 14 — perf(rt): skip accumulate pass when RT TAA is disabled

Workspace: `/Users/targus/Documents/Quake_IoS_Phase9_Fork` · Branch: `metal-renderer-fresh` · HEAD at brief time: `59b1a324`
Source of finding: audit Phase 8 P2 (confirmed against source 2026-07-01).

> Read only this section for Session 14. The full roadmap at the bottom is human reference and is NOT required to execute this session.

## Objective
When `r_rt_taa` is off (the default — `Q3_RTTAA()` returns `"0"`), skip the `Q3.RT.accumulate` compute dispatch and bind `rtTex` directly into the blend pass. Removes one full-screen compute dispatch + texture read/write **every RT frame on the default path**, with zero visual change.

## Scope (do not expand)
- `Quake3-iOS/MetalView.swift`, function `encodeRTOverlay` only.
- No C changes. No struct-layout changes. No new cvar (`r_rt_taa` already exists, stub.c ~L5789 / `Q3_RTTAA()` ~L5584).

## Read Only
- `Quake3-iOS/MetalView.swift` — `encodeRTOverlay` region ~L5580–5840 (locate by labels, not raw line numbers).
- Reference only (do not edit): `accumulateRT` / `blendRT` kernels ~L4711–4760.

## Ignore
networking · audio · UI · all other audit findings (they are later sessions).

## Exact change
`rtTAAEnabled` is already computed near the top of `encodeRTOverlay` (`let rtTAAEnabled = Q3_RTTAA() > 0.5`, ~L5588).
1. Wrap the accumulate encoder block (anchor `enc.label = "Q3.RT.accumulate"`, ~L5744–5752) in `if rtTAAEnabled { … }`.
2. At the blend input bind (anchor `enc.setTexture(accumTex, index: 0)`, ~L5784) change to `enc.setTexture(rtTAAEnabled ? accumTex : rtTex, index: 0)`.
3. Leave `accumAlpha` (~L5743) and the already-gated `Q3.RT.copyAccumToHistory` blit (`if rtTAAEnabled`, ~L5767) unchanged.

Correctness note: when TAA is ON but history is invalid (first frame), `accumAlpha` is forced to 1.0 and the accumulate pass must still run — that path is unchanged. Only the TAA-OFF branch skips the dispatch.

## Required ddemby RAG searches (run first if brain online; skip if unavailable)
1. `RT accumulate TAA copyAccumToHistory gate` — recover the 2026-06-10 note that gated the history blit (same code region; confirms intended follow-up).
2. `blendRT rtTex accumTex blend input binding` — confirm no other consumer reads `accumTex` when TAA off.
3. `r_rt_taa default off smear` — confirm default-off rationale so validation baseline is TAA-off.

## Validation (acceptance criteria — all must pass)
- Builds clean: Catalyst + iphoneos, `BUILD SUCCEEDED`.
- Run `r_rt_mix 1` with `r_rt_taa 0` on q3dm1: screenshot is **pixel-identical** to a pre-change capture from the same `setpos`.
- GPU Frame Capture with `r_rt_taa 0`: encoder list contains **no** `Q3.RT.accumulate`; with `r_rt_taa 1` it reappears.
- `[RT] metrics … gpuCommandMs=` line is equal-or-lower with TAA off (expect a small drop).
- `r_rt_taa 1` still renders correctly (temporal accumulation/smear behaves exactly as before).

## Stop conditions
Stop after ONE commit once all acceptance criteria pass. If the TAA-off capture is not pixel-identical, revert and stop — do not attempt a second unrelated fix.

## Commit message
`perf(rt): skip accumulate pass when RT TAA is disabled`

## Estimated diff size
~10–20 lines, 1 file.

## Next session after completion
Session 15 — `fix(rt-materials): make RT material signature match the material builder` (audit Phase 6 P2). `rtWorldMaterialSignature` (~L5048) hashes stage 0 only; `rtRepresentativeStage`/`buildRTPrimitiveMaterials` (~L4880/L4830) deliberately select a non-stage-0 representative and consume alpha/tcMod/PBR/atlas/lightmap-slot data the signature ignores → stale RT table after shader/PBR/map changes.

---

## Full roadmap (human reference — 11 confirmed findings → 8 deduped sessions)

Findings were validated against the checkout (not just the reports). Dedup: audit Phase 3 P1 and Phase 7 P1 are the **same** shared-buffer fence issue (one session). Audit Phase 9 led with the video fix — **demoted** here: it is diagnostic-only and CLAUDE.md documents a *second* unaddressed Catalyst AVI defect (channel-swap/blocky), so fixing the 1920×1080 cap alone does not yield a usable capture.

Findings are essentially independent (no hard code coupling), so ordering is by risk↑ / value, establishing the build→screenshot→counter loop on the safest change first, then the one real correctness landmine mid-plan with heaviest validation.

| Session | Work item | Audit ref | Risk | Why here |
|---|---|---|---|---|
| 14 | Skip accumulate when TAA off | P8·P2 | very low | default-path perf, isolated, zero visual change — establishes the loop |
| 15 | RT material signature ↔ builder parity | P6·P2 | low | isolated correctness (stale table); one function |
| 16 | In-flight fence/ring for shared dynamic buffers | P3·P1 + P7·P1 | **high** | the only real correctness landmine (GPU-in-flight race, currently masked); invasive → do after loop is trusted |
| 17 | Exclude alpha/blend prims from RT AS + counters | P4·P1 | med | RT visual correctness; needs screenshot diffing |
| 18 | Async world AS build (drop draw-path `waitUntilCompleted`) | P5·P1 | med | load-hitch only (one-time, generation-gated); pairs with 16's lifecycle work |
| 19 | Async env-cube mip generation | P8·P3 (wait) | low | load-hitch; also fixes the twin wait in `tryBuildMapSkyboxCube` |
| 20 | Static world VBO/IBO + immutable textures → private storage | P8·P3 | low | **weakest-justified**: "bandwidth" rationale is a discrete-GPU argument; on M4 unified memory the real win is texture tiling/compression, modest |
| 21 | Video capture dimension-safety | P2·P1 | low | diagnostic-only; blocked by 2nd AVI defect — fix both or defer |

Notes carried from verification:
- **P6·P1 (RT entities = grey/distance proxy, L4303)** is real but the audit's short-term fix (debug-gate off by default) is **already shipping**: `Q3_RTEntities()` defaults 0 and `encodeEntityAccelerationStructureBuild` early-returns (L5075). No session needed until the long-term entity material table is scoped — track as a feature, not a bug.
- **Phase 1 P2 (single-file / layout asserts)** is hygiene, not a bug. Optional cheap insurance: add `MemoryLayout<T>.stride` static-asserts for `RayTracingUniforms` / `RTPrimitiveMaterial` before Session 16 (which touches frame lifecycle) — fold into 16 or a 30-min standalone.
- Sessions 14–15 and 19–21 carry no meaningful regression risk; 16 is the one to schedule when there's time for full device + Metal API-validation passes.
