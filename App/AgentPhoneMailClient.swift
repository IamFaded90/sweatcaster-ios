import Foundation

@MainActor final class AgentPhoneMailClient {
    private let cloud: ComposioCloud
    let accountID: String
    private init(cloud: ComposioCloud, accountID: String) { self.cloud = cloud; self.accountID = accountID }
    static func connect() async throws -> AgentPhoneMailClient {
        let cloud = try await ComposioCloud.client()
        let discovery = try await cloud.discover("Read Gmail messages and reply to an existing Gmail thread.")
        return try AgentPhoneMailClient(cloud: cloud, accountID: AgentPhoneMail.account(discovery))
    }
    private func prepare(_ slug: String) async throws -> [String: Any] {
        let discovery = try await cloud.discover("Use Gmail tool \(slug).")
        guard try AgentPhoneMail.account(discovery) == accountID else { throw AgentPhoneMail.Failure.changed }
        guard let schemas = discovery["tool_schemas"] as? [String: [String: Any]], let schema = schemas[slug],
              let session = discovery["session"] as? [String: Any], let id = session["id"] as? String else { throw AgentPhoneMail.Failure.target }
        if schema["input_schema"] == nil {
            let result = try await cloud.call("COMPOSIO_GET_TOOL_SCHEMAS", ["tool_slugs": [slug], "session_id": id])
            guard let data = result["data"] as? [String: Any], let tools = data["tool_schemas"] as? [String: [String: Any]],
                  tools[slug]?["input_schema"] != nil else { throw AgentPhoneMail.Failure.target }
        }
        return discovery
    }
    func call(_ slug: String, _ arguments: [String: Any]) async throws -> [String: Any] {
        let discovery = try await prepare(slug)
        return try await cloud.execute(slug, arguments: arguments, discovery: discovery)
    }
    func message(_ id: String) async throws -> [String: Any] {
        try await call("GMAIL_FETCH_MESSAGE_BY_MESSAGE_ID", ["user_id": "me", "message_id": id, "format": "full"])
    }
    func verify(_ record: AgentPhoneMail.Record) async throws -> AgentPhoneMail.Record {
        guard record.accountID == accountID, let id = record.sentID else { throw AgentPhoneMail.Failure.uncertain }
        let output = try await message(id)
        guard AgentPhoneMail.verifies(output, record: record) else { throw AgentPhoneMail.Failure.uncertain }
        var result = record; result.state = .sent
        try AgentPhoneMail.Store().save(result)
        return result
    }
    func send(_ record: AgentPhoneMail.Record) async throws -> AgentPhoneMail.Record {
        guard record.state == .review, record.accountID == accountID,
              !record.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, record.body.count <= 12_000 else { throw AgentPhoneMail.Failure.changed }
        if let previous = try AgentPhoneMail.Store().load(record.id), previous.state != .review { throw AgentPhoneMail.Failure.uncertain }
        let current = try await message(record.target.messageID)
        guard try AgentPhoneMail.target(current, messageID: record.target.messageID) == record.target else { throw AgentPhoneMail.Failure.changed }
        let discovery = try await prepare("GMAIL_REPLY_TO_THREAD")
        try Task.checkCancellation()
        var pending = record; pending.state = .sending
        try AgentPhoneMail.Store().save(pending)
        do {
            let output = AgentInternetPayload.object(try await cloud.execute("GMAIL_REPLY_TO_THREAD", arguments: [
                "user_id": "me", "thread_id": record.target.threadID, "recipient_email": record.target.recipient,
                "message_body": record.body, "is_html": false, "include_signature": false,
                "timezone": TimeZone.current.identifier
            ], discovery: discovery))
            guard let id = AgentInternetPayload.identifier(output["id"] ?? output["messageId"]) else { throw AgentPhoneMail.Failure.uncertain }
            pending.sentID = id; pending.state = .uncertain
            try AgentPhoneMail.Store().save(pending)
            return try await verify(pending)
        } catch {
            pending.state = .uncertain
            try AgentPhoneMail.Store().save(pending)
            throw AgentPhoneMail.Failure.uncertain
        }
    }
}
