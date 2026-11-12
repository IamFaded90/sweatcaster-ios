// Explicit version-1 export and guarded restore of regular app data.

import Foundation

@MainActor final class BackupService {
    static let shared = BackupService()
    static let exportDirectory = "FadedAI-Backups"

    enum Mode: Equatable { case merge, replace }

    enum Failure: LocalizedError {
        case unsupportedVersion, invalidData, tooLarge, busy, rollbackFailed

        var errorDescription: String? {
            switch self {
            case .unsupportedVersion: "Backup-versionen understøttes ikke. Vælg en FadedAI-backup i version 1."
            case .invalidData: "Backupen indeholder ugyldige data. Vælg en intakt FadedAI-backup."
            case .tooLarge: "Data overskrider appens lagergrænser. Prøv en mindre backup, eller ryd plads i de relevante lister."
            case .busy: "En lokal AI-opgave kører. Stop den, og prøv igen."
            case .rollbackFailed: "Gendannelsen blev afbrudt, og nogle data kunne ikke rulles tilbage. Brug din backup til at gendanne igen."
            }
        }
    }

    private struct Snapshot: Codable {
        let version: Int
        let createdAt: Date
        var sessions: [SavedAgentSession]
        var drafts: [String: String]
        var notes: String
        var bots: [VillageBot]
        var preferences: [String: Preference]
        var videoOutbox: [String: [VideoOutboxItem]]
    }

    private enum Preference: Codable {
        case flag(Bool), text(String), number(Double)
    }

    private enum PreferenceKind { case flag, text, scale }

    private struct Change {
        let apply: () throws -> Void
        let undo: () throws -> Void
    }

    private let defaults = UserDefaults.standard
    private let data = MigratedAppData.shared
    private let videoDirectory = URL.applicationSupportDirectory.appending(path: "VideoStudio", directoryHint: .isDirectory)
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private static let preferenceKinds: [String: PreferenceKind] = {
        let flags = [
            AppStorageKeys.aiActions, AppStorageKeys.aiAssumptions, AppStorageKeys.aiBullets,
            AppStorageKeys.aiClarify, AppStorageKeys.aiCodeComments,
            AppStorageKeys.aiCounterpoint, AppStorageKeys.aiEmojis, AppStorageKeys.aiExamples,
            AppStorageKeys.aiHeadings, AppStorageKeys.aiNoJargon, AppStorageKeys.aiPreserveNames,
            AppStorageKeys.aiProsCons, AppStorageKeys.aiRecapQuestion, AppStorageKeys.aiRisks,
            AppStorageKeys.aiShowTools, AppStorageKeys.aiSimple, AppStorageKeys.aiSources,
            AppStorageKeys.aiSteps, AppStorageKeys.aiSuggestions, AppStorageKeys.aiSummary,
            AppStorageKeys.aiTables, AppStorageKeys.aiTimestamps, AppStorageKeys.aiUncertainty, AppStorageKeys.aiWordCount,
            AppStorageKeys.appFollowSystemAppearance, AppStorageKeys.appManualDarkMode,
            AppStorageKeys.chatAutoModelRouter, AppStorageKeys.chatVoiceMode,
            AppStorageKeys.liveActivityEnabled, AppStorageKeys.notificationsEnabledCode,
            AppStorageKeys.notificationsEnabledImageModel, AppStorageKeys.notificationsEnabledVideo,
            AppStorageKeys.notificationsEnabledVideoFailed, AppStorageKeys.phoneModelLiteBattery,
            AppStorageKeys.qolAutoRefreshTabs, AppStorageKeys.qolCompactClips, AppStorageKeys.qolConfirmVideo,
            AppStorageKeys.qolConnectionBanner, AppStorageKeys.qolHaptics, AppStorageKeys.qolJobDetails,
            AppStorageKeys.qolKeepAwake, AppStorageKeys.qolReduceMotion, AppStorageKeys.qolRememberSpace,
            AppStorageKeys.qolShowDurations, AppStorageKeys.spacesMotion, AppStorageKeys.spacesOnboarded,
            AppStorageKeys.teamActiveExpanded, AppStorageKeys.teamFavoritesExpanded,
            AppStorageKeys.teamSleepingExpanded, AppStorageKeys.villageShowOffice
        ]
        let strings = [
            AppStorageKeys.aiCreativity, AppStorageKeys.aiLanguage, AppStorageKeys.aiLength, AppStorageKeys.aiTone,
            AppStorageKeys.appearanceMode, AppStorageKeys.appearanceTheme, AppStorageKeys.appearanceLookPreset,
            AppStorageKeys.chatVoiceIdentifier,
            AppStorageKeys.chatVoiceLanguage, AppStorageKeys.chatVoiceBot, AppStorageKeys.codeAutonomy,
            AppStorageKeys.phoneModel, AppStorageKeys.phoneModelFavorites, AppStorageKeys.qolLastSpace,
            AppStorageKeys.spacesFont, AppStorageKeys.teamFavorites, AppStorageKeys.videoLastMood
        ]
        var kinds = Dictionary(uniqueKeysWithValues: flags.map { ($0, PreferenceKind.flag) })
        for key in strings { kinds[key] = .text }
        kinds[AppStorageKeys.appTextScale] = .scale
        return kinds
    }()

