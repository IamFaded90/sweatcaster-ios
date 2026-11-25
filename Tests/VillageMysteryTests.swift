import XCTest
@testable import SweatCaster

final class VillageMysteryTests: XCTestCase {
    func testCaseCannotFinishUntilEvidenceAndAlibisAreCollected() {
        var game = VillageMystery.start(seed: 7, roles: [])
        XCTAssertNil(game.verdict); XCTAssertFalse(game.accuse(0))
        for i in 0..<3 { game.visit(i); game.question(i) }
        XCTAssertTrue(game.canAccuse); XCTAssertTrue(game.accuse(game.culprit))
        XCTAssertTrue(game.verdict?.contains("korrekt") == true)
        XCTAssertFalse(game.accuse(1))
    }
    func testAllCulpritVariantsHaveConsistentEvidence() {
        for seed in UInt32(0)...8 {
            let game = VillageMystery.start(seed: seed, roles: [])
            XCTAssertTrue(game.clue(1).contains("nr. \(game.culprit + 1)"))
            XCTAssertFalse(game.clue(2).contains(game.roles[game.culprit].name))
        }
    }
    func testProgressSurvivesReopenAndCanBeDeleted() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = VillageMystery.Store(file: root.appendingPathComponent("game.json"))
        var game = VillageMystery.start(seed: 1, roles: []); game.visit(1); game.question(2)
        try storage.save(game); XCTAssertEqual(try storage.load(), game)
        try storage.remove(); XCTAssertNil(try storage.load())
    }
}
