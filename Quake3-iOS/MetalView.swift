import SwiftUI
import MetalKit
#if canImport(MetalFX)
import MetalFX
#endif
import GameController
import QuartzCore
import simd

/// MetalFX upscale quality picker. Persists via UserDefaults; the launcher
/// menu sets it before Quake3_Init runs. C-side cmdline picks up the input
/// render resolution via Q3_SetRenderResolution; Coordinator creates an
/// offscreen RT at that size and uses MTLFXSpatialScaler to upscale to the
/// drawable each frame. Native quality bypasses the RT — Q3 renders direct
/// to the drawable as before (no MetalFX overhead).
enum Q3UpscaleQuality: String, CaseIterable {
    case native = "native"
    case high = "high"
    case medium = "medium"
    case low = "low"

    static let userDefaultsKey = "q3_upscale_quality"

    static var current: Q3UpscaleQuality {
        // Env var override (terminal capture workflow, e.g.
        // `xcrun devicectl ... --environment-variables {"Q3_UPSCALE_QUALITY":"medium"}`).
        // Takes precedence over UserDefaults so scripts/iphone_q3_avi.sh
        // can record one .mov per quality without tapping the picker.
        if let envRaw = ProcessInfo.processInfo.environment["Q3_UPSCALE_QUALITY"]?.lowercased(),
           let envQ = Q3UpscaleQuality(rawValue: envRaw) {
            NSLog("[Q3-UPSCALE] using env var Q3_UPSCALE_QUALITY=%@", envRaw)
            return envQ
        }
        let raw = UserDefaults.standard.string(forKey: userDefaultsKey) ?? "native"
        return Q3UpscaleQuality(rawValue: raw) ?? .native
    }

    static func save(_ q: Q3UpscaleQuality) {
        UserDefaults.standard.set(q.rawValue, forKey: userDefaultsKey)
        UserDefaults.standard.synchronize()
    }

    var label: String {
        switch self {
        case .native: return "Native"
        case .high:   return "High"
        case .medium: return "Medium"
        case .low:    return "Low"
        }
    }

    /// Compute Q3's render-input dimensions given the drawable's output
    /// target dimensions (the existing iPhone/iPad lock — typically
    /// 1920×888 on iPhone, 2560×1920 on iPad).
    func renderSize(forOutput out: CGSize) -> CGSize {
        switch self {
        case .native:
            return out
        case .high:
            return CGSize(width: floor(out.width * 0.75),
                          height: floor(out.height * 0.75))
        case .medium:
            return CGSize(width: floor(out.width * 0.5),
                          height: floor(out.height * 0.5))
        case .low:
            // 480 vertical px (480p), preserve aspect for width.
            let h: CGFloat = 480
            let aspect = (out.height > 0) ? out.width / out.height : 16.0 / 9.0
            return CGSize(width: floor(h * aspect), height: h)
        }
    }

    /// One-line summary suitable for the launcher row subtitle.
    func subtitle(forOutput out: CGSize) -> String {
        let r = renderSize(forOutput: out)
        switch self {
        case .native:
            return "Render at \(Int(r.width))×\(Int(r.height)) — no upscale"
        default:
            return "Render at \(Int(r.width))×\(Int(r.height)) → MetalFX upscale to \(Int(out.width))×\(Int(out.height))"
        }
    }
}

/// MetalFX frame interpolation toggle. When .on, the renderer creates an
/// MTLFXFrameInterpolator (iOS 18+) and emits one synthesized in-between
/// frame between each pair of rendered frames — perceived framerate ~2×.
///
/// CAVEAT: the MetalFX frame interpolator wants per-pixel motion vectors
/// to keep moving objects sharp. Q3 doesn't emit motion vectors yet
/// (would require per-frame world+entity reprojection like the Q2
/// MetalTAA path). Without them, the interpolated frame is just an
/// optical-flow guess from color/depth alone — produces visible ghosting
/// on fast camera motion. Useful for smooth UI / slow-pan scenes,
/// distracting in deathmatch. Off by default until motion vectors land.
enum Q3FrameInterpolation: String, CaseIterable {
    case off = "off"
    case on  = "on"

    static let userDefaultsKey = "q3_frame_interpolation"

    static var current: Q3FrameInterpolation {
        if let envRaw = ProcessInfo.processInfo.environment["Q3_FRAME_INTERPOLATION"]?.lowercased(),
           let envQ = Q3FrameInterpolation(rawValue: envRaw) {
            NSLog("[Q3-FRAMEINTERP] using env var Q3_FRAME_INTERPOLATION=%@", envRaw)
            return envQ
        }
        let raw = UserDefaults.standard.string(forKey: userDefaultsKey) ?? "off"
        return Q3FrameInterpolation(rawValue: raw) ?? .off
    }

    static func save(_ q: Q3FrameInterpolation) {
        UserDefaults.standard.set(q.rawValue, forKey: userDefaultsKey)
        UserDefaults.standard.synchronize()
    }

    var label: String {
        switch self {
        case .off: return "Off"
        case .on:  return "On (Experimental)"
        }
    }

    var subtitle: String {
        switch self {
        case .off: return "Engine fps presented as-is"
        case .on:  return "MetalFX inserts synthesized frames · expect ghosting on fast motion"
        }
    }
}


/// Runtime ray-tracing overlay mix. This is a launch-menu convenience
/// around the existing `r_rt_mix` cvar: 0 = raster only, 0.5 = blended
/// A/B view, 1 = pure RT output. Persisted so Q3_RT can boot directly
/// into the user's last selected RT mode.
enum Q3RTMix: String, CaseIterable {
    case off = "0"
    case blend = "0.5"
    case pure = "1"

    static let userDefaultsKey = "q3_rt_mix"

    static var current: Q3RTMix {
        if let envRaw = ProcessInfo.processInfo.environment["Q3_RT_MIX"],
           let envQ = Q3RTMix(rawValue: envRaw) {
            NSLog("[Q3-RT] using env var Q3_RT_MIX=%@", envRaw)
            return envQ
        }
        let raw = UserDefaults.standard.string(forKey: userDefaultsKey) ?? "0"
        return Q3RTMix(rawValue: raw) ?? .off
    }

    static func save(_ q: Q3RTMix) {
        UserDefaults.standard.set(q.rawValue, forKey: userDefaultsKey)
        UserDefaults.standard.synchronize()
    }

    var label: String {
        switch self {
        case .off: return "Raster"
        case .blend: return "RT Blend"
        case .pure: return "Pure RT"
        }
    }

    var subtitle: String {
        switch self {
        case .off: return "r_rt_mix 0"
        case .blend: return "r_rt_mix 0.5"
        case .pure: return "r_rt_mix 1"
        }
    }

    var value: Float { Float(rawValue) ?? 0 }
    var consoleCommand: String { "r_rt_mix \(rawValue)" }
}

struct MetalView: UIViewRepresentable {
    func makeUIView(context: Context) -> Q3InputView {
        let view = Q3InputView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.colorPixelFormat = .bgra8Unorm
        view.depthStencilPixelFormat = .depth32Float
        view.delegate = context.coordinator
        #if os(visionOS)
        let maxFPS = 90
        #else
        /* Prefer ProMotion-rate rendering when available. Some Simulator
         * runtimes report 60 even for Pro-class devices, but setting a
         * 120Hz range is harmless there and lets real iPhone Pro/Max
         * hardware run past 60 when the renderer has headroom. */
        let maxFPS = max(UIScreen.main.maximumFramesPerSecond, 120)
        #endif
        view.preferredFramesPerSecond = maxFPS
        print("[Metal] display config screenMaxFPS=\(UIScreen.main.maximumFramesPerSecond) preferredFPS=\(view.preferredFramesPerSecond) lowPower=\(ProcessInfo.processInfo.isLowPowerModeEnabled ? 1 : 0) nativeBounds=\(UIScreen.main.nativeBounds) nativeScale=\(UIScreen.main.nativeScale)")
        view.enableSetNeedsDisplay = false
        view.isPaused = true
        context.coordinator.configureFramePacer(for: view, preferredFPS: maxFPS)
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
            /* Keep three drawables in flight on ProMotion devices. q3dm4
             * showed low CPU encode time but ~13ms stalls in
             * MTKView.currentDrawable on iPad; double buffering turns a
             * short GPU/present delay into a visible 60Hz cap. */
            if #available(iOS 13.0, visionOS 1.0, *) {
                metalLayer.maximumDrawableCount = 3
                print("[Metal] layer maximumDrawableCount=\(metalLayer.maximumDrawableCount)")
            }
            metalLayer.presentsWithTransaction = false
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
        private weak var pacedView: MTKView?
        private var displayLink: CADisplayLink?

        deinit {
            displayLink?.invalidate()
        }

        func configureFramePacer(for view: MTKView, preferredFPS: Int) {
            pacedView = view
            displayLink?.invalidate()

            let link = CADisplayLink(target: self, selector: #selector(displayLinkDidFire(_:)))
            #if os(iOS)
            if #available(iOS 15.0, *) {
                let minimum = Float(min(60, preferredFPS))
                let maximum = Float(preferredFPS)
                link.preferredFrameRateRange = CAFrameRateRange(minimum: minimum,
                                                                maximum: maximum,
                                                                preferred: maximum)
                print("[Metal] display link range min=\(minimum) max=\(maximum) preferred=\(maximum)")
            } else {
                link.preferredFramesPerSecond = preferredFPS
                print("[Metal] display link preferredFPS=\(link.preferredFramesPerSecond)")
            }
            #else
            link.preferredFramesPerSecond = preferredFPS
            print("[Metal] display link preferredFPS=\(link.preferredFramesPerSecond)")
            #endif
            link.add(to: .main, forMode: .common)
            displayLink = link
        }

        @objc private func displayLinkDidFire(_ link: CADisplayLink) {
            pacedView?.draw()
        }

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
            /* Per-vertex CGEN_LIGHTING_DIFFUSE — ambient + directed *
             * Lambert from the BSP lightgrid sampled at this vertex's
             * world position. Computed C-side in EmitWorldVertex.
             * Consumed by the world fragment's ComputeRGBGen mode 2.
             * SIMD3 stride = 16 (3 floats + pad); matches MSL float3. */
            var lightingDiffuse: SIMD3<Float>
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

        struct FogVolumeUniforms {
            var viewProjection: simd_float4x4
            var inverseViewProjection: simd_float4x4
            var cameraPos: SIMD3<Float>
            var _pad: Float = 0
            var fogColorDistance: SIMD4<Float>
            var boundsMin: SIMD4<Float>
            var boundsMax: SIMD4<Float>
            // xyz = fog.surface, w = fog.surface[3]
            var fogSurface: SIMD4<Float>
            // Reserved for future depth-limited fog tuning.
            var fogParams: SIMD4<Float>
        }

        struct RayTracingUniforms {
            var viewProjection: simd_float4x4
            var invViewProjection: simd_float4x4
            var cameraPos: SIMD4<Float>
            var cameraForward: SIMD4<Float>
            var cameraRight: SIMD4<Float>
            var cameraUp: SIMD4<Float>
            var jitterNearFar: SIMD4<Float> // xy=jitter, z=near, w=far
            var fovParams: SIMD4<Float>     // x=tanHalfFovX, y=tanHalfFovY
        }

        struct RTPrimitiveMaterial {
            var albedoSlot: UInt32
            var lightmapSlot: UInt32
            var tcModCount: UInt32
            var _pad0: UInt32 = 0
            var alphaTcModControl: SIMD4<Float> // x=alphaTestThreshold
            var tcModTypes: SIMD4<UInt32>       // up to 4 tcMod types, 0=none
            var tcModParams0: SIMD4<Float>
            var tcModParams1: SIMD4<Float>
            var tcModParams2: SIMD4<Float>
            var tcModParams3: SIMD4<Float>
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
            /* CGEN_CONST tint + AGEN_CONST alpha. .xyz = const rgb,
             * .w = const alpha (mirrors EntityUniforms.rgbConstColor).
             * Defaults to (1,1,1,1) so non-CONST stages no-op. */
            var rgbConstColor: SIMD4<Float> = SIMD4(1, 1, 1, 1)
            /* CGEN_ENTITY rgb + AGEN_ENTITY alpha. .xyz = entity rgb,
             * .w = entity alpha. World draws populate as identity;
             * entity shaders use the dedicated EntityUniforms path. */
            var entityColor: SIMD4<Float> = SIMD4(1, 1, 1, 1)
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
            // deformVertexes bulge — per-vertex ST-coord-driven sine
            // displacement along normal. Used by q3dm4's gothic_block
            // organic tubes. bulgeWidth=0 means no bulge.
            // Math: phase = st.s*width + time*speed; pos += n * sin(phase) * height.
            var deformBulgeWidth: Float = 0
            var deformBulgeHeight: Float = 0
            var deformBulgeSpeed: Float = 0
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
            var pbrRoughness: Float = 0.55
            var pbrMetallic: Float = 0.30
            var _pad0: Float = 0
        }

        // Render debug: 0 = normal, 1 = base only, 2 = lightmap only,
        // 3 = uv1 visualization, 4 = vertex color only. Flip to diagnose
        // lightmap / uv1 issues without touching the build pipeline.
        private static let worldDebugMode: Float = 0
        /// FOG-DIAG: which fog indices we've already printed (one-shot per unique index).
        nonisolated(unsafe) static var fogSeen: Set<Int> = []

        // One-shot: logs the first sky draw's stage layout once per launch.
        // Confirms killsky_1 + killsky_2 are both wired through as stages.
        // Instance property (not static) to sidestep Swift 6 strict global
        // concurrency — Coordinator itself is main-actor driven, so the
        // bool is safe here without any isolation attribute.
        private var skyStagesLogged: Bool = false

        private static func metalCullMode(for stageCullMode: UInt32) -> MTLCullMode {
            Q3MetalStateMap.cullMode(stageCullMode)
        }

        private static func blendClass(src: UInt32, dst: UInt32) -> Int {
            switch (src, dst) {
            case (Q3GLBlendFactor.one.rawValue, Q3GLBlendFactor.one.rawValue):
                return 5
            case (Q3GLBlendFactor.srcAlpha.rawValue, Q3GLBlendFactor.one.rawValue):
                return 1
            case (Q3GLBlendFactor.srcAlpha.rawValue, Q3GLBlendFactor.oneMinusSrcAlpha.rawValue):
                return 2
            case (Q3GLBlendFactor.dstColor.rawValue, Q3GLBlendFactor.zero.rawValue),
                 (Q3GLBlendFactor.zero.rawValue, Q3GLBlendFactor.srcColor.rawValue):
                return 3
            case (Q3GLBlendFactor.zero.rawValue, Q3GLBlendFactor.oneMinusSrcColor.rawValue):
                return 4
            default:
                return 0
            }
        }

        private static func worldBlendClass(for stage: Q3MetalWorldStage) -> Int {
            Self.blendClass(src: stage.srcBlend, dst: stage.dstBlend)
        }

        private static func worldRenderPass(for stage: Q3MetalWorldStage) -> Int {
            let blendMode = Self.worldBlendClass(for: stage)
            return (stage.useLightmap != 0) ? 1
                 : (blendMode == 5) ? 4
                 : (blendMode == 1) ? 3
                 : (blendMode == 2) ? 2
                 : (blendMode == 3) ? 1
                 : 0
        }

