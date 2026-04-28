# Resume — Quake3-iOS Metal port (as of 2026-01-28)

## Goal
- Native Metal renderer for Quake3-iOS (for VisionOS). iOS first.
- Current state: **2D UI/menus + 3D BSP world geometry render via Metal**. Gun model and text still missing.

## What already works
- App boots, audio/game loop runs.
- baseq3 can be bundled or in Documents. App no longer requires Documents only.
- Metal 2D pipeline draws menus/UI (uses DrawStretchPic).
- Metal 3D pipeline draws BSP world geometry (4849 surfaces on q3dm0).
- Full game lifecycle: server starts → client connects → cgame loads → LoadWorldMap → RenderScene.
- Partial shutdown preserves Metal device/window/pipelines during map transitions.
- Idle timer disabled to prevent screen auto-lock during gameplay.

## Key file changes already done
- `Quake3/renderermtl/tr_mtl_backend.mm`:
  - Creates Metal device/layer/command queue, clears each frame.
  - Added 2D Metal pipeline (shaders in `mtl_shaders.metal`).
  - Texture loading via `R_LoadTGA`/`R_LoadJPG`, stored in `mtlImages`.
  - `MTLimp_RegisterTexture`, `MTLimp_SetColor`, `MTLimp_DrawStretchPic` implemented.
  - 2D draws textured quads with alpha blending.
- `Quake3/renderermtl/tr_mtl_init.c`:
  - `RegisterShader` and `RegisterShaderNoMip` now call `MTLimp_RegisterTexture`.
  - `SetColor` and `DrawStretchPic` now call Metal backend.
- `Quake3/renderermtl/mtl_shaders.metal`: 2D vertex/fragment implemented.
- `Quake3-iOS/GameViewController.swift`: baseq3 lookup uses Documents or bundle; `fs_basepath` set accordingly; `r_useMetal 1`.
- `Quake3-iOS/MainMenuViewController.swift`: baseq3 detection uses Documents or bundle; extraction uses whichever is available.
- `Quake3-iOS.xcodeproj/project.pbxproj`:
  - Added Metal.framework, renderermtl files, `mtl_shaders.metal`.
  - Added build phase to copy baseq3 into app bundle at build time.
  - Disabled user script sandboxing for that copy phase.

## Last test result
- Built & installed to device; menus + 3D world render via Metal.
- Full game flow: CS_FREE → CS_CONNECTED → CS_PRIMED → CS_ACTIVE.
- BSP q3dm0 loaded: 113 shaders, 24587 verts, 47757 idx, 5023 surfs, 4849 rendered.
- RenderScene executing with correct fov/vieworg data.
- 2D HUD (health, ammo) renders correctly.
- Gun model NOT visible (entity rendering not implemented).
- Bot chat text NOT visible (font registration returns empty data).

## Completed 3D pipeline implementation

### What's implemented
- `mtl_shaders.metal`: 3D vertex/fragment shaders (`mtl3d_vertex`, `mtl3d_fragment`).
- `tr_mtl_backend.mm`:
  - `MTLimp_LoadWorldMap`: Parses BSP via `ri.FS_ReadFile`, extracts lumps, converts drawVert_t to GPU format, builds vertex/index buffers, registers surface textures. Offsets relative indices by firstVert.
  - `MTLimp_RenderScene`: Binds 3D pipeline, depth state, MVP matrix. Iterates all surfaces, binds textures, draws indexed primitives.
  - `MTLimp_BuildMVP`: Row-major view + projection matrix, transposed to column-major for Metal float4x4.
  - `MTLimp_BeginFrame`: Creates render pass with depth attachment (Depth32Float, cleared to 1.0).
  - `MTLimp_ShutdownPartial` / `MTLimp_ShutdownFull`: Split shutdown preserves Metal device during map transitions.
  - BeginFrame recovers from longjmp-orphaned Metal encoder/command buffer state.
