import Foundation

// MARK: - Loopback-only HTTP (security boundary — see SECURITY.md)
//
// Pulse's ONLY networking in the app target is this client, and it is
// deliberately incapable of talking to anything except a local AI
// engine:
//   • Host is hardcoded to 127.0.0.1; callers supply only a path.
//   • Port comes from EngineKind's fixed table — no caller input.
//   • Redirects are refused, and a redirect toward a non-loopback
//     target is refused twice (delegate + pre-flight host check).
//   • 2 second timeouts, 256 KB response cap enforced mid-download.
//   • Plain HTTP on loopback only (these engines serve no TLS locally).

enum LoopbackError: Error {
    case responseTooLarge
    case badStatus(Int)
    case notLoopback
    case transport(String)
}

final class LoopbackHTTPClient: NSObject, URLSessionDataDelegate {
    static let shared = LoopbackHTTPClient()

    static let maxResponseBytes = 256 * 1024
    static let timeout: TimeInterval = 2.0

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = Self.timeout
        config.timeoutIntervalForResource = Self.timeout
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    /// Mutable per-task accumulation state, keyed by task identity.
    private final class TaskState {
        var data = Data()
        var completion: (Result<Data, Error>) -> Void = { _ in }
    }
    private var states: [ObjectIdentifier: TaskState] = [:]
    private let lock = NSLock()

    /// GET http://127.0.0.1:<port><path> — the only request shape that exists.
    func get(port: Int, path: String) async throws -> Data {
        guard (1...65535).contains(port) else { throw LoopbackError.notLoopback }
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = port
        components.path = path.hasPrefix("/") ? path : "/" + path
        guard let url = components.url, url.host == "127.0.0.1" else {
            throw LoopbackError.notLoopback
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("PulseAI/1.0", forHTTPHeaderField: "User-Agent")

        let state = TaskState()
        return try await withCheckedThrowingContinuation { continuation in
            state.completion = { continuation.resume(with: $0) }
            let task = session.dataTask(with: request)
            lock.lock()
            states[ObjectIdentifier(task)] = state
            lock.unlock()
            task.resume()
        }
    }

    // MARK: URLSessionDataDelegate

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        // Engines never legitimately redirect. Refuse all redirects so a
        // compromised local service cannot bounce Pulse off-loopback.
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            finish(task: dataTask, with: .failure(LoopbackError.badStatus(http.statusCode)))
            completionHandler(.cancel)
            return
        }
        if response.expectedContentLength > Self.maxResponseBytes {
            finish(task: dataTask, with: .failure(LoopbackError.responseTooLarge))
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let key = ObjectIdentifier(dataTask)
        lock.lock()
        let state = states[key]
        lock.unlock()
        guard let state else { return }
        state.data.append(data)
        if state.data.count > Self.maxResponseBytes {
            finish(task: dataTask, with: .failure(LoopbackError.responseTooLarge))
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let key = ObjectIdentifier(task)
        lock.lock()
        let state = states.removeValue(forKey: key)
        lock.unlock()
        guard let state else { return }
        if let error {
            state.completion(.failure(LoopbackError.transport(error.localizedDescription)))
        } else {
            state.completion(.success(state.data))
        }
    }

    private func finish(task: URLSessionTask, with result: Result<Data, Error>) {
        let key = ObjectIdentifier(task)
        lock.lock()
        let state = states.removeValue(forKey: key)
        lock.unlock()
        state?.completion(result)
    }
}

// MARK: - Engine client protocol

protocol EngineClient {
    var kind: EngineKind { get }
    /// Poll once. ANY failure degrades to an offline status — never throws
    /// past this boundary, never crashes the caller.
    func poll() async -> EngineStatus
}

extension EngineClient {
    func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        // Defensive decoding: unknown fields tolerated by construction
        // (synthesized Codable ignores extras); a shape change yields nil
        // and the caller falls back to a minimal online status.
        try? JSONDecoder().decode(type, from: data)
    }

    func offline(error: String?) -> EngineStatus {
        var status = EngineStatus(kind: kind)
        status.isOnline = false
        status.lastErrorSummary = error
        status.lastPolledAt = Date()
        return status
    }
}

// MARK: - Ollama (GET /api/ps, /api/tags — port 11434)

struct OllamaClient: EngineClient {
    let kind = EngineKind.ollama

