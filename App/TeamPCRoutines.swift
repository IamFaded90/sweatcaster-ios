// Reads and edits the PC's existing daily repository routines.

import Foundation
import SwiftUI

struct TeamPCRoutines: Decodable, Sendable {
    let routines: [TeamPCRoutine]
}

struct TeamPCRoutine: Decodable, Identifiable, Sendable {
    enum Action: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
        case reindex = "reindex_repository"
        case refresh = "refresh_repository"

        var id: Self { self }
        var title: String { self == .reindex ? "Indeksér lokal kopi" : "Hent fra GitHub og indeksér" }
    }

    struct Configuration: Codable, Equatable, Identifiable, Sendable {
        let action: Action
        let repo: String
        let hour: Int

        var id: String { action.rawValue + "/" + repo.lowercased() }
        var time: String { String(format: "%02d:00", hour) }
    }

    let action: Action
    let repo: String
    let hour: Int
    let today: String?

    var id: String { configuration.id }
    var configuration: Configuration { .init(action: action, repo: repo, hour: hour) }
    var status: String {
        switch today {
        case "running": "Kører"
        case "completed": "Færdig i dag"
        case "failed": "Fejlede i dag"
        case "waiting": "Venter"
        default: "Planlagt"
        }
    }
}

@MainActor struct TeamPCRoutinesView: View {
    let api: LiveAPI
    @Environment(\.fadedPalette) private var palette
    @State private var saved: [TeamPCRoutine]?
    @State private var draft: [TeamPCRoutine.Configuration] = []
    @State private var repo = ""
    @State private var hour = 2
    @State private var action: TeamPCRoutine.Action = .reindex
    @State private var busy = false
    @State private var needsReload = false
    @State private var confirmSave = false
    @State private var notice: String?

    private var changed: Bool { saved.map { $0.map(\.configuration) != draft } ?? false }
    private var candidate: TeamPCRoutine.Configuration? {
        let slug = repo.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard (3...150).contains(slug.utf8.count),
              slug.range(of: #"\A[a-z0-9_-]+/[a-z0-9_-][a-z0-9_.-]*\z"#, options: .regularExpression) != nil,
              !slug.hasSuffix("."), !slug.hasSuffix(".git") else { return nil }
        return .init(action: action, repo: slug, hour: hour)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FadedSpacing.section) {
                FadedSignature()
                Text("PC’en kører rutinerne, mens appen er lukket. Tiderne følger København.")
                    .font(.subheadline).foregroundStyle(palette.secondary)
                if let notice { Text(notice).font(.subheadline).accessibilityAddTraits(.updatesFrequently) }
                if busy { Text("Arbejder med rutinerne…").font(.footnote).foregroundStyle(palette.secondary) }
                if saved == nil || needsReload {
                    FadedPrimaryButton("Hent rutiner fra PC", icon: "arrow.clockwise") {
                        Task { await load(discardDraft: true) }
                    }.disabled(busy)
                }
                if saved != nil {
                    routineList
                    if !needsReload { addRoutine }
                    if changed && !needsReload {
                        FadedPrimaryButton("Gem ændringer på PC", icon: "checkmark") { confirmSave = true }
                            .disabled(busy)
                        FadedSecondaryButton("Fortryd ændringer", icon: "arrow.uturn.backward") {
                            draft = saved?.map(\.configuration) ?? []
                            notice = nil
                        }.disabled(busy)
                    }
                }
            }
            .frame(maxWidth: 640, alignment: .leading)
            .padding(FadedSpacing.edge).frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .background { FadedBackground() }
        .foregroundStyle(palette.text)
        .navigationTitle("Planlagte PC-rutiner")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        .confirmationDialog("Gem planlagte rutiner?", isPresented: $confirmSave, titleVisibility: .visible) {
            Button("Bekræft og gem") { Task { await save() } }
        } message: {
            Text(draft.isEmpty ? "Alle planlagte Git-rutiner fjernes fra PC’en."
                 : "PC’ens rutiner erstattes med de \(draft.count) rutiner på listen.")
        }
    }