- `tr_mtl_init.c`: `RE_MTL_Shutdown` calls partial/full based on `destroyWindow`. `IN_Shutdown` only called during full shutdown.
- `tr_mtl_backend.h`: Declares `MTLimp_ShutdownPartial`, `MTLimp_ShutdownFull`.
- `GameViewController.swift`: Idle timer disabled.

### Key bugs fixed
1. **mtlDevice nil during LoadWorldMap**: `re.Shutdown(qfalse)` destroyed everything. Fixed with partial/full shutdown split.
2. **Client stuck at CS_CONNECTED**: `IN_Shutdown` killed SDL input during partial shutdown. Fixed by only calling it during full shutdown.
3. **MVP projection matrix transposed**: `proj[11]` and `proj[14]` were swapped (column-major vs row-major mixing). Fixed.
4. **BSP indices relative to firstVert**: drawIndexes are offsets from surface's firstVert, not absolute. Fixed by adding firstVert during loading.

## NOT DONE YET (what to finish next)
1. **Entity rendering** (gun model, player models, items):
   - Implement `RE_MTL_AddRefEntityToScene` to collect entities.
   - Render entities with per-entity model-view-projection transforms.
   - Requires loading MD3 model geometry.
2. **Text rendering** (bot chat, console):
   - Implement `RE_MTL_RegisterFont` to load Q3 `.dat` font files.
   - Or verify bitmap charset (`gfx/2d/bigchars`) loads via `MTLimp_RegisterTexture`.
3. **Lightmaps**: BSP lightmap data is available but not yet used. Vertex colors are forced white.
4. **Shader stages**: Q3 .shader script parsing for multi-pass effects.
5. **PSO cache**: Metal Binary Archive to precompile pipelines on Mac and bundle.
6. **Patch surfaces**: BSP patch meshes (MST_PATCH) not yet rendered — only planar + triangle soup.
7. **Culling**: No frustum culling; all 4849 surfaces drawn every frame.

## Notes / constraints
- Use C functions from qcommon: need C linkage. `tr_mtl_backend.h` & `tr_mtl_local.h` now wrap C includes in `extern "C"` to fix linkage.
- `mtlWorld` should be cleared on shutdown; call `MTLimp_ClearWorld()` in `MTLimp_Shutdown()`.
- No PSO cache yet. Once 3D pipeline is stable, use Metal Binary Archive to precompile on Mac and bundle.

## Device build/install commands used
- Device UDID: `00008150-001E714A02C0401C` (iPhone "Yd-Mubarak MajMaj")
- Build (device):
  `xcodebuild -project Quake3-iOS.xcodeproj -scheme Quake3-iOS -destination 'id=00008150-001E714A02C0401C' -allowProvisioningUpdates -allowProvisioningDeviceRegistration DEVELOPMENT_TEAM=72MB2RMPTC CODE_SIGN_STYLE=Automatic PRODUCT_BUNDLE_IDENTIFIER=com.garrettcullum.quake3metal build`
- Install:
  `xcrun devicectl device install app --device 00008150-001E714A02C0401C /Users/targus/Library/Developer/Xcode/DerivedData/Quake3-iOS-giqfdkmnjcuenyaxpxgjwvjbggpl/Build/Products/Debug-iphoneos/Quake3-iOS.app`
- Launch:
  `xcrun devicectl device process launch --device 00008150-001E714A02C0401C --terminate-existing com.garrettcullum.quake3metal`

## Repo state (dirty files)
- `Quake3-iOS.xcodeproj/project.pbxproj`
- `Quake3-iOS/GameViewController.swift`
- `Quake3-iOS/MainMenuViewController.swift`
- `Quake3/client/cl_main.c`
- `Quake3/sdl/sdl_glimp.c`
- `Quake3/renderermtl/*` (new + modified)

## Next immediate action for Claude
1. Get user visual confirmation of 3D world rendering on device.
2. Implement entity rendering (gun model, player models) — `AddRefEntityToScene` + MD3 loading.
3. Fix text rendering (RegisterFont or bitmap charset).
4. Add lightmap support to BSP surfaces.
5. Add patch surface rendering (MST_PATCH — Bezier curves to triangle meshes).
