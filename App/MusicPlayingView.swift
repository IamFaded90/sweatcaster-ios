import AVKit
import SwiftUI

@MainActor struct MusicPlayingView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.fadedPalette) private var palette
    @Environment(\.dynamicTypeSize) private var typeSize
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
                            .clipShape(.rect(cornerRadius: 18))
                            .padding(6)
                            .background(MusicEdition.surface(palette), in: .rect(cornerRadius: 24))
                            .shadow(color: MusicEdition.ink.opacity(0.24), radius: 12, y: 6)
                        VStack(spacing: 4) {
                            Text(track.title).font(.system(.title, design: .serif, weight: .bold))
                                .multilineTextAlignment(.center)
                            Text(track.artist).foregroundStyle(palette.secondary)
                        }
                        Slider(value: Binding(get: { scrubbing ? position : player.position }, set: { position = $0 }),
                               in: 0...max(1, player.duration)) { editing in
                            scrubbing = editing
                            if !editing { player.seek(position) }
                        }.accessibilityLabel("Hvor langt sangen er nået")
                            .accessibilityValue(time(scrubbing ? position : player.position) + " af " + time(player.duration))
                        HStack {
                            Text(time(scrubbing ? position : player.position))
                            Spacer()
                            Text(time(player.duration))
                        }.font(.caption.monospacedDigit())
                        HStack(spacing: 28) {
                            Button { player.previous() } label: {
                                Label("Forrige", systemImage: "backward.end.fill").frame(minWidth: 44, minHeight: 44)
                            }
                            Button(player.canPause ? "Pause" : "Afspil", systemImage: player.canPause ? "pause.circle.fill" : "play.circle.fill") {
                                player.toggle()
                            }.font(.system(size: 52)).foregroundStyle(MusicEdition.accent(palette))
                            Button { player.next() } label: {
                                Label("Næste", systemImage: "forward.end.fill").frame(minWidth: 44, minHeight: 44)
                            }
                        }.labelStyle(.iconOnly).buttonStyle(.plain).font(.title).frame(minHeight: 60)
                        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout()) : AnyLayout(HStackLayout(spacing: 14))
                        layout {
                            Button("Bland", systemImage: "shuffle") { player.shuffle() }.frame(minHeight: 44)
                            Toggle("Gentag kø", isOn: $player.repeatAll)
                            MusicAirPlayPicker().frame(width: 44, height: 44).accessibilityLabel("Vælg lydudgang")
                        }.padding(.horizontal, 12).padding(.vertical, 4)
                            .fadedGlassSurface(radius: 16, tint: MusicEdition.surface(palette))
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
                        Text("Kø").font(.system(.title2, design: .serif, weight: .bold))
                            .frame(maxWidth: .infinity, alignment: .leading).accessibilityAddTraits(.isHeader)
                        ForEach(Array(player.queue.enumerated()), id: \.offset) { i, track in
                            HStack {
                                Button { player.play(player.queue, at: i) } label: {
                                    Label(track.title, systemImage: i == player.index ? "speaker.wave.2.fill" : "music.note")
                                        .frame(maxWidth: .infinity, alignment: .leading).lineLimit(2)
                                }.buttonStyle(.plain)
                                Button("Fjern fra kø", systemImage: "minus.circle") { player.remove(at: i) }
                                    .labelStyle(.iconOnly).frame(width: 44, height: 44)
                            }.padding(10).fadedGlassSurface(radius: 14, tint: MusicEdition.surface(palette))
                        }
                    } else {
                        ContentUnavailableView("Køen er tom", systemImage: "music.note.list",
                                               description: Text("Vælg en sang i Musik for at starte afspilningen."))
                    }
                }.frame(maxWidth: .infinity).padding(FadedSpacing.edge)
            }.foregroundStyle(palette.text).background { MusicBackdrop() }
                .navigationTitle("Spiller nu").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Luk") { dismiss() } } }
        }.tint(MusicEdition.accent(palette))
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
