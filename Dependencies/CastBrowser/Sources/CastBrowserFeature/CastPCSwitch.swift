import Foundation
import GoogleCast

enum CastRelayPreflight {
    /// Follow the first video variant and read a sample of an actual segment, all through the PC.
    static func verify(_ relay: URL, isPlaylist: Bool,
                       read: (URL, Bool) async throws -> Data) async throws {
        var next = relay
        var playlist = isPlaylist
        for _ in 0..<4 {
            let data = try await read(next, playlist)
            if !playlist {
                let prefix = String(decoding: data.prefix(32), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                guard data.count >= 8, !prefix.hasPrefix("<"), !prefix.hasPrefix("{"),
                      !prefix.hasPrefix("#EXTM3U") else { throw URLError(.cannotDecodeContentData) }
                return
            }
            let text = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\u{feff}", with: "")
            let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
            guard lines.first == "#EXTM3U",
                  let child = lines.first(where: { !$0.isEmpty && !$0.hasPrefix("#") }),
                  let url = URL(string: child, relativeTo: next)?.absoluteURL,
                  url.deletingLastPathComponent() == relay.deletingLastPathComponent(), url != next else {
                throw URLError(.cannotDecodeContentData)
            }
            playlist = lines.contains { $0.hasPrefix("#EXT-X-STREAM-INF:") }
            next = url
        }
        throw URLError(.cannotDecodeContentData)
    }

    static func read(_ url: URL, playlist: Bool) async throws -> Data {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url, timeoutInterval: 10)
        if !playlist { request.setValue("bytes=0-31", forHTTPHeaderField: "Range") }
        let (bytes, reply) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let response = reply as? HTTPURLResponse, [200, 206].contains(response.statusCode),
              response.url == url else { throw URLError(.badServerResponse) }
        let limit = playlist ? 65_536 : 32
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count == limit { break }
        }
        return data
    }
}

extension CastAppModel {
    var pcSwitchTarget: (frame: FilmReceiverFrame, attempt: UUID, video: VideoCandidate)? {
        guard pcRelayWithContext != nil || pcRelay != nil, !canRetryCast, castFeedback == nil,
              let frame = filmFrame,
              let info = GCKCastContext.sharedInstance().sessionManager.currentCastSession?.remoteMediaClient?.mediaStatus?.mediaInformation,
              let tags = info.customData as? [String: String], tags["fadedaiRoute"] == "phone",
              let tag = tags["fadedaiAttempt"], let attempt = UUID(uuidString: tag),
              let video = videoConfirmed(by: attempt) else { return nil }
        return (frame, attempt, video)
    }

    func switchPlaybackToPC() async {
        guard pcSwitchID == nil, let target = pcSwitchTarget, let source = URL(string: target.video.url) else { return }
        let operation = UUID()
        let initialAttempt = attemptID
        pcSwitchID = operation
        pcSwitchFailure = nil
        defer { if pcSwitchID == operation { pcSwitchID = nil } }
        func stillCurrent() -> Bool {
            pcSwitchID == operation && attemptID == initialAttempt && pcSwitchTarget?.attempt == target.attempt
                && filmFrame?.source == target.frame.source
        }
        do {
            let relay = try await preparePCRelay(target.video, source: source, current: stillCurrent)
            guard stillCurrent() else { return }
            let isHLS = target.video.isHLSMaster == true || target.video.mime.localizedCaseInsensitiveContains("mpegurl")
                || source.pathExtension.lowercased() == "m3u8"
            try await CastRelayPreflight.verify(relay, isPlaylist: isHLS, read: CastRelayPreflight.read)
            guard stillCurrent() else { return }
            var formats: HLSFormats?
            if isHLS {
                formats = await withCheckedContinuation { ready in
                    PhoneStreamProxy.shared.inspectHLS(relay, usingBrowserSession: false) { ready.resume(returning: $0) }
                }
            }
            // Ask the receiver again: the user may have paused, rewound, or changed movies during the checks.
            guard stillCurrent() else { return }
            let frame = try await confirmedFilmFrame()
            guard stillCurrent(), frame.source == target.frame.source,
                  let session = GCKCastContext.sharedInstance().sessionManager.currentCastSession,
                  let media = session.remoteMediaClient?.mediaStatus else { return }
            commitPCSwitch(video: target.video, relay: relay, session: session, formats: formats,
                           position: frame.position, playing: media.playerState == .playing)
        } catch {
            if stillCurrent() { pcSwitchFailure = target.frame.source }
        }
    }
}
