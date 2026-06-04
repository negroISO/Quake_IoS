import SwiftUI
import Foundation
import os
import Darwin

private final class Quake3OrientationDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        return .landscape
    }
}

@main
struct Quake3_iOSApp: App {
    static let log = OSLog(subsystem: "com.quake3ios.app", category: "boot")
    private static let telemetrySource = "quake3-ios"
    @UIApplicationDelegateAdaptor(Quake3OrientationDelegate.self) private var orientationDelegate

    init() {
        // Disable stdout buffering so [Swift] print()s land in
        // devicectl --console immediately rather than getting eaten
        // by USB line-buffering when the app crashes mid-init.
        setbuf(stdout, nil)
        NSLog("[Q3-BOOT] App init")
#if DEBUG
        let telemetryHost = ProcessInfo.processInfo.environment["Q3_TELEMETRY_HOST"] ?? "192.168.0.197"
        let telemetryPort = UInt16(ProcessInfo.processInfo.environment["Q3_TELEMETRY_PORT"] ?? "8765") ?? 8765
        DebugTelemetry.shared.connect(host: telemetryHost, port: telemetryPort, source: Self.telemetrySource)
        DebugTelemetry.shared.log(source: Self.telemetrySource, type: "boot", message: "app init", fields: [
            "host": telemetryHost,
            "port": Int(telemetryPort)
        ])
#endif
    }
    /// nil = launch menu visible. Non-nil = engine should boot and
    /// queue this Q3 console command (e.g. "demo four", "map q3dm6").
    @State private var launchCommand: String? = ProcessInfo.processInfo.environment["Q3_LAUNCH_COMMAND"]
    @State private var engineStarted = false
    /// True while `Quake3_Init` is running. Drives the "Loading…" overlay
    /// so the user gets feedback during the synchronous (~5–30s) engine
    /// init instead of staring at a black MetalView while the main thread
    /// is blocked.
    @State private var engineLoading = false

