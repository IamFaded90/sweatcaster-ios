// Tests completion requests without showing real notifications or changing OS permissions.
import Foundation
import UserNotifications
import XCTest
@testable import SweatCaster

final class JobNotificationsTests: XCTestCase {
    @MainActor func testCompletionDeduplicatesByKindServerAndJob() async throws {
        let suite = "FadedAI.Tests.Notifications.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = JobNotifications()
        var requests: [UNNotificationRequest] = []
        for (kind, host) in [("video", "192.168.1.42"), ("video", "192.168.1.42"),
                             ("video", "100.64.1.42"), ("code", "192.168.1.42")] {
            await service.completed(kind: kind, server: host, id: "job-example", title: "Klar", defaults: defaults,
                                    authorization: { .authorized }, add: { requests.append($0) })
        }

        XCTAssertEqual(requests.map(\.identifier), ["video:192.168.1.42:job-example",
                                                    "video:100.64.1.42:job-example", "code:192.168.1.42:job-example"])
        XCTAssertEqual(requests.map(\.content.categoryIdentifier), ["fadedai.video", "fadedai.video", "fadedai.code"])
        XCTAssertEqual(requests.map(\.content.title), ["Klar", "Klar", "Klar"])
        XCTAssertEqual(defaults.stringArray(forKey: AppStorageKeys.notificationsSentV1), requests.map(\.identifier))
    }

    @MainActor func testDisabledAndDeniedDoNotConsumeCompletion() async throws {
        let suite = "FadedAI.Tests.Notifications.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = JobNotifications()
        let enabledKey = AppStorageKeys.notificationsEnabledVideo
        var authorizationChecks = 0
        var additions = 0

        defaults.set(false, forKey: enabledKey)
        await service.completed(kind: "video", server: "192.168.1.42", id: "job-example", title: "Klar", defaults: defaults,
                                authorization: { authorizationChecks += 1; return .authorized }, add: { _ in additions += 1 })
        XCTAssertEqual(authorizationChecks, 0)
        XCTAssertEqual(additions, 0)

        defaults.set(true, forKey: enabledKey)
        await service.completed(kind: "video", server: "192.168.1.42", id: "job-example", title: "Klar", defaults: defaults,
                                authorization: { .denied }, add: { _ in additions += 1 })
        XCTAssertEqual(additions, 0)
        XCTAssertNil(defaults.stringArray(forKey: AppStorageKeys.notificationsSentV1))

        await service.completed(kind: "video", server: "192.168.1.42", id: "job-example", title: "Klar", defaults: defaults,
                                authorization: { .provisional }, add: { _ in additions += 1 })
        XCTAssertEqual(additions, 1)
    }

    @MainActor func testFailedSchedulingReleasesTheDeduplicationMarker() async throws {
        let suite = "FadedAI.Tests.Notifications.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = JobNotifications()

        await service.completed(kind: "code", server: "192.168.1.42", id: "job-example", title: "Klar", defaults: defaults,
                                authorization: { .authorized }, add: { _ in throw CancellationError() })
        XCTAssertEqual(defaults.stringArray(forKey: AppStorageKeys.notificationsSentV1), [])

        var requests: [UNNotificationRequest] = []
        await service.completed(kind: "code", server: "192.168.1.42", id: "job-example", title: "Klar", defaults: defaults,
                                authorization: { .authorized }, add: { requests.append($0) })
        XCTAssertEqual(requests.map(\.identifier), ["code:192.168.1.42:job-example"])
    }
}
