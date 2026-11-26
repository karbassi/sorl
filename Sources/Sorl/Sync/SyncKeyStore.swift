import CryptoKit
import Foundation
import OSLog
import Security

/// The per-account sync key, cached in the login Keychain as a generic password: service
/// `com.karbassi.sorl.sync-key`, account = the iCloud user record name, never synchronizable. The bytes are never
/// logged; failures log only the `OSStatus`.
enum SyncKeyStore {
    private static let service = "com.karbassi.sorl.sync-key"
    private static let log = Logger(subsystem: "com.karbassi.sorl", category: "sync")

    static func read(user: String) -> SymmetricKey? {
        var query = baseQuery(user: user)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else {
            if status != errSecItemNotFound { log.error("reading sync key failed: \(status, privacy: .public)") }
            return nil
        }
        guard let data = result as? Data, data.count == 32 else {
            log.error("stored sync key is malformed")
            return nil
        }
        return SymmetricKey(data: data)
    }

    @discardableResult
    static func write(_ key: SymmetricKey, user: String) -> Bool {
        let attributes: [String: Any] = [
            kSecValueData as String: key.withUnsafeBytes { Data($0) },
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let query = baseQuery(user: user)
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            log.error("storing sync key failed: \(status, privacy: .public)")
            return false
        }
        return true
    }

    static func delete(user: String) {
        let status = SecItemDelete(baseQuery(user: user) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            log.error("deleting sync key failed: \(status, privacy: .public)")
            return
        }
    }

    private static func baseQuery(user: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: user,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
    }
}
