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
    /* World-space vertex normal from drawVert_t.normal. Smooth-
     * interpolated to per-fragment normal so env-map reflections
     * track curved patches without faceting. Zero (e.g. on legacy
     * paths that don't fill it) lets the fragment shader fall back
     * to a dfdx/dfdy face normal of worldPos. */
    float normal[3];
    float color[4];
    /* Per-quad center for `deformVertexes autosprite` surfaces. xyz =
     * the 4-vert quad's center (mean of the 4 corner positions); w
     * is unused (alignment pad). Zero (length(xyz) ~= 0) means
     * "this vertex is not part of an autosprite quad" — vertex shader
     * skips the billboard transform. Baked at BSP load by
     * `BakeAutospriteCenters` in metal_renderer_stub.c. */
    float autospriteCenter[4];
    /* Per-quad long-axis unit vector for `deformVertexes autoSprite2`
     * surfaces only. xyz = unit direction of the quad's longest edge
     * pair (the axis the deform must preserve); w unused. Zero for
     * autosprite (mode 1) and non-autosprite verts. Baked alongside
     * autospriteCenter at BSP load — the bake routine identifies the
     * quad's two long edges by picking the pair-of-pairs split with
     * maximum total length, then takes the mean direction. */
    float autospriteLongAxis[4];
    /* Per-vertex CGEN_LIGHTING_DIFFUSE: ambient + directed * Lambert,
     * computed from the BSP lightgrid (SampleLightgrid) at this vertex's
     * world position with its drawVert_t normal. Mirrors ioq3
     * RB_CalcDiffuseColor / R_LightForPoint applied per-vertex at world
     * load. The world fragment shader's ComputeRGBGen helper picks this
     * up when stage rgbGen == 2. .xyz used; alignment-tail pad implicit. */
    float lightingDiffuse[3];
} Q3MetalWorldVertex;

typedef struct {
    float position[3];
    float texCoord[2];
    float color[4];
    /* World-space normal. MD3 emit paths decode the lat/long packed
     * normal and rotate by the entity axis (see tr_main.c's
     * RB_CalcEnvironmentTexCoords); non-MD3 paths (sprites, beams,
     * flares, synthetic overlays) leave this zero and q3_entity_fragment
     * falls back to a flat face normal via dfdx/dfdy of worldPos. */
    float normal[3];
} Q3MetalEntityVertex;

typedef struct {
    uint32_t firstVertex;
    uint32_t vertexCount;
    uint32_t textureHandle;
    /* 0=opaque, 1=alpha-modulated additive (src=src_alpha,dst=one),
     * 2=alpha (src-over), 3=filter/multiply, 4=subtract,
     * 5=full additive (src=one,dst=one). Propagated from the shader's
     * resolved blend so 2D stages like the loading-screen `levelShotDetail`
     * overlay multiply against the levelshot instead of washing it out as
     * plain alpha-over. */
    uint32_t blendMode;
} Q3MetalDrawCmd;

#define Q3_MAX_TCMODS 4

typedef struct {
    uint32_t type;        /* 0=none,1=scroll,2=wave-sin,3=rotate,4=scale,5=turb,6=stretch,7=transform,8=translate */
    float params[4];
} Q3TcMod;

