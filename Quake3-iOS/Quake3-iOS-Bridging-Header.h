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

#endif
