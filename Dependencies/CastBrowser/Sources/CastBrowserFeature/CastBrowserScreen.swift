import SwiftUI
import WebKit
import GoogleCast
import Combine
import UIKit
import AVFoundation

let castWebsiteProfile = UUID(uuidString: "81462E40-5CCA-41CF-A5CE-AE1CD75E6A48")!

@MainActor public struct CastBrowserScreen: View {
    @StateObject private var model: CastAppModel
    @State private var browserOpened = false
    @Environment(\.scenePhase) private var phase
    @Environment(\.colorScheme) private var hostColorScheme
    @AppStorage("castbrowser.appearance") private var appearance = "Mørk"
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    public init() {
        _ = Self.castContext
        _model = StateObject(wrappedValue: CastAppModel())
    }

    init(model: CastAppModel) {
        _ = Self.castContext
        _model = StateObject(wrappedValue: model)
    }

    public static func clearWebsiteData() {
        WKWebsiteDataStore(forIdentifier: castWebsiteProfile).removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast, completionHandler: {}
        )
    }

    private static let castContext: GCKCastContext = {
        let criteria = GCKDiscoveryCriteria(applicationID: kGCKDefaultMediaReceiverApplicationID)
        let options = GCKCastOptions(discoveryCriteria: criteria)
        options.stopReceiverApplicationWhenEndingSession = false
        GCKCastContext.setSharedInstanceWith(options)
        let context = GCKCastContext.sharedInstance()
        context.useDefaultExpandedMediaControls = true
        return context
    }()

    public var body: some View {
        VStack(spacing: 0) {
            selectedPage
            Picker("CastBrowser-fane", selection: $model.selectedTab) {
                Text("Hjem").tag(AppTab.home)
                Text("Browser").tag(AppTab.browser)
                Text("Videoer").tag(AppTab.videos)
                Text("TV").tag(AppTab.remote)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.thinMaterial)
        }
        .onAppear { model.observeCastSession() }
        .onChange(of: model.selectedTab, initial: true) {
            if model.selectedTab == .browser { browserOpened = true }
        }
        .onReceive(timer) { _ in
            if phase == .active { model.refreshRemote() }
        }
        .tint(Style.accent)
        .environment(\.colorScheme, appearance == "System" ? hostColorScheme : (appearance == "Lys" ? .light : .dark))
        .alert("Fortsæt afspilning?", isPresented: Binding(
            get: { model.resumePromptVideo != nil },
            set: { if !$0 { model.cancelResumePrompt() } }
        )) {
            Button("Fortsæt fra \(model.resumePromptPosition.clockString)") { model.chooseResume(continueFromSaved: true) }
            Button("Start forfra") { model.chooseResume(continueFromSaved: false) }
            Button("Annuller", role: .cancel) { model.cancelResumePrompt() }
        } message: {
            Text("Vil du fortsætte \(model.resumePromptVideo?.title ?? "videoen") fra \(model.resumePromptPosition.clockString)?")
        }
    }

    private var selectedPage: some View {
        let browserSelected = model.selectedTab == .browser
        return ZStack {
            if browserOpened || browserSelected {
                BrowserScreen(model: model)
                    .allowsHitTesting(browserSelected)
                    .accessibilityHidden(!browserSelected)
            }
            if !browserSelected {
                Group {
                    switch model.selectedTab {
                    case .home: HomeScreen(model: model)
                    case .browser: Color.clear
                    case .videos: VideosScreen(model: model)
                    case .remote: RemoteScreen(model: model)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Style.canvas)
            }
        }
    }
}

/// Keeps CastBrowser's web view mounted while the host switches between pages.
@MainActor public struct CastBrowserHost<Content: View>: View {
    private let isSelected: Bool
    private let background: AnyView
    private let showsPlaybackControls: Bool
    private let onOpen: () -> Void
    private let onPhoneCastWake: (Bool) -> Void
    private let pcRelayID: String?
    private let pcRelay: CastPCRelay?
    private let pcRelayWithContext: CastPCRelayWithContext?
    private let filmAnalysis: CastFilmAnalysis?
    private let filmSpeech: CastFilmSpeech?
    private let content: () -> Content
    @Environment(\.scenePhase) private var phase
    @State private var model: CastAppModel?
    @State private var playingOnPhone = false

    public init(isSelected: Bool, background: AnyView, showsPlaybackControls: Bool = true,
                onOpen: @escaping () -> Void, onPhoneCastWake: @escaping (Bool) -> Void = { _ in },
                pcRelayID: String? = nil, pcRelay: CastPCRelay? = nil,
                pcRelayWithContext: CastPCRelayWithContext? = nil,
                filmAnalysis: CastFilmAnalysis? = nil,
                filmSpeech: CastFilmSpeech? = nil,
                @ViewBuilder content: @escaping () -> Content) {
        self.isSelected = isSelected
        self.background = background
        self.showsPlaybackControls = showsPlaybackControls
        self.onOpen = onOpen
        self.onPhoneCastWake = onPhoneCastWake
        self.pcRelayID = pcRelayID
        self.pcRelay = pcRelay
        self.pcRelayWithContext = pcRelayWithContext
        self.filmAnalysis = filmAnalysis
        self.filmSpeech = filmSpeech
        self.content = content
    }

