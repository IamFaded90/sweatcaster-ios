// Queue load/jump/remove/clear semantics adapted from Spotube DeviceAudioPlayerQueue.kt.
// Copyright (C) 2026 Kingkor Roy Tirtho and Spotube Contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

struct MusicTrack: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    let artist: String
    let duration: Double?
}

struct MusicQueue: Codable, Equatable, Sendable {
    private(set) var entries: [MusicTrack] = []
    private(set) var currentIndex: Int?
    var current: MusicTrack? {
        guard let currentIndex, entries.indices.contains(currentIndex) else { return nil }
        return entries[currentIndex]
    }

    mutating func load(_ tracks: [MusicTrack], startPosition: Int = 0) {
        entries = Array(tracks.prefix(500))
        currentIndex = entries.isEmpty ? nil : min(max(0, startPosition), entries.count - 1)
    }
    mutating func append(_ track: MusicTrack, next: Bool = false) {
        guard entries.count < 500 else { return }
        if next, let currentIndex { entries.insert(track, at: min(currentIndex + 1, entries.count)) }
        else { entries.append(track) }
        if currentIndex == nil { currentIndex = 0 }
    }
    mutating func jump(to index: Int) {
        guard !entries.isEmpty else { currentIndex = nil; return }
        currentIndex = min(max(0, index), entries.count - 1)
    }
    @discardableResult mutating func remove(at index: Int) -> Bool {
        guard entries.indices.contains(index) else { return false }
        let wasCurrent = currentIndex == index
        entries.remove(at: index)
        if entries.isEmpty { currentIndex = nil }
        else if let currentIndex {
            self.currentIndex = min(max(0, currentIndex - (index < currentIndex ? 1 : 0)), entries.count - 1)
        }
        return wasCurrent
    }
    mutating func move(from index: Int, to destination: Int) {
        guard entries.indices.contains(index), entries.indices.contains(destination), index != destination else { return }
        let previous = currentIndex
        entries.insert(entries.remove(at: index), at: destination)
        if previous == index { currentIndex = destination }
        else if let previous, index < previous && destination >= previous { currentIndex = previous - 1 }
        else if let previous, index > previous && destination <= previous { currentIndex = previous + 1 }
    }
    mutating func clear() { entries = []; currentIndex = nil }
}

struct MusicPlaylist: Codable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var tracks: [MusicTrack]
}

struct MusicLibrarySnapshot: Codable {
    var queue: MusicQueue
    var playlists: [MusicPlaylist]
}
