import SwiftUI

@main
struct Quake3_iOSApp: App {
    @State private var engineStarted = false

    var body: some Scene {
        WindowGroup {
            MetalView()
                .ignoresSafeArea()
                .task {
                    guard !engineStarted else { return }
                    engineStarted = true
                    startEngine()
                }
        }
    }

    private func startEngine() {
        let basePath = Bundle.main.resourcePath ?? ""
        print("[Swift] Starting Quake3 engine, basePath: \(basePath)")
        Quake3_Init(basePath)
        print("[Swift] Engine initialized")
    }
}
