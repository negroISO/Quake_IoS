# Quake3-iOS Metal Renderer — LLM Handoff Guide

You are picking up mid-stream on a port of Quake 3 Arena to iOS with a Swift/Metal renderer. The user (targus) iterates with you in a tight loop: **diagnose → patch → run → vision-verify → commit**. This document tells you everything you need to pick up without re-deriving context.

## Repo + branch

- Path: `/Users/targus/Documents/Quake_IoS`
- Active branch: `metal-renderer-fresh` (this is where we commit — never work on `main`)
- **Always check `git log --oneline -10` first.** Commits since this doc landed may supersede it.

Core files:

| Path | Purpose |
|---|---|
| `code/ios/metal_renderer_stub.c` | main Metal render stub (~4400 lines) — most rendering work lives here |
| `code/ios/metal_renderer_shared.h` | Swift ↔ C struct layouts (`Q3MetalWorldStage`, `Q3MetalLight`, `Q3MetalFlare`, etc.) |
| `Quake3-iOS/MetalView.swift` | Swift wrapper + MSL shader source string |
| `code/ios/ios_main.m` | iOS entry + `Cbuf_AddText("demo nv15")` boot command (currently set to nv15 — revert before shipping) |
| `code/renderervk/` | reference Vulkan renderer (working, complete) |

## Procedures — token discipline comes first

**The core principle is keep Claude's context lean.** Delegate grunt work — vision comparison, log searching, code summarization — to cheaper or more-specialized tools. Claude makes decisions; the tools do the heavy reading.

### Tool stack and when to use each

| Tool | Endpoint | Use it for |
|---|---|---|
| **LM Studio Gemma** | `http://192.168.0.77:1234` (`google/gemma-4-31b`, vision-capable) | Frame-by-frame visual QA, A/B regression checks, log skimming. Wrapped by `scripts/gemma_review.sh`. |
| **Codex MCP** (`mcp__codex__codex`) | local | Second-opinion architecture questions, research on Q3 engine pipeline details, multi-file code reading without burning your tokens. Keep it read-only — Codex doesn't commit. |
| **Subagents** (`Explore`, `Plan`, `general-purpose`) | local | Multi-step searches that would cost Claude dozens of Read/Grep calls. Use the `Plan` agent before any substantial feature to avoid throw-away work. |
| **q3sim_session.sh** | local | Captures a 45-second run: engine stdout, 1 fps PNG frames, meta.txt with git HEAD. |

### Ask Gemma, not me

When you have a log or a frame to inspect:

```bash
# Vision A/B on frames
scripts/gemma_review.sh --prompt 'One-line verdict per pair: IDENTICAL | DRIFT | REGRESSION' \
    "$BASELINE/frames/frame_020.png" "$NEW/frames/frame_020.png"

# System prompt defaults to Quake 3 QA framing; every response ends with
# `VERDICT: <home-screen|menu|loading|gameplay|scoreboard|other>`.
```

Gemma reads the PNGs as base64 over LM Studio's OpenAI-compatible API. A frame-comparison costs Claude ~60 tokens of prompt writing; Gemma returns ~200 tokens of verdict. Reading raw logs or staring at images ourselves costs 10×+.

### Ask Codex, not me

Before implementing anything non-trivial, delegate the planning to Codex MCP:

```
Use mcp__codex__codex with a terse prompt:
- "What does Q3 do for X?"
- "Which files in code/renderer/ handle Y, and what's the minimal surface I need to mirror in the Metal stub?"
- "Sanity-check this planned change: {diff stub}. Red flags?"
```

Codex reads the reference renderer (`code/renderer/`, `code/renderervk/`) quickly. It's a one-shot tool — give it enough context in the prompt (paths, line numbers, what we've already ruled out) and it returns a report Claude can act on.

### Save your own token budget

- Never `cat` a log file — `grep` the 2-3 lines you actually need.
- Use `Grep` output mode `content` with `head_limit`, don't dump files.
- Use `Read` with `offset:` + `limit:` when you know the line range.
- When you need broad exploration, dispatch an `Explore` subagent with a tight scope instead of doing it inline.

## The iterate loop

