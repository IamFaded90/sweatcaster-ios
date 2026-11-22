import FoundationModels
import XCTest
@testable import SweatCaster

final class MiniCPMCatalogTests: XCTestCase {
    func testRetryKeepsOneModelWhileTransfersRemainIndependent() throws {
        let file = GGUFHub.miniCPM
        let first = GGUFModelDownloads.Pending(uuid: UUID(), file: file)
        let second = GGUFModelDownloads.Pending(uuid: UUID(), file: file)
        XCTAssertNotEqual(first.uuid, second.uuid)
        XCTAssertEqual(first.installationID, second.installationID)
        XCTAssertEqual(try JSONDecoder().decode(GGUFModelDownloads.Pending.self,
                                                 from: JSONEncoder().encode(first)).installationID, first.installationID)
        let other = GGUFHub.File(repository: file.repository, revision: file.revision, name: file.name,
                                 bytes: file.bytes, sha256: String(repeating: "0", count: 64))
        let changed = GGUFModelDownloads.Pending(uuid: UUID(), file: other)
        XCTAssertEqual(changed.installationID, changed.uuid)
    }

    func testCatalogPromptContainsModelStartOnceAndKeepsBothTurns() {
        let file = GGUFHub.miniCPM
        let url = URL(fileURLWithPath: "/tmp/" + file.name)
        let model = GGUFPhoneModel(uuid: GGUFPhoneModel.miniCPMFolder, url: url, bytes: file.bytes)
        let formatted = "<|im_start|>user\nMin mappe hedder Sommerferie.<|im_end|>\n<|im_start|>assistant\n"
        let expected = "<s>" + formatted + "<think>\n\n</think>\n\n"
        XCTAssertEqual(model.id, GGUFPhoneModel.miniCPMID)
        XCTAssertEqual(model.chatPrompt(from: formatted), expected)
        XCTAssertEqual(model.chatPrompt(from: expected), expected)
        let imported = GGUFPhoneModel(uuid: UUID(), url: url, bytes: file.bytes)
        XCTAssertEqual(imported.chatPrompt(from: formatted), expected)
        let other = GGUFPhoneModel(uuid: UUID(), url: url, bytes: 42)
        XCTAssertEqual(other.chatPrompt(from: formatted), formatted)
    }
}

final class PhoneConversationHistoryTests: XCTestCase {
    func testStudioKeepsLatestCorrectionWithinItsOwnTokenBudget() {
        let turn = PhoneModels.ChatExchange(prompt: "Farven er rød. " + String(repeating: "💙", count: 3_000)
            + "Rettelse: turkis.", reply: "Jeg har læst rettelsen.")
        let first = PhoneModels.ChatExchange(prompt: "Hvad vælger vi?", reply: "En farve.")
        let history = PhoneModels.ChatExchange.studioHistory([first, turn], tokenBudget: 800)
        XCTAssertEqual(history.first?.prompt, first.prompt)
        XCTAssertTrue(history.last?.prompt.hasSuffix("Rettelse: turkis.") == true)
        XCTAssertEqual(history.last?.reply, turn.reply)
        let used = history.reduce(0) { $0 + ($1.prompt.utf8.count + 2) / 3 + ($1.reply.utf8.count + 2) / 3 + 16 }
        XCTAssertLessThanOrEqual(used, 800)
        XCTAssertTrue(PhoneModels.ChatExchange.studioHistory([turn], tokenBudget: 10).isEmpty)
        let emoji = PhoneModels.ChatExchange(prompt: "🌙", reply: "🌙")
        XCTAssertTrue(PhoneModels.ChatExchange.studioHistory([emoji], tokenBudget: 18).isEmpty)
        XCTAssertTrue(PhoneModels.ChatExchange.studioHistory([], tokenBudget: 800).isEmpty)
    }

