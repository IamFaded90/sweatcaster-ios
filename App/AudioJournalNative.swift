import AVFAudio
import FadedAISpeakerRuntime
import FadedAIWhisperRuntime
import Foundation
import Observation

enum AudioJournalNative {
    static var root: URL { .applicationSupportDirectory.appending(path: "FadedAI/AudioTranscripts", directoryHint: .isDirectory) }
    static func audio(_ id: UUID) -> URL { root.appending(path: id.uuidString.lowercased() + ".wav") }
    static func validateConverted(_ id: UUID) throws {
        let reader = try AVAudioFile(forReading: audio(id))
        guard reader.processingFormat.sampleRate == 16_000, reader.processingFormat.channelCount == 1 else { throw AudioTranscript.Failure.invalid }
        _ = try AudioTranscript.chunks(duration: Double(reader.length) / 16_000)
    }
    /// Stream conversion to disk; a 30-minute import is never a 30-minute in-memory buffer.
    static func importFile(_ source: URL, id: UUID) async throws {
        let work = Task.detached(priority: .userInitiated) {
            let scoped = source.startAccessingSecurityScopedResource(); defer { if scoped { source.stopAccessingSecurityScopedResource() } }
            guard try LocalFileStore.checkedFileSize(source, maximumBytes: 250_000_000) > 0 else { throw AudioTranscript.Failure.invalid }
            let reader = try AVAudioFile(forReading: source), inputFormat = reader.processingFormat
            guard inputFormat.sampleRate.isFinite, inputFormat.sampleRate > 0 else { throw AudioTranscript.Failure.invalid }
            _ = try AudioTranscript.chunks(duration: Double(reader.length) / inputFormat.sampleRate)
            guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
                  let converter = AVAudioConverter(from: inputFormat, to: target),
                  let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: 16_384),
                  let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 4_096) else { throw AudioTranscript.Failure.invalid }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let file = audio(id), staged = root.appending(path: id.uuidString.lowercased() + ".partial.wav")
            defer { try? FileManager.default.removeItem(at: staged) }
            var writer: AVAudioFile? = try AVAudioFile(forWriting: staged, settings: target.settings)
            var readError: Error?
            while true {
                try Task.checkCancellation(); var conversionError: NSError?
                let status = converter.convert(to: output, error: &conversionError) { _, state in
                    do {
                        try Task.checkCancellation()
                        let available = min(Int64(input.frameCapacity), reader.length - reader.framePosition)
                        guard available > 0 else { state.pointee = .endOfStream; return nil }
                        try reader.read(into: input, frameCount: AVAudioFrameCount(available))
                        guard input.frameLength > 0 else { state.pointee = .endOfStream; return nil }
                        state.pointee = .haveData; return input
                    } catch { readError = error; state.pointee = .endOfStream; return nil }
                }
                if let readError { throw readError }; if let conversionError { throw conversionError }
                if output.frameLength > 0 { try writer?.write(from: output) }
                if status == .endOfStream { break }; if status == .error { throw AudioTranscript.Failure.invalid }
            }
            writer = nil; try Task.checkCancellation()
            guard !FileManager.default.fileExists(atPath: file.path) else { throw AudioTranscript.Failure.invalid }
            try FileManager.default.moveItem(at: staged, to: file)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: file.path)
        }
        try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }
    @MainActor static func transcribe(_ initial: AudioTranscript.Recording, progress: (AudioTranscript.Recording) throws -> Void) async throws -> AudioTranscript.Recording {
        guard let model = AgentWhisper.availableModels(for: "da-DK").first else { throw PhoneModelError.unavailable }
        await AgentVoiceDownload.releaseSynthesisResources()
        var recording = initial
        let file = try AVAudioFile(forReading: audio(initial.id)), duration = Double(file.length) / 16_000
        guard file.processingFormat.sampleRate == 16_000 else { throw AudioTranscript.Failure.invalid }
        let chunks = try AudioTranscript.chunks(duration: duration)
        for range in chunks where range.lowerBound >= (recording.processedThrough ?? 0) - 0.01 {
            try Task.checkCancellation()
            let cancel = LocalWhisperEngine.Cancellation()
            let segments = try await LocalCompute.run(minimumMiB: model.minimumMemoryMiB) {
                try await withTaskCancellationHandler {
                    try await Task.detached(priority: .userInitiated) { () -> [AudioTranscript.Segment] in
                        try cancel.checkCancellation()
                        let reader = try AVAudioFile(forReading: audio(initial.id)); reader.framePosition = Int64(range.lowerBound * 16_000)
                        let frames = AVAudioFrameCount((range.upperBound - range.lowerBound) * 16_000)
                        guard let buffer = AVAudioPCMBuffer(pcmFormat: reader.processingFormat, frameCapacity: frames) else { throw AudioTranscript.Failure.invalid }
                        try reader.read(into: buffer, frameCount: frames)
                        guard let values = buffer.floatChannelData?[0] else { throw AudioTranscript.Failure.invalid }
                        guard AgentWhisper.hasMicrophoneSignal(UnsafeBufferPointer(start: values, count: Int(buffer.frameLength))) else { return [] }
                        let response = withExtendedLifetime(buffer) {
                            LocalWhisperEngine.transcribeSegments(modelPath: model.file.path, samples: values, count: Int32(buffer.frameLength), language: "da", timestamped: model != .danish, cancellation: cancel)
                        }
                        try cancel.checkCancellation()
                        guard let response else { throw AgentWhisper.Failure.inference }
                        if model == .danish {
                            let text = response.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
                            return text.isEmpty ? [] : [.init(start: range.lowerBound, end: range.upperBound, text: text)]
                        }
                        return response.compactMap { span in
                            let text = span.text.trimmingCharacters(in: .whitespacesAndNewlines); guard !text.isEmpty else { return nil }
                            // The Danish text-only model has chunk-level rather than word-aligned timing.
                            let start = range.lowerBound + span.started
                            let end = min(range.upperBound, range.lowerBound + span.ended)
                            return .init(start: start, end: max(start, end), text: text)
                        }
                    }.value
                } onCancel: { cancel.cancel() }
            }
            try Task.checkCancellation(); recording.segments += segments; recording.processedThrough = range.upperBound
            try progress(recording)
        }
        recording.complete = true; try progress(recording); return recording
    }
    @MainActor static func speakers(_ recording: AudioTranscript.Recording) async throws -> AudioTranscript.Recording {
        await AgentVoiceDownload.releaseSynthesisResources()
        let spans = try await LocalCompute.run(minimumMiB: 1_200) { try await SpeakerRuntime.shared.separate(audio(recording.id), progress: { _ in }) }
        var copy = recording
        copy.segments = AudioTranscript.label(recording.segments, with: spans.map { .init(speaker: $0.speaker, start: $0.start, end: $0.end) })
        return copy
    }
}

@MainActor @Observable final class LongAudioRecorder {
    private var recorder: AVAudioRecorder?
    private var revision = UUID()
    private(set) var active = false
    var isRecording: Bool { recorder?.isRecording == true }
    private var file: URL?
    func start(to url: URL) async throws {
        let token = UUID(); revision = token
        let allowed = await AVAudioApplication.requestRecordPermission()
        guard revision == token, !Task.isCancelled else { throw CancellationError() }
        guard allowed else { throw CocoaError(.fileReadNoPermission) }
        let session = AVAudioSession.sharedInstance(); MusicPlayer.shared.pause()
        try session.setCategory(.record, mode: .measurement); try session.setActive(true)
        file = url
        do {
            recorder = try AVAudioRecorder(url: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16])
            guard recorder?.record(forDuration: 1_800) == true else { throw AudioTranscript.Failure.invalid }; active = true
        } catch { _ = finish(); throw error }
    }
    func finish() -> URL? {
        revision = UUID(); recorder?.stop(); recorder = nil; active = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        defer { file = nil }; return file
    }
}
