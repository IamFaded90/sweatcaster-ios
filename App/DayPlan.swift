import Foundation

enum DayPlan {
    struct Task: Codable, Identifiable, Equatable, Sendable {
        var id = UUID()
        var title: String
        var minutes = 25
        var priority = 1
        var skip = false
        var notBefore: Date?
        var reminderID: String?
        var receipt: String?
    }
    struct Draft: Codable, Identifiable, Sendable {
        var id = UUID()
        var day: Date
        var start: Date
        var end: Date
        var pause = 10
        var tasks: [Task] = []
    }
    struct Busy: Sendable { let start: Date; let end: Date; let source: String }
    struct Slot: Identifiable, Equatable, Sendable { var id: UUID { task }; let task: UUID; let start: Date; let end: Date }
    struct Result { let slots: [Slot]; let unplaced: [UUID] }
    enum Failure: LocalizedError {
        case invalid, full
        var errorDescription: String? { self == .full ? "Gem højst 14 dagsplaner med 24 opgaver hver." : "Kontrollér start/slut, opgavelængder og pauser i planen." }
    }
    static func command(_ text: String) -> Bool { ["planlæg min dag", "lav en realistisk dagsplan", "åbn min dagsplan", "lav min dagsplan"].contains(text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)) }
    static func arrange(_ draft: Draft, busy: [Busy]) throws -> Result {
        guard draft.start.timeIntervalSince1970.isFinite, draft.end.timeIntervalSince1970.isFinite,
              draft.end > draft.start, draft.end.timeIntervalSince(draft.start) <= 86_400,
              (0...60).contains(draft.pause), draft.tasks.count <= 24,
              Set(draft.tasks.map(\.id)).count == draft.tasks.count,
              draft.tasks.allSatisfy({ (5...240).contains($0.minutes) && (0...3).contains($0.priority) && (1...240).contains($0.title.count) && ($0.notBefore?.timeIntervalSince1970.isFinite ?? true) }) else { throw Failure.invalid }
        let pause = Double(draft.pause * 60)
        var occupied = busy.filter { $0.start.timeIntervalSince1970.isFinite && $0.end.timeIntervalSince1970.isFinite && $0.end > $0.start && $0.end > draft.start && $0.start < draft.end }
            .map { (max(draft.start, $0.start.addingTimeInterval(-pause)), min(draft.end, $0.end.addingTimeInterval(pause))) }
        let tasks = draft.tasks.enumerated().filter { !$0.element.skip && $0.element.receipt == nil }.sorted { a, b in
            a.element.priority == b.element.priority ? a.offset < b.offset : a.element.priority > b.element.priority
        }.map(\.element)
        var slots: [Slot] = [], unplaced: [UUID] = []
        for task in tasks {
            var candidate = max(draft.start, task.notBefore ?? draft.start)
            let length = Double(task.minutes * 60)
            for interval in occupied.sorted(by: { $0.0 < $1.0 }) {
                if candidate.addingTimeInterval(length) <= interval.0 { break }
                if candidate < interval.1 { candidate = interval.1 }
            }
            guard candidate.addingTimeInterval(length) <= draft.end else { unplaced.append(task.id); continue }
            let slot = Slot(task: task.id, start: candidate, end: candidate.addingTimeInterval(length)); slots.append(slot)
            occupied.append((candidate.addingTimeInterval(-pause), slot.end.addingTimeInterval(pause)))
        }
        return Result(slots: slots.sorted { $0.start < $1.start }, unplaced: unplaced)
    }
    struct Store {
        let botID: UUID
        var root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("FadedAI/DayPlans", isDirectory: true)
        private var file: URL { root.appendingPathComponent(botID.uuidString.lowercased() + ".json") }
        func load() throws -> [Draft] {
            guard FileManager.default.fileExists(atPath: file.path) else { return [] }
            guard (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 500_000 else { throw Failure.full }
            let list = try JSONDecoder().decode([Draft].self, from: Data(contentsOf: file)); guard list.count <= 14 else { throw Failure.full }; return list
        }
        func save(_ draft: Draft) throws {
            _ = try arrange(draft, busy: [])
            var list = try load(); list.removeAll { $0.id == draft.id }; guard list.count < 14 else { throw Failure.full }; list.insert(draft, at: 0)
            try write(list)
        }
        func remove(_ id: UUID) throws { try write(load().filter { $0.id != id }) }
        private func write(_ list: [Draft]) throws {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let bytes = try JSONEncoder().encode(list); guard bytes.count <= 500_000 else { throw Failure.full }
            try bytes.write(to: file, options: [.atomic, .completeFileProtection])
        }
    }
}
