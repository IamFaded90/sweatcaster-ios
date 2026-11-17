import EventKit
import SwiftUI
import UIKit

@MainActor struct AgentMeetingPrep: View {
    let prompt: String

    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scene
    @State private var store = EKEventStore()
    @State private var state: ResultState = .loading
    @State private var requesting = false
    @State private var selection: String?

    private enum ResultState {
        case loading, permission(EKAuthorizationStatus), results([Appointment]), failed
    }

    private struct Appointment: Identifiable {
        let id, title: String
        let interval: DateInterval
        let allDay: Bool
        let location, notes: String?
        let people: [String]
        let links: [URL]
    }

    nonisolated static func matches(_ prompt: String) -> Bool {
        topic(in: prompt) != nil
    }

    private nonisolated static func topic(in prompt: String) -> String? {
        let request = #"^(?:kan du (?:lige )?|vil du )?(?:(?:forberede?|klargøre?) (?:mig til )?|gør(?:e)? mig klar til )(.+)$"#
        let need = #"^hvad skal jeg (?:have med|forberede)(?: til| før) (.+)$"#
        let eventWords = #"\b(?:aftale(?:n|r)?|møde(?:t|r)?|tandlæge(?:n|tid(?:en)?)?|læge(?:n|tid(?:en)?)?|samtale(?:n|r)?|interview(?:et)?|besøg(?:et)?|kalender(?:en)?)\b"#
        let text = prompt.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: "?!., "))
        for pattern in [request, need] {
            guard let expression = try? NSRegularExpression(pattern: pattern),
                  let result = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(result.range(at: 1), in: text) else { continue }
            let topic = String(text[range])
            if topic.range(of: eventWords, options: .regularExpression) != nil { return topic }
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Forbered aftalen", systemImage: "calendar.badge.clock").font(.headline)
            switch state {
            case .loading:
                ProgressView("Læser Kalender…")
            case let .permission(status):
                permissions(status)
            case let .results(appointments):
                results(appointments)
            case .failed:
                Text("Kalender kunne ikke læses lige nu.").foregroundStyle(.secondary)
                Button("Prøv igen", systemImage: "arrow.clockwise") { load() }.frame(minHeight: 44)
            }
        }
        .privacySensitive()
        .task { load() }
        .onChange(of: scene) { _, value in
            if value == .active && !requesting { load() }
        }
    }

    private func permissions(_ status: EKAuthorizationStatus) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Giv adgang til Kalender for at finde aftalen.").foregroundStyle(.secondary)
            if status == .notDetermined {
                Button("Giv adgang", systemImage: "lock.open") { Task { await requestAccess() } }
                    .frame(minHeight: 44)
                    .disabled(requesting)
            } else {
                Button("Åbn Indstillinger", systemImage: "gearshape") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                .frame(minHeight: 44)
            }
        }
    }

    @ViewBuilder private func results(_ appointments: [Appointment]) -> some View {
        if let appointment = appointments.first(where: { $0.id == selection }) ?? appointments.first {
            if appointments.count > 1 {
                Menu("Vælg aftale", systemImage: "calendar") {
                    ForEach(appointments) { item in
                        Button("\(item.title) – \(item.interval.start.formatted(date: .abbreviated, time: .omitted))") {
                            selection = item.id
                        }
                    }
                }
                .frame(minHeight: 44)
            }

            Text(appointment.title).font(.headline)
            Text(dateLabel(appointment)).foregroundStyle(.secondary)
            if let location = appointment.location {
                Label(location, systemImage: "mappin.and.ellipse").textSelection(.enabled)
            }
            if !appointment.people.isEmpty {
                Label(appointment.people.joined(separator: ", "), systemImage: "person.2")
                    .font(.subheadline)
            }
            if let notes = appointment.notes {
                DisclosureGroup("Noter fra aftalen") { Text(notes).textSelection(.enabled) }
            }
            ForEach(appointment.links, id: \.self) { url in
                Link(destination: url) {
                    Label(url.host ?? "Åbn link fra aftalen", systemImage: "link")
                }
                .frame(minHeight: 44)
            }
            Label("Kilde · Kalender", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary)
        } else {
            Text("Jeg fandt ingen kommende aftale, der passer. Prøv at skrive navnet på aftalen.")
                .foregroundStyle(.secondary)
        }
    }

    private func dateLabel(_ appointment: Appointment) -> String {
        let start = appointment.interval.start
        if appointment.allDay { return start.formatted(date: .abbreviated, time: .omitted) + " · Hele dagen" }
        let end = appointment.interval.end
        let sameDay = Calendar.current.isDate(start, inSameDayAs: end)
        return start.formatted(date: .abbreviated, time: .shortened) + "–"
            + end.formatted(date: sameDay ? .omitted : .abbreviated, time: .shortened)
    }

    private func requestAccess() async {
        requesting = true
        defer { requesting = false }
        do {
            _ = try await store.requestFullAccessToEvents()
            guard !Task.isCancelled else { return }
            load()
        } catch {
            if !Task.isCancelled { state = .failed }
        }
    }

    private func load() {
        let status = EKEventStore.authorizationStatus(for: .event)
        guard status == .fullAccess else { state = .permission(status); return }
        var calendar = Calendar.current
        calendar.firstWeekday = 2
        let now = Date.now
        let topic = Self.topic(in: prompt) ?? ""
        let day = Self.requestedDay(topic, now: now, calendar: calendar)
        let start = day.map { calendar.startOfDay(for: $0) } ?? now
        guard let end = calendar.date(byAdding: .day, value: day == nil ? 60 : 1, to: start) else {
            state = .failed
            return
        }
        let terms = Self.searchTerms(topic)
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let upcoming = store.events(matching: predicate).filter { event in
            guard event.status != .canceled, let beginning = event.startDate, let ending = event.endDate,
                  ending > now, beginning < end else { return false }
            if day == nil && beginning < now { return false }
            let title = (event.title ?? "").lowercased()
            return terms.allSatisfy { title.contains($0) }
        }
        .sorted { $0.startDate < $1.startDate }
        let mostRelevant = terms.isEmpty && day == nil ? upcoming.prefix(1) : upcoming.prefix(8)
        state = .results(mostRelevant.compactMap(appointment(from:)))
    }

    private func appointment(from event: EKEvent) -> Appointment? {
        guard let start = event.startDate, let end = event.endDate, start <= end else { return nil }
        let notes = nonempty(event.notes).map { String($0.prefix(4_000)) }
        let links = links(in: notes ?? "", eventURL: event.url)
        let names = ([event.organizer].compactMap { $0 } + (event.attendees ?? []))
            .compactMap { nonempty($0.name) }
        var seen = Set<String>()
        return Appointment(id: "\(event.calendarItemIdentifier):\(start.timeIntervalSinceReferenceDate)",
                           title: nonempty(event.title) ?? "Aftale", interval: DateInterval(start: start, end: end),
                           allDay: event.isAllDay, location: nonempty(event.location), notes: notes,
                           people: Array(names.filter { seen.insert($0).inserted }.prefix(12)), links: links)
    }

    private func nonempty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    private func links(in notes: String, eventURL: URL?) -> [URL] {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let found = detector?.matches(in: notes, range: NSRange(notes.startIndex..., in: notes)).compactMap(\.url) ?? []
        var seen = Set<URL>()
        return Array(([eventURL].compactMap { $0 } + found).filter { url in
            url.scheme?.lowercased() == "https" && url.host != nil && url.user == nil && url.password == nil
                && seen.insert(url).inserted
        }.prefix(5))
    }

    private nonisolated static func requestedDay(_ topic: String, now: Date, calendar: Calendar) -> Date? {
        let words = topic.split(separator: " ").map(String.init)
        if topic.contains("i overmorgen") { return calendar.date(byAdding: .day, value: 2, to: now) }
        if topic.contains("i morgen") { return calendar.date(byAdding: .day, value: 1, to: now) }
        if topic.contains("i dag") { return now }
        let weekdays = ["søndag", "mandag", "tirsdag", "onsdag", "torsdag", "fredag", "lørdag"]
        guard let weekday = words.first(where: weekdays.contains), let index = weekdays.firstIndex(of: weekday) else { return nil }
        let distance = (index + 1 - calendar.component(.weekday, from: now) + 7) % 7
        if topic.contains("næste \(weekday)"), let nextWeek = calendar.date(byAdding: .day, value: 7, to: now),
           let start = calendar.dateInterval(of: .weekOfYear, for: nextWeek)?.start {
            let offset = (index + 1 - calendar.component(.weekday, from: start) + 7) % 7
            return calendar.date(byAdding: .day, value: offset, to: start)
        }
        return calendar.date(byAdding: .day, value: distance, to: now)
    }

    private nonisolated static func searchTerms(_ topic: String) -> [String] {
        let generic: Set<String> = ["min", "mit", "mine", "næste", "den", "det", "første", "aftale", "aftalen", "aftaler",
                                    "møde", "mødet", "møder", "hos", "med", "på", "i", "overmorgen", "morgen", "dag",
                                    "mandag", "tirsdag", "onsdag", "torsdag", "fredag", "lørdag", "søndag", "kalender", "kalenderen"]
        let aliases = ["tandlægen": "tandlæge", "tandlægetid": "tandlæge", "tandlægetiden": "tandlæge",
                       "lægen": "læge", "lægetid": "læge", "lægetiden": "læge"]
        return topic.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init).filter { $0.count > 1 && !generic.contains($0) }
            .prefix(6).map { aliases[$0] ?? $0 }
    }
}
