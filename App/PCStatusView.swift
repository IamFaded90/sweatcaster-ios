// Read-only diagnostics for features of the currently paired PC.

import Foundation
import SwiftUI

struct PCStatusView: View {
    let api: LiveAPI?
    let commentaryEnabled: Bool
    @Environment(\.fadedPalette) private var palette
    @State private var refreshCount = 0
    @State private var snapshot: Snapshot?

    private struct Request: Equatable {
        let targetID: String?
        let commentaryEnabled: Bool
        let refreshCount: Int
    }

    private struct Snapshot {
        let request: Request
        let checkedAt: Date
        let rows: [PCFeatureCheck.Row]
    }

    private var request: Request {
        .init(targetID: api?.queueTargetID, commentaryEnabled: commentaryEnabled, refreshCount: refreshCount)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FadedSpacing.section) {
                FadedSignature()
                FadedSectionHeader("PC-status", detail: "Et øjebliksbillede fra din parrede PC. Statusmålingen starter ingen job.")
                if api == nil {
                    FadedEmptyState(icon: "desktopcomputer", title: "Ingen parret PC",
                                    detail: "Forbind til din PC under Indstillinger → Forbindelse. Demo har ingen PC-status.")
                } else if let snapshot, snapshot.request == request {
                    ForEach(snapshot.rows) { row in featureRow(row) }
                    Text("Tjekket \(snapshot.checkedAt.formatted(date: .omitted, time: .shortened))")
                        .font(.caption).foregroundStyle(palette.secondary)
                } else {
                    LoadingSkeleton(label: "Tjekker funktionerne på PC’en…")
                }
            }
            .padding(FadedSpacing.edge)
            .frame(maxWidth: 640).frame(maxWidth: .infinity)
        }
        .background { FadedBackground() }
        .foregroundStyle(palette.text)
        .navigationTitle("PC-status")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button("Opdatér status", systemImage: "arrow.clockwise") { refreshCount += 1 }
                .disabled(api == nil || snapshot?.request != request)
        }
        .task(id: request) { await refresh() }
    }

    private func featureRow(_ row: PCFeatureCheck.Row) -> some View {
        FadedCard(size: .compact, accent: row.tone.color(in: palette)) {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: FadedSpacing.s) {
                    FadedDetailText(row.detail)
                    if let next = row.next { FadedDetailText(next) }
                }.padding(.top, FadedSpacing.s)
            } label: {
                VStack(alignment: .leading, spacing: FadedSpacing.xs) {
                    Label(row.feature.title, systemImage: row.feature.icon).font(FadedTypography.action)
                    FadedBadge(row.status, tone: row.tone)
                }.frame(minHeight: 44, alignment: .leading)
            }
        }
    }

    @MainActor private func refresh() async {
        let requested = request
        guard let api, api.queueTargetID == requested.targetID else { return }
        let rows = await PCFeatureCheck.measure(api: api, commentaryEnabled: requested.commentaryEnabled)
        guard !Task.isCancelled, requested == request else { return }
        snapshot = .init(request: requested, checkedAt: .now, rows: rows)
    }
}

private enum PCFeatureCheck {
    enum Feature: String, CaseIterable, Hashable, Sendable {
        case chat, video, code, hub, memory

        var title: String {
            switch self {
            case .chat: "Chat"
            case .video: "Video"
            case .code: "Code Bot"
            case .hub: "Agent-Hub"
            case .memory: "Hukommelse"
            }
        }

        var icon: String {
            switch self {
            case .chat: "bubble.left"
            case .video: "film"
            case .code: "chevron.left.forwardslash.chevron.right"
            case .hub: "person.2"
            case .memory: "brain"
            }
        }
    }

    struct Row: Identifiable {
        let feature: Feature
        let status: String
        let tone: FadedStatusTone
        let detail: String
        let next: String?
        var id: Feature { feature }

        init(_ feature: Feature, _ status: String, _ tone: FadedStatusTone, _ detail: String, next: String? = nil) {
            self.feature = feature
            self.status = status
            self.tone = tone
            self.detail = detail
            self.next = next
        }
    }

    private enum Issue: Sendable {
        case unpaired, unreachable, unsupported, busy, unknown

        init(_ error: Error) {
            if let failure = error as? APIError {
                switch failure {
                case .token, .http(401, _), .http(403, _): self = .unpaired
                case .http(404, _), .http(405, _), .http(501, _): self = .unsupported
                case .http(503, _): self = .busy
                case .offline, .localNetwork: self = .unreachable
                case .transport(let code): self = Self.networkIssue(code)
                default: self = .unknown
                }
            } else if case .http(let status, _, _)? = error as? V2Failure {
                switch status {
                case 401, 403: self = .unpaired
                case 404, 405, 501: self = .unsupported
                case 503: self = .busy
                default: self = .unknown
                }
            } else if let failure = error as? URLError {
                self = Self.networkIssue(failure.errorCode)
            } else {
                self = .unknown
            }
        }

