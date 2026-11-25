import Foundation
import UserNotifications

@MainActor enum CaseTrackerClient {
    static func verifiedLink(_ requestID: UUID) async throws -> CaseTracker.MailLink {
        guard let record = try AgentPhoneMail.Store().load(requestID), record.state == .sent, let sentID = record.sentID else { throw AgentPhoneMail.Failure.uncertain }
        let client = try await AgentPhoneMailClient.connect()
        _ = try await client.verify(record)
        let profile = AgentInternetPayload.object(try await client.call("GMAIL_GET_PROFILE", ["user_id": "me"]))
        guard let email = AgentPhoneMail.address((profile["emailAddress"] ?? profile["email_address"]) as? String ?? "") else { throw AgentPhoneMail.Failure.account }
        return .init(requestID: requestID, accountID: client.accountID, email: email, sentID: sentID,
                     threadID: record.target.threadID, recipient: record.target.recipient)
    }
    static func replies(_ value: CaseTracker) async throws -> [CaseTracker.Reply] {
        guard let mail = value.mail else { return [] }
        let client = try await AgentPhoneMailClient.connect()
        guard client.accountID == mail.accountID else { throw AgentPhoneMail.Failure.changed }
        let anchor = AgentInternetPayload.object(try await client.message(mail.sentID))
        guard let original = try AgentPhoneMail.Store().load(mail.requestID),
              AgentPhoneMail.verifies(anchor, record: original), let sentAt = timestamp(anchor) else { throw AgentPhoneMail.Failure.uncertain }
        let output = AgentInternetPayload.object(try await client.call("GMAIL_FETCH_MESSAGE_BY_THREAD_ID", ["user_id": "me", "thread_id": mail.threadID]))
        let thread = (output["thread"] as? [String: Any]) ?? output
        guard let rows = thread["messages"] as? [[String: Any]], rows.count <= 100,
              AgentInternetPayload.identifier(thread["id"] ?? thread["threadId"]) == mail.threadID else { throw AgentPhoneMail.Failure.target }
        var replies: [CaseTracker.Reply] = []
        let known = Set(value.replies.map(\.id))
        for row in rows {
            try Task.checkCancellation()
            guard let id = AgentInternetPayload.identifier(row["id"] ?? row["messageId"]), id != mail.sentID, !known.contains(id) else { continue }
            let full = AgentInternetPayload.object(try await client.message(id))
            guard AgentInternetPayload.identifier(full["threadId"]) == mail.threadID else { throw AgentPhoneMail.Failure.target }
            let labels = full["labelIds"] as? [String] ?? []
            if labels.contains("SENT") || labels.contains("DRAFT") || labels.contains("TRASH") { continue }
            guard let date = timestamp(full) else { throw AgentPhoneMail.Failure.target }
            guard date > sentAt else { continue }
            let headers = AgentPhoneMail.headers(full)
            guard let sender = AgentPhoneMail.address(headers["from"] ?? full["sender"] as? String ?? ""), sender != mail.email else { continue }
            let body = try AgentInternetPayload.message(full, expectedID: id)
            replies.append(.init(id: id, threadID: mail.threadID, sender: sender,
                subject: String((headers["subject"] ?? full["subject"] as? String ?? "Svar").prefix(350)), text: String(body.text.prefix(6_000)), received: date))
            if replies.count >= 20 { break }
        }
        return replies
    }
    private static func timestamp(_ row: [String: Any]) -> Date? {
        if let raw = (row["internalDate"] as? String).flatMap(Double.init) ?? (row["internalDate"] as? NSNumber)?.doubleValue, raw.isFinite {
            return Date(timeIntervalSince1970: raw / 1_000)
        }
        if let raw = row["messageTimestamp"] as? String {
            if let date = ISO8601DateFormatter().date(from: raw) { return date }
            if let number = Double(raw), number.isFinite { return Date(timeIntervalSince1970: number > 100_000_000_000 ? number / 1_000 : number) }
        }
        return nil
    }
    static func schedule(_ value: CaseTracker, deadline: Date) async throws {
        guard deadline > .now, value.completedAt == nil else { throw CaseTracker.Failure.invalid }
        let center = UNUserNotificationCenter.current()
        guard try await center.requestAuthorization(options: [.alert, .sound]) else { throw CocoaError(.userCancelled) }
        let content = UNMutableNotificationContent()
        content.title = "Følg op · " + value.title
        content.body = "Din valgte frist er nået. Åbn FadedAI for at gennemgå sagen."
        content.sound = .default
        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: deadline)
        try await center.add(.init(identifier: value.notificationID, content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)))
    }
    static func cancelDeadline(_ value: CaseTracker) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [value.notificationID])
    }
    static func syncPC(_ value: CaseTracker, api: LiveAPI) async throws -> (UUID, [CaseTracker.Reply]) {
        guard let mail = value.mail else { throw CaseTracker.Failure.invalid }
        _ = try await api.health()
        var remote: AgentCaseRecord
        do {
            remote = try await api.moduleJSON("agent-cases/" + value.id.uuidString.lowercased(),
                query: [.init(name: "bot_id", value: value.botID.uuidString)])
        } catch APIError.http(404, _) {
            remote = try await api.caseAction(value.id.uuidString.lowercased(), body: [
                "action": "create", "title": value.title, "merchant": String(mail.recipient.prefix(160)),
                "problem": value.goal.isEmpty ? value.title : value.goal, "desired": "Følg op på den valgte Gmail-tråd", "reference": ""
            ], bot: value.botID)
        }
        if remote.outgoing == nil {
            remote = try await api.caseAction(value.id.uuidString.lowercased(), body: [
                "action": "adoptSent", "revision": remote.revision, "messageID": mail.sentID,
                "threadID": mail.threadID, "recipient": mail.recipient, "ownerEmail": mail.email
            ], bot: value.botID)
        }
        guard remote.gmailEmail.lowercased() == mail.email.lowercased(), remote.outgoing?.threadID == mail.threadID else { throw CaseTracker.Failure.account }
        if value.watch && remote.state == "closed" {
            remote = try await api.caseAction(value.id.uuidString.lowercased(), body: ["action": "reopen", "revision": remote.revision], bot: value.botID)
        }
        if remote.watch != value.watch {
            remote = try await api.caseAction(value.id.uuidString.lowercased(), body: ["action": "watch", "enabled": value.watch, "revision": remote.revision], bot: value.botID)
        }
        remote = try await api.caseAction(value.id.uuidString.lowercased(), body: ["action": "refresh"], bot: value.botID)
        guard remote.checkError == nil, remote.lastChecked != nil, remote.state != "uncertain", remote.state != "closed" else {
            throw ComposioCloudError.unavailable(remote.checkError ?? "PC’en kunne ikke bekræfte nye svar i Gmail. Prøv igen.")
        }
        let incoming = remote.incoming.map { CaseTracker.Reply(id: $0.id, threadID: mail.threadID, sender: $0.sender, subject: $0.subject,
                                                              text: $0.text, received: .init(timeIntervalSince1970: $0.created)) }
        return (remote.id, incoming)
    }
    static func flush(_ store: CaseTracker.Store, api: LiveAPI) async throws {
        for change in try store.pending() {
            do {
                let path = "agent-cases/" + change.id.uuidString.lowercased()
                let record: AgentCaseRecord = try await api.moduleJSON(path, query: [.init(name: "bot_id", value: change.botID.uuidString)])
                if change.kind == .close && record.state == "closed" { try store.acknowledge(change.id); continue }
                var body: [String: Any] = ["action": change.kind.rawValue, "revision": record.revision]
                switch change.kind {
                case .close: body["approved"] = true; body["reason"] = change.reason
                case .remove: body["approved"] = true
                case .watch: body["enabled"] = change.enabled
                case .reopen: if record.state != "closed" { try store.acknowledge(change.id); continue }
                }
                if change.kind == .remove {
                    struct Removed: Decodable { let removed: Bool }
                    let _: Removed = try await api.caseAction(change.id.uuidString.lowercased(), body: body, bot: change.botID)
                } else {
                    let _: AgentCaseRecord = try await api.caseAction(change.id.uuidString.lowercased(), body: body, bot: change.botID)
                }
                try store.acknowledge(change.id)
            } catch APIError.http(404, _) { try store.acknowledge(change.id) }
        }
    }
}
