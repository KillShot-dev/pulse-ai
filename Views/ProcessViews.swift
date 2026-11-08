import SwiftUI

/// Process list + inspector. The inspector is the Verdict surface:
/// signing truth, genealogy, lifetime totals, and signal-based
/// Quit / Force Quit behind a confirmation.
struct ProcessListView: View {
    @EnvironmentObject private var engine: ProcessEngine
    @State private var searchText = ""
    @State private var selectedPID: pid_t?
    @State private var sortOrder = [KeyPathComparator(\ProcessSnapshot.cpuPercent, order: .reverse)]

    private var filtered: [ProcessSnapshot] {
        let base = searchText.isEmpty
            ? engine.processes
            : engine.processes.filter {
                $0.name.localizedCaseInsensitiveContains(searchText)
                    || String($0.pid) == searchText
                    || ($0.path?.localizedCaseInsensitiveContains(searchText) ?? false)
            }
        return base.sorted(using: sortOrder)
    }

    private var selected: ProcessSnapshot? {
        guard let selectedPID else { return nil }
        return engine.processes.first { $0.pid == selectedPID }
    }

    var body: some View {
        HSplitView {
            Table(filtered, selection: $selectedPID, sortOrder: $sortOrder) {
                TableColumn("Process", value: \.name) { proc in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(PulseTheme.health(forCPUFraction: proc.cpuPercent / 100).color)
                            .frame(width: 8, height: 8)
                        Text(proc.name).lineLimit(1)
                    }
                }
                TableColumn("PID", value: \.pid) { proc in
                    Text("\(proc.pid)").font(PulseTheme.smallMonoFont)
                }.width(52)
                TableColumn("CPU", value: \.cpuPercent) { proc in
                    Text(Format.cpuPercent(proc.cpuPercent)).font(PulseTheme.smallMonoFont)
                }.width(64)
                TableColumn("Memory", value: \.residentBytes) { proc in
                    Text(Format.bytes(proc.residentBytes)).font(PulseTheme.smallMonoFont)
                }.width(84)
                TableColumn("User", value: \.user)
            }
            .searchable(text: $searchText, prompt: "Filter processes")
            .frame(minWidth: 430)

            Group {
                if let proc = selected {
                    ProcessInspectorView(snapshot: proc)
                } else {
                    ContentUnavailableView("No Process Selected",
                                           systemImage: "app.dashed",
                                           description: Text("Select a process to see who signed it, what launched it, and what it has used since it started."))
                }
            }
            .frame(minWidth: 340)
        }
    }
}

// MARK: - Inspector

struct ProcessInspectorView: View {
    @EnvironmentObject private var engine: ProcessEngine
    let snapshot: ProcessSnapshot

