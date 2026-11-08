import CoreML
import CoreMLLLM
import Foundation
import FoundationModels
import MediaGenerationKit
import Observation
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import UserNotifications

enum PhoneModelError: Error {
    case unavailable, invalidBundle, emptyResponse, downloadBusy
}

enum PhoneModels {
    static let liteBatteryKey = "phone.model.liteBattery"

    struct Entry: Identifiable {
        let model: ModelDownloader.ModelInfo
        let memory: String
        var id: String { model.id }
    }

    static func hasDownloadSpace(bytes: Int64) -> Bool {
        let values = try? URL.documentsDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return (values?.volumeAvailableCapacityForImportantUsage ?? 0) >= bytes
    }

    static var catalog: [Entry] {
        [
            .init(model: .lfm2_5_350m, memory: "Lavere hukommelsesforbrug"),
            .init(model: .qwen35_08b, memory: "Mellem hukommelsesforbrug"),
            .init(model: .gemma4e2b, memory: "Højt hukommelsesforbrug")
        ]
    }

    static var appleAvailable: Bool {
        if #available(iOS 26.0, *), case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    static var importedFolder: URL {
        URL.applicationSupportDirectory.appending(path: "ImportedPhoneModels", directoryHint: .isDirectory)
    }

    static func supportsLocalInference(_ id: String) -> Bool {
        // The pinned package's generic loader cannot run Qwen3.5's separate decoder.
        id != ModelDownloader.ModelInfo.qwen35_08b.id
    }

    static func installedDirectory(_ id: String) -> URL? {
        guard supportsLocalInference(id) else { return nil }
        if id == "imported" {
            let config = importedFolder.appending(path: "model_config.json")
            return FileManager.default.fileExists(atPath: config.path) ? importedFolder : nil
        }
        guard let entry = catalog.first(where: { $0.id == id }) else { return nil }
        guard ModelDownloader.shared.isDownloaded(entry.model) else { return nil }
        return ModelDownloader.shared.localModelURL(for: entry.model)?.deletingLastPathComponent()
    }

    @MainActor static func effectiveModelID(_ selected: String) -> String {
        liteModeActive(for: selected) ? ModelDownloader.ModelInfo.lfm2_5_350m.id : selected
    }

    @MainActor static func liteModeActive(for selected: String) -> Bool {
        let device = UIDevice.current
        let liteID = ModelDownloader.ModelInfo.lfm2_5_350m.id
        return UserDefaults.standard.bool(forKey: liteBatteryKey)
            && device.batteryLevel >= 0 && device.batteryLevel < 0.20
            && selected != liteID && installedDirectory(liteID) != nil
    }

    static func prefersPC(_ message: String, previousCharacters: Int) -> Bool {
        if message.count + previousCharacters > 3_000 || message.count > 1_200 { return true }
        let text = message.lowercased()
        return ["video", "klip", "render", "researcher", "søg på", "søg efter", "websøg",
                "seneste nyt", "min pc", "på pc", "file explorer", "agent-hub"].contains { text.contains($0) }
    }

    private static func minimumMemory(for modelID: String) -> UInt64 {
        switch modelID {
        case "apple": 256
        case ModelDownloader.ModelInfo.lfm2_5_350m.id: 512
        case ModelDownloader.ModelInfo.qwen35_08b.id: 1_024
        default: 2_048
        }
    }

    @MainActor static func reply(modelID: String, prompt: String, instructions: String = "", update: @escaping (String) -> Void) async throws {
        try await LocalCompute.run(minimumMiB: minimumMemory(for: modelID)) {
            try await streamReply(modelID: modelID, prompt: prompt, instructions: instructions, update: update)
        }
    }

