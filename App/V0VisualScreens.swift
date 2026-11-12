// Visuelle presets fra v0-designet.

import SwiftUI
import UniformTypeIdentifiers

struct V0LookPreset: Equatable, Identifiable, Sendable {
    enum Pattern: String, CaseIterable, Sendable {
        case aurora = "Aurora", grid = "Grid", dots = "Dots", mesh = "Mesh", halo = "Halo"
        case prism = "Prism", ripple = "Ripple", diagonal = "Diagonal", spotlight = "Spotlight", horizon = "Horizon"
    }

    enum Finish: String, CaseIterable, Sendable {
        case glass = "Glass", ink = "Ink", blueprint = "Blueprint", frost = "Frost", outline = "Outline"

        fileprivate var surface: String {
            switch self {
            case .glass: "#151D1D"
            case .ink: "#101313"
            case .blueprint: "#111C27"
            case .frost: "#1C2729"
            case .outline: "#111818"
            }
        }

        fileprivate var borderOpacity: Double {
            switch self {
            case .glass, .ink: 0.18
            case .blueprint: 0.28
            case .frost: 0.32
            case .outline: 0.5
            }
        }
    }

    let pattern: Pattern
    let finish: Finish
    var id: String { name }
    var name: String { "\(pattern.rawValue) \(finish.rawValue)" }
    static let all = Pattern.allCases.flatMap { pattern in Finish.allCases.map { Self(pattern: pattern, finish: $0) } }
    static let auroraGlass = Self(pattern: .aurora, finish: .glass)

    func cardColor(in palette: FadedPalette) -> Color {
        guard palette.theme == .faded else { return palette.card }
        let value = UInt32(finish.surface.dropFirst(), radix: 16) ?? 0x151D1D
        return Color(red: Double((value >> 16) & 255) / 255,
                     green: Double((value >> 8) & 255) / 255,
                     blue: Double(value & 255) / 255)
    }

    func borderColor(in palette: FadedPalette) -> Color {
        guard palette.theme == .faded else { return palette.border }
        return (finish == .blueprint ? FadedBrand.blue : FadedBrand.mint).opacity(finish.borderOpacity)
    }

    @ViewBuilder func background(in palette: FadedPalette) -> some View {
        if palette.theme == .faded { V0LookSurface(preset: self, palette: palette) }
        else { palette.background }
    }

    fileprivate var css: String {
        let art: String
        switch pattern {
        case .aurora: art = "linear-gradient(135deg, #57f2cc33, transparent 55%, #4596fb44)"
        case .grid: art = "linear-gradient(#57f2cc22 1px, transparent 1px), linear-gradient(90deg, #57f2cc22 1px, transparent 1px)"
        case .dots: art = "radial-gradient(#57f2cc55 1px, transparent 1px)"
        case .mesh: art = "radial-gradient(at 0% 0%, #57f2cc33, transparent 55%), radial-gradient(at 100% 100%, #4596fb44, transparent 65%)"
        case .halo: art = "radial-gradient(ellipse at center, transparent 25%, #57f2cc33 43%, transparent 59%)"
        case .prism: art = "linear-gradient(125deg, #57f2cc33, transparent 30%, #4596fb44 60%, transparent 80%)"
        case .ripple: art = "repeating-radial-gradient(circle, transparent 0 18px, #4596fb33 18px 19px, transparent 19px 24px)"
        case .diagonal: art = "repeating-linear-gradient(135deg, transparent 0 18px, #57f2cc22 18px 19px, transparent 19px 24px)"
        case .spotlight: art = "radial-gradient(ellipse at 20% 0%, #57f2cc55, transparent 65%)"
        case .horizon: art = "linear-gradient(0deg, #4596fb44, transparent 58%, #57f2cc22)"
        }
        let size = pattern == .grid || pattern == .dots ? "22px 22px" : "auto"
        let border = finish == .blueprint ? "69, 150, 251" : "87, 242, 204"
        return """
        /* FadedAI · \(name) */
        :root {
          --look-color: \(finish.surface);
          --look-pattern: \(art);
          --look-size: \(size);
          --look-border: rgba(\(border), \(finish.borderOpacity));
        }
        .faded-shell, .faded-card, .glass-dock {
          background-color: var(--look-color);
          background-image: var(--look-pattern);
          background-size: var(--look-size);
          border-color: var(--look-border);
        }
        """
    }
}

