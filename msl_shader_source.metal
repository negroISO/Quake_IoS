
        #include <metal_stdlib>
        using namespace metal;

        struct VertexIn {
            float2 position;
            float2 texCoord;
            float4 color;
        };

        struct Uniforms {
            float4x4 projection;
        };

        struct VertexOut {
            float4 position [[position]];
            float2 texCoord;
            float4 color;
        };

        vertex VertexOut q3_ui_vertex(const device VertexIn *vertices [[buffer(0)]],
                                      constant Uniforms &uniforms [[buffer(1)]],
                                      uint vertexID [[vertex_id]]) {
            VertexOut out;
            VertexIn inVertex = vertices[vertexID];
            out.position = uniforms.projection * float4(inVertex.position, 0.0, 1.0);
            out.texCoord = inVertex.texCoord;
            out.color = inVertex.color;
            return out;
        }

        fragment float4 q3_ui_fragment(VertexOut in [[stage_in]],
                                       texture2d<float> colorTexture [[texture(0)]],
                                       sampler textureSampler [[sampler(0)]]) {
            constexpr sampler fallbackSampler(filter::linear, address::clamp_to_edge);
            float4 texel = colorTexture.sample(textureSampler, in.texCoord);
            return texel * in.color;
        }

        struct WorldVertexIn {
            float3 position;
            float2 texCoord;
            float2 lightmapTexCoord;
            float3 normal;
            float4 color;
            float4 autospriteCenter;
            float4 autospriteLongAxis;
            // Per-vertex CGEN_LIGHTING_DIFFUSE (ambient + directed*Lambert
            // from the BSP lightgrid). Used by the fragment via WorldVertexOut.
            float3 lightingDiffuse;
        };

        struct WorldUniforms {
            float4x4 viewProjection;
            packed_float3 cameraPos;
            float _pad;
            packed_float3 cameraRight;
            float _padR;
            packed_float3 cameraUp;
            float _padU;
        };

        struct FogVolumeUniforms {
            float4x4 viewProjection;
            float4x4 inverseViewProjection;
            packed_float3 cameraPos;
            float _pad;
            float4 fogColorDistance;
            float4 boundsMin;
            float4 boundsMax;
            float4 fogSurface;
            float4 fogParams;
        };

        struct FogVolumeOut {
            float4 position [[position]];
            float2 ndc;
        };

        float3 q3ResolvedFogColor(float3 fogRGB) {
            /* Task #19: pass the AUTHORED fogparms color through unmodified.
             * The old `< 0.001 → float3(0.36)` grey fallback assumed black
             * fog meant "parse failed", but vanilla shaders genuinely author
             * black fog (nvidia.shader `fogparms ( 0 0 0 ) 1024`, sfx.shader
             * xblackfog/xfinalfog/darkness) — the fallback turned those into
             * the white/grey slabs and wall bands seen on q3dm4 and the
             * NV15 chapel. If a fog ever renders the WRONG color now, the
             * parse-site + load-site `[Q3-FOG]` lines in q3_diag.log give
             * ground truth — fix the parse, not the shader output. */
            return max(fogRGB, 0.0);
        }

        vertex FogVolumeOut q3_fog_volume_vertex(uint vertexID [[vertex_id]],
                                                 constant FogVolumeUniforms &uniforms [[buffer(1)]]) {
            const float2 positions[3] = {
                float2(-1.0, -1.0),
                float2( 3.0, -1.0),
                float2(-1.0,  3.0)
            };
            FogVolumeOut out;
            float2 p = positions[vertexID];
            out.position = float4(p, 0.0, 1.0);
            out.ndc = p;
            return out;
        }

        fragment float4 q3_fog_volume_fragment(FogVolumeOut in [[stage_in]],
                                               constant FogVolumeUniforms &uniforms [[buffer(1)]],
                                               depth2d<float> sceneDepth [[texture(0)]]) {
            constexpr sampler depthSampler(coord::normalized, address::clamp_to_edge, filter::nearest);
            float2 depthSize = float2(float(sceneDepth.get_width()), float(sceneDepth.get_height()));
            float2 uv = (in.position.xy + float2(0.5)) / max(depthSize, float2(1.0));
            float sceneZ = sceneDepth.sample(depthSampler, uv);

            float3 bmin = uniforms.boundsMin.xyz;
            float3 bmax = uniforms.boundsMax.xyz;
            float4 farH = uniforms.inverseViewProjection * float4(in.ndc.xy, 1.0, 1.0);
            float3 farWorld = farH.xyz / max(farH.w, 1e-6);
            float3 origin = float3(uniforms.cameraPos);
            float3 dir = normalize(farWorld - origin);
            float3 safeDir = select(float3(1e-6), dir, abs(dir) > float3(1e-6));
            float3 invDir = 1.0 / safeDir;
            float3 t0 = (bmin - origin) * invDir;
            float3 t1 = (bmax - origin) * invDir;
            float3 tsmaller = min(t0, t1);
            float3 tbigger = max(t0, t1);
            float tEnter = max(max(tsmaller.x, tsmaller.y), tsmaller.z);
            float tExit = min(min(tbigger.x, tbigger.y), tbigger.z);
            float start = max(tEnter, 0.0);

            /* Clamp the ray-box integration to the scene depth.  The earlier
             * full-screen ray-box drew the whole fog box even when a wall or
             * ceiling was in front of it, making the mist look like a huge
             * misaligned box.  Reconstructing the visible world point keeps
             * the same true-volume behavior but stops at the first rendered
             * surface, matching how OpenGL Q3 fog is occluded by BSP depth. */
            float sceneT = 1.0e20;
            if (sceneZ < 0.999999) {
                float4 sceneH = uniforms.inverseViewProjection * float4(in.ndc.xy, sceneZ, 1.0);
                float3 sceneWorld = sceneH.xyz / max(sceneH.w, 1e-6);
                sceneT = max(dot(sceneWorld - origin, dir), 0.0);
            }
            float end = min(tExit, sceneT);
            float segment = max(end - start, 0.0);
            if (segment <= 0.0) {
                return float4(0.0);
            }

            float density = uniforms.fogParams.x > 0.0 ? uniforms.fogParams.x : 0.0013;
            float alpha = saturate(1.0 - exp(-segment * density));
            float3 fogRGB = q3ResolvedFogColor(uniforms.fogColorDistance.xyz);
            return float4(fogRGB, alpha);
        }

        struct WorldVertexOut {
            float4 position [[position]];
            float2 texCoord;
            float2 lightmapTexCoord;
            float4 color;
            // World-space vertex position. Needed so the fragment can
            // compute linear view distance for fog. Interpolated with
            // perspective correction automatically.
            float3 worldPos;
            // World-space vertex normal (smooth-interpolated). Zero
            // when the source path didn't supply normals — fragment
            // detects that and falls back to dfdx/dfdy face derivation.
            float3 worldNormal;
            // Per-vertex CGEN_LIGHTING_DIFFUSE — ambient + directed*Lambert
            // from the BSP lightgrid sampled at the vertex's world pos.
            // Smooth-interpolated; consumed by ComputeRGBGen mode 2.
            float3 lightingDiffuse;
        };

        /* Dynamic point light, matches C Q3MetalLight. */
        struct MSLLight {
            packed_float3 origin;
            float radius;
            packed_float3 color;
            float _pad;
        };

        /* Fragment-buffer(2) dlight block. count first, 12-byte pad aligns
         * the lights array to 16-byte boundary. */
        struct DLightBlock {
            uint count;
            uint _pad0;
            uint _pad1;
            uint _pad2;
            MSLLight lights[32];
        };

        /* Apply additive dlight contribution to a lit color. Each light is
         * a radial falloff: (1 - dist/radius)^2, clamped and scaled by color.
         * Called unconditionally by world + entity fragments except where the
         * stage blend mode explicitly masks it (filter/multiply would darken
         * the screen if we added to already-multiplied output). */
        float3 applyDlights(float3 lit,
                            float3 worldPos,
                            float3 surfaceNormal,
                            constant DLightBlock &block) {
            uint count = min(block.count, 32u);
            float3 accum = float3(0.0);
            float3 n = surfaceNormal;
            float nLen = length(n);
            bool hasNormal = nLen > 1e-4;
            if (hasNormal) {
                n /= nLen;
            }
            for (uint i = 0; i < count; ++i) {
                MSLLight L = block.lights[i];
                float r = max(L.radius, 1.0);
                float3 d = worldPos - float3(L.origin);
                float dist = length(d);
                float atten = saturate(1.0 - dist / r);
                atten = atten * atten;
                if (hasNormal && dist > 1e-4) {
                    /* Q3 dynamic lights are projected onto surfaces in an
                     * extra pass, not added as omnidirectional ambient. A
                     * normal-facing term prevents rocket/flame dlights from
                     * flooding through back sides and adjacent thin geometry
                     * while still leaving a small wrap term for curved meshes. */
                    float facing = saturate(dot(n, normalize(-d)));
                    atten *= (0.15 + 0.85 * facing);
                }
                accum += float3(L.color) * atten * 0.65;
            }
            /* Clamp accumulated contribution so stacked explosions don't
             * white out the scene. Dynamic lights are a polish layer over
             * baked lightmaps, not a replacement for Q3's projected dlight
             * pass. */
            accum = min(accum, float3(0.85));
            return lit + accum;
        }

        struct WorldDrawUniforms {
            float tcGen;
            int tcModCount;
            float rgbGen;
            float alphaGen;
            float blendMode;
            float timeSeconds;
            uint rgbWaveFunc;
            uint alphaWaveFunc;
            uint _wavePad;
            float4 tcModType;
            float4 tcModParams0;
            float4 tcModParams1;
            float4 tcModParams2;
            float4 tcModParams3;
            float4 rgbWaveParams;
            float4 alphaWaveParams;
            // CGEN_CONST tint + AGEN_CONST alpha. .xyz = const rgb, .w = const alpha.
            float4 rgbConstColor;
            // CGEN_ENTITY rgb + AGEN_ENTITY alpha. .xyz = entity rgb, .w = entity alpha.
            float4 entityColor;
            // Fog: xyz = color, w = distance (world units). w == 0 ⇒
            // no fog applies to this draw, fragment skips the mix.
            float4 fogColorDistance;
            // x = tcScale, y = has fog boundary surface.
            float4 fogParams;
            float4 fogSurface;
            // RTX Remix sprite-sheet atlas. .x=cols (0=no atlas),
            // .y=rows, .z=fps, .w=pad. World fragment remaps UV to
            // sub-rect when cols>0 (see albedo sample site).
            float4 spriteAtlasParams;
            // Emissive contribution. .xyz = sRGB tint, .w = intensity.
            // When .w > 0 the world fragment samples emissiveTexture and
            // adds (sample.rgb * tint * intensity) to finalColor.rgb.
            float4 emissiveParams;
            // tcGen vector basis. Only consulted when tcGen == 2.
            // s = dot(worldPos, tcGenVec0.xyz), t = dot(worldPos, tcGenVec1.xyz).
            float4 tcGenVec0;
            float4 tcGenVec1;
            // deformVertexes wave (shader-level). func 0 = no deform.
            uint  deformWaveFunc;
            float deformWaveDiv;
            float deformWaveBase;
            float deformWaveAmp;
            float deformWavePhase;
            float deformWaveFreq;
            uint  deformMoveFunc;
            float3 deformMoveVector;
            float deformMoveBase;
            float deformMoveAmp;
            float deformMovePhase;
            float deformMoveFreq;
            // deformVertexes bulge — see Swift WorldDrawUniforms / world
            // vertex shader for math + rationale.
            float deformBulgeWidth;
            float deformBulgeHeight;
            float deformBulgeSpeed;
            // deformVertexes autosprite mode (1=autosprite, 2=autoSprite2,
            // 0=none).
            uint  autospriteMode;
            float debugMode;
            float forceWhiteVertColor;
            float alphaTestThreshold;
            float fogOnly;
            float stageUsesLightmap;
            float drawHasLightmapStage;
            float pbrRoughness;
            float pbrMetallic;
            float _pad0;
            // Parallax params — LAST field, mirrors Swift struct tail.
            // .x = scale (0 = off), .y/.z/.w = pad.
            float4 parallaxParams;
        };

        /* Shared wave-function evaluator. Mirrors ioquake3's TableForFunc
         * + WAVEVALUE: phase wraps to [0,1), per-wave-shape value in
         * [-1,1] (sin/square/triangle) or [0,1] (sawtooth variants),
         * scaled by amplitude and offset by base. func: 1=sin,
         * 2=triangle, 3=square, 4=sawtooth, 5=inverse_sawtooth;
         * anything else falls back to sin. */
        float evalWave(uint func, float base, float amp, float phase, float freq, float timeSeconds) {
            float t = phase + timeSeconds * freq;
            float f = fract(t);
            float w;
            if (func == 3u) {
                w = (f < 0.5) ? 1.0 : -1.0;
            } else if (func == 4u) {
                w = f;
            } else if (func == 5u) {
                w = 1.0 - f;
            } else if (func == 2u) {
                /* triangle: 0 → 1 → 0 → -1 → 0 over one period */
                w = (f < 0.25) ? (4.0 * f)
                  : (f < 0.5)  ? (2.0 - 4.0 * f)
                  : (f < 0.75) ? (2.0 - 4.0 * f)
                               : (4.0 * f - 4.0);
            } else { /* 1=sin and fallback */
                w = sin(2.0 * 3.14159265 * f);
            }
            return base + w * amp;
        }

        /* ComputeRGBGen — exact ioq3 ComputeColors mapping using the
         * CURRENT Metal parser numbering at metal_renderer_stub.c:5503-
         * 5520. (Spec-literal CGEN_* numbering forbidden by the
         * directive's "DO NOT modify parser" rule.)
         *   0 IDENTITY         → (1,1,1)
         *   1 VERTEX/EXACTVERTEX → vertexColor
         *   2 LIGHTING_DIFFUSE → vertexColor   (BSP-baked diffuse already
         *                        lives in the per-vertex color stream;
         *                        ioq3 RB_CalcDiffuseColor recomputes
         *                        Lambert per-frame, but world surfaces
         *                        on iPad use the pre-baked path)
         *   3 WAVEFORM         → float3(waveVal) (replaces; doesn't
         *                        multiply by vertexColor — matches ioq3)
         *   4 CONST            → constColor.rgb
         *   5 ENTITY           → entityColor
         *   6 ONE_MINUS_ENTITY → (1,1,1) - entityColor
         *   7 IDENTITY_LIGHTING → (1,1,1) (parser doesn't emit; safety net)
         */
        float3 ComputeRGBGen(int rgbGen,
                             float3 vertexColor,
                             float4 constColor,
                             float3 entityColor,
                             float3 lightingDiffuse,
                             float waveVal) {
            switch (rgbGen) {
                case 1: return vertexColor;
                /* case 2 LIGHTING_DIFFUSE: per-vertex value pre-baked at
                 * world load by EmitWorldVertex calling SampleLightgrid +
                 * Lambert against the vertex normal (mirrors ioq3
                 * RB_CalcDiffuseColor / R_LightForPoint applied to world
                 * surfaces). Caller passes in.lightingDiffuse. */
                case 2: return lightingDiffuse;
                case 3: return float3(waveVal);
                case 4: return constColor.rgb;
                case 5: return entityColor;
                case 6: return float3(1.0) - entityColor;
                case 0: case 7: default: return float3(1.0);
            }
        }

        /* ComputeAlphaGen — ioq3 alphaGen, current Metal parser numbering
         * (parser switch at metal_renderer_stub.c:5578-5589).
         *   0 IDENTITY         → 1.0
         *   1 VERTEX           → vertexAlpha
         *   3 WAVEFORM         → waveVal
         *   4 CONST            → constAlpha
         *   5 ENTITY           → entityAlpha
         *   6 ONE_MINUS_ENTITY → 1.0 - entityAlpha
         */
        float ComputeAlphaGen(int alphaGen,
                              float vertexAlpha,
                              float constAlpha,
                              float entityAlpha,
                              float waveVal) {
            switch (alphaGen) {
                case 1: return vertexAlpha;
                case 3: return waveVal;
                case 4: return constAlpha;
                case 5: return entityAlpha;
                case 6: return 1.0 - entityAlpha;
                case 0: default: return 1.0;
            }
        }

        float2 applyTcMod(float2 uv, float3 worldPos, int type, float4 params, float timeSeconds) {
            if (type == 1) {
                float2 adj = params.xy * timeSeconds;
                adj -= floor(adj);
                return uv + adj;
            } else if (type == 2) {
                float s = sin(timeSeconds * params.w) * params.y;
                return uv + float2(s, s);
            } else if (type == 3) {
                /* Params are signed degrees/second. Convert exactly once. */
                float degrees = fmod(params.x * timeSeconds, 360.0);
                float a = degrees * (3.14159265 / 180.0);
                float c = cos(a);
                float s = sin(a);
                float2 p = uv - 0.5;
                return float2(p.x * c - p.y * s, p.x * s + p.y * c) + 0.5;
            } else if (type == 4) {
                return uv * params.xy;
            } else if (type == 5) {
                /* Turbulent: upstream RB_CalcTurbulentTexCoords samples
                 * tr.sinTable with world-space xyz as the domain, NOT UV
                 * space. params = (amp, freq, phase, _). The expression
                 * `1/128 * 0.125 = 1/1024` matches upstream's world-unit
                 * scale so e.g. a 1024-unit-wide lava pool sees one full
                 * sin cycle of perturbation in-plane. */
                float amp = params.x;
                float freq = params.y;
                float phase = params.z;
                float now = fract(phase + timeSeconds * freq);
                float kX = (worldPos.x + worldPos.z) * (1.0 / 1024.0) + now;
                float kY = worldPos.y * (1.0 / 1024.0) + now;
                float twoPi = 2.0 * 3.14159265;
                return uv + float2(sin(kX * twoPi) * amp,
                                   sin(kY * twoPi) * amp);
            } else if (type == 6) {
                /* stretch: sin-wave zoom about texture center.
                 * params = (base, amp, phase, freq). Mirrors
                 * RB_CalcStretchTexCoords: eval = base + sin(2π(phase +
                 * t*freq)) * amp; p = 1/eval; dst = (uv-0.5)*p + 0.5.
                 * Guard eval==0 since upstream would divide by zero on
                 * an ill-configured shader; nudge to 1.0 to keep UVs
                 * sane and matching identity. */
                float angle = 2.0 * 3.14159265 * (params.z + timeSeconds * params.w);
                float eval = params.x + sin(angle) * params.y;
                if (abs(eval) < 0.0001) eval = 1.0;
                float p = 1.0 / eval;
                return (uv - 0.5) * p + 0.5;
            } else if (type == 7) {
                return float2(
                    uv.x * params.x + uv.y * params.y,
                    uv.x * params.z + uv.y * params.w
                );
            } else if (type == 8) {
                return uv + params.xy;
            }
            return uv;
        }

        /* Stock Q3's fog is sampled from a 256x32 fog ramp image whose
         * texels are generated by R_FogFactor() (see ioq3 tr_shade_calc.c).
         * The previous depth-based sqrt(saturate(depth*fogParams.x))
         * approximation returned a SINGLE coordinate that ignored the
         * fog-volume plane, which made q3dm4's pit fog render as a flat
         * white quad covering the whole surface. This version emulates
         * the actual image sample via bilinear filtering and the
         * fogSurface plane clip, matching what stock GL produces.
         * Ported from /tmp/q3_deepseek_overscope.patch. */

        float q3FogDirectFactor(float sCoord, float tCoord) {
            float s = sCoord - (1.0 / 512.0);
            float t = tCoord;
            if (s < 0.0 || t < (1.0 / 32.0)) {
                return 0.0;
            }
            if (t < (31.0 / 32.0)) {
                s *= (t - 1.0 / 32.0) / (30.0 / 32.0);
            }
            s *= 8.0;
            return sqrt(saturate(s));
        }
        float q3FogImageFactor(float sCoord, float tCoord) {
            /* Emulate linear sampling of tr.fogImage (FOG_S=256, FOG_T=32,
             * clamp-to-edge). The direct R_FogFactor approximation alone
             * returned exactly zero at T=1/32, which made q3dm4's visible
             * fog surface disappear even though stock GL samples halfway
             * into the first non-zero fog-image row. */
            constexpr float fogS = 256.0;
            constexpr float fogT = 32.0;
            float u = clamp(sCoord, 0.0, 1.0) * fogS - 0.5;
            float v = clamp(tCoord, 0.0, 1.0) * fogT - 0.5;
            float u0f = floor(u);
            float v0f = floor(v);
            float fu = clamp(u - u0f, 0.0, 1.0);
            float fv = clamp(v - v0f, 0.0, 1.0);
            float u0 = (clamp(u0f, 0.0, fogS - 1.0) + 0.5) / fogS;
            float u1 = (clamp(u0f + 1.0, 0.0, fogS - 1.0) + 0.5) / fogS;
            float v0 = (clamp(v0f, 0.0, fogT - 1.0) + 0.5) / fogT;
            float v1 = (clamp(v0f + 1.0, 0.0, fogT - 1.0) + 0.5) / fogT;
            float a00 = q3FogDirectFactor(u0, v0);
            float a10 = q3FogDirectFactor(u1, v0);
            float a01 = q3FogDirectFactor(u0, v1);
            float a11 = q3FogDirectFactor(u1, v1);
            return mix(mix(a00, a10, fu), mix(a01, a11, fu), fv);
        }
        struct Q3FogTexCoord { float s; float t; };
        Q3FogTexCoord q3FogTexCoords(float3 worldPos,
                                     constant WorldUniforms &uniforms,
                                     constant WorldDrawUniforms &drawUniforms) {
            Q3FogTexCoord out;
            out.s = -1.0;
            out.t = 0.0;
            if (drawUniforms.fogColorDistance.w <= 0.0 ||
                drawUniforms.fogParams.x <= 0.0) {
                return out;
            }
            /* WorldUniforms stores screen-right and up.  Q3 fog S is
             * forward distance from the eye.  right×up = forward; the
             * old up×right returned -forward, driving S negative for
             * visible geometry and making stock per-surface fog vanish. */
            float3 forward = normalize(cross(float3(uniforms.cameraRight),
                                             float3(uniforms.cameraUp)));
            float s = dot(worldPos - float3(uniforms.cameraPos), forward) *
                      drawUniforms.fogParams.x + (1.0 / 512.0);
            float t = 31.0 / 32.0;
            if (drawUniforms.fogParams.y > 0.5) {
                /* ioq3 stores fog.surface[3] as -plane.dist, then
                 * RB_CalcFogTexCoords builds fogDepthVector[3] as
                 * -fog->surface[3] for world geometry. The sign flip
                 * (-surface.w, was +surface.w earlier) treats cameras
                 * above q3dm4's low fog volume as inside, so the real
                 * pit fog is no longer clipped away. */
                float4 surface = drawUniforms.fogSurface;
                t = dot(worldPos, surface.xyz) - surface.w;
                float eyeT = dot(float3(uniforms.cameraPos), surface.xyz) - surface.w;
                if (eyeT < 0.0) {
                    if (t < 1.0) {
                        t = 1.0 / 32.0;
                    } else {
                        t = 1.0 / 32.0 + (30.0 / 32.0 * t) / (t - eyeT);
                    }
                } else {
                    t = (t < 0.0) ? (1.0 / 32.0) : (31.0 / 32.0);
                }
            }
            out.s = s;
            out.t = t;
            return out;
        }
        float q3FogFactor(float3 worldPos,
                          constant WorldUniforms &uniforms,
                          constant WorldDrawUniforms &drawUniforms) {
            Q3FogTexCoord st = q3FogTexCoords(worldPos, uniforms, drawUniforms);
            if (st.s < 0.0 || st.t < (1.0 / 32.0)) {
                return 0.0;
            }
            return saturate(q3FogImageFactor(st.s, st.t));
        }

        struct EntityVertexIn {
            float3 position;
            float2 texCoord;
            float4 color;
            float3 normal;
        };
        // NOTE 2026-06-01: tried packed_float3 swap here to match the
        // tightly-packed C Q3MetalEntityVertex (48 bytes vs MSL float3-
        // padded 56). The Geometry tab on a flare draw clearly showed
        // negative-w vertices producing radial bursts, so the misalignment
        // hypothesis seemed right. But the packed_float3 build turned fog
        // green and killed rocket-explosion brightness — so something
        // upstream is already compensating for the stride mismatch (the
        // CPU upload path probably re-lays the vertices to MSL-aligned
        // 56 bytes before binding, or there's a hidden vertex descriptor).
        // The diagonal "light ray" turned out to be a real BSP lens flare
        // (light_flare entity), not a geometry bug. If we ever DO need
        // to revisit struct alignment, audit how Q3MetalRenderer_Get*
        // buffers are uploaded first.

        struct EntityUniforms {
            float4x4 viewProjection;
            /* Mirrors Swift-side struct — MSL packs float3 on 16-byte
             * boundaries, so the explicit pads keep offsets aligned with
             * the Swift layout. Read by q3_entity_fragment for tcGen env. */
            float3 cameraPos;
            float3 cameraForward;
            float  tcGen;
            float  timeSeconds;
            int    tcModCount;
            float  alphaTestThreshold;
            float4 tcModType;
            float4 tcModParams0;
            float4 tcModParams1;
            float4 tcModParams2;
            float4 tcModParams3;
            uint rgbGenMode;
            uint alphaGenMode;
            uint rgbWaveFunc;
            uint alphaWaveFunc;
            float4 rgbGenWaveParams;
            float4 alphaGenWaveParams;
            float4 rgbConstColor;
            float4 entityColor;
            float4 fogColorDistance;
            float4 fogParams;
            float4 fogSurface;
            uint suppressDlights;
            uint forceLuminanceAlpha;
            /* deformVertexes wave (shader-level). Applied in
             * q3_entity_vertex when deformWaveFunc != 0. Matches the
             * world pipeline's deform formula exactly. */
            uint  deformWaveFunc;
            float deformWaveDiv;
            float deformWaveBase;
            float deformWaveAmp;
            float deformWavePhase;
            float deformWaveFreq;
            // RTX Remix sprite-sheet atlas. .x=cols (0=no atlas), .y=rows,
            // .z=fps, .w=pad. Entity fragment remaps UV when cols>0.
            float4 spriteAtlasParams;
            // Emissive contribution. .xyz = sRGB tint, .w = intensity.
            // Same semantics as WorldDrawUniforms.emissiveParams.
            float4 emissiveParams;
            // 2026-06-10: viewmodel-only PBR base-color floor.
            // .x = floor strength (r_pbr_viewmodel_floor, default 0.35)
            // .y = viewmodel gate (1.0 for RF_DEPTHHACK, 0.0 otherwise)
            // .z, .w = pad. Fragment applies `base.rgb = max(base.rgb,
            // texel.rgb * .x)` only when `.y > 0.5`. Layout MUST match
            // Swift `EntityUniforms.viewmodelParams` (placed AFTER
            // emissiveParams) — moving this above emissiveParams scrambles
            // the GPU read offsets.
            float4 viewmodelParams;
        };

        float q3EntityFogFactor(float3 worldPos,
                                constant EntityUniforms &uniforms) {
            if (uniforms.fogColorDistance.w <= 0.0 ||
                uniforms.fogParams.x <= 0.0) {
                return 0.0;
            }

            float s = dot(worldPos - uniforms.cameraPos,
                          normalize(uniforms.cameraForward)) *
                      uniforms.fogParams.x + (1.0 / 512.0);
            float t = 31.0 / 32.0;

            if (uniforms.fogParams.y > 0.5) {
                float4 surface = uniforms.fogSurface;
                t = dot(worldPos, surface.xyz) - surface.w;
                float eyeT = dot(uniforms.cameraPos, surface.xyz) - surface.w;
                if (eyeT < 0.0) {
                    if (t < 1.0) {
                        t = 1.0 / 32.0;
                    } else {
                        t = 1.0 / 32.0 + (30.0 / 32.0 * t) / (t - eyeT);
                    }
                } else {
                    t = (t < 0.0) ? (1.0 / 32.0) : (31.0 / 32.0);
                }
            }

            if (s < 0.0 || t < (1.0 / 32.0)) {
                return 0.0;
            }
            return saturate(q3FogImageFactor(s, t));
        }

        struct EntityVertexOut {
            float4 position [[position]];
            float2 texCoord;
            float4 color;
            // World-space position — entity verts are pre-transformed to
            // world space C-side so this is a direct pass-through.
            float3 worldPos;
            // World-space normal. Zero vector means "no normal supplied"
            // (sprite / beam / synthetic overlay); the fragment falls
            // back to a flat face normal via dfdx/dfdy of worldPos.
            float3 normal;
        };

        vertex WorldVertexOut q3_world_vertex(const device WorldVertexIn *vertices [[buffer(0)]],
                                              constant WorldUniforms &uniforms [[buffer(1)]],
                                              constant WorldDrawUniforms &drawUniforms [[buffer(2)]],
                                              uint vertexID [[vertex_id]]) {
            WorldVertexOut out;
            WorldVertexIn inVertex = vertices[vertexID];
            float3 worldPos = inVertex.position;
            /* deformVertexes wave: shader-level position deform.
             *   spread = 1 / div
             *   off    = (xyz.x + xyz.y + xyz.z) * spread
             *   scale  = wave(func, base, amp, phase + off, freq, time)
             *   pos   += normal * scale
             * Mirrors ioq3 DeformVertex_Wave (tr_shade_calc.c). func == 0
             * means no deform — common path branchless on most vertices
             * because the uniform value is constant per draw.
             *
             * Skip when length(normal) is near zero (legacy verts that
             * didn't fill the normal slot) to avoid a NaN axis. */
            if (drawUniforms.deformWaveFunc != 0u) {
                float3 n = inVertex.normal;
                float nLen = length(n);
                if (nLen > 1e-4) {
                    n /= nLen;
                    float spread = 1.0 / drawUniforms.deformWaveDiv;
                    float off = (worldPos.x + worldPos.y + worldPos.z) * spread;
                    float scale = evalWave(drawUniforms.deformWaveFunc,
                                           drawUniforms.deformWaveBase,
                                           drawUniforms.deformWaveAmp,
                                           drawUniforms.deformWavePhase + off,
                                           drawUniforms.deformWaveFreq,
                                           drawUniforms.timeSeconds);
                    worldPos += n * scale;
                }
            }
            /* deformVertexes bulge — per-vertex ST-coord-driven sine
             * displacement along normal. Closes the q3dm4 gothic_block /
             * wallhead organic tube/vein decoration gap (PC has them
             * undulating; iOS rendered them static because bulge was
             * silently unimplemented). Mirrors ioq3 RB_DeformTessGeometry
             * DEFORM_BULGE case from tr_shade_calc.c:
             *   phase = st.s * bulgeWidth + time * bulgeSpeed
             *   scale = sin(phase) * bulgeHeight
             *   pos  += normal * scale
             * Gated on bulgeWidth > 0 because canonical Q3 shaders only
             * specify bulge when actively using it (no default == 0
             * sentinel needed for the func bit). Uses the same per-vertex
             * normal as the wave deform above; same length-check guard
             * for sprite/beam vertices that didn't fill the normal slot. */
            if (drawUniforms.deformBulgeWidth != 0.0 ||
                drawUniforms.deformBulgeHeight != 0.0) {
                float3 nb = inVertex.normal;
                float nbLen = length(nb);
                if (nbLen > 1e-4) {
                    nb /= nbLen;
                    float bulgePhase = inVertex.texCoord.x * drawUniforms.deformBulgeWidth +
                                       drawUniforms.timeSeconds * drawUniforms.deformBulgeSpeed;
                    float bulgeScale = sin(bulgePhase) * drawUniforms.deformBulgeHeight;
                    worldPos += nb * bulgeScale;
                }
            }
            if (drawUniforms.deformMoveFunc != 0u) {
                float scale = evalWave(drawUniforms.deformMoveFunc,
                                       drawUniforms.deformMoveBase,
                                       drawUniforms.deformMoveAmp,
                                       drawUniforms.deformMovePhase,
                                       drawUniforms.deformMoveFreq,
                                       drawUniforms.timeSeconds);
                worldPos += drawUniforms.deformMoveVector * scale;
            }
            /* deformVertexes autosprite (mode 1): camera-aligned
             * billboard. Replaces the authored corner position with
             *   newPos = center + cameraRight * radius * sign(dot(offset, R))
             *                   + cameraUp    * radius * sign(dot(offset, U))
             * where offset = position - center and radius =
             * length(offset) * sqrt(2)/2. Matches ioq3 RB_AddQuadStampExt
             * substituted into RB_AutospriteDeform's per-quad emit step.
             *
             * Skip when autospriteCenter is zero (vertex is not part of
             * an autosprite quad — center bake at BSP load left it 0). */
            if (drawUniforms.autospriteMode == 1u
                && length(inVertex.autospriteCenter.xyz) > 1e-4) {
                float3 center = inVertex.autospriteCenter.xyz;
                float3 offset = worldPos - center;
                float  radius = length(offset) * 0.7071068;
                float  lProj  = dot(offset, float3(uniforms.cameraRight));
                float  uProj  = dot(offset, float3(uniforms.cameraUp));
                float  lSign  = lProj >= 0.0 ?  1.0 : -1.0;
                float  uSign  = uProj >= 0.0 ?  1.0 : -1.0;
                worldPos = center
                         + float3(uniforms.cameraRight) * (lSign * radius)
                         + float3(uniforms.cameraUp)    * (uSign * radius);
            }
            /* deformVertexes autoSprite2 (mode 2): elongated billboard.
             * Preserves the quad's authored long axis; only the
             * perpendicular short axis is camera-aligned. Used by lamp
             * wires, chains, exhaust trails, jets — geometry whose
             * long-axis orientation is meaningful and must not collapse.
             * Mirrors ioq3 RB_Autosprite2Deform (tr_shade_calc.c).
             *
             *   along       = dot(offset, longAxis)
             *   perpOffset  = offset − longAxis * along
             *   perpAxis    = normalize(cameraRight − longAxis * dot(R, L))
             *               (or cameraUp if R is nearly parallel to L)
             *   perpSign    = sign(dot(perpOffset, perpAxis))
             *   newPos      = center + longAxis * along
             *                        + perpAxis * (perpSign * |perpOffset|)
             *
             * Skip when long axis is zero (vertex not part of an
             * autoSprite2 quad). */
            if (drawUniforms.autospriteMode == 2u
                && length(inVertex.autospriteCenter.xyz) > 1e-4
                && length(inVertex.autospriteLongAxis.xyz) > 1e-4) {
                float3 center   = inVertex.autospriteCenter.xyz;
                float3 longAxis = inVertex.autospriteLongAxis.xyz;
                float3 offset   = worldPos - center;
                float  along    = dot(offset, longAxis);
                float3 perpOffset = offset - longAxis * along;
                float  perpLen  = length(perpOffset);
                float3 cR = float3(uniforms.cameraRight);
                float3 perpFromR = cR - longAxis * dot(cR, longAxis);
                float  perpFromR_len = length(perpFromR);
                float3 perpAxis;
                if (perpFromR_len > 1e-3) {
                    perpAxis = perpFromR / perpFromR_len;
                } else {
                    float3 cU = float3(uniforms.cameraUp);
                    float3 perpFromU = cU - longAxis * dot(cU, longAxis);
                    float perpFromU_len = length(perpFromU);
                    perpAxis = perpFromU_len > 1e-3
                             ? perpFromU / perpFromU_len
                             : float3(0.0, 0.0, 1.0);
                }
                float perpSign = dot(perpOffset, perpAxis) >= 0.0 ? 1.0 : -1.0;
                worldPos = center
                         + longAxis * along
                         + perpAxis * (perpSign * perpLen);
            }
            out.position = uniforms.viewProjection * float4(worldPos, 1.0);
            out.texCoord = inVertex.texCoord;
            out.lightmapTexCoord = inVertex.lightmapTexCoord;
            out.color = inVertex.color;
            // Pass through world-space position for the fog distance
            // calculation in the fragment. Cheap; perspective-correct
            // interpolation is what we want for linear fog.
            out.worldPos = worldPos;
            // Smooth per-vertex normal. Pre-normalized at parse time
            // (drawVert_t.normal); after rasterizer interpolation the
            // fragment renormalizes before reflection math.
            out.worldNormal = inVertex.normal;
            // Pre-baked CGEN_LIGHTING_DIFFUSE: ambient + directed*Lambert
            // sampled C-side from the BSP lightgrid against the vertex
            // normal. Smooth-interpolated by the rasterizer; consumed by
            // ComputeRGBGen mode 2 in the fragment.
            out.lightingDiffuse = inVertex.lightingDiffuse;
            return out;
        }

        fragment float4 q3_world_fragment(WorldVertexOut in [[stage_in]],
                                          constant WorldDrawUniforms &drawUniforms [[buffer(0)]],
                                          constant WorldUniforms &uniforms [[buffer(1)]],
                                          constant DLightBlock &dlights [[buffer(2)]],
                                          constant float4 &pbrWorldParams [[buffer(3)]],
                                          texture2d<float> colorTexture [[texture(0)]],
                                          texture2d<float> lightmapTexture [[texture(1)]],
                                          texture2d<float> worldNormalMap [[texture(2)]],
                                          texturecube<float> envCube [[texture(3)]],
                                          texture2d<float> roughnessMap [[texture(4)]],
                                          texture2d<float> metallicMap [[texture(5)]],
                                          texture2d<float> emissiveTexture [[texture(6)]],
                                          texture2d<float> heightMap [[texture(7)]],
                                          sampler textureSampler [[sampler(0)]],
                                          sampler envSampler [[sampler(1)]]) {
            float2 texCoord = in.texCoord;
            int rgbGen = int(drawUniforms.rgbGen + 0.5);
            int alphaGen = int(drawUniforms.alphaGen + 0.5);
            int blendMode = int(drawUniforms.blendMode + 0.5);
            bool additiveStage = (blendMode == 1 || blendMode == 5);
            /* tcGen modes:
             *   0 (default) — base UVs, mesh ST as authored.
             *   1 (environment) — chrome/reflective surfaces. Compute
             *       reflection vector and project per RB_CalcEnvironmentTexCoords
             *       (s = 0.5 + refl.y*0.5, t = 0.5 - refl.z*0.5). Prefer the
             *       smooth per-vertex normal (drawVert_t.normal interpolated
             *       by the rasterizer); fall back to dfdx/dfdy face normal of
             *       worldPos when the vertex normal is zero. Smooth path makes
             *       bezier-patch chrome stop looking faceted.
             *   2 (vector) — basis-projection. Per RB_CalcTexCoords TCGEN_VECTOR:
             *       s = dot(worldPos, tcGenVec0.xyz)
             *       t = dot(worldPos, tcGenVec1.xyz)
             *       Used by lava/water surfaces and a handful of parametric
             *       shaders. tcMod chain still applies AFTER. */
            int tcGenMode = int(drawUniforms.tcGen + 0.5);
            if (tcGenMode == 1) {
                float3 n;
                float nLen = length(in.worldNormal);
                if (nLen > 1e-4) {
                    n = in.worldNormal / nLen;
                } else {
                    float3 dx = dfdx(in.worldPos);
                    float3 dy = dfdy(in.worldPos);
                    n = normalize(cross(dx, dy));
                }
                float3 viewer = normalize(uniforms.cameraPos - in.worldPos);
                float d = 2.0 * dot(viewer, n);
                float3 refl = n * d - viewer;
                texCoord = float2(0.5 + refl.y * 0.5, 0.5 - refl.z * 0.5);
            } else if (tcGenMode == 2) {
                texCoord = float2(
                    dot(in.worldPos, drawUniforms.tcGenVec0.xyz),
                    dot(in.worldPos, drawUniforms.tcGenVec1.xyz)
                );
            } else if (tcGenMode == 4) {
                /* TCGEN_LIGHTMAP. Mirrors ioq3. The Swift draw loop sets
                 * tcGen=4 when stage.useLightmap != 0; the bound
                 * colorTexture for that stage IS the lightmap. */
                texCoord = in.lightmapTexCoord;
            }
            // tcMod chain — apply in order. Q3 shaders stack mods (e.g. scale
            // then scroll); order matters and cannot be reduced to one slot.
            int modCount = drawUniforms.tcModCount;
            int4 tcModTypes = int4(drawUniforms.tcModType + 0.5);
            if (modCount > 0) texCoord = applyTcMod(texCoord, in.worldPos, tcModTypes.x, drawUniforms.tcModParams0, drawUniforms.timeSeconds);
            if (modCount > 1) texCoord = applyTcMod(texCoord, in.worldPos, tcModTypes.y, drawUniforms.tcModParams1, drawUniforms.timeSeconds);
            if (modCount > 2) texCoord = applyTcMod(texCoord, in.worldPos, tcModTypes.z, drawUniforms.tcModParams2, drawUniforms.timeSeconds);
            if (modCount > 3) texCoord = applyTcMod(texCoord, in.worldPos, tcModTypes.w, drawUniforms.tcModParams3, drawUniforms.timeSeconds);

            /* RTX Remix sprite-sheet atlas sub-rect sampling. When the
             * bound PBR albedo is a `*_animation` DDS, the texture is a
             * cols×rows grid of frames. Pick the current frame by
             * (time * fps), then remap UV from full [0,1]² to the
             * frame's sub-rect [(col/cols), ((col+1)/cols)] ×
             * [(row/rows), ((row+1)/rows)]. Applies to albedo +
             * roughness + metallic since they share the atlas grid via
             * materials.json remixConstants.sprite_sheet_*. */
            if (drawUniforms.spriteAtlasParams.x > 0.5) {
                float aCols  = drawUniforms.spriteAtlasParams.x;
                float aRows  = drawUniforms.spriteAtlasParams.y;
                float aFps   = drawUniforms.spriteAtlasParams.z;
                float aTotal = aCols * aRows;
                float atlasTime = (drawUniforms.spriteAtlasParams.w > 0.0) ? drawUniforms.spriteAtlasParams.w : drawUniforms.timeSeconds;
                float frame  = floor(atlasTime * aFps);
                float idx    = fmod(frame, aTotal);
                if (idx < 0.0) { idx += aTotal; }
                float col = fmod(idx, aCols);
                float row = floor(idx / aCols);
                // fract() so upstream tcMod scrolls past [0,1] still
                // tile within the frame's sub-rect.
                float2 localUV = fract(texCoord);
                texCoord = float2((localUV.x + col) / aCols,
                                  (localUV.y + row) / aRows);
            }
            /* Parallax (height-map) offset — derivative-built tangent
             * frame, 8-step linear search. Gated on parallaxParams.x > 0
             * (cvar r_pbr_parallax_scale, only written when the material
             * actually ships a height map) and base tcGen only —
             * environment/vector/lightmap UVs have no meaningful height
             * relationship. Mutates texCoord in place so albedo, normal,
             * roughness, metallic, and emissive all sample the displaced
             * UV. */
            if (drawUniforms.parallaxParams.x > 0.0001 && tcGenMode == 0 &&
                !is_null_texture(heightMap)) {
                float3 pdx = dfdx(in.worldPos);
                float3 pdy = dfdy(in.worldPos);
                float2 tdx = dfdx(texCoord);
                float2 tdy = dfdy(texCoord);
                float3 Np = normalize(cross(pdx, pdy));
                float3 V = normalize(uniforms.cameraPos - in.worldPos);
                if (dot(Np, V) < 0.0) { Np = -Np; }
                float3 dp2perp = cross(pdy, Np);
                float3 dp1perp = cross(Np, pdx);
                float3 T = dp2perp * tdx.x + dp1perp * tdy.x;
                float3 B = dp2perp * tdx.y + dp1perp * tdy.y;
                float invmax = rsqrt(max(max(dot(T, T), dot(B, B)), 1e-12));
                float3 vT = float3(dot(V, T * invmax), dot(V, B * invmax), dot(V, Np));
                if (vT.z > 0.05) {
                    float scale = drawUniforms.parallaxParams.x;
                    float2 dir = vT.xy / vT.z * scale;
                    // 8-step layered search, then one secant refine.
                    const int steps = 8;
                    float layer = 1.0 / float(steps);
                    float depth = 0.0;
                    float2 uv = texCoord;
                    float h = 1.0 - heightMap.sample(textureSampler, uv).r;
                    float prevH = h;
                    for (int s = 0; s < steps && depth < h; ++s) {
                        prevH = h;
                        uv -= dir * layer;
                        depth += layer;
                        h = 1.0 - heightMap.sample(textureSampler, uv).r;
                    }
                    float after = h - depth;
                    float before = prevH - (depth - layer);
                    float w = saturate(before / max(before - after, 1e-5));
                    texCoord = mix(uv + dir * layer, uv, w);
                }
            }
            /* Always sample the per-stage colorTexture using the tcGen-
             * resolved texCoord. For lightmap stages tcGenMode==4 above
             * routed texCoord to lightmapTexCoord and colorTexture *is*
             * the lightmap. Stage-driven via tcGen, no flag branch. */
            float4 texel = colorTexture.sample(textureSampler, texCoord);
            int mode = int(drawUniforms.debugMode + 0.5);
            if (mode == 1) {
                return float4(texel.rgb, 1.0);
            }
            if (mode == 2) {
                /* Debug mode 2 still samples the global lightmap binding
                 * for a "lightmap only" overlay. Localized so the read
                 * doesn't fire on the normal path. */
                float4 lightmap = lightmapTexture.sample(textureSampler, in.lightmapTexCoord);
                return float4(lightmap.rgb, 1.0);
            }
            if (mode == 3) {
                return float4(fract(in.lightmapTexCoord.x), fract(in.lightmapTexCoord.y), 0.0, 1.0);
            }
            if (mode == 4) {
                return float4(in.color.rgb, 1.0);
            }
            if (drawUniforms.fogOnly > 0.5) {
                if (drawUniforms.fogColorDistance.w <= 0.0) {
                    return float4(0.0);
                }
                float f = q3FogFactor(in.worldPos, uniforms, drawUniforms);
                if (drawUniforms._pad0 > 0.5) {
                    /* Explicit fog-volume boundary sheets (xdensegreyfog in
                     * q3dm4) are authored as the visible fog cap, not as an
                     * opaque box. Only keep a low floor on faces whose normal
                     * is parallel to the fog surface plane. Side faces keep
                     * the stock fog-image value so the volume does not read as
                     * a hard rectangular wall when the camera moves inside or
                     * below the pit. */
                    float capFloor = 0.0;
                    if (drawUniforms.fogParams.y > 0.5) {
                        float3 fogN = drawUniforms.fogSurface.xyz;
                        float fogNLen = length(fogN);
                        if (fogNLen > 1e-4) {
                            fogN /= fogNLen;
                            float3 n = in.worldNormal;
                            float nLen = length(n);
                            if (nLen > 1e-4) {
                                n /= nLen;
                            } else {
                                float3 dx = dfdx(in.worldPos);
                                float3 dy = dfdy(in.worldPos);
                                n = normalize(cross(dx, dy));
                            }
                            float capAlign = abs(dot(n, fogN));
                            capFloor = (capAlign > 0.70) ? 0.24 : 0.0;
                        }
                    } else {
                        capFloor = 0.18;
                    }
                    f = max(f, capFloor);
                }
                return float4(q3ResolvedFogColor(drawUniforms.fogColorDistance.xyz), saturate(f));
            }

            // NOTE: No unconditional alpha-test discard here.
            //
            // ef21f24 introduced `if (result.a < 0.01) discard_fragment();` to
            // emulate GL alphaFunc, but Q3 alpha-test is a PER-SHADER-STAGE opt-in
            // (the `alphaFunc GT0|GE128|LT128` keyword on a stage), not a
            // world-wide rule. Forcing it on every fragment made q3dm1's two
            // ornamental arches go see-through whenever their stage0 texture
            // failed to resolve (see HUD "falling back to white" errors) or when
            // lightmap*vertexColor multiplied alpha below threshold.
            //
            // Until the per-stage shader driver is in place, world fragments must
            // always write. Alpha-tested stages will be reintroduced through the
            // Q3 shader parser, not as a global discard.
            //
            // Overbright: Q3 lightmaps are authored expecting a 2x boost (stock
            // r_overBrightBits default = 1, i.e. multiply by 2^1). Without the
            // boost the whole world renders at half brightness — user reported
            // the game was 'awfully dark even with phone brightness all the way
            // up'. saturate() clamps to [0,1] so bright spots don't wrap.
            // Per-shader alphaFunc: GT0 / GE128 / LT128.
            // Threshold >0 → discard if alpha < threshold (GT0=0.004, GE128=0.5)
            // Threshold <0 → discard if alpha >= |threshold| (LT128=-0.5)
            if (drawUniforms.alphaTestThreshold > 0.0) {
                if (texel.a < drawUniforms.alphaTestThreshold) discard_fragment();
            } else if (drawUniforms.alphaTestThreshold < 0.0) {
                if (texel.a >= -drawUniforms.alphaTestThreshold) discard_fragment();
            }

            /* Stage color via ioq3 ComputeColors helpers. No rgbGen↔
             * lightmap coupling, no blend-based force-white. Lightmap
             * stages receive vc=(1,1,1) naturally via parser
             * rgbGen=identity, and their GL_DST_COLOR/GL_ZERO blend
             * (worldFilterPipelineState) handles the framebuffer
             * multiply. Mode 2 (LIGHTING_DIFFUSE) returns vertex color
             * since BSP-baked diffuse already lives there. */
            float4 wp = drawUniforms.rgbWaveParams;
            float waveRGB = clamp(evalWave(drawUniforms.rgbWaveFunc,
                                           wp.x, wp.y, wp.z, wp.w,
                                           drawUniforms.timeSeconds),
                                  0.0, 1.0);
            float4 ap = drawUniforms.alphaWaveParams;
            float waveA = clamp(evalWave(drawUniforms.alphaWaveFunc,
                                         ap.x, ap.y, ap.z, ap.w,
                                         drawUniforms.timeSeconds),
                                0.0, 1.0);
            float3 vc = ComputeRGBGen(rgbGen,
                                      in.color.rgb,
                                      drawUniforms.rgbConstColor,
                                      drawUniforms.entityColor.xyz,
                                      in.lightingDiffuse,
                                      waveRGB);
            float va = ComputeAlphaGen(alphaGen,
                                       in.color.a,
                                       drawUniforms.rgbConstColor.w,
                                       drawUniforms.entityColor.w,
                                       waveA);
            float3 lit = texel.rgb * vc;
            if (drawUniforms._pad0 > 0.5) {
                /* Combined base+lightmap fast path for simple opaque world
                 * surfaces. Equivalent to Q3's base pass followed by the
                 * GL_DST_COLOR/GL_ZERO lightmap pass, but avoids one Metal
                 * encoder draw for the common case. Complex multi-stage
                 * shaders still use explicit stage draws. */
                float3 lm = lightmapTexture.sample(textureSampler, in.lightmapTexCoord).rgb;
                lit *= lm;
            }
            /* Dynamic lights only on non-additive stages — ioq3 runs
             * dlights as a separate iteration that skips src=ONE
             * additive blends; we don't have that separate iteration so
             * we gate inline. */
            if (!additiveStage) {
                float3 dlightN = in.worldNormal;
                if (length(dlightN) <= 1e-4) {
                    float3 dx = dfdx(in.worldPos);
                    float3 dy = dfdy(in.worldPos);
                    dlightN = normalize(cross(dx, dy));
                }
                lit = applyDlights(lit, in.worldPos, dlightN, dlights);
            }
            /* PBR Phase 3 — uniform world normal-map relief.
             *
             * When a normal map is bound at slot 2 (Swift binds one
             * generic metal-plate normal for ALL world surfaces when
             * r_pbrWorldNormal is enabled), apply tangent-space
             * normal-mapped lighting modulation on top of the existing
             * lightmap+vertex-color result.
             *
             * Goal is NOT to swap world textures (Q3's authored color
             * variety stays intact) — only to add visible surface
             * relief: bolt heads sink, panel seams catch rim light,
             * brick texture shows depth. Same Mikkelsen screen-space
             * TBN trick used by the entity shader, but the lighting
             * multiplier is subtle (0.85..1.15) so the existing BSP
             * lightmap remains dominant — fake sun is a small accent.
             *
             * Tile UV by 0.5 so the 1024² metal-plate normal at a 4x
             * scale across the wall gives plausible texel size that
             * roughly matches Q3's diffuse texel density. Without the
             * tile-down the relief reads as too-coarse on tight
             * geometry. */
            if (!is_null_texture(worldNormalMap)) {
                float2 nmUV = texCoord * 0.5;
                float3 nMap = worldNormalMap.sample(textureSampler, nmUV).xyz * 2.0 - 1.0;

                float3 dp1 = dfdx(in.worldPos);
                float3 dp2 = dfdy(in.worldPos);

                float3 N = in.worldNormal;
                if (length(N) < 1e-4) {
                    N = normalize(cross(dp1, dp2));
                } else {
                    N = normalize(N);
                }

                float2 duv1 = dfdx(texCoord);
                float2 duv2 = dfdy(texCoord);
                float3 dp2perp = cross(dp2, N);
                float3 dp1perp = cross(N, dp1);
                float3 T = dp2perp * duv1.x + dp1perp * duv2.x;
                float3 B = dp2perp * duv1.y + dp1perp * duv2.y;
                float invmax = rsqrt(max(dot(T, T), dot(B, B)) + 1e-4);
                T *= invmax;
                B *= invmax;

                float3 worldN = normalize(T * nMap.x + B * nMap.y + N * nMap.z);

                // Fake sun direction. Stronger contrast than the
                // initial 0.85..1.15 range — the subtle setting was
                // not visually noticeable per user feedback. Now
                // 0.65..1.35 which is more like the entity shader's
                // 0.6..1.2 range. Still gated below the BSP lightmap's
                // primary contribution but the relief actually reads
                // as 3D depth on screen now.
                float3 sunDir = normalize(float3(0.4, 0.5, 0.6));
                float NdotL = dot(worldN, sunDir) * 0.5 + 0.5;
                float halfLambert = NdotL * NdotL;

                lit *= (0.65 + halfLambert * 0.70);

                /* PBR Phase 8 — Cook-Torrance + IBL on world surfaces.
                 *
                 * Gated by pbrWorldParams.x (r_pbr_world_textures cvar).
                 * Augments the Phase 3 Mikkelsen normal-map shading with:
                 *   - kD * diffuseIBL * lit * ambientBoost  (env-fill on
                 *     shadow side, compensates for no GI)
                 *   - F * specularIBL * specBoost           (metallic
                 *     highlight reflecting active map skybox cube via
                 *     Phase 6 v3 auto-detect)
                 *
                 * Uses synthetic defaults — Q3 stock textures don't ship
                 * authored roughness/metallic, so all world surfaces get
                 * the same 0.55 roughness / 0.50 metallic. Result is a
                 * "PBR shading layer on top of vanilla textures" — visible
                 * IBL chrome cue on walls, brighter shadow side, soft
                 * reflections — but no per-surface authored variety (that
                 * would require unlocking the mod's 2,804 hex-hashed DDS
                 * pool which our hash algorithm doesn't match yet).
                 *
                 * pbrWorldParams.x = enable gate (0 or 1)
                 * pbrWorldParams.y = ambientBoost scalar [0..1] — how much
                 *                    of diffuse IBL adds onto lit color
                 * pbrWorldParams.z = specBoost scalar [0..1] — metallic
                 *                    highlight intensity
                 * pbrWorldParams.w = class-match gate; 0 falls back to
                 *                    Phase 8 uniform rough/metal. */
                // Skip PBR IBL specular when the stage already uses tcGen
                // environment — that's Q3's vanilla "fake reflection" path
                // (samples a 2D envmap-source texture like envmapyel.tga
                // with view-derived UVs). Adding IBL specular on top
                // double-stacks the reflection and produces mirror-bright
                // chrome on q3dm10 walls, jump pads, and yellow/red health
                // pickups where the shader expects the simple Q3 sample.
                // For tcGen base (true diffuse surfaces) IBL still augments
                // normally.
                if (pbrWorldParams.x > 0.5 && !is_null_texture(envCube) && tcGenMode != 1) {
                    float3 V = normalize(uniforms.cameraPos - in.worldPos);
                    float NdotV = max(dot(worldN, V), 0.0);
                    // Middle-ground defaults. Metallic 0.30 — still mostly
                    // dielectric (stone surfaces look like stone) but high
                    // enough that the Fresnel rim picks up a visible
                    // tint on edges. Roughness 0.45 gives a moderately
                    // sharp highlight without painting chrome streaks
                    // across flat bricks.
                    float roughness = (pbrWorldParams.w > 0.5) ? drawUniforms.pbrRoughness : 0.45;
                    float metallic = (pbrWorldParams.w > 0.5) ? drawUniforms.pbrMetallic : 0.30;
                    // The RTX replacement world should read as PBR even when
                    // the JSON has only class/fallback roughness/metalness.
                    // Avoid fully-matte defaults and keep enough response for
                    // env/spec highlights on broad floor/wall surfaces.
                    if (!is_null_texture(roughnessMap)) {
                        roughness = roughnessMap.sample(textureSampler, texCoord).r;
                    }
                    if (!is_null_texture(metallicMap)) {
                        metallic = metallicMap.sample(textureSampler, texCoord).r;
                    }
                    roughness = clamp(roughness * 0.82, 0.16, 0.88);
                    metallic = clamp(metallic, 0.0, 1.0);

                    float maxMipF = float(envCube.get_num_mip_levels() - 1);
                    float3 diffuseIBL = envCube.sample(envSampler, worldN, level(maxMipF)).rgb;
                    float3 R = reflect(-V, worldN);
                    float specMip = roughness * maxMipF;
                    float3 specularIBL = envCube.sample(envSampler, R, level(specMip)).rgb;

                    float oneMinusNdotV = 1.0 - NdotV;
                    float3 F0 = mix(float3(0.04), lit, metallic);
                    float3 F_v = F0 + (max(float3(1.0 - roughness), F0) - F0)
                                       * pow(oneMinusNdotV, 5.0);
                    float3 kD_v = (float3(1.0) - F_v) * (1.0 - metallic);

                    float ambBoost  = pbrWorldParams.y;
                    float specBoost = pbrWorldParams.z;
                    // Twin gates on the spec contribution:
                    //   shadowMask = 1 - luma — kill spec on already-bright
                    //                pixels (no double-brighten on lit
                    //                corridors or emissive plaques).
                    //   fresnelGate = pow(1-NdotV, 2) — keep spec on
                    //                EDGE / GRAZING-angle pixels where
                    //                chrome physically lives. Center of
                    //                a flat brick face → NdotV ≈ 1 →
                    //                fresnelGate ≈ 0 → no flat mirror
                    //                streak. Door trim or curved alias
                    //                edge → low NdotV → fresnelGate high
                    //                → visible rim chrome cue.
                    //
                    // The diffuse fill stays gated by shadowMask alone
                    // so shadow side gets brightened uniformly (matches
                    // how PT bounce GI fills shadows in the reference
                    // video).
                    float litLuma = dot(lit, float3(0.2126, 0.7152, 0.0722));
                    float shadowMask  = 1.0 - saturate(litLuma);
                    float fresnelGate = pow(oneMinusNdotV, 1.35);
                    float fillScale = ambBoost * shadowMask;
                    float specMask  = specBoost
                                    * (0.35 * shadowMask + 0.65)  // keep highlights visible on lit faces
                                    * (0.45 + 0.55 * fresnelGate); // edge-weighted but not edge-only
                    lit = lit
                        + kD_v * diffuseIBL * fillScale
                        + F_v  * specularIBL * specMask;
                }
            }
            // Emissive accumulation (additive, post-lighting). intensity == 0
            // is the common case (default 1×1 black bound + intensity 0) —
            // gate the sample + add behind that. The sub-rect remap done
            // upstream for atlas materials still applies because we sample
            // at the same texCoord used for albedo.
            if (drawUniforms.emissiveParams.w > 0.0) {
                float3 eSample = emissiveTexture.sample(textureSampler, texCoord).rgb;
                lit += eSample * drawUniforms.emissiveParams.xyz * drawUniforms.emissiveParams.w;
            }
            return float4(lit, texel.a * va);
        }

        vertex EntityVertexOut q3_entity_vertex(const device EntityVertexIn *vertices [[buffer(0)]],
                                                constant EntityUniforms &uniforms [[buffer(1)]],
                                                uint vertexID [[vertex_id]]) {
            EntityVertexOut out;
            EntityVertexIn inVertex = vertices[vertexID];
            float3 worldPos = inVertex.position;
            /* deformVertexes wave (shader-level). Mirrors the world
             * pipeline's deform block (search "deformVertexes wave:
             * shader-level position deform" in q3_world_vertex). Critical
             * for the powerups/quad family of shell shaders — without
             * this offset, customShader passes render at the model's
             * exact silhouette and collapse into invisibility instead
             * of forming the breathing halo around the gun / player.
             *
             *   spread = 1 / div
             *   off    = (pos.x + pos.y + pos.z) * spread
             *   scale  = wave(func, base, amp, phase + off, freq, t)
             *   pos   += normal * scale
             *
             * Branch is uniform across the draw — predictor-friendly.
             * Vertices with degenerate normals (sprites/beams that left
             * the normal slot at 0) skip the offset so chrome sprites
             * don't collapse. */
            if (uniforms.deformWaveFunc != 0u) {
                float3 n = inVertex.normal;
                float nLen = length(n);
                if (nLen > 1e-4) {
                    n /= nLen;
                    float spread = 1.0 / max(uniforms.deformWaveDiv, 1e-4);
                    float off = (worldPos.x + worldPos.y + worldPos.z) * spread;
                    float scale = evalWave(uniforms.deformWaveFunc,
                                           uniforms.deformWaveBase,
                                           uniforms.deformWaveAmp,
                                           uniforms.deformWavePhase + off,
                                           uniforms.deformWaveFreq,
                                           uniforms.timeSeconds);
                    worldPos += n * scale;
                }
            }
            out.position = uniforms.viewProjection * float4(worldPos, 1.0);
            out.texCoord = inVertex.texCoord;
            out.color = inVertex.color;
            /* Emit POST-deform world position so the fragment's tcGen
             * environment reflection vector projects from the expanded
             * shell surface rather than the original gun surface —
             * keeps the chrome reflection consistent with the visual
             * silhouette the player sees. */
            out.worldPos = worldPos;
            out.normal = inVertex.normal;
            return out;
        }

        fragment float4 q3_entity_fragment(EntityVertexOut in [[stage_in]],
                                           constant EntityUniforms &uniforms [[buffer(1)]],
                                           constant DLightBlock &dlights [[buffer(2)]],
                                           constant float &pbrNormalScale [[buffer(3)]],
                                           constant float2 &pbrRimParams [[buffer(4)]],
                                           texture2d<float> colorTexture [[texture(0)]],
                                           texture2d<float> normalTexture [[texture(1)]],
                                           texture2d<float> roughnessTexture [[texture(3)]],
                                           texture2d<float> metallicTexture [[texture(4)]],
                                           texturecube<float> envCube [[texture(5)]],
                                           texture2d<float> emissiveTexture [[texture(6)]],
                                           sampler textureSampler [[sampler(0)]],
                                           sampler envSampler [[sampler(1)]]) {
            // tcGen environment (chrome / reflective shaders: powerups/
            // quad, powerups/regen, battleSuit). Mirrors ioquake3's
            // RB_CalcEnvironmentTexCoords in tr_shade_calc.c exactly:
            //   viewer = normalize(viewOrigin - vertex)
            //   d      = dot(normal, viewer)
            //   refl   = normal*2*d - viewer
            //   s      = 0.5 + refl.y * 0.5
            //   t      = 0.5 - refl.z * 0.5
            // Entity verts carry world-space position but no normal
            // attribute, so derive a flat face normal via screen-space
            // derivatives (same technique the world pipeline uses).
            float2 texCoord = in.texCoord;
            /* Entity tcGen modes: only mode 1 (environment) is meaningful
             * here — entity shaders that declare `tcGen vector` would route
             * to the world pipeline rather than the entity pipeline. Use an
             * exact integer compare rather than `tcGen > 0.5` so a tcGen=2
             * value (if it ever leaks through) doesn't masquerade as env. */
            int entTcGenMode = int(uniforms.tcGen + 0.5);
            if (entTcGenMode == 1) {
                /* Prefer the per-vertex normal supplied by the MD3 emit
                 * path; fall back to a flat face normal via dfdx/dfdy of
                 * worldPos when none was supplied (sprites, beams,
                 * flares, synthetic overlays) or when length²==0. */
                float3 n;
                if (dot(in.normal, in.normal) > 0.0001) {
                    n = normalize(in.normal);
                } else {
                    float3 dx = dfdx(in.worldPos);
                    float3 dy = dfdy(in.worldPos);
                    n = normalize(cross(dx, dy));
                }
                float3 viewer = normalize(uniforms.cameraPos - in.worldPos);
                float d = 2.0 * dot(viewer, n);
                float3 refl = n * d - viewer;
                texCoord = float2(0.5 + refl.y * 0.5, 0.5 - refl.z * 0.5);
            }
            /* Apply stage 0 tcMod chain after tcGen (matches upstream
             * order: tcGen first, then each tcMod directive sequentially).
             * Rotate param.x is packed as signed degrees/sec; applyTcMod
             * does the single degrees→radians conversion. */
            int entityModCount = uniforms.tcModCount;
            if (entityModCount > 0) texCoord = applyTcMod(texCoord, in.worldPos, int(uniforms.tcModType.x + 0.5), uniforms.tcModParams0, uniforms.timeSeconds);
            if (entityModCount > 1) texCoord = applyTcMod(texCoord, in.worldPos, int(uniforms.tcModType.y + 0.5), uniforms.tcModParams1, uniforms.timeSeconds);
            if (entityModCount > 2) texCoord = applyTcMod(texCoord, in.worldPos, int(uniforms.tcModType.z + 0.5), uniforms.tcModParams2, uniforms.timeSeconds);
            if (entityModCount > 3) texCoord = applyTcMod(texCoord, in.worldPos, int(uniforms.tcModType.w + 0.5), uniforms.tcModParams3, uniforms.timeSeconds);

            /* RTX Remix sprite-sheet atlas sub-rect sampling for entity
             * draws. Mirrors the world fragment block (see line ~1990).
             * Used by envmapyel/envmapgold/envmapbfg (chrome animation on
             * health/armor pickups), models/mapobjects/lamps/flare03,
             * gfx/misc/raildisc_mono2, etc. When cols==0 the branch is
             * skipped — atlas materials write x>0 from the entity bind
             * site; non-atlas materials leave x=0. */
            if (uniforms.spriteAtlasParams.x > 0.5) {
                float aCols  = uniforms.spriteAtlasParams.x;
                float aRows  = uniforms.spriteAtlasParams.y;
                float aFps   = uniforms.spriteAtlasParams.z;
                float aTotal = aCols * aRows;
                float atlasTime = (uniforms.spriteAtlasParams.w > 0.0) ? uniforms.spriteAtlasParams.w : uniforms.timeSeconds;
                float frame  = floor(atlasTime * aFps);
                float idx    = fmod(frame, aTotal);
                if (idx < 0.0) { idx += aTotal; }
                float col = fmod(idx, aCols);
                float row = floor(idx / aCols);
                float2 localUV = fract(texCoord);
                texCoord = float2((localUV.x + col) / aCols,
                                  (localUV.y + row) / aRows);
            }
            float4 texel = colorTexture.sample(textureSampler, texCoord);
            /* Entity/effect alpha synthesis: PBR/RTX replacement DDS files for
             * sprites and additive effects can arrive as RGB-only (alpha=1
             * everywhere) while the Q3 shader expects a luminance mask. Recover
             * a soft mask in-shader for additive draws and alpha-tested entity
             * stages so smoke/flares/explosions do not become solid quads. */
            bool entityAlphaSensitive = (uniforms.forceLuminanceAlpha != 0u ||
                                         uniforms.suppressDlights != 0u ||
                                         uniforms.alphaTestThreshold != 0.0 ||
                                         uniforms.alphaGenMode == 5u ||
                                         uniforms.alphaGenMode == 6u);
            if (entityAlphaSensitive && (uniforms.forceLuminanceAlpha != 0u || texel.a >= 0.995)) {
                float lumAlpha = max(max(texel.r, texel.g), texel.b);
                float2 centered = texCoord - 0.5;
                float radial = saturate(1.0 - dot(centered, centered) * 2.0);
                radial = radial * radial * (3.0 - 2.0 * radial);
                /* forceLuminanceAlpha modes:
                 *   1 = luminance mask for black-background additive FX
                 *       (plasma bolts, muzzle flashes, bright cores).
                 *   2 = inverse-luminance mask for white-background smoke /
                 *       explosion captures. Apply forced modes regardless of
                 *       sampled alpha: several replacement/source effect
                 *       textures have bad semi-opaque alpha, not exactly 1.0,
                 *       so the old alpha>=0.995 gate left white quads alive. */
                float baseAlpha = (uniforms.forceLuminanceAlpha == 2u)
                                ? (1.0 - lumAlpha)
                                : lumAlpha;
                /* Force FX cutouts harder. The previous soft-only mask left
                 * semi-opaque white cards/halos on pickup orbs, muzzle
                 * flashes, smoke puffs, and capture-derived explosions. */
                float synthA;
                if (uniforms.forceLuminanceAlpha == 2u) {
                    synthA = saturate(baseAlpha * 1.65);
                    float chroma = max(texel.r, max(texel.g, texel.b)) - min(texel.r, min(texel.g, texel.b));
                    if (lumAlpha > 0.92 && chroma < 0.14) synthA = 0.0;
                } else {
                    synthA = saturate(baseAlpha * baseAlpha * 1.35);
                }
                synthA *= radial;
                texel.rgb *= synthA;
                texel.a = synthA;
            }
            /* Entity alphaFunc discard — mirrors upstream GLS_ATEST_GT_0 /
             * GE_80 / LT_80 as fragment kills so grate-style meshes and
             * any entity using `alphaFunc GT0` (sparks, explosion puffs on
             * sprite quads once sprite path learns it) show their cutout
             * shape instead of a solid rectangle. Threshold packing
             * matches the world pipeline: positive = discard on below,
             * negative = discard on at-or-above (inverted LT_80). */
            if (uniforms.alphaTestThreshold > 0.0) {
                if (texel.a < uniforms.alphaTestThreshold) discard_fragment();
            } else if (uniforms.alphaTestThreshold < 0.0) {
                if (texel.a >= -uniforms.alphaTestThreshold) discard_fragment();
            } else if (texel.a <= 0.025) {
                /* Several RTX/classic alias textures carry transparent UV
                 * padding but their Q3 shader stage has no explicit
                 * alphaFunc. Dropping fully transparent texels here removes
                 * the white fringe/outline around weapons, pickups, and ammo
                 * without changing normally opaque model interiors. */
                discard_fragment();
            }
            /* P0.2 debug — r_rt_debug_entity_mask 1: render the surviving
             * entity coverage as solid white. viewmodelParams.z is a pad
             * everywhere else (struct-default 0), set per-draw by the main
             * entity loop only, so HUD/scoreboard sub-pass draws are not
             * masked. Placed AFTER the alphaFunc/near-transparent discards
             * so the mask shows exactly the texels that survive and would
             * be preserved over the RT composite. */
            if (uniforms.viewmodelParams.z > 0.5) {
                return float4(1.0, 1.0, 1.0, 1.0);
            }
            /* rgbGen: identity (0) — ignore the per-vertex Lambert,
             * render at full brightness. Matches upstream CGEN_IDENTITY
             * which sets colors to 0xff. Other modes fall through to
             * the existing `texel * in.color` multiply (Lambert baked
             * into vertex color C-side). Alpha follows vertex color in
             * both cases so additive/alpha blends stay intact. */
            /* rgbGen selection:
             *   0 (identity) = texel.rgb * in.color.rgb. This is the
             *                  "no explicit rgbGen directive" path. PC
             *                  Q3 defaults alias-model contexts to
             *                  CGEN_LIGHTING_DIFFUSE here, generating
             *                  per-vertex Lambert at draw time via
             *                  RB_CalcDiffuseColor. Our C-side MD3 emit
             *                  bakes the same `ambient + directed * ndotl
             *                  * entityColor` into vertex.color (line
             *                  ~8773 in metal_renderer_stub.c) — so we
             *                  just multiply by it here. Effect: the
             *                  viewmodel + player + monster alias models
             *                  finally react to the BSP lightgrid (dark
             *                  hallways dim the gun, coloured wall
             *                  torches tint it, etc.) instead of rendering
             *                  full-bright regardless of player position.
             *                  Sprite/beam vertex.color = entity shaderRGBA
             *                  (set at sprite/beam emit time), so they
             *                  get correctly tinted via the same path
             *                  instead of being silently ignored. Was
             *                  returning bare `texel.rgb` — fixed
             *                  2026-06-02. PC reference behavior matches.
             *   3 (wave)     = texel.rgb * clamp(base + sin(2π*(phase +
             *                  t*freq)) * amp, 0, 1) — matches
             *                  RB_CalcWaveColor (GF_SIN scope)
             *   default      = texel.rgb * in.color.rgb (Lambert) */
            float3 baseRgb;
            if (uniforms.rgbGenMode == 0u) {
                baseRgb = texel.rgb * in.color.rgb;
            } else if (uniforms.rgbGenMode == 3u) {
                float4 wp = uniforms.rgbGenWaveParams; /* (base, amp, phase, freq) */
                float glow = clamp(evalWave(uniforms.rgbWaveFunc, wp.x, wp.y, wp.z, wp.w, uniforms.timeSeconds), 0.0, 1.0);
                baseRgb = texel.rgb * glow;
            } else if (uniforms.rgbGenMode == 4u) {
                /* CGEN_CONST: fixed RGB tint. Upstream builds a
                 * color4ub_t from pStage->constantColor and writes it
                 * to every vertex color. */
                baseRgb = texel.rgb * uniforms.rgbConstColor.rgb;
            } else if (uniforms.rgbGenMode == 5u) {
                /* CGEN_ENTITY: refEntity_t.shaderRGBA driven directly,
                 * NOT modulated by per-vertex Lambert. Used by pickup
                 * glow + a few weapon viewmodel stages where cgame
                 * sets shaderRGBA each frame to drive the tint. */
                baseRgb = texel.rgb * uniforms.entityColor.rgb;
            } else if (uniforms.rgbGenMode == 6u) {
                /* CGEN_ONE_MINUS_ENTITY: 1 - shaderRGBA. Inverse-tint
                 * fade used by some teleport / disintegrate shaders. */
                baseRgb = texel.rgb * (float3(1.0) - uniforms.entityColor.rgb);
            } else {
                baseRgb = texel.rgb * in.color.rgb;
            }
            /* alphaGen selection:
             *   0 (identity) = texel.a (force opaque)
             *   3 (wave)     = texel.a * clamp(base + sin(2π*(phase +
             *                  t*freq)) * amp, 0, 1) — RB_CalcWaveAlpha
             *   default      = texel.a * in.color.a (vertex alpha) */
            float baseA;
            if (uniforms.alphaGenMode == 0u) {
                baseA = texel.a;
            } else if (uniforms.alphaGenMode == 3u) {
                float4 ap = uniforms.alphaGenWaveParams;
                float aWave = clamp(evalWave(uniforms.alphaWaveFunc, ap.x, ap.y, ap.z, ap.w, uniforms.timeSeconds), 0.0, 1.0);
                baseA = texel.a * aWave;
            } else if (uniforms.alphaGenMode == 4u) {
                /* AGEN_CONST: fixed alpha multiplier, stashed in
                 * rgbConstColor.w (unused pad of the rgbGen const
                 * SIMD4). */
                baseA = texel.a * uniforms.rgbConstColor.w;
            } else if (uniforms.alphaGenMode == 5u) {
                /* AGEN_ENTITY: refEntity_t.shaderRGBA[3]. Drives
                 * fade-out animations on rocket explosions, gibs,
                 * plasma trails — cgame ramps this down each frame. */
                baseA = texel.a * uniforms.entityColor.a;
            } else if (uniforms.alphaGenMode == 6u) {
                /* AGEN_ONE_MINUS_ENTITY: 1 - shaderRGBA[3]. Inverse-fade
                 * for stages that should be visible only as the entity
                 * fades in/out the opposite direction. */
                baseA = texel.a * (1.0 - uniforms.entityColor.a);
            } else {
                baseA = texel.a * in.color.a;
            }
            float4 base = float4(baseRgb, baseA);
            if (uniforms.suppressDlights == 0u) {
                float3 dlightN = in.normal;
                if (length(dlightN) <= 1e-4) {
                    float3 dx = dfdx(in.worldPos);
                    float3 dy = dfdy(in.worldPos);
                    dlightN = normalize(cross(dx, dy));
                }
                base.rgb = applyDlights(base.rgb, in.worldPos, dlightN, dlights);
            }
            if (uniforms.fogColorDistance.w > 0.0) {
                float f = q3EntityFogFactor(in.worldPos, uniforms);
                base.rgb = mix(base.rgb, q3ResolvedFogColor(uniforms.fogColorDistance.xyz), f);
            }
            /* PBR Phase 2 — normal-mapped lighting modulation.
             *
             * When the Swift binder has a normal map bound to slot 1
             * (i.e. r_pbrMaterials is on AND the entity's texture handle
             * mapped to a PBR material with a real .n.rtex.dds normal
             * slot), apply tangent-space normal-mapped lighting on top
             * of the existing vertex-color shading.
             *
             * Per-pixel TBN basis derived via Mikkelsen's screen-space
             * derivative trick (Christian Schüler, 2013) — works on Q3
             * verts that don't carry a tangent attribute:
             *
             *   T = (dp2 × N) · duv1.x + (N × dp1) · duv2.x
             *   B = (dp2 × N) · duv1.y + (N × dp1) · duv2.y
             *
             * Lighting model: half-Lambert against a constant sun
             * direction. Output is a (0.6 .. 1.2) brightness multiplier
             * over the existing base color — visible 3D relief without
             * blowing out highlights. Vanilla weapons (no normal map
             * bound) skip the block entirely via is_null_texture.
             *
             * Cost: ~1 extra texture sample + ~12 ALU per fragment
             * when active, branchless skip when not. Apple Silicon
             * absorbs both in the fragment budget for the few hundred
             * pixels a weapon viewmodel occupies. */
            if (!is_null_texture(normalTexture)) {
                float3 nMap = normalTexture.sample(textureSampler, in.texCoord).xyz * 2.0 - 1.0;

                float3 N = in.normal;
                if (length(N) < 1e-4) {
                    float3 dxN = dfdx(in.worldPos);
                    float3 dyN = dfdy(in.worldPos);
                    N = normalize(cross(dxN, dyN));
                } else {
                    N = normalize(N);
                }

                float3 dp1 = dfdx(in.worldPos);
                float3 dp2 = dfdy(in.worldPos);
                float2 duv1 = dfdx(in.texCoord);
                float2 duv2 = dfdy(in.texCoord);
                float3 dp2perp = cross(dp2, N);
                float3 dp1perp = cross(N, dp1);
                float3 T = dp2perp * duv1.x + dp1perp * duv2.x;
                float3 B = dp2perp * duv1.y + dp1perp * duv2.y;
                float invmax = rsqrt(max(dot(T, T), dot(B, B)) + 1e-4);
                T *= invmax;
                B *= invmax;

                float3 worldN = normalize(T * nMap.x + B * nMap.y + N * nMap.z);

                // Half-Lambert against a fixed key-light direction.
                // 0.3, 0.5, 0.7 = soft rim from above-back-right.
                //
                // PBR Phase 4 — viewmodel-vs-world entity gating.
                // The pbrNormalScale uniform is 1.0 for viewmodel
                // draws (RF_DEPTHHACK) and 0.0 for world entities.
                // Wide (0.6..1.2) range gives the headline 3D-relief
                // look on the held viewmodel; tight (0.78..1.18) range
                // suppresses the Mikkelsen TBN derivative instability
                // that produces high-contrast jagged shading on
                // rotating world pickups. Linear-mixed so future
                // half-strength values (e.g. 0.5 for animated but
                // non-rotating entities) read sensibly.
                float3 sunDir = normalize(float3(0.3, 0.5, 0.7));
                float NdotL = dot(worldN, sunDir) * 0.5 + 0.5;
                float halfLambert = NdotL * NdotL;

                float lo = mix(0.78, 0.6, pbrNormalScale);
                float hi = mix(1.18, 1.2, pbrNormalScale);
                base.rgb *= mix(lo, hi, halfLambert);

                /* PBR Phase 4 — Cook-Torrance specular accent.
                 *
                 * When the material ships both a roughness AND a
                 * metallic map (currently only rocket launcher), add a
                 * GGX-distributed Fresnel-tinted highlight on top of
                 * the half-Lambert diffuse modulation above. The
                 * specular contribution is the "shiny" the user asked
                 * for — visible bright highlights that move when you
                 * rotate the camera, tinted by base color on metallic
                 * surfaces.
                 *
                 * Gated by pbrNormalScale so only viewmodel draws get
                 * it — rotating world pickups would hit the same TBN
                 * derivative instability that broke the normal-map
                 * contrast on them.
                 *
                 * Cook-Torrance BRDF math:
                 *   D = GGX normal distribution (alpha=roughness²)
                 *   G = Schlick-GGX geometry term
                 *   F = Schlick Fresnel, F0 lerped from 0.04 (dielectric)
                 *       to base.rgb (metal) by metallic factor
                 *   spec = D*F*G / (4*NdotV*NdotL + eps)
                 *
                 * Reference: https://google.github.io/filament/Filament.md.html
                 */
                // PBR Phase 4 (production): Blinn-Phong specular highlight.
                //
                // GGX/Cook-Torrance produced mathematically correct but
                // visually invisible specular on the rocket viewmodel —
                // GGX peaks only at mirror angles which Q3 viewmodel
                // geometry rarely hits relative to a fixed sun direction.
                // Blinn-Phong with a moderate exponent gives a much
                // softer/wider highlight that reads as "shiny metal"
                // across more of the model surface.
                //
                // Path was proven alive via magenta diagnostic (the
                // conditional fires; textures are bound; the branch
                // taken). Switching to Blinn-Phong is purely a visual
                // tuning choice for what we render.
                //
                // Gating: roughness + metallic textures bound is enough;
                // pbrNormalScale viewmodel gate dropped because both
                // viewmodel and rotating pickups handled the highlight
                // gracefully in testing (the Mikkelsen TBN instability
                // affects the underlying worldN, but the specular
                // contribution is too smooth to amplify that artifact).
                // PBR Phase 4 production (v6). Always-on Fresnel rim:
                // fires for any weapon that has a normal map (which is
                // the gate for entering this enclosing block already).
                // When roughness + metallic textures are also bound
                // (rocket only at the moment), we sample them for
                // variable response. Otherwise we use sane defaults so
                // shotgun and lightning gun also get visible shine.
                //
                // Intensity tuned DOWN from v5 (rimStrength range
                // 0.20..0.55 instead of 0.45..1.00) — earlier setting
                // read as "marble" on the rocket. New range gives a
                // clearly visible bright edge without overwhelming the
                // base color in the interior.
                {
                    float roughness = 0.55;  // default — semi-rough
                    float metallic  = 0.50;  // default — partial metal
                    bool hasFullPBR = !is_null_texture(roughnessTexture) &&
                                      !is_null_texture(metallicTexture);
                    if (!is_null_texture(roughnessTexture)) {
                        roughness = roughnessTexture.sample(textureSampler, in.texCoord).r;
                    }
                    if (!is_null_texture(metallicTexture)) {
                        metallic = metallicTexture.sample(textureSampler, in.texCoord).r;
                    }

                    float3 V = normalize(uniforms.cameraPos - in.worldPos);
                    float NdotV = max(dot(worldN, V), 0.0);

                    if (hasFullPBR) {
                        /* PBR Phase 5 — Cook-Torrance GGX with Burley diffuse.
                         *
                         * Ported from SomaZ/OpenJK rend2 lightall.glsl —
                         * the gold-standard Q3-engine PBR reference. Adapted
                         * to MSL and our single fake-sun lighting model
                         * (vs their multi-light + IBL setup).
                         *
                         * The earlier Phase 4 v2 GGX attempt (fdf5f56) failed
                         * because:
                         *   1. NdotL term multiplication zeroed spec on
                         *      surfaces not facing the hardcoded sun
                         *   2. Single fake sun was so narrow that few pixels
                         *      hit the peak
                         *
                         * Phase 5 fix: use a brighter sun + AMBIENT diffuse
                         * floor so even unlit-by-sun pixels get baseline
                         * shading. Plus we keep the Fresnel rim as additive
                         * accent on top — no longer a replacement, now a
                         * supplement.
                         */
                        float3 L = sunDir;  // already normalized above
                        float3 H = normalize(V + L);
                        float NdotL = max(dot(worldN, L), 0.0);
                        float NdotH = max(dot(worldN, H), 0.0);
                        float VdotH = max(dot(V, H), 0.0);
                        float LdotH = max(dot(L, H), 0.0);

                        // D — GGX normal distribution (OpenJK D_GGX)
                        float alpha  = max(roughness * roughness, 0.0625);
                        float alpha2 = alpha * alpha;
                        float d = (NdotH * alpha2 - NdotH) * NdotH + 1.0;
                        float D = alpha2 / (M_PI_F * d * d + 1e-6);

                        // G — Smith joint approx (OpenJK V_SmithJointApprox)
                        float Vis_SmithV = NdotL * (max(NdotV, 0.001) * (1.0 - alpha) + alpha);
                        float Vis_SmithL = NdotV * (NdotL * (1.0 - alpha) + alpha);
                        float G = 0.5 / max(Vis_SmithV + Vis_SmithL, 1e-6);

                        // F — Schlick Fresnel (OpenJK F_Schlick variant)
                        float3 F0 = mix(float3(0.04), base.rgb, metallic);
                        float3 F  = F0 + (float3(1.0) - F0) * pow(1.0 - VdotH, 5.0);

                        // Specular (D * F * G), pre-multiplied by NdotL
                        float3 spec = D * F * G;

                        // Burley diffuse (OpenJK Diff_Burley)
                        float f90 = 0.5 + 2.0 * roughness * LdotH * LdotH;
                        float diffScatterL = 1.0 + (f90 - 1.0) * pow(1.0 - NdotL, 5.0);
                        float diffScatterV = 1.0 + (f90 - 1.0) * pow(1.0 - NdotV, 5.0);
                        float3 burley = base.rgb * diffScatterL * diffScatterV * (1.0 / M_PI_F);

                        // Diffuse energy: dielectric contributes all
                        // unreflected light, metal contributes none
                        float3 kD = (float3(1.0) - F) * (1.0 - metallic);

                        // Sun intensity scaled UP to compensate for our
                        // single-light no-IBL setup. Real PBR rigs have
                        // many lights + sky contribution; we approximate
                        // by boosting the one light we have.
                        float3 sunColor = float3(2.4, 2.2, 1.9);  // warmish white sun

                        // Per-light radiance
                        float3 radiance = (kD * burley + spec) * sunColor * NdotL;

                        /* PBR Phase 6 — IBL ambient + specular reflection.
                         *
                         * Replaces the flat `ambient = base.rgb * 0.35`
                         * floor with environment-cube-driven irradiance
                         * (diffuse) + roughness-mip pre-filter (specular).
                         * envCube is the 64²×6 procedural sky-gradient
                         * generated by ensurePBREnvCube() on first entity
                         * draw; mip chain via blit `generateMipmaps`.
                         *
                         * Diffuse: sample at world normal, highest mip
                         *   (smallest, most-blurred — approximates
                         *   integrated irradiance over the hemisphere).
                         * Specular: sample at reflection vector R = reflect(-V, N),
                         *   mip = roughness * maxMip (Epic split-sum
                         *   pre-filter approximation: rough surfaces sample
                         *   blurred mips, mirrors sample sharp mip 0).
                         * Fresnel at NdotV (Karis simplification — no half
                         *   vector for env sampling). max(1-roughness, F0)
                         *   guards against over-bright dim metals at rough=1.
                         * kD energy split: dielectric gets (1-F)*1 of the
                         *   diffuse term, metal gets (1-F)*0.
                         *
                         * Null-guard: when envCube is unbound (cvar off or
                         * cube alloc failed), fall through to the legacy
                         * 0.35 ambient floor so the rocket doesn't render
                         * pitch black on shadow side.
                         */
                        float3 iblTerm;
                        // Skip IBL specular on stages that use tcGen
                        // environment — vanilla Q3 already samples a 2D
                        // envmap-source texture (envmapyel/gold etc.) via
                        // view-derived UVs; adding the cube IBL specular
                        // on top double-stacks the reflection and renders
                        // health/yellow + ammo pickups as mirror chrome of
                        // env/space1 instead of the intended yellow-tinted
                        // chrome. Keep diffuse-IBL ambient lift via the
                        // legacy 0.35 floor so the shadow side doesn't
                        // crater to black.
                        if (!is_null_texture(envCube) && entTcGenMode != 1) {
                            float maxMipF = float(envCube.get_num_mip_levels() - 1);
                            float3 diffuseIBL = envCube.sample(envSampler, worldN, level(maxMipF)).rgb;
                            float3 R = reflect(-V, worldN);
                            float specMip = roughness * maxMipF;
                            float3 specularIBL = envCube.sample(envSampler, R, level(specMip)).rgb;
                            // Karis NdotV Fresnel with roughness floor
                            float3 F_v = F0 + (max(float3(1.0 - roughness), F0) - F0)
                                              * pow(1.0 - NdotV, 5.0);
                            float3 kD_v = (float3(1.0) - F_v) * (1.0 - metallic);
                            iblTerm = kD_v * diffuseIBL * base.rgb + F_v * specularIBL;
                        } else {
                            iblTerm = base.rgb * 0.35;  // legacy ambient floor
                        }

                        // Direct sun radiance PEAKS over IBL fill — bright
                        // highlights on top of the env-driven base shading.
                        base.rgb = iblTerm + radiance;
                    }

                    // Fresnel rim — fires for ALL entities (including the
                    // GGX-path rocket). For rough/matte surfaces it adds
                    // the silhouette accent that proper PBR alone produces
                    // via shadowed-edge contrast.
                    // Phase F — pbrRimParams.x = peak intensity (default 0.55),
                    // pbrRimParams.y = Fresnel exponent (default 2.5).
                    float fresnel = pow(1.0 - NdotV, pbrRimParams.y);
                    float3 rimColor = mix(
                        float3(0.75, 0.75, 0.78),
                        base.rgb * 1.25 + 0.15,
                        metallic
                    );
                    /*
                     * pbrRimParams.x is an actual intensity gate. The old
                     * mix(0.20, intensity, ...) left a non-zero rim even when
                     * Swift intentionally bound intensity=0 for entities, which
                     * showed up as the white halo/outline around weapons and
                     * pickups. Keep the roughness shaping, but multiply by the
                     * requested peak so 0 really means OFF.
                     */
                    float rimStrength = fresnel
                                      * pbrRimParams.x
                                      * mix(0.35, 1.0, 1.0 - roughness);
                    // GGX-path entities (full PBR) get a much subtler rim
                    // accent than rim-only entities — they already have
                    // proper specular from the BRDF.
                    rimStrength *= hasFullPBR ? 0.35 : 1.0;
                    base.rgb = mix(base.rgb, rimColor, saturate(rimStrength));
                }
            }
            // 2026-06-10: viewmodel base-color floor. Applied BEFORE emissive
            // so glow ride-alongs are unaffected. Gate: `.y > 0.5` means
            // "this draw is RF_DEPTHHACK (first-person weapon)". Floor:
            // `.x = r_pbr_viewmodel_floor` (default 0.35). Reads
            // `texel.rgb` as the unlit albedo sample so the viewmodel always
            // shows its real material color through low-energy IBL — a
            // gameplay readability exception, not a PBR correctness fix.
            // World, entity pickup, and HUD sub-pass draws keep the default
            // (0,0,0,0) which makes the gate false and the floor a no-op.
            if (uniforms.viewmodelParams.y > 0.5) {
                base.rgb = max(base.rgb, texel.rgb * uniforms.viewmodelParams.x);
            }
            // Emissive accumulation. Same pattern as q3_world_fragment;
            // gated on intensity > 0 so the default zero-emission path
            // skips the sample. Sub-rect atlas remap (when active) used
            // the same texCoord, so emissive ride-alongs are consistent.
            if (uniforms.emissiveParams.w > 0.0) {
                float3 eSample = emissiveTexture.sample(textureSampler, in.texCoord).rgb;
                base.rgb += eSample * uniforms.emissiveParams.xyz * uniforms.emissiveParams.w;
            }
            return base;
        }


        /* ================ Sky rendering ================
         * Q3 sky is NOT drawn with mesh UVs. The BSP's sky brushes
         * mark a region of screen; actual sky texture is sampled by
         * view direction (spherical projection for cloud-dome skies,
         * or cubemap for skybox skies). We do the spherical map.
         *
         * Vertex: output world-space position.
         * Fragment: direction = normalize(worldPos - cameraPos);
         *           uv.x = atan2(dir.y, dir.x) mapped to [0,1]
         *           uv.y = asin(dir.z) mapped to [0,1]
         * Pipeline: no depth write, no lightmap, no vertex color.
         */
        struct SkyVertexOut {
            float4 position [[position]];
            float3 worldPos;
            float2 scrollTex;  // raw mesh UV (used for scrolling cloud uv-dome optional)
        };

        vertex SkyVertexOut q3_sky_vertex(const device WorldVertexIn *vertices [[buffer(0)]],
                                          constant WorldUniforms &uniforms [[buffer(1)]],
                                          uint vertexID [[vertex_id]]) {
            SkyVertexOut out;
            WorldVertexIn inVertex = vertices[vertexID];
            out.position = uniforms.viewProjection * float4(inVertex.position, 1.0);
            // Push to max depth so sky always renders behind everything
            out.position.z = out.position.w;
            out.worldPos = inVertex.position;
            out.scrollTex = inVertex.texCoord;
            return out;
        }

        fragment float4 q3_sky_fragment(SkyVertexOut in [[stage_in]],
                                        constant WorldUniforms &uniforms [[buffer(1)]],
                                        constant WorldDrawUniforms &drawUniforms [[buffer(0)]],
                                        texture2d<float> skyTexture [[texture(0)]],
                                        sampler textureSampler [[sampler(0)]]) {
            // Q3 cloud-dome sky: a single texture projected onto a
            // virtual sphere around the camera. NOT lat-lon (zenith
            // singularity), NOT hard cube-face switch (visible seams
            // where faces meet — the diagonal bands we saw in the
            // prior build). Instead we sample all three axis-aligned
            // cube projections and blend with weights that sharpen
            // toward the dominant axis, so the sum is smooth
            // everywhere. `pow(abs(dir), 4)` gives a narrow bell
            // around each axis; normalization keeps the final color
            // energy-preserving. This matches Q3's "fake spherical
            // projection without poles" look without true cubemaps.
            float3 dir = normalize(in.worldPos - uniforms.cameraPos);
            float3 a = abs(dir);

            // Blend weights: pow(|dir|, 4) sharpens each axis's
            // contribution near its face, softens it into adjacent
            // faces across the seams. Divide by sum to normalize —
            // keeps total contribution = 1.
            float3 w = pow(a, float3(4.0));
            float wSum = max(w.x + w.y + w.z, 1e-4);
            w /= wSum;

            // Three axis-aligned cube projections. NO V-flip on the
            // negative-axis half — with blended sampling the apparent
            // "mirror" at each axis center is invisible (the `pow(4)`
            // weight near zero collapses that face's contribution to
            // ~0 anyway). Adding a V-flip here would create a
            // discontinuity inside the blend, re-introducing seams.
            // 1e-4 floor prevents divide-by-zero exactly on the axis
            // (dir = (±1, 0, 0) etc.) where the other two components
            // collapse.
            float2 uvX = float2(-dir.y, dir.z) / max(a.x, 1e-4) * 0.5 + 0.5;
            float2 uvY = float2( dir.x, dir.z) / max(a.y, 1e-4) * 0.5 + 0.5;
            float2 uvZ = float2( dir.x, -dir.y) / max(a.z, 1e-4) * 0.5 + 0.5;

            // Apply the full tcMod chain to each of the three axis-aligned
            // projections uniformly. killsky stacks scale+scroll; order
            // matters. We iterate the chain the same as the world fragment.
            int skyModCount = drawUniforms.tcModCount;
            if (skyModCount > 0) {
                int t = int(drawUniforms.tcModType.x + 0.5);
                uvX = applyTcMod(uvX, in.worldPos, t, drawUniforms.tcModParams0, drawUniforms.timeSeconds);
                uvY = applyTcMod(uvY, in.worldPos, t, drawUniforms.tcModParams0, drawUniforms.timeSeconds);
                uvZ = applyTcMod(uvZ, in.worldPos, t, drawUniforms.tcModParams0, drawUniforms.timeSeconds);
            }
            if (skyModCount > 1) {
                int t = int(drawUniforms.tcModType.y + 0.5);
                uvX = applyTcMod(uvX, in.worldPos, t, drawUniforms.tcModParams1, drawUniforms.timeSeconds);
                uvY = applyTcMod(uvY, in.worldPos, t, drawUniforms.tcModParams1, drawUniforms.timeSeconds);
                uvZ = applyTcMod(uvZ, in.worldPos, t, drawUniforms.tcModParams1, drawUniforms.timeSeconds);
            }
            if (skyModCount > 2) {
                int t = int(drawUniforms.tcModType.z + 0.5);
                uvX = applyTcMod(uvX, in.worldPos, t, drawUniforms.tcModParams2, drawUniforms.timeSeconds);
                uvY = applyTcMod(uvY, in.worldPos, t, drawUniforms.tcModParams2, drawUniforms.timeSeconds);
                uvZ = applyTcMod(uvZ, in.worldPos, t, drawUniforms.tcModParams2, drawUniforms.timeSeconds);
            }
            if (skyModCount > 3) {
                int t = int(drawUniforms.tcModType.w + 0.5);
                uvX = applyTcMod(uvX, in.worldPos, t, drawUniforms.tcModParams3, drawUniforms.timeSeconds);
                uvY = applyTcMod(uvY, in.worldPos, t, drawUniforms.tcModParams3, drawUniforms.timeSeconds);
                uvZ = applyTcMod(uvZ, in.worldPos, t, drawUniforms.tcModParams3, drawUniforms.timeSeconds);
            }

            float4 sX = skyTexture.sample(textureSampler, uvX);
            float4 sY = skyTexture.sample(textureSampler, uvY);
            float4 sZ = skyTexture.sample(textureSampler, uvZ);

            float3 sky = sX.rgb * w.x + sY.rgb * w.y + sZ.rgb * w.z;
            return float4(sky, 1.0);
        }
        