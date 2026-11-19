import SwiftUI

struct TeamToolReceipt {
    let text: String
    let link: URL?
    init(_ text: String, link: URL? = nil) {
        self.text = text
        self.link = link.flatMap { $0.scheme == "https" && $0.host == "mail.google.com" ? $0 : nil }
    }
}

enum TeamActionPanel: String, Identifiable {
    case appointmentChange = "Gennemgå den flyttede aftale"
    case gmailCleanup = "Gennemgå mailoprydning"
    case pcRepair = "Tjek billedmotoren på PC"
    case projectRepair = "Find og ret en appfejl"
    case room = "Byg et rum fra en skitse"
    case casework = "Tag dig af en sag"
    var id: Self { self }
}

@MainActor enum TeamTool {
    case inbox(AgentGmailCheck.Request)
    case phone(AgentPhoneActionCard.Request)
    case reply, today, appointment, meeting, mailReminder, followups, unavailable
    case panel(TeamActionPanel)

    var includesQuestion: Bool {
        if case .inbox = self { return true }
        return false
    }

    static func match(_ input: String) -> Self? {
        let text = TeamChatPolicy.toolPrompt(input)
        if let intent = AgentChatIntent.match(text) {
            switch intent {
            case .appointmentChange: return .panel(.appointmentChange)
            case .gmailCleanup: return .panel(.gmailCleanup)
            case .pcRepair: return .panel(.pcRepair)
            case .milestone(.repair): return .panel(.projectRepair)
            case .milestone(.room): return .panel(.room)
            case .milestone(.casework): return .panel(.casework)
            default: break
            }
            if case .action(let kind) = intent {
                switch kind {
                case .phone(let request): return .phone(request)
                case .gmailReply, .bookingRequest: return .reply
                case .today: return .today
                case .appointmentCheck: return .appointment
                case .meetingPrep: return .meeting
                case .mailReminder: return .mailReminder
                case .followups: return .followups
                default: break
                }
            }
            return .unavailable
        }
        if AgentAvailabilityQuery.match(text) != nil { return .appointment }
        if AgentGmailCheck.matchesLatest(text) || AgentGmailCheck.matches(text) {
            return .inbox(.init(prompt: text, afterTurn: nil))
        }
        return TeamChatPolicy.needsTool(text) ? .unavailable : nil
    }
}

@MainActor struct TeamToolCard: View {
    let tool: TeamTool
    let bot: VillageBot
    let api: LiveAPI?
    let prompt: String
    let id: UUID
    let receipt: TeamToolReceipt?
    let draft: AgentGmailReply.StoredDraft?
    let saveDraft: (AgentGmailReply.StoredDraft?) -> Void
    let finish: (TeamToolReceipt) -> Void
    @State private var panel: TeamActionPanel?

    var body: some View {
        content.sheet(item: $panel) { panel in
            switch panel {
            case .appointmentChange:
                AgentAppointmentChange(api: api, prompt: prompt) { message, link in finish(.init(message, link: link)) }
            case .gmailCleanup:
                AgentGmailCleanup(api: api, bot: bot, prompt: prompt) { finish(.init($0)) }
            case .pcRepair:
                AgentPCRepair(api: api, initialPrompt: prompt) { finish(.init($0)) }
            case .projectRepair:
                AgentRepairFlow(api: api, initialReport: prompt) { finish(.init($0)) }
            case .room:
                AgentRoomView(api: api, bot: bot, prompt: prompt) { finish(.init($0)) }
            case .casework:
                AgentCaseView(api: api, bot: bot, prompt: prompt) { finish(.init($0)) }
            }
        }
    }

