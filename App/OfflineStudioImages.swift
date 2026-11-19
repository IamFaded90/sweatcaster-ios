// OfflineStudioImages.swift
// Viser billedfanen og styrer modeller, prompts og billedkø.

import MediaGenerationKit
import PhotosUI
import SwiftUI
import UIKit

extension OfflineStudio {
    @ViewBuilder var studioImagesPage: some View {
        let composer = AnyView(studioImageComposer)
        if privateSession {
            VStack(spacing: 0) {
                studioImageScroll
                composer
            }
        } else {
            studioImageScroll.safeAreaInset(edge: .bottom, spacing: 0) { composer }
        }
    }

    private var studioImageScroll: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if privateSession {
                    studioOperationStatus
                    privateImageControls
                }
                imageThermalWarning
                if let style = agentImageStyle {
                    Toggle("Brug min billedstil · " + style.title, isOn: $useAgentImageStyle).disabled(task != nil)
                }
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
                if batchTurnID != nil && !imageOnly {
                    Button("Se billedet i chatten", systemImage: "bubble.left") { studioPage = .chat }
                        .frame(minHeight: 44)
                }
                if privateSession || studioImageRoute != .pc {
                    DisclosureGroup("Billedindstillinger") { AnyView(imageInlineOptions) }
                }
            }.padding(FadedSpacing.edge)
        }
        .scrollDismissesKeyboard(.interactively)
        .onScrollPhaseChange { _, phase in if phase == .interacting { resetIdleTimer() } }
    }

    private var studioImageComposer: some View {
        let request = studioImageRequest
        let blocker = imageBlocker(for: request)
        return VStack(alignment: .leading, spacing: 8) {
            if !privateSession {
                Picker("Lav billedet på", selection: $studioImageRoute) {
                    ForEach(StudioImageRoute.allCases) { route in Text(route.title).tag(route) }
                }.pickerStyle(.segmented)
                FadedDetailText(imageRouteDetail(for: request))
            }
            if imagePromptFocused && !privateSession { imagePromptSuggestions }
            HStack(alignment: .bottom, spacing: 8) {
                TextField(privateSession && baseImage != nil ? "Hvad vil du ændre?" : "Beskriv dit billede…", text: $imagePrompt, axis: .vertical)
                    .lineLimit(1...(privateSession && imagePromptFocused ? 3 : 5))
                    .frame(minHeight: 44).focused($imagePromptFocused)
                    .dropDestination(for: StudioPhotoInput.self) { items, _ in
                        guard request.isPrivate || request.route != .pc else { return false }
                        return acceptStudioImageDrop(items.map(\.data))
                    }
                if privateSession && imagePromptFocused {
                    Button("Skjul tastatur", systemImage: "keyboard.chevron.compact.down") { imagePromptFocused = false }
                        .labelStyle(.iconOnly).frame(width: 44, height: 44)
                } else {
                    studioEditorButton(forImage: true)
                }
            }
            imageGenerationButton(request, blocked: blocker != nil)
            if !privateSession, let blocker { FadedDetailText(blocker).accessibilityAddTraits(.updatesFrequently) }
            if !privateSession && task != nil {
                FadedSecondaryButton("Stop billedkø", icon: "stop.fill") { stopStudioImageQueue() }
            }
        }
        .padding(12).background(palette.card, in: RoundedRectangle(cornerRadius: 22))
        .overlay { RoundedRectangle(cornerRadius: 22).strokeBorder(privateSession ? palette.purple : palette.border).allowsHitTesting(false) }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    func imageBlocker(for request: StudioImageRequest) -> String? {
        let modelReady = isImageModelReady(request.model)
        if request.isPrivate && request.route == .pc {
            if privateImagePC == nil { return "Forbind PC’en, eller vælg en iPhone-model." }
            if let blocker = pcImageCatalog.blocker(for: request.pcModel) { return blocker }
            if request.prompt.count > 1_000 { return "Forkort billedbeskrivelsen til højst 1.000 tegn." }
        } else if request.isPrivate {
            if !modelReady { return "Hent en billedmodel i modelmenuen, og vælg den, når den er klar." }
        } else if request.route == .pc {
            if api == nil { return "Forbind til PC’en, eller vælg Telefon." }
            if request.prompt.count > 1_000 { return "PC’en tager højst 1.000 tegn. Forkort teksten, eller vælg Telefon." }
            if !request.supportsPC { return "PC’en tager én almindelig prompt. Vælg Telefon for ekstra billedindstillinger." }
        } else if !modelReady && (request.route == .phone || api == nil || !request.allowPCFallback || !request.supportsPC) {
            return "Åbn Billedindstillinger og hent en telefonmodel, eller vælg PC."
        }
        return nil
    }

    private func imageRouteDetail(for request: StudioImageRequest) -> String {
        switch request.route {
        case .pc:
            "Din PC laver ét billede med sin ComfyUI-model. Den får kun din billedbeskrivelse."
        case .phone:
            if let model = StudioImageModel(rawValue: request.model), isImageModelReady(model.id) {
                "Telefonen bruger \(model.title)."
            } else {
                "Telefonen bruger en hentet billedmodel."
            }
        case .automatic:
            request.allowPCFallback && api != nil
                ? "Prøver telefonen først. PC’en kan overtage en enkel billedbeskrivelse."
                : "Prøver telefonen først. Vælg PC, hvis du vil bruge dens billedmotor."
        }
    }

    var imageReady: Bool {
        isImageModelReady(imageModel)
    }

    func isImageModelReady(_ id: String) -> Bool {
        guard let model = StudioImageModel(rawValue: id) else { return false }
        let downloads = StudioImageDownloads.shared
        return downloads.activeModel != model && downloads.isInstalled(model)
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

    @ViewBuilder var privateImageSettings: some View {
        if privateSession && sessionPreferences.imageRoute == .pc {
            VStack(alignment: .leading, spacing: 6) {
                Label(sessionPreferences.pcImageModel.title + " på din PC", systemImage: "desktopcomputer")
                FadedDetailText("Brug modelmenuen ved skrivefeltet, hvis du vil skifte tilbage til iPhone.")
            }
        } else {
            phoneImageSettings
        }
    }

    private var phoneImageSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Billedmodel", selection: privateSession ? $sessionPreferences.imageModel : $savedImageModel) {
                ForEach(StudioImageModel.allCases) { model in Text(model.title).tag(model.id) }
            }.disabled(task != nil)
            if let model = StudioImageModel(rawValue: imageModel) {
                StudioImageModelDeleteButton(model: model, canChange: task == nil)
            }
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
                .disabled(!imageReady || task != nil)
            if let imageBenchmark { Text(imageBenchmark).font(.caption) }
        }
    }

    @ViewBuilder private var regularImageModelActions: some View {
        let downloads = StudioImageDownloads.shared
        if downloads.activeModel?.id == imageModel {
            StudioImageDownloadProgress()
        } else if imageReady {
            Label("Billedmodellen er gemt på telefonen", systemImage: "checkmark.circle")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            Button("Hent billedmodel") { downloadImageModel() }.frame(minHeight: 44)
                .disabled(task != nil || downloads.activeModel != nil)
            FadedDetailText("Download fortsætter i baggrunden.")
        }
        if let notice = downloads.notice { FadedDetailText(notice).accessibilityAddTraits(.updatesFrequently) }
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
                if !privateSession {
                    Button("Slet LoRA", systemImage: "trash", role: .destructive) { pendingLoRADeletion = name }
                        .buttonStyle(.borderless).frame(minHeight: 44)
                }
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
            if !imageReady || privateSession {
                FadedFieldLabel("Billedmodel på telefonen")
                AnyView(privateImageSettings)
            }
            if !(privateSession && sessionPreferences.imageRoute == .pc && sessionPreferences.pcImageModel.isFlux) {
                FadedFieldLabel("Negativ prompt")
                TextField("Negativ prompt", text: $negativeImagePrompt, axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(1...3).frame(minHeight: 44)
                    .accessibilityHint("Motiver og detaljer, der skal undgås")
            }
            Toggle("Lav 4 forslag", isOn: $makeFourImages)
            HStack(spacing: 10) {
                Button {
                    studioSeed = studioSeed == nil ? UInt32.random(in: 1...(UInt32.max - 4)) : nil
                } label: {
                    Image(systemName: studioSeed == nil ? "lock.open" : "lock.fill")
                        .frame(minWidth: 44, minHeight: 44)
                }.accessibilityLabel(studioSeed == nil ? "Lås seed" : "Lås seed op")
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
            if !privateSession { imageReferencePicker }
            if studioSeed != nil {
                HStack(spacing: 10) {
                    if let studioSeed { Text("Seed: \(String(studioSeed)) låst") }
                    Spacer(minLength: 0)
                }.font(.caption).foregroundStyle(.secondary)
            }
        }
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

    private func imageGenerationButton(_ request: StudioImageRequest, blocked: Bool) -> some View {
        let action = request.route == .pc ? "Lav billede på PC" : "Lav billede"
        let label = pendingImages.isEmpty ? action : "\(action) · I kø (\(pendingImages.count))"
        let waitingForBase = (request.isPrivate || request.route != .pc) && loadingBaseImage
        return FadedPrimaryButton(label, icon: "photo.badge.plus") { generateImage(request) }
            .disabled(blocked || !canEnqueueImage || waitingForBase || pendingImages.count >= 5
                || request.prompt.isEmpty || request.prompt.count > 2_000 || request.negative.count > 1_000)
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
        setReferenceImage(decoded)
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
            if !generatingImages, let comparison = imageComparisonSource, comparison.results.contains(imageURL) {
                StudioImageComparison(source: comparison, result: thumbnail).id(imageURL)
            }
            if privateSession, privateImagePC != nil {
                FadedSecondaryButton("Lav video af billedet", icon: "film") { openPrivateVideo(from: imageURL) }
                    .disabled(task != nil)
            }
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
        Button("Slet billede", systemImage: "trash", role: .destructive) { pendingImageDeletion = file }
            .frame(minHeight: 44).disabled(task != nil)
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
    var studioImageRequest: StudioImageRequest {
        let route = privateSession ? sessionPreferences.imageRoute : studioImageRoute
        let usesPhoneOptions = route != .pc
        let model = usesPhoneOptions && !imageReady
            ? StudioImageModel.allCases.first(where: { isImageModelReady($0.id) })?.id ?? imageModel
            : imageModel
        let usesNegative = (usesPhoneOptions || privateSession) && !(privateSession && route == .pc && sessionPreferences.pcImageModel.isFlux)
        let negative = usesNegative ? negativeImagePrompt.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let lora = usesPhoneOptions && (privateSession || useLoRA) ? installedLoRA ?? "" : ""
        return StudioImageRequest(
            model: model, route: route, pcModel: sessionPreferences.pcImageModel, prompt: agentImagePrompt,
            negative: negative, lora: lora, count: usesPhoneOptions && makeFourImages ? 4 : 1,
            seed: usesPhoneOptions || privateSession ? studioSeed : nil, sourceImage: usesPhoneOptions || privateSession ? baseImage : nil,
            referenceMode: privateSession && baseImage != nil ? sessionPreferences.referenceMode : nil, referenceMask: privateSession ? referenceMask : nil,
            isPrivate: privateSession, autoSave: autoSaveStudioPhotos && !privateSession,
            botID: selectedPrivateBot?.id, allowPCFallback: !privateSession && allowPCFallback
        )
    }
    private func generateImage(_ request: StudioImageRequest) {
        guard studioEnabled, canShowStudio, canEnqueueImage, pendingImages.count < 5,
              !request.prompt.isEmpty, request.prompt.count <= 2_000, request.negative.count <= 1_000,
              (request.route == .pc && !request.isPrivate) || !loadingBaseImage else { return }
        if let blocker = imageBlocker(for: request) {
            status = blocker
            return
        }
        if privateSession { imagePromptFocused = false }
        pendingImages.append(request)
        guard !generatingImages else { return }
        generatingImages = true
        run("Starter billedopgaven…") {
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
                } catch is CancellationError { throw CancellationError() }
                catch LocalComputeError.lowMemory {
                    AppDiagnostics.record(LocalComputeError.lowMemory)
                    status = next.model == StudioImageModel.fluxKlein.id
                        ? "Telefonen har for lidt ledig hukommelse. Prøv Stable Diffusion 1.5 under Billedindstillinger."
                        : "Telefonen har for lidt ledig hukommelse. Luk andre tunge opgaver, og prøv igen."
                }
                catch {
                    AppDiagnostics.record(error)
                    status = studioImageErrorMessage(error, model: next.model)
                }
            }
        }
    }
    func stopStudioImageQueue() {
        pendingImages.removeAll()
        if generatingImages { task?.cancel() }
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
