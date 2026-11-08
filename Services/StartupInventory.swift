import Foundation
import ServiceManagement

/// Startup inventory: every LaunchAgent/LaunchDaemon plist in the three
/// standard directories, parsed read-only with
/// PropertyListSerialization. Malformed plists are skipped, never fatal.
/// No writes happen here in v1 — the Startup view's disable action is
/// gated behind the (disabled-by-default) helper, per spec.
final class StartupInventory {

    func load() -> [StartupItem] {
        var items: [StartupItem] = []
        let home = FileManager.default.homeDirectoryForCurrentUser
        items += parseDirectory(home.appendingPathComponent("Library/LaunchAgents"),
                                source: .userLaunchAgent)
        items += parseDirectory(URL(fileURLWithPath: "/Library/LaunchAgents"),
                                source: .systemLaunchAgent)
        items += parseDirectory(URL(fileURLWithPath: "/Library/LaunchDaemons"),
                                source: .systemLaunchDaemon)
        return items.sorted {
            ($0.source.rawValue, $0.label) < ($1.source.rawValue, $1.label)
        }
    }

    private func parseDirectory(_ dir: URL, source: StartupSource) -> [StartupItem] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
            return []
        }
        return entries
            .filter { $0.pathExtension == "plist" }
            .compactMap { parsePlist(at: $0, source: source) }
    }

    private func parsePlist(at url: URL, source: StartupSource) -> StartupItem? {
        guard let data = try? Data(contentsOf: url),
              let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let plist = object as? [String: Any] else {
            return nil   // malformed plist — tolerated, skipped
        }

        let label = (plist["Label"] as? String)
            ?? url.deletingPathExtension().lastPathComponent

        var executable: String?
        var arguments: [String] = []
        if let program = plist["Program"] as? String {
            executable = program
        }
        if let programArgs = plist["ProgramArguments"] as? [String], !programArgs.isEmpty {
            executable = executable ?? programArgs.first
            arguments = Array(programArgs.dropFirst())
        }

        // "Disabled" inside the plist is one signal; SMAppService knows
        // the live registration state for user agents — prefer it when
        // it answers, fall back to the plist otherwise.
        var enabled = !((plist["Disabled"] as? Bool) ?? false)
        if source == .userLaunchAgent {
            let service = SMAppService.loginItem(identifier: label)
            switch service.status {
            case .enabled: enabled = true
            case .notRegistered, .notFound: enabled = false
            case .requiresApproval: enabled = true   // registered, awaiting user approval
            @unknown default: break
            }
        }

        return StartupItem(
            label: label,
            executable: executable,
            arguments: arguments,
            runAtLoad: (plist["RunAtLoad"] as? Bool) ?? false,
            isEnabled: enabled,
            source: source,
            plistPath: url.path)
    }
}

@MainActor
final class StartupInventoryModel: ObservableObject {
    @Published private(set) var items: [StartupItem] = []

    func reload() {
        Task.detached(priority: .utility) {
            let loaded = StartupInventory().load()
            await MainActor.run { [weak self] in self?.items = loaded }
        }
    }
}