    func testLargeReplyKeepsEarlierQuestionAndCorrectionAtTheEnd() {
        let question = "Hvornår mødes vi?"
        let first = PhoneModels.ChatExchange(prompt: "Hvor?", reply: "Farsø.")
        let second = PhoneModels.ChatExchange(prompt: "Tjek tidspunktet.", reply: "Først kl. 8. "
            + String(repeating: "Mellemtekst ", count: 400) + "Rettelse: kl. 11.")
        let history = PhoneModels.ChatExchange.recent([first, second], for: question)
        XCTAssertEqual(history.map(\.prompt), [first.prompt, second.prompt])
        XCTAssertEqual(history.first?.reply, "Farsø.")
        XCTAssertTrue(history.last?.reply.hasSuffix("Rettelse: kl. 11.") == true)
        XCTAssertTrue(history.last?.reply.hasPrefix("Først kl. 8.") == true)
        XCTAssertLessThan(history.map(\.reply).joined().unicodeScalars.count, 3_000)
        let pc = second.excerpt(promptLimit: 400, replyLimit: 1_200)
        XCTAssertEqual(pc.reply.unicodeScalars.count, 1_200)
        XCTAssertTrue(pc.reply.hasSuffix("Rettelse: kl. 11."))
    }

    func testHistoryHonorsRequestBudgetAndKeepsCompleteTurnsWhenTheyFit() {
        let turns = (0..<8).map { PhoneModels.ChatExchange(prompt: "Spørg \($0)", reply: "Svar \($0)") }
        XCTAssertEqual(PhoneModels.ChatExchange.recent(turns, for: "Hej").map(\.prompt), turns.suffix(6).map(\.prompt))
        let long = PhoneModels.ChatExchange(prompt: String(repeating: "æ", count: 500), reply: String(repeating: "å", count: 1_300))
        XCTAssertEqual(PhoneModels.ChatExchange.recent([long], for: "Og så?").first?.reply, long.reply)
        let message = String(repeating: "🇩🇰", count: 1_400)
        let remaining = PhoneModels.ChatExchange.recent([long, long], for: message)
        XCTAssertFalse(remaining.isEmpty)
        let size = remaining.reduce(message.unicodeScalars.count) { $0 + $1.prompt.unicodeScalars.count + $1.reply.unicodeScalars.count + 24 }
        XCTAssertLessThanOrEqual(size, 3_000)
        XCTAssertTrue(PhoneModels.ChatExchange.recent([long], for: String(repeating: "a", count: 3_000)).isEmpty)
    }
}

final class AppleConversationTranscriptTests: XCTestCase {
    func testHistoryUsesSeparateRolesAndNewChatStartsFresh() throws {
        guard #available(iOS 26, *) else { throw XCTSkip("Kræver Foundation Models") }
        let bot = "Svar på dansk."
        let history = [PhoneModels.ChatExchange(prompt: "Mit møde er kl. 8.", reply: "Noteret.")]
        let entries = Array(PhoneModels.appleTranscript(instructions: bot, history: history))
        XCTAssertEqual(entries.count, 3)
        guard entries.count == 3, case .instructions(let instructions) = entries[0],
              case .prompt(let prompt) = entries[1], case .response(let answer) = entries[2],
              case .text(let rule) = instructions.segments.first,
              case .text(let user) = prompt.segments.first, case .text(let agent) = answer.segments.first else {
            return XCTFail("Samtalens roller blev blandet sammen.")
        }
        XCTAssertEqual(rule.content, bot)
        XCTAssertEqual(user.content, history[0].prompt)
        XCTAssertEqual(agent.content, history[0].reply)
        XCTAssertEqual(PhoneModels.appleTranscript(instructions: bot, history: []).count, 1)
    }
}

private final class PausableImageTask: URLSessionTask, @unchecked Sendable {
    private var phase: URLSessionTask.State
    private let received: Int64
    private(set) var transitions = 0
    private let descriptionForTest: String

    init(transfer: StudioImageTransfer, file: StudioImageDownloadFile, state: URLSessionTask.State, received: Int64 = 0) {
        self.phase = state
        self.received = received
        self.descriptionForTest = "\(transfer.identifier):\(file.name)"
        super.init()
    }

    override var taskDescription: String? {
        get { descriptionForTest }
        set {}
    }
    override var state: URLSessionTask.State { phase }
    override var countOfBytesReceived: Int64 { received }
    override func suspend() { phase = .suspended; transitions += 1 }
    override func resume() { phase = .running; transitions += 1 }
}

