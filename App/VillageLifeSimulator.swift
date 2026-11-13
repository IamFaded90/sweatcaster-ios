import Foundation
import Combine

/// Del B Universim life loop — docs/UNIVERSIM-LIFE-DESIGN.md
@MainActor
final class VillageLifeSimulator: ObservableObject {
    @Published private(set) var bots: [VillageLifeBot] = []
    @Published private(set) var virtualClock: Date
    @Published private(set) var activeEvents: [VillageEventOccurrence] = []
    @Published private(set) var banner: String?
    @Published private(set) var paused = false
    @Published var filmMode = true

    private(set) var isDemoClock: Bool

    var decisionEvery: TimeInterval = 8
    var walkSeconds: TimeInterval = 4
    var minStaySeconds: TimeInterval = 24
    var cafeSeconds: TimeInterval = 16
    var restSessionSeconds: TimeInterval = 24
    var practiceSessionSeconds: TimeInterval = 24
    var sleepMinSeconds: TimeInterval = 24

    private var lastDecision = Date.distantPast
    private var lastTickAt = Date.distantPast
    private var pausedAt: Date?
    private var visible = true
    private var manuallyPaused = false
    private var observedNeeds: [UUID: VillageNeeds] = [:]
    private var observedChats: Set<UUID> = []
    private var jobHistory: [String: [UUID]] = [:]
    private var sharedCopies: Set<String> = []
    private var bestFriends: [String: String] = [:]
    private var speechClearAt: [String: Date] = [:]
    private var walkStartedAt: [String: Date] = [:]
    private var cafeEndsAt: [String: Date] = [:]
    private var restEndsAt: [String: Date] = [:]
    private var practiceEndsAt: [String: Date] = [:]
    private var cafePairCooldowns: [Set<String>: Date] = [:]
    private var cafeReservations: [Set<String>: Date] = [:]
    private var demoFileShown = false
    private var lastWasOffline = false
    private var morningFiredForDay: Int?
    private var nightFiredForEveningDay: Int?
    private var settledQuestIDs: Set<String> = []
    private var firstHubSyncDone = false
    private let calendar: Calendar

    func setPaused(_ value: Bool, at now: Date = .now) {
        manuallyPaused = value
        updatePause(at: now)
    }

    func setActive(_ value: Bool, at now: Date = .now) {
        visible = value
        updatePause(at: now)
    }

    private func updatePause(at now: Date) {
        let value = manuallyPaused || !visible
        if value {
            guard !paused else { return }
            pausedAt = now
            paused = true
            if manuallyPaused { banner = VillageCopy.paused }
            return
        }
        guard paused else { return }
        if let pausedAt {
            let delta = now.timeIntervalSince(pausedAt)
            shiftActiveTimers(by: delta)
        }
        self.pausedAt = nil
        paused = false
        lastTickAt = now
        if banner == VillageCopy.paused { banner = nil }
    }

    /// Wall clock for stamping while paused: freeze at pause start so resume-shift is correct.
    private func stampNow(_ now: Date = .now) -> Date {
        if paused, let pausedAt { return pausedAt }
        return now
    }

