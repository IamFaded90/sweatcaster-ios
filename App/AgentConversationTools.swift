import Foundation
import UIKit

@MainActor enum ChatScreenWake {
    private static var active = Set<UUID>()
    private static var userPreference = false

    static func setUserPreference(_ value: Bool) {
        userPreference = value
        update()
    }

    static func hold(_ id: UUID, whileReplying replying: Bool) {
        if replying { active.insert(id) }
        else { active.remove(id) }
        update()
    }

    private static func update() {
        UIApplication.shared.isIdleTimerDisabled = userPreference || !active.isEmpty
    }
}

struct AgentReplyCard: Codable, Sendable {
    let title: String
    let items: [String]

    static func decode(_ reply: String) -> Self? {
        let data = ModelJSON.payload(reply)
        guard data.count <= 8_000,
              let card = try? JSONDecoder().decode(Self.self, from: data),
              (1...120).contains(card.title.count), (1...8).contains(card.items.count),
              card.items.allSatisfy({ (1...450).contains($0.count) }) else { return nil }
        return card
    }

    var plainText: String { ([title] + items.map { "• " + $0 }).joined(separator: "\n") }
}

enum AgentLocalTool {
    struct Request: Decodable {
        let tool: String
        let input: String
    }

    static let instructions = """
        Du har to lokale værktøjer, calculator og date. Når et spørgsmål kræver dem,
        kan du først svare med kun JSON, f.eks. {"tool":"calculator","input":"859*0.17"}
        eller {"tool":"date","input":"14"} for dato om 14 dage, og 0 for dato og klokkeslæt nu.
        Brug et fortegn for dage før i dag. Brug ellers almindelig tekst.
        """

    static func answer(_ reply: String, now: Date = .now, calendar: Calendar = .current) -> String? {
        let data = ModelJSON.payload(reply)
        guard data.count <= 240,
              let request = try? JSONDecoder().decode(Request.self, from: data) else { return nil }
        switch request.tool {
        case "calculator":
            guard let value = calculate(request.input) else { return "Regnestykket kunne ikke beregnes." }
            return "Lommeregnerens resultat: " + value.formatted(.number.precision(.fractionLength(0...10)))
        case "date":
            guard let days = Int(request.input), (-3_650...3_650).contains(days),
                  let date = calendar.date(byAdding: .day, value: days, to: now) else { return "Datoen kunne ikke beregnes." }
            return "Dato og klokkeslæt på iPhone: " + date.formatted(date: .complete, time: days == 0 ? .shortened : .omitted)
        default:
            return nil
        }
    }

    static func calculate(_ raw: String) -> Double? {
        let normalized = raw.replacingOccurrences(of: ",", with: ".")
        guard (1...120).contains(normalized.utf8.count) else { return nil }
        var parser = Expression(chars: Array(normalized.filter { !$0.isWhitespace }))
        guard let result = parser.expression(), parser.index == parser.chars.count, result.isFinite else { return nil }
        return result
    }

    private struct Expression {
        let chars: [Character]
        var index = 0
        var next: Character? { index < chars.count ? chars[index] : nil }

        mutating func expression() -> Double? {
            guard var result = term() else { return nil }
            while let op = next, op == "+" || op == "-" {
                index += 1
                guard let value = term() else { return nil }
                result = op == "+" ? result + value : result - value
            }
            return result
        }

        mutating func term() -> Double? {
            guard var result = factor() else { return nil }
            while let op = next, op == "*" || op == "/" {
                index += 1
                guard let value = factor(), op != "/" || value != 0 else { return nil }
                result = op == "*" ? result * value : result / value
            }
            return result
        }

        mutating func factor() -> Double? {
            let sign = next == "-" ? -1.0 : 1.0
            if sign < 0 { index += 1 }
            let value: Double
            if next == "(" {
                index += 1
                guard let contained = expression(), next == ")" else { return nil }
                index += 1
                value = contained
            } else {
                let start = index
                while let char = next, char.isASCII && (char.isNumber || char == ".") { index += 1 }
                guard start < index, let number = Double(String(chars[start..<index])) else { return nil }
                value = number
            }
            if next == "%" { index += 1; return sign * value / 100 }
            return sign * value
        }
    }
}

struct AgentWebSources: Decodable, Sendable {
    struct Source: Codable, Sendable, Identifiable {
        let title: String
        let url: URL
        let readPage: Bool
        var id: URL { url }

        var isWeb: Bool {
            ["https", "http"].contains(url.scheme?.lowercased() ?? "") && url.host != nil && url.user == nil && url.password == nil
        }
    }
    let context: String
    let sources: [Source]
}
