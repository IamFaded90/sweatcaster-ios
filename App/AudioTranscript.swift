import Foundation

enum AudioTranscript {
    static func command(_ text: String) -> Bool { ["åbn mine optagelser", "vis mine optagelser", "transskriber lydfil", "optag en samtale"].contains(text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)) }
    struct Segment: Codable, Identifiable, Equatable, Sendable {
        var id = UUID()
        let start: Double
        let end: Double
        var text: String
        var speaker: String?
        var speakerEstimated = false
    }
    struct SpeakerSpan: Sendable { let speaker: String; let start: Double; let end: Double }
    struct Recording: Codable, Identifiable, Sendable {
        var id = UUID()
        var title: String
        var created = Date()
        var segments: [Segment] = []
        var complete = false
        var processedThrough: Double? = nil
        var exportedText: String { segments.map { "[\(AudioTranscript.clock($0.start))–\(AudioTranscript.clock($0.end))] \($0.speaker.map { $0 + ": " } ?? "")\($0.text)" }.joined(separator: "\n") }
    }
    enum Failure: LocalizedError {
        case invalid, length
        var errorDescription: String? { self == .length ? "Vælg en lydfil på højst 30 minutter og 250 MB." : "Optagelsen eller tidskoderne kunne ikke læses." }
    }
    static func clock(_ time: Double) -> String {
        let seconds = time.isFinite ? Int(min(86_400, max(0, time))) : 0
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
    static func chunks(duration: Double, seconds: Double = 25) throws -> [Range<Double>] {
        guard duration.isFinite, duration > 0, seconds.isFinite, seconds >= 5 else { throw Failure.invalid }
        guard duration <= 1_800 else { throw Failure.length }
        return stride(from: 0.0, to: duration, by: seconds).map { $0..<min(duration, $0 + seconds) }
    }
    /// Never assign a whole text passage to one speaker when two voices share that time range.
    static func label(_ segments: [Segment], with spans: [SpeakerSpan]) -> [Segment] {
        let valid = spans.filter { !$0.speaker.isEmpty && $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end > $0.start }
        var names: [String: String] = [:]
        for span in valid.sorted(by: { $0.start < $1.start }) where names[span.speaker] == nil { names[span.speaker] = "Taler \(names.count + 1)" }
        return segments.map { segment in
            var value = segment
            let speakers = Set(valid.filter { min($0.end, segment.end) - max($0.start, segment.start) > 0.15 }.map(\.speaker))
            value.speaker = speakers.count > 1 ? "Flere talere" : speakers.first.flatMap { names[$0] }
            value.speakerEstimated = value.speaker != nil; return value
        }
    }
    struct Store {
        let botID: UUID
        var root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("FadedAI/AudioTranscripts", isDirectory: true)
        private var file: URL { root.appendingPathComponent(botID.uuidString.lowercased() + ".json") }
        func load() throws -> [Recording] {
            guard FileManager.default.fileExists(atPath: file.path) else { return [] }
            guard (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 6_000_000 else { throw Failure.length }
            return try JSONDecoder().decode([Recording].self, from: Data(contentsOf: file))
        }
        func save(_ recording: Recording) throws {
            guard recording.title.count <= 160, recording.segments.count <= 3_000,
                  recording.segments.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end >= $0.start && $0.end <= 1_800 && $0.text.count <= 6_000 }) else { throw Failure.invalid }
            var list = try load(); list.removeAll { $0.id == recording.id }; guard list.count < 24 else { throw Failure.length }
            list.insert(recording, at: 0); try write(list)
        }
        func remove(_ id: UUID) throws { try write(load().filter { $0.id != id }) }
        private func write(_ list: [Recording]) throws {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(list); guard data.count <= 6_000_000 else { throw Failure.length }
            try data.write(to: file, options: [.atomic, .completeFileProtection])
        }
    }

    /// Own microphone recordings awaiting conversion. Never enumerate or
    /// remove other agents' folders or the existing saved-recording library.
    struct Recovery {
        let botID: UUID
        var root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FadedAI/AudioTranscripts/Pending", isDirectory: true)
        private var folder: URL { root.appendingPathComponent(botID.uuidString.lowercased(), isDirectory: true) }
        func audio(_ id: UUID) -> URL { folder.appendingPathComponent(id.uuidString.lowercased() + ".wav") }
        private func manifest(_ id: UUID) -> URL { folder.appendingPathComponent(id.uuidString.lowercased() + ".json") }
        private func checked(_ url: URL) throws {
            let expectedFolder = root.resolvingSymlinksInPath().appendingPathComponent(botID.uuidString.lowercased(), isDirectory: true).standardizedFileURL
            guard url.deletingLastPathComponent().standardizedFileURL.path == folder.standardizedFileURL.path,
                  folder.resolvingSymlinksInPath().standardizedFileURL.path == expectedFolder.path,
                  url.resolvingSymlinksInPath().deletingLastPathComponent().path == folder.resolvingSymlinksInPath().standardizedFileURL.path else { throw Failure.invalid }
        }
        func begin(_ recording: Recording) throws {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let info = manifest(recording.id), sound = audio(recording.id)
            try checked(info); try checked(sound)
            guard !FileManager.default.fileExists(atPath: info.path), !FileManager.default.fileExists(atPath: sound.path) else { throw Failure.invalid }
            try JSONEncoder().encode(recording).write(to: info, options: .atomic)
        }
        /// Keep a completed conversion available for journal recovery when an
        /// import fails after writing the final file. Never remove the source.
        func preserveConverted(_ recording: Recording, from source: URL) throws {
            try begin(recording)
            let destination = audio(recording.id); try checked(destination)
            try FileManager.default.copyItem(at: source, to: destination)
        }
        func list() throws -> [Recording] {
            guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
            return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).compactMap { url in
                guard url.pathExtension.lowercased() == "wav", let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                      url.lastPathComponent == id.uuidString.lowercased() + ".wav" else { return nil }
                try checked(url)
                let info = manifest(id); try checked(info)
                if let data = try? Data(contentsOf: info), data.count <= 64_000,
                   let saved = try? JSONDecoder().decode(Recording.self, from: data), saved.id == id { return saved }
                // A missing or damaged sidecar never hides the user's audio.
                return Recording(id: id, title: "Gendannet optagelse")
            }.sorted { $0.created > $1.created }
        }
        func remove(_ id: UUID) throws {
            for url in [audio(id), manifest(id)] {
                try checked(url)
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            }
        }
        /// Validate the final file and confirm the journal before deleting raw
        /// audio. A retry never overwrites a previously committed transcript.
        func commit(_ recording: Recording, to store: Store, validate: () throws -> Void) throws -> Recording {
            guard store.botID == botID else { throw Failure.invalid }
            try validate()
            if try !store.load().contains(where: { $0.id == recording.id }) { try store.save(recording) }
            guard let saved = try store.load().first(where: { $0.id == recording.id }) else { throw Failure.invalid }
            // Once the saved file and journal are confirmed, failed cleanup is
            // not a failed save; any remaining raw file can be deleted later.
            try? remove(recording.id)
            return saved
        }
    }
}
