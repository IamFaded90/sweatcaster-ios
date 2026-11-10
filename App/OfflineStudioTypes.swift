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
    var isInstalled: Bool {
        (try? MediaGenerationEnvironment.default.inspectModel(rawValue, offline: true))?.isDownloaded == true
    }

    func ensure(progress: @escaping @Sendable (Double) -> Void) async throws {
        _ = try await MediaGenerationEnvironment.default.ensure(rawValue) { state in
            if case .downloading(_, let index, let count, let written, let total) = state, count > 0, total > 0 {
                let part = min(1, Double(written) / Double(total))
                progress(min(1, (Double(max(0, index - 1)) + part) / Double(count)))
            }
        }
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
            FadedSectionHeader("Billedmodeller", detail: "Hent modellen her, før du åbner Privat Studio. Hold siden åben under download.")
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
                            Label("Klar på telefonen", systemImage: "checkmark.circle")
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
        guard canStart else { return }
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

enum LocalSpeechVoice {
    static func options(language: String) -> [AVSpeechSynthesisVoice] {
        let base = language.split(separator: "-").first
        return AVSpeechSynthesisVoice.speechVoices().filter { $0.language.split(separator: "-").first == base }
            .sorted { lhs, rhs in
                let leftMatch = lhs.language == language
                let rightMatch = rhs.language == language
                if leftMatch != rightMatch { return leftMatch }
                if lhs.quality != rhs.quality { return lhs.quality.rawValue > rhs.quality.rawValue }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }

    static func preferred(language: String) -> AVSpeechSynthesisVoice? {
        options(language: language).first ?? AVSpeechSynthesisVoice(language: language)
    }

    static func resolve(identifier: String?, language: String) -> AVSpeechSynthesisVoice? {
        identifier.flatMap { AVSpeechSynthesisVoice(identifier: $0) } ?? preferred(language: language)
    }

    static func label(_ voice: AVSpeechSynthesisVoice) -> String {
        let quality = switch voice.quality {
        case .premium: "Premium"
        case .enhanced: "Forbedret"
        default: "Standard"
        }
        return "\(voice.name) · \(quality) · \(voice.language)"
    }
}
