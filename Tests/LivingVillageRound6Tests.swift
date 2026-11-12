// Round 6: gamle bots, Adam og Eva, energiregnskab, frys og gemmerytme.
import Foundation
import XCTest
@testable import SweatCaster

@MainActor final class LivingVillageRound6Tests: XCTestCase {
    private let novaID = "7C9E6679-7425-40DE-944B-E07FC1F90AE7"
    private let lunaID = "A1B2C3D4-E5F6-4789-A012-3456789ABCDE"

    func testOldBotProfilesDraftsAndBackupsDecodeWithDefaultTraits() throws {
        let draft = Data(#"{"id":"7C9E6679-7425-40DE-944B-E07FC1F90AE7","name":"Nova","color":"Blå","prompt":"Vær varm","voice":"da-DK","sprite":null,"personality":"Omsorgsfuld"}"#.utf8)
        let imported = try JSONDecoder().decode(VillageBot.self, from: draft)
        XCTAssertEqual(imported.name, "Nova")
        XCTAssertEqual(imported.personality, "Omsorgsfuld")
        XCTAssertNil(imported.notifications)
        XCTAssertEqual(imported.notifications ?? true, true)
        XCTAssertNil(imported.voiceRate)
        XCTAssertEqual(imported.voiceRate ?? 1.0, 1.0)
        XCTAssertEqual(imported.traits, VillageBot.defaultTraits)
        XCTAssertNil(imported.bestFriendID)
        XCTAssertEqual(imported.dailyMemory, [])

        let stored = Data("""
        {"id":"\(novaID)","name":"Nova","color":"Grøn","prompt":"Vær varm","voice":"da-DK","sprite":null,"personality":"Omsorgsfuld","notifications":false,"voiceRate":1.2,"language":"en-US","specialty":"Researcher","responsibility":"Noter","energy":12,"social":3,"workJoy":4,"mood":"glad","currentActivity":"working"}
        """.utf8)
        let resident = try JSONDecoder().decode(VillageBot.self, from: stored)
        XCTAssertEqual(resident.color, "Grøn")
        XCTAssertEqual(resident.notifications, false)
        XCTAssertEqual(resident.voiceRate ?? 0, 1.2, accuracy: 0.0001)
        XCTAssertEqual(resident.language, "en-US")
        XCTAssertEqual(resident.specialty, "Researcher")
        XCTAssertEqual(resident.responsibility, "Noter")
        XCTAssertEqual(resident.traits, VillageBot.defaultTraits)

        let backup = Data("[\(String(decoding: draft, as: UTF8.self))]".utf8)
        let restored = try JSONDecoder().decode([VillageBot].self, from: backup)
        XCTAssertEqual(restored.map(\.name), ["Nova"])
        XCTAssertEqual(restored[0].traits, VillageBot.defaultTraits)

        var edited = resident
        edited.name = "Nova 2"
        edited.traits = ["Social", "Kreativ", "Nysgerrig"]
        edited.dailyMemory = ["Så en video"]
        edited.bestFriendID = try XCTUnwrap(UUID(uuidString: lunaID))
        let encoded = try JSONEncoder().encode(edited)
        let roundTrip = try JSONDecoder().decode(VillageBot.self, from: encoded)
        XCTAssertEqual(roundTrip, edited)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNil(object["energy"])
        XCTAssertNil(object["social"])
        XCTAssertNil(object["workJoy"])
        XCTAssertNil(object["mood"])
        XCTAssertNil(object["currentActivity"])

        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let onDisk = Data("[\(String(decoding: stored, as: UTF8.self))]".utf8)
        try fixture.store.saveBytes(onDisk, forKey: "village_bots")
        let model = MigratedAppData(defaults: fixture.defaults, store: fixture.store)
        let loaded = try model.loadBots().get()
        XCTAssertEqual(loaded.map(\.name), ["Nova"])
        XCTAssertEqual(loaded[0].traits, VillageBot.defaultTraits)
        let village = SimulationEngine(repository: model, defaults: fixture.defaults, store: MemorySimulationStore(), runsLoop: false)
        village.handle(.active)
        let fresh = try XCTUnwrap(village.states[loaded[0].id])
        XCTAssertEqual(fresh.energy, 100)
        XCTAssertEqual(fresh.social, 50)
        XCTAssertEqual(fresh.workJoy, 50)
        XCTAssertEqual(fresh.mood, .neutral)
    }

    func testOneBadBotIsSkippedWithoutEmptyingTheList() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let mixed = Data("""
        [
          {"id":"\(novaID)","name":"Nova","color":"Blå","prompt":"Vær varm","voice":"da-DK"},
          {"id":"ikke-en-uuid","name":"Ødelagt","color":"Blå","prompt":"","voice":"da-DK"},
          {"id":"\(lunaID)","name":"Luna","color":"Lilla","prompt":"Klip","voice":"da-DK","traits":["Kreativ","Nysgerrig","Social"]}
        ]
        """.utf8)
        try fixture.store.saveBytes(mixed, forKey: "village_bots")
        let key = AppStorageKeys.diagnosticsApiV1
        let previous = UserDefaults.standard.stringArray(forKey: key)
        UserDefaults.standard.removeObject(forKey: key)
        defer { UserDefaults.standard.set(previous, forKey: key) }
        let model = MigratedAppData(defaults: fixture.defaults, store: fixture.store)
        let bots = try model.loadBots().get()
        XCTAssertEqual(bots.map(\.name), ["Nova", "Luna"])
        XCTAssertEqual(bots[0].traits, VillageBot.defaultTraits)
        XCTAssertEqual(bots[1].traits, ["Kreativ", "Nysgerrig", "Social"])
        XCTAssertEqual(VillageBot.list(from: model.villageBots).map(\.name), ["Nova", "Luna"])
        XCTAssertFalse(bots.isEmpty)
        let logged = UserDefaults.standard.stringArray(forKey: key) ?? []
        XCTAssertTrue(logged.contains { $0.contains("JSON") })
    }

