import Foundation
import PDFKit
import UIKit
import XCTest
@testable import SweatCaster

final class AgentChatActionTests: XCTestCase {
    @MainActor func testAgentMilestonesSelectAnActionInsteadOfAnOrdinaryReply() {
        guard case .milestone(.repair)? = AgentChatIntent.match("Find og ret en appfejl i FadedAI") else {
            return XCTFail("Projektfejl skal åbne appreparation")
        }
        guard case .milestone(.room)? = AgentChatIntent.match("Byg et rum fra en skitse") else {
            return XCTFail("Et rum skal åbne rumbyggeren")
        }
        guard case .milestone(.casework)? = AgentChatIntent.match("Tag dig af en sag") else {
            return XCTFail("Sagen skal åbne sagsforløbet")
        }
        if case .milestone? = AgentChatIntent.match("Du skal ikke reparere appen nu") { XCTFail("Ingen opgave") }
    }

    @MainActor func testNewWorkflowsRouteBeforeChatAndKeepPCsSeparate() {
        guard case .appointmentChange? = AgentChatIntent.match("Tandlægen har flyttet min tid — få styr på det.") else {
            return XCTFail("Flyttet aftale skal åbne Gmail og iPhone-gennemgang")
        }
        guard case .gmailCleanup? = AgentChatIntent.match("Ryd op i min e-mail") else { return XCTFail("Mailoprydning") }
        guard case .pcRepair? = AgentChatIntent.match("Fix billedmotoren på min PC") else { return XCTFail("PC-reparation") }
        guard case .agentComputer(let task)? = AgentChatIntent.match("Brug din egen PC til at samle filerne") else {
            return XCTFail("Agentens computer")
        }
        XCTAssertEqual(task, "at samle filerne")
        guard case .windowHelp? = AgentChatIntent.match("Tag over på min PC") else { return XCTFail("Min PC") }
        XCTAssertNil(AgentChatIntent.match("Tandlægen har flyttet min tid."))
    }

    @MainActor func testWindowHelpOpensOnAnInvitation() {
        for prompt in ["Se mit PC-vindue", "Tag over på min PC"] {
            guard case .windowHelp? = AgentChatIntent.match(prompt) else { return XCTFail(prompt) }
        }
        for prompt in ["Adam, se lige min skærm.", "Åbn skærmhjælp",
                       "Adam, se lige min skærm, jeg kan ikke åbne filen", "Del min iPhone skærm"] {
            guard case .phoneScreen? = AgentChatIntent.match(prompt) else { return XCTFail(prompt) }
        }
        for prompt in ["Se ikke min skærm", "Du må ikke se min skærm", "Min skærm er mørk", "Hvad koster et nyt vindue?"] {
            if case .windowHelp? = AgentChatIntent.match(prompt) { XCTFail(prompt) }
            if case .phoneScreen? = AgentChatIntent.match(prompt) { XCTFail(prompt) }
        }
    }

    @MainActor func testTasteCommandUsesNamedAgentAndLeavesOrdinaryRequestsInChat() throws {
        let adam = VillageBot(name: "Adam"), eva = VillageBot(name: "Eva")
        guard case .taste(let request)? = AgentChatIntent.match("Find en dansk stemme til Eva.") else {
            return XCTFail("Stemmeprøven skal kunne åbnes direkte fra chatten")
        }
        XCTAssertEqual(request.target(in: [adam, eva], current: adam)?.id, eva.id)
        XCTAssertNil(request.target(in: [adam], current: adam))
        XCTAssertNil(request.target(in: [eva, VillageBot(name: "Eva")], current: adam))
        let local = try XCTUnwrap(AgentTasteRequest.parse("Sammenlign to landsbyfigurer"))
        XCTAssertEqual(local.target(in: [], current: adam)?.id, adam.id)
        XCTAssertNil(AgentTasteRequest.parse("Lav et billede i en anden billedstil"))
        XCTAssertNil(AgentTasteRequest.parse("Find en stemme til min podcast"))
    }

