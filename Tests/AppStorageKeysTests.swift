// Locks down persisted names that must survive app upgrades.
import Foundation
import XCTest
@testable import SweatCaster

final class AppStorageKeysTests: XCTestCase {
    func testMigrationReadsTheExistingDefaultsKeys() {
        XCTAssertEqual(AppStorageKeys.villageBots, "village.bots")
        XCTAssertEqual(AppStorageKeys.villageEverInitialized, "village.everInitialized")
        XCTAssertEqual(AppStorageKeys.villageSimulation, "village.simulation")
        XCTAssertEqual(AppStorageKeys.spacesNotes, "spaces.notes")
        XCTAssertEqual(AppStorageKeys.privateChatTurns, "private.chat.turns")
        XCTAssertEqual(AppStorageKeys.privateChatDraft, "private.chat.draft")
        XCTAssertEqual(AppStorageKeys.dashboardChatPreviews, "dashboard.chat.previews")
        XCTAssertEqual(AppStorageKeys.codeActiveContext, "code.active.context")
    }

    func testDynamicKeysPreserveTheEstablishedNamespaces() throws {
        let botID = try XCTUnwrap(UUID(uuidString: "E594D46C-8FC9-457C-9E0D-98C22533B810"))
        XCTAssertEqual(Pairing.addressKey, "server.address")
        XCTAssertEqual(ConnectionProfile.home.storageKey, "server.profile.home")
        XCTAssertEqual(ConnectionProfile.tailscale.storageKey, "server.profile.tailscale")
        XCTAssertEqual(AppStorageKeys.chatSession("phone"), "spaces.chat.phone")
        XCTAssertEqual(AppStorageKeys.chatDraft(AppStorageKeys.chatSession("phone")), "spaces.chat.phone.draft")
        XCTAssertEqual(AppStorageKeys.pendingVideo("192.168.1.42"), "pending.192.168.1.42")
        XCTAssertEqual(AppStorageKeys.dashboardJobs("192.168.1.42"), "dashboard.jobs.192.168.1.42")
        XCTAssertEqual(AppStorageKeys.botDraft(nil), "village.botDraft.new")
        XCTAssertEqual(AppStorageKeys.botDraft(botID), "village.botDraft.E594D46C-8FC9-457C-9E0D-98C22533B810")
        XCTAssertEqual(AppStorageKeys.pcModel(nil), "pc.chat.model.offline")
        XCTAssertEqual(AppStorageKeys.pcModel("fixture-pc"), "pc.chat.model.fixture-pc")
    }

    func testNotificationPreferencesMatchRuntimeLookups() {
        XCTAssertEqual(AppStorageKeys.notificationsEnabled("code"), AppStorageKeys.notificationsEnabledCode)
        XCTAssertEqual(AppStorageKeys.notificationsEnabled("video"), AppStorageKeys.notificationsEnabledVideo)
        XCTAssertEqual(AppStorageKeys.notificationsEnabled("video-failed"), AppStorageKeys.notificationsEnabledVideoFailed)
        XCTAssertEqual(AppStorageKeys.notificationsEnabled("image-model"), AppStorageKeys.notificationsEnabledImageModel)
        XCTAssertNotEqual(AppStorageKeys.notificationsActive("video", server: "192.168.1.42"),
                          AppStorageKeys.notificationsActive("video", server: "100.64.1.42"))
    }
}
