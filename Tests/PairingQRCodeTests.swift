// Tests the scanner acceptance path separately from structural QR parsing.
import Foundation
import SwiftUI
import UIKit
import XCTest
@testable import SweatCaster

final class PairingQRCodeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_893_456_000)

    func testScannerUsesTheDisplayedFrameInPortraitAndLandscape() throws {
        let pairing = try qr(expiry: now.addingTimeInterval(90))
        for size in [CGSize(width: 390, height: 700), CGSize(width: 700, height: 320), CGSize(width: 180, height: 240)] {
            let screen = CGRect(origin: .zero, size: size)
            let target = PairingQRTarget.frame(in: screen)
            XCTAssertEqual(target.midX, screen.midX)
            XCTAssertEqual(target.midY, screen.midY)
            XCTAssertEqual(target.width, target.height)
            XCTAssertTrue(screen.contains(target))
            let centered = CGRect(x: target.midX - 20, y: target.midY - 20, width: 40, height: 40)
            let clipped = centered.offsetBy(dx: target.minX - centered.minX - 3, dy: 0)
            XCTAssertEqual(PairingQRTarget.select(in: target, from: [(pairing, clipped)]), .searching)
            XCTAssertEqual(PairingQRTarget.select(in: target, from: [("https://example.org", centered)]), .unrelated)
            XCTAssertEqual(PairingQRTarget.select(in: target, from: [("https://example.org", centered), (pairing, centered)]),
                           .match(pairing))
        }
        XCTAssertEqual(PairingQRTarget.select(in: .zero, from: [(pairing, .zero)]), .searching)
    }

    func testTwoPairingCodesRequireOneAtTheCenterRegardlessOfDetectionOrder() throws {
        let one = try qr(address: "192.168.1.40", expiry: now.addingTimeInterval(90))
        let two = try qr(address: "192.168.1.41", expiry: now.addingTimeInterval(90))
        let target = CGRect(x: 0, y: 0, width: 224, height: 224)
        let left = CGRect(x: 10, y: 85, width: 50, height: 50)
        let right = left.offsetBy(dx: 150, dy: 0)
        let center = left.offsetBy(dx: 80, dy: 0)
        XCTAssertEqual(PairingQRTarget.select(in: target, from: [(one, left), (two, right)]), .ambiguous)
        XCTAssertEqual(PairingQRTarget.select(in: target, from: [(one, center), (two, right)]), .match(one))
        XCTAssertEqual(PairingQRTarget.select(in: target, from: [(two, right), (one, center)]), .match(one))
    }

    @MainActor func testSelectionLeavesExpiryAndNonceChecksForFinalAcceptance() throws {
        let target = CGRect(x: 0, y: 0, width: 180, height: 180)
        let stale = try qr(expiry: now)
        let fresh = try qr(expiry: now.addingTimeInterval(20), nonce: UUID().uuidString)
        XCTAssertEqual(PairingQRTarget.select(in: target, from: [(stale, target)]), .match(stale))
        XCTAssertThrowsError(try PairingQRSession.accept(stale, now: now)) { error in
            guard case .pairingExpired? = error as? APIError else { return XCTFail("Expected expiry feedback") }
        }
        for _ in 0..<2 { XCTAssertEqual(PairingQRTarget.select(in: target, from: [(fresh, target)]), .match(fresh)) }
        XCTAssertNoThrow(try PairingQRSession.accept(fresh, now: now))
        XCTAssertThrowsError(try PairingQRSession.accept(fresh, now: now)) { error in
            guard case .replay? = error as? PairingQRSession.Failure else { return XCTFail("Expected nonce replay") }
        }
    }

    @MainActor func testCastUsesTheHomePairingWhenChatUsesTailscale() throws {
        let remote = try LiveAPI(server: Server("100.64.1.42"), token: "remote-fixture")
        let pairing = try XCTUnwrap(CastHomePairing(active: remote, savedHomeAddress: "192.168.1.20"))
        let home = try pairing.connection { address in
            XCTAssertEqual(address, "192.168.1.20")
            return "home-fixture"
        }
        XCTAssertEqual(home.server.profile, .home)
        XCTAssertEqual(home.request(home.server.endpoint("health")).value(forHTTPHeaderField: "Authorization"), "Bearer home-fixture")
        XCTAssertEqual(remote.server.profile, .tailscale)
        XCTAssertThrowsError(try pairing.connection { _ in throw APIError.storage })
        XCTAssertNil(CastHomePairing(active: remote, savedHomeAddress: "100.65.7.2"))
        XCTAssertNil(CastHomePairing(active: nil, savedHomeAddress: "192.168.1.20"))
        let alreadyHome = try XCTUnwrap(CastHomePairing(active: home, savedHomeAddress: nil))
        XCTAssertEqual(try alreadyHome.connection { _ in throw APIError.storage }.queueTargetID, home.queueTargetID)
    }

    @MainActor func testScannerAcceptsFractionalExpiryAndCanonicalizesAddress() throws {
        let expiry = now.addingTimeInterval(30.125)
        let payload = try PairingQRSession.accept(qr(address: "http://100.64.1.42:8765/api/v1", expiry: expiry), now: now)
        XCTAssertEqual(payload.address, "100.64.1.42")
        XCTAssertEqual(try Server(payload.address).profile, .tailscale)
        XCTAssertEqual(try XCTUnwrap(payload.expiresAt).timeIntervalSince(now), 30.125, accuracy: 0.001)
    }

    @MainActor func testScannerRejectsMissingPastAndExactExpiry() throws {
        for expiry in [nil, now.addingTimeInterval(-1), now] as [Date?] {
            let text = try qr(expiry: expiry)
            XCTAssertThrowsError(try PairingQRSession.accept(text, now: now)) { error in
                guard case .pairingExpired? = error as? APIError else { return XCTFail("Expected an expired QR code") }
            }
        }
    }

    @MainActor func testScannerRejectsReusedNonceEvenWhenAddressChanges() throws {
        let nonce = UUID().uuidString
        let expiry = now.addingTimeInterval(60)
        let first = try qr(expiry: expiry, nonce: nonce)
        let reused = try qr(address: "192.168.1.99", expiry: expiry, nonce: nonce)
        XCTAssertEqual(try PairingQRSession.accept(first, now: now).nonce, nonce)
        XCTAssertThrowsError(try PairingQRSession.accept(reused, now: now)) { error in
            guard case .replay? = error as? PairingQRSession.Failure else { return XCTFail("Expected a nonce replay") }
        }
    }

    @MainActor func testOptionalNonceAndInvalidTimestamp() throws {
        let valid = try qr(expiry: now.addingTimeInterval(60))
        XCTAssertNil(try PairingQRSession.accept(valid, now: now).nonce)
        XCTAssertNoThrow(try PairingQRSession.accept(valid, now: now))
        let invalid = #"{"version":1,"address":"192.168.1.42","token":"fixture","expiresAt":"tomorrow"}"#
        XCTAssertThrowsError(try PairingQRSession.accept(invalid, now: now))
    }

    @MainActor func testAcceptedQRReachesHomeAndOpensActivityAndVideoFolder() async throws {
        let suite = "FadedAI.Tests.QRNavigation.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let videoDirectory = FileManager.default.temporaryDirectory.appending(path: suite, directoryHint: .isDirectory)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: videoDirectory)
        }
        var savedAddress: String?
        let model = Model(defaults: defaults, videoStateDirectory: videoDirectory,
                          makePairingAPI: { server, token in
                              let configuration = URLSessionConfiguration.ephemeral
                              configuration.protocolClasses = [PairingNavigationProtocol.self]
                              return try LiveAPI(server: server, token: token, configuration: configuration)
                          }, storePairingToken: { token, address in
                              XCTAssertEqual(token, "fixture")
                              savedAddress = address
                          })
        let landing = expectation(description: "The unpaired app displays the landing screen")
        let home = expectation(description: "Hjem renders after successful PC pairing")
        let activity = expectation(description: "Seneste aktivitet renders after opening it from Hjem")
        let video = expectation(description: "The video shortcut displays the clip tab")
        let folders = expectation(description: "The Fortnite folder renders in the video catalog")
        let clips = expectation(description: "Opening the Fortnite folder displays the fetched clip")
        let screens: [Home.InitialScreen: XCTestExpectation] = [
            .landing: landing, .dashboard: home, .dashboardActivity: activity, .videoClips: video,
            .videoFolders: folders, .videoFolderClips: clips
        ]
        var seen: Set<Home.InitialScreen> = []
        var openActivity: (() -> Void)?
        let root = Home(model: model, onVideoFoldersAppeared: { $0 == "1" },
                        onDashboardAppeared: { openActivity = $0 }) { screen in
            if seen.insert(screen).inserted { screens[screen]?.fulfill() }
        }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        let previousWindow = scene?.windows.first { $0.isKeyWindow }
        let frame = scene?.coordinateSpace.bounds ?? CGRect(x: 0, y: 0, width: 440, height: 956)
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: frame)
        let hosting = UIHostingController(rootView: root.defaultAppStorage(defaults).environment(\.scenePhase, .active))
        window.frame = frame
        window.rootViewController = hosting
        // Xcode 26 no longer supports manually inserting a root controller's view.
        // Making the window visible lets UIKit own appearance transitions both in the
        // simulator and when this test has no foreground scene.
        window.makeKeyAndVisible()
        hosting.loadViewIfNeeded()
        hosting.view.setNeedsLayout()
        hosting.view.layoutIfNeeded()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKey()
        }
        await fulfillment(of: [landing], timeout: 8)
        XCTAssertEqual(seen, [.landing])

        let payload = try PairingQRSession.accept(
            qr(address: PairingNavigationProtocol.host, expiry: .now.addingTimeInterval(120), nonce: UUID().uuidString)
        )
        let server = try Server(payload.address)
        await model.saveProfile(server.profile, address: payload.address, token: payload.token,
                                pairingExpiresAt: payload.expiresAt)
        XCTAssertTrue(model.connected)
        XCTAssertFalse(model.needsPairing)
        XCTAssertNil(model.error)
        XCTAssertEqual(savedAddress, payload.address)
        await fulfillment(of: [home], timeout: 8)
        XCTAssertEqual(seen, [.landing, .dashboard])

        try XCTUnwrap(openActivity)()
        await fulfillment(of: [activity], timeout: 8)

        defaults.set("video", forKey: AppStorageKeys.spacesShortcut)
        await fulfillment(of: [video, folders, clips], timeout: 8)
        XCTAssertTrue(model.clips.contains { $0.id == "clip-001" && $0.name == "fixture.mp4" })
    }

    private func qr(address: String = "192.168.1.42", expiry: Date?, nonce: String? = nil) throws -> String {
        var fields: [String: Any] = ["version": 1, "address": address, "token": "fixture"]
        if let expiry {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            fields["expiresAt"] = formatter.string(from: expiry)
        }
        if let nonce { fields["nonce"] = nonce }
        let data = try JSONSerialization.data(withJSONObject: fields)
        return String(decoding: data, as: UTF8.self)
    }
}

