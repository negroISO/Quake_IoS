import SwiftUI

/// Pre-game launch menu. Appears before the engine boots; on tap it
/// signals the parent App to switch to MetalView and queue the chosen
/// command into the boot cbuf.
///
/// Sources of demos:
/// - Bundle's `baseq3/demos/*.dm_*` (anything we ship in
///   `Resources/baseq3/demos/`)
/// - Documents' `baseq3/demos/*.dm_*` (anything pushed via
///   `q3dev_run.sh`'s seed step or sideloaded via Files app)
/// - The stock `four` demo from pak0 (always assumed present —
///   pak0 ships demos/four.dm_66)
struct LaunchMenuView: View {
    /// Set by a tap. Parent App watches this and, when non-nil,
    /// boots the engine with the chosen Q3 command (e.g.
    /// "demo nv15demo" or "map q3dm6").
    @Binding var launchCommand: String?

    @State private var demoFiles: [DemoEntry] = []

    struct DemoEntry: Identifiable, Hashable {
        let id = UUID()
        /// Demo name without extension, what `demo <name>` expects.
        let name: String
        /// Source label for the row subtitle.
        let source: String
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // Quake 3 background. Silently no-ops if the asset
            // didn't get bundled — falls through to the black
            // ZStack base.
            Image("quake_3_background")
                .resizable()
                .aspectRatio(contentMode: .fill)
                .ignoresSafeArea()
                .opacity(0.55)

            VStack(spacing: 24) {
                Spacer().frame(height: 40)

                Text("QUAKE III")
                    .font(.system(size: 44, weight: .black, design: .serif))
                    .foregroundColor(.white)
                    .shadow(color: .red.opacity(0.8), radius: 8, x: 0, y: 0)
                    .tracking(6)

                Text("ARENA")
                    .font(.system(size: 28, weight: .heavy, design: .serif))
                    .foregroundColor(.white.opacity(0.85))
                    .tracking(8)
                    .padding(.top, -16)

                Spacer().frame(height: 8)

                ScrollView {
                    VStack(spacing: 12) {
                        // Stock demo always available
                        DemoButton(title: "Demo: four (Q3 default)",
                                   subtitle: "Stock pak0 — Camping Grounds (q3dm6)") {
                            launchCommand = "demo four"
                        }

                        ForEach(demoFiles) { d in
                            DemoButton(title: "Demo: \(d.name)",
                                       subtitle: d.source) {
                                launchCommand = "demo \(d.name)"
                            }
                        }

                        Divider()
                            .background(Color.white.opacity(0.3))
                            .padding(.vertical, 8)

                        // Quick-launch maps. Bots not added here yet —
                        // Scope B will grow this into a proper match
                        // setup screen.
                        DemoButton(title: "Map: q3dm1",
                                   subtitle: "Arena Gate") {
                            launchCommand = "map q3dm1"
                        }
                        DemoButton(title: "Map: q3dm6",
                                   subtitle: "Camping Grounds") {
                            launchCommand = "map q3dm6"
                        }
                        DemoButton(title: "Map: nv15",
                                   subtitle: "Area 15 — Nvidia Bunker (custom pk3)") {
                            launchCommand = "map nv15"
                        }
                    }
                    .padding(.horizontal, 24)
                    .frame(maxWidth: 560)
                    .frame(maxWidth: .infinity, alignment: .center)
                }

                Spacer()
            }
        }
        .task {
            demoFiles = Self.discoverDemos()
        }
    }

    /// Walks the bundle's `Resources/baseq3/demos` and the Documents'
    /// `baseq3/demos`, collects unique `.dm_*` filenames, and returns
    /// them as `DemoEntry` rows. Stock `four.dm_66` is excluded — it's
    /// pinned as the first row above.
    private static func discoverDemos() -> [DemoEntry] {
        var seen: Set<String> = ["four"]
        var out: [DemoEntry] = []

        // Bundle path
        if let bundleBase = Bundle.main.resourcePath {
            let bundleDemos = bundleBase + "/baseq3/demos"
            if let names = try? FileManager.default.contentsOfDirectory(atPath: bundleDemos) {
                for n in names where n.contains(".dm_") {
                    let base = String(n.split(separator: ".").first ?? "")
                    if !base.isEmpty && !seen.contains(base) {
                        seen.insert(base)
                        out.append(DemoEntry(name: base, source: "Bundled (\(n))"))
                    }
                }
            }
        }

        // Documents path (sideloaded via q3dev_run.sh seed step or
        // Files app drag-drop).
        let docs = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first ?? ""
        let docDemos = docs + "/baseq3/demos"
        if let names = try? FileManager.default.contentsOfDirectory(atPath: docDemos) {
            for n in names where n.contains(".dm_") {
                let base = String(n.split(separator: ".").first ?? "")
                if !base.isEmpty && !seen.contains(base) {
                    seen.insert(base)
                    out.append(DemoEntry(name: base, source: "User (\(n))"))
                }
            }
        }

        return out.sorted { $0.name < $1.name }
    }
}

private struct DemoButton: View {
    let title: String
    let subtitle: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 17, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                    Text(subtitle)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.white.opacity(0.6))
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundColor(.white.opacity(0.6))
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.black.opacity(0.55))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color(red: 0.7, green: 0.15, blue: 0.1).opacity(0.85), lineWidth: 1.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