final class StudioImageTransferPauseTests: XCTestCase {
    func testPauseAndResumeReattachPartiallyDownloadedFileWithoutDuplicatingIt() throws {
        let transfer = StudioImageTransfer(model: .fluxKlein)
        let restored = try XCTUnwrap(StudioImageTransfer(transfer.identifier))
        let files = transfer.model.downloadFiles
        let downloading = PausableImageTask(transfer: transfer, file: files[0], state: .running, received: files[0].bytes / 2)
        let other = PausableImageTask(transfer: StudioImageTransfer(model: .fluxKlein), file: files[1], state: .running)
        let tasks = [downloading, other]
        let staged = files[1].name
        let pause = transfer.adjust(tasks, paused: true) { $0.name == staged }
        XCTAssertEqual(pause.fractions[files[0].name], 0.5)
        XCTAssertEqual(pause.fractions[staged], 1)
        XCTAssertEqual(downloading.state, .suspended)
        _ = restored.adjust(tasks, paused: true) { $0.name == staged }
        let resumed = restored.adjust(tasks, paused: false) { $0.name == staged }
        XCTAssertEqual(resumed.missing.map(\.name), [files[2].name])
        XCTAssertEqual(downloading.state, .running)
        _ = restored.adjust(tasks, paused: false) { $0.name == staged }
        XCTAssertEqual(downloading.transitions, 2)
        XCTAssertEqual(other.transitions, 0)
    }

    func testMissingSystemTaskCanRestartWhileCompletedFilesStayOnPhone() {
        let transfer = StudioImageTransfer(model: .stableDiffusion)
        let files = transfer.model.downloadFiles
        let stale = PausableImageTask(transfer: transfer, file: files[0], state: .completed)
        let cancelled = PausableImageTask(transfer: transfer, file: files[1], state: .canceling)
        let result = transfer.adjust([stale, cancelled], paused: false) { $0.name == files[0].name }
        XCTAssertEqual(result.missing.map(\.name), [files[1].name, files[2].name])
        XCTAssertEqual(result.fractions, [files[0].name: 1])
        XCTAssertEqual(stale.transitions + cancelled.transitions, 0)
    }
}

