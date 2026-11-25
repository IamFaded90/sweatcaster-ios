import Foundation

enum SongPrompt {
    /// Adds a musical starting point to short requests without overwriting explicit choices.
    static func expanded(_ prompt: String, instrumental: Bool) -> String {
        let original = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !original.isEmpty else { return "" }
        let words = original.split(whereSeparator: \.isWhitespace)
        guard words.count <= 25 else { return original }
        let normalized = original.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en"))
        let genres: [(String, [String])] = [
            (#"\b(?:hip[ -]?hop|rap)\b"#, ["hip-hop production", "warm melodic texture", "defined verse and hook", "balanced, dynamic mix"]),
            (#"\btrap\b"#, ["modern trap production", "dark melodic atmosphere", "spacious arrangement", "clean low-end separation"]),
            (#"\b(?:lo[ -]?fi|lofi)\b"#, ["lo-fi production", "warm, intimate texture", "subtle variation", "gentle high frequencies"]),
            (#"\bhouse\b"#, ["house music", "gradually evolving layers", "clear arrangement with a memorable hook", "balanced club-ready mix"]),
            (#"\btechno\b"#, ["techno", "evolving rhythmic texture", "controlled transitions and tension", "clean, spacious mix"]),
            (#"\bjazz\b"#, ["jazz", "expressive phrasing", "natural room ambience", "clear interplay between instruments"]),
            (#"\brock\b"#, ["rock", "energetic arrangement with a strong hook", "dynamic verse-to-chorus contrast", "clear instrument separation"]),
            (#"\bpop\b"#, ["pop", "memorable melodic hook", "distinct verse and chorus", "polished, balanced mix"]),
            (#"\bambient\b"#, ["ambient", "slowly evolving textures", "gentle transitions", "wide, spacious sound"])
        ]
        guard let genre = genres.first(where: { normalized.range(of: $0.0, options: .regularExpression) != nil }) else { return original }
        var additions = genre.1
        let noSections = normalized.range(of: #"(?:uden|ingen|no|without)\s+(?:\w+\s+)?(?:omkvæd|omkvaed|vers|chorus|hook|verse)\b"#, options: .regularExpression) != nil
        if noSections {
            additions.removeAll { $0.contains("verse") || $0.contains("chorus") || $0.contains("hook") }
        }
        if normalized.range(of: #"\b(?:mørk|mork|kold|dark|cold|aggressiv)\w*"#, options: .regularExpression) != nil {
            additions.removeAll { $0.contains("warm") || $0.contains("gentle") }
        }
        let noDrums = normalized.range(of: #"(?:uden|ingen|no|without)\s+(?:\w+\s+)?(?:trommer|drums|beat)|drumless"#, options: .regularExpression) != nil
        let noBass = normalized.range(of: #"(?:uden|ingen|no|without)\s+(?:\w+\s+)?(?:bas|bass)\b"#, options: .regularExpression) != nil
        let hasTempo = normalized.range(of: #"\b\d{2,3}\s*(?:bpm|beats)|\b(?:langsom|hurtig|slow|fast)\w*"#, options: .regularExpression) != nil
        let hasRhythm = normalized.range(of: #"\b(?:swing|straight|lige|skæv|skaev|trommer|drums|breakbeat)\b"#, options: .regularExpression) != nil
        if normalized.range(of: genres[0].0, options: .regularExpression) != nil {
            if !hasTempo { additions.append("relaxed mid-tempo feel") }
            if !noDrums && !hasRhythm { additions.append("punchy drums with a laid-back swing") }
            if !noBass { additions.append("deep, controlled bass") }
        }
        if noDrums { additions.append("no drums or percussion") }
        if noBass { additions.append("no bass instruments") }
        if instrumental { additions.append("instrumental, no vocals or spoken words") }
        return String((original + "\n\nMusical detail: " + additions.joined(separator: "; ") + ".").prefix(1_500))
    }
}
