// Viser jobs og udbakke og håndterer lokal afspilning, deling og gemte videoer.

import SwiftUI
import UIKit
import AVFoundation
import AVKit
import Foundation

extension Home {
    var visibleJobs: [Job] {
        model.jobs.filter { job in
            !hiddenJobs.contains(job.id) &&
            (jobFilter == 0 || (jobFilter == 1 && job.status.active) ||
             (jobFilter == 2 && job.status == .completed) || (jobFilter == 3 && job.status == .failed))
        }
    }

    func prunePreviews() {
        let files = try? FileManager.default.contentsOfDirectory(
            at: FileManager.default.temporaryDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey])
        for file in files ?? [] where file.pathExtension == "mp4" &&
            (file.lastPathComponent.hasPrefix("Demo-") || file.lastPathComponent.hasPrefix("Sweat-")) {
            if let values = try? file.resourceValues(forKeys: [.contentModificationDateKey]),
               let date = values.contentModificationDate, Date().timeIntervalSince(date) > 86400 {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    @ViewBuilder var videoOutboxSection: some View {
        if !model.videoOutbox.isEmpty {
            FadedCard(accent: palette.cyan) {
                VStack(alignment: .leading, spacing: 12) {
                    FadedSectionLabel("Lokal videokø · \(model.videoOutbox.count) / 5")
                    Text("Kun til den valgte PC-forbindelse.").font(.caption).foregroundStyle(palette.secondary)
                    if model.checkingVideoOutbox { ProgressView("Kontrollerer køens klip…") }
                    if let notice = model.videoOutboxNotice { Text(notice).font(.subheadline).foregroundStyle(palette.secondary) }
                    ForEach(model.videoOutbox) { item in videoOutboxRow(item) }
                    if model.connected && model.videoOutbox.contains(where: { $0.state == .waiting }) {
                        FadedSecondaryButton("Kontrollér lokal kø", icon: "arrow.clockwise") {
                            Task { await model.deliverQueuedVideos() }
                        }.disabled(model.checkingVideoOutbox || model.requiresVideoReview || switchDisabled)
                    }
                }
            }
        }
    }

    private func videoOutboxRow(_ item: VideoOutboxItem) -> some View {
        let status: String = switch item.state {
        case .waiting: "Afventer kontrol på PC’en"
        case .attempted: model.checkingVideoOutbox && model.busy ? "Sender til PC’en…" : "Afsendelse uafklaret. Tjek videojoblisten."
        case .rejected: item.message ?? "PC’en afviste jobbet."
        }
        return VStack(alignment: .leading, spacing: 5) {
            Divider()
            Label("\(item.batch.mood.title) · \(item.batch.clip_ids.count) klip", systemImage: "film").font(.headline)
            Text(item.clips.map { $0.clip.name }.joined(separator: ", ")).font(.caption).foregroundStyle(palette.secondary)
                .lineLimit(2)
            Text(item.createdAt, format: .dateTime.day().month().hour().minute())
                .font(.caption).foregroundStyle(palette.secondary)
            Text(status).font(.subheadline).foregroundStyle(palette.secondary)
            if item.state != .attempted {
                FadedSecondaryButton("Fjern fra lokal kø", icon: "trash", role: .destructive) {
                    model.removeQueuedVideo(item.id)
                }.disabled(model.checkingVideoOutbox)
            }
        }
    }

    var jobSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            FadedSectionLabel("Dine videojobs").accessibilityFocused($jobsFocus)
            if videoTypeSize.isAccessibilitySize { videoJobFilter.pickerStyle(.menu).frame(minHeight: 44) }
            else { videoJobFilter.pickerStyle(.segmented) }
            if model.requiresVideoReview {
                FadedCard(accent: palette.coral) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Starten blev ikke bekræftet. Tjek joblisten for at se, om dine klip allerede er i gang.")
                        FadedSecondaryButton("Jeg har tjekket listen", icon: "checkmark") {
                            Task {
                                await model.acknowledgeAfterReview()
                                if phase == .active { await model.deliverQueuedVideos() }
                            }
                        }.disabled(switchDisabled)
                    }
                }
            }
            if visibleJobs.isEmpty {
                if jobFilter != 0, model.jobs.contains(where: { !hiddenJobs.contains($0.id) }) {
                    FadedEmptyState(icon: "line.3.horizontal.decrease", title: "Ingen jobs i dette filter",
                                    detail: "Vis hele joblisten for at se de andre jobs.", actionTitle: "Vis alle jobs") { jobFilter = 0 }
                } else if model.refreshing {
                    LoadingSkeleton(label: "Henter videojobs…")
                } else {
                    FadedEmptyState(icon: "film", title: "Ingen videoer at vise", detail: "Job vises her, når du starter en video.")
                }
            }
            if let saveVideoNotice { Text(saveVideoNotice).foregroundStyle(palette.secondary) }
            ForEach(visibleJobs.sorted { $0.created_at > $1.created_at }) { job in
                videoJobCard(job).id("video-job:\(job.id)")
            }
        }
        .sheet(item: $shareResult) { result in
            ShareLink(item: result.url) {
                Label("Del video", systemImage: "square.and.arrow.up").frame(minHeight: 48)
            }.buttonStyle(FadedButtonStyle(kind: .secondary)).padding()
        }
    }

    private var videoJobFilter: some View {
        Picker("Vis jobs", selection: $jobFilter) {
            Text("Alle").tag(0)
            Text("Aktive").tag(1)
            Text("Klar").tag(2)
            Text("Fejl").tag(3)
        }
    }

    private func videoJobCard(_ job: Job) -> some View {
        let progress = job.status == .completed ? 1 : min(1, max(0, job.progress))
        let accent = videoJobAccent(job.status)
        return FadedCard(accent: accent) {
            VStack(alignment: .leading, spacing: 8) {
                Text(model.clips.first { $0.id == job.clip_id }?.name ?? "Klip")
                    .font(FadedTypography.section).accessibilityAddTraits(.isHeader)
                Label(job.status.title + " · " + job.mood.title, systemImage: videoJobIcon(job.status))
                    .font(.subheadline.weight(.semibold)).foregroundStyle(palette.isDark ? accent : palette.text)
                Text(job.message).font(.subheadline).foregroundStyle(palette.secondary)
                if job.status.active || job.status == .completed || job.status == .failed {
                    FadedProgress(value: progress, failed: job.status == .failed)
                }
                if showJobDetails {
                    Text("\(job.id) · \(progress.formatted(.percent.precision(.fractionLength(0))))")
                        .font(.caption.monospaced()).foregroundStyle(palette.secondary)
                }
                videoJobActions(job)
                if !job.warnings.isEmpty || job.error != nil {
                    DisclosureGroup("Detaljer om jobbet") {
                        ForEach(Array(job.warnings.enumerated()), id: \.offset) { Text($0.element) }
                        if let problem = job.error { Text(problem.message) }
                    }
                }
            }
        }.modifier(FadedJobFeedback(status: job.status))
    }

    private func videoJobAccent(_ status: Stage) -> Color {
        switch status {
        case .completed: palette.green
        case .failed: palette.coral
        case .cancelled: palette.muted
        default: palette.cyan
        }
    }

    private func videoJobIcon(_ status: Stage) -> String {
        switch status {
        case .completed: "checkmark.circle"
        case .failed: "exclamationmark.circle"
        case .cancelled: "stop.circle"
        default: "clock"
        }
    }

    @ViewBuilder private func videoJobActions(_ job: Job) -> some View {
        if job.status == .failed {
            FadedSecondaryButton("Prøv igen", icon: "arrow.clockwise") { Task { await model.retry(job) } }
                .disabled(!model.canRetry(job))
            FadedSecondaryButton("Skjul fejlet job på telefonen", icon: "eye.slash") { hiddenJobs.insert(job.id) }
            if !model.isDemo, let api = model.api as? LiveAPI {
                FadedSecondaryButton("Slet fejlet job fra PC’en", icon: "trash", role: .destructive) {
                    failedJobDeletion = (job.id, api)
                }
            }
        }
        if job.status.active {
            if model.waitingForStop.contains(job.id) {
                Text("Venter på, at jobbet stopper.")
            } else if model.capabilities?.features.cancel == true {
                FadedSecondaryButton(model.cancelling.contains(job.id) ? "Beder PC’en stoppe…" : "Stop job",
                                     icon: "stop.circle") { Task { await model.cancel(job) } }
                    .disabled(model.cancelling.contains(job.id) || model.busy || model.refreshing)
            }
        }
        if job.status == .completed, job.output_url != nil {
            FadedSecondaryButton(model.isDemo ? "Se testvideo" : "Se video", icon: "play") {
                Task {
                    let demo = model.isDemo
                    if let url = await model.video(job) { media = Media(url: url, demo: demo) }
                }
            }.disabled(model.mediaLoading)
            if !model.isDemo {
                FadedSecondaryButton("Gem på telefonen", icon: "square.and.arrow.down") { Task { await saveVideo(job) } }
                    .disabled(model.mediaLoading)
            }
            FadedSecondaryButton("Del job-resultat", icon: "square.and.arrow.up") {
                Task {
                    if let url = await model.video(job) { shareResult = Media(url: url, demo: model.isDemo) }
                }
            }.disabled(model.mediaLoading)
            if !model.isDemo, let api = model.api as? LiveAPI {
                FadedSecondaryButton("Slet redigeret video fra PC’en", icon: "trash", role: .destructive) {
                    pcDeletion = (job.id, api)
                }.disabled(deletingPCVideo || model.mediaLoading)
            }
        }
    }


    private var videoFolder: URL { URL.applicationSupportDirectory.appending(path: "SavedVideos", directoryHint: .isDirectory) }

    func reloadSavedVideos() {
        let files = (try? FileManager.default.contentsOfDirectory(at: videoFolder, includingPropertiesForKeys: nil)) ?? []
        savedVideos = files.filter {
            $0.pathExtension == "mp4" && (try? LocalFileStore.checkedFileSize($0, maximumBytes: Int.max)) != nil
        }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    private func saveVideo(_ job: Job) async {
        saveVideoNotice = nil
        guard let downloaded = await model.video(job) else { return }
        defer { try? FileManager.default.removeItem(at: downloaded) }
        do {
            let filename = Date.now.formatted(.iso8601).replacingOccurrences(of: ":", with: "-")
            let target = videoFolder.appendingPathComponent("\(filename)-\(UUID().uuidString.prefix(6)).mp4")
            try LocalFileStore.copyProtectedFile(from: downloaded, to: target, within: videoFolder,
                                                 maximumBytes: LocalFileStore.maximumVideoBytes)
            saveVideoNotice = "Videoen er gemt på telefonen."
        } catch { AppDiagnostics.record(error); saveVideoNotice = "Videoen kunne ikke gemmes. Tjek ledig plads." }
    }

    func deletePCVideo(_ id: String, using api: LiveAPI) async {
        guard !deletingPCVideo else { return }
        deletingPCVideo = true
        defer { deletingPCVideo = false }
        do {
            try await api.deletePCVideo(id)
            await model.refresh()
            saveVideoNotice = "Den redigerede video er slettet fra PC’en."
        } catch {
            AppDiagnostics.record(error)
            saveVideoNotice = "PC’en kunne ikke bekræfte sletningen. Opdater joblisten."
        }
    }

    var savedVideoLibrary: some View {
        NavigationStack {
            List {
                if savedVideos.isEmpty {
                    FadedEmptyState(icon: "film.stack", title: "Ingen gemte videoer",
                                    detail: "Åbn et færdigt job, og vælg Gem på telefonen.", actionTitle: "Åbn Video Studio") {
                        showSavedVideos = false
                        selectSpace(.gallery)
                        showJobs += 1
                    }.listRowBackground(Color.clear)
                }
                ForEach(savedVideos, id: \.self) { file in
                    NavigationLink {
                        Preview(media: Media(url: file, demo: false))
                    } label: {
                        Label(file.deletingPathExtension().lastPathComponent, systemImage: "film")
                            .frame(minHeight: 44)
                    }
                    .swipeActions(allowsFullSwipe: false) {
                        Button("Slet fra telefonen", role: .destructive) { pendingLocalDeletion = file }
                    }
                }
            }.navigationTitle("Gemte videoer")
                .toolbar { Button("Luk") { showSavedVideos = false } }
                .confirmationDialog("Slet den gemte video fra telefonen?", isPresented: Binding(
                    get: { pendingLocalDeletion != nil },
                    set: { if !$0 { pendingLocalDeletion = nil } }
                ), presenting: pendingLocalDeletion) { file in
                    Button("Slet fra telefonen", role: .destructive) {
                        do { try FileManager.default.removeItem(at: file); reloadSavedVideos() }
                        catch { AppDiagnostics.record(error); localDeletionError = true }
                        pendingLocalDeletion = nil
                    }
                }
                .alert("Videoen kunne ikke slettes.", isPresented: $localDeletionError) {
                    Button("OK", role: .cancel) {}
                }
        }
    }
}

