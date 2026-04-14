import SwiftUI
import GameController
import UIKit

@main
struct Quake3_iOSApp: App {
    @State private var engineStarted = false

    var body: some Scene {
        WindowGroup {
            GameRootView(engineStarted: $engineStarted)
                .ignoresSafeArea()
        }
    }
}

private struct GameRootView: UIViewControllerRepresentable {
    @Binding var engineStarted: Bool

    func makeUIViewController(context: Context) -> GCEventViewController {
        let viewController = GCEventViewController()
        viewController.controllerUserInteractionEnabled = false
        viewController.view.backgroundColor = .black

        let hostingController = UIHostingController(rootView: MetalView())
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        hostingController.view.backgroundColor = .black

        viewController.addChild(hostingController)
        viewController.view.addSubview(hostingController.view)
        NSLayoutConstraint.activate([
            hostingController.view.leadingAnchor.constraint(equalTo: viewController.view.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: viewController.view.trailingAnchor),
            hostingController.view.topAnchor.constraint(equalTo: viewController.view.topAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: viewController.view.bottomAnchor),
        ])
        hostingController.didMove(toParent: viewController)

        context.coordinator.startIfNeeded(engineStarted: $engineStarted)
        return viewController
    }

    func updateUIViewController(_ uiViewController: GCEventViewController, context: Context) {
        context.coordinator.startIfNeeded(engineStarted: $engineStarted)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        private var didStart = false

        @MainActor
        func startIfNeeded(engineStarted: Binding<Bool>) {
            guard !didStart, !engineStarted.wrappedValue else { return }
            didStart = true
            engineStarted.wrappedValue = true

            GameControllerBridge.shared.start()

            let basePath = Bundle.main.resourcePath ?? ""
            print("[Swift] Starting Quake3 engine, basePath: \(basePath)")
            Quake3_Init(basePath)
            print("[Swift] Engine initialized")
        }
    }
}
