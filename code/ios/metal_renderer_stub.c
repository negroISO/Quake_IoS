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
    int tcGenEnv;  /* 1 if the resolved shader uses `tcGen environment`
                    * (chrome/reflective like powerups/quad, shell shaders).
                    * Entity pipeline reads this to switch UV generation
                    * from mesh ST to the reflection formula. */
    int rgbGen;    /* 0=identity, 1=vertex, 2=lightingDiffuse, 3=wave.
                    * Stored per-texture so the entity fragment can skip
                    * the baked-in Lambert color for chrome shells that
                    * upstream treats as full-bright (CGEN_IDENTITY). */
    int alphaGen;  /* 0=identity (force alpha 1.0), 1=vertex, 3=wave.
                    * Parallels rgbGen and matches upstream AGEN_IDENTITY,
                    * which overrides vertex alpha with 255 so stages that
                    * opt into identity alpha stay opaque regardless of
                    * the entity shaderRGBA alpha channel. */
    /* Stage 0 rgbGen wave parameters — only meaningful when rgbGen == 3.
     * Copied from the shader-map so the entity fragment can evaluate the
     * glow wave per frame. rgbWaveFunc selects the waveform shape
     * (1=sin, 2=triangle, 3=square, 4=sawtooth, 5=inverse_sawtooth). */
    int rgbWaveFunc;
    float rgbWaveBase;
    float rgbWaveAmp;
    float rgbWavePhase;
    float rgbWaveFreq;
    /* Stage 0 alphaGen wave parameters — mirrors rgbWave* and is
     * consumed when alphaGen == 3. */
    int alphaWaveFunc;
    float alphaWaveBase;
    float alphaWaveAmp;
    float alphaWavePhase;
    float alphaWaveFreq;
    /* rgbGen const (CGEN_CONST): static RGB tint multiplied against the
     * texel when rgbGen == 4. Copied from stage[0].rgbConstColor. */
    float rgbConstColor[3];
    /* alphaGen const: static alpha multiplier when alphaGen == 4.
     * Default 1.0 (no-op). */
    float alphaConst;
    /* Stage 0 tcMod chain, copied from the resolved shader-map entry at
     * registration time. Entity pipeline propagates to Swift so the
     * fragment shader can apply scroll/rotate after tcGen env — matches
     * ioquake3's RB_CalcScrollTexCoords + RB_CalcRotateTexCoords order. */
    int tcModCount;
    Q3TcMod tcMods[Q3_MAX_TCMODS];
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

/* Per-map fog LUT (cycle F1 of fog rendering). LUMP_FOGS in the BSP
 * holds one dfog_t per fog volume; each one names a shader whose
 * fogparms directive we parsed earlier into
 * metalShaderMap_t.hasFog/fogColor/fogDistance. We resolve the name
 * once at world-load time and cache the result so per-frame drawing
 * can index by surface->fogNum without another shader-map walk.
 * hasColor==qfalse means the referenced shader either wasn't parsed
 * or didn't declare fogparms — treat as "no fog" for that volume. */
#define METAL_MAX_WORLD_FOGS 256  /* matches MAX_MAP_FOGS in qfiles.h */
typedef struct {
    char  shaderName[MAX_QPATH];
    qboolean hasColor;
    float color[3];
    float distance;
} metalWorldFog_t;
static metalWorldFog_t s_worldFogs[METAL_MAX_WORLD_FOGS];
/* Parallel array exposed to Swift via Q3MetalRenderer_GetWorldFogs.
 * Same count as s_worldFogs; each entry's color[3]+distance matches
 * s_worldFogs[i].color/distance. Entries whose hasColor==qfalse are
 * zeroed out here so Swift seeing distance==0 reliably means "no
 * fog for this volume" even if the fogIndex was passed through. */
static Q3MetalWorldFog s_worldFogsPublic[METAL_MAX_WORLD_FOGS];
static int s_worldFogCount;

/* Flare points harvested from the BSP's MST_FLARE lump. Populated at world
 * load, consumed each frame by the Swift renderer to emit camera-facing
 * additive billboards. Texture handle is set to the resolved 'flareShader'
 * (gfx/misc/flare.tga) during world load — 0 means no flare texture
 * available, flares skip rendering. */
static Q3MetalFlare s_worldFlares[Q3_METAL_MAX_FLARES];
static int s_worldFlareCount;
static uint32_t s_flareTextureHandle;

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
static Q3MetalLight s_sceneLights[Q3_METAL_MAX_LIGHTS];
static uint32_t s_sceneLightCount;

/* Per-frame scene pool. Captured in RE_RenderScene, consumed by Swift's
 * draw(). sceneCount is reset at frame start in RE_BeginFrame; each
 * RenderScene call appends one entry. Entity + light ranges index into
 * the shared per-frame pools populated alongside. */
static Q3MetalSceneSnapshot s_sceneSnapshots[Q3_METAL_MAX_SCENES];
static uint32_t s_sceneSnapshotCount;

/* Per-frame light pool. s_sceneLights[] is the intake buffer that
 * AddLightToScene fills between ClearScene+RenderScene for the CURRENT
 * scene. At RenderScene time we memcpy those lights to s_frameLights
 * so each scene gets a stable range for Swift to bind by scene. */
static Q3MetalLight s_frameLights[Q3_METAL_MAX_LIGHTS * Q3_METAL_MAX_SCENES];
static uint32_t s_frameLightCount;

/* Scene polys — shadow blobs, bullet marks, blood splats, particle
 * sprays. Submitted by cgame via RE_AddPolyToScene as world-space
 * triangle fans (typically 3-4 verts). We copy into a pool and emit
 * as entity draws at RenderScene time alongside sprites + bolts. */
#define Q3_METAL_MAX_SCENE_POLYS 256
#define Q3_METAL_MAX_SCENE_POLY_VERTS 4096

typedef struct {
    qhandle_t shader;
    int firstVert;
    int numVerts;
} metalScenePoly_t;

static metalScenePoly_t s_scenePolys[Q3_METAL_MAX_SCENE_POLYS];
static polyVert_t s_scenePolyVerts[Q3_METAL_MAX_SCENE_POLY_VERTS];
static int s_scenePolyCount;
static int s_scenePolyVertCount;

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
    /* rgbGen const: fixed RGB tint in [0,1]. Only meaningful when
     * rgbGen == 4 (CGEN_CONST equivalent). Populated from the
     * `rgbGen const ( r g b )` directive. */
    float rgbConstColor[3];
    /* alphaGen const <v>: fixed alpha in [0,1]. Default 1.0. Only
     * meaningful when alphaGen == 4. */
    float alphaConst;
    int useLightmap;
    /* Stamped at shader-map register time from the shader-level
     * METAL_SHADER_CULL_* value. Q3 'cull' is shader-wide so every
     * stage copies from the same source, but propagating it here
     * makes AddWorldDrawStage's single pointer carry all the data
     * Swift needs to pick a pipeline cull state. */
    int cullMode;
} Q3MetalStage;

enum {
    METAL_SHADER_CULL_BACK = 0,
    METAL_SHADER_CULL_DISABLE = 1,
    METAL_SHADER_CULL_FRONT = 2
};

