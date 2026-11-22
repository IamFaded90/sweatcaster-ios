import SwiftUI

/// The allowance and work belong to one visible chat. Only an actual completed text reply counts.
@MainActor @Observable final class LumiPortraitInitiative {
    private(set) var enabled = false
    private(set) var isPreparing = false
    private(set) var revision = UUID()
    private var turns = 0
    private var attempted = false
    @ObservationIgnored private var job: Task<Void, Never>?

    func interrupt() {
        revision = UUID()
        job?.cancel()
        job = nil
        isPreparing = false
    }

    func setEnabled(_ value: Bool) {
        guard enabled != value else { return }
        interrupt()
        enabled = value
        turns = 0
    }

    func endSession() {
        interrupt()
        enabled = false
        turns = 0
        attempted = false
    }

    @discardableResult
    func completedReply(in turn: UUID, render: @escaping @MainActor () async throws -> Data,
                        publish: @escaping @MainActor (Data) throws -> Void,
                        failure: @escaping @MainActor (Error) -> Void) -> Task<Void, Never>? {
        guard enabled, !attempted, turn == revision else { return nil }
        turns += 1
        guard turns == 2 else { return nil }
        attempted = true
        isPreparing = true
        job = Task { @MainActor in
            defer {
                if revision == turn {
                    isPreparing = false
                    job = nil
                }
            }
            do {
                try Task.checkCancellation()
                let picture = try await render()
                guard !Task.isCancelled, revision == turn else { return }
                try publish(picture)
            } catch {
                if !Task.isCancelled, revision == turn { failure(error) }
            }
        }
        return job
    }
}

extension LumiStudio {
    var inheritedVoice: String {
        VillageBot.list(from: MigratedAppData.shared.villageBots).first { $0.id == VillageBot.lumiID }?.voice ?? "da-DK"
    }

    func stopAudio(cancelDictation: Bool = true) {
        if cancelDictation { dictation.stop() }
        speech.stop()
        christel.stop()
    }

    func renderLumiPicture(api: LiveAPI, model: StudioPCImageModel, prompt: String, reference: Data?,
                           pair: Data? = nil, ephemeral: Bool = false) async throws -> Data {
        if model == .realvis && !ephemeral { return try await api.lumiImage(prompt: prompt, reference: reference) }
        return try await api.privateStudioImage(prompt: prompt, negative: "", reference: reference, mask: nil,
                                                strength: nil, seed: UInt32.random(in: 1...UInt32.max),
                                                engine: model.rawValue, secondReference: pair)
    }

    func chatPicture(_ data: Data, caption: String, language: String) throws -> LumiSceneMessage {
        guard UIImage(data: data) != nil else { throw APIError.malformed }
        let reply = LumiSceneMessage(role: .assistant, text: caption, language: language)
        let file = try writeStudioMedia(data, filename: "Lumi-\(reply.id.uuidString).png")
        sceneMedia.pictures[reply.id] = file
        return reply
    }

    func offerLumiPortrait(after turn: UUID, api: LiveAPI, language: String) {
        guard canReceivePortrait, draft.isEmpty, attachedPhoto == nil, secondChatPhoto == nil,
              case .available = pcImageCatalog, pcImageCatalog.allows(pcImageModel) else { return }
        let model = pcImageModel
        portraits.completedReply(in: turn) {
            guard let reference = LumiChatImageRequest.referencePortrait() else { throw APIError.malformed }
            return try await renderLumiPicture(api: api, model: model, prompt: LumiChatImageRequest.portraitPrompt,
                                               reference: reference, ephemeral: true)
        } publish: { data in
            guard canReceivePortrait, !clearExpiredOpenedScene() else { return }
            let caption = language == "en-US" ? "A little portrait from me." : "Et lille portræt fra mig."
            messages.append(try chatPicture(data, caption: caption, language: language))
        } failure: { error in
            AppDiagnostics.record(error)
            notice = "Lumis portræt kom ikke frem fra PC’en. Du kan bede hende om et nyt i chatten."
        }
    }
}

enum LumiInitiative: String, Codable, CaseIterable, Identifiable {
    case user, together, lumi

    var id: Self { self }
    var title: String {
        switch self {
        case .user: "Jeg styrer"
        case .together: "Sammen"
        case .lumi: "Lumi styrer"
        }
    }
}

enum LumiSceneMood: String, Codable, CaseIterable, Identifiable {
    case playful, romantic, bold

    var id: Self { self }
    var title: String {
        switch self {
        case .playful: "Drilsk flirt"
        case .romantic: "Romantisk"
        case .bold: "Mere fræk"
        }
    }
}

