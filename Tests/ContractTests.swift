import XCTest
@testable import SweatCaster

extension ContractTests {
    func testSearchFindsChatBotVideoAndFile() {
        let input: [FadedSearchRecord] = [
            .init(id: "chat", category: .chat, title: "Træning i morgen", destination: .chat(query: "Træning")),
            .init(id: "bot", category: .bot, title: "Scout", keywords: "træning", destination: .bot(id: UUID())),
            .init(id: "video", category: .video, title: "Træningsklip", destination: .video(jobID: "test-video")),
            .init(id: "file", category: .file, title: "Plan.md", detail: "træning", destination: .file(path: "Plan.md")),
        ]
        let matches = FadedSearchIndex(records: input).matches("TRÆNING")
        XCTAssertEqual(Set(matches.map(\.category)), Set([.chat, .bot, .video, .file]))
        XCTAssertTrue(FadedSearchIndex(records: input).matches(" ").isEmpty)
    }
}

final class ContractTests: XCTestCase {
    func testPairingQRRecognizesLocalAndTailscaleProfiles() throws {
        let home = try PairingQRCode.parse(#"{"version":1,"address":"192.168.1.42","token":"fixture-token"}"#)
        let remote = try PairingQRCode.parse(#"{"version":1,"address":"100.64.1.42","token":"fixture-token"}"#)
        XCTAssertEqual(try Server(home.address).profile, .home)
        XCTAssertEqual(try Server(remote.address).profile, .tailscale)
    }

    func testPairingQRRejectsPublicAddressesAndHeaderInjection() {
        for payload in [
            #"{"version":1,"address":"8.8.8.8","token":"fixture-token"}"#,
            #"{"version":1,"address":"http://192.168.1.42:8765/api/v1?token=x","token":"fixture-token"}"#,
            #"{"version":1,"address":"192.168.1.42","token":"a\r\nb"}"#,
            #"{"version":2,"address":"192.168.1.42","token":"fixture-token"}"#,
        ] { XCTAssertThrowsError(try PairingQRCode.parse(payload)) }
    }

    func testCodeBotRemovesOnlyOuterMarkdownFence() throws {
        let object = #"{"content":"keep ``` inside"}"#
        for reply in [object, "```json\n\(object)\n```", "```JSON\r\n\(object)\r\n```"] {
            let value = try JSONDecoder().decode([String: String].self, from: ModelJSON.payload(reply))
            XCTAssertEqual(value["content"], "keep ``` inside")
        }
        XCTAssertThrowsError(try JSONDecoder().decode([String: String].self, from: ModelJSON.payload("```json\n\(object)")))
    }

    func testRenderingStopsDirectV2ChatBeforeTheLLMRequest() async throws {
        let api = try stubAPI(address: "192.168.1.21")
        do {
            try await api.v2Chat(V2ChatRequest(message: "Hej")) { _ in XCTFail("Unexpected chat stream") }
            XCTFail("Expected the PC-busy error")
        } catch let APIError.http(status, _) {
            XCTAssertEqual(status, 503)
        }
    }
    func testModuleManifestRestrictsUntrustedTabDefinitions() throws {
        let json = #"{"version":1,"tabs":[{"id":"cards","title":"Kortsamling","kind":"cards"},{"id":"../health","title":"Sikkerhed","kind":"information"},{"id":"script","title":"Ny","kind":"web"}]}"#
        let manifest = try JSONDecoder().decode(ModuleManifest.self, from: Data(json.utf8))
        XCTAssertEqual(manifest.version, 1)
        XCTAssertEqual(manifest.tabs.filter(\.supported).map(\.id), ["cards"])
    }

    func testShortModuleIDsUseAuthenticatedModuleRoutes() async throws {
        let api = try stubAPI()
        let cards = try await api.moduleCards("cards")
        let information = try await api.moduleInformation("a")
        XCTAssertTrue(cards.cards.isEmpty)
        XCTAssertEqual(information.text, "Lokal information")
        do {
            _ = try await api.moduleInformation("../health")
            XCTFail("Expected a rejected module ID")
        } catch V2Failure.invalidInput {}
    }

    func testClipKeepsV1ShapeAndAcceptsFutureFolderMetadata() throws {
        let old = try JSONDecoder().decode(Clip.self, from: Data(#"{"id":"clip-one","name":"game.mp4","duration_seconds":12,"width":1920,"height":1080}"#.utf8))
        XCTAssertNil(old.folderName)
        XCTAssertNil(old.timestamp)
        let newer = try JSONDecoder().decode(Clip.self, from: Data(#"{"id":"clip-two","name":"match.mp4","duration_seconds":15,"width":1920,"height":1080,"folderName":"Fortnite","timestamp":"2026-11-08T12:00:00Z"}"#.utf8))
        XCTAssertEqual(newer.folderName, "Fortnite")
    }
    func testV2GameFoldersDecodeWithoutChangingClipIDs() throws {
        let roots = try JSONDecoder().decode(V2ClipRoots.self, from: Data(#"{"roots":[{"id":"0","label":"Fortnite","file_count":101,"ready":true,"indexing":false}]}"#.utf8))
        XCTAssertEqual(roots.roots.first?.label, "Fortnite")
        let page = try JSONDecoder().decode(V2ClipPage.self, from: Data(#"{"root_id":"0","label":"Fortnite","clips":[{"id":"opaque123","name":"fight.mp4","duration_seconds":25,"width":1920,"height":1080}],"next_cursor":null,"ready":true,"indexing":false}"#.utf8))
        XCTAssertEqual(page.clips.first?.id, "opaque123")
        XCTAssertNil(page.clips.first?.folderName)
    }
    func testOldBotProfilesRemainReadableAfterProfileUpgrade() throws {
        let data = Data(#"{"id":"7C9E6679-7425-40DE-944B-E07FC1F90AE7","name":"Nova","color":"Blå","prompt":"Vær varm","voice":"da-DK","sprite":null,"personality":"Omsorgsfuld"}"#.utf8)
        let bot = try JSONDecoder().decode(VillageBot.self, from: data)
        XCTAssertEqual(bot.name, "Nova")
        XCTAssertEqual(bot.notifications ?? true, true)
        XCTAssertEqual(bot.voiceRate ?? 1.0, 1.0)
    }

    func testPCImageFallbackUsesAuthenticatedPNGRoute() async throws {
        let api = try stubAPI()
        let data = try await api.v2GenerateImage(prompt: "Blue star")
        XCTAssertTrue(data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]))
    }

    func testCodeWorkspaceContractModelsDecode() throws {
        let snapshot = try JSONDecoder().decode(V2CodeWorkspace.self, from: Data(#"""
        {"files":[{"path":"notes/plan.md","size":42,"updated_at":"2026-11-07T09:00:00Z"}],"max_files":100}
        """#.utf8))
        XCTAssertEqual(snapshot.files.first?.path, "notes/plan.md")
        XCTAssertEqual(snapshot.max_files, 100)

        let proposal = try JSONDecoder().decode(V2CodeProposal.self, from: Data(#"""
        {"change_id":"7c9e6679-7425-40de-944b-e07fc1f90ae7","path":"notes/plan.md","diff":"--- før","requires_approval":true}
        """#.utf8))
        XCTAssertTrue(proposal.requires_approval)
        XCTAssertEqual(proposal.path, "notes/plan.md")
    }

    func testPhoneRoutingKeepsPCWorkAndLongContextOnServer() {
        XCTAssertFalse(PhoneModels.prefersPC("Hvad er fotosyntese?", previousCharacters: 0))
        XCTAssertTrue(PhoneModels.prefersPC("Lav et roast-klip af den nyeste optagelse", previousCharacters: 0))
        XCTAssertTrue(PhoneModels.prefersPC("Fortsæt", previousCharacters: 3_000))
    }
    func testV2ChatKeepsQueueStatusAndCompletionMetadata() throws {
        let stream = """
        data: {"type":"tool_status","content":"Venter på modelplads."}

        data: {"type":"text","content":"Kort svar."}

        data: {"type":"done","content":"","message_id":"msg-1","model_id":"qwen25-7b"}


        """
        var parser = V2ChatParser()
        var events: [V2ChatEvent] = []
        for byte in stream.utf8 {
            if let event = try parser.feed(byte) { events.append(event) }
        }
        XCTAssertEqual(events.map(\.type), [.tool_status, .text, .done])
        XCTAssertEqual(events.last?.model_id, "qwen25-7b")
        XCTAssertEqual(events.last?.message_id, "msg-1")
        XCTAssertNil(events.last?.usage)
        XCTAssertNoThrow(try parser.end())
        XCTAssertThrowsError(try V2ChatParser().end())
    }

    func testV2ChatRequestEncodesOnlySupportedFields() throws {
        let request = try V2ChatRequest(message: "  Hej  ", sessionID: "phone-1")
        let body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request))
        let fields = try XCTUnwrap(body as? [String: Any])
        XCTAssertEqual(Set(fields.keys), ["message", "session_id", "request_id"])
        XCTAssertEqual(fields["message"] as? String, "Hej")
        XCTAssertThrowsError(try V2ChatRequest(message: " ", sessionID: "phone-1"))
        XCTAssertThrowsError(try V2ChatRequest(message: "Hej", sessionID: "phone/1"))
    }
    func testTailscaleRangeAndPublicAddressRejection() throws {
        for ip in ["100.64.0.0", "100.100.1.5", "100.127.255.255"] {
            XCTAssertEqual(try Server(ip).profile, .tailscale)
            XCTAssertEqual(try Server("http://\(ip):8765/api/v1").profile, .tailscale)
        }
        for ip in ["100.63.255.255", "100.128.0.0", "100.1.2.3", "8.8.8.8"] {
            XCTAssertThrowsError(try Server(ip))
        }
        XCTAssertEqual(try Server("192.168.1.50").profile, .home)
    }

    @MainActor func testLegacyHomeAddressMigratesWithoutReplacingExternalProfile() throws {
        let suite = "Tests.profiles.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("192.168.1.50", forKey: Pairing.addressKey)
        defaults.set("100.100.1.5", forKey: ConnectionProfile.tailscale.storageKey)
        let model = Model(api: MockAPI(), defaults: defaults)
        XCTAssertEqual(model.activeProfile, .home)
        XCTAssertEqual(model.savedAddresses[.home], "192.168.1.50")
        XCTAssertEqual(model.savedAddresses[.tailscale], "100.100.1.5")
    }
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
        let cases: [(Int, ChatFailure)] = [
            (401, .unauthorized), (403, .originRejected), (422, .invalidRequest),
            (503, .rejected), (200, .rejected)
        ]
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

    @MainActor func testBulkClipSelectionCanBeCleared() async {
        let model = Model(api: MockAPI())
        await model.refresh()
        model.select(model.clips)
        XCTAssertEqual(model.selected.count, min(model.clips.count, model.capabilities?.limit ?? 0))
        model.clearSelection()
        XCTAssertTrue(model.selected.isEmpty)
    }

    @MainActor func testV2FolderSelectionSurvivesLiveRefreshAndStartsV1Batch() async throws {
        let api = try stubAPI()
        let suite = "Tests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = Model(api: api, defaults: defaults)
        await model.refresh()
        XCTAssertTrue(model.connected, "The stub V1 clip listing returns malformed JSON and must not run on refresh")
        XCTAssertTrue(model.clips.isEmpty)

        let folder = try await api.v2ClipPage(rootID: "2")
        model.select(folder.clips)
        await model.refresh()
        XCTAssertEqual(model.selected, Set(["clip-one", "clip-two"]))

        let unsupported = await model.submit(.roast)
        XCTAssertFalse(unsupported)
        let accepted = await model.submit(.hype)
        XCTAssertTrue(accepted)
        XCTAssertEqual(model.jobs.map(\.clip_id), ["clip-one", "clip-two"])
        XCTAssertTrue(model.selected.isEmpty)
    }

    @MainActor func testOfflineVideoDraftAndClaimSurviveRelaunch() async throws {
        for host in ["192.168.1.20", "192.168.1.24"] {
            let api = try stubAPI(address: host)
            let suite = "Tests.\(UUID())"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
            defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
            defaults.set(host, forKey: Pairing.addressKey)

            let first = Model(api: api, defaults: defaults, videoStateDirectory: directory)
            await first.refresh()
            let folder = try await api.v2ClipPage(rootID: "2")
            first.includeFolderClips(folder.clips, folderID: folder.root_id)
            first.select(folder.clips)
            first.rememberVideoFolder(folder.root_id)
            first.rememberVideoMood(.roast)

            let offline = Model(api: api, defaults: defaults, videoStateDirectory: directory)
            XCTAssertEqual(offline.selected, Set(["clip-one", "clip-two"]))
            XCTAssertEqual(offline.lastVideoFolder, "2")
            XCTAssertEqual(offline.lastVideoMood, .roast)
            XCTAssertTrue(offline.queueVideoOffline(.hype))
            XCTAssertTrue(offline.selected.isEmpty)

            let reconnecting = Model(api: api, defaults: defaults, videoStateDirectory: directory)
            XCTAssertEqual(reconnecting.videoOutbox.first?.state, .waiting)
            await reconnecting.refresh()
            let before = Stub.timedOutVideoPosts.count
            await reconnecting.deliverQueuedVideos()
            if host == "192.168.1.24" {
                XCTAssertTrue(reconnecting.uncertain)
                XCTAssertEqual(reconnecting.videoOutbox.first?.state, .attempted)
                let reopened = Model(api: api, defaults: defaults, videoStateDirectory: directory)
                await reopened.refresh()
                await reopened.deliverQueuedVideos()
                XCTAssertTrue(reopened.uncertain)
                XCTAssertEqual(Stub.timedOutVideoPosts.count, before + 1)
                await reopened.acknowledgeAfterReview()
                XCTAssertTrue(reopened.videoOutbox.isEmpty)
            } else {
                XCTAssertEqual(reconnecting.jobs.map(\.clip_id), ["clip-one", "clip-two"])
                XCTAssertTrue(reconnecting.videoOutbox.isEmpty)
            }
            defaults.set("192.168.1.25", forKey: Pairing.addressKey)
            let other = Model(api: try stubAPI(address: "192.168.1.25"), defaults: defaults, videoStateDirectory: directory)
            XCTAssertTrue(other.selected.isEmpty)
            XCTAssertTrue(other.videoOutbox.isEmpty)
            XCTAssertNil(other.lastVideoFolder)
        }
    }

    @MainActor func testIncompatibleVersionPreventsSubmission() async {
        let model = Model(api: UncertainAPI(version: "2"))
        await model.refresh()
        guard case .version? = model.error else { return XCTFail("Expected version error") }
        XCTAssertFalse(model.canSubmit)
    }

    private func stubAPI(address: String = "192.168.1.20") throws -> LiveAPI {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Stub.self]
        return try LiveAPI(server: Server(address), token: "test-only-token", configuration: configuration)
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
    static let timedOutVideoPosts = RequestCounter()
    static let timedOutChatPosts = RequestCounter()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        let auth = request.value(forHTTPHeaderField: "Authorization")
        if url.host == "192.168.1.24", url.path == "/api/v1/jobs", request.httpMethod == "POST" {
            Self.timedOutVideoPosts.increment()
            client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
            return
        }
        if url.host == "192.168.1.27", url.path == "/api/v2/chat", request.httpMethod == "POST", auth == "Bearer test-only-token" {
            Self.timedOutChatPosts.increment()
            client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
            return
        }
        if url.path == "/api/v2/images/generate", request.httpMethod == "POST",
           auth == "Bearer test-only-token", request.url?.host == "192.168.1.20" {
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                           headerFields: ["Content-Type": "image/png"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data([137, 80, 78, 71, 13, 10, 26, 10, 0]))
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let status: Int
        let body: String
        var mime = "application/json"
        if url.path == "/api/v1/health", auth == nil {
            status = 200; body = #"{"api_version":"1","status":"ok"}"#
        } else if auth != "Bearer test-only-token" {
            status = 500; body = "{}"
        } else if url.path == "/api/modules/v1/tabs/cards", request.httpMethod == "GET" {
            status = 200; body = #"{"cards":[]}"#
        } else if url.path == "/api/modules/v1/tabs/a", request.httpMethod == "GET" {
            status = 200; body = #"{"text":"Lokal information"}"#
        } else if url.path == "/api/v1/capabilities" {
            status = 200
            body = #"{"moods":["hype"],"max_batch_size":10,"features":{"upload":false,"cancel":true,"range_preview":false},"dependencies":[]}"#
        } else if url.path == "/api/v2/clips", url.query == "root_id=2&limit=100" {
            status = 200
            body = #"{"root_id":"2","label":"Fortnite","clips":[{"id":"clip-one","name":"one.mp4","duration_seconds":10,"width":1920,"height":1080},{"id":"clip-two","name":"two.mp4","duration_seconds":20,"width":1920,"height":1080}],"next_cursor":null,"ready":true,"indexing":false}"#
        } else if url.path == "/api/v2/models", url.host == "192.168.1.27" {
            status = 200
            body = #"{"default_model_id":"qwen","models":[{"id":"qwen","label":"Qwen","available":true,"loaded":true,"capabilities":["chat"]}]}"#
        } else if url.path == "/api/v1/clips" {
            status = 200; body = "bad JSON"
        } else if url.path == "/api/v1/jobs", request.httpMethod == "GET" {
            status = 200
            body = url.host == "192.168.1.21" ? #"{"jobs":[{"id":"job-render","clip_id":"clip-one","mood":"hype","status":"rendering","progress":0.8,"message":"Rendering","warnings":[],"created_at":"2026-11-06T16:00:00Z","updated_at":"2026-11-06T16:00:00Z","output_url":null,"error":null}]}"# : #"{"jobs":[]}"#
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

private final class RequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func increment() { lock.withLock { value += 1 } }
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

extension ContractTests {
    func testWorkspacePatchEditsLongFileWithoutChangingOtherLines() throws {
        let before = Array(repeating: "// eksisterende linje\r\n", count: 110).joined()
        let source = before + "let value = 3\r\nlet stillHere = true\r\n"
        let context = try WorkspacePatch.context(goal: "Set value to 4", path: "File.swift",
                                                 source: source, firstLine: 111)
        XCTAssertEqual(context.lines, 110..<112)
        XCTAssertLessThanOrEqual(context.prompt.unicodeScalars.count, 2_000)
        let diff = """
        --- a/File.swift
        +++ b/File.swift
        @@ -111,2 +111,2 @@
        -let value = 3
        +let value = 4
         let stillHere = true
        """
        let patched = try WorkspacePatch.applying(diff, to: source, path: "File.swift", within: context.lines)
        XCTAssertEqual(Array(patched.utf8), Array((before + "let value = 4\r\nlet stillHere = true\r\n").utf8))
    }

    func testWorkspacePatchPreservesMissingFinalNewline() throws {
        let diff = #"""
        --- a/File.txt
        +++ b/File.txt
        @@ -2 +2 @@
        -gammel
        \ No newline at end of file
        +ny
        \ No newline at end of file
        """#
        XCTAssertEqual(try WorkspacePatch.applying(diff, to: "behold\ngammel", path: "File.txt", within: 1..<2),
                       "behold\nny")
    }

    func testWorkspacePatchRejectsWrongPathRangeAndContext() {
        let diff = "--- a/File.txt\n+++ b/File.txt\n@@ -2 +2 @@\n-gammel\n+ny\n"
        for (source, path, window) in [
            ("behold\ngammel\n", "Other.txt", 1..<2),
            ("behold\ngammel\n", "File.txt", 0..<1),
            ("behold\nændret\n", "File.txt", 1..<2),
        ] {
            XCTAssertThrowsError(try WorkspacePatch.applying(diff, to: source, path: path, within: window))
        }
        let invalidCount = diff.replacingOccurrences(of: "+2 @@", with: "+2,2 @@")
        XCTAssertThrowsError(try WorkspacePatch.applying(invalidCount, to: "behold\ngammel\n", path: "File.txt", within: 1..<2))
        XCTAssertThrowsError(try WorkspacePatch.applying(diff + diff, to: "behold\ngammel\n", path: "File.txt", within: 1..<2))
    }

    func testWorkspacePatchSupportsZeroCountInsertionAndMultipleHunks() throws {
        let diff = """
        --- a/File.txt
        +++ b/File.txt
        @@ -0,0 +1 @@
        +prefix
        @@ -3 +4 @@
        -third
        +new
        """
        XCTAssertEqual(try WorkspacePatch.applying(diff, to: "first\nsecond\nthird\n",
                                                  path: "File.txt", within: 0..<3), "prefix\nfirst\nsecond\nnew\n")
    }
}

extension ContractTests {
    func testGrokRequestUsesOnlyFixedHTTPSAndDisablesResponseStorage() throws {
        let key = "fixture-cloud-secret"
        let request = try GrokAPI.request(input: [.init(role: .user, content: "Test \(key)")], key: key)
        XCTAssertEqual(request.url?.absoluteString, "https://api.x.ai/v1/responses")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(key)")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "text/event-stream")
        let bytes = try XCTUnwrap(request.httpBody)
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "grok-4.7")
        XCTAssertEqual(body["store"] as? Bool, false)
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual((body["input"] as? [[String: String]])?.first?["content"], "Test [skjult]")
        XCTAssertThrowsError(try GrokAPI.request(input: [], key: "bad\nheader"))
    }

    func testGrokParserStreamsUnicodeAndRequiresCompletion() throws {
        let frames = "event: response.created\r\ndata: {\"type\":\"response.created\"}\r\n\r\n"
            + "data: {\"type\":\"future_event\",\"delta\":{}}\n\n"
            + "data: {\"type\":\"response.output_text.delta\",\"delta\":\"Hej æøå\"}\r\n\r\n"
        var parser = GrokResponsesParser()
        let chunks = try frames.utf8.compactMap { try parser.feed($0) }
        XCTAssertEqual(chunks, ["Hej æøå"])
        XCTAssertThrowsError(try parser.end()) { XCTAssertEqual($0 as? GrokFailure, .interrupted) }
        for byte in "data: {\"type\":\"response.completed\"}\n\n".utf8 { _ = try parser.feed(byte) }
        XCTAssertNoThrow(try parser.end())
    }

    func testGrokInterruptionsAndStreamingKeyRedaction() throws {
        var parser = GrokResponsesParser()
        XCTAssertThrowsError(try "data: {\"type\":\"response.incomplete\"}\n\n".utf8.forEach { _ = try parser.feed($0) }) {
            XCTAssertEqual($0 as? GrokFailure, .interrupted)
        }
        XCTAssertEqual(GrokAPI.redacted("Hej, fixture-", key: "fixture-secret", streaming: true), "Hej, ")
        XCTAssertEqual(GrokAPI.redacted("Hej, fixture-secret", key: "fixture-secret", streaming: false), "Hej, [skjult]")
    }
}

extension ContractTests {
    @MainActor func testPCChatOutboxClaimSurvivesRelaunchAndCannotReplay() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "queue.json")
        let first = PCChatOutbox(file: file)
        let home = "192.168.1.42"
        let external = "100.64.1.42"
        let session = UUID()
        let record = try first.enqueue(address: home, prompt: "Søg", message: "Søg i noter", sessionID: session, modelID: "qwen")
        XCTAssertEqual(first.pendingCount(for: home), 1)
        XCTAssertEqual(first.pendingCount(for: external), 0)
        XCTAssertNil(try first.claim(record.id, for: external))
        let attempt = try XCTUnwrap(first.claim(record.id, for: home))
        let request = try attempt.request()
        XCTAssertEqual(request.request_id, record.id)
        XCTAssertEqual(request.session_id, session.uuidString)
        XCTAssertEqual(request.message, "Søg i noter")
        XCTAssertEqual(request.model_id, "qwen")

        let reopened = PCChatOutbox(file: file)
        XCTAssertNil(try reopened.claim(record.id, for: home))
        XCTAssertEqual(reopened.reviewCount(for: home), 1)
        XCTAssertEqual(try reopened.entries(for: home).first?.state, .attempted)
        try reopened.complete(record.id, for: home, reply: "Noterne er fundet.")
        XCTAssertNil(try reopened.claim(record.id, for: home))
        XCTAssertEqual(try reopened.entries(for: home).first?.reply, "Noterne er fundet.")
        XCTAssertEqual(try reopened.entries(for: home).first?.state, .completed)
    }

    @MainActor func testPCChatOutboxOnlyTreatsNetworkFailureAsOffline() {
        XCTAssertTrue(PCChatOutbox.confirmedOffline(.offline))
        XCTAssertTrue(PCChatOutbox.confirmedOffline(.transport(URLError.timedOut.rawValue)))
        XCTAssertFalse(PCChatOutbox.confirmedOffline(nil))
        XCTAssertFalse(PCChatOutbox.confirmedOffline(.token))
        XCTAssertFalse(PCChatOutbox.confirmedOffline(.http(503, nil)))
    }

    @MainActor func testPCChatOutboxDrainNeverRepeatsTimedOutPOST() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "queue.json")
        let address = "192.168.1.27"
        let api = try stubAPI(address: address)
        let outbox = PCChatOutbox(file: file)
        try outbox.enqueue(address: address, prompt: "Se jobbet", message: "Se jobbet", sessionID: UUID(), modelID: nil)
        let before = Stub.timedOutChatPosts.count
        await outbox.deliverReady(using: api)
        XCTAssertEqual(Stub.timedOutChatPosts.count - before, 1)
        let reopened = PCChatOutbox(file: file)
        XCTAssertEqual(reopened.reviewCount(for: address), 1)
        await reopened.deliverReady(using: api)
        XCTAssertEqual(Stub.timedOutChatPosts.count - before, 1)
    }
}
