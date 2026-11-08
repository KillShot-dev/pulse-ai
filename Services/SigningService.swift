import Foundation
import Security

/// Code-signing truth for a process or binary, in plain English.
///
/// Sources: SecCodeCopyGuestWithAttributes (pid → SecCode),
/// SecCodeCopyStaticCode, SecCodeCopySigningInformation (identifier,
/// Team ID, certificates, designated requirement), and
/// SecCodeCheckValidityWithErrors.
///
/// Notarization is reported as an enum with an explicit `.unknown`:
/// there is no single public "is notarized" API. Pulse's heuristic —
/// Developer-ID signed AND the designated requirement contains the
/// Apple notarization OID (1.2.840.113635.100.6.2.6) AND Gatekeeper
/// architecture validation passes — is labelled a heuristic in the UI
/// copy it feeds. No fake certainty.
enum NotarizationStatus: String {
    case notarized = "Notarized (heuristic)"
    case notNotarized = "Not notarized"
    case adHocOrUnsigned = "Ad hoc / unsigned"
    case appleSystem = "Apple system code"
    case unknown = "Unknown"
}

struct Verdict {
    var isSigned: Bool = false
    var identifier: String?
    var teamID: String?
    /// Leaf → root subject summaries of the signing certificate chain.
    var authorityChain: [String] = []
    var designatedRequirement: String?
    var isAppleSystem: Bool = false
    var isHardenedRuntime: Bool = false
    var notarization: NotarizationStatus = .unknown
    /// Inputs the safe-to-quit heuristic actually used — shown in the UI
    /// so the judgment is auditable, not oracular.
    var safeToQuit: Bool?
    var safeToQuitReasons: [String] = []
    var summary: String = "No signing information available."
}

enum SigningService {

    /// Verdict for a running process.
    static func verdict(forPID pid: pid_t) -> Verdict {
        let attrs = [kSecGuestAttributePid: NSNumber(value: pid)] as CFDictionary
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attrs, [], &code) == errSecSuccess,
              let code else {
            return Verdict(summary: "Could not obtain a code object for pid \(pid).")
        }
        return verdict(forCode: code)
    }

    /// Verdict for a binary/app on disk.
    static func verdict(forURL url: URL) -> Verdict {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode else {
            return Verdict(summary: "Could not read code signing for \(url.lastPathComponent).")
        }
        return verdict(forStaticCode: staticCode)
    }

    // MARK: - Core

    private static func verdict(forCode code: SecCode) -> Verdict {
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode else {
            return Verdict(summary: "Process has no static code object (likely unsigned).")
        }
        return verdict(forStaticCode: staticCode)
    }

    private static func verdict(forStaticCode staticCode: SecStaticCode) -> Verdict {
        var verdict = Verdict()

        var infoRef: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &infoRef) == errSecSuccess,
              let info = infoRef as? [String: Any] else {
            verdict.summary = "Unsigned or unreadable signature."
            verdict.notarization = .adHocOrUnsigned
            verdict.safeToQuit = nil
            verdict.safeToQuitReasons = ["No signature to evaluate."]
            return verdict
        }

        verdict.isSigned = true
        verdict.identifier = info[kSecCodeInfoIdentifier as String] as? String
        verdict.teamID = info[kSecCodeInfoTeamIdentifier as String] as? String

        if let certs = info[kSecCodeInfoCertificates as String] as? [SecCertificate] {
            verdict.authorityChain = certs.compactMap {
                SecCertificateCopySubjectSummary($0) as String?
            }
        }

        if let requirement = info[kSecCodeInfoDesignatedRequirement as String] as? SecRequirement {
            var text: CFString?
            if SecRequirementCopyString(requirement, [], &text) == errSecSuccess {
                verdict.designatedRequirement = text as String?
            }
        }

        // Code signing flags: hardened runtime + Apple anchor checks.
        if let csFlags = (info[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value {
            // kSecCodeExecSegmentMainExec / runtime flag bit (cs_runtime = 0x10000 in cs_blobs).
            verdict.isHardenedRuntime = (csFlags & 0x10000) != 0
        }

        verdict.isAppleSystem = verdict.teamID == nil
            && (verdict.authorityChain.last?.contains("Apple Root CA") ?? false)
            && (verdict.designatedRequirement?.contains("anchor apple") ?? false)

        // Gatekeeper architecture validity (public, user-space).
        var error: Unmanaged<CFError>?
        let checkFlags = SecCSFlags(rawValue: kSecCSCheckGatekeeperArchitectures | kSecCSCheckNestedCode)
        let gatekeeperOK = SecCodeCheckValidityWithErrors(staticCode, checkFlags, nil, &error)
            == errSecSuccess

        verdict.notarization = notarizationStatus(for: verdict, gatekeeperOK: gatekeeperOK)
        applySafeToQuitHeuristic(to: &verdict)
        verdict.summary = plainEnglishSummary(for: verdict)
        return verdict
    }

    private static func notarizationStatus(for verdict: Verdict,
                                           gatekeeperOK: Bool) -> NotarizationStatus {
        if verdict.isAppleSystem { return .appleSystem }
        guard let dr = verdict.designatedRequirement else { return .unknown }
        // Notarized Developer ID code carries the notarization ticket OID
        // requirement in its designated requirement.
        let hasNotarizationOID = dr.contains("1.2.840.113635.100.6.2.6")
        let developerID = dr.contains("anchor apple generic")
        if developerID && hasNotarizationOID && gatekeeperOK { return .notarized }
        if developerID { return .notNotarized }
        if dr.contains("adhoc") { return .adHocOrUnsigned }
        return .unknown
    }

    // MARK: - Safe-to-quit heuristic (inputs stated, per spec)

    private static func applySafeToQuitHeuristic(to verdict: inout Verdict) {
        var reasons: [String] = []
        var score = 0

        if verdict.isAppleSystem {
            reasons.append("Signed by Apple as system code — quitting may destabilise macOS.")
            score -= 3
        }
        if verdict.teamID == nil && !verdict.isAppleSystem {
            reasons.append("No Team ID — not distributed through a registered developer account.")
            score -= 1
        }
        if verdict.notarization == .notarized {
            reasons.append("Developer ID signed and notarized — a known, accountable publisher.")
            score += 1
        }
        if verdict.notarization == .adHocOrUnsigned {
            reasons.append("Ad hoc or unsigned — no publisher identity to vouch for it.")
            score -= 1
        }
        if let id = verdict.identifier, id.hasPrefix("com.apple.") {
            reasons.append("Apple bundle identifier (\(id)).")
            score -= 2
        }

        verdict.safeToQuitReasons = reasons
        // Conservative: only a positive score says "likely safe", only a
        // strongly negative one says "don't". Anything in between is
        // honestly nil — the UI shows "No clear signal".
        if score >= 1 { verdict.safeToQuit = true }
        else if score <= -2 { verdict.safeToQuit = false }
        else { verdict.safeToQuit = nil }
    }

    private static func plainEnglishSummary(for verdict: Verdict) -> String {
        if verdict.isAppleSystem {
            return "Part of macOS itself, signed by Apple."
        }
        if let team = verdict.teamID {
            let leaf = verdict.authorityChain.first ?? "an identified developer"
            return "Signed by \(leaf) (Team ID \(team)). \(verdict.notarization.rawValue)."
        }
        return "No registered developer identity. \(verdict.notarization.rawValue)."
    }
}
