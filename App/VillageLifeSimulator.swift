import Foundation
import Combine

/// Del B Universim life loop — docs/UNIVERSIM-LIFE-DESIGN.md
@MainActor
final class VillageLifeSimulator: ObservableObject {
    @Published private(set) var bots: [VillageLifeBot] = []
    @Published private(set) var virtualClock: Date
    @Published private(set) var activeEvents: [VillageEventOccurrence] = []
    @Published private(set) var banner: String?
    @Published var paused = false
    @Published var filmMode = true

    let isDemoClock: Bool

    var decisionEvery: TimeInterval = 8
    var walkSeconds: TimeInterval = 4
    var minStaySeconds: TimeInterval = 24
    var cafeSeconds: TimeInterval = 16
    var restSessionSeconds: TimeInterval = 24
    var practiceSessionSeconds: TimeInterval = 24
    var sleepMinSeconds: TimeInterval = 24

    private var lastDecision = Date.distantPast
    private var lastTickAt = Date.distantPast
    private var speechClearAt: [String: Date] = [:]
    private var walkStartedAt: [String: Date] = [:]
    private var cafeEndsAt: [String: Date] = [:]
    private var restEndsAt: [String: Date] = [:]
    private var practiceEndsAt: [String: Date] = [:]
    private var cafePairCooldownUntil: Date = .distantPast
    private var demoFileShown = false
    private var lastWasOffline = false
    private var lastDayBucket: Int?
    private var morningFiredForDay: Int?
    private var nightFiredForDay: Int?
    private var completedQuestIDs: Set<String> = []
    private var firstHubSyncDone = false
    private let calendar: Calendar

