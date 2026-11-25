import Foundation

struct AgentTaskJourney: Codable, Equatable, Identifiable {
    var id = UUID()
    let botID: UUID
    var goal = "Få styr på en returvare"
    var messageID: String?
    var subject = ""
    var orderText = ""
    var policyURL = ""
    var policyText = ""
    var replyBody = ""
    var mailRequestID = UUID()
    var mailReceipt: String?
    var reminderReceipt: String?
    var skipsReminder = false
    var updated = Date.now
    var readyForChat: Bool { mailReceipt != nil && (reminderReceipt != nil || skipsReminder) }
    mutating func acceptMail(_ text: String) -> Bool {
        guard let url = URL(string: text), url.scheme == "https", url.host == "mail.google.com",
              url.user == nil, url.password == nil else { return false }
        mailReceipt = text; updated = .now; return true
    }
    var summary: String {
        guard readyForChat else { return "Sagen kræver stadig din gennemgang." }
        return "Returforespørgslen om ‘\(subject)’ er sendt via Gmail. "
            + (reminderReceipt.map { "Påmindelse: " + $0 } ?? "Du valgte ingen påmindelse.")
            + " Butikkens svar og selve returforsendelsen mangler stadig."
    }
    static func matches(_ text: String) -> Bool {
        text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines).range(of:
            #"^(?:(?:kan|vil) du (?:lige )?)?(?:få styr på|tag dig af|hjælp mig med|åbn) (?:den her |denne |en |min )?(?:returvare|retursag|returnering)\b"#,
            options: .regularExpression) != nil
    }
    struct Store {
        let botID: UUID
        var root: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FadedAI/TaskJourneys", isDirectory: true)
        private var file: URL { root.appendingPathComponent(botID.uuidString.lowercased() + ".json") }
        func load() throws -> AgentTaskJourney? {
            guard FileManager.default.fileExists(atPath: file.path) else { return nil }
            let data = try Data(contentsOf: file)
            guard data.count < 200_000 else { throw CocoaError(.fileReadCorruptFile) }
            let value = try JSONDecoder().decode(AgentTaskJourney.self, from: data)
            guard value.botID == botID else { throw CocoaError(.fileReadCorruptFile) }
            return value
        }
        func save(_ value: AgentTaskJourney) throws {
            guard value.botID == botID, value.orderText.count <= 20_000, value.policyText.count <= 20_000,
                  value.replyBody.count <= 12_000 else { throw CocoaError(.fileWriteInvalidFileName) }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try JSONEncoder().encode(value).write(to: file, options: .atomic)
        }
        func remove() throws { if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) } }
    }
}