typedef struct {
    char shaderName[128];
    char mapPath[MAX_QPATH];
    /* tcGenEnv is a shader-level flag kept for a STEP 5 follow-up that
     * will move it onto individual stages. Do not read it for new code;
     * prefer stages[i].tcGen. */
    qboolean tcGenEnv;
    int animFrameCount;
    float animFps;
    char animFrames[METAL_ANIMMAP_MAX_FRAMES][MAX_QPATH];
    qhandle_t animTextures[METAL_ANIMMAP_MAX_FRAMES];
    char skyBoxBase[MAX_QPATH];
    qhandle_t skyFaceTextures[6];
    int cullMode;
    qboolean isPortal;
    /* Fog volume parameters, extracted from 'fogparms ( r g b ) distance'.
     * hasFog=qtrue means this shader marks a fog volume; color + distance
     * define how much fog accumulates at the far plane. Not yet consumed
     * by the renderer — stored so per-surface fog assignment + a fog
     * pass can be added later without another parser commit. */
    qboolean hasFog;
    float fogColor[3];
    float fogDistance;
    /* Surface should emit a Q3 flare billboard at its centroid. Set when
     * the shader script carries a 'flareShader <tex>' directive. The
     * texture name is ignored — we use the canonical gfx/misc/flare
     * globally, matching how Q3 ships flares visually. */
    qboolean hasFlare;
    /* Shader declares itself as a sky via `surfaceparm sky` or `skyparms`.
     * Name-prefix matching (textures/skies/, env/) only catches stock
     * naming conventions; custom maps like nv15 use arbitrary paths but
     * still tag the shader. Consulting this flag at surface classification
     * time makes sky detection prefix-independent. */
    qboolean isSky;
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

/* Forward declaration — the shader-map lookup lives further down the
 * file. IsSkyShaderName is called during BSP load, well after
 * LoadAllShaders has populated the map, so the lookup always resolves. */
static const metalShaderMap_t *ShaderMap_LookupEntry(const char *name);

static qboolean IsSkyShaderName(const char *name) {
    const metalShaderMap_t *entry;

    if (name == NULL || name[0] == '\0') {
        return qfalse;
    }

    if (!Q_stricmpn(name, "textures/skies/", 15)) {
        return qtrue;
    }
    if (!Q_stricmpn(name, "env/", 4)) {
        return qtrue;
    }

    /* Prefix heuristics miss maps that declare sky via shader directives
     * at arbitrary paths (nv15 uses textures/nvidia/..., community maps
     * use textures/outside/..., etc.). Consult the parsed shader-map
     * entry's isSky flag as a fallback — set from 'surfaceparm sky'
     * or 'skyparms' in the shader script. */
    entry = ShaderMap_LookupEntry(name);
    if (entry != NULL && entry->isSky) {
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
                           uint32_t flags,
                           uint32_t fogIndex) {
    draw->firstIndex = firstIndex;
    draw->indexCount = indexCount;
    draw->lightmapTextureHandle = (uint32_t)lightmapTextureHandle;
    draw->flags = flags;
    draw->stageCount = 0;
    draw->fogIndex = fogIndex;
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
    /* STEP 6: propagate shader cullMode. Values match
     * METAL_SHADER_CULL_BACK=0 / DISABLE=1 / FRONT=2; Swift consumes
     * this directly when picking setCullMode per draw. */
    stage->cullMode = (uint32_t)src->cullMode;
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

/* Heuristic: should alpha be synthesized when a JPG fallback is loaded
 * for this texture? Stock Q3's FX sprites (plasma bolts, explosions,
 * blood splats, flares) ship as .tga with alpha; when the .tga is
 * missing we fall through to a .jpg that has no alpha channel. Without
 * alpha the full billboard quad draws opaque, producing hard-edged
 * orbs/rectangles instead of just the bright center. Synthesize alpha
 * from luminance for paths known to be FX-only. */
static qboolean TextureNeedsLuminanceAlpha(const char *path) {
    /* Synthesize alpha for textures whose .tga was authored with a
     * DARK (near-black) background + bright emissive core. Max(R,G,B)
     * cleanly recovers the alpha mask: black/dark borders become
     * alpha=0, bright cores keep alpha~255. Required because:
     *
     *   1. When .tga is missing and we fall back to .jpg, there is no
     *      alpha channel — RGB gets padded with alpha=255 everywhere,
     *      producing hard-edged opaque quads under alpha-blend shaders
     *      (the classic "yellow rectangle around the explosion").
     *   2. Additive shaders don't technically need alpha, but the dark
     *      borders still contribute non-zero color through JPEG
     *      compression artifacts. Synthesizing alpha from luminance
     *      doubles as a safe per-pixel RGB mask: we zero out RGB
     *      alongside alpha when alpha would be ~0.
     *
     * Allow-list these FX prefixes (Q3 texture convention: FX/UI/HUD
     * all use dark-bg TGAs). The pattern intentionally excludes
     * world-surface textures like textures/ and env/ where a JPG
     * without alpha is the right outcome. */
    if (path == NULL || path[0] == '\0') return qfalse;
    if (!Q_stricmpn(path, "sprites/", 8)) return qtrue;
    if (!Q_stricmpn(path, "models/weaphits/", 16)) return qtrue;
    if (!Q_stricmpn(path, "gfx/damage/", 11)) return qtrue;
    if (!Q_stricmpn(path, "gfx/misc/", 9)) return qtrue;
    if (!Q_stricmpn(path, "gfx/2d/", 7)) return qtrue;
    if (!Q_stricmpn(path, "powerups/", 9)) return qtrue;
    if (!Q_stricmpn(path, "menu/art/", 9)) return qtrue;
    return qfalse;
}

static void SynthesizeAlphaFromLuminance(byte *rgba, int width, int height) {
    /* Reconstruct an alpha mask for textures whose .tga (with proper
     * alpha) is missing and we fell back to .jpg (which has no alpha
     * channel — R_LoadJPG fills it 255). Without alpha, the entire
     * billboard quad draws opaque (the classic "yellow rectangle
     * around the rocket explosion").
     *
     * Q3 FX textures fall into two patterns and we have to handle both
     * without knowing which one we have:
     *
     *   A. Emissive core on near-black background (plasma bolt sprites,
     *      rail beam, lightning bolt). max(R,G,B) cleanly recovers the
     *      original mask.
     *   B. Uniform bright fireball / smoke puff that *fills* the
     *      texture (rocketExplosion, plasmaExplosion, smokePuff). The
     *      original .tga used a circular alpha mask to fade to corners
     *      — luminance alone produces alpha=255 everywhere → a yellow
     *      square. Apply a radial soft-mask centered on the texture so
     *      corners fade out regardless of source content.
     *
     * Both factors are multiplied together. Pattern A is unaffected
     * (the radial fade is gentle in the central area). Pattern B gets
     * the round shape it needs.
     *
     * Also: clamp very low luminance to alpha=0 + zero RGB so JPG
     * compression noise can't contribute under additive blending. */
    const int count = width * height;
    const int alphaFloor = 24;       /* ~9% of 255; below this → masked */
    const float halfW = width  * 0.5f;
    const float halfH = height * 0.5f;
    const float invHalfW = 1.0f / (halfW > 0.0f ? halfW : 1.0f);
    const float invHalfH = 1.0f / (halfH > 0.0f ? halfH : 1.0f);
    int i;
    for (i = 0; i < count; ++i) {
        int r = rgba[i * 4 + 0];
        int g = rgba[i * 4 + 1];
        int b = rgba[i * 4 + 2];
        int lum = r > g ? r : g;
        if (b > lum) lum = b;

        /* Radial soft mask: 1.0 at center, 0.0 at corners (r2>=1). */
        int x = i % width;
        int y = i / width;
        float dx = ((float)x + 0.5f - halfW) * invHalfW;
        float dy = ((float)y + 0.5f - halfH) * invHalfH;
        float r2 = dx * dx + dy * dy;
        float radial = 1.0f - r2;
        if (radial < 0.0f) radial = 0.0f;
        if (radial > 1.0f) radial = 1.0f;
        /* Smoothstep-ish — softer falloff than linear. */
        radial = radial * radial * (3.0f - 2.0f * radial);

        int a = (int)(lum * radial + 0.5f);
        if (a < alphaFloor) {
            rgba[i * 4 + 0] = 0;
            rgba[i * 4 + 1] = 0;
            rgba[i * 4 + 2] = 0;
            rgba[i * 4 + 3] = 0;
        } else {
            rgba[i * 4 + 3] = (byte)a;
        }
    }
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
        qboolean isJpg = Q_stricmp(extensions[i], ".tga") != 0;
        Com_sprintf(candidate, sizeof(candidate), "%s%s", base, extensions[i]);
        if (!isJpg) {
            R_LoadTGA(candidate, rgba, width, height);
        } else {
            R_LoadJPG(candidate, rgba, width, height);
        }

        if (*rgba != NULL && *width > 0 && *height > 0) {
            /* JPG has no alpha — R_LoadJPG fills it with 255. For FX
             * paths that expected the .tga's alpha mask, synthesize
             * one from the RGB luminance so the bright core draws and
             * the dark background is masked out. */
            if (isJpg && TextureNeedsLuminanceAlpha(name)) {
                SynthesizeAlphaFromLuminance(*rgba, *width, *height);
            }
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
static int ShaderMap_GetBlendMode(const char *name);
static int ShaderMap_GetAlphaFunc(const char *name);
static int ShaderMap_GetTcGenEnv(const char *name);
static int ShaderMap_GetRgbGen(const char *name);
static int ShaderMap_GetAlphaGen(const char *name);
static void ShaderMap_GetRgbWave(const char *name, int *func, float *base, float *amp, float *phase, float *freq);
static void ShaderMap_GetAlphaWave(const char *name, int *func, float *base, float *amp, float *phase, float *freq);
static void ShaderMap_GetRgbConst(const char *name, float outRgb[3]);
static float ShaderMap_GetAlphaConst(const char *name);
static void ShaderMap_GetTcMods(const char *name, int *outCount, Q3TcMod *outMods);
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
    /* Q3 internal sentinel shaders use '$whiteimage' / '*white' /
     * '*whiteimage' / '*default' as their stage map. The engine was
     * expected to return the built-in 1x1 white texture; our filesystem
     * loader otherwise burns cycles trying to find a file that never
     * existed and falls through to the warn + white-cache path. Short-
     * circuit here so direct Q3 calls (RegisterShader("$whiteimage"))
     * and texture lookups routed through here both resolve instantly. */
    if (!Q_stricmp(name, "$whiteimage") ||
        !Q_stricmp(name, "*white") ||
        !Q_stricmp(name, "*whiteimage") ||
        !Q_stricmp(name, "*default")) {
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
            /* If any stage's mapPath is a sentinel ($whiteimage / *white /
             * *whiteimage / *default) the shader's intent is "render a
             * stage of 1x1 white, alpha/rgbGen-driven". Return the built-
             * in white handle directly instead of walking the stages and
             * failing to load from disk. Caches the miss-free path for
             * sprite effects like viewBloodBlend, smokePuff, tracers, etc. */
            int ws;
            qboolean wantsWhite = qfalse;
            const char *mp = entry->mapPath;
            if (mp[0] == '$' || mp[0] == '*') {
                if (!Q_stricmp(mp, "$whiteimage") || !Q_stricmp(mp, "*white") ||
                    !Q_stricmp(mp, "*whiteimage") || !Q_stricmp(mp, "*default")) {
                    wantsWhite = qtrue;
                }
            }
            for (ws = 0; !wantsWhite && ws < entry->stageCount; ++ws) {
                const char *sp = entry->stages[ws].mapPath;
                if (sp[0] != '$' && sp[0] != '*') continue;
                if (!Q_stricmp(sp, "$whiteimage") || !Q_stricmp(sp, "*white") ||
                    !Q_stricmp(sp, "*whiteimage") || !Q_stricmp(sp, "*default")) {
                    wantsWhite = qtrue;
                }
            }
            if (wantsWhite) {
                if (diag) ri.Printf(PRINT_ALL, "[TEX-DBG]   entry uses $whiteimage sentinel → white\n");
                return EnsureWhiteTexture();
            }
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
        /* Missing player icon (e.g. a bot in bots.txt whose model was
         * never shipped — 'james' is the stock example). Before giving
         * up, try the same file under models/players/sarge/, which is
         * always present. Scoped by path so we don't accidentally route
         * unrelated missing textures to sarge. */
        if (!resolved) {
            const char *sub = strstr(name, "models/players/");
            const char *tail = strstr(name, "/icon_default");
            if (sub != NULL && tail != NULL && tail > sub) {
                char fallback[MAX_QPATH];
                Q_strncpyz(fallback, "models/players/sarge/icon_default.tga", sizeof(fallback));
                if (TryLoadImageRGBA(fallback, &rgba, &width, &height, resolvedName, sizeof(resolvedName))) {
                    resolved = qtrue;
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
    texture->tcGenEnv = ShaderMap_GetTcGenEnv(name);
    texture->rgbGen = ShaderMap_GetRgbGen(name);
    texture->alphaGen = ShaderMap_GetAlphaGen(name);
    ShaderMap_GetRgbWave(name, &texture->rgbWaveFunc,
                         &texture->rgbWaveBase, &texture->rgbWaveAmp,
                         &texture->rgbWavePhase, &texture->rgbWaveFreq);
    ShaderMap_GetAlphaWave(name, &texture->alphaWaveFunc,
                           &texture->alphaWaveBase, &texture->alphaWaveAmp,
                           &texture->alphaWavePhase, &texture->alphaWaveFreq);
    ShaderMap_GetRgbConst(name, texture->rgbConstColor);
    texture->alphaConst = ShaderMap_GetAlphaConst(name);
    ShaderMap_GetTcMods(name, &texture->tcModCount, texture->tcMods);
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
    /* Preserve generation across the reset so Swift's cachedWorldGeneration
     * check invalidates on every map change. Without this, Com_Memset resets
     * generation to 0 and the subsequent LoadWorldMapData bump lands on 1
     * for every map — Swift then keeps the previous map's MTLBuffer and the
     * new map's draw commands index into stale geometry. */
    uint32_t savedGeneration = s_world.generation;
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
    s_worldFogCount = 0;
    s_worldFlareCount = 0;
    s_flareTextureHandle = 0;
    Com_Memset(s_worldFlares, 0, sizeof(s_worldFlares));
    Com_Memset(s_worldFogs, 0, sizeof(s_worldFogs));
    Com_Memset(s_worldFogsPublic, 0, sizeof(s_worldFogsPublic));
    Com_Memset(&s_world, 0, sizeof(s_world));
    s_world.generation = savedGeneration;
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
    /* Multi-scene: the pool grows across scenes within a frame, so
     * realloc must preserve existing data. vertexCount/indexCount/drawCount
     * here are CUMULATIVE counts the caller wants to be able to address. */
    if (vertexCount > s_entityVertexCapacity) {
        Q3MetalEntityVertex *newVertices = ri.Malloc(vertexCount * sizeof(*newVertices));
        if (newVertices == NULL) {
            return qfalse;
        }
        /* Zero-init so non-MD3 emit paths (sprites, beams, flares,
         * synthetic overlays) leave normal[] at 0 — the fragment then
         * falls back to the dfdx/dfdy flat face normal. */
        Com_Memset(newVertices, 0, vertexCount * sizeof(*newVertices));
        if (s_entityVertices != NULL) {
            Com_Memcpy(newVertices, s_entityVertices,
                       s_entityVertexCapacity * sizeof(*newVertices));
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
            Com_Memcpy(newIndices, s_entityIndices,
                       s_entityIndexCapacity * sizeof(*newIndices));
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
            Com_Memcpy(newDraws, s_entityDraws,
                       s_entityDrawCapacity * sizeof(*newDraws));
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

    /* Mirror ioquake3's R_ColorShiftLightingBytes: Q3 lightmaps are
     * authored at half brightness (raw bytes mostly 0..127) expecting
     * the renderer to upscale by 2^(r_mapOverBrightBits - r_overBright-
     * Bits) at load time. With the stock cvars (mapOverBright=2,
     * overBright=1) that's a single left-shift per channel. Without
     * this, sampled lightmap values stay in the ~0.25-0.5 range and
     * the world renders ~60% too dark even with the shader-side
     * saturate(lightmap * 2) multiply.
     *
     * r_mapOverBrightBits is an archived cvar (default 2); r_over-
     * BrightBits defaults to 1. We read them via Cvar_VariableIntegerValue
     * so the cvar-block overrides in ios_main.m flow through naturally. */
    {
        int mapOverbright = ri.Cvar_VariableIntegerValue("r_mapOverBrightBits");
        int frameOverbright = ri.Cvar_VariableIntegerValue("r_overBrightBits");
        int shift = mapOverbright - frameOverbright;
        if (shift < 0) shift = 0; /* we never downshift — behaviour matches stock path 122-138 */
        for (i = 0; i < lightmapCount; ++i) {
            byte *rgba = ri.Malloc(LIGHTMAP_WIDTH * LIGHTMAP_HEIGHT * 4);
            const byte *source = lightmapBytes + i * LIGHTMAP_WIDTH * LIGHTMAP_HEIGHT * 3;
            int pixel;
            char lightmapName[MAX_QPATH];

            if (rgba == NULL) {
                break;
            }

            for (pixel = 0; pixel < LIGHTMAP_WIDTH * LIGHTMAP_HEIGHT; ++pixel) {
                int r = source[pixel * 3 + 0] << shift;
                int g = source[pixel * 3 + 1] << shift;
                int b = source[pixel * 3 + 2] << shift;
                /* Normalize by color instead of clamping to white so
                 * we preserve color balance on lit surfaces (same as
                 * R_ColorShiftLightingBytes lines 127-133). */
                int maxc = r > g ? r : g;
                if (b > maxc) maxc = b;
                if (maxc > 255) {
                    r = r * 255 / maxc;
                    g = g * 255 / maxc;
                    b = b * 255 / maxc;
                }
                rgba[pixel * 4 + 0] = (byte)r;
                rgba[pixel * 4 + 1] = (byte)g;
                rgba[pixel * 4 + 2] = (byte)b;
                rgba[pixel * 4 + 3] = 255;
            }

            Com_sprintf(lightmapName, sizeof(lightmapName), "*lightmap:%s:%d", mapName, i);
            s_worldLightmapHandles[i] = RegisterRawTexture(lightmapName, rgba, LIGHTMAP_WIDTH, LIGHTMAP_HEIGHT);
        }
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
    /* Suppress warnings for known-optional model references that the
     * stock Q3 engine silently ignores:
     *   - '*N' sentinels (cgame registers '*1','*2',… as placeholder
     *     model handles; they're not filesystem paths).
     *   - weapons2/<weapon>/<weapon>_barrel.md3 — the barrel MD3 is a
     *     TAG-attached sub-part that only exists for gauntlet,
     *     machinegun, bfg. Other weapons simply don't have one.
     *   - players/james, players/characters/james — bot roster entry
     *     whose model was never shipped in any pak (see cycle 1).
     * Returning 0 here keeps the caller's lookup correct; we just
     * don't spam the log. Any OTHER missing model still prints, so
     * real loading bugs stay visible. */
    {
        const char *barrel = strstr(name, "_barrel.md3");
        const char *weap2 = strstr(name, "models/weapons2/");
        qboolean silent = qfalse;
        if (name[0] == '*') silent = qtrue;
        else if (barrel != NULL && weap2 != NULL && weap2 < barrel) silent = qtrue;
        else if (strstr(name, "players/james/") != NULL) silent = qtrue;
        else if (strstr(name, "players/characters/james/") != NULL) silent = qtrue;
        if (!silent) {
            ri.Printf(PRINT_WARNING, "Metal model: failed to load '%s'\n", name);
        }
    }
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

    /* STEP 9: start from zero. The previous default of NOCULL forced
     * every world surface two-sided regardless of its shader's cull
     * directive — a leftover from before per-stage culling (STEP 6)
     * worked. Individual draws still OR in the appropriate flags
     * (LIGHTMAP_MULTIPLY, SKY, PORTAL, etc) as they're assembled. */
    static const uint32_t defaultWorldFlags = 0;

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

    /* LUMP_FOGS — one dfog_t per fog volume. Resolve each fog's shader
     * into the pre-parsed shader map to recover (r,g,b,distance) from
     * the 'fogparms' directive. Later cycles thread each surface's
     * fogNum (index into this table) into Q3MetalWorldDrawCmd so the
     * Metal fragment shader can apply fog per-surface. */
    {
        const dfog_t *fogs = (const dfog_t *)((const byte *)header +
            LittleLong(header->lumps[LUMP_FOGS].fileofs));
        int fogBytes = LittleLong(header->lumps[LUMP_FOGS].filelen);
        int fogCount = (fogBytes > 0) ? (fogBytes / (int)sizeof(dfog_t)) : 0;
        int fi;
        int withColor = 0;

        if (fogCount > METAL_MAX_WORLD_FOGS) fogCount = METAL_MAX_WORLD_FOGS;
        s_worldFogCount = fogCount;
        for (fi = 0; fi < fogCount; ++fi) {
            const metalShaderMap_t *fse;
            Q_strncpyz(s_worldFogs[fi].shaderName, fogs[fi].shader,
                       sizeof(s_worldFogs[fi].shaderName));
            s_worldFogs[fi].hasColor = qfalse;
            s_worldFogs[fi].color[0] = 0.0f;
            s_worldFogs[fi].color[1] = 0.0f;
            s_worldFogs[fi].color[2] = 0.0f;
            s_worldFogs[fi].distance = 0.0f;

            fse = ShaderMap_LookupEntry(fogs[fi].shader);
            if (fse != NULL && fse->hasFog) {
                s_worldFogs[fi].hasColor = qtrue;
                s_worldFogs[fi].color[0] = fse->fogColor[0];
                s_worldFogs[fi].color[1] = fse->fogColor[1];
                s_worldFogs[fi].color[2] = fse->fogColor[2];
                s_worldFogs[fi].distance = fse->fogDistance;
                s_worldFogsPublic[fi].color[0] = fse->fogColor[0];
                s_worldFogsPublic[fi].color[1] = fse->fogColor[1];
                s_worldFogsPublic[fi].color[2] = fse->fogColor[2];
                s_worldFogsPublic[fi].distance = fse->fogDistance;
                withColor += 1;
            }
            /* Unresolved volumes leave s_worldFogsPublic[fi] at the
             * zero-init state (distance==0), which the MSL fog branch
             * reads as "no fog". */
        }
        if (fogCount > 0) {
            ri.Printf(PRINT_ALL,
                "Metal world: %d fog volumes (%d with resolved fogparms)\n",
                fogCount, withColor);
        }
    }

    for (i = 0; i < surfaceCount; ++i) {
        const dsurface_t *surface = &surfaces[i];
        int surfaceType = LittleLong(surface->surfaceType);
        int patchWidth;
        int patchHeight;
        int shaderNum;

        /* MST_FLARE surfaces carry no triangles — they're pure light
         * points. Harvest origin/color into s_worldFlares and continue;
         * IsSupportedWorldSurface below would otherwise reject them. */
        if (surfaceType == MST_FLARE) {
            if (s_worldFlareCount < Q3_METAL_MAX_FLARES) {
                Q3MetalFlare *fl = &s_worldFlares[s_worldFlareCount++];
                fl->origin[0] = LittleFloat(surface->lightmapOrigin[0]);
                fl->origin[1] = LittleFloat(surface->lightmapOrigin[1]);
                fl->origin[2] = LittleFloat(surface->lightmapOrigin[2]);
                fl->color[0] = LittleFloat(surface->lightmapVecs[0][0]);
                fl->color[1] = LittleFloat(surface->lightmapVecs[0][1]);
                fl->color[2] = LittleFloat(surface->lightmapVecs[0][2]);
            }
            continue;
        }

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
        uint32_t fogIndex;
        int surfFogNum;
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
        /* Pull the fog volume the BSP assigned to this surface. -1 or
         * out-of-range values map to Q3_METAL_NO_FOG so the Swift/MSL
         * side can branch cheaply without an extra bool. */
        surfFogNum = LittleLong(surface->fogNum);
        if (surfFogNum < 0 || surfFogNum >= s_worldFogCount ||
            !s_worldFogs[surfFogNum].hasColor) {
            fogIndex = Q3_METAL_NO_FOG;
        } else {
            fogIndex = (uint32_t)surfFogNum;
        }
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
        /* STEP 7: propagate portal flag into the draw command so renderer
         * consumers don't have to re-infer it per frame. The parser has
         * already captured 'portal' on entry->isPortal. */
        {
            const metalShaderMap_t *_pe = ShaderMap_LookupEntry(shaders[shaderNum].shader);
            if (_pe != NULL && _pe->isPortal) {
                worldFlags |= Q3_METAL_WORLD_DRAWFLAG_PORTAL;
            }
            /* flareShader directive: emit a flare billboard at the surface
             * centroid. Skip patches (MST_PATCH) — their vertex layout
             * isn't the flat strip we'd average naively. Planar + trisoup
             * surfaces cover the stock case (lamp brushes, glow panels). */
            if (_pe != NULL && _pe->hasFlare && surfaceType != MST_PATCH &&
                s_worldFlareCount < Q3_METAL_MAX_FLARES) {
                float cx = 0.0f, cy = 0.0f, cz = 0.0f;
                int sampleCount = numVerts < 8 ? numVerts : 8;
                int si;
                for (si = 0; si < sampleCount; ++si) {
                    const drawVert_t *dv = &drawVerts[firstVert + si];
                    cx += dv->xyz[0];
                    cy += dv->xyz[1];
                    cz += dv->xyz[2];
                }
                if (sampleCount > 0) {
                    Q3MetalFlare *fl = &s_worldFlares[s_worldFlareCount++];
                    fl->origin[0] = cx / (float)sampleCount;
                    fl->origin[1] = cy / (float)sampleCount;
                    fl->origin[2] = cz / (float)sampleCount;
                    fl->color[0] = 1.0f;
                    fl->color[1] = 1.0f;
                    fl->color[2] = 1.0f;
                }
            }
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
                                       worldFlags,
                                       fogIndex);
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
                           worldFlags,
                           fogIndex);
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

    /* Resolve the flare billboard texture once per map. The canonical Q3
     * shader is 'flareShader' mapped to gfx/misc/flare. If the texture is
     * missing we fall back to white — Swift will skip flare rendering when
     * the handle is 0. */
    if (s_worldFlareCount > 0) {
        s_flareTextureHandle = (uint32_t)RegisterTexture("gfx/misc/flare");
    }

    ri.Printf(PRINT_ALL,
              "Metal world: loaded '%s' with %u verts, %u indices, %u draws (%u planar, %u patch, %u trisoup, %u sky, %d flares)\n",
              name, s_world.vertexCount, s_world.indexCount, s_world.drawCount,
              planarDraws, patchDraws, triSoupDraws, skyDraws, s_worldFlareCount);
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
    /* Read stage[0].blendMode as the shader's primary blend. The old
     * shader-level entry->blendMode field was a cached copy of the
     * same value; STEP 4 removed that cache so stages[] is the single
     * source of truth. */
    entry = ShaderMap_LookupEntry(name);
    if (entry == NULL || entry->stageCount <= 0) return 0;
    return entry->stages[0].blendMode;
}

/* blendMode enum used throughout the stub and the Q3MetalWorldStage:
 *   0 = opaque     (no blend)
 *   1 = additive   (GL_ONE/GL_ONE, GL_SRC_ALPHA/GL_ONE)
 *   2 = alpha      (GL_SRC_ALPHA/GL_ONE_MINUS_SRC_ALPHA)
 *   3 = filter     (GL_DST_COLOR/GL_ZERO and commutative form GL_ZERO/GL_SRC_COLOR)
 *   4 = subtract   (GL_ZERO/GL_ONE_MINUS_SRC_COLOR — blood/bullet/shadow decals)
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
    /* Subtractive darkening for decals (blood marks, bullet marks,
     * burn marks, markShadow). out = dst * (1 - src). */
    if (!Q_stricmp(src, "GL_ZERO") && !Q_stricmp(dst, "GL_ONE_MINUS_SRC_COLOR")) return 4;
    /* Opaque explicit (no-op blend). */
    if (!Q_stricmp(src, "GL_ONE") && !Q_stricmp(dst, "GL_ZERO")) return 0;
    /* Skip stage — GL_ZERO/GL_ZERO writes black. We render opaque-black
     * rather than dropping so the stage still consumes its slot; if a
     * shader relies on this being a no-op, promote to a dedicated drop
     * path later. */
    if (!Q_stricmp(src, "GL_ZERO") && !Q_stricmp(dst, "GL_ZERO")) return 0;

    /* Less-common combos caught by the STEP 3 warn path. These don't
     * map cleanly to our 4-mode pipeline (opaque/add/alpha/filter);
     * pick the closest semantic approximation. */

    /* src.a * src + src.a * dst = src.a * (src + dst). Alpha-scaled
     * sum — closest to alpha-blend in feel. */
    if (!Q_stricmp(src, "GL_SRC_ALPHA") && !Q_stricmp(dst, "GL_SRC_ALPHA")) return 2;
    /* (1-src.a) * (src + dst). Inverse-alpha fade — alpha-blend. */
    if (!Q_stricmp(src, "GL_ONE_MINUS_SRC_ALPHA") && !Q_stricmp(dst, "GL_ONE_MINUS_SRC_ALPHA")) return 2;
    /* (1-dst.a) * (src + dst). Used for "fade by destination alpha"
     * overlays; alpha-blend is the closest match. */
    if (!Q_stricmp(src, "GL_ONE_MINUS_DST_ALPHA") && !Q_stricmp(dst, "GL_ONE_MINUS_DST_ALPHA")) return 2;
    /* src * (src + dst). Color modulates itself onto the frame —
     * behaves like a filter/modulate pass (result is darker). */
    if (!Q_stricmp(src, "GL_SRC_COLOR") && !Q_stricmp(dst, "GL_SRC_COLOR")) return 3;
    /* (1-src) * (src + dst). Inverse-color filter, still modulative. */
    if (!Q_stricmp(src, "GL_ONE_MINUS_SRC_COLOR") && !Q_stricmp(dst, "GL_ONE_MINUS_SRC_COLOR")) return 3;

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
    if (entry == NULL || entry->stageCount <= 0) return 0;
    return entry->stages[0].alphaFunc;
}

static int ShaderMap_GetTcGenEnv(const char *name) {
    const metalShaderMap_t *entry;
    if (name == NULL || name[0] == '\0') return 0;
    entry = ShaderMap_LookupEntry(name);
    return (entry && entry->tcGenEnv) ? 1 : 0;
}

/* Stage 0 rgbGen for a shader name. Entity pipeline uses this so
 * chrome shells (rgbGen identity) bypass the per-vertex Lambert
 * color that would otherwise dim their full-bright reflection. */
static int ShaderMap_GetRgbGen(const char *name) {
    const metalShaderMap_t *entry;
    if (name == NULL || name[0] == '\0') return 0;
    entry = ShaderMap_LookupEntry(name);
    if (entry == NULL || entry->stageCount <= 0) return 0;
    return entry->stages[0].rgbGen;
}

/* Stage 0 alphaGen. Entity fragment honors identity by forcing alpha
 * to 1.0 regardless of per-vertex alpha, matching upstream
 * AGEN_IDENTITY semantics. */
static int ShaderMap_GetAlphaGen(const char *name) {
    const metalShaderMap_t *entry;
    if (name == NULL || name[0] == '\0') return 0;
    entry = ShaderMap_LookupEntry(name);
    if (entry == NULL || entry->stageCount <= 0) return 0;
    return entry->stages[0].alphaGen;
}

/* Copy stage 0's rgbGen wave parameters (base, amp, phase, freq) so
 * the entity fragment can evaluate the glow wave per frame when its
 * stage uses rgbGen wave. Zeroed when the shader doesn't specify a
 * wave. */
static void ShaderMap_GetRgbWave(const char *name, int *func, float *base, float *amp,
                                 float *phase, float *freq) {
    const metalShaderMap_t *entry;
    if (func) *func = 1; /* default to sin */
    if (base) *base = 0.0f;
    if (amp) *amp = 0.0f;
    if (phase) *phase = 0.0f;
    if (freq) *freq = 0.0f;
    if (name == NULL || name[0] == '\0') return;
    entry = ShaderMap_LookupEntry(name);
    if (entry == NULL || entry->stageCount <= 0) return;
    if (func)  *func  = entry->stages[0].rgbWaveFunc;
    if (base)  *base  = entry->stages[0].rgbWaveBase;
    if (amp)   *amp   = entry->stages[0].rgbWaveAmp;
    if (phase) *phase = entry->stages[0].rgbWavePhase;
    if (freq)  *freq  = entry->stages[0].rgbWaveFreq;
}

static void ShaderMap_GetAlphaWave(const char *name, int *func, float *base, float *amp,
                                   float *phase, float *freq) {
    const metalShaderMap_t *entry;
    if (func) *func = 1;
    if (base) *base = 0.0f;
    if (amp) *amp = 0.0f;
    if (phase) *phase = 0.0f;
    if (freq) *freq = 0.0f;
    if (name == NULL || name[0] == '\0') return;
    entry = ShaderMap_LookupEntry(name);
    if (entry == NULL || entry->stageCount <= 0) return;
    if (func)  *func  = entry->stages[0].alphaWaveFunc;
    if (base)  *base  = entry->stages[0].alphaWaveBase;
    if (amp)   *amp   = entry->stages[0].alphaWaveAmp;
    if (phase) *phase = entry->stages[0].alphaWavePhase;
    if (freq)  *freq  = entry->stages[0].alphaWaveFreq;
}

/* Copy stage 0's rgbGen const tint. Zeroed when shader doesn't use
 * `rgbGen const` — the entity fragment multiplies texel by this
 * value only when rgbGenMode == 4. */
static void ShaderMap_GetRgbConst(const char *name, float outRgb[3]) {
    const metalShaderMap_t *entry;
    outRgb[0] = outRgb[1] = outRgb[2] = 1.0f;
    if (name == NULL || name[0] == '\0') return;
    entry = ShaderMap_LookupEntry(name);
    if (entry == NULL || entry->stageCount <= 0) return;
    outRgb[0] = entry->stages[0].rgbConstColor[0];
    outRgb[1] = entry->stages[0].rgbConstColor[1];
    outRgb[2] = entry->stages[0].rgbConstColor[2];
}

static float ShaderMap_GetAlphaConst(const char *name) {
    const metalShaderMap_t *entry;
    if (name == NULL || name[0] == '\0') return 1.0f;
    entry = ShaderMap_LookupEntry(name);
    if (entry == NULL || entry->stageCount <= 0) return 1.0f;
    return entry->stages[0].alphaConst;
}

/* Stage 0's tcMod chain for a shader name. Entity pipeline consumes
 * this through metalTexture_t so the fragment can run scroll/rotate
 * after tcGen env. Returns count=0 when the shader has no tcMods or
 * the name fails to resolve. */
static void ShaderMap_GetTcMods(const char *name, int *outCount, Q3TcMod *outMods) {
    const metalShaderMap_t *entry;
    int i;
    if (outCount) *outCount = 0;
    if (name == NULL || name[0] == '\0' || outMods == NULL || outCount == NULL) return;
    for (i = 0; i < Q3_MAX_TCMODS; ++i) {
        outMods[i].type = 0;
        outMods[i].params[0] = 0.0f;
        outMods[i].params[1] = 0.0f;
        outMods[i].params[2] = 0.0f;
        outMods[i].params[3] = 0.0f;
    }
    entry = ShaderMap_LookupEntry(name);
    if (entry == NULL || entry->stageCount <= 0) return;
    *outCount = entry->stages[0].tcModCount;
    if (*outCount > Q3_MAX_TCMODS) *outCount = Q3_MAX_TCMODS;
    for (i = 0; i < *outCount; ++i) {
        outMods[i] = entry->stages[0].tcMods[i];
    }
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
        qboolean gotFog;
        qboolean gotFlare;
        qboolean gotSky;
        float fogColor[3];
        float fogDistance;
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
        gotFog = qfalse;
        gotFlare = qfalse;
        gotSky = qfalse;
        fogColor[0] = fogColor[1] = fogColor[2] = 0.0f;
        fogDistance = 0.0f;
        Com_Memset(&cur, 0, sizeof(cur));
        cur.alphaConst = 1.0f;
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
                    /* alphaConst defaults to 1.0 so a stage that sets
                     * alphaGen const without a numeric argument stays
                     * opaque instead of going fully transparent. */
                    cur.alphaConst = 1.0f;
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
                    gotSky = qtrue;   /* skyparms always implies sky */
                } else if (!Q_stricmp(token, "surfaceparm")) {
                    /* surfaceparm <keyword>. We only care about `sky`
                     * right now — everything else (trans, nolightmap,
                     * nomarks, noimpact, etc.) is ignored but we must
                     * still consume its argument so the parser advances. */
                    token = COM_ParseExt(&p, qfalse);
                    if (token[0] && !Q_stricmp(token, "sky")) {
                        gotSky = qtrue;
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
                } else if (!Q_stricmp(token, "q3map_flare")) {
                    /* Syntax: q3map_flare <shader>. Stock Q3 uses this
                     * as a compile-time hint for the map compiler, which
                     * then emits MST_FLARE BSP surfaces. We also pick it
                     * up here so maps that shipped without baked flares
                     * still render them at runtime. Texture name is
                     * discarded — we use gfx/misc/flare globally. */
                    (void)COM_ParseExt(&p, qfalse);
                    gotFlare = qtrue;
                } else if (!Q_stricmp(token, "fogparms") || !Q_stricmp(token, "fogParms")) {
                    /* Syntax: fogparms ( r g b ) distance
                     * Tokenizes as: '(' r g b ')' distance — seven tokens. */
                    const char *t;
                    t = COM_ParseExt(&p, qfalse);  /* '(' */
                    t = COM_ParseExt(&p, qfalse); if (t[0]) fogColor[0] = (float)atof(t);
                    t = COM_ParseExt(&p, qfalse); if (t[0]) fogColor[1] = (float)atof(t);
                    t = COM_ParseExt(&p, qfalse); if (t[0]) fogColor[2] = (float)atof(t);
                    t = COM_ParseExt(&p, qfalse);  /* ')' */
                    t = COM_ParseExt(&p, qfalse); if (t[0]) fogDistance = (float)atof(t);
                    gotFog = qtrue;
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
                    /* STEP 5: per-stage tcGen. Only the stage that declares
                     * 'tcGen environment' gets the env flag; sibling stages
                     * stay at base UVs. Keeping the legacy shader-level
                     * tcGenEnv in sync so Q3MetalStage's tcGen (consumed by
                     * AddWorldDrawStage → MSL) still reflects the actual
                     * intent during this transition — but readers should
                     * prefer stages[i].tcGen over the shader-level bool. */
                    if (token[0] && (!Q_stricmp(token, "environment") ||
                                     !Q_stricmp(token, "env"))) {
                        cur.tcGen = 1;
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
                    } else if (!Q_stricmp(token, "const")) {
                        /* rgbGen const takes a parenthesized vec3:
                         * '( r g b )' = 5 tokens. Encoded as mode 4 so
                         * the entity fragment multiplies texel.rgb by
                         * the constant tint (CGEN_CONST parity). */
                        const char *openParen = COM_ParseExt(&p, qfalse);
                        const char *rTok = COM_ParseExt(&p, qfalse);
                        const char *gTok = COM_ParseExt(&p, qfalse);
                        const char *bTok = COM_ParseExt(&p, qfalse);
                        (void)COM_ParseExt(&p, qfalse); /* closing paren */
                        (void)openParen;
                        cur.rgbGen = 4;
                        cur.rgbConstColor[0] = (rTok && rTok[0]) ? (float)atof(rTok) : 1.0f;
                        cur.rgbConstColor[1] = (gTok && gTok[0]) ? (float)atof(gTok) : 1.0f;
                        cur.rgbConstColor[2] = (bTok && bTok[0]) ? (float)atof(bTok) : 1.0f;
                    }
                    /* exactVertex / exactvertex / identity / vertex /
                     * lightingDiffuse / oneMinusVertex / oneMinusEntity /
                     * entity / lightingGrid take NO arguments. Consuming
                     * any tokens here desyncs the parser against the
                     * next shader's name — that's the bug that was
                     * stopping sfx.shader at fanfx (line 1117) and
                     * dropping ~230 downstream shaders including
                     * border11c / xmetalfloor_wall_5b / killblock_i4b. */
                } else if (!Q_stricmp(token, "alphaGen") || !Q_stricmp(token, "alphagen")) {
                    token = COM_ParseExt(&p, qfalse);
                    if (!Q_stricmp(token, "vertex")) cur.alphaGen = 1;
                    else if (!Q_stricmp(token, "wave")) cur.alphaGen = 3;
                    else if (!Q_stricmp(token, "const")) cur.alphaGen = 4;
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
                        /* alphaGen const <value>: fixed alpha channel. */
                        const char *vTok = COM_ParseExt(&p, qfalse);
                        cur.alphaConst = (vTok && vTok[0]) ? (float)atof(vTok) : 1.0f;
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
                        /* Syntax: tcmod stretch <func> <base> <amp> <phase> <freq>
                         * Scope is GF_SIN only (the overwhelming common case —
                         * stretch is used for pulse-zoom on powerups). Type=6
                         * is our encoding; params = (base, amp, phase, freq).
                         * Mirrors RB_CalcStretchTexCoords + RB_CalcTransformTexCoords. */
                        const char *funcTok = COM_ParseExt(&p, qfalse);
                        const char *baseTok = COM_ParseExt(&p, qfalse);
                        const char *ampTok  = COM_ParseExt(&p, qfalse);
                        const char *phaseTok = COM_ParseExt(&p, qfalse);
                        const char *freqTok = COM_ParseExt(&p, qfalse);
                        if (funcTok[0] && baseTok[0] && ampTok[0] &&
                            phaseTok[0] && freqTok[0] &&
                            cur.tcModCount < Q3_MAX_TCMODS) {
                            cur.tcMods[cur.tcModCount].type = 6;
                            cur.tcMods[cur.tcModCount].params[0] = (float)atof(baseTok);
                            cur.tcMods[cur.tcModCount].params[1] = (float)atof(ampTok);
                            cur.tcMods[cur.tcModCount].params[2] = (float)atof(phaseTok);
                            cur.tcMods[cur.tcModCount].params[3] = (float)atof(freqTok);
                            cur.tcModCount += 1;
                        }
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
                /* STEP 6: stamp the shader's cullMode onto every stage
                 * so AddWorldDrawStage's single-pointer copy carries
                 * everything Swift needs to choose a cull state. */
                for (s = 0; s < last->stageCount; ++s) {
                    last->stages[s].cullMode = cullMode;
                }
                last->isPortal = gotPortal;
                last->hasFog = gotFog;
                last->hasFlare = gotFlare;
                last->isSky = gotSky;
                if (gotFog) {
                    last->fogColor[0] = fogColor[0];
                    last->fogColor[1] = fogColor[1];
                    last->fogColor[2] = fogColor[2];
                    last->fogDistance = fogDistance;
                }

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
                /* STEP 4: the previous code here cached stages[0].blendMode,
                 * alphaFunc, and a few tcMod params onto the shader-map
                 * entry as globals. All consumers now read stages[0].* via
                 * ShaderMap_GetBlendMode/AlphaFunc — no cache needed. */
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
    /* Don't clobber vidWidth/vidHeight here — Swift's
     * Q3MetalRenderer_UpdateDrawableSize() is the authoritative source
     * (driven by MTKView's current drawable size, which the
     * troubleshooting patch locks to 960x444). Falling back to a sane
     * default ONLY when the drawable hasn't reported a size yet. */
    if (s_glConfig.vidWidth <= 0 || s_glConfig.vidHeight <= 0) {
        s_glConfig.vidWidth = 2796;
        s_glConfig.vidHeight = 1290;
    }
    s_glConfig.windowAspect = (float)s_glConfig.vidWidth / (float)s_glConfig.vidHeight;
    /* Keep cls.captureWidth/captureHeight in sync with our drawable so
     * the AVI video-capture path (cl_avi.c: afd.width = cls.captureWidth)
     * opens files with a non-zero frame size. Without this the header
     * records width=0 and no frames can be appended. */
    if (ri.CL_SetScaling) {
        ri.CL_SetScaling(1.0f, s_glConfig.vidWidth, s_glConfig.vidHeight);
    }
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
    /* Dlights are pushed AFTER ClearScene and consumed at RenderScene time.
     * Resetting here is safe: the world scene repopulates before its
     * RenderScene fires the snapshot write; the HUD scenes don't add
     * lights so an extra reset there is a no-op (snapshot.lightCount is
     * already locked in by the world scene's RenderScene and is only
     * rewritten when rdflags==0, guarding HUD scenes). */
    s_sceneLightCount = 0;
    /* Same reasoning as dlights: polys arrive between ClearScene and
     * RenderScene of the world pass. HUD scenes never AddPoly. */
    s_scenePolyCount = 0;
    s_scenePolyVertCount = 0;
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
    /* RT_LIGHTNING: beam from origin ("from") to oldorigin ("to"). We emit
     * a single view-aligned quad per bolt at RenderScene time (Q3's stock
     * path crosshatches 4 cores at 45°/90°/135° for volume; one core is
     * enough to confirm the path and visibly render a bolt on screen).
     * Follows the same defer-to-RenderScene pattern as RT_SPRITE because
     * the billboard math needs the viewer origin. */
    if (re->reType == RT_LIGHTNING) {
        AuditOnce("ENTITY:RT_LIGHTNING");
        s_sceneEntities[s_sceneEntityCount].entity = *re;
        s_sceneEntities[s_sceneEntityCount].mirrored = qfalse;
        s_sceneEntityCount += 1;
        s_entityAcceptedThisFrame += 1;
        return;
    }
    /* RT_RAIL_CORE: the main rail gun beam — single view-aligned quad
     * between origin and oldorigin. Essentially the same as RT_LIGHTNING
     * but with r_railCoreWidth (Q3 default = 16). */
    if (re->reType == RT_RAIL_CORE) {
        AuditOnce("ENTITY:RT_RAIL_CORE");
        s_sceneEntities[s_sceneEntityCount].entity = *re;
        s_sceneEntities[s_sceneEntityCount].mirrored = qfalse;
        s_sceneEntityCount += 1;
        s_entityAcceptedThisFrame += 1;
        return;
    }
    /* RT_RAIL_RINGS: the spiraling rings around the rail beam. Q3 emits
     * 4 rotated quads per segment; we emit one simplified quad per
     * segment with the ring texture (customShader) for MVP. */
    if (re->reType == RT_RAIL_RINGS) {
        AuditOnce("ENTITY:RT_RAIL_RINGS");
        s_sceneEntities[s_sceneEntityCount].entity = *re;
        s_sceneEntities[s_sceneEntityCount].mirrored = qfalse;
        s_sceneEntityCount += 1;
        s_entityAcceptedThisFrame += 1;
        return;
    }
    /* RT_BEAM: grappling hook chain, CTF mission beams. Stock Q3 renders
     * it as a 6-segment solid-red cylinder; we emit a view-aligned red
     * quad between origin ("from") and oldorigin ("to") for MVP. */
    if (re->reType == RT_BEAM) {
        AuditOnce("ENTITY:RT_BEAM");
        s_sceneEntities[s_sceneEntityCount].entity = *re;
        s_sceneEntities[s_sceneEntityCount].mirrored = qfalse;
        s_sceneEntityCount += 1;
        s_entityAcceptedThisFrame += 1;
        return;
    }
    if (re->reType != RT_MODEL) {
        if (re->reType == RT_PORTALSURFACE) AuditOnce("ENTITY:RT_PORTALSURFACE");
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
    int polyIdx;
    AuditOnce("POLY:RE_AddPolyToScene");
    if (verts == NULL || numVerts < 3) return;
    /* num is the number of polys in this batch, each with numVerts verts.
     * Blood/shadow/marks typically call with num=1. Iterate all regardless. */
    for (polyIdx = 0; polyIdx < num; ++polyIdx) {
        int vi;
        if (s_scenePolyCount >= Q3_METAL_MAX_SCENE_POLYS) return;
        if (s_scenePolyVertCount + numVerts > Q3_METAL_MAX_SCENE_POLY_VERTS) return;
        s_scenePolys[s_scenePolyCount].shader = hShader;
        s_scenePolys[s_scenePolyCount].firstVert = s_scenePolyVertCount;
        s_scenePolys[s_scenePolyCount].numVerts = numVerts;
        for (vi = 0; vi < numVerts; ++vi) {
            s_scenePolyVerts[s_scenePolyVertCount + vi] = verts[polyIdx * numVerts + vi];
        }
        s_scenePolyVertCount += numVerts;
        s_scenePolyCount += 1;
    }
}
static int R_LightForPoint(vec3_t point, vec3_t ambientLight, vec3_t directedLight, vec3_t lightDir) { return 0; }

static void AppendSceneLight(const vec3_t org, float intensity, float r, float g, float b) {
    Q3MetalLight *L;
    if (s_sceneLightCount >= Q3_METAL_MAX_LIGHTS) return;
    L = &s_sceneLights[s_sceneLightCount++];
    L->origin[0] = org[0]; L->origin[1] = org[1]; L->origin[2] = org[2];
    L->radius = intensity;
    L->color[0] = r; L->color[1] = g; L->color[2] = b;
    L->_pad = 0.0f;
}

static void RE_AddLightToScene(const vec3_t org, float intensity, float r, float g, float b) {
    AppendSceneLight(org, intensity, r, g, b);
}

static void RE_AddAdditiveLightToScene(const vec3_t org, float intensity, float r, float g, float b) {
    /* Additive light in stock Q3 modulates the surface by a separate pass.
     * Our fragment adds contributions unconditionally, so additive vs
     * subtractive is already modeled by the color sign. Treat identically. */
    AppendSceneLight(org, intensity, r, g, b);
}

static void RE_AddLinearLightToScene(const vec3_t start, const vec3_t end, float intensity, float r, float g, float b) {
    /* Linear light (lightning beam) → 3 point lights spaced along the line.
     * Keeps the per-light struct uniform and is enough to light the beam's
     * glow along its length without a capsule distance calculation. */
    int i;
    for (i = 0; i < 3; ++i) {
        float t = (float)i * 0.5f;   /* 0.0, 0.5, 1.0 */
        vec3_t p;
        p[0] = start[0] + t * (end[0] - start[0]);
        p[1] = start[1] + t * (end[1] - start[1]);
        p[2] = start[2] + t * (end[2] - start[2]);
        AppendSceneLight(p, intensity, r, g, b);
    }
}

const Q3MetalLight *Q3MetalRenderer_GetLights(void) { return s_frameLights; }
const Q3MetalSceneSnapshot *Q3MetalRenderer_GetSceneSnapshots(void) { return s_sceneSnapshots; }
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

    /* Quad Damage overlay: Q3's cgame CG_AddPlayerWeapon submits the gun
     * twice when ps.powerups[PW_QUAD] is active — once normally, once with
     * customShader=quadWeaponShader. The bundled cgame.qvm's broken
     * syscall ABI drops the second call. Replicate it engine-side so the
     * blue additive quad shell appears on our viewmodel regardless of
     * cgame's accept rate. The quad shader is registered lazily on first
     * use so we don't pay for it on maps where the player never picks
     * up the powerup. */
    if (cl.snap.ps.powerups[PW_QUAD] > cl.snap.ps.commandTime) {
        static qhandle_t s_quadShader = 0;
        if (s_quadShader == 0) {
            s_quadShader = RegisterTexture("powerups/quad");
        }
        if (s_quadShader != 0 && s_sceneEntityCount < Q3_METAL_MAX_REFENTITIES) {
            metalSceneEntity_t *shellSlot = &s_sceneEntities[s_sceneEntityCount];
            refEntity_t *shell;
            *shellSlot = *slot;           /* copy geometry + origin/axis */
            shell = &shellSlot->entity;
            shell->customShader = s_quadShader;
            s_sceneEntityCount += 1;
            s_entityAcceptedThisFrame += 1;
        }
    }
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

    /* Multi-scene: capture this scene's entity command range BEFORE
     * emission, then measure how many commands emission pushed. Pool
     * cursors (s_entityVertexCount etc.) grow monotonically across the
     * frame — RE_BeginFrame resets them. This replaces the previous
     * rdflags==0-gated reset which threw away HUD sub-scene geometry. */
    uint32_t sceneEntityCommandFirst = s_entityDrawCount;
    uint32_t sceneLightFirst = s_frameLightCount;

    if (s_sceneEntityCount > 0 || s_scenePolyCount > 0) {
        uint32_t totalEntityVerts = 0;
        uint32_t totalEntityIndices = 0;
        uint32_t totalEntityDraws = 0;
        uint32_t entityIndex;
        int polyIter;
        /* Poly budget: each poly contributes its own vert count + fan
         * triangulation (numVerts-2)*3 indices + 1 draw. */
        for (polyIter = 0; polyIter < s_scenePolyCount; ++polyIter) {
            int nv = s_scenePolys[polyIter].numVerts;
            if (nv < 3) continue;
            totalEntityVerts += (uint32_t)nv;
            totalEntityIndices += (uint32_t)((nv - 2) * 3);
            totalEntityDraws += 1;
        }

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
            /* Lightning bolt: same quad budget as a sprite (single view-
             * aligned rail core between origin and oldorigin). */
            if (sceneEntity->entity.reType == RT_LIGHTNING) {
                totalEntityVerts += 4;
                totalEntityIndices += 6;
                totalEntityDraws += 1;
                continue;
            }
            /* Rail core: single view-aligned quad like lightning. */
            if (sceneEntity->entity.reType == RT_RAIL_CORE) {
                totalEntityVerts += 4;
                totalEntityIndices += 6;
                totalEntityDraws += 1;
                continue;
            }
            /* Rail rings: up to 32 segments × 4 verts each, 1 draw. */
            if (sceneEntity->entity.reType == RT_RAIL_RINGS) {
                totalEntityVerts += 32 * 4;
                totalEntityIndices += 32 * 6;
                totalEntityDraws += 1;
                continue;
            }
            /* Generic beam: single view-aligned quad, same budget as
             * lightning/rail-core. */
            if (sceneEntity->entity.reType == RT_BEAM) {
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
            EnsureEntitySceneCapacity(s_entityVertexCount + totalEntityVerts,
                                      s_entityIndexCount + totalEntityIndices,
                                      s_entityDrawCount + totalEntityDraws)) {
            /* Append to the per-frame pool instead of resetting. Pool
             * cursors are reset in RE_BeginFrame at frame start; each
             * RE_RenderScene pushes its scene's geometry onto the end. */
            uint32_t entityVertexCursor = s_entityVertexCount;
            uint32_t entityIndexCursor = s_entityIndexCount;
            uint32_t entityDrawCursor = s_entityDrawCount;

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

                    /* Derive sprite blend from the resolved shader's
                     * blendMode instead of hard-coding additive. The old
                     * path rendered every sprite through the additive
                     * entity pipeline, which lights up the transparent
                     * corners of alpha-blended textures like smokePuff
                     * and shotgunSmokePuff as solid orange rectangles.
                     * Model entities already do this at ~line 3827.
                     * Legacy fallback: unknown / opaque → additive, to
                     * preserve the prior behavior for plasma bolts,
                     * rail cores, and muzzle flashes whose shaders we
                     * haven't parsed. */
                    {
                        uint32_t spriteFlags = Q3_METAL_ENTITY_DRAWFLAG_NOCULL;
                        const metalTexture_t *tex = FindTextureByHandle(
                            (qhandle_t)sceneEntity->entity.customShader);
                        if (tex != NULL) {
                            if (tex->blendMode == 1) {
                                spriteFlags |= Q3_METAL_ENTITY_DRAWFLAG_ADDITIVE;
                            } else if (tex->blendMode == 2) {
                                spriteFlags |= Q3_METAL_ENTITY_DRAWFLAG_ALPHA;
                            } else if (tex->blendMode == 3) {
                                spriteFlags |= Q3_METAL_ENTITY_DRAWFLAG_FILTER;
                            } else if (tex->blendMode == 4) {
                                spriteFlags |= Q3_METAL_ENTITY_DRAWFLAG_SUBTRACT;
                            } else {
                                spriteFlags |= Q3_METAL_ENTITY_DRAWFLAG_ADDITIVE;
                            }
                        } else {
                            spriteFlags |= Q3_METAL_ENTITY_DRAWFLAG_ADDITIVE;
                        }
                        s_entityDraws[entityDrawCursor].firstIndex = firstIndex;
                        s_entityDraws[entityDrawCursor].indexCount = 6;
                        s_entityDraws[entityDrawCursor].textureHandle = (uint32_t)sceneEntity->entity.customShader;
                        s_entityDraws[entityDrawCursor].flags = spriteFlags;
                    }
                    entityDrawCursor += 1;
                    continue;
                }

                /* RT_LIGHTNING: single rail-core quad between origin ("from")
                 * and oldorigin ("to"). The side vector is perpendicular to
                 * both the beam direction AND the viewer-to-beam direction,
                 * so the quad is broadest when viewed from the side and
                 * narrows into a line when viewed end-on — matches the Q3
                 * lightning bolt look. Color from entity.shader.rgba.
                 * Width fixed at 8 world units (Q3 reference). Stock Q3
                 * crosshatches 4 cores for volume; we emit one core for
                 * MVP (visible bolt). */
                if (sceneEntity->entity.reType == RT_LIGHTNING) {
                    uint32_t baseVertex = entityVertexCursor;
                    uint32_t firstIndex = entityIndexCursor;
                    const float *start = sceneEntity->entity.origin;
                    const float *end = sceneEntity->entity.oldorigin;
                    vec3_t beamDir, v1, v2, right;
                    vec3_t corner0, corner1, corner2, corner3;
                    float len;
                    float t;
                    float r, g, b, a;
                    const float spanWidth = 8.0f;

                    VectorSubtract(end, start, beamDir);
                    len = VectorLength(beamDir);
                    if (len < 1.0f) {
                        /* Degenerate beam, skip. */
                        continue;
                    }
                    t = len / 256.0f;     /* Q3 texcoord stretch */

                    VectorSubtract(start, vieworg, v1);
                    VectorNormalize(v1);
                    VectorSubtract(end, vieworg, v2);
                    VectorNormalize(v2);
                    CrossProduct(v1, v2, right);
                    if (VectorLength(right) < 1e-4f) {
                        /* Viewer directly on the beam line — degenerate
                         * cross product. Fall back to camera's up-right
                         * axis so we still emit visible geometry. */
                        VectorCopy(axis2, right);
                    }
                    VectorNormalize(right);
                    VectorScale(right, spanWidth, right);

                    /* corner0 = start + right, corner1 = start - right,
                     * corner2 = end + right, corner3 = end - right. */
                    VectorAdd(start, right, corner0);
                    VectorSubtract(start, right, corner1);
                    VectorAdd(end, right, corner2);
                    VectorSubtract(end, right, corner3);

                    r = (float)sceneEntity->entity.shader.rgba[0] / 255.0f;
                    g = (float)sceneEntity->entity.shader.rgba[1] / 255.0f;
                    b = (float)sceneEntity->entity.shader.rgba[2] / 255.0f;
                    a = (float)sceneEntity->entity.shader.rgba[3] / 255.0f;
                    /* cgame sometimes ships alpha=0 on lightning — treat
                     * as fully opaque so the bolt is visible. */
                    if (a < 0.01f) a = 1.0f;

                    s_entityVertices[baseVertex + 0].position[0] = corner0[0];
                    s_entityVertices[baseVertex + 0].position[1] = corner0[1];
                    s_entityVertices[baseVertex + 0].position[2] = corner0[2];
                    s_entityVertices[baseVertex + 0].texCoord[0] = 0.0f;
                    s_entityVertices[baseVertex + 0].texCoord[1] = 0.0f;
                    s_entityVertices[baseVertex + 1].position[0] = corner1[0];
                    s_entityVertices[baseVertex + 1].position[1] = corner1[1];
                    s_entityVertices[baseVertex + 1].position[2] = corner1[2];
                    s_entityVertices[baseVertex + 1].texCoord[0] = 0.0f;
                    s_entityVertices[baseVertex + 1].texCoord[1] = 1.0f;
                    s_entityVertices[baseVertex + 2].position[0] = corner2[0];
                    s_entityVertices[baseVertex + 2].position[1] = corner2[1];
                    s_entityVertices[baseVertex + 2].position[2] = corner2[2];
                    s_entityVertices[baseVertex + 2].texCoord[0] = t;
                    s_entityVertices[baseVertex + 2].texCoord[1] = 0.0f;
                    s_entityVertices[baseVertex + 3].position[0] = corner3[0];
                    s_entityVertices[baseVertex + 3].position[1] = corner3[1];
                    s_entityVertices[baseVertex + 3].position[2] = corner3[2];
                    s_entityVertices[baseVertex + 3].texCoord[0] = t;
                    s_entityVertices[baseVertex + 3].texCoord[1] = 1.0f;
                    {
                        int _i;
                        for (_i = 0; _i < 4; ++_i) {
                            s_entityVertices[baseVertex + _i].color[0] = r;
                            s_entityVertices[baseVertex + _i].color[1] = g;
                            s_entityVertices[baseVertex + _i].color[2] = b;
                            s_entityVertices[baseVertex + _i].color[3] = a;
                        }
                    }
                    s_entityIndices[entityIndexCursor + 0] = baseVertex + 0;
                    s_entityIndices[entityIndexCursor + 1] = baseVertex + 1;
                    s_entityIndices[entityIndexCursor + 2] = baseVertex + 2;
                    s_entityIndices[entityIndexCursor + 3] = baseVertex + 2;
                    s_entityIndices[entityIndexCursor + 4] = baseVertex + 1;
                    s_entityIndices[entityIndexCursor + 5] = baseVertex + 3;
                    entityVertexCursor += 4;
                    entityIndexCursor += 6;

                    s_entityDraws[entityDrawCursor].firstIndex = firstIndex;
                    s_entityDraws[entityDrawCursor].indexCount = 6;
                    s_entityDraws[entityDrawCursor].textureHandle =
                        (uint32_t)sceneEntity->entity.customShader;
                    /* Lightning bolt texture is additive in stock Q3
                     * (lightningBolt shader uses GL_ONE GL_ONE) — force
                     * the additive pipeline + no-cull so the beam is
                     * visible from both sides and blends over the world. */
                    s_entityDraws[entityDrawCursor].flags =
                        Q3_METAL_ENTITY_DRAWFLAG_NOCULL |
                        Q3_METAL_ENTITY_DRAWFLAG_ADDITIVE;
                    entityDrawCursor += 1;
                    continue;
                }

                /* RT_RAIL_CORE: identical geometry to lightning, just wider.
                 * Q3's r_railCoreWidth defaults to 16 (vs lightning's 8). */
                if (sceneEntity->entity.reType == RT_RAIL_CORE) {
                    uint32_t baseVertex = entityVertexCursor;
                    uint32_t firstIndex = entityIndexCursor;
                    const float *start = sceneEntity->entity.origin;
                    const float *end = sceneEntity->entity.oldorigin;
                    vec3_t beamDir, v1, v2, right;
                    vec3_t c0, c1, c2, c3;
                    float len, t;
                    float r, g, b, a;
                    const float spanWidth = 16.0f;
                    int i;

                    VectorSubtract(end, start, beamDir);
                    len = VectorLength(beamDir);
                    if (len < 1.0f) continue;
                    t = len / 256.0f;

                    VectorSubtract(start, vieworg, v1); VectorNormalize(v1);
                    VectorSubtract(end, vieworg, v2);   VectorNormalize(v2);
                    CrossProduct(v1, v2, right);
                    if (VectorLength(right) < 1e-4f) VectorCopy(axis2, right);
                    VectorNormalize(right);
                    VectorScale(right, spanWidth, right);

                    VectorAdd(start, right, c0);
                    VectorSubtract(start, right, c1);
                    VectorAdd(end, right, c2);
                    VectorSubtract(end, right, c3);

                    r = (float)sceneEntity->entity.shader.rgba[0] / 255.0f;
                    g = (float)sceneEntity->entity.shader.rgba[1] / 255.0f;
                    b = (float)sceneEntity->entity.shader.rgba[2] / 255.0f;
                    a = (float)sceneEntity->entity.shader.rgba[3] / 255.0f;
                    if (a < 0.01f) a = 1.0f;

                    s_entityVertices[baseVertex + 0].position[0] = c0[0];
                    s_entityVertices[baseVertex + 0].position[1] = c0[1];
                    s_entityVertices[baseVertex + 0].position[2] = c0[2];
                    s_entityVertices[baseVertex + 0].texCoord[0] = 0.0f;
                    s_entityVertices[baseVertex + 0].texCoord[1] = 0.0f;
                    s_entityVertices[baseVertex + 1].position[0] = c1[0];
                    s_entityVertices[baseVertex + 1].position[1] = c1[1];
                    s_entityVertices[baseVertex + 1].position[2] = c1[2];
                    s_entityVertices[baseVertex + 1].texCoord[0] = 0.0f;
                    s_entityVertices[baseVertex + 1].texCoord[1] = 1.0f;
                    s_entityVertices[baseVertex + 2].position[0] = c2[0];
                    s_entityVertices[baseVertex + 2].position[1] = c2[1];
                    s_entityVertices[baseVertex + 2].position[2] = c2[2];
                    s_entityVertices[baseVertex + 2].texCoord[0] = t;
                    s_entityVertices[baseVertex + 2].texCoord[1] = 0.0f;
                    s_entityVertices[baseVertex + 3].position[0] = c3[0];
                    s_entityVertices[baseVertex + 3].position[1] = c3[1];
                    s_entityVertices[baseVertex + 3].position[2] = c3[2];
                    s_entityVertices[baseVertex + 3].texCoord[0] = t;
                    s_entityVertices[baseVertex + 3].texCoord[1] = 1.0f;
                    for (i = 0; i < 4; ++i) {
                        s_entityVertices[baseVertex + i].color[0] = r;
                        s_entityVertices[baseVertex + i].color[1] = g;
                        s_entityVertices[baseVertex + i].color[2] = b;
                        s_entityVertices[baseVertex + i].color[3] = a;
                    }
                    s_entityIndices[entityIndexCursor + 0] = baseVertex + 0;
                    s_entityIndices[entityIndexCursor + 1] = baseVertex + 1;
                    s_entityIndices[entityIndexCursor + 2] = baseVertex + 2;
                    s_entityIndices[entityIndexCursor + 3] = baseVertex + 2;
                    s_entityIndices[entityIndexCursor + 4] = baseVertex + 1;
                    s_entityIndices[entityIndexCursor + 5] = baseVertex + 3;
                    entityVertexCursor += 4;
                    entityIndexCursor += 6;

                    s_entityDraws[entityDrawCursor].firstIndex = firstIndex;
                    s_entityDraws[entityDrawCursor].indexCount = 6;
                    s_entityDraws[entityDrawCursor].textureHandle =
                        (uint32_t)sceneEntity->entity.customShader;
                    s_entityDraws[entityDrawCursor].flags =
                        Q3_METAL_ENTITY_DRAWFLAG_NOCULL |
                        Q3_METAL_ENTITY_DRAWFLAG_ADDITIVE;
                    entityDrawCursor += 1;
                    continue;
                }

                /* RT_BEAM: grapple / mission beam. View-aligned quad with
                 * stock Q3's red color (1,0,0,1) and width 4. Uses the
                 * white fallback texture (customShader is typically 0
                 * for RT_BEAM — Q3 disables texturing entirely for it). */
                if (sceneEntity->entity.reType == RT_BEAM) {
                    uint32_t baseVertex = entityVertexCursor;
                    uint32_t firstIndex = entityIndexCursor;
                    const float *start = sceneEntity->entity.origin;
                    const float *end = sceneEntity->entity.oldorigin;
                    vec3_t beamDir, v1, v2, right;
                    vec3_t c0, c1, c2, c3;
                    float len;
                    const float spanWidth = 4.0f;
                    qhandle_t texHandle;
                    int i;

                    VectorSubtract(end, start, beamDir);
                    len = VectorLength(beamDir);
                    if (len < 1.0f) continue;

                    VectorSubtract(start, vieworg, v1); VectorNormalize(v1);
                    VectorSubtract(end, vieworg, v2);   VectorNormalize(v2);
                    CrossProduct(v1, v2, right);
                    if (VectorLength(right) < 1e-4f) VectorCopy(axis2, right);
                    VectorNormalize(right);
                    VectorScale(right, spanWidth, right);

                    VectorAdd(start, right, c0);
                    VectorSubtract(start, right, c1);
                    VectorAdd(end, right, c2);
                    VectorSubtract(end, right, c3);

                    s_entityVertices[baseVertex + 0].position[0] = c0[0];
                    s_entityVertices[baseVertex + 0].position[1] = c0[1];
                    s_entityVertices[baseVertex + 0].position[2] = c0[2];
                    s_entityVertices[baseVertex + 0].texCoord[0] = 0.0f;
                    s_entityVertices[baseVertex + 0].texCoord[1] = 0.0f;
                    s_entityVertices[baseVertex + 1].position[0] = c1[0];
                    s_entityVertices[baseVertex + 1].position[1] = c1[1];
                    s_entityVertices[baseVertex + 1].position[2] = c1[2];
                    s_entityVertices[baseVertex + 1].texCoord[0] = 0.0f;
                    s_entityVertices[baseVertex + 1].texCoord[1] = 1.0f;
                    s_entityVertices[baseVertex + 2].position[0] = c2[0];
                    s_entityVertices[baseVertex + 2].position[1] = c2[1];
                    s_entityVertices[baseVertex + 2].position[2] = c2[2];
                    s_entityVertices[baseVertex + 2].texCoord[0] = 1.0f;
                    s_entityVertices[baseVertex + 2].texCoord[1] = 0.0f;
                    s_entityVertices[baseVertex + 3].position[0] = c3[0];
                    s_entityVertices[baseVertex + 3].position[1] = c3[1];
                    s_entityVertices[baseVertex + 3].position[2] = c3[2];
                    s_entityVertices[baseVertex + 3].texCoord[0] = 1.0f;
                    s_entityVertices[baseVertex + 3].texCoord[1] = 1.0f;
                    for (i = 0; i < 4; ++i) {
                        s_entityVertices[baseVertex + i].color[0] = 1.0f;
                        s_entityVertices[baseVertex + i].color[1] = 0.0f;
                        s_entityVertices[baseVertex + i].color[2] = 0.0f;
                        s_entityVertices[baseVertex + i].color[3] = 1.0f;
                    }
                    s_entityIndices[entityIndexCursor + 0] = baseVertex + 0;
                    s_entityIndices[entityIndexCursor + 1] = baseVertex + 1;
                    s_entityIndices[entityIndexCursor + 2] = baseVertex + 2;
                    s_entityIndices[entityIndexCursor + 3] = baseVertex + 2;
                    s_entityIndices[entityIndexCursor + 4] = baseVertex + 1;
                    s_entityIndices[entityIndexCursor + 5] = baseVertex + 3;
                    entityVertexCursor += 4;
                    entityIndexCursor += 6;

                    texHandle = (sceneEntity->entity.customShader > 0)
                        ? sceneEntity->entity.customShader
                        : (qhandle_t)EnsureWhiteTexture();
                    s_entityDraws[entityDrawCursor].firstIndex = firstIndex;
                    s_entityDraws[entityDrawCursor].indexCount = 6;
                    s_entityDraws[entityDrawCursor].textureHandle = (uint32_t)texHandle;
                    s_entityDraws[entityDrawCursor].flags =
                        Q3_METAL_ENTITY_DRAWFLAG_NOCULL |
                        Q3_METAL_ENTITY_DRAWFLAG_ADDITIVE;
                    entityDrawCursor += 1;
                    continue;
                }

                /* RT_RAIL_RINGS: series of small billboard quads placed
                 * every r_railSegmentLength units along the beam. Stock
                 * Q3 draws 4 rotated quads per segment for a spiral
                 * effect; we emit a single view-aligned quad per segment
                 * for MVP, using the ring texture (customShader). */
                if (sceneEntity->entity.reType == RT_RAIL_RINGS) {
                    uint32_t baseVertex = entityVertexCursor;
                    uint32_t firstIndex = entityIndexCursor;
                    const float *a0 = sceneEntity->entity.oldorigin; /* start */
                    const float *a1 = sceneEntity->entity.origin;    /* end */
                    vec3_t beamDir, unitDir, right, up;
                    float len;
                    const float segmentLength = 64.0f;  /* r_railSegmentLength */
                    const float ringSize = 8.0f;
                    int numSegs;
                    int seg;
                    float r, g, b, a;
                    uint32_t localIndexCount = 0;

                    VectorSubtract(a1, a0, beamDir);
                    len = VectorLength(beamDir);
                    if (len < 1.0f) continue;
                    VectorScale(beamDir, 1.0f / len, unitDir);

                    /* Right + up axes perpendicular to beam for the ring
                     * quads. Cheap Gram-Schmidt off the world up axis,
                     * falling back if the beam is vertical. */
                    {
                        vec3_t worldUp = {0.0f, 0.0f, 1.0f};
                        float d = DotProduct(unitDir, worldUp);
                        if (fabsf(d) > 0.99f) {
                            vec3_t alt = {1.0f, 0.0f, 0.0f};
                            CrossProduct(unitDir, alt, right);
                        } else {
                            CrossProduct(unitDir, worldUp, right);
                        }
                        VectorNormalize(right);
                        CrossProduct(unitDir, right, up);
                        VectorNormalize(up);
                    }

                    numSegs = (int)(len / segmentLength);
                    if (numSegs < 1) numSegs = 1;
                    if (numSegs > 32) numSegs = 32;

                    r = (float)sceneEntity->entity.shader.rgba[0] / 255.0f;
                    g = (float)sceneEntity->entity.shader.rgba[1] / 255.0f;
                    b = (float)sceneEntity->entity.shader.rgba[2] / 255.0f;
                    a = (float)sceneEntity->entity.shader.rgba[3] / 255.0f;
                    if (a < 0.01f) a = 1.0f;

                    for (seg = 0; seg < numSegs; ++seg) {
                        uint32_t segBase = entityVertexCursor;
                        vec3_t center;
                        vec3_t scaledRight, scaledUp;
                        vec3_t rc0, rc1, rc2, rc3;
                        float step = (float)(seg + 1) * segmentLength;
                        int vi;

                        center[0] = a0[0] + unitDir[0] * step;
                        center[1] = a0[1] + unitDir[1] * step;
                        center[2] = a0[2] + unitDir[2] * step;
                        VectorScale(right, ringSize, scaledRight);
                        VectorScale(up, ringSize, scaledUp);
                        VectorSubtract(center, scaledRight, rc0); VectorSubtract(rc0, scaledUp, rc0);
                        VectorAdd(center, scaledRight, rc1); VectorSubtract(rc1, scaledUp, rc1);
                        VectorAdd(center, scaledRight, rc2); VectorAdd(rc2, scaledUp, rc2);
                        VectorSubtract(center, scaledRight, rc3); VectorAdd(rc3, scaledUp, rc3);

                        s_entityVertices[segBase + 0].position[0] = rc0[0];
                        s_entityVertices[segBase + 0].position[1] = rc0[1];
                        s_entityVertices[segBase + 0].position[2] = rc0[2];
                        s_entityVertices[segBase + 0].texCoord[0] = 0.0f;
                        s_entityVertices[segBase + 0].texCoord[1] = 1.0f;
                        s_entityVertices[segBase + 1].position[0] = rc1[0];
                        s_entityVertices[segBase + 1].position[1] = rc1[1];
                        s_entityVertices[segBase + 1].position[2] = rc1[2];
                        s_entityVertices[segBase + 1].texCoord[0] = 1.0f;
                        s_entityVertices[segBase + 1].texCoord[1] = 1.0f;
                        s_entityVertices[segBase + 2].position[0] = rc2[0];
                        s_entityVertices[segBase + 2].position[1] = rc2[1];
                        s_entityVertices[segBase + 2].position[2] = rc2[2];
                        s_entityVertices[segBase + 2].texCoord[0] = 1.0f;
                        s_entityVertices[segBase + 2].texCoord[1] = 0.0f;
                        s_entityVertices[segBase + 3].position[0] = rc3[0];
                        s_entityVertices[segBase + 3].position[1] = rc3[1];
                        s_entityVertices[segBase + 3].position[2] = rc3[2];
                        s_entityVertices[segBase + 3].texCoord[0] = 0.0f;
                        s_entityVertices[segBase + 3].texCoord[1] = 0.0f;
                        for (vi = 0; vi < 4; ++vi) {
                            s_entityVertices[segBase + vi].color[0] = r;
                            s_entityVertices[segBase + vi].color[1] = g;
                            s_entityVertices[segBase + vi].color[2] = b;
                            s_entityVertices[segBase + vi].color[3] = a;
                        }
                        s_entityIndices[entityIndexCursor + 0] = segBase + 0;
                        s_entityIndices[entityIndexCursor + 1] = segBase + 1;
                        s_entityIndices[entityIndexCursor + 2] = segBase + 2;
                        s_entityIndices[entityIndexCursor + 3] = segBase + 0;
                        s_entityIndices[entityIndexCursor + 4] = segBase + 2;
                        s_entityIndices[entityIndexCursor + 5] = segBase + 3;
                        entityVertexCursor += 4;
                        entityIndexCursor += 6;
                        localIndexCount += 6;
                    }

                    (void)baseVertex;
                    s_entityDraws[entityDrawCursor].firstIndex = firstIndex;
                    s_entityDraws[entityDrawCursor].indexCount = localIndexCount;
                    s_entityDraws[entityDrawCursor].textureHandle =
                        (uint32_t)sceneEntity->entity.customShader;
                    s_entityDraws[entityDrawCursor].flags =
                        Q3_METAL_ENTITY_DRAWFLAG_NOCULL |
                        Q3_METAL_ENTITY_DRAWFLAG_ADDITIVE;
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
                            } else if (tex->blendMode == 4) {
                                drawFlags |= Q3_METAL_ENTITY_DRAWFLAG_SUBTRACT;
                            } else {
                                /* blendMode==0 for an FX model means its
                                 * shader didn't parse and we loaded the
                                 * texture from a .jpg fallback that lost
                                 * the alpha channel. Opaque-render gives
                                 * a hard yellow rectangle around explosion
                                 * fireballs, blood splats, rocket trails.
                                 * Force additive for the known FX paths —
                                 * a black-border JPG contributes zero in
                                 * additive blend, hiding the rectangle and
                                 * showing just the bright fireball center. */
                                const char *n = tex->name;
                                if (n[0] != '\0' &&
                                    (!Q_stricmpn(n, "models/weaphits/", 16) ||
                                     !Q_stricmpn(n, "sprites/", 8) ||
                                     !Q_stricmpn(n, "gfx/damage/", 11) ||
                                     !Q_stricmpn(n, "gfx/misc/", 9))) {
                                    drawFlags |= Q3_METAL_ENTITY_DRAWFLAG_ADDITIVE;
                                }
                            }
                            if (tex->tcGenEnv) {
                                drawFlags |= Q3_METAL_ENTITY_DRAWFLAG_TCGEN_ENV;
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

                            /* Pass the normalized world-space normal down
                             * to the shader so tcGen environment can use
                             * smooth per-vertex normals instead of flat
                             * faceted dfdx/dfdy derivatives on quad-shell
                             * / regen / battlesuit reflections. */
                            outVertex->normal[0] = worldN[0];
                            outVertex->normal[1] = worldN[1];
                            outVertex->normal[2] = worldN[2];

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

            /* Scene polys: triangle-fan emission. Each poly's vertices
             * are already in world space. We fan from vertex 0: triangles
             * (0,1,2), (0,2,3), (0,3,4)... — (numVerts-2) triangles. Blend
             * follows the shader's blendMode like sprites. Alpha for
             * transparency (typical for shadow blobs, bullet marks) and
             * additive for muzzle-flare polys all fall out of the
             * blendMode lookup on the poly's shader. */
            {
                int polyOut;
                for (polyOut = 0; polyOut < s_scenePolyCount; ++polyOut) {
                    const metalScenePoly_t *poly = &s_scenePolys[polyOut];
                    int nv = poly->numVerts;
                    uint32_t baseVertex;
                    uint32_t firstIndex;
                    int vi, ti;
                    const metalTexture_t *ptex;
                    uint32_t polyFlags = Q3_METAL_ENTITY_DRAWFLAG_NOCULL;

                    if (nv < 3) continue;
                    baseVertex = entityVertexCursor;
                    firstIndex = entityIndexCursor;

                    for (vi = 0; vi < nv; ++vi) {
                        const polyVert_t *src = &s_scenePolyVerts[poly->firstVert + vi];
                        Q3MetalEntityVertex *dst = &s_entityVertices[baseVertex + vi];
                        dst->position[0] = src->xyz[0];
                        dst->position[1] = src->xyz[1];
                        dst->position[2] = src->xyz[2];
                        dst->texCoord[0] = src->st[0];
                        dst->texCoord[1] = src->st[1];
                        dst->color[0] = (float)src->modulate.rgba[0] / 255.0f;
                        dst->color[1] = (float)src->modulate.rgba[1] / 255.0f;
                        dst->color[2] = (float)src->modulate.rgba[2] / 255.0f;
                        dst->color[3] = (float)src->modulate.rgba[3] / 255.0f;
                    }
                    for (ti = 0; ti < nv - 2; ++ti) {
                        s_entityIndices[entityIndexCursor + ti * 3 + 0] = baseVertex;
                        s_entityIndices[entityIndexCursor + ti * 3 + 1] = baseVertex + ti + 1;
                        s_entityIndices[entityIndexCursor + ti * 3 + 2] = baseVertex + ti + 2;
                    }

                    ptex = FindTextureByHandle(poly->shader);
                    if (ptex != NULL) {
                        if (ptex->blendMode == 1) polyFlags |= Q3_METAL_ENTITY_DRAWFLAG_ADDITIVE;
                        else if (ptex->blendMode == 2) polyFlags |= Q3_METAL_ENTITY_DRAWFLAG_ALPHA;
                        else if (ptex->blendMode == 3) polyFlags |= Q3_METAL_ENTITY_DRAWFLAG_FILTER;
                        else if (ptex->blendMode == 4) polyFlags |= Q3_METAL_ENTITY_DRAWFLAG_SUBTRACT;
                        /* Fallback: when the poly's shader didn't resolve a
                         * blend mode (blendMode==0), default to ADDITIVE not
                         * ALPHA. Q3's explosion/trail/particle shaders are
                         * GL_SRC_ALPHA GL_ONE (premult-additive); our parser
                         * doesn't yet recognize that combo so they arrive
                         * with blendMode=0. Alpha-blending an opaque JPG
                         * (explosion textures load as .jpg when the .tga is
                         * missing, which is the common case) draws a hard
                         * yellow rectangle over the scene — "square around
                         * explosion." Additive with a dark-border texture
                         * renders correctly because black contributes zero. */
                        else polyFlags |= Q3_METAL_ENTITY_DRAWFLAG_ADDITIVE;
                    } else {
                        polyFlags |= Q3_METAL_ENTITY_DRAWFLAG_ADDITIVE;
                    }

                    s_entityDraws[entityDrawCursor].firstIndex = firstIndex;
                    s_entityDraws[entityDrawCursor].indexCount = (uint32_t)((nv - 2) * 3);
                    s_entityDraws[entityDrawCursor].textureHandle = (uint32_t)poly->shader;
                    s_entityDraws[entityDrawCursor].flags = polyFlags;

                    entityVertexCursor += (uint32_t)nv;
                    entityIndexCursor += (uint32_t)((nv - 2) * 3);
                    entityDrawCursor += 1;
                }
            }

            s_entityVertexCount = entityVertexCursor;
            s_entityIndexCount = entityIndexCursor;
            s_entityDrawCount = entityDrawCursor;
        }
    }

    /* Append the intake lights for this scene to the per-frame light
     * pool so Swift can bind [lightFirst .. lightFirst+lightCount]
     * per scene. The intake buffer s_sceneLights resets on next
     * ClearScene; the per-frame pool does not until RE_BeginFrame. */
    if (s_sceneLightCount > 0 &&
        s_frameLightCount + s_sceneLightCount <= Q3_METAL_MAX_LIGHTS * Q3_METAL_MAX_SCENES) {
        Com_Memcpy(&s_frameLights[s_frameLightCount],
                   s_sceneLights,
                   sizeof(Q3MetalLight) * s_sceneLightCount);
        s_frameLightCount += s_sceneLightCount;
    }

    /* Push the scene snapshot. Viewport is verbatim from fd — cgame
     * already called CG_AdjustFrom640 in CG_Draw3DModel to scale into
     * pixel coords. Swift clamps to drawable bounds. Overflow past
     * Q3_METAL_MAX_SCENES is a hard drop; log once and move on. */
    if (s_sceneSnapshotCount < Q3_METAL_MAX_SCENES) {
        Q3MetalSceneSnapshot *scene = &s_sceneSnapshots[s_sceneSnapshotCount];
        scene->viewportX = (uint32_t)(fd->x < 0 ? 0 : fd->x);
        scene->viewportY = (uint32_t)(fd->y < 0 ? 0 : fd->y);
        scene->viewportWidth = (uint32_t)(fd->width < 0 ? 0 : fd->width);
        scene->viewportHeight = (uint32_t)(fd->height < 0 ? 0 : fd->height);
        scene->viewOrigin[0] = vieworg[0];
        scene->viewOrigin[1] = vieworg[1];
        scene->viewOrigin[2] = vieworg[2];
        scene->viewAxis[0] = axis0[0]; scene->viewAxis[1] = axis0[1]; scene->viewAxis[2] = axis0[2];
        scene->viewAxis[3] = axis1[0]; scene->viewAxis[4] = axis1[1]; scene->viewAxis[5] = axis1[2];
        scene->viewAxis[6] = axis2[0]; scene->viewAxis[7] = axis2[1]; scene->viewAxis[8] = axis2[2];
        scene->fovX = fovX;
        scene->fovY = fovY;
        scene->rdflags = (uint32_t)fd->rdflags;
        scene->entityCommandFirst = sceneEntityCommandFirst;
        scene->entityCommandCount = s_entityDrawCount - sceneEntityCommandFirst;
        scene->lightFirst = sceneLightFirst;
        scene->lightCount = s_sceneLightCount;
        /* clearColor only matters for scene 0; sub-scenes use loadAction=.load */
        scene->clearColor[0] = s_frameSnapshot.clearColor[0];
        scene->clearColor[1] = s_frameSnapshot.clearColor[1];
        scene->clearColor[2] = s_frameSnapshot.clearColor[2];
        scene->clearColor[3] = s_frameSnapshot.clearColor[3];
        s_sceneSnapshotCount += 1;
    }

    s_frameSnapshot.entityVertexCount = s_entityVertexCount;
    s_frameSnapshot.entityIndexCount = s_entityIndexCount;
    s_frameSnapshot.entityCommandCount = s_entityDrawCount;
    s_frameSnapshot.lightCount = s_frameLightCount;
    s_frameSnapshot.sceneCount = s_sceneSnapshotCount;
    if ((s_sceneLogCounter % 60) == 0) {
        uint32_t i;
        ri.Printf(PRINT_ALL,
            "Metal scene frame: scenes=%u totalEntCmds=%u totalLights=%u\n",
            s_sceneSnapshotCount, s_entityDrawCount, s_frameLightCount);
        for (i = 0; i < s_sceneSnapshotCount; ++i) {
            const Q3MetalSceneSnapshot *s = &s_sceneSnapshots[i];
            ri.Printf(PRINT_ALL,
                "  scene[%u]: rdflags=0x%x viewport=%ux%u@%u,%u fov=%.1fx%.1f ents=%u lights=%u\n",
                i, s->rdflags, s->viewportWidth, s->viewportHeight,
                s->viewportX, s->viewportY, s->fovX, s->fovY,
                s->entityCommandCount, s->lightCount);
        }
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
    metalTexture_t *tex = FindTextureByHandle(textureHandle);

    if (s_drawCount >= Q3_METAL_MAX_DRAWS || s_vertexCount + 6 > Q3_METAL_MAX_VERTICES) {
        return;
    }

    draw = &s_draws[s_drawCount++];
    draw->firstVertex = s_vertexCount;
    draw->vertexCount = 6;
    draw->textureHandle = (uint32_t)textureHandle;
    draw->blendMode = (uint32_t)(tex ? tex->blendMode : 0);

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
    /* Multi-scene: reset the per-frame scene pool + entity pool cursors.
     * Each subsequent RE_RenderScene call appends one scene and its
     * entity/light ranges. Swift iterates scenes[0..sceneCount] and
     * renders each with setViewport + setScissorRect. */
    s_sceneSnapshotCount = 0;
    s_entityVertexCount = 0;
    s_entityIndexCount = 0;
    s_entityDrawCount = 0;
    s_frameLightCount = 0;
    s_frameSnapshot.sceneCount = 0;
    s_frameSnapshot.lightCount = 0;
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
static void R_ModelBounds(qhandle_t model, vec3_t mins, vec3_t maxs) {
    /* Read the MD3's frame[0] bounds directly. CG_DrawHead relies on this
     * to compute the HUD portrait's camera-relative origin — a zeroed
     * return puts the head inside the near plane and nothing draws. */
    const metalModel_t *mdl;
    const md3Header_t *header;
    const md3Frame_t *frame;

    VectorClear(mins);
    VectorClear(maxs);

    mdl = FindModelByHandle(model);
    if (mdl == NULL || mdl->md3 == NULL) {
        return;
    }
    header = mdl->md3;
    if (header->numFrames <= 0) {
        return;
    }
    frame = (const md3Frame_t *)((const byte *)header + header->ofsFrames);
    VectorCopy(frame->bounds[0], mins);
    VectorCopy(frame->bounds[1], maxs);
}

static void RE_RemapShader(const char *oldShader, const char *newShader, const char *offsetTime) {}
static qboolean RE_GetEntityToken(char *buffer, int size) { return qfalse; }
static qboolean R_inPVS(const vec3_t p1, const vec3_t p2) { return qfalse; }

/* Video capture shared buffer.
 *
 * Swift's draw(in:) reads back the current Metal drawable after each
 * frame's commit into this buffer (BGRA, width*height*4 bytes) when
 * CL_VideoRecording() is active. The engine's per-frame
 * CL_TakeVideoFrame path then invokes RE_TakeVideoFrame below, which
 * converts the stashed BGRA into the packed RGB layout the AVI muxer
 * (code/client/cl_avi.c) expects.
 *
 * Single-producer (Swift main thread) / single-consumer (engine
 * thread) — the ready flag is fine as a plain int since misses just
 * result in the previous frame being reused, which is acceptable for
 * this diagnostic tool. */
#define Q3_METAL_VIDEO_MAX_W 1920
#define Q3_METAL_VIDEO_MAX_H 1080
static byte  s_videoCaptureBgra[Q3_METAL_VIDEO_MAX_W * Q3_METAL_VIDEO_MAX_H * 4];
static int   s_videoCaptureWidth;
static int   s_videoCaptureHeight;
static int   s_videoCaptureReady;

/* Called by Swift after each drawable readback. Bytes are BGRA (Metal
 * native). bytesPerRow == width*4 (no padding). */
void Q3MetalRenderer_StoreVideoFrame(const uint8_t *bgra, int width, int height) {
    size_t n;
    if (bgra == NULL || width <= 0 || height <= 0) return;
    if (width > Q3_METAL_VIDEO_MAX_W || height > Q3_METAL_VIDEO_MAX_H) return;
    n = (size_t)width * (size_t)height * 4;
    Com_Memcpy(s_videoCaptureBgra, bgra, n);
    s_videoCaptureWidth = width;
    s_videoCaptureHeight = height;
    s_videoCaptureReady = 1;
}

/* Called by the engine's CL_TakeVideoFrame path (cl_avi.c) once per
 * recorded frame. `w`×`h` is the AVI stream dimension (from r_custom*
 * or glconfig). captureBuffer receives tightly-packed RGB (no row
 * padding, no alpha). If our Swift-driven readback hasn't produced a
 * matching frame yet, we leave captureBuffer at zeros — ffprobe will
 * see a black frame for that entry but the AVI stays valid. */
static void RE_TakeVideoFrame(int w, int h, byte *captureBuffer,
                              byte *encodeBuffer, qboolean motionJpeg) {
    int x, y;
    const byte *src;
    byte *dst;
    size_t rgbSize;
    if (captureBuffer == NULL || w <= 0 || h <= 0) return;
    rgbSize = (size_t)w * (size_t)h * 3;
    if (!s_videoCaptureReady ||
        s_videoCaptureWidth != w || s_videoCaptureHeight != h) {
        Com_Memset(captureBuffer, 0, rgbSize);
    } else {
        /* Metal textures are upside-down relative to what the AVI
         * encoder expects (GL convention: origin at bottom-left,
         * Metal: top-left). Flip Y while we walk the pixels. */
        for (y = 0; y < h; ++y) {
            src = &s_videoCaptureBgra[(size_t)(h - 1 - y) * (size_t)w * 4];
            dst = &captureBuffer[(size_t)y * (size_t)w * 3];
            for (x = 0; x < w; ++x, src += 4, dst += 3) {
                dst[0] = src[2]; /* R = BGRA's B-slot (Metal native) */
                dst[1] = src[1]; /* G */
                dst[2] = src[0]; /* B = BGRA's R-slot */
            }
        }
        s_videoCaptureReady = 0;
    }
    /* Upstream GL renderer uses a two-phase approach: RE_TakeVideoFrame
     * schedules, RB_TakeVideoFrameCmd writes. Our stub has no backend
     * phase — do the write synchronously. For motionJpeg we'd call
     * CL_SaveJPGToBuffer first; for raw we can pass captureBuffer
     * straight through. AVI muxer is happy with raw 24-bit RGB (BI_RGB
     * biCompression when motionJpeg=false). */
    if (ri.CL_WriteAVIVideoFrame) {
        if (motionJpeg && ri.CL_SaveJPGToBuffer && encodeBuffer) {
            size_t jpgSize = ri.CL_SaveJPGToBuffer(encodeBuffer, rgbSize,
                /* quality */ 90, w, h, captureBuffer, /* padding */ 0);
            ri.CL_WriteAVIVideoFrame(encodeBuffer, (int)jpgSize);
        } else {
            ri.CL_WriteAVIVideoFrame(captureBuffer, (int)rgbSize);
        }
    }
}
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
    /* Re-sync the client-side capture size each time the drawable
     * moves. Matters specifically for the `video` command pipeline
     * (cl_avi.c) which snapshots cls.captureWidth at AVI-open time. */
    if (ri.CL_SetScaling) {
        ri.CL_SetScaling(1.0f, width, height);
    }
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

int Q3MetalRenderer_GetWorldFogCount(void) {
    return s_worldFogCount;
}

const Q3MetalWorldFog *Q3MetalRenderer_GetWorldFogs(void) {
    return s_worldFogsPublic;
}

int Q3MetalRenderer_GetFlareCount(void) { return s_worldFlareCount; }
const Q3MetalFlare *Q3MetalRenderer_GetFlares(void) { return s_worldFlares; }
uint32_t Q3MetalRenderer_GetFlareTextureHandle(void) { return s_flareTextureHandle; }

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
    outInfo->tcModCount = (uint32_t)texture->tcModCount;
    {
        int i;
        for (i = 0; i < Q3_MAX_TCMODS; ++i) {
            outInfo->tcMods[i] = texture->tcMods[i];
        }
    }
    outInfo->alphaFunc = (uint32_t)texture->alphaFunc;
    outInfo->rgbGen = (uint32_t)texture->rgbGen;
    outInfo->alphaGen = (uint32_t)texture->alphaGen;
    outInfo->rgbWaveFunc  = (uint32_t)texture->rgbWaveFunc;
    outInfo->rgbWaveBase  = texture->rgbWaveBase;
    outInfo->rgbWaveAmp   = texture->rgbWaveAmp;
    outInfo->rgbWavePhase = texture->rgbWavePhase;
    outInfo->rgbWaveFreq  = texture->rgbWaveFreq;
    outInfo->alphaWaveFunc  = (uint32_t)texture->alphaWaveFunc;
    outInfo->alphaWaveBase  = texture->alphaWaveBase;
    outInfo->alphaWaveAmp   = texture->alphaWaveAmp;
    outInfo->alphaWavePhase = texture->alphaWavePhase;
    outInfo->alphaWaveFreq  = texture->alphaWaveFreq;
    outInfo->rgbConstColor[0] = texture->rgbConstColor[0];
    outInfo->rgbConstColor[1] = texture->rgbConstColor[1];
    outInfo->rgbConstColor[2] = texture->rgbConstColor[2];
    outInfo->alphaConst = texture->alphaConst;
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
