import Foundation

/// Host access to saved pages. Media URLs with expiring signatures are never exported.
@MainActor public enum CastLibraryBridge {
    public struct Item: Identifiable {
        public let id: String
        public let title: String
        public let page: URL
        public let seconds: Double
        public let isSource: Bool
    }
    public static let openRequested = Notification.Name("FadedAICastOpenPage")
    public static let controlsRequested = Notification.Name("FadedAICastControls")
    public static let playbackChanged = Notification.Name("FadedAICastPlayback")
    public struct Playback {
        public let id: String
        public let title: String
        public let position: Double
        public let duration: Double
        public let playing: Bool
        public let route: String
    }
    public private(set) static var nowPlaying: Playback?
    private static var wantsControls = false
    private static weak var activeModel: CastAppModel?
    public static func recentDialogue() async throws -> String {
        guard let activeModel else { return "" }
        let result = try await activeModel.readFilmDialogue(question: nil, scene: false)
        return result.2.map { $0.text }.joined(separator: "\n")
    }
    private static var pending: URL?
    public static func items(defaults: UserDefaults = .standard) -> [Item] {
        let recent = defaults.data(forKey: "castbrowser.recentCasts")
            .flatMap { try? JSONDecoder().decode([RecentCast].self, from: $0) } ?? []
        let bookmarks = defaults.data(forKey: "castbrowser.bookmarks")
            .flatMap { try? JSONDecoder().decode([BrowserLink].self, from: $0) } ?? []
        var seen = Set<String>()
        var values: [Item] = []
        for item in recent {
            if let url = checked(item.video.pageURL), seen.insert(url.absoluteString).inserted {
                values.append(.init(id: url.absoluteString, title: item.video.title, page: url,
                                    seconds: item.video.duration.isFinite ? max(0, item.video.duration) : 0, isSource: false))
            }
        }
        for item in bookmarks {
            if let url = checked(item.url), seen.insert(url.absoluteString).inserted {
                values.append(.init(id: url.absoluteString, title: item.title, page: url, seconds: 0, isSource: true))
            }
        }
        return values
    }
    public static func open(_ page: URL) {
        guard let valid = checked(page.absoluteString) else { return }
        pending = valid
        NotificationCenter.default.post(name: openRequested, object: nil)
    }
    static func takePending() -> URL? { defer { pending = nil }; return pending }
    public static func showControls() {
        wantsControls = true
        NotificationCenter.default.post(name: controlsRequested, object: nil)
    }
    static func takeControls() -> Bool { defer { wantsControls = false }; return wantsControls }
    static func update(_ model: CastAppModel) {
        activeModel = model
        let identity = model.filmFrame.map { "\($0.source.session)|\($0.source.mediaID)|\($0.source.itemID)" } ?? model.nowPlayingTitle
        nowPlaying = model.hasActiveMedia ? Playback(id: identity, title: model.nowPlayingTitle,
            position: model.playbackPosition.isFinite ? max(0, model.playbackPosition) : 0,
            duration: model.playbackDuration.isFinite ? max(0, model.playbackDuration) : 0, playing: model.isPlaying, route: model.connectionTitle) : nil
        NotificationCenter.default.post(name: playbackChanged, object: nil)
    }
    private static func checked(_ text: String) -> URL? {
        guard let url = URL(string: text), ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil, url.user == nil, url.password == nil else { return nil }
        return url
    }
}
