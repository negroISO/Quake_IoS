// metal_renderer_stub.c — Phase 1 stub renderer providing GetRefAPI()
// Replaces the Vulkan renderer with no-op implementations

#include "../qcommon/q_shared.h"
#include "../qcommon/qfiles.h"
#include "../client/client.h"
#include "../renderercommon/tr_public.h"
#include "../renderer/tr_common.h"
#include "metal_renderer_shared.h"

#define LL(x) x=LittleLong(x)

#define Q3_METAL_MAX_VERTICES 65536
#define Q3_METAL_MAX_DRAWS 8192
#define Q3_METAL_MAX_TEXTURES 1024
#define Q3_METAL_MAX_MODELS 1024
#define Q3_METAL_MAX_REFENTITIES 1024

typedef struct {
    qboolean inUse;
    qboolean isWhite;
    qboolean failed;
    uint32_t generation;
    qhandle_t handle;
    int width;
    int height;
    byte *rgbaBytes;
    char name[MAX_QPATH];
} metalTexture_t;

refimport_t ri;

static glconfig_t s_glConfig;
static Q3MetalFrameSnapshot s_frameSnapshot;
static Q3MetalSceneView s_sceneView;
static Q3MetalVertex s_vertices[Q3_METAL_MAX_VERTICES];
static Q3MetalDrawCmd s_draws[Q3_METAL_MAX_DRAWS];
static uint32_t s_vertexCount;
static uint32_t s_drawCount;
static uint32_t s_sceneLogCounter;
static float s_currentColor[4] = { 1.0f, 1.0f, 1.0f, 1.0f };
static metalTexture_t s_textures[Q3_METAL_MAX_TEXTURES];
static qhandle_t s_nextTextureHandle = 1;
static qhandle_t s_whiteTextureHandle;
static qhandle_t s_skyTextureHandle;
static qhandle_t s_timHellBaseTextureHandle;
static qhandle_t s_timHellAddTextureHandle;
static qhandle_t *s_worldLightmapHandles;
static int s_worldLightmapCount;

typedef struct {
    qboolean inUse;
    qhandle_t handle;
    char name[MAX_QPATH];
    md3Header_t *md3;
} metalModel_t;

typedef struct {
    refEntity_t entity;
    qboolean mirrored;
    qboolean isSynthetic;  /* set by SynthesizeViewmodelEntity; cgame entities clear */
} metalSceneEntity_t;

typedef struct {
    qboolean loaded;
    uint32_t generation;
    uint32_t vertexCount;
    uint32_t indexCount;
    uint32_t drawCount;
    Q3MetalWorldVertex *vertices;
    uint32_t *indices;
    Q3MetalWorldDrawCmd *draws;
    /* Parallel table of animated shader slot per draw index.
     * Slot == -1 means static; >= 0 indexes s_shaderMap for per-frame
     * retargeting (fire/lava/teleport on world geometry). */
    int *animShaderSlots;
    uint32_t animatedDrawCount; /* number of draws with slot >= 0 */
    char name[MAX_QPATH];
} metalWorld_t;

static metalWorld_t s_world;
static metalModel_t s_models[Q3_METAL_MAX_MODELS];
static qhandle_t s_nextModelHandle = 1;
static metalSceneEntity_t s_sceneEntities[Q3_METAL_MAX_REFENTITIES];
static uint32_t s_sceneEntityCount;
static Q3MetalEntityVertex *s_entityVertices;
static uint32_t *s_entityIndices;
static Q3MetalEntityDrawCmd *s_entityDraws;
static uint32_t s_entityVertexCount;
static uint32_t s_entityIndexCount;
static uint32_t s_entityDrawCount;
static uint32_t s_entityVertexCapacity;
static uint32_t s_entityIndexCapacity;
static uint32_t s_entityDrawCapacity;
static uint32_t s_entityAcceptedThisFrame;
static uint32_t s_entityRejectedNullThisFrame;
static uint32_t s_entityRejectedTypeThisFrame;
static uint32_t s_entityRejectedModelThisFrame;

static void CopyColor(float *dst, const float *src) {
    dst[0] = src[0];
    dst[1] = src[1];
    dst[2] = src[2];
    dst[3] = src[3];
}

static metalTexture_t *FindTextureByHandle(qhandle_t handle) {
    int i;
    for (i = 0; i < Q3_METAL_MAX_TEXTURES; ++i) {
        if (s_textures[i].inUse && s_textures[i].handle == handle) {
            return &s_textures[i];
        }
    }
    return NULL;
}

static metalTexture_t *FindTextureByName(const char *name) {
    int i;
    for (i = 0; i < Q3_METAL_MAX_TEXTURES; ++i) {
        if (s_textures[i].inUse && !Q_stricmp(s_textures[i].name, name)) {
            return &s_textures[i];
        }
    }
    return NULL;
}

static metalTexture_t *AllocTextureSlot(void) {
    int i;
    for (i = 0; i < Q3_METAL_MAX_TEXTURES; ++i) {
        if (!s_textures[i].inUse) {
            Com_Memset(&s_textures[i], 0, sizeof(s_textures[i]));
            s_textures[i].inUse = qtrue;
            s_textures[i].handle = s_nextTextureHandle++;
            s_textures[i].generation = 1;
            return &s_textures[i];
        }
    }
    return NULL;
}

static metalModel_t *FindModelByHandle(qhandle_t handle) {
    int i;
    for (i = 0; i < Q3_METAL_MAX_MODELS; ++i) {
        if (s_models[i].inUse && s_models[i].handle == handle) {
            return &s_models[i];
        }
    }
    return NULL;
}

static metalModel_t *FindModelByName(const char *name) {
    int i;
    for (i = 0; i < Q3_METAL_MAX_MODELS; ++i) {
        if (s_models[i].inUse && !Q_stricmp(s_models[i].name, name)) {
            return &s_models[i];
        }
    }
    return NULL;
}

static metalModel_t *AllocModelSlot(void) {
    int i;
    for (i = 0; i < Q3_METAL_MAX_MODELS; ++i) {
        if (!s_models[i].inUse) {
            Com_Memset(&s_models[i], 0, sizeof(s_models[i]));
            s_models[i].inUse = qtrue;
            s_models[i].handle = 0x10000000 + s_nextModelHandle++;
            return &s_models[i];
        }
    }
    return NULL;
}

static qhandle_t EnsureWhiteTexture(void) {
    metalTexture_t *texture;
    byte *rgba;

    if (s_whiteTextureHandle != 0) {
        return s_whiteTextureHandle;
    }

    texture = AllocTextureSlot();
    if (texture == NULL) {
        return 0;
    }

    rgba = ri.Malloc(4);
    rgba[0] = 255;
    rgba[1] = 255;
    rgba[2] = 255;
    rgba[3] = 255;

    texture->isWhite = qtrue;
    texture->width = 1;
    texture->height = 1;
    texture->rgbaBytes = rgba;
    Q_strncpyz(texture->name, "*white", sizeof(texture->name));
    s_whiteTextureHandle = texture->handle;
    return s_whiteTextureHandle;
}

static qhandle_t RegisterRawTexture(const char *name, byte *rgba, int width, int height) {
    metalTexture_t *texture;

    if (rgba == NULL || width <= 0 || height <= 0) {
        return EnsureWhiteTexture();
    }

    texture = FindTextureByName(name);
    if (texture == NULL) {
        texture = AllocTextureSlot();
        if (texture == NULL) {
            ri.Free(rgba);
            return EnsureWhiteTexture();
        }
        Q_strncpyz(texture->name, name, sizeof(texture->name));
    } else if (texture->rgbaBytes != NULL) {
        ri.Free(texture->rgbaBytes);
        texture->rgbaBytes = NULL;
        texture->generation += 1;
    }

    texture->width = width;
    texture->height = height;
    texture->rgbaBytes = rgba;
    return texture->handle;
}

static qhandle_t EnsureSkyTexture(void) {
    metalTexture_t *texture;
    byte *rgba;

    if (s_skyTextureHandle != 0) {
        return s_skyTextureHandle;
    }

    texture = AllocTextureSlot();
    if (texture == NULL) {
        return EnsureWhiteTexture();
    }

    rgba = ri.Malloc(4);
    rgba[0] = 18;
    rgba[1] = 14;
    rgba[2] = 26;
    rgba[3] = 255;

    texture->width = 1;
    texture->height = 1;
    texture->rgbaBytes = rgba;
    Q_strncpyz(texture->name, "*sky_fallback", sizeof(texture->name));
    s_skyTextureHandle = texture->handle;
    return s_skyTextureHandle;
}

static qboolean IsSkyShaderName(const char *name) {
    if (name == NULL || name[0] == '\0') {
        return qfalse;
    }

    if (!Q_stricmpn(name, "textures/skies/", 15)) {
        return qtrue;
    }
    if (!Q_stricmpn(name, "env/", 4)) {
        return qtrue;
    }

    return qfalse;
}

static qboolean IsTimHellShaderName(const char *name) {
    return name != NULL && !Q_stricmp(name, "textures/skies/tim_hell");
}

static qboolean IsDrawableWorldShader(const dshader_t *shader) {
    int surfaceFlags;

    if (shader == NULL) {
        return qfalse;
    }

    surfaceFlags = LittleLong(shader->surfaceFlags);
    if (surfaceFlags & SURF_NODRAW) {
        return qfalse;
    }

    return qtrue;
}

static void SetupWorldDraw(Q3MetalWorldDrawCmd *draw,
                           uint32_t firstIndex,
                           uint32_t indexCount,
                           qhandle_t textureHandle,
                           qhandle_t lightmapTextureHandle,
                           uint32_t flags,
                           float scaleS,
                           float scaleT,
                           float scrollS,
                           float scrollT) {
    draw->firstIndex = firstIndex;
    draw->indexCount = indexCount;
    draw->textureHandle = (uint32_t)textureHandle;
    draw->lightmapTextureHandle = (uint32_t)lightmapTextureHandle;
    draw->flags = flags;
    draw->texCoordScale[0] = scaleS;
    draw->texCoordScale[1] = scaleT;
    draw->texCoordScroll[0] = scrollS;
    draw->texCoordScroll[1] = scrollT;
}

static qboolean TryLoadImageRGBA(const char *name, byte **rgba, int *width, int *height, char *resolvedName, size_t resolvedNameSize) {
    static const char *extensions[] = { ".tga", ".jpg", ".jpeg" };
    char base[MAX_QPATH];
    const char *ext;
    int i;

    *rgba = NULL;
    *width = 0;
    *height = 0;

    Q_strncpyz(base, name, sizeof(base));
    ext = COM_GetExtension(base);
    if (ext[0] != '\0') {
        COM_StripExtension(base, base, sizeof(base));
    }

    for (i = 0; i < ARRAY_LEN(extensions); ++i) {
        char candidate[MAX_QPATH];
        Com_sprintf(candidate, sizeof(candidate), "%s%s", base, extensions[i]);
        if (!Q_stricmp(extensions[i], ".tga")) {
            R_LoadTGA(candidate, rgba, width, height);
        } else {
            R_LoadJPG(candidate, rgba, width, height);
        }

        if (*rgba != NULL && *width > 0 && *height > 0) {
            Q_strncpyz(resolvedName, candidate, resolvedNameSize);
            return qtrue;
        }
    }

    return qfalse;
}

static const char *ShaderMap_Lookup(const char *name);
static qhandle_t ShaderMap_ResolveCurrentFrame(const char *name);
static int ShaderMap_FindAnimatedSlot(const char *name);
static qhandle_t ShaderMap_AnimatedSlotCurrentHandle(int slot);

static int s_pendingAnimSlot;

static qhandle_t RegisterTexture(const char *name) {
    metalTexture_t *existing;
    metalTexture_t *texture;
    byte *rgba;
    int width;
    int height;
    char resolvedName[MAX_QPATH];

    if (name == NULL || name[0] == '\0' || !Q_stricmp(name, "white")) {
        return EnsureWhiteTexture();
    }

    {
        static char seen[256][MAX_QPATH];
        static int seenCount = 0;
        int i;
        qboolean alreadySeen = qfalse;
        for (i = 0; i < seenCount; ++i) {
            if (!Q_stricmp(seen[i], name)) { alreadySeen = qtrue; break; }
        }
        if (!alreadySeen && seenCount < 256) {
            Q_strncpyz(seen[seenCount++], name, MAX_QPATH);
            ri.Printf(PRINT_ALL, "Metal asset request: '%s'\n", name);
        }
    }

    existing = FindTextureByName(name);
    if (existing != NULL) {
        return existing->handle;
    }

    {
        qhandle_t animHandle = ShaderMap_ResolveCurrentFrame(name);
        if (animHandle != 0) {
            return animHandle;
        }
    }

    if (!TryLoadImageRGBA(name, &rgba, &width, &height, resolvedName, sizeof(resolvedName))) {
        const char *mapped = ShaderMap_Lookup(name);
        if (mapped != NULL
            && TryLoadImageRGBA(mapped, &rgba, &width, &height, resolvedName, sizeof(resolvedName))) {
            ri.Printf(PRINT_DEVELOPER, "Metal shader: resolved '%s' -> '%s'\n", name, mapped);
        } else {
            ri.Printf(PRINT_WARNING, "Metal stub: failed to load UI texture '%s', falling back to white\n", name);
            return EnsureWhiteTexture();
        }
    }

    texture = AllocTextureSlot();
    if (texture == NULL) {
        ri.Printf(PRINT_WARNING, "Metal stub: texture registry full, dropping '%s'\n", name);
        ri.Free(rgba);
        return EnsureWhiteTexture();
    }

    texture->width = width;
    texture->height = height;
    texture->rgbaBytes = rgba;
    Q_strncpyz(texture->name, name, sizeof(texture->name));
    if (Q_stricmp(name, resolvedName)) {
        ri.Printf(PRINT_ALL, "Metal stub: loaded '%s' from '%s' (%dx%d)\n", name, resolvedName, width, height);
    }
    return texture->handle;
}

static qhandle_t EnsureTimHellBaseTexture(void) {
    if (s_timHellBaseTextureHandle == 0) {
        s_timHellBaseTextureHandle = RegisterTexture("textures/skies/killsky_1");
    }
    return s_timHellBaseTextureHandle != 0 ? s_timHellBaseTextureHandle : EnsureSkyTexture();
}

static qhandle_t EnsureTimHellAddTexture(void) {
    if (s_timHellAddTextureHandle == 0) {
        s_timHellAddTextureHandle = RegisterTexture("textures/skies/killsky_2");
    }
    return s_timHellAddTextureHandle != 0 ? s_timHellAddTextureHandle : EnsureSkyTexture();
}