        private static func networkIssue(_ code: Int) -> Self {
            let unreachable: [URLError.Code] = [.cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
                                                .notConnectedToInternet, .networkConnectionLost, .timedOut]
            return unreachable.contains(where: { $0.rawValue == code }) ? .unreachable : .unknown
        }

        func row(_ feature: Feature) -> Row {
            switch self {
            case .unpaired:
                .init(feature, "Adgang afvist", .error, "PC’en afviste forespørgslen.",
                      next: "Tjek IP og token i Indstillinger → Forbindelse.")
            case .unreachable:
                .init(feature, "Intet svar", .warning, "PC’en svarede ikke på statusmålingen.",
                      next: "Tjek PC, Wi-Fi eller Tailscale, og opdatér status.")
            case .unsupported:
                .init(feature, "Ikke tilgængelig", .info, "Denne statusrute er utilgængelig på den parrede PC.",
                      next: "Tjek PC’ens version og moduler.")
            case .busy:
                .init(feature, "Optaget", .warning, "PC’en beder appen prøve igen senere.",
                      next: "Opdatér status, når PC’en er klar.")
            case .unknown:
                .init(feature, "Ukendt", .info, "Svaret var ikke nok til at bekræfte status.",
                      next: "Opdatér status, eller se fejlloggen under Fejlfinding.")
            }
        }
    }

    private enum Probe<Value: Sendable>: Sendable {
        case answer(Value)
        case failed(Issue)

        var value: Value? {
            if case .answer(let value) = self { return value }
            return nil
        }

        var issue: Issue? {
            if case .failed(let issue) = self { return issue }
            return nil
        }
    }

    private static func read<Value: Sendable>(_ fetch: @Sendable () async throws -> Value) async -> Probe<Value> {
        do {
            try Task.checkCancellation()
            return .answer(try await fetch())
        } catch {
            return .failed(Issue(error))
        }
    }

    static func measure(api: LiveAPI, commentaryEnabled: Bool) async -> [Row] {
        let capabilities = await read { try await api.capabilities() }
        if let issue = capabilities.issue {
            switch issue {
            case .unpaired, .unreachable, .busy:
                return Feature.allCases.map { issue.row($0) }
            case .unsupported, .unknown:
                break
            }
        }

        async let videoJobs = read { try await api.jobs() }
        async let catalog = read { try await api.v2Models() }
        async let code = codeRow(api)
        async let agents = agentRows(api)
        let (jobs, models, codeStatus, agentStatus) = await (videoJobs, catalog, code, agents)
        return [chatRow(models, jobs: jobs, capabilities: capabilities.value),
                videoRow(jobs, capabilities: capabilities, commentaryEnabled: commentaryEnabled), codeStatus] + agentStatus
    }

    private static func chatRow(_ models: Probe<V2Models>, jobs: Probe<Jobs>, capabilities: Capabilities?) -> Row {
        if capabilities?.dependencies.contains(where: { $0.name == "ollama" && !$0.ready }) == true {
            return .init(.chat, "Mangler Ollama", .error, "PC’en melder Ollama utilgængelig.",
                         next: "Start eller tjek Ollama på PC’en.")
        }
        if jobs.value?.jobs.contains(where: { $0.status == .rendering }) == true {
            return .init(.chat, "Optaget", .warning, "Appen venter med PC-chat, mens PC’en renderer video.",
                         next: "Prøv igen, når videoen er færdig, eller vælg en telefonmodel.")
        }
        if case .failed(.unsupported) = models {
            return .init(.chat, "V1 mulig", .info, "PC’en giver ikke et V2-modelkatalog. Ældre versioner kan bruge V1-chat.",
                         next: "Send en almindelig PC-chatbesked for at afprøve den.")
        }
        guard let catalog = models.value else { return (models.issue ?? .unknown).row(.chat) }
        let count = PCModelSelection.installed(in: catalog).filter(PCModelSelection.usable).count
        guard count > 0 else {
            return .init(.chat, "Mangler model", .error, "Kataloget viser ingen tilgængelig tekstmodel.",
                         next: "Installér en chatmodel via Ollama på PC’en, og opdatér status.")
        }
        let detail = count == 1 ? "PC’en viser én tilgængelig chatmodel." : "PC’en viser \(count) tilgængelige chatmodeller."
        guard jobs.value != nil else {
            return .init(.chat, "Kan ikke bekræftes", .info, detail,
                         next: "Videokøens status kunne ikke læses. Opdatér status, eller prøv en PC-chatbesked.")
        }
        return .init(.chat, "Klar", .success, detail)
    }