    private init() {}

    func createBackup() throws -> URL {
        var snapshot = try currentSnapshot()
        snapshot.videoOutbox = snapshot.videoOutbox.mapValues { $0.map(withoutPairingFingerprint) }
        try validate(snapshot)
        let archive = try BackupArchive.encode(encoder.encode(snapshot))
        let root = FileManager.default.temporaryDirectory.appending(path: Self.exportDirectory, directoryHint: .isDirectory)
        let url = root.appending(path: UUID().uuidString, directoryHint: .isDirectory)
            .appending(path: "FadedAI-backup.zip", directoryHint: .notDirectory)
        try LocalFileStore.writeBytes(archive, to: url, within: root)
        return url
    }

    func restoreBackup(from url: URL, mode: Mode) throws {
        try restoreBackup(archive: Self.readArchive(from: url), mode: mode)
    }

    nonisolated static func readArchive(from url: URL) throws -> Data {
        let hasScope = url.startAccessingSecurityScopedResource()
        defer { if hasScope { url.stopAccessingSecurityScopedResource() } }
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var result: Result<Data, Error>?
        coordinator.coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError) { readableURL in
            result = Result { try LocalFileStore.readBytes(from: readableURL, maximumBytes: BackupArchive.maximumArchiveBytes) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw Failure.invalidData }
        return try result.get()
    }

    func restoreBackup(archive raw: Data, mode: Mode) throws {
        guard !LocalCompute.isRunning else { throw Failure.busy }
        let payload = try BackupArchive.decode(raw)
        let version = try decoder.decode(VersionProbe.self, from: payload).version
        guard version == 1 else { throw Failure.unsupportedVersion }
        let incoming = try decoder.decode(Snapshot.self, from: payload)
        try validate(incoming)
        let existing = try currentSnapshot()
        let restored = restoredSnapshot(incoming, over: existing, mode: mode)
        try validate(restored)

        var changes = try chatChanges(restored, mode: mode)
        let oldArchive = data.chatArchive()
        let oldBots = data.villageBots.isEmpty ? Data("[]".utf8) : data.villageBots
        let oldNotes = data.notes
        let oldPreviews = data.dashboardPreviews.isEmpty ? Data("[]".utf8) : data.dashboardPreviews
        let botBytes = try encoder.encode(restored.bots)
        changes += [
            Change(apply: { try self.data.saveChatArchive(restored.sessions) }, undo: { try self.data.saveChatArchive(oldArchive) }),
            Change(apply: { try self.data.saveVillageBots(botBytes) }, undo: { try self.data.saveVillageBots(oldBots) }),
            Change(apply: { try self.data.saveNotes(restored.notes) }, undo: { try self.data.saveNotes(oldNotes) }),
            Change(apply: { try self.data.saveDashboardPreviews(Data("[]".utf8)) },
                   undo: { try self.data.saveDashboardPreviews(oldPreviews) })
        ]
        changes += try videoChanges(restored: restored.videoOutbox, previous: existing.videoOutbox)
        try apply(changes)
        for key in Self.preferenceKinds.keys {
            setPreference(restored.preferences[key], for: key)
        }
    }

