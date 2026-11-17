import AVFoundation
import AVKit
import SwiftUI

struct PCVideoReview: Decodable {
    struct Line: Decodable {
        let start: Double
        let text: String
    }
    let id, state: String
    let message: String?
    let lines: [Line]
    let previewReady: Bool
    let previewLines: [String]?

    var busy: Bool { ["analyzing", "previewing", "rendering"].contains(state) }
}

@MainActor struct VideoReviewScreen: View {
    let api: LiveAPI
    var batch: Batch? = nil
    var resumeID: String? = nil
    let onFinished: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.fadedPalette) private var palette
    @State private var review: PCVideoReview?
    @State private var lines: [String] = []
    @State private var previewedLines: [String]?
    @State private var player: AVPlayer?
    @State private var file: URL?
    @State private var notice: String?
    @State private var operation: Task<Void, Never>?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let review {
                    if review.state == "finished" {
                        FadedPrimaryButton("Vis under Jobs", icon: "checkmark.circle") {
                            onFinished()
                            dismiss()
                        }
                    } else if review.state == "ready" {
                        script(review)
                    } else if review.state == "failed", operation == nil, let batch {
                        FadedSecondaryButton("Prøv igen", icon: "arrow.clockwise") {
                            run { try await api.beginVideoReview(batch) }
                        }
                    }
                } else if operation == nil, let batch {
                    FadedPrimaryButton("Find replikker i klippet", icon: "text.bubble") {
                        run { try await api.beginVideoReview(batch) }
                    }
                } else if operation == nil, let resumeID, notice != nil {
                    FadedSecondaryButton("Prøv igen", icon: "arrow.clockwise") {
                        run(restoring: true) { try await api.videoReview(resumeID) }
                    }
                }
                if let notice {
                    FadedDetailText(notice)
                }
                if operation != nil {
                    ProgressView(progressText)
                }
            }
            .padding(FadedSpacing.edge)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .background { FadedBackground() }
        .foregroundStyle(palette.text)
        .navigationTitle("Speak og videoprøve")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if let resumeID, review == nil {
                run(restoring: true) { try await api.videoReview(resumeID) }
            }
        }
        .onDisappear {
            operation?.cancel()
            clearVideo()
        }
    }

    private var progressText: String {
        switch review?.state {
        case "previewing": "Laver prøve i lav opløsning…"
        case "rendering": "Laver den færdige video…"
        default: "Finder replikker og tidspunkter…"
        }
    }

    private func script(_ review: PCVideoReview) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if lines.isEmpty {
                FadedDetailText("PC’en fandt ingen replikker til klippet. Du kan stadig se en prøve af klipningen.")
            } else {
                FadedDetailText("Ret replikkerne. Ryd tekstfeltet for at fjerne en replik.")
                ForEach(lines.indices, id: \.self) { index in
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Ved \(review.lines[index].start.formatted(.number.precision(.fractionLength(1)))) sek.")
                            .font(.caption)
                        TextField("Replik \(index + 1)", text: $lines[index], axis: .vertical)
                            .lineLimit(2...4)
                            .padding(10)
                            .fadedGlassSurface()
                    }
                }
            }
            if let player, previewedLines == lines {
                VideoPlayer(player: player).frame(height: 360)
                    .clipShape(.rect(cornerRadius: FadedRadius.card))
            }
            if review.previewReady || file != nil {
                FadedSecondaryButton("Slet videoprøve", icon: "trash", role: .destructive) {
                    deletePreview(review)
                }.disabled(operation != nil)
            }
            FadedSecondaryButton("Lav videoprøve", icon: "play.rectangle") {
                let draft = lines
                run(preview: draft) { try await api.renderVideoReview(review.id, lines: draft, preview: true) }
            }
            .disabled(operation != nil || lines.contains { $0.unicodeScalars.count > 280 })
            if previewedLines == lines {
                FadedPrimaryButton("Godkend og lav færdig video", icon: "checkmark") {
                    let draft = lines
                    run { try await api.renderVideoReview(review.id, lines: draft, preview: false) }
                }
                .disabled(operation != nil)
            }
        }
    }

    private func run(preview draft: [String]? = nil, restoring: Bool = false,
                     work: @escaping @MainActor () async throws -> PCVideoReview) {
        guard operation == nil else { return }
        notice = nil
        if draft != nil {
            previewedLines = nil
            clearVideo()
        }
        operation = Task {
            defer { operation = nil }
            do {
                var current = try await work()
                review = current
                while current.busy {
                    try await Task.sleep(for: .seconds(2))
                    current = try await api.videoReview(current.id)
                    try Task.checkCancellation()
                    review = current
                }
                notice = current.message
                if restoring {
                    if let saved = current.previewLines, saved.count == current.lines.count {
                        lines = saved
                    } else {
                        lines = current.lines.map(\.text)
                    }
                }
                if let transcript = draft ?? (restoring ? current.previewLines : nil),
                   transcript.count == current.lines.count, current.previewReady, current.message == nil {
                    let downloaded = try await api.downloadVideoReview(current.id)
                    if Task.isCancelled {
                        try? FileManager.default.removeItem(at: downloaded)
                        return
                    }
                    file = downloaded
                    player = AVPlayer(url: downloaded)
                    previewedLines = transcript
                } else if draft == nil && lines.isEmpty {
                    lines = current.lines.map(\.text)
                }
            } catch is CancellationError {
                return
            } catch {
                if case let APIError.http(status, problem) = error {
                    notice = status == 404 ? "Videoprøven kræver den nye PC-opdatering eller er udløbet." : problem?.message
                }
                if notice == nil { notice = "PC’en kunne ikke færdiggøre videoprøven. Prøv igen." }
            }
        }
    }

    private func deletePreview(_ current: PCVideoReview) {
        guard operation == nil else { return }
        operation = Task {
            defer { operation = nil }
            do {
                if current.previewReady { review = try await api.deleteVideoReviewPreview(current.id) }
                try removeVideoCopy()
                previewedLines = nil
                notice = "Videoprøven er slettet."
            } catch {
                AppDiagnostics.record(error)
                notice = "Videoprøven kunne ikke slettes. Prøv igen."
            }
        }
    }

    private func removeVideoCopy() throws {
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        if let file { try Media(url: file, demo: false).discardTemporaryCopy() }
        file = nil
    }

    private func clearVideo() {
        do { try removeVideoCopy() }
        catch { AppDiagnostics.record(error) }
    }
}

