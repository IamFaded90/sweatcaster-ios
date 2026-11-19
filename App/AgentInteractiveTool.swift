import Foundation
import SwiftUI

enum AgentInteractiveTool: Identifiable {
    case window(String)
    case phoneScreen(String)
    case sales(String)
    case surprise(String)
    case builtTools(String)
    case appointmentChange(String)
    case gmailCleanup(String)
    case pcRepair(String)
    case agentComputer(String)
    case milestone(AgentMilestone, String)
    case taste(VillageBot, AgentTasteKind)

    var id: String {
        switch self {
        case .window: return "window"
        case .phoneScreen: return "phone-screen"
        case .sales: return "sales"
        case .surprise: return "surprise"
        case .builtTools: return "built-tools"
        case .appointmentChange: return "appointment-change"
        case .gmailCleanup: return "gmail-cleanup"
        case .pcRepair: return "pc-repair"
        case .agentComputer: return "agent-computer"
        case .milestone(let kind, _): return kind.rawValue
        case .taste(let bot, _): return bot.id.uuidString
        }
    }
}

struct AgentTasteRequest {
    let kind: AgentTasteKind
    var recipient: String?

    private static let command = try? NSRegularExpression(pattern:
        #"^(?:(?:kan|vil) du (?:lige )?)?(?:find(?:e)?|vælg(?:e)?|sammenlign(?:e)?|prøv(?:e)?|test(?:e)?|hjælp mig med at vælge) (?:lige )?(?:(?:en|et|to|ny|nye|anden|andre|dansk|danske|bedre) )*(stemmer?|billedstil(?:e)?|landsbyfigur(?:er)?)(?: (?:til|for) (.{1,60}))?$"#)

    static func parse(_ message: String) -> Self? {
        let text = AgentChatIntent.normalize(message)
        guard let match = command?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let noun = Range(match.range(at: 1), in: text) else { return nil }
        let recipient = Range(match.range(at: 2), in: text).map { String(text[$0]) }
        if let recipient, ["min ", "mit ", "mine ", "en ", "et "].contains(where: recipient.hasPrefix) { return nil }
        let kind: AgentTasteKind
        if text[noun].hasPrefix("stemme") { kind = .voice }
        else if text[noun].hasPrefix("billedstil") { kind = .imageStyle }
        else { kind = .figure }
        return Self(kind: kind, recipient: recipient)
    }

    func target(in bots: [VillageBot], current: VillageBot) -> VillageBot? {
        guard let recipient else { return current }
        if ["dig", "dig selv", "denne agent", "den her agent"].contains(recipient) { return current }
        let candidates = [current] + bots.filter { $0.id != current.id }
        let matches = candidates.filter {
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines)
                .compare(recipient, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
        return matches.count == 1 ? matches.first : nil
    }
}

extension AgentPhoneChat {
    @ViewBuilder var tasteChoices: some View {
        Button("Stemme") { startTasteTest(.voice) }
        Button("Billedstil") { startTasteTest(.imageStyle) }
        Button("Landsbyfigur") { startTasteTest(.figure) }
    }

    func startTasteTest(_ kind: AgentTasteKind) {
        startAgentAction(.taste(.init(kind: kind)), prompt: "")
    }

    func presentTasteTest(_ request: AgentTasteRequest) {
        let bots = (try? MigratedAppData.shared.loadBots().get()) ?? []
        if let target = request.target(in: bots, current: bot) {
            interactiveTool = .taste(target, request.kind)
        } else {
            notice = "Jeg kunne ikke finde én agent med det navn. Åbn chatten med den agent, du mener, og vælg ‘Prøv to og vælg’."
        }
    }
}
