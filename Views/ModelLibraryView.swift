import SwiftUI
import AppKit

/// Model Library: one inventory across Ollama, the Hugging Face cache,
/// LM Studio and loose GGUFs, with duplicate groups and the
/// reclaimable total up top (spec, Feature set C.5).
struct ModelLibraryView: View {
    @StateObject private var library = ModelLibraryModel()
    @State private var searchText = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let result = library.result {
                Table(filteredFiles(in: result)) {
                    TableColumn("Model", value: \.displayName) { file in
                        Text(file.displayName).lineLimit(1)
                    }
                    TableColumn("Store", value: \.store.rawValue) { file in
                        Text(file.store.rawValue)
                    }
                    TableColumn("Size", value: \.sizeBytes) { file in
                        Text(Format.bytes(file.sizeBytes)).font(PulseTheme.smallMonoFont)
                    }.width(90)
                    TableColumn("Last used") { file in
                        Text(file.lastUsedAt?.formatted(date: .abbreviated, time: .omitted) ?? "—")
                            .foregroundStyle(.secondary)
                    }.width(110)
                    TableColumn("") { file in
                        Button("Reveal") { reveal(file) }
                            .buttonStyle(.link)
                    }.width(60)
                }
                if !result.duplicateGroups.isEmpty {
                    duplicatesStrip(result)
                }
            } else if library.isScanning {
                Spacer()
                ProgressView("Scanning model stores…")
                Spacer()
            } else {
                Spacer()
                ContentUnavailableView("Not Scanned Yet",
                                       systemImage: "square.stack.3d.up.slash",
                                       description: Text("Pulse inventories Ollama blobs, the Hugging Face cache, LM Studio models and loose GGUF files — read-only, sizes only."))
                Spacer()
            }
        }
        .toolbar {
            Button {
                library.scan()
            } label: {
                Label(library.result == nil ? "Scan" : "Rescan", systemImage: "arrow.clockwise")
            }
            .disabled(library.isScanning)
        }
        .onAppear { if library.result == nil { library.scan() } }
    }

    private var header: some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Total on disk").font(.caption).foregroundStyle(.secondary)
                Text(library.result.map { Format.bytes($0.totalBytes) } ?? "—")
                    .font(PulseTheme.statValueFont)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Reclaimable duplicates").font(.caption).foregroundStyle(.secondary)
                Text(library.result.map { Format.bytes($0.totalReclaimableBytes) } ?? "—")
                    .font(PulseTheme.statValueFont)
                    .foregroundStyle((library.result?.totalReclaimableBytes ?? 0) > 0 ? .orange : .primary)
            }
            Spacer()
            if let scanned = library.result?.scannedAt {
                Text("Scanned \(scanned, style: .relative) ago")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14)
    }

    private func duplicatesStrip(_ result: ModelLibraryScanner.Result) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Duplicate groups — same size, same normalized name")
                .font(PulseTheme.cardTitleFont)
            ForEach(result.duplicateGroups) { group in
                HStack {
                    Text(group.normalizedName).lineLimit(1)
                    Spacer()
                    Text("\(group.files.count) copies · \(Format.bytes(group.reclaimableBytes)) reclaimable")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            Text("Pulse never deletes models. Review a group, then remove copies in Finder if you agree they are duplicates.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(14)
        .background(.regularMaterial)
    }

    private func filteredFiles(in result: ModelLibraryScanner.Result) -> [ModelFile] {
        // Zero-byte manifest entries are model *names*, not weights —
        // they belong in the Ollama cockpit card, not the size table.
        let sized = result.files.filter { $0.sizeBytes > 0 }
        guard !searchText.isEmpty else { return sized }
        return sized.filter { $0.displayName.localizedCaseInsensitiveContains(searchText) }
    }

    private func reveal(_ file: ModelFile) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file.path)])
    }
}
