#ifndef Quake3_iOS_Bridging_Header_h
#define Quake3_iOS_Bridging_Header_h

#include "../code/ios/metal_renderer_shared.h"

/* Stage25 portal-entity visibility bit. Carried in Q3MetalEntityDrawCmd.flags
 * for draws sourced from refEntity_t.renderfx & RF_THIRD_PERSON. Kept here
 * (rather than changing the shared ABI struct layout) so Swift can skip these
 * in the main view and include them in the portal/mirror entity pass. */
#ifndef Q3_METAL_ENTITY_DRAWFLAG_THIRD_PERSON
#define Q3_METAL_ENTITY_DRAWFLAG_THIRD_PERSON (1u << 11)
#endif

void Quake3_Init(const char *basePath);
void Quake3_Frame(void);
void Q3Gamepad_SetState(float leftX, float leftY, float rightX, float rightY,
                        int firePressed, int jumpPressed, int crouchPressed);

/* Extended button state bitmask. Bit layout in code/ios/ios_local.h (Q3_PAD_*). */
void Q3Gamepad_SetButtons(unsigned int buttonMask);

/* Execute a Q3 console command from Swift (on-screen console overlay). */
void Q3Exec_Command(const char *cmd);

/* Pre-engine-init mod selection. Must be called BEFORE Quake3_Init() —
 * the value is injected into the engine cmdline as `+set fs_game <mod>`
 * so Com_Init's pak loader discovers the mod's pk3 cascade in
 * <basepath>/<mod>/. Pass NULL or "" or "baseq3" to use vanilla.
 * Allowed chars: [A-Za-z0-9_-]. See LaunchMenuView mod rows. */
void Q3_SetBootMod(const char *modname);

/* Pre-engine-init render-resolution override for MetalFX upscaling.
 * Must be called BEFORE Quake3_Init(). When set (non-zero), the engine
 * uses these as r_customwidth/r_customheight — Q3 internally renders
 * at this size into an offscreen RT, and MTLFXSpatialScaler upscales
 * to the drawable for present. Pass 0/0 to keep the native-target
 * sizing intact (Native quality, no upscaling). */
void Q3_SetRenderResolution(int width, int height);

/* PBR Phase 1: Q3PBRMaterialPaths defined in code/ios/q3_pbr.h.
 * Each char* is an absolute filesystem path to a .dds file the Swift
 * renderer should lazy-load via MTKTextureLoader. NULL slots mean the
 * material doesn't ship that map (use a default). The struct + pointers
 * stay valid for the process lifetime. */
#include "../code/ios/q3_pbr.h"

/* Returns the PBR material paths for a registered Q3 texture, or NULL
 * if that texture had no PBR match at registration time. Cheap O(1)
 * lookup keyed on textureHandle. */
const Q3PBRMaterialPaths *Q3MetalRenderer_GetPBRMaterial(unsigned int textureHandle);
/* Name-based fallback for indirect-name cases (e.g. entity envmap stages
 * bound under `models/powerups/health/yellow` but whose atlas metadata
 * is keyed in materials.json under `textures/effects/envmapyel`). */
const Q3PBRMaterialPaths *Q3MetalRenderer_GetPBRMaterialByName(const char *name);

/* Swift→C PBR logging bridge. Wraps the C-side telemetry pipeline so the
 * Swift renderer's DDS-load events land in Documents/q3_diag.log next to
 * the C-side `[Q3-PBR]` lines. Pass any short tag for `type` (e.g.
 * "metal_pbr_swift") — it shows up in the file as `[Q3][type] message`. */
void Q3MetalRenderer_SwiftPBRLog(const char *type, const char *message);

/* Hardware-keyboard / trackpad / mouse input bridges. Called from Swift's
 * Q3InputView (an MTKView subclass) when the user presses a key on the iPad
 * Magic Keyboard, drags on the trackpad, or taps the trackpad. Each call
 * pushes one event into Q3's event queue (Sys_QueEvent), where it lands in
 * the same pipeline as gamepad events. No-op until engine init completes.
 *
 * q3Key values are the K_* enum from code/client/keycodes.h: ASCII for
 * letters/digits, K_ESCAPE=27, K_SPACE=32, K_BACKSPACE=127, K_MOUSE1=178.
 * down: 1 = pressed, 0 = released. */