        private static func configureBlend(_ attachment: MTLRenderPipelineColorAttachmentDescriptor,
                                           src: UInt32,
                                           dst: UInt32) {
            attachment.isBlendingEnabled = true
            attachment.writeMask = .all
            attachment.rgbBlendOperation = .add
            attachment.alphaBlendOperation = .add
            attachment.sourceRGBBlendFactor = Q3MetalStateMap.blendFactor(src)
            attachment.sourceAlphaBlendFactor = Q3MetalStateMap.blendFactor(src)
            attachment.destinationRGBBlendFactor = Q3MetalStateMap.blendFactor(dst)
            attachment.destinationAlphaBlendFactor = Q3MetalStateMap.blendFactor(dst)
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

        private struct WorldPassEntry {
            let drawIndex: Int
            /* -1 = sky draw (all sky stages), -2 = fog-only draw. */
            let stageIndex: Int
        }

        private struct WorldIndexBatch {
            let drawIndex: Int
            let stageIndex: Int
            var firstMergedIndex: Int
            var indexCount: Int
        }

        private var worldBatchIndexScratch: [UInt32] = []
        private var worldBatchIndexBuffers: [MTLBuffer?] = Array(repeating: nil, count: 3)
        private var worldBatchIndexBufferCapacities: [Int] = Array(repeating: 0, count: 3)

        private func ensureWorldBatchIndexBuffer(device: MTLDevice, indexCount: Int, slot: Int) -> MTLBuffer? {
            let byteCount = max(4, indexCount * MemoryLayout<UInt32>.stride)
            let clampedSlot = max(0, min(slot, worldBatchIndexBuffers.count - 1))
            if worldBatchIndexBuffers[clampedSlot] == nil || worldBatchIndexBufferCapacities[clampedSlot] < byteCount {
                worldBatchIndexBuffers[clampedSlot] = device.makeBuffer(length: byteCount, options: .storageModeShared)
                worldBatchIndexBufferCapacities[clampedSlot] = byteCount
            }
            return worldBatchIndexBuffers[clampedSlot]
        }

        private static func tcModEqual(_ a: Q3TcMod, _ b: Q3TcMod) -> Bool {
            a.type == b.type &&
            a.params.0 == b.params.0 &&
            a.params.1 == b.params.1 &&
            a.params.2 == b.params.2 &&
            a.params.3 == b.params.3
        }

        private static func float4Equal(_ a: (Float, Float, Float, Float),
                                        _ b: (Float, Float, Float, Float)) -> Bool {
            a.0 == b.0 && a.1 == b.1 && a.2 == b.2 && a.3 == b.3
        }

        private static func float3Equal(_ a: (Float, Float, Float),
                                        _ b: (Float, Float, Float)) -> Bool {
            a.0 == b.0 && a.1 == b.1 && a.2 == b.2
        }

        private static func worldDrawHasLightmapStage(_ draw: Q3MetalWorldDrawCmd) -> Bool {
            let stageCount = min(Int(draw.stageCount), Int(Q3_METAL_MAX_STAGES))
            guard stageCount > 0 else { return false }
            for i in 0..<stageCount where Self.worldStage(draw, i).useLightmap != 0 {
                return true
            }
            return false
        }

        private static func hashCombine(_ hash: inout UInt64, _ value: UInt64) {
            hash ^= value &+ 0x9e3779b97f4a7c15 &+ (hash << 6) &+ (hash >> 2)
        }

        private static func floatBits(_ value: Float) -> UInt64 {
            UInt64(value.bitPattern)
        }

        private static func worldBatchHash(draw: Q3MetalWorldDrawCmd,
                                           stage: Q3MetalWorldStage,
                                           pass: Int) -> UInt64 {
            var h: UInt64 = 0xcbf29ce484222325
            hashCombine(&h, UInt64(pass))
            hashCombine(&h, UInt64(draw.lightmapTextureHandle))
            hashCombine(&h, UInt64(draw.flags))
            hashCombine(&h, UInt64(draw.fogIndex))
            hashCombine(&h, Self.worldDrawHasLightmapStage(draw) ? 1 : 0)
            hashCombine(&h, UInt64(stage.textureHandle))
            hashCombine(&h, UInt64(stage.srcBlend))
            hashCombine(&h, UInt64(stage.dstBlend))
            hashCombine(&h, UInt64(stage.depthFunc))
            hashCombine(&h, UInt64(stage.tcGen))
            hashCombine(&h, UInt64(stage.tcModCount))
            hashCombine(&h, UInt64(stage.rgbGen))
            hashCombine(&h, UInt64(stage.alphaGen))
            hashCombine(&h, UInt64(stage.alphaFunc))
            hashCombine(&h, UInt64(stage.cullMode))
            hashCombine(&h, UInt64(stage.useLightmap))
            hashCombine(&h, UInt64(stage.depthWrite))
            hashCombine(&h, UInt64(stage.rgbWaveFunc))
            hashCombine(&h, floatBits(stage.rgbWaveBase))
            hashCombine(&h, floatBits(stage.rgbWaveAmp))
            hashCombine(&h, floatBits(stage.rgbWavePhase))
            hashCombine(&h, floatBits(stage.rgbWaveFreq))
            hashCombine(&h, UInt64(stage.alphaWaveFunc))
            hashCombine(&h, floatBits(stage.alphaWaveBase))
            hashCombine(&h, floatBits(stage.alphaWaveAmp))
            hashCombine(&h, floatBits(stage.alphaWavePhase))
            hashCombine(&h, floatBits(stage.alphaWaveFreq))
            hashCombine(&h, floatBits(stage.pbrRoughness))
            hashCombine(&h, floatBits(stage.pbrMetallic))
            let mods = [stage.tcMods.0, stage.tcMods.1, stage.tcMods.2, stage.tcMods.3]
            for m in mods {
                hashCombine(&h, UInt64(m.type))
                hashCombine(&h, floatBits(m.params.0))
                hashCombine(&h, floatBits(m.params.1))
                hashCombine(&h, floatBits(m.params.2))
                hashCombine(&h, floatBits(m.params.3))
            }
            return h
        }

        private static func worldStagesEquivalentForMerge(_ a: Q3MetalWorldStage,
                                                          _ b: Q3MetalWorldStage) -> Bool {
            guard a.textureHandle == b.textureHandle,
                  a.blendMode == b.blendMode,
                  a.srcBlend == b.srcBlend,
                  a.dstBlend == b.dstBlend,
                  a.depthFunc == b.depthFunc,
                  a.tcGen == b.tcGen,
                  a.tcModCount == b.tcModCount,
                  a.deformWaveFunc == b.deformWaveFunc,
                  a.deformWaveDiv == b.deformWaveDiv,
                  a.deformWaveBase == b.deformWaveBase,
                  a.deformWaveAmp == b.deformWaveAmp,
                  a.deformWavePhase == b.deformWavePhase,
                  a.deformWaveFreq == b.deformWaveFreq,
                  a.deformMoveFunc == b.deformMoveFunc,
                  float3Equal(a.deformMoveVector, b.deformMoveVector),
                  a.deformMoveBase == b.deformMoveBase,
                  a.deformMoveAmp == b.deformMoveAmp,
                  a.deformMovePhase == b.deformMovePhase,
                  a.deformMoveFreq == b.deformMoveFreq,
                  a.autospriteMode == b.autospriteMode,
                  a.rgbGen == b.rgbGen,
                  a.alphaGen == b.alphaGen,
                  a.alphaFunc == b.alphaFunc,
                  a.cullMode == b.cullMode,
                  a.useLightmap == b.useLightmap,
                  a.depthWrite == b.depthWrite,
                  a.rgbWaveFunc == b.rgbWaveFunc,
                  a.rgbWaveBase == b.rgbWaveBase,
                  a.rgbWaveAmp == b.rgbWaveAmp,
                  a.rgbWavePhase == b.rgbWavePhase,
                  a.rgbWaveFreq == b.rgbWaveFreq,
                  a.alphaWaveFunc == b.alphaWaveFunc,
                  a.alphaWaveBase == b.alphaWaveBase,
                  a.alphaWaveAmp == b.alphaWaveAmp,
                  a.alphaWavePhase == b.alphaWavePhase,
                  a.alphaWaveFreq == b.alphaWaveFreq,
                  float3Equal(a.rgbConstColor, b.rgbConstColor),
                  a.alphaConst == b.alphaConst,
                  a.pbrRoughness == b.pbrRoughness,
                  a.pbrMetallic == b.pbrMetallic,
                  float4Equal(a.tcGenVec0, b.tcGenVec0),
                  float4Equal(a.tcGenVec1, b.tcGenVec1) else {
                return false
            }

            return tcModEqual(a.tcMods.0, b.tcMods.0) &&
                   tcModEqual(a.tcMods.1, b.tcMods.1) &&
                   tcModEqual(a.tcMods.2, b.tcMods.2) &&
                   tcModEqual(a.tcMods.3, b.tcMods.3)
        }

        private static func worldDrawsCanMerge(_ draw: Q3MetalWorldDrawCmd,
                                               stage: Q3MetalWorldStage,
                                               nextDraw: Q3MetalWorldDrawCmd,
                                               nextStage: Q3MetalWorldStage,
                                               pass: Int,
                                               mergedIndexCount: Int) -> Bool {
            guard nextDraw.indexCount > 0,
                  nextDraw.firstIndex == draw.firstIndex + UInt32(mergedIndexCount),
                  nextDraw.lightmapTextureHandle == draw.lightmapTextureHandle,
                  nextDraw.flags == draw.flags,
                  nextDraw.fogIndex == draw.fogIndex,
                  Self.worldRenderPass(for: nextStage) == pass,
                  Self.worldDrawHasLightmapStage(nextDraw) == Self.worldDrawHasLightmapStage(draw) else {
                return false
            }
            return Self.worldStagesEquivalentForMerge(stage, nextStage)
        }

        private static func worldDrawsCanBatch(_ draw: Q3MetalWorldDrawCmd,
                                               stage: Q3MetalWorldStage,
                                               nextDraw: Q3MetalWorldDrawCmd,
                                               nextStage: Q3MetalWorldStage,
                                               pass: Int) -> Bool {
            guard nextDraw.indexCount > 0,
                  nextDraw.lightmapTextureHandle == draw.lightmapTextureHandle,
                  nextDraw.flags == draw.flags,
                  nextDraw.fogIndex == draw.fogIndex,
                  Self.worldRenderPass(for: nextStage) == pass,
                  Self.worldDrawHasLightmapStage(nextDraw) == Self.worldDrawHasLightmapStage(draw) else {
                return false
            }
            return Self.worldStagesEquivalentForMerge(stage, nextStage)
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
                    /* applyTcMod(type=3) owns the degrees→radians
                     * conversion. Pack signed degrees/sec here only. */
                    v = SIMD4<Float>(-pp.0, 0, 0, 0)
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
         * speed stays in degrees/sec; applyTcMod does the single
         * degrees→radians conversion. We only negate to match ioquake3's
         * `degs = -degsPerSecond * timeScale` sign convention. */
        /// Per-process one-time set of texture names we've already logged
        /// the tcMod-extraction result for. Filtered to powerup-shell-family
        /// names so the log stays small. Logs whether tcMods were found,
        /// types, and params — pinpoints which link in the texture →
        /// uniforms chain breaks when the chrome scroll doesn't animate.
        nonisolated(unsafe) private static var loggedTcModShaderNames: Set<String> = []
        private static func packEntityTcMods(handle: UInt32, into uniforms: inout EntityUniforms) {
            uniforms.tcModCount = 0
            uniforms.tcModType = SIMD4<Float>(0, 0, 0, 0)
            uniforms.tcModParams0 = SIMD4<Float>(0, 0, 0, 0)
            uniforms.tcModParams1 = SIMD4<Float>(0, 0, 0, 0)
            uniforms.tcModParams2 = SIMD4<Float>(0, 0, 0, 0)
            uniforms.tcModParams3 = SIMD4<Float>(0, 0, 0, 0)
            var info = Q3MetalTextureInfo()
            let infoOk = Q3MetalRenderer_GetTextureInfo(handle, &info) == 1
            // Diagnostic: log the tcMod chain for powerup-shell shaders so
            // we can see exactly what the entity pipeline sees at runtime.
            // Logs at most once per shader name to keep volume bounded.
            if let cName = Q3MetalRenderer_GetTextureName(handle) {
                let name = String(cString: cName).lowercased()
                if (name.contains("quad") || name.contains("regen") || name.contains("battle")
                    || name.contains("invuln") || name.contains("haste"))
                    && !Self.loggedTcModShaderNames.contains(name) {
                    Self.loggedTcModShaderNames.insert(name)
                    if infoOk {
                        let mods = [info.tcMods.0, info.tcMods.1, info.tcMods.2, info.tcMods.3]
                        NSLog("[Q3-TCMOD] '%@' handle=%u infoOk=1 tcModCount=%u type[0]=%d params[0]=(%.3f,%.3f,%.3f,%.3f)",
                              name, handle, info.tcModCount, Int32(mods[0].type),
                              mods[0].params.0, mods[0].params.1, mods[0].params.2, mods[0].params.3)
                    } else {
                        NSLog("[Q3-TCMOD] '%@' handle=%u infoOk=0 — Q3MetalRenderer_GetTextureInfo bailed (rgbaBytes likely NULL)",
                              name, handle)
                    }
                }
            }
            guard infoOk else { return }
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
                case 3: /* rotate: signed degrees/sec; MSL converts once */
                    types[i] = 3
                    packed[i] = SIMD4(-pp.0, 0, 0, 0)
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

        /* Route deformVertexes wave parameters (shader-level, stage 0)
         * to the entity vertex shader. Without this, customShader chrome
         * shells (powerups/quadWeapon, powerups/quad, regen, battlesuit)
         * render at the model's exact position and collapse into the
         * silhouette — user-visible bug: missing breathing halo around
         * the gun when quad damage is active. Default-zero func means
         * the vertex shader skips the deform branch entirely (per-vertex
         * cost: one int compare, branch-predictor-friendly). */
        private static func packEntityDeform(handle: UInt32, into uniforms: inout EntityUniforms) {
            uniforms.deformWaveFunc = 0
            uniforms.deformWaveDiv = 1.0
            uniforms.deformWaveBase = 0
            uniforms.deformWaveAmp = 0
            uniforms.deformWavePhase = 0
            uniforms.deformWaveFreq = 0
            var info = Q3MetalTextureInfo()
            guard Q3MetalRenderer_GetTextureInfo(handle, &info) == 1 else { return }
            uniforms.deformWaveFunc = info.deformWaveFunc
            /* Guard against pathological zero/negative div from a malformed
             * shader; div is used as 1/div in the MSL kernel. Canonical Q3
             * powerups shaders use div=100. */
            uniforms.deformWaveDiv = max(info.deformWaveDiv, 1e-4)
            uniforms.deformWaveBase = info.deformWaveBase
            uniforms.deformWaveAmp = info.deformWaveAmp
            uniforms.deformWavePhase = info.deformWavePhase
            uniforms.deformWaveFreq = info.deformWaveFreq
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
            /* deformVertexes wave (shader-level, stage 0). When
             * deformWaveFunc != 0, q3_entity_vertex offsets the vertex
             * along its normal by:
             *   spread = 1 / div
             *   off    = (pos.x + pos.y + pos.z) * spread
             *   scale  = wave(func, base, amp, phase + off, freq, time)
             *   pos   += normal * scale
             * Mirrors the world pipeline's deform block (line ~1444).
             * Drives the powerups/quadWeapon halo (+0.5 unit constant
             * offset), powerups/quad (+3 unit), regen / battlesuit
             * shells. func index: 1=sin 2=triangle 3=square 4=sawtooth
             * 5=inverseSawtooth — same as evalWave. */
            var deformWaveFunc: UInt32 = 0
            var deformWaveDiv: Float = 1.0
            var deformWaveBase: Float = 0
            var deformWaveAmp: Float = 0
            var deformWavePhase: Float = 0
            var deformWaveFreq: Float = 0
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
            if (dot(fogRGB, fogRGB) < 0.001) {
                /* q3dm4's xdensegreyfog resolves through the script path as
                 * black fogparms, but stock visuals are a grey x-density fog.
                 * Use the grey fallback consistently for the boundary sheet,
                 * per-surface fog pass, entities, and the eye-inside ray-box. */
                return float3(0.36);
            }
            return fogRGB;
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
            /* deformVertexes wave (shader-level). Applied in
             * q3_entity_vertex when deformWaveFunc != 0. Matches the
             * world pipeline's deform formula exactly. */
            uint  deformWaveFunc;
            float deformWaveDiv;
            float deformWaveBase;
            float deformWaveAmp;
            float deformWavePhase;
            float deformWaveFreq;
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
            if (modCount > 0) texCoord = applyTcMod(texCoord, in.worldPos, int(drawUniforms.tcModType.x + 0.5), drawUniforms.tcModParams0, drawUniforms.timeSeconds);
            if (modCount > 1) texCoord = applyTcMod(texCoord, in.worldPos, int(drawUniforms.tcModType.y + 0.5), drawUniforms.tcModParams1, drawUniforms.timeSeconds);
            if (modCount > 2) texCoord = applyTcMod(texCoord, in.worldPos, int(drawUniforms.tcModType.z + 0.5), drawUniforms.tcModParams2, drawUniforms.timeSeconds);
            if (modCount > 3) texCoord = applyTcMod(texCoord, in.worldPos, int(drawUniforms.tcModType.w + 0.5), drawUniforms.tcModParams3, drawUniforms.timeSeconds);
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
                float2 nmUV = in.texCoord * 0.5;
                float3 nMap = worldNormalMap.sample(textureSampler, nmUV).xyz * 2.0 - 1.0;

                float3 N = in.worldNormal;
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
                if (pbrWorldParams.x > 0.5 && !is_null_texture(envCube)) {
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

                    float maxMipF = float(envCube.get_num_mip_levels() - 1);
                    float3 diffuseIBL = envCube.sample(envSampler, worldN, level(maxMipF)).rgb;
                    float3 R = reflect(-V, worldN);
                    float specMip = roughness * maxMipF;
                    float3 specularIBL = envCube.sample(envSampler, R, level(specMip)).rgb;

                    float3 F0 = mix(float3(0.04), lit, metallic);
                    float3 F_v = F0 + (max(float3(1.0 - roughness), F0) - F0)
                                       * pow(1.0 - NdotV, 5.0);
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
                    float fresnelGate = pow(1.0 - NdotV, 2.0);
                    float fillScale = ambBoost * shadowMask;
                    float specMask  = specBoost
                                    * (0.5 * shadowMask + 0.5)   // half shadow-driven
                                    * (0.3 + 0.7 * fresnelGate); // mostly edge-driven
                    lit = lit
                        + kD_v * diffuseIBL * fillScale
                        + F_v  * specularIBL * specMask;
                }
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
                        if (!is_null_texture(envCube)) {
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
                    float rimStrength = fresnel * mix(0.20, pbrRimParams.x, 1.0 - roughness);
                    // GGX-path entities (full PBR) get a much subtler rim
                    // accent than rim-only entities — they already have
                    // proper specular from the BRDF.
                    rimStrength *= hasFullPBR ? 0.35 : 1.0;
                    base.rgb = mix(base.rgb, rimColor, saturate(rimStrength));
                }
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

        /* MetalFX spatial upscale (Q3UpscaleQuality picker).
         *   - upscaleQuality is read once from UserDefaults at Coordinator
         *     init. Quake3_iOSApp also calls Q3_SetRenderResolution() before
         *     Quake3_Init so Q3's cmdline gets r_customwidth/height matching
         *     upscaleColorTarget's dimensions.
         *   - When != .native: every frame's main render encoder is pointed
         *     at upscaleColorTarget instead of the drawable, viewport +
         *     depth attachment use the RT's size, and after encoder.endEncoding
         *     the spatialScaler upscales RT → drawable. encodePostprocess
         *     still runs on the drawable (full-res tone curve).
         *   - When .native: the RT is nil and we render direct to drawable
         *     like before. spatialScaler is also nil — no MetalFX overhead. */
        private var upscaleQuality: Q3UpscaleQuality = Q3UpscaleQuality.current
        private var upscaleColorTarget: MTLTexture?
        private var upscaleDepthTarget: MTLTexture?
        #if canImport(MetalFX)
        private var spatialScaler: MTLFXSpatialScaler?
        #endif
        /// Cached (inputW, inputH, outputW, outputH) the scaler was built
        /// for; rebuild lazily on any change (drawable resize, quality flip).
        private var spatialScalerKey: (Int, Int, Int, Int) = (0, 0, 0, 0)

        /// (Re)build the offscreen color + depth RT and the MTLFXSpatialScaler
        /// for the given input/output dimensions. Returns false if the device
        /// can't host MetalFX (very old hardware) — caller falls back to direct
        /// rendering. Called from draw() lazily when upscaleQuality != .native.
        private func ensureSpatialUpscaleTargets(device: MTLDevice,
                                                 inputW: Int, inputH: Int,
                                                 outputW: Int, outputH: Int) -> Bool {
            #if !canImport(MetalFX)
            // Simulator builds: MetalFX framework not available in the
            // iphonesimulator SDK. Fall back to direct rendering (upscale
            // disabled). Real device builds run the path below.
            return false
            #else
            let key = (inputW, inputH, outputW, outputH)
            if spatialScaler != nil && spatialScalerKey == key { return true }

            // Color RT (.private, [renderTarget, shaderRead] — Q3 renders
            // INTO this, MetalFX READS this).
            let colorDesc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm,
                width: inputW, height: inputH, mipmapped: false)
            colorDesc.usage = [.renderTarget, .shaderRead]
            colorDesc.storageMode = .private
            colorDesc.textureType = .type2D
            guard let color = device.makeTexture(descriptor: colorDesc) else {
                print("[MetalFX] ensureSpatialUpscaleTargets: color RT alloc failed (\(inputW)×\(inputH))")
                return false
            }
            color.label = "Q3.upscale.color"
            upscaleColorTarget = color

            // Depth RT (.private, renderTarget) — same dims as color RT.
            let depthDesc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .depth32Float,
                width: inputW, height: inputH, mipmapped: false)
            depthDesc.usage = [.renderTarget]
            depthDesc.storageMode = .private
            depthDesc.textureType = .type2D
            guard let depth = device.makeTexture(descriptor: depthDesc) else {
                print("[MetalFX] ensureSpatialUpscaleTargets: depth RT alloc failed (\(inputW)×\(inputH))")
                return false
            }
            depth.label = "Q3.upscale.depth"
            upscaleDepthTarget = depth

            // MTLFXSpatialScaler descriptor → build a fresh scaler for this
            // input/output pair. Spatial is the "Lanczos-ish" upscaler;
            // doesn't need motion vectors (those would feed the Temporal
            // scaler, which Q3 doesn't have).
            let scalerDesc = MTLFXSpatialScalerDescriptor()
            scalerDesc.inputWidth = inputW
            scalerDesc.inputHeight = inputH
            scalerDesc.outputWidth = outputW
            scalerDesc.outputHeight = outputH
            scalerDesc.colorTextureFormat = .bgra8Unorm
            scalerDesc.outputTextureFormat = .bgra8Unorm
            // .perceptual = source/output are display-encoded (gamma-ish).
            // .linear would be for HDR linear-light buffers.
            scalerDesc.colorProcessingMode = .perceptual
            guard let scaler = scalerDesc.makeSpatialScaler(device: device) else {
                print("[MetalFX] makeSpatialScaler returned nil — device unsupported. Falling back to direct render.")
                return false
            }
            spatialScaler = scaler
            spatialScalerKey = key
            print("[MetalFX] spatial scaler ready: \(inputW)×\(inputH) → \(outputW)×\(outputH) (\(upscaleQuality.label))")
            return true
            #endif
        }

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
        private var fogVolumePipelineState: MTLRenderPipelineState?
        private var sceneDepthTexture: MTLTexture?
        private var sceneDepthTextureSize = MTLSize(width: 0, height: 0, depth: 1)
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

        /* Final-image postprocess tone curve — port of Q2 MetalPostprocess.
         * In-place compute kernel on the drawable: rgb = saturate(rgb *
         * intensity); rgb = pow(rgb, gamma). Encoded after the main render
         * encoder ends and before commandBuffer.present(). Gated by
         * Q3_PostprocessEnabled() — when off, the compute pipeline is
         * never compiled (lazy init in ensurePostprocessPipeline). */
        private var postprocessPipelineState: MTLComputePipelineState?
        private var postprocessEncodeCount: Int = 0
        private var postprocessLogPrintedOnce: Bool = false

        private var worldAccelerationStructure: MTLAccelerationStructure?
        private var rtPipelineState: MTLComputePipelineState?
        private var rtBlendPipelineState: MTLComputePipelineState?
        private var rtTexture: MTLTexture?
        private var rtCompositeTexture: MTLTexture?
        private var rtWhiteTexture: MTLTexture?
        private var rtTextureSize = MTLSize(width: 0, height: 0, depth: 1)
        private var worldASBuilt = false
        private var worldASGeneration: UInt32 = 0
        private var rtASVertexBuffer: MTLBuffer?
        private var rtASPositionBuffer: MTLBuffer?
        private var rtASIndexBuffer: MTLBuffer?
        private var rtPrimitiveMaterialBuffer: MTLBuffer?
        private let rtMaxAlbedoSlots = 110
        private let rtMaxLightmapSlots = 16
        private var rtAlbedoHandles = [UInt32](repeating: 0, count: 110)
        private var rtLightmapHandles = [UInt32](repeating: 0, count: 16)
        private var rtLogPrintedOnce = false
        private var rtOverlayLogPrintedOnce = false

        private struct PostprocessUniforms {
            var intensity: Float
            var gamma: Float
        }

        @MainActor
        private func ensurePostprocessPipeline(device: MTLDevice) -> MTLComputePipelineState? {
            if let postprocessPipelineState { return postprocessPipelineState }
            let src = """
            #include <metal_stdlib>
            using namespace metal;

            struct PPUniforms {
                float intensity;
                float gamma;
            };

            kernel void q3_postprocess(texture2d<float, access::read_write> drawable [[texture(0)]],
                                       constant PPUniforms &u [[buffer(0)]],
                                       uint2 tid [[thread_position_in_grid]]) {
                uint w = drawable.get_width();
                uint h = drawable.get_height();
                if (tid.x >= w || tid.y >= h) return;
                float4 c = drawable.read(tid);
                float3 rgb = saturate(c.rgb * u.intensity);
                rgb = pow(rgb, float3(u.gamma));
                drawable.write(float4(rgb, c.a), tid);
            }
            """
            do {
                let lib = try device.makeLibrary(source: src, options: nil)
                guard let fn = lib.makeFunction(name: "q3_postprocess") else {
                    print("[MTL_POSTPROC] makeFunction failed")
                    return nil
                }
                let pso = try device.makeComputePipelineState(function: fn)
                postprocessPipelineState = pso
                if !postprocessLogPrintedOnce {
                    print("[MTL_POSTPROC] q3_postprocess pipeline ready")
                    postprocessLogPrintedOnce = true
                }
                return pso
            } catch {
                print("[MTL_POSTPROC] compile failed: \(error)")
                return nil
            }
        }

        @MainActor
        private func encodePostprocess(commandBuffer: MTLCommandBuffer,
                                       drawable: CAMetalDrawable) {
            guard Q3_PostprocessEnabled() != 0 else { return }
            guard let device = commandBuffer.device as MTLDevice?,
                  let pso = ensurePostprocessPipeline(device: device),
                  let enc = commandBuffer.makeComputeCommandEncoder() else {
                return
            }
            enc.label = "Q3.postprocess"
            enc.setComputePipelineState(pso)
            enc.setTexture(drawable.texture, index: 0)
            var u = PostprocessUniforms(intensity: Q3_PostprocessIntensity(),
                                        gamma: Q3_PostprocessGamma())
            enc.setBytes(&u, length: MemoryLayout<PostprocessUniforms>.size, index: 0)
            let w = drawable.texture.width
            let h = drawable.texture.height
            let threadsPerThreadgroup = MTLSize(width: 8, height: 8, depth: 1)
            let threadgroups = MTLSize(width: (w + 7) / 8,
                                       height: (h + 7) / 8,
                                       depth: 1)
            enc.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadsPerThreadgroup)
            enc.endEncoding()
            postprocessEncodeCount += 1
            if postprocessEncodeCount == 1 || postprocessEncodeCount % 120 == 0 {
                print("[MTL_POSTPROC] encode #\(postprocessEncodeCount) intensity=\(u.intensity) gamma=\(u.gamma) size=\(w)x\(h)")
            }
        }


        @MainActor
        private func makeRTLibrary(device: MTLDevice) -> MTLLibrary? {
            let src = """
            #include <metal_stdlib>
            #include <metal_raytracing>
            using namespace metal;
            using namespace raytracing;

            struct RayTracingUniforms {
                float4x4 viewProjection;
                float4x4 invViewProjection;
                float4 cameraPos;
                float4 cameraForward;
                float4 cameraRight;
                float4 cameraUp;
                float4 jitterNearFar;
                float4 fovParams;
            };

            struct RTWorldVertex {
                packed_float3 position;
                float2 texCoord;
                float2 lightmapTexCoord;
                packed_float3 normal;
                float4 color;
                float4 autospriteCenter;
                float4 autospriteLongAxis;
                packed_float3 lightingDiffuse;
            };

            struct RTPrimitiveMaterial {
                uint albedoSlot;
                uint lightmapSlot;
                uint tcModCount;
                uint _pad0;
                float4 alphaTcModControl;
                uint4 tcModTypes;
                float4 tcModParams0;
                float4 tcModParams1;
                float4 tcModParams2;
                float4 tcModParams3;
            };

            float2 rtApplyTcMod(float2 uv, float3 worldPos, int type, float4 params, float timeSeconds) {
                if (type == 1) {
                    float2 adj = params.xy * timeSeconds;
                    adj -= floor(adj);
                    return uv + adj;
                } else if (type == 2) {
                    float s = sin(timeSeconds * params.w) * params.y;
                    return uv + float2(s, s);
                } else if (type == 3) {
                    float degrees = fmod(params.x * timeSeconds, 360.0);
                    float a = degrees * (3.14159265 / 180.0);
                    float c = cos(a);
                    float sn = sin(a);
                    float2 p = uv - 0.5;
                    return float2(p.x * c - p.y * sn, p.x * sn + p.y * c) + 0.5;
                } else if (type == 4) {
                    return uv * params.xy;
                } else if (type == 5) {
                    float amp = params.x;
                    float freq = params.y;
                    float phase = params.z;
                    float now = fract(phase + timeSeconds * freq);
                    float kX = (worldPos.x + worldPos.z) * (1.0 / 1024.0) + now;
                    float kY = worldPos.y * (1.0 / 1024.0) + now;
                    float twoPi = 2.0 * 3.14159265;
                    return uv + float2(sin(kX * twoPi) * amp, sin(kY * twoPi) * amp);
                } else if (type == 6) {
                    float angle = 2.0 * 3.14159265 * (params.z + timeSeconds * params.w);
                    float eval = params.x + sin(angle) * params.y;
                    if (abs(eval) < 0.0001) eval = 1.0;
                    return (uv - 0.5) * (1.0 / eval) + 0.5;
                } else if (type == 7) {
                    return float2(uv.x * params.x + uv.y * params.y,
                                  uv.x * params.z + uv.y * params.w);
                } else if (type == 8) {
                    return uv + params.xy;
                }
                return uv;
            }

            kernel void rtKernel(texture2d<float, access::write> output [[texture(0)]],
                                 texturecube<float> envCube [[texture(1)]],
                                 array<texture2d<float>, 110> albedoTextures [[texture(2)]],
                                 array<texture2d<float>, 16> lightmapTextures [[texture(112)]],
                                 constant RayTracingUniforms &uniforms [[buffer(0)]],
                                 acceleration_structure<> worldAS [[buffer(1)]],
                                 const device uint *indices [[buffer(2)]],
                                 const device RTWorldVertex *vertices [[buffer(3)]],
                                 const device RTPrimitiveMaterial *primitiveMaterials [[buffer(4)]],
                                 uint2 tid [[thread_position_in_grid]]) {
                if (tid.x >= output.get_width() || tid.y >= output.get_height()) return;
                float2 uv = (float2(tid) + 0.5) / float2(output.get_width(), output.get_height());
                uv += uniforms.jitterNearFar.xy;
                float2 ndc = uv * 2.0 - 1.0;
                float4 farClip = float4(ndc.x, -ndc.y, 1.0, 1.0);
                float4 farWorld = uniforms.invViewProjection * farClip;
                farWorld.xyz /= max(abs(farWorld.w), 1.0e-6);
                float3 rayDir = normalize(farWorld.xyz - uniforms.cameraPos.xyz);
                ray r(uniforms.cameraPos.xyz, rayDir, uniforms.jitterNearFar.z, uniforms.jitterNearFar.w);
                intersector<triangle_data> i;
                auto hit = i.intersect(r, worldAS);

                float3 color;
                if (hit.type == intersection_type::triangle) {
                    uint tri = hit.primitive_id;
                    uint i0 = indices[tri * 3 + 0];
                    uint i1 = indices[tri * 3 + 1];
                    uint i2 = indices[tri * 3 + 2];
                    float3 n0 = float3(vertices[i0].normal);
                    float3 n1 = float3(vertices[i1].normal);
                    float3 n2 = float3(vertices[i2].normal);
                    float2 bary = hit.triangle_barycentric_coord;
                    float w = 1.0 - bary.x - bary.y;
                    float3 N = n0 * w + n1 * bary.x + n2 * bary.y;
                    if (dot(N, N) < 1.0e-6) {
                        float3 p0 = float3(vertices[i0].position);
                        float3 p1 = float3(vertices[i1].position);
                        float3 p2 = float3(vertices[i2].position);
                        N = cross(p1 - p0, p2 - p0);
                    }
                    N = normalize(N);
                    float3 normalColor = N * 0.5 + 0.5;

                    RTPrimitiveMaterial mat = primitiveMaterials[tri];
                    if (mat.albedoSlot < 110 && mat.lightmapSlot < 16) {
                        float2 uv0 = vertices[i0].texCoord;
                        float2 uv1 = vertices[i1].texCoord;
                        float2 uv2 = vertices[i2].texCoord;
                        float2 lm0 = vertices[i0].lightmapTexCoord;
                        float2 lm1 = vertices[i1].lightmapTexCoord;
                        float2 lm2 = vertices[i2].lightmapTexCoord;
                        float3 hitPos = uniforms.cameraPos.xyz + rayDir * hit.distance;
                        float2 uv = uv0 * w + uv1 * bary.x + uv2 * bary.y;
                        float2 lmuv = lm0 * w + lm1 * bary.x + lm2 * bary.y;
                        uint tcCount = min(mat.tcModCount, 4u);
                        for (uint mi = 0; mi < tcCount; ++mi) {
                            uint type = mat.tcModTypes[mi];
                            if (type == 0) { continue; }
                            float4 params = mat.tcModParams0;
                            if (mi == 1) { params = mat.tcModParams1; }
                            else if (mi == 2) { params = mat.tcModParams2; }
                            else if (mi == 3) { params = mat.tcModParams3; }
                            uv = rtApplyTcMod(uv, hitPos, int(type), params, uniforms.fovParams.z);
                            lmuv = rtApplyTcMod(lmuv, hitPos, int(type), params, uniforms.fovParams.z);
                        }
                        constexpr sampler repeatSampler(filter::linear, address::repeat);
                        constexpr sampler clampSampler(filter::linear, address::clamp_to_edge);
                        constexpr sampler envSampler(filter::linear, address::clamp_to_edge);
                        float4 albedoSample = albedoTextures[mat.albedoSlot].sample(repeatSampler, uv);
                        float alphaThreshold = mat.alphaTcModControl.x;
                        bool alphaReject = (alphaThreshold > 0.0 && albedoSample.a < alphaThreshold) ||
                                           (alphaThreshold < 0.0 && albedoSample.a >= -alphaThreshold);
                        if (alphaReject) {
                            if (!is_null_texture(envCube)) {
                                color = envCube.sample(envSampler, rayDir).rgb;
                            } else {
                                color = float3(0.04, 0.07, 0.13) + float3(0.01, 0.03, 0.06) * (1.0 - ndc.y);
                            }
                        } else {
                            float3 lightmap = lightmapTextures[mat.lightmapSlot].sample(clampSampler, lmuv).rgb;
                            color = albedoSample.rgb * max(lightmap * 2.0, float3(0.18));
                            color = mix(color, normalColor, 0.18);
                        }
                    } else {
                        color = normalColor;
                    }
                } else {
                    constexpr sampler envSampler(filter::linear, address::clamp_to_edge);
                    if (!is_null_texture(envCube)) {
                        color = envCube.sample(envSampler, rayDir).rgb;
                    } else {
                        color = float3(0.04, 0.07, 0.13) + float3(0.01, 0.03, 0.06) * (1.0 - ndc.y);
                    }
                }
                if (any(isnan(color)) || any(isinf(color))) { color = float3(0.0); }
                output.write(float4(saturate(color), 1.0), tid);
            }

            kernel void blendRT(texture2d<float, access::read> rt [[texture(0)]],
                                texture2d<float, access::read> raster [[texture(1)]],
                                texture2d<float, access::write> output [[texture(2)]],
                                constant float &mixAmount [[buffer(0)]],
                                uint2 tid [[thread_position_in_grid]]) {
                if (tid.x >= output.get_width() || tid.y >= output.get_height()) return;
                float m = saturate(mixAmount);
                float3 rtColor = saturate(rt.read(tid).rgb);
                if (m >= 0.999) {
                    output.write(float4(rtColor, 1.0), tid);
                    return;
                }
                float3 rasterColor = saturate(raster.read(tid).rgb);
                float3 blended = mix(rasterColor, rtColor, m);
                output.write(float4(blended, 1.0), tid);
            }
            """
            let opts = MTLCompileOptions()
            opts.languageVersion = .version2_4
            do { return try device.makeLibrary(source: src, options: opts) }
            catch { print("[RT] library compile failed: \(error)"); return nil }
        }

        @MainActor
        private func ensureRTPipeline(device: MTLDevice) -> MTLComputePipelineState? {
            if let rtPipelineState { return rtPipelineState }
            guard device.supportsRaytracing else {
                if !rtLogPrintedOnce { print("[RT] skipped: device/simulator does not support Metal ray tracing"); rtLogPrintedOnce = true }
                return nil
            }
            guard let lib = makeRTLibrary(device: device), let fn = lib.makeFunction(name: "rtKernel") else {
                print("[RT] failed to create rtKernel"); return nil
            }
            do { let pso = try device.makeComputePipelineState(function: fn); rtPipelineState = pso; print("[RT] rtKernel pipeline ready"); return pso }
            catch { print("[RT] pipeline state error: \(error)"); return nil }
        }

        @MainActor
        private func ensureRTBlendPipeline(device: MTLDevice) -> MTLComputePipelineState? {
            if let rtBlendPipelineState { return rtBlendPipelineState }
            guard let lib = makeRTLibrary(device: device), let fn = lib.makeFunction(name: "blendRT") else {
                print("[RT] failed to create blendRT"); return nil
            }
            do { let pso = try device.makeComputePipelineState(function: fn); rtBlendPipelineState = pso; print("[RT] blendRT pipeline ready"); return pso }
            catch { print("[RT] blend pipeline state error: \(error)"); return nil }
        }


        @MainActor
        private func buildRTPrimitiveMaterials(device: MTLDevice, primitiveCount: Int) {
            let invalid = UInt32.max
            let invalidMaterial = RTPrimitiveMaterial(
                albedoSlot: invalid,
                lightmapSlot: invalid,
                tcModCount: 0,
                _pad0: 0,
                alphaTcModControl: SIMD4<Float>(0, 0, 0, 0),
                tcModTypes: SIMD4<UInt32>(0, 0, 0, 0),
                tcModParams0: SIMD4<Float>(0, 0, 0, 0),
                tcModParams1: SIMD4<Float>(0, 0, 0, 0),
                tcModParams2: SIMD4<Float>(0, 0, 0, 0),
                tcModParams3: SIMD4<Float>(0, 0, 0, 0))
            var materials = [RTPrimitiveMaterial](repeating: invalidMaterial, count: primitiveCount)
            rtAlbedoHandles = [UInt32](repeating: 0, count: rtMaxAlbedoSlots)
            rtLightmapHandles = [UInt32](repeating: 0, count: rtMaxLightmapSlots)

            guard let drawsPtr = Q3MetalRenderer_GetWorldAllDrawCommands() else {
                rtPrimitiveMaterialBuffer = device.makeBuffer(bytes: materials,
                                                              length: materials.count * MemoryLayout<RTPrimitiveMaterial>.stride,
                                                              options: .storageModeShared)
                return
            }

            let drawCount = Int(Q3MetalRenderer_GetWorldAllDrawCommandCount())
            let draws = UnsafeBufferPointer(start: drawsPtr, count: drawCount)

            /* Pick the 16 most important handles by covered triangle count,
             * not the first 16 encountered. The first-come table made large
             * late BSP surfaces fall back to normal debug magenta/cyan while
             * tiny early detail draws consumed slots. */
            var albedoWeights: [UInt32: Int] = [:]
            var lightmapWeights: [UInt32: Int] = [:]
            let fogOnlyBit = UInt32(Q3_METAL_WORLD_DRAWFLAG_FOG_ONLY)
            for draw in draws where draw.indexCount >= 3 {
                if (draw.flags & fogOnlyBit) != 0 { continue }
                let stageCount = min(Int(draw.stageCount), Int(Q3_METAL_MAX_STAGES))
                guard stageCount > 0 else { continue }
                let triCount = max(1, Int(draw.indexCount / 3))
                let stage = Self.worldStage(draw, 0)
                if stage.useLightmap == 0 && stage.textureHandle != 0 {
                    albedoWeights[stage.textureHandle, default: 0] += triCount
                }
                if draw.lightmapTextureHandle != 0 {
                    lightmapWeights[draw.lightmapTextureHandle, default: 0] += triCount
                }
            }

            func topHandles(_ weights: [UInt32: Int], limit: Int) -> [UInt32] {
                Array(weights.sorted { lhs, rhs in
                    if lhs.value != rhs.value { return lhs.value > rhs.value }
                    return lhs.key < rhs.key
                }.prefix(limit).map { $0.key })
            }

            let topAlbedos = topHandles(albedoWeights, limit: rtMaxAlbedoSlots)
            let topLightmaps = topHandles(lightmapWeights, limit: rtMaxLightmapSlots)
            for (i, h) in topAlbedos.enumerated() {
                rtAlbedoHandles[i] = h
                _ = texture(for: h, device: device)
            }
            for (i, h) in topLightmaps.enumerated() {
                rtLightmapHandles[i] = h
                _ = texture(for: h, device: device)
            }
            let albedoSlots = Dictionary(uniqueKeysWithValues: topAlbedos.enumerated().map { (UInt32($0.offset), $0.element) }.map { ($0.1, $0.0) })
            let lightmapSlots = Dictionary(uniqueKeysWithValues: topLightmaps.enumerated().map { (UInt32($0.offset), $0.element) }.map { ($0.1, $0.0) })

            var assigned = 0
            var skippedOverwrite = 0
            for draw in draws where draw.indexCount >= 3 {
                if (draw.flags & fogOnlyBit) != 0 { continue }
                let stageCount = min(Int(draw.stageCount), Int(Q3_METAL_MAX_STAGES))
                guard stageCount > 0 else { continue }
                let stage = Self.worldStage(draw, 0)
                guard stage.useLightmap == 0,
                      let aSlot = albedoSlots[stage.textureHandle],
                      let lSlot = lightmapSlots[draw.lightmapTextureHandle] else { continue }
                let firstTri = Int(draw.firstIndex / 3)
                let triCount = Int(draw.indexCount / 3)
                guard firstTri < materials.count else { continue }
                let end = min(firstTri + triCount, materials.count)
                for tri in firstTri..<end {
                    if materials[tri].albedoSlot == invalid {
                        let chain = Self.fillTcMods(stage)
                        let tcCount = UInt32(max(0, min(Int(chain.count), 4)))
                        let tcTypes = SIMD4<UInt32>(
                            tcCount > 0 ? UInt32(max(0, Int(stage.tcMods.0.type))) : 0,
                            tcCount > 1 ? UInt32(max(0, Int(stage.tcMods.1.type))) : 0,
                            tcCount > 2 ? UInt32(max(0, Int(stage.tcMods.2.type))) : 0,
                            tcCount > 3 ? UInt32(max(0, Int(stage.tcMods.3.type))) : 0)
                        let alphaThreshold = Self.alphaTestThreshold(for: stage.alphaFunc)
                        materials[tri] = RTPrimitiveMaterial(
                            albedoSlot: aSlot,
                            lightmapSlot: lSlot,
                            tcModCount: tcCount,
                            _pad0: 0,
                            alphaTcModControl: SIMD4<Float>(alphaThreshold, Float(tcCount), 0, 0),
                            tcModTypes: tcTypes,
                            tcModParams0: chain.p0,
                            tcModParams1: chain.p1,
                            tcModParams2: chain.p2,
                            tcModParams3: chain.p3)
                        assigned += 1
                    } else {
                        skippedOverwrite += 1
                    }
                }
            }
            rtPrimitiveMaterialBuffer = device.makeBuffer(bytes: materials,
                                                          length: materials.count * MemoryLayout<RTPrimitiveMaterial>.stride,
                                                          options: .storageModeShared)
            rtPrimitiveMaterialBuffer?.label = "Q3.RT.primitiveMaterials"
            print("[RT] material table: albedo=\(topAlbedos.count)/\(albedoWeights.count) lightmap=\(topLightmaps.count)/\(lightmapWeights.count) assigned=\(assigned)/\(primitiveCount) skippedOverwrite=\(skippedOverwrite)")
        }

        @MainActor
        private func buildWorldAccelerationStructure(device: MTLDevice) -> MTLAccelerationStructure? {
            guard device.supportsRaytracing, Q3MetalRenderer_IsWorldLoaded() != 0 else { return nil }
            guard let ib = worldIndexBuffer else { return nil }
            let vertexCount = Int(Q3MetalRenderer_GetWorldVertexCount())
            let indexCount = Int(Q3MetalRenderer_GetWorldIndexCount())
            guard vertexCount > 0, indexCount >= 3, let src = Q3MetalRenderer_GetWorldVertices() else { return nil }

            let verts = UnsafeBufferPointer(start: src, count: vertexCount)
            var compactPositions = [Float]()
            compactPositions.reserveCapacity(vertexCount * 3)
            for v in verts {
                compactPositions.append(v.position.0)
                compactPositions.append(v.position.1)
                compactPositions.append(v.position.2)
            }
            guard let positionBuffer = device.makeBuffer(bytes: compactPositions,
                                                         length: compactPositions.count * MemoryLayout<Float>.stride,
                                                         options: .storageModeShared) else {
                print("[RT] AS compact position buffer allocation failed")
                return nil
            }
            positionBuffer.label = "Q3.RT.positions.compact"
            rtASPositionBuffer = positionBuffer

            buildRTPrimitiveMaterials(device: device, primitiveCount: indexCount / 3)

            let geomDesc = MTLAccelerationStructureTriangleGeometryDescriptor()
            geomDesc.vertexBuffer = positionBuffer
            geomDesc.vertexBufferOffset = 0
            geomDesc.vertexStride = 3 * MemoryLayout<Float>.stride
            geomDesc.vertexFormat = .float3
            geomDesc.indexBuffer = ib
            geomDesc.indexBufferOffset = 0
            geomDesc.indexType = .uint32
            geomDesc.triangleCount = indexCount / 3
            geomDesc.opaque = true
            let asDesc = MTLPrimitiveAccelerationStructureDescriptor()
            asDesc.geometryDescriptors = [geomDesc]
            let sizes = device.accelerationStructureSizes(descriptor: asDesc)
            guard let scratch = device.makeBuffer(length: sizes.buildScratchBufferSize, options: .storageModePrivate),
                  let accel = device.makeAccelerationStructure(size: sizes.accelerationStructureSize),
                  let queue = commandQueue,
                  let cb = queue.makeCommandBuffer(),
                  let enc = cb.makeAccelerationStructureCommandEncoder() else {
                print("[RT] AS build allocation failed"); return nil
            }
            accel.label = "Q3.RT.worldAS"
            scratch.label = "Q3.RT.worldAS.scratch"
            enc.label = "Q3.RT.buildWorldAS"
            enc.build(accelerationStructure: accel, descriptor: asDesc, scratchBuffer: scratch, scratchBufferOffset: 0)
            enc.endEncoding()
            cb.commit(); cb.waitUntilCompleted()
            if let err = cb.error { print("[RT] AS build failed: \(err)"); return nil }
            rtASVertexBuffer = worldVertexBuffer; rtASIndexBuffer = ib
            print("[RT] built world AS: vertices=\(vertexCount) indices=\(indexCount) tris=\(indexCount / 3) size=\(sizes.accelerationStructureSize)")
            return accel
        }

        @MainActor
        private func ensureRTTextures(device: MTLDevice, width: Int, height: Int, pixelFormat: MTLPixelFormat) -> Bool {
            let w = max(width, 1), h = max(height, 1)
            if rtTexture != nil && rtCompositeTexture != nil && rtTextureSize.width == w && rtTextureSize.height == h { return true }
            let rtDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
            rtDesc.usage = [.shaderRead, .shaderWrite]; rtDesc.storageMode = .private
            let compDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: pixelFormat, width: w, height: h, mipmapped: false)
            compDesc.usage = [.shaderRead, .shaderWrite]; compDesc.storageMode = .private
            rtTexture = device.makeTexture(descriptor: rtDesc)
            rtCompositeTexture = device.makeTexture(descriptor: compDesc)
            rtTexture?.label = "Q3.RT.output"; rtCompositeTexture?.label = "Q3.RT.composite"
            rtTextureSize = MTLSize(width: w, height: h, depth: 1)
            return rtTexture != nil && rtCompositeTexture != nil
        }


