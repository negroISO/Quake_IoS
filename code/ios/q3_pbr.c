/* q3_pbr.c — implementation. See q3_pbr.h for the architecture brief.
 *
 * JSON parsing is intentionally hand-rolled (no third-party dep) — the
 * schema is fixed and trivial (flat map of "<16-hex>" -> small object
 * with 6 string fields and 4 numeric fields). We parse it with a tiny
 * line-based state machine to keep the binary lean. ~250 LOC. */

#include "q3_pbr.h"

#include <ctype.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

/* Vendor xxhash single-header. Define XXH_STATIC_LINKING_ONLY +
 * XXH_IMPLEMENTATION so it compiles into this TU only. */
#define XXH_INLINE_ALL
#define XXH_IMPLEMENTATION
#include "vendor/xxhash.h"

/* Trivial djb2 string hash used only for our internal open-addressing
 * lookup of 64-bit hash → table index. Not user-visible. */
static unsigned long djb2_u64(uint64_t v) {
    unsigned long h = 5381;
    for (int i = 0; i < 8; ++i) {
        h = ((h << 5) + h) ^ ((v >> (i * 8)) & 0xffu);
    }
    return h;
}

/* The table itself. Allocated once on first load, freed + replaced on
 * subsequent loads. Two parallel arrays — `materials` keeps the public
 * material data, `hashTable` is a simple open-addressed hash table that
 * maps hash → index in materials[]. We never delete entries so linear
 * probe with a tombstone-free table is fine. */
static q3_pbr_material_t *g_materials = NULL;
static int g_materials_count = 0;
static int g_materials_cap = 0;
/* hash table: power-of-two size, store index+1 (0 = empty slot). */
static int *g_hash_table = NULL;
static int g_hash_table_mask = 0;

/* Buffer arena for the const-string slots inside materials. We
 * concatenate all path strings into one growing buffer and store
 * indices instead of pointers, then rewrite to pointers post-load.
 * Simpler than per-string malloc and reduces fragmentation. */
static char *g_str_arena = NULL;
static size_t g_str_arena_used = 0;
static size_t g_str_arena_cap = 0;

static q3_pbr_stats_t g_stats = {0};

/* Optional log callback. NULL = stderr (Sim/Console.app only). */
static q3_pbr_log_fn g_log = NULL;

void q3_pbr_set_log(q3_pbr_log_fn fn) {
    g_log = fn;
}

static void plog(const char *fmt, ...) {
    char buf[1024];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    if (g_log != NULL) {
        g_log("%s", buf);
    } else {
        fputs(buf, stderr);
    }
}

/* extern cvar accessor — defined elsewhere (ref_mtl_stub or metal_renderer_stub
 * stays the source of truth, just like every other r_* gate in this port).
 * On Q3 we route it through cvar_t* directly. */
extern int q3_pbr_cvar_enabled(void);  /* defined in metal_renderer_stub.c */

int q3_pbr_enabled(void) {
    return q3_pbr_cvar_enabled();
}

const q3_pbr_stats_t *q3_pbr_stats(void) {
    g_stats.materials_total = g_materials_count;
    return &g_stats;
}

void q3_pbr_stats_inc_hashes_seen(void)     { g_stats.hashes_seen++; }
void q3_pbr_stats_inc_hashes_matched(void)  { g_stats.hashes_matched++; }
void q3_pbr_stats_inc_dds_load_requested(void) { g_stats.dds_load_requested++; }
void q3_pbr_stats_inc_dds_load_failed(void)    { g_stats.dds_load_failed++; }

/* --- PBR Phase 9 world material classifier ----------------------- */

static int q3_pbr_prefix_match(const char *name, const char *prefix) {
    size_t i;
    if (name == NULL || prefix == NULL) return 0;
    for (i = 0; prefix[i] != '\0'; ++i) {
        char a = name[i];
        char b = prefix[i];
        if (a >= 'A' && a <= 'Z') a = (char)(a - 'A' + 'a');
        if (b >= 'A' && b <= 'Z') b = (char)(b - 'A' + 'a');
        if (a != b) return 0;
    }
    return 1;
}

