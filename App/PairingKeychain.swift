// Device-only storage and migration for PC pairing tokens.
import Foundation
import Security

enum PairingKeychain {
    private static let service = "dk.fadedai.pairing"
    private static let legacyService = "AI Sweat-Caster pairing v1"
    private static let lock = NSLock()

    static func load(_ address: String) throws -> String {
        try lock.withLock {
            if let token = try read(service, address: address) { return token }
            guard let token = try read(legacyService, address: address) else { throw APIError.token }
            try write(token, address: address)
            removeLegacy(address: address)
            return token
        }
    }

    static func save(_ token: String, for address: String) throws {
        try lock.withLock {
            try write(token, address: address)
            removeLegacy(address: address)
        }
    }

    static func removeAll() throws {
        try lock.withLock {
            // Remove the legacy copy first so it cannot restore a removed current token.
            guard delete(legacyService), delete(service) else { throw APIError.storage }
        }
    }

    private static func query(_ service: String, address: String?) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        if let address { query[kSecAttrAccount as String] = address }
        return query
    }

    private static func read(_ service: String, address: String) throws -> String? {
        var filter = query(service, address: address)
        filter[kSecReturnData as String] = true
        var item: CFTypeRef?
        let status = SecItemCopyMatching(filter as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data,
              let token = String(data: data, encoding: .utf8) else { throw APIError.storage }
        return token
    }

    private static func write(_ token: String, address: String) throws {
        let filter = query(service, address: address)
        let values: [String: Any] = [
            kSecValueData as String: Data(token.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let status = SecItemUpdate(filter as CFDictionary, values as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw APIError.storage }
        let item = filter.merging(values) { _, updated in updated }
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw APIError.storage }
    }

    private static func removeLegacy(address: String) {
        // A successful replacement remains usable if the Keychain refuses the cleanup.
        if !delete(legacyService, address: address) { AppDiagnostics.record(APIError.storage) }
    }

    private static func delete(_ service: String, address: String? = nil) -> Bool {
        let status = SecItemDelete(query(service, address: address) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
