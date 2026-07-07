import SwiftUI
import MetalKit
#if canImport(MetalFX)
import MetalFX
#endif
import GameController
import QuartzCore
import simd

/// Runtime output pixel target for the active iOS/iPadOS screen.
///
/// Keep boot-time Q3 `r_customwidth/height` and MTKView drawableSize in the
/// same coordinate system. `nativeBounds` can describe the physical panel while
/// SwiftUI/MTKView are using a different logical screen (iPad/OLED/external
/// display), which crops the 2D menu/HUD. `bounds * nativeScale` tracks the
/// actual UIKit screen and is normalized to landscape.
@MainActor
func Q3MetalOutputTargetSize(screen: UIScreen? = nil) -> CGSize {
    let screen = screen ?? UIScreen.main
    let scale = screen.nativeScale > 0 ? screen.nativeScale : screen.scale
    let px = CGSize(width: screen.bounds.width * scale,
                    height: screen.bounds.height * scale)
    let w = max(1, floor(max(px.width, px.height)))
    let h = max(1, floor(min(px.width, px.height)))
    return CGSize(width: w, height: h)
}

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
        if let envRaw = ProcessInfo.processInfo.environment["Q3_RT_MIX"]?.lowercased() {
            if let envQ = Q3RTMix(rawValue: envRaw) {
                NSLog("[Q3-RT] using env var Q3_RT_MIX=%@", envRaw)
                return envQ
            }
            let envAlias: Q3RTMix?
            switch envRaw {
            case "off", "0", "zero", "raster", "raster-only", "false", "no":
                envAlias = .off
            case "blend", "0.5", "half", "mixed", "mixed-on", "intermediate":
                envAlias = .blend
            case "pure", "1", "true", "yes", "on", "rt":
                envAlias = .pure
            default:
                envAlias = nil
            }
            if let envAlias {
                NSLog("[Q3-RT] using env var Q3_RT_MIX=%@ (alias mapped)", envRaw)
                return envAlias
            }
            NSLog("[Q3-RT] unrecognized Q3_RT_MIX=%@", envRaw)
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
        let mainScreen: UIScreen = view.window?.windowScene?.screen ?? UIScreen.main
        let maxFPS = max(mainScreen.maximumFramesPerSecond, 120)
        #endif
        view.preferredFramesPerSecond = maxFPS
        print("[Metal] display config screenMaxFPS=\(mainScreen.maximumFramesPerSecond) preferredFPS=\(view.preferredFramesPerSecond) lowPower=\(ProcessInfo.processInfo.isLowPowerModeEnabled ? 1 : 0) bounds=\(mainScreen.bounds) nativeBounds=\(mainScreen.nativeBounds) nativeScale=\(mainScreen.nativeScale) outputTarget=\(Q3MetalOutputTargetSize())")
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

        @objc @MainActor private func displayLinkDidFire(_ link: CADisplayLink) {
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
            /* USD-authored sun. Sourced from rtLightsCPU[0] when the
             * per-map light JSON contains a DistantLight (type=0); slot 0
             * is reserved for the sun by ensureRTLightBuffer's sort. The
             * MSL fragment uses sunColor.w as a 0/1 enable flag — when 0
             * it falls back to the legacy hardcoded float3(0.4, 0.5, 0.6)
             * direction so maps without USD lighting (or with no DistantLight)
             * still get the prior visual.
             *   sunDir   — direction TOWARD the sun in world space (per
             *              rt_lights_from_usda.py rot_xyz_dir = local -Z
             *              of the USDA rotateXYZ).
             *   sunIntensity — USD inputs:intensity * 2^exposure.
             *   sunColor.xyz — linear RGB color from USD inputs:color.
             *   sunColor.w   — 0=fall back to hardcoded sunDir, 1=use sunDir. */
            var sunDir: SIMD3<Float> = SIMD3<Float>(0.4, 0.5, 0.6)
            var sunIntensity: Float = 0
            var sunColor: SIMD4<Float> = SIMD4<Float>(1, 1, 1, 0)
            // Raster PCF sun shadow. Append-only; mirrors MSL WorldUniforms tail.
            var sunShadowMatrix: simd_float4x4 = matrix_identity_float4x4
            // x=bias, y=strength, z=texelSize, w=enabled
            var sunShadowParams: SIMD4<Float> = SIMD4<Float>(0, 0, 0, 0)
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
            var fovParams: SIMD4<Float>     // x=tanHalfFovX, y=tanHalfFovY, z=time
            var rtToneParams: SIMD4<Float>  // x=exposure, y=gamma exponent, z=ambient floor, w=normal mix
            var rtControlParams: SIMD4<Float> // x=resolutionScale, y=bounces, z=taaAlpha, w=taaEnabled
            // P1/P3 (must mirror MSL): x=lightCount, y=r_rt_light_scale,
            // z=r_rt_reflections, w=r_rt_refl_roughness_max
            var rtLightParams: SIMD4<Float> = SIMD4(0, 1, 0, 0.45)
            // RT atmosphere / miss-fill (must mirror MSL):
            // x=density, y=grey, z=sky/miss alpha, w=max fog factor.
            var rtAtmosphereParams: SIMD4<Float> = SIMD4(0, 0.22, 0, 0.85)
            // Step 2c: global RT PBR params (must mirror MSL append-only tail).
            // x = r_rt_normal_scale (0 = off), y = parallax scale (Step 5), z/w pad.
            var rtPBRGlobal: SIMD4<Float> = SIMD4(0, 0, 0, 0)
        }

        struct RTPrimitiveMaterial {
            var albedoSlot: UInt32
            var lightmapSlot: UInt32
            var tcModCount: UInt32
            var _pad0: UInt32 = UInt32.max // RT emissive texture slot, or invalid
            var alphaTcModControl: SIMD4<Float> // x=alphaTestThreshold
            var materialFlags: SIMD4<UInt32>    // x=isSky, y=isEmissive
            var materialParams: SIMD4<Float>    // x=emissiveIntensity
            var tcModTypes: SIMD4<UInt32>       // up to 4 tcMod types, 0=none
            var tcModParams0: SIMD4<Float>
            var tcModParams1: SIMD4<Float>
            var tcModParams2: SIMD4<Float>
            var tcModParams3: SIMD4<Float>
            // RT-only mirror of WorldDrawUniforms.spriteAtlasParams for PBR animation atlases.
            // x=cols, y=rows, z=fps, w=padding. 0 cols disables remap.
            var spriteAtlasParams: SIMD4<Float> = SIMD4(0, 0, 0, 0)
            // Step 1 (RT PBR sidecars) — packed as a single uint4 (16-byte aligned,
            // unambiguous Swift/MSL layout). x=normal, y=roughness, z=metallic, w=height
            // texture-table slot index; UInt32.max = no sidecar for that channel.
            // Kernel ignores these until Step 4; defaults make this a no-op layout change.
            var pbrSlots: SIMD4<UInt32> = SIMD4(UInt32.max, UInt32.max, UInt32.max, UInt32.max)
            // x = parallax scale (r_rt_parallax), y = normal scale, z/w = pad.
            var rtPBRParams: SIMD4<Float> = SIMD4(0, 1, 0, 0)
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
            /* RTX Remix sprite-sheet atlas params. When the bound PBR
             * albedo is a `*_animation` DDS (cols×rows grid of frames at
             * fps), the MSL world fragment sub-rect-samples one frame
             * based on shader time. .x = cols (0 = not an atlas; skip
             * remap), .y = rows, .z = fps, .w = padding. Atlas grid
             * applies to all of albedo / normal / roughness / metallic
             * since the per-material DDS quartet share the same layout
             * per materials.json remixConstants. */
            var spriteAtlasParams: SIMD4<Float> = SIMD4(0, 0, 0, 0)
            /* Emissive contribution. .xyz = sRGB color tint (1,1,1 = no
             * tint), .w = intensity multiplier. When .w == 0, the MSL
             * fragment skips the emissive add (cheap branch). Default
             * (1,1,1,0) means "tint white, intensity zero" — sampling the
             * default 1×1 black emissive texture yields 0 contribution. */
            var emissiveParams: SIMD4<Float> = SIMD4(1, 1, 1, 0)
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
            /* Parallax (height map) params — MUST stay the LAST field and
             * mirror the MSL struct tail exactly. .x = parallax scale
             * (r_pbr_parallax_scale, 0 = off / no height map bound),
             * .y/.z = pad, .w = parallax debug tint gate (r_pbr_parallax_tint). */
            var parallaxParams: SIMD4<Float> = SIMD4(0, 0, 0, 0)
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

        private static func worldPBRMaterialHandle(for stage: Q3MetalWorldStage) -> UInt32 {
            (stage.pbrMaterialHandle != 0) ? stage.pbrMaterialHandle : stage.textureHandle
        }

        private static func rtRepresentativeStage(for draw: Q3MetalWorldDrawCmd) -> Q3MetalWorldStage? {
            let stageCount = min(Int(draw.stageCount), Int(Q3_METAL_MAX_STAGES))
            guard stageCount > 0 else { return nil }

            func candidates(_ predicate: (Q3MetalWorldStage) -> Bool) -> Q3MetalWorldStage? {
                for i in 0..<stageCount {
                    let s = Self.worldStage(draw, i)
                    if s.useLightmap == 0 && s.textureHandle != 0 && predicate(s) { return s }
                }
                return nil
            }

            // RT has one material per primitive. Several stock Q3 shaders place
            // envmap/chrome/lightmap overlay stages before the real base texture
            // (q3tourney4: chrome_metal, pewter_shiney, etc.). Using stage 0 makes
            // solid walls sample chrome/water-like FX. Prefer the first non-env
            // opaque base stage, then any non-env base stage, and only fall back
            // when no better albedo-bearing stage exists.
            if let s = candidates({ $0.tcGen != 1 && Self.worldBlendClass(for: $0) == 0 }) { return s }
            if let s = candidates({ $0.tcGen != 1 }) { return s }
            if let s = candidates({ _ in true }) { return s }
            return nil
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
            hashCombine(&h, UInt64(Self.worldPBRMaterialHandle(for: stage)))
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
                  Self.worldPBRMaterialHandle(for: a) == Self.worldPBRMaterialHandle(for: b),
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

        private static func emptyTcMods() -> TcModChainPack {
            (SIMD4<Float>(0, 0, 0, 0),
             SIMD4<Float>(0, 0, 0, 0),
             SIMD4<Float>(0, 0, 0, 0),
             SIMD4<Float>(0, 0, 0, 0),
             SIMD4<Float>(0, 0, 0, 0),
             0)
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
        /// Per-process one-time set of texture names we've already logged
        /// `entity-atlas-load` for. Filters repeated logs across draws.
        nonisolated(unsafe) private static var loggedEntityAtlasNames: Set<String> = []
        /// Dedup set for the "forcing atlas params off" log — one line per
        /// resolved name (envmapyel, envmapgold, envmapbfg), not per draw.
        nonisolated(unsafe) private static var loggedEntityAtlasSingleFrameNames: Set<String> = []
        /// One-shot world atlas diagnostics. Confirms that a surface has
        /// atlas metadata and that the shader receives a monotonic animation
        /// clock in spriteAtlasParams.w (independent of Q3 demo shaderTime).
        nonisolated(unsafe) private static var loggedWorldAtlasNames: Set<String> = []

        /// Mirror of the world atlas-binding step into the entity path.
        /// When the entity draw's bound texture handle resolves to a PBR
        /// material with sprite_sheet metadata, write cols/rows/fps to
        /// `EntityUniforms.spriteAtlasParams` so the MSL entity fragment
        /// sub-rect-samples the current frame from the atlas DDS.
        /// Targets: textures/effects/envmapyel/gold/bfg (chrome animation
        /// on health/armor pickups), models/mapobjects/lamps/flare03,
        /// gfx/misc/raildisc_mono2, etc.
        /// Indirect-name map for entity shaders bound under a shader-name
        /// like `models/powerups/health/yellow` whose atlas metadata is
        /// keyed in materials.json under the underlying envmap source
        /// (e.g. `textures/effects/envmapyel`). When the handle-based PBR
        /// lookup yields no sprite_sheet_*, we retry with these targets.
        /// Covers all health/armor pickups + BFG ammo + battlesuit chrome.
        private static let entityAtlasIndirectNames: [(prefix: String, target: String)] = [
            ("models/powerups/health/yellow", "textures/effects/envmapyel"),
            ("models/powerups/health/red",    "textures/effects/envmapgold"),
            ("models/powerups/health/blue",   "textures/effects/envmapbfg"),
            ("models/powerups/armor",         "textures/effects/envmapgold"),
            ("models/powerups/ammo",          "textures/effects/envmapyel"),
            ("models/powerups/instant/bfg",   "textures/effects/envmapbfg"),
            ("powerups/regen",                "textures/effects/envmapgold"),
            ("powerups/battlesuit",           "textures/effects/envmapgold"),
        ]

        /// Returns the atlas albedo MTLTexture to bind at fragment slot 0
        /// when the entity draw resolved to an animated atlas material.
        /// Caller must replace the original color texture with the returned
        /// texture; setting `spriteAtlasParams` alone is a no-op if slot 0
        /// is still pointing at the static 64×64 envmap .jpg.
        ///
        /// Two-tier lookup:
        ///   1. Direct: `Q3MetalRenderer_GetPBRMaterial(handle)` for materials
        ///      where the entity handle already maps to atlas metadata.
        ///   2. Indirect-name fallback via `entityAtlasIndirectNames` — the
        ///      MD3 shader path (e.g. `models/powerups/health/yellow`) is
        ///      mapped to the underlying envmap source path
        ///      (`textures/effects/envmapyel`) whose hash-keyed materials.json
        ///      block carries the sprite_sheet_* fields and the atlas DDS.
        private func packEntityAtlas(handle: UInt32, into uniforms: inout EntityUniforms) -> MTLTexture? {
            var sprite_cols: Int32 = 0
            var sprite_rows: Int32 = 0
            var sprite_fps: Float = 0
            var resolvedName: String? = nil
            var atlasTexture: MTLTexture? = nil

            // Tier 1 — direct handle lookup.
            // hasAuthoredAlbedo gates Tier 2: when the handle's own material
            // already has authored albedo content (e.g. plasammo hash
            // 18180F4164BB190D with the green plasma ammo box albedo), we
            // MUST NOT fall through to the envmap-atlas override at Tier 2.
            // Without this gate, plasammo / machammo stage 1 (base color
            // model skin) inherits the `ammo/`-prefix → `envmapyel` chrome
            // atlas redirect intended only for first-stage envmap reflections
            // on health/armor pickups, and the authored base color is lost.
            var hasAuthoredAlbedo = false
            if let matPtr = Q3MetalRenderer_GetPBRMaterial(handle) {
                let mat = matPtr.pointee
                hasAuthoredAlbedo = (mat.albedo != nil)
                if mat.sprite_cols > 0 {
                    sprite_cols = mat.sprite_cols
                    sprite_rows = mat.sprite_rows > 0 ? mat.sprite_rows : 1
                    sprite_fps  = mat.sprite_fps
                    atlasTexture = pbrAlbedoTexture(for: handle)
                }
            }
            // Tier 2 — indirect-name fallback for envmap pickups
            // (health/armor/ammo + quad/regen/battlesuit/bfg). Skipped
            // when Tier 1 already found a material with authored albedo —
            // the authored asset wins over the catch-all envmap atlas.
            var isSingleFrameCapture = false
            if sprite_cols == 0,
               !hasAuthoredAlbedo,
               let cName = Q3MetalRenderer_GetTextureName(handle) {
                let name = String(cString: cName).lowercased()
                // Name-based authored-albedo check. Tier 1 above looks up by
                // HANDLE — but entity per-stage handles are composite names
                // like '*entity-stage:N:models/.../plasammo.TGA' that don't
                // resolve via Q3MetalRenderer_GetPBRMaterial(handle). The
                // name-based accessor normalizes the path and DOES hit the
                // authored materials_by_name entry (e.g. plasammo hash
                // 18180F4164BB190D). If it returns a non-nil albedo, this
                // material is authored — skip the envmap override.
                if let altPtr = Q3MetalRenderer_GetPBRMaterialByName(cName),
                   altPtr.pointee.albedo != nil {
                    return nil
                }
                for entry in Self.entityAtlasIndirectNames where name.contains(entry.prefix) {
                    if let altPtr = entry.target.withCString({ Q3MetalRenderer_GetPBRMaterialByName($0) }) {
                        let altMat = altPtr.pointee
                        if altMat.sprite_cols > 0 {
                            sprite_cols = altMat.sprite_cols
                            sprite_rows = altMat.sprite_rows > 0 ? altMat.sprite_rows : 1
                            sprite_fps  = altMat.sprite_fps
                            resolvedName = entry.target
                            let result = entityAtlasAlbedoTexture(name: entry.target)
                            atlasTexture = result.texture
                            isSingleFrameCapture = result.isCaptureFormat
                        }
                    }
                    break
                }
            }
            guard sprite_cols > 0 && sprite_rows > 0 else { return nil }
            // Single-frame capture DDS files (capture_textures_dds/<HASH>.dds)
            // are NOT real 4×4 atlases — they're snapshots of one envmap
            // moment. Treating them as atlases slices a coherent envmap
            // into 16 disjoint 16×16 tiles and cycles them, producing
            // scrambled chrome. Force atlas remap OFF for these so the
            // texture samples like a normal envmap under tcGen=environment.
            // Real ingested atlases (`_albedo_animation.a.rtex.dds`) loaded
            // via MTKTextureLoader keep their cols/rows/fps.
            if isSingleFrameCapture {
                if let n = resolvedName,
                   !Self.loggedEntityAtlasSingleFrameNames.contains(n) {
                    Self.loggedEntityAtlasSingleFrameNames.insert(n)
                    pbrLog("[Q3-PBR-SWIFT] entity-atlas single-frame capture name='\(n)' forcing atlas params off (capture DDS is not a 4x4 sprite sheet)")
                }
                uniforms.spriteAtlasParams = SIMD4<Float>(0, 0, 0, 0)
            } else if atlasTexture == nil {
                // The atlas metadata is only valid when the replacement
                // atlas texture actually loaded. Some Remix animation strips
                // exceed iOS device limits (e.g. pipe02 at 1024x20480). If
                // loading fails, leave sprite remap off so the classic fallback
                // texture is sampled normally instead of being sliced into
                // bogus fractional frames.
                uniforms.spriteAtlasParams = SIMD4<Float>(0, 0, 0, 0)
            } else {
                uniforms.spriteAtlasParams = SIMD4<Float>(
                    Float(sprite_cols),
                    Float(sprite_rows),
                    sprite_fps,
                    Float(CACurrentMediaTime() - frameTimeOrigin))
            }
            if let cName = Q3MetalRenderer_GetTextureName(handle) {
                let name = String(cString: cName)
                let logKey = resolvedName != nil ? "\(name)→\(resolvedName!)" : name
                if !Self.loggedEntityAtlasNames.contains(logKey) {
                    Self.loggedEntityAtlasNames.insert(logKey)
                    let fpsStr = String(format: "%.1f", sprite_fps)
                    pbrLog("[Q3-PBR-SWIFT] entity-atlas-load handle=\(handle) name='\(logKey)' cols=\(sprite_cols) rows=\(sprite_rows) fps=\(fpsStr) atlasTex=\(atlasTexture?.label ?? "nil")")
                }
            }
            return atlasTexture
        }

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
            /* 1 for sprites/effects whose source/PBR texture may be RGB-only
             * even though shader blending expects alpha from luminance. */
            var forceLuminanceAlpha: UInt32 = 0
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
            /* Entity-side mirror of WorldDrawUniforms.spriteAtlasParams.
             * RTX Remix sprite-sheet atlas (cols×rows grid of frames at
             * fps) for materials like textures/effects/envmapyel,
             * envmapgold, envmapbfg (chrome animations on health/armor
             * pickups), models/mapobjects/lamps/flare03, etc. When x>0
             * the entity fragment sub-rect-samples the current frame
             * using shader time. x=cols, y=rows, z=fps, w=pad. */
            var spriteAtlasParams: SIMD4<Float> = SIMD4(0, 0, 0, 0)
            /* Mirror of WorldDrawUniforms.emissiveParams. .xyz = tint,
             * .w = intensity. (1,1,1,0) means "no emissive contribution". */
            var emissiveParams: SIMD4<Float> = SIMD4(1, 1, 1, 0)
            /* 2026-06-10: viewmodel-only PBR base floor.
             *   .x = floor strength (from r_pbr_viewmodel_floor, default 0.65)
             *   .y = viewmodel gate (1.0 when RF_DEPTHHACK draw, 0.0 otherwise)
             *   .z, .w = pad
             * MSL applies `base.rgb = max(base.rgb, texel.rgb * .x)` only
             * when `.y > 0.5`. Default of (0,0,0,0) means off and is a
             * no-op for world entities + HUD sub-pass draws. */
            var viewmodelParams: SIMD4<Float> = SIMD4(0, 0, 0, 0)
            /* USD-authored sun for entity/viewmodel normal/specular path.
             * Append-only: MSL EntityUniforms mirrors these three fields at
             * the tail. sunColor.w = 0 means use legacy hardcoded direction. */
            var sunDir: SIMD3<Float> = SIMD3<Float>(0.3, 0.5, 0.7)
            var sunIntensity: Float = 0
            var sunColor: SIMD4<Float> = SIMD4<Float>(1, 1, 1, 0)
            /* 2026-06-19: additive-stage brightness cap (append-only tail,
             * mirrored at the end of MSL EntityUniforms). .x = max per-channel
             * output for additive/additive-full entity stages (from
             * r_rt_entity_additive_max). Non-additive draws set .x to a huge
             * value so the MSL `min()` is a no-op. Tames blown-out chrome
             * envmap / explosion FX that bleed bright through dark RT walls.
             * .y/.z/.w pad. Default (1e9, 0, 0, 0) = no clamp. */
            var additiveClampParams: SIMD4<Float> = SIMD4<Float>(1e9, 0, 0, 0)
        }

        /* Fragment-side dlight block bound at buffer(2) for both world and
         * entity passes. Layout: count + 12B pad (align to 16), then up to
         * 128 Q3MetalLight entries (32B each). This is 4112B, just over
         * Metal's set*Bytes comfort zone, so bindDlightBlock uses a tiny
         * MTLBuffer when the block exceeds 4KB. */
        private static let dlightMaxCount = 128
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
                                            device: MTLDevice?,
                                            index: Int,
                                            extra: [Q3MetalLight] = []) {
            var block = [UInt8](repeating: 0, count: dlightBlockSize)
            let engineCount = min(Int(snapshot.lightCount), dlightMaxCount)
            let extraCount = min(extra.count, dlightMaxCount - engineCount)
            block.withUnsafeMutableBytes { raw in
                guard let base = raw.baseAddress else { return }
                base.bindMemory(to: UInt32.self, capacity: 1).pointee = UInt32(engineCount + extraCount)
                if engineCount > 0, let src = Q3MetalRenderer_GetLights() {
                    memcpy(base.advanced(by: dlightHeaderSize), src,
                           engineCount * MemoryLayout<Q3MetalLight>.stride)
                }
                if extraCount > 0 {
                    extra.withUnsafeBytes { ex in
                        memcpy(base.advanced(by: dlightHeaderSize + engineCount * MemoryLayout<Q3MetalLight>.stride),
                               ex.baseAddress!, extraCount * MemoryLayout<Q3MetalLight>.stride)
                    }
                }
                if dlightBlockSize <= 4096 {
                    encoder.setFragmentBytes(base, length: dlightBlockSize, index: index)
                } else if let device,
                          let buffer = device.makeBuffer(bytes: base,
                                                         length: dlightBlockSize,
                                                         options: .storageModeShared) {
                    buffer.label = "Q3.dlightBlock.128"
                    encoder.setFragmentBuffer(buffer, offset: 0, index: index)
                } else {
                    // Should not happen on normal draw paths; bind a zero-count
                    // header rather than overrunning setFragmentBytes.
                    var zero = [UInt8](repeating: 0, count: dlightHeaderSize)
                    zero.withUnsafeMutableBytes { z in
                        if let zbase = z.baseAddress {
                            encoder.setFragmentBytes(zbase, length: dlightHeaderSize, index: index)
                        }
                    }
                }
            }
        }

        /// Raster-side light pop: the nearest authored Remix lights converted
        /// into static dlights so world surfaces, pickups, and the viewmodel
        /// react to map lighting even outside RT mode. Cached per frame.
        private var bakedDlights: [Q3MetalLight] = []
        private var bakedDlightsFrame: UInt32 = .max
        private func currentBakedDlights() -> [Q3MetalLight] {
            if bakedDlightsFrame == debugFrameCounter { return bakedDlights }
            bakedDlightsFrame = debugFrameCounter
            bakedDlights = []
            guard Q3_RTLights() != 0, !rtLightsCPU.isEmpty,
                  let sv = Q3MetalRenderer_GetSceneView()?.pointee else { return bakedDlights }
            let cam = SIMD3<Float>(sv.viewOrigin.0, sv.viewOrigin.1, sv.viewOrigin.2)
            let scale = Q3_RTLightScale()
            // Score = intensity / d²; take the strongest 10 local lights.
            var scored: [(Float, Int)] = []
            scored.reserveCapacity(rtLightsCPU.count)
            for (idx, l) in rtLightsCPU.enumerated() where l.dirType.w > 0.5 {
                let d = SIMD3<Float>(l.posRadius.x, l.posRadius.y, l.posRadius.z) - cam
                let d2 = max(simd_dot(d, d), 1.0)
                scored.append((l.colorIntensity.w / d2, idx))
            }
            scored.sort { $0.0 > $1.0 }
            for (_, idx) in scored.prefix(10) {
                let l = rtLightsCPU[idx]
                let intensity = l.colorIntensity.w * scale
                let radius = min(max(80.0 + 14.0 * sqrt(max(intensity, 0)), 120.0), 700.0)
                let bright = min(intensity * 0.01, 1.0) * 0.8
                guard bright > 0.01 else { continue }
                bakedDlights.append(Q3MetalLight(
                    origin: (l.posRadius.x, l.posRadius.y, l.posRadius.z),
                    radius: radius,
                    color: (l.colorIntensity.x * bright,
                            l.colorIntensity.y * bright,
                            l.colorIntensity.z * bright),
                    _pad: 0))
            }
            return bakedDlights
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
            // USD sun (slot 0 of per-map light buffer when DistantLight).
            // sunColor.w 0=fall back to hardcoded sunDir; 1=use sunDir.
            packed_float3 sunDir;
            float sunIntensity;
            float4 sunColor;
            float4x4 sunShadowMatrix;
            // x=bias, y=strength, z=texelSize, w=enabled
            float4 sunShadowParams;
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
            MSLLight lights[128];
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
            uint count = min(block.count, 128u);
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
            // .x = scale (0 = off), .y/.z = pad, .w = debug tint gate.
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
            // .x = floor strength (r_pbr_viewmodel_floor, default 0.65)
            // .y = viewmodel gate (1.0 for RF_DEPTHHACK, 0.0 otherwise)
            // .z, .w = pad. Fragment applies `base.rgb = max(base.rgb,
            // texel.rgb * .x)` only when `.y > 0.5`. Layout MUST match
            // Swift `EntityUniforms.viewmodelParams` (placed AFTER
            // emissiveParams) — moving this above emissiveParams scrambles
            // the GPU read offsets.
            float4 viewmodelParams;
            // USD-authored sun for entity/viewmodel normal/specular path.
            // sunColor.w = 0: use legacy hardcoded entity sun.
            packed_float3 sunDir;
            float sunIntensity;
            float4 sunColor;
            // 2026-06-19: additive-stage brightness cap. .x = max per-channel
            // output for additive entity stages (no-op when .x is huge).
            float4 additiveClampParams;
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


        float q3SunShadowVisibility(float3 worldPos,
                                    float3 worldNormal,
                                    constant WorldUniforms &uniforms,
                                    depth2d<float> sunShadowMap) {
            if (uniforms.sunShadowParams.w <= 0.5 || is_null_texture(sunShadowMap)) {
                return 1.0;
            }
            float3 n = worldNormal;
            if (length(n) < 1e-4) {
                n = float3(0.0, 0.0, 1.0);
            } else {
                n = normalize(n);
            }
            float4 sh = uniforms.sunShadowMatrix * float4(worldPos + n * 1.5, 1.0);
            if (abs(sh.w) < 1e-6) { return 1.0; }
            float3 ndc = sh.xyz / sh.w;
            if (ndc.x < -1.0 || ndc.x > 1.0 || ndc.y < -1.0 || ndc.y > 1.0 ||
                ndc.z < 0.0 || ndc.z > 1.0) {
                return 1.0;
            }
            float2 uv = float2(ndc.x * 0.5 + 0.5, 0.5 - ndc.y * 0.5);
            float texel = uniforms.sunShadowParams.z;
            float bias = uniforms.sunShadowParams.x;
            constexpr sampler shadowSampler(coord::normalized, address::clamp_to_edge, filter::linear);
            float receiver = ndc.z - bias;
            float visible = 0.0;
            for (int y = -1; y <= 1; ++y) {
                for (int x = -1; x <= 1; ++x) {
                    float d = sunShadowMap.sample(shadowSampler, uv + float2(x, y) * texel);
                    visible += (receiver <= d) ? 1.0 : 0.0;
                }
            }
            return visible * (1.0 / 9.0);
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
                                          depth2d<float> sunShadowMap [[texture(8)]],
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
            /* Parallax (height-map) offset. The old derivative frame built
             * T/B from perpendicular vectors without solving the UV
             * Jacobian, so many planar Q3 surfaces produced a near-zero
             * tangent-space view direction and scale=0 vs scale=2 frames
             * were visually identical. Solve the screen-space UV Jacobian
             * explicitly, then apply a bounded view-dependent offset before
             * albedo/normal/roughness/metallic/emissive sampling. */
            bool parallaxDebugTint = false;
            if (drawUniforms.parallaxParams.x > 0.0001 && tcGenMode == 0 &&
                !is_null_texture(heightMap)) {
                parallaxDebugTint = drawUniforms.parallaxParams.w > 0.5;
                float3 pdx = dfdx(in.worldPos);
                float3 pdy = dfdy(in.worldPos);
                float2 duvDx = dfdx(texCoord);
                float2 duvDy = dfdy(texCoord);
                float det = duvDx.x * duvDy.y - duvDx.y * duvDy.x;
                float3 Np = normalize(cross(pdx, pdy));
                float3 V = normalize(uniforms.cameraPos - in.worldPos);
                if (dot(Np, V) < 0.0) { Np = -Np; }
                if (abs(det) > 1.0e-7 && all(isfinite(Np)) && all(isfinite(V))) {
                    float invDet = 1.0 / det;
                    float3 T = normalize((pdx * duvDy.y - pdy * duvDx.y) * invDet);
                    float3 B = normalize((pdy * duvDx.x - pdx * duvDy.x) * invDet);
                    float vz = max(dot(V, Np), 0.08);
                    float2 viewTS = float2(dot(V, T), dot(V, B)) / vz;
                    viewTS = clamp(viewTS, float2(-4.0), float2(4.0));
                    // Remix height maps are authored as scalar relief. Keep
                    // normal gameplay default subtle (0.02), but make the
                    // diagnostic scale=2 sweep visibly move texels.
                    float h = heightMap.sample(textureSampler, texCoord).r;
                    float height = (h - 0.5) * drawUniforms.parallaxParams.x * 0.15;
                    float2 offset = viewTS * height;
                    if (all(isfinite(offset))) {
                        texCoord -= offset;
                    }
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
                            if (capAlign <= 0.70) {
                                /* Side walls of fog brushes are not visible
                                 * fog surfaces in stock Q3. Letting the fog
                                 * image alpha through here produces the hard
                                 * rectangular grey slab seen in q3dm4. */
                                f = 0.0;
                            }
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
            /* Stock-Q3 2× overbright for multi-pass lightmap stages.
             * Ported from c026768 (metal-q3dm4-16_93 branch) — when THIS
             * draw IS the lightmap stage (useLightmap=1 → bound to the
             * filter pipeline `Q3.world.filter` with GL_DST_COLOR/GL_ZERO
             * blend), the fragment output is multiplied into the
             * framebuffer. Without the ×2 here, multi-stage shaders like
             * `textures/gothic_block/killblockgeomtrn` and
             * `textures/gothic_floor/center2trn` modulate the composite
             * by raw lightmap.rgb (~0.5 average), crushing the wall/floor
             * brightness to ~half of stock-Q3. The combined-lightmap fast
             * path below (`_pad0 > 0.5`) is single-pass and gets its own
             * 2× via the inline `lm * 2.0` line. */
            if (drawUniforms.stageUsesLightmap > 0.5) {
                lit *= 2.0;
            }
            if (drawUniforms._pad0 > 0.5) {
                /* Combined base+lightmap fast path for simple opaque world
                 * surfaces. Equivalent to Q3's base pass followed by the
                 * GL_DST_COLOR/GL_ZERO lightmap pass, but avoids one Metal
                 * encoder draw for the common case. Complex multi-stage
                 * shaders still use explicit stage draws. Apply the stock-Q3
                 * 2× overbright on the lightmap sample so single-pass and
                 * multi-pass lightmap composites land at the same brightness. */
                float3 lm = lightmapTexture.sample(textureSampler, in.lightmapTexCoord).rgb * 2.0;
                lit *= lm;
            }
            /* Dynamic lights only on non-additive stages — ioq3 runs
             * dlights as a separate iteration that skips src=ONE
             * additive blends; we don't have that separate iteration so
             * we gate inline. */
            float3 surfaceNForLighting = in.worldNormal;
            if (length(surfaceNForLighting) <= 1e-4) {
                float3 dx = dfdx(in.worldPos);
                float3 dy = dfdy(in.worldPos);
                surfaceNForLighting = normalize(cross(dx, dy));
            }
            if (!additiveStage) {
                lit = applyDlights(lit, in.worldPos, surfaceNForLighting, dlights);
            }
            if (!additiveStage && drawUniforms.stageUsesLightmap < 0.5 && drawUniforms.fogOnly < 0.5) {
                float sunVis = q3SunShadowVisibility(in.worldPos, surfaceNForLighting, uniforms, sunShadowMap);
                float strength = saturate(uniforms.sunShadowParams.y);
                lit *= mix(1.0 - strength, 1.0, sunVis);
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
                // USD sun direction when WorldUniforms.sunColor.w > 0.5;
                // otherwise fall back to the legacy hardcoded vector so
                // maps without a baked DistantLight keep prior visuals.
                float3 sunDir = uniforms.sunColor.w > 0.5
                    ? normalize(float3(uniforms.sunDir))
                    : normalize(float3(0.4, 0.5, 0.6));
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
            if (parallaxDebugTint) {
                lit *= float3(0.6, 0.6, 1.4);
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
            /* Alpha synthesis radial masks must operate in local tile UVs,
             * not the repeated/scrolling beam coordinate. RT_LIGHTNING uses
             * s=len/256 so final texCoord.x often exceeds 1.0; using that
             * directly drove radial to zero and erased most of the beam. */
            float2 alphaMaskUV = fract(texCoord);

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
                float2 centered = alphaMaskUV - 0.5;
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
                    /* Dark-background additive FX (muzzle flashes, beams,
                     * plasma/rail cores) are authored as straight RGB on
                     * black, not premultiplied alpha. The old squared alpha
                     * plus RGB premultiply made weapon shots nearly vanish,
                     * especially through the GL_SRC_ALPHA/GL_ONE path. */
                    synthA = saturate(baseAlpha * 1.50);
                }
                synthA *= radial;
                if (uniforms.forceLuminanceAlpha != 1u) {
                    texel.rgb *= synthA;
                } else if (uniforms.suppressDlights != 0u) {
                    /* GL_ONE/GL_ONE and GL_SRC_ALPHA/GL_ONE Q3 FX are
                     * authored for the classic overbright/additive path and
                     * often have very dark JPG RGB (lightning3new mean is
                     * ~0.04/0.06/0.09). Boost only black-background additive
                     * FX after reconstructing their mask so weapon shots read
                     * as visible beams/flashes without reviving white-card
                     * inverse-luminance smoke/orb artifacts. */
                    texel.rgb *= 2.75;
                }
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

                // Half-Lambert against the map's USD DistantLight when
                // present; fallback preserves the older viewmodel look.
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
                float3 sunDir = uniforms.sunColor.w > 0.5
                    ? normalize(float3(uniforms.sunDir))
                    : normalize(float3(0.3, 0.5, 0.7));
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
                        float3 sunColor = uniforms.sunColor.w > 0.5
                            ? uniforms.sunColor.rgb * (2.4 * clamp(uniforms.sunIntensity, 0.25, 4.0))
                            : float3(2.4, 2.2, 1.9);  // warmish white sun

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
            // `.x = r_pbr_viewmodel_floor` (default 0.65). Reads
            // `texel.rgb` as the unlit albedo sample so the viewmodel always
            // shows its real material color through low-energy IBL — a
            // gameplay readability exception, not a PBR correctness fix.
            // World, entity pickup, and HUD sub-pass draws keep the default
            // (0,0,0,0) which makes the gate false and the floor a no-op.
            if (uniforms.viewmodelParams.y > 0.5) {
                // 2026-06-19: albedo-PROPORTIONAL floor fails for dark-albedo
                // metal weapons. The rocket launcher (metallic=1.0, dark RTX
                // albedo) has zero PBR diffuse and reflects only the ~0.08
                // grey env cube, so the lit result is ~0.05; the proportional
                // lift `dark_albedo * 0.65` is still near-black. Add an
                // ABSOLUTE minimum (`floor * 0.25`) so even a near-black
                // albedo gets a readable grey silhouette, while bright-albedo
                // weapons (machinegun) still take the larger proportional
                // term and look unchanged. floor=0 → both terms 0 → no-op.
                float vmFloor = uniforms.viewmodelParams.x;
                float3 vmFloorTerm = max(texel.rgb * vmFloor, float3(vmFloor * 0.25));
                base.rgb = max(base.rgb, vmFloorTerm);
            }
            // World-entity readability floor (non-viewmodel pickups). Full-metal
            // items (rocket launcher, plasma, ammo, health: metallic=1.0) have
            // zero PBR diffuse and only reflect the IBL cube; under the near-black
            // procedural envcube they go near-invisible (black silhouette / faint
            // Fresnel edge). Lift world entities by their unlit albedo so pickups
            // stay visible. Gate `.y <= 0.5` = NOT a viewmodel; `.w` =
            // r_pbr_entity_floor strength (0 = off). `.z` is the RT debug mask.
            if (uniforms.viewmodelParams.y <= 0.5 && uniforms.viewmodelParams.w > 0.0) {
                // 2026-06-19: same absolute-minimum hybrid as the viewmodel
                // floor above. Dark-albedo metal PICKUPS (rocket launcher on
                // the ground) need a guaranteed minimum, not just albedo*floor
                // — otherwise they read as black silhouettes against the dark
                // env-cube reflection.
                float entFloor = uniforms.viewmodelParams.w;
                float3 entFloorTerm = max(texel.rgb * entFloor, float3(entFloor * 0.25));
                base.rgb = max(base.rgb, entFloorTerm);
            }
            // Emissive accumulation. Same pattern as q3_world_fragment;
            // gated on intensity > 0 so the default zero-emission path
            // skips the sample. Sub-rect atlas remap (when active) used
            // the same texCoord, so emissive ride-alongs are consistent.
            if (uniforms.emissiveParams.w > 0.0) {
                float3 eSample = emissiveTexture.sample(textureSampler, in.texCoord).rgb;
                base.rgb += eSample * uniforms.emissiveParams.xyz * uniforms.emissiveParams.w;
            }
            // 2026-06-19: additive-stage brightness cap. Additive/additive-full
            // entity stages pass `additiveClampParams.x = r_rt_entity_additive_max`
            // here; their bright chrome-envmap / explosion specular otherwise
            // blooms and reads through dark RT walls even though the .lessEqual
            // depth test passed. Non-additive draws pass a huge .x so this is a
            // no-op. Applied AFTER emissive so the cap bounds the full additive
            // contribution this draw blends onto the destination.
            base.rgb = min(base.rgb, float3(uniforms.additiveClampParams.x));
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
        /// HDR linear-color resolve target at drawable size before final LDR postprocess.
        private var upscaleResolvedColorTarget: MTLTexture?
        private var upscaleDepthTarget: MTLTexture?
        #if canImport(MetalFX)
        private var spatialScaler: MTLFXSpatialScaler?
        #endif
        private var spatialUpscalePipelineState: MTLComputePipelineState?
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
            let key = (inputW, inputH, outputW, outputH)
            if upscaleColorTarget != nil && upscaleResolvedColorTarget != nil &&
                upscaleDepthTarget != nil && spatialScalerKey == key { return true }

            // Color RT (.private, [renderTarget, shaderRead] — Q3 renders
            // INTO this, compute scaler READS this.
            let colorDesc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba16Float,
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

            let resolvedDesc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba16Float,
                width: outputW, height: outputH, mipmapped: false)
            resolvedDesc.usage = [.shaderRead, .shaderWrite]
            resolvedDesc.storageMode = .private
            resolvedDesc.textureType = .type2D
            guard let resolved = device.makeTexture(descriptor: resolvedDesc) else {
                print("[MetalFX] ensureSpatialUpscaleTargets: resolve RT alloc failed (\(outputW)×\(outputH))")
                return false
            }
            resolved.label = "Q3.upscale.resolve"
            upscaleResolvedColorTarget = resolved

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

            spatialScalerKey = key
            #if canImport(MetalFX)
            spatialScaler = nil
            #endif
            print("[Q3-UPSCALE] compute scaler ready: \(inputW)×\(inputH) → \(outputW)×\(outputH) (\(upscaleQuality.label))")
            return true
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
        private var sunShadowDepthStencilState: MTLDepthStencilState?
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
        // Step 2a: argument encoder for the rtKernel RTTexTable (buffer index 8).
        // Cached at pipeline creation; used per-frame to encode albedo/lightmap
        // textures into an argument buffer (lifts the 128 direct-binding cap).
        private var rtTexArgEncoder: MTLArgumentEncoder?
        private var rtBlendPipelineState: MTLComputePipelineState?
        private var rtAccumPipelineState: MTLComputePipelineState?
        private var rtTexture: MTLTexture?
        private var rtAccumTexture: MTLTexture?
        private var rtHistoryTexture: MTLTexture?
        private var rtCompositeTexture: MTLTexture?
        private var rtWhiteTexture: MTLTexture?
        private var pbrMissingTexture: MTLTexture?
        private var sunShadowPipelineState: MTLRenderPipelineState?
        private var sunShadowTexture: MTLTexture?
        private var sunShadowTextureSize = MTLSize(width: 0, height: 0, depth: 1)
        private var sunShadowLoggedMaps = Set<String>()
        private var rtTextureSize = MTLSize(width: 0, height: 0, depth: 1)
        private var rtCompositeTextureSize = MTLSize(width: 0, height: 0, depth: 1)
        private var rtTexturePixelFormat: MTLPixelFormat = .invalid
        private var worldASBuilt = false
        private var worldASGeneration: UInt32 = 0
        private var rtASVertexBuffer: MTLBuffer?
        private var rtASPositionBuffer: MTLBuffer?
        private var rtASIndexBuffer: MTLBuffer?
        private var entityAccelerationStructure: MTLAccelerationStructure?
        private var entityASSize = 0
        private var entityASLogCounter: UInt64 = 0
        private var rtPrimitiveMaterialBuffer: MTLBuffer?
        private var rtPrimitiveMaterialBufferCache: [UInt64: MTLBuffer] = [:]
        private let rtMaxAlbedoSlots = 110
        private let rtMaxLightmapSlots = 16
        /* RT kernel uses Metal texture slots 2...111 for a single generic
         * 110-texture table. Reserve the tail for emissive DDS maps so
         * `r_rt_mix 1` can still show RTX/Remix emissive floors/arches/
         * jump pads instead of the old albedo-only 0.8 fake glow.
         * Kept small (6) to avoid starving albedo slots for weapons/items
         * — maps with many unique textures need the full table. */
        private let rtReservedEmissiveSlots = 6
        private var rtAlbedoHandles = [UInt32](repeating: 0, count: 110)
        private var rtAlbedoSlotKinds = [UInt32](repeating: 0, count: 110) // 0=albedo/classic, 1=emissive DDS
        private var rtLightmapHandles = [UInt32](repeating: 0, count: 16)
        private var rtLogPrintedOnce = false
        private var rtOverlayLogPrintedOnce = false
        // P0.2: one-shot log gate for the r_rt_preserve_entities mode line.
        private var rtPreserveEntitiesLogged = false
        // P1: per-map RT light set (RTX Remix authored, baked to JSON).
        private var rtLightBuffer: MTLBuffer?
        private var rtLightBufferCapacity: Int = 0
        private var rtLightCount: Int = 0
        private var rtLightMapName: String = ""
        private var rtDlightDiagLast: String = ""
        private var rtShadowCounterBuffers: [MTLBuffer] = []
        private var rtShadowCounterCursor: Int = 0
        private var rtLastShadowCounterLog: String = ""
        // CPU copy for raster-side dlight injection (currentBakedDlights).
        private var rtLightsCPU: [RTLightGPU] = []
        // Authored lights sorted for RT truncation: slot-0 sun first, then locals by intensity.
        private var rtLightsPrioritizedCPU: [RTLightGPU] = []

        private struct RTLightGPU {
            var posRadius: SIMD4<Float>
            var colorIntensity: SIMD4<Float>
            var dirType: SIMD4<Float>
        }

        /// Loads baseq3/pbr/lights/<map>.json (baked by
        /// scripts/rt_lights_from_usda.py from the RTX Remix per-map light
        /// authoring) into a GPU buffer. Distant lights are sorted to slot 0
        /// so the kernel can always-sample the sun. Cached per map; an empty
        /// 1-entry buffer is returned for maps with no light file so the
        /// kernel's buffer(6) slot is always valid.
        private func ensureRTLightBuffer(device: MTLDevice) -> (buffer: MTLBuffer?, count: Int) {
            let raw = Q3MetalRenderer_GetWorldMapName().flatMap { String(cString: $0) } ?? ""
            let base = (raw as NSString).lastPathComponent
            let map = (base as NSString).deletingPathExtension
            if map != rtLightMapName || rtLightBuffer == nil {
                rtLightMapName = map
                rtLightCount = 0
                var authored: [RTLightGPU] = []
                if !map.isEmpty,
                   let res = Bundle.main.resourcePath,
                   let data = FileManager.default.contents(atPath: res + "/baseq3/pbr/lights/\(map).json"),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let arr = obj["lights"] as? [[String: Any]] {
                    for l in arr {
                        func f3(_ k: String) -> SIMD3<Float> {
                            guard let v = l[k] as? [Any], v.count == 3 else { return SIMD3(0, 0, 0) }
                            return SIMD3(Float((v[0] as? NSNumber)?.doubleValue ?? 0),
                                         Float((v[1] as? NSNumber)?.doubleValue ?? 0),
                                         Float((v[2] as? NSNumber)?.doubleValue ?? 0))
                        }
                        let type = Float((l["type"] as? NSNumber)?.doubleValue ?? 1)
                        let intensity = Float((l["intensity"] as? NSNumber)?.doubleValue ?? 0)
                        let radius = Float((l["radius"] as? NSNumber)?.doubleValue ?? 0)
                        guard intensity > 0 else { continue }
                        let p = f3("pos"), c = f3("color"), d = f3("dir")
                        authored.append(RTLightGPU(
                            posRadius: SIMD4(p.x, p.y, p.z, radius),
                            colorIntensity: SIMD4(c.x, c.y, c.z, intensity),
                            dirType: SIMD4(d.x, d.y, d.z, type)))
                    }
                    // Sun first (kernel contract).
                    authored.sort { $0.dirType.w < $1.dirType.w }
                }
                rtLightsCPU = authored
                var prioritized = authored
                if !authored.isEmpty {
                    let hasSun = authored[0].dirType.w < 0.5
                    let start = hasSun ? 1 : 0
                    let locals = authored.dropFirst(start).sorted {
                        $0.colorIntensity.w > $1.colorIntensity.w
                    }
                    prioritized = hasSun ? [authored[0]] + locals : locals
                }
                rtLightsPrioritizedCPU = prioritized
                rtLightBuffer = nil
                rtLightBufferCapacity = 0
                let sun = authored.first?.dirType.w == 0 ? 1 : 0
                pbrLog("[RT] light set map='\(map)' lights=\(authored.count) sun=\(sun)")
                print("[RT] light set map='\(map)' lights=\(authored.count) sun=\(sun)")
            }

            let authoredSource = rtLightsPrioritizedCPU.isEmpty ? rtLightsCPU : rtLightsPrioritizedCPU
            let authoredCount = rtLightsCPU.count
            let maxTransient = 32
            let maxTotal = 128
            let engineRaw = Int(Q3MetalRenderer_GetFrameSnapshot()?.pointee.lightCount ?? 0)
            let transientBudget = min(engineRaw, maxTransient, maxTotal)
            let authoredBudget = max(0, maxTotal - transientBudget)
            var lights: [RTLightGPU]
            if authoredSource.count <= authoredBudget {
                lights = authoredSource
            } else {
                lights = Array(authoredSource.prefix(authoredBudget))
            }
            let authoredUsed = lights.count
            var transientCopied = 0
            var dropped = 0
            if engineRaw > 0, let src = Q3MetalRenderer_GetLights() {
                transientCopied = min(engineRaw, maxTransient, max(0, maxTotal - lights.count))
                dropped = max(0, engineRaw - transientCopied)
                let dyn = UnsafeBufferPointer(start: src, count: transientCopied)
                for l in dyn {
                    // Q3 passes intensity as both radius and brightness
                    // scale. Preserve radius and map brightness into RT's
                    // local-light intensity domain.
                    let radius = max(Float(l.radius), 1.0)
                    let intensity = min(max(radius * 0.75, 10.0), 800.0)
                    lights.append(RTLightGPU(
                        posRadius: SIMD4(Float(l.origin.0), Float(l.origin.1), Float(l.origin.2), radius),
                        colorIntensity: SIMD4(Float(l.color.0), Float(l.color.1), Float(l.color.2), intensity),
                        dirType: SIMD4(0, 0, -1, 1)))
                }
            }
            rtLightCount = lights.count
            let count = max(lights.count, 1)
            let length = count * MemoryLayout<RTLightGPU>.stride
            if rtLightBuffer == nil || rtLightBufferCapacity < count {
                rtLightBuffer = device.makeBuffer(length: length, options: .storageModeShared)
                rtLightBufferCapacity = count
                rtLightBuffer?.label = "Q3.RT.lights.\(map)"
            }
            if let buf = rtLightBuffer {
                let ptr = buf.contents().bindMemory(to: RTLightGPU.self, capacity: count)
                ptr[0] = RTLightGPU(posRadius: .zero, colorIntensity: .zero,
                                    dirType: SIMD4(0, 0, -1, 1))
                for (i, l) in lights.enumerated() { ptr[i] = l }
            }
            let diag = "\(authoredUsed):\(engineRaw):\(transientCopied):\(dropped)"
            if diag != rtDlightDiagLast {
                rtDlightDiagLast = diag
                let frame = Q3MetalRenderer_GetFrameSnapshot()?.pointee.frameNumber ?? 0
                let msg = "[Q3-DLIGHT] frame=\(frame) lightCount=\(lights.count) authored=\(authoredCount) engine=\(engineRaw) baked=\(authoredUsed) transient=\(transientCopied) dropped=\(dropped)"
                print(msg)
                pbrLog(msg)
            }
            return (rtLightBuffer, rtLightCount)
        }

        private func nextRTShadowCounterBuffer(device: MTLDevice) -> MTLBuffer? {
            let counterCount = 4
            let length = counterCount * MemoryLayout<UInt32>.stride
            while rtShadowCounterBuffers.count < 3 {
                guard let buf = device.makeBuffer(length: length, options: .storageModeShared) else {
                    return nil
                }
                buf.label = "Q3.RT.sunShadowCounters.\(rtShadowCounterBuffers.count)"
                memset(buf.contents(), 0, length)
                rtShadowCounterBuffers.append(buf)
            }
            let buf = rtShadowCounterBuffers[rtShadowCounterCursor]
            let ptr = buf.contents().bindMemory(to: UInt32.self, capacity: counterCount)
            let candidates = ptr[0]
            let occluded = ptr[1]
            let unoccluded = ptr[2]
            let sunPixels = ptr[3]
            if candidates != 0 || occluded != 0 || unoccluded != 0 || sunPixels != 0 {
                let sig = "\(rtLightMapName):\(sunPixels):\(candidates):\(occluded):\(unoccluded)"
                if sig != rtLastShadowCounterLog {
                    rtLastShadowCounterLog = sig
                    let msg = "[RT] sun shadow rays map='\(rtLightMapName)' sunPixels=\(sunPixels) candidates=\(candidates) occluded=\(occluded) unoccluded=\(unoccluded)"
                    print(msg)
                    pbrLog(msg)
                }
            }
            rtShadowCounterCursor = (rtShadowCounterCursor + 1) % rtShadowCounterBuffers.count
            return buf
        }

        private func populateEntitySun(_ uniforms: inout EntityUniforms) {
            guard rtLightCount > 0,
                  let sun = rtLightsCPU.first,
                  sun.dirType.w == 0 else { return }
            uniforms.sunDir = SIMD3<Float>(sun.dirType.x, sun.dirType.y, sun.dirType.z)
            uniforms.sunIntensity = sun.colorIntensity.w
            uniforms.sunColor = SIMD4<Float>(sun.colorIntensity.x,
                                             sun.colorIntensity.y,
                                             sun.colorIntensity.z,
                                             1.0)
        }
        private var rtLastMaterialRefreshTime: Float = 0
        private var rtLastMaterialSignature: UInt64 = 0
        private var rtLastEnvCubeLabel: String?
        private var rtHistoryValid = false
        private var rtJitterFrame: UInt32 = 0
        private var rtMetricsFrame: UInt64 = 0
        private var rtLastMetricsLogTime: CFTimeInterval = 0
        private var rtLastCameraPos: SIMD3<Float>?
        private var rtLastCameraForward: SIMD3<Float>?
        private var loggedPBROnlyWorldMisses: Set<UInt32> = []
        private var loggedWorldOwnerMaterialRoutes: Set<UInt64> = []
        private var loggedPBROnlyEntityMisses: Set<UInt32> = []
        /// RING-DIAG: dedup per (handle, pass) so the center2trn overlay diag
        /// fires once per surface stage, not every frame. Keyed by
        /// `(UInt64(handle) << 8) | UInt64(pass)`.
        private var loggedRingDiagKeys: Set<UInt64> = []
        /// Per-handle cache for `Q3MetalRenderer_GetPBRMaterial(...).albedo != nil`.
        /// Avoids re-doing the O(N) `q3_pbr_lookup_by_name` walk inside
        /// `Q3MetalRenderer_GetPBRMaterial` for composite entity per-stage
        /// handles where the material is unset at the metalTexture_t level —
        /// the entity FX-stage sidecar promotion gate at the draw site needs
        /// this signal per-draw, and the uncached path was ~25 µs/draw which
        /// blew encodeMs from 1.7 ms → 13 ms (8 fps) on q3dm1.
        /// `true`  = handle's material has a non-nil albedo string,
        /// `false` = lookup miss or albedo NULL — cached so we don't re-walk.
        private var entityHasAuthoredAlbedoCache: [UInt32: Bool] = [:]

        private struct PostprocessUniforms {
            var intensity: Float
            var gamma: Float
            var tonemap: Float
        }

        private struct RTBlendUniforms {
            var mixAmount: Float
            var bloomIntensity: Float
            var bloomThreshold: Float
            var bloomRadius: Float
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
                float tonemap;
            };

            kernel void q3_postprocess(texture2d<float, access::read> source [[texture(0)]],
                                       texture2d<float, access::write> target [[texture(1)]],
                                       constant PPUniforms &u [[buffer(0)]],
                                       uint2 tid [[thread_position_in_grid]]) {
                uint w = target.get_width();
                uint h = target.get_height();
                if (tid.x >= w || tid.y >= h) return;
                float4 c = source.read(tid);
                // Pre-exposure first so the ACES curve has HDR-ish values to
                // roll off. With the old hard `saturate(c.rgb * intensity)`,
                // any intensity > 1 clipped lit walls to flat white; the ACES
                // filmic curve instead lifts mid-tones and rolls highlights
                // smoothly back into [0,1], so exposure can be raised toward
                // the RTX reference brightness without blowout. (T3 exposure
                // parity — the postprocess input is the composited drawable,
                // which is still LDR-ish, so this reshapes tone rather than
                // recovering truly-clipped emissive; the HDR backbuffer is the
                // separate T2 follow-up for true highlight recovery.)
                float3 rgb = max(c.rgb * u.intensity, float3(0.0));
                if (u.tonemap > 0.5) {
                    // ACES filmic fit (Narkowicz) — same curve as the RT blendRT path.
                    rgb = (rgb * (2.51 * rgb + 0.03)) /
                          (rgb * (2.43 * rgb + 0.59) + 0.14);
                }
                rgb = pow(saturate(rgb), float3(u.gamma));
                target.write(float4(rgb, c.a), tid);
            }

            kernel void q3_spatial_upscale(texture2d<float, access::sample> source [[texture(0)]],
                                           texture2d<float, access::write> output [[texture(1)]],
                                           constant PPUniforms &u [[buffer(0)]],
                                           uint2 tid [[thread_position_in_grid]]) {
                uint w = output.get_width();
                uint h = output.get_height();
                if (tid.x >= w || tid.y >= h) return;
                constexpr sampler s(filter::linear, address::clamp_to_edge);
                float2 uv = (float2(tid) + 0.5) / float2(max(w, 1u), max(h, 1u));
                float4 c = source.sample(s, uv);
                float3 rgb = max(c.rgb * u.intensity, float3(0.0));
                if (u.tonemap > 0.5) {
                    rgb = (rgb * (2.51 * rgb + 0.03)) /
                          (rgb * (2.43 * rgb + 0.59) + 0.14);
                } else {
                    rgb *= u.intensity;
                }
                output.write(float4(saturate(rgb), c.a), tid);
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
                if let upFn = lib.makeFunction(name: "q3_spatial_upscale") {
                    spatialUpscalePipelineState = try? device.makeComputePipelineState(function: upFn)
                }
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
                                       sourceTexture: MTLTexture,
                                       outputTexture: MTLTexture) {
            if sourceTexture === outputTexture && Q3_PostprocessEnabled() == 0 { return }
            guard let device = commandBuffer.device as MTLDevice?,
                  let pso = ensurePostprocessPipeline(device: device),
                  let enc = commandBuffer.makeComputeCommandEncoder() else {
                return
            }
            enc.label = "Q3.postprocess"
            enc.setComputePipelineState(pso)
            enc.setTexture(sourceTexture, index: 0)
            enc.setTexture(outputTexture, index: 1)
            var u = PostprocessUniforms(intensity: Q3_PostprocessIntensity(),
                                        gamma: Q3_PostprocessGamma(),
                                        tonemap: Float(Q3_PostprocessTonemap()))
            enc.setBytes(&u, length: MemoryLayout<PostprocessUniforms>.size, index: 0)
            let w = outputTexture.width
            let h = outputTexture.height
            let threadsPerThreadgroup = MTLSize(width: 8, height: 8, depth: 1)
            let threadgroups = MTLSize(width: (w + 7) / 8,
                                       height: (h + 7) / 8,
                                       depth: 1)
            enc.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadsPerThreadgroup)
            enc.endEncoding()
            postprocessEncodeCount += 1
            if postprocessEncodeCount == 1 || postprocessEncodeCount % 120 == 0 {
                print("[MTL_POSTPROC] encode #\(postprocessEncodeCount) intensity=\(u.intensity) gamma=\(u.gamma) tonemap=\(u.tonemap) size=\(w)x\(h)")
            }
        }

        @MainActor
        private func ensureSpatialUpscalePipeline(device: MTLDevice) -> MTLComputePipelineState? {
            if let spatialUpscalePipelineState { return spatialUpscalePipelineState }
            _ = ensurePostprocessPipeline(device: device)
            return spatialUpscalePipelineState
        }

        @MainActor
        private func encodeSpatialUpscale(commandBuffer: MTLCommandBuffer,
                                          source: MTLTexture,
                                          output: MTLTexture) {
            guard let device = commandBuffer.device as MTLDevice?,
                  let pso = ensureSpatialUpscalePipeline(device: device),
                  let enc = commandBuffer.makeComputeCommandEncoder() else { return }
            enc.label = "Q3.spatialUpscale"
            enc.setComputePipelineState(pso)
            enc.setTexture(source, index: 0)
            enc.setTexture(output, index: 1)
            var u = PostprocessUniforms(intensity: Q3_PostprocessIntensity(),
                                        gamma: Q3_PostprocessGamma(),
                                        tonemap: 1.0)
            enc.setBytes(&u, length: MemoryLayout<PostprocessUniforms>.size, index: 0)
            let tg = MTLSize(width: 8, height: 8, depth: 1)
            let groups = MTLSize(width: (output.width + 7) / 8,
                                 height: (output.height + 7) / 8,
                                 depth: 1)
            enc.dispatchThreadgroups(groups, threadsPerThreadgroup: tg)
            enc.endEncoding()
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
                float4 rtToneParams;
                float4 rtControlParams;
                // P1/P3: x = light count, y = r_rt_light_scale,
                // z = r_rt_reflections (0/1), w = r_rt_refl_roughness_max.
                float4 rtLightParams;
                // x = atmosphere density, y = neutral grey color,
                // z = sky/miss alpha override, w = max surface fog factor.
                float4 rtAtmosphereParams;
                // Step 2c: x = r_rt_normal_scale (0 = off), y = parallax (Step 5), z/w pad.
                float4 rtPBRGlobal;
            };

            // P1: RTX Remix authored per-map light (baked from
            // <map>_lights.usda by scripts/rt_lights_from_usda.py).
            // type (dirType.w): 0 = distant/sun, 1 = sphere, 2 = disk,
            // 3 = rect (radius pre-converted to equivalent-area disk).
            struct RTLight {
                float4 posRadius;       // xyz world pos, w radius
                float4 colorIntensity;  // rgb linear color, w intensity
                float4 dirType;         // xyz emission dir, w type
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
                uint emissiveSlot; // index into texTable.albedo, or 0xFFFFFFFF
                float4 alphaTcModControl;
                uint4 materialFlags;
                float4 materialParams;
                uint4 tcModTypes;
                float4 tcModParams0;
                float4 tcModParams1;
                float4 tcModParams2;
                float4 tcModParams3;
                float4 spriteAtlasParams; // x=cols, y=rows, z=fps, w=pad; 0 cols = not an atlas
                // Step 1 (RT PBR sidecars) — must mirror the Swift struct exactly.
                uint4 pbrSlots;      // x=normal y=roughness z=metallic w=height slot; 0xFFFFFFFF = none
                float4 rtPBRParams;  // x=parallaxScale, y=normalScale, z/w=pad
            };

            // Step 2a: RT texture table moved into an argument buffer so the
            // 128 direct-binding limit no longer caps the table (room for PBR
            // sidecars later). albedo gets [[id(0..109)]], lightmap [[id(110..125)]].
            // Swift mirrors this id layout when encoding (see encodeRTOverlay).
            struct RTTexTable {
                array<texture2d<float>, 110> albedo;    // id 0..109
                array<texture2d<float>, 16> lightmap;   // id 110..125
                // Step 2b: PBR sidecar tables, PARALLEL to albedo (normal[i]/height[i]
                // correspond to the material at albedo slot i). Kernel does not read
                // these yet (Step 2c/5 wire sampling). id 126..235 / 236..345.
                array<texture2d<float>, 110> normal;    // id 126..235
                array<texture2d<float>, 110> height;    // id 236..345
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

            float rtHash12(float2 p) {
                float3 p3 = fract(float3(p.xyx) * 0.1031);
                p3 += dot(p3, p3.yzx + 33.33);
                return fract((p3.x + p3.y) * p3.z);
            }

            float3 rtCosineHemisphere(float3 n, float2 randv) {
                float phi = 6.2831853 * randv.x;
                float cosTheta = sqrt(max(0.0, 1.0 - randv.y));
                float sinTheta = sqrt(max(0.0, randv.y));
                float3 up = (abs(n.z) < 0.999) ? float3(0.0, 0.0, 1.0) : float3(1.0, 0.0, 0.0);
                float3 tangent = normalize(cross(up, n));
                float3 bitangent = cross(n, tangent);
                return normalize(tangent * cos(phi) * sinTheta + bitangent * sin(phi) * sinTheta + n * cosTheta);
            }

            kernel void rtKernel(texture2d<float, access::write> output [[texture(0)]],
                                 texturecube<float> envCube [[texture(1)]],
                                 const device RTTexTable& texTable [[buffer(8)]],
                                 constant RayTracingUniforms &uniforms [[buffer(0)]],
                                 acceleration_structure<> worldAS [[buffer(1)]],
                                 const device uint *indices [[buffer(2)]],
                                 const device RTWorldVertex *vertices [[buffer(3)]],
                                 const device RTPrimitiveMaterial *primitiveMaterials [[buffer(4)]],
                                 acceleration_structure<> entityAS [[buffer(5)]],
                                 const device RTLight *rtLights [[buffer(6)]],
                                 device atomic_uint *rtShadowCounters [[buffer(7)]],
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
                // 2026-06-09: force_opaque + assume_geometry_type were
                // attempted as intersector hints but don't exist on the
                // Metal version shipping with the iPad M4 toolchain — the
                // RT library failed to compile at runtime
                // ("no member named 'force_opaque' in
                // metal::raytracing::intersector<triangle_data>"). Reverted
                // to the default-configured intersector. The hints are
                // available on macOS Metal 3.x but not the iOS variant we
                // build against; revisit if Apple ships them in a later
                // iOS toolchain update.
                intersector<triangle_data> i;
                auto hit = i.intersect(r, worldAS);
                auto entityHit = i.intersect(r, entityAS);
                bool useEntityHit = uniforms.fovParams.w > 0.5 &&
                                    entityHit.type == intersection_type::triangle &&
                                    (hit.type != intersection_type::triangle || entityHit.distance < hit.distance);

                float3 color;
                float outputAlpha = 1.0;
                float primaryDistance = uniforms.jitterNearFar.w;
                if (useEntityHit) {
                    primaryDistance = entityHit.distance;
                    float shade = 1.0 - saturate(entityHit.distance / uniforms.jitterNearFar.w);
                    color = mix(float3(0.35, 0.35, 0.38), float3(0.9, 0.9, 0.95), shade);
                } else if (hit.type == intersection_type::triangle) {
                    primaryDistance = hit.distance;
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
                    constexpr sampler envSampler(filter::linear, address::clamp_to_edge);
                    if (mat.materialFlags.x != 0) {
                        if (!is_null_texture(envCube)) {
                            color = envCube.sample(envSampler, rayDir).rgb;
                        } else {
                            color = float3(0.04, 0.07, 0.13) + float3(0.01, 0.03, 0.06) * (1.0 - ndc.y);
                        }
                        // Hybrid RT mode must not replace the authored Q3 sky.
                        // The raster sky pipeline already renders the correct
                        // multi-stage shader/cloud dome. RT's envCube is only
                        // an IBL/reflection source and is often procedural or
                        // stale; compositing it with alpha=1 turns q3dm1/q3dm17
                        // skies black/wrong between Q3.world.additiveFull and
                        // Q3.render.postRT. Preserve the raster sky for primary
                        // camera rays while still letting reflective rays sample
                        // envCube in the reflection/miss paths.
                        outputAlpha = (uniforms.rtAtmosphereParams.x > 0.0)
                            ? saturate(uniforms.rtAtmosphereParams.z)
                            : 0.0;
                    } else if (mat.albedoSlot < 110) {
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
                        // PBR animation atlases (jump pads, teleporters, lamp flares) are stored
                        // as cols×rows sprite sheets. Raster world/entity shaders already remap
                        // to the current frame; pure RT must do the same or it samples the whole
                        // sheet, producing the vertical comb/strip seen in r_rt_mix 1.
                        if (mat.spriteAtlasParams.x > 0.5) {
                            float aCols  = mat.spriteAtlasParams.x;
                            float aRows  = mat.spriteAtlasParams.y;
                            float aFps   = mat.spriteAtlasParams.z;
                            float aTotal = max(1.0, aCols * aRows);
                            float frame  = (aFps > 0.0) ? floor(uniforms.fovParams.z * aFps) : 0.0;
                            float idx    = fmod(frame, aTotal);
                            if (idx < 0.0) { idx += aTotal; }
                            float col = fmod(idx, aCols);
                            float row = floor(idx / aCols);
                            float2 localUV = fract(uv);
                            uv = float2((localUV.x + col) / aCols,
                                        (localUV.y + row) / aRows);
                        }
                        float4 albedoSample = texTable.albedo[mat.albedoSlot].sample(repeatSampler, uv);
                        // Step 2c: RT normal mapping. Gated by r_rt_normal_scale
                        // (rtPBRGlobal.x); 0 = exact no-op. Samples the per-material
                        // normal DDS (parallel to albedo), builds an analytic TBN from
                        // the hit triangle's positions + base UVs, and perturbs N. The
                        // existing NEE sun/light dot(N,L) terms then pick up the bump.
                        if (uniforms.rtPBRGlobal.x > 0.0) {
                            float3 p0n = float3(vertices[i0].position);
                            float3 p1n = float3(vertices[i1].position);
                            float3 p2n = float3(vertices[i2].position);
                            float3 e1 = p1n - p0n;
                            float3 e2 = p2n - p0n;
                            float2 du1 = uv1 - uv0;
                            float2 du2 = uv2 - uv0;
                            float det = du1.x * du2.y - du2.x * du1.y;
                            if (abs(det) > 1.0e-8) {
                                float3 T = (e1 * du2.y - e2 * du1.y) / det;
                                T = T - N * dot(N, T);            // Gram-Schmidt orthonormalize
                                if (dot(T, T) > 1.0e-8) {
                                    T = normalize(T);
                                    float3 Bn = cross(N, T);
                                    float3 nTan = texTable.normal[mat.albedoSlot].sample(repeatSampler, uv).rgb * 2.0 - 1.0;
                                    nTan.xy *= uniforms.rtPBRGlobal.x;
                                    float3 pN = T * nTan.x + Bn * nTan.y + N * nTan.z;
                                    if (dot(pN, pN) > 1.0e-8) { N = normalize(pN); }
                                }
                            }
                        }
                        float blendMode = mat.materialParams.y;
                        bool additiveBlend = (abs(blendMode - 1.0) < 0.5 || abs(blendMode - 5.0) < 0.5);
                        bool alphaSensitive = (mat.materialFlags.z != 0 || mat.materialFlags.w != 0 || additiveBlend);
                        float sampledAlpha = albedoSample.a;
                        // Several RTX/effect DDS captures are effectively RGB-only even though
                        // the original Q3 shader expects luminance alpha. Synthesize alpha in
                        // shader for effect/blended/alpha-test materials so smoke, flares and
                        // sprites do not become opaque white quads.
                        float luminanceAlpha = max(max(albedoSample.r, albedoSample.g), albedoSample.b);
                        float effectiveAlpha = (alphaSensitive && sampledAlpha >= 0.995) ? luminanceAlpha : sampledAlpha;
                        float alphaThreshold = mat.alphaTcModControl.x;
                        bool alphaReject = (alphaThreshold > 0.0 && effectiveAlpha < alphaThreshold) ||
                                           (alphaThreshold < 0.0 && effectiveAlpha >= -alphaThreshold);
                        if (alphaReject) {
                            // Let the already-rasterized world show through. A primitive AS
                            // cannot alpha-discard and continue traversal without custom
                            // intersection/multi-hit logic, so alpha holes preserve raster.
                            color = float3(0.0);
                            outputAlpha = 0.0;
                        } else if (additiveBlend) {
                            // Additive Q3 stages (flares, smoke/energy sprites, portals) are
                            // self-lit effect passes, not lightmapped world. Preserve raster via
                            // alpha instead of turning RGB-only DDS effects into solid squares.
                            float intensity = max(mat.materialParams.x, 1.0);
                            float alphaForAdd = (abs(blendMode - 5.0) < 0.5) ? max(effectiveAlpha, 0.65) : effectiveAlpha;
                            float3 emitSample = albedoSample.rgb;
                            if (mat.emissiveSlot < 110) {
                                emitSample = texTable.albedo[mat.emissiveSlot].sample(repeatSampler, uv).rgb;
                            }
                            color = emitSample * intensity * alphaForAdd;
                            outputAlpha = clamp(alphaForAdd, 0.0, 0.85);
                        } else if (mat.materialFlags.w != 0) {
                            // First-pass translucency: shade blended surfaces but emit partial
                            // alpha so the composite pass preserves raster behind/through them.
                            float3 lightmap = float3(1.0);
                            if (mat.lightmapSlot < 16) {
                                lightmap = texTable.lightmap[mat.lightmapSlot].sample(clampSampler, lmuv).rgb;
                            }
                            float ambientFloor = uniforms.rtToneParams.z;
                            // RT lighting rebalance: rtPBRGlobal.z dims the baked
                            // lightmap (toward RT-direct/RTX look); ambient floor preserved.
                            color = albedoSample.rgb * max(lightmap * 1.25 * uniforms.rtPBRGlobal.z, float3(ambientFloor));
                            if (mat.materialFlags.y != 0) {
                                float3 emitSample = albedoSample.rgb;
                                if (mat.emissiveSlot < 110) {
                                    emitSample = texTable.albedo[mat.emissiveSlot].sample(repeatSampler, uv).rgb;
                                }
                                color += emitSample * mat.materialParams.x * effectiveAlpha;
                                color = min(color, float3(2.0));
                            }
                            outputAlpha = clamp(effectiveAlpha, 0.0, 0.70);
                        } else {
                            float3 lightmap = float3(1.0);
                            if (mat.lightmapSlot < 16) {
                                lightmap = texTable.lightmap[mat.lightmapSlot].sample(clampSampler, lmuv).rgb;
                            }
                            float ambientFloor = uniforms.rtToneParams.z;
                            // RT lighting rebalance: rtPBRGlobal.z dims the baked
                            // lightmap (toward RT-direct/RTX look); ambient floor preserved.
                            color = albedoSample.rgb * max(lightmap * 1.25 * uniforms.rtPBRGlobal.z, float3(ambientFloor));
                            if (mat.materialFlags.y != 0) {
                                float3 emitSample = albedoSample.rgb;
                                if (mat.emissiveSlot < 110) {
                                    emitSample = texTable.albedo[mat.emissiveSlot].sample(repeatSampler, uv).rgb;
                                }
                                color += emitSample * mat.materialParams.x;
                                color = min(color, float3(2.0));
                            }
                            // First-pass one-bounce indirect: gated by r_rt_bounces.
                            if (uniforms.rtControlParams.y > 0.5) {
                                float rnd0 = rtHash12(float2(tid) + uniforms.fovParams.zz * float2(17.0, 31.0));
                                float rnd1 = rtHash12(float2(tid.yx) + uniforms.fovParams.zz * float2(47.0, 11.0));
                                float3 bounceDir = rtCosineHemisphere(N, float2(rnd0, rnd1));
                                ray bounceRay(hitPos + N * 0.75, bounceDir, 0.1, 2048.0);
                                auto bounceHit = i.intersect(bounceRay, worldAS);
                                float3 indirect = float3(0.0);
                                if (bounceHit.type == intersection_type::triangle) {
                                    uint btri = bounceHit.primitive_id;
                                    RTPrimitiveMaterial bounceMat = primitiveMaterials[btri];
                                    if (bounceMat.materialFlags.y != 0 && bounceMat.albedoSlot < 110) {
                                        uint bi0 = indices[btri * 3 + 0];
                                        uint bi1 = indices[btri * 3 + 1];
                                        uint bi2 = indices[btri * 3 + 2];
                                        float2 bb = bounceHit.triangle_barycentric_coord;
                                        float bw = 1.0 - bb.x - bb.y;
                                        float2 buv = vertices[bi0].texCoord * bw + vertices[bi1].texCoord * bb.x + vertices[bi2].texCoord * bb.y;
                                        float3 emitAlbedo = texTable.albedo[bounceMat.albedoSlot].sample(repeatSampler, buv).rgb;
                                        indirect = emitAlbedo * max(bounceMat.materialParams.x, 0.8) * 0.22;
                                    } else {
                                        indirect = float3(0.035);
                                    }
                                } else if (!is_null_texture(envCube)) {
                                    indirect = envCube.sample(envSampler, bounceDir).rgb * 0.06;
                                } else {
                                    indirect = float3(0.01, 0.015, 0.025);
                                }
                                color += albedoSample.rgb * indirect;
                            }
                            /* P1 — NEE direct lighting from the RTX Remix
                             * authored per-map light set, with a real shadow
                             * ray per sample. Two samples max per pixel:
                             * the sun (lights[0] when type==0, always), plus
                             * one stochastically picked local light. */
                            uint lightCount = (uint)uniforms.rtLightParams.x;
                            if (lightCount > 0) {
                                float lightScale = uniforms.rtLightParams.y;
                                float3 direct = float3(0.0);
                                uint firstLocal = 0;
                                // Sun: always sampled when present (loader
                                // sorts distant lights to slot 0).
                                if (rtLights[0].dirType.w < 0.5) {
                                    firstLocal = 1;
                                    atomic_fetch_add_explicit(&rtShadowCounters[3], 1u, memory_order_relaxed);
                                    float3 L = -normalize(rtLights[0].dirType.xyz);
                                    float ndl = max(dot(N, L), 0.0);
                                    if (ndl > 0.0) {
                                        atomic_fetch_add_explicit(&rtShadowCounters[0], 1u, memory_order_relaxed);
                                        ray sray(hitPos + N * 0.75, L, 0.1, 20000.0);
                                        auto sh = i.intersect(sray, worldAS);
                                        bool shadowBlocked = sh.type == intersection_type::triangle &&
                                                             primitiveMaterials[sh.primitive_id].materialFlags.x == 0;
                                        if (!shadowBlocked) {
                                            atomic_fetch_add_explicit(&rtShadowCounters[2], 1u, memory_order_relaxed);
                                            direct += rtLights[0].colorIntensity.rgb *
                                                      (rtLights[0].colorIntensity.w * 0.3 * lightScale) * ndl;
                                        } else {
                                            atomic_fetch_add_explicit(&rtShadowCounters[1], 1u, memory_order_relaxed);
                                        }
                                    }
                                }
                                /* Deterministic top-2 light selection: scan
                                 * the whole list with cheap ALU scoring, cast
                                 * shadow rays ONLY for the two strongest
                                 * contributors. No stochastic pick → no pdf
                                 * multiply → no firefly noise (the v1 sampler
                                 * picked 1 of N and multiplied by N, which
                                 * sparkled at N≈90). ~100 lights × ~15 flops
                                 * is far cheaper than one shadow ray. */
                                uint bestIdx0 = 0xFFFFFFFFu, bestIdx1 = 0xFFFFFFFFu;
                                float bestS0 = 0.0, bestS1 = 0.0;
                                for (uint li = firstLocal; li < lightCount; ++li) {
                                    float3 toL = rtLights[li].posRadius.xyz - hitPos;
                                    float d2 = max(dot(toL, toL), 1.0);
                                    float ndl = max(dot(N, toL * rsqrt(d2)), 0.0);
                                    float r = rtLights[li].posRadius.w;
                                    float s = rtLights[li].colorIntensity.w * ndl /
                                              (d2 + r * r + 1.0);
                                    if (s > bestS0) {
                                        bestS1 = bestS0; bestIdx1 = bestIdx0;
                                        bestS0 = s; bestIdx0 = li;
                                    } else if (s > bestS1) {
                                        bestS1 = s; bestIdx1 = li;
                                    }
                                }
                                for (uint k = 0; k < 2; ++k) {
                                    uint li = (k == 0) ? bestIdx0 : bestIdx1;
                                    if (li == 0xFFFFFFFFu) { continue; }
                                    RTLight Lgt = rtLights[li];
                                    float3 toL = Lgt.posRadius.xyz - hitPos;
                                    float d2 = max(dot(toL, toL), 1.0);
                                    float dist = sqrt(d2);
                                    float3 L = toL / dist;
                                    float ndl = max(dot(N, L), 0.0);
                                    float r = Lgt.posRadius.w;
                                    float E = Lgt.colorIntensity.w * 60.0 * lightScale /
                                              (d2 + r * r + 1.0);
                                    if (ndl > 0.0 && E * ndl > 0.004) {
                                        ray sray(hitPos + N * 0.75, L, 0.1, max(dist - r - 1.0, 0.2));
                                        auto sh = i.intersect(sray, worldAS);
                                        bool shadowBlocked = sh.type == intersection_type::triangle &&
                                                             primitiveMaterials[sh.primitive_id].materialFlags.x == 0;
                                        if (!shadowBlocked) {
                                            direct += Lgt.colorIntensity.rgb * min(E * ndl, 3.0);
                                        }
                                    }
                                }
                                // RT lighting rebalance: rtPBRGlobal.w boosts the
                                // ray-traced direct (sun + local NEE, shadowed) term.
                                color += albedoSample.rgb * direct * uniforms.rtPBRGlobal.w;
                            }
                            /* P3 — one-level specular reflection. Gated on
                             * material roughness/metallic from the PBR table
                             * (materialParams.z = roughness, .w = metallic). */
                            if (uniforms.rtLightParams.z > 0.5) {
                                float rough = mat.materialParams.z;
                                float metal = mat.materialParams.w;
                                if (metal > 0.5 || rough < uniforms.rtLightParams.w) {
                                    float3 V = -rayDir;
                                    float3 R = reflect(rayDir, N);
                                    // Roughness jitter (TAA integrates).
                                    float rj0 = rtHash12(float2(tid) + uniforms.fovParams.zz * float2(3.0, 29.0));
                                    float rj1 = rtHash12(float2(tid.yx) + uniforms.fovParams.zz * float2(19.0, 5.0));
                                    float3 jdir = rtCosineHemisphere(R, float2(rj0, rj1));
                                    R = normalize(mix(R, jdir, rough * rough));
                                    ray rray(hitPos + N * 0.75, R, 0.1, 20000.0);
                                    auto rh = i.intersect(rray, worldAS);
                                    float3 reflColor;
                                    if (rh.type == intersection_type::triangle) {
                                        uint rtri = rh.primitive_id;
                                        RTPrimitiveMaterial rmat = primitiveMaterials[rtri];
                                        float3 reflHitOrigin = hitPos + N * 0.75;
                                        float3 reflHitPos = reflHitOrigin + R * rh.distance;
                                        if (rmat.albedoSlot < 110) {
                                            uint ri0 = indices[rtri * 3 + 0];
                                            uint ri1 = indices[rtri * 3 + 1];
                                            uint ri2 = indices[rtri * 3 + 2];
                                            float2 rb = rh.triangle_barycentric_coord;
                                            float rw = 1.0 - rb.x - rb.y;
                                            float2 ruv = vertices[ri0].texCoord * rw +
                                                         vertices[ri1].texCoord * rb.x +
                                                         vertices[ri2].texCoord * rb.y;
                                            float2 rlm = vertices[ri0].lightmapTexCoord * rw +
                                                         vertices[ri1].lightmapTexCoord * rb.x +
                                                         vertices[ri2].lightmapTexCoord * rb.y;
                                            uint rtcCount = min(rmat.tcModCount, 4u);
                                            for (uint mi = 0; mi < rtcCount; ++mi) {
                                                uint rtype = rmat.tcModTypes[mi];
                                                if (rtype == 0) { continue; }
                                                float4 rparams = rmat.tcModParams0;
                                                if (mi == 1) { rparams = rmat.tcModParams1; }
                                                else if (mi == 2) { rparams = rmat.tcModParams2; }
                                                else if (mi == 3) { rparams = rmat.tcModParams3; }
                                                ruv = rtApplyTcMod(ruv, reflHitPos, int(rtype), rparams, uniforms.fovParams.z);
                                                rlm = rtApplyTcMod(rlm, reflHitPos, int(rtype), rparams, uniforms.fovParams.z);
                                            }
                                            if (rmat.spriteAtlasParams.x > 0.5) {
                                                float rCols = rmat.spriteAtlasParams.x;
                                                float rRows = rmat.spriteAtlasParams.y;
                                                float rFps = rmat.spriteAtlasParams.z;
                                                float rTotal = max(1.0, rCols * rRows);
                                                float rFrame = (rFps > 0.0) ? floor(uniforms.fovParams.z * rFps) : 0.0;
                                                float rIdx = fmod(rFrame, rTotal);
                                                if (rIdx < 0.0) { rIdx += rTotal; }
                                                float rCol = fmod(rIdx, rCols);
                                                float rRow = floor(rIdx / rCols);
                                                float2 rLocalUV = fract(ruv);
                                                ruv = float2((rLocalUV.x + rCol) / rCols,
                                                             (rLocalUV.y + rRow) / rRows);
                                            }
                                            float3 ralb = texTable.albedo[rmat.albedoSlot].sample(repeatSampler, ruv).rgb;
                                            float3 rlight = float3(1.0);
                                            if (rmat.lightmapSlot < 16) {
                                                rlight = texTable.lightmap[rmat.lightmapSlot].sample(clampSampler, rlm).rgb;
                                            }
                                            reflColor = ralb * max(rlight * 1.25, float3(uniforms.rtToneParams.z));
                                            if (rmat.materialFlags.y != 0) {
                                                float3 remitSample = ralb;
                                                if (rmat.emissiveSlot < 110) {
                                                    remitSample = texTable.albedo[rmat.emissiveSlot].sample(repeatSampler, ruv).rgb;
                                                }
                                                reflColor += remitSample * rmat.materialParams.x;
                                            }
                                        } else if (!is_null_texture(envCube)) {
                                            reflColor = envCube.sample(envSampler, R).rgb;
                                        } else {
                                            reflColor = float3(0.03);
                                        }
                                    } else if (!is_null_texture(envCube)) {
                                        reflColor = envCube.sample(envSampler, R).rgb;
                                    } else {
                                        reflColor = float3(0.03);
                                    }
                                    // Fresnel-Schlick; F0 0.04 dielectric → albedo for metal.
                                    float ndv = max(dot(N, V), 0.0);
                                    float3 F0 = mix(float3(0.04), albedoSample.rgb, metal);
                                    float3 F = F0 + (1.0 - F0) * pow(1.0 - ndv, 5.0);
                                    float gloss = 1.0 - rough;
                                    color = mix(color, reflColor, saturate(F * gloss));
                                }
                            }
                            color = mix(color, normalColor, uniforms.rtToneParams.w);
                        }
                    } else {
                        // Missing RT material slot: keep raster instead of painting debug
                        // normals over unmapped maps/surfaces.
                        color = normalColor;
                        outputAlpha = 0.0;
                    }
                } else {
                    constexpr sampler envSampler(filter::linear, address::clamp_to_edge);
                    if (!is_null_texture(envCube)) {
                        color = envCube.sample(envSampler, rayDir).rgb;
                    } else {
                        color = float3(0.04, 0.07, 0.13) + float3(0.01, 0.03, 0.06) * (1.0 - ndc.y);
                    }
                    // Hybrid RT safety: if the world AS misses geometry that
                    // raster drew (current symptom: "half the geometry"
                    // disappears only when r_rt_mix > 0), do not let an RT
                    // miss overwrite the already-correct raster pixel. Real
                    // sky BSP surfaces still hit sky materials above and keep
                    // alpha=1, so this only preserves raster on true AS misses.
                    outputAlpha = (uniforms.rtAtmosphereParams.x > 0.0)
                        ? saturate(uniforms.rtAtmosphereParams.z)
                        : 0.0;
                }
                if (uniforms.rtAtmosphereParams.x > 0.0) {
                    float density = max(uniforms.rtAtmosphereParams.x, 0.0);
                    float fogMax = saturate(uniforms.rtAtmosphereParams.w);
                    float grey = saturate(uniforms.rtAtmosphereParams.y);
                    float3 fogColor = float3(grey);
                    float fogAmount = saturate((1.0 - exp(-primaryDistance * density)) * fogMax);
                    color = mix(color, fogColor, fogAmount);
                }
                if (any(isnan(color)) || any(isinf(color))) { color = float3(0.0); }
                // P2 HDR: do not clamp here when the RT target is rgba16F.
                // blendRT extracts bloom from >1.0 values, then tonemaps to
                // the LDR drawable/composite. Legacy rgba8 mode still clamps
                // at the texture format boundary.
                color = max(color * uniforms.rtToneParams.x, float3(0.0));
                color = pow(color, float3(max(uniforms.rtToneParams.y, 0.001)));
                output.write(float4(color, saturate(outputAlpha)), tid);
            }

            kernel void accumulateRT(texture2d<float, access::read> current [[texture(0)]],
                                     texture2d<float, access::read> history [[texture(1)]],
                                     texture2d<float, access::write> output [[texture(2)]],
                                     constant float &alpha [[buffer(0)]],
                                     uint2 tid [[thread_position_in_grid]]) {
                if (tid.x >= output.get_width() || tid.y >= output.get_height()) return;
                float4 c = current.read(tid);
                float4 h = history.read(tid);
                float a = saturate(alpha);
                float3 rgb = mix(h.rgb, c.rgb, a);
                output.write(float4(rgb, c.a), tid);
            }

            kernel void blendRT(texture2d<float, access::sample> rt [[texture(0)]],
                                texture2d<float, access::read> raster [[texture(1)]],
                                texture2d<float, access::write> output [[texture(2)]],
                                constant float4 &blendParams [[buffer(0)]],
                                uint2 tid [[thread_position_in_grid]]) {
                if (tid.x >= output.get_width() || tid.y >= output.get_height()) return;
                float m = saturate(blendParams.x);
                float2 uv = (float2(tid) + 0.5) / float2(output.get_width(), output.get_height());
                constexpr sampler rtUpscaleSampler(filter::linear, address::clamp_to_edge);
                float4 rtSample = rt.sample(rtUpscaleSampler, uv);
                float3 rtColor = max(rtSample.rgb, float3(0.0));
                float bloomIntensity = max(blendParams.y, 0.0);
                if (bloomIntensity > 0.001) {
                    float threshold = max(blendParams.z, 0.0);
                    float radius = max(blendParams.w, 0.5);
                    float2 texel = radius / float2(float(max(rt.get_width(), 1u)),
                                                   float(max(rt.get_height(), 1u)));
                    float3 bloom = max(rtColor - float3(threshold), float3(0.0)) * 0.20;
                    bloom += max(rt.sample(rtUpscaleSampler, uv + texel * float2( 1.0,  0.0)).rgb - float3(threshold), float3(0.0)) * 0.12;
                    bloom += max(rt.sample(rtUpscaleSampler, uv + texel * float2(-1.0,  0.0)).rgb - float3(threshold), float3(0.0)) * 0.12;
                    bloom += max(rt.sample(rtUpscaleSampler, uv + texel * float2( 0.0,  1.0)).rgb - float3(threshold), float3(0.0)) * 0.12;
                    bloom += max(rt.sample(rtUpscaleSampler, uv + texel * float2( 0.0, -1.0)).rgb - float3(threshold), float3(0.0)) * 0.12;
                    bloom += max(rt.sample(rtUpscaleSampler, uv + texel * float2( 1.5,  1.5)).rgb - float3(threshold), float3(0.0)) * 0.08;
                    bloom += max(rt.sample(rtUpscaleSampler, uv + texel * float2(-1.5,  1.5)).rgb - float3(threshold), float3(0.0)) * 0.08;
                    bloom += max(rt.sample(rtUpscaleSampler, uv + texel * float2( 1.5, -1.5)).rgb - float3(threshold), float3(0.0)) * 0.08;
                    bloom += max(rt.sample(rtUpscaleSampler, uv + texel * float2(-1.5, -1.5)).rgb - float3(threshold), float3(0.0)) * 0.08;
                    rtColor += bloom * bloomIntensity;
                    // ACES-fit tonemap keeps sub-1 values stable while
                    // rolling HDR lights/emissives into visible glow.
                    rtColor = saturate((rtColor * (2.51 * rtColor + 0.03)) /
                                       (rtColor * (2.43 * rtColor + 0.59) + 0.14));
                } else {
                    rtColor = saturate(rtColor);
                }
                float3 rasterColor = saturate(raster.read(tid).rgb);
                // RT alpha is a per-pixel preserve-raster mask used for alpha-test
                // holes, blended world surfaces, and unmapped RT materials.
                float effectiveMix = m * saturate(rtSample.a);
                float3 blended = mix(rasterColor, rtColor, effectiveMix);
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
            do {
                let pso = try device.makeComputePipelineState(function: fn); rtPipelineState = pso
                // Step 2a: build the argument encoder for the RTTexTable at buffer(8).
                rtTexArgEncoder = fn.makeArgumentEncoder(bufferIndex: 8)
                print("[RT] rtKernel pipeline ready (texArgEncoder len=\(rtTexArgEncoder?.encodedLength ?? 0))")
                return pso
            }
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
        private func ensureRTAccumPipeline(device: MTLDevice) -> MTLComputePipelineState? {
            if let rtAccumPipelineState { return rtAccumPipelineState }
            guard let lib = makeRTLibrary(device: device), let fn = lib.makeFunction(name: "accumulateRT") else {
                print("[RT] failed to create accumulateRT"); return nil
            }
            do { let pso = try device.makeComputePipelineState(function: fn); rtAccumPipelineState = pso; print("[RT] accumulateRT pipeline ready"); return pso }
            catch { print("[RT] accumulate pipeline state error: \(error)"); return nil }
        }

        @MainActor
        private func buildRTPrimitiveMaterials(device: MTLDevice, primitiveCount: Int, log: Bool = true) {
            let invalid = UInt32.max
            let invalidMaterial = RTPrimitiveMaterial(
                albedoSlot: invalid,
                lightmapSlot: invalid,
                tcModCount: 0,
                _pad0: invalid,
                alphaTcModControl: SIMD4<Float>(0, 0, 0, 0),
                materialFlags: SIMD4<UInt32>(0, 0, 0, 0),
                materialParams: SIMD4<Float>(0, 0, 0, 0),
                tcModTypes: SIMD4<UInt32>(0, 0, 0, 0),
                tcModParams0: SIMD4<Float>(0, 0, 0, 0),
                tcModParams1: SIMD4<Float>(0, 0, 0, 0),
                tcModParams2: SIMD4<Float>(0, 0, 0, 0),
                tcModParams3: SIMD4<Float>(0, 0, 0, 0),
                spriteAtlasParams: SIMD4<Float>(0, 0, 0, 0))
            rtAlbedoHandles = [UInt32](repeating: 0, count: rtMaxAlbedoSlots)
            rtAlbedoSlotKinds = [UInt32](repeating: 0, count: rtMaxAlbedoSlots)
            rtLightmapHandles = [UInt32](repeating: 0, count: rtMaxLightmapSlots)

            // 2026-06-10: prealloc strategy A — eliminate the 3.9 MB Swift
            // `[RTPrimitiveMaterial]` intermediate that the old code allocated
            // every 30 Hz refresh, plus the matching makeBuffer(bytes:)
            // memcpy from it. Now we allocate the MTLBuffer directly and
            // write RTPrimitiveMaterial structs into its `.contents()` via
            // typed pointer. Old code path was: heap-alloc 3.9 MB Swift
            // array → fill it → makeBuffer(bytes:) copies the 3.9 MB into
            // Metal-owned memory → release Swift array. Per refresh that's
            // 2 allocs + 2 memcpys totaling ~7.8 MB; at 30 Hz that's
            // ~234 MB/s of CPU bandwidth burned on what should be a single
            // in-place buffer fill. Strategy A still allocates a fresh
            // MTLBuffer per refresh (safe — Metal refcounts the old buffer
            // until any in-flight GPU read finishes), but eliminates the
            // Swift-array intermediate. If perf data later shows the per-
            // refresh MTLBuffer alloc itself is the cost, escalate to
            // strategy B: triple-buffer rotation + frame-fence sync.
            let bufferLength = primitiveCount * MemoryLayout<RTPrimitiveMaterial>.stride
            guard let buffer = device.makeBuffer(length: max(1, bufferLength),
                                                  options: .storageModeShared) else {
                rtPrimitiveMaterialBuffer = nil
                return
            }
            buffer.label = "Q3.RT.primitiveMaterials"
            let materials = buffer.contents().bindMemory(to: RTPrimitiveMaterial.self,
                                                          capacity: primitiveCount)
            // Initialize all primitives to invalid.
            for i in 0..<primitiveCount {
                materials[i] = invalidMaterial
            }
            rtPrimitiveMaterialBuffer = buffer

            guard let drawsPtr = Q3MetalRenderer_GetWorldAllDrawCommands() else {
                // Buffer already populated with invalid; no further work.
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
            var emissiveWeights: [UInt32: Int] = [:]
            let fogOnlyBit = UInt32(Q3_METAL_WORLD_DRAWFLAG_FOG_ONLY)

            for draw in draws where draw.indexCount >= 3 {
                if (draw.flags & fogOnlyBit) != 0 { continue }
                guard let stage = Self.rtRepresentativeStage(for: draw) else { continue }
                let triCount = max(1, Int(draw.indexCount / 3))
                let materialHandle = Self.worldPBRMaterialHandle(for: stage)
                if stage.useLightmap == 0 && stage.textureHandle != 0 {
                    albedoWeights[materialHandle, default: 0] += triCount
                    if let mat = pbrMaterialInfo(for: materialHandle),
                       mat.emissive != nil,
                       mat.emissiveIntensity > 0.0 {
                        emissiveWeights[materialHandle, default: 0] += triCount
                    }
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

            let emissiveReserve = min(rtReservedEmissiveSlots, rtMaxAlbedoSlots / 3)
            let topAlbedos = topHandles(albedoWeights, limit: max(1, rtMaxAlbedoSlots - emissiveReserve))
            let topEmissives = topHandles(emissiveWeights, limit: emissiveReserve)
            let topLightmaps = topHandles(lightmapWeights, limit: rtMaxLightmapSlots)
            for (i, h) in topAlbedos.enumerated() {
                rtAlbedoHandles[i] = h
                rtAlbedoSlotKinds[i] = 0
                _ = texture(for: h, device: device)
            }
            let emissiveSlotBase = topAlbedos.count
            for (i, h) in topEmissives.enumerated() where emissiveSlotBase + i < rtMaxAlbedoSlots {
                rtAlbedoHandles[emissiveSlotBase + i] = h
                rtAlbedoSlotKinds[emissiveSlotBase + i] = 1
                _ = pbrEmissiveTexture(for: h)
            }
            for (i, h) in topLightmaps.enumerated() {
                rtLightmapHandles[i] = h
                _ = texture(for: h, device: device)
            }
            let albedoSlots = Dictionary(uniqueKeysWithValues: topAlbedos.enumerated().map { (UInt32($0.offset), $0.element) }.map { ($0.1, $0.0) })
            let emissiveSlots = Dictionary(uniqueKeysWithValues: topEmissives.enumerated().compactMap { pair -> (UInt32, UInt32)? in
                let slot = emissiveSlotBase + pair.offset
                guard slot < rtMaxAlbedoSlots else { return nil }
                return (pair.element, UInt32(slot))
            })
            let lightmapSlots = Dictionary(uniqueKeysWithValues: topLightmaps.enumerated().map { (UInt32($0.offset), $0.element) }.map { ($0.1, $0.0) })

            var assigned = 0
            var skippedOverwrite = 0
            for draw in draws where draw.indexCount >= 3 {
                if (draw.flags & fogOnlyBit) != 0 { continue }
                guard let stage = Self.rtRepresentativeStage(for: draw) else { continue }
                let skyFlagBit = UInt32(Q3_METAL_WORLD_DRAWFLAG_SKY)
                let isSkyDraw = (draw.flags & skyFlagBit) != 0
                let materialHandle = Self.worldPBRMaterialHandle(for: stage)
                let aSlotOptional = albedoSlots[materialHandle]
                let lSlotOptional = lightmapSlots[draw.lightmapTextureHandle]
                guard stage.useLightmap == 0 else { continue }
                // Task 1 RT fallback: an opaque world primitive only needs its
                // original/base Q3 texture slot. If its lightmap did not make the
                // small 16-slot RT lightmap table, keep the material valid and let
                // the kernel shade it with the ambient floor instead of dropping to
                // transparent/debug fallback.
                if !isSkyDraw && aSlotOptional == nil { continue }
                let aSlot = aSlotOptional ?? 0
                let lSlot = lSlotOptional ?? invalid
                let blendMode = Self.worldBlendClass(for: stage)
                let isEmissive = (blendMode == 1 || blendMode == 5)
                let emissiveSlot = emissiveSlots[materialHandle] ?? invalid
                // P3: per-material roughness/metallic for the kernel's
                // reflection gate. PBR constants when authored; otherwise a
                // matte dielectric default so reflections stay off.
                var rtRough: Float = 0.85
                var rtMetal: Float = 0.0
                // Increment 1 (HDR emissive): feed AUTHORED emissive intensity
                // into the RT HDR color when r_rt_emissive > 0. Legacy default
                // (cvar 0) keeps the additive-stage albedo*0.8 fake. The kernel
                // already does `color += albedoSample.rgb * materialParams.x` on
                // materialFlags.y surfaces, so the existing ACES tonemap + bloom
                // glow these once the intensity crosses the bloom threshold.
                let rtEmissiveScale = Q3_RTEmissive()
                var rtEmissiveActive = isEmissive
                var rtEmissiveIntensity: Float = isEmissive ? 0.8 : 0.0
                // logEnabled: false — this 30 Hz RT prepass runs before any
                // draw and was poisoning the one-shot world-atlas log with
                // atlasTime=0.000 entries (dedup set is shared).
                let rtAtlasParams = pbrSpriteAtlasParams(for: materialHandle, atlasTime: 0, logEnabled: false)
                if let matPtr = Q3MetalRenderer_GetPBRMaterial(materialHandle) {
                    let m = matPtr.pointee
                    if m.roughness_constant >= 0 { rtRough = m.roughness_constant }
                    if m.metallic_constant >= 0 { rtMetal = m.metallic_constant }
                    if rtEmissiveScale > 0 {
                        let authored = m.emissive_intensity
                        if authored > 0 || m.emissive != nil {
                            rtEmissiveActive = true
                            // /16 clamp tames RTX's huge HDR values (up to 982);
                            // the master scale + r_rt_exposure/r_rt_bloom tune the
                            // final on-screen brightness through the ACES tonemap.
                            rtEmissiveIntensity = min(max(authored, 1.0), 16.0) * rtEmissiveScale
                        }
                    }
                }
                let firstTri = Int(draw.firstIndex / 3)
                let triCount = Int(draw.indexCount / 3)
                guard firstTri < primitiveCount else { continue }
                let end = min(firstTri + triCount, primitiveCount)
                let chain = worldTcModChain(for: stage)
                let tcCount = UInt32(max(0, min(Int(chain.count), 4)))
                let tcTypes = SIMD4<UInt32>(
                    tcCount > 0 ? UInt32(max(0, Int(stage.tcMods.0.type))) : 0,
                    tcCount > 1 ? UInt32(max(0, Int(stage.tcMods.1.type))) : 0,
                    tcCount > 2 ? UInt32(max(0, Int(stage.tcMods.2.type))) : 0,
                    tcCount > 3 ? UInt32(max(0, Int(stage.tcMods.3.type))) : 0)
                let alphaThreshold = Self.alphaTestThreshold(for: stage.alphaFunc)
                for tri in firstTri..<end {
                    if materials[tri].albedoSlot == invalid {
                        materials[tri] = RTPrimitiveMaterial(
                            albedoSlot: aSlot,
                            lightmapSlot: lSlot,
                            tcModCount: tcCount,
                            _pad0: emissiveSlot,
                            alphaTcModControl: SIMD4<Float>(alphaThreshold, Float(tcCount), 0, 0),
                            // flags: x=sky, y=emissive, z=alpha-test, w=blended/translucent.
                            // RT shades blended/translucent world surfaces with partial alpha
                            // so grates/flames/portals preserve raster behind them.
                            materialFlags: SIMD4<UInt32>(isSkyDraw ? 1 : 0,
                                                         rtEmissiveActive ? 1 : 0,
                                                         alphaThreshold != 0 ? 1 : 0,
                                                         blendMode != 0 ? 1 : 0),
                            // .z = roughness, .w = metallic (P3 reflections).
                            materialParams: SIMD4<Float>(rtEmissiveIntensity, Float(blendMode), rtRough, rtMetal),
                            tcModTypes: tcTypes,
                            tcModParams0: chain.p0,
                            tcModParams1: chain.p1,
                            tcModParams2: chain.p2,
                            tcModParams3: chain.p3,
                            spriteAtlasParams: rtAtlasParams)
                        assigned += 1
                    } else {
                        skippedOverwrite += 1
                    }
                }
            }
            // Buffer is already populated; no final makeBuffer(bytes:) copy
            // needed (that was strategy A's primary win).
            if log {
                var lightmapFallbacks = 0
                for i in 0..<primitiveCount {
                    let m = materials[i]
                    if m.albedoSlot != invalid && m.lightmapSlot == invalid && m.materialFlags.x == 0 {
                        lightmapFallbacks += 1
                    }
                }
                print("[RT] material table: albedo=\(topAlbedos.count)/\(albedoWeights.count) lightmap=\(topLightmaps.count)/\(lightmapWeights.count) assigned=\(assigned)/\(primitiveCount) originalNoLightmap=\(lightmapFallbacks) skippedOverwrite=\(skippedOverwrite)")
            }
        }

        @MainActor
        private func rtWorldMaterialSignature() -> UInt64 {
            guard let drawsPtr = Q3MetalRenderer_GetWorldAllDrawCommands() else { return 0 }
            let drawCount = Int(Q3MetalRenderer_GetWorldAllDrawCommandCount())
            guard drawCount > 0 else { return 0 }
            let draws = UnsafeBufferPointer(start: drawsPtr, count: drawCount)
            var h: UInt64 = 0xcbf29ce484222325
            func mix(_ v: UInt64) {
                h ^= v
                h = h &* 0x100000001b3
            }
            func mixFloat(_ v: Float) {
                mix(Self.floatBits(v))
            }
            func mixVec4(_ v: SIMD4<Float>) {
                mixFloat(v.x); mixFloat(v.y); mixFloat(v.z); mixFloat(v.w)
            }
            func mixScaled(_ v: Float, scale: Float = 1000.0, clamp: Int = 1_000_000) {
                mix(UInt64(max(0, min(clamp, Int((v * scale).rounded())))))
            }
            mixScaled(Q3_PBREmissiveIntensityMax(), clamp: 16_000)
            mixScaled(Q3_RTEmissive(), clamp: 16_000)
            mix(UInt64(Q3_PBRBakedLightmaps() != 0 ? 1 : 0))
            let fogOnlyBit = UInt32(Q3_METAL_WORLD_DRAWFLAG_FOG_ONLY)
            let skyFlagBit = UInt32(Q3_METAL_WORLD_DRAWFLAG_SKY)
            for draw in draws where draw.indexCount >= 3 {
                if (draw.flags & fogOnlyBit) != 0 { continue }
                guard let stage = Self.rtRepresentativeStage(for: draw) else { continue }
                let materialHandle = Self.worldPBRMaterialHandle(for: stage)
                let blendMode = Self.worldBlendClass(for: stage)
                let alphaThreshold = Self.alphaTestThreshold(for: stage.alphaFunc)
                let tcMods = [stage.tcMods.0, stage.tcMods.1, stage.tcMods.2, stage.tcMods.3]

                mix(UInt64(draw.firstIndex))
                mix(UInt64(draw.indexCount) << 1)
                mix(UInt64(draw.lightmapTextureHandle) << 2)
                mix(UInt64(draw.flags) << 3)
                mix(UInt64((draw.flags & skyFlagBit) != 0 ? 1 : 0) << 4)
                mix(UInt64(stage.textureHandle) << 5)
                mix(UInt64(materialHandle) << 6)
                mix(UInt64(stage.pbrMaterialHandle) << 7)
                mix(UInt64(stage.useLightmap) << 8)
                mix(UInt64(stage.srcBlend) << 9)
                mix(UInt64(stage.dstBlend) << 10)
                mix(UInt64(max(0, blendMode)) << 11)
                mix(UInt64(stage.tcGen) << 12)
                mix(UInt64(stage.alphaFunc) << 13)
                mix(UInt64(stage.tcModCount) << 14)
                mixFloat(alphaThreshold)
                for mod in tcMods {
                    mix(UInt64(mod.type))
                    mixVec4(SIMD4<Float>(mod.params.0, mod.params.1, mod.params.2, mod.params.3))
                }
            }
            return h
        }

        @MainActor
        private func encodeEntityAccelerationStructureBuild(device: MTLDevice,
                                                            commandBuffer: MTLCommandBuffer,
                                                            slot: Int) -> MTLAccelerationStructure? {
            guard Q3_RTEntities() != 0 else {
                entityAccelerationStructure = nil
                entityASSize = 0
                return nil
            }
            let clampedSlot = max(0, min(slot, Self.maxInflightFrames - 1))
            guard device.supportsRaytracing,
                  let snapshot = Q3MetalRenderer_GetFrameSnapshot()?.pointee,
                  let vb = entityVertexBuffers[clampedSlot],
                  let ib = entityIndexBuffers[clampedSlot] else {
                entityAccelerationStructure = nil
                entityASSize = 0
                return nil
            }
            let vertexCount = Int(snapshot.entityVertexCount)
            let indexCount = Int(snapshot.entityIndexCount)
            guard vertexCount > 0, indexCount >= 3 else {
                entityAccelerationStructure = nil
                entityASSize = 0
                return nil
            }

            let geomDesc = MTLAccelerationStructureTriangleGeometryDescriptor()
            geomDesc.vertexBuffer = vb
            geomDesc.vertexBufferOffset = 0
            geomDesc.vertexStride = MemoryLayout<GPUEntityVertex>.stride
            geomDesc.vertexFormat = .float3
            geomDesc.indexBuffer = ib
            geomDesc.indexBufferOffset = 0
            geomDesc.indexType = .uint32
            geomDesc.triangleCount = indexCount / 3
            geomDesc.opaque = true

            let asDesc = MTLPrimitiveAccelerationStructureDescriptor()
            asDesc.geometryDescriptors = [geomDesc]
            let sizes = device.accelerationStructureSizes(descriptor: asDesc)
            if entityAccelerationStructure == nil || entityASSize < sizes.accelerationStructureSize {
                entityAccelerationStructure = device.makeAccelerationStructure(size: sizes.accelerationStructureSize)
                entityAccelerationStructure?.label = "Q3.RT.entityAS"
                entityASSize = sizes.accelerationStructureSize
            }
            guard let accel = entityAccelerationStructure,
                  let scratch = device.makeBuffer(length: sizes.buildScratchBufferSize, options: .storageModePrivate),
                  let enc = commandBuffer.makeAccelerationStructureCommandEncoder() else {
                return nil
            }
            scratch.label = "Q3.RT.entityAS.scratch"
            enc.label = "Q3.RT.buildEntityAS"
            enc.build(accelerationStructure: accel,
                      descriptor: asDesc,
                      scratchBuffer: scratch,
                      scratchBufferOffset: 0)
            enc.endEncoding()
            entityASLogCounter &+= 1
            if entityASLogCounter == 1 || entityASLogCounter % 120 == 0 {
                print("[RT] built entity AS: slot=\(clampedSlot) vertices=\(vertexCount) indices=\(indexCount) tris=\(indexCount / 3) size=\(sizes.accelerationStructureSize)")
            }
            return accel
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
            rtLastMaterialSignature = rtWorldMaterialSignature()
            rtPrimitiveMaterialBufferCache.removeAll(keepingCapacity: true)
            if rtLastMaterialSignature != 0, let buf = rtPrimitiveMaterialBuffer {
                rtPrimitiveMaterialBufferCache[rtLastMaterialSignature] = buf
            }
            print("[RT] built world AS: vertices=\(vertexCount) indices=\(indexCount) tris=\(indexCount / 3) size=\(sizes.accelerationStructureSize)")
            return accel
        }

        @MainActor
        private func ensureRTTextures(device: MTLDevice,
                                      traceWidth: Int,
                                      traceHeight: Int,
                                      compositeWidth: Int,
                                      compositeHeight: Int,
                                      pixelFormat: MTLPixelFormat) -> Bool {
            let tw = max(traceWidth, 1), th = max(traceHeight, 1)
            let cw = max(compositeWidth, 1), ch = max(compositeHeight, 1)
            let rtPixelFormat: MTLPixelFormat = (Q3_RTHDR() != 0) ? .rgba16Float : .rgba8Unorm
            if rtTexture != nil && rtAccumTexture != nil && rtHistoryTexture != nil && rtCompositeTexture != nil &&
                rtTextureSize.width == tw && rtTextureSize.height == th &&
                rtCompositeTextureSize.width == cw && rtCompositeTextureSize.height == ch &&
                rtTexturePixelFormat == rtPixelFormat {
                return true
            }
            let rtDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: rtPixelFormat, width: tw, height: th, mipmapped: false)
            rtDesc.usage = [.shaderRead, .shaderWrite]; rtDesc.storageMode = .private
            let compDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: pixelFormat, width: cw, height: ch, mipmapped: false)
            compDesc.usage = [.shaderRead, .shaderWrite]; compDesc.storageMode = .private
            rtTexture = device.makeTexture(descriptor: rtDesc)
            rtAccumTexture = device.makeTexture(descriptor: rtDesc)
            rtHistoryTexture = device.makeTexture(descriptor: rtDesc)
            rtCompositeTexture = device.makeTexture(descriptor: compDesc)
            rtTexture?.label = "Q3.RT.output.halfres"
            rtAccumTexture?.label = "Q3.RT.accum.halfres"
            rtHistoryTexture?.label = "Q3.RT.history.halfres"
            rtCompositeTexture?.label = "Q3.RT.composite"
            rtTextureSize = MTLSize(width: tw, height: th, depth: 1)
            rtCompositeTextureSize = MTLSize(width: cw, height: ch, depth: 1)
            rtTexturePixelFormat = rtPixelFormat
            rtHistoryValid = false
            print("[RT] textures trace=\(tw)x\(th) format=\(rtPixelFormat) composite=\(cw)x\(ch) history=reset")
            return rtTexture != nil && rtAccumTexture != nil && rtHistoryTexture != nil && rtCompositeTexture != nil
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
        private func ensurePBRMissingTexture(device: MTLDevice) -> MTLTexture? {
            if let pbrMissingTexture { return pbrMissingTexture }
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
                                                                width: 1,
                                                                height: 1,
                                                                mipmapped: false)
            desc.usage = [.shaderRead]
            desc.storageMode = .shared
            guard let tex = device.makeTexture(descriptor: desc) else { return nil }
            let pixel: [UInt8] = [255, 0, 255, 255] // magenta = missing PBR
            pixel.withUnsafeBytes { bytes in
                tex.replace(region: MTLRegionMake2D(0, 0, 1, 1),
                            mipmapLevel: 0,
                            withBytes: bytes.baseAddress!,
                            bytesPerRow: 4)
            }
            tex.label = "Q3.PBR.missing.magenta"
            pbrMissingTexture = tex
            return tex
        }

        private func textureNameForLog(_ handle: UInt32) -> String {
            Q3MetalRenderer_GetTextureName(handle).map { String(cString: $0) } ?? "unknown"
        }

        private func shouldPreferClassicTextureForAlphaFX(_ textureName: String, isEntity: Bool) -> Bool {
            let raw = textureName.lowercased()
            let n: String
            if raw.hasPrefix("*entity-stage:"), let lastColon = raw.lastIndex(of: ":") {
                n = String(raw[raw.index(after: lastColon)...])
            } else {
                n = raw
            }
            // 2026-06-10: weapon viewmodel base-skin guard. Opaque first-person
            // weapon bodies live at `models/weapons2/<weapon>/<weapon>.tga`
            // (and `<weapon>2.tga` for the lightning gun's body). Without this
            // guard the broad token list below catches `"plasma"`, `"rail"`,
            // etc. and force-disables PBR on the plasma/railgun viewmodels
            // even though they should be reading as PBR metal. Sub-files in
            // the same directory (f_*.tga flash, tracer/explosion/muzzle FX
            // entries) still fall through to the token check below.
            if Self.isWeaponViewmodelBaseSkin(n) { return false }
            if n.hasPrefix("sprites/") || n.hasPrefix("gfx/") || n.hasPrefix("models/weaphits/") ||
               n.hasPrefix("models/ammo/rocket/rockfl") || n.hasPrefix("models/mapobjects/teleporter/") ||
               n.hasPrefix("textures/sfx/") || n.hasPrefix("textures/effects/") {
                return true
            }
            let tokens = [
                "smoke", "puff", "explosion", "boom", "muzzle", "tracer",
                "flame", "fire", "plasma", "rail", "teleport", "quadweapon",
                "sphere", "energy", "glass", "transparency", "flare", "glow",
                "spark", "laser", "balloon", "beam", "jumppad", "launchpad", "bouncepad"
            ]
            if tokens.contains(where: { n.contains($0) }) { return true }
            // Q3 model/effect overlay stages frequently have no useful alpha in
            // Remix captures. Keep them in the original shader path unless they
            // are the opaque base skins that already have working PBR.
            if isEntity && (n.hasPrefix("powerups/") || n.hasPrefix("models/powerups/")) { return true }
            return false
        }

        private func shouldAllowClassicFallbackInPBROnly(_ textureName: String, isEntity: Bool) -> Bool {
            let raw = textureName.lowercased()
            // Synthetic entity-stage labels look like
            // "*entity-stage:0:models/powerups/ammo/rockammo.tga". Classify using
            // the underlying texture path, not the diagnostic prefix.
            let n: String
            if raw.hasPrefix("*entity-stage:"), let lastColon = raw.lastIndex(of: ":") {
                n = String(raw[raw.index(after: lastColon)...])
            } else {
                n = raw
            }
            if n == "unknown" || n == "*white" || n.hasPrefix("*lightmap:") { return true }

            // PBR-only is a world-material diagnostic, not an FX validator. These
            // paths are Q3 shader/effect assets whose correct rendering depends on
            // alphaGen/rgbGen/blendFunc/depth sorting, and many intentionally have
            // no Remix PBR replacement. Let them use the classic texture so magenta
            // only marks actionable missing PBR world materials.
            let classicPrefixes = [
                "sprites/", "gfx/", "icons/", "menu/", "levelshots/", "powerups/",
                "models/weaphits/", "models/ammo/", "models/powerups/",
                "models/mapobjects/", "models/weapons2/",
                "textures/sfx/", "textures/effects/", "textures/base_light/",
                "textures/gothic_light/", "textures/base_trim/techborder_fx"
            ]
            if classicPrefixes.contains(where: { n.hasPrefix($0) }) { return true }

            let fxTokens = [
                "smoke", "puff", "explosion", "boom", "muzzle", "tracer",
                "flame", "fire", "plasma", "rail", "rocket", "teleport",
                "quad", "sphere", "energy", "glass", "transparency", "flare",
                "glow", "spark", "tesla", "slime", "lava", "gruel", "liquid", "water", "fog", "chrome", "spec", "laser", "balloon",
                "blend", "light", "beam", "jumppad", "launchpad", "bouncepad",
                "comp3text", "steed"
            ]
            if fxTokens.contains(where: { n.contains($0) }) { return true }

            // Entity submissions are mostly models/items/effects. If a model/item
            // really has a PBR material pbrAlbedoTexture(for:) already returned it
            // above; otherwise prefer the original skin over magenta debug geometry.
            if isEntity { return true }
            return false
        }

        private struct WorldTextureSelection {
            let texture: MTLTexture
            let useWorldPBR: Bool
            let classicFX: Bool
            let atlasParams: SIMD4<Float>?
            let materialHandle: UInt32
        }

        @MainActor
        private func worldOwnerMaterialHandle(for draw: Q3MetalWorldDrawCmd,
                                              stageIndex: Int,
                                              stage: Q3MetalWorldStage) -> UInt32 {
            let currentHandle = stage.textureHandle
            guard stage.useLightmap == 0 else { return currentHandle }

            let explicitOwner = stage.pbrMaterialHandle
            if explicitOwner != 0 && explicitOwner != currentHandle {
                let logKey = (UInt64(currentHandle) << 32) | UInt64(explicitOwner)
                if loggedWorldOwnerMaterialRoutes.insert(logKey).inserted {
                    pbrLog("[Q3-PBR] world FX owner-material handle=\(currentHandle) name='\(textureNameForLog(currentHandle))' materialHandle=\(explicitOwner) material='\(textureNameForLog(explicitOwner))'")
                }
                return explicitOwner
            }

            let currentName = textureNameForLog(currentHandle).lowercased()
            let isClassicEffectLayer =
                currentName.hasPrefix("textures/sfx/") ||
                currentName.hasPrefix("textures/liquids/")
            guard isClassicEffectLayer else { return currentHandle }

            let count = min(Int(draw.stageCount), Int(Q3_METAL_MAX_STAGES))
            guard count > 1 else { return currentHandle }

            for i in stride(from: count - 1, through: 0, by: -1) where i != stageIndex {
                let candidate = Self.worldStage(draw, i)
                guard candidate.useLightmap == 0,
                      candidate.textureHandle != 0,
                      candidate.textureHandle != currentHandle else { continue }
                let candidateName = textureNameForLog(candidate.textureHandle).lowercased()
                guard !candidateName.hasPrefix("textures/sfx/"),
                      !candidateName.hasPrefix("textures/liquids/") else { continue }
                guard let info = pbrMaterialInfo(for: candidate.textureHandle),
                      info.albedo != nil,
                      info.hasAuxSlots else { continue }

                let logKey = (UInt64(currentHandle) << 32) | UInt64(candidate.textureHandle)
                if loggedWorldOwnerMaterialRoutes.insert(logKey).inserted {
                    pbrLog("[Q3-PBR] world FX owner-material handle=\(currentHandle) name='\(textureNameForLog(currentHandle))' materialHandle=\(candidate.textureHandle) material='\(textureNameForLog(candidate.textureHandle))'")
                }
                return candidate.textureHandle
            }

            if currentName.contains("fireswirl2blue") {
                let logKey = UInt64(currentHandle) << 32
                if loggedWorldOwnerMaterialRoutes.insert(logKey).inserted {
                    var candidates: [String] = []
                    for i in 0..<count {
                        let s = Self.worldStage(draw, i)
                        candidates.append("#\(i):h\(s.textureHandle):\(textureNameForLog(s.textureHandle)):lm\(s.useLightmap)")
                    }
                    let candidateList = candidates.joined(separator: ",")
                    pbrLog("[Q3-PBR] world FX owner-material miss handle=\(currentHandle) name='\(textureNameForLog(currentHandle))' stageIndex=\(stageIndex) count=\(count) candidates=\(candidateList)")
                }
            }

            return currentHandle
        }

        @MainActor
        private func worldTextureSelectionForPBRDebug(handle: UInt32,
                                                      fallback: MTLTexture,
                                                      stage: Q3MetalWorldStage,
                                                      materialHandle: UInt32? = nil) -> WorldTextureSelection {
            let name = textureNameForLog(handle)
            let pbrHandle = materialHandle ?? handle
            let isFXStage = stage.blendMode != 0 ||
                            stage.alphaFunc != 0 ||
                            shouldPreferClassicTextureForAlphaFX(name, isEntity: false)
            if isFXStage {
                // Most blended/FX stages must stay classic, but Remix animation atlases
                // (launchpads/jumppads/etc.) are authored as replacement PBR strips.
                // Let those use PBR albedo so the atlas remap can animate while the
                // existing pass/blend state still comes from the Q3 shader stage.
                let fxAtlasParams = pbrSpriteAtlasParams(for: handle, atlasTime: Float(CACurrentMediaTime() - frameTimeOrigin))
                if fxAtlasParams.x > 0.5, let pbr = pbrAlbedoTexture(for: handle) {
                    if loggedPBROnlyWorldMisses.insert(handle).inserted {
                        pbrLog("[Q3-PBR] world FX atlas override handle=\(handle) name='\(name)' cols=\(fxAtlasParams.x) rows=\(fxAtlasParams.y) fps=\(fxAtlasParams.z)")
                    }
                    // FX atlas stages need the replacement atlas texture and
                    // atlas frame remap, but MUST keep classic Q3 semantics:
                    // authored rgbGen/alphaGen/blendFunc/luminance-alpha and
                    // zero PBR IBL/ambient contribution. Enabling world PBR
                    // here lights black atlas padding, exposing carrier quads.
                    return WorldTextureSelection(texture: pbr,
                                                 useWorldPBR: false,
                                                 classicFX: true,
                                                 atlasParams: fxAtlasParams,
                                                 materialHandle: handle)
                }
                // RTX-Remix authored emissive/PBR floor + wall shaders
                // (q3dm1 textures/gothic_floor/largerblock3b_ow,
                // textures/gothic_block/killblockgeomtrn) have alpha-blend
                // stages but carry full PBR sidecars (normal/height/
                // roughness/metallic/emissive) keyed off the same material
                // entry. The plain FX path returns useWorldPBR:false which
                // skips loading and binding those sidecars — the surface
                // reads as flat color even though the assets ship.
                // Promote to useWorldPBR:true ONLY for FX stages where the
                // material has real authored sidecar maps; pure FX sprites
                // without sidecars stay on the classic path.
                if pbrMaterialHasAuxSlots(pbrHandle), let pbr = pbrAlbedoTexture(for: pbrHandle) {
                    if loggedPBROnlyWorldMisses.insert(handle).inserted {
                        let materialName = (pbrHandle != handle) ? " materialHandle=\(pbrHandle) material='\(textureNameForLog(pbrHandle))'" : ""
                        pbrLog("[Q3-PBR] world FX-stage + PBR-sidecars handle=\(handle) name='\(name)'\(materialName)")
                    }
                    return WorldTextureSelection(texture: pbr,
                                                 useWorldPBR: true,
                                                 classicFX: true,
                                                 atlasParams: nil,
                                                 materialHandle: pbrHandle)
                }
                if Q3_PBROnlyTextures() != 0 && loggedPBROnlyWorldMisses.insert(handle).inserted {
                    pbrLog("[Q3-PBR-ONLY] world FX/classic fallback handle=\(handle) name='\(name)'")
                }
                return WorldTextureSelection(texture: fallback, useWorldPBR: false, classicFX: true, atlasParams: nil, materialHandle: handle)
            }
            if let pbr = pbrAlbedoTexture(for: pbrHandle) {
                return WorldTextureSelection(texture: pbr, useWorldPBR: true, classicFX: false, atlasParams: nil, materialHandle: pbrHandle)
            }
            // Some bridge entries intentionally have no authored albedo but do
            // carry useful PBR side data (normal/roughness/metalness constants
            // or maps). Keep the original Q3 diffuse as base color, but still
            // enable the world PBR/IBL path so those surfaces do not fall all
            // the way back to flat classic lighting.
            if pbrMaterialHasAuxSlots(pbrHandle) {
                if loggedPBROnlyWorldMisses.insert(handle).inserted {
                    let materialName = (pbrHandle != handle) ? " materialHandle=\(pbrHandle) material='\(textureNameForLog(pbrHandle))'" : ""
                    pbrLog("[Q3-PBR] world classic-albedo + PBR-sidecars handle=\(handle) name='\(name)'\(materialName)")
                }
                return WorldTextureSelection(texture: fallback, useWorldPBR: true, classicFX: false, atlasParams: nil, materialHandle: pbrHandle)
            }
            if Q3_PBROnlyTextures() != 0 {
                if shouldAllowClassicFallbackInPBROnly(name, isEntity: false) {
                    if loggedPBROnlyWorldMisses.insert(handle).inserted {
                        pbrLog("[Q3-PBR-ONLY] world FX/classic fallback handle=\(handle) name='\(name)'")
                    }
                    return WorldTextureSelection(texture: fallback, useWorldPBR: false, classicFX: true, atlasParams: nil, materialHandle: handle)
                }
                if loggedPBROnlyWorldMisses.insert(handle).inserted {
                    pbrLog("[Q3-PBR-ONLY] world missing PBR handle=\(handle) name='\(name)' -> classic fallback")
                }
                return WorldTextureSelection(texture: fallback,
                                             useWorldPBR: false,
                                             classicFX: true,
                                             atlasParams: nil,
                                             materialHandle: handle)
            }
            return WorldTextureSelection(texture: fallback, useWorldPBR: false, classicFX: false, atlasParams: nil, materialHandle: handle)
        }

        @MainActor
        private func entityBaseTextureForPBRDebug(handle: UInt32, fallback: MTLTexture) -> MTLTexture {
            if let pbr = pbrAlbedoTexture(for: handle) { return pbr }
            if Q3_PBROnlyTextures() != 0 {
                let name = textureNameForLog(handle)
                if shouldAllowClassicFallbackInPBROnly(name, isEntity: true) {
                    if loggedPBROnlyEntityMisses.insert(handle).inserted {
                        pbrLog("[Q3-PBR-ONLY] entity FX/classic fallback handle=\(handle) name='\(name)'")
                    }
                    return fallback
                }
                if loggedPBROnlyEntityMisses.insert(handle).inserted {
                    pbrLog("[Q3-PBR-ONLY] entity missing PBR handle=\(handle) name='\(name)' -> classic fallback")
                }
                return fallback
            }
            return fallback
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
            let rtNow = Float(CACurrentMediaTime() - frameTimeOrigin)
            if rtNow - rtLastMaterialRefreshTime >= (1.0 / 30.0) {
                let sig = rtWorldMaterialSignature()
                if sig != 0 && sig != rtLastMaterialSignature {
                    if let cached = rtPrimitiveMaterialBufferCache[sig] {
                        rtPrimitiveMaterialBuffer = cached
                        rtLastMaterialSignature = sig
                    } else {
                        let primitiveCount = Int(Q3MetalRenderer_GetWorldIndexCount()) / 3
                        if primitiveCount > 0 {
                            let t0 = CACurrentMediaTime()
                            buildRTPrimitiveMaterials(device: device, primitiveCount: primitiveCount, log: false)
                            rtLastMaterialSignature = sig
                            if let buf = rtPrimitiveMaterialBuffer {
                                if rtPrimitiveMaterialBufferCache.count > 96 {
                                    rtPrimitiveMaterialBufferCache.removeAll(keepingCapacity: true)
                                }
                                rtPrimitiveMaterialBufferCache[sig] = buf
                            }
                            let refreshMs = (CACurrentMediaTime() - t0) * 1000.0
                            if refreshMs > 5.0 {
                                print(String(format: "[RT] material refresh %.2f ms sig=%016llx cache=%d", refreshMs, sig, rtPrimitiveMaterialBufferCache.count))
                            }
                        }
                    }
                }
                rtLastMaterialRefreshTime = rtNow
            }
            guard let primitiveMaterialBuffer = rtPrimitiveMaterialBuffer else { return nil }
            guard let rtPSO = ensureRTPipeline(device: device),
                  let accumPSO = ensureRTAccumPipeline(device: device),
                  let blendPSO = ensureRTBlendPipeline(device: device) else { return nil }
            let rtResolutionScale = Q3_RTResolutionScale()
            let rtBounceCount = Q3_RTBounces()
            let rtTAAEnabled = Q3_RTTAA() > 0.5
            let rtTAAAlpha = Q3_RTTAAAlpha()
            let traceW = max(1, Int((Float(renderW) * rtResolutionScale).rounded(.toNearestOrAwayFromZero)))
            let traceH = max(1, Int((Float(renderH) * rtResolutionScale).rounded(.toNearestOrAwayFromZero)))
            guard ensureRTTextures(device: device,
                                   traceWidth: traceW,
                                   traceHeight: traceH,
                                   compositeWidth: renderW,
                                   compositeHeight: renderH,
                                   pixelFormat: rasterTexture.pixelFormat),
                  let rtTex = rtTexture,
                  let accumTex = rtAccumTexture,
                  let historyTex = rtHistoryTexture,
                  let compositeTex = rtCompositeTexture else { return nil }

            func halton(_ index: UInt32, _ base: UInt32) -> Float {
                var i = index
                var f: Float = 1
                var r: Float = 0
                while i > 0 {
                    f /= Float(base)
                    r += f * Float(i % base)
                    i /= base
                }
                return r
            }
            let viewProj = makeWorldViewProjection(sceneView)
            let cameraPos = SIMD3<Float>(sceneView.viewOrigin.0, sceneView.viewOrigin.1, sceneView.viewOrigin.2)
            let forward = SIMD3<Float>(sceneView.viewAxis.0, sceneView.viewAxis.1, sceneView.viewAxis.2)
            let right = SIMD3<Float>(-sceneView.viewAxis.3, -sceneView.viewAxis.4, -sceneView.viewAxis.5)
            let up = SIMD3<Float>(sceneView.viewAxis.6, sceneView.viewAxis.7, sceneView.viewAxis.8)
            let forwardLen = max(simd_length(forward), 0.0001)
            let forwardNorm = forward / forwardLen
            if let lastPos = rtLastCameraPos, let lastForward = rtLastCameraForward {
                let moved = simd_length_squared(cameraPos - lastPos) > 0.25
                let turned = simd_dot(forwardNorm, lastForward) < 0.9995
                if moved || turned { rtHistoryValid = false }
            }
            rtLastCameraPos = cameraPos
            rtLastCameraForward = forwardNorm

            rtJitterFrame &+= 1
            let jitter = rtTAAEnabled
                ? SIMD2<Float>((halton(rtJitterFrame, 2) - 0.5) / Float(max(traceW, 1)),
                               (halton(rtJitterFrame, 3) - 0.5) / Float(max(traceH, 1)))
                : SIMD2<Float>(0, 0)
            var uniforms = RayTracingUniforms(viewProjection: viewProj,
                                              invViewProjection: simd_inverse(viewProj),
                                              cameraPos: SIMD4<Float>(cameraPos.x, cameraPos.y, cameraPos.z, 0),
                                              cameraForward: SIMD4<Float>(forward.x, forward.y, forward.z, 0),
                                              cameraRight: SIMD4<Float>(right.x, right.y, right.z, 0),
                                              cameraUp: SIMD4<Float>(up.x, up.y, up.z, 0),
                                              jitterNearFar: SIMD4<Float>(jitter.x, jitter.y, 4.0, 8192.0),
                                              fovParams: SIMD4<Float>(tan(sceneView.fovX * .pi / 360.0), tan(sceneView.fovY * .pi / 360.0), Float(CACurrentMediaTime() - frameTimeOrigin), (entityAccelerationStructure == nil || Q3_RTEntities() == 0) ? 0 : 1),
                                              rtToneParams: SIMD4<Float>(Q3_RTExposure(), Q3_RTGamma(), Q3_RTAmbient(), Q3_RTNormalMix()),
                                              rtControlParams: SIMD4<Float>(rtResolutionScale, rtBounceCount, rtTAAAlpha, rtTAAEnabled ? 1.0 : 0.0))
            // P1/P3: per-map authored light set + reflection controls.
            // Light count is forced to 0 when the buffer alloc failed so
            // the kernel never reads an unbound/empty buffer(6).
            let lightInfo = ensureRTLightBuffer(device: device)
            uniforms.rtLightParams = SIMD4<Float>(
                (Q3_RTLights() != 0 && lightInfo.buffer != nil) ? Float(lightInfo.count) : 0,
                Q3_RTLightScale(),
                Q3_RTReflections() != 0 ? 1.0 : 0.0,
                Q3_RTReflRoughnessMax())
            uniforms.rtAtmosphereParams = SIMD4<Float>(
                Q3_RTAtmosphereDensity(),
                Q3_RTAtmosphereGrey(),
                Q3_RTAtmosphereSkyAlpha(),
                Q3_RTAtmosphereMax())
            // rtPBRGlobal: x=normal scale (Step 2c), y=parallax (Step 5, reserved),
            // z=lightmap scale, w=direct-light scale (RT lighting rebalance; both 1=current).
            uniforms.rtPBRGlobal = SIMD4<Float>(Q3_RTNormalScale(), 0,
                                                Q3_RTLightmapScale(), Q3_RTDirectScale())
            if !rtOverlayLogPrintedOnce {
                print("[RT] overlay active mix=\(mixValue) trace=\(traceW)x\(traceH) scale=\(rtResolutionScale) bounces=\(rtBounceCount) taa=\(rtTAAEnabled ? 1 : 0) composite=\(renderW)x\(renderH) camera=\(cameraPos)")
                rtOverlayLogPrintedOnce = true
            }
            let tg = MTLSize(width: 16, height: 16, depth: 1)
            let traceGroups = MTLSize(width: (traceW + 15) / 16, height: (traceH + 15) / 16, depth: 1)
            let compositeGroups = MTLSize(width: (renderW + 15) / 16, height: (renderH + 15) / 16, depth: 1)
            guard let shadowCounterBuffer = nextRTShadowCounterBuffer(device: device) else { return nil }
            if let blit = commandBuffer.makeBlitCommandEncoder() {
                blit.label = "Q3.RT.clearSunShadowCounters"
                blit.fill(buffer: shadowCounterBuffer,
                          range: 0..<shadowCounterBuffer.length,
                          value: 0)
                blit.endEncoding()
            }
            if let enc = commandBuffer.makeComputeCommandEncoder() {
                enc.label = "Q3.RT.trace"
                enc.setComputePipelineState(rtPSO)
                enc.setTexture(rtTex, index: 0)
                let envCube = ensurePBREnvCube()
                let envLabel = envCube?.label ?? "<nil>"
                if rtLastEnvCubeLabel != envLabel {
                    print("[RT] skybox env source=\(envLabel) stem=\(currentPBRSkyboxStem() ?? "<procedural>")")
                    rtLastEnvCubeLabel = envLabel
                    rtHistoryValid = false
                }
                enc.setTexture(envCube, index: 1)
                // Step 2a: encode the RT texture table into an argument buffer
                // (buffer 8) instead of 126 direct setTexture binds. Frees the
                // 128-binding cap so PBR sidecars can be added later. The MSL
                // RTTexTable lays out albedo at id 0..109, lightmap at id 110..125.
                if let argEnc = rtTexArgEncoder, let fallbackTex = ensureRTWhiteTexture(device: device) {
                    var rtTexResident: [MTLTexture] = []
                    rtTexResident.reserveCapacity(rtMaxAlbedoSlots * 3 + rtMaxLightmapSlots)
                    // Order MUST match RTTexTable id layout: albedo(0..109),
                    // lightmap(110..125), normal(126..235), height(236..345).
                    for i in 0..<rtMaxAlbedoSlots {
                        let h = rtAlbedoHandles[i]
                        rtTexResident.append(pbrAlbedoTexture(for: h) ?? texture(for: h, device: device) ?? fallbackTex)
                    }
                    for i in 0..<rtMaxLightmapSlots {
                        rtTexResident.append(texture(for: rtLightmapHandles[i], device: device) ?? fallbackTex)
                    }
                    // Step 2b: PBR sidecars parallel to albedo. normal[i]/height[i]
                    // resolve from the SAME handle as albedo[i]. Fallback to flat
                    // normal / white when the material lacks that channel. Kernel
                    // does not sample these yet — encoded now to verify the larger
                    // arg buffer renders identically before Step 2c wires reads.
                    let flatNormal = pbrFlatNormalDefault() ?? fallbackTex
                    for i in 0..<rtMaxAlbedoSlots {
                        let h = rtAlbedoHandles[i]
                        rtTexResident.append(pbrNormalTexture(for: h, allowGenericFallback: false) ?? flatNormal)
                    }
                    for i in 0..<rtMaxAlbedoSlots {
                        let h = rtAlbedoHandles[i]
                        rtTexResident.append(pbrHeightTexture(for: h) ?? fallbackTex)
                    }
                    // Fresh arg buffer each frame (avoids GPU-in-flight aliasing;
                    // ~1 KB, cheap). Metal refcounts it until the dispatch drains.
                    let argBuf = device.makeBuffer(length: argEnc.encodedLength, options: .storageModeShared)
                    argBuf?.label = "Q3.RT.texTableArgBuffer"
                    if let argBuf {
                        argEnc.setArgumentBuffer(argBuf, offset: 0)
                        for (i, t) in rtTexResident.enumerated() { argEnc.setTexture(t, index: i) }
                        enc.setBuffer(argBuf, offset: 0, index: 8)
                        // CRITICAL: every texture referenced by the arg buffer must be
                        // made resident or the GPU faults/hangs on access.
                        for t in rtTexResident { enc.useResource(t, usage: .read) }
                    }
                }
                enc.setBytes(&uniforms, length: MemoryLayout<RayTracingUniforms>.stride, index: 0)
                enc.setAccelerationStructure(worldAS, bufferIndex: 1)
                enc.setBuffer(rtASIndexBuffer, offset: 0, index: 2)
                enc.setBuffer(rtASVertexBuffer, offset: 0, index: 3)
                enc.setBuffer(primitiveMaterialBuffer, offset: 0, index: 4)
                enc.setAccelerationStructure(entityAccelerationStructure ?? worldAS, bufferIndex: 5)
                enc.setBuffer(lightInfo.buffer, offset: 0, index: 6)
                enc.setBuffer(shadowCounterBuffer, offset: 0, index: 7)
                enc.dispatchThreadgroups(traceGroups, threadsPerThreadgroup: tg)
                enc.endEncoding()
            }
            var accumAlpha: Float = (!rtTAAEnabled || !rtHistoryValid) ? 1.0 : rtTAAAlpha
            if let enc = commandBuffer.makeComputeCommandEncoder() {
                enc.label = "Q3.RT.accumulate"
                enc.setComputePipelineState(accumPSO)
                enc.setTexture(rtTex, index: 0)
                enc.setTexture(historyTex, index: 1)
                enc.setTexture(accumTex, index: 2)
                enc.setBytes(&accumAlpha, length: MemoryLayout<Float>.stride, index: 0)
                enc.dispatchThreadgroups(traceGroups, threadsPerThreadgroup: tg)
                enc.endEncoding()
            }
            // 2026-06-10: gate the history blit on `rtTAAEnabled`.
            // When TAA is off, `accumAlpha` is forced to 1.0 above, which
            // makes the accumulate kernel `mix(h, c, 1.0)` reduce to `c` —
            // the next-frame read of `historyTex` is multiplied by zero, so
            // this write is provably dead work. Xcode Insights flagged it
            // as "Q3.RT.copyAccumToHistory unused resource" — 3.45 MiB +
            // ~60 µs per frame. In TAA-on mode the write IS live (next
            // frame's accumulate uses history with `alpha=rtTAAAlpha`), but
            // Xcode's per-frame static analysis cannot see the cross-frame
            // consumer so it still flags — accept that as a false positive
            // when the cvar is actually on. Followup: when TAA is off, we
            // could also skip the accumulate dispatch and bind `rtTex`
            // directly to `blend`'s texture(0) — defer until measured.
            if rtTAAEnabled, let blit = commandBuffer.makeBlitCommandEncoder() {
                blit.label = "Q3.RT.copyAccumToHistory"
                blit.copy(from: accumTex, sourceSlice: 0, sourceLevel: 0,
                          sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                          sourceSize: MTLSize(width: traceW, height: traceH, depth: 1),
                          to: historyTex, destinationSlice: 0, destinationLevel: 0,
                          destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
                blit.endEncoding()
                rtHistoryValid = true
            }
            var blendUniforms = RTBlendUniforms(mixAmount: mixValue,
                                                bloomIntensity: Q3_RTBloom(),
                                                bloomThreshold: Q3_RTBloomThreshold(),
                                                bloomRadius: Q3_RTBloomRadius())
            if let enc = commandBuffer.makeComputeCommandEncoder() {
                enc.label = "Q3.RT.blend"
                enc.setComputePipelineState(blendPSO)
                enc.setTexture(accumTex, index: 0)
                enc.setTexture(rasterTexture, index: 1)
                enc.setTexture(compositeTex, index: 2)
                enc.setBytes(&blendUniforms, length: MemoryLayout<RTBlendUniforms>.stride, index: 0)
                enc.dispatchThreadgroups(compositeGroups, threadsPerThreadgroup: tg)
                enc.endEncoding()
            }
            rtMetricsFrame &+= 1
            let metricsNow = CACurrentMediaTime()
            if metricsNow - rtLastMetricsLogTime >= 2.0 {
                rtLastMetricsLogTime = metricsNow
                let frameId = rtMetricsFrame
                let scaleText = String(format: "%.2f", rtResolutionScale)
                let taaText = rtTAAEnabled ? "1" : "0"
                let alphaText = String(format: "%.2f", rtTAAAlpha)
                let bloomText = String(format: "%.2f", blendUniforms.bloomIntensity)
                print("[RT] metrics frame=\(frameId) trace=\(traceW)x\(traceH) composite=\(renderW)x\(renderH) scale=\(scaleText) bounces=\(Int(rtBounceCount)) taa=\(taaText) taaAlpha=\(alphaText) hdr=\(Q3_RTHDR()) bloom=\(bloomText) groups=\(traceGroups.width)x\(traceGroups.height)")
                commandBuffer.addCompletedHandler { cb in
                    let gpuMs = (cb.gpuEndTime > cb.gpuStartTime) ? (cb.gpuEndTime - cb.gpuStartTime) * 1000.0 : 0.0
                    if gpuMs > 0.0 {
                        print(String(format: "[RT] metrics frame=%llu gpuCommandMs=%.3f", frameId, gpuMs))
                    }
                }
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
                    /* Use brush bounds, not fog-surface plane sign, to decide
                     * whether the eye is in the volume. q3dm4's fog cap is
                     * visible even when the surface equation sign is opposite
                     * our test, which left the line/cap but skipped the actual
                     * under-fog ray-box. Bounds still prevent the old adjacent-
                     * room slab artifact. */
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
        private var loggedAlphaEffectTextures: Set<UInt32> = []
        // 2026-06-10: one-shot per-handle viewmodel PBR resolution diagnostic.
        // Logs at the primary entity bind site for first-person weapons
        // (wantsDepthHack=true). Lets us confirm which slot each viewmodel
        // gets (real material vs default fallback) and which gates fired.
        private var loggedViewmodelPBRHandles: Set<UInt32> = []
        // 2026-06-10: one-shot log when the viewmodel base-color floor first
        // fires on a RF_DEPTHHACK draw with `r_pbr_viewmodel_floor > 0`.
        private var loggedViewmodelFloorOnce: Bool = false
        private lazy var alphaTextureLogURL: URL? = {
            FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
                .appendingPathComponent("q3_alpha_tex.log")
        }()

        private func logAlphaTextureDiagnostic(_ message: String) {
            NSLog("%@", message)
            guard let url = alphaTextureLogURL else { return }
            let data = Data((message + "\n").utf8)
            if FileManager.default.fileExists(atPath: url.path),
               let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: url, options: .atomic)
            }
        }

        private static func normalizedQ3TextureName(_ name: String) -> String {
            let raw = name.lowercased()
            if raw.hasPrefix("*entity-stage:"), let lastColon = raw.lastIndex(of: ":") {
                return String(raw[raw.index(after: lastColon)...])
            }
            return raw
        }

        // Matches `models/weapons2/<weapon>/<weapon>.<ext>` and
        // `models/weapons2/<weapon>/<weapon>2.<ext>` (lightning gun's `lightning2.tga`).
        // Used by `shouldPreferClassicTextureForAlphaFX` and `textureAlphaSynthesisMode`
        // to exempt opaque weapon viewmodel base skins from FX classifier rules.
        private static func isWeaponViewmodelBaseSkin(_ n: String) -> Bool {
            guard n.hasPrefix("models/weapons2/") else { return false }
            let parts = n.split(separator: "/")
            guard parts.count == 4 else { return false }
            let weapon = String(parts[2])
            let leaf = String(parts[3])
            guard let basenameNoExt = leaf.split(separator: ".").first.map(String.init) else { return false }
            return basenameNoExt == weapon || basenameNoExt == "\(weapon)2"
        }

        private static func textureAlphaSynthesisMode(_ name: String) -> UInt32 {
            let n = normalizedQ3TextureName(name)
            // 2026-06-10: weapon viewmodel base-skin guard. `n.contains("lightning")`
            // below catches the lightning gun's `lightning2.tga` body texture and
            // force-routes it into the alpha-from-luminance FX path, which makes
            // the viewmodel render as a flat additive sprite. Skip alpha synthesis
            // for opaque weapon base skins; sub-files (f_*.tga, etc.) still match
            // the rules below.
            if isWeaponViewmodelBaseSkin(n) { return 0 }
            // White-background captures: alpha is the inverse of luminance.
            // These were the visible white square / white blob artifacts.
            // Health/ammo pickup shell stages and sphere/orb overlays commonly
            // arrive from Remix as opaque white-card captures; using luminance
            // would preserve the card, inverse-luminance cuts it out.
            if n.contains("smoke") || n.contains("puff") ||
               n.contains("explosion") || n.contains("boom") ||
               n.contains("balloon") || n.contains("blood") ||
               n.contains("sphere") || n.contains("orb") ||
               n.contains("quad") || n.contains("regen") ||
               n.contains("haste") || n.contains("invis") ||
               n.contains("health") || n.contains("mega") ||
               n.contains("ammo/") || n.contains("ammo_") ||
               n.contains("rockammo") || n.contains("machammo") ||
               n.contains("shotammo") || n.contains("railammo") ||
               n.contains("tinfx") || n.contains("envmapgold") ||
               n.contains("envmapyel") || n.contains("envmaprail") ||
               n.contains("energy_red") || n.contains("energy_blue") ||
               n.contains("energy_grn") || n.contains("energygreen") ||
               n.contains("newred") || n.contains("newyellow") ||
               n.contains("newgreen") || n.contains("armor/energy") ||
               n.contains("teleporter/transparency") {
                return 2
            }
            // Black-background additive/effect captures: alpha follows luminance.
            if n.hasPrefix("sprites/") || n.hasPrefix("gfx/misc/") ||
               n.hasPrefix("gfx/damage/") || n.hasPrefix("models/weaphits/") ||
               n.hasPrefix("textures/sfx/") || n.hasPrefix("textures/effects/") ||
               n.hasPrefix("models/mapobjects/teleporter/") ||
               n.hasPrefix("models/mapobjects/lamps/") ||
               n.hasPrefix("models/mapobjects/slamp/") ||
               n.hasPrefix("models/ammo/rocket/rockfl") {
                return 1
            }
            if n == "teleporteffect" || n == "gfx/misc/tracer" ||
               n.contains("laser") || n.contains("beam") ||
               n.contains("flare") || n.contains("glow") ||
               n.contains("bolt") || n.contains("lightning") ||
               n == "railcore" || n == "rail_core" ||
               n.contains("railcore") || n.contains("rail_core") ||
               n.contains("railcorethin") {
                return 1
            }
            if n.contains("/f_") || n.contains("f_machinegun") ||
               n.contains("f_rocketl") || n.contains("f_shotgun") ||
               n.contains("f_plasma") {
                return 1
            }
            return 0
        }

        private static func textureNameNeedsLuminanceAlpha(_ name: String) -> Bool {
            return textureAlphaSynthesisMode(name) != 0
        }

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
        // 2026-06-10: tracks the `r_pbr_envcube_grey` value used to build
        // the currently-cached procedural cube. When the cvar changes via
        // the in-game console, `ensurePBREnvCube()` notices the mismatch
        // and invalidates the cube so the next call rebuilds with the new
        // colour. Negative sentinel = "no procedural cube built yet".
        private var pbrEnvCubeGreyBuilt: Float = -1.0
        /// Stems whose 6-face FS read has already missed once. Without
        /// this cache the invalidate-on-stem-change at line 4978 fires
        /// every frame for any stem auto-published by the sky parser
        /// whose face TGAs aren't on disk (e.g. `full_rt`, `full`), and
        /// `tryBuildMapSkyboxCube` re-runs 6 `FS_ReadFile` calls per
        /// frame just to fall back to procedural. Observed at 7753
        /// retries/frame on q3dm7 with the published `full_rt` stem.
        /// Once a stem is in this set, subsequent invalidations short-
        /// circuit and the cached procedural cube is reused.
        private var pbrEnvCubeFailedStems: Set<String> = []
        /// (B) Session-level early-bail flag. Set to true on the first
        /// `tryBuildMapSkyboxCube()` call that can't find face 0 on disk
        /// when the env directory itself is also empty (no env/<anything>_ft.tga
        /// or _ft.jpg present). Future calls return nil immediately without
        /// probing the FS at all — useful when the bundle ships zero skybox
        /// faces (current state as of 2026-06-09) and every map needs IBL
        /// from the procedural cube. Per-stem retries are still possible via
        /// `pbrEnvCubeFailedStems`, but this flag catches the more common
        /// "bundle has no skybox at all" case in one path.
        private var pbrEnvBundleHasNoSkyboxAssets: Bool = false
        private var pbrEnvBundleCheckDone: Bool = false
        private var pbrTriedAndMissed: Set<UInt32> = []
        private var pbrNormalTried: Set<UInt32> = []
        private var pbrRoughnessTried: Set<UInt32> = []
        private var pbrMetallicTried: Set<UInt32> = []
        // Capture-format DDS hashes that are known to be unsupported by our
        // reader and should not emit repeated "DDS load FAILED" noise.
        // Keep this list tiny and explicit to avoid masking real regressions.
        private let captureDDSFailureSkipHashes: Set<String> = [
            "02C12E76E6B809A7",
            "A3E896158424164C",
            // BC7 animation strip is 1024×25600 (DXGI 98), beyond iOS
            // max 2D texture height; fallback to the classic source texture.
            "AE001B448262E37A"
        ]

        private func shouldSkipCaptureDDSFailure(path: String) -> Bool {
            let stem = String(URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent).uppercased()
            return captureDDSFailureSkipHashes.contains { raw in
                let hash = raw.uppercased()
                return stem == hash || stem.hasPrefix(hash)
            }
        }
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
        /// One-shot startup marker: on the very first pbrLog emit of a
        /// session, prepend a build-identifying line so a single grep can
        /// tell which bundle is actually running without UUID forensics.
        /// The marker carries the bundle path (which contains the iOS app
        /// install UUID), the binary's mtime, and an embedded compile-time
        /// indicator that this binary has the tolerant DDS loader.
        nonisolated(unsafe) private static var pbrLogStartupMarkerFired = false
        private func pbrLog(_ message: String) {
            if !Self.pbrLogStartupMarkerFired {
                Self.pbrLogStartupMarkerFired = true
                let bundlePath = Bundle.main.bundlePath
                let binaryPath = Bundle.main.executablePath ?? "<nil>"
                var binaryMtime = "<unknown>"
                if let attrs = try? FileManager.default.attributesOfItem(atPath: binaryPath),
                   let date = attrs[.modificationDate] as? Date {
                    let fmt = DateFormatter()
                    fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
                    binaryMtime = fmt.string(from: date)
                }
                let marker = "[Q3-PBR-SWIFT] tolerant-DDS-loader present bundle=\(bundlePath) binaryMtime=\(binaryMtime)"
                "metal_pbr_swift".withCString { typePtr in
                    marker.withCString { msgPtr in
                        Q3MetalRenderer_SwiftPBRLog(typePtr, msgPtr)
                    }
                }
            }
            "metal_pbr_swift".withCString { typePtr in
                message.withCString { msgPtr in
                    Q3MetalRenderer_SwiftPBRLog(typePtr, msgPtr)
                }
            }
        }

        private struct PBRMaterialInfo {
            let albedo: String?
            let normal: String?
            let roughness: String?
            let metallic: String?
            let emissive: String?
            let height: String?
            let emissiveIntensity: Float
            let emissiveColor: SIMD3<Float>
            let hasEmissiveColor: Bool
            let roughnessConstant: Float
            let metallicConstant: Float
            let spriteCols: Int32
            let spriteRows: Int32
            let spriteFps: Float

            var hasAuxSlots: Bool {
                normal != nil || roughness != nil || metallic != nil ||
                emissive != nil || height != nil ||
                roughnessConstant >= 0.0 || metallicConstant >= 0.0
            }
        }

        private var pbrMaterialInfoCache: [UInt32: PBRMaterialInfo] = [:]
        private var pbrMaterialInfoMisses: Set<UInt32> = []
        private var pbrMaterialExistsCache: [UInt32: Bool] = [:]
        private var loggedBakedTcModHandles: Set<UInt32> = []

        private func pbrMaterialInfo(for handle: UInt32) -> PBRMaterialInfo? {
            if let cached = pbrMaterialInfoCache[handle] { return cached }
            if pbrMaterialInfoMisses.contains(handle) { return nil }
            guard let matPtr = Q3MetalRenderer_GetPBRMaterial(handle) else {
                pbrMaterialInfoMisses.insert(handle)
                return nil
            }
            let mat = matPtr.pointee
            let info = PBRMaterialInfo(
                albedo: mat.albedo.map { String(cString: $0) },
                normal: mat.normal.map { String(cString: $0) },
                roughness: mat.roughness.map { String(cString: $0) },
                metallic: mat.metallic.map { String(cString: $0) },
                emissive: mat.emissive.map { String(cString: $0) },
                height: mat.height.map { String(cString: $0) },
                emissiveIntensity: mat.emissive_intensity,
                emissiveColor: SIMD3<Float>(mat.emissive_color_r, mat.emissive_color_g, mat.emissive_color_b),
                hasEmissiveColor: mat.has_emissive_color != 0,
                roughnessConstant: mat.roughness_constant,
                metallicConstant: mat.metallic_constant,
                spriteCols: mat.sprite_cols,
                spriteRows: mat.sprite_rows,
                spriteFps: mat.sprite_fps
            )
            pbrMaterialInfoCache[handle] = info
            return info
        }

        private func pbrMaterialExists(_ handle: UInt32) -> Bool {
            if let cached = pbrMaterialExistsCache[handle] { return cached }
            let exists = pbrMaterialInfo(for: handle) != nil
            pbrMaterialExistsCache[handle] = exists
            return exists
        }

        private func worldTcModChain(for stage: Q3MetalWorldStage) -> TcModChainPack {
            guard Q3_PBRBakedLightmaps() != 0,
                  stage.useLightmap == 0,
                  pbrMaterialExists(stage.textureHandle) else {
                return Self.fillTcMods(stage)
            }
            if loggedBakedTcModHandles.insert(stage.textureHandle).inserted {
                let name = textureNameForLog(stage.textureHandle)
                pbrLog("[Q3-BAKED] tcMod suppressed count=\(loggedBakedTcModHandles.count) handle=\(stage.textureHandle) name='\(name)' originalTcMods=\(stage.tcModCount)")
            }
            return Self.emptyTcMods()
        }

        private func pbrMaterialHasAuxSlots(_ handle: UInt32) -> Bool {
            pbrMaterialInfo(for: handle)?.hasAuxSlots ?? false
        }

        /// Tolerant DDS reader for RTX-Remix capture-format DDS files.
        /// MTKTextureLoader rejects `capture_textures_dds/*.dds` with
        /// "Image decoding failed" because the capture pipeline writes
        /// a bogus `dwPitchOrLinearSize` field while DDSD_PITCH is set.
        /// The pixel data itself is correct. This reader parses the
        /// header minimally, allocates an MTLTexture of the declared
        /// width × height × mipCount, and copies each mip in. Supports
        /// DXGI_FORMAT_R8G8B8A8_UNORM (the format the envmap atlases
        /// ship in) — that's the only format the indirect-name path
        /// currently surfaces. Returns nil for anything else; the
        /// caller falls back to its existing behaviour.
        private func loadCaptureFormatDDS(path: String, label: String) -> MTLTexture? {
            guard let device = self.commandQueue?.device else { return nil }
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
                if !shouldSkipCaptureDDSFailure(path: path) {
                    pbrLog("[Q3-PBR-SWIFT] capture-dds read FAILED path=\(path)")
                }
                return nil
            }
            guard data.count >= 148 else {
                if !shouldSkipCaptureDDSFailure(path: path) {
                    pbrLog("[Q3-PBR-SWIFT] capture-dds too small (\(data.count) bytes) path=\(path)")
                }
                return nil
            }
            // Magic "DDS "
            let magic = data.subdata(in: 0..<4)
            guard magic == Data([0x44, 0x44, 0x53, 0x20]) else {
                if !shouldSkipCaptureDDSFailure(path: path) {
                    pbrLog("[Q3-PBR-SWIFT] capture-dds bad magic path=\(path)")
                }
                return nil
            }
            // Helper to read UInt32 little-endian at byte offset.
            func u32(_ off: Int) -> UInt32 {
                data.withUnsafeBytes { raw in
                    raw.load(fromByteOffset: off, as: UInt32.self).littleEndian
                }
            }
            // DDS_HEADER fields
            let height   = u32(12)
            let width    = u32(16)
            let headerPitch = u32(20)              // dwPitchOrLinearSize — may be bogus
            let mipCount = max(1, u32(28))
            // FOURCC at offset 84-87
            let fourcc   = data.subdata(in: 84..<88)
            let isDX10   = fourcc == Data([0x44, 0x58, 0x31, 0x30])
            guard isDX10 else {
                if !shouldSkipCaptureDDSFailure(path: path) {
                    pbrLog("[Q3-PBR-SWIFT] capture-dds non-DX10 path=\(path)")
                }
                return nil
            }
            // DDS_HEADER_DXT10 at offset 128
            let dxgiFormat = u32(128)
            let pixelFormat: MTLPixelFormat
            let bytesPerPixel: Int
            switch dxgiFormat {
            case 28: // DXGI_FORMAT_R8G8B8A8_UNORM
                pixelFormat = .rgba8Unorm
                bytesPerPixel = 4
            case 87: // DXGI_FORMAT_B8G8R8A8_UNORM
                pixelFormat = .bgra8Unorm
                bytesPerPixel = 4
            default:
                if !shouldSkipCaptureDDSFailure(path: path) {
                    pbrLog("[Q3-PBR-SWIFT] capture-dds unsupported dxgi=\(dxgiFormat) path=\(path)")
                }
                return nil
            }
            let computedRowBytes = Int(width) * bytesPerPixel
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: pixelFormat,
                width: Int(width), height: Int(height),
                mipmapped: mipCount > 1)
            desc.mipmapLevelCount = Int(mipCount)
            desc.usage = [.shaderRead]
            desc.storageMode = .shared
            guard let tex = device.makeTexture(descriptor: desc) else {
                pbrLog("[Q3-PBR-SWIFT] capture-dds MTLTexture alloc FAILED path=\(path)")
                return nil
            }
            tex.label = label
            // Header is 4 (magic) + 124 (DDS_HEADER) + 20 (DX10 ext) = 148
            var cursor = 148
            var mipW = Int(width)
            var mipH = Int(height)
            for level in 0..<Int(mipCount) {
                let bytesPerRow = mipW * bytesPerPixel
                let size = bytesPerRow * mipH
                guard cursor + size <= data.count else {
                    pbrLog("[Q3-PBR-SWIFT] capture-dds short read at mip=\(level) need=\(size) avail=\(data.count - cursor) path=\(path)")
                    return nil
                }
                data.withUnsafeBytes { raw in
                    let base = raw.baseAddress!.advanced(by: cursor)
                    tex.replace(region: MTLRegionMake2D(0, 0, mipW, mipH),
                                mipmapLevel: level,
                                withBytes: base,
                                bytesPerRow: bytesPerRow)
                }
                cursor += size
                mipW = max(1, mipW / 2)
                mipH = max(1, mipH / 2)
            }
            pbrLog("[Q3-PBR-SWIFT] capture-dds tolerant-load OK \(width)x\(height) mips=\(mipCount) dxgi=\(dxgiFormat) headerPitch=\(headerPitch) computedRowBytes=\(computedRowBytes) path=\(path)")
            return tex
        }

        /// Name-keyed atlas albedo loader for the indirect-name entity path.
        /// `pbrAlbedoTexture(for: handle)` is handle-keyed and would re-load the
        /// envmap DDS once per pickup-handle. Many pickups share the same
        /// underlying envmap atlas (yellow health, plasma ammo, machine gun
        /// ammo, etc. all resolve to `textures/effects/envmapyel`), so a
        /// name-keyed cache loads each atlas DDS once and reuses it.
        private var entityAtlasAlbedoCache: [String: MTLTexture] = [:]
        /// Marks textures loaded via the tolerant capture-format reader.
        /// Capture-format DDS files (RTX-Remix `capture_textures_dds/<HASH>.dds`)
        /// are single-frame snapshots of one envmap moment, NOT 4×4 sprite
        /// atlases — even when the parent hash's `remixConstants` carries
        /// sprite_sheet_cols/rows/fps. Treating a single-frame capture as a
        /// 4×4 atlas slices a coherent envmap into 16 disjoint 16×16 tiles
        /// and cycles them, which reads as "scrambled chrome" in-game. The
        /// caller (`packEntityAtlas`) checks this flag and forces
        /// `spriteAtlasParams = (0,0,0,0)` when set, so the MSL atlas remap
        /// stays inactive and the texture samples like a normal envmap.
        /// Real ingested atlases (`assets/ingested/*_albedo_animation.a.rtex.dds`)
        /// load via MTKTextureLoader and stay at isCaptureFormat=false.
        private var entityAtlasIsCaptureCache: [String: Bool] = [:]
        private var entityAtlasAlbedoMissed: Set<String> = []

        private func pbrSpriteAtlasParams(for handle: UInt32, atlasTime: Float,
                                          logEnabled: Bool = true) -> SIMD4<Float> {
            if let mat = pbrMaterialInfo(for: handle) {
                if mat.spriteCols > 0 {
                    let rows = mat.spriteRows > 0 ? mat.spriteRows : 1
                    let fps = mat.spriteFps > 0 ? mat.spriteFps : 1
                    let params = SIMD4<Float>(
                        Float(mat.spriteCols),
                        Float(rows),
                        fps,
                        atlasTime)
                    if logEnabled, let cName = Q3MetalRenderer_GetTextureName(handle) {
                        let name = String(cString: cName)
                        if !Self.loggedWorldAtlasNames.contains(name) {
                            Self.loggedWorldAtlasNames.insert(name)
                            pbrLog("[Q3-PBR-SWIFT] world-atlas params handle=\(handle) name='\(name)' cols=\(mat.spriteCols) rows=\(rows) fps=\(fps) atlasTime=\(String(format: "%.3f", atlasTime))")
                        }
                    }
                    return params
                }
            }

            guard let cName = Q3MetalRenderer_GetTextureName(handle) else {
                return SIMD4<Float>(0, 0, 0, 0)
            }
            let name = String(cString: cName).lowercased()

            // q3dm17 launchpad diamond's Remix DDS is a horizontal 6-frame
            // animation atlas (12288×2048 = 6 × 2048²), but the current bridge
            // JSON lacks remixConstants.sprite_sheet_* for this material. If we
            // sample the whole DDS as a normal texture the ramp shows all frames
            // side-by-side and looks horizontally squashed. Keep this targeted
            // fallback local until the generated material JSON carries metadata.
            if name.contains("textures/sfx/launchpad_diamond") {
                if logEnabled, !Self.loggedWorldAtlasNames.contains(name) {
                    Self.loggedWorldAtlasNames.insert(name)
                    pbrLog("[Q3-PBR-SWIFT] world-atlas targeted params handle=\(handle) name='\(name)' cols=6 rows=1 fps=6 atlasTime=\(String(format: "%.3f", atlasTime))")
                }
                return SIMD4<Float>(6, 1, 6, atlasTime)
            }

            return SIMD4<Float>(0, 0, 0, 0)
        }

        private func entityAtlasAlbedoTexture(name: String) -> (texture: MTLTexture?, isCaptureFormat: Bool) {
            if let cached = entityAtlasAlbedoCache[name] {
                return (cached, entityAtlasIsCaptureCache[name] ?? false)
            }
            if entityAtlasAlbedoMissed.contains(name) { return (nil, false) }
            guard let matPtr = name.withCString({ Q3MetalRenderer_GetPBRMaterialByName($0) }) else {
                entityAtlasAlbedoMissed.insert(name); return (nil, false)
            }
            let mat = matPtr.pointee
            guard let albedoCStr = mat.albedo else {
                pbrLog("[Q3-PBR-SWIFT] entity-atlas no-albedo name='\(name)' (material found but albedo slot is NULL)")
                entityAtlasAlbedoMissed.insert(name); return (nil, false)
            }
            let path = String(cString: albedoCStr)
            guard let loader = pbrTextureLoader else {
                entityAtlasAlbedoMissed.insert(name); return (nil, false)
            }
            // File-existence diagnostic — confirms the atlas DDS is in the
            // app bundle (vs. an asset-pipeline gap that the JSON points at
            // a non-shipped file). Cheap once per name.
            let exists = FileManager.default.fileExists(atPath: path)
            var fileSize: Int = -1
            if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
               let s = attrs[.size] as? Int {
                fileSize = s
            }
            pbrLog("[Q3-PBR-SWIFT] trying-entity-atlas name='\(name)' path=\(path) exists=\(exists) size=\(fileSize)")
            guard exists else {
                pbrLog("[Q3-PBR-SWIFT] entity-atlas FILE NOT IN BUNDLE name='\(name)' path=\(path)")
                entityAtlasAlbedoMissed.insert(name); return (nil, false)
            }
            let url = URL(fileURLWithPath: path)
            let opts: [MTKTextureLoader.Option: Any] = [
                .SRGB:                NSNumber(value: true),
                .textureUsage:        NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
                .textureStorageMode:  NSNumber(value: MTLStorageMode.private.rawValue),
                .generateMipmaps:     NSNumber(value: false),
            ]
            do {
                let tex = try loader.newTexture(URL: url, options: opts)
                tex.label = "Q3.pbr.entity_atlas.\(name)"
                entityAtlasAlbedoCache[name] = tex
                entityAtlasIsCaptureCache[name] = false
                pbrLog("[Q3-PBR-SWIFT] loaded entity-atlas (ingested) name='\(name)' size=\(tex.width)x\(tex.height) path=\(path)")
                return (tex, false)
            } catch {
                // MTKTextureLoader rejected the file — most commonly the
                // RTX-Remix capture-format DDS with bogus pitch metadata.
                // Try the tolerant in-process reader before giving up.
                pbrLog("[Q3-PBR-SWIFT] MTKLoader rejected name='\(name)' err=\(error.localizedDescription) — trying capture-format reader")
                if let tex = loadCaptureFormatDDS(path: path, label: "Q3.pbr.entity_atlas.\(name)") {
                    entityAtlasAlbedoCache[name] = tex
                    entityAtlasIsCaptureCache[name] = true
                    pbrLog("[Q3-PBR-SWIFT] loaded entity-atlas (capture-format) name='\(name)' size=\(tex.width)x\(tex.height) path=\(path)")
                    return (tex, true)
                }
                pbrLog("[Q3-PBR-SWIFT] entity-atlas DDS load FAILED name='\(name)' err=\(error.localizedDescription) path=\(path)")
                entityAtlasAlbedoMissed.insert(name)
                return (nil, false)
            }
        }

        private func pbrAlbedoTexture(for handle: UInt32) -> MTLTexture? {
            if let cached = pbrAlbedoCache[handle] { return cached }
            if pbrTriedAndMissed.contains(handle) { return nil }
            guard let matPtr = Q3MetalRenderer_GetPBRMaterial(handle) else {
                pbrTriedAndMissed.insert(handle); return nil
            }
            let mat = matPtr.pointee
            // Phase 2 sprite-sheet atlas: load the full DDS atlas as a
            // normal albedo texture. The MSL world fragment sub-rect-
            // samples the current frame using drawUniforms.spriteAtlasParams
            // (cols, rows, fps) which is written by the world draw loop
            // when the bound handle has atlas metadata. One log line per
            // atlas-bound material so we can confirm the path is hot.
            if mat.sprite_cols > 0 && mat.sprite_rows > 0 {
                pbrLog("[Q3-PBR-SWIFT] atlas-load handle=\(handle) name='\(textureNameForLog(handle))' cols=\(mat.sprite_cols) rows=\(mat.sprite_rows) fps=\(mat.sprite_fps)")
            }
            guard let albedoCStr = mat.albedo else {
                func hasNonEmptyPath(_ ptr: UnsafePointer<CChar>?) -> Bool {
                    guard let ptr else { return false }
                    return ptr.pointee != 0
                }
                let hasSidecarPayload =
                    hasNonEmptyPath(mat.normal) ||
                    hasNonEmptyPath(mat.roughness) ||
                    hasNonEmptyPath(mat.metallic) ||
                    hasNonEmptyPath(mat.emissive) ||
                    hasNonEmptyPath(mat.height)
                if hasSidecarPayload {
                    pbrLog("[Q3-PBR-SWIFT] no-albedo handle=\(handle) name='\(textureNameForLog(handle))' (material found but albedo slot is NULL)")
                }
                pbrTriedAndMissed.insert(handle); return nil
            }
            let path = String(cString: albedoCStr)
            guard let loader = pbrTextureLoader else {
                pbrLog("[Q3-PBR-SWIFT] no-loader handle=\(handle) path=\(path)")
                pbrTriedAndMissed.insert(handle); return nil
            }
            if shouldSkipCaptureDDSFailure(path: path) {
                pbrTriedAndMissed.insert(handle)
                return nil
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
                // Some Remix capture DDS files are valid R8G8B8A8 DX10 DDS,
                // but MTKTextureLoader rejects them because the header pitch
                // metadata is non-standard. The entity-atlas path already has
                // a tolerant reader for these files; use it here too so world
                // and item materials do not fall back to magenta/classic only
                // just because the Apple loader refused the capture wrapper.
                pbrLog("[Q3-PBR-SWIFT] MTKLoader rejected albedo handle=\(handle) err=\(error.localizedDescription) — trying capture-format reader path=\(path)")
                if let tex = loadCaptureFormatDDS(path: path, label: "Q3.pbr.albedo.h\(handle).capture") {
                    pbrAlbedoCache[handle] = tex
                    pbrLog("[Q3-PBR-SWIFT] loaded albedo (capture-format) handle=\(handle) size=\(tex.width)x\(tex.height) path=\(path)")
                    return tex
                }
                if !shouldSkipCaptureDDSFailure(path: path) {
                    pbrLog("[Q3-PBR-SWIFT] DDS load FAILED handle=\(handle) err=\(error.localizedDescription) path=\(path)")
                }
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
        private func pbrNormalTexture(for handle: UInt32, allowGenericFallback: Bool = true) -> MTLTexture? {
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
                if !allowGenericFallback {
                    // World surfaces should not poison the normal-cache miss set
                    // for entities using the same handle; they simply render
                    // without a normal map when Remix did not provide one.
                    pbrNormalTried.remove(handle)
                    return nil
                }
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
            // Skybox faces are packed in pk3 files, not loose
            // Bundle.main/baseq3/env files. Always probe through the Q3 FS
            // bridge. If the live cvar is a bad/archived non-env stem like
            // "full", fall back to stock env/space1 so metallic weapons get
            // a real sky image instead of the flat procedural grey cube.
            var nameBuf = [CChar](repeating: 0, count: 128)
            let gotName = nameBuf.withUnsafeMutableBufferPointer { p -> Int32 in
                Q3_PBRIBLSkyboxName(p.baseAddress, Int32(p.count))
            }
            guard gotName != 0 else { return nil }
            let liveStem = String(cString: nameBuf).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !liveStem.isEmpty else { return nil }

            var candidates: [String] = []
            func addCandidate(_ raw: String) {
                let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !s.isEmpty, s != "-" else { return }
                if !candidates.contains(s) { candidates.append(s) }
            }
            addCandidate(liveStem)
            if !liveStem.hasPrefix("env/") { addCandidate("env/\(liveStem)") }
            addCandidate("env/space1")

            let suffixes = ["_rt", "_lf", "_up", "_dn", "_ft", "_bk"]
            for (candidateIndex, stem) in candidates.enumerated() {
                var faceData: [(rgba: [UInt8], width: Int, height: Int)] = []
                var missingFace: String? = nil
                for (i, suffix) in suffixes.enumerated() {
                    let faceStem = "\(stem)\(suffix)"
                    guard let face = loadSkyboxFace(stem: faceStem) else {
                        missingFace = "env probe \(faceStem).tga/.jpg face \(i)/6"
                        break
                    }
                    faceData.append(face)
                }
                if let missingFace {
                    pbrLog("[Q3-PBR-IBL] map skybox FS read MISS stem='\(stem)' live='\(liveStem)' (\(missingFace))")
                    continue
                }
                guard faceData.count == 6 else { continue }

                let baseSize = faceData[0].width
                guard baseSize > 0, baseSize == faceData[0].height else {
                    pbrLog("[Q3-PBR-IBL] map skybox invalid face size stem='\(stem)' — trying next candidate")
                    continue
                }
                var sizeMismatch = false
                for f in faceData where f.width != baseSize || f.height != baseSize {
                    sizeMismatch = true
                    break
                }
                if sizeMismatch {
                    pbrLog("[Q3-PBR-IBL] map skybox face size mismatch stem='\(stem)' — trying next candidate")
                    continue
                }

                guard let device = self.commandQueue?.device else { return nil }
                let desc = MTLTextureDescriptor.textureCubeDescriptor(
                    pixelFormat: .rgba8Unorm,
                    size: baseSize,
                    mipmapped: true
                )
                desc.usage = [.shaderRead]
                desc.storageMode = .shared
                guard let cube = device.makeTexture(descriptor: desc) else {
                    pbrLog("[Q3-PBR-IBL] map skybox cube alloc FAILED stem='\(stem)' size=\(baseSize)")
                    continue
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
                if let queue = device.makeCommandQueue(),
                   let cb = queue.makeCommandBuffer(),
                   let blit = cb.makeBlitCommandEncoder() {
                    blit.generateMipmaps(for: cube)
                    blit.endEncoding()
                    cb.commit()
                    cb.waitUntilCompleted()
                }
                let fallbackNote = candidateIndex == 0 ? "" : " fallbackFrom='\(liveStem)'"
                NSLog("[Q3-PBR-IBL] map skybox envCube ready stem=%@ %@%dx%dx6 mips=%d",
                      stem, fallbackNote, baseSize, baseSize, cube.mipmapLevelCount)
                pbrLog("[Q3-PBR-IBL] map skybox envCube ready stem=\(stem)\(fallbackNote) \(baseSize)x\(baseSize)x6 mips=\(cube.mipmapLevelCount)")
                return cube
            }
            return nil
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
            // Suppress the invalidate-on-change when the new stem is one
            // we've already proven can't load from disk — otherwise the
            // cached procedural cube gets thrown away every frame and
            // tryBuildMapSkyboxCube re-walks 6 FS_ReadFile calls just to
            // fall back to procedural again.
            let stemKnownBad = (currentStem.map { pbrEnvCubeFailedStems.contains($0) } ?? false)
            if pbrEnvCube != nil, pbrEnvCubeStem != currentStem, !stemKnownBad {
                pbrLog("[Q3-PBR-IBL] skybox stem changed (\(pbrEnvCubeStem ?? "<nil>") → \(currentStem ?? "<nil>")) — invalidating cache")
                pbrEnvCube = nil
                pbrEnvCubeAttempted = false
            }
            // 2026-06-10: invalidate the cached procedural cube when the
            // `r_pbr_envcube_grey` cvar has changed since we last built.
            // Only applies to procedural cubes (stem sentinel "<procedural>"
            // — map-skybox cubes are colour-independent of the cvar).
            // Tolerance 0.001 so float rounding from cvar string parse
            // doesn't trigger spurious rebuilds.
            if pbrEnvCube != nil, pbrEnvCubeStem == "<procedural>" {
                let liveGrey = Q3_PBREnvCubeGrey()
                if abs(liveGrey - pbrEnvCubeGreyBuilt) > 0.001 {
                    pbrLog("[Q3-PBR-IBL] envcube grey changed (\(String(format: "%.3f", pbrEnvCubeGreyBuilt)) → \(String(format: "%.3f", liveGrey))) — invalidating procedural cube")
                    pbrEnvCube = nil
                    pbrEnvCubeAttempted = false
                }
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
            // Map cube build failed for currentStem. Remember it so the
            // next stem-change check above doesn't invalidate the cached
            // procedural cube on the very next frame.
            if let s = currentStem, !s.isEmpty {
                pbrEnvCubeFailedStems.insert(s)
            }

            guard let device = self.commandQueue?.device else { return nil }

            // 2026-06-09: raised 64 → 256 for sharper procedural IBL
            // reflections. Memory cost: 256² × 6 × 4 bytes × 1.33 (mips) ≈
            // 2.1 MB resident per cube (was ~130 KB). Acceptable on iPad M4.
            // Sky-driven cubes (when env/ assets ship) keep their native size
            // via tryBuildMapSkyboxCube — this only affects the fallback.
            let size = 256
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
            cube.label = "Q3.pbr.envcube.neutral_grey"

            // 2026-06-10: replaced warm sky-gradient (skyTop/horizon/ground)
            // with neutral dark grey (0.08 linear, RGB=20). Original procedural
            // was contributing a strong orange cast to every world surface via
            // the horizon=(0.85,0.78,0.65) term; visible as "warm tint
            // dominates" in the raster-vs-RT q3dm11 comparison
            // (docs/2026-06-10-rt-mode-verified.md). 0.08 is low-energy enough
            // that diffuse IBL fill at default `r_pbr_world_ambient_boost=0.42`
            // contributes ~0.034 — lifts pure black without overpowering the
            // BSP lightmap. If shadow side still reads too dark, bump
            // `r_pbr_world_ambient_boost 0.6` at runtime. Real map skyboxes
            // (when env/ assets ship) still load via tryBuildMapSkyboxCube
            // above; this only affects the procedural fallback.
            // 2026-06-10: cube grey driven by `r_pbr_envcube_grey` cvar
            // (default 0.08). The accessor clamps to [0..1]; we then
            // round-and-clamp to UInt8 for the 8-bit cube faces. We
            // remember the float value used (`pbrEnvCubeGreyBuilt`) so
            // the invalidate-on-cvar-change check upstream can compare
            // against the next call and force a rebuild.
            let greyFloat = Q3_PBREnvCubeGrey()
            pbrEnvCubeGreyBuilt = greyFloat
            let greyValue: UInt8 = UInt8(max(0, min(255, Int((greyFloat * 255.0).rounded()))))
            let bytesPerRow = size * 4
            let bytesPerImage = bytesPerRow * size
            var faceBuf = [UInt8](repeating: greyValue, count: bytesPerImage)
            // Alpha channel = 255 (every 4th byte).
            for i in stride(from: 3, to: faceBuf.count, by: 4) {
                faceBuf[i] = 255
            }
            let region = MTLRegionMake2D(0, 0, size, size)
            for face in 0..<6 {
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
            let requestedGrey = Q3_PBREnvCubeGreyRequested()
            NSLog("[Q3-PBR-IBL] procedural envCube ready %dx%dx6 mips=%d requestedGrey=%.3f effectiveGrey=%.3f",
                  size, size, cube.mipmapLevelCount, requestedGrey, greyFloat)
            pbrLog("[Q3-PBR-IBL] procedural envCube ready \(size)x\(size)x6 mips=\(cube.mipmapLevelCount) requestedGrey=\(String(format: "%.3f", requestedGrey)) effectiveGrey=\(String(format: "%.3f", greyFloat))")
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

        /// 1×1 flat tangent-space normal (R=128, G=128, B=255, A=255 ≈
        /// (0, 0, 1)). Bound at fragment slot 1 on entity draws when no
        /// per-material normal is available, to satisfy the Q3.entity
        /// pipeline shader's `normalTexture` argument. Without this fallback
        /// Metal's API validation flagged a "missing fragment texture at
        /// index 1" warning on 57 entity draws/frame, and the fragment was
        /// reading from undefined GPU memory for tcGen-environment health
        /// pickups / quad shells / chrome FX. The MSL shader still does
        /// `is_null_texture(normalMap)` checks in some paths — this default
        /// is a no-op for those (perturbation magnitude 0 from a flat
        /// normal) while keeping the binding valid for the unprotected
        /// codepath.
        private var pbrFlatNormalDefaultTex: MTLTexture?
        private var pbrFlatNormalDefaultAttempted = false
        private func pbrFlatNormalDefault() -> MTLTexture? {
            if let t = pbrFlatNormalDefaultTex { return t }
            if pbrFlatNormalDefaultAttempted { return nil }
            pbrFlatNormalDefaultAttempted = true
            guard let device = self.commandQueue?.device else { return nil }
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba8Unorm,
                width: 1, height: 1, mipmapped: false
            )
            desc.usage = [.shaderRead]
            desc.storageMode = .shared
            guard let tex = device.makeTexture(descriptor: desc) else { return nil }
            tex.label = "Q3.pbr.normal.flat_default"
            let pixel: [UInt8] = [128, 128, 255, 255]
            pixel.withUnsafeBytes { bytes in
                tex.replace(region: MTLRegionMake2D(0, 0, 1, 1),
                            mipmapLevel: 0,
                            withBytes: bytes.baseAddress!,
                            bytesPerRow: 4)
            }
            pbrFlatNormalDefaultTex = tex
            pbrLog("[Q3-PBR-SWIFT] flat-normal default 1x1=(128,128,255) ready")
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
            if mat.roughness_constant >= 0.0 {
                let v = max(0.0, min(1.0, mat.roughness_constant))
                if let tex = makeConstantR8Texture(value: v, label: "Q3.pbr.roughness.const_\(v).h\(handle)") {
                    pbrRoughnessCache[handle] = tex
                    pbrLog("[Q3-PBR-SWIFT] roughness CONSTANT fallback handle=\(handle) value=\(v)")
                    return tex
                }
            }
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
            if mat.metallic_constant >= 0.0 {
                let v = max(0.0, min(1.0, mat.metallic_constant))
                if let tex = makeConstantR8Texture(value: v, label: "Q3.pbr.metallic.const_\(v).h\(handle)") {
                    pbrMetallicCache[handle] = tex
                    pbrLog("[Q3-PBR-SWIFT] metallic CONSTANT fallback handle=\(handle) value=\(v)")
                    return tex
                }
            }
            if mat.albedo != nil || mat.normal != nil {
                if let fallback = pbrMetallicDefault() {
                    pbrMetallicCache[handle] = fallback
                    pbrLog("[Q3-PBR-SWIFT] metallic DEFAULT fallback handle=\(handle) value=0.50")
                    return fallback
                }
            }
            return nil
        }

        // MARK: - Emissive

        /// 1×1 RGBA8 (0,0,0,255) zero-emission default. Sampled as (0,0,0,1)
        /// → emissive contribution = 0 (vector add no-op). Bound at fragment
        /// slot 6 on every world/entity draw so the Q3.world / Q3.entity
        /// pipelines never see a nil `emissiveTexture` arg.
        private var pbrEmissiveDefaultTex: MTLTexture?
        private var pbrEmissiveDefaultAttempted = false
        private func pbrEmissiveDefault() -> MTLTexture? {
            if let t = pbrEmissiveDefaultTex { return t }
            if pbrEmissiveDefaultAttempted { return nil }
            pbrEmissiveDefaultAttempted = true
            guard let device = self.commandQueue?.device else { return nil }
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba8Unorm,
                width: 1, height: 1, mipmapped: false
            )
            desc.usage = [.shaderRead]
            desc.storageMode = .shared
            guard let tex = device.makeTexture(descriptor: desc) else { return nil }
            tex.label = "Q3.pbr.emissive.default_zero"
            let pixel: [UInt8] = [0, 0, 0, 255]
            pixel.withUnsafeBytes { bytes in
                tex.replace(region: MTLRegionMake2D(0, 0, 1, 1),
                            mipmapLevel: 0,
                            withBytes: bytes.baseAddress!,
                            bytesPerRow: 4)
            }
            pbrEmissiveDefaultTex = tex
            pbrLog("[Q3-PBR-SWIFT] emissive default 1x1=(0,0,0) ready")
            return tex
        }

        /// Handle-keyed emissive DDS loader mirroring normal/roughness/
        /// metallic. RTX-Remix ingested emissive textures live in
        /// `assets/ingested/<HASH>_emissive*.e.rtex.dds`. 122 such files
        /// ship today; before this loader was wired, none of them were
        /// reaching the GPU. Returns nil when the material has no emissive
        /// DDS — the caller (bind site) falls back to `pbrEmissiveDefault()`
        /// (1×1 black) so the pipeline slot stays valid.
        private var pbrEmissiveCache: [UInt32: MTLTexture] = [:]
        private var pbrEmissiveTried: Set<UInt32> = []
        private func pbrEmissiveTexture(for handle: UInt32) -> MTLTexture? {
            if let cached = pbrEmissiveCache[handle] { return cached }
            if pbrEmissiveTried.contains(handle) { return nil }
            pbrEmissiveTried.insert(handle)
            guard let matPtr = Q3MetalRenderer_GetPBRMaterial(handle) else { return nil }
            let mat = matPtr.pointee
            guard let eCStr = mat.emissive else { return nil }
            let path = String(cString: eCStr)
            // Data-quality guard: materials.json has ~85 entries (audited
            // 2026-06-09) whose `emissive` field points at the material's
            // own albedo/normal/etc. DDS rather than an `*_emissive*` file.
            // Loading those as emissive multiplies the albedo image into
            // the glow term and blows surfaces out. C-side parser +
            // inheritance are correct — this is a JSON authoring slip.
            // Filter at the load boundary: accept only paths containing
            // "emissive" OR ending in the canonical `.e.rtex.dds` suffix.
            let lower = path.lowercased()
            let canonical = lower.contains("emissive") || lower.hasSuffix(".e.rtex.dds")
            if !canonical {
                pbrLog("[Q3-PBR-SWIFT] suspicious emissive path handle=\(handle) path=\(path) reason=not_emissive_or_.e.rtex.dds — skipping load (default zero will bind)")
                pbrEmissiveTried.insert(handle)
                return nil
            }
            guard let loader = pbrTextureLoader else { return nil }
            pbrLog("[Q3-PBR-SWIFT] trying-emissive handle=\(handle) path=\(path)")
            let url = URL(fileURLWithPath: path)
            // SRGB=true: emissive textures encode color in sRGB. Mipmaps off
            // (DDS ships its own) and private storage matches the other
            // PBR loaders. textureUsage shaderRead only.
            let opts: [MTKTextureLoader.Option: Any] = [
                .SRGB:                NSNumber(value: true),
                .textureUsage:        NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
                .textureStorageMode:  NSNumber(value: MTLStorageMode.private.rawValue),
                .generateMipmaps:     NSNumber(value: false),
            ]
            do {
                let tex = try loader.newTexture(URL: url, options: opts)
                tex.label = "Q3.pbr.emissive.h\(handle)"
                pbrEmissiveCache[handle] = tex
                pbrLog("[Q3-PBR-SWIFT] loaded emissive handle=\(handle) size=\(tex.width)x\(tex.height) path=\(path)")
                return tex
            } catch {
                pbrLog("[Q3-PBR-SWIFT] emissive DDS load FAILED handle=\(handle) err=\(error.localizedDescription) path=\(path)")
                return nil
            }
        }

        /// Height (parallax) map loader — mirrors pbrEmissiveTexture.
        /// Returns nil when the material ships no height DDS; callers bind
        /// pbrEmissiveDefault() (1×1 black ⇒ flat) and leave
        /// parallaxParams.x at 0 so the MSL parallax block is skipped.
        private var pbrHeightCache: [UInt32: MTLTexture] = [:]
        private var pbrHeightTried: Set<UInt32> = []
        private func pbrHeightTexture(for handle: UInt32) -> MTLTexture? {
            if let cached = pbrHeightCache[handle] { return cached }
            if pbrHeightTried.contains(handle) { return nil }
            pbrHeightTried.insert(handle)
            guard let matPtr = Q3MetalRenderer_GetPBRMaterial(handle) else { return nil }
            let mat = matPtr.pointee
            guard let hCStr = mat.height else { return nil }
            let path = String(cString: hCStr)
            let lower = path.lowercased()
            // Canonical-path guard, same rationale as emissive: only accept
            // real height channels (`*_height*` / `.h.rtex.dds`).
            guard lower.contains("height") || lower.hasSuffix(".h.rtex.dds") else {
                pbrLog("[Q3-PBR-SWIFT] suspicious height path handle=\(handle) path=\(path) — skipping")
                return nil
            }
            guard let loader = pbrTextureLoader else { return nil }
            let opts: [MTKTextureLoader.Option: Any] = [
                .SRGB:                NSNumber(value: false),   // height is linear data
                .textureUsage:        NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
                .textureStorageMode:  NSNumber(value: MTLStorageMode.private.rawValue),
                .generateMipmaps:     NSNumber(value: false),
            ]
            do {
                let tex = try loader.newTexture(URL: URL(fileURLWithPath: path), options: opts)
                tex.label = "Q3.pbr.height.h\(handle)"
                pbrHeightCache[handle] = tex
                pbrLog("[Q3-PBR-SWIFT] loaded height handle=\(handle) size=\(tex.width)x\(tex.height) path=\(path)")
                return tex
            } catch {
                pbrLog("[Q3-PBR-SWIFT] height DDS load FAILED handle=\(handle) err=\(error.localizedDescription) path=\(path)")
                return nil
            }
        }

        private var loggedParallaxHandles: Set<UInt32> = []
        private func logParallaxBind(handle: UInt32,
                                     stage: Q3MetalWorldStage,
                                     selection: WorldTextureSelection,
                                     heightTex: MTLTexture?,
                                     scale: Float,
                                     site: String) {
            guard loggedParallaxHandles.insert(handle).inserted else { return }
            let name = textureNameForLog(handle)
            let heightState = (heightTex == nil) ? "nil" : "yes"
            pbrLog("[Q3-PARALLAX] site=\(site) handle=\(handle) name='\(name)' useWorldPBR=\(selection.useWorldPBR ? 1 : 0) heightTex=\(heightState) scale=\(scale) tcGen=\(stage.tcGen) blendMode=\(stage.blendMode) classicFX=\(selection.classicFX ? 1 : 0)")
        }

        /// Pack (color_r, color_g, color_b, intensity) for the MSL fragment.
        /// Returns (1,1,1, intensity) when the material doesn't ship its
        /// own color tint, so the MSL multiply is a no-op against the
        /// sampled emissive texel. When the material has no emissive at
        /// all (default texture bound), intensity stays 0 → no contribution.
        ///
        /// Emits a one-shot `emissive-params` diag per handle with non-NULL
        /// emissive path so we can correlate "should glow" surfaces back to
        /// their intensity / color tint. Useful when a known-emissive
        /// surface isn't glowing — the log will show whether intensity is
        /// 0 (data issue) or the texture is just missing.
        private var loggedEmissiveParamHandles: Set<UInt32> = []
        private var loggedHighEmissiveParamHandles: Set<UInt32> = []
        private func emissiveParamsForPBRMaterial(handle: UInt32) -> SIMD4<Float> {
            guard let mat = pbrMaterialInfo(for: handle) else {
                return SIMD4(1, 1, 1, 0)
            }
            let hasEmissive = (mat.emissive != nil)
            // 2026-06-10: ceiling is now tunable via `r_pbr_emissive_intensity_max`
            // cvar (default 3.0). Hard-coded 4.0 was the historical default
            // back when entity-side emissive was silently broken (params
            // mutation happened post-upload). Once today's ordering fix
            // wired emissive correctly on entity draws, 4.0 turned chrome/
            // envmap entities (quad shell, health/armor pickups, viewmodel
            // hot-bits) into white blobs because BGRA8 saturates above
            // ~1.0 luminance. q3dm17 Catalyst sweeps on 2026-06-14 showed
            // 3.0 restores the authored space-map emissive punch without
            // returning to the old all-white 4.0/8.0 look. materials.json values
            // range up to 982 (RTX Remix HDR authoring); they all clamp
            // down to the ceiling. Real fix is `.rgba16Float` backbuffer
            // + tone mapping — deferred.
            let rawIntensity: Float = hasEmissive ? mat.emissiveIntensity : 0.0
            let intensity: Float = min(rawIntensity, Q3_PBREmissiveIntensityMax())
            if hasEmissive && !loggedEmissiveParamHandles.contains(handle) {
                loggedEmissiveParamHandles.insert(handle)
                pbrLog("[Q3-PBR-SWIFT] emissive-params handle=\(handle) intensity=\(intensity) raw=\(rawIntensity) color=(\(mat.emissiveColor.x),\(mat.emissiveColor.y),\(mat.emissiveColor.z)) hasColor=\(mat.hasEmissiveColor ? 1 : 0)")
            }
            if hasEmissive && rawIntensity > 8.0 && !loggedHighEmissiveParamHandles.contains(handle) {
                loggedHighEmissiveParamHandles.insert(handle)
                let name = textureNameForLog(handle)
                let ePath = mat.emissive ?? "<nil>"
                pbrLog("[Q3-PBR-SWIFT] high-emissive handle=\(handle) name='\(name)' raw=\(rawIntensity) clamped=\(intensity) emissive='\(ePath)'")
            }
            if mat.hasEmissiveColor {
                return SIMD4(mat.emissiveColor.x, mat.emissiveColor.y, mat.emissiveColor.z, intensity)
            }
            return SIMD4(1, 1, 1, intensity)
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

        private static let maxInflightFrames = 3
        private let frameInflightSemaphore = DispatchSemaphore(value: Coordinator.maxInflightFrames)
        private var nextFrameSlot = 0
        private var didLogMetalSync = false
        private var vertexBuffers: [MTLBuffer?] = Array(repeating: nil, count: Coordinator.maxInflightFrames)
        private var vertexBufferCapacities: [Int] = Array(repeating: 0, count: Coordinator.maxInflightFrames)
        private var worldVertexBuffer: MTLBuffer?
        private var worldIndexBuffer: MTLBuffer?
        private var cachedWorldGeneration: UInt32 = 0
        private var entityVertexBuffers: [MTLBuffer?] = Array(repeating: nil, count: Coordinator.maxInflightFrames)
        private var entityVertexBufferCapacities: [Int] = Array(repeating: 0, count: Coordinator.maxInflightFrames)
        private var entityIndexBuffers: [MTLBuffer?] = Array(repeating: nil, count: Coordinator.maxInflightFrames)
        private var entityIndexBufferCapacities: [Int] = Array(repeating: 0, count: Coordinator.maxInflightFrames)
        private var debugFrameCounter: UInt32 = 0
        private var fogVolumeLogged = false
        private var fogOverlayInsideClipLogged: Set<Int> = []
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
                let mainScreen = view.window?.windowScene?.screen ?? UIScreen.main
                let nativeSize = mainScreen.nativeBounds.size
                target = CGSize(width: max(nativeSize.width, nativeSize.height),
                                height: min(nativeSize.width, nativeSize.height))
            } else if profile != nil {
                // matchProfile960 / matchProfile1280 — keep deterministic
                // sizes so AVI captures still bit-diff against prior runs.
                target = CGSize(width: isPad ? 1280 : 960,
                                height: isPad ? 960 : 444)
            } else {
                // Normal play. Use the same active-screen target as app boot
                // (`Q3_SetRenderResolution`). Mixing nativeBounds with the
                // MTKView callback aspect makes Q3's 2D UI projection and the
                // drawable disagree, which crops the iPad/OLED menu.
                target = Q3MetalOutputTargetSize(screen: view.window?.screen ?? UIScreen.main)
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
            // Keep "Native" literal even with RT enabled. The old safety
            // override silently forced Native+RT through the 0.75 MetalFX
            // path; on current iOS/Xcode that path can assert inside
            // MetalFX with "Motion texture must not be nil" even though
            // frame interpolation is off. RT already has its own
            // r_rt_resolution_scale knob, so do not require MetalFX here.
            let effectiveUpscaleQuality: Q3UpscaleQuality = upscaleQuality
            let upscaleActive: Bool
            let renderW: Int
            let renderH: Int
            if effectiveUpscaleQuality != .native, let device = view.device, outputW > 0, outputH > 0 {
                let rs = effectiveUpscaleQuality.renderSize(forOutput: view.drawableSize)
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
            Q3MetalRenderer_UpdateCaptureSize(Int32(outputW), Int32(outputH))

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

            frameInflightSemaphore.wait()
            var frameSemaphoreNeedsSignal = true
            func signalFrameSemaphoreIfNeeded() {
                if frameSemaphoreNeedsSignal {
                    frameSemaphoreNeedsSignal = false
                    frameInflightSemaphore.signal()
                }
            }
            defer { signalFrameSemaphoreIfNeeded() }

            let frameSlot = nextFrameSlot
            nextFrameSlot = (nextFrameSlot + 1) % Self.maxInflightFrames
            if !didLogMetalSync {
                didLogMetalSync = true
                print("[MTL_SYNC] maxInflight=\(Self.maxInflightFrames) slot=\(frameSlot)")
                pbrLog("[MTL_SYNC] maxInflight=\(Self.maxInflightFrames) slot=\(frameSlot)")
            }

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

            var currentSunShadowTexture: MTLTexture? = nil
            var currentSunShadowMatrix = matrix_identity_float4x4
            if let device = view.device,
               let sceneViewForShadow = Q3MetalRenderer_GetSceneView()?.pointee,
               let shadow = encodeSunShadowMap(commandBuffer: commandBuffer,
                                               device: device,
                                               snapshot: snapshot,
                                               sceneView: sceneViewForShadow) {
                currentSunShadowTexture = shadow.texture
                currentSunShadowMatrix = shadow.matrix
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
                // USD sun pull. ensureRTLightBuffer is cached per-map; this
                // is the raster-path callsite (RT path makes its own call at
                // line ~5004) — needed so r_rt_mix=0 also gets USD sun.
                // rtLightsCPU[0] is sorted to the slot-0 DistantLight when
                // present (kernel contract). When map has no sun the array
                // is empty or slot 0's dirType.w != 0 — we leave sunColor.w
                // at the struct default 0 so MSL falls back to hardcoded dir.
                _ = ensureRTLightBuffer(device: view.device!)
                if rtLightCount > 0,
                   let sun = rtLightsCPU.first,
                   sun.dirType.w == 0 {
                    worldUniforms.sunDir = SIMD3<Float>(sun.dirType.x, sun.dirType.y, sun.dirType.z)
                    worldUniforms.sunIntensity = sun.colorIntensity.w
                    worldUniforms.sunColor = SIMD4<Float>(sun.colorIntensity.x,
                                                          sun.colorIntensity.y,
                                                          sun.colorIntensity.z,
                                                          1.0)
                }
                if let shadowTexture = currentSunShadowTexture, worldUniforms.sunColor.w > 0.5 {
                    worldUniforms.sunShadowMatrix = currentSunShadowMatrix
                    worldUniforms.sunShadowParams = SIMD4<Float>(0.0025, 0.32, 1.0 / Float(max(shadowTexture.width, 1)), 1.0)
                }
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
                encoder.setFragmentTexture(currentSunShadowTexture, index: 8)

                // Bind dlight block at fragment buffer(2). Shared across all
                // world draws in this scene — scene-constant, not per-draw.
                Self.bindDlightBlock(snapshot: snapshot, encoder: encoder, device: view.device, index: 2, extra: currentBakedDlights())

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
                    // Atlas animation must keep running even when demo/game shaderTime stalls
                    // or snaps during warmup. Keep UV alignment unchanged; only the frame clock
                    // comes from a monotonic renderer timer and is packed in spriteAtlasParams.w.
                    let atlasTimeSeconds = Float(CACurrentMediaTime() - frameTimeOrigin)

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
                                                                      slot: frameSlot) {
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
                                               _ stageIndex: Int,
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
                        // RING-DIAG (non-cached path): one-shot per
                        // (handle, drawPass) for any stage whose texture name
                        // contains "center2trn". Confirms the draw actually
                        // reaches the encoder, and whether the alpha pipeline
                        // got chosen vs the opaque fallback (when
                        // worldAlphaPipelineState is nil).
                        do {
                            let h = stage.textureHandle
                            let key = (UInt64(h) << 8) | UInt64(drawPass & 0xFF)
                            if !loggedRingDiagKeys.contains(key),
                               let cName = Q3MetalRenderer_GetTextureName(h) {
                                let name = String(cString: cName)
                                if name.contains("center2trn") {
                                    loggedRingDiagKeys.insert(key)
                                    let pipeChosen: String
                                    if drawPass == 2 && worldAlphaPipelineState != nil { pipeChosen = "alpha" }
                                    else if drawPass == 2 { pipeChosen = "OPAQUE-FALLBACK(alphaNil)" }
                                    else if drawPass == 1 && worldFilterPipelineState != nil { pipeChosen = "filter" }
                                    else { pipeChosen = "other(\(drawPass))" }
                                    pbrLog("[RING-DIAG] center2trn nonCached pass=\(drawPass) blendMode=\(blendMode) useLightmap=\(stage.useLightmap) depthWrite=\(stage.depthWrite) alphaFunc=\(stage.alphaFunc) alphaTest=\(alphaTest) tcModCount=\(stage.tcModCount) pipelineChosen=\(pipeChosen) handle=\(h) name='\(name)'")
                                }
                            }
                        }
                        let chain = worldTcModChain(for: stage)
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
                            // rgbGen const (4) / alphaGen const stages: the C
                            // parser fills these (identity when not const), so
                            // pass them through — hardcoding (1,1,1,1) made
                            // const-tinted stages render white.
                            rgbConstColor: SIMD4(stage.rgbConstColor.0,
                                                 stage.rgbConstColor.1,
                                                 stage.rgbConstColor.2,
                                                 stage.alphaConst),
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
                            // r_world_debug_mode cvar: 0=normal, 1=base, 2=lightmap, 3=UV1, 4=vertex color.
                            // Replaces compile-time `Coordinator.worldDebugMode` constant.
                            debugMode: Float(Q3_WorldDebugMode()),
                            forceWhiteVertColor: 0,
                            alphaTestThreshold: alphaTest,
                            fogOnly: 0,
                            stageUsesLightmap: stage.useLightmap != 0 ? 1.0 : 0.0,
                            drawHasLightmapStage: drawHasLightmapStage ? 1.0 : 0.0,
                            pbrRoughness: stage.pbrRoughness,
                            pbrMetallic: stage.pbrMetallic,
                            _pad0: (draw.flags & combinedLightmapBit) != 0 ? 1.0 : 0.0
                        )
                        let materialHandle = worldOwnerMaterialHandle(for: draw, stageIndex: stageIndex, stage: stage)
                        let worldSelection = (stage.useLightmap == 0)
                            ? worldTextureSelectionForPBRDebug(handle: stage.textureHandle, fallback: baseTexture, stage: stage, materialHandle: materialHandle)
                            : WorldTextureSelection(texture: baseTexture, useWorldPBR: false, classicFX: false, atlasParams: nil, materialHandle: stage.textureHandle)
                        encoder.setFragmentTexture(worldSelection.texture, index: 0)
                        encoder.setFragmentTexture(lightmapTexture, index: 1)
                        // FX/alpha/additive/tcMod stages must stay in the authored
                        // Q3 shader path. For real world PBR, bind the material's
                        // own normal/roughness/metallic maps instead of the old
                        // global generic metal-plate normal; that was making the
                        // world read noisy/flat and unlike the Remix reference.
                        // Q3.world pipeline declares normal/roughness/metallic
                        // as required slots. Mirror the entity fix: never nil,
                        // always fall back to the 1×1 defaults so Metal
                        // validation doesn't flag "missing binding" and MSL
                        // sees defined data. envCube falls back to the
                        // procedural cube via ensurePBREnvCube().
                        let worldNormalTex = worldSelection.useWorldPBR
                            ? (pbrNormalTexture(for: worldSelection.materialHandle, allowGenericFallback: false) ?? pbrFlatNormalDefault())
                            : pbrFlatNormalDefault()
                        encoder.setFragmentTexture(worldNormalTex, index: 2)
                        if worldSelection.useWorldPBR && Q3_PBRIBLEnabled() != 0 && Q3_PBRWorldEnabled() != 0 {
                            encoder.setFragmentTexture(ensurePBREnvCube(), index: 3)
                            encoder.setFragmentSamplerState(ensurePBREnvSampler(), index: 1)
                            encoder.setFragmentTexture(pbrRoughnessTexture(for: worldSelection.materialHandle) ?? pbrRoughnessDefault(), index: 4)
                            encoder.setFragmentTexture(pbrMetallicTexture(for: worldSelection.materialHandle) ?? pbrMetallicDefault(), index: 5)
                        } else {
                            encoder.setFragmentTexture(ensurePBREnvCube(), index: 3)
                            encoder.setFragmentSamplerState(ensurePBREnvSampler(), index: 1)
                            encoder.setFragmentTexture(pbrRoughnessDefault(), index: 4)
                            encoder.setFragmentTexture(pbrMetallicDefault(), index: 5)
                        }
                        // Emissive slot @ 6 — always bound (default 1×1 zero
                        // when material ships no emissive DDS). drawUniforms.
                        // emissiveParams carries (color, intensity); MSL
                        // gates the sample + add on intensity > 0.
                        let worldEmissiveTex = pbrEmissiveTexture(for: worldSelection.materialHandle) ?? pbrEmissiveDefault()
                        encoder.setFragmentTexture(worldEmissiveTex, index: 6)
                        drawUniforms.emissiveParams = emissiveParamsForPBRMaterial(handle: worldSelection.materialHandle)
                        // Height/parallax slot @ 7 — only active (scale > 0)
                        // when the material ships a real height DDS. Log both
                        // the active and fallthrough paths so q3_diag shows
                        // exactly where authored height data drops out.
                        let heightTex = worldSelection.useWorldPBR ? pbrHeightTexture(for: worldSelection.materialHandle) : nil
                        let parallaxScale: Float = (heightTex == nil) ? 0.0 : Q3_PBRParallaxScale()
                        let parallaxTint: Float = (heightTex == nil || Q3_PBRParallaxTint() == 0) ? 0.0 : 1.0
                        logParallaxBind(handle: worldSelection.materialHandle,
                                        stage: stage,
                                        selection: worldSelection,
                                        heightTex: heightTex,
                                        scale: parallaxScale,
                                        site: "primary")
                        if let heightTex {
                            encoder.setFragmentTexture(heightTex, index: 7)
                            drawUniforms.parallaxParams = SIMD4<Float>(parallaxScale, 0, 0, parallaxTint)
                        } else {
                            encoder.setFragmentTexture(pbrEmissiveDefault(), index: 7)
                            drawUniforms.parallaxParams = SIMD4<Float>(0, 0, 0, 0)
                        }
                        var pbrWorldParams = SIMD4<Float>(
                            (worldSelection.useWorldPBR && Q3_PBRWorldEnabled() != 0) ? 1.0 : 0.0,
                            Q3_PBRWorldAmbientBoost(),
                            Q3_PBRWorldSpecBoost(),
                            Q3_PBRWorldClassMatchEnabled() != 0 ? 1.0 : 0.0)
                        encoder.setFragmentBytes(&pbrWorldParams, length: 16, index: 3)
                        // Phase 2 atlas wiring. When the bound world handle
                        // has RTX Remix sprite-sheet metadata (or a targeted
                        // compatibility fallback), surface cols/rows/fps to the
                        // MSL fragment so it sub-rect-samples the current frame.
                        // Non-atlas materials leave x=0, keeping the atlas branch off.
                        drawUniforms.spriteAtlasParams = worldSelection.atlasParams
                            ?? (worldSelection.useWorldPBR ? pbrSpriteAtlasParams(for: worldSelection.materialHandle, atlasTime: atlasTimeSeconds) : SIMD4<Float>(0, 0, 0, 0))
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
                    // Pass dispatch order — NOT the same as pass-index numbering.
                    // Pass indices stay: 0=opaque, 1=filter/lightmap, 2=alpha,
                    // 3=additive(src-alpha), 4=additive-full(ONE/ONE), 5=fog.
                    // But we DISPATCH filter/lightmap (1) AFTER alpha/additive
                    // (2,3,4) so multi-stage shaders that author their lightmap
                    // as the final stage (e.g. textures/gothic_floor/center2trn
                    // = fireswirl base + 2x center2trn alpha overlays + $lightmap)
                    // get the Q3-correct composite order
                    //   fire → alpha overlay → alpha overlay → lightmap modulate
                    // instead of the previous lightmap-too-early
                    //   fire → lightmap → alpha overlay (overlays unlit, ring
                    // never gets the lightmap multiply).
                    // For 2-stage opaque+lightmap shaders the result is identical
                    // (no surface has touched those pixels between pass 0 and
                    // the later pass 1).
                    let worldPassOrder = [0, 2, 3, 4, 1, 5]
                    for worldPass in worldPassOrder {
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
                                                                                    slot: frameSlot) {
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
                                                             batch.stageIndex,
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
                        var fogHasBounds: UInt32 = 0
                        var fogBoundsMin = SIMD3<Float>(0, 0, 0)
                        var fogBoundsMax = SIMD3<Float>(0, 0, 0)
                        if draw.fogIndex != noFog {
                            let count = Q3MetalRenderer_GetWorldFogCount()
                            if Int(draw.fogIndex) < count,
                               let fogs = Q3MetalRenderer_GetWorldFogs() {
                                let f = fogs.advanced(by: Int(draw.fogIndex)).pointee
                                fogCD = SIMD4(f.color.0, f.color.1, f.color.2, f.distance)
                                fogParams = SIMD4(f.tcScale, f.hasSurface != 0 ? 1.0 : 0.0, 0, 0)
                                fogSurface = SIMD4(f.surface.0, f.surface.1, f.surface.2, f.surface.3)
                                fogHasBounds = f.hasBounds
                                fogBoundsMin = SIMD3<Float>(f.boundsMin.0, f.boundsMin.1, f.boundsMin.2)
                                fogBoundsMax = SIMD3<Float>(f.boundsMax.0, f.boundsMax.1, f.boundsMax.2)
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
                            let fogOverlayDraw = (draw.flags & fogOverlayBit) != 0
                            if fogOverlayDraw && fogHasBounds != 0 {
                                let bmin = simd_min(fogBoundsMin, fogBoundsMax)
                                let bmax = simd_max(fogBoundsMin, fogBoundsMax)
                                let margin: Float = 0.5
                                if worldUniforms.cameraPos.x >= bmin.x - margin,
                                   worldUniforms.cameraPos.x <= bmax.x + margin,
                                   worldUniforms.cameraPos.y >= bmin.y - margin,
                                   worldUniforms.cameraPos.y <= bmax.y + margin,
                                   worldUniforms.cameraPos.z >= bmin.z - margin,
                                   worldUniforms.cameraPos.z <= bmax.z + margin {
                                    let fogKey = Int(draw.fogIndex)
                                    if fogOverlayInsideClipLogged.insert(fogKey).inserted {
                                        NSLog("[Q3-FOG] clipped fog overlay inside bounds fogIndex=%d bounds=(%.0f,%.0f,%.0f)-(%.0f,%.0f,%.0f)",
                                              fogKey, bmin.x, bmin.y, bmin.z, bmax.x, bmax.y, bmax.z)
                                    }
                                    entryCursor += 1
                                    continue
                                }
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
                            // Fog overlay path — bind PBR-slot defaults (not
                            // nil) so the world pipeline's required slots
                            // 2/3/4/5 stay satisfied. Pipeline shader uses
                            // pbrWorldParams.x to skip the PBR block; the
                            // bound defaults are no-ops for fog rendering.
                            encoder.setFragmentTexture(pbrFlatNormalDefault(), index: 2)
                            encoder.setFragmentTexture(ensurePBREnvCube(), index: 3)
                            encoder.setFragmentTexture(pbrRoughnessDefault(), index: 4)
                            encoder.setFragmentTexture(pbrMetallicDefault(), index: 5)
                            // Fog overlay never emits emissive; bind the
                            // zero default and let drawUniforms.emissiveParams
                            // stay at (1,1,1,0) so the MSL gate skips.
                            encoder.setFragmentTexture(pbrEmissiveDefault(), index: 6)
                            // Height slot @7: default; fogUniforms leaves
                            // parallaxParams at 0 so the MSL block skips.
                            encoder.setFragmentTexture(pbrEmissiveDefault(), index: 7)
                            var pbrWorldFogParams = SIMD4<Float>(
                                0.0,
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
                            // RING-DIAG (cached/batched path): one-shot per
                            // (handle, drawPass) for any stage whose texture
                            // name contains "center2trn". Mirror of the
                            // non-cached site so we can tell which world draw
                            // path actually emits the overlay stages.
                            do {
                                let h = stage.textureHandle
                                let key = (UInt64(h) << 8) | UInt64(drawPass & 0xFF)
                                if !loggedRingDiagKeys.contains(key),
                                   let cName = Q3MetalRenderer_GetTextureName(h) {
                                    let name = String(cString: cName)
                                    if name.contains("center2trn") {
                                        loggedRingDiagKeys.insert(key)
                                        let pipeChosen: String
                                        if drawPass == 2 && worldAlphaPipelineState != nil { pipeChosen = "alpha" }
                                        else if drawPass == 2 { pipeChosen = "OPAQUE-FALLBACK(alphaNil)" }
                                        else if drawPass == 1 && worldFilterPipelineState != nil { pipeChosen = "filter" }
                                        else { pipeChosen = "other(\(drawPass))" }
                                        pbrLog("[RING-DIAG] center2trn cached pass=\(drawPass) blendMode=\(blendMode) useLightmap=\(stage.useLightmap) depthWrite=\(stage.depthWrite) alphaFunc=\(stage.alphaFunc) alphaTest=\(alphaTest) tcModCount=\(stage.tcModCount) pipelineChosen=\(pipeChosen) handle=\(h) name='\(name)'")
                                    }
                                }
                            }
                            let chain = worldTcModChain(for: stage)
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
                                /* Q3MetalWorldStage DOES carry these (parser
                                 * fills identity unless rgbGen/alphaGen are
                                 * const) — pass through, mirroring the
                                 * non-batched site. */
                                rgbConstColor: SIMD4(stage.rgbConstColor.0,
                                                     stage.rgbConstColor.1,
                                                     stage.rgbConstColor.2,
                                                     stage.alphaConst),
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
                                // r_world_debug_mode cvar: 0=normal, 1=base, 2=lightmap, 3=UV1, 4=vertex color.
                                // Replaces compile-time `Coordinator.worldDebugMode` constant.
                                debugMode: Float(Q3_WorldDebugMode()),
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
                            // Use authored PBR albedo for normal world color stages.
                            // The non-batched path was still binding the vanilla Q3
                            // base texture here, so most world geometry looked stock
                            // unless it happened to route through encodeNormalWorldDraw().
                            let materialHandle = worldOwnerMaterialHandle(for: draw, stageIndex: stageIndex, stage: stage)
                            let worldSelection = (stage.useLightmap == 0)
                                ? worldTextureSelectionForPBRDebug(handle: stage.textureHandle, fallback: baseTexture, stage: stage, materialHandle: materialHandle)
                                : WorldTextureSelection(texture: baseTexture, useWorldPBR: false, classicFX: false, atlasParams: nil, materialHandle: stage.textureHandle)
                            setWorldFragmentTextureCached(worldSelection.texture, index: 0)
                            setWorldFragmentTextureCached(lightmapTexture, index: 1)
                            // Match encodeNormalWorldDraw(): bind the
                            // selected material maps, not the old global
                            // generic normal. The non-batched path is used by
                            // many q3dm4/q3dm17 surfaces, so leaving the global
                            // normal here made the world look flat/noisy and
                            // ignored authored roughness/metallic maps.
                            setWorldFragmentTextureCached(worldSelection.useWorldPBR ? pbrNormalTexture(for: worldSelection.materialHandle, allowGenericFallback: false) : nil, index: 2)
                            if worldSelection.useWorldPBR && Q3_PBRIBLEnabled() != 0 && Q3_PBRWorldEnabled() != 0 {
                                setWorldFragmentTextureCached(ensurePBREnvCube(), index: 3)
                                encoder.setFragmentSamplerState(ensurePBREnvSampler(), index: 1)
                                setWorldFragmentTextureCached(pbrRoughnessTexture(for: worldSelection.materialHandle), index: 4)
                                setWorldFragmentTextureCached(pbrMetallicTexture(for: worldSelection.materialHandle), index: 5)
                            } else {
                                setWorldFragmentTextureCached(nil, index: 3)
                                setWorldFragmentTextureCached(nil, index: 4)
                                setWorldFragmentTextureCached(nil, index: 5)
                            }
                            // Emissive @ 6 — same fallback chain as the
                            // primary non-batched site. Material-specific
                            // emissive when present, zero default otherwise.
                            setWorldFragmentTextureCached(pbrEmissiveTexture(for: worldSelection.materialHandle) ?? pbrEmissiveDefault(), index: 6)
                            // Height/parallax @ 7 — mirror of the primary site.
                            let heightTex = worldSelection.useWorldPBR ? pbrHeightTexture(for: worldSelection.materialHandle) : nil
                            let parallaxScale: Float = (heightTex == nil) ? 0.0 : Q3_PBRParallaxScale()
                            let parallaxTint: Float = (heightTex == nil || Q3_PBRParallaxTint() == 0) ? 0.0 : 1.0
                            logParallaxBind(handle: worldSelection.materialHandle,
                                            stage: stage,
                                            selection: worldSelection,
                                            heightTex: heightTex,
                                            scale: parallaxScale,
                                            site: "cached")
                            if let heightTex {
                                setWorldFragmentTextureCached(heightTex, index: 7)
                                drawUniforms.parallaxParams = SIMD4<Float>(parallaxScale, 0, 0, parallaxTint)
                            } else {
                                setWorldFragmentTextureCached(pbrEmissiveDefault(), index: 7)
                                drawUniforms.parallaxParams = SIMD4<Float>(0, 0, 0, 0)
                            }
                            var pbrWorldParams = SIMD4<Float>(
                                (worldSelection.useWorldPBR && Q3_PBRWorldEnabled() != 0) ? 1.0 : 0.0,
                                Q3_PBRWorldAmbientBoost(),
                                Q3_PBRWorldSpecBoost(),
                                Q3_PBRWorldClassMatchEnabled() != 0 ? 1.0 : 0.0)
                            encoder.setFragmentBytes(&pbrWorldParams, length: 16, index: 3)
                            // Phase 2 atlas wiring (mirror of the primary
                            // draw site — see comment above the other copy).
                            drawUniforms.spriteAtlasParams = worldSelection.atlasParams
                                ?? (worldSelection.useWorldPBR ? pbrSpriteAtlasParams(for: worldSelection.materialHandle, atlasTime: atlasTimeSeconds) : SIMD4<Float>(0, 0, 0, 0))
                            drawUniforms.emissiveParams = emissiveParamsForPBRMaterial(handle: worldSelection.materialHandle)
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
                                                         stageIndex,
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
                // P0.2 (docs/2026-06-10-rt-gap-analysis-vs-rtx-remix.md):
                // r_rt_preserve_entities 1 (default) keeps this composite-
                // before-entities ordering — the raster entity/viewmodel/
                // HUD passes below draw on top of the traced world, so the
                // gun is never overwritten by RT. 0 = legacy A/B mode: the
                // composite is deferred to after the main entity pass (see
                // the Q3.render.postRT.legacy block below), reproducing
                // the old "RT world overwrites the gun" artifact.
                if Q3_RTMix() > 0 && Q3_RTPreserveEntities() != 0 {
                    if !rtPreserveEntitiesLogged {
                        rtPreserveEntitiesLogged = true
                        // Mirror through pbrLog so it lands in q3_diag.log
                        // (the file the pull scripts collect) — print() only
                        // reaches stdout.
                        print("[RT] preserve entities mask active size=\(renderW)x\(renderH) (composite-before-entities)")
                        pbrLog("[RT] preserve entities mask active size=\(renderW)x\(renderH) (composite-before-entities)")
                    }
                    _ = uploadEntityBuffers(device: device, slot: frameSlot)
                    encoder.endEncoding()
                    _ = encodeEntityAccelerationStructureBuild(device: device, commandBuffer: commandBuffer, slot: frameSlot)
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
               let entityBuffers = uploadEntityBuffers(device: view.device, slot: frameSlot) {
                let entityVertexBuffer = entityBuffers.vertexBuffer
                let entityIndexBuffer = entityBuffers.indexBuffer
                let entityViewProjection = makeWorldViewProjection(sceneView)
                let cameraPos = SIMD3<Float>(sceneView.viewOrigin.0, sceneView.viewOrigin.1, sceneView.viewOrigin.2)
                let cameraForward = SIMD3<Float>(sceneView.viewAxis.0, sceneView.viewAxis.1, sceneView.viewAxis.2)
                let entityTimeSeconds = Float(CACurrentMediaTime() - frameTimeOrigin)
                var entityUniforms = EntityUniforms(viewProjection: entityViewProjection, cameraPos: cameraPos, tcGen: 0, timeSeconds: entityTimeSeconds)
                populateEntitySun(&entityUniforms)
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
                /* RF_DEPTHHACK / first-person weapon depth range.
                 *
                 * Q3's GL backend calls glDepthRange(0, 0.3) for depth-hack
                 * entities. Keeping only `.lessEqual` without the depth-range
                 * compression lets stored world depth occlude the viewmodel
                 * after the RT preserve path ends/reopens the render encoder.
                 * Use Metal's viewport z range per draw so self-occlusion is
                 * preserved while the weapon projects into the near depth
                 * slice, then restore 0..1 for normal entities/flares/UI. */
                var entityDepthRangeHackActive = false
                func setEntityDepthRangeHack(_ active: Bool) {
                    guard entityDepthRangeHackActive != active else { return }
                    entityDepthRangeHackActive = active
                    encoder.setViewport(MTLViewport(originX: 0, originY: 0,
                                                    width: Double(renderW),
                                                    height: Double(renderH),
                                                    znear: 0.0,
                                                    zfar: active ? 0.3 : 1.0))
                }

                // Dlights for entities (viewmodel, players, pickups lit by
                // nearby muzzle flash / rocket glow). Same block as world pass.
                Self.bindDlightBlock(snapshot: snapshot, encoder: encoder, device: view.device, index: 2, extra: currentBakedDlights())

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
                    let rtPreserveDepthHackAlways = Q3_RTMix() > 0 && Q3_RTPreserveEntities() != 0
                    // P0.2: hoisted once per frame — feeds
                    // entityUniforms.viewmodelParams.z per draw below.
                    let rtDebugEntityMaskActive = Q3_RTDebugEntityMask() != 0

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
                        setEntityDepthRangeHack(wantsDepthHack)
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
                        // Reset to (0,0,0,0) before packing so a previous
                        // atlas draw doesn't bleed into a non-atlas one
                        // sharing the same uniform buffer across the loop.
                        entityUniforms.spriteAtlasParams = SIMD4<Float>(0, 0, 0, 0)
                        // packEntityAtlas writes spriteAtlasParams and returns
                        // the atlas albedo texture when an indirect-name hit
                        // landed (e.g. yellow health → envmapyel atlas DDS).
                        // Caller binds this at fragment slot 0 in place of the
                        // static 64×64 envmap .jpg so the MSL atlas sub-rect
                        // remap actually has frames to sample.
                        let entityAtlasAlbedoOverride = packEntityAtlas(handle: draw.textureHandle, into: &entityUniforms)
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
                        if rtPreserveDepthHackAlways, wantsDepthHack, let alwaysDepth = alwaysPassDepthStencilState {
                            encoder.setDepthStencilState(alwaysDepth)
                        }
                        // PBR Phase 1: when q3_pbr_lookup_by_name matched
                        // a Q3 shader (rocket / shotgun / bfg / etc.), the
                        // C-side stamped pbrMaterial on the metalTexture
                        // and we bind the HD DDS albedo here instead of
                        // the original pak0 JPG-decoded texture. Falls
                        // back to the original on miss / DDS-load fail.
                        let q3Name = Q3MetalRenderer_GetTextureName(draw.textureHandle).map { String(cString: $0) } ?? "unknown"
                        entityUniforms.forceLuminanceAlpha = Self.textureAlphaSynthesisMode(q3Name)
                        let preferClassicFX = isEntityAdditive || isEntityAdditiveFull || isEntityAlpha || isScenePoly ||
                                              entityUniforms.forceLuminanceAlpha != 0 ||
                                              shouldPreferClassicTextureForAlphaFX(q3Name, isEntity: true)
                        // Entity-side FX-stage sidecar promotion experiment
                        // reverted 2026-06-12: enabling the world-path
                        // useWorldPBR/classicFX combined return on entities
                        // tanked frame time from 13.9 ms → 121 ms (72 fps → 8 fps)
                        // on q3dm1, even after caching the Q3MetalRenderer_GetPBRMaterial
                        // lookup Swift-side. The cost wasn't the lookup itself but
                        // the per-draw pbrAlbedoTexture/pbrNormalTexture cache
                        // probes that fire for every FX entity once the gate
                        // promotes them. The plasammo chrome-clobbering bug is
                        // still fixed by the packEntityAtlas hasAuthoredAlbedo
                        // gate from earlier this session — that runs once per
                        // (handle, atlas) lookup, not per draw. Full entity-side
                        // PBR sidecar promotion needs either (a) cached per-handle
                        // texture references in EntityFrameContext to skip the
                        // dict probe, or (b) the per-frame texture cache promoted
                        // to a flat array keyed by handle. Deferred.
                        let pbrTex = preferClassicFX ? nil : pbrAlbedoTexture(for: draw.textureHandle)
                        // 2026-06-10: emissiveParams must be written BEFORE the
                        // setVertexBytes/setFragmentBytes upload, not after.
                        // Previously assigned ~98 lines below, which meant the
                        // GPU only ever saw the struct's default `(1,1,1,0)`
                        // — the `.w == 0` MSL gate then skipped the emissive
                        // accumulation on every entity draw, regardless of
                        // material. Visible as flat/dark viewmodels with no
                        // emissive glow even when the material had an
                        // emissive map bound at fragment slot 6.
                        entityUniforms.emissiveParams = emissiveParamsForPBRMaterial(handle: draw.textureHandle)
                        // 2026-06-10: viewmodel-only base-color floor. .x is
                        // the floor strength from `r_pbr_viewmodel_floor`
                        // (CVAR_ARCHIVE, default 0.65). .y is the gate flag
                        // (1.0 for RF_DEPTHHACK, 0.0 for world entities) so
                        // the MSL `if (.y > 0.5)` runs only on first-person
                        // weapons. World pickups, scene polys, and HUD heads
                        // get (0,0,0,0) and skip the floor entirely.
                        let vmFloor = Q3_PBRViewmodelFloor()
                        // P0.2: .z doubles as the r_rt_debug_entity_mask
                        // flag — q3_entity_fragment returns solid white
                        // when it is > 0.5 (after alpha-test discards), to
                        // visualize the entity coverage preserved over the
                        // RT composite. Main-scene entity loop only; the
                        // HUD/scoreboard sub-pass leaves viewmodelParams at
                        // struct default (0,0,0,0) so it is never masked.
                        entityUniforms.viewmodelParams = SIMD4<Float>(
                            vmFloor,
                            wantsDepthHack ? 1.0 : 0.0,
                            rtDebugEntityMaskActive ? 1.0 : 0.0,
                            // .w = world-entity readability floor (non-viewmodel
                            // pickups) so full-metal items (RL/plasma/ammo/health,
                            // metallic=1.0) don't go near-invisible under the dark
                            // IBL cube. Viewmodels use .x instead.
                            wantsDepthHack ? 0.0 : Q3_PBREntityFloor())
                        if wantsDepthHack && !loggedViewmodelFloorOnce && vmFloor > 0.0 {
                            loggedViewmodelFloorOnce = true
                            pbrLog("[Q3-PBR-ENTITY] viewmodel floor enabled strength=\(String(format: "%.3f", vmFloor))")
                        }
                        // 2026-06-19: additive-stage brightness cap (RT mode only).
                        // Chrome-envmap / explosion additive stages pass the
                        // .lessEqual depth test (they ARE in front) but their bright
                        // additive specular blooms and reads through dark RT walls.
                        // Cap the per-fragment output for additive/additive-full
                        // stages; non-additive draws and raster mode get a huge
                        // value so the MSL `min()` is a no-op. Set explicitly every
                        // draw so no stale cap bleeds into the next entity.
                        let entityAdditiveStage = isEntityAdditive || isEntityAdditiveFull
                        entityUniforms.additiveClampParams = SIMD4<Float>(
                            (Q3_RTMix() > 0 && entityAdditiveStage) ? Q3_RTEntityAdditiveMax() : 1e9,
                            0, 0, 0)
                        encoder.setVertexBytes(&entityUniforms, length: MemoryLayout<EntityUniforms>.stride, index: 1)
                        encoder.setFragmentBytes(&entityUniforms, length: MemoryLayout<EntityUniforms>.stride, index: 1)
                        if (preferClassicFX || (draw.flags & aTestGT0Bit) != 0),
                           loggedAlphaEffectTextures.insert(draw.textureHandle).inserted {
                            var info = Q3MetalTextureInfo()
                            _ = Q3MetalRenderer_GetTextureInfo(draw.textureHandle, &info)
                            let pbrLabel = pbrTex?.label ?? "nil"
                            let srcLabel = texture.label ?? "nil"
                            logAlphaTextureDiagnostic("[ALPHA-TEX] handle=\(draw.textureHandle) name='\(q3Name)' pass=\(drawPass) flags=0x\(String(draw.flags, radix: 16)) alphaFunc=\(info.alphaFunc) rgbGen=\(info.rgbGen) alphaGen=\(info.alphaGen) forceLum=\(entityUniforms.forceLuminanceAlpha) classicFX=\(preferClassicFX ? 1 : 0) pbr='\(pbrLabel)' src='\(srcLabel)' size=\(info.width)x\(info.height)")
                        }
                        let baseEntityColor = preferClassicFX
                            ? texture
                            : entityBaseTextureForPBRDebug(handle: draw.textureHandle, fallback: texture)
                        // Atlas override wins over the base color binding. When
                        // packEntityAtlas resolved the indirect-name fallback,
                        // it returned the atlas DDS; that's what slot 0 needs to
                        // be, not the static 64×64 envmap source .jpg.
                        let entityColorTexture = entityAtlasAlbedoOverride ?? baseEntityColor
                        encoder.setFragmentTexture(entityColorTexture, index: 0)
                        // PBR Phase 2 — bind normal map only for opaque PBR entity
                        // base skins. Alpha/additive FX stages keep the original Q3
                        // shader texture/alpha behaviour; a normal map on those
                        // quads creates white blobs and bogus lighting.
                        // Normal at index 1: never bind nil — Q3.entity pipeline
                        // shader declares `normalTexture` as required, and an
                        // unbound slot causes Metal API-validation warnings
                        // (57/frame) plus undefined GPU reads on tcGen-env
                        // entity draws (yellow/red health, quad shell). Fall
                        // back to a 1×1 flat normal so the binding stays valid
                        // while behaving as identity for PBR-off draws.
                        let entityNormalTex = preferClassicFX
                            ? pbrFlatNormalDefault()
                            : (pbrNormalTexture(for: draw.textureHandle) ?? pbrFlatNormalDefault())
                        encoder.setFragmentTexture(entityNormalTex, index: 1)
                        // PBR Phase 4 — viewmodel-vs-world entity gating.
                        // Viewmodels (RF_DEPTHHACK) get the wide
                        // (0.6..1.2) range for prominent surface relief;
                        // world entities (spinning pickups, dropped
                        // weapons) get the tight (0.78..1.18) range to
                        // avoid Mikkelsen TBN derivative instability on
                        // rotating geometry.
                        var pbrNormalScaleEntity: Float = wantsDepthHack ? 1.0 : 0.0
                        encoder.setFragmentBytes(&pbrNormalScaleEntity, length: 4, index: 3)
                        // PBR Phase F — rim params at buffer(4). Disable the
                        // Fresnel rim for now: it reads as a white outline on
                        // weapons/items with the current RTX/PBR assets.
                        // 2026-06-10: viewmodels (RF_DEPTHHACK) get a small rim
                        // intensity (0.25) so PBR-metal viewmodels get a visible
                        // edge highlight without the white-outline overdrive that
                        // killed it on world pickups. World entities keep 0.0 —
                        // the rim term was causing white halos on tcGen-env
                        // chrome items previously.
                        let rimIntensity: Float = wantsDepthHack ? 0.25 : 0.0
                        var pbrRimParamsEntity = SIMD2<Float>(rimIntensity, Q3_PBRRimFalloff())
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
                        let phase5Enabled = Q3_PBRPhase5Enabled() != 0 && !preferClassicFX && pbrTex != nil
                        // Roughness slot 3 + metallic slot 4: never nil.
                        // Same reasoning as the normal slot above —
                        // Q3.entity pipeline declares them, and unbound
                        // slots produce Metal validation warnings plus
                        // undefined reads. Fall back to the 1×1 default
                        // constants so the binding is valid even when
                        // phase5 is disabled.
                        let entityRoughTex = phase5Enabled
                            ? (pbrRoughnessTexture(for: draw.textureHandle) ?? pbrRoughnessDefault())
                            : pbrRoughnessDefault()
                        let entityMetalTex = phase5Enabled
                            ? (pbrMetallicTexture(for: draw.textureHandle) ?? pbrMetallicDefault())
                            : pbrMetallicDefault()
                        encoder.setFragmentTexture(entityRoughTex, index: 3)
                        encoder.setFragmentTexture(entityMetalTex, index: 4)
                        // Phase 6 IBL — procedural env cubemap + dedicated
                        // clampToEdge sampler. Bound nil-safe; MSL guards via
                        // is_null_texture so a fail-to-alloc falls back to
                        // Phase 5 ambient floor without crashing.
                        // envCube at index 5 — always bind to procedural cube
                        // even when IBL disabled. The MSL fragment branches on
                        // its own IBL gate so the bound cube is unused, but the
                        // pipeline slot stays valid for Metal validation.
                        encoder.setFragmentTexture(ensurePBREnvCube(), index: 5)
                        encoder.setFragmentSamplerState(ensurePBREnvSampler(), index: 1)
                        // Emissive @ 6 for primary entity bind site. Always
                        // bound — material's emissive DDS if present, zero
                        // default otherwise. Pair with entityUniforms.
                        // emissiveParams written below.
                        let entityEmissiveTex = pbrEmissiveTexture(for: draw.textureHandle) ?? pbrEmissiveDefault()
                        encoder.setFragmentTexture(entityEmissiveTex, index: 6)
                        // (emissiveParams now assigned above, pre-upload — see comment near line 7541)
                        // 2026-06-10: one-shot per-handle viewmodel PBR resolution log.
                        // Surfaces what materials each first-person weapon resolves
                        // to, dedup'd by handle. Fires only for wantsDepthHack draws
                        // (RF_DEPTHHACK = viewmodel) so HUD/world-entity noise is
                        // suppressed. Use to diagnose "viewmodel looks dark/flat":
                        // if albedo/normal/roughness/metallic show "nil-default",
                        // the material is missing from materials.json. If the
                        // preferClassicFX flag is 1, an FX classifier rule is
                        // forcing the viewmodel onto the non-PBR path.
                        if wantsDepthHack,
                           loggedViewmodelPBRHandles.insert(draw.textureHandle).inserted {
                            let albedoSrc: String
                            if preferClassicFX {
                                albedoSrc = "classicFX-forced"
                            } else if pbrTex != nil {
                                albedoSrc = pbrTex?.label ?? "pbr"
                            } else {
                                albedoSrc = "nil-default(classic-q3-tex)"
                            }
                            let normalSrc = (!preferClassicFX && pbrNormalTexture(for: draw.textureHandle) != nil) ?
                                (pbrNormalTexture(for: draw.textureHandle)?.label ?? "pbr") : "nil-default(flat)"
                            let roughSrc = (phase5Enabled && pbrRoughnessTexture(for: draw.textureHandle) != nil) ?
                                (pbrRoughnessTexture(for: draw.textureHandle)?.label ?? "pbr") : "nil-default(0.55)"
                            let metalSrc = (phase5Enabled && pbrMetallicTexture(for: draw.textureHandle) != nil) ?
                                (pbrMetallicTexture(for: draw.textureHandle)?.label ?? "pbr") : "nil-default(0.50)"
                            let emissiveSrc = (pbrEmissiveTexture(for: draw.textureHandle) != nil) ?
                                (pbrEmissiveTexture(for: draw.textureHandle)?.label ?? "pbr") : "nil-default(0,0,0)"
                            pbrLog("[Q3-PBR-ENTITY] viewmodel handle=\(draw.textureHandle) name='\(q3Name)' albedo=\(albedoSrc) normal=\(normalSrc) roughness=\(roughSrc) metallic=\(metalSrc) emissive=\(emissiveSrc) phase5=\(phase5Enabled ? 1 : 0) preferClassicFX=\(preferClassicFX ? 1 : 0) envCubeBound=1")
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
                    setEntityDepthRangeHack(false)
                }
            }

            /* P0.2 legacy A/B path — r_rt_preserve_entities 0: composite
             * the RT world AFTER the main entity pass. The RT primary ray
             * hits the world behind the viewmodel/pickups with alpha=1 and
             * blendRT overwrites them — this is the pre-2026-06-07
             * ordering, kept ONLY for comparison captures of the artifact.
             * Default path (cvar=1) composited before the entity pass
             * above and skips this block entirely. */
            if Q3_RTMix() > 0, Q3_RTPreserveEntities() == 0,
               let device = view.device,
               Q3MetalRenderer_IsWorldLoaded() != 0,
               let sceneView = Q3MetalRenderer_GetSceneView()?.pointee {
                if !rtPreserveEntitiesLogged {
                    rtPreserveEntitiesLogged = true
                    print("[RT] preserve entities OFF — legacy composite-after-entities size=\(renderW)x\(renderH)")
                    pbrLog("[RT] preserve entities OFF — legacy composite-after-entities size=\(renderW)x\(renderH)")
                }
                let rtTargetTexture = (upscaleActive ? upscaleColorTarget : drawable.texture) ?? drawable.texture
                // Parity with the preserve path: ensure entity buffers are
                // valid even when the entity pass above was skipped
                // (entityCommandCount == 0) and r_rt_entities is enabled.
                _ = uploadEntityBuffers(device: device, slot: frameSlot)
                encoder.endEncoding()
                _ = encodeEntityAccelerationStructureBuild(device: device, commandBuffer: commandBuffer, slot: frameSlot)
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
                encoder.label = "Q3.render.postRT.legacy"
                encoder.setViewport(MTLViewport(originX: 0, originY: 0,
                                                width: Double(renderW),
                                                height: Double(renderH),
                                                znear: 0.0,
                                                zfar: 1.0))
                encoder.setScissorRect(MTLScissorRect(x: 0, y: 0,
                                                       width: renderW,
                                                       height: renderH))
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
               let entityBuffers = uploadEntityBuffers(device: view.device, slot: frameSlot) {
                let entityVertexBuffer = entityBuffers.vertexBuffer
                let entityIndexBuffer = entityBuffers.indexBuffer
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
                    populateEntitySun(&subUniforms)

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
                    Self.bindDlightBlock(snapshot: snapshot, encoder: encoder, device: view.device, index: 2, extra: currentBakedDlights())

                    let first = Int(scene.entityCommandFirst)
                    let rawEnd = first + Int(scene.entityCommandCount)
                    let end = min(max(first, rawEnd), allEntityDraws.count)
                    guard first < end else { continue }
                    for drawIdx in first..<end {
                        let draw = allEntityDraws[drawIdx]
                        guard draw.indexCount > 0 else { continue }
                        guard let texture = texture(for: draw.textureHandle, device: view.device) else { continue }
                        // PBR Phase 1 — entity sub-pass (HUD heads,
                        // ammo rotations, scoreboard portraits). Keep classic
                        // fallback here; PBR-only diagnostics are for 3D world/main
                        // entity surfaces, not HUD/UI overlays.
                        let q3Name = Q3MetalRenderer_GetTextureName(draw.textureHandle).map { String(cString: $0) } ?? "unknown"
                        let preferClassicFX = shouldPreferClassicTextureForAlphaFX(q3Name, isEntity: true)
                        let pbrTex = preferClassicFX ? nil : pbrAlbedoTexture(for: draw.textureHandle)
                        encoder.setFragmentTexture(pbrTex ?? texture, index: 0)
                        // PBR Phase 2 — bind normal map to slot 1 if the
                        // material ships one. Nil bind leaves the slot
                        // unbound; q3_entity_fragment uses is_null_texture
                        // to skip the normal-mapped lighting branch.
                        // Normal at index 1 — same fallback chain as the
                        // primary entity bind site. Never nil to satisfy
                        // Q3.entity pipeline's required `normalTexture` slot.
                        let entityNormalTexSub = preferClassicFX
                            ? pbrFlatNormalDefault()
                            : (pbrNormalTexture(for: draw.textureHandle) ?? pbrFlatNormalDefault())
                        encoder.setFragmentTexture(entityNormalTexSub, index: 1)
                        // Roughness@3 + metallic@4 — same correctness rule as
                        // the primary bind site. Q3.entity pipeline declares
                        // them as required slots; an unbound texture there is
                        // a Metal API-validation "missing fragment texture"
                        // warning + UB GPU read on the sub-pass entity draws
                        // (HUD/scoreboard portrait, weapon icons, etc.). The
                        // 1×1 defaults are no-ops for non-PBR sub-pass paths.
                        encoder.setFragmentTexture(pbrRoughnessDefault(), index: 3)
                        encoder.setFragmentTexture(pbrMetallicDefault(), index: 4)
                        // envCube @ 5 + envSampler @ 1 — required by
                        // q3_entity_fragment even when PBR is off; missing
                        // bindings trigger Metal validation errors on NV15's
                        // ~44K entity draws (the sub-pass hits many surfaces).
                        encoder.setFragmentTexture(ensurePBREnvCube(), index: 5)
                        encoder.setFragmentSamplerState(ensurePBREnvSampler(), index: 1)
                        // Emissive @ 6 for HUD/sub-pass entity draws. Zero
                        // default (HUD elements have no emissive layer); the
                        // sub-pass entityUniforms.emissiveParams left at the
                        // struct default (1,1,1,0) so the MSL gate skips.
                        encoder.setFragmentTexture(pbrEmissiveDefault(), index: 6)
                        var pbrNormalScaleSub: Float = 0.0
                        encoder.setFragmentBytes(&pbrNormalScaleSub, length: 4, index: 3)
                        // PBR Phase F — rim params at buffer(4).
                        var pbrRimParamsSub = SIMD2<Float>(0.0, Q3_PBRRimFalloff())
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
               let vertexBuffer = uploadVertices(UnsafeBufferPointer(start: verticesPointer, count: vertexCount), device: view.device, slot: frameSlot) {
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
                            // PBR Phase 1 — final fallback / overlay path. Keep classic
                            // fallback for UI overlays; PBR-only diagnostics are for
                            // 3D world/main entity surfaces.
                            let pbrTex = pbrAlbedoTexture(for: draw.textureHandle)
                            encoder.setFragmentTexture(pbrTex ?? texture, index: 0)
                            encoder.drawPrimitives(type: .triangle, vertexStart: Int(draw.firstVertex), vertexCount: Int(draw.vertexCount))
                        }
                    }
                }
            }

            encoder.endEncoding()

            if upscaleActive,
               let colorRT = (rtCompositeForUpscale ?? upscaleColorTarget),
               let resolveRT = upscaleResolvedColorTarget {
                encodeSpatialUpscale(commandBuffer: commandBuffer,
                                     source: colorRT,
                                     output: resolveRT)
                encodePostprocess(commandBuffer: commandBuffer,
                                  sourceTexture: resolveRT,
                                  outputTexture: drawable.texture)
            } else if upscaleActive {
                encodePostprocess(commandBuffer: commandBuffer,
                                  sourceTexture: drawable.texture,
                                  outputTexture: drawable.texture)
            } else {
                encodePostprocess(commandBuffer: commandBuffer,
                                  sourceTexture: drawable.texture,
                                  outputTexture: drawable.texture)
            }
            // Cache drawable.texture BEFORE present(). Reading
            // drawable.texture after commandBuffer.present(drawable)
            // logs "[CAMetalLayerDrawable texture] should not be called
            // after already presenting this drawable." The MTLTexture
            // reference itself stays valid post-present — only the
            // drawable.texture accessor complains.
            let tex = drawable.texture
            let frameSemaphore = frameInflightSemaphore
            commandBuffer.addCompletedHandler { _ in
                frameSemaphore.signal()
            }
            frameSemaphoreNeedsSignal = false
            commandBuffer.present(drawable)
            commandBuffer.commit()

            // Video/debug capture: when the engine is recording an AVI, read
            // the just-rendered drawable back to CPU and stash the BGRA
            // bytes in a shared buffer. The engine's per-frame
            // CL_TakeVideoFrame → RE_TakeVideoFrame hook (in
            // metal_renderer_stub.c) pulls from that buffer and converts
            // to the packed RGB layout the AVI muxer expects. Gated by
            // CL_VideoRecording() / Q3_CAPTURE_FRAMES so idle runs incur no
            // readback cost.
            let debugCaptureFrame = nextDebugFrameCaptureNumber()
            if CL_VideoRecording() != 0 || debugCaptureFrame != nil {
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
                    if CL_VideoRecording() != 0 {
                        Q3MetalRenderer_StoreVideoFrame(ptr.baseAddress, Int32(w), Int32(h))
                    }
                    if let debugCaptureFrame {
                        writeDebugFrameCapture(ptr.baseAddress,
                                               width: w,
                                               height: h,
                                               byteCount: byteCount,
                                               frame: debugCaptureFrame)
                    }
                }
            }
        }
        /* Reusable BGRA readback buffer sized on first recorded frame. */
        private var videoReadbackBuffer: [UInt8]?
        private var debugCaptureConfigured = false
        private var debugCaptureDir: URL?
        private var debugCaptureRemaining = 0
        private var debugCaptureStartFrame: UInt32 = 120
        private var debugCaptureStride: UInt32 = 60
        private var debugCaptureLastFrame: UInt32?

        private func configureDebugFrameCaptureIfNeeded() {
            guard !debugCaptureConfigured else { return }
            debugCaptureConfigured = true
            let env = ProcessInfo.processInfo.environment
            guard let dir = env["Q3_CAPTURE_FRAME_DIR"], !dir.isEmpty else { return }
            let requested = Int(env["Q3_CAPTURE_FRAMES"] ?? "0") ?? 0
            guard requested > 0 else { return }
            debugCaptureDir = URL(fileURLWithPath: dir, isDirectory: true)
            debugCaptureRemaining = requested
            debugCaptureStartFrame = UInt32(max(0, Int(env["Q3_CAPTURE_START_FRAME"] ?? "120") ?? 120))
            debugCaptureStride = UInt32(max(1, Int(env["Q3_CAPTURE_STRIDE"] ?? "60") ?? 60))
            do {
                try FileManager.default.createDirectory(at: debugCaptureDir!,
                                                        withIntermediateDirectories: true)
                print("[Q3-CAPTURE] enabled dir=\(dir) frames=\(requested) start=\(debugCaptureStartFrame) stride=\(debugCaptureStride)")
            } catch {
                print("[Q3-CAPTURE] failed to create dir \(dir): \(error)")
                debugCaptureDir = nil
                debugCaptureRemaining = 0
            }
        }

        private func nextDebugFrameCaptureNumber() -> UInt32? {
            configureDebugFrameCaptureIfNeeded()
            guard debugCaptureRemaining > 0,
                  debugCaptureDir != nil,
                  debugFrameCounter >= debugCaptureStartFrame else { return nil }
            if let last = debugCaptureLastFrame,
               debugFrameCounter &- last < debugCaptureStride {
                return nil
            }
            debugCaptureRemaining -= 1
            debugCaptureLastFrame = debugFrameCounter
            return debugFrameCounter
        }

        private func writeDebugFrameCapture(_ bgra: UnsafeRawPointer?,
                                            width: Int,
                                            height: Int,
                                            byteCount: Int,
                                            frame: UInt32) {
            guard let bgra, let dir = debugCaptureDir else { return }
            guard width > 0, height > 0, width <= 65535, height <= 65535 else { return }
            var header = [UInt8](repeating: 0, count: 18)
            header[2] = 2               // uncompressed true-colour TGA
            header[12] = UInt8(width & 0xff)
            header[13] = UInt8((width >> 8) & 0xff)
            header[14] = UInt8(height & 0xff)
            header[15] = UInt8((height >> 8) & 0xff)
            header[16] = 32             // BGRA8
            header[17] = 0x28           // 8 alpha bits, top-left origin
            var data = Data(header)
            data.append(bgra.assumingMemoryBound(to: UInt8.self), count: byteCount)
            let url = dir.appendingPathComponent(String(format: "frame_%06u.tga", frame))
            do {
                try data.write(to: url, options: .atomic)
                print("[Q3-CAPTURE] wrote \(url.path) \(width)x\(height)")
            } catch {
                print("[Q3-CAPTURE] write failed \(url.path): \(error)")
            }
        }

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
                view.drawableSize = Q3MetalOutputTargetSize(screen: view.window?.screen ?? UIScreen.main)
            } else {
                view.drawableSize = Q3MetalOutputTargetSize(screen: view.window?.screen ?? UIScreen.main)
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

            let sunShadowPipelineDescriptor = MTLRenderPipelineDescriptor()
            sunShadowPipelineDescriptor.label = "Q3.world.sunShadowDepth"
            sunShadowPipelineDescriptor.vertexFunction = library.makeFunction(name: "q3_world_vertex")
            sunShadowPipelineDescriptor.fragmentFunction = nil
            sunShadowPipelineDescriptor.colorAttachments[0].pixelFormat = .invalid
            sunShadowPipelineDescriptor.depthAttachmentPixelFormat = .depth32Float
            do {
                sunShadowPipelineState = try device.makeRenderPipelineState(descriptor: sunShadowPipelineDescriptor)
            } catch {
                print("[Metal] Failed to create sun shadow pipeline: \(error)")
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

            let sunShadowDepthDescriptor = MTLDepthStencilDescriptor()
            sunShadowDepthDescriptor.isDepthWriteEnabled = true
            sunShadowDepthDescriptor.depthCompareFunction = .lessEqual
            sunShadowDepthStencilState = device.makeDepthStencilState(descriptor: sunShadowDepthDescriptor)

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

        private func uploadVertices(_ vertices: UnsafeBufferPointer<Q3MetalVertex>, device: MTLDevice?, slot: Int) -> MTLBuffer? {
            guard let device else { return nil }

            let clampedSlot = max(0, min(slot, Self.maxInflightFrames - 1))
            let requiredLength = vertices.count * MemoryLayout<GPUVertex>.stride
            if requiredLength == 0 {
                return nil
            }

            if vertexBuffers[clampedSlot] == nil || requiredLength > vertexBufferCapacities[clampedSlot] {
                let nextCapacity = max(requiredLength, max(vertexBufferCapacities[clampedSlot] * 2, 4096))
                vertexBuffers[clampedSlot] = device.makeBuffer(length: nextCapacity, options: .storageModeShared)
                vertexBuffers[clampedSlot]?.label = "Q3.vb.ui.slot\(clampedSlot)"
                vertexBufferCapacities[clampedSlot] = nextCapacity
            }

            guard let vertexBuffer = vertexBuffers[clampedSlot],
                  let rawPointer = vertexBuffer.contents().bindMemory(to: GPUVertex.self, capacity: vertices.count) as UnsafeMutablePointer<GPUVertex>? else {
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
                let neededIndexBytes = Int(snapshot.worldIndexCount) * MemoryLayout<UInt32>.stride
                if worldIndexBuffer?.length ?? 0 >= neededIndexBytes {
                    return worldVertexBuffer
                }
                // Buffer too small for current map (e.g. nv15 needs 3MB, q3dm1 only 200KB).
                // Fall through to re-allocate.
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
            // Purge PBR texture caches on map change — the previous map's
            // 3840x3840 PBR textures consume ~2.2 GB alone; without this,
            // switching maps accumulates textures until iOS kills the app
            // at its ~3.3 GB memory limit (EXC_RESOURCE MEMORY).
            pbrAlbedoCache.removeAll(keepingCapacity: false)
            pbrNormalCache.removeAll(keepingCapacity: false)
            pbrRoughnessCache.removeAll(keepingCapacity: false)
            pbrMetallicCache.removeAll(keepingCapacity: false)
            pbrEmissiveCache.removeAll(keepingCapacity: false)
            pbrHeightCache.removeAll(keepingCapacity: false)
            pbrTriedAndMissed.removeAll(keepingCapacity: false)
            entityAtlasAlbedoCache.removeAll(keepingCapacity: false)
            entityAtlasIsCaptureCache.removeAll(keepingCapacity: false)
            entityAtlasAlbedoMissed.removeAll(keepingCapacity: false)
            pbrEmissiveTried.removeAll(keepingCapacity: false)
            pbrHeightTried.removeAll(keepingCapacity: false)
            loggedParallaxHandles.removeAll(keepingCapacity: false)
            textureCache.removeAll(keepingCapacity: false)
            rtASVertexBuffer = nil
            rtASIndexBuffer = nil
            return worldVertexBuffer
        }

        private func uploadEntityBuffers(device: MTLDevice?, slot: Int) -> (vertexBuffer: MTLBuffer, indexBuffer: MTLBuffer)? {
            guard let device,
                  let snapshot = Q3MetalRenderer_GetFrameSnapshot()?.pointee,
                  let verticesPointer = Q3MetalRenderer_GetEntityVertices(),
                  let indicesPointer = Q3MetalRenderer_GetEntityIndices()
            else { return nil }

            let clampedSlot = max(0, min(slot, Self.maxInflightFrames - 1))
            let vertexCount = Int(snapshot.entityVertexCount)
            let indexCount = Int(snapshot.entityIndexCount)
            guard vertexCount > 0, indexCount > 0 else { return nil }

            let vertexLength = vertexCount * MemoryLayout<GPUEntityVertex>.stride
            if entityVertexBuffers[clampedSlot] == nil || vertexLength > entityVertexBufferCapacities[clampedSlot] {
                let nextCapacity = max(vertexLength, max(entityVertexBufferCapacities[clampedSlot] * 2, 4096))
                entityVertexBuffers[clampedSlot] = device.makeBuffer(length: nextCapacity, options: .storageModeShared)
                entityVertexBuffers[clampedSlot]?.label = "Q3.vb.entity.slot\(clampedSlot)"
                entityVertexBufferCapacities[clampedSlot] = nextCapacity
            }

            guard let entityVertexBuffer = entityVertexBuffers[clampedSlot],
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
            if entityIndexBuffers[clampedSlot] == nil || indexLength > entityIndexBufferCapacities[clampedSlot] {
                let nextCapacity = max(indexLength, max(entityIndexBufferCapacities[clampedSlot] * 2, 4096))
                entityIndexBuffers[clampedSlot] = device.makeBuffer(length: nextCapacity, options: .storageModeShared)
                entityIndexBuffers[clampedSlot]?.label = "Q3.ib.entity.slot\(clampedSlot)"
                entityIndexBufferCapacities[clampedSlot] = nextCapacity
            }

            guard let entityIndexBuffer = entityIndexBuffers[clampedSlot],
                  let rawIndexPointer = entityIndexBuffer.contents().bindMemory(to: UInt32.self, capacity: indexCount) as UnsafeMutablePointer<UInt32>?
            else {
                return nil
            }

            let sourceIndices = UnsafeBufferPointer(start: indicesPointer, count: indexCount)
            for i in 0..<indexCount {
                rawIndexPointer[i] = sourceIndices[i]
            }

            return (entityVertexBuffer, entityIndexBuffer)
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

        private func makeSunShadowOrtho(width: Float, height: Float, near: Float, far: Float) -> simd_float4x4 {
            let depth = max(far - near, 1.0)
            return simd_float4x4(columns: (
                SIMD4<Float>(2.0 / max(width, 1.0), 0, 0, 0),
                SIMD4<Float>(0, 2.0 / max(height, 1.0), 0, 0),
                SIMD4<Float>(0, 0, 1.0 / depth, 0),
                SIMD4<Float>(0, 0, -near / depth, 1)
            ))
        }

        private func makeSunShadowViewProjection(center: SIMD3<Float>, sunDir rawSunDir: SIMD3<Float>) -> simd_float4x4 {
            let sunDirLen = simd_length(rawSunDir)
            let sunDir = sunDirLen > 1e-4 ? rawSunDir / sunDirLen : SIMD3<Float>(0.3, 0.5, 0.7)
            let forward = -sunDir
            let upHint: SIMD3<Float> = abs(simd_dot(forward, SIMD3<Float>(0, 0, 1))) > 0.92
                ? SIMD3<Float>(0, 1, 0)
                : SIMD3<Float>(0, 0, 1)
            let right = simd_normalize(simd_cross(upHint, forward))
            let up = simd_normalize(simd_cross(forward, right))
            let span: Float = 4096.0
            let depth: Float = 8192.0
            let eye = center + sunDir * (depth * 0.5)
            let view = simd_float4x4(columns: (
                SIMD4<Float>(right.x, up.x, forward.x, 0),
                SIMD4<Float>(right.y, up.y, forward.y, 0),
                SIMD4<Float>(right.z, up.z, forward.z, 0),
                SIMD4<Float>(-simd_dot(eye, right), -simd_dot(eye, up), -simd_dot(eye, forward), 1)
            ))
            return makeSunShadowOrtho(width: span, height: span, near: 1.0, far: depth) * view
        }

        private func ensureSunShadowTexture(device: MTLDevice, size: Int = 512) -> MTLTexture? {
            if let tex = sunShadowTexture,
               sunShadowTextureSize.width == size,
               sunShadowTextureSize.height == size {
                return tex
            }
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float,
                                                                width: size,
                                                                height: size,
                                                                mipmapped: false)
            desc.usage = [.renderTarget, .shaderRead]
            desc.storageMode = .private
            guard let tex = device.makeTexture(descriptor: desc) else { return nil }
            tex.label = "Q3.sun.shadow.depth"
            sunShadowTexture = tex
            sunShadowTextureSize = MTLSize(width: size, height: size, depth: 1)
            return tex
        }

        private func encodeSunShadowMap(commandBuffer: MTLCommandBuffer,
                                        device: MTLDevice,
                                        snapshot: Q3MetalFrameSnapshot,
                                        sceneView: Q3MetalSceneView) -> (texture: MTLTexture, matrix: simd_float4x4)? {
            guard Q3_PBRSunShadows() != 0,
                  snapshot.worldCommandCount > 0,
                  let pipeline = sunShadowPipelineState,
                  let depthState = sunShadowDepthStencilState,
                  let shadowTexture = ensureSunShadowTexture(device: device),
                  let worldVertexBuffer = uploadWorldBuffers(device: device, generation: snapshot.worldGeneration),
                  let worldIndexBuffer,
                  let drawsPtr = Q3MetalRenderer_GetWorldDrawCommands() else {
                return nil
            }
            _ = ensureRTLightBuffer(device: device)
            guard rtLightCount > 0,
                  let sun = rtLightsCPU.first,
                  sun.dirType.w == 0 else {
                return nil
            }
            let center = SIMD3<Float>(sceneView.viewOrigin.0, sceneView.viewOrigin.1, sceneView.viewOrigin.2)
            let sunDir = SIMD3<Float>(sun.dirType.x, sun.dirType.y, sun.dirType.z)
            let shadowMatrix = makeSunShadowViewProjection(center: center, sunDir: sunDir)
            let pass = MTLRenderPassDescriptor()
            pass.depthAttachment.texture = shadowTexture
            pass.depthAttachment.loadAction = .clear
            pass.depthAttachment.storeAction = .store
            pass.depthAttachment.clearDepth = 1.0
            guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return nil }
            enc.label = "Q3.sun.shadow"
            enc.setViewport(MTLViewport(originX: 0, originY: 0,
                                        width: Double(shadowTexture.width),
                                        height: Double(shadowTexture.height),
                                        znear: 0, zfar: 1))
            enc.setRenderPipelineState(pipeline)
            enc.setDepthStencilState(depthState)
            enc.setFrontFacing(.clockwise)
            enc.setVertexBuffer(worldVertexBuffer, offset: 0, index: 0)
            var shadowUniforms = WorldUniforms(viewProjection: shadowMatrix,
                                               cameraPos: center,
                                               cameraRight: SIMD3<Float>(1, 0, 0),
                                               cameraUp: SIMD3<Float>(0, 0, 1))
            shadowUniforms.sunDir = sunDir
            shadowUniforms.sunIntensity = sun.colorIntensity.w
            shadowUniforms.sunColor = SIMD4<Float>(sun.colorIntensity.x, sun.colorIntensity.y, sun.colorIntensity.z, 1)
            enc.setVertexBytes(&shadowUniforms, length: MemoryLayout<WorldUniforms>.stride, index: 1)

            let draws = UnsafeBufferPointer(start: drawsPtr, count: Int(snapshot.worldCommandCount))
            let skyFlagBit = UInt32(Q3_METAL_WORLD_DRAWFLAG_SKY)
            let fogOnlyBit = UInt32(Q3_METAL_WORLD_DRAWFLAG_FOG_ONLY)
            var castDraws = 0
            for draw in draws {
                if draw.indexCount == 0 || (draw.flags & skyFlagBit) != 0 || (draw.flags & fogOnlyBit) != 0 { continue }
                let stageCount = min(Int(draw.stageCount), Int(Q3_METAL_MAX_STAGES))
                if stageCount <= 0 { continue }
                var castStage: Q3MetalWorldStage? = nil
                for i in 0..<stageCount {
                    let st = Self.worldStage(draw, i)
                    if st.useLightmap == 0 && Self.worldRenderPass(for: st) == 0 {
                        castStage = st
                        break
                    }
                }
                guard let stage = castStage else { continue }
                let (tv0, tv1) = Self.tcGenVectors(stage)
                var drawUniforms = WorldDrawUniforms(
                    tcGen: Float(stage.tcGen),
                    tcModCount: 0,
                    rgbGen: Float(stage.rgbGen),
                    alphaGen: Float(stage.alphaGen),
                    blendMode: 0,
                    timeSeconds: snapshot.shaderTime,
                    rgbWaveFunc: stage.rgbWaveFunc,
                    alphaWaveFunc: stage.alphaWaveFunc,
                    tcModType: SIMD4<Float>(0, 0, 0, 0),
                    tcModParams0: SIMD4<Float>(0, 0, 0, 0),
                    tcModParams1: SIMD4<Float>(0, 0, 0, 0),
                    tcModParams2: SIMD4<Float>(0, 0, 0, 0),
                    tcModParams3: SIMD4<Float>(0, 0, 0, 0),
                    rgbWaveParams: SIMD4(stage.rgbWaveBase, stage.rgbWaveAmp, stage.rgbWavePhase, stage.rgbWaveFreq),
                    alphaWaveParams: SIMD4(stage.alphaWaveBase, stage.alphaWaveAmp, stage.alphaWavePhase, stage.alphaWaveFreq),
                    rgbConstColor: SIMD4(stage.rgbConstColor.0, stage.rgbConstColor.1, stage.rgbConstColor.2, stage.alphaConst),
                    entityColor: SIMD4(1, 1, 1, 1),
                    fogColorDistance: SIMD4<Float>(0, 0, 0, 0),
                    tcGenVec0: tv0,
                    tcGenVec1: tv1,
                    deformWaveFunc: stage.deformWaveFunc,
                    deformWaveDiv: stage.deformWaveDiv != 0 ? stage.deformWaveDiv : 1.0,
                    deformWaveBase: stage.deformWaveBase,
                    deformWaveAmp: stage.deformWaveAmp,
                    deformWavePhase: stage.deformWavePhase,
                    deformWaveFreq: stage.deformWaveFreq,
                    deformMoveFunc: stage.deformMoveFunc,
                    deformMoveVector: SIMD3(stage.deformMoveVector.0, stage.deformMoveVector.1, stage.deformMoveVector.2),
                    deformMoveBase: stage.deformMoveBase,
                    deformMoveAmp: stage.deformMoveAmp,
                    deformMovePhase: stage.deformMovePhase,
                    deformMoveFreq: stage.deformMoveFreq,
                    deformBulgeWidth: stage.deformBulgeWidth,
                    deformBulgeHeight: stage.deformBulgeHeight,
                    deformBulgeSpeed: stage.deformBulgeSpeed,
                    autospriteMode: 0,
                    debugMode: 0,
                    forceWhiteVertColor: 0,
                    alphaTestThreshold: 0,
                    fogOnly: 0,
                    stageUsesLightmap: 0,
                    drawHasLightmapStage: 0,
                    pbrRoughness: stage.pbrRoughness,
                    pbrMetallic: stage.pbrMetallic,
                    _pad0: 0)
                enc.setCullMode(Self.metalCullMode(for: stage.cullMode))
                enc.setVertexBytes(&drawUniforms, length: MemoryLayout<WorldDrawUniforms>.stride, index: 2)
                enc.drawIndexedPrimitives(type: .triangle,
                                          indexCount: Int(draw.indexCount),
                                          indexType: .uint32,
                                          indexBuffer: worldIndexBuffer,
                                          indexBufferOffset: Int(draw.firstIndex) * MemoryLayout<UInt32>.stride)
                castDraws += 1
            }
            enc.endEncoding()
            let mapKey = rtLightMapName.isEmpty ? "<unknown>" : rtLightMapName
            if sunShadowLoggedMaps.insert(mapKey).inserted {
                pbrLog("[Q3-SUNSHADOW] map='\(mapKey)' size=\(shadowTexture.width)x\(shadowTexture.height) casters=\(castDraws) sunDir=(\(sunDir.x),\(sunDir.y),\(sunDir.z))")
            }
            return (shadowTexture, shadowMatrix)
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
            // q3_entity_fragment is shared with full entity PBR draws. Flares
            // are classic additive billboards, but Metal API validation still
            // requires every declared fragment resource that the function may
            // read to be bound. Mirror the sub-scene/entity default no-op
            // bindings so q3dm4 flare-heavy maps do not assert under
            // MTL_DEBUG_LAYER.
            encoder.setFragmentTexture(pbrFlatNormalDefault(), index: 1)
            encoder.setFragmentTexture(pbrRoughnessDefault(), index: 3)
            encoder.setFragmentTexture(pbrMetallicDefault(), index: 4)
            encoder.setFragmentTexture(ensurePBREnvCube(), index: 5)
            encoder.setFragmentTexture(pbrEmissiveDefault(), index: 6)
            encoder.setFragmentSamplerState(ensurePBREnvSampler(), index: 1)
            var pbrNormalScaleFlare: Float = 0.0
            encoder.setFragmentBytes(&pbrNormalScaleFlare, length: 4, index: 3)
            var pbrRimParamsFlare = SIMD2<Float>(0.0, Q3_PBRRimFalloff())
            encoder.setFragmentBytes(&pbrRimParamsFlare, length: 8, index: 4)
            // q3_entity_fragment declares the dlight block at buffer(2).
            // It is suppressed for flares, but binding defensively keeps
            // capture/validation state consistent with other entity draws.
            Self.bindDlightBlock(snapshot: snapshot, encoder: encoder, device: device, index: 2, extra: currentBakedDlights())

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
    private var activeMouse: GCMouse?
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
        if #available(iOS 14.0, *) {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(mouseDidConnect(_:)),
                name: .GCMouseDidConnect,
                object: nil
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(mouseDidDisconnect(_:)),
                name: .GCMouseDidDisconnect,
                object: nil
            )
        }

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
        if #available(iOS 14.0, *) {
            pickActiveMouse()
        }
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

    @available(iOS 14.0, *)
    @objc private func mouseDidConnect(_ notification: Notification) {
        if let mouse = notification.object as? GCMouse {
            print("[GCMouse] connected \(mouse.vendorName ?? "unknown")")
            pickActiveMouse(preferred: mouse)
        } else {
            print("[GCMouse] connected unknown mouse")
            pickActiveMouse()
        }
    }

    @available(iOS 14.0, *)
    @objc private func mouseDidDisconnect(_ notification: Notification) {
        let mouse = notification.object as? GCMouse
        if activeMouse === mouse {
            activeMouse?.mouseInput?.mouseMovedHandler = nil
            activeMouse?.mouseInput?.leftButton.pressedChangedHandler = nil
            activeMouse?.mouseInput?.rightButton?.pressedChangedHandler = nil
            activeMouse?.mouseInput?.middleButton?.pressedChangedHandler = nil
            activeMouse = nil
        }
        if let mouse {
            print("[GCMouse] disconnected \(mouse.vendorName ?? "unknown")")
        }
        pickActiveMouse()
    }

    @available(iOS 14.0, *)
    private func pickActiveMouse(preferred: GCMouse? = nil) {
        let nextMouse = preferred ?? activeMouse ?? GCMouse.mice().first
        guard activeMouse !== nextMouse else { return }

        activeMouse?.mouseInput?.mouseMovedHandler = nil
        activeMouse?.mouseInput?.leftButton.pressedChangedHandler = nil
        activeMouse?.mouseInput?.rightButton?.pressedChangedHandler = nil
        activeMouse?.mouseInput?.middleButton?.pressedChangedHandler = nil
        activeMouse = nextMouse

        guard let mouse = nextMouse, let input = mouse.mouseInput else {
            print("[GCMouse] no mouse/trackpad selected")
            return
        }

        input.mouseMovedHandler = { _, deltaX, deltaY in
            let scale: Float = 1.35
            let dx = Int32((deltaX * scale).rounded())
            let dy = Int32((-deltaY * scale).rounded())
            if dx != 0 || dy != 0 {
                Q3Sys_MouseMove(dx, dy)
            }
        }
        input.leftButton.pressedChangedHandler = { _, _, pressed in
            Q3Sys_KeyEvent(178, pressed ? 1 : 0) // K_MOUSE1
        }
        input.rightButton?.pressedChangedHandler = { _, _, pressed in
            Q3Sys_KeyEvent(179, pressed ? 1 : 0) // K_MOUSE2
        }
        input.middleButton?.pressedChangedHandler = { _, _, pressed in
            Q3Sys_KeyEvent(180, pressed ? 1 : 0) // K_MOUSE3
        }
        print("[GCMouse] using \(mouse.vendorName ?? "unknown")")
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
        isUserInteractionEnabled = true

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

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        _ = becomeFirstResponder()
        super.touchesBegan(touches, with: event)
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
            if key.keyCode == .keyboardGraveAccentAndTilde {
                // Desktop Q3 uses pseudo-key K_CONSOLE, not ASCII '`'.
                Q3Sys_KeyEvent(275, 1) // K_CONSOLE
                handled = true
                continue
            }
            if key.keyCode == .keyboardDeleteOrBackspace {
                /*
                 * Q3's edit fields handle backspace through SE_CHAR ctrl-H
                 * (0x08), not through the K_BACKSPACE key event. CL_CharEvent
                 * explicitly drops 0x7f and Field_KeyDownEvent only handles
                 * K_DEL as forward-delete. Magic Keyboard's Delete key was
                 * therefore reaching Q3 as a key press but never deleting text
                 * in the console. Emit ctrl-H on key-down, while still sending
                 * K_BACKSPACE below for bind compatibility.
                 */
                Q3Sys_CharEvent(8)
            }
            if let q3 = Q3InputView.q3Keycode(for: key) {
                Q3Sys_KeyEvent(q3, 1)
                handled = true
            }
            // Fire SE_CHAR for printable characters so console / cvar
            // value / player-name fields receive actual text. Use
            // `characters` (NOT charactersIgnoringModifiers) so shift
            // produces capitals and shifted symbols ("A", "!", "@", …).
            //
            // CRITICAL: only single-character keys produce text. Arrow keys,
            // F-keys, etc. report a MULTI-CHARACTER marker string in
            // `key.characters` (e.g. up-arrow = "UIInputUpArrow") whose letters
            // all pass the printable bounds check — so without the count==1
            // guard, pressing Up typed "UIInputUpArrow" into the console and
            // swallowed K_UPARROW history recall (forcing manual delete spam).
            // Single-char guard lets real text through while the navigation key
            // event above (e.g. K_UPARROW=132) drives console history.
            if key.characters.count == 1 {
                for ch in key.characters.unicodeScalars {
                    let v = ch.value
                    if v >= 32 && v < 127 {
                        Q3Sys_CharEvent(Int32(v))
                    }
                }
            }
        }
        if !handled { super.pressesBegan(presses, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            if let key = press.key, key.keyCode == .keyboardGraveAccentAndTilde {
                Q3Sys_KeyEvent(275, 0) // K_CONSOLE
                handled = true
            } else if let key = press.key, let q3 = Q3InputView.q3Keycode(for: key) {
                Q3Sys_KeyEvent(q3, 0)
                handled = true
            }
        }
        if !handled { super.pressesEnded(presses, with: event) }
    }

    /// Map iOS `UIKey` to a Q3 keycode. Values mirror
    /// `code/client/keycodes.h`:
    /// - ASCII for letters/digits/punctuation (Q3's K_A..K_Z = 'a'..'z')
    /// - 9 K_TAB, 13 K_ENTER, 27 K_ESCAPE, 32 K_SPACE
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
        // keyboardDeleteForward — Q3's Field_KeyDownEvent handles that as
        // K_DEL (forward delete), not K_BACKSPACE.
        case .keyboardDeleteForward: return 140
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
