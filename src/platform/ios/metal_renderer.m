#import "metal_renderer.h"

#include <string.h>

#if defined(__OBJC__)
#import <Foundation/Foundation.h>
#endif

#if Q3_METAL_HAS_RENDER_API
refimport_t ri;
#endif

static Q3MetalRendererState s_rendererState;

#if Q3_METAL_HAS_RENDER_API
static glconfig_t s_glConfig;
static refexport_t s_refExports;
#endif

Q3MetalRendererState *Q3MetalRendererGetState(void) {
    return &s_rendererState;
}

void Q3MetalRendererAttachLayer(CAMetalLayer *layer) {
#if defined(__OBJC__)
    s_rendererState.layer = layer;
    if (layer != nil) {
        layer.device = s_rendererState.device;
        layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
        layer.framebufferOnly = YES;
    }
#else
    s_rendererState.layer = layer;
#endif
}

void Q3MetalRendererSetDrawableSize(float width, float height) {
    s_rendererState.drawableWidth = width;
    s_rendererState.drawableHeight = height;

#if Q3_METAL_HAS_RENDER_API
    s_glConfig.vidWidth = (int)width;
    s_glConfig.vidHeight = (int)height;
#endif

#if defined(__OBJC__)
    if (s_rendererState.layer != nil) {
        s_rendererState.layer.drawableSize = CGSizeMake(width, height);
    }
#endif
}

void Q3MetalRendererSetClearColor(double red, double green, double blue, double alpha) {
    s_rendererState.clearRed = red;
    s_rendererState.clearGreen = green;
    s_rendererState.clearBlue = blue;
    s_rendererState.clearAlpha = alpha;
}

bool Q3MetalRendererBootstrap(void) {
    if (s_rendererState.isInitialized) {
        return true;
    }

#if defined(__OBJC__)
    s_rendererState.device = MTLCreateSystemDefaultDevice();
    if (s_rendererState.device == nil) {
#if Q3_METAL_HAS_RENDER_API
        if (ri.Printf != NULL) {
            ri.Printf(PRINT_WARNING, "Metal: no default device available\n");
        }
#endif
        return false;
    }

    s_rendererState.commandQueue = [s_rendererState.device newCommandQueue];
    s_rendererState.shaderLibrary = [s_rendererState.device newDefaultLibrary];
#endif

    s_rendererState.isInitialized = true;
    return true;
}

void Q3MetalRendererShutdown(void) {
#if defined(__OBJC__)
    s_rendererState.activeDrawable = nil;
    s_rendererState.activeCommandBuffer = nil;
    s_rendererState.shaderLibrary = nil;
    s_rendererState.commandQueue = nil;
    s_rendererState.device = nil;
    s_rendererState.layer = nil;
#endif
    s_rendererState.isInitialized = false;
}

#if Q3_METAL_HAS_RENDER_API
static void RE_ShutdownStub(refShutdownCode_t code) {
    (void)code;
    Q3MetalRendererShutdown();
}

static void RE_BeginRegistrationStub(glconfig_t *config) {
    if (config != NULL) {
        *config = s_glConfig;
    }
}

static qhandle_t RE_RegisterModelStub(const char *name) {
    (void)name;
    return 0;
}

static qhandle_t RE_RegisterSkinStub(const char *name) {
    (void)name;
    return 0;
}

static qhandle_t RE_RegisterShaderStub(const char *name) {
    (void)name;
    return 0;
}

static qhandle_t RE_RegisterShaderNoMipStub(const char *name) {
    (void)name;
    return 0;
}

static void RE_LoadWorldMapStub(const char *name) {
    (void)name;
}

static void RE_SetWorldVisDataStub(const byte *vis) {
    (void)vis;
}

static void RE_EndRegistrationStub(void) {
}

static void RE_ClearSceneStub(void) {
}

static void RE_AddRefEntityToSceneStub(const refEntity_t *re, qboolean intShaderTime) {
    (void)re;
    (void)intShaderTime;
}

static void RE_AddPolyToSceneStub(qhandle_t hShader, int numVerts, const polyVert_t *verts, int num) {
    (void)hShader;
    (void)numVerts;
    (void)verts;
    (void)num;
}

static int RE_LightForPointStub(vec3_t point, vec3_t ambientLight, vec3_t directedLight, vec3_t lightDir) {
    (void)point;
    memset(ambientLight, 0, sizeof(vec3_t));
    memset(directedLight, 0, sizeof(vec3_t));
    memset(lightDir, 0, sizeof(vec3_t));
    return 0;
}