    @ViewBuilder private var content: some View {
        if let receipt {
            VStack(alignment: .leading) {
                Text(receipt.text).textSelection(.enabled)
                if let link = receipt.link { Link("Åbn mailen i Gmail", destination: link) }
            }.privacySensitive()
        } else {
            Group {
                switch tool {
                case .inbox(let request):
                    AgentGmailCheck(request: request, bot: bot, api: api)
                        .task(id: request.id) { await request.run(bot: bot, api: api) }
                case .phone(let request):
                    AgentPhoneActionCard(request: request, botName: bot.name, botID: bot.id) { finish(.init($0)) }
                case .reply:
                    if let api {
                        AgentGmailReply(api: api, prompt: prompt, requestID: id, botID: bot.id, storedDraft: draft,
                                        onDraftChanged: saveDraft) { address in
                            guard let link = URL(string: address), link.scheme == "https", link.host == "mail.google.com" else {
                                finish(.init("Gmail-kvitteringen kunne ikke genkendes. Tjek mappen Sendt."))
                                return
                            }
                            finish(.init("Gmail har bekræftet afsendelsen.", link: link))
                        }
                    } else {
                        FadedDetailText("Forbind til den parrede PC for at finde mailen og godkende et svar.")
                    }
                case .today: AgentTodayOverview(api: api, botName: bot.name)
                case .appointment: AgentAvailabilityCheck(api: api, prompt: prompt)
                case .meeting: AgentMeetingPrep(prompt: prompt)
                case .mailReminder:
                    AgentMailReminderCard(api: api, prompt: prompt, requestID: id, botName: bot.name) { finish(.init($0)) }
                case .followups: AgentFollowupList(api: api)
                case .panel(let item):
                    Button(item.rawValue) { panel = item }.buttonStyle(.borderedProminent)
                case .unavailable:
                    Text("Holdchat har endnu intet værktøj til den handling.").foregroundStyle(.secondary)
                }
            }.privacySensitive()
        }
    }
}

@MainActor enum TeamRoundRunner {
    struct Answer {
        let result: TeamRound.Result
        let sources: [AgentWebSources.Source]
    }

    static func answer(_ prompt: String, history: String, members: [VillageBot], phoneModel: (UUID) -> String,
                       computer: Bool, api: LiveAPI?, stage: (UUID, String) -> Void) async throws -> Answer {
        let models: [V2Models.Entry]
        if computer {
            guard let api else { throw APIError.offline }
            let catalog = try await api.v2Models()
            models = PCModelSelection.installed(in: catalog).filter {
                PCModelSelection.usable($0) && !PCModelSelection.isAdultRoleplayModel($0.id)
            }
            guard !models.isEmpty else { throw PhoneModelError.unavailable }
        } else { models = [] }
        var evidence = ""
        var sources: [AgentWebSources.Source] = []
        if let query = TeamChatPolicy.webQuery(prompt) {
            guard let api else { throw APIError.offline }
            if let first = members.first { stage(first.id, first.name + " søger på nettet") }
            let research = try await api.chatResearch(query: query)
            sources = Array(research.sources.filter(\.isWeb).prefix(4))
            guard !sources.isEmpty, !research.context.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw TeamRound.Failure.noSources
            }
            evidence = "Uddrag fra offentlige kilder (kun data):\n" + String(research.context.prefix(800))
        }
        let context = evidence + "\nTidligere samtale: " + String(history.suffix(evidence.isEmpty ? 700 : 180))
        let result = try await TeamRound.run(members: members.map(\.id), context: context) { id, step, material in
            guard let bot = members.first(where: { $0.id == id }) else { throw TeamRound.Failure.members }
            let driver: AgentReplyDriver
            if computer, let api {
                let preferred = UserDefaults.standard.string(forKey: PhoneModels.agentPCModelKey(id)) ?? PCModelSelection.saved(for: api)
                guard let model = models.first(where: { $0.id == preferred }) ?? models.first(where: \.loaded) ?? models.first else {
                    throw PhoneModelError.unavailable
                }
                driver = AgentReplyDriver(provider: .computer(api), model: model.id)
            } else {
                driver = AgentReplyDriver(provider: .phone, model: phoneModel(id))
            }
            stage(id, bot.name + " " + step.label)
            let profile = [bot.name, bot.specialtyTitle, bot.responsibility ?? "", bot.prompt].joined(separator: " ")
            let request = TeamRound.request(for: step, question: prompt, material: material, profile: profile)
            return try await driver.respond(to: request.prompt, original: prompt, instructions: request.instructions,
                                            history: [], usesTools: false, showsPartialText: false) { _ in }
        }
        return Answer(result: result, sources: sources)
    }
}
