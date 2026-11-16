import Foundation
import NaturalLanguage

enum LocalTextRanking {
    private static func terms(in text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "da_DK"))
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }

    /// BM25 and reciprocal rank fusion, as in SQLiteVecKit's hybrid search.
    static func lexicalOrder(query: String, texts: [String]) throws -> [Int] {
        let queryTerms = Set(terms(in: query).prefix(64))
        guard !queryTerms.isEmpty, !texts.isEmpty else { return [] }
        var documentCounts: [String: Int] = [:]
        var counts: [(length: Int, hits: [String: Int])] = []
        for text in texts {
            try Task.checkCancellation()
            let words = terms(in: text)
            var hits: [String: Int] = [:]
            for word in words where queryTerms.contains(word) { hits[word, default: 0] += 1 }
            for word in hits.keys { documentCounts[word, default: 0] += 1 }
            counts.append((words.count, hits))
        }
        let meanLength = max(1, Double(counts.reduce(0) { $0 + $1.length }) / Double(counts.count))
        let total = Double(counts.count)
        let scores: [(index: Int, score: Double)] = counts.enumerated().compactMap { index, item in
            let lengthPenalty = 1.2 * (0.25 + 0.75 * Double(item.length) / meanLength)
            let score = item.hits.reduce(0.0) { sum, pair in
                let occurrences = Double(documentCounts[pair.key, default: 0])
                let frequency = Double(pair.value)
                let idf = log(1 + (total - occurrences + 0.5) / (occurrences + 0.5))
                return sum + idf * (frequency * 2.2 / (frequency + lengthPenalty))
            }
            return score > 0 ? (index, score) : nil
        }
        return scores.sorted { $0.score == $1.score ? $0.index < $1.index : $0.score > $1.score }.map(\.index)
    }

    static func fusedOrder(_ rankings: [[Int]], limit: Int) -> [Int] {
        var scores: [Int: Double] = [:]
        for order in rankings {
            for (rank, index) in order.enumerated() { scores[index, default: 0] += 1 / Double(61 + rank) }
        }
        return Array(scores.keys.sorted {
            let left = scores[$0, default: 0]
            let right = scores[$1, default: 0]
            return left == right ? $0 < $1 : left > right
        }.prefix(limit))
    }

    /// Work with the installed Latin language model. Callers run this off the UI thread.
    static func installedEmbedding() -> NLContextualEmbedding? {
        guard let model = NLContextualEmbedding(language: .danish), model.hasAvailableAssets else { return nil }
        do { try model.load() } catch { return nil }
        return model
    }

    /// VecturaKit uses normalized vectors so relevance is a dot product.
    static func vector(for text: String, using model: NLContextualEmbedding) -> [Float]? {
        guard let result = try? model.embeddingResult(for: text, language: nil) else { return nil }
        var sum = Array(repeating: 0.0, count: model.dimension)
        result.enumerateTokenVectors(in: result.string.startIndex..<result.string.endIndex) { vector, _ in
            guard vector.count == sum.count, !Task.isCancelled else { return false }
            for index in sum.indices { sum[index] += vector[index] }
            return true
        }
        let norm = sqrt(sum.reduce(0) { $0 + $1 * $1 })
        guard norm.isFinite, norm > 1e-10 else { return nil }
        return sum.map { Float($0 / norm) }
    }

    static func similarity(_ left: [Float], _ right: [Float]) -> Float? {
        guard left.count == right.count, !left.isEmpty else { return nil }
        let dot = zip(left, right).reduce(Float.zero) { $0 + $1.0 * $1.1 }
        return dot.isFinite ? dot : nil
    }
}
