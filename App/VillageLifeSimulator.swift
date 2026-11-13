import Foundation
import SwiftUI

/// Local demo life loop. LIFE-DESIGN: replace thresholds/formulas when Del B lands.
@MainActor
final class VillageLifeSimulator: ObservableObject {
    @Published private(set) var bots: [VillageLifeBot] = []
    @Published var paused = false

    /// Seconds between destination decisions (demo is intentionally a bit fast).
    /// LIFE-DESIGN: tune when Del B lands.
    var decisionEvery: TimeInterval = 5
    var walkSeconds: TimeInterval = 3

    private var lastDecision = Date.distantPast
    private var handoffCooldownUntil = Date.distantPast

    init() {
        bots = Self.seedAdamEva()
    }

    static func seedAdamEva() -> [VillageLifeBot] {
        let now = Date()
        return [
            VillageLifeBot(
                id: "adam", displayName: "Adam", archetype: .logic, spriteID: "adam",
                zoneID: .research, activity: .work, pose: .work,
                needs: VillageNeeds(energy: 0.78, social: 0.42, fulfillment: 0.7, mood: 0.62),
                destinationZoneID: nil, pathProgress: 0, speechHint: nil, carrying: nil,
                lastEventID: "morning_startup", customSprite: nil, linkedAgentID: nil, updatedAt: now
            ),
            VillageLifeBot(
                id: "eva", displayName: "Eva", archetype: .creative, spriteID: "eva",
                zoneID: .video, activity: .work, pose: .work,
                needs: VillageNeeds(energy: 0.7, social: 0.5, fulfillment: 0.66, mood: 0.68),
                destinationZoneID: nil, pathProgress: 0, speechHint: nil, carrying: nil,
                lastEventID: "inspired", customSprite: nil, linkedAgentID: nil, updatedAt: now
            )
        ]
    }

    func resetDemo() {
        bots = Self.seedAdamEva()
        lastDecision = .distantPast
        handoffCooldownUntil = .distantPast
    }

    func mergeLocalProfiles(_ profiles: [VillageBot]) {
        guard !profiles.isEmpty else { return }
        var next = bots
        for (index, profile) in profiles.prefix(8).enumerated() {
            let archetype = VillageArchetype.from(personality: profile.personality, color: profile.color, name: profile.name)
            let sprite = profile.name.localizedCaseInsensitiveContains("eva") || profile.color == "Lilla" ? "eva" : "adam"
            if index < next.count {
                next[index].displayName = profile.name.isEmpty ? next[index].displayName : profile.name
                next[index].archetype = archetype
                next[index].customSprite = profile.sprite
                if profile.sprite == nil { next[index].spriteID = sprite }
            } else {
                next.append(
                    VillageLifeBot(
                        id: profile.id.uuidString, displayName: profile.name.isEmpty ? "Bot \(index + 1)" : profile.name,
                        archetype: archetype, spriteID: sprite,
                        zoneID: archetype.workZone, activity: .idle, pose: .idle,
                        needs: .balanced, destinationZoneID: nil, pathProgress: 0,
                        speechHint: nil, carrying: nil, lastEventID: nil,
                        customSprite: profile.sprite, linkedAgentID: nil, updatedAt: Date()
                    )
                )
            }
        }
        bots = Array(next.prefix(10))
    }

