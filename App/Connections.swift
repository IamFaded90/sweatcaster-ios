import CoreTransferable
import Foundation
import ImageIO
import Observation
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum ConnectorStatus: Equatable {
    case ready, selected(Int), unavailable

    var title: String {
        switch self {
        case .ready: "Klar til at vælge"
        case .selected(let count): "\(count) valgt"
        case .unavailable: "Ikke tilgængelig"
        }
    }
}

struct ConnectorItem: Identifiable, Sendable {
    let id: UUID
    let name: String
    let size: Int
}

@MainActor protocol Connector: AnyObject {
    var id: String { get }
    var name: String { get }
    var icon: String { get }
    var status: ConnectorStatus { get }

    func connect() async throws
    func disconnect() async
    func list(path: String) async throws -> [ConnectorItem]
    func search(query: String) async throws -> [ConnectorItem]
    func fetch(id: UUID) async throws -> Data
    func upload(data: Data, path: String) async throws
}

private enum PickerConnectorError: Error, Equatable {
    case invalidFile, tooLarge, unknownItem, selectionOnly, readOnly
}

private struct ConnectorPhoto: Transferable {
    let data: Data

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            let url = received.file
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { throw PickerConnectorError.invalidFile }
            guard let size = values.fileSize, (1...80_000_000).contains(size) else { throw PickerConnectorError.tooLarge }
            guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
                throw PickerConnectorError.invalidFile
            }
            return ConnectorPhoto(data: try jpegPreview(from: source))
        }
    }

    static func preview(for data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let identifier = CGImageSourceGetType(source), UTType(identifier as String)?.conforms(to: .image) == true,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
              let height = properties[kCGImagePropertyPixelHeight as String] as? Int,
              (1...12_000).contains(width), (1...12_000).contains(height), width * height <= 80_000_000 else {
            return nil
        }
        return try? jpegPreview(from: source)
    }

    private static func jpegPreview(from source: CGImageSource) throws -> Data {
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 640
        ] as CFDictionary) else { throw PickerConnectorError.invalidFile }
        let bytes = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(bytes as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw PickerConnectorError.invalidFile
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw PickerConnectorError.invalidFile }
        return bytes as Data
    }
}

@MainActor @Observable final class PickerConnector: Connector {
    enum Source { case photos, files }

    struct Record: Identifiable {
        let item: ConnectorItem
        let data: Data
        let photoPreview: Data?
        var id: UUID { item.id }
    }

    let source: Source
    var showPicker = false
    private(set) var records: [Record] = []
    private(set) var notice: String?
    private(set) var loading = false
    private var readTask: Task<Void, Never>?

    init(source: Source) { self.source = source }

    var id: String { source == .photos ? "apple-photos" : "icloud-files" }
    var name: String { source == .photos ? "Apple Fotos" : "Filer" }
    var icon: String { source == .photos ? "photo.on.rectangle" : "folder" }
    var status: ConnectorStatus { records.isEmpty ? .ready : .selected(records.count) }

    func connect() async throws { showPicker = true }

    func disconnect() async {
        readTask?.cancel()
        readTask = nil
        showPicker = false
        records = []
        notice = nil
        loading = false
    }

    func list(path: String) async throws -> [ConnectorItem] {
        guard path.isEmpty || path == "/" else { throw PickerConnectorError.selectionOnly }
        return records.map(\.item)
    }

    func search(query: String) async throws -> [ConnectorItem] {
        let items = try await list(path: "")
        return query.isEmpty ? items : items.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    func fetch(id: UUID) async throws -> Data {
        guard let record = records.first(where: { $0.id == id }) else { throw PickerConnectorError.unknownItem }
        return record.data
    }

    func upload(data: Data, path: String) async throws { throw PickerConnectorError.readOnly }

    func pickPhotos(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        startRead {
            var selected: [Record] = []
            for (index, item) in items.prefix(3).enumerated() {
                try Task.checkCancellation()
                guard let photo = try await item.loadTransferable(type: ConnectorPhoto.self) else {
                    throw PickerConnectorError.invalidFile
                }
                selected.append(Self.record(name: "Foto \(index + 1)", data: photo.data, photoPreview: photo.data))
            }
            return selected
        }
    }

    func pickFile(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            startRead {
                let reader = Task.detached(priority: .userInitiated) {
                    try Task.checkCancellation()
                    let data = try Self.readFile(url)
                    try Task.checkCancellation()
                    return (data, ConnectorPhoto.preview(for: data))
                }
                let (data, preview) = try await withTaskCancellationHandler {
                    try await reader.value
                } onCancel: {
                    reader.cancel()
                }
                return [Self.record(name: url.lastPathComponent, data: data, photoPreview: preview)]
            }
        case .failure(let error):
            guard (error as? CocoaError)?.code != .userCancelled else { return }
            AppDiagnostics.record(error)
            notice = "Filer kunne ikke åbne dit valg. Tryk på Vælg fil for at prøve igen."
        }
    }

