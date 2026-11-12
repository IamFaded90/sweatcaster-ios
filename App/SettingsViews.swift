// Viser indstillinger, noter, forbindelsestest og eksport af fejllog.

import AVFAudio
import SwiftUI
import UIKit

struct FadedNotesSheet: View {
    let onClose: () -> Void
    @State private var unsavedNotes: String?

    var body: some View {
        NavigationStack {
            TextEditor(text: Binding(get: { unsavedNotes ?? MigratedAppData.shared.notes }, set: saveNotes))
                .font(FadedTypography.body)
                .scrollContentBackground(.hidden)
                .padding(FadedSpacing.edge)
                .background(FadedBackground())
                .accessibilityLabel("Dine noter")
                .navigationTitle("Noter")
                .toolbar { Button("Luk", action: onClose) }
                .safeAreaInset(edge: .bottom) {
                    if unsavedNotes != nil { Text("Noten kunne ikke gemmes.").font(.footnote).padding() }
                }
        }
    }

    private func saveNotes(_ text: String) {
        do { try MigratedAppData.shared.saveNotes(text); unsavedNotes = nil }
        catch { AppDiagnostics.record(error); unsavedNotes = text }
    }
}

private struct VideoCleanupSettings: View {
    let prunePreviews: () -> String
    let hideFinishedJobs: () -> Int
    @State private var previewNotice: String?
    @State private var jobsNotice: String?
    @State private var confirmHideJobs = false

    var body: some View {
        Button("Ryd previews over 24 timer") { previewNotice = prunePreviews() }
        if let previewNotice { FadedDetailText(previewNotice) }
        Button("Skjul afsluttede jobs på denne telefon", role: .destructive) { confirmHideJobs = true }
            .confirmationDialog("Skjul afsluttede jobs på denne telefon?", isPresented: $confirmHideJobs) {
                Button("Skjul afsluttede jobs", role: .destructive) {
                    let count = hideFinishedJobs()
                    jobsNotice = count == 0 ? "Der er ingen afsluttede jobs at skjule."
                        : count == 1 ? "Ét afsluttet job er skjult." : "\(count) afsluttede jobs er skjult."
                }
            } message: {
                Text("Videoer og jobhistorik bliver liggende på PC’en.")
            }
        if let jobsNotice { FadedDetailText(jobsNotice) }
    }
}