    private struct VersionProbe: Decodable { let version: Int }

    private func currentSnapshot() throws -> Snapshot {
        var sessions = ChatArchive.sessions()
        var drafts: [String: String] = [:]
        for session in sessions {
            let draft = data.chatDraft(AppStorageKeys.chatSession(session.id.uuidString))
            if !draft.isEmpty { drafts[session.id.uuidString] = draft }
        }
        for key in chatSlotKeys() {
            let suffix = String(key.dropFirst(AppStorageKeys.chatSessionPrefix.count))
            guard UUID(uuidString: suffix) == nil, suffix != "demo" else { continue }
            let draft = data.chatDraft(key)
            guard !draft.isEmpty else { continue }
            let session = data.chatSession(key).flatMap(ChatArchive.decodeSession)
                ?? SavedAgentSession(id: UUID(), turns: [], toolSteps: [], pending: false)
            drafts[session.id.uuidString] = draft
            if !sessions.contains(where: { $0.id == session.id }) { sessions.append(session) }
        }
        let botsData = data.villageBots
        let bots = botsData.isEmpty ? [] : try decoder.decode([VillageBot].self, from: botsData)
        var queue: [String: [VideoOutboxItem]] = [:]
        for address in try videoAddresses() {
            let saved = try readVideoState(address).state.outbox
            if !saved.isEmpty { queue[address] = saved }
        }
        return Snapshot(version: 1, createdAt: .now, sessions: sessions, drafts: drafts,
                        notes: data.notes, bots: bots, preferences: readPreferences(), videoOutbox: queue)
    }

    private func restoredSnapshot(_ incoming: Snapshot, over local: Snapshot, mode: Mode) -> Snapshot {
        var result = incoming
        // Restored work can already have reached the PC, even when the archive called it waiting.
        result.videoOutbox = incoming.videoOutbox.mapValues { items in
            items.map { item in
                var copy = withoutPairingFingerprint(item)
                copy.state = .rejected
                copy.message = "Gendannet fra backup. Tjek joblisten, før du opretter et nyt job."
                return copy
            }
        }
        if mode == .merge {
            result.sessions = merge(local.sessions, result.sessions, by: \.id)
            result.drafts.merge(local.drafts) { _, current in current }
            if !local.notes.isEmpty {
                result.notes = incoming.notes.isEmpty || incoming.notes == local.notes
                    ? local.notes : local.notes + "\n\n---\n\n" + incoming.notes
            }
            result.bots = merge(local.bots, result.bots, by: \.id)
            result.preferences.merge(local.preferences) { _, current in current }
            for (address, items) in local.videoOutbox {
                result.videoOutbox[address] = merge(items, result.videoOutbox[address, default: []], by: \.id)
            }
        }
        return result
    }

    private func withoutPairingFingerprint(_ item: VideoOutboxItem) -> VideoOutboxItem {
        VideoOutboxItem(id: item.id, createdAt: item.createdAt, batch: item.batch, clips: item.clips,
                        targetID: nil, state: item.state, message: item.message)
    }

    private func merge<Item>(_ existing: [Item], _ incoming: [Item], by id: KeyPath<Item, UUID>) -> [Item] {
        var seen = Set(existing.map { $0[keyPath: id] })
        return existing + incoming.filter { seen.insert($0[keyPath: id]).inserted }
    }