    func applyHubAgents(_ agents: [V2Hub.Agent], offline: Bool) {
        // LIFE-DESIGN: conflict table PC vs local sim
        guard !agents.isEmpty else { return }
        var next = bots
        for agent in agents.prefix(10) {
            if let idx = next.firstIndex(where: {
                $0.linkedAgentID == agent.id ||
                $0.displayName.localizedCaseInsensitiveCompare(agent.name) == .orderedSame ||
                $0.id.localizedCaseInsensitiveCompare(agent.id) == .orderedSame
            }) {
                next[idx].linkedAgentID = agent.id
                next[idx].displayName = agent.name
                switch agent.status {
                case .working, .thinking:
                    next[idx].destinationZoneID = nil
                    next[idx].pathProgress = 0
                    next[idx].zoneID = VillageZoneID.fromHubRoom(agent.room_id)
                    next[idx].activity = .work
                    next[idx].pose = .work
                case .offline:
                    next[idx].zoneID = .sleep
                    next[idx].activity = .sleep
                    next[idx].pose = .sleep
                    next[idx].destinationZoneID = nil
                    next[idx].pathProgress = 0
                case .ready:
                    if next[idx].activity == .work {
                        next[idx].activity = .idle
                        next[idx].pose = .idle
                    }
                }
            } else if next.count < 10 {
                let zone = offline || agent.status == .offline ? VillageZoneID.sleep : VillageZoneID.fromHubRoom(agent.room_id)
                let activity: VillageActivity = {
                    switch agent.status {
                    case .working, .thinking: return .work
                    case .offline: return .sleep
                    case .ready: return .idle
                    }
                }()
                next.append(
                    VillageLifeBot(
                        id: agent.id, displayName: agent.name, archetype: .logic, spriteID: "adam",
                        zoneID: zone, activity: activity, pose: activity, needs: .balanced,
                        destinationZoneID: nil, pathProgress: 0, speechHint: nil, carrying: nil,
                        lastEventID: nil, customSprite: nil, linkedAgentID: agent.id, updatedAt: Date()
                    )
                )
            }
        }
        bots = next
    }

    func tick(now: Date = Date(), hour: Int, reduceMotion: Bool, offlinePC: Bool) {
        guard !paused else { return }
        var next = bots
        let dt = reduceMotion ? 2.0 : 1.0

        for i in next.indices {
            // Hub-locked work/sleep skips soft drift destination changes mid-path still OK
            driftNeeds(&next[i].needs, activity: next[i].activity, dt: dt)
            next[i].needs.clamp()
            next[i].updatedAt = now

            if let dest = next[i].destinationZoneID {
                if reduceMotion {
                    next[i].zoneID = dest
                    next[i].destinationZoneID = nil
                    next[i].pathProgress = 0
                    next[i].activity = arrivalActivity(for: next[i], hour: hour)
                    next[i].pose = next[i].activity
                } else {
                    next[i].pathProgress = min(1, next[i].pathProgress + dt / walkSeconds)
                    next[i].activity = .walk
                    next[i].pose = .walk
                    if next[i].pathProgress >= 1 {
                        next[i].zoneID = dest
                        next[i].destinationZoneID = nil
                        next[i].pathProgress = 0
                        next[i].activity = arrivalActivity(for: next[i], hour: hour)
                        next[i].pose = next[i].activity
                    }
                }
            }

            if let carry = next[i].carrying, next[i].zoneID == next.first(where: { $0.id == carry.toBotID })?.zoneID {
                next[i].speechHint = "file_handoff"
                next[i].carrying = nil
                next[i].lastEventID = "file_handoff"
            }
        }

        if now.timeIntervalSince(lastDecision) >= (reduceMotion ? decisionEvery * 1.5 : decisionEvery) {
            lastDecision = now
            decideDestinations(&next, hour: hour, now: now, offlinePC: offlinePC)
            maybeCafeTalk(&next)
            maybeFileHandoff(&next, now: now)
        }

        // Clear short speech hints
        for i in next.indices {
            if next[i].activity != .talk, next[i].speechHint == "cafe_chat" {
                next[i].speechHint = nil
            }
        }

        bots = next
    }

    // MARK: - Decision (minimum policy)

    private func decideDestinations(_ bots: inout [VillageLifeBot], hour: Int, now: Date, offlinePC: Bool) {
        let night = hour < 7 || hour >= 22
        for i in bots.indices {
            if bots[i].destinationZoneID != nil { continue }
            // Don't yank hub-working bots around
            if bots[i].linkedAgentID != nil, bots[i].activity == .work, !offlinePC { continue }

            let target = chooseZone(for: bots[i], night: night, others: bots)
            if target != bots[i].zoneID {
                bots[i].destinationZoneID = target
                bots[i].pathProgress = 0
                bots[i].activity = .walk
                bots[i].pose = .walk
                bots[i].speechHint = nil
            } else {
                bots[i].activity = arrivalActivity(for: bots[i], hour: hour)
                bots[i].pose = bots[i].activity
            }
        }
    }

