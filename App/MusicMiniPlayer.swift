import SwiftUI

struct MusicMiniPlayer: View {
    let open: () -> Void
    @ObservedObject private var player = MusicPlayer.shared
    var body: some View {
        if let track = player.current {
            HStack(spacing: 12) {
                Button(action: open) {
                    HStack(spacing: 10) {
                        Image(systemName: "waveform").foregroundStyle(FadedBrand.gradient).font(.title2)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(track.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                            Text(player.loading ? "Åbner musikken…" : track.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(minHeight: 48)
                }.buttonStyle(.plain).accessibilityLabel("Åbn musikafspilleren · " + track.title)
                Button(player.canPause ? "Pause" : "Afspil", systemImage: player.canPause ? "pause.fill" : "play.fill") { player.toggle() }
                    .labelStyle(.iconOnly).frame(width: 48, height: 48)
                Button("Næste", systemImage: "forward.end.fill") { player.next() }.labelStyle(.iconOnly).frame(width: 44, height: 48)
            }.padding(.horizontal, 12).fadedGlassSurface(radius: 18)
        }
    }
}
