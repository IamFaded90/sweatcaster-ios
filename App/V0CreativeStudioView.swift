// Klargør og eksporterer briefs til de eksisterende video- og billedværksteder.

import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct V0CreativeStudioView: View {
    let openVideo: () -> Void
    let openImages: (String) -> Void

    private enum Page: String, CaseIterable, Identifiable {
        case video = "Video Studio", images = "Billedværksted"
        var id: Self { self }
    }

    private enum Format: String, CaseIterable, Identifiable {
        case portrait = "9:16", square = "1:1", landscape = "16:9"
        var id: Self { self }

        var ratio: CGFloat {
            switch self {
            case .portrait: 9.0 / 16
            case .landscape: 16.0 / 9
            case .square: 1
            }
        }
    }

    private enum Style: String, CaseIterable, Identifiable {
        case cinematic = "Cinematic", calm = "Rolig", hype = "Hype", documentary = "Dokumentar", minimal = "Minimal"
        var id: Self { self }
    }

    private struct Draft {
        var idea = ""
        var format: Format = .portrait
        var style: Style = .cinematic
        var material: [String] = []
    }

    @Environment(\.fadedPalette) private var palette
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var page: Page = .video
    @State private var videoDraft = Draft()
    @State private var imageDraft = Draft()
    @State private var subtitles = true
    @State private var importing = false
    @State private var exporting = false
    @State private var document: V0StudioBriefDocument?
    @State private var prepared: String?
    @State private var notice: String?
    @FocusState private var editingIdea: Bool

    private var draft: Draft { page == .video ? videoDraft : imageDraft }
    private var draftBinding: Binding<Draft> { page == .video ? $videoDraft : $imageDraft }
    private var idea: String { draft.idea.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var ready: Bool { prepared == brief }
    private var canPrepare: Bool { !idea.isEmpty && idea.count <= 2_000 }
    private var brief: String {
        var sections = ["# \(page.rawValue)", "## Din idé\n\(idea)"]
        if !draft.material.isEmpty {
            sections.append("## Materiale\n" + draft.material.map { "- \($0)" }.joined(separator: "\n"))
        }
        var expression = "## Udtryk\n- Format · \(draft.format.rawValue)\n- Stil · \(draft.style.rawValue)"
        if page == .video { expression += "\n- Undertekster · \(subtitles ? "Ja" : "Nej")" }
        sections.append(expression)
        return sections.joined(separator: "\n\n") + "\n"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FadedSpacing.l) {
                pagePicker
                if page == .video { compositionPreview }
                ideaCard
                materialCard
                expressionCard
                if let notice { FadedToast(notice, tone: .info) }
            }
            .padding(FadedSpacing.edge)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .background { FadedBackground() }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Kreativt Studio")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button("Eksportér brief", systemImage: "square.and.arrow.up", action: exportBrief)
                .labelStyle(.iconOnly).disabled(!canPrepare)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { primaryAction }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.movie, .image, .audio, .pdf, .plainText],
                      allowsMultipleSelection: true, onCompletion: importMaterial)
        .fileExporter(isPresented: $exporting, document: document, contentType: V0StudioBriefDocument.contentType,
                      defaultFilename: "fadedai-brief") { result in
            if case .failure(let error) = result {
                AppDiagnostics.record(error)
                notice = "Briefen kunne ikke gemmes. Prøv en anden placering."
            }
        }
    }

    @ViewBuilder private var pagePicker: some View {
        let picker = Picker("Værksted", selection: $page) { ForEach(Page.allCases) { Text($0.rawValue).tag($0) } }
        if typeSize.isAccessibilitySize { picker.pickerStyle(.menu).frame(minHeight: 44) }
        else { picker.pickerStyle(.segmented) }
    }

    private var compositionPreview: some View {
        FadedCard(size: .hero) {
            VStack(spacing: FadedSpacing.m) {
                RoundedRectangle(cornerRadius: FadedRadius.medium)
                    .fill(LinearGradient(colors: [palette.raised, palette.cyan.opacity(0.18), palette.purple.opacity(0.20)],
                                         startPoint: .bottomLeading, endPoint: .topTrailing))
                    .aspectRatio(draft.format.ratio, contentMode: .fit)
                    .frame(maxWidth: 180, maxHeight: 150)
                    .overlay { Image(systemName: "viewfinder").font(.title2).foregroundStyle(palette.secondary) }
                    .accessibilityHidden(true)
                Label("\(draft.format.rawValue) · Kompositionspreview", systemImage: "aspectratio")
                    .font(.footnote.weight(.semibold))
            }.frame(maxWidth: .infinity)
        }
    }

    private var ideaCard: some View {
        FadedCard {
            VStack(alignment: .leading, spacing: FadedSpacing.s) {
                FadedSectionLabel("01 / Din idé")
                TextField(page == .video ? "Hvad skal videoen handle om?" : "Hvad skal billedet forestille?",
                          text: draftBinding.idea, axis: .vertical)
                    .lineLimit(3...6).focused($editingIdea)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var materialCard: some View {
        FadedCard {
            VStack(alignment: .leading, spacing: FadedSpacing.s) {
                FadedSectionLabel("02 / Materiale · valgfrit")
                FadedDetailText("Gem op til 10 filnavne i briefen som reference.")
                ForEach(draft.material, id: \.self) { name in
                    HStack {
                        Text(name).lineLimit(2).truncationMode(.middle)
                        Spacer(minLength: FadedSpacing.s)
                        Button("Fjern \(name)", systemImage: "xmark") {
                            draftBinding.material.wrappedValue = draft.material.filter { $0 != name }
                        }
                            .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                    }
                }
                FadedSecondaryButton("Tilføj filnavne · \(draft.material.count)/10", icon: "paperclip") {
                    editingIdea = false
                    importing = true
                }.disabled(draft.material.count >= 10)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var expressionCard: some View {
        FadedCard {
            VStack(alignment: .leading, spacing: FadedSpacing.s) {
                FadedSectionLabel("03 / Udtryk")
                FadedDetailText("Dine valg følger med, når du eksporterer briefen.")
                Picker("Format", selection: draftBinding.format) { ForEach(Format.allCases) { Text($0.rawValue).tag($0) } }
                Picker("Stil", selection: draftBinding.style) { ForEach(Style.allCases) { Text($0.rawValue).tag($0) } }
                if page == .video { Toggle("Undertekster", isOn: $subtitles) }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var primaryAction: some View {
        VStack(alignment: .leading, spacing: FadedSpacing.s) {
            if ready {
                FadedDetailText(page == .video
                                ? "Brief klar. Brug den som reference, når du vælger klip og opskrift i Video Studio."
                                : "Brief klar. Din idé følger med til billedværkstedet.")
            } else if !canPrepare {
                FadedDetailText(idea.isEmpty ? "Skriv din idé for at klargøre briefen." : "Forkort idéen til højst 2.000 tegn.")
            }
            FadedPrimaryButton(ready ? "Åbn \(page.rawValue)" : "Klargør brief", icon: ready ? "arrow.up.right" : "doc.text") {
                editingIdea = false
                if ready {
                    if page == .video { openVideo() }
                    else { openImages(idea) }
                } else { prepared = brief }
            }.disabled(!canPrepare)
        }
        .padding(FadedSpacing.edge)
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity)
        .background(palette.background)
    }

    private func exportBrief() {
        guard canPrepare else { return }
        editingIdea = false
        document = V0StudioBriefDocument(text: brief)
        exporting = true
    }

    private func importMaterial(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            var material = draft.material
            for url in urls where material.count < 10 {
                let name = url.lastPathComponent.components(separatedBy: .newlines).joined(separator: " ")
                if !name.isEmpty && !material.contains(name) { material.append(name) }
            }
            draftBinding.material.wrappedValue = material
        case .failure(let error):
            AppDiagnostics.record(error)
            notice = "Filnavnene kunne ikke tilføjes. Prøv at vælge dem igen."
        }
    }
}

private struct V0StudioBriefDocument: FileDocument {
    static let contentType = UTType(filenameExtension: "md") ?? .plainText
    static let readableContentTypes = [contentType]
    let text: String

    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              let text = String(data: data, encoding: .utf8) else { throw CocoaError(.fileReadCorruptFile) }
        self.text = text
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
