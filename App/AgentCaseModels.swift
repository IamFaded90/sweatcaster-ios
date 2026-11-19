import Foundation

enum AgentCaseIntent {
    static func matches(_ value: String) -> Bool {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard text.range(of: #"\b(?:ikke|aldrig)\s+(?:klag|reklam|få)"#, options: .regularExpression) == nil else { return false }
        return text.range(of: #"^(?:(?:(?:kan|vil) du (?:lige )?)|(?:jeg vil (?:gerne )?)|(?:hjælp mig med at ))?(?:få det ordnet|lav(?:e)? en (?:reklamation|klagesag)|reklam[eé]r(?:e)?|klag(?:e)? (?:til|over)|vis mine sager|åbn (?:mine )?sager)\b"#,
                          options: .regularExpression) != nil
    }
}

struct AgentCaseCreationAttempt {
    private(set) var id = UUID()
    private var submittedFields: [String]?

    mutating func requestID(for fields: [String]) -> UUID {
        let normalized = fields.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let submittedFields, submittedFields != normalized { id = UUID() }
        submittedFields = normalized
        return id
    }

    mutating func confirmed() {
        id = UUID()
        submittedFields = nil
    }
}

struct AgentCaseRecord: Decodable, Identifiable {
    struct Photo: Decodable, Identifiable {
        let id: UUID
        let name, sha256: String
        let bytes: Int
    }
    struct Candidate: Decodable, Identifiable {
        let id: String
        let subject, sender: String
        let timestamp: String?
    }
    struct Receipt: Decodable {
        let id, subject, sender, text, suggestedRecipient: String
        let threadID: String?
    }
    struct Draft: Decodable {
        let sender, recipient, subject, body, digest: String
        let photos: [Photo]
    }
    struct Outgoing: Decodable {
        let id: UUID
        let sender, recipient, subject, body, rfcID, digest: String
        let photos: [Photo]
        let approvedAt: Double
        let verified: Bool
        let messageID, threadID: String?
        let verifiedAt: Double?
    }
    struct Incoming: Decodable, Identifiable {
        let id, subject, sender, text: String
        let created: Double
    }
    struct Event: Decodable, Identifiable {
        let id: UUID
        let kind, text: String
        let created: Double
    }

    let id, botID: UUID
    let revision: Int
    let title, merchant, problem, desired, reference, state, note, gmailEmail: String
    let created, updated: Double
    let photos: [Photo]
    let events: [Event]
    let receipt: Receipt?
    let candidates: [Candidate]
    let draft: Draft?
    let outgoing: Outgoing?
    let incoming: [Incoming]
    let watch: Bool
    let lastChecked: Double?

    var editable: Bool { outgoing == nil && state != "closed" }
    var stateTitle: String {
        switch state {
        case "draft": "Vi samler dokumentationen"
        case "sending": "Afsendelsen skal kontrolleres"
        case "uncertain": "Tjek status · intet gensendes"
        case "waiting": "Sendt · venter på svar"
        case "reply": "Der er svar i sagen"
        case "closed": "Afsluttet af dig"
        default: "Sagen er gemt"
        }
    }
    var gmailURL: URL? {
        guard let thread = outgoing?.threadID, outgoing?.verified == true,
              thread.range(of: #"^[0-9a-fA-F]{1,128}$"#, options: .regularExpression) != nil,
              var components = URLComponents(string: "https://mail.google.com/mail/") else { return nil }
        components.queryItems = [.init(name: "authuser", value: gmailEmail)]
        components.fragment = "all/" + thread
        return components.url
    }
}

extension LiveAPI {
    func caseAction<T: Decodable>(_ path: String, body: [String: Any], bot: UUID) async throws -> T {
        try await moduleJSON("agent-cases/" + path, upload: JSONSerialization.data(withJSONObject: body),
                             timeout: 160, query: [.init(name: "bot_id", value: bot.uuidString)])
    }
}
