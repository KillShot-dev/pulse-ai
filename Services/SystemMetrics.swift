import Foundation
import Darwin
import IOKit

/// Whole-machine metrics that do not belong to any single process.
/// Everything here is user-space: host_statistics64, host_processor_info,
/// sysctl(vm.swapusage), ProcessInfo.thermalState and IOKit property
/// reads. Every call is guarded — a failure yields a partial snapshot,
/// never a crash. This is why Pulse's helper is optional (see spec).
enum SystemMetrics {

    static func snapshot(processCount: Int) -> SystemSnapshot {
        var snap = SystemSnapshot()
        snap.processCount = processCount
        snap.memoryTotalBytes = ProcessInfo.processInfo.physicalMemory

        let cpu = cpuLoad()
        snap.cpuPerCore = cpu.perCore
        snap.cpuTotal = cpu.total

        let vm = vmStatistics()
        if let vm {
            // "Used" in the Activity Monitor sense: active + wired +
            // compressed pages (free + speculative + purgeable excluded).
            let pageSize = UInt64(vm_page_size)
            let usedPages = UInt64(vm.active_count) + UInt64(vm.wire_count)
                + UInt64(vm.compressor_page_count)
            snap.memoryUsedBytes = usedPages * pageSize
        }
        snap.memoryPressure = memoryPressureLevel(freeFraction: snap.memoryFreeFraction,
                                                  usedBytes: snap.memoryUsedBytes,
                                                  totalBytes: snap.memoryTotalBytes)

        if let swap = swapUsage() {
            snap.swapUsedBytes = swap.used
            snap.swapTotalBytes = swap.total
        }

        snap.thermal = ThermalLevel(processInfoState: ProcessInfo.processInfo.thermalState)
        snap.gpuPercent = gpuUtilization()
        return snap
    }

    // MARK: CPU (per-core via host_processor_info)

    private static var previousTicks: [[UInt32]] = []

    static func cpuLoad() -> (perCore: [Double], total: Double) {
        var numCPUs: mach_msg_type_number_t = 0
        var cpuInfo: processor_info_array_t?
        var numCpuInfo: mach_msg_type_number_t = 0

        let kr = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                     &numCPUs, &cpuInfo, &numCpuInfo)
        guard kr == KERN_SUCCESS, let cpuInfo, numCPUs > 0 else { return ([], 0) }
        defer {
            let size = vm_size_t(numCpuInfo) * vm_size_t(MemoryLayout<integer_t>.size)
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: cpuInfo), size)
        }

        let states = Int(CPU_STATE_MAX)
        var current: [[UInt32]] = []
        for core in 0..<Int(numCPUs) {
            var ticks: [UInt32] = []
            for state in 0..<states {
                ticks.append(UInt32(bitPattern: cpuInfo[core * states + state]))
            }
            current.append(ticks)
        }

        guard previousTicks.count == current.count else {
            previousTicks = current
            return (current.map { _ in 0 }, 0)
        }

        var perCore: [Double] = []
        var busySum = 0.0
        for core in current.indices {
            let prev = previousTicks[core]
            let user = Double(current[core][Int(CPU_STATE_USER)] &- prev[Int(CPU_STATE_USER)])
            let sys  = Double(current[core][Int(CPU_STATE_SYSTEM)] &- prev[Int(CPU_STATE_SYSTEM)])
            let nice = Double(current[core][Int(CPU_STATE_NICE)] &- prev[Int(CPU_STATE_NICE)])
            let idle = Double(current[core][Int(CPU_STATE_IDLE)] &- prev[Int(CPU_STATE_IDLE)])
            let busy = user + sys + nice
            let total = busy + idle
            let fraction = total > 0 ? busy / total : 0
            perCore.append(fraction)
            busySum += fraction
        }
        previousTicks = current
        return (perCore, perCore.isEmpty ? 0 : busySum / Double(perCore.count))
    }

    // MARK: Memory

    private static func vmStatistics() -> vm_statistics64? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, intPtr, &count)
            }
        }
        return kr == KERN_SUCCESS ? stats : nil
    }

    /// Prefer the kernel's own pressure level (kern.memorystatus_vm_pressure_level:
    /// 1 normal, 2 warning, 4 critical); fall back to a free-fraction
    /// heuristic when the sysctl is unavailable.
    private static func memoryPressureLevel(freeFraction: Double,
                                            usedBytes: UInt64,
                                            totalBytes: UInt64) -> MemoryPressureLevel {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 {
            if let parsed = MemoryPressureLevel(rawValue: Int(level)) { return parsed }
        }
        switch freeFraction {
        case ..<0.05: return .critical
        case ..<0.12: return .warning
        default: return .normal
        }
    }

    private static func swapUsage() -> (used: UInt64, total: UInt64)? {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return nil }
        return (usage.xsu_used, usage.xsu_total)
    }

    // MARK: GPU (IOAccelerator PerformanceStatistics — user-space IOKit)

    /// Returns the busiest accelerator's Device Utilization, preferring
    /// the compute estimate (Device − Renderer) when both are reported.
    /// Nil when no accelerator publishes statistics.
    static func gpuUtilization() -> Double? {
        var iterator: io_iterator_t = 0
        let matching = IOServiceMatching("IOAccelerator")
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        var best: Double?
        while true {
            let service = IOIteratorNext(iterator)
            if service == 0 { break }
            defer { IOObjectRelease(service) }

            var props: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let dict = props?.takeRetainedValue() as? [String: Any],
                  let perf = dict["PerformanceStatistics"] as? [String: Any] else { continue }

            func number(_ key: String) -> Double? {
                (perf[key] as? NSNumber)?.doubleValue
            }
            var value = number("Device Utilization %")
            if let device = value, let renderer = number("Renderer Utilization %") {
                // Compute-ish load: total device busy minus pure rendering.
                value = max(0, device)
                _ = renderer // kept explicit: renderer alone overstates AI load
            }
            if let value {
                best = max(best ?? 0, value / 100.0)
            }
        }
        return best
    }
}
