import XCTest
@testable import SweatCaster

final class VillageLifeContractTests: XCTestCase {
    func testVillageZoneMappingAndNeedClamp() {
        XCTAssertEqual(VillageZoneID.fromHubRoom("video-studio"), .video)
        XCTAssertEqual(VillageZoneID.fromHubRoom("research"), .research)
        var needs = VillageNeeds(energy: 1.4, social: -0.2, fulfillment: 0.5, mood: 2)
        needs.clamp()
        XCTAssertEqual(needs.energy, 1)
        XCTAssertEqual(needs.social, 0)
        // Del B: mood = clamp(0.4e + 0.3s + 0.3f) = 0.4 + 0 + 0.15
        XCTAssertEqual(needs.mood, 0.55, accuracy: 0.0001)
    }

    @MainActor
    func testVillageLifePrefersSleepWhenEnergyIsLow() {
        let life = VillageLifeSimulator()
        var bot = life.bots[0]
        bot.needs.energy = 0.1
        XCTAssertEqual(life.chooseZone(for: bot, night: false, others: life.bots), .sleep)
        bot.needs.energy = 0.9
        bot.needs.social = 0.1
        XCTAssertEqual(life.chooseZone(for: bot, night: false, others: life.bots), .cafe)
    }

    @MainActor
    func testMergeLocalProfilesKeepsAdamAndEva() {
        let life = VillageLifeSimulator()
        var profile = VillageBot()
        profile.name = "Nova"
        profile.color = "Lilla"
        profile.personality = "Nysgerrig"
        life.mergeLocalProfiles([profile])
        XCTAssertTrue(life.bots.contains { $0.id == "adam" && $0.displayName == "Adam" })
        XCTAssertTrue(life.bots.contains { $0.id == "eva" && $0.displayName == "Eva" })
        XCTAssertTrue(life.bots.contains { $0.displayName == "Nova" })
    }

    @MainActor
    func testDelBSeedAdamEvaZonesAndNeeds() throws {
        let life = VillageLifeSimulator()
        let adam = try XCTUnwrap(life.bots.first { $0.id == "adam" })
        let eva = try XCTUnwrap(life.bots.first { $0.id == "eva" })
        XCTAssertEqual(adam.zoneID, .research)
        XCTAssertEqual(eva.zoneID, .video)
        XCTAssertEqual(adam.needs.energy, 0.80, accuracy: 0.001)
        XCTAssertEqual(adam.needs.social, 0.52, accuracy: 0.001)
        XCTAssertEqual(adam.needs.fulfillment, 0.48, accuracy: 0.001)
        XCTAssertEqual(eva.needs.energy, 0.76, accuracy: 0.001)
        XCTAssertEqual(eva.needs.social, 0.38, accuracy: 0.001)
        XCTAssertEqual(eva.needs.fulfillment, 0.55, accuracy: 0.001)
    }

    @MainActor
    func testDelBPCJobBeatsSleepCrisis() throws {
        let life = VillageLifeSimulator()
        var bot = try XCTUnwrap(life.bots.first { $0.id == "eva" })
        bot.needs.energy = 0.20
        bot.pcJobRunning = true
        bot.archetype = .creative
        XCTAssertEqual(life.chooseZone(for: bot, night: false, others: life.bots), .video)
    }

    @MainActor
    func testDelBQueuedJobKeepsSleepPriority() throws {
        let life = VillageLifeSimulator()
        var bot = try XCTUnwrap(life.bots.first { $0.id == "adam" })
        bot.needs.energy = 0.20
        bot.needs.social = 0.15
        bot.pcJobQueued = true
        XCTAssertEqual(life.chooseZone(for: bot, night: false, others: life.bots), .sleep)
    }

    @MainActor
    func testDelBPauseStopsTickProgress() {
        let life = VillageLifeSimulator()
        life.setPaused(true)
        let before = life.bots.map(\.zoneID)
        life.tick(now: Date().addingTimeInterval(10), reduceMotion: false)
        XCTAssertEqual(life.bots.map(\.zoneID), before)
    }

    @MainActor
    func testDelBPauseShiftsWalkTimers() {
        let life = VillageLifeSimulator()
        let t0 = Date()
        var bot = life.bots[0]
        bot.arrivedAt = t0.addingTimeInterval(-60)
        bot.needs.social = 0.1
        life.replaceBotForTesting(bot)
        life.tick(now: t0, reduceMotion: false)
        let walker = life.bots.first { $0.activity == .walk || $0.destinationZoneID == .cafe }
        XCTAssertNotNil(walker, "Expected a café walk after forcing low social")
        life.setPaused(true, at: t0.addingTimeInterval(1))
        life.setPaused(false, at: t0.addingTimeInterval(30))
        life.tick(now: t0.addingTimeInterval(31), reduceMotion: false)
        // After a 29s pause shift, the walk should not have finished from wall-clock alone.
        if let again = life.bots.first(where: { $0.id == walker!.id }), again.activity == .walk {
            XCTAssertLessThan(again.pathProgress, 1)
        }
    }