static const struct {
    const char *prefix;
    q3_pbr_world_mat_t mat;
} kQ3PBRClassRules[] = {
    { "textures/gothic_floor/metalbridge",        Q3_PBR_MAT_METAL_BRIDGE },
    { "textures/gothic_floor/blocks",             Q3_PBR_MAT_STONE_ROUGH },
    { "textures/gothic_floor/largerblock",        Q3_PBR_MAT_STONE_ROUGH },
    { "textures/gothic_floor/xstair",             Q3_PBR_MAT_STONE_ROUGH },
    { "textures/gothic_floor/xstepborder",        Q3_PBR_MAT_STONE_ROUGH },
    { "textures/gothic_floor/center2trn",         Q3_PBR_MAT_STONE_ROUGH },
    { "textures/gothic_ceiling/woodceiling",      Q3_PBR_MAT_WOOD },
    { "textures/gothic_door/skullarch",           Q3_PBR_MAT_METAL_PLAQUE },
    { "textures/gothic_door/skull_door",          Q3_PBR_MAT_METAL_PLAQUE },
    { "textures/gothic_door/skull",               Q3_PBR_MAT_METAL_PLAQUE },
    { "textures/gothic_door/km_arena1arch",       Q3_PBR_MAT_METAL_TRIM },
    { "textures/gothic_door/km_arena1column",     Q3_PBR_MAT_METAL_PLAQUE },
    { "textures/gothic_door/xian_tourneyarch",    Q3_PBR_MAT_METAL_TRIM },
    { "textures/gothic_trim/baseboard",           Q3_PBR_MAT_METAL_TRIM },
    { "textures/gothic_trim/km_arena1tower",      Q3_PBR_MAT_METAL_TRIM },
    { "textures/gothic_block/killblock",          Q3_PBR_MAT_METAL_PLAQUE },
    { "textures/gothic_block/demon_block",        Q3_PBR_MAT_STONE_ROUGH },
    { "textures/gothic_block/blocks",             Q3_PBR_MAT_STONE_ROUGH },
    { "textures/gothic_light/pentagram_light",    Q3_PBR_MAT_LIGHT_FIXTURE },
    { NULL, Q3_PBR_MAT_DEFAULT }
};

static const struct {
    float roughness;
    float metallic;
} kQ3PBRClassParams[Q3_PBR_MAT_MAX] = {
    { 0.55f, 0.30f },
    { 0.85f, 0.02f },
    { 0.75f, 0.00f },
    { 0.30f, 0.85f },
    { 0.25f, 0.90f },
    { 0.40f, 0.70f },
    { 0.50f, 0.30f }
};

q3_pbr_world_mat_t q3_pbr_classify_shader(const char *name) {
    int i;
    if (name == NULL || name[0] == '\0') return Q3_PBR_MAT_DEFAULT;
    for (i = 0; kQ3PBRClassRules[i].prefix != NULL; ++i) {
        if (q3_pbr_prefix_match(name, kQ3PBRClassRules[i].prefix)) {
            return kQ3PBRClassRules[i].mat;
        }
    }
    return Q3_PBR_MAT_DEFAULT;
}

void q3_pbr_class_params(q3_pbr_world_mat_t mat, float *out_rough, float *out_metal) {
    if (mat < Q3_PBR_MAT_DEFAULT || mat >= Q3_PBR_MAT_MAX) {
        mat = Q3_PBR_MAT_DEFAULT;
    }
    if (out_rough) *out_rough = kQ3PBRClassParams[mat].roughness;
    if (out_metal) *out_metal = kQ3PBRClassParams[mat].metallic;
}

void q3_pbr_log_classification(const char *name, q3_pbr_world_mat_t mat) {
    static char seen[64][128];
    static int seen_count = 0;
    float rough = 0.55f, metal = 0.30f;
    int i;
    if (name == NULL || name[0] == '\0' || mat == Q3_PBR_MAT_DEFAULT) return;
    for (i = 0; i < seen_count; ++i) {
        if (strcmp(seen[i], name) == 0) return;
    }
    if (seen_count < (int)(sizeof(seen) / sizeof(seen[0]))) {
        snprintf(seen[seen_count], sizeof(seen[seen_count]), "%s", name);
        seen_count++;
    }
    q3_pbr_class_params(mat, &rough, &metal);
    plog("[Q3-PBR-CLASS] '%s' -> class=%d rough=%.2f metal=%.2f\n",
         name, (int)mat, rough, metal);
}

