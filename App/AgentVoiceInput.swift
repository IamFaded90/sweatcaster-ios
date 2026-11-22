import AudioToolbox
import AVFAudio
import CryptoKit
import Darwin
import FadedAIWhisperRuntime
import Foundation
import Observation

enum AgentWhisper {
    enum Model: String, CaseIterable, Sendable {
        case base, small, danish

        var title: String {
            switch self {
            case .base: "lille offline-model"
            case .small: "flersproget offline-model"
            case .danish: "dansk offline-model"
            }
        }

        var downloadURL: URL {
            if self == .danish {
                return URL(string: "https://huggingface.co/AladdinChen/trans-local-speech-models/resolve/035921168a44cf4702e81eed7f3c9094c538323b/models/da/da-whisper-q8.bin")!
            }
            return URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-\(rawValue)-q5_1.bin")!
        }
        var bytes: Int {
            switch self {
            case .base: 59_707_625
            case .small: 190_085_487
            case .danish: 264_464_624
            }
        }
        var checksum: String {
            switch self {
            case .base: "422f1ae452ade6f30a004d7e5c6a43195e4433bc370bf23fac9cc591f01a8898"
            case .small: "ae85e4a935d7a567bd102fe55afc16bb595bdb618e11b2fc7591bc08120411bb"
            case .danish: "55e73c83b66e38a34484c715325f602f3f5aba6d4db1958541d7244c032546ab"
            }
        }
        var minimumMemoryMiB: UInt64 {
            switch self {
            case .base: 300
            case .small: 700
            case .danish: 800
            }
        }
        var file: URL { AgentWhisper.folder.appending(path: self == .danish ? "danish-q8.bin" : "\(rawValue)-multilingual.bin") }
        var installed: Bool { (try? LocalFileStore.checkedFileSize(file, maximumBytes: bytes)) == bytes }
    }

    enum Failure: Error { case inference }

    static let folder = URL.applicationSupportDirectory.appending(path: "WhisperDictation", directoryHint: .isDirectory)
    private static let sampleRate = 16_000

    static func languageCode(_ locale: String) -> String {
        let value = locale.lowercased()
        return value.hasPrefix("en") ? "en" : value.hasPrefix("da") ? "da" : "auto"
    }

    static func availableModels(for locale: String, installed: (Model) -> Bool = { $0.installed }) -> [Model] {
        let order: [Model] = languageCode(locale) == "da" ? [.danish, .small, .base] : [.base, .small]
        return order.filter(installed)
    }

    static func install(_ variant: Model = .base) async throws {
        guard !variant.installed else { return }
        let bytes = variant.bytes
        let model = variant.file
        guard PhoneModels.hasDownloadSpace(bytes: Int64(bytes) + 100_000_000) else { throw APIError.storage }
        let (location, response) = try await URLSession.shared.download(from: variant.downloadURL)
        defer { try? FileManager.default.removeItem(at: location) }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, GGUFHub.permittedHost(http.url),
              try LocalFileStore.checkedFileSize(location, maximumBytes: bytes) == bytes else { throw APIError.malformed }
        try Task.checkCancellation()
        let verification = Task.detached(priority: .utility) {
            let input = try FileHandle(forReadingFrom: location)
            defer { try? input.close() }
            var hash = SHA256()
            while let data = try input.read(upToCount: 1_048_576), !data.isEmpty {
                try Task.checkCancellation()
                hash.update(data: data)
            }
            guard hash.finalize().map({ String(format: "%02x", Int($0)) }).joined() == variant.checksum else { throw APIError.malformed }
            try Task.checkCancellation()
            try publishVerifiedDownload(location, to: model, within: folder, expectedBytes: bytes)
        }
        try await withTaskCancellationHandler {
            try await verification.value
        } onCancel: { verification.cancel() }
    }

