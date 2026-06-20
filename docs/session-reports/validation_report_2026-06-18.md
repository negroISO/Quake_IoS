# Catalyst Validation Report — 2026-06-18

## Verdict

- **27-map Catalyst sweep:** ✅ PASS — all rows `OK`, `asset_miss=0`, `classicPromotedRTStages=0`, `magenta=0`.
- **Core RT/PBR/IBL/TAA/4:3/weapon placement:** ✅ verified from current logs/captures.
- **Frame interpolation:** ⚠️ config toggle is read, but current code/logs do **not** prove an actual `MTLFXFrameInterpolator` encode path.
- **MetalFX temporal/motion vectors on Catalyst:** ⚠️ Catalyst falls back to compute upscale (`metalfx-unavailable-or-catalyst`). Device/iPad log verifies temporal scaler readiness with `motion=rg16Float`.

## Sweep Results (27 maps)

| map | asset_miss | classicPromotedRTStages | magenta | fps | verdict |
|---|---:|---:|---:|---:|---|
| q3dm0 | 0 | 0 | 0 | 4.0 | OK |
| q3dm1 | 0 | 0 | 0 | 4.0 | OK |
| q3dm2 | 0 | 0 | 0 | 4.0 | OK |
| q3dm3 | 0 | 0 | 0 | 4.0 | OK |
| q3tourney1 | 0 | 0 | 0 | 4.0 | OK |
| q3dm4 | 0 | 0 | 0 | 4.0 | OK |
| q3dm5 | 0 | 0 | 0 | 4.0 | OK |
| q3dm6 | 0 | 0 | 0 | 6.0 | OK |
| q3tourney2 | 0 | 0 | 0 | 4.0 | OK |
| q3dm7 | 0 | 0 | 0 | 4.0 | OK |
| q3dm8 | 0 | 0 | 0 | 4.0 | OK |
| q3dm9 | 0 | 0 | 0 | 4.0 | OK |
| q3tourney3 | 0 | 0 | 0 | 4.0 | OK |
| q3dm10 | 0 | 0 | 0 | 4.0 | OK |
| q3dm11 | 0 | 0 | 0 | 4.0 | OK |
| q3dm12 | 0 | 0 | 0 | 4.0 | OK |
| q3tourney4 | 0 | 0 | 0 | 4.0 | OK |
| q3dm13 | 0 | 0 | 0 | 25.0 | OK |
| q3dm14 | 0 | 0 | 0 | 4.0 | OK |
| q3dm15 | 0 | 0 | 0 | 4.0 | OK |
| q3tourney5 | 0 | 0 | 0 | 4.0 | OK |
| q3dm16 | 0 | 0 | 0 | 4.0 | OK |
| q3dm17 | 0 | 0 | 0 | 4.0 | OK |
| q3dm18 | 0 | 0 | 0 | 4.0 | OK |
| q3dm19 | 0 | 0 | 0 | 4.0 | OK |
| q3tourney6 | 0 | 0 | 0 | 4.0 | OK |
| nv15 | 0 | 0 | 0 | 25.0 | OK |

Evidence: `/Users/targus/Desktop/q3sim_sessions/sweep_20260617_234512_summary.txt`

## Feature Verification

