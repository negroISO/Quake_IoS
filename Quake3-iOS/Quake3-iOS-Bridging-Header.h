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

/* Per-frame video capture hooks (see RE_TakeVideoFrame in metal_renderer_stub.c).
 * Swift reads CL_VideoRecording() each draw; if true, it reads back the
 * drawable's BGRA bytes and hands them off via Q3MetalRenderer_StoreVideoFrame. */
int CL_VideoRecording(void);
void Q3MetalRenderer_StoreVideoFrame(const unsigned char *bgra, int width, int height);

#endif
