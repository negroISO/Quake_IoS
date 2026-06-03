/*
 * scripts/pbr_hash_probe.c
 *
 * Offline helper to validate PBR hash permutations against
 * docs/pbr/q3rtx_v07_materials.json.
 */

#include <ctype.h>
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "q3_pbr.h"

/* Independent xxHash linkage for this TU. */
#define XXH_INLINE_ALL
#include "vendor/xxhash.h"

#pragma pack(push, 1)
typedef struct {
    uint8_t idLength;
    uint8_t colorMapType;
    uint8_t imageType;
    uint16_t colorMapIndex;
    uint16_t colorMapLength;
    uint8_t colorMapSize;
    uint16_t xOrigin;
    uint16_t yOrigin;
    uint16_t width;
    uint16_t height;
    uint8_t pixelSize;
    uint8_t attributes;
} TGAHeader;
#pragma pack(pop)

typedef enum {
    PREFIX_NONE,
    PREFIX_ASCII_WXH,
    PREFIX_ASCII_CONCAT,
    PREFIX_ASCII_WITH_X,
    PREFIX_LE_WXH,
    PREFIX_BE_WXH,
    PREFIX_U32_LE_LEN,
    PREFIX_BE_U32_LEN,
    PREFIX_U16_LE_WH,
    PREFIX_U16_BE_WH
} PrefixMode;

typedef enum {
    ORDER_RGBA,
    ORDER_BGRA,
    ORDER_ARGB,
    ORDER_ABGR,
    ORDER_GBAR
} ChannelOrder;

typedef enum {
    D3D9FMT_BGRA,
    D3D9FMT_ARGB,
    D3D9FMT_ABGR,
    D3D9FMT_A8R8G8B8_BGRA,
    D3D9FMT_X8R8G8B8_BGRA
} D3D9PixelFormat;

typedef enum {
    ALPHA_SRC,
    ALPHA_OPAQUE,
    ALPHA_ZERO,
    ALPHA_ONE_MINUS
} AlphaMode;

typedef struct {
    const char *label;
    int use_q3_hash;
    int use_xxh3;
    int include_mip_chain;
    int include_alpha;
    int include_bottom_mip_only;
    int stride;
    int prefixAfterPayload;
    int use_raw_tga;
    PrefixMode prefixMode;
    ChannelOrder order;
    AlphaMode alphaMode;
    int use_d3d9_subresource_payload;
    D3D9PixelFormat d3d9_fmt;
    int flipRows;
} HashPerm;

static uint16_t le16_u16(const uint8_t *p) {
    return (uint16_t)(p[0] | ((uint16_t)p[1] << 8));
}

static void to_hex_u64(uint64_t v, char out[17]) {
    static const char *hex = "0123456789ABCDEF";
    for (int i = 0; i < 16; ++i) {
        out[15 - i] = hex[(v >> (i * 4)) & 0xF];
    }
    out[16] = '\0';
}

static int read_file(const char *path, uint8_t **out_data, size_t *out_len) {
    FILE *fp = fopen(path, "rb");
    if (!fp) {
        fprintf(stderr, "[ERR] open '%s': %s\n", path, strerror(errno));
        return 0;
    }

    if (fseek(fp, 0, SEEK_END) != 0) {
        fprintf(stderr, "[ERR] fseek end '%s': %s\n", path, strerror(errno));
        fclose(fp);
        return 0;
    }

    long n = ftell(fp);
    if (n <= 0) {
        fprintf(stderr, "[ERR] invalid length '%s'\n", path);
        fclose(fp);
        return 0;
    }

    rewind(fp);
    uint8_t *buf = (uint8_t *)malloc((size_t)n);
    if (!buf) {
        fprintf(stderr, "[ERR] malloc(%ld) failed '%s'\n", n, path);
        fclose(fp);
        return 0;
    }

    size_t got = fread(buf, 1, (size_t)n, fp);
    fclose(fp);
    if (got != (size_t)n) {
        fprintf(stderr, "[ERR] short read %zu/%ld for '%s'\n", got, n, path);
        free(buf);
        return 0;
    }

    *out_data = buf;
    *out_len = (size_t)n;
    return 1;
}

