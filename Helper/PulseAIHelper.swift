import Foundation
import Security
import ServiceManagement

/// Pulse AI privileged helper — SHIPS DISABLED IN v1.
///
/// Why it exists at all: three things genuinely need root on macOS
/// (powermetrics-grade power sampling, full thermal/fan detail, and
/// terminating root-owned runaways). Everything else Pulse does is
/// user-space. This helper is compiled and reviewed ahead of need so
/// enablement is a packaging decision, not a rewrite (spec: helper is
/// OPTIONAL, ~90% of value is user-space).
///
/// Enablement path (NOT done in v1):
///   1. Replace TEAMIDPLACEHOLDER in XPCProtocol.swift + below with
///      the real Developer Team ID.
///   2. Ship as a LaunchDaemon via SMAppService.daemon(plistName:)
///      registration from the app (ServiceManagement), with a
///      MachServices entry for pulseHelperMachServiceName.
///   3. Sign helper + daemon plist with the same Team ID; the helper
///      validates every client against the same requirement it is
///      itself validated by.
///   4. Full security review sign-off (the fleet's MP-013 review).
///
/// The entry point below is written as a standalone daemon main:
/// build this folder as its own command-line target when enabling —
/// it is intentionally NOT part of the PulseAI app target in v1.

// MARK: - Client validation

/// Validates the process on the other end of an XPC connection using
/// its audit token (NOT the pid — pids are recyclable and racy).
final class ClientValidator {
    func isValid(connection: NSXPCConnection) -> Bool {
        // Fail closed while the Team ID placeholder is un-replaced:
        // a helper that cannot state whose clients it trusts must not
        // run at all.
        guard !pulseHelperClientRequirement.contains("TEAMIDPLACEHOLDER") else {
            return false
        }
        // The audit token is an opaque 32-byte struct; hand it to the
        // Security framework as data keyed by kSecGuestAttributeAudit.
        var token = connection.auditToken
        let tokenData = Data(bytes: &token,
                             count: MemoryLayout<audit_token_t>.size) as CFData
        let attributes = [kSecGuestAttributeAudit: tokenData] as CFDictionary
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess,
              let code else { return false }
        let requirementString = pulseHelperClientRequirement as CFString
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(requirementString, [], &requirement) == errSecSuccess,
              let requirement else { return false }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }
}

// MARK: - Service implementation

final class PulseHelperService: NSObject, PulseHelperProtocol {
    private var spentIntentTokens = Set<String>()
    private let tokenQueue = DispatchQueue(label: "com.metaphasicgroup.pulseai.helper.tokens")

    func powerSample(sampleMilliseconds: Int,
                     withReply reply: @escaping (NSNumber?, String?) -> Void) {
        let clamped = min(max(sampleMilliseconds, 100), 5000)
        // powermetrics invocation lives behind this method at
        // enablement time; until then the helper is disabled and this
        // code is never reachable in a shipped build. Replying with an
        // explicit error (not a fabricated number) is the contract.
        _ = clamped
        reply(nil, "Power sampling is disabled in this build (helper ships disabled in v1).")
    }

    func thermalDetail(withReply reply: @escaping (NSDictionary?, String?) -> Void) {
        reply(nil, "Thermal detail is disabled in this build (helper ships disabled in v1).")
    }

    func terminateProcessOwnedByRoot(pid: Int32,
                                     intentToken: String,
                                     withReply reply: @escaping (Bool, String?) -> Void) {
        // One-shot token: the app mints one per confirmed dialog; a
        // replayed or unknown token is rejected before any signal.
        let fresh: Bool = tokenQueue.sync {
            if spentIntentTokens.contains(intentToken) { return false }
            spentIntentTokens.insert(intentToken)
            return true
        }
        guard fresh, UUID(uuidString: intentToken) != nil else {
            reply(false, "Invalid or replayed intent token.")
            return
        }
        guard pid > 1 else {
            reply(false, "Refusing to signal pid \(pid).")
            return
        }
        // Even root-owned: SIGTERM only. Force-kill of system
        // processes from a helper is a footgun Pulse will not ship.
        if kill(pid, SIGTERM) == 0 {
            reply(true, nil)
        } else {
            reply(false, "kill(2) failed with errno \(errno).")
        }
    }
}

// MARK: - Listener

final class HelperListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let validator = ClientValidator()
    private let service = PulseHelperService()

    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard validator.isValid(connection: connection) else { return false }
        connection.exportedInterface = NSXPCInterface(with: PulseHelperProtocol.self)
        connection.exportedObject = service
        connection.resume()
        return true
    }
}

// MARK: - Entry point (daemon main; unused while disabled in v1)

@main
enum PulseHelperMain {
    static func main() {
        // Registration note: in the enabled packaging, the app calls
        //   try SMAppService.daemon(plistName: "com.metaphasicgroup.pulseai.helper.plist").register()
        // and this process is launched by launchd as a LaunchDaemon.
        // There is no self-install path here on purpose.
        let delegate = HelperListenerDelegate()
        let listener = NSXPCListener(machServiceName: pulseHelperMachServiceName)
        listener.delegate = delegate
        listener.resume()
        RunLoop.main.run()
    }
}
