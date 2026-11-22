import Foundation
import XCTest
@testable import SweatCaster

final class AgentPersonalPreferenceTests: XCTestCase {
    @MainActor func testCalendarFollowUpUsesBothReadResultsInOrder() async throws {
        let time = Date(timeIntervalSince1970: 1_800_000_000)
        let calendar = Calendar(identifier: .gregorian)
        let date = #"{"tool":"date","input":"0"}"#
        var reads: [String] = []
        var modelInputs: [[String]] = []
        let result = try await AgentReplyDriver.finishToolRounds(first: date) { call in
            reads.append(call.tool)
            if call.tool == "calendar" && call.input == "0" { return "Prøvekalender: 2 aftaler" }
            return AgentLocalTool.answer(call, now: time, calendar: calendar)
        } followUp: { verified, _ in
            modelInputs.append(verified)
            return verified.count == 1 ? #"{"input":"0","tool":"calendar"}"# : "Der er to aftaler den dag."
        }
        XCTAssertEqual(reads, ["date", "calendar"])
        XCTAssertEqual(modelInputs.map(\.count), [1, 2])
        XCTAssertEqual(modelInputs.last?.first, AgentLocalTool.answer(date, now: time, calendar: calendar))
        XCTAssertEqual(modelInputs.last?.last, "Prøvekalender: 2 aftaler")
        XCTAssertEqual(result, "Der er to aftaler den dag.")
        XCTAssertTrue(AgentLocalTool.asksAboutOwnCalendar("Hvor mange møder har jeg på torsdag?"))
        XCTAssertFalse(AgentLocalTool.asksAboutOwnCalendar("Hvordan opfinder man en kalender?"))
    }

    @MainActor func testToolLoopStopsForRepeatsWritesMalformedRequestsAndFailedModels() async throws {
        let first = #"{"tool":"calculator","input":"12*2"}"#
        for next in [#"{"input":" 12*2 ","tool":"calculator"}"#, #"{"tool":"send_mail","input":"test"}"#,
                     #"{"tool":"create_event","status":"done"}"#, "broken"] {
            var count = 0
            let result = try await AgentReplyDriver.finishToolRounds(first: first) { call in
                guard call.tool == "calculator" else { return nil }
                count += 1
                return "Prøveresultat: 24"
            } followUp: { _, _ in
                if next == "broken" { throw URLError(.notConnectedToInternet) }
                return next
            }
            XCTAssertEqual(count, 1)
            XCTAssertEqual(result, "Prøveresultat: 24")
        }
    }

    @MainActor func testLocalModelCanReturnTwoNumericLookupsTogether() async throws {
        let date = #"{"tool":"date","input":0}"#
        let day = #"{"tool":"calendar","input":0}"#
        for payload in [date + "\n" + day, "[" + date + "," + day + "]"] {
            var reads: [String] = []
            let answer = try await AgentReplyDriver.finishToolRounds(first: payload) { call in
                reads.append(call.tool)
                XCTAssertEqual(call.input, "0")
                return call.tool
            } followUp: { values, _ in
                XCTAssertEqual(values, ["date", "calendar"])
                throw URLError(.timedOut)
            }
            XCTAssertEqual(answer, "date\ncalendar")
            XCTAssertEqual(reads, ["date", "calendar"])
        }
        let mixed = date + "\n" + #"{"tool":"create_event","status":"done"}"#
        XCTAssertNil(AgentLocalTool.requests(mixed))
        XCTAssertTrue(AgentReplyDriver.displayText(mixed).contains("ikke gennemført"))
    }

    @MainActor func testToolLoopBoundsDistinctCallsAndPropagatesCancellation() async throws {
        let first = #"{"tool":"date","input":"0"}"#
        var lastRequests: [Bool] = []
        let result = try await AgentReplyDriver.finishToolRounds(first: first) { input in input.input } followUp: { results, final in
            lastRequests.append(final)
            return "{\"tool\":\"date\",\"input\":\"\(results.count)\"}"
        }
        XCTAssertEqual(result, "0\n1\n2")
        XCTAssertEqual(lastRequests, [false, false, true])
        let task = Task {
            try await AgentReplyDriver.finishToolRounds(first: first) { _ in "dato" } followUp: { _, _ in
                withUnsafeCurrentTask { $0?.cancel() }
                throw URLError(.cancelled)
            }
        }
        do { _ = try await task.value; XCTFail("Stoppet arbejde må ikke udgive et svar") }
        catch is CancellationError { }
    }

