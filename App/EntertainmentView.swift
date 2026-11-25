import CastBrowserFeature
import SwiftUI

struct EntertainmentBackdrop: View {
    var body: some View { FilmBackground() }
}

/// Chromecast must reach the relay itself, even when the phone is connected over Tailscale.
struct CastHomePairing {
    let server: Server
    private let activeHome: LiveAPI?

    init?(active: LiveAPI?, savedHomeAddress: String?) {
        guard let active else { return nil }
        if active.server.profile == .home {
            server = active.server
            activeHome = active
        } else {
            guard let address = savedHomeAddress, let home = try? Server(address),
                  home.profile == .home else { return nil }
            server = home
            activeHome = nil
        }
    }

    func connection(loadToken: (String) throws -> String = Pairing.load) throws -> LiveAPI {
        if let activeHome { return activeHome }
        return try LiveAPI(server: server, token: loadToken(server.address))
    }
}

@MainActor struct EntertainmentView<Content: View>: View {
    @State private var castWakeID = UUID()
    @StateObject private var filmVoice = FilmAppSpeech()
    let isSelected: Bool
    let background: AnyView
    let showsPlaybackControls: Bool
    let api: LiveAPI?
    var savedHomeAddress: String? = nil
    let onOpen: () -> Void
    let onBack: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        let home = CastHomePairing(active: api, savedHomeAddress: savedHomeAddress)
        let relayID = api.map { $0.queueTargetID + "|" + (home?.server.address ?? "") }
        let relay: CastPCRelay? = home.map { pairing in
            { source, page in try await pairing.connection().castRelayURL(source: source, page: page) }
        }
        let relayWithContext: CastPCRelayWithContext? = home.map { pairing in
            { source, page, userAgent in
                try await pairing.connection().castRelayURL(source: source, page: page, userAgent: userAgent)
            }
        }
        let filmAnalysis: CastFilmAnalysis? = api.map { connection in
            { request in
                try await connection.moduleJSON("film-companion", upload: JSONEncoder().encode(request),
                                                 timeout: 100, maximumBytes: 400_000)
            }
        }
        let filmSpeech: CastFilmSpeech = { text, language in filmVoice.speak(text, language: language, api: api) }
        CastBrowserHost(isSelected: isSelected, background: background,
                        showsPlaybackControls: showsPlaybackControls, onOpen: onOpen, onBack: onBack,
                        onPhoneCastWake: { ChatScreenWake.hold(castWakeID, whileReplying: $0) },
                        pcRelayID: relayID, pcRelay: relay, pcRelayWithContext: relayWithContext,
                        filmAnalysis: filmAnalysis,
                        filmSpeech: filmSpeech, phoneFilmHelp: { AnyView(PhoneFilmCompanionView()) }, content: content)
            .alert("Oplæsning", isPresented: Binding(get: { filmVoice.notice != nil }, set: { if !$0 { filmVoice.notice = nil } })) {
                Button("Luk") { filmVoice.notice = nil }
            } message: { Text(filmVoice.notice ?? "") }
    }
}
