import SwiftUI
import AppKit

/// Menu-bar mini: glanceable vitals plus — when llama.cpp is actively
/// generating — the live tok/s figure (the "ambient" AI surface from
/// the spec). Everything else is one click into the main window.
struct MenuBarView: View {
    @EnvironmentObject private var engine: ProcessEngine
    @EnvironmentObject private var monitor: EngineMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider()
            vitals
            if let tps = liveInference {
                Divider()
                inferenceRow(tps)
            }
            Divider()
            footer
        }
        .padding(12)
        .frame(width: 300)
    }

    private var header: some View {
        HStack {
            Image(systemName: "waveform.path.ecg")
            Text("Pulse AI").bold()
            Spacer()
            let pressure = engine.system.memoryPressure
            Label(pressure.label, systemImage: pressure.symbolName)
                .font(.caption)
                .foregroundStyle(PulseTheme.health(forPressure: pressure).color)
        }
    }

    private var vitals: some View {
        VStack(spacing: 6) {
            miniRow("CPU", Format.percent(engine.system.cpuTotal),
                    fraction: engine.system.cpuTotal)
            miniRow("Memory", "\(Format.bytes(engine.system.memoryUsedBytes)) / \(Format.bytes(engine.system.memoryTotalBytes))",
                    fraction: 1 - engine.system.memoryFreeFraction)
            miniRow("Thermal", engine.system.thermal.label, fraction: nil)
            if let gpu = engine.system.gpuPercent {
                miniRow("GPU", Format.percent(gpu), fraction: gpu)
            }
            if let top = engine.processes.first {
                miniRow("Top process", "\(top.name) · \(Format.cpuPercent(top.cpuPercent))", fraction: nil)
            }
        }
    }

    /// Live tok/s shows only when an engine is actually generating and
    /// reports a measured figure (llama.cpp via /metrics). Otherwise
    /// the mini stays silent rather than guessing (provenance rule).
    private var liveInference: (tokens: Double, engine: String)? {
        for status in monitor.statuses where status.isActiveGeneration {
            if let tps = status.throughput.tokensPerSecond {
                return (tps, status.kind.rawValue)
            }
        }
        return nil
    }

    private func inferenceRow(_ live: (tokens: Double, engine: String)) -> some View {
        HStack {
            Image(systemName: "brain.head.profile")
            VStack(alignment: .leading, spacing: 0) {
                Text("\(live.engine) generating")
                    .font(.caption).foregroundStyle(.secondary)
                Text(Format.tokensPerSecond(live.tokens))
                    .font(.headline)
            }
            Spacer()
            Text("Measured").font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack {
            Button("Open Pulse AI") {
                NSApp.activate(ignoringOtherApps: true)
                for window in NSApp.windows where window.canBecomeMain {
                    window.makeKeyAndOrderFront(nil)
                }
            }
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .buttonStyle(.plain)
        .font(.callout)
    }

    private func miniRow(_ label: String, _ value: String, fraction: Double?) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary).frame(width: 78, alignment: .leading)
            if let fraction {
                ProgressView(value: min(max(fraction, 0), 1))
                    .frame(width: 70)
            }
            Text(value).font(PulseTheme.smallMonoFont).lineLimit(1)
            Spacer()
        }
        .font(.callout)
    }
}
