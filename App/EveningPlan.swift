import Foundation

enum EveningPlan {
    enum Mood: String, CaseIterable, Codable, Identifiable {
        case calm = "Ro på", fun = "Godt humør", suspense = "Spænding", curious = "Oplev noget"
        var id: Self { self }
        var musicQuery: String {
            switch self {
            case .calm: "relaxing chill music"
            case .fun: "feel good music"
            case .suspense: "cinematic soundtrack"
            case .curious: "new indie music"
            }
        }
        var words: [String] {
            switch self {
            case .calm: ["chill", "calm", "relax", "acoustic", "rolig"]
            case .fun: ["party", "dance", "pop", "happy", "feel good"]
            case .suspense: ["thriller", "mystery", "cinematic", "suspense"]
            case .curious: ["indie", "discover", "new", "explore"]
            }
        }
    }
    struct Request: Equatable {
        var minutes = 90
        var mood = Mood.calm
        var offlineOnly = false
        static func parse(_ text: String) -> Self? {
            let value = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            guard value.range(of: #"^(?:(?:kan|vil) du (?:lige )?)?(gør min aften god|planlæg min aften|jeg keder mig|find på noget til i aften)\b"#,
                              options: .regularExpression) != nil,
                  !value.hasPrefix("ikke "), !value.contains("lad være") else { return nil }
            var result = Self()
            if let range = value.range(of: #"\b\d{1,3}\s*(minutter|min\b)"#, options: .regularExpression),
               let count = Int(value[range].prefix(while: \.isNumber)) { result.minutes = min(240, max(10, count)) }
            if value.contains("halvanden time") { result.minutes = 90 }
            else if value.contains("en halv time") { result.minutes = 30 }
            else if value.contains("en time") { result.minutes = 60 }
            if let mood = Mood.allCases.first(where: { value.contains($0.rawValue.lowercased()) || $0.words.contains(where: value.contains) }) { result.mood = mood }
            result.offlineOnly = value.contains("uden internet") || value.contains("helt offline")
            return result
        }
    }
    enum Kind: String, Codable { case film, music, village }
    struct Candidate: Identifiable, Equatable {
        let id: String
        let kind: Kind
        let title: String
        let detail: String
        var seconds: Double = 0
        var offline = false
        var keywords = ""
        var isSource = false
    }
    static func choices(_ candidates: [Candidate], request: Request) -> [Candidate] {
        var seen = Set<String>()
        let eligible = candidates.filter {
            !$0.title.isEmpty && seen.insert($0.id).inserted && (!request.offlineOnly || $0.offline)
                && ($0.seconds <= 0 || $0.seconds <= Double(request.minutes * 60))
        }
        func score(_ item: Candidate) -> Int {
            let haystack = (item.title + " " + item.keywords).lowercased()
            return request.mood.words.filter(haystack.contains).count * 10 + (item.offline ? 2 : 0) - (item.isSource ? 1 : 0)
        }
        let sorted = eligible.enumerated().sorted {
            score($0.element) == score($1.element) ? $0.offset < $1.offset : score($0.element) > score($1.element)
        }.map(\.element)
        var result: [Candidate] = []
        for kind in [Kind.film, .music, .village] {
            if let item = sorted.first(where: { $0.kind == kind }) { result.append(item) }
        }
        for item in sorted where result.count < 3 && !result.contains(where: { $0.id == item.id }) { result.append(item) }
        return Array(result.prefix(3))
    }
}
