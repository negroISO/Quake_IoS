# Q3RT parallax audit verdict — 2026-06-14

DoD evidence:
- HEAD commits:
  - `8d4ccb7f fix(parallax): add debug tint cvar`
  - `0bb1b060 fix(parallax): instrument bind site for diagnostic coverage`
- Catalyst logs:
  - `/Users/targus/Desktop/q3sim_sessions/2026-06-14_15-54-19__a81a167b_parallax-p0-q3dm1_mac/q3_diag.log`
  - `/Users/targus/Desktop/q3sim_sessions/2026-06-14_15-55-09__a81a167b_parallax-p0-q3tourney6_mac/q3_diag.log`
- Screenshot artifacts:
  - `/Users/targus/Desktop/q3sim_sessions/parallax_tint_artifact/frame_000031.png`
  - `/Users/targus/Desktop/q3sim_sessions/parallax_scale_compare_artifact/scale_0_frame_000031.png`
  - `/Users/targus/Desktop/q3sim_sessions/parallax_scale_compare_artifact/scale_2_0_frame_000031.png`
  - `/Users/targus/Desktop/q3sim_sessions/parallax_scale_compare_artifact/diff_x8.png`

Exact five target shader names from `docs/goal.md` did not appear in the captured q3dm1/q3tourney6 spawn PVS logs (`clangdark`, `diamond2c_ow`, `hfloor3`, `blocks17_ow`, `blocks18cgeomtrnx`). Per the goal fallback, substitute pool surfaces were used.

Qualified parallax bind examples:
- q3dm1: `textures/gothic_floor/metalbridge06` -> `useWorldPBR=1 heightTex=yes scale=0.5 tcGen=0`
- q3dm1: `textures/gothic_block/blocks18c` -> `useWorldPBR=1 heightTex=yes scale=0.5 tcGen=0`
- q3tourney6: `textures/base_floor/diamond2c` -> `useWorldPBR=1 heightTex=yes scale=0.5 tcGen=0`
- q3tourney6: `textures/sfx/pentfloor_diamond2c.tga` -> `useWorldPBR=1 heightTex=yes scale=0.5 tcGen=0`

Dropped-stage verdict:
- The observed target-family failures drop before `pbrHeightTexture(for:)`, at `worldTextureSelectionForPBRDebug` in `Quake3-iOS/MetalView.swift` lines 5486-5529.
- `isFXStage` is true at lines 5486-5488. If the FX atlas and `pbrMaterialHasAuxSlots(handle)` promotion checks fail, the function returns `useWorldPBR=false` at line 5529.
- The bind sites then intentionally compute `heightTex=nil` at lines 8282/8904 and set `parallaxParams.x=0` at lines 8296/8918.
- Concrete logged drops:
  - `textures/sfx/proto_zzztblu2.tga` -> `useWorldPBR=0 heightTex=nil classicFX=1`
  - `textures/gothic_block/blocks18cgeomtrn2.tga` -> `useWorldPBR=0 heightTex=nil blendMode=2 classicFX=1`

Conclusion:
- Normal world PBR height surfaces are not being dropped: they reach MTL texture slot 7 and the fragment parallax gate (`heightTex=yes`, `tcGen=0`).
- The remaining no-parallax cases seen in this audit are classic-FX routed stages, not DDS-load failures.
