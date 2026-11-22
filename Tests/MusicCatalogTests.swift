import Foundation
import XCTest
@testable import SweatCaster

final class MusicCatalogTests: XCTestCase {
    @MainActor func testEditingPausedQueueKeepsNextSongSilentAndCanCancelPendingPlayback() async {
        let player = MusicPlayer.shared
        let first = MusicTrack(id: "aaaaaaaaaaa", title: "Første", artist: "Test")
        let next = MusicTrack(id: "bbbbbbbbbbb", title: "Næste", artist: "Test", duration: 90)
        player.play([first, next])
        defer { while !player.queue.isEmpty { player.remove(at: 0) } }
        XCTAssertTrue(player.loading)
        XCTAssertTrue(player.canPause)
        player.toggle()
        XCTAssertFalse(player.loading)
        XCTAssertFalse(player.canPause)
        player.remove(at: 0)
        XCTAssertEqual(player.current, next)
        XCTAssertEqual(player.duration, 90)
        XCTAssertFalse(player.loading)
        XCTAssertFalse(player.canPause)
        player.toggle()
        XCTAssertTrue(player.loading)
        XCTAssertTrue(player.canPause)
    }

    func testInterruptionResumesOnlyIfMusicWasRequestedAndSystemAllowsIt() {
        var intent = MusicPlaybackIntent.paused
        XCTAssertFalse(intent.beginInterruption())
        XCTAssertFalse(intent.endInterruption(allowed: true))
        intent = .requested
        XCTAssertTrue(intent.beginInterruption())
        XCTAssertFalse(intent.beginInterruption())
        XCTAssertTrue(intent.endInterruption(allowed: true))
        XCTAssertFalse(intent.endInterruption(allowed: true))
        intent = .requested
        XCTAssertTrue(intent.beginInterruption())
        XCTAssertFalse(intent.endInterruption(allowed: false))
        intent = .requested
        XCTAssertTrue(intent.beginInterruption())
        intent = .paused
        XCTAssertFalse(intent.endInterruption(allowed: true))
    }

    func testPublicMusicResultsPreserveTitlesAndAvoidDuplicates() throws {
        let source = #"""
        <script>var ytInitialData = {"contents":[
          {"videoRenderer":{"videoId":"abcdefghijk","title":{"runs":[{"text":"A {live} \"version\""}]},
            "ownerText":{"simpleText":"Artist"},"lengthText":{"simpleText":"1:02"}}},
          {"videoRenderer":{"videoId":"abcdefghijk","title":{"simpleText":"Repeated"}}},
          {"videoRenderer":{"videoId":"../bad","title":{"simpleText":"Invalid"}}}
        ]};</script>
        """#
        let tracks = try MusicCatalog.tracks(in: source)
        XCTAssertEqual(tracks.count, 1)
        XCTAssertEqual(tracks[0].title, "A {live} \"version\"")
        XCTAssertEqual(tracks[0].artist, "Artist")
        XCTAssertEqual(tracks[0].duration, 62)
        XCTAssertEqual(tracks[0].durationLabel, "1:02")
        XCTAssertThrowsError(try MusicCatalog.tracks(in: "<html>Unavailable</html>"))
    }

    @MainActor func testFavoritesAndPlaylistsSurviveRelaunchAndCanBeRemoved() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "music-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = MusicLibrary(folder: folder)
        let track = MusicTrack(id: "abcdefghijk", title: "Song", artist: "Artist")
        library.createPlaylist(" Min liste ")
        let id = try XCTUnwrap(library.saved.playlists.first?.id)
        library.add(track, to: id)
        library.add(track, to: id)
        library.toggleFavorite(track)
        let reopened = MusicLibrary(folder: folder)
        XCTAssertEqual(reopened.saved.playlists.first?.tracks, [track])
        XCTAssertEqual(reopened.saved.favorites, [track])
        reopened.remove(track, from: id)
        reopened.deletePlaylist(id)
        reopened.toggleFavorite(track)
        let cleared = MusicLibrary(folder: folder)
        XCTAssertTrue(cleared.saved.playlists.isEmpty)
        XCTAssertTrue(cleared.saved.favorites.isEmpty)
        XCTAssertNil(cleared.localURL(.init(id: "../bad", title: "", artist: "")))
    }
}