static int decode_tga_rgba(const uint8_t *data, size_t len, uint8_t **out_rgba, int *out_w, int *out_h) {
    if (len < sizeof(TGAHeader)) {
        return 0;
    }

    TGAHeader h;
    memcpy(&h, data, sizeof(h));

    h.colorMapIndex  = le16_u16((uint8_t *)&h.colorMapIndex);
    h.colorMapLength = le16_u16((uint8_t *)&h.colorMapLength);
    h.xOrigin       = le16_u16((uint8_t *)&h.xOrigin);
    h.yOrigin       = le16_u16((uint8_t *)&h.yOrigin);
    h.width         = le16_u16((uint8_t *)&h.width);
    h.height        = le16_u16((uint8_t *)&h.height);

    if (h.width == 0 || h.height == 0) {
        return 0;
    }
    if (h.colorMapType != 0) {
        return 0;
    }
    if (!(h.imageType == 2 || h.imageType == 3 || h.imageType == 10)) {
        return 0;
    }
    if (h.imageType != 3 && h.pixelSize != 24 && h.pixelSize != 32) {
        return 0;
    }

    const uint8_t *p = data + sizeof(h);
    const uint8_t *end = data + len;
    if ((size_t)(end - p) < h.idLength) {
        return 0;
    }
    p += h.idLength;

    int w = (int)h.width;
    int hgt = (int)h.height;
    size_t pixels = (size_t)w * (size_t)hgt;
    size_t rgba_len = pixels * 4u;

    uint8_t *rgba = (uint8_t *)malloc(rgba_len);
    if (!rgba) {
        return 0;
    }

    if (h.imageType == 2 || h.imageType == 3) {
        size_t pixel_bytes = (h.imageType == 3) ? 1u : (size_t)(h.pixelSize / 8);
        if ((size_t)(end - p) < pixels * pixel_bytes) {
            free(rgba);
            return 0;
        }

        for (int row = hgt - 1; row >= 0; --row) {
            uint8_t *dst = rgba + (size_t)row * (size_t)w * 4u;
            for (int col = 0; col < w; ++col) {
                if (h.imageType == 3) {
                    uint8_t g = *p++;
                    *dst++ = g;
                    *dst++ = g;
                    *dst++ = g;
                    *dst++ = 255;
                } else if (h.pixelSize == 24) {
                    uint8_t b = *p++;
                    uint8_t g = *p++;
                    uint8_t r = *p++;
                    *dst++ = r;
                    *dst++ = g;
                    *dst++ = b;
                    *dst++ = 255;
                } else {
                    uint8_t b = *p++;
                    uint8_t g = *p++;
                    uint8_t r = *p++;
                    uint8_t a = *p++;
                    *dst++ = r;
                    *dst++ = g;
                    *dst++ = b;
                    *dst++ = a;
                }
            }
        }
    } else {
        size_t produced = 0;
        int dst_row = hgt - 1;
        int dst_col = 0;
        while (produced < pixels) {
            if (p >= end) {
                free(rgba);
                return 0;
            }

            uint8_t packet = *p++;
            size_t run = (size_t)(packet & 0x7Fu) + 1u;

            if (packet & 0x80u) {
                if ((size_t)(end - p) < 3u + (size_t)(h.pixelSize == 32 ? 1u : 0u)) {
                    free(rgba);
                    return 0;
                }
                uint8_t b = *p++;
                uint8_t g = *p++;
                uint8_t r = *p++;
                uint8_t a = 255;
                if (h.pixelSize == 32) {
                    a = *p++;
                }
                for (size_t i = 0; i < run && produced < pixels; ++i, ++produced) {
                    uint8_t *dst = rgba + produced * 4u;
                    dst = rgba + ((size_t)dst_row * (size_t)w + (size_t)dst_col) * 4u;
                    *dst++ = r;
                    *dst++ = g;
                    *dst++ = b;
                    *dst++ = a;
                    ++dst_col;
                    if (dst_col >= w) {
                        dst_col = 0;
                        --dst_row;
                    }
                }
            } else {
                for (size_t i = 0; i < run && produced < pixels; ++i, ++produced) {
                    if ((size_t)(end - p) < 3u + (size_t)(h.pixelSize == 32 ? 1u : 0u)) {
                        free(rgba);
                        return 0;
                    }
                    uint8_t b = *p++;
                    uint8_t g = *p++;
                    uint8_t r = *p++;
                    uint8_t a = 255;
                    if (h.pixelSize == 32) {
                        a = *p++;
                    }
                    uint8_t *dst = rgba + ((size_t)dst_row * (size_t)w + (size_t)dst_col) * 4u;
                    *dst++ = r;
                    *dst++ = g;
                    *dst++ = b;
                    *dst++ = a;
                    ++dst_col;
                    if (dst_col >= w) {
                        dst_col = 0;
                        --dst_row;
                    }
                }
            }
        }
    }

    *out_rgba = rgba;
    *out_w = w;
    *out_h = hgt;
    return 1;
}

