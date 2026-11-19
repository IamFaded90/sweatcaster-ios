import Foundation
import YouTubeKit

struct MusicTrack: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    let artist: String
    var artwork: URL?
    var duration: Double = 0

    var durationLabel: String {
        guard duration.isFinite, duration > 0 else { return "" }
        return "\(Int(duration) / 60):" + String(format: "%02d", Int(duration) % 60)
    }
}

enum MusicCatalog {
    enum Failure: LocalizedError {
        case unavailable, noAudio, badResponse
        var errorDescription: String? {
            switch self {
            case .unavailable: "Musikkilden kunne ikke åbnes. Prøv igen om lidt."
            case .noAudio: "Denne sang har ingen lyd, afspilleren kan åbne. Prøv en anden udgave."
            case .badResponse: "Musikkilden svarede i et ukendt format."
            }
        }
    }

    static func search(_ query: String) async throws -> [MusicTrack] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 250 else { return [] }
        var parts = URLComponents(string: "https://www.youtube.com/results")!
        parts.queryItems = [.init(name: "search_query", value: text), .init(name: "sp", value: "EgIQAQ==")]
        var request = URLRequest(url: parts.url!)
        request.timeoutInterval = 20
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/131.0.0.0 Safari/537.36",
                         forHTTPHeaderField: "User-Agent")
        request.setValue("da,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, data.count < 8_000_000,
              let html = String(data: data, encoding: .utf8) else { throw Failure.unavailable }
        return try tracks(in: html)
    }

    // Read the same public video catalogue used by Spotube's built-in NewPipe provider.
    // No Spotify account, contents or listening history is involved.
    static func tracks(in html: String) throws -> [MusicTrack] {
        guard let marker = html.range(of: "ytInitialData") else { throw Failure.badResponse }
        let tail = html[marker.upperBound...]
        guard let start = tail.firstIndex(of: "{") else { throw Failure.badResponse }
        var depth = 0, inString = false, escaped = false
        var end: String.Index?
        for index in html[start...].indices {
            let c = html[index]
            if inString {
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == "\"" { inString = false }
            } else if c == "\"" { inString = true }
            else if c == "{" { depth += 1 }
            else if c == "}" {
                depth -= 1
                if depth == 0 { end = html.index(after: index); break }
            }
        }
        guard let end, let data = String(html[start..<end]).data(using: .utf8) else { throw Failure.badResponse }
        let value = try JSONSerialization.jsonObject(with: data)
        var result: [MusicTrack] = [], seen = Set<String>()
        func label(_ value: Any?) -> String {
            guard let item = value as? [String: Any] else { return "" }
            if let text = item["simpleText"] as? String { return text }
            return (item["runs"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined()
        }
        func visit(_ value: Any, depth: Int) {
            guard depth < 50, result.count < 40 else { return }
            if let item = value as? [String: Any] {
                if let video = item["videoRenderer"] as? [String: Any],
                   let id = video["videoId"] as? String, id.range(of: #"^[A-Za-z0-9_-]{11}$"#, options: .regularExpression) != nil,
                   seen.insert(id).inserted {
                    let title = label(video["title"])
                    let duration = label(video["lengthText"]).split(separator: ":").reduce(0.0) { $0 * 60 + (Double($1) ?? 0) }
                    let images = (video["thumbnail"] as? [String: Any])?["thumbnails"] as? [[String: Any]]
                    let artwork = images?.last?["url"] as? String
                    if !title.isEmpty {
                        result.append(.init(id: id, title: title, artist: label(video["ownerText"]),
                                            artwork: artwork.flatMap(URL.init(string:)), duration: duration))
                    }
                }
                for key in item.keys.sorted() { if let child = item[key] { visit(child, depth: depth + 1) } }
            } else if let items = value as? [Any] { items.forEach { visit($0, depth: depth + 1) } }
        }
        visit(value, depth: 0)
        return result
    }

    static func audio(_ track: MusicTrack) async throws -> URL {
        // Spotube selects audio streams separately from video. Use an iPhone-compatible
        // extractor and AAC/MP4 selection so AVPlayer handles background playback.
        let streams = try await YouTube(videoID: track.id).streams
        guard let stream = streams.filterAudioOnly().filter({ $0.fileExtension == .m4a || $0.fileExtension == .mp4 })
            .highestAudioBitrateStream() else { throw Failure.noAudio }
        return stream.url
    }
}