struct LumiSceneCard: Codable, Identifiable, Equatable {
    var id = UUID()
    var title = ""
    var lumiRole = ""
    var userRole = ""
    var setting = ""
    var mood = LumiSceneMood.playful

    var cleaned: Self {
        var card = self
        card.title = Self.field(title, limit: 80)
        card.lumiRole = Self.field(lumiRole, limit: 300)
        card.userRole = Self.field(userRole, limit: 300)
        card.setting = Self.field(setting, limit: 800)
        return card
    }

    private static func field(_ value: String, limit: Int) -> String {
        String(value.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.prefix(limit))
    }

    var wire: [String: String] {
        let card = cleaned
        return ["title": card.title, "lumiRole": card.lumiRole, "userRole": card.userRole,
                "setting": card.setting, "mood": card.mood.rawValue]
    }
}

struct LumiSceneMessage: Codable, Identifiable, Equatable {
    enum Role: String, Codable { case user, assistant }

    var id = UUID()
    let role: Role
    let text: String
    let language: String

    var wire: [String: String] { ["role": role.rawValue, "content": text] }

    private var forChatHistory: Self {
        let limit = 4_000
        let scalars = text.unicodeScalars
        guard scalars.count > limit else { return self }
        let omission = " […] "
        let available = limit - omission.unicodeScalars.count
        let head = available / 2
        let excerpt = String(scalars.prefix(head)) + omission + String(scalars.suffix(available - head))
        return Self(id: id, role: role, text: excerpt, language: language)
    }

    static func chatHistory(_ messages: [Self]) -> [[String: String]] {
        var remaining = 9_000
        var selected: [Self] = []
        for savedMessage in messages.suffix(16).reversed() {
            let message = savedMessage.forChatHistory
            let size = message.text.utf8.count
            if size > remaining {
                if selected.isEmpty && message.role == .assistant { continue }
                break
            }
            selected.append(message)
            remaining -= size
        }
        while selected.last?.role == .assistant { selected.removeLast() }
        return selected.reversed().map(\.wire)
    }
}

struct LumiSavedScene: Codable, Identifiable {
    var id: UUID { card.id }
    let card: LumiSceneCard
    let initiative: LumiInitiative
    let language: String
    let messages: [LumiSceneMessage]
    let draft: String
    let updatedAt: Date
    var expiresAt: Date? = nil

    static func snapshot(card: LumiSceneCard, initiative: LumiInitiative, language: String,
                         messages: [LumiSceneMessage], draft: String, temporarily: Bool = false) -> Self {
        let now = Date.now
        return Self(card: card.cleaned, initiative: initiative, language: language,
                    messages: Array(messages.suffix(16)), draft: String(draft.unicodeScalars.prefix(4_000)), updatedAt: now,
                    expiresAt: temporarily ? now.addingTimeInterval(300) : nil)
    }

    func isExpired(at date: Date) -> Bool { expiresAt.map { $0 <= date } ?? false }

    static func matching(_ query: String, in scenes: [Self], at now: Date = .now) throws -> [UUID] {
        let current = scenes.filter { !$0.isExpired(at: now) }
        let words = String(query.prefix(120)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return current.map(\.id) }
        let texts = try current.map { scene in
            try Task.checkCancellation()
            return (scene.searchFields + scene.messages.map(\.text)).joined(separator: "\n")
        }
        let order = try LocalTextRanking.hybridOrder(query: words, texts: texts, limit: current.count,
                                                     completingLastWord: true) { current[$0].semanticExcerpts }
        return order.map { current[$0].id }
    }

    private var searchFields: [String] {
        [card.title, card.setting, card.lumiRole, card.userRole, card.mood.title, draft]
    }

    // One card and at most four dialogue excerpts per scene. A long draft cannot hide the last exchange.
    var semanticExcerpts: [String] {
        func sample(_ text: String) -> String {
            let scalars = text.unicodeScalars
            let head = scalars.prefix(161)
            if head.count <= 160 { return text }
            return String(head.prefix(80)) + " … " + String(scalars.suffix(80))
        }
        var excerpts = [searchFields.map(sample).joined(separator: "\n")]
        let dialogue = messages.suffix(16)
        for start in stride(from: dialogue.startIndex, to: dialogue.endIndex, by: 4) {
            let end = min(start + 4, dialogue.endIndex)
            excerpts.append(dialogue[start..<end].map { sample($0.text) }.joined(separator: "\n"))
        }
        return excerpts
    }

