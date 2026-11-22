import Foundation

// Adapted from Supertone Inc. under MIT. See the accompanying LICENSE.
func preprocessText(_ text: String, lang: String) -> String {
    // Use NFKD (decomposed) for proper Hangul Jamo decomposition
    var text = text.decomposedStringWithCompatibilityMapping

    // Remove emojis (wide Unicode range)
    // Swift NSRegularExpression doesn't support Unicode escapes above \uFFFF
    // Use character filtering instead
    text = text.unicodeScalars.filter { scalar in
        let value = scalar.value
        return !((value >= 0x1F600 && value <= 0x1F64F) ||
                 (value >= 0x1F300 && value <= 0x1F5FF) ||
                 (value >= 0x1F680 && value <= 0x1F6FF) ||
                 (value >= 0x1F700 && value <= 0x1F77F) ||
                 (value >= 0x1F780 && value <= 0x1F7FF) ||
                 (value >= 0x1F800 && value <= 0x1F8FF) ||
                 (value >= 0x1F900 && value <= 0x1F9FF) ||
                 (value >= 0x1FA00 && value <= 0x1FA6F) ||
                 (value >= 0x1FA70 && value <= 0x1FAFF) ||
                 (value >= 0x2600 && value <= 0x26FF) ||
                 (value >= 0x2700 && value <= 0x27BF) ||
                 (value >= 0x1F1E6 && value <= 0x1F1FF))
    }.map { String($0) }.joined()

    // Replace various dashes and symbols
    let replacements: [String: String] = [
        "–": "-",      // en dash
        "‑": "-",      // non-breaking hyphen
        "—": "-",      // em dash
        "_": " ",      // underscore
        "\u{201C}": "\"",     // left double quote
        "\u{201D}": "\"",     // right double quote
        "\u{2018}": "'",      // left single quote
        "\u{2019}": "'",      // right single quote
        "´": "'",      // acute accent
        "`": "'",      // grave accent
        "[": " ",      // left bracket
        "]": " ",      // right bracket
        "|": " ",      // vertical bar
        "/": " ",      // slash
        "#": " ",      // hash
        "→": " ",      // right arrow
        "←": " ",      // left arrow
    ]

    for (old, new) in replacements {
        text = text.replacingOccurrences(of: old, with: new)
    }

    // Remove special symbols
    let specialSymbols = ["♥", "☆", "♡", "©", "\\"]
    for symbol in specialSymbols {
        text = text.replacingOccurrences(of: symbol, with: "")
    }

    // Replace known expressions
    let exprReplacements: [String: String] = [
        "@": " at ",
        "e.g.,": "for example, ",
        "i.e.,": "that is, ",
    ]

    for (old, new) in exprReplacements {
        text = text.replacingOccurrences(of: old, with: new)
    }

    // Fix spacing around punctuation
    text = text.replacingOccurrences(of: " ,", with: ",")
    text = text.replacingOccurrences(of: " .", with: ".")
    text = text.replacingOccurrences(of: " !", with: "!")
    text = text.replacingOccurrences(of: " ?", with: "?")
    text = text.replacingOccurrences(of: " ;", with: ";")
    text = text.replacingOccurrences(of: " :", with: ":")
    text = text.replacingOccurrences(of: " '", with: "'")

    // Remove duplicate quotes
    while text.contains("\"\"") {
        text = text.replacingOccurrences(of: "\"\"", with: "\"")
    }
    while text.contains("''") {
        text = text.replacingOccurrences(of: "''", with: "'")
    }
    while text.contains("``") {
        text = text.replacingOccurrences(of: "``", with: "`")
    }

    // Remove extra spaces
    let whitespacePattern = try! NSRegularExpression(pattern: "\\s+")
    let whitespaceRange = NSRange(text.startIndex..., in: text)
    text = whitespacePattern.stringByReplacingMatches(in: text, range: whitespaceRange, withTemplate: " ")
    text = text.trimmingCharacters(in: .whitespacesAndNewlines)

    // If text doesn't end with punctuation, quotes, or closing brackets, add a period
    if !text.isEmpty {
        let punctPattern = try! NSRegularExpression(pattern: "[.!?;:,'\"\\u201C\\u201D\\u2018\\u2019)\\]}…。」』】〉》›»]$")
        let punctRange = NSRange(text.startIndex..., in: text)
        if punctPattern.firstMatch(in: text, range: punctRange) == nil {
            text += "."
        }
    }

    // Wrap text with language tags
    text = "<\(lang)>\(text)</\(lang)>"

    return text
}

func makeWave(_ audioData: [Float], _ sampleRate: Int) -> Data {

    // Convert float to int16
    let int16Data = audioData.map { sample -> Int16 in
        let clamped = max(-1.0, min(1.0, sample))
        return sample.isFinite ? Int16(clamped * 32767.0) : 0
    }

    // Create WAV header
    let numChannels: UInt16 = 1
    let bitsPerSample: UInt16 = 16
    let byteRate = UInt32(sampleRate) * UInt32(numChannels) * UInt32(bitsPerSample) / 8
    let blockAlign = numChannels * bitsPerSample / 8
    let dataSize = UInt32(int16Data.count * 2)

    var data = Data()

    // RIFF chunk
    data.append("RIFF".data(using: .ascii)!)
    withUnsafeBytes(of: UInt32(36 + dataSize).littleEndian) { data.append(contentsOf: $0) }
    data.append("WAVE".data(using: .ascii)!)

    // fmt chunk
    data.append("fmt ".data(using: .ascii)!)
    withUnsafeBytes(of: UInt32(16).littleEndian) { data.append(contentsOf: $0) }
    withUnsafeBytes(of: UInt16(1).littleEndian) { data.append(contentsOf: $0) } // PCM
    withUnsafeBytes(of: numChannels.littleEndian) { data.append(contentsOf: $0) }
    withUnsafeBytes(of: UInt32(sampleRate).littleEndian) { data.append(contentsOf: $0) }
    withUnsafeBytes(of: byteRate.littleEndian) { data.append(contentsOf: $0) }
    withUnsafeBytes(of: blockAlign.littleEndian) { data.append(contentsOf: $0) }
    withUnsafeBytes(of: bitsPerSample.littleEndian) { data.append(contentsOf: $0) }

    // data chunk
    data.append("data".data(using: .ascii)!)
    withUnsafeBytes(of: dataSize.littleEndian) { data.append(contentsOf: $0) }

    // audio data
    int16Data.withUnsafeBytes { data.append(contentsOf: $0) }

    return data
}
