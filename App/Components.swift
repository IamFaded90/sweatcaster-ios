import SwiftUI
import UIKit

struct FadedSignature: View {
    var body: some View {
        LinearGradient(colors: [FadedColors.lime, FadedColors.cyan, FadedColors.purple],
                       startPoint: .leading, endPoint: .trailing)
            .frame(height: 2)
            .opacity(0.6)
            .accessibilityHidden(true)
    }
}

struct FadedSectionLabel: View {
    let title: String
    @Environment(\.fadedPalette) private var palette

    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title.uppercased()).font(FadedTypography.section).tracking(0.8)
            .foregroundStyle(palette.secondary).accessibilityAddTraits(.isHeader)
    }
}

struct FadedFieldLabel: View {
    let title: String
    @Environment(\.fadedPalette) private var palette

    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(palette.text)
            .accessibilityHidden(true)
    }
}

struct FadedDetailText: View {
    let text: String
    @Environment(\.fadedPalette) private var palette

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(.footnote).foregroundStyle(palette.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct FadedSectionHeader: View {
    let title: String
    let detail: String?

    init(_ title: String, detail: String? = nil) {
        self.title = title
        self.detail = detail
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            FadedSectionLabel(title)
            if let detail { FadedDetailText(detail) }
        }
    }
}

struct FadedButtonStyle: ButtonStyle {
    enum Kind: Equatable { case primary, secondary, destructive }

    let kind: Kind
    @Environment(\.fadedPalette) private var palette
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(AppStorageKeys.qolHaptics) private var haptics = true
    @AppStorage(AppStorageKeys.qolReduceMotion) private var calmMotion = false

    private var primary: Bool { kind == .primary }
    private var destructive: Bool { kind == .destructive }

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: primary ? FadedRadius.primary : FadedRadius.small)
        let fill = !enabled ? palette.border : primary ? palette.lime : palette.raised
        let text = !enabled ? palette.secondary : primary ? FadedColors.deep : destructive ? palette.coralText : palette.text
        configuration.label
            .font(FadedTypography.action)
            .padding(.horizontal, 12)
            .frame(minHeight: primary ? 52 : 44)
            .foregroundStyle(text)
            .background(fill, in: shape)
            .overlay { shape.strokeBorder(destructive && enabled ? palette.coral : palette.border, lineWidth: primary && enabled ? 0 : 1) }
            .shadow(color: enabled && primary ? palette.lime.opacity(0.25) : .clear, radius: 12, y: 4)
            .scaleEffect(enabled && configuration.isPressed && !reduceMotion && !calmMotion ? 0.97 : 1)
            .animation(reduceMotion || calmMotion ? nil : .easeOut(duration: 0.1), value: configuration.isPressed)
            .sensoryFeedback(.impact(weight: primary ? .medium : .light), trigger: configuration.isPressed) { _, pressed in
                haptics && enabled && pressed
            }
    }
}

struct FadedPrimaryButton: View {
    let title: String
    let icon: String?
    let action: () -> Void

    init(_ title: String, icon: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Group {
                if let icon { Label(title, systemImage: icon) }
                else { Text(title) }
            }.frame(maxWidth: .infinity)
        }.buttonStyle(FadedButtonStyle(kind: .primary))
    }
}

struct FadedSecondaryButton: View {
    let title: String
    let icon: String?
    let role: ButtonRole?
    let action: () -> Void

    init(_ title: String, icon: String? = nil, role: ButtonRole? = nil, action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.role = role
        self.action = action
    }

    var body: some View {
        Button(role: role, action: action) {
            if let icon { Label(title, systemImage: icon) }
            else { Text(title) }
        }.buttonStyle(FadedButtonStyle(kind: role == .destructive ? .destructive : .secondary))
    }
}

enum FadedCardSize {
    case compact, standard, hero

    var inset: CGFloat {
        switch self {
        case .compact: FadedSpacing.s
        case .standard: FadedSpacing.m
        case .hero: FadedSpacing.l
        }
    }

    var radius: CGFloat {
        switch self {
        case .compact: FadedRadius.medium
        case .standard: FadedRadius.card
        case .hero: FadedRadius.hero
        }
    }
}

struct FadedCard<Content: View>: View {
    let size: FadedCardSize
    let accent: Color?
    let content: Content
    @Environment(\.fadedPalette) private var palette