static void PushStretchPicVertex(float x, float y, float s, float t, const float *rgba) {
    Q3MetalVertex *vertex;
    if (s_vertexCount >= Q3_METAL_MAX_VERTICES) {
        return;
    }

    vertex = &s_vertices[s_vertexCount++];
    vertex->position[0] = x;
    vertex->position[1] = y;
    vertex->texCoord[0] = s;
    vertex->texCoord[1] = t;
    CopyColor(vertex->color, rgba);
}

static void FreeWorldMapData(void) {
    if (s_world.vertices != NULL) {
        ri.Free(s_world.vertices);
    }
    if (s_world.indices != NULL) {
        ri.Free(s_world.indices);
    }
    if (s_world.draws != NULL) {
        ri.Free(s_world.draws);
    }
    if (s_world.animShaderSlots != NULL) {
        ri.Free(s_world.animShaderSlots);
    }
    if (s_worldLightmapHandles != NULL) {
        ri.Free(s_worldLightmapHandles);
        s_worldLightmapHandles = NULL;
    }
    s_worldLightmapCount = 0;
    Com_Memset(&s_world, 0, sizeof(s_world));
}

static void FreeEntitySceneData(void) {
    if (s_entityVertices != NULL) {
        ri.Free(s_entityVertices);
        s_entityVertices = NULL;
    }
    if (s_entityIndices != NULL) {
        ri.Free(s_entityIndices);
        s_entityIndices = NULL;
    }
    if (s_entityDraws != NULL) {
        ri.Free(s_entityDraws);
        s_entityDraws = NULL;
    }

    s_entityVertexCount = 0;
    s_entityIndexCount = 0;
    s_entityDrawCount = 0;
    s_entityVertexCapacity = 0;
    s_entityIndexCapacity = 0;
    s_entityDrawCapacity = 0;
}

static void FreeModelData(void) {
    int i;
    for (i = 0; i < Q3_METAL_MAX_MODELS; ++i) {
        if (s_models[i].inUse && s_models[i].md3 != NULL) {
            ri.Free(s_models[i].md3);
            s_models[i].md3 = NULL;
        }
    }
    Com_Memset(s_models, 0, sizeof(s_models));
    s_nextModelHandle = 1;
}

static qboolean EnsureEntitySceneCapacity(uint32_t vertexCount, uint32_t indexCount, uint32_t drawCount) {
    if (vertexCount > s_entityVertexCapacity) {
        Q3MetalEntityVertex *newVertices = ri.Malloc(vertexCount * sizeof(*newVertices));
        if (newVertices == NULL) {
            return qfalse;
        }
        if (s_entityVertices != NULL) {
            ri.Free(s_entityVertices);
        }
        s_entityVertices = newVertices;
        s_entityVertexCapacity = vertexCount;
    }

    if (indexCount > s_entityIndexCapacity) {
        uint32_t *newIndices = ri.Malloc(indexCount * sizeof(*newIndices));
        if (newIndices == NULL) {
            return qfalse;
        }
        if (s_entityIndices != NULL) {
            ri.Free(s_entityIndices);
        }
        s_entityIndices = newIndices;
        s_entityIndexCapacity = indexCount;
    }

    if (drawCount > s_entityDrawCapacity) {
        Q3MetalEntityDrawCmd *newDraws = ri.Malloc(drawCount * sizeof(*newDraws));
        if (newDraws == NULL) {
            return qfalse;
        }
        if (s_entityDraws != NULL) {
            ri.Free(s_entityDraws);
        }
        s_entityDraws = newDraws;
        s_entityDrawCapacity = drawCount;
    }

    return qtrue;
}

static float ByteToVisibleColor(byte value) {
    float normalized = (float)value / 255.0f;
    return 0.25f + normalized * 0.75f;
}

#define Q3_METAL_PATCH_SUBDIVISIONS 5

static void LerpDrawVert(const drawVert_t *a, const drawVert_t *b, drawVert_t *out) {
    int i;

    for (i = 0; i < 3; ++i) {
        out->xyz[i] = 0.5f * (a->xyz[i] + b->xyz[i]);
        out->normal[i] = 0.5f * (a->normal[i] + b->normal[i]);
    }
    for (i = 0; i < 2; ++i) {
        out->st[i] = 0.5f * (a->st[i] + b->st[i]);
        out->lightmap[i] = 0.5f * (a->lightmap[i] + b->lightmap[i]);
    }
    for (i = 0; i < 4; ++i) {
        out->color.rgba[i] = (byte)(((int)a->color.rgba[i] + (int)b->color.rgba[i]) >> 1);
    }
}

static void EvalQuadraticDrawVert(const drawVert_t *a, const drawVert_t *b, const drawVert_t *c, float t, drawVert_t *out) {
    drawVert_t ab;
    drawVert_t bc;
    drawVert_t result;
    float omt = 1.0f - t;
    int i;

    for (i = 0; i < 3; ++i) {
        ab.xyz[i] = omt * a->xyz[i] + t * b->xyz[i];
        bc.xyz[i] = omt * b->xyz[i] + t * c->xyz[i];
        ab.normal[i] = omt * a->normal[i] + t * b->normal[i];
        bc.normal[i] = omt * b->normal[i] + t * c->normal[i];
    }
    for (i = 0; i < 2; ++i) {
        ab.st[i] = omt * a->st[i] + t * b->st[i];
        bc.st[i] = omt * b->st[i] + t * c->st[i];
        ab.lightmap[i] = omt * a->lightmap[i] + t * b->lightmap[i];
        bc.lightmap[i] = omt * b->lightmap[i] + t * c->lightmap[i];
    }
    for (i = 0; i < 4; ++i) {
        ab.color.rgba[i] = (byte)(omt * a->color.rgba[i] + t * b->color.rgba[i]);
        bc.color.rgba[i] = (byte)(omt * b->color.rgba[i] + t * c->color.rgba[i]);
    }

    LerpDrawVert(&ab, &bc, &result);

    for (i = 0; i < 3; ++i) {
        out->xyz[i] = omt * ab.xyz[i] + t * bc.xyz[i];
        out->normal[i] = omt * ab.normal[i] + t * bc.normal[i];
    }
    for (i = 0; i < 2; ++i) {
        out->st[i] = omt * ab.st[i] + t * bc.st[i];
        out->lightmap[i] = omt * ab.lightmap[i] + t * bc.lightmap[i];
    }
    for (i = 0; i < 4; ++i) {
        out->color.rgba[i] = (byte)(omt * ab.color.rgba[i] + t * bc.color.rgba[i]);
    }
}

static void EmitWorldVertex(Q3MetalWorldVertex *dest, const drawVert_t *source) {
    dest->position[0] = LittleFloat(source->xyz[0]);
    dest->position[1] = LittleFloat(source->xyz[1]);
    dest->position[2] = LittleFloat(source->xyz[2]);
    dest->texCoord[0] = LittleFloat(source->st[0]);
    dest->texCoord[1] = LittleFloat(source->st[1]);
    dest->lightmapTexCoord[0] = LittleFloat(source->lightmap[0]);
    dest->lightmapTexCoord[1] = LittleFloat(source->lightmap[1]);
    dest->color[0] = ByteToVisibleColor(source->color.rgba[0]);
    dest->color[1] = ByteToVisibleColor(source->color.rgba[1]);
    dest->color[2] = ByteToVisibleColor(source->color.rgba[2]);
    dest->color[3] = 1.0f;
}

static void LoadWorldLightmaps(const dheader_t *header, const char *mapName) {
    const byte *lightmapBytes;
    int lumpLength;
    int lightmapCount;
    int i;

    lumpLength = LittleLong(header->lumps[LUMP_LIGHTMAPS].filelen);
    if (lumpLength <= 0) {
        return;
    }

    lightmapCount = lumpLength / (LIGHTMAP_WIDTH * LIGHTMAP_HEIGHT * 3);
    if (lightmapCount <= 0) {
        return;
    }

    s_worldLightmapHandles = ri.Malloc(lightmapCount * sizeof(*s_worldLightmapHandles));
    if (s_worldLightmapHandles == NULL) {
        return;
    }
    Com_Memset(s_worldLightmapHandles, 0, lightmapCount * sizeof(*s_worldLightmapHandles));
    s_worldLightmapCount = lightmapCount;
    lightmapBytes = (const byte *)header + LittleLong(header->lumps[LUMP_LIGHTMAPS].fileofs);

    for (i = 0; i < lightmapCount; ++i) {
        byte *rgba = ri.Malloc(LIGHTMAP_WIDTH * LIGHTMAP_HEIGHT * 4);
        const byte *source = lightmapBytes + i * LIGHTMAP_WIDTH * LIGHTMAP_HEIGHT * 3;
        int pixel;
        char lightmapName[MAX_QPATH];

        if (rgba == NULL) {
            break;
        }

        for (pixel = 0; pixel < LIGHTMAP_WIDTH * LIGHTMAP_HEIGHT; ++pixel) {
            rgba[pixel * 4 + 0] = source[pixel * 3 + 0];
            rgba[pixel * 4 + 1] = source[pixel * 3 + 1];
            rgba[pixel * 4 + 2] = source[pixel * 3 + 2];
            rgba[pixel * 4 + 3] = 255;
        }

        Com_sprintf(lightmapName, sizeof(lightmapName), "*lightmap:%s:%d", mapName, i);
        s_worldLightmapHandles[i] = RegisterRawTexture(lightmapName, rgba, LIGHTMAP_WIDTH, LIGHTMAP_HEIGHT);
    }
}

static qboolean IsSupportedWorldSurface(const dsurface_t *surface, int drawVertCount, int drawIndexCount) {
    int surfaceType = LittleLong(surface->surfaceType);
    int firstVert = LittleLong(surface->firstVert);
    int numVerts = LittleLong(surface->numVerts);
    int firstIndex = LittleLong(surface->firstIndex);
    int numIndexes = LittleLong(surface->numIndexes);

    if (surfaceType == MST_PLANAR || surfaceType == MST_TRIANGLE_SOUP) {
        if (numVerts <= 0 || numIndexes < 3) {
            return qfalse;
        }
        if (firstVert < 0 || firstIndex < 0 || firstVert + numVerts > drawVertCount || firstIndex + numIndexes > drawIndexCount) {
            return qfalse;
        }
        return qtrue;
    }

    if (surfaceType == MST_PATCH) {
        int patchWidth = LittleLong(surface->patchWidth);
        int patchHeight = LittleLong(surface->patchHeight);

        if (numVerts <= 0 || firstVert < 0 || firstVert + numVerts > drawVertCount) {
            return qfalse;
        }
        if (patchWidth < 3 || patchHeight < 3 || (patchWidth & 1) == 0 || (patchHeight & 1) == 0) {
            return qfalse;
        }
        if (patchWidth * patchHeight > numVerts) {
            return qfalse;
        }
        return qtrue;
    }

    return qfalse;
}

static qboolean BuildFallbackSceneView(vec3_t vieworg, vec3_t axis0, vec3_t axis1, vec3_t axis2, float *fovX, float *fovY) {
    vec3_t viewAngles;
    float aspect;

    if (!s_world.loaded || !cl.snap.valid) {
        return qfalse;
    }

    vieworg[0] = cl.snap.ps.origin[0];
    vieworg[1] = cl.snap.ps.origin[1];
    vieworg[2] = cl.snap.ps.origin[2] + cl.snap.ps.viewheight;

    VectorCopy(cl.viewangles, viewAngles);
    if (VectorCompare(viewAngles, vec3_origin)) {
        VectorCopy(cl.snap.ps.viewangles, viewAngles);
    }

    {
        vec3_t axes[3];
        AnglesToAxis(viewAngles, axes);
        VectorCopy(axes[0], axis0);
        VectorCopy(axes[1], axis1);
        VectorCopy(axes[2], axis2);
    }

    *fovX = 90.0f;
    aspect = s_glConfig.vidHeight > 0 ? (float)s_glConfig.vidWidth / (float)s_glConfig.vidHeight : (2796.0f / 1290.0f);
    *fovY = atanf(tanf((*fovX) * (float)M_PI / 360.0f) / aspect) * 360.0f / (float)M_PI;
    return qtrue;
}

