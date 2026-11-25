import Foundation
import XCTest
@testable import FadedAIPrivateWax

final class OrdinaryWaxLookupTests: XCTestCase {
    func testActualWaxSurvivesReopenAndRemovesChangedOrDeletedSources() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let bot = UUID(), source = UUID()
        let first = OrdinaryWaxLookup(root: root)
        let found = try await first.search("kompas", botID: bot, rows: [.init(id: source, text: "Jeg har et turkis kompas i skuffen.")])
        XCTAssertEqual(found, [source])
        let reopened = OrdinaryWaxLookup(root: root)
        let same = try await reopened.search("kompas", botID: bot, rows: [.init(id: source, text: "Jeg har et turkis kompas i skuffen.")])
        XCTAssertEqual(same, [source])
        try FileManager.default.removeItem(at: root.appendingPathComponent(bot.uuidString.lowercased() + "/ordinary.wax"))
        let repaired = try await reopened.search("kompas", botID: bot, rows: [.init(id: source, text: "Jeg har et turkis kompas i skuffen.")])
        XCTAssertEqual(repaired, [source])
        let changed = try await reopened.search("kompas", botID: bot, rows: [.init(id: source, text: "Nu gemmer jeg en kobbertekande.")])
        XCTAssertEqual(changed, [])
        let absent = try await reopened.search("tekande", botID: UUID(), rows: [])
        XCTAssertEqual(absent, [])
        _ = try await reopened.search("kobbertekande", botID: bot, rows: [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(bot.uuidString.lowercased()).path))
    }
    func testDirtyIndexRebuildAndClearAreScopedToOneAgent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = OrdinaryWaxLookup(root: root), a = UUID(), b = UUID(), id = UUID()
        _ = try await engine.search("turkis", botID: a, rows: [.init(id: id, text: "turkis")])
        _ = try await engine.search("orange", botID: b, rows: [.init(id: UUID(), text: "orange")])
        try Data([1]).write(to: root.appendingPathComponent(a.uuidString.lowercased() + "/updating"))
        let found = try await engine.search("turkis", botID: a, rows: [.init(id: id, text: "turkis")])
        XCTAssertEqual(found, [id]); try await engine.clear(botID: a)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(b.uuidString.lowercased()).path))
    }
}