    private static func videoRow(_ jobs: Probe<Jobs>, capabilities: Probe<Capabilities>, commentaryEnabled: Bool) -> Row {
        guard let info = capabilities.value else { return (capabilities.issue ?? .unknown).row(.video) }
        let required: Set<String> = commentaryEnabled ? Capabilities.requiredDependencies : ["ffmpeg", "ffprobe"]
        let missing = info.missingRequired.filter { required.contains($0.name) }.map(\.name).sorted()
        if !missing.isEmpty {
            return .init(.video, "Mangler \(missing.joined(separator: ", "))", .error,
                         "PC’en melder en nødvendig videokomponent utilgængelig.",
                         next: "Tjek komponenterne på PC’en. Uden kommentator kræves kun ffmpeg og ffprobe.")
        }
        guard info.limit > 0, !info.moods.isEmpty else {
            return .init(.video, "Ikke klar", .warning, "PC’en tillader ingen klip eller tilbyder ingen videostilarter.",
                         next: "Tjek PC’ens videoopsætning.")
        }
        guard let queue = jobs.value else { return (jobs.issue ?? .unknown).row(.video) }
        let active = queue.jobs.filter { $0.status.active && $0.status != .queued }.count
        if active > 0 {
            return .init(.video, "Optaget", .warning,
                         active == 1 ? "Ét videojob behandles." : "\(active) videojobs behandles.",
                         next: "Åbn Video → Jobs for at følge arbejdet.")
        }
        guard required.isSubset(of: Set(info.dependencies.map(\.name))) else {
            return .init(.video, "Kan ikke bekræftes", .info, "PC’en rapporterer kun nogle af videokomponenterne.",
                         next: "Tjek den aktuelle opskrift i Video Studio.")
        }
        let detail = commentaryEnabled ? "Videokomponenterne til opskriften med kommentator svarer."
            : "ffmpeg og ffprobe er klar til video uden kommentator."
        return .init(.video, "Klar", .success, detail)
    }

    private static func codeRow(_ api: LiveAPI) async -> Row {
        let batches = await read { try await api.codeBatches() }
        if let list = batches.value {
            let active = list.jobs.filter { ["queued", "running"].contains($0.status) }.count
            let detail = active > 0 ? "Batchkøen svarer og har \(active) job i kø eller under behandling."
                : "Batchkøen svarer. PC’en oplyser ikke, hvilke repoer der er godkendt."
            return .init(.code, active > 0 ? "Optaget" : "Batchkø klar", active > 0 ? .warning : .success, detail,
                         next: "Se filvalg og repo under Code Bot.")
        }
        guard case .failed(.unsupported) = batches else { return (batches.issue ?? .unknown).row(.code) }
        let workspace = await read { try await api.v2CodeWorkspace() }
        guard let files = workspace.value?.files else {
            if case .failed(.unsupported) = workspace {
                return .init(.code, "Mangler PC-modul", .error, "Hverken batchkø eller filområdet svarer på de kendte ruter.",
                             next: "Tjek Code Bot-modulet og PC’ens version.")
            }
            return (workspace.issue ?? .unknown).row(.code)
        }
        return .init(.code, "Kun filområde", .info, "Filområdet svarer med \(files.count) filer. Batchkøen er utilgængelig.",
                     next: "Brug Code Bot til enkeltfiler, eller tjek PC’ens batchmodul.")
    }

    private static func agentRows(_ api: LiveAPI) async -> [Row] {
        let hub = await read { try await api.v2Hub() }
        guard let snapshot = hub.value else {
            let issue = hub.issue ?? .unknown
            return [issue.row(.hub),
                    .init(.memory, "Ukendt", .info, "Hukommelsen kræver en agent, som appen kan finde i Agent-Hub.")]
        }
        let count = snapshot.summary.active_agents
        let hubRow: Row = count > 0
            ? .init(.hub, "Klar", .success, count == 1 ? "PC’en melder én aktiv agent." : "PC’en melder \(count) aktive agenter.")
            : .init(.hub, "Ingen aktive agenter", .info, "Agent-Hub svarer. Ingen agenter er aktive lige nu.")
        guard let agent = snapshot.agents.first(where: { $0.status != .offline }) ?? snapshot.agents.first else {
            return [hubRow, .init(.memory, "Ukendt", .info, "Agent-Hub viser ingen agent, hvis hukommelse kan tjekkes.")]
        }
        let memory = await read { try await api.v2Memory(agentID: agent.id).items.isEmpty }
        guard let empty = memory.value else {
            if case .failed(.unsupported) = memory {
                return [hubRow, .init(.memory, "Ikke bekræftet", .info, "PC’en tilbyder ikke hukommelsesruten for den testede agent.",
                                      next: "Tjek hukommelsesopsætningen på PC’en.")]
            }
            return [hubRow, (memory.issue ?? .unknown).row(.memory)]
        }
        return [hubRow, .init(.memory, "Kan læses", .success,
                              empty ? "Hukommelsen svarer for én agent og returnerer ingen poster på første side."
                                    : "Hukommelsen svarer og indeholder poster for én agent.")]
    }
}
