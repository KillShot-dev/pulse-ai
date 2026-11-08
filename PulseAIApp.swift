import SwiftUI

/// Pulse AI — entry point.
///
/// Three surfaces, one brain (spec §design language): the main window
/// (NavigationSplitView), the MenuBarExtra mini, and Settings. All of
/// them observe the same ProcessEngine / EngineMonitor / LicenseService
/// instances created here.
@main
struct PulseAIApp: App {
    @StateObject private var engine = ProcessEngine()
    @StateObject private var engineMonitor = EngineMonitor()
    @StateObject private var license = LicenseService()

    var body: some Scene {
        WindowGroup("Pulse AI") {
            ContentView()
                .environmentObject(engine)
                .environmentObject(engineMonitor)
                .environmentObject(license)
                .frame(minWidth: 980, minHeight: 620)
                .onAppear {
                    engine.start()
                    engineMonitor.start()
                }
                .onDisappear {
                    engine.stop()
                    engineMonitor.stop()
                }
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) { }  // single-window app
        }

        MenuBarExtra {
            MenuBarView()
                .environmentObject(engine)
                .environmentObject(engineMonitor)
                .environmentObject(license)
        } label: {
            MenuBarLabel()
                .environmentObject(engine)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(license)
                .environmentObject(engine)
        }
    }
}

/// The menu-bar label itself: a pulse glyph plus the live CPU figure,
/// so the "at a glance" surface works even with the popover closed.
private struct MenuBarLabel: View {
    @EnvironmentObject private var engine: ProcessEngine

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "waveform.path.ecg")
            Text(Format.percent(engine.system.cpuTotal))
                .font(.system(.body, design: .monospaced))
        }
        .accessibilityLabel("Pulse AI, CPU \(Format.percent(engine.system.cpuTotal))")
    }
}
