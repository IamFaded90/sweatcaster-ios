import SwiftUI

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

    func matches(_ other: Self) -> Bool {
        card == other.card && initiative == other.initiative &&
            language == other.language && messages == other.messages && draft == other.draft
    }
}

enum LumiSceneLibrary {
    static let maximumScenes = 24
    static let directoryName = "LumiScenes"
    private static var root: URL {
        URL.applicationSupportDirectory.appending(path: directoryName, directoryHint: .isDirectory)
    }
    private static var file: URL { root.appending(path: "library.json") }
    private static var store: LocalFileStore { LocalFileStore(root: root, maximumBytes: 12_000_000) }

    static func load(now: Date = .now) throws -> [LumiSavedScene] {
        do {
            let scenes = try store.read([LumiSavedScene].self, from: file)
            guard scenes.count <= maximumScenes,
                  Set(scenes.map(\.id)).count == scenes.count,
                  scenes.allSatisfy({ !$0.card.title.isEmpty && $0.messages.count <= 16 }) else {
                throw LocalFileStore.Failure.invalidFile
            }
            let current = scenes.filter { !$0.isExpired(at: now) }
            if current.count != scenes.count { try save(current) }
            return current.sorted { $0.updatedAt > $1.updatedAt }
        } catch let error where LocalFileStore.isMissing(error) {
            return []
        }
    }

    static func save(_ scenes: [LumiSavedScene]) throws {
        guard scenes.count <= maximumScenes else { throw LocalFileStore.Failure.tooLarge }
        if scenes.isEmpty {
            try store.delete(file)
            return
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var directory = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        try store.write(scenes, to: file)
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
                    if scenes.isEmpty {
                        Text("Gem en scene i Lumi for at fortsætte den her.").foregroundStyle(.secondary)
                    }
                    ForEach(scenes) { scene in
                        Button {
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
}
