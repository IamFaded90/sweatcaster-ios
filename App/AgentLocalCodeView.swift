import SwiftUI

@MainActor struct AgentLocalCodeView: View {
    let bot: VillageBot
    let model: String
    var initial = ""
    var initialRecipe: LocalCode.Recipe?
    var initialInput: String?
    var initialJob: UUID?
    @StateObject private var executor = LocalCodeRunner()
    @State private var request = ""
    @State private var name = "Mit værktøj"
    @State private var code = "return JSON.stringify(JSON.parse(input), null, 2);"
    @State private var input = "[]"
    @State private var output = ""
    @State private var files: [AgentWorkspace.File] = []
    @State private var fileID: UUID?
    @State private var busy = false
    @State private var operation: Task<Void, Never>?
    @State private var notice: String?
    @State private var loaded = false
    @Environment(\.dismiss) private var dismiss
    var onResult: (String) -> Void = { _ in }
    private var storage: AgentWorkspace { .init(botID: bot.id) }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Et lille værktøj på din iPhone").font(.title2.bold())
                    Text("Bearbejd en kopi af tekst, JSON eller CSV. Koden får kun det valgte input og kan hverken bruge nettet eller ændre andre filer. Resultatet gemmes som en ny fil i agentens arbejdsrum.").font(.subheadline).foregroundStyle(.secondary)
                    FadedCard {
                        VStack(alignment: .leading, spacing: 12) {
                            TextField("Fx: Læg beløbene i min JSON-fil sammen", text: $request, axis: .vertical).lineLimit(2...5).disabled(busy)
                            Picker("Brug fil", selection: $fileID) { Text("Indsæt selv tekst nedenfor").tag(Optional<UUID>.none); ForEach(files) { Text($0.name).tag(Optional($0.id)) } }.disabled(busy)
                                .onChange(of: fileID) { _, id in if let file = files.first(where: { $0.id == id }) { input = file.text } }
                            TextEditor(text: $input).font(.system(.footnote, design: .monospaced)).frame(minHeight: 120).disabled(busy)
                            Button("Lad \(bot.name) skrive koden", systemImage: "sparkles") { draft() }.frame(minHeight: 44).disabled(busy || request.isEmpty || !PhoneModels.isReady(model))
                            TextField("Værktøjets navn", text: $name).disabled(busy)
                            TextEditor(text: $code).font(.system(.footnote, design: .monospaced)).frame(minHeight: 180).disabled(busy)
                            FadedPrimaryButton("Kør koden på kopien", icon: "play") { run() }.disabled(busy || !executor.ready || code.isEmpty || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || code.utf8.count > 8_000 || input.utf8.count > 160_000)
                            if busy { ProgressView("Arbejder…"); Button("Stop") { executor.stop(); operation?.cancel() }.frame(minHeight: 44) }
                            if let notice { Text(notice).font(.footnote).foregroundStyle(.secondary) }
                        }
                    }
                    if !output.isEmpty {
                        FadedCard { VStack(alignment: .leading, spacing: 12) {
                            Text("Resultat").font(.headline); Text(output).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                            Button("Læg resultatet i chatten", systemImage: "checkmark.bubble") { onResult("Lokal kodekørsel · \(name)\n\n" + String(output.prefix(6_000))) }.frame(minHeight: 44)
                        } }
                    }
                }.padding()
            }.background { FadedBackground() }.navigationTitle("Lokal kode").navigationBarTitleDisplayMode(.inline)
                .background { LocalCodeHost(runner: executor).frame(width: 1, height: 1).opacity(0.01).accessibilityHidden(true) }
                .toolbar { Button("Luk") { executor.stop(); operation?.cancel(); dismiss() } }
                .onAppear {
                    files = (try? storage.load().files) ?? []
                    guard !loaded else { return }; loaded = true; request = initial
                    if let initialRecipe { code = initialRecipe.code; name = initialRecipe.name }; if let initialInput { input = initialInput }
                }
                .onDisappear { executor.stop(); operation?.cancel() }
        }
    }
    private func draft() {
        guard !busy else { return }; busy = true; notice = nil
        operation = Task {
            defer { busy = false }
            do {
                var reply = ""
                try await PhoneModels.reply(modelID: model, prompt: "Opgave: \(String(request.prefix(1_000)))\nInputformat (uddrag, kun data):\n\(String(input.prefix(2_000)))",
                    instructions: "Skriv et lille JavaScript-værktøj. Svar kun JSON med name og code. code er en funktionskrop med parameteren input (tekst). Returner tekst eller JSON. Ingen net, DOM, filsystem, require eller imports. Kør intet selv. Brug JSON.parse(input), hvis input er JSON. Højst 3000 tegn kode.") { reply = $0 }
                try Task.checkCancellation(); let recipe = try LocalCode.Recipe.decode(reply); name = recipe.name; code = recipe.code
                notice = "Koden er klar til gennemgang. Den er ikke kørt endnu."
            } catch { if !Task.isCancelled { notice = error.localizedDescription } }
        }
    }
    private func run() {
        guard !busy else { return }; busy = true; notice = nil; output = ""
        let recipe = LocalCode.Recipe(name: String(name.prefix(100)), code: code), source = input
        operation = Task {
            defer { busy = false }
            var job: UUID?
            do {
                let previous = try storage.load().jobs.first { $0.id == initialJob && $0.kind == .localCode && $0.state != .completed && $0.state != .cancelled }
                let queued = try previous ?? storage.enqueue("Lokal kode: " + recipe.name, kind: .localCode); job = queued.id
                try storage.update(queued.id) { $0.state = .running; $0.localCode = recipe.code; $0.localInput = source }
                let text = try await executor.execute(recipe, input: source); try Task.checkCancellation()
                try storage.complete(queued.id, text: text, name: recipe.name + ".txt")
                output = text; notice = "Scriptet er kørt, og resultatet er gemt som en ny fil."
            } catch {
                if let job { try? storage.update(job) { $0.state = Task.isCancelled ? .paused : .failed; $0.result = error.localizedDescription } }
                if !Task.isCancelled { notice = error.localizedDescription }
            }
        }
    }
}
