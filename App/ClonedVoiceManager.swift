import AVFoundation
import FadedAICloneRuntime
import SwiftUI

@MainActor final class ClonedVoiceManager: ObservableObject {
    static let shared = ClonedVoiceManager()
    static let base = URL.applicationSupportDirectory.appendingPathComponent("FadedAI/VoiceCloneModels", isDirectory: true)
    private static var marker: URL { base.appendingPathComponent("installed.json") }
    @Published private(set) var voices: [ClonedVoice.Voice] = []
    @Published private(set) var installed = false
    @Published private(set) var progress: Double?
    @Published var notice: String?
    private var downloading: Task<Void, Never>?
    init() { refresh() }
    static func ready() -> Bool {
        guard let bytes = try? marker.resourceValues(forKeys: [.fileSizeKey]).fileSize, bytes < 200_000,
              let data = try? Data(contentsOf: marker), let install = try? JSONDecoder().decode(ClonedVoice.Install.self, from: data) else { return false }
        return install.valid(in: base)
    }
    func refresh() { voices = (try? ClonedVoice.Store().list()) ?? []; installed = Self.ready() }
    func download() {
        guard downloading == nil else { return }; progress = 0; notice = nil
        downloading = Task {
            defer { progress = nil; downloading = nil; refresh() }
            do {
                try FileManager.default.createDirectory(at: Self.base, withIntermediateDirectories: true)
                let files = try await CloneRuntime.download(root: Self.base) { fraction in Task { @MainActor in self.progress = fraction } }
                try Task.checkCancellation()
                let install = ClonedVoice.Install(files: files); guard install.valid(in: Self.base) else { throw ClonedVoice.Failure.model }
                try JSONEncoder().encode(install).write(to: Self.marker, options: .atomic)
                var root = Self.base; var flags = URLResourceValues(); flags.isExcludedFromBackup = true; try root.setResourceValues(flags)
                notice = "Modellen er hentet. Nu kan du oprette og prøve en stemme uden net."
            } catch { notice = Task.isCancelled ? "Hentningen er sat på pause. Tryk Fortsæt for at prøve igen." : error.localizedDescription }
        }
    }
    func pause() { downloading?.cancel() }
    func removeModel() async {
        guard downloading == nil, !LocalCompute.isRunning else { notice = "Stop den aktive AI-opgave først."; return }
        do {
            await CloneVoiceEngine.shared.unload()
            let target = Self.base.standardizedFileURL.resolvingSymlinksInPath()
            let parent = URL.applicationSupportDirectory.appendingPathComponent("FadedAI", isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
            guard target.deletingLastPathComponent().path == parent.path else { throw ClonedVoice.Failure.model }
            if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
            refresh(); notice = "Modellen er slettet. Dine navngivne stemmer er bevaret."
        } catch { notice = error.localizedDescription }
    }
    func remove(_ voice: ClonedVoice.Voice) {
        do { try ClonedVoice.Store().remove(voice.id); refresh() } catch { notice = error.localizedDescription }
    }
    func approve(_ voice: ClonedVoice.Voice) {
        do { var saved = voice; saved.previewApproved = true; try ClonedVoice.Store().save(saved); refresh() } catch { notice = error.localizedDescription }
    }
    func create(name: String, reference: URL) async throws -> ClonedVoice.Voice {
        let voice = ClonedVoice.Voice(name: name.trimmingCharacters(in: .whitespacesAndNewlines))
        guard voice.valid else { throw ClonedVoice.Failure.name }; guard Self.ready() else { throw ClonedVoice.Failure.model }
        let bytes = try reference.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        let duration = try await AVURLAsset(url: reference).load(.duration)
        try ClonedVoice.recording(seconds: duration.seconds, bytes: bytes)
        let store = ClonedVoice.Store(), folder = ClonedVoice.Store().folder(voice.id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var committed = false
        defer { if !committed { try? store.remove(voice.id) } }
        let output = try store.conditions(voice.id)
        await AgentVoiceDownload.releaseSynthesisResources()
        try await LocalCompute.run(minimumMiB: 2_200) {
            try await CloneVoiceEngine.shared.clone(reference: reference, root: Self.base, output: output)
        }
        try Task.checkCancellation(); try store.save(voice)
        guard store.ready(voice.id) else { throw ClonedVoice.Failure.missing }
        committed = true; refresh(); return voice
    }
    static func audio(_ text: String, id: UUID, language: String) async throws -> Data {
        guard Self.ready(), ClonedVoice.Store().ready(id) else { throw ClonedVoice.Failure.missing }
        let voice = try ClonedVoice.Store().conditions(id)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= 1_000 else { throw ClonedVoice.Failure.samples }
        return try await LocalCompute.run(minimumMiB: 1_800) {
            let samples = try await CloneVoiceEngine.shared.samples(text: text, voice: voice, root: Self.base, language: language.hasPrefix("en") ? "en" : "da")
            try Task.checkCancellation(); return try ClonedVoice.wav(samples)
        }
    }
}

@MainActor final class ClonedVoiceRecorder: ObservableObject {
    @Published private(set) var recording = false
    @Published private(set) var seconds = 0.0
    @Published private(set) var url: URL?
    @Published var notice: String?
    private var recorder: AVAudioRecorder?
    private var clock: Task<Void, Never>?
    private var generation = UUID()
    func start() {
        clear(); let requested = generation
        Task {
            guard await AVAudioApplication.requestRecordPermission() else { notice = "Tillad mikrofonen i iPhones indstillinger, eller vælg en lydfil."; return }
            guard generation == requested else { return }
            do {
                let file = FileManager.default.temporaryDirectory.appendingPathComponent("FadedAI-voice-" + UUID().uuidString + ".m4a")
                let session = AVAudioSession.sharedInstance(); try session.setCategory(.record, mode: .measurement); try session.setActive(true)
                let capture = try AVAudioRecorder(url: file, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 24_000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 128_000])
                guard capture.record() else { throw ClonedVoice.Failure.recording }
                recorder = capture; url = file; recording = true; seconds = 0
                clock = Task { while !Task.isCancelled, recording {
                    seconds = recorder?.currentTime ?? seconds
                    if seconds >= 30 { stop(); return }
                    do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                } }
            } catch { stop(); notice = error.localizedDescription }
        }
    }
    func stop() {
        generation = UUID()
        recorder?.stop(); recorder = nil; recording = false; clock?.cancel(); clock = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
    func clear() { stop(); if let url { try? FileManager.default.removeItem(at: url) }; url = nil; seconds = 0; notice = nil }
}
