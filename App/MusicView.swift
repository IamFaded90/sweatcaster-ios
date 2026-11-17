import SafariServices
import SwiftUI

@MainActor struct MusicView: View {
    let onBack: () -> Void
    @Environment(\.fadedPalette) private var palette
    @State private var catalogOpen = false
    private let catalog = URL(string: "https://music.youtube.com/")!
    private let byTune = URL(string: "https://bytune.space/")!

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: FadedSpacing.l) {
                    FadedCard(size: .hero) {
                        VStack(alignment: .leading, spacing: FadedSpacing.m) {
                            Label("YouTube Music", systemImage: "music.note.list")
                                .font(.title.bold())
                            FadedDetailText("Søg efter musik i kataloget uden at importere filer. Gratis afspilning kan indeholde reklamer.")
                            FadedPrimaryButton("Åbn YouTube Music", icon: "play.fill") {
                                catalogOpen = true
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    FadedCard {
                        VStack(alignment: .leading, spacing: FadedSpacing.s) {
                            Text("ByTune på computer").font(.headline)
                            FadedDetailText("ByTune findes til Windows og Mac.")
                            Link(destination: byTune) {
                                Label("Se ByTune til PC og Mac", systemImage: "arrow.up.right")
                                    .frame(minHeight: 44)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(FadedSpacing.edge)
                .frame(maxWidth: 620)
                .frame(maxWidth: .infinity)
            }
            .foregroundStyle(palette.text)
            .background { FadedBackground() }
            .navigationTitle("Musik")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Tilbage", systemImage: "chevron.left", action: onBack)
                }
            }
            .sheet(isPresented: $catalogOpen) {
                MusicCatalogBrowser(url: catalog).ignoresSafeArea()
            }
        }
    }
}

private struct MusicCatalogBrowser: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let browser = SFSafariViewController(url: url)
        browser.dismissButtonStyle = .close
        return browser
    }

    func updateUIViewController(_ browser: SFSafariViewController, context: Context) {}
}
