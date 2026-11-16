import BackgroundTasks
import UIKit

/// Drains the existing durable chat outbox using the paired identity and its normal claim/retry rules.
/// The registration, rescheduling and expiration flow follows SwiftResilience's background drainer.
@MainActor enum PCChatBackgroundDelivery {
    static let identifier = "dk.fadedai.pc-chat-outbox"
    private static let suspendedKey = "fadedai.pc-chat-outbox.private-session"
    private static var registered = false
    private static var running: Task<Void, Never>?

    static func register() {
        registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { task in
            Task { @MainActor in
                guard let processing = task as? BGProcessingTask else {
                    task.setTaskCompleted(success: false)
                    return
                }
                deliver(processing)
            }
        }
    }

    static func setPrivateSession(_ active: Bool) {
        UserDefaults.standard.set(active, forKey: suspendedKey)
        if active {
            running?.cancel()
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
        }
    }

    static func schedule(using api: LiveAPI?) {
        guard let api, !isSuspended else { return }
        guard PCChatOutbox().pendingCount(for: api.server.address, targetID: api.queueTargetID) > 0 else { return }
        submit()
    }

    private static var isSuspended: Bool { UserDefaults.standard.bool(forKey: suspendedKey) }

    private static func submit() {
        guard registered, !isSuspended else { return }
        let request = BGProcessingTaskRequest(identifier: identifier)
        request.requiresNetworkConnectivity = true
        request.earliestBeginDate = Date.now.addingTimeInterval(300)
        do { try BGTaskScheduler.shared.submit(request) }
        catch { AppDiagnostics.record(error) }
    }

    private static func deliver(_ processing: BGProcessingTask) {
        guard running == nil, !isSuspended else {
            processing.setTaskCompleted(success: false)
            return
        }
        let work = Task { @MainActor in
            var completed = false
            defer {
                running = nil
                processing.setTaskCompleted(success: completed && !Task.isCancelled)
            }
            guard UIApplication.shared.isProtectedDataAvailable else {
                submit()
                return
            }
            guard !Task.isCancelled,
                  let address = UserDefaults.standard.string(forKey: Pairing.addressKey),
                  let server = try? Server(address), let key = try? Pairing.load(address),
                  let api = try? LiveAPI(server: server, token: key) else { return }
            await PCChatOutbox().deliverReady(using: api)
            guard !Task.isCancelled else { return }
            let pending = PCChatOutbox().pendingCount(for: address, targetID: api.queueTargetID)
            if pending > 0 { schedule(using: api) }
            completed = pending == 0
        }
        running = work
        processing.expirationHandler = { work.cancel() }
    }
}
