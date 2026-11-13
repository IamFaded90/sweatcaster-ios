// Keeps offline video requests tied to their paired PC and records attempts before sending.
import Foundation

struct VideoOutboxItem: Codable, Identifiable, Sendable {
    enum State: String, Codable, Sendable { case waiting, attempted, rejected }

    let id: UUID
    let createdAt: Date
    let batch: Batch
    let clips: [SavedVideoClip]
    let targetID: String?
    var state: State
    var message: String?
}

extension Model {
    var videoOutbox: [VideoOutboxItem] { videoStudio.outbox }
    var canQueueVideoOffline: Bool {
        !connected && !isDemo && api is LiveAPI && !busy && !refreshing && !requiresVideoReview && !selected.isEmpty &&
            videoStateReadable && options.roi.valid && videoOutbox.count < 5 && savedVideoClips.allSatisfy { $0.folderID != nil }
    }

    func queueVideoOffline(_ mood: Mood) -> Bool {
        guard canQueueVideoOffline, let live = api as? LiveAPI, live.server.address == address else { return false }
        let sources = savedVideoClips
        let batch = Batch(clip_ids: sources.map { $0.clip.id }, mood: mood, options: options)
        guard (try? batch.validate(limit: 10)) != nil else { return false }
        var updated = videoStudio
        updated.outbox.append(VideoOutboxItem(id: UUID(), createdAt: .now, batch: batch, clips: sources,
                                             targetID: live.queueTargetID, state: .waiting, message: nil))
        updated.mood = mood
        updated.clips = []
        guard saveVideoStudio(updated) else { return false }
        selected = []
        return true
    }

    func removeQueuedVideo(_ id: UUID) {
        guard !checkingVideoOutbox, let item = videoOutbox.first(where: { $0.id == id }), item.state != .attempted else { return }
        if updateQueuedVideo(id, state: nil) { videoOutboxNotice = nil }
    }

    func deliverQueuedVideos() async {
        guard !checkingVideoOutbox, connected, !isDemo, !requiresVideoReview, videoStateReadable,
              videoOutbox.contains(where: { $0.state == .waiting }),
              let live = api as? LiveAPI, live.server.address == address else { return }
        let source = live.server.address
        checkingVideoOutbox = true
        defer { checkingVideoOutbox = false }
        videoOutboxNotice = nil
        while !Task.isCancelled && connected && !requiresVideoReview && !isDemo && address == source {
            guard let item = videoOutbox.first(where: { $0.state == .waiting }) else { return }
            guard item.targetID == live.queueTargetID else {
                guard updateQueuedVideo(item.id, state: .rejected,
                                        message: "PC-parringen kan ikke bekræftes. Fjern jobbet fra den lokale kø.") else { return }
                continue
            }
            if busy || refreshing || !cancelling.isEmpty {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                continue
            }
            guard let caps = capabilities, caps.moods.contains(item.batch.mood),
                  (try? item.batch.validate(limit: caps.limit)) != nil else {
                videoOutboxNotice = "Et køjob passer ikke til PC’ens nuværende stilarter eller klipgrænse."
                return
            }
            if caps.missingRequired.contains(where: {
                item.batch.options.commentary != false || $0.name == "ffmpeg" || $0.name == "ffprobe"
            }) {
                videoOutboxNotice = "PC’en mangler en tjeneste til det næste køjob."
                return
            }
            let checkedRevision = revision
            do {
                guard try await verifyQueuedClips(item, using: live) else {
                    if !Task.isCancelled, address == source {
                        videoOutboxNotice = "Et klip kan ikke bekræftes i sin mappe. Åbn mappen for at kontrollere klippet."
                    }
                    return
                }
            } catch {
                AppDiagnostics.record(error)
                if !Task.isCancelled, address == source {
                    videoOutboxNotice = "PC’en kunne ikke kontrollere køens klip lige nu."
                }
                return
            }
            guard !Task.isCancelled, connected, address == source, !isDemo, !requiresVideoReview else { return }
            guard checkedRevision == revision, !busy, !refreshing, cancelling.isEmpty else { continue }
            // Record the claim on disk before the first POST. Relaunch can only reconcile it.
            guard updateQueuedVideo(item.id, state: .attempted) else { return }
            for clip in item.clips { includeFolderClips([clip.clip], folderID: clip.folderID) }
            let accepted = await submit(item.batch, clearSelection: false, limit: caps.limit, queuedID: item.id)
            if !accepted { return }
        }
    }

    private func verifyQueuedClips(_ item: VideoOutboxItem, using live: LiveAPI) async throws -> Bool {
        guard item.batch.clip_ids == item.clips.map({ $0.clip.id }) else { return false }
        for (folder, clips) in Dictionary(grouping: item.clips, by: \.folderID) {
            try Task.checkCancellation()
            guard let folder else { return false }
            let current: [Clip]
            if folder == "legacy" {
                current = try await live.clips().clips
            } else {
                let page = try await live.v2ClipPage(rootID: folder, limit: 100)
                guard page.root_id == folder, page.ready else { return false }
                current = page.clips
            }
            guard clips.allSatisfy({ saved in
                current.contains {
                    $0.id == saved.clip.id && $0.name == saved.clip.name && $0.width == saved.clip.width &&
                        $0.height == saved.clip.height && abs($0.duration_seconds - saved.clip.duration_seconds) < 0.001
                }
            }) else { return false }
        }
        return true
    }

    func updateQueuedVideo(_ id: UUID, state: VideoOutboxItem.State?, message: String? = nil) -> Bool {
        var updated = videoStudio
        guard let index = updated.outbox.firstIndex(where: { $0.id == id }) else { return false }
        if let state {
            updated.outbox[index].state = state
            updated.outbox[index].message = message
        } else {
            updated.outbox.remove(at: index)
        }
        return saveVideoStudio(updated)
    }
}
