// Code Bot workspace, batch proposals and human approval.

import Foundation
import SwiftUI

struct BatchReviewView: View {
    let api: LiveAPI
    @State private var jobs: [CodeBatchList.Job] = []
    @State private var repo = ""
    @State private var goal = ""
    @State private var paths = ""
    @State private var failure: String?
    @State private var busy = false

    var body: some View {
        Form {
            Section("Ny opgave") {
                TextField("Repo (ejer/projekt)", text: $repo).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Klon GitHub-repo til PC’en") { Task { await clone() } }
                    .disabled(busy || repo.trimmingCharacters(in: .whitespaces).isEmpty)
                TextField("Hvad skal ændres?", text: $goal, axis: .vertical)
                TextField("Op til fem filstier, én pr. linje", text: $paths, axis: .vertical)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                FadedPrimaryButton("Sæt i kø", icon: "terminal") { Task { await enqueue() } }
                    .disabled(busy || repo.isEmpty || goal.isEmpty || paths.isEmpty)
                if busy || repo.isEmpty || goal.isEmpty || paths.isEmpty {
                    Text(busy ? "Vent på PC’en." : "Udfyld repo, opgave og filstier.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Kodejob") {
                if let failure { Text(failure) }
                Button("Opdatér liste") { Task { await reload() } }
                ForEach(jobs) { job in
                    NavigationLink {
                        BatchProposalView(api: api, id: job.id)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(job.goal)
                            Text(batchStatus(job.status)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(FadedBackground(variant: .terminal))
        .navigationTitle("Forslag til flere filer")
        .task { await reload() }
        .refreshable { await reload() }
    }

    private func reload() async {
        do { jobs = try await api.codeBatches().jobs; failure = nil }
        catch { AppDiagnostics.record(error); failure = pcBusyMessage(error) ?? "Kodekøen kunne ikke hentes. Kontrollér forbindelsen til PC’en." }
    }

    private func enqueue() async {
        busy = true
        defer { busy = false }
        let files = paths.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        do {
            try await api.enqueueCodeBatch(repo: repo.trimmingCharacters(in: .whitespaces), goal: goal, files: files)
            goal = ""
            await reload()
        } catch { AppDiagnostics.record(error); failure = pcBusyMessage(error) ?? "Opgaven kunne ikke sættes i kø. Tjek repo og filstier." }
    }

    private func clone() async {
        busy = true
        defer { busy = false }
        do {
            try await api.cloneCodeRepository(repo.trimmingCharacters(in: .whitespaces))
            failure = nil
        } catch { AppDiagnostics.record(error); failure = pcBusyMessage(error) ?? "Repoet kunne ikke klones. Tjek navnet og PC’ens adgang til GitHub." }
    }
}

private func batchStatus(_ status: String) -> String {
    switch status {
    case "queued": "I kø"
    case "running": "Arbejder"
    case "review": "Afventer godkendelse"
    case "applied": "Gemt på lokal gren"
    case "declined": "Intet forslag"
    default: "Jobbet stoppede"
    }
}

struct BatchProposalView: View {
    let api: LiveAPI
    let id: String
    @State private var detail: CodeBatchDetail?
    @State private var confirm = false
    @State private var busy = false
    @State private var notice: String?

    var body: some View {
        List {
            if let detail { Text(batchStatus(detail.status)) }
            if let notice { Text(notice) }
            if let reason = detail?.result?.reason { Text(verbatim: reason) }
            if let diff = detail?.result?.diff {
                Section("Ændringer") {
                    FadedDiff(diff: diff)
                }
            }
            if let tests = detail?.result?.tests {
                Section("Testplan") {
                    ForEach(Array(tests.enumerated()), id: \.offset) { entry in Text(verbatim: entry.element) }
                }
            }
            if let checks = detail?.result?.checks, !checks.isEmpty {
                Section("Kontroller kørt på PC’en") {
                    ForEach(Array(checks.enumerated()), id: \.offset) { entry in Text(verbatim: entry.element) }
                }
            }
            if let branch = detail?.result?.branch { Text(verbatim: branch).textSelection(.enabled) }
            if detail?.status == "review" {
                FadedPrimaryButton("Godkend ændringer", icon: "checkmark") { confirm = true }.disabled(busy)
                if busy { Text("Vent på PC’en.").font(.caption).foregroundStyle(.secondary) }
            }
            Button("Opdatér") { Task { await reload() } }.disabled(busy)
        }
        .scrollContentBackground(.hidden)
        .background(FadedBackground(variant: .terminal))
        .navigationTitle("Gennemgå forslag")
        .task { await reload() }
        .confirmationDialog("Godkend ændringerne?", isPresented: $confirm) {
            Button("Opret lokal Git-gren") { Task { await approve() } }
        } message: { Text("Forslaget gemmes på en separat gren i Agent Workspace på PC’en.") }
    }

    private func reload() async {
        do { detail = try await api.codeBatch(id); notice = nil }
        catch { AppDiagnostics.record(error); notice = "Forslaget kunne ikke hentes." }
    }

    private func approve() async {
        busy = true
        defer { busy = false }
        do {
            let applied = try await api.approveCodeBatch(id)
            await reload()
            if let branch = applied.branch { notice = "Ændringerne er gemt på \(branch)." }
        } catch { AppDiagnostics.record(error); notice = "PC’en kunne ikke bekræfte godkendelsen. Opdatér for at se den aktuelle status." }
    }
}

struct CodeWorkspaceView: View {
    @Environment(\.fadedPalette) private var palette

    private struct FeatureDraft: Decodable {
        let feasible: Bool
        let reason: String
        let diff: String?
        let tests: [String]
    }
    private struct GeneratedProposal {
        let original: String?
        let revised: String
    }
    @MainActor private final class DraftStream {
        var text = ""
        var overflowed = false

        func append(_ part: String) {
            guard !overflowed else { return }
            if text.utf8.count + part.utf8.count > 64_000 {
                overflowed = true
                text = ""
            } else {
                text += part
            }
        }
    }
    private enum Autonomy: String, CaseIterable {
        case strict = "Strict"
        case guided = "Guided"
        case autonomous = "Autonomous"

        var explanation: String {
            switch self {
            case .strict: "Code Bot må kun forberede ændringer. Du godkender hver fil."
            case .guided: "Code Bot må planlægge flere trin. Hver filskrivning kræver stadig godkendelse."
            case .autonomous: "Code Bot må arbejde videre selv. Sikkerhedsgodkendelse før filskrivning er stadig aktiv."
            }
        }
    }

    let api: LiveAPI?
    let onBack: () -> Void
    var initialPath: String? = nil
    @AppStorage(AppStorageKeys.codeAutonomy) private var autonomy = Autonomy.strict.rawValue
    @State private var files: [V2CodeWorkspace.File] = []
    @State private var selected = Set<String>()
    @State private var path = "notes/plan.md"
    @State private var content = ""
    @State private var proposal: V2CodeProposal?
    @State private var loading = false
    @State private var workspaceLoaded = false
    @State private var workspaceError: String?
    @State private var workspaceRequest: UUID?
    @State private var workspaceScope: String?
    @State private var message: String?
    @State private var approval = false
    @State private var featureRequest = ""
    @State private var firstEditLine = "1"
    @State private var generatedProposal: GeneratedProposal?
    @State private var codeStatus = ""
    @State private var testPlan: [String] = []

    var body: some View {
        NavigationStack {
            codeContent
                .background(FadedBackground(variant: .terminal))
                .navigationTitle("Code Bot")
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Tilbage", systemImage: "chevron.left", action: onBack)
                    }
                }
                .refreshable { await load() }
                .task(id: api?.queueTargetID) {
                    let scope = api?.queueTargetID
                    if workspaceScope != scope {
                        workspaceScope = scope
                        files = []
                        workspaceLoaded = false
                        workspaceError = nil
                        proposal = nil
                        generatedProposal = nil
                        testPlan = []
                        approval = false
                        content = ""
                        message = nil
                    }
                    restoreContext()
                    await load()
                    if !Task.isCancelled, let initialPath {
                        path = initialPath
                        await open(initialPath)
                    }
                }
                .confirmationDialog("Godkend filændringen?", isPresented: $approval, presenting: proposal) { item in
                    Button("Skriv filen", role: .destructive) { Task { await apply(item) } }
                } message: { item in
                    Text("Kun \(item.path) i Agent Workspace bliver ændret.")
                }
        }
    }

    private var codeContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: FadedSpacing.section) {
                if api == nil {
                    FadedEmptyState(icon: "desktopcomputer", title: "Forbind til din PC",
                                    detail: "Åbn Forbindelser på Hjem for at bruge Code Bot og se dine filer.",
                                    actionTitle: "Gå til Hjem", action: onBack)
                } else {
                    FadedDetailText("Din makker på PC’en. Se ændringen, før den skrives.")
                    autonomyCard
                    fileCards
                    featureCard
                    manualCard
                    if let proposal { proposalCard(proposal) }
                }
                if let message {
                    FadedCard(accent: palette.cyan) { Text(message).font(FadedTypography.body) }
                }
            }.padding(FadedSpacing.edge).frame(maxWidth: 680).frame(maxWidth: .infinity)
        }
    }

    private var autonomyCard: some View {
        FadedCard {
            VStack(alignment: .leading, spacing: 8) {
                FadedSectionLabel("Autonomi")
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 4) { autonomyChoices }
                    VStack(alignment: .leading, spacing: 4) { autonomyChoices }
                }
                Text(Autonomy(rawValue: autonomy)?.explanation ?? Autonomy.strict.explanation)
                    .font(.callout).foregroundStyle(palette.secondary)
            }
        }
    }

