import XCTest
@testable import SweatCaster

final class AgentSkillLibraryTests: XCTestCase {
    private var markdown: Data { Data("---\nname: mail-opfølgning\ndescription: Følg beskeder og kalenderaftaler op\nallowed-tools: [mail, calendar]\n---\nLæs kilden og gennemgå svaret før afsendelse.".utf8) }
    func testImportedSkillIsDisabledUntilChosenForAgentAndOnlyRelevantOnesLoad() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AgentSkillLibrary.Store(root: root), bot = UUID(), other = UUID()
        var skill = try store.importFile(markdown)
        XCTAssertTrue(store.instructions(bot: bot, question: "mail").isEmpty)
        skill.enabledFor.insert(bot); try store.save([skill])
        XCTAssertFalse(store.instructions(bot: bot, question: "mail opfølgning").isEmpty)
        XCTAssertTrue(store.instructions(bot: other, question: "mail").isEmpty)
        XCTAssertTrue(store.instructions(bot: bot, question: "Fortæl en vittighed").isEmpty)
    }
    func testMalformedFrontmatterAndUnsupportedCapabilitiesDoNotBecomeTools() throws {
        XCTAssertThrowsError(try AgentSkillLibrary.parse(Data("Just text".utf8)))
        XCTAssertThrowsError(try AgentSkillLibrary.parse(Data("---\nname: one\nname: two\ndescription: test\n---\nDo it".utf8)))
        let unknown = try AgentSkillLibrary.parse(Data("---\nname: kode\ndescription: Kør programmer\nallowed-tools: [shell, admin]\n---\nGør noget".utf8))
        XCTAssertEqual(unknown.unsupported, ["shell", "admin"])
    }
    func testSelectedContextIsScopedExpiresAndCanBeDeleted() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AgentPhoneContext.Store(root: root), bot = UUID(), now = Date()
        try store.add(.init(id: "contact1", title: "Lars", facts: "Valgt telefonnummer: 12345678", source: "Kontakter", date: now), bot: bot)
        XCTAssertTrue(store.instructions(bot).contains("Lars")); XCTAssertTrue(store.instructions(UUID()).isEmpty)
        XCTAssertTrue(store.instructions(bot, question: "Fortæl en vittighed").isEmpty)
        XCTAssertTrue(store.instructions(bot, question: "Send ham en mail").contains("Lars"))
        XCTAssertTrue(store.instructions(bot, now: now.addingTimeInterval(9 * 3_600)).isEmpty)
        try store.clear(bot); XCTAssertTrue(store.instructions(bot).isEmpty)
    }
}