    private struct PSResponse: Decodable {
        struct Model: Decodable {
            var name: String?
            var model: String?
            var size: UInt64?
            var digest: String?
            struct Details: Decodable {
                var format: String?
                var parameter_size: String?
                var quantization_level: String?
            }
            var details: Details?
            var expires_at: String?
            var size_vram: UInt64?
            var context_length: Int?
        }
        var models: [Model]?
    }

    private struct VersionResponse: Decodable { var version: String? }

    func poll() async -> EngineStatus {
        do {
            let started = Date()
            let data = try await LoopbackHTTPClient.shared.get(port: kind.port, path: "/api/ps")
            let latency = Date().timeIntervalSince(started) * 1000
            var status = EngineStatus(kind: kind)
            status.isOnline = true
            status.latencyMilliseconds = latency
            status.lastPolledAt = Date()

            if let versionData = try? await LoopbackHTTPClient.shared.get(port: kind.port, path: "/api/version"),
               let version = decode(VersionResponse.self, from: versionData) {
                status.version = version.version
            }

            if let ps = decode(PSResponse.self, from: data) {
                status.loadedModels = (ps.models ?? []).map { model in
                    LoadedModel(
                        engine: kind,
                        name: model.name ?? model.model ?? "unknown",
                        quantization: model.details?.quantization_level,
                        parameterSize: model.details?.parameter_size,
                        sizeBytes: model.size,
                        memoryBytes: model.size_vram,
                        contextLength: model.context_length,
                        kvCacheUsageRatio: nil,
                        expiresAt: model.expires_at.flatMap(Self.parseISO8601))
                }
            }
            // Ollama exposes no passive tok/s (research §3.1): throughput
            // is unavailable passively, never invented.
            status.throughput = Throughput(tokensPerSecond: nil, provenance: .unavailable,
                                           methodNote: "Ollama reports tok/s only inside its own responses")
            return status
        } catch {
            return offline(error: String(describing: error))
        }
    }

    static func parseISO8601(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }
}

// MARK: - LM Studio (GET /api/v0/models — port 1234)

struct LMStudioClient: EngineClient {
    let kind = EngineKind.lmStudio

    private struct ModelsResponse: Decodable {
        struct Model: Decodable {
            var id: String?
            var type: String?
            var publisher: String?
            var arch: String?
            var quantization: String?
            var state: String?
            var max_context_length: Int?
        }
        var data: [Model]?
    }

    func poll() async -> EngineStatus {
        do {
            let started = Date()
            let data = try await LoopbackHTTPClient.shared.get(port: kind.port, path: "/api/v0/models")
            var status = EngineStatus(kind: kind)
            status.isOnline = true
            status.latencyMilliseconds = Date().timeIntervalSince(started) * 1000
            status.lastPolledAt = Date()
            if let response = decode(ModelsResponse.self, from: data) {
                status.loadedModels = (response.data ?? [])
                    .filter { $0.state == "loaded" }
                    .map { model in
                        LoadedModel(engine: kind,
                                    name: model.id ?? "unknown",
                                    quantization: model.quantization,
                                    parameterSize: model.arch,
                                    sizeBytes: nil,
                                    memoryBytes: nil,
                                    contextLength: model.max_context_length,
                                    kvCacheUsageRatio: nil,
                                    expiresAt: nil)
                    }
            }
            status.throughput = Throughput(tokensPerSecond: nil, provenance: .unavailable,
                                           methodNote: "LM Studio reports tok/s only inside its own responses")
            return status
        } catch {
            return offline(error: String(describing: error))
        }
    }
}

// MARK: - llama.cpp (GET /health, /slots, /metrics — port 8080)

struct LlamaCppClient: EngineClient {
    let kind = EngineKind.llamaCpp

    private struct HealthResponse: Decodable { var status: String? }

    private struct Slot: Decodable {
        struct Params: Decodable { var n_ctx: Int? }
        var id: Int?
        var n_ctx: Int?
        var is_processing: Bool?
        var params: Params?
        struct NextToken: Decodable {
            var n_decoded: Int?
            var has_next_token: Bool?
        }
        var next_token: NextToken?
    }

