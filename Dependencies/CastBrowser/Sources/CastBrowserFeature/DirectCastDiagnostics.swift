import SwiftUI
import Foundation
import GoogleCast
import UIKit

/// Uses the Cast context already configured by the application's AppDelegate.
/// For steps 1 and 2 that context must use kGCKDefaultMediaReceiverApplicationID.
@MainActor
final class DirectCastDiagnostics: NSObject, ObservableObject, @preconcurrency GCKRequestDelegate {
    static let muxURL = URL(string: "https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8")!
    @Published var lines: [String] = []
    @Published var receiverState = "Ingen Cast-status endnu"
    private var timer: Timer?
    private var browserContextProbe = false
    private var lastSnapshot = ""
    private var loadedURL: URL?
    private var lastPosition: TimeInterval = -10

    func beginObserving() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sampleReceiver() }
        }
        sampleReceiver()
    }

    func endObserving() {
        timer?.invalidate()
        timer = nil
    }

    func connect() {
        let context = GCKCastContext.sharedInstance()
        context.discoveryManager.startDiscovery()
        context.presentCastDialog()
    }

    func loadMux() {
        // x36xhzz is MPEG2-TS containing H.264 video and AAC audio.
        load(url: Self.muxURL, title: "Direkte Mux-test", audioRaw: 5, videoRaw: 1)
    }

    func loadSource(_ input: String) {
        guard let url = URL(string: input.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil else {
            log("INPUT: indtast den oprindelige m3u8-URL, ikke websiden eller en lokal proxy-URL.")
            return
        }
        // This preset is for our source whose separate audio/video lists use fMP4.
        load(url: url, title: "Direkte kildetest", audioRaw: 7, videoRaw: 2)
    }

    private func load(url: URL, title: String, audioRaw: Int, videoRaw: Int) {
        guard let session = GCKCastContext.sharedInstance().sessionManager.currentCastSession,
              let client = session.remoteMediaClient else {
            log("CONNECT: vælg Chromecast først og tryk derefter på testknappen igen.")
            connect()
            return
        }
        let media = GCKMediaInformationBuilder(contentURL: url)
        media.contentID = url.absoluteString
        media.contentType = "application/x-mpegurl"
        media.streamType = .buffered
        if let format = GCKHLSSegmentFormat(rawValue: audioRaw) { media.hlsSegmentFormat = format }
        if let format = GCKHLSVideoSegmentFormat(rawValue: videoRaw) { media.hlsVideoSegmentFormat = format }
        let metadata = GCKMediaMetadata(metadataType: .movie)
        metadata.setString(title, forKey: kGCKMetadataKeyTitle)
        media.metadata = metadata
        let request = GCKMediaLoadRequestDataBuilder()
        request.mediaInformation = media.build()
        request.autoplay = NSNumber(value: true)
        request.startTime = 0
        loadedURL = url
        lastSnapshot = ""
        lastPosition = -10
        log("SENDER LOAD direct=\(Self.safeURL(url)); type=application/x-mpegurl; stream=buffered; audioFormat=\(audioRaw); videoFormat=\(videoRaw). Ingen PhoneStreamProxy.")
        client.loadMedia(with: request.build()).delegate = self
    }

    func requestDidComplete(_ request: GCKRequest) {
        log("CAST LOAD accepteret. Dette bekræfter kommandoen, ikke afspilning eller HTTP-success.")
    }

    func request(_ request: GCKRequest, didFailWithError error: GCKError) {
        log("CAST LOAD fejl domain=\(error.domain); code=\(error.code). Brug receiver-konsollen til den konkrete netværksfejl.")
    }

    private func sampleReceiver() {
        guard let session = GCKCastContext.sharedInstance().sessionManager.currentCastSession else {
            receiverState = "Ingen forbundet Cast-session"
            return
        }
        guard let media = session.remoteMediaClient?.mediaStatus else {
            receiverState = "Forbundet, afventer mediestatus"
            return
        }
        let state = Self.stateName(media.playerState)
        let reason = Self.reasonName(media.idleReason)
        let type = media.mediaInformation?.contentType ?? "mangler i receiver-status"
        let contentURL = media.mediaInformation?.contentURL
        let reported = contentURL.map(Self.safeURL) ?? "mangler"
        let matchesLoad = loadedURL != nil && (contentURL == loadedURL || media.mediaInformation?.contentID == loadedURL?.absoluteString)
        let snapshot = "state=\(state)(\(media.playerState.rawValue)); idleReason=\(reason)(\(media.idleReason.rawValue)); matchesLoad=\(matchesLoad); type=\(type); receiverURL=\(reported)"
        receiverState = "\(state) · \(Int(max(0, media.streamPosition))) sek."
        if snapshot != lastSnapshot {
            log("CAST STATUS \(snapshot)")
            lastSnapshot = snapshot
        }
        if media.playerState == .playing, media.streamPosition >= lastPosition + 5 {
            log("CAST POSITION \(Int(media.streamPosition)) sek. mediaSession=\(media.mediaSessionID)")
            lastPosition = media.streamPosition
        }
    }

    static func stateName(_ value: GCKMediaPlayerState) -> String {
        switch value {
        case .unknown: return "UNKNOWN"
        case .idle: return "IDLE"
        case .playing: return "PLAYING"
        case .paused: return "PAUSED"
        case .buffering: return "BUFFERING"
        case .loading: return "LOADING"
        @unknown default: return "OTHER"
        }
    }

    static func reasonName(_ value: GCKMediaPlayerIdleReason) -> String {
        switch value {
        case .none: return "NONE"
        case .finished: return "FINISHED"
        case .cancelled: return "CANCELLED"
        case .interrupted: return "INTERRUPTED"
        case .error: return "ERROR"
        @unknown default: return "OTHER"
        }
    }

    func compareAccess(_ input: String) async {
        await probe(input)
        await probe(input, browserContext: true)
    }

    func probe(_ input: String, browserContext: Bool = false) async {
        browserContextProbe = browserContext
        guard let url = URL(string: input.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
            log("PROBE INPUT: ugyldig URL")
            return
        }
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 40
        let session = browserContext ? URLSession.shared : URLSession(configuration: config)
        defer { if !browserContext { session.invalidateAndCancel() } }
        log("IPHONE PROBE BEGIN mode=\(browserContext ? "BROWSER_CONTEXT" : "ANONYMOUS"). Ikke en Chromecast-forespørgsel.")
        do { try await probePlaylist(url, label: "master", depth: 0, session: session) }
        catch { log("IPHONE PROBE ERROR domain=\((error as NSError).domain); code=\((error as NSError).code)") }
        log("IPHONE PROBE END")
    }

    private func get(_ url: URL, label: String, session: URLSession, range: String? = nil) async throws -> (Data, URL) {
        var request: URLRequest
        if browserContextProbe {
            guard let configured = await PhoneStreamProxy.shared.diagnosticRequest(for: url) else {
                log("BROWSER_CONTEXT mangler. Start først filmen med den normale Cast-knap, og åbn derefter denne test.")
                throw URLError(.userAuthenticationRequired)
            }
            request = configured
        } else {
            request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        }
        request.httpMethod = "GET"
        if let range { request.setValue(range, forHTTPHeaderField: "Range") }
        let (body, rawResponse) = try await session.data(for: request)
        guard let response = rawResponse as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        let type = response.value(forHTTPHeaderField: "Content-Type") ?? "missing"
        let declared = response.value(forHTTPHeaderField: "Content-Length") ?? "missing"
        let contentRange = response.value(forHTTPHeaderField: "Content-Range") ?? "none"
        let magic = body.prefix(16).map { String(format: "%02X", $0) }.joined(separator: " ")
        let target = response.url ?? url
        log("IPHONE \(browserContextProbe ? "BROWSER_CONTEXT" : "ANONYMOUS") GET \(label) \(Self.safeURL(target)); HTTP=\(response.statusCode); MIME=\(type); declared=\(declared); body=\(body.count); Range=\(range ?? "none"); Content-Range=\(contentRange); magic=\(magic)")
        guard (200...299).contains(response.statusCode) else { throw URLError(.badServerResponse) }
        return (body, target)
    }

    private func probePlaylist(_ url: URL, label: String, depth: Int, session: URLSession) async throws {
        guard depth < 4 else { log("IPHONE PROBE: stopper efter fire playlist-niveauer"); return }
        let (data, finalURL) = try await get(url, label: label, session: session)
        guard let text = String(data: data, encoding: .utf8), text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#EXTM3U") else {
            log("IPHONE PROBE: svaret er ikke en læsbar HLS-playliste")
            return
        }
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        for line in lines where line.hasPrefix("#EXT-X-KEY:") || line.hasPrefix("#EXT-X-SESSION-KEY:") {
            let attributes = Self.attributes(line)
            log("IPHONE ENCRYPTION method=\(attributes["METHOD"] ?? "missing"); keyformat=\(attributes["KEYFORMAT"] ?? "identity/default"). Kryptering er ikke alene bevis for DRM.")
        }
        if let index = lines.firstIndex(where: { $0.hasPrefix("#EXT-X-STREAM-INF:") }),
           let next = lines.dropFirst(index + 1).first(where: { !$0.isEmpty && !$0.hasPrefix("#") }),
           let variant = URL(string: next, relativeTo: finalURL)?.absoluteURL {
            log("IPHONE VARIANT valgt til probe: første variant. CODECS=\(Self.attributes(lines[index])["CODECS"] ?? "missing")")
            do { try await probePlaylist(variant, label: "video-underplayliste", depth: depth + 1, session: session) }
            catch { log("IPHONE VIDEO PROBE fejlede. Se HTTP-linjen ovenfor.") }
            if let audio = lines.first(where: { $0.hasPrefix("#EXT-X-MEDIA:") && Self.attributes($0)["TYPE"] == "AUDIO" }),
               let raw = Self.attributes(audio)["URI"], let audioURL = URL(string: raw, relativeTo: finalURL)?.absoluteURL {
                do { try await probePlaylist(audioURL, label: "lyd-underplayliste", depth: depth + 1, session: session) }
                catch { log("IPHONE AUDIO PROBE fejlede. Se HTTP-linjen ovenfor.") }
            }
            return
        }
        if let map = lines.first(where: { $0.hasPrefix("#EXT-X-MAP:") }),
           let uri = Self.attributes(map)["URI"], let initURL = URL(string: uri, relativeTo: finalURL)?.absoluteURL {
            _ = try await get(initURL, label: label + " init", session: session,
                              range: Self.byteRange(Self.attributes(map)["BYTERANGE"], offset: 0))
        }
        if let index = lines.firstIndex(where: { !$0.isEmpty && !$0.hasPrefix("#") }),
           let segment = URL(string: lines[index], relativeTo: finalURL)?.absoluteURL {
            let preceding = lines[..<index].last(where: { $0.hasPrefix("#EXT-X-BYTERANGE:") })
            let rawRange = preceding.map { String($0.dropFirst("#EXT-X-BYTERANGE:".count)) }
            _ = try await get(segment, label: label + " første segment", session: session,
                              range: Self.byteRange(rawRange, offset: 0))
        }
    }

    private static func byteRange(_ raw: String?, offset: Int) -> String? {
        guard let raw else { return nil }
        let parts = raw.split(separator: "@")
        guard let first = parts.first, let length = Int(first), length > 0 else { return nil }
        let start = parts.count > 1 ? Int(parts[1]) ?? offset : offset
        return "bytes=\(start)-\(start + length - 1)"
    }

    private static func attributes(_ line: String) -> [String: String] {
        guard let regex = try? NSRegularExpression(pattern: #"([A-Z0-9-]+)=("[^"]*"|[^,]*)"#) else { return [:] }
        let ns = line as NSString
        var values: [String: String] = [:]
        for match in regex.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
            values[ns.substring(with: match.range(at: 1))] = ns.substring(with: match.range(at: 2)).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        return values
    }

    static func safeURL(_ url: URL) -> String {
        // Queries, fragments and userinfo are deliberately excluded.
        "\(url.scheme ?? "?")://\(url.host ?? "?")\(url.port.map { ":\($0)" } ?? "")\(url.path)"
    }

    private func log(_ line: String) {
        let entry = "\(Date().formatted(date: .omitted, time: .standard)) \(line)"
        lines.append(entry)
        if lines.count > 300 { lines.removeFirst(lines.count - 300) }
        print(entry)
    }
}

