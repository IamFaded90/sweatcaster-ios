// Loading and retry feedback shared by the app screens.

import SwiftUI

struct LoadingSkeleton: View {
    let label: String
    @Environment(\.fadedPalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var phase
    @AppStorage(AppStorageKeys.qolReduceMotion) private var calmMotion = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(.subheadline)
            let paused = reduceMotion || calmMotion || phase != .active
            TimelineView(.animation(minimumInterval: 1.0 / 15, paused: paused)) { context in
                let opacity = paused ? 0.22 : 0.22 + 0.07 * sin(context.date.timeIntervalSinceReferenceDate * 4)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach([1.0, 0.72, 0.48], id: \.self) { width in
                        RoundedRectangle(cornerRadius: 6)
                            .fill(palette.secondary.opacity(opacity))
                            .frame(height: 12)
                            .scaleEffect(x: width, y: 1, anchor: .leading)
                    }
                }.accessibilityHidden(true)
            }
        }.accessibilityElement(children: .combine)
    }
}

struct RetryNotice: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message)
            FadedSecondaryButton("Prøv igen", icon: "arrow.clockwise", action: retry)
        }
    }
}
