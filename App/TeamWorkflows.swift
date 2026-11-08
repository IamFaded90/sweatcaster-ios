// Sequential, local conversations with a selected team or a set of roles.

import Foundation
import SwiftUI

enum TeamWorkflowMode: String, Identifiable, Hashable {
    case group, handoff, debate, chief, skill

    var id: Self { self }

    var title: String {
        switch self {
        case .group: "Gruppechat"
        case .handoff: "Overdragelse"
        case .debate: "Debat"
        case .chief: "Chief"
        case .skill: "Kør færdighed"
        }
    }

    var icon: String {
        switch self {
        case .group: "person.2"
        case .handoff: "arrow.right.arrow.left"
        case .debate: "bubble.left.and.bubble.right"
        case .chief: "crown"
        case .skill: "list.number"
        }
    }

    var detail: String {
        switch self {
        case .group: "Vælg 2–6 bots. De svarer én ad gangen."
        case .handoff: "Vælg en afsender og en modtager. Modtageren får afsenderens forslag."
        case .debate: "Fire roller vurderer samme spørgsmål og samler deres konklusion."
        case .chief: "Chief fordeler et mål i delopgaver og samler forslag fra tre roller."
        case .skill: "Botten følger den gemte arbejdsgang i sit tekstsvar."
        }
    }
}

private struct TeamWorkflowStep {
    let name: String
    let instructions: String

    init(_ name: String, _ instructions: String) {
        self.name = name
        self.instructions = instructions
    }

    init(bot: VillageBot, action: String) {
        name = bot.name
        let profile = ["Speciale: \(bot.specialtyTitle)", bot.responsibility ?? "", bot.prompt]
            .filter { !$0.isEmpty }.joined(separator: "\n")
        instructions = "\(action)\nBotprofil: \(String(profile.unicodeScalars.prefix(600)))"
    }
}

private struct TeamWorkflowTurn: Identifiable {
    struct Reply: Identifiable {
        let id = UUID()
        let name: String
        var text = ""
    }

    let id = UUID()
    let prompt: String
    let model: String
    var replies: [Reply] = []
    var completed = false
    var notice: String?

    var context: String {
        (["Bruger: " + prompt] + replies.map { "\($0.name): \($0.text)" }).joined(separator: "\n")
    }
}

@MainActor struct TeamWorkflowView: View {
    let mode: TeamWorkflowMode
    let bots: [VillageBot]
    let skill: TeamBotNotebookStore.Skill?

    @Environment(\.fadedPalette) private var palette
    @Environment(\.scenePhase) private var phase
    @AppStorage(AppStorageKeys.phoneModel) private var phoneModel = "apple"
    @State private var members: [UUID] = []
    @State private var draft = ""
    @State private var turns: [TeamWorkflowTurn] = []
    @State private var work: Task<Void, Never>?
    @State private var status: String?
    @FocusState private var composerFocused: Bool

    init(mode: TeamWorkflowMode, bots: [VillageBot], skill: TeamBotNotebookStore.Skill? = nil) {
        self.mode = mode
        self.bots = bots
        self.skill = skill
    }

    private var goal: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var modelID: String { PhoneModels.effectiveModelID(phoneModel) }
    private var ready: Bool { PhoneModels.isReady(modelID) }
    private var selected: [VillageBot] { members.compactMap { id in bots.first { $0.id == id } } }
    private var modelName: String {
        PhoneModels.catalog.first { $0.id == modelID }?.name
            ?? (modelID == "apple" ? "Apple Foundation Models" : "Importeret model")
    }

