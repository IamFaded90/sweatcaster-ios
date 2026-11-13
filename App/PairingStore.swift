// Keychain storage for PC pairing and cloud credentials.
import Foundation
import Security

enum Pairing {
    static let addressKey = AppStorageKeys.serverAddress
    static func load(_ address: String) throws -> String { try PairingKeychain.load(address) }
    static func save(_ token: String, for address: String) throws {
        try PairingKeychain.save(token, for: address)
    }

    static func removeAll() throws { try PairingKeychain.removeAll() }
}

enum CloudModelKey {
    static let didChange = Notification.Name("FadedAI.cloudModelKeyDidChange")

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "FadedAI optional cloud models",
         kSecAttrAccount as String: "xai"]
    }

    static func exists() -> Bool {
        SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    static func save(_ value: String) throws {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValid(key) else { throw APIError.input }
        let data = Data(key.utf8)
        let updated = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updated != errSecSuccess {
            guard updated == errSecItemNotFound else { throw APIError.storage }
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw APIError.storage }
        }
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    static func load() throws -> String {
        var item: CFTypeRef?
        var filter = query
        filter[kSecReturnData as String] = true
        guard SecItemCopyMatching(filter as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let key = String(data: data, encoding: .utf8), isValid(key) else {
            throw GrokFailure.missingKey
        }
        return key
    }

    static func remove() {
        SecItemDelete(query as CFDictionary)
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    static func isValid(_ key: String) -> Bool {
        (1...512).contains(key.utf8.count) && key.utf8.allSatisfy { (33...126).contains($0) }
    }
}
