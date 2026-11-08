import Foundation
import Darwin

/// Process enumeration and sampling.
///
/// Data sources, all user-space and public: proc_listallpids /
/// proc_pidinfo(PROC_PIDTASKINFO) for CPU + resident size, proc_pidpath
/// for the executable path, proc_pid_rusage(RUSAGE_INFO_V4) for the
/// user/system CPU split where available, getpwuid for owner names.
/// No shell, no ps(1), no privilege required for the current user's
/// processes; other users' processes return whatever the kernel allows
/// and degrade gracefully.
@MainActor
final class ProcessEngine: ObservableObject {
    @Published private(set) var processes: [ProcessSnapshot] = []
    @Published private(set) var system: SystemSnapshot = SystemSnapshot()
    /// Rolling history for the dashboard traces (oldest → newest).
    @Published private(set) var history: [SystemSnapshot] = []

    private var timer: Timer?
    private var previousCPU: [pid_t: Double] = [:]
    private var previousStamp: [pid_t: TimeInterval] = [:]
    private var userNameCache: [uid_t: String] = [:]
    private let historyStore = HistoryStore.shared
    private var lastThermal: ThermalLevel = .nominal

    /// Sampling cadence. 1 Hz while the window is visible; the caller
    /// slows it on battery or when hidden (adaptive, per spec).
    var interval: TimeInterval = 1.0 {
        didSet { if timer != nil { restart() } }
    }

    private static let historyLimit = 300   // 5 minutes at 1 Hz

    func start() {
        guard timer == nil else { return }
        sample()
        restart()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func restart() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
    }

    // MARK: - Sampling

    func sample() {
        let now = Date()
        let pids = Self.allPIDs()
        var snapshots: [ProcessSnapshot] = []
        snapshots.reserveCapacity(pids.count)

        for pid in pids {
            guard let snap = snapshot(for: pid, now: now) else { continue }
            snapshots.append(snap)
        }
        // Hottest first: the default ordering everywhere in the UI.
        snapshots.sort { $0.cpuPercent > $1.cpuPercent }
        processes = snapshots

        var sys = SystemMetrics.snapshot(processCount: snapshots.count)
        sys.timestamp = now
        system = sys
        history.append(sys)
        if history.count > Self.historyLimit { history.removeFirst(history.count - Self.historyLimit) }

        if sys.thermal != lastThermal {
            historyStore.append(HistoryEvent(
                timestamp: now, kind: "thermal-transition",
                summary: "Thermal state \(lastThermal.label) → \(sys.thermal.label)",
                value: Double(sys.thermal.rawValue)))
            lastThermal = sys.thermal
        }
    }

    private func snapshot(for pid: pid_t, now: Date) -> ProcessSnapshot? {
        var taskInfo = proc_taskinfo()
        let taskSize = Int32(MemoryLayout<proc_taskinfo>.size)
        let rc = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &taskInfo, taskSize)
        guard rc == taskSize else { return nil }

        let totalCPU = (Double(taskInfo.pti_total_user) + Double(taskInfo.pti_total_system)) / 1_000_000_000.0
        var cpuPercent: Double = 0
        if let prevCPU = previousCPU[pid], let prevTime = previousStamp[pid] {
            let wall = now.timeIntervalSince1970 - prevTime
            if wall > 0 { cpuPercent = max(0, (totalCPU - prevCPU) / wall * 100.0) }
        }
        previousCPU[pid] = totalCPU
        previousStamp[pid] = now.timeIntervalSince1970

        // User/system split via rusage v4 — best effort: the rebound
        // cast is the pattern proc_pid_rusage expects; on any failure
        // the taskinfo totals still stand.
        var userSecs = Double(taskInfo.pti_total_user) / 1_000_000_000.0
        var sysSecs = Double(taskInfo.pti_total_system) / 1_000_000_000.0
        var rusage = rusage_info_v4()
        let rusageRC = withUnsafeMutableBytes(of: &rusage) { raw -> Int32 in
            guard let base = raw.baseAddress else { return -1 }
            return proc_pid_rusage(pid, RUSAGE_INFO_V4,
                                   base.assumingMemoryBound(to: rusage_info_t.self))
        }
        if rusageRC == 0 {
            userSecs = Double(rusage.ri_user_time) / 1_000_000_000.0
            sysSecs = Double(rusage.ri_system_time) / 1_000_000_000.0
        }

