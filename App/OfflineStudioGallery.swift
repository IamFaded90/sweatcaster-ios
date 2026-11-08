// OfflineStudioGallery.swift
// Viser billedhistorik, metadata og eksplicit eksport til Fotos.

import ImageIO
import LocalAuthentication
import Photos
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct StudioGalleryIndex: Sendable {
    var files: [URL] = []
    var dates: [URL: Date] = [:]
    var details: [URL: StudioImageDetails] = [:]
}

private struct StudioGalleryThumbnail: View {
    let file: URL
    let fallback: Color
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "photo").foregroundStyle(fallback)
            }
        }
        .task(id: file) {
            let url = file
            let reader = Task.detached(priority: .utility) { Self.readThumbnail(at: url) }
            let thumbnail = await withTaskCancellationHandler {
                await reader.value
            } onCancel: {
                reader.cancel()
            }
            guard !Task.isCancelled else { return }
            image = thumbnail.map { UIImage(cgImage: $0) }
        }
    }

    nonisolated private static func readThumbnail(at file: URL) -> CGImage? {
        guard !Task.isCancelled, (try? LocalFileStore.checkedFileSize(file, maximumBytes: 80_000_000)) != nil,
              let source = CGImageSourceCreateWithURL(file as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 384
        ] as CFDictionary)
    }
}

