# 2026-06-15 — Fix dangling `mat.albedo` pointer crash in q3_pbr.c

**Workspace:** `/Users/targus/Documents/Quake_IoS_Phase9_Fork`
**Branch:** `metal-renderer-fresh`
**HEAD:** `f462479` (working tree dirty — engine-side `[Q3-HASH-DUMP]` patch + cleaned `materials.json` 1.37 MB / **858 named entries** (post-noalbedo-strip 2026-06-15) are uncommitted but staged correctly)

## Open from prior batches (out of scope this batch)

- Visual gap to RTX Remix reference (skull walls, q3dm1 floor relief) — **deferred until this crash is fixed**, then resume with content-similarity texture bridge (NOT the hash-based bridge, which is empirically dead — see CLAUDE.md `q3_to_rtx_hash_bridge.py` KNOWN LIMITATION).
- `r_intensity`/`r_gamma`/`r_overBrightBits` proven no-op in our Metal renderer — irrelevant to this batch, do not retune.
- `[Q3-HASH-DUMP]` engine telemetry is wired at `metal_renderer_stub.c:2109` and produces clean output — do not touch.

## Hard limits

- **Stay inside `code/ios/q3_pbr.c` and `code/ios/q3_pbr.h`** for the actual fix. Touching `MetalView.swift` (10K-line monolith) or `metal_renderer_stub.c` is OUT OF SCOPE unless you've proven via RAG+code-read that the bug genuinely lives there.
- **No new abstractions, no refactoring "while I'm here", no helper modules.** Smallest surgical change that owns the strings.
- **Do not modify `materials.json`.** The crash is exposed by the merged file's coverage, not caused by it. Reverting would be a workaround, not a fix.

## RAG-first protocol (mandatory before reading any source file)

Run these BEFORE opening q3_pbr.c. Their output will give you prior context the codebase doesn't carry inline.

```sh
~/Desktop/q3rt-ask.sh --code  "q3_pbr material parser path ownership"
~/Desktop/q3rt-ask.sh --code  "load_named_materials_from_json"
~/Desktop/q3rt-ask.sh         "materials.json dangling pointer crash"
~/Desktop/q3rt-ask.sh         "pbrAlbedoTexture SIGSEGV strlen"
~/Desktop/q3rt-ask.sh --code  "q3_pbr_lookup_by_name back-reference inheritance"
~/Desktop/q3rt-ask.sh         "q3_pbr_material_t field lifetime strdup"
```

Read the brain output FIRST. If a prior session has already diagnosed or attempted this fix, use that as your scaffold. Do not re-derive.

## Token budget

- **Target: ≤80K total output tokens across the whole batch.**
- The fix should be ≤120 lines of C change. If you find yourself planning >250 lines you've drifted; stop and re-scope.
- Don't read MetalView.swift end-to-end (10K lines). It is not the fix site. The Swift stack frame just consumes the bad pointer; the bug is on the C side.
- Read q3_pbr.c selectively (use Grep first, target specific functions).

## P0 — Make material struct paths owned strings

