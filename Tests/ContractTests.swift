import XCTest
@testable import SweatCaster

final class ContractTests: XCTestCase {
    func testSSEAcrossBytesAndLineEndings() throws {
        let frames = [
            ": heartbeat\r\n\r\n",
            "data: {\"type\":\"tool_status\",\r\ndata: \"content\":\"Søger…\"}\r\n\r\n",
            "data: {\"type\":\"future\",\"content\":\"ignored\"}\n\n",
            "data: {\"type\":\"text\",\"content\":\"Rød grød\"}\n\n",
            "data: {\"type\":\"done\",\"content\":\"do not append\"}\n\n",
            "data: {\"type\":\"text\",\"content\":\"too late\"}\n\n"
        ]
        var parser = ChatSSEParser()
        var events: [ChatEvent] = []
        for byte in frames.joined().utf8 {
            if let event = try parser.feed(byte) { events.append(event) }
        }
        XCTAssertEqual(events.map(\.type), ["tool_status", "text", "done"])
        XCTAssertEqual(events.prefix(2).map(\.content), ["Søger…", "Rød grød"])
        XCTAssertNoThrow(try parser.end())
    }

    func testChatEOFWithoutDoneIsInterrupted() throws {
        var parser = ChatSSEParser()
        for byte in "data: {\"type\":\"text\",\"content\":\"Delvist\"}\n\n".utf8 {
            _ = try parser.feed(byte)
        }
        XCTAssertThrowsError(try parser.end()) { XCTAssertEqual($0 as? ChatFailure, .interrupted) }
    }

