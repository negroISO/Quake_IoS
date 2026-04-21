#ifndef METAL_RENDERER_SHARED_H
#define METAL_RENDERER_SHARED_H

#include <stdint.h>

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
} Q3MetalDrawCmd;

#define Q3_MAX_TCMODS 4

typedef struct {
    uint32_t type;        /* 0=none,1=scroll,2=wave-sin,3=rotate,4=scale,5=turb */
    float params[4];
} Q3TcMod;

typedef struct {
    uint32_t textureHandle;
    uint32_t blendMode;   /* 0=opaque,1=add,2=alpha,3=filter */
    uint32_t tcGen;       /* 0=base,1=environment */
    Q3TcMod tcMods[Q3_MAX_TCMODS];
    uint32_t tcModCount;
    uint32_t rgbGen;      /* 0=identity,1=vertex,2=lightingDiffuse,3=wave */
    uint32_t alphaGen;    /* 0=identity,1=vertex,3=wave */
    uint32_t alphaFunc;   /* 0=none, 1=GT0, 2=GE128, 3=LT128 */
    uint32_t cullMode;    /* 0=back,1=none,2=front */
    uint32_t useLightmap; /* 1 if stage sourced map from $lightmap */
    uint32_t rgbWaveFunc;
    float rgbWaveBase;
    float rgbWaveAmp;
    float rgbWavePhase;
    float rgbWaveFreq;
    uint32_t alphaWaveFunc;
    float alphaWaveBase;
    float alphaWaveAmp;
    float alphaWavePhase;
    float alphaWaveFreq;
} Q3MetalWorldStage;

#define Q3_METAL_MAX_STAGES 4

#define Q3_METAL_NO_FOG 0xFFFFFFFFu

typedef struct {
    uint32_t firstIndex;
    uint32_t indexCount;
    uint32_t lightmapTextureHandle;
    uint32_t flags;
    uint32_t stageCount;
    /* Fog volume index matching the per-world fog LUT stored C-side
     * (s_worldFogs[]). Q3_METAL_NO_FOG means the BSP's surface->fogNum
     * was -1 (surface lies outside any fog volume). Swift reads this
     * and, when the fog MSL pass ships, looks up color + distance by
     * this index. */
    uint32_t fogIndex;
    Q3MetalWorldStage stages[Q3_METAL_MAX_STAGES];
} Q3MetalWorldDrawCmd;

typedef struct {
    uint32_t firstIndex;
    uint32_t indexCount;
    uint32_t textureHandle;
    uint32_t flags;
} Q3MetalEntityDrawCmd;

enum {
    Q3_METAL_WORLD_DRAWFLAG_ADDITIVE = 1u << 0,
    Q3_METAL_WORLD_DRAWFLAG_NOCULL = 1u << 1,
    Q3_METAL_WORLD_DRAWFLAG_LIGHTMAP_MULTIPLY = 1u << 2,
    Q3_METAL_WORLD_DRAWFLAG_ALPHA = 1u << 3,
    Q3_METAL_WORLD_DRAWFLAG_FILTER = 1u << 4,
    Q3_METAL_WORLD_DRAWFLAG_SKY = 1u << 5,
    Q3_METAL_WORLD_DRAWFLAG_PORTAL = 1u << 6
};

enum {
    Q3_METAL_ENTITY_DRAWFLAG_DEPTHHACK = 1u << 0,
    Q3_METAL_ENTITY_DRAWFLAG_NOCULL = 1u << 1,
    Q3_METAL_ENTITY_DRAWFLAG_ADDITIVE = 1u << 2,
    Q3_METAL_ENTITY_DRAWFLAG_ALPHA = 1u << 3,
    Q3_METAL_ENTITY_DRAWFLAG_FILTER = 1u << 4
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

void Q3MetalRenderer_UpdateDrawableSize(int width, int height);
const Q3MetalFrameSnapshot *Q3MetalRenderer_GetFrameSnapshot(void);
const Q3MetalVertex *Q3MetalRenderer_GetVertices(void);
const Q3MetalDrawCmd *Q3MetalRenderer_GetDrawCommands(void);
const Q3MetalWorldVertex *Q3MetalRenderer_GetWorldVertices(void);
const uint32_t *Q3MetalRenderer_GetWorldIndices(void);
const Q3MetalWorldDrawCmd *Q3MetalRenderer_GetWorldDrawCommands(void);
/* Per-world fog LUT. fogIndex values on Q3MetalWorldDrawCmd are indices
 * into this array. Returns 0/NULL if the loaded map has no fog volumes.
 * Each entry's color is linear RGB and distance is world units. */
typedef struct {
    float color[3];
    float distance;
} Q3MetalWorldFog;
int Q3MetalRenderer_GetWorldFogCount(void);
const Q3MetalWorldFog *Q3MetalRenderer_GetWorldFogs(void);
const Q3MetalEntityVertex *Q3MetalRenderer_GetEntityVertices(void);
const uint32_t *Q3MetalRenderer_GetEntityIndices(void);
const Q3MetalEntityDrawCmd *Q3MetalRenderer_GetEntityDrawCommands(void);
const Q3MetalSceneView *Q3MetalRenderer_GetSceneView(void);
int Q3MetalRenderer_GetTextureInfo(uint32_t textureHandle, Q3MetalTextureInfo *outInfo);

#ifdef __cplusplus
}
#endif

#endif
