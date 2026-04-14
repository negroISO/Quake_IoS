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

typedef struct {
    uint32_t firstIndex;
    uint32_t indexCount;
    uint32_t textureHandle;
    uint32_t lightmapTextureHandle;
    uint32_t flags;
    float texCoordScale[2];
    float texCoordScroll[2];
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
    Q3_METAL_WORLD_DRAWFLAG_LIGHTMAP_MULTIPLY = 1u << 2
};

enum {
    Q3_METAL_ENTITY_DRAWFLAG_DEPTHHACK = 1u << 0,
    Q3_METAL_ENTITY_DRAWFLAG_NOCULL = 1u << 1
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
const Q3MetalEntityVertex *Q3MetalRenderer_GetEntityVertices(void);
const uint32_t *Q3MetalRenderer_GetEntityIndices(void);
const Q3MetalEntityDrawCmd *Q3MetalRenderer_GetEntityDrawCommands(void);
const Q3MetalSceneView *Q3MetalRenderer_GetSceneView(void);
int Q3MetalRenderer_GetTextureInfo(uint32_t textureHandle, Q3MetalTextureInfo *outInfo);

#ifdef __cplusplus
}
#endif

#endif
