// Owns video selection, persistence, submission, and job status.
import Foundation

struct SavedVideoClip: Codable, Sendable {
    let clip: Clip
    let folderID: String?
}

struct VideoStudioState: Codable {
    var folderID: String?
    var mood: Mood?
    var clips: [SavedVideoClip] = []
    var outbox: [VideoOutboxItem] = []
}

extension Model {
    var hasActive: Bool { jobs.contains { $0.status.active } }
    var blocked: Bool {
        let missing = capabilities?.missingRequired ?? []
        return missing.contains { options.commentary != false || $0.name == "ffmpeg" || $0.name == "ffprobe" }
    }
    var canSubmit: Bool {
        connected && !busy && !refreshing && !checkingVideoOutbox && !requiresVideoReview && !blocked && !selected.isEmpty && options.roi.valid &&
            selected.count <= (capabilities?.limit ?? 0)
    }

    var lastVideoFolder: String? { videoStudio.folderID }
    var lastVideoMood: Mood? { videoStudio.mood }
    private var videoStateFile: URL? {
        guard !isDemo, let server = try? Server(address) else { return nil }
        return videoStateDirectory.appending(path: server.address + ".json", directoryHint: .notDirectory)
    }

    var savedVideoClips: [SavedVideoClip] {
        clips.filter { selected.contains($0.id) }.map { SavedVideoClip(clip: $0, folderID: clipFolderIDs[$0.id]) }
    }

    func restoreVideoStudio() {
        videoStudio = VideoStudioState()
        clipFolderIDs = [:]
        videoStateReadable = true
        videoStorageNotice = nil
        videoOutboxNotice = nil
        guard let file = videoStateFile else { return }
        do {
            let store = LocalFileStore(root: videoStateDirectory, maximumBytes: 512_000)
            videoStudio = try store.read(VideoStudioState.self, from: file)
            var seen = Set<String>()
            let draft = videoStudio.clips.filter { validWireID($0.clip.id) && seen.insert($0.clip.id).inserted }.prefix(10)
            clips = draft.map(\.clip)
            selected = Set(clips.map(\.id))
            for clip in draft { clipFolderIDs[clip.clip.id] = clip.folderID }
            uncertain = uncertain || videoStudio.outbox.contains { $0.state == .attempted }
        } catch let error as CocoaError where [.fileNoSuchFile, .fileReadNoSuchFile].contains(error.code) {
            return
        } catch {
            AppDiagnostics.record(error)
            videoStateReadable = false
            videoStorageNotice = "Den lokale videokladde kunne ikke læses. Gemte køjobs sendes ikke."
        }
    }

    @discardableResult func saveVideoStudio(_ updated: VideoStudioState) -> Bool {
        guard let file = videoStateFile, videoStateReadable else { return false }
        do {
            let data = try JSONEncoder().encode(updated)
            guard data.count <= 512_000 else { throw APIError.storage }
            let resolved = try LocalFileStore.safeWriteURL(file, within: videoStateDirectory)
            try LocalFileStore.writeBytes(data, to: file, within: videoStateDirectory)
            var folder = resolved.deletingLastPathComponent()
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? folder.setResourceValues(values)
            videoStudio = updated
            videoStorageNotice = nil
            return true
        } catch {
            AppDiagnostics.record(error)
            videoStorageNotice = "Videokladden kunne ikke gemmes på telefonen."
            return false
        }
    }

    private func saveVideoSelection() {
        var updated = videoStudio
        updated.clips = savedVideoClips
        saveVideoStudio(updated)
    }

    func rememberVideoFolder(_ folderID: String) {
        guard folderID != videoStudio.folderID else { return }
        var updated = videoStudio
        updated.folderID = folderID
        saveVideoStudio(updated)
    }

    func rememberVideoMood(_ mood: Mood) {
        guard mood != videoStudio.mood else { return }
        var updated = videoStudio
        updated.mood = mood
        saveVideoStudio(updated)
    }

    func toggle(_ clip: Clip) {
        guard !busy else { return }
        if selected.remove(clip.id) != nil { saveVideoSelection(); return }
        guard selected.count < (capabilities?.limit ?? 0) else { return }
        includeFolderClips([clip])
        selected.insert(clip.id)
        saveVideoSelection()
    }

    func select(_ clips: [Clip]) {
        guard !busy else { return }
        let limit = capabilities?.limit ?? 0
        var added: [Clip] = []
        for clip in clips where selected.count < limit {
            if selected.insert(clip.id).inserted { added.append(clip) }
        }
        includeFolderClips(added)
        if !added.isEmpty { saveVideoSelection() }
    }

    func clearSelection() {
        guard !busy else { return }
        selected.removeAll()
        saveVideoSelection()
    }

    func includeFolderClips(_ additional: [Clip], folderID: String? = nil) {
        var known = Set(clips.map(\.id))
        clips.append(contentsOf: additional.filter { known.insert($0.id).inserted })
        if let folderID {
            for clip in additional where !selected.contains(clip.id) || clipFolderIDs[clip.id] == nil {
                clipFolderIDs[clip.id] = folderID
            }
        }
    }

    @discardableResult func submit(_ mood: Mood) async -> Bool {
        guard canSubmit, let capabilities, capabilities.moods.contains(mood), cancelling.isEmpty else { return false }
        let batch = Batch(clip_ids: clips.filter { selected.contains($0.id) }.map(\.id), mood: mood, options: options)
        return await submit(batch, clearSelection: true, limit: capabilities.limit)
    }

