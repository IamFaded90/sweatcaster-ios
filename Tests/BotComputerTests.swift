// Computer tasks stay one job across a double tap, a reopen, a cancel, a retry, and an offline PC.

import Foundation
import XCTest
@testable import SweatCaster

@MainActor final class BotComputerTests: XCTestCase {
    private let adam = "11111111-1111-4111-8111-111111111111"
    private let eva = "22222222-2222-4222-8222-222222222222"

    func testSameKeyDoesNotSubmitTwice() async throws {
        let transport = ScriptedComputer()
        let session = try makeSession(transport)
        let first = try await give(session, key: "key-adam-1")
        let second = try await give(session, key: "key-adam-1")
        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(session.office.tasks.count, 1)
        XCTAssertEqual(transport.submits, 1)
        await session.refresh(botID: adam)
        XCTAssertEqual(transport.submits, 1)
    }

    func testConcurrentTapsShareOneSubmission() async throws {
        let transport = ScriptedComputer()
        transport.delay = true
        let session = try makeSession(transport)
        async let first = give(session, key: "key-adam-2")
        async let second = give(session, key: "key-adam-2")
        let tasks = try await [first, second]
        XCTAssertEqual(tasks[0].id, tasks[1].id)
        XCTAssertEqual(transport.submits, 1)
    }

