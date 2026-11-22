import Foundation
import XCTest
@testable import SweatCaster

final class ChatReplyBlockTests: XCTestCase {
    func testStructuredReplyPreservesDanishTextAndSoftWrapsListItems() {
        let reply = "## Dagens aftaler\r\n\r\n1. **Tandlæge**\r\n   kl. 11\r\n  - Tag kortet med\r\n\r\nGod tur!"
        XCTAssertEqual(ChatReplyBlock.parse(reply), [
            .heading(level: 2, text: "Dagens aftaler"),
            .item(marker: "1.", indent: 0, text: "**Tandlæge**\nkl. 11"),
            .item(marker: "•", indent: 2, text: "Tag kortet med"),
            .text("God tur!")
        ])
    }

    func testStreamingCodeKeepsFirstLineAndEmbeddedFences() {
        let intro = "Skriv ```her``` midt i en linje."
        let partial = intro + "\n````swift\nlet first = 1\n```\n"
        XCTAssertEqual(ChatReplyBlock.parse(partial), [.text(intro), .code("let first = 1\n```\n")])
        let complete = partial + "let next = 2\n````\n\nFærdig"
        XCTAssertEqual(ChatReplyBlock.parse(complete),
                       [.text(intro), .code("let first = 1\n```\nlet next = 2"), .text("Færdig")])
        XCTAssertEqual(ChatReplyBlock.parse("~~~\n**ordret**\n~~~"), [.code("**ordret**")])
    }

    func testPCStreamRendersListsAndCodeAsTheTextArrives() throws {
        let frames = [
            ###"{"type":"text","content":"## Din dag\n- Køb mælk"}"###,
            #"{"type":"text","content":"\n``"}"#,
            #"{"type":"text","content":"`swift\nlet tid = 11"}"#,
            #"{"type":"text","content":"\n```\nGod tur!"}"#,
            #"{"type":"done","content":"","message_id":"test","model_id":"pc-test"}"#
        ]
        var parser = V2ChatParser()
        var reply = ""
        var rendered: [[ChatReplyBlock]] = []
        for frame in frames {
            for byte in "data: \(frame)\r\n\r\n".utf8 {
                if let event = try parser.feed(byte), event.type == .text {
                    reply += event.content
                    rendered.append(ChatReplyBlock.parse(reply))
                }
            }
        }
        try parser.end()
        let first: [ChatReplyBlock] = [.heading(level: 2, text: "Din dag"), .item(marker: "•", indent: 0, text: "Køb mælk")]
        XCTAssertEqual(rendered.count, 4)
        XCTAssertEqual(rendered.first, first)
        XCTAssertEqual(try XCTUnwrap(rendered.dropFirst(2).first), first + [.code("let tid = 11")])
        XCTAssertEqual(rendered.last, first + [.code("let tid = 11"), .text("God tur!")])
    }

    @MainActor func testPrivateMarkupKeepsReadableWordsAndClearsLinkActions() {
        let markdown = "**Læs** [aftalen](https://example.com/test)"
        let publicText = ChatTranscriptView.inlineText(markdown)
        let privateText = ChatTranscriptView.inlineText(markdown, allowsLinks: false)
        XCTAssertEqual(String(publicText.characters), "Læs aftalen")
        XCTAssertEqual(String(privateText.characters), "Læs aftalen")
        XCTAssertTrue(publicText.runs.contains { $0.link != nil })
        XCTAssertTrue(privateText.runs.allSatisfy { $0.link == nil })
    }
}


final class TeamRoundTests: XCTestCase {
    @MainActor func testTwoAgentsProduceOneAnswerAfterIndependentCorrection() async throws {
        let finder = UUID(), writer = UUID()
        var stages: [TeamRound.Stage] = []
        var checks = 0
        let answer = try await TeamRound.run(members: [finder, writer], context: "Mødet starter kl. 14.") { id, stage, data in
            stages.append(stage)
            switch stage {
            case .find: XCTAssertEqual(id, finder); return "Tidspunkt 14."
            case .draft: XCTAssertEqual(id, writer); return "Mødet starter kl. 16."
            case .check:
                XCTAssertEqual(id, finder)
                checks += 1
                if checks == 1 {
                    XCTAssertTrue(data.contains("kl. 16"))
                    return "RET. Tidspunktet i kilden er 14."
                }
                XCTAssertTrue(data.contains("Mødet starter kl. 14"))
                return "OK."
            case .revise:
                XCTAssertEqual(id, writer)
                XCTAssertTrue(data.contains("Tidspunktet i kilden er 14"))
                return "Mødet starter kl. 14."
            }
        }
        XCTAssertTrue(answer.reviewed)
        XCTAssertEqual(answer.text, "Mødet starter kl. 14.")
        XCTAssertEqual(stages, [.find, .draft, .check, .revise, .check])
    }

