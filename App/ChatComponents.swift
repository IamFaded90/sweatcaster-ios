// Viser samtalen og håndterer chatarkiv og handlinger på beskeder.

import AVFoundation
import Foundation
import Observation
import Speech
import SwiftUI

struct ChatTurn: Identifiable, Codable, Sendable {
    var id = UUID()
    let prompt: String
    var reply = ""
    var notice: String?
    var source: String?
    var favorite: Bool?
    var createdAt: Date?
    var feedback: Int?
    var replyModelID: String?

    static func upsertOutbox(_ turn: Self, in turns: inout [Self]) {
        guard let index = turns.firstIndex(where: { $0.id == turn.id }) else {
            turns.append(turn)
            return
        }
        turns[index].reply = turn.reply
        turns[index].notice = turn.notice
        turns[index].source = turn.source
        turns[index].replyModelID = turn.replyModelID
    }
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

struct SavedAgentSession: Codable, Sendable {
    let id: UUID
    let turns: [ChatTurn]
    let toolSteps: [String]
    let pending: Bool
}

enum ChatArchive {
    static let key = AppStorageKeys.spacesChatArchiveV1

    @MainActor static func sessions() -> [SavedAgentSession] {
        let archive = MigratedAppData.shared.chatArchive()
        var seen = Set<UUID>()
        // Archive snapshots include outbox replies delivered after the conversation was closed.
        return (archive + storedSlots().filter { !$0.turns.isEmpty }).filter { seen.insert($0.id).inserted }
    }

    @MainActor @discardableResult
    static func append(_ session: SavedAgentSession, includeEmpty: Bool = false) -> Bool {
        guard includeEmpty || !session.turns.isEmpty else { return false }
        do {
            let archive = MigratedAppData.shared.chatArchive()
            try MigratedAppData.shared.saveChatArchive([session] + archive.filter { $0.id != session.id })
            return true
        } catch {
            AppDiagnostics.record(error)
            return false
        }
    }

    @MainActor static func remove(_ sessionID: UUID) throws {
        let archive = MigratedAppData.shared.chatArchive()
        guard archive.contains(where: { $0.id == sessionID }) else { return }
        try MigratedAppData.shared.saveChatArchive(archive.filter { $0.id != sessionID })
    }

    @MainActor static func appendOutboxTurn(_ turn: ChatTurn, to sessionID: UUID) -> Bool {
        let session = sessions().first { $0.id == sessionID }
        var turns = session?.turns ?? []
        ChatTurn.upsertOutbox(turn, in: &turns)
        return append(SavedAgentSession(id: sessionID, turns: turns, toolSteps: session?.toolSteps ?? [], pending: false))
    }

    static func decodeSession(_ data: Data) -> SavedAgentSession? {
        let decoder = JSONDecoder()
        if let session = try? decoder.decode(SavedAgentSession.self, from: data) { return session }
        guard let turns = try? decoder.decode([ChatTurn].self, from: data), let first = turns.first else { return nil }
        return SavedAgentSession(id: first.id, turns: turns, toolSteps: [], pending: false)
    }

    static func turns(archived: [SavedAgentSession]? = nil) -> [ChatTurn] {
        let archive = archived ?? UserDefaults.standard.data(forKey: key)
            .flatMap { try? JSONDecoder().decode([SavedAgentSession].self, from: $0) } ?? []
        var seenSessions = Set<UUID>()
        let sessions = (archive + storedSlots()).filter { seenSessions.insert($0.id).inserted }
        var byID: [UUID: ChatTurn] = [:]
        for turn in sessions.flatMap(\.turns) {
            if let saved = byID[turn.id], !saved.reply.isEmpty || turn.reply.isEmpty { continue }
            byID[turn.id] = turn
        }
        return byID.values.sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
    }