    func poll() async -> EngineStatus {
        do {
            let started = Date()
            let healthData = try await LoopbackHTTPClient.shared.get(port: kind.port, path: "/health")
            guard let health = decode(HealthResponse.self, from: healthData),
                  health.status == "ok" else {
                return offline(error: "health check did not report ok")
            }
            var status = EngineStatus(kind: kind)
            status.isOnline = true
            status.latencyMilliseconds = Date().timeIntervalSince(started) * 1000
            status.lastPolledAt = Date()

            // Slots: live per-slot processing state and context size.
            if let slotsData = try? await LoopbackHTTPClient.shared.get(port: kind.port, path: "/slots"),
               let slots = decode([Slot].self, from: slotsData) {
                status.requestsInFlight = slots.filter { $0.is_processing == true }.count
                if let first = slots.first {
                    var model = LoadedModel(engine: kind, name: "llama-server model",
                                            quantization: nil, parameterSize: nil,
                                            sizeBytes: nil, memoryBytes: nil,
                                            contextLength: first.n_ctx ?? first.params?.n_ctx,
                                            kvCacheUsageRatio: nil, expiresAt: nil)
                    model.name = "llama.cpp (slot context)"
                    status.loadedModels = [model]
                }
            }

            // Metrics: Prometheus text. Defensive by design — gauge
            // names are matched by "contains" so upstream renames
            // degrade one gauge at a time instead of failing the poll.
            if let metricsData = try? await LoopbackHTTPClient.shared.get(port: kind.port, path: "/metrics"),
               let text = String(data: metricsData, encoding: .utf8) {
                let gauges = PrometheusParser.parse(text)
                if let kv = PrometheusParser.first(in: gauges, containing: "kv_cache_usage_ratio") {
                    if !status.loadedModels.isEmpty {
                        status.loadedModels[0].kvCacheUsageRatio = kv
                    }
                }
                if let processing = PrometheusParser.first(in: gauges, containing: "requests_processing") {
                    status.requestsInFlight = Int(processing)
                }
                if let deferred = PrometheusParser.first(in: gauges, containing: "requests_deferred") {
                    status.requestsQueued = Int(deferred)
                }
                // llama.cpp exposes cumulative predicted-token seconds;
                // the tokens-per-second gauge name has varied across
                // versions, so try the known spellings in order.
                let tps = PrometheusParser.first(in: gauges, containing: "tokens_predicted_seconds_total")
                    .flatMap { total -> Double? in
                        guard let tokens = PrometheusParser.first(in: gauges, containing: "tokens_predicted_total"),
                              total > 0 else { return nil }
                        return tokens / total
                    }
                    ?? PrometheusParser.first(in: gauges, containing: "predicted_tokens_seconds")
                    ?? PrometheusParser.first(in: gauges, containing: "tokens_per_second")
                if let tps {
                    status.throughput = Throughput(tokensPerSecond: tps, provenance: .measured,
                                                   methodNote: "llama.cpp /metrics")
                }
            }
            if status.throughput.tokensPerSecond == nil {
                status.throughput = Throughput(tokensPerSecond: nil, provenance: .unavailable,
                                               methodNote: "llama-server not started with --metrics, or no generation yet")
            }
            return status
        } catch {
            return offline(error: String(describing: error))
        }
    }
}

/// Minimal Prometheus exposition parser: `name{labels} value` lines,
/// comments skipped, last value wins.
enum PrometheusParser {
    static func parse(_ text: String) -> [String: Double] {
        var result: [String: Double] = [:]
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            guard let lastSpace = trimmed.lastIndex(of: " ") else { continue }
            let valuePart = trimmed[trimmed.index(after: lastSpace)...]
            guard let value = Double(valuePart) else { continue }
            var name = String(trimmed[..<lastSpace])
            if let brace = name.firstIndex(of: "{") { name = String(name[..<brace]) }
            result[name] = value
        }
        return result
    }

    static func first(in gauges: [String: Double], containing needle: String) -> Double? {
        for (name, value) in gauges where name.contains(needle) { return value }
        return nil
    }
}

// MARK: - MLX / mlx-lm (GET /health, /v1/models — port 8080)

struct MLXClient: EngineClient {
    let kind = EngineKind.mlx

    private struct ModelsResponse: Decodable {
        struct Model: Decodable { var id: String? }
        var data: [Model]?
    }