    private func startRead(_ work: @escaping @MainActor () async throws -> [Record]) {
        readTask?.cancel()
        loading = true
        notice = nil
        readTask = Task {
            defer {
                if !Task.isCancelled {
                    loading = false
                    readTask = nil
                }
            }
            do {
                let items = try await work()
                try Task.checkCancellation()
                records = items
            } catch {
                AppDiagnostics.record(error)
                guard !Task.isCancelled else { return }
                notice = (error as? PickerConnectorError) == .tooLarge
                    ? "Filen er for stor til en lokal forhåndsvisning."
                    : "Det valgte indhold kunne ikke læses. Prøv at vælge igen."
            }
        }
    }

    private static func record(name: String, data: Data, photoPreview: Data?) -> Record {
        Record(item: ConnectorItem(id: UUID(), name: name, size: data.count), data: data, photoPreview: photoPreview)
    }

    nonisolated private static func readFile(_ url: URL) throws -> Data {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let limit = 5_000_000
        if let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]) {
            guard values.isRegularFile != false, values.isSymbolicLink != true else { throw PickerConnectorError.invalidFile }
            if let size = values.fileSize, size > limit { throw PickerConnectorError.tooLarge }
        }
        var coordinationError: NSError?
        var read: Result<Data, Error>?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError) { coordinatedURL in
            read = Result { try LocalFileStore.readBytes(from: coordinatedURL, maximumBytes: limit) }
        }
        if let coordinationError { throw coordinationError }
        guard let read else { throw PickerConnectorError.invalidFile }
        do { return try read.get() }
        catch LocalFileStore.Failure.tooLarge { throw PickerConnectorError.tooLarge }
    }
}

struct ConnectionsView: View {
    private let onChooseNote: ((String) -> Void)?
    private let title: String
    private let pcConnected: Bool?
    private let openPairing: (() -> Void)?
    private let embyAPI: LiveAPI?
    @Environment(\.fadedPalette) private var palette
    @State private var photos = PickerConnector(source: .photos)
    @State private var files = PickerConnector(source: .files)
    @State private var photoSelection: [PhotosPickerItem] = []
    @State private var photoToAnalyze: PickerConnector.Record?

    init(title: String = "Forbindelser", pcConnected: Bool? = nil, openPairing: (() -> Void)? = nil,
         embyAPI: LiveAPI? = nil,
         onChooseNote: ((String) -> Void)? = nil) {
        self.title = title
        self.pcConnected = pcConnected
        self.openPairing = openPairing
        self.embyAPI = embyAPI
        self.onChooseNote = onChooseNote
    }

    private struct Provider: Identifiable {
        let name, icon, detail: String
        var id: String { name }
    }

