import SwiftUI
import Charts

/// Overview: the stat-card grid + live Swift Charts traces.
/// Every card answers one question (spec: "every number earns its pixel").
struct DashboardView: View {
    @EnvironmentObject private var engine: ProcessEngine
    @EnvironmentObject private var engineMonitor: EngineMonitor

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PulseTheme.gridSpacing) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: PulseTheme.gridSpacing)],
                          spacing: PulseTheme.gridSpacing) {
                    cpuCard
                    memoryCard
                    thermalCard
                    gpuCard
                    swapCard
                    aiCard
                }
                tracesCard
                hottestCard
            }
            .padding(16)
        }
    }

    // MARK: Cards

    private var cpuCard: some View {
        let health = PulseTheme.health(forCPUFraction: engine.system.cpuTotal)
        return StatCard(title: "CPU", symbol: "cpu", health: health) {
            Text(Format.percent(engine.system.cpuTotal))
                .font(PulseTheme.statValueFont)
            Text("\(engine.system.cpuPerCore.count) cores · \(engine.system.processCount) processes")
                .font(PulseTheme.statLabelFont)
                .foregroundStyle(.secondary)
        }
    }

    private var memoryCard: some View {
        let health = PulseTheme.health(forPressure: engine.system.memoryPressure)
        return StatCard(title: "Memory Pressure", symbol: "memorychip", health: health) {
            Text(engine.system.memoryPressure.label)
                .font(PulseTheme.statValueFont)
            Text("\(Format.bytes(engine.system.memoryUsedBytes)) of \(Format.bytes(engine.system.memoryTotalBytes)) used")
                .font(PulseTheme.statLabelFont)
                .foregroundStyle(.secondary)
        }
    }

    private var thermalCard: some View {
        let health = PulseTheme.health(forThermal: engine.system.thermal)
        return StatCard(title: "Thermal State", symbol: "thermometer.medium", health: health) {
            Text(engine.system.thermal.label)
                .font(PulseTheme.statValueFont)
            Text(health == .calm ? "No throttling pressure" : "The SoC is shedding heat — sustained work may slow")
                .font(PulseTheme.statLabelFont)
                .foregroundStyle(.secondary)
        }
    }

    private var gpuCard: some View {
        StatCard(title: "GPU", symbol: "gpu", health: nil) {
            if let gpu = engine.system.gpuPercent {
                Text(Format.percent(gpu)).font(PulseTheme.statValueFont)
                Text("IOAccelerator device utilization")
                    .font(PulseTheme.statLabelFont).foregroundStyle(.secondary)
            } else {
                Text("—").font(PulseTheme.statValueFont)
                Text("Not reported by this Mac")
                    .font(PulseTheme.statLabelFont).foregroundStyle(.secondary)
            }
        }
    }

    private var swapCard: some View {
        let swap = engine.system
        let fraction = swap.swapTotalBytes > 0
            ? Double(swap.swapUsedBytes) / Double(swap.swapTotalBytes) : 0
        return StatCard(title: "Swap", symbol: "arrow.left.arrow.right.square",
                        health: fraction > 0.5 ? .hot : (fraction > 0.15 ? .warm : .calm)) {
            Text(Format.bytes(swap.swapUsedBytes)).font(PulseTheme.statValueFont)
            Text(swap.swapUsedBytes == 0
                 ? "Unused — memory is keeping up"
                 : "In use — the disk is standing in for RAM")
                .font(PulseTheme.statLabelFont).foregroundStyle(.secondary)
        }
    }

    private var aiCard: some View {
        let online = engineMonitor.statuses.filter { $0.isOnline }
        return StatCard(title: "Local AI", symbol: "brain.head.profile", health: nil) {
            if online.isEmpty {
                Text("No engines").font(PulseTheme.statValueFont)
                Text("Ollama, LM Studio, llama.cpp, MLX, ComfyUI — none answering on loopback")
                    .font(PulseTheme.statLabelFont).foregroundStyle(.secondary)
            } else {
                Text(online.map { $0.kind.rawValue }.joined(separator: ", "))
                    .font(.headline)
                    .lineLimit(2)
                let tps = engineMonitor.headlineThroughput
                Text(Format.tokensPerSecond(tps.tokensPerSecond)
                     + (tps.tokensPerSecond != nil ? " (\(tps.provenance.rawValue.lowercased()))" : ""))
                    .font(PulseTheme.statLabelFont).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Traces

    private var tracesCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Live traces").font(PulseTheme.cardTitleFont)
            Chart(engine.history, id: \.timestamp) { point in
                LineMark(x: .value("Time", point.timestamp),
                         y: .value("CPU", point.cpuTotal * 100))
                .foregroundStyle(by: .value("Series", "CPU %"))
                LineMark(x: .value("Time", point.timestamp),
                         y: .value("Memory", (1 - point.memoryFreeFraction) * 100))
                .foregroundStyle(by: .value("Series", "Memory %"))
            }
            .chartYScale(domain: 0...100)
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 5)) }
            .frame(height: 180)
            Text("Rolling window of the current session's samples. Thermal transitions are recorded in the local history file.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(PulseTheme.cardPadding)
        .background { PulseTheme.cardBackground() }
    }

    private var hottestCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Hottest processes right now").font(PulseTheme.cardTitleFont)
            ForEach(engine.processes.prefix(5)) { proc in
                HStack {
                    Text(proc.name).lineLimit(1)
                    Spacer()
                    Text(Format.cpuPercent(proc.cpuPercent))
                        .font(PulseTheme.smallMonoFont)
                        .foregroundStyle(PulseTheme.health(forCPUFraction: proc.cpuPercent / 100).color)
                    Text(Format.bytes(proc.residentBytes))
                        .font(PulseTheme.smallMonoFont)
                        .foregroundStyle(.secondary)
                        .frame(width: 80, alignment: .trailing)
                }
            }
        }
        .padding(PulseTheme.cardPadding)
        .background { PulseTheme.cardBackground() }
    }
}

/// Shared stat card chrome.
struct StatCard<Content: View>: View {
    let title: String
    let symbol: String
    let health: PulseTheme.Health?
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                Text(title).font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                if let health {
                    Label(health.label, systemImage: health.symbol)
                        .font(.caption2)
                        .foregroundStyle(health.color)
                        .labelStyle(.iconOnly)
                        .accessibilityLabel(health.label)
                }
            }
            content()
        }
        .padding(PulseTheme.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { PulseTheme.cardBackground() }
    }
}