    @MainActor private static func streamReply(modelID: String, prompt: String, instructions: String,
                                              update: (String) -> Void) async throws {
        var answer = ""
        if modelID == "apple" {
            guard #available(iOS 26.0, *), appleAvailable else { throw PhoneModelError.unavailable }
            let defaults = "Svar kort på brugerens sprog. Du har kun adgang til teksten i chatten."
            let session = LanguageModelSession(instructions: instructions.isEmpty ? defaults : instructions)
            LocalCompute.didLoadModel()
            for try await snapshot in session.streamResponse(to: prompt) {
                try Task.checkCancellation()
                answer = snapshot.content
                update(answer)
            }
        } else {
            guard let folder = installedDirectory(modelID) else { throw PhoneModelError.unavailable }
            LocalCompute.beginModelLoad()
            let model = try await CoreMLLLM.load(from: folder, computeUnits: .cpuAndNeuralEngine)
            try Task.checkCancellation()
            LocalCompute.didLoadModel()
            let user = CoreMLLLM.Message(role: .user, content: prompt)
            let messages = instructions.isEmpty ? [user] : [.init(role: .system, content: instructions), user]
            for await token in try await model.stream(messages, maxTokens: 384) {
                try Task.checkCancellation()
                answer += token
                update(answer)
            }
        }
        guard !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PhoneModelError.emptyResponse
        }
    }

    @MainActor static func benchmark(modelID: String) async throws -> String {
        let prompt = "Skriv to korte sætninger om, hvordan regn dannes."
        return try await LocalCompute.run(minimumMiB: minimumMemory(for: modelID)) {
            if modelID == "apple" {
                guard #available(iOS 26.0, *), appleAvailable else { throw PhoneModelError.unavailable }
                let session = LanguageModelSession()
                LocalCompute.didLoadModel()
                let start = Date()
                _ = try await session.respond(to: prompt)
                try Task.checkCancellation()
                let seconds = Date().timeIntervalSince(start).formatted(.number.precision(.fractionLength(1)))
                return "Apple Foundation Models: \(seconds) sek. pr. svar."
            }
            guard let folder = installedDirectory(modelID) else { throw PhoneModelError.unavailable }
            LocalCompute.beginModelLoad()
            let model = try await CoreMLLLM.load(from: folder, computeUnits: .cpuAndNeuralEngine)
            try Task.checkCancellation()
            LocalCompute.didLoadModel()
            let reply = try await model.generate(prompt, maxTokens: 64)
            try Task.checkCancellation()
            let rate = model.tokensPerSecond
            guard !reply.isEmpty, rate.isFinite, rate > 0 else { throw PhoneModelError.emptyResponse }
            let name = catalog.first(where: { $0.id == modelID })?.model.name ?? "Importeret model"
            return "\(name): \(rate.formatted(.number.precision(.fractionLength(1)))) tokens/sek."
        }
    }

    static func importFolder(_ source: URL) throws {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let files = FileManager.default
        guard files.fileExists(atPath: source.appending(path: "model_config.json").path),
              files.fileExists(atPath: source.appending(path: "hf_model/tokenizer.json").path),
              let contents = try? files.contentsOfDirectory(at: source, includingPropertiesForKeys: nil),
              contents.contains(where: { ["mlpackage", "mlmodelc"].contains($0.pathExtension) })
        else { throw PhoneModelError.invalidBundle }
        let parent = importedFolder.deletingLastPathComponent()
        try files.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? files.removeItem(at: staging) }
        try files.copyItem(at: source, to: staging)
        var modelDirectory = staging
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try modelDirectory.setResourceValues(values)
        if files.fileExists(atPath: importedFolder.path) {
            _ = try files.replaceItemAt(importedFolder, withItemAt: staging)
        } else {
            try files.moveItem(at: staging, to: importedFolder)
        }
    }
}

@MainActor final class PhoneModelDownloads {
    static let shared = PhoneModelDownloads()
    static let backgroundIdentifier = "com.coreml-llm.model-download"
    private let key = "phone.model.pending-download"
    private var observing = false

    func activate() {
        let downloader = ModelDownloader.shared
        if !observing {
            observing = true
            observeChanges()
        }
        if downloader.isPaused,
           let pending = UserDefaults.standard.string(forKey: key), pending == downloader.downloadingModelId {
            if PhoneModels.supportsLocalInference(pending) { downloader.resumeDownload() }
            else { cancel() }
        }
        Task { await publishCompletionIfReady() }
    }

