import SwiftUI
import os

@main
struct Quake3_iOSApp: App {
    static let log = OSLog(subsystem: "com.quake3ios.app", category: "boot")
    init() {
        // Disable stdout buffering so [Swift] print()s land in
        // devicectl --console immediately rather than getting eaten
        // by USB line-buffering when the app crashes mid-init.
        setbuf(stdout, nil)
        NSLog("[Q3-BOOT] App init")
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
                            guard !engineStarted else { return }
                            engineStarted = true
                            engineLoading = true
                            NSLog("[Q3-BOOT] yielding 200ms for LoadingOverlay paint")
                            try? await Task.sleep(nanoseconds: 200_000_000)
                            NSLog("[Q3-BOOT] starting GameControllerBridge")
                            GameControllerBridge.shared.start()
                            let basePath = Bundle.main.resourcePath ?? ""
                            NSLog("[Q3-BOOT] dispatching Quake3_Init to background queue")
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
                            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                                DispatchQueue.global(qos: .userInitiated).async {
                                    NSLog("[Q3-BOOT] (bg) calling Quake3_Init")
                                    Quake3_Init(basePath)
                                    NSLog("[Q3-BOOT] (bg) Quake3_Init returned")
                                    cont.resume()
                                }
                            }
                            NSLog("[Q3-BOOT] back on main; engine ready")
                            print("[Swift] Engine initialized")
                            if let cmd = launchCommand {
                                let line = cmd + "\n"
                                NSLog("[Q3-BOOT] queuing command: %@", cmd)
                                line.withCString { Q3Exec_Command($0) }
                                print("[Swift] Queued: \(cmd)")
                            }
                            engineLoading = false
                            NSLog("[Q3-BOOT] engineLoading=false; SwiftUI should hide overlay")
                        }

                    if engineLoading {
                        LoadingOverlay(target: launchCommand ?? "")
                    }
                }
            }
            .statusBarHidden(true)
            .persistentSystemOverlays(.hidden)
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