/* --- xxhash bridge ------------------------------------------------- */

uint64_t q3_pbr_hash_rgba(const unsigned char *rgba, int width, int height) {
    if (rgba == NULL || width <= 0 || height <= 0) return 0;
    size_t pixels = (size_t)width * (size_t)height;
    /* Swap to BGRA into a small stack chunk + feed XXH3 incrementally so
     * we don't have to allocate width*height*4 bytes just to swap. */
    XXH3_state_t state;
    XXH3_64bits_reset(&state);

    static const size_t CHUNK = 4096;  /* 1024 pixels per chunk */
    unsigned char buf[4096];

    size_t remaining = pixels;
    const unsigned char *p = rgba;
    while (remaining > 0) {
        size_t take = remaining > 1024 ? 1024 : remaining;
        for (size_t i = 0; i < take; ++i) {
            buf[i * 4 + 0] = p[i * 4 + 2]; /* B */
            buf[i * 4 + 1] = p[i * 4 + 1]; /* G */
            buf[i * 4 + 2] = p[i * 4 + 0]; /* R */
            buf[i * 4 + 3] = p[i * 4 + 3]; /* A */
        }
        XXH3_64bits_update(&state, buf, take * 4);
        p += take * 4;
        remaining -= take;
        (void)CHUNK;
    }
    return XXH3_64bits_digest(&state);
}

const q3_pbr_material_t *q3_pbr_lookup(uint64_t hash) {
    if (g_hash_table == NULL || g_materials_count == 0) return NULL;
    unsigned long h = djb2_u64(hash);
    int mask = g_hash_table_mask;
    for (int i = 0; i < mask + 1; ++i) {
        int slot = (int)((h + (unsigned long)i) & (unsigned long)mask);
        int v = g_hash_table[slot];
        if (v == 0) return NULL;
        int idx = v - 1;
        if (g_materials[idx].hash == hash) {
            return &g_materials[idx];
        }
    }
    return NULL;
}

/* Forward decl — defined in the Path A section below. */
static int g_named_count;

int q3_pbr_table_ready(void) {
    /* Path A bundle JSON ships 21 name-keyed materials and 0 hex-keyed
     * (the hex block is stripped to keep the bundle small). The texture
     * register hook gates the name-match fallback behind this function,
     * so we MUST report ready when either pool is populated. */
    return g_materials_count > 0 || g_named_count > 0;
}

/* --- Name-indexed lookup (Path A, hash dead-end workaround) ------- */

/* Forward declarations of helpers defined further down the file. */
static const char *find_key(const char *p, const char *end, const char *key);
static char *json_str_dup(const char *v, const char *end);
static int json_num(const char *v, const char *end, double *out);
static const char *resolve_path(const char *root, const char *rel);

/* Parallel array: distinct entries keyed by descriptive stem ("rocket",
 * "shotgun", …). Backed by the same string arena as g_materials. */
typedef struct {
    char name[64];                       /* lowercase, NUL-terminated */
    q3_pbr_material_t mat;               /* same fields as hash-keyed */
} q3_pbr_named_t;

static q3_pbr_named_t *g_named = NULL;
static int g_named_count = 0;
static int g_named_cap = 0;

int q3_pbr_named_count(void) {
    return g_named_count;
}

/* Normalize a Q3 shader path into a lookup key. Examples:
 *   "models/ammo/rocket/rocket"   →  "rocket"
 *   "models/weapons2/bfg/bfg.tga" →  "bfg"
 *   "gfx/effects/blackhole.jpg"   →  "blackhole"
 *   "ROCKET"                      →  "rocket"
 * Strategy: take last '/' component, strip extension, lowercase. The
 * extracted descriptive stems in the JSON are stored lowercase. */