1. **Start with state.** `git log --oneline -10`, `git status --short`, `ls -t ~/Desktop/q3sim_sessions/ | head -3`.
2. **Diagnose.** Read the most recent session's `meta.txt` + `filtered.log`. Use Gemma for visual checks. Use Codex for architecture questions.
3. **Plan atomically.** One commit = one root-cause fix. If you're tempted to bundle, split.
4. **Patch.** Prefer `Edit` over `Write`. Keep edits minimal — match the surrounding comment style.
5. **Build.** Must print `** BUILD SUCCEEDED **` before commit:
   ```bash
   xcodebuild -project Quake3-iOS.xcodeproj -scheme Quake3-iOS \
     -configuration Debug \
     -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
     build 2>&1 | grep -E 'error:|BUILD SUCC'
   ```
   **DO NOT** use `generic/platform=iOS Simulator` — that triggers x86 SSE linker errors. Always pick a specific simulator model.
6. **Install + run session.**
   ```bash
   xcrun simctl install 77575E1E-108A-400D-B844-BCDB8514BE2E \
       /Users/targus/Library/Developer/Xcode/DerivedData/Quake3-iOS-*/Build/Products/Debug-iphonesimulator/Quake3-iOS.app
   SESSION=$(scripts/q3sim_session.sh autorun <label> 45 2>/dev/null)
   ```
   `$SESSION` is the folder under `~/Desktop/q3sim_sessions/<timestamp>_<label>/`.
7. **Vision-verify with Gemma.** A/B the new session vs. the last-known-good baseline frames. Only commit if there's no regression.
8. **Commit atomically** (see next section).
9. **Repeat.**

## Commit discipline

- **Branch:** `metal-renderer-fresh`. Never commit to `main`.
- **Atomic**: one logical fix per commit. Never amend. The user bisects on these — make each one independent.
- **Must build.** Non-negotiable.
- **HEREDOC message with root-cause, diagnostic evidence, and expected effect.** End with the trailer:
  ```
  Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
  ```
  Example:
  ```bash
  git commit -m "$(cat <<'EOF'
  fix(metal): preserve world generation across FreeWorldMapData

  FreeWorldMapData's trailing Com_Memset(&s_world, 0, ...) zeroed
  s_world.generation, so subsequent LoadWorldMapData incremented from 0
  every time — Swift's cachedWorldGeneration==generation short-circuit
  kept the old MTLBuffer on every map change.

  Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
  EOF
  )"
  ```
- **Never stage `ios_main.m`** unless the user explicitly wants the boot-map / demo-name change committed. It's our test-rig dial; keep it dirty.
- **Never stage `Quake3_iOSApp.swift` / `qcommon.h`** if they have unrelated dirty edits. Only stage the files that are part of the fix.

## Session workflow (q3sim_session.sh)

Lives at `scripts/q3sim_session.sh` in the repo (not `~/bin/`). Four verbs:

```bash
scripts/q3sim_session.sh start <label>                     # launches app, returns session path
scripts/q3sim_session.sh frame <session> <idx>             # grabs a rotated PNG into frames/
scripts/q3sim_session.sh finish <session> [<stop_reason>]  # builds meta.txt + filtered.log
scripts/q3sim_session.sh autorun <label> [duration_sec]    # one-shot: start + 1fps capture + finish. default 25s.
```

