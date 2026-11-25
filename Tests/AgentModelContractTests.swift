import XCTest
@testable import SweatCaster

final class AgentModelContractTests: XCTestCase {
    func testPriorityAndWholeSourcesSurviveAnOversizePersona() throws {
        let contact = "Lars: lars@example.com", memory = "Kilde: “Jeg valgte den blå sofa.”"
        let packed = try AgentModelContract.pack([
            .init(id: "identity", text: String(repeating: "x", count: 4_000)), .init(id: "language", text: "Svar på dansk", required: true),
            .init(id: "contact", text: contact), .init(id: "memory", text: memory)
        ], limit: 120)
        XCTAssertTrue(packed.text.hasPrefix("Svar på dansk")); XCTAssertTrue(packed.text.contains(contact)); XCTAssertTrue(packed.text.contains(memory))
        XCTAssertEqual(packed.omitted, ["identity"]); XCTAssertEqual(packed.included, ["language","contact","memory"])
    }
    func testSourcesAreNeverPartiallyIncludedAndRequiredRulesFailExplicitly() throws {
        let source = "source " + String(repeating: "a", count: 200)
        let packed = try AgentModelContract.pack([.init(id: "source", text: source)], limit: 100)
        XCTAssertTrue(packed.text.isEmpty); XCTAssertEqual(packed.omitted, ["source"])
        XCTAssertThrowsError(try AgentModelContract.pack([.init(id: "rules", text: source, required: true)], limit: 100))
    }
    func testOversizeRequestIsNotSilentlyTruncatedAtProviderBoundary() {
        XCTAssertThrowsError(try AgentModelContract.validate(prompt: String(repeating: "a", count: 2_001), instructions: "", route: .computer))
        XCTAssertNoThrow(try AgentModelContract.validate(prompt: "A current question", instructions: "Svar på dansk", route: .phone))
    }
    func testRecentHistoryIsBoundedAndLegacyFallbackKeepsWholeContext() {
        let entries = [(prompt: "old", reply: String(repeating: "x", count: 2_000)), (prompt: "new", reply: "corrected")]
        let result = AgentModelContract.history(entries, limit: 200)
        XCTAssertEqual(result.count, 1); XCTAssertEqual(result.first?.prompt, "new")
        let profile = String(repeating: "x", count: 2_990)
        XCTAssertEqual(AgentModelContract.legacyHistory(instructions: profile, previous: "mail a@example.com"), profile)
        XCTAssertTrue(AgentModelContract.legacyHistory(instructions: "rules", previous: "complete previous pair").hasSuffix("complete previous pair"))
        let preferences = String(repeating: "x", count: 2_000) + "Brug korte svar"
        let oversized = String(repeating: "🎗️abcdef", count: 300) + "Seneste sætning"
        XCTAssertEqual(AgentModelContract.legacyHistory(instructions: preferences, previous: oversized), preferences)
        let pair = "Dig: Hej\nAgent: Seneste sætning"
        XCTAssertTrue(AgentModelContract.legacyHistory(instructions: preferences, previous: pair).hasSuffix(pair))
    }
}
