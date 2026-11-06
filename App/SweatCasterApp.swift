import AVKit
import SwiftUI

@main struct SweatCasterApp: App {
    var body: some Scene { WindowGroup { Home() } }
}

private struct Media: Identifiable {
    let id = UUID()
    let url: URL
    let demo: Bool
}

struct Home: View {
    @Environment(\.scenePhase) private var phase
    @State private var model = Model()
    @State private var setup = true
    @State private var address = ""
    @State private var token = ""
    @State private var media: Media?
    @State private var showChat = false
    @State private var errorDetails = false
    @AccessibilityFocusState private var errorFocus: Bool
    @AccessibilityFocusState private var jobsFocus: Bool
    @State private var showJobs = 0

    var body: some View {
        @Bindable var model = model
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("AI Sweat-Caster").font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
                action("Chat med AI-holdet") { showChat = true }
                    .disabled(model.busy)
                if model.isDemo {
                    Text("Demotilstand · Kun testdata").font(.headline)
                }
                if let error = model.error {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(error.title).font(.headline).accessibilityFocused($errorFocus)
                        if let detail = error.detail {
                            DisclosureGroup("Tekniske detaljer", isExpanded: $errorDetails) {
                                Text(detail).textSelection(.enabled)
                            }
                        }
                    }
                }
                DisclosureGroup("Forbindelse til PC", isExpanded: $setup) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Brug adressen og adgangskoden, som vises på PC’en.")
                        TextField("Adresse fra PC’en", text: $address)
                            .accessibilityLabel("PC-adresse")
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .keyboardType(.URL).textFieldStyle(.roundedBorder)
                            .frame(minHeight: 48)
                        SecureField("Adgangskode fra PC’en", text: $token)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .textFieldStyle(.roundedBorder).frame(minHeight: 48)
                        action("Test forbindelse") {
                            Task {
                                await model.connect(address: address, token: token)
                                if model.error == nil && !model.isDemo { token = ""; setup = false }
                            }
                        }.disabled(switchDisabled)
                        if model.isDemo {
                            action("Prøv demo") { setup = false }
                        } else {
                            Text(model.connected ? "Forbundet til PC" : "Ingen forbindelse").font(.headline)
                            action("Skift til demo") {
                                Task { await model.useDemo(); setup = false }
                            }.disabled(switchDisabled)
                        }
                    }.padding(.top, 12)
                }.font(.body)
                if model.busy || model.refreshing || model.mediaLoading {
                    ProgressView(model.mediaLoading ? "Henter video…" : "Vent et øjeblik…")
                }
                clipSection
                moodSection
                jobSection
                advanced($model.options)
            }.padding(20).frame(maxWidth: 620).frame(maxWidth: .infinity)
        }
        .onChange(of: showJobs) {
            proxy.scrollTo("jobs", anchor: .top)
            jobsFocus = true
        }
        }
        .onAppear {
            if !model.address.isEmpty { address = "http://\(model.address):8765/api/v1" }
            setup = model.address.isEmpty || model.isDemo
            prunePreviews()
        }
        .onChange(of: model.error?.title) { _, title in
            errorDetails = false
            if title != nil { errorFocus = true }
        }
        .task(id: phase) {
            if phase == .active { await model.refresh() }
        }
        .task(id: phase == .active && model.hasActive) {
            guard phase == .active && model.hasActive else { return }
            while !Task.isCancelled && model.hasActive {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                if !Task.isCancelled { await model.poll() }
            }
        }
        .sheet(item: $media) { item in
            Preview(media: item)
        }
        .sheet(isPresented: $showChat, onDismiss: {
            if !model.isDemo { Task { await model.refresh() } }
        }) {
            ChatView(api: model.api as? any ChatAPI, demo: model.isDemo)
        }
    }

    private var switchDisabled: Bool {
        model.busy || model.refreshing || model.mediaLoading || !model.cancelling.isEmpty
    }

    private func prunePreviews() {
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

    private var clipSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            heading("1. Vælg klip")
            if let caps = model.capabilities {
                Text("Valgt: \(model.selected.count) af \(caps.limit)")
            }
            if model.clips.isEmpty { Text("Ingen klip at vise.") }
            ForEach(model.clips) { clip in
                let selected = model.selected.contains(clip.id)
                Button { model.toggle(clip) } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(clip.name).font(.headline)
                            Text("\(clip.duration_seconds.formatted(.number.precision(.fractionLength(0...1)).locale(Locale(identifier: "da_DK")))) sek.")
                        }
                        Spacer(minLength: 0)
                    }.frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                        .contentShape(Rectangle())
                }.buttonStyle(.bordered)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .disabled(model.busy || (!selected && model.selected.count >= (model.capabilities?.limit ?? 0)))
            }
            action("Opdater klip") { Task { await model.refresh() } }.disabled(switchDisabled)
        }
    }

    private var moodSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            heading("2. Vælg stil")
            if let caps = model.capabilities {
                if model.blocked { Text("PC’en er ikke klar til at lave videoer.").font(.headline) }
                if !caps.dependencies.isEmpty {
                    DisclosureGroup("Status på PC’en") {
                        ForEach(caps.dependencies, id: \.name) { dependency in
                            Text(dependency.message)
                        }
                    }
                }
                if caps.moods.isEmpty { Text("PC’en tilbyder ingen stilarter lige nu.") }
                ForEach(Mood.allCases) { mood in
                    if caps.moods.contains(mood) {
                        Button {
                            Task {
                                await model.submit(mood)
                                if model.error == nil || model.uncertain { showJobs += 1 }
                            }
                        } label: {
                            Text(mood.title).font(.headline)
                                .frame(maxWidth: .infinity, minHeight: 52)
                                .contentShape(Rectangle())
                        }.buttonStyle(.borderedProminent)
                            .tint(Color(red: 0.06, green: 0.31, blue: 0.65))
                            .environment(\.colorScheme, .light)
                            .disabled(!model.canSubmit || !model.cancelling.isEmpty)
                            .accessibilityHint("Starter valgte klip")
                    }
                }
            }
        }
    }

    private var jobSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            heading("3. Følg dine videoer").accessibilityFocused($jobsFocus)
            if model.uncertain {
                Text("Starten blev ikke bekræftet. Tjek joblisten for at se, om dine klip allerede er i gang.")
                action("Jeg har tjekket listen") {
                    Task { await model.acknowledgeAfterReview() }
                }.disabled(switchDisabled)
            }
            if model.jobs.isEmpty { Text("Ingen videoer endnu.") }
            ForEach(model.jobs.sorted { $0.created_at > $1.created_at }) { job in
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.clips.first { $0.id == job.clip_id }?.name ?? "Klip")
                        .font(.headline).accessibilityAddTraits(.isHeader)
                    Text(job.mood.title + " · " + job.status.title)
                    Text(job.message)
                    if job.status.active {
                        let progress = min(1, max(0, job.progress))
                        ProgressView(value: progress)
                            .accessibilityLabel("Fremskridt")
                            .accessibilityValue(progress.formatted(.percent.precision(.fractionLength(0))))
                        if model.waitingForStop.contains(job.id) {
                            Text("Venter på, at jobbet stopper.")
                        } else if model.capabilities?.features.cancel == true {
                            action(model.cancelling.contains(job.id) ? "Beder PC’en stoppe…" : "Stop job") {
                                Task { await model.cancel(job) }
                            }.disabled(model.cancelling.contains(job.id) || model.busy || model.refreshing)
                        }
                    }
                    if job.status == .completed, job.output_url != nil {
                        action(model.isDemo ? "Se testvideo" : "Se video") {
                            Task {
                                let demo = model.isDemo
                                if let url = await model.video(job) { media = Media(url: url, demo: demo) }
                            }
                        }.disabled(model.mediaLoading)
                    }
                    if !job.warnings.isEmpty || job.error != nil {
                        DisclosureGroup("Detaljer om jobbet") {
                            ForEach(Array(job.warnings.enumerated()), id: \.offset) {
                                Text($0.element)
                            }
                            if let problem = job.error { Text(problem.message) }
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14).background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
            }
        }.id("jobs")
    }

    private func advanced(_ options: Binding<Options>) -> some View {
        DisclosureGroup("Avancerede indstillinger") {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Beskæring", selection: options.crop_mode) {
                    Text("Automatisk").tag(Crop.auto)
                    Text("Midten").tag(Crop.center)
                }.frame(minHeight: 48)
                Toggle("Fjern støj", isOn: options.denoise).frame(minHeight: 48)
                Text("Område til tekstlæsning").font(.headline)
                Text("Brug tal fra 0 til 1, målt fra øverste venstre hjørne.")
                coordinate("Fra venstre", options.roi.x)
                coordinate("Fra toppen", options.roi.y)
                coordinate("Bredde", options.roi.width)
                coordinate("Højde", options.roi.height)
                if !model.options.roi.valid {
                    Text("Området skal have en bredde og højde og ligge inden for billedet.")
                }
            }.padding(.top, 12)
        }
    }

    private func coordinate(_ title: String, _ value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
            TextField(title, value: value, format: .number.locale(Locale(identifier: "da_DK")))
                .keyboardType(.numbersAndPunctuation).textFieldStyle(.roundedBorder)
                .frame(minHeight: 48)
        }
    }
    private func heading(_ title: String) -> some View {
        Text(title).font(.title2.bold()).accessibilityAddTraits(.isHeader)
    }
    private func action(_ title: String, _ work: @escaping () -> Void) -> some View {
        Button(action: work) {
            Text(title).frame(minHeight: 48).contentShape(Rectangle())
        }.buttonStyle(.bordered)
    }
}

