import EventKit
import Foundation
import SwiftUI

struct BotPhoneActionReview: View {
    let action: BotPhoneAction
    let jobID: UUID
    let botName: String
    let requiresAvailableTime: Bool
    let reminderNotes: String?
    let onSaved: ((String) -> Void)?
    let onApplied: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var date: Date
    @State private var endDate: Date
    @State private var location: String
    @State private var usesDate: Bool
    @State private var busy = false
    @State private var issue: String?

    init(action: BotPhoneAction, jobID: UUID, botName: String, requiresAvailableTime: Bool = false,
         suggestedDay: Date? = nil, reminderNotes: String? = nil, onSaved: ((String) -> Void)? = nil,
         onApplied: @escaping () -> Void) {
        self.action = action
        self.jobID = jobID
        self.botName = botName
        self.requiresAvailableTime = requiresAvailableTime
        self.reminderNotes = reminderNotes
        self.onSaved = onSaved
        self.onApplied = onApplied
        let proposed = action.localDate.flatMap { BotPhoneAction.localFormatter().date(from: $0) }
        let suggested = suggestedDay.flatMap { Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: $0) }
        let start = proposed ?? suggested ?? .now
        _title = State(initialValue: action.title)
        _usesDate = State(initialValue: action.kind != .reminder || action.localDate != nil || action.needsDate == true)
        _date = State(initialValue: start)
        let proposedEnd = action.endDate.flatMap { BotPhoneAction.localFormatter().date(from: $0) }
        _endDate = State(initialValue: proposedEnd ?? start.addingTimeInterval(1800))
        _location = State(initialValue: action.location ?? "")
        if action.localDate != nil && proposed == nil {
            _issue = State(initialValue: "Bottens tidspunkt kunne ikke læses. Vælg det rigtige tidspunkt.")
        } else if action.needsDate == true {
            _issue = State(initialValue: "Tidspunktet er ikke fastlagt. Vælg det her.")
        }
    }

    static var supportsAlarms: Bool {
        #if canImport(AlarmKit)
        if #available(iOS 26.0, *) { return true }
        #endif
        return false
    }

    private var dated: Bool { action.kind != .reminder || usesDate }
    private var cleanTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var validEnd: Bool { action.kind != .calendar || endDate > date }

    var body: some View {
        NavigationStack {
            Form {
                Section("Forslag fra \(botName)") {
                    TextField("Titel", text: $title)
                    if action.kind == .reminder { Toggle("Med tidspunkt", isOn: $usesDate) }
                    if dated {
                        DatePicker(action.kind == .calendar ? "Start" : "Tidspunkt", selection: $date)
                        if date <= .now { Text("Vælg et tidspunkt frem i tiden.").foregroundStyle(.secondary) }
                    }
                    if action.kind == .calendar {
                        DatePicker("Slut", selection: $endDate)
                        TextField("Sted (valgfrit)", text: $location)
                        if !validEnd { Text("Sluttid skal være efter start.").foregroundStyle(.secondary) }
                    }
                }
                if action.kind == .reminder, let reminderNotes, !reminderNotes.isEmpty {
                    Section("Noter i påmindelsen") { Text(verbatim: reminderNotes).textSelection(.enabled) }
                }
                Button("Godkend og opret", systemImage: "checkmark") { Task { await apply() } }
                    .disabled(busy || cleanTitle.isEmpty || cleanTitle.count > 120 || !validEnd || (dated && date <= .now))
                if busy { ProgressView() }
                if let issue { Text(issue).foregroundStyle(.secondary) }
            }
            .navigationTitle(action.kind.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Luk") { dismiss() }.disabled(busy)
                }
            }
            .interactiveDismissDisabled(busy)
        }
    }

    @MainActor private func apply() async {
        let requestedTitle = cleanTitle
        let requestedDate = dated ? date : nil
        guard !busy, !requestedTitle.isEmpty, requestedTitle.count <= 120, validEnd else { return }
        if let requestedDate, requestedDate <= .now {
            issue = "Vælg et tidspunkt frem i tiden."
            return
        }
        busy = true
        issue = nil
        defer { busy = false }
        do {
            switch action.kind {
            case .calendar:
                guard let requestedDate else { throw PhoneActions.Failure.expired }
                try await PhoneActions.saveEvent(title: requestedTitle, start: requestedDate, end: endDate,
                                                location: String(location.prefix(240)), jobID: jobID, store: EKEventStore(),
                                                requiresAvailableTime: requiresAvailableTime)
            case .reminder:
                try await PhoneActions.saveReminder(title: requestedTitle, due: requestedDate, jobID: jobID,
                                                    store: EKEventStore(), notes: reminderNotes)
            case .alarm:
                #if canImport(AlarmKit)
                if #available(iOS 26.0, *), let requestedDate {
                    try await PhoneActions.scheduleAlarm(title: requestedTitle, date: requestedDate, id: jobID)
                } else {
                    throw PhoneActions.Failure.unsupportedAlarm
                }
                #else
                throw PhoneActions.Failure.unsupportedAlarm
                #endif
            }
            if let onSaved {
                let start = requestedDate?.formatted(date: .abbreviated, time: .shortened)
                let end = action.kind == .calendar ? endDate.formatted(date: .abbreviated, time: .shortened) : nil
                onSaved(["\(action.kind.title) oprettet", requestedTitle, [start, end].compactMap { $0 }.joined(separator: " – ")]
                    .filter { !$0.isEmpty }.joined(separator: "\n"))
            }
            onApplied()
            dismiss()
        } catch {
            issue = (error as? PhoneActions.Failure)?.message ?? "Kunne ikke oprette \(action.kind.title.lowercased()). Prøv igen."
        }
    }
}

