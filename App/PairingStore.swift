// PC pairing, QR selection and Keychain storage.
import Foundation
import Security

struct PairingQRCode: Decodable {
    let version: Int
    let address: String
    let token: String
    let expiresAt: Date?
    let nonce: String?

    // Parsing validates the wire format. Scans must also pass PairingQRSession.accept.
    static func parse(_ text: String) throws -> Self {
        guard text.utf8.count <= 2_048,
              let payload = try? contractDecoder().decode(Self.self, from: Data(text.utf8)),
              payload.version == 1,
              !payload.token.isEmpty, payload.token.utf8.count <= 512,
              payload.nonce?.isEmpty != true,
              payload.token.utf8.allSatisfy({ (33...126).contains($0) }) else { throw APIError.input }
        let server = try Server(payload.address)
        return Self(version: 1, address: server.address, token: payload.token,
                    expiresAt: payload.expiresAt, nonce: payload.nonce)
    }
}

@MainActor enum PairingQRSession {
    enum Failure: Error { case replay }

    private static var scannedNonces: Set<String> = []

    static func accept(_ text: String, now: Date = .now) throws -> PairingQRCode {
        let payload = try PairingQRCode.parse(text)
        guard let expiresAt = payload.expiresAt, expiresAt > now else { throw APIError.pairingExpired }
        if let nonce = payload.nonce, !scannedNonces.insert(nonce).inserted {
            throw Failure.replay
        }
        return payload
    }
}

enum PairingQRTarget {
    enum Selection: Equatable {
        case searching, unrelated, ambiguous, match(String)

        var hint: String {
            switch self {
            case .unrelated: "Brug forbindelseskoden fra FadedAI på din PC."
            case .ambiguous: "Placér én forbindelseskode midt i rammen."
            default: "Hold hele PC’ens QR-kode i rammen."
            }
        }
    }

    static func frame(in bounds: CGRect) -> CGRect {
        let side = min(224, max(0, min(bounds.width, bounds.height) - 32))
        return CGRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
    }

    static func select(in target: CGRect, from codes: [(value: String, bounds: CGRect)]) -> Selection {
        guard !target.isEmpty else { return .searching }
        let visible = codes.filter { !$0.bounds.isEmpty && target.contains($0.bounds) }
        let matches = visible.filter { (try? PairingQRCode.parse($0.value)) != nil }
        guard let first = matches.first else { return visible.isEmpty ? .searching : .unrelated }
        if matches.count == 1 { return .match(first.value) }
        let center = CGPoint(x: target.midX, y: target.midY)
        let aimed = matches.filter { $0.bounds.contains(center) }
        if aimed.count == 1, let selected = aimed.first { return .match(selected.value) }
        return .ambiguous
    }
}

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
