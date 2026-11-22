import ImageIO
import Kingfisher
import PhotosUI
import SwiftUI
import UIKit

/// Only ordinary gallery originals can supply a thumbnail. No disk storage is opened.
@MainActor final class StudioGalleryThumbnailCache {
    static let shared = StudioGalleryThumbnailCache()
    private struct Version: Equatable, Sendable {
        let size: Int
        let modified: Date
        let inode: UInt64
    }
    private struct Preview: CacheCostCalculable, Sendable {
        let version: Version
        let image: CGImage
        var cacheCost: Int { image.bytesPerRow * image.height }
    }
    private let storage = MemoryStorage.Backend<Preview>(config: .init(totalCostLimit: 12 * 1_048_576))
    private var generation = UUID()

    func image(for file: URL, in folder: URL,
               decode: @escaping @Sendable (URL) -> CGImage? = { StudioGalleryThumbnailCache.decode($0) }) async -> CGImage? {
        guard !Task.isCancelled, file.isFileURL, file.pathExtension.lowercased() == "png",
              file.deletingLastPathComponent().standardizedFileURL.path == folder.standardizedFileURL.path,
              let source = try? LocalFileStore.safeWriteURL(file, within: folder),
              let version = Self.version(of: source) else { return nil }
        let key = source.path
        if let cached = storage.value(forKey: key), cached.version == version { return cached.image }
        let ticket = generation
        let reader = Task.detached(priority: .utility) { Task.isCancelled ? nil : decode(source) }
        let image = await withTaskCancellationHandler { await reader.value } onCancel: { reader.cancel() }
        guard !Task.isCancelled, ticket == generation, let image,
              Self.version(of: source) == version else { return nil }
        storage.store(value: Preview(version: version, image: image), forKey: key)
        return image
    }

    func remove(_ file: URL) {
        guard let source = try? LocalFileStore.safeWriteURL(file, within: file.deletingLastPathComponent()) else { return }
        storage.remove(forKey: source.path)
    }

    func clear() {
        generation = UUID()
        storage.removeAll()
    }

    private static func version(of file: URL) -> Version? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let bytes = attributes[.size] as? NSNumber, (1...80_000_000).contains(bytes.intValue),
              let date = attributes[.modificationDate] as? Date,
              let number = attributes[.systemFileNumber] as? NSNumber else { return nil }
        return Version(size: bytes.intValue, modified: date, inode: number.uint64Value)
    }

    nonisolated static func decode(_ file: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true, kCGImageSourceThumbnailMaxPixelSize: 384
        ] as CFDictionary)
    }
}

enum StudioPCImageModel: String, CaseIterable, Identifiable {
    case realvis, pony, flux2, flux2Adult = "flux2-adult"
    var id: Self { self }
    var isFlux: Bool { self == .flux2 || self == .flux2Adult }
    var title: String {
        switch self {
        case .realvis: "RealVisXL"
        case .pony: "CyberRealistic Pony · voksen"
        case .flux2: "FLUX 2 · redigering"
        case .flux2Adult: "FLUX 2 · voksen"
        }
    }
}

enum StudioPCImageCatalog {
    case checking
    case unreachable
    case available(flux: Bool, adult: Bool, pony: Bool)

    static func inspect(_ api: LiveAPI) async -> Self {
        do {
            let (flux, adult, pony) = try await api.privateStudioFluxAvailable()
            return .available(flux: flux, adult: adult, pony: pony)
        } catch {
            return .unreachable
        }
    }

    func allows(_ model: StudioPCImageModel) -> Bool {
        // Preserve access to the old RealVisXL route on existing PC installs.
        if model == .realvis { return true }
        guard case let .available(flux, adult, pony) = self else { return false }
        switch model {
        case .realvis: return true
        case .flux2: return flux
        case .flux2Adult: return adult
        case .pony: return pony
        }
    }

    func pairModel(preferred: StudioPCImageModel) -> StudioPCImageModel? {
        if preferred.isFlux && allows(preferred) { return preferred }
        return [.flux2, .flux2Adult].first(where: allows)
    }

    var showsRetry: Bool {
        switch self {
        case .checking: return false
        case .unreachable: return true
        case let .available(flux, adult, pony): return !flux || !adult || !pony
        }
    }