    func testAdamAndEvaAppearOnlyOnTheFirstEmptyStart() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let model = MigratedAppData(defaults: fixture.defaults, store: fixture.store)
        let first = VillageSeeder.prepare(repository: model, defaults: fixture.defaults)
        XCTAssertNil(first.message)
        XCTAssertEqual(first.bots.map(\.name), ["Adam", "Eva"])
        XCTAssertEqual(first.bots[0].specialty, "Kode og logik")
        XCTAssertEqual(first.bots[0].personality, "Rolig")
        XCTAssertEqual(first.bots[0].traits, ["Flittig", "Perfektionist", "Tålmodig"])
        XCTAssertEqual(first.bots[1].specialty, "Kreativ leder")
        XCTAssertEqual(first.bots[1].personality, "Nysgerrig")
        XCTAssertEqual(first.bots[1].traits, ["Kreativ", "Nysgerrig", "Social"])
        XCTAssertTrue(fixture.defaults.bool(forKey: AppStorageKeys.villageEverInitialized))
        let again = VillageSeeder.prepare(repository: model, defaults: fixture.defaults)
        XCTAssertEqual(again.bots.map(\.id), first.bots.map(\.id))

        try model.saveBots([])
        let deleted = VillageSeeder.prepare(repository: model, defaults: fixture.defaults)
        XCTAssertNil(deleted.message)
        XCTAssertTrue(deleted.bots.isEmpty)
        XCTAssertTrue(fixture.defaults.bool(forKey: AppStorageKeys.villageEverInitialized))
        XCTAssertEqual(try model.loadBots().get(), [])
    }

    func testExistingBotsDoNotGainFoundersAndSetTheFlag() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let model = MigratedAppData(defaults: fixture.defaults, store: fixture.store)
        try model.saveBots([VillageBot(name: "Nova")])
        fixture.defaults.set(false, forKey: AppStorageKeys.villageEverInitialized)
        let outcome = VillageSeeder.prepare(repository: model, defaults: fixture.defaults)
        XCTAssertEqual(outcome.bots.map(\.name), ["Nova"])
        XCTAssertTrue(fixture.defaults.bool(forKey: AppStorageKeys.villageEverInitialized))
    }

    func testReadErrorDoesNotCreateBotsOrSetTheFlag() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let corrupt = Data("ikke json".utf8)
        try fixture.store.saveBytes(corrupt, forKey: "village_bots")
        let model = MigratedAppData(defaults: fixture.defaults, store: fixture.store)
        let outcome = VillageSeeder.prepare(repository: model, defaults: fixture.defaults)
        XCTAssertEqual(outcome.message, "Landsbyen kunne ikke læses. Ingen bots blev oprettet.")
        XCTAssertTrue(outcome.bots.isEmpty)
        XCTAssertFalse(fixture.defaults.bool(forKey: AppStorageKeys.villageEverInitialized))
        XCTAssertEqual(try fixture.store.loadBytes(forKey: "village_bots"), corrupt)
        if case .failure = model.loadBots() {} else { XCTFail("Forventede en læsefejl") }
    }

    func testTwentyFourHourEnergyCycleSumsToZero() {
        var counts: [BotActivity: Int] = [:]
        for hour in 0..<24 { counts[BotActivity.scheduled(atHour: hour), default: 0] += 1 }
        XCTAssertEqual(counts[.working], 9)
        XCTAssertEqual(counts[.idle], 2)
        XCTAssertEqual(counts[.resting], 4)
        XCTAssertEqual(counts[.sleeping], 9)
        XCTAssertEqual(BotActivity.scheduled(atHour: 8).energyPerHour, -4)
        XCTAssertEqual(BotActivity.scheduled(atHour: 12).energyPerHour, -1)
        XCTAssertEqual(BotActivity.scheduled(atHour: 18).energyPerHour, 2)
        XCTAssertEqual(BotActivity.scheduled(atHour: 22).energyPerHour, 4)
        XCTAssertEqual(BotActivity.rawDailyEnergyDelta, Double(9 * -4 + 2 * -1 + 4 * 2 + 9 * 4))
        XCTAssertEqual(BotActivity.rawDailyEnergyDelta, 6)
        let morning = BotActivity.energyAfterOneDay(startingAtHour: 7, energy: 100)
        XCTAssertEqual(morning, 100)
        XCTAssertEqual(morning - 100, 0)
    }

    func testNeedsUseDoublesAndTheSpecifiedRates() {
        let working = state(afterMinutes: 30, hour: 9)
        XCTAssertEqual(working.currentActivity, .working)
        XCTAssertEqual(working.energy, 98)
        XCTAssertEqual(working.social, 50)
        XCTAssertEqual(working.workJoy, 50)

        let idle = state(afterMinutes: 30, hour: 7)
        XCTAssertEqual(idle.currentActivity, .idle)
        XCTAssertEqual(idle.energy, 99.5)
        XCTAssertEqual(idle.social, 49.5)
        XCTAssertEqual(idle.workJoy, 49)

        var resting = BotSimulationState(energy: 40, social: 50, workJoy: 50)
        BotSimulationState.apply(elapsed: 1800, at: utcDate(hour: 19).addingTimeInterval(1800), calendar: utcCalendar, to: &resting)
        XCTAssertEqual(resting.currentActivity, .resting)
        XCTAssertEqual(resting.energy, 41)
        XCTAssertEqual(resting.social, 50)
        XCTAssertEqual(resting.workJoy, 49)

        var sleeping = BotSimulationState(energy: 40, social: 50, workJoy: 50)
        BotSimulationState.apply(elapsed: 1800, at: utcDate(hour: 23).addingTimeInterval(1800), calendar: utcCalendar, to: &sleeping)
        XCTAssertEqual(sleeping.currentActivity, .sleeping)
        XCTAssertEqual(sleeping.energy, 42)
        XCTAssertEqual(sleeping.social, 50)
        XCTAssertEqual(sleeping.workJoy, 49)
        XCTAssertEqual(sleeping.energyDisplay, 42)
        XCTAssertNotEqual(idle.social, Double(idle.socialDisplay))

        let low = BotSimulationState(energy: 10.4, social: 80, workJoy: 90)
        XCTAssertEqual(low.energy, 10.4)
        XCTAssertEqual(low.energyDisplay, 10)
        XCTAssertEqual(low.mood, .tired)
        XCTAssertEqual(BotMood.tired.title, "Træt")
        XCTAssertEqual(BotMood.tired.symbolName, "moon.zzz")
        XCTAssertEqual(BotMood.resolve(energy: 10, social: 10, workJoy: 10), .frustrated)
        XCTAssertEqual(BotMood.resolve(energy: 80, social: 10, workJoy: 50), .lonely)
        XCTAssertEqual(BotMood.resolve(energy: 80, social: 80, workJoy: 90), .proud)
        XCTAssertEqual(BotMood.resolve(energy: 80, social: 80, workJoy: 60), .glad)
        XCTAssertEqual(BotMood.resolve(energy: 100, social: 50, workJoy: 50), .neutral)
    }

    func testBackgroundFreezesWithoutCatchUp() throws {
        let bot = VillageBot(name: "Nova")
        let repo = MemoryVillageBots(bots: [bot])
        let saved = MemorySimulationStore()
        let defaults = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }
        var time = utcDate(hour: 9)
        let engine = SimulationEngine(repository: repo, defaults: defaults, store: saved, clock: { time }, runsLoop: false)
        engine.calendar = utcCalendar
        engine.handle(.active)
        let started = try XCTUnwrap(engine.states[bot.id])
        XCTAssertEqual(started.energy, 100)
        XCTAssertEqual(started.social, 50)
        XCTAssertEqual(started.workJoy, 50)
        XCTAssertTrue(engine.isRunning)
        XCTAssertEqual(saved.saves, 0)

        time = time.addingTimeInterval(4 * 3600)
        engine.handle(.inactive)
        XCTAssertFalse(engine.isRunning)
        XCTAssertEqual(saved.saves, 0)
        engine.handle(.background)
        XCTAssertFalse(engine.isRunning)
        XCTAssertEqual(saved.saves, 1)
        let frozen = try JSONDecoder().decode(VillageSimulationSnapshot.self, from: try XCTUnwrap(saved.data))
        XCTAssertEqual(try XCTUnwrap(frozen.keyed()[bot.id]).energy, 100)

        engine.handle(.active)
        engine.tick()
        XCTAssertEqual(try XCTUnwrap(engine.states[bot.id]).energy, 100)
        time = time.addingTimeInterval(3600)
        engine.tick()
        XCTAssertEqual(try XCTUnwrap(engine.states[bot.id]).energy, 96)
    }

    func testSimulationPersistsOnBackgroundAndEveryTenthTick() throws {
        let bot = VillageBot(name: "Nova")
        let repo = MemoryVillageBots(bots: [bot])
        let saved = MemorySimulationStore()
        let defaults = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }
        var time = utcDate(hour: 9)
        let engine = SimulationEngine(repository: repo, defaults: defaults, store: saved, clock: { time }, runsLoop: false)
        engine.calendar = utcCalendar
        engine.handle(.active)
        engine.registerChat(with: bot.id)
        engine.registerBotInteraction(bot.id)
        engine.registerJobFinished(bot.id)
        engine.registerJobFailed(bot.id)
        XCTAssertEqual(try XCTUnwrap(engine.states[bot.id]).social, 58)
        XCTAssertEqual(try XCTUnwrap(engine.states[bot.id]).workJoy, 55)
        XCTAssertEqual(saved.saves, 0)

        for _ in 1...9 {
            time = time.addingTimeInterval(60)
            engine.tick()
        }
        XCTAssertEqual(saved.saves, 0)
        time = time.addingTimeInterval(60)
        engine.tick()
        XCTAssertEqual(saved.saves, 1)
        let energy = try XCTUnwrap(engine.states[bot.id]).energy
        let revived = SimulationEngine(repository: repo, defaults: defaults, store: saved, clock: { time }, runsLoop: false)
        let restored = try XCTUnwrap(revived.states[bot.id])
        XCTAssertEqual(restored.energy, energy, accuracy: 0.000_001)
        XCTAssertEqual(restored.social, try XCTUnwrap(engine.states[bot.id]).social, accuracy: 0.000_001)

        time = time.addingTimeInterval(60)
        engine.tick()
        XCTAssertEqual(saved.saves, 1)
        engine.handle(.background)
        XCTAssertEqual(saved.saves, 2)
        XCTAssertFalse(engine.isRunning)
    }

    func testActiveStartsTheLoopAndBackgroundStopsIt() throws {
        let repo = MemoryVillageBots(bots: [VillageBot(name: "Nova")])
        let defaults = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }
        let engine = SimulationEngine(repository: repo, defaults: defaults, store: MemorySimulationStore(), runsLoop: true)
        engine.tickInterval = .seconds(3600)
        engine.handle(.active)
        XCTAssertTrue(engine.isRunning)
        engine.handle(.background)
        XCTAssertFalse(engine.isRunning)
    }

    private func state(afterMinutes minutes: TimeInterval, hour: Int) -> BotSimulationState {
        var time = utcDate(hour: hour)
        let repo = MemoryVillageBots(bots: [])
        let suite = "FadedAI.Tests.LivingVillage.Rate.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let engine = SimulationEngine(repository: repo, defaults: defaults, store: MemorySimulationStore(),
                                      clock: { time }, runsLoop: false)
        engine.calendar = utcCalendar
        let bot = VillageBot(name: "Måler")
        repo.bots = [bot]
        engine.handle(.active)
        time = time.addingTimeInterval(minutes * 60)
        engine.tick()
        return engine.states[bot.id] ?? BotSimulationState()
    }

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func utcDate(hour: Int) -> Date {
        utcCalendar.date(from: DateComponents(timeZone: TimeZone(secondsFromGMT: 0), year: 2026, month: 11, day: 12, hour: hour))!
    }

    private var defaultsSuite: String { "FadedAI.Tests.LivingVillage.\(name)" }

    private func isolatedDefaults() throws -> UserDefaults {
        try XCTUnwrap(UserDefaults(suiteName: defaultsSuite))
    }

    private struct Fixture {
        let defaults: UserDefaults
        let suite: String
        let directory: URL
        let store: LocalModelStore
        func cleanup() {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func makeFixture() throws -> Fixture {
        let suite = "FadedAI.Tests.LivingVillage.Files.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let store = LocalModelStore(root: directory.appending(path: "Models", directoryHint: .isDirectory))
        return Fixture(defaults: defaults, suite: suite, directory: directory, store: store)
    }
}

@MainActor private final class MemoryVillageBots: VillageBotRepository {
    var bots: [VillageBot]
    init(bots: [VillageBot]) { self.bots = bots }
    func loadBots() -> Result<[VillageBot], Error> { .success(bots) }
    func saveBots(_ bots: [VillageBot]) throws { self.bots = bots }
}

private final class MemorySimulationStore: VillageSimulationStore {
    var data: Data?
    var saves = 0
    func load() -> Data? { data }
    func save(_ data: Data) {
        saves += 1
        self.data = data
    }
}
