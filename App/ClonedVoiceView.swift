import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor struct OwnVoiceSection: View {
    let selected: String
    let previewing: String?
    let choose: (String) -> Void
    let preview: (DownloadedAgentVoice) -> Void
    let stop: () -> Void
    @ObservedObject private var manager = ClonedVoiceManager.shared
    @State private var creating = false
    @State private var removing: ClonedVoice.Voice?
    @State private var removeModel = false
    var body: some View {
        Section("Egne stemmer fra optagelse") {
            Text("Opret en stemme fra 25–30 sekunders tydelig tale. Prøv den på dansk, og vælg selv, hvilken agent der skal bruge den.").font(.footnote).foregroundStyle(.secondary)
            if let progress = manager.progress {
                ProgressView("Henter flersproget stemmemodel…", value: progress)
                Button("Sæt hentning på pause") { manager.pause() }
            } else if !manager.installed {
                Text("Kræver en særskilt modelpakke. Appen kontrollerer pladsen til de filer, der mangler. Efter hentning foregår oprettelse og tale på telefonen.").font(.footnote)
                Button("Hent eller fortsæt stemmemodellen", systemImage: "arrow.down.circle") { manager.download() }.frame(minHeight: 44)
            }
            Button("Opret en stemme", systemImage: "waveform.badge.plus") { stop(); creating = true }.frame(minHeight: 44).disabled(!manager.installed)
            ForEach(manager.voices) { voice in
                let local = DownloadedAgentVoice(code: "clone." + voice.id.uuidString.lowercased())
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(voice.name).font(.headline); Spacer()
                        if selected == local.id { Image(systemName: "checkmark.circle.fill") }
                        Button { preview(local) } label: { Image(systemName: previewing == local.id ? "stop.circle" : "play.circle").font(.title2) }
                            .frame(width: 44, height: 44).buttonStyle(.borderless).accessibilityLabel("Hør " + voice.name).disabled(!manager.installed || !ClonedVoice.Store().ready(voice.id))
                        Button("Slet stemme", systemImage: "trash", role: .destructive) { removing = voice }.labelStyle(.iconOnly).frame(width: 44, height: 44)
                    }
                    if !voice.previewApproved { Text("Prøvestemme · hør den før du vælger den").font(.caption).foregroundStyle(.secondary) }
                    Button(voice.previewApproved ? "Vælg denne stemme" : "Godkend prøven og vælg stemmen") {
                        manager.approve(voice)
                        if manager.voices.first(where: { $0.id == voice.id })?.previewApproved == true { choose(local.id) }
                    }.frame(minHeight: 44).disabled(!manager.installed || !ClonedVoice.Store().ready(voice.id))
                }
            }
            if let notice = manager.notice { Text(notice).font(.footnote).foregroundStyle(.secondary) }
            if manager.installed { Button("Slet kun den flersprogede model", role: .destructive) { removeModel = true } }
            Link("ChatterboxCoreML · kilde og model", destination: URL(string: "https://github.com/iliasaz/chatterbox-coreml")!).font(.footnote)
        }
        .onAppear { manager.refresh() }
        .sheet(isPresented: $creating, onDismiss: { manager.refresh() }) { VoiceCloneCreationView() }
        .confirmationDialog("Slet \(removing?.name ?? "stemmen") fra telefonen?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
            Button("Slet stemmen", role: .destructive) { if let removing { stop(); manager.remove(removing) }; removing = nil }
        }
        .confirmationDialog("Slet modelpakken? Dine navngivne stemmer bevares.", isPresented: $removeModel, titleVisibility: .visible) {
            Button("Slet modelpakken", role: .destructive) { stop(); Task { await manager.removeModel() } }
        }
    }
}

