import Foundation

/// Append-only local history. One JSON object per line under
/// Application Support/PulseAI/history.jsonl, rotated at 10 MB
/// (history.jsonl → history.1.jsonl, single generation kept).
/// Nothing in this file is ever transmitted anywhere — the store has
/// no networking code at all, by design.
final class HistoryStore {
    static let shared = HistoryStore()

    static let maxBytes: Int64 = 10 * 1024 * 1024

    private let queue = DispatchQueue(label: "com.metaphasicgroup.pulseai.history")
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private(set) var fileURL: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("PulseAI", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("history.jsonl")
    }

    func append(_ event: HistoryEvent) {
        queue.async { [weak self] in
            guard let self, let line = try? self.encoder.encode(event) else { return }
            self.rotateIfNeeded()
            var payload = line
            payload.append(0x0A) // newline
            if let handle = try? FileHandle(forWritingTo: self.fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: payload)
            } else {
                try? payload.write(to: self.fileURL, options: [.atomic])
            }
        }
    }

    private func rotateIfNeeded() {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: fileURL.path),
              let size = attrs[.size] as? NSNumber,
              size.int64Value >= Self.maxBytes else { return }
        let rotated = fileURL.deletingPathExtension().appendingPathExtension("1.jsonl")
        try? fm.removeItem(at: rotated)
        try? fm.moveItem(at: fileURL, to: rotated)
    }

    /// Recent events for the History-facing UI (newest last).
    func recentEvents(limit: Int = 200) -> [HistoryEvent] {
        guard let data = try? Data(contentsOf: fileURL),
              let text = String(data: data, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let lines = text.split(separator: "\n").suffix(limit)
        return lines.compactMap { line in
            try? decoder.decode(HistoryEvent.self, from: Data(line.utf8))
        }
    }
}
