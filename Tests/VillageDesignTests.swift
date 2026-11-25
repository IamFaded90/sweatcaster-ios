import XCTest
import UIKit
import WebKit
import AVFAudio
@testable import SweatCaster

final class VillageDesignTests: XCTestCase {
    @MainActor func testPrivateChatStartsLockedEvenIfAnotherStudioWasUnlocked() {
        let chat = OfflineStudio(api: nil, sessionUnlocked: .constant(true), ephemeralOnly: true)
        XCTAssertFalse(chat.sessionUnlocked)
        XCTAssertFalse(chat.canShowStudio)
        let imageEditor = OfflineStudio(api: nil, sessionUnlocked: .constant(false),
                                        initialPage: .images, ephemeralOnly: true, imageOnly: true)
        XCTAssertTrue(imageEditor.sessionUnlocked)
    }

    func testLumiSendsWholeMessagesWhenTheHistoryBudgetEndsInsideAWord() {
        func turn(_ role: LumiSceneMessage.Role, _ text: String) -> LumiSceneMessage {
            LumiSceneMessage(role: role, text: text, language: "da-DK")
        }
        let early = turn(.user, String(repeating: "🙂", count: 1_900) + " Min cykel er petrolblå.")
        let newer = [turn(.user, "Min nye jakke er mørkegrøn."), turn(.assistant, String(repeating: "æ", count: 730))]
        XCTAssertEqual(LumiSceneMessage.chatHistory([early] + newer), newer.map(\.wire))
        let overBudget = turn(.assistant, String(repeating: "🌙", count: 2_300))
        XCTAssertEqual(LumiSceneMessage.chatHistory([early, overBudget]), [early.wire])
        let window = (0..<20).map { turn($0.isMultiple(of: 2) ? .user : .assistant, "Replik \($0)") }
        XCTAssertEqual(LumiSceneMessage.chatHistory(window), window.suffix(16).map(\.wire))
        XCTAssertTrue(LumiSceneMessage.chatHistory([turn(.assistant, "Mit gæt er lilla.")]).isEmpty)
    }

    func testLumiLimitsRestoredMessagesOnTheWireAndKeepsLateCorrections() throws {
        let correction = " Jeg mente fredag."
        let reply = " Jeg husker fredag."
        let promptText = "Min aftale. " + String(repeating: "x", count: 4_800) + correction
        let replyText = "Din aftale. " + String(repeating: "e\u{301}", count: 60) + String(repeating: "y", count: 3_900) + reply
        let turns = [
            LumiSceneMessage(role: .user, text: promptText, language: "da-DK"),
            LumiSceneMessage(role: .assistant, text: replyText, language: "da-DK")
        ]
        let saved = LumiSavedScene.snapshot(card: LumiSceneCard(title: "Aftalen"), initiative: .together,
                                            language: "da-DK", messages: turns, draft: "")
        let restored = try JSONDecoder().decode(LumiSavedScene.self, from: JSONEncoder().encode(saved))
        let history = LumiSceneMessage.chatHistory(restored.messages)
        XCTAssertEqual(restored.messages, turns)
        XCTAssertEqual(history.compactMap { $0["role"] }, ["user", "assistant"])
        let contents = history.compactMap { $0["content"] }
        XCTAssertEqual(contents.map { $0.unicodeScalars.count }, [4_000, 4_000])
        XCTAssertLessThanOrEqual(contents.reduce(0) { $0 + $1.utf8.count }, 9_000)
        XCTAssertTrue(try XCTUnwrap(contents.first).hasPrefix("Min aftale."))
        XCTAssertTrue(try XCTUnwrap(contents.first).hasSuffix(correction))
        XCTAssertTrue(try XCTUnwrap(contents.last).hasPrefix("Din aftale."))
        XCTAssertTrue(try XCTUnwrap(contents.last).hasSuffix(reply))
    }

    func testOnePhotoEditsAndQuestionsUseDifferentChatActions() {
        for text in ["Gør baggrunden blå", "Kan du ændre farven på jakken?", "Erstat himlen med skyer",
                     "Please replace the background", "Lav et billede med blå baggrund"] {
            XCTAssertNotNil(LumiChatImageRequest.requestedWithPhoto(text), text)
        }
        for text in ["", "Hvad står der på billedet?", "Beskriv billedet", "Kan du se min jakke?",
                     "What color is the jacket?", "Can you make out the writing?"] {
            XCTAssertNil(LumiChatImageRequest.requestedWithPhoto(text), text)
        }
        XCTAssertNil(LumiChatImageRequest.parse("Gør baggrunden blå"))
        XCTAssertEqual(LumiChatImageRequest.requestedWithPhoto("Tag en selfie")?.isSelfPortrait, true)
    }

