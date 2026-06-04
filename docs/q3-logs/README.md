# Q3-iOS diagnostic log archive

Per-session captures of the in-app `q3_diag.log` from the iPhone, pulled
+ wiped via `scripts/pull_q3_diag.sh`.

## What's in here

Each `q3_diag-YYYYMMDD-HHMMSS.log` file is **one full run** of the iOS
build on device: every texture loaded, every shader stage parsed, every
PBR material lookup, every Metal renderer event, every BSP load summary,
every error/warning. The file is append-only inside the app sandbox, so
the captured contents reflect every event from app launch through the
moment the script ran.

The list of all captures lives in [INDEX.md](INDEX.md). Files themselves
are **not committed** (see `.gitignore` rule in the repo root) — they
stay only on this Mac so the repo doesn't bloat. INDEX.md and this README
ARE committed.

## Workflow

```bash
# 1. install the build on iPhone (already happens via your normal device push)
# 2. play the game / do whatever you want logged
# 3. pull:
scripts/pull_q3_diag.sh

# That's it. The file lands in this directory, INDEX.md gets a new entry,
# device-side is wiped so the next run starts at 0 bytes.
```

Alternative targets:

```bash
scripts/pull_q3_diag.sh "Oled"          # iPad Pro 13" M4 instead of iPhone
scripts/pull_q3_diag.sh "" no-wipe      # leave device log intact (default device, useful for "I'm not done yet")
```

## How to read prior runs

```bash
# list everything
cat docs/q3-logs/INDEX.md

# specific session
less docs/q3-logs/q3_diag-<ts>.log

# find a specific event class across all sessions
grep -l 'roughness DEFAULT fallback' docs/q3-logs/q3_diag-*.log

# diff coverage between two sessions
diff <(awk -F'] ' '{print $2}' docs/q3-logs/q3_diag-A.log | sort -u) \
     <(awk -F'] ' '{print $2}' docs/q3-logs/q3_diag-B.log | sort -u)
```

## Channel inventory

Active subsystems write to one of these prefixes (after the `[Q3]`
wrapper). Frequency is approximate for a normal demo-load session.

| Prefix | Source | Frequency | What it tells you |
|---|---|---|---|
| `[Q3] Metal world: loaded` | metal_renderer_stub.c — BSP loader | once per map | Vert/index/draw/surface counts, cap warnings |
| `[Q3][metal_asset_request]` | tex register hook | once per unique texture | Q3 shader name asked for |
| `[Q3][metal_asset_loaded]` | tex register hook | once per unique texture | Source file path + dimensions |
| `[Q3][metal_asset_miss]` | tex register hook | rare | When a request had no resolvable file |
| `[Q3][metal_draw_plan]` | per-draw planner | per draw cmd | Texture handle, blend mode, stage flags |
| `[Q3][metal_stage_audit]` | world shader parser | per stage | Stage map / blend / tcGen / tcMod values |
| `[Q3][metal_entity_stage_audit]` | entity shader parser | per stage | Same, for entity shaders |
| `[Q3][metal_pbr_boot]` | q3_pbr.c init | boot | materials_by_name table load + alias setup |
| `[Q3][metal_pbr_hit]` | texture register PBR hook | per match | When a Q3 texture matched a PBR material |
| `[Q3][metal_pbr_swift]` | MetalView.swift PBR loaders | per DDS load | DDS load success/fail + fallback decisions |
| `[Q3][metal_pbr_ibl]` | IBL sky auto-detect | once per map | Sky shader → r_pbr_ibl_skybox cvar write |
| `[Q3-PBR-IBL]` (Swift NSLog → file) | MetalView.swift IBL builder | once per cube build | Stem + dimensions + mips |
| `[Q3-PBR-SWIFT]` | MetalView.swift PBR loaders | per DDS event | DDS path + handle id |
| `[Q3-AUDIO]` | AudioManager.swift | boot | Session sample rate, engine start |

## File-size discipline

The script wipes device-side after each pull. If you want to keep the
device log for a longer multi-run capture (e.g., reproduce a bug across
multiple map loads), use `no-wipe` mode and pull when you're done.

Locally, archives are unbounded — they accumulate on this Mac until
manually pruned. Each 5-min play session is roughly 1-3 MB. The most
recent ~20 archives total well under 100 MB.

## When to add new logging

If you find yourself **guessing** what the engine/renderer/PBR pipeline
was doing during a specific run — that's the signal to add a new
telemetry event at the corresponding code site. Pattern:

```c
MetalTelemetryPrintf("metal_<subsystem>", PRINT_ALL,
    "[Q3-<TAG>] <one-line description> field1=%d field2=%s\n",
    field1, field2);
```

In Swift:

```swift
pbrLog("[Q3-<TAG>] <one-line description> handle=\(handle) ...")
```

Keep lines compact (one event = one line) and field-tagged (`name=value`
form) so `awk -F=` and `grep` stay easy.