    @State private var verdict: Verdict?
    @State private var verdictPID: pid_t?
    @State private var pendingTermination: Bool?   // false = quit, true = force quit
    @State private var terminationNote: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                verdictCard
                genealogyCard
                totalsCard
                actions
                if let terminationNote {
                    Text(terminationNote).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(14)
        }
        .task(id: snapshot.pid) { loadVerdict() }
        .alert(item: pendingTerminationItem) { force in
            Alert(
                title: Text(force ? "Force Quit \(snapshot.name)?" : "Quit \(snapshot.name)?"),
                message: Text(force
                    ? "SIGKILL ends the process immediately. Unsaved work in it will be lost."
                    : "SIGTERM asks the process to exit. It may decline or prompt to save."),
                primaryButton: .destructive(Text(force ? "Force Quit" : "Quit")) {
                    terminate(force: force)
                },
                secondaryButton: .cancel())
        }
    }

    private var pendingTerminationItem: Binding<ForceFlag?> {
        Binding(
            get: { pendingTermination.map(ForceFlag.init) },
            set: { pendingTermination = $0?.value })
    }

    private struct ForceFlag: Identifiable {
        var value: Bool
        var id: Bool { value }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(snapshot.name).font(.title3).bold().lineLimit(2)
            Text("pid \(snapshot.pid) · user \(snapshot.user)")
                .font(.caption).foregroundStyle(.secondary)
            if let path = snapshot.path {
                Text(path).font(PulseTheme.smallMonoFont)
                    .foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }

    private var verdictCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Verdict").font(PulseTheme.cardTitleFont)
            if let verdict {
                Text(verdict.summary)
                LabeledContent("Team ID", value: verdict.teamID ?? "—")
                LabeledContent("Identifier", value: verdict.identifier ?? "—")
                LabeledContent("Notarization", value: verdict.notarization.rawValue)
                LabeledContent("Hardened Runtime", value: verdict.isHardenedRuntime ? "Yes" : "No")
                if !verdict.authorityChain.isEmpty {
                    LabeledContent("Signed by", value: verdict.authorityChain.first ?? "—")
                }
                Divider()
                switch verdict.safeToQuit {
                case .some(true):
                    Label("Likely safe to quit — see reasoning", systemImage: "checkmark.circle")
                        .foregroundStyle(.green)
                case .some(false):
                    Label("Do not quit — see reasoning", systemImage: "hand.raised.fill")
                        .foregroundStyle(.red)
                default:
                    Label("No clear quit signal — reasoning below", systemImage: "questionmark.circle")
                        .foregroundStyle(.secondary)
                }
                ForEach(verdict.safeToQuitReasons, id: \.self) { reason in
                    Text("• \(reason)").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                ProgressView("Reading signature…")
            }
        }
        .padding(PulseTheme.cardPadding)
        .background { PulseTheme.cardBackground() }
    }

    private var genealogyCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("What launched it").font(PulseTheme.cardTitleFont)
            let chain = engine.ancestry(of: snapshot.pid).reversed()
            ForEach(Array(chain.enumerated()), id: \.element.pid) { index, node in
                HStack(spacing: 6) {
                    Text(String(repeating: "› ", count: index)).foregroundStyle(.tertiary)
                    Text(node.name)
                    Text("pid \(node.pid)").font(PulseTheme.smallMonoFont).foregroundStyle(.secondary)
                }
                .font(.callout)
            }
        }
        .padding(PulseTheme.cardPadding)
        .background { PulseTheme.cardBackground() }
    }

    private var totalsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Since it started").font(PulseTheme.cardTitleFont)
            LabeledContent("CPU time (total)", value: Format.duration(snapshot.lifetimeCPUSeconds))
            LabeledContent("— user", value: Format.duration(snapshot.userCPUSeconds))
            LabeledContent("— system", value: Format.duration(snapshot.systemCPUSeconds))
            LabeledContent("Resident memory", value: Format.bytes(snapshot.residentBytes))
            LabeledContent("Threads", value: "\(snapshot.threadCount)")
            if let start = snapshot.startTime {
                LabeledContent("Started", value: start.formatted(date: .abbreviated, time: .shortened))
            }
        }
        .padding(PulseTheme.cardPadding)
        .background { PulseTheme.cardBackground() }
    }

    private var actions: some View {
        HStack {
            Button("Quit") { pendingTermination = false }
            Button("Force Quit", role: .destructive) { pendingTermination = true }
            Spacer()
        }
    }

    // MARK: Actions

    private func loadVerdict() {
        let pid = snapshot.pid
        Task.detached(priority: .userInitiated) {
            let result = SigningService.verdict(forPID: pid)
            await MainActor.run {
                verdict = result
                verdictPID = pid
            }
        }
    }

    private func terminate(force: Bool) {
        switch engine.terminate(pid: snapshot.pid, force: force) {
        case .signalled:
            terminationNote = force ? "SIGKILL sent." : "SIGTERM sent."
        case .notPermitted:
            terminationNote = "Not permitted — this process belongs to another user or the system. The optional helper (disabled in v1) is the path for root-owned processes."
        case .noSuchProcess:
            terminationNote = "The process already exited."
        case .failed(let code):
            terminationNote = "Signal failed (errno \(code))."
        }
    }
}
