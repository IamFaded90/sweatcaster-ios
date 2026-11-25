import Foundation

struct ProductHunt: Codable, Equatable {
    struct Price: Codable, Equatable {
        let amount: Decimal
        let currency: String
        let checked: Date
        var formatted: String {
            let format = NumberFormatter(); format.numberStyle = .currency
            format.locale = Locale(identifier: "da_DK"); format.currencyCode = currency
            return format.string(from: NSDecimalNumber(decimal: amount)) ?? "\(amount) \(currency)"
        }
    }
    struct Match: Codable, Equatable, Identifiable {
        var id: String { url.absoluteString }
        var title: String
        let url: URL
        var evidence = ""
        var price: Price?
        var identityConfirmed = false
        var checked: Date?
    }
    let botID: UUID
    var query = ""
    var observations = ""
    var matches: [Match] = []
    var favorites: [Match] = []
    var updated = Date.now

    mutating func favorite(_ match: Match) {
        if let index = favorites.firstIndex(where: { $0.id == match.id }) { favorites.remove(at: index) }
        else { favorites.insert(match, at: 0); favorites = Array(favorites.prefix(40)) }
        updated = .now
    }
    mutating func confirm(_ id: String) {
        if let index = matches.firstIndex(where: { $0.id == id }) { matches[index].identityConfirmed.toggle() }
        if let index = favorites.firstIndex(where: { $0.id == id }), let match = matches.first(where: { $0.id == id }) {
            favorites[index] = match
        }
        updated = .now
    }
    static func command(_ text: String, withPhoto: Bool = false) -> Bool {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !withPhoto {
            return clean.range(of: #"^(?:hvor kan jeg købe|find ting fra (?:et )?billede|vis mine produktfund|find noget der ligner)\b"#,
                options: [.regularExpression, .caseInsensitive]) != nil
        }
        return clean.range(of:
            #"^(?:(?:kan|vil) du (?:lige )?)?(?:find (?:den her|denne|den|det her|dette|det|tingen|produktet|noget der ligner)|hvor kan jeg købe|find ting fra (?:et )?billede|vis mine produktfund)\b"#,
            options: [.regularExpression, .caseInsensitive]) != nil
    }
    static func publicURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased(), host.contains("."),
              url.user == nil, url.password == nil, url.port == nil || url.port == 443,
              !host.contains(":"), host.contains(where: \.isLetter),
              ![".local", ".localhost", ".internal", ".test", ".invalid"].contains(where: host.hasSuffix),
              host != "localhost", url.absoluteString.count <= 2_000 else { return false }
        return true
    }
    struct Crop: Equatable {
        let x, y, width, height: Double
        static func selection(from a: CGPoint, to b: CGPoint, size: CGSize) -> Self? {
            guard size.width > 0, size.height > 0 else { return nil }
            let left = max(0, min(1, min(a.x, b.x) / size.width))
            let top = max(0, min(1, min(a.y, b.y) / size.height))
            let right = max(0, min(1, max(a.x, b.x) / size.width))
            let bottom = max(0, min(1, max(a.y, b.y) / size.height))
            guard right - left >= 0.04, bottom - top >= 0.04 else { return nil }
            return Self(x: left, y: top, width: right - left, height: bottom - top)
        }
    }
    struct Store {
        let botID: UUID
        var root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FadedAI/ProductHunts", isDirectory: true)
        var directory: URL { root.appendingPathComponent(botID.uuidString.lowercased(), isDirectory: true) }
        func load() throws -> ProductHunt {
            let file = directory.appendingPathComponent("hunt.json")
            guard FileManager.default.fileExists(atPath: file.path) else { return .init(botID: botID) }
            let data = try Data(contentsOf: file)
            guard data.count <= 250_000 else { throw CocoaError(.fileReadCorruptFile) }
            let value = try JSONDecoder().decode(ProductHunt.self, from: data)
            guard value.botID == botID, value.matches.count <= 10, value.favorites.count <= 40,
                  (value.matches + value.favorites).allSatisfy({ ProductHunt.publicURL($0.url) }) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return value
        }
        func save(_ value: ProductHunt) throws {
            guard value.botID == botID, value.query.count <= 500, value.observations.count <= 4_000,
                  value.matches.count <= 10, value.favorites.count <= 40,
                  (value.matches + value.favorites).allSatisfy({ ProductHunt.publicURL($0.url) && $0.title.count <= 350 && $0.evidence.count <= 1_500 }) else {
                throw CocoaError(.fileWriteInvalidFileName)
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(value).write(to: directory.appendingPathComponent("hunt.json"), options: [.atomic, .completeFileProtection])
        }
        func photo() throws -> Data? {
            let file = directory.appendingPathComponent("photo.jpg")
            guard FileManager.default.fileExists(atPath: file.path) else { return nil }
            guard (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? .max) <= 3_300_000 else { throw CocoaError(.fileReadCorruptFile) }
            return try Data(contentsOf: file)
        }
        func savePhoto(_ data: Data?) throws {
            let file = directory.appendingPathComponent("photo.jpg")
            guard let data else { if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }; return }
            guard data.count <= 3_300_000 else { throw CocoaError(.fileWriteOutOfSpace) }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: file, options: [.atomic, .completeFileProtection])
        }
        func remove() throws {
            if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
        }
    }
}

