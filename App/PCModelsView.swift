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
        entry.available && entry.capabilities.contains("chat")
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
                FadedDetailText("Vælg den model, PC’en skal bruge næste gang du sender en chatbesked.")
                modelContent
            }
            .padding(FadedSpacing.edge).frame(maxWidth: 640).frame(maxWidth: .infinity)
        }
        .background { FadedBackground() }
        .foregroundStyle(palette.text)
        .navigationTitle("PC-modeller")
        .navigationBarTitleDisplayMode(.inline)
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
        } else if let catalog, catalog.models.isEmpty {
            FadedEmptyState(icon: "cpu", title: "Ingen modeller at vise",
                            detail: "Kontrollér, at en model er installeret på PC’en, og opdatér listen.",
                            actionTitle: "Opdatér modeller") { Task { await refresh() } }
        } else if let catalog {
            if !selected.isEmpty && !catalog.models.contains(where: { $0.id == selected && PCModelSelection.usable($0) }) {
                Text("Den tidligere valgte model er utilgængelig. Vælg en installeret chatmodel, hvis der er en klar.")
                    .font(.footnote).foregroundStyle(palette.secondary)
            }
            ForEach(catalog.models) { model in modelCard(model, standard: model.id == catalog.default_model_id) }
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
                Label(model.available ? "Installeret" : "Ikke installeret",
                      systemImage: model.available ? "checkmark.circle" : "circle.dashed")
                    .font(.subheadline).foregroundStyle(palette.secondary)
                if model.loaded { Label("Indlæst på PC’en", systemImage: "bolt.fill").font(.subheadline) }
                if standard { Text("Standard på PC’en").font(.caption).foregroundStyle(palette.secondary) }
                if chosen {
                    Label("Valgt til næste chat", systemImage: "checkmark.circle.fill").font(.subheadline)
                } else if usable {
                    FadedSecondaryButton("Vælg til chat", icon: "bubble.left") { selected = model.id }
                        .disabled(requestID != nil)
                        .accessibilityLabel("Vælg \(model.label) til chat")
                } else if model.available {
                    Text("PC’en tilbyder ikke denne model til chat.").font(.caption).foregroundStyle(palette.secondary)
                }
            }
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
            var seen = Set<String>()
            loadedTargetID = api.queueTargetID
            catalog = V2Models(default_model_id: result.default_model_id,
                               models: result.models.filter { !$0.id.isEmpty && seen.insert($0.id).inserted })
        } catch is CancellationError {
            return
        } catch {
            AppDiagnostics.record(error)
            guard !Task.isCancelled, requestID == id else { return }
            loadedTargetID = api.queueTargetID
            catalog = nil
            if case .http(status: 401, code: _, message: _)? = error as? V2Failure {
                notice = "PC’en afviste tokenet. Kontrollér forbindelsen i Indstillinger."
            } else if case .http(let status, _, _)? = error as? V2Failure, [404, 405, 501].contains(status) {
                notice = "PC-serveren tilbyder endnu ingen modeloversigt."
            } else {
                notice = pcBusyMessage(error) ?? "PC’ens modeller kunne ikke hentes. Kontrollér forbindelsen, og prøv igen."
            }
        }
    }
}
