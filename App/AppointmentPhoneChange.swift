import EventKit
import Foundation

@MainActor enum AppointmentPhoneChange {
    struct Event: Identifiable, Equatable {
        let id, calendarID, title, calendar: String
        let start, end: Date
        let matchesSource: Bool

        init?(_ value: EKEvent, change: MailAppointmentChange) {
            guard let id = value.eventIdentifier, let start = value.startDate, let end = value.endDate,
                  end > start, !value.isAllDay, value.hasRecurrenceRules == false,
                  (value.attendees ?? []).isEmpty, let calendar = value.calendar,
                  calendar.allowsContentModifications else { return nil }
            self.id = id
            calendarID = calendar.calendarIdentifier
            title = value.title ?? "Aftale uden titel"
            self.calendar = calendar.title
            self.start = start
            self.end = end
            matchesSource = value.url == change.link && change.link != nil ||
                AppointmentPhoneChange.matchesTitle(title, change.subject + " " + change.sender)
        }
    }

    struct Reminder: Identifiable, Equatable {
        enum Alert: Equatable {
            case absolute(Date)
            case relative(TimeInterval)
        }
        let id, calendarID, title, calendar: String
        let due, start: Date?
        let alerts: [Alert]
        let source: URL?

        init?(_ value: EKReminder) {
            guard !value.isCompleted, value.hasRecurrenceRules == false,
                  let calendar = value.calendar, calendar.allowsContentModifications,
                  !(value.alarms ?? []).contains(where: { $0.structuredLocation != nil }) else { return nil }
            id = value.calendarItemIdentifier
            calendarID = calendar.calendarIdentifier
            title = value.title ?? "Påmindelse uden titel"
            self.calendar = calendar.title
            due = AppointmentPhoneChange.date(value.dueDateComponents)
            start = AppointmentPhoneChange.date(value.startDateComponents)
            alerts = AppointmentPhoneChange.alerts(value.alarms)
            source = value.url
        }
    }

    struct Snapshot {
        let events: [Event]
        let allReminders: [Reminder]

        func reminders(for event: Event, change: MailAppointmentChange) -> [Reminder] {
            allReminders.filter { reminder in
                if let link = change.link, reminder.source == link { return true }
                if let marker = AppointmentPhoneChange.marker(change), reminder.source == marker { return true }
                guard AppointmentPhoneChange.matchesTitle(event.title, reminder.title),
                      let due = reminder.due else { return false }
                let delta = event.start.timeIntervalSince(due)
                return (0...7 * 86_400).contains(delta)
            }.sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
        }
    }

    enum Failure: LocalizedError {
        case calendarPermission, reminderPermission, reminderRead, noList, outdated, changed, verification(String)

        var errorDescription: String? {
            switch self {
            case .calendarPermission: "Giv FadedAI fuld kalenderadgang i Indstillinger, så agenten kan finde og rette den eksisterende aftale."
            case .reminderPermission: "Giv FadedAI adgang til Påmindelser i Indstillinger."
            case .reminderRead: "Påmindelser kunne ikke læses. Prøv igen."
            case .noList: "iPhone har ingen redigerbar liste til nye påmindelser."
            case .outdated: "Den nye tid fra mailen er allerede passeret."
            case .changed: "Aftalen eller påmindelsen er ændret, siden du så den. Find den igen før du gemmer."
            case .verification(let note): note
            }
        }
    }

    static func read(_ change: MailAppointmentChange) async throws -> Snapshot {
        let store = EKEventStore()
        guard try await store.requestFullAccessToEvents() else { throw Failure.calendarPermission }
        guard try await store.requestFullAccessToReminders() else { throw Failure.reminderPermission }
        guard let start = change.date, start > .now else { throw Failure.outdated }
        let center = change.oldDate ?? start
        let span: TimeInterval = change.oldDate == nil ? 31 * 86_400 : 86_400
        let predicate = store.predicateForEvents(withStart: center.addingTimeInterval(-span),
                                                 end: center.addingTimeInterval(span), calendars: nil)
        let eligible = store.events(matching: predicate).compactMap { Event($0, change: change) }
            .filter { !PhoneActionVerification.sameTime($0.start, start) }
        let events: [Event]
        if let old = change.oldDate {
            events = eligible.filter { PhoneActionVerification.sameTime($0.start, old) }
        } else {
            let matching = eligible.filter(\.matchesSource)
            events = matching.isEmpty ? eligible : matching
        }
        return Snapshot(events: Array(events.sorted { $0.start < $1.start }.prefix(40)),
                        allReminders: try await reminders(in: store))
    }

