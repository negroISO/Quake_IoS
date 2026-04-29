import SwiftUI
import MetalKit
import GameController
import QuartzCore
import simd

struct MetalView: UIViewRepresentable {
    func makeUIView(context: Context) -> Q3InputView {
        let view = Q3InputView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.colorPixelFormat = .bgra8Unorm
        view.depthStencilPixelFormat = .depth32Float
        view.delegate = context.coordinator
        #if os(visionOS)
        let maxFPS = 90
        #else
        let maxFPS = UIScreen.main.maximumFramesPerSecond
        #endif
        view.preferredFramesPerSecond = maxFPS
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        // Lock the MTKView's drawable to the engine's logical render
        // resolution so the AVI muxer captures pixels at exactly the
        // resolution Q3's r_customwidth/r_customheight set. Without
        // this, MTKView auto-sizes drawableSize to bounds *
        // contentScaleFactor (Retina), which on iPad's SwiftUI layout
        // resolves to ~592×720 — wrong size AND wrong aspect (5:6 vs
        // engine's 4:3). All AVI parity diffs against Vulkan refs at
        // 1280×960 then become invalid resize-distorted comparisons.
        // contentScaleFactor=1.0 disables Retina doubling so
        // drawableSize equals the explicit value below.
        // Drawable lock applied lazily in drawableSizeWillChange (the
        // view doesn't have valid bounds yet here; setting drawableSize
        // pre-window produces a NaN drawable). We only mark the
        // intent here — the delegate enforces it on every resize.
        view.autoResizeDrawable = false
        if let metalLayer = view.layer as? CAMetalLayer {
            if #available(iOS 16.0, visionOS 1.0, *) {
                metalLayer.developerHUDProperties = ["mode": "hidden"]
            }
        }
        return view
    }

    func updateUIView(_ uiView: Q3InputView, context: Context) {}

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
            /* World-space vertex normal from drawVert_t.normal. Smooth-
             * interpolated by the rasterizer; the fragment uses it for
             * env-map reflections so curved patches stop looking
             * faceted. Zero lets the fragment dfdx/dfdy fallback fire. */
            var normal: SIMD3<Float>
            var color: SIMD4<Float>
            /* Per-quad center for autosprite surfaces; vertex shader
             * uses center + cameraRight/Up to emit a camera-aligned
             * billboard. xyz used, .w pad. Zero (length≈0) means
             * "not an autosprite vertex" — pass-through. Filled by
             * the BSP load post-pass in metal_renderer_stub.c. */
            var autospriteCenter: SIMD4<Float>
            /* Per-quad long-axis unit vector for autoSprite2 surfaces
             * only. xyz = direction of the quad's long edge pair (the
             * axis the deform must preserve); .w pad. Zero for non-
             * autoSprite2 verts. Mode 2 vertex shader projects camera
             * basis perpendicular to this axis to build the billboard. */
            var autospriteLongAxis: SIMD4<Float>
        }

        struct WorldUniforms {
            var viewProjection: simd_float4x4
            var cameraPos: SIMD3<Float>    // for sky sphere-mapping
            var _pad: Float = 0            // pad to 16-byte alignment
            /* Camera basis for autosprite billboard transform —
             * cameraRight = sceneView.viewAxis[1] (Q3 "left" → negate
             * to get screen-right; we store the right vector here),
             * cameraUp = viewAxis[2]. .xyz used, .w pad. */
            var cameraRight: SIMD3<Float> = SIMD3<Float>(1, 0, 0)
            var _padR: Float = 0
            var cameraUp: SIMD3<Float> = SIMD3<Float>(0, 0, 1)
            var _padU: Float = 0
        }

        struct WorldDrawUniforms {
            var tcGen: Float
            var tcModCount: Int32
            var rgbGen: Float
            var alphaGen: Float = 0
            var blendMode: Float = 0
            var timeSeconds: Float
            var rgbWaveFunc: UInt32 = 0
            var alphaWaveFunc: UInt32 = 0
            var _wavePad: UInt32 = 0
            var tcModType: SIMD4<Float>
            var tcModParams0: SIMD4<Float>
            var tcModParams1: SIMD4<Float>
            var tcModParams2: SIMD4<Float>
            var tcModParams3: SIMD4<Float>
            var rgbWaveParams: SIMD4<Float> = SIMD4(0, 0, 0, 0)
            var alphaWaveParams: SIMD4<Float> = SIMD4(0, 0, 0, 0)
            // Fog for this draw. xyz = linear fog color, w = fog distance
            // (units of world space). w == 0 ⇒ no fog, fragment skips the
            // mix entirely. Populated per-draw from s_worldFogs[fogIndex].
            var fogColorDistance: SIMD4<Float>
            // x = ioq3 fog tcScale (1 / (fogDistance * 8)), y = has surface
            // plane. fogSurface is ioq3's fog.surface[4].
            var fogParams: SIMD4<Float> = SIMD4(0, 0, 0, 0)
            var fogSurface: SIMD4<Float> = SIMD4(0, 0, 0, 0)
            // tcGen vector basis. Only consulted when tcGen == 2. .xyz =
            // world-space basis vector, .w padding (ignored). UV is
            // (dot(worldPos, .xyz0), dot(worldPos, .xyz1)). Matches ioq3
            // RB_CalcTexCoords TCGEN_VECTOR.
            var tcGenVec0: SIMD4<Float> = SIMD4(0, 0, 0, 0)
            var tcGenVec1: SIMD4<Float> = SIMD4(0, 0, 0, 0)
            // deformVertexes wave parameters. Read by the world VERTEX
            // shader: func 0 = no deform; otherwise scale = wave(func,
            // base, amp, phase + (xyz.x+y+z)/div, freq, time); pos +=
            // normal * scale. Matches ioq3 DeformVertex_Wave.
            var deformWaveFunc: UInt32 = 0
            var deformWaveDiv: Float = 1.0
            var deformWaveBase: Float = 0
            var deformWaveAmp: Float = 0
            var deformWavePhase: Float = 0
            var deformWaveFreq: Float = 0
            var deformMoveFunc: UInt32 = 0
            var deformMoveVector: SIMD3<Float> = SIMD3<Float>(0, 0, 0)
            var deformMoveBase: Float = 0
            var deformMoveAmp: Float = 0
            var deformMovePhase: Float = 0
            var deformMoveFreq: Float = 0
            // deformVertexes autosprite/autoSprite2 mode. 0 = none,
            // 1 = autosprite (full billboard), 2 = autoSprite2
            // (elongated; transform pending).
            var autospriteMode: UInt32 = 0
            var debugMode: Float
            var forceWhiteVertColor: Float
            var alphaTestThreshold: Float
            var fogOnly: Float = 0
            var stageUsesLightmap: Float = 0
            var drawHasLightmapStage: Float = 0
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
            // Matches C side METAL_SHADER_CULL_*: 0=disable, 1=back, 2=front.
            switch stageCullMode {
            case 0: return .none
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
            case 3: return draw.stages.3
            case 4: return draw.stages.4
            case 5: return draw.stages.5
            case 6: return draw.stages.6
            default: return draw.stages.7
            }
        }

        typealias TcModChainPack = (types: SIMD4<Float>,
                                    p0: SIMD4<Float>, p1: SIMD4<Float>,
                                    p2: SIMD4<Float>, p3: SIMD4<Float>,
                                    count: Int32)

        /* Read the two tcGen basis vectors out of the C-bridge stage
         * and pack as SIMD4 for the WorldDrawUniforms fields. Each
         * basis comes through as `tcGenVec0: (Float,Float,Float,Float)`
         * (a flat 4-tuple — the C side stores them as `float[4]`
         * with .w pre-padded to 0). Only meaningful when stage.tcGen
         * == 2; safe to call always (returns zero vectors otherwise). */
        private static func tcGenVectors(_ stage: Q3MetalWorldStage) -> (SIMD4<Float>, SIMD4<Float>) {
            let v0 = stage.tcGenVec0
            let v1 = stage.tcGenVec1
            return (
                SIMD4<Float>(v0.0, v0.1, v0.2, v0.3),
                SIMD4<Float>(v1.0, v1.1, v1.2, v1.3)
            )
        }

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
                let v: SIMD4<Float>
                if m.type == 3 {
                    v = SIMD4<Float>(-pp.0 * .pi / 180.0, 0, 0, 0)
                } else {
                    v = SIMD4<Float>(pp.0, pp.1, pp.2, pp.3)
                }
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
            /* World-space normal — non-zero means MD3 emit path
             * supplied a smooth per-vertex normal; zero means non-MD3
             * path (sprite, beam, flare, synthetic) and the fragment
             * should fall back to dfdx/dfdy face-normal derivation. */
            var normal: SIMD3<Float>
        }

        /* Fetch the stage-0 tcMod chain for a texture handle and pack it
         * into the fragment-side slots of the provided EntityUniforms.
         * Scope is scroll (type=1) and rotate (type=3) only — any other
         * type is cleared to 0 so applyTcMod becomes a no-op. Rotate's
         * speed gets converted from degrees/sec to radians/sec AND
         * negated to match ioquake3's `degs = -degsPerSecond * timeScale`
         * sign convention (so CW rotation looks like Q3's quad shell). */
        private static func packEntityTcMods(handle: UInt32, into uniforms: inout EntityUniforms) {
            uniforms.tcModCount = 0
            uniforms.tcModType = SIMD4<Float>(0, 0, 0, 0)
            uniforms.tcModParams0 = SIMD4<Float>(0, 0, 0, 0)
            uniforms.tcModParams1 = SIMD4<Float>(0, 0, 0, 0)
            uniforms.tcModParams2 = SIMD4<Float>(0, 0, 0, 0)
            uniforms.tcModParams3 = SIMD4<Float>(0, 0, 0, 0)
            var info = Q3MetalTextureInfo()
            guard Q3MetalRenderer_GetTextureInfo(handle, &info) == 1 else { return }
            let count = Int(min(info.tcModCount, 4))
            if count == 0 { return }
            let chain = [info.tcMods.0, info.tcMods.1, info.tcMods.2, info.tcMods.3]
            var types = SIMD4<Float>(0, 0, 0, 0)
            var packed: [SIMD4<Float>] = [SIMD4(0,0,0,0), SIMD4(0,0,0,0), SIMD4(0,0,0,0), SIMD4(0,0,0,0)]
            for i in 0..<count {
                let m = chain[i]
                let pp = m.params
                switch m.type {
                case 1: /* scroll: params.xy = s/t speed, unchanged */
                    types[i] = 1
                    packed[i] = SIMD4(pp.0, pp.1, 0, 0)
                case 3: /* rotate: degrees/sec → radians/sec, negated */
                    types[i] = 3
                    packed[i] = SIMD4(-pp.0 * .pi / 180.0, 0, 0, 0)
                case 4: /* scale: params.xy = s/t scale factors, unchanged */
                    types[i] = 4
                    packed[i] = SIMD4(pp.0, pp.1, 0, 0)
                case 5: /* turb: (amp, freq, phase, _) — NOTE the MSL branch
                         * uses a UV-space sin perturbation, whereas upstream
                         * RB_CalcTurbulentTexCoords samples tess.xyz world
                         * space. Shared parity gap with world path; tracked
                         * for a follow-up that passes worldPos through. */
                    types[i] = 5
                    packed[i] = SIMD4(pp.0, pp.1, pp.2, 0)
                case 6: /* stretch: (base, amp, phase, freq) straight through */
                    types[i] = 6
                    packed[i] = SIMD4(pp.0, pp.1, pp.2, pp.3)
                case 7: /* transform matrix: m00 m01 m10 m11 */
                    types[i] = 7
                    packed[i] = SIMD4(pp.0, pp.1, pp.2, pp.3)
                case 8: /* transform translate: s t */
                    types[i] = 8
                    packed[i] = SIMD4(pp.0, pp.1, 0, 0)
                default:
                    /* outside scope — leave type=0 so applyTcMod no-ops */
                    break
                }
            }
            uniforms.tcModCount = Int32(count)
            uniforms.tcModType = types
            uniforms.tcModParams0 = packed[0]
            uniforms.tcModParams1 = packed[1]
            uniforms.tcModParams2 = packed[2]
            uniforms.tcModParams3 = packed[3]
        }

        /* Entity alphaFunc → alphaTestThreshold packing. Reuses the
         * world pipeline's sign convention: positive = discard below,
         * negative = discard at-or-above. Must be called per entity
         * draw so alpha-tested textures (grates, chain-link) get the
         * fragment-kill behavior upstream gets from qglAlphaFunc. */
        private static func packEntityAlphaFunc(handle: UInt32, into uniforms: inout EntityUniforms) {
            uniforms.alphaTestThreshold = 0
            var info = Q3MetalTextureInfo()
            guard Q3MetalRenderer_GetTextureInfo(handle, &info) == 1 else { return }
            switch info.alphaFunc {
            case 1: uniforms.alphaTestThreshold = 0.004  /* GT0  — discard alpha==0 */
            case 2: uniforms.alphaTestThreshold = 0.5    /* GE128 */
            case 3: uniforms.alphaTestThreshold = -0.5   /* LT128 — inverted */
            default: break
            }
        }

        /* Route rgbGen mode from the texture's resolved shader. Identity
         * (0) tells the fragment to render full-bright; all other modes
         * keep the existing Lambert-baked vertex color multiply. */
        private static func packEntityRgbGen(handle: UInt32, into uniforms: inout EntityUniforms) {
            uniforms.rgbGenMode = 2 /* default to lightingDiffuse to preserve existing behavior */
            uniforms.alphaGenMode = 1 /* default to vertex alpha so existing entity alpha fades still work */
            uniforms.rgbWaveFunc = 1
            uniforms.alphaWaveFunc = 1
            uniforms.rgbGenWaveParams = SIMD4<Float>(0, 0, 0, 0)
            uniforms.alphaGenWaveParams = SIMD4<Float>(0, 0, 0, 0)
            uniforms.rgbConstColor = SIMD4<Float>(1, 1, 1, 1)
            var info = Q3MetalTextureInfo()
            guard Q3MetalRenderer_GetTextureInfo(handle, &info) == 1 else { return }
            uniforms.rgbGenMode = info.rgbGen
            uniforms.alphaGenMode = info.alphaGen
            uniforms.rgbWaveFunc = max(info.rgbWaveFunc, 1)
            uniforms.alphaWaveFunc = max(info.alphaWaveFunc, 1)
            uniforms.rgbGenWaveParams = SIMD4<Float>(
                info.rgbWaveBase, info.rgbWaveAmp, info.rgbWavePhase, info.rgbWaveFreq)
            uniforms.alphaGenWaveParams = SIMD4<Float>(
                info.alphaWaveBase, info.alphaWaveAmp, info.alphaWavePhase, info.alphaWaveFreq)
            uniforms.rgbConstColor = SIMD4<Float>(
                info.rgbConstColor.0, info.rgbConstColor.1, info.rgbConstColor.2,
                info.alphaConst)
        }

        struct EntityUniforms {
            var viewProjection: simd_float4x4
            /* Camera origin in world space — used by q3_entity_fragment
             * when tcGen>0 to compute the reflection vector for chrome
             * shaders (quad shell, regen, battlesuit). 16-byte aligned
             * via SIMD3 (w is padding). */
            var cameraPos: SIMD3<Float> = SIMD3<Float>(0, 0, 0)
            var cameraForward: SIMD3<Float> = SIMD3<Float>(1, 0, 0)
            /* 1.0 when the current draw's shader has `tcGen environment`.
             * Set per entity based on Q3_METAL_ENTITY_DRAWFLAG_TCGEN_ENV.
             * 0.0 otherwise — fragment keeps mesh ST coords. */
            var tcGen: Float = 0
            /* Time in seconds for tcMod scroll/rotate — matches
             * tess.shaderTime upstream. */
            var timeSeconds: Float = 0
            /* tcMod chain (stage 0). applyTcMod matches the world
             * fragment's types (1=scroll, 3=rotate — others clamp no-op
             * per the entity scope limitation). Rotate.x is packed as
             * `-degsPerSecond * π/180` so MSL cos/sin treat it as
             * radians/sec with Q3's CW sign convention. */
            var tcModCount: Int32 = 0
            /* Entity alphaFunc packed the same way the world pipeline
             * does (alphaTestThreshold helper): positive = discard if
             * texel.a < t; negative = discard if texel.a >= -t; zero =
             * no alpha test. Populated from Q3MetalTextureInfo.alphaFunc
             * per draw. Lives in the former padding slot so layout stays
             * 176 bytes total (16-aligned). */
            var alphaTestThreshold: Float = 0
            var tcModType: SIMD4<Float> = SIMD4<Float>(0, 0, 0, 0)
            var tcModParams0: SIMD4<Float> = SIMD4<Float>(0, 0, 0, 0)
            var tcModParams1: SIMD4<Float> = SIMD4<Float>(0, 0, 0, 0)
            var tcModParams2: SIMD4<Float> = SIMD4<Float>(0, 0, 0, 0)
            var tcModParams3: SIMD4<Float> = SIMD4<Float>(0, 0, 0, 0)
            /* 0=identity (ignore Lambert, full bright), 1=vertex,
             * 2=lightingDiffuse, 3=wave. Chrome shells use identity.
             * Three padding UInt32s keep the struct 16-byte aligned
             * and stride = 192 so setFragmentBytes works. */
            var rgbGenMode: UInt32 = 0
            /* 0=identity (force alpha 1.0), 1=vertex, 3=wave.
             * Mirrors AGEN_IDENTITY. */
            var alphaGenMode: UInt32 = 0
            /* Wave function index for rgbGen wave: 1=sin, 2=triangle,
             * 3=square, 4=sawtooth, 5=inverseSawtooth (evalWave MSL
             * helper handles all five). Reuses the former pad slot. */
            var rgbWaveFunc: UInt32 = 1
            var alphaWaveFunc: UInt32 = 1
            /* rgbGen wave params (only consulted when rgbGenMode == 3):
             * (base, amp, phase, freq). GF_SIN only for minimal scope —
             * matches ioquake3 RB_CalcWaveColor: glow = clamp(base +
             * sin(2π*(phase + t*freq)) * amp, 0, 1); rgb = texel.rgb *
             * glow. */
            var rgbGenWaveParams: SIMD4<Float> = SIMD4<Float>(0, 0, 0, 0)
            /* alphaGen wave params (only consulted when alphaGenMode
             * == 3): (base, amp, phase, freq). Matches RB_CalcWaveAlpha:
             * alpha = clamp(base + sin(...)*amp, 0, 1). */
            var alphaGenWaveParams: SIMD4<Float> = SIMD4<Float>(0, 0, 0, 0)
            /* rgbGen const tint (.xyz) + alphaGen const (.w).
             * Upstream CGEN_CONST sets per-vertex rgb = constant color;
             * AGEN_CONST does the same for alpha. Fragment multiplies
             * texel.rgb by .xyz when rgbGenMode == 4 and texel.a by
             * .w when alphaGenMode == 4. Defaults to (1,1,1,1) so
             * a no-op for shaders that don't opt in. */
            var rgbConstColor: SIMD4<Float> = SIMD4<Float>(1, 1, 1, 1)
            /* refEntity_t.shader.rgba in [0,1]. Read by the entity
             * fragment for rgbGen=entity (mode 5) / oneMinusEntity (6)
             * and alphaGen=entity (5) / oneMinusEntity (6). Distinct
             * from the per-vertex `color` path because that has Lambert
             * diffuse already baked in by the C entity build loop;
             * this carries the un-Lambert'd, raw entity color. */
            var entityColor: SIMD4<Float> = SIMD4<Float>(1, 1, 1, 1)
            var fogColorDistance: SIMD4<Float> = SIMD4<Float>(0, 0, 0, 0)
            var fogParams: SIMD4<Float> = SIMD4<Float>(0, 0, 0, 0)
            var fogSurface: SIMD4<Float> = SIMD4<Float>(0, 0, 0, 0)
            /* 1 for GL_ONE/GL_ONE entity draws. These shaders are already
             * authored as full-bright additive effects; applying dynamic
             * lights to the source texture itself double-brightens muzzle
             * flashes and projectile cores. */
            var suppressDlights: UInt32 = 0
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
            float3 normal;
            float4 color;
            float4 autospriteCenter;
            float4 autospriteLongAxis;
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
            // Fog: xyz = color, w = distance (world units). w == 0 ⇒
            // no fog applies to this draw, fragment skips the mix.
            float4 fogColorDistance;
            // x = tcScale, y = has fog boundary surface.
            float4 fogParams;
            float4 fogSurface;
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
            // deformVertexes autosprite mode (1=autosprite, 2=autoSprite2,
            // 0=none).
            uint  autospriteMode;
            float debugMode;
            float forceWhiteVertColor;
            float alphaTestThreshold;
            float fogOnly;
            float stageUsesLightmap;
            float drawHasLightmapStage;
            float _pad0;
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

        float2 applyTcMod(float2 uv, float3 worldPos, int type, float4 params, float timeSeconds) {
            if (type == 1) {
                float2 adj = params.xy * timeSeconds;
                adj -= floor(adj);
                return uv + adj;
            } else if (type == 2) {
                float s = sin(timeSeconds * params.w) * params.y;
                return uv + float2(s, s);
            } else if (type == 3) {
                float a = fmod(params.x * timeSeconds, 2.0 * 3.14159265);
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

        float q3FogFactor(float3 worldPos,
                          constant WorldUniforms &uniforms,
                          constant WorldDrawUniforms &drawUniforms) {
            if (drawUniforms.fogColorDistance.w <= 0.0 ||
                drawUniforms.fogParams.x <= 0.0) {
                return 0.0;
            }

            float3 forward = normalize(cross(float3(uniforms.cameraUp),
                                             float3(uniforms.cameraRight)));
            float s = dot(worldPos - float3(uniforms.cameraPos), forward) *
                      drawUniforms.fogParams.x;
            float t = 31.0 / 32.0;

            if (drawUniforms.fogParams.y > 0.5) {
                float4 surface = drawUniforms.fogSurface;
                t = dot(worldPos, surface.xyz) + surface.w;
                float eyeT = dot(float3(uniforms.cameraPos), surface.xyz) + surface.w;
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
            if (t < (31.0 / 32.0)) {
                s *= (t - 1.0 / 32.0) / (30.0 / 32.0);
            }
            s *= 8.0;
            return sqrt(saturate(s));
        }

        struct EntityVertexIn {
            float3 position;
            float2 texCoord;
            float4 color;
            float3 normal;
        };

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
        };

        float q3EntityFogFactor(float3 worldPos,
                                constant EntityUniforms &uniforms) {
            if (uniforms.fogColorDistance.w <= 0.0 ||
                uniforms.fogParams.x <= 0.0) {
                return 0.0;
            }

            float s = dot(worldPos - uniforms.cameraPos,
                          normalize(uniforms.cameraForward)) *
                      uniforms.fogParams.x;
            float t = 31.0 / 32.0;

            if (uniforms.fogParams.y > 0.5) {
                float4 surface = uniforms.fogSurface;
                t = dot(worldPos, surface.xyz) + surface.w;
                float eyeT = dot(uniforms.cameraPos, surface.xyz) + surface.w;
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
            if (t < (31.0 / 32.0)) {
                s *= (t - 1.0 / 32.0) / (30.0 / 32.0);
            }
            s *= 8.0;
            return sqrt(saturate(s));
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
            }
            // tcMod chain — apply in order. Q3 shaders stack mods (e.g. scale
            // then scroll); order matters and cannot be reduced to one slot.
            int modCount = drawUniforms.tcModCount;
            if (modCount > 0) texCoord = applyTcMod(texCoord, in.worldPos, int(drawUniforms.tcModType.x + 0.5), drawUniforms.tcModParams0, drawUniforms.timeSeconds);
            if (modCount > 1) texCoord = applyTcMod(texCoord, in.worldPos, int(drawUniforms.tcModType.y + 0.5), drawUniforms.tcModParams1, drawUniforms.timeSeconds);
            if (modCount > 2) texCoord = applyTcMod(texCoord, in.worldPos, int(drawUniforms.tcModType.z + 0.5), drawUniforms.tcModParams2, drawUniforms.timeSeconds);
            if (modCount > 3) texCoord = applyTcMod(texCoord, in.worldPos, int(drawUniforms.tcModType.w + 0.5), drawUniforms.tcModParams3, drawUniforms.timeSeconds);
            float4 lightmap = lightmapTexture.sample(textureSampler, in.lightmapTexCoord);
            float4 texel = drawUniforms.stageUsesLightmap > 0.5
                          ? lightmap
                          : colorTexture.sample(textureSampler, texCoord);
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
            if (drawUniforms.fogOnly > 0.5) {
                if (drawUniforms.fogColorDistance.w <= 0.0) {
                    discard_fragment();
                }
                float f = q3FogFactor(in.worldPos, uniforms, drawUniforms);
                return float4(drawUniforms.fogColorDistance.xyz, f);
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
            float3 vertexColor = float3(1.0);
            if (rgbGen == 1) {
                vertexColor = in.color.rgb;
            } else if (rgbGen == 7) {
                vertexColor = float3(1.0);
            }
            if (rgbGen == 3) {
                float4 wp = drawUniforms.rgbWaveParams;
                vertexColor *= clamp(evalWave(drawUniforms.rgbWaveFunc, wp.x, wp.y, wp.z, wp.w, drawUniforms.timeSeconds), 0.0, 1.0);
            }
            if (additiveStage && rgbGen == 1) {
                vertexColor = float3(1.0);
            }
            float3 vc = mix(vertexColor, float3(1.0), drawUniforms.forceWhiteVertColor);
            float  va = mix(in.color.a,   1.0,          drawUniforms.forceWhiteVertColor);
            if (alphaGen == 3) {
                float4 ap = drawUniforms.alphaWaveParams;
                va *= clamp(evalWave(drawUniforms.alphaWaveFunc, ap.x, ap.y, ap.z, ap.w, drawUniforms.timeSeconds), 0.0, 1.0);
            }
            // Overbright handling for the three render paths:
            //   stageUsesLightmap=1   → THIS draw is the lightmap stage. Stock Q3
            //                           writes the lightmap × 2 to the framebuffer
            //                           so the next FILTER stage's `dst=src*dst`
            //                           multiplies texture by the boosted lightmap.
            //                           Without the 2× here, multi-pass shaders
            //                           render at half brightness.
            //   drawHasLightmapStage  → THIS draw is a diffuse stage in a multi-
            //                           pass shader; lightmap was already written
            //                           (boosted) by an earlier pass. Just output
            //                           texel × vc and let the FILTER blend modulate.
            //   neither               → single-pass shader; sample the lightmap
            //                           binding directly and apply the 2× boost
            //                           inline (existing behavior).
            float3 lm;
            if (drawUniforms.stageUsesLightmap > 0.5) {
                lm = float3(2.0);
            } else if (drawUniforms.drawHasLightmapStage > 0.5 ||
                       rgbGen == 1 ||
                       rgbGen == 7 ||
                       additiveStage) {
                lm = float3(1.0);
            } else {
                lm = saturate(lightmap.rgb * 2.0);
            }
            float3 lit = texel.rgb * lm * vc;
            // Dynamic lights (muzzle flashes, rocket/plasma glow, lightning
            // halos). Applied BEFORE fog so distant explosions still fog
            // correctly. For filter/multiply stages the blend is source*dest
            // so contribution flips meaning, but the visual impact is small
            // and the per-draw blendMode isn't currently in WorldDrawUniforms.
            if (!additiveStage) {
                lit = applyDlights(lit, in.worldPos, dlights);
            }
            if (drawUniforms.fogColorDistance.w > 0.0) {
                float f = q3FogFactor(in.worldPos, uniforms, drawUniforms);
                if (additiveStage) {
                    lit *= (1.0 - f);
                } else {
                    lit = mix(lit, drawUniforms.fogColorDistance.xyz, f);
                }
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
            out.normal = inVertex.normal;
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
             * Scope: scroll (type=1) and rotate (type=3) only — rotate
             * param.x is packed as `-degs * π/180` so applyTcMod's
             * cos/sin treat it as radians/sec with CW sign. */
            int entityModCount = uniforms.tcModCount;
            if (entityModCount > 0) texCoord = applyTcMod(texCoord, in.worldPos, int(uniforms.tcModType.x + 0.5), uniforms.tcModParams0, uniforms.timeSeconds);
            if (entityModCount > 1) texCoord = applyTcMod(texCoord, in.worldPos, int(uniforms.tcModType.y + 0.5), uniforms.tcModParams1, uniforms.timeSeconds);
            if (entityModCount > 2) texCoord = applyTcMod(texCoord, in.worldPos, int(uniforms.tcModType.z + 0.5), uniforms.tcModParams2, uniforms.timeSeconds);
            if (entityModCount > 3) texCoord = applyTcMod(texCoord, in.worldPos, int(uniforms.tcModType.w + 0.5), uniforms.tcModParams3, uniforms.timeSeconds);
            float4 texel = colorTexture.sample(textureSampler, texCoord);
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
            }
            /* rgbGen: identity (0) — ignore the per-vertex Lambert,
             * render at full brightness. Matches upstream CGEN_IDENTITY
             * which sets colors to 0xff. Other modes fall through to
             * the existing `texel * in.color` multiply (Lambert baked
             * into vertex color C-side). Alpha follows vertex color in
             * both cases so additive/alpha blends stay intact. */
            /* rgbGen selection:
             *   0 (identity) = texel.rgb (full-bright)
             *   3 (wave)     = texel.rgb * clamp(base + sin(2π*(phase +
             *                  t*freq)) * amp, 0, 1) — matches
             *                  RB_CalcWaveColor (GF_SIN scope)
             *   default      = texel.rgb * in.color.rgb (Lambert) */
            float3 baseRgb;
            if (uniforms.rgbGenMode == 0u) {
                baseRgb = texel.rgb;
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
                base.rgb = applyDlights(base.rgb, in.worldPos, dlights);
            }
            if (uniforms.fogColorDistance.w > 0.0) {
                float f = q3EntityFogFactor(in.worldPos, uniforms);
                base.rgb = mix(base.rgb, uniforms.fogColorDistance.xyz, f);
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
        """

        private var commandQueue: MTLCommandQueue?
        private var uiPipelineState: MTLRenderPipelineState?
        private var uiOpaquePipelineState: MTLRenderPipelineState?
        /* Full-intensity additive (GL_ONE/GL_ONE) — blendMode=5. */
        private var uiAdditivePipelineState: MTLRenderPipelineState?
        private var uiAdditiveFullPipelineState: MTLRenderPipelineState? { uiAdditivePipelineState }
        /* Alpha-modulated additive (GL_SRC_ALPHA/GL_ONE) — blendMode=1. */
        private var uiAdditiveAlphaPipelineState: MTLRenderPipelineState?
        private var uiFilterPipelineState: MTLRenderPipelineState?
        private var worldPipelineState: MTLRenderPipelineState?
        private var worldFilterPipelineState: MTLRenderPipelineState?
        private var worldAlphaPipelineState: MTLRenderPipelineState?
        /* Alpha-modulated additive (GL_SRC_ALPHA/GL_ONE) — blendMode=1. */
        private var worldAdditivePipelineState: MTLRenderPipelineState?
        /* Full-intensity additive (GL_ONE/GL_ONE) — blendMode=5. NEVER
         * shared with worldAdditivePipelineState per strict blend-split. */
        private var worldAdditiveFullPipelineState: MTLRenderPipelineState?
        private var skyPipelineState: MTLRenderPipelineState?
        /* Full-intensity additive sky stage (GL_ONE/GL_ONE) — blendMode=5. */
        private var skyAdditivePipelineState: MTLRenderPipelineState?
        private var skyAdditiveFullPipelineState: MTLRenderPipelineState? { skyAdditivePipelineState }
        /* Alpha-modulated additive sky stage (GL_SRC_ALPHA/GL_ONE) — blendMode=1. */
        private var skyAdditiveAlphaPipelineState: MTLRenderPipelineState?
        private var skyDepthStencilState: MTLDepthStencilState?
        private var entityPipelineState: MTLRenderPipelineState?
        private var entityFilterPipelineState: MTLRenderPipelineState?
        private var entityAlphaPipelineState: MTLRenderPipelineState?
        private var entitySubtractPipelineState: MTLRenderPipelineState?
        private var entityAdditivePipelineState: MTLRenderPipelineState?
        /* Full-intensity additive (GL_ONE/GL_ONE) — distinct from
         * entityAdditivePipelineState (GL_SRC_ALPHA/GL_ONE) per strict
         * blend-split rule. */
        private var entityAdditiveFullPipelineState: MTLRenderPipelineState?
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
        private var fogEqualDepthStencilState: MTLDepthStencilState?
        private var additiveLessDepthStencilState: MTLDepthStencilState?
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
            // Persistent drawable lock to engine's logical render
            // resolution so the AVI muxer captures pixels at the
            // declared r_customwidth/r_customheight. SwiftUI's natural layout produces
            // ~592×720 on iPad which is wrong aspect (5:6 vs 4:3) and
            // invalidates every Vulkan parity diff. Re-apply on every
            // resize event — when we set view.drawableSize=target, the
            // delegate fires again with size==target and the early
            // return below handles it (no recursion).
            let isPad = (UIDevice.current.userInterfaceIdiom == .pad)
            let profile = ProcessInfo.processInfo.environment["Q3_MATCH_PROFILE"]
            let target: CGSize
            if profile == "native_ipad_25" {
                let nativeSize = UIScreen.main.nativeBounds.size
                target = CGSize(width: max(nativeSize.width, nativeSize.height),
                                height: min(nativeSize.width, nativeSize.height))
            } else {
                target = CGSize(width: isPad ? 1280 : 960,
                                height: isPad ? 960 : 444)
            }
            print("[Metal] Drawable size: \(size) (target \(target))")
            if size.width.isFinite && size.height.isFinite
                && size.width > 0 && size.height > 0
                && (Int(size.width) != Int(target.width) ||
                    Int(size.height) != Int(target.height)) {
                view.drawableSize = target
                print("[Metal] Drawable forced to \(target) (was \(size))")
                Q3MetalRenderer_UpdateDrawableSize(Int32(target.width), Int32(target.height))
                return
            }
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
            /* Explicit read-modify-write guarantees for GL_DST_COLOR/GL_ZERO
             * (filter) and GL_ZERO/GL_ONE_MINUS_SRC_COLOR (subtract) decals:
             *
             *   - loadAction = .load   → preserves the attachment's current
             *     contents at encoder begin so destinationColor is well-
             *     defined for the first blend. The world pass (emitted
             *     immediately after encoder creation) overwrites every
             *     visible pixel before any filter/subtract decal draws, so
             *     there is no visual difference vs .clear for normal frames;
             *     using .load is the stricter contract required by the
             *     GL_DST_COLOR/GL_ZERO read-modify-write spec.
             *
             *   - storeAction = .store → preserve final pixels for present.
             *     Never .dontCare, never a resolve-only path.
             *
             * Scene polys (bullet marks, shadow blobs, blood decals) render
             * in the SAME render encoder as the world + entities, so
             * destinationColor continuity holds across all draws. No blit,
             * no resolve, no intermediate texture between world and decals. */
            descriptor.colorAttachments[0].loadAction = .load
            descriptor.colorAttachments[0].storeAction = .store

            /* Sanity: the drawable texture MUST NOT be memoryless — filter
             * blending needs a real framebuffer to sample destinationColor
             * from. MTKView with framebufferOnly=false (set in
             * configureRenderer) guarantees .private storage, not
             * .memoryless. Log once if this invariant is ever violated. */
            if let drawableTexture = descriptor.colorAttachments[0].texture,
               drawableTexture.storageMode == .memoryless {
                print("[Metal] FATAL: drawable is memoryless — destinationColor will be undefined. Filter/subtract blends will not work.")
            }

            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
                return
            }

            // FORCE VIEWPORT MATCH — temporary troubleshooting patch
            encoder.setViewport(MTLViewport(
                originX: 0,
                originY: 0,
                width: Double(view.drawableSize.width),
                height: Double(view.drawableSize.height),
                znear: 0.0,
                zfar: 1.0
            ))

            if snapshot.worldCommandCount > 0,
               let worldPipelineState,
               let sceneView = Q3MetalRenderer_GetSceneView()?.pointee,
               let worldVertexBuffer = uploadWorldBuffers(device: view.device, generation: snapshot.worldGeneration),
               let worldIndexBuffer {
                let viewProjection = makeWorldViewProjection(sceneView)
                let cameraPos = SIMD3<Float>(sceneView.viewOrigin.0, sceneView.viewOrigin.1, sceneView.viewOrigin.2)
                /* sceneView.viewAxis is a row-major 3x3 in Q3 axis
                 * convention: axis[0]=forward, axis[1]=left,
                 * axis[2]=up. For a screen-right billboard basis we
                 * negate axis[1] to get camera-right. */
                let camRight = SIMD3<Float>(
                    -sceneView.viewAxis.3,
                    -sceneView.viewAxis.4,
                    -sceneView.viewAxis.5)
                let camUp = SIMD3<Float>(
                    sceneView.viewAxis.6,
                    sceneView.viewAxis.7,
                    sceneView.viewAxis.8)
                var worldUniforms = WorldUniforms(
                    viewProjection: viewProjection,
                    cameraPos: cameraPos,
                    cameraRight: camRight,
                    cameraUp: camUp)
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
                    let timeSeconds = snapshot.shaderTime

                    let skyFlagBit = UInt32(Q3_METAL_WORLD_DRAWFLAG_SKY)
                    let fogOverlayBit = UInt32(Q3_METAL_WORLD_DRAWFLAG_FOG_OVERLAY)
                    let fogOnlyBit = UInt32(Q3_METAL_WORLD_DRAWFLAG_FOG_ONLY)

                    // Ordered world passes:
                    // 0 = opaque, 1 = filter, 2 = alpha,
                    // 3 = additive (GL_SRC_ALPHA/GL_ONE — alpha-modulated),
                    // 4 = additive-full (GL_ONE/GL_ONE — explosion/glow cores),
                    // 5 = fog overlay pass (post-stage alpha fog).
                    // Sky draws are handled in pass 0 through the sky pipeline
                    // (view-direction spherical projection, no lightmap).
                    for worldPass in 0..<6 {
                    for draw in worldDraws where draw.indexCount > 0 {
                        let isSky = (draw.flags & skyFlagBit) != 0
                        if (draw.flags & fogOnlyBit) != 0 && worldPass != 5 {
                            continue
                        }
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
                                /* Strict blend split — NEVER merge 1 and 5. */
                                let skyBlend = Int(stage.blendMode)
                                let isAdditiveAlpha = skyBlend == 1
                                let isAdditiveFull  = skyBlend == 5
                                let pipeline: MTLRenderPipelineState
                                if isAdditiveFull, let p = skyAdditiveFullPipelineState {
                                    pipeline = p
                                } else if isAdditiveAlpha, let p = skyAdditiveAlphaPipelineState {
                                    pipeline = p
                                } else {
                                    pipeline = skyPipelineState
                                }
                                encoder.setRenderPipelineState(pipeline)
                                encoder.setDepthStencilState(skyDepthStencilState)
                                // Sky shaders commonly specify 'cull disable'
                                // to render the sky sphere inside-out; honour
                                // per-stage cullMode just like world stages.
                                encoder.setCullMode(Self.metalCullMode(for: stage.cullMode))
                                let skyChain = Self.fillTcMods(stage)
                                let (skyTV0, skyTV1) = Self.tcGenVectors(stage)
                                // Sky never receives fog — fogColorDistance=0.
                                var skyDrawUniforms = WorldDrawUniforms(
                                    tcGen: Float(stage.tcGen),
                                    tcModCount: skyChain.count,
                                    rgbGen: Float(stage.rgbGen),
                                    alphaGen: Float(stage.alphaGen),
                                    blendMode: Float(stage.blendMode),
                                    timeSeconds: timeSeconds,
                                    rgbWaveFunc: stage.rgbWaveFunc,
                                    alphaWaveFunc: stage.alphaWaveFunc,
                                    tcModType: skyChain.types,
                                    tcModParams0: skyChain.p0,
                                    tcModParams1: skyChain.p1,
                                    tcModParams2: skyChain.p2,
                                    tcModParams3: skyChain.p3,
                                    rgbWaveParams: SIMD4(stage.rgbWaveBase, stage.rgbWaveAmp, stage.rgbWavePhase, stage.rgbWaveFreq),
                                    alphaWaveParams: SIMD4(stage.alphaWaveBase, stage.alphaWaveAmp, stage.alphaWavePhase, stage.alphaWaveFreq),
                                    fogColorDistance: SIMD4<Float>(0, 0, 0, 0),
                                    tcGenVec0: skyTV0,
                                    tcGenVec1: skyTV1,
                                    deformMoveFunc: stage.deformMoveFunc,
                                    deformMoveVector: SIMD3(stage.deformMoveVector.0,
                                                            stage.deformMoveVector.1,
                                                            stage.deformMoveVector.2),
                                    deformMoveBase: stage.deformMoveBase,
                                    deformMoveAmp: stage.deformMoveAmp,
                                    deformMovePhase: stage.deformMovePhase,
                                    deformMoveFreq: stage.deformMoveFreq,
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
                        let lightmapMultiplyBit = UInt32(Q3_METAL_WORLD_DRAWFLAG_LIGHTMAP_MULTIPLY)
                        let drawHasLightmapStage = (draw.flags & lightmapMultiplyBit) != 0 ||
                            (0..<stageCount).contains { Self.worldStage(draw, $0).useLightmap != 0 }
                        let noFog = UInt32(Q3_METAL_NO_FOG)
                        var fogCD = SIMD4<Float>(0, 0, 0, 0)
                        var fogParams = SIMD4<Float>(0, 0, 0, 0)
                        var fogSurface = SIMD4<Float>(0, 0, 0, 0)
                        if draw.fogIndex != noFog {
                            let count = Q3MetalRenderer_GetWorldFogCount()
                            if Int(draw.fogIndex) < count,
                               let fogs = Q3MetalRenderer_GetWorldFogs() {
                                let f = fogs.advanced(by: Int(draw.fogIndex)).pointee
                                fogCD = SIMD4(f.color.0, f.color.1, f.color.2, f.distance)
                                fogParams = SIMD4(f.tcScale, f.hasSurface != 0 ? 1.0 : 0.0, 0, 0)
                                fogSurface = SIMD4(f.surface.0, f.surface.1, f.surface.2, f.surface.3)
                            }
                        }
                        if worldPass == 5 {
                            guard fogCD.w > 0,
                                  (draw.flags & fogOverlayBit) != 0,
                                  let worldAlphaPipelineState else { continue }
                            let stage = Self.worldStage(draw, 0)
                            let chain = Self.fillTcMods(stage)
                            let (tv0, tv1) = Self.tcGenVectors(stage)
                            var fogUniforms = WorldDrawUniforms(
                                tcGen: Float(stage.tcGen),
                                tcModCount: chain.count,
                                rgbGen: 0,
                                alphaGen: 0,
                                blendMode: 2,
                                timeSeconds: timeSeconds,
                                rgbWaveFunc: 0,
                                alphaWaveFunc: 0,
                                tcModType: chain.types,
                                tcModParams0: chain.p0,
                                tcModParams1: chain.p1,
                                tcModParams2: chain.p2,
                                tcModParams3: chain.p3,
                                fogColorDistance: fogCD,
                                fogParams: fogParams,
                                fogSurface: fogSurface,
                                tcGenVec0: tv0,
                                tcGenVec1: tv1,
                                deformWaveFunc: stage.deformWaveFunc,
                                deformWaveDiv: stage.deformWaveDiv != 0
                                    ? stage.deformWaveDiv : 1.0,
                                deformWaveBase: stage.deformWaveBase,
                                deformWaveAmp: stage.deformWaveAmp,
                                deformWavePhase: stage.deformWavePhase,
                                deformWaveFreq: stage.deformWaveFreq,
                                deformMoveFunc: stage.deformMoveFunc,
                                deformMoveVector: SIMD3(stage.deformMoveVector.0,
                                                        stage.deformMoveVector.1,
                                                        stage.deformMoveVector.2),
                                deformMoveBase: stage.deformMoveBase,
                                deformMoveAmp: stage.deformMoveAmp,
                                deformMovePhase: stage.deformMovePhase,
                                deformMoveFreq: stage.deformMoveFreq,
                                autospriteMode: stage.autospriteMode,
                                debugMode: 0,
                                forceWhiteVertColor: 0,
                                alphaTestThreshold: 0,
                                fogOnly: 1,
                                stageUsesLightmap: 0,
                                drawHasLightmapStage: 0,
                                _pad0: 0
                            )
                            encoder.setRenderPipelineState(worldAlphaPipelineState)
                            let fogDepthState = (draw.flags & fogOnlyBit) != 0
                                ? additiveDepthStencilState
                                : fogEqualDepthStencilState
                            encoder.setDepthStencilState(ensuredDepthStencilState(fogDepthState, device: view.device))
                            encoder.setCullMode(Self.metalCullMode(for: stage.cullMode))
                            encoder.setFragmentTexture(lightmapTexture, index: 0)
                            encoder.setFragmentTexture(lightmapTexture, index: 1)
                            encoder.setFragmentBytes(&fogUniforms, length: MemoryLayout<WorldDrawUniforms>.stride, index: 0)
                            encoder.setVertexBytes(&fogUniforms, length: MemoryLayout<WorldDrawUniforms>.stride, index: 2)
                            encoder.drawIndexedPrimitives(
                                type: .triangle,
                                indexCount: Int(draw.indexCount),
                                indexType: .uint32,
                                indexBuffer: worldIndexBuffer,
                                indexBufferOffset: Int(draw.firstIndex) * MemoryLayout<UInt32>.stride
                            )
                            continue
                        }
                        for stageIndex in 0..<stageCount {
                            let stage = Self.worldStage(draw, stageIndex)
                            let blendMode = Int(stage.blendMode)
                            let drawPass = (blendMode == 5) ? 4
                                         : (blendMode == 1) ? 3
                                         : (blendMode == 2) ? 2
                                         : (blendMode == 3) ? 1
                                         : 0
                            guard drawPass == worldPass else { continue }
                            guard let baseTexture = texture(for: stage.textureHandle, device: view.device) else {
                                continue
                            }
                            // Per-stage depth-write override. Q3 shaders
                            // can carry an explicit `depthwrite` keyword
                            // even on a blended stage (e.g. q3dm6's
                            // blocks17gwater), which ioq3 maps to
                            // GLS_DEPTHMASK_TRUE. Without honoring this
                            // bit, blended water/grate floors that author
                            // depthwrite to occlude correctly leak the
                            // chamber below through the surface.
                            // Pick the depth-write-ON state for blended
                            // stages with depthWrite=1; depth-read-only
                            // (additiveDepthStencilState) otherwise.
                            let blendedDepthState = stage.depthWrite != 0
                                ? depthStencilState
                                : additiveDepthStencilState
                            if drawPass == 4, let worldAdditiveFullPipelineState {
                                /* GL_ONE/GL_ONE — distinct pipeline from
                                 * alpha-modulated additive. */
                                encoder.setRenderPipelineState(worldAdditiveFullPipelineState)
                                encoder.setDepthStencilState(ensuredDepthStencilState(additiveDepthStencilState, device: view.device))
                            } else if drawPass == 3, let worldAdditivePipelineState {
                                encoder.setRenderPipelineState(worldAdditivePipelineState)
                                encoder.setDepthStencilState(ensuredDepthStencilState(additiveDepthStencilState, device: view.device))
                            } else if drawPass == 2, let worldAlphaPipelineState {
                                encoder.setRenderPipelineState(worldAlphaPipelineState)
                                encoder.setDepthStencilState(ensuredDepthStencilState(blendedDepthState, device: view.device))
                            } else if drawPass == 1, let worldFilterPipelineState {
                                encoder.setRenderPipelineState(worldFilterPipelineState)
                                encoder.setDepthStencilState(ensuredDepthStencilState(blendedDepthState, device: view.device))
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
                            let (tv0, tv1) = Self.tcGenVectors(stage)
                            let forceWhiteVertex = (blendMode == 1 &&
                                                    stage.rgbGen == 0 &&
                                                    stage.alphaGen == 0)
                                ? Float(1.0)
                                : Float(0.0)
                            var drawUniforms = WorldDrawUniforms(
                                tcGen: Float(stage.tcGen),
                                tcModCount: chain.count,
                                rgbGen: Float(stage.rgbGen),
                                alphaGen: Float(stage.alphaGen),
                                blendMode: Float(stage.blendMode),
                                timeSeconds: timeSeconds,
                                rgbWaveFunc: stage.rgbWaveFunc,
                                alphaWaveFunc: stage.alphaWaveFunc,
                                tcModType: chain.types,
                                tcModParams0: chain.p0,
                                tcModParams1: chain.p1,
                                tcModParams2: chain.p2,
                                tcModParams3: chain.p3,
                                rgbWaveParams: SIMD4(stage.rgbWaveBase, stage.rgbWaveAmp, stage.rgbWavePhase, stage.rgbWaveFreq),
                                alphaWaveParams: SIMD4(stage.alphaWaveBase, stage.alphaWaveAmp, stage.alphaWavePhase, stage.alphaWaveFreq),
                                fogColorDistance: fogCD,
                                fogParams: fogParams,
                                fogSurface: fogSurface,
                                tcGenVec0: tv0,
                                tcGenVec1: tv1,
                                deformWaveFunc: stage.deformWaveFunc,
                                deformWaveDiv: stage.deformWaveDiv != 0
                                    ? stage.deformWaveDiv : 1.0,
                                deformWaveBase: stage.deformWaveBase,
                                deformWaveAmp: stage.deformWaveAmp,
                                deformWavePhase: stage.deformWavePhase,
                                deformWaveFreq: stage.deformWaveFreq,
                                deformMoveFunc: stage.deformMoveFunc,
                                deformMoveVector: SIMD3(stage.deformMoveVector.0,
                                                        stage.deformMoveVector.1,
                                                        stage.deformMoveVector.2),
                                deformMoveBase: stage.deformMoveBase,
                                deformMoveAmp: stage.deformMoveAmp,
                                deformMovePhase: stage.deformMovePhase,
                                deformMoveFreq: stage.deformMoveFreq,
                                autospriteMode: stage.autospriteMode,
                                debugMode: Coordinator.worldDebugMode,
                                forceWhiteVertColor: forceWhiteVertex,
                                alphaTestThreshold: alphaTest,
                                fogOnly: 0,
                                stageUsesLightmap: stage.useLightmap != 0 ? 1.0 : 0.0,
                                drawHasLightmapStage: drawHasLightmapStage ? 1.0 : 0.0,
                                _pad0: 0.0
                            )
                            encoder.setFragmentTexture(baseTexture, index: 0)
                            encoder.setFragmentTexture(lightmapTexture, index: 1)
                            encoder.setFragmentBytes(&drawUniforms, length: MemoryLayout<WorldDrawUniforms>.stride, index: 0)
                            // Vertex shader reads deformWave + timeSeconds
                            // from WorldDrawUniforms. Bound at vertex
                            // buffer index 2 (0 = vertex buffer,
                            // 1 = WorldUniforms).
                            encoder.setVertexBytes(&drawUniforms, length: MemoryLayout<WorldDrawUniforms>.stride, index: 2)
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
                let cameraForward = SIMD3<Float>(sceneView.viewAxis.0, sceneView.viewAxis.1, sceneView.viewAxis.2)
                let entityTimeSeconds = Float(CACurrentMediaTime() - frameTimeOrigin)
                var entityUniforms = EntityUniforms(viewProjection: entityViewProjection, cameraPos: cameraPos, tcGen: 0, timeSeconds: entityTimeSeconds)
                entityUniforms.cameraForward = cameraForward
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
                    let additiveFullBit = UInt32(Q3_METAL_ENTITY_DRAWFLAG_ADDITIVE_FULL)
                    let alphaBit = UInt32(Q3_METAL_ENTITY_DRAWFLAG_ALPHA)
                    let filterBit = UInt32(Q3_METAL_ENTITY_DRAWFLAG_FILTER)
                    let subtractBit = UInt32(Q3_METAL_ENTITY_DRAWFLAG_SUBTRACT)
                    let tcGenEnvBit = UInt32(Q3_METAL_ENTITY_DRAWFLAG_TCGEN_ENV)
                    let scenePolyBit = UInt32(Q3_METAL_ENTITY_DRAWFLAG_SCENE_POLY)
                    let aTestGT0Bit = UInt32(Q3_METAL_ENTITY_DRAWFLAG_ATEST_GT0)

                    // Ordered entity passes:
                    // 0 = opaque, 1 = filter, 2 = alpha,
                    // 3 = additive (GL_SRC_ALPHA/GL_ONE — alpha-modulated),
                    // 4 = subtract (blood/bullet/shadow decals),
                    // 5 = additive-full (GL_ONE/GL_ONE — explosion cores).
                    for entityPass in 0..<6 {
                    for draw in entityDraws where draw.indexCount > 0 {
                        let isEntityAdditive = (draw.flags & additiveBit) != 0
                        let isEntityAdditiveFull = (draw.flags & additiveFullBit) != 0
                        let isEntityAlpha = (draw.flags & alphaBit) != 0
                        let isEntityFilter = (draw.flags & filterBit) != 0
                        let isEntitySubtract = (draw.flags & subtractBit) != 0
                        let drawPass = isEntityAdditiveFull ? 5
                                     : isEntitySubtract ? 4
                                     : isEntityAdditive ? 3
                                     : isEntityAlpha ? 2
                                     : isEntityFilter ? 1
                                     : 0
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
                        Self.packEntityTcMods(handle: draw.textureHandle, into: &entityUniforms)
                        Self.packEntityAlphaFunc(handle: draw.textureHandle, into: &entityUniforms)
                        Self.packEntityRgbGen(handle: draw.textureHandle, into: &entityUniforms)
                        /* Per-draw refEntity_t.shaderRGBA fed through to MSL
                         * for rgbGen=entity / oneMinusEntity (5/6) and
                         * alphaGen=entity / oneMinusEntity (5/6). */
                        let ec = draw.entityColor
                        entityUniforms.entityColor = SIMD4<Float>(ec.0, ec.1, ec.2, ec.3)
                        entityUniforms.timeSeconds = draw.shaderTime
                        entityUniforms.suppressDlights = (drawPass == 5) ? 1 : 0
                        /* Per TASK PART 3: no rgbGen/alphaGen override for
                         * scene polys — the shader's resolved genMode
                         * flows through verbatim from packEntityRgbGen. */
                        let isScenePoly = (draw.flags & scenePolyBit) != 0
                        entityUniforms.fogColorDistance = SIMD4<Float>(0, 0, 0, 0)
                        entityUniforms.fogParams = SIMD4<Float>(0, 0, 0, 0)
                        entityUniforms.fogSurface = SIMD4<Float>(0, 0, 0, 0)
                        if draw.fogIndex != UInt32(Q3_METAL_NO_FOG) {
                            let count = Q3MetalRenderer_GetWorldFogCount()
                            if Int(draw.fogIndex) < count,
                               let fogs = Q3MetalRenderer_GetWorldFogs() {
                                let f = fogs.advanced(by: Int(draw.fogIndex)).pointee
                                entityUniforms.fogColorDistance = SIMD4(f.color.0, f.color.1, f.color.2, f.distance)
                                entityUniforms.fogParams = SIMD4(f.tcScale, f.hasSurface != 0 ? 1.0 : 0.0, 0, 0)
                                entityUniforms.fogSurface = SIMD4(f.surface.0, f.surface.1, f.surface.2, f.surface.3)
                            }
                        }
                        /* Implicit alphaFunc GT0 for sprite billboards whose
                         * additive shader didn't declare alphaFunc. Matches
                         * upstream Q3 intent: dark / transparent regions of
                         * rlboom/plasma/flash JPEGs must not contribute to
                         * GL_ONE/GL_ONE blending. Threshold 0.004 (GT0). */
                        if (draw.flags & aTestGT0Bit) != 0,
                           entityUniforms.alphaTestThreshold == 0 {
                            entityUniforms.alphaTestThreshold = 0.004
                        }
                        encoder.setFragmentBytes(&entityUniforms, length: MemoryLayout<EntityUniforms>.stride, index: 1)
                        if drawPass == 5, let entityAdditiveFullPipelineState {
                            /* GL_ONE/GL_ONE — NEVER shared with the alpha-
                             * modulated additive pipeline per strict spec. */
                            encoder.setRenderPipelineState(entityAdditiveFullPipelineState)
                            encoder.setDepthStencilState(ensuredDepthStencilState(additiveLessDepthStencilState, device: view.device))
                        } else if drawPass == 4, let entitySubtractPipelineState {
                            encoder.setRenderPipelineState(entitySubtractPipelineState)
                            encoder.setDepthStencilState(ensuredDepthStencilState(additiveEntityDepthStencilState, device: view.device))
                        } else if drawPass == 3, let entityAdditivePipelineState {
                            encoder.setRenderPipelineState(entityAdditivePipelineState)
                            encoder.setDepthStencilState(ensuredDepthStencilState(additiveLessDepthStencilState, device: view.device))
                        } else if drawPass == 2, let entityAlphaPipelineState {
                            encoder.setRenderPipelineState(entityAlphaPipelineState)
                            encoder.setDepthStencilState(ensuredDepthStencilState(additiveEntityDepthStencilState, device: view.device))
                        } else if drawPass == 1, let entityFilterPipelineState {
                            encoder.setRenderPipelineState(entityFilterPipelineState)
                            encoder.setDepthStencilState(ensuredDepthStencilState(additiveEntityDepthStencilState, device: view.device))
                        } else {
                            encoder.setRenderPipelineState(entityPipelineState)
                            /* Scene polys never write depth regardless of
                             * pass — emulates upstream Q3 decal
                             * `polygonOffset` behaviour so decals can't
                             * z-fight with the surface they sit on. */
                            let state = isScenePoly ? additiveEntityDepthStencilState
                                      : (wantsDepthHack ? depthHackDepthStencilState : depthStencilState)
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
                    for draw in drawCommands {
                        /* Per-draw pipeline bind — no cross-draw reuse.
                         * Pipelines themselves are cached by (srcFactor,
                         * dstFactor) as distinct MTLRenderPipelineState
                         * objects built once in configureRenderer. The
                         * binding call below is always issued before the
                         * draw so a GL_ONE/GL_ONE additive state cannot
                         * leak into a subsequent GL_DST_COLOR/GL_ZERO
                         * filter draw. */
                        let pipeline: MTLRenderPipelineState? = {
                            switch draw.blendMode {
                            /* Strict blend split — blendMode 1 and 5 MUST
                             * use distinct pipelines. GL_ONE/GL_ONE must
                             * never route through a .sourceAlpha pipeline
                             * and GL_SRC_ALPHA/GL_ONE must never route
                             * through a .one/.one pipeline. */
                            case 1: return uiAdditiveAlphaPipelineState ?? uiPipelineState
                            case 5: return uiAdditiveFullPipelineState ?? uiPipelineState
                            case 3: return uiFilterPipelineState ?? uiPipelineState
                            default: return uiPipelineState
                            }
                        }()
                        if let pipeline {
                            encoder.setRenderPipelineState(pipeline)
                        }
                        if let texture = texture(for: draw.textureHandle, device: view.device) {
                            encoder.setFragmentTexture(texture, index: 0)
                            encoder.drawPrimitives(type: .triangle, vertexStart: Int(draw.firstVertex), vertexCount: Int(draw.vertexCount))
                        }
                    }
                }
            }

            encoder.endEncoding()
            // Cache drawable.texture BEFORE present(). Reading
            // drawable.texture after commandBuffer.present(drawable)
            // logs "[CAMetalLayerDrawable texture] should not be called
            // after already presenting this drawable." The MTLTexture
            // reference itself stays valid post-present — only the
            // drawable.texture accessor complains.
            let tex = drawable.texture
            commandBuffer.present(drawable)
            commandBuffer.commit()

            // Video capture: when the engine is recording an AVI, read
            // the just-rendered drawable back to CPU and stash the BGRA
            // bytes in a shared buffer. The engine's per-frame
            // CL_TakeVideoFrame → RE_TakeVideoFrame hook (in
            // metal_renderer_stub.c) pulls from that buffer and converts
            // to the packed RGB layout the AVI muxer expects. Gated by
            // CL_VideoRecording() so idle runs incur no readback cost.
            if CL_VideoRecording() != 0 {
                commandBuffer.waitUntilCompleted()
                let w = tex.width
                let h = tex.height
                let bytesPerRow = w * 4
                let byteCount = bytesPerRow * h
                if videoReadbackBuffer == nil || videoReadbackBuffer!.count < byteCount {
                    videoReadbackBuffer = [UInt8](repeating: 0, count: byteCount)
                }
                videoReadbackBuffer!.withUnsafeMutableBufferPointer { ptr in
                    tex.getBytes(ptr.baseAddress!,
                                 bytesPerRow: bytesPerRow,
                                 from: MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0),
                                                 size: MTLSize(width: w, height: h, depth: 1)),
                                 mipmapLevel: 0)
                    Q3MetalRenderer_StoreVideoFrame(ptr.baseAddress, Int32(w), Int32(h))
                }
            }
        }
        /* Reusable BGRA readback buffer sized on first recorded frame. */
        private var videoReadbackBuffer: [UInt8]?

        @MainActor
        private func configureRenderer(for view: MTKView) {
            guard let device = view.device else { return }

            // LOCK RESOLUTION (Quake reference) — temporary troubleshooting
            // patch. MUST live here (one-shot setup) rather than inside
            // drawableSizeWillChange, because assigning drawableSize from
            // within the delegate recursively triggers the delegate again
            // and blows the stack.
            view.autoResizeDrawable = false
            view.contentScaleFactor = 1.0
            if ProcessInfo.processInfo.environment["Q3_MATCH_PROFILE"] == "native_ipad_25" {
                let nativeSize = UIScreen.main.nativeBounds.size
                view.drawableSize = CGSize(width: max(nativeSize.width, nativeSize.height),
                                           height: min(nativeSize.width, nativeSize.height))
            } else {
                view.drawableSize = CGSize(width: 960, height: 444)
            }
            // Allow CPU readback of the drawable texture for the `video`
            // command capture path (RE_TakeVideoFrame). MTKView defaults
            // to framebufferOnly = true which blocks getBytes().
            view.framebufferOnly = false

            commandQueue = device.makeCommandQueue()

            let library: MTLLibrary
            do {
                library = try device.makeLibrary(source: shaderSource, options: nil)
            } catch {
                print("[Metal] Failed to compile shaders: \(error)")
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

            /* UI alpha-modulated additive (GL_SRC_ALPHA/GL_ONE) — blendMode=1.
             * Strictly distinct from the full-additive pipeline above per
             * blend-split rule: GL_ONE/GL_ONE MUST NEVER use a pipeline
             * with sourceAlpha, and GL_SRC_ALPHA/GL_ONE MUST NEVER use
             * one/one. */
            let uiAdditiveAlphaDesc = MTLRenderPipelineDescriptor()
            uiAdditiveAlphaDesc.colorAttachments[0].pixelFormat = view.colorPixelFormat
            uiAdditiveAlphaDesc.depthAttachmentPixelFormat = view.depthStencilPixelFormat
            uiAdditiveAlphaDesc.vertexFunction = library.makeFunction(name: "q3_ui_vertex")
            uiAdditiveAlphaDesc.fragmentFunction = library.makeFunction(name: "q3_ui_fragment")
            uiAdditiveAlphaDesc.colorAttachments[0].isBlendingEnabled = true
            uiAdditiveAlphaDesc.colorAttachments[0].writeMask = .all
            uiAdditiveAlphaDesc.colorAttachments[0].rgbBlendOperation = .add
            uiAdditiveAlphaDesc.colorAttachments[0].alphaBlendOperation = .add
            uiAdditiveAlphaDesc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            uiAdditiveAlphaDesc.colorAttachments[0].sourceAlphaBlendFactor = .one
            uiAdditiveAlphaDesc.colorAttachments[0].destinationRGBBlendFactor = .one
            uiAdditiveAlphaDesc.colorAttachments[0].destinationAlphaBlendFactor = .one
            do {
                uiAdditiveAlphaPipelineState = try device.makeRenderPipelineState(descriptor: uiAdditiveAlphaDesc)
            } catch {
                print("[Metal] Failed to create UI additive-alpha pipeline: \\(error)")
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

            /* Alpha-modulated additive (blendMode=1): GL_SRC_ALPHA/GL_ONE. */
            let worldAdditivePipelineDescriptor = worldPipelineDescriptor.copy() as! MTLRenderPipelineDescriptor
            worldAdditivePipelineDescriptor.colorAttachments[0].isBlendingEnabled = true
            worldAdditivePipelineDescriptor.colorAttachments[0].writeMask = .all
            worldAdditivePipelineDescriptor.colorAttachments[0].rgbBlendOperation = .add
            worldAdditivePipelineDescriptor.colorAttachments[0].alphaBlendOperation = .add
            worldAdditivePipelineDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            worldAdditivePipelineDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
            worldAdditivePipelineDescriptor.colorAttachments[0].destinationRGBBlendFactor = .one
            worldAdditivePipelineDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .one
            do {
                worldAdditivePipelineState = try device.makeRenderPipelineState(descriptor: worldAdditivePipelineDescriptor)
            } catch {
                print("[Metal] Failed to create additive world pipeline: \\(error)")
            }

            /* Full-intensity additive (blendMode=5): GL_ONE/GL_ONE. Distinct
             * pipeline from worldAdditivePipelineState per strict spec. */
            let worldAdditiveFullDescriptor = worldPipelineDescriptor.copy() as! MTLRenderPipelineDescriptor
            worldAdditiveFullDescriptor.colorAttachments[0].isBlendingEnabled = true
            worldAdditiveFullDescriptor.colorAttachments[0].writeMask = .all
            worldAdditiveFullDescriptor.colorAttachments[0].rgbBlendOperation = .add
            worldAdditiveFullDescriptor.colorAttachments[0].alphaBlendOperation = .add
            worldAdditiveFullDescriptor.colorAttachments[0].sourceRGBBlendFactor = .one
            worldAdditiveFullDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
            worldAdditiveFullDescriptor.colorAttachments[0].destinationRGBBlendFactor = .one
            worldAdditiveFullDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .one
            do {
                worldAdditiveFullPipelineState = try device.makeRenderPipelineState(descriptor: worldAdditiveFullDescriptor)
            } catch {
                print("[Metal] Failed to create additive-full world pipeline: \\(error)")
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

            /* Full-intensity additive sky stage (blendMode=5, GL_ONE/GL_ONE).
             * Stock Q3 cloud overlays (killsky_2 over killsky_1). */
            let skyAdditiveDescriptor = skyPipelineDescriptor.copy() as! MTLRenderPipelineDescriptor
            skyAdditiveDescriptor.colorAttachments[0].isBlendingEnabled = true
            skyAdditiveDescriptor.colorAttachments[0].writeMask = .all
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

            /* Alpha-modulated additive sky stage (blendMode=1, GL_SRC_ALPHA/GL_ONE).
             * Distinct pipeline — NEVER shared with skyAdditivePipelineState. */
            let skyAdditiveAlphaDesc = skyPipelineDescriptor.copy() as! MTLRenderPipelineDescriptor
            skyAdditiveAlphaDesc.colorAttachments[0].isBlendingEnabled = true
            skyAdditiveAlphaDesc.colorAttachments[0].writeMask = .all
            skyAdditiveAlphaDesc.colorAttachments[0].rgbBlendOperation = .add
            skyAdditiveAlphaDesc.colorAttachments[0].alphaBlendOperation = .add
            skyAdditiveAlphaDesc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            skyAdditiveAlphaDesc.colorAttachments[0].sourceAlphaBlendFactor = .one
            skyAdditiveAlphaDesc.colorAttachments[0].destinationRGBBlendFactor = .one
            skyAdditiveAlphaDesc.colorAttachments[0].destinationAlphaBlendFactor = .one
            do {
                skyAdditiveAlphaPipelineState = try device.makeRenderPipelineState(descriptor: skyAdditiveAlphaDesc)
            } catch {
                print("[Metal] Failed to create additive-alpha sky pipeline: \\(error)")
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

            /* Alpha-modulated additive (blendMode=1): GL_SRC_ALPHA/GL_ONE.
             * Particles, flame, muzzle-flash fringes. Source alpha
             * attenuates the added colour so transparent texels don't
             * brighten the framebuffer. */
            let entityAdditiveDesc = MTLRenderPipelineDescriptor()
            entityAdditiveDesc.colorAttachments[0].pixelFormat = view.colorPixelFormat
            entityAdditiveDesc.colorAttachments[0].isBlendingEnabled = true
            entityAdditiveDesc.colorAttachments[0].writeMask = .all
            entityAdditiveDesc.colorAttachments[0].rgbBlendOperation = .add
            entityAdditiveDesc.colorAttachments[0].alphaBlendOperation = .add
            entityAdditiveDesc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
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

            /* Full-intensity additive (blendMode=5): GL_ONE/GL_ONE.
             * Explosion cores, rail cores, high-energy effects. Source
             * alpha is IGNORED — whatever the fragment outputs is added
             * verbatim to the framebuffer. Kept strictly separate from
             * the alpha-modulated additive pipeline above per task spec:
             * "NO FALLBACK / NO MERGE / NO SHARING". */
            let entityAdditiveFullDesc = MTLRenderPipelineDescriptor()
            entityAdditiveFullDesc.colorAttachments[0].pixelFormat = view.colorPixelFormat
            entityAdditiveFullDesc.colorAttachments[0].isBlendingEnabled = true
            entityAdditiveFullDesc.colorAttachments[0].writeMask = .all
            entityAdditiveFullDesc.colorAttachments[0].rgbBlendOperation = .add
            entityAdditiveFullDesc.colorAttachments[0].alphaBlendOperation = .add
            entityAdditiveFullDesc.colorAttachments[0].sourceRGBBlendFactor = .one
            entityAdditiveFullDesc.colorAttachments[0].destinationRGBBlendFactor = .one
            entityAdditiveFullDesc.colorAttachments[0].sourceAlphaBlendFactor = .one
            entityAdditiveFullDesc.colorAttachments[0].destinationAlphaBlendFactor = .one
            entityAdditiveFullDesc.depthAttachmentPixelFormat = view.depthStencilPixelFormat
            entityAdditiveFullDesc.vertexFunction = library.makeFunction(name: "q3_entity_vertex")
            entityAdditiveFullDesc.fragmentFunction = library.makeFunction(name: "q3_entity_fragment")
            do {
                entityAdditiveFullPipelineState = try device.makeRenderPipelineState(descriptor: entityAdditiveFullDesc)
            } catch {
                print("[Metal] Failed to create additive-full entity pipeline: \\(error)")
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
            entityFilterDesc.colorAttachments[0].writeMask = .all
            entityFilterDesc.colorAttachments[0].rgbBlendOperation = .add
            entityFilterDesc.colorAttachments[0].alphaBlendOperation = .add
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

            // Subtract (GL_ZERO / GL_ONE_MINUS_SRC_COLOR) — out = dst * (1 - src).
            // Used by blood marks, bullet marks, burn marks, markShadow.
            // Dark-valued source bytes darken the destination without
            // replacing it. Without this pipeline, those decals were
            // falling through to additive which made them invisible
            // against lit stone/metal surfaces.
            let entitySubtractDesc = MTLRenderPipelineDescriptor()
            entitySubtractDesc.colorAttachments[0].pixelFormat = view.colorPixelFormat
            entitySubtractDesc.colorAttachments[0].isBlendingEnabled = true
            entitySubtractDesc.colorAttachments[0].writeMask = .all
            entitySubtractDesc.colorAttachments[0].rgbBlendOperation = .add
            entitySubtractDesc.colorAttachments[0].alphaBlendOperation = .add
            entitySubtractDesc.colorAttachments[0].sourceRGBBlendFactor = .zero
            entitySubtractDesc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceColor
            /* Alpha: write source alpha straight through (one/zero).
             * Previously used oneMinusSourceAlpha which is a
             * premultiplied-alpha idiom — inappropriate here. */
            entitySubtractDesc.colorAttachments[0].sourceAlphaBlendFactor = .one
            entitySubtractDesc.colorAttachments[0].destinationAlphaBlendFactor = .zero
            entitySubtractDesc.depthAttachmentPixelFormat = view.depthStencilPixelFormat
            entitySubtractDesc.vertexFunction = library.makeFunction(name: "q3_entity_vertex")
            entitySubtractDesc.fragmentFunction = library.makeFunction(name: "q3_entity_fragment")
            do {
                entitySubtractPipelineState = try device.makeRenderPipelineState(descriptor: entitySubtractDesc)
            } catch {
                print("[Metal] Failed to create subtract entity pipeline: \\(error)")
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

            let fogEqualDepthDescriptor = MTLDepthStencilDescriptor()
            fogEqualDepthDescriptor.isDepthWriteEnabled = false
            fogEqualDepthDescriptor.depthCompareFunction = .equal
            fogEqualDepthStencilState = device.makeDepthStencilState(descriptor: fogEqualDepthDescriptor)

            let additiveLessDepthDescriptor = MTLDepthStencilDescriptor()
            additiveLessDepthDescriptor.isDepthWriteEnabled = false
            additiveLessDepthDescriptor.depthCompareFunction = .less
            additiveLessDepthStencilState = device.makeDepthStencilState(descriptor: additiveLessDepthDescriptor)

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
                            normal: SIMD3<Float>(vertex.normal.0, vertex.normal.1, vertex.normal.2),
                            color: SIMD4<Float>(vertex.color.0, vertex.color.1, vertex.color.2, vertex.color.3),
                            autospriteCenter: SIMD4<Float>(
                                vertex.autospriteCenter.0,
                                vertex.autospriteCenter.1,
                                vertex.autospriteCenter.2,
                                vertex.autospriteCenter.3),
                            autospriteLongAxis: SIMD4<Float>(
                                vertex.autospriteLongAxis.0,
                                vertex.autospriteLongAxis.1,
                                vertex.autospriteLongAxis.2,
                                vertex.autospriteLongAxis.3)
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
                    color: SIMD4<Float>(vertex.color.0, vertex.color.1, vertex.color.2, vertex.color.3),
                    normal: SIMD3<Float>(vertex.normal.0, vertex.normal.1, vertex.normal.2)
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
                        color: (color.x, color.y, color.z, 1.0),
                        normal: (0, 0, 0)
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

/// MTKView subclass that adds hardware-keyboard + trackpad input on
/// iPad's Magic Keyboard (and any BT keyboard/mouse on iPhone). Bridges
/// to Q3 via Q3Sys_KeyEvent / Q3Sys_MouseMove (declared in the bridging
/// header).
///
/// - Keyboard: `pressesBegan/Ended` → maps `UIKey.keyCode` to Q3 keycodes
///   (defined in code/client/keycodes.h: ASCII for letters/digits, K_*
///   constants for arrows/modifiers/F-keys).
/// - Trackpad: `UIPanGestureRecognizer` with `.allowedScrollTypesMask =
///   .all` captures both two-finger trackpad pan AND mouse drag deltas.
///   Translation is fed as raw mouse delta (drag-to-look).
/// - Trackpad click: `UITapGestureRecognizer` with `allowedTouchTypes =
///   [.indirectPointer]` fires K_MOUSE1 (a standard click — bound by
///   default.cfg to `+attack`). Direct touch is excluded so on-screen
///   touches (HUD/joystick zones) don't double-fire.
///
/// Coexists cleanly with `GameControllerBridge`: both push events into
/// the same Q3 event queue (Sys_QueEvent), and Q3's bind system dispatches
/// based on the keycode regardless of source device. Whichever input
/// the user prefers (controller, keyboard, trackpad) just works.
final class Q3InputView: MTKView {
    override var canBecomeFirstResponder: Bool { true }

    override init(frame frameRect: CGRect, device: MTLDevice?) {
        super.init(frame: frameRect, device: device)
        setupInput()
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
        setupInput()
    }

    private func setupInput() {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        if #available(iOS 13.4, *) {
            pan.allowedScrollTypesMask = .all
        }
        addGestureRecognizer(pan)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        if #available(iOS 13.4, *) {
            tap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        }
        addGestureRecognizer(tap)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // Become first responder once SwiftUI has finished mounting.
        // Direct call during view installation is sometimes ignored
        // mid-layout; deferring one runloop tick is reliable.
        if window != nil {
            DispatchQueue.main.async { [weak self] in
                _ = self?.becomeFirstResponder()
            }
        }
    }

    @objc private func handlePan(_ g: UIPanGestureRecognizer) {
        switch g.state {
        case .began, .changed:
            let t = g.translation(in: self)
            let dx = Int32(t.x.rounded())
            let dy = Int32(t.y.rounded())
            if dx != 0 || dy != 0 {
                Q3Sys_MouseMove(dx, dy)
                // Reset translation so each call is a fresh delta
                // rather than cumulative.
                g.setTranslation(.zero, in: self)
            }
        default:
            break
        }
    }

    @objc private func handleTap(_ g: UITapGestureRecognizer) {
        guard g.state == .recognized else { return }
        // K_MOUSE1 = 178 (code/client/keycodes.h). Q3 binds run on
        // key-down; pulse down→up so the bind fires once per click.
        Q3Sys_KeyEvent(178, 1)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            Q3Sys_KeyEvent(178, 0)
        }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            guard let key = press.key else { continue }
            if let q3 = Q3InputView.q3Keycode(for: key) {
                Q3Sys_KeyEvent(q3, 1)
                handled = true
            }
            // Fire SE_CHAR for printable characters so console / cvar
            // value / player-name fields receive actual text. Use
            // `characters` (NOT charactersIgnoringModifiers) so shift
            // produces capitals and shifted symbols ("A", "!", "@", …).
            // ASCII printable range only; arrows/F-keys/modifiers
            // produce empty or non-printable .characters and are
            // skipped by the bounds check.
            for ch in key.characters.unicodeScalars {
                let v = ch.value
                if v >= 32 && v < 127 {
                    Q3Sys_CharEvent(Int32(v))
                }
            }
        }
        if !handled { super.pressesBegan(presses, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            if let key = press.key, let q3 = Q3InputView.q3Keycode(for: key) {
                Q3Sys_KeyEvent(q3, 0)
                handled = true
            }
        }
        if !handled { super.pressesEnded(presses, with: event) }
    }

    /// Map iOS `UIKey` to a Q3 keycode. Values mirror
    /// `code/client/keycodes.h`:
    /// - ASCII for letters/digits/punctuation (Q3's K_A..K_Z = 'a'..'z')
    /// - 9 K_TAB, 13 K_ENTER, 27 K_ESCAPE, 32 K_SPACE, 96 ` (toggleconsole)
    /// - 127 K_BACKSPACE
    /// - 132–135 arrow keys, 136 K_ALT, 137 K_CTRL, 138 K_SHIFT
    /// - 145–156 K_F1..K_F12
    static func q3Keycode(for key: UIKey) -> Int32? {
        switch key.keyCode {
        case .keyboardEscape: return 27
        case .keyboardReturnOrEnter, .keypadEnter: return 13
        case .keyboardSpacebar: return 32
        case .keyboardTab: return 9
        case .keyboardDeleteOrBackspace: return 127
        // iPad Magic Keyboard's only "delete" key is keyboardDeleteOrBackspace
        // above. Some external keyboards / Fn-Delete combos report
        // keyboardDeleteForward — Q3 has no separate forward-delete; map
        // it to the same K_BACKSPACE so the user's expectation of "delete
        // removes a character" holds in both cases.
        case .keyboardDeleteForward: return 127
        case .keyboardLeftArrow: return 134
        case .keyboardRightArrow: return 135
        case .keyboardUpArrow: return 132
        case .keyboardDownArrow: return 133
        case .keyboardLeftShift, .keyboardRightShift: return 138
        case .keyboardLeftControl, .keyboardRightControl: return 137
        case .keyboardLeftAlt, .keyboardRightAlt: return 136
        case .keyboardF1: return 145
        case .keyboardF2: return 146
        case .keyboardF3: return 147
        case .keyboardF4: return 148
        case .keyboardF5: return 149
        case .keyboardF6: return 150
        case .keyboardF7: return 151
        case .keyboardF8: return 152
        case .keyboardF9: return 153
        case .keyboardF10: return 154
        case .keyboardF11: return 155
        case .keyboardF12: return 156
        case .keyboardGraveAccentAndTilde: return 96
        default:
            // Fallback: trust the produced character. Some keyboard
            // layouts route DEL/BS through a keyCode that doesn't
            // match `.keyboardDeleteOrBackspace` — catch the actual
            // 0x7F (DEL) or 0x08 (BS) character and route both to
            // K_BACKSPACE.
            if let ch = key.charactersIgnoringModifiers.first,
               let asc = ch.asciiValue {
                if asc == 0x7F || asc == 0x08 { return 127 }
                if asc >= 32 && asc < 127 {
                    // Printable ASCII — Q3 uses lowercase for letter keys.
                    if let lower = String(ch).lowercased().first?.asciiValue {
                        return Int32(lower)
                    }
                    return Int32(asc)
                }
            }
            return nil
        }
    }
}
