import Foundation

struct PhoneBroadcastConfiguration: Codable {
    static let group = "group.dk.sweatcaster.ios.share"
    let id: String
    let endpoint: URL
    let token: String
    let expires: Double
    var paused = true

    private static var file: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?
            .appending(path: "phone-screen-session.json")
    }

    func save() throws {
        guard let file = Self.file, endpoint.scheme == "http", endpoint.port == 8765,
              expires > Date().timeIntervalSince1970 else { throw CocoaError(.fileWriteUnknown) }
        try JSONEncoder().encode(self).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    static func read() -> Self? {
        guard let file, let data = try? Data(contentsOf: file),
              let value = try? JSONDecoder().decode(Self.self, from: data),
              value.expires > Date().timeIntervalSince1970 else { return nil }
        return value
    }

    static func clear() {
        if let file { try? FileManager.default.removeItem(at: file) }
    }
}
