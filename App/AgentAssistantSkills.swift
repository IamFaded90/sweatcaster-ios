import EventKit
import SwiftUI

struct AgentAvailabilityQuery: Sendable {
    let topic: String

    static func match(_ input: String) -> Self? {
        let pattern = #"^(?:kan jeg nå|har jeg tid til|kan jeg komme til)\s+(.+?)(?=\s+(?:på\s+)?(?:mandag|tirsdag|onsdag|torsdag|fredag|lørdag|søndag|i dag|i morgen|i overmorgen|næste uge|\d{1,2}/\d{1,2}|20\d\d-\d\d-\d\d)\b|[?.!]*$)"#
        guard let match = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let capture = match.firstMatch(in: input, range: NSRange(input.startIndex..., in: input)),
              let range = Range(capture.range(at: 1), in: input) else { return nil }
        let topic = input[range].trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        let dateSpecified = input[range.upperBound...].contains { $0.isLetter || $0.isNumber }
        let appointmentTerms = ["tandlæge", "læge", "værksted", "aftale", "møde", "kalender", "samtale"]
        let lower = topic.lowercased()
        guard (3...120).contains(topic.count), !lower.hasPrefix("at "),
              dateSpecified || appointmentTerms.contains(where: { lower.contains($0) }) else { return nil }
        return .init(topic: topic)
    }

    var terms: [String] {
        let fillers = ["mit", "min", "den", "det", "med", "til", "hos", "aftale", "aftalen", "møde", "mødet"]
        return Array(topic.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init).filter { $0.count >= 3 && !fillers.contains($0) }.prefix(4)).map {
                switch $0 {
                case "tandlægen": "tandlæge"
                case "lægen": "læge"
                case "værkstedet": "værksted"
                default: $0
                }
            }
    }

    func matchesTitle(_ title: String) -> Bool {
        let title = title.localizedLowercase
        return !terms.isEmpty && terms.allSatisfy { title.contains($0) }
    }
}

/// The calendar and inbox checks are independent and only the final card combines their results.
@MainActor struct AgentAvailabilityCheck: View {
    private struct Event: Identifiable, Sendable {
        let id: String
        let title: String
        let start: Date
        let end: Date
        let blocksTime: Bool
        let location: String?
        let allDay: Bool
    }

