# 2026-06-15 Codex Progress — Q3 RT / PBR Crash Batch

Workspace: `/Users/targus/Documents/Quake_IoS_Phase9_Fork`  
Branch: `metal-renderer-fresh`  
Status: **in progress; not DoD complete**

## Current active goal

Fix the dangling `q3_pbr_material_t` path-pointer crash described in `docs/goal.md`.

Target crash:

```text
EXC_BAD_ACCESS / SIGSEGV in Swift String(cString:)
MetalView.swift:pbrAlbedoTexture(for:)
mat.albedo non-NULL but invalid
```

Scope constraints from `docs/goal.md`:

- Real fix must stay in `code/ios/q3_pbr.c` / `code/ios/q3_pbr.h`.
- Do not modify `materials.json` as the crash fix.
- Do not use Swift guards as a substitute for fixing C string ownership.
- Final DoD still requires commit hash + q3dm1 >=60s diag excerpt + `vid_restart` proof + q3_pbr diff under 250 lines.

## What was checked this turn

### Brain/RAG

Ran:

```sh
~/Desktop/q3rt-ask.sh "q3_pbr path ownership progress handoff no-albedo materials"
```

Result:

- `work/verdicts` search failed with `AttributeError: bindings`.
- `sources/Quake_IoS` search failed with missing collection.
- `work/q3sim` returned older session-log hits only, including prior `fix(pbr): suppress classic no-albedo noise`.

### Current worktree evidence

Relevant local diff exists in:

- `code/ios/q3_pbr.c`
- `code/ios/q3_pbr.h`

Observed `git diff -- code/ios/q3_pbr.c code/ios/q3_pbr.h` summary:

- `str_arena_dup` has a forward declaration now.
- `str_arena_dup()` now returns individually `malloc`-owned heap strings, not pointers into a realloc-moving arena.
- Named parent→child inherited paths now call `str_arena_dup(...)` for:
  - `albedo`
  - `normal`
  - `roughness`
  - `metallic`
  - `emissive`
- `q3_pbr_table_load()` now calls `q3_pbr_free_table()` on reload.
- Current `q3_pbr_free_table()` intentionally does **not** free old `g_materials` / `g_named` arrays or individual strings; it nulls global pointers and frees only `g_hash_table`. Comment says this preserves old `metalTexture_t.pbrMaterial` back-pointers across `vid_restart` and matches process-lifetime string expectations.

Important caveat:

- `q3_pbr.h` currently says material slot pointers remain valid “until the table is reloaded,” while `q3_pbr.c` comment says they intentionally remain valid for process lifetime across reload. That contract mismatch should be reconciled before final commit.

### materials.json no-albedo diagnostics

Checked these warnings:

```text
gfx/2d/numbers/eight_32b
gfx/2d/numbers/seven_32b
gfx/2d/numbers/six_32b
icons/iconr_shard
icons/iconw_plasma
```

Finding:

- All five entries exist only under `materials_by_name` in `Resources/baseq3/pbr/materials.json`.
- They contain classic shader metadata only: `alphaMode`, `srcBlend`, `dstBlend`, `renderCategory`, `maps`, `gamePath`, `sourceShaderFile`, `sourcePk3`, `surfaceparm_*`.
- They have no `hash`, no `albedo`, and no PBR texture slots.
- Current `no-albedo ... material found but albedo slot is NULL` diagnostics are expected for these entries unless they are removed from PBR lookup or given explicit PBR albedo/backrefs.

### Last-run logs

Checked standard live paths:

```sh
~/Library/Containers/com.quake3ios.rt/Data/Documents/q3_diag.log
/private/tmp/q3rt_logs/q3_diag.log
```

Result:

- No live diag log existed at either path at the time of this progress note.
- Latest archived Catalyst logs found under `~/Desktop/q3sim_sessions/`, newest observed:
  - `~/Desktop/q3sim_sessions/2026-06-15_07-27-51__099401e7_claude-verify-p3-scale2_mac/q3_diag.log`

No new runtime verification was run in this progress update.

## Current blockers / incomplete DoD

The active goal is **not complete**.

Still required:

1. Build with:

   ```sh
   xcodebuild -project Quake3-iOS.xcodeproj -scheme Quake3-iOS -destination 'generic/platform=iOS' -configuration Debug -derivedDataPath build-device-rt build
   ```

   Must show no new `q3_pbr.c` / `q3_pbr.h` warnings/errors.

2. Run q3dm1 for >=60 seconds with `r_pbrMaterials 1`.

3. Paste diag excerpt showing:

   ```text
   [Q3-PBR] table_load returned 938 materials (named=858)
   [Q3-PBR] hash-match ... OR [Q3-PBR] name-match ...
   no EXC_BAD_ACCESS / SIGSEGV
   ```

4. Prove `vid_restart` mid-session did not crash.

5. Commit the q3_pbr fix and report commit hash.

## Recommended next steps

1. Reconcile the `q3_pbr.h` lifetime comment with the process-lifetime behavior now used in `q3_pbr.c`.
2. Build device target and resolve any `q3_pbr.*` compile warnings.
3. Run Catalyst first if possible for quick smoke, then device/required q3dm1 verification.
4. Perform `vid_restart` in-session and capture log proof.
5. Commit with the `fix(pbr): own material path strings...` subject once DoD passes.
