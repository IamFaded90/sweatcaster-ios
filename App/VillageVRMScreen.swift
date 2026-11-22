import AVFAudio
import SwiftUI
import WebKit

@MainActor struct VillageVRMScreen: View {
    let bot: VillageBot
    var api: LiveAPI?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(AppStorageKeys.qolReduceMotion) private var calmMotion = false
    @ObservedObject private var speech = VillageSpeechMotion.shared
    @StateObject private var voiceTest = SpeechBox()
    @StateObject private var pcVoiceTest = ChristelPlayer()
    @State private var model: Selection?
    @State private var picker = false
    @State private var hasCustomFigure = false
    @State private var ready = false
    @State private var promptRemove = false
    @State private var failure: String?
    @State private var fileTask: Task<Void, Never>?

    private enum Source { case sample, bundled, custom, candidate }

    private struct Selection: Identifiable {
        let id: UUID
        let bytes: Data
        let source: Source
    }

    private var library: VillageVRMLibrary { VillageVRMLibrary(botID: bot.id) }
    private var portraitName: String? { VillagePortraitIdentity.name(for: bot) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let model {
                        playback(model)
                        if ready {
                            Text(model.source == .sample ? "3D-prøvefigur · Orbit" : "Figuren til \(bot.name)")
                                .font(.headline)
                            if model.source == .bundled {
                                FadedDetailText("3D-portræt · Træk for at se det lidt fra siden.")
                            }
                            speechButton
                        }
                    } else if let portraitName {
                        GeometryReader { size in
                            VillagePortraitView(name: portraitName, botID: bot.id, useCubism: true)
                                .frame(width: size.size.width, height: size.size.height)
                                .clipped()
                        }
                        .aspectRatio(4.0 / 5.0, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 24))
                        .accessibilityLabel("Animeret portræt af \(bot.name)")
                        Text("\(bot.name)s animerede portræt").font(.headline)
                        FadedDetailText("Tilføj \(bot.name)s VRM-fil for at få en figur, du kan dreje i 3D.")
                        speechButton
                    }
                    if let failure { FadedDetailText(failure) }
                    if let voiceNotice = pcVoiceTest.notice { FadedDetailText(voiceNotice) }
                    if fileTask != nil { ProgressView("Læser figuren…") }
                    Button("Vælg VRM fra Filer", systemImage: "square.and.arrow.down") { picker = true }
                        .frame(minHeight: 44)
                        .disabled(fileTask != nil || model?.source == .candidate)
                    if portraitName != nil, !hasCustomFigure, fileTask == nil, model?.source != .candidate {
                        Button(model?.source == .sample ? "Tilbage til \(bot.name)" : "Prøv 3D-demoen Orbit") {
                            failure = nil
                            load(preferSample: model?.source != .sample)
                        }.frame(minHeight: 44)
                    }
                    if model?.source == .bundled {
                        Button("Vis det animerede portræt") { load(preferPortrait: true) }.frame(minHeight: 44)
                    } else if model == nil, !hasCustomFigure, let portraitName, VillageVRMLibrary.portraitURL(portraitName) != nil {
                        Button("Vis 3D-portrættet") { load() }.frame(minHeight: 44)
                    }
                    if hasCustomFigure {
                        Button(model?.source == .sample ? "Vis min figur" : "Vis prøvefiguren Orbit") {
                            failure = nil
                            load(preferSample: model?.source != .sample)
                        }
                        .frame(minHeight: 44)
                        .disabled(fileTask != nil || model?.source == .candidate)
                        Button("Fjern min figur", role: .destructive) { promptRemove = true }
                            .frame(minHeight: 44)
                            .disabled(fileTask != nil || model?.source == .candidate)
                    }
                }
                .padding(FadedSpacing.edge)
                .frame(maxWidth: 540).frame(maxWidth: .infinity)
            }
            .background { FadedBackground(variant: .village) }
            .navigationTitle("3D-figur · \(bot.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Luk") { dismiss() } } }
        }
        .task { if model == nil { load() } }
        .fileImporter(isPresented: $picker, allowedContentTypes: [.data], onCompletion: importFile)
        .confirmationDialog("Fjern din VRM-figur?", isPresented: $promptRemove, titleVisibility: .visible) {
            Button("Fjern", role: .destructive) { remove() }
        }
        .onDisappear {
            fileTask?.cancel()
            stopPreview()
        }
    }

    private var speechButton: some View {
        Button(isPreviewing ? "Stop oplæsning" : "Prøv agentens stemme",
               systemImage: isPreviewing ? "stop.fill" : "speaker.wave.2",
               action: previewSpeech)
            .frame(minHeight: 44)
    }

    private func playback(_ model: Selection) -> some View {
        let animate = phase == .active && !reduceMotion && !calmMotion
        return TimelineView(.animation(minimumInterval: 1.0 / 12, paused: !animate || !ready)) { tick in
            VillageVRMPlayer(
                model: model.bytes, sample: model.source == .sample, portrait: model.source == .bundled, animated: animate,
                mouth: animate ? speech.mouth(for: bot.id.uuidString, at: tick.date) : 0,
                blink: animate && VillageBlink.closed(id: bot.id.uuidString, at: tick.date),
                onResult: { result in handleResult(result, for: model) }
            )
            .id(model.id)
            .overlay { if !ready { ProgressView("Klargør 3D-figuren…").allowsHitTesting(false) } }
        }
        .aspectRatio(4.0 / 5.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .accessibilityLabel("Interaktiv 3D-figur. Træk for at dreje, og knib for at zoome.")
    }

    private func load(preferSample: Bool = false, preferPortrait: Bool = false) {
        do {
            if !preferSample, let custom = try library.read() {
                hasCustomFigure = true
                select(custom, source: .custom)
                return
            }
            if !preferSample { hasCustomFigure = false }
        } catch {
            hasCustomFigure = true
            failure = "Den gemte figur kunne ikke åbnes. Du kan vælge en ny eller prøve Orbit."
        }
        if !preferSample, portraitName != nil {
            if !preferPortrait, let portraitName, let url = VillageVRMLibrary.portraitURL(portraitName) {
                do {
                    let bytes = try LocalFileStore.readBytes(from: url, maximumBytes: VillageVRMFile.maximumBytes)
                    try VillageVRMFile.validate(bytes)
                    select(bytes, source: .bundled)
                    return
                } catch {
                    failure = "Den indbyggede 3D-figur kunne ikke åbnes. Du kan stadig bruge portrættet."
                }
            }
            voiceTest.stop()
            ready = false
            model = nil
            return
        }
        guard let sample = VillageVRMLibrary.sampleURL(),
              let data = try? LocalFileStore.readBytes(from: sample, maximumBytes: VillageVRMFile.maximumBytes) else {
            failure = "3D-prøvefiguren kunne ikke åbnes."
            model = nil
            return
        }
        select(data, source: .sample)
    }

    private func select(_ bytes: Data, source: Source) {
        stopPreview()
        ready = false
        model = Selection(id: UUID(), bytes: bytes, source: source)
    }

    private var isPreviewing: Bool { voiceTest.playback != nil || pcVoiceTest.loading || pcVoiceTest.playing }

    private func stopPreview() {
        voiceTest.stop()
        pcVoiceTest.stop()
    }

    private func previewSpeech() {
        if isPreviewing {
            stopPreview()
            return
        }
        failure = nil
        let identifier = AgentVoiceSelection.identifier(for: bot)
        if let local = DownloadedAgentVoice.selected(identifier) {
            pcVoiceTest.playDownloaded(text: LocalSpeechVoice.previewSentence(language: "da-DK"), voice: local, agentID: bot.id, rate: bot.voiceRate ?? 1)
            return
        }
        if let voice = AgentPCVoice(rawValue: identifier) {
            guard let api else { failure = "Forbind PC’en for at høre agentens valgte stemme."; return }
            pcVoiceTest.playAgentVoice(text: LocalSpeechVoice.previewSentence(language: voice.language),
                                       voice: voice, agentID: bot.id, pc: api)
            return
        }
        guard let voice = AgentVoiceSelection.resolve(identifier: identifier, language: "da-DK") else {
            failure = AgentVoiceSelection.unavailable
            return
        }
        let phrase = LocalSpeechVoice.previewSentence(language: voice.language)
        voiceTest.play(LocalSpeechVoice.utterance(phrase, voice: voice, rate: bot.voiceRate ?? 1),
                       as: .preview, agentID: bot.id)
    }

    private func importFile(_ result: Result<URL, any Error>) {
        guard fileTask == nil else { return }
        failure = nil
        fileTask = Task {
            defer { fileTask = nil }
            do {
                let url = try result.get()
                let bytes = try await Task.detached(priority: .userInitiated) { try VillageVRMLibrary.importFile(url) }.value
                try Task.checkCancellation()
                select(bytes, source: .candidate)
            } catch is CancellationError {
                return
            } catch let error as VillageVRMFile.Failure {
                failure = error.errorDescription
            } catch {
                failure = "VRM-filen kunne ikke læses. Hent den til Filer, og prøv igen."
            }
        }
    }

    private func handleResult(_ result: Bool, for selection: Selection) {
        guard model?.id == selection.id else { return }
        if !result {
            failure = "Telefonen kunne ikke vise denne VRM-figur."
            model = nil
            if selection.source == .candidate { load() }
            return
        }
        if selection.source == .candidate {
            do {
                try library.save(selection.bytes)
                hasCustomFigure = true
                // The renderer already holds these exact bytes. Keep its view alive.
                model = Selection(id: selection.id, bytes: selection.bytes, source: .custom)
            } catch {
                failure = "Figuren kunne ikke gemmes. Prøv igen, mens telefonen er låst op."
                load()
                return
            }
        }
        ready = true
    }

    private func remove() {
        do {
            try library.remove()
            hasCustomFigure = false
            failure = nil
            load()
        } catch { failure = "Figuren kunne ikke fjernes. Prøv igen, mens telefonen er låst op." }
    }
}

