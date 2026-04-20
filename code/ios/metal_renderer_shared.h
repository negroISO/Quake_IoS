#ifndef METAL_RENDERER_SHARED_H
#define METAL_RENDERER_SHARED_H

#include <stdint.h>

#define Q3_METAL_WORLD_DRAWFLAG_SKY (1u << 5)
#define Q3_METAL_WORLD_DRAWFLAG_PORTAL (1u << 6)

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    float position[2];
    float texCoord[2];
    float color[4];
} Q3MetalVertex;

typedef struct {
    float position[3];
    float texCoord[2];
    float lightmapTexCoord[2];
    float color[4];
} Q3MetalWorldVertex;

typedef struct {
    float position[3];
    float texCoord[2];
    float color[4];
} Q3MetalEntityVertex;

typedef struct {
    uint32_t firstVertex;
    uint32_t vertexCount;
    uint32_t textureHandle;
    uint32_t blendMode;   /* 0=opaque/alpha (default UI), 3=filter (dst_color, zero) */
} Q3MetalDrawCmd;

#define Q3_MAX_TCMODS 4

typedef struct {
    uint32_t type;        /* 0=none,1=scroll,2=wave-sin,3=rotate,4=scale,5=turb */
    float params[4];
} Q3TcMod;

typedef struct {
    uint32_t textureHandle;
    uint32_t blendMode;   /* 0=opaque,1=add,2=alpha,3=filter,4=premult,5=skip */
    uint32_t tcGen;       /* 0=base,1=environment */
    /* Multi-tcMod chain (preserves ORDER from the .shader file).
     * Q3 stages frequently stack `tcMod turb` + `tcMod scroll` etc.
     * Chain is consumed left-to-right by the renderer; an unused
     * slot has type==0. */
    Q3TcMod tcMods[Q3_MAX_TCMODS];
    uint32_t tcModCount;
    uint32_t rgbGen;      /* 0=identity, 1=vertex, 2=lightingDiffuse, 3=wave */
    uint32_t alphaGen;    /* 0=identity, 1=vertex, 3=wave */
    uint32_t alphaFunc;   /* 0=none, 1=GT0, 2=GE128, 3=LT128 */
    uint32_t cullMode;    /* 0=CULL_BACK, 1=CULL_NONE (disable/twosided), 2=CULL_FRONT */
    uint32_t useLightmap; /* 1 if this stage sourced its map from `$lightmap` */
    /* `rgbGen wave <func> <base> <amp> <phase> <freq>` parameters.
     * func: 0=none,1=sin,2=triangle,3=square,4=sawtooth,5=inverseSawtooth,6=noise. */
    uint32_t rgbWaveFunc;
    float rgbWaveBase;
    float rgbWaveAmp;
    float rgbWavePhase;
    float rgbWaveFreq;
    /* `alphaGen wave …` parameters. Same func enumeration as rgbWaveFunc. */
    uint32_t alphaWaveFunc;
    float alphaWaveBase;
    float alphaWaveAmp;
    float alphaWavePhase;
    float alphaWaveFreq;
} Q3MetalWorldStage;

#define Q3_METAL_MAX_STAGES 4

typedef struct {
    uint32_t firstIndex;
    uint32_t indexCount;
    uint32_t lightmapTextureHandle;
    uint32_t stageCount;
    Q3MetalWorldStage stages[Q3_METAL_MAX_STAGES];
    uint32_t flags;
} Q3MetalWorldDrawCmd;

typedef struct {
    uint32_t firstIndex;
    uint32_t indexCount;
    uint32_t textureHandle;
    uint32_t flags;
} Q3MetalEntityDrawCmd;

typedef struct {
    uint32_t firstDraw;
    uint32_t drawCount;
    float origin[3];
    float axis[9];
} Q3MetalInlineModelInstance;

enum {
    Q3_METAL_WORLD_DRAWFLAG_ADDITIVE = 1u << 0,
    Q3_METAL_WORLD_DRAWFLAG_NOCULL = 1u << 1,
    Q3_METAL_WORLD_DRAWFLAG_LIGHTMAP_MULTIPLY = 1u << 2,
    Q3_METAL_WORLD_DRAWFLAG_ALPHA = 1u << 3,
    Q3_METAL_WORLD_DRAWFLAG_FILTER = 1u << 4,
    /* Shader explicitly declared `cull front` — render back faces (inverted).
     * Mutually exclusive with NOCULL; Swift picks .front cull when set. */
    Q3_METAL_WORLD_DRAWFLAG_CULL_FRONT = 1u << 7,
    /* Inline bmodel draw — WorldDrawUniforms.modelMatrix is non-identity and
     * driven by the owning scene entity's origin/axis each frame. */
    Q3_METAL_WORLD_DRAWFLAG_BMODEL = 1u << 8
};