    func testLumiSelfPortraitUsesHerBundledReference() throws {
        let portrait = try XCTUnwrap(LumiChatImageRequest.parse("Send et billede af dig selv på en café"))
        XCTAssertTrue(portrait.isSelfPortrait)
        XCTAssertTrue(portrait.prompt.contains("på en café"))
        XCTAssertEqual(LumiChatImageRequest.parse("Tag en selfie")?.isSelfPortrait, true)
        XCTAssertEqual(LumiChatImageRequest.parse("Lav et billede af havet")?.isSelfPortrait, false)
        XCTAssertNil(LumiChatImageRequest.parse("Jeg har et billede af Lumi"))
        let reference = try XCTUnwrap(LumiChatImageRequest.referencePortrait())
        let image = try XCTUnwrap(UIImage(data: reference)?.cgImage)
        XCTAssertLessThanOrEqual(max(image.width, image.height), 768)
        XCTAssertLessThanOrEqual(reference.count, 1_000_000)
    }

    @MainActor func testLumiPortraitRequiresOptInAndTwoRepliesAndRunsOnce() async throws {
        let portraits = LumiPortraitInitiative()
        var requests = 0
        var received: [Data] = []
        func reply(_ turn: UUID) -> Task<Void, Never>? {
            portraits.completedReply(in: turn) {
                requests += 1
                return Data([42])
            } publish: { received.append($0) } failure: { XCTFail(String(describing: $0)) }
        }
        let old = portraits.revision
        XCTAssertNil(reply(old))
        portraits.setEnabled(true)
        XCTAssertNil(reply(old))
        XCTAssertNil(reply(portraits.revision))
        portraits.interrupt() // The next user message has its own revision.
        let job = try XCTUnwrap(reply(portraits.revision))
        XCTAssertTrue(portraits.isPreparing)
        await job.value
        XCTAssertFalse(portraits.isPreparing)
        XCTAssertNil(reply(portraits.revision))
        portraits.setEnabled(false)
        portraits.setEnabled(true)
        XCTAssertNil(reply(portraits.revision))
        XCTAssertNil(reply(portraits.revision))
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(received, [Data([42])])
    }

    @MainActor func testLumiDiscardsLatePortraitAfterStopInterruptionOrClosingChat() async throws {
        for action in ["stop", "interrupt", "close"] {
            let portraits = LumiPortraitInitiative()
            portraits.setEnabled(true)
            let turn = portraits.revision
            let started = expectation(description: action)
            var finish: CheckedContinuation<Data, Never>?
            func reply() -> Task<Void, Never>? {
                portraits.completedReply(in: turn) {
                    await withCheckedContinuation { finish = $0; started.fulfill() }
                } publish: { _ in XCTFail("A late portrait was displayed") } failure: { _ in XCTFail("A cancelled request surfaced") }
            }
            XCTAssertNil(reply())
            let job = try XCTUnwrap(reply())
            await fulfillment(of: [started], timeout: 2)
            guard let finish else {
                portraits.endSession()
                return
            }
            if action == "stop" { portraits.setEnabled(false) }
            else if action == "close" { portraits.endSession() }
            else { portraits.interrupt() }
            finish.resume(returning: Data([42]))
            await job.value
            XCTAssertFalse(portraits.isPreparing)
            XCTAssertNotEqual(turn, portraits.revision)
            if action != "interrupt" { XCTAssertFalse(portraits.enabled) }
        }
    }

    func testOfflineDictationWaitsForSpeechBeforeFinishing() {
        var detector = AgentVoiceSilence(pause: 2)
        XCTAssertFalse(detector.ended(at: 1, level: -80))
        XCTAssertFalse(detector.ended(at: 2, level: -15))
        XCTAssertFalse(detector.ended(at: 5, level: -70))
        for time in [6.0, 6.15, 6.3] {
            XCTAssertFalse(detector.ended(at: time, level: -28))
        }
        XCTAssertFalse(detector.ended(at: 8, level: -75))
        XCTAssertTrue(detector.ended(at: 8.31, level: -75))
    }

