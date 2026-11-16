import Lottie
import SwiftUI

/// A bundled, original animation: no remote assets or tracking.
@MainActor struct FadedThinkingIndicator: View {
    @Environment(\.scenePhase) private var phase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(AppStorageKeys.qolReduceMotion) private var appReduceMotion = false
    @State private var visible = false
    let title: String
    private static let animation = LottieAnimation.named("FadedThinking")

    var body: some View {
        HStack(spacing: 8) {
            if let animation = Self.animation {
                if phase == .active && visible && !reduceMotion && !appReduceMotion {
                    LottieView(animation: animation).looping().resizable().frame(width: 40, height: 20)
                        .accessibilityHidden(true)
                } else {
                    LottieView(animation: animation).paused(at: .progress(0.5)).resizable()
                        .frame(width: 40, height: 20).accessibilityHidden(true)
                }
            } else {
                Image(systemName: "ellipsis").accessibilityHidden(true)
            }
            Text(title).font(.callout)
        }
        .accessibilityElement(children: .ignore).accessibilityLabel(title)
        .onAppear { visible = true }
        .onDisappear { visible = false }
    }
}