    func testAgentCalendarReadbackChecksTheApprovedDetails() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let end = start.addingTimeInterval(1800)
        func check(_ savedEnd: Date, locationMatches: Bool = true, allDay: Bool = false) -> PhoneActionVerification {
            .event(titleMatches: true, locationMatches: locationMatches, start: start, end: savedEnd,
                   expectedStart: start, expectedEnd: end, allDay: allDay)
        }
        XCTAssertEqual(check(end), .matched)
        XCTAssertEqual(check(end.addingTimeInterval(60)), .different)
        XCTAssertEqual(check(end, locationMatches: false), .different)
        XCTAssertEqual(check(end, allDay: true), .different)
        XCTAssertNotEqual(PhoneActionVerification.writeOnly.summary(for: .calendar),
                          PhoneActionVerification.matched.summary(for: .calendar))
    }

    func testAgentReminderChecksThatTheAlertExists() {
        let due = Date(timeIntervalSince1970: 1_800_000_000)
        func check(actual: Date?, alerts: [Date], completed: Bool = false) -> PhoneActionVerification {
            .reminder(fieldsMatch: true, isCompleted: completed, due: actual, expectedDue: due, alerts: alerts)
        }
        XCTAssertEqual(check(actual: due, alerts: [due]), .matched)
        XCTAssertEqual(check(actual: due, alerts: []), .different)
        XCTAssertEqual(check(actual: nil, alerts: [due]), .different)
        XCTAssertEqual(check(actual: due, alerts: [due], completed: true), .different)
        XCTAssertEqual(PhoneActionVerification.reminder(fieldsMatch: true, isCompleted: false,
                                                        due: nil, expectedDue: nil, alerts: []), .matched)
        XCTAssertFalse(PhoneActionVerification.sameTime(due.addingTimeInterval(60), due))
    }

    @MainActor func testInstagramScheduleAndFollowUpInDanish() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Copenhagen"))
        func date(_ day: Int, _ hour: Int, _ minute: Int = 0) throws -> Date {
            try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute)))
        }
        let now = try date(19, 11)
        let message = "Post den fredag kl. 18, og fortæl mig søndag, hvordan den klarede sig."
        let plan = try XCTUnwrap(AgentInstagramTiming.requested(in: message, now: now, calendar: calendar))
        XCTAssertEqual(plan.publish, try date(20, 18))
        XCTAssertEqual(plan.followUp, try date(22, 9))
        XCTAssertFalse(plan.notifyEmail)
        let mailed = try XCTUnwrap(AgentInstagramTiming.requested(in: "Post den fredag kl. 18, og send mig en mail søndag",
                                                                 now: now, calendar: calendar))
        XCTAssertEqual(mailed.followUp, try date(22, 9))
        XCTAssertTrue(mailed.notifyEmail)
        let weekend = try XCTUnwrap(AgentInstagramTiming.requested(in: "Udgiv den lørdag klokken 17.15 og følg op mandag kl. 12",
                                                                  now: now, calendar: calendar))
        XCTAssertEqual(weekend.publish, try date(21, 17, 15))
        XCTAssertEqual(weekend.followUp, try date(23, 12))
        XCTAssertNil(AgentInstagramTiming.requested(in: "Post på Instagram med teksten Fest på fredag!", now: now, calendar: calendar))
        guard case .scheduleInstagram? = AgentChatIntent.match(message) else { return XCTFail(message) }
        guard case .action(.instagramPlans)? = AgentChatIntent.match("Vis mine planlagte Instagram-opslag") else {
            return XCTFail("Planlisten skal kunne åbnes fra chatten")
        }
        guard case .action(.instagramPost)? = AgentChatIntent.match("Planlæg et Instagram-opslag fredag") else {
            return XCTFail("Et nyt opslag skal kunne planlægges fra chatten")
        }
        if case .scheduleInstagram? = AgentChatIntent.match("Læg det i min kalender fredag") { XCTFail("Kalenderen er en anden opgave") }
    }

    func testScheduledPublicationWaitsForActualMetricsAndEmail() throws {
        let id = UUID()
        func receipt(_ report: String, _ emailState: String) throws -> AgentInstagramJob {
            let json = """
            {"id":"\(id.uuidString)","state":"published","followUpAt":4,"publishedAt":2,"report":\(report),"emailState":"\(emailState)"}
            """
            return try JSONDecoder().decode(AgentInstagramJob.self, from: Data(json.utf8))
        }
        let waiting = try receipt(#"{"state":"pending"}"#, "off")
        XCTAssertFalse(waiting.completed)
        XCTAssertNil(waiting.reportText)
        let ready = #"{"state":"ready","checkedAt":6,"metrics":{"likes":0,"reach":34}}"#
        XCTAssertFalse(try receipt(ready, "pending").completed)
        let delivered = try receipt(ready, "sent")
        XCTAssertTrue(delivered.completed)
        XCTAssertTrue(delivered.summary.contains("Likes: 0"))
        XCTAssertTrue(delivered.summary.contains("Nåede konti: 34"))
        XCTAssertFalse(delivered.summary.contains("Delinger"))
        XCTAssertTrue(try receipt(#"{"state":"unavailable","note":"Ingen adgang til tal."}"#, "off").completed)
    }

    @MainActor func testInstagramChatSeparatesSignupDraftAndAdvice() {
        for question in ["Lav et Instagram-opslag om min kaffe", "Kan du poste et foto på Instagram?",
                         "Skriv en billedtekst til min kone"] {
            let intent = AgentChatIntent.match(question)
            if question.hasSuffix("kone") { XCTAssertNil(intent); continue }
            guard case .action(.instagramPost)? = intent else { return XCTFail(question) }
        }
        for prompt in ["Opret din egen Instagram-konto", "Kan du lave en konto på Instagram?",
                       "Tilmeld dig på https://instagram.com/accounts/emailsignup/"] {
            guard case .action(.instagramAccount)? = AgentChatIntent.match(prompt) else { return XCTFail(prompt) }
        }
        for prompt in ["Hvordan poster man på Instagram?", "Du skal ikke poste på Instagram",
                       "Lav en opskrift på instagramvenlige kager"] {
            XCTAssertNil(AgentChatIntent.match(prompt), prompt)
        }
        XCTAssertEqual(AgentInstagramIntent.draft(from: "Lav et opslag på Instagram med teksten Godmorgen, Århus!").caption,
                       "Godmorgen, Århus!")
        XCTAssertEqual(AgentInstagramIntent.draft(from: "Lav et Instagram-opslag om en tur i skoven").subject,
                       "en tur i skoven")
        XCTAssertNil(AgentInstagramIntent.mediaURL("http://example.org/opslag.jpg"))
        XCTAssertNil(AgentInstagramIntent.mediaURL("https://pc.local/opslag.jpg"))
        XCTAssertNotNil(AgentInstagramIntent.mediaURL("https://example.org/opslag.jpg"))
    }

    @MainActor func testInstagramRecoveredPublicationDoesNotRequireMediaID() throws {
        let data = Data(#"{"published":true,"mediaID":null,"state":"published"}"#.utf8)
        XCTAssertTrue(try JSONDecoder().decode(AgentInstagramPost.Receipt.self, from: data).confirmed)
        let pending = Data(#"{"published":false,"state":"publishing"}"#.utf8)
        XCTAssertFalse(try JSONDecoder().decode(AgentInstagramPost.Receipt.self, from: pending).confirmed)
    }

    @MainActor func testInstagramPhotoCropAndDraftCleanup() throws {
        XCTAssertEqual(AgentInstagramPhoto.cropRect(CGSize(width: 100, height: 200)),
                       CGRect(x: 0, y: 37, width: 100, height: 125))
        XCTAssertEqual(AgentInstagramPhoto.cropRect(CGSize(width: 300, height: 100)),
                       CGRect(x: 54, y: 0, width: 191, height: 100))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let storage = MigratedAppData(defaults: defaults, store: LocalModelStore(root: folder))
        let oldTurn = try JSONDecoder().decode(AgentChatAction.self, from: Data(#"{"kind":{"today":{}}}"#.utf8))
        XCTAssertNil(oldTurn.instagramDraft)
        var turn = PrivateChatTurn(prompt: "Lav et Instagram-opslag", reply: "")
        turn.agentAction = AgentChatAction(kind: .instagramPost, instagramDraft: .init(hasPhoto: true))
        let bytes = Data([1, 2, 3])
        try storage.saveInstagramPhoto(bytes, id: turn.id)
        try storage.saveRegularStudioTurns([turn])
        XCTAssertEqual(try storage.instagramPhoto(turn.id), bytes)
        try storage.saveRegularStudioTurns([])
        XCTAssertNil(try storage.instagramPhoto(turn.id))
    }

    @MainActor func testAgentAddressAndSignupUseTheAgentsOwnMail() {
        for prompt in ["Opret din egen e-mail", "Kan du lave en mailadresse til dig selv?"] {
            guard case .action(.agentEmail(.address))? = AgentChatIntent.match(prompt) else {
                return XCTFail(prompt)
            }
        }
        guard case .action(.agentEmail(.mailbox))? = AgentChatIntent.match("Opret din egen postkasse") else {
            return XCTFail("Agenten skal kunne oprette en selvstændig postkasse")
        }
        guard case .action(.agentEmail(.signup))? = AgentChatIntent.match("Tilmeld dig på https://eksempel.dk/nyt") else {
            return XCTFail("Tilmelding skal åbne agentens formular")
        }
        for prompt in ["Opret din egen postkasse", "Kan du lave en selvstændig postkasse?", "Create your own mailbox"] {
            guard case .action(.agentEmail(.mailbox))? = AgentChatIntent.match(prompt) else {
                return XCTFail(prompt)
            }
        }
        guard case .action(.agentEmail(.inbox))? = AgentChatIntent.match("Tjek din egen indbakke") else {
            return XCTFail("Agentens post skal kunne læses i chatten")
        }
        for prompt in ["Tjek min mail", "Du skal ikke tilmelde dig", "Hvordan opretter jeg en konto?"] {
            XCTAssertNil(AgentEmailRequest.match(AgentChatIntent.normalize(prompt)))
        }
        XCTAssertEqual(AgentSignupPage.siteURL("eksempel.dk/nyt")?.absoluteString, "https://eksempel.dk/nyt")
        XCTAssertNil(AgentSignupPage.siteURL("http://eksempel.dk"))
        XCTAssertNil(AgentSignupPage.siteURL("https://eva@eksempel.dk"))
        XCTAssertNil(AgentSignupPage.link(in: "Tilmeld dig på https://a.dk eller https://b.dk"))
    }

    @MainActor func testNaturalTodayOverviewRequestsAndUnrelatedQuestions() {
        let requests = ["Kan du give mig et overblik over min dag?", "Hvad skal jeg huske i dag?",
                        "Hvilke planer har jeg i dag?", "Har jeg noget jeg skal i dag?",
                        "Hvad har jeg på programmet i dag?", "Lav en dagsplan"]
        for text in requests {
            guard case .action(.today)? = AgentChatIntent.match(text) else {
                XCTFail("Dagens overblik blev ikke åbnet: \(text)")
                continue
            }
        }
        for text in ["Hvordan får jeg et overblik over min dag?", "Hvad sker der i verden i dag?",
                     "Hvad skal jeg huske i morgen?", "Hvad er klokken i dag?"] {
            XCTAssertNil(AgentChatIntent.match(text), text)
        }
    }

    func testGmailRequestsDistinguishLatestFromUnreadListAndGuides() {
        XCTAssertTrue(AgentGmailCheck.matchesLatest("Kan du se min seneste e-mail?"))
        XCTAssertFalse(AgentGmailCheck.isUnreadList("Kan du se min seneste e-mail?"))
        XCTAssertTrue(AgentGmailCheck.matchesLatest("Har jeg nye mails?"))
        XCTAssertTrue(AgentGmailCheck.isUnreadList("Vis mine ulæste e-mails"))
        XCTAssertFalse(AgentGmailCheck.matchesLatest("Hvordan kan jeg se min seneste mail?"))
        XCTAssertFalse(AgentGmailCheck.matchesLatest("Hvad er klokken?"))
    }
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
        guard case .action(.gmailReply)? = AgentChatIntent.match("Kan du svare tandlægen at fredag passer?") else {
            return XCTFail("A polite request should open Gmail review")
        }
        XCTAssertFalse(AgentGmailReply.matches("Svar tandlægen at   "))
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

    func testNemotronTasksOnlyOfferFreeModelIdentifiers() throws {
        let models = ["nvidia/nemotron-3-ultra-550b-a55b:free", "nvidia/nemotron-3.5-lightning:free"]
        let rows: [[String: Any]] = models.map { ["id": $0, "pricing": ["prompt": "0", "completion": "0"]] }
        XCTAssertEqual(OpenRouterCloud.freeChoices(in: ["data": rows]), models)
        for model in models {
            XCTAssertNoThrow(try OpenRouterCloud.body(model: model, messages: []))
            XCTAssertThrowsError(try OpenRouterCloud.body(model: String(model.dropLast(5)), messages: []))
        }
    }

}