    public var body: some View {
        ZStack {
            if let model {
                CastBrowserScreen(model: model)
                    .allowsHitTesting(isSelected)
                    .accessibilityHidden(!isSelected)
                    .background(CastWakeObserver(model: model, update: onPhoneCastWake))
            }
            content()
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if showsPlaybackControls && !isSelected, let model {
                        playbackBar(model)
                    }
                }
                .background {
                    if !isSelected && model != nil { background }
                }
                .opacity(isSelected ? 0 : 1)
                .allowsHitTesting(!isSelected)
                .accessibilityHidden(isSelected)
        }
        .task(id: isSelected) {
            if isSelected && model == nil {
                let controller = CastAppModel()
                controller.pcRelay = pcRelay
                controller.pcRelayWithContext = pcRelayWithContext
                controller.filmAnalysis = filmAnalysis
                controller.filmSpeech = filmSpeech
                model = controller
            }
        }
        .onChange(of: pcRelayID) { _, _ in
            model?.pcRelay = pcRelay
            model?.pcRelayWithContext = pcRelayWithContext
            model?.filmAnalysis = filmAnalysis
            model?.filmSpeech = filmSpeech
        }
        .task(id: model != nil && phase == .active) {
            guard phase == .active, let webView = model?.browser.webView else { return }
            while !Task.isCancelled {
                if webView.url != nil {
                    let state = await webView.requestMediaPlaybackState()
                    let playing = state == .playing
                    if !Task.isCancelled && playingOnPhone != playing { playingOnPhone = playing }
                }
                do { try await Task.sleep(for: .seconds(1)) }
                catch { return }
            }
        }
    }

    private func playbackBar(_ model: CastAppModel) -> some View {
        CastPlaybackBar(model: model, playingOnPhone: playingOnPhone, open: onOpen,
                        pausePhone: { playingOnPhone = false })
    }
}

@MainActor private struct CastWakeObserver: View {
    @ObservedObject var model: CastAppModel
    @Environment(\.scenePhase) private var phase
    let update: (Bool) -> Void

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .onChange(of: phase == .active && model.needsPhoneAwake, initial: true) { _, value in update(value) }
            .onDisappear { update(false) }
    }
}

@MainActor private struct CastPlaybackBar: View {
    @ObservedObject var model: CastAppModel
    let playingOnPhone: Bool
    let open: () -> Void
    let pausePhone: () -> Void

    var body: some View {
        if model.hasActiveMedia || model.canRetryCast || playingOnPhone { controls }
    }

    private var controls: some View {
        let television = model.hasActiveMedia || model.canRetryCast
        let pause = television ? model.isPlaying : playingOnPhone
        return HStack(spacing: 8) {
            Button {
                model.selectedTab = television ? .remote : .browser
                open()
            } label: {
                Label(television ? model.connectionTitle : "Tilbage til afspilleren", systemImage: television ? "tv" : "play.rectangle")
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
            Button {
                if model.canRetryCast { model.retryCast() }
                else if television { model.togglePlayback() }
                else { model.browser.webView.pauseAllMediaPlayback(completionHandler: pausePhone) }
            } label: {
                Image(systemName: model.canRetryCast ? "arrow.clockwise" : pause ? "pause.fill" : "play.fill")
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel(model.canRetryCast ? "Prøv Cast igen" : pause ? "Sæt afspilning på pause" : "Fortsæt afspilning")
            .disabled(television && !model.canRetryCast && model.castFeedback != nil)
        }
        .buttonStyle(.plain)
        .font(.subheadline.weight(.semibold))
        .padding(.leading, 14).padding(.trailing, 5)
        .background {
            let shape = RoundedRectangle(cornerRadius: 16)
            if #available(iOS 26, *) { Color.clear.glassEffect(.regular, in: shape) }
            else { shape.fill(.regularMaterial) }
        }
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(.primary.opacity(0.12)).allowsHitTesting(false) }
        .padding(.horizontal, 12).padding(.vertical, 4)
    }
}

enum Style {
    // Paper's cyan accent is darker in light mode for readable controls.
    static let accent = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.43, green: 0.87, blue: 0.91, alpha: 1)
            : UIColor(red: 0.0, green: 0.42, blue: 0.47, alpha: 1)
    })
    static let canvas = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.045, green: 0.055, blue: 0.09, alpha: 1)
            : UIColor(red: 0.975, green: 0.965, blue: 0.95, alpha: 1)
    })
    static let card = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.105, green: 0.115, blue: 0.16, alpha: 1)
            : UIColor.white
    })
    static let muted = Color(uiColor: .secondaryLabel)
    static let title = Font.system(.title2, design: .rounded, weight: .bold)
    static let body = Font.system(.body, design: .default)
    static let meta = Font.system(.caption, design: .default)
    static let small: CGFloat = 8
    static let space: CGFloat = 16
    static let radius: CGFloat = 22
}

enum AppTab: Hashable { case home, browser, videos, remote }

struct VideoCandidate: Identifiable, Codable, Equatable {
    var id: String { url }
    let url: String
    let mime: String
    let title: String
    let pageTitle: String
    let pageURL: String
    let poster: String?
    let duration: Double
    let isDirect: Bool
    let subtitles: [SubtitleCandidate]
    let isHLSMaster: Bool?
    let hasAudioTrack: Bool?
}

struct SubtitleCandidate: Codable, Equatable {
    let url: String
    let name: String
    let language: String
    let mime: String
}

struct RecentCast: Identifiable, Codable {
    var id: String { video.pageURL + "|" + video.title }
    let video: VideoCandidate
    let castAt: Date
    var receiverAttempt: UUID?
}

struct BrowserLink: Identifiable, Codable, Equatable {
    var id: String { url }
    var title: String
    var url: String
}
