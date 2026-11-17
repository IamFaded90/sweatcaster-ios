import SwiftUI
import WebKit
import GoogleCast
import Combine
import UIKit
import AVFoundation

public typealias CastPCRelay = @MainActor (URL, URL?) async throws -> URL

enum CastMediaRoute: String {
    case direct, pc, phone
}

@MainActor
final class CastAppModel: NSObject, ObservableObject, @preconcurrency GCKSessionManagerListener {
    @Published var recentCasts: [RecentCast] = []
    private var recordedRecentAttempt: UUID?
    @Published var selectedTab: AppTab = .home
    @Published var videos: [VideoCandidate] = []
    @Published var queue: [VideoCandidate] = [] { didSet { persist(queue, key: "queue") } }
    @Published var bookmarks: [BrowserLink] = [] { didSet { persist(bookmarks, key: "bookmarks") } }
    @Published var history: [BrowserLink] = [] { didSet { persist(history, key: "history") } }
    @Published var status = "Åbn en side — kompatible videoer vises automatisk her."
    @Published var nowPlayingTitle = "Intet afspilles"
    @Published var currentPoster: String?
    @Published var deviceName: String?
    @Published var isPlaying = false
    @Published var playbackPosition: Double = 0
    @Published var playbackDuration: Double = 0
    @Published var receiverVolume: Double = 0.5
    @Published var hasSession = false
    @Published var receiverMuted = false
    @Published var hasSubtitleTracks = false
    @Published var diagnostics: [String] = [] { didSet { persist(diagnostics, key: "streamDiagnostics") } }
    @Published var is404TestRunning = false
    @Published var copy404TestMessage = "Start en video, og kopiér derefter 404-testen."
    @Published var resumePromptVideo: VideoCandidate?
    @Published var resumePromptPosition: Double = 0
    let browser = BrowserController()
    private var lastScanned = Set<String>()
    @Published private var verifiedAudioURLs = Set<String>()
    private var audioProbes = Set<String>()
    private var scanGeneration = UUID()

    var displayVideos: [VideoCandidate] {
        let candidates = videos.filter { $0.isDirect && ($0.hasAudioTrack == true || verifiedAudioURLs.contains($0.url)) }
        var seen = Set<String>()
        return candidates.sorted { ($0.isHLSMaster == true) && ($1.isHLSMaster != true) }.filter {
            seen.insert($0.pageURL + "|" + $0.title.lowercased()).inserted
        }
    }

    private func checkAudioTrack(_ video: VideoCandidate) {
        guard video.hasAudioTrack != true, video.isDirect,
              let url = URL(string: video.url),
              ["mp4", "webm", "mov", "m4v"].contains(url.pathExtension.lowercased()),
              audioProbes.insert(video.url).inserted else { return }
        let generation = scanGeneration
        browser.captureBrowserSession { [weak self] cookies, userAgent, _ in
            guard let self, self.scanGeneration == generation else { return }
            var options: [String: Any] = [AVURLAssetHTTPCookiesKey: cookies]
            if let userAgent { options[AVURLAssetHTTPUserAgentKey] = userAgent }
            let asset = AVURLAsset(url: url, options: options)
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { asset.cancelLoading() }
            Task { @MainActor in
                let tracks = try? await asset.loadTracks(withMediaType: .audio)
                guard self.scanGeneration == generation, tracks?.isEmpty == false else { return }
                self.verifiedAudioURLs.insert(video.url)
            }
        }
    }
    var pendingAutoCast: VideoCandidate?
    var pendingAutoCastDate: Date?
    var pendingAutoCastPosition: Double = 0
    private var resumePositions: [String: Double] = [:]
    private var lastPersistedProgressKey: String?
    private var lastPersistedProgressPosition: Double = 0
    var receiverErrorLogged = false
    @Published var castFeedback: String?
    @Published var canRetryCast = false
    private var observingCast = false
    var retryTarget: (video: VideoCandidate, position: Double)?
    var mediaRoute = CastMediaRoute.direct
    var pcRelay: CastPCRelay?
    var retryCount = 0
    var attemptID = UUID()
    var loadStarted: Date?
    var loadDelegate: CastRequestStatus?