    func testResultSurvivesReopen() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = ScriptedComputer()
        let session = BotComputerSession(directory: directory, transport: transport, now: { 10 })
        let task = try await give(session, key: "key-adam-3")
        XCTAssertEqual(task.status, .done)
        XCTAssertEqual(task.resultText, "Rapport")
        let reopened = BotComputerSession(directory: directory, transport: OfflineBotComputerTransport(), now: { 20 })
        let stored = try XCTUnwrap(reopened.office.task(id: task.id))
        XCTAssertEqual(stored.status, .done)
        XCTAssertEqual(stored.resultText, "Rapport")
        let file = try reopened.office.open(readerID: adam, ownerID: adam, path: "opgave-test.txt")
        XCTAssertEqual(file.text, "Rapport")
    }

    func testCancelIsIdempotent() async throws {
        let transport = ScriptedComputer()
        transport.leaveWaiting = true
        let session = try makeSession(transport)
        let task = try await give(session, key: "key-adam-4")
        let cancelled = try await result(session.cancel(id: task.id))
        let again = try await result(session.cancel(id: task.id))
        XCTAssertEqual(cancelled.status, .cancelled)
        XCTAssertEqual(again.status, .cancelled)
        XCTAssertEqual(session.office.tasks.count, 1)
        XCTAssertEqual(transport.cancels, 1)
    }

    func testRetryAfterFailureSendsOneNewAttempt() async throws {
        let transport = ScriptedComputer()
        transport.failSubmit = true
        let session = try makeSession(transport)
        let failed = try await give(session, key: "key-adam-5")
        XCTAssertEqual(failed.status, .failed)
        let key = "retry-key1"
        let first = try await result(session.retry(id: failed.id, retryKey: key))
        let second = try await result(session.retry(id: failed.id, retryKey: key))
        XCTAssertEqual(first.attempt, 2)
        XCTAssertEqual(second.id, first.id)
        XCTAssertEqual(transport.retries, 1)
        XCTAssertEqual(session.office.tasks.count, 1)
    }

    func testOfflinePCAndDockerStayDistinctAndDoNotSend() async throws {
        let offline = ScriptedComputer()
        offline.healthLink = .pcOffline
        let phone = try makeSession(offline)
        let waiting = try await give(phone, key: "key-adam-6")
        XCTAssertEqual(waiting.status, .waiting)
        XCTAssertEqual(phone.office.link, .pcOffline)
        XCTAssertEqual(offline.submits, 0)
        XCTAssertEqual(phone.office.link.title, "PC’en er offline")

        let docker = ScriptedComputer()
        docker.healthLink = .dockerOffline
        let desk = try makeSession(docker)
        let held = try await give(desk, key: "key-adam-7")
        XCTAssertEqual(held.status, .waiting)
        XCTAssertEqual(desk.office.link, .dockerOffline)
        XCTAssertEqual(docker.submits, 1)
        _ = try await give(desk, key: "key-adam-7")
        XCTAssertEqual(docker.submits, 1)
        XCTAssertEqual(desk.office.tasks.count, 1)
        XCTAssertEqual(desk.office.link.title, "Docker er offline")
        XCTAssertNotEqual(phone.office.link.title, desk.office.link.title)
    }

    func testReconnectSendsTheWaitingTaskOnce() async throws {
        let transport = ScriptedComputer()
        transport.healthLink = .pcOffline
        let session = try makeSession(transport)
        _ = try await give(session, key: "key-adam-8")
        XCTAssertEqual(transport.submits, 0)
        transport.healthLink = .online
        await session.refresh(botID: adam)
        await session.refresh(botID: adam)
        XCTAssertEqual(transport.submits, 1)
        XCTAssertEqual(session.office.tasks.count, 1)
    }

    func testEvaCannotOpenAdamsReportUntilItIsShared() async throws {
        let session = try makeSession(ScriptedComputer())
        session.office.link = .pcOffline
        try session.writeFile(ownerID: adam, ownerName: "Adam", path: "rapport.txt", text: "Adams rapport")
        do {
            _ = try await session.openFile(readerID: eva, ownerID: adam, path: "rapport.txt")
            XCTFail("Eva åbnede Adams rapport")
        } catch BotComputerFailure.isolated {}
        do {
            _ = try await session.share(ownerID: adam, path: "rapport.txt", with: eva, approved: false)
            XCTFail("Deling blev gemt uden godkendelse")
        } catch BotComputerFailure.rejected {}
        do {
            _ = try await session.openFile(readerID: eva, ownerID: adam, path: "rapport.txt")
            XCTFail("Eva åbnede Adams rapport")
        } catch BotComputerFailure.isolated {}
        _ = try await session.share(ownerID: adam, path: "rapport.txt", with: eva, approved: true)
        let opened = try await session.openFile(readerID: eva, ownerID: adam, path: "rapport.txt")
        XCTAssertEqual(opened.text, "Adams rapport")
        let own = try await session.openFile(readerID: adam, ownerID: adam, path: "rapport.txt")
        XCTAssertEqual(own.text, "Adams rapport")
    }

    func testLetterboxTapUsesThePictureNotTheBars() {
        let topBar = BotComputerPointer.normalized(tapX: 100, tapY: 10, viewWidth: 200, viewHeight: 200,
                                                   imageWidth: 1920, imageHeight: 1080)
        XCTAssertNil(topBar)
        let center = BotComputerPointer.normalized(tapX: 100, tapY: 100, viewWidth: 200, viewHeight: 200,
                                                   imageWidth: 1920, imageHeight: 1080)
        XCTAssertEqual(center?.x ?? -1, 0.5, accuracy: 0.02)
        XCTAssertEqual(center?.y ?? -1, 0.5, accuracy: 0.02)
    }

    func testCancelWhileDockerIsOfflineStillReachesThePC() async throws {
        let transport = ScriptedComputer()
        transport.healthLink = .dockerOffline
        let session = try makeSession(transport)
        let task = try await give(session, key: "key-adam-cancel")
        let cancelled = try await result(session.cancel(id: task.id))
        XCTAssertEqual(cancelled.status, .cancelled)
        XCTAssertEqual(transport.cancels, 1)
        transport.healthLink = .online
        await session.refresh(botID: adam)
        XCTAssertEqual(session.office.task(id: task.id)?.status, .cancelled)
    }

    func testLocalCancelIsNotReplacedByARemoteWaitingTask() {
        var office = BotComputerOffice()
        let task = BotComputerTask(id: "task-cancel", botID: adam, botName: "Adam", idempotencyKey: "key-cancel",
                                   retryKey: nil, instruction: "Skriv", inputPath: nil, status: .cancelled,
                                   resultText: nil, resultPath: nil, error: nil, attempt: 1, created: 1, updated: 2)
        office.tasks = [task]
        var remote = task
        remote.status = .running
        office.adopt(remote)
        XCTAssertEqual(office.tasks.first?.status, .cancelled)
    }

    func testServerIsolationDoesNotLookLikeAnOfflinePC() async throws {
        let transport = ScriptedComputer()
        transport.isolateReads = true
        let session = try makeSession(transport)
        session.office.link = .online
        try session.writeFile(ownerID: adam, ownerName: "Adam", path: "rapport.txt", text: "Adams rapport")
        do {
            _ = try await session.openFile(readerID: eva, ownerID: adam, path: "rapport.txt")
            XCTFail("Eva åbnede Adams rapport")
        } catch BotComputerFailure.isolated {}
        XCTAssertEqual(session.office.link, .online)
    }

    func testWireStatusAndHTTPCodes() throws {
        let json = """
        {"id":"task-1","bot_id":"\(adam)","bot_name":"Adam","idempotency_key":"key-adam-9","retry_key":null,"instruction":"Skriv en rapport","input_path":"kilde.txt","status":"waiting","result_text":null,"result_path":null,"error":null,"attempt":1,"created":1,"updated":1}
        """
        let task = try JSONDecoder().decode(BotComputerTask.self, from: Data(json.utf8))
        XCTAssertEqual(task.status, .waiting)
        XCTAssertEqual(task.botName, "Adam")
        XCTAssertNil(task.resultText)
        XCTAssertEqual(BotComputerSession.failure(forHTTPStatus: 403), .isolated)
        XCTAssertEqual(BotComputerSession.link(forHTTPStatus: 404), .moduleMissing)
        XCTAssertEqual(BotComputerSession.link(forHTTPStatus: 503), .dockerOffline)
        XCTAssertNil(BotComputerSession.link(forHTTPStatus: 401))
        XCTAssertEqual(BotComputerLink.pcOffline.detail.contains("PC’en"), true)
        XCTAssertEqual(BotComputerLink.dockerOffline.detail.contains("Docker"), true)
    }

    private func makeSession(_ transport: ScriptedComputer) throws -> BotComputerSession {
        BotComputerSession(directory: try temporaryDirectory(), transport: transport, now: { 10 })
    }

    private func give(_ session: BotComputerSession, key: String) async throws -> BotComputerTask {
        try await result(session.give(botID: adam, name: "Adam", instruction: "Skriv en rapport", key: key, inputPath: nil))
    }

    private func result(_ value: Result<BotComputerTask, BotComputerFailure>) async throws -> BotComputerTask {
        switch value {
        case .success(let task): return task
        case .failure(let error): throw error
        }
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}

