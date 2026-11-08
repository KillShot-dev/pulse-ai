import Foundation

// MARK: - Processes

/// One sampled process. CPU% and rates are deltas computed by
/// ProcessEngine between two consecutive samples; the raw lifetime
/// counters are kept so the inspector can show totals since start.
struct ProcessSnapshot: Identifiable, Hashable {
    let pid: pid_t
    let ppid: pid_t
    var name: String
    var path: String?
    /// Percent of ONE core (may exceed 100 on multi-threaded processes),
    /// computed from the delta of total CPU time between samples.
    var cpuPercent: Double
    /// Resident memory (bytes) — the "Memory" figure Activity Monitor shows.
    var residentBytes: UInt64
    /// Total CPU seconds consumed (user + system) since the process started.
    var lifetimeCPUSeconds: Double
    var userCPUSeconds: Double
    var systemCPUSeconds: Double
    var threadCount: Int
    var startTime: Date?
    /// Owning user's short name, resolved via getpwuid.
    var user: String
    var uid: uid_t

    var id: pid_t { pid }

    var isOwnedByCurrentUser: Bool { uid == getuid() }
}

/// A node in the launchd-rooted genealogy tree.
struct ProcessNode: Identifiable {
    let snapshot: ProcessSnapshot
    var children: [ProcessNode]
    var id: pid_t { snapshot.pid }
}

// MARK: - System

enum MemoryPressureLevel: Int, Comparable {
    case normal = 1
    case warning = 2
    case critical = 4

    static func < (lhs: MemoryPressureLevel, rhs: MemoryPressureLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var label: String {
        switch self {
        case .normal: return "Normal"
        case .warning: return "Warning"
        case .critical: return "Critical"
        }
    }
}

enum ThermalLevel: Int, CaseIterable {
    case nominal = 0
    case fair = 1
    case serious = 2
    case critical = 3

    init(processInfoState: ProcessInfo.ThermalState) {
        switch processInfoState {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .nominal
        }
    }

    var label: String {
        switch self {
        case .nominal: return "Nominal"
        case .fair: return "Fair"
        case .serious: return "Serious"
        case .critical: return "Critical"
        }
    }
}

/// Whole-machine state for one sample tick.
struct SystemSnapshot {
    var timestamp: Date = Date()
    /// Per-core busy fraction 0...1 (empty when the mach call failed).
    var cpuPerCore: [Double] = []
    /// Aggregate busy fraction 0...1.
    var cpuTotal: Double = 0
    var memoryPressure: MemoryPressureLevel = .normal
    var memoryUsedBytes: UInt64 = 0
    var memoryTotalBytes: UInt64 = 0
    var swapUsedBytes: UInt64 = 0
    var swapTotalBytes: UInt64 = 0
    var thermal: ThermalLevel = .nominal
    /// GPU busy fraction 0...1 from IOAccelerator PerformanceStatistics,
    /// nil when IOKit has nothing to say (headless, some VMs).
    var gpuPercent: Double?
    var processCount: Int = 0

    var memoryFreeFraction: Double {
        guard memoryTotalBytes > 0 else { return 0 }
        return 1.0 - Double(memoryUsedBytes) / Double(memoryTotalBytes)
    }
}

// MARK: - AI engines

enum EngineKind: String, CaseIterable, Identifiable {
    case ollama = "Ollama"
    case lmStudio = "LM Studio"
    case llamaCpp = "llama.cpp"
    case mlx = "MLX"
    case comfyUI = "ComfyUI"

    var id: String { rawValue }

    /// Fixed loopback port. The allow-list in LoopbackHTTPClient is built
    /// from these values; no other host or port is ever contacted.
    var port: Int {
        switch self {
        case .ollama: return 11434
        case .lmStudio: return 1234
        case .llamaCpp: return 8080
        case .mlx: return 8080
        case .comfyUI: return 8188
        }
    }