    init(isDemoClock: Bool = true, now: Date = .now) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        self.calendar = cal
        self.isDemoClock = isDemoClock
        if isDemoClock {
            var comps = cal.dateComponents([.year, .month, .day], from: now)
            comps.hour = 9
            comps.minute = 0
            comps.second = 0
            self.virtualClock = cal.date(from: comps) ?? now
        } else {
            self.virtualClock = now
        }
        bots = Self.seedAdamEva(now: now)
    }

    static func seedAdamEva(now: Date = .now) -> [VillageLifeBot] {
        [
            VillageLifeBot(
                id: "adam", displayName: "Adam", archetype: .logic, spriteID: "adam",
                zoneID: .research, activity: .idle, pose: .idle,
                needs: VillageNeeds(energy: 0.80, social: 0.52, fulfillment: 0.48, mood: 0.62),
                destinationZoneID: nil, pathProgress: 0, speechHint: nil, carrying: nil,
                lastEventID: nil, customSprite: nil, linkedAgentID: nil, updatedAt: now,
                arrivedAt: now
            ),
            VillageLifeBot(
                id: "eva", displayName: "Eva", archetype: .creative, spriteID: "eva",
                zoneID: .video, activity: .idle, pose: .idle,
                needs: VillageNeeds(energy: 0.76, social: 0.38, fulfillment: 0.55, mood: 0.58),
                destinationZoneID: nil, pathProgress: 0, speechHint: nil, carrying: nil,
                lastEventID: nil, customSprite: nil, linkedAgentID: nil, updatedAt: now,
                arrivedAt: now
            )
        ]
    }

    func resetDemo() {
        bots = Self.seedAdamEva()
        lastDecision = .distantPast
        activeEvents = []
        banner = nil
        demoFileShown = false
        walkStartedAt = [:]
        cafeEndsAt = [:]
        restEndsAt = [:]
        practiceEndsAt = [:]
        speechClearAt = [:]
    }

    // MARK: - Profiles / hub

    func mergeLocalProfiles(_ profiles: [VillageBot]) {
        var next = bots
        if !next.contains(where: { $0.id == "adam" }) || !next.contains(where: { $0.id == "eva" }) {
            for seed in Self.seedAdamEva() where !next.contains(where: { $0.id == seed.id }) {
                next.insert(seed, at: seed.id == "adam" ? 0 : min(1, next.count))
            }
        }

        let profileIDs = Set(profiles.map(\.id.uuidString))
        next.removeAll { bot in
            bot.linkedAgentID == nil
                && bot.id != "adam" && bot.id != "eva"
                && !profileIDs.contains(bot.id)
        }

        for profile in profiles.prefix(8) {
            let archetype = VillageArchetype.from(personality: profile.personality, color: profile.color, name: profile.name)
            let sprite = profile.name.localizedCaseInsensitiveContains("eva") || profile.color == "Lilla" ? "eva" : "adam"
            let name = profile.name.isEmpty ? "Bot" : profile.name

            if let idx = next.firstIndex(where: { $0.id == profile.id.uuidString }) {
                next[idx].displayName = name
                next[idx].archetype = archetype
                next[idx].customSprite = profile.sprite
                if profile.sprite == nil { next[idx].spriteID = sprite }
                continue
            }

            if let idx = next.firstIndex(where: {
                ($0.id == "adam" || $0.id == "eva") &&
                $0.displayName.localizedCaseInsensitiveCompare(name) == .orderedSame
            }) {
                next[idx].archetype = archetype
                next[idx].customSprite = profile.sprite
                if profile.sprite == nil { next[idx].spriteID = sprite }
                continue
            }

            guard next.count < 10 else { break }
            next.append(
                VillageLifeBot(
                    id: profile.id.uuidString, displayName: name,
                    archetype: archetype, spriteID: sprite,
                    zoneID: archetype.workZone, activity: .idle, pose: .idle,
                    needs: .balanced, destinationZoneID: nil, pathProgress: 0,
                    speechHint: nil, carrying: nil, lastEventID: nil,
                    customSprite: profile.sprite, linkedAgentID: nil, updatedAt: Date(),
                    arrivedAt: Date()
                )
            )
        }
        bots = Array(next.prefix(10))
    }

    func applyHubAgents(_ agents: [V2Hub.Agent], offline: Bool) {
        if offline {
            if !lastWasOffline {
                banner = VillageCopy.speech("offline_rest")
                pushEvent(
                    eventID: "offline_rest",
                    botIDs: [],
                    zone: nil,
                    speech: "offline_rest",
                    duration: 8,
                    banner: banner,
                    now: .now
                )
            }
            lastWasOffline = true
            for i in bots.indices {
                bots[i].pcJobRunning = false
                bots[i].pcJobQueued = false
                bots[i].pcLiveLabel = nil
            }
            return
        }

        if lastWasOffline {
            banner = VillageCopy.speech("pc_reconnected")
            pushEvent(
                eventID: "pc_reconnected",
                botIDs: [],
                zone: nil,
                speech: "pc_reconnected",
                duration: 6,
                banner: banner,
                now: .now
            )
        }
        lastWasOffline = false

        var next = bots
        for agent in agents.prefix(10) {
            applyAgent(&next, agent: agent)
        }

        // Quest completion bonuses (once per quest id after first sync).
        let quests = agents.flatMap(\.recent_quests)
        if firstHubSyncDone {
            for quest in quests where !completedQuestIDs.contains(quest.id) {
                completedQuestIDs.insert(quest.id)
                guard let idx = next.firstIndex(where: {
                    $0.linkedAgentID == agents.first(where: { a in a.recent_quests.contains(where: { $0.id == quest.id }) })?.id
                        || $0.displayName.localizedCaseInsensitiveCompare(
                            agents.first(where: { $0.recent_quests.contains(where: { $0.id == quest.id }) })?.name ?? ""
                        ) == .orderedSame
                }) else { continue }
                switch quest.state {
                case .completed:
                    next[idx].needs.fulfillment = min(1, next[idx].needs.fulfillment + 0.10)
                    next[idx].needs.clamp()
                    say(&next[idx], "work_finished", now: .now)
                    pushEvent(
                        eventID: "work_finished",
                        botIDs: [next[idx].id],
                        zone: next[idx].zoneID,
                        speech: "work_finished",
                        duration: 10,
                        banner: VillageCopy.speech("work_finished"),
                        now: .now
                    )
                    next[idx].pcJobRunning = false
                    next[idx].pcLiveLabel = nil
                case .failed:
                    next[idx].needs.fulfillment = max(0, next[idx].needs.fulfillment - 0.05)
                    next[idx].needs.clamp()
                    say(&next[idx], "stuck_on_task", now: .now)
                    pushEvent(
                        eventID: "stuck_on_task",
                        botIDs: [next[idx].id],
                        zone: next[idx].zoneID,
                        speech: "stuck_on_task",
                        duration: 12,
                        banner: VillageCopy.speech("stuck_on_task"),
                        now: .now
                    )
                    next[idx].pcJobRunning = false
                    next[idx].pcLiveLabel = nil
                case .queued, .running:
                    break
                }
            }
        } else {
            // First sync: register old quests without bonus/events.
            for quest in quests { completedQuestIDs.insert(quest.id) }
            firstHubSyncDone = true
        }

        bots = next
        lastDecision = .distantPast // re-evaluate immediately on hub change
    }

    private func applyAgent(_ bots: inout [VillageLifeBot], agent: V2Hub.Agent) {
        let zoneFromRoom = VillageZoneID.fromHubRoom(agent.room_id)
        let running = agent.recent_quests.first(where: { $0.state == .running })
        let queued = agent.recent_quests.contains(where: { $0.state == .queued })
        let jobZone = running.flatMap { VillageZoneID.fromQuestTitle($0.title) } ?? zoneFromRoom

        if let idx = bots.firstIndex(where: {
            $0.linkedAgentID == agent.id ||
            $0.id.localizedCaseInsensitiveCompare(agent.id) == .orderedSame ||
            $0.displayName.localizedCaseInsensitiveCompare(agent.name) == .orderedSame
        }) {
            bots[idx].linkedAgentID = agent.id
            bots[idx].displayName = agent.name
            switch agent.status {
            case .working:
                bots[idx].pcJobQueued = false
                bots[idx].pcJobRunning = true
                bots[idx].pcLiveLabel = running?.title ?? "Arbejder på PC’en"
                if bots[idx].activity == .sleep || bots[idx].activity == .talk {
                    // PC job wins — interrupt
                }
                if bots[idx].zoneID != jobZone {
                    beginWalk(&bots[idx], to: jobZone, now: .now, reduceMotion: false)
                } else {
                    bots[idx].activity = .work
                    bots[idx].pose = .work
                    say(&bots[idx], "work_started", now: .now)
                }
            case .thinking:
                if running != nil {
                    bots[idx].pcJobRunning = true
                    bots[idx].pcLiveLabel = "Tænker"
                    bots[idx].activity = .work
                    bots[idx].pose = .work
                } else {
                    bots[idx].pcJobQueued = queued || true
                    bots[idx].pcLiveLabel = "Tænker"
                }
            case .ready:
                if bots[idx].pcJobRunning {
                    bots[idx].pcJobRunning = false
                    bots[idx].pcLiveLabel = nil
                    if bots[idx].activity == .work && !bots[idx].localPractice {
                        bots[idx].activity = .idle
                        bots[idx].pose = .idle
                    }
                }
                bots[idx].pcJobQueued = queued
            case .offline:
                bots[idx].pcJobRunning = false
                bots[idx].pcJobQueued = false
                bots[idx].pcLiveLabel = nil
            }
            if queued && agent.status != .working {
                bots[idx].pcJobQueued = true
            }
        } else if bots.count < 10 {
            bots.append(
                VillageLifeBot(
                    id: agent.id, displayName: agent.name, archetype: .logic, spriteID: "adam",
                    zoneID: jobZone, activity: agent.status == .working ? .work : .idle,
                    pose: agent.status == .working ? .work : .idle,
                    needs: .balanced, destinationZoneID: nil, pathProgress: 0,
                    speechHint: nil, carrying: nil, lastEventID: nil,
                    customSprite: nil, linkedAgentID: agent.id, updatedAt: .now,
                    pcJobRunning: agent.status == .working,
                    pcJobQueued: queued,
                    pcLiveLabel: agent.status == .working ? (running?.title ?? "Arbejder på PC’en") : nil,
                    arrivedAt: .now
                )
            )
        }
    }

    // MARK: - Tick

    func tick(now: Date = Date(), hour: Int? = nil, reduceMotion: Bool) {
        guard !paused else {
            banner = VillageCopy.paused
            return
        }
        let minGap = reduceMotion ? 1.8 : 0.9
        guard now.timeIntervalSince(lastTickAt) >= minGap else { return }
        let dt = now.timeIntervalSince(lastTickAt == .distantPast ? now.addingTimeInterval(-minGap) : lastTickAt)
        lastTickAt = now
        let activeDt = min(2.5, max(minGap * 0.9, dt))

        advanceClock(activeDelta: activeDt)
        let clockHour = hour ?? calendar.component(.hour, from: virtualClock)

        // Offline ↔ online transitions are applied by AgentHub onChange / applyHubAgents,
        // not from a captured flag inside the long-running tick task.

        driftNeeds(activeDt: activeDt, clockHour: clockHour)
        advanceWalks(now: now, reduceMotion: reduceMotion, clockHour: clockHour)
        advanceCafe(now: now)
        advanceRest(now: now)
        advancePractice(now: now)
        advanceSleep(now: now, clockHour: clockHour)
        expireSpeech(now: now)
        pruneEvents(now: now)
        maybeDayNightHints(now: now)

        if now.timeIntervalSince(lastDecision) >= (reduceMotion ? decisionEvery * 1.25 : decisionEvery) {
            lastDecision = now
            decideAll(now: now, clockHour: clockHour, reduceMotion: reduceMotion)
        }

        objectWillChange.send()
    }

    private func advanceClock(activeDelta: TimeInterval) {
        if isDemoClock {
            // 1 active second = 2 virtual minutes
            virtualClock = virtualClock.addingTimeInterval(activeDelta * 120)
        } else {
            virtualClock = virtualClock.addingTimeInterval(activeDelta)
        }
    }

    // MARK: - Needs (Del B rates)

    private func driftNeeds(activeDt: TimeInterval, clockHour: Int) {
        let hours = activeDt / 3600.0 * (isDemoClock ? 120 : 1)
        // In demo, activeDt seconds → activeDt*120 virtual seconds → hours = activeDt*120/3600 = activeDt/30
        let virtualHours = isDemoClock ? (activeDt * 120) / 3600.0 : activeDt / 3600.0
        let baseEnergy = energyRate(hour: clockHour)

        for i in bots.indices {
            if bots[i].activity == .sleep { continue }

            var e = baseEnergy * virtualHours
            var s = 0.0
            var f = 0.0

            if bots[i].activity == .work && bots[i].pcJobRunning {
                // waiting in PC queue gives no job bonus; running is visual — base rates still apply
            } else if bots[i].activity == .talk {
                // cafe session bonuses applied on completion
            }

            // Social idle decay in pause windows
            if isPauseWindow(clockHour) {
                s -= 0.01 * virtualHours
            }
            // Fulfillment decays outside work window
            if !isWorkWindow(clockHour) {
                f -= 0.02 * virtualHours
            }

            bots[i].needs.energy += e
            bots[i].needs.social += s
            bots[i].needs.fulfillment += f
            bots[i].needs.clamp()

            if bots[i].needs.energy < 0.30, bots[i].speechHint == nil {
                say(&bots[i], "needs_break", now: .now)
            }
        }
        _ = hours
    }

    private func energyRate(hour: Int) -> Double {
        // per virtual hour
        if hour >= 22 || hour < 7 { return 0.04 }
        if hour == 7 || hour == 12 { return -0.01 }
        if (8...11).contains(hour) || (13...17).contains(hour) { return -0.04 }
        return 0.02 // 18–21
    }

    private func isWorkWindow(_ hour: Int) -> Bool {
        (8...11).contains(hour) || (13...17).contains(hour)
    }

    private func isPauseWindow(_ hour: Int) -> Bool {
        hour == 7 || hour == 12 || (18...21).contains(hour)
    }

    private func isSleepWindow(_ hour: Int) -> Bool {
        hour >= 22 || hour < 7
    }

    // MARK: - Decision table (§4)

    private func decideAll(now: Date, clockHour: Int, reduceMotion: Bool) {
        tryReserveCafe(now: now, clockHour: clockHour, reduceMotion: reduceMotion)

        // Stable id order
        let order = bots.indices.sorted { bots[$0].id < bots[$1].id }
        for i in order {
            decide(index: i, now: now, clockHour: clockHour, reduceMotion: reduceMotion)
        }
    }

    private func decide(index i: Int, now: Date, clockHour: Int, reduceMotion: Bool) {
        if bots[i].destinationZoneID != nil { return }
        if bots[i].activity == .talk { return }
        if restEndsAt[bots[i].id] != nil { return }
        if practiceEndsAt[bots[i].id] != nil { return }

        let target = chooseZone(for: bots[i], night: isSleepWindow(clockHour), others: bots, clockHour: clockHour, now: now)
        applyDecision(index: i, target: target, now: now, clockHour: clockHour, reduceMotion: reduceMotion)
    }

    /// Public for contract tests — Del B priority table condensed.
    func chooseZone(for bot: VillageLifeBot, night: Bool, others: [VillageLifeBot]) -> VillageZoneID {
        chooseZone(for: bot, night: night, others: others, clockHour: night ? 23 : 10, now: .now)
    }

    func chooseZone(
        for bot: VillageLifeBot,
        night: Bool,
        others: [VillageLifeBot],
        clockHour: Int,
        now: Date
    ) -> VillageZoneID {
        // 1. Confirmed PC job → job / work zone (applyAgent sets walk target)
        if bot.pcJobRunning {
            return bot.destinationZoneID ?? bot.archetype.workZone
        }

        // 3. Sleep window / crisis / unfinished sleep
        if bot.activity == .sleep && bot.sleepSessionStarted != nil {
            return .sleep
        }
        if bot.needs.energy <= 0.22 { return .sleep }
        if night && bot.needs.energy < 0.80 { return .sleep }

        // 5. Soft rest
        if bot.needs.energy <= 0.36 || (isPauseWindow(clockHour) && bot.needs.energy < 0.65) {
            if bot.zoneID == .cafe || bot.zoneID == .sleep { return bot.zoneID }
            return bot.needs.social < 0.5 ? .cafe : .sleep
        }

        // 6. Cafe social
        if bot.needs.social <= 0.40 {
            return .cafe
        }
        if others.contains(where: {
            $0.id != bot.id && ($0.destinationZoneID == .cafe || $0.cafePartnerID == bot.id)
        }), bot.needs.social <= 0.60, bot.needs.energy > 0.36 {
            return .cafe
        }

        // 7. Queued PC — stay / go work zone idle
        if bot.pcJobQueued {
            return bot.zoneID == bot.archetype.workZone ? bot.zoneID : bot.archetype.workZone
        }

        // 8. Practice / work window
        if isWorkWindow(clockHour) || bot.needs.fulfillment <= 0.50 {
            return bot.archetype.workZone
        }

        // 9. Idle
        return bot.zoneID
    }

    private func applyDecision(index i: Int, target: VillageZoneID, now: Date, clockHour: Int, reduceMotion: Bool) {
        // PC running already handled in applyAgent for walks
        if bots[i].pcJobRunning {
            let dest = bots[i].archetype.workZone
            if bots[i].zoneID != dest {
                beginWalk(&bots[i], to: dest, now: now, reduceMotion: reduceMotion)
            } else {
                bots[i].activity = .work
                bots[i].pose = .work
            }
            return
        }

        if bots[i].activity == .sleep {
            maybeWake(index: i, now: now, clockHour: clockHour)
            return
        }

        if target == bots[i].zoneID {
            // Same zone — pick local activity
            if target == .sleep && (bots[i].needs.energy <= 0.22 || isSleepWindow(clockHour)) {
                startSleep(index: i, now: now)
            } else if target == .cafe && bots[i].cafePartnerID != nil {
                // wait for partner / talk started elsewhere
                bots[i].activity = .idle
                bots[i].pose = .idle
            } else if (bots[i].needs.energy <= 0.36 || (isPauseWindow(clockHour) && bots[i].needs.energy < 0.65)),
                      target == .cafe || target == .sleep {
                startRest(index: i, now: now)
            } else if (isWorkWindow(clockHour) || bots[i].needs.fulfillment <= 0.50),
                      (target == .research || target == .video),
                      now >= bots[i].practiceBonusReadyAt {
                startPractice(index: i, now: now)
            } else if bots[i].pcJobQueued {
                bots[i].activity = .idle
                bots[i].pose = .idle
            } else {
                bots[i].activity = .idle
                bots[i].pose = .idle
            }
            return
        }

        guard canLeave(bots[i], now: now) || bots[i].needs.energy <= 0.22 || bots[i].pcJobRunning else { return }
        beginWalk(&bots[i], to: target, now: now, reduceMotion: reduceMotion)
    }

    private func canLeave(_ bot: VillageLifeBot, now: Date) -> Bool {
        guard let arrived = bot.arrivedAt else { return true }
        return now.timeIntervalSince(arrived) >= minStaySeconds
    }

    // MARK: - Walk / arrive

    private func beginWalk(_ bot: inout VillageLifeBot, to dest: VillageZoneID, now: Date, reduceMotion: Bool) {
        if bot.zoneID == dest {
            bot.destinationZoneID = nil
            bot.pathProgress = 0
            return
        }
        bot.destinationZoneID = dest
        bot.pathProgress = 0
        bot.activity = .walk
        bot.pose = .walk
        bot.localPractice = false
        walkStartedAt[bot.id] = now
        if reduceMotion {
            bot.zoneID = dest
            bot.destinationZoneID = nil
            bot.pathProgress = 0
            bot.arrivedAt = now
            arriveActivity(&bot, now: now)
        }
    }

    private func advanceWalks(now: Date, reduceMotion: Bool, clockHour: Int) {
        for i in bots.indices {
            guard let dest = bots[i].destinationZoneID else { continue }
            if reduceMotion {
                bots[i].zoneID = dest
                bots[i].destinationZoneID = nil
                bots[i].pathProgress = 0
                bots[i].arrivedAt = now
                arriveActivity(&bots[i], now: now)
                continue
            }
            let start = walkStartedAt[bots[i].id] ?? now
            let p = min(1, now.timeIntervalSince(start) / walkSeconds)
            bots[i].pathProgress = p
            bots[i].activity = .walk
            bots[i].pose = .walk
            if p >= 1 {
                bots[i].zoneID = dest
                bots[i].destinationZoneID = nil
                bots[i].pathProgress = 0
                bots[i].arrivedAt = now
                walkStartedAt[bots[i].id] = nil
                arriveActivity(&bots[i], now: now)
            }
        }
        _ = clockHour
    }

    private func arriveActivity(_ bot: inout VillageLifeBot, now: Date) {
        if bot.pcJobRunning {
            bot.activity = .work
            bot.pose = .work
            say(&bot, "work_started", now: now)
            return
        }
        switch bot.zoneID {
        case .sleep:
            startSleep(bot: &bot, now: now)
        case .cafe:
            bot.activity = .idle
            bot.pose = .idle
        case .research, .video:
            bot.activity = .idle
            bot.pose = .idle
        }
    }

    // MARK: - Cafe

    private func tryReserveCafe(now: Date, clockHour: Int, reduceMotion: Bool) {
        guard now >= cafePairCooldownUntil else { return }
        let needy = bots.indices.filter {
            bots[$0].needs.social <= 0.40
                && bots[$0].needs.energy > 0.36
                && !bots[$0].pcJobRunning
                && bots[$0].activity != .sleep
                && bots[$0].cafePartnerID == nil
                && now >= bots[$0].cafeCooldownUntil
        }.sorted { bots[$0].id < bots[$1].id }
        guard let a = needy.first else { return }

        let partners = bots.indices.filter {
            $0 != a
                && bots[$0].needs.social <= 0.60
                && bots[$0].needs.energy > 0.36
                && !bots[$0].pcJobRunning
                && bots[$0].activity != .sleep
                && bots[$0].cafePartnerID == nil
                && now >= bots[$0].cafeCooldownUntil
                && bots[$0].activity != .talk
        }.sorted { bots[$0].id < bots[$1].id }
        guard let b = partners.first else { return }

        bots[a].cafePartnerID = bots[b].id
        bots[b].cafePartnerID = bots[a].id

        if bots[a].zoneID != .cafe {
            if canLeave(bots[a], now: now) || bots[a].needs.social <= 0.40 {
                beginWalk(&bots[a], to: .cafe, now: now, reduceMotion: reduceMotion)
            }
        }
        if bots[b].zoneID != .cafe {
            if canLeave(bots[b], now: now) {
                beginWalk(&bots[b], to: .cafe, now: now, reduceMotion: reduceMotion)
            }
        }

        // If both already at cafe, start talk
        if bots[a].zoneID == .cafe && bots[b].zoneID == .cafe
            && bots[a].destinationZoneID == nil && bots[b].destinationZoneID == nil {
            startCafeTalk(a: a, b: b, now: now)
        }
        _ = clockHour
    }

    private func startCafeTalk(a: Int, b: Int, now: Date) {
        bots[a].activity = .talk
        bots[a].pose = .talk
        bots[b].activity = .talk
        bots[b].pose = .talk
        cafeEndsAt[bots[a].id] = now.addingTimeInterval(cafeSeconds)
        cafeEndsAt[bots[b].id] = now.addingTimeInterval(cafeSeconds)
        say(&bots[a], "cafe_chat", now: now)
        say(&bots[b], "cafe_chat", now: now)
        let ids = [bots[a].id, bots[b].id]
        pushEvent(
            eventID: "cafe_chat",
            botIDs: ids,
            zone: .cafe,
            speech: "cafe_chat",
            duration: cafeSeconds,
            banner: VillageCopy.speech("cafe_chat"),
            now: now
        )

        // Demo file once after first cafe
        if !demoFileShown {
            demoFileShown = true
            let item = VillageCarryItem(
                kind: "file_share",
                labelKey: "demo_file",
                fromBotID: bots[a].id,
                toBotID: bots[b].id
            )
            bots[a].carrying = item
            pushEvent(
                eventID: "file_handoff",
                botIDs: [bots[a].id, bots[b].id],
                zone: .cafe,
                speech: "demo_file",
                duration: 10,
                banner: VillageCopy.speech("demo_file"),
                now: now
            )
            say(&bots[a], "demo_file", now: now)
        }
    }

    private func advanceCafe(now: Date) {
        // Start talk when reserved partners both arrive
        let reserved = bots.indices.filter { bots[$0].cafePartnerID != nil && bots[$0].activity != .talk }
        for i in reserved {
            guard let partnerID = bots[i].cafePartnerID,
                  let j = bots.firstIndex(where: { $0.id == partnerID }),
                  bots[i].zoneID == .cafe, bots[j].zoneID == .cafe,
                  bots[i].destinationZoneID == nil, bots[j].destinationZoneID == nil,
                  bots[j].activity != .talk
            else { continue }
            // Only initiate once from lower id
            if bots[i].id < bots[j].id {
                startCafeTalk(a: i, b: j, now: now)
            }
        }

        for i in bots.indices where bots[i].activity == .talk {
            guard let end = cafeEndsAt[bots[i].id], now >= end else { continue }
            bots[i].needs.social = min(1, bots[i].needs.social + 0.03)
            bots[i].needs.clamp()
            bots[i].activity = .idle
            bots[i].pose = .idle
            bots[i].cafePartnerID = nil
            bots[i].cafeCooldownUntil = now.addingTimeInterval(60)
            bots[i].arrivedAt = now
            cafeEndsAt[bots[i].id] = nil
            if let carry = bots[i].carrying, carry.labelKey == "demo_file" {
                bots[i].carrying = nil
            }
        }
        // Pair cooldown 120s after a completed meetup
        if cafeEndsAt.isEmpty == false { return }
        // set when any talk just finished — approximate via bots with recent cooldown
        if bots.contains(where: { now.timeIntervalSince($0.cafeCooldownUntil.addingTimeInterval(-60)) < 1 }) {
            cafePairCooldownUntil = now.addingTimeInterval(120)
        }
    }

    // MARK: - Rest / practice / sleep

    private func startRest(index i: Int, now: Date) {
        guard now >= bots[i].restBonusReadyAt else {
            bots[i].activity = .rest
            bots[i].pose = .rest
            return
        }
        bots[i].activity = .rest
        bots[i].pose = .rest
        restEndsAt[bots[i].id] = now.addingTimeInterval(restSessionSeconds)
        say(&bots[i], "needs_break", now: now)
    }

    private func advanceRest(now: Date) {
        for i in bots.indices {
            guard let end = restEndsAt[bots[i].id], now >= end else { continue }
            bots[i].needs.energy = min(1, bots[i].needs.energy + 0.08)
            bots[i].needs.clamp()
            bots[i].restBonusReadyAt = now.addingTimeInterval(120)
            bots[i].activity = .idle
            bots[i].pose = .idle
            bots[i].arrivedAt = now
            restEndsAt[bots[i].id] = nil
            say(&bots[i], "rested", now: now)
            pushEvent(
                eventID: "rested",
                botIDs: [bots[i].id],
                zone: bots[i].zoneID,
                speech: "rested",
                duration: 6,
                banner: nil,
                now: now
            )
        }
    }

    private func startPractice(index i: Int, now: Date) {
        bots[i].activity = .work
        bots[i].pose = .work
        bots[i].localPractice = true
        practiceEndsAt[bots[i].id] = now.addingTimeInterval(practiceSessionSeconds)
    }

    private func advancePractice(now: Date) {
        for i in bots.indices {
            guard let end = practiceEndsAt[bots[i].id], now >= end else { continue }
            bots[i].needs.fulfillment = min(1, bots[i].needs.fulfillment + 0.04)
            bots[i].needs.clamp()
            bots[i].practiceBonusReadyAt = now.addingTimeInterval(120)
            bots[i].localPractice = false
            bots[i].activity = .idle
            bots[i].pose = .idle
            bots[i].arrivedAt = now
            practiceEndsAt[bots[i].id] = nil
            say(&bots[i], "inspired", now: now)
            pushEvent(
                eventID: "inspired",
                botIDs: [bots[i].id],
                zone: bots[i].zoneID,
                speech: "inspired",
                duration: 8,
                banner: nil,
                now: now
            )
        }
    }

    private func startSleep(index i: Int, now: Date) {
        startSleep(bot: &bots[i], now: now)
    }

    private func startSleep(bot: inout VillageLifeBot, now: Date) {
        if bot.zoneID != .sleep {
            beginWalk(&bot, to: .sleep, now: now, reduceMotion: false)
            return
        }
        bot.activity = .sleep
        bot.pose = .sleep
        bot.localPractice = false
        if bot.sleepSessionStarted == nil {
            bot.sleepSessionStarted = now
            say(&bot, "sleep_started", now: now)
            pushEvent(
                eventID: "sleep_started",
                botIDs: [bot.id],
                zone: .sleep,
                speech: "sleep_started",
                duration: 6,
                banner: nil,
                now: now
            )
        }
    }

    private func advanceSleep(now: Date, clockHour: Int) {
        for i in bots.indices where bots[i].activity == .sleep {
            // Soft energy gain during sleep (+0.04 / virtual hour in sleep window baseline already;
            // session stay uses +0.04/hour for occupancy — apply mild real-time top-up)
            let virtualHours = isDemoClock ? (1.0 * 120) / 3600.0 : 1.0 / 3600.0
            bots[i].needs.energy = min(1, bots[i].needs.energy + 0.04 * virtualHours)
            bots[i].needs.clamp()
        }
        _ = (now, clockHour)
    }

    private func maybeWake(index i: Int, now: Date, clockHour: Int) {
        guard let started = bots[i].sleepSessionStarted else { return }
        let slept = now.timeIntervalSince(started)
        guard slept >= sleepMinSeconds else { return }

        // One-shot +0.12 bonus
        if now >= bots[i].sleepBonusReadyAt, slept >= sleepMinSeconds {
            bots[i].needs.energy = min(1, bots[i].needs.energy + 0.12)
            bots[i].needs.clamp()
            bots[i].sleepBonusReadyAt = now.addingTimeInterval(120)
        }

        let energy = bots[i].needs.energy
        let wake: Bool
        if isSleepWindow(clockHour) {
            wake = energy >= 0.80
        } else {
            wake = energy >= 0.34
        }
        if wake {
            bots[i].activity = .idle
            bots[i].pose = .idle
            bots[i].sleepSessionStarted = nil
            bots[i].arrivedAt = now
            say(&bots[i], "awake", now: now)
            pushEvent(
                eventID: "awake",
                botIDs: [bots[i].id],
                zone: .sleep,
                speech: "awake",
                duration: 6,
                banner: nil,
                now: now
            )
        }
    }

    // MARK: - Speech / events / day-night

    private func say(_ bot: inout VillageLifeBot, _ key: String, now: Date) {
        bot.speechHint = key
        speechClearAt[bot.id] = now.addingTimeInterval(4)
    }

    private func expireSpeech(now: Date) {
        for i in bots.indices {
            if let until = speechClearAt[bots[i].id], now >= until {
                bots[i].speechHint = nil
                speechClearAt[bots[i].id] = nil
            }
            // Clear carry after 10s max
            if bots[i].carrying != nil {
                // handled via event duration / cafe end; safety clear via events
            }
        }
        for event in activeEvents where event.eventID == "file_handoff" {
            if now.timeIntervalSince(event.startedAt) >= 10 {
                for i in bots.indices where event.botIDs.contains(bots[i].id) {
                    bots[i].carrying = nil
                }
            }
        }
    }

    private func pushEvent(
        eventID: String,
        botIDs: [String],
        zone: VillageZoneID?,
        speech: String?,
        duration: Double,
        banner: String?,
        now: Date
    ) {
        let occurrence = VillageEventOccurrence(
            id: "\(eventID)-\(Int(now.timeIntervalSince1970))-\(botIDs.joined(separator: "-"))",
            eventID: eventID,
            botIDs: botIDs,
            zoneID: zone,
            speechHint: speech,
            startedAt: now,
            durationSeconds: duration,
            bannerText: banner
        )
        activeEvents.append(occurrence)
        if let banner { self.banner = banner }
        for i in bots.indices where botIDs.contains(bots[i].id) {
            bots[i].lastEventID = occurrence.id
        }
    }

    private func pruneEvents(now: Date) {
        activeEvents.removeAll { now.timeIntervalSince($0.startedAt) > $0.durationSeconds }
        if activeEvents.isEmpty { banner = nil }
    }

    private func maybeDayNightHints(now: Date) {
        let hour = calendar.component(.hour, from: virtualClock)
        let day = calendar.ordinality(of: .day, in: .year, for: virtualClock) ?? 0
        if hour >= 7 && hour < 22 {
            if morningFiredForDay != day {
                morningFiredForDay = day
                banner = VillageCopy.speech("morning_startup")
                pushEvent(
                    eventID: "morning_startup",
                    botIDs: bots.map(\.id),
                    zone: nil,
                    speech: "morning_startup",
                    duration: 8,
                    banner: banner,
                    now: now
                )
            }
        }
        if hour >= 22 || hour < 7 {
            if nightFiredForDay != day {
                nightFiredForDay = day
                banner = VillageCopy.speech("night_wind_down")
                pushEvent(
                    eventID: "night_wind_down",
                    botIDs: bots.map(\.id),
                    zone: nil,
                    speech: "night_wind_down",
                    duration: 8,
                    banner: banner,
                    now: now
                )
            }
        }
        lastDayBucket = day
    }

    // MARK: - Geometry

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
        // Via plaza (center) when crossing
        let mid = CGPoint(x: size.width * 0.5, y: size.height * 0.5)
        if t < 0.5 {
            let u = t * 2
            return CGPoint(
                x: from.x + (mid.x - from.x) * u,
                y: from.y + 36 + (mid.y - (from.y + 36)) * u
            )
        } else {
            let u = (t - 0.5) * 2
            return CGPoint(
                x: mid.x + (to.x - mid.x) * u,
                y: mid.y + (to.y + 36 - mid.y) * u
            )
        }
    }
}
