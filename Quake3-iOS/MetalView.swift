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
            // Inline BSP movers reuse the world pipelines/shaders, so the
            // model matrix lives in the shared world uniform instead of
            // introducing a second "brush entity" pipeline.
            var modelMatrix: simd_float4x4 = matrix_identity_float4x4
        }

        struct WorldDrawUniforms: Equatable {
            var tcGen: Float
            var tcModCount: Int32           // 0-4 tcMod entries in the chain
            var rgbGen: Float               // 0=identity, 1=vertex, 2=lightingDiffuse
            var timeSeconds: Float
            var tcModType: SIMD4<Float>     // type per chain entry (1=scroll, 2=wave, 3=rotate, 4=scale, 5=turb)
            var tcModParams0: SIMD4<Float>  // chain[0] params
            var tcModParams1: SIMD4<Float>  // chain[1] params
            var tcModParams2: SIMD4<Float>  // chain[2] params
            var tcModParams3: SIMD4<Float>  // chain[3] params
            var debugMode: Float
            var forceWhiteVertColor: Float  // 1.0 for additive (skip BSP vertex color)
            var alphaTestThreshold: Float   // >0: discard if a<thresh; <0: discard if a>=|thresh|; 0: none
            var blendMode: Int32
            var alphaGen: Float             // 0=identity, 1=vertex
            var _pad0: Float = 0            // 16-byte alignment for the following float4
            var _pad1: Float = 0
            // Debug pass colorizer: when .a > 0.5 the fragment shader returns this
            // flat color instead of sampling. Set per-pass from `metal_debug_passes`.
            // 0=opaque (red), 1=filter (green), 2=alpha (blue), 3=additive (yellow).
            var debugPassColor: SIMD4<Float> = SIMD4<Float>(0, 0, 0, 0)
        }

        // Render debug: 0 = normal, 1 = base only, 2 = lightmap only,
        // 3 = uv1 visualization, 4 = vertex color only. Flip to diagnose
        // lightmap / uv1 issues without touching the build pipeline.
        private static let worldDebugMode: Float = 0

        // Flip to true to log world-pass stage/drawcall counts each frame.
        // Reveals how effective run-length batching is. Flooding — leave off in production.
        private static let worldBatchLogEnabled: Bool = false

        // One-shot: logs the first sky draw's stage layout once per launch.
        // Confirms killsky_1 + killsky_2 are both wired through as stages.
        // Instance property (not static) to sidestep Swift 6 strict global
        // concurrency — Coordinator itself is main-actor driven, so the
        // bool is safe here without any isolation attribute.
        private var skyStagesLogged: Bool = false

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

        /// Full tcMod chain pack — matches the `WorldDrawUniforms`
        /// `tcModCount` + `tcModType` + `tcModParams0..3` layout. MSL
        /// iterates all active entries via `ApplyTcMod`.
        typealias TcModChainPack = (types: SIMD4<Float>,
                                    p0: SIMD4<Float>, p1: SIMD4<Float>,
                                    p2: SIMD4<Float>, p3: SIMD4<Float>,
                                    count: Int32)

        /// Flatten the parsed `Q3MetalStage.tcMods[Q3_MAX_TCMODS]` chain
        /// into the six uniform fields (types + four params + count).
        /// Declaration order preserved; up to 4 entries.
        private static func fillTcMods(_ stage: Q3MetalWorldStage) -> TcModChainPack {
            var types = SIMD4<Float>(0, 0, 0, 0)
            var p0 = SIMD4<Float>(0, 0, 0, 0)
            var p1 = SIMD4<Float>(0, 0, 0, 0)
            var p2 = SIMD4<Float>(0, 0, 0, 0)
            var p3 = SIMD4<Float>(0, 0, 0, 0)
            let n = Int(min(stage.tcModCount, 4))
            // Q3TcMod tcMods[] is a fixed-size C array (tuple in Swift).
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

        /// Zero pack used by `disableTcMod` call sites.
        private static let kZeroTcModPack: TcModChainPack = (
            SIMD4<Float>(0, 0, 0, 0),
            SIMD4<Float>(0, 0, 0, 0),
            SIMD4<Float>(0, 0, 0, 0),
            SIMD4<Float>(0, 0, 0, 0),
            SIMD4<Float>(0, 0, 0, 0),
            0
        )

        struct GPUEntityVertex {
            var position: SIMD3<Float>
            var texCoord: SIMD2<Float>
            var color: SIMD4<Float>
        }

        struct EntityUniforms {
            var viewProjection: simd_float4x4
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
            float4x4 modelMatrix;
        };

        struct WorldVertexOut {
            float4 position [[position]];
            float2 texCoord;
            float2 lightmapTexCoord;
            float4 color;
            float3 worldPos;
        };

        struct WorldDrawUniforms {
            float tcGen;
            int   tcModCount;
            float rgbGen;
            float timeSeconds;
            float4 tcModType;
            float4 tcModParams0;
            float4 tcModParams1;
            float4 tcModParams2;
            float4 tcModParams3;
            float debugMode;
            float forceWhiteVertColor;
            float alphaTestThreshold;
            int blendMode;
            float alphaGen;
            float _pad0;
            float _pad1;
            float4 debugPassColor;
        };

        struct EntityVertexIn {
            float3 position;
            float2 texCoord;
            float4 color;
        };

        struct EntityUniforms {
            float4x4 viewProjection;
        };

        struct EntityVertexOut {
            float4 position [[position]];
            float2 texCoord;
            float4 color;
        };

        vertex WorldVertexOut q3_world_vertex(const device WorldVertexIn *vertices [[buffer(0)]],
                                              constant WorldUniforms &uniforms [[buffer(1)]],
                                              uint vertexID [[vertex_id]]) {
            WorldVertexOut out;
            WorldVertexIn inVertex = vertices[vertexID];
            float4 worldPosition = uniforms.modelMatrix * float4(inVertex.position, 1.0);
            out.position = uniforms.viewProjection * worldPosition;
            out.texCoord = inVertex.texCoord;
            out.lightmapTexCoord = inVertex.lightmapTexCoord;
            out.color = inVertex.color;
            // tcMod turb / tcGen environment must see the moved brush in
            // real world space, not the submodel's local BSP coordinates.
            out.worldPos = worldPosition.xyz;
            return out;
        }

        inline float2 ApplyTcMod(float2 uv, float3 worldPos, constant WorldDrawUniforms &u) {
            // Iterate the full tcMod chain in declaration order. Up to four
            // entries; types[]/params0..3 are populated by Swift-side
            // fillTcMods(). chain[i] params selection is a ladder because
            // Metal constant buffers don't support dynamic indexing into
            // disjoint float4 fields.
            for (int i = 0; i < u.tcModCount; ++i) {
                int t = int(u.tcModType[i] + 0.5);
                float4 p = (i == 0) ? u.tcModParams0
                         : (i == 1) ? u.tcModParams1
                         : (i == 2) ? u.tcModParams2
                                    : u.tcModParams3;
                if (t == 1) {
                    // scroll
                    uv += p.xy * u.timeSeconds;
                } else if (t == 2) {
                    // wave — params.y=amp, params.w=speed
                    float s = sin(u.timeSeconds * p.w) * p.y;
                    uv += float2(s, s);
                } else if (t == 3) {
                    // rotate — params.x=deg/sec
                    float a = p.x * u.timeSeconds;
                    float c = cos(a);
                    float s = sin(a);
                    float2 q = uv - 0.5;
                    uv = float2(q.x * c - q.y * s, q.x * s + q.y * c) + 0.5;
                } else if (t == 4) {
                    // scale
                    uv *= p.xy;
                } else if (t == 5) {
                    // turb — params.x=amp, .y=freq, .z=phase. Stock Q3
                    // feeds tess.xyz into the turb sine table; we use a
                    // 1/128 spatial scale so adjacent lava/slime tiles
                    // ripple coherently.
                    float amp = p.x;
                    float freq = p.y;
                    float phase = p.z;
                    float tt = (u.timeSeconds + phase) * freq * 2.0 * 3.14159265;
                    float2 wp = worldPos.xy * (1.0 / 128.0);
                    uv.x += sin(tt + wp.y) * amp;
                    uv.y += sin(tt + wp.x) * amp;
                }
            }
            return uv;
        }

        inline float2 ComputeStageTexCoord(WorldVertexOut in,
                                           constant WorldDrawUniforms &u,
                                           float3 cameraPos) {
            float2 uv;
            int tcGen = int(u.tcGen + 0.5);
            if (tcGen == 1) {
                // tcGen environment — per-fragment facet normal from the
                // screen-space derivatives of worldPos. Q3's BSP vertices
                // don't carry per-vertex normals; the stock engine uses
                // per-face normals from the surface plane. dfdx/dfdy on
                // worldPos inside the fragment shader gives us the same
                // (one flat normal per triangle). Matches the stock Q3
                // envmap look on gothic pillar reliefs, armor trim, etc.
                float3 dxPos = dfdx(in.worldPos);
                float3 dyPos = dfdy(in.worldPos);
                float3 N = normalize(cross(dxPos, dyPos));
                float3 viewer = cameraPos - in.worldPos;
                float rlen = rsqrt(max(dot(viewer, viewer), 1e-6));
                viewer *= rlen;
                float d = dot(N, viewer);
                float3 R = N * (2.0 * d) - viewer;
                // Stock Q3 RB_CalcEnvironmentTexCoords maps
                //   st[0] = 0.5 + R.y * 0.5; st[1] = 0.5 - R.z * 0.5;
                // i.e. horizontal axis is world Y, vertical axis is world Z
                // (inverted so sky maps to the top of the envmap).
                uv = float2(0.5 + R.y * 0.5, 0.5 - R.z * 0.5);
            } else {
                uv = in.texCoord;
            }
            return ApplyTcMod(uv, in.worldPos, u);
        }

        inline float4 SampleBase(texture2d<float> tex,
                                 sampler s,
                                 float2 uv,
                                 constant WorldDrawUniforms &u) {
            float4 texel = tex.sample(s, uv);
            // Explicit alphaFunc (from the shader parser) only. Positive
            // threshold = GT0/GE128 (discard below). Negative = LT128
            // (discard above). Zero = no test.
            //
            // The previous implicit "if blendMode opaque/filter && alpha<0.5
            // discard" fallback was removed 2026-04-17: it assumed every
            // opaque wall had alpha=1, but RGBA textures loaded via
            // fallback paths (or JPGs with accidental alpha<128) were
            // getting their entire surface discarded — producing the
            // "see-through walls" regression. Stock Q3 does not do an
            // implicit alpha discard on opaque/filter stages.
            float thresh = u.alphaTestThreshold;
            if (thresh > 0.0) {
                if (texel.a < thresh) discard_fragment();
            } else if (thresh < 0.0) {
                if (texel.a >= -thresh) discard_fragment();
            }
            return texel;
        }

        inline bool WorldDebugReplace(constant WorldDrawUniforms &u,
                                      thread float4 &outColor) {
            // Debug pass colorizer — solid replace when alpha >= 0.9.
            if (u.debugPassColor.a >= 0.9) {
                outColor = u.debugPassColor;
                return true;
            }
            return false;
        }

        inline bool WorldDebugMode(WorldVertexOut in,
                                   float4 texel,
                                   float4 lightmap,
                                   constant WorldDrawUniforms &u,
                                   thread float4 &outColor) {
            int mode = int(u.debugMode + 0.5);
            if (mode == 1) {
                outColor = float4(texel.rgb, 1.0);
                return true;
            }
            if (mode == 2) {
                outColor = float4(lightmap.rgb, 1.0);
                return true;
            }
            if (mode == 3) {
                outColor = float4(in.texCoord, 0.0, 1.0);
                return true;
            }
            if (mode == 4) {
                outColor = float4(in.lightmapTexCoord, 0.0, 1.0);
                return true;
            }
            return false;
        }

        inline float4 ApplyWorldDebugTint(float4 outColor,
                                          constant WorldDrawUniforms &u) {
            // Tint (alpha < 0.9 but > 0) falls through to normal shading
            // and gets mixed at the end so the texture stays visible.
            if (u.debugPassColor.a > 0.01) {
                outColor.rgb = mix(outColor.rgb, u.debugPassColor.rgb, u.debugPassColor.a);
            }
            return outColor;
        }

        // Apply rgbGen and alphaGen from the stage uniform to the computed
        // fragment color. Safety rules (per advisor spec):
        //  1. IDENTITY (code 0) is the default — DO NOTHING to color.
        //  2. VERTEX / LIGHTING_DIFFUSE (1/2) multiplies color.rgb by
        //     vertex.rgb ONLY if vertex color isn't near-zero. Guards
        //     against BSP surfaces with (0,0,0) vertex colors that would
        //     otherwise go black when the shader explicitly asked for
        //     rgbGen vertex but q3map failed to bake vertex lighting.
        //  3. alphaGen VERTEX (1) multiplies color.a by vertex.a.
        // This function MUST NOT affect shaders that leave rgbGen/alphaGen
        // unset — the majority of world BSP shaders.
        inline float4 ApplyVertexColorGen(float4 color,
                                          float4 vertexColor,
                                          constant WorldDrawUniforms &u) {
            int rgbGen = int(u.rgbGen + 0.5);
            int alphaGen = int(u.alphaGen + 0.5);
            if (rgbGen == 1 || rgbGen == 2) {
                float3 vc = vertexColor.rgb;
                // Safety: skip when vertex color is near-black so an
                // uncompiled-lighting BSP surface doesn't disappear.
                if (dot(vc, vc) > 0.0001) {
                    color.rgb *= vc;
                }
            }
            if (alphaGen == 1) {
                color.a *= vertexColor.a;
            }
            return color;
        }

        fragment float4 q3_world_frag_opaque(WorldVertexOut in [[stage_in]],
                                             constant WorldDrawUniforms &u [[buffer(0)]],
                                             constant WorldUniforms &uniforms [[buffer(1)]],
                                             texture2d<float> colorTexture [[texture(0)]],
                                             texture2d<float> lightmapTexture [[texture(1)]],
                                             sampler textureSampler [[sampler(0)]]) {
            float4 outColor;
            if (WorldDebugReplace(u, outColor)) {
                return outColor;
            }
            float2 texCoord = ComputeStageTexCoord(in, u, uniforms.cameraPos);
            float4 texel = SampleBase(colorTexture, textureSampler, texCoord, u);
            float4 lightmap = lightmapTexture.sample(textureSampler, in.lightmapTexCoord);
            if (WorldDebugMode(in, texel, lightmap, u, outColor)) {
                return outColor;
            }
            outColor = float4(texel.rgb * lightmap.rgb, 1.0);
            outColor = ApplyVertexColorGen(outColor, in.color, u);
            return ApplyWorldDebugTint(outColor, u);
        }

        fragment float4 q3_world_frag_alpha(WorldVertexOut in [[stage_in]],
                                            constant WorldDrawUniforms &u [[buffer(0)]],
                                            constant WorldUniforms &uniforms [[buffer(1)]],
                                            texture2d<float> colorTexture [[texture(0)]],
                                            texture2d<float> lightmapTexture [[texture(1)]],
                                            sampler textureSampler [[sampler(0)]]) {
            float4 outColor;
            if (WorldDebugReplace(u, outColor)) {
                return outColor;
            }
            float2 texCoord = ComputeStageTexCoord(in, u, uniforms.cameraPos);
            float4 texel = SampleBase(colorTexture, textureSampler, texCoord, u);
            float4 lightmap = lightmapTexture.sample(textureSampler, in.lightmapTexCoord);
            if (WorldDebugMode(in, texel, lightmap, u, outColor)) {
                return outColor;
            }
            outColor = float4(texel.rgb, texel.a);
            outColor = ApplyVertexColorGen(outColor, in.color, u);
            return ApplyWorldDebugTint(outColor, u);
        }

        fragment float4 q3_world_frag_add(WorldVertexOut in [[stage_in]],
                                          constant WorldDrawUniforms &u [[buffer(0)]],
                                          constant WorldUniforms &uniforms [[buffer(1)]],
                                          texture2d<float> colorTexture [[texture(0)]],
                                          texture2d<float> lightmapTexture [[texture(1)]],
                                          sampler textureSampler [[sampler(0)]]) {
            float4 outColor;
            if (WorldDebugReplace(u, outColor)) {
                return outColor;
            }
            float2 texCoord = ComputeStageTexCoord(in, u, uniforms.cameraPos);
            float4 texel = SampleBase(colorTexture, textureSampler, texCoord, u);
            float4 lightmap = lightmapTexture.sample(textureSampler, in.lightmapTexCoord);
            if (WorldDebugMode(in, texel, lightmap, u, outColor)) {
                return outColor;
            }
            outColor = float4(texel.rgb * texel.a, texel.a);
            outColor = ApplyVertexColorGen(outColor, in.color, u);
            return ApplyWorldDebugTint(outColor, u);
        }

        fragment float4 q3_world_frag_filter(WorldVertexOut in [[stage_in]],
                                             constant WorldDrawUniforms &u [[buffer(0)]],
                                             constant WorldUniforms &uniforms [[buffer(1)]],
                                             texture2d<float> colorTexture [[texture(0)]],
                                             texture2d<float> lightmapTexture [[texture(1)]],
                                             sampler textureSampler [[sampler(0)]]) {
            float4 outColor;
            if (WorldDebugReplace(u, outColor)) {
                return outColor;
            }
            float2 texCoord = ComputeStageTexCoord(in, u, uniforms.cameraPos);
            float4 texel = SampleBase(colorTexture, textureSampler, texCoord, u);
            float4 lightmap = lightmapTexture.sample(textureSampler, in.lightmapTexCoord);
            if (WorldDebugMode(in, texel, lightmap, u, outColor)) {
                return outColor;
            }
            outColor = float4(texel.rgb * lightmap.rgb, 1.0);
            outColor = ApplyVertexColorGen(outColor, in.color, u);
            return ApplyWorldDebugTint(outColor, u);
        }

        // Phase-1 portal fragment: samples the RTT portalTexture with the
        // BSP-baked stage UV. Stages are intentionally ignored by the
        // caller — only one drawcall per portal surface and only texture
        // slot 0 is bound. No lightmap, no tcMod, no stage blendMode —
        // the portal "window" is whatever the RTT pass rendered.
        fragment float4 q3_portal_fragment(WorldVertexOut in [[stage_in]],
                                           texture2d<float> portalTex [[texture(0)]],
                                           sampler textureSampler [[sampler(0)]]) {
            return portalTex.sample(textureSampler, in.texCoord);
        }

        // Entity portal fragment: used when an MD3 entity's surface
        // references a portal shader. MD3 UVs are model-space and would
        // stretch the RTT across the model, so sample by screen position
        // instead. screenSize is passed as drawable dimensions; Metal's
        // [[position]] has top-left origin and portalTexture was rendered
        // to the same convention, so no Y-flip is needed.
        fragment float4 q3_entity_portal_fragment(EntityVertexOut in [[stage_in]],
                                                  constant float2 &screenSize [[buffer(0)]],
                                                  texture2d<float> portalTex [[texture(0)]],
                                                  sampler textureSampler [[sampler(0)]]) {
            float2 uv = in.position.xy / screenSize;
            return portalTex.sample(textureSampler, uv);
        }

        vertex EntityVertexOut q3_entity_vertex(const device EntityVertexIn *vertices [[buffer(0)]],
                                                constant EntityUniforms &uniforms [[buffer(1)]],
                                                uint vertexID [[vertex_id]]) {
            EntityVertexOut out;
            EntityVertexIn inVertex = vertices[vertexID];
            out.position = uniforms.viewProjection * float4(inVertex.position, 1.0);
            out.texCoord = inVertex.texCoord;
            out.color = inVertex.color;
            return out;
        }

        fragment float4 q3_entity_fragment(EntityVertexOut in [[stage_in]],
                                           constant float4 &debugPassColor [[buffer(0)]],
                                           texture2d<float> colorTexture [[texture(0)]],
                                           sampler textureSampler [[sampler(0)]]) {
            if (debugPassColor.a >= 0.9) {
                return debugPassColor;  // solid replace
            }
            float4 texel = colorTexture.sample(textureSampler, in.texCoord);
            float4 outColor = texel * in.color;
            if (debugPassColor.a > 0.01) {
                outColor.rgb = mix(outColor.rgb, debugPassColor.rgb, debugPassColor.a);
            }
            return outColor;
        }

        fragment float4 q3_entity_additive_fragment(EntityVertexOut in [[stage_in]],
                                                    constant float4 &debugPassColor [[buffer(0)]],
                                                    texture2d<float> colorTexture [[texture(0)]],
                                                    sampler textureSampler [[sampler(0)]]) {
            if (debugPassColor.a >= 0.9) {
                return debugPassColor;  // solid replace
            }
            float4 texel = colorTexture.sample(textureSampler, in.texCoord);
            float alpha = texel.a * in.color.a;
            float3 glow = texel.rgb * alpha * in.color.rgb * 0.35;
            float4 outColor = float4(glow, alpha);
            if (debugPassColor.a > 0.01) {
                outColor.rgb = mix(outColor.rgb, debugPassColor.rgb, debugPassColor.a);
            }
            return outColor;
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
            float4 worldPosition = uniforms.modelMatrix * float4(inVertex.position, 1.0);
            out.position = uniforms.viewProjection * worldPosition;
            // Push to max depth so sky always renders behind everything
            out.position.z = out.position.w;
            out.worldPos = worldPosition.xyz;
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

            // tcMod as stacked scale+scroll. Q3 killsky has both
            // `tcMod scale` and `tcMod scroll` on the same stage —
            // Q3's runtime applies scale first, then scroll. Until
            // the per-stage uniform carries both simultaneously, we
            // derive them from the single `tcMod` + `tcModParams`
            // slot: if tcMod==1 use .xy as scroll; if tcMod==4 use
            // .xy as scale; otherwise no-op. Applied to all three
            // projections identically so motion stays coherent.
            // Walk the tcMod chain; sky only applies scroll/scale slots
            // (turb/wave/rotate on sky surfaces are rare and the cube
            // projection would distort the UV anyway).
            for (int _i = 0; _i < drawUniforms.tcModCount; ++_i) {
                int tcMod = int(drawUniforms.tcModType[_i] + 0.5);
                float4 _p = (_i == 0) ? drawUniforms.tcModParams0
                          : (_i == 1) ? drawUniforms.tcModParams1
                          : (_i == 2) ? drawUniforms.tcModParams2
                                      : drawUniforms.tcModParams3;
                if (tcMod == 1) {
                    float2 scroll = _p.xy * drawUniforms.timeSeconds;
                    uvX += scroll;
                    uvY += scroll;
                    uvZ += scroll;
                } else if (tcMod == 4) {
                    uvX *= _p.xy;
                    uvY *= _p.xy;
                    uvZ *= _p.xy;
                }
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
        // Filter-mode UI pipeline (dst_color, zero). Specifically for
        // `viewBloodBlend` and any other 2D overlay whose Q3 shader uses
        // `blendFunc GL_DST_COLOR GL_*` — without this, they render through
        // the default alpha pipeline as an opaque red overlay that blocks
        // the view.
        private var uiFilterPipelineState: MTLRenderPipelineState?
        private var worldPipelineState: MTLRenderPipelineState?
        private var worldFilterPipelineState: MTLRenderPipelineState?
        private var worldAlphaPipelineState: MTLRenderPipelineState?
        private var worldAdditivePipelineState: MTLRenderPipelineState?
        // Premultiplied-alpha blend (src=ONE, dst=ONE_MINUS_SRC_ALPHA).
        // For Q3 shaders with `blendFunc GL_ONE GL_ONE_MINUS_SRC_ALPHA` —
        // their texels are pre-multiplied by alpha, so using the plain
        // alpha pipeline (SRC_ALPHA / ONE_MINUS_SRC_ALPHA) darkens edges
        // by multiplying src.rgb by src.a twice.
        private var worldPremultPipelineState: MTLRenderPipelineState?
        private var skyPipelineState: MTLRenderPipelineState?
        private var skyAdditivePipelineState: MTLRenderPipelineState?
        private var skyDepthStencilState: MTLDepthStencilState?
        private var entityPipelineState: MTLRenderPipelineState?
        private var entityFilterPipelineState: MTLRenderPipelineState?
        private var entityAlphaPipelineState: MTLRenderPipelineState?
        private var entityAdditivePipelineState: MTLRenderPipelineState?
        private var additiveEntityDepthStencilState: MTLDepthStencilState?
        private var uiSamplerState: MTLSamplerState?
        private var worldSamplerState: MTLSamplerState?
        private var depthStencilState: MTLDepthStencilState?
        private var additiveDepthStencilState: MTLDepthStencilState?
        private var depthHackDepthStencilState: MTLDepthStencilState?
        private var fallbackDepthStencilState: MTLDepthStencilState?
        var whiteTexture: MTLTexture!

        // Phase-1 portal RTT targets. Created in configureRenderer and
        // resized in mtkView(_:drawableSizeWillChange:). The portal pass
        // renders the world+sky from a shifted camera into portalTexture,
        // which the main pass then samples as the portal surface's fill.
        private var portalTexture: MTLTexture?
        private var portalDepthTexture: MTLTexture?
        private var worldPortalPipelineState: MTLRenderPipelineState?
        private var entityPortalPipelineState: MTLRenderPipelineState?

        private func createPortalTargets(device: MTLDevice, size: CGSize, colorPixelFormat: MTLPixelFormat) {
            let width = max(1, Int(size.width))
            let height = max(1, Int(size.height))
            let colorDesc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: colorPixelFormat,
                width: width,
                height: height,
                mipmapped: false
            )
            colorDesc.usage = [.renderTarget, .shaderRead]
            colorDesc.storageMode = .private
            portalTexture = device.makeTexture(descriptor: colorDesc)

            let depthDesc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .depth32Float,
                width: width,
                height: height,
                mipmapped: false
            )
            depthDesc.usage = [.renderTarget]
            depthDesc.storageMode = .private
            portalDepthTexture = device.makeTexture(descriptor: depthDesc)
        }

        private func ensuredDepthStencilState(_ preferred: MTLDepthStencilState?, device: MTLDevice?) -> MTLDepthStencilState? {
            if let preferred { return preferred }
            if let fallbackDepthStencilState { return fallbackDepthStencilState }
            guard let device else { return nil }
            let desc = MTLDepthStencilDescriptor()
            desc.depthCompareFunction = .always
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
            if let device = view.device {
                createPortalTargets(device: device, size: size, colorPixelFormat: view.colorPixelFormat)
            }
        }
        private var inFrame = false

        func draw(in view: MTKView) {

            if commandQueue == nil {
                configureRenderer(for: view)
            }

            if inFrame {
                print("[ERROR] draw() re-entered")
                return
            }
            inFrame = true

            let frameTime = CACurrentMediaTime()
            let SKY_FLAG = UInt32(Q3_METAL_WORLD_DRAWFLAG_SKY)
            let NOCULL_FLAG = UInt32(Q3_METAL_WORLD_DRAWFLAG_NOCULL)
            let LIGHTMAP_MULTIPLY_FLAG = UInt32(Q3_METAL_WORLD_DRAWFLAG_LIGHTMAP_MULTIPLY)
            let PORTAL_FLAG = UInt32(Q3_METAL_WORLD_DRAWFLAG_PORTAL)
            // Q3 `cull front` inverts winding — we render back faces.
            let CULL_FRONT_FLAG = UInt32(Q3_METAL_WORLD_DRAWFLAG_CULL_FRONT)
            // Inline bmodel draw — owning entity's model matrix is live in
            // WorldDrawUniforms.modelMatrix and must break batching so the
            // per-entity uniform set is emitted separately from static world.
            let BMODEL_FLAG = UInt32(Q3_METAL_WORLD_DRAWFLAG_BMODEL)

            // Debug pass colorizer (`metal_debug_passes`):
            //   0 = off (normal rendering)
            //   1 = solid replace: fragment returns a flat per-pass color
            //   2 = tint: texture stays visible but gets mixed with the pass
            //       color so you can still navigate the map.
            // Per-pass RGB: 0=opaque (red), 1=filter (green), 2=alpha (blue),
            // 3=additive (yellow). Alpha channel carries the mode marker —
            // shaders test `a >= 0.9` for solid, `a > 0.01` (but < 0.9) for
            // tint. a = 0 means off.
            let debugPassesMode = Q3MetalRenderer_GetDebugPasses()
            let debugAlpha: Float = (debugPassesMode == 2) ? 0.55 : ((debugPassesMode == 1) ? 1.0 : 0.0)
            func debugColor(pass: Int) -> SIMD4<Float> {
                guard debugAlpha > 0.0 else { return SIMD4<Float>(0, 0, 0, 0) }
                switch pass {
                case 0: return SIMD4<Float>(1, 0, 0, debugAlpha) // opaque
                case 1: return SIMD4<Float>(0, 1, 0, debugAlpha) // filter
                case 2: return SIMD4<Float>(0, 0, 1, debugAlpha) // alpha
                case 3: return SIMD4<Float>(1, 1, 0, debugAlpha) // additive
                default: return SIMD4<Float>(0, 0, 0, 0)
                }
            }
            func worldPassIndex(blendMode: UInt32) -> Int {
                switch blendMode {
                case 1: return 3  // additive
                case 2: return 2  // alpha
                case 3: return 1  // filter
                case 4: return 2  // premultiplied-alpha (reuse alpha debug color)
                default: return 0 // opaque
                }
            }

            // ---- 1. RUN ENGINE (LOGIC ONLY) ----
            Quake3_Frame()

            // ---- 2. SNAPSHOT ----
            guard let snapshotPtr = Q3MetalRenderer_GetFrameSnapshot() else {
                print("[FRAME] no snapshot")
                inFrame = false
                return
            }
            let snapshot = snapshotPtr.pointee
            let drawWorldEnabled = Q3MetalRenderer_GetDrawWorld() != 0
            let drawEntitiesEnabled = Q3MetalRenderer_GetDrawEntities() != 0
            let noCullEnabled = Q3MetalRenderer_GetNoCull() != 0
            let noPortalsEnabled = Q3MetalRenderer_GetNoPortals() != 0

            // ---- 3. ACQUIRE DRAWABLE ONCE ----
            guard let drawable = view.currentDrawable,
                  let descriptor = view.currentRenderPassDescriptor,
                  let commandQueue = commandQueue,
                  let commandBuffer = commandQueue.makeCommandBuffer()
            else {
                inFrame = false
                return
            }

            // ---- 4. SET CLEAR ----
            descriptor.colorAttachments[0].clearColor = MTLClearColor(
                red: Double(snapshot.clearColor.0),
                green: Double(snapshot.clearColor.1),
                blue: Double(snapshot.clearColor.2),
                alpha: Double(snapshot.clearColor.3)
            )

            // ---- 4.5 PORTAL PASS (Phase 1 RTT) ----
            // Renders the world from an alternate camera into portalTexture
            // so the main pass can sample it on portal surfaces. Phase 1
            // scope: opaque stage-0 draws only; sky and portal surfaces are
            // skipped (no recursion). Runs before the main encoder so the
            // portal texture is ready when the main pass samples it.
            if let portalColor = portalTexture,
               let portalDepth = portalDepthTexture,
               snapshot.worldCommandCount > 0,
               let worldDrawsPointerPortal = Q3MetalRenderer_GetWorldDrawCommands(),
               let sceneViewPtr = Q3MetalRenderer_GetSceneView(),
               let worldVB = uploadWorldBuffers(device: view.device, generation: snapshot.worldGeneration),
               let worldIB = worldIndexBuffer,
               let worldMainPipeline = worldPipelineState {
                let mainSceneView = sceneViewPtr.pointee
                var portalCam = Q3MetalPortalView()
                let hasRealPortal = Q3MetalRenderer_GetPortalView(&portalCam) != 0
                let smokeTestOn = Q3MetalRenderer_GetPortalSmokeTest() != 0
                // Phase-2 visibility gate: skip the portal RTT pass entirely
                // when the map has no portal surfaces and no portal entity is
                // in the scene. This is ~99% of maps. Recovers the FPS lost
                // to Phase-1's always-on portal pass.
                let hasVisiblePortalSurface = Q3MetalRenderer_HasVisiblePortal() != 0

                // Rate-limited cull probe. Prints once per ~120 frames so
                // non-portal maps get a steady "skipped" heartbeat and
                // portal maps go quiet when the mirror is in view. Helps
                // confirm the gate is actually firing at runtime.
                if !hasVisiblePortalSurface, snapshot.frameNumber % 120 == 0 {
                    print("[PORTAL] skipped frame=\(snapshot.frameNumber)")
                }

                if hasVisiblePortalSurface && (hasRealPortal || smokeTestOn) {
                    var portalSceneView = mainSceneView
                    if hasRealPortal {
                        portalSceneView.viewOrigin = (portalCam.origin.0, portalCam.origin.1, portalCam.origin.2)
                        portalSceneView.viewAxis = (
                            portalCam.axis.0, portalCam.axis.1, portalCam.axis.2,
                            portalCam.axis.3, portalCam.axis.4, portalCam.axis.5,
                            portalCam.axis.6, portalCam.axis.7, portalCam.axis.8
                        )
                    } else {
                        // Smoke test fallback: shift the main camera 50u up Z so
                        // the RTT shows a visibly different view. Axis inherited.
                        portalSceneView.viewOrigin = (
                            mainSceneView.viewOrigin.0,
                            mainSceneView.viewOrigin.1,
                            mainSceneView.viewOrigin.2 + 50.0
                        )
                    }

                    let portalVP = makeWorldViewProjection(portalSceneView)
                    let portalCamPos = SIMD3<Float>(
                        portalSceneView.viewOrigin.0,
                        portalSceneView.viewOrigin.1,
                        portalSceneView.viewOrigin.2
                    )
                    var portalWorldUniforms = WorldUniforms(
                        viewProjection: portalVP,
                        cameraPos: portalCamPos
                    )

                    let portalPassDescriptor = MTLRenderPassDescriptor()
                    portalPassDescriptor.colorAttachments[0].texture = portalColor
                    portalPassDescriptor.colorAttachments[0].loadAction = .clear
                    portalPassDescriptor.colorAttachments[0].storeAction = .store
                    portalPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
                    portalPassDescriptor.depthAttachment.texture = portalDepth
                    portalPassDescriptor.depthAttachment.loadAction = .clear
                    portalPassDescriptor.depthAttachment.storeAction = .dontCare
                    portalPassDescriptor.depthAttachment.clearDepth = 1.0

                    // Portal pass runs on its OWN command buffer, committed
                    // BEFORE the main pass encoder starts. This keeps the
                    // drawable's texture out of the portal pass's command
                    // buffer entirely (prevents CAMetalLayer retention
                    // warnings from draining into the portal work).
                    guard let portalCommandBuffer = commandQueue.makeCommandBuffer() else {
                        return
                    }
                    if let portalEncoder = portalCommandBuffer.makeRenderCommandEncoder(descriptor: portalPassDescriptor) {
                        portalEncoder.setFrontFacing(.clockwise)
                        portalEncoder.setVertexBuffer(worldVB, offset: 0, index: 0)
                        portalEncoder.setVertexBytes(&portalWorldUniforms, length: MemoryLayout<WorldUniforms>.stride, index: 1)
                        portalEncoder.setFragmentBytes(&portalWorldUniforms, length: MemoryLayout<WorldUniforms>.stride, index: 1)
                        portalEncoder.setFragmentSamplerState(worldSamplerState, index: 0)

                        let portalWorldDraws = UnsafeBufferPointer(
                            start: worldDrawsPointerPortal,
                            count: Int(snapshot.worldCommandCount)
                        )
                        let SKY_FLAG_PORTAL = UInt32(Q3_METAL_WORLD_DRAWFLAG_SKY)
                        let NOCULL_FLAG_PORTAL = UInt32(Q3_METAL_WORLD_DRAWFLAG_NOCULL)
                        let PORTAL_FLAG_PORTAL = UInt32(Q3_METAL_WORLD_DRAWFLAG_PORTAL)
                        let portalTimeSeconds = Float(frameTime - frameTimeOrigin)

                        // ---- SKY (in portal pass) ----
                        // Mirror of the main-pass sky block. Renders into the
                        // portal RTT so looking through a mirror at the sky
                        // doesn't produce a black patch.
                        if let skyPipelineState, let skyDepthStencilState {
                            for draw in portalWorldDraws where draw.indexCount > 0 && (draw.flags & SKY_FLAG_PORTAL) != 0 {
                                if (draw.flags & PORTAL_FLAG_PORTAL) != 0 { continue }
                                let stageCount = min(Int(draw.stageCount), Int(Q3_METAL_MAX_STAGES))
                                guard stageCount > 0 else { continue }
                                for stageIndex in 0..<stageCount {
                                    let stage = Self.worldStage(draw, stageIndex)
                                    guard let skyTex = texture(for: stage.textureHandle, device: view.device) else { continue }
                                    let useAdditiveSky = stage.blendMode == 1 && skyAdditivePipelineState != nil
                                    portalEncoder.setRenderPipelineState(useAdditiveSky ? skyAdditivePipelineState! : skyPipelineState)
                                    portalEncoder.setDepthStencilState(skyDepthStencilState)
                                    portalEncoder.setCullMode(.none)
                                    var skyDrawUniforms = WorldDrawUniforms(
                                        tcGen: Float(stage.tcGen),
                                        tcModCount: Self.fillTcMods(stage).count,
                                        rgbGen: Float(stage.rgbGen),
                                        timeSeconds: portalTimeSeconds,
                                        tcModType: Self.fillTcMods(stage).types,
                                        tcModParams0: Self.fillTcMods(stage).p0,
                                        tcModParams1: Self.fillTcMods(stage).p1,
                                        tcModParams2: Self.fillTcMods(stage).p2,
                                        tcModParams3: Self.fillTcMods(stage).p3,
                                        debugMode: 0,
                                        forceWhiteVertColor: 1,
                                        alphaTestThreshold: 0,
                                        blendMode: Int32(stage.blendMode),
                                        alphaGen: Float(stage.alphaGen),
                                        debugPassColor: SIMD4<Float>(0, 0, 0, 0)
                                    )
                                    portalEncoder.setFragmentTexture(skyTex, index: 0)
                                    portalEncoder.setFragmentBytes(&skyDrawUniforms, length: MemoryLayout<WorldDrawUniforms>.stride, index: 0)
                                    portalEncoder.drawIndexedPrimitives(
                                        type: .triangle,
                                        indexCount: Int(draw.indexCount),
                                        indexType: .uint32,
                                        indexBuffer: worldIB,
                                        indexBufferOffset: Int(draw.firstIndex) * MemoryLayout<UInt32>.stride
                                    )
                                }
                            }
                            // Restore default world state before world loop.
                            portalEncoder.setDepthStencilState(depthStencilState)
                            portalEncoder.setCullMode(.back)
                        }

                        // ---- WORLD (in portal pass, full stage iteration) ----
                        // Same shape as the main-pass world loop: opaquePhase
                        // split, per-stage blend/pipeline/depth selection.
                        // Portal surfaces skip (no recursion). Entities skipped
                        // for Phase 2 — only world+sky renders into the RTT.
                        for draw in portalWorldDraws where draw.indexCount > 0 && (draw.flags & SKY_FLAG_PORTAL) == 0 {
                            if (draw.flags & PORTAL_FLAG_PORTAL) != 0 { continue }
                            let stageCount = min(Int(draw.stageCount), Int(Q3_METAL_MAX_STAGES))
                            guard stageCount > 0 else { continue }

                            portalEncoder.setCullMode((draw.flags & NOCULL_FLAG_PORTAL) != 0 ? .none : .back)

                            for opaquePhase in 0..<2 {
                                for stageIndex in 0..<stageCount {
                                    let stage = Self.worldStage(draw, stageIndex)
                                    let mode = stage.blendMode
                                    let isOpaqueStage = mode == 0
                                    if opaquePhase == 0 {
                                        guard isOpaqueStage else { continue }
                                    } else {
                                        guard !isOpaqueStage else { continue }
                                    }

                                    guard let stageTexture = texture(for: stage.textureHandle, device: view.device) else { continue }

                                    switch mode {
                                    case 1:
                                        if let p = worldAdditivePipelineState { portalEncoder.setRenderPipelineState(p) }
                                    case 2:
                                        if let p = worldAlphaPipelineState { portalEncoder.setRenderPipelineState(p) }
                                    case 3:
                                        if let p = worldFilterPipelineState { portalEncoder.setRenderPipelineState(p) }
                                    case 4:
                                        if let p = worldPremultPipelineState { portalEncoder.setRenderPipelineState(p) }
                                    default:
                                        portalEncoder.setRenderPipelineState(worldMainPipeline)
                                    }

                                    if isOpaqueStage {
                                        portalEncoder.setDepthStencilState(depthStencilState)
                                    } else {
                                        portalEncoder.setDepthStencilState(additiveDepthStencilState)
                                    }

                                    portalEncoder.setFragmentTexture(stageTexture, index: 0)
                                    let usesLightmap = stage.useLightmap != 0
                                    if usesLightmap, let lightmap = texture(for: draw.lightmapTextureHandle, device: view.device) {
                                        portalEncoder.setFragmentTexture(lightmap, index: 1)
                                    } else {
                                        portalEncoder.setFragmentTexture(whiteTexture, index: 1)
                                    }

                                    var drawUniforms = WorldDrawUniforms(
                                        tcGen: Float(stage.tcGen),
                                        tcModCount: Self.fillTcMods(stage).count,
                                        rgbGen: Float(stage.rgbGen),
                                        timeSeconds: portalTimeSeconds,
                                        tcModType: Self.fillTcMods(stage).types,
                                        tcModParams0: Self.fillTcMods(stage).p0,
                                        tcModParams1: Self.fillTcMods(stage).p1,
                                        tcModParams2: Self.fillTcMods(stage).p2,
                                        tcModParams3: Self.fillTcMods(stage).p3,
                                        debugMode: 0,
                                        forceWhiteVertColor: mode == 1 ? 1 : 0,
                                        alphaTestThreshold: Self.alphaTestThreshold(for: stage.alphaFunc),
                                        blendMode: Int32(mode),
                                        alphaGen: Float(stage.alphaGen),
                                        debugPassColor: SIMD4<Float>(0, 0, 0, 0)
                                    )
                                    portalEncoder.setFragmentBytes(&drawUniforms, length: MemoryLayout<WorldDrawUniforms>.stride, index: 0)
                                    portalEncoder.drawIndexedPrimitives(
                                        type: .triangle,
                                        indexCount: Int(draw.indexCount),
                                        indexType: .uint32,
                                        indexBuffer: worldIB,
                                        indexBufferOffset: Int(draw.firstIndex) * MemoryLayout<UInt32>.stride
                                    )
                                }
                            }
                        }

                        // Inline BSP movers reuse the same world buffers and
                        // stage metadata; only the model matrix changes per
                        // entity instance, so render them here with the
                        // portal camera before the main pass samples the RTT.
                        if snapshot.inlineModelCommandCount > 0,
                           let inlineInstancesPointer = Q3MetalRenderer_GetInlineModelInstances() {
                            let inlineInstances = UnsafeBufferPointer(
                                start: inlineInstancesPointer,
                                count: Int(snapshot.inlineModelCommandCount)
                            )
                            let maxDrawIndex = inlineInstances.reduce(Int(snapshot.worldCommandCount)) {
                                max($0, Int($1.firstDraw + $1.drawCount))
                            }
                            let portalAllWorldDraws = UnsafeBufferPointer(
                                start: worldDrawsPointerPortal,
                                count: maxDrawIndex
                            )

                            for instance in inlineInstances where instance.drawCount > 0 {
                                var inlineUniforms = WorldUniforms(
                                    viewProjection: portalVP,
                                    cameraPos: portalCamPos,
                                    modelMatrix: makeInlineModelMatrix(instance)
                                )
                                portalEncoder.setVertexBytes(&inlineUniforms, length: MemoryLayout<WorldUniforms>.stride, index: 1)
                                portalEncoder.setFragmentBytes(&inlineUniforms, length: MemoryLayout<WorldUniforms>.stride, index: 1)

                                let drawStart = Int(instance.firstDraw)
                                let drawEnd = drawStart + Int(instance.drawCount)
                                for opaquePhase in 0..<2 {
                                    for drawIndex in drawStart..<drawEnd {
                                        let draw = portalAllWorldDraws[drawIndex]
                                        if draw.indexCount == 0 || (draw.flags & SKY_FLAG_PORTAL) != 0 || (draw.flags & PORTAL_FLAG_PORTAL) != 0 {
                                            continue
                                        }

                                        let stageCount = min(Int(draw.stageCount), Int(Q3_METAL_MAX_STAGES))
                                        guard stageCount > 0 else { continue }

                                        portalEncoder.setCullMode((draw.flags & NOCULL_FLAG_PORTAL) != 0 ? .none : .back)

                                        for stageIndex in 0..<stageCount {
                                            let stage = Self.worldStage(draw, stageIndex)
                                            let mode = stage.blendMode
                                            let isOpaqueStage = mode == 0
                                            if (opaquePhase == 0) != isOpaqueStage { continue }
                                            guard let stageTexture = texture(for: stage.textureHandle, device: view.device) else { continue }

                                            switch mode {
                                            case 1:
                                                if let p = worldAdditivePipelineState { portalEncoder.setRenderPipelineState(p) }
                                            case 2:
                                                if let p = worldAlphaPipelineState { portalEncoder.setRenderPipelineState(p) }
                                            case 3:
                                                if let p = worldFilterPipelineState { portalEncoder.setRenderPipelineState(p) }
                                            case 4:
                                                if let p = worldPremultPipelineState { portalEncoder.setRenderPipelineState(p) }
                                            default:
                                                portalEncoder.setRenderPipelineState(worldMainPipeline)
                                            }

                                            portalEncoder.setDepthStencilState(isOpaqueStage ? depthStencilState : additiveDepthStencilState)
                                            portalEncoder.setFragmentTexture(stageTexture, index: 0)
                                            let usesLightmap = stage.useLightmap != 0
                                            if usesLightmap, let lightmap = texture(for: draw.lightmapTextureHandle, device: view.device) {
                                                portalEncoder.setFragmentTexture(lightmap, index: 1)
                                            } else {
                                                portalEncoder.setFragmentTexture(whiteTexture, index: 1)
                                            }

                                            let _tc = Self.fillTcMods(stage)
                                            var drawUniforms = WorldDrawUniforms(
                                                tcGen: Float(stage.tcGen),
                                                tcModCount: _tc.count,
                                                rgbGen: Float(stage.rgbGen),
                                                timeSeconds: portalTimeSeconds,
                                                tcModType: _tc.types,
                                                tcModParams0: _tc.p0,
                                                tcModParams1: _tc.p1,
                                                tcModParams2: _tc.p2,
                                                tcModParams3: _tc.p3,
                                                debugMode: 0,
                                                forceWhiteVertColor: mode == 1 ? 1 : 0,
                                                alphaTestThreshold: Self.alphaTestThreshold(for: stage.alphaFunc),
                                                blendMode: Int32(mode),
                                                alphaGen: Float(stage.alphaGen),
                                                debugPassColor: SIMD4<Float>(0, 0, 0, 0)
                                            )
                                            portalEncoder.setFragmentBytes(&drawUniforms, length: MemoryLayout<WorldDrawUniforms>.stride, index: 0)
                                            portalEncoder.drawIndexedPrimitives(
                                                type: .triangle,
                                                indexCount: Int(draw.indexCount),
                                                indexType: .uint32,
                                                indexBuffer: worldIB,
                                                indexBufferOffset: Int(draw.firstIndex) * MemoryLayout<UInt32>.stride
                                            )
                                        }
                                    }
                                }
                            }
                        }
                        portalEncoder.endEncoding()
                    }
                    // Commit portal pass before the main pass starts so
                    // the RTT target is ready when the main encoder
                    // samples it via the portal fragment shader.
                    portalCommandBuffer.commit()
                }
            }

            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
                inFrame = false
                return
            }
            encoder.setFrontFacing(.clockwise)

            // =========================================================
            // 🔥 FULL RENDER PIPELINE STARTS HERE
            // =========================================================

            // ---- SKY ----
            if drawWorldEnabled,
               snapshot.worldCommandCount > 0,
               let worldDrawsPointer = Q3MetalRenderer_GetWorldDrawCommands(),
               let sceneView = Q3MetalRenderer_GetSceneView()?.pointee,
               let worldVertexBuffer = uploadWorldBuffers(device: view.device, generation: snapshot.worldGeneration),
               let worldIndexBuffer,
               let skyPipelineState,
               let skyDepthStencilState {

                let worldDraws = Array(
                    UnsafeBufferPointer(
                        start: worldDrawsPointer,
                        count: Int(snapshot.worldCommandCount)
                    )
                )

                var worldUniforms = WorldUniforms(
                    viewProjection: makeWorldViewProjection(sceneView),
                    cameraPos: SIMD3<Float>(
                        sceneView.viewOrigin.0,
                        sceneView.viewOrigin.1,
                        sceneView.viewOrigin.2
                    )
                )

                encoder.setVertexBuffer(worldVertexBuffer, offset: 0, index: 0)
                encoder.setVertexBytes(&worldUniforms, length: MemoryLayout<WorldUniforms>.stride, index: 1)

                for draw in worldDraws where draw.indexCount > 0 && (draw.flags & SKY_FLAG) != 0 {
                    if noPortalsEnabled && (draw.flags & PORTAL_FLAG) != 0 {
                        continue
                    }
                    let stageCount = min(Int(draw.stageCount), Int(Q3_METAL_MAX_STAGES))
                    guard stageCount > 0 else { continue }

                    for stageIndex in 0..<stageCount {
                        let stage = Self.worldStage(draw, stageIndex)
                        guard let skyTexture = texture(for: stage.textureHandle, device: view.device) else {
                            continue
                        }

                        let useAdditiveSky = stage.blendMode == 1 && skyAdditivePipelineState != nil
                        encoder.setRenderPipelineState(useAdditiveSky ? skyAdditivePipelineState! : skyPipelineState)
                        encoder.setDepthStencilState(skyDepthStencilState)
                        encoder.setCullMode(.none)
                        encoder.setFragmentSamplerState(worldSamplerState, index: 0)

                        let _tc = Self.fillTcMods(stage)
                        var drawUniforms = WorldDrawUniforms(
                            tcGen: Float(stage.tcGen),
                            tcModCount: _tc.count,
                            rgbGen: Float(stage.rgbGen),
                            timeSeconds: Float(frameTime - frameTimeOrigin),
                            tcModType: _tc.types,
                            tcModParams0: _tc.p0,
                            tcModParams1: _tc.p1,
                            tcModParams2: _tc.p2,
                            tcModParams3: _tc.p3,
                            debugMode: Self.worldDebugMode,
                            forceWhiteVertColor: 1,
                            alphaTestThreshold: 0,
                            blendMode: Int32(stage.blendMode),
                            alphaGen: Float(stage.alphaGen),
                            debugPassColor: debugColor(pass: worldPassIndex(blendMode: stage.blendMode))
                        )

                        encoder.setFragmentTexture(skyTexture, index: 0)
                        encoder.setFragmentBytes(&drawUniforms, length: MemoryLayout<WorldDrawUniforms>.stride, index: 0)
                        encoder.setFragmentBytes(&worldUniforms, length: MemoryLayout<WorldUniforms>.stride, index: 1)

                        encoder.drawIndexedPrimitives(
                            type: .triangle,
                            indexCount: Int(draw.indexCount),
                            indexType: .uint32,
                            indexBuffer: worldIndexBuffer,
                            indexBufferOffset: Int(draw.firstIndex) * MemoryLayout<UInt32>.stride
                        )
                    }
                }

                // Restore depth state for world/entities
                encoder.setDepthStencilState(depthStencilState)
                encoder.setCullMode(.back)
            }
            // ---- WORLD ----
            if drawWorldEnabled,
               snapshot.worldCommandCount > 0,
               let worldDrawsPointer = Q3MetalRenderer_GetWorldDrawCommands(),
               let sceneView = Q3MetalRenderer_GetSceneView()?.pointee,
               let worldVertexBuffer = uploadWorldBuffers(device: view.device, generation: snapshot.worldGeneration),
               let worldIndexBuffer {

                let worldDraws = Array(
                    UnsafeBufferPointer(
                        start: worldDrawsPointer,
                        count: Int(snapshot.worldCommandCount)
                    )
                )

                let timeSeconds = Float(frameTime - frameTimeOrigin)
                let debugRenderMode = Float(Q3MetalRenderer_GetDebugRenderMode())
                // Diagnostic toggle: pin UVs to static BSP values by forcing
                // tcMod to 0 on every stage. Used to isolate whether
                // "flying texture" artifacts come from the tcMod parameter
                // path. Toggle with `\r_disableTcMod 1`.
                let disableTcMod = Q3MetalRenderer_GetDisableTcMod() != 0

                // build uniforms
                let viewProjection = makeWorldViewProjection(sceneView)
                let cameraPos = SIMD3<Float>(
                    sceneView.viewOrigin.0,
                    sceneView.viewOrigin.1,
                    sceneView.viewOrigin.2
                )

                var worldUniforms = WorldUniforms(
                    viewProjection: viewProjection,
                    cameraPos: cameraPos
                )

                encoder.setDepthStencilState(depthStencilState)
                encoder.setVertexBuffer(worldVertexBuffer, offset: 0, index: 0)
                encoder.setVertexBytes(&worldUniforms, length: MemoryLayout<WorldUniforms>.stride, index: 1)
                encoder.setFragmentBytes(&worldUniforms, length: MemoryLayout<WorldUniforms>.stride, index: 1)

                // ---- DRAW WORLD PASSES ----
                // Batching strategy: hoist the opaque/non-opaque phase loop
                // outside the per-draw iteration so adjacent same-state
                // stages across draws emit contiguously, then coalesce runs
                // of same-state stages with contiguous index ranges into a
                // single drawIndexedPrimitives call. BSP loader emits each
                // surface's indices directly after the previous one, so
                // adjacent draws naturally have contiguous index ranges.
                encoder.setFragmentSamplerState(worldSamplerState, index: 0)

                // Per-phase batch state. These are reset at each phase
                // boundary; a flush writes the current run and clears.
                var lastPipeline: MTLRenderPipelineState? = nil
                var lastDepth: MTLDepthStencilState? = nil
                var lastCull: MTLCullMode = .back
                var lastTex0: MTLTexture? = nil
                var lastTex1: MTLTexture? = nil
                var lastUniforms: WorldDrawUniforms? = nil
                var runFirstIndex: UInt32 = 0
                var runIndexCount: UInt32 = 0
                var emittedDrawCalls: Int = 0
                var stagesSeen: Int = 0

                func flushRun() {
                    if runIndexCount > 0 {
                        encoder.drawIndexedPrimitives(
                            type: .triangle,
                            indexCount: Int(runIndexCount),
                            indexType: .uint32,
                            indexBuffer: worldIndexBuffer,
                            indexBufferOffset: Int(runFirstIndex) * MemoryLayout<UInt32>.stride
                        )
                        emittedDrawCalls += 1
                        runIndexCount = 0
                    }
                }

                for opaquePhase in 0..<2 {
                    // New phase → reset tracked state so first draw rebinds everything.
                    flushRun()
                    lastPipeline = nil
                    lastDepth = nil
                    lastCull = .back
                    lastTex0 = nil
                    lastTex1 = nil
                    lastUniforms = nil

                    for draw in worldDraws where draw.indexCount > 0 && (draw.flags & SKY_FLAG) == 0 {
                        if noPortalsEnabled && (draw.flags & PORTAL_FLAG) != 0 {
                            continue
                        }

                        // Phase-1 portal-surface override. Portals render once
                        // during the opaque phase as a single drawcall sampling
                        // portalTexture; skip entirely during the non-opaque
                        // phase. State is completely distinct from normal world
                        // rendering, so a portal always flushes the current run.
                        if (draw.flags & PORTAL_FLAG) != 0 {
                            if opaquePhase != 0 { continue }
                            if let portalPipeline = worldPortalPipelineState,
                               let portalTex = portalTexture {
                                flushRun()
                                encoder.setRenderPipelineState(portalPipeline)
                                encoder.setDepthStencilState(additiveDepthStencilState)
                                encoder.setCullMode(.none)
                                encoder.setFragmentTexture(portalTex, index: 0)
                                encoder.drawIndexedPrimitives(
                                    type: .triangle,
                                    indexCount: Int(draw.indexCount),
                                    indexType: .uint32,
                                    indexBuffer: worldIndexBuffer,
                                    indexBufferOffset: Int(draw.firstIndex) * MemoryLayout<UInt32>.stride
                                )
                                emittedDrawCalls += 1
                                // Force rebind on next non-portal draw.
                                lastPipeline = nil
                                lastDepth = nil
                                lastCull = .none
                                lastTex0 = nil
                                lastTex1 = nil
                                lastUniforms = nil
                                continue
                            }
                            // Portal pipeline not ready — fall through to
                            // normal stage path so the surface still draws.
                        }

                        let stageCount = min(Int(draw.stageCount), Int(Q3_METAL_MAX_STAGES))
                        guard stageCount > 0 else { continue }

                        // Per-stage cullMode (parsed from shader `cull`
                        // directive). 0=BACK, 1=NONE (disable/twosided),
                        // 2=FRONT (inverted). noCullEnabled cvar still
                        // forces .none globally for debugging.
                        let stage0CullMode = Self.worldStage(draw, 0).cullMode
                        let targetCull: MTLCullMode = {
                            if noCullEnabled { return .none }
                            switch stage0CullMode {
                            case 1: return .none
                            case 2: return .front
                            default: return .back
                            }
                        }()

                        for stageIndex in 0..<stageCount {
                            let stage = Self.worldStage(draw, stageIndex)
                            let mode = stage.blendMode
                            let isOpaqueStage = mode == 0
                            if (opaquePhase == 0) != isOpaqueStage { continue }

                            guard let stageTexture = texture(for: stage.textureHandle, device: view.device) else {
                                continue
                            }
                            stagesSeen += 1

                            let targetPipeline: MTLRenderPipelineState?
                            switch mode {
                            case 1: targetPipeline = worldAdditivePipelineState
                            case 2: targetPipeline = worldAlphaPipelineState
                            case 3: targetPipeline = worldFilterPipelineState
                            case 4: targetPipeline = worldPremultPipelineState
                            default: targetPipeline = worldPipelineState
                            }
                            guard let targetPipeline else { continue }

                            let targetDepth: MTLDepthStencilState? =
                                isOpaqueStage ? depthStencilState : additiveDepthStencilState

                            let usesLightmap = stage.useLightmap != 0
                            let targetTex1: MTLTexture
                            if usesLightmap,
                               let lightmap = texture(for: draw.lightmapTextureHandle, device: view.device) {
                                targetTex1 = lightmap
                            } else {
                                targetTex1 = whiteTexture
                            }

                            // DIAGNOSTIC: log chain for multi-tcMod stages.
                            // `stage.tcMods` is a Swift tuple (C fixed-size
                            // array) — materialize into an Array to index by Int.
                            if stage.tcModCount > 1 {
                                let typeNames = ["NONE", "SCROLL", "WAVE", "ROTATE", "SCALE", "TURB"]
                                let chain = [stage.tcMods.0, stage.tcMods.1, stage.tcMods.2, stage.tcMods.3]
                                var typeStr = ""
                                for i in 0..<Int(stage.tcModCount) {
                                    let ti = Int(chain[i].type)
                                    let name = (ti >= 0 && ti < typeNames.count) ? typeNames[ti] : "UNKNOWN"
                                    if i > 0 { typeStr += "," }
                                    typeStr += name
                                }
                                let shaderKey = String(format: "tex=0x%x", stage.textureHandle)
                                print("[DRAW] \(shaderKey) tcModCount=\(stage.tcModCount) types=\(typeStr)")
                            }
                            let _tc: TcModChainPack = disableTcMod ? Self.kZeroTcModPack : Self.fillTcMods(stage)
                            let targetUniforms = WorldDrawUniforms(
                                tcGen: Float(stage.tcGen),
                                tcModCount: _tc.count,
                                rgbGen: Float(stage.rgbGen),
                                timeSeconds: timeSeconds,
                                tcModType: _tc.types,
                                tcModParams0: _tc.p0,
                                tcModParams1: _tc.p1,
                                tcModParams2: _tc.p2,
                                tcModParams3: _tc.p3,
                                debugMode: debugRenderMode,
                                forceWhiteVertColor: (mode == 1 || stage.rgbGen == 0) ? 1 : 0,
                                alphaTestThreshold: Self.alphaTestThreshold(for: stage.alphaFunc),
                                blendMode: Int32(stage.blendMode),
                                alphaGen: Float(stage.alphaGen),
                                debugPassColor: debugColor(pass: worldPassIndex(blendMode: stage.blendMode))
                            )
                            // DIAGNOSTIC: verify uniform carries the full chain.
                            if targetUniforms.tcModCount > 1 {
                                print("[UNIFORM] tcModCount=\(targetUniforms.tcModCount) " +
                                      "types=(\(targetUniforms.tcModType.x),\(targetUniforms.tcModType.y)," +
                                      "\(targetUniforms.tcModType.z),\(targetUniforms.tcModType.w)) " +
                                      "p0=(\(targetUniforms.tcModParams0.x),\(targetUniforms.tcModParams0.y)) " +
                                      "p1=(\(targetUniforms.tcModParams1.x),\(targetUniforms.tcModParams1.y))")
                            }

                            let stateMatches =
                                lastPipeline === targetPipeline &&
                                lastDepth === targetDepth &&
                                lastCull == targetCull &&
                                lastTex0 === stageTexture &&
                                lastTex1 === targetTex1 &&
                                lastUniforms == targetUniforms

                            let contiguous =
                                stateMatches &&
                                runIndexCount > 0 &&
                                draw.firstIndex == runFirstIndex + runIndexCount

                            if contiguous {
                                runIndexCount += draw.indexCount
                                continue
                            }

                            // Either state differs or index range breaks —
                            // flush the accumulated run, then rebind only
                            // what changed, and start a new run.
                            flushRun()

                            if lastPipeline !== targetPipeline {
                                encoder.setRenderPipelineState(targetPipeline)
                                lastPipeline = targetPipeline
                            }
                            if lastDepth !== targetDepth {
                                if let targetDepth { encoder.setDepthStencilState(targetDepth) }
                                lastDepth = targetDepth
                            }
                            if lastCull != targetCull {
                                encoder.setCullMode(targetCull)
                                lastCull = targetCull
                            }
                            if lastTex0 !== stageTexture {
                                encoder.setFragmentTexture(stageTexture, index: 0)
                                lastTex0 = stageTexture
                            }
                            if lastTex1 !== targetTex1 {
                                encoder.setFragmentTexture(targetTex1, index: 1)
                                lastTex1 = targetTex1
                            }
                            if lastUniforms != targetUniforms {
                                var u = targetUniforms
                                encoder.setFragmentBytes(
                                    &u,
                                    length: MemoryLayout<WorldDrawUniforms>.stride,
                                    index: 0
                                )
                                lastUniforms = targetUniforms
                            }

                            runFirstIndex = draw.firstIndex
                            runIndexCount = draw.indexCount
                        }
                    }

                    flushRun()
                }

                if Self.worldBatchLogEnabled {
                    print("[batch] world stages=\(stagesSeen) drawCalls=\(emittedDrawCalls)")
                }
            }

            // ---- INLINE BSP MODELS ----
            if drawWorldEnabled,
               snapshot.inlineModelCommandCount > 0,
               let inlineInstancesPointer = Q3MetalRenderer_GetInlineModelInstances(),
               let worldDrawsPointer = Q3MetalRenderer_GetWorldDrawCommands(),
               let sceneView = Q3MetalRenderer_GetSceneView()?.pointee,
               let worldVertexBuffer = uploadWorldBuffers(device: view.device, generation: snapshot.worldGeneration),
               let worldIndexBuffer {

                let inlineInstances = UnsafeBufferPointer(
                    start: inlineInstancesPointer,
                    count: Int(snapshot.inlineModelCommandCount)
                )
                let maxDrawIndex = inlineInstances.reduce(Int(snapshot.worldCommandCount)) {
                    max($0, Int($1.firstDraw + $1.drawCount))
                }
                let worldAllDraws = UnsafeBufferPointer(
                    start: worldDrawsPointer,
                    count: maxDrawIndex
                )
                let timeSeconds = Float(frameTime - frameTimeOrigin)
                let debugRenderMode = Float(Q3MetalRenderer_GetDebugRenderMode())
                let disableTcMod = Q3MetalRenderer_GetDisableTcMod() != 0
                let viewProjection = makeWorldViewProjection(sceneView)
                let cameraPos = SIMD3<Float>(
                    sceneView.viewOrigin.0,
                    sceneView.viewOrigin.1,
                    sceneView.viewOrigin.2
                )

                encoder.setVertexBuffer(worldVertexBuffer, offset: 0, index: 0)
                encoder.setFragmentSamplerState(worldSamplerState, index: 0)

                for instance in inlineInstances where instance.drawCount > 0 {
                    var inlineUniforms = WorldUniforms(
                        viewProjection: viewProjection,
                        cameraPos: cameraPos,
                        modelMatrix: makeInlineModelMatrix(instance)
                    )
                    encoder.setVertexBytes(&inlineUniforms, length: MemoryLayout<WorldUniforms>.stride, index: 1)
                    encoder.setFragmentBytes(&inlineUniforms, length: MemoryLayout<WorldUniforms>.stride, index: 1)

                    let drawStart = Int(instance.firstDraw)
                    let drawEnd = drawStart + Int(instance.drawCount)
                    for opaquePhase in 0..<2 {
                        for drawIndex in drawStart..<drawEnd {
                            let draw = worldAllDraws[drawIndex]
                            if draw.indexCount == 0 || (draw.flags & SKY_FLAG) != 0 {
                                continue
                            }
                            if noPortalsEnabled && (draw.flags & PORTAL_FLAG) != 0 {
                                continue
                            }

                            if (draw.flags & PORTAL_FLAG) != 0 {
                                if opaquePhase != 0 { continue }
                                if let portalPipeline = worldPortalPipelineState,
                                   let portalTex = portalTexture {
                                    encoder.setRenderPipelineState(portalPipeline)
                                    encoder.setDepthStencilState(additiveDepthStencilState)
                                    encoder.setCullMode(.none)
                                    encoder.setFragmentTexture(portalTex, index: 0)
                                    encoder.drawIndexedPrimitives(
                                        type: .triangle,
                                        indexCount: Int(draw.indexCount),
                                        indexType: .uint32,
                                        indexBuffer: worldIndexBuffer,
                                        indexBufferOffset: Int(draw.firstIndex) * MemoryLayout<UInt32>.stride
                                    )
                                    continue
                                }
                            }

                            let stageCount = min(Int(draw.stageCount), Int(Q3_METAL_MAX_STAGES))
                            guard stageCount > 0 else { continue }
                            // Per-stage cullMode (parsed from shader `cull`
                            // directive). Mirrors the static-world branch.
                            let stage0CullMode = Self.worldStage(draw, 0).cullMode
                            let targetCull: MTLCullMode = {
                                if noCullEnabled { return .none }
                                switch stage0CullMode {
                                case 1: return .none
                                case 2: return .front
                                default: return .back
                                }
                            }()
                            encoder.setCullMode(targetCull)

                            for stageIndex in 0..<stageCount {
                                let stage = Self.worldStage(draw, stageIndex)
                                let mode = stage.blendMode
                                let isOpaqueStage = mode == 0
                                if (opaquePhase == 0) != isOpaqueStage { continue }
                                guard let stageTexture = texture(for: stage.textureHandle, device: view.device) else {
                                    continue
                                }

                                switch mode {
                                case 1:
                                    if let p = worldAdditivePipelineState { encoder.setRenderPipelineState(p) }
                                case 2:
                                    if let p = worldAlphaPipelineState { encoder.setRenderPipelineState(p) }
                                case 3:
                                    if let p = worldFilterPipelineState { encoder.setRenderPipelineState(p) }
                                case 4:
                                    if let p = worldPremultPipelineState { encoder.setRenderPipelineState(p) }
                                default:
                                    if let p = worldPipelineState { encoder.setRenderPipelineState(p) }
                                }

                                encoder.setDepthStencilState(isOpaqueStage ? depthStencilState : additiveDepthStencilState)
                                encoder.setFragmentTexture(stageTexture, index: 0)
                                let usesLightmap = stage.useLightmap != 0
                                if usesLightmap,
                                   let lightmap = texture(for: draw.lightmapTextureHandle, device: view.device) {
                                    encoder.setFragmentTexture(lightmap, index: 1)
                                } else {
                                    encoder.setFragmentTexture(whiteTexture, index: 1)
                                }

                                let _tc: TcModChainPack = disableTcMod ? Self.kZeroTcModPack : Self.fillTcMods(stage)
                                var drawUniforms = WorldDrawUniforms(
                                    tcGen: Float(stage.tcGen),
                                    tcModCount: _tc.count,
                                    rgbGen: Float(stage.rgbGen),
                                    timeSeconds: timeSeconds,
                                    tcModType: _tc.types,
                                    tcModParams0: _tc.p0,
                                    tcModParams1: _tc.p1,
                                    tcModParams2: _tc.p2,
                                    tcModParams3: _tc.p3,
                                    debugMode: debugRenderMode,
                                    forceWhiteVertColor: (mode == 1 || stage.rgbGen == 0) ? 1 : 0,
                                    alphaTestThreshold: Self.alphaTestThreshold(for: stage.alphaFunc),
                                    blendMode: Int32(stage.blendMode),
                                    alphaGen: Float(stage.alphaGen),
                                    debugPassColor: debugColor(pass: worldPassIndex(blendMode: stage.blendMode))
                                )
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
                    }
                }
            }

            // ---- ENTITIES ----
            if drawEntitiesEnabled,
               snapshot.entityCommandCount > 0,
               let entityPipelineState,
               let sceneView = Q3MetalRenderer_GetSceneView()?.pointee,
               let entityVertexBuffer = uploadEntityBuffers(device: view.device),
               let entityIndexBuffer,
               let entityDrawsPointer = Q3MetalRenderer_GetEntityDrawCommands() {

                let entityViewProjection = makeWorldViewProjection(sceneView)
                let entityDepthHackViewProjection = makeDepthHackViewProjection(entityViewProjection)
                var entityUniforms = EntityUniforms(viewProjection: entityViewProjection)
                var entityDepthHackUniforms = EntityUniforms(viewProjection: entityDepthHackViewProjection)
                encoder.setRenderPipelineState(entityPipelineState)
                encoder.setDepthStencilState(ensuredDepthStencilState(depthStencilState, device: view.device))
                encoder.setFrontFacing(.clockwise)
                encoder.setCullMode(.none)
                encoder.setVertexBuffer(entityVertexBuffer, offset: 0, index: 0)
                encoder.setVertexBytes(&entityUniforms, length: MemoryLayout<EntityUniforms>.stride, index: 1)
                encoder.setFragmentSamplerState(worldSamplerState, index: 0)

                let entityDraws = UnsafeBufferPointer(start: entityDrawsPointer, count: Int(snapshot.entityCommandCount))
                let depthHackBit = UInt32(Q3_METAL_ENTITY_DRAWFLAG_DEPTHHACK)
                let additiveBit = UInt32(Q3_METAL_ENTITY_DRAWFLAG_ADDITIVE)
                let alphaBit = UInt32(Q3_METAL_ENTITY_DRAWFLAG_ALPHA)
                let filterBit = UInt32(Q3_METAL_ENTITY_DRAWFLAG_FILTER)
                let nocullBit = UInt32(Q3_METAL_ENTITY_DRAWFLAG_NOCULL)
                let firstPersonBit = UInt32(Q3_METAL_ENTITY_DRAWFLAG_FIRST_PERSON)
                let portalBit = UInt32(Q3_METAL_ENTITY_DRAWFLAG_PORTAL)

                // FIRST_PERSON hard override: viewmodel bypasses the 4-pass
                // system. Any blendMode on the weapon texture would otherwise
                // flip wantsReadOnlyDepth on and lose the depth hack, causing
                // the classic "ghost gun" transparency. Force opaque pipeline
                // + depth-hack stencil + no cull, and skip these draws in the
                // main loop below.
                var firstPersonDebugColor = debugColor(pass: 0)
                for draw in entityDraws where draw.indexCount > 0 {
                    guard (draw.flags & firstPersonBit) != 0 else { continue }
                    if noPortalsEnabled && (draw.flags & portalBit) != 0 {
                        continue
                    }
                    guard let texture = texture(for: draw.textureHandle, device: view.device) else {
                        continue
                    }
                    encoder.setRenderPipelineState(entityPipelineState)
                    encoder.setDepthStencilState(ensuredDepthStencilState(depthHackDepthStencilState, device: view.device))
                    encoder.setCullMode(.none)
                    encoder.setVertexBytes(&entityDepthHackUniforms, length: MemoryLayout<EntityUniforms>.stride, index: 1)
                    encoder.setFragmentBytes(&firstPersonDebugColor, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
                    encoder.setFragmentTexture(texture, index: 0)
                    encoder.drawIndexedPrimitives(
                        type: .triangle,
                        indexCount: Int(draw.indexCount),
                        indexType: .uint32,
                        indexBuffer: entityIndexBuffer,
                        indexBufferOffset: Int(draw.firstIndex) * MemoryLayout<UInt32>.stride
                    )
                }

                // Ordered entity passes:
                // 0 = opaque, 1 = filter, 2 = alpha, 3 = additive.
                for entityPass in 0..<4 {
                    var passDebugColor = debugColor(pass: entityPass)
                    encoder.setFragmentBytes(&passDebugColor, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
                    for draw in entityDraws where draw.indexCount > 0 {
                        if (draw.flags & firstPersonBit) != 0 { continue }
                        if noPortalsEnabled && (draw.flags & portalBit) != 0 {
                            continue
                        }

                        // Phase-2 entity portal override: an entity whose
                        // surface texture is a portal shader samples
                        // portalTexture instead of its MD3 skin. Uses the
                        // dedicated q3_entity_portal_fragment which samples
                        // by screen position (in.position.xy / screenSize)
                        // so the RTT image isn't stretched by arbitrary
                        // MD3 UVs. Routed through the alpha pass only.
                        if (draw.flags & portalBit) != 0,
                           entityPass == 2,
                           let portalTex = portalTexture,
                           let entityPortalPipeline = entityPortalPipelineState {
                            encoder.setRenderPipelineState(entityPortalPipeline)
                            encoder.setDepthStencilState(ensuredDepthStencilState(additiveEntityDepthStencilState, device: view.device))
                            encoder.setCullMode(.none)
                            encoder.setVertexBytes(&entityUniforms, length: MemoryLayout<EntityUniforms>.stride, index: 1)
                            var screenSize = SIMD2<Float>(
                                Float(max(snapshot.drawableWidth, 1)),
                                Float(max(snapshot.drawableHeight, 1))
                            )
                            encoder.setFragmentBytes(&screenSize, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
                            encoder.setFragmentTexture(portalTex, index: 0)
                            encoder.drawIndexedPrimitives(
                                type: .triangle,
                                indexCount: Int(draw.indexCount),
                                indexType: .uint32,
                                indexBuffer: entityIndexBuffer,
                                indexBufferOffset: Int(draw.firstIndex) * MemoryLayout<UInt32>.stride
                            )
                            // Restore debugPassColor at fragment buffer 0 —
                            // the portal override overwrote that slot with
                            // an 8-byte screenSize, but the subsequent
                            // non-portal q3_entity_fragment reads 16 bytes
                            // as debugPassColor. Without this restore the
                            // shader reads garbage upper bytes and triggers
                            // solid-replace / tint on every entity drawn
                            // after a portal entity in this pass.
                            encoder.setFragmentBytes(&passDebugColor, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
                            continue
                        }
                        // Portal-flagged entities on non-alpha passes are
                        // already handled above; skip in other passes.
                        if (draw.flags & portalBit) != 0 { continue }

                        let isEntityAdditive = (draw.flags & additiveBit) != 0
                        let isEntityAlpha = (draw.flags & alphaBit) != 0
                        let isEntityFilter = (draw.flags & filterBit) != 0
                        let drawPass = isEntityAdditive ? 3 : (isEntityAlpha ? 2 : (isEntityFilter ? 1 : 0))
                        guard drawPass == entityPass else { continue }
                        guard let texture = texture(for: draw.textureHandle, device: view.device) else {
                            continue
                        }

                        let wantsDepthHack = (draw.flags & depthHackBit) != 0
                        let wantsNoCull = (draw.flags & nocullBit) != 0
                        let wantsReadOnlyDepth = isEntityAdditive || isEntityAlpha || isEntityFilter
                        encoder.setCullMode(noCullEnabled || wantsNoCull ? .none : .back)
                        if wantsDepthHack {
                            encoder.setVertexBytes(&entityDepthHackUniforms, length: MemoryLayout<EntityUniforms>.stride, index: 1)
                        } else {
                            encoder.setVertexBytes(&entityUniforms, length: MemoryLayout<EntityUniforms>.stride, index: 1)
                        }

                        if drawPass == 3, let entityAdditivePipelineState {
                            encoder.setRenderPipelineState(entityAdditivePipelineState)
                        } else if drawPass == 2, let entityAlphaPipelineState {
                            encoder.setRenderPipelineState(entityAlphaPipelineState)
                        } else if drawPass == 1, let entityFilterPipelineState {
                            encoder.setRenderPipelineState(entityFilterPipelineState)
                        } else {
                            encoder.setRenderPipelineState(entityPipelineState)
                        }
                        let state = wantsReadOnlyDepth
                            ? additiveEntityDepthStencilState
                            : (wantsDepthHack ? depthHackDepthStencilState : depthStencilState)
                        encoder.setDepthStencilState(ensuredDepthStencilState(state, device: view.device))

                        encoder.setFragmentTexture(texture, index: 0)
                        encoder.drawIndexedPrimitives(
                            type: .triangle,
                            indexCount: Int(draw.indexCount),
                            indexType: .uint32,
                            indexBuffer: entityIndexBuffer,
                            indexBufferOffset: Int(draw.firstIndex) * MemoryLayout<UInt32>.stride
                        )
                    }
                }
            }

            // ---- UI ----
            if snapshot.vertexCount > 0,
               let verticesPointer = Q3MetalRenderer_GetVertices(),
               let drawCommandsPointer = Q3MetalRenderer_GetDrawCommands() {

                let projection = makeOrthoProjection(width: max(Float(snapshot.drawableWidth), 1.0), height: max(Float(snapshot.drawableHeight), 1.0))
                var uniforms = Uniforms(projection: projection)

                encoder.setDepthStencilState(ensuredDepthStencilState(nil, device: view.device))
                encoder.setFragmentSamplerState(uiSamplerState, index: 0)

                let vertexCount = Int(snapshot.vertexCount)
                if let vertexBuffer = uploadVertices(UnsafeBufferPointer(start: verticesPointer, count: vertexCount), device: view.device) {
                    encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
                    encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)

                    var currentUIPipeline: MTLRenderPipelineState? = nil
                    let drawCommands = UnsafeBufferPointer(start: drawCommandsPointer, count: Int(snapshot.commandCount))
                    for draw in drawCommands {
                        // Per-draw pipeline switch: blendMode==3 uses the
                        // filter variant (for viewBloodBlend); everything
                        // else uses the default alpha-blend UI pipeline.
                        let targetPipeline: MTLRenderPipelineState? =
                            (draw.blendMode == 3) ? uiFilterPipelineState : uiPipelineState
                        if targetPipeline !== currentUIPipeline {
                            if let p = targetPipeline {
                                encoder.setRenderPipelineState(p)
                                currentUIPipeline = p
                            }
                        }
                        if let texture = texture(for: draw.textureHandle, device: view.device) {
                            encoder.setFragmentTexture(texture, index: 0)
                            encoder.drawPrimitives(type: .triangle, vertexStart: Int(draw.firstVertex), vertexCount: Int(draw.vertexCount))
                        }
                    }
                }
            }

            // =========================================================
            // 🔥 END PIPELINE
            // =========================================================

            encoder.endEncoding()

            // ---- 5. PRESENT EXACTLY ONCE ----
            commandBuffer.present(drawable)
            commandBuffer.commit()

            inFrame = false
        }

        @MainActor
        private func configureRenderer(for view: MTKView) {
            guard let device = view.device else { return }

            commandQueue = device.makeCommandQueue()
            let whitePixel: [UInt8] = [255, 255, 255, 255]
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba8Unorm,
                width: 1,
                height: 1,
                mipmapped: false
            )
            whiteTexture = device.makeTexture(descriptor: desc)
            whiteTexture.replace(
                region: MTLRegionMake2D(0, 0, 1, 1),
                mipmapLevel: 0,
                withBytes: whitePixel,
                bytesPerRow: 4
            )

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

            // Filter-mode UI pipeline: src=dst_color, dst=zero. Approximates
            // Q3's GL_DST_COLOR/GL_SRC_ALPHA used by viewBloodBlend.
            let uiFilterPipelineDescriptor = MTLRenderPipelineDescriptor()
            uiFilterPipelineDescriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
            uiFilterPipelineDescriptor.depthAttachmentPixelFormat = view.depthStencilPixelFormat
            uiFilterPipelineDescriptor.vertexFunction = library.makeFunction(name: "q3_ui_vertex")
            uiFilterPipelineDescriptor.fragmentFunction = library.makeFunction(name: "q3_ui_fragment")
            uiFilterPipelineDescriptor.colorAttachments[0].isBlendingEnabled = true
            uiFilterPipelineDescriptor.colorAttachments[0].rgbBlendOperation = .add
            uiFilterPipelineDescriptor.colorAttachments[0].alphaBlendOperation = .add
            uiFilterPipelineDescriptor.colorAttachments[0].sourceRGBBlendFactor = .destinationColor
            uiFilterPipelineDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .destinationAlpha
            uiFilterPipelineDescriptor.colorAttachments[0].destinationRGBBlendFactor = .zero
            uiFilterPipelineDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .zero

            do {
                uiFilterPipelineState = try device.makeRenderPipelineState(descriptor: uiFilterPipelineDescriptor)
            } catch {
                print("[Metal] Failed to create UI filter pipeline: \\(error)")
            }

            let worldPipelineDescriptor = MTLRenderPipelineDescriptor()
            worldPipelineDescriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
            worldPipelineDescriptor.depthAttachmentPixelFormat = view.depthStencilPixelFormat
            worldPipelineDescriptor.vertexFunction = library.makeFunction(name: "q3_world_vertex")
            worldPipelineDescriptor.fragmentFunction = library.makeFunction(name: "q3_world_frag_opaque")

            do {
                worldPipelineState = try device.makeRenderPipelineState(descriptor: worldPipelineDescriptor)
            } catch {
                print("[Metal] Failed to create world pipeline: \\(error)")
            }

            let worldFilterPipelineDescriptor = worldPipelineDescriptor.copy() as! MTLRenderPipelineDescriptor
            worldFilterPipelineDescriptor.fragmentFunction = library.makeFunction(name: "q3_world_frag_filter")
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
            worldAlphaPipelineDescriptor.fragmentFunction = library.makeFunction(name: "q3_world_frag_alpha")
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

            // Portal pipeline: clone of the alpha pipeline with the portal
            // fragment substituted. Same src-alpha/one-minus blend so the
            // portal surface can be composited over whatever geometry lies
            // behind it if the shader author drew it translucently.
            let worldPortalPipelineDescriptor = worldAlphaPipelineDescriptor.copy() as! MTLRenderPipelineDescriptor
            worldPortalPipelineDescriptor.fragmentFunction = library.makeFunction(name: "q3_portal_fragment")
            do {
                worldPortalPipelineState = try device.makeRenderPipelineState(descriptor: worldPortalPipelineDescriptor)
            } catch {
                print("[Metal] Failed to create portal pipeline: \\(error)")
            }

            let worldAdditivePipelineDescriptor = worldPipelineDescriptor.copy() as! MTLRenderPipelineDescriptor
            worldAdditivePipelineDescriptor.fragmentFunction = library.makeFunction(name: "q3_world_frag_add")
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

            // Premultiplied-alpha pipeline. Shares the alpha fragment
            // (which already emits straight texel.rgb — correct for
            // premultiplied sources) but blend factors are (ONE,
            // ONE_MINUS_SRC_ALPHA) so the src.rgb isn't multiplied by
            // src.a a second time during the blend.
            let worldPremultPipelineDescriptor = worldAlphaPipelineDescriptor.copy() as! MTLRenderPipelineDescriptor
            worldPremultPipelineDescriptor.colorAttachments[0].sourceRGBBlendFactor = .one
            worldPremultPipelineDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            worldPremultPipelineDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
            worldPremultPipelineDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

            do {
                worldPremultPipelineState = try device.makeRenderPipelineState(descriptor: worldPremultPipelineDescriptor)
            } catch {
                print("[Metal] Failed to create premult world pipeline: \\(error)")
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
            entityAdditiveDesc.fragmentFunction = library.makeFunction(name: "q3_entity_additive_fragment")
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

            // Entity portal pipeline — clone of entity alpha with the
            // dedicated screen-UV fragment. Used when an MD3 surface
            // references a portal shader so the RTT samples by screen
            // position instead of stretching across model UVs.
            let entityPortalDesc = entityAlphaDesc.copy() as! MTLRenderPipelineDescriptor
            entityPortalDesc.fragmentFunction = library.makeFunction(name: "q3_entity_portal_fragment")
            do {
                entityPortalPipelineState = try device.makeRenderPipelineState(descriptor: entityPortalDesc)
            } catch {
                print("[Metal] Failed to create entity portal pipeline: \\(error)")
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

            // Depth-hack state for first-person viewmodel. Stock Q3 does not
            // bypass depth testing; it compresses the draw into a reduced
            // depth range near the camera. The special projection below does
            // the range squeeze, so the stencil state stays on normal
            // lessEqual testing with writes enabled.
            let depthHackDescriptor = MTLDepthStencilDescriptor()
            depthHackDescriptor.isDepthWriteEnabled = true
            depthHackDescriptor.depthCompareFunction = .lessEqual
            depthHackDepthStencilState = device.makeDepthStencilState(descriptor: depthHackDescriptor)

            // Portal RTT targets — created at the current drawable size so
            // the first frame has valid textures even if drawableSizeWillChange
            // hasn't fired yet. Resize handler above reallocates on change.
            createPortalTargets(device: device, size: view.drawableSize, colorPixelFormat: view.colorPixelFormat)
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

        private func makeInlineModelMatrix(_ instance: Q3MetalInlineModelInstance) -> simd_float4x4 {
            simd_float4x4(columns: (
                SIMD4<Float>(instance.axis.0, instance.axis.1, instance.axis.2, 0),
                SIMD4<Float>(instance.axis.3, instance.axis.4, instance.axis.5, 0),
                SIMD4<Float>(instance.axis.6, instance.axis.7, instance.axis.8, 0),
                SIMD4<Float>(instance.origin.0, instance.origin.1, instance.origin.2, 1)
            ))
        }

        private func makeOrthoProjection(width: Float, height: Float) -> simd_float4x4 {
            simd_float4x4(columns: (
                SIMD4<Float>(2.0 / width, 0, 0, 0),
                SIMD4<Float>(0, -2.0 / height, 0, 0),
                SIMD4<Float>(0, 0, 1, 0),
                SIMD4<Float>(-1, 1, 0, 1)
            ))
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

        private func makeDepthHackViewProjection(_ matrix: simd_float4x4,
                                                 depthScale: Float = 0.3) -> simd_float4x4 {
            var hacked = matrix
            hacked.columns.0.z *= depthScale
            hacked.columns.1.z *= depthScale
            hacked.columns.2.z *= depthScale
            hacked.columns.3.z *= depthScale
            return hacked
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
