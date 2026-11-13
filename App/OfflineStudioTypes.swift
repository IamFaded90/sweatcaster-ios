// OfflineStudioTypes.swift
// Definerer studiets modeller, billedfremviser og stemmehjælp.

import AVFAudio
import CoreTransferable
import ImageIO
import MediaGenerationKit
import NaturalLanguage
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

enum StudioImageModel: String, CaseIterable, Identifiable, Sendable {
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
    var downloadFiles: [StudioImageDownloadFile] {
        // Match the model filenames and hashes from the pinned Draw Things ModelZoo catalog.
        switch self {
        case .stableDiffusion:
            [StudioImageDownloadFile(name: id, sha256: "bf867591702e4c5d86cb126a3601d7e494180cce956b8dfaf90e5093d2e7c0f6"),
             StudioImageDownloadFile(name: "clip_vit_l14_f16.ckpt", sha256: "809bfd12c8d4b3d79c14e850b99130a70854f6fd8dedcacdf429417c02fa3007"),
             StudioImageDownloadFile(name: "vae_ft_mse_840000_f16.ckpt", sha256: "3b35514e11dd2b913e0579089babc1dfbd36589a77044c2e9b8065187e2f4154")]
        case .fluxKlein:
            [StudioImageDownloadFile(name: id, sha256: "430ba0f94ee0851a7f95c1383527f931afa6219898a51c5aa8e37979e9e4c86a"),
             StudioImageDownloadFile(name: "qwen_3_4b_q8p.ckpt", sha256: "a24e3f832917aafe7f6186e6dfb96ab19a4a0729cdf60a875b5da20024333350"),
             StudioImageDownloadFile(name: "flux_2_vae_f16.ckpt", sha256: nil)]
        }
    }

    var isInstalled: Bool {
        let environment = MediaGenerationEnvironment.default
        // Offline inspection checks the renderer's catalog; verify the dependency files as well.
        guard let resolved = try? environment.inspectModel(id, offline: true), resolved.isDownloaded else { return false }
        return downloadFiles.allSatisfy(\.isPresent)
    }
}

struct StudioImageDownloadsView: View {
    let canStart: Bool
    private var downloads: StudioImageDownloads { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: FadedSpacing.section) {
            FadedSectionHeader("Billedmodeller", detail: "Hent modellen én gang. Download fortsætter i baggrunden.")
            ForEach(StudioImageModel.allCases) { model in
                FadedCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Label(model.title, systemImage: "photo").font(.headline)
                        FadedDetailText(model == .stableDiffusion
                                        ? "Start her. Kræver mindst 4 GB ledig plads før download."
                                        : "Tungere model. Kræver mindst 8 GB ledig plads før download.")
                        if downloads.activeModel == model {
                            StudioImageDownloadProgress()
                        } else if model.isInstalled {
                            Label("Gemt på telefonen", systemImage: "checkmark.circle")
                        } else {
                            FadedSecondaryButton("Hent billedmodel", icon: "arrow.down.circle") { downloads.start(model) }
                                .accessibilityLabel("Hent \(model.title)").disabled(!canStart)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if let notice = downloads.notice { FadedDetailText(notice).accessibilityAddTraits(.updatesFrequently) }
        }
    }
}

struct StudioImageDownloadProgress: View {
    var body: some View {
        let downloads = StudioImageDownloads.shared
        if downloads.isInterrupted {
            FadedSecondaryButton("Fortsæt download", icon: "arrow.down.circle") { downloads.resume() }
        } else if let progress = downloads.progress, progress < 1 {
            ProgressView(value: progress) { Text(progress.formatted(.percent)) }
        } else {
            ProgressView(progressLabel(downloads.progress))
        }
        FadedSecondaryButton("Stop download", icon: "stop.fill") { downloads.cancel() }
    }

    private func progressLabel(_ progress: Double?) -> String {
        if progress == 1 {
            return "Kontrollerer billedmodellen…"
        }
        return "Henter billedmodellen…"
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

enum StudioImageRoute: String, CaseIterable, Identifiable {
    case automatic, phone, pc

    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: "Auto"
        case .phone: "Telefon"
        case .pc: "PC"
        }
    }
}

struct StudioImageRequest {
    let model: String
    let route: StudioImageRoute
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

    var supportsPC: Bool {
        !isPrivate && sourceImage == nil && seed == nil && count == 1
            && prompt.count <= 1_000 && negative.isEmpty && lora.isEmpty
    }
}

struct StudioSessionPreferences {
    var imageModel = "sd_v1.5_f16.ckpt"
    var lora = ""
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
    static let downloadHint = "Hent en Forbedret- eller Premium-stemme under Indstillinger → Tilgængelighed → Læs og tal (Oplæst indhold) → Stemmer."

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

    static func forReply(_ voice: AVSpeechSynthesisVoice?, language: String?) -> AVSpeechSynthesisVoice? {
        guard let language else { return voice }
        if let voice, voice.language.split(separator: "-").first == language.split(separator: "-").first {
            return voice
        }
        return preferred(language: language)
    }

    static func detectedReplyLanguage(_ text: String) -> String? {
        guard text.split(whereSeparator: \.isWhitespace).count >= 4 else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.prefix(1000)))
        let probabilities = recognizer.languageHypotheses(withMaximum: 1)
        if probabilities[.danish, default: 0] >= 0.8 { return "da-DK" }
        if probabilities[.english, default: 0] >= 0.8 { return "en-US" }
        return nil
    }

    static func utterance(_ text: String, voice: AVSpeechSynthesisVoice?, rate: Double) -> AVSpeechUtterance {
        let result = AVSpeechUtterance(string: text)
        result.voice = voice
        result.rate = AVSpeechUtteranceDefaultSpeechRate * Float(rate.isFinite ? min(1.3, max(0.7, rate)) : 1)
        return result
    }

    static func replyText(_ text: String) -> String {
        let prose = text.components(separatedBy: "```").enumerated().compactMap { index, block in
            index.isMultiple(of: 2) ? block : nil
        }.joined(separator: "\n\n")
        let spoken = prose.replacingOccurrences(of: #"(?m)^[ \t]*(?:#{1,6}|[-*+>])[ \t]+"#,
                                               with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spoken.isEmpty else { return text }
        let markdown = try? AttributedString(markdown: spoken, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        return markdown.map { String($0.characters) } ?? spoken
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
