// OfflineStudioTypes.swift
// Definerer studiets modeller, billedfremviser og stemmehjælp.

import AVFAudio
import CoreTransferable
import ImageIO
import MediaGenerationKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct PrivateChatTurn: Codable, Identifiable {
    var id = UUID()
    let prompt: String
    var reply: String
    var imageName: String? = nil
    var source: String? = nil
    var botID: UUID? = nil
}

struct StudioPhotoInput: Transferable {
    let data: Data

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            let bytes = try LocalFileStore.checkedFileSize(received.file, maximumBytes: 24_000_000)
            guard (1...24_000_000).contains(bytes) else { throw CocoaError(.fileReadTooLarge) }
            let data = try autoreleasepool {
                guard let source = CGImageSourceCreateWithURL(received.file as CFURL, nil),
                      let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 768
                      ] as CFDictionary),
                      let data = UIImage(cgImage: thumbnail).jpegData(compressionQuality: 0.90) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                return data
            }
            return StudioPhotoInput(data: data)
        }
        DataRepresentation(importedContentType: .image) { bytes in
            guard let data = downsample(bytes) else { throw CocoaError(.fileReadCorruptFile) }
            return StudioPhotoInput(data: data)
        }
    }

    static func downsample(_ bytes: Data) -> Data? {
        guard bytes.count <= 24_000_000 else { return nil }
        return autoreleasepool {
            guard let source = CGImageSourceCreateWithData(bytes as CFData, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceCreateThumbnailWithTransform: true,
                      kCGImageSourceThumbnailMaxPixelSize: 768
                  ] as CFDictionary) else { return nil }
            return UIImage(cgImage: image).jpegData(compressionQuality: 0.9)
        }
    }
}

enum StudioImageInterruption: Error { case heat, battery, network }

enum StudioImageModel: String, CaseIterable, Identifiable {
    case stableDiffusion = "sd_v1.5_f16.ckpt"
    case fluxKlein = "flux_2_klein_4b_q8p.ckpt"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .stableDiffusion: "Stable Diffusion 1.5"
        case .fluxKlein: "FLUX.2 Klein 4B"
        }
    }
    var minimumFreeBytes: Int64 { self == .fluxKlein ? 8_000_000_000 : 4_000_000_000 }
    var renderSize: Int { self == .fluxKlein ? 1024 : 512 }
    var renderSteps: Int { self == .fluxKlein ? 4 : 16 }
    var minimumWorkingMemoryMiB: UInt64 { self == .fluxKlein ? 4_096 : 2_048 }
    private var requiredFiles: [String] {
        // The pinned SDK's catalog also requires a text encoder and autoencoder for each model.
        switch self {
        case .stableDiffusion: [id, "clip_vit_l14_f16.ckpt", "vae_ft_mse_840000_f16.ckpt"]
        case .fluxKlein: [id, "qwen_3_4b_q8p.ckpt", "flux_2_vae_f16.ckpt"]
        }
    }

    var isInstalled: Bool {
        let roots = Set(MediaGenerationEnvironment.default.externalUrls + [PhoneModels.downloadedRoot])
        return requiredFiles.allSatisfy { name in
            roots.contains { root in
                let file = root.appendingPathComponent(name, isDirectory: false)
                return ((try? LocalFileStore.checkedFileSize(file, maximumBytes: Int.max)) ?? 0) > 0
            }
        }
    }

    func ensure(progress: @escaping @Sendable (Double) -> Void) async throws {
        try Task.checkCancellation()
        guard !isInstalled else { return }
        _ = try await MediaGenerationEnvironment.default.ensure(rawValue) { state in
            if case .downloading(_, let index, let count, let written, let total) = state, count > 0, total > 0 {
                let part = min(1, Double(written) / Double(total))
                progress(min(1, (Double(max(0, index - 1)) + part) / Double(count)))
            }
        }
        try Task.checkCancellation()
        guard isInstalled else { throw PhoneModelError.unavailable }
    }
}

struct StudioImageDownloadsView: View {
    @Binding var downloading: StudioImageModel?
    let canStart: Bool
    let onDownloaded: () -> Void
    @State private var task: Task<Void, Never>?
    @State private var progress: Double?
    @State private var notice: String?
    @State private var activeDownload: UUID?

    init(downloading: Binding<StudioImageModel?>, canStart: Bool, onDownloaded: @escaping () -> Void) {
        _downloading = downloading
        self.canStart = canStart
        self.onDownloaded = onDownloaded
    }

