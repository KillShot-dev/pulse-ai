import SwiftUI

/// Startup Manager (read-only in v1): every LaunchAgent/LaunchDaemon
/// plist in one list, with source and live enabled state. Disabling an
/// item requires the privileged helper, which ships DISABLED in v1 —
/// the per-row note says so instead of pretending the button works.
struct StartupView: View {
    @StateObject private var inventory = StartupInventoryModel()

    var body: some View {
        VStack(spacing: 0) {
            Table(inventory.items) {
                TableColumn("Label", value: \.label) { item in
                    Text(item.label).lineLimit(1)
                }
                TableColumn("Program") { item in
                    Text(item.executable ?? "—")
                        .font(PulseTheme.smallMonoFont).lineLimit(1)
                }
                TableColumn("Source", value: \.source.rawValue) { item in
                    Text(item.source.rawValue)
                }.width(150)
                TableColumn("Runs at load") { item in
                    Text(item.runAtLoad ? "Yes" : "No").foregroundStyle(.secondary)
                }.width(90)
                TableColumn("State") { item in
                    Label(item.isEnabled ? "Enabled" : "Disabled",
                          systemImage: item.isEnabled ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(item.isEnabled ? Color.green : Color.secondary)
                }.width(110)
                TableColumn("") { _ in
                    // Honest stub: the action exists in the product plan
                    // but v1's helper is disabled (see Helper/README.md).
                    Text("Disable via helper — off in v1")
                        .font(.caption).foregroundStyle(.tertiary)
                }.width(170)
            }
            footer
        }
        .onAppear { inventory.reload() }
        .toolbar {
            Button { inventory.reload() } label: {
                Label("Reload", systemImage: "arrow.clockwise")
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle")
            Text("Read from ~/Library/LaunchAgents, /Library/LaunchAgents and /Library/LaunchDaemons. Pulse reads plists only — it changes nothing at startup in v1.")
                .font(.caption)
            Spacer()
            Text("\(inventory.items.count) items").font(.caption).foregroundStyle(.secondary)
        }
        .padding(10)
        .foregroundStyle(.secondary)
        .background(.regularMaterial)
    }
}
