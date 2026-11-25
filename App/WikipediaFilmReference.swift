import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Public article metadata; no film plot is fetched for cast or actor questions.
enum WikipediaFilmReference {
    struct Page {
        let title: String; let url: URL; let text: String; let names: [String]
        var relatedURLs: [URL] = []
    }
    enum Failure: LocalizedError {
        case unavailable
        var errorDescription: String? { "Filmoplysningerne kunne ikke hentes lige nu. Prøv igen eller ret navnet/titlen." }
    }
    static func cast(movie: String) async throws -> Page {
        let title = try await find(String(movie.prefix(200)) + " film")
        let section = try await section(title, matching: ["cast", "voice cast", "cast and characters"])
        let text = try await wikitext(title, section: section)
        let names = castNames(text)
        guard !names.isEmpty else { throw Failure.unavailable }
        return .init(title: title, url: article(title), text: text, names: names)
    }
    static func actor(_ name: String) async throws -> Page {
        let title = try await find(String(name.prefix(120)) + " actor")
        let result = try await get(["action": "query", "prop": "extracts", "titles": title, "redirects": "1", "exintro": "1", "explaintext": "1"])
        let pages = (result["query"] as? [String: Any])?["pages"] as? [String: Any] ?? [:]
        let intro = pages.values.compactMap { ($0 as? [String: Any])?["extract"] as? String }.first ?? ""
        guard !intro.isEmpty else { throw Failure.unavailable }
        var films = ""
        var related: [URL] = []
        if let index = try? await section(title, matching: ["filmography", "selected filmography"]) {
            films = (try? await wikitext(title, section: index)) ?? ""
            if let linked = filmographyReference(films), linked != title,
               let credits = try? await wikitext(linked) {
                films = credits
                related = [article(linked)]
            }
        }
        return .init(title: title, url: article(title), text: String(intro.prefix(4_000)) + "\n\nFilmografi:\n" + String(films.prefix(8_000)), names: [], relatedURLs: related)
    }
    static func filmographyReference(_ source: String) -> String? {
        let pattern = #"(?i)\{\{\s*(?:main|see also|further)\s*\|\s*([^|}\n]{1,160})"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        for match in regex.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
            guard let range = Range(match.range(at: 1), in: source) else { continue }
            let title = source[range].trimmingCharacters(in: .whitespacesAndNewlines)
            if title.lowercased().contains("filmography"), !title.contains(":"), !title.contains("#"), !title.contains("[") {
                return title
            }
        }
        return nil
    }
    static func castNames(_ source: String) -> [String] {
        let pattern = #"(?m)^\s*\*+\s*(?:'{2,3})?\[\[([^\]|#:\n]{1,120})(?:\|([^\]\n]{1,100}))?\]\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        var seen = Set<String>()
        return Array(regex.matches(in: source, range: NSRange(source.startIndex..., in: source)).compactMap { match in
            let chosen = match.range(at: 2).location == NSNotFound ? 1 : 2
            guard let range = Range(match.range(at: chosen), in: source) else { return nil }
            let display = String(source[range]).components(separatedBy: " (")[0].trimmingCharacters(in: .whitespacesAndNewlines)
            guard (2...100).contains(display.count), seen.insert(display.lowercased()).inserted else { return nil }
            return display
        }.prefix(20))
    }
    private static func find(_ query: String) async throws -> String {
        let value = try await get(["action": "query", "list": "search", "srsearch": query, "srnamespace": "0", "srlimit": "3"])
        guard let rows = (value["query"] as? [String: Any])?["search"] as? [[String: Any]], let title = rows.first?["title"] as? String else { throw Failure.unavailable }
        return title
    }
    private static func section(_ title: String, matching names: [String]) async throws -> String {
        let value = try await get(["action": "parse", "page": title, "prop": "sections", "redirects": "1"])
        guard let rows = (value["parse"] as? [String: Any])?["sections"] as? [[String: Any]],
              let row = rows.first(where: { names.contains(($0["line"] as? String ?? "").lowercased()) }),
              let index = row["index"] as? String, index.range(of: #"^\d+$"#, options: .regularExpression) != nil else { throw Failure.unavailable }
        return index
    }
    private static func wikitext(_ title: String, section: String? = nil) async throws -> String {
        var arguments = ["action": "parse", "page": title, "prop": "wikitext", "redirects": "1"]
        if let section { arguments["section"] = section }
        let value = try await get(arguments)
        guard let result = value["parse"] as? [String: Any], let item = result["wikitext"] as? [String: Any], let text = item["*"] as? String else { throw Failure.unavailable }
        return String(text.prefix(20_000))
    }
    private static func article(_ title: String) -> URL { URL(string: "https://en.wikipedia.org/wiki/")!.appendingPathComponent(title.replacingOccurrences(of: " ", with: "_")) }
    private static func get(_ input: [String: String]) async throws -> [String: Any] {
        var components = URLComponents(string: "https://en.wikipedia.org/w/api.php")!
        var args = input; args["format"] = "json"
        components.queryItems = args.sorted { $0.key < $1.key }.map { .init(name: $0.key, value: $0.value) }
        guard let url = components.url else { throw Failure.unavailable }
        var request = URLRequest(url: url); request.timeoutInterval = 15
        request.setValue("FadedAI/1.0 (personal iOS film companion; https://github.com/IamFaded90/sweatcaster-ios)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, http.url?.host == "en.wikipedia.org", data.count < 1_000_000,
              let value = try JSONSerialization.jsonObject(with: data) as? [String: Any], value["error"] == nil else { throw Failure.unavailable }
        return value
    }
}