private struct PersonalVoiceSettings: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var typeSize
    @AppStorage(AppStorageKeys.chatVoiceIdentifier) private var voiceID = ""
    @AppStorage(AppStorageKeys.chatVoiceBot) private var voiceBotID = ""
    @AppStorage(AppStorageKeys.chatVoiceRate) private var voiceRate = 1.0
    @State private var authorization = AVSpeechSynthesizer.personalVoiceAuthorizationStatus
    @State private var voices: [AVSpeechSynthesisVoice] = []
    @State private var requesting = false
    @State private var previewVoiceID: String?
    @StateObject private var previewSpeech = SpeechBox()

    var body: some View {
        Section("Personlig stemme") {
            switch authorization {
            case .authorized:
                if voices.isEmpty {
                    FadedDetailText("Opret eller færdiggør din stemme i iPhones Indstillinger → Tilgængelighed → Personlig stemme.")
                }
                ForEach(voices, id: \.identifier, content: voiceRow)
                if !voices.isEmpty {
                    FadedDetailText("Tryk på stemmenavnet for at vælge det til chatten. Brug Afspil prøve for at høre stemmen.")
                }
            case .notDetermined:
                Button("Tillad personlig stemme", systemImage: "waveform") { requestAccess() }
                    .disabled(requesting)
                FadedDetailText("Slå Apps må anmode om at bruge til under Tilgængelighed → Personlig stemme på din iPhone.")
            case .denied:
                FadedDetailText("Giv FadedAI adgang under iPhones Indstillinger → Tilgængelighed → Personlig stemme.")
            case .unsupported:
                FadedDetailText("Denne enhed understøtter ikke Personlig stemme. Du kan vælge en systemstemme i chatten.")
            @unknown default:
                FadedDetailText("Personlig stemme er utilgængelig. Du kan vælge en systemstemme i chatten.")
            }
            FadedDetailText("Personlig stemme følger optagelsens sprog. Vælg en dansk systemstemme til dansk oplæsning.")
        }
        .onAppear(perform: refresh)
        .onDisappear(perform: stopPreview)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refresh() }
            else { stopPreview() }
        }
        .onChange(of: previewSpeech.playback) { _, playback in
            if playback == nil { previewVoiceID = nil }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { notification in
            guard let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: type) == .began else { return }
            stopPreview()
        }
        .onReceive(NotificationCenter.default.publisher(for: AVSpeechSynthesizer.availableVoicesDidChangeNotification)) { _ in
            Task { @MainActor in refresh() }
        }
    }

    private func voiceRow(_ voice: AVSpeechSynthesisVoice) -> some View {
        let selected = voiceBotID.isEmpty && voiceID == voice.identifier
        let previewing = previewVoiceID == voice.identifier && previewSpeech.playback == .preview
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: FadedSpacing.xs))
            : AnyLayout(HStackLayout(spacing: FadedSpacing.s))
        return VStack(alignment: .leading, spacing: FadedSpacing.xs) {
            layout {
                Button {
                    voiceBotID = ""
                    voiceID = voice.identifier
                } label: {
                    Label(LocalSpeechVoice.label(voice), systemImage: selected ? "checkmark.circle.fill" : "waveform")
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }
                .buttonStyle(.borderless)
                .accessibilityAddTraits(selected ? [.isSelected] : [])

                Button {
                    if previewing { stopPreview() }
                    else { playPreview(voice) }
                } label: {
                    Label(previewing ? "Stop prøve" : "Afspil prøve", systemImage: previewing ? "stop.circle" : "play.circle")
                        .font(.subheadline)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(previewing ? "Stop prøve med \(voice.name)" : "Afspil prøve med \(voice.name)")
            }
            if previewing {
                FadedDetailText(previewSpeech.isSpeaking ? "Afspiller stemmeprøven" : "Klargør stemmeprøven…")
            }
        }
    }

    private func playPreview(_ voice: AVSpeechSynthesisVoice) {
        guard scenePhase == .active, authorization == .authorized else { return }
        let sample = LocalSpeechVoice.previewSentence(language: voice.language)
        let utterance = LocalSpeechVoice.utterance(sample, voice: voice, rate: voiceRate)
        previewVoiceID = voice.identifier
        previewSpeech.play(utterance, as: .preview)
    }

    private func stopPreview() {
        previewVoiceID = nil
        if previewSpeech.playback != nil { previewSpeech.stop() }
    }

    private func requestAccess() {
        requesting = true
        Task { @MainActor in
            _ = await AVSpeechSynthesizer.requestPersonalVoiceAuthorization()
            requesting = false
            refresh()
        }
    }

    private func refresh() {
        authorization = AVSpeechSynthesizer.personalVoiceAuthorizationStatus
        voices = LocalSpeechVoice.personalVoices
        if let previewVoiceID, !voices.contains(where: { $0.identifier == previewVoiceID }) { stopPreview() }
    }
}

extension Home {
    private var connectionIndicator: some View {
        let latency = model.latencyMs
        let color = latencyColor(latency)
        return HStack(spacing: 8) {
            Circle().fill(color).frame(width: 8, height: 8).accessibilityHidden(true)
            Label("\(model.activeProfile.route) · \(model.connected ? "Forbundet" : "Ikke forbundet")",
                  systemImage: model.connected ? "checkmark.circle" : "exclamationmark.circle")
            if let latency { Text("\(latency) ms").foregroundStyle(.secondary) }
        }.font(.subheadline)
    }

    var settingsSheet: some View {
        NavigationStack(path: $settingsPath) {
            ScrollView {
                VStack(alignment: .leading, spacing: FadedSpacing.section) {
                    ForEach(SettingsCategory.allCases, id: \.self) { category in
                        NavigationLink(value: category) { settingsRow(category) }
                            .buttonStyle(.plain)
                    }
                }
                .padding(FadedSpacing.edge)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            .background(FadedBackground())
            .navigationTitle("Indstillinger")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Luk") { showSettings = false } }
            }
            .navigationDestination(for: SettingsCategory.self) { settingsPage($0) }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(palette.background)
    }

    func latencyColor(_ milliseconds: Int?) -> Color {
        guard let milliseconds else { return palette.coral }
        if milliseconds < 50 { return palette.green }
        return milliseconds <= 200 ? .yellow : palette.coral
    }

    private func settingsRow(_ category: SettingsCategory) -> some View {
        let accent: Color = switch category {
        case .connection: palette.cyan
        case .models: palette.purple
        case .appearance: FadedBrand.mint
        case .diagnostics: palette.secondary
        }
        return FadedCard {
            HStack(spacing: FadedSpacing.m) {
                Image(systemName: category.icon)
                    .foregroundStyle(palette.isDark ? accent : palette.text)
                    .frame(width: 38, height: 38)
                    .background(accent.opacity(0.15), in: RoundedRectangle(cornerRadius: FadedRadius.medium))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: FadedSpacing.xs) {
                    Text(category.rawValue).font(FadedTypography.action).foregroundStyle(palette.text)
                    Text(category.detail).font(.subheadline).foregroundStyle(palette.secondary)
                }
                Spacer(minLength: FadedSpacing.xs)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(palette.secondary)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 44)
        }
    }