static qboolean LoadMD3ModelData(const char *modName, void *buffer, int fileSize, md3Header_t **outModel) {
    int i;
    int j;
    md3Header_t *pinmodel;
    md3Header_t *hdr;
    md3Frame_t *frame;
    md3Tag_t *tag;
    md3Surface_t *surf;
    uint32_t version;
    uint32_t size;
    uint32_t bytesToEnd;

    *outModel = NULL;
    if (buffer == NULL || fileSize <= 0) {
        ri.Printf(PRINT_WARNING, "Metal model: '%s' rejected: no data (fileSize=%d)\n", modName, fileSize);
        return qfalse;
    }
    if ((uint32_t)fileSize < sizeof(md3Header_t)) {
        ri.Printf(PRINT_WARNING, "Metal model: '%s' rejected: file too small for MD3 header (fileSize=%d, need>=%u)\n",
            modName, fileSize, (unsigned)sizeof(md3Header_t));
        return qfalse;
    }

    pinmodel = (md3Header_t *)buffer;
    version = LittleLong(pinmodel->version);
    ri.Printf(PRINT_DEVELOPER, "Metal model: inspecting '%s' (fileSize=%d, version=%u)\n", modName, fileSize, version);
    if (version != MD3_VERSION) {
        ri.Printf(PRINT_WARNING, "Metal model: %s has wrong version (%u should be %u)\n", modName, version, MD3_VERSION);
        return qfalse;
    }

    size = LittleLong(pinmodel->ofsEnd);
    if (size == 0 || size > (uint32_t)fileSize) {
        ri.Printf(PRINT_WARNING, "Metal model: '%s' rejected: corrupted header (ofsEnd=%u, fileSize=%d)\n",
            modName, size, fileSize);
        return qfalse;
    }

    hdr = ri.Malloc(size);
    if (hdr == NULL) {
        return qfalse;
    }
    Com_Memcpy(hdr, buffer, size);

    LL(hdr->ident);
    LL(hdr->version);
    LL(hdr->flags);
    LL(hdr->numFrames);
    LL(hdr->numTags);
    LL(hdr->numSurfaces);
    LL(hdr->numSkins);
    LL(hdr->ofsFrames);
    LL(hdr->ofsTags);
    LL(hdr->ofsSurfaces);
    LL(hdr->ofsEnd);

    if (hdr->numFrames < 1 || hdr->numSurfaces < 0 ||
        hdr->ofsFrames > size || hdr->ofsTags > size || hdr->ofsSurfaces > size) {
        ri.Printf(PRINT_WARNING,
            "Metal model: '%s' rejected: invalid header ranges (frames=%d tags=%d surfaces=%d ofsFrames=%d ofsTags=%d ofsSurfaces=%d size=%u)\n",
            modName, hdr->numFrames, hdr->numTags, hdr->numSurfaces,
            hdr->ofsFrames, hdr->ofsTags, hdr->ofsSurfaces, size);
        ri.Free(hdr);
        return qfalse;
    }

    frame = (md3Frame_t *)((byte *)hdr + hdr->ofsFrames);
    for (i = 0; i < hdr->numFrames; ++i, ++frame) {
        frame->radius = LittleFloat(frame->radius);
        for (j = 0; j < 3; ++j) {
            frame->bounds[0][j] = LittleFloat(frame->bounds[0][j]);
            frame->bounds[1][j] = LittleFloat(frame->bounds[1][j]);
            frame->localOrigin[j] = LittleFloat(frame->localOrigin[j]);
        }
    }

    tag = (md3Tag_t *)((byte *)hdr + hdr->ofsTags);
    for (i = 0; i < hdr->numTags * hdr->numFrames; ++i, ++tag) {
        tag->name[sizeof(tag->name) - 1] = '\0';
        for (j = 0; j < 3; ++j) {
            tag->origin[j] = LittleFloat(tag->origin[j]);
            tag->axis[0][j] = LittleFloat(tag->axis[0][j]);
            tag->axis[1][j] = LittleFloat(tag->axis[1][j]);
            tag->axis[2][j] = LittleFloat(tag->axis[2][j]);
        }
    }

    surf = (md3Surface_t *)((byte *)hdr + hdr->ofsSurfaces);
    for (i = 0; i < hdr->numSurfaces; ++i) {
        md3Shader_t *shader;
        md3Triangle_t *tri;
        md3St_t *st;
        md3XyzNormal_t *xyz;

        bytesToEnd = size - (uint32_t)((byte *)surf - (byte *)hdr);
        if (bytesToEnd < sizeof(*surf)) {
            ri.Printf(PRINT_WARNING,
                "Metal model: '%s' rejected: surface %d truncated before header (bytesToEnd=%u need>=%u)\n",
                modName, i, bytesToEnd, (unsigned)sizeof(*surf));
            ri.Free(hdr);
            return qfalse;
        }

        LL(surf->ident);
        LL(surf->flags);
        LL(surf->numFrames);
        LL(surf->numShaders);
        LL(surf->numVerts);
        LL(surf->numTriangles);
        LL(surf->ofsTriangles);
        LL(surf->ofsShaders);
        LL(surf->ofsSt);
        LL(surf->ofsXyzNormals);
        LL(surf->ofsEnd);

        if (surf->ofsTriangles > bytesToEnd || surf->ofsShaders > bytesToEnd ||
            surf->ofsSt > bytesToEnd || surf->ofsXyzNormals > bytesToEnd || surf->ofsEnd > bytesToEnd) {
            ri.Printf(PRINT_WARNING,
                "Metal model: '%s' rejected: surface %d has invalid offsets (tri=%d shaders=%d st=%d xyz=%d end=%d bytesToEnd=%u)\n",
                modName, i, surf->ofsTriangles, surf->ofsShaders, surf->ofsSt,
                surf->ofsXyzNormals, surf->ofsEnd, bytesToEnd);
            ri.Free(hdr);
            return qfalse;
        }

        surf->name[sizeof(surf->name) - 1] = '\0';
        Q_strlwr(surf->name);

        shader = (md3Shader_t *)((byte *)surf + surf->ofsShaders);
        for (j = 0; j < surf->numShaders; ++j, ++shader) {
            shader->name[sizeof(shader->name) - 1] = '\0';
        }

        tri = (md3Triangle_t *)((byte *)surf + surf->ofsTriangles);
        for (j = 0; j < surf->numTriangles; ++j, ++tri) {
            LL(tri->indexes[0]);
            LL(tri->indexes[1]);
            LL(tri->indexes[2]);
        }

        st = (md3St_t *)((byte *)surf + surf->ofsSt);
        for (j = 0; j < surf->numVerts; ++j, ++st) {
            st->st[0] = LittleFloat(st->st[0]);
            st->st[1] = LittleFloat(st->st[1]);
        }

        xyz = (md3XyzNormal_t *)((byte *)surf + surf->ofsXyzNormals);
        for (j = 0; j < surf->numVerts * surf->numFrames; ++j, ++xyz) {
            xyz->xyz[0] = LittleShort(xyz->xyz[0]);
            xyz->xyz[1] = LittleShort(xyz->xyz[1]);
            xyz->xyz[2] = LittleShort(xyz->xyz[2]);
            xyz->normal = LittleShort(xyz->normal);
        }

        surf = (md3Surface_t *)((byte *)surf + surf->ofsEnd);
    }

    *outModel = hdr;
    ri.Printf(PRINT_ALL, "Metal model: loaded '%s' frames=%d tags=%d surfaces=%d\n",
        modName, hdr->numFrames, hdr->numTags, hdr->numSurfaces);
    return qtrue;
}

static qboolean TryRegisterModelPath(const char *name, metalModel_t *modelSlot) {
    void *fileBuffer;
    int fileSize;
    md3Header_t *md3;

    fileSize = ri.FS_ReadFile(name, &fileBuffer);
    if (fileSize <= 0 || fileBuffer == NULL) {
        ri.Printf(PRINT_DEVELOPER, "Metal model: '%s' not present in pk3 (optional, fileSize=%d)\n",
            name, fileSize);
        return qfalse;
    }

    if (!LoadMD3ModelData(name, fileBuffer, fileSize, &md3)) {
        ri.FS_FreeFile(fileBuffer);
        return qfalse;
    }

    ri.FS_FreeFile(fileBuffer);
    Q_strncpyz(modelSlot->name, name, sizeof(modelSlot->name));
    modelSlot->md3 = md3;
    return qtrue;
}

static qhandle_t ResolveAndRegisterModel(const char *name) {
    metalModel_t *existing;
    metalModel_t *modelSlot;
    char candidate[MAX_QPATH];

    existing = FindModelByName(name);
    if (existing != NULL) {
        return existing->handle;
    }

    modelSlot = AllocModelSlot();
    if (modelSlot == NULL) {
        ri.Printf(PRINT_WARNING, "Metal model: model registry full, dropping '%s'\n", name);
        return 0;
    }

    if (TryRegisterModelPath(name, modelSlot)) {
        return modelSlot->handle;
    }

    if (COM_GetExtension(name)[0] == '\0') {
        Com_sprintf(candidate, sizeof(candidate), "%s.md3", name);
        if (TryRegisterModelPath(candidate, modelSlot)) {
            Q_strncpyz(modelSlot->name, name, sizeof(modelSlot->name));
            return modelSlot->handle;
        }
    }

    Com_Memset(modelSlot, 0, sizeof(*modelSlot));
    ri.Printf(PRINT_WARNING, "Metal model: failed to load '%s'\n", name);
    return 0;
}

