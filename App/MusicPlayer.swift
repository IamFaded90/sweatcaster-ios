import AVFAudio
import AVFoundation
import MediaPlayer
import SwiftUI

// Native adaptation of Spotube's iOS playback and media-session behaviour.
// Source: team-spotube/spotube, IosMediaSession.kt and AudioPlayerQueue.kt.
@MainActor final class MusicPlayer: ObservableObject {
    static let shared = MusicPlayer()
    @Published private(set) var queue: [MusicTrack] = []
    @Published private(set) var index = 0
    @Published private(set) var playing = false
    @Published private(set) var loading = false
    @Published private(set) var position = 0.0
    @Published private(set) var duration = 0.0
    @Published var repeatAll = false
    @Published var notice: String?
    @Published private(set) var sleepUntil: Date?
    let player = AVPlayer()
    private var operation: Task<Void, Never>?
    private var observer: Any?
    private var status: NSKeyValueObservation?
    private var notifications: [NSObjectProtocol] = []
    private var commands: [(MPRemoteCommand, Any)] = []
    private var sleep: Task<Void, Never>?
    @Published private var playbackIntent = MusicPlaybackIntent.paused
    var canPause: Bool { playbackIntent == .requested }
    var current: MusicTrack? { queue.indices.contains(index) ? queue[index] : nil }

