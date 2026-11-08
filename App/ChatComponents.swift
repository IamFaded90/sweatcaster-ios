// Viser samtalen og håndterer chatarkiv og handlinger på beskeder.

import AVFoundation
import Foundation
import Observation
import Speech
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ChatTurn: Identifiable, Codable, Sendable {
    var id = UUID()
    let prompt: String
    var reply = ""
    var notice: String?
    var source: String?
    var favorite: Bool?
    var createdAt: Date?
    var feedback: Int?
}

struct StatsBar: View {
    let turns: Int
    let streaming: Bool

    var body: some View {
        Text(streaming ? "\(turns) beskeder · Modtager svar" : "\(turns) beskeder")
            .font(.caption)
    }
}

struct ChatTranscriptView: View {
    let reply: String

    var body: some View {
        let blocks = reply.components(separatedBy: "```")
        VStack(alignment: .leading, spacing: 8) {
            ForEach(blocks.indices, id: \.self) { index in
                if index.isMultiple(of: 2) {
                    if let formatted = try? AttributedString(markdown: blocks[index],
                        options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
                        Text(formatted)
                    } else { Text(blocks[index]) }
                } else {
                    let lines = blocks[index].split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
                    ScrollView(.horizontal) {
                        Text(highlight(lines.count == 2 ? String(lines[1]) : blocks[index]))
                            .font(.system(.body, design: .monospaced)).padding(8)
                    }.background(.secondary.opacity(0.10))
                }
            }
        }.textSelection(.enabled)
    }

    private func highlight(_ code: String) -> AttributedString {
        var result = AttributedString(code)
        let words = ["let", "var", "func", "return", "if", "else", "for", "import", "class", "def", "async", "await"]
        for word in words {
            var cursor = code.startIndex
            while let match = code.range(of: "\\b" + word + "\\b", options: .regularExpression,
                                         range: cursor..<code.endIndex),
                  let range = Range(match, in: result) {
                result[range].foregroundColor = .purple
                cursor = match.upperBound
            }
        }
        return result
    }
}


@MainActor @Observable final class ChatDictation {
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognition: SFSpeechRecognitionTask?
    private var recognizer: SFSpeechRecognizer?
    private var tapInstalled = false
    private var sessionActive = false
    private var runID = UUID()
    private(set) var active = false
    private(set) var problem: String?

    func start(update: @escaping (String) -> Void) async {
        guard !active else { return }
        let id = UUID()
        runID = id
        active = true
        problem = nil
        let speechAllowed = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
        guard runID == id else { return }
        guard speechAllowed, let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "da-DK")),
              recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            fail("Dansk diktering på telefonen er ikke tilgængelig. Tjek talegenkendelse i Indstillinger.")
            return
        }
        let micAllowed = await AVAudioApplication.requestRecordPermission()
        guard runID == id else { return }
        guard micAllowed else {
            fail("Giv FadedAI adgang til mikrofonen i Indstillinger.")
            return
        }
        do {
            let audio = AVAudioSession.sharedInstance()
            try audio.setCategory(.record, mode: .measurement)
            try audio.setActive(true)
            sessionActive = true
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.requiresOnDeviceRecognition = true
            request.shouldReportPartialResults = true
            self.request = request
            self.recognizer = recognizer
            let node = engine.inputNode
            let format = node.outputFormat(forBus: 0)
            guard format.channelCount > 0, format.sampleRate > 0 else {
                fail("Mikrofonen er ikke klar.")
                return
            }
            node.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in request.append(buffer) }
            tapInstalled = true
            recognition = recognizer.recognitionTask(with: request) { result, error in
                let text = result?.bestTranscription.formattedString
                let done = result?.isFinal == true
                let failed = error != nil
                Task { @MainActor [weak self] in
                    guard let self, self.runID == id else { return }
                    if let text { update(text) }
                    if done { self.stop() }
                    else if failed { self.fail("Dikteringen stoppede. Du kan prøve igen.") }
                }
            }
            try engine.start()
        } catch { AppDiagnostics.record(error); fail("Mikrofonen kunne ikke startes.") }
    }

    func stop() {
        runID = UUID()
        active = false
        engine.stop()
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        request?.endAudio()
        recognition?.cancel()
        recognition = nil
        request = nil
        recognizer = nil
        if sessionActive {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            sessionActive = false
        }
    }

    private func fail(_ message: String) {
        stop()
        problem = message
    }
}

