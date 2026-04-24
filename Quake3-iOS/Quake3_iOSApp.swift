import SwiftUI

@main
struct Quake3_iOSApp: App {
    @State private var engineStarted = false

    var body: some Scene {
        WindowGroup {
            ZStack(alignment: .topLeading) {
                MetalView()
                    .ignoresSafeArea()

                // Console button temporarily disabled so ground-truth
                // visual diffs don't flag the blue ">_" overlay as a
                // rendering bug. Re-enable when dev console access is
                // needed on-device.
                // ConsoleOverlay()
            }
            .statusBarHidden(true)
            .persistentSystemOverlays(.hidden)
            .task {
                guard !engineStarted else { return }
                engineStarted = true

                GameControllerBridge.shared.start()

                let basePath = Bundle.main.resourcePath ?? ""
                print("[Swift] Starting Quake3 engine, basePath: \(basePath)")
                Quake3_Init(basePath)
                print("[Swift] Engine initialized")
            }
        }
    }
}

/// Minimal on-screen console for iOS when no physical keyboard is attached.
/// Small corner tap-target opens a centered text field that routes commands
/// into the Q3 command buffer via `Q3Exec_Command`. Press Return (or tap
/// the × button) to dismiss. Both `cvar value` and plain `command arg`
/// forms work — same syntax as the normal Q3 console.
struct ConsoleOverlay: View {
    @State private var isOpen: Bool = false
    @State private var text: String = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Small always-visible toggle in the upper-left corner.
            Button(action: {
                isOpen.toggle()
                if isOpen {
                    // Focus on the next run-loop tick so the TextField
                    // has been added to the hierarchy before we focus it.
                    DispatchQueue.main.async { fieldFocused = true }
                }
            }) {
                Text(">_")
                    .font(.system(size: 22, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color(red: 0.12, green: 0.42, blue: 0.86))   // bright blue so
                    .cornerRadius(8)                                          // it stands out on
                    .overlay(                                                 // any dark scene
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.white.opacity(0.9), lineWidth: 1.5)
                    )
                    .shadow(color: Color.black.opacity(0.6), radius: 3, x: 0, y: 2)
            }
            .accessibilityLabel("Toggle console")

            if isOpen {
                HStack(spacing: 6) {
                    TextField("cvar or command", text: $text)
                        .font(.system(size: 14, design: .monospaced))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(Color.black.opacity(0.75))
                        .foregroundColor(.white)
                        .cornerRadius(4)
                        .focused($fieldFocused)
                        .autocorrectionDisabled(true)
                        .textInputAutocapitalization(.never)
                        .submitLabel(.send)
                        .onSubmit { submit() }
                        .frame(minWidth: 220, idealWidth: 320, maxWidth: 480)

                    Button(action: submit) {
                        Text("run")
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundColor(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.blue.opacity(0.8))
                            .cornerRadius(4)
                    }

                    Button(action: { isOpen = false; fieldFocused = false }) {
                        Text("×")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.red.opacity(0.7))
                            .cornerRadius(4)
                    }
                }
            }
        }
        .padding(.top, 12)
        .padding(.leading, 12)
    }

    private func submit() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        trimmed.withCString { Q3Exec_Command($0) }
        text = ""
        // Keep focus so the user can chain commands without re-tapping.
    }
}