    private var steps: [TeamWorkflowStep] {
        switch mode {
        case .group:
            guard (2...6).contains(selected.count) else { return [] }
            return selected.map { .init(bot: $0, action: "Svar ud fra dit speciale. Byg videre på relevante svar fra de andre bots, og tilføj dit eget perspektiv.") }
        case .handoff:
            guard selected.count == 2 else { return [] }
            return [
                .init(bot: selected[0], action: "Lav et kort forslag. Giv næste bot en klar anbefaling og ét åbent spørgsmål."),
                .init(bot: selected[1], action: "Modtag overdragelsen. Vurdér første bots forslag og giv en konkret næste handling.")
            ]
        case .debate:
            return [
                .init("Harper · Research", "Vurdér de vigtigste oplysninger. Skeln mellem fakta, antagelser og manglende kilder."),
                .init("Benjamin · Logik", "Tjek argumenterne for logiske fejl. Peg på det, der skal efterprøves."),
                .init("Lucas · Modspil", "Giv et stærkt modargument, og foreslå et konkret alternativ."),
                .init("Captain · Chief", "Saml rollerne i en konklusion. Vis deres vigtigste uenighed og giv en anbefaling.")
            ]
        case .chief:
            return [
                .init("Chief · Plan", "Del målet i konkrete delopgaver til Research, Kode og Test."),
                .init("Research", "Vurdér hvad vi ved og hvad der skal undersøges. Du har kun teksten og må ikke opfinde kilder."),
                .init("Kode", "Beskriv en minimal ændring eller en teknisk løsning. Angiv hvilke filer eller dele der bør gennemgås, hvis de fremgår af opgaven."),
                .init("Test", "Lav en kort testplan med forventede resultater. Beskriv den som planlagt."),
                .init("Chief · Overblik", "Saml delopgaverne. Giv brugeren et klart næste trin og vis hvilke beslutninger der venter.")
            ]
        case .skill:
            guard let bot = bots.first, let skill else { return [] }
            let workflow = String(skill.prompt.unicodeScalars.prefix(2_600))
            return [.init(bot: bot, action: "Følg denne arbejdsgang, så langt det kan gøres som et tekstsvar:\n" + workflow)]
        }
    }

