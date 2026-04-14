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

#endif
