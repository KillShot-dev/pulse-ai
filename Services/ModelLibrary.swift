import Foundation

/// Model inventory across every local store an AI box accumulates:
/// Ollama's blob store, the Hugging Face hub cache, LM Studio's model
/// folders, and loose .gguf files elsewhere in the home directory.
///
/// Read-only, size-only (no content hashing in v1 — identity is
/// (size, normalized name), which is the duplicate heuristic the spec
/// calls for). The home walk is deliberately bounded: depth-capped,
/// skips the big Library caches that cannot hold user models, and
/// refuses to follow symlinks into loops.
final class ModelLibraryScanner {

    struct Result {
        var files: [ModelFile] = []
        var duplicateGroups: [DuplicateGroup] = []
        var totalBytes: UInt64 = 0
        var totalReclaimableBytes: UInt64 = 0
        var scannedAt: Date = Date()
    }

    private let fileManager = FileManager.default
    private let maxHomeWalkDepth = 6
    private let homeSkipNames: Set<String> = [
        "Library", "Movies", "Music", "Pictures", ".Trash",
        ".cache", ".ollama", ".lmstudio", "Applications",
    ]

    func scan() -> Result {
        var result = Result()
        var files: [ModelFile] = []

        let home = fileManager.homeDirectoryForCurrentUser
        files += scanOllama(root: home.appendingPathComponent(".ollama/models"))
        files += scanHuggingFace(root: home.appendingPathComponent(".cache/huggingface/hub"))
        files += scanLMStudio(roots: [
            home.appendingPathComponent(".lmstudio/models"),
            home.appendingPathComponent("Library/Application Support/LM Studio/models"),
        ])
        files += scanLooseGGUF(home: home)

        result.files = files.sorted { $0.sizeBytes > $1.sizeBytes }
        result.totalBytes = files.reduce(0) { $0 + $1.sizeBytes }

        // Duplicate grouping: same bytes, same normalized name.
        var byKey: [String: [ModelFile]] = [:]
        for file in files {
            byKey["\(file.sizeBytes)|\(file.normalizedName)", default: []].append(file)
        }
        result.duplicateGroups = byKey.values
            .filter { $0.count > 1 }
            .map { group in
                DuplicateGroup(normalizedName: group[0].normalizedName,
                               sizeBytes: group[0].sizeBytes,
                               files: group.sorted { $0.path < $1.path })
            }
            .sorted { $0.reclaimableBytes > $1.reclaimableBytes }
        result.totalReclaimableBytes = result.duplicateGroups.reduce(0) { $0 + $1.reclaimableBytes }
        result.scannedAt = Date()
        return result
    }

    // MARK: - Stores

    /// Ollama keeps weights as content-addressed blobs and metadata as
    /// manifests; the user-meaningful unit is the model directory under
    /// manifests/registry.ollama.ai. We report per-model totals by
    /// summing blobs referenced from each manifest is over-engineering
    /// for v1 — instead each blob file is listed under the Ollama store
    /// and manifests contribute their model names. Sizes still add up.
    private func scanOllama(root: URL) -> [ModelFile] {
        guard fileManager.fileExists(atPath: root.path) else { return [] }
        let blobs = root.appendingPathComponent("blobs")
        var out: [ModelFile] = []
        for url in collectFiles(under: blobs, extensions: nil, maxDepth: 2) {
            let size = fileSize(url)
            guard size > 0 else { continue }
            out.append(ModelFile(
                path: url.path,
                displayName: "Ollama blob \(url.lastPathComponent.prefix(19))…",
                store: .ollama,
                sizeBytes: size,
                lastUsedAt: modificationDate(url),
                normalizedName: Self.normalize(url.lastPathComponent)))
        }
        // Manifest names give the library human-readable model entries
        // even though blob accounting carries the bytes.
        let manifests = root.appendingPathComponent("manifests")
        for url in collectFiles(under: manifests, extensions: nil, maxDepth: 6) {
            let relative = url.path.replacingOccurrences(of: manifests.path + "/", with: "")
            out.append(ModelFile(
                path: url.path,
                displayName: relative,
                store: .ollama,
                sizeBytes: 0,
                lastUsedAt: modificationDate(url),
                normalizedName: Self.normalize(relative)))
        }
        return out
    }

