import EventKit
import SwiftUI
import UIKit

@MainActor struct AgentTodayOverview: View {
    let api: LiveAPI?
    let botName: String

    init(api: LiveAPI?, botName: String = "din agent") {
        self.api = api
        self.botName = botName
    }

    private enum Source: String {
        case calendar = "Kalender"
        case reminders = "Påmindelser"

        var entity: EKEntityType { self == .calendar ? .event : .reminder }
        var icon: String { self == .calendar ? "calendar" : "checklist" }
    }

    private enum Chapter<Entry> {
        case loading
        case access(EKAuthorizationStatus)
        case unavailable(String)
        case ready([Entry])
    }

    private struct Event: Identifiable {
        let id, title: String
        let start, end: Date
        let allDay: Bool
    }

    private struct Reminder: Identifiable {
        let id, title: String
        let due: Date
        let hasTime: Bool
    }

    private struct ReminderProposal: Identifiable {
        let id = UUID()
        let eventID: String
        let action: BotPhoneAction
    }

    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scene
    @State private var store = EKEventStore()
    @State private var events: Chapter<Event> = .loading
    @State private var reminders: Chapter<Reminder> = .loading
    @State private var mail: Chapter<BotMailMessages.Message> = .loading
    @State private var requestingAccess: Source?
    @State private var selectedMail: BotMailMessages.Message?
    @State private var reminderProposal: ReminderProposal?
    @State private var remindedEvents = Set<String>()
    @State private var pendingCompletion: Reminder?
    @State private var confirmCompletion = false
    @State private var receipt: String?
    @State private var refreshID = UUID()
    @State private var reminderReadID = UUID()
    @State private var expandedSources = Set<Source>()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Dagens overblik").font(.headline)
            phoneSection(.calendar, state: events, empty: "Du har ingen aftaler i dag.", row: eventRow)
            Divider()
            phoneSection(.reminders, state: reminders, empty: "Du har ingen påmindelser med frist i dag eller tidligere.", row: reminderRow)
            Divider()
            gmailSection
            if let receipt { Text(receipt).font(.subheadline).foregroundStyle(.secondary) }
            Button("Opdatér dagsoversigten", systemImage: "arrow.clockwise") {
                refreshID = UUID()
            }
            .disabled(requestingAccess != nil)
            .frame(minHeight: 44)
        }
        .privacySensitive()
        .task(id: refreshID) {
            readEvents()
            await readReminders()
        }
        .task(id: MailRefresh(target: api?.queueTargetID, refresh: refreshID)) {
            await readMail()
        }
        .onChange(of: scene) { _, value in
            if value == .active && requestingAccess == nil { refreshID = UUID() }
        }
        .sheet(item: $selectedMail) { item in
            if let api { AgentTodayMail(api: api, item: item) }
        }
        .sheet(item: $reminderProposal) { proposal in
            BotPhoneActionReview(action: proposal.action, jobID: proposal.id, botName: botName, onSaved: { receipt = $0 }) {
                remindedEvents.insert(proposal.eventID)
                Task { await readReminders() }
            }
        }
        .alert("Markér påmindelsen som færdig?", isPresented: $confirmCompletion, presenting: pendingCompletion) { item in
            Button("Markér færdig") { Task { await complete(item) } }
            Button("Annullér", role: .cancel) {}
        } message: { item in
            Text(item.title)
        }
    }

    private struct MailRefresh: Hashable {
        let target: String?
        let refresh: UUID
    }

    private func phoneSection<Entry, Row: View>(_ source: Source, state: Chapter<Entry>, empty: String,
                                                 @ViewBuilder row: @escaping (Entry) -> Row) -> some View
    where Entry: Identifiable {
        VStack(alignment: .leading, spacing: 8) {
            Label(source.rawValue, systemImage: source.icon).font(.subheadline.bold())
            switch state {
            case .loading:
                ProgressView("Henter \(source.rawValue.lowercased())…")
            case .ready(let entries):
                if entries.isEmpty { Text(empty).foregroundStyle(.secondary) }
                let expanded = expandedSources.contains(source)
                ForEach(expanded ? entries : Array(entries.prefix(6)), content: row)
                if entries.count > 6 {
                    Button(expanded ? "Vis færre" : "Vis alle \(entries.count)",
                           systemImage: expanded ? "chevron.up" : "chevron.down") {
                        if expanded { expandedSources.remove(source) }
                        else { expandedSources.insert(source) }
                    }
                    .frame(minHeight: 44)
                }
            case .unavailable(let message):
                Text(message).foregroundStyle(.secondary)
            case .access(let status):
                Text("Giv adgang til \(source.rawValue.lowercased()) for at få det med i overblikket.")
                    .foregroundStyle(.secondary)
                if status == .denied || status == .restricted || status == .writeOnly {
                    Button("Åbn Indstillinger", systemImage: "gearshape") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                    .frame(minHeight: 44)
                } else {
                    Button("Giv adgang", systemImage: "lock.open") { Task { await requestAccess(to: source) } }
                        .disabled(requestingAccess != nil)
                        .frame(minHeight: 44)
                }
            }
        }
    }

    private func eventRow(_ item: Event) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.title)
            Text(eventTime(item)).font(.caption).foregroundStyle(.secondary)
            if remindedEvents.contains(item.id) {
                Label("Påmindelse oprettet", systemImage: "checkmark").font(.caption)
            } else if item.start > .now, !item.allDay {
                Button("Mind mig om den", systemImage: "bell") { proposeReminder(for: item) }
                    .font(.subheadline).frame(minHeight: 44)
            }
        }
    }

    private func eventTime(_ item: Event) -> String {
        if item.allDay { return "Hele dagen" }
        let calendar = Calendar.current
        let sameDay = calendar.isDate(item.start, inSameDayAs: item.end)
        let start = item.start.formatted(date: sameDay ? .omitted : .abbreviated, time: .shortened)
        let end = item.end.formatted(date: sameDay ? .omitted : .abbreviated, time: .shortened)
        return "\(start) – \(end)"
    }

    private func reminderRow(_ item: Reminder) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                Text(item.due.formatted(date: Calendar.current.isDateInToday(item.due) && item.hasTime ? .omitted : .abbreviated,
                                        time: item.hasTime ? .shortened : .omitted))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Markér \(item.title) som færdig", systemImage: "checkmark.circle") {
                pendingCompletion = item
                confirmCompletion = true
            }
            .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
        }
    }

    private var gmailSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Vigtige ulæste mails", systemImage: "envelope").font(.subheadline.bold())
            switch mail {
            case .loading:
                ProgressView("Henter Gmail…")
            case .ready(let entries):
                if entries.isEmpty { Text("Gmail fandt ingen vigtige eller stjernemarkerede ulæste mails.").foregroundStyle(.secondary) }
                ForEach(entries) { item in
                    Button { selectedMail = item } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.subject.isEmpty ? "Uden emne" : item.subject)
                            if !item.sender.isEmpty { Text(item.sender).font(.caption).foregroundStyle(.secondary) }
                        }
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                }
            case .unavailable(let message):
                Text(message).foregroundStyle(.secondary)
            case .access:
                EmptyView()
            }
        }
    }

    private func readEvents() {
        let status = EKEventStore.authorizationStatus(for: .event)
        guard status == .fullAccess else { events = .access(status); return }
        guard let today = Calendar.current.dateInterval(of: .day, for: .now) else {
            events = .unavailable("Kunne ikke finde dagens dato.")
            return
        }
        let predicate = store.predicateForEvents(withStart: today.start, end: today.end, calendars: nil)
        let results = store.events(matching: predicate).compactMap { item -> Event? in
            guard item.status != .canceled, let start = item.startDate, let end = item.endDate,
                  start < today.end, end > today.start else { return nil }
            return Event(id: "\(item.calendarItemIdentifier):\(start.timeIntervalSinceReferenceDate)",
                         title: item.title ?? "Aftale", start: start, end: end, allDay: item.isAllDay)
        }
        events = .ready(results.sorted { $0.start < $1.start })
    }

    private func readReminders() async {
        let readID = UUID()
        reminderReadID = readID
        let status = EKEventStore.authorizationStatus(for: .reminder)
        guard status == .fullAccess else { reminders = .access(status); return }
        let calendar = Calendar.current
        guard let today = calendar.dateInterval(of: .day, for: .now) else {
            reminders = .unavailable("Kunne ikke finde dagens dato.")
            return
        }
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: today.end, calendars: nil)
        let results: [Reminder]? = await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { items in
                let due = items?.compactMap { item -> Reminder? in
                    guard let components = item.dueDateComponents else { return nil }
                    let dueCalendar = components.calendar ?? calendar
                    guard let date = dueCalendar.date(from: components), date < today.end else { return nil }
                    return Reminder(id: item.calendarItemIdentifier, title: item.title ?? "Påmindelse",
                                    due: date, hasTime: components.hour != nil)
                }
                continuation.resume(returning: due)
            }
        }
        guard !Task.isCancelled, reminderReadID == readID else { return }
        if let results { reminders = .ready(results.sorted { $0.due < $1.due }) }
        else { reminders = .unavailable("Kunne ikke hente påmindelser. Opdatér for at prøve igen.") }
    }

    private func readMail() async {
        guard let api else {
            mail = .unavailable("Forbind FadedAI til din PC for at få Gmail med i overblikket.")
            return
        }
        mail = .loading
        do {
            let response: BotMailMessages = try await api.moduleJSON("composio/gmail/messages", timeout: 75,
                query: [URLQueryItem(name: "q", value: "in:inbox is:unread {is:important is:starred}")])
            guard !Task.isCancelled else { return }
            mail = .ready(Array(response.messages.prefix(5)))
        } catch {
            guard !Task.isCancelled else { return }
            if case APIError.http(_, let problem) = error, let message = problem?.message { mail = .unavailable(message) }
            else { mail = .unavailable("Kunne ikke hente Gmail fra PC’en. Opdatér for at prøve igen.") }
        }
    }

    private func requestAccess(to source: Source) async {
        guard requestingAccess == nil else { return }
        requestingAccess = source
        defer { requestingAccess = nil }
        do {
            switch source {
            case .calendar:
                _ = try await store.requestFullAccessToEvents()
                readEvents()
            case .reminders:
                _ = try await store.requestFullAccessToReminders()
                await readReminders()
            }
        } catch {
            switch source {
            case .calendar: events = .unavailable("Kunne ikke åbne Kalender. Opdatér for at prøve igen.")
            case .reminders: reminders = .unavailable("Kunne ikke åbne Påmindelser. Opdatér for at prøve igen.")
            }
        }
    }

    private func proposeReminder(for item: Event) {
        let earlier = item.start.addingTimeInterval(-1_800)
        let due = earlier > .now ? earlier : item.start
        let date = BotPhoneAction.localFormatter().string(from: due)
        let action = BotPhoneAction(kind: .reminder, title: String(item.title.prefix(120)), localDate: date,
                                    location: nil, endDate: nil, needsDate: false)
        reminderProposal = ReminderProposal(eventID: item.id, action: action)
    }

    private func complete(_ item: Reminder) async {
        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess,
              let reminder = store.calendarItem(withIdentifier: item.id) as? EKReminder else {
            receipt = "Påmindelsen kunne ikke findes på din iPhone."
            await readReminders()
            return
        }
        do {
            reminder.isCompleted = true
            try store.save(reminder, commit: true)
            let reader = EKEventStore()
            if let saved = reader.calendarItem(withIdentifier: item.id) as? EKReminder, saved.isCompleted {
                receipt = "Tjekket i Påmindelser: Den er markeret som færdig."
            } else {
                receipt = "iPhone modtog ændringen. Jeg kunne ikke bekræfte, at påmindelsen er markeret som færdig."
            }
        } catch {
            store.reset()
            receipt = "Påmindelsen kunne ikke markeres som færdig."
        }
        await readReminders()
    }
}

@MainActor private struct AgentTodayMail: View {
    let api: LiveAPI
    let item: BotMailMessages.Message

    @Environment(\.dismiss) private var dismiss
    @State private var content: String?
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(item.subject.isEmpty ? "Uden emne" : item.subject).font(.headline)
                    Text(item.sender).font(.subheadline).foregroundStyle(.secondary)
                    if let content { Text(content).textSelection(.enabled) }
                    else if let problem { Text(problem).foregroundStyle(.secondary) }
                    else { ProgressView("Henter mailen…") }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .navigationTitle("Gmail").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Luk") { dismiss() } } }
            .task(id: item.id) {
                do {
                    let response: BotMailContent = try await api.moduleJSON(
                        "composio/gmail/message/\(Server.segment(item.id))", timeout: 75)
                    guard !Task.isCancelled else { return }
                    content = response.text.isEmpty ? "Mailen indeholder ingen læsbar tekst." : response.text
                } catch {
                    guard !Task.isCancelled else { return }
                    problem = "Kunne ikke åbne mailen via PC’en."
                }
            }
        }
        .privacySensitive()
    }
}
