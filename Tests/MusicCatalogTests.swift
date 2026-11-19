import Foundation
import XCTest
@testable import SweatCaster

final class MusicCatalogTests: XCTestCase {
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
