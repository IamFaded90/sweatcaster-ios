import XCTest
import UIKit
import WebKit
import AVFAudio
@testable import SweatCaster

final class VillageDesignTests: XCTestCase {
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

    func testLifeGardenStillLifeAndOscillator() {
        func pattern(_ cells: [Int]) -> UInt64 {
            cells.reduce(0) { $0 | (UInt64(1) << $1) }
        }
        let square = pattern([9, 10, 17, 18])
        var board = VillageLifeBoard(bits: square)
        board.advance()
        XCTAssertEqual(board.bits, square)
        let horizontal = pattern([25, 26, 27])
        board = VillageLifeBoard(bits: horizontal)
        board.advance()
        XCTAssertEqual(board.bits, pattern([18, 26, 34]))
        board.advance()
        XCTAssertEqual(board.bits, horizontal)
        XCTAssertEqual(board.generation, 2)
    }

    func testLifeGardenDoesNotWrapAcrossEdgesAndRestoresBoard() {
        var board = VillageLifeBoard.empty
        for index in [0, 7, 8] { board.toggle(index) }
        board.advance()
        XCTAssertFalse(board.contains(15))
        XCTAssertEqual(board.population, 0)
        board = .glider
        for _ in 0..<4 { board.advance() }
        XCTAssertEqual(board.bits, VillageLifeBoard.glider.bits << 9)
        XCTAssertEqual(VillageLifeBoard(rawValue: board.rawValue), board)
        XCTAssertNil(VillageLifeBoard(rawValue: "0:-1"))
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
        for name in ["harper", "lumi"] {
            let url = try XCTUnwrap(Bundle.main.url(forResource: name, withExtension: "html",
                                                   subdirectory: "Village/cubism"))
            let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 256, height: 384))
            view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
            var loaded = false
            for _ in 0..<100 {
                if let ready = try? await view.evaluateJavaScript("typeof window.renderPortrait === 'function'") as? Bool,
                   ready {
                    loaded = true
                    break
                }
                try await Task.sleep(for: .milliseconds(50))
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
        let speech = SpeechBox()
        let motion = VillageSpeechMotion.shared
        let utterance = AVSpeechUtterance(string: "Hej. Nu læser jeg en kort tekst op. Mens jeg taler, kan du se mine øjne og min mund bevæge sig. Vi har tid til at se et blink, og derefter slutter jeg med at sige tak for i dag.")
        utterance.voice = AVSpeechSynthesisVoice(language: "da-DK") ?? AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        defer { speech.stop() }
        speech.play(utterance, as: .reply(UUID()), agentID: agent)

        var sampledOpenness: Double?
        let deadline = Date().addingTimeInterval(25)
        while Date() < deadline, speech.playback != nil {
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
        XCTAssertNil(speech.playback, "\(name) did not finish speaking")
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
