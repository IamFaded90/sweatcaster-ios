import SwiftUI

struct VidoraOpenSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var input = ""
    @State private var kind = VidoraReference.Kind.movie
    @State private var season = 1
    @State private var episode = 1
    let open: (URL) -> Void
    init(input: String = "", open: @escaping (URL) -> Void) {
        _input = State(initialValue: input)
        let reference = VidoraReference(input: input)
        _kind = State(initialValue: reference?.kind ?? .movie)
        _season = State(initialValue: reference?.season ?? 1)
        _episode = State(initialValue: reference?.episode ?? 1)
        self.open = open
    }
    private var reference: VidoraReference? {
        VidoraReference(input: input, kind: kind, season: season, episode: episode)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Din film. Dit tempo.").font(.title2.bold())
                    Text("Indsæt et film- eller serielink fra TMDB eller Vidora. Afspilleren åbner her i Film.")
                        .foregroundStyle(Style.muted)
                    Picker("Type", selection: $kind) {
                        Text("Film").tag(VidoraReference.Kind.movie)
                        Text("Serie").tag(VidoraReference.Kind.tv)
                    }.pickerStyle(.segmented)
                    TextField("Indsæt link", text: $input).textFieldStyle(.plain)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                        .padding(16).background(Style.card, in: RoundedRectangle(cornerRadius: 18))
                    PasteButton(payloadType: String.self) { values in input = String((values.first ?? "").prefix(2_000)) }
                    if (reference?.kind ?? kind) == .tv {
                        Stepper("Sæson \(season)", value: $season, in: 1...1_000)
                        Stepper("Episode \(episode)", value: $episode, in: 1...10_000)
                    }
                    Button {
                        guard var reference else { return }
                        if reference.kind == .tv { reference.season = season; reference.episode = episode }
                        open(reference.playerURL); dismiss()
                    } label: {
                        Label("Åbn afspilleren", systemImage: "play.fill")
                            .frame(maxWidth: .infinity, minHeight: 48)
                    }.buttonStyle(.borderedProminent).tint(Style.accent).foregroundStyle(Style.heroInk).disabled(reference == nil)
                    if !input.isEmpty && reference == nil {
                        Text("Linket skal pege på en bestemt film eller serie. Du kan finde den via søgningen i Film.")
                            .font(.caption).foregroundStyle(Style.muted)
                    }
                    Text("Afspiller leveret af Vidora. Tilgængelighed og casting afhænger af videokilden.")
                        .font(.caption).foregroundStyle(Style.muted)
                }.padding(20)
            }.background { FilmBackground() }
                .navigationTitle("Åbn film").navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(.hidden, for: .navigationBar)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Luk") { dismiss() } } }
                .onChange(of: input) {
                    if let reference {
                        kind = reference.kind; season = reference.season; episode = reference.episode
                    }
                }
        }.presentationDetents([.large])
    }
}