void Q3Sys_KeyEvent(int q3Key, int down);
void Q3Sys_MouseMove(int dx, int dy);
/* Text-input event for console / cvar / player-name fields. Q3's
 * console reads SE_CHAR (not SE_KEY) for the actual character to
 * insert. Fire alongside SE_KEY on key-down for any printable char.
 * `ch` is a Unicode codepoint (typically ASCII 32–126). */
void Q3Sys_CharEvent(int ch);

/* Per-frame video capture hooks (see RE_TakeVideoFrame in metal_renderer_stub.c).
 * Swift reads CL_VideoRecording() each draw; if true, it reads back the
 * drawable's BGRA bytes and hands them off via Q3MetalRenderer_StoreVideoFrame. */
int CL_VideoRecording(void);
void Q3MetalRenderer_StoreVideoFrame(const unsigned char *bgra, int width, int height);
void Q3MetalRenderer_UpdateCaptureSize(int width, int height);

/* Native C/Obj-C renderer telemetry bridge. Implemented in Swift by
 * DebugTelemetry.swift and callable from the Metal renderer. */
void Q3DebugTelemetry_Log(const char *type, const char *message);

/* Final-image postprocess (port of Q2 MetalPostprocess). Compute kernel
 * runs in-place on the drawable after all render encoders, before
 * commandBuffer.present(). Gated by r_postprocess (default "1" — iPhone
 * OLED tuning; matches the policy that put TAA / sky-stable-proj /
 * underwater wiggle / async textures default-on, since iPhone has no
 * in-game console keyboard to toggle).
 * r_postprocess_intensity (default 2.2, range [0.5, 4.0]) and
 * r_postprocess_gamma (default 0.95, range [0.5, 2.5]) control the curve.
 * r_postprocess_autoexposure (default 1) replaces the fixed intensity with
 * scene-adaptive exposure clamped by r_exposure_min / r_exposure_max.
 * r_exposure_highlight_limit (default 0.9, 0 disables) caps auto exposure
 * from a full-frame P95-ish highlight sample before ACES.
 * Encoded after world+entity+UI passes; skipped when disabled. */
int Q3_PostprocessEnabled(void);
float Q3_PostprocessIntensity(void);
float Q3_PostprocessGamma(void);
/* T3 exposure parity: ACES filmic tonemap in q3_postprocess (1 = on). */
int Q3_PostprocessTonemap(void);
int Q3_PostprocessAutoExposure(void);
float Q3_ExposureMin(void);
float Q3_ExposureMax(void);
float Q3_ExposureHighlightLimit(void);

/* Audio backend (ios_main.m SNDDMA + ring buffer). Set the rate BEFORE
 * Quake3_Init so SNDDMA_Init allocates correctly. Pull is called from
 * the AVAudioSourceNode render block on the audio thread — no allocs,
 * no Swift traffic, no logging. */
void Q3IOS_AudioSetSampleRate(int rate);
int  Q3IOS_AudioPullStereo16(short *dest, int frames);

/* PBR Phase 4 runtime tunables (added as part of overnight Phase F).
 * Read by MetalView.swift each frame and pushed to the entity fragment
 * shader as a constant uniform replacing the hardcoded magic numbers.
 *
 *   r_pbr_rim_intensity (0..1.5, default 0.55) — peak rim brightness.
 *     Maps to mix(0.20, this, 1.0 - roughness) in the shader.
 *   r_pbr_rim_falloff   (1..5,   default 2.5)  — Fresnel exponent.
 *     Higher = narrower rim band; lower = broader.
 */
float Q3_PBRRimIntensity(void);
float Q3_PBRRimFalloff(void);

