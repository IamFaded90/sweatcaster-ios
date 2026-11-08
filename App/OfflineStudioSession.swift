// Håndterer Offline Studios sessioner, lokal indlæsning og indstillinger.

import AVFAudio
import LocalAuthentication
import Network
import SwiftUI
import UIKit
import UniformTypeIdentifiers

extension OfflineStudio {
    var canShowStudio: Bool {
        guard sessionUnlocked, studioPhase == .active else { return false }
        return !privateSession || !sessionExpired
    }

    func resetIdleTimer(extendPrivacy: Bool = true) {
        idleAsleep = false
        idleRevision = UUID()
        guard extendPrivacy, privateSession, loaded, sessionUnlocked, studioPhase == .active else { return }
        guard !sessionExpired else { wipeExpiredPrivateSession(); return }
        privateDeadline = ContinuousClock.now.advanced(by: .seconds(Int(sessionPreferences.idleMinutes * 60)))
    }

    func awaitPrivateExpiry() async {
        guard let deadline = privateDeadline else { return }
        do { try await ContinuousClock().sleep(until: deadline) } catch { return }
        guard privateSession, loaded, sessionUnlocked, deadline == privateDeadline else { return }
        wipeExpiredPrivateSession()
    }

    func sleepStudioWhenIdle() async {
        guard sessionUnlocked, studioPhase == .active, task == nil else { return }
        let setting = privateSession ? sessionPreferences.modelTimeoutMinutes : autoSleepMinutes
        let minutes = min(30, max(1, Int(setting)))
        do { try await Task.sleep(for: .seconds(minutes * 60)) } catch { return }
        guard sessionUnlocked, studioPhase == .active, task == nil else { return }
        speech.synthesizer.stopSpeaking(at: .immediate)
        idleAsleep = true
    }

    func handleStudioPhase(_ phase: ScenePhase) {
        if phase == .background {
            dictation.stop()
            speech.synthesizer.stopSpeaking(at: .immediate)
        } else if phase == .active && privateSession {
            if sessionExpired { wipeExpiredPrivateSession(); return }
            if privateDeadline == nil { resetIdleTimer(); return }
        }
        resetIdleTimer(extendPrivacy: false)
    }

    private func wipeExpiredPrivateSession() {
        stopStudioImageQueue()
        importPromptFile = false
        importChatText = false
        showPromptEditor = false
        showSessionNote = false
        studioShareSheet = nil
        closeChatSession()
        sessionUnlocked = false
        status = "Privat session afsluttet og slettet."
    }

    func clearStudioContent() {
        if privateSession {
            wipeExpiredPrivateSession()
            return
        }
        guard task == nil else { return }
        do {
            let manager = FileManager.default
            if manager.fileExists(atPath: historyFolder.path) { try manager.removeItem(at: historyFolder) }
            closeChatSession()
            try MigratedAppData.shared.clearRegularStudio()
            promptHistoryData = Data()
            imageFavoritesData = Data()
            resetPublicGallery()
            imageURL = nil
            batchImageURLs = []
            batchTurnID = nil
            sessionUnlocked = false
            status = "Studiets samtaler og galleri er ryddet."
        } catch { AppDiagnostics.record(error); status = "Studiets galleri kunne ikke ryddes. Samtaler og modeller er bevaret." }
    }

    func monitorPrivateConnectivity() async {
        guard privateSession, loaded, sessionUnlocked else { return }
        let monitor = NWPathMonitor()
        privatePathMonitor = monitor
        let changes = AsyncStream<Bool>(bufferingPolicy: .bufferingNewest(1)) { continuation in
            monitor.pathUpdateHandler = { path in continuation.yield(path.status == .unsatisfied) }
            continuation.onTermination = { _ in monitor.cancel() }
            monitor.start(queue: DispatchQueue(label: "dk.fadedai.studio-private-network"))
        }
        defer {
            monitor.cancel()
            if privatePathMonitor === monitor {
                privatePathMonitor = nil
                privateNetworkOffline = false
            }
        }
        for await offline in changes {
            guard privateSession, loaded, sessionUnlocked, !Task.isCancelled else { return }
            privateNetworkOffline = offline
            if !offline && (generatingImages || privateImageRendering) {
                pendingImages.removeAll()
                task?.cancel()
                status = "Netværket er aktivt. Privat billedgenerering er stoppet."
            }
        }
    }