private struct V0LookSurface: View {
    let preset: V0LookPreset
    let palette: FadedPalette

    var body: some View {
        ZStack {
            preset.cardColor(in: palette)
            switch preset.pattern {
            case .aurora:
                gradient(.topLeading, .bottomTrailing)
            case .mesh:
                RadialGradient(colors: [FadedBrand.mint.opacity(0.32), .clear], center: .topLeading,
                               startRadius: 0, endRadius: 285)
                RadialGradient(colors: [FadedBrand.blue.opacity(0.36), .clear], center: .bottomTrailing,
                               startRadius: 0, endRadius: 330)
            case .halo:
                RadialGradient(colors: [.clear, FadedBrand.mint.opacity(0.30), .clear], center: .center,
                               startRadius: 45, endRadius: 175)
            case .prism:
                LinearGradient(colors: [FadedBrand.mint.opacity(0.30), .clear, FadedBrand.blue.opacity(0.38), .clear],
                               startPoint: .topTrailing, endPoint: .bottomLeading)
            case .spotlight:
                RadialGradient(colors: [FadedBrand.mint.opacity(0.4), .clear], center: .topLeading,
                               startRadius: 0, endRadius: 340)
            case .horizon:
                gradient(.top, .bottom)
            case .grid, .dots, .diagonal, .ripple:
                patternLines
            }
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    private func gradient(_ start: UnitPoint, _ end: UnitPoint) -> some View {
        LinearGradient(colors: [FadedBrand.mint.opacity(0.25), .clear, FadedBrand.blue.opacity(0.32)],
                       startPoint: start, endPoint: end)
    }

    private var patternLines: some View {
        Canvas { context, size in
            let step: CGFloat = 22
            var path = Path()
            switch preset.pattern {
            case .grid:
                for x in stride(from: CGFloat.zero, to: size.width, by: step) {
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                }
                for y in stride(from: CGFloat.zero, to: size.height, by: step) {
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: size.width, y: y))
                }
            case .dots:
                for x in stride(from: step / 2, to: size.width, by: step) {
                    for y in stride(from: step / 2, to: size.height, by: step) {
                        path.addEllipse(in: CGRect(x: x, y: y, width: 2, height: 2))
                    }
                }
            case .diagonal:
                for x in stride(from: -size.height, to: size.width, by: step) {
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x + size.height, y: size.height))
                }
            case .ripple:
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                for radius in stride(from: step, to: max(size.width, size.height), by: step) {
                    path.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
                }
            default:
                return
            }
            let tint = preset.borderColor(in: palette)
            if preset.pattern == .dots { context.fill(path, with: .color(tint)) }
            else { context.stroke(path, with: .color(tint), lineWidth: 1) }
        }
    }
}

struct V0LookbookView: View {
    @Environment(\.fadedPalette) private var palette
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var localSelection: V0LookPreset?
    @State private var visibleCount = 10
    @State private var exporting = false
    @State private var exportError = false
    private let sharedSelection: Binding<V0LookPreset?>?

    init(selection: Binding<V0LookPreset?>? = nil) { sharedSelection = selection }