struct Preview: View {
    @Environment(\.dismiss) private var dismiss
    let media: Media
    var savedFolder: URL? = nil
    var onDelete: (() -> Void)? = nil
    @State private var player: AVPlayer?
    @State private var invalid = false
    @State private var audioReady = false
    @State private var confirmDeletion = false
    @State private var deletionError = false
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
                if !media.demo {
                    FadedSecondaryButton(savedFolder == nil ? "Slet preview fra telefonen" : "Slet video fra telefonen",
                                         icon: "trash", role: .destructive) { confirmDeletion = true }
                }
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
            player?.replaceCurrentItem(with: nil)
            if !media.demo, savedFolder == nil {
                do { try media.discardTemporaryCopy() }
                catch { AppDiagnostics.record(error) }
            }
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        .confirmationDialog("Slet kopien fra telefonen?", isPresented: $confirmDeletion) {
            Button("Slet fra telefonen", role: .destructive) { deleteCopy() }
        }
        .alert("Videoen kunne ikke slettes.", isPresented: $deletionError) {
            Button("OK", role: .cancel) { }
        }
    }

    private func deleteCopy() {
        guard !media.demo else { return }
        player?.pause()
        do {
            if let savedFolder { try LocalFileStore(root: savedFolder).delete(media.url) }
            else { try media.discardTemporaryCopy() }
            onDelete?()
            dismiss()
        } catch {
            AppDiagnostics.record(error)
            deletionError = true
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

extension Home {
    func videoJobShareSheet(_ result: Media) -> some View {
        VStack {
            ShareLink(item: result.url) {
                Label("Del video", systemImage: "square.and.arrow.up").frame(minHeight: 48)
            }.buttonStyle(FadedButtonStyle(kind: .secondary))
            if !result.demo {
                FadedSecondaryButton("Slet preview fra telefonen", icon: "trash", role: .destructive) {
                    do {
                        try result.discardTemporaryCopy()
                        shareResult = nil
                    } catch { AppDiagnostics.record(error); localDeletionError = true }
                }
            }
        }
        .padding()
        .alert("Previewet kunne ikke slettes.", isPresented: $localDeletionError) {
            Button("OK", role: .cancel) { }
        }
        .onDisappear {
            if !result.demo {
                do { try result.discardTemporaryCopy() }
                catch { AppDiagnostics.record(error) }
            }
        }
    }
}
