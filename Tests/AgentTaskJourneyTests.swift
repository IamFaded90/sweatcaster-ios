import XCTest
@testable import SweatCaster

final class AgentTaskJourneyTests: XCTestCase {
    func testDraftAndReminderAloneCannotFinishTask() {
        var value = AgentTaskJourney(botID: UUID()); value.replyBody = "Et forslag"; value.reminderReceipt = "Gemt"
        XCTAssertFalse(value.readyForChat)
        XCTAssertFalse(value.acceptMail("https://mail.google.com.evil.example/receipt"))
        XCTAssertTrue(value.acceptMail("https://mail.google.com/mail/u/0/#all/thread"))
        XCTAssertTrue(value.readyForChat)
        XCTAssertTrue(value.summary.contains("mangler stadig"))
    }
    func testJourneyAndStableMailIdentitySurviveRelaunch() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let bot = UUID(); let store = AgentTaskJourney.Store(botID: bot, root: root)
        var value = AgentTaskJourney(botID: bot); value.messageID = "message"; value.replyBody = "Kladde"
        try store.save(value); XCTAssertEqual(try store.load(), value)
        XCTAssertEqual(try store.load()?.mailRequestID, value.mailRequestID)
        XCTAssertNil(try AgentTaskJourney.Store(botID: UUID(), root: root).load())
    }
}
