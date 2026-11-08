import Foundation
import Security

/// Licensing for Pulse AI — the FileRadar design, adapted (PU- prefix).
/// Read LicenseManager.swift in the FileRadar tree for the fleet's
/// rationale; the decisions carried over deliberately:
///
/// Serial format: PU-XXXX-XXXX-XXXX-XXXX (16 chars in 4 groups of 4;
/// prefix not part of the checksum).
/// Alphabet excludes easily confused characters (no 0/O, 1/I/L):
///   "ABCDEFGHJKMNPQRSTUVWXYZ23456789"  (31 symbols)
/// Checksum (identical algorithm to FileRadar's backend):
///   1. The first 15 characters are the payload.
///   2. checksum_index = sum((i + 1) * alphabetIndex(payload[i])) mod 31
///   3. The 16th character must equal alphabet[checksum_index].
/// Local validation is a typo check, NOT proof of purchase; the
/// licensing server's check is authoritative when it is configured.
///
/// Storage: macOS Keychain, generic-password item,
/// kSecAttrAccessibleWhenUnlockedThisDeviceOnly — never synced, never
/// in UserDefaults, never in a plaintext file. Keychain failures never
/// crash and never surface the serial.
///
/// Trial: full features from first launch with a gentle reminder after
/// the grace window; v1 never hard-locks (LicenseState.locked exists so
/// the UI can describe the policy honestly if it ever changes).
///
/// Network: NONE by default. Validation is local-first; the optional
/// server check lives behind SerialValidationService and the bundled
/// implementation is a local-only stub. The production endpoint
/// constant is defined here for the deployment step (a user step, per
/// spec) — nothing in v1 calls it.

// MARK: - Server validation (protocol seam)

protocol SerialValidationService {
    func validateRemotely(serial: String) async -> Bool?
    func deactivateRemotely(serial: String) async -> Bool
}

/// v1 implementation: no network. Returning nil means "no opinion",
/// and local checksum validation decides.
struct LocalOnlyValidationService: SerialValidationService {
    func validateRemotely(serial: String) async -> Bool? { nil }
    func deactivateRemotely(serial: String) async -> Bool { true }
}

enum LicensingAPI {
    /// Production licensing endpoint base. Defined, not called in v1.
    static let baseURLString = "https://api.metaphasic.net"
}

// MARK: - Keychain store

private enum KeychainSerialStore {
    private static let service = "com.metaphasicgroup.pulseai.license"
    private static let account = "activation-serial"

    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func read() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let serial = String(data: data, encoding: .utf8),
              !serial.isEmpty else { return nil }
        return serial
    }

    static func write(_ serial: String) -> Bool {
        guard let data = serial.data(using: .utf8) else { return false }
        var attributes = baseQuery
        attributes[kSecValueData as String] = data
        // ThisDeviceOnly: the serial unlocks THIS Mac and must not ride
        // iCloud Keychain to another one.
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        if addStatus == errSecSuccess { return true }
        guard addStatus == errSecDuplicateItem else { return false }
        return SecItemUpdate(baseQuery as CFDictionary,
                             [kSecValueData as String: data] as CFDictionary) == errSecSuccess
    }

    static func delete() {
        _ = SecItemDelete(baseQuery as CFDictionary)
    }
}

// MARK: - License service

@MainActor
final class LicenseService: ObservableObject {
    @Published private(set) var state: LicenseState = .trial(daysSinceFirstLaunch: 0)
    @Published private(set) var serial: String?

    static let alphabet = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"
    /// Days of full-featured trial before the gentle reminder appears.
    static let trialGraceDays = 14

    private let firstLaunchKey = "com.metaphasicgroup.pulseai.firstLaunchDate"
    private let validator: SerialValidationService

    init(validator: SerialValidationService = LocalOnlyValidationService()) {
        self.validator = validator
        restore()
    }

    var isFull: Bool { state.isFull }

    /// The gentle reminder is a state the UI may show — never a gate.
    var shouldShowTrialReminder: Bool {
        if case .trial(let days) = state { return days >= Self.trialGraceDays }
        return false
    }

    // MARK: Validation (pure, testable)

    static func validate(_ raw: String) -> Bool {
        let cleaned = normalize(raw)
        let parts = cleaned.split(separator: "-").map(String.init)
        guard parts.count == 5, parts[0] == "PU" else { return false }
        let groups = Array(parts.dropFirst())
        guard groups.count == 4, groups.allSatisfy({ $0.count == 4 }) else { return false }
        let body = groups.joined()
        guard body.allSatisfy({ alphabet.contains($0) }) else { return false }
        guard let check = checksumChar(for: String(body.prefix(15))) else { return false }
        return check == body.last!
    }

    static func checksumChar(for payload: String) -> Character? {
        let chars = Array(alphabet)
        guard payload.count == 15, payload.allSatisfy({ alphabet.contains($0) }) else { return nil }
        var total = 0
        for (i, ch) in payload.enumerated() {
            guard let idx = chars.firstIndex(of: ch) else { return nil }
            total += (i + 1) * idx
        }
        return chars[total % 31]
    }

    static func makeSerial(payload: String) -> String? {
        guard let check = checksumChar(for: payload) else { return nil }
        let full = payload + String(check)
        let groups = stride(from: 0, to: 16, by: 4).map {
            String(full[full.index(full.startIndex, offsetBy: $0)..<full.index(full.startIndex, offsetBy: $0 + 4)])
        }
        return "PU-" + groups.joined(separator: "-")
    }

    static func normalize(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    // MARK: Activation / deactivation

    @discardableResult
    func activate(_ raw: String) async -> Bool {
        let cleaned = Self.normalize(raw)
        guard Self.validate(cleaned) else { return false }
        // Optional remote check: only a definitive "no" blocks; nil
        // (no server configured / unreachable) defers to local checks.
        if let remote = await validator.validateRemotely(serial: cleaned), remote == false {
            return false
        }
        guard KeychainSerialStore.write(cleaned) else { return false }
        serial = cleaned
        state = .full
        return true
    }

    /// Local deactivation requires presenting the serial itself — the
    /// serial IS the credential (the fleet's deliberate design, mirrored
    /// server-side in server/licensing-server.mjs). No separate password
    /// exists to phish, and holding the serial already confers full use.
    @discardableResult
    func deactivate(presenting raw: String) async -> Bool {
        let cleaned = Self.normalize(raw)
        guard let current = serial, cleaned == current else { return false }
        _ = await validator.deactivateRemotely(serial: cleaned)
        KeychainSerialStore.delete()
        serial = nil
        state = .trial(daysSinceFirstLaunch: daysSinceFirstLaunch())
        return true
    }

    // MARK: State restore

    private func restore() {
        if let saved = KeychainSerialStore.read(), Self.validate(saved) {
            serial = saved
            state = .full
            return
        }
        state = .trial(daysSinceFirstLaunch: daysSinceFirstLaunch())
    }

    private func daysSinceFirstLaunch() -> Int {
        let defaults = UserDefaults.standard
        if let first = defaults.object(forKey: firstLaunchKey) as? Date {
            return max(0, Calendar.current.dateComponents([.day], from: first, to: Date()).day ?? 0)
        }
        defaults.set(Date(), forKey: firstLaunchKey)
        return 0
    }
}
