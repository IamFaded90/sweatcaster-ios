import Foundation
import XCTest
@testable import SweatCaster

final class AgentReplyQualityTests: XCTestCase {
    private let reply = "Vi har tidligere talt om den røde bil og en aftale på fredag. Jeg vil foreslå at du begynder med at se på kalenderen og derefter finder en ledig tid."
    func testLongExactAndCosmeticRepetitionIsDetected() {
        XCTAssertTrue(AgentReplyQuality.repeats(reply, previous: [reply]))
        XCTAssertTrue(AgentReplyQuality.repeats("**" + reply.uppercased() + "**", previous: [reply]))
        XCTAssertFalse(AgentReplyQuality.repeats("Ja", previous: ["Ja"]))
        XCTAssertFalse(AgentReplyQuality.repeats("Aftalen er lørdag klokken 14, og den gælder den blå bil. Det er en ny tid, som du netop har rettet, så fredag er ikke længere valgt.", previous: [reply]))
    }
    func testLanguageCorrectionDoesNotCaptureTranslationOrQuestions() {
        XCTAssertEqual(AgentReplyQuality.languageCorrection("Nej, skriv på dansk!"), "Svar altid på dansk")
        XCTAssertEqual(AgentReplyQuality.languageCorrection("Svar på engelsk fremover"), "Svar altid på engelsk")
        XCTAssertNil(AgentReplyQuality.languageCorrection("Kan du tale dansk?"))
        XCTAssertNil(AgentReplyQuality.languageCorrection("Oversæt det her til dansk"))
    }
    func testNewLanguageReplacesOldPreferenceOnlyForThisAgent() throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = UUID(), second = UUID()
        AgentChatPreferences.remember("Svar altid på engelsk", for: first, defaults: defaults)
        AgentChatPreferences.remember("Svar altid på engelsk", for: second, defaults: defaults)
        AgentChatPreferences.remember("Svar altid på dansk", for: first, defaults: defaults)
        XCTAssertEqual(AgentChatPreferences.values(for: first, defaults: defaults), ["Svar altid på dansk"])
        XCTAssertEqual(AgentChatPreferences.values(for: second, defaults: defaults), ["Svar altid på engelsk"])
        XCTAssertTrue(AgentChatPreferences.instructions(for: first, question: "Hej", defaults: defaults).contains("dansk"))
    }
    func testExplicitCorrectionSurvivesBeyondShortModelHistoryWithoutInventingFacts() {
        let prompts = ["Vi mødes fredag", "Rettelse: lørdag klokken 14"] + Array(repeating: "En anden besked", count: 12)
        let context = AgentReplyQuality.correctionContext(prompts: prompts)
        XCTAssertTrue(context.contains("lørdag klokken 14"))
        XCTAssertTrue(context.contains("Vi mødes fredag"))
        XCTAssertTrue(context.contains("ikke bevis"))
        XCTAssertFalse(context.contains("En anden besked"))
        XCTAssertEqual(AgentReplyQuality.correctionContext(prompts: ["Hvornår mødes vi?", "Måske fredag"]), "")
    }
}