static void append_payload_prefix(uint8_t **buf, size_t *len, size_t *cap, PrefixMode m, int w, int h) {
    if (m == PREFIX_NONE) {
        return;
    }

    char asc[64];
    int n = 0;
    size_t bytes = 0;

    switch (m) {
    case PREFIX_ASCII_WXH:
        n = snprintf(asc, sizeof(asc), "%dx%d", w, h);
        bytes = (size_t)n;
        break;
    case PREFIX_ASCII_CONCAT:
        n = snprintf(asc, sizeof(asc), "%d%d", w, h);
        bytes = (size_t)n;
        break;
    case PREFIX_ASCII_WITH_X:
        n = snprintf(asc, sizeof(asc), "%d,%d", w, h);
        bytes = (size_t)n;
        break;
    default:
        break;
    }

    if (m == PREFIX_LE_WXH || m == PREFIX_BE_WXH || m == PREFIX_U32_LE_LEN || m == PREFIX_BE_U32_LEN) {
        bytes = 8;
    }
    if (m == PREFIX_U16_LE_WH || m == PREFIX_U16_BE_WH) {
        bytes = 4;
    }

    if (*len + bytes > *cap) {
        size_t ncap = *cap ? *cap : 1024;
        while (ncap < *len + bytes) ncap *= 2;
        void *tmp = realloc(*buf, ncap);
        if (!tmp) {
            return;
        }
        *buf = (uint8_t *)tmp;
        *cap = ncap;
    }

    switch (m) {
    case PREFIX_ASCII_WXH:
    case PREFIX_ASCII_CONCAT:
    case PREFIX_ASCII_WITH_X:
        memcpy(*buf + *len, asc, bytes);
        *len += bytes;
        break;
    case PREFIX_LE_WXH: {
        uint32_t ww = (uint32_t)w;
        uint32_t hh = (uint32_t)h;
        memcpy(*buf + *len, &ww, 4);
        memcpy(*buf + *len + 4, &hh, 4);
        *len += 8;
        break; }
    case PREFIX_U32_LE_LEN: {
        uint64_t wh = ((uint64_t)(uint32_t)w << 32) | (uint32_t)h;
        memcpy(*buf + *len, &wh, 8);
        *len += 8;
        break; }
    case PREFIX_BE_U32_LEN: {
        uint64_t ww = (uint64_t)(uint32_t)w;
        uint64_t wh = ((uint64_t)(uint32_t)w << 32) | (uint32_t)h;
        uint8_t b8[8];
        b8[0] = (uint8_t)(wh >> 56); b8[1] = (uint8_t)(wh >> 48);
        b8[2] = (uint8_t)(wh >> 40); b8[3] = (uint8_t)(wh >> 32);
        b8[4] = (uint8_t)(wh >> 24); b8[5] = (uint8_t)(wh >> 16);
        b8[6] = (uint8_t)(wh >> 8);  b8[7] = (uint8_t)wh;
        memcpy(*buf + *len, b8, 8);
        *len += 8;
        break; }
    case PREFIX_U16_LE_WH: {
        uint16_t ww = (uint16_t)w;
        uint16_t hh = (uint16_t)h;
        memcpy(*buf + *len, &ww, 2);
        memcpy(*buf + *len + 2, &hh, 2);
        *len += 4;
        break; }
    case PREFIX_U16_BE_WH: {
        uint8_t b4[4];
        b4[0] = (uint8_t)(w >> 8);
        b4[1] = (uint8_t)(w >> 0);
        b4[2] = (uint8_t)(h >> 8);
        b4[3] = (uint8_t)(h >> 0);
        memcpy(*buf + *len, b4, 4);
        *len += 4;
        break; }
    case PREFIX_BE_WXH: {
        uint8_t b4[8];
        b4[0] = (uint8_t)(w >> 24);
        b4[1] = (uint8_t)(w >> 16);
        b4[2] = (uint8_t)(w >> 8);
        b4[3] = (uint8_t)(w >> 0);
        b4[4] = (uint8_t)(h >> 24);
        b4[5] = (uint8_t)(h >> 16);
        b4[6] = (uint8_t)(h >> 8);
        b4[7] = (uint8_t)(h >> 0);
        memcpy(*buf + *len, b4, 8);
        *len += 8;
        break; }
    default:
        break;
    }
}

static void remap_pixel(const uint8_t *rgba, uint8_t *dst, ChannelOrder order, int alpha_mode, int i) {
    uint8_t r = rgba[i + 0];
    uint8_t g = rgba[i + 1];
    uint8_t b = rgba[i + 2];
    uint8_t a = rgba[i + 3];

    if (alpha_mode == ALPHA_OPAQUE) {
        a = 255;
    } else if (alpha_mode == ALPHA_ZERO) {
        a = 0;
    } else if (alpha_mode == ALPHA_ONE_MINUS) {
        a = (uint8_t)(255 - a);
    }

    switch (order) {
    case ORDER_RGBA:
        dst[0] = r; dst[1] = g; dst[2] = b; dst[3] = a;
        break;
    case ORDER_BGRA:
        dst[0] = b; dst[1] = g; dst[2] = r; dst[3] = a;
        break;
    case ORDER_ARGB:
        dst[0] = a; dst[1] = r; dst[2] = g; dst[3] = b;
        break;
    case ORDER_ABGR:
        dst[0] = a; dst[1] = b; dst[2] = g; dst[3] = r;
        break;
    case ORDER_GBAR:
        dst[0] = g; dst[1] = b; dst[2] = a; dst[3] = r;
        break;
    }
}

static void append_pixels_in_order(uint8_t **buf, size_t *len, size_t *cap,
                                  const uint8_t *rgba, int w, int h,
                                  ChannelOrder order, AlphaMode alphaMode,
                                  int include_alpha, int flipRows, int stride) {
    if (stride <= 0) {
        stride = 1;
    }
    size_t stride_pixels = (size_t)((w + stride - 1) / stride);
    size_t bytes_per_pixel = include_alpha ? 4u : 3u;
    size_t n = (size_t)h * stride_pixels * bytes_per_pixel;
    if (*len + n > *cap) {
        size_t ncap = *cap ? *cap : 1024;
        while (ncap < *len + n) ncap *= 2;
        void *tmp = realloc(*buf, ncap);
        if (!tmp) {
            return;
        }
        *buf = (uint8_t *)tmp;
        *cap = ncap;
    }

    uint8_t tmp[4];
    for (int row = 0; row < h; ++row) {
        int srcRow = flipRows ? (h - 1 - row) : row;
        size_t srcBase = (size_t)srcRow * (size_t)w * 4u;
        for (int col = 0; col < w; col += stride) {
            size_t src_i = srcBase + (size_t)col * 4u;
            remap_pixel(rgba, tmp, order, alphaMode, (int)src_i);
            (*buf)[(*len)++] = tmp[0];
            (*buf)[(*len)++] = tmp[1];
            (*buf)[(*len)++] = tmp[2];
            if (include_alpha) {
                (*buf)[(*len)++] = tmp[3];
            }
        }
    }
}

