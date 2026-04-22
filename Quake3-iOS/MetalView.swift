import SwiftUI
import MetalKit
import GameController
import QuartzCore
import simd

struct MetalView: UIViewRepresentable {
    func makeUIView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = MTLCreateSystemDefaultDevice()
        view.colorPixelFormat = .bgra8Unorm
        view.depthStencilPixelFormat = .depth32Float
        view.delegate = context.coordinator
        let maxFPS = UIScreen.main.maximumFramesPerSecond
        view.preferredFramesPerSecond = maxFPS
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, MTKViewDelegate {
        struct GPUVertex {
            var position: SIMD2<Float>
            var texCoord: SIMD2<Float>
            var color: SIMD4<Float>
        }

        struct Uniforms {
            var projection: simd_float4x4
        }

        struct GPUWorldVertex {
            var position: SIMD3<Float>
            var texCoord: SIMD2<Float>
            var lightmapTexCoord: SIMD2<Float>
            var color: SIMD4<Float>
        }

        struct WorldUniforms {
            var viewProjection: simd_float4x4
            var cameraPos: SIMD3<Float>    // for sky sphere-mapping
            var _pad: Float = 0            // pad to 16-byte alignment
        }

        struct WorldDrawUniforms {
            var tcGen: Float
            var tcModCount: Int32
            var rgbGen: Float
            var timeSeconds: Float
            var tcModType: SIMD4<Float>
            var tcModParams0: SIMD4<Float>
            var tcModParams1: SIMD4<Float>
            var tcModParams2: SIMD4<Float>
            var tcModParams3: SIMD4<Float>
            // Fog for this draw. xyz = linear fog color, w = fog distance
            // (units of world space). w == 0 ⇒ no fog, fragment skips the
            // mix entirely. Populated per-draw from s_worldFogs[fogIndex].
            var fogColorDistance: SIMD4<Float>
            var debugMode: Float
            var forceWhiteVertColor: Float
            var alphaTestThreshold: Float
            var _pad0: Float = 0
        }

        // Render debug: 0 = normal, 1 = base only, 2 = lightmap only,
        // 3 = uv1 visualization, 4 = vertex color only. Flip to diagnose
        // lightmap / uv1 issues without touching the build pipeline.
        private static let worldDebugMode: Float = 0

        // One-shot: logs the first sky draw's stage layout once per launch.
        // Confirms killsky_1 + killsky_2 are both wired through as stages.
        // Instance property (not static) to sidestep Swift 6 strict global
        // concurrency — Coordinator itself is main-actor driven, so the
        // bool is safe here without any isolation attribute.
        private var skyStagesLogged: Bool = false

        private static func metalCullMode(for stageCullMode: UInt32) -> MTLCullMode {
            // Matches C side METAL_SHADER_CULL_*: 0=back, 1=disable, 2=front.
            switch stageCullMode {
            case 1: return .none
            case 2: return .front
            default: return .back
            }
        }

        private static func alphaTestThreshold(for alphaFunc: UInt32) -> Float {
            switch alphaFunc {
            case 1: return 0.004 // GT0
            case 2: return 0.5   // GE128
            case 3: return -0.5  // LT128 (negative means invert test)
            default: return 0.0  // disabled
            }
        }

        private static func worldStage(_ draw: Q3MetalWorldDrawCmd, _ index: Int) -> Q3MetalWorldStage {
            switch index {
            case 0: return draw.stages.0
            case 1: return draw.stages.1
            case 2: return draw.stages.2
            default: return draw.stages.3
            }
        }

        typealias TcModChainPack = (types: SIMD4<Float>,
                                    p0: SIMD4<Float>, p1: SIMD4<Float>,
                                    p2: SIMD4<Float>, p3: SIMD4<Float>,
                                    count: Int32)

        private static func fillTcMods(_ stage: Q3MetalWorldStage) -> TcModChainPack {
            var types = SIMD4<Float>(0, 0, 0, 0)
            var p0 = SIMD4<Float>(0, 0, 0, 0)
            var p1 = SIMD4<Float>(0, 0, 0, 0)
            var p2 = SIMD4<Float>(0, 0, 0, 0)
            var p3 = SIMD4<Float>(0, 0, 0, 0)
            let n = Int(min(stage.tcModCount, 4))
            let chain = [stage.tcMods.0, stage.tcMods.1, stage.tcMods.2, stage.tcMods.3]
            for i in 0..<n {
                let m = chain[i]
                types[i] = Float(m.type)
                let pp = m.params
                let v = SIMD4<Float>(pp.0, pp.1, pp.2, pp.3)
                switch i {
                case 0: p0 = v
                case 1: p1 = v
                case 2: p2 = v
                case 3: p3 = v
                default: break
                }
            }
            return (types, p0, p1, p2, p3, Int32(n))
        }

        struct GPUEntityVertex {
            var position: SIMD3<Float>
            var texCoord: SIMD2<Float>
            var color: SIMD4<Float>
        }

        struct EntityUniforms {
            var viewProjection: simd_float4x4
            /* Camera origin in world space — used by q3_entity_fragment
             * when tcGen>0 to compute the reflection vector for chrome
             * shaders (quad shell, regen, battlesuit). 16-byte aligned
             * via SIMD3 (w is padding). */
            var cameraPos: SIMD3<Float> = SIMD3<Float>(0, 0, 0)
            /* 1.0 when the current draw's shader has `tcGen environment`.
             * Set per entity based on Q3_METAL_ENTITY_DRAWFLAG_TCGEN_ENV.
             * 0.0 otherwise — fragment keeps mesh ST coords. */
            var tcGen: Float = 0
            /* Explicit padding to keep the struct 16-byte aligned so
             * setVertexBytes / setFragmentBytes agree on stride. */
            var _pad0: Float = 0
            var _pad1: Float = 0
            var _pad2: Float = 0
        }

        /* Fragment-side dlight block bound at buffer(2) for both world and
         * entity passes. Layout: count + 12B pad (align to 16), then 32
         * Q3MetalLight entries (32B each). Total 1040B, well under the
         * 4KB setFragmentBytes limit. */
        private static let dlightMaxCount = 32
        private static let dlightHeaderSize = 16
        private static let dlightBlockSize = dlightHeaderSize + dlightMaxCount * MemoryLayout<Q3MetalLight>.stride

        /* Builds and binds the dlight block into the given encoder's
         * fragment buffer slot in a single step. MUST do the bind inside
         * the `withUnsafeMutableBytes` closure — the raw pointer is only
         * valid for the closure's duration, and setFragmentBytes copies
         * immediately, so the sequence is safe. Previously this returned
         * a `[UInt8]` and the caller used `&block` in setFragmentBytes,
         * which bound the Array struct metadata (8-byte heap pointer +
         * counters) instead of the buffer contents — the fragment read
         * garbage as `count` and iterated 32 junk lights, producing red
         * flood artifacts during high-action frames. */
        private static func bindDlightBlock(snapshot: Q3MetalFrameSnapshot,
                                            encoder: MTLRenderCommandEncoder,
                                            index: Int) {
            var block = [UInt8](repeating: 0, count: dlightBlockSize)
            let count = min(Int(snapshot.lightCount), dlightMaxCount)
            block.withUnsafeMutableBytes { raw in
                guard let base = raw.baseAddress else { return }
                base.bindMemory(to: UInt32.self, capacity: 1).pointee = UInt32(count)
                if count > 0, let src = Q3MetalRenderer_GetLights() {
                    memcpy(base.advanced(by: dlightHeaderSize), src,
                           count * MemoryLayout<Q3MetalLight>.stride)
                }
                encoder.setFragmentBytes(base, length: dlightBlockSize, index: index)
            }
        }

        private let shaderSource = """
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
            float4 color;
        };

        struct WorldUniforms {
            float4x4 viewProjection;
            packed_float3 cameraPos;
            float _pad;
        };

        struct WorldVertexOut {
            float4 position [[position]];
            float2 texCoord;
            float2 lightmapTexCoord;
            float4 color;
            // World-space vertex position. Needed so the fragment can
            // compute linear view distance for fog. Interpolated with
            // perspective correction automatically.
            float3 worldPos;
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
        float3 applyDlights(float3 lit, float3 worldPos, constant DLightBlock &block) {
            uint count = min(block.count, 32u);
            float3 accum = float3(0.0);
            for (uint i = 0; i < count; ++i) {
                MSLLight L = block.lights[i];
                float r = max(L.radius, 1.0);
                float3 d = worldPos - float3(L.origin);
                float dist = length(d);
                float atten = saturate(1.0 - dist / r);
                atten = atten * atten;
                accum += float3(L.color) * atten;
            }
            /* Clamp accumulated contribution so stacked explosions don't
             * white out the scene. 1.5 keeps a strong punch for nearby
             * rockets + muzzle flashes without saturating the base lit
             * color beyond what the eye reads as "bright". */
            accum = min(accum, float3(1.5));
            return lit + accum;
        }

        struct WorldDrawUniforms {
            float tcGen;
            int tcModCount;
            float rgbGen;
            float timeSeconds;
            float4 tcModType;
            float4 tcModParams0;
            float4 tcModParams1;
            float4 tcModParams2;
            float4 tcModParams3;
            // Fog: xyz = color, w = distance (world units). w == 0 ⇒
            // no fog applies to this draw, fragment skips the mix.
            float4 fogColorDistance;
            float debugMode;
            float forceWhiteVertColor;
            float alphaTestThreshold;
            float _pad0;
        };

        float2 applyTcMod(float2 uv, int type, float4 params, float timeSeconds) {
            if (type == 1) {
                return uv + params.xy * timeSeconds;
            } else if (type == 2) {
                float s = sin(timeSeconds * params.w) * params.y;
                return uv + float2(s, s);
            } else if (type == 3) {
                float a = params.x * timeSeconds;
                float c = cos(a);
                float s = sin(a);
                float2 p = uv - 0.5;
                return float2(p.x * c - p.y * s, p.x * s + p.y * c) + 0.5;
            } else if (type == 4) {
                return uv * params.xy;
            } else if (type == 5) {
                float amp = params.x;
                float freq = params.y;
                float phase = params.z;
                float t = (timeSeconds + phase) * freq * 2.0 * 3.14159265;
                return uv + float2(sin(t + uv.y * 4.0) * amp,
                                   sin(t + uv.x * 4.0) * amp);
            }
            return uv;
        }

        struct EntityVertexIn {
            float3 position;
            float2 texCoord;
            float4 color;
        };

        struct EntityUniforms {
            float4x4 viewProjection;
            /* Mirrors Swift-side struct — MSL packs float3 on 16-byte
             * boundaries, so the explicit pads keep offsets aligned with
             * the Swift layout. Read by q3_entity_fragment for tcGen env. */
            float3 cameraPos;
            float  tcGen;
            float  _pad0;
            float  _pad1;
            float  _pad2;
        };

        struct EntityVertexOut {
            float4 position [[position]];
            float2 texCoord;
            float4 color;
            // World-space position — entity verts are pre-transformed to
            // world space C-side so this is a direct pass-through.
            float3 worldPos;
        };

        vertex WorldVertexOut q3_world_vertex(const device WorldVertexIn *vertices [[buffer(0)]],
                                              constant WorldUniforms &uniforms [[buffer(1)]],
                                              uint vertexID [[vertex_id]]) {
            WorldVertexOut out;
            WorldVertexIn inVertex = vertices[vertexID];
            out.position = uniforms.viewProjection * float4(inVertex.position, 1.0);
            out.texCoord = inVertex.texCoord;
            out.lightmapTexCoord = inVertex.lightmapTexCoord;
            out.color = inVertex.color;
            // Pass through world-space position for the fog distance
            // calculation in the fragment. Cheap; perspective-correct
            // interpolation is what we want for linear fog.
            out.worldPos = inVertex.position;
            return out;
        }

        fragment float4 q3_world_fragment(WorldVertexOut in [[stage_in]],
                                          constant WorldDrawUniforms &drawUniforms [[buffer(0)]],
                                          constant WorldUniforms &uniforms [[buffer(1)]],
                                          constant DLightBlock &dlights [[buffer(2)]],
                                          texture2d<float> colorTexture [[texture(0)]],
                                          texture2d<float> lightmapTexture [[texture(1)]],
                                          sampler textureSampler [[sampler(0)]]) {
            float2 texCoord = in.texCoord;
            int rgbGen = int(drawUniforms.rgbGen + 0.5);
            /* tcGen environment: chrome/reflective surfaces. Instead of
             * sampling by mesh UVs, compute the reflection vector off
             * the face normal and use its y/z as texture coords.
             * Per-fragment normal is derived from screen-space derivatives
             * of worldPos — yields a flat face normal without requiring
             * vertex normals in the pipeline. Matches Q3's RB_CalcEnvironmentTexCoords
             * formula: s = 0.5 + reflected.y * 0.5, t = 0.5 - reflected.z * 0.5. */
            if (drawUniforms.tcGen > 0.5) {
                float3 dx = dfdx(in.worldPos);
                float3 dy = dfdy(in.worldPos);
                float3 n = normalize(cross(dx, dy));
                float3 viewer = normalize(uniforms.cameraPos - in.worldPos);
                float d = 2.0 * dot(viewer, n);
                float3 refl = n * d - viewer;
                texCoord = float2(0.5 + refl.y * 0.5, 0.5 - refl.z * 0.5);
            }
            // tcMod chain — apply in order. Q3 shaders stack mods (e.g. scale
            // then scroll); order matters and cannot be reduced to one slot.
            int modCount = drawUniforms.tcModCount;
            if (modCount > 0) texCoord = applyTcMod(texCoord, int(drawUniforms.tcModType.x + 0.5), drawUniforms.tcModParams0, drawUniforms.timeSeconds);
            if (modCount > 1) texCoord = applyTcMod(texCoord, int(drawUniforms.tcModType.y + 0.5), drawUniforms.tcModParams1, drawUniforms.timeSeconds);
            if (modCount > 2) texCoord = applyTcMod(texCoord, int(drawUniforms.tcModType.z + 0.5), drawUniforms.tcModParams2, drawUniforms.timeSeconds);
            if (modCount > 3) texCoord = applyTcMod(texCoord, int(drawUniforms.tcModType.w + 0.5), drawUniforms.tcModParams3, drawUniforms.timeSeconds);
            float4 texel = colorTexture.sample(textureSampler, texCoord);
            float4 lightmap = lightmapTexture.sample(textureSampler, in.lightmapTexCoord);
            int mode = int(drawUniforms.debugMode + 0.5);
            if (mode == 1) {
                return float4(texel.rgb, 1.0);
            }
            if (mode == 2) {
                return float4(lightmap.rgb, 1.0);
            }
            if (mode == 3) {
                return float4(fract(in.lightmapTexCoord.x), fract(in.lightmapTexCoord.y), 0.0, 1.0);
            }
            if (mode == 4) {
                return float4(in.color.rgb, 1.0);
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

            // For additive surfaces (flames, glow), BSP vertex color is
            // typically (0,0,0) because Q3 shaders use rgbGen identity.
            // forceWhiteVertColor=1.0 substitutes white, preventing the
            // multiply from zeroing out the fragment.
            // Overbright (r_overBrightBits=1): stock Q3 multiplies the
            // lightmap by 2.0 and clamps, giving bright-lit surfaces the
            // washed-out punch that matches the reference PC build.
            // Without it the whole world renders ~50% too dark.
            // saturate() clamps to [0,1] so highlights don't wrap.
            float3 vertexColor = (rgbGen == 1) ? in.color.rgb : float3(1.0);
            float3 vc = mix(vertexColor, float3(1.0), drawUniforms.forceWhiteVertColor);
            float  va = mix(in.color.a,   1.0,          drawUniforms.forceWhiteVertColor);
            float3 lit = texel.rgb * saturate(lightmap.rgb * 2.0) * vc;
            // Dynamic lights (muzzle flashes, rocket/plasma glow, lightning
            // halos). Applied BEFORE fog so distant explosions still fog
            // correctly. For filter/multiply stages the blend is source*dest
            // so contribution flips meaning, but the visual impact is small
            // and the per-draw blendMode isn't currently in WorldDrawUniforms.
            lit = applyDlights(lit, in.worldPos, dlights);
            // Fog pass (F3). drawUniforms.fogColorDistance is:
            //   .xyz = linear fog color, .w = fog distance (world units).
            // .w == 0 means "no fog" (every surface outside any volume on
            // q3dm6 hits this branch — effectively free). Otherwise mix
            // toward fog color by saturated linear distance. Exponential
            // falloff can replace the linear ramp later if needed.
            if (drawUniforms.fogColorDistance.w > 0.0) {
                float dist = length(in.worldPos - uniforms.cameraPos);
                float f = saturate(dist / drawUniforms.fogColorDistance.w);
                lit = mix(lit, drawUniforms.fogColorDistance.xyz, f);
            }
            return float4(lit, texel.a * va);
        }

        vertex EntityVertexOut q3_entity_vertex(const device EntityVertexIn *vertices [[buffer(0)]],
                                                constant EntityUniforms &uniforms [[buffer(1)]],
                                                uint vertexID [[vertex_id]]) {
            EntityVertexOut out;
            EntityVertexIn inVertex = vertices[vertexID];
            out.position = uniforms.viewProjection * float4(inVertex.position, 1.0);
            out.texCoord = inVertex.texCoord;
            out.color = inVertex.color;
            out.worldPos = inVertex.position;
            return out;
        }

        fragment float4 q3_entity_fragment(EntityVertexOut in [[stage_in]],
                                           constant EntityUniforms &uniforms [[buffer(1)]],
                                           constant DLightBlock &dlights [[buffer(2)]],
                                           texture2d<float> colorTexture [[texture(0)]],
                                           sampler textureSampler [[sampler(0)]]) {
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
            if (uniforms.tcGen > 0.5) {
                float3 dx = dfdx(in.worldPos);
                float3 dy = dfdy(in.worldPos);
                float3 n = normalize(cross(dx, dy));
                float3 viewer = normalize(uniforms.cameraPos - in.worldPos);
                float d = 2.0 * dot(viewer, n);
                float3 refl = n * d - viewer;
                texCoord = float2(0.5 + refl.y * 0.5, 0.5 - refl.z * 0.5);
            }
            float4 texel = colorTexture.sample(textureSampler, texCoord);
            float4 base = texel * in.color;
            base.rgb = applyDlights(base.rgb, in.worldPos, dlights);
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
                uvX = applyTcMod(uvX, t, drawUniforms.tcModParams0, drawUniforms.timeSeconds);
                uvY = applyTcMod(uvY, t, drawUniforms.tcModParams0, drawUniforms.timeSeconds);
                uvZ = applyTcMod(uvZ, t, drawUniforms.tcModParams0, drawUniforms.timeSeconds);
            }
            if (skyModCount > 1) {
                int t = int(drawUniforms.tcModType.y + 0.5);
                uvX = applyTcMod(uvX, t, drawUniforms.tcModParams1, drawUniforms.timeSeconds);
                uvY = applyTcMod(uvY, t, drawUniforms.tcModParams1, drawUniforms.timeSeconds);
                uvZ = applyTcMod(uvZ, t, drawUniforms.tcModParams1, drawUniforms.timeSeconds);
            }
            if (skyModCount > 2) {
                int t = int(drawUniforms.tcModType.z + 0.5);
                uvX = applyTcMod(uvX, t, drawUniforms.tcModParams2, drawUniforms.timeSeconds);
                uvY = applyTcMod(uvY, t, drawUniforms.tcModParams2, drawUniforms.timeSeconds);
                uvZ = applyTcMod(uvZ, t, drawUniforms.tcModParams2, drawUniforms.timeSeconds);
            }
            if (skyModCount > 3) {
                int t = int(drawUniforms.tcModType.w + 0.5);
                uvX = applyTcMod(uvX, t, drawUniforms.tcModParams3, drawUniforms.timeSeconds);
                uvY = applyTcMod(uvY, t, drawUniforms.tcModParams3, drawUniforms.timeSeconds);
                uvZ = applyTcMod(uvZ, t, drawUniforms.tcModParams3, drawUniforms.timeSeconds);
            }

            float4 sX = skyTexture.sample(textureSampler, uvX);
            float4 sY = skyTexture.sample(textureSampler, uvY);
            float4 sZ = skyTexture.sample(textureSampler, uvZ);

            float3 sky = sX.rgb * w.x + sY.rgb * w.y + sZ.rgb * w.z;
            return float4(sky, 1.0);
        }
        """

        private var commandQueue: MTLCommandQueue?
        private var uiPipelineState: MTLRenderPipelineState?
        private var uiOpaquePipelineState: MTLRenderPipelineState?
        private var uiAdditivePipelineState: MTLRenderPipelineState?
        private var uiFilterPipelineState: MTLRenderPipelineState?
        private var worldPipelineState: MTLRenderPipelineState?
        private var worldFilterPipelineState: MTLRenderPipelineState?
        private var worldAlphaPipelineState: MTLRenderPipelineState?
        private var worldAdditivePipelineState: MTLRenderPipelineState?
        private var skyPipelineState: MTLRenderPipelineState?
        private var skyAdditivePipelineState: MTLRenderPipelineState?
        private var skyDepthStencilState: MTLDepthStencilState?
        private var entityPipelineState: MTLRenderPipelineState?
        private var entityFilterPipelineState: MTLRenderPipelineState?
        private var entityAlphaPipelineState: MTLRenderPipelineState?
        private var entityAdditivePipelineState: MTLRenderPipelineState?
        private var additiveEntityDepthStencilState: MTLDepthStencilState?
        /* Always-pass depth state for multi-scene HUD sub-scene rendering.
         * The world pass writes world-scale depth values across the entire
         * framebuffer, and HUD sub-scenes draw origin-space geometry into a
         * small viewport inside that — lessEqual would reject sub-scene
         * fragments under nearby walls. This state ignores the existing
         * depth buffer entirely so HUD portraits always render on top. */
        private var alwaysPassDepthStencilState: MTLDepthStencilState?
        private var uiSamplerState: MTLSamplerState?
        private var worldSamplerState: MTLSamplerState?
        private var depthStencilState: MTLDepthStencilState?
        private var additiveDepthStencilState: MTLDepthStencilState?
        private var depthHackDepthStencilState: MTLDepthStencilState?
        private var fallbackDepthStencilState: MTLDepthStencilState?

        private func ensuredDepthStencilState(_ preferred: MTLDepthStencilState?, device: MTLDevice?) -> MTLDepthStencilState? {
            if let preferred { return preferred }
            if let fallbackDepthStencilState { return fallbackDepthStencilState }
            guard let device else { return nil }
            let desc = MTLDepthStencilDescriptor()
            // STEP 8: .lessEqual (not .always) so downstream stages that
            // land on this fallback path still honor depth ordering. The
            // previous .always forced every stage drawn through the
            // fallback to overwrite existing depth, producing flicker on
            // stacked geometry.
            desc.depthCompareFunction = .lessEqual
            desc.isDepthWriteEnabled = false
            fallbackDepthStencilState = device.makeDepthStencilState(descriptor: desc)
            return fallbackDepthStencilState
        }
        private var textureCache: [UInt32: (generation: UInt32, texture: MTLTexture)] = [:]
        private var vertexBuffer: MTLBuffer?
        private var vertexBufferCapacity = 0
        private var worldVertexBuffer: MTLBuffer?
        private var worldIndexBuffer: MTLBuffer?
        private var cachedWorldGeneration: UInt32 = 0
        private var entityVertexBuffer: MTLBuffer?
        private var entityVertexBufferCapacity = 0
        private var entityIndexBuffer: MTLBuffer?
        private var entityIndexBufferCapacity = 0
        private var debugFrameCounter: UInt32 = 0
        private var frameTimeOrigin = CACurrentMediaTime()

        override init() {
            super.init()
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            print("[Metal] Drawable size: \(size)")
            Q3MetalRenderer_UpdateDrawableSize(Int32(size.width), Int32(size.height))
        }

        func draw(in view: MTKView) {
            if commandQueue == nil {
                configureRenderer(for: view)
            }

            Q3MetalRenderer_UpdateDrawableSize(Int32(view.drawableSize.width), Int32(view.drawableSize.height))
            Quake3_Frame()

            guard let snapshot = Q3MetalRenderer_GetFrameSnapshot()?.pointee else { return }
            guard let drawable = view.currentDrawable,
                  let descriptor = view.currentRenderPassDescriptor,
                  let commandQueue,
                  let uiSamplerState,
                  let worldSamplerState,
                  let commandBuffer = commandQueue.makeCommandBuffer()
            else { return }

            descriptor.colorAttachments[0].clearColor = MTLClearColor(
                red: Double(snapshot.clearColor.0),
                green: Double(snapshot.clearColor.1),
                blue: Double(snapshot.clearColor.2),
                alpha: Double(snapshot.clearColor.3)
            )

            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
                return
            }

            if snapshot.worldCommandCount > 0,
               let worldPipelineState,
               let sceneView = Q3MetalRenderer_GetSceneView()?.pointee,
               let worldVertexBuffer = uploadWorldBuffers(device: view.device, generation: snapshot.worldGeneration),
               let worldIndexBuffer {
                let viewProjection = makeWorldViewProjection(sceneView)
                let cameraPos = SIMD3<Float>(sceneView.viewOrigin.0, sceneView.viewOrigin.1, sceneView.viewOrigin.2)
                var worldUniforms = WorldUniforms(viewProjection: viewProjection, cameraPos: cameraPos)
                encoder.setRenderPipelineState(worldPipelineState)
                encoder.setDepthStencilState(ensuredDepthStencilState(depthStencilState, device: view.device))
                encoder.setFrontFacing(.clockwise)
                // Default: backface cull. Per-stage overrides below.
                encoder.setCullMode(.back)
                encoder.setVertexBuffer(worldVertexBuffer, offset: 0, index: 0)
                encoder.setVertexBytes(&worldUniforms, length: MemoryLayout<WorldUniforms>.stride, index: 1)
                // Also bind WorldUniforms at fragment index 1. The sky
                // fragment shader reads `constant WorldUniforms &uniforms
                // [[buffer(1)]]` for cameraPos; without this bind, the
                // read hits undefined memory and produces vertical
                // smear bands across the sky.
                encoder.setFragmentBytes(&worldUniforms, length: MemoryLayout<WorldUniforms>.stride, index: 1)
                encoder.setFragmentSamplerState(worldSamplerState, index: 0)

                // Bind dlight block at fragment buffer(2). Shared across all
                // world draws in this scene — scene-constant, not per-draw.
                Self.bindDlightBlock(snapshot: snapshot, encoder: encoder, index: 2)

                if let worldDrawsPointer = Q3MetalRenderer_GetWorldDrawCommands(),
                   let indicesPointer = Q3MetalRenderer_GetWorldIndices() {
                    let _ = indicesPointer
                    let worldDraws = UnsafeBufferPointer(start: worldDrawsPointer, count: Int(snapshot.worldCommandCount))
                    let timeSeconds = Float(CACurrentMediaTime() - frameTimeOrigin)

                    let skyFlagBit = UInt32(Q3_METAL_WORLD_DRAWFLAG_SKY)

                    // Ordered world passes:
                    // 0 = opaque, 1 = filter, 2 = alpha, 3 = additive.
                    // Sky draws are handled in pass 0 through the sky pipeline
                    // (view-direction spherical projection, no lightmap).
                    for worldPass in 0..<4 {
                    for draw in worldDraws where draw.indexCount > 0 {
                        let isSky = (draw.flags & skyFlagBit) != 0
                        if isSky {
                            // Only emit sky during the opaque pass to avoid
                            // duplicated draws across 4 pass iterations.
                            guard worldPass == 0 else { continue }
                            guard let skyPipelineState, let skyDepthStencilState else { continue }
                            let stageCount = min(Int(draw.stageCount), Int(Q3_METAL_MAX_STAGES))
                            guard stageCount > 0 else { continue }

                            // One-shot diagnostic: log the sky draw's stage
                            // layout so we can confirm killsky (stage0=base,
                            // stage1=additive cloud overlay) is wired end-to-end.
                            if !skyStagesLogged {
                                skyStagesLogged = true
                                print("[Metal] sky draw stageCount=\(stageCount) flags=0x\(String(draw.flags, radix: 16))")
                                for i in 0..<stageCount {
                                    let s = Self.worldStage(draw, i)
                                    let m0 = s.tcMods.0
                                    print("[Metal]   sky stage \(i): tex=\(s.textureHandle) blend=\(s.blendMode) tcModCount=\(s.tcModCount) tcMod0.type=\(m0.type) tcMod0.params=(\(m0.params.0),\(m0.params.1),\(m0.params.2),\(m0.params.3))")
                                }
                            }

                            // Render each sky stage in order. Stage 0 is the
                            // base sky (opaque through the sky pipeline with
                            // depth-write off). Subsequent stages are overlays
                            // — killsky spec sheet stage 1 is GL_ONE/GL_ONE
                            // additive. Use the stage's blendMode to decide.
                            for stageIndex in 0..<stageCount {
                                let stage = Self.worldStage(draw, stageIndex)
                                guard let skyStageTexture = texture(for: stage.textureHandle, device: view.device) else {
                                    continue
                                }
                                let isAdditive = (stageIndex > 0) && (Int(stage.blendMode) == 1)
                                let pipeline = isAdditive ? (skyAdditivePipelineState ?? skyPipelineState) : skyPipelineState
                                encoder.setRenderPipelineState(pipeline)
                                encoder.setDepthStencilState(skyDepthStencilState)
                                // Sky shaders commonly specify 'cull disable'
                                // to render the sky sphere inside-out; honour
                                // per-stage cullMode just like world stages.
                                encoder.setCullMode(Self.metalCullMode(for: stage.cullMode))
                                let skyChain = Self.fillTcMods(stage)
                                // Sky never receives fog — fogColorDistance=0.
                                var skyDrawUniforms = WorldDrawUniforms(
                                    tcGen: Float(stage.tcGen),
                                    tcModCount: skyChain.count,
                                    rgbGen: Float(stage.rgbGen),
                                    timeSeconds: timeSeconds,
                                    tcModType: skyChain.types,
                                    tcModParams0: skyChain.p0,
                                    tcModParams1: skyChain.p1,
                                    tcModParams2: skyChain.p2,
                                    tcModParams3: skyChain.p3,
                                    fogColorDistance: SIMD4<Float>(0, 0, 0, 0),
                                    debugMode: 0,
                                    forceWhiteVertColor: 0,
                                    alphaTestThreshold: 0,
                                    _pad0: 0
                                )
                                encoder.setFragmentTexture(skyStageTexture, index: 0)
                                encoder.setFragmentBytes(&skyDrawUniforms, length: MemoryLayout<WorldDrawUniforms>.stride, index: 0)
                                encoder.drawIndexedPrimitives(
                                    type: .triangle,
                                    indexCount: Int(draw.indexCount),
                                    indexType: .uint32,
                                    indexBuffer: worldIndexBuffer,
                                    indexBufferOffset: Int(draw.firstIndex) * MemoryLayout<UInt32>.stride
                                )
                            }
                            continue
                        }
                        guard let lightmapTexture = texture(for: draw.lightmapTextureHandle, device: view.device) else {
                            continue
                        }
                        let stageCount = min(Int(draw.stageCount), Int(Q3_METAL_MAX_STAGES))
                        guard stageCount > 0 else { continue }
                        for stageIndex in 0..<stageCount {
                            let stage = Self.worldStage(draw, stageIndex)
                            let blendMode = Int(stage.blendMode)
                            let drawPass = (blendMode == 1) ? 3 : ((blendMode == 2) ? 2 : ((blendMode == 3) ? 1 : 0))
                            guard drawPass == worldPass else { continue }
                            guard let baseTexture = texture(for: stage.textureHandle, device: view.device) else {
                                continue
                            }
                            if drawPass == 3, let worldAdditivePipelineState {
                                encoder.setRenderPipelineState(worldAdditivePipelineState)
                                encoder.setDepthStencilState(ensuredDepthStencilState(additiveDepthStencilState, device: view.device))
                            } else if drawPass == 2, let worldAlphaPipelineState {
                                encoder.setRenderPipelineState(worldAlphaPipelineState)
                                encoder.setDepthStencilState(ensuredDepthStencilState(additiveDepthStencilState, device: view.device))
                            } else if drawPass == 1, let worldFilterPipelineState {
                                encoder.setRenderPipelineState(worldFilterPipelineState)
                                encoder.setDepthStencilState(ensuredDepthStencilState(additiveDepthStencilState, device: view.device))
                            } else {
                                encoder.setRenderPipelineState(worldPipelineState)
                                encoder.setDepthStencilState(ensuredDepthStencilState(depthStencilState, device: view.device))
                            }
                            // STEP 6: per-stage cull mode. Replaces the
                            // previous hard-coded setCullMode(.none) which
                            // forced every world surface to two-sided.
                            encoder.setCullMode(Self.metalCullMode(for: stage.cullMode))
                            let alphaTest = Self.alphaTestThreshold(for: stage.alphaFunc)
                            let chain = Self.fillTcMods(stage)
                            // Fog lookup. draw.fogIndex is Q3_METAL_NO_FOG
                            // (0xFFFFFFFF) for surfaces outside any fog
                            // volume; on q3dm6 this is every surface. The
                            // MSL shader skips the fog mix when .w == 0.
                            let noFog = UInt32(Q3_METAL_NO_FOG)
                            var fogCD = SIMD4<Float>(0, 0, 0, 0)
                            if draw.fogIndex != noFog {
                                let count = Q3MetalRenderer_GetWorldFogCount()
                                if Int(draw.fogIndex) < count,
                                   let fogs = Q3MetalRenderer_GetWorldFogs() {
                                    let f = fogs.advanced(by: Int(draw.fogIndex)).pointee
                                    fogCD = SIMD4(f.color.0, f.color.1, f.color.2, f.distance)
                                }
                            }
                            var drawUniforms = WorldDrawUniforms(
                                tcGen: Float(stage.tcGen),
                                tcModCount: chain.count,
                                rgbGen: Float(stage.rgbGen),
                                timeSeconds: timeSeconds,
                                tcModType: chain.types,
                                tcModParams0: chain.p0,
                                tcModParams1: chain.p1,
                                tcModParams2: chain.p2,
                                tcModParams3: chain.p3,
                                fogColorDistance: fogCD,
                                debugMode: Coordinator.worldDebugMode,
                                forceWhiteVertColor: (blendMode == 1) ? 1.0 : 0.0,
                                alphaTestThreshold: alphaTest,
                                _pad0: 0.0
                            )
                            encoder.setFragmentTexture(baseTexture, index: 0)
                            encoder.setFragmentTexture(lightmapTexture, index: 1)
                            encoder.setFragmentBytes(&drawUniforms, length: MemoryLayout<WorldDrawUniforms>.stride, index: 0)
                            encoder.drawIndexedPrimitives(
                                type: .triangle,
                                indexCount: Int(draw.indexCount),
                                indexType: .uint32,
                                indexBuffer: worldIndexBuffer,
                                indexBufferOffset: Int(draw.firstIndex) * MemoryLayout<UInt32>.stride
                            )
                        }
                    }
                    } // end worldPass loop
                }

                debugFrameCounter &+= 1
                if debugFrameCounter % 60 == 0 {
                    let axis0 = SIMD3<Float>(sceneView.viewAxis.0, sceneView.viewAxis.1, sceneView.viewAxis.2)
                    let axis1 = SIMD3<Float>(sceneView.viewAxis.3, sceneView.viewAxis.4, sceneView.viewAxis.5)
                    let axis2 = SIMD3<Float>(sceneView.viewAxis.6, sceneView.viewAxis.7, sceneView.viewAxis.8)
                    let fovX = String(format: "%.2f", sceneView.fovX)
                    let fovY = String(format: "%.2f", sceneView.fovY)
                    print(
                        "[Metal] world frame \(debugFrameCounter) " +
                        "vieworg=(\(sceneView.viewOrigin.0), \(sceneView.viewOrigin.1), \(sceneView.viewOrigin.2)) " +
                        "axis0=\(formatVector(axis0)) axis1=\(formatVector(axis1)) axis2=\(formatVector(axis2)) " +
                        "fov=(\(fovX), \(fovY)) " +
                        "draws=\(snapshot.worldCommandCount) verts=\(snapshot.worldVertexCount) indices=\(snapshot.worldIndexCount)"
                    )
                    print("[Metal] world MVP \(formatMatrix(viewProjection))")
                }
            }

            if snapshot.entityCommandCount > 0,
               let entityPipelineState,
               let sceneView = Q3MetalRenderer_GetSceneView()?.pointee,
               let entityVertexBuffer = uploadEntityBuffers(device: view.device),
               let entityIndexBuffer {
                let entityViewProjection = makeWorldViewProjection(sceneView)
                let cameraPos = SIMD3<Float>(sceneView.viewOrigin.0, sceneView.viewOrigin.1, sceneView.viewOrigin.2)
                var entityUniforms = EntityUniforms(viewProjection: entityViewProjection, cameraPos: cameraPos, tcGen: 0)
                encoder.setRenderPipelineState(entityPipelineState)
                encoder.setDepthStencilState(ensuredDepthStencilState(depthStencilState, device: view.device))
                encoder.setFrontFacing(.clockwise)
                encoder.setCullMode(.none)
                encoder.setVertexBuffer(entityVertexBuffer, offset: 0, index: 0)
                encoder.setVertexBytes(&entityUniforms, length: MemoryLayout<EntityUniforms>.stride, index: 1)
                encoder.setFragmentBytes(&entityUniforms, length: MemoryLayout<EntityUniforms>.stride, index: 1)
                encoder.setFragmentSamplerState(worldSamplerState, index: 0)

                // Dlights for entities (viewmodel, players, pickups lit by
                // nearby muzzle flash / rocket glow). Same block as world pass.
                Self.bindDlightBlock(snapshot: snapshot, encoder: encoder, index: 2)

                if let entityDrawsPointer = Q3MetalRenderer_GetEntityDrawCommands() {
                    /* Multi-scene: clamp the world pass's entity loop to
                     * scene[0]'s range. The pool now contains entities for
                     * EVERY scene (world + HUD sub-scenes) back-to-back;
                     * unclamped iteration would render HUD entities at
                     * origin (0,0,0) inside the main world view. */
                    var mainEntityCount = Int(snapshot.entityCommandCount)
                    if snapshot.sceneCount > 0, let scenesPtr = Q3MetalRenderer_GetSceneSnapshots() {
                        mainEntityCount = Int(UnsafeBufferPointer(start: scenesPtr, count: 1)[0].entityCommandCount)
                    }
                    let entityDraws = UnsafeBufferPointer(start: entityDrawsPointer, count: mainEntityCount)
                    let depthHackBit = UInt32(Q3_METAL_ENTITY_DRAWFLAG_DEPTHHACK)
                    let additiveBit = UInt32(Q3_METAL_ENTITY_DRAWFLAG_ADDITIVE)
                    let alphaBit = UInt32(Q3_METAL_ENTITY_DRAWFLAG_ALPHA)
                    let filterBit = UInt32(Q3_METAL_ENTITY_DRAWFLAG_FILTER)
                    let tcGenEnvBit = UInt32(Q3_METAL_ENTITY_DRAWFLAG_TCGEN_ENV)

                    // Ordered entity passes:
                    // 0 = opaque, 1 = filter, 2 = alpha, 3 = additive.
                    for entityPass in 0..<4 {
                    for draw in entityDraws where draw.indexCount > 0 {
                        let isEntityAdditive = (draw.flags & additiveBit) != 0
                        let isEntityAlpha = (draw.flags & alphaBit) != 0
                        let isEntityFilter = (draw.flags & filterBit) != 0
                        let drawPass = isEntityAdditive ? 3 : (isEntityAlpha ? 2 : (isEntityFilter ? 1 : 0))
                        guard drawPass == entityPass else { continue }
                        guard let texture = texture(for: draw.textureHandle, device: view.device) else {
                            continue
                        }
                        let wantsDepthHack = (draw.flags & depthHackBit) != 0
                        // Per-draw tcGen flag — rebind EntityUniforms so the
                        // fragment shader picks up the current reflection-map
                        // switch. Default is 0 (mesh ST). Quad shell, regen,
                        // battlesuit carry TCGEN_ENV, sharing a viewProjection
                        // and cameraPos with the base entity pass.
                        entityUniforms.tcGen = (draw.flags & tcGenEnvBit) != 0 ? 1.0 : 0.0
                        encoder.setFragmentBytes(&entityUniforms, length: MemoryLayout<EntityUniforms>.stride, index: 1)
                        if drawPass == 3, let entityAdditivePipelineState {
                            encoder.setRenderPipelineState(entityAdditivePipelineState)
                            encoder.setDepthStencilState(ensuredDepthStencilState(additiveEntityDepthStencilState, device: view.device))
                        } else if drawPass == 2, let entityAlphaPipelineState {
                            encoder.setRenderPipelineState(entityAlphaPipelineState)
                            encoder.setDepthStencilState(ensuredDepthStencilState(additiveEntityDepthStencilState, device: view.device))
                        } else if drawPass == 1, let entityFilterPipelineState {
                            encoder.setRenderPipelineState(entityFilterPipelineState)
                            encoder.setDepthStencilState(ensuredDepthStencilState(additiveEntityDepthStencilState, device: view.device))
                        } else {
                            encoder.setRenderPipelineState(entityPipelineState)
                            let state = wantsDepthHack ? depthHackDepthStencilState : depthStencilState
                            encoder.setDepthStencilState(ensuredDepthStencilState(state, device: view.device))
                        }
                        encoder.setFragmentTexture(texture, index: 0)
                        encoder.drawIndexedPrimitives(
                            type: .triangle,
                            indexCount: Int(draw.indexCount),
                            indexType: .uint32,
                            indexBuffer: entityIndexBuffer,
                            indexBufferOffset: Int(draw.firstIndex) * MemoryLayout<UInt32>.stride
                        )
                    }
                    } // end entityPass loop
                }
            }

            /* Multi-scene HUD sub-scenes. Scene 0 is the main world view
             * handled by the blocks above. Scenes 1..sceneCount are HUD
             * portrait heads, rotating ammo pickups, scoreboard faces,
             * etc. Each has its own viewport rect + camera. Render only
             * the entities in each scene's [entityCommandFirst .. +Count)
             * range. Depth is cleared between sub-scenes by wrapping the
             * whole thing after the world pass — currently we rely on
             * each sub-scene's entities self-overlapping cleanly since
             * they all submit at origin (0,0,0) with close depths. */
            if snapshot.sceneCount > 1,
               let scenesPointer = Q3MetalRenderer_GetSceneSnapshots(),
               let entityDrawsPointer = Q3MetalRenderer_GetEntityDrawCommands(),
               let entityPipelineState,
               let entityVertexBuffer = uploadEntityBuffers(device: view.device),
               let entityIndexBuffer {
                let scenes = UnsafeBufferPointer(start: scenesPointer, count: Int(snapshot.sceneCount))
                let allEntityDraws = UnsafeBufferPointer(start: entityDrawsPointer, count: Int(snapshot.entityCommandCount))
                for sceneIdx in 1..<Int(snapshot.sceneCount) {
                    let scene = scenes[sceneIdx]
                    guard scene.entityCommandCount > 0 else { continue }
                    guard scene.viewportWidth > 0 && scene.viewportHeight > 0 else { continue }

                    encoder.setViewport(MTLViewport(
                        originX: Double(scene.viewportX),
                        originY: Double(scene.viewportY),
                        width: Double(scene.viewportWidth),
                        height: Double(scene.viewportHeight),
                        znear: 0.0, zfar: 1.0))
                    encoder.setScissorRect(MTLScissorRect(
                        x: Int(scene.viewportX),
                        y: Int(scene.viewportY),
                        width: Int(scene.viewportWidth),
                        height: Int(scene.viewportHeight)))

                    let subSceneView = Q3MetalSceneView(
                        fovX: scene.fovX, fovY: scene.fovY,
                        viewOrigin: scene.viewOrigin, viewAxis: scene.viewAxis)
                    let subViewProj = makeWorldViewProjection(subSceneView)
                    var subUniforms = EntityUniforms(viewProjection: subViewProj)

                    encoder.setRenderPipelineState(entityPipelineState)
                    /* Sub-scenes share the framebuffer's depth buffer with
                     * the world pass, so lessEqual depth-test would reject
                     * origin-space HUD geometry under world pixels at the
                     * same screen position. Use the dedicated always-pass
                     * depth state so HUD portraits render on top regardless
                     * of what the world wrote. ensuredDepthStencilState
                     * with nil falls back to lessEqual — not what we want. */
                    if let alwaysDepth = alwaysPassDepthStencilState {
                        encoder.setDepthStencilState(alwaysDepth)
                    }
                    encoder.setFrontFacing(.clockwise)
                    encoder.setCullMode(.none)
                    encoder.setVertexBuffer(entityVertexBuffer, offset: 0, index: 0)
                    encoder.setVertexBytes(&subUniforms, length: MemoryLayout<EntityUniforms>.stride, index: 1)
                    encoder.setFragmentSamplerState(worldSamplerState, index: 0)
                    Self.bindDlightBlock(snapshot: snapshot, encoder: encoder, index: 2)

                    let first = Int(scene.entityCommandFirst)
                    let rawEnd = first + Int(scene.entityCommandCount)
                    let end = min(max(first, rawEnd), allEntityDraws.count)
                    guard first < end else { continue }
                    for drawIdx in first..<end {
                        let draw = allEntityDraws[drawIdx]
                        guard draw.indexCount > 0 else { continue }
                        guard let texture = texture(for: draw.textureHandle, device: view.device) else { continue }
                        encoder.setFragmentTexture(texture, index: 0)
                        encoder.drawIndexedPrimitives(
                            type: .triangle,
                            indexCount: Int(draw.indexCount),
                            indexType: .uint32,
                            indexBuffer: entityIndexBuffer,
                            indexBufferOffset: Int(draw.firstIndex) * MemoryLayout<UInt32>.stride)
                    }
                }

                // Restore full-screen viewport for flare + UI passes
                encoder.setViewport(MTLViewport(
                    originX: 0, originY: 0,
                    width: Double(view.drawableSize.width),
                    height: Double(view.drawableSize.height),
                    znear: 0.0, zfar: 1.0))
                encoder.setScissorRect(MTLScissorRect(
                    x: 0, y: 0,
                    width: Int(view.drawableSize.width),
                    height: Int(view.drawableSize.height)))
            }

            /* Flare pass. Camera-facing additive billboards at each MST_FLARE
             * BSP surface (map-compiler light entities). Scene-constant per
             * map, recomputed per frame because quad corners are camera-
             * relative. Depth-test on with depth-write off — flares occlude
             * correctly behind walls but don't punch into the z-buffer. */
            if let sceneView = Q3MetalRenderer_GetSceneView()?.pointee,
               Q3MetalRenderer_GetFlareCount() > 0,
               Q3MetalRenderer_GetFlareTextureHandle() != 0,
               let flarePipeline = entityAdditivePipelineState,
               let flareDepth = additiveEntityDepthStencilState,
               let flareTexture = texture(for: Q3MetalRenderer_GetFlareTextureHandle(), device: view.device) {
                let flareViewProjection = makeWorldViewProjection(sceneView)
                var flareUniforms = EntityUniforms(viewProjection: flareViewProjection)
                encoder.setRenderPipelineState(flarePipeline)
                encoder.setDepthStencilState(flareDepth)
                encoder.setCullMode(.none)
                encoder.setFragmentSamplerState(worldSamplerState, index: 0)
                encoder.setFragmentTexture(flareTexture, index: 0)
                // Dlights still bound from entity pass; flare fragment path
                // shares q3_entity_fragment which reads buffer(2). Rebind
                // defensively in case a future pass clears it.
                Self.bindDlightBlock(snapshot: snapshot, encoder: encoder, index: 2)

                drawFlarePass(encoder: encoder, sceneView: sceneView, uniforms: &flareUniforms, device: view.device)
            }

            let vertexCount = Int(snapshot.vertexCount)
            if vertexCount > 0, let verticesPointer = Q3MetalRenderer_GetVertices(),
               let vertexBuffer = uploadVertices(UnsafeBufferPointer(start: verticesPointer, count: vertexCount), device: view.device) {
                let vertices = UnsafeBufferPointer(start: verticesPointer, count: vertexCount)
                let projection = makeOrthoProjection(width: max(Float(snapshot.drawableWidth), 1.0), height: max(Float(snapshot.drawableHeight), 1.0))
                var uniforms = Uniforms(projection: projection)

                encoder.setDepthStencilState(ensuredDepthStencilState(nil, device: view.device))
                encoder.setFragmentSamplerState(uiSamplerState, index: 0)
                encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)

                if let drawCommandsPointer = Q3MetalRenderer_GetDrawCommands() {
                    let drawCommands = UnsafeBufferPointer(start: drawCommandsPointer, count: Int(snapshot.commandCount))
                    var currentPipelineMode: UInt32 = UInt32.max
                    for draw in drawCommands {
                        if draw.blendMode != currentPipelineMode {
                            let pipeline: MTLRenderPipelineState? = {
                                switch draw.blendMode {
                                /* blendMode 0 (opaque) falls through to alpha-over:
                                 * Q3 2D content is universally alpha-transparent
                                 * (bigchars font atlas, HUD icons), and disabling
                                 * blending turns transparent pixels into solid
                                 * white boxes on map-load / waiting-for-players. */
                                case 1: return uiAdditivePipelineState ?? uiPipelineState
                                case 3: return uiFilterPipelineState ?? uiPipelineState
                                default: return uiPipelineState
                                }
                            }()
                            if let pipeline {
                                encoder.setRenderPipelineState(pipeline)
                            }
                            currentPipelineMode = draw.blendMode
                        }
                        if let texture = texture(for: draw.textureHandle, device: view.device) {
                            encoder.setFragmentTexture(texture, index: 0)
                            encoder.drawPrimitives(type: .triangle, vertexStart: Int(draw.firstVertex), vertexCount: Int(draw.vertexCount))
                        }
                    }
                }
            }

