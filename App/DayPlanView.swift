import EventKit
import SwiftUI

@MainActor struct DayPlanView: View {
    private struct Booking: Identifiable { var id: UUID { task.id }; let task: DayPlan.Task; let slot: DayPlan.Slot }
    let bot: VillageBot
    var initialDraftID: UUID?
    @State private var draft = DayPlanView.initialDraft()
    @State private var busyTimes: [DayPlan.Busy] = []
    @State private var events: [String] = []
    @State private var checkedDay: Date?
    @State private var store = EKEventStore()
    @State private var plan: DayPlan.Result?
    @State private var loading = false
    @State private var notice: String?
    @State private var title = ""
    @State private var saved: [DayPlan.Draft] = []
    @State private var booking: Booking?
    @State private var loaded = false
    @Environment(\.dismiss) private var dismiss
    private var library: DayPlan.Store { .init(botID: bot.id) }
    private var calendar: Calendar { .autoupdatingCurrent }
    private var sourcesCurrent: Bool { checkedDay.map { calendar.isDate($0, inSameDayAs: draft.day) } == true }
    static func initialDraft() -> DayPlan.Draft {
        let calendar = Calendar.autoupdatingCurrent, now = Date.now
        let day = calendar.startOfDay(for: now), start = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day) ?? now
        let end = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: day) ?? now.addingTimeInterval(3_600)
        return .init(day: day, start: start, end: end)
    }
    var body: some View {
        NavigationStack {
            List {
                Section("En plan med plads til pauser") {
                    DatePicker("Dag", selection: $draft.day, displayedComponents: .date).onChange(of: draft.day) { old, new in
                        let start = calendar.dateComponents([.hour,.minute], from: draft.start), end = calendar.dateComponents([.hour,.minute], from: draft.end)
                        draft.start = calendar.date(bySettingHour: start.hour ?? 9, minute: start.minute ?? 0, second: 0, of: new) ?? new
                        draft.end = calendar.date(bySettingHour: end.hour ?? 18, minute: end.minute ?? 0, second: 0, of: new) ?? new
                        checkedDay = nil; plan = nil; busyTimes = []; events = []
                    }.disabled(loading)
                    DatePicker("Fra", selection: $draft.start, displayedComponents: .hourAndMinute).disabled(loading)
                    DatePicker("Til", selection: $draft.end, displayedComponents: .hourAndMinute).disabled(loading)
                    Stepper("Pause mellem aktiviteter: \(draft.pause) min", value: $draft.pause, in: 0...60, step: 5).disabled(loading)
                    Button(sourcesCurrent ? "Opdatér kalender og påmindelser" : "Hent kalender og påmindelser", systemImage: "calendar.badge.clock") { Task { await readSources() } }.frame(minHeight: 44).disabled(loading)
                    if loading { ProgressView("Læser telefonens kilder…") }
                    Text(sourcesCurrent ? "Kalenderen er læst for den valgte dag. Nye ændringer kontrolleres igen før en booking." : "Læs kalenderen før planen fordeles, så aftaler kan holdes fri.").font(.caption).foregroundStyle(.secondary)
                    if let notice { Text(notice).font(.footnote).foregroundStyle(.secondary) }
                }
                Section("Opgaver og varighed") {
                    HStack { TextField("Tilføj en opgave", text: $title); Button("Tilføj", systemImage: "plus") { add() }.disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft.tasks.count >= 24) }.frame(minHeight: 44).disabled(loading)
                    ForEach($draft.tasks) { $task in
                        VStack(alignment: .leading, spacing: 7) {
                            TextField("Opgave", text: $task.title)
                            if let receipt = task.receipt { Label(receipt, systemImage: "checkmark.circle") }
                            else {
                                Stepper("\(task.minutes) minutter", value: $task.minutes, in: 5...240, step: 5)
                                Picker("Prioritet", selection: $task.priority) { Text("Når der er plads").tag(0); Text("Normal").tag(1); Text("Vigtig").tag(2); Text("Først").tag(3) }
                                if let notBefore = task.notBefore {
                                    DatePicker("Tidligst", selection: Binding(get: { task.notBefore ?? notBefore }, set: { task.notBefore = $0 }), displayedComponents: [.date,.hourAndMinute])
                                    Button("Fjern flytning") { task.notBefore = nil; plan = nil }
                                }
                                HStack {
                                    Button("Kort ned") { task.minutes = max(5, task.minutes - 10); plan = nil }
                                    Button("Flyt") { task.notBefore = max(draft.start, Date.now); plan = nil }
                                    Button(task.skip ? "Medtag igen" : "Spring over") { task.skip.toggle(); plan = nil }
                                }.frame(minHeight: 44)
                                if task.skip { Text("Sprunget over i denne plan").font(.caption) }
                            }
                            if task.reminderID != nil { Text("Kilde: Påmindelser · originalen bevares").font(.caption).foregroundStyle(.secondary) }
                        }.padding(.vertical, 5).disabled(loading)
                            .swipeActions { Button("Fjern fra planen", role: .destructive) { draft.tasks.removeAll { $0.id == task.id }; plan = nil }.disabled(loading) }
                    }
                    Button("Fordel opgaverne", systemImage: "sparkles") { arrange() }.frame(minHeight: 44).disabled(loading || !sourcesCurrent || draft.tasks.isEmpty)
                    Button("Gem kladden", systemImage: "square.and.arrow.down") { save() }.frame(minHeight: 44).disabled(loading)
                }
                if let plan {
                    Section("Forslaget · endnu ikke booket") {
                        ForEach(plan.slots) { slot in
                            if let task = draft.tasks.first(where: { $0.id == slot.task }) {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(task.title).font(.headline)
                                    Text("\(slot.start.formatted(date: .omitted, time: .shortened))–\(slot.end.formatted(date: .omitted, time: .shortened))")
                                    Button("Gennemgå og læg i Kalender", systemImage: "calendar.badge.plus") { booking = .init(task: task, slot: slot) }.frame(minHeight: 44)
                                }
                            }
                        }
                        if !plan.unplaced.isEmpty { Text("Disse fik ikke plads: " + draft.tasks.filter { plan.unplaced.contains($0.id) }.map(\.title).joined(separator: ", ") + ". Kort dem ned, flyt dem eller spring dem over.").foregroundStyle(.secondary) }
                    }
                }
                if !events.isEmpty { Section("Kalenderkilder for dagen") { ForEach(events.indices, id: \.self) { Text(events[$0]).font(.subheadline) } } }
                if !saved.isEmpty {
                    Section("Gemte dagsplaner") {
                        ForEach(saved) { old in
                            Button(old.day.formatted(date: .abbreviated, time: .omitted)) { draft = old; checkedDay = nil; plan = nil; events = []; busyTimes = [] }.frame(minHeight: 44).disabled(loading)
                                .swipeActions { Button("Slet kladde", role: .destructive) { do { try library.remove(old.id); saved = try library.load() } catch { notice = error.localizedDescription } }.disabled(loading) }
                        }
                    }
                }
            }.scrollContentBackground(.hidden).background { FadedBackground() }
                .navigationTitle("Min dagsplan").navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("Luk") { dismiss() } }
                .onAppear {
                    do {
                        saved = try library.load(); guard !loaded else { return }; loaded = true
                        if let initialDraftID, let initial = saved.first(where: { $0.id == initialDraftID }) { draft = initial }
                        else if let today = saved.first(where: { calendar.isDate($0.day, inSameDayAs: draft.day) }) { draft = today }
                    } catch { notice = error.localizedDescription }
                }
                .onChange(of: draft.tasks) { _, _ in plan = nil }
                .onChange(of: draft.start) { _, _ in plan = nil }.onChange(of: draft.end) { _, _ in plan = nil }.onChange(of: draft.pause) { _, _ in plan = nil }
                .sheet(item: $booking) { request in
                    BotPhoneActionReview(action: .init(kind: .calendar, title: request.task.title, localDate: BotPhoneAction.localFormatter().string(from: request.slot.start), endDate: BotPhoneAction.localFormatter().string(from: request.slot.end)), jobID: request.task.id, botName: bot.name, requiresAvailableTime: true,
                        onSaved: { receipt in if let index = draft.tasks.firstIndex(where: { $0.id == request.task.id }) { draft.tasks[index].receipt = receipt; save(); checkedDay = nil; plan = nil } }, onApplied: {})
                }
        }
    }
    private func add() {
        let text = title.trimmingCharacters(in: .whitespacesAndNewlines); guard (1...240).contains(text.count), draft.tasks.count < 24 else { return }
        draft.tasks.append(.init(title: text)); title = ""; plan = nil
    }
    private func save() { do { try library.save(draft); saved = try library.load(); notice = "Kladden er gemt. Kalenderen ændres først ved en gennemgået booking." } catch { notice = error.localizedDescription } }
    private func arrange() {
        do {
            guard sourcesCurrent else { return }
            var current = draft
            if calendar.isDateInToday(draft.day) { current.start = max(current.start, Date(timeIntervalSince1970: ceil(Date.now.timeIntervalSince1970 / 300) * 300)) }
            plan = try DayPlan.arrange(current, busy: busyTimes); try library.save(draft); saved = try library.load()
        } catch { notice = error.localizedDescription }
    }
    private func readSources() async {
        guard !loading else { return }; loading = true; notice = nil; plan = nil; checkedDay = nil
        defer { loading = false }
        do {
            var allowed = EKEventStore.authorizationStatus(for: .event) == .fullAccess
            if EKEventStore.authorizationStatus(for: .event) == .notDetermined { allowed = try await store.requestFullAccessToEvents() }
            guard allowed else { notice = "Giv FadedAI fuld kalenderadgang i iPhones indstillinger for at planlægge mellem dine aftaler."; return }
            let day = calendar.startOfDay(for: draft.day), end = calendar.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86_400)
            let found = store.events(matching: store.predicateForEvents(withStart: day, end: end, calendars: nil)).filter { $0.availability != .free }
            busyTimes = found.map { .init(start: $0.startDate, end: $0.endDate, source: $0.eventIdentifier ?? "Kalender") }
            events = found.map { ($0.title ?? "Aftale") + " · " + ($0.isAllDay ? "Hele dagen" : $0.startDate.formatted(date: .omitted, time: .shortened)) }
            checkedDay = draft.day
            var remindersAllowed = EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
            if EKEventStore.authorizationStatus(for: .reminder) == .notDetermined { remindersAllowed = try await store.requestFullAccessToReminders() }
            if remindersAllowed {
                let reminders = await withCheckedContinuation { continuation in store.fetchReminders(matching: store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: end, calendars: nil)) { continuation.resume(returning: $0 ?? []) } }
                try Task.checkCancellation()
                let known = Set(draft.tasks.compactMap(\.reminderID))
                for reminder in reminders.prefix(80) where draft.tasks.count < 24 && !known.contains(reminder.calendarItemIdentifier) {
                    draft.tasks.append(.init(title: String((reminder.title ?? "Påmindelse").prefix(240)), priority: reminder.priority > 0 && reminder.priority <= 4 ? 2 : 1, reminderID: reminder.calendarItemIdentifier))
                }
            } else { notice = "Kalenderen er læst. Tilføj opgaver selv, eller giv adgang til Påmindelser i iPhones indstillinger." }
        } catch { notice = error.localizedDescription }
    }
}

@MainActor struct DayPlanEntry: View {
    @State private var showing = false
    var body: some View {
        Button("Lav en realistisk dagsplan", systemImage: "calendar.badge.clock") { showing = true }.frame(minHeight: 44)
            .sheet(isPresented: $showing) {
                let bots = ((try? MigratedAppData.shared.loadBots().get()) ?? []).filter { $0.id != VillageBot.lumiID }
                if let bot = bots.first(where: { $0.name.caseInsensitiveCompare("Adam") == .orderedSame }) ?? bots.first { DayPlanView(bot: bot) }
                else { Text("Opret en agent i Landsbyen først.").padding() }
            }
    }
}