    func matches(_ other: Self) -> Bool {
        card == other.card && initiative == other.initiative &&
            language == other.language && messages == other.messages && draft == other.draft
    }
}

@MainActor final class LumiSceneLibrary {
    nonisolated static let maximumScenes = 24
    nonisolated static let directoryName = "LumiScenes"
    private static let shared = LumiSceneLibrary(root: URL.applicationSupportDirectory
        .appending(path: directoryName, directoryHint: .isDirectory))
    private let store: LocalFileStore
    private var file: URL { store.root.appending(path: "library.json") }
    private var nextExpiry: Date?
    private var expiryTask: Task<Void, Never>?

    init(root: URL) { store = LocalFileStore(root: root, maximumBytes: 12_000_000) }

    static func load(now: Date = .now) throws -> [LumiSavedScene] {
        try shared.read(now: now)
    }

    static func save(_ scenes: [LumiSavedScene]) throws {
        try shared.write(scenes)
    }

    func read(now: Date = .now) throws -> [LumiSavedScene] {
        do {
            let scenes = try store.read([LumiSavedScene].self, from: file)
            guard scenes.count <= Self.maximumScenes,
                  Set(scenes.map(\.id)).count == scenes.count,
                  scenes.allSatisfy({ !$0.card.title.isEmpty && $0.messages.count <= 16 }) else {
                throw LocalFileStore.Failure.invalidFile
            }
            let current = scenes.filter { !$0.isExpired(at: now) }
            if current.count != scenes.count { try write(current) }
            else { scheduleExpiry(of: current) }
            return current.sorted { $0.updatedAt > $1.updatedAt }
        } catch let error where LocalFileStore.isMissing(error) {
            scheduleExpiry(of: [])
            return []
        }
    }

    func write(_ scenes: [LumiSavedScene]) throws {
        guard scenes.count <= Self.maximumScenes else { throw LocalFileStore.Failure.tooLarge }
        if scenes.isEmpty {
            try store.delete(file)
        } else {
            try FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: true)
            var directory = store.root
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try directory.setResourceValues(values)
            try store.write(scenes, to: file)
        }
        scheduleExpiry(of: scenes)
    }

    private func scheduleExpiry(of scenes: [LumiSavedScene]) {
        let deadline = scenes.compactMap(\.expiresAt).min()
        guard deadline != nextExpiry else { return }
        expiryTask?.cancel()
        expiryTask = nil
        nextExpiry = deadline
        guard let deadline else { return }
        expiryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow))) }
            catch { return }
            guard let self, !Task.isCancelled, nextExpiry == deadline else { return }
            nextExpiry = nil
            expiryTask = nil
            do { _ = try read() }
            catch { AppDiagnostics.record(error) }
        }
    }
}

struct LumiSceneMedia {
    var pictures: [UUID: URL] = [:]
    var sentPhotos: [UUID: Data] = [:]

    mutating func retain(for messages: [LumiSceneMessage], saved scenes: [LumiSavedScene], in root: URL) {
        var keep = Set(messages.map(\.id))
        for scene in scenes { keep.formUnion(scene.messages.map(\.id)) }
        sentPhotos = sentPhotos.filter { keep.contains($0.key) }
        let store = LocalFileStore(root: root)
        for (id, file) in pictures where !keep.contains(id) {
            do {
                try store.delete(file)
                pictures[id] = nil
            } catch { AppDiagnostics.record(error) }
        }
    }
}

extension LumiStudio {
    var nextSceneExpiry: Date? {
        (scenes.map(\.expiresAt) + [openedSceneExpiry]).compactMap { $0 }.min()
    }

    func waitForSceneExpiry() async {
        guard let expiry = nextSceneExpiry else { return }
        while expiry.timeIntervalSinceNow > 0 {
            do { try await Task.sleep(for: .seconds(expiry.timeIntervalSinceNow)) }
            catch { return }
        }
        guard !Task.isCancelled else { return }
        loadScenes()
    }

    func pruneSceneMedia(now: Date = .now) {
        if pendingScene?.isExpired(at: now) == true {
            pendingScene = nil
            confirmSceneSwitch = false
        }
        sceneMedia.retain(for: messages, saved: scenes.filter { !$0.isExpired(at: now) }, in: scratchDirectory)
    }
}

