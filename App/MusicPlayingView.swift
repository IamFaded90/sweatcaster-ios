import AVKit
import SwiftUI

@MainActor struct MusicPlayingView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.fadedPalette) private var palette
    @ObservedObject private var player = MusicPlayer.shared
    @State private var position = 0.0
    @State private var scrubbing = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    if let track = player.current {
                        MusicCover(url: track.artwork)
                            .aspectRatio(1, contentMode: .fit)
                            .frame(maxWidth: 360)
                            .clipShape(RoundedRectangle(cornerRadius: 24))
                            .shadow(color: .black.opacity(0.3), radius: 18, y: 10)
                        VStack(spacing: 4) {
                            Text(track.title).font(.title2.bold()).multilineTextAlignment(.center)
                            Text(track.artist).foregroundStyle(palette.secondary)
                        }
                        Slider(value: Binding(get: { scrubbing ? position : player.position }, set: { position = $0 }),
                               in: 0...max(1, player.duration)) { editing in
                            scrubbing = editing
                            if !editing { player.seek(position) }
                        }.tint(palette.lime).accessibilityLabel("Hvor langt sangen er nået")
                        HStack {
                            Text(time(player.position))
                            Spacer()
                            Text(time(player.duration))
                        }.font(.caption.monospacedDigit())
                        HStack(spacing: 28) {
                            Button("Forrige", systemImage: "backward.end.fill") { player.previous() }
                            Button(player.playing ? "Pause" : "Afspil", systemImage: player.playing ? "pause.circle.fill" : "play.circle.fill") {
                                player.toggle()
                            }.font(.system(size: 52))
                            Button("Næste", systemImage: "forward.end.fill") { player.next() }
                        }.labelStyle(.iconOnly).buttonStyle(.plain).font(.title).frame(minHeight: 60)
                        HStack {
                            Button("Bland", systemImage: "shuffle") { player.shuffle() }
                            Spacer()
                            Toggle("Gentag kø", isOn: $player.repeatAll)
                            Spacer()
                            MusicAirPlayPicker().frame(width: 44, height: 44)
                        }
                        if let end = player.sleepUntil {
                            HStack {
                                Text("Sovetimer til " + end.formatted(date: .omitted, time: .shortened))
                                Button("Slå fra") { player.setSleep(minutes: nil) }
                            }.font(.footnote)
                        }
                        if player.loading { ProgressView("Åbner sang…") }
                        if let notice = player.notice {
                            Text(notice).foregroundStyle(.secondary)
                            Button("Prøv sangen igen", systemImage: "arrow.clockwise") { player.retry() }
                        }
                        Text("Kø").font(.headline).frame(maxWidth: .infinity, alignment: .leading)
                        ForEach(Array(player.queue.enumerated()), id: \.offset) { i, track in
                            HStack {
                                Button { player.play(player.queue, at: i) } label: {
                                    Label(track.title, systemImage: i == player.index ? "speaker.wave.2.fill" : "music.note")
                                        .frame(maxWidth: .infinity, alignment: .leading).lineLimit(2)
                                }.buttonStyle(.plain)
                                Button("Fjern fra kø", systemImage: "minus.circle") { player.remove(at: i) }
                                    .labelStyle(.iconOnly).frame(width: 44, height: 44)
                            }.padding(10).fadedGlassSurface()
                        }
                    }
                }.frame(maxWidth: .infinity).padding(FadedSpacing.edge)
            }.background { FadedBackground() }
                .navigationTitle("Spiller nu").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Luk") { dismiss() } } }
        }
    }

    private func time(_ value: Double) -> String {
        guard value.isFinite else { return "0:00" }
        return "\(Int(value) / 60):" + String(format: "%02d", Int(value) % 60)
    }
}

private struct MusicAirPlayPicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView { AVRoutePickerView() }
    func updateUIView(_ view: AVRoutePickerView, context: Context) {}
}