            encoder.endEncoding()
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }

        @MainActor
        private func configureRenderer(for view: MTKView) {
            guard let device = view.device else { return }

            commandQueue = device.makeCommandQueue()

            let library: MTLLibrary
            do {
                library = try device.makeLibrary(source: shaderSource, options: nil)
            } catch {
                print("[Metal] Failed to compile UI shaders: \\(error)")
                return
            }

            let pipelineDescriptor = MTLRenderPipelineDescriptor()
            pipelineDescriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
            pipelineDescriptor.depthAttachmentPixelFormat = view.depthStencilPixelFormat
            pipelineDescriptor.vertexFunction = library.makeFunction(name: "q3_ui_vertex")
            pipelineDescriptor.fragmentFunction = library.makeFunction(name: "q3_ui_fragment")
            pipelineDescriptor.colorAttachments[0].isBlendingEnabled = true
            pipelineDescriptor.colorAttachments[0].rgbBlendOperation = .add
            pipelineDescriptor.colorAttachments[0].alphaBlendOperation = .add
            pipelineDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            pipelineDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
            pipelineDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            pipelineDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

            do {
                uiPipelineState = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
            } catch {
                print("[Metal] Failed to create UI pipeline: \\(error)")
            }

            // Per-blend-mode variants of the UI pipeline. Each Q3MetalDrawCmd
            // carries a blendMode propagated from its shader's resolved blend,
            // so 2D stages like the loading-screen `levelShotDetail` overlay
            // multiply against the levelshot (filter) instead of washing the
            // screen out as plain source-over alpha.
            let uiOpaqueDesc = MTLRenderPipelineDescriptor()
            uiOpaqueDesc.colorAttachments[0].pixelFormat = view.colorPixelFormat
            uiOpaqueDesc.depthAttachmentPixelFormat = view.depthStencilPixelFormat
            uiOpaqueDesc.vertexFunction = library.makeFunction(name: "q3_ui_vertex")
            uiOpaqueDesc.fragmentFunction = library.makeFunction(name: "q3_ui_fragment")
            uiOpaqueDesc.colorAttachments[0].isBlendingEnabled = false
            do {
                uiOpaquePipelineState = try device.makeRenderPipelineState(descriptor: uiOpaqueDesc)
            } catch {
                print("[Metal] Failed to create UI opaque pipeline: \\(error)")
            }

            let uiAdditiveDesc = MTLRenderPipelineDescriptor()
            uiAdditiveDesc.colorAttachments[0].pixelFormat = view.colorPixelFormat
            uiAdditiveDesc.depthAttachmentPixelFormat = view.depthStencilPixelFormat
            uiAdditiveDesc.vertexFunction = library.makeFunction(name: "q3_ui_vertex")
            uiAdditiveDesc.fragmentFunction = library.makeFunction(name: "q3_ui_fragment")
            uiAdditiveDesc.colorAttachments[0].isBlendingEnabled = true
            uiAdditiveDesc.colorAttachments[0].rgbBlendOperation = .add
            uiAdditiveDesc.colorAttachments[0].alphaBlendOperation = .add
            uiAdditiveDesc.colorAttachments[0].sourceRGBBlendFactor = .one
            uiAdditiveDesc.colorAttachments[0].sourceAlphaBlendFactor = .one
            uiAdditiveDesc.colorAttachments[0].destinationRGBBlendFactor = .one
            uiAdditiveDesc.colorAttachments[0].destinationAlphaBlendFactor = .one
            do {
                uiAdditivePipelineState = try device.makeRenderPipelineState(descriptor: uiAdditiveDesc)
            } catch {
                print("[Metal] Failed to create UI additive pipeline: \\(error)")
            }

            let uiFilterDesc = MTLRenderPipelineDescriptor()
            uiFilterDesc.colorAttachments[0].pixelFormat = view.colorPixelFormat
            uiFilterDesc.depthAttachmentPixelFormat = view.depthStencilPixelFormat
            uiFilterDesc.vertexFunction = library.makeFunction(name: "q3_ui_vertex")
            uiFilterDesc.fragmentFunction = library.makeFunction(name: "q3_ui_fragment")
            uiFilterDesc.colorAttachments[0].isBlendingEnabled = true
            uiFilterDesc.colorAttachments[0].rgbBlendOperation = .add
            uiFilterDesc.colorAttachments[0].alphaBlendOperation = .add
            uiFilterDesc.colorAttachments[0].sourceRGBBlendFactor = .destinationColor
            uiFilterDesc.colorAttachments[0].sourceAlphaBlendFactor = .destinationAlpha
            uiFilterDesc.colorAttachments[0].destinationRGBBlendFactor = .zero
            uiFilterDesc.colorAttachments[0].destinationAlphaBlendFactor = .zero
            do {
                uiFilterPipelineState = try device.makeRenderPipelineState(descriptor: uiFilterDesc)
            } catch {
                print("[Metal] Failed to create UI filter pipeline: \\(error)")
            }

            let worldPipelineDescriptor = MTLRenderPipelineDescriptor()
            worldPipelineDescriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
            worldPipelineDescriptor.depthAttachmentPixelFormat = view.depthStencilPixelFormat
            worldPipelineDescriptor.vertexFunction = library.makeFunction(name: "q3_world_vertex")
            worldPipelineDescriptor.fragmentFunction = library.makeFunction(name: "q3_world_fragment")

            do {
                worldPipelineState = try device.makeRenderPipelineState(descriptor: worldPipelineDescriptor)
            } catch {
                print("[Metal] Failed to create world pipeline: \\(error)")
            }

            let worldFilterPipelineDescriptor = worldPipelineDescriptor.copy() as! MTLRenderPipelineDescriptor
            worldFilterPipelineDescriptor.colorAttachments[0].isBlendingEnabled = true
            worldFilterPipelineDescriptor.colorAttachments[0].rgbBlendOperation = .add
            worldFilterPipelineDescriptor.colorAttachments[0].alphaBlendOperation = .add
            worldFilterPipelineDescriptor.colorAttachments[0].sourceRGBBlendFactor = .destinationColor
            worldFilterPipelineDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
            worldFilterPipelineDescriptor.colorAttachments[0].destinationRGBBlendFactor = .zero
            worldFilterPipelineDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .zero
            do {
                worldFilterPipelineState = try device.makeRenderPipelineState(descriptor: worldFilterPipelineDescriptor)
            } catch {
                print("[Metal] Failed to create filter world pipeline: \\(error)")
            }

            let worldAlphaPipelineDescriptor = worldPipelineDescriptor.copy() as! MTLRenderPipelineDescriptor
            worldAlphaPipelineDescriptor.colorAttachments[0].isBlendingEnabled = true
            worldAlphaPipelineDescriptor.colorAttachments[0].rgbBlendOperation = .add
            worldAlphaPipelineDescriptor.colorAttachments[0].alphaBlendOperation = .add
            worldAlphaPipelineDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            worldAlphaPipelineDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
            worldAlphaPipelineDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            worldAlphaPipelineDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            do {
                worldAlphaPipelineState = try device.makeRenderPipelineState(descriptor: worldAlphaPipelineDescriptor)
            } catch {
                print("[Metal] Failed to create alpha world pipeline: \\(error)")
            }

            let worldAdditivePipelineDescriptor = worldPipelineDescriptor.copy() as! MTLRenderPipelineDescriptor
            worldAdditivePipelineDescriptor.colorAttachments[0].isBlendingEnabled = true
            worldAdditivePipelineDescriptor.colorAttachments[0].rgbBlendOperation = .add
            worldAdditivePipelineDescriptor.colorAttachments[0].alphaBlendOperation = .add
            worldAdditivePipelineDescriptor.colorAttachments[0].sourceRGBBlendFactor = .one
            worldAdditivePipelineDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
            worldAdditivePipelineDescriptor.colorAttachments[0].destinationRGBBlendFactor = .one
            worldAdditivePipelineDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .one

            do {
                worldAdditivePipelineState = try device.makeRenderPipelineState(descriptor: worldAdditivePipelineDescriptor)
            } catch {
                print("[Metal] Failed to create additive world pipeline: \\(error)")
            }

            // Sky pipeline: view-direction spherical projection. No blending,
            // no depth write (depth test still uses lessEqual so if anything
            // draws over sky it occludes correctly — but sky vertex shader
            // pushes z=w so sky is always at the far plane).
            let skyPipelineDescriptor = MTLRenderPipelineDescriptor()
            skyPipelineDescriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
            skyPipelineDescriptor.depthAttachmentPixelFormat = view.depthStencilPixelFormat
            skyPipelineDescriptor.vertexFunction = library.makeFunction(name: "q3_sky_vertex")
            skyPipelineDescriptor.fragmentFunction = library.makeFunction(name: "q3_sky_fragment")
            do {
                skyPipelineState = try device.makeRenderPipelineState(descriptor: skyPipelineDescriptor)
            } catch {
                print("[Metal] Failed to create sky pipeline: \\(error)")
            }

            // Additive sky pipeline for stage 1+ cloud layers (killsky_2
            // over killsky_1). src=ONE, dst=ONE.
            let skyAdditiveDescriptor = skyPipelineDescriptor.copy() as! MTLRenderPipelineDescriptor
            skyAdditiveDescriptor.colorAttachments[0].isBlendingEnabled = true
            skyAdditiveDescriptor.colorAttachments[0].rgbBlendOperation = .add
            skyAdditiveDescriptor.colorAttachments[0].alphaBlendOperation = .add
            skyAdditiveDescriptor.colorAttachments[0].sourceRGBBlendFactor = .one
            skyAdditiveDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
            skyAdditiveDescriptor.colorAttachments[0].destinationRGBBlendFactor = .one
            skyAdditiveDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .one
            do {
                skyAdditivePipelineState = try device.makeRenderPipelineState(descriptor: skyAdditiveDescriptor)
            } catch {
                print("[Metal] Failed to create additive sky pipeline: \\(error)")
            }

            let skyDepthDescriptor = MTLDepthStencilDescriptor()
            skyDepthDescriptor.depthCompareFunction = .lessEqual
            skyDepthDescriptor.isDepthWriteEnabled = false
            skyDepthStencilState = device.makeDepthStencilState(descriptor: skyDepthDescriptor)

            let entityPipelineDescriptor = MTLRenderPipelineDescriptor()
            entityPipelineDescriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
            entityPipelineDescriptor.depthAttachmentPixelFormat = view.depthStencilPixelFormat
            entityPipelineDescriptor.vertexFunction = library.makeFunction(name: "q3_entity_vertex")
            entityPipelineDescriptor.fragmentFunction = library.makeFunction(name: "q3_entity_fragment")

            do {
                entityPipelineState = try device.makeRenderPipelineState(descriptor: entityPipelineDescriptor)
            } catch {
                print("[Metal] Failed to create entity pipeline: \\(error)")
            }

            // Additive entity pipeline (flames, health orb glow, etc.)
            let entityAdditiveDesc = MTLRenderPipelineDescriptor()
            entityAdditiveDesc.colorAttachments[0].pixelFormat = view.colorPixelFormat
            entityAdditiveDesc.colorAttachments[0].isBlendingEnabled = true
            entityAdditiveDesc.colorAttachments[0].sourceRGBBlendFactor = .one
            entityAdditiveDesc.colorAttachments[0].destinationRGBBlendFactor = .one
            entityAdditiveDesc.colorAttachments[0].sourceAlphaBlendFactor = .one
            entityAdditiveDesc.colorAttachments[0].destinationAlphaBlendFactor = .one
            entityAdditiveDesc.depthAttachmentPixelFormat = view.depthStencilPixelFormat
            entityAdditiveDesc.vertexFunction = library.makeFunction(name: "q3_entity_vertex")
            entityAdditiveDesc.fragmentFunction = library.makeFunction(name: "q3_entity_fragment")
            do {
                entityAdditivePipelineState = try device.makeRenderPipelineState(descriptor: entityAdditiveDesc)
            } catch {
                print("[Metal] Failed to create additive entity pipeline: \\(error)")
            }

            let entityAlphaDesc = MTLRenderPipelineDescriptor()
            entityAlphaDesc.colorAttachments[0].pixelFormat = view.colorPixelFormat
            entityAlphaDesc.colorAttachments[0].isBlendingEnabled = true
            entityAlphaDesc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            entityAlphaDesc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            entityAlphaDesc.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
            entityAlphaDesc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            entityAlphaDesc.depthAttachmentPixelFormat = view.depthStencilPixelFormat
            entityAlphaDesc.vertexFunction = library.makeFunction(name: "q3_entity_vertex")
            entityAlphaDesc.fragmentFunction = library.makeFunction(name: "q3_entity_fragment")
            do {
                entityAlphaPipelineState = try device.makeRenderPipelineState(descriptor: entityAlphaDesc)
            } catch {
                print("[Metal] Failed to create alpha entity pipeline: \\(error)")
            }

            let entityFilterDesc = MTLRenderPipelineDescriptor()
            entityFilterDesc.colorAttachments[0].pixelFormat = view.colorPixelFormat
            entityFilterDesc.colorAttachments[0].isBlendingEnabled = true
            entityFilterDesc.colorAttachments[0].sourceRGBBlendFactor = .destinationColor
            entityFilterDesc.colorAttachments[0].destinationRGBBlendFactor = .zero
            entityFilterDesc.colorAttachments[0].sourceAlphaBlendFactor = .one
            entityFilterDesc.colorAttachments[0].destinationAlphaBlendFactor = .zero
            entityFilterDesc.depthAttachmentPixelFormat = view.depthStencilPixelFormat
            entityFilterDesc.vertexFunction = library.makeFunction(name: "q3_entity_vertex")
            entityFilterDesc.fragmentFunction = library.makeFunction(name: "q3_entity_fragment")
            do {
                entityFilterPipelineState = try device.makeRenderPipelineState(descriptor: entityFilterDesc)
            } catch {
                print("[Metal] Failed to create filter entity pipeline: \\(error)")
            }

            // Depth state for additive entities — read but no write
            let additiveEntityDepthDesc = MTLDepthStencilDescriptor()
            additiveEntityDepthDesc.depthCompareFunction = .lessEqual
            additiveEntityDepthDesc.isDepthWriteEnabled = false
            additiveEntityDepthStencilState = device.makeDepthStencilState(descriptor: additiveEntityDepthDesc)

            // Always-pass depth for multi-scene HUD sub-scenes
            let alwaysPassDesc = MTLDepthStencilDescriptor()
            alwaysPassDesc.depthCompareFunction = .always
            alwaysPassDesc.isDepthWriteEnabled = false
            alwaysPassDepthStencilState = device.makeDepthStencilState(descriptor: alwaysPassDesc)

            let uiSamplerDescriptor = MTLSamplerDescriptor()
            uiSamplerDescriptor.minFilter = .linear
            uiSamplerDescriptor.magFilter = .linear
            uiSamplerDescriptor.sAddressMode = .clampToEdge
            uiSamplerDescriptor.tAddressMode = .clampToEdge
            uiSamplerState = device.makeSamplerState(descriptor: uiSamplerDescriptor)

            let worldSamplerDescriptor = MTLSamplerDescriptor()
            worldSamplerDescriptor.minFilter = .linear
            worldSamplerDescriptor.magFilter = .linear
            worldSamplerDescriptor.sAddressMode = .repeat
            worldSamplerDescriptor.tAddressMode = .repeat
            worldSamplerState = device.makeSamplerState(descriptor: worldSamplerDescriptor)

            let depthDescriptor = MTLDepthStencilDescriptor()
            depthDescriptor.isDepthWriteEnabled = true
            depthDescriptor.depthCompareFunction = .lessEqual
            depthStencilState = device.makeDepthStencilState(descriptor: depthDescriptor)

            let additiveDepthDescriptor = MTLDepthStencilDescriptor()
            additiveDepthDescriptor.isDepthWriteEnabled = false
            additiveDepthDescriptor.depthCompareFunction = .lessEqual
            additiveDepthStencilState = device.makeDepthStencilState(descriptor: additiveDepthDescriptor)

            // Depth-hack state for first-person viewmodel (STEP 8).
            // Q3's depth-hack trick compresses the weapon's depth range so
            // the gun isn't clipped by walls. Depth TEST still runs with
            // .lessEqual so the model's OWN parts occlude each other
            // correctly; the previous .always disabled the test entirely,
            // which broke self-occlusion inside the weapon mesh (e.g.
            // barrel showing through the gun body).
            let depthHackDescriptor = MTLDepthStencilDescriptor()
            depthHackDescriptor.isDepthWriteEnabled = true
            depthHackDescriptor.depthCompareFunction = .lessEqual
            depthHackDepthStencilState = device.makeDepthStencilState(descriptor: depthHackDescriptor)
        }

        private func uploadVertices(_ vertices: UnsafeBufferPointer<Q3MetalVertex>, device: MTLDevice?) -> MTLBuffer? {
            guard let device else { return nil }

            let requiredLength = vertices.count * MemoryLayout<GPUVertex>.stride
            if requiredLength == 0 {
                return nil
            }

            if vertexBuffer == nil || requiredLength > vertexBufferCapacity {
                let nextCapacity = max(requiredLength, max(vertexBufferCapacity * 2, 4096))
                vertexBuffer = device.makeBuffer(length: nextCapacity, options: .storageModeShared)
                vertexBufferCapacity = nextCapacity
            }

            guard let vertexBuffer, let rawPointer = vertexBuffer.contents().bindMemory(to: GPUVertex.self, capacity: vertices.count) as UnsafeMutablePointer<GPUVertex>? else {
                return nil
            }

            for i in 0..<vertices.count {
                let vertex = vertices[i]
                rawPointer[i] = GPUVertex(
                    position: SIMD2<Float>(vertex.position.0, vertex.position.1),
                    texCoord: SIMD2<Float>(vertex.texCoord.0, vertex.texCoord.1),
                    color: SIMD4<Float>(vertex.color.0, vertex.color.1, vertex.color.2, vertex.color.3)
                )
            }

            return vertexBuffer
        }

        private func uploadWorldBuffers(device: MTLDevice?, generation: UInt32) -> MTLBuffer? {
            guard let device,
                  let verticesPointer = Q3MetalRenderer_GetWorldVertices(),
                  let indicesPointer = Q3MetalRenderer_GetWorldIndices(),
                  let snapshot = Q3MetalRenderer_GetFrameSnapshot()?.pointee
            else { return nil }

            if cachedWorldGeneration == generation, let worldVertexBuffer {
                return worldVertexBuffer
            }

            let vertexCount = Int(snapshot.worldVertexCount)
            let indexCount = Int(snapshot.worldIndexCount)
            guard vertexCount > 0, indexCount > 0 else { return nil }

            let sourceVertices = UnsafeBufferPointer(start: verticesPointer, count: vertexCount)
            var gpuVertices = [GPUWorldVertex]()
            gpuVertices.reserveCapacity(vertexCount)
            for vertex in sourceVertices {
                    gpuVertices.append(
                        GPUWorldVertex(
                            position: SIMD3<Float>(vertex.position.0, vertex.position.1, vertex.position.2),
                            texCoord: SIMD2<Float>(vertex.texCoord.0, vertex.texCoord.1),
                            lightmapTexCoord: SIMD2<Float>(vertex.lightmapTexCoord.0, vertex.lightmapTexCoord.1),
                            color: SIMD4<Float>(vertex.color.0, vertex.color.1, vertex.color.2, vertex.color.3)
                        )
                    )
                }

            let sourceIndices = UnsafeBufferPointer(start: indicesPointer, count: indexCount)
            guard let sourceIndexBase = sourceIndices.baseAddress else {
                return nil
            }
            worldVertexBuffer = device.makeBuffer(
                bytes: gpuVertices,
                length: gpuVertices.count * MemoryLayout<GPUWorldVertex>.stride,
                options: .storageModeShared
            )
            worldIndexBuffer = device.makeBuffer(
                bytes: sourceIndexBase,
                length: sourceIndices.count * MemoryLayout<UInt32>.stride,
                options: .storageModeShared
            )
            cachedWorldGeneration = generation
            return worldVertexBuffer
        }

        private func uploadEntityBuffers(device: MTLDevice?) -> MTLBuffer? {
            guard let device,
                  let snapshot = Q3MetalRenderer_GetFrameSnapshot()?.pointee,
                  let verticesPointer = Q3MetalRenderer_GetEntityVertices(),
                  let indicesPointer = Q3MetalRenderer_GetEntityIndices()
            else { return nil }

            let vertexCount = Int(snapshot.entityVertexCount)
            let indexCount = Int(snapshot.entityIndexCount)
            guard vertexCount > 0, indexCount > 0 else { return nil }

            let vertexLength = vertexCount * MemoryLayout<GPUEntityVertex>.stride
            if entityVertexBuffer == nil || vertexLength > entityVertexBufferCapacity {
                let nextCapacity = max(vertexLength, max(entityVertexBufferCapacity * 2, 4096))
                entityVertexBuffer = device.makeBuffer(length: nextCapacity, options: .storageModeShared)
                entityVertexBufferCapacity = nextCapacity
            }

            guard let entityVertexBuffer,
                  let rawVertexPointer = entityVertexBuffer.contents().bindMemory(to: GPUEntityVertex.self, capacity: vertexCount) as UnsafeMutablePointer<GPUEntityVertex>?
            else {
                return nil
            }

            let sourceVertices = UnsafeBufferPointer(start: verticesPointer, count: vertexCount)
            for i in 0..<vertexCount {
                let vertex = sourceVertices[i]
                rawVertexPointer[i] = GPUEntityVertex(
                    position: SIMD3<Float>(vertex.position.0, vertex.position.1, vertex.position.2),
                    texCoord: SIMD2<Float>(vertex.texCoord.0, vertex.texCoord.1),
                    color: SIMD4<Float>(vertex.color.0, vertex.color.1, vertex.color.2, vertex.color.3)
                )
            }

            let indexLength = indexCount * MemoryLayout<UInt32>.stride
            if entityIndexBuffer == nil || indexLength > entityIndexBufferCapacity {
                let nextCapacity = max(indexLength, max(entityIndexBufferCapacity * 2, 4096))
                entityIndexBuffer = device.makeBuffer(length: nextCapacity, options: .storageModeShared)
                entityIndexBufferCapacity = nextCapacity
            }

            guard let entityIndexBuffer,
                  let rawIndexPointer = entityIndexBuffer.contents().bindMemory(to: UInt32.self, capacity: indexCount) as UnsafeMutablePointer<UInt32>?
            else {
                return nil
            }

            let sourceIndices = UnsafeBufferPointer(start: indicesPointer, count: indexCount)
            for i in 0..<indexCount {
                rawIndexPointer[i] = sourceIndices[i]
            }

            return entityVertexBuffer
        }

        private func texture(for handle: UInt32, device: MTLDevice?) -> MTLTexture? {
            guard let device else { return nil }

            var info = Q3MetalTextureInfo()
            guard Q3MetalRenderer_GetTextureInfo(handle, &info) != 0,
                  let rgbaBytes = info.rgbaBytes
            else {
                return nil
            }

            guard info.width > 0, info.height > 0 else {
                return nil
            }

            if let cached = textureCache[handle], cached.generation == info.generation {
                return cached.texture
            }

            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba8Unorm,
                width: Int(info.width),
                height: Int(info.height),
                mipmapped: false
            )
            descriptor.usage = .shaderRead

            guard let texture = device.makeTexture(descriptor: descriptor) else {
                return nil
            }

            let bytesPerRow = Int(info.width) * 4
            texture.replace(
                region: MTLRegionMake2D(0, 0, Int(info.width), Int(info.height)),
                mipmapLevel: 0,
                withBytes: rgbaBytes,
                bytesPerRow: bytesPerRow
            )

            textureCache[handle] = (generation: info.generation, texture: texture)
            return texture
        }

        private func makeOrthoProjection(width: Float, height: Float) -> simd_float4x4 {
            simd_float4x4(columns: (
                SIMD4<Float>(2.0 / width, 0, 0, 0),
                SIMD4<Float>(0, -2.0 / height, 0, 0),
                SIMD4<Float>(0, 0, 1, 0),
                SIMD4<Float>(-1, 1, 0, 1)
            ))
        }

        /* Build and draw camera-facing additive billboards for each BSP flare.
         * Called inside an already-configured render pass: caller bound
         * pipeline, depth-stencil, sampler, flare texture, and dlight block.
         * We allocate a transient per-frame vertex buffer sized to the flare
         * count × 4 corners. Flare size is fixed at 16 world units — the Q3
         * behavior of world-space billboards that shrink with distance is
         * visually acceptable for phase-one. */
        private func drawFlarePass(encoder: MTLRenderCommandEncoder,
                                   sceneView: Q3MetalSceneView,
                                   uniforms: inout EntityUniforms,
                                   device: MTLDevice?) {
            guard let device,
                  let flaresPointer = Q3MetalRenderer_GetFlares() else { return }
            let flareCount = Int(Q3MetalRenderer_GetFlareCount())
            guard flareCount > 0 else { return }

            // Q3 axis convention: axis0=forward, axis1=left, axis2=up.
            // Billboard plane spans (-axis1, axis2) — rotating left into
            // "right" flips axis1 so +X on the quad is visually rightward.
            let axis1 = SIMD3<Float>(sceneView.viewAxis.3, sceneView.viewAxis.4, sceneView.viewAxis.5)
            let axis2 = SIMD3<Float>(sceneView.viewAxis.6, sceneView.viewAxis.7, sceneView.viewAxis.8)
            let right = -axis1
            let up = axis2
            let halfSize: Float = 16.0

            let corners: [(SIMD2<Float>, SIMD2<Float>)] = [
                (SIMD2(-1, -1), SIMD2(0, 1)),
                (SIMD2( 1, -1), SIMD2(1, 1)),
                (SIMD2( 1,  1), SIMD2(1, 0)),
                (SIMD2(-1,  1), SIMD2(0, 0)),
            ]

            var vertices = [Q3MetalEntityVertex]()
            vertices.reserveCapacity(flareCount * 4)
            var indices = [UInt32]()
            indices.reserveCapacity(flareCount * 6)

            let flares = UnsafeBufferPointer(start: flaresPointer, count: flareCount)
            for (i, flare) in flares.enumerated() {
                let origin = SIMD3<Float>(flare.origin.0, flare.origin.1, flare.origin.2)
                let color = SIMD3<Float>(flare.color.0, flare.color.1, flare.color.2)
                let base = UInt32(i * 4)
                for (corner, uv) in corners {
                    let p = origin + right * (corner.x * halfSize) + up * (corner.y * halfSize)
                    var vert = Q3MetalEntityVertex(
                        position: (p.x, p.y, p.z),
                        texCoord: (uv.x, uv.y),
                        color: (color.x, color.y, color.z, 1.0)
                    )
                    vertices.append(vert)
                }
                indices.append(contentsOf: [base, base + 1, base + 2, base, base + 2, base + 3])
            }

            let vertStride = MemoryLayout<Q3MetalEntityVertex>.stride
            guard let vertexBuffer = device.makeBuffer(
                bytes: vertices,
                length: vertices.count * vertStride,
                options: .storageModeShared
            ),
            let indexBuffer = device.makeBuffer(
                bytes: indices,
                length: indices.count * MemoryLayout<UInt32>.stride,
                options: .storageModeShared
            ) else { return }

            encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<EntityUniforms>.stride, index: 1)
            encoder.drawIndexedPrimitives(
                type: .triangle,
                indexCount: indices.count,
                indexType: .uint32,
                indexBuffer: indexBuffer,
                indexBufferOffset: 0
            )
        }

        private func makeWorldViewProjection(_ sceneView: Q3MetalSceneView) -> simd_float4x4 {
            let origin = SIMD3<Float>(sceneView.viewOrigin.0, sceneView.viewOrigin.1, sceneView.viewOrigin.2)
            let axis0 = SIMD3<Float>(sceneView.viewAxis.0, sceneView.viewAxis.1, sceneView.viewAxis.2)
            let axis1 = SIMD3<Float>(sceneView.viewAxis.3, sceneView.viewAxis.4, sceneView.viewAxis.5)
            let axis2 = SIMD3<Float>(sceneView.viewAxis.6, sceneView.viewAxis.7, sceneView.viewAxis.8)

            let viewer = simd_float4x4(columns: (
                SIMD4<Float>(axis0.x, axis1.x, axis2.x, 0),
                SIMD4<Float>(axis0.y, axis1.y, axis2.y, 0),
                SIMD4<Float>(axis0.z, axis1.z, axis2.z, 0),
                SIMD4<Float>(-simd_dot(origin, axis0), -simd_dot(origin, axis1), -simd_dot(origin, axis2), 1)
            ))

            let flip = simd_float4x4(columns: (
                SIMD4<Float>(0, 0, -1, 0),
                SIMD4<Float>(-1, 0, 0, 0),
                SIMD4<Float>(0, 1, 0, 0),
                SIMD4<Float>(0, 0, 0, 1)
            ))

            let zNear: Float = 4.0
            let zFar: Float = 8192.0
            let xScale = 1.0 / tan(sceneView.fovX * .pi / 360.0)
            let yScale = 1.0 / tan(sceneView.fovY * .pi / 360.0)
            let depth = zFar - zNear
            let quakeProjection = simd_float4x4(columns: (
                SIMD4<Float>(xScale, 0, 0, 0),
                SIMD4<Float>(0, yScale, 0, 0),
                SIMD4<Float>(0, 0, -(zFar + zNear) / depth, -1),
                SIMD4<Float>(0, 0, -(2 * zFar * zNear) / depth, 0)
            ))

            // Quake's legacy projection targets OpenGL clip space. Metal keeps the
            // same XY clip rules but uses a 0...1 depth range instead of -1...1.
            let openGLToMetalClip = simd_float4x4(columns: (
                SIMD4<Float>(1, 0, 0, 0),
                SIMD4<Float>(0, 1, 0, 0),
                SIMD4<Float>(0, 0, 0.5, 0),
                SIMD4<Float>(0, 0, 0.5, 1)
            ))

            return openGLToMetalClip * quakeProjection * flip * viewer
        }

        private func formatVector(_ vector: SIMD3<Float>) -> String {
            String(format: "(%.3f, %.3f, %.3f)", vector.x, vector.y, vector.z)
        }

        private func formatMatrix(_ matrix: simd_float4x4) -> String {
            let c0 = matrix.columns.0
            let c1 = matrix.columns.1
            let c2 = matrix.columns.2
            let c3 = matrix.columns.3
            return String(
                format: "[[%.3f, %.3f, %.3f, %.3f], [%.3f, %.3f, %.3f, %.3f], [%.3f, %.3f, %.3f, %.3f], [%.3f, %.3f, %.3f, %.3f]]",
                c0.x, c0.y, c0.z, c0.w,
                c1.x, c1.y, c1.z, c1.w,
                c2.x, c2.y, c2.z, c2.w,
                c3.x, c3.y, c3.z, c3.w
            )
        }
    }
}

