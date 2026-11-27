import Foundation

/// Documented Vidora embed routes. Rebuild the URL rather than forwarding pasted query parameters.
struct VidoraReference: Equatable {
    enum Kind: String, CaseIterable { case movie, tv }
    let kind: Kind
    let id: Int
    var season = 1
    var episode = 1

    init?(input: String, kind: Kind = .movie, season: Int = 1, episode: Int = 1) {
        let clean = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count <= 2_000, (1...1_000).contains(season), (1...10_000).contains(episode) else { return nil }
        if let number = Int(clean), (1...Int(Int32.max)).contains(number) {
            self.kind = kind; id = number; self.season = season; self.episode = episode
            return
        }
        guard let url = URL(string: clean), url.scheme == "https", url.user == nil, url.password == nil,
              url.port == nil, let host = url.host?.lowercased(),
              ["vidora.ac", "www.vidora.ac", "themoviedb.org", "www.themoviedb.org"].contains(host) else { return nil }
        let parts = url.path.split(separator: "/")
        guard parts.count >= 2, let route = Kind(rawValue: String(parts[0])),
              let number = Int(parts[1].split(separator: "-", omittingEmptySubsequences: false).first ?? ""),
              (1...Int(Int32.max)).contains(number) else { return nil }
        self.kind = route; id = number; self.season = season; self.episode = episode
        if host == "vidora.ac" || host == "www.vidora.ac" {
            guard parts.count == (route == .movie ? 2 : 4), Int(parts[1]) != nil else { return nil }
        }
        if route == .tv && host.contains("vidora") && parts.count >= 4 {
            guard let season = Int(parts[2]), let episode = Int(parts[3]),
                  (1...1_000).contains(season), (1...10_000).contains(episode) else { return nil }
            self.season = season; self.episode = episode
        } else if route == .tv, parts.count >= 6, parts[2] == "season", parts[4] == "episode" {
            guard let season = Int(parts[3]), let episode = Int(parts[5]),
                  (1...1_000).contains(season), (1...10_000).contains(episode) else { return nil }
            self.season = season; self.episode = episode
        }
    }

    var playerURL: URL {
        var url = URLComponents()
        url.scheme = "https"; url.host = "vidora.ac"
        url.path = kind == .movie ? "/movie/\(id)" : "/tv/\(id)/\(season)/\(episode)"
        url.queryItems = [
            .init(name: "primaryColor", value: "4596FB"),
            .init(name: "secondaryColor", value: "1C2D4C"),
            .init(name: "iconColor", value: "D8E9FF"),
            .init(name: "title", value: "true"), .init(name: "poster", value: "true"),
            .init(name: "autoplay", value: "false"),
            .init(name: "nextbutton", value: kind == .tv ? "true" : "false")
        ]
        return url.url! // All components are constants or validated positive integers.
    }
}