static uint8_t *make_mip_rgba(const uint8_t *src, int w, int h, int *out_w, int *out_h) {
    int ww = (w + 1) >> 1;
    int hh = (h + 1) >> 1;
    size_t dst_len = (size_t)ww * (size_t)hh * 4u;
    uint8_t *dst = (uint8_t *)malloc(dst_len);
    if (!dst) {
        return NULL;
    }

    for (int y = 0; y < hh; ++y) {
        int y0 = y * 2;
        int y1 = (y0 + 1 < h) ? (y0 + 1) : y0;
        for (int x = 0; x < ww; ++x) {
            int x0 = x * 2;
            int x1 = (x0 + 1 < w) ? (x0 + 1) : x0;

            int idx00 = (y0 * w + x0) * 4;
            int idx10 = (y0 * w + x1) * 4;
            int idx01 = (y1 * w + x0) * 4;
            int idx11 = (y1 * w + x1) * 4;

            int di = (y * ww + x) * 4;
            for (int c = 0; c < 4; ++c) {
                unsigned sum = src[idx00 + c] + src[idx10 + c] + src[idx01 + c] + src[idx11 + c];
                dst[di + c] = (uint8_t)(sum >> 2);
            }
        }
    }

    *out_w = ww;
    *out_h = hh;
    return dst;
}

static void append_layer_payload(uint8_t **buf, size_t *len, size_t *cap, const uint8_t *rgba, int w, int h,
                                ChannelOrder order, AlphaMode alphaMode, int include_mips,
                                int include_bottom_mip_only, int include_alpha, int flipRows, int stride) {
    if (include_bottom_mip_only) {
        int cw = w;
        int ch = h;
        uint8_t *cur = (uint8_t *)malloc((size_t)cw * (size_t)ch * 4u);
        if (!cur) {
            return;
        }
        memcpy(cur, rgba, (size_t)cw * (size_t)ch * 4u);

        while (cw > 1 || ch > 1) {
            int nw, nh;
            uint8_t *next = make_mip_rgba(cur, cw, ch, &nw, &nh);
            free(cur);
            if (!next) {
                return;
            }
            cur = next;
            cw = nw;
            ch = nh;
        }

        append_pixels_in_order(buf, len, cap, cur, cw, ch, order, alphaMode, include_alpha, flipRows, stride);
        free(cur);
        return;
    }

    append_pixels_in_order(buf, len, cap, rgba, w, h, order, alphaMode, include_alpha, flipRows, stride);
    if (!include_mips || w == 1 && h == 1) {
        return;
    }

    int cw = w;
    int ch = h;
    uint8_t *cur = (uint8_t *)malloc((size_t)cw * (size_t)ch * 4u);
    if (!cur) {
        return;
    }
    memcpy(cur, rgba, (size_t)cw * (size_t)ch * 4u);

    while (cw > 1 || ch > 1) {
        int nw, nh;
        uint8_t *next = make_mip_rgba(cur, cw, ch, &nw, &nh);
        free(cur);
        if (!next) {
            break;
        }

        append_pixels_in_order(buf, len, cap, next, nw, nh, order, alphaMode, include_alpha, flipRows, stride);
        cur = next;
        cw = nw;
        ch = nh;
    }
    free(cur);
}

static size_t align4(size_t x) {
    return (x + 3u) & ~(size_t)3u;
}

static void append_d3d9_subresource_payload(uint8_t **buf, size_t *len, size_t *cap,
                                           const uint8_t *rgba, int w, int h,
                                           ChannelOrder order, AlphaMode alphaMode,
                                           int include_alpha, int flipRows) {
    if (!rgba || w <= 0 || h <= 0) {
        return;
    }

    size_t rowBytes = (size_t)w * 4u;
    size_t rowPitch = align4(rowBytes);
    size_t payloadBytes = rowPitch * (size_t)h;
    if (payloadBytes == 0) {
        return;
    }

    if (*len + payloadBytes > *cap) {
        size_t ncap = *cap ? *cap : 1024;
        while (ncap < *len + payloadBytes) ncap *= 2;
        void *tmp = realloc(*buf, ncap);
        if (!tmp) {
            return;
        }
        *buf = (uint8_t *)tmp;
        *cap = ncap;
    }

    memset(*buf + *len, 0, payloadBytes);
    uint8_t px[4];

    for (int row = 0; row < h; ++row) {
        int srcRow = flipRows ? (h - 1 - row) : row;
        uint8_t *dst = *buf + *len + (size_t)row * rowPitch;
        const uint8_t *src = rgba + (size_t)srcRow * (size_t)w * 4u;
        for (int col = 0; col < w; ++col) {
            size_t src_i = (size_t)col * 4u;
            remap_pixel(src, px, order, alphaMode, (int)src_i);
            memcpy(dst + (size_t)col * 4u, px, 4u);
        }
    }

    *len += payloadBytes;
}

static uint64_t hash_from_payload(const uint8_t *payload, size_t payload_len, int use_xxh3) {
    if (use_xxh3) {
        return XXH3_64bits(payload, payload_len);
    }
    return XXH64(payload, payload_len, 0);
}

