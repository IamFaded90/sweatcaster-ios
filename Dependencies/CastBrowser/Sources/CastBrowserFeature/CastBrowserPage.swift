import SwiftUI

struct BrowserScreen: View {
    @ObservedObject var model: CastAppModel
    @ObservedObject private var browser: BrowserController
    @State private var showBookmarks = false
    @State private var showHistory = false
    @State private var isOpeningPictureInPicture = false
    @State private var pictureInPictureUnavailable = false
    @FocusState private var addressFocused: Bool
    private let isVisible: Bool

    init(model: CastAppModel, isVisible: Bool = true) {
        self.model = model
        self.isVisible = isVisible
        _browser = ObservedObject(wrappedValue: model.browser)
    }

    private var isBookmarked: Bool { model.bookmarks.contains { $0.url == browser.address } }

    var body: some View {
        Group {
            VStack(spacing: Style.small) {
                HStack(spacing: Style.small) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Style.muted)
                    TextField("Søg eller indtast adresse", text: $browser.address)
                        .font(Style.body).focused($addressFocused)
                        .textInputAutocapitalization(.never).keyboardType(.URL)
                        .autocorrectionDisabled().submitLabel(.go)
                        .onSubmit { addressFocused = false; model.searchOrLoad(browser.address) }
                        .accessibilityLabel("Søg eller indtast webadresse")
                    Button { model.addBookmark() } label: {
                        Image(systemName: isBookmarked ? "star.fill" : "star").frame(width: 44, height: 44)
                    }.accessibilityLabel("Gem siden som favorit")
                }
                .padding(.leading, Style.space)
                .background(Style.card, in: RoundedRectangle(cornerRadius: 16))

                VStack(alignment: .leading, spacing: Style.small) {
                    Toggle(isOn: Binding(get: { browser.adBlockingEnabled }, set: browser.setAdBlocking)) {
                        Label("Blokér reklamer", systemImage: browser.adBlockingEnabled ? "shield.fill" : "shield")
                    }
                    .frame(minHeight: 44)
                    .disabled(browser.settingAdBlocking)
                    if let notice = browser.adBlockingNotice {
                        Text(notice).font(.footnote).foregroundStyle(Style.muted)
                    }
                }
                .padding(.horizontal, Style.space)
                .background(Style.card, in: RoundedRectangle(cornerRadius: 16))

                if browser.isLoading {
                    ProgressView().progressViewStyle(.linear).tint(Style.accent)
                        .accessibilityLabel("Indlæser hjemmeside")
                }

                WebView(webView: browser.webView)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay(alignment: .bottom) {
                        if let single = model.displayVideos.first, model.displayVideos.count == 1 {
                            Button {
                                addressFocused = false
                                model.cast(single)
                            } label: {
                                HStack(spacing: Style.small) {
                                    Image(systemName: "tv")
                                    Text("Cast fundet video")
                                    Spacer(minLength: 0)
                                    Image(systemName: "arrow.up.right")
                                }
                                .font(Style.body.weight(.semibold)).padding(Style.space)
                                .foregroundStyle(.white)
                                .background(Style.accent, in: RoundedRectangle(cornerRadius: 16))
                            }.buttonStyle(.plain).padding(Style.small)
                        } else if !model.displayVideos.isEmpty {
                            Button { addressFocused = false; model.selectedTab = .videos } label: {
                                HStack(spacing: Style.small) {
                                    Image(systemName: "play.rectangle.fill")
                                    Text("\(model.displayVideos.count) videoer med lyd")
                                    Spacer(minLength: 0)
                                    Image(systemName: "arrow.right")
                                }
                                .font(Style.body.weight(.semibold)).padding(Style.space)
                                .foregroundStyle(.white)
                                .background(Style.accent, in: RoundedRectangle(cornerRadius: 16))
                            }.buttonStyle(.plain).padding(Style.small)
                        }
                    }
                HStack(spacing: Style.small) {
                    BrowserAction(icon: "chevron.left", label: "Tilbage", disabled: !browser.canGoBack) { browser.goBack() }
                    BrowserAction(icon: "chevron.right", label: "Frem", disabled: !browser.canGoForward) { browser.goForward() }
                    BrowserAction(icon: "arrow.clockwise", label: "Genindlæs", disabled: browser.settingAdBlocking) { browser.reload() }
                    BrowserAction(icon: "star", label: "Favoritsider") { showBookmarks = true }
                    BrowserAction(icon: "clock", label: "Historik") { showHistory = true }
                }
            }
            .padding(.horizontal, Style.space).padding(.top, Style.small)
            .background(Style.canvas)
            .onChange(of: isVisible) { _, visible in if !visible { addressFocused = false } }
            .toolbar {
                if isVisible { ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 0) {
                        Button("Billede i billede", systemImage: "pip.enter") {
                            openPictureInPicture()
                        }
                        .labelStyle(.iconOnly)
                        .frame(width: 44, height: 44)
                        .disabled(isOpeningPictureInPicture || browser.isLoading)
                    }
                } }
            }
            .onAppear { model.openHome() }
            .sheet(isPresented: $showBookmarks) {
                LinkListSheet(title: "Favoritsider", links: model.bookmarks, onOpen: model.open, onDelete: model.removeBookmark)
            }
            .sheet(isPresented: $showHistory) {
                LinkListSheet(title: "Historik", links: model.history, onOpen: model.open, onDelete: { _ in }, allowsDelete: false)
            }
            .alert("Lille videovindue", isPresented: $pictureInPictureUnavailable) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Start filmen først. Prøv filmens egen knap til Billede i billede, hvis den vises.")
            }
        }
    }

    private func openPictureInPicture() {
        addressFocused = false
        isOpeningPictureInPicture = true
        Task {
            pictureInPictureUnavailable = !(await browser.startPictureInPicture())
            isOpeningPictureInPicture = false
        }
    }
}

struct BrowserAction: View {
    let icon: String
    let label: String
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(Style.body)
                .frame(maxWidth: .infinity).frame(minHeight: 44).contentShape(Rectangle())
        }
        .disabled(disabled)
        .foregroundStyle(disabled ? Style.muted.opacity(0.4) : Color.primary)
        .accessibilityLabel(label)
    }
}
