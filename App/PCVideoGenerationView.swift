import AVKit
import PhotosUI
import QuickLook
import SwiftUI
private struct PCStudioVideoCatalog: Decodable {
    struct Mode: Decodable, Identifiable {
        let id, title: String
        let photos: Int
        let ready: Bool
        let missing: [String]
    }
    let modes: [Mode]
    let lastJob, message: String?
}

private struct PCStudioVideoJob: Decodable {
    enum State: String, Decodable { case working, ready, failed }
    let id, mode: String
    let state: State
}

private struct PCStudioVideoInput: Encodable {
    let id, mode, prompt: String
    let photos: [Data]
}
@MainActor private struct PCStudioDeleteControls: View {
    let name: String
    let hasLocal: Bool
    let local: () -> Void
    let remote: () -> Void
    @State private var confirming = false

    var body: some View {
        if hasLocal {
            Button("Slet kopi på iPhone", systemImage: "trash", role: .destructive, action: local)
                .frame(minHeight: 44)
        }
        Button("Slet fra PC og iPhone", systemImage: "trash", role: .destructive) { confirming = true }
            .frame(minHeight: 44)
            .confirmationDialog("Slet \(name)?", isPresented: $confirming, titleVisibility: .visible) {
                Button("Slet \(name)", role: .destructive, action: remote)
            } message: {
                Text("Det genererede resultat slettes. Dine originale billeder og eventuelle eksporter bliver liggende.")
            }
    }
}
@MainActor struct PCVideoGenerationView: View {
    let api: LiveAPI?
    let initialPrompt: String
    @Environment(\.scenePhase) private var scenePhase
    @State private var prompt = ""
    @State private var selected = ""
    @State private var catalog: PCStudioVideoCatalog?
    @State private var job: PCStudioVideoJob?
    @State private var notice: String?
    @State private var requestID: String?
    @State private var photos: [PhotosPickerItem] = []
    @State private var prepared: [Data] = []
    @State private var loadingPhotos = false
    @State private var refresh = 0
    @State private var loading = false
    @State private var submitting: Task<Void, Never>?
    @State private var player: AVPlayer?
    @State private var file: URL?
    @FocusState private var editing: Bool

    private struct Poll: Equatable {
        let id: String
        let refresh: Int
    }

    private var mode: PCStudioVideoCatalog.Mode? { catalog?.modes.first { $0.id == selected } }
    private var idea: String { prompt.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var locked: Bool { submitting != nil || job?.state == .working || requestID != nil }
    private var poll: Poll? {
        guard scenePhase == .active, job?.state == .working, let id = job?.id else { return nil }
        return Poll(id: id, refresh: refresh)
    }
    private var canSubmit: Bool {
        guard let mode, mode.ready, (1...1_000).contains(idea.count),
              !locked, !loadingPhotos, !loading else { return false }
        return prepared.count == mode.photos
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FadedSpacing.m) {
                NavigationLink { VeoCloudVideo(api: api, initialPrompt: prompt) } label: {
                    FadedCard(accent: FadedBrand.pc) {
                        HStack(spacing: 12) {
                            ComposioLogo(slug: "veo")
                            VStack(alignment: .leading) {
                                Text("Veo · Composio").font(.headline)
                                FadedDetailText("Video over internet · Kan bruges med PC’en slukket")
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                        }
                    }
                }.buttonStyle(.plain)
                if api == nil {
                    FadedEmptyState(icon: "desktopcomputer", title: "Forbind til din PC",
                                    detail: "Åbn Forbindelser, og par din iPhone med FadedAI på PC’en.")
                } else {
                    if let catalog { generationForm(catalog) }
                    if loading { LoadingSkeleton(label: "Tjekker videomodeller på PC’en…") }
                    if let notice { FadedToast(notice, tone: .info) }
                    jobCard
                }
            }
            .padding(FadedSpacing.edge)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .background { FadedBackground() }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Generér video")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button("Opdatér modeller og status", systemImage: "arrow.clockwise") { refresh += 1 }
                .labelStyle(.iconOnly).disabled(api == nil || loading || submitting != nil)
        }
        .onAppear { if prompt.isEmpty { prompt = initialPrompt } }
        .onDisappear {
            submitting?.cancel()
            clearFile()
        }
        .onChange(of: selected) { photos = []; prepared = [] }
        .task(id: refresh) { await reload() }
        .task(id: photos) { await loadPhotos(photos) }
        .task(id: poll) { if let poll { await watch(poll.id) } }
    }