extension OfflineStudio {
    @ViewBuilder
    var studioGalleryPage: some View {
        let gallery = ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                studioImageHistory
                DisclosureGroup("Chat og stemme") {
                    if privateSession { sessionChatSettings.padding(.top, 10) }
                    else { privateSettings.padding(.top, 10) }
                }
                DisclosureGroup("Billedmodel og LoRA") { privateImageSettings.padding(.top, 10) }
                StudioRAMStatus()
                FadedSecondaryButton(privateSession ? "Ryd denne session" : "Ryd studiets indhold",
                                     icon: "trash", role: .destructive) { confirmStudioPanic = true }
                    .disabled(!privateSession && task != nil)
            }.padding(16)
        }
        .onScrollPhaseChange { _, phase in if phase == .interacting { resetIdleTimer() } }
        if privateSession { gallery } else { gallery.refreshable { await refreshPublicGallery() } }
    }

    func refreshPublicGallery() async {
        guard !privateSession, sessionUnlocked else { return }
        let ticket = UUID()
        galleryLoadID = ticket
        galleryError = nil
        defer { if galleryLoadID == ticket { galleryLoadID = nil } }
        let directory = historyFolder
        while !Task.isCancelled, galleryLoadID == ticket, sessionUnlocked {
            let revision = galleryMutation
            let reader = Task.detached(priority: .utility) { try Self.readGalleryIndex(at: directory) }
            do {
                let snapshot = try await withTaskCancellationHandler {
                    try await reader.value
                } onCancel: {
                    reader.cancel()
                }
                guard !Task.isCancelled, galleryLoadID == ticket, sessionUnlocked else { return }
                guard revision == galleryMutation else { continue }
                galleryIndex = snapshot
                galleryHasLoaded = true
                selectedGalleryImages.formIntersection(snapshot.files)
                normalizeGalleryTag()
                rebuildGalleryCache()
            } catch {
                guard !Task.isCancelled, galleryLoadID == ticket, sessionUnlocked else { return }
                AppDiagnostics.record(error)
                galleryError = "Galleriet kunne ikke åbnes. Lås telefonen op, og prøv igen."
            }
            return
        }
    }

    func resetPublicGallery() {
        galleryLoadID = nil
        galleryHasLoaded = false
        galleryError = nil
        galleryMutation &+= 1
        galleryIndex = StudioGalleryIndex()
        selectedGalleryImages.removeAll()
        galleryTag = ""
        rebuildGalleryCache()
    }

    nonisolated private static func readGalleryIndex(at directory: URL) throws -> StudioGalleryIndex {
        let keys: Set<URLResourceKey> = [.creationDateKey, .isRegularFileKey, .isSymbolicLinkKey]
        let candidates: [URL]
        do {
            candidates = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys))
        } catch where LocalFileStore.isMissing(error) {
            return StudioGalleryIndex()
        }
        var index = StudioGalleryIndex()
        for file in candidates where file.pathExtension == "png" {
            if Task.isCancelled { break }
            guard let values = try? file.resourceValues(forKeys: keys),
                  values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            index.files.append(file)
            index.dates[file] = values.creationDate
            if let bytes = try? LocalFileStore.readBytes(from: metadataURL(file), maximumBytes: 32_768),
               let details = try? JSONDecoder().decode(StudioImageDetails.self, from: bytes) {
                index.details[file] = details
            }
        }
        index.files.sort { $0.lastPathComponent > $1.lastPathComponent }
        return index
    }

    private func normalizeGalleryTag() {
        let details = privateSession ? transientDetails : galleryIndex.details
        if !galleryTag.isEmpty, !details.values.contains(where: { $0.tags.contains(galleryTag) }) {
            galleryTag = ""
        }
    }

    func deleteImage(_ file: URL) {
        do {
            if privateSession {
                guard privateImages.removeValue(forKey: file) != nil else { return }
            } else {
                guard file.isFileURL, file.deletingLastPathComponent() == historyFolder else { return }
                try FileManager.default.removeItem(at: file)
                try? FileManager.default.removeItem(at: Self.metadataURL(file))
                galleryMutation &+= 1
                galleryIndex.files.removeAll { $0 == file }
                galleryIndex.dates.removeValue(forKey: file)
                galleryIndex.details.removeValue(forKey: file)
            }
            transientDetails.removeValue(forKey: file)
            normalizeGalleryTag()
            rebuildGalleryCache()
            selectedGalleryImages.remove(file)
            batchImageURLs.removeAll { $0 == file }
            if imageURL == file {
                imageURL = nil
                if let first = batchImageURLs.first { selectBatchImage(first) }
            }
            pendingImageDeletion = nil
            status = "Billedet er slettet."
        } catch { AppDiagnostics.record(error); status = "Billedet kunne ikke slettes." }
    }

    nonisolated private static func metadataURL(_ file: URL) -> URL { file.appendingPathExtension("json") }

    func imageDetails(_ file: URL) -> StudioImageDetails {
        transientDetails[file] ?? galleryIndex.details[file] ?? StudioImageDetails()
    }

    func storeImageDetails(_ details: StudioImageDetails, for file: URL) {
        if privateImages[file] != nil {
            transientDetails[file] = details
            normalizeGalleryTag()
            rebuildGalleryCache()
            return
        }
        guard !privateSession, file.isFileURL, file.deletingLastPathComponent() == historyFolder,
              FileManager.default.fileExists(atPath: file.path) else { return }
        galleryMutation &+= 1
        if !galleryIndex.files.contains(file) {
            let index = galleryIndex.files.firstIndex { $0.lastPathComponent < file.lastPathComponent }
                ?? galleryIndex.files.endIndex
            galleryIndex.files.insert(file, at: index)
        }
        do {
            let bytes = try JSONEncoder().encode(details)
            guard bytes.count <= 32_768 else { throw LocalFileStore.Failure.tooLarge }
            try LocalFileStore.writeBytes(bytes, to: Self.metadataURL(file), within: historyFolder)
            galleryIndex.details[file] = details
            normalizeGalleryTag()
        } catch { AppDiagnostics.record(error); status = "Billedets oplysninger kunne ikke gemmes." }
        rebuildGalleryCache()
    }

    var filteredImageHistory: [URL] { cachedFilteredHistory }

    func rebuildGalleryCache() {
        let calendar = Calendar.current
        let now = Date()
        let startOfWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? calendar.startOfDay(for: now)
        let details = privateSession ? transientDetails : galleryIndex.details
        cachedGalleryTags = Array(Set(details.values.flatMap(\.tags))).sorted()
        cachedFilteredHistory = history.filter { file in
            let metadata = imageDetails(file)
            guard galleryTag.isEmpty || metadata.tags.contains(galleryTag) else { return false }
            switch galleryFilter {
            case .all: return true
            case .favorites: return metadata.favorite
            case .today, .week:
                let date = file.lastPathComponent.split(separator: "-").first.flatMap { Double($0) }
                    .map { Date(timeIntervalSince1970: $0 / 1000) }
                    ?? galleryIndex.dates[file]
                guard let date else { return false }
                return galleryFilter == .today ? calendar.isDate(date, inSameDayAs: now) : date >= startOfWeek && date <= now
            }
        }
    }

    private var studioImageHistory: some View {
        let files = filteredImageHistory
        let tags = cachedGalleryTags
        return LazyVStack(alignment: .leading, spacing: FadedSpacing.section) {
            FadedSectionHeader("Billedgalleri")
            if privateSession {
                Text("Op til 16 billeder i hukommelsen. De ældste ryddes ved pladsmangel.")
                    .font(.caption).foregroundStyle(palette.secondary)
            }
            if studioTypeSize.isAccessibilitySize { galleryFilterPicker.pickerStyle(.menu).frame(minHeight: 44) }
            else { galleryFilterPicker.pickerStyle(.segmented) }
            if !tags.isEmpty {
                Picker("Tag", selection: $galleryTag) {
                    Text("Alle tags").tag("")
                    ForEach(tags, id: \.self) { Text($0).tag($0) }
                }
            }
            if !files.isEmpty || selectingGalleryImages {
                Button(selectingGalleryImages ? "Afslut valg" : "Vælg flere billeder", systemImage: "checkmark.circle") {
                    selectingGalleryImages.toggle()
                    if !selectingGalleryImages { selectedGalleryImages.removeAll() }
                }.frame(minHeight: 44)
            }
            if selectingGalleryImages {
                ViewThatFits(in: .horizontal) {
                    HStack { gallerySelectionActions }
                    VStack(alignment: .leading) { gallerySelectionActions }
                }
            }
            if !privateSession, let galleryError {
                RetryNotice(message: galleryError) { Task { await refreshPublicGallery() } }
            } else if !privateSession && !galleryHasLoaded {
                LoadingSkeleton(label: "Åbner billedgalleriet…")
            } else if files.isEmpty {
                if galleryFilter != .all || !galleryTag.isEmpty {
                    FadedEmptyState(icon: "photo.on.rectangle", title: "Ingen billeder matcher",
                                    detail: "Vis alle billeder for at se resten af galleriet.", actionTitle: "Ryd filtre") {
                        galleryFilter = .all
                        galleryTag = ""
                    }
                } else {
                    FadedEmptyState(icon: "photo.on.rectangle", title: "Ingen billeder endnu",
                                    detail: "Skriv en prompt, og tryk Lav billede.", actionTitle: "Åbn Billeder") { studioPage = .images }
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: studioTypeSize.isAccessibilitySize ? 1 : 2),
                      alignment: .leading, spacing: 12) {
                ForEach(files, id: \.self) { file in galleryImageCard(file) }
            }
        }
        .onChange(of: galleryFilter) { _, _ in selectedGalleryImages.removeAll() }
        .onChange(of: galleryTag) { _, _ in selectedGalleryImages.removeAll() }
    }

    private var galleryFilterPicker: some View {
        Picker("Filter", selection: $galleryFilter) {
            ForEach(StudioGalleryFilter.allCases) { filter in Text(filter.rawValue).tag(filter) }
        }
    }

    private func galleryImageCard(_ file: URL) -> some View {
        let details = imageDetails(file)
        let selected = selectedGalleryImages.contains(file)
        let shape = RoundedRectangle(cornerRadius: 14)
        return VStack(alignment: .leading, spacing: 6) {
            Button {
                if selectingGalleryImages {
                    if selectedGalleryImages.remove(file) == nil { selectedGalleryImages.insert(file) }
                } else {
                    imageViewer = StudioImageSheet(url: file)
                }
            } label: {
                Rectangle().fill(palette.raised).aspectRatio(1, contentMode: .fit)
                    .overlay {
                        if privateSession {
                            if let image = studioThumbnail(file, maxPixelSize: 384) {
                                Image(uiImage: image).resizable().scaledToFill()
                            } else {
                                Image(systemName: "photo").foregroundStyle(palette.secondary)
                            }
                        } else {
                            StudioGalleryThumbnail(file: file, fallback: palette.secondary)
                        }
                    }
                    .clipShape(shape)
                    .overlay(alignment: .topTrailing) {
                        if selectingGalleryImages {
                            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(palette.lime).padding(8)
                        }
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(details.prompt.map { String($0.prefix(100)) } ?? "Gemt billede")
            .accessibilityAddTraits(selected ? .isSelected : [])
            Text(details.prompt.map { String($0.prefix(72)) } ?? "Gemt billede")
                .font(.caption).foregroundStyle(palette.text).lineLimit(2)
            if !details.tags.isEmpty {
                Text(details.tags.joined(separator: " · ")).font(.caption).foregroundStyle(palette.secondary).lineLimit(1)
            }
            if !selectingGalleryImages {
                if privateSession {
                    privatePhotoButton(file)
                } else {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) { publicImageActions(file) }
                        VStack(alignment: .leading, spacing: 2) { publicImageActions(file) }
                    }
                }
                imageActionMenu(file)
            }
        }
        .padding(8).background(palette.card, in: shape)
        .overlay { shape.strokeBorder(selected ? palette.lime : palette.border).allowsHitTesting(false) }
    }

    @ViewBuilder func publicImageActions(_ file: URL) -> some View {
        Button(photosSaving.contains(file) ? "Gemmer…" : "Gem", systemImage: "square.and.arrow.down") {
            saveImageToPhotos(file)
        }
        .frame(minHeight: 44)
        .accessibilityLabel("Gem billede i Fotos")
        .disabled(photosSaving.contains(file))
        ShareLink(item: file) { Label("Del", systemImage: "square.and.arrow.up").frame(minHeight: 44) }
    }

    @ViewBuilder private var gallerySelectionActions: some View {
        if !privateSession {
            Button("Del valgte (\(selectedGalleryImages.count))", systemImage: "square.and.arrow.up") {
                studioShareSheet = StudioMultiShare(files: filteredImageHistory.filter { selectedGalleryImages.contains($0) })
            }.frame(minHeight: 44).disabled(selectedGalleryImages.isEmpty)
        }
        Button("Slet valgte", systemImage: "trash", role: .destructive) { confirmGalleryDelete = true }
            .frame(minHeight: 44).disabled(selectedGalleryImages.isEmpty || task != nil)
    }

    func imageActionMenu(_ file: URL) -> some View {
        Menu("Billedhandlinger", systemImage: "ellipsis.circle") {
            if !privateSession, file.deletingLastPathComponent() == historyFolder {
                ShareLink(item: file) { Label("Del", systemImage: "square.and.arrow.up") }
                Button("Kopiér billede", systemImage: "doc.on.doc") { copyStudioImage(file) }
            }
            if !privateSession || privateImages[file] != nil {
                Button(imageDetails(file).favorite ? "Fjern favorit" : "Gem som favorit", systemImage: "star") {
                    var info = imageDetails(file)
                    info.favorite.toggle()
                    storeImageDetails(info, for: file)
                }
            }
            Button("Info og tags", systemImage: "info.circle") {
                tagsDraft = imageDetails(file).tags.joined(separator: ", ")
                imageDetailsSheet = StudioImageSheet(url: file)
            }
            Button("Viderebyg på billede", systemImage: "wand.and.stars") { continueStudioImage(file) }
                .disabled(task != nil || (privateSession && privateImages[file] == nil))
            Button("Opgrader til 4K", systemImage: "arrow.up.left.and.arrow.down.right") { upscaleImage(file) }
                .disabled(task != nil)
            Button("Slet", systemImage: "trash", role: .destructive) { pendingImageDeletion = file }
                .disabled(task != nil)
        }.frame(minHeight: 44)
    }

    func copyStudioImage(_ file: URL) {
        guard !privateSession, file.isFileURL, file.deletingLastPathComponent() == historyFolder else { return }
        do {
            let image = try LocalFileStore.readBytes(from: file, maximumBytes: 64_000_000)
            UIPasteboard.general.setItems([[UTType.png.identifier: image]], options: [.localOnly: true])
            status = "Billedet er kopieret."
        } catch {
            AppDiagnostics.record(error)
            status = "Billedet kunne ikke kopieres."
        }
    }

    private func continueStudioImage(_ file: URL) {
        guard let data = studioThumbnail(file, maxPixelSize: 768)?.jpegData(compressionQuality: 0.9),
              acceptStudioImageDrop([data]) else { return }
        studioPage = .images
        Task { @MainActor in
            await Task.yield()
            imagePromptFocused = true
        }
    }

    func imageDetailsView(_ file: URL) -> some View {
        let details = imageDetails(file)
        return NavigationStack {
            Form {
                LabeledContent("Model", value: details.model ?? "Ikke registreret")
                LabeledContent("Seed", value: details.seed.map { String($0) } ?? "Ikke registreret")
                LabeledContent("Trin", value: details.steps.map { String($0) } ?? "Ikke registreret")
                if let prompt = details.prompt {
                    Section("Prompt") {
                        if privateSession { Text(prompt) } else { Text(prompt).textSelection(.enabled) }
                    }
                }
                if let negative = details.negativePrompt, !negative.isEmpty {
                    Section("Negativ prompt") {
                        if privateSession { Text(negative) } else { Text(negative).textSelection(.enabled) }
                    }
                }
                if file.deletingLastPathComponent() == historyFolder || privateImages[file] != nil {
                    TextField("Tags, adskilt med komma", text: $tagsDraft)
                    Button("Gem tags") {
                        var updated = details
                        updated.tags = Array(Set(tagsDraft.split(separator: ",").map {
                            String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
                        }.filter { !$0.isEmpty })).sorted().prefix(12).map { $0 }
                        storeImageDetails(updated, for: file)
                        imageDetailsSheet = nil
                    }
                }
            }.navigationTitle("Billedinfo").navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("Luk") { imageDetailsSheet = nil } }
        }
    }

    func studioThumbnail(_ file: URL, maxPixelSize: Int) -> UIImage? {
        autoreleasepool {
            guard let source = studioImageSource(file, privateImages: privateImages),
                  let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
                  ] as CFDictionary) else { return nil }
            return UIImage(cgImage: thumbnail)
        }
    }

    func studioImageURL(_ name: String) -> URL {
        (privateSession ? privateImageFolder : historyFolder).appendingPathComponent(name)
    }

    func removeTemporaryStudioImages() {
        let identifiers = Set(privateImages.keys)
        photoAuthentication?.invalidate()
        photoAuthentication = nil
        temporaryImagesID = UUID()
        privateImages.removeAll()
        batchImageURLs.removeAll { !$0.isFileURL }
        transientDetails.removeAll()
        rebuildGalleryCache()
        if imageDetailsSheet?.url.isFileURL == false { imageDetailsSheet = nil }
        if imageViewer?.url.isFileURL == false { imageViewer = nil }
        if imageURL?.isFileURL == false { imageURL = nil }
        if pendingImageDeletion?.isFileURL == false { pendingImageDeletion = nil }
        selectedGalleryImages.subtract(identifiers)
        photosSaving.subtract(identifiers)
        selectingGalleryImages = false
        confirmGalleryDelete = false
        pendingPrivatePhoto = nil
        batchTurnID = nil
        negativeImagePrompt = ""
        studioSeed = nil
        makeFourImages = false
        imageBenchmark = nil
        tagsDraft = ""
        basePhoto = nil
        baseImage = nil
    }

    func storePrivateImage(_ data: Data, for file: URL) throws {
        guard !file.isFileURL, !data.isEmpty, data.count <= 48_000_000 else { throw CocoaError(.fileWriteOutOfSpace) }
        while privateImages.values.reduce(data.count, { $0 + $1.count }) > 48_000_000 || privateImages.count >= 16 {
            guard let oldest = privateImages.keys.min(by: { $0.lastPathComponent < $1.lastPathComponent }) else { break }
            deleteImage(oldest)
        }
        privateImages[file] = data
    }

    private func saveImageToPhotos(_ file: URL) {
        guard !privateSession, file.deletingLastPathComponent() == historyFolder, photosSaving.insert(file).inserted else { return }
        Task {
            defer { photosSaving.remove(file) }
            let saved = await saveStudioPhoto(file, requiresAutoSave: false)
            status = saved ? "Billedet er gemt i Fotos." : "Kunne ikke gemme. Tjek FadedAI’s adgang til Fotos."
        }
    }

    func privatePhotoButton(_ file: URL) -> some View {
        Button(photosSaving.contains(file) ? "Gemmer…" : "Gem i Fotos", systemImage: "square.and.arrow.down") {
            if canShowStudio, privateImages[file] != nil { pendingPrivatePhoto = StudioImageSheet(url: file) }
        }
        .frame(minHeight: 44)
        .disabled(photosSaving.contains(file) || task != nil)
    }

    func exportPrivatePhoto(_ file: URL) {
        guard canShowStudio, privateSession, photoAuthentication == nil,
              privateImages[file] != nil, photosSaving.insert(file).inserted else { return }
        let sessionID = temporaryImagesID
        let context = LAContext()
        photoAuthentication = context
        Task {
            defer {
                if photoAuthentication === context { photoAuthentication = nil }
                photosSaving.remove(file)
            }
            do {
                let accepted = try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics,
                                                                 localizedReason: "Godkend en kopi af billedet i Fotos")
                guard accepted, isCurrentPrivateSession(sessionID) else { return }
                let current = PHPhotoLibrary.authorizationStatus(for: .addOnly)
                let access: PHAuthorizationStatus
                if current == .notDetermined { access = await PHPhotoLibrary.requestAuthorization(for: .addOnly) }
                else { access = current }
                guard isCurrentPrivateSession(sessionID) else { return }
                guard access == .authorized || access == .limited, let data = privateImages[file] else {
                    status = "Kunne ikke gemme. Tjek FadedAI’s adgang til Fotos."
                    return
                }
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
                }
                if isCurrentPrivateSession(sessionID) { status = "En kopi er gemt i Fotos." }
            } catch {
                AppDiagnostics.record(error)
                if isCurrentPrivateSession(sessionID) { status = "Billedet blev ikke gemt i Fotos." }
            }
        }
    }

    func isCurrentPrivateSession(_ id: UUID) -> Bool {
        privateSession && loaded && sessionUnlocked && !sessionExpired && id == temporaryImagesID
    }

    func saveStudioPhoto(_ file: URL, requiresAutoSave: Bool = true) async -> Bool {
        let existing = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        let access: PHAuthorizationStatus
        if existing == .notDetermined {
            access = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        } else {
            access = existing
        }
        guard (access == .authorized || access == .limited), !Task.isCancelled,
              sessionUnlocked, !privateSession, !requiresAutoSave || autoSaveStudioPhotos else { return false }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset().addResource(with: .photo, fileURL: file, options: nil)
            }
            return true
        } catch { AppDiagnostics.record(error); return false }
    }
}