struct LumiSceneCardEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var card: LumiSceneCard
    let actionTitle: String
    let onSave: (LumiSceneCard) -> Void

    init(card: LumiSceneCard, actionTitle: String, onSave: @escaping (LumiSceneCard) -> Void) {
        _card = State(initialValue: card)
        self.actionTitle = actionTitle
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Navn på scenen", text: $card.title)
                    Picker("Stemning", selection: $card.mood) {
                        ForEach(LumiSceneMood.allCases) { mood in
                            Text(mood.title).tag(mood)
                        }
                    }
                }
                Section("Roller og ramme") {
                    TextField("Lumis rolle", text: $card.lumiRole, axis: .vertical)
                        .lineLimit(1...3)
                    TextField("Din rolle", text: $card.userRole, axis: .vertical)
                        .lineLimit(1...3)
                    TextField("Sted og oplæg", text: $card.setting, axis: .vertical)
                        .lineLimit(2...5)
                }
            }
            .scrollContentBackground(.hidden)
            .background { FadedBackground() }
            .navigationTitle("Scenekort")
            .navigationBarTitleDisplayMode(.inline)
            .privacySensitive()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Luk") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(actionTitle) {
                        onSave(card.cleaned)
                        dismiss()
                    }
                    .disabled(card.cleaned.title.isEmpty)
                }
            }
        }
    }
}

struct LumiSceneLibraryView: View {
    @Environment(\.dismiss) private var dismiss
    let scenes: [LumiSavedScene]
    let notice: String?
    let onOpen: (LumiSavedScene) -> Void
    let onRemove: (UUID) -> Void
    let onNew: () -> Void
    @State private var removing: LumiSavedScene?
    @State private var query = ""
    @State private var matchedIDs: [UUID] = []
    @State private var finishedSearch: SearchRequest?

    private struct SearchRequest: Equatable {
        let words: String
        let versions: [UUID: Date]
    }

    private var current: [LumiSavedScene] { scenes.filter { !$0.isExpired(at: .now) } }
    private var request: SearchRequest {
        SearchRequest(words: String(query.prefix(120)).trimmingCharacters(in: .whitespacesAndNewlines),
                      versions: Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0.updatedAt) }))
    }

    private var visibleScenes: [LumiSavedScene] {
        if request.words.isEmpty { return current }
        guard finishedSearch == request else { return [] }
        let byID = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
        return matchedIDs.compactMap { byID[$0] }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button("Ny scene", systemImage: "plus") {
                        onNew()
                        dismiss()
                    }
                    if let notice { Text(notice).foregroundStyle(.secondary) }
                }
                Section("Gemte scener") {
                    if current.isEmpty {
                        Text("Gem en scene i Lumi for at fortsætte den her.").foregroundStyle(.secondary)
                    } else if !request.words.isEmpty {
                        if finishedSearch != request { ProgressView("Søger i dine scener…") }
                        else if visibleScenes.isEmpty { Text("Ingen gemte scener passer til din søgning.").foregroundStyle(.secondary) }
                    }
                    ForEach(visibleScenes) { scene in
                        Button {
                            guard !scene.isExpired(at: .now) else { return }
                            onOpen(scene)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(scene.card.title).font(.headline)
                                Text(scene.card.mood.title + " · " + scene.updatedAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.footnote).foregroundStyle(.secondary)
                                if let expiry = scene.expiresAt {
                                    Text("Slettes \(expiry.formatted(date: .omitted, time: .shortened))")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        }
                        .swipeActions {
                            Button("Slet", systemImage: "trash", role: .destructive) { removing = scene }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background { FadedBackground() }
            .navigationTitle("Lumis scener")
            .searchable(text: $query, prompt: "Søg i titler og samtaler")
            .autocorrectionDisabled()
            .task(id: request) { await search(request) }
            .navigationBarTitleDisplayMode(.inline)
            .privacySensitive()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Luk") { dismiss() } }
            }
            .alert("Slet den gemte scene?", isPresented: Binding(get: { removing != nil },
                                                               set: { if !$0 { removing = nil } }), presenting: removing) { scene in
                Button("Slet", role: .destructive) {
                    onRemove(scene.id)
                    removing = nil
                }
                Button("Annullér", role: .cancel) { removing = nil }
            }
        }
    }

    @MainActor private func search(_ request: SearchRequest) async {
        guard !request.words.isEmpty else { matchedIDs = []; finishedSearch = nil; return }
        do {
            try await Task.sleep(for: .milliseconds(200))
            let available = current
            let task = Task.detached(priority: .userInitiated) { try LumiSavedScene.matching(request.words, in: available) }
            let ids = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try Task.checkCancellation()
            matchedIDs = ids
            finishedSearch = request
        } catch is CancellationError { return }
        catch {
            guard !Task.isCancelled else { return }
            matchedIDs = []
            finishedSearch = request
        }
    }
}
