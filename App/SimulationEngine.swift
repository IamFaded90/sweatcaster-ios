// Tick hvert 60. sekund mens appen er aktiv. Baggrund og inaktiv tilstand fryser tiden.

import Foundation
import Observation
import SwiftUI

@MainActor protocol VillageBotRepository: AnyObject {
    func loadBots() -> Result<[VillageBot], Error>
    func saveBots(_ bots: [VillageBot]) throws
}

protocol VillageSimulationStore: AnyObject {
    func load() -> Data?
    func save(_ data: Data)
}

final class UserDefaultsVillageSimulationStore: VillageSimulationStore {
    let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    func load() -> Data? { defaults.data(forKey: AppStorageKeys.villageSimulation) }
    func save(_ data: Data) { defaults.set(data, forKey: AppStorageKeys.villageSimulation) }
}

struct VillageSimulationSnapshot: Codable, Equatable {
    var states: [String: BotSimulationState]
    var jobHistory: [String: [UUID]]?
    var socialHistory: [String]?

    init(states: [UUID: BotSimulationState], jobHistory: [String: [UUID]]? = nil, socialHistory: [String]? = nil) {
        self.states = Dictionary(uniqueKeysWithValues: states.map { ($0.key.uuidString, $0.value) })
        self.jobHistory = jobHistory
        self.socialHistory = socialHistory
    }

    func keyed() -> [UUID: BotSimulationState] {
        states.reduce(into: [:]) { result, entry in
            if let id = UUID(uuidString: entry.key) { result[id] = entry.value }
        }
    }
}

enum VillageSeeder {
    struct Outcome {
        var bots: [VillageBot]
        var message: String?
    }

    @MainActor static func prepare(repository: any VillageBotRepository, defaults: UserDefaults) -> Outcome {
        let flag = AppStorageKeys.villageEverInitialized
        switch repository.loadBots() {
        case .failure:
            return Outcome(bots: [], message: "Landsbyen kunne ikke læses. Ingen bots blev oprettet.")
        case .success(let bots) where bots.isEmpty:
            guard defaults.bool(forKey: flag) == false else { return Outcome(bots: [], message: nil) }
            let founders = [VillageBot.founderAdam(), VillageBot.founderEva()]
            do { try repository.saveBots(founders) }
            catch {
                AppDiagnostics.record(error)
                return Outcome(bots: [], message: "Adam og Eva kunne ikke gemmes.")
            }
            defaults.set(true, forKey: flag)
            return Outcome(bots: founders, message: nil)
        case .success(let bots):
            if defaults.bool(forKey: flag) == false { defaults.set(true, forKey: flag) }
            return Outcome(bots: bots, message: nil)
        }
    }
}

@MainActor @Observable final class SimulationEngine {
    static let shared = SimulationEngine(
        repository: MigratedAppData.shared,
        defaults: .standard,
        store: UserDefaultsVillageSimulationStore()
    )

    private(set) var states: [UUID: BotSimulationState] = [:]
    private(set) var isRunning = false
    private(set) var isPaused = false
    private(set) var activeJobs: [UUID: BotComputerJob.State] = [:]
    private var conversations: [UUID: Set<UUID>] = [:]
    var chattingBots: Set<UUID> { Set(conversations.values.joined()) }
    var readError: String?
    var tickInterval: Duration = .seconds(60)
    var calendar = Calendar.current
    var clock: () -> Date = { Date.now }
    var runsLoop = true

    private let repository: any VillageBotRepository
    private let defaults: UserDefaults
    private let store: any VillageSimulationStore
    private var lastTick: Date
    private var completedTicks = 0
    private var loopTask: Task<Void, Never>?
    private var jobHistory: [String: [UUID]] = [:]
    private var socialHistory: [String] = []
    private var jobTargetID: String?

    init(repository: any VillageBotRepository, defaults: UserDefaults, store: any VillageSimulationStore,
         clock: @escaping () -> Date = { Date.now }, runsLoop: Bool = true) {
        self.repository = repository
        self.defaults = defaults
        self.store = store
        self.clock = clock
        self.runsLoop = runsLoop
        self.lastTick = clock()
        if let data = store.load() {
            do {
                let snapshot = try JSONDecoder().decode(VillageSimulationSnapshot.self, from: data)
                states = snapshot.keyed()
                jobHistory = snapshot.jobHistory ?? [:]
                socialHistory = Array((snapshot.socialHistory ?? []).suffix(500))
            }
            catch { AppDiagnostics.record(error) }
        }
    }

    func handle(_ phase: ScenePhase) {
        switch phase {
        case .background:
            isRunning = false
            stopLoop()
            clearActiveJobs()
            persist()
        case .inactive:
            isRunning = false
            stopLoop()
            clearActiveJobs()
        case .active:
            lastTick = clock()
            isRunning = true
            let outcome = VillageSeeder.prepare(repository: repository, defaults: defaults)
            readError = outcome.message
            if outcome.message == nil {
                reconcile(outcome.bots.map(\.id))
                if !isPaused { updateScheduledActivity(at: lastTick, elapsed: 0) }
            }
            startLoopIfNeeded()
        @unknown default:
            break
        }
    }

