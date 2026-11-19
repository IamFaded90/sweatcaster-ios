import Foundation
import XCTest
@testable import SweatCaster

final class AgentPersonalPreferenceTests: XCTestCase {
    func testExplicitWishesAndOneOffQuestions() {
        XCTAssertEqual(AgentChatPreferences.command("Svar mig fremover kort"), .remember("Svar mig fremover kort", shared: false))
        XCTAssertEqual(AgentChatPreferences.command("Husk, at jeg er vegetar."), .remember("jeg er vegetar", shared: false))
        XCTAssertEqual(AgentChatPreferences.command("Til alle agenter: Kald mig Ly"), .remember("Kald mig Ly", shared: true))
        XCTAssertEqual(AgentChatPreferences.command("Hvad husker du om mig?"), .show)
        XCTAssertEqual(AgentChatPreferences.command("Glem mine ønsker"), .clearPersonal)
        XCTAssertEqual(AgentChatPreferences.command("Glem de fælles ønsker"), .clearShared)
        for question in ["Svar kort på det her", "Husk at ringe til min læge", "Til alle agenter: Send mailen",
                         "Hvordan får jeg dig til at huske noget?"] { XCTAssertNil(AgentChatPreferences.command(question)) }
    }

    func testWishesPersistPerAgentAndLegacyWishesStayShared() throws {
        let suite = "preferences-tests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let eva = UUID(), adam = UUID()
        defaults.set(["Husk at jeg vil have aftaler efter kl. 11."], forKey: "fadedai.agent.chat.preferences.v1")
        AgentChatPreferences.remember("jeg vil have aftaler efter klokken 14", for: eva, defaults: defaults)
        AgentChatPreferences.remember("Svar mig fremover kort", for: adam, defaults: defaults)
        let reopened = try XCTUnwrap(UserDefaults(suiteName: suite))
        XCTAssertEqual(AgentChatPreferences.preferredStartHour(for: eva, defaults: reopened), 14)
        XCTAssertEqual(AgentChatPreferences.preferredStartHour(for: adam, defaults: reopened), 11)
        let entries = AgentChatPreferences.entries(for: eva, defaults: reopened)
        XCTAssertEqual(entries.map(\.bot), [eva, nil])
        AgentChatPreferences.remove(entries[0], defaults: reopened)
        XCTAssertEqual(AgentChatPreferences.preferredStartHour(for: eva, defaults: defaults), 11)
        AgentChatPreferences.clear(for: nil, defaults: defaults)
        XCTAssertNil(AgentChatPreferences.preferredStartHour(for: eva, defaults: defaults))
        XCTAssertEqual(AgentChatPreferences.values(for: adam, defaults: defaults), ["Svar mig fremover kort"])
        AgentChatPreferences.remember("Kald mig Lydon", defaults: defaults)
        AgentChatPreferences.remember("Kald mig Ly", for: eva, defaults: defaults)
        AgentChatPreferences.remember("Kald mig Fade", for: eva, defaults: defaults)
        let personal = AgentChatPreferences.instructions(for: eva, question: "Hej", defaults: defaults)
        XCTAssertTrue(personal.contains("Kald mig Fade"))
        XCTAssertFalse(personal.contains("Kald mig Ly"))
        XCTAssertFalse(AgentChatPreferences.values(for: eva, defaults: defaults).contains("Kald mig Ly"))
    }

    func testUseOnlyRelevantPreferencesAndKeepPublicDraftsSeparate() throws {
        let suite = "preferences-tests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let bot = UUID()
        for wish in ["jeg er vegetar", "Kald mig Ly", "mine Instagram-opslag skal have højst ét hashtag"] {
            AgentChatPreferences.remember(wish, for: bot, defaults: defaults)
        }
        func context(_ question: String, chat: Bool = true) -> String {
            AgentChatPreferences.instructions(for: bot, question: question, useChatStyle: chat, defaults: defaults)
        }
        XCTAssertTrue(context("Hvad skal jeg lave til aftensmad?").contains("vegetar"))
        XCTAssertTrue(context("Hvad skal jeg lave til aftensmad?").contains("Kald mig Ly"))
        XCTAssertFalse(context("Hvordan virker et kompas?").contains("vegetar"))
        XCTAssertFalse(context("Hvordan virker et kompas?").contains("hashtag"))
        let caption = context("Instagram", chat: false)
        XCTAssertTrue(caption.contains("hashtag"))
        XCTAssertFalse(caption.contains("Kald mig Ly"))
        XCTAssertFalse(caption.contains("vegetar"))
        XCTAssertEqual(AgentChatPreferences.instructions(for: UUID(), question: "Instagram", defaults: defaults), "")
    }

    func testPCReceivesLatePreferencesWithinActualInstructionLimit() {
        let profile = String(repeating: "x", count: 2_000) + "Brug korte svar"
        let previous = String(repeating: "🎗️abcdef", count: 300) + "Seneste sætning"
        let result = AgentReplyDriver.computerInstructions(profile, previous: previous)
        XCTAssertTrue(result.hasPrefix(profile))
        XCTAssertTrue(result.hasSuffix("Seneste sætning"))
        XCTAssertEqual(result.unicodeScalars.count, 3_000)
        XCTAssertEqual(AgentReplyDriver.computerInstructions("Kort", previous: ""), "Kort")
    }
}
