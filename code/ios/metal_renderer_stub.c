/*
=============================================================================

Metal Renderer Stub - Quake Frontend / Metal Backend

This file implements the translation layer between Quake III's CPU-side
renderer and Apple's Metal GPU pipeline.

Architecture:
    Quake frontend:
        - parse shader scripts
        - build stage lists
        - preserve GLS blend/depth/cull semantics

    Metal backend:
        - translate stage state into Metal draw commands
        - bind textures and buffers
        - execute draw calls

Rules:
    - Do not add shader-name-specific fixes.
    - Do not add hardcoded visual tweaks.
    - Do not merge, skip, or reorder stages for convenience.
    - Cull is shader-level.
    - Lightmap is a real stage.
    - Blend must converge on srcBlend/dstBlend passthrough, not compressed modes.

If a visual issue exists, fix the generic mismatch against ioq3/Kenny behavior.

=============================================================================
*/

#include "../qcommon/q_shared.h"
#include "../qcommon/qfiles.h"
#include "../client/client.h"
#include "../renderercommon/tr_public.h"
#include "../renderer/tr_common.h"
#include "../clean_frontend/q3_stage.h"
#include "metal_renderer_shared.h"
#include "ios_local.h"
#include <os/log.h>
#include <stdio.h>

/* Append a line to ~/Documents/q3_diag.log inside the app sandbox. */
static void Q3_FileLogf(const char *fmt, ...) {
    static char path[1024] = {0};
    if (path[0] == '\0') {
        const char *home = getenv("HOME");
        if (home == NULL) home = ".";
        snprintf(path, sizeof(path), "%s/Documents/q3_diag.log", home);
    }
    FILE *f = fopen(path, "a");
    if (!f) return;
    va_list ap;
    va_start(ap, fmt);
    vfprintf(f, fmt, ap);
    va_end(ap);
    fputc('\n', f);
    fclose(f);
}

#define Q3_OSLOG(fmt, ...) do { \
    os_log(OS_LOG_DEFAULT, "[Q3] " fmt, ##__VA_ARGS__); \
    Q3_FileLogf("[Q3] " fmt, ##__VA_ARGS__); \
} while (0)

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
    qboolean isLightmap;
    uint32_t generation;
    qhandle_t handle;
    int width;
    int height;
    byte *rgbaBytes;
    char name[MAX_QPATH];
    int blendMode; /* 0=opaque, 1=alpha-add, 2=alpha, 3=filter,
                    * 4=subtract, 5=full-add; propagated from the
                    * shader-map entry that resolved this texture. */
    int alphaFunc; /* 0=none, 1=GT0, 2=GE128, 3=LT128 */
    int tcGenEnv;  /* 1 if the resolved shader uses `tcGen environment`
                    * (chrome/reflective like powerups/quad, shell shaders).
                    * Entity pipeline reads this to switch UV generation
                    * from mesh ST to the reflection formula. */
    int rgbGen;    /* 0=identity, 1=vertex, 2=lightingDiffuse, 3=wave,
                    * 7=identityLighting.
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
    /* Stage 0 `clampmap` directive: 0=repeat (default `map`), 1=clamp
     * (`clampmap`). Read by EntityFlagsForTexture; entity draws bind
     * uiSamplerState (.clampToEdge) when set, worldSamplerState
     * (.repeat) when clear. Caveat: this is stamped per-texture from
     * stage 0, so a texture used by both a `map` stage and a `clampmap`
     * stage in different shaders will reflect whichever shader
     * registered last. Acceptable for current Q3 content where wrap mode
     * is texture-content driven (dlight discs always clampmap, scrolling
     * patterns always map). Full per-stage routing would also write the
     * flag at entity-emit time from the stage that produced the draw,
     * but the helper-based path keeps EntityFlagsForTexture self-
     * contained for now. */
    int wrapClampMode;
    /* deformVertexes wave (stage 0) — propagated to entity draws via
     * Q3MetalRenderer_GetTextureInfo so chrome shell shaders (powerups/
     * quad, quadWeapon, regen, battlesuit) apply the proper normal-axis
     * vertex offset. Without this the shell shader renders at the gun
     * model's exact position and collapses inside the silhouette;
     * canonical powerups/quadWeapon uses base=0.5 → +0.5 unit halo,
     * powerups/quad uses base=3.0 → +3 unit halo. func==0 → no deform. */
    int deformWaveFunc;
    float deformWaveDiv;
    float deformWaveBase;
    float deformWaveAmp;
    float deformWavePhase;
    float deformWaveFreq;
} metalTexture_t;

refimport_t ri;

static void MetalTelemetryPrintf(const char *type, int printLevel, const char *format, ...) {
    char message[2048];
    size_t len;
    va_list args;

    if (format == NULL) {
        return;
    }

    va_start(args, format);
    Q_vsnprintf(message, sizeof(message), format, args);
    va_end(args);

    if (ri.Printf != NULL) {
        ri.Printf(printLevel, "%s", message);
    }

    len = strlen(message);
    while (len > 0 && (message[len - 1] == '\n' || message[len - 1] == '\r')) {
        message[--len] = '\0';
    }

    /* Also surface to os_log + sandbox file so host-side tools see us. */
    if (message[0] != '\0') {
        if (type != NULL && type[0] != '\0') {
            os_log(OS_LOG_DEFAULT, "[Q3][%{public}s] %{public}s", type, message);
            Q3_FileLogf("[Q3][%s] %s", type, message);
        } else {
            os_log(OS_LOG_DEFAULT, "[Q3] %{public}s", message);
            Q3_FileLogf("[Q3] %s", message);
        }
    }

    if (type != NULL && type[0] != '\0' && message[0] != '\0') {
        Q3DebugTelemetry_Log(type, message);
    }
}

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

static qboolean MetalRenderAuditEnabled(void) {
    return ri.Cvar_VariableIntegerValue("metal_render_audit") != 0;
}

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
    float tcScale;
    qboolean hasSurface;
    float surface[4];
    qboolean hasBounds;
    vec3_t bounds[2];
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
} metalSceneEntity_t;

typedef struct {
    uint32_t firstDraw;
    uint32_t drawCount;
} Q3MetalSurfaceDrawRange;

typedef struct {
    uint32_t drawIndex;
    uint32_t stageIndex;
    uint32_t batchIndex;
} Q3MetalWorldBatchEntry;

typedef struct {
    qboolean loaded;
    uint32_t generation;
    uint32_t vertexCount;
    uint32_t indexCount;
    uint32_t drawCount;
    Q3MetalWorldVertex *vertices;
    uint32_t *indices;
    Q3MetalWorldDrawCmd *draws;
    Q3MetalWorldDrawCmd *visibleDraws;
    Q3MetalWorldBatchCmd *batches;
    uint32_t batchCount;
    uint32_t batchCapacity;
    uint32_t *batchIndices;
    uint32_t batchIndexCount;
    uint32_t batchIndexCapacity;
    Q3MetalWorldBatchEntry *batchEntries;
    uint32_t batchEntryCount;
    uint32_t batchEntryCapacity;
    uint32_t *batchWriteCursors;
    uint32_t batchWriteCursorCapacity;
    uint32_t visibleDrawCount;
    uint32_t visibleDrawCapacity;
    qboolean visibleDrawsValid;
    Q3MetalSurfaceDrawRange *surfaceDrawRanges;
    int surfaceDrawRangeCount;
    int lastViewCluster;
    uint32_t lastAreaMaskHash;
    qboolean lastAreaMaskValid;
    uint32_t visibleVisCount;      /* PVS/node stamp; only changes when cluster changes. */
    uint32_t visibleSurfaceStamp;  /* Per-frame surface dedupe stamp. */
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
    uint32_t fogIndex;
} metalScenePoly_t;

static metalScenePoly_t s_scenePolys[Q3_METAL_MAX_SCENE_POLYS];
static polyVert_t s_scenePolyVerts[Q3_METAL_MAX_SCENE_POLY_VERTS];
static int s_scenePolyCount;
static int s_scenePolyVertCount;

typedef struct {
    qboolean valid;
    vec3_t origin;
    vec3_t axis[3];
} metalPortalSurface_t;

static metalPortalSurface_t s_scenePortalSurface;

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
#define Q3_MAX_STAGES 8
#define METAL_STAGE_AUDIT_MAX 1024
#define METAL_DRAW_PLAN_AUDIT_MAX 2048
#define METAL_ENTITY_STAGE_AUDIT_MAX 1024
#define Q3_GL_ZERO 0x0000u
#define Q3_GL_ONE 0x0001u
#define Q3_GL_SRC_COLOR 0x0300u
#define Q3_GL_ONE_MINUS_SRC_COLOR 0x0301u
#define Q3_GL_SRC_ALPHA 0x0302u
#define Q3_GL_ONE_MINUS_SRC_ALPHA 0x0303u
#define Q3_GL_DST_ALPHA 0x0304u
#define Q3_GL_ONE_MINUS_DST_ALPHA 0x0305u
#define Q3_GL_DST_COLOR 0x0306u
#define Q3_GL_ONE_MINUS_DST_COLOR 0x0307u
/* Q3_MAX_TCMODS and Q3TcMod live in metal_renderer_shared.h so both the
 * stub and Swift bindings share the exact same tcMod chain layout. */

typedef struct {
    char mapPath[MAX_QPATH];
    int blendMode;
    uint32_t rawSrcBlend;
    uint32_t rawDstBlend;
    uint32_t depthFunc;
    int rgbGen;
    int alphaGen;
    int alphaFunc;
    int tcGen;
    /* tcGen vector basis: two world-space vectors. Only consulted when
     * tcGen == 2 (vector). Parsed from `tcGen vector ( x y z ) ( x y z )`.
     * Stored padded as float[4] (xyz + 0) for Swift bridge stability —
     * mirrors Q3MetalWorldStage.tcGenVec0/1 layout. */
    float tcGenVec0[4];
    float tcGenVec1[4];
    /* deformVertexes wave: parsed at shader level, stamped onto every
     * stage on shader close. func=0 means no deform. */
    int deformWaveFunc;
    float deformWaveDiv;
    float deformWaveBase;
    float deformWaveAmp;
    float deformWavePhase;
    float deformWaveFreq;
    int deformMoveFunc;
    float deformMoveVector[3];
    float deformMoveBase;
    float deformMoveAmp;
    float deformMovePhase;
    float deformMoveFreq;
    /* deformVertexes autosprite (1) / autoSprite2 (2). Tag-only for
     * the moment — pipeline awareness lands here so a follow-up
     * commit can wire the camera-aligned transform without touching
     * the parser surface. */
    int autospriteMode;
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
    /* Explicit `depthwrite` keyword on the stage, OR opaque (no
     * blendFunc / blendFunc 0). ioq3 sets depthMaskBits=0 for any
     * blendFunc'd stage UNLESS this bit is set. Without it, blended
     * water/grate floors that author `depthwrite` to occlude correctly
     * (e.g. blocks17gwater) leak the chamber below through the surface. */
    int depthWrite;
    int animFrameCount;
    float animFps;
    char animFrames[METAL_ANIMMAP_MAX_FRAMES][MAX_QPATH];
    qhandle_t animTextures[METAL_ANIMMAP_MAX_FRAMES];
    /* Q3 shader script wrap directive: 0 = repeat (default / `map`),
     * 1 = clamp to edge (`clampmap`). Propagated to Q3MetalWorldStage
     * so the Swift draw loop binds the matching MTLSamplerState. */
    int wrapClampMode;
} Q3MetalStage;

enum {
    METAL_SHADER_CULL_DISABLE = 0,
    METAL_SHADER_CULL_BACK = 1,
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
    qboolean hasLightmapStage;
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

static metalTexture_t *FindTextureByHandle(qhandle_t handle);

static qboolean s_worldMapAuditActive = qfalse;
static char s_stageAuditSeen[METAL_STAGE_AUDIT_MAX][MAX_QPATH];
static int s_stageAuditSeenCount = 0;
static char s_drawPlanAuditSeen[METAL_DRAW_PLAN_AUDIT_MAX][MAX_QPATH];
static int s_drawPlanAuditSeenCount = 0;
static char s_entityStageAuditSeen[METAL_ENTITY_STAGE_AUDIT_MAX][MAX_QPATH];
static int s_entityStageAuditSeenCount = 0;

static void ResetMetalWorldAudits(void) {
    s_worldMapAuditActive = qfalse;
    s_stageAuditSeenCount = 0;
    s_drawPlanAuditSeenCount = 0;
    s_entityStageAuditSeenCount = 0;
    Com_Memset(s_stageAuditSeen, 0, sizeof(s_stageAuditSeen));
    Com_Memset(s_drawPlanAuditSeen, 0, sizeof(s_drawPlanAuditSeen));
    Com_Memset(s_entityStageAuditSeen, 0, sizeof(s_entityStageAuditSeen));
}

static qboolean AuditSeen(char seen[][MAX_QPATH], int *count, int maxCount, const char *key) {
    int i;
    if (key == NULL || key[0] == '\0') {
        return qtrue;
    }
    for (i = 0; i < *count; ++i) {
        if (!Q_stricmp(seen[i], key)) {
            return qtrue;
        }
    }
    if (*count < maxCount) {
        Q_strncpyz(seen[*count], key, MAX_QPATH);
        *count += 1;
    }
    return qfalse;
}

static const char *MetalCullName(int cullMode) {
    switch (cullMode) {
        case METAL_SHADER_CULL_DISABLE: return "none";
        case METAL_SHADER_CULL_FRONT: return "front";
        case METAL_SHADER_CULL_BACK:
        default: return "back";
    }
}

static const char *MetalRgbGenName(int rgbGen) {
    switch (rgbGen) {
        case 1: return "vertex";
        case 2: return "lightingDiffuse";
        case 3: return "wave";
        case 4: return "const";
        case 7: return "identityLighting";
        case 0:
        default: return "identity";
    }
}

static const char *MetalTcGenName(int tcGen) {
    switch (tcGen) {
        case 1: return "environment";
        case 2: return "vector";
        case 0:
        default: return "base";
    }
}

static const char *MetalSrcBlendName(int blendMode) {
    switch (blendMode) {
        case 1: return "GL_SRC_ALPHA";
        case 2: return "GL_SRC_ALPHA";
        case 3: return "GL_DST_COLOR";
        case 4: return "GL_ZERO";
        case 5: return "GL_ONE";
        case 0:
        default: return "GL_ONE";
    }
}

static const char *MetalDstBlendName(int blendMode) {
    switch (blendMode) {
        case 1: return "GL_ONE";
        case 2: return "GL_ONE_MINUS_SRC_ALPHA";
        case 3: return "GL_ZERO";
        case 4: return "GL_ONE_MINUS_SRC_COLOR";
        case 5: return "GL_ONE";
        case 0:
        default: return "GL_ZERO";
    }
}

static const char *MetalRawBlendName(uint32_t factor) {
    switch (factor) {
        case Q3_GL_ZERO: return "GL_ZERO";
        case Q3_GL_ONE: return "GL_ONE";
        case Q3_GL_SRC_COLOR: return "GL_SRC_COLOR";
        case Q3_GL_ONE_MINUS_SRC_COLOR: return "GL_ONE_MINUS_SRC_COLOR";
        case Q3_GL_SRC_ALPHA: return "GL_SRC_ALPHA";
        case Q3_GL_ONE_MINUS_SRC_ALPHA: return "GL_ONE_MINUS_SRC_ALPHA";
        case Q3_GL_DST_ALPHA: return "GL_DST_ALPHA";
        case Q3_GL_ONE_MINUS_DST_ALPHA: return "GL_ONE_MINUS_DST_ALPHA";
        case Q3_GL_DST_COLOR: return "GL_DST_COLOR";
        case Q3_GL_ONE_MINUS_DST_COLOR: return "GL_ONE_MINUS_DST_COLOR";
        default: return "GL_ONE";
    }
}

static int MetalPassForBlendMode(int blendMode) {
    if (blendMode == 5) return 4;
    if (blendMode == 1) return 3;
    if (blendMode == 2) return 2;
    if (blendMode == 3) return 1;
    return 0;
}

static void RawBlendFromMode(int blendMode, uint32_t *src, uint32_t *dst) {
    uint32_t s = Q3_GL_ONE;
    uint32_t d = Q3_GL_ZERO;
    switch (blendMode) {
        case 1: s = Q3_GL_SRC_ALPHA; d = Q3_GL_ONE; break;
        case 2: s = Q3_GL_SRC_ALPHA; d = Q3_GL_ONE_MINUS_SRC_ALPHA; break;
        case 3: s = Q3_GL_DST_COLOR; d = Q3_GL_ZERO; break;
        case 4: s = Q3_GL_ZERO; d = Q3_GL_ONE_MINUS_SRC_COLOR; break;
        case 5: s = Q3_GL_ONE; d = Q3_GL_ONE; break;
        default: break;
    }
    if (src != NULL) *src = s;
    if (dst != NULL) *dst = d;
}

static qboolean MetalStageBlendIsOpaqueForFog(const Q3MetalStage *stage) {
    uint32_t src;
    uint32_t dst;
    if (stage == NULL) {
        return qtrue;
    }
    src = stage->rawSrcBlend;
    dst = stage->rawDstBlend;
    if (src == Q3_GL_ONE && dst == Q3_GL_ZERO) {
        return qtrue;
    }
    /* ioq3 still treats lightmap/filter stages as part of an opaque
     * surface.  Do not classify GL_DST_COLOR/GL_ZERO or
     * GL_ZERO/GL_SRC_COLOR as translucent just because they are blended. */
    if ((src == Q3_GL_DST_COLOR && dst == Q3_GL_ZERO) ||
        (src == Q3_GL_ZERO && dst == Q3_GL_SRC_COLOR)) {
        return qtrue;
    }
    return qfalse;
}

static qboolean MetalShaderShouldEmitFogPass(const metalShaderMap_t *entry,
                                             int emittedStages) {
    int i;
    if (emittedStages <= 0) {
        return qfalse;
    }
    if (entry == NULL || entry->stageCount <= 0) {
        return qtrue;
    }
    if (entry->hasFog) {
        return qtrue;
    }
    for (i = 0; i < entry->stageCount; ++i) {
        if (!MetalStageBlendIsOpaqueForFog(&entry->stages[i])) {
            return qfalse;
        }
    }
    return qtrue;
}

static qboolean MetalVerboseAuditEnabled(void) {
    const char *v = getenv("Q3_VERBOSE_AUDIT");
    return (v != NULL && v[0] == '1');
}

static void MetalAuditShaderName(const char *name, char *out, size_t outSize) {
    char *dot;
    if (out == NULL || outSize == 0) {
        return;
    }
    if (name == NULL) {
        out[0] = '\0';
        return;
    }
    Q_strncpyz(out, name, outSize);
    dot = strrchr(out, '.');
    if (dot == NULL) {
        return;
    }
    if (!Q_stricmp(dot, ".tga") ||
        !Q_stricmp(dot, ".jpg") ||
        !Q_stricmp(dot, ".jpeg") ||
        !Q_stricmp(dot, ".png") ||
        !Q_stricmp(dot, ".pcx")) {
        *dot = '\0';
    }
}

static void EmitMetalStageAudit(const char *shaderName, const metalShaderMap_t *entry) {
    int s;
    if (!s_worldMapAuditActive || shaderName == NULL || entry == NULL || entry->stageCount <= 0) {
        return;
    }
    if (AuditSeen(s_stageAuditSeen, &s_stageAuditSeenCount,
                  METAL_STAGE_AUDIT_MAX, shaderName)) {
        return;
    }
    for (s = 0; s < entry->stageCount; ++s) {
        const Q3MetalStage *st = &entry->stages[s];
        MetalTelemetryPrintf("metal_stage_audit", PRINT_ALL,
            "[metal-stage-audit] shader=%s stage=%d img=%s lm=%d srcBlend=%s dstBlend=%s rgbGen=%s alphaFunc=%d tcGen=%s tcMods=%d depthW=%d cull=%s\n",
            shaderName,
            s,
            st->mapPath[0] ? st->mapPath : "(none)",
            st->useLightmap ? 1 : 0,
            MetalRawBlendName(st->rawSrcBlend),
            MetalRawBlendName(st->rawDstBlend),
            MetalRgbGenName(st->rgbGen),
            st->alphaFunc,
            MetalTcGenName(st->tcGen),
            st->tcModCount,
            st->depthWrite,
            MetalCullName(entry->cullMode));
    }
}

static void EmitMetalDrawPlan(const char *shaderName,
                              int stageIndex,
                              const Q3MetalWorldDrawCmd *draw,
                              const Q3MetalStage *stage,
                              qhandle_t textureHandle,
                              qboolean implicitLightmapBase) {
    char key[MAX_QPATH];
    const metalTexture_t *tex;
    int passIndex;
    qboolean depthWrite;
    if (!s_worldMapAuditActive || shaderName == NULL || draw == NULL || stage == NULL) {
        return;
    }
    passIndex = MetalPassForBlendMode(stage->blendMode);
    depthWrite = (stage->blendMode == 0 || stage->depthWrite != 0) ? qtrue : qfalse;
    Com_sprintf(key, sizeof(key), "%s|%d|%d|%d|%u",
                shaderName, stageIndex, passIndex,
                implicitLightmapBase ? 1 : 0,
                (unsigned)textureHandle);
    if (AuditSeen(s_drawPlanAuditSeen, &s_drawPlanAuditSeenCount,
                  METAL_DRAW_PLAN_AUDIT_MAX, key)) {
        return;
    }
    tex = FindTextureByHandle(textureHandle);
    MetalTelemetryPrintf("metal_draw_plan", PRINT_ALL,
        "[metal-draw-plan] shader=%s stage=%d pass=%d implicitLightmapBase=%d depthTest=1 depthWrite=%d texture=%s fog=%d cull=%s\n",
        shaderName,
        stageIndex,
        passIndex,
        implicitLightmapBase ? 1 : 0,
        depthWrite ? 1 : 0,
        tex ? tex->name : "(none)",
        draw->fogIndex == Q3_METAL_NO_FOG ? -1 : (int)draw->fogIndex,
        MetalCullName(stage->cullMode));
}

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
    texture->isLightmap = (!Q_stricmpn(name, "*lightmap", 9)) ? qtrue : qfalse;
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
    stage->srcBlend = src->rawSrcBlend;
    stage->dstBlend = src->rawDstBlend;
    stage->depthFunc = src->depthFunc;
    stage->tcGen = (uint32_t)src->tcGen;
    /* tcGen vector basis (only meaningful when tcGen == 2). Always copy
     * regardless of mode so stale values don't leak into a later
     * vector-mode stage if the destination slot is reused. */
    for (int k = 0; k < 4; ++k) {
        stage->tcGenVec0[k] = src->tcGenVec0[k];
        stage->tcGenVec1[k] = src->tcGenVec1[k];
    }
    /* deformVertexes wave (shader-level, stamped onto every stage by
     * the parser on shader close). func=0 means no deform. */
    stage->deformWaveFunc  = (uint32_t)src->deformWaveFunc;
    stage->deformWaveDiv   = src->deformWaveDiv;
    stage->deformWaveBase  = src->deformWaveBase;
    stage->deformWaveAmp   = src->deformWaveAmp;
    stage->deformWavePhase = src->deformWavePhase;
    stage->deformWaveFreq  = src->deformWaveFreq;
    stage->deformMoveFunc  = (uint32_t)src->deformMoveFunc;
    stage->deformMoveVector[0] = src->deformMoveVector[0];
    stage->deformMoveVector[1] = src->deformMoveVector[1];
    stage->deformMoveVector[2] = src->deformMoveVector[2];
    stage->deformMoveBase  = src->deformMoveBase;
    stage->deformMoveAmp   = src->deformMoveAmp;
    stage->deformMovePhase = src->deformMovePhase;
    stage->deformMoveFreq  = src->deformMoveFreq;
    /* deformVertexes autosprite/autoSprite2 mode. Tag-only — propagated
     * to a draw flag below so Swift can route to a future autosprite
     * vertex shader path. The actual camera-aligned billboard transform
     * is a follow-up commit. */
    stage->autospriteMode  = (uint32_t)src->autospriteMode;
    /* OR the matching draw-cmd flag bit so Swift / future audits can
     * see which draws are autosprite-shaded without walking stages.
     * Only stage 0's mode counts — Q3 deformVertexes is shader-wide. */
    if (draw->stageCount == 1) {
        if (src->autospriteMode == 1) {
            draw->flags |= Q3_METAL_WORLD_DRAWFLAG_AUTOSPRITE;
        } else if (src->autospriteMode == 2) {
            draw->flags |= Q3_METAL_WORLD_DRAWFLAG_AUTOSPRITE2;
        }
    }
    /* One-shot audit so we can grep '[autosprite-audit]' to see which
     * shaders actually exercise this path on a given map. Bounded to
     * 16 unique handles. */
    if (src->autospriteMode != 0 && MetalVerboseAuditEnabled()) {
        static uint32_t s_autoSeen[16];
        static int s_autoCount = 0;
        int dup = 0;
        for (int j = 0; j < s_autoCount; ++j) {
            if (s_autoSeen[j] == (uint32_t)textureHandle) { dup = 1; break; }
        }
        if (!dup && s_autoCount < 16) {
            const metalTexture_t *t = FindTextureByHandle(textureHandle);
            s_autoSeen[s_autoCount++] = (uint32_t)textureHandle;
            ri.Printf(PRINT_ALL,
                "[autosprite-audit] handle=%u name='%s' mode=%d (1=autosprite, 2=autoSprite2)\n",
                (unsigned)textureHandle,
                t ? t->name : "(no-tex)",
                (int)src->autospriteMode);
        }
    }
    /* One-shot world tcGen=env audit: print up to 16 unique tcGen-env
     * texture handles so we can correlate chrome/reflective surfaces in
     * captures. Fires only when tcGen==1 (environment). */
    if (src->tcGen == 1 && MetalVerboseAuditEnabled()) {
        static uint32_t s_envHandlesSeen[16];
        static int s_envHandlesCount = 0;
        int found = 0;
        for (int j = 0; j < s_envHandlesCount; ++j) {
            if (s_envHandlesSeen[j] == (uint32_t)textureHandle) { found = 1; break; }
        }
        if (!found && s_envHandlesCount < 16) {
            const metalTexture_t *t = FindTextureByHandle(textureHandle);
            s_envHandlesSeen[s_envHandlesCount++] = (uint32_t)textureHandle;
            ri.Printf(PRINT_ALL, "[world-env-audit] handle=%u name='%s' blend=%u\n",
                      (unsigned)textureHandle,
                      t ? t->name : "(no-tex)",
                      (unsigned)src->blendMode);
        }
    }
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
     * METAL_SHADER_CULL_DISABLE=0 / BACK=1 / FRONT=2; Swift consumes
     * this directly when picking setCullMode per draw. */
    stage->cullMode = (uint32_t)src->cullMode;
    stage->useLightmap = (uint32_t)src->useLightmap;
    /* Explicit `depthwrite` keyword OR opaque base stage. ioq3 sets
     * GLS_DEPTHMASK_TRUE for these; we forward the bit so Swift can
     * pick a depth-write-ON state even on a filter/alpha/additive
     * pass. Opaque stages (blendMode==0) implicitly get depth-write
     * via the opaque pipeline anyway, so this bit only matters for
     * blended stages. */
    stage->depthWrite = (uint32_t)src->depthWrite;
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
    stage->rgbConstColor[0] = (src->rgbGen == 4) ? src->rgbConstColor[0] : 1.0f;
    stage->rgbConstColor[1] = (src->rgbGen == 4) ? src->rgbConstColor[1] : 1.0f;
    stage->rgbConstColor[2] = (src->rgbGen == 4) ? src->rgbConstColor[2] : 1.0f;
    stage->alphaConst = (src->alphaGen == 4) ? src->alphaConst : 1.0f;
    /* Q3 `clampmap` directive — propagated from the parser through
     * Q3MetalStage. Swift draw loop reads stage.wrapClampMode to pick
     * between worldSamplerState (.repeat) and uiSamplerState
     * (.clampToEdge). Replaces the coarse all-entity-clamp hack from
     * MetalView.swift lines 3267/3504/4330 that killed the quad-damage
     * breathing shell on viewmodels. */
    stage->wrapClampMode = (uint32_t)src->wrapClampMode;
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
    RawBlendFromMode(blendMode, &tmp.rawSrcBlend, &tmp.rawDstBlend);
    tmp.rgbGen = rgbGen;
    tmp.rgbConstColor[0] = 1.0f;
    tmp.rgbConstColor[1] = 1.0f;
    tmp.rgbConstColor[2] = 1.0f;
    tmp.alphaConst = 1.0f;
    tmp.alphaFunc = alphaFunc;
    tmp.cullMode = METAL_SHADER_CULL_BACK;
    AddWorldDrawStage(draw, textureHandle, &tmp);
}

/* True iff `entry` already has at least one stage with useLightmap=1.
 * Used to decide whether to inject an implicit lightmap-multiply pass
 * for shaders that don't explicitly declare `map $lightmap`. */
static qboolean shaderHasExplicitLightmapStage(const metalShaderMap_t *entry) {
    int i;
    if (entry == NULL) return qfalse;
    for (i = 0; i < entry->stageCount; ++i) {
        if (entry->stages[i].useLightmap) return qtrue;
    }
    return qfalse;
}

/* True iff this is a "normal diffuse world" shader that should receive
 * the implicit lightmap multiply pass. Excludes emissive light fixtures
 * (additive blend), alpha-blended decals, and effect shaders so the
 * implicit pass doesn't crush ceiling lights into darkness. Stock Q3's
 * R_StageIteratorGeneric adds the implicit lightmap on first-stage-
 * opaque shaders only. */
static qboolean shaderShouldInjectImplicitLightmap(const metalShaderMap_t *entry) {
    int i;
    if (entry == NULL || entry->stageCount <= 0) return qtrue; /* unknown shader → default to lit */
    if (shaderHasExplicitLightmapStage(entry)) return qfalse;
    /* Skip when any stage uses a non-opaque blend: additive, alpha-
     * modulated additive, alpha, filter, subtract, full-add. Q3 light
     * fixtures and glow surfaces author themselves like this and are
     * meant to be fullbright. */
    for (i = 0; i < entry->stageCount; ++i) {
        int bm = (int)entry->stages[i].blendMode;
        if (bm != 0) return qfalse; /* 0 = opaque GL_ONE/GL_ZERO */
    }
    return qtrue;
}

static int MetalShaderCombinedLightmapBaseStage(const metalShaderMap_t *entry,
                                                qboolean hasLightmap,
                                                qhandle_t lightmapHandle) {
    if (!hasLightmap || lightmapHandle == 0) {
        return -1;
    }
    if (entry == NULL || entry->stageCount <= 0) {
        return 0;
    }
    if (entry->hasFog) {
        return -1;
    }
    if (entry->stageCount == 1 && shaderShouldInjectImplicitLightmap(entry)) {
        return 0;
    }
    if (entry->stageCount >= 2 &&
        !entry->stages[0].useLightmap &&
        entry->stages[0].blendMode == 0 &&
        entry->stages[1].useLightmap &&
        entry->stages[1].blendMode == 3) {
        return 0;
    }
    if (entry->stageCount >= 2 &&
        entry->stages[0].useLightmap &&
        !entry->stages[1].useLightmap &&
        entry->stages[1].blendMode == 3) {
        return 1;
    }
    return -1;
}

static void AddWorldDrawLightmapBaseStage(Q3MetalWorldDrawCmd *draw,
                                          qhandle_t lightmapHandle,
                                          const metalShaderMap_t *entry,
                                          int blendMode,
                                          int depthWrite) {
    Q3MetalStage tmp;
    Com_Memset(&tmp, 0, sizeof(tmp));
    if (entry != NULL && entry->stageCount > 0) {
        tmp.deformWaveFunc = entry->stages[0].deformWaveFunc;
        tmp.deformWaveDiv = entry->stages[0].deformWaveDiv;
        tmp.deformWaveBase = entry->stages[0].deformWaveBase;
        tmp.deformWaveAmp = entry->stages[0].deformWaveAmp;
        tmp.deformWavePhase = entry->stages[0].deformWavePhase;
        tmp.deformWaveFreq = entry->stages[0].deformWaveFreq;
        tmp.deformMoveFunc = entry->stages[0].deformMoveFunc;
        tmp.deformMoveVector[0] = entry->stages[0].deformMoveVector[0];
        tmp.deformMoveVector[1] = entry->stages[0].deformMoveVector[1];
        tmp.deformMoveVector[2] = entry->stages[0].deformMoveVector[2];
        tmp.deformMoveBase = entry->stages[0].deformMoveBase;
        tmp.deformMoveAmp = entry->stages[0].deformMoveAmp;
        tmp.deformMovePhase = entry->stages[0].deformMovePhase;
        tmp.deformMoveFreq = entry->stages[0].deformMoveFreq;
        tmp.autospriteMode = entry->stages[0].autospriteMode;
    }
    tmp.blendMode = blendMode;
    RawBlendFromMode(blendMode, &tmp.rawSrcBlend, &tmp.rawDstBlend);
    tmp.rgbGen = 0;
    tmp.alphaGen = 0;
    tmp.cullMode = entry != NULL ? entry->cullMode : METAL_SHADER_CULL_BACK;
    tmp.depthWrite = depthWrite;
    tmp.useLightmap = 1;
    AddWorldDrawStage(draw, lightmapHandle, &tmp);
}

/* Forward-decl so SetEntityDrawColor can invoke the helper defined
 * immediately below it. Both functions are static and adjacent — the
 * forward decl keeps the diff tight without reordering large blocks. */
static void CopyTextureTcModsToDrawCmd(uint32_t cursor, qhandle_t textureHandle);

/* Copy refEntity_t.shader.rgba into the per-draw entityColor slot so
 * MSL rgbGen=entity / alphaGen=entity / oneMinusEntity branches can
 * reach it without fishing it back out of the per-vertex color (which
 * has Lambert diffuse already baked in). Mirrors the shader.rgba[3]==0
 * → default-white convention used by the per-vertex color path.
 *
 * textureHandle is the draw cmd's bound texture — used to copy the
 * texture's stage-0 tcMod chain into the per-entity draw cmd so the
 * Swift entity vertex shader can apply scroll/scale/rotate UV
 * transforms. Without this hop the customShader entity draws had no
 * UV animation: quad shell chrome / regen shimmer / battlesuit pulse
 * all rendered static instead of scrolling. Pass 0 if the caller
 * cannot supply a texture handle — the tcMod chain falls back to
 * count=0 (identity transform). */
static void SetEntityDrawColor(uint32_t cursor, const refEntity_t *e, qhandle_t textureHandle) {
    if (e != NULL && e->shader.rgba[3] != 0) {
        s_entityDraws[cursor].entityColor[0] = (float)e->shader.rgba[0] / 255.0f;
        s_entityDraws[cursor].entityColor[1] = (float)e->shader.rgba[1] / 255.0f;
        s_entityDraws[cursor].entityColor[2] = (float)e->shader.rgba[2] / 255.0f;
        s_entityDraws[cursor].entityColor[3] = (float)e->shader.rgba[3] / 255.0f;
    } else {
        s_entityDraws[cursor].entityColor[0] = 1.0f;
        s_entityDraws[cursor].entityColor[1] = 1.0f;
        s_entityDraws[cursor].entityColor[2] = 1.0f;
        s_entityDraws[cursor].entityColor[3] = 1.0f;
    }
    s_entityDraws[cursor].shaderTime =
        (float)cls.realtime * 0.001f - (e != NULL ? e->shaderTime.f : 0.0f);
    /* tcMod chain copy via the helper below. Order doesn't matter since
     * tcMod fields are independent of entityColor / shaderTime. */
    CopyTextureTcModsToDrawCmd(cursor, textureHandle);
}

