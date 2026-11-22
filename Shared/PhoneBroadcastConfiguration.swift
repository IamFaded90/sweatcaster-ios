import Foundation

enum FadedSharedContainer {
    static let identifier = "group.dk.sweatcaster.ios.share"

    // A re-signed host and its extensions must resolve the same group.
    static func candidates(hostID: String?, declaredGroups: [String]) -> [String] {
        let prefix = identifier + "."
        func teamSuffix(_ value: String) -> Bool {
            value.range(of: #"^[A-Z0-9]{10}$"#, options: .regularExpression) != nil
        }
        var result = [identifier]
        for value in declaredGroups where value.hasPrefix(prefix) {
            if teamSuffix(String(value.dropFirst(prefix.count))), !result.contains(value) { result.append(value) }
        }
        let hostPrefix = "dk.sweatcaster.ios."
        if let hostID, hostID.hasPrefix(hostPrefix) {
            let suffix = String(hostID.dropFirst(hostPrefix.count))
            if teamSuffix(suffix), !result.contains(prefix + suffix) { result.append(prefix + suffix) }
        }
        return result
    }

    static var url: URL? {
        let bundle = Bundle.main
        let hostURL = bundle.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
        let host = bundle.bundleURL.pathExtension == "appex" ? Bundle(url: hostURL) ?? bundle : bundle
        let groups = host.object(forInfoDictionaryKey: "ALTAppGroups") as? [String] ?? []
        for id in candidates(hostID: host.bundleIdentifier, declaredGroups: groups) {
            if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id) { return url }
        }
        return nil
    }
}

struct PhoneBroadcastConfiguration: Codable {
    static let group = FadedSharedContainer.identifier
    enum SetupError: LocalizedError {
        case sharedContainerUnavailable, invalidSession, writeFailed

        var errorDescription: String? {
            switch self {
            case .sharedContainerUnavailable:
                "Denne installation af FadedAI mangler adgang til den mappe, som iPhone-skærmdelingen bruger. Appen og skærmudvidelsen skal installeres med samme App Group. Du kan stadig sende et skærmbillede i chatten."
            case .invalidSession:
                "PC’en gav appen en ugyldig eller udløbet skærmdeling. Prøv at starte igen."
            case .writeFailed:
                "iPhonen kunne ikke gemme skærmdelingen. Prøv igen, mens telefonen er låst op."
            }
        }
    }
    let id: String
    let endpoint: URL
    let token: String
    let expires: Double
    var paused = true

    private static var file: URL? {
        FadedSharedContainer.url?.appending(path: "phone-screen-session.json")
    }

    static var hasSharedContainer: Bool { file != nil }

    func save() throws {
        guard let file = Self.file else { throw SetupError.sharedContainerUnavailable }
        guard endpoint.scheme == "http", endpoint.port == 8765,
              expires > Date().timeIntervalSince1970 else { throw SetupError.invalidSession }
        do {
            try JSONEncoder().encode(self).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            throw SetupError.writeFailed
        }
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
