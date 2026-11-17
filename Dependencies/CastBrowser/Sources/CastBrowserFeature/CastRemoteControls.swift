import Foundation
import GoogleCast
import UIKit

extension CastAppModel {
    var needsPhoneAwake: Bool {
        guard hasSession else { return false }
        let media = GCKCastContext.sharedInstance().sessionManager.currentCastSession?.remoteMediaClient?.mediaStatus
        let route = (media?.mediaInformation?.customData as? [String: String])?["fadedaiRoute"]
        return (route == "phone" && (media?.playerState == .playing || media?.playerState == .buffering))
            || (mediaRoute == .phone && castFeedback != nil)
    }

    var screenOffMessage: String {
        guard hasActiveMedia else { return "Start en film for at se, om skærmen kan slukkes." }
        guard castFeedback == nil, !canRetryCast,
              let media = GCKCastContext.sharedInstance().sessionManager.currentCastSession?.remoteMediaClient?.mediaStatus,
              media.playerState == .playing || media.playerState == .paused else {
            return "Vent, til TV’et er begyndt at afspille, før du slukker skærmen."
        }
        let route = (media.mediaInformation?.customData as? [String: String])?["fadedaiRoute"]
        if route == "direct" {
            return "Afspiller direkte på TV · Du kan skifte app eller låse iPhone."
        }
        if route == "pc" {
            return "Afspiller via PC · Du kan skifte app eller låse iPhone. Lad PC’en være tændt."
        }
        return "Via iPhone · Denne kilde bruger telefonens forbindelse. Du kan skifte fane i FadedAI, men hold appen åben og skærmen tændt."
    }

    func togglePlayback() {
        guard let client = GCKCastContext.sharedInstance().sessionManager.currentCastSession?.remoteMediaClient else { return }
        if isPlaying {
            savePlaybackProgress(force: true)
            _ = client.pause()
        } else {
            _ = client.play()
        }
        refreshRemote()
    }
    func stopPlayback() {
        cancelCastRecovery()
        savePlaybackProgress(force: true)
        _ = GCKCastContext.sharedInstance().sessionManager.currentCastSession?.remoteMediaClient?.stop()
        refreshRemote()
    }
    func seek(to value: Double) { _ = GCKCastContext.sharedInstance().sessionManager.currentCastSession?.remoteMediaClient?.seek(toTimeInterval: value) }
    func setVolume(_ value: Double) { _ = GCKCastContext.sharedInstance().sessionManager.currentCastSession?.setDeviceVolume(Float(value)); receiverVolume = value }
    func toggleSubtitles() {
        guard let client = GCKCastContext.sharedInstance().sessionManager.currentCastSession?.remoteMediaClient,
              let tracks = client.mediaStatus?.mediaInformation?.mediaTracks,
              !tracks.isEmpty else { status = "Denne stream indeholder ingen Cast-undertekster."; return }
        let textTrackIDs = tracks.filter { $0.type == .text }.map { NSNumber(value: $0.identifier) }
        guard !textTrackIDs.isEmpty else { status = "Denne stream indeholder ingen Cast-undertekster."; return }
        let active = client.mediaStatus?.activeTrackIDs ?? []
        _ = client.setActiveTrackIDs(active.isEmpty ? textTrackIDs : [])
        status = active.isEmpty ? "Undertekster slået til." : "Undertekster slået fra."
    }

    var hasActiveMedia: Bool {
        guard hasSession else { return false }
        let state = GCKCastContext.sharedInstance().sessionManager.currentCastSession?.remoteMediaClient?.mediaStatus?.playerState
        return state == .playing || state == .paused || state == .buffering || castFeedback != nil
    }

    var connectionTitle: String {
        if !hasSession { return "Forbind til TV" }
        return hasActiveMedia ? (isPlaying ? "Afspiller på TV" : "Forbundet til afspilleren") : "TV forbundet"
    }

    var playbackMessage: String {
        if let feedback = castFeedback { return feedback }
        if canRetryCast { return "Afspilningen blev afbrudt. Prøv igen." }
        if !hasSession { return "Vælg din Chromecast på samme Wi-Fi." }
        if isPlaying { return "Afspiller på " + (deviceName ?? "Chromecast") }
        if hasActiveMedia && playbackDuration > 0 { return "Afspilningen er sat på pause." }
        return "Vælg en video i browseren for at starte."
    }

    func toggleMute() {
        guard let session = GCKCastContext.sharedInstance().sessionManager.currentCastSession else { return }
        _ = session.setDeviceMuted(!receiverMuted)
        receiverMuted.toggle()
    }

    func saveFavorite(title: String, address: String) -> Bool {
        let input = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = input.contains("://") ? input : "https://" + input
        guard let url = URL(string: normalized), let host = url.host, !host.isEmpty,
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.user == nil, url.password == nil else { return false }
        let link = BrowserLink(title: title.trimmedOr(host), url: url.absoluteString)
        bookmarks.removeAll { $0.url == link.url }
        bookmarks.insert(link, at: 0)
        return true
    }