static qboolean LoadWorldMapData(const char *name) {
    void *fileBuffer = NULL;
    dheader_t *header;
    dshader_t *shaders;
    drawVert_t *drawVerts;
    int *drawIndexes;
    dsurface_t *surfaces;
    int shaderCount;
    int drawVertCount;
    int drawIndexCount;
    int surfaceCount;
    int i;
    uint32_t totalVertices = 0;
    uint32_t totalIndices = 0;
    uint32_t totalDraws = 0;
    uint32_t vertexCursor = 0;
    uint32_t indexCursor = 0;
    uint32_t drawCursor = 0;
    uint32_t skyDraws = 0;
    uint32_t planarDraws = 0;
    uint32_t patchDraws = 0;
    uint32_t triSoupDraws = 0;
    uint32_t skippedNoDrawSurfaces = 0;

    static const uint32_t defaultWorldFlags = Q3_METAL_WORLD_DRAWFLAG_NOCULL;

    if (ri.FS_ReadFile(name, &fileBuffer) <= 0 || fileBuffer == NULL) {
        ri.Printf(PRINT_WARNING, "Metal world: failed to read BSP '%s'\n", name);
        return qfalse;
    }

    header = (dheader_t *)fileBuffer;
    if (LittleLong(header->version) != BSP_VERSION) {
        ri.Printf(PRINT_WARNING, "Metal world: '%s' has unsupported BSP version %d\n", name, LittleLong(header->version));
        ri.FS_FreeFile(fileBuffer);
        return qfalse;
    }

    drawVerts = (drawVert_t *)((byte *)fileBuffer + LittleLong(header->lumps[LUMP_DRAWVERTS].fileofs));
    drawIndexes = (int *)((byte *)fileBuffer + LittleLong(header->lumps[LUMP_DRAWINDEXES].fileofs));
    surfaces = (dsurface_t *)((byte *)fileBuffer + LittleLong(header->lumps[LUMP_SURFACES].fileofs));
    shaders = (dshader_t *)((byte *)fileBuffer + LittleLong(header->lumps[LUMP_SHADERS].fileofs));

    shaderCount = LittleLong(header->lumps[LUMP_SHADERS].filelen) / (int)sizeof(dshader_t);
    drawVertCount = LittleLong(header->lumps[LUMP_DRAWVERTS].filelen) / (int)sizeof(drawVert_t);
    drawIndexCount = LittleLong(header->lumps[LUMP_DRAWINDEXES].filelen) / (int)sizeof(int);
    surfaceCount = LittleLong(header->lumps[LUMP_SURFACES].filelen) / (int)sizeof(dsurface_t);

    for (i = 0; i < surfaceCount; ++i) {
        const dsurface_t *surface = &surfaces[i];
        int surfaceType = LittleLong(surface->surfaceType);
        int patchWidth;
        int patchHeight;
        int shaderNum;

        if (!IsSupportedWorldSurface(surface, drawVertCount, drawIndexCount)) {
            continue;
        }

        shaderNum = LittleLong(surface->shaderNum);
        if (shaderNum < 0 || shaderNum >= shaderCount) {
            ri.Printf(PRINT_WARNING, "Metal world: skipping surface %d with invalid shader %d in '%s'\n", i, shaderNum, name);
            continue;
        }
        if (!IsDrawableWorldShader(&shaders[shaderNum])) {
            skippedNoDrawSurfaces += 1;
            continue;
        }

        if (surfaceType == MST_PATCH) {
            uint32_t stageCount = IsTimHellShaderName(shaders[shaderNum].shader) ? 2u : 1u;
            patchWidth = LittleLong(surface->patchWidth);
            patchHeight = LittleLong(surface->patchHeight);
            totalVertices += (uint32_t)((patchWidth - 1) / 2) * (uint32_t)((patchHeight - 1) / 2) *
                             (Q3_METAL_PATCH_SUBDIVISIONS + 1) * (Q3_METAL_PATCH_SUBDIVISIONS + 1);
            totalIndices += (uint32_t)((patchWidth - 1) / 2) * (uint32_t)((patchHeight - 1) / 2) *
                            Q3_METAL_PATCH_SUBDIVISIONS * Q3_METAL_PATCH_SUBDIVISIONS * 6;
            totalDraws += (uint32_t)((patchWidth - 1) / 2) * (uint32_t)((patchHeight - 1) / 2) * stageCount;
            patchDraws += (uint32_t)((patchWidth - 1) / 2) * (uint32_t)((patchHeight - 1) / 2);
        } else {
            int numVerts = LittleLong(surface->numVerts);
            int numIndexes = LittleLong(surface->numIndexes);
            uint32_t stageCount = IsTimHellShaderName(shaders[shaderNum].shader) ? 2u : 1u;

            if (numIndexes % 3) {
                numIndexes -= numIndexes % 3;
            }
            totalVertices += (uint32_t)numVerts;
            totalIndices += (uint32_t)numIndexes;
            totalDraws += stageCount;

            if (surfaceType == MST_PLANAR) {
                planarDraws += 1;
            } else if (surfaceType == MST_TRIANGLE_SOUP) {
                triSoupDraws += 1;
            }
        }
    }

    if (totalVertices == 0 || totalIndices == 0 || totalDraws == 0) {
        ri.Printf(PRINT_WARNING, "Metal world: no drawable BSP surfaces found in '%s'\n", name);
        ri.FS_FreeFile(fileBuffer);
        return qfalse;
    }

    FreeWorldMapData();
    LoadWorldLightmaps(header, name);

    s_world.vertices = ri.Malloc(totalVertices * sizeof(*s_world.vertices));
    s_world.indices = ri.Malloc(totalIndices * sizeof(*s_world.indices));
    s_world.draws = ri.Malloc(totalDraws * sizeof(*s_world.draws));
    s_world.animShaderSlots = ri.Malloc(totalDraws * sizeof(*s_world.animShaderSlots));
    s_world.animatedDrawCount = 0;
    if (s_world.animShaderSlots != NULL) {
        uint32_t _i;
        for (_i = 0; _i < totalDraws; ++_i) s_world.animShaderSlots[_i] = -1;
    }
    if (s_world.vertices == NULL || s_world.indices == NULL || s_world.draws == NULL) {
        ri.Printf(PRINT_WARNING, "Metal world: allocation failed for '%s'\n", name);
        FreeWorldMapData();
        ri.FS_FreeFile(fileBuffer);
        return qfalse;
    }

    for (i = 0; i < surfaceCount; ++i) {
        const dsurface_t *surface = &surfaces[i];
        int surfaceType = LittleLong(surface->surfaceType);
        int firstVert;
        int numVerts;
        int firstIndex;
        int numIndexes;
        int patchWidth;
        int patchHeight;
        int shaderNum;
        uint32_t baseVertex;
        qhandle_t textureHandle;
        qhandle_t lightmapHandle;
        int lightmapNum;
        qboolean hasLightmap;
        uint32_t worldFlags;
        int j;

        if (!IsSupportedWorldSurface(surface, drawVertCount, drawIndexCount)) {
            continue;
        }

        firstVert = LittleLong(surface->firstVert);
        numVerts = LittleLong(surface->numVerts);
        firstIndex = LittleLong(surface->firstIndex);
        numIndexes = LittleLong(surface->numIndexes);
        shaderNum = LittleLong(surface->shaderNum);
        lightmapNum = LittleLong(surface->lightmapNum);
        hasLightmap = qfalse;

        if (shaderNum < 0 || shaderNum >= shaderCount) {
            continue;
        }
        if (!IsDrawableWorldShader(&shaders[shaderNum])) {
            continue;
        }

        if (IsSkyShaderName(shaders[shaderNum].shader)) {
            textureHandle = EnsureSkyTexture();
            skyDraws += 1;
        } else {
            textureHandle = RegisterTexture(shaders[shaderNum].shader);
        }

        /* Record animated-shader slot for this surface so RE_RenderScene
         * can re-resolve the textureHandle each frame. Without this,
         * world fire/lava/teleport surfaces cache frame-0 forever.
         * Patch surfaces emit multiple draws, so we stash the slot and
         * apply after each SetupWorldDraw below. */
        s_pendingAnimSlot = ShaderMap_FindAnimatedSlot(shaders[shaderNum].shader);
        lightmapHandle = EnsureWhiteTexture();
        worldFlags = defaultWorldFlags;
        if (!IsSkyShaderName(shaders[shaderNum].shader) && lightmapNum >= 0 && lightmapNum < s_worldLightmapCount) {
            lightmapHandle = s_worldLightmapHandles[lightmapNum];
            hasLightmap = qtrue;
            worldFlags |= Q3_METAL_WORLD_DRAWFLAG_LIGHTMAP_MULTIPLY;
        }

        if (surfaceType == MST_PATCH) {
            int patchX;
            int patchY;

            patchWidth = LittleLong(surface->patchWidth);
            patchHeight = LittleLong(surface->patchHeight);

            for (patchY = 0; patchY < patchHeight - 1; patchY += 2) {
                for (patchX = 0; patchX < patchWidth - 1; patchX += 2) {
                    drawVert_t control[3][3];
                    int stepY;

                    for (j = 0; j < 3; ++j) {
                        int k;
                        for (k = 0; k < 3; ++k) {
                            control[j][k] = drawVerts[firstVert + (patchY + j) * patchWidth + (patchX + k)];
                        }
                    }

                    baseVertex = vertexCursor;
                    s_world.draws[drawCursor].firstIndex = indexCursor;

                    for (stepY = 0; stepY <= Q3_METAL_PATCH_SUBDIVISIONS; ++stepY) {
                        float v = (float)stepY / (float)Q3_METAL_PATCH_SUBDIVISIONS;
                        drawVert_t row[3];
                        int stepX;

                        for (j = 0; j < 3; ++j) {
                            EvalQuadraticDrawVert(&control[0][j], &control[1][j], &control[2][j], v, &row[j]);
                        }

                        for (stepX = 0; stepX <= Q3_METAL_PATCH_SUBDIVISIONS; ++stepX) {
                            float u = (float)stepX / (float)Q3_METAL_PATCH_SUBDIVISIONS;
                            drawVert_t evaluated;

                            EvalQuadraticDrawVert(&row[0], &row[1], &row[2], u, &evaluated);
                            EmitWorldVertex(&s_world.vertices[vertexCursor++], &evaluated);
                        }
                    }

                    for (stepY = 0; stepY < Q3_METAL_PATCH_SUBDIVISIONS; ++stepY) {
                        int stepX;
                        for (stepX = 0; stepX < Q3_METAL_PATCH_SUBDIVISIONS; ++stepX) {
                            uint32_t row0 = baseVertex + (uint32_t)stepY * (Q3_METAL_PATCH_SUBDIVISIONS + 1);
                            uint32_t row1 = row0 + (Q3_METAL_PATCH_SUBDIVISIONS + 1);
                            uint32_t i0 = row0 + (uint32_t)stepX;
                            uint32_t i1 = i0 + 1;
                            uint32_t i2 = row1 + (uint32_t)stepX;
                            uint32_t i3 = i2 + 1;

                            s_world.indices[indexCursor++] = i0;
                            s_world.indices[indexCursor++] = i2;
                            s_world.indices[indexCursor++] = i1;
                            s_world.indices[indexCursor++] = i1;
                            s_world.indices[indexCursor++] = i2;
                            s_world.indices[indexCursor++] = i3;
                        }
                    }

                    if (IsTimHellShaderName(shaders[shaderNum].shader)) {
                        uint32_t firstIndexForStage = s_world.draws[drawCursor].firstIndex;
                        uint32_t indexCountForStage = indexCursor - firstIndexForStage;

                        SetupWorldDraw(&s_world.draws[drawCursor++],
                                       firstIndexForStage,
                                       indexCountForStage,
                                       EnsureTimHellBaseTexture(),
                                       EnsureWhiteTexture(),
                                       Q3_METAL_WORLD_DRAWFLAG_NOCULL,
                                       2.0f, 2.0f,
                                       0.05f, 0.10f);
                        SetupWorldDraw(&s_world.draws[drawCursor++],
                                       firstIndexForStage,
                                       indexCountForStage,
                                       EnsureTimHellAddTexture(),
                                       EnsureWhiteTexture(),
                                       Q3_METAL_WORLD_DRAWFLAG_ADDITIVE | Q3_METAL_WORLD_DRAWFLAG_NOCULL,
                                       3.0f, 3.0f,
                                       0.05f, 0.10f);
                    } else {
                        uint32_t firstIndexForDraw = s_world.draws[drawCursor].firstIndex;
                        uint32_t indexCountForDraw = indexCursor - firstIndexForDraw;
                        uint32_t _dstIdx = drawCursor;
                        SetupWorldDraw(&s_world.draws[drawCursor++],
                                       firstIndexForDraw,
                                       indexCountForDraw,
                                       textureHandle,
                                       hasLightmap ? lightmapHandle : EnsureWhiteTexture(),
                                       worldFlags,
                                       1.0f, 1.0f,
                                       0.0f, 0.0f);
                        if (s_world.animShaderSlots && s_pendingAnimSlot >= 0) {
                            s_world.animShaderSlots[_dstIdx] = s_pendingAnimSlot;
                            s_world.animatedDrawCount += 1;
                        }
                    }
                }
            }
            continue;
        }

        if (numIndexes % 3) {
            numIndexes -= numIndexes % 3;
        }

        baseVertex = vertexCursor;
        s_world.draws[drawCursor].firstIndex = indexCursor;

        for (j = 0; j < numVerts; ++j) {
            EmitWorldVertex(&s_world.vertices[vertexCursor++], &drawVerts[firstVert + j]);
        }

        for (j = 0; j < numIndexes; ++j) {
            int localIndex = LittleLong(drawIndexes[firstIndex + j]);
            if (localIndex < 0 || localIndex >= numVerts) {
                s_world.indices[indexCursor++] = baseVertex;
                continue;
            }
            s_world.indices[indexCursor++] = baseVertex + (uint32_t)localIndex;
        }

        if (IsTimHellShaderName(shaders[shaderNum].shader)) {
            uint32_t firstIndexForStage = s_world.draws[drawCursor].firstIndex;
            uint32_t indexCountForStage = indexCursor - firstIndexForStage;
            SetupWorldDraw(&s_world.draws[drawCursor++],
                           firstIndexForStage,
                           indexCountForStage,
                           EnsureTimHellBaseTexture(),
                           EnsureWhiteTexture(),
                           Q3_METAL_WORLD_DRAWFLAG_NOCULL,
                           2.0f, 2.0f,
                           0.05f, 0.10f);
            SetupWorldDraw(&s_world.draws[drawCursor++],
                           firstIndexForStage,
                           indexCountForStage,
                           EnsureTimHellAddTexture(),
                           EnsureWhiteTexture(),
                           Q3_METAL_WORLD_DRAWFLAG_ADDITIVE | Q3_METAL_WORLD_DRAWFLAG_NOCULL,
                           3.0f, 3.0f,
                           0.05f, 0.10f);
        } else {
            uint32_t firstIndexForDraw = s_world.draws[drawCursor].firstIndex;
            uint32_t indexCountForDraw = indexCursor - firstIndexForDraw;
            uint32_t _dstIdx = drawCursor;
            SetupWorldDraw(&s_world.draws[drawCursor++],
                           firstIndexForDraw,
                           indexCountForDraw,
                           textureHandle,
                           hasLightmap ? lightmapHandle : EnsureWhiteTexture(),
                           worldFlags,
                           1.0f, 1.0f,
                           0.0f, 0.0f);
            if (s_world.animShaderSlots && s_pendingAnimSlot >= 0) {
                s_world.animShaderSlots[_dstIdx] = s_pendingAnimSlot;
                s_world.animatedDrawCount += 1;
            }
        }
    }

    s_world.loaded = qtrue;
    s_world.generation += 1;
    s_world.vertexCount = vertexCursor;
    s_world.indexCount = indexCursor;
    s_world.drawCount = drawCursor;
    Q_strncpyz(s_world.name, name, sizeof(s_world.name));

    ri.Printf(PRINT_ALL,
              "Metal world: loaded '%s' with %u verts, %u indices, %u draws (%u planar, %u patch, %u trisoup, %u sky)\n",
              name, s_world.vertexCount, s_world.indexCount, s_world.drawCount,
              planarDraws, patchDraws, triSoupDraws, skyDraws);
    if (skippedNoDrawSurfaces > 0) {
        ri.Printf(PRINT_ALL, "Metal world: skipped %u nodraw surfaces in '%s'\n", skippedNoDrawSurfaces, name);
    }

    ri.FS_FreeFile(fileBuffer);
    return qtrue;
}

static void RE_Shutdown(refShutdownCode_t code) {
    FreeEntitySceneData();
    FreeModelData();
    FreeWorldMapData();
    ri.Printf(PRINT_ALL, "RE_Shutdown: Metal stub\n");
}

/*
 * Minimal Q3 shader parser.
 *
 * Many MD3 surfaces reference shader names (e.g. "models/powerups/health/red_sphere")
 * whose actual texture lives under a different path (e.g. "textures/effects/envmapgold2.tga")
 * via a .shader script. Without resolving this, the stub falls back to a white texture
 * for any model that uses the shader system. We walk every .shader file under scripts/, extract
 * the first stage's first map directive, and hash shader_name -> texture_path.
 * RegisterTexture consults this table as a fallback when direct path load fails.
 *
 * Ignored: tcGen environment, animMap frame sequencing, blendFunc, tcMod — bind
 * at least one plausible texture so the geometry is visible instead of white.
 */
#define MAX_SHADER_MAP_ENTRIES 4096
#define METAL_ANIMMAP_MAX_FRAMES 16

typedef struct {
    char shaderName[128];
    char mapPath[MAX_QPATH];
    qboolean tcGenEnv;   /* any stage uses tcGen environment */
    /* animMap support. framePaths[0] == mapPath. 0 frames = not animated. */
    int animFrameCount;
    float animFps;
    char animFrames[METAL_ANIMMAP_MAX_FRAMES][MAX_QPATH];
    qhandle_t animTextures[METAL_ANIMMAP_MAX_FRAMES]; /* lazy resolve */
} metalShaderMap_t;
static metalShaderMap_t s_shaderMap[MAX_SHADER_MAP_ENTRIES];
static int s_shaderMapCount = 0;
static qboolean s_shaderMapLoaded = qfalse;

/* Strip a trailing image extension (.tga/.jpg/.jpeg/.png/.pcx). Caller
 * supplies out buffer. Returns qtrue if an extension was stripped. */
static qboolean StripImageExt(const char *name, char *out, size_t outSize) {
    size_t len;
    const char *dot;
    if (name == NULL || out == NULL || outSize == 0) return qfalse;
    Q_strncpyz(out, name, outSize);
    len = strlen(out);
    dot = strrchr(out, '.');
    if (dot == NULL) return qfalse;
    /* Only strip if extension looks like an image (4-5 chars incl. dot). */
    if (strlen(dot) > 5) return qfalse;
    {
        const char *exts[] = { ".tga", ".jpg", ".jpeg", ".png", ".pcx", NULL };
        int i;
        for (i = 0; exts[i]; ++i) {
            if (!Q_stricmp(dot, exts[i])) {
                out[dot - out] = '\0';
                (void)len;
                return qtrue;
            }
        }
    }
    return qfalse;
}

static const metalShaderMap_t *ShaderMap_LookupEntry(const char *name) {
    int i;
    char stripped[MAX_QPATH];
    if (name == NULL || name[0] == '\0') return NULL;
    for (i = 0; i < s_shaderMapCount; ++i) {
        if (!Q_stricmp(s_shaderMap[i].shaderName, name)) {
            return &s_shaderMap[i];
        }
    }
    /* Fall back: MD3s often embed shader names with an image extension
     * (models/.../red_sphere.tga) while .shader scripts define the same
     * material without one. Retry with the extension stripped. */
    if (StripImageExt(name, stripped, sizeof(stripped))) {
        for (i = 0; i < s_shaderMapCount; ++i) {
            if (!Q_stricmp(s_shaderMap[i].shaderName, stripped)) {
                return &s_shaderMap[i];
            }
        }
    }
    return NULL;
}

static const char *ShaderMap_Lookup(const char *name) {
    const metalShaderMap_t *e = ShaderMap_LookupEntry(name);
    return e ? e->mapPath : NULL;
}

/* If the shader referenced by `name` is animated, return the current frame's
 * registered texture handle (lazily registering the frame on first hit).
 * Returns 0 for non-animated shaders so the caller falls through to the
 * normal lookup path.
 *
 * IMPORTANT: exact-name match only. Extension-stripped fallback would
 * recurse: a frame path like 'textures/sfx/flame1.tga' could strip to
 * 'textures/sfx/flame1', match a shader whose animMap lists flame1.tga
 * as a frame, and re-enter RegisterTexture for the same file until the
 * iOS watchdog SIGKILLs. */
static qhandle_t ShaderMap_ResolveCurrentFrame(const char *name) {
    int i;
    int slot = -1;
    const metalShaderMap_t *entry = NULL;
    float fps;
    int frameIdx;
    static qboolean s_resolving = qfalse;

    if (name == NULL || name[0] == '\0') return 0;
    /* Re-entry guard: if a frame's own registration somehow ends up in
     * this function, break the cycle. Belt-and-suspenders with the
     * exact-name-only policy above. */
    if (s_resolving) return 0;

    for (i = 0; i < s_shaderMapCount; ++i) {
        if (!Q_stricmp(s_shaderMap[i].shaderName, name)) {
            entry = &s_shaderMap[i];
            slot = i;
            break;
        }
    }
    if (entry == NULL || entry->animFrameCount <= 0) {
        return 0;
    }
    fps = (entry->animFps > 0.0f) ? entry->animFps : 8.0f;
    frameIdx = (int)((float)cls.realtime * 0.001f * fps) % entry->animFrameCount;
    if (frameIdx < 0) frameIdx = 0;
    if (s_shaderMap[slot].animTextures[frameIdx] == 0) {
        s_resolving = qtrue;
        s_shaderMap[slot].animTextures[frameIdx] =
            RegisterTexture(s_shaderMap[slot].animFrames[frameIdx]);
        s_resolving = qfalse;
    }
    return s_shaderMap[slot].animTextures[frameIdx];
}

