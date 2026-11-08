// Owns the current connection, pairing state, and shared model state.
import Foundation
import Observation

@MainActor @Observable final class Model {
    private(set) var api: any SweatAPI
    private let demo = MockAPI()
    let defaults: UserDefaults
    let videoStateDirectory: URL
    // Shared state for the video and outbox extensions.
    var videoStudio = VideoStudioState()
    var clipFolderIDs: [String: String] = [:]
    var videoStateReadable = true
    var pendingKey: String?
    var revision = 0
    private(set) var isDemo = false
    private(set) var needsPairing = true
    var clips: [Clip] = []
    var jobs: [Job] = []
    var observedCodeJobs: [CodeBatchList.Job] = []
    var codeJobsObservationWindow = 0
    private(set) var capabilities: Capabilities?
    var selected = Set<String>()
    var busy = false
    private(set) var refreshing = false
    var cancelling = Set<String>()
    var waitingForStop = Set<String>()
    var uncertain = false
    var cancelledVideoAttempt = false
    var requiresVideoReview: Bool { uncertain || cancelledVideoAttempt }
    var mediaLoading = false
    var connected = false
    var latencyMs: Int?
    var jobsObservationWindow: Int = 0
    var videoStorageNotice: String?
    var videoOutboxNotice: String?
    var checkingVideoOutbox = false
    var error: APIError?
    var options = Options()
    var address: String { defaults.string(forKey: Pairing.addressKey) ?? "" }
    private(set) var activeProfile: ConnectionProfile = .home
    private(set) var savedAddresses: [ConnectionProfile: String] = [:]
    var errorTitle: String? { errorPresentation?.title }

