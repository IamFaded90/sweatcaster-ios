import Foundation

struct FilmReceiverFrame: Equatable {
    struct Source: Equatable {
        let session: ObjectIdentifier
        let mediaID: Int
        let itemID: UInt
        let title: String
        let contentID: String?
        let subtitles: URL?
    }
    let source: Source
    let position: TimeInterval

    func stillApplies(to current: Self?) -> Bool {
        guard let current else { return false }
        return current.source == source && current.position >= position
    }
}

struct FilmCue: Equatable, Sendable {
    let start: TimeInterval
    let end: TimeInterval
    let text: String
}

enum FilmDialogue {
    enum ReadError: Error { case unknownTimeline }

    /// Only complete, timed dialogue reaches search or the optional on-device selector.
    static func completed(in source: String, through position: TimeInterval) throws -> [FilmCue] {
        guard position.isFinite, position >= 0 else { return [] }
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{feff}", with: "")
        guard !normalized.localizedCaseInsensitiveContains("X-TIMESTAMP-MAP") else {
            throw ReadError.unknownTimeline
        }
        var cues: [FilmCue] = []
        var recognized = false
        for block in normalized.components(separatedBy: "\n\n") {
            let lines = block.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            guard let first = lines.first, !first.hasPrefix("NOTE"), !first.hasPrefix("WEBVTT"),
                  first != "STYLE", first != "REGION",
                  let timing = lines.prefix(2).firstIndex(where: { $0.contains("-->") }) else { continue }
            let limits = lines[timing].components(separatedBy: "-->")
            guard limits.count == 2, let start = seconds(limits[0]),
                  let endToken = limits[1].split(whereSeparator: { $0.isWhitespace }).first,
                  let end = seconds(String(endToken)), end > start else { continue }
            // A missing block separator must never append a later cue to an earlier one.
            let payload = lines.dropFirst(timing + 1)
            guard !payload.contains(where: { $0.contains("-->") }) else { continue }
            recognized = true
            guard end <= position else { continue }
            let text = payload.joined(separator: " ")
                .replacingOccurrences(of: "<v(?:\\.[^ >]+)* ([^>]{1,80})>", with: "$1: ", options: .regularExpression)
                .replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
                .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&nbsp;", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { cues.append(FilmCue(start: start, end: end, text: String(text.prefix(320)))) }
        }
        guard recognized else { throw ReadError.unknownTimeline }
        return cues.sorted { $0.start < $1.start }
    }

    private static func seconds(_ token: String) -> TimeInterval? {
        let fields = token.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
            .split(separator: ":", omittingEmptySubsequences: false)
        guard (2...3).contains(fields.count) else { return nil }
        let fraction = fields.last!.split(separator: ".", omittingEmptySubsequences: false)
        let minutes = fields[fields.count - 2]
        guard fraction.count == 2, fraction[0].count == 2, fraction[1].count == 3, minutes.count == 2,
              let sec = unsigned(fraction[0]), sec < 60, let millis = unsigned(fraction[1]),
              let min = unsigned(minutes), min < 60 else { return nil }
        var hours = 0
        if fields.count == 3 {
            guard fields[0].count <= 6, let numeric = unsigned(fields[0]) else { return nil }
            hours = numeric
        }
        return TimeInterval(hours * 3600 + min * 60 + sec) + TimeInterval(millis) / 1000
    }

    private static func unsigned(_ text: Substring) -> Int? {
        guard !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        return Int(text)
    }

    static func recent(_ cues: [FilmCue], at position: TimeInterval) -> [FilmCue] {
        Array(cues.filter { $0.end <= position && $0.end >= position - 120 }.suffix(4))
    }

    private static let filler = Set("""
        af at den denne der deres det de dig du en er et far fik for fra har havde han ham hun hende
        hovedpersonen hvad hvem hvordan hvorfor hvor her jeg kender kendte lige man med mig min mødt
        mødte noget nu og om på sagde sig sin som til ved var vi he him her she what who where did
        know does from the how they is a an was say said about kommer fortæl person mand kvinde
        """.split(whereSeparator: { $0.isWhitespace }).map(String.init))

    private static func words(_ text: String) -> Set<String> {
        Set(text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
    }

    static func keywords(_ question: String) -> Set<String> { words(question).subtracting(filler) }

    static func isRecap(_ question: String) -> Bool {
        let terms = words(question)
        let requests = ["hvad blev der sagt", "hvad blev der lige sagt", "hvad skete der",
                        "hvad skete der lige", "hvad sagde de", "hvad sagde han", "hvad sagde hun",
                        "hvad sagde de lige", "gentag sidste replik", "what just happened",
                        "what did they say", "what did he say", "what did she say"]
        return requests.contains { terms == words($0) }
    }

    static func isSceneQuestion(_ question: String) -> Bool {
        let terms = words(question)
        if !terms.isDisjoint(with: ["scene", "scenen", "billedet", "vred", "sur", "angry", "ked", "udtryk", "skete", "happened", "wearing"]) { return true }
        return terms.isSuperset(of: ["hvad", "laver"]) || terms.isSuperset(of: ["hvad", "sker"])
    }

    static func isPauseRequest(_ question: String) -> Bool {
        let normalized = question.lowercased().split(whereSeparator: { !$0.isLetter }).joined(separator: " ")
        return ["pause", "pause filmen", "paus filmen", "sæt filmen på pause", "sæt på pause", "pause the movie"].contains(normalized)
    }

    /// Include neighbouring dialogue so an answer such as “from school” can be found after a name.
    static func evidence(_ cues: [FilmCue], for question: String) -> [FilmCue] {
        let wanted = keywords(question)
        guard !wanted.isEmpty else { return [] }
        let matches = cues.indices.compactMap { index -> (index: Int, count: Int)? in
            let count = words(cues[index].text).intersection(wanted).count
            return count > 0 ? (index, count) : nil
        }.sorted { $0.count == $1.count ? $0.index > $1.index : $0.count > $1.count }
        var indices = Set<Int>()
        for match in matches.prefix(7) {
            for offset in -1...2 {
                let index = match.index + offset
                if cues.indices.contains(index), abs(cues[index].start - cues[match.index].start) <= 20 {
                    indices.insert(index)
                }
            }
        }
        return indices.sorted().map { cues[$0] }
    }

    /// A neighbouring response can explain a name even when that line does not repeat it.
    static func excerpt(_ cues: [FilmCue], for question: String) -> [FilmCue] {
        let terms = keywords(question)
        guard let hit = cues.indices.last(where: { !words(cues[$0].text).isDisjoint(with: terms) }) else { return [] }
        return Array(cues[hit...].prefix(3).prefix { $0.start - cues[hit].end <= 12 })
    }

    /// A selector can point at existing local lines. Its own words never become an answer.
    static func selected(_ reply: String, from cues: [FilmCue]) -> [FilmCue] {
        let pieces = reply.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ",", omittingEmptySubsequences: false)
        guard (1...3).contains(pieces.count) else { return [] }
        var indices = Set<Int>()
        for piece in pieces {
            guard let number = Int(piece.trimmingCharacters(in: .whitespaces)), number > 0, number <= cues.count else { return [] }
            indices.insert(number - 1)
        }
        return indices.sorted().map { cues[$0] }
    }
}
