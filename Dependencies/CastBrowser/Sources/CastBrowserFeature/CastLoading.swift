import Foundation
import GoogleCast

extension CastAppModel {
    func startCast(_ video: VideoCandidate, initialPosition: Double) {
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
        loadStarted = Date()
        castFeedback = "Indlæser…"
        status = mediaRoute == .pc ? "Gør PC’en klar til at overtage filmen…" : "Forbereder filmen…"
        selectedTab = .remote
        if mediaRoute == .pc {
            startPCRelay(video, url: mediaURL, id: id, position: initialPosition)
            return
        }
        PhoneStreamProxy.shared.onActivity = { [weak self] message in
            DispatchQueue.main.async { self?.addDiagnostic(message) }
        }
        let viaPhone = mediaRoute == .phone
        browser.captureBrowserSession { [weak self] cookies, userAgent, capturedHeaders in
            guard let self, self.attemptID == id else { return }
            let isHLS = video.isHLSMaster == true || video.mime.localizedCaseInsensitiveContains("mpegurl") || mediaURL.pathExtension.lowercased() == "m3u8"
            if !viaPhone {
                PhoneStreamProxy.shared.inspectDirect(mediaURL, isHLS: isHLS, cookies: cookies, userAgent: userAgent,
                                                      referer: video.pageURL, headers: capturedHeaders) { formats in
                    DispatchQueue.main.async {
                        guard self.attemptID == id else { return }
                        self.load(video, from: mediaURL, on: session, hlsFormats: formats, initialPosition: initialPosition)
                    }
                }
                return
            }
            PhoneStreamProxy.shared.prepare(cookies: cookies, userAgent: userAgent, referer: video.pageURL, capturedHeadersByURL: capturedHeaders) { result in
                DispatchQueue.main.async {
                    guard self.attemptID == id else { return }
                    switch result {
                    case .success:
                        guard let localURL = PhoneStreamProxy.shared.proxiedURL(for: mediaURL) else {
                            self.status = "Kunne ikke oprette telefonens lokale stream-adresse."
                            self.recoverCast(id)
                            return
                        }
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

    private func startPCRelay(_ video: VideoCandidate, url: URL, id: UUID, position: Double) {
        Task { @MainActor in
            do {
                let page = URL(string: video.pageURL)
                let relayURL: URL
                if let pcRelayWithContext {
                    let context = await browser.relayPageContext(for: url, page: page)
                    guard attemptID == id else { return }
                    relayURL = try await pcRelayWithContext(url, context.page, context.userAgent)
                } else if let pcRelay {
                    relayURL = try await pcRelay(url, page)
                } else {
                    recoverCast(id)
                    return
                }
                guard attemptID == id, let session = GCKCastContext.sharedInstance().sessionManager.currentCastSession else { return }
                let isHLS = video.isHLSMaster == true || video.mime.localizedCaseInsensitiveContains("mpegurl")
                    || url.pathExtension.lowercased() == "m3u8"
                if isHLS {
                    PhoneStreamProxy.shared.inspectHLS(relayURL, usingBrowserSession: false) { [weak self] formats in
                        DispatchQueue.main.async {
                            guard let self, self.attemptID == id else { return }
                            self.load(video, from: relayURL, on: session, hlsFormats: formats, initialPosition: position)
                        }
                    }
                } else {
                    load(video, from: relayURL, on: session, hlsFormats: nil, initialPosition: position)
                }
            } catch {
                guard attemptID == id else { return }
                addDiagnostic("PC’en kunne ikke overtage Cast. Prøver den næste forbindelse.")
                recoverCast(id)
            }
        }
    }

    func load(_ video: VideoCandidate, from mediaURL: URL, on session: GCKCastSession, hlsFormats: HLSFormats?, initialPosition: Double = 0) {
        if session.currentDeviceVolume < 0.01 {
            _ = session.setDeviceVolume(0.5)
            receiverVolume = 0.5
            status = "Chromecast var lydløs — skruer lydstyrken op til 50 %."
        }
        let builder = GCKMediaInformationBuilder(contentURL: mediaURL)
        let isHLS = video.isHLSMaster == true || video.mime.localizedCaseInsensitiveContains("mpegurl")
            || URL(string: video.url)?.pathExtension.lowercased() == "m3u8"
        builder.contentType = isHLS ? "application/x-mpegurl" : video.mime
        builder.streamType = .buffered
        builder.customData = ["fadedaiAttempt": attemptID.uuidString,
                              "fadedaiRoute": mediaRoute.rawValue]
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
            guard let source = URL(string: item.url), ["http", "https"].contains(source.scheme?.lowercased() ?? ""),
                  let url = mediaRoute == .phone ? PhoneStreamProxy.shared.proxiedURL(for: source) : source else { return nil }
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
        let delegate = CastRequestStatus()
        loadDelegate = delegate
        delegate.onComplete = { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.attemptID == id else { return }
                self.addDiagnostic("Chromecast accepterede LOAD-kommandoen.")
            }
        }
        delegate.onFailure = { [weak self] error in
            DispatchQueue.main.async {
                guard let self, self.attemptID == id else { return }
                self.addDiagnostic("Cast-kommando fejlede: \(error.localizedDescription)")
                self.recoverCast(id)
            }
        }
        request.delegate = delegate
        addDiagnostic("LOAD-request oprettet; afventer svar fra Chromecast.")
        nowPlayingTitle = video.title
        currentPoster = video.poster
        if mediaRoute == .pc {
            status = "PC’en leverer filmen til TV’et. Afventer afspilning…"
        } else if mediaRoute == .direct {
            status = "TV’et henter filmen direkte. Afventer afspilning…"
        } else if hlsFormats?.audioSegmentFormat != nil || hlsFormats?.videoSegmentFormat != nil {
            status = "HLS-formater kontrolleret — sender til \(session.device.friendlyName ?? "Chromecast")…"
        } else {
            status = "Streamer fra iPhone til \(session.device.friendlyName ?? "Chromecast")…"
        }
        selectedTab = .remote
    }

}
