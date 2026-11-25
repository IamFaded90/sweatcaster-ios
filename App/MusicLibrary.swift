import Foundation
import SwiftUI

@MainActor final class MusicLibrary: ObservableObject {
    static let shared = MusicLibrary()
    struct Playlist: Codable, Identifiable {
        var id = UUID()
        var name: String
        var tracks: [MusicTrack] = []
    }
    struct Saved: Codable {
        var favorites: [MusicTrack] = []
        var playlists: [Playlist] = []
        var downloads: [MusicTrack] = []
    }
    @Published private(set) var saved = Saved()
    @Published private(set) var recent: [MusicTrack] = []
    @Published var notice: String?
    @Published private(set) var downloading: Set<String> = []
    private let folder: URL
    private var downloads: [String: Task<Void, Never>] = [:]

    func startDownload(_ track: MusicTrack) {
        guard downloads[track.id] == nil else { return }
        downloads[track.id] = Task {
            await download(track)
            downloads[track.id] = nil
        }
    }

    func cancelDownload(_ track: MusicTrack) {
        downloads[track.id]?.cancel()
    }

    init(folder: URL? = nil) {
        self.folder = folder ?? URL.applicationSupportDirectory.appending(path: "FadedMusic", directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: self.folder, withIntermediateDirectories: true)
            let history = self.folder.appending(path: "recent.json")
            if let data = try? Data(contentsOf: history),
               let tracks = try? JSONDecoder().decode([MusicTrack].self, from: data) {
                recent = Array(tracks.prefix(16))
            }
            let file = self.folder.appending(path: "library.json")
            if FileManager.default.fileExists(atPath: file.path) {
                saved = try JSONDecoder().decode(Saved.self, from: Data(contentsOf: file))
            }
            let previous = saved.downloads
            saved.downloads.removeAll { localURL($0) == nil }
            for audio in try FileManager.default.contentsOfDirectory(at: self.folder, includingPropertiesForKeys: nil)
                where audio.pathExtension == "m4a" {
                let id = audio.deletingPathExtension().lastPathComponent
                if id.range(of: #"^[A-Za-z0-9_-]{11}$"#, options: .regularExpression) != nil,
                   !saved.downloads.contains(where: { $0.id == id }) {
                    saved.downloads.append(.init(id: id, title: "Hentet sang", artist: "Gendannet fra telefonen"))
                }
            }
            if saved.downloads != previous { persist() }
        } catch { notice = "Musikbiblioteket kunne ikke åbnes. " + error.localizedDescription }
    }

    func toggleFavorite(_ track: MusicTrack) {
        if saved.favorites.contains(where: { $0.id == track.id }) { saved.favorites.removeAll { $0.id == track.id } }
        else { saved.favorites.append(track) }
        MusicMix.update { $0.favorite(track.id, selected: saved.favorites.contains { $0.id == track.id }) }
        persist()
    }

    func recordPlayback(_ track: MusicTrack) {
        guard recent.first != track else { return }
        recent.removeAll { $0.id == track.id }
        recent = Array(([track] + recent).prefix(16))
        try? JSONEncoder().encode(recent).write(to: folder.appending(path: "recent.json"), options: .atomic)
    }

    func createPlaylist(_ name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= 100 else { return }
        saved.playlists.append(.init(name: clean))
        persist()
    }

    func add(_ track: MusicTrack, to id: UUID) {
        guard let index = saved.playlists.firstIndex(where: { $0.id == id }),
              !saved.playlists[index].tracks.contains(where: { $0.id == track.id }) else { return }
        saved.playlists[index].tracks.append(track)
        persist()
    }

    func remove(_ track: MusicTrack, from id: UUID) {
        guard let i = saved.playlists.firstIndex(where: { $0.id == id }) else { return }
        saved.playlists[i].tracks.removeAll { $0.id == track.id }
        persist()
    }

    func deletePlaylist(_ id: UUID) {
        saved.playlists.removeAll { $0.id == id }
        persist()
    }

    func localURL(_ track: MusicTrack) -> URL? {
        if track.id.hasPrefix("faded-song-") { return SongLibrary().localURL(track.id) }
        guard let url = downloadURL(track), FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    func addGenerated(_ track: MusicTrack) {
        guard SongLibrary().localURL(track.id) != nil else { notice = "Sangfilen mangler på telefonen."; return }
        saved.downloads.removeAll { $0.id == track.id }
        saved.downloads.append(track)
        persist()
    }

    private func downloadURL(_ track: MusicTrack) -> URL? {
        guard track.id.range(of: #"^[A-Za-z0-9_-]{11}$"#, options: .regularExpression) != nil else { return nil }
        return folder.appending(path: track.id + ".m4a")
    }

    func download(_ track: MusicTrack) async {
        guard !downloading.contains(track.id), localURL(track) == nil, let file = downloadURL(track) else { return }
        downloading.insert(track.id)
        defer { downloading.remove(track.id) }
        do {
            let source = try await MusicCatalog.audio(track)
            try Task.checkCancellation()
            var request = URLRequest(url: source)
            request.timeoutInterval = 90
            let (temporary, response) = try await URLSession.shared.download(for: request)
            defer { try? FileManager.default.removeItem(at: temporary) }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let size = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size > 100 else { throw MusicCatalog.Failure.unavailable }
            let handle = try FileHandle(forReadingFrom: temporary)
            defer { try? handle.close() }
            let header = try handle.read(upToCount: 32) ?? Data()
            guard header.range(of: Data("ftyp".utf8)) != nil else { throw MusicCatalog.Failure.noAudio }
            try Task.checkCancellation()
            try FileManager.default.moveItem(at: temporary, to: file)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var excluded = file
            try? excluded.setResourceValues(values)
            saved.downloads.append(track)
            persist()
        } catch is CancellationError { return }
        catch { if !Task.isCancelled { notice = "Sangen kunne ikke hentes. " + error.localizedDescription } }
    }

    func deleteDownload(_ track: MusicTrack) {
        if track.id.hasPrefix("faded-song-"), let id = UUID(uuidString: String(track.id.dropFirst(11))) {
            do {
                try SongLibrary().remove(id)
                saved.downloads.removeAll { $0.id == track.id }
                saved.favorites.removeAll { $0.id == track.id }
                for index in saved.playlists.indices { saved.playlists[index].tracks.removeAll { $0.id == track.id } }
                recent.removeAll { $0.id == track.id }
                try? JSONEncoder().encode(recent).write(to: folder.appending(path: "recent.json"), options: .atomic)
                for index in MusicPlayer.shared.queue.indices.reversed() where MusicPlayer.shared.queue[index].id == track.id {
                    MusicPlayer.shared.remove(at: index)
                }
                persist()
            } catch { notice = "Sangen kunne ikke slettes. " + error.localizedDescription }
            return
        }
        guard let url = downloadURL(track) else { return }
        do {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            saved.downloads.removeAll { $0.id == track.id }
            persist()
        } catch { notice = "Den hentede sang kunne ikke slettes." }
    }

    private func persist() {
        do { try JSONEncoder().encode(saved).write(to: folder.appending(path: "library.json"), options: .atomic) }
        catch { notice = "Ændringen i musikbiblioteket kunne ikke gemmes." }
    }
}
