// Agent Workspace file selection, single-file proposals and human approval.
import Foundation
import SwiftUI

struct CodeWorkspaceView: View {
    @Environment(\.fadedPalette) private var palette
    @Environment(\.horizontalSizeClass) private var sizeClass

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
    @State private var proposalTargetID: String?
    @State private var unverifiedApprovalID: String?
    @State private var loading = false
    @State private var workspaceLoaded = false
    @State private var workspaceError: String?
    @State private var contextError: String?
    @State private var workspaceRequest: UUID?
    @State private var workspaceScope: String?
    @State private var message: String?
    @State private var approval = false
    @State private var featureRequest = ""
    @State private var firstEditLine = "1"
    @State private var generatedProposal: GeneratedProposal?
    @State private var codeStatus = ""
    @State private var testPlan: [String] = []
    @State private var showFileDetails = false
    @State private var showBatchReview = false
    @State private var openedFile: String?

    var body: some View {
        GeometryReader { geometry in
            if sizeClass == .regular && geometry.size.width >= 740 {
                NavigationSplitView {
                    fileNavigation(useSplit: true)
                        .navigationSplitViewColumnWidth(min: 280, ideal: 330, max: 400)
                } detail: {
                    workspaceDetail.navigationTitle("Arbejdsområde")
                }
                .navigationSplitViewStyle(.balanced)
            } else {
                NavigationStack { fileNavigation(useSplit: false) }
                    .sheet(isPresented: $showFileDetails) {
                        NavigationStack {
                            workspaceDetail.navigationTitle("Filændring")
                                .navigationBarTitleDisplayMode(.inline)
                                .toolbar {
                                    ToolbarItem(placement: .cancellationAction) {
                                        Button("Tilbage til filer") { showFileDetails = false }.disabled(loading)
                                    }
                                }
                        }
                        .interactiveDismissDisabled(loading)
                    }
            }
        }
        .task(id: api?.queueTargetID) {
            let scope = api?.queueTargetID
            if workspaceScope != scope {
                workspaceScope = scope
                files = []
                workspaceLoaded = false
                workspaceRequest = nil
                loading = false
                proposal = nil
                proposalTargetID = nil
                generatedProposal = nil
                testPlan = []
                approval = false
                content = ""
                path = "notes/plan.md"
                firstEditLine = "1"
                codeStatus = ""
                message = nil
                openedFile = nil
                showFileDetails = false
                showBatchReview = false
            }
            restoreContext()
            await load()
            if !Task.isCancelled, api != nil, let initialPath {
                path = initialPath
                showFileDetails = true
                await open(initialPath)
            }
        }
    }