    private let providers: [Provider] = [
        .init(name: "Dropbox", icon: "externaldrive", detail: "Kræver Dropbox OAuth og en registreret app."),
        .init(name: "Google Photos Picker", icon: "photo.stack", detail: "Kræver en godkendt Google OAuth-klient. Google lader ikke apps se hele biblioteket. Vælg fotos i Googles egen picker."),
        .init(name: "Spotify", icon: "music.note", detail: "Spotify-indhold kan ikke bruges som AI-kontekst under tjenestens vilkår."),
        .init(name: "Google Drive", icon: "folder", detail: "Kræver Google OAuth og tilladelse til valgte filer."),
        .init(name: "OneDrive", icon: "cloud", detail: "Kræver Microsoft-login og læseadgang til valgte filer."),
        .init(name: "GitHub", icon: "chevron.left.forwardslash.chevron.right", detail: "Kræver særskilt adgang til de repositories, du vil bruge."),
        .init(name: "Gmail", icon: "envelope", detail: "Kræver Google OAuth med godkendte mailtilladelser."),
        .init(name: "Todoist", icon: "checklist", detail: "Kræver Todoist OAuth og adgang til valgte projekter."),
        .init(name: "Notion", icon: "doc.text", detail: "Kræver en Notion-integration med adgang til valgte sider."),
        .init(name: "X", icon: "text.bubble", detail: "Kræver en X-udviklerapp og passende API-adgang."),
        .init(name: "Discord", icon: "bubble.left.and.bubble.right", detail: "Kræver en Discord-app og tilladelser i de valgte kanaler."),
        .init(name: "Slack", icon: "bubble.left", detail: "Kræver en Slack-app med læsetilladelse i dit arbejdsområde."),
        .init(name: "Trello", icon: "rectangle.split.3x1", detail: "Kræver kontoautorisation til de relevante tavler."),
        .init(name: "Figma", icon: "square.stack", detail: "Kræver Figma OAuth og adgang til de valgte filer.")
    ]