final class PhoneMemoryBudgetTests: XCTestCase {
    func testTruncatedStageCannotClaimOrDisplaceACompleteDelivery() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let staged = root.appendingPathComponent("model.staged")
        let incoming = staged.appendingPathExtension("incoming")
        let resume = root.appendingPathComponent("model.resume")
        try Data([7]).write(to: resume)
        for partialIncoming in [false, true] {
            try Data([1, 2]).write(to: staged)
            if partialIncoming { try Data([1]).write(to: incoming) }
            try StudioImageFileValidation.recoverStagedFile(at: staged, expectedBytes: 3)
            XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: incoming.path))
            XCTAssertEqual(try Data(contentsOf: resume), Data([7]))
        }
        try Data([1, 2, 3]).write(to: incoming)
        try StudioImageFileValidation.recoverStagedFile(at: staged, expectedBytes: 3)
        XCTAssertEqual(try Data(contentsOf: staged), Data([1, 2, 3]))
    }

    func testCompletedCallbackFileIsRecoveredAndVerifiedAfterRestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let staged = directory.appendingPathComponent("model.staged")
        let incoming = staged.appendingPathExtension("incoming")
        try Data([0]).write(to: staged)
        try Data("abc".utf8).write(to: incoming)
        try StudioImageFileValidation.recoverStagedFile(at: staged, expectedBytes: 3)
        let digest = try await StudioImageFileValidation.digest(at: staged, expectedBytes: 3) { _ in }
        XCTAssertEqual(digest, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertFalse(FileManager.default.fileExists(atPath: incoming.path))
        try Data("xyz".utf8).write(to: incoming)
        try StudioImageFileValidation.recoverStagedFile(at: staged, expectedBytes: 3)
        try StudioImageFileValidation.recoverStagedFile(at: staged, expectedBytes: 3)
        XCTAssertEqual(try Data(contentsOf: staged), Data("abc".utf8))
    }

    func testIncompleteCallbackFileReleasesSpaceAndOnlyItsFileNeedsDownloading() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let staged = directory.appendingPathComponent("model.staged")
        let incoming = staged.appendingPathExtension("incoming")
        let other = directory.appendingPathComponent("encoder.staged")
        try Data([0, 1]).write(to: incoming)
        try Data([2, 3]).write(to: other)
        try StudioImageFileValidation.recoverStagedFile(at: staged, expectedBytes: 3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: incoming.path))
        XCTAssertEqual(try Data(contentsOf: other), Data([2, 3]))
    }

    func testQwenRepairBudgetsForTheRemainingFiles() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let tokenizer = root.appendingPathComponent("hf_model")
        try manager.createDirectory(at: tokenizer, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        let compact = QwenPhoneRuntime.Variant.compact
        let config = try XCTUnwrap(compact.tokenizerFiles.first { $0.name == "tokenizer_config.json" })
        let bytes = Data(repeating: 1, count: config.bytes)
        try bytes.write(to: tokenizer.appendingPathComponent(config.name))
        try Data([0]).write(to: tokenizer.appendingPathComponent("tokenizer.json"))
        XCTAssertNil(QwenPhoneRuntime.downloadBudget(for: compact, in: root, weightsReady: false))
        let repair = try XCTUnwrap(QwenPhoneRuntime.downloadBudget(for: compact, in: root, weightsReady: true))
        XCTAssertEqual(repair.remaining, compact.tokenizerBytes - Int64(config.bytes))
        XCTAssertEqual(repair.free, repair.remaining + 12_807_982)
    }

    func testVisionRepairCreditsOnlyCompleteInstalledFiles() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        let asset = try XCTUnwrap(QwenPhoneRuntime.visionAssets?.first { $0.path.hasSuffix("/Manifest.json") })
        let manifest = root.appendingPathComponent(asset.path)
        try manager.createDirectory(at: manifest.deletingLastPathComponent(), withIntermediateDirectories: true)
        let full = try XCTUnwrap(QwenPhoneRuntime.downloadBudget(for: .vision, in: root, weightsReady: false))
        XCTAssertEqual(full.remaining, QwenPhoneRuntime.visionWeightsBytes + QwenPhoneRuntime.Variant.vision.tokenizerBytes)
        let other = root.appendingPathComponent("other.json")
        try Data(repeating: 1, count: Int(asset.bytes)).write(to: other)
        try manager.createSymbolicLink(at: manifest, withDestinationURL: other)
        XCTAssertEqual(QwenPhoneRuntime.downloadBudget(for: .vision, in: root, weightsReady: false)?.remaining, full.remaining)
        try manager.removeItem(at: manifest)
        try manager.moveItem(at: other, to: manifest)
        XCTAssertEqual(QwenPhoneRuntime.downloadBudget(for: .vision, in: root, weightsReady: false)?.remaining,
                       full.remaining - asset.bytes)
    }

    @MainActor
    func testImageChecksumContinuesAtItsFileOffsetAfterAppSwitch() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let size = 24 * 1_048_576
        try Data(repeating: 0x4c, count: size).write(to: url)
        let gate = StudioImageValidationGate()
        gate.setActive(true)
        let paused = expectation(description: "Checksum reached the first 8 MiB")
        let task = Task { @MainActor in
            var percents: [Int] = []
            let digest = try await StudioImageFileValidation.digest(at: url, expectedBytes: Int64(size)) { percent in
                percents.append(percent)
                if percents.count == 2 {
                    gate.setActive(false)
                    paused.fulfill()
                }
                try await gate.waitUntilActive()
            }
            return (digest, percents)
        }
        await fulfillment(of: [paused], timeout: 15)
        // Overwriting bytes already read makes an accidental rewind observable in the final digest.
        let handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: Data([0x41]))
        try handle.close()
        gate.setActive(true)
        let (digest, percents) = try await task.value
        XCTAssertEqual(digest, "0f0985165f648571333a29d22af9d8ab889973fcaa79de18cbd4ede80f78c551")
        XCTAssertEqual(percents.first, 0)
        XCTAssertEqual(percents.last, 100)
        XCTAssertEqual(percents.sorted(), percents)
    }

    @MainActor
    func testStopDownloadReleasesPausedChecksum() async {
        let gate = StudioImageValidationGate()
        let entered = expectation(description: "Waiting for foreground")
        let task = Task { @MainActor in
            entered.fulfill()
            try await gate.waitUntilActive()
        }
        await fulfillment(of: [entered], timeout: 5)
        task.cancel()
        gate.wake()
        do {
            try await task.value
            XCTFail("Cancelled verification completed")
        } catch { XCTAssertTrue(error is CancellationError) }
    }

    func testImageChecksumRejectsTruncatedDownload() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data([1, 2, 3]).write(to: url)
        do {
            _ = try await StudioImageFileValidation.digest(at: url, expectedBytes: 4) { _ in }
            XCTFail("The checksum accepted a truncated file")
        } catch {
            XCTAssertEqual((error as NSError).code, CocoaError.fileReadCorruptFile.rawValue)
        }
    }

    @MainActor func testBenchmarkKeepsOneRunAndCanRestartAfterCancellation() async {
        let run = PhoneBenchmarkRun()
        let (entered, signal) = AsyncStream<Void>.makeStream()
        run.start(modelID: "first") { _, _ in
            signal.yield(())
            signal.finish()
            try await Task.sleep(for: .seconds(30))
            return "Forældet resultat"
        }
        for await _ in entered { break }
        run.start(modelID: "second") { _, _ in XCTFail("Startede to målinger"); return "" }
        XCTAssertEqual(run.modelID, "first")
        let first = run.task
        run.stop()
        await first?.value
        XCTAssertNil(run.result)
        XCTAssertFalse(run.isRunning)
        XCTAssertTrue(run.notice?.contains("afbrudt") == true)

        run.start(modelID: "second") { _, progress in
            progress("Måler")
            XCTAssertEqual(run.notice, "Måler")
            return "Prøvesvar"
        }
        await run.task?.value
        XCTAssertEqual(run.modelID, "second")
        XCTAssertEqual(run.result, "Prøvesvar")
        XCTAssertNil(run.notice)
    }

    @MainActor func testSystemInterruptionShowsWhyBenchmarkEnded() async {
        let run = PhoneBenchmarkRun()
        run.start(modelID: "apple") { _, _ in throw CancellationError() }
        await run.task?.value
        XCTAssertFalse(run.isRunning)
        XCTAssertTrue(run.notice?.contains("afbrudt") == true)
        run.start(modelID: "apple") { _, _ in throw PhoneModelError.emptyResponse }
        await run.task?.value
        XCTAssertNil(run.result)
        XCTAssertTrue(run.notice?.contains("intet svar") == true)
    }

    func testFourSuggestionsKeepBothOriginalsAndHaveDistinctRepeatableSeeds() {
        let single = StudioImageRequest(model: StudioImageModel.fluxKlein.id, route: .pc, pcModel: .flux2,
                                        prompt: "Farvede figurer", negative: "", lora: "", count: 1,
                                        seed: UInt32.max - 1, sourceImage: Data([1]), secondReference: Data([2]),
                                        referenceMode: .preserve, referenceMask: nil, isPrivate: true,
                                        autoSave: false, botID: nil, allowPCFallback: false)
        var batch = single
        batch.count = 4
        XCTAssertEqual(single.suggestionSeeds, [UInt32.max - 1])
        XCTAssertEqual(batch.suggestionSeeds, [UInt32.max - 1, UInt32.max, 0, 1])
        XCTAssertEqual(batch.sourceImage, single.sourceImage)
        XCTAssertEqual(batch.secondReference, single.secondReference)
    }

    func testReferencePairRequiresAnExplicitCompatibleRoute() {
        func request(_ route: StudioImageRoute, _ model: StudioImageModel, _ pc: StudioPCImageModel,
                     privateSession: Bool = true, base: Data? = Data([1]),
                     mask: StudioReferenceMask? = nil) -> StudioImageRequest {
            StudioImageRequest(model: model.id, route: route, pcModel: pc, prompt: "Rød og blå",
                               negative: "", lora: "", count: 1, seed: 1, sourceImage: base,
                               secondReference: Data([2]), referenceMode: .edit, referenceMask: mask,
                               isPrivate: privateSession, autoSave: false, botID: nil, allowPCFallback: false)
        }
        XCTAssertNil(request(.phone, .fluxKlein, .realvis).referencePairBlocker)
        XCTAssertNil(request(.pc, .stableDiffusion, .flux2Adult).referencePairBlocker)
        XCTAssertNotNil(request(.phone, .stableDiffusion, .flux2).referencePairBlocker)
        XCTAssertNotNil(request(.pc, .fluxKlein, .realvis).referencePairBlocker)
        XCTAssertNotNil(request(.automatic, .fluxKlein, .flux2).referencePairBlocker)
        XCTAssertNotNil(request(.phone, .fluxKlein, .flux2, privateSession: false).referencePairBlocker)
        XCTAssertNotNil(request(.phone, .fluxKlein, .flux2, base: nil).referencePairBlocker)
        XCTAssertNotNil(request(.phone, .fluxKlein, .flux2, mask: .init()).referencePairBlocker)
        var onePhoto = request(.phone, .stableDiffusion, .realvis)
        onePhoto.secondReference = nil
        XCTAssertNil(onePhoto.referencePairBlocker)
    }

    func testFluxDownloadBudgetsForAllThreeFilesAndInstallationSpace() {
        let flux = StudioImageModel.fluxKlein
        XCTAssertEqual(flux.downloadFiles.reduce(Int64.zero) { $0 + $1.bytes }, 8_743_059_456)
        XCTAssertTrue(flux.downloadFiles.allSatisfy { $0.sha256?.count == 64 })
        let missingBytes = flux.downloadFiles.filter { !$0.isPresent }.reduce(Int64.zero) { $0 + $1.bytes }
        XCTAssertEqual(flux.minimumFreeBytes, missingBytes + 1_000_000_000)
    }

    func testTruncatedImageDependencyIsNotReady() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let file = StudioImageDownloadFile(name: "test.ckpt", bytes: 64, sha256: nil)
        try Data(repeating: 0, count: 63).write(to: url)
        XCTAssertFalse(file.matchesSize(at: url))
        try Data(repeating: 0, count: 64).write(to: url)
        XCTAssertTrue(file.matchesSize(at: url))
    }

    func testCachedSizeDoesNotHideCompletedImageDependency() throws {
        var url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let file = StudioImageDownloadFile(name: "test.ckpt", bytes: 64, sha256: nil)
        try Data(repeating: 0, count: 64).write(to: url)
        url.setTemporaryResourceValue(63, forKey: .fileSizeKey)
        XCTAssertTrue(file.matchesSize(at: url))
        try Data(repeating: 0, count: 63).write(to: url)
        url.setTemporaryResourceValue(64, forKey: .fileSizeKey)
        XCTAssertFalse(file.matchesSize(at: url))
    }

    func testImageDependencyRequiresRegularFileWithExactSize() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = StudioImageDownloadFile(name: "test.ckpt", bytes: 64, sha256: nil)
        let url = root.appendingPathComponent(file.name)
        try Data(repeating: 0, count: 65).write(to: url)
        XCTAssertFalse(file.matchesSize(at: url))
        try Data(repeating: 0, count: 64).write(to: url)
        let link = root.appendingPathComponent("link.ckpt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
        XCTAssertFalse(file.matchesSize(at: link))
        XCTAssertFalse(file.matchesSize(at: root))
        XCTAssertFalse(file.matchesSize(at: root.appendingPathComponent("missing.ckpt")))
    }

    func testOtherAppsCanReduceBudgetEvenOnLargePhone() {
        let result = PhoneMemoryBudget.assess(required: 3_000_000_000, physical: 12_000_000_000, available: 2_000_000_000)
        XCTAssertEqual(result.fit, .unavailable)
        XCTAssertEqual(result.recommendedBytes, 2_000_000_000)
    }

    func testConservativeEstimateDoesNotBlockOtherwiseLoadableModel() {
        let result = PhoneMemoryBudget.assess(required: 8_000_000_000, physical: 12_000_000_000, available: 9_000_000_000)
        XCTAssertEqual(result.fit, .tight)
    }

    func testSmallModelAndUnknownMemory() {
        XCTAssertEqual(PhoneMemoryBudget.assess(required: 1_000_000_000, physical: 8_000_000_000, available: 5_000_000_000).fit, .comfortable)
        XCTAssertEqual(PhoneMemoryBudget.assess(required: 1, physical: 0, available: 0).fit, .unavailable)
        XCTAssertEqual(PhoneMemoryBudget.assess(required: 0, physical: 8_000_000_000, available: 5_000_000_000).fit, .unavailable)
    }
}

