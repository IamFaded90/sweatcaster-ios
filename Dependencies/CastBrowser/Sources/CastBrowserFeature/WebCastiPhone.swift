import SwiftUI
import WebKit
import GoogleCast
import Combine
import UIKit
import AVFoundation

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
    private var pendingAutoCast: VideoCandidate?
    private var pendingAutoCastDate: Date?
    private var pendingAutoCastPosition: Double = 0
    private var resumePositions: [String: Double] = [:]
    private var lastPersistedProgressKey: String?
    private var lastPersistedProgressPosition: Double = 0
    private var receiverErrorLogged = false
    @Published var castFeedback: String?
    @Published var canRetryCast = false
    private var observingCast = false
    private(set) var retryTarget: (video: VideoCandidate, position: Double)?
    private var retryCount = 0
    private var attemptID = UUID()
    private var loadStarted: Date?

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
        startCast(target.video, initialPosition: target.position)
    }

    private func recoverCast(_ id: UUID) {
        guard id == attemptID, let target = retryTarget else { return }
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

    private func startCast(_ video: VideoCandidate, initialPosition: Double) {
        guard let mediaURL = URL(string: video.url), ["http", "https"].contains(mediaURL.scheme?.lowercased() ?? "") else { return }
        let id = UUID()
        attemptID = id
        retryTarget = (video, initialPosition)
        canRetryCast = false
        loadStarted = nil
        castFeedback = "Forbinder til TV…"
        receiverErrorLogged = false
        addDiagnostic("Nyt castforsøg: \(video.title)")
        guard let session = GCKCastContext.sharedInstance().sessionManager.currentCastSession else {
            pendingAutoCast = video
            pendingAutoCastPosition = initialPosition
            pendingAutoCastDate = Date()
            status = "Vælg din Chromecast — videoen starter automatisk bagefter."
            selectedTab = .remote
            let context = GCKCastContext.sharedInstance()
            context.discoveryManager.startDiscovery()
            context.presentCastDialog()
            return
        }
        castFeedback = "Indlæser…"
        status = "Forbereder videostream fra iPhone…"
        PhoneStreamProxy.shared.onActivity = { [weak self] message in
            DispatchQueue.main.async { self?.addDiagnostic(message) }
        }
        browser.captureBrowserSession { [weak self] cookies, userAgent, capturedHeaders in
            guard let self else { return }
            PhoneStreamProxy.shared.prepare(cookies: cookies, userAgent: userAgent, referer: video.pageURL, capturedHeadersByURL: capturedHeaders) { result in
                DispatchQueue.main.async {
                    guard self.attemptID == id else { return }
                    switch result {
                    case .success:
                        guard let localURL = PhoneStreamProxy.shared.proxiedURL(for: mediaURL) else {
                            self.status = "Kunne ikke oprette telefonens lokale stream-adresse."
                            return
                        }
                        let isHLS = video.isHLSMaster == true || video.mime.localizedCaseInsensitiveContains("mpegurl") || mediaURL.pathExtension.lowercased() == "m3u8"
                        guard !isHLS else {
                            self.status = "Kontrollerer lyd- og videoformatet i HLS-listen…"
                            PhoneStreamProxy.shared.inspectHLS(mediaURL) { formats in
                                DispatchQueue.main.async {
                                    guard self.attemptID == id else { return }
                                    if let formats {
                                        let audio = formats.audioSegmentFormat.map { self.hlsAudioFormatName($0) } ?? "ukendt"
                                        let videoFormat = formats.videoSegmentFormat.map { self.hlsVideoFormatName($0) } ?? "ukendt"
                                        self.addDiagnostic("HLS-format fundet: lyd \(audio), video \(videoFormat).")
                                        self.load(video, from: localURL, on: session, hlsFormats: formats, initialPosition: initialPosition)
                                    } else {
                                        self.addDiagnostic("Kunne ikke læse HLS-underlisterne på forhånd; sender uden formatgæt.")
                                        self.load(video, from: localURL, on: session, hlsFormats: nil, initialPosition: initialPosition)
                                    }
                                }
                            }
                            return
                        }
                        self.load(video, from: localURL, on: session, hlsFormats: nil, initialPosition: initialPosition)
                    case .failure(let error):
                        self.addDiagnostic("Stream-proxy kunne ikke starte: \(error.localizedDescription)")
                        self.recoverCast(id)
                    }
                }
            }
        }
        selectedTab = .remote
    }

    private func load(_ video: VideoCandidate, from mediaURL: URL, on session: GCKCastSession, hlsFormats: HLSFormats?, initialPosition: Double = 0) {
        if session.currentDeviceVolume < 0.01 {
            _ = session.setDeviceVolume(0.5)
            receiverVolume = 0.5
            status = "Chromecast var lydløs — skruer lydstyrken op til 50 %."
        }
        let builder = GCKMediaInformationBuilder(contentURL: mediaURL)
        let isHLS = video.isHLSMaster == true || video.mime.localizedCaseInsensitiveContains("mpegurl") || mediaURL.pathExtension.lowercased() == "m3u8"
        builder.contentType = isHLS ? "application/x-mpegurl" : video.mime
        builder.streamType = .buffered
        if isHLS {
            let rawValue = hlsFormats?.audioSegmentFormat ?? 5 // Test TS_AAC when playlist inspection cannot identify audio.
            if let format = GCKHLSSegmentFormat(rawValue: rawValue) {
                builder.hlsSegmentFormat = format
                if hlsFormats?.audioSegmentFormat == nil {
                    addDiagnostic("HLS-lydformat var ukendt; sender TS_AAC som test-fallback.")
                }
            }
        }
        if let rawValue = hlsFormats?.videoSegmentFormat,
           let format = GCKHLSVideoSegmentFormat(rawValue: rawValue) {
            builder.hlsVideoSegmentFormat = format
        }
        let metadata = GCKMediaMetadata(metadataType: .movie)
        metadata.setString(video.title, forKey: kGCKMetadataKeyTitle)
        if let poster = video.poster, let posterURL = URL(string: poster) {
            metadata.addImage(GCKImage(url: posterURL, width: 640, height: 360))
        }
        builder.metadata = metadata
        let tracks = video.subtitles.enumerated().compactMap { index, item -> GCKMediaTrack? in
            guard let url = PhoneStreamProxy.shared.proxiedURL(for: URL(string: item.url) ?? mediaURL) else { return nil }
            return GCKMediaTrack(identifier: Int(index + 1), contentIdentifier: url.absoluteString,
                                 contentType: item.mime, type: .text, textSubtype: .subtitles,
                                 name: item.name, languageCode: item.language, customData: nil)
        }
        if !tracks.isEmpty { builder.mediaTracks = tracks }
        guard let client = session.remoteMediaClient else {
            addDiagnostic("LOAD kunne ikke startes: Cast-klienten mangler.")
            status = "Kunne ikke sende videoen. Kontrollér Cast-forbindelsen."
            recoverCast(attemptID)
            return
        }
        let mediaInformation = builder.build()
        let audioFormat = hlsFormats?.audioSegmentFormat.map { hlsAudioFormatName($0) } ?? (isHLS ? "ukendt (TS_AAC fallback)" : "ukendt")
        let videoFormat = hlsFormats?.videoSegmentFormat.map { hlsVideoFormatName($0) } ?? "ukendt"
        addDiagnostic("Starter LOAD: type \(mediaInformation.contentType), lyd \(audioFormat), video \(videoFormat).")
        addDiagnostic(initialPosition > 0 ? "Genoptager fra \(initialPosition.clockString)." : "Starter fra begyndelsen.")
        let id = attemptID
        loadStarted = Date()
        let request = client.loadMedia(mediaInformation, autoplay: true, playPosition: initialPosition)
        CastRequestStatus.shared.onComplete = { [weak self] in
            DispatchQueue.main.async { self?.addDiagnostic("Chromecast accepterede LOAD-kommandoen.") }
        }
        CastRequestStatus.shared.onFailure = { [weak self] error in
            DispatchQueue.main.async {
                guard let self, self.attemptID == id else { return }
                self.addDiagnostic("Cast-kommando fejlede: \(error.localizedDescription)")
                self.recoverCast(id)
            }
        }
        request.delegate = CastRequestStatus.shared
        addDiagnostic("LOAD-request oprettet; afventer svar fra Chromecast.")
        nowPlayingTitle = video.title
        currentPoster = video.poster
        if hlsFormats?.audioSegmentFormat != nil || hlsFormats?.videoSegmentFormat != nil {
            status = "HLS-formater kontrolleret — sender til \(session.device.friendlyName ?? "Chromecast")…"
        } else {
            status = "Streamer fra iPhone til \(session.device.friendlyName ?? "Chromecast")…"
        }
        selectedTab = .remote
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
                isPlaying = media.playerState == .playing
                if isPlaying, let target = retryTarget,
                   media.mediaInformation?.metadata?.string(forKey: kGCKMetadataKeyTitle) == target.video.title {
                    rememberSuccessfulCast()
                }
                playbackPosition = max(0, media.streamPosition)
                playbackDuration = max(0, media.mediaInformation?.streamDuration ?? 0)
                if media.playerState == .playing || media.playerState == .paused {
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
                if media.playerState == .idle && media.idleReason == .error {
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

    private func addDiagnostic(_ message: String) {
        status = message
        let entry = "\(Date.now.formatted(date: .omitted, time: .shortened))  \(message)"
        diagnostics.insert(entry, at: 0)
        if diagnostics.count > 80 { diagnostics.removeLast(diagnostics.count - 80) }
    }

    private func hlsAudioFormatName(_ rawValue: Int) -> String {
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

    private func hlsVideoFormatName(_ rawValue: Int) -> String {
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
