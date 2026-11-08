import SwiftUI

/// Settings: sampling, alert thresholds, and the license surface.
/// The license section states the trial model honestly: full features
/// during trial, a gentle reminder — never a hard lockout of a tool
/// someone relies on (FileRadar fleet precedent).
struct SettingsView: View {
    @EnvironmentObject private var license: LicenseService
    @EnvironmentObject private var engine: ProcessEngine
    @AppStorage("samplingInterval") private var samplingInterval: Double = 1.0
    @AppStorage("cpuAlertThreshold") private var cpuAlertThreshold: Double = 0.9
    @AppStorage("pressureAlertEnabled") private var pressureAlertEnabled = true
    @State private var serialInput = ""
    @State private var licenseMessage: String?

    var body: some View {
        Form {
            Section("Sampling") {
                Picker("Refresh rate", selection: $samplingInterval) {
                    Text("Every second").tag(1.0)
                    Text("Every 2 seconds").tag(2.0)
                    Text("Every 5 seconds").tag(5.0)
                }
                .onChange(of: samplingInterval) { old, new in
                    engine.setInterval(new)
                }
                Text("Slower sampling costs less battery; process CPU deltas stay accurate at any rate.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Alerts") {
                Toggle("Warn when memory pressure leaves Normal", isOn: $pressureAlertEnabled)
                Slider(value: $cpuAlertThreshold, in: 0.5...1.0, step: 0.05) {
                    Text("Sustained CPU alert at \(Format.percent(cpuAlertThreshold))")
                }
                Text("Alerts are local notifications only. Pulse sends no telemetry and phones nothing home.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("License") {
                licenseBody
            }

            Section("About") {
                LabeledContent("Version", value: "1.0")
                LabeledContent("Support", value: "support@metaphasic.net")
                Text("Pulse AI by metaPhasic Group. Direct distribution, hardened runtime, no third-party code, no analytics.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 460)
    }

    @ViewBuilder
    private var licenseBody: some View {
        switch license.state {
        case .full:
            Label("Licensed — thank you.", systemImage: "checkmark.seal.fill")
                .foregroundStyle(.green)
            if let serial = license.storedSerialMasked {
                LabeledContent("Serial", value: serial)
            }
            TextField("Serial (required to deactivate)", text: $serialInput)
                .font(PulseTheme.smallMonoFont)
            Button("Deactivate This Mac", role: .destructive) {
                let serial = serialInput.isEmpty ? (license.fullSerialForDeactivation ?? "") : serialInput
                Task {
                    licenseMessage = await license.deactivate(serial: serial)
                        ? "Deactivated. This Mac returned to trial."
                        : "Deactivation failed — check the serial matches the activated one."
                }
            }
        case .trial, .locked:
            Text(license.state == .trial
                 ? "Trial — every feature works. If Pulse earns its place, a one-time license removes this reminder: $8 during the first 60 days after launch, $19 after."
                 : "This copy is not licensed. Monitoring continues in read-only form.")
                .font(.callout)
            TextField("PU-XXXX-XXXX-XXXX-XXXX", text: $serialInput)
                .font(PulseTheme.smallMonoFont)
                .autocorrectionDisabled()
            HStack {
                Button("Activate") {
                    Task {
                        licenseMessage = await license.activate(serial: serialInput)
                            ? "Activated. Welcome aboard."
                            : "That serial does not validate. Check for typos — the format is PU-XXXX-XXXX-XXXX-XXXX."
                    }
                }
                .disabled(serialInput.trimmingCharacters(in: .whitespaces).isEmpty)
                Text(licenseMessage ?? "")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
