# q3vision_diff report

- pairs sampled: **7**
- parsed verdicts: **7** (0 parse failures)
- PASS / FAIL: **0 / 7** (0% pass)

## DIFF_TYPE histogram
- UI: **3**
- BLEND: **2**
- WORLD: **1**
- DECAL: **1**

## ROOT_CAUSE histogram
- `shader`: **3**
- `blendFunc`: **2**
- `unknown`: **2**

## Most-cited MISSING features (REF has, OURS doesn't)
- killfeed text (2×)
- correct entity textures (1×)
- ambient occlusion/shadows (1×)
- distinct color separation (1×)
- killfeed text ("Fredo was gunned down by THEINDIGO") (1×)
- architectural geometry (1×)
- window/skybox portal (1×)
- wall textures (1×)
- health/armor HUD elements (1×)
- blood decals on floor/walls (1×)
- entity model in foreground (1×)
- blood decals (1×)
- world textures (1×)
- entity shading (1×)
- lighting contrast (1×)

## Most-cited EXTRA features (OURS has, REF doesn't)
- yellow additive glow overlay across entire scene (1×)
- stairs (1×)
- different room layout (1×)
- incorrect entity placement (1×)
- yellow color cast/overexposure (1×)
- red streaks in upper left viewport (1×)

## Most-recurring observations
- The OURS image is heavily tinted with a bright yellow additive blend that washes out the entire scene. (1×)
- Entity models (player) are rendered as glowing silhouettes rather than textured meshes. (1×)
- Dark particles/decals in REF appear as high-contrast black spots against the yellow glow in OURS. (1×)
- The top-left corner of the screen is missing the game event notification (killfeed). (1×)
- All world geometry, entities, and lighting appear to match. (1×)
- The scene geometry in OURS is entirely different from REF; OURS shows a circular stone room with stairs, while REF shows a corridor with large arched windows. (1×)
- The weapon model and perspective differ significantly between the two renders. (1×)
- The environment assets (textures/meshes) do not match the reference frame. (1×)
- The reference image contains the game's event log (killfeed) in the top-left corner. (1×)
- The reference image shows a large numeric indicator (likely part of the HUD or a specific UI element) on the floor area. (1×)
- OURS is missing all 2D overlay/UI elements present in REF. (1×)
- The OURS image is a wide shot of the corridor, while REF is a close-up crop. (1×)
- Killfeed text ("Thanatar was machinegunned by Duffy...") is completely missing from OURS. (1×)
- Blood decals on the left wall and floor are significantly different in shape and placement compared to REF. (1×)
- The entity (player/monster) visible on the right side of REF is absent or out of frame in OURS. (1×)

## Per-frame verdicts
| frame | MATCH | DIFF_TYPE | ROOT_CAUSE | CONF |
|---|---|---|---|---|
| four_frame_119 | FAIL | BLEND | blendFunc | HIGH |
| four_frame_141 | FAIL | UI | shader | HIGH |
| four_frame_155 | FAIL | WORLD | unknown | HIGH |
| four_frame_227 | FAIL | UI | shader | HIGH |
| four_frame_235 | FAIL | UI | unknown | HIGH |
| four_frame_247 | FAIL | BLEND | blendFunc | HIGH |
| four_frame_249 | FAIL | DECAL | shader | HIGH |
