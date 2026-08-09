import Foundation
import Security

/// Stores TDLib's local database-encryption key in the macOS Keychain,
/// generating a random one on first use. Windows-parity note from the plan
/// ("сесія в Keychain замість DPAPI"): TDLib already encrypts its own
/// on-disk session database at `databaseDirectory` — the piece that
/// actually needs OS-level protection is the *key* to that database, not
/// the database file itself, so that key (not any session data) is what
/// lives in the Keychain here.
enum TelegramKeychain {
    private static let service = "com.replixer.ReplixerMac.telegram"
    private static let account = "database-encryption-key"

    /// Returns the existing key, or generates and stores a new random
    /// 256-bit one on first call. A missing/unreadable Keychain item is
    /// treated the same as "first run" rather than a hard error — if this
    /// ever has to regenerate after a database already exists on disk,
    /// TDLib reports it as an invalid-key error (401) rather than silently
    /// corrupting anything, so the failure mode stays visible instead of
    /// being swallowed.
    static func databaseEncryptionKey() -> Data {
        if let existing = read() {
            return existing
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed: \(status)")
        let key = Data(bytes)
        save(key)
        return key
    }

    private static func read() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return data
    }

    private static func save(_ data: Data) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        // Clear any stale/partial item first so add() below can't fail
        // with errSecDuplicateItem on a retry after a previous partial
        // failure.
        SecItemDelete(query as CFDictionary)

        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status != errSecSuccess {
            print("[TelegramKeychain] ⚠️ не вдалося зберегти ключ шифрування у Keychain, OSStatus=\(status)")
        }
    }
}
