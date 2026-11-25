import Foundation

struct VillageMystery: Codable, Equatable, Identifiable {
    struct Role: Codable, Equatable, Identifiable {
        let id: UUID
        let name: String
        var botID: UUID?
    }
    let id: UUID
    let seed: UInt32
    let roles: [Role]
    var clues: Set<Int> = []
    var questioned: Set<Int> = []
    var accusation: Int?
    var updated = Date.now
    var culprit: Int { Int(seed % 3) }
    var title: String { ["Nattepremieren", "Den sidste forestilling", "Skyggen i biografen"][Int((seed / 3) % 3)] }
    var finished: Bool { accusation != nil }
    var canAccuse: Bool { clues.count == 3 && questioned.count == 3 && !finished }
    var introduction: String {
        "Biografens ejer er fundet død efter nattens premiere. Uret standsede klokken 22.14. Tre beboere var i nærheden, og ingen fortæller hele historien. Du skal undersøge rummene og sammenholde deres alibier. Figurerne spiller roller i en fiktiv historie."
    }
    var locations: [String] { ["Biografen", "Teknikrummet", "Caféen"] }
    static func command(_ text: String) -> Bool {
        text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines).range(of: #"^(?:start|spil|åbn) (?:et |vores |mit )?(?:mordmysterium|mysterium)\b"#, options: .regularExpression) != nil
    }
    static func start(seed: UInt32 = .random(in: 0...UInt32.max), roles: [Role]) -> Self {
        var cast = Array(roles.prefix(3))
        let defaults = ["Ada", "Noah", "Mika"]
        while cast.count < 3 { cast.append(.init(id: UUID(), name: defaults[cast.count])) }
        return .init(id: UUID(), seed: seed, roles: cast)
    }
    func clue(_ index: Int) -> String {
        switch index {
        case 0: "Uret i biografen standsede kl. 22.14. Den eneste indgang låses med et personligt nummereret nøglekort. Ingen andre døre var åbne."
        case 1: "Dørlåsen registrerede kort nr. \(culprit + 1) kl. 22.14. Teknikeren kontrollerede systemet: ingen kort var kopieret eller meldt lånt ud denne aften."
        default: "Caféens kamera viser \(roles[(culprit + 1) % 3].name) og \(roles[(culprit + 2) % 3].name) sammen fra 22.10 til 22.20. Den tredje plads ved bordet er tom."
        }
    }
    func dialogue(_ index: Int) -> String {
        guard roles.indices.contains(index) else { return "" }
        let key = "Mit nøglekort har nummer \(index + 1), og jeg har ikke lånt det til andre."
        return index == culprit
            ? "Jeg var på caféen hele aftenen. Jeg gik i hvert fald ikke ind i biografen klokken 22.14. " + key
            : "Jeg sad på caféen fra 22.10 til 22.20. Kameraet ved kassen så mig. " + key
    }
    mutating func visit(_ index: Int) {
        guard !finished, (0..<3).contains(index) else { return }; clues.insert(index); updated = .now
    }
    mutating func question(_ index: Int) {
        guard !finished, roles.indices.contains(index) else { return }; questioned.insert(index); updated = .now
    }
    @discardableResult mutating func accuse(_ index: Int) -> Bool {
        guard canAccuse, roles.indices.contains(index) else { return false }
        accusation = index; updated = .now; return true
    }
    var verdict: String? {
        guard let accusation else { return nil }
        let opening = accusation == culprit ? "Du samlede sporene korrekt." : "Din anklage ramte den forkerte."
        return opening + " Det var \(roles[culprit].name). Kort nr. \(culprit + 1) blev brugt kl. 22.14, og kameraet afkræfter café-alibiet. De to andre var dokumenteret på caféen hele tidsrummet."
    }
    struct Store {
        var file: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FadedAI", isDirectory: true).appendingPathComponent("village-mystery.json")
        func load() throws -> VillageMystery? {
            guard FileManager.default.fileExists(atPath: file.path) else { return nil }
            let data = try Data(contentsOf: file)
            guard data.count < 100_000 else { throw CocoaError(.fileReadCorruptFile) }
            let value = try JSONDecoder().decode(VillageMystery.self, from: data)
            guard value.roles.count == 3, value.clues.isSubset(of: Set(0..<3)), value.questioned.isSubset(of: Set(0..<3)),
                  value.accusation.map({ (0..<3).contains($0) }) ?? true else { throw CocoaError(.fileReadCorruptFile) }
            return value
        }
        func save(_ value: VillageMystery) throws {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(value).write(to: file, options: .atomic)
        }
        func remove() throws { if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) } }
    }
}