    let api: LiveAPI?
    let prompt: String
    @State private var store = EKEventStore()
    @State private var events: [Event] = []
    @State private var messages: [BotMailMessages.Message] = []
    @State private var calendarIssue: String?
    @State private var mailIssue: String?
    @State private var selectedID: String?
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !loaded { ProgressView("Tjekker Kalender og Gmail…") }
            else if let query = AgentAvailabilityQuery.match(prompt) {
                let candidates = events.filter { query.matchesTitle($0.title) }
                if let calendarIssue { Text(calendarIssue).foregroundStyle(.secondary) }
                else if candidates.isEmpty { Text("Jeg fandt ingen aftale i Kalender, der matcher ‘\(query.topic)’.") }
                else if candidates.count == 1, let candidate = candidates.first { result(candidate) }
                else if let candidate = candidates.first(where: { $0.id == selectedID }) { result(candidate) }
                else {
                    Text("Hvilken aftale mener du?").font(.headline)
                    ForEach(candidates.prefix(6)) { candidate in
                        Button { selectedID = candidate.id } label: {
                            Label("\(candidate.title) · \(candidate.start.formatted(date: .abbreviated, time: candidate.allDay ? .omitted : .shortened))",
                                  systemImage: "calendar")
                        }
                        .frame(minHeight: 44)
                    }
                }
                if let mailIssue { Text(mailIssue).font(.subheadline).foregroundStyle(.secondary) }
                else if messages.isEmpty { Text("Ingen matchende mails fundet.").font(.subheadline).foregroundStyle(.secondary) }
                else {
                    Text("Fundet i Gmail").font(.caption.weight(.semibold))
                    ForEach(messages.prefix(3)) { message in
                        if let link = Self.mailLink(message) { Link(message.subject.isEmpty ? "Uden emne" : message.subject, destination: link).frame(minHeight: 44) }
                    }
                }
            }
        }
        .task { if !loaded { await load() } }
        .privacySensitive()
    }

    private func result(_ event: Event) -> some View {
        let conflicts = events.filter { $0.id != event.id && $0.blocksTime && $0.start < event.end && $0.end > event.start }
        return VStack(alignment: .leading, spacing: 5) {
            Text(event.title).font(.headline)
            Text(event.start.formatted(date: .abbreviated, time: event.allDay ? .omitted : .shortened))
            if let location = event.location, !location.isEmpty { Label(location, systemImage: "mappin") }
            if event.allDay { Text("Aftalen er markeret som heldag. Tjek mailen for et klokkeslæt.") }
            else if conflicts.isEmpty { Label("Ingen samtidige aftaler i Kalender", systemImage: "checkmark.circle") }
            else {
                Label("Samtidig i Kalender", systemImage: "exclamationmark.circle")
                ForEach(conflicts.prefix(4)) { Text($0.title) }
            }
        }
    }

    private func load() async {
        guard let query = AgentAvailabilityQuery.match(prompt) else { return }
        async let calendarResult = calendarEvents()
        async let mailResult = gmailMessages(query)
        let (calendar, mail) = await (calendarResult, mailResult)
        guard !Task.isCancelled else { return }
        (events, calendarIssue) = calendar
        (messages, mailIssue) = mail
        loaded = true
    }

    private func calendarEvents() async -> ([Event], String?) {
        do {
            guard try await store.requestFullAccessToEvents() else { return ([], "Giv FadedAI adgang til Kalender i Indstillinger.") }
            let calendar = AgentCalendarAvailability.clock
            let now = Date()
            let day = AgentPhoneLanguage.day(in: prompt, now: now, calendar: calendar)
            let start = day ?? calendar.startOfDay(for: now)
            guard let end = calendar.date(byAdding: .day, value: day == nil ? 14 : 1, to: start) else { return ([], "Tidsrummet kunne ikke læses.") }
            let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
            let matches = store.events(matching: predicate).compactMap { event -> Event? in
                guard let id = event.eventIdentifier, let start = event.startDate, let end = event.endDate,
                      event.status != .canceled else { return nil }
                return Event(id: id + "-" + String(start.timeIntervalSince1970), title: event.title ?? "Aftale",
                             start: start, end: end, blocksTime: event.availability != .free, location: event.location,
                             allDay: event.isAllDay)
            }
            return (matches.sorted { $0.start < $1.start }, nil)
        } catch { return ([], "Kalenderen kunne ikke læses.") }
    }

    private func gmailMessages(_ query: AgentAvailabilityQuery) async -> ([BotMailMessages.Message], String?) {
        guard let api else { return ([], "Forbind PC’en for at se kildemails.") }
        guard !query.terms.isEmpty else { return ([], "Nævn personens, stedets eller aftalens navn for at finde en mail.") }
        let search = "newer_than:180d " + query.terms.map { "\"\($0)\"" }.joined(separator: " ")
        do {
            let result: BotMailMessages = try await api.moduleJSON("composio/gmail/messages", timeout: 45,
                                                                    query: [.init(name: "q", value: String(search.prefix(160)))])
            var seen = Set<String>()
            return (result.messages.filter { seen.insert($0.threadID ?? $0.id).inserted }, nil)
        } catch { return ([], "Gmail kunne ikke læses lige nu.") }
    }

    private static func mailLink(_ item: BotMailMessages.Message) -> URL? {
        let id = item.threadID ?? item.id
        guard id.range(of: #"^[A-Za-z0-9_-]{1,128}$"#, options: .regularExpression) != nil else { return nil }
        return URL(string: "https://mail.google.com/mail/#all/\(id)")
    }
}

@MainActor struct AgentFollowupList: View {
    private struct Status: Decodable {
        let state: String

        var title: String {
            switch state {
            case "waiting": "Venter på svar"
            case "received": "Der er kommet svar"
            default: "Status kunne ikke bekræftes"
            }
        }
    }

    let api: LiveAPI?
    @State private var statuses: [UUID: Status] = [:]
    @State private var loading = false
    @State private var refresh = UUID()

    var body: some View {
        var seen = Set<URL>()
        let recent = Array(MigratedAppData.shared.regularStudioTurns().reversed().filter {
            guard let action = $0.agentAction else { return false }
            guard let link = action.receiptLink else { return false }
            return seen.insert(link).inserted
        }.prefix(5))
        return VStack(alignment: .leading, spacing: 8) {
            if recent.isEmpty { Text("Du har endnu ingen sendte mails fra agentchatten at følge op på.") }
            else if api == nil { Text("Forbind PC’en for at tjekke dine Gmail-tråde.") }
            else {
                Text("Dine seneste sendte tråde fra agentchatten").font(.headline)
                ForEach(recent) { turn in
                    if let link = turn.agentAction?.receiptLink {
                        Link(turn.prompt, destination: link).frame(minHeight: 44)
                        if let status = statuses[turn.id] { Text(status.title).foregroundStyle(.secondary) }
                    }
                }
                if loading { ProgressView("Tjekker for svar…") }
                else { Button("Tjek igen", systemImage: "arrow.clockwise") { refresh = UUID() }.frame(minHeight: 44) }
            }
        }
        .task(id: (api?.queueTargetID ?? "") + refresh.uuidString) {
            if let api, !recent.isEmpty { await check(recent.map(\.id), api: api) }
        }
        .privacySensitive()
    }