static void RE_AddLightToSceneStub(const vec3_t org, float intensity, float r, float g, float b) {
    (void)org;
    (void)intensity;
    (void)r;
    (void)g;
    (void)b;
}

static void RE_AddAdditiveLightToSceneStub(const vec3_t org, float intensity, float r, float g, float b) {
    (void)org;
    (void)intensity;
    (void)r;
    (void)g;
    (void)b;
}

static void RE_AddLinearLightToSceneStub(const vec3_t start, const vec3_t end, float intensity, float r, float g, float b) {
    (void)start;
    (void)end;
    (void)intensity;
    (void)r;
    (void)g;
    (void)b;
}

static void RE_RenderSceneStub(const refdef_t *fd) {
    (void)fd;
}

static void RE_SetColorStub(const float *rgba) {
    if (rgba == NULL) {
        Q3MetalRendererSetClearColor(0.02, 0.02, 0.02, 1.0);
        return;
    }

    Q3MetalRendererSetClearColor(rgba[0], rgba[1], rgba[2], rgba[3]);
}

static void RE_DrawStretchPicStub(float x, float y, float w, float h,
                                  float s1, float t1, float s2, float t2,
                                  qhandle_t hShader) {
    (void)x;
    (void)y;
    (void)w;
    (void)h;
    (void)s1;
    (void)t1;
    (void)s2;
    (void)t2;
    (void)hShader;
}

static void RE_DrawStretchRawStub(int x, int y, int w, int h, int cols, int rows,
                                  byte *data, int client, qboolean dirty) {
    (void)x;
    (void)y;
    (void)w;
    (void)h;
    (void)cols;
    (void)rows;
    (void)data;
    (void)client;
    (void)dirty;
}

static void RE_UploadCinematicStub(int w, int h, int cols, int rows, byte *data, int client, qboolean dirty) {
    (void)w;
    (void)h;
    (void)cols;
    (void)rows;
    (void)data;
    (void)client;
    (void)dirty;
}

static void RE_BeginFrameStub(stereoFrame_t stereoFrame) {
    (void)stereoFrame;
    (void)Q3MetalRendererBootstrap();

#if defined(__OBJC__)
    if (!s_rendererState.isInitialized || s_rendererState.commandQueue == nil) {
        return;
    }

    s_rendererState.activeCommandBuffer = [s_rendererState.commandQueue commandBuffer];
    if (s_rendererState.layer != nil) {
        s_rendererState.activeDrawable = [s_rendererState.layer nextDrawable];
    }
#endif
}

static void RE_EndFrameStub(int *frontEndMsec, int *backEndMsec) {
    if (frontEndMsec != NULL) {
        *frontEndMsec = 0;
    }

    if (backEndMsec != NULL) {
        *backEndMsec = 0;
    }

#if defined(__OBJC__)
    if (s_rendererState.activeCommandBuffer != nil) {
        if (s_rendererState.activeDrawable != nil) {
            [s_rendererState.activeCommandBuffer presentDrawable:s_rendererState.activeDrawable];
        }
        [s_rendererState.activeCommandBuffer commit];
    }

    s_rendererState.activeDrawable = nil;
    s_rendererState.activeCommandBuffer = nil;
#endif
}

static int R_MarkFragmentsStub(int numPoints, const vec3_t *points, const vec3_t projection,
                               int maxPoints, vec3_t pointBuffer, int maxFragments,
                               markFragment_t *fragmentBuffer) {
    (void)numPoints;
    (void)points;
    (void)projection;
    (void)maxPoints;
    (void)pointBuffer;
    (void)maxFragments;
    (void)fragmentBuffer;
    return 0;
}

static int R_LerpTagStub(orientation_t *tag, qhandle_t model, int startFrame, int endFrame,
                         float frac, const char *tagName) {
    (void)model;
    (void)startFrame;
    (void)endFrame;
    (void)frac;
    (void)tagName;

    if (tag != NULL) {
        memset(tag, 0, sizeof(*tag));
    }
    return 0;
}

static void R_ModelBoundsStub(qhandle_t model, vec3_t mins, vec3_t maxs) {
    (void)model;
    memset(mins, 0, sizeof(vec3_t));
    memset(maxs, 0, sizeof(vec3_t));
}

static void RE_RegisterFontStub(const char *fontName, int pointSize, fontInfo_t *font) {
    (void)fontName;
    (void)pointSize;
    if (font != NULL) {
        memset(font, 0, sizeof(*font));
    }
}

static void RE_RemapShaderStub(const char *oldShader, const char *newShader, const char *offsetTime) {
    (void)oldShader;
    (void)newShader;
    (void)offsetTime;
}

