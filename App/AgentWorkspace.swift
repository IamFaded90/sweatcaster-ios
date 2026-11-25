import Foundation

/// One atomic journal per agent. User text never becomes a filesystem path.
struct AgentWorkspace {
    struct File: Codable, Identifiable, Equatable {
        let id: UUID
        var name: String
        var text: String
        var updated: Date
        var previous: [String] = []
    }
    enum Kind: String, Codable, CaseIterable { case document, research, computer, shortcut, localCode }
    struct CodeFile: Codable, Equatable, Identifiable {
        let id: UUID
        let name: String
        let text: String
    }
    enum State: String, Codable {
        case queued, running, paused, waitingForPC, checking, completed, failed, cancelled
        var title: String {
            switch self {
            case .queued: "Klar til at starte"
            case .running: "Arbejder"
            case .paused: "Kan fortsættes"
            case .waitingForPC: "Venter på PC"
            case .checking: "Afventer bekræftelse"
            case .completed: "Færdig"
            case .failed: "Kræver et nyt forsøg"
            case .cancelled: "Stoppet"
            }
        }
    }
    struct Job: Codable, Identifiable, Equatable {
        let id: UUID
        let kind: Kind
        let prompt: String
        let created: Date
        var state: State = .queued
        var result: String = ""
        var fileID: UUID?
        var inputFileID: UUID?
        var pcID: String?
        var remoteID: UUID?
        var submitted = false
        var callbackToken: UUID?
        var shortcutName: String?
        var shortcutInput: String?
        var localCode: String?
        var runsLinux: Bool?
        var localFiles: [CodeFile]?
        var localInput: String?
        var inputSnapshot: String?
        var review: AgentWorkReview.Report?
    }
    struct Shortcut: Codable, Identifiable, Equatable {
        let id: UUID
        var name: String
        var purpose: String
    }
    struct Snapshot: Codable, Equatable {
        var files: [File] = []
        var jobs: [Job] = []
        var shortcuts: [Shortcut] = []
    }
    enum Failure: LocalizedError {
        case full, invalid, missing
        var errorDescription: String? {
            switch self {
            case .full: "Arbejdsrummet er fyldt. Slet nogle gamle filer eller opgaver først."
            case .invalid: "Oplysningerne kunne ikke gemmes. Forkort teksten, og prøv igen."
            case .missing: "Filen eller opgaven findes ikke længere."
            }
        }
    }
    static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AgentWorkspaces", isDirectory: true)
    }
    let botID: UUID
    var root: URL = Self.root
    private var url: URL { root.appendingPathComponent(botID.uuidString.lowercased() + ".json") }

    func load() throws -> Snapshot {
        guard FileManager.default.fileExists(atPath: url.path) else { return Snapshot() }
        let bytes = try Data(contentsOf: url)
        guard bytes.count <= 12_000_000 else { throw Failure.invalid }
        return try JSONDecoder().decode(Snapshot.self, from: bytes)
    }

    @discardableResult func edit(_ change: (inout Snapshot) throws -> Void) throws -> Snapshot {
        var snapshot = try load()
        let previous = snapshot
        try change(&snapshot)
        guard snapshot != previous else { return snapshot }
        guard snapshot.files.count <= 50, snapshot.jobs.count <= 100, snapshot.shortcuts.count <= 30 else { throw Failure.full }
        guard snapshot.files.allSatisfy({ !$0.name.isEmpty && $0.name.count <= 160 && $0.text.count <= 80_000 }) else { throw Failure.invalid }
        let bytes = try JSONEncoder().encode(snapshot)
        guard bytes.count <= 12_000_000 else { throw Failure.full }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try bytes.write(to: url, options: .atomic)
        return snapshot
    }

    func addFile(name: String, text: String, id: UUID = UUID()) throws -> File {
        let file = File(id: id, name: String(name.prefix(160)), text: text, updated: .now)
        try edit { $0.files.append(file) }
        return file
    }

    func revise(_ id: UUID, text: String) throws {
        try edit { snapshot in
            guard let i = snapshot.files.firstIndex(where: { $0.id == id }) else { throw Failure.missing }
            guard snapshot.files[i].text != text else { return }
            snapshot.files[i].previous = Array((snapshot.files[i].previous + [snapshot.files[i].text]).suffix(3))
            snapshot.files[i].text = text
            snapshot.files[i].updated = .now
        }
    }

    func enqueue(_ prompt: String, kind: Kind, pcID: String? = nil,
                 shortcut: Shortcut? = nil, input: String = "", inputFileID: UUID? = nil) throws -> Job {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, prompt.count <= 1_200,
              input.count <= 4_000 else { throw Failure.invalid }
        var job = Job(id: UUID(), kind: kind, prompt: prompt, created: .now)
        if let inputFileID, try !load().files.contains(where: { $0.id == inputFileID }) { throw Failure.missing }
        job.inputFileID = inputFileID
        job.pcID = pcID
        job.shortcutName = shortcut?.name
        job.shortcutInput = input
        if kind == .shortcut { job.callbackToken = UUID() }
        try edit { $0.jobs.append(job) }
        return job
    }

    func update(_ id: UUID, _ change: (inout Job) throws -> Void) throws {
        try edit { snapshot in
            guard let i = snapshot.jobs.firstIndex(where: { $0.id == id }) else { throw Failure.missing }
            try change(&snapshot.jobs[i])
        }
    }

    /// Persist the complete input before execution so a stopped job can be reopened offline.
    func beginCode(resuming id: UUID?, name: String, code: String, input: String,
                   linux: Bool, files: [CodeFile]) throws -> UUID {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 100,
              !code.isEmpty, code.utf8.count <= 8_000, files.count <= 5,
              Set(files.map(\.id)).count == files.count, files.isEmpty || linux,
              files.reduce(input.utf8.count, { $0 + $1.text.utf8.count }) <= 160_000 else { throw Failure.invalid }
        var result = UUID()
        try edit { snapshot in
            var job = Job(id: result, kind: .localCode, prompt: "Lokal kode: " + name, created: .now)
            if let id, let index = snapshot.jobs.firstIndex(where: { $0.id == id }) {
                let old = snapshot.jobs[index]
                guard old.kind == .localCode, (old.runsLinux == true) == linux, old.state != .running else { throw Failure.invalid }
                if old.state != .completed && old.state != .cancelled {
                    job = Job(id: id, kind: .localCode, prompt: job.prompt, created: old.created)
                    snapshot.jobs.remove(at: index)
                }
            }
            job.state = .running; job.localCode = code; job.localInput = input; job.runsLinux = linux
            job.localFiles = files.isEmpty ? nil : files
            snapshot.jobs.append(job); result = job.id
        }
        return result
    }

    /// Output and completion commit together; a repeated receipt cannot create a second file.
    @discardableResult func complete(_ id: UUID, text: String, name: String) throws -> File? {
        let snapshot = try edit { snapshot in
            guard let i = snapshot.jobs.firstIndex(where: { $0.id == id }) else { throw Failure.missing }
            guard snapshot.jobs[i].state != .completed, snapshot.jobs[i].state != .cancelled else { return }
            let file = File(id: id, name: String(name.prefix(160)), text: text, updated: .now)
            snapshot.files.removeAll { $0.id == id }
            snapshot.files.append(file)
            snapshot.jobs[i].state = .completed
            snapshot.jobs[i].fileID = id
            snapshot.jobs[i].result = "Resultatet er gemt i arbejdsrummet."
            snapshot.jobs[i].review = nil
        }
        guard let finished = snapshot.jobs.first(where: { $0.id == id && $0.state == .completed }),
              let fileID = finished.fileID else { return nil }
        return snapshot.files.first { $0.id == fileID }
    }

    func recover() throws {
        try edit { snapshot in
            for i in snapshot.jobs.indices where snapshot.jobs[i].state == .running {
                snapshot.jobs[i].state = snapshot.jobs[i].submitted ? .checking : .paused
            }
        }
    }

    /// Rotate through the stored order so one pending PC receipt cannot starve
    /// the remaining jobs. The cursor is transient; it never changes the journal.
    static func nextComputerJob(_ jobs: [Job], after cursor: UUID?, connectedPC: String?) -> Job? {
        guard !jobs.isEmpty else { return nil }
        let start = cursor.flatMap { id in jobs.firstIndex { $0.id == id } }.map { ($0 + 1) % jobs.count } ?? 0
        for offset in 0..<jobs.count {
            let job = jobs[(start + offset) % jobs.count]
            guard job.kind == .computer, job.state == .waitingForPC || job.state == .checking else { continue }
            if let connectedPC, let target = job.pcID, target != connectedPC { continue }
            return job
        }
        return nil
    }

    static func excerpt(_ text: String, maximumBytes: Int) -> String {
        var bytes = Data(text.utf8.prefix(max(0, maximumBytes)))
        while !bytes.isEmpty {
            if let value = String(data: bytes, encoding: .utf8) { return value }
            bytes.removeLast()
        }
        return ""
    }

    static func command(_ text: String) -> (kind: Kind?, input: String)? {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if ["åbn arbejdsrum", "åbn dit arbejdsrum", "vis dine filer", "vis dine opgaver", "vis dine genveje"].contains(clean.lowercased()) {
            return (nil, "")
        }
        for (prefix, kind) in [("lav et dokument: ", Kind.document), ("undersøg og gem: ", .research), ("arbejd på pc: ", .computer), ("kør genvej: ", .shortcut)] {
            if clean.lowercased().hasPrefix(prefix), clean.count > prefix.count {
                return (kind, String(clean.dropFirst(prefix.count)))
            }
        }
        return nil
    }
}