    private func validate(_ snapshot: Snapshot) throws {
        guard snapshot.version == 1 else { throw Failure.unsupportedVersion }
        guard snapshot.sessions.count <= 100, snapshot.bots.count <= 10, snapshot.notes.count <= 96_000,
              snapshot.videoOutbox.count <= 8, snapshot.drafts.count <= 100,
              try encoder.encode(snapshot.bots).count <= 256_000,
              try encoder.encode(snapshot.sessions).count <= 8_388_608 else { throw Failure.tooLarge }
        let sessionIDs = Set(snapshot.sessions.map { $0.id.uuidString })
        guard sessionIDs.count == snapshot.sessions.count,
              Set(snapshot.bots.map(\.id)).count == snapshot.bots.count,
              snapshot.drafts.allSatisfy({ sessionIDs.contains($0.key) && $0.value.count <= 12_000 }),
              snapshot.preferences.allSatisfy({ validPreference($0.value, for: $0.key) }) else { throw Failure.invalidData }
        for session in snapshot.sessions {
            guard Set(session.turns.map(\.id)).count == session.turns.count else { throw Failure.invalidData }
        }
        for (address, items) in snapshot.videoOutbox {
            guard canonicalAddress(address), items.count <= 5,
                  Set(items.map(\.id)).count == items.count else { throw Failure.invalidData }
            for item in items {
                try item.batch.validate(limit: 10)
                guard item.batch.clip_ids == item.clips.map({ $0.clip.id }),
                      item.targetID.map(validTargetID) ?? true,
                      item.clips.allSatisfy({ $0.clip.duration_seconds.isFinite && $0.clip.duration_seconds >= 0 }) else {
                    throw Failure.invalidData
                }
            }
        }
    }

    private func chatChanges(_ snapshot: Snapshot, mode: Mode) throws -> [Change] {
        var changes: [Change] = []
        let importedDrafts = Dictionary(uniqueKeysWithValues: snapshot.drafts.map { (AppStorageKeys.chatSession($0.key), $0.value) })
        let current = mode == .replace ? chatSlotKeys() : []
        for key in Set(current).union(importedDrafts.keys).sorted() {
            let oldDraft = data.chatDraft(key)
            let newDraft = importedDrafts[key] ?? (mode == .replace ? "" : oldDraft)
            if oldDraft != newDraft {
                changes.append(Change(apply: { try self.data.saveChatDraft(newDraft, sessionKey: key) },
                                      undo: { try self.data.saveChatDraft(oldDraft, sessionKey: key) }))
            }
            if mode == .replace, let oldSession = data.chatSession(key) {
                let empty = SavedAgentSession(id: UUID(), turns: [], toolSteps: [], pending: false)
                let blank = try encoder.encode(empty)
                changes.append(Change(apply: { try self.data.saveChatSession(blank, sessionKey: key) },
                                      undo: { try self.data.saveChatSession(oldSession, sessionKey: key) }))
            }
        }
        return changes
    }

    private func chatSlotKeys() -> [String] {
        let prefix = AppStorageKeys.chatSessionPrefix
        let discovered = defaults.dictionaryRepresentation().keys.compactMap { key -> String? in
            guard key.hasPrefix(prefix), key != AppStorageKeys.spacesChatArchiveV1 else { return nil }
            let slot = key.hasSuffix(".draft") ? String(key.dropLast(".draft".count)) : key
            let suffix = String(slot.dropFirst(prefix.count))
            return suffix == "offline" || UUID(uuidString: suffix) != nil || canonicalAddress(suffix) ? slot : nil
        }
        let known = (pairedAddresses() + ["offline"]).map(AppStorageKeys.chatSession)
        let archived = data.chatArchive().map { AppStorageKeys.chatSession($0.id.uuidString) }
        return Array(Set(discovered + known + archived)).sorted()
    }

    private func pairedAddresses() -> [String] {
        let keys = [Pairing.addressKey] + ConnectionProfile.allCases.map(\.storageKey)
        return Array(Set(keys.compactMap { defaults.string(forKey: $0) }.filter(canonicalAddress))).sorted()
    }

