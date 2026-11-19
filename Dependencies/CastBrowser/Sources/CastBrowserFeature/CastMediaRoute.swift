import Foundation

enum CastMediaRoute: String {
    case direct, pc, phone

    static func referringPage(_ page: URL?) -> URL? {
        guard let page, var parts = URLComponents(url: page, resolvingAgainstBaseURL: false),
              let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
              parts.host != nil, parts.user == nil, parts.password == nil else { return nil }
        parts.query = nil
        parts.fragment = nil
        return parts.url
    }

    static func order(page: URL?, browserPage: URL?, hasPC: Bool) -> [Self] {
        guard hasPC else { return [.direct, .phone] }
        let usesCinejoy = [page, browserPage].contains { url in
            guard let host = url?.host?.lowercased() else { return false }
            return host == "cinejoy.pk" || host.hasSuffix(".cinejoy.pk")
        }
        return usesCinejoy ? [.pc, .direct, .phone] : [.direct, .pc, .phone]
    }
}