    @ViewBuilder private var autonomyChoices: some View {
        ForEach(Autonomy.allCases, id: \.rawValue) { choice in
            FadedChip(choice.rawValue, accent: palette.lime, selected: autonomy == choice.rawValue) {
                autonomy = choice.rawValue
            }
        }
    }

    @ViewBuilder private var fileCards: some View {
        FadedSectionHeader("Aktive filer")
        if let workspaceError {
            RetryNotice(message: workspaceError) { Task { await load() } }
        } else if !workspaceLoaded || workspaceRequest != nil {
            LoadingSkeleton(label: "Henter filer fra PC’en…")
        } else if files.isEmpty {
            FadedEmptyState(icon: "folder", title: "Ingen filer her endnu",
                            detail: "Tilføj en tekstfil i Agent Workspace på PC’en, og opdatér listen.",
                            actionTitle: "Opdatér filer") { Task { await load() } }
        }
        ForEach(files) { file in
            let isSelected = selected.contains(file.path)
            Button {
                guard !loading else { return }
                if isSelected { selected.remove(file.path) }
                else { selected.insert(file.path) }
                persistContext()
                Task { await open(file.path) }
            } label: {
                FadedCard(accent: isSelected ? palette.lime : nil) {
                    HStack(spacing: 10) {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(isSelected && palette.isDark ? palette.lime : palette.secondary)
                        VStack(alignment: .leading) {
                            Text(file.path).font(FadedTypography.code).lineLimit(2)
                            Text(ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file))
                                .font(.caption.monospacedDigit()).foregroundStyle(palette.secondary)
                        }
                        Spacer(minLength: 0)
                    }.frame(minHeight: 44)
                }
                .overlay {
                    if isSelected { RoundedRectangle(cornerRadius: FadedRadius.card).strokeBorder(palette.lime, lineWidth: 2).allowsHitTesting(false) }
                }
            }
            .buttonStyle(.plain)
            .disabled(loading)
            .accessibilityLabel(file.path)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        }
    }

    private var featureBlocker: String? {
        if api == nil { return "Forbind til PC’en først." }
        if loading { return "Vent på PC’en." }
        if path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Vælg en fil." }
        if featureRequest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Beskriv ændringen først." }
        return nil
    }

    private var featureCard: some View {
        FadedCard {
            VStack(alignment: .leading, spacing: 10) {
                if let api {
                    NavigationLink("Forslag til flere filer") { BatchReviewView(api: api) }
                        .buttonStyle(FadedButtonStyle(kind: .secondary))
                }
                FadedSectionHeader("Byg en funktion", detail: "Vælg en fil og beskriv én ændring. Brug startlinjen, hvis filen er lang.")
                FadedFieldLabel("Hvad skal ændres?")
                TextField("Hvad skal ændres?", text: $featureRequest, axis: .vertical)
                    .lineLimit(2...6).textFieldStyle(.roundedBorder).frame(minHeight: 44).disabled(loading)
                LabeledContent("Startlinje i filen") {
                    TextField("Startlinje", text: $firstEditLine).keyboardType(.numberPad)
                        .font(FadedTypography.number).multilineTextAlignment(.trailing).frame(minHeight: 44).disabled(loading)
                }
                Button { Task { await generateFeature() } } label: {
                    Label("Forbered forslag", systemImage: "terminal").frame(maxWidth: .infinity)
                }
                .buttonStyle(FadedButtonStyle(kind: proposal == nil ? .primary : .secondary))
                .disabled(featureBlocker != nil)
                if let featureBlocker { Text(featureBlocker).font(.caption).foregroundStyle(palette.secondary) }
                if !codeStatus.isEmpty { Text(codeStatus).font(.caption).foregroundStyle(palette.secondary) }
            }
        }
    }

    private var manualCard: some View {
        FadedCard {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Relativ filsti", text: $path).textInputAutocapitalization(.never)
                        .autocorrectionDisabled().textFieldStyle(.roundedBorder).disabled(loading)
                    TextEditor(text: $content).font(FadedTypography.code).frame(minHeight: 180)
                        .overlay { RoundedRectangle(cornerRadius: FadedRadius.small).strokeBorder(palette.border) }
                        .accessibilityLabel("Nyt filindhold").disabled(loading)
                    FadedSecondaryButton("Forbered manuel ændring") { Task { await prepare() } }
                        .disabled(api == nil || loading || path.isEmpty)
                }.padding(.top, 10)
            } label: { FadedSectionLabel("Ret fil manuelt") }
        }
    }

    private func proposalCard(_ proposal: V2CodeProposal) -> some View {
        FadedCard(accent: palette.cyan) {
            VStack(alignment: .leading, spacing: 10) {
                Label("Dit tjek. Din godkendelse.", systemImage: "lock.shield").font(FadedTypography.action)
                FadedDiff(diff: proposal.diff)
                if !testPlan.isEmpty {
                    FadedSectionLabel("Testplan")
                    ForEach(Array(testPlan.enumerated()), id: \.offset) { item in Text("\(item.offset + 1). \(item.element)") }
                }
                FadedPrimaryButton("Godkend ændring", icon: "checkmark") { approval = true }.disabled(loading)
                if loading { Text("Vent på PC’en.").font(.caption).foregroundStyle(palette.secondary) }
                FadedSecondaryButton("Afvis") { Task { await reject(proposal) } }.disabled(loading)
            }
        }
    }

    private func load() async {
        guard let api, !loading || workspaceRequest != nil else { return }
        let request = UUID()
        workspaceRequest = request
        workspaceError = nil
        loading = true
        defer {
            if workspaceRequest == request {
                workspaceRequest = nil
                loading = false
            }
        }
        do {
            let result = try await api.v2CodeWorkspace().files
            try Task.checkCancellation()
            guard workspaceRequest == request else { return }
            files = result
            workspaceLoaded = true
        } catch {
            guard !Task.isCancelled, workspaceRequest == request else { return }
            AppDiagnostics.record(error)
            workspaceError = "Filerne kunne ikke hentes. Tjek forbindelsen, og prøv igen."
        }
    }

    private func reloadFiles(_ api: LiveAPI) async throws {
        files = try await api.v2CodeWorkspace().files
    }

    private func open(_ file: String) async {
        guard let api, !loading else { return }
        loading = true; defer { loading = false }
        do {
            let found = try await api.v2CodeFile(path: file)
            path = found.path
            content = found.content
            firstEditLine = "1"
        }
        catch { AppDiagnostics.record(error); message = "Filen kunne ikke åbnes sikkert." }
    }

    private func prepare() async {
        guard let api, !loading else { return }
        proposal = nil
        generatedProposal = nil
        testPlan = []
        codeStatus = ""
        loading = true; defer { loading = false }
        do { proposal = try await api.v2CodeProposal(path: path, content: content); message = nil }
        catch { AppDiagnostics.record(error); message = "Ændringen kunne ikke forberedes. Tjek filstien og prøv igen." }
    }

    private func generateFeature() async {
        guard let api, !loading else { return }
        let brief = featureRequest.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !brief.isEmpty, !target.isEmpty else { return }
        guard let firstLine = Int(firstEditLine.trimmingCharacters(in: .whitespacesAndNewlines)), firstLine > 0 else {
            codeStatus = "Indtast en gyldig startlinje."
            return
        }
        proposal = nil
        generatedProposal = nil
        testPlan = []
        loading = true; codeStatus = "Henter den aktuelle fil fra PC’en…"
        defer { loading = false }
        do {
            let original = try await workspaceSource(api, path: target)
            let source = original ?? ""
            let context = try WorkspacePatch.context(goal: brief, path: target, source: source, firstLine: firstLine)
            let request = try V2ChatRequest(message: context.prompt)
            codeStatus = context.lines.isEmpty ? "PC-modellen forbereder en ny fil…"
                : "PC-modellen gennemgår linje \(firstLine)–\(context.lines.upperBound)…"
            let stream = DraftStream()
            try await api.v2Chat(request) { event in
                await MainActor.run {
                    if event.type == .text { stream.append(event.content) }
                    if event.type == .tool_status { codeStatus = codeStatusText(event.content, api: api) }
                }
            }
            guard !stream.overflowed else { throw WorkspacePatch.Failure.invalidDiff }
            let result = try JSONDecoder().decode(FeatureDraft.self, from: ModelJSON.payload(stream.text))
            guard result.feasible else {
                codeStatus = codeStatusText(result.reason, api: api)
                return
            }
            let plan = result.tests.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard let diff = result.diff,
                  (1...6).contains(plan.count), plan.allSatisfy({ !$0.isEmpty && $0.count <= 300 })
            else { throw WorkspacePatch.Failure.invalidDiff }
            let revised = try WorkspacePatch.applying(diff, to: source, path: target, within: context.lines)
            try await checkSource(api, path: target, original: original)
            let prepared = try await api.v2CodeProposal(path: target, content: revised)
            guard prepared.requires_approval, prepared.path == target, !prepared.diff.isEmpty else {
                throw V2Failure.invalidResponse
            }
            try await checkSource(api, path: target, original: original)
            generatedProposal = GeneratedProposal(original: original, revised: revised)
            proposal = prepared
            testPlan = plan.map { codeStatusText($0, api: api) }
            codeStatus = "Forslaget er klar. Gennemgå diff og testplan."
        } catch {
            AppDiagnostics.record(error)
            codeStatus = (error as? WorkspacePatch.Failure)?.message
                ?? pcBusyMessage(error) ?? "Code Bot kunne ikke forberede ændringen. Ingen fil blev skrevet."
        }
    }

    private func codeStatusText(_ text: String, api: LiveAPI) -> String {
        let safe = api.redactChat(text, complete: true).trimmingCharacters(in: .whitespacesAndNewlines)
        if safe.contains("Traceback (most recent call last)") { return "PC’en sendte en intern fejl." }
        return String(safe.prefix(300)).replacingOccurrences(of: #"(?i)(?:\b[A-Z]:[\\/]|\\\\)[^\r\n`\"<>]+"#,
                                                              with: "[filsti skjult]", options: .regularExpression)
    }

    private func workspaceSource(_ api: LiveAPI, path: String) async throws -> String? {
        do {
            let file = try await api.v2CodeFile(path: path)
            guard file.path == path else { throw WorkspacePatch.Failure.stale }
            return file.content
        } catch V2Failure.http(status: 404, code: _, message: _) {
            AppDiagnostics.record(V2Failure.http(status: 404, code: nil, message: nil))
            return nil
        }
    }

    private func checkSource(_ api: LiveAPI, path: String, original: String?) async throws {
        let current = try await workspaceSource(api, path: path)
        if let original, let current, original.utf8.elementsEqual(current.utf8) { return }
        guard original == nil && current == nil else { throw WorkspacePatch.Failure.stale }
    }

    private func reject(_ item: V2CodeProposal) async {
        guard let api, !loading else { return }
        loading = true; defer { loading = false }
        do {
            let result = try await api.v2ApplyCodeProposal(item.change_id, approved: false)
            guard result.change_id == item.change_id, result.path == item.path else { throw V2Failure.invalidResponse }
            guard !result.applied else {
                message = "PC’en melder, at ændringen allerede er anvendt. Genindlæs filen."
                return
            }
            confirmRejection()
        } catch let V2Failure.http(status, code, explanation) where
            status == 409 && code == "NOT_READY" && explanation == "Ændringen blev ikke godkendt. Intet blev skrevet." {
            confirmRejection()
        } catch {
            AppDiagnostics.record(error)
            message = "PC’en bekræftede ikke afvisningen. Forslaget vises stadig."
        }
    }

    private func confirmRejection() {
        proposal = nil
        generatedProposal = nil
        testPlan = []
        codeStatus = ""
        message = "PC’en bekræftede, at forslaget er afvist."
    }

    private func apply(_ item: V2CodeProposal) async {
        guard let api, !loading else { return }
        loading = true; defer { loading = false }
        do {
            if let generatedProposal {
                try await checkSource(api, path: item.path, original: generatedProposal.original)
            }
            let result = try await api.v2ApplyCodeProposal(item.change_id, approved: true)
            proposal = nil
            if result.applied, item.path == path, let generatedProposal { content = generatedProposal.revised }
            generatedProposal = nil
            codeStatus = ""
            message = result.applied ? "Ændringen er skrevet til \(result.path)." : "Intet blev ændret."
            try? await reloadFiles(api)
        } catch let failure as WorkspacePatch.Failure {
            AppDiagnostics.record(failure)
            proposal = nil
            generatedProposal = nil
            codeStatus = failure.message
        } catch { AppDiagnostics.record(error); message = "PC’en bekræftede ikke ændringen. Intet nyt forsøg blev sendt." }
    }

    private func persistContext() {
        do { try MigratedAppData.shared.saveCodeContext(Array(selected).sorted()) }
        catch { AppDiagnostics.record(error); message = "Filvalget kunne ikke gemmes." }
    }

    private func restoreContext() {
        selected = Set(MigratedAppData.shared.codeContext())
    }
}