    private func canonicalAddress(_ value: String) -> Bool {
        (try? Server(value))?.address == value
    }

    private func validTargetID(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private func videoAddresses() throws -> [String] {
        let manager = FileManager.default
        let children: [URL]
        do { children = try manager.contentsOfDirectory(at: videoDirectory, includingPropertiesForKeys: nil) }
        catch let error where LocalFileStore.isMissing(error) { return pairedAddresses() }
        return Set(pairedAddresses() + children.compactMap { url in
            guard url.pathExtension == "json" else { return nil }
            let address = url.deletingPathExtension().lastPathComponent
            return canonicalAddress(address) ? address : nil
        }).sorted()
    }

    private func readVideoState(_ address: String) throws -> (file: URL, bytes: Data?, state: VideoStudioState) {
        guard canonicalAddress(address) else { throw Failure.invalidData }
        let file = videoDirectory.appending(path: address + ".json", directoryHint: .notDirectory)
        let safe = try LocalFileStore.safeWriteURL(file, within: videoDirectory)
        do {
            let bytes = try LocalFileStore.readBytes(from: safe, maximumBytes: 512_000)
            return (safe, bytes, try decoder.decode(VideoStudioState.self, from: bytes))
        } catch let error where LocalFileStore.isMissing(error) {
            return (safe, nil, VideoStudioState())
        }
    }

    private func videoChanges(restored: [String: [VideoOutboxItem]], previous: [String: [VideoOutboxItem]]) throws -> [Change] {
        try Set(restored.keys).union(previous.keys).sorted().map { address in
            let original = try readVideoState(address)
            var state = original.state
            state.outbox = restored[address, default: []]
            let bytes = try encoder.encode(state)
            guard bytes.count <= 512_000 else { throw Failure.tooLarge }
            return Change(apply: {
                try LocalFileStore.writeBytes(bytes, to: original.file, within: self.videoDirectory)
                var folder = self.videoDirectory
                var attributes = URLResourceValues()
                attributes.isExcludedFromBackup = true
                try folder.setResourceValues(attributes)
            }, undo: {
                if let previous = original.bytes {
                    try LocalFileStore.writeBytes(previous, to: original.file, within: self.videoDirectory)
                } else {
                    try LocalFileStore(root: self.videoDirectory).delete(original.file)
                }
            })
        }
    }

    private func readPreferences() -> [String: Preference] {
        var result: [String: Preference] = [:]
        for (key, kind) in Self.preferenceKinds where defaults.object(forKey: key) != nil {
            let value: Preference? = switch kind {
            case .flag: .flag(defaults.bool(forKey: key))
            case .text: defaults.string(forKey: key).map(Preference.text)
            case .scale: .number(defaults.double(forKey: key))
            }
            if let value, validPreference(value, for: key) { result[key] = value }
        }
        return result
    }

    private func validPreference(_ value: Preference, for key: String) -> Bool {
        switch (Self.preferenceKinds[key], value) {
        case (.flag?, .flag): return true
        case (.scale?, .number(let number)): return number.isFinite && (0...5).contains(number)
        case (.text?, .text(let value)): return value.utf8.count <= 1_024
        default: return false
        }
    }

    private func setPreference(_ value: Preference?, for key: String) {
        switch value {
        case .flag(let flag)?: defaults.set(flag, forKey: key)
        case .text(let text)?: defaults.set(text, forKey: key)
        case .number(let number)?: defaults.set(number, forKey: key)
        case nil: defaults.removeObject(forKey: key)
        }
    }

    private func apply(_ changes: [Change]) throws {
        var attempted: [Change] = []
        do {
            for change in changes {
                attempted.append(change)
                try change.apply()
            }
        } catch {
            var rollbackFailed = false
            for change in attempted.reversed() {
                do { try change.undo() }
                catch { AppDiagnostics.record(error); rollbackFailed = true }
            }
            if rollbackFailed { throw Failure.rollbackFailed }
            throw error
        }
    }
}