    init(size: FadedCardSize = .standard, accent: Color? = nil, @ViewBuilder content: () -> Content) {
        self.size = size
        self.accent = accent
        self.content = content()
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size.radius)
        content
            .padding(size.inset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.card, in: shape)
            .overlay(alignment: .leading) {
                if let accent { Rectangle().fill(accent).frame(width: FadedSpacing.xs).accessibilityHidden(true) }
            }
            .clipShape(shape)
            .overlay { shape.strokeBorder(palette.border, lineWidth: 1).allowsHitTesting(false) }
            .shadow(color: .black.opacity(palette.isDark ? 0.35 : 0.08), radius: 12, y: 6)
    }
}

enum FadedStatusTone {
    case success, info, warning, error

    func color(in palette: FadedPalette) -> Color {
        switch self {
        case .success: palette.green
        case .info: palette.cyan
        case .warning: palette.lime
        case .error: palette.coral
        }
    }

    var icon: String {
        switch self {
        case .success: "checkmark.circle.fill"
        case .info: "info.circle"
        case .warning: "exclamationmark.triangle"
        case .error: "exclamationmark.circle.fill"
        }
    }
}

struct FadedBadge: View {
    let title: String
    let tone: FadedStatusTone
    @Environment(\.fadedPalette) private var palette

    init(_ title: String, tone: FadedStatusTone) {
        self.title = title
        self.tone = tone
    }

    var body: some View {
        let accent = tone.color(in: palette)
        Label(title, systemImage: tone.icon)
            .font(.caption.weight(.semibold))
            .foregroundStyle(palette.isDark ? accent : palette.text)
            .padding(.horizontal, FadedSpacing.s)
            .padding(.vertical, FadedSpacing.xs)
            .background(accent.opacity(palette.isDark ? 0.13 : 0.22), in: Capsule())
            .accessibilityLabel(title)
    }
}

struct FadedChip: View {
    let title: String
    let accent: Color
    let selected: Bool
    let icon: String?
    let action: () -> Void
    @Environment(\.fadedPalette) private var palette
    @AppStorage(AppStorageKeys.qolHaptics) private var haptics = true

    init(_ title: String, accent: Color, selected: Bool, icon: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.accent = accent
        self.selected = selected
        self.icon = icon
        self.action = action
    }

