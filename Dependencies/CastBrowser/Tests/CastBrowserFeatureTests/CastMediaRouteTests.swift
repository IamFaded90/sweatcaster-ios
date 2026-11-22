import Foundation
import XCTest
@testable import CastBrowserFeature

final class CastMediaRouteTests: XCTestCase {
    func testPCSwitchReadsVariantAndRealSegmentFromSameRelay() async throws {
        let root = URL(string: "http://192.168.1.4:8000/session/key/")!
        let master = root.appendingPathComponent("master"), variant = root.appendingPathComponent("video")
        let segment = root.appendingPathComponent("segment")
        var urls: [URL] = []
        try await CastRelayPreflight.verify(master, isPlaylist: true) { url, playlist in
            urls.append(url)
            if url == master { return Data("#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1000\n/session/key/video\n".utf8) }
            if url == variant { return Data("#EXTM3U\n#EXTINF:4,\n/session/key/segment\n".utf8) }
            XCTAssertFalse(playlist)
            return Data([0, 0, 0, 16, 102, 116, 121, 112])
        }
        XCTAssertEqual(urls, [master, variant, segment])
    }

    func testPCSwitchRejectsUnreadableMediaAndForeignPlaylistResource() async {
        let relay = URL(string: "https://pc.example/session/id/master")!
        for manifest in [false, true] {
            var reads = 0
            do {
                try await CastRelayPreflight.verify(relay, isPlaylist: manifest) { _, _ in
                    reads += 1
                    return Data((manifest ? "#EXTM3U\nhttps://other.example/film\n" : "<html>Login</html>").utf8)
                }
                XCTFail("An unavailable film passed the handoff check")
            } catch { XCTAssertEqual(reads, 1) }
        }
    }

    @MainActor func testOriginalMovieMustMatchReceiverAttemptAfterReconnecting() {
        let model = CastAppModel()
        let original = model.recentCasts
        defer { model.recentCasts = original }
        let film = VideoCandidate(url: "https://example.org/from-page.mp4", mime: "video/mp4",
                                  title: "Samme titel", pageTitle: "", pageURL: "", poster: nil,
                                  duration: 300, isDirect: true, subtitles: [], isHLSMaster: nil, hasAudioTrack: nil)
        let known = UUID()
        model.recentCasts = [RecentCast(video: film, castAt: .now, receiverAttempt: known)]
        XCTAssertEqual(model.videoConfirmed(by: known), film)
        XCTAssertNil(model.videoConfirmed(by: UUID()))
        model.retryTarget = (film, 90)
        XCTAssertEqual(model.videoConfirmed(by: model.attemptID), film)
    }

    @MainActor func testRecoveryFollowsLatestPositionAfterRewindAndIgnoresOtherMovies() async {
        let model = CastAppModel()
        let film = VideoCandidate(url: "https://example.org/movie.mp4", mime: "video/mp4",
                                  title: "Prøvefilm", pageTitle: "", pageURL: "", poster: nil,
                                  duration: 3600, isDirect: true, subtitles: [], isHLSMaster: nil, hasAudioTrack: nil)
        model.retryTarget = (film, 1200)
        model.recordPlaybackPosition(reported: 1200, estimate: 1210, duration: 3600, confirmedTarget: true)
        XCTAssertEqual(model.playbackPosition, 1210)
        model.recordPlaybackPosition(reported: 180, estimate: nil, duration: 3600, confirmedTarget: true)
        XCTAssertEqual(model.retryTarget?.position, 180)
        model.recordPlaybackPosition(reported: 180, estimate: 0, duration: 3600, confirmedTarget: true)
        XCTAssertEqual(model.retryTarget?.position, 180)
        model.recordPlaybackPosition(reported: .nan, estimate: nil, duration: 3600, confirmedTarget: true)
        XCTAssertEqual(model.retryTarget?.position, 180)
        model.recordPlaybackPosition(reported: 10, estimate: 51, duration: 50, confirmedTarget: false)
        XCTAssertEqual(model.playbackPosition, 50)
        XCTAssertEqual(model.retryTarget?.position, 180)
    }

    func testCinejoyUsesPCBeforePhoneEvenFromAnEmbeddedPlayer() {
        let embed = URL(string: "https://film.example/embed")
        let site = URL(string: "https://www.cinejoy.pk/watch/42")
        XCTAssertEqual(CastMediaRoute.order(page: embed, browserPage: site, hasPC: true), [.pc, .direct, .phone])
        XCTAssertEqual(CastMediaRoute.order(page: site, browserPage: nil, hasPC: true), [.pc, .direct, .phone])
        XCTAssertEqual(CastMediaRoute.order(page: site, browserPage: nil, hasPC: false), [.direct, .phone])
        XCTAssertEqual(CastMediaRoute.order(page: URL(string: "https://notcinejoy.pk"), browserPage: nil, hasPC: true),
                       [.direct, .pc, .phone])
    }

    func testReferringPageKeepsPlaybackPathOnly() {
        let embed = URL(string: "https://watch.example:443/embed/42?token=123#private")
        XCTAssertEqual(CastMediaRoute.referringPage(embed)?.absoluteString, "https://watch.example:443/embed/42")
        XCTAssertNil(CastMediaRoute.referringPage(URL(string: "https://person:secret@watch.example/film")))
        XCTAssertNil(CastMediaRoute.referringPage(URL(string: "data:text/html,film")))
    }
}
