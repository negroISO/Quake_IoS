# Overnight handoff — 2026-06-09

## TL;DR

- ✅ **Critical RT compile-blocker fixed** — removed `i.force_opaque(true)` and `i.assume_geometry_type(...)` from `rtKernel` MSL. Those don't exist on the iOS Metal toolchain shipping with iPad M4 and were causing the RT library to fail compile every frame (see `gpuframe_console.txt` lines 5045-5575). RT mix mode was effectively dead until this fix.
- ✅ **Simulator build clean** — `xcodebuild -destination 'iPad Pro 13-inch (M5)' build` finished with `** BUILD SUCCEEDED **`, zero warnings, zero errors.
- ⚠️ **Tier-1 register-pressure patches do not change the optimized AIR** — byte-identical IR before/after for `q3_world_fragment`. Verified via new `scripts/shader_register_audit.sh` harness + independent confirmation from Gemma-4-31b. The patches are kept as **documentation-of-intent** (zero cost, future-regression insurance) but they were NOT a perf win. Details: `docs/2026-06-09-tier1-register-delta.md`.
- ⚠️ **`.gputrace` analysis path is GUI-only** — `tmc/gputrace` CLI does not parse Xcode 16+ flat-store traces. For runtime register count on this trace, must open in Xcode Shader Profiler.

## What was changed this session

### 1. `code/Quake3-iOS.swift` (MetalView.swift) — RT compile fix
Reverted the 2026-06-09 Phase 1 attempt to add intersector hints:
```diff
-                // 2026-06-09: force_opaque + assume_geometry_type let the
-                // GPU skip any-hit/anyhit-shader paths and assume only triangles.
                 intersector<triangle_data> i;
-                i.force_opaque(true);
-                i.assume_geometry_type(geometry_type::triangle);
                 auto hit = i.intersect(r, worldAS);
```
The replacement comment block in source records that these methods exist on macOS Metal 3.x but not in the iOS toolchain we build against — revisit if Apple ships them. CLAUDE.md was updated to reflect the deferred state.

### 2. `scripts/shader_register_audit.sh` — new harness
Compile MetalView's inlined MSL via `xcrun metal -target air64-apple-ios18.0 -O2 -ffast-math`, disassemble with `metal-objdump`, parse the AIR (LLVM IR) per-function for instruction count, max SSA vreg ID, function call count, branch/phi count, loads/stores, fmul/fadd counts. Persists JSON to `scripts/shader_dump/world_stats_<label>.json`. Re-usable for any future shader change.

### 3. `docs/2026-06-09-tier1-register-delta.md` — measurement report
Documents the methodology, the byte-identical result, what works vs. doesn't work in the toolchain, and the Tier-2 implication: do not pursue speculative refactors until we have a real GPU trace showing we're at register cap.

### 4. `docs/2026-06-09-q3_world_fragment-register-pressure-notes.md` (already shipped earlier in session)
The original Gemma-driven fact-finding scan that proposed the patches.

## Independent verification — Gemma-4-31b sanity check

Gemma was asked four targeted questions about the surprising "AIR-byte-identical" result. Verbatim (saved at `/tmp/gemma_lm_review_response.md`):

> **A)** Yes, this is expected. `dfdx`/`dfdy` are treated as pure intrinsics (essentially reading from a constant buffer of quad-derivatives). LLVM's Common Subexpression Elimination (CSE) and Global Value Numbering (GVN) will aggressively hoist these if the input operand hasn't changed.
>
> **B)** It is likely SLP vectorization or simple scalar-to-vector promotion. Since `drawUniforms` is already a vector type, LLVM sees four identical operations on contiguous components and collapses them into a single SIMD instruction (or a sequence of vreg moves) during the optimization passes.
>
> **C)** If the AIR (Apple Intermediate Representation) is byte-for-byte identical, the downstream GPU compiler receives exactly the same input. While the GPU backend performs its own register allocation and scheduling, it is deterministic. Identical AIR → Identical ISA.
>
> **D)** **Keep them.** Manual hoists serve as "documentation of intent" for future maintainers. Since you've verified they are no-ops via disassembly, there is zero performance penalty, but they prevent future regressions if someone modifies the block in a way that breaks LLVM's CSE patterns.

5 seconds wall-clock, 254 tokens. Conclusion consistent with the empirical measurement.

## What did NOT get done

- **Path A (Xcode Shader Profiler runtime register count)** — requires GUI interaction. Saved for you to do in the morning if you want a hard ground-truth number.
- **No on-device deployment of the patched/fixed build** — would have to run `scripts/q3dev_run.sh` against the iPad which is presumably not at your desk. Simulator build is verified clean.
- **No Tier-2 IBL block refactor** — explicitly deferred until we have a runtime register-count measurement.

## Recommended next-morning queue

1. **Deploy & verify RT runtime** — push the patched build to the iPad (`scripts/q3dev_run.sh` against q3dm11), grep `q3_diag.log` for absence of `[RT] library compile failed` lines. The force_opaque fix means RT mix mode should actually work now.
2. **Open `Q3_RT.gputrace` in Xcode** — Show GPU Profiler → drill into a world draw → Shader Profiler → read the **Register Allocation** field for `q3_world_fragment`. This is the hard number we need to know whether Tier-2 has any payoff. Screenshot or paste back.
3. **If Register Allocation < 24** — Tier-2 is dead, move on to other workstreams (RT primitiveMaterials prealloc, encoder coalescing, JSON DDS audit per Phase 2 backlog).
4. **If Register Allocation ≥ 28** — Tier-2 (IBL block live-state refactor) is worth attempting. Use the same `shader_register_audit.sh` harness to verify the candidate change doesn't bloat AIR before deploying.
5. **Capture a fresh `.gputrace` post-RT-fix** — should be smaller (no longer crashing the RT library); will let us actually see if any of the suggested register/ALU bottlenecks materialize when RT is active.

## Toolchain notes for future work

- `~/go/bin/gputrace` (tmc/gputrace) only parses **legacy** `.gputrace` bundles. Xcode 16+ saves a flat-store format that the CLI rejects. No `convert` subcommand exists.
- `metal-gpu-debug/scripts/parse_gputrace.py` reads bundle metadata only; can't crack `store0` blob.
- `xcrun metal-objdump --disassemble` produces AIR (LLVM IR), **not** native Apple GPU ASM. Native ISA is undocumented and only exposed by Xcode Shader Profiler at runtime.
- The AIR proxy works fine for **detecting** redundant work the compiler missed — but our session shows LLVM doesn't miss much at `-O2` on simple cases like these.
- Simulator builds use Metal compilation but **do not run shaders on real Apple GPU hardware** — Metal-on-simulator is a software path. Don't conflate "simulator build succeeds" with "shaders are perf-optimal on device." Sim is for code-correctness only.
