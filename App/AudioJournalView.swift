import AVFAudio
import FadedAISpeakerRuntime
import SwiftUI
import UniformTypeIdentifiers

@MainActor struct AudioJournalView: View {
    let bot: VillageBot
    let model: String
    var initialRecordingID: UUID?
    @State private var recordings: [AudioTranscript.Recording] = []
    @State private var pending: [AudioTranscript.Recording] = []
    @State private var activeRecording: AudioTranscript.Recording?
    @State private var pendingRemoval: AudioTranscript.Recording?
    @State private var selected: AudioTranscript.Recording?
    @State private var recorder = LongAudioRecorder()
    @State private var player: AVAudioPlayer?
    @State private var picker = false
    @State private var busy = false
    @State private var operation: Task<Void, Never>?
    @State private var notice: String?
    @State private var speakerReady = SpeakerRuntime.installed
    @State private var followUp: AudioTranscript.Segment?
    @State private var hasEdits = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    private var store: AudioTranscript.Store { .init(botID: bot.id) }
    private var recovery: AudioTranscript.Recovery { .init(botID: bot.id) }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Danske optagelser med tidskoder, rettelser og opfølgning. Lyden behandles lokalt med din hentede Whisper-model. Bliv i appen, mens den arbejder.").font(.subheadline).foregroundStyle(.secondary)
                    Button("Importér lydfil", systemImage: "waveform.badge.plus") { picker = true }.frame(minHeight: 44).disabled(busy || recorder.active)
                    Button(recorder.active ? "Stop og gem optagelsen" : "Optag en samtale", systemImage: recorder.active ? "stop.fill" : "mic") { record() }.frame(minHeight: 44).disabled(busy)
                    Text("Højst 30 minutter pr. fil. Baggrundsskift stopper mikrofonen og gemmer det optagne stykke.").font(.caption)
                    if busy { ProgressView("Arbejder…"); Button("Stop behandlingen") { operation?.cancel() }.frame(minHeight: 44) }
                    if let notice { Text(notice).font(.footnote).foregroundStyle(.secondary).accessibilityAddTraits(.updatesFrequently) }
                }
                if let selected {
                    Section(selected.title) {
                        Text(selected.complete ? "Transskription færdig" : "Delvist behandlet · \(AudioTranscript.clock(selected.processedThrough ?? 0))").font(.caption)
                        if !selected.complete {
                            Button(selected.segments.isEmpty ? "Skriv lyden på dansk" : "Fortsæt fra sidste stykke", systemImage: "text.badge.waveform") { transcribe() }
                                .frame(minHeight: 44).disabled(busy || recorder.active || AgentWhisper.availableModels(for: "da-DK").isEmpty)
                        }
                        if AgentWhisper.availableModels(for: "da-DK").isEmpty { Text("Hent dansk diktering i Offline-indstillinger først.").font(.caption) }
                        if speakerReady {
                            Button("Foreslå talere", systemImage: "person.2.wave.2") { speakers() }.frame(minHeight: 44).disabled(busy || recorder.active || selected.segments.isEmpty)
                        } else {
                            Button("Hent modeller til taleropdeling", systemImage: "arrow.down.circle") { installSpeakers() }.frame(minHeight: 44).disabled(busy || recorder.active)
                        }
                        Text("Danskmodellen giver tidskoder pr. lydstykke på op til 25 sekunder. Flere stemmer i samme stykke markeres som ‘Flere talere’. Talermærker er forslag, som du kan rette.").font(.caption).foregroundStyle(.secondary)
                        if !selected.segments.isEmpty { ShareLink(item: selected.exportedText) { Label("Del transskription", systemImage: "square.and.arrow.up") } }
                        if hasEdits { Button("Gem rettelser", systemImage: "checkmark") { _ = saveEdits() }.frame(minHeight: 44).disabled(busy) }
                        ForEach(selected.segments) { segment in
                            VStack(alignment: .leading, spacing: 8) {
                                Button("\(AudioTranscript.clock(segment.start))–\(AudioTranscript.clock(segment.end)) · Afspil", systemImage: "play.circle") { play(segment.start) }.frame(minHeight: 44)
                                TextField("Taler (valgfrit)", text: Binding(get: { self.selected?.segments.first(where: { $0.id == segment.id })?.speaker ?? "" }, set: { name in edit(segment.id) { $0.speaker = name.isEmpty ? nil : String(name.prefix(60)); $0.speakerEstimated = false } })).disabled(busy)
                                TextField("Transskription", text: Binding(get: { self.selected?.segments.first(where: { $0.id == segment.id })?.text ?? "" }, set: { text in edit(segment.id) { $0.text = String(text.prefix(6_000)) } }), axis: .vertical).disabled(busy)
                                if segment.speakerEstimated { Text("Taler foreslået af modellen").font(.caption).foregroundStyle(.secondary) }
                                Button("Noter og opfølgning fra uddrag", systemImage: "square.and.pencil") { followUp = segment }.frame(minHeight: 44).disabled(busy)
                            }.padding(.vertical, 5)
                        }
                    }
                }
                Section("Gemte optagelser") {
                    ForEach(recordings) { recording in
                        Button(recording.title) { guard saveEdits() else { return }; player?.stop(); selected = recordings.first { $0.id == recording.id } ?? recording }.frame(minHeight: 44).disabled(busy || recorder.active)
                            .swipeActions { Button("Slet lyd og tekst", role: .destructive) { remove(recording) }.disabled(busy || recorder.active) }
                    }
                }
                if !pending.isEmpty {
                    Section("Optagelser der kan gendannes") {
                        Text("Den oprindelige lyd er bevaret. Prøv at gemme den igen. Hvis optagelsen blev afbrudt brat, kan filen være ufuldstændig.").font(.caption)
                        ForEach(pending) { recording in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(recording.title).font(.headline)
                                Button("Prøv at gemme optagelsen", systemImage: "arrow.clockwise") { recover(recording) }.disabled(busy || recorder.active)
                                ShareLink(item: recovery.audio(recording.id)) { Label("Del den bevarede lydfil", systemImage: "square.and.arrow.up") }
                                Button("Slet den bevarede lydfil", systemImage: "trash", role: .destructive) { pendingRemoval = recording }.disabled(busy || recorder.active)
                            }.frame(minHeight: 44)
                        }
                    }
                }
                if speakerReady { Button("Slet talermodeller", role: .destructive) { operation = Task { do { try await SpeakerRuntime.shared.remove(); speakerReady = false } catch { notice = error.localizedDescription } } }.disabled(busy || recorder.active) }
            }.scrollContentBackground(.hidden).background { FadedBackground() }
                .navigationTitle("Optagelser · \(bot.name)").navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("Luk") { dismiss() } }
                .onAppear { reload(); reloadPending(); if selected == nil, let initialRecordingID { selected = recordings.first { $0.id == initialRecordingID } } }
                .task(id: recorder.active) {
                    guard recorder.active else { return }
                    while !Task.isCancelled, recorder.active {
                        do { try await Task.sleep(for: .seconds(1)) } catch { return }
                        if !recorder.isRecording { finishRecording(); return }
                    }
                }
                .onChange(of: phase) { _, value in if value != .active { player?.stop(); if recorder.active { finishRecording(process: false) } } }
                .onDisappear { operation?.cancel(); player?.stop(); if recorder.active { finishRecording(process: false) } else { _ = recorder.finish() }; _ = saveEdits() }
                .confirmationDialog("Slet den bevarede lydfil?", isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }), titleVisibility: .visible) {
                    Button("Slet lydfilen", role: .destructive) { if let pendingRemoval { do { try recovery.remove(pendingRemoval.id); reloadPending() } catch { notice = error.localizedDescription } }; pendingRemoval = nil }
                    Button("Annuller", role: .cancel) { pendingRemoval = nil }
                }
                .fileImporter(isPresented: $picker, allowedContentTypes: [.audio]) { result in
                    do { startImport(try result.get()) } catch { if (error as? CocoaError)?.code != .userCancelled { notice = error.localizedDescription } }
                }
                .sheet(item: $followUp) { segment in CaptureReviewView(bot: bot, model: model, initial: segment.text, initialSource: (selected?.title ?? "Optagelse") + " · " + AudioTranscript.clock(segment.start)) }
        }
    }
    private func reload() { do { recordings = try store.load() } catch { notice = error.localizedDescription } }
    private func reloadPending() { do { pending = try recovery.list() } catch { notice = error.localizedDescription } }
    private func persist(_ value: AudioTranscript.Recording) throws { try store.save(value); selected = value; recordings = try store.load(); hasEdits = false }
    @discardableResult private func saveEdits() -> Bool {
        guard hasEdits, let selected else { return true }
        do { try persist(selected); return true } catch { notice = error.localizedDescription; return false }
    }
    private func startImport(_ source: URL) {
        guard !busy, saveEdits() else { return }; busy = true; notice = nil
        let recording = AudioTranscript.Recording(title: String(source.lastPathComponent.prefix(160)))
        operation = Task {
            defer { busy = false }
            do {
                try await AudioJournalNative.importFile(source, id: recording.id); try Task.checkCancellation(); try persist(recording)
                notice = "Lydkopien er gemt. Tryk Skriv lyden på dansk, når du er klar."
            } catch {
                let converted = AudioJournalNative.audio(recording.id)
                if FileManager.default.fileExists(atPath: converted.path) {
                    // A journal write might already have succeeded. Preserve
                    // the final file and offer recovery if a later step failed.
                    do {
                        try recovery.preserveConverted(recording, from: converted)
                        reloadPending()
                        notice = "Importen blev afbrudt. Lydkopien er bevaret under optagelser, der kan gendannes."
                    } catch {
                        notice = "Importen blev afbrudt. Den konverterede lyd er bevaret på telefonen, men kunne ikke lægges i gendannelseslisten."
                    }
                } else if !Task.isCancelled { notice = error.localizedDescription }
            }
        }
    }
    private func record() {
        if recorder.active { finishRecording(); return }
        guard saveEdits() else { return }
        busy = true
        operation = Task { defer { busy = false }; do {
            let recording = AudioTranscript.Recording(title: "Samtale " + Date.now.formatted(date: .abbreviated, time: .shortened))
            try recovery.begin(recording)
            try await recorder.start(to: recovery.audio(recording.id))
            activeRecording = recording
        } catch { reloadPending(); if !Task.isCancelled { notice = error.localizedDescription } } }
    }
    private func finishRecording(process: Bool = true) {
        let source = recorder.finish(), recording = activeRecording
        activeRecording = nil; reloadPending()
        if process, source != nil, let recording { recover(recording) }
    }
    private func recover(_ recording: AudioTranscript.Recording) {
        guard !busy, saveEdits() else { return }; busy = true; notice = nil
        operation = Task {
            defer { busy = false; reloadPending() }
            do {
                let destination = AudioJournalNative.audio(recording.id)
                if !FileManager.default.fileExists(atPath: destination.path) {
                    try await AudioJournalNative.importFile(recovery.audio(recording.id), id: recording.id)
                }
                try Task.checkCancellation()
                let saved = try recovery.commit(recording, to: store) { try AudioJournalNative.validateConverted(recording.id) }
                selected = saved; hasEdits = false
                do { recordings = try store.load() } catch {
                    recordings.removeAll { $0.id == saved.id }; recordings.insert(saved, at: 0)
                    notice = "Lydkopien er gemt, men listen kunne ikke opdateres lige nu."
                    return
                }
                notice = "Lydkopien er gemt. Tryk Skriv lyden på dansk, når du er klar."
            } catch {
                notice = Task.isCancelled ? "Behandlingen er stoppet. Den oprindelige lyd er bevaret til et nyt forsøg." : "Kunne ikke gemme optagelsen. Den oprindelige lyd er bevaret: " + error.localizedDescription
            }
        }
    }
    private func transcribe() {
        guard !busy, let selected else { return }; busy = true; notice = nil
        operation = Task {
            defer { busy = false }
            do { _ = try await AudioJournalNative.transcribe(selected, progress: persist); notice = "Teksten er klar. Gennemgå navne, tal og talermærker." }
            catch { if !Task.isCancelled { notice = error.localizedDescription } else { notice = "Stoppet. Færdige lydstykker er gemt, og du kan fortsætte senere." } }
        }
    }
    private func speakers() {
        guard !busy, let selected else { return }; busy = true; notice = nil
        operation = Task { defer { busy = false }; do { try persist(await AudioJournalNative.speakers(selected)) } catch { if !Task.isCancelled { notice = error.localizedDescription } } }
    }
    private func installSpeakers() {
        busy = true; notice = "Henter og klargør modellerne. Det kan tage et øjeblik."
        operation = Task { defer { busy = false; speakerReady = SpeakerRuntime.installed }; do {
            guard PhoneModels.hasDownloadSpace(bytes: 1_000_000_000) else { throw APIError.storage }
            await AgentVoiceDownload.releaseSynthesisResources()
            try await LocalCompute.run(minimumMiB: 1_200) { try await SpeakerRuntime.shared.install() }; notice = "Talermodellerne er klar til lokal brug."
        } catch { if !Task.isCancelled { notice = error.localizedDescription } } }
    }
    private func edit(_ id: UUID, change: (inout AudioTranscript.Segment) -> Void) {
        guard !busy, var value = selected, let index = value.segments.firstIndex(where: { $0.id == id }) else { return }
        change(&value.segments[index]); selected = value; hasEdits = true
    }
    private func play(_ time: Double) {
        guard let selected, !busy, !recorder.active else { return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)
            player?.stop(); player = try AVAudioPlayer(contentsOf: AudioJournalNative.audio(selected.id)); player?.currentTime = time; player?.play()
        } catch { notice = "Lydkopien kunne ikke afspilles. Teksten er stadig bevaret." }
    }
    private func remove(_ recording: AudioTranscript.Recording) {
        do {
            player?.stop()
            let file = AudioJournalNative.audio(recording.id)
            if FileManager.default.fileExists(atPath: file.path) { try LocalFileStore(root: AudioJournalNative.root).delete(file) }
            try store.remove(recording.id); if selected?.id == recording.id { selected = nil; hasEdits = false }; reload()
        } catch { notice = error.localizedDescription }
    }
}