    func blocker(for model: StudioPCImageModel) -> String? {
        guard !allows(model) else { return nil }
        switch self {
        case .checking: return "Tjekker billedmodeller på PC’en…"
        case .unreachable: return "Kunne ikke tjekke modellerne. Tjek forbindelsen til PC’en."
        case .available: return "\(model.title) er ikke klar. Tjek billedmotoren, eller vælg en anden model."
        }
    }
}

struct StudioPCImageModelPicker: View {
    @Binding var selection: StudioPCImageModel
    let catalog: StudioPCImageCatalog
    let refresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("Billedmodel på PC", selection: $selection) {
                ForEach(StudioPCImageModel.allCases) { model in
                    Text(model.title + (catalog.allows(model) ? "" : " · ikke klar"))
                        .tag(model)
                        .disabled(!catalog.allows(model))
                }
            }
            .pickerStyle(.menu)
            .frame(minHeight: 44)
            if catalog.showsRetry {
                Button("Kontrollér PC igen", systemImage: "arrow.clockwise", action: refresh)
                    .frame(minHeight: 44)
            }
        }
    }
}

extension OfflineStudio {
    func privateTurn(_ turn: PrivateChatTurn) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Spacer(minLength: 46)
                VStack(alignment: .trailing, spacing: 6) {
                    if let photo = sentChatPhotos[turn.id] { ChatPhotoPreview(data: photo) }
                    Text(turn.prompt).foregroundStyle(FadedColors.deep)
                }
                    .padding(12).background(palette.purple, in: RoundedRectangle(cornerRadius: 16))
            }
            VStack(alignment: .leading, spacing: 8) {
                Label(turn.source ?? "Privat bot", systemImage: turn.imageName == nil ? "heart.fill" : "photo")
                    .font(.caption.bold()).foregroundStyle(palette.isDark ? palette.purple : palette.text)
                if !turn.reply.isEmpty {
                    ChatTranscriptView(reply: turn.reply, privatePresentation: privateSession)
                    if turn.imageName == nil {
                        let reading = isStudioReading(.reply(turn.id))
                        Button(studioReadTitle(turn), systemImage: reading ? "stop.circle" : "speaker.wave.2") {
                            readReply(turn)
                        }
                            .frame(minHeight: 44)
                            .disabled(task != nil)
                    }
                }
                if let issue = privateReplyIssues[turn.id] {
                    FadedDetailText(issue)
                    if !hasPrompt {
                        FadedSecondaryButton("Brug som kladde", icon: "square.and.pencil") {
                            prompt = turn.prompt
                            promptFocused = true
                        }.disabled(task != nil)
                    }
                }
                if let name = turn.imageName {
                    let file = studioImageURL(name)
                    if let image = studioThumbnail(file, maxPixelSize: 1024) {
                        Image(uiImage: image).resizable().scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                            .accessibilityLabel("Genereret billede")
                        HStack {
                            if !privateSession {
                                ShareLink(item: file) { Label("Del", systemImage: "square.and.arrow.up") }
                            }
                            imageTurnActions(file)
                            Button("Slet", systemImage: "trash", role: .destructive) { pendingImageDeletion = file }
                        }.frame(minHeight: 44)
                    } else {
                        Text("Billedet er slettet.").foregroundStyle(.secondary)
                    }
                }
                Button("Slet samtaleled", systemImage: "trash", role: .destructive) {
                    deleteTurn(turn.id)
                }.frame(minHeight: 44).disabled(task != nil)
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(palette.text)
            .background(palette.card, in: RoundedRectangle(cornerRadius: 18))
            .overlay(alignment: .leading) {
                Capsule().fill(palette.purple).frame(width: 4).padding(.vertical, 8).accessibilityHidden(true)
            }
        }.id(turn.id)
    }

    var imageReferencePicker: some View {
        HStack(spacing: 8) {
            if let baseImage, let preview = UIImage(data: baseImage) {
                Image(uiImage: preview).resizable().scaledToFill()
                    .frame(width: 44, height: 44).clipShape(.rect(cornerRadius: 8))
                    .accessibilityLabel("Valgt referencebillede")
            }
            PhotosPicker(selection: $basePhoto, matching: .images, photoLibrary: .shared()) {
                Label(baseImage == nil ? "Tilføj referencebillede" : "Skift referencebillede", systemImage: "photo.badge.plus")
                    .frame(minHeight: 44)
            }
            .disabled(task != nil && !generatingImages)
            if loadingBaseImage { ProgressView().accessibilityLabel("Henter referencebillede") }
            if baseImage != nil || loadingBaseImage {
                Button("Fjern referencebillede", systemImage: "xmark") {
                    basePhoto = nil
                    setReferenceImage(nil)
                }.labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
            }
        }
        .task(id: basePhoto) { await loadBasePhoto() }
    }

    private func loadBasePhoto() async {
        guard let item = basePhoto else { loadingBaseImage = false; return }
        loadingBaseImage = true
        defer { if basePhoto == item { loadingBaseImage = false } }
        do {
            let photo = try await item.loadTransferable(type: StudioPhotoInput.self)
            try Task.checkCancellation()
            guard basePhoto == item else { return }
            guard let photo else { throw CocoaError(.fileReadCorruptFile) }
            setReferenceImage(photo.data)
            basePhoto = nil; loadingBaseImage = false
            status = ""
        } catch is CancellationError {
            return
        } catch {
            AppDiagnostics.record(error)
            if basePhoto == item {
                setReferenceImage(nil)
                status = "Billedet kunne ikke læses fra Fotos."
            }
        }
    }

    func privateImageModelMenu(current: String) -> some View {
        let installed = StudioImageModel.allCases.filter { isImageModelReady($0.id) }
        let onPC = sessionPreferences.imageRoute == .pc
        return Menu {
            ForEach(installed) { model in
                Button {
                    sessionPreferences.imageRoute = .phone
                    sessionPreferences.imageModel = model.id
                } label: {
                    Label("iPhone · " + model.title, systemImage: !onPC && current == model.id ? "checkmark" : "iphone")
                }
            }
            if privateImagePC != nil {
                Button { sessionPreferences.imageRoute = .pc } label: {
                    Label("Brug PC", systemImage: onPC ? "checkmark" : "desktopcomputer")
                }
            }
            Button("Hent billedmodeller til iPhone", systemImage: "arrow.down.circle") {
                imagePromptFocused = false
                showImageDownloads = true
            }
        } label: {
            Label(onPC ? "PC" : "iPhone · " + (StudioImageModel(rawValue: current)?.title ?? "Vælg model"),
                  systemImage: "chevron.down")
                .font(.caption.weight(.semibold)).frame(minHeight: 44)
        }
        .accessibilityHint("Vælg billedmodel og enhed, eller hent en model til iPhone.")
        .disabled(task != nil)
    }

    var privateImageControls: some View {
        let request = studioImageRequest
        return VStack(alignment: .leading, spacing: 8) {
            privateImageModelMenu(current: request.model)
            if request.route == .pc, let api = privateImagePC {
                privatePCModelPicker
                PCImageEngineStatusRow(api: api, refreshCount: pcImageRefresh)
                FadedDetailText(baseImage == nil ? "Beskrivelsen sendes til din parrede PC."
                                : "Dine valgte fotos sendes til din parrede PC, når du laver billedet.")
            }
            if imagePromptFocused && baseImage == nil { imagePromptSuggestions }
            imageReferencePicker
            if baseImage != nil {
                if secondBaseImage != nil || (request.supportsReferencePair && referenceMask == nil
                    && (request.route == .pc || isImageModelReady(request.model))) {
                    ChatPhotoPicker(photo: $secondBaseImage, loading: $loadingSecondBase, onError: { status = $0 },
                                    addTitle: "Tilføj foto 2", replaceTitle: "Skift foto 2")
                }
                if secondBaseImage == nil { privateReferenceOptions }
                else if request.supportsReferencePair {
                    FadedDetailText("Foto 1 er udgangspunktet. Beskriv, hvad du vil bruge fra foto 2.")
                    if request.route != .pc { FadedDetailText("Begge fotos behandles på din iPhone.") }
                }
            }
            if let blocker = imageBlocker(for: request) {
                FadedDetailText(blocker).accessibilityAddTraits(.updatesFrequently)
            }
            if task != nil {
                FadedSecondaryButton("Stop billedkø", icon: "stop.fill") { stopStudioImageQueue() }
            }
            if privateImagePC != nil {
                FadedSecondaryButton("Åbn Video på PC", icon: "film") { openPrivateVideo() }
                    .disabled(task != nil)
            }
        }
    }

    func privateChatPhotoActions(_ photo: Data) -> some View {
        let request = studioImageRequest
        let onPC = request.route == .pc
        let canUsePair = onPC
            ? privateImagePC != nil && pcImageCatalog.pairModel(preferred: request.pcModel) != nil
            : request.supportsReferencePair && isImageModelReady(request.model)
        return VStack(alignment: .leading, spacing: 4) {
            privateImageModelMenu(current: request.model)
            if secondChatPhoto != nil || canUsePair {
                ChatPhotoPicker(photo: $secondChatPhoto, loading: $loadingSecondChatPhoto, onError: { status = $0 },
                                addTitle: "Tilføj foto 2", replaceTitle: "Skift foto 2")
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { privateChatMediaButtons(photo) }
                VStack(alignment: .leading, spacing: 4) { privateChatMediaButtons(photo) }
            }
            if secondChatPhoto != nil {
                if canUsePair {
                    FadedDetailText(onPC
                        ? "Beskriv, hvad du vil bruge fra foto 2. Tryk Send for at lave billedet på din parrede PC."
                        : "Beskriv, hvad du vil bruge fra foto 2. Tryk Send for at lave billedet på din iPhone.")
                } else {
                    FadedDetailText("Vælg en klar FLUX-model i billedmenuen for at bruge begge fotos.")
                }
            } else if canUsePair {
                FadedDetailText("Spørg om fotoet, eller skriv fx »Gør baggrunden blå«. Du kan også tilføje foto 2.")
            } else {
                FadedDetailText("Spørg om fotoet, eller beskriv en ændring. Vælg FLUX i billedmenuen for at bruge to fotos.")
            }
        }
        .task(id: privateImagePC?.queueTargetID) {
            guard let api = privateImagePC else { pcImageCatalog = .unreachable; return }
            let catalog = await StudioPCImageCatalog.inspect(api)
            if !Task.isCancelled { pcImageCatalog = catalog }
        }
    }

    @ViewBuilder private func privateChatMediaButtons(_ photo: Data) -> some View {
        FadedSecondaryButton("Lav billede", icon: "photo.badge.plus") {
            guard canShowStudio, !loadingChatPhoto else { return }
            dictation.stop()
            promptFocused = false
            let description = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            if !description.isEmpty { imagePrompt = String(description.prefix(2_000)) }
            setReferenceImage(photo)
            secondBaseImage = secondChatPhoto
            if secondChatPhoto != nil, sessionPreferences.imageRoute == .pc,
               let model = pcImageCatalog.pairModel(preferred: sessionPreferences.pcImageModel) {
                sessionPreferences.pcImageModel = model
            }
            studioPage = .images
            resetIdleTimer()
        }
        .disabled(loadingChatPhoto || loadingSecondChatPhoto)
        FadedSecondaryButton("Lav video", icon: "video") { openPrivateVideo(chatPhoto: photo) }
            .disabled(loadingChatPhoto || loadingSecondChatPhoto || secondChatPhoto != nil || privateImagePC == nil)
    }

    func openPrivateVideo(from result: URL? = nil, chatPhoto: Data? = nil) {
        guard privateSession, canShowStudio, privateImagePC != nil, task == nil else { return }
        dictation.stop()
        imagePromptFocused = false
        promptFocused = false
        privateVideoSource = result
        privateVideoChatInput = chatPhoto.map { photo in (photo, String(prompt.prefix(1_000))) }
        resetIdleTimer()
        showPrivateVideo = true
    }

    var imagePromptSuggestions: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(["masterpiece", "cinematic", "blødt lys", "detaljeret"], id: \.self) { suggestion in
                    Button(suggestion) {
                        let current = imagePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
                        let combined = current.isEmpty ? suggestion : current + ", " + suggestion
                        if combined.count <= 2_000 { imagePrompt = combined }
                    }.buttonStyle(.bordered).frame(minHeight: 44)
                        .accessibilityLabel("Tilføj \(suggestion) til prompt")
                }
            }
        }.scrollIndicators(.hidden)
    }
}

