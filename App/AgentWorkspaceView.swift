import SwiftUI
import UniformTypeIdentifiers

@MainActor struct AgentWorkspaceView: View {
    let bot: VillageBot
    let api: LiveAPI?
    let model: String
    var initialKind: AgentWorkspace.Kind?
    var initialPrompt = ""
    var useFile: (AgentDocument) -> Void
    @StateObject private var runner: AgentWorkspaceRunner
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var phase
    @State private var prompt = ""
    @State private var kind = AgentWorkspace.Kind.document
    @State private var inputFileID: UUID?
    @State private var importing = false
    @State private var shortcutName = ""
    @State private var shortcutPurpose = ""
    @State private var shortcutInput = ""
    @State private var pendingShortcut: AgentWorkspace.Shortcut?
    @State private var started = false

    init(bot: VillageBot, api: LiveAPI?, model: String, initialKind: AgentWorkspace.Kind? = nil,
         initialPrompt: String = "", useFile: @escaping (AgentDocument) -> Void) {
        self.bot = bot; self.api = api; self.model = model
        self.initialKind = initialKind; self.initialPrompt = initialPrompt; self.useFile = useFile
        _runner = StateObject(wrappedValue: AgentWorkspaceRunner(botID: bot.id))
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label("\(bot.name)s arbejdsrum", systemImage: "laptopcomputer.and.iphone").font(.title3.bold())
                    Text("Egne filer, genveje og opgaver på din iPhone. Dokumenter kan laves offline med din hentede chatmodel. Web og mail bruger internet.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                if let notice = runner.notice { Section { Text(notice).foregroundStyle(.orange) } }
                Section("Ny opgave") {
                    NavigationLink { AgentLocalCodeView(bot: bot, model: model) } label: { Label("Lav eller kør et lokalt værktøj", systemImage: "curlybraces") }
                    Picker("Arbejd med", selection: $kind) {
                        Text("Skriv dokument · iPhone").tag(AgentWorkspace.Kind.document)
                        Text("Undersøg og gem · internet").tag(AgentWorkspace.Kind.research)
                        Text("Udfør på PC").tag(AgentWorkspace.Kind.computer)
                    }
                    if kind != .research && !runner.snapshot.files.isEmpty {
                        Picker("Brug fil", selection: $inputFileID) {
                            Text("Ingen fil").tag(Optional<UUID>.none)
                            ForEach(runner.snapshot.files) { file in Text(file.name).tag(Optional(file.id)) }
                        }
                        if kind == .computer && inputFileID != nil {
                            Text("Den valgte fils tekst sendes til din parrede PC sammen med opgaven.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    TextField("Hvad skal \(bot.name) lave?", text: $prompt, axis: .vertical).lineLimit(2...6)
                    Button("Start opgaven", systemImage: "play.fill") { start() }
                        .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || prompt.count > 1_200 || runner.active != nil)
                    Text("Du kan også skrive ‘lav et dokument: …’ eller ‘undersøg og gem: …’ i chatten.").font(.caption).foregroundStyle(.secondary)
                }
                jobs
                Section("Filer · \(runner.snapshot.files.count)") {
                    Button("Importér dokument", systemImage: "square.and.arrow.down") { importing = true }
                    Button("Ny tom note", systemImage: "square.and.pencil") {
                        runner.change { _ = try runner.storage.addFile(name: "Ny note", text: "") }
                    }
                    ForEach(runner.snapshot.files.reversed()) { file in
                        NavigationLink {
                            AgentWorkspaceFileView(file: file, storage: runner.storage) { updated in
                                useFile(AgentDocument(id: updated.id, name: updated.name, model: nil,
                                    passages: [.init(page: nil, text: updated.text, vector: nil)]))
                                dismiss()
                            }
                        } label: { Label(file.name, systemImage: "doc.text") }
                        .swipeActions { Button("Slet", role: .destructive) {
                            runner.change { try runner.storage.edit { $0.files.removeAll { $0.id == file.id } } }
                        } }
                    }
                }
                shortcuts
            }
            .scrollContentBackground(.hidden)
            .background { FadedBackground() }
            .tint(.mint)
            .navigationTitle("Arbejdsrum")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Luk") { dismiss() } } }
            .fileImporter(isPresented: $importing, allowedContentTypes: AgentDocumentIndex.localTypes) { result in
                do {
                    let url = try result.get()
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    let document = try AgentDocumentIndex.ingest(url)
                    runner.change { _ = try runner.storage.addFile(name: document.name,
                        text: document.passages.map(\.text).joined(separator: "\n\n")) }
                } catch { runner.notice = error.localizedDescription }
            }
            .task {
                if !started {
                    started = true
                    prompt = initialPrompt
                    if let initialKind, initialKind != .shortcut {
                        kind = initialKind
                        if !prompt.isEmpty { start() }
                    }
                    if initialKind == .shortcut {
                        let pieces = initialPrompt.components(separatedBy: " | ")
                        shortcutInput = pieces.dropFirst().joined(separator: " | ")
                        pendingShortcut = runner.snapshot.shortcuts.first { $0.name.localizedCaseInsensitiveCompare(pieces[0]) == .orderedSame }
                        if pendingShortcut == nil { runner.notice = "Tilføj genvejen nedenfor med præcis samme navn som i Apples Genveje." }
                        prompt = ""
                    }
                }
            }
            .task(id: phase) { if phase == .active { await runner.poll(bot: bot, api: api, model: model) } }
            .onChange(of: phase) { _, value in if value != .active { runner.pause() } }
            .onReceive(NotificationCenter.default.publisher(for: AgentShortcutBridge.changed)) { _ in runner.refresh() }
            .onAppear { runner.refresh() }
            .onDisappear { runner.pause() }
            .confirmationDialog("Kør genvejen?", isPresented: Binding(get: { pendingShortcut != nil }, set: { if !$0 { pendingShortcut = nil } }), titleVisibility: .visible) {
                if let shortcut = pendingShortcut {
                    Button("Kør \(shortcut.name)") { launch(shortcut) }
                    Button("Annuller", role: .cancel) { pendingShortcut = nil }
                }
            } message: {
                Text("Apples Genveje åbner og udfører den valgte genvej. Input: \(shortcutInput.isEmpty ? "Intet" : shortcutInput)")
            }
        }
    }

    private var jobs: some View {
        Section("Opgaver") {
            if runner.snapshot.jobs.isEmpty { Text("Dine opgaver og resultater bliver samlet her.").foregroundStyle(.secondary) }
            ForEach(runner.snapshot.jobs.reversed()) { job in
                DisclosureGroup {
                    NavigationLink("Gennemgå kilder, status og resultat") {
                        AgentWorkReviewView(bot: bot, model: model, storage: runner.storage, jobID: job.id, resume: { id in runner.run(id, bot: bot, api: api, model: model) })
                    }
                    Text(job.result.isEmpty ? "Opgaven er gemt." : job.result).textSelection(.enabled)
                    if runner.active == job.id { Button("Pause", systemImage: "pause") { runner.pause() } }
                    else if job.kind != .shortcut, job.kind != .localCode, job.state != .completed, job.state != .cancelled {
                        Button(job.submitted ? "Kontrollér på PC" : "Fortsæt", systemImage: "arrow.clockwise") {
                            runner.run(job.id, bot: bot, api: api, model: model)
                        }.disabled(runner.active != nil)
                    }
                    if job.kind == .shortcut && job.state == .checking {
                        Text("Intet svar fra Genveje endnu. Kontrollér appen, før du starter genvejen igen.").font(.caption)
                    }
                    if job.kind == .localCode, let code = job.localCode {
                        NavigationLink("Åbn det lokale værktøj") {
                            AgentLocalCodeView(bot: bot, model: model, initialRecipe: .init(name: String(job.prompt.dropFirst("Lokal kode: ".count)), code: code), initialInput: job.localInput, initialJob: job.id)
                        }
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(job.prompt).lineLimit(2)
                        Text(job.state.title).font(.caption).foregroundStyle(job.state == .completed ? .green : .secondary)
                    }.padding(.vertical, 4)
                }
                .swipeActions { if runner.active != job.id && job.state != .checking {
                    Button("Slet", role: .destructive) { runner.change { try runner.storage.edit { $0.jobs.removeAll { $0.id == job.id } } } }
                } }
            }
        }
    }

    private var shortcuts: some View {
        Section("Mine Apple-genveje") {
            Text("Tilføj genveje, du allerede har i Apples Genveje. De kan bruge de apps og tilladelser, du har sat op dér.").font(.caption).foregroundStyle(.secondary)
            TextField("Genvejens præcise navn", text: $shortcutName)
            TextField("Hvad gør den?", text: $shortcutPurpose)
            Button("Tilføj genvej", systemImage: "plus") {
                runner.change {
                    let name = shortcutName.trimmingCharacters(in: .whitespacesAndNewlines)
                    try runner.storage.edit {
                        guard !$0.shortcuts.contains(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) else { throw AgentWorkspace.Failure.invalid }
                        $0.shortcuts.append(.init(id: UUID(), name: name, purpose: String(shortcutPurpose.prefix(240))))
                    }
                    shortcutName = ""; shortcutPurpose = ""
                }
            }.disabled(shortcutName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || shortcutName.count > 120)
            TextField("Tekst til genvejen (valgfrit)", text: $shortcutInput, axis: .vertical).lineLimit(1...4)
            ForEach(runner.snapshot.shortcuts) { shortcut in
                Button { pendingShortcut = shortcut } label: {
                    VStack(alignment: .leading) { Label(shortcut.name, systemImage: "square.stack.3d.up"); Text(shortcut.purpose).font(.caption).foregroundStyle(.secondary) }
                }.disabled(shortcutInput.count > 4_000)
                .swipeActions { Button("Slet", role: .destructive) {
                    runner.change { try runner.storage.edit { $0.shortcuts.removeAll { $0.id == shortcut.id } } }
                } }
            }
            Text("Fra chatten: ‘kør genvej: Navn | tekst’. Du ser handlingen, før den starter.").font(.caption).foregroundStyle(.secondary)
        }
    }
    private func start() {
        runner.change {
            let job = try runner.storage.enqueue(prompt, kind: kind, pcID: kind == .computer ? api?.queueTargetID : nil,
                inputFileID: kind == .research ? nil : inputFileID)
            runner.refresh()
            runner.run(job.id, bot: bot, api: api, model: model)
            prompt = ""
            inputFileID = nil
        }
    }
    private func launch(_ shortcut: AgentWorkspace.Shortcut) {
        pendingShortcut = nil
        runner.change {
            let job = try runner.storage.enqueue("Kør \(shortcut.name)", kind: .shortcut, shortcut: shortcut, input: shortcutInput)
            guard let url = AgentShortcutBridge.launchURL(job: job, botID: bot.id) else { throw AgentWorkspace.Failure.invalid }
            try runner.storage.update(job.id) { $0.state = .checking; $0.submitted = true; $0.result = "Afventer svar fra Genveje." }
            openURL(url) { accepted in
                if !accepted { runner.change { try runner.storage.update(job.id) { $0.state = .failed; $0.result = "Apples Genveje kunne ikke åbnes."; $0.callbackToken = nil } } }
            }
        }
    }
}

@MainActor struct AgentWorkspaceFileView: View {
    let file: AgentWorkspace.File
    let storage: AgentWorkspace
    var use: ((AgentWorkspace.File) -> Void)? = nil
    @State private var text = ""
    @State private var previous: String?
    @State private var notice: String?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                TextField("Indhold", text: $text, axis: .vertical).lineLimit(10...35).textFieldStyle(.roundedBorder)
                if let notice { Text(notice).foregroundStyle(.secondary) }
                HStack {
                    Button("Gem", systemImage: "checkmark") { save() }
                    ShareLink(item: text) { Label("Del", systemImage: "square.and.arrow.up") }
                    if let use { Button("Brug i chat", systemImage: "bubble.left") { if let saved = save() { use(saved) } } }
                }.buttonStyle(.bordered).frame(minHeight: 44)
                if let previous {
                    Button("Hent forrige version", systemImage: "arrow.uturn.backward") { text = previous; notice = "Forrige version er indsat. Tryk Gem for at beholde den." }
                }
            }.padding()
        }
        .background { FadedBackground() }
        .navigationTitle(file.name)
        .onAppear { text = file.text; previous = file.previous.last }
    }
    @discardableResult private func save() -> AgentWorkspace.File? {
        do {
            try storage.revise(file.id, text: text)
            let saved = try storage.load().files.first { $0.id == file.id }
            previous = saved?.previous.last
            notice = "Gemt på iPhone."
            return saved
        }
        catch { notice = error.localizedDescription; return nil }
    }
}
