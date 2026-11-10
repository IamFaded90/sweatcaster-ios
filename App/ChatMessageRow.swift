// Renders each prompt and reply together with message-level actions and source attribution.

import Foundation
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
                        .background(palette.lime, in: RoundedRectangle(cornerRadius: 18))
                        .accessibilityAction(named: Text("Kopiér prompt")) { copyPrompt() }
                }
                .frame(maxWidth: userBubbleWidth, alignment: .trailing)
            }
            if !turn.reply.isEmpty {
                VStack(alignment: .leading, spacing: FadedSpacing.s) {
                    messageHeading(attribution, icon: icon, accent: palette.isDark ? accent : palette.text)
                    ChatTranscriptView(reply: turn.reply)
                    if showsWordCount {
                        FadedDetailText("\(turn.reply.split(whereSeparator: \.isWhitespace).count) ord")
                    }
                    replyActions()
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(palette.text)
                .background(palette.card, in: RoundedRectangle(cornerRadius: 18))
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
            ChatMessageRow(
                turn: turn, userBubbleWidth: userBubbleWidth, accent: replyColor(turn.source),
                attribution: replyAttribution(for: turn), icon: sourceIcon(turn.source),
                showsTime: aiTimestamps, showsWordCount: aiWordCount, copyPrompt: { copyText(turn.prompt) },
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
            if busyPCTurn == turn.id {
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

    private func isQueued(_ turn: ChatTurn) -> Bool {
        outboxEntries.contains { $0.id == turn.id }
    }

    private func branch(from turn: ChatTurn) {
        let previous = sessionID
        newConversation()
        if sessionID != previous { restoreDraft(turn) }
    }

    private func replyColor(_ source: String?) -> Color {
        switch source ?? "" {
        case "Telefon": palette.green
        case "PC": palette.cyan
        case GrokAPI.sourceLabel: palette.purple
        default: palette.lime
        }
    }

    private func replyActions(_ turn: ChatTurn) -> some View {
        HStack(spacing: 4) {
            Button("Læs svaret op", systemImage: "speaker.wave.2") { speak(turn.reply) }
                .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
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
        Button("Brug som kladde", systemImage: "square.and.pencil") { restoreDraft(turn) }
            .disabled(task != nil || isQueued(turn))
        Button("Kopiér besked", systemImage: "doc.on.doc") { copyText(turn.prompt) }
        if !turn.reply.isEmpty {
            Button("Svar med citat", systemImage: "quote.opening") { quoteReply(turn) }.disabled(task != nil)
            Button("Kopiér svar", systemImage: "doc.on.doc") { copyText(turn.reply) }
            ShareLink(item: turn.reply) { Label("Del svar", systemImage: "square.and.arrow.up") }
            Button("Gem uddrag som note", systemImage: "note.text") { saveReplyNote(turn.reply) }
        }
    }

    private func canRetryOnPhone(_ turn: ChatTurn) -> Bool {
        !demo && turn.source == "Telefon" && draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func retryOnPhone(_ turn: ChatTurn) {
        guard task == nil, canRetryOnPhone(turn) else { return }
        restoreDraft(turn)
        chooseSource(.phone)
        send()
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
