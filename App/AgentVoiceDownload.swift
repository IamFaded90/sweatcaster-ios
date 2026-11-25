import SwiftUI
import CryptoKit
import OfflineVoiceRuntime
import FadedAICloneRuntime

struct DownloadedAgentVoice: Identifiable, Equatable {
    let code: String
    static let presets = ["F1","F2","F3","F4","F5","M1","M2","M3","M4","M5"].map(Self.init(code:))
    static var all: [Self] { presets + ((try? ClonedVoice.Store().list()) ?? []).filter { $0.previewApproved && ClonedVoice.Store().ready($0.id) }.map { Self(code: "clone." + $0.id.uuidString.lowercased()) } }
    @MainActor static var playable: [Self] { all.filter { AgentVoiceDownload.available($0) } }
    var cloneID: UUID? { code.hasPrefix("clone.") ? UUID(uuidString: String(code.dropFirst(6))) : nil }
    var id: String { cloneID.map { "chatterbox-" + $0.uuidString.lowercased() } ?? ("supertonic3-" + code) }
    var name: String {
        if let cloneID { return (try? ClonedVoice.Store().list())?.first { $0.id == cloneID }?.name ?? "Egen stemme" }
        return (code.hasPrefix("F") ? "Kvindelig stemme " : "Mandlig stemme ") + String(code.suffix(1))
    }
    var label: String { name + " · dansk på iPhone" }
    static func selected(_ id: String) -> Self? { all.first { $0.id == id } }
}

private struct VoicePackAsset: Sendable {
    let path: String
    let bytes: Int64
    let sha256: String
    init(_ path: String, _ bytes: Int64, _ sha256: String) {
        self.path = path; self.bytes = bytes; self.sha256 = sha256
    }
}

private enum VoicePackFiles {
    static let revision = "3cadd1ee6394adea1bd021217a0e650ede09a323"
    static let base = URL.applicationSupportDirectory.appendingPathComponent("FadedAI/Supertonic3", isDirectory: true)
    static let installed = base.appendingPathComponent(revision, isDirectory: true)
    static let staging = base.appendingPathComponent("download-" + revision, isDirectory: true)
    static let assets: [VoicePackAsset] = [
        .init("LICENSE", 15007, "0d944a9110fed9a9602d60e0423a272903e7bd21ab060490774efc77c2275e9f"),
        .init("onnx/duration_predictor.onnx", 3700147, "c3eb91414d5ff8a7a239b7fe9e34e7e2bf8a8140d8375ffb14718b1c639325db"),
        .init("onnx/text_encoder.onnx", 36416150, "c7befd5ea8c3119769e8a6c1486c4edc6a3bc8365c67621c881bbb774b9902ff"),
        .init("onnx/tts.json", 8253, "42078d3aef1cd43ab43021f3c54f47d2d75ceb4e75f627f118890128b06a0d09"),
        .init("onnx/unicode_indexer.json", 277676, "9bf7346e43883a81f8645c81224f786d43c5b57f3641f6e7671a7d6c493cb24f"),
        .init("onnx/vector_estimator.onnx", 256534781, "883ac868ea0275ef0e991524dc64f16b3c0376efd7c320af6b53f5b780d7c61c"),
        .init("onnx/vocoder.onnx", 101424195, "085de76dd8e8d5836d6ca66826601f615939218f90e519f70ee8a36ed2a4c4ba"),
        .init("voice_styles/F1.json", 292046, "bbdec6ee00231c2c742ad05483df5334cab3b52fda3ba38e6a07059c4563dbc2"),
        .init("voice_styles/F2.json", 292423, "7c722c6a72707b1a77f035d67f0d1351ba187738e06f7683e8c72b1df3477fc6"),
        .init("voice_styles/F3.json", 290794, "12f6ef2573baa2defa1128069cb59f203e3ab67c92af77b42df8a0e3a2f7c6ab"),
        .init("voice_styles/F4.json", 291808, "c2fa764c1225a76dfc3e2c73e8aa4f70d9ee48793860eb34c295fff01c2e032b"),
        .init("voice_styles/F5.json", 291479, "45966e73316415626cf41a7d1c6f3b4c70dbc1ba2bee5c1978ef0ce33244fc8d"),
        .init("voice_styles/M1.json", 291748, "e35604687f5d23694b8e91593a93eec0e4eca6c0b02bb8ed69139ab2ea6b0a5b"),
        .init("voice_styles/M2.json", 292055, "b76cbf62bac707c710cf0ae5aba5e31eea1a6339a9734bfae33ab98499534a50"),
        .init("voice_styles/M3.json", 290198, "ea1ac35ccb91b0d7ecad533a2fbd0eec10c91513d8951e3b25fbba99954e159b"),
        .init("voice_styles/M4.json", 291522, "ca8eefad4fcd989c9379032ff3e50738adc547eeb5e221b82593a6d7b3bac303"),
        .init("voice_styles/M5.json", 291469, "dd22b92740314321f8ae11c5e87f8dd60d060f15dd3a632b5adf77f471f77af2"),
    ]
    static var total: Int64 { assets.reduce(0) { $0 + $1.bytes } }