    private init() {
        player.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self, let item = self.player.currentItem else { return }
                let wasPlaying = self.playing
                let previousDuration = self.duration
                self.position = time.seconds.isFinite ? max(0, time.seconds) : 0
                self.playing = self.player.rate > 0
                let length = item.duration.seconds
                self.duration = length.isFinite ? max(0, length) : self.current?.duration ?? 0
                if wasPlaying != self.playing || previousDuration != self.duration { self.updateNowPlaying() }
            }
        }
        notifications.append(NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
                                                                     object: nil, queue: .main) { [weak self] note in
            Task { @MainActor in
                guard let self, let item = note.object as? AVPlayerItem, item === self.player.currentItem else { return }
                self.next()
            }
        })
        notifications.append(NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification,
                                                                     object: nil, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let options = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            Task { @MainActor in
                guard let self else { return }
                if raw == AVAudioSession.InterruptionType.began.rawValue {
                    if self.playbackIntent.beginInterruption() { self.suspendPlayback() }
                } else if raw == AVAudioSession.InterruptionType.ended.rawValue {
                    let allowed = AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume)
                    if self.playbackIntent.endInterruption(allowed: allowed) { self.resume() }
                }
            }
        })
        notifications.append(NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification,
                                                                     object: nil, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            if raw == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue {
                Task { @MainActor in self?.pause() }
            }
        })
        configureCommands()
    }

    func play(_ track: MusicTrack) { queue = [track]; index = 0; load() }
    func play(_ tracks: [MusicTrack], at selected: Int = 0) {
        guard tracks.indices.contains(selected) else { return }
        queue = tracks
        index = selected
        load()
    }
    func enqueue(_ track: MusicTrack) {
        let startsPlayback = queue.isEmpty
        queue.append(track)
        if startsPlayback { index = 0; load() }
    }
    func remove(at selected: Int) {
        guard queue.indices.contains(selected) else { return }
        let wasCurrent = selected == index
        queue.remove(at: selected)
        if selected < index { index -= 1 }
        if wasCurrent {
            if queue.isEmpty { stop() }
            else {
                index = min(index, queue.count - 1)
                if canPause { load() }
                else {
                    clearPlaybackItem()
                    duration = current?.duration ?? 0
                    updateNowPlaying(showSelection: true)
                }
            }
        }
    }
    func shuffle() {
        guard let current else { return }
        queue = [current] + queue.enumerated().filter { $0.offset != index }.map(\.element).shuffled()
        index = 0
    }
    func pause() {
        playbackIntent = .paused
        suspendPlayback()
    }

    private func suspendPlayback() {
        operation?.cancel()
        operation = nil
        loading = false
        player.pause()
        playing = false
        updateNowPlaying()
    }
    func toggle() { if canPause { pause() } else { resume() } }
    func retry() { load() }
    func resume() {
        guard current != nil, !loading else { return }
        if player.currentItem == nil || player.currentItem?.status == .failed { load(); return }
        do {
            try activateAudio()
            player.play()
            playbackIntent = .requested
            playing = true
            updateNowPlaying()
        } catch { notice = "Musikken kunne ikke starte. " + error.localizedDescription }
    }
    func next() {
        guard !queue.isEmpty else { return }
        if index + 1 < queue.count { index += 1; load() }
        else if repeatAll { index = 0; load() }
        else { pause(); seek(0) }
    }
    func previous() {
        if position > 3 { seek(0) }
        else if index > 0 { index -= 1; load() }
        else { seek(0) }
    }
    func seek(_ seconds: Double) {
        guard seconds.isFinite else { return }
        player.seek(to: CMTime(seconds: min(max(0, seconds), max(duration, 0)), preferredTimescale: 600))
        position = min(max(0, seconds), max(duration, 0))
        updateNowPlaying()
    }
    func stop() {
        playbackIntent = .paused
        clearPlaybackItem()
    }

    private func clearPlaybackItem() {
        operation?.cancel()
        operation = nil
        status = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        playing = false
        loading = false
        position = 0
        duration = 0
        notice = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }
    func setSleep(minutes: Int?) {
        sleep?.cancel()
        sleep = nil
        sleepUntil = minutes.map { Date().addingTimeInterval(Double($0) * 60) }
        guard let minutes else { return }
        sleep = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(minutes * 60)) } catch { return }
            self?.pause()
            self?.sleepUntil = nil
        }
    }

    private func load() {
        guard let track = current else { return }
        playbackIntent = .requested
        operation?.cancel()
        player.pause()
        player.replaceCurrentItem(with: nil)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        status = nil
        loading = true
        playing = false
        notice = nil
        position = 0
        duration = track.duration
        operation = Task {
            defer { if !Task.isCancelled { loading = false } }
            do {
                try Task.checkCancellation()
                let source: URL
                if let local = MusicLibrary.shared.localURL(track) { source = local }
                else { source = try await MusicCatalog.audio(track) }
                try Task.checkCancellation()
                try activateAudio()
                let item = AVPlayerItem(url: source)
                status = item.observe(\.status, options: [.new]) { [weak self] item, _ in
                    if item.status == .readyToPlay {
                        Task { @MainActor in
                            guard let self, self.player.currentItem === item else { return }
                            MusicLibrary.shared.recordPlayback(track)
                        }
                    } else if item.status == .failed {
                        Task { @MainActor in
                            guard let self, self.player.currentItem === item else { return }
                            self.notice = "Sangen kunne ikke afspilles. Prøv en anden udgave eller en ny søgning."
                            self.playing = false
                            self.playbackIntent = .paused
                        }
                    }
                }
                player.replaceCurrentItem(with: item)
                player.play()
                playing = true
                updateNowPlaying()
            } catch is CancellationError { return }
            catch {
                guard !Task.isCancelled else { return }
                playbackIntent = .paused
                notice = error.localizedDescription
            }
        }
    }
    private func activateAudio() throws {
        VillageSpeechMotion.shared.stopSpeaking()
        let audio = AVAudioSession.sharedInstance()
        try audio.setCategory(.playback, mode: .default, policy: .longFormAudio)
        try audio.setActive(true)
    }
    private func updateNowPlaying(showSelection: Bool = false) {
        guard let track = current, showSelection || player.currentItem != nil else { return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: track.title, MPMediaItemPropertyArtist: track.artist,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: playing ? 1.0 : 0.0
        ]
    }
    private func configureCommands() {
        let center = MPRemoteCommandCenter.shared()
        func add(_ command: MPRemoteCommand, _ action: @escaping @MainActor () -> Void) {
            let token = command.addTarget { _ in
                Task { @MainActor in action() }
                return .success
            }
            commands.append((command, token))
        }
        add(center.playCommand) { [weak self] in self?.resume() }
        add(center.pauseCommand) { [weak self] in self?.pause() }
        add(center.togglePlayPauseCommand) { [weak self] in self?.toggle() }
        add(center.nextTrackCommand) { [weak self] in self?.next() }
        add(center.previousTrackCommand) { [weak self] in self?.previous() }
        let seek = center.changePlaybackPositionCommand
        let token = seek.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in self?.seek(event.positionTime) }
            return .success
        }
        commands.append((seek, token))
    }
}

enum MusicPlaybackIntent {
    case paused, requested, interrupted

    mutating func beginInterruption() -> Bool {
        guard self == .requested else { return false }
        self = .interrupted
        return true
    }

    mutating func endInterruption(allowed: Bool) -> Bool {
        guard self == .interrupted else { return false }
        self = .paused
        return allowed
    }
}
