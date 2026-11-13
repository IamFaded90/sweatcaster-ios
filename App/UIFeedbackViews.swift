// Loading and retry feedback shared by the app screens.

import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct LoadingSkeleton: View {
    let label: String

    var body: some View { FadedSkeleton(label: label) }
}

struct FadedSkeleton: View {
    var label = "Indlæser…"
    @Environment(\.fadedPalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var phase
    @AppStorage(AppStorageKeys.qolReduceMotion) private var calmMotion = false

    var body: some View {
        VStack(alignment: .leading, spacing: FadedSpacing.s) {
            Text(label).font(.subheadline)
            let paused = reduceMotion || calmMotion || phase != .active
            TimelineView(.animation(minimumInterval: 1.0 / 15, paused: paused)) { context in
                let opacity = paused ? 0.22 : 0.22 + 0.07 * sin(context.date.timeIntervalSinceReferenceDate * 4)
                VStack(alignment: .leading, spacing: FadedSpacing.s) {
                    ForEach([1.0, 0.72, 0.48], id: \.self) { width in
                        RoundedRectangle(cornerRadius: FadedRadius.small)
                            .fill(palette.secondary.opacity(opacity))
                            .frame(height: 12)
                            .scaleEffect(x: width, y: 1, anchor: .leading)
                    }
                }.accessibilityHidden(true)
            }
        }.accessibilityElement(children: .combine)
    }
}

struct FadedToast: View {
    let message: String
    let tone: FadedStatusTone
    @Environment(\.fadedPalette) private var palette

    init(_ message: String, tone: FadedStatusTone = .info) {
        self.message = message
        self.tone = tone
    }

    var body: some View {
        FadedCard(size: .compact, accent: tone.color(in: palette)) {
            Label(message, systemImage: tone.icon)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(palette.text)
                .padding(.leading, FadedSpacing.xs)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }
}

struct FadedCopyErrorButton: View {
    let title: String
    @State private var copied = false

    var body: some View {
        FadedSecondaryButton(copied ? "Fejl kopieret" : "Kopiér fejl",
                             icon: copied ? "checkmark" : "doc.on.doc") {
            UIPasteboard.general.setItems([[UTType.utf8PlainText.identifier: title]], options: [.localOnly: true])
            copied = true
            UIAccessibility.post(notification: .announcement, argument: "Fejl kopieret.")
        }
        .onChange(of: title) { _, _ in copied = false }
        .task(id: copied) {
            guard copied else { return }
            do {
                try await Task.sleep(for: .seconds(2))
                copied = false
            } catch { return }
        }
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
