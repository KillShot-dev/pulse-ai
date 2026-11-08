import SwiftUI

/// Design tokens for Pulse AI — the spec's "Apple, but better" language:
/// system materials, one accent per health state, SF Symbols, and
/// color-blind-safe status (icon + text, never color alone).
enum PulseTheme {

    // MARK: Health states

    enum Health {
        case calm, warm, hot

        var color: Color {
            switch self {
            case .calm: return .green
            case .warm: return .orange
            case .hot: return .red
            }
        }

        var symbol: String {
            switch self {
            case .calm: return "checkmark.circle.fill"
            case .warm: return "exclamationmark.triangle.fill"
            case .hot: return "flame.fill"
            }
        }

        var label: String {
            switch self {
            case .calm: return "Calm"
            case .warm: return "Under load"
            case .hot: return "Hot"
            }
        }
    }

    static func health(forCPUFraction fraction: Double) -> Health {
        switch fraction {
        case ..<0.6: return .calm
        case ..<0.85: return .warm
        default: return .hot
        }
    }

    static func health(forPressure pressure: MemoryPressureLevel) -> Health {
        switch pressure {
        case .normal: return .calm
        case .warning: return .warm
        case .critical: return .hot
        }
    }

    static func health(forThermal thermal: ThermalLevel) -> Health {
        switch thermal {
        case .nominal, .fair: return .calm
        case .serious: return .warm
        case .critical: return .hot
        }
    }

    // MARK: Typography scale (semantic — Dynamic Type does the work)

    static let statValueFont: Font = .system(.title2, design: .rounded).weight(.semibold)
    static let statLabelFont: Font = .caption
    static let cardTitleFont: Font = .headline
    static let monoFont: Font = .system(.body, design: .monospaced)
    static let smallMonoFont: Font = .system(.caption, design: .monospaced)

    // MARK: Spacing & shape

    static let cardCornerRadius: CGFloat = 12
    static let cardPadding: CGFloat = 14
    static let gridSpacing: CGFloat = 14

    /// The standard stat-card background: a system material over the
    /// window background, no custom gradients — restraint is the brand.
    static func cardBackground() -> some View {
        RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
            .fill(.regularMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
                    .strokeBorder(.separator, lineWidth: 1)
            )
    }
}

// MARK: - Formatting helpers shared by every view

enum Format {
    static func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .memory)
    }

    static func percent(_ fraction: Double) -> String {
        String(format: "%.0f%%", fraction * 100)
    }

    static func cpuPercent(_ value: Double) -> String {
        value >= 100 ? String(format: "%.0f%%", value) : String(format: "%.1f%%", value)
    }

    static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "—" }
        let total = Int(seconds)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m \(s)s" }
        return "\(s)s"
    }

    static func tokensPerSecond(_ value: Double?) -> String {
        guard let value, value > 0 else { return "—" }
        return String(format: "%.1f tok/s", value)
    }
}
