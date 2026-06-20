# 2026-06-15 verdict — materials.json staging, RTX hash bridge dead-end, parallax tuning

**Project:** Quake_IoS_Phase9_Fork (Q3RT Metal renderer)
**Branch:** metal-renderer-fresh
**HEAD at start:** f462479
**Session focus:** Visual gap to RTX Remix reference on q3dm1/q3tourney5

## Summary of confirmed facts (use these next session)

### 1. Materials.json staging — 3-source merge convention

`project.pbxproj` `Stage baseq3 data` script rsyncs from THREE source dirs in order:
1. `${SRCROOT}/baseq3/` (top-level)
2. `${SRCROOT}/Quake3-iOS/baseq3/` (empty for `pbr/`)
3. `${SRCROOT}/Resources/baseq3/` (canonical — wins on file-name conflict)

Build before this session was running with a STALE 18.8 KB / 26-entry `materials.json` because the script-phase's `alwaysOutOfDate=0` + directory-mtime tracking SKIPPED on incremental builds even though `Resources/baseq3/pbr/materials.json` had been updated in place. **Fix pattern: `touch Resources/baseq3` after any edit to bump dir mtime; or `rm` the stale bundle copy to force re-stage.**

### 2. RTX Remix hash bridge — empirically dead, do not retry

Wrote `scripts/q3_to_rtx_hash_bridge.py` using the validated formula `XXH3_64(BGRA mip0)` (cracked in `scripts/dds_hash_validate.py`). Walked pak0.pk3 + cross-referenced 938 hashes from `~/Desktop/capture_materials_report.csv`. Got **3 of 938 matches**.

Added engine-side hash logger at `code/ios/metal_renderer_stub.c:2109` (`[Q3-HASH-DUMP]` telemetry) inside the existing PBR hash compute block. Captured 791 unique engine hashes across q3dm1 / multiple sessions. Cross-reference: **5 of 938 matches** — slightly better than pak0-decode-only, but the 5 are: 2 model textures, 2 NVIDIA solid-color textures, 1 menu background. **Verified: cvar reset (`r_intensity 1.0`, `r_gamma 1.0`, `r_overBrightBits 0`, `r_picmip 0`, `vid_restart`) produced IDENTICAL hashes** across 274 shared textures between two runs. Our Metal renderer ignores those cvars entirely — hash is purely a function of disk-decoded TGA/JPG pixels.

Conclusion: NVIDIA Q3RTX (q3rtx engine fork) preprocesses world textures differently than us. The 5 matches are all textures that bypass world preprocessing in BOTH engines. The 938-hash bridge will not close meaningfully without either replicating Q3RTX's upload pipeline in our engine or pivoting to content-similarity matching (LMStudio visual matcher exists at `scripts/lmstudio_visual_material_match.py` — not run this session).

**Anti-pattern for future agents: do not rerun the bridge expecting better results. The cap is ~5 matches.**

### 3. Materials.json content hygiene — two cleanups

Two surgical edits this session, both backed up in `Resources/baseq3/pbr/_bak/`:

**a) noalbedo-strip:** removed 1,251 entries from `materials_by_name` that had ZERO PBR fields (Q3 shader-metadata-only — `alphaMode`/`srcBlend`/`renderCategory`/`maps`/`animMaps` etc., no `albedo`/`normal`/`hash`). These were merge artifacts polluting the PBR lookup. After strip: 2,109 → **858 PBR-eligible named entries**. Backup: `materials.pre-noaldedo-strip.20260615-112430.json.bak`. Did not affect SIGSEGV repro surface (those entries had `albedo=NULL` so Swift's `guard let` returned early on them).

**b) lmstudio-atlas-suppress:** 55 named entries inherited `sprite_sheet_cols/rows/fps` from atlas-bearing hash parents via the `"hash"` back-reference. 26 of those were `"source": "lmstudio"` (visual-matcher-generated, low-fidelity matches). Patched their own `sprite_cols=1, sprite_rows=1, sprite_fps=0` to defeat the C-side inheritance gate at `q3_pbr.c:573` (`if (e->mat.sprite_cols == 0)`) AND stay benign in MSL atlas remap (1×1 grid = always frame 0 = no UV shift). Backup: `materials.pre-lmstudio-atlassuppress.20260615-140346.json.bak`. **Result: world-side atlas-load events dropped from 9 unique surfaces to 1 (`icons/iconw_shotgun` only).**

Headline static textures affected (were "wild banshee" before patch):
- `textures/base_trim/pewterstep`, `techborder`, `border11c`, `spiderbite`
- `textures/base_floor/proto_grill`, `textures/base_support/x_support2`
- `textures/gothic_door/km_arena1archfinald_top`, `textures/gothic_trim/baseboard01`
- `textures/gothic_trim/stucco7bord1` (via lmstudio match to stucco7trim hash `EC2A30EEB84FA6AF` 4×1@8fps)

### 4. Parallax visibility — math IS firing, scale needs to be 0.1–0.3

After the noalbedo-strip exposed real height maps on 269 PBR-eligible entries, parallax displacement became visible. `r_pbr_parallax_scale` at default 0.02 is sub-pixel; at 2.0 it produces **±30% UV shift on view-direction change** → "wild banshee" because the hardcoded `* 0.15` dampener at `MetalView.swift:2438` doesn't prevent extreme scales.

