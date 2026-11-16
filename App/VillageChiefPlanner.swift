import SwiftUI

private struct VillagePlannerAPIKey: EnvironmentKey {
    static let defaultValue: LiveAPI? = nil
}

extension EnvironmentValues {
    var villagePlannerAPI: LiveAPI? {
        get { self[VillagePlannerAPIKey.self] }
        set { self[VillagePlannerAPIKey.self] = newValue }
    }
}

private struct VillageChiefPlan: Codable, Equatable {
    struct Step: Codable, Identifiable, Equatable {
        enum Priority: Int, CaseIterable, Codable, Identifiable {
            case high = 3, normal = 2, low = 1
            var id: Self { self }
            var title: String {
                switch self {
                case .high: "Høj"
                case .normal: "Normal"
                case .low: "Lav"
                }
            }
        }
        let id: UUID
        var botID: UUID
        var task: String
        var priority: Priority
        var attempted = false
        var receipt: UUID?

        var valid: Bool {
            (1...1_000).contains(task.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.count)
        }
    }

    private struct Proposal: Decodable {
        struct Item: Decodable {
            let agent: Int
            let task: String
            let priority: Step.Priority
        }
        let tasks: [Item]
    }

    var goal = ""
    var steps: [Step] = []
    var target: String?

    static func fromReply(_ reply: String, goal: String, bots: [VillageBot]) throws -> Self {
        guard reply.utf8.count <= 32_000, let start = reply.firstIndex(of: "{"),
              let end = reply.lastIndex(of: "}"), start < end else { throw PhoneModelError.emptyResponse }
        let structure = try JSONDecoder().decode(Proposal.self, from: Data(reply[start...end].utf8))
        guard (1...5).contains(structure.tasks.count) else { throw PhoneModelError.emptyResponse }
        let steps = try structure.tasks.map { task in
            guard (1...bots.count).contains(task.agent) else { throw PhoneModelError.emptyResponse }
            let step = Step(id: UUID(), botID: bots[task.agent - 1].id, task: task.task,
                            priority: task.priority, receipt: nil)
            guard step.valid else { throw PhoneModelError.emptyResponse }
            return step
        }
        return Self(goal: goal, steps: steps, target: nil)
    }
}

@MainActor struct VillageChiefPlanner: View {
    let bots: [VillageBot]
    @Environment(\.villagePlannerAPI) private var api
    @Environment(\.scenePhase) private var scenePhase
    @State private var plan = VillageChiefPlan()
    @State private var model = ""
    @State private var work: Task<Void, Never>?
    @State private var notice: String?
    @State private var confirming = false
    @State private var dialog: Dialog = .send
    @State private var loaded = false
    @FocusState private var editing: Bool

    private enum Dialog: Equatable { case send, remove }

