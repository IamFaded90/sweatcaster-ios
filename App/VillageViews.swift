// Saved bot profiles, sprite previews and the bot library.

import AVFoundation
import CoreTransferable
import Foundation
import ImageIO
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct VillageBot: Codable, Identifiable, Equatable {
    static let defaultTraits = ["Rolig", "Nysgerrig", "Tålmodig"]

    var id: UUID
    var name: String
    var color: String
    var prompt: String
    var voice: String
    var sprite: Data?
    var personality: String?
    var notifications: Bool?
    var voiceRate: Double?
    var language: String?
    var specialty: String?
    var responsibility: String?
    var traits: [String]
    var bestFriendID: UUID?
    var dailyMemory: [String]

    init(id: UUID = UUID(), name: String = "", color: String = "Blå", prompt: String = "",
         voice: String = "da-DK", sprite: Data? = nil, personality: String? = nil,
         notifications: Bool? = true, voiceRate: Double? = 1.0, language: String? = "da-DK",
         specialty: String? = nil, responsibility: String? = nil,
         traits: [String] = VillageBot.defaultTraits, bestFriendID: UUID? = nil, dailyMemory: [String] = []) {
        self.id = id
        self.name = name
        self.color = color
        self.prompt = prompt
        self.voice = voice
        self.sprite = sprite
        self.personality = personality
        self.notifications = notifications
        self.voiceRate = voiceRate
        self.language = language
        self.specialty = specialty
        self.responsibility = responsibility
        self.traits = traits
        self.bestFriendID = bestFriendID
        self.dailyMemory = dailyMemory
    }

    static func founderAdam() -> VillageBot {
        VillageBot(name: "Adam", color: "Blå",
                   prompt: "Hjælp med kode og logik. Vær rolig, grundig og præcis, og foreslå ændringer som brugeren gennemgår.",
                   personality: "Rolig", specialty: "Kode og logik",
                   traits: ["Flittig", "Perfektionist", "Tålmodig"])
    }

    static func founderEva() -> VillageBot {
        VillageBot(name: "Eva", color: "Lilla",
                   prompt: "Hjælp med video. Vær legesyg, nysgerrig og social, og foreslå klip og fortælling.",
                   personality: "Nysgerrig", specialty: "Kreativ leder",
                   traits: ["Kreativ", "Nysgerrig", "Social"])
    }

    /// Hopper over én ødelagt bot og beholder resten. En ulæselig fil kaster videre.
    static func listRecovering(from data: Data) throws -> [VillageBot] {
        let raw = try JSONSerialization.jsonObject(with: data)
        guard let array = raw as? [Any] else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Botlisten er ikke en liste"))
        }
        return array.compactMap { element in
            do {
                let item = try JSONSerialization.data(withJSONObject: element)
                return try JSONDecoder().decode(VillageBot.self, from: item)
            } catch {
                AppDiagnostics.record(error)
                return nil
            }
        }
    }

    static func list(from data: Data) -> [VillageBot] {
        guard !data.isEmpty else { return [] }
        return (try? listRecovering(from: data)) ?? []
    }

    var specialtyTitle: String {
        let named = specialty?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return named.isEmpty ? "Personlig sparring" : named
    }

    private var playbackVoice: AVSpeechSynthesisVoice? {
        let locale = ["da-DK", "en-US", "en-GB"].contains(voice) ? voice : language ?? "da-DK"
        return LocalSpeechVoice.resolve(identifier: voice, language: locale == "auto" ? "da-DK" : locale)
    }

    var previewSentence: String {
        let trait = personality ?? "Nysgerrig"
        let voice = playbackVoice
        if let voice, voice.voiceTraits.contains(.isPersonalVoice) {
            return LocalSpeechVoice.previewSentence(language: voice.language)
        }
        if voice?.language.hasPrefix("en") == true {
            let englishTrait = ["Nysgerrig": "curious", "Rolig": "calm", "Sjov": "playful", "Omsorgsfuld": "caring"][trait] ?? trait.lowercased()
            return "Hi, I'm \(name.isEmpty ? "your bot" : name). I'm \(englishTrait)."
        }
        return "Hej, jeg er \(name.isEmpty ? "din bot" : name). Jeg er \(trait.lowercased())."
    }

    var voiceDetails: String { playbackVoice.map(LocalSpeechVoice.label) ?? "Systemstemme" }

    var voiceQuality: String { playbackVoice.map(LocalSpeechVoice.qualityLabel) ?? "Systemstemme" }

    func utterance(_ text: String) -> AVSpeechUtterance {
        let result = AVSpeechUtterance(string: text)
        result.voice = playbackVoice
        result.rate = AVSpeechUtteranceDefaultSpeechRate * Float(min(1.3, max(0.7, voiceRate ?? 1)))
        return result
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, color, prompt, voice, sprite, personality, notifications, voiceRate, language
        case specialty, responsibility, traits, bestFriendID, dailyMemory
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        color = try container.decode(String.self, forKey: .color)
        prompt = try container.decode(String.self, forKey: .prompt)
        voice = try container.decode(String.self, forKey: .voice)
        sprite = try container.decodeIfPresent(Data.self, forKey: .sprite)
        personality = try container.decodeIfPresent(String.self, forKey: .personality)
        notifications = try container.decodeIfPresent(Bool.self, forKey: .notifications)
        voiceRate = try container.decodeIfPresent(Double.self, forKey: .voiceRate)
        language = try container.decodeIfPresent(String.self, forKey: .language)
        specialty = try container.decodeIfPresent(String.self, forKey: .specialty)
        responsibility = try container.decodeIfPresent(String.self, forKey: .responsibility)
        traits = try container.decodeIfPresent([String].self, forKey: .traits) ?? Self.defaultTraits
        bestFriendID = try container.decodeIfPresent(UUID.self, forKey: .bestFriendID)
        dailyMemory = try container.decodeIfPresent([String].self, forKey: .dailyMemory) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(color, forKey: .color)
        try container.encode(prompt, forKey: .prompt)
        try container.encode(voice, forKey: .voice)
        try container.encodeIfPresent(sprite, forKey: .sprite)
        try container.encodeIfPresent(personality, forKey: .personality)
        try container.encodeIfPresent(notifications, forKey: .notifications)
        try container.encodeIfPresent(voiceRate, forKey: .voiceRate)
        try container.encodeIfPresent(language, forKey: .language)
        try container.encodeIfPresent(specialty, forKey: .specialty)
        try container.encodeIfPresent(responsibility, forKey: .responsibility)
        try container.encode(traits, forKey: .traits)
        try container.encodeIfPresent(bestFriendID, forKey: .bestFriendID)
        try container.encode(dailyMemory, forKey: .dailyMemory)
    }
}