final class StudioImagePairColorTests: XCTestCase {
    func testPairRequiresBothColoursOnTheExpectedSides() {
        let side = StudioImagePairColors.side
        let red: [UInt8] = [200, 30, 15, 255], blue: [UInt8] = [20, 45, 220, 255]
        func sample(left: [UInt8]?, right: [UInt8]?, circleLeft: Bool = true, circleRight: Bool = false,
                    halfHeight: Int = 10) -> [UInt8] {
            var pixels = [UInt8](repeating: 255, count: side * side * 4)
            for y in (32 - halfHeight)..<(32 + halfHeight) {
                for x in 0 ..< side {
                    let localX = x % (side / 2) - 16
                    let dx = (Double(localX) + 0.5) / 10, dy = (Double(y - 32) + 0.5) / Double(halfHeight)
                    let circle = x < side / 2 ? circleLeft : circleRight
                    if (-10..<10).contains(localX), !circle || dx * dx + dy * dy <= 1,
                       let colour = x < side / 2 ? left : right {
                        let offset = (y * side + x) * 4
                        pixels.replaceSubrange(offset ..< offset + 4, with: colour)
                    }
                }
            }
            return pixels
        }
        XCTAssertTrue(StudioImagePairColors.matchesRGBA(sample(left: red, right: blue)))
        XCTAssertFalse(StudioImagePairColors.matchesRGBA(sample(left: red, right: blue, circleLeft: false)))
        XCTAssertFalse(StudioImagePairColors.matchesRGBA(sample(left: red, right: blue, circleRight: true)))
        XCTAssertFalse(StudioImagePairColors.matchesRGBA(sample(left: red, right: blue, circleLeft: false, circleRight: true)))
        XCTAssertFalse(StudioImagePairColors.matchesRGBA(sample(left: red, right: blue, halfHeight: 3)))
        XCTAssertFalse(StudioImagePairColors.matchesRGBA(sample(left: blue, right: red)))
        XCTAssertFalse(StudioImagePairColors.matchesRGBA(sample(left: nil, right: nil)))
        XCTAssertFalse(StudioImagePairColors.matchesRGBA(sample(left: red, right: nil)))
        XCTAssertFalse(StudioImagePairColors.matchesRGBA(sample(left: nil, right: blue)))
        XCTAssertFalse(StudioImagePairColors.matchesRGBA(sample(left: red, right: red)))
    }
}

