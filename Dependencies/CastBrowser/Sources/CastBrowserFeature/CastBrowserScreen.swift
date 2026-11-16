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
    private let content: () -> Content
    @Environment(\.scenePhase) private var phase
    @State private var model: CastAppModel?
    @State private var playingOnPhone = false

    public init(isSelected: Bool, background: AnyView, showsPlaybackControls: Bool = true,
                onOpen: @escaping () -> Void, @ViewBuilder content: @escaping () -> Content) {
        self.isSelected = isSelected
        self.background = background
        self.showsPlaybackControls = showsPlaybackControls
        self.onOpen = onOpen
        self.content = content
    }

    public var body: some View {
        ZStack {
            if let model {
                CastBrowserScreen(model: model)
                    .allowsHitTesting(isSelected)
                    .accessibilityHidden(!isSelected)
            }
            content()
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if showsPlaybackControls && !isSelected && playingOnPhone { playbackBar }
                }
                .background {
                    if !isSelected && model != nil { background }
                }
                .opacity(isSelected ? 0 : 1)
                .allowsHitTesting(!isSelected)
                .accessibilityHidden(isSelected)
        }
        .task(id: isSelected) {
            if isSelected && model == nil { model = CastAppModel() }
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

    private var playbackBar: some View {
        HStack(spacing: 8) {
            Button {
                model?.selectedTab = .browser
                onOpen()
            } label: {
                Label("Tilbage til afspilleren", systemImage: "play.rectangle")
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
            Button {
                model?.browser.webView.pauseAllMediaPlayback { playingOnPhone = false }
            } label: {
                Image(systemName: "pause.fill").frame(width: 44, height: 44)
            }
            .accessibilityLabel("Sæt afspilning på pause")
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
}

struct BrowserLink: Identifiable, Codable, Equatable {
    var id: String { url }
    var title: String
    var url: String
}
