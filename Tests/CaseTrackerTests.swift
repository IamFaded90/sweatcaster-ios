import XCTest
@testable import SweatCaster

final class CaseTrackerTests: XCTestCase {
    private func linked() throws -> CaseTracker {
        var record = CaseTracker(botID: UUID()); record.title = "Returnér skærmen"
        try record.attach(.init(requestID: UUID(), accountID: "owner", email: "owner@example.com", sentID: "ab01", threadID: "cd01", recipient: "shop@example.com"))
        return record
    }
    private func reply(_ id: String = "ef01", thread: String = "cd01", text: String = "Vi har tilbagebetalt beløbet.", at: TimeInterval = 10) -> CaseTracker.Reply {
        .init(id: id, threadID: thread, sender: "shop@example.com", subject: "Svar", text: text, received: Date(timeIntervalSince1970: at))
    }
    func testReplyIsDeduplicatedButNeverCompletesCase() throws {
        var record = try linked()
        try record.receive([reply(), reply()], account: "owner")
        XCTAssertEqual(record.replies.count, 1)
        XCTAssertNil(record.completedAt)
        XCTAssertTrue(record.stateTitle.contains("Der er svar"))
        try record.complete(note: "Pengene er kommet ind på min konto.")
        XCTAssertNotNil(record.completedAt); XCTAssertFalse(record.watch)
    }
    func testWrongAccountOrThreadCannotAdvanceCheckedTimestamp() throws {
        var record = try linked()
        XCTAssertThrowsError(try record.receive([reply()], account: "other"))
        XCTAssertThrowsError(try record.receive([reply(thread: "other")], account: "owner"))
        XCTAssertNil(record.lastChecked); XCTAssertTrue(record.replies.isEmpty)
        XCTAssertThrowsError(try record.attach(.init(requestID: UUID(), accountID: "owner", email: "owner@example.com", sentID: "ab02", threadID: "different", recipient: "shop@example.com")))
    }
    func testSentFollowupClearsNewReplyStateUntilAnotherReplyArrives() throws {
        var record = try linked(); try record.receive([reply()], account: "owner")
        XCTAssertEqual(URLComponents(url: try XCTUnwrap(record.gmailURL), resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "owner@example.com")
        XCTAssertEqual(record.gmailURL?.fragment, "all/cd01")
        try record.attach(.init(requestID: UUID(), accountID: "owner", email: "owner@example.com", sentID: "ab02", threadID: "cd01", recipient: "shop@example.com"))
        XCTAssertTrue(record.stateTitle.contains("venter på svar"))
        try record.receive([reply("ef02", at: 20)], account: "owner")
        XCTAssertTrue(record.stateTitle.contains("Der er svar"))
    }
    func testDeadlineDoesNotInventResolutionAndClosingNeedsReason() throws {
        var record = try linked(); record.deadline = Date(timeIntervalSince1970: 100)
        XCTAssertTrue(record.nextStep(at: Date(timeIntervalSince1970: 101)).contains("fristen er nået") || record.nextStep(at: Date(timeIntervalSince1970: 101)).contains("frist er nået"))
        XCTAssertNil(record.completedAt)
        XCTAssertThrowsError(try record.complete(note: " "))
        try record.complete(note: "Ordnet af mig"); record.reopen()
        XCTAssertNil(record.completedAt); XCTAssertTrue(record.watch)
    }
    func testMultipleCasesPersistAndDeletedCaseKeepsPCStopInOutbox() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var first = try linked(); first.remoteSyncAttempted = true
        let store = CaseTracker.Store(botID: first.botID, root: root)
        var second = CaseTracker(botID: first.botID); second.title = "Anden sag"
        try store.save(first); try store.save(second)
        try store.queue(first, kind: .remove); try store.remove(first.id)
        XCTAssertEqual(try store.list().map(\.id), [second.id])
        XCTAssertEqual(try store.pending().first?.id, first.id)
        XCTAssertEqual(try store.pending().first?.kind, .remove)
        try store.acknowledge(first.id); XCTAssertTrue(try store.pending().isEmpty)
    }
    func testUnicodeReplyHistoryCanReopenAndOtherAgentCannotWriteIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var record = try linked()
        try record.receive((0..<30).map { reply("reply-\($0)", text: String(repeating: "🙂", count: 6_000), at: Double($0)) }, account: "owner")
        let store = CaseTracker.Store(botID: record.botID, root: root)
        try store.save(record); XCTAssertEqual(try store.list().first, record)
        XCTAssertThrowsError(try CaseTracker.Store(botID: UUID(), root: root).save(record))
    }
}