typedef struct {
    uint32_t textureHandle;
    uint32_t blendMode;   /* 0=opaque,1=alpha-add,2=alpha,3=filter,4=subtract,5=full-add */
    uint32_t srcBlend;    /* Raw GL blend factor from q3_stage. */
    uint32_t dstBlend;    /* Raw GL blend factor from q3_stage. */
    uint32_t depthFunc;   /* 0=lessEqual, 1=equal */
    uint32_t tcGen;       /* 0=base, 1=environment, 2=vector */
    Q3TcMod tcMods[Q3_MAX_TCMODS];
    uint32_t tcModCount;
    /* tcGen vector ( x y z ) ( x y z ): two world-space basis vectors
     * used when tcGen == 2. Per-fragment UV is
     *   s = dot(worldPos, tcGenVec0.xyz)
     *   t = dot(worldPos, tcGenVec1.xyz)
     * Matches ioq3 RB_CalcTexCoords TCGEN_VECTOR (renderergl1/tr_shade.c)
     * and Quake3e's renderervk equivalent. tcMod chain is applied AFTER
     * tcGen per Q3 ordering. Stored as flat float[4] (xyz + 0 pad)
     * rather than a nested float[2][3] so Swift's bridge sees a
     * straightforward (Float, Float, Float, Float) tuple per vector
     * instead of nested ((Float,Float,Float),(Float,Float,Float)). */
    float tcGenVec0[4];
    float tcGenVec1[4];
    /* deformVertexes wave (shader-level, stamped onto every stage):
     *   spread = 1 / div
     *   off    = (xyz.x + xyz.y + xyz.z) * spread
     *   scale  = wave(func, base, amp, phase + off, freq, time)
     *   pos   += normal * scale
     * Mirrors ioq3 DeformVertex_Wave (tr_shade_calc.c).
     * deformWaveFunc 0 = no deform; 1=sin / 2=triangle / 3=square /
     * 4=sawtooth / 5=inverseSawtooth (matches `evalWave` index space). */
    uint32_t deformWaveFunc;
    float    deformWaveDiv;
    float    deformWaveBase;
    float    deformWaveAmp;
    float    deformWavePhase;
    float    deformWaveFreq;
    uint32_t deformMoveFunc;
    float    deformMoveVector[3];
    float    deformMoveBase;
    float    deformMoveAmp;
    float    deformMovePhase;
    float    deformMoveFreq;
    /* deformVertexes bulge <bulgeWidth> <bulgeHeight> <bulgeSpeed>.
     * Mirrors ioq3 RB_DeformTessGeometry DEFORM_BULGE. Math:
     *   phase  = st.s * bulgeWidth + time * bulgeSpeed
     *   scale  = sin(phase) * bulgeHeight
     *   pos   += normal * scale
     * Drives q3dm4's gothic_block / wallhead organic tube/vein
     * decorations. bulgeWidth = 0 means no bulge (MSL skips block). */
    float    deformBulgeWidth;
    float    deformBulgeHeight;
    float    deformBulgeSpeed;
    /* deformVertexes autosprite / autoSprite2 (shader-level).
     * World vertices carry baked per-quad centers/long axes and the
     * Metal vertex shader applies the camera-aligned transform to match
     * ioq3 RB_AutospriteDeform / RB_Autosprite2Deform.
     * 0 = none, 1 = autosprite, 2 = autoSprite2. */
    uint32_t autospriteMode;
    uint32_t rgbGen;      /* 0=identity,1=vertex,2=lightingDiffuse,3=wave,
                           * 7=identityLighting */
    uint32_t alphaGen;    /* 0=identity,1=vertex,3=wave */
    uint32_t alphaFunc;   /* 0=none, 1=GT0, 2=GE128, 3=LT128 */
    uint32_t cullMode;    /* 0=none,1=back,2=front */
    uint32_t useLightmap; /* 1 if stage sourced map from $lightmap */
    /* Stage explicitly declared `depthwrite` (or is opaque/no blendFunc).
     * ioq3 sets `depthMaskBits = 0` for any blendFunc'd stage UNLESS
     * `depthwrite` is explicit; Quake3e maps that into pipeline depth-write
     * enable. Without this bit, blended water/grate floors that author
     * `depthwrite` to occlude correctly leak background pixels (q3dm6
     * blocks17gwater style — chamber below visible through the surface).
     * 1 = write depth, 0 = depth-read-only. Swift selects depth-stencil
     * state per stage based on this. */
    uint32_t depthWrite;
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
    /* Per-stage constant color/alpha for rgbGen const / alphaGen const.
     * World and entity fragments use parser-local mode 4 for these.
     * Defaults should be (1,1,1,1) so non-const stages are no-ops. */
    float rgbConstColor[3];
    float alphaConst;
    /* Q3 shader script `map` vs `clampmap` directive at parse time:
     * 0 = repeat (map ... / animMap ... / default)
     * 1 = clamp to edge (clampmap ...)
     * Determines which MTLSamplerState the Swift draw loop binds for this
     * stage: worldSamplerState (.repeat) for 0, uiSamplerState
     * (.clampToEdge) for 1. Q3 reference uses GL_REPEAT for `map` and
     * GL_CLAMP_TO_EDGE for `clampmap`. Threading this per-stage replaces
     * the coarser all-entity-clamp hack at MetalView.swift:3267/3504/4330,
     * which killed the quad-damage breathing shell on viewmodels (tcGen
     * environment + map texture needs repeat to wrap seamlessly). */
    uint32_t wrapClampMode;
    /* PBR Phase 9: synthetic per-shader material-class constants.
     * Copied from q3_pbr_classify_shader(shaderName) at shader parse
     * time and consumed by q3_world_fragment when
     * r_pbr_world_class_match is enabled. */
    float pbrRoughness;
    float pbrMetallic;
} Q3MetalWorldStage;