@MainActor struct AgentPhoneActionCard: View {
    struct Request: Identifiable, Codable, Equatable {
        let id: UUID
        let prompt: String
        let kind: BotPhoneActionKind?
        let created: Date

        static func phone(_ kind: BotPhoneActionKind, prompt: String) -> Request {
            Request(id: UUID(), prompt: prompt, kind: kind, created: Date())
        }

        static func match(_ prompt: String) -> Request? {
            let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            let prefix = #"^(?:kan du\s+|vil du\s+|du må godt\s+|gider du\s+|vil du ikke\s+)?"#
            let command = #"(?:(?:så )?(?:lige )?)"#
            let search = #"(?:finde?(?: mig)? (?:en |et |nogle )?ledige? (?:timer?|tider?|tidspunkter?)|(?:hvornår er jeg|er jeg) ledig)\b"#
            if text.phoneMatch(prefix + command + search) != nil {
                return Request(id: UUID(), prompt: text, kind: nil, created: Date())
            }
            if text.phoneMatch(prefix + command + #"(?:sæt(?:te)?|stil(?:le)?|lave?|opret(?:te)?)(?: lige)? (?:en |et |min |mit )?(?:alarm|vækkeur)\b"#) != nil
                || text.phoneMatch(prefix + command + #"væk(?:ke)? mig\b"#) != nil { return phone(.alarm, prompt: text) }
            if text.phoneMatch(prefix + command + #"(?:minde? mig\b|(?:sæt(?:te)?|lave?|opret(?:te)?)(?: lige)? (?:en )?påmindelse\b|skrive?\b.*\bi (?:mine )?påmindelser\b)"#) != nil {
                return phone(.reminder, prompt: text)
            }
            if text.phoneMatch(prefix + command + #"(?:opret(?:te)?(?: lige)? (?:en )?(?:aftale|kalenderaftale)\b|(?:læg(?:ge)?|skrive?|sæt(?:te)?|tilføje?)\b.*\bi (?:min kalender|kalenderen)\b)"#) != nil {
                return phone(.calendar, prompt: text)
            }
            return nil
        }
    }

    private struct Review: Identifiable {
        let id: UUID
        let action: BotPhoneAction
        var suggestedDay: Date? = nil
    }

    let request: Request
    let botName: String
    let onApplied: (String) -> Void
    @State private var store = EKEventStore()
    @State private var day: Date
    @State private var slots: [DateInterval] = []
    @State private var showAllSlots = false
    @State private var checking = false
    @State private var notice: String?
    @State private var review: Review?
    @State private var receipt: String?
    @State private var refresh = UUID()

    init(request: Request, botName: String, onApplied: @escaping (String) -> Void) {
        self.request = request
        self.botName = botName
        self.onApplied = onApplied
        let calendar = AgentCalendarAvailability.clock
        let requestedDay = AgentPhoneLanguage.day(in: request.prompt, now: request.created, calendar: calendar)
        _day = State(initialValue: max(calendar.startOfDay(for: .now), requestedDay ?? request.created))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let receipt {
                Label(receipt, systemImage: "checkmark.circle.fill")
            } else if let kind = request.kind {
                actionPlan(kind)
            } else {
                calendarSearch
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(item: $review, onDismiss: { if receipt == nil && request.kind == nil { refresh = UUID() } }) { review in
            BotPhoneActionReview(action: review.action, jobID: review.id, botName: botName,
                                 requiresAvailableTime: request.kind == nil,
                                 suggestedDay: review.suggestedDay, onSaved: complete) {}
        }
        .privacySensitive()
    }

    @ViewBuilder private func actionPlan(_ kind: BotPhoneActionKind) -> some View {
        if kind == .alarm && !BotPhoneActionReview.supportsAlarms {
            Text("Alarmer i FadedAI kræver iOS 26 eller nyere.").foregroundStyle(.secondary)
        } else {
            let action = AgentPhoneLanguage.action(kind, prompt: request.prompt, now: request.created)
            let proposed = action.localDate.flatMap { BotPhoneAction.localFormatter().date(from: $0) }
            Text(action.title).font(.headline)
            if let proposed { Text(proposed.formatted(date: .abbreviated, time: .shortened)) }
            else if action.needsDate == true { Text("Vælg tidspunktet, når du godkender.").foregroundStyle(.secondary) }
            Button("Gennemgå \(kind.title.lowercased())", systemImage: "checkmark.circle") {
                let date = AgentPhoneLanguage.day(in: request.prompt, now: request.created,
                                                  calendar: AgentCalendarAvailability.clock)
                review = Review(id: request.id, action: action, suggestedDay: date)
            }
            .frame(minHeight: 44)
        }
    }

    private var calendarSearch: some View {
        let key = CalendarLookup(day: day, refresh: refresh)
        return VStack(alignment: .leading, spacing: 8) {
            Text("Find en ledig time").font(.headline)
            DatePicker("Dag", selection: $day, in: AgentCalendarAvailability.clock.startOfDay(for: .now)...,
                       displayedComponents: .date)
            if checking { ProgressView("Tjekker Kalender…") }
            else if let notice {
                Text(notice).foregroundStyle(.secondary)
                Button("Prøv igen", systemImage: "arrow.clockwise") { refresh = UUID() }.frame(minHeight: 44)
            } else if slots.isEmpty {
                Text("Jeg fandt ingen ledig time i det valgte tidsrum.").foregroundStyle(.secondary)
            } else {
                ForEach(showAllSlots ? slots : Array(slots.prefix(4)), id: \.start) { slot in
                    Button("\(slot.start.formatted(date: .omitted, time: .shortened))–\(slot.end.formatted(date: .omitted, time: .shortened))",
                           systemImage: "calendar.badge.plus") { select(slot) }
                        .frame(minHeight: 44)
                }
                if slots.count > 4 {
                    Button(showAllSlots ? "Vis færre tider" : "Vis flere tider") { showAllSlots.toggle() }
                        .frame(minHeight: 44)
                }
            }
        }
        .task(id: key) { await findTimes(key) }
    }

    private struct CalendarLookup: Equatable {
        let day: Date
        let refresh: UUID
    }

    private func findTimes(_ key: CalendarLookup) async {
        checking = true
        slots = []
        notice = nil
        showAllSlots = false
        defer { if day == key.day && refresh == key.refresh { checking = false } }
        do {
            guard try await store.requestFullAccessToEvents() else { throw PhoneActions.Failure.calendarReadPermission }
            try Task.checkCancellation()
            slots = AgentCalendarAvailability.slots(for: key.day, prompt: request.prompt, store: store)
        } catch is CancellationError {
            return
        } catch {
            if !Task.isCancelled {
                notice = (error as? PhoneActions.Failure)?.message ?? "Kalenderen kunne ikke læses."
            }
        }
    }

    private func select(_ slot: DateInterval) {
        let format = BotPhoneAction.localFormatter()
        let title = request.prompt.phoneMatch(#"\btil\s+(.+?)(?:\s+(?:på (?:søndag|mandag|tirsdag|onsdag|torsdag|fredag|lørdag)|i morgen|efter|før)\b|[.?!]?$)"#)?[1]
        let action = BotPhoneAction(kind: .calendar, title: String((title ?? "Aftale").prefix(120)),
                                    localDate: format.string(from: slot.start),
                                    endDate: format.string(from: slot.end))
        review = Review(id: request.id, action: action)
    }

    private func complete(_ result: String) {
        receipt = result
        onApplied(result)
    }
}

@MainActor enum AgentCalendarAvailability {
    nonisolated static var clock: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "da_DK")
        calendar.timeZone = .current
        calendar.firstWeekday = 2
        return calendar
    }

    static func blockingEvents(in range: DateInterval, store: EKEventStore) -> [DateInterval] {
        let predicate = store.predicateForEvents(withStart: range.start, end: range.end, calendars: nil)
        return store.events(matching: predicate).compactMap { event in
            guard event.status != .canceled, event.availability != .free,
                  let start = event.startDate, let end = event.endDate,
                  end > start, start < range.end, end > range.start else { return nil }
            return DateInterval(start: start, end: end)
        }
    }

    static func slots(for day: Date, prompt: String, store: EKEventStore) -> [DateInterval] {
        let calendar = clock
        let preferred = AgentChatPreferences.preferredStartHour ?? 8
        let after = AgentPhoneLanguage.time(in: prompt, marker: #"\befter\s+(?:klokken|kl\.?)?"#)
        let before = AgentPhoneLanguage.time(in: prompt, marker: #"\bfør\s+(?:klokken|kl\.?)?"#)
        let startTime = after ?? (before.map { $0.0 <= preferred ? max(0, $0.0 - 4) : preferred } ?? preferred, 0)
        let endTime = before ?? (startTime.0 < 17 ? 18 : 24, 0)
        let end = endTime.0 == 24 ? calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: day))
            : calendar.date(bySettingHour: endTime.0, minute: endTime.1, second: 0, of: day)
        guard let start = calendar.date(bySettingHour: startTime.0, minute: startTime.1, second: 0, of: day),
              let end, end > start else { return [] }
        let window = DateInterval(start: start, end: end)
        return freeSlots(in: window, busy: blockingEvents(in: window, store: store))
    }

    nonisolated static func freeSlots(in window: DateInterval, busy: [DateInterval], now: Date = .now) -> [DateInterval] {
        var result: [DateInterval] = []
        var start = window.start
        while start.addingTimeInterval(3600) <= window.end {
            let end = start.addingTimeInterval(3600)
            if start > now && !busy.contains(where: { $0.start < end && $0.end > start }) {
                result.append(DateInterval(start: start, end: end))
            }
            start = start.addingTimeInterval(1800)
        }
        return result
    }
}

enum AgentPhoneLanguage {
    static func action(_ kind: BotPhoneActionKind, prompt: String, now: Date) -> BotPhoneAction {
        let calendar = AgentCalendarAvailability.clock
        let name = title(in: prompt, kind: kind)
        let relative = relativeTime(in: prompt, now: now)
        let requestedDay = day(in: prompt, now: now, calendar: calendar)
        let marker = kind == .alarm ? #"\b(?:klokken|kl\.?|til)"# : #"\b(?:klokken|kl\.?)"#
        let chosenTime = time(in: prompt, marker: marker)
        let hasDate = requestedDay != nil || prompt.phoneMatch(#"\b(?:i morgen|i overmorgen|i dag|\d{1,2}/\d{1,2}|20\d\d-\d{2}-\d{2})\b"#) != nil
        let hasClock = chosenTime != nil || prompt.phoneMatch(marker + #"\s*\d"#) != nil
        let proposed: Date? = if let relative {
            relative
        } else if let chosenTime, !hasDate || requestedDay != nil,
                  let candidate = calendar.date(bySettingHour: chosenTime.0, minute: chosenTime.1, second: 0,
                                                of: requestedDay ?? now, matchingPolicy: .strict) {
            if requestedDay == nil && candidate <= now { calendar.date(byAdding: .day, value: 1, to: candidate) }
            else { candidate }
        } else {
            nil
        }
        let formatter = BotPhoneAction.localFormatter()
        return BotPhoneAction(kind: kind, title: name, localDate: proposed.map { formatter.string(from: $0) },
                              endDate: kind == .calendar ? proposed.map { formatter.string(from: $0.addingTimeInterval(3600)) } : nil,
                              needsDate: proposed == nil && (kind != .reminder || hasDate || hasClock))
    }

    static func day(in prompt: String, now: Date, calendar: Calendar) -> Date? {
        let today = calendar.startOfDay(for: now)
        if prompt.phoneMatch(#"\bi overmorgen\b"#) != nil { return calendar.date(byAdding: .day, value: 2, to: today) }
        if prompt.phoneMatch(#"\bi morgen\b"#) != nil { return calendar.date(byAdding: .day, value: 1, to: today) }
        if prompt.phoneMatch(#"\bi dag\b"#) != nil { return today }
        if let date = prompt.phoneMatch(#"\b(20\d\d)-(\d{2})-(\d{2})\b"#),
           let year = Int(date[1]), let month = Int(date[2]), let day = Int(date[3]) {
            return validDate(year: year, month: month, day: day, calendar: calendar)
        }
        if let date = prompt.phoneMatch(#"\b(\d{1,2})/(\d{1,2})(?:/(20\d\d))?\b"#),
           let day = Int(date[1]), let month = Int(date[2]) {
            let year = Int(date[3]) ?? calendar.component(.year, from: today)
            guard let result = validDate(year: year, month: month, day: day, calendar: calendar) else { return nil }
            if date[3].isEmpty && result < today {
                return validDate(year: year + 1, month: month, day: day, calendar: calendar)
            }
            return result
        }
        let weekdays = ["søndag", "mandag", "tirsdag", "onsdag", "torsdag", "fredag", "lørdag"]
        if let weekday = prompt.phoneMatch(#"\b(søndag|mandag|tirsdag|onsdag|torsdag|fredag|lørdag)\b"#),
           let index = weekdays.firstIndex(of: weekday[1].lowercased()) {
            let delta = (index + 1 - calendar.component(.weekday, from: today) + 7) % 7
            let next = prompt.phoneMatch(#"\bnæste (?:søndag|mandag|tirsdag|onsdag|torsdag|fredag|lørdag|uge)\b"#) != nil
            if next, let nextWeek = calendar.date(byAdding: .day, value: 7, to: today),
               let week = calendar.dateInterval(of: .weekOfYear, for: nextWeek) {
                return calendar.date(byAdding: .day, value: (index + 6) % 7, to: week.start)
            }
            return calendar.date(byAdding: .day, value: delta, to: today)
        }
        if prompt.phoneMatch(#"\bnæste uge\b"#) != nil, let nextWeek = calendar.date(byAdding: .day, value: 7, to: today) {
            return calendar.dateInterval(of: .weekOfYear, for: nextWeek)?.start
        }
        return nil
    }

    static func time(in prompt: String, marker: String) -> (Int, Int)? {
        let words = "nul|en|et|to|tre|fire|fem|seks|syv|otte|ni|ti|elleve|tolv"
        let clock = marker + #"\s*(\d{1,2})(?:[:.](\d{1,2}))?(?!\d|[:.]\d)\b"#
        if let time = prompt.phoneMatch(clock), let hour = Int(time[1]), let minute = Int(time[2].isEmpty ? "0" : time[2]),
           (0...23).contains(hour), (0...59).contains(minute) { return (hour, minute) }
        if let time = prompt.phoneMatch(marker + "\\s*(" + words + ")\\b"),
           let hour = ["nul": 0, "en": 1, "et": 1, "to": 2, "tre": 3, "fire": 4, "fem": 5, "seks": 6,
                       "syv": 7, "otte": 8, "ni": 9, "ti": 10, "elleve": 11, "tolv": 12][time[1].lowercased()] {
            return (hour, 0)
        }
        return nil
    }

    private static func validDate(year: Int, month: Int, day: Int, calendar: Calendar) -> Date? {
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)),
              calendar.component(.day, from: date) == day, calendar.component(.month, from: date) == month else { return nil }
        return date
    }

    private static func relativeTime(in prompt: String, now: Date) -> Date? {
        guard let time = prompt.phoneMatch(#"\bom\s+(\d{1,3})\s+(minut(?:ter)?|timer?)\b"#),
              let value = Int(time[1]), value > 0 else { return nil }
        return now.addingTimeInterval(Double(value) * (time[2].lowercased().hasPrefix("time") ? 3600 : 60))
    }

    private static func title(in prompt: String, kind: BotPhoneActionKind) -> String {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let intro = #"^(?:(?:kan du|vil du|du må godt|gider du|vil du ikke)\s+)?(?:så\s+)?(?:lige\s+)?"#
        let body: String
        switch kind {
        case .alarm:
            body = text.phoneMatch(#"\balarm\b.*?\btil (?:at |min |mit )?([^\d]+?)(?:\s+(?:kl\.?|klokken)\s+\d|$)"#)?[1] ?? ""
        case .reminder:
            body = text.phoneMatch(intro + #"(?:minde? mig.*?\bom (?:at )?|(?:sæt(?:te)?|lave?|opret(?:te)?)(?: lige)? (?:en )?påmindelse(?: om)?(?: at)?\s+)(.+)$"#)?[1]
                ?? text.phoneMatch(intro + #"skrive? (.+?) i (?:mine )?påmindelser\b"#)?[1] ?? text
        case .calendar:
            body = text.phoneMatch(intro + #"(?:læg(?:ge)?|skrive?|sæt(?:te)?|tilføje?)(?: lige)? (.+?) i (?:min kalender|kalenderen)\b"#)?[1]
                ?? text.phoneMatch(intro + #"opret(?:te)?(?: lige)? (?:en )?(?:aftale|kalenderaftale)(?: om)?\s+(.+)$"#)?[1] ?? text
        }
        let timing = #"\s+(?:(?:på\s+)?(?:søndag|mandag|tirsdag|onsdag|torsdag|fredag|lørdag)|i morgen|i overmorgen|i dag|om\s+\d{1,3}\s+(?:minut(?:ter)?|timer?)|\d{1,2}/\d{1,2}|20\d\d-\d{2}-\d{2}|kl\.?|klokken)\b.*$"#
        let title = body.replacingOccurrences(of: timing, with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return title.isEmpty ? kind.title : String(title.prefix(120))
    }
}

private extension String {
    func phoneMatch(_ pattern: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: self, range: NSRange(startIndex..., in: self)) else { return nil }
        return (0..<match.numberOfRanges).map { index in
            Range(match.range(at: index), in: self).map { String(self[$0]) } ?? ""
        }
    }
}