    private var routineList: some View {
        VStack(alignment: .leading, spacing: FadedSpacing.section) {
            FadedSectionLabel("Dine rutiner")
            if draft.isEmpty { Text("Ingen planlagte rutiner.").font(.subheadline).foregroundStyle(palette.secondary) }
            ForEach(draft) { item in
                FadedCard(accent: palette.cyan) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: item.repo).font(FadedTypography.action)
                        Text("\(item.action.title) · fra kl. \(item.time)").font(.subheadline)
                        Text(saved?.first { $0.configuration == item }?.status ?? "Afventer gemning")
                            .font(.footnote).foregroundStyle(palette.secondary)
                        Button("Fjern rutine", systemImage: "minus.circle", role: .destructive) {
                            draft.removeAll { $0.id == item.id }
                        }
                        .frame(minHeight: 44)
                        .accessibilityLabel("Fjern rutine for \(item.repo)")
                        .disabled(busy || needsReload)
                    }
                }
            }
        }
    }

    private var addRoutine: some View {
        FadedCard {
            VStack(alignment: .leading, spacing: 8) {
                FadedSectionLabel("Tilføj rutine")
                TextField("GitHub-repo · ejer/projekt", text: $repo)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder).frame(minHeight: 44)
                Picker("Handling", selection: $action) {
                    ForEach(TeamPCRoutine.Action.allCases) { Text($0.title).tag($0) }
                }.frame(minHeight: 44)
                Picker("Kører fra", selection: $hour) {
                    ForEach(0...23, id: \.self) { value in
                        Text(String(format: "%02d:00", value)).tag(value)
                    }
                }.frame(minHeight: 44)
                Text(action == .refresh ? "PC’en bruger sin GitHub-adgang til at hente ændringer."
                     : "Repoet skal allerede ligge i Code Bots arbejdsmappe.")
                    .font(.footnote).foregroundStyle(palette.secondary)
                if draft.count >= 10 {
                    Text("Der er plads til 10 rutiner.").font(.footnote).foregroundStyle(palette.secondary)
                } else if let candidate, draft.contains(where: { $0.id == candidate.id }) {
                    Text("Den handling er allerede planlagt for repoet.").font(.footnote).foregroundStyle(palette.secondary)
                }
                FadedSecondaryButton("Tilføj til listen", icon: "plus") {
                    guard let candidate, draft.count < 10, !draft.contains(where: { $0.id == candidate.id }) else { return }
                    draft.append(candidate)
                    repo = ""
                    notice = nil
                }
                .disabled(candidate == nil || draft.count >= 10 || draft.contains(where: { $0.id == candidate?.id }))
            }
        }.disabled(busy)
    }

    private func load(discardDraft: Bool = false) async {
        guard !busy, !changed || discardDraft else { return }
        busy = true
        defer { busy = false }
        do {
            let entries = try await api.teamRoutines().routines
            try Task.checkCancellation()
            try update(entries)
            notice = nil
        } catch {
            guard !Task.isCancelled else { return }
            AppDiagnostics.record(error)
            notice = "PC’ens rutiner kunne ikke hentes. Tjek forbindelsen og PC’ens agentmodul."
        }
    }

    private func save() async {
        guard !busy, !needsReload, changed, let saved else { return }
        busy = true
        defer { busy = false }
        let next = draft
        do {
            let current = try await api.teamRoutines().routines
            guard current.map(\.configuration) == saved.map(\.configuration) else {
                needsReload = true
                notice = "Rutinerne er ændret på PC’en. Hent listen igen, før du redigerer."
                return
            }
        } catch {
            AppDiagnostics.record(error)
            notice = "PC’en kunne ikke kontrollere listen. Prøv at gemme igen."
            return
        }
        do {
            let result = try await api.saveTeamRoutines(next)
            try update(result.routines)
            notice = "Rutinerne er gemt på PC’en."
        } catch APIError.http(422, _) {
            AppDiagnostics.record(APIError.http(422, nil))
            notice = "PC’en afviste listen. Tjek, at repoerne ligger i Code Bots arbejdsmappe."
        } catch {
            AppDiagnostics.record(error)
            needsReload = true
            notice = "PC’en bekræftede ikke gemningen. Hent listen igen, før du prøver på ny."
        }
    }

    private func update(_ entries: [TeamPCRoutine]) throws {
        guard entries.count <= 10, Set(entries.map(\.id)).count == entries.count,
              entries.allSatisfy({ (0...23).contains($0.hour) }) else { throw V2Failure.invalidResponse }
        saved = entries
        draft = entries.map(\.configuration)
        needsReload = false
    }
}
