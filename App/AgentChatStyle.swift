import BorderBeam
import SwiftUI

/// Shared with the main chat's glass surface, transcript renderer and source colors.
struct AgentChatBubble<Content: View>: View {
    @Environment(\.fadedPalette) private var palette
    let user: Bool
    let title: String
    let pc: Bool
    let content: Content

    init(user: Bool, title: String, pc: Bool, @ViewBuilder content: () -> Content) {
        self.user = user
        self.title = title
        self.pc = pc
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if user { Spacer(minLength: 40) }
            VStack(alignment: user ? .trailing : .leading, spacing: 8) {
                Label(title, systemImage: user ? "person.crop.circle.fill" : pc ? "desktopcomputer" : "iphone")
                    .font(.caption.bold())
                    .foregroundStyle(user ? palette.text : palette.isDark ? accent : palette.text)
                VStack(alignment: .leading, spacing: 10) { content }
                    .foregroundStyle(user ? FadedColors.deep : palette.text)
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .frame(maxWidth: user ? nil : .infinity, alignment: .leading)
                    .background {
                        if user {
                            RoundedRectangle(cornerRadius: 18)
                                .fill(LinearGradient(colors: [Color(red: 0.80, green: 1, blue: 0.42), FadedBrand.mint],
                                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                        } else {
                            ChatGlassSurface(radius: 18, colors: colors)
                        }
                    }
                    .overlay(alignment: .leading) {
                        if !user {
                            Capsule().fill(accent).frame(width: 4).padding(.vertical, 8)
                                .accessibilityHidden(true)
                        }
                    }
            }
        }
        .frame(maxWidth: .infinity, alignment: user ? .trailing : .leading)
    }

    private var accent: Color { pc ? FadedBrand.pc : FadedBrand.mint }
    private var colors: [Color] {
        pc ? [FadedBrand.pc, FadedBrand.blue] : [FadedBrand.mint, FadedColors.purple]
    }
}

/// BorderBeam is active only while work is pending; the package pauses its timeline at rest.
struct FadedWorkingBeam: ViewModifier {
    @Environment(\.scenePhase) private var phase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(AppStorageKeys.qolReduceMotion) private var appReduceMotion = false
    let active: Bool
    let pc: Bool
    let radius: CGFloat

    func body(content: Content) -> some View {
        if reduceMotion || appReduceMotion {
            // The system preference is read-only. Keep a static work indicator
            // instead of overriding it for the animated package.
            content.overlay {
                RoundedRectangle(cornerRadius: radius)
                    .stroke(LinearGradient(colors: colors, startPoint: .topLeading,
                                           endPoint: .bottomTrailing), lineWidth: 1)
                    .opacity(active && phase == .active ? 0.65 : 0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        } else {
            content.borderBeam(shape: .rounded(radius), style: .small,
                               active: active && phase == .active, colors: colors,
                               intensity: 0.65, timing: BeamTiming(rotateDuration: 4.5))
        }
    }

    private var colors: [Color] {
        pc ? [FadedBrand.pc, FadedBrand.blue] : [FadedBrand.mint, FadedColors.purple]
    }
}

extension View {
    func fadedWorkingBeam(active: Bool, pc: Bool, radius: CGFloat = 22) -> some View {
        modifier(FadedWorkingBeam(active: active, pc: pc, radius: radius))
    }
}