    func activateChatIfNeeded() {
        guard sessionUnlocked, !loaded else { return }
        loaded = true
        if privateSession { configureSessionPreferences() }
        else { enabled = true }
        UIDevice.current.isBatteryMonitoringEnabled = true
        privateBatteryLevel = UIDevice.current.batteryLevel
        if !ephemeralOnly, let id = pendingBotID, privateBots.contains(where: { $0.id == id }) { privateBotID = id.uuidString }
        pendingBotID = nil
        loadPrivateConversation()
        if !ephemeralOnly, privateBotID.isEmpty { privateBotID = privateBots.first?.id.uuidString ?? "" }
    }

    private func configureSessionPreferences() {
        var preferences = StudioSessionPreferences()
        preferences.imageModel = savedImageModel
        if PhoneModels.installedDirectory(textModel) != nil {
            preferences.textModel = textModel
        } else if let available = PhoneModels.catalog.first(where: { PhoneModels.installedDirectory($0.id) != nil }) {
            preferences.textModel = available.id
        } else if PhoneModels.installedDirectory("imported") != nil {
            preferences.textModel = "imported"
        }
        sessionPreferences = preferences
        privateDeadline = nil
        resetIdleTimer()
    }

    private func loadPrivateConversation() {
        guard !privateSession else { return }
        turns = MigratedAppData.shared.regularStudioTurns()
        prompt = MigratedAppData.shared.regularStudioDraft()
    }

    func savePrivateConversation() {
        guard !privateSession, loaded else { return }
        do { try MigratedAppData.shared.saveRegularStudioTurns(turns) }
        catch { AppDiagnostics.record(error); status = "Samtalen kunne ikke gemmes." }
    }

    func newPrivateConversation() {
        speech.synthesizer.stopSpeaking(at: .immediate)
        if privateSession {
            removeTemporaryStudioImages()
            sessionNote = ""
            turns = []
        } else {
            let remaining = turns.filter { !belongsToCurrentBot($0) }
            turns = remaining
            savePrivateConversation()
            do { try MigratedAppData.shared.clearRegularStudioDraft() }
            catch { AppDiagnostics.record(error) }
        }
        prompt = ""; answer = ""; status = ""
    }

    func closeChatSession() {
        studioAuthentication?.invalidate()
        studioAuthentication = nil
        authenticating = false
        dictation.stop()
        speech.synthesizer.stopSpeaking(at: .immediate)
        task?.cancel()
        if chatWorkID != nil {
            chatWorkID = nil
            task = nil
        }
        let wasPrivate = privateSession && loaded
        if privateSession {
            removeTemporaryStudioImages()
            privateDeadline = nil
            sessionPreferences = StudioSessionPreferences()
            sessionNote = ""
            voiceLanguages.removeAll()
        } else if loaded {
            savePrivateConversation()
            do { try MigratedAppData.shared.saveRegularStudioDraft(prompt) }
            catch { AppDiagnostics.record(error) }
        }
        loaded = false
        turns = []
        prompt = ""
        imagePrompt = ""
        negativeImagePrompt = ""
        answer = ""
        status = ""
        if ephemeralOnly { sessionUnlocked = false }
        if wasPrivate { onPrivateSessionEnded() }
    }

