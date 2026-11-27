import SwiftUI
import GoogleCast
import WebKit

// Presentation only: media discovery, authentication and HLS proxying stay in CastAppModel.
struct HomeScreen: View {
    @ObservedObject var model: CastAppModel
    @State private var showAddFavorite = false
    @State private var showVidora = false
    @State private var filmQuery = ""
    private let columns = [GridItem(.flexible(), spacing: Style.space), GridItem(.flexible(), spacing: Style.space)]

    var body: some View {
        Group {
            ScrollView {
                VStack(alignment: .leading, spacing: Style.space) {
                    HStack(alignment: .center, spacing: Style.space) {
                        VStack(alignment: .leading, spacing: Style.small) {
                            Text("Din næste filmaften")
                                .font(.system(.title, design: .default, weight: .bold))
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityAddTraits(.isHeader)
                            Text("På din iPhone eller dit TV")
                                .font(Style.body).foregroundStyle(Style.heroInk.opacity(0.8))
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "play.rectangle.on.rectangle")
                            .font(.system(size: 40, weight: .light))
                            .frame(width: 66, height: 66)
                            .clipShape(RoundedRectangle(cornerRadius: 20))
                            .accessibilityHidden(true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
                    .foregroundStyle(Style.heroInk)
                    .background(LinearGradient(colors: [Style.heroStart, Style.heroEnd],
                                               startPoint: .topLeading, endPoint: .bottomTrailing),
                                in: RoundedRectangle(cornerRadius: Style.radius))

                    HStack(spacing: 12) {
                        Image(systemName: "magnifyingglass").foregroundStyle(Style.accent)
                        TextField("Find en film eller serie", text: $filmQuery).textFieldStyle(.plain)
                            .submitLabel(.search).onSubmit(searchFilm)
                        Button("Søg", systemImage: "arrow.right", action: searchFilm)
                            .labelStyle(.iconOnly).frame(width: 44, height: 44)
                            .disabled(filmQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }.padding(.leading, 16).background(Style.card, in: RoundedRectangle(cornerRadius: 20))
                    Text("Søgningen åbner TMDB. På en film vælger du Afspil i FadedAI.")
                        .font(Style.meta).foregroundStyle(Style.muted)
                    Button { showVidora = true } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "play.circle.fill").font(.title2).foregroundStyle(Style.accent)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Har du et filmlink?").font(.headline)
                                Text("Åbn direkte i Film · afspiller fra Vidora").font(Style.meta).foregroundStyle(Style.muted)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                        }.padding(16).background(Style.card, in: RoundedRectangle(cornerRadius: Style.radius))
                    }.buttonStyle(.plain)
                    ConnectionCard(model: model)
                    if model.hasActiveMedia {
                        Button { model.selectedTab = .remote } label: {
                            HStack(spacing: Style.space) {
                                MediaArtwork(poster: model.currentPoster)
                                    .frame(width: 64, height: 64).clipped()
                                    .clipShape(RoundedRectangle(cornerRadius: 16))
                                VStack(alignment: .leading, spacing: Style.small) {
                                    Text(model.nowPlayingTitle).font(Style.body.weight(.semibold)).lineLimit(2)
                                    Label(model.isPlaying ? "Afspiller nu" : "Åbn fjernbetjening",
                                          systemImage: model.isPlaying ? "waveform" : "slider.horizontal.3")
                                        .font(Style.meta).foregroundStyle(Style.accent)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right").foregroundStyle(Style.muted)
                            }
                            .padding(Style.space)
                            .background(Style.card, in: RoundedRectangle(cornerRadius: Style.radius))
                        }.buttonStyle(.plain)
                    }

                    HStack {
                        Text("Favoritsider").font(Style.title)
                        Spacer()
                        Button { showAddFavorite = true } label: {
                            Image(systemName: "plus").frame(width: 44, height: 44)
                        }.accessibilityLabel("Tilføj favoritside")
                    }
                    if model.bookmarks.isEmpty {
                        EmptyCard(icon: "star", title: "Dine favoritter starter her",
                                  message: "Tryk på plus for at gemme en hjemmeside.")
                    } else {
                        LazyVGrid(columns: columns, spacing: Style.space) {
                            ForEach(model.bookmarks) { link in
                                FavoriteTile(link: link, open: { model.open(link) },
                                             remove: { model.removeBookmark(link) })
                            }
                        }
                    }

                    Button { model.selectedTab = .browser } label: {
                        Label("Åbn browser", systemImage: "safari")
                            .frame(maxWidth: .infinity).padding(.vertical, Style.small)
                    }.buttonStyle(.borderedProminent).controlSize(.large)

                    if !model.recentCasts.isEmpty {
                        Text("Seneste castede").font(Style.title).padding(.top, Style.small)
                        ForEach(model.recentCasts) { item in
                            RecentCastRow(item: item) { model.castRecent(item) }
                        }
                    }
                }.padding(Style.space)
            }
            .background { FilmBackground() }
            .sheet(isPresented: $showAddFavorite) { AddFavoriteSheet(model: model) }
            .sheet(isPresented: $showVidora) {
                VidoraOpenSheet { model.open(BrowserLink(title: "Afspiller", url: $0.absoluteString)) }
            }
        }
    }

    private func searchFilm() {
        let text = filmQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if let reference = VidoraReference(input: text) {
            model.open(BrowserLink(title: "Afspiller", url: reference.playerURL.absoluteString))
        } else {
            var url = URLComponents(string: "https://www.themoviedb.org/search")!
            url.queryItems = [.init(name: "query", value: String(text.prefix(200)))]
            if let url = url.url { model.open(BrowserLink(title: "Find film", url: url.absoluteString)) }
        }
    }
}

struct FavoriteTile: View {
    let link: BrowserLink
    let open: () -> Void
    let remove: () -> Void
    @ObservedObject private var previews = FavoritePreviewStore.shared

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 0) {
                Group {
                    if let preview = previews.images[link.url] {
                        Image(uiImage: preview)
                            .resizable()
                            .scaledToFill()
                    } else {
                        ZStack {
                            Style.canvas
                            Image(systemName: "globe")
                                .font(.system(size: 30))
                                .foregroundStyle(Style.accent)
                        }
                    }
                }
                .frame(height: 112)
                .frame(maxWidth: .infinity)
                .clipped()
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: Style.small) {
                    Text(link.title).font(Style.body.weight(.semibold)).lineLimit(1)
                    Text(URL(string: link.url)?.host ?? "Hjemmeside")
                        .font(Style.meta).foregroundStyle(Style.muted).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Style.space)
            }
            .background(Style.card, in: RoundedRectangle(cornerRadius: Style.radius))
            .clipShape(RoundedRectangle(cornerRadius: Style.radius))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Åbn " + link.title)
        .onAppear { previews.request(link.url) }
        .contextMenu {
            Button(action: open) { Label("Åbn", systemImage: "safari") }
            Button(role: .destructive, action: remove) { Label("Fjern favorit", systemImage: "star.slash") }
        }
    }
}

