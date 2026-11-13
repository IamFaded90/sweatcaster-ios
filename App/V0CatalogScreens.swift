// Power Hub samler lokale værktøjer og genveje. Funktionsatlas viser kravene fra v0.

import Foundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct V0PowerHubView: View {
    struct Action: Identifiable {
        let id: String
        let title: String
        let icon: String
        let perform: () -> Void
    }

    let actions: [Action]
    var openLookbook: (() -> Void)? = nil
    var tryAuroraGlass: (() -> Void)? = nil
    var resetAppearance: (() -> Void)? = nil
    var resolveSourceAction: ((String) -> (() -> Void)?)? = nil

    private enum Page: String, CaseIterable, Identifiable {
        case shortcuts = "Genveje", tools = "Værktøjer", appearance = "Visuelt"
        var id: Self { self }
    }

    @Environment(\.dynamicTypeSize) private var typeSize
    @AppStorage(AppStorageKeys.qolReduceMotion) private var calmMotion = false
    @AppStorage(AppStorageKeys.appTextScale) private var textScale = 0.0
    @AppStorage(AppStorageKeys.appearanceTheme) private var theme = FadedTheme.faded
    @AppStorage(AppStorageKeys.appearanceMode) private var appearanceMode = FadedAppearance.system
    @State private var page: Page = .shortcuts
    @State private var selectedTool: V0LocalTool?
    @State private var visibleShortcuts = 10
    @State private var visibleTools = 10
    @State private var category: V0LocalTool.Category?
    @State private var query = ""
    @State private var notice: String?
    @State private var exporting = false
    @State private var exportItem: V0CatalogExport?

    private var pages: [Page] {
        openLookbook != nil || tryAuroraGlass != nil || resetAppearance != nil ? Page.allCases : [.shortcuts, .tools]
    }

    private var shortcuts: [V0HubShortcut] {
        V0HubShortcut.entries.filter { matches($0.title, $0.description, $0.category) }
    }

    private var matchingTools: [V0LocalTool] {
        V0LocalTool.all.filter {
            (category == nil || $0.category == category) && matches($0.title, $0.description, $0.category.rawValue)
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: FadedSpacing.m) {
                pagePicker
                if let notice { FadedToast(notice) }
                if page != .appearance { searchField }
                switch page {
                case .shortcuts: shortcutPage
                case .tools: toolsPage
                case .appearance: appearancePage
                }
            }
            .padding(FadedSpacing.edge)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .background { FadedBackground() }
        .navigationTitle("Power Hub")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: query) { _, _ in visibleShortcuts = 10; visibleTools = 10 }
        .onChange(of: category) { _, _ in visibleTools = 10 }
        .onChange(of: page) { _, _ in query = ""; notice = nil }
        .sheet(item: $selectedTool) { V0LocalToolSheet(tool: $0) }
        .fileExporter(isPresented: $exporting, document: exportItem?.document,
                      contentType: exportItem?.type ?? .plainText, defaultFilename: exportItem?.filename) { result in
            if case .failure = result { notice = "Filen kunne ikke gemmes. Vælg en anden placering, og prøv igen." }
        }
    }

    @ViewBuilder private var pagePicker: some View {
        let picker = Picker("Power Hub", selection: $page) {
            ForEach(pages) { Text($0.rawValue).tag($0) }
        }
        if typeSize.isAccessibilitySize { picker.pickerStyle(.menu).frame(minHeight: 44) }
        else { picker.pickerStyle(.segmented) }
    }

    private var searchField: some View {
        TextField(page == .shortcuts ? "Søg genveje" : "Søg værktøjer", text: $query)
            .textFieldStyle(.roundedBorder)
            .frame(minHeight: 44)
    }

    @ViewBuilder private var shortcutPage: some View {
        let available = shortcuts
        if available.isEmpty && !actions.contains(where: { matches($0.title) }) {
            noMatches
        }
        ForEach(available.prefix(visibleShortcuts)) { entry in
            let action = resolveSourceAction?(entry.id) ?? localAction(entry)
            V0CatalogButton(title: entry.title, detail: action == nil ? unavailableReason(entry) : entry.description,
                            icon: shortcutIcon(entry), action: action)
        }
        if visibleShortcuts < available.count {
            FadedSecondaryButton("Vis 10 mere", icon: "plus") { visibleShortcuts += 10 }
        }
        let native = actions.filter { matches($0.title) }
        if !native.isEmpty {
            FadedSectionLabel("I FadedAI")
            ForEach(native) { action in
                V0CatalogButton(title: action.title, icon: action.icon, action: action.perform)
            }
        }
    }

    @ViewBuilder private var toolsPage: some View {
        FadedDetailText("Tekst, udvikling og beregninger behandles på telefonen.")
        Picker("Værktøjsgruppe", selection: $category) {
            Text("Alle grupper").tag(nil as V0LocalTool.Category?)
            ForEach(V0LocalTool.Category.allCases) { Text($0.rawValue).tag(Optional($0)) }
        }
        .pickerStyle(.menu)
        .frame(minHeight: 44)
        let tools = matchingTools
        if tools.isEmpty { noMatches }
        ForEach(tools.prefix(visibleTools)) { tool in
            V0CatalogButton(title: tool.title, detail: tool.description, icon: tool.category.icon) { selectedTool = tool }
        }
        if visibleTools < tools.count {
            FadedSecondaryButton("Vis 10 mere", icon: "plus") { visibleTools += 10 }
        }
    }

    private var noMatches: some View {
        FadedEmptyState(icon: "magnifyingglass", title: "Ingen resultater", detail: "Prøv en anden søgning.",
                        actionTitle: "Nulstil søgning") { query = ""; category = nil }
    }

    @ViewBuilder private var appearancePage: some View {
        if let tryAuroraGlass {
            V0CatalogButton(title: "Prøv Aurora Glass", icon: "sparkles", action: tryAuroraGlass)
        }
        if let resetAppearance {
            V0CatalogButton(title: "Tilbage til originalt look", icon: "arrow.counterclockwise", action: resetAppearance)
        }
        if let openLookbook {
            V0CatalogButton(title: "Åbn Lookbook", icon: "paintpalette", action: openLookbook)
        }
    }

    private func matches(_ values: String...) -> Bool {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return term.isEmpty || values.contains { $0.localizedCaseInsensitiveContains(term) }
    }

    private func localAction(_ entry: V0HubShortcut) -> (() -> Void)? {
        switch entry.kind {
        case .look:
            return entry.id == "look-aurora" ? tryAuroraGlass : resetAppearance
        case .tool:
            guard let tool = V0LocalTool.all.first(where: { $0.id == entry.value }) else { return nil }
            return { selectedTool = tool }
        case .template:
            return {
                export(Data(entry.value.utf8), as: V0CatalogDocument.markdown,
                       filename: "fadedai-\(entry.id.dropFirst("template-".count))")
            }
        case .preference:
            switch entry.id {
            case "pref-reducedMotion-true": return { calmMotion = true; notice = "Mindre bevægelse er slået til." }
            case "pref-reducedMotion-false": return { calmMotion = false; notice = "FadedAI følger nu iOS’ bevægelsesvalg." }
            case "pref-largeText-true": return { textScale = 1; notice = "Større læsetekst er slået til." }
            case "pref-largeText-false": return { textScale = 0; notice = "FadedAI følger nu iOS’ tekststørrelse." }
            default: return nil
            }
        case .utility:
            switch entry.id {
            case "utility-visuals" where pages.contains(.appearance): return { page = .appearance }
            case "utility-tools": return { page = .tools }
            default: return nil
            }
        case .copy:
            guard entry.id == "copy-date" else { return nil }
            return {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                copyCatalogText(formatter.string(from: .now))
                notice = "UTC-tidspunkt kopieret."
            }
        case .exportFile:
            switch entry.id {
            case "export-notes":
                return {
                    let notes = MigratedAppData.shared.notes
                    guard !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        notice = "Skriv en note i FadedAI først."
                        return
                    }
                    export(Data(notes.utf8), as: V0CatalogDocument.markdown, filename: "fadedai-notes")
                }
            case "export-preferences": return exportPreferences
            default: return nil
            }
        }
    }

    private func shortcutIcon(_ entry: V0HubShortcut) -> String {
        switch entry.kind {
        case .look: "paintpalette"
        case .tool: "wrench.and.screwdriver"
        case .preference: "slider.horizontal.3"
        case .exportFile: "square.and.arrow.down"
        case .copy: "doc.on.doc"
        case .utility: "arrow.up.right.square"
        case .template: "doc.text"
        }
    }

    private func unavailableReason(_ entry: V0HubShortcut) -> String {
        switch entry.kind {
        case .exportFile, .copy: "Afventer adgang til denne type kladde i iPhone-appen."
        case .preference: "Denne indstilling findes foreløbig i v0-forhåndsvisningen."
        case .utility: "Denne genvej afventer en tilsvarende rute i iPhone-appen."
        default: "Afventer en iPhone-tilpasning."
        }
    }

    private func exportPreferences() {
        do {
            let payload: [String: Any] = [
                "theme": theme.rawValue, "appearance": appearanceMode.rawValue,
                "textScale": textScale, "reducedMotion": calmMotion
            ]
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            export(data, as: .json, filename: "fadedai-ui-valg")
        } catch {
            notice = "UI-valgene kunne ikke eksporteres."
        }
    }

    private func export(_ data: Data, as type: UTType, filename: String) {
        exportItem = V0CatalogExport(document: V0CatalogDocument(data: data), type: type, filename: filename)
        exporting = true
    }
}

