# RESUME — raster-parity campaign state (paused 2026-09-16 for machine transfer)

Read `docs/goal.md` first (objective + definition of done + open items).
This file is the operational resume card: what's done, exact recipes,
what's next, and the environment facts a new machine needs.

## 1. Landed this campaign (all pushed, branch metal-renderer-fresh)

| Commit | What |
|---|---|
| 2a3b2c62 | docs: Stage-83 viewmodel lighting fix recorded as landed (fde9d961) |
| dddf7bcf | fix(metal): honor match-profile name in drawable target (FOV/aspect) — THE viewmodel-placement + world-perspective fix. Gate: fov 90/73.74 exact; v1 parity 0.95x |

## 2. Verified findings (evidence in /Volumes/iOS/Quake_iOS27_Review_20260914/)

1. **FOV/aspect bug (FIXED)**: `mtkView(drawableSizeWillChange)` collapsed
   both match profiles to 960x444 on Catalyst (.phone idiom). Measured:
   logged fov aspect 2.16 == 960/444; gun silhouette 3x too small/low.
2. **Hall darkness = PBR sidecar divergence (config-solved)**: q3dm4 v2-hall
   surfaces are bare textures (no shader defs) routed through RTX-Remix PBR
   sidecars. Ladder: PBR-on 21.6 -> boot-time `r_pbrMaterials 0` -> 53.2
   (ioq3 71.0). Parity baseline MUST run PBR-off.
3. **v1 (small room) at 0.95x parity** on the fully clean config.
4. **Tone parity is config, not code**: match-profile pins r_gamma 1.15 +
   post chain (autoexposure/ACES/intensity 2.2). Neutralize per §3 recipe.
5. Rejected: Codex "double overbright" theory (direction contradiction —
   Metal measures DARKER in bright regions, a x4 theory predicts brighter;
   claimed diff absent from tree).
6. Demo-time AVI alignment is unreliable across engines — use FIXED
   `setviewpos` vantages (the harness does).

## 3. The deterministic parity harness (exact recipe)

Both legs render 1280x960, cg_draw2D 0, cg_drawGun 1, r_picmip 0,
r_gamma 1.0, r_overBrightBits 1, r_mapOverBrightBits 2.

**ioq3 leg** (binary /Volumes/iOS/q3_builds/ioq3-mac/build/Release/ioquake3.app,
run dir = mktemp with paks symlinked from Quake3-iOS/baseq3, demos copied —
four.dm_66 lives in pak6.pk3):

    cat > $RD/baseq3/autoexec.cfg <<'EOF'
    seta logfile 2
    wait 30
    devmap q3dm4
    wait 250
    seta r_gamma 1.0
    setviewpos 680 240 -120 180
    wait 40
    screenshot
    wait 10
    quit
    EOF
    ioquake3 +set fs_basepath $RD +set fs_homepath $RD +set r_mode -1 \
      +set r_customwidth 1280 +set r_customheight 960 +set r_fullscreen 0 \
      +set r_picmip 0 +set r_gamma 1.0 +set r_overBrightBits 1 \
      +set r_mapOverBrightBits 2 +set cg_draw2D 0 +set cg_drawGun 1
    # shots land in $RD/baseq3/screenshots/shotNNNN.tga (pixel-exact)

**Catalyst leg** (app: newest Debug-maccatalyst Q3_RT.app in DerivedData):

    env Q3_LAUNCH_COMMAND="developer 1; devmap q3dm4; wait 400; cg_fov 90; \
      r_gamma 1; r_postprocess_autoexposure 0; r_postprocess_tonemap 0; \
      r_postprocess_intensity 1.0; setviewpos 680 240 -120 180; wait 1500" \
      Q3_MATCH_PROFILE=metal_1280_25 Q3_RT_MIX=off Q3_UPSCALE_QUALITY=native \
      <app>/Contents/MacOS/Q3_RT -ApplePersistenceIgnoreState YES
    # container autoexec (~/Library/Containers/21579E2F-.../Data/Documents/baseq3/
    #   autoexec.cfg) must contain: seta r_pbrMaterials 0
    # cg_fov MUST come via Q3_LAUNCH_COMMAND (autoexec seta does NOT stick —
    #   archived cg_fov 95 in the container q3config wins otherwise)
    # capture: pin window via AppleScript to {20,40} size {1280,992}, then
    #   screencapture -x -R 20,72,1280,960  -> 2560x1920 -> LANCZOS to 1280x960