    var body: some View {
        VStack(alignment: .leading, spacing: FadedSpacing.section) {
            FadedSectionHeader("Billedmodeller", detail: "Hent modellen én gang til din telefon. Hold siden åben, mens den hentes.")
            ForEach(StudioImageModel.allCases) { model in
                FadedCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Label(model.title, systemImage: "photo").font(.headline)
                        FadedDetailText(model == .stableDiffusion
                                        ? "Start her. Kræver mindst 4 GB ledig plads før download."
                                        : "Tungere model. Kræver mindst 8 GB ledig plads før download.")
                        if downloading == model {
                            if let progress {
                                ProgressView(value: progress) { Text(progress.formatted(.percent)) }
                            } else {
                                ProgressView("Henter billedmodellen…")
                            }
                            FadedSecondaryButton("Stop download", icon: "stop.fill") { task?.cancel() }
                        } else if model.isInstalled {
                            Label("Gemt på telefonen", systemImage: "checkmark.circle")
                        } else {
                            FadedSecondaryButton("Hent billedmodel", icon: "arrow.down.circle") { download(model) }
                                .accessibilityLabel("Hent \(model.title)").disabled(!canStart)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if let notice { FadedDetailText(notice).accessibilityAddTraits(.updatesFrequently) }
        }
        .onDisappear { task?.cancel() }
    }

    private func download(_ model: StudioImageModel) {
        guard canStart, !model.isInstalled else { return }
        guard PhoneModels.hasDownloadSpace(bytes: model.minimumFreeBytes) else {
            notice = "Der er for lidt ledig plads. Frigør plads, og prøv igen."
            return
        }
        let id = UUID()
        activeDownload = id
        downloading = model
        progress = nil
        notice = nil
        task = Task { @MainActor in
            defer {
                activeDownload = nil
                downloading = nil
                progress = nil
                task = nil
            }
            do {
                try await model.ensure { value in
                    Task { @MainActor in
                        if activeDownload == id { progress = value }
                    }
                }
                try Task.checkCancellation()
                notice = "\(model.title) er klar på telefonen."
                onDownloaded()
            } catch is CancellationError {
                notice = "Download stoppet."
            } catch {
                AppDiagnostics.record(error)
                notice = "Billedmodellen kunne ikke hentes. Tjek internet og ledig plads, og prøv igen."
            }
        }
    }
}

struct StudioImageDetails: Codable, Sendable {
    var prompt: String? = nil
    var negativePrompt: String? = nil
    var seed: UInt32? = nil
    var model: String? = nil
    var steps: Int? = nil
    var tags: [String] = []
    var favorite = false
}

struct StudioImageRequest {
    let model: String
    let prompt: String
    let negative: String
    let lora: String
    let count: Int
    let seed: UInt32?
    let sourceImage: Data?
    let isPrivate: Bool
    let autoSave: Bool
    let botID: UUID?
    let allowPCFallback: Bool
}

struct StudioSessionPreferences {
    var textModel = ""
    var imageModel = "sd_v1.5_f16.ckpt"
    var lora = ""
    var personality = "bot"
    var voiceLanguage = "da-DK"
    var danishVoice = ""
    var englishVoice = ""
    var backdrop = Data()
    var idleMinutes = 5.0
    var modelTimeoutMinutes = 5.0
}

enum StudioGalleryFilter: String, CaseIterable, Identifiable {
    case all = "Alle", favorites = "Favoritter", today = "I dag", week = "Denne uge"
    var id: Self { self }
}

struct StudioImageSheet: Identifiable {
    let url: URL
    var id: URL { url }
}

struct StudioMultiShare: Identifiable {
    let id = UUID()
    let files: [URL]
}

struct StudioImageShareController: UIViewControllerRepresentable {
    let files: [URL]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: files, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

struct StudioImageViewer: View {
    let files: [URL]
    let privateImages: [URL: Data]
    @State var selected: URL
    @Environment(\.dismiss) var dismiss

    init(files: [URL], selected: URL, privateImages: [URL: Data] = [:]) {
        self.files = files
        self.privateImages = privateImages
        _selected = State(initialValue: selected)
    }

    var body: some View {
        NavigationStack {
            TabView(selection: $selected) {
                ForEach(files, id: \.self) { file in
                    GeometryReader { size in
                        let limit = Int(max(size.size.width, size.size.height) * 3)
                        if let current = files.firstIndex(of: selected), let candidate = files.firstIndex(of: file),
                           abs(current - candidate) > 1 {
                            Color.clear
                        } else if let source = studioImageSource(file, privateImages: privateImages),
                           let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                            kCGImageSourceCreateThumbnailFromImageAlways: true,
                            kCGImageSourceCreateThumbnailWithTransform: true,
                            kCGImageSourceThumbnailMaxPixelSize: max(1024, min(2400, limit))
                           ] as CFDictionary) {
                            Image(uiImage: UIImage(cgImage: thumbnail)).resizable().scaledToFit()
                                .frame(width: size.size.width, height: size.size.height)
                                .accessibilityLabel("Billede i fuld skærm")
                        } else {
                            ContentUnavailableView("Billedet mangler", systemImage: "photo")
                        }
                    }.tag(file)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: files.count > 1 ? .automatic : .never))
            .navigationTitle("Billedfremviser").navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Luk") { dismiss() } }
        }
    }
}

func studioImageSource(_ file: URL, privateImages: [URL: Data]) -> CGImageSource? {
    if let bytes = privateImages[file] { return CGImageSourceCreateWithData(bytes as CFData, nil) }
    guard (try? LocalFileStore.checkedFileSize(file, maximumBytes: 80_000_000)) != nil else { return nil }
    return CGImageSourceCreateWithURL(file as CFURL, nil)
}

struct StudioImageComparisonSource {
    let result: URL
    let bytes: Data