    @MainActor func testAllSelectedReviewersParticipateWithoutPublishingDuplicateMessages() async throws {
        let agents = (0..<4).map { _ in UUID() }
        var reviewers: [UUID] = []
        let reply = try await TeamRound.run(members: agents, context: "") { id, stage, _ in
            switch stage {
            case .find: return "Bruger ønsker en kort hilsen."
            case .draft: return "Godmorgen, Lydon!"
            case .check: reviewers.append(id); return "OK"
            case .revise: XCTFail("Already approved."); return ""
            }
        }
        XCTAssertEqual(reviewers, Array(agents.dropFirst(2)))
        XCTAssertEqual(reply.text, "Godmorgen, Lydon!")
    }

    @MainActor func testInventedReceiptCannotPassEvenIfReviewerAgrees() async {
        do {
            _ = try await TeamRound.run(members: [UUID(), UUID()], context: "") { _, stage, _ in
                if stage == .check { return "OK" }
                return "Jeg har sendt mailen."
            }
            XCTFail("A generated receipt reached the user.")
        } catch { XCTAssertTrue(error is TeamRound.Failure) }
    }

    @MainActor func testUnresolvedCheckAndCancellationProduceNoFinalAnswer() async {
        do {
            _ = try await TeamRound.run(members: [UUID(), UUID()], context: "") { _, stage, _ in
                stage == .check ? "RET. Der mangler et beløb." : "Det koster 123 kr."
            }
            XCTFail("Unverified answer.")
        } catch { XCTAssertTrue(error is TeamRound.Failure) }
        var calls = 0
        do {
            _ = try await TeamRound.run(members: [UUID(), UUID()], context: "") { _, _, _ in
                calls += 1
                throw CancellationError()
            }
            XCTFail("Cancelled round published an answer.")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(calls, 1)
    }

    func testToolAndResearchRequests() {
        XCTAssertEqual(TeamChatPolicy.toolPrompt("Kan I lige læse min mail?"), "Kan du læse min mail?")
        XCTAssertEqual(TeamChatPolicy.webQuery("Søg på nettet efter dagens program"), "dagens program")
        XCTAssertNil(TeamChatPolicy.webQuery("Jeg bruger nettet på arbejde."))
        XCTAssertTrue(TeamChatPolicy.needsTool("Kan I afmelde mit abonnement?"))
        XCTAssertFalse(TeamChatPolicy.needsTool("Hvordan afmelder jeg et abonnement?"))
        XCTAssertTrue(TeamRound.presentsExecution("Beskeden er nu sendt."))
        XCTAssertTrue(TeamRound.presentsExecution("The email has been sent."))
        XCTAssertTrue(TeamChatPolicy.needsTool("Please delete the folder"))
        XCTAssertFalse(TeamRound.presentsExecution("Du kan sende teksten fredag."))
    }

    @MainActor func testRawToolCallCannotPassEvenWhenReviewerAgrees() async {
        do {
            _ = try await TeamRound.run(members: [UUID(), UUID()], context: "") { _, stage, _ in
                stage == .check ? "OK" : #"{"tool":"calendar","input":"0"}"#
            }
            XCTFail("A raw tool call leaked into the final answer.")
        } catch { XCTAssertTrue(error is TeamRound.Failure) }
    }

    func testReviewerReceivesTaskAndVerdictInstructionWithinTransportLimits() {
        let original = String(repeating: "🍏", count: 1_995) + "SLUT?"
        let request = TeamRound.request(for: .check, question: original, material: "Udkast: 15",
                                        profile: "Eva")
        XCTAssertTrue(request.prompt.contains("SLUT?"))
        XCTAssertTrue(request.prompt.hasSuffix(TeamRound.Stage.check.instruction))
        XCTAssertTrue(request.instructions.contains("Udkast: 15"))
        XCTAssertEqual((request.prompt + request.instructions).filter { $0 == "🍏" }.count, 1_995)
        XCTAssertLessThanOrEqual(request.prompt.unicodeScalars.count, 2_000)
        XCTAssertLessThanOrEqual(request.instructions.unicodeScalars.count, 3_000)
    }

#if canImport(SwiftUI)
    @MainActor func testGroupActionsUseTheActualPanels() {
        guard case .panel(.appointmentChange)? = TeamTool.match("Tandlægen har flyttet min tid — få styr på det.") else {
            return XCTFail("Flyttet aftale")
        }
        guard case .panel(.gmailCleanup)? = TeamTool.match("Ryd op i min e-mail") else { return XCTFail("Oprydning") }
        guard case .panel(.pcRepair)? = TeamTool.match("Fix billedmotoren på min PC") else { return XCTFail("Reparation") }
        guard case .inbox? = TeamTool.match("Kan I se min seneste e-mail?") else { return XCTFail("Indbakke") }
    }
#endif
}
