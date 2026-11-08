import ActivityKit
import CryptoKit
import UIKit

@MainActor final class RenderLiveActivity {
    static let shared = RenderLiveActivity()

    private struct Snapshot {
        let jobs: [Job]
        let server: String
        let enabled: Bool
    }

    private var pending: Snapshot?
    private var updating = false

    func sync(jobs: [Job], server: String, enabled: Bool) async {
        pending = Snapshot(jobs: jobs, server: server, enabled: enabled)
        guard !updating else { return }
        updating = true
        defer { updating = false }
        while let latest = pending {
            pending = nil
            await apply(latest)
        }
    }

    private func apply(_ snapshot: Snapshot) async {
        let enabled = snapshot.enabled && !snapshot.server.isEmpty && ActivityAuthorizationInfo().areActivitiesEnabled
        let active = enabled ? snapshot.jobs.filter { $0.status.active } : []
        let job = active.first { $0.status == .rendering }
            ?? active.first { $0.status != .queued }
            ?? active.first
        let key = job.map { jobKey(server: snapshot.server, id: $0.id) }
        var current: Activity<RenderActivityAttributes>?

        for activity in Activity<RenderActivityAttributes>.activities {
            if activity.attributes.jobKey == key && current == nil {
                current = activity
                continue
            }
            let previous = enabled ? snapshot.jobs.first {
                jobKey(server: snapshot.server, id: $0.id) == activity.attributes.jobKey
            } : nil
            let finished = previous.flatMap { $0.status.active ? nil : renderState($0) }
            let dismissal: ActivityUIDismissalPolicy = finished == nil ? .immediate : .after(.now.addingTimeInterval(90))
            await activity.end(finished.map { ActivityContent(state: $0, staleDate: nil) }, dismissalPolicy: dismissal)
        }

        guard let job, let key else { return }
        let content = ActivityContent(state: renderState(job), staleDate: .now.addingTimeInterval(35))
        if let current {
            await current.update(content)
        } else if UIApplication.shared.applicationState == .active {
            _ = try? Activity.request(attributes: RenderActivityAttributes(jobKey: key), content: content)
        }
    }

    private func renderState(_ job: Job) -> RenderActivityAttributes.ContentState {
        let progress = job.status == .completed ? 1 : (job.progress.isFinite ? min(1, max(0, job.progress)) : 0)
        return .init(progress: progress, phase: job.status.title)
    }

    private func jobKey(server: String, id: String) -> String {
        SHA256.hash(data: Data("\(server)\n\(id)".utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