    func canRetry(_ job: Job) -> Bool {
        job.status == .failed && connected && !busy && !refreshing && !checkingVideoOutbox && !requiresVideoReview && !blocked &&
            cancelling.isEmpty && options.roi.valid && validWireID(job.clip_id) &&
            capabilities?.moods.contains(job.mood) == true
    }

    func retry(_ job: Job) async {
        guard canRetry(job), let capabilities else { return }
        _ = await submit(Batch(clip_ids: [job.clip_id], mood: job.mood, options: options),
                         clearSelection: false, limit: capabilities.limit)
    }

    func submit(_ batch: Batch, clearSelection: Bool, limit: Int, queuedID: UUID? = nil) async -> Bool {
        busy = true
        revision += 1
        error = nil
        var startedPOST = false
        defer { busy = false }
        do {
            try Task.checkCancellation()
            try batch.validate(limit: limit)
            if let pendingKey { defaults.set(true, forKey: pendingKey) }
            startedPOST = true
            let received = try await api.submit(batch).jobs
            guard received.count == batch.clip_ids.count,
                  Set(received.map(\.id)).count == received.count,
                  received.map(\.clip_id) == batch.clip_ids,
                  received.allSatisfy({ $0.mood == batch.mood }) else { throw APIError.malformed }
            merge(received)
            if clearSelection { selected = []; saveVideoSelection() }
            if let queuedID, !updateQueuedVideo(queuedID, state: nil) { uncertain = true }
            else { clearPending() }
            return true
        } catch is CancellationError {
            // Leave a durable pending marker intact if an attempt had already started.
            if !isDemo && (startedPOST || queuedID != nil) { cancelledVideoAttempt = true }
            return false
        } catch {
            AppDiagnostics.record(error)
            if case .transport(let code)? = error as? APIError, code == URLError.cancelled.rawValue {
                // A started POST keeps its durable marker and is never automatically repeated.
                if !isDemo && startedPOST { cancelledVideoAttempt = true }
                return false
            }
            if (error as? APIError)?.ambiguous ?? true {
                uncertain = true
                // Never repeat POST. Load the authoritative list; user reviews before another submission.
                do { replaceJobs(try await api.jobs().jobs) } catch { AppDiagnostics.record(error); report(error) }
            } else if let queuedID, !updateQueuedVideo(queuedID, state: .rejected, message: (error as? APIError)?.title) {
                uncertain = true
            } else { clearPending() }
            report(error)
            return false
        }
    }

    func acknowledgeAfterReview() async {
        guard requiresVideoReview, !busy, !refreshing, cancelling.isEmpty else { return }
        busy = true
        revision += 1
        defer { busy = false }
        do {
            replaceJobs(try await api.jobs().jobs)
            let attempted = videoOutbox.filter { $0.state == .attempted }
            if attempted.isEmpty { selected = []; saveVideoSelection() }
            for item in attempted where !updateQueuedVideo(item.id, state: nil) { return }
            clearPending()
            error = nil
        } catch { AppDiagnostics.record(error); report(error) }
    }

    private func clearPending() {
        if let pendingKey { defaults.removeObject(forKey: pendingKey) }
        uncertain = false
        cancelledVideoAttempt = false
    }

    func poll() async {
        guard hasActive, !busy, !refreshing, cancelling.isEmpty else { return }
        let snapshot = revision
        do {
            let result = try await api.jobs()
            guard snapshot == revision, !busy, !refreshing, cancelling.isEmpty, !Task.isCancelled else { return }
            replaceJobs(result.jobs)
            if !connected {
                connected = true
                error = nil
            }
        } catch {
            AppDiagnostics.record(error)
            if snapshot == revision, !busy, !refreshing, !Task.isCancelled {
                connected = false
                latencyMs = nil
                report(error)
                if !isDemo { await tryAlternateProfile(after: activeProfile) }
            }
        }
    }

    func cancel(_ job: Job) async {
        guard !busy, !refreshing, job.status.active, capabilities?.features.cancel == true,
              !waitingForStop.contains(job.id),
              cancelling.insert(job.id).inserted else { return }
        revision += 1
        defer { cancelling.remove(job.id) }
        error = nil
        do {
            let updated = try await api.cancel(job.id)
            guard updated.id == job.id else { throw APIError.malformed }
            merge([updated])
            if updated.status.active { waitingForStop.insert(updated.id) }
        } catch { AppDiagnostics.record(error); report(error) }
    }

    func video(_ job: Job) async -> URL? {
        guard job.status == .completed, !mediaLoading else { return nil }
        mediaLoading = true
        defer { mediaLoading = false }
        error = nil
        do { return try await api.video(job) }
        catch { AppDiagnostics.record(error); report(error); return nil }
    }

    func replaceJobs(_ current: [Job]) {
        jobs = current
        waitingForStop.formIntersection(current.filter { $0.status.active }.map(\.id))
        observeVideos()
    }

    private func merge(_ incoming: [Job]) {
        for job in incoming {
            if let index = jobs.firstIndex(where: { $0.id == job.id }) { jobs[index] = job }
            else { jobs.append(job) }
        }
        observeVideos()
    }

    private func observeVideos() {
        jobsObservationWindow = hasActive ? Int(Date.now.timeIntervalSinceReferenceDate / 15) : 0
        observeCompletions(kind: "video", active: jobs.filter { $0.status.active }.map(\.id),
                           finished: jobs.filter { $0.status == .completed }.map(\.id), title: "Din video er klar!")
        observeCompletions(kind: "video-failed", active: jobs.filter { $0.status.active }.map(\.id),
                           finished: jobs.filter { $0.status == .failed }.map(\.id), title: "Videoen blev ikke færdig")
    }
}
