import Foundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct TeamBotNotebookStore {
    struct Memory: Codable, Identifiable, Equatable {
        let id: UUID
        let title: String
        let text: String
    }

    struct Skill: Codable, Identifiable, Equatable {
        let id: UUID
        let title: String
        let steps: [String]
        let sop: String?

        var prompt: String {
            let list = steps.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
            var sections = [title, list]
            if let sop { sections.append("SOP:\n" + sop) }
            return sections.joined(separator: "\n\n")
        }
    }

    enum Failure: LocalizedError {
        case invalid, full, unreadable

        var errorDescription: String? {
            switch self {
            case .invalid: "Tjek titlen og længden, før du gemmer."
            case .full: "Bottens mappe er fuld. Slet en post, og prøv igen."
            case .unreadable: "FadedAI kunne ikke læse eller skrive bottens lokale mappe."
            }
        }
    }

    private enum Kind: String { case memory = "Memory", skill = "Skills" }
    private let support: URL
    private let botID: UUID

    init(botID: UUID, support: URL = .applicationSupportDirectory) {
        self.botID = botID
        self.support = support
    }

    func memories() throws -> [Memory] { try records(.memory) }
    func skills() throws -> [Skill] { try records(.skill) }

    func save(_ memory: Memory) throws {
        let title = clean(memory.title)
        let text = clean(memory.text)
        guard valid(title, upTo: 80), valid(text, upTo: 3_000) else { throw Failure.invalid }
        try save(Memory(id: memory.id, title: title, text: text), kind: .memory)
    }

    func save(_ skill: Skill) throws {
        let title = clean(skill.title)
        let steps = skill.steps.map(clean).filter { !$0.isEmpty }
        let sop = skill.sop.map(clean).flatMap { $0.isEmpty ? nil : $0 }
        guard valid(title, upTo: 80), (1...12).contains(steps.count),
              steps.allSatisfy({ valid($0, upTo: 500) }),
              sop.map({ $0.utf8.count <= 16_384 && !$0.contains("\0") }) ?? true else { throw Failure.invalid }
        try save(Skill(id: skill.id, title: title, steps: steps, sop: sop), kind: .skill)
    }

    func deleteMemory(_ id: UUID) throws { try remove(id, kind: .memory) }
    func deleteSkill(_ id: UUID) throws { try remove(id, kind: .skill) }

    static func readSOP(_ url: URL) throws -> String {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let data = try LocalFileStore.readBytes(from: url, maximumBytes: 16_384)
        guard var text = String(data: data, encoding: .utf8), !text.contains("\0") else { throw Failure.invalid }
        if text.first == "\u{FEFF}" { text.removeFirst() }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw Failure.invalid }
        return text
    }

    private func clean(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func valid(_ text: String, upTo limit: Int) -> Bool {
        !text.isEmpty && text.unicodeScalars.count <= limit && !text.contains("\0")
    }

    private func directory(_ kind: Kind, create: Bool) throws -> URL? {
        let manager = FileManager.default
        if !manager.fileExists(atPath: support.path) {
            guard create else { return nil }
            try manager.createDirectory(at: support, withIntermediateDirectories: true)
        }
        var folder = support.resolvingSymlinksInPath()
        for component in ["FadedAI", "Bots", botID.uuidString, kind.rawValue] {
            folder.append(path: component, directoryHint: .isDirectory)
            if !manager.fileExists(atPath: folder.path) {
                guard create else { return nil }
                try manager.createDirectory(at: folder, withIntermediateDirectories: false)
            }
            let values = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { throw Failure.unreadable }
        }
        if create {
            var properties = URLResourceValues()
            properties.isExcludedFromBackup = true
            try folder.setResourceValues(properties)
        }
        return folder
    }

    private func files(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
            .filter { $0.pathExtension == "json" && UUID(uuidString: $0.deletingPathExtension().lastPathComponent) != nil }
    }

    private func checkFile(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, (1...65_536).contains(size) else { throw Failure.unreadable }
    }

    private func records<T: Decodable & Identifiable>(_ kind: Kind) throws -> [T] where T.ID == UUID {
        guard let directory = try directory(kind, create: false) else { return [] }
        let urls = try files(in: directory)
        guard urls.count <= 24 else { throw Failure.full }
        return try urls.map { url in
            let data = try LocalFileStore.readBytes(from: url, maximumBytes: 65_536)
            let record = try JSONDecoder().decode(T.self, from: data)
            guard record.id.uuidString == url.deletingPathExtension().lastPathComponent else { throw Failure.unreadable }
            return record
        }
    }

    private func save<T: Encodable & Identifiable>(_ record: T, kind: Kind) throws where T.ID == UUID {
        guard let directory = try directory(kind, create: true) else { throw Failure.unreadable }
        let url = directory.appending(path: record.id.uuidString + ".json")
        if FileManager.default.fileExists(atPath: url.path) { try checkFile(url) }
        else if try files(in: directory).count >= 24 { throw Failure.full }
        let data = try JSONEncoder().encode(record)
        guard data.count <= 65_536 else { throw Failure.invalid }
        try LocalFileStore.writeBytes(data, to: url, within: directory)
    }

    private func remove(_ id: UUID, kind: Kind) throws {
        guard let directory = try directory(kind, create: false) else { return }
        let url = directory.appending(path: id.uuidString + ".json")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try checkFile(url)
        try FileManager.default.removeItem(at: url)
    }
}