    func prepareDirectDiagnostics() {
        savePlaybackProgress(force: true)
        cancelCastRecovery()
    }

    func endSession() {
        cancelCastRecovery()
        savePlaybackProgress(force: true)
        GCKCastContext.sharedInstance().sessionManager.endSession()
    }

    /// The original upstream URL from the latest cast, never the iPhone proxy address.
    var directDiagnosticSourceURL: URL? {
        guard let retryTarget, let url = URL(string: retryTarget.video.url),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }

    var canRun404Test: Bool { retryTarget != nil && !is404TestRunning }

    /// Compares the same active upstream master URL with and without the proxy's
    /// browser context. No URL query, cookie, token or header value is copied.
    func copy404Test() {
        guard !is404TestRunning, let target = retryTarget,
              let sourceURL = URL(string: target.video.url),
              ["http", "https"].contains(sourceURL.scheme?.lowercased() ?? "") else {
            copy404TestMessage = "Start en video først, og prøv igen."
            return
        }
        is404TestRunning = true
        copy404TestMessage = "Tester den aktuelle videokilde…"
        Task {
            let contextRequest = await PhoneStreamProxy.shared.diagnosticRequest(for: sourceURL)
            var report = [
                "WEB CAST 404-TEST",
                "Kilde: \(sourceURL.host ?? "ukendt") / .\(sourceURL.pathExtension.lowercased()) (sti og query skjult)",
                "Samme URL og iPhone-netværk i alle forsøg. Testen beviser ikke adgang fra Chromecast eller en ekstern server."
            ]
            if let contextRequest {
                report.append(await self.probe404(contextRequest, label: "MED browserkontekst (før)"))
                let headerNames = (contextRequest.allHTTPHeaderFields ?? [:]).keys.sorted()
                for name in headerNames {
                    var variant = contextRequest
                    if name.caseInsensitiveCompare("User-Agent") == .orderedSame {
                        variant.setValue("WebCastDiagnostic/1.0", forHTTPHeaderField: name)
                    } else {
                        variant.setValue(nil, forHTTPHeaderField: name)
                    }
                    let label = name.caseInsensitiveCompare("User-Agent") == .orderedSame
                        ? "MED generisk User-Agent" : "UDEN \(name)"
                    report.append(await self.probe404(variant, label: label))
                }
                report.append(await self.probe404(contextRequest, label: "MED browserkontekst (efter)"))
            } else {
                report.append("MED browserkontekst: proxyens session er ikke klar; start casting og prøv igen.")
            }
            var bare = URLRequest(url: sourceURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
            bare.httpMethod = "GET"
            bare.httpShouldHandleCookies = false
            bare.setValue("WebCastDiagnostic/1.0", forHTTPHeaderField: "User-Agent")
            bare.setValue("*/*", forHTTPHeaderField: "Accept")
            bare.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            report.append(await self.probe404(bare, label: "UDEN browserkontekst"))
            await MainActor.run {
                UIPasteboard.general.string = report.joined(separator: "\n")
                self.is404TestRunning = false
                self.copy404TestMessage = "404-test kopieret. Indsæt teksten i din besked."
            }
        }
    }

    private func probe404(_ original: URLRequest, label: String) async -> String {
        var request = original
        request.httpShouldHandleCookies = false
        let headers = request.allHTTPHeaderFields ?? [:]
        let present = ["Cookie", "Referer", "Origin", "User-Agent"].map { name in
            "\(name)=\(headers.keys.contains { $0.caseInsensitiveCompare(name) == .orderedSame } ? "ja" : "nej")"
        }.joined(separator: ", ")
        // Ephemeral session prevents the "without" request from inheriting shared cookies.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return "\(label): Intet HTTP-svar; requestheaders: \(present)"
            }
            let mime = http.value(forHTTPHeaderField: "Content-Type") ?? "mangler"
            let declared = http.value(forHTTPHeaderField: "Content-Length") ?? "mangler"
            let magic = data.prefix(8).map { String(format: "%02X", $0) }.joined(separator: " ")
            let finalHost = http.url?.host ?? "ukendt"
            return "\(label): HTTP=\(http.statusCode); MIME=\(mime); declared=\(declared); body=\(data.count); magic=\(magic); finalHost=\(finalHost); requestheaders: \(present)"
        } catch {
            let nsError = error as NSError
            return "\(label): netværksfejl \(nsError.domain)/\(nsError.code); requestheaders: \(present)"
        }
    }

    func copyDiagnostics() {
        UIPasteboard.general.string = diagnostics.reversed().joined(separator: "\n")
        status = "Log kopieret — indsæt den i din besked."
    }
}