    func testScannedWallPhotoFollowsPerspectiveAndThePhotographedFace() throws {
        let focal = SIMD2<Float>(0.7, 0.7), principal = SIMD2<Float>(0.5, 0.5)
        func wall(_ across: SIMD3<Float>, _ up: SIMD3<Float>) -> OfficeWallProjection {
            .init(center: .init(0, 0, -3), across: across, up: up, focal: focal, principal: principal)
        }
        let tilted = wall(.init(2, 0, 0.8), .init(0, 1.5, 0))
        var source = [UInt8](repeating: 255, count: 100 * 100 * 4)
        for y in 0..<100 { for x in 0..<100 {
            let i = (y * 100 + x) * 4
            source[i] = UInt8(x); source[i + 1] = UInt8(y)
        }}
        let image = try XCTUnwrap(tilted.rectifiedBGRA(source: source, width: 100, height: 100,
                                                       targetWidth: 4, targetHeight: 2))
        for y in 0..<2 { for x in 0..<4 {
            let wx = (Double(x) + 0.5) / 4 - 0.5, wy = 0.5 - (Double(y) + 0.5) / 2
            let distance = 3 - 0.8 * wx
            let i = (y * 4 + x) * 4
            XCTAssertEqual(Int(image[i]), Int((0.5 + 1.4 * wx / distance) * 100))
            XCTAssertEqual(Int(image[i + 1]), Int((0.5 - 1.05 * wy / distance) * 100))
        }}
        let back = wall(.init(-2, 0, 0), .init(0, 1.5, 0))
        XCTAssertFalse(back.front)
        XCTAssertLessThan(try XCTUnwrap(back.sample(.init(0, 0))).x, try XCTUnwrap(back.sample(.init(1, 0))).x)
        let rolled = wall(.init(0, 2, 0), .init(-1.5, 0, 0))
        XCTAssertGreaterThan(try XCTUnwrap(rolled.sample(.init(0, 0))).y, try XCTUnwrap(rolled.sample(.init(1, 0))).y)
    }

    func testScannedWallPhotoRejectsForegroundOutsideAndMissingGeometry() {
        func wall(_ center: SIMD3<Float>, _ across: SIMD3<Float> = .init(2, 0, 0)) -> OfficeWallProjection {
            .init(center: center, across: across, up: .init(0, 2, 0), focal: .init(repeating: 0.65),
                  principal: .init(repeating: 0.5))
        }
        let good = wall(.init(0, 0, -2))
        let depth = [Float](repeating: 2, count: 64 * 48)
        XCTAssertNotNil(good.quality(depth: depth, columns: 64, rows: 48))
        XCTAssertNil(wall(.init(2, 0, -2)).quality(depth: depth, columns: 64, rows: 48))
        XCTAssertNil(wall(.init(0, 0, 2)).quality(depth: depth, columns: 64, rows: 48))
        XCTAssertNil(wall(.init(0, 0, -2), .init(0.01, 0, 1)).quality(depth: depth, columns: 64, rows: 48))
        XCTAssertNil(good.quality(depth: .init(repeating: 4, count: depth.count), columns: 64, rows: 48))
        var occluded = depth
        for row in 10..<20 { for col in 15..<27 { occluded[row * 64 + col] = 0.8 } }
        XCTAssertNil(good.quality(depth: occluded, columns: 64, rows: 48))
        XCTAssertNil(good.quality(depth: [], columns: 0, rows: 0))
        var features: [SIMD3<Float>] = []
        for row in 0..<6 { for col in 0..<8 {
            if let p = good.sample(.init((Float(col) + 0.5) / 8, (Float(row) + 0.5) / 6)) { features.append(p) }
        }}
        XCTAssertNotNil(good.quality(depth: [], columns: 0, rows: 0, featurePoints: features))
        XCTAssertNil(good.quality(depth: [], columns: 0, rows: 0, featurePoints: Array(features.prefix(24))))
        features[2].z = 0.7
        XCTAssertNil(good.quality(depth: [], columns: 0, rows: 0, featurePoints: features))
    }