private struct Preview: View {
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
                if invalid { Text("Videoen kan ikke afspilles på telefonen.") }
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
                } else { ProgressView("Åbner video…") }
            }.padding(20)
        }.task {
            let asset = AVURLAsset(url: media.url)
            do {
                guard try await asset.load(.isPlayable) else { invalid = true; return }
                try Task.checkCancellation()
                let preview = AVPlayer(playerItem: AVPlayerItem(asset: asset))
                preview.isMuted = false
                preview.volume = 1
                player = preview
                activateAudio()
            } catch { if !Task.isCancelled { invalid = true } }
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
        } catch { audioReady = false }
    }
}

private struct ChatTurn: Identifiable {
    let id = UUID()
    let prompt: String
    var reply = ""
    var notice: String?
}

private struct ChatView: View {
    @Environment(\.dismiss) private var dismiss
    let api: (any ChatAPI)?
    let demo: Bool
    @State private var sessionID = UUID()
    @State private var draft = ""
    @State private var turns: [ChatTurn] = []
    @State private var status: String?
    @State private var streamedText = ""
    @State private var task: Task<Void, Never>?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Chat med AI-holdet").font(.title.bold()).accessibilityAddTraits(.isHeader)
                Button("Luk") { stop(); dismiss() }.frame(minHeight: 48)
                if demo { Text("Demotilstand · Ingen rigtige job").font(.headline) }
                Text("AI’en arbejder på din PC. Researcher bruger internettet til websøgning.")
                ForEach(turns) { turn in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(turn.prompt).font(.headline)
                        if !turn.reply.isEmpty { Text(turn.reply).textSelection(.enabled) }
                        if let notice = turn.notice { Text(notice).font(.callout) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12).background(.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                }
                if let status { Text(status).font(.callout) }
                TextField("Din besked", text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(2...5).frame(minHeight: 48)
                if task != nil {
                    Button { stop() } label: { Text("Stop modtagelse").frame(minHeight: 48) }
                        .buttonStyle(.bordered)
                } else {
                    Button { send() } label: { Text("Send besked").frame(minHeight: 48) }
                        .buttonStyle(.borderedProminent)
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.padding(20)
        }.onDisappear { stop() }
    }

    private func send() {
        let message = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard task == nil, !message.isEmpty else { return }
        draft = ""
        streamedText = ""
        turns.append(ChatTurn(prompt: message))
        let index = turns.count - 1
        status = "Venter på svar…"
        let input = ChatRequest(message: message, session_id: sessionID)
        task = Task {
            do {
                if demo {
                    status = "Demo · Finder et testklip…"
                    try await Task.sleep(for: .milliseconds(600))
                    turns[index].reply = "Jeg fandt et testklip. "
                    try await Task.sleep(for: .milliseconds(600))
                    turns[index].reply += "Demoen starter ikke et video-job."
                } else {
                    guard let api else { throw ChatFailure.unauthorized }
                    await run(api, input: input, index: index)
                }
            } catch is CancellationError {
                turns[index].notice = "Modtagelsen er stoppet."
            } catch {
                turns[index].notice = (error as? ChatFailure ?? .interrupted).message
            }
            status = nil
            task = nil
        }
    }

    private func run(_ api: any ChatAPI, input: ChatRequest, index: Int) async {
        do {
            try await api.chat(input) { event in
                await MainActor.run {
                    guard !Task.isCancelled else { return }
                    switch event.type {
                    case "tool_status": status = safeText(event.content)
                    case "text":
                        streamedText += event.content
                        turns[index].reply = safeText(streamedText)
                    case "done":
                        turns[index].reply = safeText(streamedText, complete: true)
                    default: break
                    }
                }
            }
            try Task.checkCancellation()
        } catch {
            turns[index].notice = Task.isCancelled ? "Modtagelsen er stoppet. Et job kan stadig køre."
                : (error as? ChatFailure ?? .interrupted).message
        }
    }

    private func safeText(_ text: String, complete: Bool = false) -> String {
        let safe = (api as? LiveAPI)?.redactChat(text, complete: complete) ?? text
        if safe.contains("Traceback (most recent call last)") { return "PC’en sendte en intern fejl." }
        return safe.replacingOccurrences(of: #"(?i)(?:\b[A-Z]:[\\/]|\\\\)[^\r\n`"<>]+"#,
                                         with: "[filsti skjult]", options: .regularExpression)
    }

    private func stop() { task?.cancel() }
}
