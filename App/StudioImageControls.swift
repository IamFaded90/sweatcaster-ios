import SwiftUI
import UIKit

enum StudioPCImageModel: String, CaseIterable, Identifiable {
    case realvis, pony, flux2, flux2Adult = "flux2-adult"
    var id: Self { self }
    var isFlux: Bool { self == .flux2 || self == .flux2Adult }
    var title: String {
        switch self {
        case .realvis: "RealVisXL"
        case .pony: "CyberRealistic Pony · voksen"
        case .flux2: "FLUX 2 · redigering"
        case .flux2Adult: "FLUX 2 · voksen"
        }
    }
}

enum StudioPCImageCatalog {
    case checking
    case unreachable
    case available(flux: Bool, adult: Bool, pony: Bool)

    static func inspect(_ api: LiveAPI) async -> Self {
        do {
            let (flux, adult, pony) = try await api.privateStudioFluxAvailable()
            return .available(flux: flux, adult: adult, pony: pony)
        } catch {
            return .unreachable
        }
    }

    func allows(_ model: StudioPCImageModel) -> Bool {
        // Preserve access to the old RealVisXL route on existing PC installs.
        if model == .realvis { return true }
        guard case let .available(flux, adult, pony) = self else { return false }
        switch model {
        case .realvis: return true
        case .flux2: return flux
        case .flux2Adult: return adult
        case .pony: return pony
        }
    }

    var showsRetry: Bool {
        switch self {
        case .checking: return false
        case .unreachable: return true
        case let .available(flux, adult, pony): return !flux || !adult || !pony
        }
    }

    func blocker(for model: StudioPCImageModel) -> String? {
        guard !allows(model) else { return nil }
        switch self {
        case .checking: return "Tjekker billedmodeller på PC’en…"
        case .unreachable: return "Kunne ikke tjekke modellerne. Tjek forbindelsen til PC’en."
        case .available: return "\(model.title) er ikke klar. Tjek billedmotoren, eller vælg en anden model."
        }
    }
}

struct StudioPCImageModelPicker: View {
    @Binding var selection: StudioPCImageModel
    let catalog: StudioPCImageCatalog
    let refresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("Billedmodel på PC", selection: $selection) {
                ForEach(StudioPCImageModel.allCases) { model in
                    Text(model.title + (catalog.allows(model) ? "" : " · ikke klar"))
                        .tag(model)
                        .disabled(!catalog.allows(model))
                }
            }
            .pickerStyle(.menu)
            .frame(minHeight: 44)
            if catalog.showsRetry {
                Button("Kontrollér PC igen", systemImage: "arrow.clockwise", action: refresh)
                    .frame(minHeight: 44)
            }
        }
    }
}

extension OfflineStudio {
    var privateImageControls: some View {
        let request = studioImageRequest
        return VStack(alignment: .leading, spacing: 8) {
            privateImageModelMenu(current: request.model)
            if request.route == .pc, let api = privateImagePC {
                privatePCModelPicker
                PCImageEngineStatusRow(api: api, refreshCount: pcImageRefresh)
                FadedDetailText(baseImage == nil
                                ? "Beskrivelsen sendes til din parrede PC."
                                : "Beskrivelsen og referencebilledet sendes til din parrede PC, når du laver billedet.")
            }
            if imagePromptFocused && baseImage == nil { imagePromptSuggestions }
            imageReferencePicker
            if baseImage != nil { privateReferenceOptions }
            if let blocker = imageBlocker(for: request) {
                FadedDetailText(blocker).accessibilityAddTraits(.updatesFrequently)
            }
            if task != nil {
                FadedSecondaryButton("Stop billedkø", icon: "stop.fill") { stopStudioImageQueue() }
            }
            if privateImagePC != nil {
                FadedSecondaryButton("Åbn Video på PC", icon: "film") { openPrivateVideo() }
                    .disabled(task != nil)
            }
        }
    }

