import Foundation

enum AgentPhoneMail {
    struct Target: Codable, Equatable {
        let messageID, threadID, recipient, subject: String
    }
    struct Record: Codable {
        enum State: String, Codable { case review, sending, uncertain, sent }
        let id: UUID
        let accountID: String
        let target: Target
        var body: String
        var state: State = .review
        var sentID: String?
    }
    static func account(_ discovery: [String: Any]) throws -> String {
        let rows = discovery["toolkit_connection_statuses"] as? [[String: Any]] ?? []
        let row = rows.first { ($0["toolkit"] as? String)?.lowercased() == "gmail" }
        let accounts = (row?["accounts"] as? [[String: Any]] ?? []).filter { ($0["status"] as? String) == "ACTIVE" }
        guard row?["has_active_connection"] as? Bool == true, accounts.count == 1,
              let id = accounts[0]["id"] as? String, !id.isEmpty else { throw Failure.account }
        return id
    }
    enum Failure: LocalizedError {
        case account, target, changed, uncertain
        var errorDescription: String? {
            switch self {
            case .account: "Forbind én Gmail-konto i Composio på iPhone. Ved flere konti skal den ønskede vælges i Composio først."
            case .target: "Mailens modtager eller samtale kunne ikke bekræftes. Åbn mailen i Gmail."
            case .changed: "Konto eller modtager har ændret sig. Vælg mailen igen før afsendelse."
            case .uncertain: "Gmail kan have sendt svaret. Kontrollér Sendt, før du gør mere. Appen sender ikke igen automatisk."
            }
        }
    }
    static func address(_ raw: String) -> String? {
        guard !raw.contains("\n"), !raw.contains("\r"), raw.count <= 320 else { return nil }
        var text = raw.trimmingCharacters(in: .whitespaces)
        if let start = text.lastIndex(of: "<"), text.hasSuffix(">") {
            let displayName = text[..<start]
            guard !displayName.contains("@"), !displayName.contains("<"), !displayName.contains(">") else { return nil }
            text = String(text[text.index(after: start)..<text.index(before: text.endIndex)])
        }
        guard text.range(of: #"^[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?\.[A-Za-z]{2,63}$"#, options: .regularExpression) != nil else { return nil }
        return text.lowercased()
    }
    static func headers(_ row: [String: Any]) -> [String: String] {
        let payload = row["payload"] as? [String: Any] ?? [:]
        var result: [String: String] = [:]
        for field in (payload["headers"] as? [[String: Any]] ?? []).prefix(100) {
            if let name = field["name"] as? String, let value = field["value"] as? String {
                let key = name.lowercased()
                // Duplicate address headers are ambiguous; never silently pick the last one.
                result[key] = result[key] == nil ? value : "\n"
            }
        }
        return result
    }
    static func target(_ output: [String: Any], messageID: String) throws -> Target {
        let row = AgentInternetPayload.object(output)
        let headers = headers(row)
        guard AgentInternetPayload.identifier(row["messageId"] ?? row["id"]) == messageID,
              let thread = AgentInternetPayload.identifier(row["threadId"]),
              let recipient = address(headers["reply-to"] ?? headers["from"] ?? (row["sender"] as? String ?? "")),
              !(row["labelIds"] as? [String] ?? []).contains("DRAFT") else { throw Failure.target }
        return Target(messageID: messageID, threadID: thread, recipient: recipient,
            subject: String((headers["subject"] ?? row["subject"] as? String ?? "Uden emne").prefix(350)))
    }
    static func verifies(_ output: [String: Any], record: Record) -> Bool {
        let row = AgentInternetPayload.object(output), fields = headers(row)
        return record.sentID != nil && AgentInternetPayload.identifier(row["id"] ?? row["messageId"]) == record.sentID
            && AgentInternetPayload.identifier(row["threadId"]) == record.target.threadID
            && (row["labelIds"] as? [String] ?? []).contains("SENT")
            && address(fields["to"] ?? "") == record.target.recipient
            && (fields["cc"] ?? "").trimmingCharacters(in: .whitespaces).isEmpty
            && (fields["bcc"] ?? "").trimmingCharacters(in: .whitespaces).isEmpty
    }
    struct Store {
        var root = AgentWorkspace.root.appendingPathComponent("MailReceipts", isDirectory: true)
        func load(_ id: UUID) throws -> Record? {
            let url = root.appendingPathComponent(id.uuidString + ".json")
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return try JSONDecoder().decode(Record.self, from: Data(contentsOf: url))
        }
        func save(_ record: Record) throws {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try JSONEncoder().encode(record).write(to: root.appendingPathComponent(record.id.uuidString + ".json"), options: .atomic)
        }
    }
}
