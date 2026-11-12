// Humør udledt af behov. Påvirker kun visning — ikke Video, Kode eller Team.

import SwiftUI

enum BotMood: String, Codable, Equatable {
    case glad, tired, lonely, frustrated, proud, neutral

    var title: String {
        switch self {
        case .glad: "Glad"
        case .tired: "Træt"
        case .lonely: "Ensom"
        case .frustrated: "Frustreret"
        case .proud: "Stolt"
        case .neutral: "Neutral"
        }
    }

    var symbolName: String {
        switch self {
        case .glad: "face.smiling"
        case .tired: "moon.zzz"
        case .lonely: "person"
        case .frustrated: "exclamationmark.bubble"
        case .proud: "star.fill"
        case .neutral: "face.dashed"
        }
    }

    func tint(_ palette: FadedPalette) -> Color {
        switch self {
        case .glad: palette.green
        case .tired: palette.muted
        case .lonely: palette.cyan
        case .frustrated: palette.coral
        case .proud: palette.lime
        case .neutral: palette.secondary
        }
    }

    /// Frustreret > Træt > Ensom > Stolt > Glad > Neutral.
    static func resolve(energy: Double, social: Double, workJoy: Double) -> BotMood {
        if workJoy < 20 { return .frustrated }
        if energy < 30 { return .tired }
        if social < 20 { return .lonely }
        if workJoy > 80 { return .proud }
        if energy > 50, social > 50, workJoy > 50 { return .glad }
        return .neutral
    }
}