    var body: some View {
        @Bindable var photoConnector = photos
        @Bindable var fileConnector = files
        ScrollView {
            VStack(alignment: .leading, spacing: FadedSpacing.action) {
                Text(title).font(FadedTypography.title).accessibilityAddTraits(.isHeader)
                if let pcConnected, let openPairing {
                    FadedCard(size: .hero) {
                        VStack(alignment: .leading, spacing: FadedSpacing.m) {
                            HStack {
                                Image(systemName: "desktopcomputer").foregroundStyle(palette.cyan)
                                Spacer()
                                FadedBadge(pcConnected ? "Forbundet" : "Ikke forbundet",
                                           tone: pcConnected ? .success : .info)
                            }
                            Text("Din PC. Mere kraft.").font(FadedTypography.title)
                            FadedDetailText("Par din iPhone med FadedAI på din PC.")
                            Button(action: openPairing) {
                                Label("QR-login", systemImage: "qrcode")
                                    .padding(.horizontal, FadedSpacing.m)
                                    .frame(minHeight: 44)
                                    .fadedGlassSurface()
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if openPairing != nil || embyAPI != nil { embyLink }
                if openPairing != nil || embyAPI != nil {
                    NavigationLink {
                        PCServicesView(api: embyAPI)
                    } label: {
                        FadedCard {
                            VStack(alignment: .leading, spacing: FadedSpacing.s) {
                                Label("Tjenester på PC’en", systemImage: "desktopcomputer")
                                    .font(FadedTypography.action)
                                FadedDetailText("YouTube og websøgning. Se, hvad der skal sættes op på PC’en.")
                            }
                            .frame(minHeight: 44)
                        }
                    }
                    .buttonStyle(.plain)
                }
                NavigationLink {
                    AppleConnectionsView(onChooseNote: onChooseNote)
                } label: {
                    FadedCard {
                        Label("Apple og iPhone", systemImage: "iphone")
                            .frame(minHeight: 44)
                    }
                }
                .buttonStyle(.plain)
                if onChooseNote == nil && (openPairing != nil || embyAPI != nil) {
                    NavigationLink {
                        PersonalVaultView()
                    } label: {
                        FadedCard {
                            Label("Vault", systemImage: "lock.shield")
                                .frame(minHeight: 44)
                        }
                    }
                    .buttonStyle(.plain)
                }
                Text("Vælg indhold fra din telefon. Valget vises kun her i denne session.")
                    .foregroundStyle(palette.secondary)
                pickerCard(photos, detail: "Vælg op til tre billeder i Apples billedvælger. Her vises små lokale forhåndsvisninger.")
                pickerCard(files, detail: "Vælg én fil op til 5 MB fra iCloud Drive eller en anden placering i Filer. Se billeder og uddrag fra tekstfiler her.")
                DisclosureGroup("Tjenester uden direkte forbindelse") {
                    VStack(spacing: 10) { ForEach(providers) { providerCard($0) } }
                        .padding(.top, 10)
                }
            }
            .padding(FadedSpacing.edge).frame(maxWidth: 640).frame(maxWidth: .infinity)
        }
        .background { FadedBackground() }
        .foregroundStyle(palette.text)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .photosPicker(isPresented: $photoConnector.showPicker, selection: $photoSelection,
                      maxSelectionCount: 3, matching: .images)
        .onChange(of: photoSelection) { _, items in
            photos.pickPhotos(items)
            photoSelection = []
        }
        .fileImporter(isPresented: $fileConnector.showPicker, allowedContentTypes: [.data], onCompletion: files.pickFile)
        .sheet(item: $photoToAnalyze) { record in
            if let preview = record.photoPreview {
                LocalImageAnalysisView(data: preview, onChooseNote: onChooseNote)
            }
        }
    }

    private var embyLink: some View {
        NavigationLink {
            EmbyLibraryView(api: embyAPI).id(embyAPI?.queueTargetID)
        } label: {
            FadedCard {
                Label("Emby & bibliotek", systemImage: "play.rectangle")
                    .frame(minHeight: 44)
            }
        }
        .buttonStyle(.plain)
    }

    private func pickerCard(_ connector: PickerConnector, detail: String) -> some View {
        FadedCard(accent: palette.cyan) {
            VStack(alignment: .leading, spacing: 10) {
                Label(connector.name, systemImage: connector.icon).font(FadedTypography.section).accessibilityAddTraits(.isHeader)
                Text(connector.status.title).font(.caption.weight(.semibold))
                Text(detail).font(.subheadline).foregroundStyle(palette.secondary)
                FadedSecondaryButton(connector.source == .photos ? "Vælg billeder" : "Vælg fil", icon: connector.icon) {
                    Task { try? await connector.connect() }
                }.disabled(connector.loading)
                if connector.loading { ProgressView("Læser dit valg…") }
                if let notice = connector.notice { Text(notice).font(.caption).foregroundStyle(palette.secondary) }
                ForEach(connector.records) { record in
                    if let preview = record.photoPreview, let image = UIImage(data: preview) {
                        if connector.source == .files { fileLabel(record) }
                        Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 190)
                            .clipShape(RoundedRectangle(cornerRadius: FadedRadius.small))
                            .accessibilityLabel(record.item.name)
                        FadedSecondaryButton("Analysér på telefonen", icon: "text.viewfinder") {
                            photoToAnalyze = record
                        }
                    } else {
                        fileLabel(record)
                        if let excerpt = noteExcerpt(record) {
                            Text(verbatim: excerpt).font(.caption).lineLimit(4).textSelection(.enabled)
                            if let onChooseNote {
                                FadedSecondaryButton("Vedhæft tekstuddrag", icon: "note.text") { onChooseNote(excerpt) }
                            }
                        }
                    }
                }
                if !connector.records.isEmpty {
                    FadedSecondaryButton("Fjern valg", icon: "xmark") { Task { await connector.disconnect() } }
                }
            }
        }
    }

    private func fileLabel(_ record: PickerConnector.Record) -> some View {
        VStack(alignment: .leading, spacing: FadedSpacing.xs) {
            Label(record.item.name, systemImage: "doc").font(.subheadline)
            Text(ByteCountFormatter.string(fromByteCount: Int64(record.item.size), countStyle: .file))
                .font(.caption).foregroundStyle(palette.secondary)
        }
    }

    private func noteExcerpt(_ record: PickerConnector.Record) -> String? {
        let ext = (record.item.name as NSString).pathExtension.lowercased()
        guard ["txt", "md", "markdown"].contains(ext), record.data.count <= 96_000,
              let text = String(data: record.data, encoding: .utf8) else { return nil }
        let excerpt = String(text.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.prefix(600))
        return excerpt.isEmpty ? nil : excerpt
    }

    private func providerCard(_ provider: Provider) -> some View {
        FadedCard {
            VStack(alignment: .leading, spacing: 6) {
                Label(provider.name, systemImage: provider.icon).font(FadedTypography.section)
                Text(ConnectorStatus.unavailable.title).font(.caption.weight(.semibold))
                Text(provider.detail).font(.subheadline).foregroundStyle(palette.secondary)
            }
        }
    }
}