static void q3_pbr_normalize_name(const char *in, char *out, size_t outSize) {
    if (out == NULL || outSize == 0) return;
    out[0] = '\0';
    if (in == NULL) return;

    /* Last path component */
    const char *base = in;
    for (const char *p = in; *p; ++p) {
        if (*p == '/' || *p == '\\') base = p + 1;
    }
    /* Copy until '.' or end */
    size_t i = 0;
    while (base[i] && base[i] != '.' && i + 1 < outSize) {
        char c = base[i];
        if (c >= 'A' && c <= 'Z') c = (char)(c - 'A' + 'a');
        out[i] = c;
        ++i;
    }
    out[i] = '\0';
}


/* Normalize a Q3 shader path into a full lookup key: lowercase, strip
 * image extension, preserve directories. Example:
 *   "textures/base_wall/foo.tga" -> "textures/base_wall/foo". */
static void q3_pbr_normalize_full_name(const char *in, char *out, size_t outSize) {
    if (out == NULL || outSize == 0) return;
    out[0] = '\0';
    if (in == NULL) return;

    size_t i = 0;
    for (; in[i] && i + 1 < outSize; ++i) {
        char c = in[i];
        if (c == '\\') c = '/';
        if (c >= 'A' && c <= 'Z') c = (char)(c - 'A' + 'a');
        out[i] = c;
    }
    out[i] = '\0';

    /* Strip common image extension from the full path. */
    char *slash = strrchr(out, '/');
    char *dot = strrchr(out, '.');
    if (dot && (!slash || dot > slash)) {
        if (!strcmp(dot, ".tga") || !strcmp(dot, ".jpg") ||
            !strcmp(dot, ".jpeg") || !strcmp(dot, ".png") ||
            !strcmp(dot, ".dds")) {
            *dot = '\0';
        }
    }
}

/* Q3 ships weapon textures with stems that don't match the descriptive
 * names extracted from the RTX Remix mod USDA. Map them. Left = the
 * normalized Q3 stem from load_pic_texture_with_mipmap; right = the stem
 * that appears in materials_by_name (from pbr_extract_hash_table.py).
 *
 * Observed Q3 stems from q3_diag.log:
 *   models/weapons2/machinegun/machinegun    → "machinegun"   ✓ direct
 *   models/weapons2/plasma/plasma            → "plasma"        ✓ direct
 *   models/weapons2/rocketl/rocketl          → "rocketl"
 *   models/weapons2/lightning/lightning2     → "lightning2"
 *   models/weapons2/shotgun/f_shotgun        → "f_shotgun"
 *   models/ammo/rocket/rocketfn              → "rocketfn"
 *   models/weapons2/rocketl/f_rocketl        → "f_rocketl"
 *   models/weapons2/plasma/f_plasma          → "f_plasma"
 *   models/ammo/plasma/plasma_a              → "plasma_a"
 *
 * The "f_" prefix on weapon flash textures shares the projectile body
 * appearance — alias to the same PBR set. */
static const struct {
    const char *q3_stem;
    const char *mod_stem;
} kPbrAliases[] = {
    { "rocketl",        "rocket"     },
    { "rocketl2",       "rocket"     },
    { "f_rocketl",      "rocket"     },
    { "rocketfn",       "rocket"     },
    { "f_shotgun",      "shotgun"    },
    /* NOTE: the mod's USDA mis-spells this as "lighting" (no n). The
     * extracted bundle JSON preserves the typo as the entry key, so
     * we alias both Q3 lightning stems to it verbatim. */
    { "lightning2",     "lighting"   },
    { "trail2",         "lighting"   },
    { "f_plasma",       "plasma"     },
    { "plasma_glass",   "plasma"     },
    { "plasma_glo",     "plasma"     },
    { "plasma_a",       "plasma"     },
    { "railgun",        "rail"       },
    /* Vanilla Q3 railgun MD3 references numbered texture variants
     * (railgun1..4.tga, see pak0). The plain "railgun" stem above
     * never fires because no MD3 actually uses it — these do. */
    { "railgun1",       "rail"       },
    { "railgun2",       "rail"       },
    { "railgun3",       "rail"       },
    { "railgun4",       "rail"       },
    { "f_railgun2",     "rail"       },
    /* Vanilla grenade launcher MD3 references "grenadel" (the
     * pak0 directory is models/weapons2/grenadel/, not grenadelauncher). */
    { "grenadel",       "grenade"    },
    { "grenadelauncher","grenade"    },
    /* Vanilla BFG MD3 references bfg.TGA + bfg_e.TGA (emissive
     * companion). Bind both to the same PBR albedo. */
    { "bfg_e",          "bfg"        },
    { "f_bfg",          "bfg"        },
    { NULL, NULL }
};