@MainActor private final class ScriptedComputer: BotComputerTransport {
    var healthLink: BotComputerLink = .online
    var submits = 0
    var cancels = 0
    var retries = 0
    var failSubmit = false
    var failCancel = false
    var isolateReads = false
    var leaveWaiting = false
    var delay = false
    private var sent: [String: BotComputerTask] = [:]

    func health() async throws -> BotComputerLink {
        if healthLink == .pcOffline { throw BotComputerFailure.pcOffline }
        if healthLink == .moduleMissing { throw BotComputerFailure.moduleMissing }
        return healthLink
    }

    func submit(_ task: BotComputerTask) async throws -> BotComputerSubmission {
        if delay { try await Task.sleep(for: .milliseconds(50)) }
        submits += 1
        if let existing = sent[task.idempotencyKey] {
            return BotComputerSubmission(link: healthLink == .dockerOffline ? .dockerOffline : .online, task: existing)
        }
        var stored = task
        if healthLink == .dockerOffline {
            stored.status = .waiting
        } else if failSubmit {
            stored.status = .failed
            stored.error = "Ollama svarede ikke."
            failSubmit = false
        } else if !leaveWaiting {
            stored.status = .done
            stored.resultText = "Rapport"
            stored.resultPath = "opgave-test.txt"
        }
        sent[task.idempotencyKey] = stored
        let link: BotComputerLink = healthLink == .dockerOffline ? .dockerOffline : .online
        return BotComputerSubmission(link: link, task: stored)
    }

    func cancel(botID: String, id: String) async throws -> BotComputerTask {
        cancels += 1
        if failCancel { throw BotComputerFailure.pcOffline }
        guard var task = sent.values.first(where: { $0.id == id }) else { throw BotComputerFailure.rejected("Opgaven findes ikke.") }
        task.status = .cancelled
        sent[task.idempotencyKey] = task
        return task
    }

    func retry(botID: String, id: String, retryKey: String) async throws -> BotComputerSubmission {
        retries += 1
        guard var task = sent.values.first(where: { $0.id == id }) else { throw BotComputerFailure.rejected("Opgaven findes ikke.") }
        task.status = .done
        task.attempt += 1
        task.resultText = "Rapport"
        task.resultPath = "opgave-test.txt"
        task.retryKey = retryKey
        sent[task.idempotencyKey] = task
        return BotComputerSubmission(link: .online, task: task)
    }

    func tasks(botID: String) async throws -> [BotComputerTask] { Array(sent.values) }
    func read(botID: String, ownerID: String, path: String) async throws -> BotComputerFile {
        if isolateReads { throw BotComputerFailure.isolated }
        throw BotComputerFailure.pcOffline
    }
    func share(ownerID: String, path: String, with botID: String, approved: Bool) async throws -> BotComputerFile { throw BotComputerFailure.pcOffline }
    func startDesktop(botID: String, name: String) async throws -> BotComputerLink { healthLink }
    func frame(botID: String, name: String) async throws -> Data { Data([0x89, 0x50, 0x4E, 0x47]) }
    func click(botID: String, name: String, x: Double, y: Double, approved: Bool) async throws {
        if !approved { throw BotComputerFailure.rejected("Overtag styring kræver en eksplicit godkendelse.") }
    }
}