static qboolean RE_GetEntityTokenStub(char *buffer, int size) {
    if (buffer != NULL && size > 0) {
        buffer[0] = '\0';
    }
    return qfalse;
}

static qboolean R_inPVSStub(const vec3_t p1, const vec3_t p2) {
    (void)p1;
    (void)p2;
    return qfalse;
}

static void RE_TakeVideoFrameStub(int h, int w, byte *captureBuffer, byte *encodeBuffer, qboolean motionJpeg) {
    (void)h;
    (void)w;
    (void)captureBuffer;
    (void)encodeBuffer;
    (void)motionJpeg;
}

static void RE_ThrottleBackendStub(void) {
}

static void RE_FinishBloomStub(void) {
}

static void R_SetColorMappingsStub(void) {
}

static qboolean RE_CanMinimizeStub(void) {
    return qfalse;
}

static const glconfig_t *RE_GetConfigStub(void) {
    return &s_glConfig;
}

static void RE_VertexLightingStub(qboolean allowed) {
    (void)allowed;
}

static void RE_SyncRenderStub(void) {
}

refexport_t *GetRefAPI(int apiVersion, refimport_t *rimp) {
    if (rimp == NULL || apiVersion != REF_API_VERSION) {
        return NULL;
    }

    ri = *rimp;
    memset(&s_refExports, 0, sizeof(s_refExports));
    memset(&s_glConfig, 0, sizeof(s_glConfig));

    s_glConfig.vidWidth = (int)s_rendererState.drawableWidth;
    s_glConfig.vidHeight = (int)s_rendererState.drawableHeight;
    s_glConfig.deviceSupportsGamma = qfalse;
    s_glConfig.stereoEnabled = qfalse;

    s_refExports.Shutdown = RE_ShutdownStub;
    s_refExports.BeginRegistration = RE_BeginRegistrationStub;
    s_refExports.RegisterModel = RE_RegisterModelStub;
    s_refExports.RegisterSkin = RE_RegisterSkinStub;
    s_refExports.RegisterShader = RE_RegisterShaderStub;
    s_refExports.RegisterShaderNoMip = RE_RegisterShaderNoMipStub;
    s_refExports.LoadWorld = RE_LoadWorldMapStub;
    s_refExports.SetWorldVisData = RE_SetWorldVisDataStub;
    s_refExports.EndRegistration = RE_EndRegistrationStub;
    s_refExports.ClearScene = RE_ClearSceneStub;
    s_refExports.AddRefEntityToScene = RE_AddRefEntityToSceneStub;
    s_refExports.AddPolyToScene = RE_AddPolyToSceneStub;
    s_refExports.LightForPoint = RE_LightForPointStub;
    s_refExports.AddLightToScene = RE_AddLightToSceneStub;
    s_refExports.AddAdditiveLightToScene = RE_AddAdditiveLightToSceneStub;
    s_refExports.AddLinearLightToScene = RE_AddLinearLightToSceneStub;
    s_refExports.RenderScene = RE_RenderSceneStub;
    s_refExports.SetColor = RE_SetColorStub;
    s_refExports.DrawStretchPic = RE_DrawStretchPicStub;
    s_refExports.DrawStretchRaw = RE_DrawStretchRawStub;
    s_refExports.UploadCinematic = RE_UploadCinematicStub;
    s_refExports.BeginFrame = RE_BeginFrameStub;
    s_refExports.EndFrame = RE_EndFrameStub;
    s_refExports.MarkFragments = R_MarkFragmentsStub;
    s_refExports.LerpTag = R_LerpTagStub;
    s_refExports.ModelBounds = R_ModelBoundsStub;
    s_refExports.RegisterFont = RE_RegisterFontStub;
    s_refExports.RemapShader = RE_RemapShaderStub;
    s_refExports.GetEntityToken = RE_GetEntityTokenStub;
    s_refExports.inPVS = R_inPVSStub;
    s_refExports.TakeVideoFrame = RE_TakeVideoFrameStub;
    s_refExports.ThrottleBackend = RE_ThrottleBackendStub;
    s_refExports.FinishBloom = RE_FinishBloomStub;
    s_refExports.SetColorMappings = R_SetColorMappingsStub;
    s_refExports.CanMinimize = RE_CanMinimizeStub;
    s_refExports.GetConfig = RE_GetConfigStub;
    s_refExports.VertexLighting = RE_VertexLightingStub;
    s_refExports.SyncRender = RE_SyncRenderStub;

    return &s_refExports;
}
#endif
