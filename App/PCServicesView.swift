import SwiftUI

struct YouTubeChannels: Decodable, Sendable {
    struct Channel: Decodable, Identifiable, Sendable {
        let id: String
        let title: String
        let handle: String
        let videoCount: String?
        let viewCount: String?
        let subscriberCount: String?

        var statistics: [String] {
            [
                videoCount.map { "Videoer · \($0)" },
                viewCount.map { "Visninger · \($0)" },
                subscriberCount.map { "Abonnenter · \($0)" }
            ].compactMap { $0 }
        }

        var lookup: String {
            (["YouTube-kanal · \(title)", handle, "https://www.youtube.com/channel/\(id)"] + statistics)
                .filter { !$0.isEmpty }.joined(separator: "\n")
        }
    }

    let configured: Bool
    let channels: [Channel]
}

struct PCWebSearch: Decodable, Sendable {
    struct Result: Decodable, Identifiable, Sendable {
        let title: String
        let url: String
        let snippet: String
        var id: String { url }
    }

    let results: [Result]
}

struct PCServicesView: View {
    let api: LiveAPI?
    var onUse: ((String) -> Bool)? = nil
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            NavigationLink {
                ComposioLibraryView(api: api, onUse: attach)
            } label: {
                Label("Composio og biblioteker", systemImage: "link")
            }
            if onUse == nil {
                NavigationLink {
                    PCStatusView(api: api, commentaryEnabled: true)
                } label: {
                    Label("PC-status og målinger", systemImage: "gauge.with.dots.needle.50percent")
                }
            }
            NavigationLink {
                PCServiceLookupView(api: api, service: .youtube, onUse: attach)
            } label: {
                Label("YouTube", systemImage: "play.rectangle")
            }
            NavigationLink {
                PCServiceLookupView(api: api, service: .web, onUse: attach)
            } label: {
                Label("Websøgning via SearXNG", systemImage: "magnifyingglass")
            }
        }
        .navigationTitle("Tjenester på PC’en")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if onUse != nil {
                ToolbarItem(placement: .cancellationAction) { Button("Luk") { dismiss() } }
            }
        }
    }

    private var attach: ((String) -> Bool)? {
        guard let onUse else { return nil }
        return { text in
            guard onUse(text) else { return false }
            dismiss()
            return true
        }
    }
}

struct PCServiceLookupView: View {
    enum Service: Equatable { case youtube, web }
    let api: LiveAPI?
    let service: Service
    let onUse: ((String) -> Bool)?
    var useWebSourceTitle: String? = nil
    @State private var query = ""
    @State private var submittedQuery = ""
    @State private var channels: YouTubeChannels?
    @State private var search: PCWebSearch?
    @State private var notice: String?
    @State private var lookup: Task<Void, Never>?
    @State private var busy = false

    var body: some View {
        List {
            if api == nil {
                Text("Forbind først din iPhone med FadedAI på PC’en.").foregroundStyle(.secondary)
            }
            if service == .youtube {
                Button("Hent mine kanaler", systemImage: "arrow.down.circle") { load() }
                    .disabled(api == nil || busy)
                youtubeResults
            } else {
                TextField("Hvad vil du søge efter?", text: $query)
                    .submitLabel(.search)
                    .onSubmit { load() }
                Button("Søg på nettet", systemImage: "magnifyingglass") { load() }
                    .disabled(api == nil || busy || !validQuery)
                webResults
            }
            if busy { ProgressView() }
            if let notice { Text(notice).foregroundStyle(.secondary) }
        }
        .navigationTitle(service == .youtube ? "YouTube" : "Websøgning")
        .privacySensitive()
        .onDisappear {
            lookup?.cancel()
            lookup = nil
        }
    }

    @ViewBuilder private var youtubeResults: some View {
        if let channels {
            if !channels.configured {
                Text("Åbn YouTube-opsætningen på PC’en og godkend læseadgang. Prøv igen her bagefter.")
                    .foregroundStyle(.secondary)
            } else if channels.channels.isEmpty {
                Text("Google-kontoen har ingen YouTube-kanal at vise.").foregroundStyle(.secondary)
            }
            ForEach(channels.channels) { channel in
                Section(channel.title) {
                    if !channel.handle.isEmpty { Text(channel.handle) }
                    ForEach(channel.statistics, id: \.self) { Text($0) }
                    if let onUse {
                        Button("Vedhæft denne kanal", systemImage: "paperclip") { attach(channel.lookup, using: onUse) }
                    }
                }
            }
        }
    }

