# Quake3-iOS Metal Renderer — LLM Handoff Guide

You are picking up mid-stream on a port of Quake 3 Arena to iOS with a Swift/Metal renderer. The user (targus) iterates with you on a loop: (1) commit an atomic fix, (2) build for the simulator, (3) run a recorded session, (4) show you the folder, (5) you diagnose and propose the next fix. This document tells you everything you need to pick up without re-deriving context.

## Repo

- Path: `/Users/targus/Documents/Quake_IoS`
- Metal stub (C side): `code/ios/metal_renderer_stub.c` — 4000+ lines; most rendering work lives here
- Shared header: `code/ios/metal_renderer_shared.h` — Q3MetalWorldStage / Q3TcMod layout
- Swift + MSL shaders: `Quake3-iOS/MetalView.swift`
- Reference Vulkan renderer (working, complete): `code/renderervk/`

## Active branch + state

- Active branch: `metal-renderer-fresh`
- HEAD at time of writing: `ca59020 fix(parser): stop eating 5 tokens after rgbGen exactVertex`
- Always check `git log --oneline -10` in `/Users/targus/Documents/Quake_IoS` before doing anything — commits since this doc landed may supersede what's written here.

## The user's ground rules (DO NOT VIOLATE)

- **Atomic commits**: one fix per commit. NEVER batch multiple logical changes into one commit. NEVER amend.
- **Every commit must build**. Run `xcodebuild ... build` and confirm `** BUILD SUCCEEDED **` before committing.
- **Commit with a HEREDOC** so the message contains the root cause + diagnostic evidence + expected effect, not just the fix summary. End with the trailer:
  `Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>`
- **Don't skip commits** — the user will bisect between commits when something breaks.
- **Don't introduce backwards-compatibility shims** or speculative abstractions.
- **The user's 9-step plan** is the north star for structural fixes. STEP status as of HEAD=ca59020:
  - STEP 1 (stage array) — ✅ done (`7c1b654`, `f151790`, `cf1cc2e`)
  - STEP 2 (tcMod chain) — ✅ done (same commits)
  - STEP 3 (blendFunc mapping) — ✅ done (`fe9ff23`)
  - STEPS 4–9 — not yet started

## Repro + session workflow

### 0. Before each session, confirm state

```bash
cd /Users/targus/Documents/Quake_IoS
git status --short
git log --oneline -5
```

### 1. Build for the iOS Simulator (arm64 only)

```bash
cd /Users/targus/Documents/Quake_IoS
xcodebuild -project Quake3-iOS.xcodeproj -scheme Quake3-iOS \
  -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  build 2>&1 | grep -E "error:|BUILD "
```

Must print `** BUILD SUCCEEDED **`. If it doesn't, fix errors before proceeding — don't commit a broken build.

**DO NOT** use `-destination 'generic/platform=iOS Simulator'` — that triggers x86_64 SSE asm linker errors. Always name a specific iPhone model.

### 2. Ensure baseq3 assets are in the simulator's Documents folder

Simulator Xcode builds don't bundle baseq3 — must copy once per sim install.

```bash
APP_DATA=$(xcrun simctl get_app_container booted com.quake3ios.app data 2>/dev/null)
if [ -n "$APP_DATA" ]; then
    mkdir -p "$APP_DATA/Documents/baseq3"
    cp /Users/targus/Documents/Quake_IoS/baseq3/*.pk3 "$APP_DATA/Documents/baseq3/"
fi
```

The session script does this idempotently on every run, so usually you don't need to do it manually.

### 3. Run a recorded session

```bash
~/bin/q3sim_session.sh [max_seconds] [label]
# e.g.
~/bin/q3sim_session.sh 180 after-step4
```

- Stops automatically when Q3's timedemo prints `"N frames, S.S seconds: F.F fps"`.
- Also stops on `Sys_Error:` (fatal).
- Safety-caps at max_seconds (default 120).

Output: `~/Desktop/q3sim_sessions/<timestamp>_<label>/` containing:
- `meta.txt` — git HEAD, dirty files, simulator info, stop reason, timedemo result
- `q3.log` — full stdout from Quake3-iOS (every `[PARSER-DBG]`, `[SHADER-REG]`, `[TEX-DBG]` line)
- `filtered.log` — just the interesting lines (grep of SHADER-REG|PARSER-DBG|TEX-DBG|ENTITY:rejected|failed to load|Sys_Error|Q3-AUDIT|unrecognized blendFunc)
- `frames/frame_NNN.png` — 1 fps screenshots, each 1320×2868

### 4. Inspect the session folder

Always start with `meta.txt` — it has the git HEAD so you know what code produced the log.

```bash
SESS=~/Desktop/q3sim_sessions/<folder>
cat "$SESS/meta.txt"
less "$SESS/filtered.log"
```

