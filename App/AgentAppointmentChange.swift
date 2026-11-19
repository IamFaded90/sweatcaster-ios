import EventKit
import SwiftUI

enum AgentAppointmentChangeIntent {
    static func matches(_ input: String) -> Bool {
        let text = AgentChatIntent.normalize(input)
        if ["ret en flyttet aftale", "find en flyttet aftale"].contains(text) { return true }
        if text.range(of: #"^(?:(?:kan|vil) du\s+)?(?:ikke|lad være med at)\b"#, options: .regularExpression) != nil { return false }
        let mentionsChange = text.range(of: #"\b(?:flyttet|rykket|ombooket|ændret|rescheduled)\b"#, options: .regularExpression) != nil
        let mentionsAppointment = text.range(of: #"\b(?:aftale\w*|tid\w*|booking\w*|appointment\w*)\b"#, options: .regularExpression) != nil
        let wantsAction = text.range(of: #"\b(?:ret|opdat[eé]r|flyt|ryk|få styr på|ordn|find|gør|hjælp|læg)\b"#, options: .regularExpression) != nil
        return mentionsChange && mentionsAppointment && wantsAction
    }

    static func query(_ input: String) -> String {
        let text = AgentChatIntent.normalize(input)
        if let match = ["tandlægen", "værkstedet", "lægen"].first(where: { word in
            text.range(of: "\\b" + word + "\\b", options: .regularExpression) != nil
        }) { return match }
        let suffix = text.range(of: #"\b(?:fra|hos)\s+([\p{L}\p{N}][\p{L}\p{N} -]{1,68})(?=[,.?!;]|$)"#, options: .regularExpression)
        guard let suffix else { return "" }
        return String(text[suffix].dropFirst(4)).trimmingCharacters(in: .whitespaces)
    }
}

struct MailAppointmentChange: Decodable, Equatable, Identifiable {
    let id, thread, sender, subject, quote: String
    let start, oldStart, end: TimeInterval?
    var date: Date? { start.map(Date.init(timeIntervalSince1970:)) }
    var oldDate: Date? { oldStart.map(Date.init(timeIntervalSince1970:)) }
    var link: URL? {
        guard thread.range(of: #"^[A-Za-z0-9_-]{1,128}$"#, options: .regularExpression) != nil else { return nil }
        return URL(string: "https://mail.google.com/mail/#all/" + thread)
    }
}

@MainActor struct AgentAppointmentChange: View {
    let api: LiveAPI?
    let onResult: (String, URL?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query: String
    @State private var changes: [MailAppointmentChange] = []
    @State private var selected: MailAppointmentChange?
    @State private var snapshot: AppointmentPhoneChange.Snapshot?
    @State private var eventID: String?
    @State private var reminderID: String?
    @State private var reminderChosen = false
    @State private var busy = false
    @State private var notice: String?
    @State private var confirmation = false
    @State private var receipt: String?

    init(api: LiveAPI?, prompt: String, onResult: @escaping (String, URL?) -> Void) {
        self.api = api
        self.onResult = onResult
        _query = State(initialValue: AgentAppointmentChangeIntent.query(prompt))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if api == nil {
                        Text("Forbind FadedAI med PC’en for at finde ændringen i Gmail.")
                    } else if let receipt {
                        FadedCard { Label(receipt, systemImage: "checkmark.circle").textSelection(.enabled) }
                    } else if let change = selected {
                        source(change)
                        if let snapshot { targets(snapshot, change: change) }
                        else { FadedPrimaryButton("Find aftalen på iPhone", icon: "calendar") { findTargets(change) }.disabled(busy) }
                        Button("Tilbage til mailene") { clearTargets(); selected = nil }.disabled(busy)
                    } else {
                        searchControls
                    }
                    if busy { ProgressView("Arbejder…") }
                    if let notice { Text(notice).foregroundStyle(.secondary).textSelection(.enabled) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(FadedSpacing.edge)
            }
            .background { FadedBackground() }
            .navigationTitle("Flyttet aftale")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Luk") { dismiss() }.disabled(busy) } }
            .interactiveDismissDisabled(busy)
            .confirmationDialog("Flyt aftale og påmindelse?", isPresented: $confirmation, titleVisibility: .visible) {
                Button("Gem ændringer") { apply() }
                Button("Annuller", role: .cancel) {}
            }
        }
        .privacySensitive()
        .task(id: api?.queueTargetID) { await search() }
    }

    private var searchControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Søg efter afsender eller aftale", text: $query)
                .submitLabel(.search).onSubmit { Task { await search() } }
                .padding(12).fadedGlassSurface().disabled(busy)
            FadedPrimaryButton("Find flyttede aftaler", icon: "envelope.badge") { Task { await search() } }.disabled(busy)
            ForEach(changes) { change in
                Button {
                    selected = change
                    notice = nil
                } label: {
                    FadedCard {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(change.subject.isEmpty ? "Flyttet aftale" : change.subject).font(.headline)
                            Text(change.sender).font(.caption).foregroundStyle(.secondary)
                            if let date = change.date { time(date) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .buttonStyle(.plain).disabled(busy)
            }
        }
    }

    private func source(_ change: MailAppointmentChange) -> some View {
        FadedCard {
            VStack(alignment: .leading, spacing: 8) {
                Text(change.subject.isEmpty ? "Flyttet aftale" : change.subject).font(.headline)
                Text(change.sender).font(.caption).foregroundStyle(.secondary)
                if let old = change.oldDate { HStack { Text("Før"); time(old) }.foregroundStyle(.secondary) }
                if let date = change.date { HStack { Text("Ny tid").bold(); time(date) } }
                Text(change.quote).font(.subheadline).textSelection(.enabled)
                if let url = change.link { Link("Åbn kilden i Gmail", destination: url) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func targets(_ snapshot: AppointmentPhoneChange.Snapshot, change: MailAppointmentChange) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if snapshot.events.isEmpty {
                Text("Jeg fandt ingen redigerbar aftale ved den gamle tid. Tjek kalenderen, og prøv igen.")
            } else {
                Text("Vælg den eksisterende aftale").font(.headline)
                ForEach(snapshot.events) { event in
                    choice(event.title, list: event.calendar, date: event.start, selected: event.id == eventID) {
                        eventID = event.id
                        reminderID = nil
                        reminderChosen = false
                    }
                }
            }
            if let event = snapshot.events.first(where: { $0.id == eventID }), let date = change.date {
                let reminders = snapshot.reminders(for: event, change: change)
                Text("Påmindelse").font(.headline)
                ForEach(reminders) { reminder in
                    choice(reminder.title, list: reminder.calendar, date: reminder.due, selected: reminder.id == reminderID) {
                        reminderID = reminder.id
                        reminderChosen = true
                    }
                }
                let newTitle = reminders.isEmpty ? "Opret en påmindelse" : "Opret en ny i stedet"
                choice(newTitle, list: "", date: nil, selected: reminderChosen && reminderID == nil) {
                    reminderID = nil
                    reminderChosen = true
                }
                if reminderChosen {
                    let due = reminders.first(where: { $0.id == reminderID })?.due
                    let next = AppointmentPhoneChange.reminderDate(oldDue: due, eventStart: event.start, newStart: date, now: .now)
                    HStack { Text("Påmind mig"); time(next) }.font(.subheadline)
                }
                FadedPrimaryButton("Gennemgå og flyt", icon: "calendar.badge.clock") { confirmation = true }
                    .disabled(busy || !reminderChosen)
            }
            Button("Find aftalen igen", systemImage: "arrow.clockwise") { findTargets(change) }.disabled(busy)
        }
    }

    private func choice(_ title: String, list: String, date: Date?, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.subheadline.weight(.semibold))
                    if let date { time(date).font(.caption) }
                    if !list.isEmpty { Text(list).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
            }
            .padding(12).fadedGlassSurface()
            .frame(minHeight: 44)
        }
        .buttonStyle(.plain).disabled(busy)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func time(_ date: Date) -> Text { Text(date.formatted(date: .abbreviated, time: .shortened)) }

    private func clearTargets() {
        snapshot = nil
        eventID = nil
        reminderID = nil
        reminderChosen = false
        notice = nil
    }

    private struct Results: Decodable { let changes: [MailAppointmentChange] }
    private struct Lookup: Encodable { let zone: String; let query: String?; let thread: String? }

    private func lookup(_ api: LiveAPI, query: String? = nil, thread: String? = nil) async throws -> [MailAppointmentChange] {
        let payload = Lookup(zone: TimeZone.current.identifier, query: query, thread: thread)
        let result: Results = try await api.moduleJSON("mail-reschedule", upload: JSONEncoder().encode(payload), timeout: 90)
        return result.changes.filter { $0.date != nil && $0.link != nil }
    }

    private func search() async {
        guard let api, !busy else { return }
        busy = true
        defer { busy = false }
        clearTargets()
        selected = nil
        changes = []
        do {
            let result = try await lookup(api, query: query)
            try Task.checkCancellation()
            changes = result
            if changes.count == 1 { selected = changes.first }
            if changes.isEmpty { notice = "Jeg fandt ingen nyere mail med én klar ny dato og et klokkeslæt. Prøv et andet navn." }
        } catch is CancellationError {} catch { show(error) }
    }

    private func findTargets(_ change: MailAppointmentChange) {
        guard !busy else { return }
        clearTargets()
        busy = true
        Task {
            defer { busy = false }
            do {
                let found = try await AppointmentPhoneChange.read(change)
                snapshot = found
                if found.events.count == 1 && (found.events[0].matchesSource || change.oldDate != nil) {
                    let event = found.events[0]
                    eventID = event.id
                    let reminders = found.reminders(for: event, change: change)
                    if reminders.count == 1 { reminderID = reminders[0].id; reminderChosen = true }
                }
            } catch { show(error) }
        }
    }

    private func apply() {
        guard let api, let change = selected, let snapshot, let eventID, reminderChosen, !busy,
              let event = snapshot.events.first(where: { $0.id == eventID }) else { return }
        let reminder = snapshot.reminders.first(where: { $0.id == reminderID })
        busy = true
        notice = nil
        Task {
            defer { busy = false }
            do {
                guard try await lookup(api, thread: change.thread).first == change else {
                    clearTargets()
                    selected = nil
                    changes = []
                    notice = "Gmail-tråden har ændret sig. Find den nyeste mail igen."
                    return
                }
                let result = try await AppointmentPhoneChange.apply(change, event: event, reminder: reminder)
                receipt = result
                onResult(result, change.link)
            } catch { show(error) }
        }
    }

    private func show(_ error: Error) {
        if case APIError.http(_, let problem) = error, let message = problem?.message { notice = message }
        else { notice = error.localizedDescription }
    }
}
