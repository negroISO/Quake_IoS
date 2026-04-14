#ifndef Quake3_iOS_Bridging_Header_h
#define Quake3_iOS_Bridging_Header_h

#include "../code/ios/metal_renderer_shared.h"

void Quake3_Init(const char *basePath);
void Quake3_Frame(void);

#endif