    @MainActor
    private static func requestLandscapeSceneGeometry() {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first else {
            return
        }
        scene.windows.first?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        if #available(iOS 16.0, *) {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight)) { error in
                NSLog("[Q3-BOOT] landscape request failed: %@", String(describing: error))
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            ZStack(alignment: .topLeading) {
                if launchCommand == nil {
                    LaunchMenuView(launchCommand: $launchCommand)
                } else {
                    MetalView()
                        .ignoresSafeArea()
                        .task {
                            NSLog("[Q3-BOOT] .task entered (engineStarted=%d)", engineStarted ? 1 : 0)
                            DebugTelemetry.shared.log(source: Self.telemetrySource, type: "engine_task_entered", fields: [
                                "engineStarted": engineStarted,
                                "launchCommand": launchCommand ?? ""
                            ])
                            guard !engineStarted else {
                                DebugTelemetry.shared.log(source: Self.telemetrySource, type: "engine_task_skipped", message: "engine already started")
                                return
                            }
                            engineStarted = true
                            engineLoading = true
                            DebugTelemetry.shared.log(source: Self.telemetrySource, type: "engine_loading", message: "true")
                            NSLog("[Q3-BOOT] yielding 200ms for LoadingOverlay paint")
                            try? await Task.sleep(nanoseconds: 200_000_000)
                            NSLog("[Q3-BOOT] starting GameControllerBridge")
                            DebugTelemetry.shared.log(source: Self.telemetrySource, type: "controller_bridge_start")
                            GameControllerBridge.shared.start()
                            let basePath = Bundle.main.resourcePath ?? ""

                            /* MetalFX upscale render-resolution injection.
                             * The launcher quality picker persists into
                             * UserDefaults; we read it here BEFORE
                             * Quake3_Init runs, compute the input render
                             * size relative to the drawable target
                             * (iPhone: 1920×888, iPad: 2560×1920), and
                             * call Q3_SetRenderResolution() so ios_main.m's
                             * cmdline gets r_customwidth/r_customheight
                             * matching the offscreen RT the Coordinator
                             * will allocate. Native quality clears the
                             * override (0,0) → engine uses the default
                             * native-target sizing path. */
                            let quality = Q3UpscaleQuality.current
                            // True device-native pixel dimensions in
                            // landscape orientation. iPhone 17 Pro Max =
                            // 2868×1320, iPad Pro 13" M4 = 2752×2064.
                            // UIScreen.nativeBounds reports portrait; we
                            // swap with max/min so width is the long axis.
                            let nb = UIScreen.main.nativeBounds.size
                            let outputW = max(nb.width, nb.height)
                            let outputH = min(nb.width, nb.height)
                            let outputSize = CGSize(width: outputW, height: outputH)
                            if quality != .native {
                                let rs = quality.renderSize(forOutput: outputSize)
                                let w = Int32(rs.width)
                                let h = Int32(rs.height)
                                NSLog("[Q3-BOOT] MetalFX quality=%@ render=%dx%d (output target %dx%d native)",
                                      quality.label, w, h, Int32(outputW), Int32(outputH))
                                Q3_SetRenderResolution(w, h)
                            } else {
                                // Native quality: render at true device
                                // pixels — no MetalFX, no Core Animation
                                // upscale. The drawableSize lock below
                                // will also pin to native bounds.
                                let w = Int32(outputW)
                                let h = Int32(outputH)
                                NSLog("[Q3-BOOT] MetalFX quality=Native render=%dx%d (true native, no upscale)", w, h)
                                Q3_SetRenderResolution(w, h)
                            }

                            // Log RT overlay choice so the user can confirm
                            // UserDefaults / env var was read. The actual cvar
                            // is queued after Quake3_Init below because the cvar
                            // system does not exist before engine startup.
                            let rtMix = Q3RTMix.current
                            NSLog("[Q3-BOOT] RT mix = %@", rtMix.rawValue)

                            // Log frame-interpolation choice so the user
                            // can confirm UserDefaults / env var was read.
                            let frameInterp = Q3FrameInterpolation.current
                            NSLog("[Q3-BOOT] MetalFX frame interpolation = %@", frameInterp.label)

                            /* Parse "mod:<name>|<command>" prefix from
                             * launchCommand (LaunchMenuView mod rows
                             * encode this). When present, call
                             * Q3_SetBootMod BEFORE Quake3_Init so
                             * ios_main.m can bake +set fs_game <name>
                             * into the Com_Init cmdline. The actual map
                             * command (after the pipe) is queued
                             * post-init below via Q3Exec_Command. */
                            if let cmd = launchCommand, cmd.hasPrefix("mod:") {
                                let trimmed = cmd.dropFirst(4)
                                if let pipeIdx = trimmed.firstIndex(of: "|") {
                                    let modName = String(trimmed[..<pipeIdx])
                                    let postCmd = String(trimmed[trimmed.index(after: pipeIdx)...])
                                    NSLog("[Q3-BOOT] mod-prefix detected mod=%@ post=%@", modName, postCmd)
                                    DebugTelemetry.shared.log(source: Self.telemetrySource, type: "mod_select", message: modName, fields: [
                                        "modName": modName,
                                        "postCommand": postCmd
                                    ])
                                    modName.withCString { Q3_SetBootMod($0) }
                                    // Replace launchCommand with just
                                    // the post-pipe portion so the
                                    // post-init queueing block fires
                                    // the map/demo command unmodified.
                                    launchCommand = postCmd
                                }
                            }
                            NSLog("[Q3-BOOT] dispatching Quake3_Init to background queue")
                            DebugTelemetry.shared.log(source: Self.telemetrySource, type: "engine_init_dispatch", fields: [
                                "basePath": basePath
                            ])
                            print("[Swift] Starting Quake3 engine, basePath: \(basePath)")
                            // Run Quake3_Init on a background queue so the
                            // main thread stays responsive. iOS will SIGKILL
                            // a foreground app whose main thread blocks long
                            // enough that no drawables get presented (~20s
                            // on iPad with its 2752×2064 drawable + cold
                            // Metal shader cache; iPhone init is faster and
                            // squeaks under the threshold). Engine init is
                            // pure C state setup — no UIKit/Metal main-thread
                            // requirements until rendering begins. The
                            // MTKView's draw(in:) keeps rendering the
                            // LoadingOverlay while we wait.
                            let telemetrySource = Self.telemetrySource
                            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                                DispatchQueue.global(qos: .userInitiated).async {
                                    // PBR Phase C — start audio backend BEFORE
                                    // Quake3_Init so the sample rate negotiated
                                    // with AVAudioSession is set when the engine's
                                    // S_Init eventually calls SNDDMA_Init.
                                    Q3AudioManager.shared.start()
                                    NSLog("[Q3-BOOT] (bg) calling Quake3_Init")
                                    DebugTelemetry.shared.log(source: telemetrySource, type: "engine_init_begin")
                                    Quake3_Init(basePath)
                                    NSLog("[Q3-BOOT] (bg) Quake3_Init returned")
                                    DebugTelemetry.shared.log(source: telemetrySource, type: "engine_init_end")
                                    cont.resume()
                                }
                            }
                            NSLog("[Q3-BOOT] back on main; engine ready")
                            DebugTelemetry.shared.log(source: Self.telemetrySource, type: "engine_ready")
                            print("[Swift] Engine initialized")
                            let rtLine = rtMix.consoleCommand + "\n"
                            NSLog("[Q3-BOOT] queuing RT cvar: %@", rtMix.consoleCommand)
                            rtLine.withCString { Q3Exec_Command($0) }
                            if let cmd = launchCommand {
                                let line = cmd + "\n"
                                NSLog("[Q3-BOOT] queuing command: %@", cmd)
                                DebugTelemetry.shared.log(source: Self.telemetrySource, type: "command_queue", message: cmd)
                                line.withCString { Q3Exec_Command($0) }
                                print("[Swift] Queued: \(cmd)")
                            }
                            engineLoading = false
                            DebugTelemetry.shared.log(source: Self.telemetrySource, type: "engine_loading", message: "false")
                            NSLog("[Q3-BOOT] engineLoading=false; SwiftUI should hide overlay")
                        }

                    if engineLoading {
                        LoadingOverlay(target: launchCommand ?? "")
                    }
                }
            }
            .statusBarHidden(true)
            .persistentSystemOverlays(.hidden)
            .onAppear {
                Self.requestLandscapeSceneGeometry()
            }
        }
    }
}

/// Full-screen translucent black overlay shown while `Quake3_Init` runs.
/// `Quake3_Init` is synchronous and blocks the main thread for several
/// seconds (~5s iPhone, can be 30s+ on a fresh iPad install while the
/// Metal shader cache warms). Without this overlay the user only sees a
/// black MetalView with no indication progress is happening; on slower
/// devices that can look like a hang. The overlay is replaced as soon as
/// the engine finishes init and SwiftUI re-renders.
private struct LoadingOverlay: View {
    let target: String

    var body: some View {
        ZStack {
            Color.black.opacity(0.85)
                .ignoresSafeArea()
            VStack(spacing: 18) {
                Text("LOADING")
                    .font(.system(size: 36, weight: .black, design: .serif))
                    .foregroundColor(.white)
                    .tracking(8)
                    .shadow(color: .red.opacity(0.7), radius: 6)
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white)
                Text(target.isEmpty ? "Initializing engine…" : "→ \(target)")
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundColor(.white.opacity(0.7))
                Text("First launch may take up to 30 seconds")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.white.opacity(0.4))
            }
        }
    }
}
