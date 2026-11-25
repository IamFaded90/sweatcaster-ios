import XCTest
@testable import SweatCaster

final class CapturedInsightTests: XCTestCase {
    func testEveryProposalMustQuoteTheActualInput() throws {
        let source = "Jeg ringer til Lars i morgen. Vi valgte den blå sofa."
        let reply = #"{"items":[{"kind":"decision","text":"Den blå sofa blev valgt","quote":"Vi valgte den blå sofa."}]}"#
        XCTAssertEqual(try CapturedInsight.decode(reply, source: source).first?.kind, .decision)
        XCTAssertThrowsError(try CapturedInsight.decode(reply, source: "Vi valgte den røde sofa."))
    }
    func testRejectsInventedKindsAndDeduplicatesIdenticalEvidence() throws {
        let row = #"{"kind":"fact","text":"Lars bor i Aarhus","quote":"Lars bor i Aarhus"}"#
        XCTAssertEqual(try CapturedInsight.decode("{\"items\":[" + row + "," + row + "]}", source: "Lars bor i Aarhus").count, 1)
        XCTAssertThrowsError(try CapturedInsight.decode(#"{"items":[{"kind":"send","text":"send","quote":"Lars"}]}"#, source: "Lars"))
    }
    func testDistinctActionsSharingOneQuoteAreBothKept() throws {
        let source = "Ring til Lars og send regningen."
        let reply = #"{"items":[{"kind":"reminder","text":"Ring til Lars","quote":"Ring til Lars og send regningen."},{"kind":"reminder","text":"Send regningen","quote":"Ring til Lars og send regningen."},{"kind":"reminder","text":"Ring til Lars","quote":"Ring til Lars og send regningen."}]}"#
        let items = try CapturedInsight.decode(reply, source: source)
        XCTAssertEqual(items.map(\.text), ["Ring til Lars", "Send regningen"])
        XCTAssertEqual(items.map(\.quote), [source, source])
    }
    func testReviewedProposalCannotChangeItsSourceQuoteOrExceedLimits() {
        let proposal = CapturedInsight.Proposal(kind: .note, text: String(repeating: "a", count: 241), quote: "Actual quote")
        XCTAssertThrowsError(try proposal.validate(source: "Actual quote"))
        XCTAssertThrowsError(try CapturedInsight.decode(String(repeating: "a", count: 16_001), source: "Actual quote"))
    }
    func testSaveRetriesKeepOneEntryAndDeletionIsScoped() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CapturedInsight.Store(botID: UUID(), root: root), other = CapturedInsight.Store(botID: UUID(), root: root)
        let proposal = CapturedInsight.Proposal(kind: .note, text: "Ring Lars", quote: "Ring til Lars")
        try store.save(proposal, sourceText: "Ring til Lars", sourceTitle: "Din optagelse", receipt: nil)
        try store.save(proposal, sourceText: "Ring til Lars", sourceTitle: "Din optagelse", receipt: "Gemt")
        try other.save(proposal, sourceText: "Ring til Lars", sourceTitle: "Din tekst", receipt: nil)
        XCTAssertEqual(try store.load().count, 1); XCTAssertEqual(try store.load().first?.receipt, "Gemt")
        try store.remove(proposal.id); XCTAssertTrue(try store.load().isEmpty); XCTAssertEqual(try other.load().count, 1)
    }
    func testCompletedActionCanArchiveAfterFullStoreAndReopenWithoutRepeatingAction() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let bot = UUID(), store = CapturedInsight.Store(botID: bot, root: root)
        let pending = CapturedInsight.Proposal(kind: .reminder, text: "Ring Lars", quote: "Ring til Lars")
        for index in 0..<120 {
            let entry = CapturedInsight.Proposal(kind: .note, text: "Note \(index)", quote: "Kilde \(index)")
            try store.save(entry, sourceText: entry.quote, sourceTitle: "Test", receipt: nil)
        }
        try store.prepare(pending, sourceText: pending.quote, sourceTitle: "Optagelse")
        try store.recordReceipt("Påmindelsen er oprettet", for: pending.id)
        XCTAssertThrowsError(try store.archivePending(pending.id))

        let reopened = CapturedInsight.Store(botID: bot, root: root)
        XCTAssertEqual(try reopened.loadPending().first?.receipt, "Påmindelsen er oprettet")
        XCTAssertTrue(try CapturedInsight.Store(botID: UUID(), root: root).loadPending().isEmpty)
        XCTAssertEqual(try reopened.load().count, 120)
        try reopened.remove(try XCTUnwrap(reopened.load().last).id)
        try reopened.archivePending(pending.id)
        XCTAssertTrue(try reopened.loadPending().isEmpty)
        let archived = try XCTUnwrap(reopened.load().first(where: { $0.id == pending.id }))
        XCTAssertEqual(archived.receipt, "Påmindelsen er oprettet")
        XCTAssertEqual(archived.proposal.quote, pending.quote)
    }
    func testUnconfirmedPendingActionCannotBeReplayedByArchiveRetry() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let bot = UUID(), store = CapturedInsight.Store(botID: bot, root: root)
        let proposal = CapturedInsight.Proposal(kind: .calendar, text: "Møde", quote: "Vi holder møde")
        try store.prepare(proposal, sourceText: proposal.quote, sourceTitle: "Test")
        let reopened = CapturedInsight.Store(botID: bot, root: root)
        XCTAssertThrowsError(try reopened.archivePending(proposal.id))
        XCTAssertTrue(try reopened.load().isEmpty)
        XCTAssertNil(try reopened.loadPending().first?.receipt)
        try reopened.removePending(proposal.id)
        XCTAssertTrue(try reopened.loadPending().isEmpty)
    }
    func testInterruptedArchiveCanFinishWithoutDuplicateOrActionReplay() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let bot = UUID(), store = CapturedInsight.Store(botID: bot, root: root)
        let proposal = CapturedInsight.Proposal(kind: .note, text: "Gem note", quote: "En vigtig note")
        try store.prepare(proposal, sourceText: proposal.quote, sourceTitle: "Tekst")
        try store.recordReceipt("Gemt", for: proposal.id)
        // Simulate a crash after the source was written but before journal removal.
        try store.save(proposal, sourceText: proposal.quote, sourceTitle: "Tekst", receipt: "Gemt")
        let reopened = CapturedInsight.Store(botID: bot, root: root)
        try reopened.archivePending(proposal.id)
        XCTAssertEqual(try reopened.load().filter { $0.id == proposal.id }.count, 1)
        XCTAssertTrue(try reopened.loadPending().isEmpty)
    }
    func testUnconfirmedSourceCanBeMarkedHonestlyWithoutCreatingAnAction() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let bot = UUID(), store = CapturedInsight.Store(botID: bot, root: root)
        let proposal = CapturedInsight.Proposal(kind: .reminder, text: "Ring", quote: "Ring i morgen")
        try store.prepare(proposal, sourceText: proposal.quote, sourceTitle: "Tekst")
        let reopened = CapturedInsight.Store(botID: bot, root: root)
        try reopened.recordReceipt("Ubekræftet – kontrollér selv", for: proposal.id)
        try reopened.archivePending(proposal.id)
        XCTAssertEqual(try reopened.load().first?.receipt, "Ubekræftet – kontrollér selv")
        XCTAssertTrue(try reopened.loadPending().isEmpty)
    }
}
