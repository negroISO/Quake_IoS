#ifndef Q3_IOS_METAL_RENDERER_H
#define Q3_IOS_METAL_RENDERER_H

#include <stdbool.h>
#include <stdint.h>

#if defined(__OBJC__)
#import <CoreGraphics/CoreGraphics.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#else
typedef struct CGSize CGSize;
typedef struct objc_object* CAMetalLayer;
typedef struct objc_object* id;
#endif

#if __has_include("tr_public.h")
#include "tr_public.h"
#define Q3_METAL_HAS_RENDER_API 1
#elif __has_include("../../engine/renderer/core/tr_public.h")
#include "../../engine/renderer/core/tr_public.h"
#define Q3_METAL_HAS_RENDER_API 1
#elif __has_include("../../../code/renderercommon/tr_public.h")
#include "../../../code/renderercommon/tr_public.h"
#define Q3_METAL_HAS_RENDER_API 1
#else
#define Q3_METAL_HAS_RENDER_API 0
#endif

#ifdef __cplusplus
extern "C" {
#endif

typedef struct Q3MetalRendererState {
#if defined(__OBJC__)
    id<MTLDevice> device;
    id<MTLCommandQueue> commandQueue;
    id<MTLLibrary> shaderLibrary;
    id<MTLCommandBuffer> activeCommandBuffer;
    id<CAMetalDrawable> activeDrawable;
    CAMetalLayer *layer;
#else
    void *device;
    void *commandQueue;
    void *shaderLibrary;
    void *activeCommandBuffer;
    void *activeDrawable;
    void *layer;
#endif
    double clearRed;
    double clearGreen;
    double clearBlue;
    double clearAlpha;
    float drawableWidth;
    float drawableHeight;
    bool isInitialized;
} Q3MetalRendererState;

Q3MetalRendererState *Q3MetalRendererGetState(void);
void Q3MetalRendererAttachLayer(CAMetalLayer *layer);
void Q3MetalRendererSetDrawableSize(float width, float height);
void Q3MetalRendererSetClearColor(double red, double green, double blue, double alpha);
bool Q3MetalRendererBootstrap(void);
void Q3MetalRendererShutdown(void);

#if Q3_METAL_HAS_RENDER_API
refexport_t *GetRefAPI(int apiVersion, refimport_t *rimp);
#endif

#ifdef __cplusplus
}
#endif

#endif