private struct VillageBotFile: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    static let maximumBytes = 256_000
    let bot: VillageBot

    init(bot: VillageBot) { self.bot = bot }

    init(configuration: ReadConfiguration) throws {
        let attributes = configuration.file.fileAttributes as NSDictionary
        if let size = attributes[FileAttributeKey.size.rawValue] as? NSNumber, size.int64Value > Int64(Self.maximumBytes) {
            throw CocoaError(.fileReadTooLarge)
        }
        guard let data = configuration.file.regularFileContents, data.count <= Self.maximumBytes else {
            throw CocoaError(.fileReadCorruptFile)
        }
        bot = try JSONDecoder().decode(VillageBot.self, from: data)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: try JSONEncoder().encode(bot))
    }
}

private struct VillageSpritePhoto: Transferable {
    let sprite: Data

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            let url = received.file
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { throw CocoaError(.fileReadCorruptFile) }
            guard let size = values.fileSize, (1...80_000_000).contains(size) else { throw CocoaError(.fileReadTooLarge) }
            return try autoreleasepool {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                      let sprite = thumbnail(source) else { throw CocoaError(.fileReadCorruptFile) }
                return VillageSpritePhoto(sprite: sprite)
            }
        }
    }

    static func thumbnail(_ data: Data) -> Data? {
        autoreleasepool {
            guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
            return thumbnail(source)
        }
    }

    private static func thumbnail(_ source: CGImageSource) -> Data? {
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 64
        ] as CFDictionary) else { return nil }
        return UIImage(cgImage: thumbnail).pngData()
    }
}

struct VillageBotBuilder: View {
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
    private var canTest: Bool { testModel == "apple" ? PhoneModels.appleAvailable : PhoneModels.installedDirectory(testModel) != nil }

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
                    DisclosureGroup("Gemte bots · \(bots.count) af 10") {
                        ForEach(bots) { bot in Button(bot.name) { selectDraft(bot) } }
                        Button("Ny bot") { selectDraft(VillageBot()) }.disabled(bots.count >= 10)
                        Button("Importér JSON") { importing = true }.disabled(bots.count >= 10 || testing)
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
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json], onCompletion: importBot)
            .fileExporter(isPresented: $exporting, document: exportFile, contentType: .json,
                          defaultFilename: "FadedAI-bot") { result in
                if case .failure = result { notice = "Botten kunne ikke eksporteres." }
            }
            .confirmationDialog("Slet botprofil?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Slet bot", role: .destructive) {
                    guard persist(bots.filter { $0.id != draft.id }) else { return }
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
            PhotosPicker("Vælg figur fra Fotos", selection: $selectedSprite, matching: .images)
                .onChange(of: selectedSprite) { _, item in
                    guard let item else { return }
                    let id = draft.id
                    Task { await loadSprite(item, botID: id) }
                }
            if let api {
                Button(generatingSprite ? "PC’en tegner figuren…" : "Generér pixelfigur på PC’en") {
                    Task { await generateSprite(api) }
                }
                .disabled(generatingSprite)
            }
            if let data = draft.sprite, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().interpolation(.none)
                    .scaledToFill().frame(width: 112, height: 112).clipShape(Circle())
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("Bottens figur")
                Button("Fjern figur") { draft.sprite = nil }
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
                Button("Eksportér bot") { exportFile = VillageBotFile(bot: draft); exporting = true }
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
        if let index = updated.firstIndex(where: { $0.id == bot.id }) { updated[index] = bot }
        else {
            guard updated.count < 10 else { notice = "Du kan gemme op til 10 bots."; return false }
            updated.append(bot)
        }
        guard persist(updated) else { return false }
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
            var bot = try JSONDecoder().decode(VillageBot.self, from: data)
            guard !bot.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CocoaError(.fileReadCorruptFile)
            }
            if let original = bot.sprite {
                guard let sprite = VillageSpritePhoto.thumbnail(original) else { throw CocoaError(.fileReadCorruptFile) }
                bot.sprite = sprite
            }
            bot.id = UUID()
            if save(bot) { draft = bot }
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