    private func scanHuggingFace(root: URL) -> [ModelFile] {
        guard fileManager.fileExists(atPath: root.path) else { return [] }
        var out: [ModelFile] = []
        // Each entry is a directory models--org--name containing snapshots.
        guard let entries = try? fileManager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        else { return [] }
        for entry in entries {
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: entry.path, isDirectory: &isDir), isDir.boolValue,
                  entry.lastPathComponent.hasPrefix("models--") else { continue }
            let size = directorySize(entry, maxDepth: 5)
            guard size > 0 else { continue }
            let name = entry.lastPathComponent
                .replacingOccurrences(of: "models--", with: "")
                .replacingOccurrences(of: "--", with: "/")
            out.append(ModelFile(
                path: entry.path,
                displayName: name,
                store: .huggingFace,
                sizeBytes: size,
                lastUsedAt: modificationDate(entry),
                normalizedName: Self.normalize(name)))
        }
        return out
    }

    private func scanLMStudio(roots: [URL]) -> [ModelFile] {
        var out: [ModelFile] = []
        for root in roots where fileManager.fileExists(atPath: root.path) {
            for url in collectFiles(under: root, extensions: ["gguf", "safetensors"], maxDepth: 5) {
                let size = fileSize(url)
                guard size > 0 else { continue }
                out.append(ModelFile(
                    path: url.path,
                    displayName: url.lastPathComponent,
                    store: .lmStudio,
                    sizeBytes: size,
                    lastUsedAt: modificationDate(url),
                    normalizedName: Self.normalize(url.lastPathComponent)))
            }
        }
        return out
    }

    private func scanLooseGGUF(home: URL) -> [ModelFile] {
        collectFiles(under: home, extensions: ["gguf"], maxDepth: maxHomeWalkDepth,
                     skipTopLevelNames: homeSkipNames)
            .map { url in
                ModelFile(path: url.path,
                          displayName: url.lastPathComponent,
                          store: .looseGGUF,
                          sizeBytes: fileSize(url),
                          lastUsedAt: modificationDate(url),
                          normalizedName: Self.normalize(url.lastPathComponent))
            }
            .filter { $0.sizeBytes > 0 }
    }

    // MARK: - Walking helpers (symlink-safe, depth-capped, error-tolerant)

    private func collectFiles(under root: URL,
                              extensions exts: Set<String>?,
                              maxDepth: Int,
                              skipTopLevelNames: Set<String> = []) -> [URL] {
        guard fileManager.fileExists(atPath: root.path) else { return [] }
        var out: [URL] = []
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let enumerator = fileManager.enumerator(
            at: root, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }

        let rootDepth = root.pathComponents.count
        for case let url as URL in enumerator {
            let depth = url.pathComponents.count - rootDepth
            if depth > maxDepth {
                enumerator.skipDescendants()
                continue
            }
            // Never follow symlinks: a link inside a model dir pointing
            // at / would otherwise walk the whole disk.
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            if depth == 1, skipTopLevelNames.contains(url.lastPathComponent) {
                enumerator.skipDescendants()
                continue
            }
            guard values?.isRegularFile == true else { continue }
            if let exts, !exts.contains(url.pathExtension.lowercased()) { continue }
            out.append(url)
        }
        return out
    }

    private func directorySize(_ url: URL, maxDepth: Int) -> UInt64 {
        collectFiles(under: url, extensions: nil, maxDepth: maxDepth)
            .reduce(0) { $0 + fileSize($1) }
    }

    private func fileSize(_ url: URL) -> UInt64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .totalFileAllocatedSizeKey])
        if let allocated = values?.totalFileAllocatedSize, allocated > 0 {
            return UInt64(allocated)
        }
        return UInt64(values?.fileSize ?? 0)
    }

    private func modificationDate(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    /// "llama-3.1-8b-instruct-Q4_K_M.gguf" → "llama 3.1 8b instruct"
    /// (quant suffix and separators stripped so the same weights under
    /// two stores group together when byte sizes also match).
    static func normalize(_ raw: String) -> String {
        var name = (raw as NSString).deletingPathExtension.lowercased()
        name = name.replacingOccurrences(of: "sha256-", with: "")
        let separators = CharacterSet(charactersIn: "-_./ ")
        var parts = name.components(separatedBy: separators).filter { !$0.isEmpty }
        let quantPattern = try? NSRegularExpression(pattern: "^(q|iq|f|bf)\\d")
        parts.removeAll { part in
            if part.hasPrefix("gguf") || part == "instruct" && false { return false }
            if let quantPattern, quantPattern.firstMatch(in: part, range: NSRange(part.startIndex..., in: part)) != nil {
                return true
            }
            return ["q4", "q5", "q6", "q8", "f16", "f32"].contains { part.hasPrefix($0) }
        }
        return parts.joined(separator: " ")
    }
}

/// Observable wrapper so views can trigger and watch scans.
@MainActor
final class ModelLibraryModel: ObservableObject {
    @Published private(set) var result: ModelLibraryScanner.Result?
    @Published private(set) var isScanning = false

    func scan() {
        guard !isScanning else { return }
        isScanning = true
        Task.detached(priority: .utility) {
            let scanned = ModelLibraryScanner().scan()
            await MainActor.run { [weak self] in
                self?.result = scanned
                self?.isScanning = false
            }
        }
    }
}
