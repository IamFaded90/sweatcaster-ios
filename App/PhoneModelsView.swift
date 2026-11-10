// Model selection, storage and benchmarks in Settings.
import CoreMLLLM
import Foundation
import MediaGenerationKit
import SwiftUI
import UniformTypeIdentifiers

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

    static let textRoot = PhoneModels.downloadedRoot

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
    let allowsImageDownloads: Bool
    init(allowsImageDownloads: Bool = true) { self.allowsImageDownloads = allowsImageDownloads }
    @Environment(\.dismiss) private var dismiss
    @Environment(\.fadedPalette) private var palette
    @AppStorage(AppStorageKeys.phoneModel) private var selected = "apple"
    @AppStorage(AppStorageKeys.phoneModelLiteBattery) private var liteBattery = false
    @AppStorage(AppStorageKeys.phoneModelFavorites) private var favoriteModels = ""
    @State private var downloadConfirmation: PhoneModels.Entry?
    @State private var requestedDownloadID: String?
    @State private var imageDownload: StudioImageModel?
    @State private var importing = false
    @State private var working = false
    @State private var notice: String?
    @State private var downloadSuccess: String?
    @State private var storage: ModelDiskStorage.Snapshot?
    @State private var storageRevision = 0
    @State private var benchmarkRunning = false
    @State private var benchmarkResult: String?
    @State private var deleteTarget: DeleteTarget?
    @State private var page: Page = .models
    @Environment(\.dynamicTypeSize) private var typeSize

    private enum Page: String, CaseIterable {
        case models = "Modeller"
        case images = "Billeder"
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
    private var mutationBusy: Bool {
        working || benchmarkRunning || imageDownload != nil || requestedDownloadID != nil || downloader.isDownloading || PhoneModelDownloads.shared.preparingModelID != nil
    }
    private var favorites: Set<String> { Set(favoriteModels.split(separator: "|").map(String.init)) }
    private var orderedCatalog: [PhoneModels.Entry] {
        PhoneModels.catalog.filter { favorites.contains($0.id) } + PhoneModels.catalog.filter { !favorites.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: FadedSpacing.section) {
                    if typeSize.isAccessibilitySize { pagePicker.pickerStyle(.menu) }
                    else { pagePicker.pickerStyle(.segmented) }
                    modelPage
                    if let notice { FadedDetailText(notice).accessibilityAddTraits(.updatesFrequently) }
                }
                .padding(16).frame(maxWidth: 640).frame(maxWidth: .infinity)
            }
            .background { FadedBackground() }
            .foregroundStyle(palette.text)
            .tint(palette.isDark ? palette.lime : palette.text)
            .navigationTitle("Lokale modeller")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Luk") { dismiss() }.disabled(working || imageDownload != nil) }
            .interactiveDismissDisabled(working || imageDownload != nil)
            .task(id: storageRevision) { await refreshStorage() }
            .onChange(of: downloader.isDownloading) { _, isDownloading in
                if !isDownloading { storageRevision += 1 }
            }
            .onChange(of: PhoneModelDownloads.shared.preparingModelID) { _, id in
                if id == nil { storageRevision += 1 }
            }
            .safeAreaInset(edge: .bottom) {
                if let downloadSuccess {
                    FadedToast(downloadSuccess, tone: .success).padding(.horizontal, FadedSpacing.edge)
                }
            }
            .task(id: downloadSuccess) {
                guard downloadSuccess != nil else { return }
                do { try await Task.sleep(for: .seconds(4)) }
                catch { return }
                downloadSuccess = nil
            }
            .confirmationDialog("Hent stor model?", isPresented: Binding(
                get: { downloadConfirmation != nil }, set: { if !$0 { downloadConfirmation = nil } }
            ), presenting: downloadConfirmation) { entry in
                Button("Hent modellen") { download(entry) }
            } message: { entry in
                Text("\(entry.name) henter ca. \(ModelDiskStorage.gigabytes(entry.estimatedDownloadBytes)). Vælg PC til tunge opgaver eller ved lav arbejdshukommelse.")
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

    @ViewBuilder private var modelPage: some View {
        switch page {
        case .models:
            catalogSection
            appleCard
            favoriteSection
            importSection
        case .images:
            StudioImageDownloadsView(downloading: $imageDownload, canStart: !mutationBusy) { storageRevision += 1 }
        case .storage:
            storageSection
            imageFilesSection
        case .performance:
            benchmarkSection
        }
    }

    private var pagePicker: some View {
        Picker("Sektion", selection: $page) {
            ForEach(Page.allCases.filter { allowsImageDownloads || $0 != .images }, id: \.self) { Text($0.rawValue).tag($0) }
        }.disabled(imageDownload != nil)
    }

    @ViewBuilder private var favoriteSection: some View {
        let installed = orderedCatalog.filter { favorites.contains($0.id) && PhoneModels.installedDirectory($0.id) != nil }
        let showApple = favorites.contains("apple")
        let showImported = favorites.contains("imported") && PhoneModels.installedDirectory("imported") != nil
        if showApple || showImported || !installed.isEmpty {
            FadedCard {
                VStack(alignment: .leading, spacing: 6) {
                    FadedSectionLabel("Favoritter")
                    if showApple { favoriteRow("Apple Foundation Models", id: "apple") }
                    ForEach(installed) { entry in
                        favoriteRow(entry.name, id: entry.id)
                    }
                    if showImported { favoriteRow("Importeret model", id: "imported") }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func favoriteRow(_ title: String, id: String) -> some View {
        Button { select(id) } label: {
            Label(title, systemImage: selected == id ? "checkmark.circle.fill" : "circle")
                .frame(minHeight: 44).accessibilityValue(selected == id ? "Valgt" : "Ikke valgt")
        }.buttonStyle(.plain).disabled(!PhoneModels.isReady(id))
    }

    private var appleCard: some View {
        let ready = PhoneModels.appleAvailable
        return FadedCard(accent: selected == "apple" ? palette.lime : nil) {
            VStack(alignment: .leading, spacing: 10) {
                modelHeader("Apple Foundation Models", icon: "sparkles", id: "apple", ready: ready)
                modelStatus(ready ? "Klar" : "Ikke tilgængelig", color: ready ? palette.green : palette.secondary)
                if !ready {
                    Text("Kræver iOS 26 og en aktiv, kompatibel Apple Intelligence-model.")
                        .font(.caption).foregroundStyle(palette.secondary)
                }
                if ready && selected != "apple" {
                    FadedSecondaryButton("Brug modellen", icon: "checkmark") { select("apple") }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var storageSection: some View {
        FadedCard(accent: palette.cyan) {
            VStack(alignment: .leading, spacing: 10) {
                FadedSectionLabel("Lagerplads")
                if let storage {
                    Text("Modeller og LoRA: \(ModelDiskStorage.gigabytes(storage.total))").font(.headline)
                    if let used = storage.used, let capacity = storage.capacity, capacity > 0 {
                        FadedProgress(value: Double(used) / Double(capacity))
                        Text("\(ModelDiskStorage.gigabytes(max(0, capacity - used))) ledig af \(ModelDiskStorage.gigabytes(capacity)).")
                            .font(.caption).foregroundStyle(palette.secondary)
                    }
                } else {
                    LoadingSkeleton(label: "Måler modelplads…")
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var catalogSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            FadedSectionHeader("Alle \(PhoneModels.catalog.count) iPhone-modeller",
                               detail: "Hent én gang og brug offline. Lagerplads afgør, hvor mange modeller du kan gemme. Arbejdshukommelsen (RAM) afgør, hvor stor en model du kan køre.")
            ForEach(orderedCatalog, content: modelCard)
        }
    }

    private func modelCard(_ entry: PhoneModels.Entry) -> some View {
        let direct = PhoneModelDownloads.shared.directModelID == entry.id
        let downloading = direct || (downloader.downloadingModelId == entry.id && downloader.isDownloading)
        let preparing = !downloading && (requestedDownloadID == entry.id || PhoneModelDownloads.shared.preparingModelID == entry.id)
        let supported = PhoneModels.supportsLocalInference(entry.id)
        let ready = PhoneModels.isReady(entry.id)
        let onDisk = storage?.text[entry.id]
        let status = catalogStatus(downloading, preparing, ready, supported, onDisk != nil)
        return FadedCard(accent: selected == entry.id && ready ? palette.lime : nil) {
            VStack(alignment: .leading, spacing: 10) {
                modelHeader(entry.name, icon: "cpu", id: entry.id, ready: ready)
                ViewThatFits(in: .horizontal) {
                    HStack {
                        status
                        if entry.recommendsPC { FadedBadge("PC anbefales", tone: .warning) }
                    }
                    VStack(alignment: .leading) {
                        status
                        if entry.recommendsPC { FadedBadge("PC anbefales", tone: .warning) }
                    }
                }
                FadedDetailText("\(entry.packageFormat.rawValue) · ca. \(ModelDiskStorage.gigabytes(entry.estimatedDownloadBytes)) at hente.\n\(entry.description)")
                Text("Bedst til: \(entry.bestFor)").font(.subheadline)
                if downloading {
                    downloadProgress(direct: direct)
                } else if preparing {
                    ProgressView("Klargør download…")
                    FadedSecondaryButton("Annuller download", icon: "xmark", role: .destructive) { PhoneModelDownloads.shared.cancel() }
                } else if let reason = entry.unavailableReason {
                    FadedDetailText(reason)
                } else if ready && selected != entry.id {
                    FadedSecondaryButton("Brug modellen", icon: "checkmark") { select(entry.id) }
                } else if !ready, supported {
                    FadedSecondaryButton(onDisk == nil ? "Hent og vælg" : "Reparér og vælg", icon: "arrow.down.circle") {
                        if entry.recommendsPC { downloadConfirmation = entry }
                        else { download(entry) }
                    }.disabled(mutationBusy)
                }
                if let bytes = onDisk {
                    storageActions(entry.name, id: entry.id, bytes: bytes)
                }
                if allowsImageDownloads, let source = entry.modelCardURL {
                    Link("Modelkort på Hugging Face", destination: source)
                        .font(.footnote).frame(minHeight: 44, alignment: .leading)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func catalogStatus(_ downloading: Bool, _ preparing: Bool, _ ready: Bool, _ supported: Bool, _ partial: Bool) -> FadedBadge {
        if downloading { return FadedBadge("Henter", tone: .info) }
        if preparing { return FadedBadge("Klargør", tone: .info) }
        if ready { return FadedBadge("Gemt på telefonen", tone: .success) }
        if !supported { return FadedBadge("Utilgængelig", tone: .warning) }
        if partial { return FadedBadge("Ufuldstændig", tone: .warning) }
        return FadedBadge("Ikke hentet", tone: .info)
    }

    private func downloadProgress(direct: Bool) -> some View {
        let progress = min(1, max(0, direct ? PhoneModelDownloads.shared.directProgress : downloader.progress))
        return VStack(alignment: .leading, spacing: 8) {
            FadedProgress(value: progress)
            Text("Henter modellen · \(progress.formatted(.percent.precision(.fractionLength(0))))")
                .font(.caption.monospacedDigit()).foregroundStyle(palette.secondary)
            Text(direct ? "Hold appen åben. Færdige filer genbruges, hvis du afbryder." : "Download fortsætter normalt i baggrunden, når iOS tillader det.")
                .font(.caption).foregroundStyle(palette.secondary)
            FadedSecondaryButton("Annuller download", icon: "xmark", role: .destructive) {
                PhoneModelDownloads.shared.cancel()
                storageRevision += 1
            }
        }
    }

    private func modelHeader(_ title: String, icon: String, id: String, ready: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).font(.title3).foregroundStyle(palette.cyan)
                .frame(width: 40, height: 40).background(palette.raised, in: .rect(cornerRadius: 10))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                if selected == id && ready {
                    Label("Valgt", systemImage: "checkmark.circle.fill").font(.caption)
                        .foregroundStyle(palette.isDark ? palette.lime : palette.text)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            favoriteButton(id)
        }
    }

    private func modelStatus(_ title: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7).accessibilityHidden(true)
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(palette.isDark ? color : palette.text)
        }
        .padding(.horizontal, 8).padding(.vertical, 4).background(palette.raised, in: .capsule)
    }

    private func storageActions(_ name: String, id: String, bytes: Int64) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("På telefonen: \(ModelDiskStorage.gigabytes(bytes))").font(.caption).foregroundStyle(palette.secondary)
            FadedSecondaryButton("Slet model", icon: "trash", role: .destructive) {
                deleteTarget = .text(id: id, name: name)
            }.disabled(mutationBusy).accessibilityLabel("Slet \(name)")
        }
    }

    private var importSection: some View {
        let installed = PhoneModels.isReady("imported")
        let hasFiles = FileManager.default.fileExists(atPath: PhoneModels.importedFolder.path)
        return FadedCard(accent: selected == "imported" && installed ? palette.lime : nil) {
            VStack(alignment: .leading, spacing: 10) {
                FadedSectionLabel("Importér fra Filer")
                Text("Gem modellen via AirDrop eller en filserver i Filer. Pak ZIP-filen ud, og vælg hele Core ML-modelmappen.")
                    .font(.caption).foregroundStyle(palette.secondary)
                FadedPrimaryButton("Vælg modelmappe", icon: "folder") { importing = true }.disabled(mutationBusy)
                if working { ProgressView("Arbejder…") }
                if hasFiles {
                    modelHeader("Importeret model", icon: "tray.and.arrow.down", id: "imported", ready: installed)
                    modelStatus(installed ? "Klar" : "Ufuldstændig eller inkompatibel", color: installed ? palette.green : palette.secondary)
                    if installed && selected != "imported" {
                        FadedSecondaryButton("Brug importeret model", icon: "checkmark") { select("imported") }
                    }
                    if let bytes = storage?.text["imported"] {
                        storageActions("Importeret model", id: "imported", bytes: bytes)
                    } else {
                        FadedSecondaryButton("Slet importeret model", icon: "trash", role: .destructive) {
                            deleteTarget = .text(id: "imported", name: "Importeret model")
                        }.disabled(mutationBusy)
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private var imageFilesSection: some View {
        if let files = storage?.files, !files.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                FadedSectionLabel("Billedmodelfiler og LoRA")
                Text("Billedmodeller kan dele filer. Når du sletter en delt fil, kan den skulle hentes igen for andre modeller.")
                    .font(.caption).foregroundStyle(palette.secondary)
                ForEach(files, content: imageFileCard)
            }
        }
    }

    private func imageFileCard(_ file: ModelDiskStorage.Item) -> some View {
        FadedCard {
            VStack(alignment: .leading, spacing: 10) {
                Label(file.name, systemImage: "photo.on.rectangle").font(.headline)
                Text("\(file.kind) · \(ModelDiskStorage.gigabytes(file.bytes))").font(.caption).foregroundStyle(palette.secondary)
                FadedSecondaryButton("Slet fil", icon: "trash", role: .destructive) { deleteTarget = .image(file) }
                    .accessibilityLabel("Slet \(file.name)").disabled(mutationBusy)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var benchmarkSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            benchmarkCard
            FadedCard {
                VStack(alignment: .leading, spacing: 8) {
                    FadedSectionLabel("Batteri")
                    Toggle("Skift automatisk til lille model ved under 20 % batteri", isOn: $liteBattery)
                    if liteBattery && PhoneModels.installedDirectory(ModelDownloader.ModelInfo.lfm2_5_350m.id) == nil {
                        Text("Hent LFM2.5 350M for at bruge batteritilstanden.")
                            .font(.caption).foregroundStyle(palette.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var benchmarkCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            FadedSectionHeader("Benchmark", detail: "Mål den valgte model direkte på telefonen.")
            FadedPrimaryButton(benchmarkRunning ? "Måler…" : "Start benchmark", icon: "speedometer", action: benchmark)
                .disabled(mutationBusy || !PhoneModels.isReady(selected))
            if !PhoneModels.isReady(selected) {
                Text("Vælg en klar model for at måle hastigheden.").font(.caption).foregroundStyle(palette.secondary)
            }
            if let benchmarkResult {
                Text(benchmarkResult).font(.system(.headline, design: .monospaced)).foregroundStyle(palette.text)
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(FadedSpacing.edge)
        .background(LinearGradient(colors: [palette.lime.opacity(0.19), palette.card, palette.purple.opacity(0.15)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing), in: .rect(cornerRadius: 20))
        .overlay { RoundedRectangle(cornerRadius: 20).strokeBorder(palette.lime.opacity(0.28)) }
    }
    private func select(_ id: String) {
        guard PhoneModels.isReady(id) else { return }
        selected = id
        benchmarkResult = nil
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
        guard let model = entry.model, PhoneModels.supportsLocalInference(model.id), !mutationBusy else { return }
        if PhoneModels.isReady(model.id) { select(model.id); return }
        guard PhoneModels.hasDownloadSpace(bytes: entry.minimumFreeBytes) else {
            notice = "Modellen kræver mindst \(ModelDiskStorage.gigabytes(entry.minimumFreeBytes)) fri lagerplads under installation. Frigør plads, og prøv igen."
            return
        }
        requestedDownloadID = model.id
        notice = nil
        downloadSuccess = nil
        Task {
            defer { requestedDownloadID = nil; storageRevision += 1 }
            do {
                try await PhoneModelDownloads.shared.download(model)
                downloadSuccess = "\(entry.name) er hentet og klar."
            } catch is CancellationError { AppDiagnostics.record(CancellationError()); notice = "Download annulleret." }
            catch { AppDiagnostics.record(error); notice = "Modellen kunne ikke hentes. Tjek internet og ledig plads, og prøv igen." }
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
            } catch let error as CocoaError where error.code == .fileWriteOutOfSpace {
                AppDiagnostics.record(error)
                notice = "Der er ikke nok ledig plads til at importere modellen."
            } catch {
                AppDiagnostics.record(error)
                notice = "Importen mislykkedes. Vælg en udpakket Core ML-modelmappe med konfiguration og tokenizer."
            }
        }
    }

    private func refreshStorage() async {
        var textFolders: [String: URL] = [:]
        let root = ModelDiskStorage.textRoot.resolvingSymlinksInPath().standardizedFileURL
        for entry in PhoneModels.catalog {
            guard let model = entry.model else { continue }
            let folder = root.appendingPathComponent(model.folderName, isDirectory: true)
            guard folder.path == folder.resolvingSymlinksInPath().path,
                  let flags = try? folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  flags.isDirectory == true, flags.isSymbolicLink != true else { continue }
            textFolders[entry.id] = folder
        }
        if FileManager.default.fileExists(atPath: PhoneModels.importedFolder.path) { textFolders["imported"] = PhoneModels.importedFolder }
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
            } catch LocalComputeError.busy { AppDiagnostics.record(LocalComputeError.busy); notice = "Vent til den lokale AI-opgave er færdig." }
            catch { AppDiagnostics.record(error); notice = "Modelfilen kunne ikke slettes." }
        }
    }

    private func benchmark() {
        guard !mutationBusy, PhoneModels.isReady(selected) else { return }
        let id = selected
        benchmarkRunning = true
        benchmarkResult = nil
        Task {
            defer { benchmarkRunning = false }
            do {
                let result = try await PhoneModels.benchmark(modelID: id)
                if selected == id { benchmarkResult = result }
            } catch LocalComputeError.busy { AppDiagnostics.record(LocalComputeError.busy); notice = "Vent til den lokale AI-opgave er færdig." }
            catch LocalComputeError.lowMemory { AppDiagnostics.record(LocalComputeError.lowMemory); notice = "Der er for lidt ledig hukommelse til benchmark lige nu." }
            catch { AppDiagnostics.record(error); notice = "Benchmark kunne ikke gennemføres. Vælg en klar model og prøv igen." }
        }
    }
}