| Feature | Status | Evidence / Notes |
|---|---|---|
| Motion vectors / MetalFX temporal | ⚠️ Catalyst fallback; ✅ device ready | Catalyst logs `[Q3-MOTION] reset reason=scaler-rebuild` but `[Q3-METALFX] fallback reason=metalfx-unavailable-or-catalyst`. iPad log shows `[Q3-METALFX] temporal ready input=2064x1548 output=2752x2064 fmt=rgba16Float motion=rg16Float`; exported iPad Metal trace has `metal-command-buffer-error` rows = 0. |
| Temporal denoiser / TAA | ✅ | TAA opt-in session used `set r_rt_taa 1`; metrics show `taa=1 taaAlpha=0.10`, `trace=864x559`, `bounces=1`. Note: prescribed default command still logs `taa=0` because `r_rt_taa` defaults off in code. |
| Frame interpolation | ⚠️ unproven | `Q3_FRAME_INTERPOLATION=on` is acknowledged in stdout, but grep/code inspection found no `MTLFXFrameInterpolator` usage beyond the enum/comment. No log proves synthesized frames. |
| Weapon placement | ✅ | Captured 10 frames via `Q3_CAPTURE_FRAME_DIR`; contact sheet shows Gauntlet, Machinegun, Shotgun, Grenade Launcher, Rocket Launcher viewmodels bottom-right with HUD intact. |
| 4:3 aspect match | ✅ | `Q3_MATCH_PROFILE=960` produced target/drawable `1280x960` and RT `composite=1280x960 trace=640x480`; this is 4:3. The goal doc's `960x444` expected string is stale for current code. |
| Lighting / PBR | ✅ | q3dm1: `material table ... classicPromotedRTStages=0`; `pbrSidecars=8/72`; `trace=864x559`; `bounces=1`; no asset misses/magenta. |
| Reflections / IBL | ✅ | q3dm1/q3dm4 stdout logs `skybox env source=Q3.pbr.envcube.map.env/space1 stem=env/space1`. |
| Classic fallback fidelity | ✅ | Full sweep: zero `asset_miss`, zero `classicPromotedRTStages`, zero `magenta`; q3dm1/q3dm4 feature sessions also zero asset/magenta. |

## Key Evidence Paths

- Sweep summary: `/Users/targus/Desktop/q3sim_sessions/sweep_20260617_234512_summary.txt`
- Feature/TAA session: `/Users/targus/Desktop/q3sim_sessions/2026-06-18_00-09-29__a59d865b_feature-verify-taa-on_mac`
- Default feature session: `/Users/targus/Desktop/q3sim_sessions/2026-06-18_00-03-03__a59d865b_feature-verify_mac`
- 4:3 q3dm4 session: `/Users/targus/Desktop/q3sim_sessions/2026-06-18_00-12-47__a59d865b_verify-43-q3dm4_mac`
- Weapon session: `/Users/targus/Desktop/q3sim_sessions/2026-06-18_00-22-30__a59d865b_weapon-capture-container_mac`
- Weapon capture frames: `/Users/targus/Library/Containers/21579E2F-6467-4375-8C90-BE862362FB0F/Data/Documents/captures/weapon_002230`
- Weapon contact sheet: `/Users/targus/Library/Containers/21579E2F-6467-4375-8C90-BE862362FB0F/Data/Documents/captures/weapon_002230/weapon_contact.png`
- iPad temporal/Metal trace session: `/Users/targus/Desktop/q3sim_sessions/2026-06-17_23-10-29__a59d865b_nv15-iphone-smoke-check_dev`
- iPad Metal trace: `/tmp/q3_trace/q3iphone_demo-nv15_231242.trace`

## Commands Run

```bash
xcodebuild -project Quake3-iOS.xcodeproj -scheme Quake3-iOS \
  -configuration Debug -destination 'platform=macOS,variant=Mac Catalyst' build

SWEEP_RUN_SECS=35 ./scripts/q3_sweep_catalyst.sh

Q3_UPSCALE_QUALITY=medium Q3_RT_MIX=pure Q3_FRAME_INTERPOLATION=on \
  LAUNCH_COMMAND='set r_rt_taa 1; map q3dm1; wait 480; quit' RUN_SECS=180 \
  ./scripts/q3dev_run_mac.sh feature-verify-taa-on

Q3_UPSCALE_QUALITY=native Q3_RT_MIX=pure Q3_MATCH_PROFILE=960 \
  LAUNCH_COMMAND='map q3dm4; wait 120; quit' RUN_SECS=150 \
  ./scripts/q3dev_run_mac.sh verify-43-q3dm4
```

## Notes / Fixes Applied During Validation

- Fixed `scripts/q3_sweep_catalyst.sh` no-match `grep -c` handling, which was producing `0\n0` and false `ASSET_MISS` verdicts.
- Fixed saved sweep summary to include map names.
- Added `SWEEP_RUN_SECS` override and reran at 35s/map to get stable metrics for all maps.
