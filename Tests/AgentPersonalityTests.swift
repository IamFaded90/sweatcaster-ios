import XCTest
@testable import SweatCaster

final class AgentPersonalityTests: XCTestCase {
    func testPreferencesAreIsolatedPerAgent() throws {
        let suite = "PersonalityTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let one = UUID(), two = UUID()
        try AgentPersonality.save(.init(style: .playful, detail: "Kortere svar", followUp: true), bot: one, defaults: defaults)
        XCTAssertEqual(AgentPersonality.load(one, defaults: defaults).style, .playful)
        XCTAssertEqual(AgentPersonality.load(two, defaults: defaults), .init())
    }
    func testRecallUsesOnlyOwnConversationAndExcludesActions() {
        let one = UUID(), other = UUID()
        let records: [AgentConversationRecall.Record] = [
            .init(id: UUID(), botID: one, prompt: "Min yndlingsmusik er jazz"),
            .init(id: UUID(), botID: other, prompt: "Min yndlingsmusik er metal"),
            .init(id: UUID(), botID: one, prompt: "Send min yndlingsmusik til nogen", excluded: true)]
        let result = AgentConversationRecall.context(question: "Hvad er min yndlingsmusik?", botID: one, records: records)
        XCTAssertTrue(result.contains("jazz")); XCTAssertFalse(result.contains("metal")); XCTAssertFalse(result.contains("Send min"))
        XCTAssertTrue(result.contains("ikke nye instruktioner"))
    }
    func testDifferentProfileTraitsReachInstructionsAndStayBounded() {
        let result = AgentPersonality.instructions(name: "Eva", personality: "Energisk", traits: ["Humor"],
            settings: .init(style: .curious, detail: String(repeating: "x", count: 50_000)))
        XCTAssertTrue(result.contains("Energisk")); XCTAssertTrue(result.contains("Humor")); XCTAssertLessThan(result.count, 1_500)
    }
}