    private func settingsPage(_ category: SettingsCategory) -> some View {
        Form {
            switch category {
            case .connection:
                Section("PC-forbindelse") {
                    connectionIndicator
                    pingSetting
                    Button("Skift forbindelse") { closeSettings(for: .login) }.disabled(switchDisabled)
                    NavigationLink("Forbindelser") {
                        ConnectionsView(embyAPI: model.isDemo || privateStudioPresented ? nil : model.api as? LiveAPI)
                    }
                }
                Section("Status og opdatering") {
                    Toggle("Vis forbindelsesbanner", isOn: $showConnectionBanner)
                    Toggle("Opdatér ved faneskift", isOn: $autoRefreshTabs)
                }
            case .models:
                Section("Telefon og PC") {
                    Button("Lokale modeller (iPhone)", systemImage: "iphone") { closeSettings(for: .models) }
                    FadedDetailText("Hent tekst- og billedmodeller til iPhone, og brug dem igen uden download.")
                    NavigationLink {
                        PCModelsView(api: studioAPI)
                    } label: {
                        Label("PC-modeller (RTX 3070)", systemImage: "desktopcomputer")
                    }
                    Toggle("Vælg automatisk model", isOn: $autoModelRouter)
                    FadedDetailText("Automatisk modelvalg bruger Telefon og PC. Grok vælges manuelt.")
                }
                Section("Grok") { CloudModelSettings() }
                Section("Værktøjer") {
                    Button("Privat Studio") { closeSettings(for: .privateChat) }
                    Button("Mine bots") { closeSettings(for: .bots) }
                    Button("Code Bot og Agent Workspace") { closeSettings(for: .code) }
                }
            case .appearance:
                appearanceSettings
                Section("Chat og lyd") {
                    Toggle("Vis værktøjsstatus", isOn: $showChatTools)
                    Toggle("Læs chatsvar op", isOn: $readChatAloud)
                    Toggle("Haptisk feedback", isOn: $appHaptics)
                    Text("Vælg stemme i chatten eller på din bots profil.").font(.callout).foregroundStyle(palette.secondary)
                }
                PersonalVoiceSettings()
            case .diagnostics:
                Section("PC og ressourcer") {
                    pingSetting
                    ResourceMonitor()
                    Button("Eksportér fejllog", systemImage: "square.and.arrow.up") { closeSettings(for: .export) }
                }
                Section("Notifikationer") {
                    JobNotificationSettings()
                    Toggle("Liveaktivitet på låseskærmen", isOn: $liveActivityEnabled)
                }
                Section("Medier") {
                    Toggle("Gem almindelige billeder i Fotos", isOn: $saveImagesToPhotos)
                    FadedDetailText("Privat Studio gemmer kun en kopi i Fotos, når du selv vælger det.")
                    Toggle("Bekræft før video startes", isOn: $confirmVideoStart)
                    VideoCleanupSettings(prunePreviews: prunePreviews) {
                        let previousCount = hiddenJobs.count
                        hiddenJobs.formUnion(model.jobs.filter { !$0.status.active }.map(\.id))
                        return hiddenJobs.count - previousCount
                    }
                }
                Section("Eksperimentelle funktioner") { ExperimentalVillageSetting() }
                Section("Lokale data") {
                    NavigationLink("Backup og gendan") {
                        BackupSettingsView(canRestore: {
                            !model.busy && !model.refreshing && !model.checkingVideoOutbox &&
                                !model.mediaLoading && model.cancelling.isEmpty
                        }, onRestore: {
                            UserDefaults.standard.set(UUID().uuidString, forKey: AppStorageKeys.appResetGeneration)
                        })
                        .onAppear { showingBackupTools = true }
                        .onDisappear { showingBackupTools = false }
                    }
                    NukeLocalDataButton()
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(FadedBackground())
        .navigationTitle(category.rawValue)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { Button("Luk") { showSettings = false } }
        }
    }

    @ViewBuilder private var pingSetting: some View {
        Button(pinging ? "Tester PC…" : "Ping PC", systemImage: "network") {
            Task {
                pinging = true
                defer { pinging = false }
                pingResult = await model.ping()
            }
        }.disabled(pinging)
        if let pingResult { Text(pingResult).font(.caption).foregroundStyle(.secondary) }
    }

    private func closeSettings(for destination: SettingsFollowup) {
        settingsFollowup = destination
        showSettings = false
    }

    func openSettingsFollowup() {
        settingsPath.removeAll()
        guard let destination = settingsFollowup else { return }
        settingsFollowup = nil
        switch destination {
        case .login: showLogin = true
        case .models: showPhoneModels = true
        case .privateChat: openStudio(.chat)
        case .bots: showBots = true
        case .code: searchCodePath = nil; showCodeWorkspace = true
        case .export: exportDiagnostics()
        }
    }

    @ViewBuilder private var appearanceSettings: some View {
        let colors = [Color(red: 0.83, green: 1, blue: 0.93), FadedBrand.mint, FadedBrand.blue, palette.raised]
        Section {
            FadedCard(size: .hero) {
                VStack(alignment: .leading, spacing: FadedSpacing.m) {
                    HStack(spacing: FadedSpacing.s) {
                        ForEach(colors.indices, id: \.self) { index in
                            Circle().fill(colors[index]).frame(width: 26, height: 26)
                        }
                    }
                    .accessibilityHidden(true)
                    Text("Premium Dark. Supreme Sky.").font(FadedTypography.title)
                    FadedDetailText("Mørkt, roligt og helt dit. Tilpas tema, tekst og bevægelse her.")
                }
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
        } header: {
            Text("På dine vilkår")
        }
        Section("Tema og tekst") {
            Picker("Lys og mørke", selection: $appearanceMode) {
                ForEach(FadedAppearance.allCases, id: \.self) { mode in Text(mode.rawValue).tag(mode) }
            }
            Picker("Tema", selection: $theme) {
                ForEach(FadedTheme.allCases) { choice in Text(choice.rawValue).tag(choice) }
            }
            textSizeSetting
            Picker("Skrift", selection: $font) {
                ForEach(["Standard", "Afrundet", "Monospace"], id: \.self) { Text($0) }
            }
        }
        Section("Bevægelse og navigation") {
            Toggle("Bevægelse i baggrunden", isOn: $motion)
            Toggle("Ekstra rolig bevægelse", isOn: $calmMotion)
            Toggle("Husk seneste fane", isOn: $rememberLastSpace)
            Toggle("Hold skærmen vågen", isOn: $keepScreenAwake)
        }
        Section("Video") {
            Toggle("Kompakte klipkort", isOn: $compactClipCards)
            Toggle("Vis kliplængde", isOn: $showClipDurations)
            Toggle("Vis jobdetaljer", isOn: $showJobDetails)
        }
    }

    private var textSizeSetting: some View {
        let slider = Slider<Text, EmptyView>(value: $textScale, in: 0.0...5.0, step: 1.0,
                                             label: { Text("Tekststørrelse") })
        return slider
            .accessibilityLabel("Tekststørrelse i appen")
            .sensoryFeedback(.selection, trigger: textScale) { (old: Double, new: Double) in
                appHaptics && old != new && (new == 0 || new == 5)
            }
    }

    func exportDiagnostics() {
        let selected = UserDefaults.standard.string(forKey: PhoneModels.selectionKey) ?? "apple"
        let name = PhoneModels.catalog.first(where: { $0.id == selected })?.name
            ?? (selected == "imported" ? "Importeret model" : "Apple Foundation Models")
        do {
            diagnosticsExport = DiagnosticsExport(url: try AppDiagnostics.export(phoneModel: name,
                                                                                 pcConnected: model.connected && !model.isDemo))
        }
        catch { AppDiagnostics.record(error); diagnosticsError = true }
    }
}