/* PBR Phase 6 IBL gate — drives Swift's procedural environment cubemap
 * binding to fragment slot 5 and the MSL IBL block inside `hasFullPBR`.
 * Default "1"; set "0" to A/B against Phase 5's flat 0.35 ambient floor.
 *
 * PBR Phase 5 gate — direct-sun Cook-Torrance + Burley GGX block. Default
 * "1"; set "0" to A/B against Phase 4 v6 (Fresnel rim only). */
int Q3_PBRIBLEnabled(void);
int Q3_PBRPhase5Enabled(void);

/* PBR Phase 6 v2 — map-specific skybox IBL.
 *
 * Q3_PBRIBLSkyboxName: writes the active r_pbr_ibl_skybox cvar value to
 *   `out` (null-terminated). Returns 1 on non-empty, 0 on empty/missing.
 * Q3MetalRenderer_FSReadFile/FSFreeFile: Swift→engine FS bridge so Swift
 *   can read pk3-packed env/<name>_*.tga skybox face textures, decode them
 *   with the minimal Type 2 truecolor reader in MetalView.swift, and build
 *   a real per-map IBL cube. Callers MUST FSFreeFile what FSReadFile gives. */
int Q3_PBRIBLSkyboxName(char *out, int max_len);
int Q3MetalRenderer_FSReadFile(const char *path, const unsigned char **out_buf, int *out_size);
void Q3MetalRenderer_FSFreeFile(const unsigned char *buf);

/* PBR Phase 8 — world-surface PBR shading toggles.
 * r_pbr_world_textures (1) gates the Cook-Torrance+IBL block on top of
 * Phase 3 normal-map shading inside q3_world_fragment.
 * r_pbr_world_ambient_boost (0.20) scales the diffuse-IBL fill that
 * brightens shadow side (compensates for no GI in raster).
 * r_pbr_world_spec_boost (0.40) scales the specular IBL highlight that
 * reflects active map skybox cube on metallic-leaning surfaces. */
int   Q3_PBRWorldEnabled(void);
float Q3_PBRWorldAmbientBoost(void);
float Q3_PBRWorldSpecBoost(void);
int   Q3_PBRWorldClassMatchEnabled(void);
int   Q3_PBRBakedLightmaps(void);
int   Q3_PBRSunShadows(void);
/* r_pbr_viewmodel_floor (default 0.65) — viewmodel-only PBR floor that
 * keeps fully-metallic first-person weapons readable under the neutral
 * low-energy procedural envCube. Applied per-fragment as
 * `base.rgb = max(base.rgb, texel.rgb * floor)` ONLY for RF_DEPTHHACK
 * draws (viewmodel). World surfaces, entity pickups, and HUD draws are
 * unchanged. Test range 0.35..0.75. Range-clamped 0..1 in the accessor. */
float Q3_PBRViewmodelFloor(void);
/* r_pbr_entity_floor (default 0.40) — non-viewmodel entity/pickup PBR
 * readability floor. Range-clamped 0..1 in the accessor; 0 disables. */
float Q3_PBREntityFloor(void);
/* r_world_debug_mode (default 0, not archived) — runtime swap for what was
 * a compile-time `Coordinator.worldDebugMode` constant. Drives the world
 * fragment shader's debug-mode branch: 0=normal, 1=base only, 2=lightmap
 * only, 3=UV1 viz, 4=vertex color only. Clamped to [0..4]. Not archived
 * so it doesn't stick across sessions. Use at the console: `r_world_debug_mode 2`. */
int Q3_WorldDebugMode(void);
/* Raster mirror/portal pass. r_portal_render (CVAR_ARCHIVE, default 1)
 * controls whether Swift renders a one-per-frame reflected portal view.
 * Q3MetalRenderer_GetPortalSurface returns 1 when the current world scene
 * submitted an RT_PORTALSURFACE; outOrigin3 is xyz, outAxis9 is row-major
 * axis[0..2][xyz] matching refEntity_t.axis. */
