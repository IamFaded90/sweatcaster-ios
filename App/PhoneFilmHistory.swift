import Foundation

enum PhoneFilmHistory {
    struct Clip: Codable, Equatable {
        let filmID: String
        let position: Double
        let text: String
    }
    static let key = "fadedai.film.seen-clips.v1"
    static func clips(defaults: UserDefaults = .standard) -> [Clip] {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([Clip].self, from: $0) } ?? []
    }
    static func remember(_ text: String, context: PhoneFilmContext, defaults: UserDefaults = .standard) {
        guard context.position.isFinite, context.position >= 0, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        var values = clips(defaults: defaults).filter { !($0.filmID == context.id && abs($0.position - context.position) < 1) }
        values.append(.init(filmID: context.id, position: context.position, text: String(text.prefix(3_200))))
        if let data = try? JSONEncoder().encode(Array(values.suffix(60))) { defaults.set(data, forKey: key) }
    }
    static func seen(through context: PhoneFilmContext, defaults: UserDefaults = .standard) -> String {
        let eligible = clips(defaults: defaults).filter { $0.filmID == context.id && $0.position <= context.position }
            .sorted { $0.position < $1.position }.suffix(12)
        return String(eligible.map { "Ved \(Int($0.position)) sek.: \($0.text)" }.joined(separator: "\n\n").suffix(9_000))
    }
    static func forget(_ filmID: String, defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(clips(defaults: defaults).filter { $0.filmID != filmID }) { defaults.set(data, forKey: key) }
    }
}