    static func ready(in root: URL) -> Bool {
        assets.allSatisfy {
            let file = root.appendingPathComponent($0.path)
            return (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) == Int($0.bytes)
        }
    }

    static func verified(_ file: URL, _ asset: VoicePackAsset) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        var size: Int64 = 0
        while let chunk = try handle.read(upToCount: 256 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            size += Int64(chunk.count)
            guard size <= asset.bytes else { return false }
            hash.update(data: chunk)
        }
        return size == asset.bytes && hash.finalize().map { String(format: "%02x", $0) }.joined() == asset.sha256
    }
}

private final class VoiceDownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let update: @Sendable (Int64) -> Void
    init(update: @escaping @Sendable (Int64) -> Void) { self.update = update }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        update(totalBytesWritten)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}

private enum VoicePackInstall {
    static func run(progress: @escaping @Sendable (Int64) -> Void) async throws {
        let fm = FileManager.default
        var base = VoicePackFiles.base
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        var flags = URLResourceValues()
        flags.isExcludedFromBackup = true
        try base.setResourceValues(flags)
        let staging = VoicePackFiles.staging
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        var completed: Int64 = 0
        for asset in VoicePackFiles.assets {
            try Task.checkCancellation()
            let destination = staging.appendingPathComponent(asset.path)
            if fm.fileExists(atPath: destination.path), try VoicePackFiles.verified(destination, asset) {
                completed += asset.bytes
                progress(completed)
                continue
            }
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            let space = try base.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            if let available = space.volumeAvailableCapacityForImportantUsage,
               available < asset.bytes + 30_000_000 { throw CocoaError(.fileWriteOutOfSpace) }
            let origin = URL(string: "https://huggingface.co/Supertone/supertonic-3/resolve/")!
            let url = origin.appendingPathComponent(VoicePackFiles.revision).appendingPathComponent(asset.path)
            let already = completed
            let delegate = VoiceDownloadProgress { progress(already + min($0, asset.bytes)) }
            let (file, response) = try await session.download(for: URLRequest(url: url), delegate: delegate)
            defer { try? fm.removeItem(at: file) }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  try VoicePackFiles.verified(file, asset) else { throw URLError(.cannotDecodeContentData) }
            try fm.moveItem(at: file, to: destination)
            completed += asset.bytes
            progress(completed)
        }
        try Task.checkCancellation()
        let installed = VoicePackFiles.installed
        if fm.fileExists(atPath: installed.path) { try fm.removeItem(at: installed) }
        try fm.moveItem(at: staging, to: installed)
    }
}

private actor LocalVoiceSynthesis {
    static let shared = LocalVoiceSynthesis()
    private var model: SupertonicVoice?
    private var idleRelease: Task<Void, Never>?
    func unload() {
        idleRelease?.cancel()
        idleRelease = nil
        model = nil
    }
    private func releaseAfterPlayback() {
        idleRelease?.cancel()
        idleRelease = Task {
            do { try await Task.sleep(for: .seconds(20)) } catch { return }
            unload()
        }
    }
    func audio(_ text: String, voice: DownloadedAgentVoice, language: String, rate: Double) throws -> Data {
        try Task.checkCancellation()
        guard VoicePackFiles.ready(in: VoicePackFiles.installed) else { throw CocoaError(.fileReadNoSuchFile) }
        idleRelease?.cancel()
        defer { releaseAfterPlayback() }
        if model == nil { model = try SupertonicVoice(directory: VoicePackFiles.installed) }
        guard let model else { throw CocoaError(.fileReadCorruptFile) }
        return try model.render(text, style: voice.code, language: language.hasPrefix("en") ? "en" : "da", rate: rate)
    }
}