        @MainActor
        private func ensureRTWhiteTexture(device: MTLDevice) -> MTLTexture? {
            if let rtWhiteTexture { return rtWhiteTexture }
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
            desc.usage = [.shaderRead]
            desc.storageMode = .shared
            guard let tex = device.makeTexture(descriptor: desc) else { return nil }
            var pixel: UInt32 = 0xffffffff
            withUnsafeBytes(of: &pixel) { bytes in
                tex.replace(region: MTLRegionMake2D(0, 0, 1, 1),
                            mipmapLevel: 0,
                            withBytes: bytes.baseAddress!,
                            bytesPerRow: 4)
            }
            tex.label = "Q3.RT.whiteFallback"
            rtWhiteTexture = tex
            return tex
        }

        @MainActor
        private func encodeRTOverlay(commandBuffer: MTLCommandBuffer,
                                     rasterTexture: MTLTexture,
                                     outputDrawableTexture: MTLTexture,
                                     device: MTLDevice,
                                     sceneView: Q3MetalSceneView,
                                     renderW: Int,
                                     renderH: Int) -> MTLTexture? {
            let mixValue = Q3_RTMix()
            guard mixValue > 0 else { return nil }
            guard device.supportsRaytracing else {
                if !rtLogPrintedOnce { print("[RT] disabled: current device/simulator does not support acceleration structures"); rtLogPrintedOnce = true }
                return nil
            }
            guard worldASBuilt, let worldAS = worldAccelerationStructure else { return nil }
            guard let primitiveMaterialBuffer = rtPrimitiveMaterialBuffer else { return nil }
            guard let rtPSO = ensureRTPipeline(device: device), let blendPSO = ensureRTBlendPipeline(device: device) else { return nil }
            guard ensureRTTextures(device: device, width: renderW, height: renderH, pixelFormat: rasterTexture.pixelFormat),
                  let rtTex = rtTexture, let compositeTex = rtCompositeTexture else { return nil }

            let viewProj = makeWorldViewProjection(sceneView)
            let cameraPos = SIMD3<Float>(sceneView.viewOrigin.0, sceneView.viewOrigin.1, sceneView.viewOrigin.2)
            let forward = SIMD3<Float>(sceneView.viewAxis.0, sceneView.viewAxis.1, sceneView.viewAxis.2)
            let right = SIMD3<Float>(-sceneView.viewAxis.3, -sceneView.viewAxis.4, -sceneView.viewAxis.5)
            let up = SIMD3<Float>(sceneView.viewAxis.6, sceneView.viewAxis.7, sceneView.viewAxis.8)
            var uniforms = RayTracingUniforms(viewProjection: viewProj,
                                              invViewProjection: simd_inverse(viewProj),
                                              cameraPos: SIMD4<Float>(cameraPos.x, cameraPos.y, cameraPos.z, 0),
                                              cameraForward: SIMD4<Float>(forward.x, forward.y, forward.z, 0),
                                              cameraRight: SIMD4<Float>(right.x, right.y, right.z, 0),
                                              cameraUp: SIMD4<Float>(up.x, up.y, up.z, 0),
                                              jitterNearFar: SIMD4<Float>(0, 0, 4.0, 8192.0),
                                              fovParams: SIMD4<Float>(tan(sceneView.fovX * .pi / 360.0), tan(sceneView.fovY * .pi / 360.0), Float(CACurrentMediaTime() - frameTimeOrigin), 0))
            if !rtOverlayLogPrintedOnce {
                print("[RT] overlay active mix=\(mixValue) size=\(renderW)x\(renderH) camera=\(cameraPos)")
                rtOverlayLogPrintedOnce = true
            }
            let tg = MTLSize(width: 16, height: 16, depth: 1)
            let groups = MTLSize(width: (renderW + 15) / 16, height: (renderH + 15) / 16, depth: 1)
            if let enc = commandBuffer.makeComputeCommandEncoder() {
                enc.label = "Q3.RT.trace"
                enc.setComputePipelineState(rtPSO)
                enc.setTexture(rtTex, index: 0)
                enc.setTexture(ensurePBREnvCube(), index: 1)
                let fallbackTex = ensureRTWhiteTexture(device: device)
                for i in 0..<rtMaxAlbedoSlots {
                    enc.setTexture(texture(for: rtAlbedoHandles[i], device: device) ?? fallbackTex, index: 2 + i)
                }
                for i in 0..<rtMaxLightmapSlots {
                    enc.setTexture(texture(for: rtLightmapHandles[i], device: device) ?? fallbackTex, index: 112 + i)
                }
                enc.setBytes(&uniforms, length: MemoryLayout<RayTracingUniforms>.stride, index: 0)
                enc.setAccelerationStructure(worldAS, bufferIndex: 1)
                enc.setBuffer(rtASIndexBuffer, offset: 0, index: 2)
                enc.setBuffer(rtASVertexBuffer, offset: 0, index: 3)
                enc.setBuffer(primitiveMaterialBuffer, offset: 0, index: 4)
                enc.dispatchThreadgroups(groups, threadsPerThreadgroup: tg)
                enc.endEncoding()
            }
            var m = mixValue
            if let enc = commandBuffer.makeComputeCommandEncoder() {
                enc.label = "Q3.RT.blend"
                enc.setComputePipelineState(blendPSO)
                enc.setTexture(rtTex, index: 0)
                enc.setTexture(rasterTexture, index: 1)
                enc.setTexture(compositeTex, index: 2)
                enc.setBytes(&m, length: MemoryLayout<Float>.stride, index: 0)
                enc.dispatchThreadgroups(groups, threadsPerThreadgroup: tg)
                enc.endEncoding()
            }
            if rasterTexture === outputDrawableTexture, let blit = commandBuffer.makeBlitCommandEncoder() {
                blit.label = "Q3.RT.copyCompositeToDrawable"
                blit.copy(from: compositeTex, sourceSlice: 0, sourceLevel: 0,
                          sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                          sourceSize: MTLSize(width: renderW, height: renderH, depth: 1),
                          to: outputDrawableTexture, destinationSlice: 0, destinationLevel: 0,
                          destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
                blit.endEncoding()
                return nil
            }
            return compositeTex
        }

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

        private func ensureSceneDepthTexture(device: MTLDevice, width: Int, height: Int) -> MTLTexture? {
            let w = max(width, 1)
            let h = max(height, 1)
            if let sceneDepthTexture,
               sceneDepthTextureSize.width == w,
               sceneDepthTextureSize.height == h {
                return sceneDepthTexture
            }
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float,
                                                                width: w,
                                                                height: h,
                                                                mipmapped: false)
            desc.usage = [.renderTarget, .shaderRead]
            desc.storageMode = .private
            let tex = device.makeTexture(descriptor: desc)
            tex?.label = "Q3.scene.depth.shaderRead"
            sceneDepthTexture = tex
            sceneDepthTextureSize = MTLSize(width: w, height: h, depth: 1)
            return tex
        }