    func download(_ model: ModelDownloader.ModelInfo) async throws {
        let downloader = ModelDownloader.shared
        guard PhoneModels.supportsLocalInference(model.id) else { throw PhoneModelError.unavailable }
        guard !downloader.isDownloading || (downloader.isPaused && downloader.downloadingModelId == model.id) else {
            throw PhoneModelError.downloadBusy
        }
        UserDefaults.standard.set(model.id, forKey: key)
        do {
            _ = try await downloader.download(model)
            await publishCompletionIfReady()
        } catch {
            if UserDefaults.standard.string(forKey: key) == model.id && !downloader.isDownloading {
                UserDefaults.standard.removeObject(forKey: key)
            }
            throw error
        }
    }

    func cancel() {
        UserDefaults.standard.removeObject(forKey: key)
        ModelDownloader.shared.cancelDownload()
    }

    func handleBackgroundEvents(completion: @escaping () -> Void) {
        ModelDownloader.shared.backgroundCompletionHandler = {
            Task { @MainActor in
                await self.publishCompletionIfReady()
                completion()
            }
        }
        activate()
    }

    private func observeChanges() {
        withObservationTracking {
            _ = ModelDownloader.shared.isDownloading
            _ = ModelDownloader.shared.refreshTrigger
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.observeChanges()
                await self.publishCompletionIfReady()
            }
        }
    }

    private func publishCompletionIfReady() async {
        let downloader = ModelDownloader.shared
        guard !downloader.isDownloading,
              let id = UserDefaults.standard.string(forKey: key),
              let entry = PhoneModels.catalog.first(where: { $0.id == id }),
              downloader.isDownloaded(entry.model) else { return }
        UserDefaults.standard.removeObject(forKey: key)
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
        let content = UNMutableNotificationContent()
        content.title = "Din lokale model er klar!"
        content.body = entry.model.name
        content.sound = .default
        try? await center.add(UNNotificationRequest(identifier: "model-download-\(UUID())", content: content, trigger: nil))
    }
}

@MainActor final class FadedAIModelDownloadDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UIDevice.current.isBatteryMonitoringEnabled = true
        PhoneModelDownloads.shared.activate()
        return true
    }

    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == PhoneModelDownloads.backgroundIdentifier else { completionHandler(); return }
        PhoneModelDownloads.shared.handleBackgroundEvents(completion: completionHandler)
    }
}

private enum ModelDiskStorage {
    struct Item: Identifiable, Sendable {
        let url: URL
        let name: String
        let kind: String
        let bytes: Int64
        var id: URL { url }
    }

    struct Snapshot: Sendable {
        var text: [String: Int64] = [:]
        var files: [Item] = []
        var total = Int64(0)
        var used: Int64?
        var capacity: Int64?
    }

    static let textRoot = URL.documentsDirectory.appendingPathComponent("Models", isDirectory: true)

    static func allowedImageRoots(_ configured: [URL]) -> [URL] {
        let allowed = [URL.documentsDirectory, URL.applicationSupportDirectory].map { $0.resolvingSymlinksInPath().path + "/" }
        var seen = Set<URL>()
        return (configured + [textRoot]).map { $0.resolvingSymlinksInPath().standardizedFileURL }
            .filter { root in allowed.contains(where: { root.path.hasPrefix($0) }) && seen.insert(root).inserted }
    }

