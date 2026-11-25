import SwiftUI

/// Replays only explicit close/remove/watch choices. No mail is sent by this outbox.
struct CaseTrackerSync: ViewModifier {
    let api: LiveAPI?
    @Environment(\.scenePhase) private var phase
    func body(content: Content) -> some View {
        content.task(id: "\(api?.queueTargetID ?? ""):\(phase == .active)") {
            guard phase == .active, let api, let bots = try? MigratedAppData.shared.loadBots().get() else { return }
            for bot in bots where bot.id != VillageBot.lumiID {
                let store = CaseTracker.Store(botID: bot.id)
                guard (try? store.pending().isEmpty) == false else { continue }
                do { try await CaseTrackerClient.flush(store, api: api) }
                catch { return }
            }
        }
    }
}