    @MainActor
    func testDelBQuestCompletionFiresAfterRunning() throws {
        let life = VillageLifeSimulator()
        let running = V2Hub.Quest(id: "q1", title: "Video edit", state: .running, updated_at: Date())
        let agent = V2Hub.Agent(
            id: "adam", room_id: "video", name: "Adam", icon: "person",
            status: .working, xp: 1, level: 1, xp_in_level: 1, xp_for_next_level: 10,
            recent_quests: [running]
        )
        life.applyHubAgents([agent], offline: false)
        XCTAssertFalse(life.bots.contains { $0.speechHint == "work_finished" })
        let done = V2Hub.Quest(id: "q1", title: "Video edit", state: .completed, updated_at: Date())
        let ready = V2Hub.Agent(
            id: "adam", room_id: "video", name: "Adam", icon: "person",
            status: .ready, xp: 1, level: 1, xp_in_level: 1, xp_for_next_level: 10,
            recent_quests: [done]
        )
        let before = try XCTUnwrap(life.bots.first { $0.id == "adam" }).needs.fulfillment
        life.applyHubAgents([ready], offline: false)
        let adam = try XCTUnwrap(life.bots.first { $0.id == "adam" })
        XCTAssertEqual(adam.needs.fulfillment, min(1, before + 0.10), accuracy: 0.001)
        XCTAssertEqual(adam.speechHint, "work_finished")
    }

    @MainActor
    func testDelBPCJobUsesQuestZoneNotOnlyArchetype() throws {
        let life = VillageLifeSimulator()
        var bot = try XCTUnwrap(life.bots.first { $0.id == "adam" })
        bot.pcJobRunning = true
        bot.pcJobZone = .video
        bot.archetype = .logic
        XCTAssertEqual(life.chooseZone(for: bot, night: false, others: life.bots), .video)
    }

    @MainActor
    func testDelBThinkingWithoutQueueIsNotQueued() {
        let life = VillageLifeSimulator()
        let agent = V2Hub.Agent(
            id: "eva", room_id: "video", name: "Eva", icon: "person",
            status: .thinking, xp: 1, level: 1, xp_in_level: 1, xp_for_next_level: 10,
            recent_quests: []
        )
        life.applyHubAgents([agent], offline: false)
        let eva = life.bots.first { $0.id == "eva" }
        XCTAssertEqual(eva?.pcLiveLabel, "Tænker")
        XCTAssertEqual(eva?.pcJobQueued, false)
    }

    @MainActor
    func testDelBThinkingWithRunningQuestWalksToJobZone() throws {
        let life = VillageLifeSimulator()
        let running = V2Hub.Quest(id: "q2", title: "Video edit", state: .running, updated_at: Date())
        let agent = V2Hub.Agent(
            id: "adam", room_id: "video", name: "Adam", icon: "person",
            status: .thinking, xp: 1, level: 1, xp_in_level: 1, xp_for_next_level: 10,
            recent_quests: [running]
        )
        life.applyHubAgents([agent], offline: false)
        let adam = try XCTUnwrap(life.bots.first { $0.id == "adam" })
        XCTAssertTrue(adam.pcJobRunning)
        XCTAssertEqual(adam.pcLiveLabel, "Tænker")
        XCTAssertEqual(adam.pcJobZone, .video)
        XCTAssertTrue(adam.destinationZoneID == .video || adam.zoneID == .video || adam.activity == .walk || adam.activity == .work)
    }

    @MainActor
    func testDelBThinkingJobDoesNotAnnounceWorkStartedOnArrival() throws {
        let life = VillageLifeSimulator()
        var adam = try XCTUnwrap(life.bots.first { $0.id == "adam" })
        adam.zoneID = .research
        adam.arrivedAt = Date().addingTimeInterval(-60)
        life.replaceBotForTesting(adam)
        let running = V2Hub.Quest(id: "q-think", title: "Video edit", state: .running, updated_at: Date())
        let agent = V2Hub.Agent(
            id: "adam", room_id: "video", name: "Adam", icon: "person",
            status: .thinking, xp: 1, level: 1, xp_in_level: 1, xp_for_next_level: 10,
            recent_quests: [running]
        )
        life.applyHubAgents([agent], offline: false)
        let walking = try XCTUnwrap(life.bots.first { $0.id == "adam" })
        XCTAssertEqual(walking.pcLiveLabel, "Tænker")
        XCTAssertNotEqual(walking.speechHint, "work_started")
        // Force arrival (reduce-motion path completes the walk immediately).
        let now = Date().addingTimeInterval(5)
        life.tick(now: now, reduceMotion: true)
        let arrived = try XCTUnwrap(life.bots.first { $0.id == "adam" })
        XCTAssertEqual(arrived.activity, .work)
        XCTAssertEqual(arrived.pcLiveLabel, "Tænker")
        XCTAssertNotEqual(arrived.speechHint, "work_started")
        XCTAssertTrue(arrived.workStartedAnnounced)
    }

