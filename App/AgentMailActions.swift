import SwiftUI

extension AgentChatAction.Kind {
    var isMailReply: Bool {
        switch self { case .gmailReply, .bookingRequest: true; default: false }
    }
}

extension AgentPhoneChat {
    @ViewBuilder func gmailReplyCard(_ turn: PrivateChatTurn, action: AgentChatAction) -> some View {
        if action.mailDraft == nil && (AgentInternetTools.phoneAvailable || (try? AgentPhoneMail.Store().load(turn.id)) != nil) {
            AgentPhoneMailReply(prompt: turn.prompt, requestID: turn.id, botID: bot.id, botName: bot.name) {
                acceptMailReceipt($0, turn: turn, action: action)
            }
        } else if let api {
            AgentGmailReply(api: api, prompt: turn.prompt, requestID: turn.id, botID: bot.id, storedDraft: action.mailDraft,
                           onDraftChanged: { updateAgentDraft(turn.id, draft: $0) }) {
                acceptMailReceipt($0, turn: turn, action: action)
            }.id(api.queueTargetID)
        } else {
            FadedDetailText("Forbind Composio på iPhone for at svare via Gmail uden PC.")
            ComposioCloudSetup(api: api)
            if let draft = action.mailDraft { Text(draft.body).textSelection(.enabled) }
        }
    }
    private func acceptMailReceipt(_ address: String, turn: PrivateChatTurn, action: AgentChatAction) {
        guard let link = URL(string: address), link.scheme == "https", link.host == "mail.google.com" else {
            notice = "Gmail-kvitteringen kunne ikke verificeres. Tjek Sendt før du prøver igen."
            return
        }
        let receipt: String
        if case .bookingRequest = action.kind { receipt = "Forespørgslen er sendt via Gmail. En tid er først aftalt, når modtageren bekræfter den." }
        else { receipt = "Svar sendt via Gmail." }
        finishAgentAction(turn.id, receipt: receipt, link: link)
    }
}

/// Existing EventKit review and read-back verification, available directly below a chat result.
@MainActor struct AgentResultActions: View {
    let text: String
    let contextID: UUID
    let botName: String
    @State private var action: BotPhoneActionKind?
    @State private var receipt: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button("Kalender", systemImage: "calendar.badge.plus") { action = .calendar }
                Button("Påmindelse", systemImage: "bell.badge") { action = .reminder }
            }.buttonStyle(.bordered).frame(minHeight: 44)
            if let receipt { Text(receipt).font(.caption).foregroundStyle(.secondary) }
        }
        .sheet(isPresented: Binding(get: { action != nil }, set: { if !$0 { action = nil } })) {
            if let action {
                let proposed = BotPhoneAction(kind: action, title: String(text.split(whereSeparator: \.isNewline).first.map(String.init)?.prefix(120) ?? "Opfølgning"),
                                             localDate: nil, needsDate: action == .calendar)
                BotPhoneActionReview(action: proposed, jobID: identity(action), botName: botName,
                    reminderNotes: String(text.prefix(4_000)), onSaved: { receipt = $0 }, onApplied: {})
            }
        }
    }
    private func identity(_ kind: BotPhoneActionKind) -> UUID {
        var bytes = contextID.uuid
        bytes.15 ^= kind == .calendar ? 0xCA : 0xAD
        return UUID(uuid: bytes)
    }
}