    private func generationForm(_ catalog: PCStudioVideoCatalog) -> some View {
        FadedCard {
            VStack(alignment: .leading, spacing: FadedSpacing.m) {
                Picker("Videomodel", selection: $selected) {
                    ForEach(catalog.modes) { mode in Text(mode.title).tag(mode.id) }
                }
                if let message = catalog.message { FadedDetailText(message) }
                if let mode, !mode.ready, !mode.missing.isEmpty {
                    DisclosureGroup("Det mangler på PC’en") {
                        ForEach(mode.missing, id: \.self) { FadedDetailText($0) }
                    }
                }
                TextField("Hvad skal der ske i videoen?", text: $prompt, axis: .vertical)
                    .lineLimit(3...6).focused($editing)
                if idea.count > 1_000 { FadedDetailText("Forkort beskrivelsen til højst 1.000 tegn.") }
                if let mode, mode.photos > 0 {
                    PhotosPicker(selection: $photos, maxSelectionCount: mode.photos, selectionBehavior: .ordered,
                                 matching: .images) {
                        Label(mode.photos == 2 ? "Vælg start- og slutbillede" : "Vælg billede", systemImage: "photo")
                    }
                    .frame(minHeight: 44)
                    if loadingPhotos { ProgressView("Klargør billeder…") }
                    if !prepared.isEmpty {
                        FadedDetailText("\(prepared.count) af \(mode.photos) billeder valgt. De sendes til din PC, når du starter.")
                    }
                }
                FadedPrimaryButton("Lav video", icon: "play.fill", action: submit)
                    .disabled(!canSubmit)
                if submitting != nil { ProgressView("Sender til PC’en…") }
            }
        }
    }