@MainActor
final class GameControllerBridge {
    static let shared = GameControllerBridge()

    private struct State {
        var leftX: Float = 0
        var leftY: Float = 0
        var rightX: Float = 0
        var rightY: Float = 0
        var firePressed: Int32 = 0
        var jumpPressed: Int32 = 0
        var crouchPressed: Int32 = 0
        var buttonMask: UInt32 = 0
    }

    /* Mirror of code/ios/ios_local.h Q3_PAD_* bits. */
    private struct PadBit {
        static let a:              UInt32 = 1 << 0
        static let b:              UInt32 = 1 << 1
        static let x:              UInt32 = 1 << 2
        static let y:              UInt32 = 1 << 3
        static let leftShoulder:   UInt32 = 1 << 4
        static let rightShoulder:  UInt32 = 1 << 5
        static let leftTrigger:    UInt32 = 1 << 6
        static let rightTrigger:   UInt32 = 1 << 7
        static let dpadUp:         UInt32 = 1 << 8
        static let dpadDown:       UInt32 = 1 << 9
        static let dpadLeft:       UInt32 = 1 << 10
        static let dpadRight:      UInt32 = 1 << 11
        static let menu:           UInt32 = 1 << 12
        static let options:        UInt32 = 1 << 13
        static let leftThumb:      UInt32 = 1 << 14
        static let rightThumb:     UInt32 = 1 << 15
    }

