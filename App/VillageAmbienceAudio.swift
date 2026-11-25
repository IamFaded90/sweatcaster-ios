import AVFAudio
import SwiftUI
import UIKit

@MainActor final class VillageAmbienceAudio: ObservableObject {
    static let shared = VillageAmbienceAudio()
    @Published var notice: String?
    private var engine: AVAudioEngine?
    private var node: AVAudioPlayerNode?
    private var owner: String?
    private var generation = UUID()
    private var live = Set<String>()
    private var playingSettings: VillageAmbience.Settings?
    private var beforePreview: (String, VillageAmbience.Settings)?
    private var interruption: NSObjectProtocol?
    private var background: NSObjectProtocol?
    private init() {
        interruption = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in Self.shared.stopAll() }
        }
        background = NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in Self.shared.stopAll() }
        }
    }
    func play(scene: String, settings: VillageAmbience.Settings) async {
        stopAll(); owner = scene; playingSettings = settings; notice = nil
        let ticket = generation
        do {
            try settings.validate()
            if let music = settings.music {
                if !settings.offlineMusicOnly || MusicLibrary.shared.localURL(music) != nil { MusicPlayer.shared.play(music) }
                else { notice = "Musikken er ikke hentet. Baggrundslyden kan stadig spilles uden PC." }
            }
            guard settings.sound != .none else { return }
            let samples = await Task.detached(priority: .utility) { VillageAmbiencePCM.samples(sound: settings.sound) }.value
            guard generation == ticket, owner == scene, !Task.isCancelled else { return }
            guard let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1),
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
                  let channel = buffer.floatChannelData?[0] else { return }
            buffer.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { if let base = $0.baseAddress { channel.update(from: base, count: $0.count) } }
            let audio = AVAudioSession.sharedInstance()
            if audio.category != .playback { try audio.setCategory(.ambient, mode: .default, options: [.mixWithOthers]) }
            try audio.setActive(true)
            let engine = AVAudioEngine(), player = AVAudioPlayerNode()
            engine.attach(player); engine.connect(player, to: engine.mainMixerNode, format: format)
            engine.mainMixerNode.outputVolume = Float(settings.volume)
            // Queue the loop synchronously before starting and retaining the audio engine.
            player.scheduleBuffer(buffer, at: nil, options: [.loops], completionHandler: nil)
            try engine.start(); player.play(); self.engine = engine; node = player
        } catch { if generation == ticket { notice = "Stemningens lyd kunne ikke startes. Dit valg er stadig gemt."; stopAll() } }
    }
    func stop(scene: String) { if owner == scene { stopAll() } }
    func register(_ scene: String) { live.insert(scene) }
    func unregister(_ scene: String) { live.remove(scene); stop(scene: scene) }
    func preview(scene: String, settings: VillageAmbience.Settings) async {
        if owner != scene, let owner, let playingSettings { beforePreview = (owner, playingSettings) }
        await play(scene: scene, settings: settings)
    }
    func endPreview(scene: String) {
        stop(scene: scene)
        let previous = beforePreview; beforePreview = nil
        if let (previousOwner, settings) = previous, live.contains(previousOwner), owner == nil {
            Task { await play(scene: previousOwner, settings: settings) }
        }
    }
    private func stopAll() {
        generation = UUID(); node?.stop(); engine?.stop(); node = nil; engine = nil; owner = nil; playingSettings = nil
    }
}