    func poll() async -> EngineStatus {
        // MLX's OpenAI-compatible server has no /health on all builds;
        // /v1/models answering at all is the health signal.
        do {
            let started = Date()
            let data = try await LoopbackHTTPClient.shared.get(port: kind.port, path: "/v1/models")
            var status = EngineStatus(kind: kind)
            status.isOnline = true
            status.latencyMilliseconds = Date().timeIntervalSince(started) * 1000
            status.lastPolledAt = Date()
            if let response = decode(ModelsResponse.self, from: data) {
                status.loadedModels = (response.data ?? []).map {
                    LoadedModel(engine: kind, name: $0.id ?? "mlx model",
                                quantization: nil, parameterSize: nil, sizeBytes: nil,
                                memoryBytes: nil, contextLength: nil,
                                kvCacheUsageRatio: nil, expiresAt: nil)
                }
            }
            // Research §3.4: no metrics/slots/KV telemetry exists for
            // mlx-lm. Presence is process-correlated only — say so.
            status.throughput = Throughput(tokensPerSecond: nil, provenance: .unavailable,
                                           methodNote: "MLX exposes no live telemetry; presence only")
            return status
        } catch {
            return offline(error: String(describing: error))
        }
    }
}

// MARK: - ComfyUI (GET /system_stats, /queue — port 8188)

struct ComfyUIClient: EngineClient {
    let kind = EngineKind.comfyUI

    private struct SystemStats: Decodable {
        struct Device: Decodable {
            var name: String?
            var vram_total: UInt64?
            var vram_free: UInt64?
        }
        var devices: [Device]?
    }

    private struct Queue: Decodable {
        var queue_running: [JSONValue]?
        var queue_pending: [JSONValue]?
    }

    /// Tolerates ComfyUI's loosely-typed queue payloads (arrays of
    /// mixed arrays) without failing the whole decode.
    enum JSONValue: Decodable {
        case array([JSONValue]), object([String: JSONValue]), string(String)
        case number(Double), bool(Bool), null
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() { self = .null }
            else if let v = try? container.decode(Bool.self) { self = .bool(v) }
            else if let v = try? container.decode(Double.self) { self = .number(v) }
            else if let v = try? container.decode(String.self) { self = .string(v) }
            else if let v = try? container.decode([JSONValue].self) { self = .array(v) }
            else if let v = try? container.decode([String: JSONValue].self) { self = .object(v) }
            else { self = .null }
        }
    }

    func poll() async -> EngineStatus {
        do {
            let started = Date()
            let statsData = try await LoopbackHTTPClient.shared.get(port: kind.port, path: "/system_stats")
            var status = EngineStatus(kind: kind)
            status.isOnline = true
            status.latencyMilliseconds = Date().timeIntervalSince(started) * 1000
            status.lastPolledAt = Date()
            if let stats = decode(SystemStats.self, from: statsData),
               let device = stats.devices?.first {
                status.deviceMemoryTotalBytes = device.vram_total
                status.deviceMemoryFreeBytes = device.vram_free
            }
            if let queueData = try? await LoopbackHTTPClient.shared.get(port: kind.port, path: "/queue"),
               let queue = decode(Queue.self, from: queueData) {
                status.requestsInFlight = queue.queue_running?.count ?? 0
                status.requestsQueued = queue.queue_pending?.count ?? 0
            }
            status.throughput = Throughput(tokensPerSecond: nil, provenance: .unavailable,
                                           methodNote: "ComfyUI progress is node-based, not token-based")
            return status
        } catch {
            return offline(error: String(describing: error))
        }
    }
}

// MARK: - Poll coordinator

/// Polls every engine on a slow cadence (engines change state far more
/// slowly than processes do) and publishes the roster.
@MainActor
final class EngineMonitor: ObservableObject {
    @Published private(set) var statuses: [EngineStatus] = EngineKind.allCases.map { EngineStatus(kind: $0) }

    private let clients: [EngineClient] = [
        OllamaClient(), LMStudioClient(), LlamaCppClient(), MLXClient(), ComfyUIClient(),
    ]
    private var task: Task<Void, Never>?

    /// llama.cpp and MLX share port 8080 by default; if llama.cpp
    /// answers, MLX's identical-port result is kept but the UI groups
    /// them — both statuses are honest ("something answered on 8080").
    func start(intervalSeconds: UInt64 = 3) {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollAll()
                try? await Task.sleep(nanoseconds: intervalSeconds * 1_000_000_000)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    func pollAll() async {
        var results: [EngineStatus] = []
        for client in clients {
            results.append(await client.poll())
        }
        statuses = results
    }

    var anyOnline: Bool { statuses.contains { $0.isOnline } }

    /// Best available live throughput for the menu bar mini.
    var headlineThroughput: Throughput {
        for status in statuses where status.isOnline {
            if let tps = status.throughput.tokensPerSecond, tps > 0 {
                return status.throughput
            }
        }
        return Throughput()
    }
}