    var body: some View {
        Button {
            if haptics && !selected { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
            action()
        } label: {
            Group {
                if let icon { Label(title, systemImage: icon) }
                else { Text(title) }
            }
            .font(.system(.subheadline, design: .rounded).weight(.semibold))
            .foregroundStyle(selected ? FadedColors.deep : palette.text)
            .padding(.horizontal, 12).frame(minHeight: 32)
            .background(selected ? accent : palette.card, in: Capsule())
            .overlay { Capsule().strokeBorder(selected ? accent : palette.border, lineWidth: 1) }
            .frame(minHeight: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct FadedProgress: View {
    let value: Double
    var failed = false
    @Environment(\.fadedPalette) private var palette

    private var progress: Double { value.isFinite ? min(1, max(0, value)) : 0 }

    var body: some View {
        GeometryReader { geometry in
            Capsule().fill(palette.border)
                .overlay(alignment: .leading) {
                    Capsule().fill(LinearGradient(colors: failed ? [palette.coral, palette.coral] : [palette.lime, palette.cyan],
                                                  startPoint: .leading, endPoint: .trailing))
                        .frame(width: geometry.size.width * (failed ? 1 : progress))
                }
        }
        .frame(height: 8)
        .accessibilityLabel("Fremdrift")
        .accessibilityValue(failed ? "Fejlet" : progress.formatted(.percent.precision(.fractionLength(0))))
    }
}

// Shared video status for Home and Video Studio. Progress represents PC job stages.
struct VideoJobStatusLine: View {
    let status: Stage
    let progress: Double
    let isCurrent: Bool
    let accent: Color
    var updatedAt: Date? = nil
    var outputAvailable = false
    var failureDetail: String? = nil
    @Environment(\.fadedPalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: FadedSpacing.xs) {
            if !isCurrent { FadedDetailText("Sidst set på PC’en") }
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(palette.isDark ? accent : palette.text)
            if isCurrent || status == .failed { FadedDetailText(detail) }
            if status.active {
                FadedProgress(value: progress).accessibilityHidden(true)
                if progress.isFinite, (0...1).contains(progress) {
                    Text("Fremdrift \(progress.formatted(.percent.precision(.fractionLength(0))))")
                        .font(.caption.monospacedDigit()).foregroundStyle(palette.secondary)
                }
            }
            if let updatedAt {
                Text("Seneste status \(updatedAt, format: .dateTime.day().month().hour().minute())")
                    .font(.caption).foregroundStyle(palette.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        if status == .completed { return outputAvailable ? "Klar til afspilning" : "Videofilen er ikke tilgængelig" }
        return status.title
    }

    private var icon: String {
        switch status {
        case .queued: "clock"
        case .analyzing: "film"
        case .commentating: "text.bubble"
        case .synthesizing: "waveform"
        case .rendering: "film.stack"
        case .completed: "checkmark.circle"
        case .failed: "exclamationmark.circle"
        case .cancelled: "stop.circle"
        }
    }

    private var detail: String {
        switch status {
        case .queued: "PC’en har modtaget jobbet. Det venter på sin tur."
        case .analyzing: "PC’en gennemgår klippet før redigeringen."
        case .commentating: "PC’en skriver en kommentar ud fra klippet."
        case .synthesizing: "Kommentaren bliver lavet om til lyd."
        case .rendering: "PC’en samler billede og lyd til den færdige video."
        case .completed: outputAvailable ? "Åbn videoen herfra." : "PC’en melder jobbet færdigt, men har ingen videofil at afspille."
        case .failed: failureDetail ?? "PC’en kunne ikke gøre videoen færdig."
        case .cancelled: "PC’en har stoppet jobbet."
        }
    }
}

struct FadedEmptyState: View {
    let icon: String
    let title: String
    let detail: String
    let actionTitle: String?
    let action: (() -> Void)?
    @Environment(\.fadedPalette) private var palette
    @ScaledMetric(relativeTo: .title) private var iconSize = 48.0

    init(icon: String, title: String, detail: String, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        self.icon = icon
        self.title = title
        self.detail = detail
        self.actionTitle = actionTitle
        self.action = action
    }

    var body: some View {
        FadedCard {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: icon).font(.system(size: iconSize)).foregroundStyle(palette.secondary)
                    .accessibilityHidden(true)
                Text(title).font(FadedTypography.title).tracking(-0.5).accessibilityAddTraits(.isHeader)
                Text(detail).font(FadedTypography.body).foregroundStyle(palette.secondary)
                if let actionTitle, let action {
                    FadedSecondaryButton(actionTitle, action: action)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct FadedDiff: View {
    let diff: String

    private var coloredDiff: AttributedString {
        var text = AttributedString()
        for row in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = AttributedString(String(row) + "\n")
            if row.hasPrefix("+") && !row.hasPrefix("+++") { line.foregroundColor = FadedColors.green }
            else if row.hasPrefix("-") && !row.hasPrefix("---") { line.foregroundColor = FadedColors.coral }
            else { line.foregroundColor = FadedColors.secondary }
            text += line
        }
        return text
    }

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            Text(coloredDiff).font(FadedTypography.code).lineSpacing(4).textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: true).padding(12)
        }
        .frame(minHeight: 100, maxHeight: 260)
        .background(FadedColors.terminal, in: RoundedRectangle(cornerRadius: FadedRadius.small))
        .overlay { RoundedRectangle(cornerRadius: FadedRadius.small).strokeBorder(FadedColors.border).allowsHitTesting(false) }
    }
}

struct FadedJobFeedback: ViewModifier {
    let status: Stage
    @Environment(\.fadedPalette) private var palette
    @Environment(\.scenePhase) private var phase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(AppStorageKeys.qolReduceMotion) private var calmMotion = false
    @State private var signal: Stage?
    @State private var flash = false
    @State private var offset: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .offset(x: offset)
            .overlay {
                RoundedRectangle(cornerRadius: FadedRadius.card)
                    .strokeBorder(signal == .failed ? palette.coral : palette.lime, lineWidth: 2)
                    .opacity(flash ? 1 : 0).allowsHitTesting(false).accessibilityHidden(true)
            }
            .onChange(of: status) { _, current in
                guard phase == .active, current == .completed || current == .failed else { return }
                signal = current
            }
            .onChange(of: phase) { _, current in
                if current != .active { signal = nil; flash = false; offset = 0 }
            }
            .task(id: signal) { await animate() }
    }

    private func animate() async {
        guard let signal, phase == .active else { return }
        let scale = calmMotion ? 2.0 : 1.0
        flash = true
        if signal == .failed && !reduceMotion && !calmMotion {
            let steps: [CGFloat] = [-4, 4, -4, 4, 0]
            for step in steps {
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.055 * scale)) { offset = step }
                do { try await Task.sleep(for: .seconds(0.055 * scale)) } catch { return }
            }
        } else {
            do { try await Task.sleep(for: .seconds(0.18 * scale)) } catch { return }
        }
        withAnimation(.easeOut(duration: 0.12 * scale)) { flash = false; offset = 0 }
    }
}
