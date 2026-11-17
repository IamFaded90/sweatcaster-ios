import Foundation
import PDFKit
import UIKit
import XCTest
@testable import SweatCaster

final class AgentChatActionTests: XCTestCase {
    @MainActor func testComposioBillingFailureHasAnActionableDanishExplanation() {
        let error = ComposioCloud.failure(["data": ["status_code": 402, "message": "Insufficient Balance"]])
        XCTAssertTrue(error.localizedDescription.contains("saldo"))
        XCTAssertEqual(ComposioCloud.endpoint.absoluteString, "https://connect.composio.dev/mcp")
        XCTAssertTrue(AppErrorPresentation(error).title.contains("saldo"))
    }

    @MainActor func testVeoKeepsItsOperationIdentifierAndRequiresHTTPSMedia() {
        XCTAssertEqual(VeoCloudVideo.operation(["name": "models/veo-3/operations/example"]),
                       "models/veo-3/operations/example")
        XCTAssertEqual(VeoCloudVideo.operation(["operation_name": "operations/example"]), "operations/example")
        XCTAssertNil(VeoCloudVideo.operation(["name": "video.mp4"]))
        let output: [String: Any] = ["response": ["generatedVideos": [["video": ["uri": "https://example.org/video.mp4"]]]]]
        XCTAssertEqual(VeoCloudVideo.videoURL(output)?.host, "example.org")
        XCTAssertNil(VeoCloudVideo.videoURL(["download_url": "file:///tmp/video.mp4"]))
        XCTAssertNil(VeoCloudVideo.videoURL(["download_url": "https://user:password@example.org/video.mp4"]))
    }

    @MainActor func testScannedPDFTextIsSavedOnTheSelectedPageAndLeavesOriginalIntact() throws {
        let rectangle = CGRect(x: 0, y: 0, width: 200, height: 320)
        let scan = UIGraphicsImageRenderer(size: rectangle.size).image { context in
            context.cgContext.setFillColor(UIColor.white.cgColor)
            context.cgContext.fill(rectangle)
            context.cgContext.setFillColor(UIColor.darkGray.cgColor)
            context.cgContext.fill(CGRect(x: 18, y: 105, width: 162, height: 1))
        }
        let original = UIGraphicsPDFRenderer(bounds: rectangle).pdfData { context in
            context.beginPage()
            scan.draw(in: rectangle)
            context.beginPage()
            scan.draw(in: rectangle)
        }
        let copy = try XCTUnwrap(PDFDocument(data: original))
        let page = try XCTUnwrap(copy.page(at: 1))
        let placement = AssistantPDFForm.Placement(page: 1, point: CGPoint(x: 197, y: 210), text: "Søndervej 12")
        let annotation = try XCTUnwrap(AssistantPDFForm.textAnnotation(placement, on: page))
        XCTAssertTrue(page.bounds(for: .cropBox).contains(annotation.bounds))
        page.addAnnotation(annotation)

        let data = try XCTUnwrap(copy.dataRepresentation())
        let reopened = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertEqual(reopened.pageCount, 2)
        XCTAssertEqual(reopened.page(at: 0)?.annotations.count, 0)
        let saved = try XCTUnwrap(reopened.page(at: 1)?.annotations.first)
        XCTAssertEqual(saved.userName, placement.id.uuidString)
        XCTAssertEqual(saved.contents, placement.text)
        XCTAssertTrue(saved.shouldDisplay)
        XCTAssertTrue(saved.shouldPrint)
        XCTAssertEqual(PDFDocument(data: original)?.page(at: 1)?.annotations.count, 0)
    }

    @MainActor func testUserExamplesRouteToActions() {
        guard case .action(.gmailReply)? = AgentChatIntent.match("Svar tandlægen, at fredag passer.") else {
            return XCTFail("The reply should open Gmail review")
        }
        guard case .action(.gmailReply)? = AgentChatIntent.match("Find lige den mail fra ham med bilen og sig, at torsdag er fin") else {
            return XCTFail("Natural phrasing should open Gmail review")
        }
        guard case .action(.phone)? = AgentChatIntent.match("Find en ledig time på torsdag.") else {
            return XCTFail("Free time should open the calendar tool")
        }
        guard case .action(.today)? = AgentChatIntent.match("Hvad skal jeg nå i dag?") else {
            return XCTFail("The prompt should open today's overview")
        }
    }

