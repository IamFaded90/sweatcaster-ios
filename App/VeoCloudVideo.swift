import AVKit
import Foundation
import SwiftUI

struct VeoCloudJob: Codable, Identifiable {
    enum State: String, Codable { case submitting, working, ready, failed }
    let id: UUID
    let prompt, model: String
    var state = State.submitting
    var operation: String?
    var downloadURL: URL?
    var notice: String?
    let createdAt: Date

    var generationArguments: [String: Any] {
        ["model": model, "prompt": prompt, "aspect_ratio": "16:9", "extras": ["sampleCount": 1]]
    }

    mutating func updateStatus(_ status: [String: Any]) {
        if status["error"] is [String: Any] {
            state = .failed
            notice = "Google kunne ikke færdiggøre videoen."
        } else if status["done"] as? Bool == true {
            let response = status["response"] as? [String: Any] ?? [:]
            let output = response["generateVideoResponse"] as? [String: Any] ?? response
            if (output["raiMediaFilteredCount"] as? Int ?? 0) > 0,
               (output["generatedSamples"] as? [Any] ?? []).isEmpty,
               (output["generatedVideos"] as? [Any] ?? []).isEmpty {
                state = .failed
                notice = "Google standsede videoen med sit indholdsfilter."
            } else {
                state = .ready
                notice = nil
            }
        }
    }

    mutating func clearUnavailableLink(statusCode: Int) -> Bool {
        guard state == .ready, downloadURL != nil, [401, 403, 404, 410].contains(statusCode) else { return false }
        downloadURL = nil
        notice = "Downloadlinket er udløbet eller utilgængeligt. Hent et nyt link til det samme job."
        return true
    }
}

@MainActor final class VeoCloudLibrary: ObservableObject {
    static let shared = VeoCloudLibrary()
    @Published private(set) var jobs: [VeoCloudJob] = []
    private let root = URL.applicationSupportDirectory.appendingPathComponent("FadedAI/Veo", isDirectory: true)
    private var file: URL { root.appendingPathComponent("jobs.json") }
    func video(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString.lowercased() + ".mp4") }
    func hasVideo(_ id: UUID) -> Bool { FileManager.default.fileExists(atPath: video(id).path) }

    private init() {
        if let bytes = try? LocalFileStore.readBytes(from: file, maximumBytes: 500_000),
           let saved = try? JSONDecoder().decode([VeoCloudJob].self, from: bytes) { jobs = Array(saved.prefix(30)) }
    }

    func clearMemory() { jobs = [] }

    func save(_ job: VeoCloudJob) throws {
        var next = jobs
        if let index = next.firstIndex(where: { $0.id == job.id }) { next[index] = job }
        else {
            guard next.count < 30 else { throw ComposioCloudError.unavailable("Slet et gammelt Veo-job, før du opretter flere.") }
            next.insert(job, at: 0)
        }
        try LocalFileStore.writeBytes(JSONEncoder().encode(next), to: file, within: root)
        jobs = next
    }

    func remove(_ id: UUID) throws {
        if hasVideo(id) { try LocalFileStore(root: root).delete(video(id)) }
        let next = jobs.filter { $0.id != id }
        try LocalFileStore.writeBytes(JSONEncoder().encode(next), to: file, within: root)
        jobs = next
    }

    func storeVideo(_ data: Data, id: UUID) throws {
        guard jobs.contains(where: { $0.id == id }), data.count <= 80_000_000 else { throw APIError.input }
        try LocalFileStore.writeBytes(data, to: video(id), within: root)
        objectWillChange.send()
    }
}

