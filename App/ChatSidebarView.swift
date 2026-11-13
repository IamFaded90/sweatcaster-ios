// Chat history keeps search and navigation separate from the active conversation.

import Foundation
import SwiftUI

struct ChatSidebarView: View {
    @Environment(\.fadedPalette) private var palette
    @Binding var query: String
    let sessions: [SavedAgentSession]
    let selectedID: UUID
    let isBusy: Bool
    let activeTurns: [ChatTurn]
    let newChat: () -> Void
    let select: (SavedAgentSession) -> Void
    let jumpToTurn: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: FadedSpacing.m) {
            FadedSecondaryButton("Ny chat", icon: "square.and.pencil", action: newChat)
                .disabled(isBusy)
            TextField("Søg i alle samtaler", text: Binding(
                get: { query }, set: { query = FadedSearchIndex.boundedQuery($0) }
            ))
            .textFieldStyle(.roundedBorder).frame(minHeight: 44)
            .autocorrectionDisabled()
            let rows = visibleSessions
            if rows.isEmpty {
                if searchText.isEmpty {
                    FadedEmptyState(icon: "bubble.left.and.bubble.right", title: "Ingen samtaler endnu",
                                    detail: "Samtaler og kladder ligger her, når du har skrevet noget.")
                } else {
                    FadedEmptyState(icon: "magnifyingglass", title: "Ingen samtaler fundet",
                                    detail: "Prøv et andet ord.", actionTitle: "Ryd søgning") { query = "" }
                }
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: FadedSpacing.s) {
                        if searchText.isEmpty {
                            messageIndex
                            let favorites = rows.filter { $0.turns.contains { $0.favorite == true } }
                            let other = rows.filter { !$0.turns.contains { $0.favorite == true } }
                            section("Favoritter", sessions: favorites)
                            section("I dag", sessions: other.filter { age(of: $0) == .today })
                            section("Seneste uge", sessions: other.filter { age(of: $0) == .week })
                            section("Ældre", sessions: other.filter { age(of: $0) == .earlier })
                        } else {
                            section("Søgeresultater", sessions: rows)
                        }
                    }
                }
                .scrollDismissesKeyboard(.interactively)
            }
        }
        .padding(FadedSpacing.edge)
        .foregroundStyle(palette.text)
        .background(palette.background)
    }

    private enum Age: Equatable { case today, week, earlier }

    private var searchText: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    @ViewBuilder private var messageIndex: some View {
        if activeTurns.count > 1 {
            DisclosureGroup("Hop til en besked") {
                ForEach(Array(activeTurns.suffix(FadedSearchIndex.limit))) { turn in
                    Button { jumpToTurn(turn.id) } label: {
                        Label(turn.prompt, systemImage: "arrow.turn.down.right")
                            .lineLimit(2).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }.buttonStyle(.plain).disabled(isBusy)
                }
            }.frame(minHeight: 44, alignment: .leading)
        }
    }

    private var visibleSessions: [SavedAgentSession] {
        let sorted = sessions.sorted {
            (date(of: $0) ?? .distantPast) > (date(of: $1) ?? .distantPast)
        }
        let term = searchText
        guard !term.isEmpty else { return sorted }
        return Array(sorted.lazy.filter { session in
            session.turns.contains { $0.prompt.localizedCaseInsensitiveContains(term) || $0.reply.localizedCaseInsensitiveContains(term) }
        }.prefix(FadedSearchIndex.limit))
    }

    private func date(of session: SavedAgentSession) -> Date? {
        session.turns.compactMap(\.createdAt).max()
    }

    private func age(of session: SavedAgentSession) -> Age {
        guard let date = date(of: session) else { return .earlier }
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return .today }
        if let cutoff = calendar.date(byAdding: .day, value: -7, to: calendar.startOfDay(for: .now)), date >= cutoff { return .week }
        return .earlier
    }

    @ViewBuilder private func section(_ title: String, sessions: [SavedAgentSession]) -> some View {
        if !sessions.isEmpty {
            FadedSectionLabel(title).padding(.top, FadedSpacing.xs)
            ForEach(sessions, id: \.id) { session in row(session) }
        }
    }

    private func row(_ session: SavedAgentSession) -> some View {
        let selected = session.id == selectedID
        let title = session.turns.first?.prompt ?? "Kladde uden titel"
        let snippet = matchingText(in: session)
        return Button { select(session) } label: {
            HStack(alignment: .top, spacing: FadedSpacing.s) {
                Image(systemName: session.turns.contains { $0.favorite == true } ? "star.fill" : "bubble.left")
                    .foregroundStyle(palette.secondary).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: FadedSpacing.xs) {
                    Text(title).font(FadedTypography.action).lineLimit(2).foregroundStyle(palette.text)
                    if let snippet { FadedDetailText(snippet).lineLimit(2) }
                    if let date = date(of: session) {
                        Text(date, format: .dateTime.day().month().hour().minute())
                            .font(.caption).foregroundStyle(palette.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(FadedSpacing.s)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(selected ? palette.raised : palette.card, in: RoundedRectangle(cornerRadius: FadedRadius.medium))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .disabled(isBusy && !selected)
    }

    private func matchingText(in session: SavedAgentSession) -> String? {
        let term = searchText
        guard !term.isEmpty else { return nil }
        return session.turns.lazy.flatMap { [$0.prompt, $0.reply] }.first { $0.localizedCaseInsensitiveContains(term) }
    }
}

extension ChatView {
    var historySessions: [SavedAgentSession] {
        let history = archivedSessions.filter { $0.id != sessionID }
        guard !turns.isEmpty || !draft.isEmpty else { return history }
        return [currentSession(pending: task != nil)] + history
    }

    func refreshHistorySessions() {
        archivedSessions = ChatArchive.sessions()
    }

    @discardableResult func openConversation(_ session: SavedAgentSession) -> Bool {
        guard task == nil else { return false }
        if session.id == sessionID { return true }
        return switchConversation(to: session)
    }

    func newConversation() {
        guard task == nil else { return }
        _ = switchConversation(to: SavedAgentSession(id: UUID(), turns: [], toolSteps: [], pending: false))
    }

    private func switchConversation(to session: SavedAgentSession) -> Bool {
        guard checkpointConversation() else { return false }
        let opened = recoverPending(session)
        let nextDraft = MigratedAppData.shared.chatDraft(AppStorageKeys.chatSession(session.id.uuidString))
        guard persistCurrentSlot(opened) else { return false }

        dictation.stop()
        speechBox.stop()
        sessionID = opened.id
        turns = opened.turns
        searchSteps = opened.toolSteps
        draft = nextDraft
        savedDraft = nextDraft
        sourceExcerpt = nil
        attachedNote = nil
        attachedQuote = nil
        removedTurns = []
        chatNotice = nil
        busyPCTurn = nil
        manualRoute = nil
        inFlightAutoRoute = nil
        refreshHistorySessions()
        reloadOutbox()
        scrollRequest += 1
        return true
    }

    private func checkpointConversation() -> Bool {
        guard !turns.isEmpty || !draft.isEmpty || archivedSessions.contains(where: { $0.id == sessionID }) else { return true }
        do {
            let key = AppStorageKeys.chatSession(sessionID.uuidString)
            if !draft.isEmpty || !MigratedAppData.shared.chatDraft(key).isEmpty {
                try MigratedAppData.shared.saveChatDraft(draft, sessionKey: key)
            }
            if turns.isEmpty && draft.isEmpty {
                try ChatArchive.remove(sessionID)
                return true
            }
            guard ChatArchive.append(currentSession(pending: false), includeEmpty: !draft.isEmpty) else {
                chatNotice = "Samtalen kunne ikke gemmes. Prøv at skifte igen."
                return false
            }
            return true
        } catch {
            AppDiagnostics.record(error)
            chatNotice = "Kladden kunne ikke gemmes. Prøv at skifte igen."
            return false
        }
    }

    @discardableResult func save(pending: Bool? = nil) -> Bool {
        let session = currentSession(pending: pending ?? (task != nil))
        guard persistCurrentSlot(session) else { return false }
        if !session.pending, archivedSessions.contains(where: { $0.id == session.id }) {
            if turns.isEmpty && draft.isEmpty {
                do { try ChatArchive.remove(session.id) }
                catch { AppDiagnostics.record(error); chatNotice = "Historikken kunne ikke opdateres. Prøv igen." }
            } else if !ChatArchive.append(session, includeEmpty: !draft.isEmpty) {
                chatNotice = "Historikken kunne ikke opdateres. Prøv igen."
            }
            refreshHistorySessions()
        }
        return true
    }

    private func currentSession(pending: Bool) -> SavedAgentSession {
        SavedAgentSession(id: sessionID, turns: turns, toolSteps: searchSteps, pending: pending)
    }

    private func persistCurrentSlot(_ session: SavedAgentSession) -> Bool {
        do {
            let data = try JSONEncoder().encode(session)
            // Keep the legacy active slot; streaming updates it without a synchronous file write.
            UserDefaults.standard.set(data, forKey: storageKey)
            return true
        } catch {
            AppDiagnostics.record(error)
            chatNotice = "Samtalen kunne ikke gemmes. Prøv igen."
            return false
        }
    }

    func loadHistory() {
        refreshHistorySessions()
        guard let data = MigratedAppData.shared.chatSession(storageKey),
              let session = ChatArchive.decodeSession(data) else { return }
        let recovered = recoverPending(session)
        sessionID = recovered.id
        turns = recovered.turns
        searchSteps = recovered.toolSteps

        // A queued reply can finish in the archive while a different slot still holds its placeholder.
        var repaired = session.pending
        if let archived = archivedSessions.first(where: { $0.id == sessionID }) {
            for delivered in archived.turns where delivered.source == "PC" &&
                (!delivered.reply.isEmpty || delivered.notice == "PC’en afsluttede beskeden uden svartekst.") {
                guard let placeholder = turns.first(where: { $0.id == delivered.id && $0.source == "PC" && $0.reply.isEmpty }),
                      placeholder.reply != delivered.reply || placeholder.notice != delivered.notice else { continue }
                ChatTurn.upsertOutbox(delivered, in: &turns)
                repaired = true
            }
        }
        if repaired { save() }
    }

    private func recoverPending(_ session: SavedAgentSession) -> SavedAgentSession {
        guard session.pending, !session.turns.isEmpty else { return session }
        var interrupted = session.turns
        interrupted[interrupted.count - 1].notice = "Forbindelsen blev afbrudt, før svaret var færdigt."
        return SavedAgentSession(id: session.id, turns: interrupted, toolSteps: session.toolSteps, pending: false)
    }
}
