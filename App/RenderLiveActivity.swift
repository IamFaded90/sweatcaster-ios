// Converts verified video and Code Bot statuses to the existing Live Activity.

import Foundation

struct RenderWork {
    let id: String
    let kind: RenderActivityAttributes.Kind
    let state: RenderActivityAttributes.ContentState
    let active: Bool
    let priority: Int

    init(video: Job) {
        id = video.id
        kind = .video
        let progress = video.status == .completed ? 1 : (video.progress.isFinite ? min(1, max(0, video.progress)) : 0)
        state = .init(progress: progress, phase: video.status.title)
        active = video.status.active
        priority = video.status == .rendering ? 0 : video.status == .queued ? 3 : 1
    }

    init(code: CodeBatchList.Job) {
        id = code.id
        kind = .code
        let phase: String
        switch code.status {
        case "queued": phase = "Kodejob i kø"
        case "running": phase = "Code Bot arbejder"
        case "review": phase = "Kodeforslag klar til godkendelse"
        case "applied", "completed": phase = "Kodejob afsluttet"
        case "declined": phase = "Ingen ændring foreslået"
        case "failed": phase = "Kodejob mislykkedes"
        case "cancelled": phase = "Kodejob annulleret"
        default: phase = "Kodejob stoppet"
        }
        active = code.status == "queued" || code.status == "running"
        state = .init(progress: 0, phase: phase, progressIsKnown: false, isRunning: active)
        priority = code.status == "running" ? 2 : 4
    }
}
