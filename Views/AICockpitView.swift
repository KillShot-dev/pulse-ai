import SwiftUI

/// The Inference Cockpit — the differentiator (spec, Feature set C).
/// One card per engine: loaded models, memory footprint, KV/context
/// where the engine reports it, endpoint health, and throughput that
/// ALWAYS carries its provenance label. An unavailable number is
/// shown as unavailable, with the reason — never invented.
struct AICockpitView: View {
    @EnvironmentObject private var monitor: EngineMonitor
    @EnvironmentObject private var engine: ProcessEngine

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PulseTheme.gridSpacing) {
                if !monitor.anyOnline {
                    ContentUnavailableView(
                        "No AI Engines Running",
                        systemImage: "brain.head.profile",
                        description: Text("Pulse watches Ollama (11434), LM Studio (1234), llama.cpp (8080), MLX (8080) and ComfyUI (8188) on loopback. Start one and it will appear here within seconds."))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                }
                ForEach(monitor.statuses) { status in
                    EngineCard(status: status)
                }
                correlationNote
            }
            .padding(16)
        }
        .toolbar {
            Button {
                Task { await monitor.pollAll() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
        }
    }

    /// The "which suspect did it" strip: current system suspects,
    /// always visible beside the engine cards.
    private var correlationNote: some View {
        let sys = engine.system
        return VStack(alignment: .leading, spacing: 6) {
            Text("When generation slows, check the suspects").font(PulseTheme.cardTitleFont)
            HStack(spacing: 16) {
                suspect("GPU", Format.percent(sys.gpuPercent ?? 0),
                        ok: (sys.gpuPercent ?? 0) < 0.98)
                suspect("Memory pressure", sys.memoryPressure.label,
                        ok: sys.memoryPressure == .normal)
                suspect("Thermal", sys.thermal.label,
                        ok: sys.thermal.rawValue < ThermalLevel.serious.rawValue)
                suspect("Swap in use", Format.bytes(sys.swapUsedBytes),
                        ok: sys.swapUsedBytes == 0)
            }
            Text("llama.cpp reports true live tok/s and KV-cache fill. Ollama and LM Studio expose loaded-model state only — their throughput is labelled accordingly (see the research addendum in the spec).")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(PulseTheme.cardPadding)
        .background { PulseTheme.cardBackground() }
    }

    private func suspect(_ label: String, _ value: String, ok: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 4) {
                Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(ok ? Color.green : Color.orange)
                Text(value).font(.callout).bold()
            }
        }
    }
}

private struct EngineCard: View {
    let status: EngineStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if status.isOnline {
                models
                throughputRow
                queueRow
            } else {
                Text(status.lastErrorSummary.map { "Not answering on loopback port \(status.kind.port). (\($0))" }
                     ?? "Not answering on loopback port \(status.kind.port).")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(PulseTheme.cardPadding)
        .background { PulseTheme.cardBackground() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: status.kind.symbolName).font(.title3)
            Text(status.kind.rawValue).font(PulseTheme.cardTitleFont)
            if let version = status.version {
                Text("v\(version)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Label(status.isOnline ? "Online" : "Offline",
                  systemImage: status.isOnline ? "circle.fill" : "circle")
                .font(.caption)
                .foregroundStyle(status.isOnline ? Color.green : Color.secondary)
            if let latency = status.latencyMilliseconds {
                Text(String(format: "%.0f ms", latency))
                    .font(PulseTheme.smallMonoFont).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var models: some View {
        if status.loadedModels.isEmpty {
            Text("No models loaded.").font(.callout).foregroundStyle(.secondary)
        } else {
            ForEach(status.loadedModels) { model in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(model.name).bold().lineLimit(1)
                        Spacer()
                        if let memory = model.memoryBytes {
                            Text(Format.bytes(memory)).font(PulseTheme.smallMonoFont)
                        }
                    }
                    HStack(spacing: 10) {
                        if let quant = model.quantization { Text(quant) }
                        if let params = model.parameterSize { Text(params) }
                        if let ctx = model.contextLength { Text("ctx \(ctx)") }
                        if let kv = model.kvCacheUsageRatio {
                            Text("KV \(Format.percent(kv))")
                        }
                        if let expires = model.expiresAt {
                            Text("unloads \(expires, style: .relative)")
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                Divider()
            }
        }
        if let total = status.deviceMemoryTotalBytes, let free = status.deviceMemoryFreeBytes {
            Text("Device memory: \(Format.bytes(total - free)) of \(Format.bytes(total)) in use")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var throughputRow: some View {
        HStack(spacing: 8) {
            Text("Throughput").font(.callout).foregroundStyle(.secondary)
            Text(Format.tokensPerSecond(status.throughput.tokensPerSecond))
                .font(.callout).bold()
            // Provenance is part of the number. Always rendered.
            Text(status.throughput.provenance.rawValue)
                .font(.caption)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(.quaternary, in: Capsule())
            if let note = status.throughput.methodNote {
                Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var queueRow: some View {
        if status.requestsInFlight != nil || status.requestsQueued != nil {
            HStack(spacing: 16) {
                LabeledContent("In flight", value: "\(status.requestsInFlight ?? 0)")
                LabeledContent("Queued", value: "\(status.requestsQueued ?? 0)")
            }
            .font(.callout)
        }
    }
}
