import ActivityKit
import CryptoKit
import UIKit

@MainActor final class RenderLiveActivity {
    static let shared = RenderLiveActivity()

    private struct Snapshot {
        let jobs: [RenderWork]
        let server: String
        let enabled: Bool
    }

    private var pending: Snapshot?
    private var updating = false

    func sync(jobs: [Job], server: String, enabled: Bool, codeJobs: [CodeBatchList.Job] = []) async {
        pending = Snapshot(jobs: jobs.map(RenderWork.init(video:)) + codeJobs.map(RenderWork.init(code:)),
                           server: server, enabled: enabled)
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
        let active = enabled ? snapshot.jobs.filter(\.active) : []
        let job = active.min { $0.priority < $1.priority }
        let key = job.map { jobKey(server: snapshot.server, job: $0) }
        var current: Activity<RenderActivityAttributes>?

        for activity in Activity<RenderActivityAttributes>.activities {
            if activity.attributes.jobKey == key && current == nil {
                current = activity
                continue
            }
            let previous = enabled ? snapshot.jobs.first {
                jobKey(server: snapshot.server, job: $0) == activity.attributes.jobKey
            } : nil
            let finished = previous.flatMap { $0.active ? nil : $0.state }
            let dismissal: ActivityUIDismissalPolicy = finished == nil ? .immediate : .after(.now.addingTimeInterval(90))
            await activity.end(finished.map { ActivityContent(state: $0, staleDate: nil) }, dismissalPolicy: dismissal)
        }

        guard let job, let key else { return }
        let content = ActivityContent(state: job.state, staleDate: .now.addingTimeInterval(35))
        if let current {
            await current.update(content)
        } else if UIApplication.shared.applicationState == .active {
            do {
                _ = try Activity.request(attributes: RenderActivityAttributes(jobKey: key, kind: job.kind), content: content)
            } catch {
                AppDiagnostics.record(error)
            }
        }
    }

    private func jobKey(server: String, job: RenderWork) -> String {
        let id = job.kind == .video ? job.id : "code:\(job.id)"
        return SHA256.hash(data: Data("\(server)\n\(id)".utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