    private var selection: Binding<V0LookPreset?> { sharedSelection ?? $localSelection }
    private var active: V0LookPreset? { selection.wrappedValue }
    private var previewPalette: FadedPalette { FadedPalette(theme: .faded) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FadedSpacing.xl) {
                FadedDetailText("10 mønstre × 5 finishes = 50 presets. Premium Dark + Supreme Sky, altid.")
                activeCard
                LazyVGrid(columns: [GridItem(.adaptive(minimum: typeSize.isAccessibilitySize ? 260 : 144),
                                             spacing: FadedSpacing.m)], spacing: FadedSpacing.m) {
                    ForEach(V0LookPreset.all.prefix(visibleCount)) { preset in presetButton(preset) }
                }
                if visibleCount < V0LookPreset.all.count {
                    FadedSecondaryButton("Vis 10 mere", icon: "plus") { visibleCount += 10 }
                }
                if exportError { FadedDetailText("CSS-filen kunne ikke eksporteres. Prøv igen.") }
            }
            .padding(FadedSpacing.l)
            .frame(maxWidth: 580)
            .frame(maxWidth: .infinity)
        }
        .background {
            if let active { active.background(in: palette).ignoresSafeArea() }
            else { FadedBackground() }
        }
        .navigationTitle("Lookbook")
        .fileExporter(isPresented: $exporting, document: active.map { V0LookCSS(text: $0.css) },
                      contentType: V0LookCSS.cssType, defaultFilename: active?.name ?? "FadedAI") { result in
            if case .failure(let error) = result {
                AppDiagnostics.record(error)
                exportError = true
            }
        }
    }

    private var activeCard: some View {
        let shape = RoundedRectangle(cornerRadius: FadedRadius.hero)
        return VStack(alignment: .leading, spacing: FadedSpacing.m) {
            FadedSectionLabel("Dit aktive look")
            Text(active?.name ?? "Original FadedAI")
                .font(.title3.weight(.semibold))
                .foregroundStyle(palette.text)
            if palette.theme != .faded, active != nil {
                FadedDetailText("Skift til Faded-temaet for at anvende dit valg i appen.")
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: FadedSpacing.s) { activeActions }
                VStack(alignment: .leading, spacing: FadedSpacing.s) { activeActions }
            }
        }
        .padding(FadedSpacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if let active { active.background(in: palette).clipShape(shape) }
            else { shape.fill(palette.card) }
        }
        .overlay { shape.strokeBorder(active?.borderColor(in: palette) ?? palette.border).allowsHitTesting(false) }
    }

    @ViewBuilder private var activeActions: some View {
        FadedSecondaryButton("Download CSS", icon: "arrow.down.to.line") {
            exportError = false
            exporting = true
        }
        .disabled(active == nil)
        FadedSecondaryButton("Nulstil", icon: "arrow.counterclockwise") { selection.wrappedValue = nil }
            .disabled(active == nil)
    }

    private func presetButton(_ preset: V0LookPreset) -> some View {
        let selected = active == preset
        let shape = RoundedRectangle(cornerRadius: FadedRadius.card)
        return Button {
            selection.wrappedValue = preset
        } label: {
            VStack(alignment: .leading, spacing: FadedSpacing.s) {
                preset.background(in: previewPalette)
                    .frame(height: 64)
                    .clipShape(.rect(cornerRadius: FadedRadius.medium))
                HStack(spacing: FadedSpacing.s) {
                    Text(preset.name).font(.footnote.weight(.semibold))
                    if selected {
                        Spacer(minLength: 0)
                        Image(systemName: "checkmark.circle.fill").accessibilityHidden(true)
                    }
                }
                .foregroundStyle(palette.text)
            }
            .padding(FadedSpacing.s)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(palette.card, in: shape)
            .overlay { shape.strokeBorder(selected ? FadedBrand.mint : palette.border).allowsHitTesting(false) }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Anvend \(preset.name)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct V0LookCSS: FileDocument {
    static let cssType = UTType(filenameExtension: "css") ?? .plainText
    static let readableContentTypes = [cssType]
    let text: String

    init(text: String) { self.text = text }

    init(configuration: ReadConfiguration) throws {
        guard let bytes = configuration.file.regularFileContents,
              let text = String(data: bytes, encoding: .utf8) else { throw CocoaError(.fileReadCorruptFile) }
        self.text = text
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