    static func reminderDate(oldDue: Date?, eventStart: Date, newStart: Date, now: Date) -> Date {
        let lead = oldDue.map { eventStart.timeIntervalSince($0) } ?? 1800
        let next = newStart.addingTimeInterval(-max(0, lead))
        return next > now ? next : newStart
    }

    static func apply(_ change: MailAppointmentChange, event expected: Event, reminder chosen: Reminder?) async throws -> String {
        guard let start = change.date, start > .now else { throw Failure.outdated }
        let store = EKEventStore()
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { throw Failure.calendarPermission }
        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else { throw Failure.reminderPermission }
        if chosen == nil, try await reminders(in: store).contains(where: { $0.source == marker(change) }) { throw Failure.changed }
        guard let event = store.event(withIdentifier: expected.id), Event(event, change: change) == expected else {
            throw Failure.changed
        }
        let reminder: EKReminder
        if let chosen {
            guard let existing = store.calendarItem(withIdentifier: chosen.id) as? EKReminder,
                  Reminder(existing) == chosen else { throw Failure.changed }
            reminder = existing
        } else {
            guard let list = store.defaultCalendarForNewReminders(), list.allowsContentModifications else { throw Failure.noList }
            reminder = EKReminder(eventStore: store)
            reminder.calendar = list
            reminder.title = expected.title
            reminder.notes = change.link?.absoluteString
            reminder.url = marker(change)
        }
        let end = change.end.map(Date.init(timeIntervalSince1970:)) ?? start.addingTimeInterval(expected.end.timeIntervalSince(expected.start))
        guard start > .now, end > start else { throw Failure.outdated }
        let due = reminderDate(oldDue: chosen?.due, eventStart: expected.start, newStart: start, now: .now)
        event.startDate = start
        event.endDate = end
        move(reminder, from: chosen, to: due, now: .now)
        guard let target = Reminder(reminder) else { throw Failure.changed }
        do {
            try store.save(event, span: .thisEvent, commit: false)
            try store.save(reminder, commit: false)
            try store.commit()
        } catch {
            let eventID = event.eventIdentifier ?? expected.id
            let reminderID = reminder.calendarItemIdentifier
            store.reset()
            let result = verify(change, eventID: eventID, reminderID: reminderID,
                                start: start, end: end, expected: expected, target: target)
            if result.event && result.reminder { return receipt(start: start, due: due) }
            if result.event || result.reminder { throw Failure.verification(result.detail) }
            throw error
        }
        let result = verify(change, eventID: event.eventIdentifier ?? expected.id, reminderID: reminder.calendarItemIdentifier,
                            start: start, end: end, expected: expected, target: target)
        guard result.event && result.reminder else { throw Failure.verification(result.detail) }
        return receipt(start: start, due: due)
    }

    private static func move(_ reminder: EKReminder, from previous: Reminder?, to due: Date, now: Date) {
        reminder.dueDateComponents = components(due)
        let shift = previous?.due.map { due.timeIntervalSince($0) }
        if previous == nil { reminder.startDateComponents = components(due) }
        else if let shift, let start = previous?.start { reminder.startDateComponents = components(start.addingTimeInterval(shift)) }
        let alarms = (previous?.alerts ?? []).compactMap { alert -> EKAlarm? in
            switch alert {
            case .absolute(let date):
                guard let shift, date.addingTimeInterval(shift) > now else { return nil }
                return EKAlarm(absoluteDate: date.addingTimeInterval(shift))
            case .relative(let offset):
                guard due.addingTimeInterval(offset) > now else { return nil }
                return EKAlarm(relativeOffset: offset)
            }
        }
        reminder.alarms = alarms.isEmpty ? [EKAlarm(absoluteDate: due)] : alarms
    }

