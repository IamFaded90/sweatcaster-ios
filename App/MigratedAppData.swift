// Migrates six existing defaults values and keeps shared UI data consistent.

import Foundation
import Observation

@MainActor @Observable final class MigratedAppData {
    static let shared = MigratedAppData(legacyStore: LocalModelStore())

    private enum Field: String, CaseIterable {
        case bots = "village_bots"
        case notes
        case turns = "private_turns"
        case draft = "private_draft"
        case previews = "dashboard_previews"
        case context = "code_context"

        var defaultsKey: String {
            switch self {
            case .bots: AppStorageKeys.villageBots
            case .notes: AppStorageKeys.spacesNotes
            case .turns: AppStorageKeys.privateChatTurns
            case .draft: AppStorageKeys.privateChatDraft
            case .previews: AppStorageKeys.dashboardChatPreviews
            case .context: AppStorageKeys.codeActiveContext
            }
        }

        var isText: Bool { self == .notes || self == .draft }

        var maximumBytes: Int {
            switch self {
            case .bots: 256_000
            case .turns: 512_000
            default: 8_388_608
            }
        }
    }

    private let store: LocalModelStore
    private let legacyStore: LocalModelStore?
    private let defaults: UserDefaults
    private var initialized = false
    private var cachedBots = Data()
    private var cachedNotes = ""
    private var cachedPreviews = Data()

    var villageBots: Data {
        migrateUserDefaultsToFilesIfNeeded()
        return cachedBots
    }

    var notes: String {
        migrateUserDefaultsToFilesIfNeeded()
        return cachedNotes
    }

    var dashboardPreviews: Data {
        migrateUserDefaultsToFilesIfNeeded()
        return cachedPreviews
    }

    init(defaults: UserDefaults = .standard,
         store: LocalModelStore = LocalModelStore(root: .applicationSupportDirectory.appending(path: "FadedAI", directoryHint: .isDirectory)),
         legacyStore: LocalModelStore? = nil) {
        self.defaults = defaults
        self.store = store
        if let legacyStore, legacyStore.root.resolvingSymlinksInPath() != store.root.resolvingSymlinksInPath() {
            self.legacyStore = legacyStore
        } else {
            self.legacyStore = nil
        }
    }

    func migrateUserDefaultsToFilesIfNeeded() {
        guard !initialized else { return }
        initialized = true
        for field in Field.allCases {
            do {
                if try storedBytes(field, in: store) != nil {
                    retireLegacy(field)
                } else if let legacy = try previousBytes(field) ?? legacyBytes(field) {
                    try persist(legacy, for: field)
                }
            } catch { AppDiagnostics.record(error) }
        }
        cachedBots = recover(.bots) ?? Data()
        cachedNotes = recover(.notes).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        cachedPreviews = recover(.previews) ?? Data()
    }

    func saveVillageBots(_ data: Data) throws {
        try persist(data, for: .bots)
        cachedBots = data
    }

    func saveNotes(_ text: String) throws {
        try persist(Data(text.utf8), for: .notes)
        cachedNotes = text
    }

    func saveDashboardPreviews(_ data: Data) throws {
        try persist(data, for: .previews)
        cachedPreviews = data
    }

    func regularStudioTurns() -> [PrivateChatTurn] {
        migrateUserDefaultsToFilesIfNeeded()
        guard let data = recover(.turns) else { return [] }
        return (try? JSONDecoder().decode([PrivateChatTurn].self, from: data)) ?? []
    }