User settled at **`r_pbr_parallax_scale 0.3`** — confirmed via session log analysis (cycled 2.0 → 0 → 0.3, last 100+ PBR draws at 0.3). Verified stable.

Per-frame motion at standing-still under high parallax scale is from Q3's idle camera bob/sway (cg_bob* cvars) — every frame view matrix changes slightly → viewTS changes → parallax UV offset changes. Even small camera changes produce big visible shifts at high scale. **Do not interpret "still moves while standing" as evidence of tcMod animation.**

### 5. SIGSEGV crash — root cause identified, fix queued for Codex

Crash: `EXC_BAD_ACCESS at 0x0000020540010000` in `_platform_strlen` ← `String.init(cString:)` ← `pbrAlbedoTexture(for:)` at `MetalView.swift:6669` (`let path = String(cString: albedoCStr)`).

Root cause: `mat.albedo` C pointer is non-NULL but dangling — `q3_pbr.c`'s material parser populates `q3_pbr_material_t.{albedo,normal,roughness,metallic,emissive,height,sourceTexture}` with pointers into the JSON parser's temp buffer; buffer is freed after parsing, leaving every material with dangling C strings. Old 26-entry materials.json never tripped it because almost no entries had `albedo` populated.

Fix dispatched to Codex via `docs/goal.md` with:
- Hard scope: q3_pbr.c/.h only
- RAG-first protocol (6 mandatory `~/Desktop/q3rt-ask.sh` queries before reading any source file)
- Token budget ≤80K, ≤120-line C diff
- Acceptance: strdup all path fields at parse time; free in `q3_pbr_free_table()`; hash-keyed inheritance copies also strdup
- DoD: commit hash + diag log excerpt + vid_restart-survives proof
- Anti-patterns: no `materials.json` revert, no Swift try/catch around `String(cString:)`, no "while I'm here" refactors

**Notable empirical:** after noalbedo-strip + lmstudio-suppress, latest session ran **2,261 frames q3dm1 without SIGSEGV**. Either incidentally fixed by the cleanup (one of the 1,251 stripped entries was the trigger) OR just lucky and bug surface narrowed. Codex's strdup fix is still the correct long-term direction — any future merge from another source could re-expose it.

### 6. Visual state at session end

Per user's screenshot at 13:53 with `r_pbr_parallax_scale 0.3`:
- q3dm1 floor + walls show proper PBR detail (visible stone tile relief, gothic door reads as forged metal with glowing orbs, walls have rivet detail)
- 17 fps — performance still rough; not chased this session
- Black rectangular hole in floor (separate bug, not investigated this session — likely single brush face with wrong shader output)

Visual gap to RTX Remix reference (skull walls / `largerblock3b_ow` / `center2trn`) remains because those textures are STILL absent or have empty PBR fields in the merged materials.json. Adding entries for them requires either content-similarity matching (LMStudio) or hand-authoring against the existing 2,812 ingested DDS at `Resources/baseq3/pbr/assets/ingested/`.

## Files written this session

- `scripts/q3_to_rtx_hash_bridge.py` (new, 168 lines) — pak0 walk + CSV cross-ref + materials.json merge
- `code/ios/metal_renderer_stub.c` ~line 2109 — 4-line `[Q3-HASH-DUMP]` telemetry hook
- `Resources/baseq3/pbr/materials.json` — merged + noalbedo-strip + lmstudio-suppress (final: 1.37 MB, 858 named, 938 hash)
- `docs/goal.md` — Codex batch handoff for q3_pbr.c strdup fix
- `CLAUDE.md` — added `q3_to_rtx_hash_bridge.py` entry + `[Q3-HASH-DUMP]` section under build-and-run

## Backups in `Resources/baseq3/pbr/_bak/`

- `materials.bundle-stale.20260615-090722.json.bak` (18.8 KB original stale stub)
- `materials.top-baseq3.20260615-090722.json.bak` (11.7 KB top-level baseq3 dup)
- `materials.pre-bridge.20260615-093809.json.bak`
- `materials.pre-noaldedo-strip.20260615-112430.json.bak`
- `materials.pre-lmstudio-atlassuppress.20260615-140346.json.bak`

## Open items for next session

1. **Wait for Codex's q3_pbr.c strdup fix** per `docs/goal.md` — verifies the SIGSEGV root cause is closed, not just surface-narrowed.
2. **Investigate the black floor rectangle on q3dm1** — likely single brush face with bad shader output (subtract blend or nodraw regression). Walk to it, note world coordinates, grep the BSP shader list.
3. **Content-similarity texture bridge** to fill in the absent gothic_wall/skull_b, gothic_block/largerblock3b_ow, gothic_floor/center2trn entries. Either `scripts/lmstudio_visual_material_match.py` (exists, unused) or write a thumbnail-MSE matcher pak0 → ingested DDS.
4. **Performance:** 14–17 fps on q3dm1 Catalyst is rough. Likely RT pipeline + new PBR coverage hitting harder. Phase 2 perf items in CLAUDE.md remain deferred (`Q3.RT.copyAccumToHistory` TAA gate already applied 2026-06-10; `Q3.render.postRT` encoder coalescing still pending).
