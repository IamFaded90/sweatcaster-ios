import Foundation

enum MusicMix {
    struct Feedback: Codable, Equatable {
        var likes: [String] = []
        var skips: [String: Int] = [:]
        mutating func favorite(_ id: String, selected: Bool) {
            likes.removeAll { $0 == id }
            if selected { likes = Array((likes + [id]).suffix(300)); skips[id] = nil }
        }
        mutating func skip(_ id: String, position: Double, duration: Double) {
            guard position.isFinite, duration.isFinite, position >= 5, duration > 0, position / duration < 0.35 else { return }
            if skips.count >= 300, skips[id] == nil { return }
            skips[id] = min(5, (skips[id] ?? 0) + 1)
        }
    }
    static let key = "fadedai.music.feedback.v1"
    static func feedback(defaults: UserDefaults = .standard) -> Feedback {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(Feedback.self, from: $0) } ?? .init()
    }
    static func update(defaults: UserDefaults = .standard, _ change: (inout Feedback) -> Void) {
        var value = feedback(defaults: defaults); change(&value)
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }
    static func tracks(_ input: [MusicTrack], mood: EveningPlan.Mood, feedback: Feedback, limit: Int = 10) -> [MusicTrack] {
        var seen = Set<String>()
        let candidates = input.filter { seen.insert($0.id).inserted && $0.duration.isFinite && $0.duration >= 0 }
        func score(_ track: MusicTrack) -> Int {
            let text = (track.title + " " + track.artist).lowercased()
            return mood.words.filter(text.contains).count * 3 + (feedback.likes.contains(track.id) ? 5 : 0) - (feedback.skips[track.id] ?? 0) * 4
        }
        return Array(candidates.enumerated().sorted {
            score($0.element) == score($1.element) ? $0.offset < $1.offset : score($0.element) > score($1.element)
        }.prefix(max(0, min(30, limit))).map(\.element))
    }
    static func command(_ text: String) -> Bool {
        let value = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return value.range(of: #"^(?:(?:kan|vil) du (?:lige )?)?(?:lav(?:e)? (?:mig )?(?:et |mit )?(?:musikmix|miks|mix)|(?:start|sæt|spil) (?:noget )?(?:rolig |energisk |god |min )?musik|åbn musikværten)\b"#, options: .regularExpression) != nil
    }
}