    private func fileNavigation(useSplit: Bool) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: FadedSpacing.section) {
                if let api {
                    FadedDetailText("Åbn en fil, eller markér den til din arbejdskontekst.")
                    if !useSplit {
                        if currentProposal != nil {
                            FadedSecondaryButton("Gennemgå åbent forslag", icon: "checklist") { showFileDetails = true }
                        }
                        FadedSecondaryButton("Ny eller manuel ændring", icon: "square.and.pencil") { showFileDetails = true }
                    }
                    FadedSecondaryButton("Forslag til flere filer", icon: "square.stack") { showBatchReview = true }
                        .sheet(isPresented: $showBatchReview) { BatchReviewSheet(api: api).id(api.queueTargetID) }
                    if let contextError { FadedDetailText(contextError) }
                    fileCards(useSplit: useSplit)
                } else {
                    FadedEmptyState(icon: "desktopcomputer", title: "Forbind til din PC",
                                    detail: "Åbn Forbindelser på Hjem for at se filerne i Agent Workspace.",
                                    actionTitle: "Gå til Hjem", action: onBack)
                }
            }
            .padding(FadedSpacing.edge).frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(FadedBackground(variant: .terminal))
        .navigationTitle("Code Bot")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Tilbage", systemImage: "chevron.left", action: onBack)
            }
        }
        .refreshable { await load() }
    }

    private var workspaceDetail: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: FadedSpacing.section) {
                    if api == nil {
                        FadedEmptyState(icon: "desktopcomputer", title: "PC-forbindelse mangler",
                                        detail: "Gå til Hjem for at forbinde til din PC.",
                                        actionTitle: "Gå til Hjem", action: onBack)
                    } else {
                        if let proposal = currentProposal { proposalCard(proposal).id(proposal.change_id) }
                        if let message {
                            FadedCard(accent: palette.cyan) { Text(message).font(FadedTypography.body) }
                        }
                        FadedSectionHeader("Agent Workspace", detail: openedFile ?? "Vælg en fil, eller angiv en ny filsti i Ret fil manuelt.")
                        autonomyCard
                        featureCard
                        manualCard
                    }
                }
                .padding(FadedSpacing.edge).frame(maxWidth: 680).frame(maxWidth: .infinity)
            }
            .onChange(of: currentProposal?.change_id, initial: true) { _, id in
                if let id { proxy.scrollTo(id, anchor: .top) }
            }
            .safeAreaInset(edge: .bottom) {
                if let proposal = currentProposal {
                    workspaceApprovalBar(proposal)
                }
            }
        }
        .background(FadedBackground(variant: .terminal))
        .confirmationDialog("Godkend filændringen?", isPresented: $approval, presenting: currentProposal) { item in
            Button("Skriv filen", role: .destructive) { Task { await apply(item) } }
        } message: { item in
            Text("Kun \(item.path) i Agent Workspace bliver ændret.")
        }
    }

    private var currentProposal: V2CodeProposal? {
        guard let api, proposalTargetID == api.queueTargetID else { return nil }
        return proposal
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

    @ViewBuilder private func fileCards(useSplit: Bool) -> some View {
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
            FadedCard(accent: openedFile == file.path ? palette.cyan : nil) {
                HStack(spacing: FadedSpacing.s) {
                    Button {
                        if isSelected { selected.remove(file.path) }
                        else { selected.insert(file.path) }
                        persistContext()
                    } label: {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(isSelected && palette.isDark ? palette.lime : palette.secondary)
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isSelected ? "Fjern \(file.path) fra kontekst" : "Tilføj \(file.path) til kontekst")
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                    Button {
                        if !useSplit { showFileDetails = true }
                        Task { await open(file.path) }
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(file.path).font(FadedTypography.code)
                                Text(ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file))
                                    .font(.caption.monospacedDigit()).foregroundStyle(palette.secondary)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").foregroundStyle(palette.secondary)
                                .accessibilityHidden(true)
                        }
                        .frame(minHeight: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Åbn \(file.path)")
                }
            }
            .disabled(loading)
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
                .buttonStyle(FadedButtonStyle(kind: currentProposal == nil ? .primary : .secondary))
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
                Text(proposal.path).font(FadedTypography.code)
                FadedDiff(diff: proposal.diff)
                if !testPlan.isEmpty {
                    FadedSectionLabel("Testplan")
                    ForEach(Array(testPlan.enumerated()), id: \.offset) { item in Text("\(item.offset + 1). \(item.element)") }
                }
            }
        }
    }

    private func workspaceApprovalBar(_ proposal: V2CodeProposal) -> some View {
        VStack(spacing: FadedSpacing.s) {
            if loading { FadedDetailText("Vent på PC’en.") }
            else if unverifiedApprovalID == proposal.change_id { FadedDetailText("Åbn filen igen, og tjek den, før du opretter et nyt forslag.") }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: FadedSpacing.s) { workspaceApprovalActions(proposal) }
                VStack(spacing: FadedSpacing.s) { workspaceApprovalActions(proposal) }
            }.disabled(loading)
        }
        .padding(.horizontal, FadedSpacing.edge).padding(.vertical, FadedSpacing.s)
        .background(palette.background)
    }

    @ViewBuilder private func workspaceApprovalActions(_ proposal: V2CodeProposal) -> some View {
        FadedSecondaryButton("Afvis", role: .destructive) { Task { await reject(proposal) } }
        FadedPrimaryButton("Godkend ændring", icon: "checkmark") { approval = true }
            .disabled(unverifiedApprovalID == proposal.change_id)
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
        let refreshed = try await api.v2CodeWorkspace().files
        if workspaceScope == api.queueTargetID { files = refreshed }
    }

    private func open(_ file: String) async {
        guard let api, workspaceScope == api.queueTargetID, !loading else { return }
        loading = true
        message = nil
        defer { if workspaceScope == api.queueTargetID { loading = false } }
        do {
            let found = try await api.v2CodeFile(path: file)
            guard workspaceScope == api.queueTargetID else { return }
            guard found.path == file else { throw V2Failure.invalidResponse }
            openedFile = found.path
            path = found.path
            content = found.content
            firstEditLine = "1"
        }
        catch {
            AppDiagnostics.record(error)
            if workspaceScope == api.queueTargetID { message = "Filen kunne ikke åbnes sikkert. Vælg den igen i fillisten." }
        }
    }

    private func prepare() async {
        guard let api, workspaceScope == api.queueTargetID, !loading else { return }
        let target = path
        proposal = nil
        proposalTargetID = nil
        generatedProposal = nil
        testPlan = []
        codeStatus = ""
        loading = true
        defer { if workspaceScope == api.queueTargetID { loading = false } }
        do {
            let prepared = try await api.v2CodeProposal(path: target, content: content)
            guard workspaceScope == api.queueTargetID else { return }
            guard prepared.requires_approval, prepared.path == target, !prepared.diff.isEmpty else { throw V2Failure.invalidResponse }
            proposal = prepared
            proposalTargetID = api.queueTargetID
            message = nil
        } catch {
            AppDiagnostics.record(error)
            if workspaceScope == api.queueTargetID { message = "Ændringen kunne ikke forberedes. Tjek filstien og prøv igen." }
        }
    }

    private func generateFeature() async {
        guard let api, workspaceScope == api.queueTargetID, !loading else { return }
        let brief = featureRequest.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !brief.isEmpty, !target.isEmpty else { return }
        guard let firstLine = Int(firstEditLine.trimmingCharacters(in: .whitespacesAndNewlines)), firstLine > 0 else {
            codeStatus = "Indtast en gyldig startlinje."
            return
        }
        proposal = nil
        proposalTargetID = nil
        generatedProposal = nil
        testPlan = []
        loading = true; codeStatus = "Henter den aktuelle fil fra PC’en…"
        defer { if workspaceScope == api.queueTargetID { loading = false } }
        do {
            let original = try await workspaceSource(api, path: target)
            guard workspaceScope == api.queueTargetID else { return }
            let source = original ?? ""
            let context = try WorkspacePatch.context(goal: brief, path: target, source: source, firstLine: firstLine)
            let request = try V2ChatRequest(message: context.prompt)
            codeStatus = context.lines.isEmpty ? "PC-modellen forbereder en ny fil…"
                : "PC-modellen gennemgår linje \(firstLine)–\(context.lines.upperBound)…"
            let stream = DraftStream()
            try await api.v2Chat(request) { event in
                await MainActor.run {
                    guard workspaceScope == api.queueTargetID else { return }
                    if event.type == .text { stream.append(event.content) }
                    if event.type == .tool_status { codeStatus = codeStatusText(event.content, api: api) }
                }
            }
            guard workspaceScope == api.queueTargetID else { return }
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
            guard workspaceScope == api.queueTargetID else { return }
            let prepared = try await api.v2CodeProposal(path: target, content: revised)
            guard prepared.requires_approval, prepared.path == target, !prepared.diff.isEmpty else {
                throw V2Failure.invalidResponse
            }
            try await checkSource(api, path: target, original: original)
            guard workspaceScope == api.queueTargetID else { return }
            generatedProposal = GeneratedProposal(original: original, revised: revised)
            proposal = prepared
            proposalTargetID = api.queueTargetID
            testPlan = plan.map { codeStatusText($0, api: api) }
            codeStatus = "Forslaget er klar. Gennemgå diff og testplan."
        } catch {
            AppDiagnostics.record(error)
            guard workspaceScope == api.queueTargetID else { return }
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
        guard let api, workspaceScope == api.queueTargetID, currentProposal?.change_id == item.change_id, !loading else { return }
        loading = true
        defer { if workspaceScope == api.queueTargetID { loading = false } }
        do {
            let result = try await api.v2ApplyCodeProposal(item.change_id, approved: false)
            guard workspaceScope == api.queueTargetID else { return }
            guard result.change_id == item.change_id, result.path == item.path else { throw V2Failure.invalidResponse }
            guard !result.applied else {
                message = "PC’en melder, at ændringen allerede er anvendt. Genindlæs filen."
                return
            }
            confirmRejection()
        } catch let V2Failure.http(status, code, explanation) where
            status == 409 && code == "NOT_READY" && explanation == "Ændringen blev ikke godkendt. Intet blev skrevet." {
            guard workspaceScope == api.queueTargetID else { return }
            confirmRejection()
        } catch {
            AppDiagnostics.record(error)
            guard workspaceScope == api.queueTargetID else { return }
            message = "PC’en bekræftede ikke afvisningen. Forslaget vises stadig."
        }
    }

    private func confirmRejection() {
        proposal = nil
        proposalTargetID = nil
        generatedProposal = nil
        testPlan = []
        codeStatus = ""
        message = "PC’en bekræftede, at forslaget er afvist."
    }

    private func apply(_ item: V2CodeProposal) async {
        guard let api, workspaceScope == api.queueTargetID, currentProposal?.change_id == item.change_id,
              unverifiedApprovalID != item.change_id, !loading else { return }
        loading = true
        defer { if workspaceScope == api.queueTargetID { loading = false } }
        do {
            if let generatedProposal {
                try await checkSource(api, path: item.path, original: generatedProposal.original)
            }
            guard workspaceScope == api.queueTargetID else { return }
            unverifiedApprovalID = item.change_id
            let result = try await api.v2ApplyCodeProposal(item.change_id, approved: true)
            guard workspaceScope == api.queueTargetID else { return }
            guard result.change_id == item.change_id, result.path == item.path else { throw V2Failure.invalidResponse }
            proposal = nil
            proposalTargetID = nil
            if result.applied, item.path == path, let generatedProposal { content = generatedProposal.revised }
            generatedProposal = nil
            codeStatus = ""
            message = result.applied ? "Ændringen er skrevet til \(result.path)." : "Intet blev ændret."
            try? await reloadFiles(api)
        } catch let failure as WorkspacePatch.Failure {
            AppDiagnostics.record(failure)
            guard workspaceScope == api.queueTargetID else { return }
            proposal = nil
            proposalTargetID = nil
            generatedProposal = nil
            message = failure.message
        } catch {
            AppDiagnostics.record(error)
            if workspaceScope == api.queueTargetID { message = "PC’en bekræftede ikke ændringen. Intet nyt forsøg blev sendt." }
        }
    }

    private func persistContext() {
        do {
            try MigratedAppData.shared.saveCodeContext(Array(selected).sorted())
            contextError = nil
        } catch { AppDiagnostics.record(error); contextError = "Filvalget kunne ikke gemmes." }
    }

    private func restoreContext() {
        selected = Set(MigratedAppData.shared.codeContext())
    }
}