    private static func verify(_ change: MailAppointmentChange, eventID: String, reminderID: String,
                               start: Date, end: Date, expected: Event, target: Reminder)
        -> (event: Bool, reminder: Bool, detail: String) {
        let reader = EKEventStore()
        let new = reader.event(withIdentifier: eventID).flatMap { Event($0, change: change) }
        let oldRange = reader.predicateForEvents(withStart: expected.start.addingTimeInterval(-60),
                                                end: expected.start.addingTimeInterval(60), calendars: nil)
        let oldRemains = reader.events(matching: oldRange).contains {
            $0.eventIdentifier == expected.id && PhoneActionVerification.sameTime($0.startDate, expected.start)
        }
        let event = new.map {
            $0.title == expected.title && $0.calendarID == expected.calendarID &&
                PhoneActionVerification.sameTime($0.start, start) && PhoneActionVerification.sameTime($0.end, end)
        } == true && !oldRemains
        let stored = (reader.calendarItem(withIdentifier: reminderID) as? EKReminder).flatMap { Reminder($0) }
        let reminder = stored.map {
            $0.title == target.title && $0.calendarID == target.calendarID &&
                PhoneActionVerification.sameTime($0.due, target.due) && sameAlerts($0.alerts, target.alerts)
        } == true
        let detail = (event ? "Kalenderaftalen er flyttet." : "Den nye tid kunne ikke bekræftes i Kalender.") + " " +
            (reminder ? "Påmindelsen er opdateret." : "Den nye påmindelse kunne ikke bekræftes.") + " Tjek iPhone før du prøver igen."
        return (event, reminder, detail)
    }

    nonisolated private static func alerts(_ values: [EKAlarm]?) -> [Reminder.Alert] {
        (values ?? []).map { item in
            if let date = item.absoluteDate { return .absolute(date) }
            return .relative(item.relativeOffset)
        }
    }

    private static func sameAlerts(_ actual: [Reminder.Alert], _ expected: [Reminder.Alert]) -> Bool {
        actual.count == expected.count && expected.allSatisfy { alert in
            actual.contains { candidate in
                switch (alert, candidate) {
                case let (.absolute(left), .absolute(right)): PhoneActionVerification.sameTime(left, right)
                case let (.relative(left), .relative(right)): abs(left - right) < 1
                default: false
                }
            }
        }
    }

    private static func receipt(start: Date, due: Date) -> String {
        "Jeg flyttede aftalen til \(start.formatted(date: .abbreviated, time: .shortened)) og satte påmindelsen til \(due.formatted(date: .abbreviated, time: .shortened)). Begge tider er tjekket på iPhone."
    }

    private static func reminders(in store: EKEventStore) async throws -> [Reminder] {
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        let values: [EKReminder]? = await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { continuation.resume(returning: $0) }
        }
        guard let values else { throw Failure.reminderRead }
        return values.compactMap(Reminder.init)
    }

    private static func components(_ date: Date) -> DateComponents {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar.dateComponents([.calendar, .timeZone, .year, .month, .day, .hour, .minute, .second], from: date)
    }

    nonisolated private static func date(_ values: DateComponents?) -> Date? {
        values.flatMap { $0.date ?? Calendar.current.date(from: $0) }
    }

    nonisolated private static func marker(_ change: MailAppointmentChange) -> URL? {
        URL(string: "fadedai://mail-reschedule/" + change.thread + "/" + change.id)
    }

    nonisolated private static func matchesTitle(_ first: String, _ second: String) -> Bool {
        let ignored: Set<String> = ["aftale", "aftalen", "flyttet", "tidspunkt", "møde", "påmindelse", "gennemgå"]
        func words(_ value: String) -> Set<String> {
            Set(value.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init).filter { $0.count >= 4 && !ignored.contains($0) })
        }
        let right = words(second)
        return words(first).contains { left in
            right.contains { $0 == left || ($0.count >= 5 && left.count >= 5 && ($0.hasPrefix(left) || left.hasPrefix($0))) }
        }
    }
}
