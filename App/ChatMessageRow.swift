// Filnavn: App/ChatMessageRow.swift
// Renders each prompt and reply together with message-level actions and source attribution.

import Foundation
import ImageIO
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ChatMessageRow<ReplyActions: View, NoticeActions: View>: View {
    @Environment(\.fadedPalette) private var palette
    let turn: ChatTurn
    let userBubbleWidth: CGFloat
    let accent: Color
    let attribution: String
    let icon: String
    let showsTime: Bool
    let showsWordCount: Bool
    let readAlong: SpeechBox.WordProgress?
    let isSpeaking: Bool
    let copyPrompt: () -> Void
    let replyActions: () -> ReplyActions
    let noticeActions: () -> NoticeActions

    var body: some View {
        VStack(alignment: .leading, spacing: FadedSpacing.m) {
            HStack {
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: FadedSpacing.xs) {
                    messageHeading("Dig", icon: "person.crop.circle.fill", accent: palette.text)
                    Text(turn.prompt)
                        .foregroundStyle(FadedColors.deep)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(
                            LinearGradient(colors: [Color(red: 0.80, green: 1, blue: 0.42), FadedBrand.mint],
                                           startPoint: .topLeading, endPoint: .bottomTrailing),
                            in: RoundedRectangle(cornerRadius: 18)
                        )
                        .accessibilityAction(named: Text("Kopiér prompt")) { copyPrompt() }
                }
                .frame(maxWidth: userBubbleWidth, alignment: .trailing)
            }
            if !turn.reply.isEmpty {
                let replyShape = RoundedRectangle(cornerRadius: 18)
                VStack(alignment: .leading, spacing: FadedSpacing.s) {
                    messageHeading(attribution, icon: icon, accent: palette.isDark ? accent : palette.text)
                    if let name = turn.imageName {
                        ChatGeneratedImage(name: name)
                    } else {
                        ChatTranscriptView(reply: turn.reply)
                        if let readAlong { ChatReadAlong(progress: readAlong) }
                        if showsWordCount {
                            FadedDetailText("\(turn.reply.split(whereSeparator: \.isWhitespace).count) ord")
                        }
                        replyActions()
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(palette.text)
                .background { ChatGlassSurface(radius: 18, colors: replyGradient) }
                .overlay {
                    if isSpeaking {
                        replyShape.strokeBorder(accent.opacity(palette.isDark ? 0.55 : 0.7), lineWidth: 1.5)
                            .shadow(color: accent.opacity(0.28), radius: 6)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .overlay(alignment: .leading) {
                    Capsule().fill(accent).frame(width: 4).padding(.vertical, 8).accessibilityHidden(true)
                }
            }
            if let notice = turn.notice {
                FadedCard(accent: turn.source == "PC" && notice == "Venter på PC" ? accent : palette.coral) {
                    VStack(alignment: .leading, spacing: FadedSpacing.s) {
                        Text(notice)
                        noticeActions()
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // Swift Chats chatBubbleStyle anvender brugerdefineret fyld på beskedboblen.
    private var replyGradient: [Color] {
        switch turn.source {
        case "PC": [FadedBrand.pc, FadedBrand.blue]
        case "Telefon", "iPhone": [FadedBrand.mint, Color(red: 0.64, green: 0.42, blue: 1)]
        case "Claude", "ClaudeAI": [FadedColors.purple, .pink]
        default: [accent, palette.raised]
        }
    }

    private func messageHeading(_ title: String, icon: String, accent: Color) -> some View {
        HStack(spacing: FadedSpacing.s) {
            Image(systemName: icon)
                .frame(width: 25, height: 25)
                .background(accent.opacity(0.12), in: Circle())
                .accessibilityHidden(true)
            Text(title).font(.caption.bold())
            if showsTime, let date = turn.createdAt {
                Text(date, format: .dateTime.hour().minute()).font(.caption)
                    .foregroundStyle(palette.secondary)
            }
        }
        .foregroundStyle(accent)
    }
}

struct ChatGlassSurface: View {
    @Environment(\.fadedPalette) private var palette
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let radius: CGFloat
    let colors: [Color]

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius)
        let gradient = LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
        ZStack {
            if #available(iOS 26.0, *), !reduceTransparency {
                Color.clear.glassEffect(.regular.tint(colors.first?.opacity(0.18)), in: shape)
                shape.fill(palette.card.opacity(0.76))
            } else {
                shape.fill(palette.card)
            }
            shape.fill(gradient).opacity(palette.isDark ? 0.13 : 0.08)
            shape.strokeBorder(gradient).opacity(palette.isDark ? 0.36 : 0.22)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct ChatGeneratedImage: View {
    let name: String
    @State private var photo: UIImage?
    @State private var file: URL?
    @State private var loaded = false
    @State private var confirmDeletion = false
    @State private var deletionFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let photo, let file {
                Image(uiImage: photo)
                    .resizable().scaledToFit()
                    .clipShape(.rect(cornerRadius: 12))
                    .accessibilityLabel("AI-genereret billede")
                HStack {
                    ShareLink(item: file) { Label("Del billede", systemImage: "square.and.arrow.up") }
                        .frame(minHeight: 44)
                    Button("Slet billede", systemImage: "trash", role: .destructive) { confirmDeletion = true }
                        .frame(minHeight: 44)
                }
            } else if loaded {
                Text("Billedet er ikke længere i galleriet.").foregroundStyle(.secondary)
            } else {
                ProgressView("Åbner billede…")
            }
        }
        .confirmationDialog("Slet billedet fra FadedAI?", isPresented: $confirmDeletion) {
            Button("Slet billede", role: .destructive, action: deleteImage)
        }
        .alert("Billedet kunne ikke slettes", isPresented: $deletionFailed) {
            Button("OK", role: .cancel) { }
        }
        .task(id: name) {
            loaded = false
            photo = nil
            file = nil
            guard let url = StudioImageFiles.savedImage(name) else { loaded = true; return }
            let thumbnail = await Task.detached(priority: .utility) { Self.thumbnail(url) }.value
            guard !Task.isCancelled else { return }
            photo = thumbnail.map { UIImage(cgImage: $0) }
            file = url
            loaded = true
        }
    }

    private func deleteImage() {
        guard let file else { return }
        do {
            try StudioImageFiles.deleteSavedImage(file)
            photo = nil
            self.file = nil
            loaded = true
        } catch {
            AppDiagnostics.record(error)
            deletionFailed = true
        }
    }

    private nonisolated static func thumbnail(_ file: URL) -> CGImage? {
        guard let data = try? LocalFileStore.readBytes(from: file, maximumBytes: 15_000_000),
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1_024
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

private struct ChatReadAlong: View {
    @Environment(\.fadedPalette) private var palette
    @Environment(\.dynamicTypeSize) private var typeSize
    @ObservedObject var progress: SpeechBox.WordProgress

    var body: some View {
        VStack(alignment: .leading, spacing: FadedSpacing.xs) {
            Label("Følg oplæsningen", systemImage: "speaker.wave.2")
                .font(.caption.weight(.semibold))
                .foregroundStyle(palette.secondary)
            Text(highlightedExcerpt)
                .font(.subheadline)
                .lineLimit(2, reservesSpace: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(FadedSpacing.s)
        .background(palette.raised, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityHidden(true)
    }

    private var highlightedExcerpt: AttributedString {
        guard let position = progress.position, let range = Range(position.range, in: position.text),
              !range.isEmpty else { return AttributedString("…") }
        let text = position.text
        let context = typeSize.isAccessibilitySize ? 8 : 24
        let before = text[..<range.lowerBound].suffix(context + 1)
        let after = text[range.upperBound...].prefix(context + 1)
        var excerpt = AttributedString((before.count > context ? "…" : "") + String(before.suffix(context)))
        var word = AttributedString(String(text[range]))
        word.backgroundColor = palette.lime
        word.foregroundColor = FadedColors.deep
        excerpt.append(word)
        excerpt.append(AttributedString(String(after.prefix(context)) + (after.count > context ? "…" : "")))
        return excerpt
    }
}

extension ChatView {
    func scrollChat(_ proxy: ScrollViewProxy) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            withAnimation(reduceMotion || calmMotion ? nil : .easeOut(duration: 0.2)) {
                proxy.scrollTo("chat-bottom", anchor: .bottom)
            }
        }
    }

    func transcriptRows(userBubbleWidth: CGFloat) -> some View {
        ForEach(filteredTurns) { turn in
            let reading = speechBox.playback == .reply(turn.id)
            ChatMessageRow(
                turn: turn, userBubbleWidth: userBubbleWidth, accent: replyColor(turn.source),
                attribution: replyAttribution(for: turn), icon: sourceIcon(turn.source),
                showsTime: aiTimestamps, showsWordCount: aiWordCount,
                readAlong: reading ? speechBox.wordProgress : nil, isSpeaking: reading && speechBox.isSpeaking,
                copyPrompt: { copyText(turn.prompt) },
                replyActions: { replyActions(turn) }, noticeActions: { noticeActions(turn) }
            )
            .contextMenu {
                quickTurnActions(turn)
                Button("Start ny gren") { branch(from: turn) }.disabled(task != nil || isQueued(turn))
                Button("Slet besked", systemImage: "trash", role: .destructive) { deleteTurn(turn.id) }
                    .disabled(task != nil || isQueued(turn))
            }
            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                Button("Kopiér") { copyText(turn.reply.isEmpty ? turn.prompt : turn.reply) }
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button("Brug som kladde") { restoreDraft(turn) }.disabled(task != nil || isQueued(turn))
                Button("Ny gren") { branch(from: turn) }.disabled(task != nil || isQueued(turn))
            }
            .id(turn.id)
        }
    }

    @ViewBuilder private func noticeActions(_ turn: ChatTurn) -> some View {
        if !isQueued(turn) {
            if turn.imageRequest == true {
                retryImageControls(turn)
            } else if busyPCTurn == turn.id {
                FadedSecondaryButton("Brug Telefon imens", icon: "iphone") {
                    if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { restoreDraft(turn) }
                    chooseModelForNextMessage(.phone)
                }.disabled(task != nil)
            } else if canRetryOnPhone(turn) {
                FadedSecondaryButton("Prøv igen på telefonen", icon: "arrow.clockwise") { retryOnPhone(turn) }
                    .disabled(task != nil)
            } else {
                FadedSecondaryButton("Brug som kladde", icon: "square.and.pencil") { restoreDraft(turn) }
                    .disabled(task != nil)
            }
        }
    }

    @ViewBuilder private func retryImageControls(_ turn: ChatTurn) -> some View {
        let currentDraft = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let canRetry = task == nil && (currentDraft.isEmpty || currentDraft == turn.prompt)
        if turn.source == "PC" && api is LiveAPI {
            FadedSecondaryButton("Prøv billedet igen på PC", icon: "arrow.clockwise") {
                draft = turn.prompt
                generateChatImage(onPC: true)
            }.disabled(!canRetry)
        }
        FadedSecondaryButton("Prøv billedet på iPhone", icon: "iphone") {
            draft = turn.prompt
            generateChatImage(onPC: false)
        }.disabled(!canRetry)
    }

    private func isQueued(_ turn: ChatTurn) -> Bool {
        outboxEntries.contains { $0.id == turn.id }
    }

    private func branch(from turn: ChatTurn) {
        let previous = sessionID
        newConversation()
        if sessionID != previous { restoreDraft(turn) }
    }

    private func replyColor(_ source: String?) -> Color {
        if source?.contains("Composio") == true || source?.contains("NVIDIA") == true || source == "OpenRouter" { return palette.purple }
        return switch source ?? "" {
        case "Telefon": palette.green
        case "PC": palette.cyan
        case GrokAPI.sourceLabel: palette.purple
        default: palette.lime
        }
    }

    private func replyActions(_ turn: ChatTurn) -> some View {
        let reading = speechBox.playback == .reply(turn.id)
        return HStack(spacing: 4) {
            Button(reading ? "Stop oplæsning" : "Læs svaret op", systemImage: reading ? "stop.circle" : "speaker.wave.2") {
                if reading { speechBox.stop() }
                else { speak(turn.reply, turnID: turn.id) }
            }.labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44).disabled(dictation.active)
            Menu {
                quickTurnActions(turn)
                Button(turn.favorite == true ? "Fjern favorit" : "Favorit",
                       systemImage: turn.favorite == true ? "star.fill" : "star") { toggleFavorite(turn.id) }
                Button("Godt svar", systemImage: turn.feedback == 1 ? "hand.thumbsup.fill" : "hand.thumbsup") {
                    setFeedback(turn.id, value: 1)
                }
                Button("Dårligt svar", systemImage: turn.feedback == -1 ? "hand.thumbsdown.fill" : "hand.thumbsdown") {
                    setFeedback(turn.id, value: -1)
                }
                Button("Slet besked", systemImage: "trash", role: .destructive) { deleteTurn(turn.id) }
                    .disabled(task != nil)
            } label: {
                Image(systemName: "ellipsis.circle").frame(minWidth: 44, minHeight: 44)
            }.accessibilityLabel("Flere handlinger for svar")
        }
    }

    @ViewBuilder private func quickTurnActions(_ turn: ChatTurn) -> some View {
        if turn.notice != nil && canRetryOnPhone(turn) {
            Button("Prøv igen på telefonen", systemImage: "arrow.clockwise") { retryOnPhone(turn) }
                .disabled(task != nil)
        }
        Button("Redigér besked", systemImage: "square.and.pencil") { restoreDraft(turn) }
            .disabled(task != nil || isQueued(turn) || !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        if !demo, turn.imageRequest != true {
            Menu("Prøv med en anden model", systemImage: "arrow.clockwise") {
                ForEach(phoneRoutingCandidates, id: \.id) { option in
                    Button("iPhone · \(option.name)") {
                        retryWithModel(turn, route: .init(source: .phone, modelID: option.id, automatic: nil))
                    }
                }
                ForEach(models.filter(PCModelSelection.usable), id: \.id) { option in
                    Button("PC · \(option.label)") {
                        retryWithModel(turn, route: .init(source: .pc, modelID: option.id, automatic: nil))
                    }
                }
            }
            .disabled(task != nil || isQueued(turn) || !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        Button("Kopiér besked", systemImage: "doc.on.doc") { copyText(turn.prompt) }
        if !turn.reply.isEmpty {
            if api is LiveAPI {
                Button("Lav agentopgave af svar", systemImage: "person.crop.circle.badge.plus") {
                    composerFocused = false
                    agentTaskDraft = AgentTaskDraft(text: turn.reply)
                }.disabled(task != nil || turn.imageRequest == true)
            }
            Button("Svar med citat", systemImage: "quote.opening") { quoteReply(turn) }.disabled(task != nil)
            Button("Kopiér svar", systemImage: "doc.on.doc") { copyText(turn.reply) }
            ShareLink(item: turn.reply) { Label("Del svar", systemImage: "square.and.arrow.up") }
            Button("Gem uddrag som note", systemImage: "note.text") { saveReplyNote(turn.reply) }
        }
    }

    private func canRetryOnPhone(_ turn: ChatTurn) -> Bool {
        !demo && turn.imageRequest != true && turn.source == "Telefon" &&
            draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func retryOnPhone(_ turn: ChatTurn) {
        guard task == nil, canRetryOnPhone(turn) else { return }
        restoreDraft(turn)
        chooseSource(.phone)
        send()
    }

    private func retryWithModel(_ turn: ChatTurn, route: ResolvedRoute) {
        guard task == nil, !isQueued(turn), draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              canSend(to: route) else { return }
        restoreDraft(turn)
        composerFocused = false
        send(via: route)
    }

    private func restoreDraft(_ turn: ChatTurn) {
        guard task == nil else { return }
        attachedNote = nil
        attachedQuote = nil
        draft = turn.prompt
        composerFocused = true
    }

    private func quoteReply(_ turn: ChatTurn) {
        guard task == nil, !turn.reply.isEmpty else { return }
        attachedQuote = String(turn.reply.unicodeScalars.prefix(650))
        quoteDestination = effectiveReplySource
        composerFocused = true
    }

    func copyText(_ text: String) {
        guard !text.isEmpty else { return }
        UIPasteboard.general.setItems([[UTType.utf8PlainText.identifier: text]], options: [.localOnly: true])
        chatNotice = "Kopieret."
    }

    private func saveReplyNote(_ reply: String) {
        let oneLine = reply.split(whereSeparator: \.isNewline).joined(separator: " ")
        let excerpt = String(oneLine.prefix(600)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !excerpt.isEmpty else { return }
        do {
            try MigratedAppData.shared.saveNotes(notes.isEmpty ? excerpt : excerpt + "\n" + notes)
            chatNotice = "Uddraget er gemt som note på telefonen."
        } catch { AppDiagnostics.record(error); chatNotice = "Noten kunne ikke gemmes." }
    }

    private var filteredTurns: [ChatTurn] {
        favoritesOnly ? turns.filter { $0.favorite == true } : turns
    }

    private func toggleFavorite(_ id: UUID) {
        guard let index = turns.firstIndex(where: { $0.id == id }) else { return }
        turns[index].favorite = turns[index].favorite != true
        save()
    }

    private func deleteTurn(_ id: UUID) {
        guard task == nil, let index = turns.firstIndex(where: { $0.id == id }) else { return }
        removedTurns.removeAll { $0.expiresAt <= ContinuousClock.now }
        removedTurns.append(RemovedTurn(turn: turns.remove(at: index), index: index,
                                        expiresAt: ContinuousClock.now.advanced(by: .seconds(5))))
        save()
    }

    private func setFeedback(_ id: UUID, value: Int) {
        guard let index = turns.firstIndex(where: { $0.id == id }) else { return }
        turns[index].feedback = turns[index].feedback == value ? nil : value
        save()
    }

}
