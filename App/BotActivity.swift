// Dagsplan for landsbyen. Tiden fryser, mens appen ikke er aktiv.

import Foundation

enum BotActivity: String, Codable, Equatable {
    case working, idle, resting, sleeping

    var title: String {
        switch self {
        case .working: "Arbejder"
        case .idle: "Vågen"
        case .resting: "Hviler"
        case .sleeping: "Sover"
        }
    }

    /// Energi pr. time. Working 08–12 og 13–18, idle 07–08 og 12–13, resting 18–22, sleeping 22–07.
    var energyPerHour: Double {
        switch self {
        case .working: -4
        case .idle: -1
        case .resting: 2
        case .sleeping: 4
        }
    }

    static func scheduled(atHour hour: Int) -> BotActivity {
        let hour = ((hour % 24) + 24) % 24
        switch hour {
        case 8..<12, 13..<18: return .working
        case 7, 12: return .idle
        case 18..<22: return .resting
        default: return .sleeping
        }
    }

    /// Uafklamret sum af time-raterne. 9×−4 + 2×−1 + 4×+2 + 9×+4 = +6.
    static var rawDailyEnergyDelta: Double {
        (0..<24).reduce(0) { $0 + scheduled(atHour: $1).energyPerHour }
    }

    /// Et døgn fra et fuldt morgen-niveau lander igen på 100, fordi overskuddet klippes ved loftet.
    static func energyAfterOneDay(startingAtHour start: Int, energy: Double) -> Double {
        var value = energy
        for offset in 0..<24 {
            let hour = (start + offset) % 24
            value = min(100, max(0, value + scheduled(atHour: hour).energyPerHour))
        }
        return value
    }
}