struct RecentCastRow: View {
    let item: RecentCast
    let castAgain: () -> Void

    var body: some View {
        Button(action: castAgain) {
            HStack(spacing: Style.space) {
                MediaArtwork(poster: item.video.poster)
                    .frame(width: 64, height: 80).clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                VStack(alignment: .leading, spacing: Style.small) {
                    Text(item.video.title).font(Style.body.weight(.semibold)).lineLimit(2)
                    Text(item.castAt.formatted(date: .abbreviated, time: .shortened))
                        .font(Style.meta).foregroundStyle(Style.muted)
                    Label("Cast igen", systemImage: "tv").font(Style.meta).foregroundStyle(Style.accent)
                }
                Spacer(minLength: 0)
                Image(systemName: "play.fill").foregroundStyle(Style.accent)
            }
            .padding(Style.space)
            .background(Style.card, in: RoundedRectangle(cornerRadius: Style.radius))
        }.buttonStyle(.plain).accessibilityLabel("Cast " + item.video.title + " igen")
    }
}

struct ConnectionCard: View {
    @ObservedObject var model: CastAppModel

    var body: some View {
        Button {
            let context = GCKCastContext.sharedInstance()
            context.discoveryManager.startDiscovery()
            context.presentCastDialog()
        } label: {
            HStack(spacing: Style.space) {
                Image(systemName: model.hasActiveMedia ? "play.tv.fill" : (model.hasSession ? "tv.fill" : "tv"))
                    .font(.system(size: 24))
                    .frame(width: 48, height: 48)
                    .foregroundStyle(model.hasSession ? Style.accent : Style.muted)
                    .background(Style.accent.opacity(model.hasSession ? 0.12 : 0.04), in: RoundedRectangle(cornerRadius: 16))
                VStack(alignment: .leading, spacing: Style.small) {
                    Text(model.connectionTitle).font(Style.body.weight(.semibold))
                    Text(model.deviceName ?? "Tryk for at vælge din Chromecast")
                        .font(Style.meta).foregroundStyle(Style.muted).lineLimit(2)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").foregroundStyle(Style.muted)
            }
            .padding(Style.space)
            .background(Style.card, in: RoundedRectangle(cornerRadius: Style.radius))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(model.connectionTitle + ". " + (model.deviceName ?? "Vælg enhed"))
    }
}

struct VideosScreen: View {
    @ObservedObject var model: CastAppModel

    var body: some View {
        Group {
            ScrollView {
                VStack(alignment: .leading, spacing: Style.space) {
                    Text("Klar til dit TV").font(Style.title)
                    Text("Kun videoer med registreret lyd. Dubletter er samlet.")
                        .font(Style.body).foregroundStyle(Style.muted)
                    if model.displayVideos.isEmpty {
                        EmptyCard(icon: "play.rectangle", title: "Start videoen i browseren",
                                  message: "Når video og lyd er fundet, vises filmen her.")
                        Button { model.selectedTab = .browser } label: {
                            Label("Åbn browser", systemImage: "safari")
                                .frame(maxWidth: .infinity).padding(.vertical, Style.small)
                        }.buttonStyle(.borderedProminent).controlSize(.large)
                    } else {
                        ForEach(model.displayVideos) { video in VideoCard(video: video, model: model) }
                    }
                }.padding(Style.space)
            }
            .background { FilmBackground() }
        }
    }
}

struct VideoCard: View {
    let video: VideoCandidate
    @ObservedObject var model: CastAppModel

    private var active: Bool { model.hasActiveMedia && model.nowPlayingTitle == video.title }

    var body: some View {
        VStack(spacing: 0) {
            MediaArtwork(poster: video.poster)
                .frame(height: 176).clipped()
                .overlay(alignment: .topLeading) {
                    if active {
                        Label("På dit TV", systemImage: "play.tv.fill")
                            .font(Style.meta.weight(.semibold)).padding(Style.small)
                            .background(.regularMaterial, in: Capsule()).padding(Style.space)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if video.duration > 0 {
                        Text(video.duration.clockString).font(Style.meta.monospacedDigit())
                            .padding(Style.small).background(.black.opacity(0.75), in: Capsule())
                            .foregroundStyle(.white).padding(Style.space)
                    }
                }
            VStack(alignment: .leading, spacing: Style.space) {
                Text(video.title).font(Style.title).lineLimit(2)
                HStack(spacing: Style.small) {
                    Label("Med lyd", systemImage: "speaker.wave.2")
                    Spacer()
                    Text(URL(string: video.pageURL)?.host ?? video.pageTitle).lineLimit(1)
                }.font(Style.meta).foregroundStyle(Style.muted)
                Button {
                    if active { model.selectedTab = .remote } else { model.cast(video) }
                } label: {
                    Label(active ? "Åbn fjernbetjening" : "Cast til TV",
                          systemImage: active ? "slider.horizontal.3" : "tv")
                        .font(Style.body.weight(.semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, Style.small)
                }.buttonStyle(.borderedProminent).controlSize(.large).disabled(!video.isDirect)
            }.padding(Style.space)
        }
        .background(Style.card, in: RoundedRectangle(cornerRadius: Style.radius))
        .clipShape(RoundedRectangle(cornerRadius: Style.radius))
        .overlay(RoundedRectangle(cornerRadius: Style.radius).stroke(active ? Style.accent : Color.primary.opacity(0.06), lineWidth: active ? 2 : 1))
    }
}

struct RemoteScreen: View {
    @ObservedObject var model: CastAppModel
    @State private var showsFilmCompanion = false

    var body: some View {
        Group {
            ScrollView {
                VStack(spacing: Style.space) {
                    ConnectionCard(model: model)
                    if model.castFeedback != nil || model.canRetryCast {
                        VStack(alignment: .leading, spacing: Style.small) {
                            HStack(spacing: Style.space) {
                                if model.castFeedback != nil { ProgressView().tint(Style.accent) }
                                Text(model.playbackMessage).font(Style.body)
                            }
                            if model.canRetryCast {
                                Button("Prøv igen") { model.retryCast() }
                                    .buttonStyle(.borderedProminent).controlSize(.large)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).padding(Style.space)
                        .background(Style.card, in: RoundedRectangle(cornerRadius: Style.radius))
                    }
                    RemoteArtworkCard(model: model)
                    RemoteTransport(model: model)
                    Button { showsFilmCompanion = true } label: {
                        Label("Spørg filmvennen", systemImage: "bubble.left.and.text.bubble.right")
                            .frame(maxWidth: .infinity).padding(.vertical, Style.small)
                    }.buttonStyle(.bordered).controlSize(.large)
                    RemoteVolume(model: model)
                    Text(model.screenOffMessage)
                        .font(Style.meta).foregroundStyle(Style.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let target = model.pcSwitchTarget {
                        Button { Task { await model.switchPlaybackToPC() } } label: {
                            Label(model.pcSwitchID == nil ? "Prøv via PC" : "Tjekker filmen på PC…", systemImage: "desktopcomputer")
                        }.buttonStyle(.bordered).controlSize(.large).disabled(model.pcSwitchID != nil)
                        if model.pcSwitchFailure == target.frame.source {
                            Text("PC’en kunne ikke klargøre filmen. Du kan fortsætte via iPhone og prøve igen.")
                                .font(Style.meta).foregroundStyle(Style.muted)
                        }
                    }
                    if model.hasSubtitleTracks {
                        Button { model.toggleSubtitles() } label: {
                            Label("Slå undertekster til / fra", systemImage: "captions.bubble")
                                .frame(maxWidth: .infinity).padding(.vertical, Style.small)
                        }.buttonStyle(.bordered).controlSize(.large)
                    }
                    if model.hasSession {
                        HStack(spacing: Style.space) {
                            Button { model.stopPlayback() } label: { Label("Stop", systemImage: "stop.fill") }
                                .buttonStyle(.bordered).controlSize(.large)
                            Spacer()
                            Button("Afbryd TV", role: .destructive) { model.endSession() }
                                .font(Style.body)
                        }
                    } else {
                        Text("Din iPhone og Chromecast skal være på samme Wi-Fi.")
                            .font(Style.meta).foregroundStyle(Style.muted).multilineTextAlignment(.center)
                    }
                }.padding(Style.space)
            }
            .background { FilmBackground() }
            .sheet(isPresented: $showsFilmCompanion) { FilmCompanionView(model: model) }
        }
    }
}

struct RemoteArtworkCard: View {
    @ObservedObject var model: CastAppModel
    var body: some View {
        VStack(spacing: Style.space) {
            MediaArtwork(poster: model.currentPoster)
                .frame(height: 192).clipped()
                .clipShape(RoundedRectangle(cornerRadius: 16))
            Text(model.nowPlayingTitle).font(Style.title).multilineTextAlignment(.center).lineLimit(3)
            Text(model.playbackMessage).font(Style.meta).foregroundStyle(Style.muted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(Style.space)
        .background(Style.card, in: RoundedRectangle(cornerRadius: Style.radius))
    }
}

struct RemoteTransport: View {
    @ObservedObject var model: CastAppModel
    @State private var scrubbing = false
    @State private var draftPosition: Double = 0

    var body: some View {
        VStack(spacing: Style.space) {
            VStack(spacing: Style.small) {
                Slider(value: Binding(
                    get: { scrubbing ? draftPosition : min(model.playbackPosition, max(model.playbackDuration, 1)) },
                    set: { draftPosition = $0 }
                ), in: 0...max(model.playbackDuration, 1), onEditingChanged: { editing in
                    if editing { draftPosition = model.playbackPosition; scrubbing = true }
                    else { scrubbing = false; model.seek(to: draftPosition) }
                })
                .tint(Style.accent).disabled(!model.hasSession || model.playbackDuration <= 0)
                .accessibilityLabel("Afspilningsposition")
                HStack {
                    Text((scrubbing ? draftPosition : model.playbackPosition).clockString)
                    Spacer()
                    Text(model.playbackDuration.clockString)
                }.font(Style.meta.monospacedDigit()).foregroundStyle(Style.muted)
            }
            HStack(spacing: Style.space) {
                Button { model.seek(to: max(0, model.playbackPosition - 10)) } label: {
                    Image(systemName: "gobackward.10").font(.system(size: 28)).frame(width: 56, height: 56)
                }.accessibilityLabel("10 sekunder tilbage")
                Spacer(minLength: 0)
                Button { model.togglePlayback() } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 28)).frame(width: 80, height: 80)
                        .background(Style.accent, in: Circle()).foregroundStyle(Style.heroInk)
                }.accessibilityLabel(model.isPlaying ? "Pause" : "Afspil")
                Spacer(minLength: 0)
                Button {
                    let next = model.playbackPosition + 10
                    model.seek(to: model.playbackDuration > 0 ? min(next, model.playbackDuration) : next)
                } label: {
                    Image(systemName: "goforward.10").font(.system(size: 28)).frame(width: 56, height: 56)
                }.accessibilityLabel("10 sekunder frem")
            }.buttonStyle(.plain).disabled(!model.hasSession).foregroundStyle(Color.primary)
        }
        .padding(Style.space)
        .background(Style.card, in: RoundedRectangle(cornerRadius: Style.radius))
    }
}

struct RemoteVolume: View {
    @ObservedObject var model: CastAppModel
    var body: some View {
        VStack(alignment: .leading, spacing: Style.small) {
            HStack {
                Text("TV-lyd").font(Style.body.weight(.semibold))
                Spacer()
                Text(model.receiverMuted ? "Lydløs" : "\(Int(model.receiverVolume * 100)) %")
                    .font(Style.meta.monospacedDigit()).foregroundStyle(Style.muted)
            }
            HStack(spacing: Style.small) {
                Button { model.toggleMute() } label: {
                    Image(systemName: model.receiverMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(model.receiverMuted ? "Slå TV-lyd til" : "Slå TV-lyd fra")
                Slider(value: Binding(get: { model.receiverVolume }, set: { model.setVolume($0) }), in: 0...1)
                    .tint(Style.accent).accessibilityLabel("TV-lydstyrke")
                Image(systemName: "speaker.wave.3.fill").foregroundStyle(Style.muted).accessibilityHidden(true)
            }.disabled(!model.hasSession)
        }
        .padding(Style.space)
        .background(Style.card, in: RoundedRectangle(cornerRadius: Style.radius))
    }
}

struct MediaArtwork: View {
    let poster: String?
    var body: some View {
        ZStack {
            Rectangle().fill(Style.accent.opacity(0.10))
            Image(systemName: "play.rectangle")
                .font(.system(size: 40, weight: .light)).foregroundStyle(Style.accent)
            if let poster, let url = URL(string: poster) {
                AsyncImage(url: url) { phase in
                    if let image = phase.image { image.resizable().scaledToFill() }
                }
            }
        }
    }
}

struct EmptyCard: View {
    let icon: String
    let title: String
    let message: String
    var body: some View {
        VStack(spacing: Style.space) {
            Image(systemName: icon).font(.system(size: 32)).foregroundStyle(Style.accent)
            Text(title).font(Style.title)
            Text(message).font(Style.body).foregroundStyle(Style.muted).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(Style.space)
        .background(Style.card, in: RoundedRectangle(cornerRadius: Style.radius))
    }
}

struct LinkListSheet: View {
    let title: String
    let links: [BrowserLink]
    let onOpen: (BrowserLink) -> Void
    let onDelete: (BrowserLink) -> Void
    var allowsDelete = true
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if links.isEmpty { Text("Her er endnu ingen gemte sider.").foregroundStyle(Style.muted) }
                ForEach(links) { link in
                    Button { onOpen(link); dismiss() } label: {
                        VStack(alignment: .leading, spacing: Style.small) {
                            Text(link.title).font(Style.body.weight(.semibold))
                            Text(URL(string: link.url)?.host ?? link.url)
                                .font(Style.meta).foregroundStyle(Style.muted).lineLimit(1)
                        }.padding(.vertical, Style.small)
                    }
                    .listRowBackground(Style.card)
                    .swipeActions {
                        if allowsDelete {
                            Button(role: .destructive) { onDelete(link) } label: { Label("Fjern", systemImage: "trash") }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden).background { FilmBackground() }
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Færdig") { dismiss() } } }
        }.presentationDetents([.medium, .large]).presentationBackground { FilmBackground() }
    }
}

struct AddFavoriteSheet: View {
    @ObservedObject var model: CastAppModel
    @State private var title = ""
    @State private var address = ""
    @State private var invalidAddress = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Favoritside") {
                    TextField("Navn", text: $title)
                    TextField("Webadresse", text: $address)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                }.listRowBackground(Style.card)
                if invalidAddress { Text("Indtast en gyldig webadresse, fx example.com.").foregroundStyle(Style.accent) }
            }
            .scrollContentBackground(.hidden).background { FilmBackground() }
            .navigationTitle("Ny favorit").navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Annuller") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Gem") {
                        if model.saveFavorite(title: title, address: address) { dismiss() }
                        else { invalidAddress = true }
                    }.disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }.presentationDetents([.medium, .large]).presentationBackground { FilmBackground() }
    }
}