    func regularStudioDraft() -> String {
        migrateUserDefaultsToFilesIfNeeded()
        return recover(.draft).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    func saveRegularStudioTurns(_ turns: [PrivateChatTurn]) throws {
        try persist(JSONEncoder().encode(turns.suffix(100)), for: .turns)
    }

    func saveRegularStudioDraft(_ text: String) throws {
        try persist(Data(String(text.prefix(12_000)).utf8), for: .draft)
    }

    func clearRegularStudioDraft() throws {
        try legacyStore?.delete(forKey: Field.draft.rawValue, text: true)
        try store.delete(forKey: Field.draft.rawValue, text: true)
        defaults.removeObject(forKey: Field.draft.defaultsKey)
    }

    func clearRegularStudio() throws {
        try clearRegularStudioDraft()
        try legacyStore?.delete(forKey: Field.turns.rawValue)
        try store.delete(forKey: Field.turns.rawValue)
        defaults.removeObject(forKey: Field.turns.defaultsKey)
    }

    func codeContext() -> [String] {
        migrateUserDefaultsToFilesIfNeeded()
        guard let data = recover(.context) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    func saveCodeContext(_ paths: [String]) throws {
        try persist(JSONEncoder().encode(paths), for: .context)
    }

    func resetCachedValues() {
        initialized = false
        cachedBots = Data()
        cachedNotes = ""
        cachedPreviews = Data()
    }

    private func storedBytes(_ field: Field, in source: LocalModelStore) throws -> Data? {
        let reader = LocalModelStore(root: source.root, maximumBytes: min(source.maximumBytes, field.maximumBytes))
        guard let data = try reader.loadBytes(forKey: field.rawValue, text: field.isText) else { return nil }
        try validate(data, for: field)
        return data
    }

    private func previousBytes(_ field: Field) throws -> Data? {
        guard let legacyStore else { return nil }
        return try storedBytes(field, in: legacyStore)
    }

    private func recover(_ field: Field) -> Data? {
        do {
            if let data = try storedBytes(field, in: store) { return data }
        } catch { AppDiagnostics.record(error) }
        do {
            if let data = try previousBytes(field) { return data }
        } catch { AppDiagnostics.record(error) }
        do {
            guard let data = try legacyBytes(field) else { return nil }
            try validate(data, for: field)
            return data
        }
        catch { AppDiagnostics.record(error); return nil }
    }

    private func legacyBytes(_ field: Field) throws -> Data? {
        guard defaults.object(forKey: field.defaultsKey) != nil else { return nil }
        switch field {
        case .notes, .draft:
            guard let text = defaults.string(forKey: field.defaultsKey) else { throw LocalFileStore.Failure.invalidFile }
            return Data(text.utf8)
        case .context:
            guard let paths = defaults.stringArray(forKey: field.defaultsKey) else { throw LocalFileStore.Failure.invalidFile }
            return try JSONEncoder().encode(paths)
        case .bots, .turns, .previews:
            guard let data = defaults.data(forKey: field.defaultsKey) else { throw LocalFileStore.Failure.invalidFile }
            return data.isEmpty ? Data("[]".utf8) : data
        }
    }

    private func persist(_ data: Data, for field: Field) throws {
        try validate(data, for: field)
        try store.saveBytes(data, forKey: field.rawValue, text: field.isText)
        retireLegacy(field)
    }

    private func retireLegacy(_ field: Field) {
        defaults.removeObject(forKey: field.defaultsKey)
        do { try legacyStore?.delete(forKey: field.rawValue, text: field.isText) }
        catch { AppDiagnostics.record(error) }
    }

    private func validate(_ data: Data, for field: Field) throws {
        guard data.count <= min(store.maximumBytes, field.maximumBytes) else { throw LocalFileStore.Failure.tooLarge }
        let decoder = JSONDecoder()
        switch field {
        case .bots: _ = try decoder.decode([VillageBot].self, from: data)
        case .turns: _ = try decoder.decode([PrivateChatTurn].self, from: data)
        case .previews: _ = try decoder.decode([ChatTurn].self, from: data)
        case .context: _ = try decoder.decode([String].self, from: data)
        case .notes, .draft:
            guard let text = String(data: data, encoding: .utf8) else { throw LocalFileStore.Failure.invalidFile }
            guard text.count <= (field == .notes ? 96_000 : 12_000) else { throw LocalFileStore.Failure.tooLarge }
        }
    }
}