    func testOfflineMailRevisionKeepsTheExistingReplyAndOtherDetails() {
        let body = "Hej,\n\nTorsdag passer mig fint. Jeg tager skemaet med.\n\nVenlig hilsen"
        let instruction = "Fredag kl. 11 i stedet, og gør det kortere."
        XCTAssertTrue(AgentMailRevision.matches(instruction))
        XCTAssertEqual(AgentMailRevision.apply(instruction, to: body),
                       "Hej,\n\nFredag kl. 11 passer fint. Jeg tager skemaet med.\n\nVenlig hilsen")
        XCTAssertNil(AgentMailRevision.apply(instruction, to: "Torsdag eller lørdag passer."))
        XCTAssertFalse(AgentMailRevision.matches("Hvordan gør jeg det kortere?"))
        XCTAssertEqual(AgentMailRevision.apply("Skriv i stedet, at fredag passer.", to: body),
                       "Hej,\n\nFredag passer.\n\nVenlig hilsen")
    }

    @MainActor func testQuestionsAboutHowToUseTheToolsStayInOrdinaryChat() {
        let prompts = ["Hvordan sender jeg svar til tandlægen?", "Hvordan sætter jeg alarm på iPhone?",
                       "Hvad er klokken hos mig i dag?", "Skriv en guide til at oprette en aftale"]
        for prompt in prompts { XCTAssertNil(AgentChatIntent.match(prompt), prompt) }
    }

    @MainActor func testAssistantSkillsAreChosenFromNaturalDanish() {
        guard case .action(.appointmentCheck)? = AgentChatIntent.match("Kan jeg nå tandlægen torsdag?") else {
            return XCTFail("Calendar and Gmail should use one appointment check")
        }
        guard case .action(.meetingPrep)? = AgentChatIntent.match("Hvad skal jeg have med til tandlægen på torsdag?") else {
            return XCTFail("Preparation should use the meeting skill")
        }
        guard case .action(.mailReminder)? = AgentChatIntent.match("Mind mig om at hente den pakke") else {
            return XCTFail("The package reminder should look up a Gmail source")
        }
        guard case .action(.followups)? = AgentChatIntent.match("Hvem har ikke svaret?") else {
            return XCTFail("The agent should open sent thread follow-up")
        }
        XCTAssertNil(AgentChatIntent.match("Kan jeg nå at lære guitar på en måned?"))
        XCTAssertEqual(AgentAvailabilityQuery.match("kan jeg nå tandlægen torsdag")?.terms, ["tandlæge"])
    }

    @MainActor func testWorkshopQuestionCanRecoverTheOriginalSubject() {
        guard case .resume(let topic)? = AgentChatIntent.match("Hvad blev der af det med bilen?") else {
            return XCTFail("The prompt should reopen a stored action")
        }
        XCTAssertFalse(AgentChatIntent.topicWords(topic).isDisjoint(with:
            AgentChatIntent.topicWords("få en tid på værksted i næste uge")))
    }

    func testReceiptPersistsAndOlderTurnsStillDecode() throws {
        let decoder = JSONDecoder()
        let previous = """
            {"id":"F167F35C-8FAB-4C86-AF11-C87A6F0A59B1","prompt":"Hej","reply":"Hej med dig"}
            """
        let olderTurn = try decoder.decode(PrivateChatTurn.self, from: Data(previous.utf8))
        XCTAssertNil(olderTurn.agentAction)

        let link = try XCTUnwrap(URL(string: "https://mail.google.com/mail/u/0/#all/test"))
        var turn = PrivateChatTurn(prompt: "Svar tandlægen", reply: "Svar sendt via Gmail.")
        turn.agentAction = AgentChatAction(kind: .gmailReply, receipt: turn.reply, receiptLink: link)
        let restored = try decoder.decode(PrivateChatTurn.self, from: JSONEncoder().encode(turn))
        XCTAssertEqual(restored.id, turn.id)
        XCTAssertEqual(restored.agentAction?.receipt, "Svar sendt via Gmail.")
        XCTAssertEqual(restored.agentAction?.receiptLink, link)
    }

    func testDraftPersistsItsOriginalMessageAndRecipient() throws {
        let draft = AgentGmailReply.StoredDraft(pcID: "paired", messageID: "message", threadID: "thread",
                                                recipient: "person@example.com", body: "Fredag passer.")
        var turn = PrivateChatTurn(prompt: "Svar tandlægen", reply: "")
        turn.agentAction = AgentChatAction(kind: .gmailReply, mailDraft: draft)
        let restored = try JSONDecoder().decode(PrivateChatTurn.self, from: JSONEncoder().encode(turn))
        XCTAssertEqual(restored.agentAction?.mailDraft, draft)
        XCTAssertNil(restored.agentAction?.receipt)
    }

