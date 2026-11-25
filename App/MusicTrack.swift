import Foundation

struct MusicTrack: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    let artist: String
    var artwork: URL?
    var duration: Double = 0

    var durationLabel: String {
        guard duration.isFinite, duration > 0 else { return "" }
        return "\(Int(duration) / 60):" + String(format: "%02d", Int(duration) % 60)
    }
}
