import Gepetto
import SwiftUI

/// Reuses FadedAI's existing local model and its memory/cancellation gate.
final class FadedBrowserEngine: GepettoAIEngine, @unchecked Sendable {
    let modelID: String
    init(modelID: String) { self.modelID = modelID }
    func stream(messages: [GepettoMessage], systemPrompt: String?) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let operation = Task { @MainActor in
                do {
                    let prompt = messages.map { "\($0.role.rawValue): \($0.content)" }.joined(separator: "\n\n")
                    guard prompt.utf8.count + (systemPrompt?.utf8.count ?? 0) <= 10_000 else { throw BrowserWork.Failure.context }
                    var answer = ""
                    try await PhoneModels.reply(modelID: modelID, prompt: prompt,
                        instructions: BrowserWork.modelInstructions + (systemPrompt.map { "\n" + $0 } ?? "")) { answer = $0 }
                    try Task.checkCancellation()
                    continuation.yield(answer); continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in operation.cancel() }
        }
    }
}

@MainActor struct AgentBrowserView: View {
    let bot: VillageBot
    let model: String
    var initialTask = ""
    var onResult: (String) -> Void = { _ in }
    @StateObject private var agent: BrowserAgent
    @State private var taskText = ""
    @State private var humanNote = ""
    @State private var chosenModel = "apple"
    @State private var record = BrowserWork.Record()
    @State private var busy = false
    @State private var saved = false
    @State private var showModels = false
    @State private var operation: Task<Void, Never>?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    init(bot: VillageBot, model: String, initialTask: String = "", onResult: @escaping (String) -> Void = { _ in }) {
        self.bot = bot; self.model = model; self.initialTask = initialTask; self.onResult = onResult
        var options = ObservationOptions(); options.maxElements = 14; options.maxTextChars = 750
        var configuration = BrowserAgentConfiguration(maxIterations: 18, visualPaceMs: 350, observation: options, historyWindow: 3)
        configuration.accentCSSColor = "#37DDBB"; configuration.autoDismissConsent = false
        configuration.useScriptedFlowForMultiURLTasks = false
        _agent = StateObject(wrappedValue: BrowserAgent(configuration: configuration))
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("\(bot.name) arbejder på nettet").font(.title2.bold())
                    Text("Browseren bruger telefonens internet. Modellen og arbejdet kører på din iPhone. Du kan tage over på siden undervejs.").font(.subheadline).foregroundStyle(.secondary)
                    FadedCard {
                        VStack(alignment: .leading, spacing: 10) {
                            TextField("Fx: Brug browseren til at finde åbningstider på…", text: $taskText, axis: .vertical).lineLimit(2...5).disabled(busy)
                                .onChange(of: taskText) { _, text in if text.count > 2_000 { taskText = String(text.prefix(2_000)) } }
                            Button(PhoneModels.textModelName(chosenModel), systemImage: "iphone") { showModels = true }.frame(minHeight: 44).disabled(busy)
                            FadedPrimaryButton("Start opgaven", icon: "globe") { start() }.disabled(busy || taskText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !PhoneModels.isReady(chosenModel))
                            if !PhoneModels.isReady(chosenModel) { Text("Vælg eller hent en telefonmodel for at starte.").font(.caption) }
                        }
                    }
                    if let engine = agent.executor?.engine {
                        if let url = BrowserWork.sourceURL(agent.currentURL) { Link(url.host ?? "Åbn siden", destination: url).font(.caption).lineLimit(1) }
                        BrowserView(engine: engine, showNavBar: false).frame(height: 440).clipShape(.rect(cornerRadius: 18))
                    }
                    controls
                    if !agent.steps.isEmpty {
                        DisclosureGroup("Udførte trin · \(agent.steps.count)") {
                            ForEach(agent.steps) { step in
                                Label(step.label, systemImage: step.succeeded ? "checkmark.circle" : "exclamationmark.circle")
                                    .font(.footnote).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
                            }
                        }
                    }
                    if !record.answer.isEmpty || record.failure != nil {
                        FadedCard {
                            VStack(alignment: .leading, spacing: 12) {
                                Text(record.receipt).textSelection(.enabled)
                                if !record.answer.isEmpty {
                                    Button(saved ? "Gemt i chatten" : "Gem resultat i chatten", systemImage: "checkmark.bubble") { onResult(record.receipt); saved = true }.frame(minHeight: 44).disabled(busy || saved)
                                }
                            }
                        }
                    }
                }.padding()
            }.background { FadedBackground() }.navigationTitle("Agentbrowser").navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("Luk") { stop(); agent.shutdown(); dismiss() } }
                .onAppear { if taskText.isEmpty { taskText = initialTask; chosenModel = model }; agent.start() }
                .sheet(isPresented: $showModels, onDismiss: { chosenModel = UserDefaults.standard.string(forKey: PhoneModels.selectionKey) ?? chosenModel }) { PhoneModelsView() }
                .onChange(of: phase) { _, next in if next != .active { agent.pause() } }
                .onDisappear { stop(); agent.shutdown() }
        }
    }
    @ViewBuilder private var controls: some View {
        switch agent.controlState {
        case .running:
            HStack { Button("Pause", systemImage: "pause") { agent.pause() }; Button("Jeg tager over", systemImage: "hand.raised") { agent.takeOver() }; Button("Stop", systemImage: "stop") { stop() } }.frame(minHeight: 44)
        case .paused:
            HStack { Button("Fortsæt", systemImage: "play") { agent.resume() }; Button("Jeg tager over") { agent.takeOver() }; Button("Stop") { stop() } }.frame(minHeight: 44)
        case .waitingForUser(let request):
            FadedCard {
                VStack(alignment: .leading, spacing: 12) {
                    switch request {
                    case .takeover:
                        Text("Du styrer siden nu. Log ind eller gør det nødvendige, og giv derefter opgaven tilbage.")
                        TextField("En besked til agenten (valgfri)", text: $humanNote)
                        Button("Giv tilbage til \(bot.name)") { agent.handBack(note: String(humanNote.prefix(500))); humanNote = "" }.frame(minHeight: 44)
                    case .confirm(_, let summary, _):
                        Text(summary); HStack { Button("Udfør handlingen") { agent.respond(allow: true) }; Button("Afvis") { agent.respond(allow: false) } }.frame(minHeight: 44)
                    case .question(let question):
                        Text(question); TextField("Dit svar", text: $humanNote)
                        Button("Svar") { agent.answer(String(humanNote.prefix(1_000))); humanNote = "" }.frame(minHeight: 44).disabled(humanNote.isEmpty)
                    }
                    Button("Stop opgaven") { stop() }.frame(minHeight: 44)
                }
            }
        default: if busy { ProgressView("Kontrollerer resultatet på siden…") }
        }
    }
    private func stop() { agent.stop(); operation?.cancel() }
    private func start() {
        guard !busy else { return }; busy = true; saved = false; record = .init()
        let request = taskText, selected = chosenModel
        operation = Task {
            defer { busy = false }
            await agent.run(task: request, engine: FadedBrowserEngine(modelID: selected)) { event in
                switch event {
                case .complete(let answer): record.answer = String(answer.prefix(8_000))
                case .failed(let reason, let partial): record.failure = reason; record.answer = String(partial.prefix(8_000))
                default: break
                }
            }
            guard !Task.isCancelled, record.failure == nil, !record.answer.isEmpty else { return }
            do {
                guard let browser = agent.executor?.engine else { throw BrowserWork.Failure.proof }
                let text = try await browser.extractText(); try Task.checkCancellation()
                record.observed = String(text.prefix(4_500)); record.source = BrowserWork.sourceURL(agent.currentURL)
                guard record.source != nil else { throw BrowserWork.Failure.proof }
                var proof = ""
                try await PhoneModels.reply(modelID: selected, prompt: BrowserWork.verification(task: request, answer: record.answer, observed: record.observed), instructions: "Svar kun med JSON. Kontroller resultatet; udfør intet.") { proof = $0 }
                try Task.checkCancellation(); record.proof = try BrowserWork.Proof.decode(proof, observed: record.observed)
            } catch { if !Task.isCancelled { record.failure = error.localizedDescription } }
        }
    }
}