    func chooseZone(for bot: VillageLifeBot, night: Bool, others: [VillageLifeBot]) -> VillageZoneID {
        // LIFE-DESIGN: replace with full priority table
        if night || bot.needs.energy < 0.28 { return .sleep }
        if bot.needs.social < 0.35 {
            let someoneAtCafe = others.contains { $0.id != bot.id && ($0.zoneID == .cafe || $0.destinationZoneID == .cafe) }
            if someoneAtCafe || bot.needs.social < 0.22 { return .cafe }
        }
        if bot.needs.fulfillment < 0.45 || bot.activity == .work {
            return bot.archetype.workZone
        }
        if bot.needs.energy < 0.45 { return .sleep }
        if bot.needs.mood < 0.4 { return .cafe }
        return bot.zoneID == .sleep ? bot.archetype.workZone : bot.zoneID
    }

    private func arrivalActivity(for bot: VillageLifeBot, hour: Int) -> VillageActivity {
        let night = hour < 7 || hour >= 22
        switch bot.zoneID {
        case .sleep: return .sleep
        case .cafe:
            return night ? .rest : .talk
        case .research, .video:
            return night ? .rest : .work
        }
    }

    private func driftNeeds(_ needs: inout VillageNeeds, activity: VillageActivity, dt: Double) {
        // LIFE-DESIGN: formal rates
        let t = dt / 10
        switch activity {
        case .work:
            needs.energy -= 0.035 * t
            needs.fulfillment += 0.04 * t
            needs.social -= 0.02 * t
            needs.mood += 0.01 * t
        case .talk:
            needs.social += 0.06 * t
            needs.mood += 0.03 * t
            needs.energy -= 0.015 * t
        case .sleep:
            needs.energy += 0.08 * t
            needs.social -= 0.01 * t
            needs.mood += 0.01 * t
        case .rest:
            needs.energy += 0.03 * t
            needs.mood += 0.02 * t
        case .walk:
            needs.energy -= 0.02 * t
        case .idle:
            needs.energy -= 0.01 * t
            needs.fulfillment -= 0.01 * t
        }
    }

    private func maybeCafeTalk(_ bots: inout [VillageLifeBot]) {
        let cafe = bots.indices.filter { bots[$0].zoneID == .cafe && bots[$0].destinationZoneID == nil }
        guard cafe.count >= 2 else { return }
        for i in cafe.prefix(2) {
            bots[i].activity = .talk
            bots[i].pose = .talk
            bots[i].speechHint = "cafe_chat"
            bots[i].lastEventID = "cafe_chat"
            bots[i].needs.social = min(1, bots[i].needs.social + 0.08)
        }
    }

    private func maybeFileHandoff(_ bots: inout [VillageLifeBot], now: Date) {
        guard now > handoffCooldownUntil, bots.count >= 2 else { return }
        let donor = bots.firstIndex { $0.zoneID == $0.archetype.workZone && $0.activity == .work && $0.carrying == nil }
        let receiver = bots.firstIndex { idx in
            guard let donor else { return false }
            return idx != donor && bots[idx].archetype != bots[donor].archetype
        }
        guard let donor, let receiver else { return }
        if Int.random(in: 0..<100) > 18 { return }
        let item = VillageCarryItem(
            kind: "file_share", labelKey: "shared_clip",
            fromBotID: bots[donor].id, toBotID: bots[receiver].id
        )
        bots[donor].carrying = item
        bots[donor].destinationZoneID = bots[receiver].zoneID
        bots[donor].pathProgress = 0
        bots[donor].activity = .walk
        bots[donor].pose = .walk
        bots[donor].lastEventID = "file_handoff"
        handoffCooldownUntil = now.addingTimeInterval(90)
    }

    static func mapPoint(zone: VillageZoneID, size: CGSize) -> CGPoint {
        let columns: [CGFloat] = [0.27, 0.73, 0.27, 0.73]
        let rows: [CGFloat] = [0.28, 0.37, 0.65, 0.74]
        let i = zone.pointIndex
        return CGPoint(x: size.width * columns[i], y: size.height * rows[i])
    }

    static func interpolatedPoint(bot: VillageLifeBot, size: CGSize) -> CGPoint {
        let from = mapPoint(zone: bot.zoneID, size: size)
        guard let dest = bot.destinationZoneID else { return CGPoint(x: from.x, y: from.y + 36) }
        let to = mapPoint(zone: dest, size: size)
        let t = bot.pathProgress
        return CGPoint(
            x: from.x + (to.x - from.x) * t,
            y: from.y + 36 + (to.y - from.y) * t
        )
    }
}