    var errorPresentation: AppErrorPresentation? {
        guard let error else { return nil }
        if activeProfile == .tailscale, !isDemo {
            switch error {
            case .offline, .transport, .localNetwork:
                return AppErrorPresentation(error, title: "Tailscale-forbindelse mistet. Tjek at Tailscale er aktivt på din telefon og PC.")
            default: break
            }
        }
        return AppErrorPresentation(error)
    }
    init(api: (any SweatAPI)? = nil, defaults: UserDefaults = .standard,
         videoStateDirectory: URL = URL.applicationSupportDirectory.appending(path: "VideoStudio", directoryHint: .isDirectory)) {
        self.defaults = defaults
        self.videoStateDirectory = videoStateDirectory
        self.api = api ?? UnpairedAPI()
        if defaults === UserDefaults.standard { MigratedAppData.shared.migrateUserDefaultsToFilesIfNeeded() }
        needsPairing = api == nil
        isDemo = api.map { !($0 is LiveAPI) } ?? false
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
                needsPairing = false
                pendingKey = AppStorageKeys.pendingVideo(address)
                uncertain = defaults.object(forKey: AppStorageKeys.pendingVideo(address)) != nil
            } catch { AppDiagnostics.record(error); self.error = error as? APIError ?? .storage }
        }
        if !isDemo, !address.isEmpty { restoreVideoStudio() }
    }

    func report(_ failure: Error) {
        if !(failure is CancellationError) { error = failure as? APIError ?? .storage }
    }

    private func install(_ api: any SweatAPI, demo: Bool) {
        self.api = api
        isDemo = demo
        needsPairing = false
        revision += 1
        clips = []; jobs = []; selected = []; capabilities = nil; connected = false
        observedCodeJobs = []
        codeJobsObservationWindow = 0
        latencyMs = nil
        waitingForStop = []
        pendingKey = demo ? nil : AppStorageKeys.pendingVideo(address)
        uncertain = pendingKey.map { defaults.object(forKey: $0) != nil } ?? false
        cancelledVideoAttempt = false
        restoreVideoStudio()
    }

    func useDemo() async {
        guard !busy, !refreshing, !checkingVideoOutbox, cancelling.isEmpty, !mediaLoading else { return }
        install(demo, demo: true)
        await refresh()
    }

    func saveProfile(_ profile: ConnectionProfile, address: String, token: String,
                     pairingExpiresAt: Date? = nil) async {
        await connect(address: address, token: token, profile: profile, activateBeforeTest: false,
                      pairingExpiresAt: pairingExpiresAt)
        await tryAlternateProfile(after: profile)
    }

    func selectProfile(_ profile: ConnectionProfile) async {
        guard let address = savedAddresses[profile] else { return }
        await connect(address: address, token: "", profile: profile, activateBeforeTest: true)
        await tryAlternateProfile(after: profile)
    }

    private func connect(address: String, token input: String, profile: ConnectionProfile,
                         activateBeforeTest: Bool, pairingExpiresAt: Date? = nil) async {
        guard !busy, !refreshing, !checkingVideoOutbox, cancelling.isEmpty, !mediaLoading else { return }
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
            let result = try await initial(live, pairingExpiresAt: pairingExpiresAt)
            try Pairing.save(token, for: server.address)
            savedAddresses[server.profile] = server.address
            defaults.set(server.address, forKey: server.profile.storageKey)
            if !activateBeforeTest { activate(live) }
            apply(result)
        } catch { AppDiagnostics.record(error); report(error) }
    }

    private func activate(_ live: LiveAPI) {
        defaults.set(live.server.address, forKey: Pairing.addressKey)
        activeProfile = live.server.profile
        install(live, demo: false)
    }

    func tryAlternateProfile(after profile: ConnectionProfile) async {
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
            AppDiagnostics.record(error)
            if source == address { latencyMs = nil }
            return "PC’en svarede ikke inden for tre sekunder."
        }
    }

    static func probe(_ server: Server) async throws -> Int {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 3
        configuration.timeoutIntervalForResource = 3
        configuration.allowsCellularAccess = server.profile == .tailscale
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let start = ContinuousClock.now
        let (bytes, response) = try await session.bytes(from: server.endpoint("health"))
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw APIError.unhealthy }
        var payload = Data()
        for try await byte in bytes {
            guard payload.count < 1_024 else { throw APIError.unhealthy }
            payload.append(byte)
        }
        guard let health = try? JSONDecoder().decode(Health.self, from: payload),
              health.status == "ok" else { throw APIError.unhealthy }
        guard health.api_version == "1" else { throw APIError.version }
        return milliseconds(since: start)
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Int {
        let duration = start.duration(to: .now).components
        return max(1, Int(duration.seconds * 1_000 + duration.attoseconds / 1_000_000_000_000_000))
    }

    private func initial(_ api: any SweatAPI, pairingExpiresAt: Date? = nil) async throws -> (Capabilities, [Clip]?, [Job], Int?) {
        let start = ContinuousClock.now
        let health = try await api.health()
        let latency = api is LiveAPI ? Self.milliseconds(since: start) : nil
        guard health.api_version == "1" else { throw APIError.version }
        guard health.status == "ok" else { throw APIError.unhealthy }
        if let pairingExpiresAt {
            try Task.checkCancellation()
            guard pairingExpiresAt > .now else { throw APIError.pairingExpired }
        }
        async let capabilities = api.capabilities()
        async let jobs = api.jobs()
        // A live server's V1 list can probe hundreds of clips and omits later folders.
        // Only load a live clip list when the user opens a source in Video Studio.
        let initialClips: [Clip]? = if api is LiveAPI { nil } else { try await api.clips().clips }
        return try await (capabilities, initialClips, jobs.jobs, latency)
    }
    private func apply(_ data: (Capabilities, [Clip]?, [Job], Int?)) {
        capabilities = data.0
        if let refreshedClips = data.1 {
            clips = refreshedClips
            selected.formIntersection(clips.map(\.id))
        }
        replaceJobs(data.2)
        connected = true
        latencyMs = data.3
    }

    func refresh() async {
        guard !needsPairing else { return }
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
            AppDiagnostics.record(error)
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
}

private struct UnpairedAPI: SweatAPI {
    func health() async throws -> Health { throw APIError.token }
    func capabilities() async throws -> Capabilities { throw APIError.token }
    func clips() async throws -> Clips { throw APIError.token }
    func jobs() async throws -> Jobs { throw APIError.token }
    func job(_ id: String) async throws -> Job { throw APIError.token }
    func submit(_ batch: Batch) async throws -> Jobs { throw APIError.token }
    func cancel(_ id: String) async throws -> Job { throw APIError.token }
    func video(_ job: Job) async throws -> URL { throw APIError.token }
}