    func testEditedWishKeepsScopeAndAStaleEditCannotRestoreDeletedData() throws {
        let suite = "preferences-edit-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let bot = UUID()
        let shared = AgentChatPreferences.Entry(value: "Aftaler efter kl. 10", bot: nil)
        AgentChatPreferences.remember(shared.value, defaults: defaults)
        AgentChatPreferences.remember(shared.value, for: bot, defaults: defaults)
        XCTAssertFalse(AgentChatPreferences.replace(shared, with: "   ", defaults: defaults))
        XCTAssertTrue(AgentChatPreferences.replace(shared, with: "Aftaler efter kl. 12", defaults: defaults))
        XCTAssertFalse(AgentChatPreferences.replace(shared, with: "Aftaler efter kl. 15", defaults: defaults))
        let reopened = try XCTUnwrap(UserDefaults(suiteName: suite))
        XCTAssertEqual(AgentChatPreferences.preferredStartHour(for: UUID(), defaults: reopened), 12)
        XCTAssertEqual(AgentChatPreferences.preferredStartHour(for: bot, defaults: reopened), 10)
    }

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

final class AgentLocalTranslationTests: XCTestCase {
    @MainActor func testDanishTranslationPicksAnInstalledModelAndKeepsOtherChatChoices() async {
        func choose(_ chat: String, _ ready: [String]) -> String {
            AgentTranslationSession.initialModel(suggested: chat, ready: ready, mini: "mini", gemma: "gemma")
        }
        XCTAssertEqual(choose("mini", ["mini", "apple", "gemma"]), "gemma")
        XCTAssertEqual(choose("my-model", ["mini", "gemma", "my-model"]), "my-model")
        XCTAssertEqual(choose("mini", ["mini"]), "mini")
        XCTAssertEqual(choose("mini", []), "")
    }

    @MainActor func testLongAnswerKeepsParagraphsNamesAndNumbersAcrossStreamingPassages() async throws {
        let sentence = "Ms. Sørensen meets René 👩🏽‍🔬 at 14:35 on Friday. "
        let original = "  " + String(repeating: sentence, count: 52) + "\r\n\r\n  Plan B, item 07.\n"
        let session = AgentTranslationSession(original: original)
        var inputs: [String] = []
        let task = try XCTUnwrap(session.start(model: "local") { input, update in
            inputs.append(input)
            update("unfærdigt")
            update(input.replacingOccurrences(of: "Friday", with: "fredag"))
        })
        await task.value
        XCTAssertGreaterThan(original.unicodeScalars.count, 2_000)
        XCTAssertTrue(inputs.allSatisfy { !$0.isEmpty && $0.unicodeScalars.count <= 500 })
        XCTAssertGreaterThan(session.count, 4)
        XCTAssertEqual(inputs.count, session.count)
        XCTAssertEqual(session.completed, session.count)
        XCTAssertEqual(session.translation, original.replacingOccurrences(of: "Friday", with: "fredag"))
        XCTAssertNil(session.notice)
        XCTAssertEqual(AgentTranslationSession(original: " \n\t").count, 0)
    }

    @MainActor func testRetryAfterEmptyStreamOrCancellationRetainsCompletedParts() async throws {
        let session = AgentTranslationSession(original: "first\n\nsecond\nthird")
        var later: ((String) -> Void)?
        var calls: [String] = []
        let first = try XCTUnwrap(session.start(model: "A") { source, update in
            calls.append(source)
            if source == "first" { update("først") }
            else { later = update; update("   ") }
        })
        await first.value
        XCTAssertEqual(session.completed, 1)
        XCTAssertNotNil(session.notice)
        let second = try XCTUnwrap(session.start(model: "A") { source, update in
            calls.append(source)
            later?("forældet svar")
            XCTAssertEqual(session.translation, "først")
            update("halvfærdigt svar")
            session.stop()
            update("forældet svar efter stop")
        })
        await second.value
        XCTAssertEqual(session.translation, "først")
        XCTAssertEqual(session.completed, 1)
        let last = try XCTUnwrap(session.start(model: "A") { source, update in
            calls.append(source)
            update(source == "second" ? "anden" : "tredje")
        })
        await last.value
        XCTAssertEqual(calls, ["first", "second", "second", "second", "third"])
        XCTAssertEqual(session.translation, "først\n\nanden\ntredje")
        session.select("B")
        XCTAssertEqual(session.translation, "")
        XCTAssertEqual(session.completed, 0)
    }
}
