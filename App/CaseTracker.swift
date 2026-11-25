import Foundation

struct CaseTracker: Codable, Equatable, Identifiable {
    struct MailLink: Codable, Equatable {
        let requestID: UUID
        let accountID, email, sentID, threadID, recipient: String
    }
    struct Reply: Codable, Equatable, Identifiable {
        let id, threadID, sender, subject, text: String
        let received: Date
    }
    var id = UUID()
    let botID: UUID
    var title = "Min sag"
    var goal = ""
    var notes = ""
    var created = Date.now
    var updated = Date.now
    var deadline: Date?
    var notificationScheduled = false
    var initialMailRequestID = UUID()
    var nextReplyRequestID = UUID()
    var mail: MailLink?
    var replies: [Reply] = []
    var lastChecked: Date?
    var checkError: String?
    var remoteCaseID: UUID?
    var remoteSyncAttempted = false
    var lastRespondedReplyID: String?
    var completedAt: Date?
    var completionNote = ""
    var watch = true
    var stateTitle: String {
        if completedAt != nil { return "Afsluttet af dig" }
        if checkError != nil { return "Kontrollen skal prøves igen" }
        if let last = replies.last, last.id != lastRespondedReplyID { return "Der er svar · vælg næste skridt" }
        return mail == nil ? "Gennemgå første handling" : "Sendt · venter på svar"
    }
    func nextStep(at now: Date = .now) -> String {
        if completedAt != nil { return "Afslutning: " + completionNote }
        if let deadline, deadline <= now { return "Din valgte frist er nået. Gennemgå sagen og vælg, om der skal følges op." }
        if let last = replies.last, last.id != lastRespondedReplyID { return "Læs svaret, og vælg om agenten skal forberede et svar. Der sendes ikke automatisk." }
        return mail == nil ? "Vælg Gmail-tråden og gennemgå den første mail." : "Afventer svar i den tilknyttede Gmail-tråd."
    }
    mutating func attach(_ link: MailLink) throws {
        guard completedAt == nil, !link.accountID.isEmpty, !link.email.isEmpty,
              !link.sentID.isEmpty, !link.threadID.isEmpty else { throw Failure.invalid }
        if let mail, mail.accountID != link.accountID || mail.threadID != link.threadID { throw Failure.account }
        if mail != nil { lastRespondedReplyID = replies.last?.id }
        mail = link; checkError = nil; updated = .now
    }
    mutating func receive(_ values: [Reply], account: String, checked: Date = .now) throws {
        guard let mail, mail.accountID == account else { throw Failure.account }
        guard completedAt == nil else { return }
        guard values.allSatisfy({ $0.threadID == mail.threadID && !$0.id.isEmpty && $0.text.count <= 6_000 }) else { throw Failure.invalid }
        var merged = Dictionary(replies.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for reply in values { merged[reply.id] = reply }
        replies = Array(merged.values.sorted { $0.received == $1.received ? $0.id < $1.id : $0.received < $1.received }.suffix(30))
        lastChecked = checked; checkError = nil; updated = checked
        // A reply, including "refunded", is evidence to review, never automatic completion.
    }
    mutating func complete(note: String, at date: Date = .now) throws {
        let clean = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= 1_000 else { throw Failure.invalid }
        completionNote = clean; completedAt = date; watch = false; notificationScheduled = false; updated = date
    }
    mutating func reopen() { completedAt = nil; completionNote = ""; watch = true; updated = .now }
    var notificationID: String { "fadedai.case." + id.uuidString.lowercased() }
    var gmailURL: URL? {
        guard let mail, mail.threadID.range(of: #"^[0-9a-fA-F]{1,128}$"#, options: .regularExpression) != nil,
              var components = URLComponents(string: "https://mail.google.com/mail/") else { return nil }
        components.queryItems = [.init(name: "authuser", value: mail.email)]
        components.fragment = "all/" + mail.threadID
        return components.url
    }
    enum Failure: Error { case invalid, account }
    static func command(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).range(of:
            #"^(?:(?:kan|vil) du (?:lige )?)?(?:følg (?:denne |den her |min |en )?sag|hold styr på (?:denne |min |en )?sag|vis mine sager|åbn mine sager|tag sagen til dørs)\b"#,
            options: [.regularExpression, .caseInsensitive]) != nil
    }
    func validate() throws {
        guard !title.isEmpty, title.count <= 160, goal.count <= 3_000, notes.count <= 8_000,
              completionNote.count <= 1_000, replies.count <= 30, (checkError?.count ?? 0) <= 1_000,
              Set(replies.map(\.id)).count == replies.count,
              replies.allSatisfy({ $0.id.count <= 128 && $0.text.count <= 6_000 && $0.subject.count <= 350 && $0.sender.count <= 320 && $0.threadID == mail?.threadID && $0.received.timeIntervalSince1970.isFinite }) else { throw Failure.invalid }
        if let mail, mail.accountID.count > 200 || mail.threadID.count > 128 || mail.sentID.count > 128 || mail.email.count > 320 || mail.recipient.count > 320 { throw Failure.invalid }
        if let deadline, !deadline.timeIntervalSince1970.isFinite { throw Failure.invalid }
    }
    struct Store {
        struct RemoteChange: Codable, Identifiable {
            enum Kind: String, Codable { case close, remove, watch, reopen }
            let id, botID: UUID
            let kind: Kind
            let reason: String
            let enabled: Bool
        }
        let botID: UUID
        var root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FadedAI/CaseTrackers", isDirectory: true)
        var directory: URL { root.appendingPathComponent(botID.uuidString.lowercased(), isDirectory: true) }
        func list() throws -> [CaseTracker] {
            guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
            return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" }.prefix(100).map { url in
                    guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? .max) <= 1_000_000 else { throw Failure.invalid }
                    let value = try JSONDecoder().decode(CaseTracker.self, from: Data(contentsOf: url))
                    guard value.botID == botID else { throw Failure.account }; try value.validate(); return value
                }.sorted { $0.updated > $1.updated }
        }
        func save(_ value: CaseTracker) throws {
            guard value.botID == botID else { throw Failure.account }; try value.validate()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(value)
            guard data.count <= 1_000_000 else { throw Failure.invalid }
            try data.write(to: directory.appendingPathComponent(value.id.uuidString.lowercased() + ".json"), options: [.atomic, .completeFileProtection])
        }
        func remove(_ id: UUID) throws {
            let path = directory.appendingPathComponent(id.uuidString.lowercased() + ".json")
            if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
        }
        func queue(_ value: CaseTracker, kind: RemoteChange.Kind) throws {
            guard value.botID == botID else { throw Failure.account }
            guard value.remoteCaseID != nil || value.remoteSyncAttempted else { return }
            let folder = directory.appendingPathComponent("outbox", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let change = RemoteChange(id: value.remoteCaseID ?? value.id, botID: botID, kind: kind,
                                      reason: value.completionNote, enabled: value.watch)
            try JSONEncoder().encode(change).write(to: folder.appendingPathComponent(change.id.uuidString + ".json"), options: [.atomic, .completeFileProtection])
        }
        func pending() throws -> [RemoteChange] {
            let folder = directory.appendingPathComponent("outbox", isDirectory: true)
            guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
            return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).prefix(100).map {
                let data = try Data(contentsOf: $0)
                guard data.count <= 5_000 else { throw Failure.invalid }
                let change = try JSONDecoder().decode(RemoteChange.self, from: data)
                guard change.botID == botID else { throw Failure.account }; return change
            }
        }
        func acknowledge(_ id: UUID) throws {
            let path = directory.appendingPathComponent("outbox", isDirectory: true).appendingPathComponent(id.uuidString + ".json")
            if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
        }
    }
}
