// OfflineStudioImages.swift
// Viser billedfanen og styrer modeller, prompts og billedkø.

import MediaGenerationKit
import PhotosUI
import SwiftUI
import UIKit

extension OfflineStudio {
    var studioImagesPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                imageThermalWarning
                if generatingImages { imageShimmer }
                if idleAsleep {
                    FadedSecondaryButton("Vis resultat igen", icon: "photo") { resetIdleTimer() }
                } else {
                    imageResults
                    if imageURL == nil && task == nil {
                        FadedEmptyState(icon: "photo", title: "Dit næste billede",
                                        detail: "Beskriv motivet nedenfor, og tryk Lav billede.")
                    }
                }
                if batchTurnID != nil {
                    Button("Se billedet i chatten", systemImage: "bubble.left") { studioPage = .chat }
                        .frame(minHeight: 44)
                }
                DisclosureGroup("Billedindstillinger") { imageInlineOptions }
            }.padding(FadedSpacing.edge)
        }
        .scrollDismissesKeyboard(.interactively)
        .onScrollPhaseChange { _, phase in if phase == .interacting { resetIdleTimer() } }
        .safeAreaInset(edge: .bottom) { studioImageComposer }
    }

    private var studioImageComposer: some View {
        let blocker = privateImageBlocker
        return VStack(alignment: .leading, spacing: 8) {
            Label(privateSession || api == nil || !allowPCFallback ? "Kun telefon" : "Telefon først · PC ved behov",
                  systemImage: "iphone").font(.caption).foregroundStyle(.secondary)
            if imagePromptFocused {
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
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Beskriv dit billede…", text: $imagePrompt, axis: .vertical)
                    .lineLimit(1...5).frame(minHeight: 44).focused($imagePromptFocused)
                    .dropDestination(for: StudioPhotoInput.self) { items, _ in
                        acceptStudioImageDrop(items.map(\.data))
                    }
                studioEditorButton(forImage: true)
            }
            imageGenerationButton(blocked: blocker != nil)
            if let blocker { FadedDetailText(blocker).accessibilityAddTraits(.updatesFrequently) }
            if task != nil {
                FadedSecondaryButton("Stop billedkø", icon: "stop.fill") { stopStudioImageQueue() }
            }
        }
        .padding(12).background(palette.card, in: RoundedRectangle(cornerRadius: 22))
        .overlay { RoundedRectangle(cornerRadius: 22).strokeBorder(privateSession ? palette.purple : palette.border) }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    private var privateImageBlocker: String? {
        guard privateSession else { return nil }
        if !imageReady { return "Hent billedmodellen under Hjem → ⋯ → Lokale modeller → Billeder." }
        if !canRenderPrivateImages { return "Slå Wi-Fi og mobildata fra for at lave billedet privat." }
        return nil
    }

    var imageReady: Bool {
        (try? MediaGenerationEnvironment.default.inspectModel(imageModel, offline: true))?.isDownloaded == true
    }

    private var installedLoRA: String? {
        let selected = privateSession ? sessionPreferences.lora : loraName
        guard selected.hasPrefix("fadedai-"), selected.hasSuffix("_lora_f16.ckpt"),
              !selected.contains("/"), !selected.contains("\\"),
              MediaGenerationEnvironment.default.externalUrls.contains(where: { root in
                  let file = root.appendingPathComponent(selected)
                  guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return false }
                  return values.isRegularFile == true && values.isSymbolicLink != true
              }) else { return nil }
        return selected
    }

    var imageFavorites: [String] {
        (try? JSONDecoder().decode([String].self, from: imageFavoritesData)) ?? []
    }

    private var loraPreviews: URL { URL.applicationSupportDirectory.appending(path: "StudioLoRAPreviews", directoryHint: .isDirectory) }

    private var importedLoRAs: [String] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey]
        return Array(Set(MediaGenerationEnvironment.default.externalUrls.flatMap { root in
            let files = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])) ?? []
            return files.compactMap { file -> String? in
                let name = file.lastPathComponent
                guard name.hasPrefix("fadedai-"), name.hasSuffix("_lora_f16.ckpt"),
                      let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true,
                      values.isSymbolicLink != true else { return nil }
                return name
            }
        })).sorted()
    }

    var loraLabels: [String: String] {
        (try? JSONDecoder().decode([String: String].self, from: loraLabelsData)) ?? [:]
    }

    var privateImageSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Billedmodel", selection: privateSession ? $sessionPreferences.imageModel : $savedImageModel) {
                ForEach(StudioImageModel.allCases) { model in Text(model.title).tag(model.id) }
            }.disabled(task != nil)
            if privateSession {
                Text(imageReady ? "Billedmodellen er klar på telefonen." : "Hent billedmodellen under Hjem → ⋯ → Lokale modeller → Billeder.")
                    .font(.caption).foregroundStyle(palette.secondary)
                let names = importedLoRAs
                if !names.isEmpty {
                    DisclosureGroup("Installeret LoRA") {
                        loraRows(names, selection: $sessionPreferences.lora)
                    }.disabled(task != nil)
                }
                Text("Private billeder kan gemmes i Fotos med din godkendelse.")
                    .font(.caption).foregroundStyle(palette.secondary)
            } else {
                regularImageModelActions
            }
            Button("Benchmark billedmodel") { benchmarkImageModel() }.frame(minHeight: 44)
                .disabled(!imageReady || task != nil || (privateSession && !canRenderPrivateImages))
            if let imageBenchmark { Text(imageBenchmark).font(.caption) }
        }
    }

    @ViewBuilder private var regularImageModelActions: some View {
        Button("Download billedmodel") { downloadImageModel() }.frame(minHeight: 44).disabled(task != nil)
        Text("Lad FadedAI være åben under download af billedmodeller.")
            .font(.caption).foregroundStyle(.secondary)
        Button("Importér LoRA fra Filer") { importLoRA = true }.frame(minHeight: 44).disabled(task != nil)
        let names = importedLoRAs
        if !names.isEmpty {
            DisclosureGroup("LoRA-forhåndsvisninger") {
                loraRows(names, selection: $loraName, enabled: $useLoRA)
                if installedLoRA != nil {
                    PhotosPicker("Vælg forhåndsvisning til valgt LoRA", selection: $loraPreviewSelection, matching: .images)
                        .frame(minHeight: 44)
                        .task(id: loraPreviewSelection) { await saveLoRAPreview() }
                }
            }.disabled(task != nil)
        }
        Toggle("Beskyt batteriet under billedgenerering", isOn: $imageBatteryProtection).disabled(task != nil)
    }

    private func loraRows(_ names: [String], selection: Binding<String>, enabled: Binding<Bool>? = nil) -> some View {
        let labels = loraLabels
        return ForEach(names, id: \.self) { name in
            let previewURL = loraPreviews.appendingPathComponent(name + ".jpg")
            HStack {
                if let image = studioThumbnail(previewURL, maxPixelSize: 160) {
                    Image(uiImage: image).resizable().scaledToFill().frame(width: 52, height: 52).clipped()
                        .accessibilityLabel("LoRA-forhåndsvisning")
                } else {
                    Image(systemName: "photo").frame(width: 52, height: 52).foregroundStyle(.secondary)
                        .accessibilityLabel("Ingen forhåndsvisning")
                }
                Toggle(labels[name] ?? name, isOn: Binding(get: {
                    (enabled?.wrappedValue ?? true) && selection.wrappedValue == name
                }, set: { selected in
                    if selected {
                        selection.wrappedValue = name
                        enabled?.wrappedValue = true
                    } else if selection.wrappedValue == name {
                        if let enabled { enabled.wrappedValue = false }
                        else { selection.wrappedValue = "" }
                    }
                })).frame(minHeight: 44)
            }.id("\(name)-\(loraPreviewRefresh)")
        }
    }

    private func saveLoRAPreview() async {
        guard !privateSession, let item = loraPreviewSelection, let name = installedLoRA else { return }
        do {
            guard let photo = try await item.loadTransferable(type: StudioPhotoInput.self) else { return }
            try Task.checkCancellation()
            guard loraPreviewSelection == item, installedLoRA == name else { return }
            try FileManager.default.createDirectory(at: loraPreviews, withIntermediateDirectories: true)
            try LocalFileStore.writeBytes(photo.data, to: loraPreviews.appendingPathComponent(name + ".jpg"), within: loraPreviews)
            loraPreviewRefresh += 1
        } catch is CancellationError {} catch { AppDiagnostics.record(error); status = "Forhåndsvisningen kunne ikke gemmes." }
    }

    private var imageInlineOptions: some View {
        VStack(alignment: .leading, spacing: FadedSpacing.section) {
            if api != nil && !privateSession { Toggle("Tillad PC som reserve", isOn: $allowPCFallback) }
            FadedFieldLabel("Negativ prompt")
            TextField("Negativ prompt", text: $negativeImagePrompt, axis: .vertical)
                .textFieldStyle(.roundedBorder).lineLimit(1...3).frame(minHeight: 44)
                .accessibilityHint("Motiver og detaljer, der skal undgås")
            Toggle("Lav 4 forslag", isOn: $makeFourImages)
            HStack(spacing: 10) {
                Button {
                    studioSeed = studioSeed == nil ? UInt32.random(in: 1...(UInt32.max - 4)) : nil
                } label: {
                    Image(systemName: studioSeed == nil ? "lock.open" : "lock.fill")
                        .frame(minWidth: 44, minHeight: 44)
                }.accessibilityLabel(studioSeed == nil ? "Lås seed" : "Lås seed op")
                PhotosPicker(selection: $basePhoto, matching: .images, photoLibrary: .shared()) {
                    Image(systemName: "photo.badge.plus").frame(minWidth: 44, minHeight: 44)
                }.accessibilityLabel("Vælg basebillede fra Fotos")
                .disabled(privateSession && !canRenderPrivateImages)
                .task(id: basePhoto) { await loadBasePhoto() }
                Button { saveImageFavorite() } label: {
                    Image(systemName: "star").frame(minWidth: 44, minHeight: 44)
                }.accessibilityLabel("Gem billedprompt som favorit")
                    .disabled(privateSession || imagePrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || imagePrompt.count > 2_000)
                if !imageFavorites.isEmpty && !privateSession {
                    Menu {
                        ForEach(imageFavorites, id: \.self) { favorite in
                            Button(String(favorite.prefix(80))) { imagePrompt = favorite }
                        }
                    } label: {
                        Image(systemName: "star.square.on.square").frame(minWidth: 44, minHeight: 44)
                    }.accessibilityLabel("Brug gemt billedprompt")
                }
                Spacer(minLength: 0)
                if makeFourImages { Text("4 forslag").font(.caption).foregroundStyle(.secondary) }
            }.disabled(task != nil && !generatingImages)
            if studioSeed != nil || baseImage != nil || loadingBaseImage {
                HStack(spacing: 10) {
                    if let studioSeed { Text("Seed: \(String(studioSeed)) låst") }
                    if loadingBaseImage { Text("Henter basebillede…") }
                    if baseImage != nil {
                        Button("Fjern basebillede", systemImage: "xmark.circle") {
                            basePhoto = nil
                            baseImage = nil
                        }.frame(minHeight: 44).disabled(task != nil && !generatingImages)
                    }
                    Spacer(minLength: 0)
                }.font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func imageGenerationButton(blocked: Bool) -> some View {
        let label = pendingImages.isEmpty ? "Lav billede" : "Lav billede · I kø (\(pendingImages.count))"
        return FadedPrimaryButton(label, icon: "photo.badge.plus") { generateImage() }
            .disabled(blocked || !canEnqueueImage || loadingBaseImage || pendingImages.count >= 5
                || imagePrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || imagePrompt.count > 2_000 || negativeImagePrompt.count > 1_000)
    }

    private var imageShimmer: some View {
        let paused = reduceMotion || calmMotion || studioPhase != .active
        return TimelineView(.animation(minimumInterval: 1.0 / 15, paused: paused)) { context in
            let phase = paused ? 0.5 : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
            FadedCard(accent: palette.lime) {
                VStack(alignment: .leading, spacing: 10) {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(palette.raised)
                        .overlay {
                            GeometryReader { geometry in
                                LinearGradient(colors: [.clear, palette.lime.opacity(0.16), .clear], startPoint: .leading, endPoint: .trailing)
                                    .frame(width: geometry.size.width * 0.55)
                                    .offset(x: geometry.size.width * (CGFloat(phase) * 1.55 - 0.55))
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .frame(height: 90).accessibilityHidden(true)
                    Text("Maleren sveder…").font(.subheadline.weight(.semibold)).foregroundStyle(palette.text)
                }
            }
        }
    }

    private var canEnqueueImage: Bool {
        if generatingImages { return task?.isCancelled == false }
        return task == nil
    }

    func acceptStudioImageDrop(_ items: [Data]) -> Bool {
        guard sessionUnlocked, task == nil || generatingImages,
              let first = items.first, let decoded = StudioPhotoInput.downsample(first) else { return false }
        basePhoto = nil
        baseImage = decoded
        status = "Bruger dit billede som base…"
        return true
    }

    @ViewBuilder private var imageThermalWarning: some View {
        if imageCooling || isImageThermallyConstrained {
            Label(imageCooling
                  ? "Telefonen er varm. Generering er sat på pause i 30 sekunder."
                  : "Telefonen er varm.", systemImage: "thermometer.sun.fill")
                .foregroundStyle(.red).font(.callout)
        }
        if let upscaleProgress {
            ProgressView(value: upscaleProgress) {
                Text("Opgraderer… \(upscaleProgress.formatted(.percent))")
            }
        }
    }

    @ViewBuilder private var imageResults: some View {
        if batchImageURLs.count > 1 {
            VStack(alignment: .leading, spacing: 8) {
                Text("Vælg dit bedste forslag").font(.headline)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ForEach(batchImageURLs, id: \.self) { file in
                        Button { selectBatchImage(file) } label: {
                            if let thumbnail = studioThumbnail(file, maxPixelSize: 384) {
                                Image(uiImage: thumbnail).resizable().scaledToFit()
                                    .frame(maxWidth: .infinity)
                                    .overlay(alignment: .topTrailing) {
                                        if imageURL == file {
                                            Image(systemName: "checkmark.circle.fill").padding(6)
                                                .foregroundStyle(FadedColors.deep, palette.lime)
                                        }
                                    }
                            }
                        }.buttonStyle(.plain).accessibilityLabel("Vælg forslag \((batchImageURLs.firstIndex(of: file) ?? 0) + 1)")
                            .accessibilityAddTraits(imageURL == file ? .isSelected : [])
                    }
                }
            }
        }
        if let imageURL, let thumbnail = studioThumbnail(imageURL, maxPixelSize: 1024) {
            Button { imageViewer = StudioImageSheet(url: imageURL) } label: {
                Image(uiImage: thumbnail).resizable().scaledToFit().accessibilityLabel("Valgt billede")
            }.buttonStyle(.plain)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { resultImageActions(imageURL) }
                VStack(alignment: .leading, spacing: 4) { resultImageActions(imageURL) }
            }.frame(minHeight: 44)
        }
    }

    @ViewBuilder private func resultImageActions(_ file: URL) -> some View {
        if privateSession && privateImages[file] != nil {
            privatePhotoButton(file)
        } else if file.deletingLastPathComponent() == historyFolder && !privateSession {
            publicImageActions(file)
            Button("Kopiér billede", systemImage: "doc.on.doc") { copyStudioImage(file) }.frame(minHeight: 44)
        }
        imageTurnActions(file)
    }

    func imageTurnActions(_ file: URL) -> some View {
        imageActionMenu(file)
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
            baseImage = photo.data
            status = "Basebillede valgt. Det bliver på telefonen."
        } catch is CancellationError {
            return
        } catch {
            AppDiagnostics.record(error)
            if basePhoto == item {
                baseImage = nil
                status = "Billedet kunne ikke læses fra Fotos."
            }
        }
    }

    private func saveImageFavorite() {
        let value = imagePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !privateSession, !value.isEmpty, value.count <= 2_000 else { return }
        let values = [value] + imageFavorites.filter { $0 != value }
        if let data = try? JSONEncoder().encode(Array(values.prefix(20))) {
            imageFavoritesData = data
            status = "Prompt gemt i favoritter."
        }
    }

    func selectBatchImage(_ file: URL) {
        imageURL = file
        if let batchTurnID, let index = turns.firstIndex(where: { $0.id == batchTurnID }) {
            turns[index].imageName = file.lastPathComponent
            savePrivateConversation()
        }
    }

    func selectHistoryImage(_ file: URL) {
        batchImageURLs = []
        batchTurnID = nil
        imageURL = file
    }

    private func generateImage() {
        let message = imagePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let negative = negativeImagePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard studioEnabled, canShowStudio, canEnqueueImage, pendingImages.count < 5,
              !message.isEmpty, message.count <= 2_000, negative.count <= 1_000, !loadingBaseImage else { return }
        if let blocker = privateImageBlocker {
            status = blocker
            return
        }
        let request = StudioImageRequest(model: imageModel, prompt: message, negative: negative,
                                         lora: privateSession || useLoRA ? installedLoRA ?? "" : "", count: makeFourImages ? 4 : 1,
                                         seed: studioSeed, sourceImage: baseImage, isPrivate: privateSession,
                                         autoSave: autoSaveStudioPhotos && !privateSession,
                                         botID: selectedPrivateBot?.id, allowPCFallback: !privateSession && allowPCFallback)
        pendingImages.append(request)
        guard !generatingImages else { return }
        generatingImages = true
        run("Genererer billede på telefonen…") {
            defer {
                imageCooling = false
                generatingImages = false
                pendingImages.removeAll()
            }
            while !pendingImages.isEmpty {
                try Task.checkCancellation()
                let next = pendingImages.removeFirst()
                do { try await generateQueuedImages(next) }
                catch StudioImageInterruption.battery {
                    AppDiagnostics.record(StudioImageInterruption.battery)
                    status = "Batteriet er lavt. Sæt telefonen til opladning for at fortsætte."
                    return
                } catch StudioImageInterruption.network {
                    AppDiagnostics.record(StudioImageInterruption.network)
                    status = "Slå Wi-Fi og mobildata fra for at generere billeder privat."
                    return
                } catch is CancellationError { throw CancellationError() }
                catch LocalComputeError.lowMemory {
                    AppDiagnostics.record(LocalComputeError.lowMemory)
                    status = next.model == StudioImageModel.fluxKlein.id
                        ? "Telefonen har for lidt ledig hukommelse. Prøv Stable Diffusion 1.5 under Billedindstillinger."
                        : "Telefonen har for lidt ledig hukommelse. Luk andre tunge opgaver, og prøv igen."
                }
                catch {
                    AppDiagnostics.record(error)
                    status = pcBusyMessage(error) ?? "Billedopgaven kunne ikke gennemføres. Tjek billedmodel og plads."
                }
            }
        }
    }

    func stopStudioImageQueue() {
        pendingImages.removeAll()
        if generatingImages { task?.cancel() }
    }

    private func generateQueuedImages(_ request: StudioImageRequest) async throws {
        let sessionID = temporaryImagesID
        let folder = request.isPrivate ? privateImageFolder : historyFolder
        if request.isPrivate && !canRenderPrivateImages { throw StudioImageInterruption.network }
        let ready = (try? await MediaGenerationEnvironment.default.inspectModel(request.model, offline: true))?.isDownloaded == true
        try Task.checkCancellation()
        let localOnly = !request.allowPCFallback || request.isPrivate || request.sourceImage != nil || request.seed != nil || request.prompt.count > 1_000
            || request.count > 1 || !request.negative.isEmpty || !request.lora.isEmpty
        if !ready && localOnly {
            status = "Hent billedmodellen på telefonen for at bruge de valgte indstillinger."
            return
        }
        let steps = request.model.hasPrefix("flux") ? 4 : 20
        var created: [URL] = []
        var photosDenied = false
        if !request.isPrivate { try prepareImageFolder(folder) }
        for index in 0..<request.count {
            try Task.checkCancellation()
            try checkImageBattery()
            let destination = imageDestination(in: folder)
            let seed = request.seed.map { $0 + UInt32(index) } ?? UInt32.random(in: 1...UInt32.max)
            let variation = request.seed != nil && index > 0 ? created.first : nil
            let part = request.count > 1 ? "Genererer \(index + 1) af \(request.count)…" : "Genererer billede på telefonen…"
            let label = request.sourceImage != nil || variation != nil ? part + " Bruger dit billede som base…" : part
            var source = "Telefon"
            var metadata = StudioImageDetails(prompt: request.prompt, negativePrompt: request.negative,
                                              seed: seed, model: request.model, steps: steps)
            do {
                guard ready else { throw PhoneModelError.unavailable }
                let data = try await renderStudioImage(model: request.model, prompt: request.prompt, lora: request.lora, seed: seed,
                                                       sourceImage: request.sourceImage, variation: variation,
                                                       destination: request.isPrivate ? nil : destination, within: folder,
                                                       label: label, steps: steps, negativePrompt: request.negative,
                                                       requireOffline: request.isPrivate)
                try Task.checkCancellation()
                if request.isPrivate {
                    guard privateSession, sessionUnlocked, !sessionExpired, sessionID == temporaryImagesID else { throw CancellationError() }
                    guard let data else { throw PhoneModelError.emptyResponse }
                    try storePrivateImage(data, for: destination)
                }
            } catch StudioImageInterruption.battery { AppDiagnostics.record(StudioImageInterruption.battery); throw StudioImageInterruption.battery }
            catch StudioImageInterruption.network { AppDiagnostics.record(StudioImageInterruption.network); throw StudioImageInterruption.network }
            catch {
                AppDiagnostics.record(error)
                try Task.checkCancellation()
                // Privat: aldrig PC, aldrig Grok, aldrig forbindelser.
                guard !request.isPrivate, !privateSession, let api, !localOnly else { throw error }
                try checkImageBattery()
                status = "Telefonen kunne ikke lave billedet. PC’en prøver med sin egen model…"
                let png = try await api.v2GenerateImage(prompt: request.prompt)
                try Task.checkCancellation()
                try LocalFileStore.writeBytes(png, to: destination, within: folder)
                source = "PC"
                metadata = StudioImageDetails(prompt: request.prompt, model: "PC’ens billedmodel")
            }
            try Task.checkCancellation()
            storeImageDetails(metadata, for: destination)
            created.append(destination)
            if request.isPrivate { created.removeAll { privateImages[$0] == nil } }
            if index == 0 {
                let turn = PrivateChatTurn(prompt: request.prompt, reply: "Billede klar.",
                                           imageName: destination.lastPathComponent, source: source, botID: request.botID)
                batchTurnID = turn.id
                turns.append(turn)
                imageURL = destination
            }
            batchImageURLs = created
            savePrivateConversation()
            if request.autoSave && !request.isPrivate && autoSaveStudioPhotos && !privateSession {
                if !(await saveStudioPhoto(destination)) { photosDenied = true }
            }
        }
        status = request.count > 1 ? "Forslagene er klar. Vælg dit bedste billede." : "Billede klar."
        if photosDenied { status += " Billedet er gemt i studiet. Tjek tilladelsen til Fotos." }
        offlineSuccessHaptic()
    }

    private func downloadImageModel() {
        guard !privateSession, let selected = StudioImageModel(rawValue: imageModel) else { return }
        guard PhoneModels.hasDownloadSpace(bytes: selected.minimumFreeBytes) else { status = "Frigør mere plads før download."; return }
        run("Henter billedmodel…") {
            defer { downloadProgress = nil }
            try await selected.ensure { value in
                Task { @MainActor in
                    if task != nil { downloadProgress = value }
                }
            }
            try Task.checkCancellation()
            status = "Billedmodel hentet."
            await JobNotifications.shared.completed(kind: "image-model", server: "phone", id: UUID().uuidString,
                                                     title: "Din lokale billedmodel er klar!")
        }
    }

    func loadLoRA(_ source: URL) {
        guard !privateSession, source.pathExtension.lowercased() == "safetensors",
              let directory = MediaGenerationEnvironment.default.externalUrls.first else {
            status = "Vælg en LoRA-fil i .safetensors-format."
            return
        }
        let name = "fadedai-\(UUID().uuidString)_lora_f16.ckpt"
        let destination = directory.appendingPathComponent(name)
        run("Importerer LoRA…") {
            var finished = false
            defer { if !finished { try? FileManager.default.removeItem(at: destination) } }
            try await Task.detached(priority: .userInitiated) {
                let scoped = source.startAccessingSecurityScopedResource()
                defer { if scoped { source.stopAccessingSecurityScopedResource() } }
                let size = try LocalFileStore.checkedFileSize(source, maximumBytes: 8_000_000_000)
                guard size > 0 else { throw LocalFileStore.Failure.invalidFile }
                let target = try LocalFileStore.safeWriteURL(destination, within: directory)
                var importer = LoRAImporter(file: source)
                try importer.import(to: target)
                let appModels = PhoneModels.downloadedRoot.resolvingSymlinksInPath().path
                if target.deletingLastPathComponent().path == appModels { try LocalFileStore.protectFile(target) }
            }.value
            try Task.checkCancellation()
            var labels = loraLabels
            labels[name] = String(source.deletingPathExtension().lastPathComponent.prefix(80))
            loraLabelsData = try JSONEncoder().encode(labels)
            loraName = name
            useLoRA = true
            finished = true
            status = "LoRA importeret."
        }
    }
}