@MainActor final class AgentVoiceDownload: ObservableObject {
    static let shared = AgentVoiceDownload()
    @Published private(set) var installed = VoicePackFiles.ready(in: VoicePackFiles.installed)
    @Published private(set) var partial = FileManager.default.fileExists(atPath: VoicePackFiles.staging.path)
    @Published private(set) var progress: Double?
    @Published private(set) var message: String?
    private var task: Task<Void, Never>?
    func download() {
        guard task == nil, !installed else { return }
        progress = 0
        message = nil
        task = Task {
            do {
                try await VoicePackInstall.run { bytes in
                    Task { @MainActor in
                        guard let current = self.progress else { return }
                        self.progress = max(current, min(1, Double(bytes) / Double(VoicePackFiles.total)))
                    }
                }
            } catch {
                let cancelled = Task.isCancelled
                let noSpace = (error as NSError).domain == NSCocoaErrorDomain &&
                    (error as NSError).code == CocoaError.fileWriteOutOfSpace.rawValue
                message = cancelled ? "Hentningen er sat på pause." : noSpace ? "Frigør plads på telefonen, og prøv igen." :
                    "Hentningen blev afbrudt. Tryk Hent igen for at fortsætte."
            }
            installed = VoicePackFiles.ready(in: VoicePackFiles.installed)
            partial = FileManager.default.fileExists(atPath: VoicePackFiles.staging.path)
            progress = nil
            task = nil
        }
    }
    func cancel() { task?.cancel() }
    func remove() {
        guard task == nil else { return }
        do {
            if FileManager.default.fileExists(atPath: VoicePackFiles.base.path) {
                try FileManager.default.removeItem(at: VoicePackFiles.base)
            }
            installed = false
            partial = false
            message = nil
            Task { await LocalVoiceSynthesis.shared.unload() }
        } catch { message = "Stemmepakken kunne ikke slettes. Prøv igen." }
    }
    static func audio(_ text: String, voice: DownloadedAgentVoice, language: String, rate: Double) async throws -> Data {
        if let id = voice.cloneID { return try await ClonedVoiceManager.audio(text, id: id, language: language) }
        return try await LocalVoiceSynthesis.shared.audio(text, voice: voice, language: language, rate: rate)
    }
    static func available(_ voice: DownloadedAgentVoice) -> Bool {
        if let id = voice.cloneID { return ClonedVoiceManager.shared.installed && ClonedVoice.Store().ready(id) }
        return shared.installed
    }
    static func ready(selection: String) -> Bool { DownloadedAgentVoice.selected(selection).map(available) ?? shared.installed }
    static func releaseSynthesisResources() async {
        // The actor finishes any active synthesis before releasing its cached sessions.
        await LocalVoiceSynthesis.shared.unload()
        await CloneVoiceEngine.shared.unload()
    }
}

struct DownloadedVoiceOptions: View {
    let selection: String
    @ObservedObject private var pack = AgentVoiceDownload.shared
    @ObservedObject private var own = ClonedVoiceManager.shared
    var body: some View {
        ForEach(DownloadedAgentVoice.all.filter { AgentVoiceDownload.available($0) }) { voice in Text(voice.label).tag(voice.id) }
        if let voice = DownloadedAgentVoice.selected(selection), !AgentVoiceDownload.available(voice) { Text(voice.name + " · hent modellen igen").tag(voice.id) }
    }
}

struct AgentVoicePackSection: View {
    let selected: String
    let previewing: String?
    let choose: (String) -> Void
    let preview: (DownloadedAgentVoice) -> Void
    let stop: () -> Void
    @ObservedObject private var pack = AgentVoiceDownload.shared
    @State private var confirmRemoval = false

    var body: some View {
        Section("Danske stemmer uden PC") {
            if pack.installed {
                ForEach(DownloadedAgentVoice.presets) { voice in
                    HStack {
                        Button { choose(voice.id) } label: {
                            HStack {
                                Text(voice.name)
                                Spacer()
                                if selected == voice.id { Image(systemName: "checkmark.circle.fill") }
                            }.frame(minHeight: 44).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityAddTraits(selected == voice.id ? .isSelected : [])
                        Button { preview(voice) } label: {
                            Image(systemName: previewing == voice.id ? "stop.circle" : "play.circle")
                                .font(.title2).frame(width: 48, height: 48)
                        }.buttonStyle(.borderless).accessibilityLabel("Hør " + voice.name)
                    }
                }
            } else if let progress = pack.progress {
                ProgressView("Henter stemmer", value: progress)
                Button("Sæt på pause", systemImage: "pause") { pack.cancel() }
            } else {
                Text("Supertonic laver syntetisk tale på din iPhone med fem kvinde- og fem mandestemmer. Efter hentning kan du høre og vælge en stemme til hver agent.")
                Button(pack.partial ? "Fortsæt hentning" : "Hent 10 stemmer · 401 MB", systemImage: "arrow.down.circle") { pack.download() }
            }
            if let message = pack.message { Text(message).font(.footnote).foregroundStyle(.secondary) }
            if (pack.partial || pack.installed) && pack.progress == nil {
                Button("Slet stemmepakken", role: .destructive) { confirmRemoval = true }
            }
            Link("Supertonic 3 · model og licens", destination: URL(string: "https://huggingface.co/Supertone/supertonic-3")!)
                .font(.footnote)
        }
        .confirmationDialog("Slet stemmepakken fra denne iPhone?", isPresented: $confirmRemoval, titleVisibility: .visible) {
            Button("Slet stemmepakken", role: .destructive) { stop(); pack.remove() }
            Button("Annuller", role: .cancel) {}
        } message: { Text("Agenter med en stemme fra pakken kan bruge den igen, når du henter pakken.") }
        OwnVoiceSection(selected: selected, previewing: previewing, choose: choose, preview: preview, stop: stop)
    }
}
