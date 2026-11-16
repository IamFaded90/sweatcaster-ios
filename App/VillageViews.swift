// Saved bot profiles, sprite previews and the bot library.

import AVFoundation
import CoreTransferable
import Foundation
import ImageIO
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

@MainActor struct VillageBotBuilder: View {
    private enum Page: String, CaseIterable {
        case profile = "Profil", voice = "Stemme", test = "Prøv bot"
    }

    let api: LiveAPI?
    private let onBack: (() -> Void)?
    private let fixedProfile: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.fadedPalette) private var palette
    @Environment(\.dynamicTypeSize) private var typeSize
    private var savedBots: Data { MigratedAppData.shared.villageBots }
    @AppStorage(AppStorageKeys.phoneModel) private var phoneModel = "apple"
    @AppStorage private var savedEditorDraft: Data
    @State private var draft: VillageBot
    @State private var draftLoaded = false
    @StateObject private var voicePreviewBox = SpeechBox()
    @State private var importing = false
    @State private var showGrokTemplate = false
    @State private var confirmReplaceDraft = false
    @State private var selectedSprite: PhotosPickerItem?
    @State private var exporting = false
    @State private var exportFile: VillageBotFile?
    @State private var confirmDelete = false
    @State private var notice: String?
    @State private var improving = false
    @State private var testTask: Task<Void, Never>?
    @State private var testQuestion = ""
    @State private var testReply = ""
    @State private var generatingSprite = false
    @State private var page = Page.profile

    private var bots: [VillageBot] { VillageBot.list(from: savedBots) }
    private var testing: Bool { testTask != nil }
    private var testModel: String { PhoneModels.effectiveModelID(phoneModel) }
    private var canTest: Bool { PhoneModels.isReady(testModel) }

    init(api: LiveAPI? = nil, bot: VillageBot? = nil, onBack: (() -> Void)? = nil) {
        self.api = api
        self.onBack = onBack
        fixedProfile = bot != nil
        _draft = State(initialValue: bot ?? VillageBot())
        _savedEditorDraft = AppStorage(wrappedValue: Data(), AppStorageKeys.botDraft(bot?.id))
    }

    var body: some View {
        NavigationStack {
            Form {
                if !fixedProfile {
                    Button("Brug en Grok-skabelon", systemImage: "doc.on.doc") {
                        let editingExisting = bots.contains { $0.id == draft.id }
                        if !editingExisting && !savedEditorDraft.isEmpty {
                            confirmReplaceDraft = true
                        } else {
                            showGrokTemplate = true
                        }
                    }
                    .disabled(bots.count >= 10 || testing)
                    .listRowBackground(palette.card)
                    DisclosureGroup("Gemte bots · \(bots.count) af 10") {
                        ForEach(bots) { bot in Button(bot.name) { selectDraft(bot) } }
                        Button("Ny bot") { selectDraft(VillageBot()) }.disabled(bots.count >= 10)
                        Button("Importér agentskabelon") { importing = true }.disabled(bots.count >= 10 || testing)
                    }.listRowBackground(palette.card)
                }
                Group {
                    if typeSize.isAccessibilitySize { pagePicker.pickerStyle(.menu) }
                    else { pagePicker.pickerStyle(.segmented) }
                }.listRowBackground(palette.card)
                switch page {
                case .profile: editor.disabled(testing).listRowBackground(palette.card)
                case .voice: voiceSettings.disabled(testing).listRowBackground(palette.card)
                case .test: localTest.listRowBackground(palette.card)
                }
                if let notice { Text(notice).listRowBackground(palette.card) }
            }
            .scrollContentBackground(.hidden)
            .background { FadedBackground() }
            .foregroundStyle(palette.text)
            .tint(palette.isDark ? palette.lime : palette.text)
            .navigationTitle("Botbygger")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Tilbage", systemImage: "chevron.left", action: close)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Færdig") {
                        if save(draft) { close() }
                    }.fontWeight(.semibold)
                }
            }
            .sheet(isPresented: $showGrokTemplate) {
                GrokBotTemplateView(api: api) { bot in
                    selectDraft(bot)
                }
            }
            .confirmationDialog("Erstat din kladde med en skabelon?", isPresented: $confirmReplaceDraft,
                                titleVisibility: .visible) {
                Button("Vælg skabelon") { showGrokTemplate = true }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json], onCompletion: importBot)
            .fileExporter(isPresented: $exporting, document: exportFile, contentType: .json,
                          defaultFilename: "FadedAI-bot") { result in
                if case .failure = result { notice = "Botten kunne ikke eksporteres." }
            }
            .confirmationDialog("Slet botprofil?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Slet bot", role: .destructive) {
                    guard persist(bots.filter { $0.id != draft.id }) else { return }
                    VillageHistory.shared.retired(draft)
                    if fixedProfile { close() } else { selectDraft(VillageBot()) }
                }
            } message: {
                Text("Botprofilen fjernes fra telefonen og Landsbyen.")
            }
            .onAppear {
                guard !draftLoaded else { return }
                if let restored = try? JSONDecoder().decode(VillageBot.self, from: savedEditorDraft), !fixedProfile || restored.id == draft.id {
                    draft = restored
                }
                draftLoaded = true
            }
            .onChange(of: draft) { _, value in updateDraftCache(value) }
            .onDisappear { stopPreview() }
        }
    }

    private var pagePicker: some View {
        Picker("Sektion", selection: $page) {
            ForEach(Page.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
    }

    private var editor: some View {
        Section("Botprofil på telefonen") {
            TextField("Navn", text: $draft.name)
            if !savedEditorDraft.isEmpty { Text("Gemt som kladde").font(.caption).foregroundStyle(.secondary) }
            TextField("Speciale, fx Researcher", text: Binding(
                get: { draft.specialty ?? "" }, set: { draft.specialty = String($0.prefix(64)) }
            ))
            Menu("Vælg et speciale", systemImage: "person.crop.circle.badge.checkmark") {
                ForEach(["Stabschef", "Skribent", "Researcher", "Kode og logik", "Kreativ leder", "SEO", "Økonomi", "Coach"], id: \.self) { role in
                    Button(role) { draft.specialty = role }
                }
            }
            TextField("Ansvar og grænser", text: Binding(
                get: { draft.responsibility ?? "" }, set: { draft.responsibility = String($0.prefix(400)) }
            ), axis: .vertical).lineLimit(2...4)
            Text("Profilbilledet vises ved botten. Landsbyfiguren bruger sit eget pixelbillede.").font(.footnote).foregroundStyle(.secondary)
            PhotosPicker("Vælg profilbillede fra Fotos", selection: $selectedSprite, matching: .images)
                .onChange(of: selectedSprite) { _, item in
                    guard let item else { return }
                    let id = draft.id
                    Task { await loadSprite(item, botID: id) }
                }
            if let api {
                Button(generatingSprite ? "PC’en tegner profilbilledet…" : "Generér profilbillede på PC’en") {
                    Task { await generateSprite(api) }
                }
                .disabled(generatingSprite)
            }
            if let data = draft.sprite, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().interpolation(.none)
                    .scaledToFill().frame(width: 112, height: 112).clipShape(Circle())
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("Bottens profilbillede")
                Button("Fjern profilbillede") { draft.sprite = nil }
            }
            Picker("Farve", selection: $draft.color) {
                ForEach(["Blå", "Lilla", "Grøn"], id: \.self) { Text($0) }
            }
            TextField("Systemprompt", text: $draft.prompt, axis: .vertical).lineLimit(3...8)
            Picker("Personlighed", selection: Binding(
                get: { draft.personality ?? "Nysgerrig" },
                set: { draft.personality = $0 }
            )) {
                ForEach(["Nysgerrig", "Rolig", "Sjov", "Omsorgsfuld"], id: \.self) { Text($0) }
            }
            Picker("Sprog", selection: Binding(
                get: { draft.language ?? "da-DK" }, set: { draft.language = $0 }
            )) {
                Text("Dansk").tag("da-DK")
                Text("Engelsk").tag("en-US")
                Text("Automatisk").tag("auto")
            }
            Toggle("Notifikationer fra botten", isOn: Binding(
                get: { draft.notifications ?? true }, set: { draft.notifications = $0 }
            ))
            Button("Forbedr prompt på telefonen") { Task { await improvePrompt() } }
                .disabled(improving || draft.prompt.isEmpty || !PhoneModels.appleAvailable)
            Button("Gem bot") { _ = save(draft) }.disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if bots.contains(where: { $0.id == draft.id }) {
                if draft.id != VillageBot.lumiID {
                    Button("Del som agentskabelon") { exportFile = VillageBotFile(bot: draft); exporting = true }
                }
                FadedSecondaryButton("Slet bot", icon: "trash", role: .destructive) { confirmDelete = true }
            }
        }
    }

    private var voiceSettings: some View {
        Section("Oplæsning på telefonen") {
            Picker("Stemme", selection: $draft.voice) {
                Text("Bedste danske stemme").tag("da-DK")
                Text("Bedste engelske stemme").tag("en-US")
                ForEach(LocalSpeechVoice.options(language: "da-DK", includePersonalVoices: true) + LocalSpeechVoice.options(language: "en-US"),
                        id: \.identifier) { voice in
                    Text(LocalSpeechVoice.label(voice)).tag(voice.identifier)
                }
            }
            VStack(alignment: .leading) {
                Text("Talehastighed · \((draft.voiceRate ?? 1).formatted(.number.precision(.fractionLength(1))))x")
                Slider(value: Binding(get: { draft.voiceRate ?? 1 }, set: { draft.voiceRate = $0 }),
                       in: 0.7...1.3, step: 0.1)
            }
            let playing = voicePreviewBox.playback == .preview
            FadedSecondaryButton(playing ? "Stop stemmeprøve" : "Prøv stemme", icon: playing ? "stop.circle" : "play.circle") { speakPreview(draft.previewSentence) }
        }
    }

    private func loadSprite(_ item: PhotosPickerItem, botID: UUID) async {
        defer { if draft.id == botID, selectedSprite == item { selectedSprite = nil } }
        do {
            guard let photo = try await item.loadTransferable(type: VillageSpritePhoto.self) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            guard draft.id == botID, selectedSprite == item else { return }
            draft.sprite = photo.sprite
            notice = nil
        } catch {
            AppDiagnostics.record(error)
            guard draft.id == botID, selectedSprite == item else { return }
            notice = "Billedet kunne ikke læses. Vælg et billede på højst 80 MB."
        }
    }

    private func generateSprite(_ api: LiveAPI) async {
        guard !generatingSprite else { return }
        generatingSprite = true
        defer { generatingSprite = false }
        let id = draft.id
        let prompt = "Single friendly full body robot, 2D isometric pixel art sprite, centered with margin, simple solid dark backdrop, no text. Color: \(draft.color). Personality: \(draft.personality ?? "rolig")."
        do {
            let data = try await api.v2GenerateImage(prompt: prompt)
            guard draft.id == id else { return }
            guard let sprite = VillageSpritePhoto.thumbnail(data) else { throw APIError.malformed }
            draft.sprite = sprite
            notice = "Figuren er klar. Tryk Gem bot for at bruge den i Landsbyen."
        } catch {
            AppDiagnostics.record(error)
            guard draft.id == id else { return }
            notice = "PC’en kunne ikke lave figuren. Kontrollér billedtjenesten, eller vælg et billede fra Fotos."
        }
    }

    private var localTest: some View {
        Section("Prøv AI på denne iPhone") {
            Text(canTest ? "Din valgte telefonmodel er klar." : "Vælg en klar model under Lokale modeller.")
            TextField("Besked til botten", text: $testQuestion, axis: .vertical)
                .disabled(testing)
            FadedPrimaryButton(testing ? "Svarer på telefonen…" : "Prøv på telefonen", icon: "arrow.up") {
                testTask = Task { await testBot() }
            }
            .disabled(testing || !canTest || testQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if !testReply.isEmpty {
                Label("Telefon", systemImage: "iphone")
                Text(testReply).textSelection(.enabled)
                Button(voicePreviewBox.playback == .preview ? "Stop oplæsning" : "Læs testsvar op",
                       systemImage: voicePreviewBox.playback == .preview ? "stop.circle" : "speaker.wave.2") { speakPreview(testReply) }
                    .frame(minHeight: 44).disabled(testing)
            }
        }
    }

    private func testBot() async {
        let modelID = testModel
        let instructions = OfflineStudio.companionInstructions(for: draft)
        let question = testQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        testReply = ""
        notice = nil
        defer { testTask = nil }
        do {
            try await PhoneModels.reply(modelID: modelID, prompt: question, instructions: instructions) {
                if !Task.isCancelled { testReply = $0 }
            }
        } catch is CancellationError {
        } catch {
            AppDiagnostics.record(error)
            notice = "Telefonen kunne ikke svare. Tjek din valgte lokale model, og prøv igen."
        }
    }

    private func speakPreview(_ text: String) {
        if voicePreviewBox.playback == .preview { voicePreviewBox.stop() }
        else { voicePreviewBox.play(draft.utterance(text), as: .preview) }
    }

    private func stopPreview() {
        testTask?.cancel()
        voicePreviewBox.stop()
    }

    private func selectDraft(_ bot: VillageBot) {
        stopPreview()
        draft = bot
        page = .profile
        testReply = ""
    }

    private func close() {
        stopPreview()
        if let onBack { onBack() } else { dismiss() }
    }

    private func save(_ bot: VillageBot) -> Bool {
        guard !bot.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            notice = "Skriv et navn til botten, før du gemmer."
            page = .profile
            return false
        }
        var updated = bots
        let isNew = !updated.contains(where: { $0.id == bot.id })
        if let index = updated.firstIndex(where: { $0.id == bot.id }) { updated[index] = bot }
        else {
            guard updated.count < 10 else { notice = "Du kan gemme op til 10 bots."; return false }
            updated.append(bot)
        }
        guard persist(updated) else { return false }
        UserDefaults.standard.set(bot.voice, forKey: PhoneModels.agentVoiceKey(bot.id))
        if isNew { VillageHistory.shared.created(bot) }
        savedEditorDraft = Data()
        return true
    }

    private func updateDraftCache(_ bot: VillageBot) {
        guard draftLoaded else { return }
        if fixedProfile, let existing = bots.first(where: { $0.id == bot.id }), existing == bot {
            savedEditorDraft = Data()
            return
        }
        if !fixedProfile && bots.contains(where: { $0.id == bot.id }) { return }
        if bot.name.isEmpty && bot.prompt.isEmpty && bot.sprite == nil && !fixedProfile {
            savedEditorDraft = Data()
        } else if let data = try? JSONEncoder().encode(bot) {
            savedEditorDraft = data
        }
    }

    private func persist(_ value: [VillageBot]) -> Bool {
        do {
            try MigratedAppData.shared.saveVillageBots(JSONEncoder().encode(value))
            notice = nil
            return true
        } catch {
            AppDiagnostics.record(error)
            notice = "Botten kunne ikke gemmes."
            return false
        }
    }

    private func importBot(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let data = try LocalFileStore.readBytes(from: url, maximumBytes: VillageBotFile.maximumBytes)
            let template = try? JSONDecoder().decode(VillageBotTemplate.self, from: data)
            var bot = try template?.profile ?? JSONDecoder().decode(VillageBot.self, from: data)
            guard bot.id != VillageBot.lumiID, !bot.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CocoaError(.fileReadCorruptFile)
            }
            if let original = bot.sprite {
                guard let sprite = VillageSpritePhoto.thumbnail(original) else { throw CocoaError(.fileReadCorruptFile) }
                bot.sprite = sprite
            }
            bot.id = UUID()
            if save(bot) {
                if let template {
                    let options = PhoneModels.textOptions
                    let imported = options.first { $0.id == template.phoneModelID || $0.name == template.phoneModelName }
                    if let imported {
                        UserDefaults.standard.set(imported.id, forKey: PhoneModels.agentModelKey(bot.id))
                    }
                    if let id = template.pcModelID, (1...96).contains(id.utf8.count) {
                        UserDefaults.standard.set(id, forKey: PhoneModels.agentPCModelKey(bot.id))
                    }
                }
                draft = bot
            }
        } catch { AppDiagnostics.record(error); notice = "Filen kunne ikke læses som en FadedAI-bot." }
    }

    private func improvePrompt() async {
        improving = true
        defer { improving = false }
        let original = draft
        var suggestion = ""
        do {
            try await PhoneModels.reply(modelID: "apple", prompt:
                "Omskriv denne idé til en kort systemprompt på dansk. Returnér kun prompten. Idé: " +
                original.prompt) { suggestion = $0 }
            if draft.id == original.id && draft.prompt == original.prompt { draft.prompt = suggestion }
        } catch { AppDiagnostics.record(error); notice = "Telefonen kunne ikke forbedre prompten." }
    }
}
