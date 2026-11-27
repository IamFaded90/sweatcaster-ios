import Foundation

enum SongMode: String, CaseIterable, Codable, Identifiable {
    case new, inspiration, remix
    var id: Self { self }
    var title: String { switch self { case .new: "Ny sang"; case .inspiration: "Inspiration"; case .remix: "Remix" } }
}

struct SongDraft: Codable, Equatable {
    var id = UUID()
    var title = "Min nye sang"
    var prompt = ""
    var lyrics = ""
    var favorite = ""
    var mode = SongMode.new
    var seconds = 30.0
    var instrumental = false
    var language = "da"
    var enhancePrompt = true
    var source: Data?
    var voice: Data?

    static func request(_ text: String) -> SongDraft? {
        let pattern = #"^(?:(?:kan|vil) du (?:lige )?)?(?:lav|skab|skriv) (?:en |et |min |mit |ny |nyt )*(sang|nummer|remix)(?:[ ,:]+(.*))?$"#
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: clean, range: NSRange(clean.startIndex..., in: clean)),
              let kind = Range(match.range(at: 1), in: clean) else { return nil }
        var result = SongDraft()
        result.title = "Min nye sang"
        if clean[kind].lowercased() == "remix" { result.mode = .remix }
        if let range = Range(match.range(at: 2), in: clean) { result.prompt = String(clean[range].prefix(1_500)) }
        return result
    }

    var problem: String? {
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || title.count > 100 { return "Giv sangen en kort titel." }
        if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || prompt.count > 1_500 { return "Beskriv musikken med højst 1.500 tegn." }
        if lyrics.count > 6_000 || favorite.count > 220 { return "Forkort sangteksten eller referencens navn." }
        if !["da", "en"].contains(language) { return "Vælg dansk eller engelsk til sangteksten." }
        if !seconds.isFinite || !(10...180).contains(seconds) { return "Vælg en længde mellem 10 og 180 sekunder." }
        if mode == .remix && source == nil { return "Vælg selve lydfilen til remix. Favorittens navn er ikke nok." }
        if let source, source.isEmpty || source.count > 12_000_000 { return "Vælg en kortere musikreference." }
        if let voice, voice.isEmpty || voice.count > 12_000_000 { return "Vælg en kortere optagelse af din stemme." }
        if voice != nil && instrumental { return "Slå instrumental fra for at prøve din stemme." }
        if voice != nil && mode == .inspiration && source != nil {
            return "Til en stemmeprøve: brug favoritnavnet og din stilbeskrivelse, eller vælg Remix med en lydfil."
        }
        return nil
    }
}

struct SongJob: Codable, Identifiable, Equatable {
    let id: UUID
    let title: String
    let prompt: String
    let lyrics: String
    let favorite: String
    let mode: SongMode
    let seconds: Double
    let instrumental: Bool
    let state: String
    let notice: String
    let created: Double
    var progress: SongJobProgress? = nil
    var finished: Bool { ["completed", "failed", "removed"].contains(state) }
}

struct SongJobProgress: Codable, Equatable {
    let stage: String
    let updated: Double
    let lastChecked: Double?
}

extension SongJob {
    var progressStep: Int {
        if state == "completed" { return 4 }
        switch progress?.stage ?? state {
        case "preparing", "submitting": return 1
        case "rendering": return 2
        case "saving": return 3
        default: return 0
        }
    }
    var progressTitle: String {
        if state == "failed" { return "Sangen kunne ikke laves" }
        return ["I kø på PC’en", "Klargør musikmotoren", "Skaber din sang", "Gør lyden klar", "Sangen er klar"][progressStep]
    }
}

struct SongStudioCatalog: Decodable {
    let ready: Bool
    let voiceReference: Bool
    let jobs: [SongJob]
    var hasActiveJobs: Bool { jobs.contains { !$0.finished } }
}