@MainActor struct VeoCloudVideo: View {
    let api: LiveAPI?
    var initialPrompt = ""
    @ObservedObject private var account = ComposioCloudAccount.shared
    @ObservedObject private var library = VeoCloudLibrary.shared
    @Environment(\.scenePhase) private var phase
    @State private var models: [String] = []
    @State private var model = ""
    @State private var prompt = ""
    @State private var catalogRead = false
    @State private var busy = false
    @State private var notice: String?
    @State private var checking = Set<UUID>()
    @State private var player: AVPlayer?
    @State private var playing = false
    @State private var downloading = Set<UUID>()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FadedSpacing.m) {
                if !account.enabled { ComposioCloudSetup(api: api) }
                FadedCard(accent: FadedBrand.pc) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 12) {
                            ComposioLogo(slug: "veo")
                            VStack(alignment: .leading) {
                                Text("Veo · Composio").font(.headline)
                                FadedDetailText("Video via internet. PC’en kan være slukket.")
                            }
                        }
                        if !models.isEmpty {
                            Picker("Veo-model", selection: $model) {
                                ForEach(models, id: \.self) { Text($0).tag($0) }
                            }
                        }
                        TextField("Beskriv videoen", text: $prompt, axis: .vertical).lineLimit(3...6)
                        FadedDetailText("Én kort video i 16:9. Forbrug afhænger af din Google-konto.")
                        FadedPrimaryButton("Lav video med Veo", icon: "video") { submit() }
                            .disabled(busy || models.isEmpty || !models.contains(model)
                                      || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || prompt.count > 1000)
                        if busy { ProgressView("Kontakter Veo…") }
                        if let notice { FadedDetailText(notice) }
                        if catalogRead && models.isEmpty {
                            NavigationLink {
                                PCVideoGenerationView(api: api, initialPrompt: prompt, showsVeoLink: false)
                            } label: {
                                Label("Brug beskrivelsen i PC-studiet", systemImage: "desktopcomputer")
                            }.frame(minHeight: 44)
                        }
                    }
                }
                ForEach(library.jobs) { job in jobCard(job) }
            }
            .padding(FadedSpacing.edge).frame(maxWidth: 640).frame(maxWidth: .infinity)
        }
        .background { FadedBackground() }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Veo")
        .toolbar {
            Button("Opdatér modeller", systemImage: "arrow.clockwise") { Task { await loadModels() } }.disabled(busy || !account.enabled)
        }
        .onAppear { if prompt.isEmpty { prompt = initialPrompt } }
        .task(id: account.enabled) { if account.enabled { await loadModels() } }
        .task(id: phase) {
            guard phase == .active else { return }
            while !Task.isCancelled {
                for job in library.jobs where job.state == .working { await check(job) }
                do { try await Task.sleep(for: .seconds(12)) } catch { return }
            }
        }
        .sheet(isPresented: $playing, onDismiss: { player?.pause(); player = nil }) {
            if let player { VideoPlayer(player: player).onAppear { player.play() } }
        }
    }

    private func jobCard(_ job: VeoCloudJob) -> some View {
        FadedCard {
            VStack(alignment: .leading, spacing: 10) {
                Text(job.prompt).font(.subheadline.weight(.semibold)).lineLimit(3)
                switch job.state {
                case .submitting:
                    FadedDetailText("Start blev ikke bekræftet. Status er ukendt. Der startes ikke automatisk en ny video.")
                case .working:
                    ProgressView("Veo arbejder…")
                    Button("Tjek status") { Task { await check(job) } }.disabled(checking.contains(job.id))
                case .ready:
                    if library.hasVideo(job.id) {
                        Button("Afspil video", systemImage: "play.circle") {
                            player = AVPlayer(url: library.video(job.id))
                            playing = true
                        }.frame(minHeight: 44)
                        ShareLink(item: library.video(job.id)) { Label("Gem eller del video", systemImage: "square.and.arrow.up") }
                    } else if let url = job.downloadURL {
                        Button("Hent video til iPhone", systemImage: "arrow.down.circle") {
                            Task { await fetchVideo(url, job: job) }
                        }.disabled(downloading.contains(job.id)).frame(minHeight: 44)
                        if downloading.contains(job.id) { ProgressView("Henter video…") }
                    } else {
                        Button("Hent nyt videolink", systemImage: "arrow.down.circle") { Task { await check(job) } }
                            .disabled(checking.contains(job.id)).frame(minHeight: 44)
                    }
                case .failed: FadedDetailText("Videoen kunne ikke laves.")
                }
                if let text = job.notice { FadedDetailText(text) }
                if job.state != .working && !downloading.contains(job.id) {
                    Button("Fjern fra denne iPhone", systemImage: "trash", role: .destructive) {
                        do { try library.remove(job.id) } catch { notice = error.localizedDescription }
                    }.frame(minHeight: 44)
                }
            }
        }
    }

    private func fetchVideo(_ url: URL, job: VeoCloudJob) async {
        guard downloading.insert(job.id).inserted else { return }
        defer { downloading.remove(job.id) }
        do {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.httpShouldSetCookies = false
            configuration.urlCredentialStorage = nil
            configuration.timeoutIntervalForResource = 180
            let network = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
            defer { network.invalidateAndCancel() }
            let (bytes, response) = try await network.bytes(from: url)
            guard let http = response as? HTTPURLResponse else { throw ComposioCloudError.invalidResponse }
            var updated = job
            if updated.clearUnavailableLink(statusCode: http.statusCode) {
                if library.jobs.contains(where: { $0.id == job.id }) { try library.save(updated) }
                return
            }
            guard http.statusCode == 200,
                  response.expectedContentLength <= 80_000_000 else { throw ComposioCloudError.invalidResponse }
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < 80_000_000 else { throw ComposioCloudError.invalidResponse }
                data.append(byte)
            }
            guard data.count >= 12, String(data: data[4..<8], encoding: .ascii) == "ftyp" else {
                throw ComposioCloudError.invalidResponse
            }
            try library.storeVideo(data, id: job.id)
            notice = "Videoen er hentet og kan afspilles offline."
        } catch { notice = error.localizedDescription }
    }

    private func loadModels() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            let client = try await ComposioCloud.client()
            let search = try await client.discover("Veo VEO_LIST_MODELS available video generation models.")
            let result = try await client.execute("VEO_LIST_MODELS", arguments: [:], discovery: search)
            let rows = (result["models"] as? [[String: Any]]) ?? []
            let fallback = (result["raw"] as? [String: Any])?["models"] as? [[String: Any]] ?? []
            let names = rows + fallback
            models = Array(Set(names.compactMap { ($0["name"] ?? $0["id"]) as? String }
                .map { $0.hasPrefix("models/") ? String($0.dropFirst(7)) : $0 }.filter { $0.hasPrefix("veo-") })).sorted()
            let nextPage = result["nextPageToken"] as? String ?? (result["raw"] as? [String: Any])?["nextPageToken"] as? String
            if models.isEmpty || !(nextPage ?? "").isEmpty {
                models = try await Self.allModels(client, discovery: search)
            }
            catalogRead = true
            if !models.contains(model) { model = models.first(where: { $0.contains("fast") }) ?? models.first ?? "" }
            notice = models.isEmpty ? "Denne forbindelse viser ingen Veo-modeller. Google lukkede Veo 3.1 Preview i Gemini API den 22. oktober 2026. Du kan bruge samme beskrivelse i dit PC-studie." : nil
        } catch {
            if !Task.isCancelled {
                models = []
                model = ""
                catalogRead = false
                notice = "Kunne ikke hente Veo-modeller. \(error.localizedDescription) Prøv Opdatér modeller igen."
            }
        }
    }

    static func allModels(_ client: ComposioCloud, discovery: [String: Any]) async throws -> [String] {
        guard let session = discovery["session"] as? [String: Any], let id = session["id"] as? String else {
            throw ComposioCloudError.invalidResponse
        }
        let code = """
        import json
        models = set()
        token = None
        for page in range(20):
            params = {"pageSize": 1000}
            if token:
                params["pageToken"] = token
            catalog, catalog_error = proxy_execute(method="GET", endpoint="https://generativelanguage.googleapis.com/v1beta/models", toolkit="veo", query_params=params)
            if catalog_error:
                raise RuntimeError("Veo model catalog could not be read")
            for item in catalog.get("models", []):
                name = item.get("name", "").removeprefix("models/")
                if name.startswith("veo-"):
                    models.add(name)
            token = catalog.get("nextPageToken")
            if not token:
                break
        if token:
            raise RuntimeError("Veo model catalog is incomplete")
        print("FADEDAI_VEO_MODELS:" + json.dumps(sorted(models)))
        """
        let result = try await client.call("COMPOSIO_REMOTE_WORKBENCH", [
            "session_id": id, "code_to_execute": code, "current_step": "CHECKING_VEO_MODELS",
            "thought": "Read the complete model catalog because VEO_LIST_MODELS exposes only the first page."
        ])
        let data = result["data"] as? [String: Any] ?? [:]
        guard let output = data["stdout"] as? String,
              let line = output.components(separatedBy: .newlines).last(where: { $0.hasPrefix("FADEDAI_VEO_MODELS:") }),
              let models = try JSONSerialization.jsonObject(with: Data(line.dropFirst("FADEDAI_VEO_MODELS:".count).utf8)) as? [String] else {
            throw ComposioCloudError.invalidResponse
        }
        return models.filter { $0.hasPrefix("veo-") && $0.count <= 160 }
    }

    private func submit() {
        guard !busy, models.contains(model) else { return }
        busy = true
        let idea = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            defer { busy = false }
            var job = VeoCloudJob(id: UUID(), prompt: idea, model: model, createdAt: .now)
            do {
                let client = try await ComposioCloud.client()
                let search = try await client.discover("Veo VEO_GENERATE_VIDEOS text to video generation.")
                try library.save(job)
                let result = try await client.execute("VEO_GENERATE_VIDEOS", arguments: job.generationArguments, discovery: search)
                guard let operation = Self.operation(result), operation.count <= 512 else { throw ComposioCloudError.uncertain }
                job.operation = operation
                job.state = .working
                try library.save(job)
                notice = "Veo laver videoen. Du kan gå tilbage og åbne jobbet senere."
            } catch {
                if case ComposioCloudError.unavailable = error {
                    job.state = .failed
                    job.notice = error.localizedDescription
                    do { try library.save(job) } catch { notice = "Kunne ikke gemme jobstatus." }
                }
                notice = error.localizedDescription
            }
        }
    }

    static func operation(_ result: [String: Any]) -> String? {
        if let name = result["operation_name"] as? String ?? result["name"] as? String,
           name.hasPrefix("operations/") || name.contains("/operations/") { return name }
        if let nested = result["operation"] as? [String: Any] { return operation(nested) }
        return nil
    }

    private func check(_ job: VeoCloudJob) async {
        guard let operation = job.operation, checking.insert(job.id).inserted else { return }
        defer { checking.remove(job.id) }
        do {
            let client = try await ComposioCloud.client()
            let search = try await client.discover("Veo VEO_GET_VIDEOS_OPERATION get the status of an existing video operation.")
            let result = try await client.execute("VEO_GET_VIDEOS_OPERATION",
                                                  arguments: ["operation_name": operation], discovery: search)
            var updated = job
            let status = result["operation"] as? [String: Any] ?? result
            updated.updateStatus(status)
            guard library.jobs.contains(where: { $0.id == job.id }) else { return }
            if updated.state != job.state { try library.save(updated) }
            guard updated.state == .ready else { return }
            do {
                updated.downloadURL = try await download(status, job: job, client: client)
                updated.notice = updated.downloadURL == nil ? "Veo er færdig. Prøv at hente videolinket igen." : nil
            } catch {
                guard !Task.isCancelled else { return }
                updated.notice = "Videoen er færdig. Linket kunne ikke hentes. \(error.localizedDescription)"
            }
            if library.jobs.contains(where: { $0.id == job.id }) { try library.save(updated) }
        } catch { if !Task.isCancelled { notice = error.localizedDescription } }
    }

    private func download(_ result: [String: Any], job: VeoCloudJob, client: ComposioCloud) async throws -> URL? {
        guard let uri = Self.videoURL(result) else { return nil }
        let search = try await client.discover("Veo VEO_DOWNLOAD_VIDEO download a completed video to a file.")
        let path = "/tmp/fadedai-veo-" + job.id.uuidString.lowercased() + ".mp4"
        let saved = try await client.execute("VEO_DOWNLOAD_VIDEO",
            arguments: ["video_uri": uri.absoluteString, "download_path": path], discovery: search)
        let file = saved["path"] as? String ?? ""
        if let url = URL(string: file), url.scheme == "https", url.user == nil, url.password == nil { return url }
        // Composio downloads can be materialized in its remote workspace.
        guard file == path else { throw ComposioCloudError.invalidResponse }
        let code = """
        import os
        path = "\(path)"
        if not os.path.isfile(path):
            print("FADEDAI_VIDEO_NOT_FOUND")
        else:
            uploaded, upload_error = upload_local_file(path)
            if upload_error:
                print("FADEDAI_VIDEO_UPLOAD_FAILED")
            else:
                print(uploaded.get("s3_url", "FADEDAI_VIDEO_NO_URL"))
        """
        let uploaded = try await client.call("COMPOSIO_REMOTE_WORKBENCH", [
            "session_id": (search["session"] as? [String: Any])?["id"] as? String ?? "",
            "code_to_execute": code, "current_step": "EXPORTING_GENERATED_VIDEO",
            "thought": "Export the already generated video for playback on the user's iPhone."
        ])
        let data = uploaded["data"] as? [String: Any] ?? [:]
        let output = data["stdout"] as? String ?? data["output"] as? String ?? ""
        guard let line = output.split(whereSeparator: \.isWhitespace).first(where: { $0.hasPrefix("https://") }),
              let url = URL(string: String(line)), url.scheme == "https" else {
            throw ComposioCloudError.unavailable("Veo er færdig, men Composio kunne ikke levere videofilen til iPhone.")
        }
        return url
    }

    static func videoURL(_ result: [String: Any]) -> URL? {
        let response = result["response"] as? [String: Any] ?? [:]
        let output = response["generateVideoResponse"] as? [String: Any] ?? response
        let videos = output["generatedSamples"] as? [[String: Any]] ?? output["generatedVideos"] as? [[String: Any]] ?? []
        let video = videos.first?["video"] as? [String: Any] ?? [:]
        guard let value = video["uri"] as? String ?? result["download_url"] as? String,
              let url = URL(string: value), url.scheme == "https", url.user == nil, url.password == nil else { return nil }
        return url
    }
}
