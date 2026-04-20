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
    int blendMode; /* 0=opaque, 1=additive, 2=alpha, 3=filter; propagated
                    * from the shader-map entry that resolved this texture. */
    int alphaFunc; /* 0=none, 1=GT0, 2=GE128, 3=LT128 */
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
    /* BSP lightgrid. LUMP_LIGHTGRID is an array of 8-byte cells
     * (ambient[3] + directed[3] + latLong[2]) sampled at a regular grid
     * over the map volume. Used by SetupEntityLighting to compute
     * per-entity ambient+directed+lightDir so MD3 entities pick up
     * the local room lighting instead of rendering full-white. */
    const byte *lightGrid;
    vec3_t lightGridOrigin;
    vec3_t lightGridSize;     /* cell dims — default (64,64,128) */
    int    lightGridBounds[3]; /* cell counts per axis */
    char name[MAX_QPATH];
} metalWorld_t;

static metalWorld_t s_world;
static metalModel_t s_models[Q3_METAL_MAX_MODELS];
static qhandle_t s_nextModelHandle = 1;
static metalSceneEntity_t s_sceneEntities[Q3_METAL_MAX_REFENTITIES];
static uint32_t s_sceneEntityCount;

/* Audit: once-per-session dedup log for missing-feature tracking. Copies
 * the message string into owned storage so callers can safely pass stack
 * buffers. Only used for genuinely missing renderer features — do NOT
 * add hooks for features we implement; stale warnings create false work.
 * Kept intentionally small (256 slots × 128 chars) to bound memory. */
#define METAL_AUDIT_MAX 256
static char s_auditSeen[METAL_AUDIT_MAX][128];
static int s_auditCount = 0;

static void AuditOnce(const char *msg) {
    int i;
    for (i = 0; i < s_auditCount; ++i) {
        if (strcmp(s_auditSeen[i], msg) == 0) return;
    }
    if (s_auditCount < METAL_AUDIT_MAX) {
        Q_strncpyz(s_auditSeen[s_auditCount], msg, sizeof(s_auditSeen[0]));
        s_auditCount += 1;
    }
    ri.Printf(PRINT_WARNING, "[Q3-AUDIT] %s\n", msg);
}
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

#define MAX_SHADER_MAP_ENTRIES 4096
#define METAL_ANIMMAP_MAX_FRAMES 16
#define Q3_MAX_STAGES 4
/* Q3_MAX_TCMODS and Q3TcMod live in metal_renderer_shared.h so both the
 * stub and Swift bindings share the exact same tcMod chain layout. */

typedef struct {
    char mapPath[MAX_QPATH];
    int blendMode;
    int rgbGen;
    int alphaGen;
    int alphaFunc;
    int tcGen;
    Q3TcMod tcMods[Q3_MAX_TCMODS];
    int tcModCount;
    int rgbWaveFunc;
    float rgbWaveBase;
    float rgbWaveAmp;
    float rgbWavePhase;
    float rgbWaveFreq;
    int alphaWaveFunc;
    float alphaWaveBase;
    float alphaWaveAmp;
    float alphaWavePhase;
    float alphaWaveFreq;
    int useLightmap;
} Q3MetalStage;

enum {
    METAL_SHADER_CULL_BACK = 0,
    METAL_SHADER_CULL_DISABLE = 1,
    METAL_SHADER_CULL_FRONT = 2
};

typedef struct {
    char shaderName[128];
    char mapPath[MAX_QPATH];
    qboolean tcGenEnv;
    float tcModScrollS;
    float tcModScrollT;
    float tcModScaleS;
    float tcModScaleT;
    qboolean hasTurb;
    float tcModTurbAmp;
    float tcModTurbPhase;
    float tcModTurbFreq;
    int blendMode;
    int alphaFunc;
    int animFrameCount;
    float animFps;
    char animFrames[METAL_ANIMMAP_MAX_FRAMES][MAX_QPATH];
    qhandle_t animTextures[METAL_ANIMMAP_MAX_FRAMES];
    char skyBoxBase[MAX_QPATH];
    qhandle_t skyFaceTextures[6];
    char stage2MapPath[MAX_QPATH];
    int stage2BlendMode;
    float stage2TcModScrollS;
    float stage2TcModScrollT;
    float stage2TcModScaleS;
    float stage2TcModScaleT;
    int cullMode;
    qboolean isPortal;
    Q3MetalStage stages[Q3_MAX_STAGES];
    int stageCount;
} metalShaderMap_t;

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

/* Sky-face texture lookup helper; defined past the metalShaderMap_t
 * struct. Takes the sky shader name and a normal direction, returns
 * the handle of the matching face texture, or 0 if the shader has no
 * skyparms directive (caller falls back to legacy sky). */
static qhandle_t GetSkyFaceTextureForSurface(const char *shaderName,
                                             float nx, float ny, float nz);

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
    (void)name;
    /* Legacy local-geometry tim_hell special-case is disabled.
     * It renders sky shader stages directly on BSP polys, which causes
     * obvious rectangular artifacts around q3dm1's teleporter area.
     * Sky shaders should flow through the generic sky path until full
     * multi-stage sky rendering is implemented. */
    return qfalse;
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
                           qhandle_t lightmapTextureHandle,
                           uint32_t flags) {
    draw->firstIndex = firstIndex;
    draw->indexCount = indexCount;
    draw->lightmapTextureHandle = (uint32_t)lightmapTextureHandle;
    draw->flags = flags;
    draw->stageCount = 0;
}

static void AddWorldDrawStage(Q3MetalWorldDrawCmd *draw,
                              qhandle_t textureHandle,
                              const Q3MetalStage *src) {
    Q3MetalWorldStage *stage;
    int i;
    int count;
    if (draw == NULL || src == NULL || draw->stageCount >= Q3_METAL_MAX_STAGES) {
        return;
    }
    stage = &draw->stages[draw->stageCount++];
    stage->textureHandle = (uint32_t)textureHandle;
    stage->blendMode = (uint32_t)src->blendMode;
    stage->tcGen = (uint32_t)src->tcGen;
    count = src->tcModCount;
    if (count < 0) count = 0;
    if (count > Q3_MAX_TCMODS) count = Q3_MAX_TCMODS;
    stage->tcModCount = (uint32_t)count;
    for (i = 0; i < count; ++i) {
        stage->tcMods[i] = src->tcMods[i];
    }
    for (; i < Q3_MAX_TCMODS; ++i) {
        stage->tcMods[i].type = 0;
        stage->tcMods[i].params[0] = 0.0f;
        stage->tcMods[i].params[1] = 0.0f;
        stage->tcMods[i].params[2] = 0.0f;
        stage->tcMods[i].params[3] = 0.0f;
    }
    stage->rgbGen = (uint32_t)src->rgbGen;
    stage->alphaGen = (uint32_t)src->alphaGen;
    stage->alphaFunc = (uint32_t)src->alphaFunc;
    stage->cullMode = 0; /* default back; per-stage cull wiring is step 6 */
    stage->useLightmap = (uint32_t)src->useLightmap;
    stage->rgbWaveFunc = (uint32_t)src->rgbWaveFunc;
    stage->rgbWaveBase = src->rgbWaveBase;
    stage->rgbWaveAmp = src->rgbWaveAmp;
    stage->rgbWavePhase = src->rgbWavePhase;
    stage->rgbWaveFreq = src->rgbWaveFreq;
    stage->alphaWaveFunc = (uint32_t)src->alphaWaveFunc;
    stage->alphaWaveBase = src->alphaWaveBase;
    stage->alphaWaveAmp = src->alphaWaveAmp;
    stage->alphaWavePhase = src->alphaWavePhase;
    stage->alphaWaveFreq = src->alphaWaveFreq;
}

/* Fallback for draws with no parsed .shader entry — construct a minimal
 * opaque stage inline. Used when a texture binds directly via
 * RegisterTexture() without going through the shader-map. */