        var bsdInfo = proc_bsdinfo()
        let bsdSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        var ppid: pid_t = 0
        var uid: uid_t = 0
        var startTime: Date?
        if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsdInfo, bsdSize) == bsdSize {
            ppid = pid_t(bsdInfo.pbi_ppid)
            uid = bsdInfo.pbi_uid
            let startSec = TimeInterval(bsdInfo.pbi_start_tvsec)
            if startSec > 0 { startTime = Date(timeIntervalSince1970: startSec) }
        }

        let path = Self.path(for: pid)
        let name = Self.name(for: pid, path: path)

        return ProcessSnapshot(
            pid: pid,
            ppid: ppid,
            name: name,
            path: path,
            cpuPercent: cpuPercent,
            residentBytes: taskInfo.pti_resident_size,
            lifetimeCPUSeconds: totalCPU,
            userCPUSeconds: userSecs,
            systemCPUSeconds: sysSecs,
            threadCount: Int(taskInfo.pti_threadnum),
            startTime: startTime,
            user: userName(for: uid),
            uid: uid)
    }

    private static func allPIDs() -> [pid_t] {
        let estimated = proc_listallpids(nil, 0)
        guard estimated > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(estimated) + 64)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard filled > 0 else { return [] }
        return Array(pids.prefix(Int(filled))).filter { $0 > 0 }
    }

    private static func path(for pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let rc = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard rc > 0 else { return nil }
        return String(cString: buffer)
    }

    private static func name(for pid: pid_t, path: String?) -> String {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        if proc_name(pid, &buffer, UInt32(buffer.count)) > 0 {
            let n = String(cString: buffer)
            if !n.isEmpty { return n }
        }
        if let path { return (path as NSString).lastPathComponent }
        return "pid \(pid)"
    }

    private func userName(for uid: uid_t) -> String {
        if let cached = userNameCache[uid] { return cached }
        var name = String(uid)
        if let pw = getpwuid(uid), let cName = pw.pointee.pw_name {
            name = String(cString: cName)
        }
        userNameCache[uid] = name
        return name
    }

    // MARK: - Genealogy

    /// Builds the launchd-rooted forest for the current sample.
    /// Processes whose parent has exited attach to pid 1's subtree
    /// logically by being listed as roots — macOS reparents orphans to
    /// launchd, so ppid already reflects that in practice.
    func genealogy() -> [ProcessNode] {
        let byPID = Dictionary(uniqueKeysWithValues: processes.map { ($0.pid, $0) })
        var childrenOf: [pid_t: [ProcessSnapshot]] = [:]
        var roots: [ProcessSnapshot] = []
        for proc in processes {
            if proc.ppid > 0, proc.ppid != proc.pid, byPID[proc.ppid] != nil {
                childrenOf[proc.ppid, default: []].append(proc)
            } else {
                roots.append(proc)
            }
        }
        func node(for snap: ProcessSnapshot, depth: Int) -> ProcessNode {
            guard depth < 32 else { return ProcessNode(snapshot: snap, children: []) }
            let kids = (childrenOf[snap.pid] ?? [])
                .sorted { $0.cpuPercent > $1.cpuPercent }
                .map { node(for: $0, depth: depth + 1) }
            return ProcessNode(snapshot: snap, children: kids)
        }
        return roots.sorted { $0.pid < $1.pid }.map { node(for: $0, depth: 0) }
    }

    /// The parent chain for one process, itself first, root last.
    func ancestry(of pid: pid_t) -> [ProcessSnapshot] {
        let byPID = Dictionary(uniqueKeysWithValues: processes.map { ($0.pid, $0) })
        var chain: [ProcessSnapshot] = []
        var current = byPID[pid]
        var seen = Set<pid_t>()
        while let node = current, !seen.contains(node.pid) {
            chain.append(node)
            seen.insert(node.pid)
            guard node.ppid > 0, node.ppid != node.pid else { break }
            current = byPID[node.ppid]
        }
        return chain
    }

    // MARK: - Termination (signals only — never a shell)

    enum TerminateResult {
        case signalled, notPermitted, noSuchProcess, failed(Int32)
    }

    /// Sends SIGTERM (force=false) or SIGKILL (force=true) directly via
    /// kill(2). The UI confirms with the user before calling this.
    func terminate(pid: pid_t, force: Bool) -> TerminateResult {
        let sig = force ? SIGKILL : SIGTERM
        if kill(pid, sig) == 0 { return .signalled }
        switch errno {
        case EPERM: return .notPermitted
        case ESRCH: return .noSuchProcess
        default: return .failed(errno)
        }
    }
}
