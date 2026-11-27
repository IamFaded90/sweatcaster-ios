import Foundation
import OfflineSongRuntime
import SwiftUI

@MainActor final class PhoneSongStudio: ObservableObject {
    static let shared = PhoneSongStudio()
    static let root = URL.applicationSupportDirectory.appending(path: "FadedAI/OfflineSongs", directoryHint: .isDirectory)
    @Published private(set) var installed = PhoneSongEngine.installed(at: root)
    @Published private(set) var busy = false
    @Published private(set) var progress = ""
    @Published private(set) var downloadFraction: Double?
    @Published private(set) var downloadSize = ""
    @Published var notice: String?
    @Published private(set) var songs: [SongJob] = []
    @Published private(set) var referenceReady = false
    @Published private(set) var referenceBusy = false
    @Published private(set) var referenceProgress = ""
    @Published private(set) var deletingModel = false
    @Published private(set) var deletingReferenceModel = false
    private var operation: Task<Void, Never>?
    private var downloadID: UUID?
    private var referenceOperation: Task<Void, Never>?
    private let journal = URL.applicationSupportDirectory.appending(path: "FadedAI/Songs/local-jobs.json")
    private init() {
        PhoneSongEngine.cleanupReferenceScratch()
        if let data = try? Data(contentsOf: journal), let values = try? JSONDecoder().decode([SongJob].self, from: data) {
            songs = values
        }
        let existing = Set(songs.map(\.id))
        let recovered = SongLibrary().recoverPhoneSongs().filter { !existing.contains($0.id) }
        if !recovered.isEmpty {
            songs.insert(contentsOf: recovered, at: 0)
            try? persist()
        }
        for job in songs where !MusicLibrary.shared.saved.downloads.contains(where: { $0.id == SongLibrary.trackID(job.id) }) {
            MusicLibrary.shared.addGenerated(.init(id: SongLibrary.trackID(job.id), title: job.title,
                                                   artist: "Skabt i FadedAI", duration: job.seconds))
        }
    }
    func download() {
        guard !busy, !referenceBusy else { return }
        busy = true; notice = nil; progress = "Gør modelhentningen klar…"
        let id = UUID(); downloadID = id; downloadFraction = 0; downloadSize = ""
        operation = Task {
            defer {
                busy = false; installed = PhoneSongEngine.installed(at: Self.root)
                downloadID = nil; downloadFraction = nil; downloadSize = ""
            }
            do {
                try FileManager.default.createDirectory(at: Self.root.deletingLastPathComponent(), withIntermediateDirectories: true)
                let space = try Self.root.deletingLastPathComponent().resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                let required = PhoneSongEngine.requiredSpace(at: Self.root)
                guard (space.volumeAvailableCapacityForImportantUsage ?? 0) > required else {
                    notice = String(format: "ACE-Step skal bruge cirka %.1f GB ledig plads til de manglende filer og arbejdet.", Double(required) / 1e9); return
                }
                try await PhoneSongEngine.shared.download(to: Self.root) { value in
                    Task { @MainActor in
                        guard self.downloadID == id else { return }
                        self.progress = value.message
                        self.downloadFraction = value.fraction
                        self.downloadSize = value.byteSummary
                    }
                }
                notice = "Sangmodellen er hentet. Den første prøve skal køres på denne iPhone."
            } catch {
                if Task.isCancelled || error is CancellationError {
                    notice = "Hentningen er stoppet. Færdige modelfiler er bevaret."
                } else {
                    let detail = (error as? URLError)?.code == .timedOut
                        ? "Der kom ingen data fra modelserveren i 30 sekunder."
                        : error.localizedDescription
                    notice = "Hentningen kunne ikke afsluttes. " + detail +
                        " Tryk Hent igen for at fortsætte; færdige filer bevares."
                }
            }
        }
    }
    func cancel() {
        guard busy, !deletingModel else { return }
        operation?.cancel()
        notice = "Stopper ved næste sikre trin…"
    }
    func refreshReferenceModel() async {
        switch await PhoneSongReferenceModels.shared.status(at: Self.root) {
        case .ready: referenceReady = true
        case .notInstalled: referenceReady = false
        case .preparing: break
        }
    }
    func downloadReferenceModel() {
        guard !busy, !referenceBusy, installed else { return }
        referenceBusy = true; notice = nil; referenceProgress = "Gør lydreferencen klar…"
        referenceOperation = Task {
            defer { referenceBusy = false }
            do {
                try await PhoneSongReferenceModels.shared.prepare(at: Self.root) { value in
                    Task { @MainActor in self.referenceProgress = value }
                }
                try Task.checkCancellation()
                await refreshReferenceModel()
                try Task.checkCancellation()
                notice = "Lydreferencens modeldele er klargjort. Første prøve skal køres på denne iPhone."
            } catch {
                if Task.isCancelled || error is CancellationError {
                    notice = "Hentningen blev stoppet. Færdige dele bevares til næste forsøg."
                    // The final version may have completed just before Stop.
                    // Refresh from an independent task, not the cancelled one.
                    Task { await self.refreshReferenceModel() }
                } else {
                    notice = (error as? LocalizedError)?.errorDescription ?? "Lydreferencens modeldele kunne ikke klargøres."
                }
            }
        }
    }
    func cancelReferenceModel() {
        guard referenceBusy, !deletingReferenceModel else { return }
        referenceOperation?.cancel()
    }
    func removeReferenceModel() {
        guard !busy, !referenceBusy else { return }
        referenceBusy = true; deletingReferenceModel = true
        referenceOperation = Task {
            defer { referenceBusy = false; deletingReferenceModel = false }
            do {
                try await PhoneSongReferenceModels.shared.remove(at: Self.root)
                await refreshReferenceModel()
                notice = "Modeldelene til lydreference er fjernet. Sangmodellen er bevaret."
            } catch { notice = (error as? LocalizedError)?.errorDescription ?? "Modeldelene kunne ikke slettes." }
        }
    }
    func removeModel() {
        guard !busy, !referenceBusy else { return }
        busy = true; deletingModel = true
        operation = Task {
            defer { busy = false; deletingModel = false }
            do { try await PhoneSongEngine.shared.removeModel(at: Self.root); installed = false; referenceReady = false }
            catch { notice = "Modellen kunne ikke slettes." }
        }
    }
    func create(_ draft: SongDraft, musicReference: URL? = nil, voiceReference: URL? = nil) {
        // The PC draft stores bounded WAV bytes. iPhone references are file
        // URLs instead, so validation must reflect the selected phone files.
        var validated = draft
        validated.source = musicReference.map { _ in Data([0]) }
        validated.voice = voiceReference.map { _ in Data([0]) }
        guard !busy, !referenceBusy else { notice = "Vent, til den igangværende sang eller modelklargøring er færdig."; return }
        guard installed else { notice = "Hent først sangmodellen på iPhone."; return }
        guard validated.problem == nil else { notice = validated.problem; return }
        guard (musicReference == nil && voiceReference == nil) || referenceReady else {
            notice = "Hent først modeldelene til lydreference på iPhone."; return
        }
        busy = true; notice = nil; progress = "Gør klar på iPhone…"
        operation = Task {
            defer { busy = false }
            do {
                MusicPlayer.shared.pause()
                await AgentVoiceDownload.releaseSynthesisResources()
                try Task.checkCancellation()
                let style = draft.enhancePrompt ? SongPrompt.expanded(draft.prompt, instrumental: draft.instrumental) : draft.prompt
                let input = PhoneSongInput(id: draft.id, style: style, lyrics: draft.lyrics,
                    seconds: draft.seconds, instrumental: draft.instrumental,
                    enhancePrompt: draft.enhancePrompt, language: draft.language,
                    referenceAudio: draft.mode == .remix ? voiceReference : (voiceReference ?? musicReference),
                    remixAudio: draft.mode == .remix ? musicReference : nil)
                let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("song-" + draft.id.uuidString + ".wav")
                defer { try? FileManager.default.removeItem(at: scratch) }
                let duration = try await LocalCompute.run(minimumMiB: 3_800) {
                    try await PhoneSongEngine.shared.generate(input, models: Self.root, output: scratch) { value in
                        Task { @MainActor in self.progress = value }
                    }
                }
                try Task.checkCancellation()
                let job = SongJob(id: draft.id, title: draft.title, prompt: style, lyrics: draft.lyrics, favorite: draft.favorite,
                    mode: draft.mode, seconds: duration, instrumental: draft.instrumental, state: "completed",
                    notice: "Lavet på denne iPhone · \(Int(duration)) sek.", created: Date.now.timeIntervalSince1970)
                var track = try SongLibrary().saveFile(scratch, job: job)
                track.artwork = try? SongCover.save(title: job.title, id: job.id)
                MusicLibrary.shared.addGenerated(track)
                songs.removeAll { $0.id == job.id }; songs.insert(job, at: 0)
                do {
                    try persist()
                    notice = job.notice
                } catch {
                    notice = "Sangen er gemt, men sanglisten kunne ikke gemmes. Prøv igen senere."
                }
                progress = ""
            } catch is CancellationError { notice = "Forsøget blev stoppet. Dine færdige sange er bevaret." }
            catch { notice = (error as? LocalizedError)?.errorDescription ?? AppErrorPresentation(error).title }
        }
    }
    func remove(_ job: SongJob) {
        guard !busy else { return }
        MusicLibrary.shared.deleteDownload(.init(id: SongLibrary.trackID(job.id), title: job.title, artist: "Skabt i FadedAI"))
        guard !SongLibrary().containsStoredFiles(job.id) else {
            notice = "Sangen kunne ikke slettes. Prøv igen."
            return
        }
        songs.removeAll { $0.id == job.id }
        do { try persist() } catch { notice = "Sanglisten kunne ikke gemmes." }
    }
    private func persist() throws {
        try FileManager.default.createDirectory(at: journal.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(songs).write(to: journal, options: [.atomic, .completeFileProtection])
    }
    static func changePhase(_ phase: ScenePhase) {
        if phase == .active { PhoneSongEngine.resume() }
        else { PhoneSongEngine.suspend(); shared.cancel() }
    }
}
