import SwiftUI
import UIKit

enum VillageSurpriseIntent {
    static func matches(_ value: String) -> Bool {
        value.lowercased().range(of: #"^(?:(?:kan|vil) du )?(?:overrask mig|lav noget (?:nyt |nyttigt )?til (?:min |vores )?landsby|byg noget til (?:min |vores )?landsby|vis mine overraskelser|åbn overraskelser)\b"#,
                                options: .regularExpression) != nil
    }
}

struct VillageSurprise: Decodable, Identifiable {
    let id, botID: UUID
    let brief, state: String
    let figures: [String]
    let revision, bytes: Int
    let note: String?
    let addon: CodeAddOn?
    let checks: [String]?
    let steps: [String]?
    let completed: [Int]?

    var title: String { addon?.title ?? "En ny idé til landsbyen" }
    var stateTitle: String {
        switch state {
        case "queued": "Venter på ledig PC-tid"
        case "building": "Agenten bygger"
        case "ready": "Klar til at prøve"
        case "kept": "Gemt i dine tilføjelser"
        default: "Idéen skal prøves igen"
        }
    }
}

@MainActor struct VillageSurprisesView: View {
    let api: LiveAPI?
    let bot: VillageBot
    let prompt: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @State private var brief = ""
    @State private var profiles: [VillageBot] = []
    @State private var selectedAgents: Set<UUID>
    @State private var jobs: [VillageSurprise] = []
    @State private var refresh = 0
    @State private var busy = false
    @State private var notice: String?
    @State private var selected: VillageSurprise?
    @State private var createID = UUID()

    init(api: LiveAPI?, bot: VillageBot, prompt: String = "") {
        self.api = api
        self.bot = bot
        self.prompt = prompt
        _selectedAgents = State(initialValue: [bot.id])
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    FadedCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Lad " + bot.name + " skabe noget").font(.title3.bold())
                            Text("Agenten laver en lille aktivitet med værktøjer, når PC’en har ledig tid.")
                            TextField("Hvad må agenten finde på?", text: $brief, axis: .vertical)
                                .lineLimit(3...6)
                            DisclosureGroup("Vælg de figurer, agenten må bruge") {
                                ForEach(profiles) { profile in
                                    Toggle(isOn: Binding(get: { selectedAgents.contains(profile.id) }, set: { yes in
                                        if yes { selectedAgents.insert(profile.id) } else { selectedAgents.remove(profile.id) }
                                    })) {
                                        HStack {
                                            VillageBotAvatar(bot: profile, size: 36, radius: 8)
                                            Text(profile.name)
                                        }
                                    }
                                }
                            }
                            FadedPrimaryButton("Giv agenten opgaven", icon: "sparkles") { create() }
                                .disabled(api == nil || busy || brief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                                          brief.count > 650 || selectedAgents.isEmpty)
                        }
                    }
                    ForEach(jobs) { job in
                        Button { selected = job } label: {
                            FadedCard {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(job.title).font(.headline)
                                    Text(job.stateTitle).font(.subheadline)
                                    if let note = job.note { Text(note).font(.caption).foregroundStyle(.secondary) }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }.buttonStyle(.plain)
                    }
                    if api == nil { Text("Forbind din PC, så agenten kan bygge til landsbyen.") }
                    if busy { ProgressView("Gemmer opgaven på PC’en…") }
                    if let notice { Text(notice).foregroundStyle(.secondary) }
                }.padding(FadedSpacing.edge)
            }
            .background { FadedBackground(variant: .village) }
            .navigationTitle("Overraskelser").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Luk") { dismiss() } }
                ToolbarItem(placement: .topBarLeading) {
                    Button("Opdatér", systemImage: "arrow.clockwise") { refresh += 1 }.labelStyle(.iconOnly)
                }
            }
            .sheet(item: $selected, onDismiss: { refresh += 1 }) { job in
                if let api { VillageSurpriseDetails(api: api, job: job) }
            }
            .task(id: refresh) {
                profiles = (try? MigratedAppData.shared.loadBots().get()) ?? []
                if !profiles.contains(where: { $0.id == bot.id }) { profiles.insert(bot, at: 0) }
                if brief.isEmpty { brief = prompt.isEmpty ? "Lav en nyttig aktivitet til mit atelier med mine valgte figurer." : prompt }
                repeat {
                    await load()
                    guard jobs.contains(where: { ["queued", "building"].contains($0.state) }) else { return }
                    do { try await Task.sleep(for: .seconds(15)) } catch { return }
                } while !Task.isCancelled && phase == .active
            }
            .onChange(of: phase) { _, phase in if phase == .active { refresh += 1 } }
        }
    }

    private func load() async {
        guard let api else { return }
        do {
            struct Library: Decodable { let items: [VillageSurprise] }
            let result: Library = try await api.moduleJSON("village-surprises",
                query: [.init(name: "bot_id", value: bot.id.uuidString)])
            try Task.checkCancellation()
            jobs = result.items
        } catch is CancellationError { return }
        catch { notice = (error as? APIError)?.title ?? "Aktiviteterne kunne ikke hentes fra PC’en." }
    }

    private func create() {
        guard let api, !busy else { return }
        busy = true
        notice = nil
        let figures = Set(profiles.filter { selectedAgents.contains($0.id) }.map {
            VillagePortraitIdentity.name(for: $0) ?? $0.villageFigure
        })
        Task { @MainActor in
            defer { busy = false }
            do {
                let body: [String: Any] = ["action": "create", "brief": brief, "figures": figures.sorted()]
                let _: VillageSurprise = try await api.saleAction("village-surprises/" + createID.uuidString,
                                                                body: body, bot: bot.id)
                createID = UUID()
                refresh += 1
            } catch { notice = (error as? APIError)?.title ?? "Opgaven kunne ikke gemmes." }
        }
    }
}