const q3_pbr_material_t *q3_pbr_lookup_by_name(const char *q3_shader_name) {
    if (g_named == NULL || g_named_count == 0 || q3_shader_name == NULL) {
        return NULL;
    }
    char key[64];
    char fullKey[128];
    q3_pbr_normalize_name(q3_shader_name, key, sizeof(key));
    q3_pbr_normalize_full_name(q3_shader_name, fullKey, sizeof(fullKey));
    if (key[0] == '\0' && fullKey[0] == '\0') return NULL;

    /* Full shader-path match first. The current whole-game PBR bundle is
     * keyed by full Q3 shader names (textures/base_wall/foo), not just
     * basename stems. The older 21-entry weapon bundle used basename stems,
     * so keep that fallback below. */
    for (int i = 0; i < g_named_count; ++i) {
        char namedFull[128];
        q3_pbr_normalize_full_name(g_named[i].name, namedFull, sizeof(namedFull));
        if (fullKey[0] != '\0' && strcmp(namedFull, fullKey) == 0) {
            return &g_named[i].mat;
        }
    }

    /* Basename/stem match for legacy small bundles and model aliases. */
    for (int i = 0; i < g_named_count; ++i) {
        char namedStem[64];
        q3_pbr_normalize_name(g_named[i].name, namedStem, sizeof(namedStem));
        if (key[0] != '\0' && strcmp(namedStem, key) == 0) {
            return &g_named[i].mat;
        }
    }

    /* Alias match — Q3 stem → mod stem. */
    for (int a = 0; kPbrAliases[a].q3_stem != NULL; ++a) {
        if (strcmp(key, kPbrAliases[a].q3_stem) == 0) {
            const char *mod_stem = kPbrAliases[a].mod_stem;
            for (int i = 0; i < g_named_count; ++i) {
                if (strcmp(g_named[i].name, mod_stem) == 0) {
                    return &g_named[i].mat;
                }
            }
            return NULL;  /* alias known but mod doesn't ship this material */
        }
    }
    return NULL;
}

/* JSON loader for the `materials_by_name` block. Called near end of
 * q3_pbr_table_load after `materials` is parsed. Reads each named
 * stem and stages it into g_named. Strings are duplicated into the
 * existing string arena. */
