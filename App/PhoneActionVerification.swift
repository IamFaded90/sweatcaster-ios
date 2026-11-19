import Foundation

enum PhoneActionVerification: Equatable {
    case matched, writeOnly, unavailable, different

    static func sameTime(_ actual: Date?, _ expected: Date?) -> Bool {
        switch (actual, expected) {
        case (nil, nil): true
        case let (actual?, expected?): floor(actual.timeIntervalSince1970 / 60) == floor(expected.timeIntervalSince1970 / 60)
        default: false
        }
    }

    static func event(titleMatches: Bool, locationMatches: Bool, start: Date?, end: Date?,
                      expectedStart: Date, expectedEnd: Date, allDay: Bool) -> Self {
        titleMatches && locationMatches && !allDay && sameTime(start, expectedStart) && sameTime(end, expectedEnd) ? .matched : .different
    }

    static func reminder(fieldsMatch: Bool, isCompleted: Bool, due: Date?, expectedDue: Date?, alerts: [Date]) -> Self {
        guard fieldsMatch, !isCompleted, sameTime(due, expectedDue) else { return .different }
        if let expectedDue, !alerts.contains(where: { sameTime($0, expectedDue) }) { return .different }
        return .matched
    }

    func summary(for kind: BotPhoneActionKind) -> String {
        switch self {
        case .matched:
            switch kind {
            case .calendar: "Kalenderaftalen er tjekket i Kalender."
            case .reminder: "Påmindelsen er tjekket i Påmindelser."
            case .alarm: "Alarmtidspunktet er tjekket på iPhone."
            }
        case .writeOnly: "Kalender modtog aftalen. Med din nuværende adgang kan jeg kun skrive i kalenderen."
        case .unavailable: "iPhone modtog handlingen. Jeg kunne ikke læse resultatet tilbage."
        case .different: "Det, jeg fandt på iPhone, afviger fra det, du godkendte."
        }
    }
}
