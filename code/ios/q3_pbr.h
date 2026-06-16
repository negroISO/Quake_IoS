/* q3_pbr.h — RTX Remix-compatible PBR material table.
 *
 * Phase 1 (raster path): at texture register time we hash the just-loaded
 * pixels with XXH3_64bits and look up the result in a JSON-loaded
 * material table extracted from a Quake III Arena RTX Remix mod
 * (scripts/pbr_extract_hash_table.py). When a hit lands, we attach a
 * `q3_pbr_material_t` to the metalTexture_t so the Swift renderer can
 * lazy-load the DDS PBR maps and bind them to the world fragment shader.
 *
 * No raytracing in Phase 1 — this is pure PBR rasterization. The same
 * table can later drive RT material lookup in Phase 2/3 unchanged.
 *
 * Hash function:
 *   xxh3_64( raw_pixel_bytes_of_mip_0_in_BGRA_layout )
 * This matches the algorithm used by NVIDIA's dxvk-remix. If our hash
 * doesn't reproduce theirs exactly, q3_pbr_lookup() just returns NULL
 * — Phase 1 falls back to the existing Lambert path, no regression. */

#ifndef Q3_PBR_H
#define Q3_PBR_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Lightweight Swift-facing view of a PBR material's path slots. The
 * full q3_pbr_material_t (below) carries internal book-keeping; this
 * mirror is what the Swift renderer reads via
 * Q3MetalRenderer_GetPBRMaterial(). Strings remain valid for the
 * process lifetime. */
typedef struct {
    const char *albedo;
    const char *normal;
    const char *roughness;
    const char *metallic;
    const char *emissive;
    const char *height;
    float       emissive_intensity;
    /* Emissive color tint (linear RGB). Multiplied into the sampled
     * emissive DDS texel. 1,1,1 is "no tint". has_emissive_color==0 means
     * Swift should treat it as (1,1,1). */
    float       emissive_color_r;
    float       emissive_color_g;
    float       emissive_color_b;
    int         has_emissive_color;
    float       roughness_constant;   /* <0 = unset */
    float       metallic_constant;    /* <0 = unset */
    /* RTX Remix sprite-sheet atlas (animMap material). When sprite_cols
     * or sprite_rows > 0, the albedo (+ companion normal/roughness/metallic/
     * emissive) DDS is a 2D grid of cols×rows frames. Shader sub-samples
     * frame index = floor(time*fps) % (cols*rows), col = idx%cols,
     * row = idx/cols. (0,0) = static. */
    int         sprite_cols;
    int         sprite_rows;
    float       sprite_fps;
} Q3PBRMaterialPaths;

/* A single PBR material entry. Slot pointers are owned by the table and
 * remain valid for the lifetime of the process. Old table allocations are
 * intentionally preserved across reloads so existing metalTexture_t
 * pbrMaterial pointers survive vid_restart. NULL = slot not present in
 * the mod (use a sensible default in the shader). */
typedef struct q3_pbr_material_s {
    /* The 64-bit Remix content hash this entry was keyed by. */
    uint64_t hash;
    /* Relative paths under the mod root. NULL when the mod didn't ship
     * a texture for this slot. Paths are absolute on disk after
     * q3_pbr_table_resolve_paths(). */
    const char *albedo;
    const char *normal;
    const char *roughness;
    const char *metallic;
    const char *emissive;
    const char *height;
    /* Optional emissive shading constants (matches the .usda inputs). */
    float       emissive_intensity;   /* 0 when not set */
    float       emissive_color_r;
    float       emissive_color_g;
    float       emissive_color_b;
    int         has_emissive_color;   /* 1 if emissive_color_* are set */
    float       roughness_constant;   /* <0 when not set */
    float       metallic_constant;    /* <0 when not set */
    /* Sprite-sheet metadata (remixConstants.sprite_sheet_cols/rows/fps).
     * 0 = static texture (no atlas). See Q3PBRMaterialPaths above. */
    int         sprite_cols;
    int         sprite_rows;
    float       sprite_fps;
} q3_pbr_material_t;

/* One-shot init. Loads the JSON table produced by
 * scripts/pbr_extract_hash_table.py and resolves all asset paths to
 * absolute paths so the Swift loader can fopen them directly.
 *
 *   jsonPath  — absolute path to q3rtx_v07_materials.json (or equivalent).
 *   assetRoot — absolute path to the directory the JSON paths are relative
 *               to (typically <mod>/rtx-remix/mods/q3rtx_v07/).
 *
 * Returns the number of materials loaded, or 0 on any failure. Safe to
 * call multiple times — subsequent calls install a fresh active table while
 * intentionally preserving old allocations for process-lifetime pointer
 * stability across vid_restart. */
