// Starter videojobs, viser kø og status og håndterer lokal afspilning, deling og gemte videoer.

import SwiftUI
import UIKit
import AVFoundation
import AVKit
import Foundation

private struct VideoStartBlock {
    enum Action {
        case clips, jobs, connection, refresh, resetROI

        var title: String {
            switch self {
            case .clips: "Åbn Klip"
            case .jobs: "Se jobs"
            case .connection: "Forbind til PC"
            case .refresh: "Opdatér PC-status"
            case .resetROI: "Brug standardområde"
            }
        }
    }

    let message: String
    let action: Action?

    init(_ message: String, action: Action? = nil) {
        self.message = message
        self.action = action
    }
}

extension Home {
    var videoBottomBar: some View {
        videoStartControls
            .frame(maxWidth: 640)
            .padding(.horizontal, FadedSpacing.edge).padding(.vertical, FadedSpacing.s)
            .frame(maxWidth: .infinity)
            .background(palette.raised.opacity(0.96))
    }

    private var canSubmitReason: VideoStartBlock? {
        let jobsAction: VideoStartBlock.Action? = videoPage == .jobs ? nil : .jobs
        if model.requiresVideoReview {
            return .init("Starten på et tidligere job er uafklaret. Tjek joblisten først.", action: jobsAction)
        }
        if model.checkingVideoOutbox { return .init("Kontrollerer den lokale videokø…") }
        if model.busy { return .init("Venter på svar fra PC’en.") }
        if model.refreshing { return .init("Kontrollerer forbindelsen til PC’en…") }
        if !model.cancelling.isEmpty { return .init("Venter på, at PC’en stopper videojobbet.") }
        let clipAction: VideoStartBlock.Action? = videoPage == .clips ? nil : .clips
        if model.selected.isEmpty { return .init("Vælg mindst ét klip.", action: clipAction) }
        if !model.options.roi.valid {
            return .init("Området til tekstlæsning skal ligge inden for billedet.", action: .resetROI)
        }
        if !model.connected && !model.isDemo {
            guard let live = model.api as? LiveAPI, live.server.address == model.address else {
                return .init("Forbind til en PC, før du gemmer et køjob.", action: .connection)
            }
            if !model.videoStateReadable { return .init("Videokøen kunne ikke læses. Forbind til PC’en for at starte.", action: .connection) }
            if model.videoOutbox.count >= 5 { return .init("Videokøen er fuld. Fjern eller send et køjob først.", action: jobsAction) }
            if model.selected.count > 10 { return .init("Vælg højst 10 klip til den lokale kø.", action: clipAction) }
            let savedClips = model.savedVideoClips
            if savedClips.count != model.selected.count || savedClips.contains(where: { $0.folderID == nil }) {
                return .init("Forbind til PC’en, og vælg klippene fra en spilmappe igen.", action: .connection)
            }
            if availableVideoMood == nil { return .init("Køjobbet mangler en tilgængelig stil.", action: .refresh) }
            return nil
        }
        guard model.connected else { return .init("Forbind til PC’en for at starte.", action: .connection) }
        guard let capabilities = model.capabilities else {
            return .init("PC’ens videofunktioner er ikke hentet endnu.", action: .refresh)
        }
        if model.blocked {
            let names = capabilities.missingRequired
                .filter { model.options.commentary != false || $0.name == "ffmpeg" || $0.name == "ffprobe" }
                .map(\.name).joined(separator: ", ")
            return .init("PC’en mangler: \(names). Tjek tjenesterne på PC’en.", action: .refresh)
        }
        if availableVideoMood == nil { return .init("PC’en har ingen tilgængelige stilarter.", action: .refresh) }
        if model.clips.lazy.filter({ model.selected.contains($0.id) }).count != model.selected.count {
            return .init("Et valgt klip mangler. Vælg klippene igen.", action: clipAction)
        }
        if model.selected.count > capabilities.limit {
            if capabilities.limit == 0 { return .init("PC’en tillader ingen klip lige nu.", action: .refresh) }
            return .init("PC’en tillader højst \(capabilities.limit) klip. Fjern klip fra valget.", action: clipAction)
        }
        return nil
    }