        private func hasRenderableFogVolume() -> Bool {
            /* Stock Q3 fog is the BSP fog overlay plus per-surface fog pass.
             * The ray-box pass is only safe when the eye is actually inside a
             * fog brush (see encodeFogVolumeRayBox); otherwise the brush AABB
             * reads as a rectangular fog slab over adjacent rooms. Keep a kill
             * switch for A/B, but default on with the inside-volume gate. */
            guard ProcessInfo.processInfo.environment["Q3_METAL_DISABLE_RAYBOX_FOG"] != "1" else { return false }
            guard fogVolumePipelineState != nil,
                  let fogs = Q3MetalRenderer_GetWorldFogs() else { return false }
            let fogCount = Int(Q3MetalRenderer_GetWorldFogCount())
            guard fogCount > 0 else { return false }
            for fogIndex in 0..<fogCount {
                let fog = fogs.advanced(by: fogIndex).pointee
                if fog.distance > 0, fog.hasBounds != 0 {
                    let rawMin = SIMD3<Float>(fog.boundsMin.0, fog.boundsMin.1, fog.boundsMin.2)
                    let rawMax = SIMD3<Float>(fog.boundsMax.0, fog.boundsMax.1, fog.boundsMax.2)
                    let span = simd_max(rawMin, rawMax) - simd_min(rawMin, rawMax)
                    if span.x > 1, span.y > 1, span.z > 1 { return true }
                }
            }
            return false
        }

        private func makeLoadedRenderPassDescriptor(colorTexture: MTLTexture,
                                                    depthTexture: MTLTexture?) -> MTLRenderPassDescriptor {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = colorTexture
            pass.colorAttachments[0].loadAction = .load
            pass.colorAttachments[0].storeAction = .store
            if let depthTexture {
                pass.depthAttachment.texture = depthTexture
                pass.depthAttachment.loadAction = .load
                pass.depthAttachment.storeAction = .store
            }
            return pass
        }

        private func encodeFogVolumeRayBox(commandBuffer: MTLCommandBuffer,
                                           colorTexture: MTLTexture,
                                           depthTexture: MTLTexture,
                                           device: MTLDevice,
                                           sceneView: Q3MetalSceneView) {
            guard let fogVolumePipelineState,
                  let fogs = Q3MetalRenderer_GetWorldFogs() else { return }
            let fogCount = Int(Q3MetalRenderer_GetWorldFogCount())
            guard fogCount > 0 else { return }

            let viewProjection = makeWorldViewProjection(sceneView)
            let cameraPos = SIMD3<Float>(sceneView.viewOrigin.0,
                                         sceneView.viewOrigin.1,
                                         sceneView.viewOrigin.2)

            if !fogVolumeLogged {
                var parts: [String] = []
                for fogIndex in 0..<fogCount {
                    let fog = fogs.advanced(by: fogIndex).pointee
                    parts.append("#\(fogIndex) dist=\(fog.distance) hasBounds=\(fog.hasBounds) min=(\(fog.boundsMin.0),\(fog.boundsMin.1),\(fog.boundsMin.2)) max=(\(fog.boundsMax.0),\(fog.boundsMax.1),\(fog.boundsMax.2)) hasSurface=\(fog.hasSurface) surface=(\(fog.surface.0),\(fog.surface.1),\(fog.surface.2),\(fog.surface.3))")
                }
                print("[Metal] fog volume depth-limited ray-box pass count=\(fogCount) \(parts.joined(separator: " | "))")
                fogVolumeLogged = true
            }

            let fogPass = makeLoadedRenderPassDescriptor(colorTexture: colorTexture, depthTexture: nil)
            guard let fogEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: fogPass) else { return }
            fogEncoder.label = "Q3.fog.depthLimitedRayBox"
            fogEncoder.setViewport(MTLViewport(originX: 0,
                                               originY: 0,
                                               width: Double(colorTexture.width),
                                               height: Double(colorTexture.height),
                                               znear: 0.0,
                                               zfar: 1.0))
            fogEncoder.setRenderPipelineState(fogVolumePipelineState)
            fogEncoder.setCullMode(.none)
            fogEncoder.setFrontFacing(.clockwise)
            fogEncoder.setFragmentTexture(depthTexture, index: 0)