/* Copy a texture's stage-0 tcMod chain into the per-entity draw cmd so
 * the Swift entity vertex shader can apply scroll/scale/rotate/stretch
 * UV transforms. Without this hop, customShader entity draws had no UV
 * animation — quad shell chrome stayed static, regen/battlesuit shimmers
 * didn't animate. Mirrors the per-stage tcMod plumbing already present
 * on Q3MetalWorldStage for the world pipeline. Called adjacent to
 * SetEntityDrawColor at every entity emit site. Safe to call on draws
 * whose texture has no tcMods (count stays 0, shader applies identity). */
static void CopyTextureTcModsToDrawCmd(uint32_t cursor, qhandle_t textureHandle) {
    const metalTexture_t *tex = FindTextureByHandle(textureHandle);
    int n, i;
    if (tex == NULL) {
        s_entityDraws[cursor].tcModCount = 0;
        return;
    }
    n = (int)tex->tcModCount;
    if (n < 0) n = 0;
    if (n > Q3_MAX_TCMODS) n = Q3_MAX_TCMODS;
    s_entityDraws[cursor].tcModCount = (uint32_t)n;
    for (i = 0; i < n; ++i) {
        s_entityDraws[cursor].tcMods[i] = tex->tcMods[i];
    }
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
    /* Menu medals are circular alpha-masked badges authored as TGAs
     * (menu/medals/medal_assist.tga etc., pak4/pak5). If the .tga is
     * absent and we land on a JPG fallback, synthesize alpha so the
     * badge doesn't render as an opaque rectangle. */
    if (!Q_stricmpn(path, "menu/medals/", 12)) return qtrue;
    /* HUD icons (weapon, ammo, health, armor) are alpha-masked sprites
     * with transparent backgrounds. Same JPG-fallback risk. */
    if (!Q_stricmpn(path, "icons/", 6)) return qtrue;
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

/* Try loading <base><ext> for ext in {.tga, .jpg, .jpeg}. Returns true
 * on first success, populates rgba/width/height and resolvedName. */
static qboolean TryLoadExtChain(const char *origName, const char *base,
                                byte **rgba, int *width, int *height,
                                char *resolvedName, size_t resolvedNameSize) {
    static const char *extensions[] = { ".tga", ".jpg", ".jpeg" };
    int i;
    for (i = 0; i < (int)ARRAY_LEN(extensions); ++i) {
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
            if (isJpg && TextureNeedsLuminanceAlpha(origName)) {
                SynthesizeAlphaFromLuminance(*rgba, *width, *height);
            }
            Q_strncpyz(resolvedName, candidate, resolvedNameSize);
            return qtrue;
        }
    }
    return qfalse;
}

static qboolean TryLoadImageRGBA(const char *name, byte **rgba, int *width, int *height, char *resolvedName, size_t resolvedNameSize) {
    char base[MAX_QPATH];
    const char *ext;

    *rgba = NULL;
    *width = 0;
    *height = 0;

    Q_strncpyz(base, name, sizeof(base));
    ext = COM_GetExtension(base);
    if (ext[0] != '\0') {
        COM_StripExtension(base, base, sizeof(base));
    }

    /* (1) requested-case extension chain. */
    if (TryLoadExtChain(name, base, rgba, width, height, resolvedName, resolvedNameSize)) {
        return qtrue;
    }

    /* (2) Case-folded basename retry. iOS pak files (zip) are
     * case-sensitive but stock Q3 ships levelshots and a handful of
     * other paths with uppercase basenames (`levelshots/Q3DM1.jpg`,
     * etc.) that the UI requests in lowercase. Try uppercasing just
     * the filename portion (preserve directory case so `MENU/ART/`
     * isn't generated). */
    {
        char upperBase[MAX_QPATH];
        Q_strncpyz(upperBase, base, sizeof(upperBase));
        char *fname = strrchr(upperBase, '/');
        fname = fname ? (fname + 1) : upperBase;
        Q_strupr(fname);
        if (Q_stricmp(upperBase, base) != 0) {
            if (TryLoadExtChain(name, upperBase, rgba, width, height, resolvedName, resolvedNameSize)) {
                return qtrue;
            }
        }
    }

    /* (3) `_df` (deferred icon) strip fallback. Stock Q3 has
     * `icons/iconw_machinegun.tga` but cgame's UI code requests
     * the deferred-load variant `icons/iconw_machinegun_df` which
     * was never shipped. Drop the suffix and retry rather than
     * fall through to white. */
    {
        size_t blen = strlen(base);
        if (blen > 3 && !Q_stricmp(base + blen - 3, "_df")) {
            char stripped[MAX_QPATH];
            Q_strncpyz(stripped, base, sizeof(stripped));
            stripped[blen - 3] = '\0';
            if (TryLoadExtChain(name, stripped, rgba, width, height, resolvedName, resolvedNameSize)) {
                return qtrue;
            }
        }
    }

    return qfalse;
}

static const char *ShaderMap_Lookup(const char *name);
static qhandle_t ShaderMap_ResolveCurrentFrame(const char *name);
static int ShaderMap_FindAnimatedSlot(const char *name);
static qhandle_t ShaderMap_AnimatedSlotCurrentHandle(int slot, float shaderTime);
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
static void ShaderMap_GetDeformWave(const char *name, int *func, float *div, float *base,
                                    float *amp, float *phase, float *freq);
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

    /* Some stock/custom shader scripts contain accidental duplicate path
     * separators (pak0 base_wall.shader has textures//base_wall/...).
     * id FS tolerates this, but our direct image loader/key cache did not,
     * causing a white fallback on nv15. Canonicalize before lookup/load. */
    {
        char cleanName[MAX_QPATH];
        int si = 0;
        int di = 0;
        qboolean changed = qfalse;
        char prev = '\0';
        while (name[si] != '\0' && di < (int)sizeof(cleanName) - 1) {
            char c = name[si++];
            if (c == '\\') {
                c = '/';
                changed = qtrue;
            }
            if (c == '/' && prev == '/') {
                changed = qtrue;
                continue;
            }
            cleanName[di++] = c;
            prev = c;
        }
        cleanName[di] = '\0';
        if (changed && cleanName[0] != '\0') {
            return RegisterTexture(cleanName);
        }
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
            /* Demoted to DEVELOPER — PRINT_ALL drowned out actual
             * diagnostics. Use `\developer 1` from the console to
             * re-enable per-asset request tracing. */
            MetalTelemetryPrintf("metal_asset_request", PRINT_DEVELOPER, "Metal asset request: '%s'\n", name);
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
                animTex->blendMode = ShaderMap_GetBlendMode(name);
                animTex->alphaFunc = ShaderMap_GetAlphaFunc(name);
                animTex->tcGenEnv = ShaderMap_GetTcGenEnv(name);
                animTex->rgbGen = ShaderMap_GetRgbGen(name);
                animTex->alphaGen = ShaderMap_GetAlphaGen(name);
                ShaderMap_GetRgbWave(name, &animTex->rgbWaveFunc,
                                     &animTex->rgbWaveBase, &animTex->rgbWaveAmp,
                                     &animTex->rgbWavePhase, &animTex->rgbWaveFreq);
                ShaderMap_GetAlphaWave(name, &animTex->alphaWaveFunc,
                                       &animTex->alphaWaveBase, &animTex->alphaWaveAmp,
                                       &animTex->alphaWavePhase, &animTex->alphaWaveFreq);
                ShaderMap_GetRgbConst(name, animTex->rgbConstColor);
                animTex->alphaConst = ShaderMap_GetAlphaConst(name);
                ShaderMap_GetTcMods(name, &animTex->tcModCount, animTex->tcMods);
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
             * name. The returned handle is the shared white texture.
             * Structured `[asset-miss]` log lets future agents grep by
             * category and see the resolution path that was tried. */
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
                /* Categorize by leading path so the user can quickly
                 * triage which subsystem to investigate. */
                const char *cat = "other";
                if      (!Q_stricmpn(name, "menu/",        5))  cat = "menu";
                else if (!Q_stricmpn(name, "ui/",          3))  cat = "ui";
                else if (!Q_stricmpn(name, "levelshots/", 11)) cat = "levelshot";
                else if (!Q_stricmpn(name, "icons/",       6))  cat = "icon";
                else if (!Q_stricmpn(name, "powerups/",    9))  cat = "powerup";
                else if (!Q_stricmpn(name, "sprites/",     8))  cat = "sprite";
                else if (!Q_stricmpn(name, "gfx/",         4))  cat = "gfx";
                else if (!Q_stricmpn(name, "models/",      7))  cat = "model";
                else if (!Q_stricmpn(name, "textures/",    9))  cat = "world";
                MetalTelemetryPrintf("metal_asset_miss", PRINT_WARNING,
                    "[asset-miss] cat=%s name='%s' shader=%s mapPath='%s' stages=%d\n",
                    cat, name,
                    entry ? "found" : "notfound",
                    (entry && entry->mapPath[0]) ? entry->mapPath : "(empty)",
                    entry ? entry->stageCount : 0);
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
    /* Shader-level deformVertexes wave (entity halo). The shader-map's
     * stage 0 carries the parsed values; without this propagation,
     * customShader textures (powerups/quadWeapon, powerups/quad, regen,
     * battlesuit) leave texture->deformWaveFunc at 0 and the entity
     * vertex shader skips the offset → halo collapses into silhouette. */
    ShaderMap_GetDeformWave(name, &texture->deformWaveFunc,
                            &texture->deformWaveDiv, &texture->deformWaveBase,
                            &texture->deformWaveAmp, &texture->deformWavePhase,
                            &texture->deformWaveFreq);
    if (Q_stricmp(name, resolvedName)) {
        MetalTelemetryPrintf("metal_asset_loaded", PRINT_ALL, "Metal stub: loaded '%s' from '%s' (%dx%d)\n", name, resolvedName, width, height);
    }
    return texture->handle;
}

static qboolean IsPickupEntityShaderName(const char *name) {
    return name != NULL &&
        (!Q_stricmpn(name, "models/powerups/health/", 23) ||
         !Q_stricmpn(name, "models/powerups/ammo/", 21));
}

static int EntityPickupStageDrawCount(const char *shaderName) {
    const metalShaderMap_t *entry;
    int i, count = 0;
    if (!IsPickupEntityShaderName(shaderName)) return 0;
    entry = ShaderMap_LookupEntry(shaderName);
    if (entry == NULL || entry->stageCount <= 1) return 0;
    for (i = 0; i < entry->stageCount; ++i) {
        if (!entry->stages[i].useLightmap && entry->stages[i].mapPath[0] != '\0') count++;
    }
    return count;
}

static void CopyStageMetadataToTexture(metalTexture_t *texture, const Q3MetalStage *stage) {
    int i;
    texture->blendMode = stage->blendMode;
    texture->alphaFunc = stage->alphaFunc;
    texture->tcGenEnv = (stage->tcGen == 1);
    texture->rgbGen = stage->rgbGen;
    texture->alphaGen = stage->alphaGen;
    texture->rgbWaveFunc = stage->rgbWaveFunc;
    texture->rgbWaveBase = stage->rgbWaveBase;
    texture->rgbWaveAmp = stage->rgbWaveAmp;
    texture->rgbWavePhase = stage->rgbWavePhase;
    texture->rgbWaveFreq = stage->rgbWaveFreq;
    texture->alphaWaveFunc = stage->alphaWaveFunc;
    texture->alphaWaveBase = stage->alphaWaveBase;
    texture->alphaWaveAmp = stage->alphaWaveAmp;
    texture->alphaWavePhase = stage->alphaWavePhase;
    texture->alphaWaveFreq = stage->alphaWaveFreq;
    texture->rgbConstColor[0] = stage->rgbConstColor[0];
    texture->rgbConstColor[1] = stage->rgbConstColor[1];
    texture->rgbConstColor[2] = stage->rgbConstColor[2];
    texture->alphaConst = stage->alphaConst;
    texture->tcModCount = stage->tcModCount;
    for (i = 0; i < Q3_MAX_TCMODS; ++i) texture->tcMods[i] = stage->tcMods[i];
    texture->wrapClampMode = stage->wrapClampMode;
    texture->deformWaveFunc  = (int)stage->deformWaveFunc;
    texture->deformWaveDiv   = stage->deformWaveDiv;
    texture->deformWaveBase  = stage->deformWaveBase;
    texture->deformWaveAmp   = stage->deformWaveAmp;
    texture->deformWavePhase = stage->deformWavePhase;
    texture->deformWaveFreq  = stage->deformWaveFreq;
}

static qhandle_t RegisterEntityStageTexture(const char *shaderName, int stageIndex) {
    const metalShaderMap_t *entry = ShaderMap_LookupEntry(shaderName);
    const Q3MetalStage *stage;
    char alias[MAX_QPATH];
    qhandle_t baseHandle;
    metalTexture_t *base;
    metalTexture_t *texture;

    if (entry == NULL || stageIndex < 0 || stageIndex >= entry->stageCount) return 0;
    stage = &entry->stages[stageIndex];
    if (stage->useLightmap || stage->mapPath[0] == '\0') return 0;

    Com_sprintf(alias, sizeof(alias), "*entity-stage:%d:%s", stageIndex, shaderName);
    texture = FindTextureByName(alias);
    if (texture != NULL) return texture->handle;

    baseHandle = RegisterTexture(stage->mapPath);
    base = FindTextureByHandle(baseHandle);
    if (base == NULL || base->rgbaBytes == NULL) return 0;

    texture = AllocTextureSlot();
    if (texture == NULL) return 0;
    Q_strncpyz(texture->name, alias, sizeof(texture->name));
    texture->width = base->width;
    texture->height = base->height;
    texture->rgbaBytes = base->rgbaBytes;
    texture->generation = base->generation;
    CopyStageMetadataToTexture(texture, stage);
    return texture->handle;
}

static void EmitMetalEntityStageAudit(const char *shaderName, const char *source) {
    const metalShaderMap_t *entry;
    char auditName[MAX_QPATH];
    int s;
    if (!s_worldMapAuditActive || shaderName == NULL || shaderName[0] == '\0') {
        return;
    }
    entry = ShaderMap_LookupEntry(shaderName);
    if (entry == NULL || entry->stageCount <= 0) {
        return;
    }
    MetalAuditShaderName(shaderName, auditName, sizeof(auditName));
    if (AuditSeen(s_entityStageAuditSeen, &s_entityStageAuditSeenCount,
                  METAL_ENTITY_STAGE_AUDIT_MAX, auditName)) {
        return;
    }
    for (s = 0; s < entry->stageCount; ++s) {
        const Q3MetalStage *st = &entry->stages[s];
        MetalTelemetryPrintf("metal_entity_stage_audit", PRINT_ALL,
            "[metal-entity-stage-audit] shader=%s source=%s stage=%d img=%s lm=%d srcBlend=%s dstBlend=%s rgbGen=%s alphaFunc=%d tcGen=%s tcMods=%d depthW=%d cull=%s\n",
            auditName,
            (source != NULL && source[0] != '\0') ? source : "entity",
            s,
            st->mapPath[0] ? st->mapPath : "(none)",
            st->useLightmap ? 1 : 0,
            MetalSrcBlendName(st->blendMode),
            MetalDstBlendName(st->blendMode),
            MetalRgbGenName(st->rgbGen),
            st->alphaFunc,
            MetalTcGenName(st->tcGen),
            st->tcModCount,
            st->depthWrite,
            MetalCullName(entry->cullMode));
    }
}

static void EmitMetalEntityStageAuditForHandle(qhandle_t textureHandle, const char *source) {
    const metalTexture_t *tex = FindTextureByHandle(textureHandle);
    if (tex == NULL) {
        return;
    }
    EmitMetalEntityStageAudit(tex->name, source);
}

static uint32_t EntityFlagsForTexture(qhandle_t textureHandle, uint32_t flags, qboolean allowFxFallback) {
    const metalTexture_t *tex = FindTextureByHandle(textureHandle);
    if (tex == NULL) return flags;
    if (tex->blendMode == 1) flags |= Q3_METAL_ENTITY_DRAWFLAG_ADDITIVE;
    else if (tex->blendMode == 2) flags |= Q3_METAL_ENTITY_DRAWFLAG_ALPHA;
    else if (tex->blendMode == 3) flags |= Q3_METAL_ENTITY_DRAWFLAG_FILTER;
    else if (tex->blendMode == 4) flags |= Q3_METAL_ENTITY_DRAWFLAG_SUBTRACT;
    else if (tex->blendMode == 5) flags |= Q3_METAL_ENTITY_DRAWFLAG_ADDITIVE_FULL;
    else if (allowFxFallback) {
        const char *n = tex->name;
        if (n[0] != '\0' &&
            (!Q_stricmpn(n, "models/weaphits/", 16) ||
             !Q_stricmpn(n, "sprites/", 8) ||
             !Q_stricmpn(n, "gfx/damage/", 11) ||
             !Q_stricmpn(n, "gfx/misc/", 9))) {
            flags |= Q3_METAL_ENTITY_DRAWFLAG_ADDITIVE;
        }
    }
    if (tex->tcGenEnv) flags |= Q3_METAL_ENTITY_DRAWFLAG_TCGEN_ENV;
    /* Sampler-wrap routing. Three triggers force clampToEdge:
     *   1. Explicit `clampmap` directive in the shader script
     *      (wrapClampMode == 1). Always clamps. HUD icons, dlight
     *      projection discs, deliberate clamp content.
     *   2. Animated tcMod (scroll / rotate / etc) on a non-environment
     *      `tcGen base` stage. These are 2D-billboard sprites where the
     *      animated UVs WILL go outside [0,1] and Q3 reference relies on
     *      transparent border padding to fade out via clamp. With repeat
     *      the wrap exposes the sprite quad's polygon edges (visible
     *      on plasma bolts, gauntlet fx, muzzle-flash sprites).
     *   3. (rule 2 explicitly EXCLUDES tcGen environment) Chrome shells
     *      with animated tcMod (quad damage breathing shell, megahealth
     *      orb) MUST stay on repeat — the envmap is seamless and clamp
     *      would freeze the shimmer at the edge texel.
     *
     * Logic table:
     *   wrapClampMode=1                  → CLAMP (rule 1)
     *   tcMods>0 && !tcGenEnv            → CLAMP (rule 2)
     *   tcMods>0 &&  tcGenEnv            → repeat (chrome shell)
     *   tcMods=0 (static)                → repeat (typical world / model
     *                                       textures, also any unanimated
     *                                       clampmap stage handled by rule 1) */
    if (tex->wrapClampMode ||
        (tex->tcModCount > 0 && !tex->tcGenEnv)) {
        flags |= Q3_METAL_ENTITY_DRAWFLAG_CLAMPMAP;
    }
    return flags;
}

static int MetalRailCvarInteger(const char *name, int fallback) {
    cvar_t *cv = ri.Cvar_Get(name, va("%d", fallback), CVAR_ARCHIVE);
    return (cv != NULL && cv->integer > 0) ? cv->integer : fallback;
}

static float MetalRailCvarValue(const char *name, float fallback) {
    cvar_t *cv = ri.Cvar_Get(name, va("%g", fallback), CVAR_ARCHIVE);
    return (cv != NULL && cv->value > 0.0f) ? cv->value : fallback;
}

static void MetalSetEntityVertex(uint32_t index, const vec3_t xyz,
                                 float s, float t,
                                 float r, float g, float b, float a) {
    s_entityVertices[index].position[0] = xyz[0];
    s_entityVertices[index].position[1] = xyz[1];
    s_entityVertices[index].position[2] = xyz[2];
    s_entityVertices[index].texCoord[0] = s;
    s_entityVertices[index].texCoord[1] = t;
    s_entityVertices[index].color[0] = r;
    s_entityVertices[index].color[1] = g;
    s_entityVertices[index].color[2] = b;
    s_entityVertices[index].color[3] = a;
    s_entityVertices[index].normal[0] = 0.0f;
    s_entityVertices[index].normal[1] = 0.0f;
    s_entityVertices[index].normal[2] = 0.0f;
}

static void MetalEmitRailCore(uint32_t *vertexCursor,
                              uint32_t *indexCursor,
                              const vec3_t start,
                              const vec3_t end,
                              const vec3_t up,
                              float len,
                              float spanWidth,
                              float r,
                              float g,
                              float b,
                              float a) {
    uint32_t vbase = *vertexCursor;
    vec3_t p0, p1, p2, p3;
    float t = len / 256.0f;

    VectorMA(start, spanWidth, up, p0);
    VectorMA(start, -spanWidth, up, p1);
    VectorMA(end, spanWidth, up, p2);
    VectorMA(end, -spanWidth, up, p3);

    MetalSetEntityVertex(vbase + 0, p0, 0.0f, 0.0f, r * 0.25f, g * 0.25f, b * 0.25f, a);
    MetalSetEntityVertex(vbase + 1, p1, 0.0f, 1.0f, r, g, b, a);
    MetalSetEntityVertex(vbase + 2, p2, t,    0.0f, r, g, b, a);
    MetalSetEntityVertex(vbase + 3, p3, t,    1.0f, r, g, b, a);

    s_entityIndices[*indexCursor + 0] = vbase + 0;
    s_entityIndices[*indexCursor + 1] = vbase + 1;
    s_entityIndices[*indexCursor + 2] = vbase + 2;
    s_entityIndices[*indexCursor + 3] = vbase + 2;
    s_entityIndices[*indexCursor + 4] = vbase + 1;
    s_entityIndices[*indexCursor + 5] = vbase + 3;

    *vertexCursor += 4;
    *indexCursor += 6;
}