    private var videoStartControls: some View {
        let isOffline = !model.connected && !model.isDemo
        let count = model.selected.count
        let blocker = canSubmitReason
        let title = model.busy ? "Sender videojob…" : (isOffline ? "Gem i lokal kø" : "Start videomagi")
        return VStack(alignment: .leading, spacing: FadedSpacing.xs) {
            FadedPrimaryButton(count > 0 && !model.busy ? "\(title) · \(count) klip" : title,
                               icon: isOffline ? "tray.and.arrow.down" : "play.fill") {
                guard let mood = availableVideoMood else { return }
                if isOffline {
                    if model.queueVideoOffline(mood) {
                        selectedGameFolder = nil
                        videoStartNotice = "Videojob gemt på telefonen."
                        jobFilter = 0
                        showJobs += 1
                    } else {
                        videoStartNotice = "Køjobbet kunne ikke gemmes. Kontrollér klipvalget."
                    }
                } else if confirmVideoStart {
                    pendingVideoMood = mood
                } else {
                    startVideo(mood)
                }
            }.disabled(blocker != nil || !(isOffline ? model.canQueueVideoOffline : model.canSubmit))
            if let blocker {
                FadedDetailText(blocker.message)
                if let action = blocker.action {
                    Button(action.title) { resolveVideoStartBlock(action) }
                        .frame(minHeight: 44)
                }
            } else if let notice = videoStartNotice ?? (isOffline ? nil : model.errorTitle) {
                FadedDetailText(notice)
            } else if isOffline {
                FadedDetailText("Køjob sendes første gang, når appen igen får kontakt til denne PC.")
            }
        }
    }

    private func resolveVideoStartBlock(_ action: VideoStartBlock.Action) {
        switch action {
        case .clips: videoPage = .clips
        case .jobs: showJobs += 1
        case .connection: showLogin = true
        case .refresh: Task { await model.refresh() }
        case .resetROI: model.options.roi = ROI()
        }
    }

    func startVideo(_ mood: Mood) {
        videoStartNotice = nil
        Task {
            let accepted = await model.submit(mood)
            if accepted || model.requiresVideoReview {
                selectedGameFolder = nil
                jobFilter = 0
                showJobs += 1
            } else if model.error == nil {
                videoStartNotice = canSubmitReason?.message ?? "Videojobbet blev ikke sendt. Kontrollér klipvalget, og prøv igen."
            }
        }
    }

    var visibleJobs: [Job] {
        model.jobs.filter { job in
            !hiddenJobs.contains(job.id) &&
            (jobFilter == 0 || (jobFilter == 1 && job.status.active) ||
             (jobFilter == 2 && job.status == .completed) || (jobFilter == 3 && job.status == .failed))
        }
    }

