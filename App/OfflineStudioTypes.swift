// OfflineStudioTypes.swift
// Definerer studiets modeller, billedfremviser og stemmehjælp.

import AVFAudio
import CoreTransferable
import ImageIO
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