**Crash evidence** (already collected — don't re-collect):

```
/Users/targus/Desktop/q3rt_llm_drop/crash.txt
EXC_BAD_ACCESS at 0x0000020540010000
0   libsystem_platform.dylib   _platform_strlen + 4
1   libswiftCore.dylib         String.init(cString:) + 28
2   Q3_RT.debug.dylib          pbrAlbedoTexture(for:) + 1328  (MetalView.swift:6669)
3   Q3_RT.debug.dylib          Coordinator.draw(in:) + 104700 (MetalView.swift:9934)
```

`MetalView.swift:6669` is `let path = String(cString: albedoCStr)` where `albedoCStr = mat.albedo` passed the `guard let` nil-check. So `mat.albedo` is non-NULL but pointing at memory that's no longer a valid C string. **Root cause: `q3_pbr.c` populates `q3_pbr_material_t.albedo` (and likely the other path fields: `normal`, `roughness`, `metallic`, `emissive`, `height`, `sourceTexture`) with pointers into the JSON parser's temp buffer or a stack-local arena that's freed before the material is queried.**

### Acceptance criteria

1. After fix: load the existing `Resources/baseq3/pbr/materials.json` (1.37 MB, 938 hash entries, **858 named** — post-2026-06-15 noalbedo-strip; do NOT shrink further; the 1251 stripped entries were Q3-shader-metadata-only without PBR fields and DID NOT trigger the SIGSEGV since `guard let mat.albedo` returned early on them), run q3dm1 interactively for ≥60 seconds with `r_pbrMaterials 1`, and observe **zero SIGSEGV**.
2. `q3_diag.log` for the verification session must contain ≥1 `[Q3-PBR] hash-match` or `[Q3-PBR] name-match` line — proves the material lookup path is still wired and serving real albedo paths to Swift (regression check; the fix can't accidentally NULL-out everyone).
3. No new compile warnings in `q3_pbr.c` or `q3_pbr.h` (clangd warnings about other files in `metal_renderer_stub.c` are pre-existing — don't try to fix them).
4. A `vid_restart` mid-session does not crash (this was the specific trigger pattern in the 2026-06-15 10:13 crash).

### Suggested approach (read RAG output first; this may need adjusting based on what prior sessions found)

- Identify every assignment to `q3_pbr_material_t.albedo` / `.normal` / `.roughness` / `.metallic` / `.emissive` / `.height` / `.sourceTexture` in `q3_pbr.c`. Trace lifetime of each source string.
- Wrap each assignment in `q3_pbr_strdup_path()` (or equivalent) so the material owns its strings.
- Add a `q3_pbr_free_table()` (or augment existing teardown) that walks all materials and frees their owned strings. Wire it into table-reload paths if any.
- The hash-keyed inheritance back-reference (`"hash":` field — see CLAUDE.md "PBR name lookup — three-tier order" + "PBR material constants" sections) propagates paths from parent → child. The COPIED pointer in the child entry must also be owned (or shared via refcount); do not just memcpy the parent's pointer.

### Commit message template

```
fix(pbr): own material path strings so q3_pbr_material_t survives parser teardown

Root cause: q3_pbr.c populated q3_pbr_material_t.{albedo,normal,roughness,
metallic,emissive,height,sourceTexture} with pointers into the JSON parser's
temp buffer. After parsing finished those buffers were freed, leaving each
material with dangling C strings. The crash surfaced as a SIGSEGV inside
strlen called from MetalView.Coordinator.pbrAlbedoTexture(for:) at
MetalView.swift:6669 (`let path = String(cString: albedoCStr)`) — Swift
trusted mat.albedo was non-NULL and tried to dereference.

Fix: strdup() every path field at parse time; free in q3_pbr_free_table().
Hash-keyed inheritance copies (parent → named-entry back-reference) also
strdup() so child entries own their own strings.

Crash repro: load Resources/baseq3/pbr/materials.json (2107 named entries,
post-merge from 2026-06-15), interactive map q3dm1 for >30s, SIGSEGV in
pbrAlbedoTexture (MetalView.swift:6669). With fix: q3dm1 + vid_restart +
q3tourney5 + nv15 all stable for >5 min, [Q3-PBR] hash-match / name-match
lines still emit normally.
```

## P1 (optional, only after P0 verified) — Defensive Swift guard

ONLY if P0 verification confirms the C-side fix is solid and time remains in budget: add a single-line bounded-read guard in `MetalView.swift:pbrAlbedoTexture(for:)` so a future regression of this same bug fails gracefully (returns nil + logs) instead of SIGSEGV. **Do not implement this as a substitute for P0.** It is belt-and-suspenders only.

## Definition of Done

ALL of the following must be present in the final commit / response:

1. **Commit hash** with the q3_pbr.c fix.
2. **Diag log excerpt** from a ≥60s q3dm1 session showing:
   - `[Q3-PBR] table_load returned 938 materials (named=858)` (proves full materials.json loaded — count reflects the 2026-06-15 noalbedo-strip; if you see `named=2107` then a stale unstripped copy got staged, fix by `touch Resources/baseq3` + rebuild)
   - At least one `[Q3-PBR] hash-match` OR `[Q3-PBR] name-match` line (proves lookup path still works)
   - Zero `EXC_BAD_ACCESS` / `SIGSEGV` (proves the crash is fixed)
3. **`vid_restart` test:** session log proving vid_restart mid-game did not crash.
4. **Code diff** for q3_pbr.c kept under 250 lines. If larger, justify the scope expansion in the commit body.

If you cannot achieve all four, do NOT mark complete. Stop and surface the blocker — partial diagnostic verdicts (e.g. "the dangling write actually happens at parse-line N, fix requires owning field X but field X has shared ownership with Y") ARE acceptable completion when the root cause is named precisely.

## Anti-patterns to refuse

- Do NOT revert `materials.json` to a smaller version "to avoid the crash". That's a workaround that hides the bug.
- Do NOT add `try?`/`do/catch` around the Swift `String(cString:)` call. Swift doesn't catch SIGSEGV; it's not a recoverable error.
- Do NOT add NULL-check helpers in MetalView.swift that "guard against bad pointers". They can't — any read of an invalid C pointer faults the same way `strlen` does.
- Do NOT commit a `materials.json` regen or schema change as part of this batch.
- Do NOT "while I'm here" refactor q3_pbr.c's hash table, JSON parser, or lookup pipeline. Surgical fix only.