Output at `~/Desktop/q3sim_sessions/<YYYYMMDD_HHMMSS>_<label>/`:
- `meta.txt` — git HEAD, dirty files, sim UDID, app bundle path, timedemo result.
- `q3.log` — full engine stdout.
- `filtered.log` — grepped slice: `metal|skin|entity|light|shader|error|warn`.
- `frames/frame_NNN.png` — 1 fps landscape screenshots (sips rotates sim's portrait capture).

`autorun` waits for the first `Demo file:` log line before beginning capture (so frame_001 is inside gameplay, not the iOS home screen), then exits early on `Client Shutdown|Sys_Quit`.

The script echoes the session path to stdout; its own status messages go to stderr so `SESSION=$(...)` works cleanly.

## Gemma review script (scripts/gemma_review.sh)

Send 1-N PNG frames + a prompt to LM Studio's OpenAI-compatible endpoint. Returns text + a required `VERDICT:` line for machine parsing.

```bash
scripts/gemma_review.sh <frame.png> [<frame.png> ...]                  # default QA prompt
scripts/gemma_review.sh --prompt "custom question" <frames>            # override user prompt
scripts/gemma_review.sh --system "custom system" --prompt "..." <fr>   # override system too
```

Env vars: `LMSTUDIO_URL` (default `http://192.168.0.77:1234`), `LMSTUDIO_MODEL` (default `google/gemma-4-31b`).

If LMS times out: either it's busy or the Mac lost Wi-Fi. Drop the payload to 1-2 frames and retry — 5+ frames of 2796×1290 PNG occasionally exceed the model's patience.

## Current feature stack

Recent commits on `metal-renderer-fresh`, newest first. Use `git log --oneline -15` to refresh.

| Commit | What shipped |
|---|---|
| `9c83561` | **Flare billboard pipeline** — BSP MST_FLARE + `q3map_flare` shader directive → camera-facing additive sprites |
| `63d24bb` | **Dynamic lights infra** — `RE_AddLightToScene` end-to-end, radial falloff, 32-light cap. Blocked on cgame syscall ABI (see below). |
| `1b81110` | **Map-change fix** — preserve `s_world.generation` across `FreeWorldMapData` so Swift re-uploads MTLBuffer on every map load |
| `b13d176` | **Text fix** — 2D blendMode 0 falls through to alpha-over instead of opaque (font atlas glyphs were white squares) |
| `fa7ed88` | **Scripts tooling** — `q3sim_session.sh` + `gemma_review.sh` landed |
| `519d884` | **Sprite blend** — derive sprite blendMode from customShader instead of forcing additive |
| `5b3a750` | **2D blendMode** — StretchPic path respects shader blend (fixes levelShotDetail overlay) |

## Ordered missing-subsystem backlog (from nv15 demo stress test)

nv15 is the user's nvidia-logo benchmark demo — it's meant to exercise everything. Reviewing its output with Gemma surfaced this priority order:

1. ~~**Dynamic lights**~~ — infra shipped (`63d24bb`). Blocked on cgame syscall ABI.
2. ~~**Flares**~~ — infra shipped (`9c83561`). Visible on maps with MST_FLARE or `q3map_flare` directive.
3. **Shader-sky classification for nv15 sky** — nv15 loads with 0 sky draws because its sky shader isn't classified. Need to detect via `surfaceparm sky` or `skyparms` block.
4. **RT_RAIL_CORE + RT_RAIL_RINGS** — rail gun trails (rejected in `RE_AddRefEntityToScene`).
5. **RT_LIGHTNING** — lightning gun beam.
6. **RT_BEAM** — grappling hook + CTF mission beams.
7. **RE_AddPolyToScene** — full no-op; breaks bullet marks, shadow blobs, blood splats.
8. **tcGen environment** — chrome/reflective surfaces render flat.

Work strictly in this order unless the user overrides. Each new feature: patch, run, Gemma-verify no regression, commit, move on.

## Known blockers

- **cgame QVM syscall ABI** — bundled cgame.qvm emits `addLight=0, addPoly=0` per frame, and only ships a small fraction of expected `addRefEntity` calls (see comment in `metal_renderer_stub.c` around the synthetic viewmodel injection). This gates dlight visibility (commit `63d24bb`), poly marks (task #7), and HUD player entities. Fix is a single coordinated effort — either repair `vmMain` interface, replace `cgame.qvm`, or cut over to native cgame. Tracked as its own task.
- **`ios_main.m` boot hack** — currently set to `timedemo 0; demo nv15`. Must be reverted to `demo four` (or whatever) before any final ship.
- **`$whiteimage` / `*white` sentinels** — shaders that use these as `map` fall through to white fallback; affects `viewBloodBlend`, `smokePuff`, `rocketExplosion`, `railCore`, `bloodTrail`, `wake`, etc.
- **Missing weapon-barrel MD3s** — deeper asset issue; deprioritized.

## First commands when you pick up a new chat

```bash
cd /Users/targus/Documents/Quake_IoS
git log --oneline -10
git status --short
ls -t ~/Desktop/q3sim_sessions/ | head -3
LATEST=$(ls -td ~/Desktop/q3sim_sessions/*/ | head -1)
cat "$LATEST/meta.txt"
```

Then:
- Read this file top-to-bottom if it's your first chat on this repo.
- Ask the user what's next, **or** proceed on the top unchecked item in the "Ordered missing-subsystem backlog."

## Ground rules (DO NOT VIOLATE)

- Atomic commits on `metal-renderer-fresh`. Never amend. Never `--no-verify`.
- Every commit builds.
- Delegate to Gemma + Codex before spending your own tokens on reading.
- Don't introduce backwards-compat shims or speculative abstractions.
- Don't commit `ios_main.m`'s boot tweaks unless explicitly asked.
- If something's unclear, ask Gemma or Codex before asking the user.
