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

    init(states: [UUID: BotSimulationState]) {
        self.states = Dictionary(uniqueKeysWithValues: states.map { ($0.key.uuidString, $0.value) })
    }

    func keyed() -> [UUID: BotSimulationState] {
        Dictionary(uniqueKeysWithValues: states.compactMap { key, value in
            UUID(uuidString: key).map { ($0, value) }
        })
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

    init(repository: any VillageBotRepository, defaults: UserDefaults, store: any VillageSimulationStore,
         clock: @escaping () -> Date = { Date.now }, runsLoop: Bool = true) {
        self.repository = repository
        self.defaults = defaults
        self.store = store
        self.clock = clock
        self.runsLoop = runsLoop
        self.lastTick = clock()
        if let data = store.load() {
            do { states = try JSONDecoder().decode(VillageSimulationSnapshot.self, from: data).keyed() }
            catch { AppDiagnostics.record(error) }
        }
    }

    func handle(_ phase: ScenePhase) {
        switch phase {
        case .background:
            isRunning = false
            stopLoop()
            persist()
        case .inactive:
            isRunning = false
            stopLoop()
        case .active:
            lastTick = clock()
            isRunning = true
            let outcome = VillageSeeder.prepare(repository: repository, defaults: defaults)
            readError = outcome.message
            if outcome.message == nil { reconcile(outcome.bots.map(\.id)) }
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
        for id in Array(states.keys) {
            guard var state = states[id] else { continue }
            BotSimulationState.apply(elapsed: elapsed, at: now, calendar: calendar, to: &state)
            states[id] = state
        }
        completedTicks += 1
        if completedTicks.isMultiple(of: 10) { persist() }
    }

    func registerChat(with botID: UUID) { bump(botID) { $0.social += BotSimulationState.socialChatBonus } }
    func registerBotInteraction(_ botID: UUID) { bump(botID) { $0.social += BotSimulationState.socialInteractionBonus } }
    func registerJobFinished(_ botID: UUID) { bump(botID) { $0.workJoy += BotSimulationState.workJoyFinishedBonus } }
    func registerJobFailed(_ botID: UUID) { bump(botID) { $0.workJoy += BotSimulationState.workJoyFailedPenalty } }

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
        states = next
    }

    private func persist() {
        do { store.save(try JSONEncoder().encode(VillageSimulationSnapshot(states: states))) }
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