static int MetalScenePolyFogIndex(const polyVert_t *verts, int numVerts) {
    vec3_t bounds[2];
    int i;
    int fogIndex;

    if (!s_world.loaded || s_worldFogCount <= 0 || verts == NULL || numVerts <= 0) {
        return -1;
    }

    VectorCopy(verts[0].xyz, bounds[0]);
    VectorCopy(verts[0].xyz, bounds[1]);
    for (i = 1; i < numVerts; ++i) {
        AddPointToBounds(verts[i].xyz, bounds[0], bounds[1]);
    }

    for (fogIndex = 0; fogIndex < s_worldFogCount; ++fogIndex) {
        const metalWorldFog_t *fog = &s_worldFogs[fogIndex];
        if (!fog->hasBounds) {
            continue;
        }
        if (bounds[1][0] >= fog->bounds[0][0] &&
            bounds[1][1] >= fog->bounds[0][1] &&
            bounds[1][2] >= fog->bounds[0][2] &&
            bounds[0][0] <= fog->bounds[1][0] &&
            bounds[0][1] <= fog->bounds[1][1] &&
            bounds[0][2] <= fog->bounds[1][2]) {
            return fogIndex;
        }
    }

    return -1;
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

/* Parallel BSP world (see block below LoadWorldMapData) — forward decl. */
static void BspFreeWorld(void);

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
    if (s_world.visibleDraws != NULL) {
        ri.Free(s_world.visibleDraws);
    }
    if (s_world.batches != NULL) {
        ri.Free(s_world.batches);
    }
    if (s_world.batchIndices != NULL) {
        ri.Free(s_world.batchIndices);
    }
    if (s_world.batchEntries != NULL) {
        ri.Free(s_world.batchEntries);
    }
    if (s_world.batchWriteCursors != NULL) {
        ri.Free(s_world.batchWriteCursors);
    }
    if (s_world.surfaceDrawRanges != NULL) {
        ri.Free(s_world.surfaceDrawRanges);
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

    /* Parallel BSP tree cleanup — additive, map-scoped. */
    BspFreeWorld();
    ResetMetalWorldAudits();
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

#define Q3_METAL_PATCH_SUBDIVISIONS 4

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

/* Forward decl: SampleLightgrid is defined later in this file. EmitWorldVertex
 * needs it to compute per-vertex lightingDiffuse at world load. */
static void SampleLightgrid(const vec3_t worldPos, vec3_t outAmbient, vec3_t outDirected, vec3_t outLightDir);

static void EmitWorldVertex(Q3MetalWorldVertex *dest, const drawVert_t *source) {
    dest->position[0] = LittleFloat(source->xyz[0]);
    dest->position[1] = LittleFloat(source->xyz[1]);
    dest->position[2] = LittleFloat(source->xyz[2]);
    dest->texCoord[0] = LittleFloat(source->st[0]);
    dest->texCoord[1] = LittleFloat(source->st[1]);
    dest->lightmapTexCoord[0] = LittleFloat(source->lightmap[0]);
    dest->lightmapTexCoord[1] = LittleFloat(source->lightmap[1]);
    /* drawVert_t.normal is filled by q3map2 for face/trisurf and by
     * BspMakeMeshNormals for grid patches. Copy through verbatim so the
     * fragment shader can do smooth env-map reflections on curved
     * surfaces. */
    dest->normal[0] = LittleFloat(source->normal[0]);
    dest->normal[1] = LittleFloat(source->normal[1]);
    dest->normal[2] = LittleFloat(source->normal[2]);
    dest->color[0] = ByteToVisibleColor(source->color.rgba[0]);
    dest->color[1] = ByteToVisibleColor(source->color.rgba[1]);
    dest->color[2] = ByteToVisibleColor(source->color.rgba[2]);
    dest->color[3] = 1.0f;
    /* Default to zero — `BakeAutospriteCenters` overwrites for the
     * subset of vertices belonging to autosprite quads. Vertex shader
     * detects "no autosprite" via length(autospriteCenter.xyz) ≈ 0. */
    dest->autospriteCenter[0] = 0.0f;
    dest->autospriteCenter[1] = 0.0f;
    dest->autospriteCenter[2] = 0.0f;
    dest->autospriteCenter[3] = 0.0f;
    dest->autospriteLongAxis[0] = 0.0f;
    dest->autospriteLongAxis[1] = 0.0f;
    dest->autospriteLongAxis[2] = 0.0f;
    dest->autospriteLongAxis[3] = 0.0f;
    /* CGEN_LIGHTING_DIFFUSE per-vertex: sample the BSP lightgrid at
     * this vertex's world position and Lambert against its normal.
     * Mirrors ioq3 R_LightForPoint + RB_CalcDiffuseColor (ent->ambient +
     * ent->directed * max(0, dot(N, L))) applied to world surfaces.
     * Returns identity when the lightgrid isn't loaded — same fallback
     * SampleLightgrid uses internally. */
    {
        vec3_t worldPos, vNormal, ambient, directed, lightDir;
        float incoming;
        int c;
        worldPos[0] = dest->position[0];
        worldPos[1] = dest->position[1];
        worldPos[2] = dest->position[2];
        vNormal[0] = dest->normal[0];
        vNormal[1] = dest->normal[1];
        vNormal[2] = dest->normal[2];
        SampleLightgrid(worldPos, ambient, directed, lightDir);
        incoming = DotProduct(vNormal, lightDir);
        if (incoming < 0.0f) incoming = 0.0f;
        for (c = 0; c < 3; ++c) {
            float v = ambient[c] + directed[c] * incoming;
            if (v > 1.0f) v = 1.0f;
            dest->lightingDiffuse[c] = v;
        }
    }
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
        /* CANONICAL PC Q3 reference math: shift = mapOverbright - frameOverbright.
         * At stock cvars (mapOverbright=2, overBright=1) this is a single
         * left-shift = 2x boost per channel, which matches the GL_RGB_SCALE=2
         * that PC Q3 applied at the lightmap texture unit. The earlier `+1`
         * added an extra 2x on top to compensate for fragment-side scaling
         * that's been removed elsewhere — but it pushed the world ~2x brighter
         * than PC reference. Easy to spot in q3dm1: the previous "+1" path
         * blew out the rocket arena ceiling lights into pure white. PC stock
         * keeps them as a hot but distinct yellow.
         *
         * OLED-side visibility lift happens via r_gamma=1.15 in the cmdline
         * (small midtone bump, doesn't wash anything out). Lightmap math
         * stays at the PC reference shift so highlights don't clip and
         * darker corners still have the right relative contrast curve. */
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

/* ==========================================================================
 * PARALLEL BSP WORLD — strict upstream layout (ioquake3 renderer/)
 *
 * These structs + loaders mirror ioq3 tr_local.h/tr_bsp.c/tr_curve.c exactly.
 * They run alongside the existing Metal draw pipeline without disturbing it:
 * the Metal pipeline drives on-screen rendering from the flattened
 * Q3MetalWorldDrawCmd stream; this parallel tree is populated from the same
 * BSP and exists so R_MarkFragments can BSP-traverse and per-surface clip
 * impact polygons.
 *
 * Struct names are prefixed `bsp*` to avoid colliding with any future port
 * of the full ioq3 renderer into this translation unit. Layouts MATCH
 * upstream (see renderer/tr_local.h lines 652..833). All field names and
 * semantics are preserved for faithful R_MarkFragments port.
 * ========================================================================== */

#include <limits.h>

#ifndef BSP_VERTEXSIZE
#define BSP_VERTEXSIZE 8
#endif
#define BSP_MAX_FACE_POINTS 1024
#define BSP_MAX_GRID_SIZE   65
#define BSP_MAX_PATCH_SIZE  32

typedef enum {
    BSP_SF_BAD,
    BSP_SF_SKIP,
    BSP_SF_FACE,
    BSP_SF_GRID,
    BSP_SF_TRIANGLES,
    BSP_SF_POLY,
    BSP_SF_MD3,
    BSP_SF_MDR,
    BSP_SF_IQM,
    BSP_SF_FLARE,
    BSP_SF_ENTITY,
    BSP_SF_NUM_SURFACE_TYPES,
    BSP_SF_MAX = 0x7fffffff
} bspSurfaceType_t;

typedef struct {
    int surfaceFlags;
    int contentFlags;
} bspShader_t;

typedef struct bspMsurface_s {
    int                 viewCount;
    uint32_t            metalVisibleStamp;
    bspShader_t         *shader;
    int                 fogIndex;
    vec3_t              bounds[2];
    qboolean            boundsValid;
    bspSurfaceType_t    *data;
} bspMsurface_t;

typedef struct {
    bspSurfaceType_t    surfaceType;
    cplane_t            plane;
    int                 numPoints;
    int                 numIndices;
    int                 ofsIndices;
    float               points[1][BSP_VERTEXSIZE];
} bspSrfSurfaceFace_t;

typedef struct bspSrfGridMesh_s {
    bspSurfaceType_t    surfaceType;
    vec3_t              meshBounds[2];
    vec3_t              localOrigin;
    float               meshRadius;
    vec3_t              lodOrigin;
    float               lodRadius;
    int                 lodFixed;
    int                 lodStitched;
    int                 width, height;
    float               *widthLodError;
    float               *heightLodError;
    drawVert_t          verts[1];
} bspSrfGridMesh_t;

typedef struct {
    bspSurfaceType_t    surfaceType;
    vec3_t              bounds[2];
    vec3_t              localOrigin;
    float               radius;
    int                 numIndexes;
    int                 *indexes;
    int                 numVerts;
    drawVert_t          *verts;
} bspSrfTriangles_t;

typedef struct {
    bspSurfaceType_t    surfaceType;
    vec3_t              origin;
    vec3_t              normal;
    vec3_t              color;
} bspSrfFlare_t;

typedef struct bspMnode_s {
    int                 contents;
    int                 visframe;
    vec3_t              mins, maxs;
    struct bspMnode_s   *parent;
    cplane_t            *plane;
    struct bspMnode_s   *children[2];
    int                 cluster;
    int                 area;
    bspMsurface_t       **firstmarksurface;
    int                 nummarksurfaces;
} bspMnode_t;

static struct {
    qboolean        loaded;
    int             numplanes;
    cplane_t        *planes;
    int             numnodes;
    int             numDecisionNodes;
    bspMnode_t      *nodes;
    int             numsurfaces;
    bspMsurface_t   *surfaces;
    int             nummarksurfaces;
    bspMsurface_t   **marksurfaces;
    int             numClusters;
    int             numShaders;
    bspShader_t     *shaders;
    /* Linear pool for variable-size surface structs (face/grid/tri payload).
     * Allocated once, freed once — mirrors ioq3's Hunk_Alloc usage pattern
     * but on our ri.Malloc heap. */
    byte            *blobPool;
    size_t          blobUsed;
    size_t          blobCap;
} s_bspWorld;

static int      s_bspViewCount;
static cvar_t   *r_marksOnTriangleMeshes;
static cvar_t   *r_subdivisions_bsp;

static void *BspBlobAlloc(size_t bytes) {
    void *p;
    bytes = (bytes + 15u) & ~(size_t)15u;
    if (s_bspWorld.blobUsed + bytes > s_bspWorld.blobCap) return NULL;
    p = s_bspWorld.blobPool + s_bspWorld.blobUsed;
    s_bspWorld.blobUsed += bytes;
    Com_Memset(p, 0, bytes);
    return p;
}

static float BspClampDenorm(float v) {
    if (fabsf(v) > 0.0f && fabsf(v) < 1e-9f) return 0.0f;
    return v;
}

/* ---- tr_curve.c port (verbatim from ioquake3 renderer/tr_curve.c) ---- */

static void BspLerpDrawVert(drawVert_t *a, drawVert_t *b, drawVert_t *out) {
    out->xyz[0] = 0.5f * (a->xyz[0] + b->xyz[0]);
    out->xyz[1] = 0.5f * (a->xyz[1] + b->xyz[1]);
    out->xyz[2] = 0.5f * (a->xyz[2] + b->xyz[2]);
    out->st[0] = 0.5f * (a->st[0] + b->st[0]);
    out->st[1] = 0.5f * (a->st[1] + b->st[1]);
    out->lightmap[0] = 0.5f * (a->lightmap[0] + b->lightmap[0]);
    out->lightmap[1] = 0.5f * (a->lightmap[1] + b->lightmap[1]);
    out->color.rgba[0] = (a->color.rgba[0] + b->color.rgba[0]) >> 1;
    out->color.rgba[1] = (a->color.rgba[1] + b->color.rgba[1]) >> 1;
    out->color.rgba[2] = (a->color.rgba[2] + b->color.rgba[2]) >> 1;
    out->color.rgba[3] = (a->color.rgba[3] + b->color.rgba[3]) >> 1;
}

static void BspTranspose(int width, int height, drawVert_t ctrl[BSP_MAX_GRID_SIZE][BSP_MAX_GRID_SIZE]) {
    int i, j;
    drawVert_t temp;
    if (width > height) {
        for (i = 0; i < height; i++) {
            for (j = i + 1; j < width; j++) {
                if (j < height) {
                    temp = ctrl[j][i];
                    ctrl[j][i] = ctrl[i][j];
                    ctrl[i][j] = temp;
                } else {
                    ctrl[j][i] = ctrl[i][j];
                }
            }
        }
    } else {
        for (i = 0; i < width; i++) {
            for (j = i + 1; j < height; j++) {
                if (j < width) {
                    temp = ctrl[i][j];
                    ctrl[i][j] = ctrl[j][i];
                    ctrl[j][i] = temp;
                } else {
                    ctrl[i][j] = ctrl[j][i];
                }
            }
        }
    }
}

static void BspMakeMeshNormals(int width, int height, drawVert_t ctrl[BSP_MAX_GRID_SIZE][BSP_MAX_GRID_SIZE]) {
    int i, j, k, dist;
    vec3_t normal, sum, base, delta;
    int x, y;
    drawVert_t *dv;
    vec3_t around[8], temp;
    qboolean good[8];
    qboolean wrapWidth, wrapHeight;
    float len;
    static const int neighbors[8][2] = { {0,1},{1,1},{1,0},{1,-1},{0,-1},{-1,-1},{-1,0},{-1,1} };

    wrapWidth = qfalse;
    for (i = 0; i < height; i++) {
        VectorSubtract(ctrl[i][0].xyz, ctrl[i][width-1].xyz, delta);
        len = VectorLengthSquared(delta);
        if (len > 1.0f) break;
    }
    if (i == height) wrapWidth = qtrue;

    wrapHeight = qfalse;
    for (i = 0; i < width; i++) {
        VectorSubtract(ctrl[0][i].xyz, ctrl[height-1][i].xyz, delta);
        len = VectorLengthSquared(delta);
        if (len > 1.0f) break;
    }
    if (i == width) wrapHeight = qtrue;

    for (i = 0; i < width; i++) {
        for (j = 0; j < height; j++) {
            dv = &ctrl[j][i];
            VectorCopy(dv->xyz, base);
            for (k = 0; k < 8; k++) {
                VectorClear(around[k]);
                good[k] = qfalse;
                for (dist = 1; dist <= 3; dist++) {
                    x = i + neighbors[k][0] * dist;
                    y = j + neighbors[k][1] * dist;
                    if (wrapWidth) {
                        if (x < 0) x = width - 1 + x;
                        else if (x >= width) x = 1 + x - width;
                    }
                    if (wrapHeight) {
                        if (y < 0) y = height - 1 + y;
                        else if (y >= height) y = 1 + y - height;
                    }
                    if (x < 0 || x >= width || y < 0 || y >= height) break;
                    VectorSubtract(ctrl[y][x].xyz, base, temp);
                    if (VectorNormalize(temp) < 0.001f) continue;
                    good[k] = qtrue;
                    VectorCopy(temp, around[k]);
                    break;
                }
            }
            VectorClear(sum);
            for (k = 0; k < 8; k++) {
                if (!good[k] || !good[(k+1)&7]) continue;
                CrossProduct(around[(k+1)&7], around[k], normal);
                if (VectorNormalize(normal) < 0.001f) continue;
                VectorAdd(normal, sum, sum);
            }
            VectorNormalize2(sum, dv->normal);
            for (k = 0; k < 3; k++) dv->normal[k] = BspClampDenorm(dv->normal[k]);
        }
    }
}

static void BspInvertCtrl(int width, int height, drawVert_t ctrl[BSP_MAX_GRID_SIZE][BSP_MAX_GRID_SIZE]) {
    int i, j;
    drawVert_t temp;
    for (i = 0; i < height; i++) {
        for (j = 0; j < width/2; j++) {
            temp = ctrl[i][j];
            ctrl[i][j] = ctrl[i][width-1-j];
            ctrl[i][width-1-j] = temp;
        }
    }
}

static void BspInvertErrorTable(float errorTable[2][BSP_MAX_GRID_SIZE], int width, int height) {
    int i;
    float copy[2][BSP_MAX_GRID_SIZE];
    Com_Memcpy(copy, errorTable, sizeof(copy));
    for (i = 0; i < width; i++)  errorTable[1][i] = copy[0][i];
    for (i = 0; i < height; i++) errorTable[0][i] = copy[1][height-1-i];
}

static void BspPutPointsOnCurve(drawVert_t ctrl[BSP_MAX_GRID_SIZE][BSP_MAX_GRID_SIZE], int width, int height) {
    int i, j;
    drawVert_t prev, next;
    for (i = 0; i < width; i++) {
        for (j = 1; j < height; j += 2) {
            BspLerpDrawVert(&ctrl[j][i], &ctrl[j+1][i], &prev);
            BspLerpDrawVert(&ctrl[j][i], &ctrl[j-1][i], &next);
            BspLerpDrawVert(&prev, &next, &ctrl[j][i]);
        }
    }
    for (j = 0; j < height; j++) {
        for (i = 1; i < width; i += 2) {
            BspLerpDrawVert(&ctrl[j][i], &ctrl[j][i+1], &prev);
            BspLerpDrawVert(&ctrl[j][i], &ctrl[j][i-1], &next);
            BspLerpDrawVert(&prev, &next, &ctrl[j][i]);
        }
    }
}

static bspSrfGridMesh_t *BspCreateSurfaceGridMesh(int width, int height,
        drawVert_t ctrl[BSP_MAX_GRID_SIZE][BSP_MAX_GRID_SIZE],
        float errorTable[2][BSP_MAX_GRID_SIZE]) {
    int i, j, size;
    drawVert_t *vert;
    vec3_t tmpVec;
    bspSrfGridMesh_t *grid;

    size = (width * height - 1) * sizeof(drawVert_t) + sizeof(*grid);
    grid = (bspSrfGridMesh_t *)BspBlobAlloc(size);
    if (!grid) return NULL;
    grid->widthLodError  = (float *)BspBlobAlloc(width * sizeof(float));
    grid->heightLodError = (float *)BspBlobAlloc(height * sizeof(float));
    if (grid->widthLodError && grid->heightLodError) {
        Com_Memcpy(grid->widthLodError,  errorTable[0], width * sizeof(float));
        Com_Memcpy(grid->heightLodError, errorTable[1], height * sizeof(float));
    }
    grid->width = width;
    grid->height = height;
    grid->surfaceType = BSP_SF_GRID;
    ClearBounds(grid->meshBounds[0], grid->meshBounds[1]);
    for (i = 0; i < width; i++) {
        for (j = 0; j < height; j++) {
            vert = &grid->verts[j*width+i];
            *vert = ctrl[j][i];
            AddPointToBounds(vert->xyz, grid->meshBounds[0], grid->meshBounds[1]);
        }
    }
    VectorAdd(grid->meshBounds[0], grid->meshBounds[1], grid->localOrigin);
    VectorScale(grid->localOrigin, 0.5f, grid->localOrigin);
    VectorSubtract(grid->meshBounds[0], grid->localOrigin, tmpVec);
    grid->meshRadius = VectorLength(tmpVec);
    VectorCopy(grid->localOrigin, grid->lodOrigin);
    grid->lodRadius = grid->meshRadius;
    return grid;
}

static bspSrfGridMesh_t *BspSubdividePatchToGrid(int width, int height,
        drawVert_t points[BSP_MAX_PATCH_SIZE*BSP_MAX_PATCH_SIZE]) {
    int i, j, k, l, n, t;
    drawVert_t prev, next, mid;
    float len, maxLen;
    drawVert_t ctrl[BSP_MAX_GRID_SIZE][BSP_MAX_GRID_SIZE];
    float errorTable[2][BSP_MAX_GRID_SIZE];
    float subdivisionsValue = (r_subdivisions_bsp != NULL) ? r_subdivisions_bsp->value : 4.0f;

    Com_Memset(&prev, 0, sizeof(prev));
    Com_Memset(&next, 0, sizeof(next));
    Com_Memset(&mid, 0, sizeof(mid));
    for (i = 0; i < width; i++)
        for (j = 0; j < height; j++)
            ctrl[j][i] = points[j*width+i];

    for (n = 0; n < 2; n++) {
        for (j = 0; j < BSP_MAX_GRID_SIZE; j++) errorTable[n][j] = 0;
        for (j = 0; j + 2 < width; j += 2) {
            maxLen = 0;
            for (i = 0; i < height; i++) {
                vec3_t midxyz, midxyz2, dir, projected;
                float d;
                for (l = 0; l < 3; l++)
                    midxyz[l] = (ctrl[i][j].xyz[l] + ctrl[i][j+1].xyz[l] * 2 + ctrl[i][j+2].xyz[l]) * 0.25f;
                VectorSubtract(midxyz, ctrl[i][j].xyz, midxyz);
                VectorSubtract(ctrl[i][j+2].xyz, ctrl[i][j].xyz, dir);
                VectorNormalize(dir);
                d = DotProduct(midxyz, dir);
                VectorScale(dir, d, projected);
                VectorSubtract(midxyz, projected, midxyz2);
                len = VectorLengthSquared(midxyz2);
                if (len > maxLen) maxLen = len;
            }
            maxLen = sqrtf(maxLen);
            if (maxLen < 0.1f) { errorTable[n][j+1] = 999; continue; }
            if (width + 2 > BSP_MAX_GRID_SIZE) { errorTable[n][j+1] = 1.0f/maxLen; continue; }
            if (maxLen <= subdivisionsValue) { errorTable[n][j+1] = 1.0f/maxLen; continue; }
            errorTable[n][j+2] = 1.0f/maxLen;
            width += 2;
            for (i = 0; i < height; i++) {
                BspLerpDrawVert(&ctrl[i][j],   &ctrl[i][j+1], &prev);
                BspLerpDrawVert(&ctrl[i][j+1], &ctrl[i][j+2], &next);
                BspLerpDrawVert(&prev, &next, &mid);
                for (k = width - 1; k > j + 3; k--) ctrl[i][k] = ctrl[i][k-2];
                ctrl[i][j+1] = prev;
                ctrl[i][j+2] = mid;
                ctrl[i][j+3] = next;
            }
            j -= 2;
        }
        BspTranspose(width, height, ctrl);
        t = width; width = height; height = t;
    }

    BspPutPointsOnCurve(ctrl, width, height);

    for (i = 1; i < width-1; i++) {
        if (errorTable[0][i] != 999) continue;
        for (j = i+1; j < width; j++) {
            for (k = 0; k < height; k++) ctrl[k][j-1] = ctrl[k][j];
            errorTable[0][j-1] = errorTable[0][j];
        }
        width--;
    }
    for (i = 1; i < height-1; i++) {
        if (errorTable[1][i] != 999) continue;
        for (j = i+1; j < height; j++) {
            for (k = 0; k < width; k++) ctrl[j-1][k] = ctrl[j][k];
            errorTable[1][j-1] = errorTable[1][j];
        }
        height--;
    }
    if (height > width) {
        BspTranspose(width, height, ctrl);
        BspInvertErrorTable(errorTable, width, height);
        t = width; width = height; height = t;
        BspInvertCtrl(width, height, ctrl);
    }
    BspMakeMeshNormals(width, height, ctrl);
    return BspCreateSurfaceGridMesh(width, height, ctrl, errorTable);
}

/* ---- tr_bsp.c Parse* ports ---- */

static void BspParseFace(const dsurface_t *ds, const drawVert_t *verts, int numPoints,
                         bspMsurface_t *surf, const int *srcIndexes, int numIndexes,
                         bspShader_t *shaderTab, int numShaders) {
    int i, j, sfaceSize, ofsIndexes;
    bspSrfSurfaceFace_t *cv;
    int *indexes;
    int shaderNum = LittleLong(ds->shaderNum);

    if (shaderNum >= 0 && shaderNum < numShaders)
        surf->shader = &shaderTab[shaderNum];
    else
        surf->shader = &shaderTab[0];

    if (numPoints > BSP_MAX_FACE_POINTS) numPoints = BSP_MAX_FACE_POINTS;

    sfaceSize = sizeof(*cv) - sizeof(cv->points) + sizeof(cv->points[0]) * numPoints;
    ofsIndexes = sfaceSize;
    sfaceSize += sizeof(int) * numIndexes;

    cv = (bspSrfSurfaceFace_t *)BspBlobAlloc(sfaceSize);
    if (!cv) return;
    cv->surfaceType = BSP_SF_FACE;
    cv->numPoints = numPoints;
    cv->numIndices = numIndexes;
    cv->ofsIndices = ofsIndexes;

    ClearBounds(surf->bounds[0], surf->bounds[1]);
    for (i = 0; i < numPoints; i++) {
        for (j = 0; j < 3; j++)
            cv->points[i][j] = LittleFloat(verts[i].xyz[j]);
        AddPointToBounds(cv->points[i], surf->bounds[0], surf->bounds[1]);
        for (j = 0; j < 2; j++) {
            cv->points[i][3+j] = LittleFloat(verts[i].st[j]);
            cv->points[i][5+j] = LittleFloat(verts[i].lightmap[j]);
        }
        Com_Memcpy((byte *)&cv->points[i][7], verts[i].color.rgba, 4);
    }
    surf->boundsValid = (numPoints > 0) ? qtrue : qfalse;

    indexes = (int *)((byte *)cv + cv->ofsIndices);
    for (i = 0; i < numIndexes; i++) {
        unsigned num = LittleLong(srcIndexes[i]);
        if ((int)num >= numPoints) num = 0;
        indexes[i] = (int)num;
    }

    for (i = 0; i < 3; i++)
        cv->plane.normal[i] = LittleFloat(ds->lightmapVecs[2][i]);
    for (i = 0; i < 3; i++)
        cv->plane.normal[i] = BspClampDenorm(cv->plane.normal[i]);

    cv->plane.dist = DotProduct(cv->points[0], cv->plane.normal);
    SetPlaneSignbits(&cv->plane);
    cv->plane.type = PlaneTypeForNormal(cv->plane.normal);

    surf->data = (bspSurfaceType_t *)cv;
}

static void BspParseMesh(const dsurface_t *ds, const drawVert_t *verts, int numVerts,
                         bspMsurface_t *surf,
                         bspShader_t *shaderTab, int numShaders) {
    int i, j;
    unsigned width, height, numPoints;
    drawVert_t points[BSP_MAX_PATCH_SIZE * BSP_MAX_PATCH_SIZE];
    vec3_t bounds[2], tmpVec;
    int shaderNum = LittleLong(ds->shaderNum);
    bspSrfGridMesh_t *grid;
    static bspSurfaceType_t skipData = BSP_SF_SKIP;

    if (shaderNum >= 0 && shaderNum < numShaders)
        surf->shader = &shaderTab[shaderNum];
    else
        surf->shader = &shaderTab[0];

    width = (unsigned)LittleLong(ds->patchWidth);
    height = (unsigned)LittleLong(ds->patchHeight);
    if (width <= 2 || height <= 2 || !(width & 1) || !(height & 1) ||
        width > BSP_MAX_PATCH_SIZE || height > BSP_MAX_PATCH_SIZE ||
        width * height > ARRAY_LEN(points)) {
        surf->data = &skipData;
        return;
    }
    numPoints = width * height;
    if (numPoints > (unsigned)numVerts) {
        surf->data = &skipData;
        return;
    }
    for (i = 0; i < (int)numPoints; i++) {
        for (j = 0; j < 3; j++) {
            points[i].xyz[j] = LittleFloat(verts[i].xyz[j]);
            points[i].normal[j] = BspClampDenorm(LittleFloat(verts[i].normal[j]));
        }
        for (j = 0; j < 2; j++) {
            points[i].st[j] = LittleFloat(verts[i].st[j]);
            points[i].lightmap[j] = LittleFloat(verts[i].lightmap[j]);
        }
        Com_Memcpy(points[i].color.rgba, verts[i].color.rgba, 4);
    }

    grid = BspSubdividePatchToGrid((int)width, (int)height, points);
    if (!grid) {
        surf->data = &skipData;
        return;
    }
    surf->data = (bspSurfaceType_t *)grid;
    VectorCopy(grid->meshBounds[0], surf->bounds[0]);
    VectorCopy(grid->meshBounds[1], surf->bounds[1]);
    surf->boundsValid = qtrue;

    for (i = 0; i < 3; i++) {
        bounds[0][i] = LittleFloat(ds->lightmapVecs[0][i]);
        bounds[1][i] = LittleFloat(ds->lightmapVecs[1][i]);
    }
    VectorAdd(bounds[0], bounds[1], bounds[1]);
    VectorScale(bounds[1], 0.5f, grid->lodOrigin);
    VectorSubtract(bounds[0], grid->lodOrigin, tmpVec);
    grid->lodRadius = VectorLength(tmpVec);
}

static void BspParseTriSurf(const dsurface_t *ds, const drawVert_t *verts, int numVerts,
                            bspMsurface_t *surf, const int *srcIndexes, int numIndexes,
                            bspShader_t *shaderTab, int numShaders) {
    int i, j;
    bspSrfTriangles_t *tri;
    int shaderNum = LittleLong(ds->shaderNum);

    if (shaderNum >= 0 && shaderNum < numShaders)
        surf->shader = &shaderTab[shaderNum];
    else
        surf->shader = &shaderTab[0];

    tri = (bspSrfTriangles_t *)BspBlobAlloc(sizeof(*tri) + numVerts * sizeof(tri->verts[0])
                                          + numIndexes * sizeof(tri->indexes[0]));
    if (!tri) return;
    tri->surfaceType = BSP_SF_TRIANGLES;
    tri->numVerts = numVerts;
    tri->numIndexes = numIndexes;
    tri->verts = (drawVert_t *)(tri + 1);
    tri->indexes = (int *)(tri->verts + tri->numVerts);

    surf->data = (bspSurfaceType_t *)tri;

    ClearBounds(tri->bounds[0], tri->bounds[1]);
    for (i = 0; i < numVerts; i++) {
        for (j = 0; j < 3; j++) {
            tri->verts[i].xyz[j] = LittleFloat(verts[i].xyz[j]);
            tri->verts[i].normal[j] = BspClampDenorm(LittleFloat(verts[i].normal[j]));
        }
        AddPointToBounds(tri->verts[i].xyz, tri->bounds[0], tri->bounds[1]);
        for (j = 0; j < 2; j++) {
            tri->verts[i].st[j] = LittleFloat(verts[i].st[j]);
            tri->verts[i].lightmap[j] = LittleFloat(verts[i].lightmap[j]);
        }
        Com_Memcpy(tri->verts[i].color.rgba, verts[i].color.rgba, 4);
    }
    for (i = 0; i < numIndexes; i++) {
        int v = (int)LittleLong(srcIndexes[i]);
        if (v < 0 || v >= numVerts) v = 0;
        tri->indexes[i] = v;
    }
    VectorCopy(tri->bounds[0], surf->bounds[0]);
    VectorCopy(tri->bounds[1], surf->bounds[1]);
    surf->boundsValid = (numVerts > 0) ? qtrue : qfalse;
}

static void BspParseFlare(const dsurface_t *ds, bspMsurface_t *surf,
                          bspShader_t *shaderTab, int numShaders) {
    int i;
    bspSrfFlare_t *flare;
    int shaderNum = LittleLong(ds->shaderNum);

    if (shaderNum >= 0 && shaderNum < numShaders)
        surf->shader = &shaderTab[shaderNum];
    else
        surf->shader = &shaderTab[0];

    flare = (bspSrfFlare_t *)BspBlobAlloc(sizeof(*flare));
    if (!flare) return;
    flare->surfaceType = BSP_SF_FLARE;
    surf->data = (bspSurfaceType_t *)flare;
    for (i = 0; i < 3; i++) {
        flare->origin[i] = LittleFloat(ds->lightmapOrigin[i]);
        flare->color[i]  = LittleFloat(ds->lightmapVecs[0][i]);
        flare->normal[i] = BspClampDenorm(LittleFloat(ds->lightmapVecs[2][i]));
    }
    for (i = 0; i < 3; i++) {
        surf->bounds[0][i] = flare->origin[i] - 16.0f;
        surf->bounds[1][i] = flare->origin[i] + 16.0f;
    }
    surf->boundsValid = qtrue;
}

/* ---- tr_bsp.c Load*() ports ---- */

static void BspLoadShaders(const dheader_t *header, const byte *fileBase,
                           int *outNumFaces, int *outNumMeshes, int *outNumTris, int *outNumFlares) {
    const dshader_t *in;
    int i, count;
    bspShader_t *out;

    in = (const dshader_t *)(fileBase + LittleLong(header->lumps[LUMP_SHADERS].fileofs));
    count = LittleLong(header->lumps[LUMP_SHADERS].filelen) / (int)sizeof(*in);
    out = (bspShader_t *)ri.Malloc(count * sizeof(*out));
    s_bspWorld.shaders = out;
    s_bspWorld.numShaders = count;
    for (i = 0; i < count; i++) {
        out[i].surfaceFlags = LittleLong(in[i].surfaceFlags);
        out[i].contentFlags = LittleLong(in[i].contentFlags);
    }
    (void)outNumFaces; (void)outNumMeshes; (void)outNumTris; (void)outNumFlares;
}

static void BspLoadPlanes(const dheader_t *header, const byte *fileBase) {
    const dplane_t *in;
    cplane_t *out;
    int i, j, count, bits;

    in = (const dplane_t *)(fileBase + LittleLong(header->lumps[LUMP_PLANES].fileofs));
    count = LittleLong(header->lumps[LUMP_PLANES].filelen) / (int)sizeof(*in);
    out = (cplane_t *)ri.Malloc(count * 2 * sizeof(*out));
    Com_Memset(out, 0, count * 2 * sizeof(*out));
    s_bspWorld.planes = out;
    s_bspWorld.numplanes = count;
    for (i = 0; i < count; i++, in++, out++) {
        bits = 0;
        for (j = 0; j < 3; j++) {
            out->normal[j] = LittleFloat(in->normal[j]);
            if (out->normal[j] < 0) bits |= 1 << j;
        }
        out->dist = LittleFloat(in->dist);
        out->type = PlaneTypeForNormal(out->normal);
        out->signbits = bits;
    }
}

static void BspLoadMarksurfaces(const dheader_t *header, const byte *fileBase) {
    const int *in;
    int i, count;
    bspMsurface_t **out;

    in = (const int *)(fileBase + LittleLong(header->lumps[LUMP_LEAFSURFACES].fileofs));
    count = LittleLong(header->lumps[LUMP_LEAFSURFACES].filelen) / (int)sizeof(*in);
    out = (bspMsurface_t **)ri.Malloc(count * sizeof(*out));
    s_bspWorld.marksurfaces = out;
    s_bspWorld.nummarksurfaces = count;
    for (i = 0; i < count; i++) {
        int idx = (int)LittleLong(in[i]);
        if (idx < 0 || idx >= s_bspWorld.numsurfaces) idx = 0;
        out[i] = &s_bspWorld.surfaces[idx];
    }
}

static void BspSetParent_r(bspMnode_t *node, bspMnode_t *parent) {
    node->parent = parent;
    if (node->contents != CONTENTS_NODE) return;
    BspSetParent_r(node->children[0], node);
    BspSetParent_r(node->children[1], node);
}

static void BspLoadNodesAndLeafs(const dheader_t *header, const byte *fileBase) {
    const dnode_t *in;
    const dleaf_t *inLeaf;
    bspMnode_t *out;
    int i, j, numNodes, numLeafs;
    unsigned p, firstmarksurface, nummarksurfaces;

    in = (const dnode_t *)(fileBase + LittleLong(header->lumps[LUMP_NODES].fileofs));
    numNodes = LittleLong(header->lumps[LUMP_NODES].filelen) / (int)sizeof(dnode_t);
    numLeafs = LittleLong(header->lumps[LUMP_LEAFS].filelen) / (int)sizeof(dleaf_t);

    out = (bspMnode_t *)ri.Malloc((numNodes + numLeafs) * sizeof(*out));
    Com_Memset(out, 0, (numNodes + numLeafs) * sizeof(*out));
    s_bspWorld.nodes = out;
    s_bspWorld.numnodes = numNodes + numLeafs;
    s_bspWorld.numDecisionNodes = numNodes;

    for (i = 0; i < numNodes; i++, in++, out++) {
        for (j = 0; j < 3; j++) {
            out->mins[j] = (float)LittleLong(in->mins[j]);
            out->maxs[j] = (float)LittleLong(in->maxs[j]);
        }
        p = (unsigned)LittleLong(in->planeNum);
        if ((int)p >= s_bspWorld.numplanes) p = 0;
        out->plane = s_bspWorld.planes + p;
        out->contents = CONTENTS_NODE;
        for (j = 0; j < 2; j++) {
            p = (unsigned)LittleLong(in->children[j]);
            if (p & 0x80000000u) {
                p = ~p;
                if ((int)p >= numLeafs) p = 0;
                out->children[j] = s_bspWorld.nodes + numNodes + p;
            } else {
                if ((int)p >= numNodes) p = 0;
                out->children[j] = s_bspWorld.nodes + p;
            }
        }
    }

    inLeaf = (const dleaf_t *)(fileBase + LittleLong(header->lumps[LUMP_LEAFS].fileofs));
    for (i = 0; i < numLeafs; i++, inLeaf++, out++) {
        for (j = 0; j < 3; j++) {
            out->mins[j] = (float)LittleLong(inLeaf->mins[j]);
            out->maxs[j] = (float)LittleLong(inLeaf->maxs[j]);
        }
        out->cluster = LittleLong(inLeaf->cluster);
        out->area    = LittleLong(inLeaf->area);
        if (out->cluster >= s_bspWorld.numClusters) {
            s_bspWorld.numClusters = out->cluster + 1;
        }
        out->contents = 0; /* !=CONTENTS_NODE — it's a leaf */
        firstmarksurface = (unsigned)LittleLong(inLeaf->firstLeafSurface);
        nummarksurfaces  = (unsigned)LittleLong(inLeaf->numLeafSurfaces);
        if ((int)(firstmarksurface + nummarksurfaces) > s_bspWorld.nummarksurfaces) {
            firstmarksurface = 0;
            nummarksurfaces = 0;
        }
        out->firstmarksurface = s_bspWorld.marksurfaces + firstmarksurface;
        out->nummarksurfaces = (int)nummarksurfaces;
    }

    BspSetParent_r(s_bspWorld.nodes, NULL);
}

static void BspLoadSurfaces(const dheader_t *header, const byte *fileBase,
                            const dsurface_t *surfIn, int surfaceCount,
                            const drawVert_t *dv, int totalVerts,
                            const int *indexes, int totalIndexes,
                            int *outFaces, int *outMeshes, int *outTris, int *outFlares) {
    int i;
    int numFaces = 0, numMeshes = 0, numTris = 0, numFlares = 0;
    bspMsurface_t *out;
    unsigned firstVert = 0, numVerts = 0, firstIndex = 0, numIndexes = 0;

    (void)header;
    out = (bspMsurface_t *)ri.Malloc(surfaceCount * sizeof(*out));
    Com_Memset(out, 0, surfaceCount * sizeof(*out));
    s_bspWorld.surfaces = out;
    s_bspWorld.numsurfaces = surfaceCount;

    for (i = 0; i < surfaceCount; i++, surfIn++, out++) {
        unsigned type = (unsigned)LittleLong(surfIn->surfaceType);
        if (type != MST_FLARE) {
            firstVert = (unsigned)LittleLong(surfIn->firstVert);
            if (type == MST_PATCH) numVerts = 0;
            else numVerts = (unsigned)LittleLong(surfIn->numVerts);
            if ((int)(firstVert + numVerts) > totalVerts) { firstVert = 0; numVerts = 0; }
            if (type != MST_PATCH) {
                firstIndex = (unsigned)LittleLong(surfIn->firstIndex);
                numIndexes = (unsigned)LittleLong(surfIn->numIndexes);
                if ((int)(firstIndex + numIndexes) > totalIndexes) { firstIndex = 0; numIndexes = 0; }
                if (numIndexes % 3) numIndexes -= numIndexes % 3;
            }
        }
        out->fogIndex = LittleLong(surfIn->fogNum) + 1;
        switch (type) {
            case MST_PATCH:
                BspParseMesh(surfIn, dv + firstVert, totalVerts - (int)firstVert,
                             out, s_bspWorld.shaders, s_bspWorld.numShaders);
                numMeshes++;
                break;
            case MST_TRIANGLE_SOUP:
                BspParseTriSurf(surfIn, dv + firstVert, (int)numVerts, out,
                                indexes + firstIndex, (int)numIndexes,
                                s_bspWorld.shaders, s_bspWorld.numShaders);
                numTris++;
                break;
            case MST_PLANAR:
                BspParseFace(surfIn, dv + firstVert, (int)numVerts, out,
                             indexes + firstIndex, (int)numIndexes,
                             s_bspWorld.shaders, s_bspWorld.numShaders);
                numFaces++;
                break;
            case MST_FLARE:
                BspParseFlare(surfIn, out, s_bspWorld.shaders, s_bspWorld.numShaders);
                numFlares++;
                break;
            default:
                break;
        }
    }
    *outFaces  = numFaces;
    *outMeshes = numMeshes;
    *outTris   = numTris;
    *outFlares = numFlares;
}

static void BspFreeWorld(void) {
    if (s_bspWorld.shaders)      ri.Free(s_bspWorld.shaders);
    if (s_bspWorld.planes)       ri.Free(s_bspWorld.planes);
    if (s_bspWorld.nodes)        ri.Free(s_bspWorld.nodes);
    if (s_bspWorld.surfaces)     ri.Free(s_bspWorld.surfaces);
    if (s_bspWorld.marksurfaces) ri.Free(s_bspWorld.marksurfaces);
    if (s_bspWorld.blobPool)     ri.Free(s_bspWorld.blobPool);
    Com_Memset(&s_bspWorld, 0, sizeof(s_bspWorld));
}

static qboolean BspLoad(const dheader_t *header, const byte *fileBase,
                        const dsurface_t *surfIn, int surfaceCount,
                        const drawVert_t *dv, int totalVerts,
                        const int *indexes, int totalIndexes) {
    int numFaces = 0, numMeshes = 0, numTris = 0, numFlares = 0;
    size_t blobBudget;

    BspFreeWorld();

    /* Blob pool budget: sized against total BSP geometry + fat-patch overhead.
     * Faces store (points + indices) inline; the totalVerts/totalIndexes
     * terms cover them. Tri-surfs inline drawVert_t + int[] — also covered
     * by totalVerts. Patches are the ONLY surface kind that blows up after
     * subdivision, worst-case roughly 65×65 drawVerts per patch. So the
     * fat-patch term must multiply by patchCount, NOT surfaceCount —
     * otherwise complex maps (nv15 has ~29k surfaces but maybe <500 are
     * patches) over-allocate by ~60× and trip Z_TagMalloc's INT_MAX guard
     * with a 5.3GB request. Count patches in a quick first pass. */
    {
        int patchCount = 0;
        for (int s = 0; s < surfaceCount; s++) {
            if (LittleLong(surfIn[s].surfaceType) == MST_PATCH) {
                patchCount++;
            }
        }
        blobBudget = (size_t)totalVerts * (sizeof(drawVert_t) + 32)
                   + (size_t)totalIndexes * sizeof(int) * 2
                   + (size_t)patchCount * (sizeof(bspSrfGridMesh_t) + BSP_MAX_GRID_SIZE * BSP_MAX_GRID_SIZE * sizeof(drawVert_t))
                   + 1024 * 1024;
        ri.Printf(PRINT_DEVELOPER, "[BSP] blobBudget surfaces=%d patches=%d → %zu bytes\n",
                  surfaceCount, patchCount, blobBudget);
    }
    s_bspWorld.blobPool = (byte *)ri.Malloc(blobBudget);
    s_bspWorld.blobCap  = blobBudget;
    s_bspWorld.blobUsed = 0;
    Com_Memset(s_bspWorld.blobPool, 0, blobBudget);

    if (r_marksOnTriangleMeshes == NULL)
        r_marksOnTriangleMeshes = ri.Cvar_Get("r_marksOnTriangleMeshes", "0", CVAR_ARCHIVE);
    if (r_subdivisions_bsp == NULL)
        r_subdivisions_bsp = ri.Cvar_Get("r_subdivisions", "4", CVAR_ARCHIVE_ND | CVAR_LATCH);

    BspLoadShaders(header, fileBase, &numFaces, &numMeshes, &numTris, &numFlares);
    BspLoadPlanes(header, fileBase);
    BspLoadSurfaces(header, fileBase, surfIn, surfaceCount,
                    dv, totalVerts, indexes, totalIndexes,
                    &numFaces, &numMeshes, &numTris, &numFlares);
    BspLoadMarksurfaces(header, fileBase);
    BspLoadNodesAndLeafs(header, fileBase);

    s_bspWorld.loaded = qtrue;

    /* Validation milestone logs — matches user-specified checklist */
    ri.Printf(PRINT_ALL, "[BSP] nodes=%d leafs=%d planes=%d\n",
              s_bspWorld.numDecisionNodes,
              s_bspWorld.numnodes - s_bspWorld.numDecisionNodes,
              s_bspWorld.numplanes);
    ri.Printf(PRINT_ALL, "[BSP] leafsurfaces=%d\n", s_bspWorld.nummarksurfaces);
    ri.Printf(PRINT_ALL, "[SURF] faces=%d grids=%d tris=%d flares=%d\n",
              numFaces, numMeshes, numTris, numFlares);
    ri.Printf(PRINT_ALL, "[BSP] blobUsed=%zu/%zu bytes\n",
              s_bspWorld.blobUsed, s_bspWorld.blobCap);
    return qtrue;
}

/* ========================================================================== */

static void MetalWorldSetSurfaceDrawRange(int surfaceIndex, uint32_t firstDraw, uint32_t endDraw) {
    if (s_world.surfaceDrawRanges == NULL) return;
    if (surfaceIndex < 0 || surfaceIndex >= s_world.surfaceDrawRangeCount) return;
    if (endDraw < firstDraw) endDraw = firstDraw;
    s_world.surfaceDrawRanges[surfaceIndex].firstDraw = firstDraw;
    s_world.surfaceDrawRanges[surfaceIndex].drawCount = endDraw - firstDraw;
}

static bspMnode_t *MetalWorldPointInLeaf(const vec3_t p) {
    bspMnode_t *node;
    if (!s_bspWorld.loaded || s_bspWorld.nodes == NULL) {
        return NULL;
    }
    node = s_bspWorld.nodes;
    while (node != NULL && node->contents == CONTENTS_NODE) {
        const cplane_t *plane = node->plane;
        float d;
        if (plane == NULL) {
            return NULL;
        }
        d = DotProduct(p, plane->normal) - plane->dist;
        node = node->children[(d > 0.0f) ? 0 : 1];
    }
    return node;
}

static const byte *MetalWorldClusterPVS(int cluster) {
    if (cluster < 0 || cluster >= s_bspWorld.numClusters) {
        return NULL;
    }
    if (ri.CM_ClusterPVS != NULL) {
        return ri.CM_ClusterPVS(cluster);
    }
    return NULL;
}

static uint32_t MetalWorldAreaMaskHash(const byte *areamask) {
    uint32_t hash = 2166136261u;
    int i;
    if (areamask == NULL) {
        return 0;
    }
    for (i = 0; i < MAX_MAP_AREA_BYTES; ++i) {
        hash ^= (uint32_t)areamask[i];
        hash *= 16777619u;
    }
    return (hash != 0) ? hash : 1u;
}

static void MetalWorldBumpVisCount(void) {
    s_world.visibleVisCount += 1;
    if (s_world.visibleVisCount == 0) {
        int i;
        for (i = 0; i < s_bspWorld.numnodes; ++i) {
            s_bspWorld.nodes[i].visframe = 0;
        }
        s_world.visibleVisCount = 1;
    }
}

static uint32_t MetalWorldNextSurfaceStamp(void) {
    s_world.visibleSurfaceStamp += 1;
    if (s_world.visibleSurfaceStamp == 0) {
        int i;
        if (s_bspWorld.surfaces != NULL) {
            for (i = 0; i < s_bspWorld.numsurfaces; ++i) {
                s_bspWorld.surfaces[i].metalVisibleStamp = 0;
            }
        }
        s_world.visibleSurfaceStamp = 1;
    }
    return s_world.visibleSurfaceStamp;
}

static void MetalWorldMarkAllLeaves(void) {
    int i;
    MetalWorldBumpVisCount();
    for (i = 0; i < s_bspWorld.numnodes; ++i) {
        s_bspWorld.nodes[i].visframe = (int)s_world.visibleVisCount;
    }
}

static void MetalWorldMarkLeaves(const vec3_t vieworg, const byte *areamask) {
    bspMnode_t *leaf;
    const byte *vis;
    int cluster;
    uint32_t areaMaskHash;
    int i;

    if (!s_bspWorld.loaded || s_bspWorld.nodes == NULL || s_bspWorld.numnodes <= 0) {
        return;
    }

    leaf = MetalWorldPointInLeaf(vieworg);
    if (leaf == NULL) {
        MetalWorldMarkAllLeaves();
        s_world.lastViewCluster = -2;
        return;
    }

    cluster = leaf->cluster;
    areaMaskHash = MetalWorldAreaMaskHash(areamask);
    if (cluster == s_world.lastViewCluster &&
        s_world.visibleVisCount != 0 &&
        s_world.lastAreaMaskValid &&
        s_world.lastAreaMaskHash == areaMaskHash) {
        return;
    }

    vis = MetalWorldClusterPVS(cluster);
    if (cluster < 0 || vis == NULL || s_bspWorld.numClusters <= 0) {
        MetalWorldMarkAllLeaves();
        s_world.lastViewCluster = cluster;
        s_world.lastAreaMaskHash = areaMaskHash;
        s_world.lastAreaMaskValid = qtrue;
        return;
    }

    MetalWorldBumpVisCount();
    s_world.lastViewCluster = cluster;
    s_world.lastAreaMaskHash = areaMaskHash;
    s_world.lastAreaMaskValid = qtrue;

    for (i = s_bspWorld.numDecisionNodes; i < s_bspWorld.numnodes; ++i) {
        bspMnode_t *node = &s_bspWorld.nodes[i];
        int leafCluster = node->cluster;
        bspMnode_t *parent;
        if (leafCluster < 0 || leafCluster >= s_bspWorld.numClusters) {
            continue;
        }
        if (areamask != NULL && node->area >= 0 &&
            (areamask[node->area >> 3] & (1 << (node->area & 7))) != 0) {
            continue;
        }
        if ((vis[leafCluster >> 3] & (1 << (leafCluster & 7))) == 0) {
            continue;
        }
        for (parent = node; parent != NULL; parent = parent->parent) {
            if (parent->visframe == (int)s_world.visibleVisCount) {
                break;
            }
            parent->visframe = (int)s_world.visibleVisCount;
        }
    }
}

static void MetalWorldBuildFrustum(cplane_t frustum[4],
                                   const vec3_t vieworg,
                                   const vec3_t axis0,
                                   const vec3_t axis1,
                                   const vec3_t axis2,
                                   float fovX,
                                   float fovY) {
    float xmax = tanf(DEG2RAD(fovX) * 0.5f);
    float ymax = tanf(DEG2RAD(fovY) * 0.5f);
    float length;
    float oppleg;
    float adjleg;
    int i;

    if (xmax < 0.001f) xmax = 0.001f;
    if (ymax < 0.001f) ymax = 0.001f;

    length = sqrtf(xmax * xmax + 1.0f);
    oppleg = xmax / length;
    adjleg = 1.0f / length;

    VectorScale(axis0, oppleg, frustum[0].normal);
    VectorMA(frustum[0].normal, adjleg, axis1, frustum[0].normal);

    VectorScale(axis0, oppleg, frustum[1].normal);
    VectorMA(frustum[1].normal, -adjleg, axis1, frustum[1].normal);

    length = sqrtf(ymax * ymax + 1.0f);
    oppleg = ymax / length;
    adjleg = 1.0f / length;

    VectorScale(axis0, oppleg, frustum[2].normal);
    VectorMA(frustum[2].normal, adjleg, axis2, frustum[2].normal);

    VectorScale(axis0, oppleg, frustum[3].normal);
    VectorMA(frustum[3].normal, -adjleg, axis2, frustum[3].normal);

    for (i = 0; i < 4; ++i) {
        frustum[i].type = PLANE_NON_AXIAL;
        frustum[i].dist = DotProduct(vieworg, frustum[i].normal);
        SetPlaneSignbits(&frustum[i]);
    }
}

static qboolean MetalWorldSurfaceBoundsInFrustum(bspMsurface_t *surf,
                                                 const cplane_t frustum[4]) {
    int i;
    if (surf == NULL || !surf->boundsValid) {
        return qtrue;
    }
    for (i = 0; i < 4; ++i) {
        if (BoxOnPlaneSide(surf->bounds[0], surf->bounds[1], (cplane_t *)&frustum[i]) == 2) {
            return qfalse;
        }
    }
    return qtrue;
}

static qboolean MetalWorldCullFaceSurface(bspMsurface_t *surf,
                                          Q3MetalSurfaceDrawRange range,
                                          const vec3_t vieworg) {
    bspSrfSurfaceFace_t *face;
    Q3MetalWorldDrawCmd *draw;
    uint32_t cullMode;
    float d;

    if (surf == NULL || surf->data == NULL || *(surf->data) != BSP_SF_FACE) {
        return qfalse;
    }
    if (range.drawCount == 0 || range.firstDraw >= s_world.drawCount) {
        return qfalse;
    }
    draw = &s_world.draws[range.firstDraw];
    if (draw->stageCount == 0) {
        return qfalse;
    }

    cullMode = draw->stages[0].cullMode;
    if (cullMode == METAL_SHADER_CULL_DISABLE) {
        return qfalse;
    }

    face = (bspSrfSurfaceFace_t *)surf->data;
    d = DotProduct(vieworg, face->plane.normal);
    if (cullMode == METAL_SHADER_CULL_FRONT) {
        return (d > face->plane.dist + 8.0f) ? qtrue : qfalse;
    }
    return (d < face->plane.dist - 8.0f) ? qtrue : qfalse;
}

static void MetalWorldAppendSurfaceDraws(bspMsurface_t *surf,
                                         uint32_t surfaceStamp,
                                         const vec3_t vieworg,
                                         const cplane_t frustum[4]) {
    intptr_t surfaceIndex;
    Q3MetalSurfaceDrawRange range;

    if (surf == NULL || s_bspWorld.surfaces == NULL) return;
    if (surf->metalVisibleStamp == surfaceStamp) return;
    if (!MetalWorldSurfaceBoundsInFrustum(surf, frustum)) return;

    surfaceIndex = surf - s_bspWorld.surfaces;
    if (surfaceIndex < 0 || surfaceIndex >= s_world.surfaceDrawRangeCount) return;
    if (s_world.surfaceDrawRanges == NULL || s_world.visibleDraws == NULL) return;

    range = s_world.surfaceDrawRanges[surfaceIndex];
    if (range.drawCount == 0) return;
    if (range.firstDraw >= s_world.drawCount) return;
    if (range.firstDraw + range.drawCount > s_world.drawCount) {
        range.drawCount = s_world.drawCount - range.firstDraw;
    }
    if (MetalWorldCullFaceSurface(surf, range, vieworg)) return;

    surf->metalVisibleStamp = surfaceStamp;

    if (range.drawCount > s_world.visibleDrawCapacity - s_world.visibleDrawCount) {
        range.drawCount = s_world.visibleDrawCapacity - s_world.visibleDrawCount;
    }
    if (range.drawCount == 0) return;
    Com_Memcpy(&s_world.visibleDraws[s_world.visibleDrawCount],
               &s_world.draws[range.firstDraw],
               range.drawCount * sizeof(s_world.visibleDraws[0]));
    s_world.visibleDrawCount += range.drawCount;
}

static qboolean MetalWorldVisibleDrawAlreadyHas(const Q3MetalWorldDrawCmd *draw) {
    uint32_t i;

    if (draw == NULL || s_world.visibleDraws == NULL) return qfalse;

    for (i = 0; i < s_world.visibleDrawCount; ++i) {
        const Q3MetalWorldDrawCmd *visible = &s_world.visibleDraws[i];
        if (visible->firstIndex == draw->firstIndex &&
            visible->indexCount == draw->indexCount &&
            visible->flags == draw->flags &&
            visible->fogIndex == draw->fogIndex &&
            visible->lightmapTextureHandle == draw->lightmapTextureHandle) {
            return qtrue;
        }
    }
    return qfalse;
}

static void MetalWorldAppendFogOverlayDraws(void) {
    uint32_t di;

    if (s_world.draws == NULL || s_world.visibleDraws == NULL) return;

    for (di = 0; di < s_world.drawCount; ++di) {
        const Q3MetalWorldDrawCmd *draw = &s_world.draws[di];
        if ((draw->flags & Q3_METAL_WORLD_DRAWFLAG_FOG_OVERLAY) == 0) {
            continue;
        }
        if (MetalWorldVisibleDrawAlreadyHas(draw)) {
            continue;
        }
        if (s_world.visibleDrawCount >= s_world.visibleDrawCapacity) {
            return;
        }
        s_world.visibleDraws[s_world.visibleDrawCount++] = *draw;
    }
}

static void MetalWorldRecursiveNode(bspMnode_t *node,
                                    int planeBits,
                                    const cplane_t frustum[4],
                                    const vec3_t vieworg,
                                    uint32_t surfaceStamp) {
    int i;

    if (node == NULL) return;
    if (node->visframe != (int)s_world.visibleVisCount) return;

    for (i = 0; i < 4; ++i) {
        int side;
        int bit = 1 << i;
        if ((planeBits & bit) == 0) continue;
        side = BoxOnPlaneSide(node->mins, node->maxs, (cplane_t *)&frustum[i]);
        if (side == 2) return;
        if (side == 1) planeBits &= ~bit;
    }

    if (node->contents != CONTENTS_NODE) {
        bspMsurface_t **mark = node->firstmarksurface;
        int c = node->nummarksurfaces;
        while (c-- > 0 && mark != NULL) {
            MetalWorldAppendSurfaceDraws(*mark, surfaceStamp, vieworg, frustum);
            mark++;
        }
        return;
    }

    MetalWorldRecursiveNode(node->children[0], planeBits, frustum, vieworg, surfaceStamp);
    MetalWorldRecursiveNode(node->children[1], planeBits, frustum, vieworg, surfaceStamp);
}

static void MetalWorldBuildVisibleDraws(const vec3_t vieworg,
                                        const vec3_t axis0,
                                        const vec3_t axis1,
                                        const vec3_t axis2,
                                        float fovX,
                                        float fovY,
                                        const byte *areamask) {
    cplane_t frustum[4];
    uint32_t surfaceStamp;

    s_world.visibleDrawsValid = qfalse;
    s_world.visibleDrawCount = 0;

    if (!s_world.loaded || !s_bspWorld.loaded || s_bspWorld.nodes == NULL ||
        s_world.draws == NULL || s_world.visibleDraws == NULL ||
        s_world.surfaceDrawRanges == NULL || s_world.visibleDrawCapacity == 0) {
        return;
    }

    MetalWorldMarkLeaves(vieworg, areamask);
    if (s_world.visibleVisCount == 0) {
        return;
    }

    MetalWorldBuildFrustum(frustum, vieworg, axis0, axis1, axis2, fovX, fovY);
    surfaceStamp = MetalWorldNextSurfaceStamp();
    MetalWorldRecursiveNode(s_bspWorld.nodes, 15, frustum, vieworg, surfaceStamp);
    /* Fog-volume overlay surfaces are authored as boundary sheets for the
     * whole volume, not normal wall/floor detail. PVS/frustum surface culling
     * can drop the one q3dm4 fog sheet after the demo camera starts moving,
     * which makes fog flash for a few startup frames and then disappear.
     * Keep explicit fog overlays resident in the visible stream; depth test and
     * one-sided culling in Swift still prevent them from drawing through walls. */
    MetalWorldAppendFogOverlayDraws();

    if (s_world.visibleDrawCount > 0) {
        s_world.visibleDrawsValid = qtrue;
    }
}

static uint32_t MetalWorldCurrentDrawCount(void) {
    return (s_world.visibleDrawsValid) ? s_world.visibleDrawCount : s_world.drawCount;
}

static int MetalWorldBlendClass(uint32_t src, uint32_t dst) {
    if (src == Q3_GL_ONE && dst == Q3_GL_ONE) return 5;
    if (src == Q3_GL_SRC_ALPHA && dst == Q3_GL_ONE) return 1;
    if (src == Q3_GL_SRC_ALPHA && dst == Q3_GL_ONE_MINUS_SRC_ALPHA) return 2;
    if ((src == Q3_GL_DST_COLOR && dst == Q3_GL_ZERO) ||
        (src == Q3_GL_ZERO && dst == Q3_GL_SRC_COLOR)) return 3;
    if (src == Q3_GL_ZERO && dst == Q3_GL_ONE_MINUS_SRC_COLOR) return 4;
    return 0;
}

static uint32_t MetalWorldStageRenderPass(const Q3MetalWorldStage *stage) {
    int blendMode;
    if (stage == NULL) return 0;
    blendMode = MetalWorldBlendClass(stage->srcBlend, stage->dstBlend);
    if (stage->useLightmap != 0) return 1;
    if (blendMode == 5) return 4;
    if (blendMode == 1) return 3;
    if (blendMode == 2) return 2;
    if (blendMode == 3) return 1;
    return 0;
}

static qboolean MetalWorldDrawHasLightmapStageC(const Q3MetalWorldDrawCmd *draw) {
    uint32_t i;
    uint32_t count;
    if (draw == NULL) return qfalse;
    count = draw->stageCount;
    if (count > Q3_METAL_MAX_STAGES) count = Q3_METAL_MAX_STAGES;
    for (i = 0; i < count; ++i) {
        if (draw->stages[i].useLightmap != 0) return qtrue;
    }
    return qfalse;
}

static qboolean MetalWorldStagesEqualC(const Q3MetalWorldStage *a,
                                       const Q3MetalWorldStage *b) {
    if (a == NULL || b == NULL) return qfalse;
    return (memcmp(a, b, sizeof(*a)) == 0) ? qtrue : qfalse;
}

static qboolean MetalWorldBatchCompatible(const Q3MetalWorldBatchCmd *batch,
                                          const Q3MetalWorldDrawCmd *draw,
                                          const Q3MetalWorldStage *stage,
                                          uint32_t stageIndex,
                                          uint32_t renderPass) {
    const Q3MetalWorldDrawCmd *baseDraw;
    if (batch == NULL || draw == NULL || stage == NULL) return qfalse;
    if (batch->renderPass != renderPass || batch->stageIndex != stageIndex) return qfalse;

    baseDraw = &batch->draw;
    if (baseDraw->lightmapTextureHandle != draw->lightmapTextureHandle ||
        baseDraw->flags != draw->flags ||
        baseDraw->fogIndex != draw->fogIndex ||
        baseDraw->stageCount != draw->stageCount) {
        return qfalse;
    }
    if (MetalWorldDrawHasLightmapStageC(baseDraw) != MetalWorldDrawHasLightmapStageC(draw)) {
        return qfalse;
    }
    if (stageIndex >= draw->stageCount || stageIndex >= baseDraw->stageCount ||
        stageIndex >= Q3_METAL_MAX_STAGES) {
        return qfalse;
    }
    return MetalWorldStagesEqualC(&baseDraw->stages[stageIndex], stage);
}

static qboolean MetalWorldEnsureBatchCapacity(uint32_t batchCapacity,
                                              uint32_t entryCapacity,
                                              uint32_t indexCapacity) {
    if (batchCapacity > s_world.batchCapacity) {
        Q3MetalWorldBatchCmd *newBatches =
            ri.Malloc(batchCapacity * sizeof(*newBatches));
        if (newBatches == NULL) return qfalse;
        if (s_world.batches != NULL) ri.Free(s_world.batches);
        s_world.batches = newBatches;
        s_world.batchCapacity = batchCapacity;
    }
    if (entryCapacity > s_world.batchEntryCapacity) {
        Q3MetalWorldBatchEntry *newEntries =
            ri.Malloc(entryCapacity * sizeof(*newEntries));
        if (newEntries == NULL) return qfalse;
        if (s_world.batchEntries != NULL) ri.Free(s_world.batchEntries);
        s_world.batchEntries = newEntries;
        s_world.batchEntryCapacity = entryCapacity;
    }
    if (indexCapacity > s_world.batchIndexCapacity) {
        uint32_t *newIndices = ri.Malloc(indexCapacity * sizeof(*newIndices));
        if (newIndices == NULL) return qfalse;
        if (s_world.batchIndices != NULL) ri.Free(s_world.batchIndices);
        s_world.batchIndices = newIndices;
        s_world.batchIndexCapacity = indexCapacity;
    }
    if (batchCapacity > s_world.batchWriteCursorCapacity) {
        uint32_t *newCursors = ri.Malloc(batchCapacity * sizeof(*newCursors));
        if (newCursors == NULL) return qfalse;
        if (s_world.batchWriteCursors != NULL) ri.Free(s_world.batchWriteCursors);
        s_world.batchWriteCursors = newCursors;
        s_world.batchWriteCursorCapacity = batchCapacity;
    }
    return qtrue;
}

static uint32_t MetalWorldFindOrCreateBatch(const Q3MetalWorldDrawCmd *draw,
                                            const Q3MetalWorldStage *stage,
                                            uint32_t stageIndex,
                                            uint32_t renderPass) {
    uint32_t i;
    for (i = 0; i < s_world.batchCount; ++i) {
        if (MetalWorldBatchCompatible(&s_world.batches[i], draw, stage,
                                      stageIndex, renderPass)) {
            return i;
        }
    }
    if (s_world.batchCount >= s_world.batchCapacity) {
        return UINT32_MAX;
    }
    i = s_world.batchCount++;
    Com_Memset(&s_world.batches[i], 0, sizeof(s_world.batches[i]));
    s_world.batches[i].renderPass = renderPass;
    s_world.batches[i].stageIndex = stageIndex;
    s_world.batches[i].draw = *draw;
    return i;
}

uint32_t Q3MetalRenderer_BuildWorldBatches(uint32_t passMask) {
    const Q3MetalWorldDrawCmd *draws;
    uint32_t drawCount;
    uint32_t maxEntries;
    uint32_t maxBatches;
    uint32_t drawIndex;
    uint32_t entryIndex;
    uint32_t batchIndex;
    uint32_t cursor;
    qboolean overflow;

    s_world.batchCount = 0;
    s_world.batchIndexCount = 0;
    s_world.batchEntryCount = 0;

    if (!s_world.loaded || s_world.indices == NULL || passMask == 0) {
        return 0;
    }

    draws = (s_world.visibleDrawsValid && s_world.visibleDraws != NULL)
        ? s_world.visibleDraws
        : s_world.draws;
    drawCount = MetalWorldCurrentDrawCount();
    if (draws == NULL || drawCount == 0) {
        return 0;
    }

    maxEntries = drawCount * Q3_METAL_MAX_STAGES;
    maxBatches = (maxEntries < 4096u) ? maxEntries : 4096u;
    if (!MetalWorldEnsureBatchCapacity(maxBatches, maxEntries, s_world.indexCount * Q3_METAL_MAX_STAGES)) {
        return 0;
    }
    if (s_world.batches == NULL || s_world.batchEntries == NULL ||
        s_world.batchIndices == NULL || s_world.batchWriteCursors == NULL) {
        return 0;
    }

    overflow = qfalse;
    for (drawIndex = 0; drawIndex < drawCount; ++drawIndex) {
        const Q3MetalWorldDrawCmd *draw = &draws[drawIndex];
        uint32_t stageCount;
        uint32_t stageIndex;

        if (draw->indexCount == 0) continue;
        if ((draw->flags & (Q3_METAL_WORLD_DRAWFLAG_SKY |
                            Q3_METAL_WORLD_DRAWFLAG_FOG_ONLY)) != 0) {
            continue;
        }
        if (draw->firstIndex >= s_world.indexCount ||
            draw->firstIndex + draw->indexCount > s_world.indexCount) {
            continue;
        }

        stageCount = draw->stageCount;
        if (stageCount > Q3_METAL_MAX_STAGES) stageCount = Q3_METAL_MAX_STAGES;
        for (stageIndex = 0; stageIndex < stageCount; ++stageIndex) {
            const Q3MetalWorldStage *stage = &draw->stages[stageIndex];
            uint32_t renderPass = MetalWorldStageRenderPass(stage);
            uint32_t mask = (renderPass < 32) ? (1u << renderPass) : 0u;
            if ((passMask & mask) == 0) continue;

            batchIndex = MetalWorldFindOrCreateBatch(draw, stage, stageIndex, renderPass);
            if (batchIndex == UINT32_MAX || s_world.batchEntryCount >= s_world.batchEntryCapacity) {
                overflow = qtrue;
                break;
            }
            s_world.batchEntries[s_world.batchEntryCount].drawIndex = drawIndex;
            s_world.batchEntries[s_world.batchEntryCount].stageIndex = stageIndex;
            s_world.batchEntries[s_world.batchEntryCount].batchIndex = batchIndex;
            s_world.batchEntryCount += 1;
            s_world.batches[batchIndex].indexCount += draw->indexCount;
            s_world.batchIndexCount += draw->indexCount;
        }
        if (overflow) break;
    }

    if (overflow || s_world.batchCount == 0 || s_world.batchIndexCount == 0 ||
        s_world.batchIndexCount > s_world.batchIndexCapacity) {
        s_world.batchCount = 0;
        s_world.batchIndexCount = 0;
        s_world.batchEntryCount = 0;
        return 0;
    }

    cursor = 0;
    for (batchIndex = 0; batchIndex < s_world.batchCount; ++batchIndex) {
        s_world.batches[batchIndex].firstIndex = cursor;
        s_world.batchWriteCursors[batchIndex] = cursor;
        cursor += s_world.batches[batchIndex].indexCount;
    }

    for (entryIndex = 0; entryIndex < s_world.batchEntryCount; ++entryIndex) {
        Q3MetalWorldBatchEntry *entry = &s_world.batchEntries[entryIndex];
        const Q3MetalWorldDrawCmd *draw;
        uint32_t writeCursor;
        if (entry->batchIndex >= s_world.batchCount || entry->drawIndex >= drawCount) continue;
        draw = &draws[entry->drawIndex];
        if (draw->indexCount == 0) continue;
        writeCursor = s_world.batchWriteCursors[entry->batchIndex];
        if (writeCursor + draw->indexCount > s_world.batchIndexCapacity) continue;
        Com_Memcpy(&s_world.batchIndices[writeCursor],
                   &s_world.indices[draw->firstIndex],
                   draw->indexCount * sizeof(uint32_t));
        s_world.batchWriteCursors[entry->batchIndex] = writeCursor + draw->indexCount;
    }

    return s_world.batchCount;
}

const Q3MetalWorldBatchCmd *Q3MetalRenderer_GetWorldBatches(void) {
    return s_world.batches;
}

uint32_t Q3MetalRenderer_GetWorldBatchCount(void) {
    return s_world.batchCount;
}

const uint32_t *Q3MetalRenderer_GetWorldBatchIndices(void) {
    return s_world.batchIndices;
}

uint32_t Q3MetalRenderer_GetWorldBatchIndexCount(void) {
    return s_world.batchIndexCount;
}

/* ========================================================================== */

static void MetalWorldEmitSurfaceStages(const char *shaderName,
                                        qhandle_t lightmapHandle,
                                        qhandle_t skyOverrideTexture,
                                        qboolean hasLightmap,
                                        uint32_t worldFlags,
                                        uint32_t fogIndex,
                                        uint32_t firstIndexForDraw,
                                        uint32_t indexCountForDraw,
                                        uint32_t *drawCursorPtr) {
    const metalShaderMap_t *_e;
    int _s;
    int _emitted;
    int _combinedLightmapBaseStage;
    qboolean _combinedLightmap;

    if (shaderName == NULL || drawCursorPtr == NULL || indexCountForDraw == 0) {
        return;
    }

    _e = ShaderMap_LookupEntry(shaderName);
    _emitted = 0;
    _combinedLightmapBaseStage = MetalShaderCombinedLightmapBaseStage(_e, hasLightmap, lightmapHandle);
    _combinedLightmap = (_combinedLightmapBaseStage >= 0) ? qtrue : qfalse;
    EmitMetalStageAudit(shaderName, _e);

    if (_e != NULL && _e->hasFog) {
        Q3MetalStage _fogStage;
        uint32_t _dstIdx;
        if (fogIndex == Q3_METAL_NO_FOG) {
            return;
        }
        _dstIdx = (*drawCursorPtr)++;
        Com_Memset(&_fogStage, 0, sizeof(_fogStage));
        _fogStage.blendMode = 2;
        RawBlendFromMode(_fogStage.blendMode, &_fogStage.rawSrcBlend, &_fogStage.rawDstBlend);
        _fogStage.cullMode = _e->cullMode;
        _fogStage.depthWrite = 0;
        SetupWorldDraw(&s_world.draws[_dstIdx], firstIndexForDraw, indexCountForDraw,
                       EnsureWhiteTexture(),
                       worldFlags | Q3_METAL_WORLD_DRAWFLAG_FOG_OVERLAY |
                           Q3_METAL_WORLD_DRAWFLAG_FOG_ONLY,
                       fogIndex);
        AddWorldDrawStage(&s_world.draws[_dstIdx], EnsureWhiteTexture(), &_fogStage);
        EmitMetalDrawPlan(shaderName, -2, &s_world.draws[_dstIdx], &_fogStage,
                          EnsureWhiteTexture(), qfalse);
        return;
    }

    if (_e != NULL && _e->stageCount > 0) {
        for (_s = 0; _s < _e->stageCount; ++_s) {
            const Q3MetalStage *_st = &_e->stages[_s];
            Q3MetalStage _drawStage;
            qhandle_t _tex;
            uint32_t _dstIdx;
            uint32_t _drawFlags;
            if (_combinedLightmap && _st->useLightmap) {
                continue;
            }
            _drawStage = *_st;
            _drawStage.cullMode = _e->cullMode;
            if (_combinedLightmap && _s == _combinedLightmapBaseStage && _drawStage.blendMode == 3) {
                _drawStage.blendMode = 0;
                RawBlendFromMode(_drawStage.blendMode, &_drawStage.rawSrcBlend, &_drawStage.rawDstBlend);
                _drawStage.depthWrite = 1;
            }
            if (_st->animFrameCount > 0) {
                int _idx;
                float _fps = (_st->animFps > 0.0f) ? _st->animFps : 8.0f;
                _idx = (int)((float)cls.realtime * 0.001f * _fps) % _st->animFrameCount;
                if (_idx < 0) _idx = 0;
                if (_st->animTextures[_idx] == 0) {
                    ((Q3MetalStage *)_st)->animTextures[_idx] = RegisterTexture(_st->animFrames[_idx]);
                }
                _tex = _st->animTextures[_idx];
            } else if (_st->useLightmap) {
                _tex = lightmapHandle;
            } else if (_s == 0 && skyOverrideTexture != 0) {
                _tex = skyOverrideTexture;
            } else {
                _tex = (_st->mapPath[0] != '\0') ? RegisterTexture(_st->mapPath) : 0;
            }
            if (_tex == 0) continue;
            _dstIdx = (*drawCursorPtr)++;
            _drawFlags = worldFlags;
            if (_combinedLightmap && _s == _combinedLightmapBaseStage) {
                _drawFlags |= Q3_METAL_WORLD_DRAWFLAG_COMBINED_LIGHTMAP;
            }
            SetupWorldDraw(&s_world.draws[_dstIdx], firstIndexForDraw, indexCountForDraw,
                           hasLightmap ? lightmapHandle : EnsureWhiteTexture(), _drawFlags, fogIndex);
            if (s_world.animShaderSlots && s_pendingAnimSlot >= 0 && _st->animFrameCount > 0) {
                s_world.animShaderSlots[_dstIdx] = s_pendingAnimSlot * Q3_MAX_STAGES + _s;
                s_world.animatedDrawCount += 1;
            }
            AddWorldDrawStage(&s_world.draws[_dstIdx], _tex, &_drawStage);
            EmitMetalDrawPlan(shaderName, _s, &s_world.draws[_dstIdx], &_drawStage, _tex, qfalse);
            _emitted += 1;
        }
    }

    if (_e == NULL || _e->stageCount == 0 || _emitted == 0) {
        qhandle_t _tex = (skyOverrideTexture != 0) ? skyOverrideTexture : RegisterTexture(shaderName);
        if (_tex != 0) {
            uint32_t _dstIdx = (*drawCursorPtr)++;
            uint32_t _drawFlags = worldFlags;
            if (_combinedLightmap) {
                _drawFlags |= Q3_METAL_WORLD_DRAWFLAG_COMBINED_LIGHTMAP;
            }
            SetupWorldDraw(&s_world.draws[_dstIdx], firstIndexForDraw, indexCountForDraw,
                           hasLightmap ? lightmapHandle : EnsureWhiteTexture(), _drawFlags, fogIndex);
            if (s_world.animShaderSlots && s_pendingAnimSlot >= 0) {
                s_world.animShaderSlots[_dstIdx] = s_pendingAnimSlot;
                s_world.animatedDrawCount += 1;
            }
            AddWorldDrawStageSimple(&s_world.draws[_dstIdx], _tex, 0, 0, 0);
            if (s_world.draws[_dstIdx].stageCount > 0) {
                Q3MetalStage _simple;
                Com_Memset(&_simple, 0, sizeof(_simple));
                _simple.cullMode = METAL_SHADER_CULL_BACK;
                _simple.depthWrite = 1;
                EmitMetalDrawPlan(shaderName, 0, &s_world.draws[_dstIdx], &_simple, _tex, qfalse);
                _emitted += 1;
            }
        }
    }

    if (!_combinedLightmap && hasLightmap && lightmapHandle != 0 &&
        _emitted > 0 && shaderShouldInjectImplicitLightmap(_e)) {
        uint32_t _ldst = (*drawCursorPtr)++;
        SetupWorldDraw(&s_world.draws[_ldst], firstIndexForDraw, indexCountForDraw,
                       lightmapHandle, worldFlags, fogIndex);
        AddWorldDrawLightmapBaseStage(&s_world.draws[_ldst], lightmapHandle, _e,
                                      /*blendMode=*/3, /*depthWrite=*/0);
    }

    if (fogIndex != Q3_METAL_NO_FOG && MetalShaderShouldEmitFogPass(_e, _emitted)) {
        Q3MetalStage _fogStage;
        uint32_t _fdst;
        Com_Memset(&_fogStage, 0, sizeof(_fogStage));
        _fogStage.blendMode = 2;
        RawBlendFromMode(_fogStage.blendMode, &_fogStage.rawSrcBlend, &_fogStage.rawDstBlend);
        _fogStage.cullMode = (_e != NULL) ? _e->cullMode : METAL_SHADER_CULL_BACK;
        _fogStage.depthWrite = 0;
        _fdst = (*drawCursorPtr)++;
        SetupWorldDraw(&s_world.draws[_fdst], firstIndexForDraw, indexCountForDraw,
                       EnsureWhiteTexture(), worldFlags | Q3_METAL_WORLD_DRAWFLAG_FOG_ONLY, fogIndex);
        AddWorldDrawStage(&s_world.draws[_fdst], EnsureWhiteTexture(), &_fogStage);
    }
}

/* ========================================================================== */

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

    FreeWorldMapData();
    s_worldMapAuditActive = qtrue;

    /* LUMP_FOGS — one dfog_t per fog volume. Resolve each fog's shader
     * into the pre-parsed shader map to recover (r,g,b,distance) from
     * the 'fogparms' directive. Later cycles thread each surface's
     * fogNum (index into this table) into Q3MetalWorldDrawCmd so the
     * Metal fragment shader can apply fog per-surface. */
    {
        const dfog_t *fogs = (const dfog_t *)((const byte *)header +
            LittleLong(header->lumps[LUMP_FOGS].fileofs));
        const dbrush_t *brushes = (const dbrush_t *)((const byte *)header +
            LittleLong(header->lumps[LUMP_BRUSHES].fileofs));
        const dbrushside_t *sides = (const dbrushside_t *)((const byte *)header +
            LittleLong(header->lumps[LUMP_BRUSHSIDES].fileofs));
        const dplane_t *planes = (const dplane_t *)((const byte *)header +
            LittleLong(header->lumps[LUMP_PLANES].fileofs));
        int fogBytes = LittleLong(header->lumps[LUMP_FOGS].filelen);
        int brushCount = LittleLong(header->lumps[LUMP_BRUSHES].filelen) / (int)sizeof(dbrush_t);
        int sideCount = LittleLong(header->lumps[LUMP_BRUSHSIDES].filelen) / (int)sizeof(dbrushside_t);
        int planeCount = LittleLong(header->lumps[LUMP_PLANES].filelen) / (int)sizeof(dplane_t);
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
            s_worldFogs[fi].tcScale = 0.0f;
            s_worldFogs[fi].hasSurface = qfalse;
            s_worldFogs[fi].surface[0] = 0.0f;
            s_worldFogs[fi].surface[1] = 0.0f;
            s_worldFogs[fi].surface[2] = 0.0f;
            s_worldFogs[fi].surface[3] = 0.0f;
            s_worldFogs[fi].hasBounds = qfalse;
            ClearBounds(s_worldFogs[fi].bounds[0], s_worldFogs[fi].bounds[1]);

            fse = ShaderMap_LookupEntry(fogs[fi].shader);
            if (fse != NULL && fse->hasFog) {
                float d = fse->fogDistance < 1.0f ? 1.0f : fse->fogDistance;
                int brushNum = LittleLong(fogs[fi].brushNum);
                int visibleSide = LittleLong(fogs[fi].visibleSide);
                int firstSide = -1;
                s_worldFogs[fi].hasColor = qtrue;
                s_worldFogs[fi].color[0] = fse->fogColor[0];
                s_worldFogs[fi].color[1] = fse->fogColor[1];
                s_worldFogs[fi].color[2] = fse->fogColor[2];
                s_worldFogs[fi].distance = fse->fogDistance;
                s_worldFogs[fi].tcScale = 1.0f / (d * 8.0f);
                if (brushNum >= 0 && brushNum < brushCount) {
                    firstSide = LittleLong(brushes[brushNum].firstSide);
                    if (firstSide >= 0 && firstSide + 5 < sideCount) {
                        int sideNum;
                        int planeNum;
                        const dplane_t *plane;
                        sideNum = firstSide + 0;
                        planeNum = LittleLong(sides[sideNum].planeNum);
                        if (planeNum >= 0 && planeNum < planeCount) {
                            plane = &planes[planeNum];
                            s_worldFogs[fi].bounds[0][0] = -LittleFloat(plane->dist);
                            sideNum = firstSide + 1;
                            planeNum = LittleLong(sides[sideNum].planeNum);
                            if (planeNum >= 0 && planeNum < planeCount) {
                                plane = &planes[planeNum];
                                s_worldFogs[fi].bounds[1][0] = LittleFloat(plane->dist);
                                sideNum = firstSide + 2;
                                planeNum = LittleLong(sides[sideNum].planeNum);
                                if (planeNum >= 0 && planeNum < planeCount) {
                                    plane = &planes[planeNum];
                                    s_worldFogs[fi].bounds[0][1] = -LittleFloat(plane->dist);
                                    sideNum = firstSide + 3;
                                    planeNum = LittleLong(sides[sideNum].planeNum);
                                    if (planeNum >= 0 && planeNum < planeCount) {
                                        plane = &planes[planeNum];
                                        s_worldFogs[fi].bounds[1][1] = LittleFloat(plane->dist);
                                        sideNum = firstSide + 4;
                                        planeNum = LittleLong(sides[sideNum].planeNum);
                                        if (planeNum >= 0 && planeNum < planeCount) {
                                            plane = &planes[planeNum];
                                            s_worldFogs[fi].bounds[0][2] = -LittleFloat(plane->dist);
                                            sideNum = firstSide + 5;
                                            planeNum = LittleLong(sides[sideNum].planeNum);
                                            if (planeNum >= 0 && planeNum < planeCount) {
                                                plane = &planes[planeNum];
                                                s_worldFogs[fi].bounds[1][2] = LittleFloat(plane->dist);
                                                s_worldFogs[fi].hasBounds = qtrue;
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                if (visibleSide != -1 && brushNum >= 0 && brushNum < brushCount) {
                    int sideNum = firstSide + visibleSide;
                    if (sideNum >= 0 && sideNum < sideCount) {
                        int planeNum = LittleLong(sides[sideNum].planeNum);
                        if (planeNum >= 0 && planeNum < planeCount) {
                            const dplane_t *plane = &planes[planeNum];
                            s_worldFogs[fi].hasSurface = qtrue;
                            s_worldFogs[fi].surface[0] = -LittleFloat(plane->normal[0]);
                            s_worldFogs[fi].surface[1] = -LittleFloat(plane->normal[1]);
                            s_worldFogs[fi].surface[2] = -LittleFloat(plane->normal[2]);
                            s_worldFogs[fi].surface[3] = -LittleFloat(plane->dist);
                        }
                    }
                }
                s_worldFogsPublic[fi].color[0] = fse->fogColor[0];
                s_worldFogsPublic[fi].color[1] = fse->fogColor[1];
                s_worldFogsPublic[fi].color[2] = fse->fogColor[2];
                s_worldFogsPublic[fi].distance = fse->fogDistance;
                s_worldFogsPublic[fi].tcScale = s_worldFogs[fi].tcScale;
                s_worldFogsPublic[fi].hasSurface = s_worldFogs[fi].hasSurface ? 1u : 0u;
                s_worldFogsPublic[fi].surface[0] = s_worldFogs[fi].surface[0];
                s_worldFogsPublic[fi].surface[1] = s_worldFogs[fi].surface[1];
                s_worldFogsPublic[fi].surface[2] = s_worldFogs[fi].surface[2];
                s_worldFogsPublic[fi].surface[3] = s_worldFogs[fi].surface[3];
                s_worldFogsPublic[fi].hasBounds = s_worldFogs[fi].hasBounds ? 1u : 0u;
                s_worldFogsPublic[fi].boundsMin[0] = s_worldFogs[fi].bounds[0][0];
                s_worldFogsPublic[fi].boundsMin[1] = s_worldFogs[fi].bounds[0][1];
                s_worldFogsPublic[fi].boundsMin[2] = s_worldFogs[fi].bounds[0][2];
                s_worldFogsPublic[fi].boundsMax[0] = s_worldFogs[fi].bounds[1][0];
                s_worldFogsPublic[fi].boundsMax[1] = s_worldFogs[fi].bounds[1][1];
                s_worldFogsPublic[fi].boundsMax[2] = s_worldFogs[fi].bounds[1][2];
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
        int drawMultiplier = 1;

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
        {
            const metalShaderMap_t *_fe = ShaderMap_LookupEntry(shaders[shaderNum].shader);
            if (_fe != NULL && _fe->hasFog) {
                int _fogNum = LittleLong(surface->fogNum);
                if (_fogNum < 0 || _fogNum >= s_worldFogCount ||
                    !s_worldFogs[_fogNum].hasColor) {
                    skippedNoDrawSurfaces += 1;
                    continue;
                }
                drawMultiplier = 1;
            } else {
                int _fogNum = LittleLong(surface->fogNum);
                if (_fe != NULL && _fe->stageCount > 1) {
                    drawMultiplier = _fe->stageCount;
                }
                if (_fogNum >= 0 && _fogNum < s_worldFogCount &&
                    s_worldFogs[_fogNum].hasColor) {
                    drawMultiplier += 1;
                }
                /* Reserve one extra draw slot for the implicit-lightmap
                 * pass that the emission loop may inject when the shader
                 * has no explicit `map $lightmap` stage. Conservatively
                 * reserved unconditionally so the s_world.draws[]
                 * allocator never under-sizes — overhead is bounded
                 * (a few KB) and avoids a memory-corruption crash from
                 * drawCursor++ exceeding the malloc'd extent. */
                if (shaderShouldInjectImplicitLightmap(_fe)) {
                    drawMultiplier += 1;
                }
            }
        }

        if (surfaceType == MST_PATCH) {
            patchWidth = LittleLong(surface->patchWidth);
            patchHeight = LittleLong(surface->patchHeight);
            totalVertices += (uint32_t)((patchWidth - 1) / 2) * (uint32_t)((patchHeight - 1) / 2) *
                             (Q3_METAL_PATCH_SUBDIVISIONS + 1) * (Q3_METAL_PATCH_SUBDIVISIONS + 1);
            totalIndices += (uint32_t)((patchWidth - 1) / 2) * (uint32_t)((patchHeight - 1) / 2) *
                            Q3_METAL_PATCH_SUBDIVISIONS * Q3_METAL_PATCH_SUBDIVISIONS * 6;
            totalDraws += (uint32_t)((patchWidth - 1) / 2) *
                          (uint32_t)((patchHeight - 1) / 2) *
                          (uint32_t)drawMultiplier;
            patchDraws += (uint32_t)((patchWidth - 1) / 2) * (uint32_t)((patchHeight - 1) / 2);
        } else {
            int numVerts = LittleLong(surface->numVerts);
            int numIndexes = LittleLong(surface->numIndexes);

            if (numIndexes % 3) {
                numIndexes -= numIndexes % 3;
            }
            totalVertices += (uint32_t)numVerts;
            totalIndices += (uint32_t)numIndexes;
            totalDraws += (uint32_t)drawMultiplier;

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
    s_world.visibleDraws = ri.Malloc(totalDraws * sizeof(*s_world.visibleDraws));
    s_world.visibleDrawCapacity = totalDraws;
    s_world.visibleDrawCount = 0;
    s_world.visibleDrawsValid = qfalse;
    s_world.surfaceDrawRanges = ri.Malloc(surfaceCount * sizeof(*s_world.surfaceDrawRanges));
    s_world.surfaceDrawRangeCount = surfaceCount;
    s_world.lastViewCluster = -9999;
    s_world.animShaderSlots = ri.Malloc(totalDraws * sizeof(*s_world.animShaderSlots));
    s_world.animatedDrawCount = 0;
    if (s_world.surfaceDrawRanges != NULL) {
        Com_Memset(s_world.surfaceDrawRanges, 0, surfaceCount * sizeof(*s_world.surfaceDrawRanges));
    }
    if (s_world.animShaderSlots != NULL) {
        uint32_t _i;
        for (_i = 0; _i < totalDraws; ++_i) s_world.animShaderSlots[_i] = -1;
    }
    if (s_world.vertices == NULL || s_world.indices == NULL ||
        s_world.draws == NULL || s_world.visibleDraws == NULL ||
        s_world.surfaceDrawRanges == NULL) {
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
        uint32_t surfaceFirstDraw;
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
        {
            const metalShaderMap_t *_fe = ShaderMap_LookupEntry(shaders[shaderNum].shader);
            if (_fe != NULL && _fe->hasFog &&
                fogIndex == Q3_METAL_NO_FOG) {
                continue;
            }
        }
        surfaceFirstDraw = drawCursor;
        if (!IsSkyShaderName(shaders[shaderNum].shader) &&
            lightmapNum >= 0 && lightmapNum < s_worldLightmapCount) {
            lightmapHandle = s_worldLightmapHandles[lightmapNum];
            hasLightmap = qtrue;
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
            uint32_t firstIndexForDraw;

            patchWidth = LittleLong(surface->patchWidth);
            patchHeight = LittleLong(surface->patchHeight);
            firstIndexForDraw = indexCursor;

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
                }
            }

            if (indexCursor > firstIndexForDraw) {
                MetalWorldEmitSurfaceStages(shaders[shaderNum].shader,
                                            lightmapHandle,
                                            skyOverrideTexture,
                                            hasLightmap,
                                            worldFlags,
                                            fogIndex,
                                            firstIndexForDraw,
                                            indexCursor - firstIndexForDraw,
                                            &drawCursor);
            }
            MetalWorldSetSurfaceDrawRange(i, surfaceFirstDraw, drawCursor);
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
            if (indexCountForDraw > 0) {
                MetalWorldEmitSurfaceStages(shaders[shaderNum].shader,
                                            lightmapHandle,
                                            skyOverrideTexture,
                                            hasLightmap,
                                            worldFlags,
                                            fogIndex,
                                            firstIndexForDraw,
                                            indexCountForDraw,
                                            &drawCursor);
            }
        }
        MetalWorldSetSurfaceDrawRange(i, surfaceFirstDraw, drawCursor);
    }

	    s_world.loaded = qtrue;
    s_world.generation += 1;
    s_world.vertexCount = vertexCursor;
    s_world.indexCount = indexCursor;
    s_world.drawCount = drawCursor;
    Q_strncpyz(s_world.name, name, sizeof(s_world.name));

    {
        uint32_t di;
        uint32_t fogOnlyDraws = 0;
        uint32_t fogVolumeDraws = 0;
        for (di = 0; di < s_world.drawCount; ++di) {
            if ((s_world.draws[di].flags & Q3_METAL_WORLD_DRAWFLAG_FOG_ONLY) != 0) {
                fogOnlyDraws += 1;
                if ((s_world.draws[di].flags & Q3_METAL_WORLD_DRAWFLAG_FOG_OVERLAY) != 0) {
                    fogVolumeDraws += 1;
                }
            }
        }
        if (fogOnlyDraws > 0) {
            ri.Printf(PRINT_ALL,
                      "Metal world: %u fog pass draws (%u fog-volume surfaces)\n",
                      fogOnlyDraws, fogVolumeDraws);
        }
    }

    /* Post-load: bake per-quad center into autospriteCenter for every
     * vertex that belongs to an autosprite-flagged draw. Q3 emits
     * autosprite surfaces as N quads of 4 verts each, indexed as
     * (i*4+0, i*4+1, i*4+2, i*4+0, i*4+2, i*4+3). The 4 corners share
     * a center; the vertex shader uses that center + `cameraRight/Up`
     * to emit a camera-aligned billboard. Mirrors ioq3
     * RB_AutospriteDeform's per-quad center step (tr_shade_calc.c).
     *
     * Only fires for AUTOSPRITE / AUTOSPRITE2 draws — non-autosprite
     * vertices stay zero (vertex shader detects via length(center)≈0). */
    {
        uint32_t di;
        for (di = 0; di < s_world.drawCount; ++di) {
            const Q3MetalWorldDrawCmd *d = &s_world.draws[di];
            if ((d->flags & (Q3_METAL_WORLD_DRAWFLAG_AUTOSPRITE
                           | Q3_METAL_WORLD_DRAWFLAG_AUTOSPRITE2)) == 0) {
                continue;
            }
            /* Walk the index buffer in 6-index quad chunks. q3map2
             * emits autosprite quads as exactly two triangles sharing
             * indices (i, i+1, i+2, i, i+2, i+3). Group every 6
             * contiguous indices, dedup to the 4 unique vertex
             * indices, average their positions. */
            uint32_t firstIdx = d->firstIndex;
            uint32_t idxCount = d->indexCount;
            if (idxCount < 6 || (idxCount % 6) != 0) continue;
            for (uint32_t q = 0; q < idxCount; q += 6) {
                /* Six index slots → four unique verts. Use a sorted
                 * dedup so we don't double-count. */
                uint32_t idxs[6];
                for (int k = 0; k < 6; ++k) idxs[k] = s_world.indices[firstIdx + q + k];
                uint32_t uniq[4]; int nUniq = 0;
                for (int k = 0; k < 6 && nUniq < 4; ++k) {
                    int seen = 0;
                    for (int u = 0; u < nUniq; ++u) {
                        if (uniq[u] == idxs[k]) { seen = 1; break; }
                    }
                    if (!seen) uniq[nUniq++] = idxs[k];
                }
                if (nUniq != 4) continue;
                float cx = 0.0f, cy = 0.0f, cz = 0.0f;
                for (int u = 0; u < 4; ++u) {
                    cx += s_world.vertices[uniq[u]].position[0];
                    cy += s_world.vertices[uniq[u]].position[1];
                    cz += s_world.vertices[uniq[u]].position[2];
                }
                cx *= 0.25f; cy *= 0.25f; cz *= 0.25f;
                for (int u = 0; u < 4; ++u) {
                    s_world.vertices[uniq[u]].autospriteCenter[0] = cx;
                    s_world.vertices[uniq[u]].autospriteCenter[1] = cy;
                    s_world.vertices[uniq[u]].autospriteCenter[2] = cz;
                    s_world.vertices[uniq[u]].autospriteCenter[3] = 0.0f;
                }
                /* For autoSprite2 only, also bake the long-axis direction.
                 * Mirrors ioq3 RB_Autosprite2Deform: find the two shortest
                 * of the 6 candidate edges among 4 corners; long axis is
                 * the unit vector from midpoint(short1) → midpoint(short2).
                 * Independent of perimeter order, so robust to any q3map2
                 * quad emission convention. */
                if ((d->flags & Q3_METAL_WORLD_DRAWFLAG_AUTOSPRITE2) != 0) {
                    static const int edgePairs[6][2] = {
                        {0,1},{0,2},{0,3},{1,2},{1,3},{2,3}
                    };
                    float lenSq[6];
                    for (int e = 0; e < 6; ++e) {
                        const float *p1 = s_world.vertices[uniq[edgePairs[e][0]]].position;
                        const float *p2 = s_world.vertices[uniq[edgePairs[e][1]]].position;
                        float dx = p1[0] - p2[0];
                        float dy = p1[1] - p2[1];
                        float dz = p1[2] - p2[2];
                        lenSq[e] = dx*dx + dy*dy + dz*dz;
                    }
                    int s1 = 0, s2 = 0;
                    float l1 = 1e30f, l2 = 1e30f;
                    for (int e = 0; e < 6; ++e) {
                        if (lenSq[e] < l1) {
                            l2 = l1; s2 = s1;
                            l1 = lenSq[e]; s1 = e;
                        } else if (lenSq[e] < l2) {
                            l2 = lenSq[e]; s2 = e;
                        }
                    }
                    const float *a1 = s_world.vertices[uniq[edgePairs[s1][0]]].position;
                    const float *b1 = s_world.vertices[uniq[edgePairs[s1][1]]].position;
                    const float *a2 = s_world.vertices[uniq[edgePairs[s2][0]]].position;
                    const float *b2 = s_world.vertices[uniq[edgePairs[s2][1]]].position;
                    float m1x = 0.5f * (a1[0] + b1[0]);
                    float m1y = 0.5f * (a1[1] + b1[1]);
                    float m1z = 0.5f * (a1[2] + b1[2]);
                    float m2x = 0.5f * (a2[0] + b2[0]);
                    float m2y = 0.5f * (a2[1] + b2[1]);
                    float m2z = 0.5f * (a2[2] + b2[2]);
                    float ax = m2x - m1x;
                    float ay = m2y - m1y;
                    float az = m2z - m1z;
                    float alen = sqrtf(ax*ax + ay*ay + az*az);
                    if (alen > 1e-4f) {
                        float inv = 1.0f / alen;
                        ax *= inv; ay *= inv; az *= inv;
                        for (int u = 0; u < 4; ++u) {
                            s_world.vertices[uniq[u]].autospriteLongAxis[0] = ax;
                            s_world.vertices[uniq[u]].autospriteLongAxis[1] = ay;
                            s_world.vertices[uniq[u]].autospriteLongAxis[2] = az;
                            s_world.vertices[uniq[u]].autospriteLongAxis[3] = 0.0f;
                        }
                    }
                }
            }
        }
    }

    /* Parallel BSP tree for R_MarkFragments — additive, does not touch
     * the Metal draw pipeline above. */
    BspLoad(header, (const byte *)fileBuffer,
            surfaces, surfaceCount,
            drawVerts, drawVertCount,
            drawIndexes, drawIndexCount);

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
    Q3_FileLogf("[Q3] Metal world: loaded '%s' verts=%u indices=%u draws=%u (cap=%d) planar=%u patch=%u trisoup=%u sky=%u flares=%d",
                name, s_world.vertexCount, s_world.indexCount, s_world.drawCount,
                Q3_METAL_MAX_DRAWS,
                planarDraws, patchDraws, triSoupDraws, skyDraws, s_worldFlareCount);
    if (s_world.drawCount >= Q3_METAL_MAX_DRAWS) {
        Q3_FileLogf("[Q3] Metal world: WARNING drawCount=%u >= cap=%d — surfaces past cap may corrupt or drop",
                    s_world.drawCount, Q3_METAL_MAX_DRAWS);
    }
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
    int i, s;
    if (name == NULL || name[0] == '\0') return -1;
    for (i = 0; i < s_shaderMapCount; ++i) {
        if (!Q_stricmp(s_shaderMap[i].shaderName, name)) {
            if (s_shaderMap[i].animFrameCount > 0) return i;
            for (s = 0; s < s_shaderMap[i].stageCount; ++s) {
                if (s_shaderMap[i].stages[s].animFrameCount > 0) return i;
            }
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
 *   1 = additive   (GL_SRC_ALPHA/GL_ONE — alpha-modulated additive)
 *   2 = alpha      (GL_SRC_ALPHA/GL_ONE_MINUS_SRC_ALPHA)
 *   3 = filter     (GL_DST_COLOR/GL_ZERO and commutative form GL_ZERO/GL_SRC_COLOR)
 *   4 = subtract   (GL_ZERO/GL_ONE_MINUS_SRC_COLOR — blood/bullet/shadow decals)
 *   5 = additive-full (GL_ONE/GL_ONE — full-intensity, ignores alpha)
 * CRITICAL: 1 and 5 MUST stay distinct. Merging them leaks full-intensity
 * explosion/glow shaders through an alpha-modulated pipeline (or vice versa),
 * producing scene-wide yellow/gold blowout when the alpha channel is close
 * to 1 across the full quad.
 */
static int BlendModeFromTokens(const char *src, const char *dst) {
    if (src == NULL || src[0] == '\0') return 0;

    /* Short Q3 aliases — these are dst-independent. "add" is the
     * Q3 shorthand for GL_ONE/GL_ONE (full-intensity additive). */
    if (!Q_stricmp(src, "add"))    return 5;
    if (!Q_stricmp(src, "blend"))  return 2;
    if (!Q_stricmp(src, "filter")) return 3;

    if (dst == NULL || dst[0] == '\0') return 0;

    /* Full-intensity additive (GL_ONE/GL_ONE) — explosion cores, muzzle
     * flash, rail core. Distinct from mode 1 (alpha-modulated). */
    if (!Q_stricmp(src, "GL_ONE") && !Q_stricmp(dst, "GL_ONE")) return 5;
    /* Alpha-modulated additive (GL_SRC_ALPHA/GL_ONE) — flame, glow,
     * particles. Source alpha attenuates the added colour. */
    if (!Q_stricmp(src, "GL_SRC_ALPHA") && !Q_stricmp(dst, "GL_ONE")) return 1;
    /* Alpha blend (transparent decals, glass). */
    if (!Q_stricmp(src, "GL_SRC_ALPHA") && !Q_stricmp(dst, "GL_ONE_MINUS_SRC_ALPHA")) return 2;
    /* Filter / modulate (lightmap pass, dark overlay). */
    if (!Q_stricmp(src, "GL_DST_COLOR") && !Q_stricmp(dst, "GL_ZERO")) return 3;
    /* Q3 floor/portal shaders commonly use this for their final lightmap
     * modulation stage. The default framebuffer alpha is effectively 1, so
     * the RGB result is the same read-modify-write filter path, not an
     * opaque depth-writing pass. */
    if (!Q_stricmp(src, "GL_DST_COLOR") && !Q_stricmp(dst, "GL_ONE_MINUS_DST_ALPHA")) return 3;
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

    /* GL_DST_COLOR / X family — all read the framebuffer as a multiplier
     * (read-modify-write). Q3 uses these for floor / portal / lightmap
     * stages. ALL must route to filter so depth-write stays off; otherwise
     * the stage corrupts the depth buffer and surfaces behind it leak
     * through (q3dm6 floor → lit-walls / lava bleed-through, demo four
     * 0:33–0:35). Mirrors ioq3 `depthMaskBits = 0` rule for any blend. */
    if (!Q_stricmp(src, "GL_DST_COLOR") && !Q_stricmp(dst, "GL_ONE_MINUS_SRC_ALPHA")) return 3;
    if (!Q_stricmp(src, "GL_DST_COLOR") && !Q_stricmp(dst, "GL_ONE_MINUS_SRC_COLOR")) return 3;
    if (!Q_stricmp(src, "GL_DST_COLOR") && !Q_stricmp(dst, "GL_ONE"))                  return 3;
    if (!Q_stricmp(src, "GL_DST_COLOR") && !Q_stricmp(dst, "GL_SRC_ALPHA"))            return 3;
    if (!Q_stricmp(src, "GL_DST_COLOR") && !Q_stricmp(dst, "GL_SRC_COLOR"))            return 3;
    /* (1-dst.color)*src — invert-multiply. Filter-class (depth-read-only). */
    if (!Q_stricmp(src, "GL_ONE_MINUS_DST_COLOR") && !Q_stricmp(dst, "GL_ZERO"))               return 3;
    if (!Q_stricmp(src, "GL_ONE_MINUS_DST_COLOR") && !Q_stricmp(dst, "GL_ONE_MINUS_SRC_ALPHA")) return 2;
    /* GL_ZERO / X family — source contributes nothing; result is purely a
     * destination scale. Pass-through / dst-alpha-multiply / etc. All
     * filter-class. */
    if (!Q_stricmp(src, "GL_ZERO") && !Q_stricmp(dst, "GL_ONE"))       return 3;
    if (!Q_stricmp(src, "GL_ZERO") && !Q_stricmp(dst, "GL_SRC_ALPHA")) return 3;
    /* GL_ONE / X additive variants. Premultiplied alpha + alpha-modulated
     * additive — closest to alpha (mode 2, depth-read-only).  */
    if (!Q_stricmp(src, "GL_ONE") && !Q_stricmp(dst, "GL_ONE_MINUS_SRC_ALPHA")) return 2;
    if (!Q_stricmp(src, "GL_ONE") && !Q_stricmp(dst, "GL_ONE_MINUS_SRC_COLOR")) return 2;
    if (!Q_stricmp(src, "GL_ONE") && !Q_stricmp(dst, "GL_SRC_ALPHA"))            return 2;
    if (!Q_stricmp(src, "GL_ONE") && !Q_stricmp(dst, "GL_SRC_COLOR"))            return 3;
    /* (1-src.a)*src + dst*src.a — inverted alpha (decal trick). Alpha-class. */
    if (!Q_stricmp(src, "GL_ONE_MINUS_SRC_ALPHA") && !Q_stricmp(dst, "GL_SRC_ALPHA")) return 2;

    /* Unknown combo: warn once and fall back to filter (depth-read-only).
     * Routing the unclassified default to filter instead of opaque
     * mirrors ioq3 tr_shader.c's `depthMaskBits = 0 if blendFunc set`
     * invariant — losing precise blend math is far less visible than the
     * depth-corruption that comes from running with depth-write ON. */
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
            ri.Printf(PRINT_WARNING, "Metal shader: unrecognized blendFunc '%s %s' → filter (depth-write off)\n", src, dst);
        }
    }
    return 3;
}

static uint32_t GLBlendFactorFromToken(const char *token) {
    if (token == NULL || token[0] == '\0') return Q3_GL_ONE;
    if (!Q_stricmp(token, "GL_ZERO")) return Q3_GL_ZERO;
    if (!Q_stricmp(token, "GL_ONE")) return Q3_GL_ONE;
    if (!Q_stricmp(token, "GL_SRC_COLOR")) return Q3_GL_SRC_COLOR;
    if (!Q_stricmp(token, "GL_ONE_MINUS_SRC_COLOR")) return Q3_GL_ONE_MINUS_SRC_COLOR;
    if (!Q_stricmp(token, "GL_SRC_ALPHA")) return Q3_GL_SRC_ALPHA;
    if (!Q_stricmp(token, "GL_ONE_MINUS_SRC_ALPHA")) return Q3_GL_ONE_MINUS_SRC_ALPHA;
    if (!Q_stricmp(token, "GL_DST_ALPHA")) return Q3_GL_DST_ALPHA;
    if (!Q_stricmp(token, "GL_ONE_MINUS_DST_ALPHA")) return Q3_GL_ONE_MINUS_DST_ALPHA;
    if (!Q_stricmp(token, "GL_DST_COLOR")) return Q3_GL_DST_COLOR;
    if (!Q_stricmp(token, "GL_ONE_MINUS_DST_COLOR")) return Q3_GL_ONE_MINUS_DST_COLOR;
    if (!Q_stricmp(token, "add")) return Q3_GL_ONE;
    if (!Q_stricmp(token, "blend")) return Q3_GL_SRC_ALPHA;
    if (!Q_stricmp(token, "filter")) return Q3_GL_DST_COLOR;
    return Q3_GL_ONE;
}

static uint32_t GLBlendDstFromTokens(const char *src, const char *dst) {
    if (src != NULL && !Q_stricmp(src, "add")) return Q3_GL_ONE;
    if (src != NULL && !Q_stricmp(src, "blend")) return Q3_GL_ONE_MINUS_SRC_ALPHA;
    if (src != NULL && !Q_stricmp(src, "filter")) return Q3_GL_ZERO;
    return GLBlendFactorFromToken(dst);
}

static Q3cTcGen CleanTcGenFromMetal(int tcGen, int useLightmap) {
    if (useLightmap) return Q3C_TCGEN_LIGHTMAP;
    if (tcGen == 1) return Q3C_TCGEN_ENVIRONMENT_MAPPED;
    if (tcGen == 2) return Q3C_TCGEN_VECTOR;
    return Q3C_TCGEN_BASE;
}

static void ApplyCleanStageToMetalStage(const Q3cShaderStage *clean,
                                        Q3MetalStage *stage) {
    int i;
    if (clean == NULL || stage == NULL) return;
    if (clean->image[0]) Q_strncpyz(stage->mapPath, clean->image, sizeof(stage->mapPath));
    stage->useLightmap = clean->isLightmap ? 1 : 0;
    if (clean->animFrameCount > 0) {
        int count = (int)clean->animFrameCount;
        if (count > METAL_ANIMMAP_MAX_FRAMES) count = METAL_ANIMMAP_MAX_FRAMES;
        stage->animFrameCount = count;
        stage->animFps = clean->animFrequency;
        for (i = 0; i < count; ++i) {
            Q_strncpyz(stage->animFrames[i], clean->animFrames[i], MAX_QPATH);
        }
        Q_strncpyz(stage->mapPath, stage->animFrames[0], sizeof(stage->mapPath));
    }
    stage->tcGen = (clean->tcGen == Q3C_TCGEN_ENVIRONMENT_MAPPED) ? 1 :
                   (clean->tcGen == Q3C_TCGEN_VECTOR) ? 2 : 0;
    stage->tcGenVec0[0] = clean->tcGenVectors[0][0];
    stage->tcGenVec0[1] = clean->tcGenVectors[0][1];
    stage->tcGenVec0[2] = clean->tcGenVectors[0][2];
    stage->tcGenVec0[3] = 0.0f;
    stage->tcGenVec1[0] = clean->tcGenVectors[1][0];
    stage->tcGenVec1[1] = clean->tcGenVectors[1][1];
    stage->tcGenVec1[2] = clean->tcGenVectors[1][2];
    stage->tcGenVec1[3] = 0.0f;
    stage->rawSrcBlend = clean->srcBlend ? clean->srcBlend : Q3_GL_ONE;
    stage->rawDstBlend = clean->dstBlend;
    stage->depthFunc = clean->depthFunc;
    stage->depthWrite = clean->depthWrite ? 1 : stage->depthWrite;
    stage->alphaFunc = (int)clean->alphaFunc;
    stage->wrapClampMode = (int)clean->wrapClampMode;
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

/* Fetch the shader-level deformVertexes wave parameters from stage 0
 * of the resolved shader-map entry. The legacy parser at the registration
 * site stamps these onto every stage (line ~6865) after Q3cShaderGraph_
 * AddDeform captures them at depth==1, so stage 0 is always representative.
 * RegisterTexture calls this so the texture (which is what cgame's
 * customShader resolves to) carries the deform info to the entity uniforms
 * — without this hop, ApplyCleanStageToMetalStage's narrower copy drops
 * the deform fields and the quad shell collapses into the gun silhouette. */
static void ShaderMap_GetDeformWave(const char *name, int *func, float *div, float *base,
                                    float *amp, float *phase, float *freq) {
    const metalShaderMap_t *entry;
    if (func)  *func  = 0;
    if (div)   *div   = 1.0f;
    if (base)  *base  = 0.0f;
    if (amp)   *amp   = 0.0f;
    if (phase) *phase = 0.0f;
    if (freq)  *freq  = 0.0f;
    if (name == NULL || name[0] == '\0') return;
    entry = ShaderMap_LookupEntry(name);
    if (entry == NULL || entry->stageCount <= 0) return;
    if (func)  *func  = (int)entry->stages[0].deformWaveFunc;
    if (div)   *div   = entry->stages[0].deformWaveDiv;
    if (base)  *base  = entry->stages[0].deformWaveBase;
    if (amp)   *amp   = entry->stages[0].deformWaveAmp;
    if (phase) *phase = entry->stages[0].deformWavePhase;
    if (freq)  *freq  = entry->stages[0].deformWaveFreq;
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
static qhandle_t ShaderMap_AnimatedSlotCurrentHandle(int encodedSlot, float shaderTime) {
    int slot = encodedSlot / Q3_MAX_STAGES;
    int stageIndex = encodedSlot % Q3_MAX_STAGES;
    metalShaderMap_t *entry;
    Q3MetalStage *stage = NULL;
    float fps;
    int frameIdx;
    if (slot < 0 || slot >= s_shaderMapCount) return 0;
    entry = &s_shaderMap[slot];
    if (stageIndex >= 0 && stageIndex < entry->stageCount) {
        stage = &entry->stages[stageIndex];
    }
    if (stage != NULL && stage->animFrameCount > 0) {
        fps = (stage->animFps > 0.0f) ? stage->animFps : 8.0f;
        frameIdx = (int)(shaderTime * fps) % stage->animFrameCount;
        if (frameIdx < 0) frameIdx = 0;
        if (stage->animTextures[frameIdx] == 0) {
            stage->animTextures[frameIdx] = RegisterTexture(stage->animFrames[frameIdx]);
        }
        return stage->animTextures[frameIdx];
    }
    if (entry->animFrameCount <= 0) return 0;
    fps = (entry->animFps > 0.0f) ? entry->animFps : 8.0f;
    frameIdx = (int)(shaderTime * fps) % entry->animFrameCount;
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
        /* Top-level deformVertexes wave: parsed at depth==1, stamped
         * onto every stage on shader close (same pattern as cullMode).
         * func=0 means the shader has no deform. */
        int deformWaveFunc;
        float deformWaveDiv;
        float deformWaveBase;
        float deformWaveAmp;
        float deformWavePhase;
        float deformWaveFreq;
        int deformMoveFunc;
        float deformMoveVector[3];
        float deformMoveBase;
        float deformMoveAmp;
        float deformMovePhase;
        float deformMoveFreq;
        /* deformVertexes autosprite/autoSprite2 (1/2). 0 = no autosprite. */
        int topAutospriteMode;
        char skyBoxBase[MAX_QPATH];
        qboolean gotSkyParms;
        qboolean gotPortal;
        qboolean gotFog;
        qboolean gotLightmapStage;
        qboolean gotFlare;
        qboolean gotSky;
        float fogColor[3];
        float fogDistance;
        Q3MetalStage cur;
        Q3MetalStage stages[Q3_MAX_STAGES];
        Q3cShaderGraph cleanGraph;
        Q3cShaderStage *cleanStage;
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
        deformWaveFunc = 0;
        deformWaveDiv = 1.0f;
        deformWaveBase = 0.0f;
        deformWaveAmp = 0.0f;
        deformWavePhase = 0.0f;
        deformWaveFreq = 0.0f;
        deformMoveFunc = 0;
        deformMoveVector[0] = deformMoveVector[1] = deformMoveVector[2] = 0.0f;
        deformMoveBase = 0.0f;
        deformMoveAmp = 0.0f;
        deformMovePhase = 0.0f;
        deformMoveFreq = 0.0f;
        topAutospriteMode = 0;
        skyBoxBase[0] = '\0';
        gotSkyParms = qfalse;
        gotPortal = qfalse;
        gotFog = qfalse;
        gotLightmapStage = qfalse;
        gotFlare = qfalse;
        gotSky = qfalse;
        fogColor[0] = fogColor[1] = fogColor[2] = 0.0f;
        fogDistance = 0.0f;
        Com_Memset(&cur, 0, sizeof(cur));
        cur.rawSrcBlend = Q3_GL_ONE;
        cur.rawDstBlend = Q3_GL_ZERO;
        cur.alphaConst = 1.0f;
        Com_Memset(stages, 0, sizeof(stages));
        Q3cShaderGraph_Clear(&cleanGraph);
        Q_strncpyz(cleanGraph.name, shaderName, sizeof(cleanGraph.name));
        cleanGraph.cullType = (uint32_t)cullMode;
        cleanStage = NULL;
        stagesCount = 0;

        while (depth > 0) {
            token = COM_ParseExt(&p, qtrue);
            if (!token[0]) break;

            if (token[0] == '{' && token[1] == '\0') {
                depth += 1;
                if (depth == 2) {
                    inStage = qtrue;
                    Com_Memset(&cur, 0, sizeof(cur));
                    cur.rawSrcBlend = Q3_GL_ONE;
                    cur.rawDstBlend = Q3_GL_ZERO;
                    /* alphaConst defaults to 1.0 so a stage that sets
                     * alphaGen const without a numeric argument stays
                     * opaque instead of going fully transparent. */
                    cur.alphaConst = 1.0f;
                    cleanStage = Q3cShaderGraph_AddStage(&cleanGraph);
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
                    if (stagesCount < Q3_MAX_STAGES &&
                        (cur.mapPath[0] != '\0' || cur.animFrameCount > 0 || cur.useLightmap)) {
                        ApplyCleanStageToMetalStage(cleanStage, &cur);
                        stages[stagesCount++] = cur;
                    }
                    cleanStage = NULL;
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
                     * nomarks, noimpact, fog, etc.) is ignored but we
                     * still consume the argument so the parser
                     * advances. NOTE: `surfaceparm fog` is NOT used
                     * here to mark a fog volume — q3dm6 and other
                     * pak0 shaders use it on regular floor brushes
                     * where `surfaceparm` is a content tag rather
                     * than a "this brush is a fog volume" signal.
                     * The reliable fog-volume marker is `fogparms`,
                     * which only true fog volumes declare. */
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
                    cleanGraph.cullType = (uint32_t)cullMode;
                } else if (!Q_stricmp(token, "deformVertexes") ||
                           !Q_stricmp(token, "deformvertexes")) {
                    /* Top-level shader directive — applies to all
                     * stages. We implement `wave`; other variants are
                     * parsed-and-discarded so the token stream stays in
                     * sync. Wave syntax:
                     *   deformVertexes wave <div> <func> <base> <amp> <phase> <freq>
                     * func is sin/triangle/square/sawtooth/inversesawtooth.
                     * COM_ParseExt aliases its static buffer; copy each
                     * token to a local before parsing the next. */
                    char modeBuf[MAX_TOKEN_CHARS];
                    Q_strncpyz(modeBuf, COM_ParseExt(&p, qfalse), sizeof(modeBuf));
                    if (!Q_stricmp(modeBuf, "wave")) {
                        char divBuf[MAX_TOKEN_CHARS], funcBuf[MAX_TOKEN_CHARS];
                        char baseBuf[MAX_TOKEN_CHARS], ampBuf[MAX_TOKEN_CHARS];
                        char phaseBuf[MAX_TOKEN_CHARS], freqBuf[MAX_TOKEN_CHARS];
                        Q_strncpyz(divBuf,   COM_ParseExt(&p, qfalse), sizeof(divBuf));
                        Q_strncpyz(funcBuf,  COM_ParseExt(&p, qfalse), sizeof(funcBuf));
                        Q_strncpyz(baseBuf,  COM_ParseExt(&p, qfalse), sizeof(baseBuf));
                        Q_strncpyz(ampBuf,   COM_ParseExt(&p, qfalse), sizeof(ampBuf));
                        Q_strncpyz(phaseBuf, COM_ParseExt(&p, qfalse), sizeof(phaseBuf));
                        Q_strncpyz(freqBuf,  COM_ParseExt(&p, qfalse), sizeof(freqBuf));
                        int fn = 1; /* default sin */
                        if (!Q_stricmp(funcBuf, "sin")) fn = 1;
                        else if (!Q_stricmp(funcBuf, "triangle")) fn = 2;
                        else if (!Q_stricmp(funcBuf, "square")) fn = 3;
                        else if (!Q_stricmp(funcBuf, "sawtooth")) fn = 4;
                        else if (!Q_stricmp(funcBuf, "inversesawtooth") ||
                                 !Q_stricmp(funcBuf, "inverseSawtooth")) fn = 5;
                        deformWaveFunc  = fn;
                        deformWaveDiv   = (float)atof(divBuf);
                        if (deformWaveDiv == 0.0f) deformWaveDiv = 1.0f;
                        deformWaveBase  = (float)atof(baseBuf);
                        deformWaveAmp   = (float)atof(ampBuf);
                        deformWavePhase = (float)atof(phaseBuf);
                        deformWaveFreq  = (float)atof(freqBuf);
                        {
                            float args[8] = {
                                deformWaveDiv, (float)fn, deformWaveBase, deformWaveAmp,
                                deformWavePhase, deformWaveFreq, 0.0f, 0.0f
                            };
                            Q3cShaderGraph_AddDeform(&cleanGraph, Q3C_DEFORM_WAVE, args, 8);
                        }
                    } else if (!Q_stricmp(modeBuf, "bulge")) {
                        /* `bulge <bulgewidth> <bulgeheight> <bulgespeed>` — 3 args. Skip. */
                        (void)COM_ParseExt(&p, qfalse);
                        (void)COM_ParseExt(&p, qfalse);
                        (void)COM_ParseExt(&p, qfalse);
                    } else if (!Q_stricmp(modeBuf, "move")) {
                        char xBuf[MAX_TOKEN_CHARS], yBuf[MAX_TOKEN_CHARS], zBuf[MAX_TOKEN_CHARS];
                        char funcBuf[MAX_TOKEN_CHARS], baseBuf[MAX_TOKEN_CHARS];
                        char ampBuf[MAX_TOKEN_CHARS], phaseBuf[MAX_TOKEN_CHARS], freqBuf[MAX_TOKEN_CHARS];
                        Q_strncpyz(xBuf,     COM_ParseExt(&p, qfalse), sizeof(xBuf));
                        Q_strncpyz(yBuf,     COM_ParseExt(&p, qfalse), sizeof(yBuf));
                        Q_strncpyz(zBuf,     COM_ParseExt(&p, qfalse), sizeof(zBuf));
                        Q_strncpyz(funcBuf,  COM_ParseExt(&p, qfalse), sizeof(funcBuf));
                        Q_strncpyz(baseBuf,  COM_ParseExt(&p, qfalse), sizeof(baseBuf));
                        Q_strncpyz(ampBuf,   COM_ParseExt(&p, qfalse), sizeof(ampBuf));
                        Q_strncpyz(phaseBuf, COM_ParseExt(&p, qfalse), sizeof(phaseBuf));
                        Q_strncpyz(freqBuf,  COM_ParseExt(&p, qfalse), sizeof(freqBuf));
                        if (xBuf[0] && yBuf[0] && zBuf[0] && funcBuf[0]) {
                            int fn = 1;
                            if (!Q_stricmp(funcBuf, "sin")) fn = 1;
                            else if (!Q_stricmp(funcBuf, "triangle")) fn = 2;
                            else if (!Q_stricmp(funcBuf, "square")) fn = 3;
                            else if (!Q_stricmp(funcBuf, "sawtooth")) fn = 4;
                            else if (!Q_stricmp(funcBuf, "inversesawtooth") ||
                                     !Q_stricmp(funcBuf, "inverseSawtooth")) fn = 5;
                            deformMoveFunc = fn;
                            deformMoveVector[0] = (float)atof(xBuf);
                            deformMoveVector[1] = (float)atof(yBuf);
                            deformMoveVector[2] = (float)atof(zBuf);
                            deformMoveBase = baseBuf[0] ? (float)atof(baseBuf) : 0.0f;
                            deformMoveAmp = ampBuf[0] ? (float)atof(ampBuf) : 0.0f;
                            deformMovePhase = phaseBuf[0] ? (float)atof(phaseBuf) : 0.0f;
                            deformMoveFreq = freqBuf[0] ? (float)atof(freqBuf) : 0.0f;
                            {
                                float args[8] = {
                                    deformMoveVector[0], deformMoveVector[1], deformMoveVector[2],
                                    (float)fn, deformMoveBase, deformMoveAmp,
                                    deformMovePhase, deformMoveFreq
                                };
                                Q3cShaderGraph_AddDeform(&cleanGraph, Q3C_DEFORM_MOVE, args, 8);
                            }
                        }
                    } else if (!Q_stricmp(modeBuf, "normal")) {
                        /* `normal <amplitude> <frequency>` — 2 args. Skip. */
                        (void)COM_ParseExt(&p, qfalse);
                        (void)COM_ParseExt(&p, qfalse);
                    } else if (!Q_stricmp(modeBuf, "autosprite")) {
                        /* 0 args. Tag the shader; transform deferred. */
                        topAutospriteMode = 1;
                        Q3cShaderGraph_AddDeform(&cleanGraph, Q3C_DEFORM_AUTOSPRITE, NULL, 0);
                    } else if (!Q_stricmp(modeBuf, "autoSprite2") ||
                               !Q_stricmp(modeBuf, "autosprite2")) {
                        /* 0 args. Tag the shader; transform deferred. */
                        topAutospriteMode = 2;
                        Q3cShaderGraph_AddDeform(&cleanGraph, Q3C_DEFORM_AUTOSPRITE2, NULL, 0);
                    }
                    /* `projectionShadow` / `text0..text7` take 0 args. */
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
                    const char *t = COM_ParseExt(&p, qfalse);
                    if (!Q_stricmp(t, "(")) {
                        t = COM_ParseExt(&p, qfalse); if (t[0]) fogColor[0] = (float)atof(t);
                        t = COM_ParseExt(&p, qfalse); if (t[0]) fogColor[1] = (float)atof(t);
                        t = COM_ParseExt(&p, qfalse); if (t[0]) fogColor[2] = (float)atof(t);
                        (void)COM_ParseExt(&p, qfalse);
                        t = COM_ParseExt(&p, qfalse); if (t[0]) fogDistance = (float)atof(t);
                    } else {
                        if (t[0]) fogColor[0] = (float)atof(t);
                        t = COM_ParseExt(&p, qfalse); if (t[0]) fogColor[1] = (float)atof(t);
                        t = COM_ParseExt(&p, qfalse); if (t[0]) fogColor[2] = (float)atof(t);
                        t = COM_ParseExt(&p, qfalse); if (t[0]) fogDistance = (float)atof(t);
                        (void)COM_ParseExt(&p, qfalse);
                    }
                    gotFog = qtrue;
                    cleanGraph.fogColor[0] = fogColor[0];
                    cleanGraph.fogColor[1] = fogColor[1];
                    cleanGraph.fogColor[2] = fogColor[2];
                    cleanGraph.fogDistance = fogDistance;
                }
                continue;
            }

            {
                if (!Q_stricmp(token, "map") || !Q_stricmp(token, "clampmap")) {
                    /* Q3 shader scripts distinguish `map` (repeat wrap) from
                     * `clampmap` (clamp-to-edge wrap). Reference ioquake3
                     * sets bundle->wrapClampMode = WRAP_CLAMP for clampmap
                     * and WRAP_REPEAT (default 0) for map. Threading this
                     * per-stage lets the Swift draw loop pick the right
                     * MTLSamplerState — dlight projection discs, HUD
                     * elements, and `clampmap` decorations get clamp;
                     * environment-mapped chrome shells (quad damage),
                     * tiled detail textures, and standard `map` stages
                     * get repeat. */
                    int isClampMap = !Q_stricmp(token, "clampmap");
                    if (cleanStage != NULL) {
                        cleanStage->wrapClampMode = (uint32_t)(isClampMap ? 1 : 0);
                    }
                    token = COM_ParseExt(&p, qfalse);
                    if (token[0]) {
                        if (!Q_stricmp(token, "$lightmap")) {
                            cur.useLightmap = 1;
                            if (cleanStage != NULL) {
                                cleanStage->isLightmap = 1;
                                cleanStage->tcGen = Q3C_TCGEN_LIGHTMAP;
                            }
                            gotLightmapStage = qtrue;
                        } else if (cur.mapPath[0] == '\0') {
                            Q_strncpyz(cur.mapPath, token, sizeof(cur.mapPath));
                            if (cleanStage != NULL) {
                                Q_strncpyz(cleanStage->image, token, sizeof(cleanStage->image));
                            }
                        }
                    }
                } else if (!Q_stricmp(token, "animMap") || !Q_stricmp(token, "animmap")) {
                    token = COM_ParseExt(&p, qfalse);
                    cur.animFps = (float)atof(token);
                    cur.animFrameCount = 0;
                    if (cleanStage != NULL) {
                        cleanStage->animFrequency = cur.animFps;
                        cleanStage->animFrameCount = 0;
                    }
                    while (1) {
                        token = COM_ParseExt(&p, qfalse);
                        if (!token[0]) break;
                        if (token[0] == '$') continue;
                        if (cur.animFrameCount >= METAL_ANIMMAP_MAX_FRAMES) continue;
                        Q_strncpyz(cur.animFrames[cur.animFrameCount], token, MAX_QPATH);
                        if (cleanStage != NULL &&
                            cleanStage->animFrameCount < Q3C_MAX_ANIM_FRAMES) {
                            Q_strncpyz(cleanStage->animFrames[cleanStage->animFrameCount],
                                       token,
                                       sizeof(cleanStage->animFrames[0]));
                            cleanStage->animFrameCount += 1;
                        }
                        cur.animFrameCount += 1;
                    }
                    if (cur.animFrameCount > 0) {
                        Q_strncpyz(cur.mapPath, cur.animFrames[0], sizeof(cur.mapPath));
                        if (cleanStage != NULL) {
                            Q_strncpyz(cleanStage->image,
                                       cleanStage->animFrames[0],
                                       sizeof(cleanStage->image));
                        }
                        gotAnim = qtrue;
                        if (animFrameCount == 0) {
                            int af;
                            animFps = cur.animFps;
                            animFrameCount = cur.animFrameCount;
                            for (af = 0; af < animFrameCount; ++af) {
                                Q_strncpyz(animFrames[af], cur.animFrames[af], MAX_QPATH);
                            }
                        }
                    }
                } else if (!Q_stricmp(token, "tcGen") || !Q_stricmp(token, "tcgen")) {
                    /* Per-stage tcGen. Only the stage that declares the
                     * directive gets the flag; sibling stages stay at base.
                     * Modes: 0=base (default), 1=environment, 2=vector.
                     * Vector takes two parenthesized vec3 arguments and
                     * computes UV per-fragment as dot(worldPos, vec[0..1]).
                     * Matches ioq3 ParseStage / RB_CalcTexCoords TCGEN_VECTOR. */
                    char modeBuf[MAX_TOKEN_CHARS];
                    Q_strncpyz(modeBuf, COM_ParseExt(&p, qfalse), sizeof(modeBuf));
                    if (modeBuf[0] && (!Q_stricmp(modeBuf, "environment") ||
                                       !Q_stricmp(modeBuf, "env"))) {
                        cur.tcGen = 1;
                        if (cleanStage != NULL) {
                            cleanStage->tcGen = Q3C_TCGEN_ENVIRONMENT_MAPPED;
                        }
                        tcGenEnv = qtrue;
                    } else if (modeBuf[0] && !Q_stricmp(modeBuf, "vector")) {
                        /* Syntax: tcGen vector ( x y z ) ( x y z )
                         * 10 tokens after 'vector': '(' x y z ')' '(' x y z ')'.
                         * Copy each numeric token before parsing the next
                         * because COM_ParseExt aliases its static buffer.
                         * Validate paren tokens; if a paren is missing the
                         * shader is malformed — bail without committing the
                         * mode so we don't desync the parser stream. */
                        float vecs[2][3] = {{0}};
                        qboolean ok = qtrue;
                        for (int vec = 0; ok && vec < 2; ++vec) {
                            char openBuf[MAX_TOKEN_CHARS];
                            Q_strncpyz(openBuf, COM_ParseExt(&p, qfalse), sizeof(openBuf));
                            if (openBuf[0] != '(') { ok = qfalse; break; }
                            for (int comp = 0; ok && comp < 3; ++comp) {
                                char numBuf[MAX_TOKEN_CHARS];
                                Q_strncpyz(numBuf, COM_ParseExt(&p, qfalse), sizeof(numBuf));
                                if (!numBuf[0] || numBuf[0] == '(' || numBuf[0] == ')') {
                                    ok = qfalse; break;
                                }
                                vecs[vec][comp] = (float)atof(numBuf);
                            }
                            if (!ok) break;
                            char closeBuf[MAX_TOKEN_CHARS];
                            Q_strncpyz(closeBuf, COM_ParseExt(&p, qfalse), sizeof(closeBuf));
                            if (closeBuf[0] != ')') { ok = qfalse; break; }
                        }
                        if (ok) {
                            cur.tcGenVec0[0] = vecs[0][0];
                            cur.tcGenVec0[1] = vecs[0][1];
                            cur.tcGenVec0[2] = vecs[0][2];
                            cur.tcGenVec0[3] = 0.0f;
                            cur.tcGenVec1[0] = vecs[1][0];
                            cur.tcGenVec1[1] = vecs[1][1];
                            cur.tcGenVec1[2] = vecs[1][2];
                            cur.tcGenVec1[3] = 0.0f;
                            cur.tcGen = 2;
                            if (cleanStage != NULL) {
                                cleanStage->tcGen = Q3C_TCGEN_VECTOR;
                                cleanStage->tcGenVectors[0][0] = vecs[0][0];
                                cleanStage->tcGenVectors[0][1] = vecs[0][1];
                                cleanStage->tcGenVectors[0][2] = vecs[0][2];
                                cleanStage->tcGenVectors[1][0] = vecs[1][0];
                                cleanStage->tcGenVectors[1][1] = vecs[1][1];
                                cleanStage->tcGenVectors[1][2] = vecs[1][2];
                            }
                            /* One-shot per-shader audit so we know which
                             * surfaces actually exercise the vector path
                             * in a capture run. Bounded to 16 unique
                             * shader names. */
                            static char s_tcGenVecSeen[16][MAX_QPATH];
                            static int s_tcGenVecCount = 0;
                            int dup = 0;
                            for (int j = 0; j < s_tcGenVecCount; ++j) {
                                if (!Q_stricmp(s_tcGenVecSeen[j], shaderName)) { dup = 1; break; }
                            }
                            if (!dup && s_tcGenVecCount < 16) {
                                Q_strncpyz(s_tcGenVecSeen[s_tcGenVecCount++],
                                           shaderName, sizeof(s_tcGenVecSeen[0]));
                                ri.Printf(PRINT_ALL,
                                    "[tcgen-vec] '%s' v0=(%g %g %g) v1=(%g %g %g)\n",
                                    shaderName,
                                    vecs[0][0], vecs[0][1], vecs[0][2],
                                    vecs[1][0], vecs[1][1], vecs[1][2]);
                            }
                        } else {
                            ri.Printf(PRINT_WARNING,
                                "Metal shader: malformed tcGen vector in '%s' — skipping\n",
                                shaderName);
                        }
                    }
                } else if (!Q_stricmp(token, "blendFunc") || !Q_stricmp(token, "blendfunc")) {
                    /* COM_ParseExt returns a pointer into a shared static
                     * buffer that the next call overwrites. Capture src
                     * into a local BEFORE parsing dst — otherwise src and
                     * dst end up pointing at the same (dst) token and
                     * BlendModeFromTokens sees (dst,dst). That silently
                     * mis-routed GL_ZERO/GL_ONE_MINUS_SRC_COLOR decals
                     * (bullet_mrk, markShadow, burn_med_mrk, hole_lg_mrk)
                     * to filter instead of subtract. */
                    char srcCopy[MAX_TOKEN_CHARS];
                    const char *srcTok = COM_ParseExt(&p, qfalse);
                    Q_strncpyz(srcCopy, srcTok, sizeof(srcCopy));
                    const char *dst = COM_ParseExt(&p, qfalse);
                    if (srcCopy[0]) {
                        cur.blendMode = BlendModeFromTokens(srcCopy, dst);
                        cur.rawSrcBlend = GLBlendFactorFromToken(srcCopy);
                        cur.rawDstBlend = GLBlendDstFromTokens(srcCopy, dst);
                        cur.depthWrite = 0;
                        if (cleanStage != NULL) {
                            cleanStage->srcBlend = cur.rawSrcBlend;
                            cleanStage->dstBlend = cur.rawDstBlend;
                            cleanStage->depthWrite = 0;
                        }
                    }
                } else if (!Q_stricmp(token, "alphaFunc") || !Q_stricmp(token, "alphafunc")) {
                    token = COM_ParseExt(&p, qfalse);
                    if (!Q_stricmp(token, "GT0")) cur.alphaFunc = 1;
                    else if (!Q_stricmp(token, "GE128")) cur.alphaFunc = 2;
                    else if (!Q_stricmp(token, "LT128")) cur.alphaFunc = 3;
                    if (cleanStage != NULL) {
                        cleanStage->alphaFunc = (uint32_t)cur.alphaFunc;
                    }
                } else if (!Q_stricmp(token, "depthWrite") || !Q_stricmp(token, "depthwrite")) {
                    /* Explicit Q3 keyword that overrides the default
                     * depth-mask-off behavior for blended stages. ioq3
                     * tr_shader.c sets GLS_DEPTHMASK_TRUE here; Quake3e
                     * propagates as `depthWriteEnable = (state_bits &
                     * GLS_DEPTHMASK_TRUE) != 0`. Our renderer uses this
                     * flag to pick a depth-write-ON depth-stencil state
                     * even on filter/alpha/additive passes. No arg. */
                    cur.depthWrite = 1;
                    if (cleanStage != NULL) {
                        cleanStage->depthWrite = 1;
                    }
                } else if (!Q_stricmp(token, "rgbGen") || !Q_stricmp(token, "rgbgen")) {
                    token = COM_ParseExt(&p, qfalse);
                    if (!Q_stricmp(token, "vertex")) cur.rgbGen = 1;
                    else if (!Q_stricmp(token, "exactVertex") ||
                             !Q_stricmp(token, "exactvertex")) cur.rgbGen = 1;
                    else if (!Q_stricmp(token, "lightingDiffuse") ||
                             !Q_stricmp(token, "lightingdiffuse")) cur.rgbGen = 2;
                    else if (!Q_stricmp(token, "wave")) cur.rgbGen = 3;
                    /* entity: refEntity_t.shaderRGBA → fragment multiplies
                     * texel.rgb by uniforms.entityColor.rgb (un-Lambert'd
                     * — distinct from the per-vertex color path which has
                     * Lambert diffuse already baked in). */
                    else if (!Q_stricmp(token, "entity")) cur.rgbGen = 5;
                    /* oneMinusEntity: 1.0 - entity rgba. Used by some
                     * fade-in / inverse-tint stages (e.g. teleport flicker). */
                    else if (!Q_stricmp(token, "oneMinusEntity") ||
                             !Q_stricmp(token, "oneminusentity")) cur.rgbGen = 6;
                    else cur.rgbGen = 0;
                    if (!Q_stricmp(token, "wave")) {
                        /* Copy tokens to locals — COM_ParseExt returns a
                         * pointer into a shared static buffer. */
                        char funcBuf[MAX_TOKEN_CHARS], baseBuf[MAX_TOKEN_CHARS];
                        char ampBuf[MAX_TOKEN_CHARS], phaseBuf[MAX_TOKEN_CHARS];
                        char freqBuf[MAX_TOKEN_CHARS];
                        Q_strncpyz(funcBuf, COM_ParseExt(&p, qfalse), sizeof(funcBuf));
                        Q_strncpyz(baseBuf, COM_ParseExt(&p, qfalse), sizeof(baseBuf));
                        Q_strncpyz(ampBuf, COM_ParseExt(&p, qfalse), sizeof(ampBuf));
                        Q_strncpyz(phaseBuf, COM_ParseExt(&p, qfalse), sizeof(phaseBuf));
                        Q_strncpyz(freqBuf, COM_ParseExt(&p, qfalse), sizeof(freqBuf));
                        if (funcBuf[0]) {
                            if (!Q_stricmp(funcBuf, "sin")) cur.rgbWaveFunc = 1;
                            else if (!Q_stricmp(funcBuf, "triangle")) cur.rgbWaveFunc = 2;
                            else if (!Q_stricmp(funcBuf, "square")) cur.rgbWaveFunc = 3;
                            else if (!Q_stricmp(funcBuf, "sawtooth")) cur.rgbWaveFunc = 4;
                            else if (!Q_stricmp(funcBuf, "inversesawtooth") ||
                                     !Q_stricmp(funcBuf, "inverseSawtooth")) cur.rgbWaveFunc = 5;
                            else if (!Q_stricmp(funcBuf, "noise")) cur.rgbWaveFunc = 6;
                            else cur.rgbWaveFunc = 1;
                        }
                        if (baseBuf[0]) cur.rgbWaveBase = (float)atof(baseBuf);
                        if (ampBuf[0]) cur.rgbWaveAmp = (float)atof(ampBuf);
                        if (phaseBuf[0]) cur.rgbWavePhase = (float)atof(phaseBuf);
                        if (freqBuf[0]) cur.rgbWaveFreq = (float)atof(freqBuf);
                        if (cleanStage != NULL) {
                            cleanStage->rgbGen = (uint32_t)cur.rgbGen;
                            cleanStage->rgbWave[0] = cur.rgbWaveBase;
                            cleanStage->rgbWave[1] = cur.rgbWaveAmp;
                            cleanStage->rgbWave[2] = cur.rgbWavePhase;
                            cleanStage->rgbWave[3] = cur.rgbWaveFreq;
                        }
                    } else if (!Q_stricmp(token, "const")) {
                        /* rgbGen const ( r g b ). Copy r/g/b to locals so
                         * the tokens survive subsequent COM_ParseExt calls. */
                        char rBuf[MAX_TOKEN_CHARS], gBuf[MAX_TOKEN_CHARS], bBuf[MAX_TOKEN_CHARS];
                        (void)COM_ParseExt(&p, qfalse); /* opening paren */
                        Q_strncpyz(rBuf, COM_ParseExt(&p, qfalse), sizeof(rBuf));
                        Q_strncpyz(gBuf, COM_ParseExt(&p, qfalse), sizeof(gBuf));
                        Q_strncpyz(bBuf, COM_ParseExt(&p, qfalse), sizeof(bBuf));
                        (void)COM_ParseExt(&p, qfalse); /* closing paren */
                        cur.rgbGen = 4;
                        cur.rgbConstColor[0] = rBuf[0] ? (float)atof(rBuf) : 1.0f;
                        cur.rgbConstColor[1] = gBuf[0] ? (float)atof(gBuf) : 1.0f;
                        cur.rgbConstColor[2] = bBuf[0] ? (float)atof(bBuf) : 1.0f;
                    }
                    if (cleanStage != NULL) {
                        cleanStage->rgbGen = (uint32_t)cur.rgbGen;
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
                    /* entity: use refEntity_t.shaderRGBA[3] directly — drives
                     * fade animations on gibs, rocket explosions, plasma
                     * trails (cgame ramps the alpha down each frame). */
                    else if (!Q_stricmp(token, "entity")) cur.alphaGen = 5;
                    else if (!Q_stricmp(token, "oneMinusEntity") ||
                             !Q_stricmp(token, "oneminusentity")) cur.alphaGen = 6;
                    else cur.alphaGen = 0;
                    if (!Q_stricmp(token, "wave")) {
                        /* See rgbGen wave: COM_ParseExt aliases into a
                         * shared static buffer; copy to locals. */
                        char funcBuf[MAX_TOKEN_CHARS], baseBuf[MAX_TOKEN_CHARS];
                        char ampBuf[MAX_TOKEN_CHARS], phaseBuf[MAX_TOKEN_CHARS];
                        char freqBuf[MAX_TOKEN_CHARS];
                        Q_strncpyz(funcBuf, COM_ParseExt(&p, qfalse), sizeof(funcBuf));
                        Q_strncpyz(baseBuf, COM_ParseExt(&p, qfalse), sizeof(baseBuf));
                        Q_strncpyz(ampBuf, COM_ParseExt(&p, qfalse), sizeof(ampBuf));
                        Q_strncpyz(phaseBuf, COM_ParseExt(&p, qfalse), sizeof(phaseBuf));
                        Q_strncpyz(freqBuf, COM_ParseExt(&p, qfalse), sizeof(freqBuf));
                        if (funcBuf[0]) {
                            if (!Q_stricmp(funcBuf, "sin")) cur.alphaWaveFunc = 1;
                            else if (!Q_stricmp(funcBuf, "triangle")) cur.alphaWaveFunc = 2;
                            else if (!Q_stricmp(funcBuf, "square")) cur.alphaWaveFunc = 3;
                            else if (!Q_stricmp(funcBuf, "sawtooth")) cur.alphaWaveFunc = 4;
                            else if (!Q_stricmp(funcBuf, "inversesawtooth") ||
                                     !Q_stricmp(funcBuf, "inverseSawtooth")) cur.alphaWaveFunc = 5;
                            else if (!Q_stricmp(funcBuf, "noise")) cur.alphaWaveFunc = 6;
                            else cur.alphaWaveFunc = 1;
                        }
                        if (baseBuf[0]) cur.alphaWaveBase = (float)atof(baseBuf);
                        if (ampBuf[0]) cur.alphaWaveAmp = (float)atof(ampBuf);
                        if (phaseBuf[0]) cur.alphaWavePhase = (float)atof(phaseBuf);
                        if (freqBuf[0]) cur.alphaWaveFreq = (float)atof(freqBuf);
                        if (cleanStage != NULL) {
                            cleanStage->alphaGen = (uint32_t)cur.alphaGen;
                            cleanStage->alphaWave[0] = cur.alphaWaveBase;
                            cleanStage->alphaWave[1] = cur.alphaWaveAmp;
                            cleanStage->alphaWave[2] = cur.alphaWavePhase;
                            cleanStage->alphaWave[3] = cur.alphaWaveFreq;
                        }
                    } else if (!Q_stricmp(token, "const")) {
                        /* alphaGen const <value>: fixed alpha channel. */
                        const char *vTok = COM_ParseExt(&p, qfalse);
                        cur.alphaConst = (vTok && vTok[0]) ? (float)atof(vTok) : 1.0f;
                    } else if (!Q_stricmp(token, "portal")) {
                        (void)COM_ParseExt(&p, qfalse);
                    }
                    if (cleanStage != NULL) {
                        cleanStage->alphaGen = (uint32_t)cur.alphaGen;
                    }
                } else if (!Q_stricmp(token, "tcMod") || !Q_stricmp(token, "tcmod")) {
                    token = COM_ParseExt(&p, qfalse);
                    if (token[0] && !Q_stricmp(token, "scroll")) {
                        /* Copy tokens — COM_ParseExt aliases its static buffer. */
                        char sBuf[MAX_TOKEN_CHARS], tBuf[MAX_TOKEN_CHARS];
                        Q_strncpyz(sBuf, COM_ParseExt(&p, qfalse), sizeof(sBuf));
                        Q_strncpyz(tBuf, COM_ParseExt(&p, qfalse), sizeof(tBuf));
                        if (sBuf[0] && tBuf[0] && cur.tcModCount < Q3_MAX_TCMODS) {
                            cur.tcMods[cur.tcModCount].type = 1;
                            cur.tcMods[cur.tcModCount].params[0] = (float)atof(sBuf);
                            cur.tcMods[cur.tcModCount].params[1] = (float)atof(tBuf);
                            cur.tcMods[cur.tcModCount].params[2] = 0.0f;
                            cur.tcMods[cur.tcModCount].params[3] = 0.0f;
                            if (cleanStage != NULL) {
                                float args[2] = {
                                    cur.tcMods[cur.tcModCount].params[0],
                                    cur.tcMods[cur.tcModCount].params[1]
                                };
                                Q3cShaderStage_AddTcMod(cleanStage, Q3C_TCMOD_SCROLL, args, 2);
                            }
                            cur.tcModCount += 1;
                        }
                    } else if (token[0] && !Q_stricmp(token, "scale")) {
                        char sBuf[MAX_TOKEN_CHARS], tBuf[MAX_TOKEN_CHARS];
                        Q_strncpyz(sBuf, COM_ParseExt(&p, qfalse), sizeof(sBuf));
                        Q_strncpyz(tBuf, COM_ParseExt(&p, qfalse), sizeof(tBuf));
                        if (sBuf[0] && tBuf[0] && cur.tcModCount < Q3_MAX_TCMODS) {
                            cur.tcMods[cur.tcModCount].type = 4;
                            cur.tcMods[cur.tcModCount].params[0] = (float)atof(sBuf);
                            cur.tcMods[cur.tcModCount].params[1] = (float)atof(tBuf);
                            cur.tcMods[cur.tcModCount].params[2] = 0.0f;
                            cur.tcMods[cur.tcModCount].params[3] = 0.0f;
                            if (cleanStage != NULL) {
                                float args[2] = {
                                    cur.tcMods[cur.tcModCount].params[0],
                                    cur.tcMods[cur.tcModCount].params[1]
                                };
                                Q3cShaderStage_AddTcMod(cleanStage, Q3C_TCMOD_SCALE, args, 2);
                            }
                            cur.tcModCount += 1;
                        }
                    } else if (token[0] && !Q_stricmp(token, "turb")) {
                        char baseBuf[MAX_TOKEN_CHARS], ampBuf[MAX_TOKEN_CHARS];
                        char phaseBuf[MAX_TOKEN_CHARS], freqBuf[MAX_TOKEN_CHARS];
                        Q_strncpyz(baseBuf, COM_ParseExt(&p, qfalse), sizeof(baseBuf));
                        Q_strncpyz(ampBuf, COM_ParseExt(&p, qfalse), sizeof(ampBuf));
                        Q_strncpyz(phaseBuf, COM_ParseExt(&p, qfalse), sizeof(phaseBuf));
                        Q_strncpyz(freqBuf, COM_ParseExt(&p, qfalse), sizeof(freqBuf));
                        (void)baseBuf;
                        if (ampBuf[0] && phaseBuf[0] && freqBuf[0] && cur.tcModCount < Q3_MAX_TCMODS) {
                            cur.tcMods[cur.tcModCount].type = 5;
                            cur.tcMods[cur.tcModCount].params[0] = (float)atof(ampBuf);
                            cur.tcMods[cur.tcModCount].params[1] = (float)atof(freqBuf);
                            cur.tcMods[cur.tcModCount].params[2] = (float)atof(phaseBuf);
                            cur.tcMods[cur.tcModCount].params[3] = 0.0f;
                            if (cleanStage != NULL) {
                                float args[4] = {
                                    (float)atof(baseBuf),
                                    cur.tcMods[cur.tcModCount].params[0],
                                    cur.tcMods[cur.tcModCount].params[2],
                                    cur.tcMods[cur.tcModCount].params[1]
                                };
                                Q3cShaderStage_AddTcMod(cleanStage, Q3C_TCMOD_TURB, args, 4);
                            }
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
                            if (cleanStage != NULL) {
                                float args[1] = { cur.tcMods[cur.tcModCount].params[0] };
                                Q3cShaderStage_AddTcMod(cleanStage, Q3C_TCMOD_ROTATE, args, 1);
                            }
                            cur.tcModCount += 1;
                        }
                    } else if (token[0] && !Q_stricmp(token, "stretch")) {
                        /* Syntax: tcmod stretch <func> <base> <amp> <phase> <freq>
                         * Scope is GF_SIN only (the overwhelming common case —
                         * stretch is used for pulse-zoom on powerups). Type=6
                         * is our encoding; params = (base, amp, phase, freq).
                         * Mirrors RB_CalcStretchTexCoords + RB_CalcTransformTexCoords. */
                        char funcBuf[MAX_TOKEN_CHARS], baseBuf[MAX_TOKEN_CHARS];
                        char ampBuf[MAX_TOKEN_CHARS], phaseBuf[MAX_TOKEN_CHARS];
                        char freqBuf[MAX_TOKEN_CHARS];
                        Q_strncpyz(funcBuf, COM_ParseExt(&p, qfalse), sizeof(funcBuf));
                        Q_strncpyz(baseBuf, COM_ParseExt(&p, qfalse), sizeof(baseBuf));
                        Q_strncpyz(ampBuf, COM_ParseExt(&p, qfalse), sizeof(ampBuf));
                        Q_strncpyz(phaseBuf, COM_ParseExt(&p, qfalse), sizeof(phaseBuf));
                        Q_strncpyz(freqBuf, COM_ParseExt(&p, qfalse), sizeof(freqBuf));
                        /* GF_SIN only — func token consumed but not encoded. */
                        if (funcBuf[0] && baseBuf[0] && ampBuf[0] &&
                            phaseBuf[0] && freqBuf[0] &&
                            cur.tcModCount < Q3_MAX_TCMODS) {
                            cur.tcMods[cur.tcModCount].type = 6;
                            cur.tcMods[cur.tcModCount].params[0] = (float)atof(baseBuf);
                            cur.tcMods[cur.tcModCount].params[1] = (float)atof(ampBuf);
                            cur.tcMods[cur.tcModCount].params[2] = (float)atof(phaseBuf);
                            cur.tcMods[cur.tcModCount].params[3] = (float)atof(freqBuf);
                            if (cleanStage != NULL) {
                                float args[5] = {
                                    0.0f,
                                    cur.tcMods[cur.tcModCount].params[0],
                                    cur.tcMods[cur.tcModCount].params[1],
                                    cur.tcMods[cur.tcModCount].params[2],
                                    cur.tcMods[cur.tcModCount].params[3]
                                };
                                Q3cShaderStage_AddTcMod(cleanStage, Q3C_TCMOD_STRETCH, args, 5);
                            }
                            cur.tcModCount += 1;
                        }
                    } else if (token[0] && !Q_stricmp(token, "transform")) {
                        char m00[MAX_TOKEN_CHARS], m01[MAX_TOKEN_CHARS];
                        char m10[MAX_TOKEN_CHARS], m11[MAX_TOKEN_CHARS];
                        char t0[MAX_TOKEN_CHARS], t1[MAX_TOKEN_CHARS];
                        Q_strncpyz(m00, COM_ParseExt(&p, qfalse), sizeof(m00));
                        Q_strncpyz(m01, COM_ParseExt(&p, qfalse), sizeof(m01));
                        Q_strncpyz(m10, COM_ParseExt(&p, qfalse), sizeof(m10));
                        Q_strncpyz(m11, COM_ParseExt(&p, qfalse), sizeof(m11));
                        Q_strncpyz(t0, COM_ParseExt(&p, qfalse), sizeof(t0));
                        Q_strncpyz(t1, COM_ParseExt(&p, qfalse), sizeof(t1));
                        if (m00[0] && m01[0] && m10[0] && m11[0] &&
                            cur.tcModCount < Q3_MAX_TCMODS) {
                            cur.tcMods[cur.tcModCount].type = 7;
                            cur.tcMods[cur.tcModCount].params[0] = (float)atof(m00);
                            cur.tcMods[cur.tcModCount].params[1] = (float)atof(m01);
                            cur.tcMods[cur.tcModCount].params[2] = (float)atof(m10);
                            cur.tcMods[cur.tcModCount].params[3] = (float)atof(m11);
                            if (cleanStage != NULL) {
                                float args[6] = {
                                    cur.tcMods[cur.tcModCount].params[0],
                                    cur.tcMods[cur.tcModCount].params[1],
                                    cur.tcMods[cur.tcModCount].params[2],
                                    cur.tcMods[cur.tcModCount].params[3],
                                    t0[0] ? (float)atof(t0) : 0.0f,
                                    t1[0] ? (float)atof(t1) : 0.0f
                                };
                                Q3cShaderStage_AddTcMod(cleanStage, Q3C_TCMOD_TRANSFORM, args, 6);
                            }
                            cur.tcModCount += 1;
                        }
                        if (t0[0] && t1[0] && cur.tcModCount < Q3_MAX_TCMODS) {
                            cur.tcMods[cur.tcModCount].type = 8;
                            cur.tcMods[cur.tcModCount].params[0] = (float)atof(t0);
                            cur.tcMods[cur.tcModCount].params[1] = (float)atof(t1);
                            cur.tcMods[cur.tcModCount].params[2] = 0.0f;
                            cur.tcMods[cur.tcModCount].params[3] = 0.0f;
                            cur.tcModCount += 1;
                        }
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
                 * everything Swift needs to choose a cull state. Same
                 * for the top-level deformVertexes wave parameters —
                 * deform is shader-wide in Q3 but our pipeline reads
                 * per-stage. */
                for (s = 0; s < last->stageCount; ++s) {
                    last->stages[s].cullMode = cullMode;
                    last->stages[s].deformWaveFunc  = deformWaveFunc;
                    last->stages[s].deformWaveDiv   = deformWaveDiv;
                    last->stages[s].deformWaveBase  = deformWaveBase;
                    last->stages[s].deformWaveAmp   = deformWaveAmp;
                    last->stages[s].deformWavePhase = deformWavePhase;
                    last->stages[s].deformWaveFreq  = deformWaveFreq;
                    last->stages[s].deformMoveFunc  = deformMoveFunc;
                    last->stages[s].deformMoveVector[0] = deformMoveVector[0];
                    last->stages[s].deformMoveVector[1] = deformMoveVector[1];
                    last->stages[s].deformMoveVector[2] = deformMoveVector[2];
                    last->stages[s].deformMoveBase  = deformMoveBase;
                    last->stages[s].deformMoveAmp   = deformMoveAmp;
                    last->stages[s].deformMovePhase = deformMovePhase;
                    last->stages[s].deformMoveFreq  = deformMoveFreq;
                    last->stages[s].autospriteMode  = topAutospriteMode;
                }
                last->isPortal = gotPortal;
                last->hasFog = gotFog;
                last->hasLightmapStage = gotLightmapStage;
                last->hasFlare = gotFlare;
                last->isSky = gotSky;
                /* === [METAL-SHADER] PC-port comparison instrumentation ====
                 * Mirrors the [QE-SHADER] dump baked into Quake3e's
                 * renderer/tr_shader.c FinishShader (see Q2_too_ios
                 * project notes 2026-06-02). Filtered to powerup-shell
                 * family so we can diff our parsed state against PC
                 * reference line-by-line.
                 *
                 * Output goes BOTH to ri.Printf (→ NSLog → Console.app)
                 * AND to a fixed sandbox file the user can pull via
                 *   xcrun devicectl device copy from ... Documents/baseq3/metalshader.log
                 * because iOS 18+ broke idevicesyslog (Apple restricted
                 * the syslog stream path libimobiledevice uses). The
                 * file is reopened in append mode each shader so
                 * partial captures survive a crash. */
                {
                    const char *qname = last->shaderName;
                    int isShell = (qname && qname[0] &&
                                   (Q_stristr(qname, "powerup") ||
                                    Q_stristr(qname, "quad")    ||
                                    Q_stristr(qname, "regen")   ||
                                    Q_stristr(qname, "battle")  ||
                                    Q_stristr(qname, "invuln")  ||
                                    Q_stristr(qname, "haste"))) ? 1 : 0;
                    if (isShell) {
                        /* File mirror via plain stdio + $HOME-resolved
                         * sandbox path. The iOS app sandbox sets HOME to
                         * the app's container, so this writes to
                         *   <container>/Documents/baseq3/metalshader.log
                         * which is exactly the path we pull via
                         *   xcrun devicectl device copy from ... \
                         *     --source Documents/baseq3/metalshader.log
                         * Append mode means a single demo session can
                         * accumulate dumps across multiple shader registrations
                         * (powerups + battle + regen + ...). FS_WriteFile
                         * from refimport_t is all-or-nothing so this
                         * direct stdio path is simpler. */
                        static FILE *s_metalShaderLogFP = NULL;
                        if (s_metalShaderLogFP == NULL) {
                            const char *home = getenv("HOME");
                            if (home != NULL && home[0]) {
                                char path[1024];
                                Com_sprintf(path, sizeof(path),
                                            "%s/Documents/baseq3/metalshader.log", home);
                                s_metalShaderLogFP = fopen(path, "a");
                            }
                        }
                        if (s_metalShaderLogFP != NULL) {
                            int sl, tm;
                            fprintf(s_metalShaderLogFP,
                                "[METAL-SHADER] name='%s' stages=%d deformWaveFunc=%d\n",
                                qname, last->stageCount, deformWaveFunc);
                            if (deformWaveFunc != 0) {
                                float spread = (deformWaveDiv != 0.0f) ? (1.0f / deformWaveDiv) : 0.0f;
                                fprintf(s_metalShaderLogFP,
                                    "[METAL-SHADER]   deform={WAVE base=%.3f amp=%.3f phase=%.3f freq=%.3f spread=%.3f fn=%d}\n",
                                    deformWaveBase, deformWaveAmp, deformWavePhase,
                                    deformWaveFreq, spread, deformWaveFunc);
                            }
                            for (sl = 0; sl < last->stageCount; ++sl) {
                                const Q3MetalStage *st = &last->stages[sl];
                                const char *tcGenName = "?";
                                switch (st->tcGen) {
                                    case 0: tcGenName = "TEXTURE"; break;
                                    case 1: tcGenName = "ENVIRONMENT"; break;
                                    case 2: tcGenName = "VECTOR"; break;
                                }
                                fprintf(s_metalShaderLogFP,
                                    "[METAL-SHADER]   stage[%d] blendMode=%d srcBlend=0x%x dstBlend=0x%x tcGen=%s tcMods=%d rgbGen=%d alphaGen=%d\n",
                                    sl, st->blendMode, st->rawSrcBlend, st->rawDstBlend,
                                    tcGenName, st->tcModCount,
                                    st->rgbGen, st->alphaGen);
                                for (tm = 0; tm < st->tcModCount && tm < Q3_MAX_TCMODS; ++tm) {
                                    const Q3TcMod *m = &st->tcMods[tm];
                                    const char *tmName = "?";
                                    switch (m->type) {
                                        case 1: tmName = "SCROLL"; break;
                                        case 2: tmName = "SCALE"; break;
                                        case 3: tmName = "ROTATE"; break;
                                        case 4: tmName = "STRETCH"; break;
                                        case 5: tmName = "TURB"; break;
                                        case 6: tmName = "ENTITY_TRANSLATE"; break;
                                        case 7: tmName = "TRANSFORM"; break;
                                    }
                                    fprintf(s_metalShaderLogFP,
                                        "[METAL-SHADER]     tcMod[%d]={%s p=(%.3f,%.3f,%.3f,%.3f)}\n",
                                        tm, tmName, m->params[0], m->params[1],
                                        m->params[2], m->params[3]);
                                }
                            }
                            fflush(s_metalShaderLogFP);
                        }

                        int sl;
                        ri.Printf(PRINT_ALL,
                                  "[METAL-SHADER] name='%s' stages=%d deformWaveFunc=%d\n",
                                  qname, last->stageCount, deformWaveFunc);
                        if (deformWaveFunc != 0) {
                            float spread = (deformWaveDiv != 0.0f) ? (1.0f / deformWaveDiv) : 0.0f;
                            ri.Printf(PRINT_ALL,
                                      "[METAL-SHADER]   deform={WAVE base=%.3f amp=%.3f phase=%.3f freq=%.3f spread=%.3f fn=%d}\n",
                                      deformWaveBase, deformWaveAmp, deformWavePhase,
                                      deformWaveFreq, spread, deformWaveFunc);
                        }
                        for (sl = 0; sl < last->stageCount; ++sl) {
                            const Q3MetalStage *st = &last->stages[sl];
                            int tm;
                            const char *tcGenName = "?";
                            switch (st->tcGen) {
                                case 0: tcGenName = "TEXTURE"; break;
                                case 1: tcGenName = "ENVIRONMENT"; break;
                                case 2: tcGenName = "VECTOR"; break;
                            }
                            ri.Printf(PRINT_ALL,
                                      "[METAL-SHADER]   stage[%d] blendMode=%d srcBlend=0x%x dstBlend=0x%x tcGen=%s tcMods=%d rgbGen=%d alphaGen=%d\n",
                                      sl, st->blendMode, st->rawSrcBlend, st->rawDstBlend,
                                      tcGenName, st->tcModCount,
                                      st->rgbGen, st->alphaGen);
                            for (tm = 0; tm < st->tcModCount && tm < Q3_MAX_TCMODS; ++tm) {
                                const Q3TcMod *m = &st->tcMods[tm];
                                const char *tmName = "?";
                                switch (m->type) {
                                    case 1: tmName = "SCROLL"; break;
                                    case 2: tmName = "SCALE"; break;
                                    case 3: tmName = "ROTATE"; break;
                                    case 4: tmName = "STRETCH"; break;
                                    case 5: tmName = "TURB"; break;
                                    case 6: tmName = "ENTITY_TRANSLATE"; break;
                                    case 7: tmName = "TRANSFORM"; break;
                                }
                                ri.Printf(PRINT_ALL,
                                          "[METAL-SHADER]     tcMod[%d]={%s p=(%.3f,%.3f,%.3f,%.3f)}\n",
                                          tm, tmName,
                                          m->params[0], m->params[1],
                                          m->params[2], m->params[3]);
                            }
                        }
                    }
                }
                /* === end [METAL-SHADER] instrumentation ================== */
                /* [multi-stage-audit] one-shot print for any shader with
                 * stageCount >= 2. Bounded to first 32 unique shaders
                 * (deduped by shaderName). Lets us see exactly which
                 * world surfaces are multi-stage and what stages[]
                 * the parser captured for each — diagnostic for
                 * see-through floor / grate / lightmap-modulate cases. */
                /* One-shot diagnostic for any multi-stage shader.
                 * Bounded to 256 unique entries via dedupe seen-table —
                 * pak0 produces ~150 multi-stage shaders so the bound
                 * holds. Fires PRINT_DEVELOPER so default captures stay
                 * quiet; toggle with `\developer 1` to enable. Per-stage
                 * line includes mapPath/lm/blend/alpha/rgb/tcMods/depthW
                 * so future "is this shader parsed correctly?" questions
                 * can be answered from a log grep instead of a code dive. */
                if (s_worldMapAuditActive && last->stageCount >= 2) {
                    static char s_msaSeen[256][MAX_QPATH];
                    static int s_msaCount = 0;
                    int j, dup = 0;
                    for (j = 0; j < s_msaCount; ++j) {
                        if (!Q_stricmp(s_msaSeen[j], shaderName)) { dup = 1; break; }
                    }
                    if (!dup && s_msaCount < (int)(sizeof(s_msaSeen) / sizeof(s_msaSeen[0]))) {
                        Q_strncpyz(s_msaSeen[s_msaCount++], shaderName, MAX_QPATH);
                        ri.Printf(PRINT_DEVELOPER,
                            "[multi-stage-audit] '%s' stages=%d cull=%d\n",
                            shaderName, last->stageCount, (int)cullMode);
                        for (s = 0; s < last->stageCount; ++s) {
                            ri.Printf(PRINT_DEVELOPER,
                                "  s%d: map='%s' lm=%d blend=%d alpha=%d rgb=%d tcMods=%d depthW=%d\n",
                                s,
                                last->stages[s].mapPath[0] ? last->stages[s].mapPath : "(empty)",
                                (int)last->stages[s].useLightmap,
                                (int)last->stages[s].blendMode,
                                (int)last->stages[s].alphaFunc,
                                (int)last->stages[s].rgbGen,
                                (int)last->stages[s].tcModCount,
                                (int)last->stages[s].depthWrite);
                        }
                    }
                }
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
                if (s_worldMapAuditActive &&
                    (strstr(shaderName, "border11c") ||
                     strstr(shaderName, "xmetalfloor_wall_5b") ||
                     strstr(shaderName, "killblock_i4b"))) {
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

    /* ioq3 concatenates shader files in reverse FS_ListFiles order, then
     * uses the first matching shader text. Preserve that duplicate-name
     * precedence so q3dm4's textures/sfx/xdensegreyfog resolves to the
     * sfx.shader grey fog, not the earlier liquid.shader black variant. */
    for (i = numFiles - 1; i >= 0; --i) {
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
        ParseShaderText(buf);
        ri.FS_FreeFile(buf);
    }

    ri.FS_FreeFileList(fileList);
    ri.Printf(PRINT_ALL, "Metal shader parser: %d shader->map entries loaded from %d files\n",
        s_shaderMapCount, numFiles);
}

/* `test_menu_assets` console command. Registers a curated list of
 * known menu / UI / HUD shaders so the structured `[asset-miss]`
 * diagnostic captures the menu-render path even when the boot cbuf
 * runs straight to demo (which skips main-menu rendering). The list
 * is harvested from prior wedged-run miss logs so each entry is one
 * known-failing or known-curious asset. Idempotent across calls.
 *
 * Diagnostic only — no rendering side effect (RegisterShader returns
 * a handle but the menu draw path doesn't run during `demo four`).
 * Remove after menu asset misses are classified and fixed. */
static void TestMenuAssets_f(void) {
    static const char *names[] = {
        /* Main-menu chrome / level previews */
        "menuback", "menubacknologo", "lagometer", "console", "disconnected",
        "levelShotDetail", "levelshots/q3dm1.tga",
        /* Medal awards */
        "medal_assist", "medal_capture", "medal_defend",
        "medal_excellent", "medal_gauntlet", "medal_impressive",
        /* Powerup overlays (gameplay HUD) */
        "powerups/battleSuit", "powerups/battleWeapon", "powerups/invisibility",
        "powerups/quad", "powerups/quadWeapon", "powerups/regen",
        /* Deferred-load icons (the `_df` suffix our strip fallback handles) */
        "icons/icona_machinegun_df", "icons/icona_plasma_df", "icons/icona_shotgun_df",
        "icons/iconh_red_df", "icons/iconh_yellow_df",
        "icons/iconr_red_df", "icons/iconr_shard_df",
        "icons/iconw_gauntlet_df", "icons/iconw_machinegun_df",
        "icons/iconw_plasma_df", "icons/iconw_rocket_df", "icons/iconw_shotgun_df",
        /* FX shaders that resolve via shader-map walk */
        "bloodMark", "bloodTrail", "bloodExplosion", "bulletExplosion",
        "markShadow", "wake", "viewBloodBlend", "waterBubble",
        "gfx/misc/tracer", "hasteSmokePuff", "shotgunSmokePuff",
        "smokePuff", "smokePuffRagePro",
        "plasmaExplosion", "rocketExplosion", "teleportEffect", "railDisc",
        "sprites/balloon3", "sprites/plasma1",
        /* explode animMap (single representative) */
        "explode11",
        /* 2D HUD primitives */
        "gfx/2d/backtile", "gfx/2d/bigchars", "gfx/2d/colorbar",
        "gfx/2d/select", "gfx/2d/defer.tga",
    };
    int i;
    int n = (int)(sizeof(names) / sizeof(names[0]));
    ri.Printf(PRINT_ALL, "[test_menu_assets] registering %d curated shaders\n", n);
    for (i = 0; i < n; ++i) {
        (void)RE_RegisterShader(names[i]);
    }
    ri.Printf(PRINT_ALL, "[test_menu_assets] done — grep '\\[asset-miss\\]' for misses\n");
}

static void RE_BeginRegistration(glconfig_t *config) {
    ri.Printf(PRINT_ALL, "RE_BeginRegistration: Metal stub\n");
    LoadAllShaders();
    EnsureWhiteTexture();
    EnsureSkyTexture();
    EnsureTimHellBaseTexture();
    EnsureTimHellAddTexture();
    /* Register the menu-asset audit command once. Cmd_AddCommand is
     * idempotent for repeated registrations — RE_BeginRegistration may
     * fire again on vid_restart; the engine drops the duplicate. */
    ri.Cmd_AddCommand("test_menu_assets", TestMenuAssets_f);
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
    Com_Memset(&s_scenePortalSurface, 0, sizeof(s_scenePortalSurface));
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
    /* RT_PORTALSURFACE is metadata for mirror/portal surface matching in
     * the stock renderer. It intentionally does not emit draw geometry.
     * Accept it as a handled no-op so audits only report genuinely missing
     * entity paths. */
    if (re->reType == RT_PORTALSURFACE) {
        AuditOnce("ENTITY:RT_PORTALSURFACE");
        s_scenePortalSurface.valid = qtrue;
        VectorCopy(re->origin, s_scenePortalSurface.origin);
        VectorCopy(re->axis[0], s_scenePortalSurface.axis[0]);
        VectorCopy(re->axis[1], s_scenePortalSurface.axis[1]);
        VectorCopy(re->axis[2], s_scenePortalSurface.axis[2]);
        s_entityAcceptedThisFrame += 1;
        return;
    }
    /* RT_SPRITE: billboard quad (plasma bolts, rail core, muzzle flashes,
     * smoke puffs). We accept sprites into the scene-entity list and emit
     * their geometry at RE_RenderScene time (camera-facing math requires
     * the view axes, which aren't known here). */
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
        AuditOnce("ENTITY:reType unknown");
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
    if (hShader == 0 || verts == NULL || numVerts < 3) return;
    /* num is the number of polys in this batch, each with numVerts verts.
     * Blood/shadow/marks typically call with num=1. Iterate all regardless. */
    for (polyIdx = 0; polyIdx < num; ++polyIdx) {
        int vi;
        if (s_scenePolyCount >= Q3_METAL_MAX_SCENE_POLYS) return;
        if (s_scenePolyVertCount + numVerts > Q3_METAL_MAX_SCENE_POLY_VERTS) return;
        s_scenePolys[s_scenePolyCount].shader = hShader;
        s_scenePolys[s_scenePolyCount].firstVert = s_scenePolyVertCount;
        s_scenePolys[s_scenePolyCount].numVerts = numVerts;
        s_scenePolys[s_scenePolyCount].fogIndex =
            (uint32_t)MetalScenePolyFogIndex(&verts[polyIdx * numVerts], numVerts);
        for (vi = 0; vi < numVerts; ++vi) {
            s_scenePolyVerts[s_scenePolyVertCount + vi] = verts[polyIdx * numVerts + vi];
        }
        if (MetalRenderAuditEnabled()) {
            static int s_polyAuditCount = 0;
            if (s_polyAuditCount < 64) {
                int aMin = 255;
                int aMax = 0;
                float sMin = 9999.0f;
                float sMax = -9999.0f;
                float tMin = 9999.0f;
                float tMax = -9999.0f;
                for (vi = 0; vi < numVerts; ++vi) {
                    const polyVert_t *pv = &verts[polyIdx * numVerts + vi];
                    int a = pv->modulate.rgba[3];
                    if (a < aMin) aMin = a;
                    if (a > aMax) aMax = a;
                    if (pv->st[0] < sMin) sMin = pv->st[0];
                    if (pv->st[0] > sMax) sMax = pv->st[0];
                    if (pv->st[1] < tMin) tMin = pv->st[1];
                    if (pv->st[1] > tMax) tMax = pv->st[1];
                }
                ri.Printf(PRINT_DEVELOPER,
                    "[scene-poly-submit] shader=%d verts=%d alpha=%d..%d st=(%.2f..%.2f,%.2f..%.2f)\n",
                    (int)hShader, numVerts, aMin, aMax, sMin, sMax, tMin, tMax);
                s_polyAuditCount++;
            }
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
        float shaderTime = fd ? (float)fd->time * 0.001f : (float)cls.realtime * 0.001f;
        for (i = 0; i < s_world.drawCount; ++i) {
            int slot = s_world.animShaderSlots[i];
            if (slot >= 0) {
                int srcStageIndex = slot % Q3_MAX_STAGES;
                int drawStageIndex = (s_world.draws[i].stageCount == 1)
                                   ? 0 : srcStageIndex;
                qhandle_t h = ShaderMap_AnimatedSlotCurrentHandle(slot, shaderTime);
                if (h != 0 && drawStageIndex >= 0 &&
                    drawStageIndex < (int)s_world.draws[i].stageCount) {
                    s_world.draws[i].stages[drawStageIndex].textureHandle = (uint32_t)h;
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

	    if (s_world.loaded && !(fd->rdflags & RDF_NOWORLDMODEL)) {
	        MetalWorldBuildVisibleDraws(vieworg, axis0, axis1, axis2, fovX, fovY, fd->areamask);
	    }

	    /* World-scene-only camera. HUD/portrait scenes would overwrite with
	     * their own view, projecting preserved world entity draws off-screen. */
	    if (fd->rdflags == 0) {
        s_frameSnapshot.shaderTime = (float)fd->time * 0.001f;
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

    s_sceneLogCounter += 1;
    if (MetalRenderAuditEnabled() && (s_sceneLogCounter % 60) == 0) {
	        ri.Printf(
	            PRINT_ALL,
	            "Metal debug refdef[%u]: vieworg=(%.2f %.2f %.2f) axis0=(%.3f %.3f %.3f) "
	            "axis1=(%.3f %.3f %.3f) axis2=(%.3f %.3f %.3f) fov=(%.2f %.2f) rdflags=0x%x worldLoaded=%d draws=%u visible=%u static=%u pvs=%d\n",
	            s_sceneLogCounter,
	            vieworg[0], vieworg[1], vieworg[2],
	            axis0[0], axis0[1], axis0[2],
            axis1[0], axis1[1], axis1[2],
            axis2[0], axis2[1], axis2[2],
	            fovX, fovY,
	            fd->rdflags,
	            s_world.loaded,
	            MetalWorldCurrentDrawCount(),
	            s_world.visibleDrawCount,
	            s_world.drawCount,
	            s_world.visibleDrawsValid ? 1 : 0
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
            uint32_t logged = 0;
            for (logIdx = 0; logIdx < s_sceneEntityCount && logged < 10; ++logIdx) {
                const metalSceneEntity_t *se = &s_sceneEntities[logIdx];
                const metalModel_t *mdl;
                const char *name;
                vec3_t firstVertWorld;
                qboolean haveFirstVert = qfalse;
                int depthHack;
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
                logged += 1;
            }
        }
    }

	    if (s_world.loaded && !(fd->rdflags & RDF_NOWORLDMODEL)) {
	        s_frameSnapshot.worldVertexCount = s_world.vertexCount;
	        s_frameSnapshot.worldIndexCount = s_world.indexCount;
	        s_frameSnapshot.worldCommandCount = MetalWorldCurrentDrawCount();
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
            if (sceneEntity->entity.reType == RT_LIGHTNING) {
                totalEntityVerts += 4 * 4;
                totalEntityIndices += 4 * 6;
                totalEntityDraws += 1;
                continue;
            }
            if (sceneEntity->entity.reType == RT_RAIL_CORE) {
                totalEntityVerts += 4;
                totalEntityIndices += 6;
                totalEntityDraws += 1;
                continue;
            }
            if (sceneEntity->entity.reType == RT_RAIL_RINGS) {
                vec3_t railVec;
                float railLen;
                float segmentLength = MetalRailCvarValue("r_railSegmentLength", 32.0f);
                int numSegs;
                VectorSubtract(sceneEntity->entity.origin, sceneEntity->entity.oldorigin, railVec);
                railLen = VectorLength(railVec);
                numSegs = (int)(railLen / segmentLength);
                if (numSegs <= 0) numSegs = 1;
                if (numSegs > 1) numSegs--;
                totalEntityVerts += (uint32_t)(numSegs * 4);
                totalEntityIndices += (uint32_t)(numSegs * 6);
                totalEntityDraws += 1;
                continue;
            }
            if (sceneEntity->entity.reType == RT_BEAM) {
                totalEntityVerts += 6 * 4;
                totalEntityIndices += 6 * 6;
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
                const char *shaderName = NULL;
                int stageDraws = 0;
                if (sceneEntity->entity.customShader == 0 &&
                    sceneEntity->entity.customSkin == 0 &&
                    surface->numShaders > 0) {
                    const md3Shader_t *shader = (const md3Shader_t *)((const byte *)surface + surface->ofsShaders);
                    int shaderSlot = sceneEntity->entity.skinNum % surface->numShaders;
                    if (shaderSlot < 0) shaderSlot = 0;
                    shaderName = shader[shaderSlot].name;
                    stageDraws = EntityPickupStageDrawCount(shaderName);
                }
                totalEntityVerts += (uint32_t)surface->numVerts;
                totalEntityIndices += (uint32_t)(surface->numTriangles * 3);
                totalEntityDraws += (uint32_t)(stageDraws > 0 ? stageDraws : 1);
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
            {
                uint32_t drawInit;
                for (drawInit = entityDrawCursor;
                     drawInit < entityDrawCursor + totalEntityDraws;
                     ++drawInit) {
                    s_entityDraws[drawInit].fogIndex = Q3_METAL_NO_FOG;
                }
            }

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
                    if (sceneEntity->entity.rotation == 0.0f) {
                        VectorScale(axis1, -radius, right);
                        VectorScale(axis2,  radius, up);
                    } else {
                        float ang = (float)(M_PI / 180.0) * sceneEntity->entity.rotation;
                        float s = sinf(ang);
                        float c = cosf(ang);
                        vec3_t left;

                        VectorScale(axis1, c * radius, left);
                        VectorMA(left, -s * radius, axis2, left);

                        VectorScale(axis2, c * radius, up);
                        VectorMA(up, s * radius, axis1, up);

                        VectorSubtract(vec3_origin, left, right);
                    }
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
                        qboolean isAdditiveLike = qfalse;
                        qboolean hasExplicitATest = qfalse;
                        EmitMetalEntityStageAuditForHandle(
                            (qhandle_t)sceneEntity->entity.customShader,
                            "sprite");
                        if (tex != NULL) {
                            if (tex->blendMode == 1) {
                                spriteFlags |= Q3_METAL_ENTITY_DRAWFLAG_ADDITIVE;
                                isAdditiveLike = qtrue;
                            } else if (tex->blendMode == 2) {
                                spriteFlags |= Q3_METAL_ENTITY_DRAWFLAG_ALPHA;
                            } else if (tex->blendMode == 3) {
                                spriteFlags |= Q3_METAL_ENTITY_DRAWFLAG_FILTER;
                            } else if (tex->blendMode == 4) {
                                spriteFlags |= Q3_METAL_ENTITY_DRAWFLAG_SUBTRACT;
                            } else if (tex->blendMode == 5) {
                                spriteFlags |= Q3_METAL_ENTITY_DRAWFLAG_ADDITIVE_FULL;
                                isAdditiveLike = qtrue;
                            } else {
                                spriteFlags |= Q3_METAL_ENTITY_DRAWFLAG_ADDITIVE;
                                isAdditiveLike = qtrue;
                            }
                            hasExplicitATest = (tex->alphaFunc != 0);
                        } else {
                            spriteFlags |= Q3_METAL_ENTITY_DRAWFLAG_ADDITIVE;
                            isAdditiveLike = qtrue;
                        }
                        /* TASK #1: force implicit alphaFunc GT0 for sprites
                         * whose shader uses additive blending and doesn't
                         * set alphaFunc explicitly. Prevents JPEG-compressed
                         * dark-but-not-black rlboom/plasma/flash borders
                         * from contributing to GL_ONE/GL_ONE blend
                         * (classic hard-rectangular explosion quad). */
                        if (isAdditiveLike && !hasExplicitATest) {
                            spriteFlags |= Q3_METAL_ENTITY_DRAWFLAG_ATEST_GT0;
                        }
                        if (MetalVerboseAuditEnabled() && MetalRenderAuditEnabled()) {
                            static int s_spriteAuditCount = 0;
                            if (s_spriteAuditCount < 64) {
                                ri.Printf(PRINT_DEVELOPER,
                                    "[sprite-audit] shader=%d tex='%s' radius=%.1f rgba=%.2f,%.2f,%.2f,%.2f blend=%d alphaFunc=%d rgbGen=%d alphaGen=%d flags=0x%x\n",
                                    (int)sceneEntity->entity.customShader,
                                    tex ? tex->name : "(no-tex)",
                                    radius, r, g, b, a,
                                    tex ? tex->blendMode : -1,
                                    tex ? tex->alphaFunc : -1,
                                    tex ? tex->rgbGen : -1,
                                    tex ? tex->alphaGen : -1,
                                    (unsigned)spriteFlags);
                                s_spriteAuditCount++;
                            }
                        }
                        s_entityDraws[entityDrawCursor].firstIndex = firstIndex;
                        s_entityDraws[entityDrawCursor].indexCount = 6;
                        s_entityDraws[entityDrawCursor].textureHandle = (uint32_t)sceneEntity->entity.customShader;
                        s_entityDraws[entityDrawCursor].flags = spriteFlags;
                        SetEntityDrawColor(entityDrawCursor, &sceneEntity->entity,
                                           (qhandle_t)sceneEntity->entity.customShader);
                    }
                    entityDrawCursor += 1;
                    continue;
                }

                if (sceneEntity->entity.reType == RT_LIGHTNING) {
                    uint32_t firstIndex = entityIndexCursor;
                    const float *start = sceneEntity->entity.origin;
                    const float *end = sceneEntity->entity.oldorigin;
                    vec3_t beamDir, v1, v2, right;
                    float len;
                    float r, g, b, a;
                    int i;

                    VectorSubtract(end, start, beamDir);
                    len = VectorNormalize(beamDir);
                    if (len == 0.0f) continue;

                    VectorSubtract(start, vieworg, v1);
                    VectorNormalize(v1);
                    VectorSubtract(end, vieworg, v2);
                    VectorNormalize(v2);
                    CrossProduct(v1, v2, right);
                    VectorNormalize(right);

                    r = (float)sceneEntity->entity.shader.rgba[0] / 255.0f;
                    g = (float)sceneEntity->entity.shader.rgba[1] / 255.0f;
                    b = (float)sceneEntity->entity.shader.rgba[2] / 255.0f;
                    a = (float)sceneEntity->entity.shader.rgba[3] / 255.0f;

                    for (i = 0; i < 4; ++i) {
                        vec3_t temp;
                        MetalEmitRailCore(&entityVertexCursor, &entityIndexCursor,
                                          start, end, right, len, 8.0f,
                                          r, g, b, a);
                        RotatePointAroundVector(temp, beamDir, right, 45.0f);
                        VectorCopy(temp, right);
                    }

                    s_entityDraws[entityDrawCursor].firstIndex = firstIndex;
                    s_entityDraws[entityDrawCursor].indexCount = entityIndexCursor - firstIndex;
                    s_entityDraws[entityDrawCursor].textureHandle =
                        (uint32_t)sceneEntity->entity.customShader;
                    s_entityDraws[entityDrawCursor].flags =
                        EntityFlagsForTexture((qhandle_t)sceneEntity->entity.customShader,
                                              Q3_METAL_ENTITY_DRAWFLAG_NOCULL,
                                              qfalse);
                    EmitMetalEntityStageAuditForHandle(
                        (qhandle_t)sceneEntity->entity.customShader,
                        "lightning");
                    SetEntityDrawColor(entityDrawCursor, &sceneEntity->entity,
                                       (qhandle_t)sceneEntity->entity.customShader);
                    entityDrawCursor += 1;
                    continue;
                }

                if (sceneEntity->entity.reType == RT_RAIL_CORE) {
                    uint32_t firstIndex = entityIndexCursor;
                    const float *start = sceneEntity->entity.origin;
                    const float *end = sceneEntity->entity.oldorigin;
                    vec3_t beamDir, v1, v2, right;
                    float len;
                    float r, g, b, a;
                    float spanWidth = (float)MetalRailCvarInteger("r_railCoreWidth", 6);

                    VectorSubtract(end, start, beamDir);
                    len = VectorNormalize(beamDir);
                    if (len == 0.0f) continue;

                    VectorSubtract(start, vieworg, v1); VectorNormalize(v1);
                    VectorSubtract(end, vieworg, v2);   VectorNormalize(v2);
                    CrossProduct(v1, v2, right);
                    VectorNormalize(right);

                    r = (float)sceneEntity->entity.shader.rgba[0] / 255.0f;
                    g = (float)sceneEntity->entity.shader.rgba[1] / 255.0f;
                    b = (float)sceneEntity->entity.shader.rgba[2] / 255.0f;
                    a = (float)sceneEntity->entity.shader.rgba[3] / 255.0f;

                    MetalEmitRailCore(&entityVertexCursor, &entityIndexCursor,
                                      start, end, right, len, spanWidth,
                                      r, g, b, a);

                    s_entityDraws[entityDrawCursor].firstIndex = firstIndex;
                    s_entityDraws[entityDrawCursor].indexCount = 6;
                    s_entityDraws[entityDrawCursor].textureHandle =
                        (uint32_t)sceneEntity->entity.customShader;
                    s_entityDraws[entityDrawCursor].flags =
                        EntityFlagsForTexture((qhandle_t)sceneEntity->entity.customShader,
                                              Q3_METAL_ENTITY_DRAWFLAG_NOCULL,
                                              qfalse);
                    EmitMetalEntityStageAuditForHandle(
                        (qhandle_t)sceneEntity->entity.customShader,
                        "rail_core");
                    SetEntityDrawColor(entityDrawCursor, &sceneEntity->entity,
                                       (qhandle_t)sceneEntity->entity.customShader);
                    entityDrawCursor += 1;
                    continue;
                }

                if (sceneEntity->entity.reType == RT_BEAM) {
                    uint32_t firstIndex = entityIndexCursor;
                    const float *start = sceneEntity->entity.origin;
                    const float *end = sceneEntity->entity.oldorigin;
                    vec3_t direction, normalizedDirection, perpvec;
                    float len;
                    qhandle_t texHandle;
                    int i;

                    VectorSubtract(end, start, direction);
                    VectorCopy(direction, normalizedDirection);
                    len = VectorNormalize(normalizedDirection);
                    if (len == 0.0f) continue;

                    PerpendicularVector(perpvec, normalizedDirection);
                    VectorScale(perpvec, 4.0f, perpvec);

                    for (i = 0; i < 6; ++i) {
                        uint32_t vbase = entityVertexCursor;
                        vec3_t s0, s1, e0, e1, rot0, rot1;
                        RotatePointAroundVector(rot0, normalizedDirection, perpvec, (360.0f / 6.0f) * i);
                        RotatePointAroundVector(rot1, normalizedDirection, perpvec, (360.0f / 6.0f) * (i + 1));
                        VectorAdd(start, rot0, s0);
                        VectorAdd(start, rot1, s1);
                        VectorAdd(end, rot1, e1);
                        VectorAdd(end, rot0, e0);

                        MetalSetEntityVertex(vbase + 0, s0, 0.0f, 0.0f, 1.0f, 0.0f, 0.0f, 1.0f);
                        MetalSetEntityVertex(vbase + 1, s1, 0.0f, 1.0f, 1.0f, 0.0f, 0.0f, 1.0f);
                        MetalSetEntityVertex(vbase + 2, e1, 1.0f, 1.0f, 1.0f, 0.0f, 0.0f, 1.0f);
                        MetalSetEntityVertex(vbase + 3, e0, 1.0f, 0.0f, 1.0f, 0.0f, 0.0f, 1.0f);

                        s_entityIndices[entityIndexCursor + 0] = vbase + 0;
                        s_entityIndices[entityIndexCursor + 1] = vbase + 1;
                        s_entityIndices[entityIndexCursor + 2] = vbase + 2;
                        s_entityIndices[entityIndexCursor + 3] = vbase + 0;
                        s_entityIndices[entityIndexCursor + 4] = vbase + 2;
                        s_entityIndices[entityIndexCursor + 5] = vbase + 3;
                        entityVertexCursor += 4;
                        entityIndexCursor += 6;
                    }

                    texHandle = (qhandle_t)EnsureWhiteTexture();
                    s_entityDraws[entityDrawCursor].firstIndex = firstIndex;
                    s_entityDraws[entityDrawCursor].indexCount = entityIndexCursor - firstIndex;
                    s_entityDraws[entityDrawCursor].textureHandle = (uint32_t)texHandle;
                    s_entityDraws[entityDrawCursor].flags =
                        Q3_METAL_ENTITY_DRAWFLAG_NOCULL |
                        Q3_METAL_ENTITY_DRAWFLAG_ADDITIVE_FULL;
                    EmitMetalEntityStageAuditForHandle(texHandle, "beam");
                    SetEntityDrawColor(entityDrawCursor, &sceneEntity->entity,
                                       (qhandle_t)texHandle);
                    entityDrawCursor += 1;
                    continue;
                }

                if (sceneEntity->entity.reType == RT_RAIL_RINGS) {
                    uint32_t firstIndex = entityIndexCursor;
                    const float *a0 = sceneEntity->entity.oldorigin; /* start */
                    const float *a1 = sceneEntity->entity.origin;    /* end */
                    vec3_t vec, right, up;
                    vec3_t pos[4];
                    float len;
                    float segmentLength = MetalRailCvarValue("r_railSegmentLength", 32.0f);
                    int spanWidth = MetalRailCvarInteger("r_railWidth", 16);
                    int numSegs;
                    int seg;
                    float r, g, b, a;
                    uint32_t localIndexCount = 0;
                    int j;

                    VectorSubtract(a1, a0, vec);
                    len = VectorNormalize(vec);
                    if (len == 0.0f) continue;
                    MakeNormalVectors(vec, right, up);

                    numSegs = (int)(len / segmentLength);
                    if (numSegs <= 0) numSegs = 1;
                    VectorScale(vec, segmentLength, vec);
                    if (numSegs > 1) numSegs--;
                    if (!numSegs) continue;

                    r = (float)sceneEntity->entity.shader.rgba[0] / 255.0f;
                    g = (float)sceneEntity->entity.shader.rgba[1] / 255.0f;
                    b = (float)sceneEntity->entity.shader.rgba[2] / 255.0f;
                    a = (float)sceneEntity->entity.shader.rgba[3] / 255.0f;

                    for (j = 0; j < 4; ++j) {
                        vec3_t v;
                        float c = cosf((float)(M_PI / 180.0) * (45.0f + (float)j * 90.0f));
                        float s = sinf((float)(M_PI / 180.0) * (45.0f + (float)j * 90.0f));
                        v[0] = (right[0] * c + up[0] * s) * 0.25f * (float)spanWidth;
                        v[1] = (right[1] * c + up[1] * s) * 0.25f * (float)spanWidth;
                        v[2] = (right[2] * c + up[2] * s) * 0.25f * (float)spanWidth;
                        VectorAdd(a0, v, pos[j]);
                        if (numSegs > 1) {
                            VectorAdd(pos[j], vec, pos[j]);
                        }
                    }

                    for (seg = 0; seg < numSegs; ++seg) {
                        uint32_t segBase = entityVertexCursor;
                        int vi;

                        for (vi = 0; vi < 4; ++vi) {
                            MetalSetEntityVertex(segBase + vi, pos[vi],
                                                 (float)(vi < 2),
                                                 (float)(vi && vi != 3),
                                                 r, g, b, a);
                            VectorAdd(pos[vi], vec, pos[vi]);
                        }
                        s_entityIndices[entityIndexCursor + 0] = segBase + 0;
                        s_entityIndices[entityIndexCursor + 1] = segBase + 1;
                        s_entityIndices[entityIndexCursor + 2] = segBase + 3;
                        s_entityIndices[entityIndexCursor + 3] = segBase + 3;
                        s_entityIndices[entityIndexCursor + 4] = segBase + 1;
                        s_entityIndices[entityIndexCursor + 5] = segBase + 2;
                        entityVertexCursor += 4;
                        entityIndexCursor += 6;
                        localIndexCount += 6;
                    }

                    s_entityDraws[entityDrawCursor].firstIndex = firstIndex;
                    s_entityDraws[entityDrawCursor].indexCount = localIndexCount;
                    s_entityDraws[entityDrawCursor].textureHandle =
                        (uint32_t)sceneEntity->entity.customShader;
                    s_entityDraws[entityDrawCursor].flags =
                        EntityFlagsForTexture((qhandle_t)sceneEntity->entity.customShader,
                                              Q3_METAL_ENTITY_DRAWFLAG_NOCULL,
                                              qfalse);
                    EmitMetalEntityStageAuditForHandle(
                        (qhandle_t)sceneEntity->entity.customShader,
                        "rail_rings");
                    SetEntityDrawColor(entityDrawCursor, &sceneEntity->entity,
                                       (qhandle_t)sceneEntity->entity.customShader);
                    entityDrawCursor += 1;
                    continue;
                }

                model = FindModelByHandle(sceneEntity->entity.hModel);
                if (model == NULL || model->md3 == NULL) {
                    continue;
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

                /* Use the entity transform as submitted by cgame. */
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
                    const char *shaderNameForStages = NULL;
                    uint32_t drawFlags = Q3_METAL_ENTITY_DRAWFLAG_NOCULL;
                    uint32_t baseDrawFlags;
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
                        shaderNameForStages = shader[shaderSlot].name;
                        textureHandle = RegisterTexture(shader[shaderSlot].name);
                    }

                    if (sceneEntity->entity.renderfx & RF_DEPTHHACK) {
                        drawFlags |= Q3_METAL_ENTITY_DRAWFLAG_DEPTHHACK;
                    }
                    baseDrawFlags = drawFlags;
                    {
                        drawFlags = EntityFlagsForTexture(textureHandle, drawFlags, qtrue);
                        /* === [QUAD-EMIT] runtime trace for chrome-shell draws ===
                         * When the entity uses a customShader whose texture name
                         * contains "quad" (powerups/quadWeapon for the viewmodel
                         * chrome shell), log everything the entity draw cmd will
                         * carry so we can diff what cgame emitted vs what reached
                         * the Swift entity loop. Logged to the same Documents/
                         * baseq3/metalshader.log file as [METAL-SHADER] dumps so
                         * one devicectl pull captures both. */
                        if (sceneEntity->entity.customShader != 0) {
                            const metalTexture_t *tex = FindTextureByHandle(textureHandle);
                            const char *texName = (tex != NULL) ? tex->name : "(no-tex)";
                            if (Q_stristr(texName, "quad") || Q_stristr(texName, "powerup") ||
                                Q_stristr(texName, "battle") || Q_stristr(texName, "regen")) {
                                static FILE *s_quadEmitFP = NULL;
                                if (s_quadEmitFP == NULL) {
                                    const char *home = getenv("HOME");
                                    if (home != NULL && home[0]) {
                                        char path[1024];
                                        Com_sprintf(path, sizeof(path),
                                                    "%s/Documents/baseq3/metalshader.log", home);
                                        s_quadEmitFP = fopen(path, "a");
                                    }
                                }
                                if (s_quadEmitFP != NULL) {
                                    static int s_quadEmitCount = 0;
                                    if (s_quadEmitCount < 20) {
                                        fprintf(s_quadEmitFP,
                                            "[QUAD-EMIT] tex='%s' handle=%u customShader=%d "
                                            "blendMode=%d tcModCount=%d "
                                            "tcGenEnv=%d deformWaveFunc=%d deformWaveBase=%.3f "
                                            "baseFlags=0x%x finalFlags=0x%x renderfx=0x%x\n",
                                            texName, textureHandle, sceneEntity->entity.customShader,
                                            tex ? tex->blendMode : -1,
                                            tex ? (int)tex->tcModCount : -1,
                                            tex ? tex->tcGenEnv : -1,
                                            tex ? (int)tex->deformWaveFunc : -1,
                                            tex ? tex->deformWaveBase : 0.0f,
                                            baseDrawFlags, drawFlags,
                                            sceneEntity->entity.renderfx);
                                        fflush(s_quadEmitFP);
                                        s_quadEmitCount++;
                                    }
                                }
                            }
                        }
                        /* === end [QUAD-EMIT] runtime trace ====================== */
                        if (shaderNameForStages != NULL) {
                            EmitMetalEntityStageAudit(shaderNameForStages, "model");
                        } else {
                            EmitMetalEntityStageAuditForHandle(textureHandle, "model");
                        }
                        if (MetalVerboseAuditEnabled() && MetalRenderAuditEnabled()) {
                            const metalTexture_t *tex = FindTextureByHandle(textureHandle);
                            static int s_entityBlendLog = 0;
                            if (s_entityBlendLog < 5 && tex != NULL) {
                                ri.Printf(PRINT_DEVELOPER, "Metal entity blend: tex='%s' bm=%d flags=0x%x\n",
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

                    if (shaderNameForStages != NULL &&
                        EntityPickupStageDrawCount(shaderNameForStages) > 0) {
                        const metalShaderMap_t *entry = ShaderMap_LookupEntry(shaderNameForStages);
                        int si;
                        for (si = 0; entry != NULL && si < entry->stageCount; ++si) {
                            qhandle_t stageHandle = RegisterEntityStageTexture(shaderNameForStages, si);
                            if (stageHandle == 0) continue;
                            s_entityDraws[entityDrawCursor].firstIndex = firstIndex;
                            s_entityDraws[entityDrawCursor].indexCount = entityIndexCursor - firstIndex;
                            s_entityDraws[entityDrawCursor].textureHandle = (uint32_t)stageHandle;
                            s_entityDraws[entityDrawCursor].flags =
                                EntityFlagsForTexture(stageHandle, baseDrawFlags, qfalse);
                            SetEntityDrawColor(entityDrawCursor, &sceneEntity->entity, stageHandle);
                            entityDrawCursor += 1;
                        }
                    } else {
                        s_entityDraws[entityDrawCursor].firstIndex = firstIndex;
                        s_entityDraws[entityDrawCursor].indexCount = entityIndexCursor - firstIndex;
                        s_entityDraws[entityDrawCursor].textureHandle = (uint32_t)textureHandle;
                        s_entityDraws[entityDrawCursor].flags = drawFlags;
                        SetEntityDrawColor(entityDrawCursor, &sceneEntity->entity, textureHandle);
                        entityDrawCursor += 1;
                    }

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
                    uint32_t polyFlags = 0;

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
                        dst->normal[0] = 0.0f;
                        dst->normal[1] = 0.0f;
                        dst->normal[2] = 0.0f;
                    }
                    for (ti = 0; ti < nv - 2; ++ti) {
                        s_entityIndices[entityIndexCursor + ti * 3 + 0] = baseVertex;
                        s_entityIndices[entityIndexCursor + ti * 3 + 1] = baseVertex + ti + 1;
                        s_entityIndices[entityIndexCursor + ti * 3 + 2] = baseVertex + ti + 2;
                    }

                    /* Tag scene-poly draws so Swift entity pass can apply
                     * scene-poly-specific state (no dlight amplification,
                     * no ndotl lighting — cgame has already computed the
                     * vertex modulate). No rgbGen/alphaGen overrides:
                     * the shader's resolved genMode flows through verbatim
                     * per TASK PART 3 "use EXACT data from cgame." */
                    polyFlags |= Q3_METAL_ENTITY_DRAWFLAG_SCENE_POLY;

                    ptex = FindTextureByHandle(poly->shader);
                    if (ptex != NULL) {
                        if (ptex->blendMode == 1) polyFlags |= Q3_METAL_ENTITY_DRAWFLAG_ADDITIVE;
                        else if (ptex->blendMode == 2) polyFlags |= Q3_METAL_ENTITY_DRAWFLAG_ALPHA;
                        else if (ptex->blendMode == 3) polyFlags |= Q3_METAL_ENTITY_DRAWFLAG_FILTER;
                        else if (ptex->blendMode == 4) polyFlags |= Q3_METAL_ENTITY_DRAWFLAG_SUBTRACT;
                        else if (ptex->blendMode == 5) polyFlags |= Q3_METAL_ENTITY_DRAWFLAG_ADDITIVE_FULL;
                        /* Unresolved blend = upstream default shader = OPAQUE
                         * (GL_ONE/GL_ZERO). No flag set → opaque pipeline. */
                    }
                    EmitMetalEntityStageAuditForHandle((qhandle_t)poly->shader, "poly");

                    /* One-shot audit: log the first time each distinct
                     * poly shader routes through here. Grep the capture
                     * log for '[decal-audit]' to confirm blood vs
                     * bullet-mark vs markShadow land on the expected
                     * blendMode + drawflag combination. */
                    {
                        static qhandle_t s_auditSeen[64];
                        static int s_auditCount = 0;
                        qboolean isNew = qtrue;
                        for (int i = 0; i < s_auditCount; i++) {
                            if (s_auditSeen[i] == poly->shader) { isNew = qfalse; break; }
                        }
                        if (MetalVerboseAuditEnabled() && isNew && s_auditCount < 64) {
                            s_auditSeen[s_auditCount++] = poly->shader;
                            ri.Printf(PRINT_ALL,
                                "[decal-audit] shader=%d name='%s' blendMode=%d rgbGen=%d polyFlags=0x%X\n",
                                (int)poly->shader,
                                ptex ? ptex->name : "(no-tex)",
                                ptex ? (int)ptex->blendMode : -1,
                                ptex ? (int)ptex->rgbGen    : -1,
                                (unsigned)polyFlags);
                        }
                    }

                    s_entityDraws[entityDrawCursor].firstIndex = firstIndex;
                    s_entityDraws[entityDrawCursor].indexCount = (uint32_t)((nv - 2) * 3);
                    s_entityDraws[entityDrawCursor].textureHandle = (uint32_t)poly->shader;
                    s_entityDraws[entityDrawCursor].flags = polyFlags;
                    s_entityDraws[entityDrawCursor].fogIndex = poly->fogIndex;
                    /* Scene polys (RE_AddPolyToScene) carry per-vertex
                     * polyVert_t.modulate already; rgbGen=entity isn't a
                     * concept here. Default the per-draw entityColor to
                     * white so any oneMinusEntity/entity stage on the
                     * shader returns identity. */
                    SetEntityDrawColor(entityDrawCursor, NULL, (qhandle_t)poly->shader);

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
    if (MetalRenderAuditEnabled() && (s_sceneLogCounter % 60) == 0) {
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
    s_frameSnapshot.shaderTime = 0.0f;
}

static void RE_EndFrame(int *frontEndMsec, int *backEndMsec) {
    s_frameSnapshot.frameNumber += 1;
    s_frameSnapshot.vertexCount = s_vertexCount;
    s_frameSnapshot.commandCount = s_drawCount;
    if (frontEndMsec) *frontEndMsec = 0;
    if (backEndMsec) *backEndMsec = 0;
}

/* =================================================================
 * R_MarkFragments — verbatim port of ioquake3 renderer/tr_marks.c
 * Operates against the parallel bspMnode_t/bspMsurface_t tree built
 * in LoadWorldMapData via BspLoad(). Structure layouts and control
 * flow match upstream exactly (R_ChopPolyBehindPlane, R_BoxSurfaces_r,
 * R_AddMarkFragments, R_MarkFragments).
 * ================================================================= */

#define BSP_MARK_MAX_VERTS_ON_POLY 64
#define BSP_MARK_SIDE_FRONT 0
#define BSP_MARK_SIDE_BACK  1
#define BSP_MARK_SIDE_ON    2
#define BSP_MARK_MARKER_OFFSET 0

static void BspChopPolyBehindPlane(int numInPoints, vec3_t inPoints[BSP_MARK_MAX_VERTS_ON_POLY],
                                   int *numOutPoints, vec3_t outPoints[BSP_MARK_MAX_VERTS_ON_POLY],
                                   vec3_t normal, vec_t dist, vec_t epsilon) {
    float dists[BSP_MARK_MAX_VERTS_ON_POLY+4];
    int sides[BSP_MARK_MAX_VERTS_ON_POLY+4];
    int counts[3];
    float dot;
    int i, j;
    float *p1, *p2, *clip;
    float d;

    if (numInPoints >= BSP_MARK_MAX_VERTS_ON_POLY - 2) { *numOutPoints = 0; return; }

    counts[0] = counts[1] = counts[2] = 0;
    dists[0] = 0.0f;
    sides[0] = 0;

    for (i = 0; i < numInPoints; i++) {
        dot = DotProduct(inPoints[i], normal);
        dot -= dist;
        dists[i] = dot;
        if (dot > epsilon) sides[i] = BSP_MARK_SIDE_FRONT;
        else if (dot < -epsilon) sides[i] = BSP_MARK_SIDE_BACK;
        else sides[i] = BSP_MARK_SIDE_ON;
        counts[sides[i]]++;
    }
    sides[i] = sides[0];
    dists[i] = dists[0];

    *numOutPoints = 0;
    if (!counts[0]) return;
    if (!counts[1]) {
        *numOutPoints = numInPoints;
        Com_Memcpy(outPoints, inPoints, numInPoints * sizeof(vec3_t));
        return;
    }

    for (i = 0; i < numInPoints; i++) {
        p1 = inPoints[i];
        clip = outPoints[*numOutPoints];
        if (sides[i] == BSP_MARK_SIDE_ON) {
            VectorCopy(p1, clip);
            (*numOutPoints)++;
            continue;
        }
        if (sides[i] == BSP_MARK_SIDE_FRONT) {
            VectorCopy(p1, clip);
            (*numOutPoints)++;
            clip = outPoints[*numOutPoints];
        }
        if (sides[i+1] == BSP_MARK_SIDE_ON || sides[i+1] == sides[i]) continue;
        p2 = inPoints[(i+1) % numInPoints];
        d = dists[i] - dists[i+1];
        dot = (d == 0) ? 0.0f : (dists[i] / d);
        for (j = 0; j < 3; j++)
            clip[j] = p1[j] + dot * (p2[j] - p1[j]);
        (*numOutPoints)++;
    }
}

static void BspBoxSurfaces_r(bspMnode_t *node, vec3_t mins, vec3_t maxs,
                             bspSurfaceType_t **list, int listsize, int *listlength, vec3_t dir) {
    int s, c;
    bspMsurface_t *surf, **mark;

    while (node->contents == CONTENTS_NODE) {
        s = BoxOnPlaneSide(mins, maxs, node->plane);
        if (s == 1) {
            node = node->children[0];
        } else if (s == 2) {
            node = node->children[1];
        } else {
            BspBoxSurfaces_r(node->children[0], mins, maxs, list, listsize, listlength, dir);
            node = node->children[1];
        }
    }

    mark = node->firstmarksurface;
    c = node->nummarksurfaces;
    while (c--) {
        if (*listlength >= listsize) break;
        surf = *mark;
        if (surf->shader &&
            ((surf->shader->surfaceFlags & (SURF_NOIMPACT | SURF_NOMARKS)) ||
             (surf->shader->contentFlags & CONTENTS_FOG))) {
            surf->viewCount = s_bspViewCount;
        } else if (*(surf->data) == BSP_SF_FACE) {
            s = BoxOnPlaneSide(mins, maxs, &((bspSrfSurfaceFace_t *)surf->data)->plane);
            if (s == 1 || s == 2) {
                surf->viewCount = s_bspViewCount;
            } else if (DotProduct(((bspSrfSurfaceFace_t *)surf->data)->plane.normal, dir) > -0.5) {
                surf->viewCount = s_bspViewCount;
            }
        } else if (*(bspSurfaceType_t *)(surf->data) != BSP_SF_GRID &&
                   *(bspSurfaceType_t *)(surf->data) != BSP_SF_TRIANGLES) {
            surf->viewCount = s_bspViewCount;
        }
        if (surf->viewCount != s_bspViewCount) {
            surf->viewCount = s_bspViewCount;
            list[*listlength] = (bspSurfaceType_t *)surf->data;
            (*listlength)++;
        }
        mark++;
    }
}

static void BspAddMarkFragments(int numClipPoints, vec3_t clipPoints[2][BSP_MARK_MAX_VERTS_ON_POLY],
                                int numPlanes, vec3_t *normals, float *dists,
                                int maxPoints, vec3_t pointBuffer,
                                int maxFragments, markFragment_t *fragmentBuffer,
                                int *returnedPoints, int *returnedFragments,
                                vec3_t mins, vec3_t maxs) {
    int pingPong, i;
    markFragment_t *mf;

    pingPong = 0;
    for (i = 0; i < numPlanes; i++) {
        BspChopPolyBehindPlane(numClipPoints, clipPoints[pingPong],
                               &numClipPoints, clipPoints[!pingPong],
                               normals[i], dists[i], 0.5);
        pingPong ^= 1;
        if (numClipPoints == 0) break;
    }
    if (numClipPoints == 0) return;
    if (numClipPoints + (*returnedPoints) > maxPoints) return;

    mf = fragmentBuffer + (*returnedFragments);
    mf->firstPoint = (*returnedPoints);
    mf->numPoints = numClipPoints;
    Com_Memcpy(pointBuffer + (*returnedPoints) * 3, clipPoints[pingPong],
               numClipPoints * sizeof(vec3_t));
    (*returnedPoints) += numClipPoints;
    (*returnedFragments)++;
    (void)mins; (void)maxs;
}

static int R_MarkFragments(int numPoints, const vec3_t *points, const vec3_t projection,
                           int maxPoints, vec3_t pointBuffer, int maxFragments,
                           markFragment_t *fragmentBuffer) {
    int numsurfaces, numPlanes;
    int i, j, k, m, n;
    bspSurfaceType_t *surfaces[64];
    vec3_t mins, maxs;
    int returnedFragments;
    int returnedPoints;
    vec3_t normals[BSP_MARK_MAX_VERTS_ON_POLY+2];
    float dists[BSP_MARK_MAX_VERTS_ON_POLY+2];
    vec3_t clipPoints[2][BSP_MARK_MAX_VERTS_ON_POLY];
    int numClipPoints;
    float *v;
    bspSrfGridMesh_t *cv;
    drawVert_t *dv;
    vec3_t normal;
    vec3_t projectionDir;
    vec3_t v1, v2;
    int *indexes;

    if (numPoints <= 0) return 0;
    if (!s_bspWorld.loaded || s_bspWorld.nodes == NULL) return 0;

    s_bspViewCount++;

    VectorNormalize2(projection, projectionDir);
    ClearBounds(mins, maxs);
    for (i = 0; i < numPoints; i++) {
        vec3_t temp;
        AddPointToBounds(points[i], mins, maxs);
        VectorAdd(points[i], projection, temp);
        AddPointToBounds(temp, mins, maxs);
        VectorMA(points[i], -20, projectionDir, temp);
        AddPointToBounds(temp, mins, maxs);
    }

    if (numPoints > BSP_MARK_MAX_VERTS_ON_POLY) numPoints = BSP_MARK_MAX_VERTS_ON_POLY;
    for (i = 0; i < numPoints; i++) {
        VectorSubtract(points[(i+1)%numPoints], points[i], v1);
        VectorAdd(points[i], projection, v2);
        VectorSubtract(points[i], v2, v2);
        CrossProduct(v1, v2, normals[i]);
        VectorNormalizeFast(normals[i]);
        dists[i] = DotProduct(normals[i], points[i]);
    }
    VectorCopy(projectionDir, normals[numPoints]);
    dists[numPoints] = DotProduct(normals[numPoints], points[0]) - 32;
    VectorCopy(projectionDir, normals[numPoints+1]);
    VectorInverse(normals[numPoints+1]);
    dists[numPoints+1] = DotProduct(normals[numPoints+1], points[0]) - 20;
    numPlanes = numPoints + 2;

    numsurfaces = 0;
    BspBoxSurfaces_r(s_bspWorld.nodes, mins, maxs, surfaces, 64, &numsurfaces, projectionDir);

    returnedPoints = 0;
    returnedFragments = 0;

    for (i = 0; i < numsurfaces; i++) {
        if (*surfaces[i] == BSP_SF_GRID) {
            cv = (bspSrfGridMesh_t *)surfaces[i];
            for (m = 0; m < cv->height - 1; m++) {
                for (n = 0; n < cv->width - 1; n++) {
                    numClipPoints = 3;
                    dv = cv->verts + m * cv->width + n;

                    VectorCopy(dv[0].xyz, clipPoints[0][0]);
                    VectorMA(clipPoints[0][0], BSP_MARK_MARKER_OFFSET, dv[0].normal, clipPoints[0][0]);
                    VectorCopy(dv[cv->width].xyz, clipPoints[0][1]);
                    VectorMA(clipPoints[0][1], BSP_MARK_MARKER_OFFSET, dv[cv->width].normal, clipPoints[0][1]);
                    VectorCopy(dv[1].xyz, clipPoints[0][2]);
                    VectorMA(clipPoints[0][2], BSP_MARK_MARKER_OFFSET, dv[1].normal, clipPoints[0][2]);
                    VectorSubtract(clipPoints[0][0], clipPoints[0][1], v1);
                    VectorSubtract(clipPoints[0][2], clipPoints[0][1], v2);
                    CrossProduct(v1, v2, normal);
                    VectorNormalizeFast(normal);
                    if (DotProduct(normal, projectionDir) < -0.1) {
                        BspAddMarkFragments(numClipPoints, clipPoints,
                                            numPlanes, normals, dists,
                                            maxPoints, pointBuffer,
                                            maxFragments, fragmentBuffer,
                                            &returnedPoints, &returnedFragments, mins, maxs);
                        if (returnedFragments == maxFragments) return returnedFragments;
                    }

                    VectorCopy(dv[1].xyz, clipPoints[0][0]);
                    VectorMA(clipPoints[0][0], BSP_MARK_MARKER_OFFSET, dv[1].normal, clipPoints[0][0]);
                    VectorCopy(dv[cv->width].xyz, clipPoints[0][1]);
                    VectorMA(clipPoints[0][1], BSP_MARK_MARKER_OFFSET, dv[cv->width].normal, clipPoints[0][1]);
                    VectorCopy(dv[cv->width+1].xyz, clipPoints[0][2]);
                    VectorMA(clipPoints[0][2], BSP_MARK_MARKER_OFFSET, dv[cv->width+1].normal, clipPoints[0][2]);
                    VectorSubtract(clipPoints[0][0], clipPoints[0][1], v1);
                    VectorSubtract(clipPoints[0][2], clipPoints[0][1], v2);
                    CrossProduct(v1, v2, normal);
                    VectorNormalizeFast(normal);
                    if (DotProduct(normal, projectionDir) < -0.05) {
                        BspAddMarkFragments(numClipPoints, clipPoints,
                                            numPlanes, normals, dists,
                                            maxPoints, pointBuffer,
                                            maxFragments, fragmentBuffer,
                                            &returnedPoints, &returnedFragments, mins, maxs);
                        if (returnedFragments == maxFragments) return returnedFragments;
                    }
                }
            }
        } else if (*surfaces[i] == BSP_SF_FACE) {
            bspSrfSurfaceFace_t *surf = (bspSrfSurfaceFace_t *)surfaces[i];
            if (DotProduct(surf->plane.normal, projectionDir) > -0.5) continue;
            indexes = (int *)((byte *)surf + surf->ofsIndices);
            for (k = 0; k < surf->numIndices; k += 3) {
                for (j = 0; j < 3; j++) {
                    v = &surf->points[0][0] + BSP_VERTEXSIZE * indexes[k+j];
                    VectorMA(v, BSP_MARK_MARKER_OFFSET, surf->plane.normal, clipPoints[0][j]);
                }
                BspAddMarkFragments(3, clipPoints,
                                    numPlanes, normals, dists,
                                    maxPoints, pointBuffer,
                                    maxFragments, fragmentBuffer,
                                    &returnedPoints, &returnedFragments, mins, maxs);
                if (returnedFragments == maxFragments) return returnedFragments;
            }
        } else if (*surfaces[i] == BSP_SF_TRIANGLES &&
                   r_marksOnTriangleMeshes != NULL && r_marksOnTriangleMeshes->integer) {
            bspSrfTriangles_t *surf = (bspSrfTriangles_t *)surfaces[i];
            for (k = 0; k < surf->numIndexes; k += 3) {
                for (j = 0; j < 3; j++) {
                    v = surf->verts[surf->indexes[k+j]].xyz;
                    VectorMA(v, BSP_MARK_MARKER_OFFSET, surf->verts[surf->indexes[k+j]].normal, clipPoints[0][j]);
                }
                BspAddMarkFragments(3, clipPoints,
                                    numPlanes, normals, dists,
                                    maxPoints, pointBuffer,
                                    maxFragments, fragmentBuffer,
                                    &returnedPoints, &returnedFragments, mins, maxs);
                if (returnedFragments == maxFragments) return returnedFragments;
            }
        }
    }
    return returnedFragments;
}
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
static qboolean R_inPVS(const vec3_t p1, const vec3_t p2) {
    bspMnode_t *leaf1;
    bspMnode_t *leaf2;
    const byte *vis;
    if (!s_bspWorld.loaded || s_bspWorld.nodes == NULL) {
        return qfalse;
    }
    leaf1 = MetalWorldPointInLeaf(p1);
    leaf2 = MetalWorldPointInLeaf(p2);
    if (leaf1 == NULL || leaf2 == NULL) {
        return qfalse;
    }
    if (leaf1->cluster < 0 || leaf2->cluster < 0 ||
        leaf1->cluster >= s_bspWorld.numClusters ||
        leaf2->cluster >= s_bspWorld.numClusters) {
        return qfalse;
    }
    vis = MetalWorldClusterPVS(leaf1->cluster);
    if (vis == NULL) {
        return qfalse;
    }
    return (vis[leaf2->cluster >> 3] & (1 << (leaf2->cluster & 7))) ? qtrue : qfalse;
}

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
    if (s_world.visibleDrawsValid && s_world.visibleDraws != NULL) {
        return s_world.visibleDraws;
    }
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
    outInfo->flags = texture->isLightmap ? Q3_METAL_TEXTURE_FLAG_LIGHTMAP : 0u;
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
    outInfo->deformWaveFunc  = (uint32_t)texture->deformWaveFunc;
    outInfo->deformWaveDiv   = texture->deformWaveDiv;
    outInfo->deformWaveBase  = texture->deformWaveBase;
    outInfo->deformWaveAmp   = texture->deformWaveAmp;
    outInfo->deformWavePhase = texture->deformWavePhase;
    outInfo->deformWaveFreq  = texture->deformWaveFreq;
    return 1;
}

const char *Q3MetalRenderer_GetTextureName(uint32_t textureHandle) {
    metalTexture_t *texture = FindTextureByHandle((qhandle_t)textureHandle);
    if (texture == NULL) {
        return NULL;
    }
    return texture->name;
}

/* Final-image postprocess tone curve — port of Q2's MetalPostprocess.
 *
 * Compute kernel applied in-place on the drawable after all renderer
 * encoders complete and before commandBuffer.present(). Two ops, in order:
 *     rgb = saturate(rgb * intensity);
 *     rgb = pow(rgb, gamma);
 *
 * Defaults tuned for OLED iPhone after the lightmap pre-shift was raised
 * to ×4 (r_mapOverBrightBits 3). intensity 1.5 lifts midtones a further
 * ~15% perceived without doubling up on the lightmap. gamma 0.95 = mild
 * brighten in the shoulder, leaves blacks alone.
 *
 * These three accessors are idempotent: ri.Cvar_Get registers on first
 * call, returns the existing cvar on subsequent calls. Range clamps are
 * defensive — keeps a user dialing extreme values from blowing out or
 * crushing the image entirely.
 *
 * NULL-guard for early call: Swift `drawFrame` can fire during the
 * `[Q3-BOOT] yielding 200ms for LoadingOverlay paint` window, BEFORE
 * GetRefAPI populates the static `ri` refimport_t (file-scope zero-init
 * until GetRefAPI runs). Calling `ri.Cvar_Get` then dereferences a NULL
 * function pointer → EXC_BAD_ACCESS at address 0x0. Returning the
 * cvar-default value when `ri.Cvar_Get == NULL` lets the postprocess
 * pipeline lazy-init harmlessly on the first real frame; once GetRefAPI
 * runs, subsequent calls register the cvar and read its live value. */
int Q3_PostprocessEnabled(void) {
    if (ri.Cvar_Get == NULL) return 1;
    cvar_t *cv = ri.Cvar_Get("r_postprocess", "1", CVAR_ARCHIVE);
    return cv ? cv->integer : 1;
}

float Q3_PostprocessIntensity(void) {
    if (ri.Cvar_Get == NULL) return 1.5f;
    cvar_t *cv = ri.Cvar_Get("r_postprocess_intensity", "1.5", CVAR_ARCHIVE);
    float v = cv ? cv->value : 1.5f;
    if (v < 0.5f) v = 0.5f;
    if (v > 3.0f) v = 3.0f;
    return v;
}

float Q3_PostprocessGamma(void) {
    if (ri.Cvar_Get == NULL) return 0.95f;
    cvar_t *cv = ri.Cvar_Get("r_postprocess_gamma", "0.95", CVAR_ARCHIVE);
    float v = cv ? cv->value : 0.95f;
    if (v < 0.5f) v = 0.5f;
    if (v > 2.5f) v = 2.5f;
    return v;
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
