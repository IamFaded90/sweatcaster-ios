import AudioToolbox
import AVFAudio
import CryptoKit
import FadedAIWhisperRuntime
import Foundation
import Observation

enum AgentWhisper {
    static let folder = URL.applicationSupportDirectory.appending(path: "WhisperDictation", directoryHint: .isDirectory)
    private static let model = folder.appending(path: "base-multilingual.bin")
    private static let url = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-base-q5_1.bin")!
    private static let bytes = 59_707_625
    private static let digest = "422f1ae452ade6f30a004d7e5c6a43195e4433bc370bf23fac9cc591f01a8898"
    private static let sampleRate = 16_000

    static var ready: Bool { (try? LocalFileStore.checkedFileSize(model, maximumBytes: bytes)) == bytes }

    static func install() async throws {
        guard !ready else { return }
        guard PhoneModels.hasDownloadSpace(bytes: Int64(bytes) + 100_000_000) else { throw APIError.storage }
        let (location, response) = try await URLSession.shared.download(from: url)
        defer { try? FileManager.default.removeItem(at: location) }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, GGUFHub.permittedHost(http.url),
              try LocalFileStore.checkedFileSize(location, maximumBytes: bytes) == bytes else { throw APIError.malformed }
        try await Task.detached(priority: .utility) {
            let input = try FileHandle(forReadingFrom: location)
            defer { try? input.close() }
            var hash = SHA256()
            while let data = try input.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
            guard hash.finalize().map({ String(format: "%02x", Int($0)) }).joined() == digest else { throw APIError.malformed }
            let fm = FileManager.default
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            if fm.fileExists(atPath: model.path) { try fm.removeItem(at: model) }
            try fm.moveItem(at: location, to: model)
            var target = model
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try target.setResourceValues(values)
        }.value
    }

    static func transcribe(_ url: URL, language: String) throws -> String {
        try transcribeSegments(url, language: language).map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func transcribeSegments(_ url: URL, language: String) throws -> [LocalWhisperEngine.Segment] {
        let file = try AVAudioFile(forReading: url)
        let frameCount = AVAudioFrameCount(min(Int64(sampleRate * 45), file.length))
        guard frameCount > 0, file.processingFormat.sampleRate == Double(sampleRate),
              let pcm = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount) else {
            throw APIError.malformed
        }
        try file.read(into: pcm, frameCount: frameCount)
        guard let samples = pcm.floatChannelData?[0] else { throw APIError.malformed }
        let code = language.hasPrefix("en") ? "en" : language.hasPrefix("da") ? "da" : "auto"
        guard let result = LocalWhisperEngine.transcribeSegments(modelPath: model.path, samples: samples,
                                                                count: Int32(pcm.frameLength), language: code) else {
            throw APIError.malformed
        }
        return result
    }
}

@MainActor @Observable final class AgentWhisperCapture {
    private var recorder: AVAudioRecorder?
    private var recordingURL: URL?
    private var revision = UUID()
    private var maxDuration: Task<Void, Never>?
    private(set) var active = false
    private(set) var processing = false
    private(set) var installing = false
    private(set) var segments: [LocalWhisperEngine.Segment] = []

    func install() async throws {
        guard !installing else { return }
        installing = true
        defer { installing = false }
        try await AgentWhisper.install()
    }

    func start(whenFull: @escaping @MainActor () -> Void) async throws {
        guard !active, !processing, AgentWhisper.ready else { throw APIError.storage }
        let id = UUID()
        revision = id
        segments = []
        guard await AVAudioApplication.requestRecordPermission(), revision == id else { throw APIError.input }
        let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".wav")
        let audio = AVAudioSession.sharedInstance()
        try audio.setCategory(.record, mode: .measurement)
        try audio.setActive(true)
        recordingURL = file
        do {
            recorder = try AVAudioRecorder(url: file, settings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16
            ])
            guard recorder?.record(forDuration: 45) == true else { throw APIError.storage }
            active = true
        } catch {
            cancel()
            try? audio.setActive(false, options: .notifyOthersOnDeactivation)
            throw error
        }
        maxDuration = Task {
            try? await Task.sleep(for: .seconds(45))
            if !Task.isCancelled, active { whenFull() }
        }
    }

    func finish(language: String) async throws -> String {
        guard active, let file = recordingURL else { throw APIError.input }
        let id = revision
        releaseMic()
        processing = true
        recordingURL = nil
        defer {
            try? FileManager.default.removeItem(at: file)
            processing = false
        }
        let result = try await LocalCompute.run(minimumMiB: 300) {
            try await Task.detached(priority: .userInitiated) {
                try AgentWhisper.transcribeSegments(file, language: language)
            }.value
        }
        guard revision == id else { throw CancellationError() }
        segments = result
        return result.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func cancel() {
        revision = UUID()
        segments = []
        releaseMic()
        if let recordingURL { try? FileManager.default.removeItem(at: recordingURL) }
        recordingURL = nil
    }

    private func releaseMic() {
        maxDuration?.cancel()
        maxDuration = nil
        if let recorder {
            recorder.stop()
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        recorder = nil
        active = false
    }
}