/* Exact-match slot lookup used when tagging world draws at map-load
 * for per-frame retargeting. Returns -1 if not animated. */
static int ShaderMap_FindAnimatedSlot(const char *name) {
    int i;
    if (name == NULL || name[0] == '\0') return -1;
    for (i = 0; i < s_shaderMapCount; ++i) {
        if (s_shaderMap[i].animFrameCount > 0 &&
            !Q_stricmp(s_shaderMap[i].shaderName, name)) {
            return i;
        }
    }
    return -1;
}

/* Current frame's texture handle for a known animated slot. Caller
 * already validated the slot; returns 0 on bad input to play safe. */
static qhandle_t ShaderMap_AnimatedSlotCurrentHandle(int slot) {
    const metalShaderMap_t *entry;
    float fps;
    int frameIdx;
    if (slot < 0 || slot >= s_shaderMapCount) return 0;
    entry = &s_shaderMap[slot];
    if (entry->animFrameCount <= 0) return 0;
    fps = (entry->animFps > 0.0f) ? entry->animFps : 8.0f;
    frameIdx = (int)((float)cls.realtime * 0.001f * fps) % entry->animFrameCount;
    if (frameIdx < 0) frameIdx = 0;
    if (s_shaderMap[slot].animTextures[frameIdx] == 0) {
        s_shaderMap[slot].animTextures[frameIdx] =
            RegisterTexture(s_shaderMap[slot].animFrames[frameIdx]);
    }
    return s_shaderMap[slot].animTextures[frameIdx];
}

static void ShaderMap_Register(const char *name, const char *path, qboolean tcGenEnv) {
    if (s_shaderMapCount >= MAX_SHADER_MAP_ENTRIES) return;
    if (ShaderMap_Lookup(name) != NULL) return; /* first wins */
    Q_strncpyz(s_shaderMap[s_shaderMapCount].shaderName, name,
        sizeof(s_shaderMap[0].shaderName));
    Q_strncpyz(s_shaderMap[s_shaderMapCount].mapPath, path,
        sizeof(s_shaderMap[0].mapPath));
    s_shaderMap[s_shaderMapCount].tcGenEnv = tcGenEnv;
    s_shaderMap[s_shaderMapCount].animFrameCount = 0;
    s_shaderMap[s_shaderMapCount].animFps = 0.0f;
    s_shaderMapCount += 1;
}

/* Register an animated shader entry. frames[] contains up to frameCount
 * texture paths. Later animation resolves to the current frame based on
 * cls.realtime. */
static void ShaderMap_RegisterAnimated(const char *name,
                                       char frames[][MAX_QPATH],
                                       int frameCount,
                                       float fps,
                                       qboolean tcGenEnv) {
    int i;
    int maxFrames = frameCount < METAL_ANIMMAP_MAX_FRAMES ? frameCount : METAL_ANIMMAP_MAX_FRAMES;
    if (s_shaderMapCount >= MAX_SHADER_MAP_ENTRIES) return;
    if (ShaderMap_Lookup(name) != NULL) return;
    if (maxFrames <= 0) return;
    Q_strncpyz(s_shaderMap[s_shaderMapCount].shaderName, name,
        sizeof(s_shaderMap[0].shaderName));
    Q_strncpyz(s_shaderMap[s_shaderMapCount].mapPath, frames[0],
        sizeof(s_shaderMap[0].mapPath));
    s_shaderMap[s_shaderMapCount].tcGenEnv = tcGenEnv;
    s_shaderMap[s_shaderMapCount].animFrameCount = maxFrames;
    s_shaderMap[s_shaderMapCount].animFps = (fps > 0.0f) ? fps : 8.0f;
    for (i = 0; i < maxFrames; ++i) {
        Q_strncpyz(s_shaderMap[s_shaderMapCount].animFrames[i], frames[i],
                   sizeof(s_shaderMap[0].animFrames[i]));
        s_shaderMap[s_shaderMapCount].animTextures[i] = 0;
    }
    s_shaderMapCount += 1;
}

static void ParseShaderText(const char *text) {
    const char *p = text;
    const char *token;

    while (1) {
        char shaderName[128];
        char firstMap[MAX_QPATH];
        char animFrames[METAL_ANIMMAP_MAX_FRAMES][MAX_QPATH];
        int animFrameCount;
        float animFps;
        int depth;
        qboolean inStage;
        qboolean gotMap;
        qboolean gotAnim;
        qboolean tcGenEnv;

        token = COM_ParseExt(&p, qtrue);
        if (!token[0]) break;
        Q_strncpyz(shaderName, token, sizeof(shaderName));

        token = COM_ParseExt(&p, qtrue);
        if (token[0] != '{') continue;

        firstMap[0] = '\0';
        animFrameCount = 0;
        animFps = 0.0f;
        depth = 1;
        inStage = qfalse;
        gotMap = qfalse;
        gotAnim = qfalse;
        tcGenEnv = qfalse;

        while (depth > 0) {
            token = COM_ParseExt(&p, qtrue);
            if (!token[0]) break;

            if (token[0] == '{' && token[1] == '\0') {
                depth += 1;
                inStage = qtrue;
                continue;
            }
            if (token[0] == '}' && token[1] == '\0') {
                depth -= 1;
                inStage = qfalse;
                continue;
            }

            if (inStage) {
                if (!gotMap && !gotAnim && (!Q_stricmp(token, "map") || !Q_stricmp(token, "clampmap"))) {
                    token = COM_ParseExt(&p, qfalse);
                    if (token[0] && token[0] != '$') {
                        Q_strncpyz(firstMap, token, sizeof(firstMap));
                        gotMap = qtrue;
                    }
                } else if (!gotMap && !gotAnim && !Q_stricmp(token, "animmap")) {
                    /* animMap <fps> <frame1> <frame2> ... up to end of line. */
                    token = COM_ParseExt(&p, qfalse);
                    animFps = (float)atof(token);
                    while (1) {
                        token = COM_ParseExt(&p, qfalse);
                        if (!token[0]) break; /* end of line */
                        if (token[0] == '$') continue;
                        if (animFrameCount >= METAL_ANIMMAP_MAX_FRAMES) continue;
                        Q_strncpyz(animFrames[animFrameCount], token, MAX_QPATH);
                        animFrameCount += 1;
                    }
                    if (animFrameCount > 0) {
                        Q_strncpyz(firstMap, animFrames[0], sizeof(firstMap));
                        gotAnim = qtrue;
                    }
                } else if (!Q_stricmp(token, "tcGen") || !Q_stricmp(token, "tcgen")) {
                    token = COM_ParseExt(&p, qfalse);
                    if (token[0] && (!Q_stricmp(token, "environment") ||
                                     !Q_stricmp(token, "env"))) {
                        tcGenEnv = qtrue;
                    }
                }
            }
        }

        if (gotAnim) {
            ShaderMap_RegisterAnimated(shaderName, animFrames, animFrameCount, animFps, tcGenEnv);
        } else if (gotMap) {
            ShaderMap_Register(shaderName, firstMap, tcGenEnv);
        }
    }
}

static void LoadAllShaders(void) {
    char **fileList;
    int numFiles;
    int i;

    if (s_shaderMapLoaded) return;
    s_shaderMapLoaded = qtrue;

    fileList = ri.FS_ListFiles("scripts", ".shader", &numFiles);
    if (fileList == NULL || numFiles == 0) {
        if (fileList) ri.FS_FreeFileList(fileList);
        ri.Printf(PRINT_WARNING, "Metal shader parser: no scripts/*.shader found\n");
        return;
    }

    for (i = 0; i < numFiles; ++i) {
        char path[MAX_QPATH];
        char *buf;
        int len;

        Com_sprintf(path, sizeof(path), "scripts/%s", fileList[i]);
        len = ri.FS_ReadFile(path, (void **)&buf);
        if (len <= 0 || buf == NULL) {
            if (buf) ri.FS_FreeFile(buf);
            continue;
        }
        ParseShaderText(buf);
        ri.FS_FreeFile(buf);
    }

    ri.FS_FreeFileList(fileList);
    ri.Printf(PRINT_ALL, "Metal shader parser: %d shader->map entries loaded from %d files\n",
        s_shaderMapCount, numFiles);
}

static void RE_BeginRegistration(glconfig_t *config) {
    ri.Printf(PRINT_ALL, "RE_BeginRegistration: Metal stub\n");
    LoadAllShaders();
    EnsureWhiteTexture();
    EnsureSkyTexture();
    EnsureTimHellBaseTexture();
    EnsureTimHellAddTexture();
    s_glConfig.vidWidth = 2796;
    s_glConfig.vidHeight = 1290;
    s_glConfig.windowAspect = (float)s_glConfig.vidWidth / (float)s_glConfig.vidHeight;
    s_glConfig.colorBits = 32;
    s_glConfig.depthBits = 24;
    s_glConfig.stencilBits = 8;
    s_glConfig.isFullscreen = qtrue;
    s_glConfig.deviceSupportsGamma = qfalse;
    Q_strncpyz(s_glConfig.renderer_string, "Apple Metal (iOS)", sizeof(s_glConfig.renderer_string));
    Q_strncpyz(s_glConfig.vendor_string, "Apple", sizeof(s_glConfig.vendor_string));
    Q_strncpyz(s_glConfig.version_string, "Metal 4", sizeof(s_glConfig.version_string));
    s_frameSnapshot.drawableWidth = (uint32_t)s_glConfig.vidWidth;
    s_frameSnapshot.drawableHeight = (uint32_t)s_glConfig.vidHeight;
    s_frameSnapshot.clearColor[0] = 0.0f;
    s_frameSnapshot.clearColor[1] = 0.0f;
    s_frameSnapshot.clearColor[2] = 0.0f;
    s_frameSnapshot.clearColor[3] = 1.0f;
    *config = s_glConfig;
}

static qhandle_t s_nextStubSkinHandle = 1;

/* Q3 .skin file support. Each line maps a surface name to a texture:
 *   h_helmet,models/players/sarge/sarge.jpg
 *   u_torso,models/players/sarge/sarge.jpg
 *   tag_weapon,
 * An empty right-hand side means "hide this surface". */
#define METAL_SKIN_MAX_SURFACES 32
#define METAL_SKIN_MAX 256

typedef struct {
    char surface[MAX_QPATH];
    char shader[MAX_QPATH];
    qhandle_t textureHandle; /* 0 if surface should be hidden */
} metalSkinSurface_t;

typedef struct {
    qboolean inUse;
    char name[MAX_QPATH];
    int numSurfaces;
    metalSkinSurface_t surfaces[METAL_SKIN_MAX_SURFACES];
} metalSkin_t;

static metalSkin_t s_skins[METAL_SKIN_MAX];

static metalSkin_t *FindSkinByHandle(qhandle_t handle) {
    int idx;
    if (handle < 0x20000000) {
        return NULL;
    }
    idx = handle - 0x20000000;
    if (idx < 0 || idx >= METAL_SKIN_MAX) {
        return NULL;
    }
    if (!s_skins[idx].inUse) {
        return NULL;
    }
    return &s_skins[idx];
}

static qboolean ParseSkinText(const char *text, metalSkin_t *skin) {
    const char *p = text;
    skin->numSurfaces = 0;
    while (p && *p) {
        const char *lineStart = p;
        const char *lineEnd;
        const char *comma;
        char surfaceBuf[MAX_QPATH];
        char shaderBuf[MAX_QPATH];
        size_t surfaceLen;
        size_t shaderLen;

        while (*p && *p != '\n' && *p != '\r') {
            p++;
        }
        lineEnd = p;
        while (*p == '\n' || *p == '\r') {
            p++;
        }

        /* Trim trailing whitespace. */
        while (lineEnd > lineStart && (lineEnd[-1] == ' ' || lineEnd[-1] == '\t')) {
            lineEnd--;
        }
        /* Skip blank lines and comments. */
        {
            const char *skip = lineStart;
            while (skip < lineEnd && (*skip == ' ' || *skip == '\t')) {
                skip++;
            }
            if (skip >= lineEnd) {
                continue;
            }
            if (skip + 1 < lineEnd && skip[0] == '/' && skip[1] == '/') {
                continue;
            }
            lineStart = skip;
        }

        comma = memchr(lineStart, ',', (size_t)(lineEnd - lineStart));
        if (comma == NULL) {
            continue;
        }

        surfaceLen = (size_t)(comma - lineStart);
        if (surfaceLen >= sizeof(surfaceBuf)) {
            surfaceLen = sizeof(surfaceBuf) - 1;
        }
        memcpy(surfaceBuf, lineStart, surfaceLen);
        surfaceBuf[surfaceLen] = '\0';

        shaderLen = (size_t)(lineEnd - (comma + 1));
        if (shaderLen >= sizeof(shaderBuf)) {
            shaderLen = sizeof(shaderBuf) - 1;
        }
        memcpy(shaderBuf, comma + 1, shaderLen);
        shaderBuf[shaderLen] = '\0';

        /* tag_ entries are attachment points, not renderable surfaces. Skip. */
        if (strncmp(surfaceBuf, "tag_", 4) == 0) {
            continue;
        }

        if (skin->numSurfaces >= METAL_SKIN_MAX_SURFACES) {
            break;
        }
        Q_strncpyz(skin->surfaces[skin->numSurfaces].surface, surfaceBuf,
                   sizeof(skin->surfaces[skin->numSurfaces].surface));
        Q_strncpyz(skin->surfaces[skin->numSurfaces].shader, shaderBuf,
                   sizeof(skin->surfaces[skin->numSurfaces].shader));
        skin->surfaces[skin->numSurfaces].textureHandle = 0; /* lazy resolve */
        skin->numSurfaces += 1;
    }
    return (skin->numSurfaces > 0) ? qtrue : qfalse;
}

