// Behov ejet af SimulationEngine. VillageBot gemmer dem ikke.

import Foundation

struct BotSimulationState: Codable, Equatable {
    var energy: Double
    var social: Double
    var workJoy: Double
    var mood: BotMood
    var currentActivity: BotActivity

    static let socialPerHour = -1.0
    static let socialChatBonus = 5.0
    static let socialInteractionBonus = 3.0
    static let workJoyWithoutWorkPerHour = -2.0
    static let workJoyFinishedBonus = 10.0
    static let workJoyFailedPenalty = -5.0

    init(energy: Double = 100, social: Double = 50, workJoy: Double = 50, currentActivity: BotActivity = .idle) {
        self.energy = Self.clamp(energy)
        self.social = Self.clamp(social)
        self.workJoy = Self.clamp(workJoy)
        self.currentActivity = currentActivity
        self.mood = BotMood.resolve(energy: self.energy, social: self.social, workJoy: self.workJoy)
    }

    var energyDisplay: Int { Int(energy.rounded()) }
    var socialDisplay: Int { Int(social.rounded()) }
    var workJoyDisplay: Int { Int(workJoy.rounded()) }

    static func clamp(_ value: Double) -> Double { min(100, max(0, value)) }

    static func apply(elapsed: TimeInterval, at date: Date, calendar: Calendar, to state: inout BotSimulationState) {
        let hours = max(0, elapsed) / 3600
        let activity = BotActivity.scheduled(atHour: calendar.component(.hour, from: date))
        state.currentActivity = activity
        if hours > 0 {
            state.energy = clamp(state.energy + activity.energyPerHour * hours)
            // Idle er vinduet 07–08 og 12–13. Social falder kun dér.
            if activity == .idle { state.social = clamp(state.social + socialPerHour * hours) }
            if activity != .working {
                state.workJoy = clamp(state.workJoy + workJoyWithoutWorkPerHour * hours)
            }
        }
        state.mood = BotMood.resolve(energy: state.energy, social: state.social, workJoy: state.workJoy)
    }
}