struct SavedAgentSession: Codable {
    let id: UUID
    let turns: [ChatTurn]
    let toolSteps: [String]
    let pending: Bool
}

enum ChatArchive {
    static let key = AppStorageKeys.spacesChatArchiveV1

    @discardableResult static func append(_ session: SavedAgentSession) -> Bool {
        guard !session.turns.isEmpty else { return false }
        let defaults = UserDefaults.standard
        let saved = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([SavedAgentSession].self, from: $0) } ?? []
        let updated = [session] + saved.filter { $0.id != session.id }
        guard let data = try? JSONEncoder().encode(Array(updated.prefix(100))) else { return false }
        defaults.set(data, forKey: key)
        return true
    }

    static func appendOutboxTurn(_ turn: ChatTurn, to sessionID: UUID) -> Bool {
        let saved = UserDefaults.standard.data(forKey: key)
            .flatMap { try? JSONDecoder().decode([SavedAgentSession].self, from: $0) }
        let session = saved?.first { $0.id == sessionID }
        let turns = session?.turns ?? []
        guard !turns.contains(where: { $0.id == turn.id }) else { return true }
        return append(SavedAgentSession(id: sessionID, turns: turns + [turn], toolSteps: session?.toolSteps ?? [], pending: false))
    }

    static func turns() -> [ChatTurn] {
        let defaults = UserDefaults.standard
        let decoder = JSONDecoder()
        var found = defaults.data(forKey: key).flatMap { try? decoder.decode([SavedAgentSession].self, from: $0) }?.flatMap(\.turns) ?? []
        for (name, value) in defaults.dictionaryRepresentation() where name.hasPrefix(AppStorageKeys.chatSessionPrefix) && name != key {
            guard let data = value as? Data else { continue }
            if let session = try? decoder.decode(SavedAgentSession.self, from: data) { found += session.turns }
            else if let legacy = try? decoder.decode([ChatTurn].self, from: data) { found += legacy }
        }
        var seen = Set<UUID>()
        return found.sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
            .filter { seen.insert($0.id).inserted }
    }
}

