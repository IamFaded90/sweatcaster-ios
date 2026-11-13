// Shared Agent-Hub helpers for local bots and visibility.

import Foundation
import SwiftUI

extension AgentHub {
    var villageVisible: Bool { isVisible && hubPhase == .active }

    var localVillageBots: [VillageBot] {
        VillageBot.list(from: localBotsData)
    }
}
