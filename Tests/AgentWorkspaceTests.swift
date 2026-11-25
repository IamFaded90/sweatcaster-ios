import Foundation
import XCTest
@testable import SweatCaster

final class AgentWorkspaceTests: XCTestCase {
    func testPendingComputerJobsRotateWithoutBlockingLaterReceipt() {
        var first = AgentWorkspace.Job(id: UUID(), kind: .computer, prompt: "Stadig i gang", created: .now)
        first.state = .checking; first.submitted = true; first.pcID = "min-pc"
        var second = AgentWorkspace.Job(id: UUID(), kind: .computer, prompt: "Har et færdigt resultat", created: .now)
        second.state = .checking; second.submitted = true; second.pcID = "min-pc"
        let jobs = [first, second]
        let initial = AgentWorkspace.nextComputerJob(jobs, after: nil, connectedPC: "min-pc")
        XCTAssertEqual(initial?.id, first.id)
        // The first job can remain pending indefinitely; the next poll must
        // check the second instead of repeatedly selecting the first.
        let next = AgentWorkspace.nextComputerJob(jobs, after: initial?.id, connectedPC: "min-pc")
        XCTAssertEqual(next?.id, second.id)
        XCTAssertEqual(AgentWorkspace.nextComputerJob(jobs, after: next?.id, connectedPC: "min-pc")?.id, first.id)
        XCTAssertEqual(jobs, [first, second])
    }
    func testComputerPollingSkipsOtherTargetsAndFinishedJobs() {
        var wrongPC = AgentWorkspace.Job(id: UUID(), kind: .computer, prompt: "Anden PC", created: .now)
        wrongPC.state = .waitingForPC; wrongPC.pcID = "anden"
        var finished = AgentWorkspace.Job(id: UUID(), kind: .computer, prompt: "Færdig", created: .now)
        finished.state = .completed
        var selected = AgentWorkspace.Job(id: UUID(), kind: .computer, prompt: "Min PC", created: .now)
        selected.state = .waitingForPC; selected.pcID = "min-pc"
        let jobs = [wrongPC, finished, selected]
        XCTAssertEqual(AgentWorkspace.nextComputerJob(jobs, after: nil, connectedPC: "min-pc")?.id, selected.id)
        XCTAssertNil(AgentWorkspace.nextComputerJob(jobs, after: selected.id, connectedPC: "ukendt"))
        XCTAssertEqual(AgentWorkspace.nextComputerJob(jobs, after: UUID(), connectedPC: "min-pc")?.id, selected.id)
    }
    private func withStore(_ test: (AgentWorkspace) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try test(AgentWorkspace(botID: UUID(), root: root))
    }
    func testAgentsNeverShareFilesOrJobs() throws {
        try withStore { store in
            _ = try store.addFile(name: "../../note.txt", text: "Kun Adam")
            _ = try store.enqueue("Skriv en pakkeliste", kind: .document)
            let other = AgentWorkspace(botID: UUID(), root: store.root)
            XCTAssertEqual(try other.load(), .init())
            XCTAssertEqual(try store.load().files.first?.text, "Kun Adam")
            XCTAssertFalse(FileManager.default.fileExists(atPath: store.root.deletingLastPathComponent().appendingPathComponent("note.txt").path))
        }
    }
    func testInterruptedReadsResumeButUnknownWritesMustBeChecked() throws {
        try withStore { store in
            let local = try store.enqueue("Lav et dokument", kind: .document)
            let pc = try store.enqueue("Udfør på PC", kind: .computer)
            try store.update(local.id) { $0.state = .running }
            try store.update(pc.id) { $0.state = .running; $0.submitted = true }
            try store.recover()
            XCTAssertEqual(try store.load().jobs.map(\.state), [.paused, .checking])
        }
    }
    func testCompletionAndFileCommitAreIdempotent() throws {
        try withStore { store in
            let job = try store.enqueue("Lav en note", kind: .document)
            try store.complete(job.id, text: "Første resultat", name: "Note.md")
            try store.complete(job.id, text: "Dublet", name: "Anden.md")
            let saved = try store.load()
            XCTAssertEqual(saved.files.count, 1)
            XCTAssertEqual(saved.files[0].text, "Første resultat")
            XCTAssertEqual(saved.jobs[0].fileID, saved.files[0].id)
            XCTAssertEqual(saved.jobs[0].state, .completed)
        }
    }
    func testFailedSaveLeavesPreviousJournalAndVersionHistoryIntact() throws {
        try withStore { store in
            let file = try store.addFile(name: "Note", text: "En")
            try store.revise(file.id, text: "To")
            let before = try store.load()
            XCTAssertThrowsError(try store.revise(file.id, text: String(repeating: "x", count: 80_001)))
            XCTAssertEqual(try store.load(), before)
            XCTAssertEqual(before.files[0].previous, ["En"])
        }
    }
    func testShortcutEscapesInputAndRequiresSingleUseMatchingCallback() throws {
        try withStore { store in
            let shortcut = AgentWorkspace.Shortcut(id: UUID(), name: "Lys & musik", purpose: "Hjem")
            let job = try store.enqueue("Start", kind: .shortcut, shortcut: shortcut, input: "a&x-error=evil? #æ")
            let url = try XCTUnwrap(AgentShortcutBridge.launchURL(job: job, botID: store.botID))
            let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
            XCTAssertEqual(items.first { $0.name == "text" }?.value, "a&x-error=evil? #æ")
            var callback = try XCTUnwrap(URLComponents(string: try XCTUnwrap(items.first { $0.name == "x-success" }?.value)))
            callback.queryItems?.append(.init(name: "result", value: "Klar"))
            XCTAssertFalse(try AgentShortcutBridge.receive(try XCTUnwrap(callback.url), root: store.root))
            try store.update(job.id) { $0.submitted = true; $0.state = .checking }
            XCTAssertTrue(try AgentShortcutBridge.receive(try XCTUnwrap(callback.url), root: store.root))
            XCTAssertFalse(try AgentShortcutBridge.receive(try XCTUnwrap(callback.url), root: store.root))
            XCTAssertEqual(try store.load().jobs[0].state, .completed)
            XCTAssertTrue(try store.load().jobs[0].result.contains("Genveje meldte"))
        }
    }
    func testShortcutRejectsForgedAndDuplicateToken() throws {
        try withStore { store in
            let shortcut = AgentWorkspace.Shortcut(id: UUID(), name: "Test", purpose: "")
            let job = try store.enqueue("Test", kind: .shortcut, shortcut: shortcut)
            try store.update(job.id) { $0.state = .checking; $0.submitted = true }
            let fake = URL(string: "fadedai://agent-shortcut?agent=\(store.botID)&job=\(job.id)&token=\(UUID())&outcome=success")!
            XCTAssertFalse(try AgentShortcutBridge.receive(fake, root: store.root))
            let duplicate = URL(string: fake.absoluteString + "&token=\(job.callbackToken!)")!
            XCTAssertFalse(try AgentShortcutBridge.receive(duplicate, root: store.root))
            XCTAssertEqual(try store.load().jobs[0].state, .checking)
        }
    }
    func testCommandsAreExplicitAndDoNotCatchOrdinaryConversation() {
        XCTAssertEqual(AgentWorkspace.command("lav et dokument: en pakkeliste")?.kind, .document)
        XCTAssertEqual(AgentWorkspace.command("kør genvej: Lys | stue")?.input, "Lys | stue")
        XCTAssertNotNil(AgentWorkspace.command("vis dine filer"))
        XCTAssertNil(AgentWorkspace.command("Hvad er et dokument?"))
        XCTAssertNil(AgentWorkspace.command("lav et dokument: "))
    }
    func testFileContextFitsPCByteLimitAndCannotBorrowAnotherAgentsFile() throws {
        let text = String(repeating: "🇩🇰 Æble ", count: 2_000)
        let clipped = AgentWorkspace.excerpt(text, maximumBytes: 6_000)
        XCTAssertLessThanOrEqual(clipped.utf8.count, 6_000)
        XCTAssertTrue(text.hasPrefix(clipped))
        XCTAssertFalse(clipped.contains("�"))
        try withStore { store in
            XCTAssertThrowsError(try store.enqueue("Brug filen", kind: .document, inputFileID: UUID()))
            let file = try store.addFile(name: "Min note", text: "En tekst")
            let job = try store.enqueue("Brug filen", kind: .document, inputFileID: file.id)
            XCTAssertEqual(job.inputFileID, file.id)
        }
    }
}