private struct V0CatalogButton: View {
    @Environment(\.fadedPalette) private var palette
    let title: String
    var detail: String? = nil
    let icon: String
    let action: (() -> Void)?

    var body: some View {
        if let action {
            Button(action: action) { row }
                .buttonStyle(.plain)
        } else {
            row.accessibilityElement(children: .combine)
        }
    }

    private var row: some View {
        FadedCard(size: .compact) {
            HStack(alignment: .center, spacing: FadedSpacing.m) {
                Image(systemName: icon).frame(minWidth: 28).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: FadedSpacing.xs) {
                    Text(title).font(FadedTypography.action)
                    if let detail { FadedDetailText(detail) }
                }
                Spacer(minLength: FadedSpacing.s)
                Image(systemName: action == nil ? "lock" : "chevron.right")
                    .font(.caption.weight(.semibold)).foregroundStyle(palette.secondary).accessibilityHidden(true)
            }
            .foregroundStyle(palette.text)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
    }
}

private struct V0LocalToolSheet: View {
    let tool: V0LocalTool
    @Environment(\.dismiss) private var dismiss
    @State private var values: [String: String] = [:]
    @State private var output: String?
    @State private var failure: String?
    @State private var copied = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    FadedDetailText(tool.description)
                    ForEach(tool.fields, content: field)
                    if !tool.fields.isEmpty {
                        FadedSecondaryButton("Brug eksempel", icon: "lightbulb") { values = tool.example }
                    }
                    FadedPrimaryButton("Vis resultat", action: run)
                    if let failure { FadedToast(failure, tone: .warning) }
                }
                if let output {
                    Section("Resultat") {
                        if output.isEmpty { FadedDetailText("Resultatet er tomt.") }
                        else {
                            Text(verbatim: output).textSelection(.enabled)
                            Button(copied ? "Resultat kopieret" : "Kopiér resultat",
                                   systemImage: copied ? "checkmark" : "doc.on.doc") {
                                copyCatalogText(output)
                                copied = true
                            }
                            .frame(minHeight: 44)
                            ShareLink(item: output) {
                                Label("Del resultat", systemImage: "square.and.arrow.up").frame(minHeight: 44)
                            }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background { FadedBackground() }
            .navigationTitle(tool.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Luk") { dismiss() } }
        }
    }

    @ViewBuilder private func field(_ field: V0LocalTool.Field) -> some View {
        let value = Binding(get: { values[field.id, default: ""] }, set: { values[field.id] = $0 })
        VStack(alignment: .leading, spacing: FadedSpacing.xs) {
            FadedFieldLabel(field.label)
            switch field.kind {
            case .multiline:
                TextEditor(text: value).frame(minHeight: 110).accessibilityLabel(field.label)
            case .text:
                TextField(field.label, text: value).frame(minHeight: 44)
            case .number:
                TextField(field.label, text: value).keyboardType(.numbersAndPunctuation).frame(minHeight: 44)
            }
        }
    }

    private func run() {
        copied = false
        do {
            output = try tool.run(values)
            failure = nil
        } catch {
            output = nil
            failure = error.localizedDescription
        }
    }
}

struct V0FeatureAtlasView: View {
    private enum Origin: String, CaseIterable, Identifiable {
        case all = "Alle", original = "Oprindelige", new = "Nye", favorites = "Mine favoritter"
        var id: Self { self }
    }

    @State private var query = ""
    @State private var area = ""
    @State private var origin: Origin = .all
    @State private var favorites: Set<Int> = []
    @State private var selected: V0AtlasFeature?
    @State private var exporting = false
    @State private var exportDocument: V0CatalogDocument?
    @State private var notice: String?

    private var matching: [V0AtlasFeature] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return V0FeatureAtlasData.entries.filter { feature in
            guard area.isEmpty || feature.area == area else { return false }
            switch origin {
            case .original where feature.origin != "Oprindelig": return false
            case .new where feature.origin != "Ny": return false
            case .favorites where !favorites.contains(feature.id): return false
            default: break
            }
            return term.isEmpty || [feature.title, feature.description, feature.area].contains {
                $0.localizedCaseInsensitiveContains(term)
            }
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: FadedSpacing.m) {
                FadedDetailText("Krav til appen fra v0. Status for backend og iPhone-test verificeres separat.")
                filters
                if let notice { FadedToast(notice, tone: .warning) }
                let features = matching
                FadedSectionLabel("\(features.count) af \(V0FeatureAtlasData.entries.count) krav")
                if features.isEmpty {
                    FadedEmptyState(icon: "magnifyingglass", title: "Ingen krav fundet", detail: "Prøv en anden søgning eller et andet område.",
                                    actionTitle: "Nulstil filtre") { query = ""; area = ""; origin = .all }
                }
                ForEach(features, content: row)
            }
            .padding(FadedSpacing.edge)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .background { FadedBackground() }
        .navigationTitle("Funktionsatlas")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Søg efter en idé eller funktion")
        .toolbar {
            Button("Eksportér overlevering til Claude Code", systemImage: "square.and.arrow.down", action: export)
        }
        .sheet(item: $selected, content: details)
        .fileExporter(isPresented: $exporting, document: exportDocument, contentType: .json,
                      defaultFilename: "fadedai-ui-handoff") { result in
            if case .failure = result { notice = "Overleveringen kunne ikke gemmes. Prøv igen." }
        }
    }

    private var filters: some View {
        VStack(alignment: .leading, spacing: FadedSpacing.xs) {
            Picker("Vis funktioner", selection: $origin) {
                ForEach(Origin.allCases) { value in
                    Text(value == .favorites ? "\(value.rawValue) (\(favorites.count))" : value.rawValue).tag(value)
                }
            }
            .pickerStyle(.menu)
            .frame(minHeight: 44)
            Picker("Område", selection: $area) {
                Text("Alle områder").tag("")
                ForEach(V0FeatureAtlasData.areas, id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.menu)
            .frame(minHeight: 44)
        }
    }

    private func row(_ feature: V0AtlasFeature) -> some View {
        HStack(spacing: FadedSpacing.s) {
            V0CatalogButton(title: "\(String(format: "%02d", feature.id)) · \(feature.title)",
                            detail: feature.area, icon: "list.bullet.rectangle") { selected = feature }
            favoriteButton(feature)
        }
    }

    private func favoriteButton(_ feature: V0AtlasFeature) -> some View {
        let marked = favorites.contains(feature.id)
        return Button {
            if marked { favorites.remove(feature.id) }
            else { favorites.insert(feature.id) }
        } label: {
            Image(systemName: marked ? "star.fill" : "star").frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(marked ? "Fjern \(feature.title) fra favoritter" : "Føj \(feature.title) til favoritter")
    }

    private func details(_ feature: V0AtlasFeature) -> some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: FadedSpacing.m) {
                    FadedSectionHeader(feature.title, detail: "\(feature.origin) · \(feature.area)")
                    Text(feature.description)
                    FadedDetailText(feature.delivery)
                    favoriteButton(feature)
                }
                .padding(FadedSpacing.edge)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .background { FadedBackground() }
            .navigationTitle("Krav \(feature.id)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Luk") { selected = nil } }
        }
        .presentationDetents([.medium, .large])
    }

    private func export() {
        do {
            exportDocument = V0CatalogDocument(data: try V0FeatureAtlasData.handoff())
            notice = nil
            exporting = true
        } catch {
            notice = "Overleveringen kunne ikke klargøres. Prøv igen."
        }
    }
}

private struct V0CatalogExport {
    let document: V0CatalogDocument
    let type: UTType
    let filename: String
}

private struct V0CatalogDocument: FileDocument {
    static let markdown = UTType(filenameExtension: "md") ?? .plainText
    static let readableContentTypes: [UTType] = [.plainText, .json, markdown]
    let data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

@MainActor private func copyCatalogText(_ text: String) {
    UIPasteboard.general.setItems([[UTType.utf8PlainText.identifier: text]], options: [.localOnly: true])
}
