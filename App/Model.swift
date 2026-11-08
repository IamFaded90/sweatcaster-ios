import Foundation
import Observation

@MainActor @Observable final class Model {
    private(set) var api: any SweatAPI
    private let demo = MockAPI()
    private let defaults: UserDefaults
    private var pendingKey: String?
    private var revision = 0
    private(set) var isDemo = true
    private(set) var clips: [Clip] = []
    private(set) var jobs: [Job] = []
    private(set) var capabilities: Capabilities?
    private(set) var selected = Set<String>()
    private(set) var busy = false
    private(set) var refreshing = false
    private(set) var cancelling = Set<String>()
    private(set) var waitingForStop = Set<String>()
    private(set) var uncertain = false
    private(set) var mediaLoading = false
    private(set) var connected = false
    private(set) var latencyMs: Int?
    private(set) var jobsObservationWindow: Int = 0
    var error: APIError?
    var options = Options()
    var address: String { defaults.string(forKey: Pairing.addressKey) ?? "" }
    private(set) var activeProfile: ConnectionProfile = .home
    private(set) var savedAddresses: [ConnectionProfile: String] = [:]
    var errorTitle: String? {
        if activeProfile == .tailscale, !isDemo, let error {
            switch error {
            case .offline, .transport, .localNetwork:
                return "Tailscale-forbindelse mistet. Tjek at Tailscale er aktivt på din telefon og PC."
            default: break
            }
        }
        return error?.title
    }
    var hasActive: Bool { jobs.contains { $0.status.active } }
    var blocked: Bool {
        let missing = capabilities?.missingRequired ?? []
        return missing.contains { options.commentary != false || $0.name == "ffmpeg" || $0.name == "ffprobe" }
    }
    var canSubmit: Bool {
        connected && !busy && !refreshing && !uncertain && !blocked && !selected.isEmpty && options.roi.valid
    }

    init(api: (any SweatAPI)? = nil, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.api = api ?? demo
        if api == nil { isDemo = false }
        for profile in ConnectionProfile.allCases {
            savedAddresses[profile] = defaults.string(forKey: profile.storageKey)
        }
        if let server = try? Server(address) {
            activeProfile = server.profile
            if savedAddresses[server.profile] == nil {
                savedAddresses[server.profile] = server.address
                defaults.set(server.address, forKey: server.profile.storageKey)
            }
        }
        if api == nil, !address.isEmpty {
            isDemo = false
            do {
                let token = try Pairing.load(address)
                self.api = try LiveAPI(server: Server(address), token: token)
                pendingKey = "pending." + address
                uncertain = defaults.object(forKey: "pending." + address) != nil
            } catch { self.error = error as? APIError ?? .storage }
        }
    }

    private func report(_ failure: Error) {
        if !(failure is CancellationError) { error = failure as? APIError ?? .storage }
    }

    private func install(_ api: any SweatAPI, demo: Bool) {
        self.api = api
        isDemo = demo
        revision += 1
        clips = []; jobs = []; selected = []; capabilities = nil; connected = false
        latencyMs = nil
        waitingForStop = []
        pendingKey = demo ? nil : "pending." + address
        uncertain = pendingKey.map { defaults.object(forKey: $0) != nil } ?? false
    }

    func useDemo() async {
        guard !busy, !refreshing, cancelling.isEmpty, !mediaLoading else { return }
        install(demo, demo: true)
        await refresh()
    }

    func saveProfile(_ profile: ConnectionProfile, address: String, token: String) async {
        await connect(address: address, token: token, profile: profile, activateBeforeTest: false)
        await tryAlternateProfile(after: profile)
    }

    func selectProfile(_ profile: ConnectionProfile) async {
        guard let address = savedAddresses[profile] else { return }
        await connect(address: address, token: "", profile: profile, activateBeforeTest: true)
        await tryAlternateProfile(after: profile)
    }

    private func connect(address: String, token input: String, profile: ConnectionProfile, activateBeforeTest: Bool) async {
        guard !busy, !refreshing, cancelling.isEmpty, !mediaLoading else { return }
        busy = true
        defer { busy = false }
        error = nil
        do {
            let server = try Server(address)
            if profile != server.profile {
                error = .address
                return
            }
            let token: String
            if input.isEmpty {
                token = try Pairing.load(server.address)
            } else { token = input.trimmingCharacters(in: .whitespacesAndNewlines) }
            let live = try LiveAPI(server: server, token: token)
            if activateBeforeTest { activate(live) }
            let result = try await initial(live)
            try Pairing.save(token, for: server.address)
            savedAddresses[server.profile] = server.address
            defaults.set(server.address, forKey: server.profile.storageKey)
            if !activateBeforeTest { activate(live) }
            apply(result)
        } catch { report(error) }
    }