int Q3_PortalRender(void);
int Q3MetalRenderer_GetPortalSurface(float *outOrigin3, float *outAxis9);
/* r_pbr_envcube_grey (default 0.08, archived, clamped 0..1) — uniform
 * grey value the procedural envCube fills its faces with. The CVAR is
 * stored verbatim (`Q3_PBREnvCubeGreyRequested()` returns the raw user
 * value), but the EFFECTIVE value used to build the cube is clamped to
 * `max(requested, 0.04)` to keep full-metal world entities (chrome
 * pickups, dropped weapons) from rendering pure-black when the cube
 * goes too dim — a sweep showed `grey < 0.04` reliably broke metallic
 * pickup readability. Override the floor for debug captures by setting
 * `r_pbr_envcube_grey_debug 1`. Tunable per map family: q3dm17/space
 * 0.02 (debug) or 0.04 (production); dungeon/indoor 0.08; brighter
 * outdoor 0.12-0.15. `ensurePBREnvCube()` invalidates the cached
 * procedural cube when the EFFECTIVE value changes. */
float Q3_PBREnvCubeGrey(void);
float Q3_PBREnvCubeGreyRequested(void);
/* r_pbr_envcube_live (default 1, archived): when enabled and no authored
 * map skybox cube resolves, Swift replaces the procedural grey IBL fallback
 * with a small camera-position world cubemap refreshed over several frames.
 * 0 restores the legacy procedural envCube path exactly. */
int Q3_PBREnvCubeLive(void);
/* r_pbr_emissive_intensity_max (default 64.0, archived, clamped 0..1024) —
 * hard ceiling on the per-material emissive intensity that
 * `emissiveParamsForPBRMaterial` writes into `EntityUniforms.emissive
 * Params.w` and `WorldDrawUniforms.emissiveParams.w`. materials.json
 * authors values up to 982 (RTX Remix HDR pipeline) and the historical
 * default was 4.0 — after HDR resolve now uses tone mapping so the clamp
 * is permissive enough for 48/982 authored values and only guards absurd
 * numeric values. 64.0 is practical for gameplay; 1024.0 is the hard
 * guard. */
float Q3_PBREmissiveIntensityMax(void);
int   Q3_PBROnlyTextures(void);
/* r_pbr_texture_budget_mb (archived): maximum summed allocation for loaded
 * PBR sidecar MTLTextures. Default is device-scaled in C from
 * os_proc_available_memory()/2 capped at 4096 MB; 0 restores legacy
 * unlimited loading. Swift enforces via mip-drop on PBR sidecar DDS loads. */
int   Q3_PBRTextureBudgetMB(void);
float Q3_RTMix(void);
float Q3_SetRTMix(float mix);
float Q3_RTExposure(void);
float Q3_RTGamma(void);
float Q3_RTAmbient(void);
float Q3_RTNormalMix(void);
/* r_rt_normal_scale (default 0.0 = OFF) — RT normal-map perturbation strength
 * (Step 2c). 0 = no-op; tune up to 4 live to dial in RT bump mapping. */
float Q3_RTNormalScale(void);
/* RT lighting rebalance (both default 1.0 = current look). r_rt_lightmap_scale
 * [0..1] dims the baked-lightmap base; r_rt_direct_scale [0..8] boosts RT direct
 * (sun+local NEE). Lower lightmap + higher direct → RTX-Remix-like look. */
float Q3_RTLightmapScale(void);
float Q3_RTDirectScale(void);
/* Per-channel brightness cap for additive/additive-full ENTITY stages — tames
 * chrome envmap / explosion FX that bleed bright through dark RT walls. Default
 * 2.0, set high to disable. */
float Q3_RTEntityAdditiveMax(void);
float Q3_RTResolutionScale(void);
float Q3_RTTraceScale(void);
float Q3_RTBounces(void);
float Q3_RTTAA(void);
float Q3_RTTAAAlpha(void);
/* Stage 18 RT denoiser. 1 = MetalFX temporal denoised scaler path when
 * available; 0 = exact pre-Stage18 RT accumulate/upscale behavior. */