static qhandle_t LookupSkinSurfaceTexture(qhandle_t skinHandle, const char *surfaceName) {
    metalSkin_t *skin = FindSkinByHandle(skinHandle);
    int i;
    if (skin == NULL || surfaceName == NULL || surfaceName[0] == '\0') {
        return 0;
    }
    for (i = 0; i < skin->numSurfaces; ++i) {
        if (Q_stricmp(skin->surfaces[i].surface, surfaceName) == 0) {
            if (skin->surfaces[i].shader[0] == '\0') {
                /* Empty mapping: surface hidden. Return sentinel -1. */
                return (qhandle_t)-1;
            }
            if (skin->surfaces[i].textureHandle == 0) {
                skin->surfaces[i].textureHandle = RegisterTexture(skin->surfaces[i].shader);
            }
            return skin->surfaces[i].textureHandle;
        }
    }
    return 0;
}

static qhandle_t RE_RegisterModel(const char *name) {
    if (name == NULL || name[0] == '\0') {
        return 0;
    }
    return ResolveAndRegisterModel(name);
}

static qhandle_t RE_RegisterSkin(const char *name) {
    int idx;
    char *text = NULL;
    int fileLen;

    if (name == NULL || name[0] == '\0') {
        return 0;
    }

    /* Reuse existing registration. */
    for (idx = 0; idx < METAL_SKIN_MAX; ++idx) {
        if (s_skins[idx].inUse && Q_stricmp(s_skins[idx].name, name) == 0) {
            return (qhandle_t)(0x20000000 + idx);
        }
    }

    /* Find a free slot. */
    for (idx = 0; idx < METAL_SKIN_MAX; ++idx) {
        if (!s_skins[idx].inUse) {
            break;
        }
    }
    if (idx >= METAL_SKIN_MAX) {
        ri.Printf(PRINT_WARNING, "Metal skin: registry full, dropping '%s'\n", name);
        return 0;
    }

    fileLen = ri.FS_ReadFile(name, (void **)&text);
    if (fileLen <= 0 || text == NULL) {
        ri.Printf(PRINT_DEVELOPER, "Metal skin: cannot read '%s'\n", name);
        if (text) {
            ri.FS_FreeFile(text);
        }
        /* Return a handle anyway so cgame doesn't treat this as failure;
         * just with zero surfaces the draw loop will fall back to MD3
         * shader lookup. */
        Com_Memset(&s_skins[idx], 0, sizeof(s_skins[idx]));
        Q_strncpyz(s_skins[idx].name, name, sizeof(s_skins[idx].name));
        s_skins[idx].inUse = qtrue;
        s_skins[idx].numSurfaces = 0;
        return (qhandle_t)(0x20000000 + idx);
    }

    Com_Memset(&s_skins[idx], 0, sizeof(s_skins[idx]));
    Q_strncpyz(s_skins[idx].name, name, sizeof(s_skins[idx].name));
    s_skins[idx].inUse = qtrue;
    ParseSkinText(text, &s_skins[idx]);
    ri.FS_FreeFile(text);

    ri.Printf(PRINT_DEVELOPER, "Metal skin: '%s' -> %d surface mappings\n",
              name, s_skins[idx].numSurfaces);

    if (s_nextStubSkinHandle <= idx) {
        s_nextStubSkinHandle = idx + 1;
    }
    return (qhandle_t)(0x20000000 + idx);
}
qhandle_t RE_RegisterShader(const char *name) { return RegisterTexture(name); }
qhandle_t RE_RegisterShaderNoMip(const char *name) { return RegisterTexture(name); }
static void RE_LoadWorldMap(const char *name) {
    if (name == NULL || name[0] == '\0') {
        FreeWorldMapData();
        return;
    }

    if (!LoadWorldMapData(name)) {
        ri.Printf(PRINT_WARNING, "Metal world: falling back to empty world for '%s'\n", name);
    }
}
static void RE_SetWorldVisData(const byte *vis) {}
static void RE_EndRegistration(void) {}

static uint32_t s_clearSceneCalls;
static uint32_t s_renderSceneCalls;

static void RE_ClearScene(void) {
    s_clearSceneCalls += 1;
    s_sceneEntityCount = 0;
    /* DO NOT reset s_entity{Vertex,Index,Draw}Count here. Cgame calls
     * ClearScene between every scene (world + HUD + HUD). If we wiped the
     * draw buffer here, the world scene's draws would be lost before the
     * HUD scenes' RE_RenderScene runs — which is exactly when Swift reads
     * s_frameSnapshot. Resets happen in RE_RenderScene (gated on world). */
    s_entityAcceptedThisFrame = 0;
    s_entityRejectedNullThisFrame = 0;
    s_entityRejectedTypeThisFrame = 0;
    s_entityRejectedModelThisFrame = 0;
}

static uint32_t s_rawEntryCount;  /* unconditional counter for debug */

static void RE_AddRefEntityToScene(const refEntity_t *re, qboolean intShaderTime) {
    vec3_t cross;

    s_rawEntryCount += 1;  /* counted even for null/invalid */
    if (re == NULL || s_sceneEntityCount >= Q3_METAL_MAX_REFENTITIES) {
        s_entityRejectedNullThisFrame += 1;
        return;
    }
    if (re->reType != RT_MODEL) {
        s_entityRejectedTypeThisFrame += 1;
        return;
    }
    if (re->hModel == 0 || FindModelByHandle(re->hModel) == NULL) {
        s_entityRejectedModelThisFrame += 1;
        return;
    }

    s_sceneEntities[s_sceneEntityCount].entity = *re;
    CrossProduct(re->axis[0], re->axis[1], cross);
    s_sceneEntities[s_sceneEntityCount].mirrored = (DotProduct(re->axis[2], cross) < 0.0f);
    s_sceneEntityCount += 1;
    s_entityAcceptedThisFrame += 1;
}
static void RE_AddPolyToScene(qhandle_t hShader, int numVerts, const polyVert_t *verts, int num) {}
static int R_LightForPoint(vec3_t point, vec3_t ambientLight, vec3_t directedLight, vec3_t lightDir) { return 0; }
static void RE_AddLightToScene(const vec3_t org, float intensity, float r, float g, float b) {}
static void RE_AddAdditiveLightToScene(const vec3_t org, float intensity, float r, float g, float b) {}
static void RE_AddLinearLightToScene(const vec3_t start, const vec3_t end, float intensity, float r, float g, float b) {}
/*
 * Synthetic first-person viewmodel.
 *
 * The bundled cgame.qvm only submits one entity per frame (its scene-build
 * loop appears to abort after the first add, probably due to a refEntity_t
 * ABI mismatch), so we cannot rely on it for a stable viewmodel. Instead we
 * inject our own viewmodel entity each frame using the live client state
 * (cl.snap.ps.weapon) and the camera transform. The cgame-submitted
 * entity, whatever it is, renders normally through the standard path.
 */
static qhandle_t s_viewmodelHandles[16];  /* WP_NUM_WEAPONS is 11; pad for safety */

static qhandle_t RE_RegisterModel(const char *name);

static qhandle_t GetViewmodelHandle(int weapon) {
    static const char *names[] = {
        NULL,                                         /* WP_NONE */
        "models/weapons2/gauntlet/gauntlet.md3",      /* WP_GAUNTLET */
        "models/weapons2/machinegun/machinegun.md3",  /* WP_MACHINEGUN */
        "models/weapons2/shotgun/shotgun.md3",        /* WP_SHOTGUN */
        "models/weapons2/grenadel/grenadel.md3",      /* WP_GRENADE_LAUNCHER */
        "models/weapons2/rocketl/rocketl.md3",        /* WP_ROCKET_LAUNCHER */
        "models/weapons2/lightning/lightning.md3",    /* WP_LIGHTNING */
        "models/weapons2/railgun/railgun.md3",        /* WP_RAILGUN */
        "models/weapons2/plasma/plasma.md3",          /* WP_PLASMAGUN */
        "models/weapons2/bfg/bfg.md3",                /* WP_BFG */
        "models/weapons2/grapple/grapple.md3"         /* WP_GRAPPLING_HOOK */
    };
    if (weapon <= 0 || weapon >= (int)(sizeof(names) / sizeof(names[0])) || names[weapon] == NULL) {
        return 0;
    }
    if (s_viewmodelHandles[weapon] == 0) {
        s_viewmodelHandles[weapon] = RE_RegisterModel(names[weapon]);
    }
    return s_viewmodelHandles[weapon];
}

static cvar_t *s_cvarVmForward = NULL;
static cvar_t *s_cvarVmRight = NULL;
static cvar_t *s_cvarVmUp = NULL;
static cvar_t *s_cvarVmScale = NULL;
static cvar_t *s_cvarVmSwayAmp = NULL;

static void EnsureViewmodelCvars(void) {
    if (s_cvarVmForward == NULL) {
        /* Live-tunable placement. Adjust from console without a rebuild:
         *   \metal_vm_forward 10
         *   \metal_vm_right -5
         *   \metal_vm_up -6
         *   \metal_vm_scale 1.0
         *   \metal_vm_sway 0.4
         * Defaults below are a tighter second guess than the prior
         * (70, -18, -24, 0.7) — log coords suggested world scale is
         * smaller than stock Q3, so large offsets pushed the model off-
         * screen and scale 0.7 still felt oversized. */
        /* Sign convention: origin formula uses `-kRight * axis1`, and
         * axis1 is Q3 "left". Positive kRight → subtract left → move
         * right (screen). Previous default of -4 placed the model 4
         * units LEFT of center; screenshots confirmed wrong-side bug. */
        s_cvarVmForward = ri.Cvar_Get("metal_vm_forward", "6",   CVAR_ARCHIVE);
        s_cvarVmRight   = ri.Cvar_Get("metal_vm_right",   "5",   CVAR_ARCHIVE);
        s_cvarVmUp      = ri.Cvar_Get("metal_vm_up",      "-4",  CVAR_ARCHIVE);
        s_cvarVmScale   = ri.Cvar_Get("metal_vm_scale",   "0.3", CVAR_ARCHIVE);
        s_cvarVmSwayAmp = ri.Cvar_Get("metal_vm_sway",    "0.4", CVAR_ARCHIVE);
    }
}

static void SynthesizeViewmodelEntity(const vec3_t vieworg,
                                      const vec3_t axis0,
                                      const vec3_t axis1,
                                      const vec3_t axis2) {
    metalSceneEntity_t *slot;
    refEntity_t *e;
    qhandle_t hModel;
    int weapon;
    vec3_t origin;
    float t, swayRight, swayUp, swayAmp;
    float kForward, kRight, kUp, kScale;

    EnsureViewmodelCvars();
    kForward = s_cvarVmForward->value;
    kRight   = s_cvarVmRight->value;
    kUp      = s_cvarVmUp->value;
    kScale   = s_cvarVmScale->value;
    swayAmp  = s_cvarVmSwayAmp->value;
    if (kScale <= 0.0f) {
        kScale = 0.6f;
    }

    if (s_sceneEntityCount >= Q3_METAL_MAX_REFENTITIES) {
        return;
    }
    if (!s_world.loaded) {
        return;
    }

    weapon = cl.snap.ps.weapon;
    hModel = GetViewmodelHandle(weapon);
    if (hModel == 0) {
        return;
    }

    slot = &s_sceneEntities[s_sceneEntityCount];
    Com_Memset(slot, 0, sizeof(*slot));
    e = &slot->entity;
    e->reType = RT_MODEL;
    e->hModel = hModel;
    e->renderfx = RF_DEPTHHACK;
    e->shader.rgba[0] = 255;
    e->shader.rgba[1] = 255;
    e->shader.rgba[2] = 255;
    e->shader.rgba[3] = 255;

    /* Build origin in view space. axis1 is Q3 "left" → subtract for right. */
    origin[0] = vieworg[0] + kForward * axis0[0] - kRight * axis1[0] + kUp * axis2[0];
    origin[1] = vieworg[1] + kForward * axis0[1] - kRight * axis1[1] + kUp * axis2[1];
    origin[2] = vieworg[2] + kForward * axis0[2] - kRight * axis1[2] + kUp * axis2[2];

    /* Idle sway using engine-side time (cls.realtime is in ms). Subtle. */
    t = (float)cls.realtime * 0.002f;
    swayRight = sinf(t) * swayAmp;
    swayUp    = cosf(t) * (swayAmp * 0.6f);
    origin[0] += (-axis1[0] * swayRight) + (axis2[0] * swayUp);
    origin[1] += (-axis1[1] * swayRight) + (axis2[1] * swayUp);
    origin[2] += (-axis1[2] * swayRight) + (axis2[2] * swayUp);

    VectorCopy(origin, e->origin);

    /* Copy camera axes, then uniformly scale them to fake MD3 scale. */
    VectorCopy(axis0, e->axis[0]);
    VectorCopy(axis1, e->axis[1]);
    VectorCopy(axis2, e->axis[2]);
    VectorScale(e->axis[0], kScale, e->axis[0]);
    VectorScale(e->axis[1], kScale, e->axis[1]);
    VectorScale(e->axis[2], kScale, e->axis[2]);

    slot->mirrored = qfalse;
    slot->isSynthetic = qtrue;
    s_sceneEntityCount += 1;
    s_entityAcceptedThisFrame += 1;
}