    private func activate(_ live: LiveAPI) {
        defaults.set(live.server.address, forKey: Pairing.addressKey)
        activeProfile = live.server.profile
        install(live, demo: false)
    }

    private func tryAlternateProfile(after profile: ConnectionProfile) async {
        guard !Task.isCancelled, let error else { return }
        switch error {
        case .offline, .localNetwork, .transport: break
        default: return
        }
        let alternate: ConnectionProfile = profile == .home ? .tailscale : .home
        guard let saved = savedAddresses[alternate] else { return }
        await connect(address: saved, token: "", profile: alternate, activateBeforeTest: false)
    }

    func ping() async -> String {
        guard let live = api as? LiveAPI, !isDemo else { return "Forbind til din PC først." }
        let source = address
        let start = ContinuousClock.now
        do {
            let health = try await live.health()
            guard health.status == "ok", health.api_version == "1", source == address else { return "PC’en er ikke klar." }
            let ms = Self.milliseconds(since: start)
            latencyMs = ms
            return "PC’en svarer · \(ms) ms"
        } catch {
            if source == address { latencyMs = nil }
            return "PC’en svarede ikke inden for tre sekunder."
        }
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Int {
        let duration = start.duration(to: .now).components
        return max(1, Int(duration.seconds * 1_000 + duration.attoseconds / 1_000_000_000_000_000))
    }

    private func initial(_ api: any SweatAPI) async throws -> (Capabilities, [Clip], [Job], Int?) {
        let start = ContinuousClock.now
        let health = try await api.health()
        let latency = api is LiveAPI ? Self.milliseconds(since: start) : nil
        guard health.api_version == "1" else { throw APIError.version }
        guard health.status == "ok" else { throw APIError.unhealthy }
        async let capabilities = api.capabilities()
        async let clips = api.clips()
        async let jobs = api.jobs()
        return try await (capabilities, clips.clips, jobs.jobs, latency)
    }
    private func apply(_ data: (Capabilities, [Clip], [Job], Int?)) {
        capabilities = data.0
        clips = data.1
        selected = Set(clips.filter { selected.contains($0.id) }.prefix(data.0.limit).map(\.id))
        replaceJobs(data.2)
        connected = true
        latencyMs = data.3
    }

    func refresh() async {
        guard isDemo || !(api is MockAPI) else { return }
        guard !busy, !refreshing, cancelling.isEmpty else { return }
        revision += 1
        refreshing = true
        defer { refreshing = false }
        error = nil
        do {
            let result = try await initial(api)
            try Task.checkCancellation()
            apply(result)
        } catch {
            if !Task.isCancelled {
                connected = false
                latencyMs = nil
                report(error)
                if !isDemo {
                    refreshing = false
                    await tryAlternateProfile(after: activeProfile)
                }
            }
        }
    }

    func toggle(_ clip: Clip) {
        guard !busy else { return }
        if selected.remove(clip.id) != nil { return }
        guard selected.count < (capabilities?.limit ?? 0) else { return }
        selected.insert(clip.id)
    }

    func select(_ clips: [Clip]) {
        guard !busy else { return }
        let limit = capabilities?.limit ?? 0
        for clip in clips where selected.count < limit { selected.insert(clip.id) }
    }

    func clearSelection() {
        guard !busy else { return }
        selected.removeAll()
    }

    func includeFolderClips(_ additional: [Clip]) {
        let known = Set(clips.map(\.id))
        clips.append(contentsOf: additional.filter { !known.contains($0.id) })
    }

    func submit(_ mood: Mood) async {
        guard canSubmit, let capabilities, capabilities.moods.contains(mood), cancelling.isEmpty else { return }
        let batch = Batch(clip_ids: clips.filter { selected.contains($0.id) }.map(\.id), mood: mood, options: options)
        await submit(batch, clearSelection: true, limit: capabilities.limit)
    }

    func canRetry(_ job: Job) -> Bool {
        job.status == .failed && connected && !busy && !refreshing && !uncertain && !blocked &&
            cancelling.isEmpty && options.roi.valid && clips.contains(where: { $0.id == job.clip_id }) &&
            capabilities?.moods.contains(job.mood) == true
    }

    func retry(_ job: Job) async {
        guard canRetry(job), let capabilities else { return }
        await submit(Batch(clip_ids: [job.clip_id], mood: job.mood, options: options),
                     clearSelection: false, limit: capabilities.limit)
    }

    private func submit(_ batch: Batch, clearSelection: Bool, limit: Int) async {
        busy = true
        revision += 1
        error = nil
        defer { busy = false }
        do {
            try batch.validate(limit: limit)
            if let pendingKey { defaults.set(true, forKey: pendingKey) }
            let received = try await api.submit(batch).jobs
            guard received.count == batch.clip_ids.count,
                  Set(received.map(\.id)).count == received.count,
                  received.map(\.clip_id) == batch.clip_ids,
                  received.allSatisfy({ $0.mood == batch.mood }) else { throw APIError.malformed }
            merge(received)
            if clearSelection { selected = [] }
            clearPending()
        } catch {
            if (error as? APIError)?.ambiguous ?? true {
                uncertain = true
                // Never repeat POST. Load the authoritative list; user reviews before another submission.
                do { replaceJobs(try await api.jobs().jobs) } catch { report(error) }
            } else { clearPending() }
            report(error)
        }
    }

    func acknowledgeAfterReview() async {
        guard uncertain, !busy, !refreshing, cancelling.isEmpty else { return }
        busy = true
        revision += 1
        defer { busy = false }
        do {
            replaceJobs(try await api.jobs().jobs)
            selected = []
            clearPending()
            error = nil
        } catch { report(error) }
    }

    private func clearPending() {
        if let pendingKey { defaults.removeObject(forKey: pendingKey) }
        uncertain = false
    }

    func poll() async {
        guard hasActive, !busy, !refreshing, cancelling.isEmpty else { return }
        let snapshot = revision
        do {
            let result = try await api.jobs()
            guard snapshot == revision, !busy, !refreshing, cancelling.isEmpty, !Task.isCancelled else { return }
            replaceJobs(result.jobs)
            if !connected {
                connected = true
                error = nil
            }
        } catch {
            if snapshot == revision, !busy, !refreshing, !Task.isCancelled {
                connected = false
                latencyMs = nil
                report(error)
                if !isDemo { await tryAlternateProfile(after: activeProfile) }
            }
        }
    }

    func pollCodeJobs() async -> Bool {
        guard connected, !isDemo, let live = api as? LiveAPI else { return false }
        let server = address
        do {
            let jobs = try await live.codeBatches().jobs
            guard connected, !isDemo, address == server, !Task.isCancelled else { return false }
            let active = jobs.filter { ["queued", "running"].contains($0.status) }.map(\.id)
            let finished = jobs.filter { ["review", "applied", "completed"].contains($0.status) }.map(\.id)
            observeCompletions(kind: "code", active: active, finished: finished, title: "Dit Code Bot-forslag er klar!")
        } catch let APIError.http(status, _) where [401, 403, 404, 405].contains(status) {
            return false
        } catch {
            if Task.isCancelled { return false }
        }
        return true
    }

    func cancel(_ job: Job) async {
        guard !busy, !refreshing, job.status.active, capabilities?.features.cancel == true,
              !waitingForStop.contains(job.id),
              cancelling.insert(job.id).inserted else { return }
        revision += 1
        defer { cancelling.remove(job.id) }
        error = nil
        do {
            let updated = try await api.cancel(job.id)
            guard updated.id == job.id else { throw APIError.malformed }
            merge([updated])
            if updated.status.active { waitingForStop.insert(updated.id) }
        } catch { report(error) }
    }

    func video(_ job: Job) async -> URL? {
        guard job.status == .completed, !mediaLoading else { return nil }
        mediaLoading = true
        defer { mediaLoading = false }
        error = nil
        do { return try await api.video(job) }
        catch { report(error); return nil }
    }

    private func replaceJobs(_ current: [Job]) {
        jobs = current
        waitingForStop.formIntersection(current.filter { $0.status.active }.map(\.id))
        observeVideos()
    }

    private func merge(_ incoming: [Job]) {
        for job in incoming {
            if let index = jobs.firstIndex(where: { $0.id == job.id }) { jobs[index] = job }
            else { jobs.append(job) }
        }
        observeVideos()
    }

    private func observeVideos() {
        jobsObservationWindow = hasActive ? Int(Date.now.timeIntervalSinceReferenceDate / 15) : 0
        observeCompletions(kind: "video", active: jobs.filter { $0.status.active }.map(\.id),
                           finished: jobs.filter { $0.status == .completed }.map(\.id), title: "Din video er klar!")
    }

    private func observeCompletions(kind: String, active: [String], finished: [String], title: String) {
        guard !isDemo, !address.isEmpty else { return }
        let server = address
        let key = "notifications.active.\(kind).\(server)"
        let previous = Set(defaults.stringArray(forKey: key) ?? [])
        defaults.set(active, forKey: key)
        for id in previous.intersection(finished) {
            Task { await JobNotifications.shared.completed(kind: kind, server: server, id: id, title: title) }
        }
    }
}