    @ViewBuilder private var webResults: some View {
        if let search {
            if search.results.isEmpty {
                Text("Ingen resultater for »\(submittedQuery)«.").foregroundStyle(.secondary)
            } else {
                Section("Resultater for »\(submittedQuery)«") {
                    ForEach(search.results) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.title).font(.headline)
                            if !item.snippet.isEmpty { Text(item.snippet).font(.subheadline) }
                            if let destination = URL(string: item.url), ["http", "https"].contains(destination.scheme ?? ""),
                               destination.host != nil, destination.user == nil, destination.password == nil {
                                Link(destination: destination) {
                                    Label("Åbn kilde", systemImage: "arrow.up.right.square")
                                        .font(.subheadline).frame(minHeight: 44)
                                }
                                Text(item.url).font(.caption).foregroundStyle(.secondary)
                                if let onUse, let useWebSourceTitle {
                                    Button(useWebSourceTitle, systemImage: "paperclip") {
                                        let source = ["Webkilde · " + item.title, item.url, String(item.snippet.prefix(350))]
                                        attach(source.joined(separator: "\n"), using: onUse)
                                    }
                                    .buttonStyle(.borderless)
                                    .frame(minHeight: 44)
                                }
                            }
                        }
                    }
                    if let onUse, useWebSourceTitle == nil {
                        Button("Vedhæft til denne opgave", systemImage: "paperclip") {
                            let entries = search.results.map { "\($0.title)\n\($0.url)\n\($0.snippet)" }
                            attach((["Websøgning · \(submittedQuery)"] + entries).joined(separator: "\n\n"), using: onUse)
                        }
                    }
                }
            }
        }
    }

    private var cleanQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var validQuery: Bool { (3...180).contains(cleanQuery.unicodeScalars.count) }

    private func attach(_ text: String, using action: (String) -> Bool) {
        if !action(text) {
            notice = useWebSourceTitle == nil ? "Opslaget kunne ikke vedhæftes. Tjek PC-forbindelsen, og prøv igen."
                : "Kilden kunne ikke sættes i kladden. Prøv med en kortere kladde."
        }
    }

    private func load() {
        let text = cleanQuery
        guard let api, !busy, service == .youtube || validQuery else { return }
        busy = true
        notice = nil
        channels = nil
        search = nil
        lookup = Task {
            defer { busy = false }
            do {
                switch service {
                case .youtube:
                    let result = try await api.youtubeChannels()
                    if !Task.isCancelled { channels = result }
                case .web:
                    let result = try await api.pcWebSearch(query: text)
                    if !Task.isCancelled {
                        submittedQuery = text
                        search = result
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                switch error as? APIError {
                case .http(404, _)?: notice = "Opdatér FadedAI på PC’en for at bruge denne forbindelse."
                case .http(_, let problem)?: notice = problem?.message ?? "PC’en kunne ikke hente opslaget."
                default: notice = "PC’en kunne ikke hente opslaget. Tjek forbindelsen, og prøv igen."
                }
            }
        }
    }
}

struct PCMetrics: Decodable {
    struct GPU: Decodable, Identifiable {
        let id, name: String
        let percent, usedMiB, totalMiB: Int?
        let temperatureC: Int?
    }
    let cpuPercent: Int?
    let cpuTemperatureC: Int?
    let videoJobs, botJobs: Int?
    let memoryUsed, memoryTotal: Int64?
    let diskFree, diskTotal: Int64
    let gpus: [GPU]
}

struct PCLiveMetrics: View {
    let api: LiveAPI
    let refreshCount: Int
    @Environment(\.scenePhase) private var phase
    @State private var metrics: PCMetrics?
    @State private var notice: String?

    var body: some View {
        VStack(alignment: .leading, spacing: FadedSpacing.s) {
            FadedSectionHeader("PC’en lige nu", detail: "Målingerne opdateres, mens siden er åben.")
            if let metrics {
                processor(metrics)
                ForEach(metrics.gpus, content: graphics)
                if metrics.gpus.isEmpty {
                    FadedDetailText("Intet NVIDIA-grafikkort kunne aflæses.")
                }
                system(metrics)
            } else if let notice {
                FadedDetailText(notice)
            } else {
                LoadingSkeleton(label: "Henter CPU- og GPU-målinger…")
            }
        }
        .task(id: "\(api.queueTargetID):\(phase == .active):\(refreshCount)") {
            metrics = nil
            notice = nil
            guard phase == .active else { return }
            while !Task.isCancelled {
                await refresh()
                do { try await Task.sleep(for: .seconds(5)) }
                catch { break }
            }
        }
    }

    private func processor(_ sample: PCMetrics) -> some View {
        FadedCard(size: .compact) {
            VStack(alignment: .leading, spacing: FadedSpacing.s) {
                Label("CPU", systemImage: "cpu").font(FadedTypography.action)
                LabeledContent("Brug", value: usage(sample.cpuPercent))
                LabeledContent("Temperatur", value: temperature(sample.cpuTemperatureC))
                if sample.cpuTemperatureC == nil {
                    FadedDetailText("Åbn LibreHardwareMonitor på PC’en for at læse CPU-sensoren.")
                }
            }
        }
    }

    private func graphics(_ gpu: PCMetrics.GPU) -> some View {
        FadedCard(size: .compact) {
            VStack(alignment: .leading, spacing: FadedSpacing.s) {
                Label(gpu.name, systemImage: "display").font(FadedTypography.action)
                LabeledContent("GPU-brug", value: usage(gpu.percent))
                LabeledContent("Temperatur", value: temperature(gpu.temperatureC))
                if let used = gpu.usedMiB, let total = gpu.totalMiB {
                    LabeledContent("Grafikhukommelse", value: "\(used) / \(total) MiB")
                }
            }
        }
    }

    private func system(_ sample: PCMetrics) -> some View {
        FadedCard(size: .compact) {
            DisclosureGroup("Hukommelse, disk og kø") {
                VStack(alignment: .leading, spacing: FadedSpacing.s) {
                    if let used = sample.memoryUsed, let total = sample.memoryTotal {
                        LabeledContent("Hukommelse", value: "\(size(used)) / \(size(total))")
                    }
                    LabeledContent("Ledig arbejdsdisk", value: "\(size(sample.diskFree)) / \(size(sample.diskTotal))")
                    if let jobs = sample.videoJobs { LabeledContent("Videojobs", value: String(jobs)) }
                    if let jobs = sample.botJobs { LabeledContent("Agentopgaver", value: String(jobs)) }
                }
                .padding(.top, FadedSpacing.s)
            }
        }
    }

    private func usage(_ value: Int?) -> String {
        value.map { "\($0) %" } ?? "Ingen aflæsning"
    }

    private func temperature(_ value: Int?) -> String {
        value.map { "\($0) °C" } ?? "Ingen aflæsning"
    }

    private func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    @MainActor private func refresh() async {
        do {
            let sample = try await api.pcMetrics()
            guard !Task.isCancelled else { return }
            metrics = sample
            notice = nil
        } catch let APIError.http(status, _) where status == 404 {
            guard !Task.isCancelled else { return }
            metrics = nil
            notice = "Opdatér FadedAI på PC’en for at se målingerne."
        } catch {
            guard !Task.isCancelled else { return }
            metrics = nil
            notice = "Kunne ikke læse PC’en. Tjek forbindelsen og PC-opdateringen."
        }
    }
}

struct ComposioProviders: Decodable {
    struct Provider: Decodable, Identifiable {
        let id, title: String
        let configured, connected: Bool
    }
    let providers: [Provider]
}

struct ComposioLink: Decodable { let url: URL }
struct ComposioContext: Decodable { let text: String }
struct ComposioItems: Decodable {
    struct Item: Decodable, Identifiable { let id, title: String }
    let items: [Item]
}

@MainActor private struct ComposioLibraryView: View {
    let api: LiveAPI?
    let onUse: ((String) -> Bool)?
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var phase
    @State private var providers: [ComposioProviders.Provider] = []
    @State private var notice: String?
    @State private var starting: String?

    var body: some View {
        List {
            ForEach(providers) { provider in
                Section(provider.title) {
                    if provider.connected {
                        NavigationLink("Åbn bibliotek") {
                            ComposioItemsView(api: api, provider: provider, onUse: onUse)
                        }
                    } else if provider.configured {
                        Button("Log ind", systemImage: "person.badge.key") { start(provider) }
                            .disabled(starting != nil)
                    } else {
                        Text("Opsæt Composio på PC’en først.").foregroundStyle(.secondary)
                    }
                }
            }
            if let notice { Text(notice).foregroundStyle(.secondary) }
            if api != nil && providers.isEmpty && notice == nil { ProgressView("Tjekker forbindelser…") }
            if api != nil { Button("Opdatér forbindelser", systemImage: "arrow.clockwise") { Task { await reload() } } }
        }
        .navigationTitle("Composio")
        .task(id: "\(api?.queueTargetID ?? ""):\(phase == .active)") {
            if phase == .active { await reload() }
        }
        .privacySensitive()
    }

    private func reload() async {
        guard let api else {
            providers = []
            notice = "Forbind først din iPhone med FadedAI på PC’en."
            return
        }
        do {
            let data = try await api.composioProviders()
            guard !Task.isCancelled else { return }
            providers = data.providers
            notice = nil
        } catch {
            guard !Task.isCancelled else { return }
            providers = []
            notice = "Kunne ikke læse forbindelserne. Tjek opsætningen på PC’en."
        }
    }

    private func start(_ provider: ComposioProviders.Provider) {
        guard let api, starting == nil else { return }
        starting = provider.id
        Task {
            defer { starting = nil }
            do {
                let link = try await api.composioLink(provider.id)
                guard link.url.scheme == "https", link.url.user == nil, link.url.password == nil,
                      let host = link.url.host,
                      host == "composio.dev" || host.hasSuffix(".composio.dev") ||
                      host == "composio.com" || host.hasSuffix(".composio.com") else {
                    throw APIError.malformed
                }
                openURL(link.url)
                notice = "Gå tilbage hertil og opdatér, når du har logget ind."
            } catch {
                notice = "Kunne ikke åbne login. Tjek Composio på PC’en."
            }
        }
    }
}

@MainActor private struct ComposioItemsView: View {
    let api: LiveAPI?
    let provider: ComposioProviders.Provider
    let onUse: ((String) -> Bool)?
    @State private var items: [ComposioItems.Item] = []
    @State private var selected: ComposioItems.Item?
    @State private var context: String?
    @State private var notice: String?
    @State private var busy = false

    var body: some View {
        List {
            ForEach(items) { item in
                Button(item.title) {
                    context = nil
                    selected = item
                }
            }
            if let notice { Text(notice).foregroundStyle(.secondary) }
            if busy { ProgressView() }
            if items.isEmpty && !busy && notice == nil {
                ContentUnavailableView("Ingen opslag", systemImage: "folder")
            }
        }
        .navigationTitle(provider.title)
        .task { await load() }
        .refreshable { await load() }
        .sheet(item: $selected) { item in
            NavigationStack {
                List {
                    if let context {
                        Text(context).textSelection(.enabled)
                        if let onUse {
                            Button("Tillad til denne opgave", systemImage: "paperclip") {
                                if onUse(context) { selected = nil }
                            }
                            Text("Kun den valgte tekst deles. Opgaven skal begynde inden for 30 minutter.")
                                .foregroundStyle(.secondary)
                        }
                    } else if let notice {
                        Text(notice).foregroundStyle(.secondary)
                    } else {
                        ProgressView("Læser opslaget…")
                    }
                }
                .navigationTitle(item.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Luk") { selected = nil } }
                }
                .task(id: item.id) { await read(item) }
            }
        }
        .privacySensitive()
    }

    private func load() async {
        guard let api else { return }
        busy = true
        defer { busy = false }
        do {
            let response = try await api.composioItems(provider.id)
            guard !Task.isCancelled else { return }
            items = response.items
            notice = nil
        } catch {
            guard !Task.isCancelled else { return }
            notice = "Kunne ikke åbne biblioteket. Tjek tjenestens tilladelser."
        }
    }

    private func read(_ item: ComposioItems.Item) async {
        guard let api else { return }
        notice = nil
        do {
            let response = try await api.composioContext(provider.id, item: item.id)
            guard !Task.isCancelled else { return }
            context = response.text
        } catch {
            guard !Task.isCancelled else { return }
            notice = "Det valgte opslag kunne ikke læses."
        }
    }
}
