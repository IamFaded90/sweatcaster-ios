import Foundation

/// Keep the existing language-independent meter gate; Danish decoding remains Whisper.
struct AgentVoiceSilence {
    let pause: TimeInterval
    private var speechSamples = 0
    private var lastSpeech: TimeInterval?
    private var lastEvent: TimeInterval?
    init(pause: TimeInterval) { self.pause = pause.isFinite ? min(4, max(1.4, pause)) : 2.5 }
    mutating func ended(at time: TimeInterval, level: Float) -> Bool {
        guard time.isFinite, level.isFinite else { return false }
        if let lastEvent, time < lastEvent { speechSamples = 0; lastSpeech = nil }
        lastEvent = time
        if level >= -42 { speechSamples = min(3, speechSamples + 1); lastSpeech = time; return false }
        if speechSamples < 3 { speechSamples = 0 }
        return speechSamples == 3 && lastSpeech.map { time - $0 >= pause } == true
    }
}