    private func check(_ ids: [UUID], api: LiveAPI) async {
        loading = true
        statuses = [:]
        defer { loading = false }
        for id in ids {
            guard !Task.isCancelled else { return }
            let result: Status? = try? await api.moduleJSON("composio/gmail/reply/followup/\(id.uuidString)", timeout: 35)
            guard !Task.isCancelled else { return }
            statuses[id] = result ?? Status(state: "unknown")
        }
    }
}

@MainActor struct AgentAssistantHome: View {
    private enum TaskSection: String, CaseIterable, Identifiable {
        case pending = "Afventer", followup = "Følg op", done = "Udført"
        var id: Self { self }

        var icon: String {
            switch self {
            case .pending: "clock"
            case .followup: "envelope.badge"
            case .done: "checkmark.circle"
            }
        }
    }

    private struct ChatRoute: Identifiable {
        let id = UUID()
        let bot: VillageBot
        let taskID: UUID?
    }

    let api: LiveAPI?
    @State private var bots: [VillageBot] = []
    @State private var tasks: [PrivateChatTurn] = []
    @State private var section = TaskSection.pending
    @State private var route: ChatRoute?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FadedSpacing.m) {
                startCard
                AssistantCaptureStrip()
                AgentSharedInboxButton(api: api)
                Picker("Opgaver", selection: $section) {
                    ForEach(TaskSection.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                let visible = tasks.filter { taskSection($0) == section }
                if visible.isEmpty {
                    ContentUnavailableView("Ingen opgaver her endnu", systemImage: section.icon,
                                           description: Text("Opgaver fra agentchatten vises her."))
                } else {
                    ForEach(visible) { task in taskRow(task) }
                }
            }
            .padding(FadedSpacing.edge)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .background { FadedBackground() }
        .navigationTitle("Assistent")
        .navigationBarTitleDisplayMode(.inline)
        .task { reload() }
        .refreshable { reload() }
        .sheet(item: $route, onDismiss: reload) { destination in
            AgentPhoneChat(bot: destination.bot, api: api, opensAction: destination.taskID)
        }
        .privacySensitive()
    }


    private var startCard: some View {
        FadedCard {
            VStack(alignment: .leading, spacing: 8) {
                if let preferred = bots.first(where: { $0.name.caseInsensitiveCompare("Adam") == .orderedSame }) ?? bots.first {
                    FadedPrimaryButton("Giv en opgave", icon: "bubble.left.and.bubble.right") {
                        route = ChatRoute(bot: preferred, taskID: nil)
                    }
                    if bots.count > 1 {
                        Menu("Vælg en agent", systemImage: "person.2") {
                            ForEach(bots) { bot in
                                Button(bot.name) { route = ChatRoute(bot: bot, taskID: nil) }
                            }
                        }
                        .frame(minHeight: 44)
                    }
                } else {
                    FadedDetailText("Åbn Landsbyen for at oprette en agent.")
                }
            }
        }
    }

    private func taskRow(_ task: PrivateChatTurn) -> some View {
        let owner = bots.first { $0.id == task.botID }
        return Button {
            if let owner { route = ChatRoute(bot: owner, taskID: task.id) }
        } label: {
            FadedCard {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(task.prompt).font(.headline).lineLimit(2)
                        Text([owner?.name, task.agentAction?.title].compactMap { $0 }.joined(separator: " · "))
                            .font(.subheadline).foregroundStyle(.secondary)
                        let detail = task.agentAction?.receipt ?? (task.agentAction?.mailDraft != nil ? "Kladde klar til gennemgang" : "Åbn og fortsæt opgaven")
                        Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").accessibilityHidden(true)
                }
                .frame(minHeight: 44)
            }
        }
        .buttonStyle(.plain)
        .disabled(owner == nil)
        .contextMenu {
            if let link = task.agentAction?.receiptLink { Link("Åbn i Gmail", destination: link) }
        }
    }

    private func reload() {
        bots = ((try? MigratedAppData.shared.loadBots().get()) ?? []).filter { $0.id != VillageBot.lumiID }
        tasks = MigratedAppData.shared.regularStudioTurns().reversed().filter { taskSection($0) != nil }
    }

    private func taskSection(_ turn: PrivateChatTurn) -> TaskSection? {
        guard let action = turn.agentAction, action.canFollowUp else { return nil }
        if action.receiptLink != nil { return .followup }
        return action.receipt == nil ? .pending : .done
    }
}