    func testChatPOSTStopsLocallyDuringStream() async throws {
        let api = try stubAPI()
        let task = Task {
            try await api.chat(ChatRequest(message: "Hej", session_id: UUID())) { event in
                XCTAssertEqual(event.type, "tool_status")
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
        do {
            try await task.value
            XCTFail("Expected local cancellation")
        } catch is CancellationError {}
    }

    func testChatRejectsJSONAndMapsHTTPFailures() throws {
        XCTAssertNoThrow(try ChatFailure.validate(status: 200, mime: "text/event-stream"))
        let cases: [(Int, ChatFailure)] = [(401, .unauthorized), (503, .unavailable), (200, .rejected)]
        for (status, expected) in cases {
            XCTAssertThrowsError(try ChatFailure.validate(status: status, mime: "application/json")) {
                XCTAssertEqual($0 as? ChatFailure, expected)
            }
        }
    }

    @MainActor func testSavedLiveConnectionDoesNotFallBackToDemo() async throws {
        let suite = "Tests.live.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("unconfigured-test-address", forKey: Pairing.addressKey)
        let model = Model(defaults: defaults)
        await model.refresh()
        XCTAssertFalse(model.isDemo)
        XCTAssertTrue(model.clips.isEmpty)
        await model.useDemo()
        XCTAssertTrue(model.isDemo)
        XCTAssertFalse(model.clips.isEmpty)
    }
    private let fixture = """
    {"id":"job-example","clip_id":"clip-example","mood":"hype","status":"completed",
    "progress":1,"message":"Ready","warnings":[],"created_at":"2026-11-06T16:00:00Z",
    "updated_at":"2026-11-06T16:00:01.123Z","output_url":"/api/v1/jobs/job-example/video","error":null}
    """

    func testJobDecodingAndDates() throws {
        let job = try contractDecoder().decode(Job.self, from: Data(fixture.utf8))
        XCTAssertEqual(job.status, .completed)
        XCTAssertEqual(job.updated_at.timeIntervalSince(job.created_at), 1.123, accuracy: 0.001)
        XCTAssertFalse(job.status.active)
        XCTAssertThrowsError(try contractDecoder().decode(Job.self, from: Data("{}".utf8)))
    }

    func testOutputResolutionAndOriginRestriction() throws {
        let server = try Server("192.168.1.20")
        var job = try contractDecoder().decode(Job.self, from: Data(fixture.utf8))
        XCTAssertEqual(try server.videoURL(job).absoluteString,
                       "http://192.168.1.20:8765/api/v1/jobs/job-example/video")
        for path in ["//example.org/api/v1/jobs/job-example/video", "C:/out.mp4",
                     "/api/v1/jobs/other/video", "/api/v1/jobs/job-example/video?token=x"] {
            job.output_url = path
            XCTAssertThrowsError(try server.videoURL(job))
        }
        XCTAssertThrowsError(try Server("8.8.8.8"))
        XCTAssertThrowsError(try Server("192.168.1.20:8765"))
        XCTAssertEqual(try Server("http://192.168.1.20:8765/api/v1").address, server.address)
        XCTAssertThrowsError(try Server("http://8.8.8.8:8765/api/v1"))
        XCTAssertThrowsError(try Server("http://192.168.1.20:8765/api/v1?token=x"))
        XCTAssertThrowsError(try Server.segment("id/with?symbols"))
    }

    func testBatchValidation() throws {
        let options = Options()
        XCTAssertEqual(options.roi.y, 0.62)
        XCTAssertFalse(options.denoise)
        XCTAssertThrowsError(try Batch(clip_ids: ["short"], mood: .hype, options: options).validate(limit: 10))
        let batch = Batch(clip_ids: ["clip-first", "clip-second"], mood: .funnyNPC, options: options)
        XCTAssertNoThrow(try batch.validate(limit: 2))
        XCTAssertThrowsError(try batch.validate(limit: 1))
        XCTAssertThrowsError(try Batch(clip_ids: ["clip-first", "clip-first"], mood: .hype, options: options).validate(limit: 10))
        let bad = Options(roi: ROI(x: 0.8, y: 0, width: 0.5, height: 1))
        XCTAssertThrowsError(try Batch(clip_ids: ["clip-first"], mood: .hype, options: bad).validate(limit: 10))
        let data = try JSONEncoder().encode(batch)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["clip_ids"] as? [String], ["clip-first", "clip-second"])
        XCTAssertEqual(json["mood"] as? String, "funny_npc")
    }

    func testMockJobsRunInSequenceAndCancellationIsIdempotent() async throws {
        let clock = TestClock()
        let api = MockAPI(now: { clock.date })
        let batch = Batch(clip_ids: ["demo-arena", "demo-final"], mood: .roast, options: Options())
        let jobs = try await api.submit(batch).jobs
        XCTAssertEqual(jobs.map(\.status), [.queued, .queued])
        clock.seconds = 4
        let mid = await api.jobs().jobs
        XCTAssertEqual(mid.map(\.status), [.queued, .synthesizing])
        XCTAssertEqual(mid[1].progress, 0.60)
        clock.seconds = 9
        let next = await api.jobs().jobs
        XCTAssertEqual(next.map(\.status), [.analyzing, .completed])
        XCTAssertNotNil(next[1].output_url)
        let stopped = try await api.cancel(jobs[1].id)
        let repeated = try await api.cancel(jobs[1].id)
        XCTAssertEqual(stopped.status, .cancelled)
        XCTAssertEqual(repeated.updated_at, stopped.updated_at)
    }

    func testHTTPHeadersAndErrorEnvelopes() async throws {
        let api = try stubAPI()
        let health = try await api.health()
        XCTAssertEqual(health.api_version, "1")
        for code in [401, 404, 409, 422, 503] {
            do {
                _ = try await api.job("http-status-\(code)")
                XCTFail("Expected HTTP failure")
            } catch APIError.http(let actual, let problem) {
                XCTAssertEqual(actual, code)
                XCTAssertEqual(problem?.message, "[skjult]")
            }
        }
        do {
            _ = try await api.clips()
            XCTFail("Expected malformed JSON")
        } catch APIError.malformed {}
    }

    func testPOSTUsesContractAndExpects202() async throws {
        let api = try stubAPI()
        let result = try await api.submit(Batch(clip_ids: ["clip-one", "clip-two"], mood: .hype, options: Options()))
        XCTAssertEqual(result.jobs.map(\.clip_id), ["clip-one", "clip-two"])
        XCTAssertEqual(result.jobs.map(\.status), [.queued, .queued])
    }

    @MainActor func testAmbiguousBatchReconcilesWithoutRetry() async {
        let api = UncertainAPI()
        let suite = "Tests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = Model(api: api, defaults: defaults)
        await model.refresh()
        for clip in model.clips { model.toggle(clip) }
        XCTAssertTrue(model.canSubmit, "Optional demo dependencies must not block a batch")
        await model.submit(.hype)
        await model.submit(.hype)
        let submissions = await api.submissions
        let reads = await api.reads
        XCTAssertEqual(submissions, 1)
        XCTAssertEqual(reads, 2)
        XCTAssertTrue(model.uncertain)
        XCTAssertFalse(model.canSubmit)
        await model.acknowledgeAfterReview()
        XCTAssertFalse(model.uncertain)
        XCTAssertTrue(model.selected.isEmpty)
    }

    @MainActor func testIncompatibleVersionPreventsSubmission() async {
        let model = Model(api: UncertainAPI(version: "2"))
        await model.refresh()
        guard case .version? = model.error else { return XCTFail("Expected version error") }
        XCTAssertFalse(model.canSubmit)
    }

    private func stubAPI() throws -> LiveAPI {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Stub.self]
        return try LiveAPI(server: Server("192.168.1.20"), token: "test-only-token", configuration: configuration)
    }
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Double = 0
    var seconds: Double {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
    var date: Date { Date(timeIntervalSince1970: seconds) }
}

private final class Stub: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        let auth = request.value(forHTTPHeaderField: "Authorization")
        let status: Int
        let body: String
        var mime = "application/json"
        if url.path == "/api/v1/health", auth == nil {
            status = 200; body = #"{"api_version":"1","status":"ok"}"#
        } else if auth != "Bearer test-only-token" {
            status = 500; body = "{}"
        } else if url.path == "/api/v1/clips" {
            status = 200; body = "bad JSON"
        } else if url.path == "/api/v1/chat", request.httpMethod == "POST",
                  request.value(forHTTPHeaderField: "Accept") == "text/event-stream" {
            status = 200
            mime = "text/event-stream"
            body = "data: {\"type\":\"tool_status\",\"content\":\"Søger\"}\n\ndata: {\"type\":\"done\",\"content\":\"\"}\n\n"
        } else if url.path == "/api/v1/jobs", request.httpMethod == "POST",
                  request.value(forHTTPHeaderField: "Content-Type") == "application/json" {
            status = 202
            let jobs = ["clip-one", "clip-two"].map { id in
                """
                {"id":"job-\(id)","clip_id":"\(id)","mood":"hype","status":"queued","progress":0,
                "message":"Waiting","warnings":[],"created_at":"2026-11-06T16:00:00Z",
                "updated_at":"2026-11-06T16:00:00Z","output_url":null,"error":null}
                """
            }
            body = "{\"jobs\":[" + jobs.joined(separator: ",") + "]}"
        } else {
            status = Int(url.lastPathComponent.split(separator: "-").last ?? "") ?? 500
            body = #"{"error":{"code":"TEST","message":"test-only-token"}}"#
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil,
                                       headerFields: ["Content-Type": mime])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private actor UncertainAPI: SweatAPI {
    let version: String
    let mock = MockAPI()
    var submissions = 0
    var reads = 0
    init(version: String = "1") { self.version = version }
    func health() -> Health { Health(api_version: version, status: "ok") }
    func capabilities() async -> Capabilities { await mock.capabilities() }
    func clips() async -> Clips { await mock.clips() }
    func jobs() async -> Jobs { reads += 1; return await mock.jobs() }
    func job(_ id: String) async throws -> Job { try await mock.job(id) }
    func submit(_ batch: Batch) async throws -> Jobs {
        submissions += 1
        _ = try await mock.submit(batch)
        throw APIError.transport(URLError.timedOut.rawValue)
    }
    func cancel(_ id: String) async throws -> Job { try await mock.cancel(id) }
    func video(_ job: Job) async throws -> URL { try await mock.video(job) }
}
