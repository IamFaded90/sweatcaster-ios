import Foundation

enum AgentGmailCleanupIntent {
    static func matches(_ value: String) -> Bool {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let action = #"\b(?:ryd(?:de)?\s+op|oprydning|arkiv[eé]r(?:e)?|arkivering|slet(?:te)?|clean\s+up|archive|delete|fjern(?:e)?)\b"#
        let mail = #"\b(?:gmail|mails?|e-?mails?|indbakke(?:n)?|nyhedsbreve?|reklamemails?|inbox|newsletters?)\b"#
        let negative = #"\b(?:(?:ikke|aldrig|don't|do not)\s+(?:ryd|arkiv|slet|fjern|delete|archive|clean)|(?:slet|fjern|arkiv[eé]r)\s+ikke)"#
        return text.range(of: action, options: .regularExpression) != nil &&
            text.range(of: mail, options: .regularExpression) != nil &&
            text.range(of: negative, options: .regularExpression) == nil
    }
}

struct AgentGmailCleanupJob: Decodable, Identifiable {
    struct Message: Decodable, Identifiable {
        let id, subject, sender, state, note: String
        let labels, reasons: [String]

        var protected: Bool { state == "protected" }
        var stateTitle: String {
            switch state {
            case "ready": "Klar til at vælge"
            case "protected": "Bevares"
            case "applied": "Kontrolleret hos Gmail"
            case "restored": "Tilbage i indbakken"
            case "skipped": "Sprunget over"
            case "uncertain": "Status skal kontrolleres"
            default: "Skal prøves igen"
            }
        }
    }

    let id, botID: UUID
    let revision: Int
    let mode, query, state, receipt: String
    let created: Double
    let messages: [Message]
    let selected: [String]
    let hasMore: Bool
    let counts: [String: Int]
    let undoRequested: Bool?

    var verifiedCount: Int { counts[undoRequested == true ? "restored" : "applied", default: 0] }
    var canUndo: Bool {
        !selected.isEmpty && state != "restored" && messages.contains {
            ["applied", "uncertain", "failed"].contains($0.state)
        }
    }
    var needsAttention: Bool { state == "partial" }
    var title: String {
        switch state {
        case "preview": "Se listen før du godkender"
        case "complete": "Oprydningen er kontrolleret"
        case "restored": "Mails er tilbage i indbakken"
        default: "Nogle mails mangler at blive kontrolleret"
        }
    }
}