            for fogIndex in 0..<fogCount {
                let fog = fogs.advanced(by: fogIndex).pointee
                guard fog.distance > 0, fog.hasBounds != 0 else { continue }

                let rawMin = SIMD3<Float>(fog.boundsMin.0, fog.boundsMin.1, fog.boundsMin.2)
                let rawMax = SIMD3<Float>(fog.boundsMax.0, fog.boundsMax.1, fog.boundsMax.2)
                let bmin = simd_min(rawMin, rawMax)
                let bmax = simd_max(rawMin, rawMax)
                let span = bmax - bmin
                guard span.x > 1, span.y > 1, span.z > 1 else { continue }

                let surface = SIMD4<Float>(fog.surface.0, fog.surface.1, fog.surface.2, fog.surface.3)
                /* The ray-box is a true in-fog volume integration pass.
                 * It must only run while the eye is actually inside the fog
                 * brush.  When run from outside, the AABB projects across
                 * adjacent rooms and looks like the fog "takes over" the map
                 * as the demo camera moves.  Stock Q3's outside view is
                 * already covered by the per-surface fog/cap passes above;
                 * keep an explicit override only for GPU-capture A/B. */
                if ProcessInfo.processInfo.environment["Q3_METAL_FOG_RAYBOX_ALLOW_OUTSIDE"] != "1" {
                    if fog.hasSurface != 0 {
                        let eyeT = simd_dot(cameraPos, SIMD3<Float>(surface.x, surface.y, surface.z)) - surface.w
                        if eyeT < 0 { continue }
                    }
                    let boundsMargin: Float = 0.5
                    guard cameraPos.x >= bmin.x - boundsMargin,
                          cameraPos.x <= bmax.x + boundsMargin,
                          cameraPos.y >= bmin.y - boundsMargin,
                          cameraPos.y <= bmax.y + boundsMargin,
                          cameraPos.z >= bmin.z - boundsMargin,
                          cameraPos.z <= bmax.z + boundsMargin else {
                        continue
                    }
                }
                let fogDistance = max(fog.distance, 1.0)
                let rayDensity = min(max(2.0 / fogDistance, 0.00035), 0.0014)
                var uniforms = FogVolumeUniforms(
                    viewProjection: viewProjection,
                    inverseViewProjection: simd_inverse(viewProjection),
                    cameraPos: cameraPos,
                    fogColorDistance: SIMD4<Float>(fog.color.0, fog.color.1, fog.color.2, fog.distance),
                    boundsMin: SIMD4<Float>(bmin.x, bmin.y, bmin.z, 0),
                    boundsMax: SIMD4<Float>(bmax.x, bmax.y, bmax.z, 0),
                    fogSurface: surface,
                    fogParams: SIMD4<Float>(rayDensity, 0, 0, 0))
                fogEncoder.setVertexBytes(&uniforms, length: MemoryLayout<FogVolumeUniforms>.stride, index: 1)
                fogEncoder.setFragmentBytes(&uniforms, length: MemoryLayout<FogVolumeUniforms>.stride, index: 1)
                fogEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            }
            fogEncoder.endEncoding()
        }
        private var textureCache: [UInt32: (generation: UInt32, texture: MTLTexture)] = [:]

        /* PBR Phase 1: per-Q3-handle HD albedo cache. When the C-side
         * texture register hook stamps a metalTexture_t.pbrMaterial,
         * the Swift entity/world bind paths consult this cache. On
         * miss, we synchronously load the DDS via MTKTextureLoader
         * (sync is fine for the small ~50-file curated subset; async
         * upload is a Phase 2 optimization). DDS textures on Apple
         * Silicon use the native BC1/BC3/BC5/BC7 hardware decoders. */
        private var pbrAlbedoCache: [UInt32: MTLTexture] = [:]
        private var pbrNormalCache: [UInt32: MTLTexture] = [:]
        /// Phase 4 — Cook-Torrance specular needs roughness (sharpness of
        /// the highlight, 0=mirror to 1=matte) and metallic (0=plastic
        /// dielectric to 1=metal that tints highlights by base color).
        /// Both maps load lazily on first bind of a material that has
        /// them populated in materials_by_name.
        private var pbrRoughnessCache: [UInt32: MTLTexture] = [:]
        private var pbrMetallicCache: [UInt32: MTLTexture] = [:]
        /// Phase 6+ extension — 1×1 R8Unorm constant fallback textures.
        /// When a material has albedo or normal but no explicit roughness
        /// or metallic DDS, these shim into the texture(3)/(4) bindings so
        /// the MSL `hasFullPBR` check evaluates true and the weapon enters
        /// the Cook-Torrance + IBL block with default values (0.55 rough,
        /// 0.50 metal). Brings shotgun / lightning / railgun / grenade /
        /// BFG up to the same shading path as the rocket without needing
        /// per-weapon DDS authoring. Built once on first request; shared
        /// pointer across all handles falling back. Values match the
        /// in-MSL default constants used pre-Phase 6 (see q3_entity_fragment
        /// `roughness = 0.55; metallic = 0.50;`).
        private var pbrRoughnessDefaultTex: MTLTexture?
        private var pbrRoughnessDefaultAttempted = false
        private var pbrMetallicDefaultTex: MTLTexture?
        private var pbrMetallicDefaultAttempted = false
        /// Phase 6 — IBL environment cubemap. Procedural sky-gradient cube
        /// (bright blue top → warm horizon → dark ground), 64²×6, mipmapped.
        /// Built once on first call to `ensurePBREnvCube()` and reused for
        /// every entity draw. `pbrEnvSampler` is a dedicated clampToEdge
        /// sampler at fragment sampler slot 1 (sampler slot 0 stays the
        /// per-draw routing between repeat/clamp for the 2D textures).
        private var pbrEnvCube: MTLTexture?
        private var pbrEnvCubeAttempted = false
        private var pbrEnvSampler: MTLSamplerState?
        /// Phase 6 v3 — the stem (e.g., "env/space1") the current pbrEnvCube
        /// was built from. Compared against the live r_pbr_ibl_skybox cvar at
        /// the top of each ensurePBREnvCube() call; mismatch invalidates the
        /// cached cube + flags the lazy builder to try again. Lets the
        /// in-engine sky-shader auto-publisher (C-side GetSkyFaceTextureForSurface)
        /// drive per-map IBL swaps seamlessly without restart. Sentinel
        /// "<procedural>" marks the procedural-fallback path so subsequent
        /// frames don't re-attempt the FS loader once it has been determined
        /// to miss for the current stem.
        private var pbrEnvCubeStem: String?
        private var pbrTriedAndMissed: Set<UInt32> = []
        private var pbrNormalTried: Set<UInt32> = []
        private var pbrRoughnessTried: Set<UInt32> = []
        private var pbrMetallicTried: Set<UInt32> = []
        /// Phase 3 — single global normal map applied to ALL world surfaces
        /// when r_pbrMaterials is on. Loads once on first world-fragment
        /// call; nil while still loading or if the DDS is missing. The
        /// q3_world_fragment MSL guards with is_null_texture(), so a nil
        /// binding produces vanilla rendering.
        private var pbrWorldNormalTexture: MTLTexture?
        private var pbrWorldNormalAttempted = false
        private lazy var pbrTextureLoader: MTKTextureLoader? = {
            guard let dev = self.commandQueue?.device else { return nil }
            return MTKTextureLoader(device: dev)
        }()

        /// Returns the PBR albedo texture for a Q3 handle, or nil when
        /// no PBR material was bound or the DDS load fails. First call
        /// per handle does the load; subsequent calls hit the cache.
        /* Route PBR-Swift logs through the C telemetry pipeline so they
         * land in Documents/q3_diag.log next to the C-side [Q3-PBR] lines. */
        private func pbrLog(_ message: String) {
            "metal_pbr_swift".withCString { typePtr in
                message.withCString { msgPtr in
                    Q3MetalRenderer_SwiftPBRLog(typePtr, msgPtr)
                }
            }
        }

        private func pbrAlbedoTexture(for handle: UInt32) -> MTLTexture? {
            if let cached = pbrAlbedoCache[handle] { return cached }
            if pbrTriedAndMissed.contains(handle) { return nil }
            guard let matPtr = Q3MetalRenderer_GetPBRMaterial(handle) else {
                pbrTriedAndMissed.insert(handle); return nil
            }
            let mat = matPtr.pointee
            guard let albedoCStr = mat.albedo else {
                pbrLog("[Q3-PBR-SWIFT] no-albedo handle=\(handle) (material found but albedo slot is NULL)")
                pbrTriedAndMissed.insert(handle); return nil
            }
            let path = String(cString: albedoCStr)
            guard let loader = pbrTextureLoader else {
                pbrLog("[Q3-PBR-SWIFT] no-loader handle=\(handle) path=\(path)")
                pbrTriedAndMissed.insert(handle); return nil
            }
            pbrLog("[Q3-PBR-SWIFT] trying handle=\(handle) path=\(path)")
            let url = URL(fileURLWithPath: path)
            let opts: [MTKTextureLoader.Option: Any] = [
                .SRGB:                NSNumber(value: true),   // albedo is color data
                .textureUsage:        NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
                .textureStorageMode:  NSNumber(value: MTLStorageMode.private.rawValue),
                .generateMipmaps:     NSNumber(value: false),  // DDS already ships mips
            ]
            do {
                let tex = try loader.newTexture(URL: url, options: opts)
                tex.label = "Q3.pbr.albedo.h\(handle)"
                pbrAlbedoCache[handle] = tex
                pbrLog("[Q3-PBR-SWIFT] loaded albedo handle=\(handle) size=\(tex.width)x\(tex.height) path=\(path)")
                return tex
            } catch {
                pbrLog("[Q3-PBR-SWIFT] DDS load FAILED handle=\(handle) err=\(error.localizedDescription) path=\(path)")
                pbrTriedAndMissed.insert(handle)
                return nil
            }
        }

        /// Returns the PBR normal map texture for a Q3 handle, or nil
        /// when the material has no normal slot or the load fails.
        /// Note: normal maps are NOT sRGB — they encode tangent-space
        /// vector data, so .SRGB must be false. Without that, the GPU
        /// would gamma-correct the .xyz fields and the per-pixel normals
        /// would point in the wrong direction.
        private func pbrNormalTexture(for handle: UInt32) -> MTLTexture? {
            if let cached = pbrNormalCache[handle] { return cached }
            if pbrNormalTried.contains(handle) { return nil }
            pbrNormalTried.insert(handle)
            guard let matPtr = Q3MetalRenderer_GetPBRMaterial(handle) else { return nil }
            let mat = matPtr.pointee
            // Phase 4b — generic normal fallback. If material has albedo
            // but no normal (railgun / grenade / bfg currently), return
            // the cached shotgun.n.rtex.dds as a generic surface relief
            // map. This puts the Phase 4 Fresnel rim on more weapons
            // without requiring per-weapon authored normals.
            // Skips when albedo is also null (shotgun's case — but shotgun
            // DOES have its own normal so this branch never fires for it).
            if mat.normal == nil {
                if mat.albedo != nil {
                    if let generic = pbrGenericFallbackNormal() {
                        pbrNormalCache[handle] = generic
                        pbrLog("[Q3-PBR-SWIFT] generic-normal fallback handle=\(handle)")
                        return generic
                    }
                }
                return nil
            }
            guard let normalCStr = mat.normal else { return nil }
            let path = String(cString: normalCStr)
            guard let loader = pbrTextureLoader else { return nil }
            pbrLog("[Q3-PBR-SWIFT] trying-normal handle=\(handle) path=\(path)")
            let url = URL(fileURLWithPath: path)
            let opts: [MTKTextureLoader.Option: Any] = [
                .SRGB:                NSNumber(value: false),  // vector data, NOT color
                .textureUsage:        NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
                .textureStorageMode:  NSNumber(value: MTLStorageMode.private.rawValue),
                .generateMipmaps:     NSNumber(value: false),
            ]
            do {
                let tex = try loader.newTexture(URL: url, options: opts)
                tex.label = "Q3.pbr.normal.h\(handle)"
                pbrNormalCache[handle] = tex
                pbrLog("[Q3-PBR-SWIFT] loaded normal handle=\(handle) size=\(tex.width)x\(tex.height) path=\(path)")
                return tex
            } catch {
                pbrLog("[Q3-PBR-SWIFT] normal DDS load FAILED handle=\(handle) err=\(error.localizedDescription) path=\(path)")
                return nil
            }
        }

        /// Phase 4b — generic fallback normal. Single bundled shotgun.n
        /// DDS (256² ≈ 87 KB, smaller than rocket_body which is 1.4 MB
        /// at 1024²). Loaded once, shared across all handles whose
        /// material has albedo but no normal of its own.
        private var pbrGenericNormalTex: MTLTexture?
        private var pbrGenericNormalAttempted = false
        private func pbrGenericFallbackNormal() -> MTLTexture? {
            if pbrGenericNormalTex != nil { return pbrGenericNormalTex }
            if pbrGenericNormalAttempted { return nil }
            pbrGenericNormalAttempted = true
            guard let loader = pbrTextureLoader else { return nil }
            guard let bundleRoot = Bundle.main.resourcePath else { return nil }
            let path = bundleRoot + "/baseq3/pbr/assets/ingested/shotgun.n.rtex.dds"
            let url = URL(fileURLWithPath: path)
            let opts: [MTKTextureLoader.Option: Any] = [
                .SRGB:                NSNumber(value: false),
                .textureUsage:        NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
                .textureStorageMode:  NSNumber(value: MTLStorageMode.private.rawValue),
                .generateMipmaps:     NSNumber(value: false),
            ]
            do {
                let tex = try loader.newTexture(URL: url, options: opts)
                tex.label = "Q3.pbr.normal.generic.shotgun_n"
                pbrGenericNormalTex = tex
                pbrLog("[Q3-PBR-SWIFT] loaded generic-normal size=\(tex.width)x\(tex.height)")
                return tex
            } catch {
                pbrLog("[Q3-PBR-SWIFT] generic-normal load FAILED err=\(error.localizedDescription)")
                return nil
            }
        }

        /// Phase 6 v2 — minimal TGA decoder for skybox face files.
        ///
        /// Q3 ships skybox faces as 256×256 uncompressed Type 2 truecolor TGAs
        /// (RGB, 24-bit). A handful are RGBA 32-bit. RLE-compressed (Type 10)
        /// support skipped — none of Q3's stock skyboxes use it.
        ///
        /// Returns RGBA8 bytes (width*height*4) in CPU memory plus dimensions,
        /// or nil on parse failure / unsupported variant. TGA byte order is
        /// stored BGR(A), origin is bottom-left by default; we swap to RGBA
        /// and flip vertically so the caller gets standard top-down RGBA
        /// ready for `MTLTexture.replace(region:slice:withBytes:)`.
        ///
        /// Reference: TGA spec v2.0 §3.1-3.4. Header layout (18 bytes):
        ///   0:  ID length             u8
        ///   1:  color map type        u8 (must be 0 — palette unsupported)
        ///   2:  image type            u8 (must be 2 — uncompressed truecolor)
        ///   3:  color map spec        u16+u16+u8 (5 bytes, all 0 expected)
        ///   8:  X origin              u16 le
        ///   10: Y origin              u16 le
        ///   12: width                 u16 le
        ///   14: height                u16 le
        ///   16: bits per pixel        u8 (24 or 32)
        ///   17: image descriptor      u8 (bit 5 = top-down origin flag,
        ///                                bits 0-3 = alpha bits)
        private func decodeTGAToRGBA(_ data: UnsafeBufferPointer<UInt8>) -> (rgba: [UInt8], width: Int, height: Int)? {
            guard data.count >= 18 else { return nil }
            let idLen     = Int(data[0])
            let mapType   = Int(data[1])
            let imageType = Int(data[2])
            // Tolerate only uncompressed truecolor with no color map.
            guard mapType == 0 else { return nil }
            guard imageType == 2 else { return nil }
            let width  = Int(data[12]) | (Int(data[13]) << 8)
            let height = Int(data[14]) | (Int(data[15]) << 8)
            let bpp    = Int(data[16])
            let descriptor = Int(data[17])
            guard width > 0, height > 0 else { return nil }
            guard bpp == 24 || bpp == 32 else { return nil }
            let bytesPerPixel = bpp / 8
            let pixelDataOffset = 18 + idLen
            let expectedPixelBytes = width * height * bytesPerPixel
            guard data.count >= pixelDataOffset + expectedPixelBytes else { return nil }
            // bit 5 of descriptor → top-down origin if set, bottom-up if clear
            let topDown = (descriptor & 0x20) != 0
            var rgba = [UInt8](repeating: 0, count: width * height * 4)
            for row in 0..<height {
                let srcRow = topDown ? row : (height - 1 - row)
                let srcOffset = pixelDataOffset + srcRow * width * bytesPerPixel
                let dstOffset = row * width * 4
                for col in 0..<width {
                    let s = srcOffset + col * bytesPerPixel
                    let d = dstOffset + col * 4
                    // TGA stores BGR(A); swap to RGBA
                    rgba[d + 0] = data[s + 2]
                    rgba[d + 1] = data[s + 1]
                    rgba[d + 2] = data[s + 0]
                    rgba[d + 3] = bpp == 32 ? data[s + 3] : 255
                }
            }
            return (rgba, width, height)
        }

        /// Phase 6 v2 — CoreGraphics-based fallback decoder for image data
        /// CGImageSource recognises (JPG / PNG / HEIC / TIFF). Q3's stock
        /// skybox face TGAs were re-encoded as JPG in pak0.pk3 to save space,
        /// so the JPG path is the actual default; TGA support is for any
        /// modder authoring custom skyboxes in TGA. Renders the decoded
        /// image into a CPU RGBA buffer via a CGBitmapContext.
        private func decodeImageDataToRGBA(_ data: Data) -> (rgba: [UInt8], width: Int, height: Int)? {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
            let w = cgImage.width
            let h = cgImage.height
            guard w > 0, h > 0 else { return nil }
            var rgba = [UInt8](repeating: 0, count: w * h * 4)
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
            let ok = rgba.withUnsafeMutableBytes { bytes -> Bool in
                guard let ctx = CGContext(data: bytes.baseAddress,
                                           width: w, height: h,
                                           bitsPerComponent: 8,
                                           bytesPerRow: w * 4,
                                           space: colorSpace,
                                           bitmapInfo: bitmapInfo) else { return false }
                ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
                return true
            }
            guard ok else { return nil }
            return (rgba, w, h)
        }

        /// Phase 6 v2 — load a single Q3 skybox face by stem (no extension).
        /// Tries `.tga` first via the minimal TGA decoder (for modders shipping
        /// custom skies as TGA), then `.jpg` via CoreGraphics (Q3 stock skies).
        /// Returns RGBA bytes + dimensions on success, nil if neither variant
        /// resolves. Routes through engine FS so pak0.pk3 content is found.
        private func loadSkyboxFace(stem: String) -> (rgba: [UInt8], width: Int, height: Int)? {
            // Try .tga first
            let tgaPath = "\(stem).tga"
            var bufPtr: UnsafePointer<UInt8>? = nil
            var size: Int32 = 0
            var ok = tgaPath.withCString { cstr -> Int32 in
                return Q3MetalRenderer_FSReadFile(cstr, &bufPtr, &size)
            }
            if ok != 0, let raw = bufPtr, size > 0 {
                let buf = UnsafeBufferPointer(start: raw, count: Int(size))
                let decoded = decodeTGAToRGBA(buf)
                Q3MetalRenderer_FSFreeFile(raw)
                if let r = decoded { return r }
                // TGA file exists but decode failed — could be RLE or palette.
                // Fall through to JPG attempt.
            }
            // Try .jpg via CoreGraphics
            let jpgPath = "\(stem).jpg"
            bufPtr = nil
            size = 0
            ok = jpgPath.withCString { cstr -> Int32 in
                return Q3MetalRenderer_FSReadFile(cstr, &bufPtr, &size)
            }
            guard ok != 0, let raw = bufPtr, size > 0 else { return nil }
            defer { Q3MetalRenderer_FSFreeFile(raw) }
            let buf = UnsafeBufferPointer(start: raw, count: Int(size))
            let data = Data(bytes: buf.baseAddress!, count: buf.count)
            return decodeImageDataToRGBA(data)
        }

        /// Phase 6 v2 — attempt to build the IBL cube from the active map's
        /// skybox faces. Reads the `r_pbr_ibl_skybox` cvar via the C bridge,
        /// then loads 6 TGAs (`<stem>_ft.tga`, `_bk`, `_lf`, `_rt`, `_up`,
        /// `_dn`). Returns the cubemap on full success, or nil if any face
        /// fails — caller falls back to the procedural sky-gradient cube.
        ///
        /// Face mapping (Q3 sky face → Metal cube slice):
        ///   slice 0 (+X right) = _rt
        ///   slice 1 (-X left)  = _lf
        ///   slice 2 (+Y top)   = _up
        ///   slice 3 (-Y bottom)= _dn
        ///   slice 4 (+Z front) = _ft
        ///   slice 5 (-Z back)  = _bk
        ///
        /// Q3 face orientation correction: some TGAs need horizontal/vertical
        /// flips because Q3's world axes don't match Metal's cubemap face
        /// orientation. v1 ships the simple mapping; if the resulting
        /// reflection looks rotated 90° on a face, swap the suffix mapping
        /// in this method.
        private func tryBuildMapSkyboxCube() -> MTLTexture? {
            // Read active skybox stem
            var nameBuf = [CChar](repeating: 0, count: 128)
            let gotName = nameBuf.withUnsafeMutableBufferPointer { p -> Int32 in
                Q3_PBRIBLSkyboxName(p.baseAddress, Int32(p.count))
            }
            guard gotName != 0 else { return nil }
            let stem = String(cString: nameBuf)
            guard !stem.isEmpty else { return nil }

            let suffixes = ["_rt", "_lf", "_up", "_dn", "_ft", "_bk"]
            var faceData: [(rgba: [UInt8], width: Int, height: Int)] = []
            for suffix in suffixes {
                let faceStem = "\(stem)\(suffix)"
                guard let face = loadSkyboxFace(stem: faceStem) else {
                    pbrLog("[Q3-PBR-IBL] map skybox FS read MISS stem=\(faceStem) (.tga and .jpg both unavailable) — falling back to procedural")
                    return nil
                }
                faceData.append(face)
            }
            // All 6 faces must share dimensions (square)
            let baseSize = faceData[0].width
            guard baseSize > 0, baseSize == faceData[0].height else { return nil }
            for f in faceData {
                if f.width != baseSize || f.height != baseSize {
                    pbrLog("[Q3-PBR-IBL] map skybox face size mismatch — falling back")
                    return nil
                }
            }

            // Build cube
            guard let device = self.commandQueue?.device else { return nil }
            let desc = MTLTextureDescriptor.textureCubeDescriptor(
                pixelFormat: .rgba8Unorm,
                size: baseSize,
                mipmapped: true
            )
            desc.usage = [.shaderRead]
            desc.storageMode = .shared
            guard let cube = device.makeTexture(descriptor: desc) else {
                pbrLog("[Q3-PBR-IBL] map skybox cube alloc FAILED size=\(baseSize)")
                return nil
            }
            cube.label = "Q3.pbr.envcube.map.\(stem)"

            let bytesPerRow = baseSize * 4
            let bytesPerImage = bytesPerRow * baseSize
            let region = MTLRegionMake2D(0, 0, baseSize, baseSize)
            for face in 0..<6 {
                faceData[face].rgba.withUnsafeBytes { rawBuf in
                    cube.replace(region: region,
                                 mipmapLevel: 0,
                                 slice: face,
                                 withBytes: rawBuf.baseAddress!,
                                 bytesPerRow: bytesPerRow,
                                 bytesPerImage: bytesPerImage)
                }
            }
            // Generate mip chain for roughness-based specular sampling
            if let queue = device.makeCommandQueue(),
               let cb = queue.makeCommandBuffer(),
               let blit = cb.makeBlitCommandEncoder() {
                blit.generateMipmaps(for: cube)
                blit.endEncoding()
                cb.commit()
                cb.waitUntilCompleted()
            }
            NSLog("[Q3-PBR-IBL] map skybox envCube ready stem=%@ %dx%dx6 mips=%d",
                  stem, baseSize, baseSize, cube.mipmapLevelCount)
            pbrLog("[Q3-PBR-IBL] map skybox envCube ready stem=\(stem) \(baseSize)x\(baseSize)x6 mips=\(cube.mipmapLevelCount)")
            return cube
        }

        /// Phase 6 — procedural sky-gradient environment cubemap.
        ///
        /// Built once at first call; reused across all entity draws via
        /// fragment texture slot 5. 64²×6 RGBA8Unorm, mipmapped via blit
        /// `generateMipmaps(for:)` so each higher mip = coarser blur
        /// approximating one fixed roughness step. Procedural sky model:
        ///   - top   (Y=+1): sky blue (0.55, 0.72, 0.92)
        ///   - horiz (Y= 0): warm dusk (0.85, 0.78, 0.65)
        ///   - bottom(Y=-1): dark ground (0.15, 0.13, 0.10)
        /// Direction computed per-texel via standard Metal cube face
        /// convention (slice 0=+X, 1=-X, 2=+Y, 3=-Y, 4=+Z, 5=-Z) so the
        /// MSL fragment can `envCube.sample(envSampler, worldDir, level(m))`
        /// directly without any custom mapping.
        ///
        /// Why procedural over per-map scene cube (deferred to v2): per-map
        /// rendering needs a 6-face render-pass at first valid frame after
        /// world load, which is invasive plumbing. Procedural v1 ships the
        /// headline "rocket reflects sky" win in one self-contained method.
        /// Phase 6 v3 — read the active skybox stem from the C bridge. Returns
        /// the cvar value (which the engine auto-publishes on map load via
        /// GetSkyFaceTextureForSurface) or nil if unavailable / empty.
        private func currentPBRSkyboxStem() -> String? {
            var nameBuf = [CChar](repeating: 0, count: 128)
            let ok = nameBuf.withUnsafeMutableBufferPointer { p -> Int32 in
                Q3_PBRIBLSkyboxName(p.baseAddress, Int32(p.count))
            }
            guard ok != 0 else { return nil }
            let stem = String(cString: nameBuf)
            return stem.isEmpty ? nil : stem
        }

        private func ensurePBREnvCube() -> MTLTexture? {
            // Phase 6 v3 — live cvar-change detection. Read the active stem
            // and compare against the stem the cached cube was built from.
            // If the engine auto-publish (or user console set) has moved the
            // cvar since we last built, invalidate so the lazy builder
            // re-runs. The "<procedural>" sentinel records sessions where
            // the map skybox path missed and we shipped the procedural
            // fallback — those don't invalidate when the cvar changes UNLESS
            // the cvar now names something different from when the procedural
            // was selected (sentinel always != real stem).
            let currentStem = currentPBRSkyboxStem()
            if pbrEnvCube != nil, pbrEnvCubeStem != currentStem {
                pbrLog("[Q3-PBR-IBL] skybox stem changed (\(pbrEnvCubeStem ?? "<nil>") → \(currentStem ?? "<nil>")) — invalidating cache")
                pbrEnvCube = nil
                pbrEnvCubeAttempted = false
            }
            if let cube = pbrEnvCube { return cube }
            if pbrEnvCubeAttempted { return nil }
            pbrEnvCubeAttempted = true

            // Phase 6 v2 — try map-specific skybox cube first. Returns nil on
            // any miss (engine FS not ready, skybox name empty, any of the 6
            // TGAs fail to read, decode fails, sizes mismatch). On success
            // we cache and return immediately; the procedural fallback below
            // never fires for this session.
            if let mapCube = tryBuildMapSkyboxCube() {
                pbrEnvCube = mapCube
                pbrEnvCubeStem = currentStem
                return mapCube
            }

            guard let device = self.commandQueue?.device else { return nil }

            let size = 64
            let desc = MTLTextureDescriptor.textureCubeDescriptor(
                pixelFormat: .rgba8Unorm,
                size: size,
                mipmapped: true
            )
            desc.usage = [.shaderRead]
            desc.storageMode = .shared
            guard let cube = device.makeTexture(descriptor: desc) else {
                pbrLog("[Q3-PBR-IBL] envCube alloc FAILED size=\(size)")
                return nil
            }
            cube.label = "Q3.pbr.envcube.procedural"

            // Sky-gradient color model
            let skyTop  = SIMD3<Float>(0.55, 0.72, 0.92)
            let horizon = SIMD3<Float>(0.85, 0.78, 0.65)
            let ground  = SIMD3<Float>(0.15, 0.13, 0.10)

            let bytesPerRow = size * 4
            let bytesPerImage = bytesPerRow * size
            var faceBuf = [UInt8](repeating: 0, count: bytesPerImage)

            for face in 0..<6 {
                for y in 0..<size {
                    for x in 0..<size {
                        // Face-local UV centred [-1, +1]
                        let u = (Float(x) + 0.5) / Float(size) * 2.0 - 1.0
                        let v = (Float(y) + 0.5) / Float(size) * 2.0 - 1.0
                        // Metal cube convention → world direction
                        var dir: SIMD3<Float>
                        switch face {
                        case 0: dir = SIMD3( 1, -v, -u)  // +X right
                        case 1: dir = SIMD3(-1, -v,  u)  // -X left
                        case 2: dir = SIMD3( u,  1,  v)  // +Y top (sky)
                        case 3: dir = SIMD3( u, -1, -v)  // -Y bottom (ground)
                        case 4: dir = SIMD3( u, -v,  1)  // +Z front
                        case 5: dir = SIMD3(-u, -v, -1)  // -Z back
                        default: dir = SIMD3(0, 1, 0)
                        }
                        let len = simd_length(dir)
                        if len > 1e-6 { dir = dir / len }
                        // Y component drives sky/ground gradient.
                        // t in [0, 1] where 1 = straight up
                        let t = dir.y * 0.5 + 0.5
                        let color: SIMD3<Float>
                        if t >= 0.5 {
                            let k = (t - 0.5) * 2.0
                            color = horizon * (1 - k) + skyTop * k
                        } else {
                            let k = t * 2.0
                            color = ground * (1 - k) + horizon * k
                        }
                        let idx = (y * size + x) * 4
                        faceBuf[idx + 0] = UInt8(max(0, min(255, Int(color.x * 255))))
                        faceBuf[idx + 1] = UInt8(max(0, min(255, Int(color.y * 255))))
                        faceBuf[idx + 2] = UInt8(max(0, min(255, Int(color.z * 255))))
                        faceBuf[idx + 3] = 255
                    }
                }
                let region = MTLRegionMake2D(0, 0, size, size)
                faceBuf.withUnsafeBytes { rawBuf in
                    cube.replace(region: region,
                                 mipmapLevel: 0,
                                 slice: face,
                                 withBytes: rawBuf.baseAddress!,
                                 bytesPerRow: bytesPerRow,
                                 bytesPerImage: bytesPerImage)
                }
            }

            // Generate mip chain so the fragment can `level(roughness*maxMip)`
            // for the specular IBL pre-filter approximation. Box-filter mips
            // are not a true GGX importance-sampled prefilter, but at 64² with
            // 7 mips they're close enough for viewmodel-scale visual fidelity.
            if let queue = device.makeCommandQueue(),
               let cb = queue.makeCommandBuffer(),
               let blit = cb.makeBlitCommandEncoder() {
                blit.generateMipmaps(for: cube)
                blit.endEncoding()
                cb.commit()
                cb.waitUntilCompleted()
            }
            pbrEnvCube = cube
            // Phase 6 v3 — stamp the procedural sentinel so if the cvar
            // later changes to a real loadable stem, ensurePBREnvCube
            // invalidates and re-tries the map-cube path next call.
            pbrEnvCubeStem = "<procedural>"
            NSLog("[Q3-PBR-IBL] procedural envCube ready %dx%dx6 mips=%d",
                  size, size, cube.mipmapLevelCount)
            pbrLog("[Q3-PBR-IBL] procedural envCube ready \(size)x\(size)x6 mips=\(cube.mipmapLevelCount)")
            return cube
        }

        /// Phase 6 — env-cube sampler. Always `.clampToEdge` on all axes to
        /// prevent seam artefacts at cube face boundaries (same class of fix
        /// as Q2's sky-seam `.repeat` → `.clampToEdge` switch from ffeb197).
        /// Trilinear filtering across mips for smooth roughness transitions.
        private func ensurePBREnvSampler() -> MTLSamplerState? {
            if let s = pbrEnvSampler { return s }
            guard let device = self.commandQueue?.device else { return nil }
            let d = MTLSamplerDescriptor()
            d.minFilter = .linear
            d.magFilter = .linear
            d.mipFilter = .linear
            d.sAddressMode = .clampToEdge
            d.tAddressMode = .clampToEdge
            d.rAddressMode = .clampToEdge
            d.maxAnisotropy = 1
            d.label = "Q3.pbr.env.sampler"
            pbrEnvSampler = device.makeSamplerState(descriptor: d)
            return pbrEnvSampler
        }

        /// Phase 6+ extension — 1×1 R8Unorm constant-value texture builder.
        /// Shared helper for roughness + metallic fallback textures. Stores
        /// `value` clamped to [0, 1] as a single byte; MSL samples `.r` and
        /// gets the same scalar regardless of which texel it picks.
        private func makeConstantR8Texture(value: Float, label: String) -> MTLTexture? {
            guard let device = self.commandQueue?.device else { return nil }
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .r8Unorm,
                width: 1, height: 1, mipmapped: false
            )
            desc.usage = [.shaderRead]
            desc.storageMode = .shared
            guard let tex = device.makeTexture(descriptor: desc) else { return nil }
            tex.label = label
            var byte: UInt8 = UInt8(max(0, min(255, Int((value.isFinite ? value : 0.0) * 255.0))))
            let region = MTLRegionMake2D(0, 0, 1, 1)
            withUnsafePointer(to: &byte) { ptr in
                tex.replace(region: region, mipmapLevel: 0,
                            withBytes: UnsafeRawPointer(ptr),
                            bytesPerRow: 1)
            }
            return tex
        }

        /// Phase 6+ — default roughness constant (0.55). Lazy-built on first
        /// request; shared across every weapon falling back from no-explicit-
        /// roughness-DDS. Matches the pre-Phase 6 in-MSL default literal so
        /// the GGX peak width stays unchanged for weapons that DID NOT have
        /// explicit textures before this extension.
        private func pbrRoughnessDefault() -> MTLTexture? {
            if let t = pbrRoughnessDefaultTex { return t }
            if pbrRoughnessDefaultAttempted { return nil }
            pbrRoughnessDefaultAttempted = true
            let tex = makeConstantR8Texture(value: 0.55, label: "Q3.pbr.roughness.default_0p55")
            pbrRoughnessDefaultTex = tex
            if tex != nil {
                pbrLog("[Q3-PBR-SWIFT] roughness default 1x1=0.55 ready")
            } else {
                pbrLog("[Q3-PBR-SWIFT] roughness default alloc FAILED")
            }
            return tex
        }

        /// Phase 6+ — default metallic constant (0.50). Partial-metal value
        /// reads as "weathered steel": F0 lerps halfway between dielectric
        /// 0.04 and base.rgb, giving the rocket-style tinted highlight + half
        /// diffuse contribution. Same value as the previous in-MSL default.
        private func pbrMetallicDefault() -> MTLTexture? {
            if let t = pbrMetallicDefaultTex { return t }
            if pbrMetallicDefaultAttempted { return nil }
            pbrMetallicDefaultAttempted = true
            let tex = makeConstantR8Texture(value: 0.50, label: "Q3.pbr.metallic.default_0p50")
            pbrMetallicDefaultTex = tex
            if tex != nil {
                pbrLog("[Q3-PBR-SWIFT] metallic default 1x1=0.50 ready")
            } else {
                pbrLog("[Q3-PBR-SWIFT] metallic default alloc FAILED")
            }
            return tex
        }

        /// Phase 4 — lazy-load roughness map. Single-channel (R) data:
        /// 0=mirror polish, 1=fully matte. Like normals, must NOT be
        /// sRGB (linear scalar data, not gamma-encoded color).
        ///
        /// Phase 6+ extension: when the material has albedo or normal but
        /// no explicit roughness DDS, return the 1×1 R8 constant fallback
        /// (`pbrRoughnessDefault`, value 0.55) so the MSL `hasFullPBR`
        /// check evaluates true and the weapon enters the Cook-Torrance +
        /// IBL block. Brings shotgun/lightning/railgun/grenade/BFG up to
        /// the same shading path as the rocket.
        private func pbrRoughnessTexture(for handle: UInt32) -> MTLTexture? {
            if let cached = pbrRoughnessCache[handle] { return cached }
            if pbrRoughnessTried.contains(handle) { return nil }
            pbrRoughnessTried.insert(handle)
            guard let matPtr = Q3MetalRenderer_GetPBRMaterial(handle) else { return nil }
            let mat = matPtr.pointee
            if let rCStr = mat.roughness {
                let path = String(cString: rCStr)
                if let loader = pbrTextureLoader {
                    pbrLog("[Q3-PBR-SWIFT] trying-roughness handle=\(handle) path=\(path)")
                    let url = URL(fileURLWithPath: path)
                    let opts: [MTKTextureLoader.Option: Any] = [
                        .SRGB:                NSNumber(value: false),
                        .textureUsage:        NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
                        .textureStorageMode:  NSNumber(value: MTLStorageMode.private.rawValue),
                        .generateMipmaps:     NSNumber(value: false),
                    ]
                    do {
                        let tex = try loader.newTexture(URL: url, options: opts)
                        tex.label = "Q3.pbr.roughness.h\(handle)"
                        pbrRoughnessCache[handle] = tex
                        pbrLog("[Q3-PBR-SWIFT] loaded roughness handle=\(handle) size=\(tex.width)x\(tex.height) path=\(path)")
                        return tex
                    } catch {
                        pbrLog("[Q3-PBR-SWIFT] roughness DDS load FAILED handle=\(handle) err=\(error.localizedDescription) — will try default fallback")
                        // fall through to default fallback below
                    }
                }
            }
            // No explicit roughness map (or load failed) — fall back to the
            // 1×1 R8 default constant when the material has any other PBR
            // slot. This is the Phase 6+ coverage extension for the lower-
            // tier weapons.
            if mat.albedo != nil || mat.normal != nil {
                if let fallback = pbrRoughnessDefault() {
                    pbrRoughnessCache[handle] = fallback
                    pbrLog("[Q3-PBR-SWIFT] roughness DEFAULT fallback handle=\(handle) value=0.55")
                    return fallback
                }
            }
            return nil
        }

        /// Phase 4 — lazy-load metallic map. Single-channel (R): 0=plastic
        /// dielectric reflects ~4% incoming light at normal incidence,
        /// 1=metal reflects ~100% TINTED by the base color (gold reflects
        /// gold, copper reflects copper). Required for Schlick Fresnel
        /// F0 lerp in the Cook-Torrance BRDF.
        ///
        /// Phase 6+ extension: see pbrRoughnessTexture(for:) comment — same
        /// fallback policy with `pbrMetallicDefault` (value 0.50).
        private func pbrMetallicTexture(for handle: UInt32) -> MTLTexture? {
            if let cached = pbrMetallicCache[handle] { return cached }
            if pbrMetallicTried.contains(handle) { return nil }
            pbrMetallicTried.insert(handle)
            guard let matPtr = Q3MetalRenderer_GetPBRMaterial(handle) else { return nil }
            let mat = matPtr.pointee
            if let mCStr = mat.metallic {
                let path = String(cString: mCStr)
                if let loader = pbrTextureLoader {
                    pbrLog("[Q3-PBR-SWIFT] trying-metallic handle=\(handle) path=\(path)")
                    let url = URL(fileURLWithPath: path)
                    let opts: [MTKTextureLoader.Option: Any] = [
                        .SRGB:                NSNumber(value: false),
                        .textureUsage:        NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
                        .textureStorageMode:  NSNumber(value: MTLStorageMode.private.rawValue),
                        .generateMipmaps:     NSNumber(value: false),
                    ]
                    do {
                        let tex = try loader.newTexture(URL: url, options: opts)
                        tex.label = "Q3.pbr.metallic.h\(handle)"
                        pbrMetallicCache[handle] = tex
                        pbrLog("[Q3-PBR-SWIFT] loaded metallic handle=\(handle) size=\(tex.width)x\(tex.height) path=\(path)")
                        return tex
                    } catch {
                        pbrLog("[Q3-PBR-SWIFT] metallic DDS load FAILED handle=\(handle) err=\(error.localizedDescription) — will try default fallback")
                        // fall through to default fallback below
                    }
                }
            }
            // Phase 6+ default fallback (see pbrRoughnessTexture comment).
            if mat.albedo != nil || mat.normal != nil {
                if let fallback = pbrMetallicDefault() {
                    pbrMetallicCache[handle] = fallback
                    pbrLog("[Q3-PBR-SWIFT] metallic DEFAULT fallback handle=\(handle) value=0.50")
                    return fallback
                }
            }
            return nil
        }

        /// Phase 3 — lazy-load the metal-plate normal map for uniform
        /// world-surface relief. One bundled DDS, shared across every
        /// world draw. Sticks to nil until first call; subsequent calls
        /// hit the cached texture.
        private func ensurePBRWorldNormal() -> MTLTexture? {
            if pbrWorldNormalTexture != nil { return pbrWorldNormalTexture }
            if pbrWorldNormalAttempted { return nil }
            pbrWorldNormalAttempted = true
            // Only attach when the r_pbrMaterials cvar is on, so the world
            // shader falls back to vanilla when PBR is disabled.
            if q3_pbr_enabled() == 0 { return nil }
            guard let loader = pbrTextureLoader else { return nil }
            guard let bundleRoot = Bundle.main.resourcePath else { return nil }
            let path = bundleRoot + "/baseq3/pbr/assets/ingested/metal_plate_normal_2k_OTH_Normal.n.rtex.dds"
            pbrLog("[Q3-PBR-SWIFT] world-normal trying path=\(path)")
            let url = URL(fileURLWithPath: path)
            let opts: [MTKTextureLoader.Option: Any] = [
                .SRGB:                NSNumber(value: false),   // vector data
                .textureUsage:        NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
                .textureStorageMode:  NSNumber(value: MTLStorageMode.private.rawValue),
                .generateMipmaps:     NSNumber(value: false),
            ]
            do {
                let tex = try loader.newTexture(URL: url, options: opts)
                tex.label = "Q3.pbr.world.normal.metal_plate"
                pbrWorldNormalTexture = tex
                pbrLog("[Q3-PBR-SWIFT] loaded world-normal size=\(tex.width)x\(tex.height)")
                return tex
            } catch {
                pbrLog("[Q3-PBR-SWIFT] world-normal DDS load FAILED err=\(error.localizedDescription)")
                return nil
            }
        }

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
        private var fogVolumeLogged = false
        private var frameTimeOrigin = CACurrentMediaTime()
        private var lastPerfLogTime = CACurrentMediaTime()
        private var lastPerfLogFrame: UInt32 = 0

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
            } else if profile != nil {
                // matchProfile960 / matchProfile1280 — keep deterministic
                // sizes so AVI captures still bit-diff against prior runs.
                target = CGSize(width: isPad ? 1280 : 960,
                                height: isPad ? 960 : 444)
            } else {
                // Normal play. Lock the drawable to TRUE device-native
                // pixels so MetalFX's spatial upscale outputs directly to
                // the panel-pixel grid with NO Core Animation downstream
                // scale. iPhone 17 Pro Max = 2868×1320 landscape, iPad
                // Pro 13" M4 = 2752×2064 landscape. UIScreen.nativeBounds
                // is portrait; swap with max/min for landscape.
                // Previous build used 1920×888 / 2560×1920 fixed targets
                // and relied on Core Animation linear-scale to the panel —
                // soft on OLED. With MetalFX spatial + drawable at native
                // pixels, the result is 1:1 on the display and crisp.
                let nb = UIScreen.main.nativeBounds.size
                let _ = isPad   // pad/phone branch no longer needed
                target = CGSize(width: max(nb.width, nb.height),
                                height: min(nb.width, nb.height))
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
            let drawFrameStart = CACurrentMediaTime()
            if commandQueue == nil {
                configureRenderer(for: view)
            }

            /* MetalFX upscale path: when upscaleQuality != .native, we
             * render the frame at a lower resolution (renderW × renderH)
             * into upscaleColorTarget and then MetalFX spatially upscales
             * to the drawable. The Q3 renderer needs to know its
             * "effective drawable" is the RT size so projection / viewport
             * / scissor math is consistent with what we'll actually feed
             * to MetalFX. Native quality keeps the existing direct path. */
            let outputW = Int(view.drawableSize.width)
            let outputH = Int(view.drawableSize.height)
            let upscaleActive: Bool
            let renderW: Int
            let renderH: Int
            if upscaleQuality != .native, let device = view.device, outputW > 0, outputH > 0 {
                let rs = upscaleQuality.renderSize(forOutput: view.drawableSize)
                let rW = max(1, Int(rs.width))
                let rH = max(1, Int(rs.height))
                if ensureSpatialUpscaleTargets(device: device, inputW: rW, inputH: rH, outputW: outputW, outputH: outputH) {
                    upscaleActive = true
                    renderW = rW
                    renderH = rH
                } else {
                    // MetalFX unavailable on this device — fall back.
                    upscaleActive = false
                    renderW = outputW
                    renderH = outputH
                }
            } else {
                upscaleActive = false
                renderW = outputW
                renderH = outputH
            }
            Q3MetalRenderer_UpdateDrawableSize(Int32(renderW), Int32(renderH))

            /* Acquire the CAMetalLayer drawable before running the Q3
             * simulation/render build. On ProMotion hardware, waiting until
             * after a 3-5ms Quake3_Frame() can miss the layer's current
             * acquisition window, turning otherwise-fast maps (nv15) into
             * every-other-vblank 60Hz despite low GPU time. Holding the
             * drawable while Q3 builds command lists is short in steady
             * state and lets us commit before the next 120Hz deadline. */
            let drawableAcquireStart = CACurrentMediaTime()
            guard let drawable = view.currentDrawable,
                  let descriptor = view.currentRenderPassDescriptor,
                  let commandQueue,
                  let uiSamplerState,
                  let worldSamplerState,
                  let commandBuffer = commandQueue.makeCommandBuffer()
            else { return }
            let drawableAcquireMs = (CACurrentMediaTime() - drawableAcquireStart) * 1000.0
            commandBuffer.label = "Q3.frame"

            let q3FrameStart = CACurrentMediaTime()
            Quake3_Frame()
            let q3FrameMs = (CACurrentMediaTime() - q3FrameStart) * 1000.0

            guard let snapshot = Q3MetalRenderer_GetFrameSnapshot()?.pointee else { return }

            descriptor.colorAttachments[0].clearColor = MTLClearColor(
                red: Double(snapshot.clearColor.0),
                green: Double(snapshot.clearColor.1),
                blue: Double(snapshot.clearColor.2),
                alpha: Double(snapshot.clearColor.3)
            )
            /* Start every frame from Q3's requested clear colour. A
             * CAMetalLayer drawable's previous contents are undefined, and
             * transparent/additive passes (sky overlays, flares, UI, filter
             * decals) can expose pixels the opaque world did not overwrite.
             *
             * GL_DST_COLOR/GL_ZERO and other read-modify-write stages still
             * see valid destinationColor because they execute later in the
             * same encoder, after the world/sky passes have populated the
             * framebuffer. Keeping .load here leaked stale drawable pixels
             * into sky/additive/UI captures as intermittent "light" patches. */
            descriptor.colorAttachments[0].loadAction = .clear
            descriptor.colorAttachments[0].storeAction = .store

            /* MetalFX path: redirect the main color attachment to our
             * offscreen RT. The descriptor's drawable.texture is left
             * untouched (we'll fill it via spatial upscale after
             * encoder.endEncoding). Depth attachment is ALSO swapped to
             * match the RT's dimensions — Metal rejects a render pass
             * where color/depth dims disagree. */
            if upscaleActive, let colorRT = upscaleColorTarget, let depthRT = upscaleDepthTarget {
                descriptor.colorAttachments[0].texture = colorRT
                descriptor.depthAttachment.texture = depthRT
                descriptor.depthAttachment.loadAction = .clear
                descriptor.depthAttachment.storeAction = .store
                descriptor.depthAttachment.clearDepth = 1.0
            }

            /* Sanity: the drawable texture MUST NOT be memoryless — filter
             * blending needs a real framebuffer to sample destinationColor
             * from. MTKView with framebufferOnly=false (set in
             * configureRenderer) guarantees .private storage, not
             * .memoryless. Log once if this invariant is ever violated. */
            if let drawableTexture = descriptor.colorAttachments[0].texture,
               drawableTexture.storageMode == .memoryless {
                print("[Metal] FATAL: drawable is memoryless — destinationColor will be undefined. Filter/subtract blends will not work.")
            }

            let wantsFogRayBox = hasRenderableFogVolume()
            let sceneDepth = wantsFogRayBox ? view.device.flatMap { device in
                ensureSceneDepthTexture(device: device,
                                        width: renderW,
                                        height: renderH)
            } : nil
            if let sceneDepth, !upscaleActive {
                // Native path: drive the descriptor's depth from our scene
                // depth (drawable-sized). Upscale path already set depth
                // to upscaleDepthTarget above.
                descriptor.depthAttachment.texture = sceneDepth
                descriptor.depthAttachment.loadAction = .clear
                descriptor.depthAttachment.storeAction = .store
                descriptor.depthAttachment.clearDepth = 1.0
            }

            guard var encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
                return
            }
            encoder.label = "Q3.render"
            var rtCompositeForUpscale: MTLTexture? = nil

            // Viewport matches the actual render-target size (RT when
            // upscaling, drawable when native).
            encoder.setViewport(MTLViewport(
                originX: 0,
                originY: 0,
                width: Double(renderW),
                height: Double(renderH),
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

                var worldPassEntryCount = 0
                var worldEncodedDrawCalls = 0
                var worldPassEntryCounts = [Int](repeating: 0, count: 6)
                var worldEncodedDrawCallsByPass = [Int](repeating: 0, count: 6)
                var worldBatchGroupCounts = [Int](repeating: 0, count: 6)
                var worldBatchBuildMs: Double = 0
                var worldBatchCopyMs: Double = 0
                var worldEncodeMs: Double = 0
                if let worldDrawsPointer = Q3MetalRenderer_GetWorldDrawCommands(),
                   let indicesPointer = Q3MetalRenderer_GetWorldIndices() {
                    let _ = indicesPointer
                    let worldDraws = UnsafeBufferPointer(start: worldDrawsPointer, count: Int(snapshot.worldCommandCount))
                    let timeSeconds = snapshot.shaderTime

                    let skyFlagBit = UInt32(Q3_METAL_WORLD_DRAWFLAG_SKY)
                    let fogOverlayBit = UInt32(Q3_METAL_WORLD_DRAWFLAG_FOG_OVERLAY)
                    let fogOnlyBit = UInt32(Q3_METAL_WORLD_DRAWFLAG_FOG_ONLY)
                    let combinedLightmapBit = UInt32(Q3_METAL_WORLD_DRAWFLAG_COMBINED_LIGHTMAP)

                    // Ordered world passes:
                    // 0 = opaque, 1 = filter, 2 = alpha,
                    // 3 = additive (GL_SRC_ALPHA/GL_ONE — alpha-modulated),
                    // 4 = additive-full (GL_ONE/GL_ONE — explosion/glow cores),
                    // 5 = fog overlay pass (post-stage alpha fog).
                    // Sky draws are handled in pass 0 through the sky pipeline
                    // (view-direction spherical projection, no lightmap).
                    var worldPassEntriesByPass = Array(repeating: [WorldPassEntry](), count: 6)
                    if !worldDraws.isEmpty {
                        worldPassEntriesByPass[0].reserveCapacity(worldDraws.count)
                        worldPassEntriesByPass[1].reserveCapacity(worldDraws.count)
                        for pass in 2..<6 {
                            worldPassEntriesByPass[pass].reserveCapacity(max(16, worldDraws.count / 8))
                        }
                    }

                    for drawIndex in 0..<worldDraws.count {
                        let draw = worldDraws[drawIndex]
                        guard draw.indexCount > 0 else { continue }

                        if (draw.flags & fogOnlyBit) != 0 {
                            worldPassEntriesByPass[5].append(WorldPassEntry(drawIndex: drawIndex, stageIndex: -2))
                            continue
                        }

                        if (draw.flags & skyFlagBit) != 0 {
                            worldPassEntriesByPass[0].append(WorldPassEntry(drawIndex: drawIndex, stageIndex: -1))
                            continue
                        }

                        let stageCount = min(Int(draw.stageCount), Int(Q3_METAL_MAX_STAGES))
                        guard stageCount > 0 else { continue }

                        for stageIndex in 0..<stageCount {
                            let stage = Self.worldStage(draw, stageIndex)
                            let drawPass = Self.worldRenderPass(for: stage)
                            worldPassEntriesByPass[drawPass].append(WorldPassEntry(drawIndex: drawIndex, stageIndex: stageIndex))
                        }
                    }
                    worldPassEntryCount = worldPassEntriesByPass.reduce(0) { $0 + $1.count }
                    for pass in 0..<6 {
                        worldPassEntryCounts[pass] = worldPassEntriesByPass[pass].count
                    }
                    let shouldSampleWorldBatchGroups = ((debugFrameCounter &+ 1) % 60) == 0
                    if shouldSampleWorldBatchGroups {
                        for pass in 0...1 {
                            var hashes = Set<UInt64>()
                            hashes.reserveCapacity(min(worldPassEntriesByPass[pass].count, 256))
                            for entry in worldPassEntriesByPass[pass] where entry.stageIndex >= 0 {
                                let d = worldDraws[entry.drawIndex]
                                let s = Self.worldStage(d, entry.stageIndex)
                                hashes.insert(Self.worldBatchHash(draw: d, stage: s, pass: pass))
                            }
                            worldBatchGroupCounts[pass] = hashes.count
                        }
                    }

                    var cWorldBatches = UnsafeBufferPointer<Q3MetalWorldBatchCmd>(start: nil, count: 0)
                    var cWorldBatchIndexBuffer: MTLBuffer?
                    let batchBuildStart = CACurrentMediaTime()
                    let cBatchCount = Int(Q3MetalRenderer_BuildWorldBatches((1 << 0) | (1 << 1) | (1 << 2) | (1 << 3) | (1 << 4)))
                    worldBatchBuildMs = (CACurrentMediaTime() - batchBuildStart) * 1000.0
                    let cBatchIndexCount = Int(Q3MetalRenderer_GetWorldBatchIndexCount())
                    if cBatchCount > 0,
                       cBatchIndexCount > 0,
                       let cBatchPointer = Q3MetalRenderer_GetWorldBatches(),
                       let cBatchIndexPointer = Q3MetalRenderer_GetWorldBatchIndices(),
                       let device = view.device,
                       let batchBuffer = ensureWorldBatchIndexBuffer(device: device,
                                                                      indexCount: cBatchIndexCount,
                                                                      slot: Int(debugFrameCounter % 3)) {
                        let byteCount = cBatchIndexCount * MemoryLayout<UInt32>.stride
                        let batchCopyStart = CACurrentMediaTime()
                        memcpy(batchBuffer.contents(), cBatchIndexPointer, byteCount)
                        worldBatchCopyMs = (CACurrentMediaTime() - batchCopyStart) * 1000.0
                        cWorldBatches = UnsafeBufferPointer(start: cBatchPointer, count: cBatchCount)
                        cWorldBatchIndexBuffer = batchBuffer
                    }

                    var lastWorldPipelineState: MTLRenderPipelineState?
                    var lastWorldDepthStencilState: MTLDepthStencilState?
                    var lastWorldCullMode: MTLCullMode?
                    var lastWorldFragmentTexture0: MTLTexture?
                    var lastWorldFragmentTexture1: MTLTexture?

                    func invalidateWorldStateCache() {
                        lastWorldPipelineState = nil
                        lastWorldDepthStencilState = nil
                        lastWorldCullMode = nil
                        lastWorldFragmentTexture0 = nil
                        lastWorldFragmentTexture1 = nil
                    }

                    func setWorldPipelineStateCached(_ state: MTLRenderPipelineState) {
                        if lastWorldPipelineState !== state {
                            encoder.setRenderPipelineState(state)
                            lastWorldPipelineState = state
                        }
                    }

                    func setWorldDepthStencilStateCached(_ state: MTLDepthStencilState?) {
                        if lastWorldDepthStencilState !== state {
                            encoder.setDepthStencilState(state)
                            lastWorldDepthStencilState = state
                        }
                    }

                    func setWorldCullModeCached(_ mode: MTLCullMode) {
                        if lastWorldCullMode != mode {
                            encoder.setCullMode(mode)
                            lastWorldCullMode = mode
                        }
                    }

                    func setWorldFragmentTextureCached(_ texture: MTLTexture?, index: Int) {
                        if index == 0 {
                            if lastWorldFragmentTexture0 !== texture {
                                encoder.setFragmentTexture(texture, index: index)
                                lastWorldFragmentTexture0 = texture
                            }
                        } else if index == 1 {
                            if lastWorldFragmentTexture1 !== texture {
                                encoder.setFragmentTexture(texture, index: index)
                                lastWorldFragmentTexture1 = texture
                            }
                        } else {
                            encoder.setFragmentTexture(texture, index: index)
                        }
                    }

                    func encodeNormalWorldDraw(_ draw: Q3MetalWorldDrawCmd,
                                               _ stage: Q3MetalWorldStage,
                                               _ worldPass: Int,
                                               _ activeIndexBuffer: MTLBuffer,
                                               _ activeIndexOffset: Int,
                                               _ activeIndexCount: Int) -> Bool {
                        guard let lightmapTexture = texture(for: draw.lightmapTextureHandle, device: view.device),
                              let baseTexture = texture(for: stage.textureHandle, device: view.device) else {
                            return false
                        }
                        let stageCount = min(Int(draw.stageCount), Int(Q3_METAL_MAX_STAGES))
                        let drawHasLightmapStage = Self.worldDrawHasLightmapStage(draw)
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
                                /* DIAG: log first time each distinct (fogIndex, color)
                                 * pair shows up so we can determine whether q3dm4's
                                 * "fog changes between visits" is multiple BSP-authored
                                 * fog volumes (expected) or a single volume returning
                                 * varying state (bug). Grep q3_diag.log for FOG-DIAG. */
                                if Coordinator.fogSeen.insert(Int(draw.fogIndex)).inserted {
                                    NSLog("[FOG-DIAG] fogIndex=%d color=(%.3f, %.3f, %.3f) distance=%.1f tcScale=%.3f",
                                          Int(draw.fogIndex), f.color.0, f.color.1, f.color.2, f.distance, f.tcScale)
                                }
                            }
                        }

                        let blendMode = Self.worldBlendClass(for: stage)
                        let drawPass = Self.worldRenderPass(for: stage)
                        guard drawPass == worldPass, stageCount > 0 else { return false }
                        let blendedDepthState = (stage.useLightmap == 0 && stage.depthWrite != 0)
                            ? depthStencilState
                            : additiveDepthStencilState
                        if drawPass == 4, let worldAdditiveFullPipelineState {
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
                        encoder.setCullMode(Self.metalCullMode(for: stage.cullMode))
                        let alphaTest = Self.alphaTestThreshold(for: stage.alphaFunc)
                        let chain = Self.fillTcMods(stage)
                        let (tv0, tv1) = Self.tcGenVectors(stage)
                        var drawUniforms = WorldDrawUniforms(
                            tcGen: stage.useLightmap != 0 ? Float(4) : Float(stage.tcGen),
                            tcModCount: chain.count,
                            rgbGen: Float(stage.rgbGen),
                            alphaGen: Float(stage.alphaGen),
                            blendMode: Float(blendMode),
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
                            rgbConstColor: SIMD4(1, 1, 1, 1),
                            entityColor: SIMD4(1, 1, 1, 1),
                            fogColorDistance: fogCD,
                            fogParams: fogParams,
                            fogSurface: fogSurface,
                            tcGenVec0: tv0,
                            tcGenVec1: tv1,
                            deformWaveFunc: stage.deformWaveFunc,
                            deformWaveDiv: stage.deformWaveDiv != 0 ? stage.deformWaveDiv : 1.0,
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
                            deformBulgeWidth: stage.deformBulgeWidth,
                            deformBulgeHeight: stage.deformBulgeHeight,
                            deformBulgeSpeed: stage.deformBulgeSpeed,
                            autospriteMode: stage.autospriteMode,
                            debugMode: Coordinator.worldDebugMode,
                            forceWhiteVertColor: 0,
                            alphaTestThreshold: alphaTest,
                            fogOnly: 0,
                            stageUsesLightmap: stage.useLightmap != 0 ? 1.0 : 0.0,
                            drawHasLightmapStage: drawHasLightmapStage ? 1.0 : 0.0,
                            pbrRoughness: stage.pbrRoughness,
                            pbrMetallic: stage.pbrMetallic,
                            _pad0: (draw.flags & combinedLightmapBit) != 0 ? 1.0 : 0.0
                        )
                        encoder.setFragmentTexture(baseTexture, index: 0)
                        encoder.setFragmentTexture(lightmapTexture, index: 1)
                        // PBR Phase 3 — bind generic world normal map at
                        // slot 2 for tangent-space relief. nil bind leaves
                        // slot unbound; q3_world_fragment guards with
                        // is_null_texture() so the vanilla path is preserved.
                        encoder.setFragmentTexture(ensurePBRWorldNormal(), index: 2)
                        // PBR Phase 8 — bind IBL env cube + sampler for the
                        // Cook-Torrance + IBL block on world surfaces. Same
                        // cube as entity binding (Phase 6 v3 auto-detected).
                        if Q3_PBRIBLEnabled() != 0 && Q3_PBRWorldEnabled() != 0 {
                            encoder.setFragmentTexture(ensurePBREnvCube(), index: 3)
                            encoder.setFragmentSamplerState(ensurePBREnvSampler(), index: 1)
                        } else {
                            encoder.setFragmentTexture(nil, index: 3)
                        }
                        var pbrWorldParams = SIMD4<Float>(
                            Q3_PBRWorldEnabled() != 0 ? 1.0 : 0.0,
                            Q3_PBRWorldAmbientBoost(),
                            Q3_PBRWorldSpecBoost(),
                            Q3_PBRWorldClassMatchEnabled() != 0 ? 1.0 : 0.0)
                        encoder.setFragmentBytes(&pbrWorldParams, length: 16, index: 3)
                        encoder.setFragmentBytes(&drawUniforms, length: MemoryLayout<WorldDrawUniforms>.stride, index: 0)
                        encoder.setVertexBytes(&drawUniforms, length: MemoryLayout<WorldDrawUniforms>.stride, index: 2)
                        encoder.drawIndexedPrimitives(
                            type: .triangle,
                            indexCount: activeIndexCount,
                            indexType: .uint32,
                            indexBuffer: activeIndexBuffer,
                            indexBufferOffset: activeIndexOffset
                        )
                        return true
                    }

                    let worldEncodeStart = CACurrentMediaTime()
                    for worldPass in 0..<6 {
                        let passEntries = worldPassEntriesByPass[worldPass]
                        let useCWorldBatchesForPass = cWorldBatchIndexBuffer != nil && worldPass <= 4
                        if false && worldPass <= 1 && !passEntries.contains(where: { $0.stageIndex < 0 }) {
                            var batches: [WorldIndexBatch] = []
                            batches.reserveCapacity(128)
                            var buckets: [UInt64: [Int]] = [:]
                            buckets.reserveCapacity(128)
                            var entryBatchIndices = [Int](repeating: -1, count: passEntries.count)
                            var totalBatchIndexCount = 0

                            for (entryOrdinal, entry) in passEntries.enumerated() {
                                let draw = worldDraws[entry.drawIndex]
                                guard entry.stageIndex >= 0,
                                      entry.stageIndex < min(Int(draw.stageCount), Int(Q3_METAL_MAX_STAGES)),
                                      draw.indexCount > 0 else { continue }
                                let stage = Self.worldStage(draw, entry.stageIndex)
                                let key = Self.worldBatchHash(draw: draw, stage: stage, pass: worldPass)
                                var batchIndex: Int? = nil
                                if let candidates = buckets[key] {
                                    for candidate in candidates {
                                        let b = batches[candidate]
                                        let bd = worldDraws[b.drawIndex]
                                        let bs = Self.worldStage(bd, b.stageIndex)
                                        if Self.worldDrawsCanBatch(bd,
                                                                   stage: bs,
                                                                   nextDraw: draw,
                                                                   nextStage: stage,
                                                                   pass: worldPass) {
                                            batchIndex = candidate
                                            break
                                        }
                                    }
                                }
                                if batchIndex == nil {
                                    let newIndex = batches.count
                                    batches.append(WorldIndexBatch(drawIndex: entry.drawIndex,
                                                                  stageIndex: entry.stageIndex,
                                                                  firstMergedIndex: 0,
                                                                  indexCount: 0))
                                    buckets[key, default: []].append(newIndex)
                                    batchIndex = newIndex
                                }
                                let srcCount = Int(draw.indexCount)
                                if let bi = batchIndex {
                                    entryBatchIndices[entryOrdinal] = bi
                                    batches[bi].indexCount += srcCount
                                    totalBatchIndexCount += srcCount
                                }
                            }

                            if !batches.isEmpty,
                               let device = view.device,
                               let batchedIndexBuffer = ensureWorldBatchIndexBuffer(device: device,
                                                                                    indexCount: totalBatchIndexCount,
                                                                                    slot: Int(debugFrameCounter % 3)) {
                                var runningIndex = 0
                                for batchIndex in batches.indices {
                                    batches[batchIndex].firstMergedIndex = runningIndex
                                    runningIndex += batches[batchIndex].indexCount
                                }
                                var batchWriteCursors = batches.map { $0.firstMergedIndex }
                                worldBatchIndexScratch.removeAll(keepingCapacity: true)
                                worldBatchIndexScratch.reserveCapacity(totalBatchIndexCount)
                                if totalBatchIndexCount > 0 {
                                    worldBatchIndexScratch.append(contentsOf: repeatElement(0, count: totalBatchIndexCount))
                                }
                                if totalBatchIndexCount > 0 {
                                    worldBatchIndexScratch.withUnsafeMutableBufferPointer { dst in
                                        guard let dstBase = dst.baseAddress else { return }
                                        for (entryOrdinal, entry) in passEntries.enumerated() {
                                            let bi = entryBatchIndices[entryOrdinal]
                                            guard bi >= 0 else { continue }
                                            let draw = worldDraws[entry.drawIndex]
                                            let srcCount = Int(draw.indexCount)
                                            guard srcCount > 0 else { continue }
                                            let writeIndex = batchWriteCursors[bi]
                                            memcpy(dstBase.advanced(by: writeIndex),
                                                   indicesPointer.advanced(by: Int(draw.firstIndex)),
                                                   srcCount * MemoryLayout<UInt32>.stride)
                                            batchWriteCursors[bi] = writeIndex + srcCount
                                        }
                                    }
                                }
                                let byteCount = totalBatchIndexCount * MemoryLayout<UInt32>.stride
                                if byteCount > 0 {
                                    worldBatchIndexScratch.withUnsafeBytes { src in
                                        memcpy(batchedIndexBuffer.contents(), src.baseAddress!, byteCount)
                                    }
                                }
                                for batch in batches where batch.indexCount > 0 {
                                    let draw = worldDraws[batch.drawIndex]
                                    let stage = Self.worldStage(draw, batch.stageIndex)
                                    if encodeNormalWorldDraw(draw,
                                                             stage,
                                                             worldPass,
                                                             batchedIndexBuffer,
                                                             batch.firstMergedIndex * MemoryLayout<UInt32>.stride,
                                                             batch.indexCount) {
                                        worldEncodedDrawCalls += 1
                                        worldEncodedDrawCallsByPass[worldPass] += 1
                                    }
                                }
                                continue
                            }
                        }
                        var entryCursor = 0
                        while entryCursor < passEntries.count {
                        let entry = passEntries[entryCursor]
                        let drawIndex = entry.drawIndex
                        let draw = worldDraws[drawIndex]
                        let isSky = (draw.flags & skyFlagBit) != 0
                        if (draw.flags & fogOnlyBit) != 0 && worldPass != 5 {
                            entryCursor += 1
                            continue
                        }
                        if isSky {
                            // Only emit sky during the opaque pass to avoid
                            // duplicated draws across 4 pass iterations.
                            if worldPass != 0 {
                                entryCursor += 1
                                continue
                            }
                            guard let skyPipelineState, let skyDepthStencilState else {
                                entryCursor += 1
                                continue
                            }
                            let stageCount = min(Int(draw.stageCount), Int(Q3_METAL_MAX_STAGES))
                            guard stageCount > 0 else {
                                entryCursor += 1
                                continue
                            }

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
                            var skyDrawCalls = 0
                            for stageIndex in 0..<stageCount {
                                let stage = Self.worldStage(draw, stageIndex)
                                guard let skyStageTexture = texture(for: stage.textureHandle, device: view.device) else {
                                    continue
                                }
                                /* Strict blend split — NEVER merge 1 and 5. */
                                let skyBlend = Self.worldBlendClass(for: stage)
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
                                    blendMode: Float(skyBlend),
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
                                    deformBulgeWidth: stage.deformBulgeWidth,
                                    deformBulgeHeight: stage.deformBulgeHeight,
                                    deformBulgeSpeed: stage.deformBulgeSpeed,
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
                                skyDrawCalls += 1
                            }
                            worldEncodedDrawCalls += skyDrawCalls
                            worldEncodedDrawCallsByPass[worldPass] += skyDrawCalls
                            invalidateWorldStateCache()
                            entryCursor += 1
                            continue
                        }
                        if useCWorldBatchesForPass {
                            entryCursor += 1
                            continue
                        }
                        guard let lightmapTexture = texture(for: draw.lightmapTextureHandle, device: view.device) else {
                            entryCursor += 1
                            continue
                        }
                        let stageCount = min(Int(draw.stageCount), Int(Q3_METAL_MAX_STAGES))
                        guard stageCount > 0 else {
                            entryCursor += 1
                            continue
                        }
                        /* Identity flag: true if any stage in this draw
                         * binds the lightmap. C-side no longer sets
                         * Q3_METAL_WORLD_DRAWFLAG_LIGHTMAP_MULTIPLY, so
                         * detect directly from per-stage useLightmap.
                         * Kept as metadata for diagnostics; NOT consumed
                         * by the world fragment's rgbGen/alphaGen path. */
                        let drawHasLightmapStage = (0..<stageCount).contains { Self.worldStage(draw, $0).useLightmap != 0 }
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
                            /* Render any FOG_ONLY draw on pass 5. */
                            guard fogCD.w > 0,
                                  (draw.flags & fogOnlyBit) != 0,
                                  let worldAlphaPipelineState else {
                                entryCursor += 1
                                continue
                            }
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
                                deformBulgeWidth: stage.deformBulgeWidth,
                                deformBulgeHeight: stage.deformBulgeHeight,
                                deformBulgeSpeed: stage.deformBulgeSpeed,
                                autospriteMode: stage.autospriteMode,
                                debugMode: 0,
                                forceWhiteVertColor: 0,
                                alphaTestThreshold: 0,
                                fogOnly: 1,
                                stageUsesLightmap: 0,
                                drawHasLightmapStage: 0,
                                _pad0: (draw.flags & fogOverlayBit) != 0 ? 1.0 : 0.0
                            )
                            encoder.setRenderPipelineState(worldAlphaPipelineState)
                            let fogOverlayDraw = (draw.flags & fogOverlayBit) != 0
                            /* Regular fog passes and explicit fog-volume
                             * boundary sheets use LEQUAL so BSP depth occludes
                             * them. The previous always-pass state was safe only
                             * while the shader hid boundary sheets; once visible
                             * again, always-pass made the fog plane bleed through
                             * walls and read as a misaligned rectangle. */
                            encoder.setDepthStencilState(ensuredDepthStencilState(
                                additiveDepthStencilState,
                                device: view.device))
                            if fogOverlayDraw {
                                encoder.setCullMode(.none)
                            } else {
                                encoder.setCullMode(Self.metalCullMode(for: stage.cullMode))
                            }
                            encoder.setFragmentTexture(lightmapTexture, index: 0)
                            encoder.setFragmentTexture(lightmapTexture, index: 1)
                            // PBR Phase 3 — see main world bind site for rationale.
                            encoder.setFragmentTexture(ensurePBRWorldNormal(), index: 2)
                            // PBR Phase 8 — IBL env cube binding (fog pass).
                            if Q3_PBRIBLEnabled() != 0 && Q3_PBRWorldEnabled() != 0 {
                                encoder.setFragmentTexture(ensurePBREnvCube(), index: 3)
                                encoder.setFragmentSamplerState(ensurePBREnvSampler(), index: 1)
                            } else {
                                encoder.setFragmentTexture(nil, index: 3)
                            }
                            var pbrWorldFogParams = SIMD4<Float>(
                                Q3_PBRWorldEnabled() != 0 ? 1.0 : 0.0,
                                Q3_PBRWorldAmbientBoost(),
                                Q3_PBRWorldSpecBoost(),
                                0.0)
                            encoder.setFragmentBytes(&pbrWorldFogParams, length: 16, index: 3)
                            encoder.setFragmentBytes(&fogUniforms, length: MemoryLayout<WorldDrawUniforms>.stride, index: 0)
                            encoder.setVertexBytes(&fogUniforms, length: MemoryLayout<WorldDrawUniforms>.stride, index: 2)
                            encoder.drawIndexedPrimitives(
                                type: .triangle,
                                indexCount: Int(draw.indexCount),
                                indexType: .uint32,
                                indexBuffer: worldIndexBuffer,
                                indexBufferOffset: Int(draw.firstIndex) * MemoryLayout<UInt32>.stride
                            )
                            worldEncodedDrawCalls += 1
                            worldEncodedDrawCallsByPass[worldPass] += 1
                            invalidateWorldStateCache()
                            entryCursor += 1
                            continue
                        }
                        let stageIndex = entry.stageIndex
                        guard stageIndex >= 0 && stageIndex < stageCount else {
                            entryCursor += 1
                            continue
                        }
                            let stage = Self.worldStage(draw, stageIndex)
                            let blendMode = Self.worldBlendClass(for: stage)
                            let drawPass = Self.worldRenderPass(for: stage)
                            guard drawPass == worldPass else {
                                entryCursor += 1
                                continue
                            }
                            guard let baseTexture = texture(for: stage.textureHandle, device: view.device) else {
                                entryCursor += 1
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
                            let blendedDepthState = (stage.useLightmap == 0 && stage.depthWrite != 0)
                                ? depthStencilState
                                : additiveDepthStencilState
                            if drawPass == 4, let worldAdditiveFullPipelineState {
                                /* GL_ONE/GL_ONE — distinct pipeline from
                                 * alpha-modulated additive. */
                                setWorldPipelineStateCached(worldAdditiveFullPipelineState)
                                setWorldDepthStencilStateCached(ensuredDepthStencilState(additiveDepthStencilState, device: view.device))
                            } else if drawPass == 3, let worldAdditivePipelineState {
                                setWorldPipelineStateCached(worldAdditivePipelineState)
                                setWorldDepthStencilStateCached(ensuredDepthStencilState(additiveDepthStencilState, device: view.device))
                            } else if drawPass == 2, let worldAlphaPipelineState {
                                setWorldPipelineStateCached(worldAlphaPipelineState)
                                setWorldDepthStencilStateCached(ensuredDepthStencilState(blendedDepthState, device: view.device))
                            } else if drawPass == 1, let worldFilterPipelineState {
                                setWorldPipelineStateCached(worldFilterPipelineState)
                                setWorldDepthStencilStateCached(ensuredDepthStencilState(blendedDepthState, device: view.device))
                            } else {
                                setWorldPipelineStateCached(worldPipelineState)
                                setWorldDepthStencilStateCached(ensuredDepthStencilState(depthStencilState, device: view.device))
                            }
                            // STEP 6: per-stage cull mode. Replaces the
                            // previous hard-coded setCullMode(.none) which
                            // forced every world surface to two-sided.
                            setWorldCullModeCached(Self.metalCullMode(for: stage.cullMode))
                            let alphaTest = Self.alphaTestThreshold(for: stage.alphaFunc)
                            let chain = Self.fillTcMods(stage)
                            // Fog lookup. draw.fogIndex is Q3_METAL_NO_FOG
                            // (0xFFFFFFFF) for surfaces outside any fog
                            // volume; on q3dm6 this is every surface. The
                            // MSL shader skips the fog mix when .w == 0.
                            let (tv0, tv1) = Self.tcGenVectors(stage)
                            var drawUniforms = WorldDrawUniforms(
                                /* tcGen=4 (TCGEN_LIGHTMAP) routes the
                                 * world fragment to sample colorTexture
                                 * using in.lightmapTexCoord. For
                                 * lightmap stages the bound colorTexture
                                 * IS the lightmap. Mirrors ioq3 TCGEN_LIGHTMAP. */
                                tcGen: stage.useLightmap != 0 ? Float(4) : Float(stage.tcGen),
                                tcModCount: chain.count,
                                rgbGen: Float(stage.rgbGen),
                                alphaGen: Float(stage.alphaGen),
                                blendMode: Float(blendMode),
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
                                /* TODO: wire from per-stage clean->
                                 * rgbConstColor once Q3MetalWorldStage
                                 * carries it (parser-side change). */
                                rgbConstColor: SIMD4(1, 1, 1, 1),
                                /* World draws don't bind a refEntity. */
                                entityColor: SIMD4(1, 1, 1, 1),
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
                                deformBulgeWidth: stage.deformBulgeWidth,
                                deformBulgeHeight: stage.deformBulgeHeight,
                                deformBulgeSpeed: stage.deformBulgeSpeed,
                                autospriteMode: stage.autospriteMode,
                                debugMode: Coordinator.worldDebugMode,
                                /* forceWhiteVertColor no longer consumed
                                 * by the fragment shader. Field retained
                                 * for ABI; always 0. */
                                forceWhiteVertColor: 0,
                                alphaTestThreshold: alphaTest,
                                fogOnly: 0,
                                stageUsesLightmap: stage.useLightmap != 0 ? 1.0 : 0.0,
                                drawHasLightmapStage: drawHasLightmapStage ? 1.0 : 0.0,
                                pbrRoughness: stage.pbrRoughness,
                                pbrMetallic: stage.pbrMetallic,
                                _pad0: (draw.flags & combinedLightmapBit) != 0 ? 1.0 : 0.0
                            )
                            setWorldFragmentTextureCached(baseTexture, index: 0)
                            setWorldFragmentTextureCached(lightmapTexture, index: 1)
                            encoder.setFragmentBytes(&drawUniforms, length: MemoryLayout<WorldDrawUniforms>.stride, index: 0)
                            // Vertex shader reads deformWave + timeSeconds
                            // from WorldDrawUniforms. Bound at vertex
                            // buffer index 2 (0 = vertex buffer,
                            // 1 = WorldUniforms).
                            encoder.setVertexBytes(&drawUniforms, length: MemoryLayout<WorldDrawUniforms>.stride, index: 2)

                            var mergedIndexCount = Int(draw.indexCount)
                            var nextEntryCursor = entryCursor + 1
                            while nextEntryCursor < passEntries.count {
                                let nextEntry = passEntries[nextEntryCursor]
                                guard nextEntry.stageIndex >= 0 else { break }
                                let nextDraw = worldDraws[nextEntry.drawIndex]
                                guard nextEntry.stageIndex < min(Int(nextDraw.stageCount), Int(Q3_METAL_MAX_STAGES)) else { break }
                                let nextStage = Self.worldStage(nextDraw, nextEntry.stageIndex)
                                guard Self.worldDrawsCanMerge(draw,
                                                              stage: stage,
                                                              nextDraw: nextDraw,
                                                              nextStage: nextStage,
                                                              pass: worldPass,
                                                              mergedIndexCount: mergedIndexCount) else {
                                    break
                                }
                                mergedIndexCount += Int(nextDraw.indexCount)
                                nextEntryCursor += 1
                            }

                            encoder.drawIndexedPrimitives(
                                type: .triangle,
                                indexCount: mergedIndexCount,
                                indexType: .uint32,
                                indexBuffer: worldIndexBuffer,
                                indexBufferOffset: Int(draw.firstIndex) * MemoryLayout<UInt32>.stride
                            )
                            worldEncodedDrawCalls += 1
                            worldEncodedDrawCallsByPass[worldPass] += 1
                            entryCursor = nextEntryCursor
                    }
                        if useCWorldBatchesForPass, let batchIndexBuffer = cWorldBatchIndexBuffer {
                            for batch in cWorldBatches where Int(batch.renderPass) == worldPass && batch.indexCount > 0 {
                                let stageIndex = Int(batch.stageIndex)
                                guard stageIndex >= 0 && stageIndex < min(Int(batch.draw.stageCount), Int(Q3_METAL_MAX_STAGES)) else {
                                    continue
                                }
                                let stage = Self.worldStage(batch.draw, stageIndex)
                                if encodeNormalWorldDraw(batch.draw,
                                                         stage,
                                                         worldPass,
                                                         batchIndexBuffer,
                                                         Int(batch.firstIndex) * MemoryLayout<UInt32>.stride,
                                                         Int(batch.indexCount)) {
                                    worldEncodedDrawCalls += 1
                                    worldEncodedDrawCallsByPass[worldPass] += 1
                                }
                            }
                        }
                    } // end worldPass loop
                    worldEncodeMs = (CACurrentMediaTime() - worldEncodeStart) * 1000.0
                }

                debugFrameCounter &+= 1
                if debugFrameCounter % 60 == 0 {
                    let now = CACurrentMediaTime()
                    let frameDelta = debugFrameCounter &- lastPerfLogFrame
                    let dt = max(now - lastPerfLogTime, 0.0001)
                    let avgFps = Double(frameDelta) / dt
                    let avgMs = 1000.0 / max(avgFps, 0.0001)
                    lastPerfLogFrame = debugFrameCounter
                    lastPerfLogTime = now
                    let axis0 = SIMD3<Float>(sceneView.viewAxis.0, sceneView.viewAxis.1, sceneView.viewAxis.2)
                    let axis1 = SIMD3<Float>(sceneView.viewAxis.3, sceneView.viewAxis.4, sceneView.viewAxis.5)
                    let axis2 = SIMD3<Float>(sceneView.viewAxis.6, sceneView.viewAxis.7, sceneView.viewAxis.8)
                    let fovX = String(format: "%.2f", sceneView.fovX)
                    let fovY = String(format: "%.2f", sceneView.fovY)
                    let frameCpuMs = (CACurrentMediaTime() - drawFrameStart) * 1000.0
                    print(
                        "[Metal] world frame \(debugFrameCounter) " +
                        "vieworg=(\(sceneView.viewOrigin.0), \(sceneView.viewOrigin.1), \(sceneView.viewOrigin.2)) " +
                        "axis0=\(formatVector(axis0)) axis1=\(formatVector(axis1)) axis2=\(formatVector(axis2)) " +
                        "fov=(\(fovX), \(fovY)) " +
                        String(format: "fps=%.1f ms=%.2f q3Ms=%.2f drawableMs=%.2f frameCpuMs=%.2f ", avgFps, avgMs, q3FrameMs, drawableAcquireMs, frameCpuMs) +
                        "draws=\(snapshot.worldCommandCount) entries=\(worldPassEntryCount) encoded=\(worldEncodedDrawCalls) " +
                        "passEntries=\(worldPassEntryCounts) passEncoded=\(worldEncodedDrawCallsByPass) " +
                        String(format: "batchMs=%.2f copyMs=%.2f encodeMs=%.2f ", worldBatchBuildMs, worldBatchCopyMs, worldEncodeMs) +
                        "batchGroups=\(worldBatchGroupCounts) " +
                        "verts=\(snapshot.worldVertexCount) indices=\(snapshot.worldIndexCount)"
                    )
                    print("[Metal] world MVP \(formatMatrix(viewProjection))")
                }
            }

            /* RT world composite must happen before raster entities/HUD.
             * The trace replaces/blends only the already-rendered world color;
             * subsequent entity, flare, sub-scene, and UI passes draw over it.
             * This keeps r_rt_mix=1 usable as "RT world + raster weapon/HUD"
             * instead of the old after-everything overlay that hid the weapon
             * and HUD. */
            if let device = view.device,
               Q3MetalRenderer_IsWorldLoaded() != 0,
               let sceneView = Q3MetalRenderer_GetSceneView()?.pointee {
                if (!worldASBuilt || worldASGeneration != snapshot.worldGeneration),
                   worldVertexBuffer != nil, worldIndexBuffer != nil {
                    worldAccelerationStructure = buildWorldAccelerationStructure(device: device)
                    worldASBuilt = (worldAccelerationStructure != nil)
                    worldASGeneration = worldASBuilt ? snapshot.worldGeneration : 0
                }
                let rtTargetTexture = (upscaleActive ? upscaleColorTarget : drawable.texture) ?? drawable.texture
                if Q3_RTMix() > 0 {
                    encoder.endEncoding()
                    _ = encodeRTOverlay(commandBuffer: commandBuffer,
                                        rasterTexture: rtTargetTexture,
                                        outputDrawableTexture: rtTargetTexture,
                                        device: device,
                                        sceneView: sceneView,
                                        renderW: renderW,
                                        renderH: renderH)
                    let postRTPass = makeLoadedRenderPassDescriptor(colorTexture: rtTargetTexture,
                                                                    depthTexture: descriptor.depthAttachment.texture)
                    guard let postRTEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: postRTPass) else {
                        return
                    }
                    encoder = postRTEncoder
                    encoder.label = "Q3.render.postRT"
                    encoder.setViewport(MTLViewport(originX: 0, originY: 0,
                                                    width: Double(renderW),
                                                    height: Double(renderH),
                                                    znear: 0.0,
                                                    zfar: 1.0))
                    encoder.setScissorRect(MTLScissorRect(x: 0, y: 0,
                                                           width: renderW,
                                                           height: renderH))
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
                // Q3 per-stage wrap routing — sampler is bound per-draw
                // inside the loop below based on the new
                // Q3_METAL_ENTITY_DRAWFLAG_CLAMPMAP bit (sourced from the
                // Q3 .shader `clampmap` vs `map` directive). World samp
                // (.repeat) is the default for `map` stages (quad damage
                // breathing field, scrolling chrome shells); ui samp
                // (.clampToEdge) for `clampmap` stages (dlight projection
                // discs, HUD pics). Seed with repeat — the prior
                // single-bind-clampToEdge here killed the quad shell.
                encoder.setFragmentSamplerState(worldSamplerState, index: 0)
                var entityLastSamplerWasClamp: Bool = false

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
                        /* deformVertexes wave (shell shaders: quad, quadWeapon,
                         * regen, battlesuit). Per-draw because each customShader
                         * carries its own div/base/amp. */
                        Self.packEntityDeform(handle: draw.textureHandle, into: &entityUniforms)
                        /* Per-draw refEntity_t.shaderRGBA fed through to MSL
                         * for rgbGen=entity / oneMinusEntity (5/6) and
                         * alphaGen=entity / oneMinusEntity (5/6). */
                        let ec = draw.entityColor
                        entityUniforms.entityColor = SIMD4<Float>(ec.0, ec.1, ec.2, ec.3)
                        entityUniforms.timeSeconds = draw.shaderTime
                        entityUniforms.suppressDlights = (drawPass == 3 || drawPass == 5) ? 1 : 0
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
                        /* CRITICAL: also bind to the vertex stage. Before
                         * this, entityUniforms was bound ONCE before the
                         * loop (line ~3498) with the initial state where
                         * deformWaveFunc=0, then per-draw updates from
                         * packEntityDeform / packEntityTcMods / etc. only
                         * pushed to setFragmentBytes. The vertex shader
                         * kept reading the stale outside-loop uniforms —
                         * so q3_entity_vertex's `if (uniforms.deformWaveFunc
                         * != 0u)` outer guard always failed for chrome
                         * shell entities (powerups/quadWeapon, regen,
                         * battlesuit, battleWeapon, redflag, blueflag),
                         * silently skipping the +base unit halo expansion.
                         * Diagnosed via 10× multiplier producing zero
                         * visible effect — proved the block never entered.
                         * Fragment-only path was a footgun: tcGen env +
                         * chrome appearance worked because those uniforms
                         * are fragment-side; deformWave is vertex-side. */
                        encoder.setVertexBytes(&entityUniforms, length: MemoryLayout<EntityUniforms>.stride, index: 1)
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
                            // NOTE 2026-06-01: tried swapping to depthStencilState
                            // (write=YES) so the fog volume could see alpha
                            // entities. Symptom did exist (health/armor floating
                            // above fog) but the fix had cross-pass side effects
                            // — fog turned green, rocket-explosion brightness
                            // dropped. The Q3.entity.alpha pipeline is shared
                            // by multi-stage shaders where some stages also
                            // route through additive blending; writing depth on
                            // an alpha stage occluded subsequent additive stages
                            // of the same entity. Proper fix requires per-stage
                            // depth control (write depth only on the OPAQUE
                            // base stage of multi-stage entity shaders, leave
                            // additive overlay stages with write=NO). Defer.
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
                        // PBR Phase 1: when q3_pbr_lookup_by_name matched
                        // a Q3 shader (rocket / shotgun / bfg / etc.), the
                        // C-side stamped pbrMaterial on the metalTexture
                        // and we bind the HD DDS albedo here instead of
                        // the original pak0 JPG-decoded texture. Falls
                        // back to the original on miss / DDS-load fail.
                        let pbrTex = pbrAlbedoTexture(for: draw.textureHandle)
                        encoder.setFragmentTexture(pbrTex ?? texture, index: 0)
                        // PBR Phase 2 — bind normal map to slot 1 if the
                        // material ships one. Nil bind leaves the slot
                        // unbound; q3_entity_fragment uses is_null_texture
                        // to skip the normal-mapped lighting branch.
                        encoder.setFragmentTexture(pbrNormalTexture(for: draw.textureHandle), index: 1)
                        // PBR Phase 4 — viewmodel-vs-world entity gating.
                        // Viewmodels (RF_DEPTHHACK) get the wide
                        // (0.6..1.2) range for prominent surface relief;
                        // world entities (spinning pickups, dropped
                        // weapons) get the tight (0.78..1.18) range to
                        // avoid Mikkelsen TBN derivative instability on
                        // rotating geometry.
                        var pbrNormalScaleEntity: Float = wantsDepthHack ? 1.0 : 0.0
                        encoder.setFragmentBytes(&pbrNormalScaleEntity, length: 4, index: 3)
                        // PBR Phase F — runtime tunable rim params at buffer(4).
                        var pbrRimParamsEntity = SIMD2<Float>(
                            Q3_PBRRimIntensity(), Q3_PBRRimFalloff())
                        encoder.setFragmentBytes(&pbrRimParamsEntity, length: 8, index: 4)
                        // PBR Phase 4 — Cook-Torrance specular textures.
                        // Roughness at slot 3, metallic at slot 4. The
                        // MSL fragment guards both with is_null_texture
                        // so weapons without the maps (machinegun, etc.)
                        // skip the specular block entirely. Currently
                        // only the rocket launcher has both maps wired
                        // in materials.json.
                        // PBR Phase 5 A/B gate — when r_pbr_phase5=0, bind nil
                        // for roughness + metallic so the MSL `hasFullPBR`
                        // check falls through and the Cook-Torrance + Burley
                        // direct-sun block is skipped. Pure v6 Fresnel rim
                        // remains active. Note: this also disables Phase 6 IBL
                        // (gated inside hasFullPBR) so a clean Phase 5 A/B
                        // requires IBL stays on — but IBL is only PRESENT
                        // inside hasFullPBR, so without Phase 5 there's no
                        // hasFullPBR block to host IBL either. Two-axis A/B
                        // (phase5 × ibl) needs both cvars: r_pbr_phase5=0
                        // → no GGX peak, no IBL; r_pbr_ibl=0 → IBL replaced
                        // by 0.35 ambient floor (Phase 5 GGX still fires).
                        let phase5Enabled = Q3_PBRPhase5Enabled() != 0
                        encoder.setFragmentTexture(phase5Enabled ? pbrRoughnessTexture(for: draw.textureHandle) : nil, index: 3)
                        encoder.setFragmentTexture(phase5Enabled ? pbrMetallicTexture(for: draw.textureHandle) : nil, index: 4)
                        // Phase 6 IBL — procedural env cubemap + dedicated
                        // clampToEdge sampler. Bound nil-safe; MSL guards via
                        // is_null_texture so a fail-to-alloc falls back to
                        // Phase 5 ambient floor without crashing.
                        if Q3_PBRIBLEnabled() != 0 {
                            encoder.setFragmentTexture(ensurePBREnvCube(), index: 5)
                            encoder.setFragmentSamplerState(ensurePBREnvSampler(), index: 1)
                        } else {
                            encoder.setFragmentTexture(nil, index: 5)
                        }
                        // Per-draw sampler routing.
                        //
                        // Two ways to land on clampToEdge:
                        //   1. Q3_METAL_ENTITY_DRAWFLAG_CLAMPMAP bit — set
                        //      from the shader's `clampmap` directive via
                        //      EntityFlagsForTexture → wrapClampMode.
                        //   2. isScenePoly — force clamp for blast-marks /
                        //      blood / shadow decals submitted via
                        //      RE_AddPolyToScene. Q3 decal textures fade
                        //      to alpha=0 at UV edges; with the world
                        //      sampler's .repeat wrap, edge UVs (~0.99
                        //      from the poly clip) sample from the
                        //      opposite side of the texture (which has
                        //      alpha=1 near the center), producing the
                        //      "checkerboard square tile" artifact the
                        //      user reported on rocket blasts. Decal
                        //      shaders use `map` not `clampmap`, so the
                        //      CLAMPMAP flag is off — but Q3's stock
                        //      ref_gl behaviour is to clamp ALL scene
                        //      polys regardless.
                        let wantClamp = isScenePoly ||
                            (draw.flags & UInt32(Q3_METAL_ENTITY_DRAWFLAG_CLAMPMAP)) != 0
                        if wantClamp != entityLastSamplerWasClamp {
                            encoder.setFragmentSamplerState(wantClamp ? uiSamplerState : worldSamplerState, index: 0)
                            entityLastSamplerWasClamp = wantClamp
                        }
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

            let mainSceneViewForLatePasses = Q3MetalRenderer_GetSceneView()?.pointee
            var mainFlaresDrawnBeforeFog = false
            if wantsFogRayBox, let sceneView = mainSceneViewForLatePasses {
                /* Draw BSP flare billboards before the depth-limited fog
                 * volume pass so fog attenuates light sprites just like the
                 * already-encoded world/entities. Keeping flares in the
                 * postFog encoder made Q3.entity.additive appear as an
                 * unfogged light artifact, and that persisted into Q3.ui
                 * because UI is simply later in the same framebuffer. */
                mainFlaresDrawnBeforeFog = encodeMainFlarePass(
                    encoder: encoder,
                    sceneView: sceneView,
                    snapshot: snapshot,
                    device: view.device)
            }

            if let sceneView = mainSceneViewForLatePasses,
               let device = view.device,
               let sceneDepth,
               wantsFogRayBox {
                encoder.endEncoding()
                // Substitute upscale RT for drawable when MetalFX is
                // active — fog must read/write the same texture the main
                // render targeted, otherwise we'd lose the world geometry.
                let fogColorTex = (upscaleActive ? upscaleColorTarget : drawable.texture) ?? drawable.texture
                encodeFogVolumeRayBox(commandBuffer: commandBuffer,
                                      colorTexture: fogColorTex,
                                      depthTexture: sceneDepth,
                                      device: device,
                                      sceneView: sceneView)
                let postFogPass = makeLoadedRenderPassDescriptor(colorTexture: fogColorTex,
                                                                 depthTexture: sceneDepth)
                guard let postFogEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: postFogPass) else {
                    return
                }
                encoder = postFogEncoder
                encoder.label = "Q3.render.postFog"
                encoder.setViewport(MTLViewport(originX: 0,
                                                originY: 0,
                                                width: Double(renderW),
                                                height: Double(renderH),
                                                znear: 0.0,
                                                zfar: 1.0))
                encoder.setScissorRect(MTLScissorRect(x: 0, y: 0,
                                                       width: renderW,
                                                       height: renderH))
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
                    encoder.setFragmentBytes(&subUniforms, length: MemoryLayout<EntityUniforms>.stride, index: 1)
                    // HUD sub-scene entity samples need clampToEdge — see
                    // comment at the world-scene entity bind above. Same
                    // reason: dlight/sprite/refraction stages tile under
                    // .repeat. Sub-scenes run inside Q3.render.postFog.
                    encoder.setFragmentSamplerState(uiSamplerState, index: 0)
                    Self.bindDlightBlock(snapshot: snapshot, encoder: encoder, index: 2)

                    let first = Int(scene.entityCommandFirst)
                    let rawEnd = first + Int(scene.entityCommandCount)
                    let end = min(max(first, rawEnd), allEntityDraws.count)
                    guard first < end else { continue }
                    for drawIdx in first..<end {
                        let draw = allEntityDraws[drawIdx]
                        guard draw.indexCount > 0 else { continue }
                        guard let texture = texture(for: draw.textureHandle, device: view.device) else { continue }
                        // PBR Phase 1 — entity sub-pass (HUD heads,
                        // ammo rotations, scoreboard portraits). Same
                        // PBR-or-fallback rule as the main entity pass.
                        let pbrTex = pbrAlbedoTexture(for: draw.textureHandle)
                        encoder.setFragmentTexture(pbrTex ?? texture, index: 0)
                        // PBR Phase 2 — bind normal map to slot 1 if the
                        // material ships one. Nil bind leaves the slot
                        // unbound; q3_entity_fragment uses is_null_texture
                        // to skip the normal-mapped lighting branch.
                        encoder.setFragmentTexture(pbrNormalTexture(for: draw.textureHandle), index: 1)
                        // PBR Phase 4 — HUD/scoreboard sub-pass: world-style tight range.
                        var pbrNormalScaleSub: Float = 0.0
                        encoder.setFragmentBytes(&pbrNormalScaleSub, length: 4, index: 3)
                        // PBR Phase F — rim params at buffer(4) — same defaults as main entity pass
                        // so HUD entities (rotating weapon icons) read sensibly.
                        var pbrRimParamsSub = SIMD2<Float>(
                            Q3_PBRRimIntensity(), Q3_PBRRimFalloff())
                        encoder.setFragmentBytes(&pbrRimParamsSub, length: 8, index: 4)
                        encoder.drawIndexedPrimitives(
                            type: .triangle,
                            indexCount: Int(draw.indexCount),
                            indexType: .uint32,
                            indexBuffer: entityIndexBuffer,
                            indexBufferOffset: Int(draw.firstIndex) * MemoryLayout<UInt32>.stride)
                    }
                }

                // Restore full-screen viewport for flare + UI passes
                // (renderW/H = upscale RT size when MetalFX active).
                encoder.setViewport(MTLViewport(
                    originX: 0, originY: 0,
                    width: Double(renderW),
                    height: Double(renderH),
                    znear: 0.0, zfar: 1.0))
                encoder.setScissorRect(MTLScissorRect(
                    x: 0, y: 0,
                    width: renderW,
                    height: renderH))
            }

            /* Flare pass. When fog ray-box is active, main-scene flares
             * were already drawn before fog so they are attenuated by the
             * volume integration pass. Without fog, draw them here just
             * before UI as before. */
            if !mainFlaresDrawnBeforeFog, let sceneView = mainSceneViewForLatePasses {
                _ = encodeMainFlarePass(encoder: encoder,
                                        sceneView: sceneView,
                                        snapshot: snapshot,
                                        device: view.device)
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
                            // PBR Phase 1 — final fallback / overlay path
                            let pbrTex = pbrAlbedoTexture(for: draw.textureHandle)
                            encoder.setFragmentTexture(pbrTex ?? texture, index: 0)
                            encoder.drawPrimitives(type: .triangle, vertexStart: Int(draw.firstVertex), vertexCount: Int(draw.vertexCount))
                        }
                    }
                }
            }

            encoder.endEncoding()

            #if canImport(MetalFX)
            /* MetalFX spatial upscale: when active, all main render encoders
             * above wrote to upscaleColorTarget (renderW × renderH). Encode
             * the scaler now to fill the drawable with the upscaled image.
             * If RT overlay produced a composite texture, MetalFX reads that
             * instead of the raw raster color target. */
            if upscaleActive, let scaler = spatialScaler, let colorRT = (rtCompositeForUpscale ?? upscaleColorTarget) {
                scaler.colorTexture = colorRT
                scaler.outputTexture = drawable.texture
                scaler.encode(commandBuffer: commandBuffer)
            }
            #endif

            // Final-image postprocess tone curve (port of Q2 MetalPostprocess).
            // Compute kernel does saturate(rgb*intensity); pow(rgb, gamma).
            // Encoded after all render encoders + upscale, before present.
            // Always runs on the drawable so the tone curve is applied at
            // output resolution regardless of upscale state.
            encodePostprocess(commandBuffer: commandBuffer, drawable: drawable)
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

            pipelineDescriptor.label = "Q3.ui"
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
            uiOpaqueDesc.label = "Q3.ui.opaque"
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
            uiAdditiveDesc.label = "Q3.ui.additive"
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
            uiAdditiveAlphaDesc.label = "Q3.ui.additiveAlpha"
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
            uiFilterDesc.label = "Q3.ui.filter"
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

            worldPipelineDescriptor.label = "Q3.world.lit"
            do {
                worldPipelineState = try device.makeRenderPipelineState(descriptor: worldPipelineDescriptor)
            } catch {
                print("[Metal] Failed to create world pipeline: \\(error)")
            }

            let worldFilterPipelineDescriptor = worldPipelineDescriptor.copy() as! MTLRenderPipelineDescriptor
            Self.configureBlend(worldFilterPipelineDescriptor.colorAttachments[0],
                                src: Q3GLBlendFactor.dstColor.rawValue,
                                dst: Q3GLBlendFactor.zero.rawValue)
            worldFilterPipelineDescriptor.label = "Q3.world.filter"
            do {
                worldFilterPipelineState = try device.makeRenderPipelineState(descriptor: worldFilterPipelineDescriptor)
            } catch {
                print("[Metal] Failed to create filter world pipeline: \\(error)")
            }

            let worldAlphaPipelineDescriptor = worldPipelineDescriptor.copy() as! MTLRenderPipelineDescriptor
            Self.configureBlend(worldAlphaPipelineDescriptor.colorAttachments[0],
                                src: Q3GLBlendFactor.srcAlpha.rawValue,
                                dst: Q3GLBlendFactor.oneMinusSrcAlpha.rawValue)
            worldAlphaPipelineDescriptor.label = "Q3.world.alpha"
            do {
                worldAlphaPipelineState = try device.makeRenderPipelineState(descriptor: worldAlphaPipelineDescriptor)
            } catch {
                print("[Metal] Failed to create alpha world pipeline: \\(error)")
            }

            let fogVolumePipelineDescriptor = MTLRenderPipelineDescriptor()
            fogVolumePipelineDescriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
            /* The ray-box fog pass samples the scene depth texture but does
             * not bind a depth attachment.  Leaving a depth pixel format here
             * trips Metal validation on Simulator/debug devices:
             * "renderPipelineState pixelFormat must be Invalid, as no
             * texture is set." */
            fogVolumePipelineDescriptor.depthAttachmentPixelFormat = .invalid
            fogVolumePipelineDescriptor.vertexFunction = library.makeFunction(name: "q3_fog_volume_vertex")
            fogVolumePipelineDescriptor.fragmentFunction = library.makeFunction(name: "q3_fog_volume_fragment")
            fogVolumePipelineDescriptor.colorAttachments[0].isBlendingEnabled = true
            fogVolumePipelineDescriptor.colorAttachments[0].rgbBlendOperation = .add
            fogVolumePipelineDescriptor.colorAttachments[0].alphaBlendOperation = .add
            fogVolumePipelineDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            fogVolumePipelineDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
            fogVolumePipelineDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            fogVolumePipelineDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            fogVolumePipelineDescriptor.label = "Q3.fog.depthLimitedRayBox"
            do {
                fogVolumePipelineState = try device.makeRenderPipelineState(descriptor: fogVolumePipelineDescriptor)
            } catch {
                print("[Metal] Failed to create fog-volume pipeline: \\(error)")
            }

            /* Alpha-modulated additive (blendMode=1): GL_SRC_ALPHA/GL_ONE. */
            let worldAdditivePipelineDescriptor = worldPipelineDescriptor.copy() as! MTLRenderPipelineDescriptor
            Self.configureBlend(worldAdditivePipelineDescriptor.colorAttachments[0],
                                src: Q3GLBlendFactor.srcAlpha.rawValue,
                                dst: Q3GLBlendFactor.one.rawValue)
            worldAdditivePipelineDescriptor.label = "Q3.world.additive"
            do {
                worldAdditivePipelineState = try device.makeRenderPipelineState(descriptor: worldAdditivePipelineDescriptor)
            } catch {
                print("[Metal] Failed to create additive world pipeline: \\(error)")
            }

            /* Full-intensity additive (blendMode=5): GL_ONE/GL_ONE. Distinct
             * pipeline from worldAdditivePipelineState per strict spec. */
            let worldAdditiveFullDescriptor = worldPipelineDescriptor.copy() as! MTLRenderPipelineDescriptor
            Self.configureBlend(worldAdditiveFullDescriptor.colorAttachments[0],
                                src: Q3GLBlendFactor.one.rawValue,
                                dst: Q3GLBlendFactor.one.rawValue)
            worldAdditiveFullDescriptor.label = "Q3.world.additiveFull"
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
            skyPipelineDescriptor.label = "Q3.sky"
            do {
                skyPipelineState = try device.makeRenderPipelineState(descriptor: skyPipelineDescriptor)
            } catch {
                print("[Metal] Failed to create sky pipeline: \\(error)")
            }

            /* Full-intensity additive sky stage (blendMode=5, GL_ONE/GL_ONE).
             * Stock Q3 cloud overlays (killsky_2 over killsky_1). */
            let skyAdditiveDescriptor = skyPipelineDescriptor.copy() as! MTLRenderPipelineDescriptor
            Self.configureBlend(skyAdditiveDescriptor.colorAttachments[0],
                                src: Q3GLBlendFactor.one.rawValue,
                                dst: Q3GLBlendFactor.one.rawValue)
            skyAdditiveDescriptor.label = "Q3.sky.additive"
            do {
                skyAdditivePipelineState = try device.makeRenderPipelineState(descriptor: skyAdditiveDescriptor)
            } catch {
                print("[Metal] Failed to create additive sky pipeline: \\(error)")
            }

            /* Alpha-modulated additive sky stage (blendMode=1, GL_SRC_ALPHA/GL_ONE).
             * Distinct pipeline — NEVER shared with skyAdditivePipelineState. */
            let skyAdditiveAlphaDesc = skyPipelineDescriptor.copy() as! MTLRenderPipelineDescriptor
            Self.configureBlend(skyAdditiveAlphaDesc.colorAttachments[0],
                                src: Q3GLBlendFactor.srcAlpha.rawValue,
                                dst: Q3GLBlendFactor.one.rawValue)
            skyAdditiveAlphaDesc.label = "Q3.sky.additiveAlpha"
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

            entityPipelineDescriptor.label = "Q3.entity"
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
            entityAdditiveDesc.label = "Q3.entity.additive"
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
            entityAdditiveFullDesc.label = "Q3.entity.additiveFull"
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
            entityAlphaDesc.label = "Q3.entity.alpha"
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
            entityFilterDesc.label = "Q3.entity.filter"
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
            entitySubtractDesc.label = "Q3.entity.subtract"
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
            /* WAS .less — caused the powerups/quadWeapon chrome shell (and
             * all other shell-shader entities: powerups/quad, regen,
             * battlesuit, battleWeapon) to fail the depth test against
             * the underlying model. Sequence: (1) gun renders with depth
             * write → writes depth Z at gun surface; (2) chrome shell
             * renders with deformWave +0.5 unit offset → vertex shader
             * pushes shell verts toward camera; (3) under RF_DEPTHHACK
             * (which compresses the viewmodel's depth range to a tiny
             * near-z slice via viewport zRange / depth bias), the
             * 0.5-world-unit deform offset projects to *the same NDC
             * depth* as the gun surface; (4) `.less` requires strictly
             * less → equal-z FAILS → chrome rejected, invisible.
             * PC Q3 uses GL_LEQUAL for blend passes (ioq3 default
             * GLS_DEPTHFUNC_LEQUAL) so equal-z passes through. Matching
             * that fixes the chrome-shell invisibility while still
             * preventing additive effects from drawing through closer
             * solid geometry. Diff confirmed via /tmp/metalshader.log
             * QUAD-EMIT trace: chrome shell IS emitted every frame with
             * blendMode=5 ADDITIVE_FULL, tcGenEnv=1, deformWaveFunc=1
             * — all flags correct, only depth compare was rejecting it. */
            additiveLessDepthDescriptor.depthCompareFunction = .lessEqual
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
                vertexBuffer?.label = "Q3.vb.ui"
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
                                vertex.autospriteLongAxis.3),
                            lightingDiffuse: SIMD3<Float>(
                                vertex.lightingDiffuse.0,
                                vertex.lightingDiffuse.1,
                                vertex.lightingDiffuse.2)
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
            worldVertexBuffer?.label = "Q3.vb.world"
            worldIndexBuffer = device.makeBuffer(
                bytes: sourceIndexBase,
                length: sourceIndices.count * MemoryLayout<UInt32>.stride,
                options: .storageModeShared
            )
            worldIndexBuffer?.label = "Q3.ib.world"
            cachedWorldGeneration = generation
            worldAccelerationStructure = nil
            worldASBuilt = false
            worldASGeneration = 0
            rtASVertexBuffer = nil
            rtASIndexBuffer = nil
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
                entityVertexBuffer?.label = "Q3.vb.entity"
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
                entityIndexBuffer?.label = "Q3.ib.entity"
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
            if let namePtr = Q3MetalRenderer_GetTextureName(handle) {
                let name = String(cString: namePtr)
                texture.label = name.isEmpty ? "Q3.tex.\(handle)" : "Q3.tex.\(handle):\(name)"
            } else {
                texture.label = "Q3.tex.\(handle)"
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

        /* Encodes the main scene's camera-facing additive flare billboards.
         * Returns true only when a flare draw was actually encoded. When the
         * depth-limited fog ray-box is active this must run before that fog
         * pass so the fog attenuates light sprites instead of letting them
         * punch bright Q3.entity.additive artifacts through the final Q3.ui
         * framebuffer state. */
        @discardableResult
        private func encodeMainFlarePass(encoder: MTLRenderCommandEncoder,
                                         sceneView: Q3MetalSceneView,
                                         snapshot: Q3MetalFrameSnapshot,
                                         device: MTLDevice?) -> Bool {
            guard Q3MetalRenderer_GetFlareCount() > 0,
                  Q3MetalRenderer_GetFlareTextureHandle() != 0,
                  let flarePipeline = entityAdditivePipelineState,
                  let flareDepth = additiveLessDepthStencilState ?? additiveEntityDepthStencilState,
                  let flareTexture = texture(for: Q3MetalRenderer_GetFlareTextureHandle(), device: device) else {
                return false
            }

            let flareViewProjection = makeWorldViewProjection(sceneView)
            var flareUniforms = EntityUniforms(viewProjection: flareViewProjection)
            flareUniforms.cameraPos = SIMD3<Float>(sceneView.viewOrigin.0,
                                                   sceneView.viewOrigin.1,
                                                   sceneView.viewOrigin.2)
            flareUniforms.suppressDlights = 1

            encoder.setRenderPipelineState(flarePipeline)
            encoder.setDepthStencilState(flareDepth)
            encoder.setCullMode(.none)
            // Flare disc texture (Q3 tr.flareShader image) must clampToEdge
            // — with .repeat the falloff disc tiles across the framebuffer
            // and the rings persist through the fog volume into Q3.ui (see
            // fog-fix comment at encodeMainFlarePass call site). uiSampler
            // is the existing clampToEdge sampler created at line ~4031.
            encoder.setFragmentSamplerState(uiSamplerState, index: 0)
            encoder.setFragmentTexture(flareTexture, index: 0)
            // q3_entity_fragment declares the dlight block at buffer(2).
            // It is suppressed for flares, but binding defensively keeps
            // capture/validation state consistent with other entity draws.
            Self.bindDlightBlock(snapshot: snapshot, encoder: encoder, index: 2)

            drawFlarePass(encoder: encoder,
                          sceneView: sceneView,
                          uniforms: &flareUniforms,
                          device: device)
            return true
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
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<EntityUniforms>.stride, index: 1)
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