    static func publishVerifiedDownload(_ download: URL, to model: URL, within folder: URL,
                                        expectedBytes: Int) throws {
        let manager = FileManager.default
        let target = try LocalFileStore.safeWriteURL(model, within: folder)
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        var staged = try LocalFileStore.safeWriteURL(
            folder.appending(path: ".whisper-\(UUID().uuidString).download"), within: folder
        )
        defer { try? manager.removeItem(at: staged) }
        try manager.moveItem(at: download, to: staged)
        guard try LocalFileStore.checkedFileSize(staged, maximumBytes: expectedBytes) == expectedBytes else {
            throw APIError.malformed
        }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try staged.setResourceValues(values)
        // The staged file shares the destination volume. Atomic rename keeps an installed model readable.
        let result = staged.withUnsafeFileSystemRepresentation { source in
            target.withUnsafeFileSystemRepresentation { destination -> Int32? in
                guard let source, let destination else { return nil }
                return Darwin.rename(source, destination)
            }
        }
        guard let result else { throw APIError.storage }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    static func transcribe(_ url: URL, language: String) throws -> String {
        guard let model = availableModels(for: language).first else { throw APIError.storage }
        return try transcribeSegments(url, language: language, model: model)
            .map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func transcribeSegments(_ url: URL, language: String, model: Model = .base,
                                   cancellation: LocalWhisperEngine.Cancellation? = nil) throws -> [LocalWhisperEngine.Segment] {
        try cancellation?.checkCancellation()
        let file = try AVAudioFile(forReading: url)
        let frameCount = AVAudioFrameCount(min(Int64(sampleRate * 45), file.length))
        guard frameCount > 0 else { return [] }
        guard file.processingFormat.sampleRate == Double(sampleRate),
              let pcm = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount) else {
            throw APIError.malformed
        }
        try file.read(into: pcm, frameCount: frameCount)
        guard let samples = pcm.floatChannelData?[0] else { throw APIError.malformed }
        guard hasMicrophoneSignal(UnsafeBufferPointer(start: samples, count: Int(pcm.frameLength))) else { return [] }
        // The Danish checkpoint was tuned with short text-only transcripts. Whisper still returns clip ranges.
        let result = withExtendedLifetime(pcm) {
            LocalWhisperEngine.transcribeSegments(
                modelPath: model.file.path, samples: samples, count: Int32(pcm.frameLength),
                language: languageCode(language), timestamped: model != .danish, cancellation: cancellation
            )
        }
        try cancellation?.checkCancellation()
        guard let result else { throw Failure.inference }
        return result
    }

    static func hasMicrophoneSignal(_ samples: UnsafeBufferPointer<Float>) -> Bool {
        // Ignore empty recordings and traces below -60 dBFS, so the decoder cannot invent a reply from digital silence.
        samples.contains { $0.isFinite && abs($0) >= 0.001 }
    }
}

struct AgentVoiceSilence {
    let pause: TimeInterval
    private var speechSamples = 0
    private var lastSpeech: TimeInterval?

    init(pause: TimeInterval) {
        self.pause = pause.isFinite ? min(4, max(1.4, pause)) : 2.5
    }

    mutating func ended(at time: TimeInterval, level: Float) -> Bool {
        if level >= -42 {
            speechSamples = min(3, speechSamples + 1)
            lastSpeech = time
            return false
        }
        if speechSamples < 3 { speechSamples = 0 }
        return speechSamples == 3 && lastSpeech.map { time - $0 >= pause } == true
    }
}

@MainActor protocol ChatWhisperRecording: AnyObject {
    func start(language: String, silenceAfter: TimeInterval?, whenFull: @escaping @MainActor () -> Void) async throws
    func finish(language: String) async throws -> String
    func cancel()
}

@MainActor @Observable final class AgentWhisperCapture: ChatWhisperRecording {
    private static var modelTransferActive = false
    @ObservationIgnored private var installation: Task<Void, Error>?
    @ObservationIgnored private var cancelDecode: (@Sendable () -> Void)?
    private var modelRevision = 0
    private var recorder: AVAudioRecorder?
    private var recordingURL: URL?
    private var revision = UUID()
    private var maxDuration: Task<Void, Never>?
    private var silenceMonitor: Task<Void, Never>?
    private(set) var starting = false
    private(set) var active = false
    private(set) var processing = false
    private(set) var installing = false
    private(set) var segments: [LocalWhisperEngine.Segment] = []
    var deletionChoice: AgentWhisper.Model?
    var installedModels: [AgentWhisper.Model] {
        _ = modelRevision
        return AgentWhisper.Model.allCases.filter(\.installed)
    }

    func install(_ model: AgentWhisper.Model = .base) async throws {
        guard !Self.modelTransferActive else { throw PhoneModelError.downloadBusy }
        Self.modelTransferActive = true
        installing = true
        let transfer = Task { try await AgentWhisper.install(model) }
        installation = transfer
        defer {
            Self.modelTransferActive = false
            installation = nil
            installing = false
            modelRevision += 1
        }
        try await withTaskCancellationHandler {
            try await transfer.value
        } onCancel: { transfer.cancel() }
    }

    func cancelInstallation() { installation?.cancel() }

    func removeModel(_ model: AgentWhisper.Model) throws {
        guard !Self.modelTransferActive, !starting, !active, !processing, !LocalCompute.isRunning else {
            throw LocalComputeError.busy
        }
        try LocalFileStore(root: AgentWhisper.folder).delete(model.file)
        modelRevision += 1
    }

