import AVFoundation
import Combine
import MediaPlayer
import SwiftUI

@MainActor final class MusicPlayback: ObservableObject {
    static let shared = MusicPlayback()
    private static let storageKey = "fadedai.music.library.v1"
    @Published private(set) var queue = MusicQueue()
    @Published private(set) var playlists: [MusicPlaylist] = []
    @Published private(set) var playing = false
    @Published private(set) var loading = false
    @Published private(set) var elapsed = 0.0
    @Published private(set) var duration = 0.0
    @Published private(set) var sleepUntil: Date?
    @Published var notice: String?
    private let player = AVPlayer()
    private var api: LiveAPI?
    private var activeID: String?
    private var generation = UUID()
    private var resolving: Task<Void, Never>?
    private var prefetching: Task<Void, Never>?
    private var sleeper: Task<Void, Never>?
    private var periodic: Any?
    private var ended: NSObjectProtocol?
    private var subscriptions: [AnyCancellable] = []
    private var streams: [String: (URL, Date)] = [:]

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.storageKey), data.count <= 1_000_000,
           let saved = try? JSONDecoder().decode(MusicLibrarySnapshot.self, from: data),
           saved.queue.entries.count <= 500, saved.playlists.count <= 25 {
            queue = saved.queue
            playlists = saved.playlists.filter { $0.tracks.count <= 500 }
        }
        periodic = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 600), queue: .main) { [weak self] _ in
            Task { @MainActor in self?.updatePosition() }
        }
        NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)
            .compactMap { $0.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt }
            .receive(on: RunLoop.main).sink { [weak self] raw in
                if raw == AVAudioSession.InterruptionType.began.rawValue { self?.pause() }
            }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)
            .compactMap { $0.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt }
            .receive(on: RunLoop.main).sink { [weak self] raw in
                if raw == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue { self?.pause() }
            }.store(in: &subscriptions)
        installRemoteControls()
    }

    func configure(_ api: LiveAPI?) {
        if self.api?.queueTargetID != api?.queueTargetID { streams = [:]; prefetching?.cancel() }
        self.api = api
    }

    func load(_ tracks: [MusicTrack], index: Int = 0) {
        queue.load(tracks, startPosition: index)
        save()
        play(index: index)
    }
    func add(_ track: MusicTrack, next: Bool = false) { queue.append(track, next: next); save() }
    func clear() {
        pause(); prefetching?.cancel(); queue.clear(); player.replaceCurrentItem(with: nil)
        activeID = nil; elapsed = 0; duration = 0; streams = [:]; save(); nowPlaying()
    }
    func remove(at index: Int) {
        let changed = queue.remove(at: index)
        save()
        if changed {
            if let current = queue.currentIndex { play(index: current) }
            else { clear() }
        }
    }
    func move(from index: Int, to destination: Int) { queue.move(from: index, to: destination); save() }
    func next() {
        guard let current = queue.currentIndex, current + 1 < queue.entries.count else { pause(); return }
        play(index: current + 1)
    }
    func previous() {
        if elapsed > 3 { seek(0); return }
        play(index: max(0, (queue.currentIndex ?? 0) - 1))
    }
    func toggle() { if playing || loading { pause() } else { play(index: queue.currentIndex ?? 0) } }
    func pause() {
        generation = UUID(); resolving?.cancel(); loading = false
        player.pause(); playing = false; nowPlaying()
    }
    func seek(_ seconds: Double) {
        guard seconds.isFinite else { return }
        player.seek(to: CMTime(seconds: min(max(0, seconds), max(duration, 0)), preferredTimescale: 600))
    }

    func play(index: Int) {
        guard !queue.entries.isEmpty else { return }
        resolving?.cancel(); queue.jump(to: index); save()
        guard let track = queue.current else { return }
        let token = UUID(); generation = token; notice = nil
        if activeID == track.id, player.currentItem?.status != .failed, player.currentItem != nil {
            do {
                try activateAudio()
                if duration > 0, elapsed >= duration - 0.5 { seek(0) }
                player.play(); playing = true; nowPlaying()
            }
            catch { notice = "Kunne ikke starte lyden på iPhone." }
            return
        }
        if player.currentItem?.status == .failed { streams.removeValue(forKey: track.id) }
        player.pause(); playing = false; loading = true; elapsed = 0
        resolving = Task {
            defer { if generation == token { loading = false } }
            do {
                let url = try await stream(for: track)
                try Task.checkCancellation()
                guard generation == token else { return }
                try activateAudio()
                let item = AVPlayerItem(url: url)
                if let ended { NotificationCenter.default.removeObserver(ended) }
                ended = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
                    object: item, queue: .main) { [weak self] _ in Task { @MainActor in self?.next() } }
                player.replaceCurrentItem(with: item)
                activeID = track.id; duration = track.duration ?? 0; player.play(); playing = true; nowPlaying()
                prefetch(after: queue.currentIndex ?? 0)
            } catch {
                if !Task.isCancelled, generation == token {
                    notice = (error as? APIError)?.title ?? "PC’en kunne ikke finde lyd til nummeret. Tjek forbindelsen og prøv igen."
                }
            }
        }
    }

    private func stream(for track: MusicTrack) async throws -> URL {
        if let (url, expiry) = streams[track.id], expiry > Date() { return url }
        guard let api else { throw APIError.offline }
        struct Stream: Decodable { let url: URL; let expiresIn: Int }
        let result: Stream = try await api.moduleJSON("music/stream", upload: JSONEncoder().encode(["id": track.id]), timeout: 60)
        guard result.url.scheme == "https", result.url.host?.hasSuffix(".googlevideo.com") == true else { throw APIError.malformed }
        streams[track.id] = (result.url, Date().addingTimeInterval(Double(min(1800, max(0, result.expiresIn)))))
        return result.url
    }
    private func prefetch(after index: Int) {
        prefetching?.cancel()
        let upcoming = Array(queue.entries.dropFirst(index + 1).prefix(2))
        prefetching = Task {
            for track in upcoming {
                guard !Task.isCancelled else { return }
                _ = try? await stream(for: track)
            }
            let keep = Set(queue.entries.map(\.id))
            streams = streams.filter { keep.contains($0.key) && $0.value.1 > Date() }
        }
    }
    private func activateAudio() throws {
        let audio = AVAudioSession.sharedInstance()
        try audio.setCategory(.playback, mode: .default)
        try audio.setActive(true)
    }
    private func updatePosition() {
        guard playing || loading else { return }
        let seconds = player.currentTime().seconds
        elapsed = seconds.isFinite ? max(0, seconds) : 0
        if let seconds = player.currentItem?.duration.seconds, seconds.isFinite { duration = max(0, seconds) }
        if player.currentItem?.error != nil, !loading { notice = "Lyden kunne ikke afspilles. Prøv nummeret igen."; playing = false }
        nowPlaying()
    }
    private func nowPlaying() {
        guard let track = queue.current else { MPNowPlayingInfoCenter.default().nowPlayingInfo = nil; return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist, MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed, MPNowPlayingInfoPropertyPlaybackRate: playing ? 1.0 : 0.0]
    }
    private func installRemoteControls() {
        let remote = MPRemoteCommandCenter.shared()
        remote.playCommand.addTarget { [weak self] _ in Task { @MainActor in self?.play(index: self?.queue.currentIndex ?? 0) }; return .success }
        remote.pauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.pause() }; return .success }
        remote.togglePlayPauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.toggle() }; return .success }
        remote.nextTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.next() }; return .success }
        remote.previousTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.previous() }; return .success }
    }
    func setSleepTimer(minutes: Int?) {
        sleeper?.cancel(); sleepUntil = nil
        guard let minutes, (1...180).contains(minutes) else { return }
        sleepUntil = Date().addingTimeInterval(Double(minutes * 60))
        sleeper = Task {
            do { try await Task.sleep(for: .seconds(minutes * 60)); pause(); sleepUntil = nil }
            catch { }
        }
    }
    func savePlaylist(name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !queue.entries.isEmpty, !clean.isEmpty, clean.count <= 80, playlists.count < 25 else { return }
        playlists.append(MusicPlaylist(name: clean, tracks: queue.entries)); save()
    }
    func deletePlaylist(_ id: UUID) { playlists.removeAll { $0.id == id }; save() }
    private func save() {
        let snapshot = MusicLibrarySnapshot(queue: queue, playlists: playlists)
        guard let data = try? JSONEncoder().encode(snapshot), data.count <= 1_000_000 else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
}