struct SongLibrary {
    var root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("FadedAI/Songs", isDirectory: true)
    static func trackID(_ id: UUID) -> String { "faded-song-" + id.uuidString.lowercased() }
    func localURL(_ id: String) -> URL? {
        guard id.hasPrefix("faded-song-"), let key = UUID(uuidString: String(id.dropFirst(11))) else { return nil }
        let file = root.appendingPathComponent(key.uuidString.lowercased() + ".wav")
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }
    func save(_ audio: Data, job: SongJob) throws -> MusicTrack {
        guard job.state == "completed", audio.count > 44, audio.count <= 70_000_000,
              audio.prefix(4) == Data("RIFF".utf8), audio[8..<12] == Data("WAVE".utf8) else { throw CocoaError(.fileReadCorruptFile) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent(job.id.uuidString.lowercased() + ".wav")
        try audio.write(to: file, options: [.atomic, .completeFileProtection])
        try JSONEncoder().encode(job).write(to: file.deletingPathExtension().appendingPathExtension("json"), options: .atomic)
        return .init(id: Self.trackID(job.id), title: job.title, artist: "Skabt i FadedAI", duration: job.seconds)
    }
    /// Keep large on-device results on disk instead of making another complete RAM copy.
    func saveFile(_ source: URL, job: SongJob) throws -> MusicTrack {
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard job.state == "completed", values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, (45...70_000_000).contains(size) else { throw CocoaError(.fileReadCorruptFile) }
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let header = try input.read(upToCount: 12) ?? Data()
        guard header.count == 12, header.prefix(4) == Data("RIFF".utf8), header[8..<12] == Data("WAVE".utf8) else { throw CocoaError(.fileReadCorruptFile) }
        let manager = FileManager.default
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        let target = root.appendingPathComponent(job.id.uuidString.lowercased() + ".wav")
        let metadata = target.deletingPathExtension().appendingPathExtension("json")
        let staged = root.appendingPathComponent(".song-" + UUID().uuidString + ".wav")
        defer { try? manager.removeItem(at: staged) }
        guard !manager.fileExists(atPath: target.path), !manager.fileExists(atPath: metadata.path) else { throw CocoaError(.fileWriteFileExists) }
        try manager.copyItem(at: source, to: staged)
        guard try staged.resourceValues(forKeys: [.fileSizeKey]).fileSize == size else { throw CocoaError(.fileReadCorruptFile) }
        #if canImport(UIKit)
        try manager.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: staged.path)
        #endif
        try manager.moveItem(at: staged, to: target)
        do { try JSONEncoder().encode(job).write(to: metadata, options: [.atomic, .completeFileProtection]) }
        catch { try? manager.removeItem(at: target); throw error }
        return .init(id: Self.trackID(job.id), title: job.title, artist: "Skabt i FadedAI", duration: job.seconds)
    }
    /// Restore local results after an interrupted update of the song list.
    func recoverPhoneSongs() -> [SongJob] {
        let manager = FileManager.default
        guard let files = try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else { return [] }
        return files.compactMap { file in
            guard file.pathExtension == "json", let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent),
                  let attributes = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  attributes.isRegularFile == true, let size = attributes.fileSize, (1...100_000).contains(size),
                  let data = try? Data(contentsOf: file), let job = try? JSONDecoder().decode(SongJob.self, from: data),
                  job.id == id, job.state == "completed", job.notice.hasPrefix("Lavet på denne iPhone"),
                  localURL(Self.trackID(id)) != nil else { return nil }
            return job
        }.sorted { $0.created > $1.created }
    }
    func containsStoredFiles(_ id: UUID) -> Bool {
        ["wav", "json", "png"].contains { ext in
            FileManager.default.fileExists(atPath: root.appendingPathComponent(id.uuidString.lowercased() + "." + ext).path)
        }
    }
    func remove(_ id: UUID) throws {
        for ext in ["wav", "json", "png"] {
            let file = root.appendingPathComponent(id.uuidString.lowercased() + "." + ext)
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        }
    }
}