Use `Read` on individual frames to see the rendered output. Key diagnostics the log produces today:
- `[PARSER-DBG] end file=<shader.shader> registered=<N>` — how many shaders made it through
- `[SHADER-REG] name=[...] len=... last3bytes=...` — every sfx-prefixed or target shader as it registers
- `[TEX-DBG] resolving '...' entry=FOUND|NULL` — whether RegisterTexture finds the shader map entry
- `[TEX-DBG] via entry.mapPath '...' → '<resolved>'` — what real file resolved it
- `failed to load UI texture '...' falling back to white` — unresolved
- `ENTITY:rejected-implausible-origin` / `-non-finite-axis` — origin guard at work
- `unrecognized blendFunc 'X Y' → opaque` — missing blendFunc mapping

### 5. Make the next fix

Workflow for an atomic fix:
```bash
cd /Users/targus/Documents/Quake_IoS
# Edit code/ios/metal_renderer_stub.c or Quake3-iOS/MetalView.swift

# Build
xcodebuild -project Quake3-iOS.xcodeproj -scheme Quake3-iOS \
  -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  build 2>&1 | grep -E "error:|BUILD "

# Commit (HEREDOC, no --amend, one fix only)
git add code/ios/metal_renderer_stub.c
git commit -m "$(cat <<'EOF'
fix(area): one-line summary

Multi-paragraph body: root cause, diagnostic evidence (quote the
exact log lines from the session that justified this), expected
user-visible effect. Leave no ambiguity — the user bisects on
these messages later.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

After committing, the user rebuilds in Xcode (Cmd+B then Cmd+R once to reinstall the sim app) and re-runs `q3sim_session.sh` with a label indicating what changed.

## Recording automation (physical iPhone)

The user has Xcode Behaviors wired to these scripts. They fire automatically on Run Start / Run Complete:

- `~/bin/xcode_record_start.sh` — opens QuickTime, pins camera to iPhone + mic to Mac's built-in, begins Movie Recording.
- `~/bin/xcode_record_stop.sh` — stops, exports at 1080p preset to `~/Movies/`, then mv's to `~/Desktop/xcode_capture_*.mov`.

Xcode Behavior wiring: **Settings → Behaviors → Running → Generates output** (NOT `Starts` — it was causing LLDB attach failures due to USB bandwidth contention). `Completes` runs the stop script.

## Known-good reference points

If you need to test whether a regression is real, here are visual baselines recorded against each major commit. Read frames from these session folders:

- Latest baseline pre-fix sfx parser: session 20260420_181255_baseline-post-fb0904d (HEAD=fb0904d). Shows ~236 missing shaders in sfx.shader, walls rendering as white.

## Known remaining issues (as of ca59020)

- **STEPS 4–9** of the 9-step plan not yet applied (remove global shader state, per-stage tcGen, per-stage culling, portal flags, depth hack, default world flags).
- **`$whiteimage` / `*white` sentinels** — shaders that use these as `map` don't resolve. Affects `viewBloodBlend`, `smokePuff`, `plasmaExplosion`, `rocketExplosion`, `railCore`, `bloodTrail`, `wake`, `sprites/plasma1`, `gfx/misc/tracer`, etc. Fix: detect `*` / `$` prefix in stage mapPath resolver and return `EnsureWhiteTexture()` immediately.
- **5 unknown blendFunc combos** still log: `gl_one_minus_dst_alpha gl_one_minus_dst_alpha`, `GL_ONE_MINUS_SRC_ALPHA GL_ONE_MINUS_SRC_ALPHA`, `GL_SRC_COLOR GL_SRC_COLOR`, `GL_ONE_MINUS_SRC_COLOR GL_ONE_MINUS_SRC_COLOR`, `GL_SRC_ALPHA GL_SRC_ALPHA`. Add to `BlendModeFromTokens`.
- **Missing weapon-barrel MD3s** (`models/weapons2/shotgun/shotgun_barrel.md3` etc.) — deeper issue; deprioritized unless the user asks.
- **Entity bad origin on scoreboard** — `af13367` catches it but the portrait model is missing; fix origin at source if time permits.
- **Fog** — no implementation. Not on the 9-step list; separate feature.

## File locations summary

| Path | Purpose |
|---|---|
| `/Users/targus/Documents/Quake_IoS` | repo root |
| `code/ios/metal_renderer_stub.c` | main Metal render stub (~4000 lines) |
| `code/ios/metal_renderer_shared.h` | Swift⇄C struct layouts |
| `Quake3-iOS/MetalView.swift` | Swift wrapper + MSL shaders |
| `code/renderervk/` | working Vulkan renderer for reference |
| `baseq3/*.pk3` | game asset packs |
| `~/bin/q3sim_session.sh` | automated session capture |
| `~/bin/xcode_record_start.sh` | QT recording start (device workflow) |
| `~/bin/xcode_record_stop.sh` | QT recording stop |
| `~/Desktop/q3sim_sessions/` | session folders (meta + log + frames) |

## First commands when you pick up a new chat

Run these to ground yourself:

```bash
cd /Users/targus/Documents/Quake_IoS
git log --oneline -10
git status --short
ls -lt ~/Desktop/q3sim_sessions/ | head -5
# If a recent session folder exists, inspect it:
LATEST=$(ls -td ~/Desktop/q3sim_sessions/*/ | head -1)
cat "$LATEST/meta.txt"
head -30 "$LATEST/filtered.log"
```

Then ask the user what they want you to focus on, or proceed on whichever 9-step item is next.