int   Q3_RTDenoise(void);
/* Stage 19 RT perf: r_rt_perf_hud is session-only instrumentation; shadow
 * budget is archived and defaults to the shipped Stage19 sun-only budget. */
int   Q3_RTPerfHUD(void);
int   Q3_RTShadowBudget(void);
/* Stage 17 RT G-buffer debug visualization. Session-only:
 * 0=off, 1=motion, 2=normal, 3=depth. */
int   Q3_RTDebugGBuffer(void);
int   Q3_RTEntities(void);
/* P0.2 — RT composite entity preservation (see
 * docs/2026-06-10-rt-gap-analysis-vs-rtx-remix.md).
 * Q3_RTPreserveEntities: 1 (default) = composite before entity/HUD passes
 * so raster viewmodel/pickups draw on top of the traced world; 0 = legacy
 * A/B mode, composite deferred until after the main entity pass.
 * Q3_RTDebugEntityMask: 1 = main-scene entity fragments render solid white
 * (coverage visualization of what is preserved over the RT composite). */
int   Q3_RTPreserveEntities(void);
int   Q3_RTDebugEntityMask(void);
/* P1 RT lights (NEE shadow rays). Light data baked offline from RTX Remix
 * per-map <map>_lights.usda into Resources/baseq3/pbr/lights/<map>.json.
 * Q3MetalRenderer_GetWorldMapName: current BSP path ("maps/q3dm6.bsp").
 * r_rt_lights (default 1) gates the kernel NEE block; r_rt_light_scale
 * (default 1.0) is a global intensity multiplier for on-device tuning. */
const char *Q3MetalRenderer_GetWorldMapName(void);
int   Q3_RTLights(void);
float Q3_RTLightScale(void);
/* P3 RT reflections. r_rt_reflections (Stage19 default 0) gates the one-level
 * specular reflect ray; r_rt_refl_roughness_max (default 0.45) is the
 * roughness ceiling above which no reflection ray is cast. */
int   Q3_RTReflections(void);
float Q3_RTReflRoughnessMax(void);
/* P2 RT HDR+bloom. r_rt_hdr keeps RT trace/accum in rgba16F; r_rt_bloom
 * spreads values above r_rt_bloom_threshold in blendRT before final LDR
 * composite. Radius is in RT-trace texels. */
int   Q3_RTHDR(void);
float Q3_RTBloom(void);
float Q3_RTBloomThreshold(void);
float Q3_RTBloomRadius(void);
/* Master scale for authored emissive (materials.json emissive_intensity) fed
 * into the RT HDR color. Default 1 = authored emissive-mask DDS active; 0 =
 * legacy albedo*0.8 fake. Stage27 maps authored HDR values with a compressive
 * curve before this scale; r_rt_emissive_maxev 0 restores the old hard clamp. */
float Q3_RTEmissive(void);
float Q3_RTEmissiveMaxEV(void);
/* Stage24 emissive area-light NEE. Default 0/off; when enabled the RT kernel
 * samples one emissive triangle per primary opaque hit and casts one shadow
 * ray toward it. */
int   Q3_RTEmissiveNEE(void);
/* RT atmosphere/miss-fill tuning. Defaults off: density=0 keeps the
 * historic raster-sky-preserve alpha path. When density > 0, the RT trace
 * applies neutral-grey distance fog and can alpha-fill AS misses via
 * r_rt_atmosphere_sky_alpha. */
float Q3_RTAtmosphereDensity(void);
float Q3_RTAtmosphereGrey(void);
float Q3_RTAtmosphereSkyAlpha(void);
float Q3_RTAtmosphereMax(void);
/* Height-map parallax for world surfaces (r_pbr_parallax_scale, default
 * 0.02, 0 = off). Only applied when the material ships a height DDS. */
float Q3_PBRParallaxScale(void);
int   Q3_PBRParallaxTint(void);

#endif
