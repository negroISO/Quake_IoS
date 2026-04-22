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
    /* 0=opaque, 1=additive (src=one, dst=one), 2=alpha (src-over),
     * 3=filter (src=dst_color, dst=zero, i.e. multiply). Propagated from
     * the shader's resolved blend so 2D stages like the loading-screen
     * `levelShotDetail` overlay multiply against the levelshot instead of
     * washing it out as plain alpha-over. */
    uint32_t blendMode;
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

#define Q3_METAL_MAX_LIGHTS 32

/* Dynamic light (point). Emitted by cgame for muzzle flashes, rocket/plasma
 * glow, explosion flashes, lightning halos. Fragment shaders add a radial
 * falloff contribution per active light to the lit color before fog.
 * Layout matches MSL packed_float3 + float pattern (32 bytes, 16-aligned). */
typedef struct {
    float origin[3];
    float radius;
    float color[3];
    float _pad;
} Q3MetalLight;

#define Q3_METAL_NO_FOG 0xFFFFFFFFu

/* Flare point harvested from the BSP's MST_FLARE surfaces. Renders as an
 * additive camera-facing billboard using the bundled gfx/misc/flare
 * texture at draw time. Color comes from the map compiler (light entity's
 * tint); origin is the light entity's world position. */
typedef struct {
    float origin[3];
    float color[3];
    uint32_t _pad0;
    uint32_t _pad1;
} Q3MetalFlare;

#define Q3_METAL_MAX_FLARES 512

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
    Q3_METAL_ENTITY_DRAWFLAG_FILTER = 1u << 4,
    /* Shader's stage uses `tcGen environment` (chrome/reflective — quad
     * shell, regen, battlesuit). Swift flips the entity fragment's tcGen
     * path to compute reflection-based UVs instead of mesh ST. */
    Q3_METAL_ENTITY_DRAWFLAG_TCGEN_ENV = 1u << 5
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
    uint32_t lightCount;
    /* Number of scenes captured this frame (world + HUD sub-scenes).
     * Each RE_RenderScene call pushes one entry into the scenes[] array
     * exposed by Q3MetalRenderer_GetSceneSnapshots. Swift iterates
     * scenes[0..sceneCount] and renders each with its own viewport. */
    uint32_t sceneCount;
    float clearColor[4];
} Q3MetalFrameSnapshot;

#define Q3_METAL_MAX_SCENES 8

#define Q3_METAL_SCENE_FLAG_NOWORLDMODEL  (1u << 0)
#define Q3_METAL_SCENE_FLAG_HYPERSPACE    (1u << 1)

/* Per-scene snapshot: everything Swift needs to render one viewport.
 * Entity and light ranges index into the shared per-frame pools
 * (Q3MetalRenderer_GetEntityVertices / GetEntityIndices /
 * GetEntityDrawCommands / GetLights). viewportW==0 means "full
 * drawable"; Swift should clamp the rect to drawable bounds. */
typedef struct {
    uint32_t viewportX;
    uint32_t viewportY;
    uint32_t viewportWidth;
    uint32_t viewportHeight;
    float viewOrigin[3];
    float viewAxis[9];
    float fovX;
    float fovY;
    uint32_t rdflags;
    uint32_t entityCommandFirst;
    uint32_t entityCommandCount;
    uint32_t lightFirst;
    uint32_t lightCount;
    float clearColor[4];
} Q3MetalSceneSnapshot;

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
const Q3MetalLight *Q3MetalRenderer_GetLights(void);
const Q3MetalSceneSnapshot *Q3MetalRenderer_GetSceneSnapshots(void);
int Q3MetalRenderer_GetFlareCount(void);
const Q3MetalFlare *Q3MetalRenderer_GetFlares(void);
uint32_t Q3MetalRenderer_GetFlareTextureHandle(void);
const Q3MetalSceneView *Q3MetalRenderer_GetSceneView(void);
int Q3MetalRenderer_GetTextureInfo(uint32_t textureHandle, Q3MetalTextureInfo *outInfo);

#ifdef __cplusplus
}
#endif

#endif
