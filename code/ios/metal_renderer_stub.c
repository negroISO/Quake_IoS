// metal_renderer_stub.c — Phase 1 stub renderer providing GetRefAPI()
// Replaces the Vulkan renderer with no-op implementations

#include "../qcommon/q_shared.h"
#include "../qcommon/qfiles.h"
#include "../client/client.h"
#include "../renderercommon/tr_public.h"
#include "../renderer/tr_common.h"
#include "metal_renderer_shared.h"

#define Q3_METAL_MAX_VERTICES 65536
#define Q3_METAL_MAX_DRAWS 8192
#define Q3_METAL_MAX_TEXTURES 1024

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
    qboolean loaded;
    uint32_t generation;
    uint32_t vertexCount;
    uint32_t indexCount;
    uint32_t drawCount;
    Q3MetalWorldVertex *vertices;
    uint32_t *indices;
    Q3MetalWorldDrawCmd *draws;
    char name[MAX_QPATH];
} metalWorld_t;

static metalWorld_t s_world;

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
    static const char *extensions[] = { "", ".tga", ".jpg", ".jpeg" };
    int i;

    *rgba = NULL;
    *width = 0;
    *height = 0;

    for (i = 0; i < ARRAY_LEN(extensions); ++i) {
        char candidate[MAX_QPATH];
        if (extensions[i][0] != '\0' && COM_GetExtension(name)[0] != '\0') {
            continue;
        }

        Com_sprintf(candidate, sizeof(candidate), "%s%s", name, extensions[i]);
        if (!Q_stricmp(COM_GetExtension(candidate), "tga")) {
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

    existing = FindTextureByName(name);
    if (existing != NULL) {
        return existing->handle;
    }

    if (!TryLoadImageRGBA(name, &rgba, &width, &height, resolvedName, sizeof(resolvedName))) {
        ri.Printf(PRINT_WARNING, "Metal stub: failed to load UI texture '%s', falling back to white\n", name);
        return EnsureWhiteTexture();
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
    if (s_worldLightmapHandles != NULL) {
        ri.Free(s_worldLightmapHandles);
        s_worldLightmapHandles = NULL;
    }
    s_worldLightmapCount = 0;
    Com_Memset(&s_world, 0, sizeof(s_world));
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
                        SetupWorldDraw(&s_world.draws[drawCursor++],
                                       firstIndexForDraw,
                                       indexCountForDraw,
                                       textureHandle,
                                       hasLightmap ? lightmapHandle : EnsureWhiteTexture(),
                                       worldFlags,
                                       1.0f, 1.0f,
                                       0.0f, 0.0f);
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
            SetupWorldDraw(&s_world.draws[drawCursor++],
                           firstIndexForDraw,
                           indexCountForDraw,
                           textureHandle,
                           hasLightmap ? lightmapHandle : EnsureWhiteTexture(),
                           worldFlags,
                           1.0f, 1.0f,
                           0.0f, 0.0f);
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
    FreeWorldMapData();
    ri.Printf(PRINT_ALL, "RE_Shutdown: Metal stub\n");
}

static void RE_BeginRegistration(glconfig_t *config) {
    ri.Printf(PRINT_ALL, "RE_BeginRegistration: Metal stub\n");
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

static qhandle_t s_nextStubModelHandle = 1;
static qhandle_t s_nextStubSkinHandle = 1;

static qhandle_t RE_RegisterModel(const char *name) {
    if (name == NULL || name[0] == '\0') {
        return 0;
    }

    // Phase 4 only draws BSP world geometry. Return stable non-zero handles so
    // cgame can finish client/world setup even though MD3 model rendering is not
    // implemented in the Metal path yet.
    return 0x10000000 + s_nextStubModelHandle++;
}

static qhandle_t RE_RegisterSkin(const char *name) {
    if (name == NULL || name[0] == '\0') {
        return 0;
    }

    return 0x20000000 + s_nextStubSkinHandle++;
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

static void RE_ClearScene(void) {}
static void RE_AddRefEntityToScene(const refEntity_t *re, qboolean intShaderTime) {}
static void RE_AddPolyToScene(qhandle_t hShader, int numVerts, const polyVert_t *verts, int num) {}
static int R_LightForPoint(vec3_t point, vec3_t ambientLight, vec3_t directedLight, vec3_t lightDir) { return 0; }
static void RE_AddLightToScene(const vec3_t org, float intensity, float r, float g, float b) {}
static void RE_AddAdditiveLightToScene(const vec3_t org, float intensity, float r, float g, float b) {}
static void RE_AddLinearLightToScene(const vec3_t start, const vec3_t end, float intensity, float r, float g, float b) {}
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
    }

    if (s_world.loaded && !(fd->rdflags & RDF_NOWORLDMODEL)) {
        s_frameSnapshot.worldVertexCount = s_world.vertexCount;
        s_frameSnapshot.worldIndexCount = s_world.indexCount;
        s_frameSnapshot.worldCommandCount = s_world.drawCount;
        s_frameSnapshot.worldGeneration = s_world.generation;
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
