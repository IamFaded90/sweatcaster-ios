import SwiftUI

enum AgentMilestone: String, CaseIterable, Identifiable {
    case repair = "repair-project"
    case room = "create-village-room"
    case casework = "manage-case"

    var id: Self { self }

    var title: String {
        switch self {
        case .repair: "Find og ret en appfejl"
        case .room: "Byg et rum fra en skitse"
        case .casework: "Tag dig af en sag"
        }
    }

    var icon: String {
        switch self {
        case .repair: "ladybug"
        case .room: "square.on.square.dashed"
        case .casework: "tray.full"
        }
    }

    static func match(_ input: String) -> Self? {
        let text = AgentChatIntent.normalize(input)
        guard text.range(of: #"^(?:(?:(?:kan|vil|skal|må) du|du (?:må|skal))\s+)?(?:ikke|lad være(?: med at)?)\b"#,
                         options: .regularExpression) == nil else { return nil }
        if let command = allCases.first(where: { AgentChatIntent.normalize($0.title) == text }) { return command }
        if AgentRoomIntent.matches(input) { return .room }
        if AgentCaseIntent.matches(input) { return .casework }
        let target = #"\b(?:fadedai|appen|ios|iphone-app\w*|swift|xcode|projekt\w*|appfejl|\.ips|build\w*)\b"#
        let request = #"\b(?:ret\w*|fix\w*|repar\w*|fejlsøg\w*|find\w*.{0,13}fejl|lukk\w*.{0,30}(?:model|hent)|byg\w*.{0,15}fejl)\b"#
        if text.range(of: target, options: .regularExpression) != nil &&
            text.range(of: request, options: .regularExpression) != nil { return .repair }
        return nil
    }
}

extension AgentPhoneChat {
    @ViewBuilder func milestoneSheet(_ milestone: AgentMilestone, prompt: String) -> some View {
        switch milestone {
        case .repair:
            AgentRepairFlow(api: api, initialReport: prompt == milestone.title ? "" : prompt) { receipt in
                addAgentAction(prompt, kind: .workflow("Appfejl og test"), receipt: receipt, source: "PC")
            }
        case .room:
            AgentRoomView(api: api, bot: bot, prompt: prompt == milestone.title ? "" : prompt) { receipt in
                addAgentAction(prompt, kind: .workflow("Nyt landsbyrum"), receipt: receipt, source: "PC")
            }
        case .casework:
            AgentCaseView(api: api, bot: bot, prompt: prompt == milestone.title ? "" : prompt) { receipt in
                addAgentAction(prompt, kind: .workflow("Sagsforløb"), receipt: receipt, source: "PC")
            }
        }
    }
}

@MainActor struct AgentRoomShortcut: View {
    let bots: [VillageLifeBot]
    let openProfile: (VillageLifeBot) -> Void
    @Environment(\.villagePlannerAPI) private var api

    var body: some View {
        NavigationLink {
            AgentRoomPublishedView(api: api) { id in
                if let bot = bots.first(where: { UUID(uuidString: $0.id) == id }) { openProfile(bot) }
            }
        } label: {
            Label("Mine agentrum", systemImage: "square.on.square.dashed")
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .padding(.horizontal, 12)
                .fadedGlassSurface()
        }
        .buttonStyle(.plain)
    }
}
