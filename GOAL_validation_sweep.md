# Goal: Catalyst Render Validation — 27 Maps + Feature Verification

## Step 1 — Build (if not already built)

```bash
cd /Users/targus/Documents/Quake_IoS_Phase9_Fork
xcodebuild -project Quake3-iOS.xcodeproj -scheme Quake3-iOS \
  -configuration Debug -destination 'platform=macOS,variant=Mac Catalyst' \
  build
```

Takes ~2 minutes. Only needed if source changed since last build.

## Step 2 — Run the sweep

```bash
chmod +x scripts/q3_sweep_catalyst.sh
./scripts/q3_sweep_catalyst.sh
```

This loops over 27 maps (~25s each, ~12 minutes total) and produces a summary table at `~/Desktop/q3sim_sessions/sweep_<timestamp>_summary.txt`.

**Expected result:** All 27 maps should be `OK` — zero asset_miss, zero classicPromotedRTStages, zero magenta.

## Step 3 — Feature verification (interactive)

Run ONE manual session with all features active:

```bash
Q3_UPSCALE_QUALITY=medium Q3_RT_MIX=pure Q3_FRAME_INTERPOLATION=on \
  LAUNCH_COMMAND='map q3dm1; wait 480; quit' RUN_SECS=300 \
  ./scripts/q3dev_run_mac.sh feature-verify
```

While it's running (5 min), check these in the live window, then verify in the collected logs:

### Motion Vectors

- **Grep stdout**: `[Q3-MOTION]` — confirms motion vector compute pass is running
- **Grep stdout**: `motionTexture` — confirms MetalFX temporal scaler receives motion data
- **Grep stdout**: `reset reason=` — flags temporal history resets (map change, quality change)

### Temporal Denoiser / TAA

- **Grep stdout**: `[RT] metrics` → look for `taa=1` and `taaAlpha=0.10`
- This means temporal accumulation is active — frames are averaged with 10% new / 90% history
- Verify `rtHistoryTexture` is allocated (no "history buffer alloc failed" in logs)

### Frame Interpolation

- **Live**: Perceived framerate should be ~2× render rate (if render is 30fps, should feel like 60)
- **Grep stdout**: `Q3_FRAME_INTERPOLATION=on` — confirms it's enabled
- **Caveat**: Expect ghosting on fast camera motion — this is a known limitation without per-object motion vectors

### Weapon Placement

- **Add to launch command**: `weapnext; wait 10; weapnext; wait 10; weapnext`
- **Check**: Each weapon should appear at the bottom-right, correctly positioned
- **Reference**: Compare against https://quake.fandom.com (or your reference screenshots)
- The viewmodel position is controlled by cgame's `cg_gunX`, `cg_gunY`, `cg_gunZ` cvars

### 4:3 Aspect Ratio Match

Run a separate session at deterministic 4:3 resolution:

```bash
Q3_UPSCALE_QUALITY=native Q3_RT_MIX=pure \
  Q3_MATCH_PROFILE=960 \
  LAUNCH_COMMAND='map q3dm4; wait 120; quit' RUN_SECS=150 \
  ./scripts/q3dev_run_mac.sh verify-43-q3dm4
```

- **Check stdout**: `[Metal] Drawable size: (960.0, 444.0)` — confirms 4:3 lock
- **Compare**: Extract AVI frames and diff against Vulkan reference (if available)
- **Check**: No HUD cropping or menu misalignment

### Lighting / Textures / Reflections

- **Grep stdout**: `[RT] metrics` → `trace=864x559` (medium upscale RT resolution)
- **Grep stdout**: `bounces=1` — one-bounce RT GI
- **Grep q3_diag.log**: `[Q3-PBR-SWIFT]` entries — confirm PBR textures loaded, IBL env cube built
- **Grep stdout**: `skybox env source=` — confirms environment cubemap is active for reflections

## Step 4 — Write the report

Create `~/Desktop/q3sim_sessions/validation_report_<date>.md`:

```markdown
# Catalyst Validation Report — <date>

## Sweep Results (27 maps)
| map | asset_miss | classicPromotedRTStages | magenta | fps | verdict |
|---|---|---|---|---|---|
| q3dm0 | 0 | 0 | 0 | 4.3 | OK |
| ... | ... | ... | ... | ... | ... |

## Feature Verification
| Feature | Status | Notes |
|---|---|---|
| Motion vectors | ✅/❌ | |
| Temporal denoiser (TAA) | ✅/❌ | |
| Frame interpolation | ✅/❌ | |
| Weapon placement | ✅/❌ | |
| 4:3 aspect match | ✅/❌ | |
| Lighting / PBR | ✅/❌ | |
| Reflections / IBL | ✅/❌ | |
| Classic fallback fidelity | ✅/❌ | |
```

## Key Log Patterns to Grep

| What | Where | Pattern |
|---|---|---|
| PBR gate health | stdout | `classicPromotedRTStages=0` |
| Asset misses | stdout | `[asset-miss]` |
| Magenta surfaces | q3_diag.log | `-> magenta` |
| Motion vectors active | stdout | `[Q3-MOTION]` |
| RT metrics | stdout | `[RT] metrics frame=` |
| Material table | stdout | `material table:` |
| World loaded | stdout | `Metal world: loaded` |
| FX/classic fallback | stdout | `FX/classic fallback` |
| Temporal reset | stdout | `[Q3-MOTION] reset reason=` |
| IBL cubemap | stdout | `skybox env source=` |
| MetalFX scaler | stdout | `[Q3-METALFX]` or `[Q3-UPSCALE]` |
| Cap failures | q3_diag.log | `cap re-load FAILED` |
| GPU downsamples | q3_diag.log | `scaled.*->.*channel=` |