@MainActor struct VoiceCloneCreationView: View {
    @StateObject private var recorder = ClonedVoiceRecorder()
    @State private var name = ""
    @State private var imported: URL?
    @State private var choosing = false
    @State private var busy = false
    @State private var made: ClonedVoice.Voice?
    @State private var notice: String?
    @State private var operation: Task<Void, Never>?
    @Environment(\.dismiss) private var dismiss
    private var reference: URL? { imported ?? recorder.url }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Giv stemmen sit eget navn").font(.title2.bold())
                    TextField("Fx min stemme eller Lumis stemme", text: $name).textFieldStyle(.roundedBorder).disabled(busy)
                        .onChange(of: name) { _, value in if value.count > 60 { name = String(value.prefix(60)) } }
                    FadedCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Tal roligt, med normal styrke og uden musik i baggrunden. En ren optagelse på 25–30 sekunder giver et bedre grundlag.")
                            if recorder.recording {
                                ProgressView(value: min(1, recorder.seconds / 30)); Text("\(Int(recorder.seconds)) sekunder")
                                Button("Stop optagelsen", systemImage: "stop.circle") { recorder.stop() }.frame(minHeight: 44)
                            } else {
                                Button("Optag med mikrofonen", systemImage: "mic") { clearImported(); made = nil; recorder.start() }.frame(minHeight: 44).disabled(busy)
                                Button("Vælg en lydfil", systemImage: "waveform") { choosing = true }.frame(minHeight: 44).disabled(busy)
                            }
                            if let reference { Label(imported == nil ? "Optagelse klar · \(Int(recorder.seconds)) sekunder" : reference.lastPathComponent, systemImage: "checkmark.circle")
                                Button("Slet valgt optagelse", systemImage: "trash", role: .destructive) { clearImported(); recorder.clear(); made = nil }.disabled(busy)
                            }
                            if let message = recorder.notice { Text(message).foregroundStyle(.secondary) }
                        }
                    }
                    if made == nil {
                        FadedPrimaryButton("Opret prøvestemmen", icon: "waveform.path") { create() }.disabled(busy || recorder.recording || reference == nil || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    if busy { ProgressView("Opretter stemmen lokalt… Første indlæsning kan tage lidt tid."); Button("Stop") { operation?.cancel() }.frame(minHeight: 44) }
                    if let made {
                        Text("\(made.name) er oprettet. Luk her, hør prøven i stemmelisten, og godkend den der, hvis du vil bruge den.").font(.headline)
                        Button("Tilbage til stemmerne") { dismiss() }.frame(minHeight: 44)
                    }
                    if let notice { Text(notice).foregroundStyle(.secondary).textSelection(.enabled) }
                }.padding()
            }.background { FadedBackground() }.navigationTitle("Ny stemme").navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("Luk") { operation?.cancel(); dismiss() } }
                .fileImporter(isPresented: $choosing, allowedContentTypes: [.audio]) { result in
                    do {
                        let url = try result.get(); let granted = url.startAccessingSecurityScopedResource(); defer { if granted { url.stopAccessingSecurityScopedResource() } }
                        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                        guard (1...20_000_000).contains(size), ["wav","mp3","m4a","aac","aiff","aif","caf","flac"].contains(url.pathExtension.lowercased()) else { throw ClonedVoice.Failure.recording }
                        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("FadedAI-reference-" + UUID().uuidString + "." + url.pathExtension.lowercased())
                        try FileManager.default.copyItem(at: url, to: copy); clearImported(); recorder.clear(); imported = copy; made = nil; notice = nil
                    } catch { notice = error.localizedDescription }
                }
                .onDisappear { operation?.cancel(); recorder.clear(); clearImported() }
        }
    }
    private func clearImported() { if let imported { try? FileManager.default.removeItem(at: imported) }; imported = nil }
    private func create() {
        guard !busy, let reference else { return }; busy = true; notice = nil
        operation = Task {
            defer { busy = false }
            do { made = try await ClonedVoiceManager.shared.create(name: name, reference: reference) }
            catch { if !Task.isCancelled { notice = error.localizedDescription } }
        }
    }
}