static uint64_t hash_variant(const uint8_t *rgba, int w, int h, const HashPerm *perm, const uint8_t *raw_tga_bytes, size_t raw_tga_len) {
    if (perm->use_q3_hash) {
        return q3_pbr_hash_rgba(rgba, w, h);
    }

    size_t cap = 1024;
    uint8_t *payload = (uint8_t *)malloc(cap);
    size_t len = 0;
    if (!payload) {
        return 0;
    }

    AlphaMode alpha = perm->alphaMode;
    ChannelOrder order = perm->order;

    if (!perm->prefixAfterPayload) {
        append_payload_prefix(&payload, &len, &cap, perm->prefixMode, w, h);
    }

    /* Legacy/escape path: hash raw container bytes instead of decoded RGBA. */
    if (perm->use_raw_tga && raw_tga_bytes != NULL) {
        if (len + raw_tga_len > cap) {
            size_t ncap = cap;
            while (ncap < len + raw_tga_len) ncap *= 2;
            void *tmp = realloc(payload, ncap);
            if (!tmp) {
                free(payload);
                return 0;
            }
            payload = (uint8_t *)tmp;
            cap = ncap;
        }
        memcpy(payload + len, raw_tga_bytes, raw_tga_len);
        len += raw_tga_len;
    } else {
        ChannelOrder effective_order = order;
        if (perm->d3d9_fmt == D3D9FMT_ARGB) {
            effective_order = ORDER_ARGB;
        } else if (perm->d3d9_fmt == D3D9FMT_ABGR) {
            effective_order = ORDER_ABGR;
        } else if (perm->d3d9_fmt == D3D9FMT_A8R8G8B8_BGRA) {
            effective_order = ORDER_BGRA;
        } else if (perm->d3d9_fmt == D3D9FMT_X8R8G8B8_BGRA) {
            effective_order = ORDER_BGRA;
        } else {
            effective_order = order;
        }

        if (perm->use_d3d9_subresource_payload) {
            append_d3d9_subresource_payload(&payload, &len, &cap,
                                            rgba, w, h,
                                            effective_order, alpha,
                                            perm->include_alpha, perm->flipRows);
        } else {
            append_layer_payload(&payload, &len, &cap, rgba, w, h,
                                effective_order, alpha,
                                perm->include_mip_chain, perm->include_bottom_mip_only,
                                perm->include_alpha, perm->flipRows, perm->stride);
        }
    }

    if (perm->prefixAfterPayload) {
        append_payload_prefix(&payload, &len, &cap, perm->prefixMode, w, h);
    }

    uint64_t hv = hash_from_payload(payload, len, perm->use_xxh3);
    free(payload);
    return hv;
}

static int find_field_value(const char *obj_start, const char *obj_end, const char *field_name,
                                   char *out, size_t out_cap) {
    char pattern[64];
    snprintf(pattern, sizeof(pattern), "\"%s\"", field_name);

    for (const char *p = obj_start; p && p < obj_end; ++p) {
        const char *q = strstr(p, pattern);
        if (!q || q >= obj_end) {
            return 0;
        }

        const char *r = q + strlen(pattern);
        while (r < obj_end && isspace((unsigned char)*r)) ++r;
        if (r >= obj_end || *r != ':') {
            p = q;
            continue;
        }

        ++r;
        while (r < obj_end && isspace((unsigned char)*r)) ++r;
        if (r >= obj_end) return 0;

        if (strncmp(r, "null", 4) == 0) {
            strcpy(out, "(null)");
            return 1;
        }
        if (*r != '"') {
            strcpy(out, "(non-string)");
            return 1;
        }

        ++r;
        const char *e = r;
        while (e < obj_end && *e != '"') ++e;
        if (e <= r || e > obj_end) return 0;

        size_t n = (size_t)(e - r);
        if (n >= out_cap) n = out_cap - 1;
        memcpy(out, r, n);
        out[n] = '\0';
        return 1;
    }

    return 0;
}

static const char *find_material_block(const char *json, const char *key,
                                      const char **obj_start,
                                      const char **obj_end) {
    char quoted[40];
    snprintf(quoted, sizeof(quoted), "\"%s\"", key);

    const char *p = json;
    while ((p = strstr(p, quoted)) != NULL) {
        const char *after_key = p + strlen(quoted);
        while (after_key < p + 1024 && isspace((unsigned char)*after_key)) ++after_key;
        if (*after_key != ':') {
            p = after_key;
            continue;
        }

        const char *s = after_key;
        while (s && *s && *s != '{') ++s;
        if (!s || *s != '{') {
            p = after_key;
            continue;
        }

        int depth = 0;
        const char *q = s;
        for (; *q; ++q) {
            if (*q == '{') ++depth;
            else if (*q == '}') {
                --depth;
                if (depth == 0) {
                    *obj_start = s;
                    *obj_end = q + 1;
                    return p;
                }
            }
        }

        return NULL;
    }

    return NULL;
}

static int permutation_hits(const char *json, const char *hex) {
    const char *obj_start = NULL;
    const char *obj_end = NULL;

    if (find_material_block(json, hex, &obj_start, &obj_end)) {
        return 1;
    }

    char key_to_use[24];
    snprintf(key_to_use, sizeof(key_to_use), "mat_%s", hex);
    if (find_material_block(json, key_to_use, &obj_start, &obj_end)) {
        return 1;
    }

    return 0;
}

