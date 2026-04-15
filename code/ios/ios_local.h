#ifndef __IOS_LOCAL_H__
#define __IOS_LOCAL_H__

#include "../qcommon/q_shared.h"
#include "../qcommon/qcommon.h"

void IN_Init(void);
void IN_Frame(void);
void IN_Shutdown(void);

void Quake3_Init(const char *basePath);
void Quake3_Frame(void);
void Q3Gamepad_SetState(float leftX, float leftY, float rightX, float rightY,
                        int firePressed, int jumpPressed, int crouchPressed);

/* Extended button state. Bit layout in Q3Gamepad_Buttons below. */
#define Q3_PAD_A              (1u << 0)
#define Q3_PAD_B              (1u << 1)
#define Q3_PAD_X              (1u << 2)
#define Q3_PAD_Y              (1u << 3)
#define Q3_PAD_LEFT_SHOULDER  (1u << 4)
#define Q3_PAD_RIGHT_SHOULDER (1u << 5)
#define Q3_PAD_LEFT_TRIGGER   (1u << 6)
#define Q3_PAD_RIGHT_TRIGGER  (1u << 7)
#define Q3_PAD_DPAD_UP        (1u << 8)
#define Q3_PAD_DPAD_DOWN      (1u << 9)
#define Q3_PAD_DPAD_LEFT      (1u << 10)
#define Q3_PAD_DPAD_RIGHT     (1u << 11)
#define Q3_PAD_MENU           (1u << 12)
#define Q3_PAD_OPTIONS        (1u << 13)
#define Q3_PAD_LEFT_THUMB     (1u << 14)
#define Q3_PAD_RIGHT_THUMB    (1u << 15)

void Q3Gamepad_SetButtons(unsigned int buttonMask);

#endif