int q3_pbr_table_load(const char *jsonPath, const char *assetRoot);

/* True if the table has been loaded with at least one material. */
int q3_pbr_table_ready(void);

/* Hash an RGBA pixel buffer (mip 0) as XXH3_64bits over the BGRA layout
 * — RTX Remix's hash key. width/height in pixels. rgba points to
 * width*height*4 bytes ordered R,G,B,A. Returns the 64-bit hash. */
uint64_t q3_pbr_hash_rgba(const unsigned char *rgba, int width, int height);

/* Look up a material by content hash. Returns NULL if not present.
 * The returned pointer remains valid for the lifetime of the process. */
const q3_pbr_material_t *q3_pbr_lookup(uint64_t hash);

/* Phase 1 Path A: look up a material by descriptive name (e.g.
 * "rocket", "shotgun") extracted from the .dds asset filename. The
 * Q3 shader name is normalized at lookup time — basename, lowercased,
 * extension stripped, common path prefixes (`models/ammo/`,
 * `models/weapons2/`, `gfx/effects/`) tried.
 *
 * Implemented as a linear scan over the small (~20 entry)
 * `materials_by_name` table from the JSON. Cost is negligible vs the
 * Lambert lookup the renderer would do otherwise.
 *
 * Returns NULL on miss. */
const q3_pbr_material_t *q3_pbr_lookup_by_name(const char *q3_shader_name);

/* Count of name-indexed materials loaded — used for boot-time stats. */
int q3_pbr_named_count(void);

/* Logging hook — q3_pbr.c is a leaf .c file with no access to
 * Com_Printf / NSLog. metal_renderer_stub.c wires a callback at boot
 * so our boot messages reach q3_diag.log alongside the rest of the
 * telemetry. printf-style; va_args resolved by the impl. */
typedef void (*q3_pbr_log_fn)(const char *fmt, ...);
void q3_pbr_set_log(q3_pbr_log_fn fn);


/* PBR Phase 9 — world shader-name material classifier.
 * Values are synthetic roughness/metallic constants keyed by Q3 shader
 * path prefixes. World-only; entity/material JSON path is unchanged. */
typedef enum {
    Q3_PBR_MAT_DEFAULT = 0,
    Q3_PBR_MAT_STONE_ROUGH,
    Q3_PBR_MAT_WOOD,
    Q3_PBR_MAT_METAL_TRIM,
    Q3_PBR_MAT_METAL_PLAQUE,
    Q3_PBR_MAT_METAL_BRIDGE,
    Q3_PBR_MAT_LIGHT_FIXTURE,
    Q3_PBR_MAT_MAX
} q3_pbr_world_mat_t;

q3_pbr_world_mat_t q3_pbr_classify_shader(const char *name);
void q3_pbr_class_params(q3_pbr_world_mat_t mat, float *out_rough, float *out_metal);
void q3_pbr_log_classification(const char *name, q3_pbr_world_mat_t mat);

/* Cvar accessor — non-zero when r_pbrMaterials is on. The renderer
 * gates the PBR shader path on this; q3_pbr_table_load runs
 * regardless so we can audit hash matches independent of the
 * shader path. */
int q3_pbr_enabled(void);
int Q3_PBRBakedLightmaps(void);
int Q3_PBRSunShadows(void);
int Q3_PBRSSREnabled(void);
float Q3_PBRShadowPCFRadius(void);
float Q3_PBRNormalScale(void);

/* Stats for debugging — emitted in NSLog at boot. */
typedef struct {
    int materials_total;       /* total entries in JSON */
    int hashes_seen;           /* distinct hashes we've hashed at register time */
    int hashes_matched;        /* of hashes_seen, how many had a table entry */
    int dds_load_requested;    /* PBR texture loads kicked off (Swift side) */
    int dds_load_failed;       /* loads that failed (missing file, decode err) */
} q3_pbr_stats_t;

const q3_pbr_stats_t *q3_pbr_stats(void);
void q3_pbr_stats_inc_hashes_seen(void);
void q3_pbr_stats_inc_hashes_matched(void);
void q3_pbr_stats_inc_dds_load_requested(void);
void q3_pbr_stats_inc_dds_load_failed(void);

#ifdef __cplusplus
}
#endif

#endif /* Q3_PBR_H */