    func openPrivateVideo(from result: URL? = nil) {
        guard privateSession, canShowStudio, privateImagePC != nil, task == nil else { return }
        imagePromptFocused = false
        promptFocused = false
        privateVideoSource = result
        resetIdleTimer()
        showPrivateVideo = true
    }

    var imagePromptSuggestions: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(["masterpiece", "cinematic", "blødt lys", "detaljeret"], id: \.self) { suggestion in
                    Button(suggestion) {
                        let current = imagePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
                        let combined = current.isEmpty ? suggestion : current + ", " + suggestion
                        if combined.count <= 2_000 { imagePrompt = combined }
                    }.buttonStyle(.bordered).frame(minHeight: 44)
                        .accessibilityLabel("Tilføj \(suggestion) til prompt")
                }
            }
        }.scrollIndicators(.hidden)
    }
}

@MainActor struct StudioReferenceMaskEditor: View {
    let photo: UIImage
    let onActivity: () -> Void
    let onApply: (StudioReferenceMask?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var draft: StudioReferenceMask
    @State private var dragging = false

    init(photo: UIImage, mask: StudioReferenceMask?, onActivity: @escaping () -> Void,
         onApply: @escaping (StudioReferenceMask?) -> Void) {
        self.photo = photo
        self.onActivity = onActivity
        self.onApply = onApply
        _draft = State(initialValue: mask ?? StudioReferenceMask())
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                FadedDetailText("Mal hen over det, du vil ændre. Lad resten af billedet være umarkeret.")
                GeometryReader { proxy in
                    let width = min(proxy.size.width, proxy.size.height * photo.size.width / photo.size.height)
                    let size = CGSize(width: width, height: width * photo.size.height / photo.size.width)
                    Image(uiImage: photo).resizable().frame(width: size.width, height: size.height)
                        .overlay { StudioReferenceMaskOverlay(mask: draft) }
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                            addPoint(value.location, in: size)
                        }.onEnded { _ in dragging = false })
                        .clipShape(.rect(cornerRadius: 12))
                        .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
                        .accessibilityLabel("Tegn på referencebilledet")
                }
                HStack {
                    Button("Fortryd streg", systemImage: "arrow.uturn.backward") {
                        if !draft.isEmpty { draft.strokes.removeLast() }
                    }
                    Spacer()
                    Button("Ryd", role: .destructive) { draft.strokes.removeAll() }
                }
                .disabled(draft.isEmpty)
                .buttonStyle(.bordered)
            }
            .padding(FadedSpacing.edge)
            .navigationTitle("Markér området")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annullér") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(draft.isEmpty ? "Uden markering" : "Brug markering") {
                        onApply(draft.isEmpty ? nil : draft)
                        dismiss()
                    }
                }
            }
        }
    }

    private func addPoint(_ point: CGPoint, in size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let p = CGPoint(x: min(1, max(0, point.x / size.width)), y: min(1, max(0, point.y / size.height)))
        if !dragging {
            guard draft.strokes.count < 128 else { return }
            onActivity()
            draft.strokes.append([p])
            dragging = true
        } else if let index = draft.strokes.indices.last, draft.strokes[index].count < 512 {
            if let last = draft.strokes[index].last, hypot(last.x - p.x, last.y - p.y) >= 0.005 {
                draft.strokes[index].append(p)
            }
        }
    }
}

struct StudioReferenceMaskOverlay: View {
    let mask: StudioReferenceMask

    var body: some View {
        Canvas { context, size in
            let brush = StudioReferenceMask.brushWidth * min(size.width, size.height)
            for stroke in mask.strokes {
                let points = stroke.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }
                guard let first = points.first else { continue }
                let color = Color.mint.opacity(0.65)
                if points.count == 1 {
                    let dot = CGRect(x: first.x - brush / 2, y: first.y - brush / 2, width: brush, height: brush)
                    context.fill(Path(ellipseIn: dot), with: .color(color))
                } else {
                    var path = Path()
                    path.addLines(points)
                    context.stroke(path, with: .color(color),
                                   style: StrokeStyle(lineWidth: brush, lineCap: .round, lineJoin: .round))
                }
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}
