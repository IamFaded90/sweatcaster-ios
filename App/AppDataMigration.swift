// Migrates six existing defaults values and keeps shared UI data consistent.

import Foundation
import Observation

@MainActor @Observable final class MigratedAppData {
    static let shared = MigratedAppData()

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
    }

    private let store: LocalModelStore
    private let defaults: UserDefaults
    private var initialized = false
    private(set) var villageBots = Data()
    private(set) var notes = ""
    private(set) var dashboardPreviews = Data()

    init(defaults: UserDefaults = .standard, store: LocalModelStore = LocalModelStore()) {
        self.defaults = defaults
        self.store = store
    }

    func migrateUserDefaultsToFilesIfNeeded() {
        guard !initialized else { return }
        initialized = true
        for field in Field.allCases where defaults.object(forKey: field.defaultsKey) != nil {
            do {
                if let current = try storedBytes(field) {
                    try validate(current, for: field)
                    try store.protectBackup(forKey: field.rawValue, text: field.isText)
                } else if let legacy = try legacyBytes(field) {
                    try persist(legacy, for: field)
                }
                defaults.removeObject(forKey: field.defaultsKey)
            } catch { AppDiagnostics.record(error) }
        }
        villageBots = recover(.bots) ?? Data()
        notes = recover(.notes).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        dashboardPreviews = recover(.previews) ?? Data()
    }

    func saveVillageBots(_ data: Data) throws {
        try persist(data, for: .bots)
        villageBots = data
    }

    func saveNotes(_ text: String) throws {
        try persist(Data(text.utf8), for: .notes)
        notes = text
    }

    func saveDashboardPreviews(_ data: Data) throws {
        try persist(data, for: .previews)
        dashboardPreviews = data
    }

    func regularStudioTurns() -> [PrivateChatTurn] {
        guard let data = recover(.turns) else { return [] }
        return (try? JSONDecoder().decode([PrivateChatTurn].self, from: data)) ?? []
    }

    func regularStudioDraft() -> String {
        recover(.draft).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    func saveRegularStudioTurns(_ turns: [PrivateChatTurn]) throws {
        try persist(JSONEncoder().encode(turns.suffix(100)), for: .turns)
    }

    func saveRegularStudioDraft(_ text: String) throws {
        try persist(Data(String(text.prefix(12_000)).utf8), for: .draft)
    }

    func clearRegularStudioDraft() throws {
        try store.delete(forKey: Field.draft.rawValue, text: true)
        defaults.removeObject(forKey: Field.draft.defaultsKey)
    }

    func clearRegularStudio() throws {
        try clearRegularStudioDraft()
        try store.delete(forKey: Field.turns.rawValue)
        defaults.removeObject(forKey: Field.turns.defaultsKey)
    }

    func codeContext() -> [String] {
        guard let data = recover(.context) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    func saveCodeContext(_ paths: [String]) throws {
        try persist(JSONEncoder().encode(paths), for: .context)
    }

    func resetCachedValues() {
        initialized = false
        villageBots = Data()
        notes = ""
        dashboardPreviews = Data()
    }

    private func storedBytes(_ field: Field) throws -> Data? {
        try store.loadBytes(forKey: field.rawValue, text: field.isText)
    }

    private func recover(_ field: Field) -> Data? {
        do {
            if let bytes = try storedBytes(field) {
                try validate(bytes, for: field)
                return bytes
            }
        } catch { AppDiagnostics.record(error) }
        do { return try legacyBytes(field) }
        catch { AppDiagnostics.record(error); return nil }
    }

    private func legacyBytes(_ field: Field) throws -> Data? {
        guard defaults.object(forKey: field.defaultsKey) != nil else { return nil }
        switch field {
        case .notes, .draft:
            guard let text = defaults.string(forKey: field.defaultsKey) else { throw LocalFileStore.Failure.invalidFile }
            return Data((field == .draft ? String(text.prefix(12_000)) : text).utf8)
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
        defaults.removeObject(forKey: field.defaultsKey)
    }

    private func validate(_ data: Data, for field: Field) throws {
        guard data.count <= store.maximumBytes else { throw LocalFileStore.Failure.tooLarge }
        let decoder = JSONDecoder()
        switch field {
        case .bots: _ = try decoder.decode([VillageBot].self, from: data)
        case .turns: _ = try decoder.decode([PrivateChatTurn].self, from: data)
        case .previews: _ = try decoder.decode([ChatTurn].self, from: data)
        case .context: _ = try decoder.decode([String].self, from: data)
        case .notes, .draft:
            guard let text = String(data: data, encoding: .utf8),
                  field != .draft || text.count <= 12_000 else { throw LocalFileStore.Failure.invalidFile }
        }
    }
}