struct TeamBotNotebook: View {
    let botID: UUID
    @Environment(\.fadedPalette) private var palette
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var page: Page = .memory
    @State private var memories: [TeamBotNotebookStore.Memory] = []
    @State private var skills: [TeamBotNotebookStore.Skill] = []
    @State private var editor: BotNotebookDraft?
    @State private var deletion: BotNotebookDraft?
    @State private var notice: String?
    @State private var teaching = false
    @State private var learned: TeamBotNotebookStore.Skill?
    @State private var skillToRun: TeamBotNotebookStore.Skill?

    private enum Page: String, CaseIterable {
        case memory = "Hukommelse"
        case skills = "Færdigheder"
    }

    private var store: TeamBotNotebookStore { TeamBotNotebookStore(botID: botID) }
    private var profile: VillageBot? {
        let bots = try? JSONDecoder().decode([VillageBot].self, from: MigratedAppData.shared.villageBots)
        return bots?.first { $0.id == botID }
    }

    var body: some View {
        VStack(spacing: FadedSpacing.s) {
            Group {
                if typeSize.isAccessibilitySize { pagePicker.pickerStyle(.menu) }
                else { pagePicker.pickerStyle(.segmented) }
            }.frame(minHeight: 44).padding(.horizontal, FadedSpacing.edge)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: FadedSpacing.section) {
                    if let notice { Text(notice).font(.caption).foregroundStyle(palette.secondary) }
                    switch page {
                    case .memory: memorySection
                    case .skills: skillsSection
                    }
                }.padding(FadedSpacing.edge)
            }.id(page)
        }
        .background { FadedBackground() }
        .navigationTitle("Bottens notesbog")
        .task { reload() }
        .sheet(item: $editor) { item in
            BotNotebookEditor(draft: item, save: persist)
        }
        .sheet(isPresented: $teaching, onDismiss: {
            guard let learned else { return }
            self.learned = nil
            editor = BotNotebookDraft(id: learned.id, kind: .skill, title: learned.title, steps: learned.steps)
        }) {
            TeamTeachTask { learned = $0 }
        }
        .sheet(item: $skillToRun) { skill in
            if let profile {
                NavigationStack {
                    TeamWorkflowView(mode: .skill, bots: [profile], skill: skill)
                        .toolbar { Button("Luk") { skillToRun = nil } }
                }
            }
        }
        .confirmationDialog("Slet denne post?", isPresented: Binding(get: { deletion != nil }, set: { if !$0 { deletion = nil } }), presenting: deletion) { item in
            Button("Slet", role: .destructive) { remove(item) }
        }
    }

    private var pagePicker: some View {
        Picker("Notesbogens indhold", selection: $page) {
            ForEach(Page.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
    }

    private var memorySection: some View {
        VStack(alignment: .leading, spacing: FadedSpacing.section) {
            FadedDetailText("Gem fakta og præferencer, du vil beholde i bottens lokale notesbog.")
            FadedSecondaryButton("Tilføj hukommelse", icon: "plus") { editor = BotNotebookDraft(kind: .memory) }
            ForEach(memories) { item in
                recordCard(BotNotebookDraft(id: item.id, kind: .memory, title: item.title, text: item.text), copy: item.text)
            }
        }
    }

    private var skillsSection: some View {
        let canRun = profile != nil
        return VStack(alignment: .leading, spacing: FadedSpacing.section) {
            FadedDetailText("Gem en arbejdsgang på telefonen. Du kan læse trinnene, før du bruger den som tekst.")
            FadedSecondaryButton("Tilføj færdighed", icon: "plus") { editor = BotNotebookDraft(kind: .skill) }
            FadedSecondaryButton("Lær botten en opgave", icon: "list.number") { teaching = true }
            ForEach(skills) { item in
                recordCard(BotNotebookDraft(id: item.id, kind: .skill, title: item.title, steps: item.steps, sop: item.sop),
                           copy: item.prompt, run: canRun ? { skillToRun = item } : nil)
            }
        }
    }

    private func recordCard(_ item: BotNotebookDraft, copy text: String, run: (() -> Void)? = nil) -> some View {
        FadedCard(accent: item.kind == .memory ? palette.cyan : palette.purple) {
            VStack(alignment: .leading, spacing: 6) {
                Text(item.title).font(FadedTypography.action)
                Text(item.kind == .memory ? item.text : "\(item.steps.count) trin" + (item.sop == nil ? "" : " · SOP vedlagt"))
                    .font(.subheadline).lineLimit(3).foregroundStyle(palette.secondary)
                if item.kind == .skill {
                    DisclosureGroup("Se arbejdsgangen") {
                        VStack(alignment: .leading, spacing: FadedSpacing.s) {
                            ForEach(Array(item.steps.enumerated()), id: \.offset) { entry in
                                Text("\(entry.offset + 1). \(entry.element)")
                            }
                            if let sop = item.sop {
                                FadedFieldLabel("Vejledning")
                                Text(verbatim: sop)
                            }
                        }.padding(.vertical, FadedSpacing.s)
                    }.frame(minHeight: 44)
                }
                if let run { FadedSecondaryButton("Kør som tekst", icon: "play", action: run) }
                Menu("Handlinger", systemImage: "ellipsis.circle") {
                    Button("Redigér", systemImage: "pencil") { editor = item }
                    Button("Kopiér", systemImage: "doc.on.doc") {
                        UIPasteboard.general.setItems([[UTType.utf8PlainText.identifier: text]], options: [.localOnly: true])
                        notice = text.unicodeScalars.count > 2_000
                            ? "Kopieret. Del lange arbejdsgange op i beskeder på højst 2.000 tegn."
                            : "Kopieret på telefonen."
                    }
                    Button("Slet", systemImage: "trash", role: .destructive) { deletion = item }
                }.frame(minHeight: 44)
            }
        }
    }

    private func persist(_ item: BotNotebookDraft) throws {
        switch item.kind {
        case .memory: try store.save(.init(id: item.id, title: item.title, text: item.text))
        case .skill: try store.save(.init(id: item.id, title: item.title, steps: item.steps, sop: item.sop))
        }
        editor = nil
        reload()
    }

    private func remove(_ item: BotNotebookDraft) {
        deletion = nil
        do {
            switch item.kind {
            case .memory: try store.deleteMemory(item.id)
            case .skill: try store.deleteSkill(item.id)
            }
            reload()
        } catch { AppDiagnostics.record(error); notice = "Posten kunne ikke slettes." }
    }

    private func reload() {
        do {
            memories = try store.memories().sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            skills = try store.skills().sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            notice = nil
        } catch { AppDiagnostics.record(error); notice = "Bottens notesbog kunne ikke læses." }
    }
}

private struct BotNotebookDraft: Identifiable {
    enum Kind { case memory, skill }
    var id = UUID()
    let kind: Kind
    var title = ""
    var text = ""
    var steps = [""]
    var sop: String?
}

private struct BotNotebookEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var draft: BotNotebookDraft
    let save: (BotNotebookDraft) throws -> Void
    @State private var importSOP = false
    @State private var notice: String?

    var body: some View {
        NavigationStack {
            Form {
                TextField("Titel", text: $draft.title).frame(minHeight: 44)
                if draft.kind == .memory {
                    TextField("Hvad skal botten huske?", text: $draft.text, axis: .vertical).lineLimit(4...8)
                } else {
                    Section("Trin i arbejdsgangen") {
                        ForEach(draft.steps.indices, id: \.self) { index in
                            TextField("Trin \(index + 1)", text: Binding(
                                get: { draft.steps.indices.contains(index) ? draft.steps[index] : "" },
                                set: { if draft.steps.indices.contains(index) { draft.steps[index] = $0 } }
                            ), axis: .vertical).lineLimit(2...5)
                        }
                        .onDelete { draft.steps.remove(atOffsets: $0) }
                        Button("Tilføj trin", systemImage: "plus") { draft.steps.append("") }
                            .frame(minHeight: 44).disabled(draft.steps.count >= 12)
                    }
                    Section("Valgfri SOP") {
                        Button("Vælg en tekstfil", systemImage: "doc.text") { importSOP = true }.frame(minHeight: 44)
                        if draft.sop != nil {
                            TextField("SOP", text: Binding(get: { draft.sop ?? "" }, set: { draft.sop = $0 }), axis: .vertical)
                                .lineLimit(4...8)
                            Button("Fjern SOP", role: .destructive) { draft.sop = nil }.frame(minHeight: 44)
                        }
                    }
                }
                if let notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
                FadedPrimaryButton("Gem", icon: "checkmark") {
                    do { try save(draft) }
                    catch let error as TeamBotNotebookStore.Failure { AppDiagnostics.record(error); notice = error.errorDescription }
                    catch { AppDiagnostics.record(error); notice = "Posten kunne ikke gemmes på telefonen." }
                }
            }
            .scrollContentBackground(.hidden)
            .background { FadedBackground() }
            .navigationTitle(draft.kind == .memory ? "Hukommelse" : "Færdighed")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Luk") { dismiss() } }
            .fileImporter(isPresented: $importSOP, allowedContentTypes: [.plainText]) { result in
                do {
                    draft.sop = try TeamBotNotebookStore.readSOP(result.get())
                    notice = nil
                } catch { AppDiagnostics.record(error); notice = "Vælg en UTF-8-tekstfil på højst 16 KB." }
            }
        }
    }
}