    @discardableResult func prunePreviews() -> String {
        let manager = FileManager.default
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey]
        let files: [URL]
        do {
            files = try manager.contentsOfDirectory(at: manager.temporaryDirectory, includingPropertiesForKeys: Array(keys))
        } catch {
            AppDiagnostics.record(error)
            return "Mappen med midlertidige previews kunne ikke læses."
        }
        let cutoff = Date.now.addingTimeInterval(-86_400)
        var removed = 0
        var failed = 0
        for file in files where file.pathExtension == "mp4" &&
            (file.lastPathComponent.hasPrefix("Demo-") || file.lastPathComponent.hasPrefix("Sweat-")) {
            do {
                let values = try file.resourceValues(forKeys: keys)
                guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                guard let date = values.contentModificationDate else { failed += 1; continue }
                guard date < cutoff else { continue }
                try manager.removeItem(at: file)
                removed += 1
            } catch {
                AppDiagnostics.record(error)
                failed += 1
            }
        }
        if failed > 0 { return "Slettede \(removed) previews. \(failed) filer kunne ikke behandles." }
        return switch removed {
        case 0: "Ingen previews over 24 timer at rydde."
        case 1: "Ét preview over 24 timer blev slettet."
        default: "\(removed) previews over 24 timer blev slettet."
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
            VStack(alignment: .leading, spacing: FadedSpacing.s) {
                Text(model.clips.first { $0.id == job.clip_id }?.name ?? "Klip")
                    .font(FadedTypography.section).accessibilityAddTraits(.isHeader)
                Label(job.status.title + " · " + job.mood.title, systemImage: videoJobIcon(job.status))
                    .font(.subheadline.weight(.semibold)).foregroundStyle(palette.isDark ? accent : palette.text)
                if !job.message.isEmpty {
                    FadedDetailText(job.message)
                }
                if job.status.active || job.status == .completed || job.status == .failed {
                    FadedProgress(value: progress, failed: job.status == .failed)
                }
                videoJobPrimaryAction(job)
                if showJobDetails || !job.warnings.isEmpty || job.error != nil ||
                    job.status == .failed || (job.status == .completed && job.output_url != nil) {
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: FadedSpacing.s) {
                            if showJobDetails {
                                Text("\(job.id) · \(progress.formatted(.percent.precision(.fractionLength(0))))")
                                    .font(.caption.monospaced()).foregroundStyle(palette.secondary)
                            }
                            ForEach(Array(job.warnings.enumerated()), id: \.offset) { Text($0.element) }
                            if let problem = job.error { Text(problem.message) }
                            videoJobSecondaryActions(job)
                        }.padding(.top, FadedSpacing.s)
                    } label: {
                        Text("Detaljer og handlinger").frame(minHeight: 44)
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

    @ViewBuilder private func videoJobPrimaryAction(_ job: Job) -> some View {
        if job.status == .failed {
            FadedSecondaryButton("Prøv igen", icon: "arrow.clockwise") { Task { await model.retry(job) } }
                .disabled(!model.canRetry(job))
        } else if job.status.active {
            if model.waitingForStop.contains(job.id) {
                Text("Venter på, at jobbet stopper.")
            } else if model.capabilities?.features.cancel == true {
                FadedSecondaryButton(model.cancelling.contains(job.id) ? "Beder PC’en stoppe…" : "Stop job",
                                     icon: "stop.circle") { Task { await model.cancel(job) } }
                    .disabled(model.cancelling.contains(job.id) || model.busy || model.refreshing)
            }
        } else if job.status == .completed, job.output_url != nil {
            FadedSecondaryButton(model.isDemo ? "Se testvideo" : "Se video", icon: "play") {
                Task {
                    let demo = model.isDemo
                    if let url = await model.video(job) { media = Media(url: url, demo: demo) }
                }
            }.disabled(model.mediaLoading)
        }
    }

    @ViewBuilder private func videoJobSecondaryActions(_ job: Job) -> some View {
        if job.status == .failed {
            FadedSecondaryButton("Skjul fejlet job på telefonen", icon: "eye.slash") { hiddenJobs.insert(job.id) }
            if !model.isDemo, let api = model.api as? LiveAPI {
                FadedSecondaryButton("Slet fejlet job fra PC’en", icon: "trash", role: .destructive) {
                    failedJobDeletion = (job.id, api)
                }
            }
        } else if job.status == .completed, job.output_url != nil {
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
                    HStack(spacing: 8) {
                        NavigationLink {
                            Preview(media: Media(url: file, demo: false))
                        } label: {
                            Label(file.deletingPathExtension().lastPathComponent, systemImage: "film")
                                .frame(minHeight: 44)
                        }
                        Button(role: .destructive) {
                            pendingLocalDeletion = file
                        } label: {
                            Image(systemName: "trash").frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Slet \(file.deletingPathExtension().lastPathComponent) fra telefonen")
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
