// Polls Code Bot status and records completion notifications.
import Foundation

extension Model {
    func pollCodeJobs() async -> Bool {
        guard connected, !isDemo, let live = api as? LiveAPI else { return false }
        let server = address
        do {
            let jobs = try await live.codeBatches().jobs
            guard connected, !isDemo, address == server, !Task.isCancelled,
                  (api as? LiveAPI)?.queueTargetID == live.queueTargetID else { return false }
            observedCodeJobs = jobs
            let active = jobs.filter { ["queued", "running"].contains($0.status) }.map(\.id)
            codeJobsObservationWindow = active.isEmpty ? 0 : Int(Date.now.timeIntervalSinceReferenceDate / 15)
            let finished = jobs.filter { ["review", "applied", "completed"].contains($0.status) }.map(\.id)
            observeCompletions(kind: "code", active: active, finished: finished, title: "Dit Code Bot-forslag er klar!")
        } catch let APIError.http(status, _) where [401, 403, 404, 405].contains(status) {
            AppDiagnostics.record(APIError.http(status, nil))
            if !Task.isCancelled, (api as? LiveAPI)?.queueTargetID == live.queueTargetID {
                observedCodeJobs = []
                codeJobsObservationWindow = 0
            }
            return false
        } catch {
            AppDiagnostics.record(error)
            if Task.isCancelled { return false }
        }
        return true
    }

    func observeCompletions(kind: String, active: [String], finished: [String], title: String) {
        guard !isDemo, !address.isEmpty else { return }
        let server = address
        let key = AppStorageKeys.notificationsActive(kind, server: server)
        let previous = Set(defaults.stringArray(forKey: key) ?? [])
        defaults.set(active, forKey: key)
        for id in previous.intersection(finished) {
            Task { await JobNotifications.shared.completed(kind: kind, server: server, id: id, title: title) }
        }
    }
}