static void RE_RenderScene(const refdef_t *fd) {
    vec3_t vieworg;
    vec3_t axis0;
    vec3_t axis1;
    vec3_t axis2;
    float fovX;
    float fovY;

    if (fd == NULL) {
        return;
    }
    s_renderSceneCalls += 1;

    /* Per-frame world-surface animMap retarget. Walk only the draws we
     * tagged at map-load (fire/lava/teleport surfaces) and overwrite
     * their textureHandle with the current animation frame. Zero-cost
     * when animatedDrawCount == 0 (maps with no animated world shaders). */
    if (s_world.loaded && s_world.animatedDrawCount > 0 &&
        s_world.animShaderSlots != NULL && s_world.draws != NULL) {
        uint32_t i;
        for (i = 0; i < s_world.drawCount; ++i) {
            int slot = s_world.animShaderSlots[i];
            if (slot >= 0) {
                qhandle_t h = ShaderMap_AnimatedSlotCurrentHandle(slot);
                if (h != 0) {
                    s_world.draws[i].textureHandle = (uint32_t)h;
                }
            }
        }
    }

    VectorCopy(fd->vieworg, vieworg);
    VectorCopy(fd->viewaxis[0], axis0);
    VectorCopy(fd->viewaxis[1], axis1);
    VectorCopy(fd->viewaxis[2], axis2);
    fovX = fd->fov_x;
    fovY = fd->fov_y;

    if (s_world.loaded && fovX < 45.0f) {
        if (BuildFallbackSceneView(vieworg, axis0, axis1, axis2, &fovX, &fovY) && (s_sceneLogCounter % 60) == 0) {
            ri.Printf(
                PRINT_WARNING,
                "Metal fallback camera[%u]: repaired invalid refdef using cl.snap.ps origin=(%.2f %.2f %.2f) angles=(%.2f %.2f %.2f) fov=(%.2f %.2f)\n",
                s_sceneLogCounter + 1,
                cl.snap.ps.origin[0], cl.snap.ps.origin[1], cl.snap.ps.origin[2],
                cl.viewangles[0], cl.viewangles[1], cl.viewangles[2],
                fovX, fovY
            );
        }
    }

    /* World-scene-only camera. HUD/portrait scenes would overwrite with
     * their own view, projecting preserved world entity draws off-screen. */
    if (fd->rdflags == 0) {
        s_sceneView.fovX = fovX;
        s_sceneView.fovY = fovY;
        s_sceneView.viewOrigin[0] = vieworg[0];
        s_sceneView.viewOrigin[1] = vieworg[1];
        s_sceneView.viewOrigin[2] = vieworg[2];
        s_sceneView.viewAxis[0] = axis0[0];
        s_sceneView.viewAxis[1] = axis0[1];
        s_sceneView.viewAxis[2] = axis0[2];
        s_sceneView.viewAxis[3] = axis1[0];
        s_sceneView.viewAxis[4] = axis1[1];
        s_sceneView.viewAxis[5] = axis1[2];
        s_sceneView.viewAxis[6] = axis2[0];
        s_sceneView.viewAxis[7] = axis2[1];
        s_sceneView.viewAxis[8] = axis2[2];
    }

    /* Inject our own viewmodel entity; cgame is unreliable here. */
    SynthesizeViewmodelEntity(vieworg, axis0, axis1, axis2);

    s_sceneLogCounter += 1;
    if ((s_sceneLogCounter % 60) == 0) {
        ri.Printf(
            PRINT_ALL,
            "Metal debug refdef[%u]: vieworg=(%.2f %.2f %.2f) axis0=(%.3f %.3f %.3f) "
            "axis1=(%.3f %.3f %.3f) axis2=(%.3f %.3f %.3f) fov=(%.2f %.2f) rdflags=0x%x worldLoaded=%d draws=%u\n",
            s_sceneLogCounter,
            vieworg[0], vieworg[1], vieworg[2],
            axis0[0], axis0[1], axis0[2],
            axis1[0], axis1[1], axis1[2],
            axis2[0], axis2[1], axis2[2],
            fovX, fovY,
            fd->rdflags,
            s_world.loaded,
            s_world.drawCount
        );
        ri.Printf(
            PRINT_ALL,
            "Metal entity queue[%u]: accepted=%u rejectNull=%u rejectType=%u rejectModel=%u sceneEntities=%u clearCalls=%u renderCalls=%u rawEntries=%u\n",
            s_sceneLogCounter,
            s_entityAcceptedThisFrame,
            s_entityRejectedNullThisFrame,
            s_entityRejectedTypeThisFrame,
            s_entityRejectedModelThisFrame,
            s_sceneEntityCount,
            s_clearSceneCalls,
            s_renderSceneCalls,
            s_rawEntryCount
        );
        s_clearSceneCalls = 0;
        s_renderSceneCalls = 0;
        s_rawEntryCount = 0;
        if (s_sceneEntityCount > 0) {
            uint32_t logIdx;
            uint32_t loggedNonSynth = 0;
            for (logIdx = 0; logIdx < s_sceneEntityCount && loggedNonSynth < 10; ++logIdx) {
                const metalSceneEntity_t *se = &s_sceneEntities[logIdx];
                const metalModel_t *mdl;
                const char *name;
                vec3_t firstVertWorld;
                qboolean haveFirstVert = qfalse;
                int depthHack;
                if (se->isSynthetic) {
                    continue;
                }
                mdl = FindModelByHandle(se->entity.hModel);
                name = (mdl && mdl->inUse) ? mdl->name : "<unknown>";
                depthHack = (se->entity.renderfx & RF_DEPTHHACK) ? 1 : 0;

                /* Compute the first vertex's world position to verify the
                 * transform produces sensible coords. */
                if (mdl && mdl->md3) {
                    const md3Header_t *hdr = mdl->md3;
                    if (hdr->numSurfaces > 0) {
                        const md3Surface_t *surf = (const md3Surface_t *)((const byte *)hdr + hdr->ofsSurfaces);
                        if (surf->numVerts > 0) {
                            const md3XyzNormal_t *v = (const md3XyzNormal_t *)((const byte *)surf + surf->ofsXyzNormals);
                            float lx = v->xyz[0] * MD3_XYZ_SCALE;
                            float ly = v->xyz[1] * MD3_XYZ_SCALE;
                            float lz = v->xyz[2] * MD3_XYZ_SCALE;
                            firstVertWorld[0] = se->entity.origin[0]
                                + se->entity.axis[0][0]*lx + se->entity.axis[1][0]*ly + se->entity.axis[2][0]*lz;
                            firstVertWorld[1] = se->entity.origin[1]
                                + se->entity.axis[0][1]*lx + se->entity.axis[1][1]*ly + se->entity.axis[2][1]*lz;
                            firstVertWorld[2] = se->entity.origin[2]
                                + se->entity.axis[0][2]*lx + se->entity.axis[1][2]*ly + se->entity.axis[2][2]*lz;
                            haveFirstVert = qtrue;
                        }
                    }
                }

                if (haveFirstVert) {
                    ri.Printf(
                        PRINT_ALL,
                        "Metal cgame ent[%u/%u]: model='%s' origin=(%.1f %.1f %.1f) axis0=(%.2f %.2f %.2f) "
                        "rfx=0x%x hMdl=%d reType=%d cShader=%d cSkin=%d depthHack=%d firstVtxWorld=(%.1f %.1f %.1f)\n",
                        s_sceneLogCounter, logIdx,
                        name,
                        se->entity.origin[0], se->entity.origin[1], se->entity.origin[2],
                        se->entity.axis[0][0], se->entity.axis[0][1], se->entity.axis[0][2],
                        se->entity.renderfx, se->entity.hModel, se->entity.reType,
                        se->entity.customShader, se->entity.customSkin,
                        depthHack,
                        firstVertWorld[0], firstVertWorld[1], firstVertWorld[2]
                    );
                } else {
                    ri.Printf(
                        PRINT_ALL,
                        "Metal cgame ent[%u/%u]: model='%s' origin=(%.1f %.1f %.1f) axis0=(%.2f %.2f %.2f) "
                        "rfx=0x%x hMdl=%d reType=%d cShader=%d cSkin=%d depthHack=%d firstVtxWorld=N/A\n",
                        s_sceneLogCounter, logIdx,
                        name,
                        se->entity.origin[0], se->entity.origin[1], se->entity.origin[2],
                        se->entity.axis[0][0], se->entity.axis[0][1], se->entity.axis[0][2],
                        se->entity.renderfx, se->entity.hModel, se->entity.reType,
                        se->entity.customShader, se->entity.customSkin,
                        depthHack
                    );
                }
                loggedNonSynth += 1;
            }
        }
    }

    if (s_world.loaded && !(fd->rdflags & RDF_NOWORLDMODEL)) {
        s_frameSnapshot.worldVertexCount = s_world.vertexCount;
        s_frameSnapshot.worldIndexCount = s_world.indexCount;
        s_frameSnapshot.worldCommandCount = s_world.drawCount;
        s_frameSnapshot.worldGeneration = s_world.generation;
    }

    /* World-scene-only buffer rebuild. HUD scenes retain the world scene's
     * draws so Swift's Coordinator.draw can consume them. Combined with
     * removing buffer resets from RE_ClearScene (which is called between
     * every scene) this preserves world draws across the frame. */
    if (fd->rdflags == 0) {
        s_entityVertexCount = 0;
        s_entityIndexCount = 0;
        s_entityDrawCount = 0;
    }

    if (fd->rdflags == 0 && s_sceneEntityCount > 0) {
        uint32_t totalEntityVerts = 0;
        uint32_t totalEntityIndices = 0;
        uint32_t totalEntityDraws = 0;
        uint32_t entityIndex;

        for (entityIndex = 0; entityIndex < s_sceneEntityCount; ++entityIndex) {
            const metalSceneEntity_t *sceneEntity = &s_sceneEntities[entityIndex];
            const metalModel_t *model = FindModelByHandle(sceneEntity->entity.hModel);
            const md3Header_t *header;
            const md3Surface_t *surface;
            int surfaceIndex;

            if (model == NULL || model->md3 == NULL) {
                continue;
            }

            header = model->md3;
            surface = (const md3Surface_t *)((const byte *)header + header->ofsSurfaces);
            for (surfaceIndex = 0; surfaceIndex < header->numSurfaces; ++surfaceIndex) {
                totalEntityVerts += (uint32_t)surface->numVerts;
                totalEntityIndices += (uint32_t)(surface->numTriangles * 3);
                totalEntityDraws += 1;
                surface = (const md3Surface_t *)((const byte *)surface + surface->ofsEnd);
            }
        }

        if (totalEntityVerts > 0 && totalEntityIndices > 0 && totalEntityDraws > 0 &&
            EnsureEntitySceneCapacity(totalEntityVerts, totalEntityIndices, totalEntityDraws)) {
            uint32_t entityVertexCursor = 0;
            uint32_t entityIndexCursor = 0;
            uint32_t entityDrawCursor = 0;

            for (entityIndex = 0; entityIndex < s_sceneEntityCount; ++entityIndex) {
                const metalSceneEntity_t *sceneEntity = &s_sceneEntities[entityIndex];
                const metalModel_t *model = FindModelByHandle(sceneEntity->entity.hModel);
                vec3_t effectiveOrigin;
                vec3_t effectiveAxis[3];
                const md3Header_t *header;
                const md3Surface_t *surface;
                int frameIndex;
                int oldFrameIndex;
                float backlerp;
                float frontlerp;
                vec4_t entityColor;
                int surfaceIndex;

                if (model == NULL || model->md3 == NULL) {
                    continue;
                }

                /* Hide the local player's own head in first-person view.
                 * The stock engine relies on RF_THIRD_PERSON being set by
                 * cgame on the local player's body parts, but the current
                 * cgame.qvm ABI mismatch causes renderfx bits to land in
                 * the wrong field (see brain.db msg 172). Detect by model
                 * path + camera proximity instead: any /players/.../head.md3
                 * within ~40 units of the camera is the local-player head. */
                if (!sceneEntity->isSynthetic && model->inUse) {
                    const char *mname = model->name;
                    if (mname && strstr(mname, "/players/") != NULL) {
                        size_t mlen = strlen(mname);
                        if (mlen >= 9 && strcmp(mname + mlen - 9, "/head.md3") == 0) {
                            float dx = sceneEntity->entity.origin[0] - s_sceneView.viewOrigin[0];
                            float dy = sceneEntity->entity.origin[1] - s_sceneView.viewOrigin[1];
                            float dz = sceneEntity->entity.origin[2] - s_sceneView.viewOrigin[2];
                            float distSq = dx*dx + dy*dy + dz*dz;
                            /* 40 world units, squared = 1600. */
                            if (distSq < 1600.0f) {
                                continue;
                            }
                        }
                    }
                }

                header = model->md3;
                frameIndex = sceneEntity->entity.frame;
                oldFrameIndex = sceneEntity->entity.oldframe;
                if (header->numFrames <= 0) {
                    continue;
                }
                if (frameIndex < 0 || frameIndex >= header->numFrames) {
                    frameIndex = 0;
                }
                if (oldFrameIndex < 0 || oldFrameIndex >= header->numFrames) {
                    oldFrameIndex = frameIndex;
                }

                backlerp = sceneEntity->entity.backlerp;
                if (backlerp < 0.0f) {
                    backlerp = 0.0f;
                } else if (backlerp > 1.0f) {
                    backlerp = 1.0f;
                }
                frontlerp = 1.0f - backlerp;

                if (sceneEntity->entity.shader.rgba[3] == 0) {
                    entityColor[0] = 1.0f;
                    entityColor[1] = 1.0f;
                    entityColor[2] = 1.0f;
                    entityColor[3] = 1.0f;
                } else {
                    entityColor[0] = (float)sceneEntity->entity.shader.rgba[0] / 255.0f;
                    entityColor[1] = (float)sceneEntity->entity.shader.rgba[1] / 255.0f;
                    entityColor[2] = (float)sceneEntity->entity.shader.rgba[2] / 255.0f;
                    entityColor[3] = (float)sceneEntity->entity.shader.rgba[3] / 255.0f;
                }

                /* Use the entity transform as submitted. The synthetic
                 * viewmodel path (SynthesizeViewmodelEntity) appends its own
                 * entity with correct camera-relative origin/axis; cgame-
                 * submitted entities (pickups, etc.) use their world
                 * placement. */
                VectorCopy(sceneEntity->entity.origin, effectiveOrigin);
                VectorCopy(sceneEntity->entity.axis[0], effectiveAxis[0]);
                VectorCopy(sceneEntity->entity.axis[1], effectiveAxis[1]);
                VectorCopy(sceneEntity->entity.axis[2], effectiveAxis[2]);

                surface = (const md3Surface_t *)((const byte *)header + header->ofsSurfaces);
                for (surfaceIndex = 0; surfaceIndex < header->numSurfaces; ++surfaceIndex) {
                    const md3Triangle_t *triangles = (const md3Triangle_t *)((const byte *)surface + surface->ofsTriangles);
                    const md3St_t *st = (const md3St_t *)((const byte *)surface + surface->ofsSt);
                    const md3XyzNormal_t *currentFrameVerts = (const md3XyzNormal_t *)((const byte *)surface + surface->ofsXyzNormals) + frameIndex * surface->numVerts;
                    const md3XyzNormal_t *oldFrameVerts = (const md3XyzNormal_t *)((const byte *)surface + surface->ofsXyzNormals) + oldFrameIndex * surface->numVerts;
                    qhandle_t textureHandle = EnsureWhiteTexture();
                    uint32_t drawFlags = Q3_METAL_ENTITY_DRAWFLAG_NOCULL;
                    uint32_t baseVertex = entityVertexCursor;
                    uint32_t firstIndex = entityIndexCursor;
                    int vertexIndex;
                    int triangleIndex;

                    if (sceneEntity->entity.customShader != 0) {
                        textureHandle = sceneEntity->entity.customShader;
                    } else if (sceneEntity->entity.customSkin != 0) {
                        qhandle_t skinTex = LookupSkinSurfaceTexture(
                            sceneEntity->entity.customSkin, surface->name);
                        if (skinTex == (qhandle_t)-1) {
                            /* Skin explicitly hides this surface. */
                            surface = (const md3Surface_t *)((const byte *)surface + surface->ofsEnd);
                            continue;
                        }
                        if (skinTex != 0) {
                            textureHandle = skinTex;
                        } else if (surface->numShaders > 0) {
                            const md3Shader_t *shader = (const md3Shader_t *)((const byte *)surface + surface->ofsShaders);
                            textureHandle = RegisterTexture(shader[0].name);
                        }
                    } else if (surface->numShaders > 0) {
                        const md3Shader_t *shader = (const md3Shader_t *)((const byte *)surface + surface->ofsShaders);
                        int shaderSlot = sceneEntity->entity.skinNum % surface->numShaders;
                        if (shaderSlot < 0) {
                            shaderSlot = 0;
                        }
                        textureHandle = RegisterTexture(shader[shaderSlot].name);
                    }

                    if (sceneEntity->entity.renderfx & RF_DEPTHHACK) {
                        drawFlags |= Q3_METAL_ENTITY_DRAWFLAG_DEPTHHACK;
                    }

                    for (vertexIndex = 0; vertexIndex < surface->numVerts; ++vertexIndex) {
                        vec3_t localPosition;
                        vec3_t worldPosition;
                        const md3XyzNormal_t *currentVertex = &currentFrameVerts[vertexIndex];
                        const md3XyzNormal_t *oldVertex = &oldFrameVerts[vertexIndex];
                        Q3MetalEntityVertex *outVertex = &s_entityVertices[entityVertexCursor++];

                        localPosition[0] = (frontlerp * currentVertex->xyz[0] + backlerp * oldVertex->xyz[0]) * MD3_XYZ_SCALE;
                        localPosition[1] = (frontlerp * currentVertex->xyz[1] + backlerp * oldVertex->xyz[1]) * MD3_XYZ_SCALE;
                        localPosition[2] = (frontlerp * currentVertex->xyz[2] + backlerp * oldVertex->xyz[2]) * MD3_XYZ_SCALE;

                        worldPosition[0] = effectiveOrigin[0]
                            + effectiveAxis[0][0] * localPosition[0]
                            + effectiveAxis[1][0] * localPosition[1]
                            + effectiveAxis[2][0] * localPosition[2];
                        worldPosition[1] = effectiveOrigin[1]
                            + effectiveAxis[0][1] * localPosition[0]
                            + effectiveAxis[1][1] * localPosition[1]
                            + effectiveAxis[2][1] * localPosition[2];
                        worldPosition[2] = effectiveOrigin[2]
                            + effectiveAxis[0][2] * localPosition[0]
                            + effectiveAxis[1][2] * localPosition[1]
                            + effectiveAxis[2][2] * localPosition[2];

                        outVertex->position[0] = worldPosition[0];
                        outVertex->position[1] = worldPosition[1];
                        outVertex->position[2] = worldPosition[2];
                        outVertex->texCoord[0] = st[vertexIndex].st[0];
                        outVertex->texCoord[1] = st[vertexIndex].st[1];
                        outVertex->color[0] = entityColor[0];
                        outVertex->color[1] = entityColor[1];
                        outVertex->color[2] = entityColor[2];
                        outVertex->color[3] = entityColor[3];
                    }

                    for (triangleIndex = 0; triangleIndex < surface->numTriangles; ++triangleIndex) {
                        if (sceneEntity->mirrored) {
                            s_entityIndices[entityIndexCursor++] = baseVertex + triangles[triangleIndex].indexes[0];
                            s_entityIndices[entityIndexCursor++] = baseVertex + triangles[triangleIndex].indexes[2];
                            s_entityIndices[entityIndexCursor++] = baseVertex + triangles[triangleIndex].indexes[1];
                        } else {
                            s_entityIndices[entityIndexCursor++] = baseVertex + triangles[triangleIndex].indexes[0];
                            s_entityIndices[entityIndexCursor++] = baseVertex + triangles[triangleIndex].indexes[1];
                            s_entityIndices[entityIndexCursor++] = baseVertex + triangles[triangleIndex].indexes[2];
                        }
                    }

                    s_entityDraws[entityDrawCursor].firstIndex = firstIndex;
                    s_entityDraws[entityDrawCursor].indexCount = entityIndexCursor - firstIndex;
                    s_entityDraws[entityDrawCursor].textureHandle = (uint32_t)textureHandle;
                    s_entityDraws[entityDrawCursor].flags = drawFlags;
                    entityDrawCursor += 1;

                    surface = (const md3Surface_t *)((const byte *)surface + surface->ofsEnd);
                }
            }

            s_entityVertexCount = entityVertexCursor;
            s_entityIndexCount = entityIndexCursor;
            s_entityDrawCount = entityDrawCursor;
        }
    }

    s_frameSnapshot.entityVertexCount = s_entityVertexCount;
    s_frameSnapshot.entityIndexCount = s_entityIndexCount;
    s_frameSnapshot.entityCommandCount = s_entityDrawCount;
    if ((s_sceneLogCounter % 60) == 0) {
        ri.Printf(
            PRINT_ALL,
            "Metal entity frame: sceneEntities=%u drawCmds=%u verts=%u idx=%u\n",
            s_sceneEntityCount, s_entityDrawCount, s_entityVertexCount, s_entityIndexCount
        );
    }
}

