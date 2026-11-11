import Foundation
import SwiftUI

enum PCModelSelection {
    static let adultRoleplayLabel = "18+ rollespil"

    static func isAdultRoleplayModel(_ id: String?) -> Bool {
        id == "dolphin3-8b"
    }

    static func key(for api: LiveAPI?) -> String {
        AppStorageKeys.pcModel(api?.queueTargetID)
    }

    static func saved(for api: LiveAPI?, defaults: UserDefaults = .standard) -> String? {
        guard api != nil, let value = defaults.string(forKey: key(for: api)), !value.isEmpty else { return nil }
        return value
    }

    static func set(_ id: String, for api: LiveAPI?, defaults: UserDefaults = .standard) {
        guard api != nil else { return }
        if id.isEmpty { defaults.removeObject(forKey: key(for: api)) }
        else { defaults.set(id, forKey: key(for: api)) }
    }

    static func usable(_ entry: V2Models.Entry) -> Bool {
        entry.available && entry.capabilities.contains("chat") && !entry.requiresImageForChat
    }

    static func installed(in catalog: V2Models) -> [V2Models.Entry] {
        var seen = Set<String>()
        return catalog.models.filter { $0.available && !$0.id.isEmpty && seen.insert($0.id).inserted }
    }

    static func advertised(in catalog: V2Models) -> [V2Models.Entry] {
        let available = Dictionary(uniqueKeysWithValues: installed(in: catalog).map { ($0.id, $0) })
        var seen = Set<String>()
        return catalog.models.filter { !$0.id.isEmpty && seen.insert($0.id).inserted }.map { available[$0.id] ?? $0 }
    }

    static func textModel(in catalog: V2Models, preferredID: String?) -> V2Models.Entry? {
        let models = installed(in: catalog).filter(usable)
        return models.first { $0.id == preferredID }
            ?? models.first { $0.id == catalog.default_model_id }
            ?? models.first { $0.loaded }
            ?? models.first
    }
}

struct PCModelsView: View {
    let api: LiveAPI?
    private let onChoose: ((V2Models.Entry) -> Void)?
    @Environment(\.fadedPalette) private var palette
    @AppStorage private var selected: String
    @State private var catalog: V2Models?
    @State private var notice: String?
    @State private var loadedTargetID: String?
    @State private var requestID: UUID?