@MainActor private struct VillageVRMPlayer: UIViewRepresentable {
    let model: Data
    let sample: Bool
    let portrait: Bool
    let animated: Bool
    let mouth: Double
    let blink: Bool
    let onResult: (Bool) -> Void

    private static let bridge = "vrm"

    func makeCoordinator() -> Coordinator { Coordinator(model: model, sample: sample, portrait: portrait, onResult: onResult) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(context.coordinator, name: Self.bridge)
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.navigationDelegate = context.coordinator
        web.scrollView.isScrollEnabled = false
        web.isOpaque = false
        web.backgroundColor = .clear
        context.coordinator.web = web
        if let url = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "Village/vrm") {
            context.coordinator.page = url
            web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            Task { @MainActor in onResult(false) }
        }
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        let values = SIMD3(animated ? 1 : 0, mouth.isFinite ? max(0, min(1, mouth)) : 0, blink ? 1 : 0)
        context.coordinator.update(values)
    }

    static func dismantleUIView(_ web: WKWebView, coordinator: Coordinator) {
        coordinator.transfer?.cancel()
        web.configuration.userContentController.removeScriptMessageHandler(forName: bridge)
        web.navigationDelegate = nil
        web.stopLoading()
    }

    @MainActor final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        let model: Data
        let sample: Bool
        let portrait: Bool
        let onResult: (Bool) -> Void
        weak var web: WKWebView?
        var page: URL?
        var transfer: Task<Void, Never>?
        private var loaded = false
        private var values: SIMD3<Double> = .zero
        private var last: SIMD3<Double>?

        init(model: Data, sample: Bool, portrait: Bool, onResult: @escaping (Bool) -> Void) {
            self.model = model
            self.sample = sample
            self.portrait = portrait
            self.onResult = onResult
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == VillageVRMPlayer.bridge, message.frameInfo.isMainFrame,
                  let state = message.body as? String else { return }
            if state == "error" { onResult(false) }
            if state == "ready", transfer == nil { importModel() }
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let page, action.targetFrame?.isMainFrame == true,
                  action.request.url?.standardizedFileURL == page.standardizedFileURL else {
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.evaluateJavaScript("typeof window.avatarBegin === 'function'") { [weak self] result, _ in
                if result as? Bool != true { self?.onResult(false) }
            }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            onResult(false)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { onResult(false) }

        private func importModel() {
            guard let web else { return }
            transfer = Task { @MainActor [weak self, weak web] in
                guard let self, let web else { return }
                do {
                    let chunkBytes = 262_144
                    _ = try await web.callAsyncJavaScript("window.avatarBegin(length);",
                                                        arguments: ["length": model.count], in: nil, contentWorld: .page)
                    for start in stride(from: 0, to: model.count, by: chunkBytes) {
                        try Task.checkCancellation()
                        let base64 = model.subdata(in: start..<min(start + chunkBytes, model.count)).base64EncodedString()
                        _ = try await web.callAsyncJavaScript("window.avatarAppend(chunk);",
                                                            arguments: ["chunk": base64], in: nil, contentWorld: .page)
                    }
                    let outcome = try await web.callAsyncJavaScript("return await window.avatarFinish(orbit, portrait);",
                                                                     arguments: ["orbit": sample, "portrait": portrait], in: nil, contentWorld: .page)
                    try Task.checkCancellation()
                    loaded = outcome as? Bool == true
                    onResult(loaded)
                    update(values)
                } catch is CancellationError {
                    return
                } catch {
                    onResult(false)
                }
            }
        }

        func update(_ newValues: SIMD3<Double>) {
            values = newValues
            guard loaded, last != values, let web else { return }
            last = values
            web.evaluateJavaScript("window.avatarMotion(\(values.x), \(values.y), \(values.z));") { _, _ in }
        }
    }
}