    var symbolName: String {
        switch self {
        case .ollama: return "brain.head.profile"
        case .lmStudio: return "desktopcomputer"
        case .llamaCpp: return "terminal"
        case .mlx: return "cpu"
        case .comfyUI: return "photo.on.rectangle.angled"
        }
    }
}

/// Where a number came from. The spec's honesty rule: every throughput
/// figure is shown with its provenance, never bare.
enum Provenance: String {
    /// Read from the engine's own live telemetry (llama.cpp /metrics, /slots).
    case measured = "Measured"
    /// Seen inside a response to a request the user's own client made.
    case observed = "Observed"
    /// Derived from process deltas — an approximation, labelled as such.
    case estimated = "Estimated"
    /// Not available for this engine/situation.
    case unavailable = "Unavailable"
}

struct Throughput {
    var tokensPerSecond: Double?
    var provenance: Provenance = .unavailable
    /// Optional human note, e.g. "llama.cpp /metrics".
    var methodNote: String?
}

/// A model resident in an engine's memory.
struct LoadedModel: Identifiable, Hashable {
    var id: String { engine.rawValue + ":" + name }
    let engine: EngineKind
    var name: String
    var quantization: String?
    var parameterSize: String?
    /// Bytes the weights occupy on disk (or as reported by the engine).
    var sizeBytes: UInt64?
    /// Bytes held in unified memory / VRAM, when the engine reports it.
    var memoryBytes: UInt64?
    /// Context window the model is loaded with, when reported.
    var contextLength: Int?
    /// KV-cache occupancy 0...1 (llama.cpp only, from /metrics).
    var kvCacheUsageRatio: Double?
    /// When Ollama will unload the model if it stays idle.
    var expiresAt: Date?
}

struct EngineStatus: Identifiable {
    var id: EngineKind { kind }
    let kind: EngineKind
    var isOnline: Bool = false
    var version: String?
    var latencyMilliseconds: Double?
    var loadedModels: [LoadedModel] = []
    var throughput: Throughput = Throughput()
    var requestsInFlight: Int?
    var requestsQueued: Int?
    /// Device memory figures (ComfyUI reports these directly).
    var deviceMemoryFreeBytes: UInt64?
    var deviceMemoryTotalBytes: UInt64?
    var lastErrorSummary: String?
    var lastPolledAt: Date?
}

// MARK: - Model library

enum ModelStore: String, CaseIterable {
    case ollama = "Ollama"
    case huggingFace = "Hugging Face cache"
    case lmStudio = "LM Studio"
    case looseGGUF = "Loose GGUF"

    var rootDescription: String {
        switch self {
        case .ollama: return "~/.ollama/models"
        case .huggingFace: return "~/.cache/huggingface/hub"
        case .lmStudio: return "~/.lmstudio/models"
        case .looseGGUF: return "Home folder scan"
        }
    }
}

struct ModelFile: Identifiable, Hashable {
    var id: String { path }
    let path: String
    var displayName: String
    var store: ModelStore
    var sizeBytes: UInt64
    var lastUsedAt: Date?
    /// Lowercased name with store prefixes and extension stripped — the
    /// first half of the duplicate-grouping key.
    var normalizedName: String
}

struct DuplicateGroup: Identifiable {
    var id: String { normalizedName + ":" + String(sizeBytes) }
    let normalizedName: String
    let sizeBytes: UInt64
    var files: [ModelFile]
    /// Bytes recoverable by deleting all but one copy.
    var reclaimableBytes: UInt64 {
        guard files.count > 1 else { return 0 }
        return sizeBytes * UInt64(files.count - 1)
    }
}

// MARK: - Startup items

enum StartupSource: String {
    case userLaunchAgent = "User LaunchAgent"
    case systemLaunchAgent = "System LaunchAgent"
    case systemLaunchDaemon = "System LaunchDaemon"
    case loginItem = "Login item"

    var directory: String {
        switch self {
        case .userLaunchAgent: return "~/Library/LaunchAgents"
        case .systemLaunchAgent: return "/Library/LaunchAgents"
        case .systemLaunchDaemon: return "/Library/LaunchDaemons"
        case .loginItem: return "System Settings"
        }
    }
}

struct StartupItem: Identifiable, Hashable {
    var id: String { source.rawValue + ":" + label }
    var label: String
    var executable: String?
    var arguments: [String] = []
    var runAtLoad: Bool = false
    var isEnabled: Bool = true
    var source: StartupSource
    var plistPath: String?
}

// MARK: - Licensing

enum LicenseState: Equatable {
    /// Full features, gentle reminders only. v1 trials do not hard-lock.
    case trial(daysSinceFirstLaunch: Int)
    case full
    /// Reserved for a future hard-expiry policy; the gate shows this
    /// state exists so the UI copy is honest about what would happen.
    case locked

    var isFull: Bool { self == .full }

    var label: String {
        switch self {
        case .trial: return "Trial"
        case .full: return "Licensed"
        case .locked: return "Locked"
        }
    }
}

// MARK: - History

/// One line of the append-only JSONL history file. Written locally only;
/// nothing in this struct ever leaves the machine.
struct HistoryEvent: Codable {
    var timestamp: Date
    var kind: String          // "thermal-transition", "runaway", "engine-session"
    var summary: String
    var value: Double?
}