    static func scan(textFolders: [String: URL], imageRoots: [URL]) -> Snapshot {
        var snapshot = Snapshot()
        var seen = Set<NSObject>()
        for (id, folder) in textFolders.sorted(by: { $0.key < $1.key }) {
            snapshot.text[id] = folderSize(folder, seen: &seen)
        }
        for folder in imageRoots {
            let contents = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys),
                                                                        options: [.skipsHiddenFiles])) ?? []
            for url in contents where ["ckpt", "safetensors"].contains(url.pathExtension.lowercased()) {
                guard let size = fileSize(url, seen: &seen) else { continue }
                let kind = url.lastPathComponent.lowercased().contains("lora") ? "LoRA" : "Billedmodelfil"
                snapshot.files.append(Item(url: url, name: url.lastPathComponent, kind: kind, bytes: size))
            }
        }
        snapshot.files.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        snapshot.total = snapshot.text.values.reduce(0, +) + snapshot.files.reduce(0) { $0 + $1.bytes }
        if let volume = try? URL.documentsDirectory.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey]),
           let total = volume.volumeTotalCapacity, let free = volume.volumeAvailableCapacity {
            snapshot.capacity = Int64(total)
            snapshot.used = Int64(max(0, total - free))
        }
        return snapshot
    }

    static func delete(_ file: Item, within roots: [URL]) throws {
        let target = file.url.standardizedFileURL
        guard roots.contains(target.deletingLastPathComponent()), target == target.resolvingSymlinksInPath(),
              ["ckpt", "safetensors"].contains(target.pathExtension.lowercased()),
              try target.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw PhoneModelError.invalidBundle
        }
        try FileManager.default.removeItem(at: target)
    }

    static func gigabytes(_ bytes: Int64) -> String {
        (Double(bytes) / 1_000_000_000).formatted(.number.precision(.fractionLength(3))) + " GB"
    }

    private static let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey,
                                                     .fileAllocatedSizeKey, .fileSizeKey, .fileResourceIdentifierKey]

    private static func folderSize(_ folder: URL, seen: inout Set<NSObject>) -> Int64 {
        guard (try? folder.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { return 0 }
        guard let contents = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: Array(keys), options: []) else { return 0 }
        var total = Int64(0)
        for case let file as URL in contents {
            if (try? file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                contents.skipDescendants()
                continue
            }
            total += fileSize(file, seen: &seen) ?? 0
        }
        return total
    }

    private static func fileSize(_ file: URL, seen: inout Set<NSObject>) -> Int64? {
        guard let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
        if let id = values.fileResourceIdentifier as? NSObject, !seen.insert(id).inserted { return nil }
        return Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0)
    }
}

