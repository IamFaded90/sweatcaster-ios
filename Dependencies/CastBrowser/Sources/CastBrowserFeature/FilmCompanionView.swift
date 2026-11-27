import SwiftUI
import AVFAudio

struct FilmCompanionView: View {
    @ObservedObject var model: CastAppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @State private var question = ""
    @State private var showPhoneHelp = false
    @State private var result: (FilmReceiverFrame, String, [FilmCue], String?)?
    @State private var notice: String?
    @State private var job: Task<Void, Never>?
    @State private var voice = AVSpeechSynthesizer()
    @State private var usingHostVoice = false
    @FocusState private var editing: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Style.space) {
                    if let frame = model.filmFrame {
                        Text(frame.source.title).font(Style.title)
                        Label("På TV · \(frame.position.clockString)", systemImage: "play.tv")
                            .font(.subheadline.monospacedDigit()).foregroundStyle(Style.muted)
                    }
                    Text("Lyt med iPhone for hjælp uden PC og uden synlige undertekster. Med din PC kan knapperne nedenfor læse de seneste replikker og billeder frem til TV’ets tidspunkt.")
                    if model.phoneFilmHelp != nil {
                        Button("Lyt med iPhone · uden PC", systemImage: "ear") { showPhoneHelp = true }
                            .buttonStyle(.borderedProminent).frame(minHeight: 44)
                    }
                    Button { ask(nil) } label: {
                        Label("Hvad blev der lige sagt?", systemImage: "captions.bubble")
                    }.buttonStyle(.bordered).disabled(job != nil)
                    Button { ask(nil, scene: true) } label: {
                        Label("Hvad sker der i scenen?", systemImage: "eye")
                    }.buttonStyle(.bordered).disabled(job != nil)
                    HStack {
                        TextField("Spørg om filmen", text: $question, axis: .vertical)
                            .lineLimit(1...4).focused($editing)
                        Button("Spørg") { ask(question) }.buttonStyle(.borderedProminent)
                            .disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || job != nil)
                    }.padding(Style.small)
                        .background(Style.card, in: RoundedRectangle(cornerRadius: Style.radius))
                    if job != nil { ProgressView("Læser scenen frem til dit tidspunkt…") }
                    if let notice { Text(notice).foregroundStyle(Style.muted) }
                    if let result, result.0.stillApplies(to: model.filmFrame) {
                        if let answer = result.3 {
                            Text(verbatim: answer).font(.headline)
                            DisclosureGroup("Vis originale replikker og kilder") { lines(result.2) }
                        } else {
                            Text(result.1).font(.headline)
                            lines(result.2)
                        }
                        Button("Læs svaret op på iPhone", systemImage: "speaker.wave.2") {
                            stopVoice()
                            voice.usesApplicationAudioSession = false
                            let texts = result.3.map { [$0] } ?? result.2.map { $0.text }
                            if let speak = model.filmSpeech {
                                usingHostVoice = true
                                speak(texts.joined(separator: " "), result.3 == nil ? "en-US" : "da-DK")
                                return
                            }
                            for line in texts {
                                let text = line.replacingOccurrences(of: "Billedobservation · ", with: "")
                                let utterance = AVSpeechUtterance(string: text)
                                utterance.voice = AVSpeechSynthesisVoice(language: result.3 == nil ? "en-US" : "da-DK")
                                voice.speak(utterance)
                            }
                        }.buttonStyle(.bordered)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(Style.space)
            }
            .scrollDismissesKeyboard(.interactively)
            .background { FilmBackground() }
            .navigationTitle("Filmven uden spoilers").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Luk") { dismiss() } } }
            .onChange(of: model.filmFrame) { _, newFrame in
                if let result, !result.0.stillApplies(to: newFrame) {
                    stopVoice()
                    self.result = nil
                    notice = FilmCompanionError.filmChanged.localizedDescription
                }
            }
            .onDisappear { job?.cancel(); stopVoice() }
            .sheet(isPresented: $showPhoneHelp) { model.phoneFilmHelp?() }
            .onChange(of: phase) { _, newPhase in
                if newPhase != .active {
                    job?.cancel()
                    stopVoice()
                    result = nil
                }
            }
        }
    }

    private func stopVoice() {
        voice.stopSpeaking(at: .immediate)
        if usingHostVoice {
            model.filmSpeech?("", "da-DK")
            usingHostVoice = false
        }
    }

    private func lines(_ cues: [FilmCue]) -> some View {
        ForEach(cues.indices, id: \.self) { index in
            let cue = cues[index]
            HStack(alignment: .top, spacing: Style.small) {
                Text(cue.start.clockString).font(Style.meta.monospacedDigit()).foregroundStyle(Style.accent)
                Text(verbatim: cue.text)
            }
        }
    }

    private func ask(_ text: String?, scene: Bool = false) {
        editing = false
        stopVoice()
        notice = nil
        result = nil
        job = Task { @MainActor in
            defer { job = nil }
            do {
                if let text, FilmDialogue.isPauseRequest(text) {
                    try await model.pauseFilmIfAsked()
                    notice = "Filmen er sat på pause på TV’et."
                    return
                }
                let answer = try await model.readFilmDialogue(question: text, scene: scene)
                try Task.checkCancellation()
                result = answer
            } catch is CancellationError { return }
            catch {
                notice = (error as? FilmCompanionError ?? .cannotRead).localizedDescription
            }
        }
    }
}