struct DirectCastDiagnosticsView: View {
    @StateObject private var diagnostics = DirectCastDiagnostics()
    @State private var source: String
    @State private var probing = false
    @Environment(\.dismiss) private var dismiss

    init(sourceURL: URL? = nil) {
        _source = State(initialValue: sourceURL?.absoluteString ?? "")
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Forbind først til Chromecast") {
                    Button("Vælg Chromecast") { diagnostics.connect() }
                    Text(diagnostics.receiverState)
                }
                Section("Trin 1 · Mux direkte") {
                    Button("Afspil Mux direkte") { diagnostics.loadMux() }
                    Button("HTTP-probe fra iPhone") { runProbe(DirectCastDiagnostics.muxURL.absoluteString) }.disabled(probing)
                }
                Section("Trin 2 · Oprindelig HLS-kilde") {
                    TextField("Original m3u8-URL", text: $source)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    Button("HTTP-probe fra iPhone") { runProbe(source) }.disabled(probing)
                    Button("Sammenlign adgang") {
                        probing = true
                        Task {
                            await diagnostics.compareAccess(source)
                            probing = false
                        }
                    }.disabled(probing)
                    Button("Afspil kilde direkte · fMP4") { diagnostics.loadSource(source) }
                    Text("Sammenlign adgang tester samme URL først uden adgangsoplysninger og derefter med den normale Cast-proxys browseroplysninger. Header-værdier vises ikke i loggen.")
                        .font(.footnote)
                }
                Section("Diagnostik") {
                    Button("Kopiér diagnostik") { UIPasteboard.general.string = diagnostics.lines.joined(separator: "\n") }
                    ForEach(Array(diagnostics.lines.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
            }
            .navigationTitle("Direkte Cast-test")
            .toolbar { Button("Luk") { dismiss() } }
            .onAppear { diagnostics.beginObserving() }
            .onDisappear { diagnostics.endObserving() }
        }
    }

    private func runProbe(_ url: String) {
        probing = true
        Task {
            await diagnostics.probe(url)
            probing = false
        }
    }
}