static void AddWorldDrawStageSimple(Q3MetalWorldDrawCmd *draw,
                                    qhandle_t textureHandle,
                                    int blendMode,
                                    int rgbGen,
                                    int alphaFunc) {
    Q3MetalStage tmp;
    Com_Memset(&tmp, 0, sizeof(tmp));
    tmp.blendMode = blendMode;
    tmp.rgbGen = rgbGen;
    tmp.alphaFunc = alphaFunc;
    AddWorldDrawStage(draw, textureHandle, &tmp);
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
static const metalShaderMap_t *ShaderMap_LookupEntry(const char *name);
static void ShaderMap_GetScroll(const char *name, float *outS, float *outT);
static void ShaderMap_GetScale(const char *name, float *outS, float *outT);
static qboolean ShaderMap_GetTurb(const char *name, float *outAmp, float *outPhase, float *outFreq);
static int ShaderMap_GetBlendMode(const char *name);
static int ShaderMap_GetAlphaFunc(const char *name);
static int ShaderMap_GetTcGenEnv(const char *name);
static qboolean ShaderMap_GetSecondStage(const char *name,
                                         char *outMap, size_t outMapSize,
                                         int *outBlendMode,
                                         float *outScaleS, float *outScaleT,
                                         float *outScrollS, float *outScrollT);

static int s_pendingAnimSlot;
static float s_pendingScrollS;
static float s_pendingScrollT;
static int s_pendingBlendMode;
static int s_pendingAlphaFunc;

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
            /* Propagate the parent shader's blendMode to the frame
             * texture. Frame textures are registered under their own
             * filenames (flame4.tga, etc.) which have no shader-map
             * entry → blendMode stays 0. But the PARENT shader
             * (flame1_hell) has blendMode=1 (additive). Without this
             * propagation, additive flames render opaque. */
            metalTexture_t *animTex = FindTextureByHandle(animHandle);
            if (animTex != NULL) {
                if (animTex->blendMode == 0) {
                    int parentBM = ShaderMap_GetBlendMode(name);
                    if (parentBM != 0) animTex->blendMode = parentBM;
                }
                if (animTex->alphaFunc == 0) {
                    int parentAF = ShaderMap_GetAlphaFunc(name);
                    if (parentAF != 0) animTex->alphaFunc = parentAF;
                }
            }
            return animHandle;
        }
    }

    if (!TryLoadImageRGBA(name, &rgba, &width, &height, resolvedName, sizeof(resolvedName))) {
        /* Shader-name → texture-path resolver. The .shader scripts map
         * logical names (models/powerups/health/yellow) to actual files
         * (textures/effects/envmapyel.tga). Historically we only tried
         * entry->mapPath; walk the parsed stages + animFrames too so
         * multi-stage + animated shaders also resolve. */
        const metalShaderMap_t *entry = ShaderMap_LookupEntry(name);
        qboolean resolved = qfalse;
        qboolean diag = (!Q_stricmp(name, "textures/sfx/border11c") ||
                         !Q_stricmp(name, "textures/sfx/xmetalfloor_wall_5b") ||
                         !Q_stricmp(name, "textures/gothic_block/killblock_i4b"));
        if (diag) {
            ri.Printf(PRINT_ALL,
                "[TEX-DBG] resolving '%s' entry=%s stageCount=%d entry.mapPath='%s'\n",
                name,
                entry ? "FOUND" : "NULL",
                entry ? entry->stageCount : 0,
                entry ? (entry->mapPath[0] ? entry->mapPath : "(empty)") : "n/a");
        }
        if (entry != NULL) {
            if (entry->animFrameCount > 0 && entry->animFrames[0][0] != '\0') {
                if (TryLoadImageRGBA(entry->animFrames[0], &rgba, &width, &height, resolvedName, sizeof(resolvedName))) {
                    resolved = qtrue;
                    if (diag) ri.Printf(PRINT_ALL, "[TEX-DBG]   via animFrames[0] '%s' → '%s'\n", entry->animFrames[0], resolvedName);
                } else if (diag) {
                    ri.Printf(PRINT_ALL, "[TEX-DBG]   animFrames[0]='%s' load FAILED\n", entry->animFrames[0]);
                }
            }
            if (!resolved && entry->mapPath[0] != '\0') {
                if (TryLoadImageRGBA(entry->mapPath, &rgba, &width, &height, resolvedName, sizeof(resolvedName))) {
                    resolved = qtrue;
                    if (diag) ri.Printf(PRINT_ALL, "[TEX-DBG]   via entry.mapPath '%s' → '%s'\n", entry->mapPath, resolvedName);
                } else if (diag) {
                    ri.Printf(PRINT_ALL, "[TEX-DBG]   entry.mapPath='%s' load FAILED\n", entry->mapPath);
                }
            }
            if (!resolved) {
                int si;
                for (si = 0; si < entry->stageCount && !resolved; ++si) {
                    if (entry->stages[si].useLightmap) {
                        if (diag) ri.Printf(PRINT_ALL, "[TEX-DBG]   stage[%d] skipped (lightmap)\n", si);
                        continue;
                    }
                    if (entry->stages[si].mapPath[0] == '\0') {
                        if (diag) ri.Printf(PRINT_ALL, "[TEX-DBG]   stage[%d] skipped (empty mapPath)\n", si);
                        continue;
                    }
                    if (TryLoadImageRGBA(entry->stages[si].mapPath, &rgba, &width, &height, resolvedName, sizeof(resolvedName))) {
                        resolved = qtrue;
                        if (diag) ri.Printf(PRINT_ALL, "[TEX-DBG]   via stages[%d].mapPath '%s' → '%s'\n", si, entry->stages[si].mapPath, resolvedName);
                    } else if (diag) {
                        ri.Printf(PRINT_ALL, "[TEX-DBG]   stages[%d].mapPath='%s' load FAILED\n", si, entry->stages[si].mapPath);
                    }
                }
            }
        }
        if (!resolved) {
            /* Remember the miss so subsequent lookups skip the shader-map
             * walk and don't re-spam the warning. Finite cap, dedup by
             * name. The returned handle is the shared white texture. */
            static char s_missSeen[1024][MAX_QPATH];
            static int s_missSeenCount = 0;
            int mi;
            qboolean alreadyLogged = qfalse;
            for (mi = 0; mi < s_missSeenCount; ++mi) {
                if (!Q_stricmp(s_missSeen[mi], name)) { alreadyLogged = qtrue; break; }
            }
            if (!alreadyLogged) {
                if (s_missSeenCount < (int)(sizeof(s_missSeen) / sizeof(s_missSeen[0]))) {
                    Q_strncpyz(s_missSeen[s_missSeenCount++], name, MAX_QPATH);
                }
                ri.Printf(PRINT_WARNING, "Metal stub: failed to load UI texture '%s', falling back to white\n", name);
            }
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
    /* Propagate blend mode from the shader-map entry that resolved
     * this texture. Used by entity draw to decide additive pipeline. */
    texture->blendMode = ShaderMap_GetBlendMode(name);
    texture->alphaFunc = ShaderMap_GetAlphaFunc(name);
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

/*
===============================================================================
BSP lightgrid — per-entity ambient + directed lighting.

Loads LUMP_LIGHTGRID (15). Each cell is 8 bytes:
    byte ambient[3]    0..255 RGB ambient
    byte directed[3]   0..255 RGB directed
    byte latLong[2]    packed direction: lat*255/(2π), long*255/(2π)

Cells are laid out in Z-Y-X order at a regular grid sized by
worldspawn's `gridsize` (default (64,64,128)). The grid origin and
bounds are derived from the world BSP's model 0 mins/maxs.

SampleLightgrid does trilinear interpolation across 8 neighboring
cells and returns normalized (0..1) ambient/directed plus a
normalized lightDir. SetupEntityLighting uses the entity's
`lightingOrigin` (falls back to `origin`) as the sample point.
===============================================================================
*/

static void LoadLightgrid(const dheader_t *header, const dmodel_t *worldModel) {
    int lumpLen = LittleLong(header->lumps[LUMP_LIGHTGRID].filelen);
    int lumpOfs = LittleLong(header->lumps[LUMP_LIGHTGRID].fileofs);
    const byte *lumpData;
    int i, expectedCells, expectedBytes;
    vec3_t mins, maxs;

    s_world.lightGrid = NULL;
    s_world.lightGridBounds[0] = 0;
    s_world.lightGridBounds[1] = 0;
    s_world.lightGridBounds[2] = 0;

    if (lumpLen <= 0 || worldModel == NULL) {
        ri.Printf(PRINT_DEVELOPER, "Metal lightgrid: lump empty or no world model\n");
        return;
    }

    /* Stock Q3 default cell size. Some maps override via worldspawn
     * `gridsize` but parsing entities is out of scope for this pass;
     * default covers q3dm1 and nearly all stock maps. */
    s_world.lightGridSize[0] = 64.0f;
    s_world.lightGridSize[1] = 64.0f;
    s_world.lightGridSize[2] = 128.0f;

    for (i = 0; i < 3; ++i) {
        mins[i] = worldModel->mins[i];
        maxs[i] = worldModel->maxs[i];
    }

    /* Grid origin at the first cell boundary inside the map, grid
     * bounds at the last boundary inside. Matches stock Q3's
     * R_LoadLightGrid derivation. */
    for (i = 0; i < 3; ++i) {
        s_world.lightGridOrigin[i] = s_world.lightGridSize[i] * ceilf(mins[i] / s_world.lightGridSize[i]);
        {
            float maxBound = s_world.lightGridSize[i] * floorf(maxs[i] / s_world.lightGridSize[i]);
            s_world.lightGridBounds[i] = (int)((maxBound - s_world.lightGridOrigin[i]) / s_world.lightGridSize[i]) + 1;
        }
        if (s_world.lightGridBounds[i] < 1) {
            s_world.lightGridBounds[i] = 1;
        }
    }

    expectedCells = s_world.lightGridBounds[0] * s_world.lightGridBounds[1] * s_world.lightGridBounds[2];
    expectedBytes = expectedCells * 8;

    if (lumpLen != expectedBytes) {
        ri.Printf(PRINT_WARNING,
            "Metal lightgrid: size mismatch (%d bytes, expected %d for %dx%dx%d grid); disabling\n",
            lumpLen, expectedBytes,
            s_world.lightGridBounds[0], s_world.lightGridBounds[1], s_world.lightGridBounds[2]);
        s_world.lightGridBounds[0] = 0;
        return;
    }

    lumpData = (const byte *)header + lumpOfs;
    s_world.lightGrid = lumpData;

    ri.Printf(PRINT_ALL,
        "Metal lightgrid: loaded %dx%dx%d grid (%d cells, origin=(%.0f,%.0f,%.0f))\n",
        s_world.lightGridBounds[0], s_world.lightGridBounds[1], s_world.lightGridBounds[2],
        expectedCells,
        s_world.lightGridOrigin[0], s_world.lightGridOrigin[1], s_world.lightGridOrigin[2]);
}

static void SampleLightgrid(const vec3_t worldPos, vec3_t outAmbient, vec3_t outDirected, vec3_t outLightDir) {
    vec3_t pos;
    float fx, fy, fz, tx, ty, tz;
    int ix, iy, iz, dx, dy, dz;
    vec3_t ambient = {0, 0, 0};
    vec3_t directed = {0, 0, 0};
    vec3_t dir = {0, 0, 0};

    /* Sensible fallback when grid unavailable — dim ambient, straight-up
     * light from above. Keeps entities visible without blowing highlights. */
    outAmbient[0] = outAmbient[1] = outAmbient[2] = 0.5f;
    outDirected[0] = outDirected[1] = outDirected[2] = 0.5f;
    outLightDir[0] = 0.0f;
    outLightDir[1] = 0.0f;
    outLightDir[2] = 1.0f;

    if (s_world.lightGrid == NULL || s_world.lightGridBounds[0] < 1) {
        return;
    }

    VectorSubtract(worldPos, s_world.lightGridOrigin, pos);
    fx = pos[0] / s_world.lightGridSize[0];
    fy = pos[1] / s_world.lightGridSize[1];
    fz = pos[2] / s_world.lightGridSize[2];

    ix = (int)floorf(fx);
    iy = (int)floorf(fy);
    iz = (int)floorf(fz);
    tx = fx - ix;
    ty = fy - iy;
    tz = fz - iz;

    for (dz = 0; dz <= 1; ++dz) {
        for (dy = 0; dy <= 1; ++dy) {
            for (dx = 0; dx <= 1; ++dx) {
                int x = ix + dx;
                int y = iy + dy;
                int z = iz + dz;
                const byte *cell;
                float w, lat, lng;
                vec3_t l;

                if (x < 0 || y < 0 || z < 0 ||
                    x >= s_world.lightGridBounds[0] ||
                    y >= s_world.lightGridBounds[1] ||
                    z >= s_world.lightGridBounds[2]) {
                    continue;
                }

                cell = s_world.lightGrid + 8 * (x +
                    y * s_world.lightGridBounds[0] +
                    z * s_world.lightGridBounds[0] * s_world.lightGridBounds[1]);

                w = (dx ? tx : (1.0f - tx)) *
                    (dy ? ty : (1.0f - ty)) *
                    (dz ? tz : (1.0f - tz));

                ambient[0] += cell[0] * w;
                ambient[1] += cell[1] * w;
                ambient[2] += cell[2] * w;
                directed[0] += cell[3] * w;
                directed[1] += cell[4] * w;
                directed[2] += cell[5] * w;

                /* Q3 lat/long direction encoding:
                 *   lat byte → 0..2π latitude
                 *   long byte → 0..2π longitude
                 *   dir = (cos(lat)sin(long), sin(lat)sin(long), cos(long)) */
                lat = (float)cell[7] * ((float)M_PI * 2.0f / 255.0f);
                lng = (float)cell[6] * ((float)M_PI * 2.0f / 255.0f);
                l[0] = cosf(lat) * sinf(lng);
                l[1] = sinf(lat) * sinf(lng);
                l[2] = cosf(lng);

                dir[0] += l[0] * w;
                dir[1] += l[1] * w;
                dir[2] += l[2] * w;
            }
        }
    }

    VectorNormalize(dir);

    outAmbient[0]  = ambient[0]  / 255.0f;
    outAmbient[1]  = ambient[1]  / 255.0f;
    outAmbient[2]  = ambient[2]  / 255.0f;
    outDirected[0] = directed[0] / 255.0f;
    outDirected[1] = directed[1] / 255.0f;
    outDirected[2] = directed[2] / 255.0f;
    outLightDir[0] = dir[0];
    outLightDir[1] = dir[1];
    outLightDir[2] = dir[2];
}

/* Given a refEntity_t, compute ambient + directed + lightDir at its
 * lighting origin (falls back to origin if lightingOrigin is zero). */
static void SetupEntityLighting(const refEntity_t *ent,
                                vec3_t outAmbient,
                                vec3_t outDirected,
                                vec3_t outLightDir) {
    vec3_t origin;
    int c;
    /* Stock Q3 identityLight = 1 / (1 << r_overBrightBits). At default
     * r_overBrightBits=1, identityLight = 0.5 — the minimum per-channel
     * ambient that guarantees models never render black in dim lightgrid
     * cells. Matches tr_light.c's post-sample ambient floor. Without it,
     * pickups in dark rooms (q3dm1 railgun alcove etc.) sample 0.02
     * ambient and stay invisible even after NdotL kicks in. */
    const float kAmbientFloor = 0.5f;

    if (ent->lightingOrigin[0] != 0.0f ||
        ent->lightingOrigin[1] != 0.0f ||
        ent->lightingOrigin[2] != 0.0f) {
        VectorCopy(ent->lightingOrigin, origin);
    } else {
        VectorCopy(ent->origin, origin);
    }
    SampleLightgrid(origin, outAmbient, outDirected, outLightDir);

    for (c = 0; c < 3; ++c) {
        if (outAmbient[c] < kAmbientFloor) {
            outAmbient[c] = kAmbientFloor;
        }
    }
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
            patchWidth = LittleLong(surface->patchWidth);
            patchHeight = LittleLong(surface->patchHeight);
            totalVertices += (uint32_t)((patchWidth - 1) / 2) * (uint32_t)((patchHeight - 1) / 2) *
                             (Q3_METAL_PATCH_SUBDIVISIONS + 1) * (Q3_METAL_PATCH_SUBDIVISIONS + 1);
            totalIndices += (uint32_t)((patchWidth - 1) / 2) * (uint32_t)((patchHeight - 1) / 2) *
                            Q3_METAL_PATCH_SUBDIVISIONS * Q3_METAL_PATCH_SUBDIVISIONS * 6;
            totalDraws += (uint32_t)((patchWidth - 1) / 2) * (uint32_t)((patchHeight - 1) / 2);
            patchDraws += (uint32_t)((patchWidth - 1) / 2) * (uint32_t)((patchHeight - 1) / 2);
        } else {
            int numVerts = LittleLong(surface->numVerts);
            int numIndexes = LittleLong(surface->numIndexes);

            if (numIndexes % 3) {
                numIndexes -= numIndexes % 3;
            }
            totalVertices += (uint32_t)numVerts;
            totalIndices += (uint32_t)numIndexes;
            totalDraws += 1;

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

    /* Load the lightgrid (LUMP_LIGHTGRID). World model is model 0 in
     * LUMP_MODELS — its mins/maxs define the grid bounds. */
    {
        const dmodel_t *models = (const dmodel_t *)((const byte *)fileBuffer +
                                                    LittleLong(header->lumps[LUMP_MODELS].fileofs));
        int modelLen = LittleLong(header->lumps[LUMP_MODELS].filelen);
        if (modelLen >= (int)sizeof(dmodel_t)) {
            LoadLightgrid(header, &models[0]);
        }
    }

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
        qhandle_t skyOverrideTexture;
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
        skyOverrideTexture = 0;

        if (shaderNum < 0 || shaderNum >= shaderCount) {
            continue;
        }
        if (!IsDrawableWorldShader(&shaders[shaderNum])) {
            continue;
        }

        if (IsSkyShaderName(shaders[shaderNum].shader)) {
            qhandle_t skyFace = 0;
            if (numVerts > 0) {
                float nx = 0, ny = 0, nz = 0;
                int nSample = numVerts < 4 ? numVerts : 4;
                int vi;
                for (vi = 0; vi < nSample; ++vi) {
                    const drawVert_t *dv = &drawVerts[firstVert + vi];
                    nx += dv->normal[0];
                    ny += dv->normal[1];
                    nz += dv->normal[2];
                }
                skyFace = GetSkyFaceTextureForSurface(shaders[shaderNum].shader, nx, ny, nz);
            }
            if (skyFace != 0) {
                skyOverrideTexture = skyFace;
                textureHandle = skyFace;
            } else {
                textureHandle = 0;
            }
            skyDraws += 1;
        } else {
            textureHandle = 0;
        }

        s_pendingAnimSlot = ShaderMap_FindAnimatedSlot(shaders[shaderNum].shader);
        lightmapHandle = EnsureWhiteTexture();
        worldFlags = defaultWorldFlags;
        if (!IsSkyShaderName(shaders[shaderNum].shader) && lightmapNum >= 0 && lightmapNum < s_worldLightmapCount) {
            const metalShaderMap_t *_le = ShaderMap_LookupEntry(shaders[shaderNum].shader);
            qboolean wantLightmap = qfalse;
            if (_le == NULL || _le->stageCount == 0) {
                wantLightmap = qtrue;
            } else {
                int _ls;
                for (_ls = 0; _ls < _le->stageCount; ++_ls) {
                    if (_le->stages[_ls].useLightmap) {
                        wantLightmap = qtrue;
                        break;
                    }
                }
            }
            if (wantLightmap) {
                lightmapHandle = s_worldLightmapHandles[lightmapNum];
                hasLightmap = qtrue;
                worldFlags |= Q3_METAL_WORLD_DRAWFLAG_LIGHTMAP_MULTIPLY;
            }
        }
        if (IsSkyShaderName(shaders[shaderNum].shader)) {
            worldFlags |= Q3_METAL_WORLD_DRAWFLAG_SKY;
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

                    {
                        uint32_t firstIndexForDraw = s_world.draws[drawCursor].firstIndex;
                        uint32_t indexCountForDraw = indexCursor - firstIndexForDraw;
                        uint32_t _dstIdx = drawCursor;
                        SetupWorldDraw(&s_world.draws[drawCursor++],
                                       firstIndexForDraw,
                                       indexCountForDraw,
                                       hasLightmap ? lightmapHandle : EnsureWhiteTexture(),
                                       worldFlags);
                        if (s_world.animShaderSlots && s_pendingAnimSlot >= 0) {
                            s_world.animShaderSlots[_dstIdx] = s_pendingAnimSlot;
                            s_world.animatedDrawCount += 1;
                        }
                        {
                            const metalShaderMap_t *_e = ShaderMap_LookupEntry(shaders[shaderNum].shader);
                            int _s;
                            if (_e != NULL && _e->stageCount > 0) {
                                for (_s = 0; _s < _e->stageCount; ++_s) {
                                    const Q3MetalStage *_st = &_e->stages[_s];
                                    qhandle_t _tex;
                                    if (_st->useLightmap) {
                                        _tex = lightmapHandle;
                                    } else if (_s == 0 && skyOverrideTexture != 0) {
                                        _tex = skyOverrideTexture;
                                    } else {
                                        _tex = (_st->mapPath[0] != '\0') ? RegisterTexture(_st->mapPath) : 0;
                                    }
                                    if (_tex == 0) continue;
                                    AddWorldDrawStage(&s_world.draws[_dstIdx], _tex, _st);
                                }
                            }
                            if (_e == NULL || _e->stageCount == 0) {
                                qhandle_t _tex = (skyOverrideTexture != 0)
                                               ? skyOverrideTexture
                                               : RegisterTexture(shaders[shaderNum].shader);
                                if (_tex != 0) {
                                    AddWorldDrawStageSimple(&s_world.draws[_dstIdx], _tex, 0, 0, 0);
                                }
                            }
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

        {
            uint32_t firstIndexForDraw = s_world.draws[drawCursor].firstIndex;
            uint32_t indexCountForDraw = indexCursor - firstIndexForDraw;
            uint32_t _dstIdx = drawCursor;
            SetupWorldDraw(&s_world.draws[drawCursor++],
                           firstIndexForDraw,
                           indexCountForDraw,
                           hasLightmap ? lightmapHandle : EnsureWhiteTexture(),
                           worldFlags);
            if (s_world.animShaderSlots && s_pendingAnimSlot >= 0) {
                s_world.animShaderSlots[_dstIdx] = s_pendingAnimSlot;
                s_world.animatedDrawCount += 1;
            }
            {
                const metalShaderMap_t *_e = ShaderMap_LookupEntry(shaders[shaderNum].shader);
                int _s;
                if (_e != NULL && _e->stageCount > 0) {
                    for (_s = 0; _s < _e->stageCount; ++_s) {
                        const Q3MetalStage *_st = &_e->stages[_s];
                        qhandle_t _tex;
                        if (_st->useLightmap) {
                            _tex = lightmapHandle;
                        } else if (_s == 0 && skyOverrideTexture != 0) {
                            _tex = skyOverrideTexture;
                        } else {
                            _tex = (_st->mapPath[0] != '\0') ? RegisterTexture(_st->mapPath) : 0;
                        }
                        if (_tex == 0) continue;
                        AddWorldDrawStage(&s_world.draws[_dstIdx], _tex, _st);
                    }
                }
                if (_e == NULL || _e->stageCount == 0) {
                    qhandle_t _tex = (skyOverrideTexture != 0)
                                   ? skyOverrideTexture
                                   : RegisterTexture(shaders[shaderNum].shader);
                    if (_tex != 0) {
                        AddWorldDrawStageSimple(&s_world.draws[_dstIdx], _tex, 0, 0, 0);
                    }
                }
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
/* Sky face enumeration. Order matches Q3 convention. */
#define METAL_SKY_FACE_UP 0
#define METAL_SKY_FACE_DN 1
#define METAL_SKY_FACE_FT 2  /* +X */
#define METAL_SKY_FACE_BK 3  /* -X */
#define METAL_SKY_FACE_LF 4  /* +Y */
#define METAL_SKY_FACE_RT 5  /* -Y */
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

/* Returns the tcMod scroll (s, t) values parsed from the first stage
 * of the named shader, or (0, 0) if unknown / absent. */
/* Q3 skybox support. Resolves one of six face textures for a sky
 * shader based on the surface's dominant normal direction. Returns 0
 * if the named shader has no skyparms directive; caller falls back
 * to the legacy fake sky. Lazily registers each face texture. */
static qhandle_t GetSkyFaceTextureForSurface(const char *shaderName,
                                             float nx, float ny, float nz) {
    static const char *kSuffixes[6] = { "_up", "_dn", "_ft", "_bk", "_lf", "_rt" };
    metalShaderMap_t *entry = NULL;
    int i, faceIdx;
    float ax, ay, az;
    char path[MAX_QPATH];
    if (shaderName == NULL || shaderName[0] == '\0') return 0;

    for (i = 0; i < s_shaderMapCount; ++i) {
        if (!Q_stricmp(s_shaderMap[i].shaderName, shaderName) &&
            s_shaderMap[i].skyBoxBase[0] != '\0') {
            entry = &s_shaderMap[i];
            break;
        }
    }
    if (entry == NULL) return 0;

    ax = fabsf(nx); ay = fabsf(ny); az = fabsf(nz);
    if (az >= ax && az >= ay) {
        faceIdx = (nz >= 0.0f) ? 0 /*up*/ : 1 /*dn*/;
    } else if (ax >= ay) {
        faceIdx = (nx >= 0.0f) ? 2 /*ft*/ : 3 /*bk*/;
    } else {
        faceIdx = (ny >= 0.0f) ? 4 /*lf*/ : 5 /*rt*/;
    }

    if (entry->skyFaceTextures[faceIdx] != 0) {
        return entry->skyFaceTextures[faceIdx];
    }
    Com_sprintf(path, sizeof(path), "%s%s", entry->skyBoxBase, kSuffixes[faceIdx]);
    entry->skyFaceTextures[faceIdx] = RegisterTexture(path);
    return entry->skyFaceTextures[faceIdx];
}

static int ShaderMap_GetBlendMode(const char *name) {
    const metalShaderMap_t *entry;
    if (name == NULL || name[0] == '\0') return 0;
    /* Use ShaderMap_LookupEntry which handles extension-stripped
     * fallback (e.g. 'yellow.tga' → 'yellow'). A plain stricmp
     * loop missed entity textures registered with their file
     * extension while shader definitions omit it. */
    entry = ShaderMap_LookupEntry(name);
    return entry ? entry->blendMode : 0;
}

/* blendMode enum used throughout the stub and the Q3MetalWorldStage:
 *   0 = opaque (no blend)
 *   1 = additive (GL_ONE/GL_ONE, GL_SRC_ALPHA/GL_ONE)
 *   2 = alpha   (GL_SRC_ALPHA/GL_ONE_MINUS_SRC_ALPHA)
 *   3 = filter  (GL_DST_COLOR/GL_ZERO and commutative form GL_ZERO/GL_SRC_COLOR)
 * If Q3 supports the blendFunc combo, we must map it. Unrecognized combos
 * fall through to opaque AND log once so missing cases surface without
 * re-introducing stage0/stage2 heuristics. */
static int BlendModeFromTokens(const char *src, const char *dst) {
    if (src == NULL || src[0] == '\0') return 0;

    /* Short Q3 aliases — these are dst-independent. */
    if (!Q_stricmp(src, "add"))    return 1;
    if (!Q_stricmp(src, "blend"))  return 2;
    if (!Q_stricmp(src, "filter")) return 3;

    if (dst == NULL || dst[0] == '\0') return 0;

    /* Canonical additive. */
    if (!Q_stricmp(src, "GL_ONE") && !Q_stricmp(dst, "GL_ONE")) return 1;
    /* Premultiplied additive (flame, glow). */
    if (!Q_stricmp(src, "GL_SRC_ALPHA") && !Q_stricmp(dst, "GL_ONE")) return 1;
    /* Alpha blend (transparent decals, glass). */
    if (!Q_stricmp(src, "GL_SRC_ALPHA") && !Q_stricmp(dst, "GL_ONE_MINUS_SRC_ALPHA")) return 2;
    /* Filter / modulate (lightmap pass, dark overlay). */
    if (!Q_stricmp(src, "GL_DST_COLOR") && !Q_stricmp(dst, "GL_ZERO")) return 3;
    /* Filter (commutative factor ordering — some shaders author this form). */
    if (!Q_stricmp(src, "GL_ZERO") && !Q_stricmp(dst, "GL_SRC_COLOR")) return 3;
    /* Opaque explicit (no-op blend). */
    if (!Q_stricmp(src, "GL_ONE") && !Q_stricmp(dst, "GL_ZERO")) return 0;
    /* Skip stage — GL_ZERO/GL_ZERO writes black. We render opaque-black
     * rather than dropping so the stage still consumes its slot; if a
     * shader relies on this being a no-op, promote to a dedicated drop
     * path later. */
    if (!Q_stricmp(src, "GL_ZERO") && !Q_stricmp(dst, "GL_ZERO")) return 0;

    /* Unknown combo: warn once. Adding here is cheaper than bisecting
     * visuals weeks later. */
    {
        static char s_unknownSeen[64][64];
        static int s_unknownCount = 0;
        char combo[64];
        int u;
        qboolean seen = qfalse;
        Com_sprintf(combo, sizeof(combo), "%s|%s", src, dst);
        for (u = 0; u < s_unknownCount; ++u) {
            if (!Q_stricmp(s_unknownSeen[u], combo)) { seen = qtrue; break; }
        }
        if (!seen && s_unknownCount < (int)(sizeof(s_unknownSeen) / sizeof(s_unknownSeen[0]))) {
            Q_strncpyz(s_unknownSeen[s_unknownCount++], combo, sizeof(s_unknownSeen[0]));
            ri.Printf(PRINT_WARNING, "Metal shader: unrecognized blendFunc '%s %s' → opaque\n", src, dst);
        }
    }
    return 0;
}

static int ShaderMap_GetAlphaFunc(const char *name) {
    const metalShaderMap_t *entry;
    if (name == NULL || name[0] == '\0') return 0;
    entry = ShaderMap_LookupEntry(name);
    return entry ? entry->alphaFunc : 0;
}

static int ShaderMap_GetTcGenEnv(const char *name) {
    const metalShaderMap_t *entry;
    if (name == NULL || name[0] == '\0') return 0;
    entry = ShaderMap_LookupEntry(name);
    return (entry && entry->tcGenEnv) ? 1 : 0;
}

static void ShaderMap_GetScroll(const char *name, float *outS, float *outT) {
    int i;
    if (outS) *outS = 0.0f;
    if (outT) *outT = 0.0f;
    if (name == NULL || name[0] == '\0') return;
    for (i = 0; i < s_shaderMapCount; ++i) {
        if (!Q_stricmp(s_shaderMap[i].shaderName, name)) {
            if (outS) *outS = s_shaderMap[i].tcModScrollS;
            if (outT) *outT = s_shaderMap[i].tcModScrollT;
            return;
        }
    }
}

static void ShaderMap_GetScale(const char *name, float *outS, float *outT) {
    const metalShaderMap_t *entry;
    if (outS) *outS = 1.0f;
    if (outT) *outT = 1.0f;
    if (name == NULL || name[0] == '\0') return;
    entry = ShaderMap_LookupEntry(name);
    if (entry == NULL) return;
    if (outS) *outS = entry->tcModScaleS;
    if (outT) *outT = entry->tcModScaleT;
}

static qboolean ShaderMap_GetTurb(const char *name, float *outAmp, float *outPhase, float *outFreq) {
    const metalShaderMap_t *entry;
    if (outAmp) *outAmp = 0.0f;
    if (outPhase) *outPhase = 0.0f;
    if (outFreq) *outFreq = 0.0f;
    if (name == NULL || name[0] == '\0') return qfalse;
    entry = ShaderMap_LookupEntry(name);
    if (entry == NULL || !entry->hasTurb) return qfalse;
    if (outAmp) *outAmp = entry->tcModTurbAmp;
    if (outPhase) *outPhase = entry->tcModTurbPhase;
    if (outFreq) *outFreq = entry->tcModTurbFreq;
    return qtrue;
}

static qboolean ShaderMap_GetSecondStage(const char *name,
                                         char *outMap, size_t outMapSize,
                                         int *outBlendMode,
                                         float *outScaleS, float *outScaleT,
                                         float *outScrollS, float *outScrollT) {
    const metalShaderMap_t *entry = ShaderMap_LookupEntry(name);
    if (outMap && outMapSize > 0) outMap[0] = '\0';
    if (outBlendMode) *outBlendMode = 0;
    if (outScaleS) *outScaleS = 1.0f;
    if (outScaleT) *outScaleT = 1.0f;
    if (outScrollS) *outScrollS = 0.0f;
    if (outScrollT) *outScrollT = 0.0f;
    if (entry == NULL || entry->stage2MapPath[0] == '\0') return qfalse;
    if (outMap && outMapSize > 0) {
        Q_strncpyz(outMap, entry->stage2MapPath, outMapSize);
    }
    if (outBlendMode) *outBlendMode = entry->stage2BlendMode;
    if (outScaleS) *outScaleS = entry->stage2TcModScaleS;
    if (outScaleT) *outScaleT = entry->stage2TcModScaleT;
    if (outScrollS) *outScrollS = entry->stage2TcModScrollS;
    if (outScrollT) *outScrollT = entry->stage2TcModScrollT;
    return qtrue;
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
    if (name && (strstr(name, "border11c") || strstr(name, "killblock_i4b") ||
                 strstr(name, "xmetalfloor_wall_5b") ||
                 strncmp(name, "textures/sfx/", 13) == 0)) {
        size_t nlen = strlen(name);
        ri.Printf(PRINT_ALL, "[SHADER-REG] name=[%s] len=%zu last3bytes=%02x,%02x,%02x path=[%s]\n",
            name, nlen,
            (nlen >= 3) ? (unsigned char)name[nlen-3] : 0,
            (nlen >= 2) ? (unsigned char)name[nlen-2] : 0,
            (nlen >= 1) ? (unsigned char)name[nlen-1] : 0,
            path ? path : "(null)");
    }
    Q_strncpyz(s_shaderMap[s_shaderMapCount].shaderName, name,
        sizeof(s_shaderMap[0].shaderName));
    Q_strncpyz(s_shaderMap[s_shaderMapCount].mapPath, path,
        sizeof(s_shaderMap[0].mapPath));
    s_shaderMap[s_shaderMapCount].tcGenEnv = tcGenEnv;
    s_shaderMap[s_shaderMapCount].tcModScaleS = 1.0f;
    s_shaderMap[s_shaderMapCount].tcModScaleT = 1.0f;
    s_shaderMap[s_shaderMapCount].stage2TcModScaleS = 1.0f;
    s_shaderMap[s_shaderMapCount].stage2TcModScaleT = 1.0f;
    s_shaderMap[s_shaderMapCount].animFrameCount = 0;
    s_shaderMap[s_shaderMapCount].animFps = 0.0f;
    s_shaderMap[s_shaderMapCount].cullMode = METAL_SHADER_CULL_BACK;
    s_shaderMap[s_shaderMapCount].stageCount = 0;
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
    s_shaderMap[s_shaderMapCount].tcModScaleS = 1.0f;
    s_shaderMap[s_shaderMapCount].tcModScaleT = 1.0f;
    s_shaderMap[s_shaderMapCount].stage2TcModScaleS = 1.0f;
    s_shaderMap[s_shaderMapCount].stage2TcModScaleT = 1.0f;
    s_shaderMap[s_shaderMapCount].animFrameCount = maxFrames;
    s_shaderMap[s_shaderMapCount].animFps = (fps > 0.0f) ? fps : 8.0f;
    s_shaderMap[s_shaderMapCount].cullMode = METAL_SHADER_CULL_BACK;
    s_shaderMap[s_shaderMapCount].stageCount = 0;
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
        char animFrames[METAL_ANIMMAP_MAX_FRAMES][MAX_QPATH];
        int animFrameCount;
        float animFps;
        int depth;
        qboolean inStage;
        qboolean gotAnim;
        qboolean tcGenEnv;
        int cullMode;
        char skyBoxBase[MAX_QPATH];
        qboolean gotSkyParms;
        qboolean gotPortal;
        Q3MetalStage cur;
        Q3MetalStage stages[Q3_MAX_STAGES];
        int stagesCount;

        token = COM_ParseExt(&p, qtrue);
        if (!token[0]) break;
        Q_strncpyz(shaderName, token, sizeof(shaderName));

        token = COM_ParseExt(&p, qtrue);
        if (token[0] != '{') continue;

        animFrameCount = 0;
        animFps = 0.0f;
        depth = 1;
        inStage = qfalse;
        gotAnim = qfalse;
        tcGenEnv = qfalse;
        cullMode = METAL_SHADER_CULL_BACK;
        skyBoxBase[0] = '\0';
        gotSkyParms = qfalse;
        gotPortal = qfalse;
        Com_Memset(&cur, 0, sizeof(cur));
        Com_Memset(stages, 0, sizeof(stages));
        stagesCount = 0;

        while (depth > 0) {
            token = COM_ParseExt(&p, qtrue);
            if (!token[0]) break;

            if (token[0] == '{' && token[1] == '\0') {
                depth += 1;
                if (depth == 2) {
                    inStage = qtrue;
                    Com_Memset(&cur, 0, sizeof(cur));
                }
                continue;
            }
            if (token[0] == '}' && token[1] == '\0') {
                depth -= 1;
                /* Only append on stage-close (depth 2→1). The outer
                 * shader-close (depth 1→0) previously also hit this and
                 * appended a stale cur as a duplicate/bogus stage. */
                if (depth == 1) {
                    inStage = qfalse;
                    if (cur.useLightmap && cur.blendMode == 0) {
                        cur.blendMode = 3;
                    }
                    if (stagesCount < Q3_MAX_STAGES) {
                        stages[stagesCount++] = cur;
                    }
                }
                continue;
            }

            if (!inStage) {
                if (!gotSkyParms && !Q_stricmp(token, "skyparms")) {
                    token = COM_ParseExt(&p, qfalse);
                    if (token[0] && Q_stricmp(token, "-") != 0) {
                        Q_strncpyz(skyBoxBase, token, sizeof(skyBoxBase));
                        gotSkyParms = qtrue;
                    }
                } else if (!gotPortal && !Q_stricmp(token, "portal")) {
                    gotPortal = qtrue;
                } else if (!Q_stricmp(token, "cull")) {
                    token = COM_ParseExt(&p, qfalse);
                    if (token[0] &&
                        (!Q_stricmp(token, "disable") ||
                         !Q_stricmp(token, "twosided") ||
                         !Q_stricmp(token, "none"))) {
                        cullMode = METAL_SHADER_CULL_DISABLE;
                    } else if (token[0] && !Q_stricmp(token, "front")) {
                        cullMode = METAL_SHADER_CULL_FRONT;
                    } else {
                        cullMode = METAL_SHADER_CULL_BACK;
                    }
                }
                continue;
            }

            {
                if (!Q_stricmp(token, "map") || !Q_stricmp(token, "clampmap")) {
                    token = COM_ParseExt(&p, qfalse);
                    if (token[0]) {
                        if (!Q_stricmp(token, "$lightmap")) {
                            cur.useLightmap = 1;
                        } else if (cur.mapPath[0] == '\0') {
                            Q_strncpyz(cur.mapPath, token, sizeof(cur.mapPath));
                        }
                    }
                } else if (!Q_stricmp(token, "animMap") || !Q_stricmp(token, "animmap")) {
                    token = COM_ParseExt(&p, qfalse);
                    animFps = (float)atof(token);
                    while (1) {
                        token = COM_ParseExt(&p, qfalse);
                        if (!token[0]) break;
                        if (token[0] == '$') continue;
                        if (animFrameCount >= METAL_ANIMMAP_MAX_FRAMES) continue;
                        Q_strncpyz(animFrames[animFrameCount], token, MAX_QPATH);
                        animFrameCount += 1;
                    }
                    if (animFrameCount > 0) {
                        Q_strncpyz(cur.mapPath, animFrames[0], sizeof(cur.mapPath));
                        gotAnim = qtrue;
                    }
                } else if (!Q_stricmp(token, "tcGen") || !Q_stricmp(token, "tcgen")) {
                    token = COM_ParseExt(&p, qfalse);
                    if (token[0] && (!Q_stricmp(token, "environment") ||
                                     !Q_stricmp(token, "env"))) {
                        tcGenEnv = qtrue;
                    }
                } else if (!Q_stricmp(token, "blendFunc") || !Q_stricmp(token, "blendfunc")) {
                    const char *src = COM_ParseExt(&p, qfalse);
                    const char *dst = COM_ParseExt(&p, qfalse);
                    if (src[0]) {
                        cur.blendMode = BlendModeFromTokens(src, dst);
                    }
                } else if (!Q_stricmp(token, "alphaFunc") || !Q_stricmp(token, "alphafunc")) {
                    token = COM_ParseExt(&p, qfalse);
                    if (!Q_stricmp(token, "GT0")) cur.alphaFunc = 1;
                    else if (!Q_stricmp(token, "GE128")) cur.alphaFunc = 2;
                    else if (!Q_stricmp(token, "LT128")) cur.alphaFunc = 3;
                } else if (!Q_stricmp(token, "rgbGen") || !Q_stricmp(token, "rgbgen")) {
                    token = COM_ParseExt(&p, qfalse);
                    if (!Q_stricmp(token, "vertex")) cur.rgbGen = 1;
                    else if (!Q_stricmp(token, "lightingDiffuse") ||
                             !Q_stricmp(token, "lightingdiffuse")) cur.rgbGen = 2;
                    else if (!Q_stricmp(token, "wave")) cur.rgbGen = 3;
                    else cur.rgbGen = 0;
                    if (!Q_stricmp(token, "wave")) {
                        const char *funcTok = COM_ParseExt(&p, qfalse);
                        const char *baseTok = COM_ParseExt(&p, qfalse);
                        const char *ampTok = COM_ParseExt(&p, qfalse);
                        const char *phaseTok = COM_ParseExt(&p, qfalse);
                        const char *freqTok = COM_ParseExt(&p, qfalse);
                        if (funcTok[0]) {
                            if (!Q_stricmp(funcTok, "sin")) cur.rgbWaveFunc = 1;
                            else if (!Q_stricmp(funcTok, "triangle")) cur.rgbWaveFunc = 2;
                            else if (!Q_stricmp(funcTok, "square")) cur.rgbWaveFunc = 3;
                            else if (!Q_stricmp(funcTok, "sawtooth")) cur.rgbWaveFunc = 4;
                            else if (!Q_stricmp(funcTok, "inversesawtooth") ||
                                     !Q_stricmp(funcTok, "inverseSawtooth")) cur.rgbWaveFunc = 5;
                            else if (!Q_stricmp(funcTok, "noise")) cur.rgbWaveFunc = 6;
                            else cur.rgbWaveFunc = 1;
                        }
                        if (baseTok[0]) cur.rgbWaveBase = (float)atof(baseTok);
                        if (ampTok[0]) cur.rgbWaveAmp = (float)atof(ampTok);
                        if (phaseTok[0]) cur.rgbWavePhase = (float)atof(phaseTok);
                        if (freqTok[0]) cur.rgbWaveFreq = (float)atof(freqTok);
                    } else if (!Q_stricmp(token, "const") ||
                               !Q_stricmp(token, "exactVertex") ||
                               !Q_stricmp(token, "exactvertex")) {
                        (void)COM_ParseExt(&p, qfalse);
                        (void)COM_ParseExt(&p, qfalse);
                        (void)COM_ParseExt(&p, qfalse);
                        (void)COM_ParseExt(&p, qfalse);
                        (void)COM_ParseExt(&p, qfalse);
                    }
                } else if (!Q_stricmp(token, "alphaGen") || !Q_stricmp(token, "alphagen")) {
                    token = COM_ParseExt(&p, qfalse);
                    if (!Q_stricmp(token, "vertex")) cur.alphaGen = 1;
                    else if (!Q_stricmp(token, "wave")) cur.alphaGen = 3;
                    else cur.alphaGen = 0;
                    if (!Q_stricmp(token, "wave")) {
                        const char *funcTok = COM_ParseExt(&p, qfalse);
                        const char *baseTok = COM_ParseExt(&p, qfalse);
                        const char *ampTok = COM_ParseExt(&p, qfalse);
                        const char *phaseTok = COM_ParseExt(&p, qfalse);
                        const char *freqTok = COM_ParseExt(&p, qfalse);
                        if (funcTok[0]) {
                            if (!Q_stricmp(funcTok, "sin")) cur.alphaWaveFunc = 1;
                            else if (!Q_stricmp(funcTok, "triangle")) cur.alphaWaveFunc = 2;
                            else if (!Q_stricmp(funcTok, "square")) cur.alphaWaveFunc = 3;
                            else if (!Q_stricmp(funcTok, "sawtooth")) cur.alphaWaveFunc = 4;
                            else if (!Q_stricmp(funcTok, "inversesawtooth") ||
                                     !Q_stricmp(funcTok, "inverseSawtooth")) cur.alphaWaveFunc = 5;
                            else if (!Q_stricmp(funcTok, "noise")) cur.alphaWaveFunc = 6;
                            else cur.alphaWaveFunc = 1;
                        }
                        if (baseTok[0]) cur.alphaWaveBase = (float)atof(baseTok);
                        if (ampTok[0]) cur.alphaWaveAmp = (float)atof(ampTok);
                        if (phaseTok[0]) cur.alphaWavePhase = (float)atof(phaseTok);
                        if (freqTok[0]) cur.alphaWaveFreq = (float)atof(freqTok);
                    } else if (!Q_stricmp(token, "const")) {
                        (void)COM_ParseExt(&p, qfalse);
                    } else if (!Q_stricmp(token, "portal")) {
                        (void)COM_ParseExt(&p, qfalse);
                    }
                } else if (!Q_stricmp(token, "tcMod") || !Q_stricmp(token, "tcmod")) {
                    token = COM_ParseExt(&p, qfalse);
                    if (token[0] && !Q_stricmp(token, "scroll")) {
                        const char *sTok = COM_ParseExt(&p, qfalse);
                        const char *tTok = COM_ParseExt(&p, qfalse);
                        if (sTok[0] && tTok[0] && cur.tcModCount < Q3_MAX_TCMODS) {
                            cur.tcMods[cur.tcModCount].type = 1;
                            cur.tcMods[cur.tcModCount].params[0] = (float)atof(sTok);
                            cur.tcMods[cur.tcModCount].params[1] = (float)atof(tTok);
                            cur.tcMods[cur.tcModCount].params[2] = 0.0f;
                            cur.tcMods[cur.tcModCount].params[3] = 0.0f;
                            cur.tcModCount += 1;
                        }
                    } else if (token[0] && !Q_stricmp(token, "scale")) {
                        const char *sTok = COM_ParseExt(&p, qfalse);
                        const char *tTok = COM_ParseExt(&p, qfalse);
                        if (sTok[0] && tTok[0] && cur.tcModCount < Q3_MAX_TCMODS) {
                            cur.tcMods[cur.tcModCount].type = 4;
                            cur.tcMods[cur.tcModCount].params[0] = (float)atof(sTok);
                            cur.tcMods[cur.tcModCount].params[1] = (float)atof(tTok);
                            cur.tcMods[cur.tcModCount].params[2] = 0.0f;
                            cur.tcMods[cur.tcModCount].params[3] = 0.0f;
                            cur.tcModCount += 1;
                        }
                    } else if (token[0] && !Q_stricmp(token, "turb")) {
                        const char *baseTok = COM_ParseExt(&p, qfalse);
                        const char *ampTok = COM_ParseExt(&p, qfalse);
                        const char *phaseTok = COM_ParseExt(&p, qfalse);
                        const char *freqTok = COM_ParseExt(&p, qfalse);
                        (void)baseTok;
                        if (ampTok[0] && phaseTok[0] && freqTok[0] && cur.tcModCount < Q3_MAX_TCMODS) {
                            cur.tcMods[cur.tcModCount].type = 5;
                            cur.tcMods[cur.tcModCount].params[0] = (float)atof(ampTok);
                            cur.tcMods[cur.tcModCount].params[1] = (float)atof(freqTok);
                            cur.tcMods[cur.tcModCount].params[2] = (float)atof(phaseTok);
                            cur.tcMods[cur.tcModCount].params[3] = 0.0f;
                            cur.tcModCount += 1;
                        }
                    } else if (token[0] && !Q_stricmp(token, "rotate")) {
                        const char *speedTok = COM_ParseExt(&p, qfalse);
                        if (speedTok[0] && cur.tcModCount < Q3_MAX_TCMODS) {
                            cur.tcMods[cur.tcModCount].type = 3;
                            cur.tcMods[cur.tcModCount].params[0] = (float)atof(speedTok);
                            cur.tcMods[cur.tcModCount].params[1] = 0.0f;
                            cur.tcMods[cur.tcModCount].params[2] = 0.0f;
                            cur.tcMods[cur.tcModCount].params[3] = 0.0f;
                            cur.tcModCount += 1;
                        }
                    } else if (token[0] && !Q_stricmp(token, "stretch")) {
                        COM_ParseExt(&p, qfalse);
                        COM_ParseExt(&p, qfalse);
                        COM_ParseExt(&p, qfalse);
                        COM_ParseExt(&p, qfalse);
                    } else if (token[0] && !Q_stricmp(token, "transform")) {
                        COM_ParseExt(&p, qfalse);
                        COM_ParseExt(&p, qfalse);
                        COM_ParseExt(&p, qfalse);
                        COM_ParseExt(&p, qfalse);
                        COM_ParseExt(&p, qfalse);
                    }
                }
            }
        }

        {
            char shaderMapPath[MAX_QPATH];
            int s;
            shaderMapPath[0] = '\0';
            for (s = 0; s < stagesCount; ++s) {
                if (stages[s].mapPath[0] != '\0' && !stages[s].useLightmap) {
                    Q_strncpyz(shaderMapPath, stages[s].mapPath, sizeof(shaderMapPath));
                    break;
                }
            }
            if (gotAnim && animFrameCount > 0) {
                ShaderMap_RegisterAnimated(shaderName, animFrames, animFrameCount, animFps, tcGenEnv);
            } else {
                ShaderMap_Register(shaderName, shaderMapPath, tcGenEnv);
            }
        }

        if (s_shaderMapCount > 0) {
            metalShaderMap_t *last = &s_shaderMap[s_shaderMapCount - 1];
            if (!Q_stricmp(last->shaderName, shaderName)) {
                int s;
                Com_Memset(last->stages, 0, sizeof(last->stages));
                for (s = 0; s < Q3_MAX_STAGES; ++s) {
                    last->stages[s] = stages[s];
                }
                last->stageCount = stagesCount;
                last->cullMode = cullMode;
                last->isPortal = gotPortal;

                /* Diagnostic: dump full parse state for shaders we know
                 * are falling back to white. Substring match tolerates
                 * stray trailing chars (\r, \t, spaces) that would break
                 * an exact Q_stricmp comparison. */
                if (strstr(shaderName, "border11c") ||
                    strstr(shaderName, "xmetalfloor_wall_5b") ||
                    strstr(shaderName, "killblock_i4b")) {
                    int ds;
                    ri.Printf(PRINT_ALL,
                        "[SHADER-DBG] registered '%s' stageCount=%d mapPath='%s' cull=%d portal=%d\n",
                        shaderName, stagesCount,
                        (last->mapPath[0] != '\0') ? last->mapPath : "(empty)",
                        cullMode, gotPortal ? 1 : 0);
                    for (ds = 0; ds < stagesCount; ++ds) {
                        ri.Printf(PRINT_ALL,
                            "[SHADER-DBG]   stage[%d] mapPath='%s' useLightmap=%d blend=%d alphaFunc=%d rgbGen=%d tcMods=%d\n",
                            ds,
                            (stages[ds].mapPath[0] != '\0') ? stages[ds].mapPath : "(empty)",
                            stages[ds].useLightmap, stages[ds].blendMode,
                            stages[ds].alphaFunc, stages[ds].rgbGen,
                            stages[ds].tcModCount);
                    }
                }
                if (gotSkyParms) {
                    Q_strncpyz(last->skyBoxBase, skyBoxBase, sizeof(last->skyBoxBase));
                }
                if (stagesCount > 0) {
                    int m;
                    last->blendMode = stages[0].blendMode;
                    last->alphaFunc = stages[0].alphaFunc;
                    last->tcModScrollS = 0.0f;
                    last->tcModScrollT = 0.0f;
                    last->tcModScaleS = 1.0f;
                    last->tcModScaleT = 1.0f;
                    last->hasTurb = qfalse;
                    for (m = 0; m < stages[0].tcModCount; ++m) {
                        const Q3TcMod *mod = &stages[0].tcMods[m];
                        if (mod->type == 1) {
                            last->tcModScrollS = mod->params[0];
                            last->tcModScrollT = mod->params[1];
                        } else if (mod->type == 4) {
                            last->tcModScaleS = mod->params[0];
                            last->tcModScaleT = mod->params[1];
                        } else if (mod->type == 5) {
                            last->hasTurb = qtrue;
                            last->tcModTurbAmp = mod->params[0];
                            last->tcModTurbFreq = mod->params[1];
                            last->tcModTurbPhase = mod->params[2];
                        }
                    }
                }
            }
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
        int j;

        Com_sprintf(path, sizeof(path), "scripts/%s", fileList[i]);
        len = ri.FS_ReadFile(path, (void **)&buf);
        if (len <= 0 || buf == NULL) {
            if (buf) ri.FS_FreeFile(buf);
            continue;
        }
        /* Normalize CRLF → LF in place. The original id shader files ship
         * with Windows line endings (\r\n); COM_ParseExt leaves the \r
         * attached to the preceding token, so shader names parsed from
         * CRLF files are stored as 'textures/sfx/border11c\r' and fail
         * every subsequent lookup. Replacing \r with space also avoids
         * confusing the parser with an extra empty line. */
        for (j = 0; j < len; ++j) {
            if (buf[j] == '\r') buf[j] = ' ';
        }
        {
            int before = s_shaderMapCount;
            ri.Printf(PRINT_ALL, "[PARSER-DBG] begin file=%s size=%d mapCount=%d\n",
                fileList[i], len, s_shaderMapCount);
            ParseShaderText(buf);
            ri.Printf(PRINT_ALL, "[PARSER-DBG] end   file=%s registered=%d (total=%d)\n",
                fileList[i], s_shaderMapCount - before, s_shaderMapCount);
        }
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
    /* RT_SPRITE: billboard quad (plasma bolts, rail core, muzzle flashes,
     * smoke puffs). We accept sprites into the scene-entity list and emit
     * their geometry at RE_RenderScene time (camera-facing math requires
     * the view axes, which aren't known here). All other reTypes
     * (RT_BEAM, RT_RAIL_CORE, etc.) are still rejected for now and emit
     * an audit entry so we can see what else the map submits. */
    if (re->reType == RT_SPRITE) {
        AuditOnce("ENTITY:RT_SPRITE");
        s_sceneEntities[s_sceneEntityCount].entity = *re;
        s_sceneEntities[s_sceneEntityCount].mirrored = qfalse;
        s_sceneEntityCount += 1;
        s_entityAcceptedThisFrame += 1;
        return;
    }
    if (re->reType != RT_MODEL) {
        if (re->reType == RT_BEAM) AuditOnce("ENTITY:RT_BEAM");
        else if (re->reType == RT_RAIL_CORE) AuditOnce("ENTITY:RT_RAIL_CORE");
        else if (re->reType == RT_RAIL_RINGS) AuditOnce("ENTITY:RT_RAIL_RINGS");
        else if (re->reType == RT_LIGHTNING) AuditOnce("ENTITY:RT_LIGHTNING");
        else if (re->reType == RT_PORTALSURFACE) AuditOnce("ENTITY:RT_PORTALSURFACE");
        else AuditOnce("ENTITY:reType unknown");
        s_entityRejectedTypeThisFrame += 1;
        return;
    }
    if (re->hModel == 0 || FindModelByHandle(re->hModel) == NULL) {
        s_entityRejectedModelThisFrame += 1;
        return;
    }

    /* Defensive origin/axis validation. Scoreboard/intermission scenes
     * (rdflags=0x1) intermittently submit refEntity_t instances with
     * astronomical origin values (Y ≈ 8e25, etc). If accepted, the
     * MD3 rasterizes triangles that span the entire viewport — with the
     * skin texture falling back to white, the whole frame blanks to
     * solid white. Reject non-finite or out-of-range coords up front.
     * 1e6 is well past any legitimate Q3 world coordinate (maps are
     * ~8192 units across) so the threshold has ample headroom. */
    {
        int c;
        qboolean badOrigin = qfalse;
        qboolean badAxis = qfalse;
        for (c = 0; c < 3 && !badOrigin; ++c) {
            float v = re->origin[c];
            if (!isfinite(v) || fabsf(v) > 1.0e6f) badOrigin = qtrue;
        }
        for (c = 0; c < 3 && !badAxis; ++c) {
            float v = re->axis[0][c];
            if (!isfinite(v)) badAxis = qtrue;
            v = re->axis[1][c]; if (!isfinite(v)) badAxis = qtrue;
            v = re->axis[2][c]; if (!isfinite(v)) badAxis = qtrue;
        }
        if (badOrigin || badAxis) {
            s_entityRejectedModelThisFrame += 1;
            AuditOnce(badOrigin ? "ENTITY:rejected-implausible-origin"
                                 : "ENTITY:rejected-non-finite-axis");
            return;
        }
    }

    s_sceneEntities[s_sceneEntityCount].entity = *re;
    CrossProduct(re->axis[0], re->axis[1], cross);
    s_sceneEntities[s_sceneEntityCount].mirrored = (DotProduct(re->axis[2], cross) < 0.0f);
    s_sceneEntityCount += 1;
    s_entityAcceptedThisFrame += 1;
}
static void RE_AddPolyToScene(qhandle_t hShader, int numVerts, const polyVert_t *verts, int num) {
    AuditOnce("POLY:RE_AddPolyToScene");
    (void)hShader; (void)numVerts; (void)verts; (void)num;
}
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
     * stage-0 textureHandle with the current animation frame. Zero-cost
     * when animatedDrawCount == 0 (maps with no animated world shaders). */
    if (s_world.loaded && s_world.animatedDrawCount > 0 &&
        s_world.animShaderSlots != NULL && s_world.draws != NULL) {
        uint32_t i;
        for (i = 0; i < s_world.drawCount; ++i) {
            int slot = s_world.animShaderSlots[i];
            if (slot >= 0) {
                qhandle_t h = ShaderMap_AnimatedSlotCurrentHandle(slot);
                if (h != 0 && s_world.draws[i].stageCount > 0) {
                    s_world.draws[i].stages[0].textureHandle = (uint32_t)h;
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

    /* Refdef fallback camera — gated behind cvar now that native cgame
     * writes a valid refdef. With cgame.qvm's broken ABI the refdef
     * arrived with invalid fov (< 45) and we'd synthesize one from
     * cl.snap.ps.origin. Unnecessary after commit 5977485.
     *   \metal_fallback_camera 1  (re-enable fallback)
     * If native cgame regresses, flip this on and watch the log for
     * 'Metal fallback camera[...]' to reconfirm the ABI issue. */
    {
        static cvar_t *s_cvarFallbackCam = NULL;
        if (s_cvarFallbackCam == NULL) {
            s_cvarFallbackCam = ri.Cvar_Get("metal_fallback_camera", "0", CVAR_ARCHIVE);
        }
        if (s_cvarFallbackCam->integer && s_world.loaded && fovX < 45.0f) {
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

    /* Synthetic viewmodel injection — disabled by default now that
     * native cgame runs and CG_AddViewWeapon submits the real viewmodel
     * at the correct tag_weapon position with correct animations and
     * muzzle flash. Toggle via console to fall back if cgame's output
     * looks wrong:
     *   \metal_synth_viewmodel 1
     *
     * This was a QVM-ABI-mismatch workaround; commit 5977485 made it
     * obsolete by switching cgame to native. Leaving the code path in
     * place (behind the cvar) as a safety net during the native cgame
     * shakedown period. */
    {
        static cvar_t *s_cvarSynthVm;
        if (s_cvarSynthVm == NULL) {
            s_cvarSynthVm = ri.Cvar_Get("metal_synth_viewmodel", "0", CVAR_ARCHIVE);
        }
        if (s_cvarSynthVm->integer) {
            SynthesizeViewmodelEntity(vieworg, axis0, axis1, axis2);
        }
    }

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
            const metalModel_t *model;
            const md3Header_t *header;
            const md3Surface_t *surface;
            int surfaceIndex;

            /* Sprites reserve a single quad: 4 verts, 6 indices, 1 draw. */
            if (sceneEntity->entity.reType == RT_SPRITE) {
                totalEntityVerts += 4;
                totalEntityIndices += 6;
                totalEntityDraws += 1;
                continue;
            }

            model = FindModelByHandle(sceneEntity->entity.hModel);
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
                const metalModel_t *model;
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

                /* RT_SPRITE: billboard quad facing the camera. Q3 view
                 * axis convention: axis[0]=forward, axis[1]=left,
                 * axis[2]=up — so right_world = -axis1, up_world = axis2.
                 * Uses additive blend (flags bit) + the additive entity
                 * pipeline which already runs depth-read-only (no write)
                 * via additiveEntityDepthStencilState. Covers plasma
                 * bolts, rail core, muzzle flashes, smoke puffs. */
                if (sceneEntity->entity.reType == RT_SPRITE) {
                    uint32_t baseVertex = entityVertexCursor;
                    uint32_t firstIndex = entityIndexCursor;
                    float radius = sceneEntity->entity.radius;
                    vec3_t right, up;
                    vec3_t v0, v1, v2, v3;
                    float r, g, b, a;
                    int i;
                    if (radius < 0.5f) radius = 8.0f;  /* sensible default */
                    VectorScale(axis1, -radius, right);
                    VectorScale(axis2,  radius, up);
                    /* Four billboard corners. CCW order with UV
                     * origin at top-left (Q3 tex convention). */
                    VectorSubtract(sceneEntity->entity.origin, right, v0);
                    VectorSubtract(v0, up, v0);
                    VectorAdd(sceneEntity->entity.origin, right, v1);
                    VectorSubtract(v1, up, v1);
                    VectorAdd(sceneEntity->entity.origin, right, v2);
                    VectorAdd(v2, up, v2);
                    VectorSubtract(sceneEntity->entity.origin, right, v3);
                    VectorAdd(v3, up, v3);
                    r = (float)sceneEntity->entity.shader.rgba[0] / 255.0f;
                    g = (float)sceneEntity->entity.shader.rgba[1] / 255.0f;
                    b = (float)sceneEntity->entity.shader.rgba[2] / 255.0f;
                    a = (float)sceneEntity->entity.shader.rgba[3] / 255.0f;
                    /* Emit 4 verts: BL, BR, TR, TL */
                    s_entityVertices[baseVertex + 0].position[0] = v0[0];
                    s_entityVertices[baseVertex + 0].position[1] = v0[1];
                    s_entityVertices[baseVertex + 0].position[2] = v0[2];
                    s_entityVertices[baseVertex + 0].texCoord[0] = 0.0f;
                    s_entityVertices[baseVertex + 0].texCoord[1] = 1.0f;
                    s_entityVertices[baseVertex + 1].position[0] = v1[0];
                    s_entityVertices[baseVertex + 1].position[1] = v1[1];
                    s_entityVertices[baseVertex + 1].position[2] = v1[2];
                    s_entityVertices[baseVertex + 1].texCoord[0] = 1.0f;
                    s_entityVertices[baseVertex + 1].texCoord[1] = 1.0f;
                    s_entityVertices[baseVertex + 2].position[0] = v2[0];
                    s_entityVertices[baseVertex + 2].position[1] = v2[1];
                    s_entityVertices[baseVertex + 2].position[2] = v2[2];
                    s_entityVertices[baseVertex + 2].texCoord[0] = 1.0f;
                    s_entityVertices[baseVertex + 2].texCoord[1] = 0.0f;
                    s_entityVertices[baseVertex + 3].position[0] = v3[0];
                    s_entityVertices[baseVertex + 3].position[1] = v3[1];
                    s_entityVertices[baseVertex + 3].position[2] = v3[2];
                    s_entityVertices[baseVertex + 3].texCoord[0] = 0.0f;
                    s_entityVertices[baseVertex + 3].texCoord[1] = 0.0f;
                    for (i = 0; i < 4; ++i) {
                        s_entityVertices[baseVertex + i].color[0] = r;
                        s_entityVertices[baseVertex + i].color[1] = g;
                        s_entityVertices[baseVertex + i].color[2] = b;
                        s_entityVertices[baseVertex + i].color[3] = a;
                    }
                    /* Two triangles: 0-1-2, 0-2-3. */
                    s_entityIndices[entityIndexCursor + 0] = baseVertex + 0;
                    s_entityIndices[entityIndexCursor + 1] = baseVertex + 1;
                    s_entityIndices[entityIndexCursor + 2] = baseVertex + 2;
                    s_entityIndices[entityIndexCursor + 3] = baseVertex + 0;
                    s_entityIndices[entityIndexCursor + 4] = baseVertex + 2;
                    s_entityIndices[entityIndexCursor + 5] = baseVertex + 3;
                    entityVertexCursor += 4;
                    entityIndexCursor += 6;
                    s_entityDraws[entityDrawCursor].firstIndex = firstIndex;
                    s_entityDraws[entityDrawCursor].indexCount = 6;
                    s_entityDraws[entityDrawCursor].textureHandle = (uint32_t)sceneEntity->entity.customShader;
                    s_entityDraws[entityDrawCursor].flags = Q3_METAL_ENTITY_DRAWFLAG_ADDITIVE | Q3_METAL_ENTITY_DRAWFLAG_NOCULL;
                    entityDrawCursor += 1;
                    continue;
                }

                model = FindModelByHandle(sceneEntity->entity.hModel);
                if (model == NULL || model->md3 == NULL) {
                    continue;
                }

                /* Hide local-player entities that cgame submits with
                 * broken transforms (QVM ABI bug — renderfx bits land
                 * in the wrong field, see brain.db msg 172). Three
                 * classes of near-camera models get filtered:
                 *
                 *   /players/.../{head,upper,lower}.md3
                 *     — the body parts; without suppression, looking
                 *       down shows your own torso.
                 *
                 *   /weapons2/...
                 *     — cgame's first-person viewmodel (CG_AddViewWeapon
                 *       submits the weapon + flash + barrel + hand
                 *       tag chain). With ABI breakage these render at
                 *       garbage origins; user screenshots showed a
                 *       ghost shotgun floating on the left and red
                 *       polygon slashes when turning. Our own synthetic
                 *       viewmodel (isSynthetic == qtrue) stays since
                 *       it's correctly placed in view space.
                 *
                 * Proximity: 40 world units (sqrt(1600)). Distant
                 * players + their weapons (other clients, bots) still
                 * render normally. */
                /* Legacy proximity filter — gated behind cvar now that
                 * native cgame places body parts + weapons correctly
                 * via RF_THIRD_PERSON. Toggle back if cgame somehow
                 * still exhibits the ABI artifacts:
                 *   \metal_hide_nearby 1  (re-enable filter) */
                static cvar_t *s_cvarHideNearby = NULL;
                if (s_cvarHideNearby == NULL) {
                    s_cvarHideNearby = ri.Cvar_Get("metal_hide_nearby", "0", CVAR_ARCHIVE);
                }
                if (s_cvarHideNearby->integer && !sceneEntity->isSynthetic && model->inUse) {
                    const char *mname = model->name;
                    qboolean isLocalPart = qfalse;
                    if (mname) {
                        size_t mlen = strlen(mname);
                        if (strstr(mname, "/players/") != NULL) {
                            if (mlen >= 9  && strcmp(mname + mlen - 9,  "/head.md3")  == 0) isLocalPart = qtrue;
                            if (mlen >= 10 && strcmp(mname + mlen - 10, "/upper.md3") == 0) isLocalPart = qtrue;
                            if (mlen >= 10 && strcmp(mname + mlen - 10, "/lower.md3") == 0) isLocalPart = qtrue;
                        }
                        if (strstr(mname, "/weapons2/") != NULL) {
                            /* Suppress cgame's first-person weapon chain
                             * with one exception: *_flash.md3 muzzle
                             * flashes. They're transient (one frame per
                             * shot), submitted via tag_flash on fire,
                             * and even mispositioned they give useful
                             * 'weapon is firing' feedback. Without this
                             * exemption the machinegun/plasma/rail look
                             * dead when you pull the trigger. */
                            if (!(mlen >= 10 && strcmp(mname + mlen - 10, "_flash.md3") == 0)) {
                                isLocalPart = qtrue;
                            }
                        }
                    }
                    if (isLocalPart) {
                        float dx = sceneEntity->entity.origin[0] - s_sceneView.viewOrigin[0];
                        float dy = sceneEntity->entity.origin[1] - s_sceneView.viewOrigin[1];
                        float dz = sceneEntity->entity.origin[2] - s_sceneView.viewOrigin[2];
                        float distSq = dx*dx + dy*dy + dz*dz;
                        if (distSq < 1600.0f) {
                            continue;
                        }
                    }
                }

                /* Q3 renderfx visibility filtering.
                 * RF_THIRD_PERSON: body parts of local player — skip in
                 *   first-person view (render only in mirrors / third-
                 *   person cameras). Fixes "looking down shows own body".
                 * No need for RF_FIRST_PERSON whitelist: stock cgame
                 *   flags the viewmodel with RF_FIRST_PERSON|RF_DEPTHHACK;
                 *   we already handle DEPTHHACK and we want it to render
                 *   in our (first-person) view so don't skip it. */
                if (sceneEntity->entity.renderfx & RF_THIRD_PERSON) {
                    continue;
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

                /* Sample BSP lightgrid at the entity's lighting origin.
                 * Ambient + directed are 0..1; lightDir is a unit vec.
                 * Applied per-vertex in the inner loop as Lambert diffuse. */
                vec3_t entityAmbient, entityDirected, entityLightDir;
                SetupEntityLighting(&sceneEntity->entity, entityAmbient, entityDirected, entityLightDir);

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
                    /* Check entity's shader for additive blending (e.g.
                     * health orbs, glow effects, flame pickups). The
                     * texture's blendMode was propagated from the shader-
                     * map entry at RegisterTexture time. */
                    {
                        const metalTexture_t *tex = FindTextureByHandle(textureHandle);
                        if (tex != NULL) {
                            if (tex->blendMode == 1) {
                                drawFlags |= Q3_METAL_ENTITY_DRAWFLAG_ADDITIVE;
                            } else if (tex->blendMode == 2) {
                                drawFlags |= Q3_METAL_ENTITY_DRAWFLAG_ALPHA;
                            } else if (tex->blendMode == 3) {
                                drawFlags |= Q3_METAL_ENTITY_DRAWFLAG_FILTER;
                            }
                        }
                        /* Diagnostic: first 5 per frame */
                        {
                            static int s_entityBlendLog = 0;
                            if (s_entityBlendLog < 5 && tex != NULL) {
                                ri.Printf(PRINT_ALL, "Metal entity blend: tex='%s' bm=%d flags=0x%x\n",
                                          tex->name, tex->blendMode, drawFlags);
                                s_entityBlendLog++;
                            }
                        }
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

                        /* Per-vertex Lambert diffuse from BSP lightgrid.
                         * 1. Decode MD3 lat/long normal (2 bytes packed).
                         *    `currentVertex->normal` is stored as
                         *    high=lat, low=long in Q3's short format.
                         * 2. Rotate to world space by entity axis.
                         * 3. Lambert: N·L clamped to 0.
                         * 4. diffuse = ambient + directed * NdotL,
                         *    modulated by shaderRGBA (entityColor). */
                        {
                            int latByte = (currentVertex->normal >> 8) & 0xff;
                            int lngByte = currentVertex->normal & 0xff;
                            float latRad = latByte * ((float)M_PI * 2.0f / 255.0f);
                            float lngRad = lngByte * ((float)M_PI * 2.0f / 255.0f);
                            vec3_t localN, worldN;
                            float ndotl, rgb0, rgb1, rgb2;

                            localN[0] = cosf(latRad) * sinf(lngRad);
                            localN[1] = sinf(latRad) * sinf(lngRad);
                            localN[2] = cosf(lngRad);

                            worldN[0] = effectiveAxis[0][0] * localN[0]
                                      + effectiveAxis[1][0] * localN[1]
                                      + effectiveAxis[2][0] * localN[2];
                            worldN[1] = effectiveAxis[0][1] * localN[0]
                                      + effectiveAxis[1][1] * localN[1]
                                      + effectiveAxis[2][1] * localN[2];
                            worldN[2] = effectiveAxis[0][2] * localN[0]
                                      + effectiveAxis[1][2] * localN[1]
                                      + effectiveAxis[2][2] * localN[2];

                            /* Defensive normalize. localN is unit by
                             * construction (sin²+cos²=1), but cgame's
                             * entity.axis can drift out of orthonormality
                             * over time — the rotated worldN ends up
                             * slightly >1 or <1 and Lambert's N·L
                             * produces clamped/bogus values on those
                             * entities. VectorNormalize returns early
                             * on zero-length vectors so it's safe. */
                            VectorNormalize(worldN);

                            ndotl = worldN[0] * entityLightDir[0]
                                  + worldN[1] * entityLightDir[1]
                                  + worldN[2] * entityLightDir[2];
                            if (ndotl < 0.0f) ndotl = 0.0f;

                            rgb0 = (entityAmbient[0] + entityDirected[0] * ndotl) * entityColor[0];
                            rgb1 = (entityAmbient[1] + entityDirected[1] * ndotl) * entityColor[1];
                            rgb2 = (entityAmbient[2] + entityDirected[2] * ndotl) * entityColor[2];
                            if (rgb0 > 1.0f) rgb0 = 1.0f;
                            if (rgb1 > 1.0f) rgb1 = 1.0f;
                            if (rgb2 > 1.0f) rgb2 = 1.0f;

                            outVertex->color[0] = rgb0;
                            outVertex->color[1] = rgb1;
                            outVertex->color[2] = rgb2;
                            outVertex->color[3] = entityColor[3];
                        }
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
static int R_LerpTag(orientation_t *tag, qhandle_t handle, int startFrame, int endFrame, float frac, const char *tagName) {
    const metalModel_t *model;
    const md3Header_t *hdr;
    const md3Tag_t *tags;
    int numTags, tagIndex;
    const md3Tag_t *start, *end;
    int i;

    if (tag == NULL || tagName == NULL || tagName[0] == '\0') {
        return -1;
    }
    Com_Memset(tag, 0, sizeof(*tag));

    model = FindModelByHandle(handle);
    if (model == NULL || !model->inUse || model->md3 == NULL) {
        return -1;
    }
    hdr = model->md3;
    numTags = hdr->numTags;
    if (numTags <= 0) {
        return -1;
    }

    if (startFrame < 0 || startFrame >= hdr->numFrames) startFrame = 0;
    if (endFrame < 0 || endFrame >= hdr->numFrames) endFrame = 0;
    if (frac < 0.0f) frac = 0.0f;
    if (frac > 1.0f) frac = 1.0f;

    tags = (const md3Tag_t *)((const byte *)hdr + hdr->ofsTags);

    tagIndex = -1;
    for (i = 0; i < numTags; ++i) {
        if (!Q_stricmp(tags[i].name, tagName)) {
            tagIndex = i;
            break;
        }
    }
    if (tagIndex < 0) {
        return -1;
    }

    start = &tags[startFrame * numTags + tagIndex];
    end   = &tags[endFrame   * numTags + tagIndex];

    for (i = 0; i < 3; ++i) {
        tag->origin[i] = start->origin[i] + frac * (end->origin[i] - start->origin[i]);
        tag->axis[0][i] = start->axis[0][i] + frac * (end->axis[0][i] - start->axis[0][i]);
        tag->axis[1][i] = start->axis[1][i] + frac * (end->axis[1][i] - start->axis[1][i]);
        tag->axis[2][i] = start->axis[2][i] + frac * (end->axis[2][i] - start->axis[2][i]);
    }
    VectorNormalize(tag->axis[0]);
    VectorNormalize(tag->axis[1]);
    VectorNormalize(tag->axis[2]);

    return 0;
}
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