    private func shiftActiveTimers(by delta: TimeInterval) {
        guard delta > 0 else { return }
        func shift(_ date: Date) -> Date {
            date == .distantPast ? date : date.addingTimeInterval(delta)
        }
        func shiftOpt(_ date: Date?) -> Date? { date.map(shift) }

        lastDecision = shift(lastDecision)
        cafePairCooldowns = cafePairCooldowns.mapValues(shift)
        cafeReservations = cafeReservations.mapValues(shift)
        for key in walkStartedAt.keys { walkStartedAt[key] = shift(walkStartedAt[key]!) }
        for key in cafeEndsAt.keys { cafeEndsAt[key] = shift(cafeEndsAt[key]!) }
        for key in restEndsAt.keys { restEndsAt[key] = shift(restEndsAt[key]!) }
        for key in practiceEndsAt.keys { practiceEndsAt[key] = shift(practiceEndsAt[key]!) }
        for key in speechClearAt.keys { speechClearAt[key] = shift(speechClearAt[key]!) }
        for i in bots.indices {
            bots[i].arrivedAt = shiftOpt(bots[i].arrivedAt)
            bots[i].sleepSessionStarted = shiftOpt(bots[i].sleepSessionStarted)
            bots[i].restBonusReadyAt = shift(bots[i].restBonusReadyAt)
            bots[i].practiceBonusReadyAt = shift(bots[i].practiceBonusReadyAt)
            bots[i].sleepBonusReadyAt = shift(bots[i].sleepBonusReadyAt)
            bots[i].cafeCooldownUntil = shift(bots[i].cafeCooldownUntil)
        }
        for i in activeEvents.indices {
            activeEvents[i].startedAt = shift(activeEvents[i].startedAt)
        }
    }

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
        cafePairCooldowns = [:]
        cafeReservations = [:]
        restEndsAt = [:]
        practiceEndsAt = [:]
        speechClearAt = [:]
        settledQuestIDs = []
        firstHubSyncDone = false
        morningFiredForDay = nil
        nightFiredForEveningDay = nil
    }

    /// Test helper — updates one bot without exposing a public setter on `bots`.
    func replaceBotForTesting(_ bot: VillageLifeBot) {
        guard let i = bots.firstIndex(where: { $0.id == bot.id }) else { return }
        bots[i] = bot
    }

    // MARK: - Profiles / hub

    func mergeLocalProfiles(_ profiles: [VillageBot], keepDemoFounders: Bool = true) {
        if !keepDemoFounders {
            let now = stampNow()
            let previous = Dictionary(bots.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            var seen = Set<UUID>()
            var next: [VillageLifeBot] = []
            for profile in profiles where next.count < 10 && seen.insert(profile.id).inserted {
                let id = profile.id.uuidString
                let role = VillageArchetype.from(personality: profile.personality, color: profile.color, name: profile.name)
                let sprite = role == .creative || role == .playful ? "eva" : "adam"
                let name = profile.name.isEmpty ? "Bot" : profile.name
                let demoNeeds = Self.seedAdamEva(now: now).first(where: { $0.spriteID == sprite })?.needs ?? .balanced
                var bot = previous[id] ?? VillageLifeBot(
                    id: id, displayName: name, archetype: role, spriteID: sprite,
                    zoneID: role.workZone, activity: .idle, pose: .idle,
                    needs: isDemoClock ? demoNeeds : .balanced, destinationZoneID: nil, pathProgress: 0,
                    speechHint: nil, carrying: nil, lastEventID: nil,
                    customSprite: profile.sprite, linkedAgentID: nil, updatedAt: now, arrivedAt: now
                )
                bot.displayName = name
                bot.archetype = role
                bot.spriteID = sprite
                bot.customSprite = profile.sprite
                next.append(bot)
            }
            if next != bots { bots = next }
            bestFriends = profiles.reduce(into: [:]) { result, profile in
                result[profile.id.uuidString] = profile.bestFriendID?.uuidString
            }
            observedNeeds = observedNeeds.filter { seen.contains($0.key) }
            return
        }
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

    /// Drop confirmed PC job markers without treating it as a disconnect (e.g. PC switch / hub glitch).
    /// When `resetOfflineState` is true, also clear `lastWasOffline` so the next online apply
    /// does not emit `pc_reconnected` (use on PC switch after a prior offline).
    func clearPCJobMarkers(resetOfflineState: Bool = false) {
        for i in bots.indices {
            bots[i].pcJobRunning = false
            bots[i].pcJobQueued = false
            bots[i].pcJobZone = nil
            bots[i].pcLiveLabel = nil
            bots[i].workStartedAnnounced = false
        }
        if resetOfflineState {
            lastWasOffline = false
        }
    }

    func resetPCProjection() {
        clearPCJobMarkers(resetOfflineState: true)
        activeEvents.removeAll { $0.eventID == "offline_rest" || $0.eventID == "pc_reconnected" }
        if banner == VillageCopy.speech("offline_rest") || banner == VillageCopy.speech("pc_reconnected") {
            banner = nil
        }
    }

    func setDemoClock(_ enabled: Bool, at now: Date = .now) {
        guard isDemoClock != enabled else { return }
        isDemoClock = enabled
        if !enabled { virtualClock = now }
    }

    func setPCOffline(_ offline: Bool) {
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
                    now: stampNow()
                )
            }
            lastWasOffline = true
            clearPCJobMarkers()
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
                now: stampNow()
            )
        }
        lastWasOffline = false
    }

    func updateRoundSix(states: [UUID: BotSimulationState], activeJobs: [UUID: BotComputerJob.State],
                        chatting: Set<UUID>, reduceMotion: Bool) {
        guard !paused else { return }
        let now = stampNow()
        var next = bots
        for i in next.indices {
            guard let id = UUID(uuidString: next[i].id) else { continue }
            if let state = states[id] {
                let needs = VillageNeeds(energy: state.energy / 100, social: state.social / 100,
                                         fulfillment: state.workJoy / 100, mood: 0)
                let previous = observedNeeds.updateValue(needs, forKey: id)
                if let previous, needs != previous {
                    // Round 6 tracks persistent needs. Scene rates are applied below; only
                    // event-sized deltas cross into the scene to avoid applying time twice.
                    let social = needs.social - previous.social
                    let fulfillment = needs.fulfillment - previous.fulfillment
                    if social > 0 { next[i].needs.social += social }
                    if abs(fulfillment) >= 0.025 { next[i].needs.fulfillment += fulfillment }
                    next[i].needs.clamp()
                } else if previous == nil && (state.energy != 100 || state.social != 50 || state.workJoy != 50) {
                    next[i].needs = needs
                    next[i].needs.clamp()
                }
            }

            let wasRunning = next[i].pcJobRunning
            next[i].pcJobQueued = activeJobs[id] == .queued
            if activeJobs[id] == .running {
                if !wasRunning {
                    let jobZone = next[i].archetype.workZone
                    engageConfirmedPCJob(botIndex: i, bots: &next, jobZone: jobZone,
                                         label: "Arbejder på PC’en", announceStart: true, reduceMotion: reduceMotion)
                }
                continue
            }
            if wasRunning {
                next[i].pcJobRunning = false
                next[i].pcJobZone = nil
                next[i].pcLiveLabel = nil
                next[i].workStartedAnnounced = false
                cancelWalk(&next[i])
                next[i].activity = .idle
                next[i].pose = .idle
            }
            if chatting.contains(id) {
                if !observedChats.contains(id) || next[i].activity != .talk {
                    interruptLocalSessions(botIndex: i, bots: &next)
                    cancelWalk(&next[i])
                    next[i].activity = .talk
                    next[i].pose = .talk
                }
            } else if observedChats.contains(id), next[i].activity == .talk {
                next[i].activity = .idle
                next[i].pose = .idle
                lastDecision = .distantPast
            }
        }
        observedChats = chatting
        if next != bots { bots = next }
    }

    func observeJobs(_ jobs: [VillageBotJobActivity], botID: UUID, targetID: String) {
        let id = botID.uuidString
        let scope = targetID + ":" + id
        let previous = jobHistory[scope]
        var history = previous ?? []
        var seen = Set(history)
        for job in jobs.reversed() where job.status == .completed || job.status == .failed {
            guard seen.insert(job.id).inserted else { continue }
            history.append(job.id)
            guard previous != nil, let i = bots.firstIndex(where: { $0.id == id }) else { continue }
            let key = job.status == .completed ? "work_finished" : "stuck_on_task"
            let now = stampNow()
            say(&bots[i], key, now: now)
            pushEvent(eventID: key, botIDs: [id], zone: bots[i].zoneID, speech: key,
                      duration: job.status == .completed ? 10 : 12, banner: VillageCopy.speech(key), now: now)
        }
        jobHistory[scope] = Array(history.suffix(160))
    }

    func recordFileShare(source: UUID, recipient: UUID, copyID: UUID, targetID: String) {
        guard source != recipient,
              let sourceIndex = bots.firstIndex(where: { $0.id == source.uuidString }),
              let recipientIndex = bots.firstIndex(where: { $0.id == recipient.uuidString }),
              sharedCopies.insert(targetID + ":" + copyID.uuidString).inserted else { return }
        let now = stampNow()
        let sender = bots[sourceIndex].id
        let receiver = bots[recipientIndex].id
        bots[sourceIndex].carrying = VillageCarryItem(kind: "file_share", labelKey: "shared_file",
                                                     fromBotID: sender, toBotID: receiver)
        say(&bots[sourceIndex], "shared_file", now: now)
        pushEvent(eventID: "file_handoff", botIDs: [sender, receiver], zone: bots[sourceIndex].zoneID,
                  speech: "shared_file", duration: 10, banner: VillageCopy.speech("shared_file"), now: now)
    }

    func applyHubAgents(_ agents: [V2Hub.Agent], offline: Bool) {
        setPCOffline(offline)
        guard !offline else { return }

        var next = bots
        for agent in agents.prefix(10) {
            applyAgent(&next, agent: agent)
        }

        // Quest settlement bonuses once per quest id (only completed/failed count as settled).
        let quests = agents.flatMap(\.recent_quests)
        if firstHubSyncDone {
            for quest in quests {
                switch quest.state {
                case .queued, .running:
                    continue
                case .completed, .failed:
                    guard !settledQuestIDs.contains(quest.id) else { continue }
                    settledQuestIDs.insert(quest.id)
                    guard let owner = agents.first(where: { $0.recent_quests.contains(where: { $0.id == quest.id }) }),
                          let idx = next.firstIndex(where: {
                              $0.linkedAgentID == owner.id
                                  || $0.id == owner.id
                                  || $0.displayName.localizedCaseInsensitiveCompare(owner.name) == .orderedSame
                          })
                    else { continue }
                    if quest.state == .completed {
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
                    } else {
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
                    }
                    next[idx].pcJobRunning = false
                    next[idx].pcLiveLabel = nil
                    next[idx].workStartedAnnounced = false
                }
            }
        } else {
            // First sync: register already-settled quests without bonus/events.
            for quest in quests where quest.state == .completed || quest.state == .failed {
                settledQuestIDs.insert(quest.id)
            }
            firstHubSyncDone = true
        }

        bots = next
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
                engageConfirmedPCJob(
                    botIndex: idx,
                    bots: &bots,
                    jobZone: jobZone,
                    label: running?.title ?? "Arbejder på PC’en",
                    announceStart: true
                )
            case .thinking:
                if running != nil {
                    // Confirmed running quest under thinking → same as PC work, with "Tænker" label.
                    engageConfirmedPCJob(
                        botIndex: idx,
                        bots: &bots,
                        jobZone: jobZone,
                        label: "Tænker",
                        announceStart: false
                    )
                } else {
                    bots[idx].pcJobRunning = false
                    bots[idx].pcJobQueued = queued
                    bots[idx].pcLiveLabel = "Tænker"
                }
            case .ready:
                if bots[idx].pcJobRunning {
                    bots[idx].pcJobRunning = false
                    bots[idx].pcLiveLabel = nil
                    bots[idx].workStartedAnnounced = false
                    if bots[idx].activity == .work && !bots[idx].localPractice {
                        bots[idx].activity = .idle
                        bots[idx].pose = .idle
                    }
                }
                bots[idx].pcJobQueued = queued
                if !queued { bots[idx].pcJobZone = nil }
            case .offline:
                bots[idx].pcJobRunning = false
                bots[idx].pcJobQueued = false
                bots[idx].pcJobZone = nil
                bots[idx].pcLiveLabel = nil
                bots[idx].workStartedAnnounced = false
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
                    pcJobZone: agent.status == .working || queued ? jobZone : nil,
                    pcLiveLabel: agent.status == .working ? (running?.title ?? "Arbejder på PC’en") : nil,
                    arrivedAt: .now,
                    workStartedAnnounced: agent.status == .working
                )
            )
        }
    }

    private func engageConfirmedPCJob(
        botIndex idx: Int,
        bots: inout [VillageLifeBot],
        jobZone: VillageZoneID,
        label: String,
        announceStart: Bool,
        reduceMotion: Bool = false
    ) {
        let now = stampNow()
        interruptLocalSessions(botIndex: idx, bots: &bots)
        bots[idx].pcJobQueued = false
        bots[idx].pcJobRunning = true
        bots[idx].pcJobZone = jobZone
        bots[idx].pcLiveLabel = label
        if bots[idx].zoneID != jobZone {
            if bots[idx].destinationZoneID != jobZone || bots[idx].activity != .walk {
                beginWalk(&bots[idx], to: jobZone, now: now, reduceMotion: reduceMotion)
            }
            // Thinking-labeled PC jobs must not say "work_started" on arrival.
            if !announceStart {
                bots[idx].workStartedAnnounced = true
            }
        } else {
            bots[idx].destinationZoneID = nil
            walkStartedAt[bots[idx].id] = nil
            bots[idx].activity = .work
            bots[idx].pose = .work
            if announceStart, !bots[idx].workStartedAnnounced {
                say(&bots[idx], "work_started", now: now)
                bots[idx].workStartedAnnounced = true
            } else if !announceStart {
                bots[idx].workStartedAnnounced = true
            }
        }
    }

    private func interruptLocalSessions(botIndex idx: Int, bots: inout [VillageLifeBot]) {
        let id = bots[idx].id
        if let partnerID = bots[idx].cafePartnerID,
           let j = bots.firstIndex(where: { $0.id == partnerID }) {
            cafeReservations[Set([id, partnerID])] = nil
            bots[j].cafePartnerID = nil
            cafeEndsAt[bots[j].id] = nil
            if bots[j].destinationZoneID == .cafe || bots[j].activity == .talk {
                cancelWalk(&bots[j])
                bots[j].activity = .idle
                bots[j].pose = .idle
            }
        }
        bots[idx].cafePartnerID = nil
        cafeEndsAt[id] = nil
        restEndsAt[id] = nil
        practiceEndsAt[id] = nil
        bots[idx].localPractice = false
        bots[idx].sleepSessionStarted = nil
        bots[idx].sleepBonusGrantedThisSession = false
        bots[idx].walkIntentRest = false
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
        expireSpeech(now: now)
        pruneEvents(now: now)
        maybeDayNightHints(now: now)

        if now.timeIntervalSince(lastDecision) >= decisionEvery {
            lastDecision = now
            decideAll(now: now, clockHour: clockHour, reduceMotion: reduceMotion)
        }

        for event in activeEvents {
            for i in bots.indices where event.botIDs.contains(bots[i].id) && bots[i].lastEventID != event.id {
                bots[i].lastEventID = event.id
            }
        }
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
        let virtualHours = isDemoClock ? (activeDt * 120) / 3600.0 : activeDt / 3600.0
        let baseEnergy = energyRate(hour: clockHour)

        for i in bots.indices {
            let rate = switch bots[i].activity {
            case .sleep: 0.04
            case .rest: 0.02
            default: baseEnergy
            }
            var s = 0.0
            var f = 0.0

            // Social idle decay in pause windows
            if clockHour == 7 || clockHour == 12 {
                s -= 0.01 * virtualHours
            }
            // Fulfillment decays outside work window
            if !isWorkWindow(clockHour) {
                f -= 0.02 * virtualHours
            }

            bots[i].needs.energy += rate * virtualHours
            bots[i].needs.social += s
            bots[i].needs.fulfillment += f
            bots[i].needs.clamp()

            if bots[i].needs.energy < 0.30, bots[i].speechHint == nil {
                say(&bots[i], "needs_break", now: .now)
            }
        }
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
        // 1. Confirmed PC job → quest/room job zone, else profile work zone
        if bot.pcJobRunning {
            return bot.pcJobZone ?? bot.destinationZoneID ?? bot.archetype.workZone
        }

        // 3. Sleep window / crisis / unfinished sleep
        if bot.activity == .sleep && bot.sleepSessionStarted != nil {
            return .sleep
        }
        if bot.needs.energy <= 0.22 { return .sleep }
        if night && bot.needs.energy < 0.80 { return .sleep }
        if night { return bot.zoneID }

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
        if bots[i].pcJobRunning {
            let dest = bots[i].pcJobZone ?? bots[i].archetype.workZone
            if bots[i].zoneID != dest {
                if bots[i].destinationZoneID != dest || bots[i].activity != .walk {
                    beginWalk(&bots[i], to: dest, now: now, reduceMotion: reduceMotion)
                }
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
            let energy = bots[i].needs.energy
            let sleepWindow = isSleepWindow(clockHour)
            let needsSleep = energy <= 0.22 || (sleepWindow && energy < 0.80)
            if target == .sleep && needsSleep {
                bots[i].walkIntentRest = false
                startSleep(index: i, now: now)
            } else if target == .sleep && sleepWindow {
                bots[i].activity = .rest
                bots[i].pose = .rest
            } else if target == .cafe && bots[i].cafePartnerID != nil {
                bots[i].activity = .idle
                bots[i].pose = .idle
            } else if (bots[i].needs.energy <= 0.36 || (isPauseWindow(clockHour) && bots[i].needs.energy < 0.65)),
                      target == .cafe || target == .sleep {
                startRest(index: i, now: now)
            } else if (isWorkWindow(clockHour) || bots[i].needs.fulfillment <= 0.50),
                      (target == .research || target == .video),
                      now >= bots[i].practiceBonusReadyAt {
                startPractice(index: i, now: now)
            } else {
                bots[i].activity = .idle
                bots[i].pose = .idle
            }
            return
        }

        let socialCrisis = bots[i].needs.social <= 0.40 && target == .cafe
        guard canLeave(bots[i], now: now)
                || bots[i].needs.energy <= 0.22
                || bots[i].pcJobRunning
                || socialCrisis
        else { return }

        let softRestToSleep = target == .sleep
            && bots[i].needs.energy > 0.22
            && !isSleepWindow(clockHour)
        bots[i].walkIntentRest = softRestToSleep
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
        // Idempotent: keep an in-flight walk to the same destination.
        if bot.destinationZoneID == dest, bot.activity == .walk, walkStartedAt[bot.id] != nil {
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

    private func cancelWalk(_ bot: inout VillageLifeBot) {
        walkStartedAt[bot.id] = nil
        bot.destinationZoneID = nil
        bot.pathProgress = 0
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
            bot.walkIntentRest = false
            // Skip when engageConfirmedPCJob(announceStart: false) already marked announced
            // (thinking + running quest), or when speech was already shown at the desk.
            if !bot.workStartedAnnounced {
                say(&bot, "work_started", now: now)
                bot.workStartedAnnounced = true
            }
            return
        }
        switch bot.zoneID {
        case .sleep:
            if bot.walkIntentRest {
                bot.walkIntentRest = false
                startRest(bot: &bot, now: now)
            } else {
                startSleep(bot: &bot, now: now)
            }
        case .cafe:
            bot.walkIntentRest = false
            bot.activity = .idle
            bot.pose = .idle
        case .research, .video:
            bot.walkIntentRest = false
            bot.activity = .idle
            bot.pose = .idle
        }
    }

    // MARK: - Cafe

    private func tryReserveCafe(now: Date, clockHour: Int, reduceMotion: Bool) {
        guard !isSleepWindow(clockHour) else { return }
        let eligible = bots.indices.filter { i in
            let bot = bots[i]
            return bot.needs.energy > 0.36 && bot.needs.social <= 0.60 && !bot.pcJobRunning
                && bot.activity != .sleep && bot.activity != .talk && bot.activity != .rest
                && bot.cafePartnerID == nil && bot.destinationZoneID == nil
                && now >= bot.cafeCooldownUntil && (bot.zoneID == .cafe || canLeave(bot, now: now))
                && (!isPauseWindow(clockHour) || bot.needs.energy >= 0.65)
        }.sorted { bots[$0].id < bots[$1].id }
        for a in eligible where bots[a].cafePartnerID == nil && bots[a].needs.social <= 0.40 {
            let partners = eligible.filter { i in
                guard i != a, bots[i].cafePartnerID == nil else { return false }
                let pair = Set([bots[a].id, bots[i].id])
                return now >= (cafePairCooldowns[pair] ?? .distantPast)
            }
            guard let b = partners.first(where: { bots[$0].id == bestFriends[bots[a].id] }) ?? partners.first else {
                continue
            }
            let aID = bots[a].id
            let bID = bots[b].id
            cafeReservations[Set([aID, bID])] = now.addingTimeInterval(12)
            bots[a].cafePartnerID = bID
            bots[b].cafePartnerID = aID
            for i in [a, b] {
                practiceEndsAt[bots[i].id] = nil
                if bots[i].zoneID != .cafe { beginWalk(&bots[i], to: .cafe, now: now, reduceMotion: reduceMotion) }
            }
            if bots[a].zoneID == .cafe && bots[b].zoneID == .cafe { startCafeTalk(a: a, b: b, now: now) }
        }
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
        cafeReservations[Set(ids)] = nil
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
        if isDemoClock && !demoFileShown {
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
        for pair in cafeReservations.filter({ now >= $0.value }).keys {
            for i in bots.indices where pair.contains(bots[i].id) {
                bots[i].cafePartnerID = nil
                if bots[i].destinationZoneID == .cafe {
                    cancelWalk(&bots[i])
                    bots[i].activity = .idle
                    bots[i].pose = .idle
                }
            }
            cafeReservations[pair] = nil
        }
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
            if let partner = bots[i].cafePartnerID {
                cafePairCooldowns[Set([bots[i].id, partner])] = now.addingTimeInterval(120)
            }
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
    }

    // MARK: - Rest / practice / sleep

    private func startRest(index i: Int, now: Date) {
        startRest(bot: &bots[i], now: now)
    }

    private func startRest(bot: inout VillageLifeBot, now: Date) {
        bot.activity = .rest
        bot.pose = .rest
        bot.walkIntentRest = false
        guard now >= bot.restBonusReadyAt else { return }
        restEndsAt[bot.id] = now.addingTimeInterval(restSessionSeconds)
        say(&bot, "needs_break", now: now)
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
        bot.walkIntentRest = false
        if bot.sleepSessionStarted == nil {
            bot.sleepSessionStarted = now
            bot.sleepBonusGrantedThisSession = false
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

    private func maybeWake(index i: Int, now: Date, clockHour: Int) {
        guard let started = bots[i].sleepSessionStarted else { return }
        let slept = now.timeIntervalSince(started)
        guard slept >= sleepMinSeconds else { return }

        // +0.12 once per sleep session (and respect 120s cooldown between sessions).
        if !bots[i].sleepBonusGrantedThisSession, now >= bots[i].sleepBonusReadyAt {
            bots[i].needs.energy = min(1, bots[i].needs.energy + 0.12)
            bots[i].needs.clamp()
            bots[i].sleepBonusGrantedThisSession = true
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
            bots[i].sleepBonusGrantedThisSession = false
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
        let stamped = stampNow(now)
        bot.speechHint = key
        speechClearAt[bot.id] = stamped.addingTimeInterval(4)
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
        let stamped = stampNow(now)
        let occurrence = VillageEventOccurrence(
            id: "\(eventID)-\(Int(stamped.timeIntervalSince1970))-\(botIDs.joined(separator: "-"))",
            eventID: eventID,
            botIDs: botIDs,
            zoneID: zone,
            speechHint: speech,
            startedAt: stamped,
            durationSeconds: duration,
            bannerText: banner
        )
        activeEvents.append(occurrence)
        if let banner { self.banner = banner }
    }

    private func pruneEvents(now: Date) {
        activeEvents.removeAll { now.timeIntervalSince($0.startedAt) > $0.durationSeconds }
        if activeEvents.isEmpty { banner = nil }
    }

    private func maybeDayNightHints(now: Date) {
        let hour = calendar.component(.hour, from: virtualClock)
        let day = calendar.ordinality(of: .day, in: .year, for: virtualClock) ?? 0
        // Morning: first tick at/after 07:00 once per calendar day.
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
        // Night: first tick at/after 22:00 once per evening day (not again after midnight).
        if hour >= 22 {
            if nightFiredForEveningDay != day {
                nightFiredForEveningDay = day
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