private final class PairingNavigationProtocol: URLProtocol {
    static let host = "192.168.77.42"

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == host }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let result: (status: Int, body: String)
        switch url.path {
        case "/api/v1/health":
            result = (200, #"{"api_version":"1","status":"ok"}"#)
        case "/api/v1/capabilities":
            result = (200, #"{"moods":["hype"],"max_batch_size":10,"features":{"upload":false,"cancel":true,"range_preview":false},"dependencies":[]}"#)
        case "/api/v1/jobs":
            result = (200, #"{"jobs":[]}"#)
        case "/api/v2/clip-roots":
            result = (200, #"{"roots":[{"id":"1","label":"Fortnite","file_count":1,"ready":true,"indexing":false}]}"#)
        case "/api/v2/clips" where URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.contains(URLQueryItem(name: "root_id", value: "1")) == true:
            result = (200, #"{"root_id":"1","label":"Fortnite","clips":[{"id":"clip-001","name":"fixture.mp4","duration_seconds":20,"width":1920,"height":1080}],"ready":true,"indexing":false}"#)
        default:
            result = (404, #"{"error":{"code":"NOT_FOUND","message":"Unknown fixture path"}}"#)
        }
        guard let response = HTTPURLResponse(url: url, statusCode: result.status, httpVersion: nil,
                                             headerFields: ["Content-Type": "application/json"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(result.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