    func start(language: String, silenceAfter: TimeInterval? = nil,
               whenFull: @escaping @MainActor () -> Void) async throws {
        guard !starting, !active, !processing, !AgentWhisper.availableModels(for: language).isEmpty else {
            throw APIError.storage
        }
        starting = true
        defer { starting = false }
        let id = UUID()
        revision = id
        segments = []
        let permitted = await AVAudioApplication.requestRecordPermission()
        guard revision == id, !Task.isCancelled else { throw CancellationError() }
        guard permitted else { throw APIError.input }
        let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".wav")
        MusicPlayer.shared.pause()
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
            if silenceAfter != nil { recorder?.isMeteringEnabled = true }
        } catch {
            cancel()
            try? audio.setActive(false, options: .notifyOthersOnDeactivation)
            throw error
        }
        maxDuration = Task {
            try? await Task.sleep(for: .seconds(45))
            if !Task.isCancelled, active { whenFull() }
        }
        if let silenceAfter {
            silenceMonitor = Task {
                var detector = AgentVoiceSilence(pause: silenceAfter)
                while !Task.isCancelled, active, revision == id {
                    do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
                    guard !Task.isCancelled, active, revision == id, let recorder else { return }
                    recorder.updateMeters()
                    if detector.ended(at: ProcessInfo.processInfo.systemUptime, level: recorder.averagePower(forChannel: 0)) {
                        whenFull()
                        return
                    }
                }
            }
        }
    }

    func finish(language: String) async throws -> String {
        guard active, let file = recordingURL else { throw APIError.input }
        let id = revision
        releaseMic()
        processing = true
        recordingURL = nil
        let cancellation = LocalWhisperEngine.Cancellation()
        let operation = Task { try await recognize(file, language: language, cancellation: cancellation) }
        let stop: @Sendable () -> Void = { cancellation.cancel(); operation.cancel() }
        cancelDecode = stop
        defer {
            try? FileManager.default.removeItem(at: file)
            processing = false
            cancelDecode = nil
        }
        let result = try await withTaskCancellationHandler { try await operation.value } onCancel: { stop() }
        try cancellation.checkCancellation()
        try Task.checkCancellation()
        guard revision == id else { throw CancellationError() }
        segments = result
        return result.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func recognize(_ file: URL, language: String,
                           cancellation: LocalWhisperEngine.Cancellation) async throws -> [LocalWhisperEngine.Segment] {
        try cancellation.checkCancellation()
        let models = AgentWhisper.availableModels(for: language)
        guard !models.isEmpty else { throw APIError.storage }
        for (index, model) in models.enumerated() {
            try cancellation.checkCancellation()
            let hasFallback = index + 1 < models.count
            do {
                return try await LocalCompute.run(minimumMiB: model.minimumMemoryMiB) {
                    try await withTaskCancellationHandler {
                        try await Task.detached(priority: .userInitiated) {
                            try AgentWhisper.transcribeSegments(file, language: language, model: model,
                                                               cancellation: cancellation)
                        }.value
                    } onCancel: { cancellation.cancel() }
                }
            } catch LocalComputeError.lowMemory where hasFallback {
                continue
            } catch AgentWhisper.Failure.inference where hasFallback {
                continue
            }
        }
        throw LocalComputeError.lowMemory
    }

    func cancel() {
        cancelDecode?()
        revision = UUID()
        segments = []
        releaseMic()
        if let recordingURL { try? FileManager.default.removeItem(at: recordingURL) }
        recordingURL = nil
    }

    private func releaseMic() {
        silenceMonitor?.cancel()
        silenceMonitor = nil
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

@MainActor @Observable final class ChatWhisperInput {
    enum Phase { case idle, starting, recording, transcribing }

    private struct Session {
        let id = UUID()
        let capture: any ChatWhisperRecording
        let language: String
        let receive: (Result<String, Error>) -> Void
    }

    private(set) var phase: Phase = .idle
    @ObservationIgnored private var session: Session?
    @ObservationIgnored private var transcription: Task<Void, Never>?

    static func appending(_ transcript: String, to draft: String) -> String {
        let words = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return draft }
        let separator = draft.isEmpty || draft.last?.isWhitespace == true ? "" : " "
        return draft + separator + words
    }

    func start(_ capture: any ChatWhisperRecording, language: String,
               receive: @escaping (Result<String, Error>) -> Void) async {
        guard phase == .idle else { return }
        let current = Session(capture: capture, language: language, receive: receive)
        let id = current.id
        session = current
        phase = .starting
        do {
            try await capture.start(language: language, silenceAfter: nil) { [weak self] in
                guard self?.session?.id == id else { return }
                self?.finish()
            }
            guard session?.id == current.id else { return }
            if Task.isCancelled { cancel(); return }
            phase = .recording
        } catch {
            guard session?.id == current.id else { return }
            cancel()
            if !(error is CancellationError) { receive(.failure(error)) }
        }
    }

    func finish() {
        guard phase == .recording, let current = session else { return }
        phase = .transcribing
        transcription = Task {
            guard session?.id == current.id, !Task.isCancelled else { return }
            let result: Result<String, Error>
            do { result = .success(try await current.capture.finish(language: current.language)) }
            catch { result = .failure(error) }
            guard session?.id == current.id, !Task.isCancelled else { return }
            session = nil
            transcription = nil
            phase = .idle
            current.receive(result)
        }
    }

    func cancel() {
        transcription?.cancel()
        transcription = nil
        let capture = session?.capture
        session = nil
        phase = .idle
        capture?.cancel()
    }
}