struct PhoneModelsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("phone.model") private var selected = "apple"
    @AppStorage(PhoneModels.liteBatteryKey) private var liteBattery = false
    @AppStorage("phone.model.favorites") private var favoriteModels = ""
    @State private var requestingDownload = false
    @State private var importing = false
    @State private var working = false
    @State private var notice: String?
    @State private var storage: ModelDiskStorage.Snapshot?
    @State private var storageRevision = 0
    @State private var benchmarkRunning = false
    @State private var benchmarkResult: String?
    @State private var deleteTarget: DeleteTarget?
    @State private var page: Page = .models
    @Environment(\.dynamicTypeSize) private var typeSize

    private enum Page: String, CaseIterable {
        case models = "Modeller"
        case storage = "Lagerplads"
        case performance = "Hastighed"
    }

    private enum DeleteTarget {
        case text(id: String, name: String)
        case image(ModelDiskStorage.Item)

        var name: String {
            switch self {
            case .text(_, let name): name
            case .image(let item): item.name
            }
        }
    }

    private var downloader: ModelDownloader { .shared }
    private var mutationBusy: Bool { working || benchmarkRunning || requestingDownload || downloader.isDownloading }
    private var favorites: Set<String> { Set(favoriteModels.split(separator: "|").map(String.init)) }
    private var orderedCatalog: [PhoneModels.Entry] {
        PhoneModels.catalog.filter { favorites.contains($0.id) } + PhoneModels.catalog.filter { !favorites.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            List {
                Group {
                    if typeSize.isAccessibilitySize { pagePicker.pickerStyle(.menu) }
                    else { pagePicker.pickerStyle(.segmented) }
                }
                switch page {
                case .models:
                    favoriteSection
                    Section("Standard") {
                        HStack {
                            Button { selected = "apple"; benchmarkResult = nil } label: {
                                modelLabel("Apple Foundation Models", id: "apple")
                            }.buttonStyle(.borderless)
                            Spacer()
                            favoriteButton("apple")
                        }
                        Text(PhoneModels.appleAvailable ? "Klar på denne telefon."
                             : "Kræver iOS 26 og en aktiv, kompatibel Apple Intelligence-model.")
                            .font(.caption)
                    }
                    catalogSection
                    importSection
                case .storage:
                    storageSection
                    imageFilesSection
                case .performance:
                    benchmarkSection
                }
                if let notice { Text(notice) }
            }
            .navigationTitle("Lokale modeller")
            .toolbar { Button("Luk") { dismiss() }.disabled(working) }
            .interactiveDismissDisabled(working)
            .task(id: storageRevision) { await refreshStorage() }
            .onChange(of: downloader.isDownloading) { _, isDownloading in
                if !isDownloading { storageRevision += 1 }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.folder]) { result in
                if case .success(let url) = result { importModel(url) }
            }
            .confirmationDialog("Slet lokale modeldata?", isPresented: Binding(
                get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }
            ), presenting: deleteTarget) { target in
                Button("Slet \(target.name)", role: .destructive) { remove(target) }
            } message: { _ in Text("Du kan hente eller importere filen igen.") }
        }
    }

    private var pagePicker: some View {
        Picker("Sektion", selection: $page) {
            ForEach(Page.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
    }

    @ViewBuilder private var favoriteSection: some View {
        let installed = orderedCatalog.filter { favorites.contains($0.id) && PhoneModels.installedDirectory($0.id) != nil }
        let showApple = favorites.contains("apple")
        let showImported = favorites.contains("imported") && PhoneModels.installedDirectory("imported") != nil
        if showApple || showImported || !installed.isEmpty {
            Section("Favoritter") {
                if showApple {
                    Button { selected = "apple"; benchmarkResult = nil } label: {
                        modelLabel("Apple Foundation Models", id: "apple")
                    }
                }
                ForEach(installed) { entry in
                    Button { selected = entry.id; benchmarkResult = nil } label: {
                        modelLabel(entry.model.name, id: entry.id)
                    }
                }
                if showImported {
                    Button { selected = "imported"; benchmarkResult = nil } label: {
                        modelLabel("Importeret model", id: "imported")
                    }
                }
            }
        }
    }

    @ViewBuilder private var storageSection: some View {
        Section("Lagerplads") {
            if let storage {
                Text("Modeller og LoRA: \(ModelDiskStorage.gigabytes(storage.total))")
                if let used = storage.used, let capacity = storage.capacity {
                    Text("Telefonen bruger \(ModelDiskStorage.gigabytes(used)) af \(ModelDiskStorage.gigabytes(capacity)).")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                ProgressView("Måler modelplads…")
            }
        }
    }

    @ViewBuilder private var catalogSection: some View {
        Section("Core ML-modeller") {
            Text("Størrelser er cirka. RAM afhænger af telefonen og længden af chatten.")
                .font(.caption)
            ForEach(orderedCatalog) { entry in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(entry.model.name).font(.headline)
                        Spacer()
                        favoriteButton(entry.id)
                    }
                    Text("\(entry.model.size) · \(entry.memory)").font(.caption)
                    if downloader.downloadingModelId == entry.id && downloader.isDownloading {
                        let progress = min(1, max(0, downloader.progress))
                        ProgressView(value: progress) {
                            Text("Henter modellen · \(progress.formatted(.percent.precision(.fractionLength(0))))")
                        }
                        Text("Download fortsætter normalt i baggrunden, når iOS tillader det.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Annuller download", role: .destructive) { PhoneModelDownloads.shared.cancel(); storageRevision += 1 }
                            .frame(minHeight: 44)
                    } else if !PhoneModels.supportsLocalInference(entry.id) {
                        Text("Midlertidigt utilgængelig. Modellen kræver en særskilt lokal afspiller.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if PhoneModels.installedDirectory(entry.id) != nil {
                        Button { selected = entry.id; benchmarkResult = nil } label: { modelLabel("Brug modellen", id: entry.id) }
                    } else {
                        Button("Download") { download(entry) }
                            .disabled(mutationBusy)
                    }
                    if let bytes = storage?.text[entry.id] {
                        Text("På telefonen: \(ModelDiskStorage.gigabytes(bytes))").font(.caption)
                        Button("Slet \(entry.model.name)", role: .destructive) {
                            deleteTarget = .text(id: entry.id, name: entry.model.name)
                        }.frame(minHeight: 44).disabled(mutationBusy)
                    }
                }
            }
        }
    }

    @ViewBuilder private var importSection: some View {
        Section("Importér fra Filer") {
            Text("Gem modellen via AirDrop eller en filserver i Filer. Pak ZIP-filen ud, og vælg hele Core ML-modelmappen.")
                .font(.caption)
            Button("Vælg modelmappe") { importing = true }.disabled(mutationBusy)
            if working { ProgressView("Importerer model…") }
            if PhoneModels.installedDirectory("imported") != nil {
                HStack {
                    Button { selected = "imported"; benchmarkResult = nil } label: { modelLabel("Brug importeret model", id: "imported") }
                        .buttonStyle(.borderless)
                    Spacer()
                    favoriteButton("imported")
                }
                if let bytes = storage?.text["imported"] {
                    Text("På telefonen: \(ModelDiskStorage.gigabytes(bytes))").font(.caption)
                }
                Button("Slet importeret model", role: .destructive) {
                    deleteTarget = .text(id: "imported", name: "Importeret model")
                }.frame(minHeight: 44).disabled(mutationBusy)
            }
        }
    }

    @ViewBuilder private var imageFilesSection: some View {
        if let files = storage?.files, !files.isEmpty {
            Section("Billedmodelfiler og LoRA") {
                Text("Billedmodeller kan dele filer. Når du sletter en delt fil, kan den skulle hentes igen for andre modeller.")
                    .font(.caption)
                ForEach(files) { file in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(verbatim: file.name).font(.headline)
                        Text("\(file.kind) · \(ModelDiskStorage.gigabytes(file.bytes))").font(.caption)
                        Button("Slet", role: .destructive) { deleteTarget = .image(file) }
                            .accessibilityLabel("Slet \(file.name)").frame(minHeight: 44).disabled(mutationBusy)
                    }
                }
            }
        }
    }

    @ViewBuilder private var benchmarkSection: some View {
        Section("Hastighed og batteri") {
            Toggle("Skift automatisk til lille model ved under 20 % batteri", isOn: $liteBattery)
            if liteBattery && PhoneModels.installedDirectory(ModelDownloader.ModelInfo.lfm2_5_350m.id) == nil {
                Text("Hent LFM2.5 350M for at bruge batteritilstanden.").font(.caption)
            }
            Button(benchmarkRunning ? "Måler…" : "Benchmark") { benchmark() }
                .frame(minHeight: 44).disabled(mutationBusy)
            if let benchmarkResult { Text(benchmarkResult).accessibilityAddTraits(.updatesFrequently) }
        }
    }

    private func modelLabel(_ title: String, id: String) -> some View {
        Label(title, systemImage: selected == id ? "checkmark.circle.fill" : "circle")
            .accessibilityValue(selected == id ? "Valgt" : "Ikke valgt")
    }

    private func favoriteButton(_ id: String) -> some View {
        Button {
            var updated = favorites
            if !updated.insert(id).inserted { updated.remove(id) }
            favoriteModels = updated.sorted().joined(separator: "|")
        } label: {
            Image(systemName: favorites.contains(id) ? "star.fill" : "star").frame(minWidth: 44, minHeight: 44)
        }.buttonStyle(.borderless)
         .accessibilityLabel(favorites.contains(id) ? "Fjern favoritmodel" : "Gør til favoritmodel")
    }

    private func download(_ entry: PhoneModels.Entry) {
        let reserves: [String: Int64] = ["lfm2.5-350m": 1_200_000_000, "gemma4-e2b": 7_000_000_000]
        guard PhoneModels.hasDownloadSpace(bytes: reserves[entry.id] ?? 2_000_000_000) else {
            notice = "Der er ikke plads nok til modellen. Frigør plads, og prøv igen."
            return
        }
        guard !mutationBusy else { return }
        requestingDownload = true
        notice = nil
        Task {
            defer { requestingDownload = false; storageRevision += 1 }
            do {
                try await PhoneModelDownloads.shared.download(entry.model)
                notice = "Modellen er hentet. Tryk Brug modellen for at vælge den."
            } catch is CancellationError { notice = "Download annulleret." }
            catch { notice = "Modellen kunne ikke hentes. Tjek internet og ledig plads, og prøv igen." }
        }
    }

    private func importModel(_ url: URL) {
        working = true
        notice = nil
        Task {
            defer { working = false; storageRevision += 1 }
            do {
                try await LocalCompute.run(minimumMiB: 0) {
                    try await Task.detached(priority: .userInitiated) { try PhoneModels.importFolder(url) }.value
                }
                selected = "imported"
                notice = "Modellen er importeret og valgt."
            } catch {
                notice = "Importen mislykkedes. Vælg en udpakket Core ML-modelmappe med konfiguration og tokenizer."
            }
        }
    }

    private func refreshStorage() async {
        var textFolders: [String: URL] = [:]
        for entry in PhoneModels.catalog where downloader.hasFiles(entry.model) {
            textFolders[entry.id] = ModelDiskStorage.textRoot.appendingPathComponent(entry.model.folderName, isDirectory: true)
        }
        if PhoneModels.installedDirectory("imported") != nil { textFolders["imported"] = PhoneModels.importedFolder }
        let folders = textFolders
        let roots = ModelDiskStorage.allowedImageRoots(MediaGenerationEnvironment.default.externalUrls)
        let snapshot = await Task.detached(priority: .utility) { ModelDiskStorage.scan(textFolders: folders, imageRoots: roots) }.value
        if !Task.isCancelled { storage = snapshot }
    }

    private func remove(_ target: DeleteTarget) {
        guard !mutationBusy else { return }
        working = true
        notice = nil
        Task {
            defer { working = false; storageRevision += 1 }
            do {
                try await LocalCompute.run(minimumMiB: 0) {
                    switch target {
                    case .text(let id, _):
                        if id == "imported" {
                            try FileManager.default.removeItem(at: PhoneModels.importedFolder)
                        } else if let model = PhoneModels.catalog.first(where: { $0.id == id })?.model {
                            try downloader.delete(model)
                        }
                        if selected == id { selected = "apple"; benchmarkResult = nil }
                    case .image(let file):
                        try ModelDiskStorage.delete(file, within: ModelDiskStorage.allowedImageRoots(MediaGenerationEnvironment.default.externalUrls))
                    }
                }
                notice = "Modelfilen er slettet."
            } catch LocalComputeError.busy { notice = "Vent til den lokale AI-opgave er færdig." }
            catch { notice = "Modelfilen kunne ikke slettes." }
        }
    }

    private func benchmark() {
        guard !mutationBusy else { return }
        let id = selected
        benchmarkRunning = true
        benchmarkResult = nil
        Task {
            defer { benchmarkRunning = false }
            do {
                let result = try await PhoneModels.benchmark(modelID: id)
                if selected == id { benchmarkResult = result }
            } catch LocalComputeError.busy { notice = "Vent til den lokale AI-opgave er færdig." }
            catch LocalComputeError.lowMemory { notice = "Der er for lidt ledig hukommelse til benchmark lige nu." }
            catch { notice = "Benchmark kunne ikke gennemføres. Vælg en klar model og prøv igen." }
        }
    }
}