    private static func storedSlots() -> [SavedAgentSession] {
        UserDefaults.standard.dictionaryRepresentation().compactMap { name, value in
            guard name.hasPrefix(AppStorageKeys.chatSessionPrefix), name != key, let data = value as? Data else { return nil }
            return decodeSession(data)
        }
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

private struct ChatAgentActivity: View {
    let title: String
    let running: Bool
    let liveStatus: String?
    let steps: [String]
    @State private var expanded = false
    @Environment(\.fadedPalette) private var palette

    var body: some View {
        Group {
            if steps.isEmpty {
                heading
            } else {
                DisclosureGroup(isExpanded: $expanded) {
                    VStack(alignment: .leading, spacing: FadedSpacing.s) {
                        ForEach(steps.indices, id: \.self) { index in
                            Label {
                                Text(verbatim: steps[index])
                            } icon: {
                                Image(systemName: "circle").font(.system(size: 6)).accessibilityHidden(true)
                            }
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(palette.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, FadedSpacing.edge)
                    .padding(.bottom, FadedSpacing.s)
                } label: {
                    heading.frame(minHeight: 44)
                        .accessibilityHint("Viser \(steps.count) statusopdateringer")
                }
                .tint(palette.secondary)
            }
        }
        .padding(.horizontal, FadedSpacing.s)
    }

    private var heading: some View {
        HStack(spacing: FadedSpacing.s) {
            if running { AgentToolWave(status: title).accessibilityHidden(true) }
            else { Image(systemName: "clock").accessibilityHidden(true) }
            VStack(alignment: .leading, spacing: FadedSpacing.xs) {
                Text(title)
                if let liveStatus, liveStatus != title { Text(liveStatus).font(.caption) }
            }
        }
        .font(.footnote.weight(.medium))
        .foregroundStyle(palette.secondary)
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
    @ViewBuilder var chatAgentActivity: some View {
        let steps = aiShowTools ? searchSteps : []
        if task != nil {
            let waiting = turns.last?.reply.isEmpty != false
            let model = chatRouteModelTitle ?? "AI’en"
            ChatAgentActivity(title: waiting ? "\(model) gør svaret klar…" : "\(model) skriver…", running: true,
                              liveStatus: waiting && aiShowTools ? status : nil, steps: steps)
        } else if let responseDuration, responseDuration.turnID == turns.last?.id, responseDuration.seconds > 0 {
            ChatAgentActivity(title: "Svar klar · \(responseDuration.seconds) sek.", running: false,
                              liveStatus: nil, steps: steps)
        } else if !steps.isEmpty {
            ChatAgentActivity(title: "Agentaktivitet · \(steps.count) trin", running: false,
                              liveStatus: nil, steps: steps)
        }
    }

    var chatSuggestions: some View {
        ScrollView(.horizontal) {
            HStack(spacing: FadedSpacing.s) {
                chatSuggestion("Opsummér", icon: "text.alignleft", prompt: "Opsummér denne tekst i tre korte punkter:\n")
                chatSuggestion("Brainstorm", icon: "lightbulb", prompt: "Giv mig fem idéer til ")
                chatSuggestion("FPS-highlights", icon: "gamecontroller",
                               prompt: "Hjælp mig med at vurdere, hvad der gør et FPS-klip til et godt highlight.")
            }
        }
        .scrollIndicators(.hidden)
        .accessibilityLabel("Forslag til at starte en samtale")
    }

    private func chatSuggestion(_ title: String, icon: String, prompt: String) -> some View {
        FadedChip(title, accent: palette.lime, selected: false, icon: icon) {
            guard draft.isEmpty, task == nil else { return }
            draft = prompt
            composerFocused = true
        }
        .accessibilityHint("Sætter et forslag ind i beskedfeltet")
    }

    var conversationText: String {
        turns.map { "Dig: \($0.prompt)\n\($0.source ?? "AI"): \($0.reply)" }.joined(separator: "\n\n")
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

    func stop() { task?.cancel() }

    func localReference(for message: String) -> String? {
        let words = Set(message.lowercased().components(separatedBy: CharacterSet.letters.inverted)
            .filter { $0.count >= 5 })
        guard !words.isEmpty else { return nil }
        return notes.split(whereSeparator: \.isNewline).first { line in
            let candidates = line.lowercased().components(separatedBy: CharacterSet.letters.inverted)
            return !words.isDisjoint(with: candidates)
        }.map { String($0.prefix(240)) }
    }

}