    init(api: LiveAPI?, onChoose: ((V2Models.Entry) -> Void)? = nil) {
        self.api = api
        self.onChoose = onChoose
        _selected = AppStorage(wrappedValue: "", PCModelSelection.key(for: api))
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: FadedSpacing.action) {
                FadedSignature()
                FadedDetailText("Vælg en model til PC-chat. PC’en indlæser den, når du sender en besked.")
                if api != nil {
                    FadedDetailText("RTX 3070 har 8 GB grafikhukommelse. Modelstørrelsen er pladsen på disken. Samtalens længde og andre programmer påvirker pladsen på grafikkortet.")
                }
                modelContent
            }
            .padding(FadedSpacing.edge).frame(maxWidth: 640).frame(maxWidth: .infinity)
        }
        .background { FadedBackground() }
        .foregroundStyle(palette.text)
        .navigationTitle("PC-modeller")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button("Opdatér modeller", systemImage: "arrow.clockwise") { Task { await refresh() } }
                .disabled(api == nil || requestID != nil)
        }
        .task(id: api?.queueTargetID) { await refresh() }
        .refreshable { await refresh() }
    }

    @ViewBuilder private var modelContent: some View {
        if api == nil {
            FadedEmptyState(icon: "desktopcomputer", title: "Ingen PC-forbindelse",
                            detail: "Gå tilbage til Indstillinger, og forbind til PC’en for at se dens modeller.")
        } else if loadedTargetID != api?.queueTargetID {
            catalogLoading
        } else if let notice {
            FadedCard(accent: palette.coral) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(notice)
                    FadedSecondaryButton("Prøv igen", icon: "arrow.clockwise") { Task { await refresh() } }
                }
            }
        } else if let catalog, PCModelSelection.advertised(in: catalog).isEmpty {
            FadedEmptyState(icon: "cpu", title: "Ingen modeller i PC-kataloget",
                            detail: "PC’en sendte et tomt modelkatalog. Kontrollér Ollama på PC’en, og opdatér listen.",
                            actionTitle: "Opdatér modeller") { Task { await refresh() } }
        } else if let catalog {
            let models = PCModelSelection.advertised(in: catalog)
            let ready = models.filter(PCModelSelection.usable)
            let other = models.filter { $0.available && !PCModelSelection.usable($0) }
            let missing = models.filter { !$0.available }
            if !selected.isEmpty && !catalog.models.contains(where: { $0.id == selected && PCModelSelection.usable($0) }) {
                Text("Den tidligere valgte model er utilgængelig. Vælg en installeret chatmodel, hvis der er en klar.")
                    .font(.footnote).foregroundStyle(palette.secondary)
            }
            if !ready.isEmpty {
                FadedSectionLabel("Klar til PC-chat · \(ready.count)")
                ForEach(ready) { model in
                    modelCard(model, standard: model.id == catalog.default_model_id)
                }
            } else {
                FadedDetailText("Der er endnu ingen installerede tekstmodeller til PC-chat.")
            }
            if !missing.isEmpty {
                FadedSectionLabel("Kan hentes på PC’en")
                FadedDetailText("Åbn FadedAI – Hent modeller på PC’en. Opdatér derefter listen her.")
                ForEach(missing) { model in
                    modelCard(model, standard: model.id == catalog.default_model_id)
                }
            }
            if !other.isEmpty {
                FadedSectionLabel("Til andre opgaver")
                ForEach(other) { model in
                    modelCard(model, standard: model.id == catalog.default_model_id)
                }
            }
        } else {
            catalogLoading
        }
    }

    private var catalogLoading: some View {
        VStack(alignment: .leading, spacing: FadedSpacing.s) {
            FadedDetailText("Henter modeller fra PC’en…")
            ForEach(0..<3, id: \.self) { _ in
                FadedCard(size: .compact) {
                    VStack(alignment: .leading, spacing: FadedSpacing.s) {
                        Capsule().fill(palette.secondary.opacity(0.24)).frame(width: 144, height: 12)
                        Capsule().fill(palette.secondary.opacity(0.16)).frame(width: 84, height: 10)
                        RoundedRectangle(cornerRadius: FadedRadius.small)
                            .fill(palette.secondary.opacity(0.12)).frame(maxWidth: 280).frame(height: 10)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.accessibilityHidden(true)
            }
        }
    }

    private func modelCard(_ model: V2Models.Entry, standard: Bool) -> some View {
        let usable = PCModelSelection.usable(model)
        let chosen = usable && selected == model.id
        let profile = modelProfile(model.id)
        return FadedCard(accent: chosen ? palette.lime : model.loaded ? palette.cyan : nil) {
            VStack(alignment: .leading, spacing: 8) {
                Label(model.label, systemImage: "cpu").font(FadedTypography.section).accessibilityAddTraits(.isHeader)
                if PCModelSelection.isAdultRoleplayModel(model.id) {
                    FadedBadge(PCModelSelection.adultRoleplayLabel, tone: .info)
                }
                if model.available {
                    FadedBadge(usable ? (model.loaded ? "Indlæst på PC" : "Klar til chat") : "Installeret på PC",
                               tone: usable ? .success : .info)
                } else {
                    FadedBadge("Skal hentes på PC", tone: .warning)
                }
                if let bytes = model.size_bytes, bytes > 0 {
                    FadedDetailText("På disk: \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))")
                } else if !model.available, let profile {
                    FadedDetailText("Ca. \(profile.downloadSize) at hente")
                }
                FadedDetailText(profile?.detail ?? modelDetail(model))
                if !model.available, let profile {
                    FadedDetailText("Hent modellen på PC’en, og opdatér derefter listen.")
                    Text("ollama pull \(profile.tag)")
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                }
                if let profile, let modelCardURL = URL(string: "https://huggingface.co/" + profile.modelCardPath) {
                    Link(destination: modelCardURL) {
                        Label("Læs om modellen", systemImage: "arrow.up.right")
                    }
                    .font(.subheadline)
                    .frame(minHeight: 44)
                    .accessibilityLabel("Læs om \(model.label) på Hugging Face")
                }
                if standard { Text("Standard på PC’en").font(.caption).foregroundStyle(palette.secondary) }
                if chosen {
                    Label("Foretrukken til PC-chat", systemImage: "checkmark.circle.fill").font(.subheadline)
                }
                if usable && (!chosen || onChoose != nil) {
                    FadedSecondaryButton(onChoose == nil ? "Vælg til chat" : "Brug i chat", icon: "bubble.left") {
                        selected = model.id
                        onChoose?(model)
                    }
                        .disabled(requestID != nil)
                        .accessibilityLabel("Vælg \(model.label) til chat")
                }
            }
        }
    }

    private func modelProfile(_ id: String) -> (tag: String, downloadSize: String, detail: String, modelCardPath: String)? {
        switch id {
        case "qwen35-4b":
            ("qwen3.5:4b", "3,3–4,0 GB",
             "Start her til hverdagschat på RTX 3070. God til spørgsmål, forklaringer og almindelige tekstopgaver.",
             "Qwen/Qwen3.5-4B")
        case "qwen35-9b":
            ("qwen3.5:9b", "6,6–7,6 GB",
             "Til længere forklaringer og opgaver med flere trin. Den har mindre plads til lange samtaler på RTX 3070 end de lettere modeller.",
             "Qwen/Qwen3.5-9B")
        case "qwen25-coder-7b":
            ("qwen2.5-coder:7b", "4,7 GB", "Til kode, fejlfinding og forslag til ændringer. Det er den specialiserede kodemodel.",
             "Qwen/Qwen2.5-Coder-7B-Instruct-GGUF")
        case "dolphin3-8b":
            ("dolphin3:8b", "4,9 GB", "Til rollespil for voksne og kreativ dialog. Køres lokalt på PC’en.",
             "dphn/Dolphin3.0-Llama3.1-8B")
        case "qwen25-7b":
            ("qwen2.5:7b", "4,7 GB", "Til hverdagschat, dansk tekst og korte opgaver.",
             "Qwen/Qwen2.5-7B-Instruct")
        case "llama31-8b":
            ("llama3.1:8b", "4,9 GB", "Til idéudvikling, kreativ skrivning og almindelig chat.", "meta-llama/Llama-3.1-8B-Instruct")
        case "moondream-18":
            ("moondream:1.8b", "1,7 GB", "Til at beskrive og analysere billeder på PC’en.", "vikhyatk/moondream2")
        default: nil
        }
    }

    private func modelDetail(_ model: V2Models.Entry) -> String {
        if !model.available { return "Kontrollér modellens installation på PC’en." }
        if model.supportsImageChat {
            return PCModelSelection.usable(model) ? "Til tekstchat og billedanalyse." : "Brug modellen via Analysér billede i chatten."
        }
        if !PCModelSelection.usable(model) { return "PC’en tilbyder denne model til andre opgaver end tekstchat." }
        if model.capabilities.contains(where: { $0 == "code" || $0 == "coding" }) { return "Til tekstchat og kode." }
        if model.capabilities.contains("long_context") { return "Til tekstchat med længere kontekst." }
        return "Til tekstchat på PC’en."
    }

    private func refresh() async {
        guard let api else { return }
        let id = UUID()
        requestID = id
        notice = nil
        defer { if requestID == id { requestID = nil } }
        do {
            let result = try await api.v2Models()
            try Task.checkCancellation()
            guard requestID == id else { return }
            loadedTargetID = api.queueTargetID
            catalog = result
        } catch is CancellationError {
            return
        } catch {
            AppDiagnostics.record(error)
            guard !Task.isCancelled, requestID == id else { return }
            loadedTargetID = api.queueTargetID
            catalog = nil
            if let failure = error as? V2Failure, case .http(status: 401, code: _, message: _) = failure {
                notice = "PC’en afviste tokenet. Kontrollér forbindelsen i Indstillinger."
            } else if case .http(let status, _, _)? = error as? V2Failure, [404, 405, 501].contains(status) {
                notice = "PC-serveren tilbyder endnu ingen modeloversigt."
            } else {
                notice = pcBusyMessage(error) ?? "PC’ens modeller kunne ikke hentes. Kontrollér forbindelsen, og prøv igen."
            }
        }
    }
}

// Searchable single-selection model groups, following shadcn's Model Selector pattern.
private struct ChatModelOption: Identifiable {
    let source: ChatView.ReplySource
    let modelID: String?
    let title: String
    var available = true

    var id: String { "\(source.rawValue):\(modelID ?? "")" }
    var isAdultRoleplay: Bool { source == .pc && PCModelSelection.isAdultRoleplayModel(modelID) }

    func matches(_ query: String) -> Bool {
        var terms = [title, source.rawValue, modelID ?? ""]
        if isAdultRoleplay { terms.append(PCModelSelection.adultRoleplayLabel) }
        let key = terms.joined(separator: " ")
        return query.prefix(120).split(whereSeparator: \.isWhitespace)
            .allSatisfy { key.localizedStandardContains(String($0)) }
    }
}

private struct ChatModelSelectionButton: View {
    private enum Setup { case phone, pc }

    @Environment(\.fadedPalette) private var palette
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var showing = false
    @State private var query = ""
    @State private var setupAfterDismiss: Setup? = nil

    let current: ChatModelOption
    let options: [ChatModelOption]
    let blocked: Bool
    let pcHint: String?
    let resetTitle: String?
    let pcSetupTitle: String
    let onOpen: () -> Void
    let onChoose: (ChatModelOption) -> Void
    let onReset: () -> Void
    let onPhoneSetup: () -> Void
    let onPCSetup: (() -> Void)?

    var body: some View {
        Button {
            query = ""
            onOpen()
            showing = true
        } label: {
            HStack(spacing: FadedSpacing.xs) {
                Image(systemName: current.available ? current.source.icon : "exclamationmark.circle")
                    .foregroundStyle(palette.isDark ? accent(current.source) : palette.text)
                Text(current.title).lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                Image(systemName: "chevron.down")
            }
            .font(.caption.bold())
            .frame(minWidth: 44, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(blocked)
        .accessibilityLabel("Model for næste besked")
        .accessibilityValue("\(current.source.rawValue), \(current.title)" + (current.available ? "" : ", ikke klar"))
        .sheet(isPresented: $showing, onDismiss: finishSetup) { selectionSheet }
    }

    private var selectionSheet: some View {
        let emptyQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let results = options.filter { $0.matches(query) }
        return NavigationStack {
            List {
                if let resetTitle, emptyQuery {
                    Button(resetTitle, systemImage: "arrow.uturn.backward") {
                        onReset()
                        showing = false
                    }.frame(minHeight: 44).listRowBackground(palette.card)
                }
                if !emptyQuery && results.isEmpty {
                    FadedEmptyState(icon: "magnifyingglass", title: "Ingen modeller matcher",
                                    detail: "Prøv et modelnavn, Telefon, PC, Grok eller 18+.",
                                    actionTitle: "Ryd søgning") { query = "" }
                        .listRowBackground(Color.clear)
                }
                ForEach(ChatView.ReplySource.allCases, id: \.self) { source in
                    let rows = results.filter { $0.source == source }
                    if !rows.isEmpty || (emptyQuery && source != .grok) {
                        Section {
                            ForEach(rows) { row in optionRow(row) }
                            if emptyQuery { sourceActions(source) }
                        } header: {
                            Label(source.rawValue, systemImage: source.icon)
                                .foregroundStyle(palette.isDark ? accent(source) : palette.secondary)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .foregroundStyle(palette.text)
            .background { FadedBackground() }
            .navigationTitle("Vælg model")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Søg modeller")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Luk") { showing = false } }
            }
        }
    }

    private func optionRow(_ row: ChatModelOption) -> some View {
        let selected = row.id == current.id
        return Button {
            onChoose(row)
            showing = false
        } label: {
            HStack(spacing: FadedSpacing.s) {
                VStack(alignment: .leading, spacing: FadedSpacing.xs) {
                    Text(row.title).font(FadedTypography.action)
                    if row.isAdultRoleplay {
                        FadedBadge(PCModelSelection.adultRoleplayLabel, tone: .info)
                    }
                    if !row.available { FadedDetailText("Ikke klar") }
                }
                Spacer(minLength: 8)
                if selected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(palette.isDark ? accent(row.source) : palette.text)
                        .accessibilityHidden(true)
                }
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!row.available || blocked)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .listRowBackground(palette.card)
    }

    @ViewBuilder private func sourceActions(_ source: ChatView.ReplySource) -> some View {
        switch source {
        case .phone:
            Button("Lokale modeller", systemImage: "arrow.down.circle") {
                setupAfterDismiss = .phone
                showing = false
            }.frame(minHeight: 44).listRowBackground(palette.card)
        case .pc:
            if let pcHint { FadedDetailText(pcHint).listRowBackground(palette.card) }
            if onPCSetup != nil {
                Button(pcSetupTitle, systemImage: "desktopcomputer") {
                    setupAfterDismiss = .pc
                    showing = false
                }.frame(minHeight: 44).listRowBackground(palette.card)
            }
        case .grok:
            EmptyView()
        }
    }

    private func finishSetup() {
        guard let setupAfterDismiss else { return }
        self.setupAfterDismiss = nil
        switch setupAfterDismiss {
        case .phone: onPhoneSetup()
        case .pc: onPCSetup?()
        }
    }

    private func accent(_ source: ChatView.ReplySource) -> Color {
        switch source {
        case .phone: palette.green
        case .pc: palette.cyan
        case .grok: palette.purple
        }
    }
}

extension ChatView {
    @ViewBuilder var chatModelSelectionButton: some View {
        if !demo {
            let route = resolvedRoute
            let current = chatModelCurrentOption(route)
            let hasPCCatalog = api is LiveAPI && !legacyChat
            let pcSetup: (() -> Void)? = hasPCCatalog ? { showPCModelSetup = true } : (api == nil ? reconnectPC : nil)
            ChatModelSelectionButton(
                current: current, options: chatModelOptions, blocked: task != nil,
                pcHint: modelsLoading ? "Henter PC’ens modeller…" : pcEngineOffline ? pcEngineOfflineMessage : modelsError,
                resetTitle: manualRoute == nil ? nil : autoRouterEnabled ? "Brug Auto igen" : "Brug mit normale valg",
                pcSetupTitle: hasPCCatalog ? "Se hele PC-kataloget" : "Forbind til PC",
                onOpen: { composerFocused = false },
                onChoose: { chooseModelForNextMessage($0.source, modelID: $0.modelID) },
                onReset: { manualRoute = nil }, onPhoneSetup: { showPhoneModelSetup = true }, onPCSetup: pcSetup
            )
        }
    }

    private var chatModelOptions: [ChatModelOption] {
        var options = phoneRoutingCandidates.map { ChatModelOption(source: .phone, modelID: $0.id, title: $0.name) }
        let phone = PhoneModels.effectiveModelID(phoneModel)
        if !options.contains(where: { $0.modelID == phone }) {
            options.append(ChatModelOption(source: .phone, modelID: phone, title: phoneModelLabel(for: phone),
                                           available: PhoneModels.isReady(phone)))
        }
        if legacyChat || !(api is LiveAPI) {
            options.append(ChatModelOption(source: .pc, modelID: nil, title: "PC’ens standardmodel",
                                           available: api != nil || canQueuePC))
        } else {
            options.append(contentsOf: models.map {
                ChatModelOption(source: .pc, modelID: $0.id, title: $0.label,
                                available: !pcEngineOffline && !modelsLoading && PCModelSelection.usable($0))
            })
        }
        if cloudKeyAvailable {
            options.append(ChatModelOption(source: .grok, modelID: nil, title: GrokAPI.requestedModelID))
        }
        return options
    }

    private func chatModelCurrentOption(_ route: ResolvedRoute) -> ChatModelOption {
        switch route.source {
        case .phone:
            let id = route.modelID ?? PhoneModels.effectiveModelID(phoneModel)
            return ChatModelOption(source: .phone, modelID: id, title: phoneModelLabel(for: id), available: PhoneModels.isReady(id))
        case .pc:
            let entry = models.first { $0.id == route.modelID }
            let title = entry?.label ?? route.modelID ?? "PC’ens standardmodel"
            let catalogReady = legacyChat || !(api is LiveAPI) || (route.modelID == nil ? !models.isEmpty : entry != nil)
            return ChatModelOption(source: .pc, modelID: route.modelID, title: title,
                                   available: api != nil && !modelsLoading && !pcEngineOffline && catalogReady)
        case .grok:
            return ChatModelOption(source: .grok, modelID: nil, title: GrokAPI.requestedModelID, available: cloudKeyAvailable)
        }
    }
}
