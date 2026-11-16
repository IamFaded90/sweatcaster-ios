import SwiftUI

/// Facial anchors belong exclusively to the bundled 96px FadedAI sprite sheets.
/// Profile photographs are never modified or used to choose a village character.
struct VillageSpriteFace: View {
    let artName: String
    let pose: VillageActivity
    let frame: Int
    let direction: Int
    let blink: Bool
    let mouth: Double

    var body: some View {
        Canvas { context, size in
            guard pose != .sleep, !(6...10).contains(direction) else { return }
            let animated = pose == .walk || pose == .work || pose == .talk
            let bob = animated ? sin(Double(frame) * .pi / 4) : 0
            let rest = pose == .rest ? 6.0 : 0
            let y = 45 + bob + rest
            let skin = skinColor
            let ink = Color(red: 24 / 255, green: 38 / 255, blue: 55 / 255)
            context.scaleBy(x: size.width / 96, y: size.height / 96)
            if blink {
                for x in [44.0, 52.0] {
                    context.fill(Path(CGRect(x: x - 2, y: y - 1, width: 5, height: 4)), with: .color(skin))
                    context.fill(Path(CGRect(x: x - 2, y: y + 1, width: 5, height: 1)), with: .color(ink))
                }
            }
            // Original artwork has no mouth; add one at its documented face anchor.
            let opening = max(0, min(1, mouth))
            let rect = CGRect(x: 46, y: 50 + bob + rest, width: 5, height: 1 + opening * 4)
            context.fill(Path(ellipseIn: rect), with: .color(ink))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var skinColor: Color {
        let names = ["adam", "eva", "atlas", "luna", "milo", "iris", "noah", "nova", "saga", "theo"]
        let index = (names.firstIndex(of: artName) ?? 0) % 4
        let colors: [(Double, Double, Double)] = [(217, 181, 154), (185, 132, 104), (227, 189, 158), (152, 115, 91)]
        let color = colors[index]
        return Color(red: color.0 / 255, green: color.1 / 255, blue: color.2 / 255)
    }
}

/// A small view keeps timeline updates out of the large chat body.
@MainActor struct AgentSpeakingStage: View {
    let bot: VillageBot
    var listening = false
    @ObservedObject private var motion = VillageSpeechMotion.shared

    private var figure: VillageLifeBot {
        VillageLifeBot(id: bot.id.uuidString, displayName: bot.name, archetype: .logic,
                       spriteID: "adam", zoneID: .research, activity: .idle, pose: .idle,
                       needs: .balanced, pathProgress: 0, updatedAt: .now)
    }

    var body: some View {
        HStack(spacing: 12) {
            VillageBotSprite(bot: figure, size: 88, animateWalk: true)
                .frame(width: 56, height: 58).clipped()
            VStack(alignment: .leading, spacing: 3) {
                Text(bot.name).font(.subheadline.bold())
                Text(listening ? "Jeg lytter…" : motion.isSpeaking(figure.id) ? "Taler til dig" : "Klar til en snak")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .background { ChatGlassSurface(radius: 18, colors: [FadedBrand.mint, FadedColors.purple]) }
        .accessibilityElement(children: .combine)
    }
}