@MainActor struct VillageSurpriseDetails: View {
    let api: LiveAPI
    @State var job: VillageSurprise
    @Environment(\.dismiss) private var dismiss
    @State private var busy = false
    @State private var notice: String?
    @State private var revision = ""
    @State private var selectedTool: V0LocalTool?
    @State private var deleting = false
    @Environment(\.scenePhase) private var phase

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    scene
                    Text(job.title).font(.title2.bold())
                    Text(job.stateTitle).font(.headline)
                    if let note = job.note { Text(note).foregroundStyle(.secondary) }
                    if let addon = job.addon {
                        if let steps = job.steps, !steps.isEmpty {
                            ForEach(steps.indices, id: \.self) { index in
                                Toggle(isOn: Binding(get: { job.completed?.contains(index) == true }, set: { done in
                                    change("progress", extra: ["index": index, "done": done])
                                })) { Text(steps[index]) }
                            }
                        } else { Text(addon.text) }
                        ForEach(Array(addon.actions.enumerated()), id: \.offset) { _, action in
                            if let tool = V0LocalTool.all.first(where: { $0.id == action.value }) {
                                FadedPrimaryButton(action.label, icon: "wrench.and.screwdriver") { selectedTool = tool }
                            }
                        }
                        Text(ByteCountFormatter.string(fromByteCount: Int64(job.bytes), countStyle: .file))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let checks = job.checks {
                        DisclosureGroup("PC-kontrol") {
                            ForEach(checks, id: \.self) { Label($0, systemImage: "checkmark") }
                                .font(.caption)
                        }
                    }
                    if job.state == "ready" {
                        FadedPrimaryButton("Behold i mine tilføjelser", icon: "tray.and.arrow.down") { change("keep") }
                    }
                    if ["ready", "error", "queued"].contains(job.state) {
                        TextField("Ret idéen", text: $revision, axis: .vertical).lineLimit(2...5)
                        FadedSecondaryButton("Byg en ny version", icon: "arrow.triangle.2.circlepath") {
                            change("revise", extra: ["brief": revision])
                        }.disabled(revision.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || revision.count > 650)
                    }
                    if job.state == "kept" {
                        NavigationLink { CodeAddOnsView(api: api) } label: {
                            Label("Åbn mine tilføjelser", systemImage: "square.grid.2x2")
                        }.frame(minHeight: 44)
                    }
                    if job.state != "building" {
                        Button("Slet aktiviteten", systemImage: "trash", role: .destructive) { deleting = true }
                            .frame(minHeight: 44)
                    }
                    if busy { ProgressView("Gemmer…") }
                    if let notice { Text(notice).foregroundStyle(.secondary) }
                }.disabled(busy).padding(FadedSpacing.edge)
            }
            .background { FadedBackground(variant: .village) }
            .navigationTitle("Agentens nye aktivitet").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Luk") { dismiss() } } }
            .sheet(item: $selectedTool) { V0LocalToolSheet(tool: $0) }
            .confirmationDialog("Slet aktiviteten og dens gemte tilføjelse?", isPresented: $deleting) {
                Button("Slet", role: .destructive) { change("remove") }
                Button("Annuller", role: .cancel) {}
            }
            .onAppear { revision = job.brief }
            .task(id: job.state) {
                guard ["queued", "building"].contains(job.state) else { return }
                repeat {
                    do { try await Task.sleep(for: .seconds(8)) } catch { return }
                    struct Library: Decodable { let items: [VillageSurprise] }
                    if let response: Library = try? await api.moduleJSON("village-surprises",
                        query: [.init(name: "bot_id", value: job.botID.uuidString)]),
                       !Task.isCancelled, let current = response.items.first(where: { $0.id == job.id }) { job = current }
                } while !Task.isCancelled && phase == .active
            }
        }
    }

    private var scene: some View {
        ZStack(alignment: .bottom) {
            if let image = VillageProductionArt.image("room-research-lab") {
                Image(uiImage: image).resizable().scaledToFill()
            }
            HStack(alignment: .bottom, spacing: 12) {
                ForEach(job.figures, id: \.self) { character in
                    if let image = (["lumi", "harper"].contains(character)
                        ? VillageProductionArt.portrait(character)
                        : VillageProductionArt.frame(character: character, direction: 0, step: 0)) {
                        Image(uiImage: image).resizable().scaledToFit().frame(maxWidth: 100, maxHeight: 130)
                    }
                }
            }.padding(.bottom, 18).padding(.horizontal, 12)
        }
        .frame(height: 235).frame(maxWidth: .infinity).clipped()
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .accessibilityLabel("Aktivitet med de figurer, du har valgt")
    }

    private func change(_ action: String, extra: [String: Any] = [:]) {
        guard !busy else { return }
        busy = true
        notice = nil
        Task { @MainActor in
            defer { busy = false }
            do {
                let body = extra.merging(["action": action, "revision": job.revision]) { _, b in b }
                if action == "remove" {
                    struct Removed: Decodable { let removed: Bool }
                    let _: Removed = try await api.saleAction("village-surprises/" + job.id.uuidString, body: body, bot: job.botID)
                    dismiss()
                } else {
                    job = try await api.saleAction("village-surprises/" + job.id.uuidString, body: body, bot: job.botID)
                }
            } catch { notice = (error as? APIError)?.title ?? "Aktiviteten kunne ikke opdateres." }
        }
    }
}