    private var roster: [VillageBot] { bots.filter { $0.id != VillageBot.lumiID } }
    private var models: [PhoneModels.TextOption] { PhoneModels.textOptions.filter { PhoneModels.isReady($0.id) } }
    private var pending: [VillageChiefPlan.Step] { plan.steps.filter { $0.receipt == nil } }
    private var goal: String { plan.goal.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSend: Bool {
        guard loaded, work == nil, let api, !pending.isEmpty,
              plan.target == nil || plan.target == api.queueTargetID else { return false }
        return pending.allSatisfy { step in step.valid && roster.contains { $0.id == step.botID } }
    }
    private var folder: URL { URL.applicationSupportDirectory.appending(path: "Chief", directoryHint: .isDirectory) }
    private var store: LocalFileStore { LocalFileStore(root: folder, maximumBytes: 50_000) }
    private var file: URL { folder.appending(path: "draft.json") }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FadedSpacing.m) {
                FadedCard {
                    VStack(alignment: .leading, spacing: FadedSpacing.s) {
                        TextField("Hvad skal holdet hjælpe dig med?", text: $plan.goal, axis: .vertical)
                            .lineLimit(3...6).focused($editing)
                            .disabled(!loaded || work != nil || !plan.steps.isEmpty)
                        if plan.steps.isEmpty {
                            if models.isEmpty { FadedDetailText("Vælg en hentet telefonmodel under Lokale modeller.") }
                            Picker("Planlæg på iPhone med", selection: $model) {
                                ForEach(models) { Text($0.name).tag($0.id) }
                            }.disabled(work != nil)
                            if goal.unicodeScalars.count > 1_000 { FadedDetailText("Brug højst 1.000 tegn.") }
                            FadedPrimaryButton("Foreslå en plan", icon: "list.bullet.rectangle", action: propose)
                                .disabled(!loaded || work != nil || !models.contains { $0.id == model } ||
                                          !(1...1_000).contains(goal.unicodeScalars.count) || roster.isEmpty)
                        }
                    }
                }
                if !plan.steps.isEmpty { review }
                if work != nil {
                    ProgressView("Arbejder…")
                    Button("Stop", systemImage: "stop.circle") { work?.cancel() }.frame(minHeight: 44)
                }
                if let notice { FadedToast(notice, tone: .info) }
            }
            .padding(FadedSpacing.edge)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .background { FadedBackground(variant: .village) }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Chief")
        .navigationBarTitleDisplayMode(.inline)
        .task { load() }
        .onChange(of: scenePhase) { if scenePhase != .active { work?.cancel() } }
        .onChange(of: plan) { if loaded, !plan.steps.isEmpty, work == nil { _ = save() } }
        .onDisappear { work?.cancel() }
        .confirmationDialog(dialog == .send ? "Send \(pending.count) opgaver til agenternes computere?"
                            : "Fjern den lokale Chief-kladde?", isPresented: $confirming, titleVisibility: .visible) {
            if dialog == .send { Button("Godkend og send", action: send) }
            else { Button("Fjern kladde", role: .destructive, action: clear) }
            Button("Annullér", role: .cancel) {}
        }
    }

    private var review: some View {
        VStack(alignment: .leading, spacing: FadedSpacing.m) {
            FadedSectionLabel("Gennemgå opgaverne")
            ForEach($plan.steps) { $step in
                FadedCard {
                    VStack(alignment: .leading, spacing: FadedSpacing.s) {
                        TextField("Opgave", text: $step.task, axis: .vertical).lineLimit(2...5)
                        Picker("Agent", selection: $step.botID) {
                            if !roster.contains(where: { $0.id == step.botID }) {
                                Text("Vælg en agent").tag(step.botID)
                            }
                            ForEach(roster) { Text($0.name).tag($0.id) }
                        }
                        Picker("Prioritet", selection: $step.priority) {
                            ForEach(VillageChiefPlan.Step.Priority.allCases) { Text($0.title).tag($0) }
                        }
                        if step.receipt != nil { Label("Modtaget på PC’en", systemImage: "checkmark.circle") }
                        else if step.attempted { FadedDetailText("Afventer kvittering fra PC’en.") }
                    }.disabled(work != nil || step.attempted)
                }
            }
            if !pending.isEmpty {
                if api == nil { FadedDetailText("Forbind til din PC for at sende de viste opgaver.") }
                else if let target = plan.target, target != api?.queueTargetID {
                    FadedDetailText("Denne kladde er knyttet til den tidligere PC. Forbind til den for at fortsætte.")
                }
                FadedPrimaryButton("Send \(pending.count) opgaver", icon: "paperplane") {
                    editing = false
                    dialog = .send
                    confirming = true
                }.disabled(!canSend)
            }
            Button("Fjern kladde", systemImage: "trash", role: .destructive) {
                dialog = .remove
                confirming = true
            }
                .disabled(work != nil).frame(minHeight: 44)
        }
    }

    private func propose() {
        guard loaded, work == nil, plan.steps.isEmpty, (1...1_000).contains(goal.unicodeScalars.count),
              models.contains(where: { $0.id == model }), !roster.isEmpty else { return }
        editing = false
        notice = nil
        let bots = Array(roster.prefix(10))
        let brief = goal
        let engine = model
        let names = bots.enumerated().map {
            "\($0.offset + 1). \(String($0.element.name.prefix(40))) — \($0.element.specialtyTitle)"
        }.joined(separator: "\n")
        work = Task {
            defer { work = nil }
            do {
                var reply = ""
                try await PhoneModels.reply(modelID: engine, prompt: brief, instructions: """
                    Du er Chief. Del målet i 1-5 konkrete danske opgaver til holdet.
                    Svar kun med JSON som {"tasks":[{"agent":1,"task":"Find tre mulige løsninger","priority":3}]}.
                    Agent skal være et af numrene nedenfor. Prioritet 3 er høj, 2 er normal, 1 er lav.
                    Hver opgave skal kunne besvares som en arbejdsrapport.
                    \(names)
                    """) { reply = $0 }
                try Task.checkCancellation()
                plan = try VillageChiefPlan.fromReply(reply, goal: brief, bots: bots)
                _ = save()
            } catch is CancellationError {
            } catch {
                AppDiagnostics.record(error)
                notice = "Telefonmodellen kunne ikke lave en plan. Prøv en kortere beskrivelse eller en anden model."
            }
        }
    }

    private func send() {
        guard canSend, let api else { return }
        let ids = pending.enumerated().sorted {
            let first = $0.element.priority.rawValue, second = $1.element.priority.rawValue
            return first == second ? $0.offset < $1.offset : first > second
        }.map { $0.element.id }
        plan.target = api.queueTargetID
        notice = nil
        guard save() else { return }
        work = Task {
            defer { work = nil }
            do {
                for id in ids {
                    try Task.checkCancellation()
                    guard let index = plan.steps.firstIndex(where: { $0.id == id }) else { throw APIError.input }
                    let step = plan.steps[index]
                    plan.steps[index].attempted = true
                    guard save() else {
                        plan.steps[index].attempted = step.attempted
                        return
                    }
                    let client = BotComputerClient(api: api, botID: step.botID)
                    let result = try await client.submit(prompt: step.task.trimmingCharacters(in: .whitespacesAndNewlines),
                        fileID: nil, requestID: step.id, phoneKind: nil, phoneTime: nil,
                        taskContext: nil, agentProfile: nil, webSearch: false)
                    plan.steps[index].receipt = result.id
                    guard save() else { return }
                }
                notice = "Opgaverne ligger på agenternes computere."
            } catch is CancellationError {
            } catch {
                AppDiagnostics.record(error)
                notice = "Afsendelsen blev afbrudt. Opgaver med kvittering er sendt. Prøv at sende de resterende igen."
            }
        }
    }

    private func load() {
        guard !loaded else { return }
        do {
            let recovered = try store.read(VillageChiefPlan.self, from: file)
            guard (1...5).contains(recovered.steps.count),
                  Set(recovered.steps.map(\.id)).count == recovered.steps.count else {
                throw LocalFileStore.Failure.invalidFile
            }
            plan = recovered
        } catch where LocalFileStore.isMissing(error) {
            plan = VillageChiefPlan()
        } catch {
            AppDiagnostics.record(error)
            notice = "Chief-kladden kunne ikke læses."
            return
        }
        model = models.first?.id ?? ""
        loaded = true
    }

    private func save() -> Bool {
        do { try store.write(plan, to: file); return true }
        catch {
            AppDiagnostics.record(error)
            notice = "Kladden kunne ikke gemmes på iPhone."
            return false
        }
    }

    private func clear() {
        do {
            try store.delete(file)
            plan = VillageChiefPlan()
            notice = nil
        } catch {
            AppDiagnostics.record(error)
            notice = "Kladden kunne ikke fjernes."
        }
    }
}
