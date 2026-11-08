import Foundation

/// The Pulse AI privileged helper's XPC surface — an ALLOW-LIST, not a
/// general RPC channel. The helper ships DISABLED in v1 (see
/// Helper/README.md); this protocol exists so the security review
/// (and the eventual enablement) has exactly three calls to reason
/// about:
///
///   - powerSample:              powermetrics-grade power figures
///   - thermalDetail:            full thermal/clock detail
///   - terminateProcessOwnedByRoot: SIGTERM a root-owned pid, only
///     after the helper re-validates the caller's intent token
///
/// There is deliberately NO "run command", NO file access, NO
/// arbitrary-signal call. Every reply is a value type; every input is
/// validated again inside the helper.
@objc(PulseHelperProtocol)
public protocol PulseHelperProtocol {
    /// Combined CPU/GPU/ANE package power in milliwatts, sampled over
    /// `sampleMilliseconds` (clamped 100–5000 inside the helper).
    func powerSample(sampleMilliseconds: Int,
                     withReply reply: @escaping (_ milliwatts: NSNumber?,
                                                 _ errorMessage: String?) -> Void)

    /// Thermal detail beyond ProcessInfo: a dictionary with keys
    /// cpuDieCelsius, gpuDieCelsius, fanRPMs ([NSNumber]) — values may
    /// be absent on hardware that does not report them.
    func thermalDetail(withReply reply: @escaping (_ detail: NSDictionary?,
                                                   _ errorMessage: String?) -> Void)

    /// Terminates a root-owned process with SIGTERM. `intentToken` is
    /// a one-shot UUID the app obtained from the user's confirmation
    /// dialog; the helper tracks issued tokens and rejects replays.
    func terminateProcessOwnedByRoot(pid: Int32,
                                     intentToken: String,
                                     withReply reply: @escaping (_ success: Bool,
                                                                 _ errorMessage: String?) -> Void)
}

/// Mach service name the helper registers (must match its LaunchDaemon
/// plist's MachServices key when enabled).
public let pulseHelperMachServiceName = "com.metaphasicgroup.pulseai.helper"

/// The designated requirement the helper enforces on every incoming
/// connection: Apple-anchored, our bundle id family, OUR Team ID.
/// TEAMIDPLACEHOLDER is replaced at release time with the real
/// Developer Team ID — the helper refuses to run while the placeholder
/// is still present (see PulseAIHelper.swift).
public let pulseHelperClientRequirement =
    "anchor apple generic and certificate leaf[subject.OU] = \"TEAMIDPLACEHOLDER\""