    init?(result: URL, bytes: Data?) {
        // The generation input has already been downsampled by StudioPhotoInput.
        guard let bytes, (1...2_000_000).contains(bytes.count) else { return nil }
        self.result = result
        self.bytes = bytes
    }
}

struct StudioImageComparison: View {
    let source: StudioImageComparisonSource
    let result: UIImage
    @State private var expanded = false

    var body: some View {
        DisclosureGroup("Sammenlign med basebilledet", isExpanded: $expanded) {
            if expanded {
                if let base = UIImage(data: source.bytes) {
                    StudioImageComparisonCanvas(base: base, result: result)
                        .padding(.top, FadedSpacing.s)
                } else {
                    FadedDetailText("Basebilledet kunne ikke vises.")
                }
            }
        }
        .frame(minHeight: 44)
    }
}

private struct StudioImageComparisonCanvas: View {
    let base: UIImage
    let result: UIImage
    @Environment(\.fadedPalette) private var palette
    @State private var reveal = 0.5

    var body: some View {
        VStack(alignment: .leading, spacing: FadedSpacing.s) {
            GeometryReader { geometry in
                let edge = geometry.size.width * CGFloat(1 - reveal)
                ZStack {
                    palette.background
                    fittedImage(result, in: geometry.size)
                    fittedImage(base, in: geometry.size)
                        .background(palette.background)
                        .mask(alignment: .leading) { Rectangle().frame(width: edge) }
                    if reveal > 0, reveal < 1 {
                        Rectangle().fill(FadedColors.lime).frame(width: 2)
                            .position(x: edge, y: geometry.size.height / 2)
                    }
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(.rect(cornerRadius: FadedRadius.small))
            .accessibilityHidden(true)
            HStack {
                FadedDetailText("Basebillede")
                Spacer()
                FadedDetailText("Resultat")
            }
            Slider(value: $reveal, in: 0...1)
                .frame(minHeight: 44)
                .accessibilityLabel("Vis mere af basebilledet eller resultatet")
                .accessibilityValue("\(reveal.formatted(.percent.precision(.fractionLength(0)))) resultat")
        }
    }

    private func fittedImage(_ image: UIImage, in size: CGSize) -> some View {
        Image(uiImage: image).resizable().scaledToFit().frame(width: size.width, height: size.height)
    }
}

enum LocalSpeechVoice {
    static var personalVoices: [AVSpeechSynthesisVoice] {
        guard AVSpeechSynthesizer.personalVoiceAuthorizationStatus == .authorized else { return [] }
        return AVSpeechSynthesisVoice.speechVoices().filter { $0.voiceTraits.contains(.isPersonalVoice) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func options(language: String, includePersonalVoices: Bool = false) -> [AVSpeechSynthesisVoice] {
        let base = language.split(separator: "-").first
        let systemVoices = AVSpeechSynthesisVoice.speechVoices().filter {
            !$0.voiceTraits.contains(.isPersonalVoice) && $0.language.split(separator: "-").first == base
        }
            .sorted { lhs, rhs in
                let leftMatch = lhs.language == language
                let rightMatch = rhs.language == language
                if leftMatch != rightMatch { return leftMatch }
                if lhs.quality != rhs.quality { return lhs.quality.rawValue > rhs.quality.rawValue }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        return includePersonalVoices ? personalVoices + systemVoices : systemVoices
    }

    static func preferred(language: String) -> AVSpeechSynthesisVoice? {
        if let voice = options(language: language).first { return voice }
        guard let voice = AVSpeechSynthesisVoice(language: language), !voice.voiceTraits.contains(.isPersonalVoice) else { return nil }
        return voice
    }

    static func resolve(identifier: String?, language: String) -> AVSpeechSynthesisVoice? {
        if let identifier, !identifier.isEmpty, let voice = AVSpeechSynthesisVoice(identifier: identifier),
           !voice.voiceTraits.contains(.isPersonalVoice) || AVSpeechSynthesizer.personalVoiceAuthorizationStatus == .authorized {
            return voice
        }
        return preferred(language: language)
    }

    static func label(_ voice: AVSpeechSynthesisVoice) -> String {
        "\(voice.name) · \(qualityLabel(voice)) · \(voice.language)"
    }

    static func qualityLabel(_ voice: AVSpeechSynthesisVoice) -> String {
        if voice.voiceTraits.contains(.isPersonalVoice) { return "Personlig" }
        return switch voice.quality {
        case .premium: "Premium"
        case .enhanced: "Forbedret"
        default: "Standard"
        }
    }

    static func previewSentence(language: String) -> String {
        switch language.split(separator: "-").first.map(String.init) ?? "" {
        case "en": "Hello. This is how my voice sounds in FadedAI."
        case "es": "Hola. Así suena mi voz en FadedAI."
        case "zh": "你好！这是我在 FadedAI 里的声音。"
        default: "Hej. Sådan lyder min stemme i FadedAI."
        }
    }
}