    func observeCastSession() {
        guard !observingCast else { return }
        observingCast = true
        GCKCastContext.sharedInstance().sessionManager.add(self)
        refreshRemote()
    }

    func sessionManager(_ manager: GCKSessionManager, didResume session: GCKCastSession) {
        DispatchQueue.main.async {
            self.refreshRemote()
            if let state = session.remoteMediaClient?.mediaStatus?.playerState,
               state == .playing || state == .paused || state == .buffering {
                self.status = "Fortsat på TV"
            }
        }
    }

    func retryCast() {
        guard let target = retryTarget else { return }
        retryCount = 0
        mediaRoute = .direct
        startCast(target.video, initialPosition: target.position)
    }

    func recoverCast(_ id: UUID) {
        guard id == attemptID, let target = retryTarget else { return }
        if mediaRoute == .direct, pcRelay != nil {
            mediaRoute = .pc
            addDiagnostic("TV’et kunne ikke hente kilden direkte. Prøver via PC…")
            startCast(target.video, initialPosition: target.position)
            return
        }
        if mediaRoute != .phone {
            mediaRoute = .phone
            addDiagnostic("TV’et kunne ikke hente kilden direkte. Prøver via iPhone…")
            startCast(target.video, initialPosition: target.position)
            return
        }
        loadStarted = nil
        attemptID = UUID()
        let retryID = attemptID
        guard retryCount < 2, GCKCastContext.sharedInstance().sessionManager.currentCastSession != nil else {
            castFeedback = nil
            canRetryCast = true
            status = "Afspilningen kunne ikke fortsætte."
            return
        }
        retryCount += 1
        castFeedback = "Prøver igen…"
        addDiagnostic("Automatisk Cast-genforsøg \(retryCount) af 2.")
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(retryCount)) {
            guard self.attemptID == retryID else { return }
            self.startCast(target.video, initialPosition: target.position)
        }
    }

    func cancelCastRecovery() {
        attemptID = UUID()
        retryTarget = nil
        pendingAutoCast = nil
        pendingAutoCastDate = nil
        loadStarted = nil
        castFeedback = nil
        canRetryCast = false
    }

    override init() {
        super.init()
        queue = restore([VideoCandidate].self, key: "queue") ?? []
        bookmarks = restore([BrowserLink].self, key: "bookmarks") ?? [BrowserLink(title: "FMHY Video", url: "https://fmhy.net/video")]
        history = restore([BrowserLink].self, key: "history") ?? []
        diagnostics = restore([String].self, key: "streamDiagnostics") ?? []
        resumePositions = restore([String: Double].self, key: "resumePositions") ?? [:]
        recentCasts = restore([RecentCast].self, key: "recentCasts") ?? []
        if !UserDefaults.standard.bool(forKey: "castbrowser.fmhyStarterBookmarksV1") {
            let starters = [
                BrowserLink(title: "Movy", url: "https://www.movy.sx/"),
                BrowserLink(title: "Cinejoy", url: "https://cinejoy.pk/"),
                BrowserLink(title: "PopcornMovies", url: "https://popcornmovies.ac/"),
                BrowserLink(title: "7Movies", url: "https://7movies.ac/"),
                BrowserLink(title: "Atlantic", url: "https://atlantic.st/"),
                BrowserLink(title: "P-Stream Forks", url: "https://fmhy.net/video#p-stream-forks")
            ]
            for link in starters where !bookmarks.contains(where: { $0.url.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == link.url.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }) {
                bookmarks.append(link)
            }
            persist(bookmarks, key: "bookmarks")
            UserDefaults.standard.set(true, forKey: "castbrowser.fmhyStarterBookmarksV1")
        }
        browser.onVideo = { [weak self] video in self?.receive(video) }
        browser.onPageStarted = { [weak self] in self?.clearPageVideos() }
        browser.onPageLoaded = { [weak self] url, title in self?.recordPage(url: url, title: title) }
    }

    func openHome() {
        guard browser.webView.url == nil else { return }
        browser.load("https://fmhy.net/video")
    }

    func receive(_ video: VideoCandidate) {
        checkAudioTrack(video)
        if let index = videos.firstIndex(where: { $0.url == video.url }) {
            let current = videos[index]
            videos[index] = VideoCandidate(url: current.url, mime: current.mime.isEmpty ? video.mime : current.mime,
                                           title: current.title, pageTitle: current.pageTitle, pageURL: current.pageURL,
                                           poster: current.poster ?? video.poster, duration: max(current.duration, video.duration),
                                           isDirect: current.isDirect || video.isDirect,
                                           subtitles: current.subtitles.isEmpty ? video.subtitles : current.subtitles,
                                           isHLSMaster: current.isHLSMaster == true || video.isHLSMaster == true,
                                           hasAudioTrack: current.hasAudioTrack == true || video.hasAudioTrack == true)
            return
        }
        guard !lastScanned.contains(video.url) else { return }
        lastScanned.insert(video.url)
        videos.insert(video, at: 0)
        if videos.count > 100 { videos.removeLast(videos.count - 100) }
        status = "Fandt video på siden."
    }

    func clearPageVideos() {
        scanGeneration = UUID()
        videos.removeAll()
        lastScanned.removeAll()
        verifiedAudioURLs.removeAll()
        audioProbes.removeAll()
    }

    func addBookmark() {
        guard let url = browser.webView.url?.absoluteString else { return }
        let bookmark = BrowserLink(title: browser.webView.title?.trimmedOr("Bogmærke") ?? "Bogmærke", url: url)
        bookmarks.removeAll { $0.url == url }
        bookmarks.insert(bookmark, at: 0)
    }

    func removeBookmark(_ bookmark: BrowserLink) { bookmarks.removeAll { $0.id == bookmark.id } }
    func open(_ link: BrowserLink) { selectedTab = .browser; browser.load(link.url) }

    func searchOrLoad(_ text: String) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        if let url = URL(string: value), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) {
            browser.load(value)
        } else if value.contains(".") && !value.contains(" "), let url = URL(string: "https://" + value) {
            browser.load(url.absoluteString)
        } else if let query = value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            browser.load("https://www.google.com/search?q=" + query)
        }
    }

    func recordPage(url: URL?, title: String?) {
        guard let url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        let item = BrowserLink(title: title?.trimmedOr(url.host ?? "Website") ?? (url.host ?? "Website"), url: url.absoluteString)
        history.removeAll { $0.url == item.url }
        history.insert(item, at: 0)
        if history.count > 50 { history.removeLast(history.count - 50) }
    }

    func addToQueue(_ video: VideoCandidate) {
        guard video.isDirect else { return }
        if !queue.contains(where: { $0.url == video.url }) { queue.append(video) }
    }

    func removeFromQueue(at offsets: IndexSet) { queue.remove(atOffsets: offsets) }
    func moveInQueue(from source: IndexSet, to destination: Int) { queue.move(fromOffsets: source, toOffset: destination) }
    func clearQueue() { queue.removeAll() }

    func castRecent(_ item: RecentCast) {
        retryCount = 0
        mediaRoute = .direct
        let position = resumePositions[resumeKey(for: item.video.title)] ?? 0
        startCast(item.video, initialPosition: position)
    }

    private func rememberSuccessfulCast() {
        guard recordedRecentAttempt != attemptID, let target = retryTarget else { return }
        recordedRecentAttempt = attemptID
        let item = RecentCast(video: target.video, castAt: Date())
        recentCasts.removeAll { $0.id == item.id }
        recentCasts.insert(item, at: 0)
        recentCasts = Array(recentCasts.prefix(10))
        persist(recentCasts, key: "recentCasts")
    }

    func cast(_ video: VideoCandidate) {
        guard video.isDirect, let mediaURL = URL(string: video.url), ["http", "https"].contains(mediaURL.scheme?.lowercased() ?? "") else {
            status = "Denne afspiller har ikke et direkte videolink, der kan sendes til Chromecast."
            return
        }
        retryCount = 0
        mediaRoute = .direct
        let key = resumeKey(for: video.title)
        if let saved = resumePositions[key], saved >= 15 {
            resumePromptVideo = video
            resumePromptPosition = saved
            return
        }
        startCast(video, initialPosition: 0)
    }

    func chooseResume(continueFromSaved: Bool) {
        guard let video = resumePromptVideo else { return }
        let position = continueFromSaved ? resumePromptPosition : 0
        if !continueFromSaved { clearResume(for: video.title) }
        resumePromptVideo = nil
        resumePromptPosition = 0
        startCast(video, initialPosition: position)
    }

    func cancelResumePrompt() {
        resumePromptVideo = nil
        resumePromptPosition = 0
    }

    func castNextQueued() {
        guard let next = queue.first else { status = "Køen er tom."; return }
        queue.removeFirst()
        cast(next)
    }

    func refreshRemote() {
        let session = GCKCastContext.sharedInstance().sessionManager.currentCastSession
        hasSession = session != nil
        deviceName = session?.device.friendlyName
        if let started = loadStarted, Date().timeIntervalSince(started) > 45 {
            addDiagnostic("Cast-afspilning startede ikke inden for 45 sekunder.")
            recoverCast(attemptID)
            return
        }
        if let session {
            if let pending = pendingAutoCast {
                let position = pendingAutoCastPosition
                pendingAutoCast = nil
                pendingAutoCastPosition = 0
                pendingAutoCastDate = nil
                startCast(pending, initialPosition: position)
                return
            }
            receiverVolume = Double(session.currentDeviceVolume)
            receiverMuted = session.currentDeviceMuted
            if let media = session.remoteMediaClient?.mediaStatus {
                hasSubtitleTracks = media.mediaInformation?.mediaTracks?.contains(where: { $0.type == .text }) ?? false
                let receivedAttempt = (media.mediaInformation?.customData as? [String: String])?["fadedaiAttempt"]
                let matchesAttempt = retryTarget == nil || receivedAttempt == attemptID.uuidString
                isPlaying = media.playerState == .playing
                if matchesAttempt, isPlaying, let target = retryTarget,
                   media.mediaInformation?.metadata?.string(forKey: kGCKMetadataKeyTitle) == target.video.title {
                    rememberSuccessfulCast()
                }
                playbackPosition = max(0, media.streamPosition)
                playbackDuration = max(0, media.mediaInformation?.streamDuration ?? 0)
                if matchesAttempt && (media.playerState == .playing || media.playerState == .paused) {
                    if loadStarted != nil || castFeedback == "Bufferer…" || castFeedback == "Forbinder til TV…" { castFeedback = nil }
                    loadStarted = nil
                    if let target = retryTarget,
                       media.mediaInformation?.metadata?.string(forKey: kGCKMetadataKeyTitle) == target.video.title,
                       playbackPosition > target.position {
                        retryTarget = (target.video, playbackPosition)
                    }
                } else if media.playerState == .buffering {
                    castFeedback = "Bufferer…"
                }
                if matchesAttempt && media.playerState == .idle && media.idleReason == .error {
                    if !receiverErrorLogged && castFeedback != "Prøver igen…" && (loadStarted.map { Date().timeIntervalSince($0) > 2 } ?? true) {
                        receiverErrorLogged = true
                        let contentType = media.mediaInformation?.contentType ?? "ukendt"
                        addDiagnostic("Chromecast afspilningsfejl: idleReason=\(String(describing: media.idleReason)), playerState=\(String(describing: media.playerState)), contentType=\(contentType).")
                        recoverCast(attemptID)
                    }
                }
                if let title = media.mediaInformation?.metadata?.string(forKey: kGCKMetadataKeyTitle), !title.isEmpty {
                    nowPlayingTitle = title
                }
                if media.playerState == .playing || media.playerState == .paused || media.playerState == .buffering {
                    savePlaybackProgress()
                }
            }
        } else {
            savePlaybackProgress(force: true)
            if retryTarget != nil && pendingAutoCast == nil && !canRetryCast { castFeedback = "Forbinder til TV…" }
            if let since = pendingAutoCastDate, Date().timeIntervalSince(since) > 120 {
                pendingAutoCast = nil
                pendingAutoCastDate = nil
                castFeedback = nil
                canRetryCast = retryTarget != nil
                status = "Cast-valget blev lukket. Tryk Cast på videoen for at prøve igen."
            }
            receiverMuted = false
            hasSubtitleTracks = false
            isPlaying = false
            playbackPosition = 0
            playbackDuration = 0
        }
    }

    private func resumeKey(for title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func clearResume(for title: String) {
        resumePositions.removeValue(forKey: resumeKey(for: title))
        persist(resumePositions, key: "resumePositions")
    }

    func savePlaybackProgress(force: Bool = false) {
        let key = resumeKey(for: nowPlayingTitle)
        guard !key.isEmpty, key != resumeKey(for: "Intet afspilles"),
              playbackPosition.isFinite, playbackPosition >= 15 else { return }
        if playbackDuration > 0, playbackPosition >= playbackDuration - 20 {
            resumePositions.removeValue(forKey: "castbrowser." + key)
            persist(resumePositions, key: "resumePositions")
            return
        }
        if !force, lastPersistedProgressKey == key,
           abs(playbackPosition - lastPersistedProgressPosition) < 5 { return }
        resumePositions[key] = playbackPosition
        persist(resumePositions, key: "resumePositions")
        lastPersistedProgressKey = key
        lastPersistedProgressPosition = playbackPosition
    }

    func addDiagnostic(_ message: String) {
        status = message
        let entry = "\(Date.now.formatted(date: .omitted, time: .shortened))  \(message)"
        diagnostics.insert(entry, at: 0)
        if diagnostics.count > 80 { diagnostics.removeLast(diagnostics.count - 80) }
    }

    func hlsAudioFormatName(_ rawValue: Int) -> String {
        switch rawValue {
        case 1: return "AAC"
        case 2: return "AC3"
        case 3: return "MP3"
        case 4: return "TS"
        case 5: return "TS_AAC"
        case 6: return "E_AC3"
        case 7: return "FMP4"
        default: return "ukendt"
        }
    }

    func hlsVideoFormatName(_ rawValue: Int) -> String {
        switch rawValue {
        case 1: return "MPEG2_TS"
        case 2: return "FMP4"
        default: return "ukendt"
        }
    }

    private func persist<T: Encodable>(_ value: T, key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        UserDefaults.standard.set(data, forKey: "castbrowser." + key)
    }
    private func restore<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: "castbrowser." + key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

struct CastButton: UIViewRepresentable {
    func makeUIView(context: Context) -> GCKUICastButton {
        let button = GCKUICastButton(frame: .zero)
        button.tintColor = UIColor(Style.accent)
        return button
    }
    func updateUIView(_ uiView: GCKUICastButton, context: Context) { }
}

final class CastRequestStatus: NSObject, GCKRequestDelegate {
    static let shared = CastRequestStatus()
    var onComplete: (() -> Void)?
    var onFailure: ((GCKError) -> Void)?
    func requestDidComplete(_ request: GCKRequest) { onComplete?() }
    func request(_ request: GCKRequest, didFailWithError error: GCKError) { onFailure?(error) }
}

extension String {
    func trimmedOr(_ fallback: String) -> String { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallback : trimmingCharacters(in: .whitespacesAndNewlines) }
}

extension Double {
    var clockString: String {
        guard isFinite, self >= 0 else { return "0:00" }
        let seconds = Int(self.rounded())
        return seconds >= 3600 ? String(format: "%d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60) : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