#define Q3_METAL_MAX_STAGES 8

#define Q3_METAL_MAX_LIGHTS 32
#define Q3_METAL_TEXTURE_FLAG_LIGHTMAP 0x00000001u

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
    uint32_t firstIndex;   /* Offset into Q3MetalRenderer_GetWorldBatchIndices(). */
    uint32_t indexCount;
    uint32_t renderPass;   /* Same pass numbering as Swift worldRenderPass(). */
    uint32_t stageIndex;
    Q3MetalWorldDrawCmd draw; /* Representative draw; firstIndex/indexCount ignored by Swift batch path. */
} Q3MetalWorldBatchCmd;

typedef struct {
    uint32_t firstIndex;
    uint32_t indexCount;
    uint32_t textureHandle;
    uint32_t flags;
    /* refEntity_t.shader.rgba normalized to [0,1] floats. Read by the
     * MSL entity fragment for rgbGen=entity / oneMinusEntity and
     * alphaGen=entity / oneMinusEntity (modes 5 and 6). The
     * un-Lambert'd entity color — distinct from per-vertex `color`
     * which has Lambert diffuse already baked in by the C build loop. */
    float entityColor[4];
    float shaderTime;
    uint32_t fogIndex;
    /* Stage 0 tcMod chain copied from the texture's shader-map entry
     * (RegisterTexture → ShaderMap_GetTcMods at line ~1830). Without
     * this, customShader entity draws (quad shell `powerups/quadWeapon`,
     * regen, battlesuit) had no UV animation — chrome reflection from
     * tcGen environment landed but stayed static. Mirrors the per-stage
     * tcMod fields on Q3MetalWorldStage. Applied in q3_entity_vertex
     * MSL after tcGen UV computation, before vertex output. */
    uint32_t tcModCount;
    Q3TcMod tcMods[Q3_MAX_TCMODS];
} Q3MetalEntityDrawCmd;

