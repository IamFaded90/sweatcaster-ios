import SwiftUI

/// Opens the installed Spotify URL handler. Does not embed or authenticate Spotify.
@MainActor struct MusicView: View {
    let onBack: () -> Void
    @Environment(\.openURL) private var openURL
    @Environment(\.fadedPalette) private var palette
    @State private var opening = false
    @State private var notice: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Dit soundtrack.", systemImage: "music.note.list")
                            .font(.largeTitle.bold())
                        Text("Sæt noget på. Find din ro.").font(.headline)
                    }
                    .padding(24).frame(maxWidth: .infinity, alignment: .leading)
                    .background(ChatGlassSurface(radius: 24, colors: [FadedBrand.mint, FadedColors.purple]))

                    VStack(alignment: .leading, spacing: 16) {
                        Text("Musik med Eevee / Spotify").font(.title2.bold())
                        Text("Åbn din musikapp, log ind dér, og vælg noget at høre.")
                        Button(action: openMusic) {
                            Label(opening ? "Åbner…" : "Åbn musikappen", systemImage: "play.fill")
                                .font(.headline).frame(maxWidth: .infinity, minHeight: 52)
                                .foregroundStyle(FadedColors.deep)
                                .background(LinearGradient(colors: [Color(red: 0.8, green: 1, blue: 0.42), FadedBrand.mint],
                                                           startPoint: .leading, endPoint: .trailing),
                                            in: RoundedRectangle(cornerRadius: 16))
                        }.buttonStyle(.plain).disabled(opening)
                        Text("Musikken åbner i en separat app. Kø, playlister og sovetimer styres dér. Du behøver ingen PC eller udviklernøgler for denne genvej.")
                            .font(.footnote).foregroundStyle(palette.secondary)
                        if let notice {
                            Text(notice).font(.callout).accessibilityAddTraits(.updatesFrequently)
                        }
                    }
                    .padding(20).fadedGlassSurface(radius: 24)

                    DisclosureGroup("Hvis appen ikke åbner") {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Eevee skal være installeret på din iPhone først. Genvejen åbner den app, iOS bruger til Spotify-links. Har du både almindelig Spotify og Eevee, kan iOS vælge den almindelige app.")
                            Link("Åbn Eevee-projektet", destination: URL(string: "https://github.com/SideloadLabs/EeveeSpotifyReincarnated")!)
                        }.font(.footnote).padding(.top, 8)
                    }
                    .padding(18).fadedGlassSurface(radius: 20)
                    Text("Dit musiklogin bliver i musikappen. FadedAI læser hverken din adgangskode eller din musik.")
                        .font(.caption).foregroundStyle(palette.secondary)
                }
                .padding(18).frame(maxWidth: 620).frame(maxWidth: .infinity)
            }
            .background(FadedBackground())
            .navigationTitle("Musik")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Tilbage", systemImage: "chevron.left", action: onBack)
                }
            }
        }
    }

    private func openMusic() {
        guard !opening, let url = URL(string: "spotify:") else { return }
        opening = true
        notice = nil
        openURL(url) { accepted in
            opening = false
            if !accepted {
                notice = "iPhone kunne ikke åbne Spotify-linket. Installér og åbn Eevee først, og prøv derefter igen."
            }
        }
    }
}
