import SwiftUI

@MainActor final class MusicHost {
    static let shared = MusicHost()
    private let speech = ChristelPlayer()
    private var announcements: [String: String] = [:]
    private var voiceID = ""
    func configure(_ values: [String: String], voice: String) { announcements = values; voiceID = voice }
    func clear() { announcements = [:]; stop() }
    func stop() { speech.stop() }
    func before(_ track: MusicTrack) async throws -> String? {
        guard let text = announcements.removeValue(forKey: track.id),
              let voice = DownloadedAgentVoice.selected(voiceID), AgentVoiceDownload.available(voice) else { return nil }
        speech.playDownloaded(text: String(text.prefix(300)), voice: voice, agentID: nil, language: "da-DK", rate: 1)
        do {
            while speech.loading || speech.playing { try await Task.sleep(for: .milliseconds(150)) }
            try Task.checkCancellation()
            return speech.notice
        } catch { speech.stop(); throw error }
    }
}
