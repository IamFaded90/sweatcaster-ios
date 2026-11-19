import SwiftUI
import UniformTypeIdentifiers

@MainActor struct AgentRepairFlow: View {
    let api: LiveAPI?
    var initialReport = ""
    var onResult: (String) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss
    @State private var catalog: AgentRepairData.Catalog?
    @State private var job: AgentRepairData.Job?
    @State private var project = ""
    @State private var selected = Set<String>()
    @State private var sourceSearch = ""
    @State private var profile = "auto"
    @State private var report = ""
    @State private var busy = false
    @State private var importing = false
    @State private var notice: String?
    @State private var operation: Task<Void, Never>?
    @State private var bundleURL: URL?
    @State private var delivered = Set<String>()
    @State private var confirmApproval = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    FadedCard {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("Fejl → bevis → rettelse", systemImage: "hammer.circle").font(.title2.bold())
                            Text("Agenten gentager først fejlen i en separat kopi. Du ser den faktiske kontrol og godkender ændringen, før den får sin egen lokale gren.")
                        }
                    }
                    if api == nil {
                        ContentUnavailableView("Forbind din PC", systemImage: "desktopcomputer",
                            description: Text("Åbn FadedAI på PC’en for at undersøge kode og gemme reparationsopgaver."))
                    }
                    if let catalog {
                        intake(catalog)
                        if let job { details(job) }
                        if !catalog.jobs.isEmpty {
                            Text("Tidligere reparationsopgaver").font(.headline)
                            ForEach(catalog.jobs.filter { $0.id != job?.id }) { previous in
                                Button { open(previous) } label: {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(previous.repository).font(.headline)
                                        Text(previous.stateTitle).font(.subheadline)
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                }.buttonStyle(FadedButtonStyle(kind: .secondary)).disabled(busy)
                            }
                        }
                    }
                    if busy { ProgressView(job?.active == true ? "PC’en arbejder i den separate kopi…" : "Henter fra PC’en…") }
                    if let notice { Text(notice).font(.callout).foregroundStyle(.secondary) }
                    if api != nil {
                        FadedSecondaryButton("Opdatér", icon: "arrow.clockwise") { reload() }.disabled(busy)
                    }
                }.padding(FadedSpacing.edge)
            }.background { FadedBackground() }
                .navigationTitle("Agenten retter fejl").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Luk") { dismiss() } } }
        }
        .task {
            if report.isEmpty { report = initialReport }
            reload()
        }
        .onDisappear { operation?.cancel(); removeBundle() }
        .onChange(of: project) { _, value in
            sourceSearch = ""
            selected = Set(catalog?.projects.first(where: { $0.id == value })?.files.prefix(5).map(\.id) ?? [])
            if report.isEmpty, value == "fadedai/repair-demo" { report = "20 procent rabat på 100 kroner skal give 80 kroner. Nu giver funktionen et forkert beløb." }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.plainText, .json, .data]) { result in importLog(result) }
        .confirmationDialog("Godkend den testede ændring?", isPresented: $confirmApproval, titleVisibility: .visible) {
            Button(job?.state == "reviewOnMac" ? "Godkend forslag til Mac-test" : "Godkend på separat lokal gren") { approve() }
            Button("Annuller", role: .cancel) {}
        } message: {
            Text("Ændringen får sin egen lokale gren. En Apple-bygning og en IPA kræver stadig en Mac.")
        }
    }

    private func intake(_ catalog: AgentRepairData.Catalog) -> some View {
        FadedCard {
            VStack(alignment: .leading, spacing: 14) {
                Picker("Projekt", selection: $project) {
                    ForEach(catalog.projects) { value in Text(value.title).tag(value.id) }
                }.disabled(busy)
                Picker("Kontrol", selection: $profile) {
                    Text("Automatisk").tag("auto")
                    Text("Python-test").tag("python")
                    Text("iPhone / Mac").tag("ios")
                }.disabled(busy)
                Text("Hvad sker der, og hvad skulle der ske?").font(.headline)
                TextEditor(text: $report).frame(minHeight: 140, maxHeight: 230).padding(8).fadedGlassSurface().disabled(busy)
                FadedSecondaryButton("Importér iPhone-log eller byggelog", icon: "doc.badge.plus") { importing = true }.disabled(busy)
                Text("Vælg en .ips-, .log- eller .txt-fil. Mulige adgangsnøgler fjernes på PC’en, før rapporten gemmes.")
                    .font(.footnote).foregroundStyle(.secondary)
                if let current = catalog.projects.first(where: { $0.id == project }) {
                    DisclosureGroup("Kildefiler og tests · \(selected.count) valgt") {
                        TextField("Find fil · fx PhoneModels eller StudioImage", text: $sourceSearch)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().padding(10).fadedGlassSurface()
                        ForEach(current.files.filter { sourceSearch.isEmpty || $0.id.localizedCaseInsensitiveContains(sourceSearch) }) { source in
                            Toggle(isOn: Binding(get: { selected.contains(source.id) }, set: { yes in
                                if yes { selected.insert(source.id) } else { selected.remove(source.id) }
                            })) {
                                Label(source.id, systemImage: source.test ? "checkmark.square" : "doc.text")
                            }.font(.caption).disabled(busy || selected.count >= 5 && !selected.contains(source.id))
                        }
                    }
                }
                Text(catalog.runner.detail).font(.footnote).foregroundStyle(.secondary)
                Text(catalog.detail).font(.footnote).foregroundStyle(.secondary)
                FadedPrimaryButton("Undersøg og ret i en kopi", icon: "hammer") { start() }
                    .disabled(busy || project.isEmpty || report.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || report.count > 48000)
            }
        }
    }

    @ViewBuilder private func details(_ job: AgentRepairData.Job) -> some View {
        FadedCard {
            VStack(alignment: .leading, spacing: 12) {
                Label(job.stateTitle, systemImage: job.state == "review" || job.state == "approved" ? "checkmark.seal" : "wrench.and.screwdriver")
                    .font(.headline)
                Text(job.summary).textSelection(.enabled)
                Text(job.evidence.title).font(.subheadline.bold())
                if let build = job.evidence.build { Text("iPhone-build: " + build).font(.caption) }
                ForEach(Array(job.evidence.lines.enumerated()), id: \.offset) { _, line in
                    Text(line).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                }
                ForEach(Array(job.steps.enumerated()), id: \.offset) { _, step in Text(step).font(.footnote) }
                if let before = job.before { check("Før rettelsen", before) }
                if let after = job.after { check("Efter rettelsen", after) }
                if let diff = job.diff, !diff.isEmpty {
                    DisclosureGroup("Se den præcise ændring") {
                        ScrollView(.horizontal) { Text(diff).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                    }
                }
                Text("Grundrevision: " + job.baseRevision).font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
                if job.state == "review" || job.state == "reviewOnMac" {
                    FadedPrimaryButton(job.state == "reviewOnMac" ? "Godkend forslag til Mac-test" : "Godkend den testede ændring", icon: "checkmark.seal") { confirmApproval = true }.disabled(busy)
                }
                if job.state == "interrupted" {
                    FadedPrimaryButton("Genoptag samme kontrol", icon: "play.circle") { resume(job) }.disabled(busy)
                }
                if let handoff = job.handoff {
                    DisclosureGroup("Opgaven til Mac") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(handoff.detail)
                            ForEach(Array(handoff.steps.enumerated()), id: \.offset) { _, step in Text(step) }
                            Text("Mac-status: " + (handoff.state == "waitingForMac" ? "Afventer bygning og test" : "Rapport modtaget fra Mac"))
                            FadedSecondaryButton("Hent opgaven til Mac", icon: "square.and.arrow.down") { download() }.disabled(busy)
                            if let bundleURL { ShareLink("Del reparationspakken", item: bundleURL) }
                        }.font(.footnote)
                    }
                }
                if job.active { Text("Du kan lukke siden. Arbejdet fortsætter på PC’en; opdatér for at se resultatet.").font(.footnote) }
                else {
                    Button(role: .destructive) { remove(job) } label: { Label("Slet rapport og arbejdskopier", systemImage: "trash") }
                        .disabled(busy)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func check(_ title: String, _ run: AgentRepairData.TestRun) -> some View {
        DisclosureGroup(title + " · " + (run.passed ? "Bestod" : "Fejlede")) {
            VStack(alignment: .leading, spacing: 7) {
                Text("\(run.testsRun) tests · \(run.failures) fejlede checks · \(run.errors) fejl")
                Text(run.command).textSelection(.enabled)
                Text("Testhash: " + run.testDigest).textSelection(.enabled)
                ScrollView(.horizontal) { Text(run.log).font(.system(.caption2, design: .monospaced)).textSelection(.enabled) }
            }.font(.footnote)
        }
    }

    private func reload() {
        guard !busy, let api else { return }
        perform {
            let result: AgentRepairData.Catalog = try await api.moduleJSON("agent-repair", timeout: 35)
            try Task.checkCancellation()
            catalog = result
            if project.isEmpty { project = result.projects.first?.id ?? "" }
            if let current = job { job = result.jobs.first(where: { $0.id == current.id }) }
            else { job = result.jobs.first }
            if let job, job.active { try await watch(job.id) }
        }
    }

    private func start() {
        guard let api else { return }
        perform {
            struct Body: Encodable { let id: String; let report: String; let repository: String; let files: [String]; let profile: String }
            let body = Body(id: UUID().uuidString.lowercased(), report: report, repository: project, files: selected.sorted(), profile: profile)
            job = try await api.moduleJSON("agent-repair/jobs", upload: JSONEncoder().encode(body), timeout: 30)
            try Task.checkCancellation()
            if let job { try await watch(job.id) }
        }
    }

    private func open(_ previous: AgentRepairData.Job) {
        job = previous
        perform { try await watch(previous.id) }
    }

    private func watch(_ id: String) async throws {
        guard let api else { return }
        repeat {
            let fresh: AgentRepairData.Job = try await api.moduleJSON("agent-repair/jobs/" + id, timeout: 20)
            try Task.checkCancellation()
            job = fresh
            if !fresh.active {
                let delivery = id + ":" + fresh.state
                if delivered.insert(delivery).inserted { onResult(fresh.stateTitle + ": " + fresh.summary) }
                return
            }
            try await Task.sleep(for: .seconds(3))
        } while !Task.isCancelled
    }

    private func approve() {
        guard let api, let job else { return }
        perform {
            let fresh: AgentRepairData.Job = try await api.moduleJSON("agent-repair/jobs/" + job.id + "/approve", upload: Data("{}".utf8), timeout: 35)
            try Task.checkCancellation()
            self.job = fresh
            onResult(fresh.stateTitle + ": " + fresh.summary)
        }
    }

    private func resume(_ previous: AgentRepairData.Job) {
        guard let api else { return }
        perform {
            job = try await api.moduleJSON("agent-repair/jobs/" + previous.id + "/resume", upload: Data("{}".utf8), timeout: 30)
            try Task.checkCancellation()
            try await watch(previous.id)
        }
    }

    private func download() {
        guard let api, let job else { return }
        perform {
            let bundle: AgentRepairData.Bundle = try await api.moduleJSON("agent-repair/jobs/" + job.id + "/bundle", timeout: 25, maximumBytes: 1_000_000)
            try Task.checkCancellation()
            guard bundle.data.count <= 700000 else { throw APIError.malformed }
            removeBundle()
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("FadedAI-reparation-" + UUID().uuidString + ".zip")
            try bundle.data.write(to: url, options: [.atomic, .completeFileProtection])
            bundleURL = url
        }
    }

    private func remove(_ previous: AgentRepairData.Job) {
        guard let api else { return }
        perform {
            struct Deleted: Decodable { let deleted: Bool }
            let receipt: Deleted = try await api.moduleJSON("agent-repair/jobs/" + previous.id + "/remove", upload: Data("{}".utf8), timeout: 25)
            guard receipt.deleted else { throw APIError.malformed }
            try Task.checkCancellation()
            job = nil
            removeBundle()
            catalog = try await api.moduleJSON("agent-repair", timeout: 35)
        }
    }

    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true
        notice = nil
        operation = Task {
            defer { busy = false }
            do { try await action() }
            catch is CancellationError { return }
            catch { notice = AgentPCFeedback.message(error, fallback: "Kunne ikke hente reparationsopgaven. Opdatér for at se PC’ens faktiske status.") }
        }
    }

    private func importLog(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            guard ["ips", "log", "txt", "json"].contains(url.pathExtension.lowercased()) else { throw APIError.input }
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 1_000_000 else { throw APIError.input }
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            let data = try file.read(upToCount: 1_000_001) ?? Data()
            guard data.count <= 1_000_000, let text = String(data: data, encoding: .utf8) else { throw APIError.input }
            report = String(text.prefix(48000))
            profile = "ios"
            notice = text.count > 48000 ? "De første 48.000 tegn er taget med. Gem gerne den fulde original til Mac-testen." : "Loggen er klar. Vælg projektet, så rapporten bindes til den rigtige revision."
        } catch { notice = "Vælg en læsbar .ips-, .log- eller .txt-fil under 1 MB." }
    }

    private func removeBundle() {
        if let bundleURL { try? FileManager.default.removeItem(at: bundleURL) }
        bundleURL = nil
    }
}
