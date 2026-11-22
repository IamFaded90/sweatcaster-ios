import BorderBeam
import Foundation
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

enum ChatReplyBlock: Equatable {
    case text(String)
    case heading(level: Int, text: String)
    case item(marker: String, indent: Int, text: String)
    case code(String)

    static func parse(_ reply: String) -> [Self] {
        var blocks: [Self] = []
        var lines: [String] = []
        var fence: Substring?
        var item: (marker: String, indent: Int)?

        func finishBlock() {
            if !lines.isEmpty {
                let value = lines.joined(separator: "\n")
                if fence != nil {
                    blocks.append(.code(value))
                } else if let item {
                    blocks.append(.item(marker: item.marker, indent: item.indent, text: value))
                } else {
                    blocks.append(.text(value))
                }
            }
            lines.removeAll(keepingCapacity: true)
            item = nil
        }

        for line in reply.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let indent = line.prefix(while: { $0 == " " }).count
            let content = line.dropFirst(indent)
            let marker = content.prefix(while: { $0 == content.first })
            let rest = content.dropFirst(marker.count)
            if let open = fence {
                if indent <= 3, marker.first == open.first, marker.count >= open.count, rest.allSatisfy(\.isWhitespace) {
                    finishBlock()
                    fence = nil
                } else {
                    lines.append(String(line))
                }
            } else if indent <= 3, marker.count >= 3,
                      marker.first == "~" || (marker.first == "`" && !rest.contains("`")) {
                finishBlock()
                fence = marker
            } else if line.allSatisfy(\.isWhitespace) {
                finishBlock()
            } else if indent <= 3, marker.first == "#", marker.count <= 6, rest.first?.isWhitespace == true {
                finishBlock()
                blocks.append(.heading(level: marker.count, text: String(rest.drop(while: \.isWhitespace))))
            } else if indent <= 3, let (bullet, body) = listItem(content) {
                finishBlock()
                item = (bullet, indent)
                lines.append(String(body))
            } else {
                lines.append(String(item == nil ? line : content))
            }
        }
        finishBlock()
        return blocks
    }

    private static func listItem(_ line: Substring) -> (String, Substring)? {
        let token = line.prefix(while: { !$0.isWhitespace })
        let body = line.dropFirst(token.count)
        guard !body.isEmpty else { return nil }
        if token == "-" || token == "*" || token == "+" {
            return ("•", body.drop(while: \.isWhitespace))
        }
        guard (2...10).contains(token.count), token.last == "." || token.last == ")",
              token.dropLast().allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return (String(token), body.drop(while: \.isWhitespace))
    }
}

struct ChatTranscriptView: View {
    let reply: String
    var privatePresentation = false

    var body: some View {
        if privatePresentation { transcript.textSelection(.disabled) }
        else { transcript.textSelection(.enabled) }
    }

    private var transcript: some View {
        let blocks = ChatReplyBlock.parse(reply)
        return VStack(alignment: .leading, spacing: 8) {
            ForEach(blocks.indices, id: \.self) { index in
                switch blocks[index] {
                case let .text(text):
                    Text(Self.inlineText(text, allowsLinks: !privatePresentation))
                case let .heading(level, text):
                    Text(Self.inlineText(text, allowsLinks: !privatePresentation))
                        .font(level == 1 ? .title3.weight(.semibold) : .headline)
                        .accessibilityAddTraits(.isHeader)
                case let .item(marker, indent, text):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(verbatim: marker).monospacedDigit()
                        Text(Self.inlineText(text, allowsLinks: !privatePresentation))
                    }
                    .padding(.leading, CGFloat(indent) * 4)
                case let .code(code):
                    ScrollView(.horizontal) {
                        Text(highlight(code)).font(.system(.body, design: .monospaced)).padding(8)
                    }.background(.secondary.opacity(0.10))
                }
            }
        }
    }

    static func inlineText(_ text: String, allowsLinks: Bool = true) -> AttributedString {
        var formatted = (try? AttributedString(markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
        if !allowsLinks { formatted.link = nil }
        return formatted
    }

    private func highlight(_ code: String) -> AttributedString {
        let source = AttributedString(code)
        let characters = source.characters
        let keywords: Set<String> = ["let", "var", "func", "return", "if", "else", "for", "import", "class", "def", "async", "await"]
        var output = AttributedString()
        var start = characters.startIndex
        while start < characters.endIndex {
            let character = characters[start]
            var end = characters.index(after: start)
            if character.isLetter || character.isNumber || character == "_" {
                while end < characters.endIndex {
                    let next = characters[end]
                    guard next.isLetter || next.isNumber || next == "_" else { break }
                    characters.formIndex(after: &end)
                }
            }
            var segment = AttributedString(source[start..<end])
            if keywords.contains(String(segment.characters)) { segment.foregroundColor = .purple }
            output.append(segment)
            start = end
        }
        return output
    }
}