struct VillageBotAvatar: View {
    let bot: VillageBot
    let size: CGFloat
    let radius: CGFloat
    @Environment(\.fadedPalette) private var palette

    private var tint: Color {
        switch bot.color {
        case "Grøn": palette.green
        case "Lilla": palette.purple
        default: palette.cyan
        }
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: [tint.opacity(0.42), palette.raised], startPoint: .topLeading, endPoint: .bottomTrailing)
            if let data = bot.sprite, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().interpolation(.none).scaledToFill()
            } else {
                Image(systemName: "face.smiling.inverse")
                    .font(.system(size: size * 0.43, weight: .medium)).foregroundStyle(tint)
            }
        }
        .frame(width: size, height: size)
        .clipShape(.rect(cornerRadius: radius))
        .overlay { RoundedRectangle(cornerRadius: radius).strokeBorder(tint.opacity(0.35)) }
        .accessibilityHidden(true)
    }
}

struct VillageBotLibrary: View {
    let api: LiveAPI?
    @Binding var studioUnlocked: Bool
    let onPrivateSessionEnded: () -> Void
    let onBack: () -> Void
    @Environment(\.fadedPalette) private var palette
    private var savedBots: Data { MigratedAppData.shared.villageBots }
    @State private var showBuilder = false
    @State private var editingBot: VillageBot?
    @State private var chattingBot: VillageBot?

    private var bots: [VillageBot] { VillageBot.list(from: savedBots) }

    var body: some View {
        NavigationStack {
            List {
                FadedPrimaryButton("Ny bot", icon: "plus") { showBuilder = true }
                    .disabled(bots.count >= 10)
                    .listRowInsets(rowInsets).listRowSeparator(.hidden).listRowBackground(Color.clear)
                if bots.isEmpty {
                    FadedEmptyState(icon: "person.crop.circle.badge.plus", title: "Du har ingen bots endnu",
                                    detail: "Opret din første bot med et navn, en stemme og en personlighed.")
                        .listRowInsets(rowInsets).listRowSeparator(.hidden).listRowBackground(Color.clear)
                }
                ForEach(bots) { bot in
                    NavigationLink(value: bot.id) {
                        botRow(bot)
                    }
                    .listRowInsets(rowInsets).listRowSeparator(.hidden).listRowBackground(Color.clear)
                    .swipeActions(edge: .leading, allowsFullSwipe: false) {
                        Button { chattingBot = bot } label: { Label("Chat", systemImage: "bubble.left") }.tint(palette.lime)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button { editingBot = bot } label: { Label("Redigér", systemImage: "pencil") }.tint(palette.purple)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background { FadedBackground() }
            .foregroundStyle(palette.text)
            .navigationTitle("Mine bots")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: UUID.self) { botID in
                VillageBotProfile(botID: botID, api: api, studioUnlocked: $studioUnlocked,
                                  onPrivateSessionEnded: onPrivateSessionEnded)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Tilbage", systemImage: "chevron.left", action: onBack)
                }
            }
            .sheet(isPresented: $showBuilder) { VillageBotBuilder(api: api, onBack: { showBuilder = false }) }
            .sheet(item: $editingBot) { bot in
                VillageBotBuilder(api: api, bot: bot, onBack: { editingBot = nil })
            }
            .sheet(item: $chattingBot) { bot in
                OfflineStudio(api: api, sessionUnlocked: $studioUnlocked, onPrivateSessionEnded: onPrivateSessionEnded,
                              initialPage: .chat, initialBotID: bot.id)
            }
        }
    }

    private var rowInsets: EdgeInsets { EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16) }

    private func botRow(_ bot: VillageBot) -> some View {
        FadedCard {
            HStack(alignment: .top, spacing: 12) {
                VillageBotAvatar(bot: bot, size: 56, radius: 12)
                VStack(alignment: .leading, spacing: 4) {
                    Text(bot.name).font(.headline)
                    Text(bot.personality ?? "Nysgerrig").font(.subheadline).foregroundStyle(palette.secondary)
                    Text(bot.voiceQuality)
                        .font(.caption.weight(.semibold)).foregroundStyle(palette.text)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(palette.raised, in: .capsule)
                        .accessibilityLabel("Stemme: \(bot.voiceQuality)")
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        }
    }
}