    private var started = false
    private var activeController: GCController?
    private var state = State()
    private var lastLoggedState: State?

    private init() {}

    func start() {
        guard !started else { return }
        started = true

        print("[GCController] start")

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(controllerDidConnect(_:)),
            name: .GCControllerDidConnect,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(controllerDidDisconnect(_:)),
            name: .GCControllerDidDisconnect,
            object: nil
        )

        print("[GCController] existing controllers: \(GCController.controllers().count)")
        for controller in GCController.controllers() {
            print("[GCController] existing \(describe(controller))")
        }

        GCController.startWirelessControllerDiscovery { [weak self] in
            print("[GCController] wireless discovery completed")
            Task { @MainActor in
                self?.pickActiveController()
            }
        }
        pickActiveController()
    }

    @objc private func controllerDidConnect(_ notification: Notification) {
        if let controller = notification.object as? GCController {
            print("[GCController] connected \(describe(controller))")
        } else {
            print("[GCController] connected unknown controller")
        }
        pickActiveController(preferred: notification.object as? GCController)
    }

    @objc private func controllerDidDisconnect(_ notification: Notification) {
        let disconnected = notification.object as? GCController
        if activeController === disconnected {
            activeController = nil
            state = State()
            lastLoggedState = nil
            pushState()
        }
        if let disconnected {
            print("[GCController] disconnected \(describe(disconnected))")
        } else {
            print("[GCController] disconnected unknown controller")
        }
        pickActiveController()
    }

    private func pickActiveController(preferred: GCController? = nil) {
        let nextController = [preferred, activeController]
            .compactMap { $0 }
            .first { $0.extendedGamepad != nil }
            ?? GCController.controllers().first { $0.extendedGamepad != nil }

        guard activeController !== nextController else {
            return
        }

        activeController?.extendedGamepad?.valueChangedHandler = nil
        activeController = nextController
        state = State()
        lastLoggedState = nil
        pushState()

        guard let controller = nextController, let gamepad = controller.extendedGamepad else {
            print("[GCController] no extended gamepad controller selected")
            return
        }

        controller.playerIndex = .index1
        controller.handlerQueue = .main
        gamepad.valueChangedHandler = { [weak self] gamepad, element in
            self?.ingest(gamepad: gamepad, source: element)
        }
        ingest(gamepad: gamepad, source: nil)
        print("[GCController] using \(describe(controller))")
    }

    private func ingest(gamepad: GCExtendedGamepad, source: GCControllerElement?) {
        state.leftX = gamepad.leftThumbstick.xAxis.value
        state.leftY = gamepad.leftThumbstick.yAxis.value
        state.rightX = gamepad.rightThumbstick.xAxis.value
        state.rightY = gamepad.rightThumbstick.yAxis.value
        state.firePressed = gamepad.rightTrigger.isPressed ? 1 : 0
        state.jumpPressed = gamepad.buttonA.isPressed ? 1 : 0
        state.crouchPressed = gamepad.buttonB.isPressed ? 1 : 0

        var mask: UInt32 = 0
        if gamepad.buttonA.isPressed             { mask |= PadBit.a }
        if gamepad.buttonB.isPressed             { mask |= PadBit.b }
        if gamepad.buttonX.isPressed             { mask |= PadBit.x }
        if gamepad.buttonY.isPressed             { mask |= PadBit.y }
        if gamepad.leftShoulder.isPressed        { mask |= PadBit.leftShoulder }
        if gamepad.rightShoulder.isPressed       { mask |= PadBit.rightShoulder }
        if gamepad.leftTrigger.isPressed         { mask |= PadBit.leftTrigger }
        if gamepad.rightTrigger.isPressed        { mask |= PadBit.rightTrigger }
        if gamepad.dpad.up.isPressed             { mask |= PadBit.dpadUp }
        if gamepad.dpad.down.isPressed           { mask |= PadBit.dpadDown }
        if gamepad.dpad.left.isPressed           { mask |= PadBit.dpadLeft }
        if gamepad.dpad.right.isPressed          { mask |= PadBit.dpadRight }
        if gamepad.buttonMenu.isPressed          { mask |= PadBit.menu }
        if gamepad.buttonOptions?.isPressed == true { mask |= PadBit.options }
        if gamepad.leftThumbstickButton?.isPressed == true  { mask |= PadBit.leftThumb }
        if gamepad.rightThumbstickButton?.isPressed == true { mask |= PadBit.rightThumb }
        state.buttonMask = mask

        logStateChange(source: source)
        pushState()
    }

    private func pushState() {
        // Feed the engine continuously from the latest controller sample.
        Q3Gamepad_SetState(
            state.leftX,
            state.leftY,
            state.rightX,
            state.rightY,
            state.firePressed,
            state.jumpPressed,
            state.crouchPressed
        )
        Q3Gamepad_SetButtons(state.buttonMask)
    }

    private func logStateChange(source: GCControllerElement?) {
        let shouldLog: Bool
        if let lastLoggedState {
            shouldLog =
                abs(state.leftX - lastLoggedState.leftX) >= 0.05 ||
                abs(state.leftY - lastLoggedState.leftY) >= 0.05 ||
                abs(state.rightX - lastLoggedState.rightX) >= 0.05 ||
                abs(state.rightY - lastLoggedState.rightY) >= 0.05 ||
                state.firePressed != lastLoggedState.firePressed ||
                state.jumpPressed != lastLoggedState.jumpPressed ||
                state.crouchPressed != lastLoggedState.crouchPressed ||
                state.buttonMask != lastLoggedState.buttonMask
        } else {
            shouldLog = true
        }

        guard shouldLog else { return }
        lastLoggedState = state

        let sourceName = source.map { String(describing: type(of: $0)) } ?? "initial"
        let maskHex = String(format: "0x%04X", state.buttonMask)
        var btns: [String] = []
        if state.buttonMask & PadBit.a != 0             { btns.append("A") }
        if state.buttonMask & PadBit.b != 0             { btns.append("B") }
        if state.buttonMask & PadBit.x != 0             { btns.append("X") }
        if state.buttonMask & PadBit.y != 0             { btns.append("Y") }
        if state.buttonMask & PadBit.leftShoulder != 0  { btns.append("LB") }
        if state.buttonMask & PadBit.rightShoulder != 0 { btns.append("RB") }
        if state.buttonMask & PadBit.leftTrigger != 0   { btns.append("LT") }
        if state.buttonMask & PadBit.rightTrigger != 0  { btns.append("RT") }
        if state.buttonMask & PadBit.dpadUp != 0        { btns.append("dU") }
        if state.buttonMask & PadBit.dpadDown != 0      { btns.append("dD") }
        if state.buttonMask & PadBit.dpadLeft != 0      { btns.append("dL") }
        if state.buttonMask & PadBit.dpadRight != 0     { btns.append("dR") }
        if state.buttonMask & PadBit.menu != 0          { btns.append("MENU") }
        if state.buttonMask & PadBit.options != 0       { btns.append("OPT") }
        if state.buttonMask & PadBit.leftThumb != 0     { btns.append("L3") }
        if state.buttonMask & PadBit.rightThumb != 0    { btns.append("R3") }
        let btnStr = btns.isEmpty ? "-" : btns.joined(separator: "+")
        print(
            String(
                format: "[GCController] input %@ left=(%.2f, %.2f) right=(%.2f, %.2f) fire=%d jump=%d crouch=%d buttons=%@ mask=%@",
                sourceName,
                state.leftX,
                state.leftY,
                state.rightX,
                state.rightY,
                state.firePressed,
                state.jumpPressed,
                state.crouchPressed,
                btnStr,
                maskHex
            )
        )
    }

    private func describe(_ controller: GCController) -> String {
        let name = controller.vendorName ?? "Unknown"
        let profile = controller.extendedGamepad != nil ? "extended" : "non-extended"
        return "\(name) profile=\(profile)"
    }
}