    func testOldOfficeFurnitureDecodesAndKeepsNewDimensionsWhenMoved() throws {
        let id = UUID()
        let json = """
        {"id":"\(id.uuidString)","title":"Bord","width":1,"depth":0.5,"wall":false,"x":0,"z":0,"angle":0}
        """
        var item = try JSONDecoder().decode(ScannedOfficeRoom.Item.self, from: Data(json.utf8))
        XCTAssertNil(item.height)
        XCTAssertEqual(item.displayHeight, 0.8)
        item.height = 0.95
        item.x = 10
        var room = ScannedOfficeRoom(id: UUID(), createdAt: .now, items: [])
        room.place(item)
        let saved = try JSONEncoder().encode(room)
        let reopened = try JSONDecoder().decode(ScannedOfficeRoom.self, from: saved)
        let placed = try XCTUnwrap(reopened.items.first)
        XCTAssertEqual(placed.id, id)
        XCTAssertEqual(placed.x, 1.5)
        XCTAssertEqual(placed.displayHeight, 0.95)
    }

    func testBundledVRMPortraitsMatchTheAgents() throws {
        for name in ["harper", "lumi"] {
            let url = try XCTUnwrap(VillageVRMLibrary.portraitURL(name))
            let data = try Data(contentsOf: url)
            try VillageVRMFile.validate(data)

            let manifestSize = (0..<4).reduce(0) { $0 | (Int(data[12 + $1]) << ($1 * 8)) }
            let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: data.subdata(in: 20..<(20 + manifestSize))) as? [String: Any])
            let extensions = try XCTUnwrap(manifest["extensions"] as? [String: Any])
            let vrm = try XCTUnwrap(extensions["VRMC_vrm"] as? [String: Any])
            let meta = try XCTUnwrap(vrm["meta"] as? [String: Any])
            XCTAssertEqual(meta["name"] as? String, name.capitalized)
            let expressions = try XCTUnwrap(vrm["expressions"] as? [String: [String: Any]])
            XCTAssertEqual(Set(expressions["preset"]?.keys.map { $0 } ?? []), Set(["blink", "ih", "aa"]))
            XCTAssertNotNil(expressions["custom"]?["breath"])
        }
    }

    @MainActor func testBundledCubismPortraitsRenderBlinkMouthAndBreathTogether() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let host = UIViewController()
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        for name in ["harper", "lumi"] {
            let url = try XCTUnwrap(Bundle.main.url(forResource: name, withExtension: "html",
                                                   subdirectory: "Village/cubism"))
            let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 256, height: 384))
            host.view.addSubview(view)
            defer { view.removeFromSuperview() }
            view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
            var loaded = false
            let deadline = Date.now.addingTimeInterval(40)
            while Date.now < deadline {
                if let failure = try? await view.evaluateJavaScript("window.portraitStartupError ?? null") as? String {
                    XCTFail("\(name) could not start Cubism: \(failure)")
                    break
                }
                if let ready = try? await view.evaluateJavaScript("typeof window.renderPortrait === 'function'") as? Bool,
                   ready {
                    loaded = true
                    break
                }
                try await Task.sleep(for: .milliseconds(150))
            }
            XCTAssertTrue(loaded, "\(name) failed to load the bundled Cubism player")
            guard loaded else { continue }
            let rendered = try await view.evaluateJavaScript("""
                (() => {
                    const canvas = document.querySelector("canvas");
                    const gl = canvas.getContext("webgl");
                    function frame(eye, mouth, breath) {
                        window.renderPortrait(eye, mouth, breath);
                        const pixels = new Uint8Array(canvas.width * canvas.height * 4);
                        gl.readPixels(0, 0, canvas.width, canvas.height, gl.RGBA, gl.UNSIGNED_BYTE, pixels);
                        return pixels;
                    }
                    const combined = frame(0, 1, 1);
                    const different = other => combined.some((value, index) => value !== other[index]);
                    return combined.some(value => value > 0)
                        && different(frame(1, 1, 1))
                        && different(frame(0, 0, 1))
                        && different(frame(0, 1, 0));
                })()
                """)
            XCTAssertEqual(rendered as? Bool, true, "\(name) must render all three inputs independently")
            try await checkSpokenPortrait(name: name, in: view)
        }
    }

    @MainActor private func checkSpokenPortrait(name: String, in view: WKWebView) async throws {
        let agent = name == "lumi" ? VillageBot.lumiID : UUID()
        let id = agent.uuidString
        let speech = ChristelPlayer()
        let motion = VillageSpeechMotion.shared
        // A fixed Danish eSpeak-ng clip exercises the same decoded-audio player and
        // metering used by downloaded voices, without depending on simulator voice downloads.
        let clip = try XCTUnwrap(Bundle(for: VillageDesignTests.self).url(forResource: "portrait-speech",
            withExtension: "wav", subdirectory: "Fixtures"))
        let audio = try Data(contentsOf: clip)
        defer { speech.stop() }
        speech.start(parts: [audio], agentID: agent, failure: "Fixture speech could not play.") { $0 }

        var sampledOpenness: Double?
        let deadline = Date().addingTimeInterval(25)
        while Date() < deadline, speech.loading || speech.playing {
            let now = Date()
            let mouth = motion.mouth(for: id, at: now)
            if mouth > 0.15, VillageBlink.closed(id: id, at: now), sampledOpenness == nil {
                let result = try await view.evaluateJavaScript("""
                    (() => {
                        const canvas = document.querySelector("canvas");
                        const gl = canvas.getContext("webgl");
                        function pixels(eye, mouth, breath) {
                            window.renderPortrait(eye, mouth, breath);
                            const data = new Uint8Array(canvas.width * canvas.height * 4);
                            gl.readPixels(0, 0, canvas.width, canvas.height, gl.RGBA, gl.UNSIGNED_BYTE, data);
                            return data;
                        }
                        const spoken = pixels(0, \(mouth), 0.75);
                        const differs = other => spoken.some((value, i) => value !== other[i]);
                        return differs(pixels(1, \(mouth), 0.75))
                            && differs(pixels(0, 0, 0.75))
                            && differs(pixels(0, \(mouth), 0));
                    })()
                    """)
                XCTAssertEqual(result as? Bool, true, "\(name): actual speech, blink and breath must all affect the rendered frame")
                sampledOpenness = mouth
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNotNil(sampledOpenness, "\(name) did not blink during a mouth pulse from actual speech")
        XCTAssertFalse(speech.loading || speech.playing, "\(name) did not finish speaking")
        XCTAssertNil(speech.notice, "\(name) could not play the speech fixture")
        XCTAssertEqual(motion.mouth(for: id, at: .now), 0)
    }

    func testTenDistinctChoicesAndEveryPackagedFigureRenders() throws {
        let choices = VillageCharacterCatalog.all
        XCTAssertEqual(choices.count, 10)
        XCTAssertEqual(choices.filter(\.female).count, 5)
        XCTAssertEqual(choices.filter { !$0.female }.count, 5)
        XCTAssertEqual(Set(choices.map(\.id)).count, 10)
        var images = Set<Data>()
        for choice in choices {
            let first = try XCTUnwrap(VillageProductionArt.frame(character: choice.id, direction: 0, step: 0), choice.id)
            images.insert(try XCTUnwrap(first.pngData()))
            for direction in 0..<16 {
                let still = try XCTUnwrap(VillageProductionArt.frame(character: choice.id, direction: direction, step: 0))
                let walking = try XCTUnwrap(VillageProductionArt.frame(character: choice.id, direction: direction, step: 3))
                XCTAssertEqual(still.size, CGSize(width: 128, height: 128))
                XCTAssertNotEqual(still.pngData(), walking.pngData(), "Missing walk cycle: \(choice.id), \(direction)")
            }
        }
        XCTAssertEqual(images.count, 10)
    }

    func testFigureSurvivesRenamePhotoAndSerialization() throws {
        var bot = VillageBot(name: "Nova", villageFigure: "saga")
        bot.name = "Min hjælper"
        bot.sprite = Data([1, 2, 3])
        let reopened = try JSONDecoder().decode(VillageBot.self, from: JSONEncoder().encode(bot))
        XCTAssertEqual(reopened.villageFigure, "saga")
        XCTAssertEqual(reopened.sprite, bot.sprite)
        let suite = "village.figure.test.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        VillageCharacterCatalog.index([reopened], defaults: defaults)
        XCTAssertEqual(VillageCharacterCatalog.resolved(name: "Eva", id: bot.id.uuidString, defaults: defaults), "saga")
    }

    func testOldProfilesAndInvalidFigureChoicesRemainReadable() throws {
        let bot = VillageBot(name: "Eva")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(bot)) as? [String: Any])
        json.removeValue(forKey: "villageFigure")
        let old = try JSONDecoder().decode(VillageBot.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(old.villageFigure, "eva")
        json["villageFigure"] = "../../private-file"
        let invalid = try JSONDecoder().decode(VillageBot.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(invalid.villageFigure, "eva")
        json["villageFigure"] = 42
        let malformed = try JSONDecoder().decode(VillageBot.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(malformed.id, bot.id)
        XCTAssertEqual(malformed.villageFigure, "eva")
    }

    func testLumiGetsHerOwnWalkingFigureAndMigratesHerOldDefault() throws {
        let lumi = VillageBot.lumi()
        XCTAssertEqual(lumi.villageFigure, "lumi")
        XCTAssertEqual(VillageBot.founderEva().villageFigure, "eva")
        XCTAssertFalse(VillageCharacterCatalog.all.contains { $0.id == lumi.villageFigure })

        var previous = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(lumi)) as? [String: Any])
        previous["villageFigure"] = "eva"
        let migrated = try JSONDecoder().decode(VillageBot.self, from: JSONSerialization.data(withJSONObject: previous))
        XCTAssertEqual(migrated.villageFigure, "lumi")

        let suite = "village.lumi.figure.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        VillageCharacterCatalog.index([migrated], defaults: defaults)
        XCTAssertEqual(VillageCharacterCatalog.resolved(name: "Lumi", id: lumi.id.uuidString, defaults: defaults), "lumi")

        var customized = lumi
        customized.chooseVillageFigure("eva")
        let reopened = try JSONDecoder().decode(VillageBot.self, from: JSONEncoder().encode(customized))
        XCTAssertEqual(reopened.villageFigure, "eva")

        let distinct = try XCTUnwrap(VillageProductionArt.frame(character: "lumi", direction: 0, step: 0)?.pngData())
        for character in ["eva", "saga"] {
            let existing = try XCTUnwrap(VillageProductionArt.frame(character: character, direction: 0, step: 0)?.pngData())
            XCTAssertNotEqual(distinct, existing)
        }
        for direction in 0..<16 {
            let still = try XCTUnwrap(VillageProductionArt.frame(character: "lumi", direction: direction, step: 0))
            let walking = try XCTUnwrap(VillageProductionArt.frame(character: "lumi", direction: direction, step: 3))
            XCTAssertNotEqual(still.pngData(), walking.pngData())
        }
    }

    func testFreshAgentsGetUnusedFiguresUntilTheCatalogIsFull() {
        let preferred = VillageBot(name: "Eva")
        var saved = [VillageBot.lumi()]
        for _ in VillageCharacterCatalog.all {
            var draft = preferred
            draft.id = UUID()
            draft.useAvailableVillageFigure(among: saved)
            saved.append(draft)
        }
        XCTAssertEqual(Set(saved.map(\.villageFigure)).count, 11)
        XCTAssertEqual(saved[1].villageFigure, "eva")
        XCTAssertEqual(saved[2].villageFigure, "luna")

        var manuallyPicked = VillageBot()
        manuallyPicked.chooseVillageFigure("luna")
        manuallyPicked.useAvailableVillageFigure(among: saved)
        XCTAssertEqual(manuallyPicked.villageFigure, "luna")
    }

    func testReloadRepairsAutomaticDuplicatesAndKeepsLaterChoices() throws {
        var old = VillageBot(name: "Eva", sprite: Data([1, 2, 3]))
        let other = VillageBot(name: "Luna")
        let chosen = VillageBot(name: "Min bot", villageFigure: "eva")
        let secondChosen = VillageBot(name: "Min anden bot", villageFigure: "eva")
        var rows = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode([old, other, chosen, secondChosen, .lumi()])) as? [[String: Any]])
        rows[0].removeValue(forKey: "villageFigure")
        rows[4]["villageFigure"] = "eva"
        let decoded = try VillageBot.listRecovering(from: JSONSerialization.data(withJSONObject: rows))
        XCTAssertEqual(decoded.map(\.villageFigure), ["iris", "luna", "eva", "eva", "lumi"])
        old.villageFigure = "iris"
        XCTAssertEqual(decoded.first, old)
        XCTAssertEqual(try VillageBot.listRecovering(from: JSONEncoder().encode(decoded)), decoded)
    }

    func testRoomFiguresUseSpaceAndStayInsideArtwork() {
        let phone = CGSize(width: 330, height: 215)
        XCTAssertGreaterThan(VillageRoomPlacement(index: 0, count: 1, in: phone).size, 144)
        XCTAssertGreaterThan(VillageRoomPlacement(index: 0, count: 2, in: phone).size, 144)
        for canvas in [phone, CGSize(width: 235, height: 165), CGSize(width: 92, height: 74)] {
            for count in 1...10 {
                for index in 0..<count {
                    let place = VillageRoomPlacement(index: index, count: count, in: canvas)
                    let half = place.size / 2
                    XCTAssertGreaterThan(place.size, 0)
                    XCTAssertGreaterThanOrEqual(place.center.x - half, -0.001)
                    XCTAssertGreaterThanOrEqual(place.center.y - half, -0.001)
                    XCTAssertLessThanOrEqual(place.center.x + half, canvas.width + 0.001)
                    XCTAssertLessThanOrEqual(place.center.y + half, canvas.height + 0.001)
                }
            }
        }
    }

    func testRoomSpeechPanFollowsTheDisplayedResident() {
        for size in [CGSize(width: 330, height: 215), CGSize(width: 235, height: 165)] {
            XCTAssertEqual(VillageRoomPlacement(index: 0, count: 1, in: size).pan, 0, accuracy: 0.0001)
            let left = VillageRoomPlacement(index: 0, count: 2, in: size)
            let right = VillageRoomPlacement(index: 1, count: 2, in: size)
            XCTAssertLessThan(left.pan, -0.4)
            XCTAssertGreaterThan(right.pan, 0.4)
            for count in 1...10 {
                for index in 0..<count {
                    let seat = VillageRoomPlacement(index: index, count: count, in: size)
                    XCTAssertEqual(seat.pan, Float(2 * seat.center.x / size.width - 1), accuracy: 0.0001)
                    XCTAssertTrue((-1...1).contains(seat.pan))
                }
            }
        }
        XCTAssertEqual(VillageRoomPlacement(index: 0, count: 1, in: .zero).pan, 0)
    }

    func testRoomVoiceBufferCanBeDecodedForStereoPlayback() async throws {
        let writer = VillageRoomSpeechFile()
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1))
        let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 240))
        pcm.frameLength = 240
        let samples = try XCTUnwrap(pcm.floatChannelData)[0]
        for index in 0..<240 { samples[index] = index.isMultiple(of: 2) ? 0.125 : -0.125 }
        let end = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1))
        end.frameLength = 0
        let bytes: Data = try await withCheckedThrowingContinuation { continuation in
            guard writer.start(continuation) else { return }
            writer.receive(pcm)
            writer.receive(end)
            writer.receive(end)
        }
        let audio = try AVAudioPlayer(data: bytes)
        XCTAssertEqual(audio.duration, 0.01, accuracy: 0.002)
        XCTAssertEqual(audio.numberOfChannels, 1)
    }

    @MainActor func testTemplateKeepsFigureWithoutKeepingPersonalPhoto() {
        let bot = VillageBot(name: "Test", sprite: Data([1]), villageFigure: "iris")
        let template = VillageBotTemplate(bot: bot)
        XCTAssertEqual(template.profile.villageFigure, "iris")
        XCTAssertNil(template.profile.sprite)
        XCTAssertNotEqual(template.profile.id, bot.id)
    }

    func testInteriorsCemeteryAndPortraitExpressionsAreBundled() throws {
        for name in ["map-day", "map-night", "cemetery", "personal-office", "office-slice",
                     "room-cafe", "room-research-lab", "room-media-studio", "room-sleeping-corner"] {
            XCTAssertNotNil(VillageProductionArt.image(name), name)
        }
        for name in ["harper", "lumi"] {
            var frames = Set<Data>()
            for expression in 0...3 {
                let image = try XCTUnwrap(VillageProductionArt.portrait(name, expression: expression))
                frames.insert(try XCTUnwrap(image.pngData()))
            }
            XCTAssertEqual(frames.count, 4, name)
        }
    }

    func testMapAndTouchTargetsUseSameFitTransform() {
        for size in [CGSize(width: 320, height: 420), CGSize(width: 640, height: 520)] {
            let bounds = VillageMapLayout.imageRect(in: size)
            XCTAssertLessThanOrEqual(bounds.width, size.width)
            XCTAssertLessThanOrEqual(bounds.height, size.height)
            for zone in VillageZoneID.allCases {
                XCTAssertTrue(bounds.contains(VillageMapLayout.point(VillageMapLayout.building(zone), in: size)))
                XCTAssertTrue(bounds.contains(VillageMapLayout.point(VillageMapLayout.entrance(zone), in: size)))
            }
            XCTAssertTrue(bounds.contains(VillageMapLayout.point(VillageMapLayout.cemetery, in: size)))
        }
    }
}