enum {
    Q3_METAL_ENTITY_DRAWFLAG_DEPTHHACK = 1u << 0,
    Q3_METAL_ENTITY_DRAWFLAG_NOCULL = 1u << 1,
    Q3_METAL_ENTITY_DRAWFLAG_ADDITIVE = 1u << 2,
    Q3_METAL_ENTITY_DRAWFLAG_ALPHA = 1u << 3,
    Q3_METAL_ENTITY_DRAWFLAG_FILTER = 1u << 4,
    Q3_METAL_ENTITY_DRAWFLAG_FIRST_PERSON = 1u << 5,
    Q3_METAL_ENTITY_DRAWFLAG_PORTAL = 1u << 6
};

typedef struct {
    uint32_t frameNumber;
    uint32_t drawableWidth;
    uint32_t drawableHeight;
    uint32_t vertexCount;
    uint32_t commandCount;
    uint32_t worldVertexCount;
    uint32_t worldIndexCount;
    uint32_t worldCommandCount;
    uint32_t worldGeneration;
    uint32_t inlineModelCommandCount;
    uint32_t entityVertexCount;
    uint32_t entityIndexCount;
    uint32_t entityCommandCount;
    float clearColor[4];
} Q3MetalFrameSnapshot;

typedef struct {
    uint32_t handle;
    uint32_t width;
    uint32_t height;
    uint32_t generation;
    const uint8_t *rgbaBytes;
} Q3MetalTextureInfo;

typedef struct {
    float fovX;
    float fovY;
    float viewOrigin[3];
    float viewAxis[9];
} Q3MetalSceneView;

/* Portal camera captured from RT_PORTALSURFACE entities. Origin + axis
 * only; fov inherits from the main scene. Returned via
 * Q3MetalRenderer_GetPortalView() below. */
typedef struct {
    float origin[3];
    float axis[9];
} Q3MetalPortalView;

void Q3MetalRenderer_UpdateDrawableSize(int width, int height);
const Q3MetalFrameSnapshot *Q3MetalRenderer_GetFrameSnapshot(void);
const Q3MetalVertex *Q3MetalRenderer_GetVertices(void);
const Q3MetalDrawCmd *Q3MetalRenderer_GetDrawCommands(void);
const Q3MetalWorldVertex *Q3MetalRenderer_GetWorldVertices(void);
const uint32_t *Q3MetalRenderer_GetWorldIndices(void);
const Q3MetalWorldDrawCmd *Q3MetalRenderer_GetWorldDrawCommands(void);
const Q3MetalInlineModelInstance *Q3MetalRenderer_GetInlineModelInstances(void);
const Q3MetalEntityVertex *Q3MetalRenderer_GetEntityVertices(void);
const uint32_t *Q3MetalRenderer_GetEntityIndices(void);
const Q3MetalEntityDrawCmd *Q3MetalRenderer_GetEntityDrawCommands(void);
const Q3MetalSceneView *Q3MetalRenderer_GetSceneView(void);
int Q3MetalRenderer_GetTextureInfo(uint32_t textureHandle, Q3MetalTextureInfo *outInfo);
int Q3MetalRenderer_GetDebugRenderMode(void);
int Q3MetalRenderer_GetDebugPasses(void);
int Q3MetalRenderer_GetDrawWorld(void);
int Q3MetalRenderer_GetDrawEntities(void);
int Q3MetalRenderer_GetNoCull(void);
int Q3MetalRenderer_GetNoPortals(void);
int Q3MetalRenderer_GetPortalSmokeTest(void);

/* Diagnostic cvar — when nonzero the Swift world draw loop zeroes out
 * `WorldDrawUniforms.tcMod` on every draw, pinning UVs to their static
 * BSP-baked values. If "flying texture" artifacts disappear when this
 * is on, the root cause is in the tcMod parameter/uniform chain. If
 * artifacts persist, look further down (vertex/index offsets, state
 * leakage). */
int Q3MetalRenderer_GetDisableTcMod(void);

/* Returns nonzero if a RT_PORTALSURFACE was captured this frame and
 * fills *out with its origin + axis. Returns 0 if no portal entity
 * was seen (typical on maps without portals / mirrors). */
int Q3MetalRenderer_GetPortalView(Q3MetalPortalView *out);

/* Returns nonzero when the current map has portal BSP surfaces or the
 * current frame has portal-shader entities. Swift uses this to skip the
 * portal RTT pass on non-portal maps. Orthogonal to GetPortalView: a
 * map with portal surfaces but no RT_PORTALSURFACE captured this frame
 * still returns visible=true but GetPortalView returns 0. Caller should
 * combine both (and r_portalSmokeTest) to decide whether to render. */
int Q3MetalRenderer_HasVisiblePortal(void);

#ifdef __cplusplus
}
#endif

#endif
