import Foundation
import XCTest
@testable import SweatCaster

final class AgentPhoneMailTests: XCTestCase {
    private func message(id: String = "abc123", to: String = "person@example.test") -> [String: Any] {
        ["id": id, "threadId": "def456", "labelIds": ["SENT"], "payload": ["headers": [
            ["name": "From", "value": "Test <person@example.test>"], ["name": "To", "value": to],
            ["name": "Subject", "value": "En aftale"]]]]
    }
    func testMailReplyUsesReplyToAndRejectsAmbiguousOrInjectedHeaders() throws {
        var row = message()
        row["payload"] = ["headers": [["name": "Reply-To", "value": "reply@example.test"], ["name": "From", "value": "from@example.test"]]]
        XCTAssertEqual(try AgentPhoneMail.target(row, messageID: "abc123").recipient, "reply@example.test")
        XCTAssertThrowsError(try AgentPhoneMail.target(row, messageID: "wrong"))
        XCTAssertNil(AgentPhoneMail.address("one@example.test, two@example.test"))
        XCTAssertNil(AgentPhoneMail.address("one@example.test, Two <two@example.test>"))
        XCTAssertEqual(AgentPhoneMail.address("\"Andersen, Test\" <one@example.test>"), "one@example.test")
        XCTAssertNil(AgentPhoneMail.address("one@example.test\r\nBcc: two@example.test"))
        row["payload"] = ["headers": [["name": "From", "value": "one@example.test"], ["name": "from", "value": "two@example.test"]]]
        XCTAssertThrowsError(try AgentPhoneMail.target(row, messageID: "abc123"))
    }
    func testSentReceiptRequiresExactMessageThreadRecipientAndSentLabel() throws {
        let target = try AgentPhoneMail.target(message(), messageID: "abc123")
        var record = AgentPhoneMail.Record(id: UUID(), accountID: "account", target: target, body: "Fredag passer.")
        record.sentID = "abc124"
        XCTAssertTrue(AgentPhoneMail.verifies(message(id: "abc124"), record: record))
        XCTAssertFalse(AgentPhoneMail.verifies(message(id: "abc125"), record: record))
        XCTAssertFalse(AgentPhoneMail.verifies(message(id: "abc124", to: "wrong@example.test"), record: record))
        var draft = message(id: "abc124"); draft["labelIds"] = ["DRAFT"]
        XCTAssertFalse(AgentPhoneMail.verifies(draft, record: record))
        var other = message(id: "abc124"); other["threadId"] = "other"
        XCTAssertFalse(AgentPhoneMail.verifies(other, record: record))
    }
    func testUncertainSendSurvivesRestart() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AgentPhoneMail.Store(root: root)
        let target = try AgentPhoneMail.target(message(), messageID: "abc123")
        var record = AgentPhoneMail.Record(id: UUID(), accountID: "account", target: target, body: "Svar")
        record.state = .sending
        try store.save(record)
        XCTAssertEqual(try store.load(record.id)?.state, .sending)
        XCTAssertNil(try store.load(UUID()))
    }
    func testMultipleAccountsCannotBeSilentlyMixed() throws {
        let active: [String: Any] = ["id": "a", "status": "ACTIVE"]
        let single: [String: Any] = ["toolkit_connection_statuses": [["toolkit": "gmail", "has_active_connection": true, "accounts": [active]]]]
        XCTAssertEqual(try AgentPhoneMail.account(single), "a")
        let several: [String: Any] = ["toolkit_connection_statuses": [["toolkit": "gmail", "has_active_connection": true, "accounts": [active, active]]]]
        XCTAssertThrowsError(try AgentPhoneMail.account(several))
    }
}
