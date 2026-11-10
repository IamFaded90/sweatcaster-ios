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
        speech.stop()
        idleAsleep = true
    }

    func handleStudioPhase(_ phase: ScenePhase) {
        if phase == .background {
            dictation.stop()
            speech.stop()
            if privateSession, loaded, sessionUnlocked {
                let backgroundLimit = ContinuousClock.now.advanced(by: .seconds(300))
                privateDeadline = min(privateDeadline ?? backgroundLimit, backgroundLimit)
            }
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

    func clearStudioContent(includingModels: Bool) {
        if !includingModels {
            wipeExpiredPrivateSession()
            return
        }
        guard task == nil, !LocalCompute.isRunning else {
            status = "Vent til den lokale opgave er færdig, før du rydder studiet."
            return
        }
        LocalCompute.suspend()
        defer { LocalCompute.resume() }
        PhoneModelDownloads.shared.cancel()
        closeChatSession()
        loraPreviewSelection = nil
        removeTemporaryStudioImages()
        var finished = true
        do { try MigratedAppData.shared.clearRegularStudio() }
        catch { AppDiagnostics.record(error); finished = false }

        let previews = URL.applicationSupportDirectory.appending(path: "StudioLoRAPreviews", directoryHint: .isDirectory)
        for directory in [historyFolder, previews, PhoneModels.importedFolder, PhoneModels.downloadedRoot] {
            do { try FileManager.default.removeItem(at: directory) }
            catch let error where LocalFileStore.isMissing(error) { continue }
            catch { AppDiagnostics.record(error); finished = false }
        }
        promptHistoryData = Data()
        imageFavoritesData = Data()
        loraLabelsData = Data()
        loraName = ""
        useLoRA = false
        textModel = "apple"
        resetPublicGallery()
        imageURL = nil
        batchImageURLs = []
        studioShareSheet = nil
        sessionUnlocked = false
        status = finished ? "Studiets samtaler, billeder og downloadede modeller er slettet."
            : "Oprydningen blev ikke færdig. Lås op igen for at prøve på ny."
    }

    func monitorPrivateConnectivity() async {
        guard privateSession, loaded, sessionUnlocked else { return }
        let monitor = NWPathMonitor()
        privatePathMonitor = monitor
        privateNetworkOffline = nil
        let changes = AsyncStream<Bool>(bufferingPolicy: .bufferingNewest(1)) { continuation in
            monitor.pathUpdateHandler = { path in continuation.yield(path.status == .unsatisfied) }
            continuation.onTermination = { _ in monitor.cancel() }
            monitor.start(queue: DispatchQueue(label: "dk.fadedai.studio-private-network"))
        }
        defer {
            monitor.cancel()
            if privatePathMonitor === monitor {
                privatePathMonitor = nil
                privateNetworkOffline = nil
            }
        }
        for await offline in changes {
            guard privateSession, loaded, sessionUnlocked, !Task.isCancelled else { return }
            privateNetworkOffline = offline
            if !offline && loadingBaseImage { basePhoto = nil }
            if !offline && (generatingImages || privateImageRendering) {
                pendingImages.removeAll()
                task?.cancel()
                status = "Netværket er aktivt. Billedet blev stoppet. Slå flytilstand til og Wi-Fi fra for at prøve igen."
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
        preferences.imageModel = if StudioImageModel(rawValue: savedImageModel)?.isInstalled == true {
            savedImageModel
        } else {
            StudioImageModel.allCases.first(where: \.isInstalled)?.id ?? savedImageModel
        }
        let compact = QwenPhoneRuntime.Variant.compact.modelID
        if PhoneModels.installedDirectory(textModel) != nil {
            preferences.textModel = textModel
        } else if PhoneModels.installedDirectory(compact) != nil {
            preferences.textModel = compact
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
        speech.stop()
        if privateSession {
            removeTemporaryStudioImages()
            sessionNote = ""
            turns = []
            privateReplyIssues.removeAll()
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
        speech.stop()
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
        privateReplyIssues.removeAll()
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
                    status = privateImageOfflineInstructions
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
            Button(studioVoicePreviewTitle, systemImage: studioVoicePreviewIcon, action: previewStudioVoice)
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
            if effectiveTextModel == QwenPhoneRuntime.Variant.compact.modelID {
                FadedDetailText("Qwen3.5 0.8B er en lille model. Hvis den misforstår dig, kan du prøve en anden installeret tekstmodel.")
            }
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
            FadedSecondaryButton(studioVoicePreviewTitle, icon: studioVoicePreviewIcon, action: previewStudioVoice)
                .disabled(task != nil)
            ColorPicker("Chatbaggrund", selection: Binding(get: { chatBackdrop }, set: { setChatBackdrop($0) }),
                        supportsOpacity: false)
            if !sessionPreferences.backdrop.isEmpty {
                Button("Brug standardbaggrund") { sessionPreferences.backdrop = Data() }.frame(minHeight: 44)
            }
            Stepper("Ryd efter \(Int(sessionPreferences.idleMinutes)) min uden aktivitet", value: $sessionPreferences.idleMinutes,
                    in: 1...15, step: 1)
            VStack(alignment: .leading, spacing: 4) {
                Text("Modeldvale efter \(Int(sessionPreferences.modelTimeoutMinutes)) min")
                Slider(value: $sessionPreferences.modelTimeoutMinutes, in: 1...15, step: 1)
                    .accessibilityLabel("Minutter til studiets dvale")
                    .onChange(of: sessionPreferences.modelTimeoutMinutes) { _, value in
                        if studioHaptics && (value == 1 || value == 15) {
                            UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                        }
                    }
            }
            Text("Modeller frigives efter hver opgave. Dvale stopper oplæsning og skjuler forhåndsvisningen.")
                .font(.caption).foregroundStyle(palette.secondary)
        }
    }

    var sessionModelPicker: some View {
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

    private var studioVoicePreviewTitle: String { speech.playback == .preview ? "Stop stemmeprøve" : "Afspil prøvesætning" }
    private var studioVoicePreviewIcon: String { speech.playback == .preview ? "stop.circle" : "play.circle" }

    private func previewStudioVoice() {
        if speech.playback == .preview { speech.stop(); return }
        let language = privateSession ? sessionPreferences.voiceLanguage : previewLanguage
        guard let voice = studioVoice(language: language, bot: selectedPrivateBot) else {
            status = "Stemmen er ikke tilgængelig på telefonen."
            return
        }
        resetIdleTimer()
        dictation.stop()
        let utterance = AVSpeechUtterance(string: LocalSpeechVoice.previewSentence(language: voice.language))
        utterance.voice = voice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * Float(selectedPrivateBot?.voiceRate ?? 1)
        speech.play(utterance, as: .preview)
    }

    private func studioVoicePicker(language: String, saved: Binding<String>) -> some View {
        let available = studioVoiceOptions(language: language)
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
        let options = studioVoiceOptions(language: language)
        let saved = if privateSession {
            language == "da-DK" ? sessionPreferences.danishVoice : sessionPreferences.englishVoice
        } else {
            language == "da-DK" ? danishVoiceID : englishVoiceID
        }
        return options.first { $0.identifier == saved }
            ?? options.first { $0.identifier == bot?.voice }
            ?? LocalSpeechVoice.preferred(language: language)
    }

    private func studioVoiceOptions(language: String) -> [AVSpeechSynthesisVoice] {
        let base = language.split(separator: "-").first
        return LocalSpeechVoice.options(language: language, includePersonalVoices: true)
            .filter { $0.language.split(separator: "-").first == base }
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
