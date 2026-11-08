// Covers the video POST boundary with a deterministic URLSession fixture.
import Foundation
import XCTest
@testable import SweatCaster

final class ModelSubmitTests: XCTestCase {
    @MainActor func testCancellationBeforePostDoesNotRequireReview() async throws {
        let fixture = try await makeModel(host: "192.168.10.41")
        defer { fixture.cleanup() }
        let model = fixture.model
        XCTAssertTrue(model.canSubmit)
        let before = SubmitURLProtocol.posts.count(for: model.address)

        let attempt = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return await model.submit(.hype)
        }
        let accepted = await attempt.value

        XCTAssertFalse(accepted)
        XCTAssertTrue(model.canSubmit)
        XCTAssertFalse(model.requiresVideoReview)
        XCTAssertNil(model.error)
        XCTAssertNil(fixture.defaults.object(forKey: AppStorageKeys.pendingVideo(model.address)))
        XCTAssertEqual(SubmitURLProtocol.posts.count(for: model.address), before)
    }

    @MainActor func testCancellationAfterPostBlocksAnotherAttemptUntilReview() async throws {
        let fixture = try await makeModel(host: "192.168.10.42")
        defer { fixture.cleanup() }
        let model = fixture.model
        let before = SubmitURLProtocol.posts.count(for: model.address)

        let accepted = await model.submit(.hype)
        XCTAssertFalse(accepted)
        XCTAssertFalse(model.uncertain)
        XCTAssertTrue(model.requiresVideoReview)
        XCTAssertFalse(model.canSubmit)
        XCTAssertNil(model.error)
        XCTAssertTrue(fixture.defaults.bool(forKey: AppStorageKeys.pendingVideo(model.address)))

        let duplicate = await model.submit(.hype)
        XCTAssertFalse(duplicate)
        XCTAssertEqual(SubmitURLProtocol.posts.count(for: model.address), before + 1)
        await model.acknowledgeAfterReview()
        XCTAssertFalse(model.requiresVideoReview)
        XCTAssertTrue(model.selected.isEmpty)
        XCTAssertNil(fixture.defaults.object(forKey: AppStorageKeys.pendingVideo(model.address)))
    }

    @MainActor func testAcceptedBatchPublishesJobsAndClearsSelectionAndAttempt() async throws {
        let fixture = try await makeModel(host: "192.168.10.44")
        defer { fixture.cleanup() }
        let model = fixture.model
        let before = SubmitURLProtocol.posts.count(for: model.address)

        let accepted = await model.submit(.hype)
        XCTAssertTrue(accepted)
        XCTAssertEqual(SubmitURLProtocol.posts.count(for: model.address), before + 1)
        XCTAssertEqual(model.jobs.map(\.id), ["job-example"])
        XCTAssertEqual(model.jobs.map(\.status), [.queued])
        XCTAssertTrue(model.selected.isEmpty)
        XCTAssertFalse(model.requiresVideoReview)
        XCTAssertNil(fixture.defaults.object(forKey: AppStorageKeys.pendingVideo(model.address)))
    }

    @MainActor func testBusyResponseKeepsSelectionAndClearsAttempt() async throws {
        let fixture = try await makeModel(host: "192.168.10.43")
        defer { fixture.cleanup() }
        let model = fixture.model

        let accepted = await model.submit(.hype)
        XCTAssertFalse(accepted)
        guard case .http(503, _)? = model.error else { return XCTFail("Expected the PC busy response") }
        XCTAssertEqual(model.selected, Set(["clip-example"]))
        XCTAssertTrue(model.canSubmit)
        XCTAssertFalse(model.requiresVideoReview)
        XCTAssertNil(fixture.defaults.object(forKey: AppStorageKeys.pendingVideo(model.address)))
    }

    private struct Fixture {
        let model: Model
        let defaults: UserDefaults
        let suite: String
        let directory: URL

        func cleanup() {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    @MainActor private func makeModel(host: String) async throws -> Fixture {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SubmitURLProtocol.self]
        let api = try LiveAPI(server: Server(host), token: "fixture", configuration: configuration)
        let suite = "FadedAI.Tests.ModelSubmit.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defaults.set(host, forKey: Pairing.addressKey)
        let model = Model(api: api, defaults: defaults, videoStateDirectory: directory)
        model.pendingKey = AppStorageKeys.pendingVideo(host)
        await model.refresh()
        model.select([Clip(id: "clip-example", name: "test.mp4", duration_seconds: 3, width: 1920, height: 1080)])
        XCTAssertTrue(model.canSubmit)
        return Fixture(model: model, defaults: defaults, suite: suite, directory: directory)
    }

    private final class PostCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var counts: [String: Int] = [:]

        func count(for host: String) -> Int { lock.withLock { counts[host, default: 0] } }
        func record(_ host: String) { lock.withLock { counts[host, default: 0] += 1 } }
    }

    private final class SubmitURLProtocol: URLProtocol {
        static let posts = PostCounter()

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            guard let url = request.url else {
                client?.urlProtocol(self, didFailWithError: URLError(.badURL))
                return
            }
            if request.httpMethod == "POST", let host = url.host { Self.posts.record(host) }
            let result: (status: Int, body: String)
            switch (request.httpMethod ?? "", url.path) {
            case ("GET", "/api/v1/health"):
                result = (200, #"{"api_version":"1","status":"ok"}"#)
            case ("GET", "/api/v1/capabilities"):
                result = (200, #"{"moods":["hype"],"max_batch_size":10,"features":{"upload":false,"cancel":true,"range_preview":false},"dependencies":[]}"#)
            case ("GET", "/api/v1/jobs"):
                result = (200, #"{"jobs":[]}"#)
            case ("POST", "/api/v1/jobs") where url.host == "192.168.10.42":
                client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
                return
            case ("POST", "/api/v1/jobs") where url.host == "192.168.10.44":
                result = (202, """
                    {"jobs":[{"id":"job-example","clip_id":"clip-example","mood":"hype","status":"queued",
                    "progress":0,"message":"Waiting","warnings":[],"created_at":"2026-11-06T16:00:00Z",
                    "updated_at":"2026-11-06T16:00:00Z","output_url":null,"error":null}]}
                    """)
            case ("POST", "/api/v1/jobs"):
                result = (503, #"{"error":{"code":"DEPENDENCY_MISSING","message":"Busy"}}"#)
            default:
                result = (404, #"{"error":{"code":"NOT_FOUND","message":"Unknown path"}}"#)
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
}