static void print_material_hit(const char *json, const char *hex) {
    const char *obj_start = NULL;
    const char *obj_end = NULL;

    char key_to_use[24];
    snprintf(key_to_use, sizeof(key_to_use), "mat_%s", hex);

    const char *found = find_material_block(json, hex, &obj_start, &obj_end);
    const char *resolved = NULL;
    if (!found) {
        found = find_material_block(json, key_to_use, &obj_start, &obj_end);
        resolved = key_to_use;
    } else {
        resolved = hex;
    }

    if (!found) {
        printf("    [no-match]\n");
        return;
    }

    printf("    key: %s\n", resolved ? resolved : hex);

    const char *fields[] = {"albedo", "normal", "roughness", "metallic", "emissive", "height", "emissive_intensity", "emissive_color"};
    char v[256];
    for (size_t i = 0; i < sizeof(fields) / sizeof(fields[0]); ++i) {
        if (find_field_value(obj_start, obj_end, fields[i], v, sizeof(v))) {
            printf("    %s: %s\n", fields[i], v);
        } else {
            printf("    %s: (missing)\n", fields[i]);
        }
    }
}

static int load_text(const char *path, char **out_text, size_t *out_len) {
    FILE *fp = fopen(path, "rb");
    if (!fp) {
        return 0;
    }
    if (fseek(fp, 0, SEEK_END) != 0) {
        fclose(fp);
        return 0;
    }

    long n = ftell(fp);
    if (n < 0) {
        fclose(fp);
        return 0;
    }
    rewind(fp);

    char *s = (char *)malloc((size_t)n + 1);
    if (!s) {
        fclose(fp);
        return 0;
    }

    size_t got = fread(s, 1, (size_t)n, fp);
    fclose(fp);
    if (got != (size_t)n) {
        free(s);
        return 0;
    }

    s[got] = '\0';
    *out_text = s;
    if (out_len) *out_len = got;
    return 1;
}

static void print_first_bytes(const uint8_t *rgba, size_t rgba_len) {
    printf("first16 bytes: ");
    size_t n = rgba_len < 16 ? rgba_len : 16;
    for (size_t i = 0; i < n; ++i) {
        if (i > 0) printf(" ");
        printf("%02X", rgba[i]);
    }
    printf("\n");
}

