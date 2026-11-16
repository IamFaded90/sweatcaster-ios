import ActivityKit
import CryptoKit
import UIKit

@MainActor final class RenderLiveActivity {
    static let shared = RenderLiveActivity()

    private struct Snapshot {
        let videoJobs: [Job]
        let codeJobs: [CodeBatchList.Job]
        let videoWindow: Int
        let codeWindow: Int
        let pairingKey: String?
        let connected: Bool
        let enabled: Bool

        var jobs: [RenderWork] { videoJobs.map(RenderWork.init(video:)) + codeJobs.map(RenderWork.init(code:)) }

        func observedAt(_ kind: RenderActivityAttributes.Kind) -> Date? {
            let window = kind == .video ? videoWindow : codeWindow
            guard window > 0 else { return nil }
            return Date(timeIntervalSinceReferenceDate: Double(window) * 15)
        }

        func state(for job: RenderWork) -> RenderActivityAttributes.ContentState {
            var state = job.state
            state.lastUpdatedAt = job.kind == .video
                ? videoJobs.first { $0.id == job.id }?.updated_at : observedAt(job.kind)
            return state
        }
    }

    private var pending: Snapshot?
    private var updating = false

    func sync(jobs: [Job], codeJobs: [CodeBatchList.Job], videoWindow: Int, codeWindow: Int,
              pairing: String?, connected: Bool, enabled: Bool) async {
        guard !Task.isCancelled else { return }
        pending = Snapshot(videoJobs: jobs, codeJobs: codeJobs, videoWindow: videoWindow, codeWindow: codeWindow,
                           pairingKey: pairing.map { digest("render-activity\n" + $0) },
                           connected: connected, enabled: enabled)
        guard !updating else { return }
        updating = true
        defer { updating = false }
        while let latest = pending {
            pending = nil
            await apply(latest)
        }
    }

    private func apply(_ snapshot: Snapshot) async {
        let enabled = snapshot.enabled && ActivityAuthorizationInfo().areActivitiesEnabled
        let pairingKey = enabled ? snapshot.pairingKey : nil
        let jobs = pairingKey != nil && snapshot.connected ? snapshot.jobs : []
        let job = jobs.filter(\.active).min { $0.priority < $1.priority }
        let key = job.flatMap { work in pairingKey.map { jobKey(pairing: $0, job: work) } }
        var current: Activity<RenderActivityAttributes>?

        for activity in Activity<RenderActivityAttributes>.activities {
            guard let pairingKey, activity.attributes.pairingKey == pairingKey else {
                await activity.end(nil, dismissalPolicy: .immediate)
                continue
            }
            if !snapshot.connected {
                if activity.activityState == .active {
                    await activity.update(ActivityContent(state: activity.content.state, staleDate: .now))
                }
                continue
            }
            if activity.attributes.jobKey == key && current == nil {
                current = activity
                continue
            }
            let previous = jobs.first { jobKey(pairing: pairingKey, job: $0) == activity.attributes.jobKey }
            let finished = previous.flatMap { $0.active ? nil : snapshot.state(for: $0) }
            let dismissal: ActivityUIDismissalPolicy = finished == nil ? .immediate : .after(.now.addingTimeInterval(90))
            await activity.end(finished.map { ActivityContent(state: $0, staleDate: nil) }, dismissalPolicy: dismissal)
        }

        guard let job, let key, let pairingKey, let observedAt = snapshot.observedAt(job.kind) else { return }
        // The successful poll is recorded in a 15-second window.
        let staleDate = observedAt.addingTimeInterval(50)
        let content = ActivityContent(state: snapshot.state(for: job), staleDate: staleDate)
        if let current {
            await current.update(content)
        } else if staleDate > .now && UIApplication.shared.applicationState == .active {
            do {
                let attributes = RenderActivityAttributes(jobKey: key, kind: job.kind, pairingKey: pairingKey)
                _ = try Activity.request(attributes: attributes, content: content)
            } catch {
                AppDiagnostics.record(error)
            }
        }
    }

    private func jobKey(pairing: String, job: RenderWork) -> String {
        let id = job.kind == .video ? job.id : "code:\(job.id)"
        return digest("\(pairing)\n\(id)")
    }

    private func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
