import ActivityKit
import AppIntents
import Foundation

struct RenderActivityAttributes: ActivityAttributes {
    enum Kind: String, Codable, Hashable { case video, code }

    struct ContentState: Codable, Hashable {
        let progress: Double
        let phase: String
        var progressIsKnown: Bool? = nil
        var isRunning: Bool? = nil
        var lastUpdatedAt: Date? = nil
    }

    let jobKey: String
    var kind: Kind? = nil
    var pairingKey: String? = nil
}
enum FadedCameraTarget: String, AppEnum {
    case studio

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Kamera")
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .studio: "FadedAI Kamera"
    ]
}

struct OpenFadedAICamera: OpenIntent {
    static let title: LocalizedStringResource = "Åbn FadedAI Kamera"
    static let openAppWhenRun = true
    static let destination = "capture-video"
    static let shortcutKey = "spaces.shortcut"

    @Parameter(title: "Kamera")
    var target: FadedCameraTarget

    init() { target = .studio }

    @MainActor func perform() async throws -> some IntentResult {
        UserDefaults.standard.set(Self.destination, forKey: Self.shortcutKey)
        return .result()
    }
}