**Verify FOV in the log**: `grep "world frame" <log> | tail -1` must show
`fov=(90.00, 73.74)`. Anything else = config drift.

## 4. Canonical vantages (q3dm4)

- v1 small room: `setviewpos -192 -768 -320 90` (settles z=-333.9; 0.95x parity)
- v2 long hall: `setviewpos 680 240 -120 180` (the residual test case)
- ioq3 reference grids: v1 overall 59.9, v2 71.0; v2 grid
  [[43,63,95,95],[50,63,81,50],[64,74,81,50],[56,79,52,82]] (4x4 luma means)

## 5. Open defect — v2 bright-region residual

Clean-config Metal 48.8 vs ioq3 71.0 (0.69x): dark regions at parity
(43~43, 50~49), bright regions compressed to ~51-55 luma (ioq3 63-95),
ratios 0.54-0.87 surface-dependent. Lightmap-only views: Metal 129.9 vs
ioq3 156.7 (0.83x). Load-time shift verified equivalent to ioq3
(R_ColorShiftLightingBytes mirror, normalize-by-max). NOT: fog (yaw-invariant),
NOT missing lightmap data (debug2 bright everywhere), NOT PBR/parallax/IBL
(all off), NOT skip-on-handle-0 (refuted by grids).

**Next instrument (agreed)**: lightmap texel forensics — extract the actual
lightmap page bytes for an affected bright surface (e.g. the wall right of
v2 view) from the BSP, run BOTH engines' load-path math on the same bytes,
and diff. Suspects remaining: upload color-space, sampling filtering, or a
presentation-only debug-view difference (i.e., possibly TWO smaller issues).

## 6. Environment facts (new machine needs these)

- Repo: /Volumes/iOS/Projects/Quake_IoS_Phase9_Fork (branch metal-renderer-fresh,
  HEAD dddf7bcf, remote github.com/negroISO/Quake_IoS). CLAUDE.md is
  intentionally untracked (policy commit 57bb26a0).
- Results/evidence: /Volumes/iOS/Quake_iOS27_Review_20260914/ (raster_parity/
  is this campaign; dm4_demo_compare/ the previous one; GOAL_COMPLETION.md
  indexes the 2026-09-14/15 review).
- ioq3 reference build: /Volumes/iOS/q3_builds/ioq3-mac (branch `audit`, has
  r_stageaudit/r_renderaudit instrumentation).
- Catalyst container: ~/Library/Containers/21579E2F-6467-4375-8C90-BE862362FB0F
  (boot source=documents materials.json; autoexec currently has
  r_pbrMaterials 0 appended — see §3).
- iPhone 17 Pro Max: UUID 1EED792C-F233-511F-8DBD-15A47EC570A3, iOS 27.0
  (24A435), bundle com.quake3ios.rt; appDataContainer pull works
  (Documents/baseq3/videos, capture_ras2/3 lossless TGA sets).
- Codex invocation that works:
  `codex exec --yolo -c model_provider=Model_Studio_Token_Plan_Personal -m qwen3.8-max "$(cat brief.md)" < /dev/null`
  (CCR profile dead; DeepSeek disabled). Briefs live in the results folder.
- ddemby RAG: intermittent DNS (ddemby.home.arpa); shell route
  /Volumes/iOS/Development/q3rt-ask.sh when up.
- Auto-memory hook incident (solved): hooks resolve CLAUDE_PROJECT_DIR — if
  session cwd is /Volumes/iOS, the ACTIVE queue is
  /Volumes/iOS/.claude/auto-memory/dirty-files (NOT the repo path). Always
  check that path first when the Stop hook loops.
- DeviceSupport cleanup 2026-09-15: 15->53 GiB free; log
  reports/devicesupport_deletion_20260915.log.

## 7. On resume (ordered)

1. Rebuild both legs, re-verify fov=(90.00,73.74) + v1 0.95x (regression gate
   for the transfer).
2. Lightmap texel forensics on v2 bright surfaces (§5) — identify, then ONE
   minimal upstream-backed fix, gated on re-capture.
3. Weapon silhouette A/B post-FOV-fix (expect ~parity; verify area/centroid).
4. Broaden: q3dm1 (medallion/red wall), nv15 fixed vantages.
5. Only then: commit sequence review, Metal validation run, and (if all
   bars met) `RASTER_PARITY_VERIFIED`.