struct Preview: View {
    @Environment(\.dismiss) private var dismiss
    let media: Media
    @State private var player: AVPlayer?
    @State private var invalid = false
    @State private var audioReady = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(media.demo ? "Testvideo · Demo" : "Din video")
                    .font(.title.bold()).accessibilityAddTraits(.isHeader)
                Button("Luk") { dismiss() }.frame(minHeight: 48)
                if invalid {
                    FadedEmptyState(icon: "exclamationmark.circle", title: "Videoen kan ikke afspilles",
                                    detail: "Gå tilbage, og prøv at åbne videoen igen.")
                }
                else if let player {
                    VideoPlayer(player: player).aspectRatio(9.0 / 16.0, contentMode: .fit)
                        .frame(maxHeight: 540).accessibilityLabel("Videoafspiller")
                    if !audioReady { Text("Lydudgangen kunne ikke aktiveres. Prøv igen.") }
                    Button("Afspil fra starten") {
                        activateAudio()
                        player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { completed in
                            if completed { player.play() }
                        }
                    }.frame(minHeight: 48)
                    ShareLink(item: media.url) { Text("Del video").frame(minHeight: 48) }
                        .buttonStyle(.bordered)
                } else { LoadingSkeleton(label: "Åbner video…") }
            }.padding(FadedSpacing.edge)
        }.task {
            do {
                try LocalFileStore.checkedFileSize(media.url, maximumBytes: Int.max)
                let asset = AVURLAsset(url: media.url)
                guard try await asset.load(.isPlayable) else { invalid = true; return }
                try Task.checkCancellation()
                let preview = AVPlayer(playerItem: AVPlayerItem(asset: asset))
                preview.isMuted = false
                preview.volume = 1
                player = preview
                activateAudio()
            } catch { AppDiagnostics.record(error); if !Task.isCancelled { invalid = true } }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { notice in
            guard let raw = notice.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            if type == .began { player?.pause(); audioReady = false }
            if type == .ended { activateAudio() }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)) { notice in
            if notice.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ==
                AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue { player?.pause() }
        }
        .onDisappear {
            player?.pause()
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    private func activateAudio() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback)
            try session.setActive(true)
            audioReady = true
        } catch { AppDiagnostics.record(error); audioReady = false }
    }
}