static void load_named_materials_from_json(const char *json, const char *json_end,
                                           const char *assetRoot) {
    /* Find the "materials_by_name" object. */
    const char *byNamePtr = find_key(json, json_end, "materials_by_name");
    if (!byNamePtr) return;
    while (byNamePtr < json_end && *byNamePtr != '{') byNamePtr++;
    if (byNamePtr >= json_end) return;
    byNamePtr++;

    /* Walk entries: "<key>": { ... }, repeat. */
    const char *p = byNamePtr;
    while (p < json_end) {
        /* Skip whitespace + commas. */
        while (p < json_end && (*p == ' ' || *p == '\t' || *p == '\n' ||
                                *p == '\r' || *p == ',')) p++;
        if (p >= json_end || *p == '}') break;
        if (*p != '"') { p++; continue; }
        p++;  /* skip opening quote */
        const char *keyEnd = memchr(p, '"', (size_t)(json_end - p));
        if (!keyEnd) break;
        size_t keyLen = (size_t)(keyEnd - p);
        char key[64];
        if (keyLen >= sizeof(key)) {
            /* Truncate over-long keys; the descriptive stems are
             * always short in practice. */
            keyLen = sizeof(key) - 1;
        }
        memcpy(key, p, keyLen);
        key[keyLen] = '\0';

        /* Locate the object body. */
        const char *body = keyEnd + 1;
        while (body < json_end && *body != '{') body++;
        if (body >= json_end) break;
        body++;
        const char *body_end = body;
        int depth = 1;
        while (body_end < json_end && depth > 0) {
            if (*body_end == '{') depth++;
            else if (*body_end == '}') depth--;
            body_end++;
        }
        if (depth != 0) break;

        /* Grow g_named array as needed. */
        if (g_named_count >= g_named_cap) {
            int nc = g_named_cap ? g_named_cap * 2 : 64;
            q3_pbr_named_t *nn = (q3_pbr_named_t *)realloc(
                g_named, sizeof(*nn) * (size_t)nc);
            if (!nn) break;
            g_named = nn;
            g_named_cap = nc;
        }
        q3_pbr_named_t *e = &g_named[g_named_count];
        memset(e, 0, sizeof(*e));
        size_t nl = strlen(key);
        if (nl >= sizeof(e->name)) nl = sizeof(e->name) - 1;
        memcpy(e->name, key, nl);
        e->name[nl] = '\0';

        /* Extract paths + emissive (same as hash-keyed materials). */
        char *s;
        if ((s = json_str_dup(find_key(body, body_end, "albedo"),    body_end))) { e->mat.albedo    = resolve_path(assetRoot, s); free(s); }
        if ((s = json_str_dup(find_key(body, body_end, "normal"),    body_end))) { e->mat.normal    = resolve_path(assetRoot, s); free(s); }
        if ((s = json_str_dup(find_key(body, body_end, "roughness"), body_end))) { e->mat.roughness = resolve_path(assetRoot, s); free(s); }
        if ((s = json_str_dup(find_key(body, body_end, "metallic"),  body_end))) { e->mat.metallic  = resolve_path(assetRoot, s); free(s); }
        if ((s = json_str_dup(find_key(body, body_end, "emissive"),  body_end))) { e->mat.emissive  = resolve_path(assetRoot, s); free(s); }
        if ((s = json_str_dup(find_key(body, body_end, "height"),    body_end))) { e->mat.height    = resolve_path(assetRoot, s); free(s); }
        double dv;
        if (json_num(find_key(body, body_end, "emissive_intensity"), body_end, &dv)) {
            e->mat.emissive_intensity = (float)dv;
        }
        g_named_count++;
        p = body_end;
    }
}

/* --- JSON loader --------------------------------------------------- */

static char *slurp(const char *path, size_t *out_len) {
    FILE *fp = fopen(path, "rb");
    if (!fp) return NULL;
    fseek(fp, 0, SEEK_END);
    long sz = ftell(fp);
    fseek(fp, 0, SEEK_SET);
    if (sz < 0 || sz > (long)(256 * 1024 * 1024)) { fclose(fp); return NULL; }
    char *buf = (char *)malloc((size_t)sz + 1);
    if (!buf) { fclose(fp); return NULL; }
    size_t got = fread(buf, 1, (size_t)sz, fp);
    fclose(fp);
    buf[got] = '\0';
    if (out_len) *out_len = got;
    return buf;
}

