import Foundation
import SwiftUI

/// Ephemeral playback only. No text, audio, profile changes or village saves.
@MainActor final class VillageSpeechMotion: ObservableObject {
    static let shared = VillageSpeechMotion()
    @Published private(set) var agentID: UUID?
    @Published private(set) var speaking = false
    @Published private(set) var pulse: SpeechMouthPulse?
    @Published private(set) var audioLevel: SpeechAudioLevel?
    private var owner: UUID?
    private var interrupt: (() -> Void)?

    func begin(agentID: UUID?, interrupt: @escaping () -> Void) -> UUID {
        let previous = self.interrupt
        let token = UUID()
        owner = token
        self.interrupt = interrupt
        self.agentID = agentID
        speaking = false
        pulse = nil
        audioLevel = nil
        previous?()
        return token
    }

    func setSpeaking(_ value: Bool, owner: UUID) {
        guard self.owner == owner else { return }
        speaking = value
        if !value { pulse = nil; audioLevel = nil }
    }

    func word(length: Int, rate: Double, owner: UUID, at date: Date = .now) {
        guard self.owner == owner, agentID != nil else { return }
        speaking = true
        pulse = SpeechMouthPulse(start: date, length: length, rate: rate)
    }

    func end(owner: UUID) {
        guard self.owner == owner else { return }
        self.owner = nil
        interrupt = nil
        speaking = false
        pulse = nil
        audioLevel = nil
        agentID = nil
    }

    func isSpeaking(_ id: String) -> Bool {
        guard speaking, let agentID, let requested = UUID(uuidString: id) else { return false }
        return agentID == requested
    }

    func audio(decibels: Double, owner: UUID, at date: Date = .now) {
        guard self.owner == owner, agentID != nil else { return }
        speaking = true
        audioLevel = SpeechAudioLevel(decibels: decibels, date: date)
    }

    func mouth(for id: String, at date: Date) -> Double {
        guard isSpeaking(id) else { return 0 }
        if let audioLevel { return audioLevel.openness(at: date) }
        return pulse?.openness(at: date) ?? 0
    }
}

struct SpeechAudioLevel {
    let decibels: Double
    let date: Date

    func openness(at now: Date) -> Double {
        guard decibels.isFinite, now >= date, now.timeIntervalSince(date) < 0.2 else { return 0 }
        return min(1, max(0, (decibels + 45) / 35))
    }
}

/// Word-boundary animation, not phoneme detection. It closes between words,
/// on pause, and at completion; no timer runs independently of playback.
struct SpeechMouthPulse {
    let start: Date
    let duration: Double

    init(start: Date, length: Int, rate: Double) {
        self.start = start
        let speed = rate.isFinite ? min(1.3, max(0.7, rate)) : 1
        duration = min(0.8, max(0.16, Double(max(1, min(30, length))) * 0.045 / speed))
    }

    func openness(at date: Date) -> Double {
        let elapsed = date.timeIntervalSince(start)
        guard elapsed >= 0, elapsed < duration else { return 0 }
        let envelope = min(1, elapsed / 0.04) * min(1, (duration - elapsed) / 0.07)
        return max(0, min(1, (0.25 + 0.75 * abs(sin(elapsed * 22))) * envelope))
    }
}

enum VillageBlink {
    static func closed(id: String, at date: Date) -> Bool {
        let hash = id.utf8.reduce(UInt64(5381)) { ($0 &* 33) &+ UInt64($1) }
        let phase = Double(hash % 500) / 100
        let elapsed = (date.timeIntervalSinceReferenceDate + phase).truncatingRemainder(dividingBy: 5.3)
        return elapsed >= 0 && elapsed < 0.16
    }
}
