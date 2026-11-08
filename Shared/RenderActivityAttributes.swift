import ActivityKit
import Foundation

struct RenderActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        let progress: Double
        let phase: String
    }

    let jobKey: String
}
