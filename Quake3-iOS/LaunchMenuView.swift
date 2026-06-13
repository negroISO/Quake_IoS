import SwiftUI
import Foundation

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
    private static let telemetrySource = "quake3-ios"

    /// Set by a tap. Parent App watches this and, when non-nil,
    /// boots the engine with the chosen Q3 command (e.g.
    /// "demo nv15demo" or "map q3dm6").
    @Binding var launchCommand: String?

    @State private var demoFiles: [DemoEntry] = []
    @State private var selectedRTMix: Q3RTMix = Q3RTMix.current
    @State private var selectedQuality: Q3UpscaleQuality = Q3UpscaleQuality.current
    @State private var selectedFrameInterp: Q3FrameInterpolation = Q3FrameInterpolation.current

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

            VStack(spacing: 12) {
                Spacer().frame(height: 12)

                // Title — kept compact so the picker rows + the
                // scrollable demo/map list all fit on a single phone
                // screen in landscape. Was 44pt + Spacer(40) above + 24
                // between rows; the Frame Interpolation row pushed the
                // ScrollView entirely off-screen so the user lost access
                // to demos/maps. Tightened the whole header so the
                // ScrollView fits below without scrolling the picker UI
                // itself off-screen.
                HStack(spacing: 12) {
                    Text("QUAKE III")
                        .font(.system(size: 28, weight: .black, design: .serif))
                        .foregroundColor(.white)
                        .shadow(color: .red.opacity(0.8), radius: 6, x: 0, y: 0)
                        .tracking(4)
                    Text("ARENA")
                        .font(.system(size: 18, weight: .heavy, design: .serif))
                        .foregroundColor(.white.opacity(0.85))
                        .tracking(6)
                }

                // Ray-tracing overlay mix picker. Persisted via
                // UserDefaults; Quake3_iOSApp queues `r_rt_mix` after
                // engine init so this controls raster-only, blended A/B,
                // or pure RT output at launch. Placed above MetalFX so RT
                // mode is chosen before output scaling options.
                HStack(spacing: 8) {
                    ForEach(Q3RTMix.allCases, id: \.self) { rt in
                        let isSelected = (selectedRTMix == rt)
                        Button(action: {
                            selectedRTMix = rt
                            Q3RTMix.save(rt)
                            NSLog("[Q3-MENU] RT mix = %@", rt.rawValue)
                        }) {
                            VStack(spacing: 2) {
                                Text(rt.label)
                                    .font(.system(size: 13, weight: .heavy, design: .monospaced))
                                    .foregroundColor(.white)
                                Text(rt.subtitle)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(.white.opacity(0.6))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(isSelected ? Color(red: 0.7, green: 0.15, blue: 0.1).opacity(0.85)
                                                     : Color.black.opacity(0.55))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color(red: 0.7, green: 0.15, blue: 0.1).opacity(isSelected ? 1.0 : 0.5),
                                            lineWidth: isSelected ? 2 : 1)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: 560)
                .padding(.horizontal, 24)

                Text("Ray Tracing Overlay")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.white.opacity(0.55))
                    .padding(.top, -10)

                // MetalFX upscale quality picker. Persisted via
                // UserDefaults; Quake3_iOSApp.swift reads it on engine
                // boot and calls Q3_SetRenderResolution() so the engine
                // cmdline gets r_customwidth/height = the chosen input
                // resolution. The MetalView Coordinator allocates an
                // offscreen RT + MTLFXSpatialScaler at the same size and
                // upscales RT → drawable each frame.
                HStack(spacing: 8) {
                    ForEach(Q3UpscaleQuality.allCases, id: \.self) { q in
                        let isSelected = (selectedQuality == q)
                        Button(action: {
                            selectedQuality = q
                            Q3UpscaleQuality.save(q)
                            NSLog("[Q3-MENU] upscale quality = %@", q.label)
                        }) {
                            VStack(spacing: 2) {
                                Text(q.label)
                                    .font(.system(size: 13, weight: .heavy, design: .monospaced))
                                    .foregroundColor(.white)
                                Text(q == .native ? "1.0×" :
                                     q == .high   ? "0.75×" :
                                     q == .medium ? "0.5×"  : "480p")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(.white.opacity(0.6))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(isSelected ? Color(red: 0.7, green: 0.15, blue: 0.1).opacity(0.85)
                                                     : Color.black.opacity(0.55))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color(red: 0.7, green: 0.15, blue: 0.1).opacity(isSelected ? 1.0 : 0.5),
                                            lineWidth: isSelected ? 2 : 1)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: 560)
                .padding(.horizontal, 24)

                Text("MetalFX Upscale Quality")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.white.opacity(0.55))
                    .padding(.top, -10)

                // MetalFX Frame Interpolation toggle. Sits directly under
                // the upscale-quality picker — same style, two buttons
                // (Off / On). Persists via UserDefaults; the Coordinator
                // reads Q3FrameInterpolation.current at init and (when
                // .on) creates an MTLFXFrameInterpolator + emits one
                // synthesized frame between each rendered pair.
                HStack(spacing: 8) {
                    ForEach(Q3FrameInterpolation.allCases, id: \.self) { fi in
                        let isSelected = (selectedFrameInterp == fi)
                        Button(action: {
                            selectedFrameInterp = fi
                            Q3FrameInterpolation.save(fi)
                            NSLog("[Q3-MENU] frame interpolation = %@", fi.label)
                        }) {
                            VStack(spacing: 2) {
                                Text(fi.label)
                                    .font(.system(size: 13, weight: .heavy, design: .monospaced))
                                    .foregroundColor(.white)
                                Text(fi == .off ? "1× present" : "2× present")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(.white.opacity(0.6))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(isSelected ? Color(red: 0.7, green: 0.15, blue: 0.1).opacity(0.85)
                                                     : Color.black.opacity(0.55))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color(red: 0.7, green: 0.15, blue: 0.1).opacity(isSelected ? 1.0 : 0.5),
                                            lineWidth: isSelected ? 2 : 1)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: 560)
                .padding(.horizontal, 24)

                Text("Frame Interpolation (experimental)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.white.opacity(0.45))
                    .padding(.top, -10)

                // Scrollable demo + map + mod list. .frame(maxHeight:
                // .infinity) anchors this to consume all remaining
                // vertical space, so however many pickers we add above
                // can never crowd the list off-screen — the list just
                // shrinks and gets longer scroll content.
                ScrollView {
                    VStack(spacing: 12) {
                        // Stock demo always available
                        DemoButton(title: "Demo: four (Q3 default)",
                                   subtitle: "Stock pak0 — Camping Grounds (q3dm6)") {
                            choose(command: "demo four", label: "Demo: four (Q3 default)")
                        }

                        ForEach(demoFiles) { d in
                            DemoButton(title: "Demo: \(d.name)",
                                       subtitle: d.source) {
                                choose(command: "demo \(d.name)", label: "Demo: \(d.name)")
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
                            choose(command: "map q3dm1", label: "Map: q3dm1")
                        }
                        DemoButton(title: "Map: q3dm4",
                                   subtitle: "The Place of Many Deaths") {
                            choose(command: "map q3dm4", label: "Map: q3dm4")
                        }
                        DemoButton(title: "Map: q3dm6",
                                   subtitle: "Camping Grounds") {
                            choose(command: "map q3dm6", label: "Map: q3dm6")
                        }
                        DemoButton(title: "Map: q3dm17",
                                   subtitle: "The Longest Yard") {
                            choose(command: "map q3dm17", label: "Map: q3dm17")
                        }
                        DemoButton(title: "Map: nv15",
                                   subtitle: "Area 15 — Nvidia Bunker (custom pk3)") {
                            choose(command: "map nv15", label: "Map: nv15")
                        }

                        Divider()
                            .background(Color.white.opacity(0.3))
                            .padding(.vertical, 8)

                        // Mod rows. Encoded form: "mod:<name>|<command>"
                        // Quake3_iOSApp.swift parses the prefix → calls
                        // Q3_SetBootMod(name) before Quake3_Init (which
                        // bakes +set fs_game <name> into the cmdline).
                        // VM_FindNative is patched to skip our native
                        // cgame when fs_game is a non-baseq3 value, so
                        // the mod's cgame.qvm / qagame.qvm / ui.qvm load
                        // via the AArch64 QVM JIT path.
                        Text("MODS")
                            .font(.system(size: 13, weight: .heavy, design: .monospaced))
                            .foregroundColor(.red.opacity(0.85))
                            .tracking(4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.leading, 8)

                        DemoButton(title: "OSP — q3dm6",
                                   subtitle: "Orange Smoothie Productions ruleset · bot duel") {
                            choose(command: "mod:osp|map q3dm6", label: "OSP — q3dm6")
                        }
                        DemoButton(title: "Q3Plus — q3dm6",
                                   subtitle: "Modern competitive overlay + better hud") {
                            choose(command: "mod:q3plus|map q3dm6", label: "Q3Plus — q3dm6")
                        }
                        DemoButton(title: "ExcessivePlus — q3dm17",
                                   subtitle: "Faster respawn / infinite ammo · bot deathmatch") {
                            choose(command: "mod:excessiveplus|map q3dm17", label: "ExcessivePlus — q3dm17")
                        }
                    }
                    .padding(.horizontal, 24)
                    .frame(maxWidth: 560)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
                .frame(maxHeight: .infinity)   // ScrollView takes all remaining vertical space
            }
        }
        .task {
            let demos = Self.discoverDemos()
            demoFiles = demos
            DebugTelemetry.shared.log(source: Self.telemetrySource, type: "menu_ready", fields: [
                "demoCount": demos.count,
                "demos": demos.map(\.name)
            ])
        }
    }

    private func choose(command: String, label: String) {
        NSLog("[Q3-MENU] selected %@", command)
        DebugTelemetry.shared.log(source: Self.telemetrySource, type: "menu_tap", message: label, fields: [
            "command": command
        ])
        launchCommand = command
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
        .onTapGesture(perform: action)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}
