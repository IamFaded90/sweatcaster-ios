import Foundation
import SwiftUI

enum PCModelSelection {
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
    @Environment(\.fadedPalette) private var palette
    @AppStorage private var selected: String
    @State private var catalog: V2Models?
    @State private var notice: String?
    @State private var loadedTargetID: String?
    @State private var requestID: UUID?

    init(api: LiveAPI?) {
        self.api = api
        _selected = AppStorage(wrappedValue: "", PCModelSelection.key(for: api))
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: FadedSpacing.action) {
                FadedSignature()
                FadedDetailText("Vælg din foretrukne model til PC-chat. PC’en indlæser modellen ved brug. Auto kan vælge en anden model til opgaven.")
                modelContent
                cloudCard
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
            LoadingSkeleton(label: "Henter modeller fra PC’en…")
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
            if !selected.isEmpty && !catalog.models.contains(where: { $0.id == selected && PCModelSelection.usable($0) }) {
                Text("Den tidligere valgte model er utilgængelig. Vælg en installeret chatmodel, hvis der er en klar.")
                    .font(.footnote).foregroundStyle(palette.secondary)
            }
            ForEach(PCModelSelection.advertised(in: catalog)) { model in
                modelCard(model, standard: model.id == catalog.default_model_id)
            }
        } else {
            LoadingSkeleton(label: "Henter modeller fra PC’en…")
        }
    }

    private func modelCard(_ model: V2Models.Entry, standard: Bool) -> some View {
        let usable = PCModelSelection.usable(model)
        let chosen = usable && selected == model.id
        return FadedCard(accent: chosen ? palette.lime : model.loaded ? palette.cyan : nil) {
            VStack(alignment: .leading, spacing: 8) {
                Label(model.label, systemImage: "cpu").font(FadedTypography.section).accessibilityAddTraits(.isHeader)
                FadedBadge(model.available ? (model.loaded ? "Indlæst på PC" : "Tilgængelig på PC") : "Utilgængelig på PC",
                           tone: model.available ? .success : .warning)
                if let bytes = model.size_bytes, bytes > 0 {
                    FadedDetailText(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                }
                FadedDetailText(modelDetail(model))
                if standard { Text("Standard på PC’en").font(.caption).foregroundStyle(palette.secondary) }
                if chosen {
                    Label("Foretrukken til PC-chat", systemImage: "checkmark.circle.fill").font(.subheadline)
                } else if usable {
                    FadedSecondaryButton("Vælg til chat", icon: "bubble.left") { selected = model.id }
                        .disabled(requestID != nil)
                        .accessibilityLabel("Vælg \(model.label) til chat")
                }
            }
        }
    }

    private func modelDetail(_ model: V2Models.Entry) -> String {
        if !model.available { return "Kontrollér modellens installation eller opsætning på PC’en." }
        if model.supportsImageChat {
            return PCModelSelection.usable(model) ? "Til tekstchat og billedanalyse." : "Brug modellen via Analysér billede i chatten."
        }
        if !PCModelSelection.usable(model) { return "PC’en tilbyder denne model til andre opgaver end tekstchat." }
        if model.capabilities.contains(where: { $0 == "code" || $0 == "coding" }) { return "Til tekstchat og kode." }
        if model.capabilities.contains("long_context") { return "Til tekstchat med længere kontekst." }
        return "Til tekstchat på PC’en."
    }

    private var cloudCard: some View {
        FadedCard(accent: palette.purple) {
            VStack(alignment: .leading, spacing: FadedSpacing.s) {
                FadedSectionHeader("Grok", detail: "Separat cloud-destination via xAI. Vælg Grok direkte i AI-chat.")
                FadedBadge(CloudModelKey.exists() ? "xAI-nøgle gemt" : "Kræver xAI-nøgle", tone: .info)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
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
