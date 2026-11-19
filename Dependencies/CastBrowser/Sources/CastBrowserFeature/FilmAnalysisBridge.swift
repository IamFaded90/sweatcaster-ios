import Foundation

public typealias CastFilmAnalysis = @MainActor (CastFilmRequest) async throws -> CastFilmResult
/// An empty string stops the last answer when the viewer leaves or rewinds.
public typealias CastFilmSpeech = @MainActor (String, String) -> Void

public struct CastFilmRequest: Codable, Sendable {
    public let source: String
    public let origin: String?
    public let position: Double
    public let mode: String
    public let question: String?
    public let subtitles: [CastFilmResult.Cue]?
    public var userAgent: String?
}

public struct CastFilmResult: Codable, Sendable {
    public struct Cue: Codable, Sendable {
        public let start: Double
        public let end: Double
        public let text: String
    }
    public let cues: [Cue]
    public let detail: String
    public var answer: String?

    func completed(through position: Double) -> [FilmCue] {
        cues.prefix(64).compactMap {
            guard $0.start.isFinite, $0.end.isFinite, $0.start >= 0, $0.start < $0.end,
                  $0.end <= position, !$0.text.isEmpty else { return nil }
            return FilmCue(start: $0.start, end: $0.end, text: String($0.text.prefix(320)))
        }
    }
}
