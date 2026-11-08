import SwiftUI

/// The sidebar destinations. Raw values double as command-palette ids.
enum SidebarSection: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case processes = "Processes"
    case aiCockpit = "AI Cockpit"
    case models = "Models"
    case startup = "Startup"
    case settings = "Settings"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .overview: return "gauge.with.dots.needle.67percent"
        case .processes: return "list.bullet.indent"
        case .aiCockpit: return "brain.head.profile"
        case .models: return "square.stack.3d.up"
        case .startup: return "power"
        case .settings: return "gearshape"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var engine: ProcessEngine
    @EnvironmentObject private var license: LicenseService
    @State private var selection: SidebarSection? = .overview
    @State private var showPalette = false

    var body: some View {
        NavigationSplitView {
            List(SidebarSection.allCases, selection: $selection) { section in
                Label(section.rawValue, systemImage: section.symbol)
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 210)
            .safeAreaInset(edge: .bottom) { licenseFooter }
        } detail: {
            detail
                .navigationTitle(selection?.rawValue ?? "Pulse AI")
        }
        .overlay { if showPalette { paletteOverlay } }
        .background {
            // ⌘K toggles the command palette from anywhere.
            Button("") { showPalette.toggle() }
                .keyboardShortcut("k", modifiers: .command)
                .hidden()
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch selection ?? .overview {
        case .overview:
            DashboardView()
        case .processes:
            ProcessListView()
        case .aiCockpit:
            AICockpitView()
        case .models:
            ModelLibraryView()
        case .startup:
            StartupView()
        case .settings:
            SettingsView()
        }
    }

    private var licenseFooter: some View {
        HStack(spacing: 6) {
            Image(systemName: license.isFull ? "checkmark.seal.fill" : "clock.badge")
            Text(license.isFull ? "Licensed" : "Trial — full features")
                .font(.caption)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .foregroundStyle(.secondary)
    }

    // MARK: Command palette (⌘K) — fuzzy jump over views + top processes

    private var paletteOverlay: some View {
        ZStack {
            Color.black.opacity(0.25)
                .ignoresSafeArea()
                .onTapGesture { showPalette = false }
            CommandPaletteView(
                onJump: { section in
                    selection = section
                    showPalette = false
                },
                onClose: { showPalette = false })
            .frame(width: 520)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(radius: 30)
            .padding(.top, 80)
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }
}

private struct CommandPaletteView: View {
    @EnvironmentObject private var engine: ProcessEngine
    @State private var query = ""
    let onJump: (SidebarSection) -> Void
    let onClose: () -> Void

    private struct Entry: Identifiable {
        var id: String
        var title: String
        var subtitle: String
        var symbol: String
        var section: SidebarSection
    }

    private var entries: [Entry] {
        var all: [Entry] = SidebarSection.allCases.map {
            Entry(id: "view-\($0.rawValue)", title: $0.rawValue,
                  subtitle: "Go to view", symbol: $0.symbol, section: $0)
        }
        for proc in engine.processes.prefix(12) {
            all.append(Entry(
                id: "proc-\(proc.pid)",
                title: proc.name,
                subtitle: "pid \(proc.pid) · \(Format.cpuPercent(proc.cpuPercent)) CPU",
                symbol: "app.dashed", section: .processes))
        }
        guard !query.isEmpty else { return all }
        let needle = query.lowercased()
        return all.filter { entry in
            fuzzyMatch(needle: needle, in: entry.title.lowercased())
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Jump to a view or process…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                Button("Cancel") { onClose() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            Divider()
            List(entries) { entry in
                Button {
                    onJump(entry.section)
                } label: {
                    HStack {
                        Image(systemName: entry.symbol)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.title)
                            Text(entry.subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .frame(maxHeight: 320)
        }
    }

    /// Subsequence fuzzy match — every needle char, in order.
    private func fuzzyMatch(needle: String, in haystack: String) -> Bool {
        var index = haystack.startIndex
        for ch in needle {
            guard let found = haystack[index...].firstIndex(of: ch) else { return false }
            index = haystack.index(after: found)
        }
        return true
    }
}
