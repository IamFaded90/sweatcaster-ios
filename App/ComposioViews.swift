import Foundation
import SwiftUI
import UIKit

struct ComposioProviders: Decodable {
    struct Provider: Decodable, Identifiable {
        let id, title: String
        let configured, connected: Bool
        let availability: String?

        var status: String {
            if connected { return availability == nil ? "Forbindelse registreret" : "Klar i FadedAI" }
            switch availability {
            case "composio": return "Forbundet i Composio"
            case "error": return "Læsning fejlede"
            case "unknown": return "Status ukendt"
            default: return "Ikke forbundet"
            }
        }

        var icon: String {
            switch id {
            case "gmail": "envelope"
            case "googlecalendar": "calendar"
            case "googlesheets": "tablecells"
            case "notion": "note.text"
            case "github": "chevron.left.forwardslash.chevron.right"
            case "googlephotos": "photo.on.rectangle"
            case "google_maps": "map"
            case "veo", "youtube", "twitch": "play.rectangle"
            case "discord", "facebook": "bubble.left.and.bubble.right"
            case "deepseek", "grok": "sparkles"
            default: "folder"
            }
        }

        var subtitle: String {
            switch id {
            case "gmail": "Indbakke, søgning og kladder"
            case "googlecalendar": "Dine kalendere"
            case "googledrive", "one_drive", "dropbox": "Filer og mapper"
            case "googlesheets": "Regneark"
            case "notion": "Sider og noter"
            case "github": "Projekter og opgaver"
            case "googlephotos": "Billeder valgt fra Google Fotos"
            case "google_maps": "Steder og ruter"
            case "youtube": "Dine YouTube-kanaler"
            case "twitch": "Kanaler og livestreams"
            case "discord": "Servere og kanaler"
            case "facebook": "Sider og opslag"
            case "veo": "Videogenerering"
            case "deepseek", "grok": "AI-modeller"
            default: ""
            }
        }

        var openTitle: String {
            switch id {
            case "gmail": "Åbn indbakken"
            case "googlecalendar": "Vis kalendere"
            case "youtube": "Vis mine kanaler"
            default: "Åbn bibliotek"
            }
        }

        var showsItemDetails: Bool { id != "googlecalendar" && id != "youtube" }
    }
    let providers: [Provider]
}

struct ComposioLogo: View {
    let slug: String
    var size: CGFloat = 44
    var fallback = "link"

    var body: some View {
        Group {
            if let logo = UIImage(named: "Composio-" + slug) {
                Image(uiImage: logo).resizable().scaledToFit()
            } else {
                Image(systemName: fallback).font(.system(size: size * 0.45)).foregroundStyle(.black)
            }
        }
            .padding(size * 0.17)
            .frame(width: size, height: size)
            .background(.white, in: RoundedRectangle(cornerRadius: size * 0.26))
            .accessibilityHidden(true)
    }
}

struct ComposioLink: Decodable { let url: URL }
struct ComposioContext: Decodable { let text: String }
struct ComposioItems: Decodable {
    struct Item: Decodable, Identifiable { let id, title: String }
    let items: [Item]
}

