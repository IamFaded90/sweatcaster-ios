// Saved bot profiles, sprite previews and the bot library.

import AVFoundation
import CoreTransferable
import Foundation
import ImageIO
import PhotosUI
import CryptoKit
import Kingfisher
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct VillageBot: Codable, Identifiable, Equatable {
    static let defaultTraits = ["Rolig", "Nysgerrig", "Tålmodig"]
    static let lumiID = UUID(uuidString: "ecba4ff7-69b2-5a9c-a028-d93ef6ec7983")!

    static func lumi() -> VillageBot {
        VillageBot(id: lumiID, name: "Lumi", color: "Lilla",
                   prompt: "Privat, voksen og flirtende samtale. Forstår dansk, uperfekt engelsk og blandinger.",
                   personality: "Legesyg og flirtende", language: "auto",
                   specialty: "Privat ledsager", responsibility: "Samtale og kreativt studie",
                   traits: ["Varm", "Legesyg", "Direkte"])
    }

    var id: UUID
    var name: String
    var color: String
    var prompt: String
    var voice: String
    var sprite: Data?
    var villageFigure: String
    private(set) var villageFigureWasPicked: Bool
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
         traits: [String] = VillageBot.defaultTraits, bestFriendID: UUID? = nil, dailyMemory: [String] = [], villageFigure: String? = nil) {
        self.id = id
        self.name = name
        self.color = color
        self.prompt = prompt
        self.voice = voice
        self.sprite = sprite
        let validFigure = VillageCharacterCatalog.valid(villageFigure, for: id)
        self.villageFigure = validFigure ?? VillageCharacterCatalog.initial(name: name, id: id.uuidString)
        self.villageFigureWasPicked = validFigure != nil
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

    mutating func chooseVillageFigure(_ figure: String) {
        guard let figure = VillageCharacterCatalog.valid(figure, for: id) else { return }
        villageFigure = figure
        villageFigureWasPicked = true
    }

    mutating func useAvailableVillageFigure(among profiles: [VillageBot]) {
        guard id != Self.lumiID, !villageFigureWasPicked else { return }
        villageFigure = VillageCharacterCatalog.availableDefault(preferred: villageFigure, among: profiles)
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

    var voiceDetails: String { AgentPCVoice(rawValue: voice)?.label ?? playbackVoice.map(LocalSpeechVoice.label) ?? "Systemstemme" }

    var voiceQuality: String { playbackVoice.map(LocalSpeechVoice.qualityLabel) ?? "Systemstemme" }

    func utterance(_ text: String) -> AVSpeechUtterance {
        LocalSpeechVoice.utterance(text, voice: playbackVoice, rate: voiceRate ?? 1)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, color, prompt, voice, sprite, personality, notifications, voiceRate, language
        case specialty, responsibility, traits, bestFriendID, dailyMemory, villageFigure, villageFigureWasPicked
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        color = try container.decode(String.self, forKey: .color)
        prompt = try container.decode(String.self, forKey: .prompt)
        voice = try container.decode(String.self, forKey: .voice)
        sprite = try container.decodeIfPresent(Data.self, forKey: .sprite)
        let savedFigure = VillageCharacterCatalog.valid(try? container.decode(String.self, forKey: .villageFigure), for: id)
        let wasPicked = savedFigure != nil && ((try? container.decode(Bool.self, forKey: .villageFigureWasPicked)) ?? false)
        villageFigureWasPicked = wasPicked
        // Lumi's original default resolved to Eva. Older saves recorded only the figure ID.
        let legacyLumi = id == Self.lumiID && savedFigure == "eva" && !wasPicked
        villageFigure = (legacyLumi ? nil : savedFigure) ?? VillageCharacterCatalog.initial(name: name, id: id.uuidString)
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
        try container.encode(villageFigure, forKey: .villageFigure)
        if villageFigureWasPicked { try container.encode(true, forKey: .villageFigureWasPicked) }
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

struct VillageBotTemplate: Codable {
    let profile: VillageBot
    let phoneModelID: String?
    let phoneModelName: String?
    let pcModelID: String?

    @MainActor init(bot: VillageBot) {
        var copy = bot
        copy.id = UUID()
        if copy.villageFigure == VillageCharacterCatalog.lumi.id {
            copy.villageFigure = VillageCharacterCatalog.initial(name: copy.name, id: copy.id.uuidString)
        }
        copy.dailyMemory = []
        copy.bestFriendID = nil
        copy.sprite = nil
        let defaults = UserDefaults.standard
        if let voice = defaults.string(forKey: PhoneModels.agentVoiceKey(bot.id)), !voice.isEmpty {
            copy.voice = voice
        }
        profile = copy
        phoneModelID = defaults.string(forKey: PhoneModels.agentModelKey(bot.id))
        phoneModelName = phoneModelID.map(PhoneModels.textModelName)
        pcModelID = defaults.string(forKey: PhoneModels.agentPCModelKey(bot.id))
    }
}

struct VillageBotFile: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    static let maximumBytes = 256_000
    let template: VillageBotTemplate

    @MainActor init(bot: VillageBot) { template = VillageBotTemplate(bot: bot) }

    init(configuration: ReadConfiguration) throws {
        let attributes = configuration.file.fileAttributes as NSDictionary
        if let size = attributes[FileAttributeKey.size.rawValue] as? NSNumber, size.int64Value > Int64(Self.maximumBytes) {
            throw CocoaError(.fileReadTooLarge)
        }
        guard let data = configuration.file.regularFileContents, data.count <= Self.maximumBytes else {
            throw CocoaError(.fileReadCorruptFile)
        }
        template = try JSONDecoder().decode(VillageBotTemplate.self, from: data)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: try JSONEncoder().encode(template))
    }
}

struct VillageSpritePhoto: Transferable {
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

@MainActor enum VillageAvatarCache {
    private static let privateCache: ImageCache = {
        let cache = ImageCache(name: "FadedAIAvatarMemory")
        cache.memoryStorage.config.totalCostLimit = 16_000_000
        return cache
    }()

    private static let ordinaryCache: ImageCache = {
        let cache = ImageCache(name: "FadedAIAvatars")
        cache.memoryStorage.config.totalCostLimit = 16_000_000
        cache.diskStorage.config.sizeLimit = 4_000_000
        cache.diskStorage.config.expiration = .days(7)
        cache.cleanExpiredDiskCache(completion: nil)
        return cache
    }()

    static func cache(for id: UUID) -> ImageCache {
        id == VillageBot.lumiID ? privateCache : ordinaryCache
    }

    static func key(id: UUID, data: Data) -> String {
        id.uuidString + ":" + SHA256.hash(data: data).description
    }

    static func storeCurrentAvatar(_ image: UIImage, id: UUID, data: Data, key: String) {
        guard id != VillageBot.lumiID,
              VillageBot.list(from: MigratedAppData.shared.villageBots).contains(where: { $0.id == id && $0.sprite == data })
        else { return }
        let options = KingfisherParsedOptionsInfo([.diskStoreWriteOptions([.atomic, .completeFileProtection])])
        ordinaryCache.store(image, original: data, forKey: key, options: options)
        ordinaryCache.cleanExpiredDiskCache(completion: nil)
    }

    static func discardChanged(from previous: [VillageBot], keeping current: [VillageBot]) {
        let currentKeys = Set(current.compactMap { bot in bot.sprite.map { key(id: bot.id, data: $0) } })
        for bot in previous {
            guard let data = bot.sprite else { continue }
            let oldKey = key(id: bot.id, data: data)
            if !currentKeys.contains(oldKey) {
                cache(for: bot.id).removeImage(forKey: oldKey, fromDisk: bot.id != VillageBot.lumiID, completionHandler: nil)
            }
        }
    }

    static func clear() {
        privateCache.clearMemoryCache()
        ordinaryCache.clearCache()
    }
}

@MainActor struct VillageBotAvatar: View {
    let bot: VillageBot
    let size: CGFloat
    let radius: CGFloat
    @Environment(\.fadedPalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
            if let data = bot.sprite {
                let cacheKey = VillageAvatarCache.key(id: bot.id, data: data)
                let source = RawImageDataProvider(data: data, cacheKey: cacheKey)
                KFImage(source: .provider(source))
                    .targetCache(VillageAvatarCache.cache(for: bot.id))
                    .cacheMemoryOnly()
                    .onSuccess { result in
                        // Keep stale views from writing to disk after a portrait has changed or been deleted.
                        guard case .none = result.cacheType, bot.id != VillageBot.lumiID else { return }
                        let id = bot.id
                        Task { @MainActor in
                            VillageAvatarCache.storeCurrentAvatar(result.image, id: id, data: data, key: cacheKey)
                        }
                    }
                    .cancelOnDisappear(true)
                    .fade(duration: reduceMotion ? 0 : 0.15)
                    .placeholder { placeholder }
                    .onFailureView { placeholder }
                    .resizable()
                    .scaledToFill()
                    .id(cacheKey)
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(.rect(cornerRadius: radius))
        .overlay { RoundedRectangle(cornerRadius: radius).strokeBorder(tint.opacity(0.35)) }
        .accessibilityHidden(true)
    }

    private var placeholder: some View {
        Group {
            if let name = VillagePortraitIdentity.name(for: bot), let image = VillageProductionArt.portrait(name) {
                Image(uiImage: image).resizable().scaledToFill()
            } else if let image = VillageProductionArt.frame(character: bot.villageFigure, direction: 0, step: 0) {
                Image(uiImage: image).resizable().interpolation(.none).scaledToFit()
            } else {
                Image(systemName: "face.smiling.inverse")
                    .font(.system(size: size * 0.43, weight: .medium)).foregroundStyle(tint)
            }
        }
    }
}

@MainActor struct VillageBotLibrary: View {
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
                if !bots.contains(where: { $0.id == VillageBot.lumiID }) {
                    FadedSecondaryButton("Tilføj Lumi · 18+", icon: "sparkles") { addLumi() }
                        .disabled(bots.count >= 10)
                        .listRowInsets(rowInsets).listRowSeparator(.hidden).listRowBackground(Color.clear)
                }
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
                if bot.id == VillageBot.lumiID {
                    LumiStudio(api: api)
                } else {
                    OfflineStudio(api: api, sessionUnlocked: $studioUnlocked, onPrivateSessionEnded: onPrivateSessionEnded,
                                  initialPage: .chat, initialBotID: bot.id)
                }
            }
        }
    }

    private var rowInsets: EdgeInsets { EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16) }

    private func addLumi() {
        var updated = bots
        guard updated.count < 10, !updated.contains(where: { $0.id == VillageBot.lumiID }) else { return }
        updated.append(.lumi())
        do {
            try MigratedAppData.shared.saveVillageBots(JSONEncoder().encode(updated))
            if let lumi = updated.last { VillageHistory.shared.created(lumi) }
        }
        catch { AppDiagnostics.record(error) }
    }

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