struct AgentToolWave: View {
    let status: String
    @Environment(\.fadedPalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(AppStorageKeys.qolReduceMotion) private var calmMotion = false

    var body: some View {
        let paused = reduceMotion || calmMotion || scenePhase != .active
        TimelineView(.animation(minimumInterval: 1.0 / 15, paused: paused)) { context in
            let time = paused ? 0 : context.date.timeIntervalSinceReferenceDate * 6
            HStack(spacing: 3) {
                ForEach(0..<7, id: \.self) { index in
                    Capsule().fill(palette.lime).frame(width: 3, height: 6 + CGFloat(abs(sin(time + Double(index) * 0.8))) * 12)
                }
            }.frame(height: 20)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(status)
    }
}

struct CloudModelSettings: View {
    @State private var draft = ""
    @State private var hasKey = CloudModelKey.exists()
    @State private var notice: String?

    var body: some View {
        DisclosureGroup("Valgfri xAI-nøgle") {
            Text("Nøglen gemmes i iPhones Keychain. Vælg Grok i chatten for at sende til xAI. Forbruget kan koste penge.")
                .font(.caption).foregroundStyle(.secondary)
            SecureField("xAI API-nøgle", text: $draft)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("Gem nøgle") {
                do {
                    try CloudModelKey.save(draft)
                    draft = ""
                    notice = "Nøglen er gemt på telefonen."
                } catch { AppDiagnostics.record(error); notice = "Nøglen kunne ikke gemmes." }
            }.disabled(draft.isEmpty)
            if hasKey {
                Button("Fjern nøgle", role: .destructive) {
                    CloudModelKey.remove()
                    notice = CloudModelKey.exists() ? "Nøglen kunne ikke fjernes." : "Nøglen er fjernet."
                }
            }
            if let notice { Text(notice).font(.caption) }
        }
        .onAppear { hasKey = CloudModelKey.exists() }
        .onReceive(NotificationCenter.default.publisher(for: CloudModelKey.didChange)) { _ in
            hasKey = CloudModelKey.exists()
        }
    }
}

extension ChatView {
    func transcriptRows(userBubbleWidth: CGFloat) -> some View {
        ForEach(filteredTurns) { turn in
            let accent = replyColor(turn.source)
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Spacer(minLength: 0)
                    Text(turn.prompt)
                        .foregroundStyle(Color.black)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(palette.lime, in: RoundedRectangle(cornerRadius: 18))
                        .frame(maxWidth: userBubbleWidth, alignment: .trailing)
                }
                if !turn.reply.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(turn.source ?? "AI", systemImage: sourceIcon(turn.source))
                            .font(.caption.bold()).foregroundStyle(palette.isDark ? accent : palette.text)
                        if aiTimestamps, let date = turn.createdAt {
                            Text(date, format: .dateTime.hour().minute()).font(.caption).foregroundStyle(palette.secondary)
                        }
                        ChatTranscriptView(reply: turn.reply)
                        if aiWordCount {
                            Text("\(turn.reply.split(whereSeparator: \.isWhitespace).count) ord")
                                .font(.caption).foregroundStyle(palette.secondary)
                        }
                        replyActions(turn)
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
                    FadedCard(accent: palette.coral) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(notice)
                            if busyPCTurn == turn.id {
                                FadedSecondaryButton("Brug Telefon imens", icon: "iphone") {
                                    if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { restoreDraft(turn) }
                                    chooseSource(.phone)
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
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contextMenu {
                quickTurnActions(turn)
                Button("Start ny gren") { newConversation(); restoreDraft(turn) }.disabled(task != nil)
                Button("Slet besked", systemImage: "trash", role: .destructive) { deleteTurn(turn.id) }
                    .disabled(task != nil)
            }
            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                Button("Kopiér") { copyText(turn.reply.isEmpty ? turn.prompt : turn.reply) }
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button("Brug som kladde") { restoreDraft(turn) }.disabled(task != nil)
                Button("Ny gren") { newConversation(); restoreDraft(turn) }.disabled(task != nil)
            }
            .id(turn.id)
        }
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
        Button("Brug som kladde", systemImage: "square.and.pencil") { restoreDraft(turn) }.disabled(task != nil)
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
        chatSearch = ""
        composerFocused = true
    }

    private func quoteReply(_ turn: ChatTurn) {
        guard task == nil, !turn.reply.isEmpty else { return }
        attachedQuote = String(turn.reply.unicodeScalars.prefix(650))
        quoteDestination = effectiveReplySource
        chatSearch = ""
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
        let query = chatSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        return turns.filter { turn in
            (!favoritesOnly || turn.favorite == true) &&
            (query.isEmpty || turn.prompt.localizedCaseInsensitiveContains(query) || turn.reply.localizedCaseInsensitiveContains(query))
        }
    }

    @ViewBuilder var globalSearchRows: some View {
        let query = chatSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentIDs = Set(turns.map(\.id))
        let source = turns + archivedTurns.filter { !currentIDs.contains($0.id) }
        let hits = source.filter {
            (!favoritesOnly || $0.favorite == true) &&
            ($0.prompt.localizedCaseInsensitiveContains(query) || $0.reply.localizedCaseInsensitiveContains(query))
        }
        if hits.isEmpty {
            FadedEmptyState(icon: "magnifyingglass", title: "Ingen samtaler fundet",
                            detail: "Prøv et andet søgeord eller slå favoritfilteret fra.",
                            actionTitle: "Ryd søgning") { chatSearch = "" }
        }
        ForEach(hits.prefix(80)) { turn in
            VStack(alignment: .leading, spacing: 6) {
                Text(turn.prompt).font(.headline).textSelection(.enabled)
                if let date = turn.createdAt { Text(date, format: .dateTime.day().month().year()).font(.caption) }
                if !turn.reply.isEmpty { Text(turn.reply).lineLimit(5).textSelection(.enabled) }
            }
            .contextMenu {
                quickTurnActions(turn)
            }
        }
    }

    var conversationText: String {
        turns.map { "Dig: \($0.prompt)\n\($0.source ?? "AI"): \($0.reply)" }.joined(separator: "\n\n")
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

    var undoBar: some View {
        HStack {
            Text("Besked slettet").font(.subheadline)
            Spacer()
            Button("Fortryd", action: undoDelete).font(.subheadline.weight(.semibold)).frame(minHeight: 44)
        }
        .padding(.horizontal, 12).background(palette.raised, in: RoundedRectangle(cornerRadius: 12))
    }

    private func undoDelete() {
        guard let deletion = removedTurns.popLast(), deletion.expiresAt > ContinuousClock.now,
              !turns.contains(where: { $0.id == deletion.turn.id }) else { return }
        turns.insert(deletion.turn, at: min(deletion.index, turns.count))
        save()
    }

    func expireUndo() async {
        while let expiry = removedTurns.map(\.expiresAt).min() {
            do { try await Task.sleep(until: expiry, clock: .continuous) }
            catch { AppDiagnostics.record(error); return }
            removedTurns.removeAll { $0.expiresAt <= ContinuousClock.now }
        }
    }

    private func setFeedback(_ id: UUID, value: Int) {
        guard let index = turns.firstIndex(where: { $0.id == id }) else { return }
        turns[index].feedback = turns[index].feedback == value ? nil : value
        save()
    }

    func stop() { task?.cancel() }

    func newConversation() {
        if !turns.isEmpty {
            ChatArchive.append(SavedAgentSession(id: sessionID, turns: turns, toolSteps: searchSteps, pending: false))
        }
        turns = []
        draft = ""
        savedDraft = ""
        searchSteps = []
        sourceExcerpt = nil
        attachedNote = nil
        attachedQuote = nil
        removedTurns = []
        chatNotice = nil
        manualRoute = nil
        inFlightAutoRoute = nil
        sessionID = UUID()
        save()
    }

    func localReference(for message: String) -> String? {
        let words = Set(message.lowercased().components(separatedBy: CharacterSet.letters.inverted)
            .filter { $0.count >= 5 })
        guard !words.isEmpty else { return nil }
        return notes.split(whereSeparator: \.isNewline).first { line in
            let candidates = line.lowercased().components(separatedBy: CharacterSet.letters.inverted)
            return !words.isDisjoint(with: candidates)
        }.map { String($0.prefix(240)) }
    }

    @discardableResult func save(pending: Bool? = nil) -> Bool {
        let session = SavedAgentSession(id: sessionID, turns: turns, toolSteps: searchSteps, pending: pending ?? (task != nil))
        guard let data = try? JSONEncoder().encode(session) else { return false }
        UserDefaults.standard.set(data, forKey: storageKey)
        return true
    }

    func loadHistory() {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return }
        let decoder = JSONDecoder()
        if let session = try? decoder.decode(SavedAgentSession.self, from: data) {
            sessionID = session.id
            turns = session.turns
            searchSteps = session.toolSteps
            if session.pending && !turns.isEmpty {
                turns[turns.count - 1].notice = "Forbindelsen blev afbrudt, før svaret var færdigt."
                save()
            }
        } else if let saved = try? decoder.decode([ChatTurn].self, from: data) {
            turns = saved
        }
    }
}
