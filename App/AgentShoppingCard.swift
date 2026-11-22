import EventKit
import SwiftUI

@MainActor struct AgentShoppingCard: View {
    let request: AgentShoppingRequest
    let requestID: UUID
    let finish: (String) -> Void

    @State private var store = EKEventStore()
    @State private var lists: [EKCalendar] = []
    @State private var listID = ""
    @State private var fallbackListID: String?
    @State private var excluded = Set<String>()
    @State private var available: [String]?
    @State private var problem: String?
    @State private var busy = false
    @State private var reload = 0

    private var selected: EKCalendar? { lists.first { $0.calendarIdentifier == listID } }
    private var fallback: Bool { fallbackListID == listID }
    private var candidates: [String] {
        guard case .add(let names) = request else { return [] }
        return names.filter { !excluded.contains($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if lists.count > 1 {
                Picker("Liste i Påmindelser", selection: $listID) {
                    ForEach(lists, id: \.calendarIdentifier) { list in
                        Text(list.title + " · " + list.source.title).tag(list.calendarIdentifier)
                    }
                }.disabled(busy)
            } else if let selected {
                Label(selected.title, systemImage: "checklist")
            }
            if fallback { Text("Dine indkøb ligger i din standardliste i Påmindelser.").font(.footnote) }
            switch request {
            case .view:
                if let available {
                    if available.isEmpty { Text("Du har ingen åbne indkøb her.") }
                    ForEach(available, id: \.self) { Label($0, systemImage: "circle") }
                }
            case .add(let names):
                ForEach(names, id: \.self) { name in
                    Toggle(name, isOn: Binding(get: { !excluded.contains(name) }, set: { included in
                        if included { excluded.remove(name) } else { excluded.insert(name) }
                    }))
                }
                .disabled(busy)
                Button("Føj til Påmindelser", systemImage: "cart.badge.plus") {
                    guard !busy, let selected else { return }
                    busy = true
                    let items = candidates
                    Task { await save(items, to: selected) }
                }
                .disabled(selected == nil || busy || candidates.isEmpty)
            }
            if let problem { Text(problem).font(.callout) }
            if busy { ProgressView().accessibilityLabel("Opdaterer indkøbslisten") }
            if case .view = request { Button("Opdatér listen") { reload += 1 }.disabled(busy) }
            else if problem != nil && selected == nil { Button("Prøv igen") { reload += 1 } }
        }
        .task(id: reload) { await loadLists() }
        .task(id: listID) { if let selected, case .view = request { await read(selected) } }
    }

    private func loadLists() async {
        problem = nil
        do {
            guard try await store.requestFullAccessToReminders() else { throw PhoneActions.Failure.reminderPermission }
            let calendars = store.calendars(for: .reminder)
            let named = calendars.filter { list in
                let name = AgentShoppingRequest.key(list.title)
                return ["indkøb", "indkøbsliste", "indkøbslisten"].contains(name)
            }
            let ordered = named.sorted { ($0.title, $0.source.title) < ($1.title, $1.source.title) }
            let standard = store.defaultCalendarForNewReminders()
            let all = calendars + [standard].compactMap { $0 }
            let names = ordered.map(\.calendarIdentifier)
            let writable = Set(all.filter(\.allowsContentModifications).map(\.calendarIdentifier))
            let ids = request.destinationIDs(named: names, writable: writable, standard: standard?.calendarIdentifier)
            lists = ids.compactMap { id in all.first { $0.calendarIdentifier == id } }
            fallbackListID = standard.flatMap { names.contains($0.calendarIdentifier) ? nil : $0.calendarIdentifier }
            guard let first = lists.first else { throw PhoneActions.Failure.reminderList }
            let next = lists.first(where: { $0.calendarIdentifier == listID }) ?? first
            if listID == next.calendarIdentifier, case .view = request { await read(next) }
            else { listID = next.calendarIdentifier }
        } catch {
            lists = []
            listID = ""
            available = nil
            problem = (error as? PhoneActions.Failure)?.message ?? "Kunne ikke hente listerne fra Påmindelser."
        }
    }

    private func read(_ list: EKCalendar) async {
        available = nil
        problem = nil
        let rows = await Self.rows(in: list, store: store)
        guard !Task.isCancelled, listID == list.calendarIdentifier else { return }
        guard let rows else { problem = "Listen kunne ikke læses. Prøv igen."; return }
        let titles = rows.filter { !$0.done && (!fallback || $0.isShopping) }.flatMap { AgentShoppingRequest.titles(in: $0.title) }
        var seen = Set<String>()
        available = titles.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .filter { seen.insert(AgentShoppingRequest.key($0)).inserted }
    }

    private static func rows(in list: EKCalendar, store: EKEventStore) async -> [AgentShoppingRow]? {
        let predicate = store.predicateForReminders(in: [list])
        return await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: reminders?.compactMap { reminder in
                    guard let title = reminder.title, !title.isEmpty else { return nil }
                    return AgentShoppingRow(title: title, marker: reminder.url?.absoluteString, done: reminder.isCompleted)
                })
            }
        }
    }

    // One EventKit transaction per list, including the duplicate check across different agents.
    private static var writing = Set<String>()

    private func save(_ items: [String], to list: EKCalendar) async {
        defer { busy = false }
        guard Self.writing.insert(list.calendarIdentifier).inserted else {
            problem = "En anden agent gemmer indkøb på listen. Prøv igen om et øjeblik."
            return
        }
        defer { Self.writing.remove(list.calendarIdentifier) }
        problem = nil
        guard let rows = await Self.rows(in: list, store: store), case .add(let original) = request else {
            problem = "Påmindelser kunne ikke læse listen. Prøv igen."
            return
        }
        let plan = AgentShoppingPlan(original: original, selected: Set(items), requestID: requestID, rows: rows, defaultList: fallback)
        do {
            for item in plan.additions {
                let reminder = EKReminder(eventStore: store)
                reminder.title = item.title
                reminder.calendar = list
                reminder.url = URL(string: item.marker)
                try store.save(reminder, commit: false)
            }
            if !plan.additions.isEmpty { try store.commit() }
        } catch {
            store.reset()
            problem = "Påmindelser kunne ikke gemme indkøbene. Opdatér listen og prøv igen."
            lists = []
            listID = ""
            return
        }
        guard let verified = await Self.rows(in: list, store: store),
              Set(plan.additions.map(\.marker)).isSubset(of: Set(verified.compactMap(\.marker))) else {
            problem = "Kunne ikke bekræfte alle varerne. Prøv igen for at tjekke listen."
            return
        }
        var receipt = ["Tilføjet i " + list.title + ": " + plan.additions.map(\.title).joined(separator: ", ") + "."]
        if plan.additions.isEmpty { receipt = [] }
        if !plan.existing.isEmpty { receipt.append("Allerede registreret: " + plan.existing.joined(separator: ", ") + ".") }
        finish(receipt.joined(separator: "\n"))
    }
}