final class StudioImageProbeHistoryTests: XCTestCase {
    @MainActor func testOlderColourOnlyMeasurementKeepsItsOriginalMeaning() async throws {
        let json = #"{"id":"00000000-0000-0000-0000-000000000001","date":0,"measurement":{"width":896,"height":640,"seconds":60}}"#
        let record = try JSONDecoder().decode(StudioImageProbeHistory.Record.self, from: Data(json.utf8))
        XCTAssertNil(record.measurement?.checkedPairShapes)
        XCTAssertTrue(record.summary(pair: true).contains("Tidligere farveprøve"))
    }

    @MainActor func testRestartSeparatesUnfinishedPairFromCompletedPhoneImage() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        let first = StudioImageProbeHistory(file: file)
        let apple = UUID(), pair = UUID()
        XCTAssertNil(first.record(model: "flux", pair: false))
        first.begin(apple, model: "flux", pair: false)
        first.finish(apple, model: "flux", pair: false, width: 1024, height: 1024, seconds: 62.5)
        first.begin(pair, model: "flux", pair: true)

        let reopened = StudioImageProbeHistory(file: file)
        XCTAssertEqual(reopened.record(model: "flux", pair: false)?.measurement?.seconds, 62.5)
        XCTAssertEqual(reopened.record(model: "flux", pair: true)?.id, pair)
        XCTAssertNil(reopened.record(model: "flux", pair: true)?.measurement)
        let newPair = UUID()
        reopened.begin(newPair, model: "flux", pair: true)
        reopened.finish(pair, model: "flux", pair: true, width: 64, height: 64, seconds: 1)
        reopened.finish(newPair, model: "flux", pair: true, width: 0, height: 64, seconds: 1)
        XCTAssertNil(reopened.record(model: "flux", pair: true)?.measurement)
        reopened.finish(newPair, model: "flux", pair: true, width: 800, height: 768, seconds: 50)
        XCTAssertEqual(reopened.record(model: "flux", pair: true)?.measurement?.width, 800)
        XCTAssertEqual(reopened.record(model: "flux", pair: true)?.measurement?.checkedPairShapes, true)
        XCTAssertEqual(reopened.record(model: "flux", pair: false)?.measurement?.width, 1024)
        reopened.begin(UUID(), model: "flux", pair: false)
        reopened.begin(UUID(), model: "flux", pair: false)
        let afterInterruption = StudioImageProbeHistory(file: file).record(model: "flux", pair: false)
        XCTAssertNil(afterInterruption?.measurement)
        XCTAssertEqual(afterInterruption?.previousSuccess?.measurement.width, 1024)
    }

    @MainActor func testDeletingModelClearsOnlyItsLocalProbeResults() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        let first = StudioImageProbeHistory(file: file)
        first.begin(UUID(), model: "flux", pair: false)
        first.begin(UUID(), model: "flux", pair: true)
        first.begin(UUID(), model: "sd", pair: false)
        first.forget(model: "flux")
        let reopened = StudioImageProbeHistory(file: file)
        XCTAssertNil(reopened.record(model: "flux", pair: false))
        XCTAssertNil(reopened.record(model: "flux", pair: true))
        XCTAssertNotNil(reopened.record(model: "sd", pair: false))
    }
}