/// Reads an unambiguous Product/Offer pair. Prices in navigation, reviews or AI text are not offers.
enum ProductOffer {
    struct Offer: Equatable { let title: String; let amount: Decimal; let currency: String }
    static func read(html: String) -> Offer? {
        guard html.utf8.count <= 600_000, let regex = try? NSRegularExpression(
            pattern: #"<script\b[^>]*type\s*=\s*["']application/ld\+json["'][^>]*>(.*?)</script\s*>"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return nil }
        var products: [[String: Any]] = []
        func visit(_ value: Any, depth: Int) {
            guard depth < 8, products.count < 20 else { return }
            if let array = value as? [Any] { for item in array.prefix(100) { visit(item, depth: depth + 1) } }
            if let node = value as? [String: Any] {
                let types = (node["@type"] as? [String]) ?? [node["@type"] as? String ?? ""]
                if types.contains(where: { $0 == "Product" || $0.hasSuffix("/Product") }) { products.append(node) }
                if let graph = node["@graph"] { visit(graph, depth: depth + 1) }
                if let page = node["mainEntity"] { visit(page, depth: depth + 1) }
            }
        }
        for match in regex.matches(in: html, range: NSRange(html.startIndex..., in: html)).prefix(12) {
            guard let range = Range(match.range(at: 1), in: html), let data = String(html[range]).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) else { continue }
            visit(object, depth: 0)
        }
        guard products.count == 1, let product = products.first, let name = product["name"] as? String,
              !name.isEmpty, name.count <= 350 else { return nil }
        let raw = product["offers"]
        let offers = (raw as? [[String: Any]]) ?? (raw as? [String: Any]).map { [$0] } ?? []
        guard offers.count == 1, let offer = offers.first,
              let type = offer["@type"] as? String, type == "Offer" || type.hasSuffix("/Offer"),
              let currency = offer["priceCurrency"] as? String,
              ["DKK", "EUR", "USD", "GBP", "SEK", "NOK", "CHF", "CAD", "AUD", "JPY"].contains(currency) else { return nil }
        let rawPrice = (offer["price"] as? String) ?? (offer["price"] as? NSNumber)?.stringValue ?? ""
        guard rawPrice.range(of: #"^\d{1,9}(?:\.\d{1,4})?$"#, options: .regularExpression) != nil,
              let amount = Decimal(string: rawPrice, locale: Locale(identifier: "en_US_POSIX")), amount > 0 else { return nil }
        return Offer(title: name, amount: amount, currency: currency)
    }
}
