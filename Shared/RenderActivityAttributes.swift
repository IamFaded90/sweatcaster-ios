import ActivityKit
import Foundation

struct RenderActivityAttributes: ActivityAttributes {
    enum Kind: String, Codable, Hashable { case video, code }

    struct ContentState: Codable, Hashable {
        let progress: Double
        let phase: String
        var progressIsKnown: Bool? = nil
        var isRunning: Bool? = nil
    }

    let jobKey: String
    var kind: Kind? = nil
}