@MainActor struct ComposioLibraryView: View {
    let api: LiveAPI?
    let onUse: ((String) -> Bool)?
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var phase
    @State private var providers: [ComposioProviders.Provider] = []
    @State private var notice: String?
    @State private var starting: String?
    @State private var loading = false
    @State private var query = ""
    @State private var displayedTarget: String?
    @State private var reloadID: UUID?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: FadedSpacing.m) {
                ComposioCloudSetup(api: api)
                NvidiaCloudSetup(api: api)
                OpenRouterCloudSetup(api: api)
                FadedCard(accent: FadedBrand.pc) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Dine forbindelser").font(.title2.bold())
                        if !providers.isEmpty {
                            let ready = providers.filter(\.connected).count
                            let dashboardOnly = providers.filter { $0.availability == "composio" }.count
                            FadedDetailText("\(ready) klar i FadedAI · \(dashboardOnly) kun i Composio")
                        }
                        if loading { ProgressView("Tjekker forbindelser…") }
                        if let notice { FadedDetailText(notice) }
                        if api != nil {
                            FadedSecondaryButton("Tjek forbindelser igen", icon: "arrow.clockwise") {
                                Task { await reload(force: true) }
                            }.disabled(loading)
                        }
                    }
                }
                let visible = providers.filter {
                    query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || $0.title.localizedStandardContains(query)
                }
                ForEach(visible.sorted { $0.connected && !$1.connected }) { provider in
                    integrationCard(provider)
                }
                if !providers.isEmpty && visible.isEmpty {
                    FadedEmptyState(icon: "magnifyingglass", title: "Ingen forbindelser fundet",
                                    detail: "Prøv at søge på tjenestens navn.")
                }
            }
            .padding(FadedSpacing.edge)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .background { FadedBackground() }
        .navigationTitle("Composio")
        .searchable(text: $query, prompt: "Find en forbindelse")
        .refreshable { await reload(force: true) }
        .task(id: "\(api?.queueTargetID ?? ""):\(phase == .active)") {
            if phase == .active { await reload() }
        }
        .privacySensitive()
    }

    private func integrationCard(_ provider: ComposioProviders.Provider) -> some View {
        FadedCard(accent: provider.connected ? FadedBrand.pc : nil) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    ComposioLogo(slug: provider.id, fallback: provider.icon)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(provider.title).font(.headline)
                        FadedDetailText(provider.subtitle)
                        Label(provider.status, systemImage: provider.connected ? "checkmark.circle.fill" : "info.circle")
                            .font(.caption)
                            .foregroundStyle(provider.connected ? FadedBrand.pc : Color.secondary)
                    }
                }
                if provider.connected {
                    NavigationLink {
                        if provider.id == "gmail", let api { GmailReadView(api: api, onUse: onUse) }
                        else { ComposioItemsView(api: api, provider: provider, onUse: onUse) }
                    } label: {
                        Label(provider.openTitle, systemImage: "chevron.right")
                            .font(.subheadline.weight(.semibold)).frame(minHeight: 44)
                    }
                } else if provider.configured && (provider.availability == nil || provider.availability == "disconnected") {
                    FadedSecondaryButton("Forbind", icon: "person.badge.key") { start(provider) }.disabled(starting != nil)
                }
            }
        }
    }

    private func reload(force: Bool = false) async {
        let id = UUID()
        reloadID = id
        if displayedTarget != api?.queueTargetID {
            displayedTarget = api?.queueTargetID
            providers = []
        }
        guard let api else {
            providers = []
            loading = false
            notice = "Forbind først din iPhone med FadedAI på PC’en."
            return
        }
        loading = true
        defer { if reloadID == id { loading = false } }
        do {
            let data = try await api.composioProviders(refresh: force)
            guard !Task.isCancelled, reloadID == id else { return }
            providers = data.providers
            notice = nil
        } catch {
            guard !Task.isCancelled, reloadID == id else { return }
            notice = composioErrorText(error)
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
    @State private var itemNotice: String?
    @State private var busy = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: FadedSpacing.s) {
                FadedCard(accent: FadedBrand.pc) {
                    HStack(spacing: 12) {
                        ComposioLogo(slug: provider.id, size: 48, fallback: provider.icon)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(provider.subtitle).font(.headline)
                            FadedDetailText(provider.id == "googlesheets"
                                ? "Forhåndsvisning af første fane, A1–J25." : provider.status)
                        }
                    }
                }
                ForEach(items) { item in
                    if provider.showsItemDetails {
                        Button {
                            context = nil
                            itemNotice = nil
                            selected = item
                        } label: { itemRow(item) }.buttonStyle(.plain)
                    } else {
                        itemRow(item)
                    }
                }
                if let notice {
                    FadedEmptyState(icon: provider.icon, title: "Biblioteket kunne ikke åbnes", detail: notice,
                                    actionTitle: "Prøv igen", action: { Task { await load() } })
                }
                if busy { ProgressView("Læser \(provider.title)…").padding(12) }
                if items.isEmpty && !busy && notice == nil {
                    FadedEmptyState(icon: provider.icon, title: "Intet at vise", detail: "Der blev ikke fundet noget, FadedAI kan vise her.")
                }
            }
            .padding(FadedSpacing.edge).frame(maxWidth: 640).frame(maxWidth: .infinity)
        }
        .background { FadedBackground() }
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
                    } else if let itemNotice {
                        Text(itemNotice).foregroundStyle(.secondary)
                        Button("Prøv igen", systemImage: "arrow.clockwise") { Task { await read(item) } }
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

    private func itemRow(_ item: ComposioItems.Item) -> some View {
        FadedCard {
            HStack(spacing: 12) {
                Image(systemName: provider.icon).foregroundStyle(FadedBrand.pc)
                Text(item.title).multilineTextAlignment(.leading).font(.subheadline.weight(.semibold))
                Spacer(minLength: 0)
                if provider.showsItemDetails { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary) }
            }
            .frame(minHeight: 44)
        }
    }

    private func load() async {
        guard let api, !busy else { return }
        busy = true
        notice = nil
        defer { busy = false }
        do {
            let response = try await api.composioItems(provider.id)
            guard !Task.isCancelled else { return }
            items = response.items
            notice = nil
        } catch {
            guard !Task.isCancelled else { return }
            notice = composioErrorText(error)
        }
    }

    private func read(_ item: ComposioItems.Item) async {
        guard let api else { return }
        itemNotice = nil
        do {
            let response = try await api.composioContext(provider.id, item: item.id)
            guard !Task.isCancelled, selected?.id == item.id else { return }
            context = response.text
        } catch {
            guard !Task.isCancelled, selected?.id == item.id else { return }
            itemNotice = composioErrorText(error)
        }
    }
}

private func composioErrorText(_ error: Error) -> String {
    if case APIError.http(_, let problem) = error, let message = problem?.message { return message }
    return AppErrorPresentation(error).title
}