static int hex_byte(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

static int parse_hex64(const char *s, uint64_t *out) {
    uint64_t v = 0;
    for (int i = 0; i < 16; ++i) {
        int h = hex_byte(s[i]);
        if (h < 0) return 0;
        v = (v << 4) | (uint64_t)h;
    }
    *out = v;
    return 1;
}

/* str_arena_dup: appends s + NUL to the arena and returns the
 * stored char* (which is stable for the life of the arena). If
 * s == NULL, returns NULL. Grows the arena geometrically. */
static const char *str_arena_dup(const char *s) {
    if (!s) return NULL;
    /* The original "arena" used realloc() and returned direct pointers
     * into the backing buffer. Every growth could move the buffer and
     * silently invalidate all previously returned material paths. That
     * showed up on-device as empty/garbage DDS paths and partial PBR
     * binding. Use individually stable allocations instead; the table is
     * process-lifetime data and only ~800 named materials in the iOS
     * bundle, so this tiny leak-on-reload is preferable to dangling
     * pointers. */
    size_t len = strlen(s) + 1;
    char *dst = (char *)malloc(len);
    if (!dst) return NULL;
    memcpy(dst, s, len);
    return dst;
}

/* The JSON is well-formed and produced by our own Python tool, so we
 * lean on that — no real JSON parser. We scan for `"<16-hex>"`: { ... },
 * extract the fields by name, and skip everything else. */

static const char *find_key(const char *p, const char *end, const char *key) {
    /* Looks for "key" : <something>  bounded by p..end. Returns pointer to
     * the value (skips whitespace + colon) or NULL. */
    size_t klen = strlen(key);
    while (p < end) {
        const char *q = memchr(p, '"', (size_t)(end - p));
        if (!q) return NULL;
        q++;
        if (q + klen + 1 < end && memcmp(q, key, klen) == 0 && q[klen] == '"') {
            const char *r = q + klen + 1;
            /* This is a JSON object-key finder, not a generic string
             * search. Require the closing quote to be followed by optional
             * whitespace and then ':' before accepting it. Without this,
             * values like `"source": "albedo"` were misidentified as the
             * `albedo` key, causing named world materials whose source tag
             * was "albedo" to lose their actual albedo map while still
             * keeping later fields such as normal. */
            while (r < end && (*r == ' ' || *r == '\t' || *r == '\n' || *r == '\r')) r++;
            if (r >= end || *r != ':') {
                p = q;
                continue;
            }
            r++;
            while (r < end && (*r == ' ' || *r == '\t' || *r == '\n' || *r == '\r')) r++;
            return r;
        }
        p = q;
    }
    return NULL;
}

static char *json_str_dup(const char *v, const char *end) {
    /* v points just after the opening quote. */
    if (!v || v >= end || *v != '"') return NULL;
    v++;
    const char *q = memchr(v, '"', (size_t)(end - v));
    if (!q) return NULL;
    size_t len = (size_t)(q - v);
    char *s = (char *)malloc(len + 1);
    if (!s) return NULL;
    memcpy(s, v, len);
    s[len] = '\0';
    return s;
}

static int json_num(const char *v, const char *end, double *out) {
    if (!v) return 0;
    char *e;
    double d = strtod(v, &e);
    if (e == v) return 0;
    *out = d;
    return 1;
}

/* Path resolution helper. */
static const char *resolve_path(const char *root, const char *rel) {
    if (!rel) return NULL;
    char tmp[2048];
    snprintf(tmp, sizeof(tmp), "%s/%s", root, rel);
    return str_arena_dup(tmp);
}

int q3_pbr_table_load(const char *jsonPath, const char *assetRoot) {
    /* Reset previous state. */
    free(g_materials); g_materials = NULL;
    g_materials_count = 0; g_materials_cap = 0;
    free(g_hash_table); g_hash_table = NULL; g_hash_table_mask = 0;
    free(g_str_arena); g_str_arena = NULL;
    g_str_arena_used = 0; g_str_arena_cap = 0;
    free(g_named); g_named = NULL;
    g_named_count = 0; g_named_cap = 0;

    if (!jsonPath || !assetRoot) return 0;

    size_t json_len = 0;
    char *json = slurp(jsonPath, &json_len);
    if (!json) {
        plog("[Q3-PBR] could not open %s\n", jsonPath);
        return 0;
    }
    const char *end = json + json_len;

    /* Locate the "materials" object. */
    const char *mats = find_key(json, end, "materials");
    if (!mats) { plog("[Q3-PBR] no 'materials' in JSON\n"); free(json); return 0; }

    const char *p = mats;
    while (p < end) {
        /* Find next 16-hex key. */
        const char *q = memchr(p, '"', (size_t)(end - p));
        if (!q) break;
        q++;
        if (q + 16 >= end) break;
        uint64_t hash;
        if (!parse_hex64(q, &hash) || q[16] != '"') {
            p = q;
            continue;
        }
        /* OK, we have a hash. Find the object body. */
        const char *body = q + 17;
        while (body < end && *body != '{' && *body != ']') body++;
        if (body >= end || *body == ']') break;
        body++;
        const char *body_end = body;
        int depth = 1;
        while (body_end < end && depth > 0) {
            if (*body_end == '{') depth++;
            else if (*body_end == '}') depth--;
            body_end++;
        }
        if (depth != 0) break;

        if (g_materials_count >= g_materials_cap) {
            int nc = g_materials_cap ? g_materials_cap * 2 : 256;
            q3_pbr_material_t *nm = (q3_pbr_material_t *)realloc(
                g_materials, sizeof(*nm) * (size_t)nc);
            if (!nm) { free(json); return g_materials_count; }
            g_materials = nm;
            g_materials_cap = nc;
        }

        q3_pbr_material_t *m = &g_materials[g_materials_count++];
        memset(m, 0, sizeof(*m));
        m->hash = hash;

        char *s;
        if ((s = json_str_dup(find_key(body, body_end, "albedo"),    body_end))) { m->albedo    = resolve_path(assetRoot, s); free(s); }
        if ((s = json_str_dup(find_key(body, body_end, "normal"),    body_end))) { m->normal    = resolve_path(assetRoot, s); free(s); }
        if ((s = json_str_dup(find_key(body, body_end, "roughness"), body_end))) { m->roughness = resolve_path(assetRoot, s); free(s); }
        if ((s = json_str_dup(find_key(body, body_end, "metallic"),  body_end))) { m->metallic  = resolve_path(assetRoot, s); free(s); }
        if ((s = json_str_dup(find_key(body, body_end, "emissive"),  body_end))) { m->emissive  = resolve_path(assetRoot, s); free(s); }
        if ((s = json_str_dup(find_key(body, body_end, "height"),    body_end))) { m->height    = resolve_path(assetRoot, s); free(s); }

        double dv = 0;
        if (json_num(find_key(body, body_end, "emissive_intensity"), body_end, &dv)) {
            m->emissive_intensity = (float)dv;
        }
        /* emissive_color is an array — find_key returns pointer right
         * after the ':' so scan for '[' then 3 numbers. */
        const char *ec = find_key(body, body_end, "emissive_color");
        if (ec) {
            while (ec < body_end && *ec != '[') ec++;
            if (ec < body_end && *ec == '[') {
                ec++;
                double r = 0, g = 0, b = 0;
                char *e;
                r = strtod(ec, &e);
                if (e == ec) goto skip_ec;
                ec = e;
                while (ec < body_end && (*ec == ',' || *ec == ' ' || *ec == '\t')) ec++;
                g = strtod(ec, &e);
                if (e == ec) goto skip_ec;
                ec = e;
                while (ec < body_end && (*ec == ',' || *ec == ' ' || *ec == '\t')) ec++;
                b = strtod(ec, &e);
                if (e == ec) goto skip_ec;
                m->emissive_color_r = (float)r;
                m->emissive_color_g = (float)g;
                m->emissive_color_b = (float)b;
                m->has_emissive_color = 1;
            }
            skip_ec:;
        }

        p = body_end;
    }

    /* Phase 1 Path A: also parse the materials_by_name block for the
     * descriptive-stem lookup fallback. */
    load_named_materials_from_json(json, end, assetRoot);

    free(json);

    /* Build the lookup hash table — power-of-two ≥ 2 * count for low
     * collision rate. */
    int cap = 1;
    while (cap < g_materials_count * 2) cap <<= 1;
    if (cap < 16) cap = 16;
    g_hash_table = (int *)calloc((size_t)cap, sizeof(int));
    if (!g_hash_table) return 0;
    g_hash_table_mask = cap - 1;
    for (int i = 0; i < g_materials_count; ++i) {
        unsigned long h = djb2_u64(g_materials[i].hash);
        for (int j = 0; j < cap; ++j) {
            int slot = (int)((h + (unsigned long)j) & (unsigned long)g_hash_table_mask);
            if (g_hash_table[slot] == 0) {
                g_hash_table[slot] = i + 1;
                break;
            }
        }
    }

    plog("[Q3-PBR] loaded %d materials from %s\n",
            g_materials_count, jsonPath);
    plog("[Q3-PBR] assets root: %s\n", assetRoot);
    plog("[Q3-PBR] name-indexed materials: %d (Path A fallback)\n", g_named_count);
    return g_materials_count;
}
