#ifndef Quake3_iOS_Bridging_Header_h
#define Quake3_iOS_Bridging_Header_h

#include "../code/ios/metal_renderer_shared.h"

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

/* Native C/Obj-C renderer telemetry bridge. Implemented in Swift by
 * DebugTelemetry.swift and callable from the Metal renderer. */
void Q3DebugTelemetry_Log(const char *type, const char *message);

/* Final-image postprocess (port of Q2 MetalPostprocess). Compute kernel
 * runs in-place on the drawable after all render encoders, before
 * commandBuffer.present(). Gated by r_postprocess (default "1" — iPhone
 * OLED tuning; matches the policy that put TAA / sky-stable-proj /
 * underwater wiggle / async textures default-on, since iPhone has no
 * in-game console keyboard to toggle).
 * r_postprocess_intensity (default 1.5, range [0.5, 3.0]) and
 * r_postprocess_gamma (default 0.95, range [0.5, 2.5]) control the curve.
 * Encoded after world+entity+UI passes; skipped when disabled. */
int Q3_PostprocessEnabled(void);
float Q3_PostprocessIntensity(void);
float Q3_PostprocessGamma(void);

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

#endif