final class PhonePromptCacheTests: XCTestCase {
    func testOnlyPublicTokensBeforeTheFirstChangedTokenAreEligible() {
        XCTAssertEqual(PhonePromptCache.commonTokens(publicPrefix: [1, 2, 3], prompt: [1, 2, 99, 80]), [1, 2])
        XCTAssertEqual(PhonePromptCache.commonTokens(publicPrefix: [1, 2], prompt: [1, 2, 80]), [1, 2])
        XCTAssertTrue(PhonePromptCache.commonTokens(publicPrefix: [1, 2], prompt: [9, 2, 80]).isEmpty)
        XCTAssertTrue(PhonePromptCache.commonTokens(publicPrefix: [1, 2], prompt: [1, 2]).isEmpty)
    }

    func testSnapshotBelongsToOneConversationModelAndExactTokenPrefix() {
        let cache = PhonePromptCache()
        let key = PhonePromptCache.Key(sessionID: UUID(), modelHash: "model-a", tokens: [1, 2])
        let bytes = Data([10, 20, 30])
        cache.save(bytes, for: key)
        XCTAssertEqual(cache.state(for: key), bytes)
        XCTAssertNil(cache.state(for: .init(sessionID: UUID(), modelHash: "model-a", tokens: [1, 2])))
        XCTAssertNil(cache.state(for: .init(sessionID: key.sessionID, modelHash: "model-b", tokens: [1, 2])))
        XCTAssertNil(cache.state(for: .init(sessionID: key.sessionID, modelHash: "model-a", tokens: [1])))
        XCTAssertNil(PhonePromptCache().state(for: key))
    }

    func testOversizedAndEmptySnapshotsAreDiscarded() {
        let cache = PhonePromptCache()
        let key = PhonePromptCache.Key(sessionID: UUID(), modelHash: "model-a", tokens: [1, 2])
        cache.save(Data(), for: key)
        XCTAssertNil(cache.state(for: key))
        cache.save(Data(count: PhonePromptCache.maximumBytes + 1), for: key)
        XCTAssertNil(cache.state(for: key))
    }
}