    func authenticate() {
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else {
            status = "Slå Face ID eller Touch ID til på telefonen for at åbne studiet."
            return
        }
        authenticating = true
        studioAuthentication = context
        Task {
            defer {
                if studioAuthentication === context {
                    studioAuthentication = nil
                    authenticating = false
                }
            }
            do {
                let accepted = try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics,
                                                                localizedReason: "Lås FadedAI-studiet op")
                guard studioAuthentication === context else { return }
                sessionUnlocked = accepted
                if !privateSession { enabled = accepted }
                status = accepted ? "" : "Studiet er låst."
            } catch {
                AppDiagnostics.record(error)
                if studioAuthentication === context { status = "Studiet er låst. Prøv igen." }
            }
        }
    }

    func offlineSuccessHaptic() {
        if studioHaptics && studioPhase == .active {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
    }

    func run(_ message: String, work: @escaping @MainActor () async throws -> Void) {
        guard canShowStudio, studioEnabled, task == nil else { return }
        let sessionID = privateSession ? temporaryImagesID : nil
        status = message
        task = Task {
            defer { task = nil }
            do { try await work() }
            catch {
                AppDiagnostics.record(error)
                if sessionID.map(isCurrentPrivateSession) == false { return }
                switch error {
                case is CancellationError:
                    if !status.hasPrefix("Netværket er aktivt") { status = "Stoppet." }
                case StudioImageInterruption.network:
                    status = "Slå Wi-Fi og mobildata fra for at generere billeder privat."
                case LocalComputeError.busy:
                    status = "Telefonen kører allerede en lokal AI-opgave. Prøv igen om lidt."
                case LocalComputeError.lowMemory:
                    status = "Telefonen har for lidt ledig hukommelse til denne model lige nu."
                case let V2Failure.http(statusCode, _, _) where statusCode == 503:
                    status = "PC’en har travlt eller skifter model. Prøv igen om lidt."
                default:
                    status = privateSession ? "Billedet kunne ikke laves. Tjek pladsen og den lokale model."
                                             : "Billedet kunne ikke laves. Tjek plads på telefonen og forbindelsen til PC’en."
                }
            }
        }
    }
}

