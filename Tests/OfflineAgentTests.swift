import XCTest
@testable import SweatCaster

final class OfflineAgentTests: XCTestCase {
    func testSelectedVisionModelWinsOnlyWhenItFits() {
        let models = [OfflineAgentPolicy.VisionCandidate(id: "small", requiredMiB: 2_560),
                      .init(id: "large", requiredMiB: 5_000)]
        XCTAssertEqual(OfflineAgentPolicy.visionModel(preferred: "large", candidates: models, availableMiB: 6_000), "large")
        XCTAssertEqual(OfflineAgentPolicy.visionModel(preferred: "large", candidates: models, availableMiB: 3_000), "small")
        XCTAssertEqual(OfflineAgentPolicy.visionModel(preferred: "text-only", candidates: models, availableMiB: 6_000), "small")
        XCTAssertNil(OfflineAgentPolicy.visionModel(preferred: "large", candidates: models, availableMiB: 2_000))
    }

    func testVisionIgnoresUnknownRequirementsAndEmptyCatalog() {
        XCTAssertNil(OfflineAgentPolicy.visionModel(preferred: nil, candidates: [], availableMiB: 6_000))
        XCTAssertNil(OfflineAgentPolicy.visionModel(preferred: "unknown", candidates: [.init(id: "unknown", requiredMiB: 0)], availableMiB: 6_000))
        XCTAssertEqual(OfflineAgentPolicy.visionModel(preferred: nil, candidates: [.init(id: "exact", requiredMiB: 2_560)], availableMiB: 2_560), "exact")
        let ordered = [OfflineAgentPolicy.VisionCandidate(id: "preferred-by-catalog", requiredMiB: 2_560),
                       .init(id: "lower-minimum-not-lower-peak", requiredMiB: 2_048)]
        XCTAssertEqual(OfflineAgentPolicy.visionModel(preferred: nil, candidates: ordered, availableMiB: 6_000), "preferred-by-catalog")
    }

    func testVoiceChecksEverythingBeforeRecording() {
        func check(chat: Bool = true, dictation: Bool = true, pc: Bool = false,
                   downloaded: Bool = true, pack: Bool = true, apple: Bool = false) -> OfflineAgentPolicy.VoiceReadiness {
            OfflineAgentPolicy.voiceReadiness(chatReady: chat, dictationReady: dictation, pcVoice: pc,
                downloadedVoice: downloaded, packReady: pack, systemVoiceReady: apple)
        }
        XCTAssertEqual(check(), .ready)
        XCTAssertEqual(check(chat: false), .missingChat)
        XCTAssertEqual(check(dictation: false), .missingDictation)
        XCTAssertEqual(check(pc: true, apple: true), .needsLocalVoice)
        XCTAssertEqual(check(pack: false, apple: true), .missingVoicePack)
        XCTAssertEqual(check(downloaded: false, pack: false, apple: true), .ready)
        XCTAssertEqual(check(downloaded: false), .unavailableVoice)
        XCTAssertNil(check().message)
        XCTAssertNotNil(check(pc: true).message)
    }
}