static void RE_SetColor(const float *rgba) {
    if (rgba == NULL) {
        s_currentColor[0] = 1.0f;
        s_currentColor[1] = 1.0f;
        s_currentColor[2] = 1.0f;
        s_currentColor[3] = 1.0f;
        return;
    }

    CopyColor(s_currentColor, rgba);
}

static void RE_StretchPic(float x, float y, float w, float h, float s1, float t1, float s2, float t2, qhandle_t hShader) {
    Q3MetalDrawCmd *draw;
    qhandle_t textureHandle = hShader > 0 ? hShader : EnsureWhiteTexture();

    if (s_drawCount >= Q3_METAL_MAX_DRAWS || s_vertexCount + 6 > Q3_METAL_MAX_VERTICES) {
        return;
    }

    draw = &s_draws[s_drawCount++];
    draw->firstVertex = s_vertexCount;
    draw->vertexCount = 6;
    draw->textureHandle = (uint32_t)textureHandle;

    PushStretchPicVertex(x, y, s1, t1, s_currentColor);
    PushStretchPicVertex(x + w, y, s2, t1, s_currentColor);
    PushStretchPicVertex(x, y + h, s1, t2, s_currentColor);

    PushStretchPicVertex(x + w, y, s2, t1, s_currentColor);
    PushStretchPicVertex(x + w, y + h, s2, t2, s_currentColor);
    PushStretchPicVertex(x, y + h, s1, t2, s_currentColor);
}
static void RE_StretchRaw(int x, int y, int w, int h, int cols, int rows, byte *data, int client, qboolean dirty) {}
static void RE_UploadCinematic(int w, int h, int cols, int rows, byte *data, int client, qboolean dirty) {}

static void RE_BeginFrame(stereoFrame_t stereoFrame) {
    s_vertexCount = 0;
    s_drawCount = 0;
    s_frameSnapshot.vertexCount = 0;
    s_frameSnapshot.commandCount = 0;
    s_frameSnapshot.worldVertexCount = 0;
    s_frameSnapshot.worldIndexCount = 0;
    s_frameSnapshot.worldCommandCount = 0;
    s_frameSnapshot.worldGeneration = s_world.generation;
    s_frameSnapshot.entityVertexCount = 0;
    s_frameSnapshot.entityIndexCount = 0;
    s_frameSnapshot.entityCommandCount = 0;
}

static void RE_EndFrame(int *frontEndMsec, int *backEndMsec) {
    s_frameSnapshot.frameNumber += 1;
    s_frameSnapshot.vertexCount = s_vertexCount;
    s_frameSnapshot.commandCount = s_drawCount;
    if (frontEndMsec) *frontEndMsec = 0;
    if (backEndMsec) *backEndMsec = 0;
}

static int R_MarkFragments(int numPoints, const vec3_t *points, const vec3_t projection,
                           int maxPoints, vec3_t pointBuffer, int maxFragments, markFragment_t *fragmentBuffer) { return 0; }
static int R_LerpTag(orientation_t *tag, qhandle_t model, int startFrame, int endFrame, float frac, const char *tagName) { return 0; }
static void R_ModelBounds(qhandle_t model, vec3_t mins, vec3_t maxs) {}

static void RE_RemapShader(const char *oldShader, const char *newShader, const char *offsetTime) {}
static qboolean RE_GetEntityToken(char *buffer, int size) { return qfalse; }
static qboolean R_inPVS(const vec3_t p1, const vec3_t p2) { return qfalse; }

static void RE_TakeVideoFrame(int h, int w, byte *captureBuffer, byte *encodeBuffer, qboolean motionJpeg) {}
static void RE_ThrottleBackend(void) {}
static void RE_FinishBloom(void) {}
static void R_SetColorMappings(void) {}
static qboolean RE_CanMinimize(void) { return qfalse; }
static const glconfig_t *RE_GetConfig(void) { return &s_glConfig; }
static void RE_VertexLighting(qboolean allowed) {}
static void RE_SyncRender(void) {}

void Q3MetalRenderer_UpdateDrawableSize(int width, int height) {
    if (width <= 0 || height <= 0) {
        return;
    }

    s_glConfig.vidWidth = width;
    s_glConfig.vidHeight = height;
    s_glConfig.windowAspect = (float)width / (float)height;
    s_frameSnapshot.drawableWidth = (uint32_t)width;
    s_frameSnapshot.drawableHeight = (uint32_t)height;
}

const Q3MetalFrameSnapshot *Q3MetalRenderer_GetFrameSnapshot(void) {
    return &s_frameSnapshot;
}

const Q3MetalVertex *Q3MetalRenderer_GetVertices(void) {
    return s_vertices;
}

const Q3MetalDrawCmd *Q3MetalRenderer_GetDrawCommands(void) {
    return s_draws;
}

const Q3MetalWorldVertex *Q3MetalRenderer_GetWorldVertices(void) {
    return s_world.vertices;
}

const uint32_t *Q3MetalRenderer_GetWorldIndices(void) {
    return s_world.indices;
}

const Q3MetalWorldDrawCmd *Q3MetalRenderer_GetWorldDrawCommands(void) {
    return s_world.draws;
}

const Q3MetalEntityVertex *Q3MetalRenderer_GetEntityVertices(void) {
    return s_entityVertices;
}

const uint32_t *Q3MetalRenderer_GetEntityIndices(void) {
    return s_entityIndices;
}

const Q3MetalEntityDrawCmd *Q3MetalRenderer_GetEntityDrawCommands(void) {
    return s_entityDraws;
}

const Q3MetalSceneView *Q3MetalRenderer_GetSceneView(void) {
    return &s_sceneView;
}

int Q3MetalRenderer_GetTextureInfo(uint32_t textureHandle, Q3MetalTextureInfo *outInfo) {
    metalTexture_t *texture = FindTextureByHandle((qhandle_t)textureHandle);
    if (texture == NULL || outInfo == NULL || texture->rgbaBytes == NULL) {
        return 0;
    }

    outInfo->handle = texture->handle;
    outInfo->width = (uint32_t)texture->width;
    outInfo->height = (uint32_t)texture->height;
    outInfo->generation = texture->generation;
    outInfo->rgbaBytes = texture->rgbaBytes;
    return 1;
}

refexport_t *GetRefAPI(int apiVersion, refimport_t *rimp) {
    static refexport_t re;

    ri = *rimp;

    if (apiVersion != REF_API_VERSION) {
        ri.Printf(PRINT_ALL, "Mismatched REF_API_VERSION: expected %d, got %d\n", REF_API_VERSION, apiVersion);
        return NULL;
    }

    Com_Memset(&re, 0, sizeof(re));

    re.Shutdown = RE_Shutdown;
    re.BeginRegistration = RE_BeginRegistration;
    re.RegisterModel = RE_RegisterModel;
    re.RegisterSkin = RE_RegisterSkin;
    re.RegisterShader = RE_RegisterShader;
    re.RegisterShaderNoMip = RE_RegisterShaderNoMip;
    re.LoadWorld = RE_LoadWorldMap;
    re.SetWorldVisData = RE_SetWorldVisData;
    re.EndRegistration = RE_EndRegistration;
    re.BeginFrame = RE_BeginFrame;
    re.EndFrame = RE_EndFrame;
    re.MarkFragments = R_MarkFragments;
    re.LerpTag = R_LerpTag;
    re.ModelBounds = R_ModelBounds;
    re.ClearScene = RE_ClearScene;
    re.AddRefEntityToScene = RE_AddRefEntityToScene;
    re.AddPolyToScene = RE_AddPolyToScene;
    re.LightForPoint = R_LightForPoint;
    re.AddLightToScene = RE_AddLightToScene;
    re.AddAdditiveLightToScene = RE_AddAdditiveLightToScene;
    re.AddLinearLightToScene = RE_AddLinearLightToScene;
    re.RenderScene = RE_RenderScene;
    re.SetColor = RE_SetColor;
    re.DrawStretchPic = RE_StretchPic;
    re.DrawStretchRaw = RE_StretchRaw;
    re.UploadCinematic = RE_UploadCinematic;
    re.RegisterFont = RE_RegisterFont;
    re.RemapShader = RE_RemapShader;
    re.GetEntityToken = RE_GetEntityToken;
    re.inPVS = R_inPVS;
    re.TakeVideoFrame = RE_TakeVideoFrame;
    re.SetColorMappings = R_SetColorMappings;
    re.ThrottleBackend = RE_ThrottleBackend;
    re.FinishBloom = RE_FinishBloom;
    re.CanMinimize = RE_CanMinimize;
    re.GetConfig = RE_GetConfig;
    re.VertexLighting = RE_VertexLighting;
    re.SyncRender = RE_SyncRender;

    ri.Printf(PRINT_ALL, "=== Metal Stub Renderer Initialized ===\n");
    return &re;
}

/* STANDALONE stub — CD key not used on iOS */
#ifdef STANDALONE
#include "../qcommon/q_shared.h"
qboolean UI_usesUniqueCDKey(void) { return qfalse; }
#endif