extension OfflineStudio {
    var privateSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Kun for voksne. Den valgte lokale models egne begrænsninger gælder stadig.")
                .font(.caption).foregroundStyle(.secondary)
            if !privateBots.isEmpty {
                Picker("Companion", selection: $privateBotID) {
                    ForEach(privateBots) { bot in Text(bot.name).tag(bot.id.uuidString) }
                }
            }
            Button("Opret eller redigér botprofil") { showBotBuilder = true }.frame(minHeight: 44)
            Button("Lokale modeller") { showModels = true }.frame(minHeight: 44).disabled(task != nil)
            Text(textReady ? "Tekstmodellen er klar." : "Vælg en downloadet Core ML-model til privat chat.")
                .font(.caption)
            Picker("Systemprompt", selection: $personalityPreset) {
                Text("Bottens egen").tag("bot")
                Text("Kort og rolig").tag("calm")
                Text("Kreativ og legende").tag("creative")
                Text("Direkte og konkret").tag("direct")
            }.disabled(task != nil)
            Picker("Stemme til forhåndsvisning", selection: $previewLanguage) {
                Text("Dansk").tag("da-DK")
                Text("Engelsk (US)").tag("en-US")
            }
            studioVoicePicker(language: previewLanguage, saved: previewLanguage == "da-DK" ? $danishVoiceID : $englishVoiceID)
            Button("Afspil prøvesætning", systemImage: "play.circle") { previewStudioVoice() }
                .frame(minHeight: 44).disabled(task != nil)
            ColorPicker("Chatbaggrund", selection: Binding(get: { chatBackdrop }, set: { setChatBackdrop($0) }),
                        supportsOpacity: false)
            if !backdropData.isEmpty {
                Button("Brug standardbaggrund") { backdropData = Data() }.frame(minHeight: 44)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Aflast studiet efter \(Int(autoSleepMinutes)) min uden aktivitet")
                Slider(value: $autoSleepMinutes, in: 1...30, step: 1)
                    .accessibilityLabel("Minutter til studiets dvale")
                    .onChange(of: autoSleepMinutes) { _, value in
                        if studioHaptics && (value == 1 || value == 30) { UIImpactFeedbackGenerator(style: .soft).impactOccurred() }
                    }
                Text("Modeller frigives efter hver opgave. Dvale skjuler også forhåndsvisningen og stopper oplæsning.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !privateSession {
                ShareLink(item: privateConversationText) {
                    Label("Eksportér samtale", systemImage: "square.and.arrow.up")
                        .frame(minHeight: 44)
                }.disabled(turns.isEmpty)
            }
            Text(textReady && imageReady ? "Klar til flytilstand · Chat og billeder"
                 : textReady ? "Klar til flytilstand · Chat"
                 : imageReady ? "Klar til flytilstand · Billeder" : "Lokale modeller mangler")
                .font(.caption.bold())
        }
    }

    var sessionChatSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            sessionModelPicker
            Picker("Systemprompt", selection: $sessionPreferences.personality) {
                Text("Standard").tag("bot")
                Text("Kort og rolig").tag("calm")
                Text("Kreativ og legende").tag("creative")
                Text("Direkte og konkret").tag("direct")
            }.disabled(task != nil)
            Picker("Oplæsningssprog", selection: $sessionPreferences.voiceLanguage) {
                Text("Dansk").tag("da-DK")
                Text("Engelsk (US)").tag("en-US")
            }
            studioVoicePicker(language: sessionPreferences.voiceLanguage,
                              saved: sessionPreferences.voiceLanguage == "da-DK" ? $sessionPreferences.danishVoice : $sessionPreferences.englishVoice)
            FadedSecondaryButton("Afspil prøvesætning", icon: "play.circle", action: previewStudioVoice)
                .disabled(task != nil)
            ColorPicker("Chatbaggrund", selection: Binding(get: { chatBackdrop }, set: { setChatBackdrop($0) }),
                        supportsOpacity: false)
            if !sessionPreferences.backdrop.isEmpty {
                Button("Brug standardbaggrund") { sessionPreferences.backdrop = Data() }.frame(minHeight: 44)
            }
            Stepper("Ryd efter \(Int(sessionPreferences.idleMinutes)) min uden aktivitet", value: $sessionPreferences.idleMinutes,
                    in: 1...15, step: 1)
            Stepper("Modeldvale efter \(Int(sessionPreferences.modelTimeoutMinutes)) min", value: $sessionPreferences.modelTimeoutMinutes,
                    in: 1...15, step: 1)
            Text("Modeller frigives efter hver opgave. Dvale stopper oplæsning og skjuler forhåndsvisningen.")
                .font(.caption).foregroundStyle(palette.secondary)
        }
    }

    private var sessionModelPicker: some View {
        let models = PhoneModels.catalog.filter { PhoneModels.installedDirectory($0.id) != nil }
        let imported = PhoneModels.installedDirectory("imported") != nil
        return Group {
            if models.isEmpty && !imported {
                Text("Hent en Core ML-model under Lokale modeller, inden du åbner en privat session.")
                    .font(.caption).foregroundStyle(palette.secondary)
            } else {
                Picker("Lokal tekstmodel", selection: $sessionPreferences.textModel) {
                    if sessionPreferences.textModel.isEmpty { Text("Vælg lokal model").tag("") }
                    ForEach(models) { model in Text(model.name).tag(model.id) }
                    if imported { Text("Importeret model").tag("imported") }
                }.disabled(task != nil)
            }
        }
    }

    var chatBackdrop: Color {
        let data = privateSession ? sessionPreferences.backdrop : backdropData
        guard let components = try? JSONDecoder().decode([Double].self, from: data), components.count == 3 else { return .clear }
        return Color(red: components[0], green: components[1], blue: components[2])
    }

    private func setChatBackdrop(_ color: Color) {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha),
              let data = try? JSONEncoder().encode([Double(red), Double(green), Double(blue)]) else { return }
        if privateSession { sessionPreferences.backdrop = data }
        else { backdropData = data }
    }

    private func previewStudioVoice() {
        let language = privateSession ? sessionPreferences.voiceLanguage : previewLanguage
        guard let voice = studioVoice(language: language, bot: selectedPrivateBot) else {
            status = "Stemmen er ikke tilgængelig på telefonen."
            return
        }
        resetIdleTimer()
        dictation.stop()
        speech.synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: language == "da-DK" ? "Hej. Sådan lyder min stemme i FadedAI." : "Hello. This is how my voice sounds in FadedAI.")
        utterance.voice = voice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * Float(selectedPrivateBot?.voiceRate ?? 1)
        speech.synthesizer.speak(utterance)
    }

    private func studioVoicePicker(language: String, saved: Binding<String>) -> some View {
        let available = LocalSpeechVoice.options(language: language)
        let selection = Binding(get: { available.contains { $0.identifier == saved.wrappedValue } ? saved.wrappedValue : "" },
                                set: { saved.wrappedValue = $0 })
        return Picker("Installeret stemme", selection: selection) {
            Text("Automatisk").tag("")
            ForEach(available, id: \.identifier) { voice in
                Text(LocalSpeechVoice.label(voice)).tag(voice.identifier)
            }
        }
    }

    func studioVoice(language: String, bot: VillageBot?) -> AVSpeechSynthesisVoice? {
        let options = LocalSpeechVoice.options(language: language)
        let saved = if privateSession {
            language == "da-DK" ? sessionPreferences.danishVoice : sessionPreferences.englishVoice
        } else {
            language == "da-DK" ? danishVoiceID : englishVoiceID
        }
        return options.first { $0.identifier == saved }
            ?? options.first { $0.identifier == bot?.voice }
            ?? options.first
            ?? AVSpeechSynthesisVoice(language: language)
    }

    func studioEditorButton(forImage: Bool) -> some View {
        Button {
            editingImagePrompt = forImage
            showPromptEditor = true
        } label: {
            Image(systemName: "square.and.pencil").frame(width: 44, height: 44)
        }.accessibilityLabel("Åbn prompteditor").disabled(task != nil)
    }

    var studioPromptEditor: some View {
        let text = editingImagePrompt ? $imagePrompt : $prompt
        return NavigationStack {
            Group {
                if canShowStudio {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            TextEditor(text: text).frame(minHeight: 240)
                                .accessibilityLabel("Prompt som Markdown")
                            DisclosureGroup("Forhåndsvis Markdown") {
                                let preview = String(text.wrappedValue.prefix(12_000))
                                if let rendered = try? AttributedString(markdown: preview) {
                                    Text(rendered).environment(\.openURL, OpenURLAction { _ in
                                        privateSession ? .discarded : .systemAction
                                    })
                                }
                                else { Text(verbatim: preview) }
                            }
                        }.padding(16)
                    }
                } else { Text("Studiet er låst.") }
            }
            .navigationTitle("Prompteditor")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Importér .txt") { importPromptFile = true }.disabled(!canShowStudio)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Færdig") { showPromptEditor = false }
                }
            }
            .fileImporter(isPresented: $importPromptFile, allowedContentTypes: [.plainText]) { result in
                if case .success(let url) = result { loadPromptFile(url, intoImages: editingImagePrompt) }
            }
        }
    }

    func loadPromptFile(_ url: URL, intoImages: Bool) {
        guard sessionUnlocked, !sessionExpired else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            if privateSession, try url.resourceValues(forKeys: [.isUbiquitousItemKey]).isUbiquitousItem == true {
                status = "Vælg en tekstfil, der ligger på din iPhone."
                return
            }
            let data = try LocalFileStore.readBytes(from: url, maximumBytes: 96_000)
            guard let text = String(data: data, encoding: .utf8) else {
                throw CocoaError(.fileReadInapplicableStringEncoding)
            }
            let content = text.first == "\u{FEFF}" ? String(text.dropFirst()) : text
            if intoImages { imagePrompt = content }
            else { prompt = content }
            resetIdleTimer()
            status = "Tekst importeret."
        } catch { AppDiagnostics.record(error); status = "Brug en UTF-8-tekstfil på højst 96 KB." }
    }
}
