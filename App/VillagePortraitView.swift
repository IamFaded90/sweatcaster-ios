import SwiftUI
import WebKit

enum VillagePortraitIdentity {
    static func name(for bot: VillageBot) -> String? {
        if bot.id == VillageBot.lumiID { return "lumi" }
        return bot.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "harper" ? "harper" : nil
    }
}

/// Native expression frames are driven by the existing audio owner. No extra audio player or timer.
@MainActor struct VillagePortraitView: View {
    let name: String
    let botID: UUID
    var useCubism = false
    @State private var cubismReady = false
    @ObservedObject private var speech = VillageSpeechMotion.shared
    @Environment(\.scenePhase) private var phase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(AppStorageKeys.qolReduceMotion) private var calmMotion = false

    var body: some View {
        let animate = phase == .active && !reduceMotion && !calmMotion
        TimelineView(.animation(minimumInterval: 1.0 / 12, paused: !animate)) { context in
            let frame = mouthFrame(at: context.date, animate: animate)
            let blinking = animate && VillageBlink.closed(id: botID.uuidString, at: context.date)
            portrait(mouthFrame: frame, blinking: blinking)
                .overlay {
                    if useCubism,
                       let url = Bundle.main.url(forResource: name, withExtension: "html", subdirectory: "Village/cubism") {
                        VillageCubismPlayer(url: url, eye: blinking ? 0 : 1,
                                            mouth: animate ? speech.mouth(for: botID.uuidString, at: context.date) : 0,
                                            breath: animate ? 0.5 - 0.5 * cos(context.date.timeIntervalSinceReferenceDate * 1.7) : 0,
                                            ready: $cubismReady)
                            .opacity(cubismReady ? 1 : 0)
                            .allowsHitTesting(false)
                    }
                }
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func portrait(mouthFrame: Int, blinking: Bool) -> some View {
        if let image = VillageProductionArt.portrait(name, expression: mouthFrame == 0 && blinking ? 1 : mouthFrame) {
            Image(uiImage: image).resizable().scaledToFill()
                .overlay {
                    if blinking, mouthFrame != 0,
                       let blink = VillageProductionArt.portrait(name, expression: 1) {
                        Canvas { context, size in
                            // Coordinates from the same 512 × 768 cells used for the Cubism eye layers.
                            let eyes = name == "lumi"
                                ? CGRect(x: 205, y: 208, width: 159, height: 74)
                                : CGRect(x: 168, y: 228, width: 178, height: 66)
                            let scale = max(size.width / 512, size.height / 768)
                            let imageRect = CGRect(x: (size.width - 512 * scale) / 2,
                                                   y: (size.height - 768 * scale) / 2,
                                                   width: 512 * scale, height: 768 * scale)
                            let eyeRect = CGRect(x: imageRect.minX + eyes.minX * scale,
                                                 y: imageRect.minY + eyes.minY * scale,
                                                 width: eyes.width * scale, height: eyes.height * scale)
                            context.clip(to: Path(eyeRect))
                            context.draw(Image(uiImage: blink), in: imageRect)
                        }
                        .allowsHitTesting(false)
                    }
                }
        }
    }

    private func mouthFrame(at date: Date, animate: Bool) -> Int {
        guard animate, speech.isSpeaking(botID.uuidString) else { return 0 }
        let opening = speech.mouth(for: botID.uuidString, at: date)
        if opening > 0.55 { return 3 }
        if opening > 0.12 { return 2 }
        return 0
    }
}

private struct VillageCubismPlayer: UIViewRepresentable {
    let url: URL
    let eye: Double
    let mouth: Double
    let breath: Double
    @Binding var ready: Bool

    func makeCoordinator() -> Coordinator { Coordinator(ready: $ready) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(context.coordinator, name: "cubism")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.isScrollEnabled = false
        view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        guard ready else { return }
        let opening = mouth.isFinite ? min(1, max(0, mouth)) : 0
        let values = SIMD3(eye, opening, breath)
        guard context.coordinator.lastValues != values else { return }
        context.coordinator.lastValues = values
        view.evaluateJavaScript("window.renderPortrait(\(eye), \(opening), \(breath));") { _, _ in }
    }

    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: "cubism")
        view.stopLoading()
    }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        @Binding var ready: Bool
        var lastValues: SIMD3<Double>?

        init(ready: Binding<Bool>) { _ready = ready }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, let state = message.body as? String else { return }
            lastValues = nil
            ready = state == "ready"
        }
    }
}

@MainActor struct VillagePortraitScreen: View {
    let bot: VillageBot
    let name: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.fadedPalette) private var palette

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    VillagePortraitView(name: name, botID: bot.id, useCubism: true)
                        .aspectRatio(2.0 / 3.0, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 28))
                        .accessibilityLabel("Portræt af \(bot.name)")
                    Text(bot.name).font(.largeTitle.bold())
                    Text(bot.specialtyTitle).foregroundStyle(palette.secondary)
                }
                .padding(FadedSpacing.edge).frame(maxWidth: 500).frame(maxWidth: .infinity)
            }
            .background { FadedBackground(variant: .village) }
            .foregroundStyle(palette.text)
            .navigationTitle(bot.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Luk") { dismiss() } } }
        }
    }
}