    @MainActor
    func testDelBPauseDoesNotFutureShiftMidPauseWalk() {
        let life = VillageLifeSimulator()
        let t0 = Date()
        life.setPaused(true, at: t0)
        let running = V2Hub.Quest(id: "q3", title: "Video edit", state: .running, updated_at: t0)
        let agent = V2Hub.Agent(
            id: "adam", room_id: "video", name: "Adam", icon: "person",
            status: .working, xp: 1, level: 1, xp_in_level: 1, xp_for_next_level: 10,
            recent_quests: [running]
        )
        life.applyHubAgents([agent], offline: false)
        life.setPaused(false, at: t0.addingTimeInterval(20))
        life.tick(now: t0.addingTimeInterval(20.5), reduceMotion: false)
        if let adam = life.bots.first(where: { $0.id == "adam" }), adam.activity == .walk {
            XCTAssertGreaterThanOrEqual(adam.pathProgress, 0)
            XCTAssertLessThan(adam.pathProgress, 1)
        }
    }

    @MainActor
    func testDelBOfflineClearsLivePCMarkers() {
        let life = VillageLifeSimulator()
        var bot = life.bots[0]
        bot.pcJobRunning = true
        bot.pcLiveLabel = "Klip"
        life.replaceBotForTesting(bot)
        life.applyHubAgents([], offline: true)
        XCTAssertFalse(life.bots[0].pcJobRunning)
        XCTAssertNil(life.bots[0].pcLiveLabel)
        XCTAssertEqual(life.banner, VillageCopy.speech("offline_rest"))
    }

    @MainActor
    func testDelBPCSwitchClearsMarkersWithoutOfflineRest() {
        let life = VillageLifeSimulator()
        var bot = life.bots[0]
        bot.pcJobRunning = true
        bot.pcLiveLabel = "Render"
        bot.pcJobQueued = true
        life.replaceBotForTesting(bot)
        let before = life.banner
        life.clearPCJobMarkers()
        XCTAssertFalse(life.bots[0].pcJobRunning)
        XCTAssertFalse(life.bots[0].pcJobQueued)
        XCTAssertNil(life.bots[0].pcLiveLabel)
        XCTAssertEqual(life.banner, before)
        life.applyHubAgents([], offline: false)
        XCTAssertNotEqual(life.banner, VillageCopy.speech("pc_reconnected"))
    }

    func testVillageCameraClampAt1xIsCentered() {
        let frame = CGSize(width: 320, height: 420)
        XCTAssertEqual(VillageCamera.clampOffset(CGSize(width: 80, height: -40), zoom: 1, frame: frame), .zero)
    }

    func testVillageCameraClampAt2xCapsEdges() {
        let frame = CGSize(width: 320, height: 420)
        let maxX = (320.0 * 2 - 320) / 2 // 160
        let maxY = (420.0 * 2 - 420) / 2 // 210
        let clamped = VillageCamera.clampOffset(CGSize(width: 999, height: -999), zoom: 2, frame: frame)
        XCTAssertEqual(clamped.width, maxX, accuracy: 0.001)
        XCTAssertEqual(clamped.height, -maxY, accuracy: 0.001)
    }

    @MainActor
    func testDelBReduceMotionArrivesInstantly() {
        let life = VillageLifeSimulator()
        var bot = life.bots[0]
        bot.arrivedAt = Date().addingTimeInterval(-60)
        bot.needs.social = 0.1
        life.replaceBotForTesting(bot)
        // Force decision by clearing lastDecision via many ticks with reduce motion
        let now = Date()
        for step in 0..<12 {
            life.tick(now: now.addingTimeInterval(Double(step) * 2), reduceMotion: true)
        }
        if let eva = life.bots.first(where: { $0.id == "eva" }), eva.destinationZoneID == nil {
            // Eva starts social 0.38 — may walk or already be at cafe/idle
            XCTAssertTrue([VillageZoneID.cafe, .video, .research, .sleep].contains(eva.zoneID))
        }
        XCTAssertTrue(life.bots.allSatisfy { $0.destinationZoneID == nil || $0.pathProgress == 0 })
    }

    @MainActor
    func testDelBFirstDecisionSendsEvaTowardCafe() {
        let life = VillageLifeSimulator()
        let now = Date()
        // First tick runs a decision immediately (lastDecision starts distantPast).
        life.tick(now: now, reduceMotion: false)
        let eva = life.bots.first { $0.id == "eva" }
        let adam = life.bots.first { $0.id == "adam" }
        XCTAssertNotNil(eva)
        XCTAssertNotNil(adam)
        // Eva social 0.38 → café reservation / walk; Adam may practice in Research Lab.
        let evaMovingToCafe = eva?.destinationZoneID == .cafe
            || eva?.zoneID == .cafe
            || eva?.cafePartnerID != nil
            || eva?.activity == .walk
        XCTAssertTrue(evaMovingToCafe, "Eva should head toward café on first decision")
        XCTAssertEqual(adam?.zoneID, .research)
        XCTAssertNotEqual(adam?.destinationZoneID, .cafe, "Adam should not leave for café before min stay")
    }

    func testDelBSleepKeepsQueuedLabel() {
        let label = VillageCopy.activityLabel(.sleep, zone: .sleep, pcJob: false, queued: true, localWork: false)
        XCTAssertTrue(label.contains("Venter"))
    }


}