@MainActor struct StudioReferenceMaskEditor: View {
    let photo: UIImage
    let onActivity: () -> Void
    let onApply: (StudioReferenceMask?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var draft: StudioReferenceMask
    @State private var dragging = false

    init(photo: UIImage, mask: StudioReferenceMask?, onActivity: @escaping () -> Void,
         onApply: @escaping (StudioReferenceMask?) -> Void) {
        self.photo = photo
        self.onActivity = onActivity
        self.onApply = onApply
        _draft = State(initialValue: mask ?? StudioReferenceMask())
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                FadedDetailText("Mal hen over det, du vil ændre. Lad resten af billedet være umarkeret.")
                GeometryReader { proxy in
                    let width = min(proxy.size.width, proxy.size.height * photo.size.width / photo.size.height)
                    let size = CGSize(width: width, height: width * photo.size.height / photo.size.width)
                    Image(uiImage: photo).resizable().frame(width: size.width, height: size.height)
                        .overlay { StudioReferenceMaskOverlay(mask: draft) }
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                            addPoint(value.location, in: size)
                        }.onEnded { _ in dragging = false })
                        .clipShape(.rect(cornerRadius: 12))
                        .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
                        .accessibilityLabel("Tegn på referencebilledet")
                }
                HStack {
                    Button("Fortryd streg", systemImage: "arrow.uturn.backward") {
                        if !draft.isEmpty { draft.strokes.removeLast() }
                    }
                    Spacer()
                    Button("Ryd", role: .destructive) { draft.strokes.removeAll() }
                }
                .disabled(draft.isEmpty)
                .buttonStyle(.bordered)
            }
            .padding(FadedSpacing.edge)
            .navigationTitle("Markér området")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annullér") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(draft.isEmpty ? "Uden markering" : "Brug markering") {
                        onApply(draft.isEmpty ? nil : draft)
                        dismiss()
                    }
                }
            }
        }
    }

    private func addPoint(_ point: CGPoint, in size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let p = CGPoint(x: min(1, max(0, point.x / size.width)), y: min(1, max(0, point.y / size.height)))
        if !dragging {
            guard draft.strokes.count < 128 else { return }
            onActivity()
            draft.strokes.append([p])
            dragging = true
        } else if let index = draft.strokes.indices.last, draft.strokes[index].count < 512 {
            if let last = draft.strokes[index].last, hypot(last.x - p.x, last.y - p.y) >= 0.005 {
                draft.strokes[index].append(p)
            }
        }
    }
}

