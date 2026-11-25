import Foundation

enum ScanDocument {
    struct Amount: Codable, Equatable, Sendable { let value: String; let quote: String }
    struct Record: Codable, Identifiable, Sendable {
        var id = UUID()
        var title: String
        var created = Date()
        var text: String
        var pages: Int
        var totals: [Amount]
    }
    enum Failure: LocalizedError {
        case format, full
        var errorDescription: String? { self == .full ? "Gem højst 80 scanninger med op til 10 sider hver. Fjern en gammel kopi eller del dokumentet op." : "Scanningen kunne ikke læses. Prøv en tydeligere kopi." }
    }
    static func command(_ text: String) -> Bool { ["scan et dokument", "scan en kvittering", "åbn mine scanninger", "læs en qr kode"].contains(text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)) }
    static func amounts(in text: String) -> [Amount] {
        let pattern = #"(?im)\b(?:i\s+alt|total|at\s+betale|beløb)\b[ \t:]*((?:DKK|kr\.?|EUR|€)?[ \t]*[0-9](?:[0-9., ]{0,18}[0-9])?(?:[ \t]*(?:DKK|kr\.?|EUR|€))?)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let source = String(text.prefix(24_000))
        return regex.matches(in: source, range: NSRange(source.startIndex..., in: source)).prefix(6).compactMap { match in
            guard let whole = Range(match.range, in: source), let number = Range(match.range(at: 1), in: source) else { return nil }
            return .init(value: source[number].trimmingCharacters(in: .whitespaces), quote: String(source[whole]))
        }
    }
    static func qrURL(_ text: String) -> URL? {
        guard text.utf8.count <= 4_096, !text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              let parts = URLComponents(string: text), ["https", "http"].contains(parts.scheme?.lowercased() ?? ""),
              parts.user == nil, parts.password == nil, let host = parts.host, !host.isEmpty else { return nil }; return parts.url
    }
    struct Store {
        let botID: UUID
        var base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("FadedAI/Scans", isDirectory: true)
        var folder: URL { base.appendingPathComponent(botID.uuidString.lowercased(), isDirectory: true) }
        private var index: URL { folder.appendingPathComponent("index.json") }
        func file(_ id: UUID) -> URL { folder.appendingPathComponent(id.uuidString.lowercased() + ".pdf") }
        func load() throws -> [Record] {
            guard FileManager.default.fileExists(atPath: index.path) else { return [] }
            guard (try index.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 8_000_000 else { throw Failure.full }
            let values = try JSONDecoder().decode([Record].self, from: Data(contentsOf: index))
            guard values.count <= 80 else { throw Failure.full }; return values
        }
        func save(_ record: Record, pdf: Data) throws {
            guard (1...10).contains(record.pages), (1...160).contains(record.title.count), record.text.unicodeScalars.count <= 24_000,
                  pdf.count <= 24_000_000, pdf.starts(with: Data("%PDF-".utf8)) else { throw Failure.format }
            var current = try load(); current.removeAll { $0.id == record.id }; guard current.count < 80 else { throw Failure.full }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            // A fresh UUID is used for each export; an existing export is never silently overwritten.
            guard !FileManager.default.fileExists(atPath: file(record.id).path) else { throw Failure.format }
            try pdf.write(to: file(record.id), options: [.atomic, .completeFileProtection])
            do { current.insert(record, at: 0); try write(current) } catch { try? FileManager.default.removeItem(at: file(record.id)); throw error }
        }
        func remove(_ id: UUID) throws {
            var values = try load(); values.removeAll { $0.id == id }
            if FileManager.default.fileExists(atPath: file(id).path) { try FileManager.default.removeItem(at: file(id)) }; try write(values)
        }
        private func write(_ values: [Record]) throws {
            let bytes = try JSONEncoder().encode(values); guard bytes.count <= 8_000_000 else { throw Failure.full }
            try bytes.write(to: index, options: [.atomic, .completeFileProtection])
        }
    }
}