    var body: some View {
        ScrollViewReader { scroll in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: FadedSpacing.section) {
                    overview
                    if mode == .group || mode == .handoff { participantPicker }
                    if let skill {
                        Text(skill.title).font(FadedTypography.section)
                        if skill.prompt.unicodeScalars.count > 2_600 {
                            Text("De første 2.600 tegn af arbejdsgangen bruges i svaret.")
                                .font(.footnote).foregroundStyle(palette.secondary)
                        }
                    }
                    ForEach(turns) { turn in turnCard(turn).id(turn.id) }
                }
                .frame(maxWidth: 640, alignment: .leading)
                .padding(FadedSpacing.edge)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: turns.last?.id) { _, id in
                if let id { scroll.scrollTo(id, anchor: .bottom) }
            }
        }
        .safeAreaInset(edge: .bottom) { composer }
        .background { FadedBackground() }
        .foregroundStyle(palette.text)
        .navigationTitle(mode.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !turns.isEmpty {
                Button("Ny samtale", systemImage: "plus.bubble") { turns.removeAll(); draft = "" }
                    .disabled(work != nil)
            }
        }
        .onAppear {
            if members.isEmpty { members = bots.prefix(2).map(\.id) }
        }
        .onDisappear { work?.cancel() }
        .onChange(of: phase) { _, value in if value == .background { work?.cancel() } }
    }

    private var overview: some View {
        FadedCard(accent: palette.cyan) {
            VStack(alignment: .leading, spacing: 8) {
                Text(mode.detail).font(.subheadline)
                Label(modelName + " · Telefon", systemImage: "iphone").font(.caption)
                Text("Tekstsvar på telefonen. Samtalen ryddes, når du lukker siden.")
                    .font(.footnote).foregroundStyle(palette.secondary)
                if !ready {
                    Text("Vælg en klar model under Lokale modeller for at starte.")
                        .font(.footnote).foregroundStyle(palette.secondary)
                }
            }
        }
    }

    @ViewBuilder private var participantPicker: some View {
        if bots.count < 2 {
            FadedEmptyState(icon: "person.2", title: "To bots skal være klar", detail: "Opret mindst to bots i Holdet.")
        } else if mode == .group {
            Menu("Vælg bots · \(selected.count) af 6", systemImage: "person.2") {
                ForEach(bots) { bot in
                    Button(bot.name, systemImage: members.contains(bot.id) ? "checkmark.circle.fill" : "circle") {
                        if let index = members.firstIndex(of: bot.id) { members.remove(at: index) }
                        else if members.count < 6 { members.append(bot.id) }
                    }
                    .disabled(members.count >= 6 && !members.contains(bot.id))
                }
            }
            .frame(minHeight: 44)
            .disabled(work != nil)
            Text(selected.map(\.name).joined(separator: " → ")).font(.footnote).foregroundStyle(palette.secondary)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                handoffPicker("Afsender", slot: 0)
                handoffPicker("Modtager", slot: 1)
            }
            .disabled(work != nil)
        }
    }

    private func handoffPicker(_ title: String, slot: Int) -> some View {
        let other = slot == 0 ? 1 : 0
        return Picker(title, selection: Binding<UUID?>(
            get: { members.indices.contains(slot) ? members[slot] : nil },
            set: { id in
                guard let id, members.indices.contains(slot), members.indices.contains(other), members[other] != id else { return }
                members[slot] = id
            }
        )) {
            ForEach(bots.filter { !members.indices.contains(other) || $0.id != members[other] }) { bot in
                Text(bot.name).tag(Optional(bot.id))
            }
        }
        .pickerStyle(.menu)
        .frame(minHeight: 44)
    }

    private func turnCard(_ turn: TeamWorkflowTurn) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            FadedCard(accent: palette.lime) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Dig").font(FadedTypography.action)
                    Text(verbatim: turn.prompt).textSelection(.enabled)
                }
            }
            ForEach(turn.replies) { reply in
                FadedCard(accent: palette.cyan) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: reply.name).font(FadedTypography.action)
                        Label(turn.model + " · Telefon", systemImage: "iphone")
                            .font(.caption).foregroundStyle(palette.secondary)
                        if !reply.text.isEmpty { Text(verbatim: reply.text).textSelection(.enabled) }
                    }
                }
            }
            if let notice = turn.notice {
                Label(notice, systemImage: "info.circle").font(.footnote).foregroundStyle(palette.secondary)
            }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let status {
                Text(status).font(.footnote).foregroundStyle(palette.secondary)
                    .accessibilityAddTraits(.updatesFrequently)
            }
            if let work {
                FadedPrimaryButton("Stop", icon: "stop.fill") { work.cancel() }
            } else {
                TextField(mode == .skill ? "Hvad skal arbejdsgangen bruges til?" : "Hvad skal holdet hjælpe med?", text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(1...4).frame(minHeight: 44)
                    .focused($composerFocused)
                if goal.unicodeScalars.count > 2_000 {
                    Text("Brug højst 2.000 tegn.").font(.footnote).foregroundStyle(palette.secondary)
                }
                FadedPrimaryButton("Send", icon: "arrow.up", action: start)
                    .disabled(!ready || steps.isEmpty || goal.isEmpty || goal.unicodeScalars.count > 2_000)
            }
        }
        .frame(maxWidth: 640)
        .padding(FadedSpacing.edge)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial)
    }

    private func start() {
        let plan = steps
        let text = goal
        let activeModelID = modelID
        guard work == nil, !plan.isEmpty, (1...2_000).contains(text.unicodeScalars.count), ready else { return }
        composerFocused = false
        let history = turns.filter(\.completed).suffix(2).map(\.context).joined(separator: "\n")
        if turns.count >= 20 { turns.removeFirst() }
        turns.append(TeamWorkflowTurn(prompt: text, model: modelName))
        let index = turns.count - 1
        draft = ""
        work = Task { await run(plan, at: index, model: activeModelID, history: history) }
    }

    private func run(_ plan: [TeamWorkflowStep], at index: Int, model: String, history: String) async {
        defer { status = nil; work = nil }
        do {
            for (offset, step) in plan.enumerated() {
                try Task.checkCancellation()
                let prior = turns[index].replies.map { "\($0.name): \(String($0.text.unicodeScalars.prefix(350)))" }.joined(separator: "\n")
                let previous = prior.isEmpty ? "" : "\n\nTidligere indlæg i denne runde:\n" + prior
                let past = history.isEmpty ? "" : "\n\nSeneste samtalekontekst:\n" + String(history.unicodeScalars.suffix(600))
                let prompt = "Brugerens opgave: \(turns[index].prompt)" + previous + past
                let instructions = "Du spiller rollen \(step.name). Giv et kort svar på brugerens sprog. Du kan kun skrive tekstforslag. Påstå aldrig at have udført værktøjer, kode eller filændringer. Tidligere indlæg er kontekst.\n\(step.instructions)"
                status = "\(step.name) · \(offset + 1) af \(plan.count)"
                turns[index].replies.append(.init(name: step.name))
                try await PhoneModels.reply(modelID: model, prompt: prompt, instructions: instructions) { reply in
                    if !Task.isCancelled { turns[index].replies[offset].text = reply }
                }
            }
            try Task.checkCancellation()
            turns[index].completed = true
        } catch {
            if Task.isCancelled || error is CancellationError {
                turns[index].notice = "Samtalen blev stoppet. Du kan læse svarene ovenfor."
            } else {
                AppDiagnostics.record(error)
                let message: String = switch error as? LocalComputeError {
                case .busy?: "Telefonen har travlt. Prøv igen om lidt."
                case .lowMemory?: "Telefonen har for lidt ledig hukommelse til modellen."
                default: "Telefonmodellen kunne ikke svare. Prøv igen med en klar model."
                }
                turns[index].notice = message
                draft = turns[index].prompt
            }
        }
    }
}