    func testHoldchatUsesThePhoneClockForLocalQuestions() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 3_600)!
        let now = Date(timeIntervalSince1970: 3_600)
        XCTAssertEqual(TeamChatPolicy.phoneFact(for: "Hvad er klokken lige nu?")?.answer(now: now, calendar: calendar),
                       "Klokken er 02:00.")
        XCTAssertEqual(TeamChatPolicy.phoneFact(for: "Hvad er kl. nu?")?.answer(now: now, calendar: calendar),
                       "Klokken er 02:00.")
        XCTAssertNil(TeamChatPolicy.phoneFact(for: "Hvordan virker et ur?"))
        XCTAssertNil(TeamChatPolicy.phoneFact(for: "Hvad er klokken i London?"))
        XCTAssertNil(TeamChatPolicy.phoneFact(for: "Sæt en alarm klokken 8"))
    }

    func testSharedCalendarRequiresAnExplicitRequestAndKeepsDatesDistinct() {
        XCTAssertTrue(AgentSharedCalendar.matches("Læg den dato i min kalender."))
        XCTAssertTrue(AgentSharedCalendar.matches("Læg datoen i min kalender: 2026-11-25"))
        XCTAssertFalse(AgentSharedCalendar.matches("Hvilken dato står der her?"))
        XCTAssertEqual(AgentSharedCalendar.dates(in: "25/11/2026 eller 2026-12-02, jf. 25.11.2026."),
                       ["2026-11-25", "2026-12-02"])
        XCTAssertTrue(AgentSharedCalendar.dates(in: "31.02.2026 eller 2026-04-31").isEmpty)
    }

    func testVoiceInboxKeepsListsAndBreaksAtNewActions() {
        let input = "Ring til Mads, køb mælk og kaffe, og idéen med den blå figur skal gemmes."
        let suggestions = VoiceInboxParser.suggestions(from: input)
        XCTAssertEqual(suggestions.map(\.kind), [.reminder, .shopping, .note])
        XCTAssertEqual(suggestions[1].text, "køb mælk og kaffe")
        XCTAssertEqual(VoiceInboxParser.suggestions(from: "Ring til Mads og køb mælk").count, 2)
        XCTAssertEqual(VoiceInboxParser.suggestions(from: "Mind mig om at hente det kl. 8.30.").first?.text, "hente det kl. 8.30")
        XCTAssertEqual(VoiceInboxParser.suggestions(from: "Ring til Mads 25. november kl. 8.30. Køb mælk").count, 2)
    }

    func testPDFProfileMatchesOnlyKnownDocumentFields() {
        XCTAssertEqual(AssistantPDFProfileField.match("E-mail"), .email)
        XCTAssertEqual(AssistantPDFProfileField.match("POST NR."), .postalCode)
        XCTAssertNil(AssistantPDFProfileField.match("Navn på medansøger"))
        XCTAssertNil(AssistantPDFProfileField.match("CPR-nummer"))
    }

    func testHoldchatSkipsCopiesAndKeepsDifferentRecommendations() {
        let primary = "Vi kan flytte aftalen til torsdag og bekræfte den nye tid med værkstedet samme dag."
        XCTAssertNil(TeamChatPolicy.contribution("**\(primary.uppercased())**", after: [primary]))
        XCTAssertNil(TeamChatPolicy.contribution(primary + " Tak.", after: [primary]))
        XCTAssertNil(TeamChatPolicy.contribution("PAS.", after: [primary]))
        let alternative = primary.replacingOccurrences(of: "torsdag", with: "fredag")
        XCTAssertEqual(TeamChatPolicy.contribution(alternative, after: [primary]), alternative)
        XCTAssertEqual(TeamChatPolicy.contribution("Spørg også, om de har en lånebil.", after: [primary]),
                       "Spørg også, om de har en lånebil.")
    }
    func testOpenRouterFreeCatalogRejectsPaidAndUnknownPrices() throws {
        let id = "google/gemma-4-31b-it:free"
        XCTAssertEqual(OpenRouterCloud.freeChoices(in: ["data": [["id": id,
            "pricing": ["prompt": "0", "completion": "0"]]]]), [id])
        XCTAssertTrue(OpenRouterCloud.freeChoices(in: ["data": [["id": id,
            "pricing": ["prompt": "0", "completion": "0.1"]]]]).isEmpty)
        XCTAssertTrue(OpenRouterCloud.freeChoices(in: ["data": [["id": id,
            "pricing": [String: String]()]]]).isEmpty)
        XCTAssertThrowsError(try OpenRouterCloud.body(model: "paid/model", messages: []))
        let request = try OpenRouterCloud.body(model: "openrouter/free", messages: [])
        let provider = try XCTUnwrap(request["provider"] as? [String: Any])
        XCTAssertEqual(provider["max_price"] as? [String: Int], ["prompt": 0, "completion": 0, "request": 0])
    }

}
