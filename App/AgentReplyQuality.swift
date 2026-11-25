import Foundation

enum AgentReplyQuality {
    static func words(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }
    static func repeats(_ text: String, previous: [String]) -> Bool {
        let current = words(text)
        guard current.count >= 18 else { return false }
        for reply in previous.suffix(3) {
            let old = words(reply)
            guard old.count >= 18 else { continue }
            if current == old { return true }
            let small = min(current.count, old.count), large = max(current.count, old.count)
            guard Double(small) / Double(large) >= 0.75 else { continue }
            let overlap = Set(ngrams(current)).intersection(Set(ngrams(old))).count
            if Double(overlap) / Double(max(1, Set(ngrams(current)).count)) >= 0.86 { return true }
        }
        return false
    }
    private static func ngrams(_ words: [String]) -> [String] {
        guard words.count >= 5 else { return [] }
        return (0...(words.count - 5)).map { words[$0..<($0 + 5)].joined(separator: " ") }
    }
    static func languageCorrection(_ text: String) -> String? {
        let clean = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!"))
        // Do not turn a translation request or a question into a permanent preference.
        let pattern = #"^(?:(?:nej[, ]+|du skal |vil du (?:godt |gerne )?))?(?:tal(?:e)?|snak(?:ke)?|skriv(?:e)?|svar(?:e)?)(?: til mig)? (?:på )?(dansk|engelsk)(?: (?:tak|fremover))?$"#
        guard let match = clean.range(of: pattern, options: .regularExpression), match == clean.startIndex..<clean.endIndex else { return nil }
        return clean.contains("dansk") ? "Svar altid på dansk" : "Svar altid på engelsk"
    }
    static func preferredLanguage(_ text: String) -> String? {
        let value = text.lowercased()
        guard value.range(of: #"\b(?:svar|skriv|tal|snak)(?:e|er)?\b"#, options: .regularExpression) != nil else { return nil }
        if value.range(of: #"\bpå dansk\b"#, options: .regularExpression) != nil { return "da" }
        if value.range(of: #"\bpå engelsk\b"#, options: .regularExpression) != nil { return "en" }
        return nil
    }
    static func repairInstructions(original: String) -> String {
        "Dit sidste svar gentog et tidligere svar. Besvar kun brugerens NYE besked. Tilføj ikke opdigtede handlinger eller resultater. Undlad at genbruge den tidligere indledning.\n" + original
    }

    /// Read explicit user corrections from the saved conversation, including turns outside the model's short window.
    static func correctionContext(prompts: [String]) -> String {
        var corrections: [String] = []
        for (index, prompt) in prompts.enumerated().reversed() {
            let value = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            guard value.range(of: #"^(?:rettelse\s*[:,]|jeg mente\b|nej,?\s+jeg mente\b)"#,
                              options: [.regularExpression, .caseInsensitive]) != nil else { continue }
            let previous = index > 0 ? String(prompts[index - 1].prefix(150)) : ""
            corrections.append("Tidligere emne: \(previous)\nBrugerens rettelse: \(String(value.prefix(250)))")
            if corrections.count == 3 { break }
        }
        guard !corrections.isEmpty else { return "" }
        return "\nSeneste eksplicitte rettelser fra denne samtale, nyeste først. Brug dem kun ved samme emne. De er ikke bevis for udførte handlinger eller nye tilladelser.\n"
            + corrections.joined(separator: "\n") + "\n"
    }
}