int main(int argc, char **argv) {
    int quiet = 0;
    if (argc >= 2 && strcmp(argv[1], "--quiet") == 0) {
        quiet = 1;
        ++argv;
        --argc;
    }

    int use_raw = 0;
    int raw_w = 0;
    int raw_h = 0;
    const char *tga_path = NULL;
    const char *json_path = NULL;
    uint8_t *rgba = NULL;
    int width = 0;
    int height = 0;
    size_t rgba_len = 0;
    uint8_t *raw_tga = NULL;
    size_t raw_tga_len = 0;

    if (argc >= 2 && strcmp(argv[1], "--raw") == 0) {
        use_raw = 1;
        if (argc != 6) {
            fprintf(stderr, "Usage: %s [--quiet] --raw <rgba_file> <width> <height> <q3rtx_v07_materials.json>\n", argv[0]);
            return 1;
        }

        char *endp = NULL;
        raw_w = (int)strtol(argv[3], &endp, 10);
        if (!endp || *endp != '\0' || raw_w <= 0) {
            fprintf(stderr, "[ERR] invalid width '%s'\n", argv[3]);
            return 1;
        }
        endp = NULL;
        raw_h = (int)strtol(argv[4], &endp, 10);
        if (!endp || *endp != '\0' || raw_h <= 0) {
            fprintf(stderr, "[ERR] invalid height '%s'\n", argv[4]);
            return 1;
        }

        if (!read_file(argv[2], &rgba, &rgba_len)) {
            return 1;
        }
        size_t expected = (size_t)raw_w * (size_t)raw_h * 4u;
        if (rgba_len != expected) {
            fprintf(stderr, "[ERR] raw rgba size mismatch: have %zu, expected %zu (%dx%d)\n", rgba_len, expected, raw_w, raw_h);
            free(rgba);
            return 1;
        }

        width = raw_w;
        height = raw_h;
        tga_path = "<raw rgba>";
        json_path = argv[5];
    } else {
        if (argc != 3) {
            fprintf(stderr, "Usage: %s [--quiet] <tga_file|--raw ...> <q3rtx_v07_materials.json>\n", argv[0]);
            return 1;
        }

        tga_path = argv[1];
        json_path = argv[2];

        uint8_t *tga_blob = NULL;
        size_t tga_len = 0;
        if (!read_file(tga_path, &tga_blob, &tga_len)) {
            return 1;
        }

        if (!decode_tga_rgba(tga_blob, tga_len, &rgba, &width, &height)) {
            fprintf(stderr, "[ERR] failed to decode TGA '%s'\n", tga_path);
                return 1;
        }

        raw_tga = tga_blob;
        raw_tga_len = tga_len;
        rgba_len = (size_t)width * (size_t)height * 4u;
    }

    char *json = NULL;
    if (!load_text(json_path, &json, NULL)) {
        fprintf(stderr, "[ERR] failed to load JSON '%s'\n", json_path);
        free(rgba);
        free(raw_tga);
        return 1;
    }

    if (!quiet) {
        printf("texture: %s\n", tga_path ? tga_path : "<raw rgba>");
        printf("dims:    %dx%d\n", width, height);
        printf("bytes:   %zu\n", rgba_len);
        print_first_bytes(rgba, rgba_len);
        if (!use_raw) {
            printf("mip:     TGA container has only mip0 (no explicit mips)\n");
        } else {
            printf("mip:     raw input is single layer\n");
        }
        printf("\n");
    }

    HashPerm variants[] = {
        {"q3_pbr_hash_rgba",              1, 1, 0, 1, 0, 1, 0, 0, PREFIX_NONE,        ORDER_BGRA, ALPHA_SRC, 0, D3D9FMT_BGRA, 0},
        {"STRIDE2_BGRA",                  0, 1, 0, 1, 0, 2, 0, 0, PREFIX_NONE,        ORDER_BGRA, ALPHA_SRC, 0, D3D9FMT_BGRA, 0},
        {"STRIDE4_BGRA",                  0, 1, 0, 1, 0, 4, 0, 0, PREFIX_NONE,        ORDER_BGRA, ALPHA_SRC, 0, D3D9FMT_BGRA, 0},
        {"STRIDE8_BGRA",                  0, 1, 0, 1, 0, 8, 0, 0, PREFIX_NONE,        ORDER_BGRA, ALPHA_SRC, 0, D3D9FMT_BGRA, 0},
        {"STRIDE16_BGRA",                 0, 1, 0, 1, 0,16, 0, 0, PREFIX_NONE,        ORDER_BGRA, ALPHA_SRC, 0, D3D9FMT_BGRA, 0},
        {"STRIDE3_BGRA",                  0, 1, 0, 1, 0, 3, 0, 0, PREFIX_NONE,        ORDER_BGRA, ALPHA_SRC, 0, D3D9FMT_BGRA, 0},
        {"XXH3_RGBA",                     0, 1, 0, 1, 0, 1, 0, 0, PREFIX_NONE,        ORDER_RGBA, ALPHA_SRC, 0, D3D9FMT_BGRA, 0},
        {"XXH3_BGRA",                     0, 1, 0, 1, 0, 1, 0, 0, PREFIX_NONE,        ORDER_BGRA, ALPHA_SRC, 0, D3D9FMT_BGRA, 0},
        {"XXH3_ARGB",                     0, 1, 0, 1, 0, 1, 0, 0, PREFIX_NONE,        ORDER_ARGB, ALPHA_SRC, 0, D3D9FMT_ARGB, 0},
        {"XXH3_ABGR",                     0, 1, 0, 1, 0, 1, 0, 0, PREFIX_NONE,        ORDER_ABGR, ALPHA_SRC, 0, D3D9FMT_ABGR, 0},
        {"XXH3_GBAR",                     0, 1, 0, 1, 0, 1, 0, 0, PREFIX_NONE,        ORDER_GBAR, ALPHA_SRC, 0, D3D9FMT_BGRA, 0},
        {"XXH3_RGBA_le",                  0, 1, 0, 1, 0, 1, 0, 0, PREFIX_U16_LE_WH,   ORDER_RGBA, ALPHA_SRC, 0, D3D9FMT_BGRA, 0},
        {"XXH3_RGBA_u32_be",              0, 1, 0, 1, 0, 1, 0, 0, PREFIX_BE_U32_LEN,  ORDER_RGBA, ALPHA_SRC, 0, D3D9FMT_BGRA, 0},
        {"XXH3_RGBA_u16_be",              0, 1, 0, 1, 0, 1, 0, 0, PREFIX_U16_BE_WH,   ORDER_RGBA, ALPHA_SRC, 0, D3D9FMT_BGRA, 0},
        {"XXH3_RGBA_be",                  0, 1, 0, 1, 0, 1, 0, 0, PREFIX_BE_WXH,      ORDER_RGBA, ALPHA_SRC, 0, D3D9FMT_BGRA, 0},
        {"XXH3_RGBA_wxh",                 0, 1, 0, 1, 0, 1, 0, 0, PREFIX_ASCII_WXH,   ORDER_RGBA, ALPHA_SRC, 0, D3D9FMT_BGRA, 0},
        {"XXH3_BGRA_wxh",                 0, 1, 0, 1, 0, 1, 0, 0, PREFIX_ASCII_WXH,   ORDER_BGRA, ALPHA_SRC, 0, D3D9FMT_BGRA, 0},
        {"XXH3_RGBA_wxh_concat",           0, 1, 0, 1, 0, 1, 0, 0, PREFIX_ASCII_CONCAT, ORDER_RGBA, ALPHA_SRC, 0, D3D9FMT_BGRA, 0},
        {"XXH3_RGBA_wxh_commas",           0, 1, 0, 1, 0, 1, 0, 0, PREFIX_ASCII_WITH_X, ORDER_RGBA, ALPHA_SRC, 0, D3D9FMT_BGRA, 0},
        {"XXH3_RGBA_wxh_suffix",           0, 1, 0, 1, 0, 1, 1, 0, PREFIX_ASCII_WXH,   ORDER_RGBA, ALPHA_SRC, 0, D3D9FMT_BGRA, 0},
        {"XXH3_RGBA_mipchain",             0, 1, 1, 1, 0, 1, 0, 0, PREFIX_NONE,        ORDER_RGBA, ALPHA_SRC, 0, D3D9FMT_BGRA, 0},
        {"XXH3_RGBA_bottom_mip",           0, 1, 0, 1, 1, 1, 0, 0, PREFIX_NONE,        ORDER_RGBA, ALPHA_SRC, 0, D3D9FMT_BGRA, 0},
        {"XXH3_DX9_A8R8G8B8",             0, 1, 0, 1, 0, 1, 0, 0, PREFIX_NONE,        ORDER_RGBA, ALPHA_SRC, 0, D3D9FMT_A8R8G8B8_BGRA, 0},
        {"XXH3_DX9_ABGR",                 0, 1, 0, 1, 0, 1, 0, 0, PREFIX_NONE,        ORDER_RGBA, ALPHA_SRC, 0, D3D9FMT_ABGR, 0},
        {"XXH3_DX9_A8R8G8B8_bottommip",   0, 1, 0, 1, 1, 1, 0, 0, PREFIX_NONE,        ORDER_RGBA, ALPHA_SRC, 0, D3D9FMT_A8R8G8B8_BGRA, 0},
        {"XXH3_RGBA_opaque",               0, 1, 0, 1, 0, 1, 0, 0, PREFIX_NONE,        ORDER_RGBA, ALPHA_OPAQUE, 0, D3D9FMT_BGRA, 0},
        {"XXH3_BGRA_opaque",               0, 1, 0, 1, 0, 1, 0, 0, PREFIX_NONE,        ORDER_BGRA, ALPHA_OPAQUE, 0, D3D9FMT_BGRA, 0},
        {"XXH3_RGBA_one_minus_alpha",      0, 1, 0, 1, 0, 1, 0, 0, PREFIX_NONE,        ORDER_RGBA, ALPHA_ONE_MINUS, 0, D3D9FMT_BGRA, 0},
        {"XXH3_RGBA_zero_alpha",           0, 1, 0, 1, 0, 1, 0, 0, PREFIX_NONE,        ORDER_RGBA, ALPHA_ZERO, 0, D3D9FMT_BGRA, 0},
        {"XXH3_RGBA_nobalpha",             0, 1, 0, 0, 0, 1, 0, 0, PREFIX_NONE,        ORDER_RGBA, ALPHA_SRC, 0, D3D9FMT_BGRA, 0},
        {"XXH3_BGRA_flipY",                0, 1, 0, 1, 0, 1, 0, 0, PREFIX_NONE,        ORDER_BGRA, ALPHA_SRC, 0, D3D9FMT_BGRA, 1},
        {"XXH3_RGBA_flipY",                0, 1, 0, 1, 0, 1, 0, 0, PREFIX_NONE,        ORDER_RGBA, ALPHA_SRC, 0, D3D9FMT_BGRA, 1},
        {"XXH3_BGRA_raw",                  0, 1, 0, 1, 0, 1, 1, 0, PREFIX_NONE,        ORDER_BGRA, ALPHA_SRC, 0, D3D9FMT_BGRA, 0},
        {"XXH64_RGBA",                     0, 0, 0, 1, 0, 1, 0, 0, PREFIX_NONE,        ORDER_RGBA, ALPHA_SRC, 0, D3D9FMT_BGRA, 0},
        {"XXH64_DX9_A8R8G8B8",            0, 0, 0, 1, 0, 1, 0, 0, PREFIX_NONE,        ORDER_RGBA, ALPHA_SRC, 0, D3D9FMT_A8R8G8B8_BGRA, 0},
        {"XXH64_DX9_A8R8G8B8_bottommip",   0, 0, 0, 1, 1, 1, 0, 0, PREFIX_NONE,        ORDER_RGBA, ALPHA_SRC, 0, D3D9FMT_A8R8G8B8_BGRA, 0},
        {"XXH64_BGRA",                     0, 0, 0, 1, 0, 1, 0, 0, PREFIX_NONE,        ORDER_BGRA, ALPHA_SRC, 0, D3D9FMT_BGRA, 0},
        {"XXH64_RGBA_be",                  0, 0, 0, 1, 0, 1, 0, 0, PREFIX_BE_WXH,      ORDER_RGBA, ALPHA_SRC, 0, D3D9FMT_BGRA, 0},
        {"XXH64_RGBA_u16_be",              0, 0, 0, 1, 0, 1, 0, 0, PREFIX_U16_BE_WH,   ORDER_RGBA, ALPHA_SRC, 0, D3D9FMT_BGRA, 0},
        {"XXH64_RGBA_flipY",               0, 0, 0, 1, 0, 1, 0, 0, PREFIX_NONE,        ORDER_RGBA, ALPHA_SRC, 0, D3D9FMT_BGRA, 1},
    };
    const size_t variant_count = sizeof(variants) / sizeof(variants[0]);

    int found = 0;
    if (!quiet) {
        printf("%-32s  %-16s  match\n", "permutation", "hash");
        printf("----------------------------------------------------------------------\n");
    }

    for (size_t i = 0; i < variant_count; ++i) {
        const HashPerm *v = &variants[i];
        uint64_t hv = hash_variant(rgba, width, height, v, raw_tga, raw_tga_len);

        char hex[17];
        to_hex_u64(hv, hex);

        int is_match = permutation_hits(json, hex);

        if (!quiet) {
            printf("%-32s  %s  %s\n", v->label, hex, is_match ? "YES" : "no");
        }

        if (is_match) {
            ++found;
            if (quiet) {
                printf("MATCH\t%s\t%s\t%s\n", tga_path ? tga_path : "<raw>", v->label, hex);
            }
            if (!quiet) {
                printf("  \n");
            }
            print_material_hit(json, hex);
        }
    }

    free(rgba);
    free(json);
    free(raw_tga);

    if (!found) {
        if (!quiet) {
            printf("\n[summary] all permutations tried, no match — algorithm differs structurally\n");
        }
        return 2;
    }

    if (!quiet) {
        printf("\n[summary] match(es) found above under listed permutation rows.\n");
    }
    return 0;
}

int q3_pbr_cvar_enabled(void) {
    return 1;
}