    func tick() {
        guard isRunning else { return }
        let now = clock()
        let elapsed = now.timeIntervalSince(lastTick)
        lastTick = now
        let outcome = VillageSeeder.prepare(repository: repository, defaults: defaults)
        if let message = outcome.message {
            readError = message
        } else {
            readError = nil
            reconcile(outcome.bots.map(\.id))
        }
        if !isPaused {
            updateScheduledActivity(at: now, elapsed: elapsed)
        }
        completedTicks += 1
        if completedTicks.isMultiple(of: 10) { persist() }
    }

    func setPaused(_ paused: Bool) {
        guard paused != isPaused else { return }
        lastTick = clock()
        isPaused = paused
        if !paused { updateScheduledActivity(at: lastTick, elapsed: 0) }
    }

    func beginConversation(_ eventID: UUID, bots: [UUID]) {
        let active = Set(bots)
        guard conversations[eventID] != active else { return }
        conversations[eventID] = active
    }

    func endConversation(_ eventID: UUID) { conversations.removeValue(forKey: eventID) }

    func clearActiveJobs() {
        if !activeJobs.isEmpty { activeJobs.removeAll() }
        jobTargetID = nil
    }

    func ingestJobs(_ jobs: [VillageBotJobActivity], for botID: UUID, targetID: String) {
        guard isRunning, ensureState(botID) else { return }
        if jobTargetID != targetID {
            clearActiveJobs()
            jobTargetID = targetID
        }
        let active: BotComputerJob.State? = jobs.contains { $0.status == .running } ? .running :
            (jobs.contains { $0.status == .queued } ? .queued : nil)
        if activeJobs[botID] != active { activeJobs[botID] = active }

        let scope = botID.uuidString + ":" + targetID
        let previous = jobHistory[scope]
        var history = previous ?? []
        var seen = Set(history)
        for job in jobs.reversed() {
            guard job.status == .completed || job.status == .failed, seen.insert(job.id).inserted else { continue }
            history.append(job.id)
            // On the first connection, remember completed jobs without awarding old activity.
            if previous != nil {
                if job.status == .completed { registerJobFinished(botID) }
                else { registerJobFailed(botID) }
            }
        }
        if previous != history {
            jobHistory[scope] = Array(history.suffix(160))
            persist()
        }
    }

    func registerChat(with botID: UUID, eventID: UUID? = nil) {
        registerSocial(botID, eventID: eventID, kind: "chat", bonus: BotSimulationState.socialChatBonus)
    }

    func registerBotInteraction(_ botID: UUID, eventID: UUID? = nil) {
        registerSocial(botID, eventID: eventID, kind: "team", bonus: BotSimulationState.socialInteractionBonus)
    }

    func registerJobFinished(_ botID: UUID) { bump(botID) { $0.workJoy += BotSimulationState.workJoyFinishedBonus } }
    func registerJobFailed(_ botID: UUID) { bump(botID) { $0.workJoy += BotSimulationState.workJoyFailedPenalty } }

    private func updateScheduledActivity(at date: Date, elapsed: TimeInterval) {
        for (id, original) in states {
            var state = original
            BotSimulationState.apply(elapsed: elapsed, at: date, calendar: calendar, to: &state)
            if state != original { states[id] = state }
        }
    }

    private func registerSocial(_ id: UUID, eventID: UUID?, kind: String, bonus: Double) {
        guard ensureState(id) else { return }
        if let eventID {
            let key = kind + ":" + id.uuidString + ":" + eventID.uuidString
            guard !socialHistory.contains(key) else { return }
            socialHistory = Array((socialHistory + [key]).suffix(500))
        }
        bump(id) { $0.social += bonus }
        if eventID != nil { persist() }
    }

    private func ensureState(_ id: UUID) -> Bool {
        if states[id] != nil { return true }
        guard case .success(let bots) = repository.loadBots(), bots.contains(where: { $0.id == id }) else { return false }
        reconcile(bots.map(\.id))
        return true
    }

    private func bump(_ id: UUID, _ change: (inout BotSimulationState) -> Void) {
        guard var state = states[id] else { return }
        change(&state)
        state.energy = BotSimulationState.clamp(state.energy)
        state.social = BotSimulationState.clamp(state.social)
        state.workJoy = BotSimulationState.clamp(state.workJoy)
        state.mood = BotMood.resolve(energy: state.energy, social: state.social, workJoy: state.workJoy)
        states[id] = state
    }

    private func reconcile(_ ids: [UUID]) {
        let live = Set(ids)
        var next = states.filter { live.contains($0.key) }
        for id in live where next[id] == nil { next[id] = BotSimulationState() }
        if states != next { states = next }
        if !activeJobs.keys.allSatisfy(live.contains) { activeJobs = activeJobs.filter { live.contains($0.key) } }
    }

    private func persist() {
        do {
            store.save(try JSONEncoder().encode(
                VillageSimulationSnapshot(states: states, jobHistory: jobHistory, socialHistory: socialHistory)
            ))
        }
        catch { AppDiagnostics.record(error) }
    }

    private func startLoopIfNeeded() {
        guard runsLoop, loopTask == nil else { return }
        loopTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    private func runLoop() async {
        while isRunning && !Task.isCancelled {
            do { try await Task.sleep(for: tickInterval) }
            catch { return }
            guard isRunning, !Task.isCancelled else { return }
            tick()
        }
    }

    private func stopLoop() {
        loopTask?.cancel()
        loopTask = nil
    }
}
