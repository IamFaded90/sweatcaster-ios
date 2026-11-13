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

private struct PCServiceLookupView: View {
    enum Service: Equatable { case youtube, web }
    let api: LiveAPI?
    let service: Service
    let onUse: ((String) -> Bool)?
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
                            Text(item.url).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let onUse {
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
        if !action(text) { notice = "Opslaget kunne ikke vedhæftes. Tjek PC-forbindelsen, og prøv igen." }
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