enum {
    Q3_METAL_WORLD_DRAWFLAG_ADDITIVE = 1u << 0,
    Q3_METAL_WORLD_DRAWFLAG_NOCULL = 1u << 1,
    Q3_METAL_WORLD_DRAWFLAG_LIGHTMAP_MULTIPLY = 1u << 2,
    Q3_METAL_WORLD_DRAWFLAG_ALPHA = 1u << 3,
    Q3_METAL_WORLD_DRAWFLAG_FILTER = 1u << 4,
    Q3_METAL_WORLD_DRAWFLAG_SKY = 1u << 5,
    Q3_METAL_WORLD_DRAWFLAG_PORTAL = 1u << 6,
    /* GL_ONE/GL_ONE — full-intensity additive (ignores alpha). Kept
     * strictly distinct from DRAWFLAG_ADDITIVE (GL_SRC_ALPHA/GL_ONE,
     * alpha-modulated). Merging the two caused explosion shaders to
     * bleed full-screen yellow into the framebuffer. */
    Q3_METAL_WORLD_DRAWFLAG_ADDITIVE_FULL = 1u << 7,
    /* Shader uses `deformVertexes autosprite` — quads should be
     * camera-aligned billboards. Pipeline tag only at present;
     * the actual GPU transform is a follow-up commit. Useful now
     * for `[autosprite-audit]` logging + future regression detection. */
    Q3_METAL_WORLD_DRAWFLAG_AUTOSPRITE = 1u << 8,
    /* Shader uses `deformVertexes autoSprite2` — elongated billboard
     * (preserves long axis, only one axis camera-aligned). Used by
     * lamp wires, chains, jet exhaust, flame sprites. Pipeline tag
     * only; transform is the follow-up to AUTOSPRITE. */
    Q3_METAL_WORLD_DRAWFLAG_AUTOSPRITE2 = 1u << 9,
    /* This draw owns the post-stage fog overlay for its original BSP
     * surface. Split multi-stage draws still carry fogIndex on every
     * stage for per-pass attenuation, but only one draw should emit the
     * final fog pass. */
    Q3_METAL_WORLD_DRAWFLAG_FOG_OVERLAY = 1u << 10,
    Q3_METAL_WORLD_DRAWFLAG_FOG_ONLY = 1u << 11,
    /* Fast path for ordinary diffuse+lightmap world surfaces. The draw's
     * stage[0] samples the base texture and the fragment shader also samples
     * lightmapTexture at uv1, replacing the historical second
     * GL_DST_COLOR/GL_ZERO lightmap draw. Only set for simple opaque
     * base/lightmap pairs so multi-stage shader semantics stay intact. */
    Q3_METAL_WORLD_DRAWFLAG_COMBINED_LIGHTMAP = 1u << 12
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
    Q3_METAL_ENTITY_DRAWFLAG_TCGEN_ENV = 1u << 5,
    /* blendFunc GL_ZERO GL_ONE_MINUS_SRC_COLOR — inverse darken,
     * `out = dst * (1 - src)`; dark src darkens destination. Used by
     * bullet marks (gfx/damage/bullet_mrk), burn marks (burn_med_mrk),
     * wall hole marks (hole_lg_mrk), and markShadow (player foot blob).
     * bloodMark does NOT use this — it declares
     * `blendFunc GL_SRC_ALPHA GL_ONE_MINUS_SRC_ALPHA` and routes to
     * DRAWFLAG_ALPHA (pass 2). Previously fell through to ADDITIVE
     * which rendered decals near-invisibly. */
    Q3_METAL_ENTITY_DRAWFLAG_SUBTRACT = 1u << 6,
    /* Draw originated from RE_AddPolyToScene (bullet marks, shadow blobs,
     * blood splats, particle sprays). Swift side forces rgbGen=vertex
     * and alphaGen=vertex for these so the cgame-supplied polyVert_t
     * modulate color — which carries the CG_AddMarks fade — is respected
     * instead of falling to texel.a (which would pin alpha to 1.0 for
     * opaque decal textures). */
    Q3_METAL_ENTITY_DRAWFLAG_SCENE_POLY = 1u << 7,
    /* GL_ONE/GL_ONE — full-intensity additive for explosion cores and
     * similar high-energy shaders. Distinct from DRAWFLAG_ADDITIVE
     * (GL_SRC_ALPHA/GL_ONE) which modulates by source alpha. */
    Q3_METAL_ENTITY_DRAWFLAG_ADDITIVE_FULL = 1u << 8,
    /* Implicit alphaFunc GT0 for the draw: discards texels where
     * texel.a < 0.004. Applied to RT_SPRITE / billboard emits whose
     * shader didn't declare alphaFunc but whose blendMode
     * (additive / additive-full) ignores alpha at the blend stage —
     * without a discard the dark-but-non-zero JPEG-compressed
     * borders of rlboom/plasma/muzzle-flash sprites contribute fully
     * to the framebuffer, producing the hard rectangular explosion
     * quad visible in close-range combat. */
    Q3_METAL_ENTITY_DRAWFLAG_ATEST_GT0 = 1u << 9,
    /* Q3 `clampmap` directive on the stage that emitted this entity draw.
     * Set: Swift draw loop binds uiSamplerState (.clampToEdge). Unset:
     * binds worldSamplerState (.repeat). Per-stage routing replaces the
     * coarse all-entity-clamp at MetalView.swift:3267/3504/4330 which
     * killed the quad-damage breathing shell on viewmodels (tcGen
     * environment + `map` directive needs repeat to wrap seamlessly). */
    Q3_METAL_ENTITY_DRAWFLAG_CLAMPMAP = 1u << 10
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
    float shaderTime;
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
    uint32_t flags; /* Q3_METAL_TEXTURE_FLAG_* */
    /* Stage 0 tcMod chain for this texture's resolved shader.
     * Entity pipeline reads this to apply scroll/rotate on the quad
     * shell / regen / battlesuit shaders — matches ioquake3's
     * RB_CalcScrollTexCoords + RB_CalcRotateTexCoords order. */
    uint32_t tcModCount;
    Q3TcMod tcMods[Q3_MAX_TCMODS];
    /* Stage 0 alphaFunc: 0=none, 1=GT0, 2=GE128, 3=LT128. Entity
     * fragment translates to an MSL discard so alpha-tested textures
     * (grates, chain-link, vegetation billboards) render with holes
     * instead of solid silhouettes. Matches ioquake3's GLS_ATEST_*. */
    uint32_t alphaFunc;
    /* Stage 0 rgbGen: 0=identity, 1=vertex, 2=lightingDiffuse, 3=wave.
     * Entity pipeline consults this so chrome shells (rgbGen identity)
     * bypass the per-vertex Lambert color and render at full
     * brightness — upstream's CGEN_IDENTITY semantics. */
    uint32_t rgbGen;
    /* Stage 0 alphaGen: 0=identity (force alpha 1.0), 1=vertex, 3=wave.
     * Entity fragment overrides in.color.a with 1.0 for identity so
     * alpha-faded entityColor doesn't leak into stages that want
     * opaque output — matches upstream AGEN_IDENTITY. */
    uint32_t alphaGen;
    /* Stage 0 rgbGen wave parameters (func, base, amp, phase, freq).
     * Only meaningful when rgbGen == 3. func: 1=sin, 2=triangle,
     * 3=square, 4=sawtooth, 5=inverse_sawtooth. */
    uint32_t rgbWaveFunc;
    float rgbWaveBase;
    float rgbWaveAmp;
    float rgbWavePhase;
    float rgbWaveFreq;
    /* Stage 0 alphaGen wave parameters — parallels rgbWave*. */
    uint32_t alphaWaveFunc;
    float alphaWaveBase;
    float alphaWaveAmp;
    float alphaWavePhase;
    float alphaWaveFreq;
    /* Stage 0 rgbGen const tint — only read when rgbGen == 4
     * (CGEN_CONST). Defaults to (1,1,1) which is a no-op multiply. */
    float rgbConstColor[3];
    /* Stage 0 alphaGen const — only read when alphaGen == 4
     * (AGEN_CONST). Default 1.0 (no-op). */
    float alphaConst;
    /* deformVertexes wave parameters (shader-level, stamped on every
     * stage by the parser). Drives the q3_entity_vertex normal-axis
     * offset that puts the powerups/quadWeapon shell OUTSIDE the gun
     * silhouette (halo) instead of inside it. Mirrors id-quake2
     * DeformVertex_Wave (tr_shade_calc.c) and the existing world
     * pipeline deform block. func == 0 → no deform (branch skipped).
     * For powerups/quadWeapon canonical content: func=1 (sin) div=100
     * base=0.5 amp=0 phase=0 freq=0 → constant +0.5 unit halo.
     * For powerups/quad (player): same shape with base=3.0 → +3 unit. */
    uint32_t deformWaveFunc;
    float deformWaveDiv;
    float deformWaveBase;
    float deformWaveAmp;
    float deformWavePhase;
    float deformWaveFreq;
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
uint32_t Q3MetalRenderer_BuildWorldBatches(uint32_t passMask);
const Q3MetalWorldBatchCmd *Q3MetalRenderer_GetWorldBatches(void);
uint32_t Q3MetalRenderer_GetWorldBatchCount(void);
const uint32_t *Q3MetalRenderer_GetWorldBatchIndices(void);
uint32_t Q3MetalRenderer_GetWorldBatchIndexCount(void);
/* Per-world fog LUT. fogIndex values on Q3MetalWorldDrawCmd are indices
 * into this array. Returns 0/NULL if the loaded map has no fog volumes.
 * Each entry's color is linear RGB and distance is world units. */
typedef struct {
    float color[3];
    float distance;
    float tcScale;
    uint32_t hasSurface;
    float surface[4];
    uint32_t hasBounds;
    float boundsMin[3];
    float boundsMax[3];
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
const char *Q3MetalRenderer_GetTextureName(uint32_t textureHandle);

#ifdef __cplusplus
}
#endif

#endif