    @ViewBuilder private var jobCard: some View {
        if let job {
            FadedCard {
                VStack(alignment: .leading, spacing: FadedSpacing.m) {
                    switch job.state {
                    case .working:
                        ProgressView("PC’en arbejder på videoen…")
                        FadedDetailText("Du kan gå tilbage og hente resultatet her, når det er klar.")
                    case .failed:
                        FadedDetailText("Videojobbet blev afbrudt eller udløb på PC’en. Tjek ComfyUI, og prøv igen.")
                    case .ready:
                        if let player, let file {
                            VideoPlayer(player: player).aspectRatio(16.0 / 10.0, contentMode: .fit)
                            ShareLink(item: file) { Label("Gem eller del video", systemImage: "square.and.arrow.up") }
                        } else {
                            Button("Hent video fra PC", systemImage: "play.rectangle") { loadVideo(job.id) }
                                .disabled(submitting != nil)
                        }
                    }
                    if job.state != .working {
                        PCStudioDeleteControls(name: "videoen", hasLocal: file != nil, local: { clearFile() }, remote: { remove(job.id) })
                            .disabled(submitting != nil || loading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func reload() async {
        guard let api else { return }
        loading = true
        defer { loading = false }
        do {
            let current: PCStudioVideoCatalog = try await api.moduleJSON("studio-video", timeout: 45)
            try Task.checkCancellation()
            catalog = current
            if selected.isEmpty { selected = current.modes.first(where: \.ready)?.id ?? current.modes.first?.id ?? "" }
            if let latest = current.lastJob {
                if job?.id != latest { clearFile() }
                job = try await api.studioVideo(latest)
            } else { job = nil; clearFile() }
            requestID = nil
            notice = nil
        } catch is CancellationError {
        } catch APIError.http(404, _) {
            notice = "Opdatér FadedAI på PC’en for at få videogenerering."
        } catch { report(error) }
    }

    private func loadPhotos(_ items: [PhotosPickerItem]) async {
        prepared = []
        guard !items.isEmpty else { loadingPhotos = false; return }
        loadingPhotos = true
        defer { if items == photos { loadingPhotos = false } }
        do {
            var images: [Data] = []
            for item in items {
                guard let photo = try await item.loadTransferable(type: StudioPhotoInput.self),
                      (1...1_000_000).contains(photo.data.count) else { throw APIError.input }
                images.append(photo.data)
            }
            try Task.checkCancellation()
            guard items == photos else { return }
            prepared = images
            notice = nil
        } catch is CancellationError {
        } catch { if items == photos { notice = "Ét af de valgte billeder kunne ikke læses. Vælg billederne igen." } }
    }

    private func submit() {
        guard canSubmit, let api, let mode else { return }
        editing = false
        notice = nil
        let id = UUID().uuidString.lowercased()
        let input = PCStudioVideoInput(id: id, mode: mode.id, prompt: idea, photos: prepared)
        requestID = id
        submitting = Task {
            defer { submitting = nil }
            do {
                let created: PCStudioVideoJob = try await api.moduleJSON("studio-video",
                    upload: JSONEncoder().encode(input), timeout: 80, maximumBytes: 8_000)
                try Task.checkCancellation()
                clearFile()
                job = created
                requestID = nil
            } catch is CancellationError {
            } catch {
                report(error)
                if let failure = error as? APIError {
                    switch failure {
                    case .http(401, _), .http(409, _), .http(422, _): requestID = nil
                    default: break
                    }
                }
            }
        }
    }

    private func watch(_ id: String) async {
        guard let api else { return }
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(5))
                let result = try await api.studioVideo(id)
                try Task.checkCancellation()
                guard job?.id == id else { return }
                job = result
                notice = nil
                if result.state != .working { return }
            } catch is CancellationError { return }
            catch { report(error); return }
        }
    }

    private func loadVideo(_ id: String) {
        guard let api, submitting == nil else { return }
        notice = nil
        submitting = Task {
            defer { submitting = nil }
            do {
                let result = try await api.studioVideoFile(id)
                guard !Task.isCancelled, job?.id == id else {
                    try? FileManager.default.removeItem(at: result)
                    return
                }
                clearFile()
                file = result
                player = AVPlayer(url: result)
            } catch is CancellationError {
            } catch { report(error) }
        }
    }

    private func clearFile() {
        player?.pause()
        player = nil
        if let file { try? FileManager.default.removeItem(at: file) }
        file = nil
    }

    private func remove(_ id: String) {
        guard let api, submitting == nil else { return }
        notice = nil
        submitting = Task {
            defer { submitting = nil }
            do {
                try await api.removeStudioResult("studio-video", id: id)
                try Task.checkCancellation()
                if job?.id == id {
                    clearFile()
                    job = nil
                    refresh += 1
                }
            } catch is CancellationError {
            } catch { report(error) }
        }
    }

    private func report(_ error: Error) {
        AppDiagnostics.record(error)
        if let failure = error as? APIError {
            if case .http(_, let problem) = failure, let message = problem?.message { notice = message }
            else { notice = failure.title }
        } else { notice = "PC’en svarede ikke. Opdatér status, og prøv igen." }
    }
}

extension LiveAPI {
    fileprivate func removeStudioResult(_ route: String, id: String) async throws {
        guard let id = UUID(uuidString: id) else { throw APIError.input }
        struct Receipt: Decodable { let ok: Bool }
        let receipt: Receipt = try await moduleJSON("\(route)/\(id.uuidString.lowercased())/remove",
                                                    upload: Data("{}".utf8), timeout: 25, maximumBytes: 8_000)
        guard receipt.ok else { throw APIError.malformed }
    }

    fileprivate func studioVideo(_ id: String) async throws -> PCStudioVideoJob {
        guard UUID(uuidString: id) != nil else { throw APIError.input }
        return try await moduleJSON("studio-video/\(id)", timeout: 18, maximumBytes: 8_000)
    }

    fileprivate func studioVideoFile(_ id: String) async throws -> URL {
        guard UUID(uuidString: id) != nil else { throw APIError.input }
        let url = server.origin.appending(path: "api/modules/v1/studio-video/\(id)/file")
        return try await downloadVideo(at: url)
    }
}

private struct PCStudioMeshCatalog: Decodable {
    let modes: [PCStudioVideoCatalog.Mode]
    let lastJob: PCStudioVideoJob?

    var shapeModes: [PCStudioVideoCatalog.Mode] {
        modes.filter { $0.id == "shape-text" || $0.id == "shape-image" }
    }
}

private struct PCStudioMeshInput: Encodable {
    let id = UUID().uuidString.lowercased()
    let mode: String
    let prompt: String
    let photo: Data?
}

@MainActor struct PCMeshGenerationView: View {
    let api: LiveAPI?
    @Environment(\.scenePhase) private var phase
    @State private var catalog: PCStudioMeshCatalog?
    @State private var model = ""
    @State private var prompt = ""
    @State private var photo: PhotosPickerItem?
    @State private var prepared: Data?
    @State private var preparedItem: PhotosPickerItem?
    @State private var job: PCStudioVideoJob?
    @State private var pending: PCStudioMeshInput?
    @State private var action: Task<Void, Never>?
    @State private var loadingCatalog = false
    @State private var notice: String?
    @State private var preview: URL?
    @State private var file: URL?
    @State private var refresh = 0

    private var mode: PCStudioVideoCatalog.Mode? { catalog?.shapeModes.first { $0.id == model } }
    private var text: String { prompt.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var pollKey: String? {
        guard phase == .active, let job, job.state == .working else { return nil }
        return job.id + ":" + String(refresh)
    }
    private var canStart: Bool {
        guard let mode, mode.ready, !loadingCatalog, action == nil, pending == nil, job?.state != .working else { return false }
        return mode.photos == 0 ? (1...1_000).contains(text.count) : prepared != nil && preparedItem == photo
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FadedSpacing.m) {
                if api == nil {
                    FadedEmptyState(icon: "desktopcomputer", title: "Forbind til din PC",
                                    detail: "Par din iPhone med FadedAI for at generere en 3D-model.")
                } else if let catalog {
                    FadedCard {
                        VStack(alignment: .leading, spacing: FadedSpacing.m) {
                            Picker("3D-model", selection: $model) {
                                ForEach(catalog.shapeModes) { Text($0.title).tag($0.id) }
                            }
                            .disabled(pending != nil || action != nil)
                            if mode?.photos == 1 {
                                let title = prepared == nil ? "Vælg referencebillede" : "Skift referencebillede"
                                PhotosPicker(selection: $photo, matching: .images) {
                                    Label(title, systemImage: "photo")
                                }
                                .disabled(pending != nil || action != nil)
                                FadedDetailText("Billedet sendes til den parrede PC, når du starter.")
                            } else {
                                TextField("Beskriv det, du vil lave", text: $prompt, axis: .vertical)
                                    .lineLimit(3...5)
                                    .disabled(pending != nil || action != nil)
                            }
                            if let mode, !mode.ready {
                                FadedDetailText("Mangler på PC’en: " + mode.missing.joined(separator: ", "))
                            }
                            if let pending {
                                FadedSecondaryButton("Prøv samme afsendelse igen", icon: "arrow.clockwise") { submit(pending) }
                                    .disabled(action != nil)
                                Button("Ryd afsendelse") { self.pending = nil; refresh += 1 }.disabled(action != nil)
                            } else {
                                FadedPrimaryButton("Lav 3D-model", icon: "cube.fill", action: start)
                                    .disabled(!canStart)
                            }
                        }
                    }
                    jobStatus
                }
                if loadingCatalog { ProgressView("Tjekker 3D-modeller på PC’en…") }
                if let notice { FadedToast(notice, tone: .info) }
            }
            .padding(FadedSpacing.edge)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .background { FadedBackground() }
        .navigationTitle("Generér 3D")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button("Opdatér PC-status", systemImage: "arrow.clockwise") { refresh += 1 }
                .disabled(api == nil || action != nil || loadingCatalog)
        }
        .onChange(of: model) { photo = nil; prepared = nil; preparedItem = nil }
        .task(id: photo) { await loadPhoto(photo) }
        .task(id: refresh) { await reload() }
        .task(id: pollKey) {
            if pollKey != nil, let job { await watch(job.id) }
        }
        .quickLookPreview($preview)
        .onDisappear { action?.cancel(); clearFile() }
    }

    @ViewBuilder private var jobStatus: some View {
        if let job {
            switch job.state {
            case .working: ProgressView("PC’en laver 3D-modellen…")
            case .failed: FadedDetailText("PC’en kunne ikke lave modellen. Tjek modelinstallationen, og prøv igen.")
            case .ready:
                if let file {
                    Button("Se 3D-model", systemImage: "cube") { preview = file }
                    ShareLink(item: file) { Label("Gem eller del model", systemImage: "square.and.arrow.up") }
                } else {
                    Button("Hent 3D-model", systemImage: "arrow.down.circle") { download(job.id) }
                        .disabled(action != nil)
                }
            }
            if job.state != .working {
                PCStudioDeleteControls(name: "3D-modellen", hasLocal: file != nil, local: { clearFile() }, remote: { remove(job.id) })
                    .disabled(action != nil || loadingCatalog)
            }
        }
    }

    private func reload() async {
        guard let api else { return }
        loadingCatalog = true
        defer { loadingCatalog = false }
        do {
            let current: PCStudioMeshCatalog = try await api.moduleJSON("studio-3d", timeout: 18)
            try Task.checkCancellation()
            catalog = current
            if !current.shapeModes.contains(where: { $0.id == model }) {
                model = current.shapeModes.first(where: \.ready)?.id ?? current.shapeModes.first?.id ?? ""
            }
            if job?.id != current.lastJob?.id { clearFile() }
            job = current.lastJob
            if pending?.id == job?.id { pending = nil }
            notice = nil
        } catch is CancellationError {
        } catch APIError.http(404, _) {
            notice = "Opdatér FadedAI på PC’en for at se 3D-motorerne."
        } catch { report(error) }
    }

    private func loadPhoto(_ item: PhotosPickerItem?) async {
        guard !Task.isCancelled, photo == item else { return }
        prepared = nil
        preparedItem = nil
        guard let item else { return }
        do {
            guard let input = try await item.loadTransferable(type: StudioPhotoInput.self),
                  (1...1_000_000).contains(input.data.count) else { throw APIError.input }
            try Task.checkCancellation()
            guard photo == item else { return }
            prepared = input.data
            preparedItem = item
            notice = nil
        } catch is CancellationError {
        } catch { if photo == item { notice = "Vælg et andet referencebillede." } }
    }

    private func start() {
        guard canStart, let mode else { return }
        submit(PCStudioMeshInput(mode: mode.id, prompt: mode.photos == 0 ? text : "",
                                photo: mode.photos == 1 ? prepared : nil))
    }

    private func submit(_ input: PCStudioMeshInput) {
        guard let api, action == nil else { return }
        pending = input
        notice = nil
        action = Task {
            defer { action = nil }
            do {
                let result: PCStudioVideoJob = try await api.moduleJSON("studio-3d",
                    upload: JSONEncoder().encode(input), timeout: 25, maximumBytes: 8_000)
                try Task.checkCancellation()
                clearFile()
                job = result
                pending = nil
            } catch is CancellationError {
            } catch {
                report(error)
                if case APIError.http(let status, _) = error, [401, 409, 413, 422, 503].contains(status) { pending = nil }
            }
        }
    }

    private func watch(_ id: String) async {
        guard let api, UUID(uuidString: id) != nil else { return }
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(5))
                let result: PCStudioVideoJob = try await api.moduleJSON("studio-3d/\(id)", timeout: 15, maximumBytes: 8_000)
                try Task.checkCancellation()
                guard job?.id == id else { return }
                job = result
                notice = nil
                if result.state != .working { return }
            } catch is CancellationError { return }
            catch { report(error); return }
        }
    }

    private func download(_ id: String) {
        guard let api, let uuid = UUID(uuidString: id), action == nil else { return }
        action = Task {
            defer { action = nil }
            do {
                let result = try await api.downloadStudioMesh(uuid)
                guard !Task.isCancelled, job?.id == id else {
                    try? FileManager.default.removeItem(at: result)
                    return
                }
                clearFile()
                file = result
                preview = result
            } catch is CancellationError {
            } catch { report(error) }
        }
    }

    private func clearFile() {
        preview = nil
        if let file { try? FileManager.default.removeItem(at: file) }
        file = nil
    }

    private func remove(_ id: String) {
        guard let api, action == nil else { return }
        notice = nil
        action = Task {
            defer { action = nil }
            do {
                try await api.removeStudioResult("studio-3d", id: id)
                try Task.checkCancellation()
                if job?.id == id {
                    clearFile()
                    job = nil
                    refresh += 1
                }
            } catch is CancellationError {
            } catch { report(error) }
        }
    }

    private func report(_ error: Error) {
        if case APIError.http(_, let problem) = error, let message = problem?.message { notice = message }
        else { notice = "PC’en svarede ikke. Opdatér status, og prøv igen." }
    }
}