struct StudioReferenceMaskOverlay: View {
    let mask: StudioReferenceMask

    var body: some View {
        Canvas { context, size in
            let brush = StudioReferenceMask.brushWidth * min(size.width, size.height)
            for stroke in mask.strokes {
                let points = stroke.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }
                guard let first = points.first else { continue }
                let color = Color.mint.opacity(0.65)
                if points.count == 1 {
                    let dot = CGRect(x: first.x - brush / 2, y: first.y - brush / 2, width: brush, height: brush)
                    context.fill(Path(ellipseIn: dot), with: .color(color))
                } else {
                    var path = Path()
                    path.addLines(points)
                    context.stroke(path, with: .color(color),
                                   style: StrokeStyle(lineWidth: brush, lineCap: .round, lineJoin: .round))
                }
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}

struct StudioImageDownloadProgress: View {
    @State private var confirmStop = false
    @State private var transferToStop: UUID?

    var body: some View {
        let downloads = StudioImageDownloads.shared
        if downloads.isInterrupted {
            if let notice = downloads.notice { FadedDetailText(notice) }
            if downloads.isUserPaused, let progress = downloads.progress {
                ProgressView(value: progress) { Text("Hentet · \(Int(progress * 100)) %") }
            }
            FadedSecondaryButton(downloads.isWaitingForModelCheck ? "Fortsæt modelkontrol" : "Fortsæt download",
                                 icon: "arrow.down.circle") { downloads.resume() }
        } else if let label = downloads.validationLabel {
            ProgressView(label)
        } else if let progress = downloads.progress, progress < 1 {
            ProgressView(value: progress) { Text("Henter · \(Int(progress * 100)) %") }
        } else {
            ProgressView(downloads.progress == 1 ? "Kontrollerer billedmodellen…" : "Henter billedmodellen…")
        }
        if !downloads.isInterrupted || downloads.isWaitingForModelCheck {
            FadedSecondaryButton("Sæt på pause", icon: "pause.fill") { downloads.pause() }
        }
        FadedSecondaryButton("Annuller hentning", icon: "xmark", role: .destructive) {
            transferToStop = downloads.transferID
            confirmStop = true
        }
            .confirmationDialog("Annuller hentningen?", isPresented: $confirmStop, presenting: transferToStop) { id in
                Button("Annuller hentning", role: .destructive) { if downloads.transferID == id { downloads.cancel() } }
                Button("Tilbage", role: .cancel) {}
            } message: { _ in
                Text("Filer, der er installeret, bevares. Midlertidige filer fjernes. Vælg pause, hvis du vil fortsætte senere.")
            }
    }

}
